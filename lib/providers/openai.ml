(** OpenAI-compatible LLM backend. *)

open OrchCaml.Types
open OrchCaml.Provider
open OrchCaml.Config
open OrchCaml.Tool

let load_api_key_from_env () =
  match get_string_opt (Some "OPENAI_API_KEY") "openai_api_key" with
  | Some k -> k
  | None -> failwith "OPENAI_API_KEY not found in env or ~/.orchcaml/config.toml"

let load_org_id () = Sys.getenv_opt "OPENAI_ORG_ID"

type config = {
  base_url : string;
  api_key  : string;
  model    : string;
  options  : gen_options;
  org_id   : string option;
}

let make_config
    ?(base_url = "https://api.openai.com/v1")
    ?(options  = default_options)
    ?api_key
    ~model
    () =
  let api_key = match api_key with
    | Some k -> k
    | None   -> load_api_key_from_env ()
  in
  { base_url; api_key; model; options; org_id = load_org_id () }

let options_to_json_fields (o : gen_options) =
  let opt key f = function None -> [] | Some v -> [(key, f v)] in
  List.concat [
    opt "temperature"  (fun v -> `Float v) o.temperature;
    opt "top_p"        (fun v -> `Float v) o.top_p;
    opt "max_tokens"   (fun v -> `Int v)   o.max_tokens;
    opt "seed"         (fun v -> `Int v)   o.seed;
    (if o.stop = [] then []
     else [("stop", `List (List.map (fun s -> `String s) o.stop))]);
  ]

let make_body cfg ?tools msgs ~stream =
  let base_fields = List.concat [
    [
      ("model",    `String cfg.model);
      ("messages", messages_to_json msgs);
      ("stream",   `Bool stream);
    ];
    options_to_json_fields cfg.options;
  ] in
  let base_fields =
    if stream then ("stream_options", `Assoc [("include_usage", `Bool true)]) :: base_fields
    else base_fields
  in
  match tools with
  | None | Some [] -> `Assoc base_fields
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
      `Assoc (("tools", tools_json) :: base_fields)

let auth_headers cfg =
  let h = [
    ("Content-Type",  "application/json");
    ("Authorization", "Bearer " ^ cfg.api_key);
  ] in
  match cfg.org_id with
  | None    -> h
  | Some id -> ("OpenAI-Organization", id) :: h

let read_body (body : Cohttp_eio.Body.t) =
  Eio.Buf_read.(of_flow body ~max_size:max_int |> take_all)

let parse_usage json =
  let open Yojson.Safe.Util in
  match json |> member "usage" with
  | `Assoc _ as u ->
    let prompt_tokens     = u |> member "prompt_tokens"     |> to_int in
    let completion_tokens = u |> member "completion_tokens" |> to_int in
    let total_tokens      = u |> member "total_tokens"      |> to_int in
    Some { prompt_tokens; completion_tokens; total_tokens; total_duration = None }
  | _ -> None

let parse_complete_response body_str model =
  let json = Yojson.Safe.from_string body_str in
  let open Yojson.Safe.Util in
  let choice = json |> member "choices" |> index 0 in
  let msg_json = choice |> member "message" in
  let content =
    match msg_json |> member "content" with
    | `String s -> s
    | `Null -> ""
    | s -> to_string s
  in
  let finish = choice |> member "finish_reason" |> to_string_option in
  let tool_calls =
    match msg_json |> member "tool_calls" with
    | `Null -> None
    | `List l ->
      Some (List.map (fun tc ->
        let id = tc |> member "id" |> to_string in
        let func = tc |> member "function" in
        let name = func |> member "name" |> to_string in
        let args = func |> member "arguments" |> to_string in
        { id; name; args }
      ) l)
    | _ -> None
  in
  let usage = parse_usage json in
  let reply_msg = make_message ?tool_calls Assistant content in
  wrap_result ~raw_response:body_str ~model ~provider:"openai" ?finish_reason:finish ?usage reply_msg

let https uri sock =
  let host = Uri.host uri |> Option.value ~default:"" in
  let ssl_ctx = Ssl.create_context Ssl.TLSv1_2 Ssl.Client_context in
  let ctx = Eio_ssl.Context.create ~ctx:ssl_ctx (Obj.magic sock : Eio_unix.Net.stream_socket_ty Eio.Resource.t) in
  let ssl_sock_raw = Eio_ssl.Context.ssl_socket ctx in
  Ssl.set_client_SNI_hostname ssl_sock_raw host;
  let ssl_sock = Eio_ssl.connect ctx in
  (ssl_sock :> _ Eio.Flow.two_way)

module Openai = struct
  type nonrec config = config

  let name = "openai"

  let complete net cfg ?tools msgs =
    let uri      = Uri.of_string (cfg.base_url ^ "/chat/completions") in
    let body_str = Yojson.Safe.to_string (make_body cfg ?tools msgs ~stream:false) in
    let headers  = Http.Header.of_list (auth_headers cfg) in
    let client   = Cohttp_eio.Client.make ~https:(Some https) net in
    Eio.Switch.run @@ fun sw ->
    let (resp, body) =
      Cohttp_eio.Client.post client ~sw ~headers
        ~body:(Cohttp_eio.Body.of_string body_str) uri
    in
    let status = Http.Response.status resp |> Http.Status.to_int in
    let resp_body = read_body body in
    if status >= 200 && status < 300 then
      parse_complete_response resp_body cfg.model
    else
      failwith (Printf.sprintf "OpenAI error %d: %s" status resp_body)

  let stream net cfg ?tools msgs ~on_token =
    let uri      = Uri.of_string (cfg.base_url ^ "/chat/completions") in
    let headers  = Http.Header.of_list (("Accept", "text/event-stream") :: auth_headers cfg) in
    let body_str = Yojson.Safe.to_string (make_body cfg ?tools msgs ~stream:true) in
    let buf      = Buffer.create 4096 in
    let tool_acc : (int, string * string * Buffer.t) Hashtbl.t = Hashtbl.create 4 in
    let usage_ref = ref None in
    let result_ref = ref None in
    let client   = Cohttp_eio.Client.make ~https:(Some https) net in
    Eio.Switch.run @@ fun sw ->
    let (resp, body) =
      Cohttp_eio.Client.post client ~sw ~headers
        ~body:(Cohttp_eio.Body.of_string body_str) uri
    in
    let status = Http.Response.status resp |> Http.Status.to_int in
    if status < 200 || status >= 300 then begin
      let err = read_body body in
      failwith (Printf.sprintf "OpenAI stream error %d: %s" status err)
    end;
    let buf_r = Eio.Buf_read.of_flow body ~max_size:max_int in
    (try
      while true do
        let line = String.trim (Eio.Buf_read.line buf_r) in
        if String.length line > 6 && String.sub line 0 6 = "data: " then begin
          let data = String.sub line 6 (String.length line - 6) in
          if data = "[DONE]" then begin
            let full = Buffer.contents buf in
            let tool_calls =
              if Hashtbl.length tool_acc = 0 then None
              else begin
                let pairs = Hashtbl.fold (fun idx v acc -> (idx, v) :: acc) tool_acc [] in
                let sorted = List.sort (fun (a,_) (b,_) -> compare a b) pairs in
                Some (List.map (fun (_, (id, name, abuf)) ->
                  { id; name; args = Buffer.contents abuf }
                ) sorted)
              end
            in
            let reply = make_message ?tool_calls Assistant full in
            result_ref := Some (wrap_result ~raw_response:full ~model:cfg.model
              ~provider:"openai" ?usage:(!usage_ref) reply)
          end else begin
            (try
              let json = Yojson.Safe.from_string data in
              let open Yojson.Safe.Util in
              (match json |> member "usage" with
               | `Assoc _ -> usage_ref := parse_usage json
               | _ -> ());
              let choices = json |> member "choices" in
              if choices <> `Null && choices <> `List [] then begin
                let delta = choices |> index 0 |> member "delta" in
                (match delta |> member "content" with
                 | `String token ->
                   Buffer.add_string buf token;
                   on_token token
                 | _ -> ());
                (match delta |> member "tool_calls" with
                 | `List tcs ->
                   List.iter (fun tc ->
                     let idx = tc |> member "index" |> to_int in
                     let (id, name, abuf) =
                       match Hashtbl.find_opt tool_acc idx with
                       | Some existing -> existing
                       | None ->
                         let entry = ("", "", Buffer.create 64) in
                         Hashtbl.add tool_acc idx entry;
                         entry
                     in
                     let new_id =
                       match tc |> member "id" with
                       | `String s when s <> "" -> s
                       | _ -> id
                     in
                     let fn = tc |> member "function" in
                     let new_name =
                       match fn |> member "name" with
                       | `String s when s <> "" -> s
                       | _ -> name
                     in
                     (match fn |> member "arguments" with
                      | `String s -> Buffer.add_string abuf s
                      | _ -> ());
                     Hashtbl.replace tool_acc idx (new_id, new_name, abuf)
                   ) tcs
                 | _ -> ())
              end
            with exn ->
              Printf.eprintf "[OpenAI Stream Parse Error]: %s\nData: %s\n%!"
                (Printexc.to_string exn) data)
          end
        end
      done
    with End_of_file -> ());
    match !result_ref with
    | Some r -> r
    | None ->
      let full = Buffer.contents buf in
      let tool_calls =
        if Hashtbl.length tool_acc = 0 then None
        else begin
          let pairs = Hashtbl.fold (fun idx v acc -> (idx, v) :: acc) tool_acc [] in
          let sorted = List.sort (fun (a,_) (b,_) -> compare a b) pairs in
          Some (List.map (fun (_, (id, name, abuf)) ->
            { id; name; args = Buffer.contents abuf }
          ) sorted)
        end
      in
      let reply = make_message ?tool_calls Assistant full in
      wrap_result ~raw_response:full ~model:cfg.model ~provider:"openai"
        ?usage:(!usage_ref) reply

  let list_models net cfg =
    let uri    = Uri.of_string (cfg.base_url ^ "/models") in
    let client = Cohttp_eio.Client.make ~https:(Some https) net in
    (try
      Eio.Switch.run @@ fun sw ->
      let headers = Http.Header.of_list (auth_headers cfg) in
      let (resp, body) = Cohttp_eio.Client.get client ~sw ~headers uri in
      let status = Http.Response.status resp |> Http.Status.to_int in
      let body_str = read_body body in
      if status >= 200 && status < 300 then
        try
          let json = Yojson.Safe.from_string body_str in
          let open Yojson.Safe.Util in
          json |> member "data" |> to_list
          |> List.map (fun m -> m |> member "id" |> to_string)
        with _ -> failwith "cannot query remote provider"
      else
        failwith "cannot query remote provider"
    with _ -> failwith "cannot query remote provider")

end

let make_provider
    ?(base_url = "https://api.openai.com/v1")
    ?(options  = default_options)
    ?api_key
    ~model
    () =
  let cfg = make_config ~base_url ~options ?api_key ~model () in
  Provider ((module Openai), cfg)

let provider : (module PROVIDER with type config = config) = (module Openai)
