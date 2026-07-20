type permission_mode =
  | Always_allow
  | Ask_user
  | Deny_all
  | Custom of (string -> string -> bool)

let ask_user_approval tool_name args =
  Printf.printf "\n[Permission Request] Tool '%s' wants to run with args:\n%s\nApprove? (y/N): %!" tool_name args;
  match read_line () with
  | input ->
    let input' = String.lowercase_ascii (String.trim input) in
    input' = "y" || input' = "yes"
  | exception _ -> false

let check mode tool_name args =
  match mode with
  | Always_allow -> true
  | Ask_user -> ask_user_approval tool_name args
  | Deny_all -> false
  | Custom policy -> policy tool_name args

let default_policy () = Always_allow
