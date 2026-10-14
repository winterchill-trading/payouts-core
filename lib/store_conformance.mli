(** Scenarios every {!Store.S} implementation must pass: insert, retried insert,
    conflicting ids and line keys, compare-and-set updates, the line-key and transfer
    indexes, listing by progress and the per-status work queue. A service runs them
    against its database store in its own test suite, next to {!Store_memory}.

    Give it a fresh, empty store; the scenarios use batch ids and line keys starting with
    [conformance-]. *)

open! Core

module Make (M : Monad.S) (Store : Store.S with type 'a io := 'a M.t) : sig
  (** [Ok ()] when every scenario passes, otherwise the first difference. *)
  val check : Store.t -> unit Or_error.t M.t
end
