open! Core
module Utc_time = Payments_core.Utc_time

module Status = struct
  module Stable = struct
    module V1 = struct
      type t =
        | Pending_approval
        | Approved
        | Rejected of
            { by : Actor_id.Stable.V1.t
            ; note : string
            }
        | Cancelled of { by : Actor_id.Stable.V1.t }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  include Stable.V1

  let name = function
    | Pending_approval -> "pending_approval"
    | Approved -> "approved"
    | Rejected _ -> "rejected"
    | Cancelled _ -> "cancelled"
  ;;
end

module Progress = struct
  type t =
    | Awaiting_approval
    | Processing
    | Completed
    | Completed_with_failures
    | Failed
    | Rejected
    | Cancelled
  [@@deriving sexp, compare, equal, enumerate]

  let name = function
    | Awaiting_approval -> "awaiting_approval"
    | Processing -> "processing"
    | Completed -> "completed"
    | Completed_with_failures -> "completed_with_failures"
    | Failed -> "failed"
    | Rejected -> "rejected"
    | Cancelled -> "cancelled"
  ;;
end

module Approval_record = struct
  module Stable = struct
    module V1 = struct
      type t =
        { by : Actor_id.Stable.V1.t
        ; at : Utc_time.Stable.V1.t
        }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  include Stable.V1
end

module Stable = struct
  module V1 = struct
    type t =
      { id : Batch_id.Stable.V1.t
      ; title : string
      ; created_by : Actor_id.Stable.V1.t
      ; created_at : Utc_time.Stable.V1.t
      ; lines : Line.Stable.V1.t list
      ; approvals_required : int
      ; approvals : Approval_record.Stable.V1.t list
      ; status : Status.Stable.V1.t
      ; decided_at : Utc_time.Stable.V1.t option
      ; revision : int
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

include Stable.V1

let max_lines = 1000
let max_title_length = 140
let active_lines t = List.filter t.lines ~f:(fun l -> not (Line_status.equal l.status Cancelled))

let totals_of lines =
  List.map lines ~f:(fun (l : Line.t) -> l.amount)
  |> List.sort_and_group ~compare:(fun a b ->
    Money.Currency.compare (Money.Amount.currency a) (Money.Amount.currency b))
  |> List.map ~f:(fun group ->
    let currency = Money.Amount.currency (List.hd_exn group) in
    Money.Amount.sum currency group |> Or_error.ok_exn)
;;

let totals t = totals_of (active_lines t)

let summary t : Approval.Summary.t =
  let lines = active_lines t in
  { batch = t.id
  ; created_by = t.created_by
  ; totals = totals_of lines
  ; line_count = List.length lines
  ; rails =
      List.map lines ~f:(fun l -> l.rail)
      |> List.dedup_and_sort ~compare:Payments_core.Rail.compare
  }
;;

let check_unique ~what ~compare items =
  match List.find_a_dup items ~compare with
  | None -> Ok ()
  | Some _ -> Or_error.error_s [%message "duplicate" what]
;;

(* Moves every draft line to [Approved]; used when the last approval arrives. *)
let approve_lines lines ~at =
  List.map lines ~f:(fun (l : Line.t) ->
    match l.status with
    | Draft -> Line.approve l ~at |> Or_error.ok_exn
    | _ -> l)
;;

let cancel_lines lines ~at =
  List.map lines ~f:(fun (l : Line.t) ->
    if Line_status.is_cancellable l.status then Line.cancel l ~at |> Or_error.ok_exn else l)
;;

let bump t = { t with revision = t.revision + 1 }

let create ~id ~title ~created_by ~lines ~policy ~now =
  let open Or_error.Let_syntax in
  let%bind () =
    let n = List.length lines in
    if n = 0
    then Or_error.error_s [%message "a batch needs at least one line"]
    else if n > max_lines
    then Or_error.error_s [%message "too many lines" (n : int) (max_lines : int)]
    else Ok ()
  in
  let%bind () =
    let title = String.strip title in
    if String.is_empty title
    then Or_error.error_s [%message "empty title"]
    else if String.length title > max_title_length
    then Or_error.error_s [%message "title too long" (max_title_length : int)]
    else Ok ()
  in
  let%bind () =
    match List.find lines ~f:(fun (l : Line.t) -> not (Line_status.equal l.status Draft)) with
    | None -> Ok ()
    | Some l ->
      Or_error.error_s
        [%message "line is not a draft" ~line:(l.key : Line_key.t) ~status:(l.status : Line_status.t)]
  in
  let%bind () =
    check_unique
      ~what:"line id"
      ~compare:Line_id.compare
      (List.map lines ~f:(fun (l : Line.t) -> l.id))
  in
  let%bind () =
    check_unique
      ~what:"line key"
      ~compare:Line_key.compare
      (List.map lines ~f:(fun (l : Line.t) -> l.key))
  in
  let t =
    { id
    ; title = String.strip title
    ; created_by
    ; created_at = now
    ; lines
    ; approvals_required = 0
    ; approvals = []
    ; status = Pending_approval
    ; decided_at = None
    ; revision = 0
    }
  in
  let required = Approval.Policy.required policy (summary t) in
  if required = 0
  then
    return
      { t with
        status = Approved
      ; decided_at = Some now
      ; lines = approve_lines lines ~at:now
      }
  else return { t with approvals_required = required }
;;

let authorize t ~(policy : Approval.Policy.t) ~actor : (unit, Approval.Refusal.t) Result.t =
  match policy.authorize (summary t) ~approver:actor with
  | Ok () -> Ok ()
  | Error reason -> Error (Not_allowed reason)
;;

let can_approve t ~policy ~approver : (unit, Approval.Refusal.t) Result.t =
  match t.status with
  | Approved | Rejected _ | Cancelled _ -> Error Not_pending
  | Pending_approval when List.is_empty (active_lines t) -> Error Not_pending
  | Pending_approval ->
    if Actor_id.equal approver t.created_by
    then Error Own_batch
    else if List.exists t.approvals ~f:(fun a -> Actor_id.equal a.by approver)
    then Error Already_approved
    else authorize t ~policy ~actor:approver
;;

let approve t ~policy ~approver ~now =
  let open Result.Let_syntax in
  let%bind () = can_approve t ~policy ~approver in
  let approvals = t.approvals @ [ { Approval_record.by = approver; at = now } ] in
  let t = bump { t with approvals } in
  if List.length approvals >= t.approvals_required
  then
    return
      { t with
        status = Approved
      ; decided_at = Some now
      ; lines = approve_lines t.lines ~at:now
      }
  else return t
;;

let decide t ~policy ~by ~creator_may ~now ~status : (t, Approval.Refusal.t) Result.t =
  let open Result.Let_syntax in
  let%bind () =
    match t.status with
    | Pending_approval -> Ok ()
    | Approved | Rejected _ | Cancelled _ -> Error Approval.Refusal.Not_pending
  in
  let%bind () =
    if Actor_id.equal by t.created_by
    then if creator_may then Ok () else Error Approval.Refusal.Own_batch
    else authorize t ~policy ~actor:by
  in
  return
    (bump
       { t with status; decided_at = Some now; lines = cancel_lines t.lines ~at:now })
;;

let reject t ~policy ~by ~note ~now =
  decide t ~policy ~by ~creator_may:false ~now ~status:(Rejected { by; note })
;;

let cancel t ~policy ~by ~now =
  decide t ~policy ~by ~creator_may:true ~now ~status:(Cancelled { by })
;;

let is_done (l : Line.t) =
  match l.status with
  | Settled | Failed _ | Returned _ | Cancelled -> true
  | Draft | Approved | Funded | Submitted -> false
;;

let progress t : Progress.t =
  match t.status with
  | Pending_approval ->
    if List.is_empty (active_lines t) then Cancelled else Awaiting_approval
  | Rejected _ -> Rejected
  | Cancelled _ -> Cancelled
  | Approved ->
    let lines = active_lines t in
    if List.is_empty lines
    then Cancelled
    else if not (List.for_all lines ~f:is_done)
    then Processing
    else (
      let settled = List.count lines ~f:(fun l -> Line_status.equal l.status Settled) in
      if settled = List.length lines
      then Completed
      else if settled > 0
      then Completed_with_failures
      else Failed)
;;

let find_line t id = List.find t.lines ~f:(fun l -> Line_id.equal l.id id)
let find_line_by_key t key = List.find t.lines ~f:(fun l -> Line_key.equal l.key key)

let find_line_by_transfer t transfer =
  List.find t.lines ~f:(fun l ->
    Option.equal Payments_core.Transfer.Id.equal l.transfer (Some transfer))
;;

let lines_in t name =
  List.filter t.lines ~f:(fun l -> String.equal (Line_status.name l.status) name)
;;

let replace_line t (line : Line.t) =
  { t with
    lines = List.map t.lines ~f:(fun l -> if Line_id.equal l.id line.id then line else l)
  }
;;

let cancel_line t ~policy id ~now =
  let open Or_error.Let_syntax in
  let%bind line =
    match find_line t id with
    | Some l -> Ok l
    | None -> Or_error.error_s [%message "no such line" (id : Line_id.t)]
  in
  match t.status with
  | Rejected _ | Cancelled _ -> Or_error.error_s [%message "batch is closed"]
  | Approved ->
    let%bind line = Line.cancel line ~at:now in
    return (bump (replace_line t line))
  | Pending_approval ->
    let%bind line = Line.cancel line ~at:now in
    let t = replace_line t line in
    (* The approvals given so far were for a different batch. *)
    let required = Approval.Policy.required policy (summary t) in
    return (bump { t with approvals = []; approvals_required = Int.max 1 required })
;;

let update_line t id ~f =
  let open Or_error.Let_syntax in
  let%bind () =
    match t.status with
    | Approved -> Ok ()
    | Pending_approval | Rejected _ | Cancelled _ ->
      Or_error.error_s
        [%message "batch is not approved" ~status:(Status.name t.status : string)]
  in
  let%bind line =
    match find_line t id with
    | Some l -> Ok l
    | None -> Or_error.error_s [%message "no such line" (id : Line_id.t)]
  in
  let%bind (updated : Line.t) = f line in
  if Line_id.equal updated.id line.id && Line_key.equal updated.key line.key
  then return (bump (replace_line t updated))
  else Or_error.error_s [%message "update changed the line's id or key"]
;;
