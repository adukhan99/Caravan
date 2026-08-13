type permission_mode =
  | Always_allow
  | Ask_user
  | Deny_all
  | Custom of (string -> string -> bool)

val check : permission_mode -> is_mutating:bool -> desc:string -> bool
val check_by_name : permission_mode -> tool_name:string -> args:string -> bool
val ask_user_approval : string -> bool
val default_policy : unit -> permission_mode
val reset_session_override : unit -> unit

(** Map a config mode string ("auto" | "ask" | "readonly") to a
    permission policy for [Effects.run_with_effects]. *)
val policy_of_mode : string -> (string -> string -> bool)

