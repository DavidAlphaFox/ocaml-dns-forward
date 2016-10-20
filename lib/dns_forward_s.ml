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

module type FLOW_CLIENT = sig
  include Mirage_flow_s.SHUTDOWNABLE
  type address
  val connect: ?read_buffer_size:int -> address
    -> (flow, [ `Msg of string ]) Lwt_result.t
end

module type FLOW_SERVER = sig
  type server
  type address
  val bind: address -> (server, [ `Msg of string ]) Lwt_result.t
  val getsockname: server -> address
  type flow
  val listen: server -> (flow -> unit Lwt.t) -> unit
  val shutdown: server -> unit Lwt.t
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
  val connect: address -> (t, [ `Msg of string ]) Lwt_result.t
  val rpc: t -> request -> (response, [ `Msg of string ]) Lwt_result.t
  val disconnect: t -> unit Lwt.t
end

module type RPC_SERVER = sig
  type request = Cstruct.t
  type response = Cstruct.t
  type address = Dns_forward_config.address

  type server
  val bind: address -> (server, [ `Msg of string ]) Lwt_result.t
  val listen: server -> (request -> (response, [ `Msg of string ]) Lwt_result.t) -> (unit, [ `Msg of string ]) Lwt_result.t
  val shutdown: server -> unit Lwt.t
end

module type RESOLVER = sig
  type t
  val create:
    ?local_names_cb:(Dns.Packet.question -> Dns.Packet.rr list option Lwt.t) ->
    ?timeout:float ->
    Dns_forward_config.t ->
    t Lwt.t
  val destroy: t -> unit Lwt.t
  val answer: Cstruct.t -> t -> (Cstruct.t, [ `Msg of string ]) Lwt_result.t
end

module type SERVER = sig
  type t
  val create:
    ?local_names_cb:(Dns.Packet.question -> Dns.Packet.rr list option Lwt.t) ->
    ?timeout:float ->
    Dns_forward_config.t -> t Lwt.t
  val serve:
    address:Dns_forward_config.address ->
    t -> (unit, [ `Msg of string ]) Lwt_result.t
  val destroy: t -> unit Lwt.t
end

module type READERWRITER = sig
  (** Read and write DNS packets from a flow *)
  type request = Cstruct.t
  type response = Cstruct.t
  type t
  type flow
  val connect: flow -> t
  val read: t -> (request, [ `Msg of string ]) Lwt_result.t
  val write: t -> response -> (unit, [ `Msg of string]) Lwt_result.t
  val close: t -> unit Lwt.t
end
