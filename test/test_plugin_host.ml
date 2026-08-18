(* Tests for the harness side of the plugin runtime: [[plugins]] config
   parsing, Plugin_host composition/reconciliation, the provider
   service, and the new Trace events. All offline. *)

open Caravan

let write_tmp_config contents =
  let path = Filename.temp_file "caravan_plugins" ".toml" in
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  path

let with_config contents f =
  let path = write_tmp_config contents in
  Unix.putenv "CARAVAN_CONFIG" path;
  Config.reload ();
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "CARAVAN_CONFIG" "";
      Config.reload ();
      Sys.remove path)
    f

(* ── [[plugins]] parsing ────────────────────────────────────────────── *)

let%test_unit "config parses [[plugins]] entries" =
  with_config
    {|
provider = "ollama"

[[plugins]]
plugin = "tools.builtin"
exclude = ["bash"]

[[plugins]]
id = "fs"
plugin = "tools.mcp"
enabled = false
command = "npx"
args = ["-y", "server-filesystem"]

[[plugins]]
comment = "no plugin field: dropped"
|}
    (fun () ->
      match Config.get_plugins () with
      | [ a; b ] ->
        assert (a.Config.id = "tools.builtin");
        assert (a.Config.plugin = "tools.builtin");
        assert a.Config.enabled;
        assert (
          Yojson.Safe.Util.(a.Config.config |> member "exclude" |> to_list)
          = [ `String "bash" ]);
        assert (b.Config.id = "fs");
        assert (not b.Config.enabled);
        assert (
          Yojson.Safe.Util.(b.Config.config |> member "command" |> to_string)
          = "npx")
      | l -> failwith (Printf.sprintf "expected 2 entries, got %d" (List.length l)))

let%test "config with no [[plugins]] table yields []" =
  with_config "provider = \"ollama\"\n" (fun () -> Config.get_plugins () = [])

(* ── Plugin_host composition ────────────────────────────────────────── *)

module Fake_tool (M : sig
  val tool_name : string
end) : Tool.TOOL with type input = unit and type output = string = struct
  let name = M.tool_name
  let aliases = []
  let description = "fake"

  type input = unit
  type output = string

  let json_schema () = `Assoc []
  let parse_args _ = Ok ()
  let format_output s = s
  let is_mutating = false
  let describe_action () = "fake"

  type _ Effect.t += Exec : input -> output Effect.t

  let execute () = "fake"
end

let fake_tools () =
  [
    Tool.Tool (module Fake_tool (struct let tool_name = "alpha" end));
    Tool.Tool (module Fake_tool (struct let tool_name = "beta" end));
  ]

let tool_names host = List.map Tool.name_of_packed (Plugin_host.tools host)

let%test_unit "empty config loads the default composition" =
  with_config "provider = \"ollama\"\n" (fun () ->
      let h = Plugin_host.create ~builtin_tools:fake_tools () in
      Plugin_host.load h;
      assert (tool_names h = [ "alpha"; "beta" ]);
      (match Plugin_host.fiber h "tools.builtin" with
       | Some f -> assert (Plugin.Fiber.state f = Plugin.Fiber.Active)
       | None -> assert false);
      (* re-load is a no-op reconciliation, not a rebuild *)
      let f1 = Option.get (Plugin_host.fiber h "tools.builtin") in
      Plugin_host.load h;
      assert (Option.get (Plugin_host.fiber h "tools.builtin") == f1))

let%test_unit "[[plugins]] entries merge over the defaults by id" =
  with_config
    {|
provider = "ollama"

[[plugins]]
plugin = "tools.builtin"
exclude = ["beta"]
|}
    (fun () ->
      let h = Plugin_host.create ~builtin_tools:fake_tools () in
      Plugin_host.load h;
      (* the user entry replaced the default one: exclude applies *)
      assert (tool_names h = [ "alpha" ]))

let%test_unit "unknown plugin names are skipped, not fatal" =
  with_config
    {|
provider = "ollama"

[[plugins]]
id = "mystery"
plugin = "does.not.exist"
|}
    (fun () ->
      let h = Plugin_host.create ~builtin_tools:fake_tools () in
      Plugin_host.load h;
      (* defaults still applied; the unknown entry is absent *)
      assert (tool_names h = [ "alpha"; "beta" ]);
      assert (
        not
          (List.exists
             (fun (e : Config.plugin_config) -> e.id = "mystery")
             (Plugin_host.entries h))))

let%test_unit "set_enabled toggles a live entry and its tools" =
  with_config "provider = \"ollama\"\n" (fun () ->
      let h = Plugin_host.create ~builtin_tools:fake_tools () in
      Plugin_host.load h;
      assert (Plugin_host.set_enabled h ~id:"tools.builtin" false = Ok ());
      assert (tool_names h = []);
      assert (Plugin_host.fiber h "tools.builtin" = None);
      assert (Plugin_host.set_enabled h ~id:"tools.builtin" true = Ok ());
      assert (tool_names h = [ "alpha"; "beta" ]);
      match Plugin_host.set_enabled h ~id:"nope" true with
      | Error _ -> ()
      | Ok () -> assert false)

let%test_unit "custom builders are addressable from config" =
  with_config
    {|
provider = "ollama"

[[plugins]]
id = "greeter"
plugin = "test.greeter"
text = "hi"
|}
    (fun () ->
      let key : string Plugin.Key.t = Plugin.Key.create ~name:"greeting" () in
      let h = Plugin_host.create ~builtin_tools:fake_tools () in
      Plugin_host.register_builder h "test.greeter" (fun cfg ->
          let text = Yojson.Safe.Util.(cfg |> member "text" |> to_string) in
          Plugin.component ~name:"greeter" ~provide:[ Plugin.Key.Ex key ]
            (fun ctx -> ignore (Plugin.provide ctx key text)));
      Plugin_host.load h;
      assert (Plugin.find (Plugin_host.context h) key = Some "hi"))

let%test "an mcp entry without a command fails its fiber in isolation" =
  with_config
    {|
provider = "ollama"

[[plugins]]
id = "broken"
plugin = "tools.mcp"
name = "broken"
|}
    (fun () ->
      let h = Plugin_host.create ~builtin_tools:fake_tools () in
      Plugin_host.load h;
      (* the broken mount failed, the builtin tools are unaffected *)
      (match Plugin_host.fiber h "broken" with
       | Some f -> Plugin.Fiber.state f = Plugin.Fiber.Failed
       | None -> false)
      && tool_names h = [ "alpha"; "beta" ])

(* ── The provider service ───────────────────────────────────────────── *)

module Plain_provider : Provider.PROVIDER with type config = string = struct
  type config = string

  let name = "plain"

  let complete _net cfg ?model:_ ?options:_ ?tools:_ _msgs =
    Types.wrap_result ~raw_response:"" ~model:"m" ~provider:cfg
      (Types.assistant_msg "ok")

  let stream net cfg ?model:_ ?options:_ ?tools:_ msgs ~on_token:_ =
    complete net cfg msgs

  let list_models _ _ = []
end

let%test_unit "set_provider rebinds and reloads dependents" =
  with_config "provider = \"ollama\"\n" (fun () ->
      let h = Plugin_host.create ~builtin_tools:fake_tools () in
      Plugin_host.load h;
      let ctx = Plugin_host.context h in
      let seen = ref [] in
      let watcher =
        Plugin.component ~name:"watcher"
          ~inject:[ Plugin.Key.Ex Plugin.Services.provider ] (fun cctx ->
            let (Provider.Provider ((module P), _)) =
              Plugin.get cctx Plugin.Services.provider
            in
            seen := !seen @ [ P.name ])
      in
      let f = Plugin.use ctx watcher in
      assert (Plugin.Fiber.state f = Plugin.Fiber.Pending);
      Plugin_host.set_provider h (Provider.Provider ((module Plain_provider), "a"));
      assert (Plugin.Fiber.state f = Plugin.Fiber.Active);
      (* rebinding withdraws first, so the dependent reloads *)
      Plugin_host.set_provider h (Provider.Provider ((module Plain_provider), "b"));
      assert (Plugin.Fiber.state f = Plugin.Fiber.Active);
      assert (!seen = [ "plain"; "plain" ]))

(* ── Trace integration ──────────────────────────────────────────────── *)

let%test_unit "plugin lifecycle transitions land in the trace" =
  let events = ref [] in
  Trace.with_sink
    (fun ev -> match ev with
      | Trace.Plugin_transition { name; state; _ } ->
        events := !events @ [ (name, state) ]
      | _ -> ())
    (fun () ->
      let ctx = Plugin.make () in
      Plugin.trace_transitions ctx;
      let f = Plugin.use ctx (Plugin.component ~name:"traced" (fun _ -> ())) in
      Plugin.dispose f);
  assert (
    !events
    = [
        ("traced", "loading");
        ("traced", "active");
        ("traced", "unloading");
        ("traced", "pending");
        ("traced", "disposed");
      ])

let%test_unit "observers accumulate" =
  let a = ref 0 and b = ref 0 in
  let ctx = Plugin.make () in
  Plugin.observe ctx (fun _ -> incr a);
  Plugin.observe ctx (fun _ -> incr b);
  ignore (Plugin.use ctx (Plugin.component ~name:"c" (fun _ -> ())));
  assert (!a > 0 && !a = !b)

let%test_unit "run errors are recorded as trace events with JSON shape" =
  let seen = ref None in
  Trace.with_sink
    (fun ev -> match ev with Trace.Run_error _ -> seen := Some ev | _ -> ())
    (fun () -> Trace.error "test" "boom %d" 7);
  match !seen with
  | Some (Trace.Run_error { origin; message } as ev) ->
    assert (origin = "test");
    assert (message = "boom 7");
    let json = Trace.event_to_json ev in
    let open Yojson.Safe.Util in
    assert (json |> member "event" |> to_string = "error");
    assert (json |> member "origin" |> to_string = "test");
    assert (json |> member "message" |> to_string = "boom 7")
  | _ -> assert false

(* ── Session tool refresh ───────────────────────────────────────────── *)

let%test "with_tools swaps the toolset and keeps history" =
  let provider = Provider.Provider ((module Plain_provider), "p") in
  let sess = Session.create ~tools:(fake_tools ()) "m" provider in
  let sess = Session.add_messages sess [ Types.user_msg "hello" ] in
  let sess' = Session.with_tools sess [] in
  Session.tools sess' = [] && Session.history sess' = Session.history sess

(* ── Toolset realms (subagent sandboxes) ────────────────────────────── *)

let%test_unit "reconcile isolate annotations bind entries into realms" =
  let ctx = Plugin.make () in
  let key : int Plugin.Key.t = Plugin.Key.create ~name:"svc" () in
  let r = Plugin.Reconcile.create ctx in
  let entry realm_annotations v =
    {
      Plugin.Reconcile.id = "e";
      enabled = true;
      config = `Int v;
      isolate = realm_annotations;
      plugin =
        (fun cfg ->
          let v = Yojson.Safe.Util.to_int cfg in
          Plugin.component ~name:"p" ~provide:[ Plugin.Key.Ex key ] (fun c ->
              ignore (Plugin.provide c key v)));
    }
  in
  Plugin.Reconcile.apply r [ entry [ (Plugin.Key.Ex key, "r1") ] 1 ];
  (* bound in realm r1, not in the default realm *)
  assert (Plugin.find ctx key = None);
  let in_r1 = Plugin.isolate ~realm:"r1" ctx (Plugin.Key.Ex key) in
  assert (Plugin.find in_r1 key = Some 1);
  (* changing the isolation rebuilds the entry into the new realm *)
  Plugin.Reconcile.apply r [ entry [ (Plugin.Key.Ex key, "r2") ] 1 ];
  assert (Plugin.find in_r1 key = None);
  assert (
    Plugin.find (Plugin.isolate ~realm:"r2" ctx (Plugin.Key.Ex key)) key = Some 1)

let sandbox_tool_builder tool_name = fun _cfg ->
  Plugin.component ~name:("pack:" ^ tool_name)
    ~inject:[ Plugin.Key.Ex Plugin.Toolset.key ] (fun ctx ->
      ignore
        (Plugin.Toolset.register ctx
           (Tool.Tool (module Fake_tool (struct let tool_name = tool_name end)))))

let%test_unit "a realm-scoped plugin entry sandboxes its tools" =
  with_config
    {|
provider = "ollama"

[[plugins]]
id = "worker-pack"
plugin = "test.pack"
realm = "research"
|}
    (fun () ->
      let h = Plugin_host.create ~builtin_tools:fake_tools () in
      Plugin_host.register_builder h "test.pack" (sandbox_tool_builder "probe");
      Plugin_host.load h;
      (* the shared toolset is untouched; the realm holds the tool *)
      assert (tool_names h = [ "alpha"; "beta" ]);
      assert (
        List.map Tool.name_of_packed (Plugin_host.realm_tools h ~realm:"research")
        = [ "probe" ]);
      assert (Plugin_host.realm_tools h ~realm:"other" = []);
      (* disabling the entry withdraws the sandbox tool, live *)
      assert (Plugin_host.set_enabled h ~id:"worker-pack" false = Ok ());
      assert (Plugin_host.realm_tools h ~realm:"research" = []);
      assert (Plugin_host.set_enabled h ~id:"worker-pack" true = Ok ());
      assert (
        List.map Tool.name_of_packed (Plugin_host.realm_tools h ~realm:"research")
        = [ "probe" ]))

let%test_unit "two entries naming one realm share its toolset" =
  with_config
    {|
provider = "ollama"

[[plugins]]
id = "pack-a"
plugin = "test.a"
realm = "shared"

[[plugins]]
id = "pack-b"
plugin = "test.b"
realm = "shared"
|}
    (fun () ->
      let h = Plugin_host.create ~builtin_tools:fake_tools () in
      Plugin_host.register_builder h "test.a" (sandbox_tool_builder "tool_a");
      Plugin_host.register_builder h "test.b" (sandbox_tool_builder "tool_b");
      Plugin_host.load h;
      assert (
        List.sort compare
          (List.map Tool.name_of_packed (Plugin_host.realm_tools h ~realm:"shared"))
        = [ "tool_a"; "tool_b" ]))

let%test_unit "config parses the subagent realm field" =
  with_config
    {|
provider = "ollama"

[[subagents]]
name = "researcher"
provider = "ollama"
model = "m"
realm = "research"

[[subagents]]
name = "plain"
provider = "ollama"
model = "m"
|}
    (fun () ->
      match Config.get_subagents () with
      | [ a; b ] ->
        assert (a.Config.realm = Some "research");
        assert (b.Config.realm = None)
      | l -> failwith (Printf.sprintf "expected 2 subagents, got %d" (List.length l)))

let%test_unit "delegate merges live sandbox tools at dispatch, statics win" =
  let base = fake_tools () in
  let spec =
    {
      Subagent.name = "worker";
      role = "atomic";
      system_prompt = "";
      tools = base;
      provider = None;
      model = None;
    }
  in
  (* no sandbox: the spec passes through untouched (same value) *)
  let same = CaravanTools.Delegate.effective_spec ~live_tools:(fun _ -> []) spec in
  assert (same.Subagent.tools == base);
  (* sandbox tools are appended; name collisions resolve to the static tool *)
  let dup = Tool.Tool (module Fake_tool (struct let tool_name = "alpha" end)) in
  let fresh = Tool.Tool (module Fake_tool (struct let tool_name = "gamma" end)) in
  let merged =
    CaravanTools.Delegate.effective_spec
      ~live_tools:(fun name ->
        assert (name = "worker");
        [ dup; fresh ])
      spec
  in
  assert (
    List.map Tool.name_of_packed merged.Subagent.tools
    = [ "alpha"; "beta"; "gamma" ]);
  (* the surviving alpha is the static one, not the sandbox duplicate *)
  assert (List.nth merged.Subagent.tools 0 == List.nth base 0)
