(** Typed output parsers for LLM responses. *)

type 'a parse_result = ('a, string) result
type 'a t = string -> 'a parse_result

let map f p s = Result.map f (p s)

let and_then f p s = match p s with
  | Error e -> Error e
  | Ok v    -> f v s

let (>|=) p f = map f p
let (>>=) p f = and_then f p

let return v _s = Ok v
let fail msg _s = Error msg

let or_else p1 p2 s = match p1 s with
  | Ok _ as ok -> ok
  | Error _    -> p2 s

let (<|>) = or_else

let ap pf pa =
  pf >>= fun f ->
  pa >|= fun a ->
  f a

let (<*>) = ap

let product pa pb =
  pa >>= fun a ->
  pb >|= fun b ->
  (a, b)

let string : string t = fun s -> return s s

let trimmed : string t = fun s -> return (String.trim s) s

let json : Yojson.Safe.t t = fun s ->
  try return (Yojson.Safe.from_string (String.trim s)) s
  with Yojson.Json_error msg -> fail ("JSON parse error: " ^ msg) s

let json_field key : Yojson.Safe.t t =
  json >>= fun j s ->
  match Yojson.Safe.Util.member key j with
  | `Null  -> fail (Printf.sprintf "Field '%s' not found in JSON" key) s
  | v      -> return v s

let json_string_field key : string t =
  json_field key >>= function
  | `String v -> return v
  | other -> fun s -> fail (Printf.sprintf "Field '%s' is not a string: %s"
                  key (Yojson.Safe.to_string other)) s

let list : string list t = fun s ->
  return (s
      |> String.split_on_char '\n'
      |> List.map String.trim
      |> List.filter (fun l -> l <> "")) s

let numbered_list : string list t = fun s ->
  let parse_numbered s =
    let re = 
      let open Re in
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
      match Re.exec_opt re (String.trim line) with
      | Some m -> Some (String.trim (Re.Group.get m 1))
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
  let s_trim = String.trim s in
  let re = 
    let open Re in
    compile (seq [opt (char '-'); rep1 digit]) 
  in
  match Re.exec_opt re s_trim with
  | None   -> fail ("No integer found in: " ^ s_trim) s
  | Some m -> return (int_of_string (Re.Group.get m 0)) s

let float_val : float t = fun s ->
  let s_trim = String.trim s in
  let re = 
    let open Re in
    compile (seq [
      opt (char '-');
      rep1 digit;
      opt (seq [char '.'; rep1 digit]);
    ]) 
  in
  match Re.exec_opt re s_trim with
  | None   -> fail ("No float found in: " ^ s_trim) s
  | Some m -> return (float_of_string (Re.Group.get m 0)) s

(** Strips markdown code fences from the response. *)
let extract_code ?lang : string t = fun s ->
  let lang_pat = match lang with
    | None   -> Re.rep (Re.compl [Re.char '\n'])
    | Some l -> Re.str l
  in
  let re = 
    let open Re in
    compile (seq [
      str "```";
      lang_pat;
      char '\n';
      group (rep any);
      str "```";
    ]) 
  in
  match Re.exec_opt re s with
  | Some m -> return (String.trim (Re.Group.get m 1)) s
  | None   ->
    let re2 = 
      let open Re in
      compile (seq [
        char '`';
        group (rep1 (compl [char '`']));
        char '`';
      ]) 
    in
    (match Re.exec_opt re2 s with
     | Some m -> return (Re.Group.get m 1) s
     | None   -> return (String.trim s) s)

let first_line : string t =
  list >>= function
  | [] -> return ""
  | h :: _ -> return h

let regex_capture ~pattern : string t = fun s ->
  let re = Re.compile (Re.Pcre.re pattern) in
  match Re.exec_opt re s with
  | None   -> fail (Printf.sprintf "Pattern /%s/ did not match" pattern) s
  | Some m ->
    (try return (Re.Group.get m 1) s
     with Not_found ->
       try return (Re.Group.get m 0) s
       with Not_found -> fail "No capture group in match" s)

let json_array_strings : string list t =
  json >>= function
  | `List items ->
    return (List.filter_map (function
      | `String s -> Some s
      | _ -> None) items)
  | _ -> fail "Expected a JSON array"

let run p s = p s

let run_exn p s =
  match p s with
  | Ok v    -> v
  | Error e -> failwith e
