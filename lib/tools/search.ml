open OrchCaml

(** OrchCaml.Tools.Search — Web search tool.

    Config precedence: SEARCH_API_KEY env var > [tools] search_api_key in config.toml.
*)

module Search : Tool.TOOL = struct

  type input = { query : string; num_results : int }

  type search_result = {
    title   : string;
    url     : string;
    snippet : string;
  }

  type output = (search_result list, string) result


  let name        = "web_search"
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

  (* Config key retrieval: env var first, then toml. *)
  let get_api_key () =
    match Sys.getenv_opt "SEARCH_API_KEY" with
    | Some k when k <> "" -> Some k
    | _ -> Config.get_string "search_api_key"

  let execute { query; num_results } =
    match get_api_key () with
    | None ->
      Error
        "No Search API key found. Set SEARCH_API_KEY or add \
         search_api_key under [tools] in ~/.orchcaml/config.toml."
    | Some api_key ->
      let encoded_query = Uri.pct_encode query in
      let uri = Uri.of_string
        (Printf.sprintf
           "https://api.search.brave.com/res/v1/web/search?q=%s&count=%d"
           encoded_query num_results)
      in
      let headers = Cohttp.Header.of_list [
        "Accept",            "application/json";
        "Accept-Encoding",   "gzip";
        "X-Subscription-Token", api_key;
      ] in
      Lwt_main.run (
        Lwt.catch
          (fun () ->
            let open Lwt.Syntax in
            let* (resp, body) = Cohttp_lwt_unix.Client.get ~headers uri in
            let status = Cohttp.Response.status resp in
            let code   = Cohttp.Code.code_of_status status in
            let* body_str = Cohttp_lwt.Body.to_string body in
            if code <> 200 then
              Lwt.return (Error (Printf.sprintf "HTTP %d: %s" code body_str))
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
              Lwt.return (Ok results))
          (fun exn ->
            Lwt.return (Error (Printf.sprintf "Request failed: %s" (Printexc.to_string exn)))))

end
