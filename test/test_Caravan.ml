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

let%test_unit "config" =
  Unix.putenv "CARAVAN_DUMMY_KEY" "dummy_val";
  match Config.get_string_opt (Some "CARAVAN_DUMMY_KEY") "nonexistent" with
  | Some "dummy_val" -> ()
  | _ -> failwith "Config.get_string_opt failed to read environment variable"

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
    ⠋ Summarizing...[KThis is a summary.
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
  match res_exn with
  | Error (Caravan_error.Exception msg) -> assert (String.length msg > 0)
  | _ -> failwith "Expected Exception error"

let%test_unit "permission_policies" =
  assert (Permission.check Permission.Always_allow "tool" "args");
  assert (not (Permission.check Permission.Deny_all "tool" "args"));
  let custom = Permission.Custom (fun name args -> name = "safe_tool") in
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


