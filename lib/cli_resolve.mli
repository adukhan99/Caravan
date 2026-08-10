val resolve :
  default_model:(string -> string) ->
  provider_cli:string option ->
  model_cli:string option ->
  base_url_cli:string option ->
  unit ->
  string * string * string option

