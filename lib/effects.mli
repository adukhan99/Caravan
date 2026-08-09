type _ Effect.t +=
  | Exec_tool : { tool_name : string; args : string } -> string Effect.t
  | Ask_permission : { tool_name : string; args : string } -> bool Effect.t
  | Log_event : { level : string; message : string } -> unit Effect.t
  | Spawn_subagent : { role : string; task : string } -> (string, string) result Effect.t
  | Parse_warning : { field : string; message : string } -> unit Effect.t
  | Get_net : Eio_unix.Net.t Effect.t

val get_net : unit -> Eio_unix.Net.t

(** Run [f] with [Get_net] answered by [net]. Install this once at the
    front-end entry point (inside [Eio_main.run]) so network tools reuse
    the ambient event loop. *)
val with_net : Eio_unix.Net.t -> (unit -> 'a) -> 'a

val exec_tool : string -> string -> string
val ask_permission : string -> string -> bool
val log_event : string -> string -> unit
val spawn_subagent : string -> string -> (string, string) result
val parse_warning : string -> string -> unit

(** Install handlers for the effects that were actually supplied; all
    other effects are forwarded. Notably, omitting [on_exec] leaves
    [Exec_tool] unhandled so tools fall back to direct execution. *)
val run_with_effects :
  ?permission_policy:(string -> string -> bool) ->
  ?on_log:(string -> string -> unit) ->
  ?on_exec:(string -> string -> string) ->
  ?on_spawn:(string -> string -> (string, string) result) ->
  ?on_parse_warning:(string -> string -> unit) ->
  (unit -> 'a) -> 'a
