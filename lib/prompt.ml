(** Composable conversation building via a Writer monad. *)

open Types

type 'a t = unit -> 'a * chat_message list

let return x () = (x, [])

let bind (m : 'a t) (f : 'a -> 'b t) : 'b t =
  fun () ->
    let (a, msgs_a) = m () in
    let (b, msgs_b) = (f a) () in
    (b, msgs_a @ msgs_b)

let (let*) = bind

let map f m () =
  let (a, msgs) = m () in
  (f a, msgs)

let (>|=) m f = map f m

let tell msg () = ((), [msg])

let tell_all msgs () = ((), msgs)

let system content = tell (system_msg content)

let user content = tell (user_msg content)

let assistant content = tell (assistant_msg content)

let tool_result id content = tell (tool_msg id content)

let when_ cond p = if cond then p else return ()

let unless cond p = when_ (not cond) p

let optional opt_str f =
  match opt_str with
  | None   -> return ()
  | Some s -> f s

let many xs f =
  List.fold_left (fun acc x ->
    let* () = acc in
    f x
  ) (return ()) xs

let exec p =
  let (_, msgs) = p () in
  msgs

let exec_with p = p ()

let exec_in_session p sess =
  let msgs = exec p in
  let memory = List.fold_left Memory.Buffer.add sess.Session.memory msgs in
  { sess with Session.memory }
