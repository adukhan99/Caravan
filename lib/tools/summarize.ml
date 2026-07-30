(** Summarize tool — allows the agent to explicitly request context summarization. *)

open Caravan.Tool
open Yojson.Safe.Util

module Summarize = struct
  let name    = "summarize"
  let aliases = ["compress_history"; "summarise"]

  let description =
    "Summarize and compress past conversation history into a concise summary \
     to preserve context space and retain key details."

  type input  = { reason : string option }
  type output = string

  let json_schema () =
    `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional reason or focus for the summarization.");
        ]);
      ]);
    ]

  let parse_args json =
    try
      let reason =
        match json |> member "reason" with
        | `String s -> Some s
        | _ -> None
      in
      Ok { reason }
    with Type_error (msg, _) -> Error ("summarize parse: " ^ msg)

  let format_output s = s

  type _ Effect.t += Exec : input -> output Effect.t

  let execute inp =
    match inp.reason with
    | Some r -> Printf.sprintf "Conversation history summarized successfully. Focus: %s" r
    | None   -> "Conversation history summarized successfully."
end
