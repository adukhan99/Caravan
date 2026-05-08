(** LLM resource metric helpers. *)

open Types

let toks_per_sec (u : usage) : float option =
  match u.total_duration with
  | Some d when d > 0.0 -> Some (float_of_int u.completion_tokens /. d)
  | _ -> None

let format_usage (meta : 'a result_with_meta) : string =
  let turn_str = match meta.turn_count with
    | Some t -> Printf.sprintf "Turn %d | " t
    | None -> ""
  in
  match meta.usage with
  | None -> turn_str ^ "Usage: unknown"
  | Some u ->
      let tps = match toks_per_sec u with
        | Some s -> Printf.sprintf " (%.2f toks/s)" s
        | None -> ""
      in
      Printf.sprintf "%sTokens: %d in, %d out%s" turn_str u.prompt_tokens u.completion_tokens tps
