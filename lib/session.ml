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
  memory   : Memory.Buffer.t;
  turn_idx : int;
  tools    : Tool.packed_tool list;
}

let create ?(config = fun m -> default_config m) ?(tools=[]) model provider =
  let cfg = config model in
  let window = if cfg.memory_size = 0 then max_int else cfg.memory_size in
  {
    cfg;
    provider;
    memory = Memory.Buffer.create ~window ();
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

let clear sess =
  { sess with memory = Memory.Buffer.clear sess.memory; turn_idx = 0 }

let history sess = Memory.Buffer.get sess.memory

let history_for_llm sess =
  match sess.cfg.system with
  | None     -> Memory.Buffer.get sess.memory
  | Some sys ->
    let sm = system_msg sys in
    (match Memory.Buffer.get sess.memory with
     | { role = System; _ } :: _ -> Memory.Buffer.get sess.memory
     | rest -> sm :: rest)

let execute_tool_calls _net sess tcs =
  List.map (fun tc ->
    match List.find_opt (fun t -> Tool.name_of_packed t = tc.name) sess.tools with
    | None ->
      let msg = Printf.sprintf "Tool '%s' not found in registered tools." tc.name in
      Printf.eprintf "%s: %s → %s\n%!" (Ui.magenta "[Tool]") tc.name (Ui.red "NOT FOUND");
      tool_msg tc.id msg
    | Some packed ->
      Printf.eprintf "%s: %s(%s)\n%!" (Ui.magenta "[Tool]") (Ui.bold tc.name) (Ui.dim tc.args);
      let output_str = Tool.dispatch packed tc.args in
      Printf.eprintf "%s: %s\n%!" (Ui.dim "[Tool Result]") (Ui.dim output_str);
      tool_msg tc.id output_str
  ) tcs

type step_outcome =
  | Continue of t
  | Done     of t * string

let run_turn_step net sess (reply : chat_message) =
  let final_memory = Memory.Buffer.add sess.memory reply in
  let new_sess = { sess with memory = final_memory; turn_idx = sess.turn_idx + 1 } in
  match reply.tool_calls with
  | Some tcs when tcs <> [] ->
    let tool_responses = execute_tool_calls net new_sess tcs in
    let memory_with_tools =
      List.fold_left Memory.Buffer.add new_sess.memory tool_responses
    in
    Continue { new_sess with memory = memory_with_tools }
  | _ ->
    Done (new_sess, reply.content)

let rec run_conversations net sess =
  let result = Provider.complete_packed net ~tools:sess.tools sess.provider (history_for_llm sess) in
  let outcome = run_turn_step net sess result.value in
  match outcome with
  | Continue sess' -> run_conversations net sess'
  | Done (sess', _content) -> (sess', result)

let turn net sess user_input =
  let user = user_msg user_input in
  let sess' = { sess with memory = Memory.Buffer.add sess.memory user } in
  run_conversations net sess'

let rec run_conversations_stream net sess ~on_token =
  let result_with_meta =
    Provider.stream_packed net ~tools:sess.tools ~on_token sess.provider (history_for_llm sess)
  in
  let outcome = run_turn_step net sess result_with_meta.value in
  match outcome with
  | Continue sess' -> run_conversations_stream net sess' ~on_token
  | Done (sess', _content) -> (sess', result_with_meta)

let turn_stream net sess user_input ~on_token =
  let user = user_msg user_input in
  let sess' = { sess with memory = Memory.Buffer.add sess.memory user } in
  run_conversations_stream net sess' ~on_token

let export_json sess =
  `Assoc [
    ("model",    `String sess.cfg.model);
    ("turn_idx", `Int sess.turn_idx);
    ("system",   (match sess.cfg.system with
                  | None -> `Null | Some s -> `String s));
    ("history",  Memory.Buffer.to_json sess.memory);
  ]

let pp_history fmt sess =
  List.iter (fun msg ->
    let role_str = role_to_string msg.role in
    Format.fprintf fmt "@[<v>[%s]: %s@]@." role_str msg.content
  ) (Memory.Buffer.get sess.memory)
