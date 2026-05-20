open Types

type t

val create      : host:string -> port:int -> session_id:string -> unit -> t
val add         : t -> chat_message -> t
val get         : t -> chat_message list
val clear       : t -> t
val length      : t -> int
val set_window  : t -> int -> t
val to_json     : t -> Yojson.Safe.t
val of_json     : Yojson.Safe.t -> t
