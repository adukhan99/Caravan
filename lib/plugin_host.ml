(* Config-driven composition over the Plugin runtime — see the .mli. *)

type t = {
  ctx : Plugin.context;
  builders : (string, Yojson.Safe.t -> Plugin.component) Hashtbl.t;
  mutable current : Config.plugin_config list;
  reconciler : Plugin.Reconcile.t;
  mutable provider_disposer : Plugin.Disposer.t option;
}

(* ── Built-in builders ───────────────────────────────────────────────── *)

let json_strings json field =
  match Yojson.Safe.Util.member field json with
  | `List l -> List.filter_map (function `String s -> Some s | _ -> None) l
  | _ -> []

let json_string json field =
  match Yojson.Safe.Util.member field json with `String s -> Some s | _ -> None

let builtin_tools_builder get_tools config =
  let exclude = json_strings config "exclude" in
  Plugin.component ~name:"tools.builtin"
    ~inject:[ Plugin.Key.Ex Plugin.Toolset.key ] (fun ctx ->
      List.iter
        (fun tool ->
          if not (List.mem (Tool.name_of_packed tool) exclude) then
            ignore (Plugin.Toolset.register ctx tool))
        (get_tools ()))

(* An MCP server as a component: connect on activation, register the
   discovered tools, close the server on disposal. Uses the thread-based
   transport (no Eio handles needed), like the CLI always has. *)
let mcp_builder config =
  let name = Option.value ~default:"mcp" (json_string config "name") in
  Plugin.component ~name:("mcp:" ^ name)
    ~inject:[ Plugin.Key.Ex Plugin.Toolset.key ] (fun ctx ->
      let command =
        match json_string config "command" with
        | Some c -> c
        | None -> failwith (Printf.sprintf "mcp '%s': missing 'command'" name)
      in
      let args = json_strings config "args" in
      Trace.log "info" "MCP: connecting to '%s' (%s %s)" name command
        (String.concat " " args);
      match Mcp.connect name command args with
      | Error err ->
        Trace.log "error" "MCP: failed to connect to '%s': %s" name err;
        failwith err
      | Ok client ->
        ignore (Plugin.on_dispose ctx (fun () -> try client.Mcp.close () with _ -> ()));
        let tools = Mcp.list_tools client in
        Trace.log "info" "MCP: discovered %d tools from '%s'" (List.length tools) name;
        List.iter
          (fun tool_def ->
            ignore (Plugin.Toolset.register ctx (Mcp.make_packed_tool client tool_def)))
          tools)

(* ── Host lifecycle ──────────────────────────────────────────────────── *)

let create ?builtin_tools () =
  let ctx = Plugin.make () in
  Plugin.trace_transitions ctx;
  ignore (Plugin.use ctx Plugin.Toolset.provider);
  let builders = Hashtbl.create 8 in
  Hashtbl.replace builders "tools.mcp" mcp_builder;
  (match builtin_tools with
   | Some get -> Hashtbl.replace builders "tools.builtin" (builtin_tools_builder get)
   | None -> ());
  {
    ctx;
    builders;
    current = [];
    reconciler = Plugin.Reconcile.create ctx;
    provider_disposer = None;
  }

let context t = t.ctx
let register_builder t name builder = Hashtbl.replace t.builders name builder

(* The composition when the config is silent: built-in tools plus one
   MCP mount per [[mcp.servers]] entry. *)
let default_entries t =
  let builtin =
    if Hashtbl.mem t.builders "tools.builtin" then
      [ { Config.id = "tools.builtin"; plugin = "tools.builtin";
          enabled = true; config = `Assoc [] } ]
    else []
  in
  let mcp =
    List.map
      (fun (cfg : Config.mcp_server_config) ->
        { Config.id = "mcp:" ^ cfg.name;
          plugin = "tools.mcp";
          enabled = true;
          config =
            `Assoc
              [ ("name", `String cfg.name);
                ("transport", `String cfg.transport);
                ("command", `String cfg.command);
                ("args", `List (List.map (fun a -> `String a) cfg.args)) ];
        })
      (Config.get_mcp_servers ())
  in
  builtin @ mcp

let apply t entries =
  (* Keep only entries whose builder exists; warn about the rest. *)
  let usable =
    List.filter
      (fun (e : Config.plugin_config) ->
        let known = Hashtbl.mem t.builders e.plugin in
        if not known then
          Trace.log "warn" "plugins: entry '%s' names unknown plugin '%s' — skipped"
            e.id e.plugin;
        known)
      entries
  in
  t.current <- usable;
  Plugin.Reconcile.apply t.reconciler
    (List.map
       (fun (e : Config.plugin_config) ->
         { Plugin.Reconcile.id = e.id; enabled = e.enabled; config = e.config;
           plugin = (fun cfg -> (Hashtbl.find t.builders e.plugin) cfg) })
       usable)

let load t =
  let defaults = default_entries t in
  let declared = Config.get_plugins () in
  let declared_ids = List.map (fun (e : Config.plugin_config) -> e.id) declared in
  let merged =
    List.filter
      (fun (d : Config.plugin_config) -> not (List.mem d.id declared_ids))
      defaults
    @ declared
  in
  apply t merged

let entries t = t.current

let set_enabled t ~id enabled =
  if List.exists (fun (e : Config.plugin_config) -> e.id = id) t.current then begin
    apply t
      (List.map
         (fun (e : Config.plugin_config) ->
           if e.id = id then { e with enabled } else e)
         t.current);
    Ok ()
  end
  else Error (Printf.sprintf "no plugin entry with id '%s'" id)

let fiber t id = Plugin.Reconcile.fiber t.reconciler id
let tools t = Plugin.Toolset.snapshot t.ctx

let set_provider t provider =
  (match t.provider_disposer with
   | Some d -> Plugin.Disposer.dispose d
   | None -> ());
  t.provider_disposer <- Some (Plugin.provide t.ctx Plugin.Services.provider provider)
