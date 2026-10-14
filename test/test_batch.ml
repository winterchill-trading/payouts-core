open! Core
open Payouts_core
open Helpers

let policy = Approval.Policy.one_approval

let show_refusal = function
  | Ok b -> print_batch b
  | Error r -> print_s [%sexp (r : Approval.Refusal.t)]
;;

let%expect_test "creation checks lines and title" =
  let create ?(title = "March") lines =
    Batch.create
      ~id:(Batch_id.of_string "b")
      ~title
      ~created_by:maker
      ~lines
      ~policy
      ~now:t0
    |> Or_error.map ~f:(fun _ -> "ok")
    |> [%sexp_of: string Or_error.t]
    |> print_s
  in
  create [];
  create ~title:"  " [ line "ada" (eur "1.00") ];
  create [ line "ada" (eur "1.00"); line "ada" (eur "2.00") ];
  create
    [ line "ada" (eur "1.00")
    ; Line.approve (line "bob" (eur "1.00")) ~at:t0 |> Or_error.ok_exn
    ];
  create [ line "ada" (eur "1.00"); line "bob" (chf "2.00") ];
  [%expect
    {|
    (Error "a batch needs at least one line")
    (Error "empty title")
    (Error "duplicate line id")
    (Error ("line is not a draft" (line req-1:bob) (status Approved)))
    (Ok ok)
    |}]
;;

let%expect_test "maker-checker, one approval per person, then approved" =
  let b = batch [ line "ada" (eur "100.00"); line "bob" (chf "50.00") ] in
  print_batch b;
  print_s [%sexp (Batch.totals b : Money.Amount.t list)];
  show_refusal (Batch.approve b ~policy ~approver:maker ~now:(at 1));
  let b = Batch.approve b ~policy ~approver:checker ~now:(at 1) |> Result.ok |> Option.value_exn in
  print_batch b;
  show_refusal (Batch.approve b ~policy ~approver:second_checker ~now:(at 2));
  [%expect
    {|
    ((status pending_approval) (progress awaiting_approval) (approvals 0)
     (required 1) (revision 0) (lines ((ada draft) (bob draft))))
    ("50.00 CHF" "100.00 EUR")
    Own_batch
    ((status approved) (progress processing) (approvals 1) (required 1)
     (revision 1) (lines ((ada approved) (bob approved))))
    Not_pending
    |}]
;;

let%expect_test "per-currency thresholds" =
  let limit amount currency =
    if Money.Currency.equal currency Money.Currency.eur then Some (eur amount) else None
  in
  let policy =
    Approval.Policy.thresholds
      ~auto_approve_up_to:(limit "500.00")
      ~second_approver_above:(limit "10000.00")
      ~authorize:(fun actor ->
        if Actor_id.equal actor (Actor_id.of_string "viewer")
        then Error "role_required"
        else Ok ())
      ()
  in
  let create lines =
    Batch.create
      ~id:(Batch_id.of_string "b")
      ~title:"t"
      ~created_by:maker
      ~lines
      ~policy
      ~now:t0
    |> Or_error.ok_exn
  in
  print_batch (create [ line "ada" (eur "500.00") ]);
  print_batch (create [ line "ada" (eur "500.00"); line "bob" (chf "1.00") ]);
  let big = create [ line "ada" (eur "6000.00"); line "bob" (eur "4000.01") ] in
  print_batch big;
  show_refusal (Batch.approve big ~policy ~approver:(Actor_id.of_string "viewer") ~now:(at 1));
  let big = Batch.approve big ~policy ~approver:checker ~now:(at 1) |> Result.ok |> Option.value_exn in
  show_refusal (Batch.approve big ~policy ~approver:checker ~now:(at 2));
  show_refusal (Batch.approve big ~policy ~approver:second_checker ~now:(at 2));
  [%expect
    {|
    ((status approved) (progress processing) (approvals 0) (required 0)
     (revision 0) (lines ((ada approved))))
    ((status pending_approval) (progress awaiting_approval) (approvals 0)
     (required 1) (revision 0) (lines ((ada draft) (bob draft))))
    ((status pending_approval) (progress awaiting_approval) (approvals 0)
     (required 2) (revision 0) (lines ((ada draft) (bob draft))))
    (Not_allowed role_required)
    Already_approved
    ((status approved) (progress processing) (approvals 2) (required 2)
     (revision 2) (lines ((ada approved) (bob approved))))
    |}]
;;

let%expect_test "reject and cancel" =
  let b = batch [ line "ada" (eur "100.00") ] in
  show_refusal (Batch.reject b ~policy ~by:maker ~note:"oops" ~now:(at 1));
  show_refusal (Batch.reject b ~policy ~by:checker ~note:"wrong month" ~now:(at 1));
  show_refusal (Batch.cancel b ~policy ~by:maker ~now:(at 1));
  let approved = approved_batch [ line "ada" (eur "100.00") ] in
  show_refusal (Batch.cancel approved ~policy ~by:maker ~now:(at 2));
  [%expect
    {|
    Own_batch
    ((status rejected) (progress rejected) (approvals 0) (required 1)
     (revision 1) (lines ((ada cancelled))))
    ((status cancelled) (progress cancelled) (approvals 0) (required 1)
     (revision 1) (lines ((ada cancelled))))
    Not_pending
    |}]
;;

let%expect_test "cancelling a line before approval clears approvals" =
  let policy =
    Approval.Policy.thresholds
      ~second_approver_above:(fun _ -> Some (eur "1000.00"))
      ()
  in
  let b =
    Batch.create
      ~id:(Batch_id.of_string "b")
      ~title:"t"
      ~created_by:maker
      ~lines:[ line "ada" (eur "900.00"); line "bob" (eur "900.00") ]
      ~policy
      ~now:t0
    |> Or_error.ok_exn
  in
  let b = Batch.approve b ~policy ~approver:checker ~now:(at 1) |> Result.ok |> Option.value_exn in
  print_batch b;
  let b = Batch.cancel_line b ~policy (Line_id.of_string "bob") ~now:(at 2) |> Or_error.ok_exn in
  print_batch b;
  let b = Batch.cancel_line b ~policy (Line_id.of_string "ada") ~now:(at 3) |> Or_error.ok_exn in
  print_batch b;
  show_refusal (Batch.approve b ~policy ~approver:checker ~now:(at 4));
  [%expect
    {|
    ((status pending_approval) (progress awaiting_approval) (approvals 1)
     (required 2) (revision 1) (lines ((ada draft) (bob draft))))
    ((status pending_approval) (progress awaiting_approval) (approvals 0)
     (required 1) (revision 2) (lines ((ada draft) (bob cancelled))))
    ((status pending_approval) (progress cancelled) (approvals 0) (required 1)
     (revision 3) (lines ((ada cancelled) (bob cancelled))))
    Not_pending
    |}]
;;

let%expect_test "progress after approval: partial failure" =
  let b =
    approved_batch [ line "ada" (chf "1.00"); line "bob" (chf "2.00"); line "cy" (chf "3.00") ]
  in
  let step b name f = Batch.update_line b (Line_id.of_string name) ~f |> Or_error.ok_exn in
  let fund (l : Line.t) =
    Line.fund
      l
      { account = Ledger.Account_id.of_string "org:1/chf"
      ; hold = Line_key.hold_id l.key
      ; conversion = None
      }
      ~at:(at 2)
  in
  let submit name (l : Line.t) =
    Line.submit l ~transfer:(Payments_core.Transfer.Id.of_string ("tr-" ^ name)) ~at:(at 3) ()
  in
  let b = step b "ada" fund in
  let b = step b "ada" (submit "ada") in
  let b = step b "bob" fund in
  let b = step b "bob" (submit "bob") in
  let b =
    step b "cy" (fun l ->
      Line.fail
        l
        (Insufficient_funds { required = chf "3.00"; available = chf "0.00" })
        ~at:(at 2))
  in
  print_batch b;
  let b = step b "ada" (fun l -> Line.settle l ~at:(at 4)) in
  let b = step b "bob" (fun l -> Line.fail l (Submission_refused "closed") ~at:(at 4)) in
  print_batch b;
  print_s
    [%sexp
      (Batch.find_line_by_transfer b (Payments_core.Transfer.Id.of_string "tr-ada")
       |> Option.map ~f:(fun l -> l.id)
       : Line_id.t option)];
  print_s
    [%sexp
      (Batch.update_line b (Line_id.of_string "zed") ~f:Or_error.return
       |> Or_error.map ~f:ignore
       : unit Or_error.t)];
  [%expect
    {|
    ((status approved) (progress processing) (approvals 1) (required 1)
     (revision 6) (lines ((ada submitted) (bob submitted) (cy failed))))
    ((status approved) (progress completed_with_failures) (approvals 1)
     (required 1) (revision 8) (lines ((ada settled) (bob failed) (cy failed))))
    (ada)
    (Error ("no such line" (id zed)))
    |}]
;;
