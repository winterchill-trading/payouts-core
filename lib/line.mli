(** One payment of a batch: who is paid, how much, on which rail, and where it is in its
    life ({!Line_status}).

    Every function here is pure and checks the transition table; the ledger entries that
    go with funding and submission are built by {!Funding} and {!Submission}. A line's
    {!Line_key.t} is its idempotency key: two lines with the same key and the same
    {!same_content} are one payment. *)

open! Core

(** Where a funded line's money is reserved. *)
module Funded_from : sig
  type t =
    { account : Ledger.Account_id.t (** the payer's account in the line's currency *)
    ; hold : Ledger.Hold_id.t (** the hold placed on it, {!Line_key.hold_id} *)
    ; conversion : Conversion.t option (** the currency was bought first *)
    }
  [@@deriving sexp, compare, equal]
end

type t = private
  { id : Line_id.t
  ; key : Line_key.t
  ; payee : Payments_core.Beneficiary.t
  ; rail : Payments_core.Rail.t
  ; amount : Money.Amount.t (** positive; what the payee receives *)
  ; reference : string (** shown to the payee, at most 140 characters *)
  ; status : Line_status.t
  ; history : (Line_status.t * Payments_core.Utc_time.t) list (** newest first *)
  ; funded_from : Funded_from.t option (** set when funded *)
  ; transfer : Payments_core.Transfer.Id.t option (** set when submitted *)
  ; provider_ref : string option (** the provider's id for the transfer, when known *)
  }
[@@deriving sexp, compare, equal]

(** 140 characters: the SEPA unstructured remittance limit. *)
val max_reference_length : int

(** A [Draft] line. Fails on a non-positive amount, a payee the rail cannot reach, a
    SEPA rail with a currency other than EUR, or a reference that is too long or has
    line breaks. *)
val create
  :  id:Line_id.t
  -> key:Line_key.t
  -> payee:Payments_core.Beneficiary.t
  -> rail:Payments_core.Rail.t
  -> amount:Money.Amount.t
  -> ?reference:string
  -> now:Time_ns.t
  -> unit
  -> t Or_error.t

(** The line's currency. *)
val currency : t -> Money.Currency.t

(** Same key, payee, rail, amount and reference: a retried request, not a conflicting
    use of the key. *)
val same_content : t -> t -> bool

(** When the line first entered a status with this name ({!Line_status.name}). *)
val entered_at : t -> string -> Time_ns.t option

(** {2 Transitions}

    Each fails when {!Line_status.can_move} refuses the move. *)

val approve : t -> at:Time_ns.t -> t Or_error.t
val fund : t -> Funded_from.t -> at:Time_ns.t -> t Or_error.t

(** Records the transfer that pays the line. *)
val submit
  :  t
  -> transfer:Payments_core.Transfer.Id.t
  -> ?provider_ref:string
  -> at:Time_ns.t
  -> unit
  -> t Or_error.t

val settle : t -> at:Time_ns.t -> t Or_error.t
val fail : t -> Failure.t -> at:Time_ns.t -> t Or_error.t
val return : t -> ?reason:Payments_core.Iso_reason.t -> at:Time_ns.t -> unit -> t Or_error.t
val cancel : t -> at:Time_ns.t -> t Or_error.t

(** Follows the line's transfer: [Settled] settles, [Rejected], [Failed] and [Cancelled]
    fail, [Returned] and [Recalled] return; statuses on the way ([Submitted], [Pending],
    [Timed_out], which can still settle late, a recall request, a reorg) leave the line
    as it is. A status the line already
    reflects is not an error, so the same provider event can be applied twice. Fails
    when the transfer is not the line's. *)
val observe : t -> Payments_core.Transfer.t -> at:Time_ns.t -> t Or_error.t

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
  end
end
