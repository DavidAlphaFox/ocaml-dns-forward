(*
 * Copyright (C) 2016 David Scott <dave@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)
module Lwt_result = Dns_forward_lwt_result (* remove when this is available *)

let src =
  let src = Logs.Src.create "Dns_forward" ~doc:"DNS over SOCKETS" in
  Logs.Src.set_level src (Some Logs.Debug);
  src

module Log = (val Logs.src_log src : Logs.LOG)

module Client = struct

  module type S = Dns_forward_s.RPC_CLIENT

  module Make
    (Sockets: Dns_forward_s.FLOW_CLIENT with type address = Ipaddr.t * int)
    (Packet: Dns_forward_s.READERWRITER with type flow = Sockets.flow)
    (Time: V1_LWT.TIME) = struct
    type address = Dns_forward_config.address
    type request = Cstruct.t
    type response = Cstruct.t

    type t = {
      address: address;
      mutable rw: Packet.t option;
      mutable disconnect_on_idle: unit Lwt.t;
      wakeners: (int, (Cstruct.t, [ `Msg of string ]) Result.result Lwt.u) Hashtbl.t;
      m: Lwt_mutex.t;
      free_ids: Dns_forward_free_id.t;
    }

    module FlowError = Dns_forward_error.FromFlowError(Sockets)

    let disconnect t =
      Lwt_mutex.with_lock t.m
        (fun () ->
          match t with
          | { rw = Some rw; _ } as t ->
            t.rw <- None;
            let tbl = Hashtbl.copy t.wakeners in
            Hashtbl.clear t.wakeners;
            let error = Result.Error (`Msg "connection to server was closed") in
            Hashtbl.iter (fun id u ->
              Log.err (fun f -> f "disconnect: failing request with id %d" id);
              Dns_forward_free_id.put t.free_ids id;
              Lwt.wakeup_later u error
            ) tbl;
            Packet.close rw
          | _ -> Lwt.return_unit
        )

    (* Receive all the responses and demux to the right thread. When the connection
       is closed, `read_buffer` will fail and this thread will exit. *)
    let dispatcher t rw () =
      let open Lwt.Infix in
      let rec loop () =
        Packet.read rw
        >>= function
        | Result.Error (`Msg m) ->
          Log.info (fun f -> f "%s: dispatcher shutting down" m);
          disconnect t
        | Result.Ok buffer ->
          let buf = Dns.Buf.of_cstruct buffer in
          begin match Dns.Protocol.Server.parse (Dns.Buf.sub buf 0 (Cstruct.len buffer)) with
          | None ->
            Log.err (fun f -> f "failed to parse response");
            Lwt.fail (Failure "failed to parse response")
          | Some response ->
            let client_id = response.Dns.Packet.id in
            if Hashtbl.mem t.wakeners client_id then begin
              let u = Hashtbl.find t.wakeners client_id in
              Hashtbl.remove t.wakeners client_id;
              Dns_forward_free_id.put t.free_ids client_id;
              Lwt.wakeup_later u (Result.Ok buffer)
            end else begin
              Log.err (fun f -> f "failed to find a wakener for id %d" client_id);
            end;
            loop ()
          end
      in
      Lwt.catch loop
        (fun e ->
          Log.info (fun f -> f "dispatcher caught %s" (Printexc.to_string e));
          Lwt.return_unit
        )

    let get_rw t =
      let open Lwt_result.Infix in
      Lwt.cancel t.disconnect_on_idle;
      Lwt_mutex.with_lock t.m
        (fun () -> match t.rw with
          | None ->
            Sockets.connect (t.address.Dns_forward_config.ip, t.address.Dns_forward_config.port)
            >>= fun flow ->
            let rw = Packet.connect flow in
            t.rw <- Some rw;
            Lwt.async (dispatcher t rw);
            Lwt_result.return rw
          | Some rw ->
            Lwt_result.return rw)
      >>= fun rw ->
      (* Add a fresh idle timer *)
      t.disconnect_on_idle <- (let open Lwt.Infix in Time.sleep 30. >>= fun () -> disconnect t);
      Lwt_result.return rw

    let connect address =
      let rw = None in
      let m = Lwt_mutex.create () in
      let disconnect_on_idle = Lwt.return_unit in
      let wakeners = Hashtbl.create 7 in
      let free_ids = Dns_forward_free_id.make () in
      Lwt_result.return { address; rw; disconnect_on_idle; wakeners; m; free_ids }

    let rpc (t: t) buffer =
      let buf = Dns.Buf.of_cstruct buffer in
      match Dns.Protocol.Server.parse (Dns.Buf.sub buf 0 (Cstruct.len buffer)) with
      | None ->
        Log.err (fun f -> f "failed to parse request");
        Lwt_result.fail (`Msg "failed to parse request")
      | Some request ->
        (* Note: the received request id is scoped to the connection with the
           client. Since we are multiplexing requests to a single server we need
           to track used/unused ids on the link to the server and remember the
           mapping to the client. *)
        let open Lwt.Infix in
        (* The id whose scope is the link to the client *)
        let client_id = request.Dns.Packet.id in
        (* The id whose scope is the link to the server *)
        Dns_forward_free_id.get t.free_ids
        >>= fun free_id ->
        (* Rewrite the query id before forwarding *)
        Cstruct.BE.set_uint16 buffer 0 free_id;
        Log.debug (fun f -> f "mapping DNS id %d -> %d" client_id free_id);

        let th, u = Lwt.task () in
        Hashtbl.replace t.wakeners free_id u;

        (* If we fail to connect, return the error *)
        let open Lwt.Infix in
        begin
          let open Lwt_result.Infix in
          get_rw t
          >>= fun rw ->
          let open Lwt.Infix in
          (* An existing connection to the server might have been closed by the server;
             therefore if we fail to write the request, reconnect and try once more. *)
          Packet.write rw buffer
          >>= function
          | Result.Ok () ->
            Lwt_result.return ()
          | Result.Error (`Msg m) ->
            Log.info (fun f -> f "caught %s writing request, attempting to reconnect" m);
            disconnect t
            >>= fun () ->
            let open Lwt_result.Infix in
            get_rw t
            >>= fun rw ->
            Packet.write rw buffer
        end
        >>= function
        | Result.Error (`Msg m) ->
          Hashtbl.remove t.wakeners free_id;
          Dns_forward_free_id.put t.free_ids free_id;
          Lwt_result.fail (`Msg m)
        | Result.Ok () ->
          let open Lwt_result.Infix in
          th (* will be woken up by the dispatcher *)
          >>= fun buf ->
          (* Rewrite the query id back to the original *)
          Cstruct.BE.set_uint16 buf 0 client_id;
          Lwt_result.return buf
  end
end

module Server = struct

  module type S = Dns_forward_s.RPC_SERVER

  module Make
    (Sockets: Dns_forward_s.FLOW_SERVER with type address = Ipaddr.t * int)
    (Packet: Dns_forward_s.READERWRITER with type flow = Sockets.flow)
    (Time: V1_LWT.TIME) = struct
    type address = Dns_forward_config.address
    type request = Cstruct.t
    type response = Cstruct.t

    type server = {
      address: address;
      server: Sockets.server;
    }

    let bind address =
      let open Lwt_result.Infix in
      Sockets.bind (address.Dns_forward_config.ip, address.Dns_forward_config.port)
      >>= fun server ->
      Lwt_result.return { address; server }

    let listen { server; _ } cb =
      Sockets.listen server (fun flow ->
        let open Lwt.Infix in
        let rw = Packet.connect flow in
        let rec loop () =
          let open Lwt_result.Infix in
          Packet.read rw
          >>= fun request ->
          (* FIXME: need to run these in the background *)
          (* FIXME: need to rewrite transaction IDs if the requests come from
             different resolvers *)
          let open Lwt.Infix in
          cb request
          >>= function
          | Result.Error _ ->
            loop ()
          | Result.Ok response ->
            let open Lwt_result.Infix in
            Packet.write rw response
            >>= fun () ->
            loop () in
        loop ()
        >>= function
        | Result.Error (`Msg m) ->
          Log.err (fun f -> f "server loop failed with: %s" m);
          Lwt.return_unit
        | Result.Ok () ->
          Lwt.return_unit
      );
      Lwt_result.return ()

    let shutdown server =
      Sockets.shutdown server.server

  end
end
