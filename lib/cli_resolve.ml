(* Reconcile CLI flags, environment variables, and the config file into
   a unified (provider, model, base_url) triple. *)

let resolve ~default_model ~provider_cli ~model_cli ~base_url_cli () =
  let configured_provider = Config.get_string "provider" in
  (* Resolve the provider: CLI flags override environment variables, which
     override the configuration file, defaulting to "ollama". *)
  let provider_name =
    match provider_cli with
    | Some p -> p
    | None ->
      Config.get_string_opt (Some "CARAVAN_PROVIDER") "provider"
      |> Option.value ~default:"ollama"
  in
  (* The model and base URL settings in environment variables or general config
     only apply if the current provider matches the configured provider. *)
  let provider_matches_config =
    match configured_provider with
    | Some cp ->
      String.lowercase_ascii (String.trim cp)
      = String.lowercase_ascii (String.trim provider_name)
    | None -> false
  in
  (* Resolve the model: CLI flags override the matches-only env/config settings,
     which override the default model lookup. *)
  let model =
    match model_cli with
    | Some m -> m
    | None ->
      let from_cfg =
        if provider_matches_config then
          Config.get_string_opt (Some "CARAVAN_MODEL") "model"
        else None
      in
      Option.value ~default:(default_model provider_name) from_cfg
  in
  (* Resolve the base URL: CLI flags override provider-specific configuration
     sections, which override matches-only env/config settings. *)
  let base_url =
    match base_url_cli with
    | Some _ as url -> url
    | None ->
      match Config.get_provider_config provider_name with
      | Some pcfg -> Some pcfg.base_url
      | None ->
        if provider_matches_config then
          Config.get_string_opt (Some "CARAVAN_BASE_URL") "base_url"
        else None
  in
  (provider_name, model, base_url)

let resolve_spec ~default_model ~default_base_url ~provider_cli ~model_cli ~base_url_cli ?api_key_cli () =
  let (provider_name, model, base_url) = resolve ~default_model ~provider_cli ~model_cli ~base_url_cli () in
  let api_key =
    match api_key_cli with
    | Some _ as k -> k
    | None -> Config.get_string_opt (Some "OPENAI_API_KEY") "api_key"
  in
  Provider.parse_spec ~provider_name ~model ~base_url
    ~default_base_url:(default_base_url provider_name) ~api_key

