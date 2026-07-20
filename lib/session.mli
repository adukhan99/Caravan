open Types

type config = {
  model       : string;
  system      : string option;
  options     : gen_options;
  memory_size : int;
}

val default_config : string -> config

type t

val create : ?config:(string -> config) -> ?tools:Tool.packed_tool list -> string -> Provider.packed_provider -> t

val set_system : t -> string -> t
val set_memory_size : t -> int -> t
val set_options : t -> (gen_options -> gen_options) -> t
val clear : t -> t
val add_messages : t -> chat_message list -> t
val with_provider : t -> Provider.packed_provider -> t
val tools : t -> Tool.packed_tool list
val config : t -> config
val provider : t -> Provider.packed_provider
val with_model : t -> string -> t

val history : t -> chat_message list
val history_for_llm : t -> chat_message list

val run_conversations : _ Eio.Net.t -> _ Eio.Time.clock -> t -> t * chat_message result_with_meta
val run_conversations_stream : _ Eio.Net.t -> _ Eio.Time.clock -> t -> on_token:(string -> unit) -> t * chat_message result_with_meta

val turn : _ Eio.Net.t -> _ Eio.Time.clock -> t -> string -> t * chat_message result_with_meta
val turn_stream : _ Eio.Net.t -> _ Eio.Time.clock -> t -> string -> on_token:(string -> unit) -> t * chat_message result_with_meta

val summarise : _ Eio.Net.t -> _ Eio.Time.clock -> t -> t * string

val export_json : t -> Yojson.Safe.t
val pp_history : Format.formatter -> t -> unit
