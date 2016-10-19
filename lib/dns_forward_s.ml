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

module type FLOW_CLIENT = sig
  include Mirage_flow_s.SHUTDOWNABLE

  type address

  val connect: ?read_buffer_size:int -> address
    -> [ `Ok of flow | `Error of [ `Msg of string ] ] Lwt.t
  (** [connect address] creates a connection to [address] and returns
      he connected flow. *)
end

module type FLOW_SERVER = sig
  type server
  (* A server bound to some address *)

  type address

  val bind: address -> [ `Ok of server | `Error of [ `Msg of string ]] Lwt.t
  (** Bind a server to an address *)

  val getsockname: server -> address
  (** Query the address the server is bound to *)

  type flow

  val listen: server -> (flow -> unit Lwt.t) -> unit
  (** Accept connections forever, calling the callback with each one.
      Connections are closed automatically when the callback finishes. *)

  val shutdown: server -> unit Lwt.t
  (** Stop accepting connections on the given server *)
end

module type SOCKETS = sig
  type address = Ipaddr.t * int

  type flow

  include FLOW_CLIENT
    with type address := address
     and type flow := flow
  include FLOW_SERVER
    with type address := address
     and type flow := flow
end

module type RPC_CLIENT = sig
  type request = Cstruct.t
  type response = Cstruct.t
  type address = Dns_forward_config.address
  type t
  val connect: address -> [ `Ok of t | `Error of [ `Msg of string ] ] Lwt.t
  val rpc: t -> request -> [ `Ok of response | `Error of [ `Msg of string ] ] Lwt.t
  val disconnect: t -> unit Lwt.t
end

module type RPC_SERVER = sig
  type request = Cstruct.t
  type response = Cstruct.t
  type address = Dns_forward_config.address

  type server
  val bind: address -> [ `Ok of server | `Error of [ `Msg of string ] ] Lwt.t
  val listen: server -> (request -> [ `Ok of response | `Error of [ `Msg of string ] ] Lwt.t) -> [`Ok of unit | `Error of [ `Msg of string ]] Lwt.t
  val shutdown: server -> unit Lwt.t
end

module type RESOLVER = sig
  type t
  val create: Dns_forward_config.t -> t Lwt.t
  val destroy: t -> unit Lwt.t
  val answer:
    ?local_names_cb:(Dns.Packet.question -> Dns.Packet.rr list option Lwt.t) ->
    ?timeout:float ->
    Cstruct.t ->
    t -> [ `Ok of Cstruct.t | `Error of [ `Msg of string ] ] Lwt.t
end

module type SERVER = sig
  type t
  val create: Dns_forward_config.t -> t Lwt.t
  val serve:
    address:Dns_forward_config.address ->
    ?local_names_cb:(Dns.Packet.question -> Dns.Packet.rr list option Lwt.t) ->
    ?timeout:float ->
    t -> [ `Ok of unit | `Error of [ `Msg of string ] ] Lwt.t
  val destroy: t -> unit Lwt.t
end

module type READERWRITER = sig
  (** Read and write DNS packets from a flow *)
  type request = Cstruct.t
  type response = Cstruct.t
  type t
  type flow
  val connect: flow -> t
  val read: t -> [ `Ok of request | `Error of [ `Msg of string ] ] Lwt.t
  val write: t -> response -> [ `Ok of unit | `Error of [ `Msg of string ] ] Lwt.t
  val close: t -> unit Lwt.t
end
