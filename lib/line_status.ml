open! Core

module Stable = struct
  module V1 = struct
    type t =
      | Draft
      | Approved
      | Funded
      | Submitted
      | Settled
      | Failed of Failure.Stable.V1.t
      | Returned of Payments_core.Iso_reason.Stable.V1.t option
      | Cancelled
    [@@deriving bin_io, sexp, compare, equal]
  end
end

include Stable.V1

let name = function
  | Draft -> "draft"
  | Approved -> "approved"
  | Funded -> "funded"
  | Submitted -> "submitted"
  | Settled -> "settled"
  | Failed _ -> "failed"
  | Returned _ -> "returned"
  | Cancelled -> "cancelled"
;;

let names =
  [ "draft"
  ; "approved"
  ; "funded"
  ; "submitted"
  ; "settled"
  ; "failed"
  ; "returned"
  ; "cancelled"
  ]
;;

(* A rail can report a return without ever reporting settlement (the provider folds both
   into one event), so [submitted -> returned] is allowed. *)
let allowed_transitions =
  [ "draft", [ "approved"; "cancelled" ]
  ; "approved", [ "funded"; "failed"; "cancelled" ]
  ; "funded", [ "submitted"; "failed"; "cancelled" ]
  ; "submitted", [ "settled"; "failed"; "returned" ]
  ; "settled", [ "returned" ]
  ; "failed", []
  ; "returned", []
  ; "cancelled", []
  ]
;;

let can_move ~from ~to_ =
  match List.Assoc.find allowed_transitions ~equal:String.equal (name from) with
  | None -> false
  | Some targets -> List.mem targets (name to_) ~equal:String.equal
;;

let is_final = function
  | Failed _ | Returned _ | Cancelled -> true
  | Draft | Approved | Funded | Submitted | Settled -> false
;;

let is_resolved t ~rail =
  match t with
  | Settled -> not (Payments_core.Rail.is_returnable rail)
  | _ -> is_final t
;;

let is_cancellable = function
  | Draft | Approved | Funded -> true
  | Submitted | Settled | Failed _ | Returned _ | Cancelled -> false
;;
