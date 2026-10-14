# Changes

## Unreleased

## 0.1.0

- Payout lines with a pure state machine (`Line`, `Line_status`, `Failure`) and per-line
  idempotency keys (`Line_key`) from which every ledger key is derived.
- Batches approved as a whole through a policy hook (`Approval.Policy`), with
  per-currency thresholds, maker-checker and one approval per person; rejection,
  cancellation and derived progress (`Batch`).
- Funding against ledger balances with ledger holds, line by line or all or nothing,
  and an FX hook for short currencies (`Funding`, `Conversion`).
- Submission as payments-core transfers with an atomic hold handover, and transfer
  status tracking (`Submission`).
- Receipts as values (`Receipt`) and reconciliation of batch totals against ledger
  holds and transfers (`Reconciliation`).
- `Store` module type with compare-and-set updates, `Store_memory` and
  `Store_conformance`.
