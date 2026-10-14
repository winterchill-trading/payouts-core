(** Reserving the money for approved lines, checked against ledger balances.

    {!plan} walks the batch's [Approved] lines in order and decides, for each, against the
    payer's available balance (what {!Ledger.Balances.available} reports, less what
    earlier lines of the same plan already took):
    - [Fund]: the account in the line's currency covers it; the plan carries the ledger
      entry that places a hold of the line's amount under {!Line_key.hold_id}, keyed
      [<line key>/fund];
    - [Convert]: the account is short but a {!Conversion.Hook.t} priced buying the amount
      with the source's funding currency, and that account covers the sold amount. The
      caller executes the conversion (crediting the line's account), then plans again with
      the conversion in [~converted], and the line is funded;
    - [Fail]: no account in the currency, a refused conversion, or not enough money.

    {!apply} moves the lines: funded lines to [Funded], failed lines to [Failed] (in
    {!Mode.Line_by_line}); lines waiting for a conversion stay [Approved].

    Book [entries] in one linked journal record before saving the batch. The ledger checks
    every hold again when it is booked, so two plans racing for the same money cannot both
    succeed: the second record is refused, and planning again from the new balances gives
    the right answer. *)

open! Core

module Mode : sig
  type t =
    | Line_by_line
    (** fund what fits, in line order; a line that does not fit fails on its own *)
    | All_or_nothing
    (** fund every line or none: any line that would fail refuses the whole plan and
        leaves every line [Approved] *)
  [@@deriving sexp, compare, equal]
end

(** Where the money comes from. *)
module Source : sig
  type t =
    { account_for : Money.Currency.t -> Ledger.Account_id.t option
    (** the payer's account in a currency, if it has one *)
    ; funding_currency : Money.Currency.t option
    (** the currency to buy a short currency with, through [conversion] *)
    ; conversion : Conversion.Hook.t
    }

  (** One account per currency, no conversion. *)
  val of_accounts : (Money.Currency.t * Ledger.Account_id.t) list -> t

  (** [of_accounts] that buys short currencies with [funding_currency] through [hook]. *)
  val with_conversion
    :  (Money.Currency.t * Ledger.Account_id.t) list
    -> funding_currency:Money.Currency.t
    -> hook:Conversion.Hook.t
    -> t
end

module Decision : sig
  type t =
    | Fund of
        { account : Ledger.Account_id.t
        ; conversion : Conversion.t option (** the conversion executed for it, if any *)
        }
    | Convert of
        { from_ : Ledger.Account_id.t (** the funding currency's account *)
        ; to_ : Ledger.Account_id.t (** the line's account, credited by the conversion *)
        ; conversion : Conversion.t
        }
    | Fail of Failure.t
  [@@deriving sexp_of]
end

module Plan : sig
  type t =
    | Planned of
        { decisions : (Line_id.t * Decision.t) list (** in line order *)
        ; entries : Ledger.Entry.t list (** the holds to book, in order *)
        }
    | Refused of (Line_id.t * Failure.t) list
    (** {!Mode.All_or_nothing} only: the lines that would fail *)
  [@@deriving sexp_of]

  (** Total held per currency by the plan's entries. *)
  val held : t -> Money.Amount.t list
end

(** Plans the batch's [Approved] lines (or only [lines], when given). [converted] lists
    the conversions the caller executed since the previous plan, by line. Fails when the
    batch is not approved, a listed line is unknown, or a hold entry cannot be built (an
    account that is not open in the ledger). *)
val plan
  :  Ledger.Balances.t
  -> Source.t
  -> Batch.t
  -> mode:Mode.t
  -> ?lines:Line_id.t list
  -> ?converted:(Line_id.t * Conversion.t) list
  -> now:Time_ns.t
  -> unit
  -> Plan.t Or_error.t

(** Moves lines as the plan decided. A [Refused] plan changes nothing. *)
val apply : Batch.t -> Plan.t -> now:Time_ns.t -> Batch.t Or_error.t

(** The entry that returns a funded line's hold to its account, keyed
    [<line key>/release]: book it when a funded line is cancelled or fails before
    submission. *)
val release : Ledger.Balances.t -> Line.t -> now:Time_ns.t -> Ledger.Entry.t Or_error.t
