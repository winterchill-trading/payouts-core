open! Core

module Insert_result = struct
  type t =
    | Inserted
    | Duplicate of Batch.t
    | Conflict of string
  [@@deriving sexp_of]
end

module Update_result = struct
  type t =
    | Updated
    | Stale of Batch.t
    | Not_found
  [@@deriving sexp_of]
end

let same_request (a : Batch.t) (b : Batch.t) =
  Batch_id.equal a.id b.id
  && String.equal a.title b.title
  && Actor_id.equal a.created_by b.created_by
  && List.equal Line.same_content a.lines b.lines
;;

module type S = sig
  type 'a io
  type t

  val insert : t -> Batch.t -> Insert_result.t io
  val find : t -> Batch_id.t -> Batch.t option io
  val update : t -> Batch.t -> expected_revision:int -> Update_result.t io
  val find_by_line_key : t -> Line_key.t -> (Batch_id.t * Line_id.t) option io

  val find_by_transfer
    :  t
    -> Payments_core.Transfer.Id.t
    -> (Batch_id.t * Line_id.t) option io

  val list : t -> ?progress:Batch.Progress.t -> unit -> Batch.t list io
  val lines_in : t -> string -> (Batch_id.t * Line_id.t) list io
end
