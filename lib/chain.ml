(** OrchCaml.Chain — Composable typed LLM pipelines.

    The chain type is ['a -> ('b, string) result]. Direct style — no Lwt.t.
    Error paths are first-class citizens — [|>>] threads the Result monad
    using [Result.bind], so a failing step short-circuits the rest of the
    pipeline without exceptions.

    Chains that perform I/O (LLM calls, streaming) receive the Eio [net]
    capability explicitly.

    Example:
    {[
      let my_chain net provider =
        Chain.prompt_template "Explain {{topic}} in one sentence."
        |>> Chain.llm net provider
        |>> Chain.parse Parser.trimmed
      in
      let result = Chain.run (my_chain net provider) [("topic", "monads")] in
      match result with
      | Ok answer -> ...
      | Error msg -> ...
    ]}
*)

open Types

(** A chain step: a function from ['a] to [('b, string) result]. *)
type ('a, 'b) t = 'a -> ('b, string) result

(** Compose two chain steps left-to-right via [Result.bind]. *)
let (|>>) (f : ('a, 'b) t) (g : ('b, 'c) t) : ('a, 'c) t =
  fun x -> Result.bind (f x) g

(** Run a chain with an input value. *)
let run chain input = chain input

(** Run and raise on [Error] (escape hatch for interop). *)
let run_exn chain input =
  match chain input with
  | Ok v    -> v
  | Error e -> failwith e

(** Lift a pure function into a chain (always succeeds). *)
let lift f x = Ok (f x)

(** Lift a [Result]-returning pure function into a chain. *)
let lift_result f x = f x

(** [tap f] runs [f] for side effects on a successfully computed value
    and passes it through unchanged.  If the upstream is [Error], [f] is
    not called. *)
let tap (f : 'b -> unit) : ('b, string) result -> ('b, string) result =
  function
  | Error _ as e -> e
  | Ok v -> f v; Ok v

(** [tap_pure] is an alias for [tap] (kept for API compatibility). *)
let tap_pure = tap

(* Prompt steps *)

(** [prompt_template tmpl_str] compiles and renders a template string.
    Input: a variable list [(name, value)].
    Output: the rendered string, or [Error] on missing variables. *)
let prompt_template tmpl_str : (string * string) list -> (string, string) result =
  let tmpl = Template.of_string tmpl_str in
  fun vars -> Template.render ~vars tmpl

(** [prompt_messages tmpl_str] like [prompt_template] but produces a
    [chat_message list] suitable for direct LLM submission.
    Returns [Error] if template rendering fails. *)
let prompt_messages ?system tmpl_str
  : (string * string) list -> (chat_message list, string) result =
  let ct = Template.chat_template ?system tmpl_str in
  fun vars -> Template.render_chat ~vars ct

(** [just_messages msgs] lifts a static message list into a chain. *)
let just_messages msgs : unit -> (chat_message list, string) result =
  fun () -> Ok msgs

(* LLM steps *)

(** [llm net provider] calls the provider and returns the assistant's content. *)
let llm (net : _ Eio.Net.t) (provider : Provider.packed_provider)
  : chat_message list -> (string, string) result =
  fun msgs ->
    match Provider.complete_packed net provider msgs with
    | result -> Ok result.value.content
    | exception Failure e -> Error e
    | exception exn -> Error (Printexc.to_string exn)

(** [llm_with_meta net provider] like [llm] but returns the full result
    with metadata (model, provider, finish reason). *)
let llm_with_meta (net : _ Eio.Net.t) (provider : Provider.packed_provider)
  : chat_message list -> (chat_message result_with_meta, string) result =
  fun msgs ->
    match Provider.complete_packed net provider msgs with
    | result -> Ok result
    | exception Failure e -> Error e
    | exception exn -> Error (Printexc.to_string exn)

(** [llm_stream net provider ~on_token] streams tokens via [on_token] and
    returns the full accumulated response when done. *)
let llm_stream (net : _ Eio.Net.t) (provider : Provider.packed_provider)
    ~(on_token : string -> unit)
  : chat_message list -> (string, string) result =
  fun msgs ->
    match Provider.stream_packed net ~on_token provider msgs with
    | result -> Ok result.value.content
    | exception Failure e -> Error e
    | exception exn -> Error (Printexc.to_string exn)

(* Parse steps *)

(** [parse p] applies parser [p] to the LLM's string output.
    Returns [Error] if the parser fails — no exceptions raised. *)
let parse (p : 'a Parser.t) : string -> ('a, string) result =
  fun s -> p s

(* Memory-aware chain helpers *)

(** [with_memory (module M) mem net provider] wraps around a provider so that
    each call:
    1. Prepends memory history to the input messages.
    2. Adds the user's messages and the assistant response to memory.

    Input: [chat_message list] (the new user turn).
    Output: [(m * string)] (the new memory state and the assistant response).
*)
let with_memory
    (type m)
    (module Mem : Memory.MEMORY with type t = m)
    (mem : m)
    (net : _ Eio.Net.t)
    (provider : Provider.packed_provider)
  : chat_message list -> (m * string, string) result =
  fun new_msgs ->
    let mem_with_user = List.fold_left Mem.add mem new_msgs in
    let history = Mem.get mem_with_user in
    match Provider.complete_packed net provider history with
    | result ->
      let final_mem = Mem.add mem_with_user result.value in
      Ok (final_mem, result.value.content)
    | exception Failure e -> Error e
    | exception exn -> Error (Printexc.to_string exn)

(* Sequence combinators *)

(** [sequence chains] runs a list of chains in order, threading the
    value through each one. Short-circuits on the first [Error]. *)
let sequence : ('a, 'a) t list -> ('a, 'a) t = fun chains x ->
  List.fold_left (fun acc chain ->
    Result.bind acc chain
  ) (Ok x) chains

(** [parallel sw chains] runs a list of chains in parallel using Eio fibers
    with the same input.  All branches run to completion; the result is
    [Ok (list of values)] only when every branch succeeds, otherwise
    [Error (all errors joined)]. *)
let parallel (sw : Eio.Switch.t) (chains : ('a, 'b) t list) : ('a, 'b list) t =
  fun x ->
    let results = Array.make (List.length chains) (Error "") in
    Eio.Fiber.all (List.mapi (fun i c ->
      fun () -> results.(i) <- c x
    ) chains |> List.to_seq |> Array.of_seq |> Array.to_list);
    ignore sw;
    let result_list = Array.to_list results in
    let errs = List.filter_map (function Error e -> Some e | Ok _ -> None) result_list in
    if errs <> [] then Error (String.concat "\n" errs)
    else Ok (List.filter_map (function Ok v -> Some v | _ -> None) result_list)

(** [retry ~n chain] retries [chain] up to [n] times on [Error].
    Propagates the last error if all attempts fail. *)
let retry ~n chain x =
  let rec loop i =
    match chain x with
    | Ok _ as ok -> ok
    | Error e ->
      if i >= n then Error e
      else begin
        Printf.eprintf "[OrchCaml] Retry %d/%d: %s\n%!" (i+1) n e;
        loop (i + 1)
      end
  in
  loop 0
