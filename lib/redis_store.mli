(** Redis-backed session store for persistent multi-turn conversation history. *)

open Types

(** Redis store instance handle. *)
type t

(** Create a new Redis-backed session store. *)
val create      : host:string -> port:int -> session_id:string -> unit -> t

(** Append a chat message to the Redis session store. *)
val add         : t -> chat_message -> t

(** Retrieve the full list of chat messages for the session. *)
val get         : t -> chat_message list

(** Clear all chat messages from the Redis session store. *)
val clear       : t -> t

(** Get the total number of chat messages stored for the session. *)
val length      : t -> int

(** Set maximum sliding window size for message history retention. *)
val set_window  : t -> int -> t

(** Serialize store configuration and state metadata to JSON. *)
val to_json     : t -> Yojson.Safe.t

(** Deserialize store configuration and state metadata from JSON. *)
val of_json     : Yojson.Safe.t -> t

