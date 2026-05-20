(** Ollama local LLM backend. *)

open Caravan.Types
open Caravan.Provider
open Caravan.Tool

type config = {
  base_url : string;
  model    : string;
  options  : gen_options;
  timeout  : float;
}

let make_config
    ?(base_url = "http://127.0.0.1:11434")
    ?(options  = default_options)
    ?(timeout  = 120.)
    ~model
    () =
  { base_url; model; options; timeout }

let options_to_json (o : gen_options) =
  let opt key f = function None -> [] | Some v -> [(key, f v)] in
  `Assoc (List.concat [
    opt "temperature"  (fun v -> `Float v) o.temperature;
    opt "top_p"        (fun v -> `Float v) o.top_p;
    opt "top_k"        (fun v -> `Int v)   o.top_k;
    opt "num_predict"  (fun v -> `Int v)   o.max_tokens;
    opt "seed"         (fun v -> `Int v)   o.seed;
    (if o.stop = [] then []
     else [("stop", `List (List.map (fun s -> `String s) o.stop))]);
  ])

let ollama_tool_call_to_json (tc : tool_call) =
  let args_json = try Yojson.Safe.from_string tc.args with _ -> `Assoc [] in
  `Assoc [
    ("type", `String "function");
    ("function", `Assoc [
      ("name", `String tc.name);
      ("arguments", args_json);
    ]);
  ]

let ollama_chat_message_to_json (msg : chat_message) =
  let base = [
    ("role",      `String (match msg.role with Tool _ -> "tool" | r -> role_to_string r));
    ("content",   if msg.content = "" && msg.tool_calls <> None then `Null else `String msg.content);
  ] in
  let base = match msg.tool_calls with
    | Some tcs -> ("tool_calls", `List (List.map ollama_tool_call_to_json tcs)) :: base
    | None -> base
  in
  let base = match msg.role with
    | Tool id -> ("tool_call_id", `String id) :: base
    | _ -> base
  in
  `Assoc base

let ollama_messages_to_json msgs =
  `List (List.map ollama_chat_message_to_json msgs)

let make_body cfg ?tools msgs ~stream =
  let base = [
    ("model",    `String cfg.model);
    ("messages", ollama_messages_to_json msgs);
    ("stream",   `Bool stream);
    ("options",  options_to_json cfg.options);
  ] in
  match tools with
  | None | Some [] -> `Assoc base
  | Some ts ->
      let tools_json = `List (List.map (fun t ->
        `Assoc [
          ("type", `String "function");
          ("function", `Assoc [
            ("name", `String (name_of_packed t));
            ("description", `String (description_of_packed t));
            ("parameters", schema_of_packed t);
          ])
        ]) ts)
      in
      `Assoc (("tools", tools_json) :: base)

let read_body (body : Cohttp_eio.Body.t) =
  Eio.Buf_read.(of_flow body ~max_size:max_int |> take_all)

let parse_usage json =
  let open Yojson.Safe.Util in
  let int_opt key = match json |> member key with `Int i -> Some i | _ -> None in
  match int_opt "eval_count", int_opt "prompt_eval_count" with
  | Some completion_tokens, Some prompt_tokens ->
    let total_tokens = prompt_tokens + completion_tokens in
    let total_duration =
      match json |> member "total_duration" with
      | `Int ns   -> Some (float_of_int ns /. 1e9)
      | `Float ns -> Some (ns /. 1e9)
      | _         -> None
    in
    Some { prompt_tokens; completion_tokens; total_tokens; total_duration }
  | _ -> None

let parse_complete_response body_str model =
  let json = Yojson.Safe.from_string body_str in
  let open Yojson.Safe.Util in
  let msg_json = json |> member "message" in
  let content = msg_json |> member "content" |> to_string in
  let finish   = json |> member "done_reason" |> to_string_option in
  let tool_calls =
    match msg_json |> member "tool_calls" with
    | `Null -> None
    | `List l ->
      Some (List.map (fun tc ->
        let func = tc |> member "function" in
        let name = func |> member "name" |> to_string in
        let args = func |> member "arguments" |> Yojson.Safe.to_string in
        { id = "call_" ^ name; name; args }
      ) l)
    | _ -> None
  in
  let usage = parse_usage json in
  let reply_msg = make_message ?tool_calls Assistant content in
  wrap_result ~raw_response:body_str ~model ~provider:"ollama" ?finish_reason:finish ?usage reply_msg

module Ollama = struct
  type nonrec config = config

  let name = "ollama"

  let complete net cfg ?tools msgs =
    let url  = Uri.of_string (cfg.base_url ^ "/api/chat") in
    let body_str = Yojson.Safe.to_string (make_body cfg ?tools msgs ~stream:false) in
    let headers  = Http.Header.of_list [
      ("Content-Type", "application/json");
      ("Accept",       "application/json");
    ] in
    let client = Cohttp_eio.Client.make ~https:None net in
    Eio.Switch.run @@ fun sw ->
    let (resp, body) =
      Cohttp_eio.Client.post client ~sw ~headers
        ~body:(Cohttp_eio.Body.of_string body_str) url
    in
    let status = Http.Response.status resp |> Http.Status.to_int in
    let resp_body = read_body body in
    if status >= 200 && status < 300 then
      parse_complete_response resp_body cfg.model
    else
      failwith (Printf.sprintf "Ollama error %d: %s" status resp_body)

  let stream net cfg ?tools msgs ~on_token =
    let url      = Uri.of_string (cfg.base_url ^ "/api/chat") in
    let body_str = Yojson.Safe.to_string (make_body cfg ?tools msgs ~stream:true) in
    let headers  = Http.Header.of_list [("Content-Type", "application/json")] in
    let buf      = Buffer.create 4096 in
    let result   = ref None in
    let client   = Cohttp_eio.Client.make ~https:None net in
    Eio.Switch.run @@ fun sw ->
    let (resp, body) =
      Cohttp_eio.Client.post client ~sw ~headers
        ~body:(Cohttp_eio.Body.of_string body_str) url
    in
    let status = Http.Response.status resp |> Http.Status.to_int in
    if status < 200 || status >= 300 then begin
      let err_body = read_body body in
      failwith (Printf.sprintf "Ollama stream error %d: %s" status err_body)
    end;
    let buf_r = Eio.Buf_read.of_flow body ~max_size:max_int in
    (try
      while true do
        let line = String.trim (Eio.Buf_read.line buf_r) in
        if line <> "" then begin
          (try
            let json = Yojson.Safe.from_string line in
            let open Yojson.Safe.Util in
            let msg_json = json |> member "message" in
            let token = msg_json |> member "content" |> to_string in
            Buffer.add_string buf token;
            on_token token;
            let done_ = json |> member "done" |> to_bool in
            if done_ then begin
              let full   = Buffer.contents buf in
              let finish = json |> member "done_reason" |> to_string_option in
              let usage  = parse_usage json in
              let tool_calls =
                match msg_json |> member "tool_calls" with
                | `Null -> None
                | `List l ->
                  Some (List.map (fun tc ->
                    let func = tc |> member "function" in
                    let name = func |> member "name" |> to_string in
                    let args = func |> member "arguments" |> Yojson.Safe.to_string in
                    { id = "call_" ^ name; name; args }
                  ) l)
                | _ -> None
              in
              let reply = make_message ?tool_calls Assistant full in
              result := Some (wrap_result ~raw_response:full ~model:cfg.model
                ~provider:"ollama" ?finish_reason:finish ?usage reply)
            end
          with exn ->
            Printf.eprintf "[Ollama Stream Parse Error]: %s\nLine: %s\n%!"
              (Printexc.to_string exn) line)
        end
      done
    with End_of_file -> ());
    match !result with
    | Some r -> r
    | None ->
      let full = Buffer.contents buf in
      wrap_result ~raw_response:full ~model:cfg.model ~provider:"ollama"
        (assistant_msg full)

  let list_models net cfg =
    let url    = Uri.of_string (cfg.base_url ^ "/api/tags") in
    let client = Cohttp_eio.Client.make ~https:None net in
    (try
      Eio.Switch.run @@ fun sw ->
      let (resp, body) = Cohttp_eio.Client.get client ~sw url in
      let status = Http.Response.status resp |> Http.Status.to_int in
      let body_str = read_body body in
      if status >= 200 && status < 300 then
        try
          let json = Yojson.Safe.from_string body_str in
          let open Yojson.Safe.Util in
          json |> member "models" |> to_list
          |> List.map (fun m -> m |> member "name" |> to_string)
        with _ -> failwith "cannot query remote provider"
      else
        failwith "cannot query remote provider"
    with _ -> failwith "cannot query remote provider")

end

let make_provider ?(base_url = "http://127.0.0.1:11434")
    ?(options=default_options) ?(timeout=120.) ~model () =
  let cfg = make_config ~base_url ~options ~timeout ~model () in
  Provider ((module Ollama), cfg)

let provider : (module PROVIDER with type config = config) = (module Ollama)
