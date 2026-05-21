(** MCP client and packed tool registry. *)

open Types
open Tool

type mcp_tool_def = {
  name : string;
  description : string;
  schema : Yojson.Safe.t;
}

type mcp_client = {
  name : string;
  in_chan : in_channel;
  out_chan : out_channel;
  err_chan : in_channel;
  mutable next_id : int;
  mutex : Mutex.t;
}

type registry = {
  mutable clients : mcp_client list;
}

let global_registry = { clients = [] }

let read_line_opt ic =
  try Some (input_line ic)
  with _ -> None

let rec read_response_matching ic expected_id =
  match read_line_opt ic with
  | None -> Error "Connection closed"
  | Some line ->
    if String.trim line = "" then
      read_response_matching ic expected_id
    else
      match Yojson.Safe.from_string line with
      | exception _ ->
        (* Print non-JSON lines as debug messages *)
        Printf.eprintf "[MCP stdout debug]: %s\n%!" line;
        read_response_matching ic expected_id
      | json ->
        let open Yojson.Safe.Util in
        match json |> member "id" with
        | `Int id when id = expected_id -> Ok json
        | _ ->
          (* Log incoming notification *)
          (match json |> member "method" |> to_string_option with
           | Some "notifications/message"
           | Some "notifications/log" ->
             let params = json |> member "params" in
             let text = params |> member "text" |> to_string_option |> Option.value ~default:"" in
             let level = params |> member "level" |> to_string_option |> Option.value ~default:"info" in
             Printf.eprintf "[MCP Log %s]: %s\n%!" level text
           | _ -> ());
          read_response_matching ic expected_id

let make_request id method_name params =
  let assoc = [
    ("jsonrpc", `String "2.0");
    ("id", `Int id);
    ("method", `String method_name);
  ] in
  let assoc =
    match params with
    | Some p -> ("params", p) :: assoc
    | None -> assoc
  in
  `Assoc assoc

let make_notification method_name params =
  let assoc = [
    ("jsonrpc", `String "2.0");
    ("method", `String method_name);
  ] in
  let assoc =
    match params with
    | Some p -> ("params", p) :: assoc
    | None -> assoc
  in
  `Assoc assoc

let send_request client method_name params =
  Mutex.lock client.mutex;
  let id = client.next_id in
  client.next_id <- client.next_id + 1;
  let req = make_request id method_name params in
  let req_str = Yojson.Safe.to_string req in
  try
    output_string client.out_chan (req_str ^ "\n");
    flush client.out_chan;
    let res = read_response_matching client.in_chan id in
    Mutex.unlock client.mutex;
    res
  with exn ->
    Mutex.unlock client.mutex;
    Error (Printexc.to_string exn)

let send_notification client method_name params =
  Mutex.lock client.mutex;
  let req = make_notification method_name params in
  let req_str = Yojson.Safe.to_string req in
  try
    output_string client.out_chan (req_str ^ "\n");
    flush client.out_chan;
    Mutex.unlock client.mutex
  with _ ->
    Mutex.unlock client.mutex

let start_stderr_forwarder name err_chan =
  ignore (Thread.create (fun () ->
    try
      let rec loop () =
        let line = input_line err_chan in
        Printf.eprintf "[MCP Stderr (%s)]: %s\n%!" name line;
        loop ()
      in
      loop ()
    with _ ->
      try close_in_noerr err_chan with _ -> ()
  ) ())

let spawn_server name command args =
  let args_arr = Array.of_list (command :: args) in
  try
    let (in_c, out_c, err_c) = Unix.open_process_full command args_arr in
    Ok (in_c, out_c, err_c)
  with exn ->
    Error (Printf.sprintf "Failed to spawn MCP server %s: %s" name (Printexc.to_string exn))

let connect name command args =
  match spawn_server name command args with
  | Error e -> Error e
  | Ok (in_chan, out_chan, err_chan) ->
    let client = {
      name;
      in_chan;
      out_chan;
      err_chan;
      next_id = 1;
      mutex = Mutex.create ();
    } in
    start_stderr_forwarder name err_chan;
    (* Initialize handshake *)
    let init_params = `Assoc [
      ("protocolVersion", `String "2024-11-05");
      ("capabilities", `Assoc []);
      ("clientInfo", `Assoc [
        ("name", `String "Caravan");
        ("version", `String "0.1.0");
      ]);
    ] in
    match send_request client "initialize" (Some init_params) with
    | Error err ->
      Error (Printf.sprintf "Initialization failed for %s: %s" name err)
    | Ok _res ->
      send_notification client "notifications/initialized" None;
      Ok client

let list_tools client =
  match send_request client "tools/list" (Some (`Assoc [])) with
  | Error err ->
    Printf.eprintf "Failed to list tools for %s: %s\n%!" client.name err;
    []
  | Ok json ->
    let open Yojson.Safe.Util in
    try
      let tools_list = json |> member "result" |> member "tools" |> to_list in
      List.filter_map (fun t_json ->
        let name_opt = t_json |> member "name" |> to_string_option in
        let desc_opt = t_json |> member "description" |> to_string_option in
        let schema = t_json |> member "inputSchema" in
        match name_opt, desc_opt with
        | Some name, Some desc ->
          Some { name; description = desc; schema }
        | _ -> None
      ) tools_list
    with exn ->
      Printf.eprintf "Error parsing tools for %s: %s\n%!" client.name (Printexc.to_string exn);
      []

let parse_call_response json =
  let open Yojson.Safe.Util in
  match json |> member "error" with
  | `Assoc err ->
    let msg =
      match List.assoc_opt "message" err with
      | Some (`String s) -> s
      | _ -> "Unknown error"
    in
    Error msg
  | _ ->
    match json |> member "result" with
    | `Null -> Error "Empty result from server"
    | result ->
      match result |> member "isError" |> to_bool_option with
      | Some true ->
        let content_list = result |> member "content" |> to_list in
        let text_contents = List.filter_map (fun item ->
          item |> member "text" |> to_string_option
        ) content_list in
        Error (String.concat "\n" text_contents)
      | _ ->
        let content_list = result |> member "content" |> to_list in
        let text_contents = List.filter_map (fun item ->
          item |> member "text" |> to_string_option
        ) content_list in
        Ok (String.concat "\n" text_contents)

let call_tool client original_name args =
  let params = `Assoc [
    ("name", `String original_name);
    ("arguments", args);
  ] in
  match send_request client "tools/call" (Some params) with
  | Error err -> Printf.sprintf "Error calling tool %s: %s" original_name err
  | Ok json ->
    match parse_call_response json with
    | Ok txt -> txt
    | Error err -> Printf.sprintf "Error: %s" err

let make_packed_tool (client : mcp_client) (tool_def : mcp_tool_def) =
  let caravan_name = client.name ^ "_" ^ tool_def.name in
  let module T = struct
    let name = caravan_name
    let description = tool_def.description
    type input = Yojson.Safe.t
    type output = string

    let json_schema () = tool_def.schema
    let parse_args json = Ok json
    let format_output s = s

    type _ Effect.t += Exec : input -> output Effect.t
    let execute args = call_tool client tool_def.name args
  end in
  Tool.Tool (module T)

let close_all () =
  List.iter (fun client ->
    try
      let _status = Unix.close_process_full (client.in_chan, client.out_chan, client.err_chan) in
      ()
    with _ -> ()
  ) global_registry.clients;
  global_registry.clients <- []

let () =
  at_exit close_all

let init_mcp_servers configs =
  close_all ();
  let clients = List.filter_map (fun (cfg : Config.mcp_server_config) ->
    Printf.eprintf "[MCP] Connecting to server '%s' (%s %s %s)...\n%!"
      cfg.name cfg.transport cfg.command (String.concat " " cfg.args);
    match connect cfg.name cfg.command cfg.args with
    | Ok client ->
      Printf.eprintf "[MCP] Connected successfully to '%s'.\n%!" cfg.name;
      Some client
    | Error err ->
      Printf.eprintf "[MCP Error] Failed to connect to '%s': %s\n%!" cfg.name err;
      None
  ) configs in
  global_registry.clients <- clients;
  let all_tools = List.concat_map (fun client ->
    let tools = list_tools client in
    Printf.eprintf "[MCP] Discovered %d tools from '%s'.\n%!" (List.length tools) client.name;
    List.map (fun t ->
      let packed = make_packed_tool client t in
      Printf.eprintf "  - Registered tool: %s\n%!" (Tool.name_of_packed packed);
      packed
    ) tools
  ) clients in
  all_tools
