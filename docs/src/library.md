# Library Guide

Caravan is three findlib libraries: `Caravan` (core), `CaravanProviders`,
`CaravanTools`. Full signatures live in the
[API reference](https://adukhan99.github.io/Caravan/api/).

## A typed pipeline in ten lines

```ocaml
open Caravan
open Caravan.Chain

let fact_chain net provider =
  prompt_template "List 3 facts about {{topic}}."
  |>> llm net provider
  |>> parse Parser.numbered_list

let () = Eio_main.run (fun env ->
  let provider = CaravanProviders.Ollama.make_provider ~model:"llama3.2" () in
  match run (fact_chain env#net provider) [("topic", "OCaml")] with
  | Ok facts -> List.iter print_endline facts
  | Error e  -> prerr_endline e)
```

`|>>` is Result-bind: every stage is `'a -> ('b, string) result`.
Also available: `parallel`, `retry ~n`, Kleisli `>=>`.

## Sessions and agents

```ocaml
let sess = Session.create ~tools:CaravanTools.All_tools.all_tools model provider in
let sess = Session.set_system sess "Be terse." in
match Agent.run env#net env#clock sess "count the .ml files here" with
| Ok (_sess, result) -> print_endline result.value.content
| Error e -> prerr_endline e
```

Wrap calls in `Effects.with_net env#net` so network tools reuse your
event loop, and in
`Effects.run_with_effects ~permission_policy:(Permission.policy_of_mode "ask")`
to govern tools.

## Writing a tool

A tool is a module satisfying `Caravan.Tool.TOOL` — typed input/output,
a JSON schema, and an `execute`. Drop the file in `lib/tools/`; the
build-time generator registers any file that defines
`module <Capitalized-filename>`:

```ocaml
(* lib/tools/word_count.ml *)
open Caravan.Tool

module Word_count = struct
  let name = "word_count"
  let aliases = ["wc"]
  let description = "Counts words in a string."
  type input = string
  type output = int

  let json_schema () = `Assoc [
    "type", `String "object";
    "properties", `Assoc ["text", `Assoc ["type", `String "string"]];
    "required", `List [`String "text"] ]

  let parse_args json =
    try Ok Yojson.Safe.Util.(json |> member "text" |> to_string)
    with _ -> Error "expected {\"text\": …}"

  let format_output n = string_of_int n

  type _ Effect.t += Exec : input -> output Effect.t
  let execute text =
    String.split_on_char ' ' text |> List.filter (( <> ) "") |> List.length
end
```

If the tool mutates state, add its name to `Permission.mutating_tools`.

## Writing a provider

Any OpenAI-compatible endpoint needs **no code** — add a registry entry
(one record in `lib/providers/registry.ml`) or just use `base_url`.
For a genuinely different API, implement `Caravan.Provider.PROVIDER`
(four functions: `name`, `complete`, `stream`, `list_models`) and pack it
with `Provider ((module M), cfg)`.

## Observing everything: Trace

```ocaml
Trace.add_sink (function
  | Trace.Tool_call_end { name; duration; _ } ->
    Printf.eprintf "%s took %.1fs\n" name duration
  | _ -> ());

(* or capture scoped: *)
let (result, events) =
  let acc = ref [] in
  let r = Trace.with_sink (fun e -> acc := e :: !acc) run_my_agent in
  (r, List.rev !acc)
```

`Trace.open_transcript ~dir` attaches the JSONL sink the CLI uses.

## Memory back-ends

`Memory.Ring` (sliding window), `Memory.Summary` (compact-on-demand),
`Memory.Hierarchical` (rolling summaries), `Redis_store` (shared,
multi-process). Sessions accept any `MEMORY` implementation via the
packed existential.
