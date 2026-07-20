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

let to_string = function
  | Tool_error msg -> "Tool Error: " ^ msg
  | Tool_not_found msg -> "Tool Not Found: " ^ msg
  | Json_parse_error msg -> "JSON Parse Error: " ^ msg
  | Provider_error msg -> "Provider Error: " ^ msg
  | Mcp_error msg -> "MCP Error: " ^ msg
  | Subagent_error msg -> "Subagent Error: " ^ msg
  | Eio_error msg -> "Eio Error: " ^ msg
  | Permission_denied msg -> "Permission Denied: " ^ msg
  | Exception msg -> "Exception: " ^ msg

let of_exn exn =
  Exception (Printexc.to_string exn)

let safe_run f =
  try Ok (f ())
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (of_exn exn)
