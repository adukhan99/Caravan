(** Interactive TUI / REPL entry point. *)

open Caravan
open Caravan.Types
open Caravan.Config
open Ui
open Cmdliner

(* --- Types --- *)

type repl_state = {
  mutable session          : Session.t;
  mutable provider_name    : string;
  mutable model            : string;
  mutable provider         : Provider.packed_provider;
  mutable base_url         : string option;
  mutable total_tokens_in  : int;
  mutable total_tokens_out : int;
}

(* --- Constants & Environment --- *)

let static_tools : Caravan.Tool.packed_tool list = 
  let base = CaravanTools.All_tools.all_tools in
  let strict_mode = 
    Caravan.Config.get_int_opt (Some "CARAVAN_STRICT_MODE") "strict_mode"
    |> Option.value ~default:1
  in
  if strict_mode = 2 then
    List.filter (fun t -> Caravan.Tool.name_of_packed t <> "bash") base
  else base

let all_tools_ref = ref static_tools

let all_tools () = !all_tools_ref

let init_mcp () =
  let configs = Config.get_mcp_servers () in
  if configs <> [] then begin
    let mcp = Caravan.Mcp.init_mcp_servers configs in
    all_tools_ref := static_tools @ mcp
  end


type help_group = {
  title : string;
  commands : (string * string * string option) list;
}

let help_groups = [
  { title = "Chat";
    commands = [
      ("/agent <task>", "Let the AI work autonomously on a task",
       Some "Example: /agent summarize the files in this directory");
      ("/system [text]", "Set instructions for the AI's personality", None);
      ("/clear", "Start a fresh conversation", None);
    ] };
  { title = "Model and Provider";
    commands = [
      ("/model <name>", "Switch AI model",
       Some "Example: /model gpt-4o");
      ("/provider <p> [url]", "Switch AI provider",
       Some "Example: /provider openai");
      ("/models", "Browse available models", None);
      ("/providers", "List supported providers", None);
    ] };
  { title = "Tuning";
    commands = [
      ("/temp <0.0-2.0>", "Creativity level (higher = more creative)", None);
      ("/memory <n>", "How many messages to remember (0 = unlimited)", None);
      ("/summarise", "Compress conversation to save memory", None);
    ] };
  { title = "Session";
    commands = [
      ("/history", "Show conversation so far", None);
      ("/export [file]", "Save conversation to a file", None);
      ("/config", "Show current settings", None);
    ] };
  { title = "Exit";
    commands = [
      ("/quit", "Exit Caravan", None);
    ] };
]

let print_help_grouped groups =
  List.iter (fun g ->
    println_ansi (bold (yellow (Printf.sprintf "\n  %s" g.title)));
    List.iter (fun (cmd, desc, ex) ->
      println_ansi (Printf.sprintf "    %s  %s"
        (cyan (Printf.sprintf "%-24s" cmd)) (dim desc));
      match ex with
      | Some e -> println_ansi (Printf.sprintf "      %s" (green e))
      | None -> ()
    ) g.commands
  ) groups;
  print_newline ()

(* --- Tool & Provider Management --- *)

let get_available_tools () =
  let tools_dir = "lib/tools" in
  if Sys.file_exists tools_dir && Sys.is_directory tools_dir then
    let files = Array.to_list (Sys.readdir tools_dir) in
    let ml_files = List.filter (fun f -> Filename.check_suffix f ".ml") files in
    let desc_re = 
      let open Re in
      compile (seq [
        str "let description"; rep space; char '='; rep space;
        char '"'; group (rep (compl [char '"'])); char '"'
      ])
    in
    let all = List.map (fun f ->
      let path = Filename.concat tools_dir f in
      let name = Filename.chop_suffix f ".ml" in
      let desc =
        try
          let ic = open_in path in
          let rec loop () =
            let line = input_line ic in
            match Re.exec_opt desc_re line with
            | Some g -> Re.Group.get g 1
            | None -> loop ()
          in
          let d = loop () in
          close_in ic; d
        with _ -> "No description available"
      in
      (name, desc)
    ) ml_files in
    let strict_mode = 
      Caravan.Config.get_int_opt (Some "CARAVAN_STRICT_MODE") "strict_mode"
      |> Option.value ~default:1
    in
    if strict_mode = 2 then
      List.filter (fun (name, _) -> name <> "bash") all
    else all
  else []

let make_any_provider name model base_url =
  let factories = [
    ("openai",    fun ~base_url ~model -> CaravanProviders.Openai.make_provider ?base_url ~model ());
    ("llama_cpp", fun ~base_url ~model -> CaravanProviders.Llama_cpp.make_provider ?base_url ~model ());
    ("ollama",    fun ~base_url ~model -> CaravanProviders.Ollama.make_provider ?base_url ~model ());
  ] in
  let maker = List.assoc_opt name factories |> Option.value ~default:(List.assoc "ollama" factories) in
  maker ~base_url ~model

let rebuild_session st =
  let provider = make_any_provider st.provider_name st.model st.base_url in
  st.provider <- provider;
  st.session  <- Session.create ~tools:(all_tools ()) st.model provider


let on_token token =
  print_ansi (green token);
  flush stdout

(* --- Slash Command Helpers --- *)

let usage cmd msg = println_ansi (red (Printf.sprintf "Usage: %s %s" cmd msg))

let update_float_opt st cmd name setter min_v max_v = function
  | [v_str] ->
    (match float_of_string_opt v_str with
     | Some v when v >= min_v && v <= max_v ->
       st.session <- Session.set_options st.session (setter v);
       println_ansi (yellow (Printf.sprintf "  ✓ %s → %.2f" name v))
     | _ -> usage cmd (Printf.sprintf "<float %.1f-%.1f>" min_v max_v))
  | _ -> usage cmd (Printf.sprintf "<float %.1f-%.1f>" min_v max_v)

let update_int_opt st cmd name setter = function
  | [v_str] ->
    (match int_of_string_opt v_str with
     | Some v ->
       st.session <- Session.set_options st.session (setter v);
       println_ansi (yellow (Printf.sprintf "  ✓ %s → %d" name v))
     | _ -> usage cmd "<int>")
  | _ -> usage cmd "<int>"

(* --- Slash Command Handling --- *)

let handle_slash_command net clock st line =
  let parts = String.split_on_char ' ' (String.trim line) |> List.filter (fun s -> s <> "") in
  match parts with
  | [] -> ()

  | ["/quit"] | ["/exit"] | ["/q"] ->
    println_ansi (dim "\nGoodbye.");
    exit 0

  | ["/help"] | ["/?"] ->
    print_help_grouped help_groups

  | "/agent" :: rest ->
    let task = String.concat " " rest |> String.trim in
    if task = "" then usage "/agent" "<task description>"
    else begin
      println_ansi (bold (yellow (Printf.sprintf "\n  Starting agentic loop for: %s" task)));
      let on_turn current max =
        println_ansi (dim (Printf.sprintf "  -- Turn %d/%d --------" current max))
      in
      (try
        let stream_enabled = Config.get_stream () in
        let result =
          if stream_enabled then
            Agent.run_stream ~on_turn net clock st.session task ~on_token
          else
            Agent.run ~on_turn net clock st.session task
        in
        match result with
        | Ok (new_sess, res) ->
          st.session <- new_sess;
          print_newline ();
          println_ansi (green "╔═══════════════════════════════════════════════════════╗");
          println_ansi (green "║  ✓ Agent completed task successfully!               ║");
          println_ansi (green "╚═══════════════════════════════════════════════════════╝");
          println_ansi (dim (Monitor.format_usage res))
        | Error e ->
          println_ansi (red (Printf.sprintf "  [Agent Error]: %s" e))
      with exn ->
        println_ansi (red (Printf.sprintf "  [Error]: %s" (Caravan_error.humanize exn))))
    end

  | "/model" :: rest ->
    (match rest with
     | [new_model] ->
       st.model <- new_model;
       let provider = make_any_provider st.provider_name new_model st.base_url in
       st.provider <- provider;
       st.session <- Session.with_provider (Session.with_model st.session new_model) provider;
       println_ansi (yellow (Printf.sprintf "  ✓ Model → %s" new_model))
     | _ -> usage "/model" "<model-name>")

  | "/provider" :: rest ->
    (match rest with
     | name :: rest ->
       let base_url = if rest = [] then None else Some (String.concat " " rest) in
       st.provider_name <- name;
       st.base_url <- base_url;
       let provider = make_any_provider name st.model base_url in
       st.provider <- provider;
       st.session <- Session.with_provider st.session provider;
       println_ansi (yellow (Printf.sprintf "  ✓ Provider → %s %s" name (Option.value ~default:"" base_url)))
     | [] -> usage "/provider" "<name> [url]")

  | "/system" :: rest ->
    let text = String.concat " " rest |> String.trim in
    st.session <- Session.set_system st.session text;
    if text = "" then println_ansi (yellow "  ✓ System prompt cleared")
    else println_ansi (yellow (Printf.sprintf "  ✓ System prompt set (%d chars)" (String.length text)))

  | "/memory" :: rest ->
    (match rest with
     | [n_str] ->
       (match int_of_string_opt n_str with
        | Some n ->
          st.session <- Session.set_memory_size st.session n;
          println_ansi (yellow (Printf.sprintf "  ✓ Memory window → %s"
            (if n = 0 then "unlimited" else string_of_int n)))
        | None -> usage "/memory" "<n>")
     | _ -> usage "/memory" "<n>")

  | ["/summarise"] | ["/summarize"] ->
    let hist = Session.history st.session in
    if hist = [] then
      println_ansi (yellow "  ⚠ Conversation history is empty; nothing to summarize.")
    else begin
      println_ansi (bold (yellow "\n  Summarizing conversation history..."));
      (try
         let (new_sess, summary) = Session.summarise net clock st.session in
         st.session <- new_sess;
         println_ansi (bold (green "  ✓ Context slimmed successfully."));
         println_ansi (cyan (Printf.sprintf "  [Summary]: %s" summary))
       with exn ->
         println_ansi (red (Printf.sprintf "  Error summarizing: %s" (Caravan_error.humanize exn))))
    end

  | ["/clear"] ->
    st.session <- Session.clear st.session;
    println_ansi (yellow "  ✓ History cleared")

  | ["/history"] ->
    let hist = Session.history st.session in
    if hist = [] then println_ansi (dim "  (empty history)")
    else
      List.iter (fun msg ->
        let role_str = role_to_string msg.role in
        let colour = match msg.role with
          | System -> yellow | User -> cyan | Assistant -> green | Tool _ -> magenta in
        println_ansi (Printf.sprintf "%s: %s" (bold (colour role_str)) (dim msg.content))
      ) hist

  | "/export" :: rest ->
    (match rest with
     | [file] ->
       (try
         let oc = open_out file in
         output_string oc (Yojson.Safe.pretty_to_string (Session.export_json st.session));
         close_out oc;
         println_ansi (yellow (Printf.sprintf "  ✓ Exported to %s" file))
       with exn -> println_ansi (red (Printf.sprintf "  Error: %s" (Caravan_error.humanize exn))))
     | [] -> print_endline (Yojson.Safe.pretty_to_string (Session.export_json st.session))
     | _ -> usage "/export" "[file]")

  | ["/models"] ->
    (try
      let models = Provider.list_models_packed net st.provider in
      println_ansi (bold (yellow (Printf.sprintf "\n  Models on %s:" st.provider_name)));
      List.iteri (fun i m ->
        let mark = if m = st.model then green " > " else dim "   " in
        let num = cyan (Printf.sprintf "[%d]" (i + 1)) in
        println_ansi (Printf.sprintf "  %s %s%s" num mark (white m))
      ) models;
      if is_tty then begin
        println_ansi (dim "\n  Enter a number to switch, or press Enter to cancel:");
        (try
          let input = String.trim (input_line stdin) in
          if input <> "" then
            match int_of_string_opt input with
            | Some n when n >= 1 && n <= List.length models ->
              let new_model = List.nth models (n - 1) in
              st.model <- new_model;
              let provider = make_any_provider st.provider_name new_model st.base_url in
              st.provider <- provider;
              st.session <- Session.with_provider
                (Session.with_model st.session new_model) provider;
              println_ansi (yellow (Printf.sprintf "  Switched to %s" new_model))
            | _ -> println_ansi (red "  Invalid selection.")
        with End_of_file -> ())
      end
    with exn ->
      println_ansi (red (Caravan_error.humanize exn)))

  | ["/providers"] ->
    let providers = ["ollama"; "openai"; "llama_cpp"] in
    println_ansi (bold (yellow "\n  Supported Providers:"));
    List.iteri (fun i p ->
      let mark = if p = st.provider_name then green " > " else dim "   " in
      let num = cyan (Printf.sprintf "[%d]" (i + 1)) in
      println_ansi (Printf.sprintf "  %s %s%s" num mark (white p))
    ) providers;
    if is_tty then begin
      println_ansi (dim "\n  Enter a number to switch, or press Enter to cancel:");
      (try
        let input = String.trim (input_line stdin) in
        if input <> "" then
          match int_of_string_opt input with
          | Some n when n >= 1 && n <= List.length providers ->
            let new_provider = List.nth providers (n - 1) in
            st.provider_name <- new_provider;
            let provider = make_any_provider new_provider st.model st.base_url in
            st.provider <- provider;
            st.session <- Session.with_provider st.session provider;
            println_ansi (yellow (Printf.sprintf "  Switched to provider %s" new_provider))
          | _ -> println_ansi (red "  Invalid selection.")
      with End_of_file -> ())
    end

  | ["/tools"] ->
    let tools = Session.tools st.session in
    if tools = [] then println_ansi (yellow "  No tools registered.")
    else begin
      println_ansi (bold (yellow "  Available Tools:"));
      List.iter (fun p -> println_ansi (Printf.sprintf "  %s" (cyan (Tool.name_of_packed p)))) tools
    end

  | ["/config"] ->
    let cfg = Session.config st.session in
    let opts = cfg.options in
    println_ansi (bold (yellow "  Current Configuration:"));
    let p s v = println_ansi (Printf.sprintf "  %-15s %s" (blue (s^":")) (white v)) in
    p "Provider" st.provider_name;
    p "Model" st.model;
    p "URL" (Option.value ~default:"(default)" st.base_url);
    p "Memory" (string_of_int cfg.memory_size);
    p "System" (match cfg.system with Some s -> Printf.sprintf "\"%s...\"" (String.sub s 0 (min (String.length s) 30)) | None -> "(none)");
    p "Streaming" (string_of_bool (Config.get_stream ()));
    p "Spinner" (string_of_bool (Config.get_spinner_enabled ()));
    println_ansi (bold (dim "  Generation Options:"));
    let po n = function Some v -> println_ansi (Printf.sprintf "    %-13s %s" (cyan (n ^ ":")) (white v)) | None -> () in
    po "Temp" (Option.map (Printf.sprintf "%.2f") opts.temperature);
    po "Top P" (Option.map (Printf.sprintf "%.2f") opts.top_p);
    po "Top K" (Option.map string_of_int opts.top_k);
    po "Max Tokens" (Option.map string_of_int opts.max_tokens);
    po "Seed" (Option.map string_of_int opts.seed);
    if opts.stop <> [] then println_ansi (Printf.sprintf "    %-13s %s" (cyan "Stop:") (white (String.concat ", " opts.stop)))

  | "/temp"       :: rest -> update_float_opt st "/temp" "Temperature" (fun v o -> { o with temperature = Some v }) 0.0 2.0 rest
  | "/top_p"      :: rest -> update_float_opt st "/top_p" "Top P" (fun v o -> { o with top_p = Some v }) 0.0 1.0 rest
  | "/top_k"      :: rest -> update_int_opt st "/top_k" "Top K" (fun v o -> { o with top_k = Some v }) rest
  | "/max_tokens" :: rest -> update_int_opt st "/max_tokens" "Max Tokens" (fun v o -> { o with max_tokens = Some v }) rest
  | "/seed"       :: rest -> update_int_opt st "/seed" "Seed" (fun v o -> { o with seed = Some v }) rest

  | "/stop" :: rest ->
    if rest = [] then (st.session <- Session.set_options st.session (fun o -> { o with stop = [] }); println_ansi (yellow "  ✓ Stop sequences cleared"))
    else (st.session <- Session.set_options st.session (fun o -> { o with stop = rest }); println_ansi (yellow (Printf.sprintf "  ✓ Stop sequences → %s" (String.concat ", " rest))))

  | cmd :: _ ->
    if String.length cmd > 0 && cmd.[0] = '/' then
      println_ansi (red (Printf.sprintf "  Unknown command: %s  (try /help)" cmd))
    else ()

(* --- REPL Loop --- *)

let repl net clock st =
  let prompt () =
    if is_tty then begin
      let turns = List.length (Session.history st.session) in
      let status = render_status_bar
        ~provider:st.provider_name
        ~model:st.model
        ~turns
        ~tokens_in:st.total_tokens_in
        ~tokens_out:st.total_tokens_out
      in
      println_ansi (Printf.sprintf "\n%s" status);
      print_ansi (Printf.sprintf "%s " (cyan "›"))
    end else ();
    flush stdout
  in
  let rec loop () =
    prompt ();
    let line_opt =
      try Some (input_line stdin)
      with End_of_file -> None
    in
    let line = match line_opt with
      | Some l -> String.trim l
      | None -> "/quit"
    in
    if line = "" then loop ()
    else if String.length line > 0 && line.[0] = '/' then begin
      handle_slash_command net clock st line;
      loop ()
    end else begin
      if String.length line > 200 then
        println_ansi (dim "  Tip: For complex autonomous tasks, try using /agent <task>\n");
      let verbose = Config.get_spinner_verbose () in
      if is_tty && verbose then
        println_ansi (Printf.sprintf "\n%s" (bold (green "Assistant:")));
      (try
        let stream_enabled = Config.get_stream () in
        let (new_sess, result) =
          if stream_enabled then
            Session.turn_stream net clock st.session line ~on_token
          else
            Session.turn net clock st.session line
        in
        st.session <- new_sess;
        (match result.usage with
         | Some u ->
           st.total_tokens_in  <- st.total_tokens_in + u.prompt_tokens;
           st.total_tokens_out <- st.total_tokens_out + u.completion_tokens
         | None -> ());
        if not stream_enabled then
          print_ansi (green result.value.content);
        if is_tty then begin
          print_newline ();
          println_ansi (dim (Monitor.format_usage result))
        end;
        if not is_tty && not stream_enabled then print_endline result.value.content
      with exn ->
        if is_tty then print_newline ();
        println_ansi (red (Printf.sprintf "\n  [Error]: %s" (Caravan_error.humanize exn))));
      loop ()
    end
  in
  loop ()

(* --- CLI Mode Implementations --- *)

let cmd_complete net clock ~model ~provider_name ~base_url ~system prompt_text =
  init_mcp ();
  let provider = make_any_provider provider_name model base_url in
  let sess = Session.create ~tools:(all_tools ()) model provider in
  let sess = match system with Some s -> Session.set_system sess s | None -> sess in
  (try
    let stream_enabled = Config.get_stream () in
    let (_sess, result) =
      if stream_enabled then
        Session.turn_stream net clock sess prompt_text ~on_token
      else
        Session.turn net clock sess prompt_text
    in
    if not stream_enabled then
      print_ansi (green result.value.content);
    print_newline ();
    if is_tty then println_ansi (dim (Monitor.format_usage result))
  with exn ->
    Printf.eprintf "[Caravan] Error: %s\n%!" (Caravan_error.humanize exn))

let cmd_models net ~provider_name ~base_url ~model () =
  let provider = make_any_provider provider_name model base_url in
  (try
    let models = Provider.list_models_packed net provider in
    List.iter (fun m ->
      print_endline (if m = model then "> " ^ m else "  " ^ m)
    ) models
  with exn ->
    Printf.eprintf "[Caravan] Error: %s\n%!" (Caravan_error.humanize exn);
    exit 1)

(* --- CLI Configuration (Cmdliner) --- *)

let model_arg =
  let doc = "Model name to use." in
  let default = match get_string "model" with Some v -> v | None -> "gpt-oss:20b" in
  Arg.(value & opt string default & info ["m"; "model"] ~docv:"MODEL" ~doc)

let provider_arg =
  let doc = "Provider to use: 'ollama', 'openai', or 'llama_cpp'." in
  let default = match get_string "provider" with Some v -> v | None -> "ollama" in
  Arg.(value & opt string default & info ["p"; "provider"] ~docv:"PROVIDER" ~doc)

let base_url_arg =
  let doc = "Base URL for the provider API (OpenAI, llama.cpp, Ollama, etc.)." in
  let default = get_string "base_url" in
  Arg.(value & opt (some string) default
       & info ["base-url"] ~docv:"URL" ~doc)

let system_arg =
  let doc = "System prompt to use for the session or completion." in
  let default = get_string "system" in
  Arg.(value & opt (some string) default & info ["s"; "system"] ~docv:"PROMPT" ~doc)

let run_init () =
  println_ansi (bold (cyan "\n  Welcome to Caravan! Let's get you set up.\n"));
  println_ansi (bold (yellow "  Where is your AI running?"));
  println_ansi (white "  1) Ollama (local, free - recommended for beginners)");
  println_ansi (white "  2) OpenAI / GPT (cloud, requires API key)");
  println_ansi (white "  3) llama.cpp (local, advanced)");
  print_ansi (cyan "\n  Select [1-3] (default 1): ");
  flush stdout;
  let choice =
    try
      let line = String.trim (read_line ()) in
      if line = "" then "1" else line
    with End_of_file -> "1"
  in
  let provider, model, base_url, api_key_opt =
    match choice with
    | "2" ->
      print_ansi (cyan "  Enter your OpenAI API Key (starts with sk-): ");
      flush stdout;
      let key = try String.trim (read_line ()) with End_of_file -> "" in
      if key = "" || not (String.starts_with ~prefix:"sk-" key) then
        println_ansi (yellow "  Warning: Key doesn't start with sk-. Saving anyway.");
      ("openai", "gpt-4o", None, Some key)
    | "3" ->
      print_ansi (cyan "  Enter llama.cpp base URL (default http://127.0.0.1:8080/v1): ");
      flush stdout;
      let url = try String.trim (read_line ()) with End_of_file -> "" in
      let base_url = if url = "" then "http://127.0.0.1:8080/v1" else url in
      ("llama_cpp", "default", Some base_url, None)
    | _ ->
      let base_url = "http://127.0.0.1:11434/v1" in
      let selected_model = ref "llama3.2" in
      Eio_main.run (fun env ->
        try
          let provider = make_any_provider "ollama" "llama3.2" (Some base_url) in
          let models = Provider.list_models_packed env#net provider in
          if models <> [] then begin
            println_ansi (green "\n  Connected to Ollama! Found models:");
            List.iteri (fun i m ->
              println_ansi (Printf.sprintf "  %s %s" (cyan (Printf.sprintf "[%d]" (i + 1))) (white m))
            ) models;
            print_ansi (cyan (Printf.sprintf "\n  Select model [1-%d] (default 1): " (List.length models)));
            flush stdout;
            try
              let sel = String.trim (read_line ()) in
              if sel <> "" then
                match int_of_string_opt sel with
                | Some n when n >= 1 && n <= List.length models ->
                  selected_model := List.nth models (n - 1)
                | _ -> ()
              else selected_model := List.hd models
            with End_of_file -> selected_model := List.hd models
          end else ()
        with exn ->
          println_ansi (yellow "\n  Could not connect to Ollama at http://127.0.0.1:11434/v1");
          println_ansi (dim "  Make sure Ollama is installed and running: https://ollama.com")
      );
      ("ollama", !selected_model, Some base_url, None)
  in
  let config_dir = Filename.dirname Config.config_path in
  if not (Sys.file_exists config_dir) then (try Unix.mkdir config_dir 0o755 with _ -> ());
  let oc = open_out Config.config_path in
  Printf.fprintf oc "# Generated by caravan init\n";
  Printf.fprintf oc "provider = \"%s\"\n" provider;
  Printf.fprintf oc "model = \"%s\"\n" model;
  (match base_url with Some u -> Printf.fprintf oc "base_url = \"%s\"\n" u | None -> ());
  (match api_key_opt with Some k -> Printf.fprintf oc "openai_api_key = \"%s\"\n" k | None -> ());
  Printf.fprintf oc "stream = true\n";
  close_out oc;
  println_ansi (green (Printf.sprintf "\n  ✓ Saved configuration to %s" Config.config_path));
  println_ansi (dim "  Run 'caravan' to start chatting!\n")

let init_cmd =
  let doc = "Interactive first-run setup wizard." in
  let info = Cmd.info "init" ~doc in
  Cmd.v info Term.(const run_init $ const ())

let run_doctor () =
  println_ansi (bold (cyan "\n  Caravan System Diagnostics\n"));
  let checks_passed = ref true in

  if Sys.file_exists Config.config_path then begin
    (match Config.load_toml () with
     | Some _ -> println_ansi (green "  ✓ Config file exists and valid TOML")
     | None ->
       checks_passed := false;
       println_ansi (red (Printf.sprintf "  ✗ Config file at %s contains TOML syntax errors" Config.config_path)))
  end else begin
    checks_passed := false;
    println_ansi (yellow (Printf.sprintf "  ⚠ Config file does not exist at %s (run 'caravan init')" Config.config_path))
  end;

  let provider_name = Config.get_string_opt (Some "CARAVAN_PROVIDER") "provider" |> Option.value ~default:"ollama" in
  let model = Config.get_string_opt (Some "CARAVAN_MODEL") "model" |> Option.value ~default:"llama3.2" in
  let base_url = Config.get_string_opt (Some "CARAVAN_BASE_URL") "base_url" in
  if List.mem provider_name ["ollama"; "openai"; "llama_cpp"] then
    println_ansi (green (Printf.sprintf "  ✓ Provider '%s' is supported" provider_name))
  else begin
    checks_passed := false;
    println_ansi (red (Printf.sprintf "  ✗ Provider '%s' is unknown. Supported: ollama, openai, llama_cpp" provider_name))
  end;

  (match provider_name with
   | "openai" ->
     let key_opt = match Sys.getenv_opt "OPENAI_API_KEY" with
       | Some k when k <> "" -> Some k
       | _ -> Config.get_string "openai_api_key"
     in
     (match key_opt with
      | Some _ -> println_ansi (green "  ✓ OpenAI API key configured")
      | None ->
        checks_passed := false;
        println_ansi (red "  ✗ OpenAI API key missing. Set OPENAI_API_KEY env var or api_key in config.toml"))
   | "ollama" | "llama_cpp" ->
     let default_url = if provider_name = "ollama" then "http://127.0.0.1:11434/v1" else "http://127.0.0.1:8080/v1" in
     let url = Option.value ~default:default_url base_url in
     Eio_main.run (fun env ->
       try
         let p = make_any_provider provider_name model base_url in
         let models = Provider.list_models_packed env#net p in
         println_ansi (green (Printf.sprintf "  ✓ %s endpoint reachable at %s (%d models)" provider_name url (List.length models)))
       with exn ->
         checks_passed := false;
         println_ansi (red (Printf.sprintf "  ✗ Could not connect to %s at %s\n    Hint: %s" provider_name url (Caravan_error.humanize exn)))
     )
   | _ -> ());

  let mcp_servers = Config.get_mcp_servers () in
  if mcp_servers <> [] then begin
    List.iter (fun (srv : Config.mcp_server_config) ->
      let cmd_ok = Sys.command (Printf.sprintf "which %s >/dev/null 2>&1" (Filename.quote srv.command)) = 0 in
      if cmd_ok then
        println_ansi (green (Printf.sprintf "  ✓ MCP server '%s' command '%s' found in PATH" srv.name srv.command))
      else begin
        checks_passed := false;
        println_ansi (red (Printf.sprintf "  ✗ MCP server '%s' command '%s' not found in PATH" srv.name srv.command))
      end
    ) mcp_servers
  end;

  print_newline ();
  if !checks_passed then
    println_ansi (bold (green "  All diagnostics passed! Caravan is ready.\n"))
  else
    println_ansi (bold (yellow "  Some issues were detected. Check hints above.\n"))

let doctor_cmd =
  let doc = "Run system and configuration diagnostics." in
  let info = Cmd.info "doctor" ~doc in
  Cmd.v info Term.(const run_doctor $ const ())

let run_repl model provider_name base_url system =
  init_mcp ();
  if is_tty && Config.is_first_run () then begin
    println_ansi (yellow "  Notice: First time running Caravan? Run 'caravan init' for guided setup.\n")
  end;
  Eio_main.run (fun env ->
    let net = env#net in
    let provider = make_any_provider provider_name model base_url in
    let sess = Session.create ~tools:(all_tools ()) model provider in
    let sess = match system with Some s -> Session.set_system sess s | None -> sess in
    let st = {
      session          = sess;
      provider_name;
      model;
      provider;
      base_url;
      total_tokens_in  = 0;
      total_tokens_out = 0;
    } in
    print_banner ();
    if is_tty then begin
      println_ansi (dim "  Just type a message and press Enter to chat.");
      println_ansi (dim "  Try " ^ cyan "/help" ^ dim " for commands, or " ^
                    cyan "/agent <task>" ^ dim " to let the AI work autonomously.");
      println_ansi (Printf.sprintf "  %s %s   %s %s"
        (dim "Using") (bold (white model))
        (dim "on") (bold (white provider_name)));
      print_newline ()
    end;
    repl net env#clock st
  )

let repl_cmd =
  let doc = "Start an interactive chat session (default command)." in
  let info = Cmd.info "repl" ~doc in
  Cmd.v info Term.(const run_repl $ model_arg $ provider_arg $ base_url_arg $ system_arg)

let complete_cmd =
  let prompt_arg =
    let doc = "The prompt text to send." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"PROMPT" ~doc)
  in
  let run model provider_name base_url system prompt =
    Eio_main.run (fun env ->
      cmd_complete env#net env#clock ~model ~provider_name ~base_url ~system prompt
    )
  in
  let doc = "Send a single prompt and print the response." in
  let info = Cmd.info "complete" ~doc in
  Cmd.v info Term.(const run $ model_arg $ provider_arg $ base_url_arg $ system_arg $ prompt_arg)

let models_cmd =
  let run model provider_name base_url =
    Eio_main.run (fun env ->
      cmd_models env#net ~provider_name ~base_url ~model ()
    )
  in
  let doc = "List available models for the chosen provider." in
  let info = Cmd.info "models" ~doc in
  Cmd.v info Term.(const run $ model_arg $ provider_arg $ base_url_arg)

(* --- Entry Point --- *)

let () =
  let doc = "Typed LLM orchestration framework and interactive REPL." in
  let info = Cmd.info "caravan"
    ~doc
    ~version:"0.1.0"
  in
  let default_cmd = Term.(const run_repl $ model_arg $ provider_arg $ base_url_arg $ system_arg)
  in
  let cmd = Cmd.group ~default:default_cmd info
    [ repl_cmd; complete_cmd; models_cmd; init_cmd; doctor_cmd ]
  in
  exit (Cmd.eval cmd)
