(** Profunctor Formatter Abstraction. *)

type ('a, 'b) t = 'a -> 'b Document.document

module Formatter = struct
  type ('a, 'b) f = ('a, 'b) t

  let dimap (f : 'c -> 'a) (g : 'b -> 'd) (fmt : ('a, 'b) f) : ('c, 'd) f =
    fun x -> Document.Document.map g (fmt (f x))
end
