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

let run ?(config = default_config) net sess task =
  let rec loop sess turn_count =
    if turn_count >= config.max_turns then
      Error "Maximum turns reached without completion."
    else
      let (sess', result) = Session.run_conversations net sess in
      if is_finished sess' then
        Ok (sess', result)
      else
        (* If it didn't call finish and didn't call other tools (which would have kept it in run_conversations),
           it might just be talking. We nudge it to continue if it's not finished. *)
        let user_nudge = user_msg config.continue_prompt in
        let sess'' = { sess' with Session.memory = Memory.Buffer.add sess'.Session.memory user_nudge } in
        loop sess'' (turn_count + 1)
  in
  let sess_with_task = { sess with Session.memory = Memory.Buffer.add sess.Session.memory (user_msg task) } in
  loop sess_with_task 0

let run_stream ?(config = default_config) net sess task ~on_token =
  let rec loop sess turn_count =
    if turn_count >= config.max_turns then
      Error "Maximum turns reached without completion."
    else
      let (sess', result) = Session.run_conversations_stream net sess ~on_token in
      if is_finished sess' then
        Ok (sess', result)
      else
        let user_nudge = user_msg config.continue_prompt in
        let sess'' = { sess' with Session.memory = Memory.Buffer.add sess'.Session.memory user_nudge } in
        loop sess'' (turn_count + 1)
  in
  let sess_with_task = { sess with Session.memory = Memory.Buffer.add sess.Session.memory (user_msg task) } in
  loop sess_with_task 0
