(** Composable typed LLM pipelines. *)

open Types

type ('a, 'b) t = 'a -> ('b, string) result

let (|>>) (f : ('a, 'b) t) (g : ('b, 'c) t) : ('a, 'c) t =
  fun x -> Result.bind (f x) g

let run chain input = chain input

let run_exn chain input =
  match chain input with
  | Ok v    -> v
  | Error e -> failwith e

let lift f x = Ok (f x)

let lift_result f x = f x

let tap (f : 'b -> unit) : ('b, string) result -> ('b, string) result =
  function
  | Error _ as e -> e
  | Ok v -> f v; Ok v

let tap_pure = tap

let prompt_template tmpl_str : (string * string) list -> (string, string) result =
  let tmpl = Template.of_string tmpl_str in
  fun vars -> Template.render ~vars tmpl

let prompt_messages ?system tmpl_str
  : (string * string) list -> (chat_message list, string) result =
  let ct = Template.chat_template ?system tmpl_str in
  fun vars -> Template.render_chat ~vars ct

let just_messages msgs : unit -> (chat_message list, string) result =
  fun () -> Ok msgs

let llm (net : _ Eio.Net.t) (provider : Provider.packed_provider)
  : chat_message list -> (string, string) result =
  fun msgs ->
    match Provider.complete_packed net provider msgs with
    | result -> Ok result.value.content
    | exception Failure e -> Error e
    | exception exn -> Error (Printexc.to_string exn)

let llm_with_meta (net : _ Eio.Net.t) (provider : Provider.packed_provider)
  : chat_message list -> (chat_message result_with_meta, string) result =
  fun msgs ->
    match Provider.complete_packed net provider msgs with
    | result -> Ok result
    | exception Failure e -> Error e
    | exception exn -> Error (Printexc.to_string exn)

let llm_stream (net : _ Eio.Net.t) (provider : Provider.packed_provider)
    ~(on_token : string -> unit)
  : chat_message list -> (string, string) result =
  fun msgs ->
    match Provider.stream_packed net ~on_token provider msgs with
    | result -> Ok result.value.content
    | exception Failure e -> Error e
    | exception exn -> Error (Printexc.to_string exn)

let parse (p : 'a Parser.t) : string -> ('a, string) result =
  fun s -> p s

let agent ?config (net : _ Eio.Net.t) (clock : _ Eio.Time.clock) (provider : Provider.packed_provider) (tools : Tool.packed_tool list)
  : string -> (Session.t * chat_message result_with_meta, string) result =
  fun task ->
    let sess = Session.create ~tools (Provider.name_of_packed provider) provider in
    Agent.run ?config net clock sess task

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

let sequence : ('a, 'a) t list -> ('a, 'a) t = fun chains x ->
  List.fold_left (fun acc chain ->
    Result.bind acc chain
  ) (Ok x) chains

let parallel (sw : Eio.Switch.t) (chains : ('a, 'b) t list) : ('a, 'b list) t =
  fun x ->
    let results = Array.make (List.length chains) (Error "") in
    Eio.Fiber.all (List.mapi (fun i c ->
      fun () -> results.(i) <- c x
    ) chains);
    ignore sw;
    let result_list = Array.to_list results in
    let errs = List.filter_map (function Error e -> Some e | Ok _ -> None) result_list in
    if errs <> [] then Error (String.concat "\n" errs)
    else Ok (List.filter_map (function Ok v -> Some v | _ -> None) result_list)

let retry ~n chain x =
  let rec loop i =
    match chain x with
    | Ok _ as ok -> ok
    | Error e ->
      if i >= n then Error e
      else begin
        Printf.eprintf "[Caravan] Retry %d/%d: %s\n%!" (i+1) n e;
        loop (i + 1)
      end
  in
  loop 0

(* --- Kleisli Category Composition --- *)

module Kleisli = struct
  let compose (f : 'a -> ('b, 'e) result) (g : 'b -> ('c, 'e) result) : 'a -> ('c, 'e) result =
    fun x -> Result.bind (f x) g

  let ( >=> ) = compose
end

