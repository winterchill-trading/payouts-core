(** Why a payout line failed. Failures before submission are ours (funding); failures
    after it come from the rail or the provider, with the scheme's reason code where there
    is one. *)

open! Core

type t =
  | Insufficient_funds of
      { required : Money.Amount.t
      ; available : Money.Amount.t
      } (** the funding account could not cover the line when it was funded *)
  | No_funding_account of Money.Currency.t
  (** no account to pay this currency from, and no conversion was offered *)
  | Conversion_unavailable of string
  (** the line's currency had to be bought first and the FX hook refused *)
  | Submission_refused of string
  (** the transfer could not be created or was refused before the rail accepted it *)
  | Rejected of Payments_core.Iso_reason.t (** the scheme rejected the payment *)
  | Transfer_failed of Payments_core.Transfer.Failure_reason.t
  (** the transfer failed on our side after submission (SCA, expiry, provider error) *)
[@@deriving sexp, compare, equal]

(** A short machine-readable code: ["insufficient_funds"], ["rejected"], ... *)
val code : t -> string

(** Whether the payee's details were at fault (a closed or wrong account), so paying again
    to the same details will fail again. *)
val is_payee_error : t -> bool

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
  end
end
