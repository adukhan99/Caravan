(** Categorical & Modular terminal styling. *)

let is_tty = Unix.isatty Unix.stdout

(* --- Categorical & Modular Rendering Abstractions --- *)

module type RENDERER = sig
  type t
  val empty : t
  val append : t -> t -> t
  val render_styled : Document.style -> t -> t
  val render_text : string -> t
  val compile : t -> string
end

module AnsiRenderer = struct
  type t = string
  let empty = ""
  let append = ( ^ )

  let color_code = function
    | Document.Cyan -> "36"
    | Document.Green -> "32"
    | Document.Yellow -> "33"
    | Document.Magenta -> "35"
    | Document.Red -> "31"
    | Document.Blue -> "34"
    | Document.White -> "97"

  let style_code = function
    | Document.Bold -> "1"
    | Document.Dim -> "2"
    | Document.Underline -> "4"
    | Document.Foreground c -> "1;" ^ color_code c
    | Document.Background c ->
      (match c with
       | Document.Cyan -> "46"
       | Document.Green -> "42"
       | Document.Yellow -> "43"
       | Document.Magenta -> "45"
       | Document.Red -> "41"
       | Document.Blue -> "44"
       | Document.White -> "107")

  let render_styled s t =
    if t = "" then "" else
    let code = style_code s in
    Printf.sprintf "\027[%sm%s\027[0m" code t

  let render_text s = s
  let compile t = t
end

module PlainTextRenderer = struct
  type t = string
  let empty = ""
  let append = ( ^ )
  let render_styled _s t = t
  let render_text s = s
  let compile t = t
end

let compile_document (type r) (module R : RENDERER with type t = r) (fmt_elem : 'a -> r) doc =
  let rec loop = function
    | Document.Empty -> R.empty
    | Document.Text x -> fmt_elem x
    | Document.Styled (st, d) -> R.render_styled st (loop d)
    | Document.Concat docs ->
      List.fold_left (fun acc d ->
        R.append acc (loop d)
      ) R.empty docs
  in
  loop doc

module TermRenderer = struct
  type t = string
  let empty = ""
  let append = ( ^ )
  let render_styled s t =
    if is_tty then AnsiRenderer.render_styled s t
    else PlainTextRenderer.render_styled s t
  let render_text s = s
  let compile t = t
end

(* --- Type-Safe Style API Wrappers --- *)

let style_doc style s =
  compile_document (module TermRenderer) (fun x -> x) (Document.Styled (style, Document.Text s))

let bold s      = style_doc Document.Bold s
let dim s       = style_doc Document.Dim s
let underline s = style_doc Document.Underline s
let cyan s      = style_doc (Document.Foreground Document.Cyan) s
let green s     = style_doc (Document.Foreground Document.Green) s
let yellow s    = style_doc (Document.Foreground Document.Yellow) s
let magenta s   = style_doc (Document.Foreground Document.Magenta) s
let red s       = style_doc (Document.Foreground Document.Red) s
let white s     = style_doc (Document.Foreground Document.White) s
let blue s      = style_doc (Document.Foreground Document.Blue) s

let print_ansi s = print_string s
let println_ansi s = print_endline s

let print_banner () =
  if is_tty then begin
    println_ansi (cyan "╔═════════════════════════════════════════════════╗");
    println_ansi (cyan "║  "  ^ bold (white "Caravan") ^ white "   v0.1  —  Typed LLM Orchestration     " ^ cyan "║");
    println_ansi (cyan "╚═════════════════════════════════════════════════╝");
    print_newline ()
  end

let print_help cmds =
  println_ansi (bold (yellow " Slash Commands:"));
  List.iter (fun (cmd, desc) ->
    println_ansi (Printf.sprintf "  %s  %s"
      (cyan (Printf.sprintf "%-22s" cmd))
      (dim desc))
  ) cmds;
  print_newline ()

module MakeTheme (R : RENDERER) = struct
  let keyword s = R.render_styled Document.Bold (R.render_text s)
  let error s = R.render_styled (Document.Foreground Document.Red) (R.render_text s)
  let title s = R.render_styled (Document.Foreground Document.Cyan) (R.render_styled Document.Bold (R.render_text s))
  let success s = R.render_styled (Document.Foreground Document.Green) (R.render_text s)
end

(* ── Spinner ──────────────────────────────────────────────────────────────── *)

module Spinner = struct
  (** Braille arc — the classic ten-frame dot sweep. *)
  let braille = [| "⠋"; "⠙"; "⠹"; "⠸"; "⠼"; "⠴"; "⠦"; "⠧"; "⠇"; "⠏" |]

  type config = {
    frames   : string array;
    colors   : (string -> string) array;
    interval : float;  (** seconds per frame *)
  }

  (** OCaml amber + warm tones — used while the LLM is thinking. *)
  let thinking = {
    frames   = braille;
    colors   = [| yellow; (fun s -> style_doc (Document.Foreground Document.Red) s);
                  magenta; cyan; yellow |];
    interval = 0.08;
  }

  (** Caravan teal/cyan palette — used while a tool is executing. *)
  let tool = {
    frames   = braille;
    colors   = [| cyan; blue; green; cyan; blue |];
    interval = 0.07;
  }

  (** Purple / magenta — used during context summarisation. *)
  let summarize = {
    frames   = braille;
    colors   = [| magenta; blue; cyan; magenta; blue |];
    interval = 0.09;
  }

  (** Green / teal — used for network fetches. *)
  let fetch = {
    frames   = braille;
    colors   = [| green; cyan; blue; green; cyan |];
    interval = 0.08;
  }

  (** Yellow / white — used for web searches. *)
  let search = {
    frames   = braille;
    colors   = [| yellow; white; cyan; yellow; white |];
    interval = 0.08;
  }

  (** Neutral fallback for unknown tools. *)
  let default = {
    frames   = braille;
    colors   = [| white; yellow; cyan; magenta; blue |];
    interval = 0.08;
  }

  (** Select a preset by the tool/context name forwarded from Config. *)
  let of_verb verb =
    let lv = String.lowercase_ascii verb in
    if String.length lv >= 7 && String.sub lv 0 7 = "thinkin" then thinking
    else if String.length lv >= 5 && String.sub lv 0 5 = "summa"  then summarize
    else if String.length lv >= 5 && String.sub lv 0 5 = "fetch"  then fetch
    else if String.length lv >= 6 && String.sub lv 0 6 = "search" then search
    else if String.length lv >= 7 && String.sub lv 0 7 = "running" then tool
    else if String.length lv >= 7 && String.sub lv 0 7 = "executi" then tool
    else default
end

(** Infinite braille render loop — intended to be raced via [Fiber.first].
    Eio's cancellation will interrupt [sleep] and [Fun.protect] clears the line. *)
let spinner_loop clock cfg verb =
  Fun.protect
    ~finally:(fun () -> Printf.eprintf "\r\027[K%!")
    (fun () ->
       let rec loop idx =
         let frame    = cfg.Spinner.frames.(idx mod Array.length cfg.Spinner.frames) in
         let color_fn = cfg.Spinner.colors.(idx mod Array.length cfg.Spinner.colors) in
         Printf.eprintf "\r%s %s...%!" (color_fn frame) verb;
         Eio.Time.sleep clock cfg.Spinner.interval;
         loop (idx + 1)
       in
       loop 0)

(** Poll loop — checks [stop] every frame; exits cleanly when it returns [true]. *)
let spinner_poll_loop clock cfg verb stop =
  Fun.protect
    ~finally:(fun () -> Printf.eprintf "\r\027[K%!")
    (fun () ->
       let rec loop idx =
         if stop () then ()
         else begin
           let frame    = cfg.Spinner.frames.(idx mod Array.length cfg.Spinner.frames) in
           let color_fn = cfg.Spinner.colors.(idx mod Array.length cfg.Spinner.colors) in
           Printf.eprintf "\r%s %s...%!" (color_fn frame) verb;
           Eio.Time.sleep clock cfg.Spinner.interval;
           loop (idx + 1)
         end
       in
       loop 0)

(** Run [fn] while showing a spinner; the spinner is cancelled when [fn] returns. *)
let with_spinner clock verb enabled fn =
  if not enabled then fn ()
  else
    let cfg = Spinner.of_verb verb in
    Eio.Fiber.first (fun () -> spinner_loop clock cfg verb) fn

(** Fork a spinner fiber that watches an Eio promise and stops when it resolves. *)
let run_spinner_until_promise sw clock verb enabled promise =
  if enabled then
    Eio.Fiber.fork ~sw (fun () ->
      let cfg = Spinner.of_verb verb in
      spinner_poll_loop clock cfg verb (fun () -> Eio.Promise.is_resolved promise)
    )
