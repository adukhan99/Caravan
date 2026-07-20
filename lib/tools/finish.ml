(** Terminal tool for agents to signal completion. *)

open Caravan.Tool
open Yojson.Safe.Util

module Finish : TOOL = struct
  let name = "finish"
  let aliases = ["done"; "complete"; "stop"; "end"]
  let description = "Call this tool when you have completed the task or reached a final conclusion. Provide a summary of your work."

  type input = {
    summary : string option;
  }
  type output = string

  let json_schema () =
    `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("summary", `Assoc [
          ("type", `String "string");
          ("description", `String "A final summary of the task completion.");
        ]);
      ]);
    ]

  let parse_args json =
    let summary = 
      match json |> member "summary" with
      | `Null -> None
      | `String s -> Some s
      | _ -> None
    in
    Ok { summary }

  let format_output summary =
    Printf.sprintf "Task finished: %s" summary

  type _ Effect.t += Exec : input -> output Effect.t
  let execute input = 
    match input.summary with
    | Some s -> s
    | None -> "Completed"
end
