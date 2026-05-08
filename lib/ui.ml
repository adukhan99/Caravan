(** ANSI terminal styling. *)

let is_tty = Unix.isatty Unix.stdout

let ansi code s = Printf.sprintf "\027[%sm%s\027[0m" code s

let bold s    = ansi "1" s
let dim s     = ansi "2" s
let cyan s    = ansi "1;36" s
let green s   = ansi "1;32" s
let yellow s  = ansi "1;33" s
let magenta s = ansi "1;35" s
let red s     = ansi "1;31" s
let white s   = ansi "0;97" s
let blue s    = ansi "0;34" s

let print_ansi s =
  if is_tty then print_string s
  else
    let re = Re.compile (Re.seq [
      Re.char '\027'; Re.char '[';
      Re.rep (Re.compl [Re.char 'm']); Re.char 'm'
    ]) in
    print_string (Re.replace_string re ~by:"" s)

let println_ansi s = print_ansi s; print_char '\n'

let print_banner () =
  if is_tty then begin
    println_ansi (cyan "╔═════════════════════════════════════════════════╗");
    println_ansi (cyan "║  " ^ bold (white "OrchCaml") ^ white "  v0.1  —  Typed LLM Orchestration     " ^ cyan "║");
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
