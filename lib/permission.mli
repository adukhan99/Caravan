type permission_mode =
  | Always_allow
  | Ask_user
  | Deny_all
  | Custom of (string -> string -> bool)

val check : permission_mode -> string -> string -> bool
val ask_user_approval : string -> string -> bool
val default_policy : unit -> permission_mode
val reset_session_override : unit -> unit

(** Tools that can change state outside the conversation. *)
val mutating_tools : string list
val is_mutating : string -> bool

(** Map a config mode string ("auto" | "ask" | "readonly") to a
    permission policy for [Effects.run_with_effects]. *)
val policy_of_mode : string -> (string -> string -> bool)
