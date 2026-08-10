(** Structured system and configuration diagnostics. *)

type severity = Pass | Warn | Fail

type check = {
  label    : string;
  severity : severity;
  message  : string;
  hint     : string option;
}

type provider_kind = Local | Cloud

type provider_info = {
  name          : string;
  kind          : provider_kind;
  base_url      : string;
  requires_key  : bool;
  key_env       : string option;
}

(** Run a suite of diagnostic checks. *)
val run_checks :
  find_provider:(string -> provider_info option) ->
  api_key_for:(provider_info -> string option) ->
  list_models:(provider_info -> string option -> string list) ->
  subagents_roster:(Config.subagent_config * string) list ->
  subagents_enabled:bool ->
  unit -> check list
