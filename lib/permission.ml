type permission_mode =
  | Always_allow
  | Ask_user
  | Deny_all
  | Custom of (string -> string -> bool)

let session_override = ref None

let reset_session_override () = session_override := None

let ask_user_approval desc =
  Printf.printf "\n[Permission Request] %s\nApprove? [y]es / [n]o / [a]lways: %!" desc;
  match read_line () with
  | input ->
    let input' = String.lowercase_ascii (String.trim input) in
    if input' = "a" || input' = "always" then begin
      session_override := Some Always_allow;
      true
    end else
      input' = "y" || input' = "yes"
  | exception _ -> false

let check mode ~is_mutating ~desc =
  let effective_mode = match !session_override with Some m -> m | None -> mode in
  match effective_mode with
  | Always_allow -> true
  | Ask_user ->
    if not is_mutating then true
    else ask_user_approval desc
  | Deny_all -> not is_mutating
  | Custom policy -> policy desc ""

let default_policy () = Always_allow

(** Map a config-level mode string to a permission policy usable as
    [Effects.run_with_effects ~permission_policy]. *)
let policy_of_mode
    ?(is_mutating = fun _ -> true)
    ?(describe_action = fun name _ -> Printf.sprintf "Use tool '%s'" name)
    mode : string -> string -> bool =
  match String.lowercase_ascii mode with
  | "ask" ->
    (fun name args ->
       let is_mut = is_mutating name in
       let desc = describe_action name args in
       check Ask_user ~is_mutating:is_mut ~desc)
  | "readonly" | "read-only" | "ro" ->
    (fun name _args ->
       not (is_mutating name))
  | _ -> (fun _ _ -> true)

