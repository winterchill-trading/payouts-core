(** An in-memory {!Store.S} for tests, examples and offline modes. Every call completes at
    once, so each is trivially atomic within one process. *)

open! Core

module Make (M : Monad.S) : sig
  include Store.S with type 'a io = 'a M.t

  val create : unit -> t
end
