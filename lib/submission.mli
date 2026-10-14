(** Handing a funded line to its rail as a {!Payments_core.Transfer.t}.

    The line's money is already reserved by the funding hold. Submitting moves that
    reservation to the transfer in one step: the funding hold is released (keyed
    [<line key>/submit]) and the transfer's own hold is placed by
    {!Payments_core.Booking.transition}, so from then on payments-core books the
    settlement, rejection or return of the transfer as it would for any other payment.
    Book the returned entries in one linked journal record: the available balance never
    shows the amount twice, nor frees it in between. *)

open! Core

(** An outgoing transfer draft for the line, debiting its funding account. SEPA rails need
    [details] (the pacs.008 fields); other rails fill theirs in. The transfer still needs
    an authorization (an SCA challenge or a recorded exemption) before it can be
    submitted. Fails when the line is not funded. *)
val draft_transfer
  :  Line.t
  -> id:Payments_core.Transfer.Id.t
  -> ?details:Payments_core.Transfer.Details.t
  -> now:Time_ns.t
  -> unit
  -> Payments_core.Transfer.t Or_error.t

(** Moves the line to [Submitted] and returns the ledger entries to book. [transfer] is
    the authorized transfer about to be sent (status [Draft] or [Awaiting_sca]); it must
    pay the line's payee the line's amount on the line's rail, from the funding account.
    [event_id] keys the transfer's own entries ([<event id>/<leg>], as payments-core
    does). Fails when the line is not [Funded], the transfer does not match, or an entry
    breaks a ledger rule. *)
val submit
  :  Payments_core.Booking.Chart.t
  -> Ledger.Balances.t
  -> Batch.t
  -> Line_id.t
  -> transfer:Payments_core.Transfer.t
  -> event_id:string
  -> now:Time_ns.t
  -> (Batch.t * Ledger.Entry.t list) Or_error.t

(** Applies a transfer's new status to the line it pays ({!Line.observe}). Fails when no
    line of the batch is paid by it. The ledger side of the transition is
    {!Payments_core.Booking.transition}, which the caller books as for any transfer. *)
val observe : Batch.t -> Payments_core.Transfer.t -> now:Time_ns.t -> Batch.t Or_error.t
