(** Styled Document Category-Theory Abstractions. *)

type color =
  | Cyan
  | Green
  | Yellow
  | Magenta
  | Red
  | Blue
  | White

type style =
  | Bold
  | Dim
  | Underline
  | Foreground of color
  | Background of color

type 'a document =
  | Empty
  | Text of 'a
  | Styled of style * 'a document
  | Concat of 'a document list

module Document = struct
  type 'a t = 'a document

  let rec map f = function
    | Empty -> Empty
    | Text x -> Text (f x)
    | Styled (st, doc) -> Styled (st, map f doc)
    | Concat docs -> Concat (List.map (map f) docs)
end

module DocumentMonoid = struct
  type 'a t = 'a document

  let empty = Empty

  let append doc1 doc2 =
    match doc1, doc2 with
    | Empty, d | d, Empty -> d
    | Concat l1, Concat l2 -> Concat (l1 @ l2)
    | Concat l1, d -> Concat (l1 @ [d])
    | d, Concat l2 -> Concat (d :: l2)
    | d1, d2 -> Concat [d1; d2]
end
