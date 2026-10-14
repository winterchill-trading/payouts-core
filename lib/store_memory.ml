open! Core

module Make (M : Monad.S) = struct
  type 'a io = 'a M.t

  type t =
    { batches : Batch.t Batch_id.Table.t
    ; line_keys : (Batch_id.t * Line_id.t) Line_key.Table.t
    ; transfers : (Batch_id.t * Line_id.t) Payments_core.Transfer.Id.Table.t
    }

  let create () =
    { batches = Batch_id.Table.create ()
    ; line_keys = Line_key.Table.create ()
    ; transfers = Payments_core.Transfer.Id.Table.create ()
    }
  ;;

  let index_transfers t (batch : Batch.t) =
    List.iter batch.lines ~f:(fun line ->
      Option.iter line.transfer ~f:(fun id ->
        Hashtbl.set t.transfers ~key:id ~data:(batch.id, line.id)))
  ;;

  let insert t (batch : Batch.t) =
    M.return
      (match Hashtbl.find t.batches batch.id with
       | Some existing when Store.same_request existing batch -> Duplicate existing
       | Some _ -> Conflict "batch id already used by another batch"
       | None ->
         (match
            List.find batch.lines ~f:(fun l -> Hashtbl.mem t.line_keys l.key)
          with
          | Some line ->
            Conflict (sprintf "line key %s belongs to another batch" (Line_key.to_string line.key))
          | None ->
            Hashtbl.set t.batches ~key:batch.id ~data:batch;
            List.iter batch.lines ~f:(fun l ->
              Hashtbl.set t.line_keys ~key:l.key ~data:(batch.id, l.id));
            index_transfers t batch;
            Inserted)
        : Store.Insert_result.t)
  ;;

  let find t id = M.return (Hashtbl.find t.batches id)

  let update t (batch : Batch.t) ~expected_revision =
    M.return
      (match Hashtbl.find t.batches batch.id with
       | None -> Not_found
       | Some current when current.revision <> expected_revision -> Stale current
       | Some _ ->
         Hashtbl.set t.batches ~key:batch.id ~data:batch;
         index_transfers t batch;
         Updated
        : Store.Update_result.t)
  ;;

  let find_by_line_key t key = M.return (Hashtbl.find t.line_keys key)
  let find_by_transfer t id = M.return (Hashtbl.find t.transfers id)

  let sorted t =
    Hashtbl.data t.batches
    |> List.sort ~compare:(fun (a : Batch.t) (b : Batch.t) ->
      match Time_ns.compare a.created_at b.created_at with
      | 0 -> Batch_id.compare a.id b.id
      | c -> c)
  ;;

  let list t ?progress () =
    M.return
      (match progress with
       | None -> sorted t
       | Some p ->
         List.filter (sorted t) ~f:(fun b -> Batch.Progress.equal (Batch.progress b) p))
  ;;

  let lines_in t name =
    M.return
      (List.concat_map (sorted t) ~f:(fun b ->
         List.map (Batch.lines_in b name) ~f:(fun l -> b.id, l.id)))
  ;;
end
