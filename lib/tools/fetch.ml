open Caravan.Tool

module Fetch : TOOL = struct

  type input = { url : string }
  type output = (string, string) result

  let name = "web_fetch"
  let description = "Fetches and parses text content from a given URL."

  let json_schema () =
    `Assoc [
      "type", `String "object";
      "properties", `Assoc [
        "url", `Assoc [
          "type", `String "string";
          "description", `String "The URL of the website to fetch."
        ]
      ];
      "required", `List [`String "url"]
    ]

  let parse_args json =
    let open Yojson.Safe.Util in
    try
      let url = json |> member "url" |> to_string in
      Ok { url }
    with Type_error (s, _) -> Error s

  let format_output = function
    | Error e -> Printf.sprintf "Fetch error: %s" e
    | Ok content -> content

  type _ Effect.t += Exec : input -> output Effect.t
  type _ Effect.t += Get_net : _ Eio.Net.t Effect.t

  let strip_html s =
    let len = String.length s in
    let buf = Buffer.create (len / 2) in
    let rec loop i in_script in_style in_comment =
      if i >= len then ()
      else if in_comment then
        if i + 3 <= len && String.sub s i 3 = "-->" then loop (i + 3) false false false
        else loop (i + 1) in_script in_style in_comment
      else if in_script then
        if i + 9 <= len && String.lowercase_ascii (String.sub s i 9) = "</script>" then loop (i + 9) false in_style in_comment
        else loop (i + 1) in_script in_style in_comment
      else if in_style then
        if i + 8 <= len && String.lowercase_ascii (String.sub s i 8) = "</style>" then loop (i + 8) in_script false in_comment
        else loop (i + 1) in_script in_style in_comment
      else if i + 4 <= len && String.sub s i 4 = "<!--" then loop (i + 4) in_script in_style true
      else if i + 7 <= len && String.lowercase_ascii (String.sub s i 7) = "<script" then loop (i + 7) true in_style in_comment
      else if i + 6 <= len && String.lowercase_ascii (String.sub s i 6) = "<style" then loop (i + 6) in_script true in_comment
      else if s.[i] = '<' then
        let rec skip_tag j =
          if j >= len then j
          else if s.[j] = '>' then j + 1
          else skip_tag (j + 1)
        in
        loop (skip_tag (i + 1)) in_script in_style in_comment
      else begin
        Buffer.add_char buf s.[i];
        loop (i + 1) in_script in_style in_comment
      end
    in
    loop 0 false false false;
    let text = Buffer.contents buf in
    let re_spaces = Re.compile (Re.rep1 (Re.set " \t\r\n")) in
    Re.replace_string re_spaces ~by:" " text |> String.trim

  let do_fetch net { url } =
    let uri = Uri.of_string url in
    let https uri sock =
      let host = Uri.host uri |> Option.value ~default:"" in
      let ssl_ctx = Ssl.create_context Ssl.TLSv1_2 Ssl.Client_context in
      let ctx = Eio_ssl.Context.create ~ctx:ssl_ctx (Obj.magic sock : Eio_unix.Net.stream_socket_ty Eio.Resource.t) in
      let ssl_sock_raw = Eio_ssl.Context.ssl_socket ctx in
      Ssl.set_client_SNI_hostname ssl_sock_raw host;
      let ssl_sock = Eio_ssl.connect ctx in
      (ssl_sock :> _ Eio.Flow.two_way)
    in
    let client = Cohttp_eio.Client.make ~https:(Some https) net in
    let headers = Http.Header.of_list [
      ("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8");
      ("User-Agent", "Caravan WebFetch/1.0");
    ] in
    try
      Eio.Switch.run @@ fun sw ->
      let (resp, body) = Cohttp_eio.Client.get client ~sw ~headers uri in
      let status = Http.Response.status resp |> Http.Status.to_int in
      let body_str = Eio.Buf_read.(of_flow body ~max_size:10_000_000 |> take_all) in
      if status >= 200 && status < 300 then
        let text = strip_html body_str in
        let max_len = 12000 in
        let text = if String.length text > max_len then String.sub text 0 max_len ^ "\n[... truncated ...]" else text in
        Ok text
      else
        Error (Printf.sprintf "HTTP %d: Failed to fetch URL. Content: %s" status (String.sub body_str 0 (min 200 (String.length body_str))))
    with exn ->
      let msg = match exn with
        | Failure s -> s
        | _ -> Printexc.to_string exn
      in
      Error (Printf.sprintf "Exception during fetch: %s" msg)

  let execute input =
    match Effect.perform Get_net with
    | net -> do_fetch net input
    | exception Effect.Unhandled _ ->
      Domain.join (Domain.spawn (fun () ->
        Eio_main.run (fun env ->
          do_fetch env#net input
        )
      ))

end
