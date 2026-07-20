open Caravan.Tool
open Caravan.Config

module Search : TOOL = struct

  type input = { query : string; num_results : int }

  type search_result = {
    title   : string;
    url     : string;
    snippet : string;
  }

  type output = (search_result list, string) result


  let name        = "web_search"
  let aliases     = ["search"; "brave_search"; "google_search"; "web"]
  let description = "Searches the web and returns titles, URLs, and snippets."

  let json_schema () =
    `Assoc [
      "type",       `String "object";
      "properties", `Assoc [
        "query",       `Assoc [
          "type",        `String "string";
          "description", `String "The search query string."
        ];
        "num_results", `Assoc [
          "type",        `String "integer";
          "description", `String "Number of results to return (1–10, default 5).";
          "default",     `Int 5
        ]
      ];
      "required", `List [`String "query"]
    ]

  let parse_args json =
    let open Yojson.Safe.Util in
    try
      let query       = json |> member "query"       |> to_string in
      let num_results = json |> member "num_results"
                        |> to_int_option
                        |> Option.value ~default:5
                        |> (fun n -> max 1 (min 10 n))
      in
      Ok { query; num_results }
    with Type_error (s, _) -> Error s

  let format_output = function
    | Error e -> Printf.sprintf "Search error: %s" e
    | Ok [] -> "No results found."
    | Ok results ->
      results
      |> List.mapi (fun i r ->
        Printf.sprintf "[%d] %s\n    %s\n    %s" (i + 1) r.title r.url r.snippet)
      |> String.concat "\n\n"

  type _ Effect.t += Exec : input -> output Effect.t

  let get_api_key () =
    match Sys.getenv_opt "SEARCH_API_KEY" with
    | Some k when k <> "" -> Some k
    | _ -> get_string "search_api_key"

  let do_search net { query; num_results } =
    let encoded_query = Uri.pct_encode query in
    let url = Printf.sprintf
      "https://api.search.brave.com/res/v1/web/search?q=%s&count=%d"
      encoded_query num_results
    in
    let uri  = Uri.of_string url in
    let headers = Http.Header.of_list [
      ("Accept",                "application/json");
      ("X-Subscription-Token",  match get_api_key () with Some k -> k | None -> "");
    ] in
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
    Eio.Switch.run @@ fun sw ->
    let (resp, body) = Cohttp_eio.Client.get client ~sw ~headers uri in
    let status = Http.Response.status resp |> Http.Status.to_int in
    let body_str = Eio.Buf_read.(of_flow body ~max_size:max_int |> take_all) in
    if status <> 200 then
      Error (Printf.sprintf "HTTP %d: %s" status body_str)
    else
      let json = Yojson.Safe.from_string body_str in
      let open Yojson.Safe.Util in
      let web = json |> member "web" |> member "results" in
      let results =
        match web with
        | `List items ->
          List.map (fun item ->
            let title   = item |> member "title"       |> to_string_option |> Option.value ~default:"" in
            let url     = item |> member "url"         |> to_string_option |> Option.value ~default:"" in
            let snippet = item |> member "description" |> to_string_option |> Option.value ~default:"" in
            { title; url; snippet }
          ) items
        | _ -> []
      in
      Ok results

  type _ Effect.t += Get_net : _ Eio.Net.t Effect.t

  let execute input =
    match get_api_key () with
    | None ->
      Error
        "No Search API key found. Set SEARCH_API_KEY or add \
         search_api_key under [tools] in ~/.caravan/config.toml."
    | Some _api_key ->
      (match Effect.perform Get_net with
       | net -> do_search net input
       | exception Effect.Unhandled _ ->
         Domain.join (Domain.spawn (fun () ->
           Eio_main.run (fun env ->
             do_search env#net input
           )
         )))

end
