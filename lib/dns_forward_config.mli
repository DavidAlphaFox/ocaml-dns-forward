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

module Address: sig
  type t = {
    ip: Ipaddr.t;
    port: int;
  }

  val compare: t -> t -> int
  module Set: Set.S with type elt = t
  module Map: Map.S with type key = t
end

module Domain: sig
  type t = string list

  val compare: t -> t -> int

  module Set: Set.S with type elt = t
  module Map: Map.S with type key = t
end

module Server: sig
  type t = {
    zones: Domain.Set.t; (** use this server for these specific domains *)
    address: Address.t;
  }
  (** A single upstream DNS server *)

  val compare: t -> t -> int
  module Set: Set.S with type elt = t
  module Map: Map.S with type key = t
end

type t = {
  servers: Server.Set.t;
  search: string list;
} [@@deriving sexp]

val of_string: string -> (t, [ `Msg of string ]) Result.result
val to_string: t -> string

val compare: t -> t -> int

module Unix: sig
  val of_resolv_conf: string -> (t, [ `Msg of string ]) Result.result
end
