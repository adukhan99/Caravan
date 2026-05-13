(** Conversation memory management. *)

open Types

module type MEMORY = sig
  type t
  val create : unit -> t
  val add : t -> chat_message -> t
  val get : t -> chat_message list
  val clear : t -> t
  val length : t -> int
  val to_json : t -> Yojson.Safe.t
  val of_json : Yojson.Safe.t -> t
end

module Buffer : sig
  include MEMORY
  val create : ?window:int -> unit -> t
  val set_window : t -> int -> t
end = struct
  type t = {
    system_msgs : chat_message list;
    front       : chat_message list;
    rear        : chat_message list;
    window      : int;
    len         : int;
  }

  let create ?(window = 20) () =
    { system_msgs = []; front = []; rear = []; window; len = 0 }

  let rebalance dq =
    match dq.front with
    | [] -> { dq with front = List.rev dq.rear; rear = [] }
    | _  -> dq

  let drop_oldest dq =
    let dq = rebalance dq in
    match dq.front with
    | []     -> dq
    | _ :: t -> rebalance { dq with front = t; len = dq.len - 1 }

  let add mem msg =
    match msg.role with
    | System -> { mem with system_msgs = mem.system_msgs @ [msg] }
    | _ ->
      let dq = { mem with rear = msg :: mem.rear; len = mem.len + 1 } in
      if dq.len > dq.window then drop_oldest dq
      else dq

  let set_window mem new_window =
    let window = if new_window = 0 then max_int else new_window in
    let rec prune d =
      if d.len > d.window then prune (drop_oldest d)
      else d
    in
    prune { mem with window }

  let get mem =
    mem.system_msgs @ mem.front @ List.rev mem.rear

  let clear mem =
    { mem with system_msgs = []; front = []; rear = []; len = 0 }

  let length mem = List.length mem.system_msgs + mem.len

  let to_json mem =
    `List (List.map chat_message_to_json (get mem))

  let of_json json =
    let msgs = Yojson.Safe.Util.to_list json |> List.map chat_message_of_json in
    let mem = create () in
    List.fold_left add mem msgs
end

module Noop : MEMORY = struct
  type t = unit
  let create () = ()
  let add () _msg = ()
  let get () = []
  let clear () = ()
  let length () = 0
  let to_json () = `List []
  let of_json _ = ()
end

module Summary = struct
  type t = {
    buf          : Buffer.t;
    max_messages : int;
    summary      : string option;
  }

  let create ?(max_messages = 40) () =
    { buf = Buffer.create ~window:max_messages ();
      max_messages;
      summary = None }

  let add mem msg =
    { mem with buf = Buffer.add mem.buf msg }

  let get mem =
    let msgs = Buffer.get mem.buf in
    match mem.summary with
    | None   -> msgs
    | Some s ->
      let sum_msg = system_msg ("[Conversation summary]: " ^ s) in
      sum_msg :: msgs

  let clear mem =
    { mem with buf = Buffer.clear mem.buf; summary = None }

  let length mem = Buffer.length mem.buf

  let compress ~complete mem =
    let msgs = Buffer.get mem.buf in
    let prompt = [
      system_msg "You are a summarisation assistant. Summarise the following \
                  conversation history concisely, preserving all important \
                  facts, decisions, and context. Output only the summary.";
      user_msg (String.concat "\n\n" (List.map (fun m ->
        Printf.sprintf "[%s]: %s" (role_to_string m.role) m.content) msgs));
    ] in
    let summary = complete prompt in
    { mem with summary = Some summary; buf = Buffer.clear mem.buf }

  let to_json mem =
    `Assoc [
      ("messages", Buffer.to_json mem.buf);
      ("summary",  match mem.summary with
                   | None   -> `Null
                   | Some s -> `String s);
    ]

  let of_json json =
    let open Yojson.Safe.Util in
    let msgs = json |> member "messages" |> to_list |> List.map chat_message_of_json in
    let mem = create () in
    let mem = List.fold_left add mem msgs in
    let summary = match json |> member "summary" with
                  | `Null     -> None
                  | `String s -> Some s
                  | _         -> None
    in
    { mem with summary }
end
