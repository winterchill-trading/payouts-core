open! Core
open Payouts_core
module Beneficiary = Payments_core.Beneficiary

let t0 = Time_ns.of_string_with_utc_offset "2027-03-01 09:00:00Z"
let at n = Time_ns.add t0 (Time_ns.Span.of_int_min n)
let eur s = Money.Amount.of_decimal_string Money.Currency.eur s |> Or_error.ok_exn
let chf s = Money.Amount.of_decimal_string Money.Currency.chf s |> Or_error.ok_exn
let usdc s = Money.Amount.of_decimal_string Money.Currency.usdc s |> Or_error.ok_exn

let sepa_payee name =
  Beneficiary.create
    ~id:(Beneficiary.Id.of_string ("ben-" ^ name))
    ~owner:"org-1"
    ~name
    ~rail:Sepa_credit
    ~now:t0
    "DE89370400440532013000"
  |> Or_error.ok_exn
;;

let internal_payee name =
  Beneficiary.create
    ~id:(Beneficiary.Id.of_string ("ben-" ^ name))
    ~owner:"org-1"
    ~name
    ~rail:Intraledger
    ~now:t0
    ("customer:" ^ name)
  |> Or_error.ok_exn
;;

let line ?reference name amount =
  let rail, payee =
    if Money.Currency.equal (Money.Amount.currency amount) Money.Currency.eur
    then Payments_core.Rail.Sepa_credit, sepa_payee name
    else Payments_core.Rail.Intraledger, internal_payee name
  in
  Line.create
    ~id:(Line_id.of_string name)
    ~key:(Line_key.of_string ("req-1:" ^ name))
    ~payee
    ~rail
    ~amount
    ?reference
    ~now:t0
    ()
  |> Or_error.ok_exn
;;

let maker = Actor_id.of_string "maker"
let checker = Actor_id.of_string "checker"
let second_checker = Actor_id.of_string "checker-2"

let batch ?(id = "batch-1") lines =
  Batch.create
    ~id:(Batch_id.of_string id)
    ~title:"March contractors"
    ~created_by:maker
    ~lines
    ~policy:Approval.Policy.one_approval
    ~now:t0
  |> Or_error.ok_exn
;;

let approved_batch ?id lines =
  match
    Batch.approve
      (batch ?id lines)
      ~policy:Approval.Policy.one_approval
      ~approver:checker
      ~now:(at 1)
  with
  | Ok b -> b
  | Error r -> raise_s [%sexp (r : Approval.Refusal.t)]
;;

let print_batch (b : Batch.t) =
  print_s
    [%message
      ""
        ~status:(Batch.Status.name b.status : string)
        ~progress:(Batch.Progress.name (Batch.progress b) : string)
        ~approvals:(List.length b.approvals : int)
        ~required:(b.approvals_required : int)
        ~revision:(b.revision : int)
        ~lines:
          (List.map b.lines ~f:(fun l -> Line_id.to_string l.id, Line_status.name l.status)
           : (string * string) list)]
;;

let org_account currency =
  Ledger.Account_id.of_string ("org:1/" ^ String.lowercase (Money.Currency.to_string currency))
;;

let cash = Ledger.Account_id.of_string "bank:cash"
let seq = ref 0

let apply_event balances event =
  let record = { Ledger.Record.seq = Ledger.Balances.next_seq balances; event } in
  Ledger.Balances.apply balances record |> Or_error.ok_exn
;;

let deposit balances amount =
  incr seq;
  let entry =
    Ledger.Entry.create
      ~idempotency_key:(Ledger.Idempotency_key.of_string (sprintf "deposit-%d" !seq))
      ~kind:(Transfer "deposit")
      ~effective_at:t0
      ~recorded_at:t0
      [ Ledger.Posting.debit cash amount
      ; Ledger.Posting.credit (org_account (Money.Amount.currency amount)) amount
      ]
    |> Or_error.ok_exn
  in
  apply_event balances (Posted entry)
;;

let currencies = Money.Currency.[ eur; chf; usdc ]

let ledger deposits =
  let accounts =
    Ledger.Account.create cash Asset ~allow_negative:true
    :: List.map currencies ~f:(fun c -> Ledger.Account.create (org_account c) Liability)
    @ Payments_core.Booking.Chart.accounts
        Payments_core.Booking.Chart.default
        ~rails:[ Sepa_credit; Intraledger ]
        ~currencies
  in
  let balances =
    List.fold accounts ~init:Ledger.Balances.empty ~f:(fun b a ->
      apply_event b (Account_opened a))
  in
  List.fold deposits ~init:balances ~f:deposit
;;

let book balances entries =
  Payments_core.Booking.apply balances entries |> Or_error.ok_exn
;;

let convert balances ~sell ~buy ~at =
  incr seq;
  let leg amount ~from ~to_ =
    Ledger.Entry.create
      ~idempotency_key:(Ledger.Idempotency_key.of_string (sprintf "fx-%d-%s" !seq (Money.Amount.to_decimal_string amount)))
      ~kind:(Transfer "fx")
      ~effective_at:at
      ~recorded_at:at
      [ Ledger.Posting.debit from amount; Ledger.Posting.credit to_ amount ]
    |> Or_error.ok_exn
  in
  book
    balances
    [ leg sell ~from:(org_account (Money.Amount.currency sell)) ~to_:cash
    ; leg buy ~from:cash ~to_:(org_account (Money.Amount.currency buy))
    ]
;;

let available balances currency =
  Money.Amount.to_string
    (Ledger.Balances.available balances (org_account currency) currency)
;;
