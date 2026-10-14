open! Core

module Summary = struct
  type t =
    { batch : Batch_id.t
    ; created_by : Actor_id.t
    ; totals : Money.Amount.t list
    ; line_count : int
    ; rails : Payments_core.Rail.t list
    }
  [@@deriving sexp_of]
end

module Refusal = struct
  type t =
    | Not_pending
    | Own_batch
    | Already_approved
    | Not_allowed of string
  [@@deriving sexp, compare, equal]

  let code = function
    | Not_pending -> "not_pending"
    | Own_batch -> "own_batch"
    | Already_approved -> "already_approved"
    | Not_allowed _ -> "not_allowed"
  ;;
end

module Policy = struct
  type t =
    { required_approvals : Summary.t -> int
    ; authorize : Summary.t -> approver:Actor_id.t -> (unit, string) Result.t
    }

  let allow_all _ ~approver:_ = Ok ()
  let one_approval = { required_approvals = (fun _ -> 1); authorize = allow_all }

  (* [Some limit] and the total exceeds it. A limit given in another currency than the one
     asked for is a configuration mistake; it counts as exceeded, so the mistake asks for
     more approval rather than less. *)
  let above limit total =
    match limit (Money.Amount.currency total) with
    | None -> false
    | Some limit ->
      (match Money.Amount.compare_value total limit with
       | Ok c -> c > 0
       | Error _ -> true)
  ;;

  let thresholds
    ?(auto_approve_up_to = fun _ -> None)
    ?(second_approver_above = fun _ -> None)
    ?authorize
    ()
    =
    let required_approvals (summary : Summary.t) =
      let within_auto total =
        Option.is_some (auto_approve_up_to (Money.Amount.currency total))
        && not (above auto_approve_up_to total)
      in
      if List.exists summary.totals ~f:(above second_approver_above)
      then 2
      else if (not (List.is_empty summary.totals))
              && List.for_all summary.totals ~f:within_auto
      then 0
      else 1
    in
    let authorize =
      match authorize with
      | None -> allow_all
      | Some f -> fun _ ~approver -> f approver
    in
    { required_approvals; authorize }
  ;;

  let required t summary = Int.max 0 (t.required_approvals summary)
end
