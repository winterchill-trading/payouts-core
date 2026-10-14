(** Where batches live. Libraries never persist: a service implements this signature over
    its database, and {!Store_memory} serves tests and offline modes.

    Two guarantees carry the library's idempotency:
    - a line key belongs to one line for good: {!S.insert} refuses a batch that reuses a
      key already stored in another batch, so a retried request cannot create a second
      payment;
    - writes are compare-and-set on {!Batch.t.revision}: {!S.update} refuses a batch
      computed from a stale read, so two workers cannot both fund or submit a line.
      Re-read, re-apply the operation and write again. *)

open! Core

module Insert_result : sig
  type t =
    | Inserted
    | Duplicate of Batch.t
    (** a batch with this id and the same content exists: a retried request; the stored
        batch is returned as it is now *)
    | Conflict of string
    (** the id is taken by a different batch, or a line key belongs to another batch *)
  [@@deriving sexp_of]
end

module Update_result : sig
  type t =
    | Updated
    | Stale of Batch.t (** the stored batch moved on; here it is *)
    | Not_found
  [@@deriving sexp_of]
end

(** Same id, title, creator and lines with {!Line.same_content}, in order: what
    {!S.insert} treats as a retry. *)
val same_request : Batch.t -> Batch.t -> bool

module type S = sig
  type 'a io
  type t

  (** Stores a new batch, atomically with its line keys. *)
  val insert : t -> Batch.t -> Insert_result.t io

  val find : t -> Batch_id.t -> Batch.t option io

  (** Replaces the stored batch with [batch] when the stored revision is
      [expected_revision], and keeps the line and transfer indexes in step. *)
  val update : t -> Batch.t -> expected_revision:int -> Update_result.t io

  (** The batch and line a line key belongs to. *)
  val find_by_line_key : t -> Line_key.t -> (Batch_id.t * Line_id.t) option io

  (** The batch and line a transfer pays, for provider events that only name the transfer. *)
  val find_by_transfer
    :  t
    -> Payments_core.Transfer.Id.t
    -> (Batch_id.t * Line_id.t) option io

  (** Batches, oldest first (by creation time, then id), optionally only those with this
      progress. *)
  val list : t -> ?progress:Batch.Progress.t -> unit -> Batch.t list io

  (** Lines in a status with this name ({!Line_status.name}) across every batch, in batch
      order then line order: the work queue of a funding or submission worker. *)
  val lines_in : t -> string -> (Batch_id.t * Line_id.t) list io
end
