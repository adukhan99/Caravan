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

(** Structural representation of details extracted from a provider error payload. *)
type provider_error_detail = {
  provider_name : string option;
  code          : string option;
  message       : string;
  raw           : string option;
  param         : string option;
  user_id       : string option;
}

(** Exception raised when an LLM provider endpoint returns an error HTTP status. *)
exception Provider_failure of {
  provider : string;
  status   : int;
  body     : string;
  detail   : provider_error_detail option;
}

(** Raise a {!exception:Provider_failure} exception after parsing the body payload. *)
val raise_provider_failure : provider:string -> status:int -> body:string -> 'a

(** Attempt to parse a provider error JSON payload into a {!type:provider_error_detail}. *)
val parse_provider_error : string -> provider_error_detail option

(** Convert an error to a descriptive text string. *)
val to_string : t -> string

(** Convert an arbitrary exception into a clean, human-readable message. *)
val humanize : exn -> string

(** Convert an exception into a structured {!type:t}. *)
val of_exn : exn -> t

(** Run a computation safely, wrapping thrown exceptions in {!type:t}. *)
val safe_run : (unit -> 'a) -> ('a, t) result


