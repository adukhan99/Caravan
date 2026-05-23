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
      let complete _net _cfg ?tools:_ _msgs =
        let reply = Types.assistant_msg "This is a summary." in
        Types.wrap_result ~raw_response:"mock" ~model:"mock" ~provider:"mock" reply
      let stream _net _cfg ?tools:_ _msgs ~on_token =
        on_token "This is a summary.";
        let reply = Types.assistant_msg "This is a summary." in
        Types.wrap_result ~raw_response:"mock" ~model:"mock" ~provider:"mock" reply
      let list_models _net _cfg = ["mock"]
    end in
    let provider = Provider.Provider ((module MockProvider), ()) in
    let sess = Session.create ~tools:[] "mock" provider in
    let sess = Session.add_messages sess [Types.user_msg "hello"; Types.assistant_msg "hi"] in
    
    let (sess', sum) = Session.summarise env#net sess in
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
    Content: [Conversation summary]: This is a summary. |}]
