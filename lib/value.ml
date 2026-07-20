open Types

type t =
  | String of string
  | Int of int
  | Float of float
  | Bool of bool
  | List of t list
  | Record of (string * t) list
  | Null
  | Degraded of t * string

let null = Null
let string s = String s
let int i = Int i
let float f = Float f
let bool b = Bool b
let list l = List l
let record r = Record r

let rec to_string = function
  | String s -> s
  | Int i -> string_of_int i
  | Float f -> string_of_float f
  | Bool b -> string_of_bool b
  | Null -> ""
  | Degraded (v, _) -> to_string v
  | List l -> "[" ^ String.concat ", " (List.map to_string l) ^ "]"
  | Record r ->
    "{" ^ String.concat ", " (List.map (fun (k, v) -> k ^ ": " ^ to_string v) r) ^ "}"

let rec to_int_opt = function
  | Int i -> Some i
  | Float f -> Some (int_of_float f)
  | String s -> int_of_string_opt (String.trim s)
  | Bool b -> Some (if b then 1 else 0)
  | Degraded (v, _) -> to_int_opt v
  | _ -> None

and to_float_opt = function
  | Float f -> Some f
  | Int i -> Some (float_of_int i)
  | String s -> float_of_string_opt (String.trim s)
  | Degraded (v, _) -> to_float_opt v
  | _ -> None

and to_bool_opt = function
  | Bool b -> Some b
  | Int i -> Some (i <> 0)
  | String s ->
    (match String.lowercase_ascii (String.trim s) with
     | "true" | "yes" | "1" | "y" -> Some true
     | "false" | "no" | "0" | "n" -> Some false
     | _ -> None)
  | Degraded (v, _) -> to_bool_opt v
  | _ -> None

and to_list = function
  | List l -> l
  | Null -> []
  | Degraded (v, _) -> to_list v
  | v -> [v]

and to_record = function
  | Record r -> r
  | Degraded (v, _) -> to_record v
  | _ -> []

let rec of_yojson : Yojson.Safe.t -> t = function
  | `Null -> Null
  | `Bool b -> Bool b
  | `Int i -> Int i
  | `Float f -> Float f
  | `String s -> String s
  | `List l -> List (List.map of_yojson l)
  | `Assoc kvs -> Record (List.map (fun (k, v) -> (k, of_yojson v)) kvs)
  | `Intlit s ->
    (match int_of_string_opt s with
     | Some i -> Int i
     | None -> String s)
  | other -> String (Yojson.Safe.to_string other)

let rec to_yojson : t -> Yojson.Safe.t = function
  | Null -> `Null
  | Bool b -> `Bool b
  | Int i -> `Int i
  | Float f -> `Float f
  | String s -> `String s
  | List l -> `List (List.map to_yojson l)
  | Record r -> `Assoc (List.map (fun (k, v) -> (k, to_yojson v)) r)
  | Degraded (v, _) -> to_yojson v

let strip_code_fences s =
  let s_trim = String.trim s in
  let open Re in
  let re = compile (seq [str "```"; opt (rep (compl [char '\n'])); char '\n'; group (rep any); str "```"]) in
  match exec_opt re s_trim with
  | Some m -> String.trim (Group.get m 1)
  | None -> s_trim

let of_string_permissive s =
  let cleaned = strip_code_fences s in
  try of_yojson (Yojson.Safe.from_string cleaned)
  with _ -> String cleaned

let rec get key = function
  | Record r ->
    (match List.assoc_opt key r with
     | Some v -> Ok v
     | None -> Error (Printf.sprintf "Key '%s' not found in record" key))
  | Degraded (v, _) -> get key v
  | _ -> Error (Printf.sprintf "Cannot get key '%s' from non-record value" key)

let get_opt key v =
  match get key v with
  | Ok res -> Some res
  | Error _ -> None

let rec select keys v =
  let select_single_record r =
    Record (List.filter_map (fun k ->
      match List.assoc_opt k r with
      | Some val_ -> Some (k, val_)
      | None -> None
    ) keys)
  in
  match v with
  | Record r -> Ok (select_single_record r)
  | List l ->
    let selected = List.map (function
      | Record r -> select_single_record r
      | other -> other
    ) l in
    Ok (List selected)
  | Degraded (inner, _) -> select keys inner
  | _ -> Error "Select expected a Record or List of Records"

let rec where_field field pred = function
  | List l ->
    let filtered = List.filter (fun item ->
      match get_opt field item with
      | Some v -> pred v
      | None -> false
    ) l in
    Ok (List filtered)
  | Record r as rec_val ->
    (match get_opt field rec_val with
     | Some v when pred v -> Ok rec_val
     | _ -> Ok (List []))
  | Degraded (inner, _) -> where_field field pred inner
  | _ -> Error "where_field expected a List or Record"

let rec sort_by field ?(desc=false) = function
  | List l ->
    let cmp a b =
      let val_a = get_opt field a in
      let val_b = get_opt field b in
      let res = match val_a, val_b with
        | Some (Int i1), Some (Int i2) -> compare i1 i2
        | Some (Float f1), Some (Float f2) -> compare f1 f2
        | Some (String s1), Some (String s2) -> String.compare s1 s2
        | _ -> compare (Option.map to_string val_a) (Option.map to_string val_b)
      in
      if desc then -res else res
    in
    Ok (List (List.sort cmp l))
  | Degraded (inner, _) -> sort_by field ~desc inner
  | v -> Ok v

type sexp =
  | Atom of string
  | SList of sexp list

let parse_sexp s =
  let buf = Buffer.create (String.length s) in
  let tokens = ref [] in
  let i = ref 0 in
  let len = String.length s in
  while !i < len do
    match s.[!i] with
    | ' ' | '\t' | '\n' | '\r' -> incr i
    | '(' -> tokens := "(" :: !tokens; incr i
    | ')' -> tokens := ")" :: !tokens; incr i
    | '"' ->
      Buffer.clear buf;
      incr i;
      while !i < len && s.[!i] <> '"' do
        if s.[!i] = '\\' && !i + 1 < len then incr i;
        Buffer.add_char buf s.[!i];
        incr i
      done;
      if !i < len && s.[!i] = '"' then incr i;
      tokens := ("\"" ^ Buffer.contents buf ^ "\"") :: !tokens
    | _ ->
      Buffer.clear buf;
      while !i < len && not (List.mem s.[!i] [' '; '\t'; '\n'; '\r'; '('; ')']) do
        Buffer.add_char buf s.[!i];
        incr i
      done;
      tokens := Buffer.contents buf :: !tokens
  done;
  let toks = List.rev !tokens in
  let rec parse_list acc = function
    | [] -> (List.rev acc, [])
    | ")" :: rest -> (List.rev acc, rest)
    | "(" :: rest ->
      let (sub, rest') = parse_list [] rest in
      parse_list (SList sub :: acc) rest'
    | atom :: rest ->
      parse_list (Atom atom :: acc) rest
  in
  match toks with
  | "(" :: rest ->
    let (sub, _) = parse_list [] rest in
    Ok (SList sub)
  | atom :: _ -> Ok (Atom atom)
  | [] -> Error "Empty expression"

let eval_lisp expr_str ctx =
  match parse_sexp expr_str with
  | Error e -> Error e
  | Ok sexp ->
    let rec eval = function
      | Atom a when String.length a >= 2 && a.[0] = '"' && a.[String.length a - 1] = '"' ->
        Ok (String (String.sub a 1 (String.length a - 2)))
      | Atom a ->
        (match int_of_string_opt a with
         | Some i -> Ok (Int i)
         | None ->
           (match float_of_string_opt a with
            | Some f -> Ok (Float f)
            | None ->
              (match String.lowercase_ascii a with
               | "true" -> Ok (Bool true)
               | "false" -> Ok (Bool false)
               | "null" -> Ok Null
               | _ ->
                 (match get_opt a ctx with
                  | Some v -> Ok v
                  | None -> Ok (String a)))))
      | SList [] -> Ok Null
      | SList (Atom "get" :: Atom key :: _) -> get key ctx
      | SList (Atom "get" :: sub_expr :: _) ->
        (match eval sub_expr with
         | Ok (String key) -> get key ctx
         | Ok other -> get (to_string other) ctx
         | Error e -> Error e)
      | SList (Atom "select" :: keys) ->
        let key_strs = List.map (function Atom k -> k | sexp -> to_string (match eval sexp with Ok v -> v | Error _ -> Null)) keys in
        select key_strs ctx
      | SList (Atom "count" :: _) ->
        Ok (Int (List.length (to_list ctx)))
      | SList (Atom "first" :: _) ->
        (match to_list ctx with
         | h :: _ -> Ok h
         | [] -> Ok Null)
      | SList (Atom "last" :: _) ->
        (match List.rev (to_list ctx) with
         | h :: _ -> Ok h
         | [] -> Ok Null)
      | SList (Atom "where" :: Atom field :: sub_val :: _) ->
        let target_val = match eval sub_val with Ok v -> v | Error _ -> Null in
        where_field field (fun v -> v = target_val) ctx
      | SList fn_list ->
        Error ("Unsupported LISP expression: " ^ String.concat " " (List.map (function Atom a -> a | _ -> "(...)") fn_list))
    in
    eval sexp

let pp fmt v =
  Yojson.Safe.pretty_print fmt (to_yojson v)

let to_pretty_string v =
  Yojson.Safe.pretty_to_string (to_yojson v)
