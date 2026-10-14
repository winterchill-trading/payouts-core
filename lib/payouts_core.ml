(** Payout batches across rails and currencies. *)

(** Batch identifiers. *)
module Batch_id = Batch_id

(** Line identifiers, unique within a batch. *)
module Line_id = Line_id

(** Who created or approved a batch. *)
module Actor_id = Actor_id

(** Per-line idempotency keys and the ledger keys derived from them. *)
module Line_key = Line_key

(** Why a line failed. *)
module Failure = Failure

(** The line state machine. *)
module Line_status = Line_status

(** Buying a line's currency through an FX hook. *)
module Conversion = Conversion

(** One payment of a batch. *)
module Line = Line

(** Batch approval policies (a hook) and refusals. *)
module Approval = Approval

(** Batches: approval, cancellation, derived progress. *)
module Batch = Batch
