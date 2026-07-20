type subagent_spec = {
  name : string;
  role : string;
  system_prompt : string;
  tools : Tool.packed_tool list;
}

let delegate net clock parent_sess spec task =
  let child_sess = Session.create ~tools:spec.tools spec.name (Session.provider parent_sess) in
  let child_sess' = Session.set_system child_sess spec.system_prompt in
  Agent.run net clock child_sess' task

let delegate_parallel net clock parent_sess tasks =
  Eio.Fiber.List.map (fun (spec, task) ->
    delegate net clock parent_sess spec task
  ) tasks
