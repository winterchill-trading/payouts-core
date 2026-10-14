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

(** {2 Ledger fixtures} *)

(** [org:1/<currency>], e.g. [org:1/eur]. *)
val org_account : Money.Currency.t -> Ledger.Account_id.t

(** Balances with [org:1/eur], [org:1/chf] and [org:1/usdc] open (liabilities), a cash
    account allowed to go negative, the default chart's settlement and fee accounts, and
    one deposit per positive amount into the org account of its currency. *)
val ledger : Money.Amount.t list -> Ledger.Balances.t

(** Applies entries as a journal would; raises on a refusal. *)
val book : Ledger.Balances.t -> Ledger.Entry.t list -> Ledger.Balances.t

(** Moves [sell] out of the org's account in its currency and [buy] into the org's account
    in its currency, as an executed conversion would. *)
val convert
  :  Ledger.Balances.t
  -> sell:Money.Amount.t
  -> buy:Money.Amount.t
  -> at:Time_ns.t
  -> Ledger.Balances.t

val available : Ledger.Balances.t -> Money.Currency.t -> string
