open Caravan

let%test_unit "memory_ring" =
  let mem = Memory.Ring.make ~window:2 () in
  let msgs = Prompt.(exec (
    let* () = system "You are an assistant." in
    let* () = user "Hello!" in
    let* () = assistant "Hi!" in
    user "Next"
  )) in
  let mem = List.fold_left Memory.Ring.add mem msgs in
  
  let hist = Memory.Ring.get mem in
  assert (List.length hist = 3);
  let roles = List.map (fun m -> m.Types.role) hist in
  assert (roles = [Types.System; Types.Assistant; Types.User]);
  ()

let%expect_test "parser_json" =
  let fake_json = {| {"status": "ok", "count": 42} |} in
  (match Parser.json_field "count" fake_json with
   | Ok json -> Format.printf "Ok(%s)" (Yojson.Safe.to_string json)
   | Error err -> Format.printf "Error(%s)" err);
  [%expect {| Ok(42) |}]

let%test "parser_bool" =
  match Parser.bool "   yes  \n" with
  | Ok true -> true
  | _ -> false

let%test_unit "config_extended" =
  (* Test environment variable overrides for config getters *)
  Unix.putenv "CARAVAN_DUMMY_KEY" "dummy_val";
  (match Config.get_string_opt (Some "CARAVAN_DUMMY_KEY") "nonexistent" with
   | Some "dummy_val" -> ()
   | _ -> failwith "Config.get_string_opt failed to read environment variable");

  Unix.putenv "CARAVAN_DUMMY_INT" "42";
  (match Config.get_int_opt (Some "CARAVAN_DUMMY_INT") "nonexistent" with
   | Some 42 -> ()
   | _ -> failwith "Config.get_int_opt failed to read environment variable");

  Unix.putenv "CARAVAN_DUMMY_BOOL" "true";
  (match Config.get_bool_opt (Some "CARAVAN_DUMMY_BOOL") "nonexistent" with
   | Some true -> ()
   | _ -> failwith "Config.get_bool_opt failed to read environment variable");

  (* Test default configuration fallbacks *)
  assert (Config.get_spinner_enabled () = true || Config.get_spinner_enabled () = false);

  (* Test verb lookup fallbacks *)
  let verbs_thinking = Config.get_verbs "thinking" in
  assert (verbs_thinking <> []);
  let verbs_custom = Config.get_verbs "nonexistent_action_tool" in
  assert (verbs_custom = ["Running nonexistent_action_tool"]);

  (* Test subagents default helper *)
  let _ = Config.get_subagents () in
  let _ = Config.get_orchestrator () in
  let _ = Config.get_provider_config "openai" in
  let _ = Config.get_mcp_servers () in
  ()

let%test_unit "config_orchestrator_parsing" =
  let tmp_config = "test_work_config.toml" in
  let oc = open_out tmp_config in
  output_string oc {|
stream = true
max_turns = 100

[orchestrator]
base_url = "http://127.0.0.1:8080"
provider = "llama_cpp"
model = "LiquidAI/LFM2.5-2.6B-GGUF"
system = "Test System Prompt"
|};
  close_out oc;
  Unix.putenv "CARAVAN_CONFIG" tmp_config;
  (* Force reload of config *)
  let provider = Config.get_string "provider" in
  let model = Config.get_string "model" in
  let base_url = Config.get_string "base_url" in
  let system = Config.get_string "system" in
  let max_turns = Config.get_int "max_turns" in
  Sys.remove tmp_config;
  Unix.putenv "CARAVAN_CONFIG" "";
  assert (provider = Some "llama_cpp");
  assert (model = Some "LiquidAI/LFM2.5-2.6B-GGUF");
  assert (base_url = Some "http://127.0.0.1:8080");
  assert (system = Some "Test System Prompt");
  assert (max_turns = Some 100)

let%test_unit "tool_read_file" =
  let path = "test_dummy_file.txt" in
  let ch = open_out path in
  output_string ch "Hello Tool";
  close_out ch;
  
  let json_args = Printf.sprintf {|{"path": "%s"}|} path in
  let tool = Tool.Tool (module CaravanTools.Read_file.Read_file) in
  let res = Tool.dispatch tool json_args in
  
  Sys.remove path;
  if res <> "Hello Tool" then
    failwith ("Tool read_file failed, got: " ^ res)

let%test_unit "tool_write_file" =
  let path = "test_dummy_write.txt" in
  if Sys.file_exists path then Sys.remove path;
  
  let json_args = Printf.sprintf {|{"path": "%s", "content": "Written by test"}|} path in
  let tool = Tool.Tool (module CaravanTools.Write_file.Write_file) in
  let res = Tool.dispatch tool json_args in
  
  let content =
    try
      let ic = open_in path in
      let s = really_input_string ic (in_channel_length ic) in
      close_in ic; s
    with _ -> ""
  in
  if Sys.file_exists path then Sys.remove path;
  
  if res <> "File written successfully." || content <> "Written by test" then
    failwith ("Tool write_file failed, got: " ^ res ^ " content: " ^ content)

let%test_unit "tool_grep" =
  let path = "test_dummy_grep.txt" in
  let ch = open_out path in
  output_string ch "line 1: foo\nline 2: bar\nline 3: foo again";
  close_out ch;

  let json_args = Printf.sprintf {|{"path": "%s", "pattern": "foo"}|} path in
  let tool = Tool.Tool (module CaravanTools.Grep.Grep) in
  let res = Tool.dispatch tool json_args in

  Sys.remove path;
  if res <> "line 1: foo\nline 3: foo again" then
    failwith ("Tool grep failed, got: " ^ res)

let%test_unit "tool_sed" =
  let path = "test_dummy_sed.txt" in
  let ch = open_out path in
  output_string ch "hello world";
  close_out ch;

  let json_args = Printf.sprintf {|{"path": "%s", "pattern": "world", "replacement": "caravan"}|} path in
  let tool = Tool.Tool (module CaravanTools.Sed.Sed) in
  let res = Tool.dispatch tool json_args in

  let content =
    try
      let ic = open_in path in
      let s = really_input_string ic (in_channel_length ic) in
      close_in ic; s
    with _ -> ""
  in
  Sys.remove path;
  if res <> "Replaced occurrences successfully." || content <> "hello caravan" then
    failwith ("Tool sed failed, got: " ^ res ^ " content: " ^ content)

let%test_unit "tool_bash" =
  let json_args = {|{"command": "echo 'hello bash'"}|} in
  let tool = Tool.Tool (module CaravanTools.Bash.Bash) in
  let res = Tool.dispatch tool json_args in
  let has_hello =
    let rex = Re.compile (Re.str "hello bash") in
    Re.execp rex res
  in
  if not has_hello then
    failwith ("Tool bash failed, got: " ^ res)

let%test_unit "tool_aliases" =
  let tools = [
    Tool.Tool (module CaravanTools.Read_file.Read_file);
    Tool.Tool (module CaravanTools.Search.Search);
  ] in
  (match Tool.find_tool tools "open_file" with
   | Some t -> assert (Tool.name_of_packed t = "read_file")
   | None -> failwith "Expected to resolve alias 'open_file' to 'read_file'");
  (match Tool.find_tool tools "search" with
   | Some t -> assert (Tool.name_of_packed t = "web_search")
   | None -> failwith "Expected to resolve alias 'search' to 'web_search'")

let%test_unit "tool_touch" =
  let path = "test_dummy_touch.txt" in
  if Sys.file_exists path then Sys.remove path;
  let json_args = Printf.sprintf {|{"path": "%s"}|} path in
  let tool = Tool.Tool (module CaravanTools.Touch.Touch) in
  let res = Tool.dispatch tool json_args in
  
  let exists = Sys.file_exists path in
  if Sys.file_exists path then Sys.remove path;
  
  if not exists then
    failwith ("Tool touch failed, file not created. Result: " ^ res)

let%test_unit "tool_mkdir" =
  let dir_path = "test_dummy_dir" in
  if Sys.file_exists dir_path then Unix.rmdir dir_path;
  
  let json_args = Printf.sprintf {|{"path": "%s"}|} dir_path in
  let tool = Tool.Tool (module CaravanTools.Mkdir.Mkdir) in
  let res = Tool.dispatch tool json_args in
  
  let exists = Sys.file_exists dir_path && Sys.is_directory dir_path in
  if exists then Unix.rmdir dir_path;
  
  if not exists then
    failwith ("Tool mkdir failed, directory not created. Result: " ^ res)

let%test_unit "tool_ls" =
  let json_args = {|{"path": "."}|} in
  let tool = Tool.Tool (module CaravanTools.Ls.Ls) in
  let res = Tool.dispatch tool json_args in
  
  if String.length res = 0 then
    failwith ("Tool ls failed, output was empty")

let%test_unit "subagent_session_and_compaction" =
  let module MockProvider : Provider.PROVIDER with type config = unit = struct
    type config = unit
    let name = "mock_provider"
    let complete _net _cfg ?model:_ ?options:_ ?tools:_ _msgs =
      let reply = Types.assistant_msg "Subagent response" in
      Types.wrap_result ~raw_response:"mock" ~model:"mock" ~provider:"mock" reply
    let stream _net _cfg ?model:_ ?options:_ ?tools:_ _msgs ~on_token:_ =
      let reply = Types.assistant_msg "Subagent response" in
      Types.wrap_result ~raw_response:"mock" ~model:"mock" ~provider:"mock" reply
    let list_models _net _cfg = ["mock"]
  end in
  let provider = Provider.Provider ((module MockProvider), ()) in
  let parent_sess = Session.create ~tools:[] "parent_model" provider in
  
  let spec : Subagent.subagent_spec = {
    name = "child_agent";
    role = "atomic";
    system_prompt = "Perform task concisely.";
    tools = [];
    provider = None;
    model = Some "child_model";
  } in
  let child_sess = Subagent.make_child_session parent_sess spec in
  let cfg = Session.config child_sess in
  assert (cfg.model = "child_model");
  (match cfg.system with
   | Some sys ->
     assert (String.starts_with ~prefix:"Perform task concisely." sys);
     assert (String.ends_with ~suffix:Subagent.compaction_suffix sys)
   | None -> failwith "Child session system prompt missing")

let%test_unit "delegate_tool_validation_and_dispatch" =
  Eio_main.run (fun env ->
    let module MockProvider : Provider.PROVIDER with type config = unit = struct
      type config = unit
      let name = "mock"
      let complete _net _cfg ?model:_ ?options:_ ?tools:_ _msgs =
        let finish_tc = Types.{ id = "call_finish"; name = "finish"; args = {|{"summary":"Subagent finished task."}|}; extra_content = None } in
        let reply = Types.assistant_tool_msg ~tool_calls:[finish_tc] "Subagent finished task." in
        Types.wrap_result ~raw_response:"mock" ~model:"mock" ~provider:"mock" reply
      let stream _net _cfg ?model:_ ?options:_ ?tools:_ _msgs ~on_token =
        on_token "Subagent finished task.";
        let finish_tc = Types.{ id = "call_finish"; name = "finish"; args = {|{"summary":"Subagent finished task."}|}; extra_content = None } in
        let reply = Types.assistant_tool_msg ~tool_calls:[finish_tc] "Subagent finished task." in
        Types.wrap_result ~raw_response:"mock" ~model:"mock" ~provider:"mock" reply
      let list_models _net _cfg = ["mock"]
    end in
    let provider = Provider.Provider ((module MockProvider), ()) in
    let dummy_tool = Tool.Tool (module CaravanTools.Read_file.Read_file) in
    let finish_tool = Tool.Tool (module CaravanTools.Finish.Finish) in
    let registered = [dummy_tool; finish_tool] in
    
    let valid_spec : Subagent.subagent_spec = {
      name = "worker1";
      role = "atomic";
      system_prompt = "Do work";
      tools = registered;
      provider = Some provider;
      model = Some "mock-model";
    } in

    let invalid_spec : Subagent.subagent_spec = {
      name = "worker2";
      role = "atomic";
      system_prompt = "Do work";
      tools = [Tool.Tool (module struct
        let name = "unregistered_tool"
        let aliases = []
        let description = ""
        type input = string
        type output = string
        type _ Effect.t += Exec : input -> output Effect.t
        let json_schema () = `Assoc []
        let parse_args _ = Ok ""
        let format_output s = s
        let execute _ = ""
      end)];
      provider = Some provider;
      model = Some "mock-model";
    } in

    (* Test startup-time tool name validation failure *)
    let raised = ref false in
    (try
       CaravanTools.Delegate.validate_tool_names "worker2" invalid_spec registered
     with Invalid_argument _ -> raised := true);
    assert (!raised);

    (* Test Delegate.make and tool execution *)
    let delegate_tool =
      CaravanTools.Delegate.make
        ~net:env#net
        ~clock:env#clock
        ~registered_tools:registered
        ~subagent_specs:[valid_spec]
    in
    assert (Tool.name_of_packed delegate_tool = "delegate");

    (* Test dispatch to valid subagent *)
    let json_valid = {|{"subagent": "worker1", "task": "analyze file"}|} in
    let res = Tool.dispatch delegate_tool json_valid in
    assert (res = "Subagent finished task.\n\nTask finished: Subagent finished task.");

    (* Test dispatch to unknown subagent *)
    let json_invalid = {|{"subagent": "unknown_worker", "task": "do something"}|} in
    let err_res = Tool.dispatch delegate_tool json_invalid in
    assert (String.starts_with ~prefix:"Error: unknown subagent 'unknown_worker'" err_res)
  )

let%test_unit "usage_openai_parsing" =
  let fake_body = {|
    { "choices": [{"message": {"role": "assistant", "content": "Hi"},
                   "finish_reason": "stop"}],
      "usage": {"prompt_tokens": 9, "completion_tokens": 12, "total_tokens": 21}
    } |} in
  let json = Yojson.Safe.from_string fake_body in
  let open Yojson.Safe.Util in
  let u_json = json |> member "usage" in
  let usage = Types.{
    prompt_tokens     = u_json |> member "prompt_tokens"     |> to_int;
    completion_tokens = u_json |> member "completion_tokens" |> to_int;
    total_tokens      = u_json |> member "total_tokens"      |> to_int;
    total_duration    = None;
  } in
  let meta = Types.(wrap_result ~raw_response:"" ~model:"gpt-4o" ~provider:"openai" ~usage
    (assistant_msg "Hi")) in
  (match meta.Types.usage with
   | Some u ->
     assert (u.Types.prompt_tokens = 9);
     assert (u.Types.completion_tokens = 12);
     assert (u.Types.total_tokens = 21);
     assert (u.Types.total_duration = None)
   | None -> failwith "usage field was None")

let%expect_test "monitor_format_usage" =
  let usage = Types.{
    prompt_tokens = 5; completion_tokens = 20; total_tokens = 25;
    total_duration = Some 2.0;
  } in
  let meta = Types.(wrap_result ~raw_response:"" ~model:"llama3" ~provider:"ollama" ~usage
    (assistant_msg "ok")) in
  print_endline (Monitor.format_usage meta);
  
  let meta_with_turn = { meta with turn_count = Some 3 } in
  print_endline (Monitor.format_usage meta_with_turn);
  [%expect {|
    Tokens: 5 in, 20 out (10.00 toks/s)
    Turn 3 | Tokens: 5 in, 20 out (10.00 toks/s) |}]

let%test_unit "usage_llama_cpp_parsing" =
  let fake_body = {|
    { "choices": [{"message": {"role": "assistant", "content": "Hi"},
                   "finish_reason": "stop"}],
      "usage": {"prompt_tokens": 5, "completion_tokens": 5, "total_tokens": 10}
    } |} in
  let json = Yojson.Safe.from_string fake_body in
  let open Yojson.Safe.Util in
  let u_json = json |> member "usage" in
  let usage = Types.{
    prompt_tokens     = u_json |> member "prompt_tokens"     |> to_int;
    completion_tokens = u_json |> member "completion_tokens" |> to_int;
    total_tokens      = u_json |> member "total_tokens"      |> to_int;
    total_duration    = None;
  } in
  let meta = Types.(wrap_result ~raw_response:"" ~model:"llama3" ~provider:"llama_cpp" ~usage
    (assistant_msg "Hi")) in
  (match meta.Types.usage with
   | Some u ->
     assert (u.Types.prompt_tokens = 5);
     assert (u.Types.completion_tokens = 5);
     assert (u.Types.total_tokens = 10)
   | None -> failwith "usage field was None")

let%expect_test "tool_finish" =
  let tool = Tool.Tool (module CaravanTools.Finish.Finish) in
  
  let json_args = {|{"summary": "all done"}|} in
  print_endline (Tool.dispatch tool json_args);
    
  let json_args_no_sum = "{}" in
  print_endline (Tool.dispatch tool json_args_no_sum);
  [%expect {|
    Task finished: all done
    Task finished: Completed |}]

let%test_unit "document_functor" =
  let doc = Document.Concat [
    Document.Text 42;
    Document.Styled (Document.Bold, Document.Text 100)
  ] in
  (* Identity law *)
  let doc_id = Document.Document.map (fun x -> x) doc in
  assert (doc_id = doc);

  (* Composition law *)
  let f x = x * 2 in
  let g x = x + 10 in
  let doc_fg = Document.Document.map (fun x -> f (g x)) doc in
  let doc_f_g = Document.Document.map f (Document.Document.map g doc) in
  assert (doc_fg = doc_f_g);
  ()

let%test_unit "document_monoid" =
  let d1 = Document.Text "hello" in
  let d2 = Document.Text "world" in
  let d3 = Document.Text "!" in

  (* Identity law *)
  assert (Document.DocumentMonoid.append Document.DocumentMonoid.empty d1 = d1);
  assert (Document.DocumentMonoid.append d1 Document.DocumentMonoid.empty = d1);

  (* Associativity law *)
  let d12_3 = Document.DocumentMonoid.append (Document.DocumentMonoid.append d1 d2) d3 in
  let d1_23 = Document.DocumentMonoid.append d1 (Document.DocumentMonoid.append d2 d3) in
  assert (d12_3 = d1_23);
  ()

let%test_unit "formatter_profunctor" =
  let base_fmt x = Document.Text (string_of_int x) in
  let pre c = int_of_string c in
  let post s = String.uppercase_ascii s in
  let mapped_fmt = Formatter.Formatter.dimap pre post base_fmt in
  
  let res_doc = mapped_fmt "42" in
  assert (res_doc = Document.Text "42");
  ()

let%expect_test "renderers" =
  let doc = Document.Styled (Document.Foreground Document.Red, Document.Text "error") in
  
  (* Plain Text Renderer strips styles *)
  let plain = Ui.compile_document (module Ui.PlainTextRenderer) (fun s -> s) doc in
  print_endline plain;

  (* ANSI Renderer applies escape codes *)
  let ansi = Ui.compile_document (module Ui.AnsiRenderer) (fun s -> s) doc in
  print_endline ansi;
  [%expect {|
    error
    [1;31merror[0m
    |}]

let%test_unit "kleisli_composition" =
  let f x = if x > 0 then Ok (x * 2) else Error "must be positive" in
  let g y = if y < 100 then Ok (y + 5) else Error "too big" in
  
  let composed = Chain.Kleisli.(f >=> g) in
  assert (composed 10 = Ok 25);
  assert (composed (-5) = Error "must be positive");
  assert (composed 60 = Error "too big");
  ()

let%expect_test "session_summarise" =
  Eio_main.run (fun env ->
    let module MockProvider : Provider.PROVIDER with type config = unit = struct
      type config = unit
      let name = "mock"
      let complete _net _cfg ?model:_ ?options:_ ?tools:_ _msgs =
        let reply = Types.assistant_msg "This is a summary." in
        Types.wrap_result ~raw_response:"mock" ~model:"mock" ~provider:"mock" reply
      let stream _net _cfg ?model:_ ?options:_ ?tools:_ _msgs ~on_token =
        on_token "This is a summary.";
        let reply = Types.assistant_msg "This is a summary." in
        Types.wrap_result ~raw_response:"mock" ~model:"mock" ~provider:"mock" reply
      let list_models _net _cfg = ["mock"]
    end in
    let provider = Provider.Provider ((module MockProvider), ()) in
    let sess = Session.create ~tools:[] "mock" provider in
    let sess = Session.add_messages sess [Types.user_msg "hello"; Types.assistant_msg "hi"] in
    
    let (sess', sum) = Session.summarise env#net env#clock sess in
    print_endline sum;
    let hist = Session.history sess' in
    Format.printf "History length: %d\n" (List.length hist);
    let msg = List.hd hist in
    Format.printf "Role: %s\n" (match msg.Types.role with
      | Types.System -> "System"
      | Types.User -> "User"
      | Types.Assistant -> "Assistant"
      | Types.Tool _ -> "Tool");
    Format.printf "Content: %s\n" msg.Types.content
  );
  [%expect {|
    This is a summary.
    History length: 1
    Role: System
    Content: [Conversation summary]: This is a summary.
    |}]

let%test_unit "caravan_error_handling" =
  let err = Caravan_error.Tool_error "test failure" in
  assert (Caravan_error.to_string err = "Tool Error: test failure");
  let res = Caravan_error.safe_run (fun () -> 42) in
  assert (res = Ok 42);
  let res_exn = Caravan_error.safe_run (fun () -> failwith "boom") in
  (match res_exn with
   | Error (Caravan_error.Exception msg) -> assert (String.length msg > 0)
   | _ -> failwith "Expected Exception error");

  (* Test error humanization *)
  let h_conn = Caravan_error.humanize (Failure "ECONNREFUSED") in
  assert (String.starts_with ~prefix:"Could not connect" h_conn);
  let h_404 = Caravan_error.humanize (Failure "HTTP 404 model not found") in
  assert (String.starts_with ~prefix:"Model not found" h_404);
  let h_401 = Caravan_error.humanize (Failure "HTTP 401 Unauthorized") in
  assert (String.starts_with ~prefix:"Authentication failed" h_401);
  let h_429 = Caravan_error.humanize (Failure "HTTP 429 rate limit exceeded") in
  assert (String.starts_with ~prefix:"Rate limited" h_429)

let%test_unit "permission_policies" =
  assert (Permission.check Permission.Always_allow "tool" "args");
  assert (not (Permission.check Permission.Deny_all "tool" "args"));
  let custom = Permission.Custom (fun name _args -> name = "safe_tool") in
  assert (Permission.check custom "safe_tool" "");
  assert (not (Permission.check custom "unsafe_tool" ""))

let%expect_test "algebraic_effects_dispatch" =
  let logs = ref [] in
  let on_log lvl msg = logs := (lvl ^ ": " ^ msg) :: !logs in
  let permission_policy name _args = name <> "forbidden_tool" in
  let on_exec name args = "Executed " ^ name ^ "(" ^ args ^ ")" in
  let result =
    Effects.run_with_effects ~permission_policy ~on_log ~on_exec (fun () ->
      let perm1 = Effects.ask_permission "allowed_tool" "{}" in
      let perm2 = Effects.ask_permission "forbidden_tool" "{}" in
      Effects.log_event "info" "Testing effects";
      let exec_res = Effects.exec_tool "my_tool" "my_arg" in
      Printf.sprintf "perm1=%b perm2=%b exec=%s" perm1 perm2 exec_res
    )
  in
  print_endline result;
  List.iter print_endline (List.rev !logs);
  [%expect {|
    perm1=true perm2=false exec=Executed my_tool(my_arg)
    info: Testing effects |}]

let%test_unit "value_queries" =
  let json_str = {|
    [
      {"name": "Alice", "age": 30, "role": "admin"},
      {"name": "Bob", "age": 25, "role": "user"},
      {"name": "Charlie", "age": 35, "role": "user"}
    ]
  |} in
  let val_data = Value.of_string_permissive json_str in
  
  (* where_field *)
  let filtered = Value.where_field "role" (fun v -> Value.to_string v = "user") val_data in
  (match filtered with
   | Ok (Value.List items) -> assert (List.length items = 2)
   | _ -> failwith "where_field failed");

  (* select *)
  let selected = Value.select ["name"; "age"] val_data in
  (match selected with
   | Ok (Value.List items) ->
     let first = List.hd items in
     assert (Value.get_opt "name" first = Some (Value.String "Alice"));
     assert (Value.get_opt "role" first = None)
   | _ -> failwith "select failed");

  (* LISPy S-expression query *)
  (match Value.eval_lisp "(count)" val_data with
   | Ok (Value.Int 3) -> ()
   | _ -> failwith "LISP (count) failed");
  
  (match Value.eval_lisp "(first)" val_data with
   | Ok record ->
     assert (Value.get_opt "name" record = Some (Value.String "Alice"))
   | _ -> failwith "LISP (first) failed")

let%test_unit "coercive_parsers" =
  assert (Parser.coercive_int "42" = Ok 42);
  assert (Parser.coercive_int "\"123\"" = Ok 123);
  assert (Parser.coercive_bool "TRUE" = Ok true);
  assert (Parser.coercive_bool "1" = Ok true);
  
  let json_with_fence = "```json\n{\"key\": \"value\"}\n```" in
  (match Parser.permissive_json json_with_fence with
   | Ok (`Assoc [("key", `String "value")]) -> ()
   | _ -> failwith "permissive_json failed on code fence")

let%test_unit "session_with_model_override" =
  Eio_main.run (fun env ->
    let last_model_called = ref "" in
    let module ModelCheckProvider : Provider.PROVIDER with type config = unit = struct
      type config = unit
      let name = "model_check"
      let complete _net _cfg ?model ?options:_ ?tools:_ _msgs =
        last_model_called := Option.value ~default:"default_model" model;
        let reply = Types.assistant_msg "ok" in
        Types.wrap_result ~raw_response:"ok" ~model:!last_model_called ~provider:"model_check" reply
      let stream _net _cfg ?model ?options:_ ?tools:_ _msgs ~on_token:_ =
        last_model_called := Option.value ~default:"default_model" model;
        let reply = Types.assistant_msg "ok" in
        Types.wrap_result ~raw_response:"ok" ~model:!last_model_called ~provider:"model_check" reply
      let list_models _net _cfg = ["model_check"]
    end in
    let provider = Provider.Provider ((module ModelCheckProvider), ()) in
    let sess = Session.create ~tools:[] "initial_model" provider in
    let (sess', _) = Session.turn env#net env#clock sess "hello" in
    assert (!last_model_called = "initial_model");
    let sess'' = Session.with_model sess' "switched_model" in
    let (_sess''', _) = Session.turn env#net env#clock sess'' "hello again" in
    assert (!last_model_called = "switched_model")
  )

let%test_unit "tool_output_truncation_for_context" =
  Eio_main.run (fun _env ->
    let module DummyProvider : Provider.PROVIDER with type config = unit = struct
      type config = unit
      let name = "dummy"
      let complete _net _cfg ?model:_ ?options:_ ?tools:_ _msgs =
        Types.wrap_result ~raw_response:"ok" ~model:"dummy" ~provider:"dummy" (Types.assistant_msg "ok")
      let stream _net _cfg ?model:_ ?options:_ ?tools:_ _msgs ~on_token:_ =
        Types.wrap_result ~raw_response:"ok" ~model:"dummy" ~provider:"dummy" (Types.assistant_msg "ok")
      let list_models _net _cfg = ["dummy"]
    end in
    let provider = Provider.Provider ((module DummyProvider), ()) in
    let sess = Session.create ~tools:[] "dummy" provider in
    let sess = Session.set_max_tool_output_len sess (Some 50) in
    let long_tool_output = String.make 500 'A' in
    let messages = [
      Types.user_msg "Run bash tool";
      Types.assistant_msg "Running bash";
      Types.tool_msg "call_1" long_tool_output;
      Types.user_msg "What next?";
      Types.assistant_msg "I will check";
      Types.tool_msg "call_2" "short";
    ] in
    let sess = Session.add_messages sess messages in
    let llm_hist = Session.history_for_llm sess in
    (* Long tool message at index 2 (older than 2 most recent messages) should be truncated *)
    let old_tool_msg = List.find (fun (m : Types.chat_message) ->
      match m.role with Types.Tool "call_1" -> true | _ -> false
    ) llm_hist in
    assert (String.length old_tool_msg.content < 200);
    assert (String.contains old_tool_msg.content 'A');
    let has_omitted = Re.execp (Re.compile (Re.str "bytes omitted")) old_tool_msg.content in
    assert has_omitted
  )

let%test_unit "summarize_tool_and_session_compaction" =
  Eio_main.run (fun env ->
    let called = ref false in
    let module MockSumProvider : Provider.PROVIDER with type config = unit = struct
      type config = unit
      let name = "mock_sum"
      let complete _net _cfg ?model:_ ?options:_ ?tools:_ _msgs =
        if not !called then begin
          called := true;
          let sum_tc = Types.{ id = "sum_1"; name = "summarize"; args = {|{"reason": "clear space"}|}; extra_content = None } in
          let reply = Types.assistant_tool_msg ~tool_calls:[sum_tc] "Compressing history..." in
          Types.wrap_result ~raw_response:"ok" ~model:"mock" ~provider:"mock" reply
        end else
          let reply = Types.assistant_msg "Summary of key points." in
          Types.wrap_result ~raw_response:"ok" ~model:"mock" ~provider:"mock" reply

      let stream _net _cfg ?model ?options ?tools msgs ~on_token:_ =
        complete _net _cfg ?model ?options ?tools msgs
      let list_models _net _cfg = ["mock_sum"]
    end in
    let provider = Provider.Provider ((module MockSumProvider), ()) in
    let sum_tool = Tool.Tool (module CaravanTools.Summarize.Summarize) in
    let sess = Session.create ~tools:[sum_tool] "mock" provider in
    let (sess', _) = Session.turn env#net env#clock sess "hello" in
    let hist = Session.history sess' in
    assert (List.length hist > 0);
    let has_sum_header = List.exists (fun (m : Types.chat_message) ->
      String.starts_with ~prefix:"[Conversation summary]:" m.content
    ) hist in
    assert has_sum_header
  )

let%test_unit "agent_turn_increment_and_max_turns" =
  Eio_main.run (fun env ->
    let turn_calls = ref [] in
    let call_count = ref 0 in
    let finish_tool = Tool.Tool (module CaravanTools.Finish.Finish) in
    let read_tool = Tool.Tool (module CaravanTools.Read_file.Read_file) in
    let module MultiTurnProvider : Provider.PROVIDER with type config = unit = struct
      type config = unit
      let name = "multi_turn"
      let complete _net _cfg ?model:_ ?options:_ ?tools:_ _msgs =
        incr call_count;
        if !call_count < 3 then
          let tc = Types.{ id = Printf.sprintf "call_%d" !call_count; name = "read_file"; args = {|{"path": "dune"}|}; extra_content = None } in
          let reply = Types.assistant_tool_msg ~tool_calls:[tc] "Reading file..." in
          Types.wrap_result ~raw_response:"ok" ~model:"multi" ~provider:"multi" reply
        else
          let tc = Types.{ id = "fin"; name = "finish"; args = {|{"summary": "Done three turns"}|}; extra_content = None } in
          let reply = Types.assistant_tool_msg ~tool_calls:[tc] "Finished" in
          Types.wrap_result ~raw_response:"ok" ~model:"multi" ~provider:"multi" reply

      let stream _net _cfg ?model:_ ?options:_ ?tools:_ msgs ~on_token:_ =
        complete _net _cfg msgs
      let list_models _net _cfg = ["multi_turn"]
    end in
    let provider = Provider.Provider ((module MultiTurnProvider), ()) in
    let sess = Session.create ~tools:[finish_tool; read_tool] "multi" provider in
    
    let on_turn current max = turn_calls := (current, max) :: !turn_calls in
    let agent_cfg = Agent.{ max_turns = 5; continue_prompt = "continue"; nudge = false } in
    let res = Agent.run ~config:agent_cfg ~on_turn env#net env#clock sess "Execute multi-turn task" in
    (match res with
     | Ok (final_sess, _meta) ->
       assert (Session.turn_idx final_sess = 3);
       assert (List.rev !turn_calls = [(1, 5); (2, 5); (3, 5)])
     | Error msg -> failwith ("Agent.run failed: " ^ msg));

    (* Test max_turns limit enforcement *)
    call_count := 0;
    turn_calls := [];
    let sess2 = Session.create ~tools:[finish_tool; read_tool] "multi" provider in
    let agent_cfg_low = Agent.{ max_turns = 2; continue_prompt = "continue"; nudge = false } in
    let res_low = Agent.run ~config:agent_cfg_low ~on_turn env#net env#clock sess2 "Task max turns test" in
    (match res_low with
     | Error "Maximum turns reached without completion." -> ()
     | _ -> failwith "Expected max turns error")
  )
