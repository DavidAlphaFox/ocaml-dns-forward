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

let src =
  let src = Logs.Src.create "Dns_forward" ~doc:"DNS over TCP" in
  Logs.Src.set_level src (Some Logs.Debug);
  src

module Log = (val Logs.src_log src : Logs.LOG)

module ReaderWriter(Flow: V1_LWT.FLOW) = struct
  module Error = Dns_forward_error.Infix
  let errorf = Dns_forward_error.errorf

  module C = Channel.Make(Flow)

  type request = Cstruct.t
  type response = Cstruct.t
  type t = {
    c: C.t;
    write_m: Lwt_mutex.t;
    read_m: Lwt_mutex.t;
  }

  let connect flow =
    let c = C.create flow in
    let write_m = Lwt_mutex.create () in
    let read_m = Lwt_mutex.create () in
    { c; write_m; read_m }

  let close t =
    Flow.close @@ C.to_flow t.c

  let read t =
    Lwt_mutex.with_lock t.read_m
      (fun () ->
        let open Error in
        Lwt.catch
          (fun () ->
            let open Lwt.Infix in
            C.read_exactly ~len:2 t.c
            >>= fun bufs ->
            Lwt.return (`Ok bufs)
          ) (fun e ->
            errorf "Failed to read response header: %s" (Printexc.to_string e)
          )
        >>= fun bufs ->
        let buf = Cstruct.concat bufs in
        let len = Cstruct.BE.get_uint16 buf 0 in
        Lwt.catch
          (fun () ->
            let open Lwt.Infix in
            C.read_exactly ~len t.c
            >>= fun bufs ->
            Lwt.return (`Ok bufs)
          ) (fun e ->
            errorf "Failed to read response payload (%d bytes): %s" len (Printexc.to_string e)
          )
        >>= fun bufs ->
        Lwt.return (`Ok (Cstruct.concat bufs))
      )

  let write t buffer =
    Lwt_mutex.with_lock t.write_m
      (fun () ->
        (* RFC 1035 4.2.2 TCP Usage: 2 byte length field *)
        let header = Cstruct.create 2 in
        Cstruct.BE.set_uint16 header 0 (Cstruct.len buffer);
        C.write_buffer t.c header;
        C.write_buffer t.c buffer;
        Lwt.catch
          (fun () ->
            let open Lwt.Infix in
            C.flush t.c
            >>= fun () ->
            Lwt.return (`Ok ())
          ) (fun e ->
            errorf "Failed to write %d bytes: %s" (Cstruct.len buffer) (Printexc.to_string e)
          )
      )
end

module Make(Tcp: Dns_forward_s.SOCKETS)(Time: V1_LWT.TIME) = struct
  type address = Dns_forward_config.address

  module RW = ReaderWriter(Tcp)

  type t = {
    address: address;
    mutable rw: RW.t option;
    mutable disconnect_on_idle: unit Lwt.t;
    wakeners: (int, [ `Ok of Cstruct.t | `Error of [ `Msg of string ] ] Lwt.u) Hashtbl.t;
    m: Lwt_mutex.t;
    free_ids: Dns_forward_free_id.t;
  }

  module Error = Dns_forward_error.Infix
  module FlowError = Dns_forward_error.FromFlowError(Tcp)

  let disconnect t =
    Lwt_mutex.with_lock t.m
      (fun () ->
        match t with
        | { rw = Some rw; _ } as t ->
          t.rw <- None;
          let tbl = Hashtbl.copy t.wakeners in
          Hashtbl.clear t.wakeners;
          let error = `Error (`Msg "connection to server was closed") in
          Hashtbl.iter (fun id u ->
            Log.err (fun f -> f "disconnect: failing request with id %d" id);
            Dns_forward_free_id.put t.free_ids id;
            Lwt.wakeup_later u error
          ) tbl;
          RW.close rw
        | _ -> Lwt.return_unit
      )

  (* Receive all the responses and demux to the right thread. When the connection
     is closed, `read_buffer` will fail and this thread will exit. *)
  let dispatcher t rw () =
    let open Lwt.Infix in
    let rec loop () =
      RW.read rw
      >>= function
      | `Error (`Msg m) ->
        Log.info (fun f -> f "%s: dispatcher shutting down" m);
        disconnect t
      | `Ok buffer ->
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
            Lwt.wakeup_later u (`Ok buffer)
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
    let open Error in
    Lwt.cancel t.disconnect_on_idle;
    Lwt_mutex.with_lock t.m
      (fun () -> match t.rw with
        | None ->
          Tcp.connect (t.address.Dns_forward_config.ip, t.address.Dns_forward_config.port)
          >>= fun flow ->
          let rw = RW.connect flow in
          t.rw <- Some rw;
          Lwt.async (dispatcher t rw);
          Lwt.return (`Ok rw)
        | Some rw ->
          Lwt.return (`Ok rw))
    >>= fun rw ->
    (* Add a fresh idle timer *)
    t.disconnect_on_idle <- (let open Lwt.Infix in Time.sleep 30. >>= fun () -> disconnect t);
    Lwt.return (`Ok rw)

  type request = Cstruct.t
  type response = Cstruct.t

  let connect address =
    let rw = None in
    let m = Lwt_mutex.create () in
    let disconnect_on_idle = Lwt.return_unit in
    let wakeners = Hashtbl.create 7 in
    let free_ids = Dns_forward_free_id.make () in
    Lwt.return (`Ok { address; rw; disconnect_on_idle; wakeners; m; free_ids })

  let rpc (t: t) buffer =
    let buf = Dns.Buf.of_cstruct buffer in
    match Dns.Protocol.Server.parse (Dns.Buf.sub buf 0 (Cstruct.len buffer)) with
    | None ->
      Log.err (fun f -> f "failed to parse request");
      Lwt.return (`Error (`Msg "failed to parse request"))
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
        let open Error in
        get_rw t
        >>= fun rw ->
        let open Lwt.Infix in
        (* An existing connection to the server might have been closed by the server;
           therefore if we fail to write the request, reconnect and try once more. *)
        RW.write rw buffer
        >>= function
        | `Ok () ->
          Lwt.return (`Ok ())
        | `Error (`Msg m) ->
          Log.info (fun f -> f "caught %s writing request, attempting to reconnect" m);
          disconnect t
          >>= fun () ->
          let open Error in
          get_rw t
          >>= fun rw ->
          RW.write rw buffer
      end
      >>= function
      | `Error (`Msg m) ->
        Hashtbl.remove t.wakeners free_id;
        Dns_forward_free_id.put t.free_ids free_id;
        Lwt.return (`Error (`Msg m))
      | `Ok () ->
        let open Error in
        th (* will be woken up by the dispatcher *)
        >>= fun buf ->
        (* Rewrite the query id back to the original *)
        Cstruct.BE.set_uint16 buf 0 client_id;
        Lwt.return (`Ok buf)
  type server = {
    address: address;
    server: Tcp.server;
  }

  let bind address =
    let open Error in
    Tcp.bind (address.Dns_forward_config.ip, address.Dns_forward_config.port)
    >>= fun server ->
    Lwt.return (`Ok { address; server })

  let listen { server; _ } cb =
    Tcp.listen server (fun flow ->
      let open Lwt.Infix in
      let rw = RW.connect flow in
      let rec loop () =
        let open Error in
        RW.read rw
        >>= fun request ->
        (* FIXME: need to run these in the background *)
        (* FIXME: need to rewrite transaction IDs if the requests come from
           different resolvers *)
        let open Lwt.Infix in
        cb request
        >>= function
        | `Error _ ->
          loop ()
        | `Ok response ->
          let open Error in
          RW.write rw response
          >>= fun () ->
          loop () in
      loop ()
      >>= function
      | `Error (`Msg m) ->
        Log.err (fun f -> f "server loop failed with: %s" m);
        Lwt.return_unit
      | `Ok () ->
        Lwt.return_unit
    );
    Lwt.return (`Ok ())

  let shutdown server =
    Tcp.shutdown server.server

end
