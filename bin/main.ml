(** Interactive TUI / REPL entry point. *)

open OrchCaml
open OrchCaml.Types
open OrchCaml.Config

let ansi code s = Printf.sprintf "\027[%sm%s\027[0m" code s
let bold s    = ansi "1" s
let dim s     = ansi "2" s
let cyan s    = ansi "1;36" s
let green s   = ansi "1;32" s
let yellow s  = ansi "1;33" s
let magenta s = ansi "1;35" s
let red s     = ansi "1;31" s
let white s   = ansi "0;97" s
let blue s    = ansi "0;34" s

let is_tty = Unix.isatty Unix.stdout

let print_ansi s = if is_tty then print_string s else
  let re = Re.compile (Re.seq [
    Re.char '\027'; Re.char '[';
    Re.rep (Re.compl [Re.char 'm']); Re.char 'm'
  ]) in
  print_string (Re.replace_string re ~by:"" s)

let println_ansi s = print_ansi s; print_char '\n'

let print_banner () =
  if is_tty then begin
    println_ansi (cyan "╔═════════════════════════════════════════════════╗");
    println_ansi (cyan "║  " ^ bold (white "OrchCaml") ^ white "  v0.1  —  Typed LLM Orchestration     " ^ cyan "║");
    println_ansi (cyan "╚═════════════════════════════════════════════════╝");
    print_newline ()
  end

let get_available_tools () =
  let tools_dir = "lib/tools" in
  if Sys.file_exists tools_dir && Sys.is_directory tools_dir then
    let files = Array.to_list (Sys.readdir tools_dir) in
    let ml_files = List.filter (fun f -> Filename.check_suffix f ".ml") files in
    let desc_re = Re.compile (Re.seq [
      Re.str "let description"; Re.rep Re.space; Re.char '='; Re.rep Re.space;
      Re.char '"'; Re.group (Re.rep (Re.compl [Re.char '"'])); Re.char '"'
    ]) in
    List.map (fun f ->
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
    ) ml_files
  else []

let print_help () =
  println_ansi (bold (yellow " Slash Commands:"));
  let cmds = [
    "/model <name>",    "Switch the model";
    "/system <text>",   "Set the system prompt";
    "/nosystem",        "Clear the system prompt";
    "/memory <n>",      "Set context window (0 = max)";
    "/clear",           "Clear conversation history";
    "/history",         "Print conversation history";
    "/export [file]",   "Export session JSON to stdout or file";
    "/models",          "List available models";
    "/tools",           "List available tools";
    "/provider",        "Show current provider info";
    "/temp <0.0-2.0>",  "Set temperature";
    "/help",            "Show this help";
    "/quit  or  /exit", "Exit OrchCaml";
  ] in
  List.iter (fun (cmd, desc) ->
    println_ansi (Printf.sprintf "  %s  %s"
      (cyan (Printf.sprintf "%-22s" cmd))
      (dim desc))
  ) cmds;
  print_newline ()

let make_ollama_provider model =
  OrchCamlProviders.Ollama.make_provider ~model ()

let make_openai_provider ?base_url model =
  OrchCamlProviders.Openai.make_provider ?base_url ~model ()

type repl_state = {
  mutable session  : Session.t;
  mutable provider_name : string;
  mutable model    : string;
  mutable provider : Provider.packed_provider;
  mutable use_openai : bool;
  mutable openai_base : string;
}

let all_tools : OrchCaml.Tool.packed_tool list = [
  Tool (module OrchCamlTools.Grep.Grep);
  Tool (module OrchCamlTools.Ls.Ls);
  Tool (module OrchCamlTools.Mkdir.Mkdir);
  Tool (module OrchCamlTools.Read_file.Read_file);
  Tool (module OrchCamlTools.Search.Search);
  Tool (module OrchCamlTools.Sed.Sed);
  Tool (module OrchCamlTools.Touch.Touch);
  Tool (module OrchCamlTools.Write_file.Write_file);
]

let rebuild_session st =
  let provider =
    if st.use_openai then
      make_openai_provider ~base_url:st.openai_base st.model
    else
      make_ollama_provider st.model
  in
  st.provider <- provider;
  st.session  <- Session.create ~tools:all_tools st.model provider

let on_token token =
  print_ansi (green token);
  flush stdout

let handle_slash_command net st line =
  let parts = String.split_on_char ' ' (String.trim line) in
  match parts with
  | ["/quit"] | ["/exit"] | ["/q"] ->
    println_ansi (dim "\nGoodbye.");
    exit 0

  | ["/help"] | ["/?"] ->
    print_help ()

  | "/model" :: rest ->
    let new_model = String.concat " " rest |> String.trim in
    if new_model = "" then
      println_ansi (red "Usage: /model <model-name>")
    else begin
      st.model <- new_model;
      rebuild_session st;
      println_ansi (yellow (Printf.sprintf "  ✓ Model → %s" new_model))
    end

  | "/system" :: rest ->
    let text = String.concat " " rest |> String.trim in
    if text = "" then
      println_ansi (red "Usage: /system <prompt text>")
    else begin
      st.session <- Session.set_system st.session text;
      println_ansi (yellow (Printf.sprintf "  ✓ System prompt set (%d chars)" (String.length text)))
    end

  | ["/nosystem"] ->
    st.session <- Session.set_system st.session "";
    println_ansi (yellow "  ✓ System prompt cleared")

  | "/memory" :: [n_str] ->
    (match int_of_string_opt n_str with
     | None   -> println_ansi (red "Usage: /memory <n>  (integer)")
     | Some n ->
       let window = if n = 0 then max_int else n in
       st.session <- Session.create ~tools:all_tools
         ~config:(fun m -> { (Session.default_config m) with memory_size = window })
         st.model st.provider;
       println_ansi (yellow (Printf.sprintf "  ✓ Memory window → %s"
         (if n = 0 then "unlimited" else string_of_int n))))

  | ["/clear"] ->
    st.session <- Session.clear st.session;
    println_ansi (yellow "  ✓ History cleared")

  | ["/history"] ->
    let hist = Session.history st.session in
    if hist = [] then
      println_ansi (dim "  (empty history)")
    else
      List.iter (fun msg ->
        let role_str = role_to_string msg.role in
        let colour = match msg.role with
          | System    -> yellow
          | User      -> cyan
          | Assistant -> green
          | Tool _    -> magenta
        in
        println_ansi (Printf.sprintf "%s: %s"
          (bold (colour role_str))
          (dim msg.content))
      ) hist

  | "/export" :: rest ->
    let json = Session.export_json st.session in
    let json_str = Yojson.Safe.pretty_to_string json in
    (match rest with
     | [file] ->
       let oc = open_out file in
       output_string oc json_str;
       close_out oc;
       println_ansi (yellow (Printf.sprintf "  ✓ Exported to %s" file))
     | _ ->
       print_endline json_str)

  | ["/models"] ->
    (try
      let models = Provider.list_models_packed net st.provider in
      println_ansi (bold (yellow (Printf.sprintf "  Models on %s:" st.provider_name)));
      List.iter (fun m ->
        let mark = if m = st.model then green " ✓ " else dim "   " in
        println_ansi (mark ^ white m)
      ) models
    with exn ->
      let msg = match exn with
        | Failure s -> s
        | _ -> Printexc.to_string exn
      in
      println_ansi (red (Printf.sprintf "  Error: %s" msg)))

  | ["/tools"] ->
    let tools = get_available_tools () in
    if tools = [] then
      println_ansi (yellow "  No tools found loosely in lib/tools/")
    else begin
      println_ansi (bold (yellow "  Available Tools:"));
      List.iter (fun (name, desc) ->
        println_ansi (Printf.sprintf "  %s  %s" 
          (cyan (Printf.sprintf "%-15s" name))
          (dim desc))
      ) tools
    end

  | ["/provider"] ->
    println_ansi (Printf.sprintf "  %s  %s  %s"
      (bold (blue "Provider:")) (white st.provider_name)
      (dim ("model=" ^ st.model)))

  | "/temp" :: [v_str] ->
    (match float_of_string_opt v_str with
     | None -> println_ansi (red "Usage: /temp <float 0.0-2.0>")
     | Some temp ->
       st.session <- Session.create ~tools:all_tools
         ~config:(fun m -> { (Session.default_config m) with options = { (Session.default_config m).options with temperature = Some temp } })
         st.model st.provider;
       println_ansi (yellow (Printf.sprintf "  ✓ Temperature → %.2f" temp)))

  | cmd :: _ ->
    println_ansi (red (Printf.sprintf "  Unknown command: %s  (try /help)" cmd))

  | [] -> ()

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

let cmd_complete net ~model ~use_openai ~openai_base ~system prompt_text =
  let provider =
    if use_openai then make_openai_provider ~base_url:openai_base model
    else make_ollama_provider model
  in
  let sess = Session.create ~tools:all_tools model provider in
  let sess = match system with Some s -> Session.set_system sess s | None -> sess in
  (try
    let (_sess, result) = Session.turn_stream net sess prompt_text ~on_token in
    print_newline ();
    if is_tty then println_ansi (dim (Monitor.format_usage result))
  with exn ->
    Printf.eprintf "[OrchCaml] Error: %s\n%!" (Printexc.to_string exn))

let cmd_models net ~use_openai ~openai_base ~model () =
  let provider =
    if use_openai then make_openai_provider ~base_url:openai_base model
    else make_ollama_provider model
  in
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

open Cmdliner

let model_arg =
  let doc = "Model name to use." in
  let default = match get_string "model" with Some v -> v | None -> "gpt-oss:20b" in
  Arg.(value & opt string default & info ["m"; "model"] ~docv:"MODEL" ~doc)

let provider_arg =
  let doc = "Provider to use: 'ollama' or 'openai'." in
  let default = match get_string "provider" with Some v -> v | None -> "ollama" in
  Arg.(value & opt string default & info ["p"; "provider"] ~docv:"PROVIDER" ~doc)

let openai_base_arg =
  let doc = "Base URL for OpenAI-compatible API." in
  let default = match get_string "base_url" with Some v -> v | None -> "https://api.openai.com/v1" in
  Arg.(value & opt string default
       & info ["base-url"] ~docv:"URL" ~doc)

let system_arg =
  let doc = "System prompt to use for the session or completion." in
  let default = get_string "system" in
  Arg.(value & opt (some string) default & info ["s"; "system"] ~docv:"PROMPT" ~doc)

let run_repl model provider_str openai_base system =
  let use_openai = provider_str = "openai" in
  let provider_name = provider_str in
  Eio_main.run (fun env ->
    let net = env#net in
    let provider =
      if use_openai then make_openai_provider ~base_url:openai_base model
      else make_ollama_provider model
    in
    let sess = Session.create ~tools:all_tools model provider in
    let sess = match system with Some s -> Session.set_system sess s | None -> sess in
    let st = {
      session      = sess;
      provider_name;
      model;
      provider;
      use_openai;
      openai_base;
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
  Cmd.v info Term.(const run_repl $ model_arg $ provider_arg $ openai_base_arg $ system_arg)

let complete_cmd =
  let prompt_arg =
    let doc = "The prompt text to send." in
    Arg.(required & pos 0 (some string) None & info [] ~docv:"PROMPT" ~doc)
  in
  let run model provider_str openai_base system prompt =
    let use_openai = provider_str = "openai" in
    Eio_main.run (fun env ->
      cmd_complete env#net ~model ~use_openai ~openai_base ~system prompt
    )
  in
  let doc = "Send a single prompt and print the response." in
  let info = Cmd.info "complete" ~doc in
  Cmd.v info Term.(const run $ model_arg $ provider_arg $ openai_base_arg $ system_arg $ prompt_arg)

let models_cmd =
  let run model provider_str openai_base =
    let use_openai = provider_str = "openai" in
    Eio_main.run (fun env ->
      cmd_models env#net ~use_openai ~openai_base ~model ()
    )
  in
  let doc = "List available models for the chosen provider." in
  let info = Cmd.info "models" ~doc in
  Cmd.v info Term.(const run $ model_arg $ provider_arg $ openai_base_arg)

let () =
  let doc = "Typed LLM orchestration framework and interactive REPL." in
  let info = Cmd.info "orchcaml"
    ~doc
    ~version:"0.1.0"
  in
  let default_cmd = Term.(const run_repl $ model_arg $ provider_arg $ openai_base_arg $ system_arg)
  in
  let cmd = Cmd.group ~default:default_cmd info
    [ repl_cmd; complete_cmd; models_cmd ]
  in
  exit (Cmd.eval cmd)
