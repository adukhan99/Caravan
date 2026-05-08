(** Centralized TOML configuration reader. *)

let config_path = Filename.concat (Sys.getenv "HOME") ".orchcaml/config.toml"

let load_toml () =
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
