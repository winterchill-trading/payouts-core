# payouts-core

Batches of outgoing payments to many payees, across rails and currencies: payroll runs,
contractor and supplier payments, refunds in bulk. One approval covers a whole batch;
after that every line is funded, sent and settled on its own.

- **A pure line state machine.** `draft -> approved -> funded -> submitted -> settled`,
  with `failed`, `returned` and `cancelled`. Every transition is checked against one
  table and timestamped; failed, returned and cancelled are final.
- **Batch approval through a hook.** How many approvals a batch needs and who may give
  them is an `Approval.Policy.t`: two functions over the batch's totals and the
  approver. `Policy.thresholds` gives per-currency limits (auto-approve below one, a
  second approver above another) and takes an `authorize` function for roles. Whatever
  the policy, the creator never approves their own batch and one person approves once.
- **Funding against ledger balances.** `Funding.plan` walks approved lines in order
  against `Ledger.Balances.available` and reserves each one with a ledger hold. Two
  modes: fund what fits line by line, or all or nothing. A line in a currency the payer
  is short of can be bought first through an FX hook (`Conversion.Hook.t`).
- **Per-line idempotency keys.** Each line carries the caller's key; the funding hold,
  its release and the submission entries derive their ledger keys from it, and a store
  refuses a second line with the same key, so a retry never pays twice.
- **Partial failure.** Lines fail independently and nothing is rolled back. The batch's
  progress is derived from its lines: `processing`, then `completed`,
  `completed_with_failures` or `failed`.
- **Receipts as values.** `Receipt.of_line` builds a plain record (masked destination,
  outcome, approvers, conversion, timeline) and `Receipt.to_text` renders it.
- **Reconciliation.** Per-currency totals whose buckets always add up, and a check that
  lists every difference between a batch, the ledger's holds and the transfers that pay
  it.
- **A Store module type** with compare-and-set updates, an in-memory implementation and
  conformance scenarios for other implementations.

## Why separate

Paying many people at once has rules that single payments do not: one approval for
many payments, money checked for the whole batch before any of it leaves, lines that
fail without undoing their neighbours, and totals that must still add up afterwards.
These rules are the same whether the batch is a payroll, a supplier run or a set of
refunds, and whatever rail each line uses. Keeping them in a small library over
`payments-core` (rails, payees, transfers) and `ledger` (balances, holds) lets a service
use them without re-deriving them, and lets them be tested once, with property tests.

## Quick start

```ocaml
open! Core
open Payouts_core

let policy =
  Approval.Policy.thresholds
    ~second_approver_above:(fun _ -> Some (Money.Amount.of_string "10000.00 EUR"))
    ()

(* lines: Line.create ~id ~key ~payee ~rail ~amount ~now () for each payee *)
let batch = Batch.create ~id ~title:"March payroll" ~created_by ~lines ~policy ~now |> ok
let batch = Batch.approve batch ~policy ~approver ~now (* Error Own_batch for the creator *)

(* Reserve the money: hold entries to book, then the lines move. *)
let source = Funding.Source.of_accounts [ Money.Currency.eur, payer_eur_account ]
let plan = Funding.plan balances source batch ~mode:Line_by_line ~now () |> ok
let batch = Funding.apply batch plan ~now |> ok

(* For each funded line: an authorized transfer, then the hold moves to it. *)
let transfer = Submission.draft_transfer line ~id:transfer_id ~now () |> ok
let batch, entries =
  Submission.submit chart balances batch line.id ~transfer ~event_id ~now |> ok

(* Provider events: payments-core books them; the line follows its transfer. *)
let batch = Submission.observe batch transfer ~now |> ok
let receipts = Receipt.all batch
```

[`examples/quickstart.ml`](examples/quickstart.ml) runs the whole flow on pure ledger
balances: a two-approver batch, a line funded through a conversion, one payment settled
and one rejected, the receipts and the reconciliation. Its output is checked in CI
(`examples/quickstart.expected`).

## Modules

| Module | What it is |
|---|---|
| `Batch_id`, `Line_id`, `Actor_id` | validated ids (the ledger id alphabet) |
| `Line_key` | per-line idempotency key; derived ledger keys and the funding hold id |
| `Line_status`, `Failure` | the transition table; why a line failed |
| `Line` | one payment: payee, rail, amount, reference, status, history, funding, transfer |
| `Approval` | `Policy.t` hook, `Policy.thresholds`, `Summary`, `Refusal` |
| `Batch` | creation checks, approve, reject, cancel, cancel a line, derived `Progress` |
| `Conversion` | the FX hook: buy a line's amount with a funding currency |
| `Funding` | `plan` against ledger balances, `apply`, `release` |
| `Submission` | transfer drafts, hold handover on submission, `observe` transfer statuses |
| `Receipt` | receipts as values, masked destinations, text rendering |
| `Reconciliation` | per-currency `Totals`; differences with ledger holds and transfers |
| `Store`, `Store_memory`, `Store_conformance` | persistence as a module type |

Line life:

```
draft --batch approved--> approved --funded--> funded --submitted--> submitted --> settled
  |                         |                    |                       |            |
  |                         +--> failed <--------+---------- failed <----+            v
  +-------------------------+--> cancelled <-----+         returned <----+------- returned
```

Batch: `pending_approval -> approved | rejected | cancelled`; progress after approval
is derived from the lines.

## Money flow in the ledger

| Step | Entries | Key |
|---|---|---|
| Funding | hold of the line's amount on the payer's account | `<line key>/fund`, hold `payout:<line key>` |
| Cancel or fail while funded | release of that hold | `<line key>/release` |
| Submission | release of the funding hold and the transfer's own hold, in one linked record | `<line key>/submit`, `<event id>/hold` |
| Settlement, rejection, return | `payments-core` `Booking.transition` | `<event id>/<leg>` |

Book each step's entries before saving the batch; the ledger re-checks every hold, so a
plan built on stale balances is refused when booked, never half applied.

## FX hook

Funding never prices currencies. `Funding.Source.with_conversion` takes a funding
currency and a `Conversion.Hook.t`; for a line its currency account cannot cover, the
plan asks the hook for a firm price to buy exactly the line's amount and returns a
`Convert` decision. The caller executes the conversion (booking its entries through its
FX library), then plans again with `~converted`, and the line is funded with the
conversion recorded for its receipt. A rate library that issues buy-fixed quotes plugs
in by mapping its quote's id, sold and bought amounts onto `Conversion.t`.
`Conversion.Hook.fixed_rates` serves tests and examples.

## Storage

The library never persists anything. A service implements `Store.S` over its own
database: `insert` must store a batch atomically with its line keys (a key belongs to
one line for good) and `update` is a compare-and-set on the batch's `revision`. Run
`Store_conformance.Make` against the implementation in the service's test suite; it is
the same suite `Store_memory` passes. Every persisted type has a `Stable.V1` bin_prot
and sexp form with a pinned digest; rails and payees are stored in their payments-core
V2 format, which carries the UK rails.

## Dependencies

`money`, `ledger` and `payments-core` from this organisation, plus `core`, `ppx_jane` and
`zarith`. CI pins `fixed-decimal`, `money`, `ledger` and `payments-core` in that order.

## Known gaps

- Payroll schedules (a batch per due date) are left to a scheduler; a batch has no
  notion of recurrence.
- Contractor invoices and monthly payout caps are not modelled.
- Lines are not dated: every approved line is due at once.
- The FX hook is a function, not a dependency on a pricing library; executing the
  conversion is the caller's job.

## Docs

- `AGENTS.md` (and one per directory) for AI coding agents.
- [`CHANGES.md`](CHANGES.md).
- API docs: `dune build @doc`.
