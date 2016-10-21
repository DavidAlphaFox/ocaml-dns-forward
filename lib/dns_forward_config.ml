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
open Sexplib.Std

module Address = struct
  type t = {
    ip: Ipaddr.t;
    port: int;
  } [@@deriving sexp]

  let compare a b =
    let ip = Ipaddr.compare a.ip b.ip in
    if ip <> 0 then ip else Pervasives.compare a.port b.port
end

module Domain = struct
  type t = string list [@@deriving sexp]

  let compare (a: t) (b: t) = Pervasives.compare a b
end

type server = {
  zones: Domain.t list;
  address: Address.t;
} [@@deriving sexp]

type t = server list [@@deriving sexp]
