(** Structured data representation and LISPy query pipeline for Caravan. *)

type t =
  | String of string
  | Int of int
  | Float of float
  | Bool of bool
  | List of t list
  | Record of (string * t) list
  | Null
  | Degraded of t * string

val null : t
val string : string -> t
val int : int -> t
val float : float -> t
val bool : bool -> t
val list : t list -> t
val record : (string * t) list -> t

val to_string : t -> string
val to_int_opt : t -> int option
val to_float_opt : t -> float option
val to_bool_opt : t -> bool option
val to_list : t -> t list
val to_record : t -> (string * t) list

val of_yojson : Yojson.Safe.t -> t
val to_yojson : t -> Yojson.Safe.t

val of_string_permissive : string -> t

(** Query & Structured Data Operations *)
val get : string -> t -> (t, string) result
val get_opt : string -> t -> t option
val select : string list -> t -> (t, string) result
val where_field : string -> (t -> bool) -> t -> (t, string) result
val sort_by : string -> ?desc:bool -> t -> (t, string) result

(** LISPy Expression Evaluation on Structured Data *)
val eval_lisp : string -> t -> (t, string) result

val pp : Format.formatter -> t -> unit
val to_pretty_string : t -> string
