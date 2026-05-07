(** ANSI terminal styling. *)

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
