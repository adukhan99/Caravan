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
  let aliases = ["subagent"; "spawn_worker"; "offload"]

  let description =
    let base =
      "Delegate an atomic, well-specified task to a specialised local subagent. \
       The subagent starts cold (no conversation history) and returns only a \
       concise final result, saving orchestrator tokens. "
    in
    if Hashtbl.length registry = 0 then base ^ "(no subagents configured)"
    else
      let names =
        Hashtbl.fold (fun k _ acc -> k :: acc) registry []
        |> List.sort String.compare
        |> String.concat ", "
      in
      base ^ "Available subagents: " ^ names ^ "."

  type input  = { subagent : string; task : string }
  type output = string

  let json_schema () =
    let enum_names = Hashtbl.fold (fun k _ acc -> `String k :: acc) registry [] in
    `Assoc [
      ("type",     `String "object");
      ("required", `List [`String "subagent"; `String "task"]);
      ("properties", `Assoc [
        ("subagent", `Assoc (
          [ ("type",        `String "string");
            ("description", `String "Name of the subagent to use.") ]
          @ if enum_names <> [] then [("enum", `List enum_names)] else []
        ));
        ("task", `Assoc [
          ("type",        `String "string");
          ("description", `String
            "Complete, self-contained task description. Include ALL context \
             needed — the subagent has no memory of prior turns.");
        ]);
      ]);
    ]

  let parse_args json =
    try
      let subagent = json |> member "subagent" |> to_string in
      let task     = json |> member "task"     |> to_string in
      Ok { subagent; task }
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
  let dispatch (subagent : string) (task : string) : string =
    match Hashtbl.find_opt registry subagent with
    | None ->
      let available =
        Hashtbl.fold (fun k _ a -> k :: a) registry []
        |> List.sort String.compare
        |> String.concat ", "
      in
      Printf.sprintf "Error: unknown subagent '%s'. Available: %s" subagent available
    | Some spec ->
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
      (* Cold start — fresh session, no parent history *)
      let parent_sess = Caravan.Session.create model parent_provider in
      (match Caravan.Subagent.delegate net clock parent_sess spec task with
       | Ok (_sess, result) -> result.value.content
       | Error msg          -> Printf.sprintf "Subagent '%s' error: %s" subagent msg)
  in
  Tool (module struct
    (* Re-export all Delegate members explicitly so [input] remains a concrete
       record type — [include Delegate] would make it abstract via the TOOL sig. *)
    let name          = Delegate.name
    let aliases       = Delegate.aliases
    let description   = Delegate.description
    type input        = Delegate.input = { subagent : string; task : string }
    type output       = string
    type _ Effect.t  += Exec : input -> output Effect.t
    let json_schema   = Delegate.json_schema
    let parse_args    = Delegate.parse_args
    let format_output = Delegate.format_output
    let execute inp   = dispatch inp.subagent inp.task
  end)
