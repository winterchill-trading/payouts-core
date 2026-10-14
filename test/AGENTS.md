# test/AGENTS.md

Inline expect tests and Quickcheck properties for `payouts-core`, in one test library.

- `helpers.ml` holds fixtures: payees, lines, batches, and pure ledger balances with the
  organisation's accounts (`ledger`, `book`, `convert`). Book entries in time order.
- `test_stable.ml` pins bin_prot digests; a changed digest means a new `Stable` version,
  not a new pin.
- `test_properties.ml` holds the Quickcheck invariants (line table, approvals, funding
  never over-commits, totals add up).
- `test_store.ml` runs `Store_conformance` on `Store_memory`.

Run and promote from the repository root:
`opam exec --switch 5.2.0+ox -- dune build --root .. @payouts-core/runtest`, then
`opam exec --switch 5.2.0+ox -- dune promote --root ..` after reading the diff.
