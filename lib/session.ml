(** Stateful multi-turn conversation sessions. *)

open Types

type config = {
  model       : string;
  system      : string option;
  options     : gen_options;
  memory_size : int;
}

let default_config model = {
  model;
  system      = None;
  options     = default_options;
  memory_size = 40;
}

type t = {
  cfg      : config;
  provider : Provider.packed_provider;
  memory   : Memory.packed_memory;
  turn_idx : int;
  tools    : Tool.packed_tool list;
}

let create ?(config = fun m -> default_config m) ?(tools=[]) model provider =
  let cfg = config model in
  let window = if cfg.memory_size = 0 then max_int else cfg.memory_size in
  {
    cfg;
    provider;
    memory = Memory.Mem ((module Memory.Ring), Memory.Ring.make ~window ());
    turn_idx = 0;
    tools;
  }

let set_system sess text =
  let cfg =
    if String.trim text = "" then
      { sess.cfg with system = None }
    else
      { sess.cfg with system = Some text }
  in
  { sess with cfg }

let set_memory_size sess n =
  let cfg = { sess.cfg with memory_size = n } in
  let Memory.Mem ((module M), mem) = sess.memory in
  let memory = Memory.Mem ((module M), M.set_window mem n) in
  { sess with cfg; memory }

let set_options sess f =
  let cfg = { sess.cfg with options = f sess.cfg.options } in
  { sess with cfg }

let clear sess =
  let Memory.Mem ((module M), mem) = sess.memory in
  { sess with memory = Memory.Mem ((module M), M.clear mem); turn_idx = 0 }

let add_messages sess msgs =
  let Memory.Mem ((module M), mem) = sess.memory in
  let final_mem = List.fold_left M.add mem msgs in
  { sess with memory = Memory.Mem ((module M), final_mem) }

let with_provider sess provider =
  { sess with provider }

let config sess = sess.cfg
let provider sess = sess.provider
let tools sess = sess.tools

let with_model sess model =
  { sess with cfg = { sess.cfg with model } }

let history sess =
  let Memory.Mem ((module M), mem) = sess.memory in
  M.get mem

let history_for_llm sess =
  let Memory.Mem ((module M), mem) = sess.memory in
  let hist = M.get mem in
  match sess.cfg.system with
  | None     -> hist
  | Some sys ->
    let sm = system_msg sys in
    (match hist with
     | { role = System; _ } :: _ -> hist
     | rest -> sm :: rest)

let execute_tool_calls net clock sess tcs =
  let verbose = Config.get_spinner_verbose () in
  List.map (fun tc ->
    match Tool.find_tool sess.tools tc.name with
    | None ->
      let msg = Printf.sprintf "Tool '%s' not found in registered tools." tc.name in
      Printf.eprintf "%s: %s → %s\n%!" (Ui.magenta "[Tool]") tc.name (Ui.red "NOT FOUND");
      tool_msg tc.id msg
    | Some packed ->
      if verbose then
        Printf.eprintf "%s: %s(%s)\n%!" (Ui.magenta "[Tool]") (Ui.bold tc.name) (Ui.dim tc.args);
      let verb = Config.pick_verb (Config.get_verbs tc.name) in
      let enabled = Config.get_spinner_enabled () in
      let output_str = Ui.with_spinner clock verb enabled (fun () -> Tool.dispatch packed tc.args) in
      if verbose then begin
        if tc.name = "finish" then
          Ui.println_ansi (Ui.bold (Ui.green output_str))
        else
          Printf.eprintf "%s: %s\n%!" (Ui.dim "[Tool Result]") (Ui.dim output_str)
      end else if tc.name = "finish" then
        Ui.println_ansi (Ui.bold (Ui.green output_str));
      tool_msg tc.id output_str
  ) tcs

type step_outcome =
  | Continue of t
  | Done     of t * string

let run_turn_step net clock sess (reply : chat_message) =
  let Memory.Mem ((module M), mem) = sess.memory in
  let final_memory = Memory.Mem ((module M), M.add mem reply) in
  let new_sess = { sess with memory = final_memory; turn_idx = sess.turn_idx + 1 } in
  match reply.tool_calls with
  | Some tcs when tcs <> [] ->
    let tool_responses = execute_tool_calls net clock new_sess tcs in
    let memory_with_tools =
      List.fold_left (fun (Memory.Mem ((module M2), m2)) r -> Memory.Mem ((module M2), M2.add m2 r)) new_sess.memory tool_responses
    in
    let has_finish = List.exists (fun tc -> tc.name = "finish") tcs in
    if has_finish then
      let finish_tool_call = List.find (fun tc -> tc.name = "finish") tcs in
      let finish_output =
        match List.find_opt (fun (m : chat_message) ->
          match m.role with Tool id -> id = finish_tool_call.id | _ -> false
        ) tool_responses with
        | Some m -> m.content
        | None -> ""
      in
      let final_content =
        if reply.content = "" then finish_output
        else reply.content ^ "\n\n" ^ finish_output
      in
      Done ({ new_sess with memory = memory_with_tools }, final_content)
    else
      Continue { new_sess with memory = memory_with_tools }
  | _ ->
    Done (new_sess, reply.content)

let rec run_conversations net clock sess =
  let verb = Config.pick_verb (Config.get_verbs "thinking") in
  let enabled = Config.get_spinner_enabled () in
  let verbose = Config.get_spinner_verbose () in
  let result = Ui.with_spinner clock verb enabled (fun () ->
    Provider.complete_packed net ~model:sess.cfg.model ~options:sess.cfg.options ~tools:sess.tools sess.provider (history_for_llm sess)
  ) in
  if not verbose then
    Ui.println_ansi (Printf.sprintf "\n%s" (Ui.bold (Ui.green "Assistant:")));
  let outcome = run_turn_step net clock sess result.value in
  match outcome with
  | Continue sess' -> run_conversations net clock sess'
  | Done (sess', content) ->
      (sess', { result with value = { result.value with content }; turn_count = Some sess'.turn_idx })

let turn net clock sess user_input =
  let user = user_msg user_input in
  let Memory.Mem ((module M), mem) = sess.memory in
  let sess' = { sess with memory = Memory.Mem ((module M), M.add mem user) } in
  run_conversations net clock sess'

let rec run_conversations_stream net clock sess ~on_token =
  let verb = Config.pick_verb (Config.get_verbs "thinking") in
  let enabled = Config.get_spinner_enabled () in
  let verbose = Config.get_spinner_verbose () in
  let result_with_meta =
    Eio.Switch.run (fun sw ->
      let promise, resolver = Eio.Promise.create () in
      Ui.run_spinner_until_promise sw clock verb enabled promise;
      let first_token = ref true in
      let wrapped_on_token token =
        if !first_token then begin
          first_token := false;
          Eio.Promise.resolve resolver ();
          if not verbose then
            Ui.println_ansi (Printf.sprintf "\n%s" (Ui.bold (Ui.green "Assistant:")));
        end;
        on_token token
      in
      Fun.protect
        ~finally:(fun () -> if not (Eio.Promise.is_resolved promise) then Eio.Promise.resolve resolver ())
        (fun () -> Provider.stream_packed net ~model:sess.cfg.model ~options:sess.cfg.options ~tools:sess.tools ~on_token:wrapped_on_token sess.provider (history_for_llm sess))
    )
  in
  let outcome = run_turn_step net clock sess result_with_meta.value in
  match outcome with
  | Continue sess' -> run_conversations_stream net clock sess' ~on_token
  | Done (sess', content) ->
      (sess', { result_with_meta with value = { result_with_meta.value with content }; turn_count = Some sess'.turn_idx })

let turn_stream net clock sess user_input ~on_token =
  let user = user_msg user_input in
  let Memory.Mem ((module M), mem) = sess.memory in
  let sess' = { sess with memory = Memory.Mem ((module M), M.add mem user) } in
  run_conversations_stream net clock sess' ~on_token

let summarise net clock sess =
  let hist = history sess in
  if hist = [] then
    (sess, "Conversation history is empty; nothing to summarize.")
  else
    let format_history msgs =
      String.concat "\n"
        (List.map (fun m ->
           Printf.sprintf "[%s]: %s" (role_to_string m.role) m.content) msgs)
    in
    let prompt =
      "Please provide a highly concise summary of the following conversation history. " ^
      "Focus on preserving key details, facts, contexts, and instructions. " ^
      "Write ONLY the plain-text summary, with no meta-commentary, introductory text, or headers.\n\n" ^
      "Conversation History:\n" ^
      format_history hist
    in
    let verb = Config.pick_verb (Config.get_verbs "summarizing") in
    let enabled = Config.get_spinner_enabled () in
    let result = Ui.with_spinner clock verb enabled (fun () ->
      Provider.complete_packed net ~model:sess.cfg.model ~options:sess.cfg.options ~tools:[] sess.provider [user_msg prompt]
    ) in
    let summary_content = String.trim result.value.content in
    let new_mem_t =
      let open Memory.Summary in
      let mem = create ~max_messages:sess.cfg.memory_size () in
      let mem_sum = compress ~complete:(fun _ -> summary_content) mem in
      Memory.Mem ((module Memory.SummaryMemory), mem_sum)
    in
    let new_sess = { sess with memory = new_mem_t; turn_idx = 0 } in
    (new_sess, summary_content)


let export_json sess =
  let Memory.Mem ((module M), mem) = sess.memory in
  `Assoc [
    ("model",    `String sess.cfg.model);
    ("turn_idx", `Int sess.turn_idx);
    ("system",   (match sess.cfg.system with
                  | None -> `Null | Some s -> `String s));
    ("history",  M.to_json mem);
  ]

let pp_history fmt sess =
  let Memory.Mem ((module M), mem) = sess.memory in
  List.iter (fun msg ->
    let role_str = role_to_string msg.role in
    Format.fprintf fmt "@[<v>[%s]: %s@]@." role_str msg.content
  ) (M.get mem)
