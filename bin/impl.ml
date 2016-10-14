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

open Lwt.Infix

let read_lines filename =
  Lwt.catch
    (fun () ->
      Lwt_io.open_file filename ~mode:Lwt_io.input
      >>= fun ic ->
      Lwt.finalize
        (fun () ->
          let s = Lwt_io.read_lines ic in
          Lwt_stream.to_list s
        ) (fun () ->
          Lwt_io.close ic
        )
    ) (function
      | Unix.Unix_error(Unix.ENOENT, _, _) as e ->
        Logs.err (fun f -> f "failed to find file %s" filename);
        Lwt.fail e
      )

module Time = struct
  type 'a io = 'a Lwt.t
  let sleep = Lwt_unix.sleep
end

module Udp = Dns_forward_udp.Make(Dns_forward_lwt_unix.Udp)
module Udp_forwarder = Dns_forward.Make(Udp)(Udp)(Time)

module Tcp = Dns_forward_tcp.Make(Dns_forward_lwt_unix.Tcp)(Time)
module Tcp_forwarder = Dns_forward.Make(Tcp)(Tcp)(Time)

let max_udp_length = 65507

let serve port filename =
  if filename = "" then begin
    `Error (true, "please supply the name of a config file")
  end else Lwt_main.run begin
    read_lines filename
    >>= fun lines ->
    let all = String.concat "" lines in
    let config = Dns_forward_config.t_of_sexp @@ Sexplib.Sexp.of_string all in
    Udp_forwarder.make config
    >>= fun udp ->
    Tcp_forwarder.make config
    >>= fun tcp ->
    let address = { Dns_forward_config.ip = Ipaddr.V4 Ipaddr.V4.localhost; port } in
    let t =
      let open Dns_forward_error.Infix in
      Udp_forwarder.serve udp address
      >>= fun () ->
      Tcp_forwarder.serve tcp address
      >>= fun () ->
      let t, _ = Lwt.task () in
      t in
    t >>= function
    | `Error (`Msg m) -> Lwt.return (`Error(true, m))
    | `Ok () -> Lwt.return (`Ok ())
  end
