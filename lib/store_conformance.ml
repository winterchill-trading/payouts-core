open! Core
module Beneficiary = Payments_core.Beneficiary

(* The functor's [Store] argument hides the library module of the same name. *)
module Results = Store

let now = Time_ns.of_string_with_utc_offset "2027-01-04 10:00:00Z"
let chf s = Money.Amount.of_decimal_string Money.Currency.chf s |> Or_error.ok_exn
let maker = Actor_id.of_string "conformance-maker"
let checker = Actor_id.of_string "conformance-checker"
let policy = Approval.Policy.one_approval

let line ~batch name amount =
  let payee =
    Beneficiary.create
      ~id:(Beneficiary.Id.of_string ("conformance-" ^ name))
      ~owner:"conformance"
      ~name
      ~rail:Intraledger
      ~now
      ("conformance:" ^ name)
    |> Or_error.ok_exn
  in
  Line.create
    ~id:(Line_id.of_string name)
    ~key:(Line_key.of_string (sprintf "conformance-%s-%s" batch name))
    ~payee
    ~rail:Intraledger
    ~amount
    ~now
    ()
  |> Or_error.ok_exn
;;

let batch ?(key_batch = "") id lines =
  let key_batch = if String.is_empty key_batch then id else key_batch in
  Batch.create
    ~id:(Batch_id.of_string ("conformance-" ^ id))
    ~title:"conformance"
    ~created_by:maker
    ~lines:(List.map lines ~f:(fun (name, amount) -> line ~batch:key_batch name amount))
    ~policy
    ~now
  |> Or_error.ok_exn
;;

module Make (M : Monad.S) (Store : Store.S with type 'a io := 'a M.t) = struct
  open M.Let_syntax

  let expect name ok = if ok then Ok () else Or_error.error_s [%message "failed" name]

  let check store =
    let a = batch "a" [ "x", chf "10.00"; "y", chf "20.00" ] in
    let%bind inserted = Store.insert store a in
    let%bind retried = Store.insert store a in
    let%bind other_content =
      Store.insert store (batch "a" [ "x", chf "11.00"; "y", chf "20.00" ])
    in
    (* Batch b reuses a line key of batch a. *)
    let%bind key_reused = Store.insert store (batch ~key_batch:"a" "b" [ "x", chf "10.00" ]) in
    let%bind b_missing = Store.find store (Batch_id.of_string "conformance-b") in
    let%bind by_key = Store.find_by_line_key store (Line_key.of_string "conformance-a-y") in
    let approved =
      match Batch.approve a ~policy ~approver:checker ~now with
      | Ok b -> b
      | Error r -> raise_s [%sexp (r : Approval.Refusal.t)]
    in
    let%bind stale = Store.update store approved ~expected_revision:5 in
    let%bind updated = Store.update store approved ~expected_revision:0 in
    let%bind replayed = Store.update store approved ~expected_revision:0 in
    let%bind missing = Store.update store (batch "zz" [ "x", chf "1.00" ]) ~expected_revision:0 in
    let%bind found = Store.find store a.id in
    let fund (l : Line.t) =
      Line.fund
        l
        { account = Ledger.Account_id.of_string "conformance:payer"
        ; hold = Line_key.hold_id l.key
        ; conversion = None
        }
        ~at:now
    in
    let transfer = Payments_core.Transfer.Id.of_string "conformance-tr-x" in
    let submitted =
      Batch.update_line approved (Line_id.of_string "x") ~f:(fun l ->
        Or_error.bind (fund l) ~f:(fun l -> Line.submit l ~transfer ~at:now ()))
      |> Or_error.ok_exn
    in
    let%bind (_ : Results.Update_result.t) =
      Store.update store submitted ~expected_revision:approved.revision
    in
    let%bind by_transfer = Store.find_by_transfer store transfer in
    let c = batch "c" [ "z", chf "5.00" ] in
    let%bind (_ : Results.Insert_result.t) = Store.insert store c in
    let%bind all = Store.list store () in
    let%bind awaiting = Store.list store ~progress:Awaiting_approval () in
    let%bind approved_queue = Store.lines_in store "approved" in
    let%bind submitted_queue = Store.lines_in store "submitted" in
    let ids batches = List.map batches ~f:(fun (b : Batch.t) -> Batch_id.to_string b.id) in
    let pairs = List.map ~f:(fun (b, l) -> Batch_id.to_string b, Line_id.to_string l) in
    return
      (Or_error.combine_errors_unit
         [ expect
             "insert"
             (match (inserted : Results.Insert_result.t) with
              | Inserted -> true
              | Duplicate _ | Conflict _ -> false)
         ; expect
             "retried insert is a duplicate"
             (match (retried : Results.Insert_result.t) with
              | Duplicate b -> Batch.equal b a
              | Inserted | Conflict _ -> false)
         ; expect
             "same id, other content conflicts"
             (match (other_content : Results.Insert_result.t) with
              | Conflict _ -> true
              | Inserted | Duplicate _ -> false)
         ; expect
             "reused line key conflicts"
             (match (key_reused : Results.Insert_result.t) with
              | Conflict _ -> true
              | Inserted | Duplicate _ -> false)
         ; expect "a refused batch is not stored" (Option.is_none b_missing)
         ; expect
             "line key index"
             ([%equal: (Batch_id.t * Line_id.t) option]
                by_key
                (Some (a.id, Line_id.of_string "y")))
         ; expect
             "stale update refused"
             (match (stale : Results.Update_result.t) with
              | Stale b -> Batch.equal b a
              | Updated | Not_found -> false)
         ; expect
             "update"
             (match (updated : Results.Update_result.t) with
              | Updated -> true
              | Stale _ | Not_found -> false)
         ; expect
             "a second write from the same read is stale"
             (match (replayed : Results.Update_result.t) with
              | Stale b -> Batch.equal b approved
              | Updated | Not_found -> false)
         ; expect
             "update of an unknown batch"
             (match (missing : Results.Update_result.t) with
              | Not_found -> true
              | Updated | Stale _ -> false)
         ; expect "find" ([%equal: Batch.t option] found (Some approved))
         ; expect
             "transfer index"
             ([%equal: (Batch_id.t * Line_id.t) option]
                by_transfer
                (Some (a.id, Line_id.of_string "x")))
         ; expect
             "list, oldest first then by id"
             ([%equal: string list] (ids all) [ "conformance-a"; "conformance-c" ])
         ; expect
             "list by progress"
             ([%equal: string list] (ids awaiting) [ "conformance-c" ])
         ; expect
             "work queue: approved"
             ([%equal: (string * string) list]
                (pairs approved_queue)
                [ "conformance-a", "y" ])
         ; expect
             "work queue: submitted"
             ([%equal: (string * string) list]
                (pairs submitted_queue)
                [ "conformance-a", "x" ])
         ])
  ;;
end
