open! Core
module Utc_time = Payments_core.Utc_time

module Outcome = struct
  module Stable = struct
    module V1 = struct
      type t =
        | In_progress
        | Paid
        | Failed of Failure.Stable.V1.t
        | Returned of Payments_core.Iso_reason.Stable.V1.t option
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  include Stable.V1

  let name = function
    | In_progress -> "in_progress"
    | Paid -> "paid"
    | Failed _ -> "failed"
    | Returned _ -> "returned"
  ;;
end

module Stable = struct
  module V1 = struct
    type t =
      { batch : Batch_id.Stable.V1.t
      ; batch_title : string
      ; line : Line_id.Stable.V1.t
      ; key : Line_key.Stable.V1.t
      ; payee_name : string
      ; destination : string
      ; rail : Payments_core.Rail.Stable.V1.t
      ; amount : Money.Amount.Stable.V1.t
      ; reference : string
      ; outcome : Outcome.Stable.V1.t
      ; transfer : Payments_core.Transfer.Id.Stable.V1.t
      ; provider_ref : string option
      ; created_by : Actor_id.Stable.V1.t
      ; approved_by : Actor_id.Stable.V1.t list
      ; conversion : Conversion.Stable.V1.t option
      ; timeline : (string * Utc_time.Stable.V1.t) list
      }
    [@@deriving bin_io, sexp, compare, equal]
  end
end

include Stable.V1

let last_four s =
  let n = String.length s in
  "****" ^ if n <= 4 then s else String.sub s ~pos:(n - 4) ~len:4
;;

(* payments-core adds destination kinds as it learns new schemes (UK sort code and
   account number, for instance). The final wildcard keeps receipts compiling across
   those versions; it is silenced because it is unused whenever this match is complete. *)
let mask_destination (d : Payments_core.Beneficiary.Destination.t) =
  match[@warning "-11"] d with
  | Bank_account { iban; _ } -> "IBAN " ^ last_four (Payments_core.Iban.to_string iban)
  | Crypto { address; _ } ->
    "address " ^ last_four (Payments_core.Crypto_address.address address)
  | Lightning (Address { domain; _ }) -> "Lightning address ****@" ^ domain
  | Lightning (Invoice _) -> "Lightning invoice"
  | Lightning (Lnurl _) -> "LNURL"
  | Internal { account } -> "account " ^ last_four account
  | _ -> "account"
;;

let outcome (line : Line.t) : Outcome.t option =
  match line.status with
  | Submitted -> Some In_progress
  | Settled -> Some Paid
  | Failed f -> Option.map line.transfer ~f:(fun _ -> Outcome.Failed f)
  | Returned r -> Some (Returned r)
  | Draft | Approved | Funded | Cancelled -> None
;;

let build (batch : Batch.t) (line : Line.t) =
  match outcome line, line.transfer with
  | Some outcome, Some transfer ->
    Some
      { batch = batch.id
      ; batch_title = batch.title
      ; line = line.id
      ; key = line.key
      ; payee_name = line.payee.name
      ; destination = mask_destination line.payee.destination
      ; rail = line.rail
      ; amount = line.amount
      ; reference = line.reference
      ; outcome
      ; transfer
      ; provider_ref = line.provider_ref
      ; created_by = batch.created_by
      ; approved_by = List.map batch.approvals ~f:(fun a -> a.by)
      ; conversion = Option.bind line.funded_from ~f:(fun f -> f.conversion)
      ; timeline =
          List.rev_map line.history ~f:(fun (status, at) -> Line_status.name status, at)
      }
  | _ -> None
;;

let of_line batch id =
  match Batch.find_line batch id with
  | None -> Or_error.error_s [%message "no such line" (id : Line_id.t)]
  | Some line ->
    (match build batch line with
     | Some r -> Ok r
     | None ->
       Or_error.error_s
         [%message
           "no receipt before submission"
             ~line:(id : Line_id.t)
             ~status:(Line_status.name line.status : string)])
;;

let all (batch : Batch.t) = List.filter_map batch.lines ~f:(build batch)

let to_text t =
  let time at = Time_ns.to_sec_string at ~zone:Time_float.Zone.utc ^ "Z" in
  let rows =
    [ "batch", sprintf "%s (%s)" t.batch_title (Batch_id.to_string t.batch)
    ; "line", Line_id.to_string t.line
    ; "payee", t.payee_name
    ; "to", t.destination
    ; "rail", Payments_core.Rail.to_string t.rail
    ; "amount", Money.Amount.to_string t.amount
    ]
    @ (if String.is_empty t.reference then [] else [ "reference", t.reference ])
    @ (match t.conversion with
       | None -> []
       | Some c ->
         [ ( "converted"
           , sprintf
               "%s -> %s (%s)"
               (Money.Amount.to_string c.sell)
               (Money.Amount.to_string c.buy)
               c.quote_ref )
         ])
    @ [ ( "outcome"
        , match t.outcome with
          | Failed f -> "failed: " ^ Failure.code f
          | Returned (Some r) -> "returned: " ^ Payments_core.Iso_reason.to_code r
          | o -> Outcome.name o )
      ; "transfer", Payments_core.Transfer.Id.to_string t.transfer
      ]
    @ Option.value_map t.provider_ref ~default:[] ~f:(fun r -> [ "provider ref", r ])
    @ [ "created by", Actor_id.to_string t.created_by
      ; ( "approved by"
        , if List.is_empty t.approved_by
          then "(automatic)"
          else String.concat ~sep:", " (List.map t.approved_by ~f:Actor_id.to_string) )
      ]
    @ List.map t.timeline ~f:(fun (name, at) -> name, time at)
  in
  List.map rows ~f:(fun (label, value) -> sprintf "%-13s %s" (label ^ ":") value)
  |> String.concat ~sep:"\n"
  |> fun s -> s ^ "\n"
;;
