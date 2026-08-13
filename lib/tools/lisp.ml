(** The lisp tool — a sandboxed, exact symbolic calculator for models.

    Backed by [Caravan.Lisp] (step-capped, no IO). Lets any model — 2B or
    frontier — do exact counting, arithmetic, filtering, and data
    reshaping instead of approximating it in prose. *)

open Caravan.Tool
open Yojson.Safe.Util

module Lisp = struct
  let name    = "lisp"
  let aliases = ["eval"; "calc"; "lisp_eval"; "compute"]

  let description =
    "Exact symbolic calculator (a tiny sandboxed LISP). Use it for \
     arithmetic, counting, sorting, filtering and reshaping JSON data — \
     never do math in your head when this tool is available. \
     Pass the program in `program`; optionally pass JSON in `data` \
     (bound to the symbol `data`). Programs always terminate; errors \
     come back as text. Examples: \
     (+ 1 2) → 3 · \
     (len (filter (lambda (r) (> (get \"age\" r) 30)) data)) · \
     (sort-by \"score\" data) · \
     (mean (map (lambda (r) (get \"t\" r)) data)).\n" ^
    Caravan.Lisp.cheat_sheet

  type input  = { program : string; data : Yojson.Safe.t option }
  type output = (string, string) result

  let json_schema () =
    `Assoc [
      ("type", `String "object");
      ("required", `List [`String "program"]);
      ("properties", `Assoc [
        ("program", `Assoc [
          ("type", `String "string");
          ("description", `String "The LISP program to evaluate.");
        ]);
        ("data", `Assoc [
          ("description", `String
             "Optional JSON value bound to the symbol `data` inside the program.");
        ]);
      ]);
    ]

  let parse_args json =
    try
      let program = json |> member "program" |> to_string in
      let data = match json |> member "data" with
        | `Null -> None
        | d -> Some d
      in
      Ok { program; data }
    with Type_error (msg, _) -> Error ("lisp parse: " ^ msg)

  let format_output = function
    | Ok s -> s
    | Error e -> "Error: " ^ e

  let is_mutating = false
  let describe_action input = Printf.sprintf "Execute Lisp: %s" input.program

  type _ Effect.t += Exec : input -> output Effect.t

  let execute { program; data } =
    let data = Option.map Caravan.Value.of_yojson data in
    Caravan.Lisp.run_to_string ?data program
end
