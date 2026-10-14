(lang dune 3.17)

(name payouts-core)

(generate_opam_files true)

(license MIT)

(authors "WinterChill AI")

(maintainers "hello@winterchill.xyz")

(source
 (github winterchill-trading/payouts-core))

(homepage "https://github.com/winterchill-trading/payouts-core")

(bug_reports "https://github.com/winterchill-trading/payouts-core/issues")

(documentation "https://github.com/winterchill-trading/payouts-core#readme")

(package
 (name payouts-core)
 (synopsis
  "Payout batches across rails and currencies, with approval, funding and receipts")
 (description
  "payouts-core models a batch of outgoing payments to many payees, possibly on several rails and in several currencies. Each line follows a pure state machine (draft, approved, funded, submitted, settled, failed, returned, cancelled) and carries its own idempotency key. Batches are approved as a whole through a policy hook (per-currency thresholds, a second approver above a limit, maker-checker); funding checks lines against ledger balances and reserves them with ledger holds, with a hook for lines whose currency must be bought first. Lines fail independently, so a batch can finish with some payments settled and others failed. Receipts are plain values, batch totals reconcile against transfers and ledger holds, and persistence is a Store module type with an in-memory implementation. Requires the OxCaml compiler.")
 (tags
  (payments payouts batch payroll ledger oxcaml))
 (depends
  oxcaml
  (ocaml
   (and
    (>= 5.2.0)
    (< 5.3~)))
  dune
  (core
   (and
    (>= v0.18~preview.130.106+341)
    (< v0.19~)))
  (ppx_jane
   (and
    (>= v0.18~preview.130.106+341)
    (< v0.19~)))
  zarith
  money
  ledger
  payments-core
  (base_quickcheck :with-test)
  (odoc :with-doc)))
