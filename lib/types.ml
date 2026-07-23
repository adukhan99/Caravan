(** Message and type definitions. *)

open Ppx_yojson_conv_lib.Yojson_conv.Primitives

type role =
  | System
  | User
  | Assistant
  | Tool of string

let role_to_string = function
  | System       -> "system"
  | User         -> "user"
  | Assistant    -> "assistant"
  | Tool name    -> "tool:" ^ name

let role_of_string_result = function
  | "system"    -> Ok System
  | "user"      -> Ok User
  | "assistant" -> Ok Assistant
  | "tool"      -> Ok (Tool "")
  | s when String.length s > 5 && String.sub s 0 5 = "tool:" ->
    Ok (Tool (String.sub s 5 (String.length s - 5)))
  | s           -> Error ("Unknown role: " ^ s)

let role_of_string s =
  match role_of_string_result s with
  | Ok r    -> r
  | Error e -> failwith e

type tool_call = {
  id            : string;
  name          : string;
  args          : string;
  extra_content : Yojson.Safe.t option;
}

(** A single message in a conversation. *)
type chat_message = {
  role          : role;
  content       : string;
  timestamp     : float;
  tool_calls    : tool_call list option;
  extra_content : Yojson.Safe.t option;
}

let make_message ?tool_calls ?extra_content role content = {
  role;
  content;
  timestamp = Unix.gettimeofday ();
  tool_calls;
  extra_content;
}

let system_msg    content          = make_message System    content
let user_msg      content          = make_message User      content
let assistant_msg content          = make_message Assistant content

let assistant_tool_msg ~tool_calls content =
  make_message ~tool_calls Assistant content

let tool_msg call_id content = make_message (Tool call_id) content

let tool_call_to_json tc =
  let fields = [
    ("id", `String tc.id);
    ("type", `String "function");
    ("function", `Assoc [
      ("name", `String tc.name);
      ("arguments", `String tc.args);
    ]);
  ] in
  match tc.extra_content with
  | Some ec -> `Assoc (("extra_content", ec) :: fields)
  | None -> `Assoc fields

let chat_message_to_json msg =
  let base = [
    ("role",      `String (match msg.role with Tool _ -> "tool" | r -> role_to_string r));
    ("content",   if msg.content = "" && msg.tool_calls <> None then `Null else `String msg.content);
    ("timestamp", `Float  msg.timestamp);
  ] in
  let base = match msg.extra_content with
    | Some ec -> ("extra_content", ec) :: base
    | None -> base
  in
  let base = match msg.tool_calls with
    | Some tcs -> ("tool_calls", `List (List.map tool_call_to_json tcs)) :: base
    | None -> base
  in
  let base = match msg.role with
    | Tool id -> ("tool_call_id", `String id) :: base
    | _ -> base
  in
  `Assoc base

let tool_call_of_json_result json =
  try
    let open Yojson.Safe.Util in
    let func = json |> member "function" in
    let extra_content =
      match json |> member "extra_content" with
      | `Null -> None
      | ec -> Some ec
    in
    Ok {
      id   = json |> member "id"   |> to_string;
      name = func |> member "name" |> to_string;
      args = func |> member "arguments" |> to_string;
      extra_content;
    }
  with Yojson.Safe.Util.Type_error (msg, _) -> Error ("tool_call parse: " ^ msg)

let tool_call_of_json json =
  match tool_call_of_json_result json with
  | Ok tc   -> tc
  | Error e -> failwith e

let chat_message_of_json_result json =
  try
    let open Yojson.Safe.Util in
    let role_str = json |> member "role" |> to_string in
    let extra_content =
      match json |> member "extra_content" with
      | `Null -> None
      | ec -> Some ec
    in
    let role_r =
      if role_str = "tool" then
        match json |> member "tool_call_id" with
        | `String id -> Ok (Tool id)
        | _          -> role_of_string_result role_str
      else
        role_of_string_result role_str
    in
    let tool_calls_r =
      match json |> member "tool_calls" with
      | `Null  -> Ok None
      | `List l ->
        let results = List.map tool_call_of_json_result l in
        let errs = List.filter_map (function Error e -> Some e | Ok _ -> None) results in
        if errs <> [] then Error (String.concat "; " errs)
        else Ok (Some (List.filter_map (function Ok tc -> Some tc | _ -> None) results))
      | _ -> Ok None
    in
    let open struct
      module Let_syntax = struct
        let bind x ~f = Result.bind x f
        let map x ~f = Result.map f x
      end
    end in
    let%bind role = role_r in
    let%map tcs = tool_calls_r in
    {
      role;
      content       = (match json |> member "content" with `String s -> s | `Null -> "" | _ -> "");
      timestamp     = (match json |> member "timestamp" with `Float f -> f | _ -> 0.0);
      tool_calls    = tcs;
      extra_content;
    }
  with Yojson.Safe.Util.Type_error (msg, _) -> Error ("chat_message parse: " ^ msg)


let chat_message_of_json json =
  match chat_message_of_json_result json with
  | Ok m    -> m
  | Error e -> failwith e

let messages_to_json msgs =
  `List (List.map chat_message_to_json msgs)

type usage = {
  prompt_tokens     : int;
  completion_tokens : int;
  total_tokens      : int;
  total_duration    : float option;
} [@@deriving yojson]

type 'a result_with_meta = {
  value        : 'a;
  raw_response : string;
  model        : string;
  provider     : string;
  finish_reason: string option;
  usage        : usage option;
  turn_count   : int option;
}

let wrap_result ~raw_response ~model ~provider ?finish_reason ?usage ?turn_count value =
  { value; raw_response; model; provider; finish_reason; usage; turn_count }

type gen_options = {
  temperature  : float option;
  top_p        : float option;
  top_k        : int option;
  max_tokens   : int option;
  stop         : string list;
  seed         : int option;
} [@@deriving yojson]

let default_options = {
  temperature  = None;
  top_p        = None;
  top_k        = None;
  max_tokens   = None;
  stop         = [];
  seed         = None;
}

let options
    ?temperature ?top_p ?top_k ?max_tokens ?(stop=[]) ?seed () =
  { temperature; top_p; top_k; max_tokens; stop; seed }
