(** OpenAI LLM provider (built on Openai_compatible). *)

open Caravan.Provider

let load_api_key_from_env () =
  match Caravan.Config.get_string_opt (Some "OPENAI_API_KEY") "openai_api_key" with
  | Some k -> k
  | None -> failwith "OPENAI_API_KEY not found in env or ~/.caravan/config.toml"

let load_org_id () = Sys.getenv_opt "OPENAI_ORG_ID"

type config = Openai_compatible.config

let make_config
    ?(base_url = "https://api.openai.com/v1")
    ?(options  = Caravan.Types.default_options)
    ?api_key
    ~model
    () =
  let api_key = match api_key with
    | Some k -> k
    | None   -> load_api_key_from_env ()
  in
  Openai_compatible.make_config
    ~provider_name:"openai"
    ~base_url
    ~options
    ~api_key
    ?org_id:(load_org_id ())
    ~model
    ()

module Openai = struct
  type nonrec config = config
  let name = "openai"
  let complete = Openai_compatible.complete
  let stream = Openai_compatible.stream
  let list_models = Openai_compatible.list_models
end

let make_provider
    ?(base_url = "https://api.openai.com/v1")
    ?(options  = Caravan.Types.default_options)
    ?api_key
    ~model
    () =
  let cfg = make_config ~base_url ~options ?api_key ~model () in
  Provider ((module Openai), cfg)

let provider : (module PROVIDER with type config = config) = (module Openai)
