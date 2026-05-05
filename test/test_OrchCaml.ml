open OrchCaml

let test_memory_buffer () =
  let mem = Memory.Buffer.create ~window:2 () in
  let s1 = Types.system_msg "You are an assistant." in
  let m1 = Types.user_msg "Hello!" in
  let m2 = Types.assistant_msg "Hi!" in
  let m3 = Types.user_msg "Next" in
  let mem = Memory.Buffer.add mem s1 in
  let mem = Memory.Buffer.add mem m1 in
  let mem = Memory.Buffer.add mem m2 in
  let mem = Memory.Buffer.add mem m3 in
  
  let hist = Memory.Buffer.get mem in
  (* Note: we configured window=2, so m1 is expelled but s1 is safely isolated and prepended! *)
  assert (List.length hist = 3);
  let roles = List.map (fun m -> m.Types.role) hist in
  assert (roles = [Types.System; Types.Assistant; Types.User]);
  ()

let test_parser_json () =
  let fake_json = {| {"status": "ok", "count": 42} |} in
  match Parser.json_field "count" fake_json with
  | Ok (`Int 42) -> ()
  | _ -> failwith "JSON parser count field failure"

let test_parser_bool () =
  match Parser.bool "   yes  \n" with
  | Ok true -> ()
  | _ -> failwith "Bool parser failure"

let test_config () =
  (* Config is evaluated lazily, but config_path is evaluated at module load.
     We might not be able to fully mock HOME after load, but we can test get_string_opt
     with env var precedence. *)
  Unix.putenv "ORCHCAML_DUMMY_KEY" "dummy_val";
  match Config.get_string_opt (Some "ORCHCAML_DUMMY_KEY") "nonexistent" with
  | Some "dummy_val" -> ()
  | _ -> failwith "Config.get_string_opt failed to read environment variable"

let test_tool_read_file () =
  let path = "test_dummy_file.txt" in
  let ch = open_out path in
  output_string ch "Hello Tool";
  close_out ch;
  
  let json_args = Printf.sprintf {|{"path": "%s"}|} path in
  let tool = Tool.Tool (module OrchCamlTools.Read_file.Read_file) in
  let res = Lwt_main.run (Tool.dispatch tool json_args) in
  
  Sys.remove path;
  if res <> "Hello Tool" then
    failwith ("Tool read_file failed, got: " ^ res)

let test_tool_touch () =
  let path = "test_dummy_touch.txt" in
  if Sys.file_exists path then Sys.remove path;
  let json_args = Printf.sprintf {|{"path": "%s"}|} path in
  let tool = Tool.Tool (module OrchCamlTools.Touch.Touch) in
  let res = Lwt_main.run (Tool.dispatch tool json_args) in
  
  let exists = Sys.file_exists path in
  if Sys.file_exists path then Sys.remove path;
  
  if not exists then
    failwith ("Tool touch failed, file not created. Result: " ^ res)

let test_tool_mkdir () =
  let dir_path = "test_dummy_dir" in
  if Sys.file_exists dir_path then Unix.rmdir dir_path;
  
  let json_args = Printf.sprintf {|{"path": "%s"}|} dir_path in
  let tool = Tool.Tool (module OrchCamlTools.Mkdir.Mkdir) in
  let res = Lwt_main.run (Tool.dispatch tool json_args) in
  
  let exists = Sys.file_exists dir_path && Sys.is_directory dir_path in
  if exists then Unix.rmdir dir_path;
  
  if not exists then
    failwith ("Tool mkdir failed, directory not created. Result: " ^ res)

let test_tool_ls () =
  let json_args = {|{"path": "."}|} in
  let tool = Tool.Tool (module OrchCamlTools.Ls.Ls) in
  let res = Lwt_main.run (Tool.dispatch tool json_args) in
  
  (* We just check if it returns some files *)
  if String.length res = 0 then
    failwith ("Tool ls failed, output was empty")

let run_tests () =
  Printf.printf "Running tests...\n";
  test_memory_buffer ();
  test_parser_json ();
  test_parser_bool ();
  test_config ();
  test_tool_read_file ();
  test_tool_touch ();
  test_tool_mkdir ();
  test_tool_ls ();
  Printf.printf "All tests passed.\n"

let () = run_tests ()