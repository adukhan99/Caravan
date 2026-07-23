(** Subagent delegation — cold-start, provider-isolated workers. *)

(** The suffix automatically appended to every subagent's system prompt to
    enforce compact, summary-first output back to the orchestrator. *)
val compaction_suffix : string

type subagent_spec = {
  name          : string;
  role          : string;
  (** "atomic" — single task; "parallel" — safe to fan out *)
  system_prompt : string;
  (** Core persona / instructions.  [compaction_suffix] is appended
      automatically — do not duplicate the output rules here. *)
  tools         : Tool.packed_tool list;
  provider      : Provider.packed_provider option;
  (** [Some p] routes the subagent to a specific backend (e.g. local
      Qwen3.5).  [None] inherits the parent session's provider. *)
  model         : string option;
  (** [Some m] specifies the target model name to run. [None] inherits. *)
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
