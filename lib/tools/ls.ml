open Caravan.Tool

module Ls : TOOL with type input = string and type output = string = struct
  let name = "ls"
  let description =
    "Lists files and directories at a given path. \
     Returns a newline-separated list of entries with type prefix: \
     'f ' for files, 'd ' for directories. \
     Use '.' for the current working directory."

  type input = string
  type output = string

  let json_schema () =
    `Assoc [
      "type", `String "object";
      "properties", `Assoc [
        "path", `Assoc [
          "type", `String "string";
          "description", `String
            "The directory path to list. Use '.' for cwd. \
             Absolute paths are recommended."
        ]
      ];
      "required", `List [`String "path"]
    ]

  let parse_args json =
    let open Yojson.Safe.Util in
    try Ok (json |> member "path" |> to_string)
    with Type_error (s, _) -> Error s

  let format_output s = s

  type _ Effect.t += Exec : input -> output Effect.t

  let execute path =
    try
      if not (Sys.file_exists path) then
        Printf.sprintf "Error: path does not exist: %s" path
      else if not (Sys.is_directory path) then
        Printf.sprintf "Error: not a directory: %s" path
      else begin
        let entries = Sys.readdir path |> Array.to_list |> List.sort String.compare in
        let lines = List.map (fun name ->
          let full = Filename.concat path name in
          let prefix = if Sys.file_exists full && Sys.is_directory full then "d " else "f " in
          prefix ^ name
        ) entries in
        let header = Printf.sprintf "# ls %s  (cwd: %s)" path (Sys.getcwd ()) in
        String.concat "\n" (header :: lines)
      end
    with Sys_error msg -> "Error: " ^ msg
end
