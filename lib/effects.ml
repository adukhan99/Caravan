type _ Effect.t +=
  | Exec_tool : { tool_name : string; args : string } -> string Effect.t
  | Ask_permission : { tool_name : string; args : string } -> bool Effect.t
  | Log_event : { level : string; message : string } -> unit Effect.t
  | Spawn_subagent : { role : string; task : string } -> (string, string) result Effect.t

let exec_tool tool_name args =
  Effect.perform (Exec_tool { tool_name; args })

let ask_permission tool_name args =
  Effect.perform (Ask_permission { tool_name; args })

let log_event level message =
  Effect.perform (Log_event { level; message })

let spawn_subagent role task =
  Effect.perform (Spawn_subagent { role; task })

let run_with_effects
    ?(permission_policy = fun _ _ -> true)
    ?(on_log = fun _ _ -> ())
    ?(on_exec = fun _ _ -> "No exec handler registered.")
    ?(on_spawn = fun _ _ -> Error "No spawn handler registered.")
    f =
  Effect.Deep.try_with f () {
    effc = fun (type a) (eff : a Effect.t) ->
      match eff with
      | Ask_permission { tool_name; args } ->
        Some (fun (k : (a, _) Effect.Deep.continuation) ->
          let granted = permission_policy tool_name args in
          Effect.Deep.continue k granted)
      | Log_event { level; message } ->
        Some (fun k ->
          on_log level message;
          Effect.Deep.continue k ())
      | Exec_tool { tool_name; args } ->
        Some (fun k ->
          let res = on_exec tool_name args in
          Effect.Deep.continue k res)
      | Spawn_subagent { role; task } ->
        Some (fun k ->
          let res = on_spawn role task in
          Effect.Deep.continue k res)
      | _ -> None
  }
