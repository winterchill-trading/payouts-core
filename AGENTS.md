# AGENTS.md

Guide for AI coding agents working in this repository. Read this first; the subdirectory
`AGENTS.md` files add detail for `lib/`, `test/`, `examples/` and `.github/`. The
workspace-wide guide is `../oxcaml-claude-skills/AGENTS.md`.

## Purpose

`payouts-core` models batches of outgoing payments to many payees across rails and
currencies: a pure line state machine, batch approval through a policy hook, funding
against `ledger` balances with holds, submission as `payments-core` transfers, receipts
and reconciliation. It never persists anything itself: storage is the `Store.S` module
type, with an in-memory implementation and conformance scenarios.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | The `payouts-core` library (`Payouts_core`): ids, `Line_key`, `Line_status`, `Failure`, `Line`, `Approval`, `Batch`, `Conversion`, `Funding`, `Submission`, `Receipt`, `Reconciliation`, `Store`, `Store_memory`, `Store_conformance` |
| `test/` | Expect tests, Base_quickcheck properties, pinned stable digests, store conformance |
| `examples/` | `quickstart.ml`, whose output is diffed against `quickstart.expected` in `runtest` |
| `.github/` | CI workflow |
| `dune-project` | Source of truth for package metadata; `dune build` regenerates `payouts-core.opam` |

## Build, test, docs

Inside the workspace (sibling checkouts and the shared `5.2.0+ox` switch are required),
from this directory:

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @payouts-core/all
opam exec --switch 5.2.0+ox -- dune build --root .. @payouts-core/runtest
opam exec --switch 5.2.0+ox -- dune build --root .. @payouts-core/doc
```

Parallel work: prefix the commands with `DUNE_BUILD_DIR=_build-payouts-core` (resolved from
the workspace root because of `--root ..`; `../_build-payouts-core` fails with "path
outside the workspace"). Promote expect output with
`opam exec --switch 5.2.0+ox -- dune promote --root ..` (same `DUNE_BUILD_DIR`).

Standalone: `opam repo add winterchill https://github.com/winterchill-trading/opam-repository.git`,
then `opam install --deps-only --with-test .` and `dune build && dune test`.

## Conventions

- Every module has an `.mli` with odoc on every public value; `open! Core`, labelled
  arguments, ppx_jane derivations.
- Pure functions: every operation takes a value and returns a new one (or the ledger
  entries to book); nothing reads a clock, a database or the network.
- Persisted types (`Line`, `Batch`, `Receipt`, `Failure`, `Line_status`, `Conversion`,
  the ids) have `Stable.V1` with digests pinned in `test/test_stable.ml`. Add a `V2`
  rather than editing a pinned version. Rails and payees are embedded in their
  `payments-core` `Stable.V2` form.
- Times inside records are `Payments_core.Utc_time.t`, so sexps print in UTC everywhere.
- Every ledger key a line causes derives from its `Line_key` (`Line_key.derive`); never
  build ledger keys from clocks or counters.
- Expect tests plus Quickcheck (`Quickcheck.test` in `let%test_unit`) for invariants.
- Comments for humans at non-obvious choices (wildcards kept on purpose, silenced
  warnings).
- Formatting: `opam exec --switch 5.2.0+ox -- dune build --root .. @payouts-core/fmt --auto-promote`.
  Never run `dune fmt` at the workspace root.
- User-visible changes get a line under "Unreleased" in `CHANGES.md`.

## Dependencies and dependents

- Depends on `money`, `ledger` and `payments-core` (and `fixed-decimal` through `money`),
  plus `core`, `ppx_jane`, `zarith`.
- CI pin order: `fixed-decimal`, `money`, `ledger`, `payments-core`.
- No org repository depends on it yet.

## CI

`.github/workflows/ci.yml` runs the infra `ox-setup` action (cached switch, sibling pins),
then `dune build`, `dune test` (which also diffs the example's output), an odoc build that
fails on warnings, and the shared `obj-magic` workflow. Check a run with
`gh run list --limit 1`, then at most one `gh run watch <id> --exit-status`.

## Pitfalls

- `payments-core` adds rails and payee destinations over time. Matches on them keep a
  wildcard (`Line.rail_currency`, `Receipt.mask_destination`); in the receipt the
  wildcard sits under `[@warning "-11"]` so it compiles whether or not the match is
  already complete.
- The unversioned `bin_io` of `Rail` and `Beneficiary` is their V1 format, which raises
  on UK values; embed `Stable.V2`.
- Inside `Store_conformance.Make` the functor argument `Store` hides the library module
  of the same name; the result types are reached through the `Results` alias.
- A constructor returned through `M.return (match ... )` is not disambiguated by the
  expected type: annotate the match (`: Store.Insert_result.t`).
- `[%message "..." ~max_length]` without a type annotation assumes a string; write
  `(max_length : int)`.
- Ledger fixtures must book in time order: `Balances.apply` refuses a `recorded_at`
  earlier than the last record.
- Another repository's broken `dune` file can stop a workspace build before this
  repository's tests run; check that the expected test output actually appeared.

## Where to read more

- `README.md`: why separate, quick start, modules, money flow, FX hook, storage, known
  gaps.
- `../specs/repos/payouts-core.md` once written.
- `../oxcaml-claude-skills/skills/banking-standards/` and
  `../oxcaml-claude-skills/skills/janestreet-ocaml-style/`.
- `../oxcaml-claude-skills/GOTCHAS.md`, section "Product libraries".
- `../oxcaml-claude-skills/AGENTS.md`, the workspace-wide guide.

## Never do

- Install or upgrade opam packages that change the compiler, `core`, `base`, `async` or
  `ppx_jane` on the shared switch. Run `opam install --switch 5.2.0+ox --dry-run <pkg>`
  first and stop if the plan touches any of them.
- Publish, tag or release.
- Add persistence, a clock or a network call to the library; services own those.
- Commit credentials, print secrets, or poll CI in a loop.
