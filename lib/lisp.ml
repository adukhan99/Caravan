(** Slip — Caravan's embedded micro-LISP.

    A tiny, total, sandboxed symbolic engine for neurosymbolic work:
    models offload counting, filtering, arithmetic, and data reshaping to
    an exact evaluator instead of doing it "in their head".

    Design constraints, in order:
    1. {b Simple} — a 2B model must be able to write it. No macros, no
       continuations, no tail-call subtleties; just atoms, lists,
       [lambda], and ~40 named builtins.
    2. {b Total} — every program terminates: evaluation is step-capped
       (default 100k ticks). Recursion is allowed; runaways get a clean
       error instead of hanging the agent loop.
    3. {b Sandboxed} — pure computation over [Value.t] (the JSON
       universe). No IO, no shell, no clock, no randomness.
    4. {b Homoiconic} — programs are the lists they manipulate; [quote]
       turns code into data, [read]/[show]/[eval] round-trip it.

    A program is one or more forms evaluated in sequence ([define] adds
    bindings); the result is the last form's value. Optional input is
    bound to the symbol [data]. *)

type error = string

let max_steps_default = 100_000

(* ── Reader ───────────────────────────────────────────────────────────── *)

type sexp =
  | Atom of string
  | Str  of string          (* distinguished so "1" ≠ 1 and symbols ≠ strings *)
  | SList of sexp list

let parse_error fmt = Printf.ksprintf (fun s -> Error ("parse: " ^ s)) fmt

(** Tokenize: parens, quote, double-quoted strings with escapes, atoms,
    line comments (; …). *)
let tokenize (src : string) : (string list, error) result =
  let len = String.length src in
  let toks = ref [] in
  let buf = Buffer.create 16 in
  let flush_atom () =
    if Buffer.length buf > 0 then begin
      toks := Buffer.contents buf :: !toks;
      Buffer.clear buf
    end
  in
  let rec go i =
    if i >= len then (flush_atom (); Ok (List.rev !toks))
    else match src.[i] with
      | ' ' | '\t' | '\n' | '\r' -> flush_atom (); go (i + 1)
      | ';' ->
        flush_atom ();
        let rec skip j = if j < len && src.[j] <> '\n' then skip (j + 1) else j in
        go (skip i)
      | '(' | ')' | '\'' as c ->
        flush_atom ();
        toks := String.make 1 c :: !toks;
        go (i + 1)
      | '"' ->
        flush_atom ();
        let sb = Buffer.create 16 in
        let rec str j =
          if j >= len then parse_error "unterminated string"
          else match src.[j] with
            | '"' ->
              toks := ("\"" ^ Buffer.contents sb) :: !toks;
              go (j + 1)
            | '\\' when j + 1 < len ->
              let c = match src.[j + 1] with
                | 'n' -> '\n' | 't' -> '\t' | 'r' -> '\r'
                | c -> c
              in
              Buffer.add_char sb c; str (j + 2)
            | c -> Buffer.add_char sb c; str (j + 1)
        in
        str (i + 1)
      | c -> Buffer.add_char buf c; go (i + 1)
  in
  go 0

(** Parse every top-level form in [src]. *)
let read_many (src : string) : (sexp list, error) result =
  match tokenize src with
  | Error e -> Error e
  | Ok toks ->
    let rec form = function
      | [] -> Error "parse: unexpected end of input"
      | "(" :: rest ->
        let rec items acc rest =
          match rest with
          | ")" :: rest' -> Ok (SList (List.rev acc), rest')
          | [] -> parse_error "missing ')'"
          | _ ->
            (match form rest with
             | Ok (s, rest') -> items (s :: acc) rest'
             | Error e -> Error e)
        in
        items [] rest
      | ")" :: _ -> Error "parse: unexpected ')'"
      | "'" :: rest ->
        (match form rest with
         | Ok (s, rest') -> Ok (SList [Atom "quote"; s], rest')
         | Error e -> Error e)
      | tok :: rest ->
        if String.length tok > 0 && tok.[0] = '"'
        then Ok (Str (String.sub tok 1 (String.length tok - 1)), rest)
        else Ok (Atom tok, rest)
    in
    let rec all acc toks =
      match toks with
      | [] -> if acc = [] then Error "parse: empty program" else Ok (List.rev acc)
      | _ ->
        (match form toks with
         | Ok (s, rest) -> all (s :: acc) rest
         | Error e -> Error e)
    in
    all [] toks

(* ── Sexp ⇄ Value (homoiconicity) ─────────────────────────────────────── *)

let rec sexp_to_value : sexp -> Value.t = function
  | Str s -> Value.String s
  | Atom a ->
    (match int_of_string_opt a with
     | Some i -> Value.Int i
     | None ->
       match float_of_string_opt a with
       | Some f -> Value.Float f
       | None ->
         match a with
         | "true" -> Value.Bool true
         | "false" -> Value.Bool false
         | "null" -> Value.Null
         | _ -> Value.String a)   (* quoted symbols become strings *)
  | SList l -> Value.List (List.map sexp_to_value l)

(** Render a value back as program-ish text ([show]). *)
let rec show (v : Value.t) : string =
  match v with
  | Value.String s ->
    if s <> "" &&
       String.for_all (fun c ->
         (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
         || (c >= '0' && c <= '9')
         || c = '+' || c = '-' || c = '*' || c = '/' || c = '_' || c = '?'
         || c = '=' || c = '<' || c = '>' || c = '!') s
       && not (String.for_all (fun c -> c >= '0' && c <= '9') s)
    then s  (* symbol-safe: keeps quoted code re-evaluable *)
    else "\"" ^ String.concat "\\\"" (String.split_on_char '"' s) ^ "\""
  | Value.Int i -> string_of_int i
  | Value.Float f -> Printf.sprintf "%g" f
  | Value.Bool b -> if b then "true" else "false"
  | Value.Null -> "null"
  | Value.List l -> "(" ^ String.concat " " (List.map show l) ^ ")"
  | Value.Record r ->
    "{" ^ String.concat ", "
      (List.map (fun (k, v) -> k ^ ": " ^ show v) r) ^ "}"
  | Value.Degraded (v, _) -> show v

(* ── Evaluator ────────────────────────────────────────────────────────── *)

type closure = {
  params : string list;
  body   : sexp;
  env    : env;
}
and binding =
  | Val  of Value.t
  | Fn   of closure
  | Prim of string          (* a named builtin, first-class for (map f xs) *)
and env = (string * binding) list ref
(* The environment is a mutable assoc list shared down the program so a
   top-level (define f (lambda …)) can recurse into itself; the step cap
   keeps that safe. *)

exception Eval_error of string
exception Out_of_fuel

let builtin_names = [
  "+"; "-"; "*"; "/"; "mod"; "abs"; "min"; "max"; "round"; "sum"; "mean";
  "="; "!="; "<"; ">"; "<="; ">="; "not";
  "str"; "upper"; "lower"; "contains"; "split"; "join";
  "list"; "len"; "count"; "first"; "last"; "nth"; "rest"; "append";
  "reverse"; "range"; "sort"; "map"; "filter"; "reduce";
  "get"; "keys"; "put"; "select"; "where"; "sort-by";
  "number?"; "string?"; "list?"; "record?"; "null?";
  "parse-json"; "to-json"; "read"; "show"; "eval";
]

let is_builtin name = List.mem name builtin_names

let truthy = function
  | Value.Bool false | Value.Null -> false
  | Value.Int 0 -> false
  | _ -> true

let num_op name fi ff a b =
  match a, b with
  | Value.Int x, Value.Int y -> Value.Int (fi x y)
  | Value.Int x, Value.Float y -> Value.Float (ff (float_of_int x) y)
  | Value.Float x, Value.Int y -> Value.Float (ff x (float_of_int y))
  | Value.Float x, Value.Float y -> Value.Float (ff x y)
  | _ -> raise (Eval_error (Printf.sprintf "%s expects numbers, got %s and %s"
                              name (show a) (show b)))

let to_float = function
  | Value.Int i -> float_of_int i
  | Value.Float f -> f
  | v -> raise (Eval_error ("expected a number, got " ^ show v))

let compare_values a b =
  match a, b with
  | Value.Int x, Value.Int y -> compare x y
  | (Value.Int _ | Value.Float _), (Value.Int _ | Value.Float _) ->
    compare (to_float a) (to_float b)
  | Value.String x, Value.String y -> String.compare x y
  | Value.Bool x, Value.Bool y -> compare x y
  | _ -> compare a b

let as_list name = function
  | Value.List l -> l
  | Value.Null -> []
  | v -> raise (Eval_error (name ^ " expects a list, got " ^ show v))

let as_string name = function
  | Value.String s -> s
  | v -> raise (Eval_error (name ^ " expects a string, got " ^ show v))

let expect_val name = function
  | Val v -> v
  | Fn _ | Prim _ ->
    raise (Eval_error (name ^ ": expected a value, got a function"))

let rec eval (fuel : int ref) (env : env) (s : sexp) : binding =
  decr fuel;
  if !fuel <= 0 then raise Out_of_fuel;
  match s with
  | Str str -> Val (Value.String str)
  | Atom a ->
    (match int_of_string_opt a with
     | Some i -> Val (Value.Int i)
     | None ->
       match float_of_string_opt a with
       | Some f -> Val (Value.Float f)
       | None ->
         match a with
         | "true" -> Val (Value.Bool true)
         | "false" -> Val (Value.Bool false)
         | "null" -> Val Value.Null
         | _ ->
           (match List.assoc_opt a !env with
            | Some b -> b
            | None ->
              if is_builtin a then Prim a
              else raise (Eval_error ("unbound symbol: " ^ a))))
  | SList [] -> Val Value.Null
  | SList (head :: args) ->
    (match head with
     | Atom "quote" ->
       (match args with
        | [x] -> Val (sexp_to_value x)
        | _ -> raise (Eval_error "quote takes exactly one argument"))
     | Atom "if" ->
       (match args with
        | [c; t] ->
          if truthy (eval_value fuel env c) then eval fuel env t else Val Value.Null
        | [c; t; e] ->
          if truthy (eval_value fuel env c) then eval fuel env t else eval fuel env e
        | _ -> raise (Eval_error "if takes (if cond then else?)"))
     | Atom "and" ->
       let rec go = function
         | [] -> Val (Value.Bool true)
         | [x] -> eval fuel env x
         | x :: rest -> if truthy (eval_value fuel env x) then go rest
                        else Val (Value.Bool false)
       in go args
     | Atom "or" ->
       let rec go = function
         | [] -> Val (Value.Bool false)
         | x :: rest ->
           let b = eval fuel env x in
           (match b with
            | Val v when truthy v -> b
            | Fn _ | Prim _ -> b
            | _ -> go rest)
       in go args
     | Atom "let" ->
       (match args with
        | SList bindings :: body when body <> [] ->
          let scope = ref !env in
          List.iter (function
            | SList [Atom name; expr] ->
              scope := (name, eval fuel scope expr) :: !scope
            | _ -> raise (Eval_error "let bindings look like ((name expr) …)")
          ) bindings;
          eval_body fuel scope body
        | _ -> raise (Eval_error "let looks like (let ((x 1) (y 2)) body)"))
     | Atom "define" ->
       (match args with
        | [Atom name; expr] ->
          let b = eval fuel env expr in
          env := (name, b) :: !env;
          Val Value.Null
        | _ -> raise (Eval_error "define looks like (define name expr)"))
     | Atom "lambda" | Atom "fn" ->
       (match args with
        | SList params :: body when body <> [] ->
          let names = List.map (function
            | Atom n -> n
            | _ -> raise (Eval_error "lambda parameters must be symbols")) params
          in
          let body = match body with [b] -> b | bs -> SList (Atom "do" :: bs) in
          Fn { params = names; body; env }
        | _ -> raise (Eval_error "lambda looks like (lambda (x y) body)"))
     | Atom "do" | Atom "begin" ->
       eval_body fuel env args
     | _ ->
       let f = eval fuel env head in
       let argb = List.map (fun a -> eval fuel env a) args in
       apply fuel f argb)

and eval_value fuel env s : Value.t =
  expect_val "expression" (eval fuel env s)

and eval_body fuel env body : binding =
  match body with
  | [] -> Val Value.Null
  | [last] -> eval fuel env last
  | x :: rest -> ignore (eval fuel env x); eval_body fuel env rest

and apply fuel (f : binding) (argb : binding list) : binding =
  decr fuel;
  if !fuel <= 0 then raise Out_of_fuel;
  match f with
  | Fn clo ->
    if List.length clo.params <> List.length argb then
      raise (Eval_error (Printf.sprintf "function expects %d argument(s), got %d"
                           (List.length clo.params) (List.length argb)));
    let scope = ref (List.combine clo.params argb @ !(clo.env)) in
    eval fuel scope clo.body
  | Prim name -> apply_prim fuel name argb
  | Val v -> raise (Eval_error ("not a function: " ^ show v))

and call1 fuel (f : binding) (x : Value.t) : Value.t =
  expect_val "function result" (apply fuel f [Val x])

and call2 fuel (f : binding) (x : Value.t) (y : Value.t) : Value.t =
  expect_val "function result" (apply fuel f [Val x; Val y])

and apply_prim fuel name (argb : binding list) : binding =
  let argv () = List.map (expect_val name) argb in
  let one () = match argb with
    | [x] -> expect_val name x
    | _ -> raise (Eval_error (name ^ " takes 1 argument"))
  in
  let two () = match argv () with
    | [a; b] -> (a, b)
    | _ -> raise (Eval_error (name ^ " takes 2 arguments"))
  in
  let v x = Val x in
  match name with
  (* arithmetic *)
  | "+" -> v (match argv () with
      | [] -> Value.Int 0
      | x :: rest -> List.fold_left (num_op "+" ( + ) ( +. )) x rest)
  | "*" -> v (match argv () with
      | [] -> Value.Int 1
      | x :: rest -> List.fold_left (num_op "*" ( * ) ( *. )) x rest)
  | "-" -> v (match argv () with
      | [Value.Int x] -> Value.Int (-x)
      | [Value.Float x] -> Value.Float (-.x)
      | x :: rest when rest <> [] -> List.fold_left (num_op "-" ( - ) ( -. )) x rest
      | _ -> raise (Eval_error "- takes numbers"))
  | "/" ->
    let (x, y) = two () in
    (match y with
     | Value.Int 0 -> raise (Eval_error "division by zero")
     | Value.Float f when f = 0.0 -> raise (Eval_error "division by zero")
     | _ -> v (Value.Float (to_float x /. to_float y)))
  | "mod" ->
    (match two () with
     | (Value.Int a, Value.Int b) when b <> 0 -> v (Value.Int (a mod b))
     | (_, Value.Int 0) -> raise (Eval_error "mod by zero")
     | _ -> raise (Eval_error "mod takes 2 integers"))
  | "abs" ->
    (match one () with
     | Value.Int i -> v (Value.Int (abs i))
     | Value.Float f -> v (Value.Float (abs_float f))
     | x -> raise (Eval_error ("abs expects a number, got " ^ show x)))
  | "min" | "max" ->
    (* Accept either (min 1 2 3) or (min some-list). *)
    let items = match argv () with
      | [Value.List inner] -> inner
      | l -> l
    in
    let pick = if name = "min"
      then (fun a b -> if compare_values b a < 0 then b else a)
      else (fun a b -> if compare_values b a > 0 then b else a)
    in
    (match items with
     | [] -> raise (Eval_error (name ^ " of nothing"))
     | x :: rest -> v (List.fold_left pick x rest))
  | "round" -> v (Value.Int (int_of_float (Float.round (to_float (one ())))))
  | "sum" ->
    v (List.fold_left (num_op "sum" ( + ) ( +. )) (Value.Int 0)
         (as_list "sum" (one ())))
  | "mean" ->
    (match as_list "mean" (one ()) with
     | [] -> v Value.Null
     | l ->
       let total = List.fold_left (fun acc x -> acc +. to_float x) 0.0 l in
       v (Value.Float (total /. float_of_int (List.length l))))

  (* comparison & logic *)
  | "=" -> let (a, b) = two () in v (Value.Bool (compare_values a b = 0))
  | "!=" -> let (a, b) = two () in v (Value.Bool (compare_values a b <> 0))
  | "<" -> let (a, b) = two () in v (Value.Bool (compare_values a b < 0))
  | ">" -> let (a, b) = two () in v (Value.Bool (compare_values a b > 0))
  | "<=" -> let (a, b) = two () in v (Value.Bool (compare_values a b <= 0))
  | ">=" -> let (a, b) = two () in v (Value.Bool (compare_values a b >= 0))
  | "not" -> v (Value.Bool (not (truthy (one ()))))

  (* strings *)
  | "str" -> v (Value.String (String.concat "" (List.map (fun x ->
      match x with Value.String s -> s | other -> Value.to_string other) (argv ()))))
  | "upper" -> v (Value.String (String.uppercase_ascii (as_string "upper" (one ()))))
  | "lower" -> v (Value.String (String.lowercase_ascii (as_string "lower" (one ()))))
  | "contains" ->
    (match two () with
     | (Value.String hay, Value.String needle) ->
       v (Value.Bool (Re.execp (Re.compile (Re.str needle)) hay))
     | _ -> raise (Eval_error "contains takes 2 strings"))
  | "split" ->
    (match two () with
     | (Value.String s, Value.String sep) when String.length sep = 1 ->
       v (Value.List (String.split_on_char sep.[0] s |> List.map (fun x -> Value.String x)))
     | _ -> raise (Eval_error "split takes a string and a 1-char separator"))
  | "join" ->
    (match two () with
     | (Value.List l, Value.String sep) ->
       v (Value.String (String.concat sep (List.map (function
         | Value.String s -> s | other -> Value.to_string other) l)))
     | _ -> raise (Eval_error "join takes a list and a string"))

  (* lists *)
  | "list" -> v (Value.List (argv ()))
  | "len" | "count" ->
    (match one () with
     | Value.List l -> v (Value.Int (List.length l))
     | Value.String s -> v (Value.Int (String.length s))
     | Value.Record r -> v (Value.Int (List.length r))
     | Value.Null -> v (Value.Int 0)
     | x -> raise (Eval_error ("len expects a list/string/record, got " ^ show x)))
  | "first" -> v (match as_list "first" (one ()) with [] -> Value.Null | x :: _ -> x)
  | "last" -> v (match List.rev (as_list "last" (one ())) with [] -> Value.Null | x :: _ -> x)
  | "nth" ->
    (match two () with
     | (Value.Int i, lv) ->
       let l = as_list "nth" lv in
       v (if i >= 0 && i < List.length l then List.nth l i else Value.Null)
     | _ -> raise (Eval_error "nth takes an index and a list: (nth 0 xs)"))
  | "rest" ->
    v (match as_list "rest" (one ()) with [] -> Value.List [] | _ :: t -> Value.List t)
  | "append" -> v (Value.List (List.concat_map (fun x -> as_list "append" x) (argv ())))
  | "reverse" -> v (Value.List (List.rev (as_list "reverse" (one ()))))
  | "range" ->
    (match two () with
     | (Value.Int a, Value.Int b) when b >= a && b - a <= 100_000 ->
       v (Value.List (List.init (b - a) (fun i -> Value.Int (a + i))))
     | (Value.Int _, Value.Int _) -> raise (Eval_error "range is empty or too large (max 100000)")
     | _ -> raise (Eval_error "range takes 2 integers: (range 0 10)"))
  | "sort" -> v (Value.List (List.sort compare_values (as_list "sort" (one ()))))
  | "map" ->
    (match argb with
     | [f; lb] ->
       let l = as_list "map" (expect_val "map" lb) in
       v (Value.List (List.map (fun x -> call1 fuel f x) l))
     | _ -> raise (Eval_error "map takes a function and a list"))
  | "filter" ->
    (match argb with
     | [f; lb] ->
       let l = as_list "filter" (expect_val "filter" lb) in
       v (Value.List (List.filter (fun x -> truthy (call1 fuel f x)) l))
     | _ -> raise (Eval_error "filter takes a function and a list"))
  | "reduce" ->
    (match argb with
     | [f; init; lb] ->
       let l = as_list "reduce" (expect_val "reduce" lb) in
       v (List.fold_left (fun acc x -> call2 fuel f acc x)
            (expect_val "reduce" init) l)
     | _ -> raise (Eval_error "reduce takes a function, an initial value, and a list"))

  (* records *)
  | "get" ->
    (match two () with
     | (Value.String k, rv) ->
       v (match Value.get_opt k rv with Some x -> x | None -> Value.Null)
     | _ -> raise (Eval_error "get takes a key and a record: (get \"name\" row)"))
  | "keys" ->
    (match one () with
     | Value.Record r -> v (Value.List (List.map (fun (k, _) -> Value.String k) r))
     | x -> raise (Eval_error ("keys expects a record, got " ^ show x)))
  | "put" ->
    (match argv () with
     | [Value.String k; nv; Value.Record r] ->
       v (Value.Record ((k, nv) :: List.remove_assoc k r))
     | _ -> raise (Eval_error "put takes a key, a value, and a record"))
  | "select" ->
    (match argv () with
     | ks_and_rec when List.length ks_and_rec >= 2 ->
       let rec split_last acc = function
         | [x] -> (List.rev acc, x)
         | x :: rest -> split_last (x :: acc) rest
         | [] -> assert false
       in
       let (keys, target) = split_last [] ks_and_rec in
       let key_strs = List.map (function
         | Value.String s -> s
         | other -> Value.to_string other) keys in
       (match Value.select key_strs target with
        | Ok r -> v r
        | Error e -> raise (Eval_error e))
     | _ -> raise (Eval_error "select takes keys then a record/list"))
  | "where" ->
    (match argv () with
     | [Value.String field; target_val; data] ->
       (match Value.where_field field (fun x -> compare_values x target_val = 0) data with
        | Ok r -> v r
        | Error e -> raise (Eval_error e))
     | _ -> raise (Eval_error "where takes a field, a value, and rows: (where \"role\" \"user\" rows)"))
  | "sort-by" ->
    (match two () with
     | (Value.String field, data) ->
       (match Value.sort_by field data with
        | Ok r -> v r | Error e -> raise (Eval_error e))
     | _ -> raise (Eval_error "sort-by takes a field and rows"))

  (* types & json & homoiconicity *)
  | "number?" -> v (Value.Bool (match one () with Value.Int _ | Value.Float _ -> true | _ -> false))
  | "string?" -> v (Value.Bool (match one () with Value.String _ -> true | _ -> false))
  | "list?" -> v (Value.Bool (match one () with Value.List _ -> true | _ -> false))
  | "record?" -> v (Value.Bool (match one () with Value.Record _ -> true | _ -> false))
  | "null?" -> v (Value.Bool (match one () with Value.Null -> true | _ -> false))
  | "parse-json" ->
    (match one () with
     | Value.String s ->
       (try v (Value.of_yojson (Yojson.Safe.from_string s))
        with _ -> raise (Eval_error "parse-json: invalid JSON"))
     | x -> raise (Eval_error ("parse-json expects a string, got " ^ show x)))
  | "to-json" -> v (Value.String (Yojson.Safe.to_string (Value.to_yojson (one ()))))
  | "read" ->
    (match one () with
     | Value.String s ->
       (match read_many s with
        | Ok [single] -> v (sexp_to_value single)
        | Ok many -> v (Value.List (List.map sexp_to_value many))
        | Error e -> raise (Eval_error e))
     | x -> raise (Eval_error ("read expects a string, got " ^ show x)))
  | "show" -> v (Value.String (show (one ())))
  | "eval" ->
    (* Reflection: evaluate quoted code — same fuel, same sandbox. *)
    let data = one () in
    let src = show data in
    (match read_many src with
     | Ok forms ->
       let env' : env = ref [] in
       eval_body fuel env' forms
     | Error e -> raise (Eval_error e))

  | _ -> raise (Eval_error (Printf.sprintf "unknown function '%s'" name))

(* ── Entry points ─────────────────────────────────────────────────────── *)

(** Evaluate a program (one or more forms). [data], when given, is bound
    to the symbol [data]. Returns the last form's value. *)
let run ?(max_steps = max_steps_default) ?data (src : string)
  : (Value.t, error) result =
  match read_many src with
  | Error e -> Error e
  | Ok forms ->
    let fuel = ref max_steps in
    let env : env = ref [] in
    (match data with
     | Some d -> env := ("data", Val d) :: !env
     | None -> ());
    (try
       match eval_body fuel env forms with
       | Val v -> Ok v
       | Fn _ | Prim _ -> Error "program returned a function; return a value instead"
     with
     | Eval_error e -> Error e
     | Out_of_fuel ->
       Error (Printf.sprintf "step budget exceeded (%d steps) — simplify the program" max_steps)
     | Stack_overflow -> Error "recursion too deep — simplify the program")

(** Convenience: run and render the result as a display string. *)
let run_to_string ?max_steps ?data src =
  match run ?max_steps ?data src with
  | Ok (Value.String s) -> Ok s
  | Ok v -> Ok (show v)
  | Error e -> Error e

(** One-line-per-area cheat sheet, embedded in the tool description so
    even small models have the full language in-context. *)
let cheat_sheet =
  "FORMS: (if c a b) (let ((x 1)) body) (define name expr) (lambda (x) body) \
   (do e1 e2) (quote x) or 'x\n\
   MATH: + - * / mod abs min max round sum mean  COMPARE: = != < > <= >= not and or\n\
   LISTS: (list 1 2) (len xs) (first xs) (last xs) (nth 0 xs) (rest xs) (append a b) \
   (reverse xs) (range 0 10) (sort xs) (map f xs) (filter f xs) (reduce f init xs)\n\
   RECORDS: (get \"k\" r) (keys r) (put \"k\" v r) (select \"a\" \"b\" rows) \
   (where \"field\" value rows) (sort-by \"field\" rows)\n\
   STRINGS: (str a b) (upper s) (lower s) (contains s sub) (split s \",\") (join xs \", \")\n\
   TYPES/JSON: number? string? list? record? null? (parse-json s) (to-json x)\n\
   CODE-AS-DATA: (read \"(+ 1 2)\") (show x) (eval '(+ 1 2))\n\
   Input data (when provided) is bound to the symbol `data`."
