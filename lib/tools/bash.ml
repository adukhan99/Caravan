open Caravan.Tool
let strict_mode =
  Caravan.Config.get_int_opt (Some "CARAVAN_STRICT_MODE") "strict_mode"
  |> Option.value ~default:1

module Bash : TOOL with type input = string and type output = string = struct
  let name = "bash"
  let description =
    let base =
      "The primary tool for running and orchestrating CLI applications and system utilities. \
       Use this to execute external programs, manage system tools, and process their output. \
       Commands may contain '&&' and '||' for control flow."
    in
    if strict_mode = 1 then
      base ^ " Do NOT separate multiple independent commands with ';' or newlines — \
              issue each as its own tool call so intermediate results can be verified."
    else base

  type input = string
  type output = string

  let json_schema () =
    `Assoc [
      "type", `String "object";
      "properties", `Assoc [
        "command", `Assoc [
          "type", `String "string";
          "description", `String "The bash command to execute."
        ]
      ];
      "required", `List [`String "command"]
    ]

  let has_delimiters s =
    String.contains s ';' || String.contains s '\n'

  let parse_args json =
    let open Yojson.Safe.Util in
    try
      let cmd = json |> member "command" |> to_string in
      if strict_mode = 1 && has_delimiters cmd then
        Error
          "Multiple commands detected (';' or newline). \
           Please issue each command as a separate tool call."
      else Ok cmd
    with Type_error (s, _) -> Error s

  let format_output s = s

  type _ Effect.t += Exec : input -> output Effect.t

  let run_single cmd =
    let ic = Unix.open_process_in cmd in
    let out = In_channel.input_all ic in
    let status = Unix.close_process_in ic in
    (out, status)

  let split_commands s =
    String.split_on_char ';' s
    |> List.concat_map (String.split_on_char '\n')
    |> List.map String.trim
    |> List.filter (fun t -> t <> "")

  let execute_sequential commands =
    let buf = Buffer.create 256 in
    let rec loop = function
      | [] -> Buffer.contents buf
      | cmd :: rest ->
        Buffer.add_string buf (Printf.sprintf "$ %s\n" cmd);
        (match
           (try run_single cmd
            with e ->
              let msg = "Error: " ^ Printexc.to_string e ^ "\n" in
              (msg, Unix.WEXITED 1))
         with
         | (out, Unix.WEXITED 0) ->
           Buffer.add_string buf out;
           if out <> "" && out.[String.length out - 1] <> '\n' then
             Buffer.add_char buf '\n';
           loop rest
         | (out, Unix.WEXITED n) ->
           Buffer.add_string buf out;
           Buffer.add_string buf (Printf.sprintf "[exit %d — stopped]\n" n);
           Buffer.contents buf
         | (out, _) ->
           Buffer.add_string buf out;
           Buffer.add_string buf "[killed by signal — stopped]\n";
           Buffer.contents buf)
    in
    loop commands

  let execute command =
    if strict_mode = 1 then
      (try
        let (out, status) = run_single command in
        match status with
        | Unix.WEXITED 0 -> out
        | Unix.WEXITED n -> Printf.sprintf "Command failed (exit %d):\n%s" n out
        | _ -> "Command killed by signal.\n" ^ out
      with e -> "Error executing command: " ^ Printexc.to_string e)
    else
      execute_sequential (split_commands command)
end
