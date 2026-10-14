(** Fixtures shared by the tests. *)

open! Core
open Payouts_core

val t0 : Time_ns.t

(** [t0] plus [n] minutes. *)
val at : int -> Time_ns.t

val eur : string -> Money.Amount.t
val chf : string -> Money.Amount.t
val usdc : string -> Money.Amount.t

(** A SEPA payee with a valid German IBAN. *)
val sepa_payee : string -> Payments_core.Beneficiary.t

(** An intraledger payee (any currency). *)
val internal_payee : string -> Payments_core.Beneficiary.t

(** A draft line: SEPA for EUR amounts, intraledger otherwise. *)
val line : ?reference:string -> string -> Money.Amount.t -> Line.t

val maker : Actor_id.t
val checker : Actor_id.t
val second_checker : Actor_id.t

(** A pending batch under {!Approval.Policy.one_approval}. *)
val batch : ?id:string -> Line.t list -> Batch.t

(** {!batch}, approved by {!checker}. *)
val approved_batch : ?id:string -> Line.t list -> Batch.t

val print_batch : Batch.t -> unit
