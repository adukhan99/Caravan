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

let contains haystack needle =
  try let _ = Re.exec (Re.compile (Re.str needle)) haystack in true
  with Not_found -> false

let humanize exn =
  let raw = Printexc.to_string exn in
  if contains raw "ECONNREFUSED" || contains raw "Connection refused" then
    "Could not connect to the AI provider.\n" ^
    "  Hint: Is Ollama running? Try: ollama serve\n" ^
    "  Hint: Using OpenAI? Check your API key and internet connection."
  else if contains raw "404"
       || (contains raw "model" && (contains raw "not found" || contains raw "does not exist")) then
    "Model not found on this provider.\n" ^
    "  Hint: Run /models to see what's available, or /model <name> to switch."
  else if contains raw "401" || contains raw "Unauthorized" then
    "Authentication failed. Your API key may be missing or invalid.\n" ^
    "  Hint: Set it with: export OPENAI_API_KEY=\"sk-...\"\n" ^
    "  Hint: Or add it to ~/.caravan/config.toml"
  else if contains raw "429" || contains raw "rate" then
    "Rate limited by the provider. Wait a moment and try again."
  else
    Printf.sprintf "Something went wrong: %s\n  Hint: Try /config to check your settings." raw

let of_exn exn =
  Exception (Printexc.to_string exn)

let safe_run f =
  try Ok (f ())
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (of_exn exn)
