(* A payout batch from creation to receipts: two payees paid in CHF and EUR from an
   organisation that holds EUR only, so the CHF line is funded through a conversion.
   Everything is pure: the ledger is a [Ledger.Balances.t] value and the entries each step
   returns are applied to it, as a journal would book them. *)

open! Core
open Payouts_core
module Transfer = Payments_core.Transfer
module Booking = Payments_core.Booking

let start = Time_ns.of_string_with_utc_offset "2027-03-31 08:00:00Z"
let at minutes = Time_ns.add start (Time_ns.Span.of_int_min minutes)
let amount currency s = Money.Amount.of_decimal_string currency s |> Or_error.ok_exn
let eur = amount Money.Currency.eur
let chf = amount Money.Currency.chf
let ok = Or_error.ok_exn
let account = Ledger.Account_id.of_string
let org_eur = account "org:acme/eur"
let org_chf = account "org:acme/chf"
let fx_desk = account "bank:fx"
let book balances entries = Booking.apply balances entries |> ok

(* The bank's side: the organisation's accounts, an FX desk and the payment chart, and a
   5,000 EUR deposit. *)
let opening_balances () =
  let apply b event =
    Ledger.Balances.apply b { seq = Ledger.Balances.next_seq b; event } |> ok
  in
  let accounts =
    [ Ledger.Account.create org_eur Liability
    ; Ledger.Account.create org_chf Liability
    ; Ledger.Account.create fx_desk Asset ~allow_negative:true
    ]
    @ Booking.Chart.accounts
        Booking.Chart.default
        ~rails:[ Intraledger ]
        ~currencies:[ Money.Currency.eur; Money.Currency.chf ]
  in
  let b =
    List.fold accounts ~init:Ledger.Balances.empty ~f:(fun b a ->
      apply b (Account_opened a))
  in
  let entry key ~from ~to_ amount =
    Ledger.Entry.create
      ~idempotency_key:(Ledger.Idempotency_key.of_string key)
      ~kind:(Transfer "funding")
      ~effective_at:start
      ~recorded_at:start
      [ Ledger.Posting.debit from amount; Ledger.Posting.credit to_ amount ]
    |> ok
  in
  apply b (Posted (entry "deposit-1" ~from:fx_desk ~to_:org_eur (eur "5000.00")))
;;

let payee name destination =
  Payments_core.Beneficiary.create
    ~id:(Payments_core.Beneficiary.Id.of_string name)
    ~owner:"acme"
    ~name
    ~rail:Intraledger
    ~now:start
    destination
  |> ok
;;

let line name key amount ~reference =
  Line.create
    ~id:(Line_id.of_string name)
    ~key:(Line_key.of_string key)
    ~payee:(payee name ("customer:" ^ name))
    ~rail:Intraledger
    ~amount
    ~reference
    ~now:start
    ()
  |> ok
;;

let show_batch label b =
  printf
    "%-10s %s: %s\n"
    label
    (Batch.Progress.name (Batch.progress b))
    (List.map b.Batch.lines ~f:(fun l ->
       sprintf "%s=%s" (Line_id.to_string l.id) (Line_status.name l.status))
     |> String.concat ~sep:" ")
;;

let () =
  let balances = opening_balances () in
  (* Above 1,000 EUR a batch needs two approvers; the creator never counts. *)
  let policy =
    Approval.Policy.thresholds
      ~second_approver_above:(fun currency ->
        if Money.Currency.equal currency Money.Currency.eur
        then Some (eur "1000.00")
        else None)
      ()
  in
  let b =
    Batch.create
      ~id:(Batch_id.of_string "2027-03-contractors")
      ~title:"March contractors"
      ~created_by:(Actor_id.of_string "dana")
      ~lines:
        [ line "lea" "req-81:lea" (eur "1200.00") ~reference:"INV-2027-031"
        ; line "marc" "req-81:marc" (chf "930.00") ~reference:"Rechnung 17"
        ]
      ~policy
      ~now:start
    |> ok
  in
  show_batch "created" b;
  let approve b who minute =
    match Batch.approve b ~policy ~approver:(Actor_id.of_string who) ~now:(at minute) with
    | Ok b -> b
    | Error refusal ->
      printf "%s cannot approve: %s\n" who (Approval.Refusal.code refusal);
      b
  in
  let b = approve b "dana" 1 in
  let b = approve b "omar" 2 in
  let b = approve b "jun" 3 in
  show_batch "approved" b;
  (* The organisation holds no CHF: the hook prices buying it with EUR. *)
  let source =
    Funding.Source.with_conversion
      [ Money.Currency.eur, org_eur; Money.Currency.chf, org_chf ]
      ~funding_currency:Money.Currency.eur
      ~hook:
        (Conversion.Hook.fixed_rates
           [ Money.Currency.eur, Money.Currency.chf, Q.of_string "0.93" ])
  in
  let fund b balances ?converted minute =
    let plan =
      Funding.plan balances source b ~mode:Line_by_line ?converted ~now:(at minute) ()
      |> ok
    in
    let b = Funding.apply b plan ~now:(at minute) |> ok in
    match plan with
    | Planned { decisions; entries } -> b, book balances entries, decisions
    | Refused _ -> assert false
  in
  let b, balances, decisions = fund b balances 4 in
  show_batch "funding" b;
  (* Execute the conversion the plan asked for (an FX library books these entries in
     practice), then plan again. *)
  let converted =
    List.filter_map decisions ~f:(fun (id, d) ->
      match d with
      | Convert { conversion; _ } ->
        printf
          "convert    %s for %s (%s)\n"
          (Money.Amount.to_string conversion.sell)
          (Money.Amount.to_string conversion.buy)
          conversion.quote_ref;
        Some (id, conversion)
      | Fund _ | Fail _ -> None)
  in
  let balances =
    List.fold converted ~init:balances ~f:(fun balances (id, c) ->
      let leg leg amount ~from ~to_ =
        Ledger.Entry.create
          ~idempotency_key:
            (Ledger.Idempotency_key.of_string
               (sprintf "fx/%s/%s" (Line_id.to_string id) leg))
          ~kind:(Transfer "fx")
          ~code:Fx_leg
          ~effective_at:(at 5)
          ~recorded_at:(at 5)
          [ Ledger.Posting.debit from amount; Ledger.Posting.credit to_ amount ]
        |> ok
      in
      book
        balances
        [ leg "sell" c.sell ~from:org_eur ~to_:fx_desk
        ; leg "buy" c.buy ~from:fx_desk ~to_:org_chf
        ])
  in
  let b, balances, _ = fund b balances ~converted 6 in
  show_batch "funded" b;
  (* Submit each line as a transfer, then the provider settles lea and rejects marc. *)
  let submit (b, balances) (line : Line.t) minute =
    let transfer =
      Submission.draft_transfer
        line
        ~id:(Transfer.Id.of_string ("tr-" ^ Line_id.to_string line.id))
        ~now:(at minute)
        ()
      |> ok
      |> Transfer.exempt ~exemption:Corporate_process
      |> ok
    in
    let b, entries =
      Submission.submit
        Booking.Chart.default
        balances
        b
        line.id
        ~transfer
        ~event_id:("sub-" ^ Line_id.to_string line.id)
        ~now:(at minute)
      |> ok
    in
    (b, book balances entries), Transfer.submit transfer ~at:(at minute) () |> ok
  in
  let state, lea = submit (b, balances) (List.nth_exn b.lines 0) 7 in
  let (b, balances), marc = submit state (List.nth_exn b.lines 1) 8 in
  show_batch "submitted" b;
  let finish (b, balances) transfer to_ minute =
    let entries =
      Booking.transition
        Booking.Chart.default
        balances
        transfer
        ~to_
        ~event_id:("fin-" ^ Transfer.Id.to_string transfer.Transfer.id)
        ~at:(at minute)
      |> ok
    in
    let transfer = Transfer.transition transfer ~to_ ~at:(at minute) |> ok in
    ( (Submission.observe b transfer ~now:(at minute) |> ok, book balances entries)
    , transfer )
  in
  let ac04 = Payments_core.Iso_reason.of_code "AC04" |> ok in
  let state, lea = finish (b, balances) lea Settled 9 in
  let (b, balances), marc = finish state marc (Rejected ac04) 10 in
  show_batch "done" b;
  printf
    "balances   %s, %s\n\n"
    (Money.Amount.to_string
       (Ledger.Balances.available balances org_eur Money.Currency.eur))
    (Money.Amount.to_string
       (Ledger.Balances.available balances org_chf Money.Currency.chf));
  List.iter (Receipt.all b) ~f:(fun r -> print_endline (Receipt.to_text r));
  List.iter (Reconciliation.Totals.of_batch b) ~f:(fun t ->
    printf
      "%s requested %s, settled %s, failed %s\n"
      (Money.Currency.to_string t.currency)
      (Money.Amount.to_string t.requested)
      (Money.Amount.to_string t.settled)
      (Money.Amount.to_string t.failed));
  printf
    "differences: %d\n"
    (List.length (Reconciliation.check b ~balances ~transfers:[ lea; marc ]))
;;
