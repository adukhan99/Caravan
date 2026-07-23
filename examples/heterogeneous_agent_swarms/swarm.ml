(** Heterogeneous Agent Swarm — Caravan example.

    Gemini 2.5 Pro orchestrates; local Qwen3.5 workers execute atomic tasks.

    Run:
      GEMINI_API_KEY=<key> \
      CARAVAN_CONFIG=examples/heterogeneous_agent_swarms/config.toml \
      dune exec examples/heterogeneous_agent_swarms/swarm.exe

    What happens:
      1. [[subagents]] entries are read from config.toml
      2. [providers.*] entries are read and packed_providers built for each worker
      3. The delegate tool is installed (tool names validated at this point)
      4. Gemini orchestrator session is created with ONLY finish + delegate tools
      5. Two demo tasks run: single delegation and parallel fan-out
*)

open Caravan
open Caravan.Types

(* ── Pretty printing ──────────────────────────────────────────────────────── *)

let pp_sep () = Printf.printf "\n%s\n%!" (String.make 60 '-')

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

(** Derive gen_options from a subagent config (respecting GRES constraints). *)
let options_of_cfg (sc : Config.subagent_config) =
  (* When thinking is disabled in GRES, cap temperature at 0 for predictability *)
  let temperature =
    if sc.gres.thinking then sc.temperature
    else Some (Option.value sc.temperature ~default:0.0 |> min 0.3)
  in
  { default_options with temperature; max_tokens = sc.max_tokens }

(* ── Build subagent specs from config ─────────────────────────────────────── *)

(** Resolve a [Config.subagent_config] into a [Subagent.subagent_spec], building
    the worker's provider and filtering the global tool list to the subset named
    in [sc.tool_names].  Compile-time validation happens in [Delegate.make]. *)
let resolve_spec static_tools (sc : Config.subagent_config) =
  let options  = options_of_cfg sc in
  let provider = provider_of_ref ~name:sc.provider_ref ~model:sc.model ~options in
  let tools =
    if sc.tool_names = [] then []
    else List.filter (fun t -> List.mem (Tool.name_of_packed t) sc.tool_names) static_tools
  in
  ({ Subagent.
     name          = sc.name;
     role          = sc.worker_role;
     system_prompt = sc.system_prompt;
     tools;
     provider      = Some provider;
     model         = Some sc.model;
   } : Subagent.subagent_spec)

(* ── Main ─────────────────────────────────────────────────────────────────── *)

let () =
  Eio_main.run (fun env ->
    let net   = env#net in
    let clock = env#clock in

    (* 1. Read config *)
    let subagent_cfgs = Config.get_subagents () in
    if subagent_cfgs = [] then
      failwith
        "No [[subagents]] found.\n\
         Run with: CARAVAN_CONFIG=examples/heterogeneous_agent_swarms/config.toml";

    Printf.printf "Subagent pool (%d workers):\n%!" (List.length subagent_cfgs);
    List.iter (fun (sc : Config.subagent_config) ->
      Printf.printf "  %-22s  provider=%-16s  model=%s  role=%s\n\
                     %s  gres={thinking=%b tools=%b vision=%b gen_image=%b}\n%!"
        sc.name sc.provider_ref sc.model sc.worker_role
        (String.make 24 ' ')
        sc.gres.thinking sc.gres.tools sc.gres.vision sc.gres.gen_image
    ) subagent_cfgs;

    (* 2. Build the static tool list *)
    let static_tools = CaravanTools.All_tools.all_tools in

    (* 3. Resolve subagent specs (providers built here) *)
    let subagent_specs = List.map (resolve_spec static_tools) subagent_cfgs in

    (* 4. Build the delegate tool — tool name validation fires here.
          Any unknown tool name raises Invalid_argument immediately. *)
    let delegate_tool =
      CaravanTools.Delegate.make
        ~net
        ~clock
        ~registered_tools:static_tools
        ~subagent_specs
    in

    (* 5. Orchestrator tool list: only finish + delegate.
          Gemini must plan and delegate — it cannot execute directly. *)
    let finish_tool =
      List.find (fun t -> Tool.name_of_packed t = "finish") static_tools
    in
    let orchestrator_tools = [finish_tool; delegate_tool] in

    (* 6. Build the Gemini orchestrator session *)
    let (orch_provider_ref, orch_model) =
      Option.value ~default:("gemini", "gemini-2.5-pro") (Config.get_orchestrator ())
    in
    let orch_provider = provider_of_ref
      ~name:orch_provider_ref ~model:orch_model ~options:default_options
    in
    let worker_names =
      List.map (fun (s : Subagent.subagent_spec) -> s.name) subagent_specs
      |> String.concat ", "
    in
    let orch_system =
      Printf.sprintf
        "You are a high-level orchestrator. Decompose complex tasks and delegate \
         each atomic sub-task to a specialised local worker via the 'delegate' tool.\n\
         Available workers: %s.\n\
         Rules:\n\
         - Delegate ALL execution work to workers — do not perform it yourself.\n\
         - Workers start cold with no conversation history; give them full context.\n\
         - When all sub-tasks are complete, synthesise a concise final answer and \
           call 'finish'."
        worker_names
    in
    let orch_sess =
      Session.create ~tools:orchestrator_tools orch_model orch_provider
      |> fun s -> Session.set_system s orch_system
    in
    pp_sep ();
    Printf.printf "Orchestrator: %s / %s\n%!" orch_provider_ref orch_model;
    Printf.printf "Orchestrator tools: %s\n%!"
      (List.map Tool.name_of_packed orchestrator_tools |> String.concat ", ");

    (* ── Demo 1: Agentic LISP delegation ───────────────────────────────── *)
    pp_sep ();
    Printf.printf "Demo 1 — Agentic delegation\n%!";
    let scratch_dir =
      let home = match Sys.getenv_opt "HOME" with Some h -> h | None -> "." in
      Filename.concat home "tmp/caravan_swarm_lisp"
    in
    if not (Sys.file_exists scratch_dir) then
      (try Unix.mkdir scratch_dir 0o755 with _ -> ());
    let target_file = Filename.concat scratch_dir "cauchy_schwarz_hetero.lisp" in

    let task1 =
      Printf.sprintf
        "Write a clean LISP (Common Lisp or Scheme) program that verifies or proves the Cauchy-Schwarz inequality \
         ( (a1*b1 + a2*b2)^2 <= (a1^2 + a2^2)*(b1^2 + b2^2) ) for 2D vectors, including test assertions with example vectors. \
         Delegate writing the code to a worker subagent, specifying target file '%s'."
        target_file
    in
    Printf.printf "Task: %s\n%!" task1;
    let result1 = Agent.run net clock orch_sess task1 in
    pp_result "orchestrator" result1;

    if Sys.file_exists target_file then (
      Printf.printf "\nFound generated file '%s'. Contents:\n\n" target_file;
      let ic = open_in target_file in
      (try
         while true do
           Printf.printf "  %s\n" (input_line ic)
         done
       with End_of_file -> close_in ic);
    );

    (* ── Demo 2: Parallel fact extraction ────────────────────────────────── *)
    pp_sep ();
    Printf.printf "Demo 2 — Parallel fact extraction\n%!";
    let passages = [
      "The OCaml programming language was created by Xavier Leroy and others \
       at INRIA. It features a strong static type system with type inference.";
      "Eio is an effects-based concurrency library for OCaml 5. It provides \
       structured concurrency via fibers and switches.";
    ] in
    let extractor_spec_opt =
      List.find_opt (fun (s : Subagent.subagent_spec) -> s.name = "fact_extractor")
        subagent_specs
    in
    (match extractor_spec_opt with
     | None ->
       Printf.printf "  (fact_extractor not configured — skipping demo 2)\n%!"
     | Some extractor_spec ->
       let specs_and_tasks = List.map (fun p -> (extractor_spec, p)) passages in
       let results = Subagent.delegate_parallel net clock orch_sess specs_and_tasks in
       List.iter2 (fun passage result ->
         Printf.printf "\nPassage: %s\n%!" passage;
         pp_result "fact_extractor" result
       ) passages results);

    pp_sep ();
    Printf.printf "Swarm example complete.\n%!"
  )
