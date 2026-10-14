(** A batch of payout lines approved together and then paid line by line.

    {2 Life}

    A batch starts [Pending_approval] with every line [Draft]. Approvals are collected
    under an {!Approval.Policy.t}; when enough different people have approved, the batch
    becomes [Approved] and every draft line [Approved] in the same step. A pending batch
    can instead be rejected (with a note) or cancelled, which cancels its lines.

    {2 Partial failure}

    After approval each line goes its own way: funding, submission and the rail's answer
    are per line, and a line that fails never undoes another. Nothing is rolled back: a
    settled line stays settled when its neighbour is rejected by the payee's bank. The
    batch's {!Progress.t} is derived from its lines and reports [Completed],
    [Completed_with_failures] or [Failed] once every line is done.

    {2 Revisions}

    Every successful change increments [revision], so a store can refuse a write based on
    a stale read ({!Store.S.update}). *)

open! Core

module Status : sig
  (** The decision on the batch. *)
  type t =
    | Pending_approval
    | Approved
    | Rejected of
        { by : Actor_id.t
        ; note : string
        }
    | Cancelled of { by : Actor_id.t }
  [@@deriving sexp, compare, equal]

  (** ["pending_approval"], ["approved"], ["rejected"], ["cancelled"]. *)
  val name : t -> string
end

module Progress : sig
  (** What the batch shows, derived from its status and its lines. *)
  type t =
    | Awaiting_approval
    | Processing (** approved, some lines still on their way *)
    | Completed (** every line not cancelled settled *)
    | Completed_with_failures (** some settled, some failed or returned *)
    | Failed (** none settled *)
    | Rejected
    | Cancelled (** cancelled before approval, or every line cancelled *)
  [@@deriving sexp, compare, equal, enumerate]

  (** ["awaiting_approval"], ["processing"], ... *)
  val name : t -> string
end

module Approval_record : sig
  type t =
    { by : Actor_id.t
    ; at : Payments_core.Utc_time.t
    }
  [@@deriving sexp, compare, equal]
end

type t = private
  { id : Batch_id.t
  ; title : string
  ; created_by : Actor_id.t
  ; created_at : Payments_core.Utc_time.t
  ; lines : Line.t list (** in the order given at creation *)
  ; approvals_required : int
  ; approvals : Approval_record.t list (** oldest first *)
  ; status : Status.t
  ; decided_at : Payments_core.Utc_time.t option
  (** when the batch was approved, rejected or cancelled *)
  ; revision : int (** 0 at creation, + 1 on every change *)
  }
[@@deriving sexp, compare, equal]

(** 1000. *)
val max_lines : int

(** 140 characters. *)
val max_title_length : int

(** A batch of [Draft] lines. Fails on no lines or more than {!max_lines}, a line that is
    not a draft, two lines with the same id or the same key, or an empty or too long
    title. The policy fixes how many approvals are needed; with none, the batch is
    approved at once. *)
val create
  :  id:Batch_id.t
  -> title:string
  -> created_by:Actor_id.t
  -> lines:Line.t list
  -> policy:Approval.Policy.t
  -> now:Time_ns.t
  -> t Or_error.t

(** What a policy sees. *)
val summary : t -> Approval.Summary.t

(** Totals per currency of the lines not cancelled, sorted by currency. *)
val totals : t -> Money.Amount.t list

(** Whether [approver] may approve now, without changing anything. *)
val can_approve
  :  t
  -> policy:Approval.Policy.t
  -> approver:Actor_id.t
  -> (unit, Approval.Refusal.t) Result.t

(** Records an approval. The last one needed approves the batch and its lines. *)
val approve
  :  t
  -> policy:Approval.Policy.t
  -> approver:Actor_id.t
  -> now:Time_ns.t
  -> (t, Approval.Refusal.t) Result.t

(** Rejects a pending batch; its lines are cancelled. The creator may not reject their own
    batch (they cancel it instead); others need the policy's [authorize]. *)
val reject
  :  t
  -> policy:Approval.Policy.t
  -> by:Actor_id.t
  -> note:string
  -> now:Time_ns.t
  -> (t, Approval.Refusal.t) Result.t

(** Cancels a pending batch; its lines are cancelled. The creator may always cancel;
    anyone else needs the policy's [authorize]. *)
val cancel
  :  t
  -> policy:Approval.Policy.t
  -> by:Actor_id.t
  -> now:Time_ns.t
  -> (t, Approval.Refusal.t) Result.t

(** The derived progress. *)
val progress : t -> Progress.t

(** {2 Lines} *)

val find_line : t -> Line_id.t -> Line.t option
val find_line_by_key : t -> Line_key.t -> Line.t option

(** The line paid by this transfer. *)
val find_line_by_transfer : t -> Payments_core.Transfer.Id.t -> Line.t option

(** Lines in a status with this name ({!Line_status.name}), in order. *)
val lines_in : t -> string -> Line.t list

(** Cancels one line. Before approval the batch's approvals are cleared and the number
    required is computed again, as the batch is no longer what was approved; cancelling
    the last line leaves a batch whose progress is [Cancelled]. A changed batch needs at
    least one approval even when the policy would now approve it at once. After approval
    only a line not yet submitted can be cancelled; a funded line's hold must be released
    with {!Funding.release}. *)
val cancel_line
  :  t
  -> policy:Approval.Policy.t
  -> Line_id.t
  -> now:Time_ns.t
  -> t Or_error.t

(** Applies [f] to one line of an approved batch and keeps the result if the line kept its
    id and key. The building block of {!Funding}, {!Submission} and transfer updates. *)
val update_line : t -> Line_id.t -> f:(Line.t -> Line.t Or_error.t) -> t Or_error.t

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal]
  end
end
