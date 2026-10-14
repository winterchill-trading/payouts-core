open! Core
open Payouts_core
open Helpers

let source = Funding.Source.of_accounts (List.map Money.Currency.[ eur; usdc ] ~f:(fun c -> c, org_account c))

let print_plan (plan : Funding.Plan.t) =
  match plan with
  | Refused failures ->
    print_s [%message "refused" ~_:(failures : (Line_id.t * Failure.t) list)]
  | Planned { decisions; entries } ->
    List.iter decisions ~f:(fun (id, d) ->
      let d =
        match d with
        | Fund { account; conversion } ->
          [%message
            "fund"
              (account : Ledger.Account_id.t)
              ~conversion:(Option.map conversion ~f:(fun c -> c.sell) : Money.Amount.t option)]
        | Convert { from_; conversion; _ } ->
          [%message
            "convert" (from_ : Ledger.Account_id.t) ~sell:(conversion.sell : Money.Amount.t)]
        | Fail f -> [%message "fail" ~_:(f : Failure.t)]
      in
      print_s [%message (id : Line_id.t) ~_:(d : Sexp.t)]);
    List.iter entries ~f:(fun e ->
      print_s
        [%message
          ""
            ~key:(e.idempotency_key : Ledger.Idempotency_key.t)
            ~kind:(e.kind : Ledger.Entry.Kind.t)
            ~amount:(Ledger.Entry.total e : Money.Amount.t)
            ~reference:e.reference]);
    print_s [%message "held" ~_:(Funding.Plan.held plan : Money.Amount.t list)]
;;

let lines () =
  [ line "ada" (eur "600.00")
  ; line "bob" (eur "500.00")
  ; line "cy" (eur "300.00")
  ; line "dee" (chf "10.00")
  ]
;;

let%expect_test "line by line: fund what fits, in order" =
  let balances = ledger [ eur "1000.00" ] in
  let b = approved_batch (lines ()) in
  let plan =
    Funding.plan balances source b ~mode:Line_by_line ~now:(at 2) () |> Or_error.ok_exn
  in
  print_plan plan;
  let b = Funding.apply b plan ~now:(at 2) |> Or_error.ok_exn in
  print_batch b;
  let balances =
    match plan with
    | Planned { entries; _ } -> book balances entries
    | Refused _ -> assert false
  in
  print_endline (available balances Money.Currency.eur);
  (* Planning again finds nothing left to fund. *)
  print_plan (Funding.plan balances source b ~mode:Line_by_line ~now:(at 3) () |> Or_error.ok_exn);
  [%expect
    {|
    ((id ada) (fund (account org:1/eur) (conversion ())))
    ((id bob)
     (fail (Insufficient_funds (required "500.00 EUR") (available "400.00 EUR"))))
    ((id cy) (fund (account org:1/eur) (conversion ())))
    ((id dee) (fail (No_funding_account CHF)))
    ((key req-1:ada/fund) (kind (Hold_place payout:req-1:ada))
     (amount "600.00 EUR") (reference batch-1/ada))
    ((key req-1:cy/fund) (kind (Hold_place payout:req-1:cy))
     (amount "300.00 EUR") (reference batch-1/cy))
    (held ("900.00 EUR"))
    ((status approved) (progress processing) (approvals 1) (required 1)
     (revision 5) (lines ((ada funded) (bob failed) (cy funded) (dee failed))))
    100.00 EUR
    (held ())
    |}]
;;

let%expect_test "all or nothing: one short line refuses the plan" =
  let balances = ledger [ eur "1000.00" ] in
  let b = approved_batch (lines ()) in
  let plan =
    Funding.plan balances source b ~mode:All_or_nothing ~now:(at 2) () |> Or_error.ok_exn
  in
  print_plan plan;
  print_batch (Funding.apply b plan ~now:(at 2) |> Or_error.ok_exn);
  (* Without the CHF line and with enough money, everything is funded. *)
  let b = Batch.cancel_line b ~policy:Approval.Policy.one_approval (Line_id.of_string "dee") ~now:(at 2) |> Or_error.ok_exn in
  let balances = ledger [ eur "1400.00" ] in
  print_plan (Funding.plan balances source b ~mode:All_or_nothing ~now:(at 2) () |> Or_error.ok_exn);
  [%expect
    {|
    (refused
     ((bob (Insufficient_funds (required "500.00 EUR") (available "400.00 EUR")))
      (dee (No_funding_account CHF))))
    ((status approved) (progress processing) (approvals 1) (required 1)
     (revision 1)
     (lines ((ada approved) (bob approved) (cy approved) (dee approved))))
    ((id ada) (fund (account org:1/eur) (conversion ())))
    ((id bob) (fund (account org:1/eur) (conversion ())))
    ((id cy) (fund (account org:1/eur) (conversion ())))
    ((key req-1:ada/fund) (kind (Hold_place payout:req-1:ada))
     (amount "600.00 EUR") (reference batch-1/ada))
    ((key req-1:bob/fund) (kind (Hold_place payout:req-1:bob))
     (amount "500.00 EUR") (reference batch-1/bob))
    ((key req-1:cy/fund) (kind (Hold_place payout:req-1:cy))
     (amount "300.00 EUR") (reference batch-1/cy))
    (held ("1400.00 EUR"))
    |}]
;;

let%expect_test "a short currency is bought with the funding currency" =
  let hook =
    Conversion.Hook.fixed_rates
      [ Money.Currency.eur, Money.Currency.chf, Q.of_string "0.93" ]
  in
  let source =
    Funding.Source.with_conversion
      (List.map Money.Currency.[ eur; chf ] ~f:(fun c -> c, org_account c))
      ~funding_currency:Money.Currency.eur
      ~hook
  in
  let balances = ledger [ eur "150.00"; chf "5.00" ] in
  let b = approved_batch [ line "dee" (chf "93.00"); line "eve" (chf "5.00"); line "fay" (chf "93.00") ] in
  let plan = Funding.plan balances source b ~mode:Line_by_line ~now:(at 2) () |> Or_error.ok_exn in
  print_plan plan;
  let b = Funding.apply b plan ~now:(at 2) |> Or_error.ok_exn in
  print_batch b;
  (* The caller executes the conversion, books the hold for eve, and plans again. *)
  let conversion =
    match plan with
    | Planned { decisions; _ } ->
      List.find_map_exn decisions ~f:(fun (_, d) ->
        match d with
        | Convert { conversion; _ } -> Some conversion
        | Fund _ | Fail _ -> None)
    | Refused _ -> assert false
  in
  let balances =
    match plan with
    | Planned { entries; _ } -> book balances entries
    | Refused _ -> assert false
  in
  let balances = convert balances ~sell:conversion.sell ~buy:conversion.buy ~at:(at 2) in
  let plan =
    Funding.plan
      balances
      source
      b
      ~mode:Line_by_line
      ~converted:[ Line_id.of_string "dee", conversion ]
      ~now:(at 3)
      ()
    |> Or_error.ok_exn
  in
  print_plan plan;
  let b = Funding.apply b plan ~now:(at 3) |> Or_error.ok_exn in
  print_batch b;
  print_s [%sexp ((Option.value_exn (Batch.find_line b (Line_id.of_string "dee"))).funded_from : Line.Funded_from.t option)];
  [%expect
    {|
    ((id dee) (convert (from_ org:1/eur) (sell "100.00 EUR")))
    ((id eve) (fund (account org:1/chf) (conversion ())))
    ((id fay)
     (fail (Insufficient_funds (required "100.00 EUR") (available "50.00 EUR"))))
    ((key req-1:eve/fund) (kind (Hold_place payout:req-1:eve))
     (amount "5.00 CHF") (reference batch-1/eve))
    (held ("5.00 CHF"))
    ((status approved) (progress processing) (approvals 1) (required 1)
     (revision 3) (lines ((dee approved) (eve funded) (fay failed))))
    ((id dee) (fund (account org:1/chf) (conversion ("100.00 EUR"))))
    ((key req-1:dee/fund) (kind (Hold_place payout:req-1:dee))
     (amount "93.00 CHF") (reference batch-1/dee))
    (held ("93.00 CHF"))
    ((status approved) (progress processing) (approvals 1) (required 1)
     (revision 4) (lines ((dee funded) (eve funded) (fay failed))))
    (((account org:1/chf) (hold payout:req-1:dee)
      (conversion
       (((quote_ref fixed:EUR:CHF) (sell "100.00 EUR") (buy "93.00 CHF"))))))
    |}]
;;

let%expect_test "hook refusals and missing funding accounts" =
  let balances = ledger [ eur "200.00" ] in
  let b = approved_batch [ line "dee" (chf "1.00"); line "eve" (usdc "1.00") ] in
  let source =
    Funding.Source.with_conversion
      [ Money.Currency.chf, org_account Money.Currency.chf
      ; Money.Currency.usdc, org_account Money.Currency.usdc
      ]
      ~funding_currency:Money.Currency.eur
      ~hook:Conversion.Hook.none
  in
  print_plan (Funding.plan balances source b ~mode:Line_by_line ~now:(at 2) () |> Or_error.ok_exn);
  let source =
    Funding.Source.with_conversion
      (List.map Money.Currency.[ eur; chf; usdc ] ~f:(fun c -> c, org_account c))
      ~funding_currency:Money.Currency.eur
      ~hook:Conversion.Hook.none
  in
  print_plan (Funding.plan balances source b ~mode:Line_by_line ~now:(at 2) () |> Or_error.ok_exn);
  [%expect
    {|
    ((id dee) (fail (No_funding_account EUR)))
    ((id eve) (fail (No_funding_account EUR)))
    (held ())
    ((id dee) (fail (Conversion_unavailable "no conversion configured")))
    ((id eve) (fail (Conversion_unavailable "no conversion configured")))
    (held ())
    |}]
;;

let%expect_test "the ledger refuses a second plan built on the same balances" =
  let balances = ledger [ eur "1000.00" ] in
  let b1 = approved_batch ~id:"batch-1" [ line "ada" (eur "800.00") ] in
  let b2 =
    approved_batch
      ~id:"batch-2"
      [ Line.create
          ~id:(Line_id.of_string "bob")
          ~key:(Line_key.of_string "req-2:bob")
          ~payee:(sepa_payee "bob")
          ~rail:Sepa_credit
          ~amount:(eur "800.00")
          ~now:t0
          ()
        |> Or_error.ok_exn
      ]
  in
  let entries b =
    match Funding.plan balances source b ~mode:Line_by_line ~now:(at 2) () |> Or_error.ok_exn with
    | Planned { entries; _ } -> entries
    | Refused _ -> assert false
  in
  let after_first = book balances (entries b1) in
  print_s
    [%sexp
      (Payments_core.Booking.apply after_first (entries b2) |> Or_error.map ~f:ignore
       : unit Or_error.t)];
  [%expect {|
    (Error
     ("entry would take an account below zero" (id org:1/eur)
      (balance_after "-600.00 EUR") (idempotency_key req-2:bob/fund)))
    |}]
;;

let%expect_test "release returns a funded line's hold" =
  let balances = ledger [ eur "1000.00" ] in
  let b = approved_batch [ line "ada" (eur "600.00") ] in
  let plan = Funding.plan balances source b ~mode:Line_by_line ~now:(at 2) () |> Or_error.ok_exn in
  let b = Funding.apply b plan ~now:(at 2) |> Or_error.ok_exn in
  let balances =
    match plan with
    | Planned { entries; _ } -> book balances entries
    | Refused _ -> assert false
  in
  print_endline (available balances Money.Currency.eur);
  let line = Option.value_exn (Batch.find_line b (Line_id.of_string "ada")) in
  let entry = Funding.release balances line ~now:(at 3) |> Or_error.ok_exn in
  print_s [%sexp (entry.idempotency_key : Ledger.Idempotency_key.t)];
  let balances = book balances [ entry ] in
  print_endline (available balances Money.Currency.eur);
  let b = Batch.cancel_line b ~policy:Approval.Policy.one_approval line.id ~now:(at 3) |> Or_error.ok_exn in
  print_batch b;
  [%expect
    {|
    400.00 EUR
    req-1:ada/release
    1000.00 EUR
    ((status approved) (progress cancelled) (approvals 1) (required 1)
     (revision 3) (lines ((ada cancelled))))
    |}]
;;
