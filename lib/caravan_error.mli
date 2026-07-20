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

val to_string : t -> string
val of_exn : exn -> t
val safe_run : (unit -> 'a) -> ('a, t) result
