(** The idempotency key of one payout line, chosen by the caller, typically from the
    request that created the line.

    A key names one payment for good: a store refuses a second line with the same key and
    different content, in any batch, so a retried request cannot pay a payee twice. Every
    ledger entry the line causes derives its key from it ([<key>/fund], [<key>/release],
    [<key>/submit]), and so does the ledger hold that reserves its funds ([payout:<key>]).

    A key uses the ledger id alphabet ([A-Z a-z 0-9 _ - . : / @ +]) and is at most
    {!max_length} characters, which leaves room for the derived suffixes within the
    ledger's 128-character limit. *)

open! Core

type t [@@deriving quickcheck]

include Identifiable.S with type t := t

(** 112 characters. *)
val max_length : int

(** [of_string] raises on an invalid key; this is the non-raising form. *)
val of_string_or_error : string -> t Or_error.t

(** The ledger entries a line books, each under its own derived key. *)
module Leg : sig
  type t =
    | Fund (** the hold that reserves the line's funds *)
    | Release (** the release of that hold (cancelled, failed or moved to the transfer) *)
    | Submit (** the entries booked when the transfer is submitted *)
  [@@deriving sexp, compare, equal, enumerate]

  (** ["fund"], ["release"], ["submit"]. *)
  val to_string : t -> string
end

(** [<key>/<leg>]. *)
val derive : t -> Leg.t -> Ledger.Idempotency_key.t

(** [payout:<key>]: the ledger hold that reserves the line's funds once it is funded. *)
val hold_id : t -> Ledger.Hold_id.t

module Stable : sig
  module V1 : sig
    (** Bin_prot is the plain string; reading validates again. *)
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal, hash]
  end
end
