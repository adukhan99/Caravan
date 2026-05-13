(** Interactive TUI / REPL entry point. *)

open OrchCaml
open OrchCaml.Types
open OrchCaml.Config
open Ui
open Cmdliner

(* --- Types --- *)

type repl_state = {
  mutable session       : Session.t;
  mutable provider_name : string;
  mutable model         : string;
  mutable provider      : Provider.packed_provider;
  mutable base_url      : string option;
}

(* --- Constants & Environment --- *)

let all_tools : OrchCaml.Tool.packed_tool list = 
  let base = OrchCamlTools.All_tools.all_tools in
  let strict_mode = 
    OrchCaml.Config.get_int_opt (Some "ORCHCAML_STRICT_MODE") "strict_mode"
    |> Option.value ~default:1
  in
  if strict_mode = 2 then
    List.filter (fun t -> OrchCaml.Tool.name_of_packed t <> "bash") base
  else base

let slash_commands = [
  "/model <name>",    "Switch the model";
  "/provider <p> [u]", "Switch provider (ollama, openai, llama_cpp)";
  "/system [text]",   "Set or clear the system prompt";
  "/agent <task>",    "Start an autonomous agentic loop";
  "/memory <n>",      "Set context window (0 = max)";
  "/clear",           "Clear conversation history";
  "/history",         "Print conversation history";
  "/export [file]",   "Export session JSON to stdout or file";
  "/models",          "List available models";
  "/providers",       "List available providers";
  "/tools",           "List available tools";
  "/config",          "Show current session configuration";
  "/temp <f>",        "Set temperature (0.0-2.0)";
  "/top_p <f>",       "Set top_p (0.0-1.0)";
  "/top_k <n>",       "Set top_k";
  "/max_tokens <n>",  "Set max output tokens";
  "/seed <n>",        "Set random seed";
  "/help",            "Show this help";
  "/quit",            "Exit OrchCaml";
]

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
      OrchCaml.Config.get_int_opt (Some "ORCHCAML_STRICT_MODE") "strict_mode"
      |> Option.value ~default:1
    in
    if strict_mode = 2 then
      List.filter (fun (name, _) -> name <> "bash") all
    else all
  else []

let make_any_provider name model base_url =
  let factories = [
    ("openai",    fun ~base_url ~model -> OrchCamlProviders.Openai.make_provider ?base_url ~model ());
    ("llama_cpp", fun ~base_url ~model -> OrchCamlProviders.Llama_cpp.make_provider ?base_url ~model ());
    ("ollama",    fun ~base_url ~model -> OrchCamlProviders.Ollama.make_provider ?base_url ~model ());
  ] in
  let maker = List.assoc_opt name factories |> Option.value ~default:(List.assoc "ollama" factories) in
  maker ~base_url ~model

let rebuild_session st =
  let provider = make_any_provider st.provider_name st.model st.base_url in
  st.provider <- provider;
  st.session  <- Session.create ~tools:all_tools st.model provider

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

let handle_slash_command net st line =
  let parts = String.split_on_char ' ' (String.trim line) |> List.filter (fun s -> s <> "") in
  match parts with
  | [] -> ()

  | ["/quit"] | ["/exit"] | ["/q"] ->
    println_ansi (dim "\nGoodbye.");
    exit 0

  | ["/help"] | ["/?"] ->
    print_help slash_commands

  | "/agent" :: rest ->
    let task = String.concat " " rest |> String.trim in
    if task = "" then usage "/agent" "<task description>"
    else begin
      println_ansi (bold (yellow (Printf.sprintf "\n  Starting agentic loop for: %s" task)));
      (try
        let result = Agent.run_stream net st.session task ~on_token in
        match result with
        | Ok (new_sess, res) ->
          st.session <- new_sess;
          print_newline ();
          println_ansi (bold (green "  ✓ Agent complete."));
          println_ansi (dim (Monitor.format_usage res))
        | Error e ->
          println_ansi (red (Printf.sprintf "  [Agent Error]: %s" e))
      with exn ->
        println_ansi (red (Printf.sprintf "  [Error]: %s" (Printexc.to_string exn))))
    end

  | "/model" :: rest ->
    (match rest with
     | [new_model] ->
       st.model <- new_model;
       st.session <- Session.with_model st.session new_model;
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
       with exn -> println_ansi (red (Printf.sprintf "  Error: %s" (Printexc.to_string exn))))
     | [] -> print_endline (Yojson.Safe.pretty_to_string (Session.export_json st.session))
     | _ -> usage "/export" "[file]")

  | ["/models"] ->
    (try
      let models = Provider.list_models_packed net st.provider in
      println_ansi (bold (yellow (Printf.sprintf "  Models on %s:" st.provider_name)));
      List.iter (fun m ->
        let mark = if m = st.model then green " ✓ " else dim "   " in
        println_ansi (mark ^ white m)
      ) models
    with exn -> println_ansi (red (Printf.sprintf "  Error: %s" (Printexc.to_string exn))))

  | ["/providers"] ->
    println_ansi (bold (yellow "  Supported Providers:"));
    List.iter (fun s -> println_ansi (Printf.sprintf "  - %s" s)) ["openai"; "ollama"; "llama_cpp"]

  | ["/tools"] ->
    let tools = st.session.tools in
    if tools = [] then println_ansi (yellow "  No tools registered.")
    else begin
      println_ansi (bold (yellow "  Available Tools:"));
      List.iter (fun p -> println_ansi (Printf.sprintf "  %s" (cyan (Tool.name_of_packed p)))) tools
    end

  | ["/config"] ->
    let cfg = st.session.cfg in
    let opts = cfg.options in
    println_ansi (bold (yellow "  Current Configuration:"));
    let p s v = println_ansi (Printf.sprintf "  %-15s %s" (blue (s^":")) (white v)) in
    p "Provider" st.provider_name;
    p "Model" st.model;
    p "URL" (Option.value ~default:"(default)" st.base_url);
    p "Memory" (string_of_int cfg.memory_size);
    p "System" (match cfg.system with Some s -> Printf.sprintf "\"%s...\"" (String.sub s 0 (min (String.length s) 30)) | None -> "(none)");
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

let repl net st =
  let prompt () =
    if is_tty then
      print_ansi (Printf.sprintf "\n%s %s %s "
        (blue (Printf.sprintf "[%s/%s]" st.provider_name st.model))
        (cyan "›")
        "")
    else ();
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
      handle_slash_command net st line;
      loop ()
    end else begin
      if is_tty then
        println_ansi (Printf.sprintf "\n%s" (bold (green "Assistant:")));
      (try
        let (new_sess, result) = Session.turn_stream net st.session line ~on_token in
        st.session <- new_sess;
        if is_tty then begin
          print_newline ();
          println_ansi (dim (Monitor.format_usage result))
        end;
        if not is_tty then print_endline result.value.content
      with exn ->
        if is_tty then print_newline ();
        let msg = match exn with
          | Failure s -> s
          | _ -> Printexc.to_string exn
        in
        println_ansi (red (Printf.sprintf "\n  [Error]: %s" msg)));
      loop ()
    end
  in
  loop ()

(* --- CLI Mode Implementations --- *)

let cmd_complete net ~model ~provider_name ~base_url ~system prompt_text =
  let provider = make_any_provider provider_name model base_url in
  let sess = Session.create ~tools:all_tools model provider in
  let sess = match system with Some s -> Session.set_system sess s | None -> sess in
  (try
    let (_sess, result) = Session.turn_stream net sess prompt_text ~on_token in
    print_newline ();
    if is_tty then println_ansi (dim (Monitor.format_usage result))
  with exn ->
    Printf.eprintf "[OrchCaml] Error: %s\n%!" (Printexc.to_string exn))

let cmd_models net ~provider_name ~base_url ~model () =
  let provider = make_any_provider provider_name model base_url in
  (try
    let models = Provider.list_models_packed net provider in
    List.iter (fun m ->
      print_endline (if m = model then "> " ^ m else "  " ^ m)
    ) models
  with exn ->
    let msg = match exn with
      | Failure s -> s
      | _ -> Printexc.to_string exn
    in
    Printf.eprintf "[OrchCaml] Error: %s\n%!" msg;
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

let run_repl model provider_name base_url system =
  Eio_main.run (fun env ->
    let net = env#net in
    let provider = make_any_provider provider_name model base_url in
    let sess = Session.create ~tools:all_tools model provider in
    let sess = match system with Some s -> Session.set_system sess s | None -> sess in
    let st = {
      session      = sess;
      provider_name;
      model;
      provider;
      base_url;
    } in
    print_banner ();
    if is_tty then begin
      println_ansi (Printf.sprintf "  %s %s  %s %s"
        (bold (blue "Provider:")) (white provider_name)
        (bold (blue "Model:"))    (white model));
      (match system with
       | Some s -> println_ansi (Printf.sprintf "  %s %s"
                     (bold (yellow "System:")) (dim s))
       | None -> ());
      println_ansi (dim "  Type a message and press Enter. Use /help for commands.");
      print_newline ()
    end;
    repl net st
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
      cmd_complete env#net ~model ~provider_name ~base_url ~system prompt
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
  let info = Cmd.info "orchcaml"
    ~doc
    ~version:"0.1.0"
  in
  let default_cmd = Term.(const run_repl $ model_arg $ provider_arg $ base_url_arg $ system_arg)
  in
  let cmd = Cmd.group ~default:default_cmd info
    [ repl_cmd; complete_cmd; models_cmd ]
  in
  exit (Cmd.eval cmd)
