(** CLI argument resolution and provider/model fallback logic. *)

(** [resolve ~default_model ~provider_cli ~model_cli ~base_url_cli ()]
    resolves provider, model, and base URL settings by taking explicit CLI overrides
    and falling back to environment or default settings. *)
val resolve :
  default_model:(string -> string) ->
  provider_cli:string option ->
  model_cli:string option ->
  base_url_cli:string option ->
  unit ->
  string * string * string option


