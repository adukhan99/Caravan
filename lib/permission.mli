type permission_mode =
  | Always_allow
  | Ask_user
  | Deny_all
  | Custom of (string -> string -> bool)

val check : permission_mode -> string -> string -> bool
val ask_user_approval : string -> string -> bool
val default_policy : unit -> permission_mode
