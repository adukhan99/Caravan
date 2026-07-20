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

  type _ Effect.t += Exec : input -> output Effect.t
  val execute : input -> output
end

type packed_tool =
  | Tool : (module TOOL with type input = 'i and type output = 'o) -> packed_tool

let name_of_packed (Tool (module T)) = T.name
let aliases_of_packed (Tool (module T)) = T.aliases
let description_of_packed (Tool (module T)) = T.description
let schema_of_packed (Tool (module T)) = T.json_schema ()

let matches_name (Tool (module T)) (requested_name : string) : bool =
  T.name = requested_name || List.mem requested_name T.aliases

let find_tool (tools : packed_tool list) (name : string) : packed_tool option =
  match List.find_opt (fun t -> name_of_packed t = name) tools with
  | Some _ as exact -> exact
  | None -> List.find_opt (fun t -> List.mem name (aliases_of_packed t)) tools

let execute_packed (Tool (module T)) (args_json : string) : string =
  let cleaned_args = Parser.extract_code args_json |> Result.value ~default:args_json in
  match Yojson.Safe.from_string (String.trim cleaned_args) with
  | exception _ ->
    Printf.sprintf
      "Error: could not parse tool arguments as JSON.\n\
       Received: %s.\n\
       Expected JSON matching schema: %s"
      args_json (Yojson.Safe.to_string (T.json_schema ()))
  | json ->
    match T.parse_args json with
    | Error err ->
      Printf.sprintf
        "SCHEMA_MISMATCH for tool '%s': %s\n\
         Expected JSON schema: %s\n\
         Please retry with valid parameters matching this schema."
        T.name err (Yojson.Safe.to_string (T.json_schema ()))
    | Ok input ->
      let output =
        try Effect.perform (T.Exec input)
        with Effect.Unhandled _ -> T.execute input
      in
      T.format_output output

let dispatch (Tool (module T) as tool) (args_json : string) : string =
  let allowed =
    try Effects.ask_permission T.name args_json
    with Effect.Unhandled _ -> true
  in
  if not allowed then
    Printf.sprintf "Error: Permission denied for tool '%s'." T.name
  else
    try Effects.exec_tool T.name args_json
    with Effect.Unhandled _ -> execute_packed tool args_json
