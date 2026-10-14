open! Core
module Transfer = Payments_core.Transfer

module Totals = struct
  type t =
    { currency : Money.Currency.t
    ; lines : int
    ; requested : Money.Amount.t
    ; awaiting : Money.Amount.t
    ; funded : Money.Amount.t
    ; submitted : Money.Amount.t
    ; settled : Money.Amount.t
    ; failed : Money.Amount.t
    ; returned : Money.Amount.t
    ; cancelled : Money.Amount.t
    }
  [@@deriving sexp, compare, equal]

  let empty currency =
    let zero = Money.Amount.zero currency in
    { currency
    ; lines = 0
    ; requested = zero
    ; awaiting = zero
    ; funded = zero
    ; submitted = zero
    ; settled = zero
    ; failed = zero
    ; returned = zero
    ; cancelled = zero
    }
  ;;

  let add_line t (line : Line.t) =
    let a = line.amount in
    let ( + ) x y = Money.Amount.add_exn x y in
    let t = { t with lines = Int.succ t.lines; requested = t.requested + a } in
    match line.status with
    | Draft | Approved -> { t with awaiting = t.awaiting + a }
    | Funded -> { t with funded = t.funded + a }
    | Submitted -> { t with submitted = t.submitted + a }
    | Settled -> { t with settled = t.settled + a }
    | Failed _ -> { t with failed = t.failed + a }
    | Returned _ -> { t with returned = t.returned + a }
    | Cancelled -> { t with cancelled = t.cancelled + a }
  ;;

  let of_batch (batch : Batch.t) =
    List.fold
      batch.lines
      ~init:(Map.empty (module Money.Currency))
      ~f:(fun acc line ->
        Map.update acc (Line.currency line) ~f:(fun row ->
          add_line (Option.value row ~default:(empty (Line.currency line))) line))
    |> Map.data
  ;;

  let check t =
    let buckets =
      [ t.awaiting; t.funded; t.submitted; t.settled; t.failed; t.returned; t.cancelled ]
    in
    let open Or_error.Let_syntax in
    let%bind sum = Money.Amount.sum t.currency buckets in
    if Money.Amount.equal sum t.requested
    then Ok ()
    else
      Or_error.error_s
        [%message
          "buckets do not add up"
            ~currency:(t.currency : Money.Currency.t)
            ~requested:(t.requested : Money.Amount.t)
            (sum : Money.Amount.t)]
  ;;
end

module Diff = struct
  type t =
    | Hold_missing of
        { line : Line_id.t
        ; hold : Ledger.Hold_id.t
        }
    | Hold_amount_mismatch of
        { line : Line_id.t
        ; hold : Ledger.Hold_id.t
        ; line_amount : Money.Amount.t
        ; held : Money.Amount.t
        }
    | Hold_left_open of
        { line : Line_id.t
        ; hold : Ledger.Hold_id.t
        ; held : Money.Amount.t
        }
    | Transfer_missing of
        { line : Line_id.t
        ; transfer : Transfer.Id.t
        }
    | Transfer_amount_mismatch of
        { line : Line_id.t
        ; transfer : Transfer.Id.t
        ; line_amount : Money.Amount.t
        ; transfer_amount : Money.Amount.t
        }
    | Status_mismatch of
        { line : Line_id.t
        ; transfer : Transfer.Id.t
        ; line_status : Line_status.t
        ; transfer_status : Transfer.Status.t
        }
    | Settled_total_mismatch of
        { currency : Money.Currency.t
        ; batch : Money.Amount.t
        ; transfers : Money.Amount.t
        }
  [@@deriving sexp_of, compare, equal]
end

let hold_diffs balances (line : Line.t) : Diff.t list =
  match line.funded_from with
  | None -> []
  | Some { hold; _ } ->
    let remaining =
      Option.map (Ledger.Balances.find_hold balances hold) ~f:(fun h -> h.remaining)
    in
    (match line.status, remaining with
     | Funded, None -> [ Hold_missing { line = line.id; hold } ]
     | Funded, Some held when not (Money.Amount.equal held line.amount) ->
       [ Hold_amount_mismatch { line = line.id; hold; line_amount = line.amount; held } ]
     | Funded, Some _ -> []
     | _, Some held when Money.Amount.is_positive held ->
       [ Hold_left_open { line = line.id; hold; held } ]
     | _, (None | Some _) -> [])
;;

let transfer_diffs transfers (line : Line.t) : Diff.t list =
  match line.transfer with
  | None -> []
  | Some id ->
    (match Map.find transfers id with
     | None -> [ Transfer_missing { line = line.id; transfer = id } ]
     | Some (transfer : Transfer.t) ->
       let amount =
         if Money.Amount.equal transfer.amount line.amount
         then []
         else
           [ Diff.Transfer_amount_mismatch
               { line = line.id
               ; transfer = id
               ; line_amount = line.amount
               ; transfer_amount = transfer.amount
               }
           ]
       in
       let follows =
         match Line.observe line transfer ~at:Time_ns.epoch with
         | Ok observed -> Line_status.equal observed.status line.status
         | Error _ -> false
       in
       let status =
         if follows
         then []
         else
           [ Diff.Status_mismatch
               { line = line.id
               ; transfer = id
               ; line_status = line.status
               ; transfer_status = transfer.status
               }
           ]
       in
       amount @ status)
;;

let settled_totals (batch : Batch.t) transfers : Diff.t list =
  let sum_by_currency amounts =
    List.fold
      amounts
      ~init:(Map.empty (module Money.Currency))
      ~f:(fun acc a ->
        Map.update acc (Money.Amount.currency a) ~f:(function
          | None -> a
          | Some s -> Money.Amount.add_exn s a))
  in
  let ours =
    List.filter_map batch.lines ~f:(fun l ->
      Option.some_if (Line_status.equal l.status Settled) l.amount)
    |> sum_by_currency
  in
  let theirs =
    List.filter_map batch.lines ~f:(fun l ->
      Option.bind l.transfer ~f:(Map.find transfers))
    |> List.filter_map ~f:(fun (t : Transfer.t) ->
      Option.some_if (Transfer.Status.equal t.status Settled) t.amount)
    |> sum_by_currency
  in
  Map.merge ours theirs ~f:(fun ~key:currency -> function
    | `Both (a, b) when Money.Amount.equal a b -> None
    | `Both (batch, transfers) ->
      Some (Diff.Settled_total_mismatch { currency; batch; transfers })
    | `Left batch ->
      Some
        (Settled_total_mismatch
           { currency; batch; transfers = Money.Amount.zero currency })
    | `Right transfers ->
      Some
        (Settled_total_mismatch
           { currency; batch = Money.Amount.zero currency; transfers }))
  |> Map.data
;;

let check (batch : Batch.t) ~balances ~transfers =
  let transfers =
    List.fold
      transfers
      ~init:(Map.empty (module Transfer.Id))
      ~f:(fun acc (t : Transfer.t) -> Map.set acc ~key:t.id ~data:t)
  in
  List.concat_map batch.lines ~f:(fun line ->
    hold_diffs balances line @ transfer_diffs transfers line)
  @ settled_totals batch transfers
;;
