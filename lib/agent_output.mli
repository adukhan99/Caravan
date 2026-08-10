(** Formatter for agent results. *)

type mode = Plain | Json

(** Format a successful agent run result. *)
val format_success :
  mode:mode ->
  result:Types.chat_message Types.result_with_meta ->
  transcript:string option ->
  string

(** Format an agent run error. *)
val format_error :
  mode:mode ->
  message:string ->
  transcript:string option ->
  string
