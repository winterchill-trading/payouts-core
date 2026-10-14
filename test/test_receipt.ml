open! Core
open Payouts_core
open Helpers
module Transfer = Payments_core.Transfer
module Booking = Payments_core.Booking

let chart = Booking.Chart.default

(* ada is settled, bob is rejected by the scheme, cy is still only funded. Returns the
   batch, the balances and the transfers as the provider reports them. *)
let scenario () =
  let source = Funding.Source.of_accounts [ Money.Currency.chf, org_account Money.Currency.chf ] in
  let balances = ledger [ chf "500.00" ] in
  let b =
    approved_batch
      [ line ~reference:"Invoice 2027-014" "ada" (chf "120.00")
      ; line "bob" (chf "80.00")
      ; line "cy" (chf "40.00")
      ]
  in
  let plan = Funding.plan balances source b ~mode:Line_by_line ~now:(at 2) () |> Or_error.ok_exn in
  let b = Funding.apply b plan ~now:(at 2) |> Or_error.ok_exn in
  let balances =
    match plan with
    | Planned { entries; _ } -> book balances entries
    | Refused _ -> assert false
  in
  let send (b, balances) name ~final ~minute =
    let line = Option.value_exn (Batch.find_line b (Line_id.of_string name)) in
    let transfer =
      Submission.draft_transfer line ~id:(Transfer.Id.of_string ("tr-" ^ name)) ~now:(at minute) ()
      |> Or_error.ok_exn
      |> Transfer.exempt ~exemption:Corporate_process
      |> Or_error.ok_exn
    in
    let b, entries =
      Submission.submit chart balances b line.id ~transfer ~event_id:("evt-" ^ name) ~now:(at minute)
      |> Or_error.ok_exn
    in
    let balances = book balances entries in
    let transfer = Transfer.submit transfer ~provider_ref:("p-" ^ name) ~at:(at minute) () |> Or_error.ok_exn in
    let balances =
      book
        balances
        (Booking.transition chart balances transfer ~to_:final ~event_id:("evt2-" ^ name) ~at:(at (minute + 1))
         |> Or_error.ok_exn)
    in
    let transfer = Transfer.transition transfer ~to_:final ~at:(at (minute + 1)) |> Or_error.ok_exn in
    let b = Submission.observe b transfer ~now:(at (minute + 1)) |> Or_error.ok_exn in
    (b, balances), transfer
  in
  let ac04 = Payments_core.Iso_reason.of_code "AC04" |> Or_error.ok_exn in
  let state, ada = send (b, balances) "ada" ~final:Settled ~minute:3 in
  let (b, balances), bob = send state "bob" ~final:(Rejected ac04) ~minute:5 in
  b, balances, [ ada; bob ]
;;

let%expect_test "receipts exist for submitted lines" =
  let b, _, _ = scenario () in
  print_s [%sexp (List.map (Receipt.all b) ~f:(fun r -> r.line, Receipt.Outcome.name r.outcome) : (Line_id.t * string) list)];
  print_string (Receipt.to_text (Receipt.of_line b (Line_id.of_string "ada") |> Or_error.ok_exn));
  print_string (Receipt.to_text (Receipt.of_line b (Line_id.of_string "bob") |> Or_error.ok_exn));
  print_s [%sexp (Receipt.of_line b (Line_id.of_string "cy") |> Or_error.map ~f:ignore : unit Or_error.t)];
  [%expect
    {|
    ((ada paid) (bob failed))
    batch:        March contractors (batch-1)
    line:         ada
    payee:        ada
    to:           account ****:ada
    rail:         intraledger
    amount:       120.00 CHF
    reference:    Invoice 2027-014
    outcome:      paid
    transfer:     tr-ada
    provider ref: p-ada
    created by:   maker
    approved by:  checker
    draft:        2027-03-01 09:00:00Z
    approved:     2027-03-01 09:01:00Z
    funded:       2027-03-01 09:02:00Z
    submitted:    2027-03-01 09:03:00Z
    settled:      2027-03-01 09:04:00Z
    batch:        March contractors (batch-1)
    line:         bob
    payee:        bob
    to:           account ****:bob
    rail:         intraledger
    amount:       80.00 CHF
    outcome:      failed: rejected
    transfer:     tr-bob
    provider ref: p-bob
    created by:   maker
    approved by:  checker
    draft:        2027-03-01 09:00:00Z
    approved:     2027-03-01 09:01:00Z
    funded:       2027-03-01 09:02:00Z
    submitted:    2027-03-01 09:05:00Z
    failed:       2027-03-01 09:06:00Z
    (Error ("no receipt before submission" (line cy) (status funded)))
    |}]
;;

let%expect_test "masking" =
  let show d = print_endline (Receipt.mask_destination d) in
  show (sepa_payee "x").destination;
  show
    (Lightning
       (Payments_core.Lightning.Target.of_string "pay@example.org" |> Or_error.ok_exn));
  [%expect {|
    IBAN ****3000
    Lightning address ****@example.org
    |}]
;;

let%expect_test "a consistent batch reconciles" =
  let b, balances, transfers = scenario () in
  let totals = Reconciliation.Totals.of_batch b in
  print_s [%sexp (totals : Reconciliation.Totals.t list)];
  List.iter totals ~f:(fun t -> Reconciliation.Totals.check t |> Or_error.ok_exn);
  print_s [%sexp (Reconciliation.check b ~balances ~transfers : Reconciliation.Diff.t list)];
  [%expect {|
    (((currency CHF) (lines 3) (requested "240.00 CHF") (awaiting "0.00 CHF")
      (funded "40.00 CHF") (submitted "0.00 CHF") (settled "120.00 CHF")
      (failed "80.00 CHF") (returned "0.00 CHF") (cancelled "0.00 CHF")))
    ()
    |}]
;;

let%expect_test "differences are listed, not fixed" =
  let b, balances, transfers = scenario () in
  (* The provider reports ada returned and has no bob; cy's hold was released by
     mistake. *)
  let ada = List.hd_exn transfers in
  let ada =
    { ada with
      status = Returned (Payments_core.Iso_reason.of_code "AC04" |> Or_error.ok_exn)
    }
  in
  let cy = Option.value_exn (Batch.find_line b (Line_id.of_string "cy")) in
  let balances = book balances [ Funding.release balances cy ~now:(at 9) |> Or_error.ok_exn ] in
  print_s [%sexp (Reconciliation.check b ~balances ~transfers:[ ada ] : Reconciliation.Diff.t list)];
  [%expect {|
    ((Status_mismatch (line ada) (transfer tr-ada) (line_status Settled)
      (transfer_status (Returned AC04)))
     (Transfer_missing (line bob) (transfer tr-bob))
     (Hold_amount_mismatch (line cy) (hold payout:req-1:cy)
      (line_amount "40.00 CHF") (held "0.00 CHF"))
     (Settled_total_mismatch (currency CHF) (batch "120.00 CHF")
      (transfers "0.00 CHF")))
    |}]
;;
