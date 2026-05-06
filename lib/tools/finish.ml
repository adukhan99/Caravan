(** Terminal tool for agents to signal completion. *)

open OrchCaml.Tool
open Yojson.Safe.Util

module Finish : TOOL = struct
  let name = "finish"
  let description = "Call this tool when you have completed the task or reached a final conclusion. Provide a summary of your work."

  type input = {
    summary : string;
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
      ("required", `List [`String "summary"]);
    ]

  let parse_args json =
    try
      Ok { summary = json |> member "summary" |> to_string }
    with Type_error (msg, _) -> Error msg

  let format_output summary =
    Printf.sprintf "Task finished: %s" summary

  type _ Effect.t += Exec : input -> output Effect.t
  let execute input = input.summary
end
