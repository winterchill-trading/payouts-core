(** A receipt for one payout line: what was paid, to whom, how, and what happened.

    A receipt is a plain value built from the batch, so it can be rendered (text here;
    PDF or HTML by the caller), stored or sent without reading anything else. The
    payee's account is masked to its last four characters, so a receipt is safe to
    e-mail or log. Receipts exist once a line was handed to its rail: a line that never
    left (still waiting, cancelled, or failed while funding) has none. *)

open! Core

module Outcome : sig
  type t =
    | In_progress (** submitted, no final answer yet *)
    | Paid (** settled *)
    | Failed of Failure.t
    | Returned of Payments_core.Iso_reason.t option
  [@@deriving sexp, compare, equal]

  (** ["in_progress"], ["paid"], ["failed"], ["returned"]. *)
  val name : t -> string
end

type t =
  { batch : Batch_id.t
  ; batch_title : string
  ; line : Line_id.t
  ; key : Line_key.t
  ; payee_name : string
  ; destination : string (** masked, e.g. ["IBAN ****3000"] *)
  ; rail : Payments_core.Rail.t
  ; amount : Money.Amount.t
  ; reference : string
  ; outcome : Outcome.t
  ; transfer : Payments_core.Transfer.Id.t
  ; provider_ref : string option
  ; created_by : Actor_id.t
  ; approved_by : Actor_id.t list (** in approval order; empty when auto-approved *)
  ; conversion : Conversion.t option
  ; timeline : (string * Payments_core.Utc_time.t) list
  (** status names with the time each was entered, oldest first *)
  }
[@@deriving sexp, compare, equal]

(** The receipt of one line. Fails when the line is unknown or was never submitted. *)
val of_line : Batch.t -> Line_id.t -> t Or_error.t

(** Receipts of every submitted line, in line order. *)
val all : Batch.t -> t list

(** The masked form of a payee's destination. *)
val mask_destination : Payments_core.Beneficiary.Destination.t -> string

(** A plain-text rendering, one ["label: value"] per line, times in UTC. *)
val to_text : t -> string

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
  end
end
