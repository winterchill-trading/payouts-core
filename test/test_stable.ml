open! Core
open Payouts_core
open Helpers

(* Pinned bin_prot shape digests. A change here means stored values written by an earlier
   version can no longer be read: add a V2 instead of editing V1. *)
let%expect_test "stable digests" =
  print_endline [%bin_digest: Batch_id.Stable.V1.t];
  print_endline [%bin_digest: Line_id.Stable.V1.t];
  print_endline [%bin_digest: Actor_id.Stable.V1.t];
  print_endline [%bin_digest: Line_key.Stable.V1.t];
  print_endline [%bin_digest: Failure.Stable.V1.t];
  print_endline [%bin_digest: Line_status.Stable.V1.t];
  print_endline [%bin_digest: Conversion.Stable.V1.t];
  print_endline [%bin_digest: Line.Stable.V1.t];
  print_endline [%bin_digest: Batch.Stable.V1.t];
  print_endline [%bin_digest: Receipt.Stable.V1.t];
  [%expect
    {|
    d9a8da25d5656b016fb4dbdc2e4197fb
    d9a8da25d5656b016fb4dbdc2e4197fb
    d9a8da25d5656b016fb4dbdc2e4197fb
    d9a8da25d5656b016fb4dbdc2e4197fb
    6c9ca001dbebc5be18b8b1c35bba8d0d
    5e233ca245cf78f3c4d75e47cddcd301
    a4ee441073ed849d54af2ef02fd88bf6
    f73ae2bddc0507077937658923828352
    a38258355bce9e76b00f487f3c19f134
    0ba342cd903c112a8cab7c13e3ab8340
    |}]
;;

let%expect_test "a batch round-trips through bin_prot and sexp" =
  let b =
    approved_batch
      [ line ~reference:"Invoice 7" "ada" (eur "12.50"); line "bob" (chf "3.00") ]
  in
  let b =
    Batch.update_line b (Line_id.of_string "bob") ~f:(fun l ->
      Line.fail
        l
        (Insufficient_funds { required = chf "3.00"; available = chf "0.00" })
        ~at:(at 2))
    |> Or_error.ok_exn
  in
  let bin = Binable.to_string (module Batch.Stable.V1) b in
  [%test_result: Batch.t] (Binable.of_string (module Batch.Stable.V1) bin) ~expect:b;
  [%test_result: Batch.t]
    (Batch.Stable.V1.t_of_sexp (Batch.Stable.V1.sexp_of_t b))
    ~expect:b;
  print_s [%sexp (b : Batch.Stable.V1.t)];
  [%expect
    {|
    ((id batch-1) (title "March contractors") (created_by maker)
     (created_at "2027-03-01 09:00:00Z")
     (lines
      (((id ada) (key req-1:ada)
        (payee
         ((id ben-ada) (owner org-1) (name ada)
          (destination (Bank_account (iban DE89370400440532013000) (bic ())))
          (trusted false) (first_seen "2027-03-01 09:00:00Z") (payee_check ())))
        (rail Sepa_credit) (amount "12.50 EUR") (reference "Invoice 7")
        (status Approved)
        (history
         ((Approved "2027-03-01 09:01:00Z") (Draft "2027-03-01 09:00:00Z")))
        (funded_from ()) (transfer ()) (provider_ref ()))
       ((id bob) (key req-1:bob)
        (payee
         ((id ben-bob) (owner org-1) (name bob)
          (destination (Internal (account customer:bob))) (trusted false)
          (first_seen "2027-03-01 09:00:00Z") (payee_check ())))
        (rail Intraledger) (amount "3.00 CHF") (reference "")
        (status
         (Failed
          (Insufficient_funds (required "3.00 CHF") (available "0.00 CHF"))))
        (history
         (((Failed
            (Insufficient_funds (required "3.00 CHF") (available "0.00 CHF")))
           "2027-03-01 09:02:00Z")
          (Approved "2027-03-01 09:01:00Z") (Draft "2027-03-01 09:00:00Z")))
        (funded_from ()) (transfer ()) (provider_ref ()))))
     (approvals_required 1)
     (approvals (((by checker) (at "2027-03-01 09:01:00Z")))) (status Approved)
     (decided_at ("2027-03-01 09:01:00Z")) (revision 2))
    |}]
;;

let%expect_test "a line on a UK rail round-trips" =
  let payee =
    Payments_core.Beneficiary.create
      ~id:(Payments_core.Beneficiary.Id.of_string "ben-uk")
      ~owner:"org-1"
      ~name:"Ada Example"
      ~rail:Faster_payments
      ~now:t0
      "04-00-04 12345678"
    |> Or_error.ok_exn
  in
  let gbp s = Money.Amount.of_decimal_string Money.Currency.gbp s |> Or_error.ok_exn in
  let create amount =
    Line.create
      ~id:(Line_id.of_string "uk")
      ~key:(Line_key.of_string "req-9:uk")
      ~payee
      ~rail:Faster_payments
      ~amount
      ~now:t0
      ()
  in
  print_s [%sexp (create (eur "1.00") |> Or_error.map ~f:ignore : unit Or_error.t)];
  let line = create (gbp "250.00") |> Or_error.ok_exn in
  let bin = Binable.to_string (module Line.Stable.V1) line in
  [%test_result: Line.t] (Binable.of_string (module Line.Stable.V1) bin) ~expect:line;
  [%expect
    {|
    (Error
     ("rail pays another currency" (rail Faster_payments) (required GBP)
      (currency EUR)))
    |}]
;;
