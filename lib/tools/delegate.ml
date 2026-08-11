(** Delegate tool — lets the orchestrator spawn local subagent workers.

    Instantiate once at startup (inside [Eio_main.run]) after building your
    provider and spec values:

    {[
      let delegate_tool =
        Delegate.make ~net ~clock
          ~registered_tools:CaravanTools.All_tools.all_tools
          ~subagent_specs
      in
      let orchestrator_tools = [finish_tool; delegate_tool] in
    ]}

    Every tool name in each spec's [tools] list is validated against
    [registered_tools] at [make] time — [Invalid_argument] is raised
    before the first LLM call if anything is wrong. *)

open Caravan.Tool
open Caravan.Types
open Yojson.Safe.Util

(* ── Startup-time validation ──────────────────────────────────────────────── *)

(** Check every tool name in [spec.tools] exists in [registered_tools].
    Raises [Invalid_argument] with a human-readable message on the first miss. *)
let validate_tool_names subagent_name (spec : Caravan.Subagent.subagent_spec) registered_tools =
  let names = List.map Caravan.Tool.name_of_packed spec.tools in
  List.iter (fun tn ->
    match Caravan.Tool.find_tool registered_tools tn with
    | Some _ -> ()
    | None ->
      let known =
        List.map Caravan.Tool.name_of_packed registered_tools
        |> String.concat ", "
      in
      invalid_arg (Printf.sprintf
        "[Caravan] Subagent '%s': tool '%s' not found in registered tools.\n\
         Known tools: %s"
        subagent_name tn known)
  ) names

(* ── Shared mutable registry ──────────────────────────────────────────────── *)

(** Populated by [make] before any dispatch can happen. *)
let registry : (string, Caravan.Subagent.subagent_spec) Hashtbl.t = Hashtbl.create 8

(* ── TOOL module ─────────────────────────────────────────────────────────── *)

module Delegate = struct
  let name    = "delegate"
  let aliases = ["subagent"; "spawn_worker"; "offload"; "delegate_batch"]

  (* NOTE: must stay a function — the registry is only populated by [make],
     which runs after this module is initialised. A plain [let] here would
     freeze the description as "(no subagents configured)" forever. *)
  let description_now () =
    let base =
      "Delegate one or more atomic, well-specified tasks to specialised local subagents in parallel. \
       Subagents start cold (no conversation history) and return concise final results, saving orchestrator tokens. \
       Pass a 'tasks' array of subagent/task pairs for parallel execution, or single 'subagent' and 'task'. "
    in
    if Hashtbl.length registry = 0 then base ^ "(no subagents configured)"
    else
      let names =
        Hashtbl.fold (fun k _ acc -> k :: acc) registry []
        |> List.sort String.compare
        |> String.concat ", "
      in
      base ^ "Available subagents: " ^ names ^ "."

  let description = description_now ()

  type task_item = { subagent : string; task : string }

  type input  =
    | Single of task_item
    | Batch of task_item list

  type output = string

  let json_schema () =
    let enum_names = Hashtbl.fold (fun k _ acc -> `String k :: acc) registry [] in
    let subagent_prop =
      [ ("type",        `String "string");
        ("description", `String "Name of the subagent to use.") ]
      @ if enum_names <> [] then [("enum", `List enum_names)] else []
    in
    let task_prop =
      [ ("type",        `String "string");
        ("description", `String
          "Complete, self-contained task description. Include ALL context \
           needed — the subagent has no memory of prior turns."); ]
    in
    `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("subagent", `Assoc subagent_prop);
        ("task",     `Assoc task_prop);
        ("tasks", `Assoc [
          ("type",        `String "array");
          ("description", `String "List of subagent tasks to run concurrently in parallel.");
          ("items", `Assoc [
            ("type",     `String "object");
            ("required", `List [`String "subagent"; `String "task"]);
            ("properties", `Assoc [
              ("subagent", `Assoc subagent_prop);
              ("task",     `Assoc task_prop);
            ]);
          ]);
        ]);
      ]);
    ]

  let parse_item json =
    let subagent = json |> member "subagent" |> to_string in
    let task     = json |> member "task"     |> to_string in
    { subagent; task }

  let parse_args json =
    try
      let tasks_json = json |> member "tasks" in
      if tasks_json <> `Null then
        let items = tasks_json |> to_list |> List.map parse_item in
        if items = [] then Error "delegate parse: 'tasks' array cannot be empty"
        else Ok (Batch items)
      else
        let subagent = json |> member "subagent" |> to_string in
        let task     = json |> member "task"     |> to_string in
        Ok (Single { subagent; task })
    with Type_error (msg, _) -> Error ("delegate parse: " ^ msg)

  let format_output s = s

  type _ Effect.t += Exec : input -> output Effect.t

  let execute _input =
    "Error: delegate tool not initialised — call Delegate.make inside Eio_main.run."
end

(* ── Factory function ─────────────────────────────────────────────────────── *)

(** Build and return the delegate [packed_tool].

    @param net              Eio network handle (from the enclosing fiber).
    @param clock            Eio clock handle.
    @param registered_tools Full tool list — used only for name validation.
    @param subagent_specs   Resolved specs with provider already set.
    @raise Invalid_argument on unknown tool name in any spec. *)
let make
    ~(net              : _ Eio.Net.t)
    ~(clock            : _ Eio.Time.clock)
    ~(registered_tools : Caravan.Tool.packed_tool list)
    ~(subagent_specs   : Caravan.Subagent.subagent_spec list)
  : Caravan.Tool.packed_tool =
  (* Validate at startup — before any token is spent *)
  List.iter (fun (spec : Caravan.Subagent.subagent_spec) ->
    validate_tool_names spec.name spec registered_tools
  ) subagent_specs;
  (* Populate registry *)
  Hashtbl.clear registry;
  List.iter (fun (spec : Caravan.Subagent.subagent_spec) ->
    Hashtbl.replace registry spec.name spec
  ) subagent_specs;
  (* Construct a fresh packed_tool whose [execute] closes over [net] and [clock] *)
  let dispatch_single (subagent : string) (task : string) : (string, string) result =
    match Hashtbl.find_opt registry subagent with
    | None ->
      let available =
        Hashtbl.fold (fun k _ a -> k :: a) registry []
        |> List.sort String.compare
        |> String.concat ", "
      in
      Error (Printf.sprintf "Error: unknown subagent '%s'. Available: %s" subagent available)
    | Some (spec : Caravan.Subagent.subagent_spec) ->
      let parent_provider =
        match spec.provider with
        | Some p -> p
        | None   -> failwith "delegate: subagent spec has no provider set"
      in
      let model =
        match spec.model with
        | Some m -> m
        | None   -> spec.name
      in
      let parent_sess = Caravan.Session.create model parent_provider in
      (match Caravan.Subagent.delegate net clock parent_sess spec task with
       | Ok (_sess, result) -> Ok result.value.content
       | Error msg          -> Error (Printf.sprintf "Subagent '%s' error: %s" subagent msg))
  in

  let dispatch_batch (items : Delegate.task_item list) : string =
    match items with
    | [] -> "Error: empty subagent task list"
    | [{ subagent; task }] ->
      (match dispatch_single subagent task with
       | Ok res -> res
       | Error err -> err)
    | items ->
      let specs_and_tasks =
        List.map (fun ({ subagent; task } : Delegate.task_item) ->
          match Hashtbl.find_opt registry subagent with
          | Some spec -> Ok (spec, task)
          | None -> Error subagent
        ) items
      in
      let unknown =
        List.filter_map (function Error s -> Some s | Ok _ -> None) specs_and_tasks
      in
      if unknown <> [] then
        let available =
          Hashtbl.fold (fun k _ a -> k :: a) registry []
          |> List.sort String.compare
          |> String.concat ", "
        in
        Printf.sprintf "Error: unknown subagent(s): %s. Available: %s"
          (String.concat ", " unknown) available
      else
        let valid_items =
          List.filter_map (function Ok pair -> Some pair | Error _ -> None) specs_and_tasks
        in
        let tasks_with_sessions =
          List.map (fun ((spec : Caravan.Subagent.subagent_spec), task) ->
            let parent_provider =
              match spec.provider with
              | Some p -> p
              | None   -> failwith "delegate: subagent spec has no provider set"
            in
            let model =
              match spec.model with
              | Some m -> m
              | None   -> spec.name
            in
            let parent_sess = Caravan.Session.create model parent_provider in
            (spec, task, parent_sess)
          ) valid_items
        in
        let results =
          Eio.Fiber.List.map (fun ((spec : Caravan.Subagent.subagent_spec), task, parent_sess) ->
            (spec.name, Caravan.Subagent.delegate net clock parent_sess spec task)
          ) tasks_with_sessions
        in
        List.map (fun (name, res) ->
          match res with
          | Ok (_sess, result) -> Printf.sprintf "[Subagent '%s']:\n%s" name result.value.content
          | Error msg          -> Printf.sprintf "[Subagent '%s'] Error: %s" name msg
        ) results
        |> String.concat "\n\n"
  in

  let dispatch (inp : Delegate.input) : string =
    match inp with
    | Single { subagent; task } ->
      (match dispatch_single subagent task with
       | Ok res -> res
       | Error err -> err)
    | Batch items -> dispatch_batch items
  in
  Tool (module struct
    let name          = Delegate.name
    let aliases       = Delegate.aliases
    let description   = Delegate.description_now ()
    type input        = Delegate.input = Single of Delegate.task_item | Batch of Delegate.task_item list
    type output       = string
    type _ Effect.t  += Exec : input -> output Effect.t
    let json_schema   = Delegate.json_schema
    let parse_args    = Delegate.parse_args
    let format_output = Delegate.format_output
    let execute inp   = dispatch inp
  end)
