(lang dune 3.21)

(name Caravan)

(generate_opam_files true)

(source
 (github adukhan99/Caravan))

(authors "Caravan Contributors")

(maintainers "Caravan Contributors")

(license GPL-3.0-or-later)

(package
 (name Caravan)
 (synopsis "A typed LLM orchestration framework for OCaml")
 (description
  "Caravan provides a functional, type-safe interface for composing LLM pipelines with typed message passing, pluggable providers (Ollama, OpenAI-compatible, llama.cpp), output parsers, prompt templates, conversation memory, and an interactive TUI.")
 (depends
  ocaml
  (dune
   (>= 3.21))
  (eio
   (>= 1.0))
  (eio_main
   (>= 1.0))
  (cohttp-eio
   (>= 6.2.1))
  (uri
   (>= 4.0))
  (yojson
   (>= 3.0))
  (cmdliner
   (>= 1.3))
  (fmt
   (>= 0.9))
  (re
   (>= 1.10))
  (otoml
   (>= 1.0))
  (ssl
   (>= 0.7))
  (eio-ssl
   (>= 0.3))
  redis-sync)
 (tags
  ("llm" "orchestration" "ai" "ollama" "openai" "llama.cpp")))
