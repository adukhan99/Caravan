(** llama.cpp local LLM provider (built on Openai_compatible). *)

open Caravan.Provider

type config = Openai_compatible.config

let make_config
    ?(base_url = "http://127.0.0.1:8080/v1")
    ?(options  = Caravan.Types.default_options)
    ?api_key
    ~model
    () =
  Openai_compatible.make_config
    ~provider_name:"llama_cpp"
    ~base_url
    ~options
    ?api_key
    ~model
    ()

module Llama_cpp = struct
  type nonrec config = config
  let name = "llama_cpp"
  let complete = Openai_compatible.complete
  let stream = Openai_compatible.stream
  let list_models = Openai_compatible.list_models
end

let make_provider
    ?(base_url = "http://127.0.0.1:8080/v1")
    ?(options  = Caravan.Types.default_options)
    ?api_key
    ~model
    () =
  let cfg = make_config ~base_url ~options ?api_key ~model () in
  Provider ((module Llama_cpp), cfg)

let provider : (module PROVIDER with type config = config) = (module Llama_cpp)
