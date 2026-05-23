(** Typed output parsers for LLM responses. *)

type 'a parse_result = ('a, string) result
type 'a t = string -> 'a parse_result

let map f p s = Result.map f (p s)

let and_then f p s = match p s with
  | Error e -> Error e
  | Ok v    -> f v s

let (>|=) p f = map f p
let (>>=) p f = and_then f p

module Let_syntax = struct
  let bind p ~f s = match p s with
    | Error e -> Error e
    | Ok v    -> f v s

  let map p ~f s = match p s with
    | Error e -> Error e
    | Ok v    -> Ok (f v)
end

let return v _s = Ok v
let fail msg _s = Error msg

let or_else p1 p2 s = match p1 s with
  | Ok _ as ok -> ok
  | Error _    -> p2 s

let (<|>) = or_else

let ap pf pa =
  let%bind f = pf in
  let%map a = pa in
  f a

let (<*>) = ap

let product pa pb =
  let%bind a = pa in
  let%map b = pb in
  (a, b)

let string : string t = fun s -> return s s

let trimmed : string t = fun s -> return (String.trim s) s

let json : Yojson.Safe.t t = fun s ->
  try return (Yojson.Safe.from_string (String.trim s)) s
  with Yojson.Json_error msg -> fail ("JSON parse error: " ^ msg) s

let json_field key : Yojson.Safe.t t =
  let%bind j = json in
  match Yojson.Safe.Util.member key j with
  | `Null  -> fail (Printf.sprintf "Field '%s' not found in JSON" key)
  | v      -> return v

let json_string_field key : string t =
  let%bind j = json_field key in
  match j with
  | `String v -> return v
  | other -> fail (Printf.sprintf "Field '%s' is not a string: %s"
                  key (Yojson.Safe.to_string other))

let list : string list t = fun s ->
  return (s
      |> String.split_on_char '\n'
      |> List.map String.trim
      |> List.filter (fun l -> l <> "")) s

let numbered_list : string list t = fun s ->
  let open Re in
  let parse_numbered s =
    let re = 
      compile (seq [
        bos |> opt;
        rep space;
        rep1 digit;
        alt [char '.'; char ')'];
        rep1 space;
        group (rep1 any);
      ]) in
    let lines = String.split_on_char '\n' s in
    let items = List.filter_map (fun line ->
      match exec_opt re (String.trim line) with
      | Some m -> Some (String.trim (Group.get m 1))
      | None   -> None
    ) lines in
    if items = [] then Error "No numbered items found"
    else Ok items
  in
  (parse_numbered <|> list) s

let bool : bool t = fun s ->
  match String.lowercase_ascii (String.trim s) with
  | "yes" | "true"  | "1" | "y" -> return true s
  | "no"  | "false" | "0" | "n" -> return false s
  | other -> fail ("Cannot parse bool from: " ^ other) s

let int_val : int t = fun s ->
  let open Re in
  let s_trim = String.trim s in
  let re = 
    compile (seq [opt (char '-'); rep1 digit]) 
  in
  match exec_opt re s_trim with
  | None   -> fail ("No integer found in: " ^ s_trim) s
  | Some m -> return (int_of_string (Group.get m 0)) s

let float_val : float t = fun s ->
  let open Re in
  let s_trim = String.trim s in
  let re = 
    compile (seq [
      opt (char '-');
      rep1 digit;
      opt (seq [char '.'; rep1 digit]);
    ]) 
  in
  match exec_opt re s_trim with
  | None   -> fail ("No float found in: " ^ s_trim) s
  | Some m -> return (float_of_string (Group.get m 0)) s

(** Strips markdown code fences from the response. *)
let extract_code ?lang : string t = fun s ->
  let open Re in
  let lang_pat = match lang with
    | None   -> rep (compl [char '\n'])
    | Some l -> str l
  in
  let re = 
    compile (seq [
      str "```";
      lang_pat;
      char '\n';
      group (rep any);
      str "```";
    ]) 
  in
  match exec_opt re s with
  | Some m -> return (String.trim (Group.get m 1)) s
  | None   ->
    let re2 = 
      compile (seq [
        char '`';
        group (rep1 (compl [char '`']));
        char '`';
      ]) 
    in
    (match exec_opt re2 s with
     | Some m -> return (Group.get m 1) s
     | None   -> return (String.trim s) s)

let first_line : string t =
  let%bind lines = list in
  match lines with
  | [] -> return ""
  | h :: _ -> return h

let regex_capture ~pattern : string t = fun s ->
  let open Re in
  let re = compile (Pcre.re pattern) in
  match exec_opt re s with
  | None   -> fail (Printf.sprintf "Pattern /%s/ did not match" pattern) s
  | Some m ->
    (try return (Group.get m 1) s
     with Not_found ->
       try return (Group.get m 0) s
       with Not_found -> fail "No capture group in match" s)

let json_array_strings : string list t =
  let%bind items = json in
  match items with
  | `List l ->
    return (List.filter_map (function
      | `String s -> Some s
      | _ -> None) l)
  | _ -> fail "Expected a JSON array"

let run p s = p s

let run_exn p s =
  match p s with
  | Ok v    -> v
  | Error e -> failwith e
