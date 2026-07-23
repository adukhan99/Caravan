(** Centralized TOML configuration reader. *)

let config_path =
  match Sys.getenv_opt "CARAVAN_CONFIG" with
  | Some p when p <> "" -> p
  | _ ->
    let home = match Sys.getenv_opt "HOME" with Some h -> h | None -> "." in
    Filename.concat home ".caravan/config.toml"

let ensure_config_exists () =
  let dir = Filename.dirname config_path in
  if not (Sys.file_exists dir) then
    (try Unix.mkdir dir 0o755 with _ -> ());
  if not (Sys.file_exists config_path) then
    try
      let oc = open_out config_path in
      output_string oc "# Caravan Configuration\n\n";
      close_out oc
    with _ -> ()

let load_toml () =
  ensure_config_exists ();
  if Sys.file_exists config_path then
    try Some (Otoml.Parser.from_file config_path)
    with exn ->
      Printf.eprintf "[Caravan] Warning: Failed to parse %s: %s\n%!"
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

type mcp_server_config = {
  name      : string;
  transport : string;
  command   : string;
  args      : string list;
}

(** SLURM-GRES-style generic resource descriptor for a subagent.
    Each key maps to a boolean capability flag.  Unknown keys are
    preserved so future resource types (e.g. [gen_image]) compose
    without breaking older configs.  Default: all capabilities on. *)
type gres = {
  thinking   : bool;  (** Extended chain-of-thought / thinking tokens *)
  tools      : bool;  (** Tool-calling support *)
  vision     : bool;  (** Image / multi-modal input *)
  gen_image  : bool;  (** Image generation output *)
  extra      : (string * bool) list;  (** Forward-compatible catch-all *)
}

let default_gres = {
  thinking  = true;
  tools     = true;
  vision    = true;
  gen_image = false;
  extra     = [];
}

(** Config for a single subagent worker, read from a [[subagents]] table. *)
type subagent_config = {
  name          : string;
  worker_role    : string;   (** "atomic" | "parallel" *)
  provider_ref  : string;   (** key into [providers.*] table *)
  model         : string;
  max_tokens    : int option;
  temperature   : float option;
  tool_names    : string list; (** validated against registered tools at startup *)
  system_prompt : string;
  gres          : gres;
}

(** Config for a named provider endpoint, read from [providers.<name>]. *)
type provider_config = {
  base_url    : string;
  api_key_env : string option;  (** env-var name that holds the key *)
  org_id_env  : string option;
}

let get_mcp_servers () =
  match Lazy.force toml_ast with
  | None -> []
  | Some ast ->
    try
      let servers_node = Otoml.find ast (fun x -> x) ["mcp"; "servers"] in
      let elements =
        match servers_node with
        | Otoml.TomlArray l
        | Otoml.TomlTableArray l -> l
        | _ -> []
      in
      List.filter_map (fun item ->
        match item with
        | Otoml.TomlTable fields
        | Otoml.TomlInlineTable fields ->
          let get_field k = List.assoc_opt k fields in
          let name = match get_field "name" with Some (Otoml.TomlString s) -> Some s | _ -> None in
          let transport = match get_field "transport" with Some (Otoml.TomlString s) -> Some s | _ -> None in
          let command = match get_field "command" with Some (Otoml.TomlString s) -> Some s | _ -> None in
          let args =
            match get_field "args" with
            | Some (Otoml.TomlArray arr)
            | Some (Otoml.TomlTableArray arr) ->
              List.filter_map (function Otoml.TomlString s -> Some s | _ -> None) arr
            | _ -> []
          in
          (match name, transport, command with
           | Some name, Some transport, Some command ->
             Some { name; transport; command; args }
           | _ -> None)
        | _ -> None
      ) elements
    with _ -> []

(** Read a TOML boolean field from an association list, defaulting to [d]. *)
let assoc_bool fields key d =
  match List.assoc_opt key fields with
  | Some (Otoml.TomlBoolean b) -> b
  | _ -> d

(** Read a TOML string field from an association list, returning None on miss. *)
let assoc_string_opt fields key =
  match List.assoc_opt key fields with
  | Some (Otoml.TomlString s) -> Some s
  | _ -> None

(** Read a TOML integer field from an association list, returning None on miss. *)
let assoc_int_opt fields key =
  match List.assoc_opt key fields with
  | Some (Otoml.TomlInteger n) -> Some n
  | _ -> None

(** Read a TOML float field. Accepts both TomlFloat and TomlInteger. *)
let assoc_float_opt fields key =
  match List.assoc_opt key fields with
  | Some (Otoml.TomlFloat f) -> Some f
  | Some (Otoml.TomlInteger n) -> Some (float_of_int n)
  | _ -> None

(** Read a [gres.*] sub-table from a [[subagents]] entry. *)
let parse_gres fields =
  match List.assoc_opt "gres" fields with
  | Some (Otoml.TomlTable gfields | Otoml.TomlInlineTable gfields) ->
    let known = ["thinking"; "tools"; "vision"; "gen_image"] in
    let extra =
      List.filter_map (fun (k, v) ->
        if List.mem k known then None
        else match v with Otoml.TomlBoolean b -> Some (k, b) | _ -> None
      ) gfields
    in
    { thinking  = assoc_bool gfields "thinking"  default_gres.thinking;
      tools     = assoc_bool gfields "tools"     default_gres.tools;
      vision    = assoc_bool gfields "vision"    default_gres.vision;
      gen_image = assoc_bool gfields "gen_image" default_gres.gen_image;
      extra;
    }
  | _ -> default_gres

(** Read all [[subagents]] entries from the config file. *)
let get_subagents () =
  match Lazy.force toml_ast with
  | None -> []
  | Some ast ->
    try
      let node = Otoml.find ast (fun x -> x) ["subagents"] in
      let elements = match node with
        | Otoml.TomlArray l | Otoml.TomlTableArray l -> l
        | _ -> []
      in
      List.filter_map (fun item ->
        match item with
        | Otoml.TomlTable fields | Otoml.TomlInlineTable fields ->
          let get_str  k = assoc_string_opt fields k in
          let get_strl k =
            match List.assoc_opt k fields with
            | Some (Otoml.TomlArray arr | Otoml.TomlTableArray arr) ->
              List.filter_map (function Otoml.TomlString s -> Some s | _ -> None) arr
            | _ -> []
          in
          (match get_str "name", get_str "provider", get_str "model" with
           | Some name, Some provider_ref, Some model ->
             Some {
               name;
               worker_role    = Option.value ~default:"atomic" (get_str "role");
               provider_ref;
               model;
               max_tokens    = assoc_int_opt   fields "max_tokens";
               temperature   = assoc_float_opt fields "temperature";
               tool_names    = get_strl "tools";
               system_prompt = Option.value ~default:"" (get_str "system_prompt");
               gres          = parse_gres fields;
             }
           | _ -> None)
        | _ -> None
      ) elements
    with _ -> []

(** Read a single [providers.<name>] table. *)
let get_provider_config name =
  match Lazy.force toml_ast with
  | None -> None
  | Some ast ->
    try
      let node = Otoml.find ast (fun x -> x) ["providers"; name] in
      (match node with
       | Otoml.TomlTable fields | Otoml.TomlInlineTable fields ->
         (match assoc_string_opt fields "base_url" with
          | None -> None
          | Some base_url ->
            Some {
              base_url;
              api_key_env = assoc_string_opt fields "api_key_env";
              org_id_env  = assoc_string_opt fields "org_id_env";
            })
       | _ -> None)
    with _ -> None

(** Read the [orchestrator] table. Returns (provider_ref, model). *)
let get_orchestrator () =
  match Lazy.force toml_ast with
  | None -> None
  | Some ast ->
    try
      let node = Otoml.find ast (fun x -> x) ["orchestrator"] in
      (match node with
       | Otoml.TomlTable fields | Otoml.TomlInlineTable fields ->
         (match assoc_string_opt fields "provider",
                assoc_string_opt fields "model" with
          | Some p, Some m -> Some (p, m)
          | _ -> None)
       | _ -> None)
    with _ -> None

let get_stream () =
  get_bool_opt (Some "CARAVAN_STREAM") "stream" |> Option.value ~default:true

let get_spinner_enabled () =
  get_bool_opt (Some "CARAVAN_SPINNER") "spinner.enabled" |> Option.value ~default:true

let get_spinner_verbose () =
  get_bool_opt (Some "CARAVAN_SPINNER_VERBOSE") "spinner.verbose" |> Option.value ~default:false

(** Read the TOML [spinner.<tool>] key as a string or array of strings. *)
let get_spinner_verbs tool_name =
  match Lazy.force toml_ast with
  | None -> None
  | Some ast ->
    (* Try array first, then fall back to plain string. *)
    (try
       let arr = Otoml.find ast (Otoml.get_array Otoml.get_string) ["spinner"; tool_name] in
       if arr = [] then None else Some arr
     with _ ->
       try Some [Otoml.find ast Otoml.get_string ["spinner"; tool_name]]
       with _ -> None)

(** Return the list of verbs for [tool_name].
    TOML overrides take priority; built-in defaults are lists so every
    tool can have several synonyms picked randomly at call time. *)
let get_verbs tool_name =
  match get_spinner_verbs tool_name with
  | Some vs -> vs
  | None    ->
    match tool_name with
    | "thinking" -> ["Thinking"]
    | "summarizing" -> ["Summarizing"]
    | _ -> ["Running " ^ tool_name]

(** Pick a verb at random from a list. *)
let pick_verb = function
  | []  -> "Working"
  | [v] -> v
  | vs  -> List.nth vs (Random.int (List.length vs))

