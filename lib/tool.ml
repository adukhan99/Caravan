(** Tool interface and execution. *)

module type TOOL = sig
  val name : string
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
let description_of_packed (Tool (module T)) = T.description
let schema_of_packed (Tool (module T)) = T.json_schema ()

let dispatch (Tool (module T)) (args_json : string) : string =
  match Yojson.Safe.from_string args_json with
  | exception _ ->
    Printf.sprintf
      "Error: could not parse tool arguments as JSON. \
       Received: %s. Please provide valid JSON matching the schema." args_json
  | json ->
    match T.parse_args json with
    | Error err -> Printf.sprintf "Error parsing arguments: %s" err
    | Ok input ->
        let output =
          Effect.Deep.try_with
            (fun () -> Effect.perform (T.Exec input))
            ()
            { effc = fun (type a) (eff : a Effect.t) ->
                match eff with
                | T.Exec i -> Some (fun (k : (a, _) Effect.Deep.continuation) ->
                    Effect.Deep.continue k (T.execute i))
                | _ -> None
            }
        in
        T.format_output output
