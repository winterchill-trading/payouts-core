open! Core

module Raw =
  Ledger.Validated_id.Make
    (struct
      let module_name = "Payouts_core.Line_key"
    end)
    ()

let max_length = 112

let of_string_or_error s =
  if String.length s > max_length
  then
    Or_error.error_s
      [%message "line key too long" (max_length : int) ~length:(String.length s : int)]
  else Or_error.map (Raw.of_string_or_error s) ~f:Raw.to_string
;;

module T = struct
  type t = string [@@deriving bin_io, compare, equal, hash]

  let to_string t = t
  let of_string s = Or_error.ok_exn (of_string_or_error s)
  let sexp_of_t t = String.sexp_of_t t
  let t_of_sexp sexp = of_string (String.t_of_sexp sexp)
  let module_name = "Payouts_core.Line_key"
end

include T
include Identifiable.Make (T)

let quickcheck_generator =
  Quickcheck.Generator.map (Int.gen_incl 0 99_999) ~f:(sprintf "line-%05d")
;;

let quickcheck_observer = String.quickcheck_observer
let quickcheck_shrinker = Quickcheck.Shrinker.empty ()

module Leg = struct
  type t =
    | Fund
    | Release
    | Submit
  [@@deriving sexp, compare, equal, enumerate]

  let to_string = function
    | Fund -> "fund"
    | Release -> "release"
    | Submit -> "submit"
  ;;
end

(* Both ids stay within the ledger's 128 characters because [max_length] is 112. *)
let derive t leg = Ledger.Idempotency_key.of_string (t ^ "/" ^ Leg.to_string leg)
let hold_id t = Ledger.Hold_id.of_string ("payout:" ^ t)

module Stable = struct
  module V1 = T
end
