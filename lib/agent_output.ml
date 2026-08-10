type mode = Plain | Json

let format_success ~mode ~result ~transcript =
  match mode with
  | Json ->
    Yojson.Safe.to_string (`Assoc [
      ("ok", `Bool true);
      ("result", `String (String.trim result.Types.value.Types.content));
      ("model", `String result.Types.model);
      ("provider", `String result.Types.provider);
      ("turns", (match result.Types.turn_count with Some t -> `Int t | None -> `Null));
      ("usage", (match result.Types.usage with
        | Some u -> `Assoc [
            ("prompt_tokens", `Int u.Types.prompt_tokens);
            ("completion_tokens", `Int u.Types.completion_tokens)]
        | None -> `Null));
      ("transcript", (match transcript with
        | Some p -> `String p | None -> `Null));
    ])
  | Plain ->
    String.trim result.Types.value.Types.content

let format_error ~mode ~message ~transcript =
  match mode with
  | Json ->
    Yojson.Safe.to_string (`Assoc [
      ("ok", `Bool false);
      ("error", `String message);
      ("transcript", (match transcript with
        | Some p -> `String p | None -> `Null));
    ])
  | Plain ->
    Printf.sprintf "[caravan agent] %s" message
