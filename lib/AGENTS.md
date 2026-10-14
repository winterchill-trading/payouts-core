# lib/AGENTS.md

The `payouts-core` library (`Payouts_core`). `payouts_core.ml` re-exports every module
with a one-line doc; add new modules there.

- Every module has an `.mli` with odoc on each value; persisted types have a `Stable`
  module whose digest is pinned in `../test/test_stable.ml`.
- Transitions go through `Line_status.can_move`; do not set a line's status any other
  way. `Batch.update_line` is the only way to change a line of an approved batch.
- Functions that produce ledger entries build them against the `Ledger.Balances.t` they
  are given and fold them with `Payments_core.Booking.apply`, so each entry is checked
  as the journal will check it.
- `Store_conformance` is part of the public API: a store implementation in a service
  runs it, so keep its scenarios independent of `Store_memory` details.

Build: `opam exec --switch 5.2.0+ox -- dune build --root ../.. @payouts-core/all` from
here, or the commands in `../AGENTS.md` from the repository root.
