(** Prompt template engine. *)

type ast_node =
  | Text of string
  | Var of string

type t = {
  source    : string;
  ast       : ast_node list;
  variables : string list;
}

let var_re = Re.compile (Re.seq [
  Re.str "{{";
  Re.rep1 Re.space |> Re.opt;
  Re.group (Re.rep1 (Re.alt [Re.alnum; Re.char '_']));
  Re.rep1 Re.space |> Re.opt;
  Re.str "}}";
])

let of_string source =
  let ast =
    Re.split_full var_re source
    |> List.map (function
        | `Text t -> Text t
        | `Delim d ->
          let var_name = Re.Group.get d 1 in
          Var var_name
      )
  in
  let variables =
    ast |> List.filter_map (function Var v -> Some v | Text _ -> None)
    |> List.sort_uniq String.compare
  in
  { source; ast; variables }

let render ~vars tmpl =
  let missing =
    List.filter (fun v -> not (List.mem_assoc v vars)) tmpl.variables
  in
  if missing <> [] then
    Error ("Template: missing variables: " ^ String.concat ", " missing)
  else
    Ok (List.map (function
      | Text t -> t
      | Var v  -> List.assoc v vars
    ) tmpl.ast
    |> String.concat "")

let render_exn ~vars tmpl =
  match render ~vars tmpl with
  | Ok s    -> s
  | Error e -> invalid_arg e

let render_string ~vars src = render ~vars (of_string src)

let variables tmpl = tmpl.variables

let source tmpl = tmpl.source

let pp fmt tmpl =
  Format.fprintf fmt "@[<v>Template {@ source = %S;@ variables = [%s]@]}"
    tmpl.source
    (String.concat "; " (List.map (fun v -> "\"" ^ v ^ "\"") tmpl.variables))

type chat_template = {
  system_tmpl : t option;
  human_tmpl  : t;
}

let chat_template ?system human = {
  system_tmpl = Option.map of_string system;
  human_tmpl  = of_string human;
}

let render_chat ~vars tmpl =
  let open Types in
  render ~vars tmpl.human_tmpl >>= fun human_content ->
  (match tmpl.system_tmpl with
   | None -> Ok None
   | Some sys ->
     let sys_vars = List.filter (fun (k, _) -> List.mem k sys.variables) vars in
     render ~vars:sys_vars sys >|= Option.some)
  >|= fun sys_opt ->
  Prompt.(exec (
    let* () = optional sys_opt system in
    user human_content
  ))

let render_chat_exn ~vars tmpl =
  match render_chat ~vars tmpl with
  | Ok msgs -> msgs
  | Error e -> invalid_arg e
