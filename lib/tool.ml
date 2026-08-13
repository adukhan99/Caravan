(** Tool interface and execution. *)

module type TOOL = sig
  val name : string
  val aliases : string list
  val description : string

  type input
  type output

  val json_schema : unit -> Yojson.Safe.t
  val parse_args : Yojson.Safe.t -> (input, string) result
  val format_output : output -> string

  val is_mutating : bool
  val describe_action : input -> string

  type _ Effect.t += Exec : input -> output Effect.t
  val execute : input -> output
end

type packed_tool =
  | Tool : (module TOOL with type input = 'i and type output = 'o) -> packed_tool

let name_of_packed (Tool (module T)) = T.name
let aliases_of_packed (Tool (module T)) = T.aliases
let description_of_packed (Tool (module T)) = T.description
let schema_of_packed (Tool (module T)) = T.json_schema ()
let is_mutating_packed (Tool (module T)) = T.is_mutating

let describe_action_packed (Tool (module T)) (args_json : string) : string =
  match Parser.permissive_json args_json with
  | Ok json ->
    (match T.parse_args json with
     | Ok input -> T.describe_action input
     | Error _ -> Printf.sprintf "Use tool '%s'" T.name)
  | Error _ -> Printf.sprintf "Use tool '%s'" T.name


let matches_name (Tool (module T)) (requested_name : string) : bool =
  T.name = requested_name || List.mem requested_name T.aliases

let find_tool (tools : packed_tool list) (name : string) : packed_tool option =
  match List.find_opt (fun t -> name_of_packed t = name) tools with
  | Some _ as exact -> exact
  | None -> List.find_opt (fun t -> List.mem name (aliases_of_packed t)) tools

type dispatch_error =
  | Invalid_json of { raw : string; schema : Yojson.Safe.t }
  | Schema_mismatch of { tool_name : string; details : string; schema : Yojson.Safe.t }
  | Permission_denied of { tool_name : string }
  | Execution_error of string

let format_dispatch_error = function
  | Invalid_json { raw; schema } ->
    Printf.sprintf
      "Error: could not parse tool arguments as JSON.\n\
       Received: %s.\n\
       Expected JSON matching schema: %s"
      raw (Yojson.Safe.to_string schema)
  | Schema_mismatch { tool_name; details; schema } ->
    Printf.sprintf
      "SCHEMA_MISMATCH for tool '%s': %s\n\
       Expected JSON schema: %s\n\
       Please retry with valid parameters matching this schema."
      tool_name details (Yojson.Safe.to_string schema)
  | Permission_denied { tool_name } ->
    Printf.sprintf "Error: Permission denied for tool '%s'." tool_name
  | Execution_error msg ->
    Printf.sprintf "Error executing tool: %s" msg

let execute_packed_typed (Tool (module T)) (args_json : string) : (string, dispatch_error) result =
  match Parser.permissive_json args_json with
  | Error _ ->
    Error (Invalid_json { raw = args_json; schema = T.json_schema () })
  | Ok json ->
    match T.parse_args json with
    | Error err ->
      Error (Schema_mismatch { tool_name = T.name; details = err; schema = T.json_schema () })
    | Ok input ->
      try
        let output =
          try Effect.perform (T.Exec input)
          with Effect.Unhandled _ -> T.execute input
        in
        Ok (T.format_output output)
      with exn ->
        Error (Execution_error (Printexc.to_string exn))

let execute_packed (Tool (module T) as tool) (args_json : string) : string =
  match execute_packed_typed tool args_json with
  | Ok output -> output
  | Error err -> format_dispatch_error err

let dispatch_typed (Tool (module T) as tool) (args_json : string) : (string, dispatch_error) result =
  let allowed =
    try Effects.ask_permission T.name args_json
    with Effect.Unhandled _ ->
      Permission.check (Permission.default_policy ()) ~is_mutating:T.is_mutating ~desc:(describe_action_packed tool args_json)
  in
  if not allowed then begin
    Trace.emit (Trace.Permission_denied { name = T.name });
    Error (Permission_denied { tool_name = T.name })
  end
  else
    try Ok (Effects.exec_tool T.name args_json)
    with Effect.Unhandled _ -> execute_packed_typed tool args_json

let dispatch tool args_json =
  match dispatch_typed tool args_json with
  | Ok res -> res
  | Error err -> format_dispatch_error err

