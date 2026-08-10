(** Policy for when to compact conversation history. *)

(** [should_compact ~auto_summarize ~memory_size ~history_length
    ~tool_call_names] returns [true] when the session should be
    compacted after a turn step. *)
val should_compact :
  auto_summarize:bool ->
  memory_size:int ->
  history_length:int ->
  tool_call_names:string list ->
  bool
