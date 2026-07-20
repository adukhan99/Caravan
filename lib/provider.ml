(** Abstract LLM backend interface. *)

open Types

module type PROVIDER = sig
  type config

  val name : string

  val complete
    :  _ Eio.Net.t
    -> config
    -> ?model:string
    -> ?options:gen_options
    -> ?tools:Tool.packed_tool list
    -> chat_message list
    -> chat_message result_with_meta

  val stream
    :  _ Eio.Net.t
    -> config
    -> ?model:string
    -> ?options:gen_options
    -> ?tools:Tool.packed_tool list
    -> chat_message list
    -> on_token:(string -> unit)
    -> chat_message result_with_meta

  val list_models : _ Eio.Net.t -> config -> string list
end

type packed_provider =
  | Provider : (module PROVIDER with type config = 'c) * 'c -> packed_provider

let complete_packed net ?model ?options ?tools (Provider ((module P), cfg)) msgs =
  P.complete net cfg ?model ?options ?tools msgs

let stream_packed net ?model ?options ?tools ~on_token (Provider ((module P), cfg)) msgs =
  P.stream net cfg ?model ?options ?tools msgs ~on_token

let list_models_packed net (Provider ((module P), cfg)) =
  P.list_models net cfg

let name_of_packed (Provider ((module P), _)) = P.name
