open! Core

module Mode = struct
  type t =
    | Line_by_line
    | All_or_nothing
  [@@deriving sexp, compare, equal]
end

module Source = struct
  type t =
    { account_for : Money.Currency.t -> Ledger.Account_id.t option
    ; funding_currency : Money.Currency.t option
    ; conversion : Conversion.Hook.t
    }

  let lookup accounts currency =
    List.Assoc.find accounts ~equal:Money.Currency.equal currency
  ;;

  let of_accounts accounts =
    { account_for = lookup accounts
    ; funding_currency = None
    ; conversion = Conversion.Hook.none
    }
  ;;

  let with_conversion accounts ~funding_currency ~hook =
    { account_for = lookup accounts
    ; funding_currency = Some funding_currency
    ; conversion = hook
    }
  ;;
end

module Decision = struct
  type t =
    | Fund of
        { account : Ledger.Account_id.t
        ; conversion : Conversion.t option
        }
    | Convert of
        { from_ : Ledger.Account_id.t
        ; to_ : Ledger.Account_id.t
        ; conversion : Conversion.t
        }
    | Fail of Failure.t
  [@@deriving sexp_of]
end

module Plan = struct
  type t =
    | Planned of
        { decisions : (Line_id.t * Decision.t) list
        ; entries : Ledger.Entry.t list
        }
    | Refused of (Line_id.t * Failure.t) list
  [@@deriving sexp_of]

  let held = function
    | Refused _ -> []
    | Planned { entries; _ } ->
      List.map entries ~f:Ledger.Entry.total
      |> List.sort_and_group ~compare:(fun a b ->
        Money.Currency.compare (Money.Amount.currency a) (Money.Amount.currency b))
      |> List.map ~f:(fun group ->
        Money.Amount.sum (Money.Amount.currency (List.hd_exn group)) group
        |> Or_error.ok_exn)
  ;;
end

(* Available balances as the plan goes: the ledger's figure less what earlier lines of
   this plan reserved or will sell. *)
module Running = struct
  type t = Money.Amount.t Map.M(Ledger.Account_id).t Map.M(Money.Currency).t

  let get (t : t) balances account currency =
    match Option.bind (Map.find t currency) ~f:(fun m -> Map.find m account) with
    | Some amount -> amount
    | None -> Ledger.Balances.available balances account currency
  ;;

  let set (t : t) account amount : t =
    Map.update t (Money.Amount.currency amount) ~f:(fun m ->
      Map.set
        (Option.value m ~default:(Map.empty (module Ledger.Account_id)))
        ~key:account
        ~data:amount)
  ;;
end

let covers available amount =
  match Money.Amount.compare_value available amount with
  | Ok c -> c >= 0
  | Error _ -> false
;;

let decide (source : Source.t) balances running ~converted (line : Line.t) =
  let currency = Line.currency line in
  match source.account_for currency with
  | None -> running, Decision.Fail (No_funding_account currency)
  | Some account ->
    let available = Running.get running balances account currency in
    if covers available line.amount
    then (
      let conversion = List.Assoc.find converted ~equal:Line_id.equal line.id in
      ( Running.set running account (Money.Amount.sub_exn available line.amount)
      , Fund { account; conversion } ))
    else (
      let short =
        Decision.Fail (Insufficient_funds { required = line.amount; available })
      in
      match source.funding_currency with
      | None -> running, short
      | Some sell when Money.Currency.equal sell currency -> running, short
      | Some sell ->
        (match source.account_for sell with
         | None -> running, Fail (No_funding_account sell)
         | Some from_ ->
           (match source.conversion.quote ~sell ~buy:line.amount with
            | Error reason -> running, Fail (Conversion_unavailable reason)
            | Ok conversion ->
              (match Conversion.validate conversion ~sell ~buy:line.amount with
               | Error e -> running, Fail (Conversion_unavailable (Error.to_string_hum e))
               | Ok () ->
                 let funds = Running.get running balances from_ sell in
                 if covers funds conversion.sell
                 then
                   ( Running.set running from_ (Money.Amount.sub_exn funds conversion.sell)
                   , Convert { from_; to_ = account; conversion } )
                 else
                   ( running
                   , Fail
                       (Insufficient_funds
                          { required = conversion.sell; available = funds }) )))))
;;

let hold_entry balances (batch : Batch.t) (line : Line.t) ~account ~now =
  Ledger.Hold.place
    balances
    ~hold_id:(Line_key.hold_id line.key)
    ~account
    ~amount:line.amount
    ~idempotency_key:(Line_key.derive line.key Fund)
    ~reference:(Batch_id.to_string batch.id ^ "/" ^ Line_id.to_string line.id)
    ~effective_at:now
    ~recorded_at:now
    ()
;;

let plan balances source (batch : Batch.t) ~mode ?lines ?(converted = []) ~now () =
  let open Or_error.Let_syntax in
  let%bind () =
    match batch.status with
    | Approved -> Ok ()
    | Pending_approval | Rejected _ | Cancelled _ ->
      Or_error.error_s [%message "batch is not approved" ~batch:(batch.id : Batch_id.t)]
  in
  let%bind selected =
    match lines with
    | None -> Ok batch.lines
    | Some ids ->
      let%bind () =
        match List.find ids ~f:(fun id -> Option.is_none (Batch.find_line batch id)) with
        | None -> Ok ()
        | Some id -> Or_error.error_s [%message "no such line" (id : Line_id.t)]
      in
      Ok
        (List.filter batch.lines ~f:(fun (l : Line.t) ->
           List.mem ids l.id ~equal:Line_id.equal))
  in
  let candidates =
    List.filter selected ~f:(fun (l : Line.t) -> Line_status.equal l.status Approved)
  in
  let _running, decisions =
    List.fold_map
      candidates
      ~init:(Map.empty (module Money.Currency))
      ~f:(fun running line ->
        let running, decision = decide source balances running ~converted line in
        running, (line, decision))
  in
  let failures =
    List.filter_map decisions ~f:(fun ((l : Line.t), d) ->
      match d with
      | Fail f -> Some (l.id, f)
      | Fund _ | Convert _ -> None)
  in
  match (mode : Mode.t), failures with
  | All_or_nothing, _ :: _ -> return (Plan.Refused failures)
  | (All_or_nothing | Line_by_line), _ ->
    (* Build each hold against the balances after the previous ones, as the journal will
       apply them. *)
    let%bind _, entries =
      List.fold_result decisions ~init:(balances, []) ~f:(fun (balances, acc) (line, d) ->
        match d with
        | Fail _ | Convert _ -> Ok (balances, acc)
        | Fund { account; _ } ->
          let%bind entry = hold_entry balances batch line ~account ~now in
          let%bind balances = Payments_core.Booking.apply balances [ entry ] in
          Ok (balances, entry :: acc))
    in
    return
      (Plan.Planned
         { decisions = List.map decisions ~f:(fun ((l : Line.t), d) -> l.id, d)
         ; entries = List.rev entries
         })
;;

let apply batch (plan : Plan.t) ~now =
  match plan with
  | Refused _ -> Ok batch
  | Planned { decisions; _ } ->
    List.fold_result decisions ~init:batch ~f:(fun batch (id, decision) ->
      match (decision : Decision.t) with
      | Convert _ -> Ok batch
      | Fail failure ->
        Batch.update_line batch id ~f:(fun l -> Line.fail l failure ~at:now)
      | Fund { account; conversion } ->
        Batch.update_line batch id ~f:(fun l ->
          Line.fund l { account; hold = Line_key.hold_id l.key; conversion } ~at:now))
;;

let release balances (line : Line.t) ~now =
  match line.funded_from with
  | None ->
    Or_error.error_s [%message "line was never funded" ~line:(line.key : Line_key.t)]
  | Some from ->
    Ledger.Hold.release
      balances
      ~hold_id:from.hold
      ~idempotency_key:(Line_key.derive line.key Release)
      ~reference:(Line_id.to_string line.id)
      ~effective_at:now
      ~recorded_at:now
      ()
;;
