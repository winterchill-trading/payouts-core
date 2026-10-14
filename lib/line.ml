open! Core
module Beneficiary = Payments_core.Beneficiary
module Rail = Payments_core.Rail
module Transfer = Payments_core.Transfer
module Utc_time = Payments_core.Utc_time

module Funded_from = struct
  module Stable = struct
    module V1 = struct
      type t =
        { account : Ledger.Account_id.Stable.V1.t
        ; hold : Ledger.Hold_id.Stable.V1.t
        ; conversion : Conversion.Stable.V1.t option
        }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  include Stable.V1
end

module Stable = struct
  module V1 = struct
    type t =
      { id : Line_id.Stable.V1.t
      ; key : Line_key.Stable.V1.t
      ; payee : Beneficiary.Stable.V2.t
      ; rail : Rail.Stable.V2.t
      ; amount : Money.Amount.Stable.V1.t
      ; reference : string
      ; status : Line_status.Stable.V1.t
      ; history : (Line_status.Stable.V1.t * Utc_time.Stable.V1.t) list
      ; funded_from : Funded_from.Stable.V1.t option
      ; transfer : Transfer.Id.Stable.V1.t option
      ; provider_ref : string option
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

include Stable.V1

let max_reference_length = 140
let currency t = Money.Amount.currency t.amount

(* The currency a rail is limited to, if any. *)
let rail_currency (rail : Rail.t) =
  if Rail.is_uk rail
  then Some Money.Currency.gbp
  else (
    (* A wildcard on purpose: payments-core gains rails over time, and only SEPA and the
       UK rails restrict the currency. *)
    match rail with
    | Sepa_credit | Sepa_instant -> Some Money.Currency.eur
    | _ -> None)
;;

let create ~id ~key ~payee ~rail ~amount ?(reference = "") ~now () =
  let open Or_error.Let_syntax in
  let%bind () =
    if Money.Amount.is_positive amount
    then Ok ()
    else Or_error.error_s [%message "amount must be positive" (amount : Money.Amount.t)]
  in
  let%bind () =
    if Beneficiary.usable_on payee rail
    then Ok ()
    else
      Or_error.error_s [%message "payee cannot be reached on this rail" (rail : Rail.t)]
  in
  let%bind () =
    match rail_currency rail with
    | Some required
      when not (Money.Currency.equal (Money.Amount.currency amount) required) ->
      Or_error.error_s
        [%message
          "rail pays another currency"
            (rail : Rail.t)
            (required : Money.Currency.t)
            ~currency:(Money.Amount.currency amount : Money.Currency.t)]
    | Some _ | None -> Ok ()
  in
  let%bind () =
    if String.length reference > max_reference_length
    then
      Or_error.error_s
        [%message
          "reference too long"
            (max_reference_length : int)
            ~length:(String.length reference : int)]
    else if String.exists reference ~f:(fun c -> Char.equal c '\n' || Char.equal c '\r')
    then Or_error.error_s [%message "reference has a line break"]
    else Ok ()
  in
  return
    { id
    ; key
    ; payee
    ; rail
    ; amount
    ; reference
    ; status = Draft
    ; history = [ Line_status.Draft, now ]
    ; funded_from = None
    ; transfer = None
    ; provider_ref = None
    }
;;

let same_content a b =
  Line_key.equal a.key b.key
  && Beneficiary.equal a.payee b.payee
  && Rail.equal a.rail b.rail
  && Money.Amount.equal a.amount b.amount
  && String.equal a.reference b.reference
;;

let entered_at t name =
  (* [history] is newest first; the first entry into a status is the last match. *)
  List.rev t.history
  |> List.find_map ~f:(fun (status, at) ->
    Option.some_if (String.equal (Line_status.name status) name) at)
;;

let move t ~to_ ~at =
  if Line_status.can_move ~from:t.status ~to_
  then Ok { t with status = to_; history = (to_, at) :: t.history }
  else
    Or_error.error_s
      [%message
        "line cannot move"
          ~line:(t.key : Line_key.t)
          ~from:(t.status : Line_status.t)
          (to_ : Line_status.t)]
;;

let approve t ~at = move t ~to_:Approved ~at

let fund t (from : Funded_from.t) ~at =
  let open Or_error.Let_syntax in
  let%bind t = move t ~to_:Funded ~at in
  return { t with funded_from = Some from }
;;

let submit t ~transfer ?provider_ref ~at () =
  let open Or_error.Let_syntax in
  let%bind t = move t ~to_:Submitted ~at in
  return { t with transfer = Some transfer; provider_ref }
;;

let settle t ~at = move t ~to_:Settled ~at
let fail t failure ~at = move t ~to_:(Failed failure) ~at
let return t ?reason ~at () = move t ~to_:(Returned reason) ~at
let cancel t ~at = move t ~to_:Cancelled ~at

(* What the line should become for a transfer status, or [None] to stay. *)
let target_of_transfer (status : Transfer.Status.t) : Line_status.t option =
  match status with
  | Settled -> Some Settled
  | Rejected reason -> Some (Failed (Rejected reason))
  | Failed reason -> Some (Failed (Transfer_failed reason))
  | Returned reason -> Some (Returned (Some reason))
  | Recalled -> Some (Returned None)
  | Cancelled -> Some (Failed (Submission_refused "transfer cancelled"))
  | Draft
  | Awaiting_sca
  | Submitted
  | Pending
  | Recall_requested _
  | Recall_refused _
  | Reorged
  (* An instant payment without confirmation can still settle late, so the line waits for
     the transfer's next status instead of failing. *)
  | Timed_out -> None
;;

let observe t (transfer : Transfer.t) ~at =
  match t.transfer with
  | None ->
    Or_error.error_s [%message "line has no transfer yet" ~line:(t.key : Line_key.t)]
  | Some id when not (Transfer.Id.equal id transfer.id) ->
    Or_error.error_s
      [%message
        "transfer belongs to another line"
          ~line:(t.key : Line_key.t)
          ~expected:(id : Transfer.Id.t)
          ~got:(transfer.id : Transfer.Id.t)]
  | Some _ ->
    let t =
      match transfer.provider_ref, t.provider_ref with
      | Some _, None -> { t with provider_ref = transfer.provider_ref }
      | _ -> t
    in
    (match target_of_transfer transfer.status with
     | None -> Ok t
     | Some target when Line_status.equal target t.status -> Ok t
     | Some target -> move t ~to_:target ~at)
;;
