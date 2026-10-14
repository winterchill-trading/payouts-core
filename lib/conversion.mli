(** Buying a line's currency with another currency the payer holds.

    payouts-core does not price foreign exchange. When a line is in a currency the payer
    has no account in (or not enough of), funding asks a {!Hook.t} for a firm price to
    buy exactly the line's amount; the caller executes that conversion through its FX
    library and funds the line from the bought currency afterwards. A rate library that
    makes buy-fixed quotes plugs in by mapping its quote id, sold and bought amounts onto
    {!t}. *)

open! Core

type t =
  { quote_ref : string (** the FX library's quote id, to execute it later *)
  ; sell : Money.Amount.t (** taken from the funding currency, fees included *)
  ; buy : Money.Amount.t (** exactly the amount the line needs *)
  }
[@@deriving sexp, compare, equal]

module Hook : sig
  type conversion := t

  (** [quote ~sell ~buy] prices buying [buy] with currency [sell]. An [Error] is shown
      to people as the reason the line could not be funded (no rate, a stale rate, an
      amount too small). *)
  type t = { quote : sell:Money.Currency.t -> buy:Money.Amount.t -> (conversion, string) Result.t }

  (** Refuses every conversion: lines are funded only in currencies already held. *)
  val none : t

  (** Prices from fixed rates, for tests and examples. [(sell, buy, rate)] means one unit
      of [sell] buys [rate] units of [buy]; the sold amount is [buy / rate] rounded up to
      the sold currency's minor unit, so the payer never gets more than it paid for. The
      quote ref is [fixed:<sell>:<buy>]. *)
  val fixed_rates : (Money.Currency.t * Money.Currency.t * Q.t) list -> t
end

(** Checks what a hook returned: the bought amount is exactly [buy], the sold amount is
    positive and in [sell], and the two currencies differ. *)
val validate : t -> sell:Money.Currency.t -> buy:Money.Amount.t -> unit Or_error.t

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
  end
end
