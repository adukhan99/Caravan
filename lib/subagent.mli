type subagent_spec = {
  name : string;
  role : string;
  system_prompt : string;
  tools : Tool.packed_tool list;
}

val delegate :
  _ Eio.Net.t ->
  _ Eio.Time.clock ->
  Session.t ->
  subagent_spec ->
  string ->
  (Session.t * Types.chat_message Types.result_with_meta, string) result

val delegate_parallel :
  _ Eio.Net.t ->
  _ Eio.Time.clock ->
  Session.t ->
  (subagent_spec * string) list ->
  (Session.t * Types.chat_message Types.result_with_meta, string) result list
