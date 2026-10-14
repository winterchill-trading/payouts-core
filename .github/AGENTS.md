# .github/AGENTS.md

`workflows/ci.yml` builds and tests on `ubuntu-latest` through the infra `ox-setup`
composite action, which caches the OxCaml switch and pins sibling repositories.

- The `pins` list must follow the dependency order (`fixed-decimal`, `money`, `ledger`,
  `payments-core`) and include every org package named in `dune-project`.
- The docs step fails on any odoc warning.
- Check runs with `gh run list --limit 1` and at most one
  `gh run watch <id> --exit-status`; never poll in a loop.
