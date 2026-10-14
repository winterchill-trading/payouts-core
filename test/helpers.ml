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
