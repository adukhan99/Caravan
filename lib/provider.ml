(** OrchCaml.Provider — Abstract LLM backend interface.

    Every provider (Ollama, OpenAI, Anthropic, etc.) implements this
    signature. Pipelines are written against [PROVIDER], not a concrete
    module, so swapping backends is a one-liner.

    All functions are direct-style (no Lwt.t). Providers receive the
    Eio [net] capability and execute synchronously within the caller's
    fiber. *)

open Types

(** The core interface that every backend must satisfy. *)
module type PROVIDER = sig

  (** Provider-specific configuration (URLs, credentials, model name, etc.) *)
  type config

  (** Human-readable provider name, e.g. "ollama" or "openai". *)
  val name : string

  (** [complete net cfg ?tools history] sends [history] to the LLM and returns
      the full response when it is ready. Direct style — blocks the calling fiber. *)
  val complete
    :  _ Eio.Net.t
    -> config
    -> ?tools:Tool.packed_tool list
    -> chat_message list
    -> chat_message result_with_meta

  (** [stream net cfg ?tools history ~on_token] sends [history] and calls
      [on_token] for each arriving token chunk. Returns the full result when
      the stream is exhausted. *)
  val stream
    :  _ Eio.Net.t
    -> config
    -> ?tools:Tool.packed_tool list
    -> chat_message list
    -> on_token:(string -> unit)
    -> chat_message result_with_meta

  (** [list_models net cfg] returns the models available from this provider. *)
  val list_models : _ Eio.Net.t -> config -> string list

end

(** A packed (existential) provider — lets you store providers of different
    types in the same data structure. *)
type packed_provider =
  | Provider : (module PROVIDER with type config = 'c) * 'c -> packed_provider

let complete_packed net ?tools (Provider ((module P), cfg)) msgs =
  P.complete net cfg ?tools msgs

let stream_packed net ?tools ~on_token (Provider ((module P), cfg)) msgs =
  P.stream net cfg ?tools msgs ~on_token

let list_models_packed net (Provider ((module P), cfg)) =
  P.list_models net cfg

let name_of_packed (Provider ((module P), _)) = P.name
