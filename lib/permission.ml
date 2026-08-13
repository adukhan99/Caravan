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

let legacy_mutating = ["bash"; "write_file"; "sed"; "touch"; "mkdir"; "delegate"]

let check_by_name mode ~tool_name ~args =
  let is_mutating = List.mem tool_name legacy_mutating in
  let desc = Printf.sprintf "Use tool '%s'" tool_name in
  check mode ~is_mutating ~desc

let default_policy () = Always_allow

(** Map a config-level mode string to a policy usable as
    [Effects.run_with_effects ~permission_policy]. *)
let policy_of_mode mode : string -> string -> bool =
  match String.lowercase_ascii mode with
  | "ask" ->
    (fun name args -> check_by_name Ask_user ~tool_name:name ~args)
  | "readonly" | "read-only" | "ro" ->
    (fun name args -> check_by_name Deny_all ~tool_name:name ~args)
  | _ -> (fun _ _ -> true)


