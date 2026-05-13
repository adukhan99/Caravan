(** Centralized TOML configuration reader. *)

let config_path =
  let home = match Sys.getenv_opt "HOME" with Some h -> h | None -> "." in
  Filename.concat home ".orchcaml/config.toml"

let ensure_config_exists () =
  let dir = Filename.dirname config_path in
  if not (Sys.file_exists dir) then
    (try Unix.mkdir dir 0o755 with _ -> ());
  if not (Sys.file_exists config_path) then
    try
      let oc = open_out config_path in
      output_string oc "# OrchCaml Configuration\n\n";
      close_out oc
    with _ -> ()

let load_toml () =
  ensure_config_exists ();
  if Sys.file_exists config_path then
    try Some (Otoml.Parser.from_file config_path)
    with exn ->
      Printf.eprintf "[OrchCaml] Warning: Failed to parse %s: %s\n%!"
        config_path (Printexc.to_string exn);
      None
  else None

let toml_ast = lazy (load_toml ())

let get_int key =
  match Lazy.force toml_ast with
  | None -> None
  | Some ast ->
    try Some (Otoml.find ast Otoml.get_integer [key])
    with _ -> None

let get_int_opt env_var toml_key =
  match env_var with
  | Some e -> (match Sys.getenv_opt e with
               | Some v when v <> "" -> (try Some (int_of_string v) with _ -> get_int toml_key)
               | _ -> get_int toml_key)
  | None -> get_int toml_key

let get_string key =
  match Lazy.force toml_ast with
  | None -> None
  | Some ast ->
    try Some (Otoml.find ast Otoml.get_string [key])
    with _ -> None

let get_string_opt env_var toml_key =
  match env_var with
  | Some e -> (match Sys.getenv_opt e with
               | Some v when v <> "" -> Some v
               | _ -> get_string toml_key)
  | None -> get_string toml_key

let get_bool key =
  match Lazy.force toml_ast with
  | None -> None
  | Some ast ->
    try Some (Otoml.find ast Otoml.get_boolean [key])
    with _ -> None

let get_bool_opt env_var toml_key =
  let of_env_str = function
    | "true" | "1" | "yes" -> Some true
    | "false" | "0" | "no" -> Some false
    | _ -> None
  in
  match env_var with
  | Some e -> (match Sys.getenv_opt e with
               | Some v when v <> "" ->
                 (match of_env_str (String.lowercase_ascii v) with
                  | Some _ as r -> r
                  | None -> get_bool toml_key)
               | _ -> get_bool toml_key)
  | None -> get_bool toml_key
