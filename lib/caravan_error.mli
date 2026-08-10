(** Unified error handling types and formatting utilities for Caravan. *)

(** Structural error categories across tool dispatch, providers, MCP, subagents, and permissions. *)
type t =
  | Tool_error of string
  | Tool_not_found of string
  | Json_parse_error of string
  | Provider_error of string
  | Mcp_error of string
  | Subagent_error of string
  | Eio_error of string
  | Permission_denied of string
  | Exception of string

(** Convert an error to a descriptive text string. *)
val to_string : t -> string

(** Convert an arbitrary exception into a clean, human-readable message. *)
val humanize : exn -> string

(** Convert an exception into a structured {!type:t}. *)
val of_exn : exn -> t

(** Run a computation safely, wrapping thrown exceptions in {!type:t}. *)
val safe_run : (unit -> 'a) -> ('a, t) result

