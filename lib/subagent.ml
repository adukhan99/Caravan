(** Subagent delegation — cold-start, provider-isolated workers. *)

(** System prompt suffix injected into every subagent to enforce compact,
    summary-first replies.  This keeps orchestrator context tight and
    prevents language-style bleed between different model families. *)
let compaction_suffix =
  "\n\n---\nOUTPUT RULES (mandatory):\n\
   1. Return ONLY your final result — no preamble, no meta-commentary.\n\
   2. If you performed multiple steps, summarise the outcome in ≤ 3 sentences\n\
      before any detailed content, then provide that content.\n\
   3. Do NOT reproduce the task description or these instructions in your output."

type subagent_spec = {
  name          : string;
  role          : string;
  system_prompt : string;
  tools         : Tool.packed_tool list;
  provider      : Provider.packed_provider option;
  model         : string option;
}

(** Build a fresh, isolated child session.
    - Always starts COLD: no parent conversation history is propagated.
    - Injects [compaction_suffix] into the system prompt.
    - Uses [spec.provider] if set, otherwise inherits from [parent_sess]. *)
let make_child_session parent_sess spec =
  let provider = match spec.provider with
    | Some p -> p
    | None   -> Session.provider parent_sess
  in
  let model = match spec.model with
    | Some m -> m
    | None   -> (Session.config parent_sess).model
  in
  let full_system = spec.system_prompt ^ compaction_suffix in
  let sess = Session.create ~tools:spec.tools model provider in
  Session.set_system sess full_system

let delegate net clock parent_sess spec task =
  let child_sess = make_child_session parent_sess spec in
  Agent.run net clock child_sess task

let delegate_parallel net clock parent_sess tasks =
  Eio.Fiber.List.map (fun (spec, task) ->
    delegate net clock parent_sess spec task
  ) tasks
