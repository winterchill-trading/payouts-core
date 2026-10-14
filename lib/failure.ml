open! Core

module Stable = struct
  module V1 = struct
    type t =
      | Insufficient_funds of
          { required : Money.Amount.Stable.V1.t
          ; available : Money.Amount.Stable.V1.t
          }
      | No_funding_account of Money.Currency.Stable.V1.t
      | Conversion_unavailable of string
      | Submission_refused of string
      | Rejected of Payments_core.Iso_reason.Stable.V1.t
      | Transfer_failed of Payments_core.Transfer.Failure_reason.t
    [@@deriving bin_io, sexp, compare, equal]
  end
end

include Stable.V1

let code = function
  | Insufficient_funds _ -> "insufficient_funds"
  | No_funding_account _ -> "no_funding_account"
  | Conversion_unavailable _ -> "conversion_unavailable"
  | Submission_refused _ -> "submission_refused"
  | Rejected _ -> "rejected"
  | Transfer_failed _ -> "transfer_failed"
;;

let is_payee_error = function
  | Rejected reason -> Payments_core.Iso_reason.is_customer_error reason
  | Insufficient_funds _
  | No_funding_account _
  | Conversion_unavailable _
  | Submission_refused _
  | Transfer_failed _ -> false
;;
