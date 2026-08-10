let should_compact ~auto_summarize ~memory_size ~history_length ~tool_call_names =
  let explicit = List.exists
    (fun n -> n = "summarize" || n = "compress_history" || n = "summarise")
    tool_call_names
  in
  let overflow =
    auto_summarize
    && memory_size > 0
    && history_length > memory_size
  in
  explicit || overflow
