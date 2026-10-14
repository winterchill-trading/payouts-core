(** Where a payout line is in its life.

    {v
    Draft ──> Approved ──> Funded ──> Submitted ──> Settled ──> Returned
      │          │           │            │  └──────────────────────^
      │          ├───────────┴────────────┴──> Failed
      └──────────┴───────────┴──> Cancelled
    v}

    - [Draft]: in a batch waiting for approval.
    - [Approved]: the batch was approved; the line waits for funds.
    - [Funded]: a ledger hold reserves the amount on the funding account.
    - [Submitted]: the transfer left for the rail; the hold moved to the transfer.
    - [Settled]: the rail confirmed the payment.
    - [Failed]: funding, submission or the rail failed; any reserved funds go back.
    - [Returned]: the payee's bank sent the money back (only on returnable rails, after or
      instead of settlement).
    - [Cancelled]: taken out before submission (batch rejected or cancelled, or the line
      cancelled on its own).

    [Failed], [Returned] and [Cancelled] are final. A failed line is not retried in place:
    paying again is a new line with a new key, so the ledger never sees one key twice for
    two attempts. *)

open! Core

type t =
  | Draft
  | Approved
  | Funded
  | Submitted
  | Settled
  | Failed of Failure.t
  | Returned of Payments_core.Iso_reason.t option
  (** with the return reason when the rail gives one *)
  | Cancelled
[@@deriving sexp, compare, equal]

(** The constructor name in lower case: ["draft"], ["failed"], ... *)
val name : t -> string

(** Every status name, in life-cycle order. *)
val names : string list

(** Every allowed [(from, to)] pair by status name. *)
val allowed_transitions : (string * string list) list

(** Whether the table allows moving from [from] to [to_]. Moving to the same status is
    never allowed. *)
val can_move : from:t -> to_:t -> bool

(** No transition leaves this status. [Settled] is not final: a settled payment can still
    be returned on a returnable rail; see {!is_resolved}. *)
val is_final : t -> bool

(** The batch has nothing more to do for this line: it is final, or settled on a rail that
    cannot return it. *)
val is_resolved : t -> rail:Payments_core.Rail.t -> bool

(** Before submission: the line can still be cancelled. *)
val is_cancellable : t -> bool

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
  end
end
