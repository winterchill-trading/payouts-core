open! Core
open Payouts_core
open Helpers
module Transfer = Payments_core.Transfer

let show = function
  | Ok (l : Line.t) -> print_s [%sexp (l.status : Line_status.t)]
  | Error e -> print_s [%sexp (e : Error.t)]
;;

let%expect_test "creation checks amount, rail, currency and reference" =
  let create ?(rail = Payments_core.Rail.Sepa_credit) ?reference amount =
    Line.create
      ~id:(Line_id.of_string "l")
      ~key:(Line_key.of_string "k")
      ~payee:(sepa_payee "ada")
      ~rail
      ~amount
      ?reference
      ~now:t0
      ()
    |> show
  in
  create (eur "10.00");
  create (eur "0.00");
  create (chf "10.00");
  create ~rail:Lightning (eur "10.00");
  create ~reference:(String.make 141 'x') (eur "1.00");
  create ~reference:"a\nb" (eur "1.00");
  [%expect
    {|
    Draft
    ("amount must be positive" (amount "0.00 EUR"))
    ("SEPA rails pay EUR only" (currency CHF))
    ("payee cannot be reached on this rail" (rail Lightning))
    ("reference too long" (max_reference_length 140) (length 141))
    "reference has a line break"
    |}]
;;

let%expect_test "the happy path, and moves the table refuses" =
  let l = line "ada" (eur "100.00") in
  let funded_from : Line.Funded_from.t =
    { account = Ledger.Account_id.of_string "org:1/eur"
    ; hold = Line_key.hold_id l.key
    ; conversion = None
    }
  in
  show (Line.fund l funded_from ~at:(at 1));
  let ok r = Or_error.ok_exn r in
  let l = Line.approve l ~at:(at 1) |> ok in
  let l = Line.fund l funded_from ~at:(at 2) |> ok in
  let l = Line.submit l ~transfer:(Transfer.Id.of_string "tr-1") ~at:(at 3) () |> ok in
  let l = Line.settle l ~at:(at 4) |> ok in
  show (Ok l);
  show (Line.cancel l ~at:(at 5));
  let l = Line.return l ~at:(at 6) () |> ok in
  show (Ok l);
  print_s
    [%sexp
      (List.map Line_status.names ~f:(Line.entered_at l)
       : Time_ns.Alternate_sexp.t option list)];
  [%expect
    {|
    ("line cannot move" (line req-1:ada) (from Draft) (to_ Funded))
    Settled
    ("line cannot move" (line req-1:ada) (from Settled) (to_ Cancelled))
    (Returned ())
    (("2027-03-01 09:00:00Z") ("2027-03-01 09:01:00Z") ("2027-03-01 09:02:00Z")
     ("2027-03-01 09:03:00Z") ("2027-03-01 09:04:00Z") ()
     ("2027-03-01 09:06:00Z") ())
    |}]
;;

let%expect_test "transfer statuses map onto the line" =
  (* Intraledger, so the transfer draft needs no SEPA details. *)
  let base =
    let l = line "ada" (chf "100.00") in
    let ok r = Or_error.ok_exn r in
    let l = Line.approve l ~at:t0 |> ok in
    let l =
      Line.fund
        l
        { account = Ledger.Account_id.of_string "org:1/chf"
        ; hold = Line_key.hold_id l.key
        ; conversion = None
        }
        ~at:t0
      |> ok
    in
    Line.submit l ~transfer:(Transfer.Id.of_string "tr-1") ~at:t0 () |> ok
  in
  let transfer =
    Transfer.draft
      ~id:(Transfer.Id.of_string "tr-1")
      ~rail:Intraledger
      ~account:(Ledger.Account_id.of_string "org:1/chf")
      ~beneficiary:base.payee
      ~amount:base.amount
      ~now:t0
      ()
    |> Or_error.ok_exn
  in
  let with_status (status : Transfer.Status.t) = { transfer with status } in
  let ac04 = Payments_core.Iso_reason.of_code "AC04" |> Or_error.ok_exn in
  List.iter
    [ Transfer.Status.Submitted
    ; Pending
    ; Timed_out
    ; Settled
    ; Rejected ac04
    ; Failed Insufficient_funds
    ; Returned ac04
    ; Recalled
    ]
    ~f:(fun status ->
      let r = Line.observe base (with_status status) ~at:(at 1) in
      print_s
        [%message
          (Transfer.Status.name status)
            ~line:
              (Or_error.map r ~f:(fun (l : Line.t) -> l.status)
               : Line_status.t Or_error.t)]);
  (* The same settlement twice is a no-op, not an error. *)
  let settled = Line.observe base (with_status Settled) ~at:(at 1) |> Or_error.ok_exn in
  show (Line.observe settled (with_status Settled) ~at:(at 2));
  show (Line.observe base { transfer with id = Transfer.Id.of_string "tr-2" } ~at:(at 1));
  [%expect
    {|
    (Submitted (line (Ok Submitted)))
    (Pending (line (Ok Submitted)))
    (Timed_out (line (Ok Submitted)))
    (Settled (line (Ok Settled)))
    (Rejected (line (Ok (Failed (Rejected AC04)))))
    (Failed (line (Ok (Failed (Transfer_failed Insufficient_funds)))))
    (Returned (line (Ok (Returned (AC04)))))
    (Recalled (line (Ok (Returned ()))))
    Settled
    ("transfer belongs to another line" (line req-1:ada) (expected tr-1)
     (got tr-2))
    |}]
;;

let%expect_test "keys and derived ledger ids" =
  let key = Line_key.of_string "req-7:ada" in
  List.iter Line_key.Leg.all ~f:(fun leg ->
    print_endline (Ledger.Idempotency_key.to_string (Line_key.derive key leg)));
  print_endline (Ledger.Hold_id.to_string (Line_key.hold_id key));
  print_s
    [%sexp (Line_key.of_string_or_error (String.make 113 'a') : Line_key.t Or_error.t)];
  print_s [%sexp (Line_key.of_string_or_error "has space" : Line_key.t Or_error.t)];
  [%expect
    {|
    req-7:ada/fund
    req-7:ada/release
    req-7:ada/submit
    payout:req-7:ada
    (Error ("line key too long" (max_length 112) (length 113)))
    (Error
     ((Payouts_core.Line_key (id "has space"))
      ("invalid character in id" (c " ") "has space")))
    |}]
;;
