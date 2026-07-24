type permission_mode =
  | Always_allow
  | Ask_user
  | Deny_all
  | Custom of (string -> string -> bool)

let session_override = ref None

let reset_session_override () = session_override := None

let ask_user_approval tool_name args =
  let desc =
    try
      let json = Yojson.Safe.from_string args in
      match tool_name with
      | "bash" ->
        (match Yojson.Safe.Util.member "command" json with
         | `String cmd -> Printf.sprintf "Execute command: %s" cmd
         | _ -> Printf.sprintf "Execute bash command")
      | "write_file" ->
        (match Yojson.Safe.Util.member "path" json with
         | `String path -> Printf.sprintf "Write to file: %s" path
         | _ -> Printf.sprintf "Write file")
      | _ -> Printf.sprintf "Use tool '%s'" tool_name
    with _ -> Printf.sprintf "Use tool '%s'" tool_name
  in
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

let check mode tool_name args =
  let effective_mode = match !session_override with Some m -> m | None -> mode in
  match effective_mode with
  | Always_allow -> true
  | Ask_user -> ask_user_approval tool_name args
  | Deny_all -> false
  | Custom policy -> policy tool_name args

let default_policy () = Always_allow
