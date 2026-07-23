(** Homogeneous Agent Swarm — Caravan example.

    A single primary orchestrator model dynamically spawns instances of itself
    (clones using the same provider and model) as specialized child agents
    with custom system prompts, roles, and tool permissions.

    Run:
      GEMINI_API_KEY=<key> \
      CARAVAN_CONFIG=examples/homogeneous_agent_swarms/config.toml \
      dune exec examples/homogeneous_agent_swarms/swarm.exe
*)

open Caravan
open Caravan.Types
open Caravan.Tool
open Yojson.Safe.Util

(* ── Pretty printing ──────────────────────────────────────────────────────── *)

let pp_sep () = Printf.printf "\n%s\n%!" (String.make 60 '=')

let pp_result label (result : (Session.t * chat_message result_with_meta, string) result) =
  match result with
  | Error e ->
    Printf.printf "[%s] ✗ ERROR: %s\n%!" label e
  | Ok (_sess, res) ->
    let tok_info = match res.usage with
      | None   -> "usage unknown"
      | Some u -> Printf.sprintf "%d prompt + %d completion = %d total tokens"
                    u.prompt_tokens u.completion_tokens u.total_tokens
    in
    Printf.printf "[%s] ✓ (%s)\n%s\n%!" label tok_info res.value.content

(* ── Provider helpers ─────────────────────────────────────────────────────── *)

(** Build a packed_provider from a [providers.<name>] config section. *)
let provider_of_ref ~name ~model ~options =
  match Config.get_provider_config name with
  | None ->
    Printf.eprintf "[swarm] Warning: no [providers.%s] section — using Ollama defaults\n%!" name;
    CaravanProviders.Ollama.make_provider ~model ()
  | Some pc ->
    let api_key =
      match pc.api_key_env with
      | None -> None
      | Some k ->
        (match Sys.getenv_opt k with
         | Some v when v <> "" -> Some v
         | _ ->
           if String.length k > 10 && not (String.contains k ' ') then Some k
           else None)
    in
    let org_id  = Option.bind pc.org_id_env  Sys.getenv_opt in
    CaravanProviders.Openai_compatible.make_provider
      ~provider_name:name
      ~base_url:pc.base_url
      ~options
      ?api_key
      ?org_id
      ~model
      ()

(* ── SpawnAgent Tool Definition ───────────────────────────────────────────── *)

module SpawnAgent = struct
  let name = "spawn_agent"
  let aliases = ["spawn"; "delegate_self"; "spawn_subagent"]
  let description =
    "Spawn a child agent using the same model and provider to solve a specific sub-task. " ^
    "The child starts cold (no history). You must provide the task details, and optionally " ^
    "a custom system_prompt, a custom role, and a list of tool names the child is permitted to use."

  type input = {
    task : string;
    role : string option;
    system_prompt : string option;
    tools : string list option;
  }
  type output = string

  let json_schema () =
    `Assoc [
      ("type", `String "object");
      ("required", `List [`String "task"]);
      ("properties", `Assoc [
        ("task", `Assoc [
          ("type", `String "string");
          ("description", `String "The self-contained task description for the child agent.");
        ]);
        ("role", `Assoc [
          ("type", `String "string");
          ("description", `String "The role/persona of the child (e.g. 'coder', 'researcher', 'reviewer').");
        ]);
        ("system_prompt", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional custom system prompt/instructions to guide the child's behavior.");
        ]);
        ("tools", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Optional list of tool names the child is allowed to use. E.g. ['bash', 'read_file', 'write_file', 'finish']. If omitted, the child inherits all available tools except spawn_agent itself.");
        ]);
      ]);
    ]

  let parse_args json =
    try
      let task = json |> member "task" |> to_string in
      let role =
        match json |> member "role" with
        | `String r -> Some r
        | _ -> None
      in
      let system_prompt =
        match json |> member "system_prompt" with
        | `String p -> Some p
        | _ -> None
      in
      let tools =
        match json |> member "tools" with
        | `List l -> Some (List.map to_string l)
        | _ -> None
      in
      Ok { task; role; system_prompt; tools }
    with Type_error (msg, _) -> Error ("spawn_agent parse: " ^ msg)

  let format_output s = s

  type _ Effect.t += Exec : input -> output Effect.t
  let execute _input =
    "Error: spawn_agent not initialised."
end

(** Factory function to construct the [spawn_agent] packed tool.
    Uses a reference to break the recursive definition between the tool
    and the list of registered tools it can grant to children. *)
let make_spawn_agent_tool ~net ~clock ~registered_tools_ref ~parent_provider ~parent_model =
  let dispatch (input : SpawnAgent.input) : string =
    let role = Option.value input.role ~default:"subagent" in
    let system_prompt =
      Option.value input.system_prompt
        ~default:"You are a helpful assistant. Solve the task as best as you can."
    in
    let registered_tools = !registered_tools_ref in
    let child_tools =
      match input.tools with
      | None ->
        (* Omit spawn_agent by default to prevent simple infinite loops *)
        List.filter (fun t -> Tool.name_of_packed t <> "spawn_agent") registered_tools
      | Some names ->
        List.filter (fun t ->
          List.mem (Tool.name_of_packed t) names
        ) registered_tools
    in
    (* Ensure 'finish' is always available so the child agent loop can end *)
    let child_tools =
      if List.exists (fun t -> Tool.name_of_packed t = "finish") child_tools then
        child_tools
      else
        match List.find_opt (fun t -> Tool.name_of_packed t = "finish") registered_tools with
        | Some f -> f :: child_tools
        | None -> child_tools
    in

    Printf.printf "\n%s Spawning subagent: %s (model: %s)\n"
      (Ui.cyan "[Swarm]") (Ui.bold role) parent_model;
    Printf.printf "  Tools: %s\n" (List.map Tool.name_of_packed child_tools |> String.concat ", ");
    Printf.printf "  Task: %s\n%!" input.task;

    (* Create and run a fresh child session using the parent's model and provider *)
    let child_sess = Session.create ~tools:child_tools parent_model parent_provider in
    let full_system = system_prompt ^ Caravan.Subagent.compaction_suffix in
    let child_sess = Session.set_system child_sess full_system in

    match Agent.run net clock child_sess input.task with
    | Ok (_sess, result) ->
      Printf.printf "%s Subagent %s completed successfully.\n%!"
        (Ui.green "[Swarm]") (Ui.bold role);
      result.value.content
    | Error msg ->
      let err_msg = Printf.sprintf "Error running subagent '%s': %s" role msg in
      Printf.eprintf "%s %s\n%!" (Ui.red "[Swarm Error]") err_msg;
      err_msg
  in
  Tool (module struct
    let name          = SpawnAgent.name
    let aliases       = SpawnAgent.aliases
    let description   = SpawnAgent.description
    type input        = SpawnAgent.input = { task : string; role : string option; system_prompt : string option; tools : string list option }
    type output       = string
    type _ Effect.t  += Exec : input -> output Effect.t
    let json_schema   = SpawnAgent.json_schema
    let parse_args    = SpawnAgent.parse_args
    let format_output = SpawnAgent.format_output
    let execute inp   = dispatch inp
  end)

(* ── Main Entrypoint ──────────────────────────────────────────────────────── *)

let () =
  Eio_main.run (fun env ->
    let net   = env#net in
    let clock = env#clock in

    (* 1. Read orchestrator config *)
    let (orch_provider_ref, orch_model) =
      Option.value ~default:("gemini", "gemini-2.5-pro") (Config.get_orchestrator ())
    in
    let options = { default_options with temperature = Some 0.2; max_tokens = Some 4096 } in
    let orch_provider = provider_of_ref ~name:orch_provider_ref ~model:orch_model ~options in

    (* 2. Load standard tools *)
    let static_tools = CaravanTools.All_tools.all_tools in

    (* 3. Set up the dynamic spawn tool and register it in the global tool set *)
    let registered_tools_ref = ref [] in
    let spawn_agent_tool =
      make_spawn_agent_tool
        ~net
        ~clock
        ~registered_tools_ref
        ~parent_provider:orch_provider
        ~parent_model:orch_model
    in
    let all_available_tools = spawn_agent_tool :: static_tools in
    registered_tools_ref := all_available_tools;

    (* 4. Orchestrator tools: only finish + spawn_agent.
          It must plan and spawn clones — it does not execute directly. *)
    let finish_tool =
      List.find (fun t -> Tool.name_of_packed t = "finish") static_tools
    in
    let orchestrator_tools = [finish_tool; spawn_agent_tool] in

    (* 5. Initialize the orchestrator session *)
    let orch_system =
      "You are a master orchestrator in a homogeneous agent swarm. Your job is to solve complex tasks \
       by decomposing them and dynamically spawning specialized child agents (clones of yourself) \
       using the 'spawn_agent' tool.\n\
       Rules:\n\
       - Do not execute the tasks yourself. Delegate all actual thinking and coding tasks to child agents.\n\
       - Give each spawned agent a descriptive role, a specific system prompt, and the exact set of tools they need.\n\
       - For coding/writing files, spawn an agent with tools like: [\"bash\", \"read_file\", \"write_file\", \"finish\"].\n\
       - For pure reasoning, planning, or reviewing, spawn an agent with only: [\"finish\"].\n\
       - Child agents start cold with no memory of prior turns. You must provide all necessary context in the task argument.\n\
       - When all sub-tasks are complete, synthesize a concise final summary and call 'finish'."
    in

    let orch_sess =
      Session.create ~tools:orchestrator_tools orch_model orch_provider
      |> fun s -> Session.set_system s orch_system
    in

    pp_sep ();
    Printf.printf "Homogeneous Swarm Orchestrator Initialised:\n";
    Printf.printf "  Provider: %s\n" orch_provider_ref;
    Printf.printf "  Model:    %s\n" orch_model;
    Printf.printf "  Tools:    %s\n"
      (List.map Tool.name_of_packed orchestrator_tools |> String.concat ", ");

    (* ── Demo: Dynamic Multi-Agent LISP Swarm ─────────────────────────── *)
    pp_sep ();
    Printf.printf "Running Swarm Demo...\n%!";
    let scratch_dir =
      let home = match Sys.getenv_opt "HOME" with Some h -> h | None -> "." in
      Filename.concat home "tmp/caravan_swarm_lisp"
    in
    if not (Sys.file_exists scratch_dir) then
      (try Unix.mkdir scratch_dir 0o755 with _ -> ());
    let target_file = Filename.concat scratch_dir "cauchy_schwarz.lisp" in

    let task =
      Printf.sprintf
        "Write a clean LISP (Common Lisp or Scheme) program that proves/verifies the Cauchy-Schwarz inequality \
         ( (a1*b1 + a2*b2)^2 <= (a1^2 + a2^2)*(b1^2 + b2^2) ) for 2D vectors, including assertions with test vectors. \
         Write the resulting LISP code into the file '%s'. \
         After writing the file, spawn a reviewer subagent to check the code correctness."
        target_file
    in
    Printf.printf "Task: %s\n%!" task;

    let result = Agent.run net clock orch_sess task in
    pp_sep ();
    pp_result "orchestrator" result;
    pp_sep ();

    if Sys.file_exists target_file then (
      Printf.printf "Found generated file '%s'. Contents:\n\n" target_file;
      let ic = open_in target_file in
      (try
         while true do
           Printf.printf "  %s\n" (input_line ic)
         done
       with End_of_file -> close_in ic);
    );
    pp_sep ();
    Printf.printf "Swarm example complete.\n%!"
  )
