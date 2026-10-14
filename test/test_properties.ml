open! Core
open Payouts_core
open Helpers

module Op = struct
  type t =
    | Approve
    | Fund
    | Submit
    | Settle
    | Fail
    | Return
    | Cancel
  [@@deriving sexp, quickcheck, enumerate]
end

let funded_from (l : Line.t) : Line.Funded_from.t =
  { account = org_account (Line.currency l); hold = Line_key.hold_id l.key; conversion = None }
;;

let step (l : Line.t) (op : Op.t) ~at =
  match op with
  | Approve -> Line.approve l ~at
  | Fund -> Line.fund l (funded_from l) ~at
  | Submit -> Line.submit l ~transfer:(Payments_core.Transfer.Id.of_string "tr") ~at ()
  | Settle -> Line.settle l ~at
  | Fail -> Line.fail l (Submission_refused "x") ~at
  | Return -> Line.return l ~at ()
  | Cancel -> Line.cancel l ~at
;;

let%test_unit "line moves follow the table, and final statuses absorb" =
  Quickcheck.test
    [%quickcheck.generator: Op.t list]
    ~sexp_of:[%sexp_of: Op.t list]
    ~f:(fun ops ->
      let l, moves =
        List.foldi ops ~init:(line "ada" (chf "1.00"), 0) ~f:(fun i (l, moves) op ->
          let before = l.status in
          match step l op ~at:(at i) with
          | Ok l' ->
            assert (Line_status.can_move ~from:before ~to_:l'.status);
            assert (not (Line_status.is_final before));
            l', moves + 1
          | Error _ -> l, moves)
      in
      [%test_result: int] (List.length l.history) ~expect:(moves + 1);
      (* Once final, nothing moves the line again. *)
      if Line_status.is_final l.status
      then
        List.iter Op.all ~f:(fun op -> assert (Result.is_error (step l op ~at:(at 1000)))))
;;

let%test_unit "approval needs as many different people as the policy asks, never the creator" =
  let actors = List.map [ "maker"; "checker"; "checker-2"; "checker-3" ] ~f:Actor_id.of_string in
  Quickcheck.test
    (Quickcheck.Generator.both
       (Int.gen_incl 0 3)
       (List.gen_with_length 6 (Quickcheck.Generator.of_list actors)))
    ~sexp_of:[%sexp_of: int * Actor_id.t list]
    ~f:(fun (required, approvers) ->
      let policy =
        { Approval.Policy.one_approval with required_approvals = (fun _ -> required) }
      in
      let b =
        Batch.create
          ~id:(Batch_id.of_string "b")
          ~title:"t"
          ~created_by:maker
          ~lines:[ line "ada" (chf "1.00") ]
          ~policy
          ~now:t0
        |> Or_error.ok_exn
      in
      let b =
        List.fold approvers ~init:b ~f:(fun b approver ->
          match Batch.approve b ~policy ~approver ~now:(at 1) with
          | Ok b -> b
          | Error _ -> b)
      in
      let distinct =
        List.filter approvers ~f:(fun a -> not (Actor_id.equal a maker))
        |> List.dedup_and_sort ~compare:Actor_id.compare
        |> List.length
      in
      let approved =
        match b.status with
        | Approved -> true
        | Pending_approval | Rejected _ | Cancelled _ -> false
      in
      [%test_result: bool] approved ~expect:(distinct >= required);
      assert (not (List.exists b.approvals ~f:(fun a -> Actor_id.equal a.by maker)));
      assert (
        not
          (List.contains_dup b.approvals ~compare:(fun (x : Batch.Approval_record.t) y ->
             Actor_id.compare x.by y.by))))
;;

let amounts_gen =
  List.gen_with_length 6 (Int.gen_incl 1 50_000)
  |> Quickcheck.Generator.map ~f:(List.map ~f:(Money.Amount.of_minor_units_int Money.Currency.eur))
;;

let funding_case mode (balance, amounts) =
  let balances = ledger [ Money.Amount.of_minor_units_int Money.Currency.eur balance ] in
  let lines = List.mapi amounts ~f:(fun i a -> line (sprintf "p%d" i) a) in
  let b = approved_batch lines in
  let source = Funding.Source.of_accounts [ Money.Currency.eur, org_account Money.Currency.eur ] in
  let plan = Funding.plan balances source b ~mode ~now:(at 2) () |> Or_error.ok_exn in
  let b = Funding.apply b plan ~now:(at 2) |> Or_error.ok_exn in
  let balances =
    match plan with
    | Planned { entries; _ } -> book balances entries
    | Refused _ -> balances
  in
  b, balances
;;

let funding_gen = Quickcheck.Generator.both (Int.gen_incl 0 150_000) amounts_gen

let%test_unit "line by line funding never over-commits and holds exactly the funded lines" =
  Quickcheck.test
    funding_gen
    ~sexp_of:[%sexp_of: int * Money.Amount.t list]
    ~f:(fun case ->
      let b, balances = funding_case Line_by_line case in
      let account = org_account Money.Currency.eur in
      assert (not (Money.Amount.is_negative (Ledger.Balances.available balances account Money.Currency.eur)));
      let funded = Batch.lines_in b "funded" |> List.map ~f:(fun l -> l.amount) in
      [%test_result: Money.Amount.t]
        (Ledger.Balances.held balances account Money.Currency.eur)
        ~expect:(Money.Amount.sum Money.Currency.eur funded |> Or_error.ok_exn);
      (* Every line was decided: funded or failed for want of money. *)
      [%test_result: int]
        (List.length funded + List.length (Batch.lines_in b "failed"))
        ~expect:(List.length b.lines);
      [%test_result: Reconciliation.Diff.t list]
        (Reconciliation.check b ~balances ~transfers:[])
        ~expect:[])
;;

let%test_unit "all-or-nothing funding funds every line or none" =
  Quickcheck.test
    funding_gen
    ~sexp_of:[%sexp_of: int * Money.Amount.t list]
    ~f:(fun ((balance, amounts) as case) ->
      let b, _ = funding_case All_or_nothing case in
      let total =
        Money.Amount.sum Money.Currency.eur amounts
        |> Or_error.ok_exn
        |> Money.Amount.minor_units_int
        |> Option.value_exn
      in
      let funded = List.length (Batch.lines_in b "funded") in
      let approved = List.length (Batch.lines_in b "approved") in
      if total <= balance
      then [%test_result: int] funded ~expect:(List.length amounts)
      else [%test_result: int] approved ~expect:(List.length amounts))
;;

let%test_unit "batch totals: every line in exactly one bucket" =
  Quickcheck.test
    (List.gen_with_length 5 (List.gen_with_length 4 Op.quickcheck_generator))
    ~sexp_of:[%sexp_of: Op.t list list]
    ~f:(fun per_line ->
      let lines =
        List.mapi per_line ~f:(fun i _ ->
          line (sprintf "p%d" i) (if i % 2 = 0 then chf "3.00" else usdc "2.50"))
      in
      let b = approved_batch lines in
      let b =
        List.foldi per_line ~init:b ~f:(fun i b ops ->
          List.fold ops ~init:b ~f:(fun b op ->
            match
              Batch.update_line b (Line_id.of_string (sprintf "p%d" i)) ~f:(fun l ->
                step l op ~at:(at 5))
            with
            | Ok b -> b
            | Error _ -> b))
      in
      List.iter (Reconciliation.Totals.of_batch b) ~f:(fun row ->
        Reconciliation.Totals.check row |> Or_error.ok_exn);
      [%test_result: int]
        (List.sum (module Int) (Reconciliation.Totals.of_batch b) ~f:(fun r -> r.lines))
        ~expect:(List.length lines))
;;
