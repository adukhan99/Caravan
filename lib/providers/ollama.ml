(** Ollama local LLM provider (built on Openai_compatible). *)

open Caravan.Provider

type config = Openai_compatible.config

let normalize_ollama_url url =
  let trimmed = String.trim url in
  let len = String.length trimmed in
  if len > 0 && trimmed.[len - 1] = '/' then
    let sub = String.sub trimmed 0 (len - 1) in
    if Filename.check_suffix sub "/v1" then sub else sub ^ "/v1"
  else if Filename.check_suffix trimmed "/v1" then trimmed
  else trimmed ^ "/v1"

let make_config
    ?(base_url = "http://127.0.0.1:11434")
    ?(options  = Caravan.Types.default_options)
    ?(timeout  = 120.)
    ~model
    () =
  let norm_url = normalize_ollama_url base_url in
  Openai_compatible.make_config
    ~provider_name:"ollama"
    ~base_url:norm_url
    ~options
    ~timeout
    ~model
    ()

module Ollama = struct
  type nonrec config = config
  let name = "ollama"
  let complete = Openai_compatible.complete
  let stream = Openai_compatible.stream
  let list_models = Openai_compatible.list_models
end

let make_provider
    ?(base_url = "http://127.0.0.1:11434")
    ?(options  = Caravan.Types.default_options)
    ?(timeout  = 120.)
    ~model
    () =
  let cfg = make_config ~base_url ~options ~timeout ~model () in
  Provider ((module Ollama), cfg)

let provider : (module PROVIDER with type config = config) = (module Ollama)
