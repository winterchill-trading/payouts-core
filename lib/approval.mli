(** Who must approve a batch before any of it is paid.

    A batch is approved as a whole: one decision covers every line. How many approvals it
    needs and who may give them is a {!Policy.t}, a pair of functions, so an
    organisation's own roles and permissions plug in without this library knowing them.
    Two rules hold whatever the policy says:
    - maker-checker: the batch's creator never approves it;
    - each person approves a batch at most once, so two approvals are two people. *)

open! Core

(** What a policy sees of a batch. *)
module Summary : sig
  type t =
    { batch : Batch_id.t
    ; created_by : Actor_id.t
    ; totals : Money.Amount.t list
    (** one per currency, sorted by currency; cancelled lines excluded *)
    ; line_count : int (** lines not cancelled *)
    ; rails : Payments_core.Rail.t list (** distinct, sorted *)
    }
  [@@deriving sexp_of]
end

(** Why an approval (or a rejection, or a cancellation) was refused. *)
module Refusal : sig
  type t =
    | Not_pending (** the batch was already approved, rejected or cancelled *)
    | Own_batch (** maker-checker: the creator cannot approve *)
    | Already_approved (** this person approved already *)
    | Not_allowed of string (** the policy's [authorize] refused, with its reason *)
  [@@deriving sexp, compare, equal]

  (** ["not_pending"], ["own_batch"], ["already_approved"], ["not_allowed"]. *)
  val code : t -> string
end

module Policy : sig
  type t =
    { required_approvals : Summary.t -> int
    (** how many different people must approve; [0] approves the batch when it is created *)
    ; authorize : Summary.t -> approver:Actor_id.t -> (unit, string) Result.t
    (** whether this person may approve, reject or cancel someone else's batch: a role or
        permission check *)
    }

  (** One approval from anyone but the creator. *)
  val one_approval : t

  (** Per-currency thresholds. A batch needs no approval when every currency's total is at
      most [auto_approve_up_to] for that currency, two approvals when any currency's total
      is above [second_approver_above], and one otherwise. A currency without a threshold
      ([None]) never auto-approves and never needs a second approver. [authorize] defaults
      to allowing everyone. *)
  val thresholds
    :  ?auto_approve_up_to:(Money.Currency.t -> Money.Amount.t option)
    -> ?second_approver_above:(Money.Currency.t -> Money.Amount.t option)
    -> ?authorize:(Actor_id.t -> (unit, string) Result.t)
    -> unit
    -> t

  (** [required_approvals], never below zero. *)
  val required : t -> Summary.t -> int
end
