open Types

type t = {
  client     : Redis_sync.Client.connection;
  session_id : string;
  window     : int;
}

let create ~host ~port ~session_id () =
  let spec   = { Redis_sync.Client.host; port } in
  let client = Redis_sync.Client.connect spec in
  { client; session_id; window = max_int }

let add mem msg =
  let json_str = Yojson.Safe.to_string (chat_message_to_json msg) in
  let _pushed  = Redis_sync.Client.rpush mem.client mem.session_id [json_str] in
  mem

let get mem =
  let start = if mem.window = max_int then 0 else -(mem.window) in
  let items  = Redis_sync.Client.lrange mem.client mem.session_id start (-1) in
  List.map (fun s -> chat_message_of_json (Yojson.Safe.from_string s)) items

let clear mem =
  let _deleted = Redis_sync.Client.del mem.client [mem.session_id] in
  mem

let length mem =
  Redis_sync.Client.llen mem.client mem.session_id

let set_window mem w =
  let window = if w = 0 then max_int else w in
  let start = if window = max_int then 0 else -(window) in
  let _     = Redis_sync.Client.ltrim mem.client mem.session_id start (-1) in
  { mem with window }

let to_json mem =
  `List (List.map chat_message_to_json (get mem))

let of_json _json =
  invalid_arg
    "Redis_store.of_json: cannot deserialise a Redis store without \
     connection parameters – construct a store with \
     Redis_store.create ~host ~port ~session_id () instead"
