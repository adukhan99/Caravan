(** Autonomous agentic loops. *)

open Types

type agent_config = {
  max_turns : int;
  continue_prompt : string;
}

let default_config = {
  max_turns = Config.get_int_opt (Some "MAX_TURNS") "max_turns" |> Option.value ~default:10;
  continue_prompt = "Please continue until you are finished. Use the 'finish' tool to signal completion.";
}

let is_finished sess =
  let history = Session.history sess in
  List.exists (fun (msg : chat_message) ->
    match msg.tool_calls with
    | Some tcs -> List.exists (fun tc -> tc.name = "finish") tcs
    | None -> false
  ) history

let run_generic ?(config = default_config) ?on_turn run_fn sess task =
  let rec loop sess =
    if Session.turn_idx sess >= config.max_turns then
      Error "Maximum turns reached without completion."
    else begin
      let (sess', result) = run_fn ?max_turns:(Some config.max_turns) ?on_turn sess in
      if is_finished sess' then
        Ok (sess', result)
      else if Session.turn_idx sess' >= config.max_turns then
        Error "Maximum turns reached without completion."
      else
        let sess'' = Prompt.(exec_in_session (user config.continue_prompt) sess') in
        loop sess''
    end
  in
  let sess_with_task = Prompt.(exec_in_session (user task) sess) in
  loop sess_with_task

let run ?(config = default_config) ?on_turn net clock sess task =
  run_generic ~config ?on_turn (fun ?max_turns ?on_turn s -> Session.run_conversations ?max_turns ?on_turn net clock s) sess task

let run_stream ?(config = default_config) ?on_turn net clock sess task ~on_token =
  run_generic ~config ?on_turn (fun ?max_turns ?on_turn s -> Session.run_conversations_stream ?max_turns ?on_turn net clock s ~on_token) sess task
