# examples/AGENTS.md

`quickstart.ml` runs a batch end to end on pure ledger balances: approval with two
approvers, funding with a conversion, submission, one settlement and one rejection,
receipts and reconciliation.

The `runtest` alias diffs its output against `quickstart.expected`, so CI fails when the
behaviour changes. After an intended change, regenerate the file with
`opam exec --switch 5.2.0+ox -- dune build --root .. @payouts-core/runtest` and
`dune promote --root ..` from the repository root, and read the diff first.
