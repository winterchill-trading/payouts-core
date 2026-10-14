(** Checking a batch against the ledger and the transfers that pay it.

    {!Totals} splits each currency's requested amount over the line statuses; every line
    is in exactly one bucket, so the buckets add up to what was requested
    ({!Totals.check}). {!check} then compares the batch with the outside world and lists
    every difference without fixing any:
    - a funded line's hold must be open in the ledger for exactly the line's amount, and
      the hold of a line past [Funded] must be used up;
    - a submitted line's transfer must exist, pay the line's amount, and be in a status
      the line already reflects;
    - per currency, the settled total of the batch must equal the total of its settled
      transfers. *)

open! Core

module Totals : sig
  type t =
    { currency : Money.Currency.t
    ; lines : int
    ; requested : Money.Amount.t (** every line, cancelled ones included *)
    ; awaiting : Money.Amount.t (** draft or approved *)
    ; funded : Money.Amount.t
    ; submitted : Money.Amount.t
    ; settled : Money.Amount.t
    ; failed : Money.Amount.t
    ; returned : Money.Amount.t
    ; cancelled : Money.Amount.t
    }
  [@@deriving sexp, compare, equal]

  (** One row per currency, sorted by currency. *)
  val of_batch : Batch.t -> t list

  (** [requested] equals the sum of the other buckets. *)
  val check : t -> unit Or_error.t
end

module Diff : sig
  type t =
    | Hold_missing of
        { line : Line_id.t
        ; hold : Ledger.Hold_id.t
        } (** the line is funded but the ledger has no such hold *)
    | Hold_amount_mismatch of
        { line : Line_id.t
        ; hold : Ledger.Hold_id.t
        ; line_amount : Money.Amount.t
        ; held : Money.Amount.t (** what remains of the hold *)
        }
    | Hold_left_open of
        { line : Line_id.t
        ; hold : Ledger.Hold_id.t
        ; held : Money.Amount.t
        } (** the line moved past funding but its hold still reserves money *)
    | Transfer_missing of
        { line : Line_id.t
        ; transfer : Payments_core.Transfer.Id.t
        }
    | Transfer_amount_mismatch of
        { line : Line_id.t
        ; transfer : Payments_core.Transfer.Id.t
        ; line_amount : Money.Amount.t
        ; transfer_amount : Money.Amount.t
        }
    | Status_mismatch of
        { line : Line_id.t
        ; transfer : Payments_core.Transfer.Id.t
        ; line_status : Line_status.t
        ; transfer_status : Payments_core.Transfer.Status.t
        } (** the transfer moved on and the line did not follow, or they contradict *)
    | Settled_total_mismatch of
        { currency : Money.Currency.t
        ; batch : Money.Amount.t
        ; transfers : Money.Amount.t
        }
  [@@deriving sexp_of, compare, equal]
end

(** Every difference, line by line in batch order, then per currency. [transfers] may
    include transfers of other batches; they are ignored. *)
val check
  :  Batch.t
  -> balances:Ledger.Balances.t
  -> transfers:Payments_core.Transfer.t list
  -> Diff.t list
