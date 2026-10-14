open! Core
open Payouts_core
open Helpers
module Transfer = Payments_core.Transfer
module Booking = Payments_core.Booking

let chart = Booking.Chart.default

let source =
  Funding.Source.of_accounts [ Money.Currency.chf, org_account Money.Currency.chf ]
;;

(* A funded batch of two CHF lines paid intraledger, and the balances with both holds. *)
let funded () =
  let balances = ledger [ chf "500.00" ] in
  let b = approved_batch [ line "ada" (chf "120.00"); line "bob" (chf "80.00") ] in
  let plan =
    Funding.plan balances source b ~mode:Line_by_line ~now:(at 2) () |> Or_error.ok_exn
  in
  let b = Funding.apply b plan ~now:(at 2) |> Or_error.ok_exn in
  match plan with
  | Planned { entries; _ } -> b, book balances entries
  | Refused _ -> assert false
;;

let authorized_transfer b name =
  let line = Option.value_exn (Batch.find_line b (Line_id.of_string name)) in
  Submission.draft_transfer line ~id:(Transfer.Id.of_string ("tr-" ^ name)) ~now:(at 3) ()
  |> Or_error.ok_exn
  (* Batch payments by a business under a dedicated process: RTS article 17. *)
  |> Transfer.exempt ~exemption:Corporate_process
  |> Or_error.ok_exn
;;

let show_balances balances =
  let account = org_account Money.Currency.chf in
  print_s
    [%message
      ""
        ~available:
          (Ledger.Balances.available balances account Money.Currency.chf : Money.Amount.t)
        ~held:(Ledger.Balances.held balances account Money.Currency.chf : Money.Amount.t)
        ~posted:
          (Ledger.Balances.posted balances account Money.Currency.chf : Money.Amount.t)]
;;

let%expect_test "submission moves the funding hold to the transfer" =
  let b, balances = funded () in
  show_balances balances;
  let transfer = authorized_transfer b "ada" in
  let b, entries =
    Submission.submit
      chart
      balances
      b
      (Line_id.of_string "ada")
      ~transfer
      ~event_id:"evt-1"
      ~now:(at 3)
    |> Or_error.ok_exn
  in
  List.iter entries ~f:(fun e ->
    print_s
      [%message
        ""
          ~key:(e.idempotency_key : Ledger.Idempotency_key.t)
          ~kind:(e.kind : Ledger.Entry.Kind.t)
          ~amount:(Ledger.Entry.total e : Money.Amount.t)]);
  let balances = book balances entries in
  show_balances balances;
  print_batch b;
  (* The provider accepts, then settles; payments-core books the capture. *)
  let transfer = Transfer.submit transfer ~at:(at 3) () |> Or_error.ok_exn in
  let settle =
    Booking.transition chart balances transfer ~to_:Settled ~event_id:"evt-2" ~at:(at 4)
    |> Or_error.ok_exn
  in
  let balances = book balances settle in
  let transfer =
    Transfer.transition transfer ~to_:Settled ~at:(at 4) |> Or_error.ok_exn
  in
  let b = Submission.observe b transfer ~now:(at 4) |> Or_error.ok_exn in
  show_balances balances;
  print_batch b;
  [%expect
    {|
    ((available "300.00 CHF") (held "200.00 CHF") (posted "500.00 CHF"))
    ((key req-1:ada/submit) (kind (Hold_release payout:req-1:ada))
     (amount "120.00 CHF"))
    ((key evt-1/hold) (kind (Hold_place transfer:tr-ada)) (amount "120.00 CHF"))
    ((available "300.00 CHF") (held "200.00 CHF") (posted "500.00 CHF"))
    ((status approved) (progress processing) (approvals 1) (required 1)
     (revision 4) (lines ((ada submitted) (bob funded))))
    ((available "300.00 CHF") (held "80.00 CHF") (posted "380.00 CHF"))
    ((status approved) (progress processing) (approvals 1) (required 1)
     (revision 5) (lines ((ada settled) (bob funded))))
    |}]
;;

let%expect_test "submission checks the line and the transfer" =
  let b, balances = funded () in
  let transfer = authorized_transfer b "ada" in
  let try_submit ?(b = b) name transfer =
    Submission.submit
      chart
      balances
      b
      (Line_id.of_string name)
      ~transfer
      ~event_id:"evt-1"
      ~now:(at 3)
    |> Or_error.map ~f:ignore
    |> [%sexp_of: unit Or_error.t]
    |> print_s
  in
  try_submit "bob" transfer;
  try_submit "ada" { transfer with amount = chf "1.00" };
  let unfunded = approved_batch [ line "ada" (chf "120.00") ] in
  try_submit ~b:unfunded "ada" transfer;
  print_s
    [%sexp
      (Submission.observe b transfer ~now:(at 3) |> Or_error.map ~f:ignore
       : unit Or_error.t)];
  [%expect
    {|
    (Error ("transfer does not match the line" amount))
    (Error ("transfer does not match the line" amount))
    (Error ("line is not funded" (line req-1:ada) (status Approved)))
    (Error ("no line is paid by this transfer" (transfer tr-ada)))
    |}]
;;
