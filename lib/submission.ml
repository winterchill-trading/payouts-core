open! Core
module Transfer = Payments_core.Transfer

let funded_account (line : Line.t) =
  match line.status, line.funded_from with
  | Funded, Some from -> Ok from
  | _ ->
    Or_error.error_s
      [%message
        "line is not funded"
          ~line:(line.key : Line_key.t)
          ~status:(line.status : Line_status.t)]
;;

let draft_transfer (line : Line.t) ~id ?details ~now () =
  let open Or_error.Let_syntax in
  let%bind from = funded_account line in
  Transfer.draft
    ~id
    ~rail:line.rail
    ~account:from.account
    ~beneficiary:line.payee
    ~amount:line.amount
    ~reference:line.reference
    ?details
    ~now
    ()
;;

let check_match (line : Line.t) (from : Line.Funded_from.t) (transfer : Transfer.t) =
  let beneficiary =
    match transfer.counterparty with
    | Beneficiary b -> Some b
    | External _ -> None
  in
  let mismatch what = Or_error.error_s [%message "transfer does not match the line" what] in
  if not (Transfer.Direction.equal transfer.direction Out)
  then mismatch "direction"
  else if not (Payments_core.Rail.equal transfer.rail line.rail)
  then mismatch "rail"
  else if not (Money.Amount.equal transfer.amount line.amount)
  then mismatch "amount"
  else if not (Ledger.Account_id.equal transfer.account from.account)
  then mismatch "account"
  else if not
            (Option.value_map beneficiary ~default:false ~f:(fun b ->
               Payments_core.Beneficiary.Id.equal b.id line.payee.id))
  then mismatch "payee"
  else Ok ()
;;

let submit chart balances (batch : Batch.t) id ~(transfer : Transfer.t) ~event_id ~now =
  let open Or_error.Let_syntax in
  let%bind line =
    match Batch.find_line batch id with
    | Some l -> Ok l
    | None -> Or_error.error_s [%message "no such line" (id : Line_id.t)]
  in
  let%bind from = funded_account line in
  let%bind () = check_match line from transfer in
  let%bind release =
    Ledger.Hold.release
      balances
      ~hold_id:from.hold
      ~idempotency_key:(Line_key.derive line.key Submit)
      ~reference:(Transfer.Id.to_string transfer.id)
      ~effective_at:now
      ~recorded_at:now
      ()
  in
  let%bind released = Payments_core.Booking.apply balances [ release ] in
  let%bind transfer_entries =
    Payments_core.Booking.transition
      chart
      released
      transfer
      ~to_:Submitted
      ~event_id
      ~at:now
  in
  let%bind batch =
    Batch.update_line batch id ~f:(fun l ->
      Line.submit l ~transfer:transfer.id ?provider_ref:transfer.provider_ref ~at:now ())
  in
  return (batch, release :: transfer_entries)
;;

let observe batch (transfer : Transfer.t) ~now =
  match Batch.find_line_by_transfer batch transfer.id with
  | None ->
    Or_error.error_s
      [%message "no line is paid by this transfer" ~transfer:(transfer.id : Transfer.Id.t)]
  | Some line -> Batch.update_line batch line.id ~f:(fun l -> Line.observe l transfer ~at:now)
;;
