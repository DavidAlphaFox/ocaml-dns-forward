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
open Dns_forward
module Error = Error.Infix

module Make(Server: Rpc.Server.S) = struct
  type t = {
    names: (string * Ipaddr.t) list;
    mutable nr_queries: int;
  }
  let make names = { names; nr_queries = 0 }

  let get_nr_queries { nr_queries; _ } = nr_queries

  let answer buffer t =
    t.nr_queries <- t.nr_queries + 1;
    let len = Cstruct.len buffer in
    let buf = Dns.Buf.of_cstruct buffer in
    match Dns.Protocol.Server.parse (Dns.Buf.sub buf 0 len) with
    | Some request ->
      let open Dns.Packet in
      begin match request with
        | { id; detail; additionals; questions = [ { q_class = Q_IN; q_type = Q_A; q_name; _ } ]; _ } ->
          begin match List.fold_left (fun found (name, ip) -> match found, ip with
            | Some v4, _           -> Some v4
            | None,   Ipaddr.V4 v4 ->
              if Dns.Name.to_string q_name = name then Some v4 else None
            | None,   Ipaddr.V6 _  -> None
          ) None t.names with
          | None ->
            Lwt.return (Result.Error (`Msg "no mapping for name"))
          | Some v4 ->
            let answers = [ { name = q_name; cls = RR_IN; flush = false; ttl = 0l; rdata = A v4 } ] in
            let pkt = { Dns.Packet.id; detail; questions = request.questions; authorities=[]; additionals; answers } in
            let buf = Dns.Buf.create 1024 in
            let buf = marshal buf pkt in
            Lwt.return (Result.Ok (Cstruct.of_bigarray buf))
          end
        | _ ->
          Lwt.return (Result.Error (`Msg "unexpected query type"))
      end
    | None ->
      Lwt.return (Result.Error (`Msg "failed to parse request"))

  let serve ~address t =
    let open Error in
    Server.bind address
    >>= fun server ->
    Server.listen server (fun buf -> answer buf t)
    >>= fun () ->
    Lwt.return (Result.Ok ())

end
