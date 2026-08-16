(* Tests for Caravan.Plugin — the spatiotemporal composability runtime.

   Each test builds its own runtime (Plugin.make) so state never bleeds
   between tests. Activation/deactivation order is asserted by recording
   into a shared log ref. *)

open Caravan

let push log x = log := !log @ [ x ]

(* ── Revertible effects ─────────────────────────────────────────────── *)

let%test "track runs setup immediately and disposer is one-shot" =
  let ctx = Plugin.make () in
  let log = ref [] in
  let dispose =
    Plugin.track ctx (fun () ->
        push log "setup";
        fun () -> push log "teardown")
  in
  assert (!log = [ "setup" ]);
  Plugin.Disposer.dispose dispose;
  Plugin.Disposer.dispose dispose;
  !log = [ "setup"; "teardown" ]

let%test "disposal is LIFO on fiber unload" =
  let ctx = Plugin.make () in
  let log = ref [] in
  let comp =
    Plugin.component ~name:"c" (fun cctx ->
        ignore (Plugin.on_dispose cctx (fun () -> push log "first"));
        ignore (Plugin.on_dispose cctx (fun () -> push log "second"));
        ignore (Plugin.on_dispose cctx (fun () -> push log "third")))
  in
  let f = Plugin.use ctx comp in
  assert (Plugin.Fiber.state f = Plugin.Fiber.Active);
  Plugin.dispose f;
  !log = [ "third"; "second"; "first" ]

let%test "early disposal unregisters: not re-run on unload" =
  let ctx = Plugin.make () in
  let count = ref 0 in
  let early = ref None in
  let comp =
    Plugin.component ~name:"c" (fun cctx ->
        early := Some (Plugin.on_dispose cctx (fun () -> incr count)))
  in
  let f = Plugin.use ctx comp in
  Plugin.Disposer.dispose (Option.get !early);
  assert (!count = 1);
  Plugin.dispose f;
  !count = 1

(* ── Services at the root ───────────────────────────────────────────── *)

let%test_unit "root provide / get / find round-trips typed values" =
  let ctx = Plugin.make () in
  let k_int : int Plugin.Key.t = Plugin.Key.create ~name:"int" () in
  let k_str : string Plugin.Key.t = Plugin.Key.create ~name:"str" () in
  let dispose_int = Plugin.provide ctx k_int 42 in
  let _ = Plugin.provide ctx k_str "hello" in
  assert (Plugin.get ctx k_int = 42);
  assert (Plugin.get ctx k_str = "hello");
  assert (Plugin.find ctx k_int = Some 42);
  Plugin.Disposer.dispose dispose_int;
  assert (Plugin.find ctx k_int = None);
  (match Plugin.get ctx k_int with
   | exception Plugin.Unprovided "int" -> ()
   | _ -> assert false);
  assert (Plugin.get ctx k_str = "hello")

(* ── Reactive activation and deactivation ───────────────────────────── *)

let%test_unit "component waits for its dependency, then reacts to it" =
  let ctx = Plugin.make () in
  let key : int Plugin.Key.t = Plugin.Key.create ~name:"dep" () in
  let log = ref [] in
  let comp =
    Plugin.component ~name:"consumer" ~inject:[ Plugin.Key.Ex key ]
      (fun cctx ->
        push log (Printf.sprintf "up:%d" (Plugin.get cctx key));
        ignore (Plugin.on_dispose cctx (fun () -> push log "down")))
  in
  let f = Plugin.use ctx comp in
  assert (Plugin.Fiber.state f = Plugin.Fiber.Pending);
  assert (!log = []);
  let withdraw = Plugin.provide ctx key 7 in
  assert (Plugin.Fiber.state f = Plugin.Fiber.Active);
  assert (!log = [ "up:7" ]);
  Plugin.Disposer.dispose withdraw;
  assert (Plugin.Fiber.state f = Plugin.Fiber.Pending);
  assert (!log = [ "up:7"; "down" ]);
  let _ = Plugin.provide ctx key 8 in
  assert (Plugin.Fiber.state f = Plugin.Fiber.Active);
  assert (!log = [ "up:7"; "down"; "up:8" ])

let%test "teardown can still read the withdrawn service" =
  let ctx = Plugin.make () in
  let key : string Plugin.Key.t = Plugin.Key.create ~name:"conn" () in
  let seen = ref None in
  let comp =
    Plugin.component ~name:"consumer" ~inject:[ Plugin.Key.Ex key ]
      (fun cctx ->
        ignore
          (Plugin.on_dispose cctx (fun () -> seen := Some (Plugin.get cctx key))))
  in
  let _f = Plugin.use ctx comp in
  let withdraw = Plugin.provide ctx key "pool" in
  Plugin.Disposer.dispose withdraw;
  !seen = Some "pool"

let%test_unit "provider chain activates forward and deactivates backward" =
  let ctx = Plugin.make () in
  let x : unit Plugin.Key.t = Plugin.Key.create ~name:"x" () in
  let y : unit Plugin.Key.t = Plugin.Key.create ~name:"y" () in
  let log = ref [] in
  let track_lifecycle name cctx =
    push log (name ^ "+");
    ignore (Plugin.on_dispose cctx (fun () -> push log (name ^ "-")))
  in
  let a =
    Plugin.component ~name:"a" ~provide:[ Plugin.Key.Ex x ] (fun cctx ->
        track_lifecycle "a" cctx;
        ignore (Plugin.provide cctx x ()))
  in
  let b =
    Plugin.component ~name:"b" ~inject:[ Plugin.Key.Ex x ]
      ~provide:[ Plugin.Key.Ex y ] (fun cctx ->
        track_lifecycle "b" cctx;
        ignore (Plugin.provide cctx y ()))
  in
  let c =
    Plugin.component ~name:"c" ~inject:[ Plugin.Key.Ex y ] (fun cctx ->
        track_lifecycle "c" cctx)
  in
  (* Instantiation order should not matter: use consumers first. *)
  let fc = Plugin.use ctx c in
  let fb = Plugin.use ctx b in
  assert (Plugin.Fiber.state fc = Plugin.Fiber.Pending);
  assert (Plugin.Fiber.state fb = Plugin.Fiber.Pending);
  let fa = Plugin.use ctx a in
  assert (Plugin.Fiber.state fa = Plugin.Fiber.Active);
  assert (Plugin.Fiber.state fb = Plugin.Fiber.Active);
  assert (Plugin.Fiber.state fc = Plugin.Fiber.Active);
  assert (!log = [ "a+"; "b+"; "c+" ]);
  (* Disposing the root provider must drain dependents first: c, then b. *)
  Plugin.dispose fa;
  assert (!log = [ "a+"; "b+"; "c+"; "c-"; "b-"; "a-" ]);
  assert (Plugin.Fiber.state fa = Plugin.Fiber.Disposed);
  assert (Plugin.Fiber.state fb = Plugin.Fiber.Pending);
  assert (Plugin.Fiber.state fc = Plugin.Fiber.Pending)

let%test "unloading one component leaves independent siblings running" =
  let ctx = Plugin.make () in
  let x : int Plugin.Key.t = Plugin.Key.create ~name:"x" () in
  let y : int Plugin.Key.t = Plugin.Key.create ~name:"y" () in
  let mk name key v =
    Plugin.component ~name ~provide:[ Plugin.Key.Ex key ] (fun cctx ->
        ignore (Plugin.provide cctx key v))
  in
  let fa = Plugin.use ctx (mk "a" x 1) in
  let fb = Plugin.use ctx (mk "b" y 2) in
  Plugin.dispose fa;
  Plugin.Fiber.state fb = Plugin.Fiber.Active
  && Plugin.find ctx x = None
  && Plugin.find ctx y = Some 2

(* ── Failure handling ───────────────────────────────────────────────── *)

let%test_unit "a raising body is rolled back and marked Failed" =
  let ctx = Plugin.make () in
  let key : int Plugin.Key.t = Plugin.Key.create ~name:"svc" () in
  let log = ref [] in
  let bad =
    Plugin.component ~name:"bad" ~provide:[ Plugin.Key.Ex key ] (fun cctx ->
        ignore (Plugin.provide cctx key 1);
        ignore (Plugin.on_dispose cctx (fun () -> push log "rollback"));
        failwith "boom")
  in
  let f = Plugin.use ctx bad in
  assert (Plugin.Fiber.state f = Plugin.Fiber.Failed);
  assert (
    match Plugin.Fiber.error f with
    | Some (Failure msg) -> String.equal msg "boom"
    | _ -> false);
  (* effects rolled back: the provision is gone, the disposer ran *)
  assert (Plugin.find ctx key = None);
  assert (!log = [ "rollback" ]);
  (* a failed sibling does not disturb others *)
  let ok = Plugin.component ~name:"ok" (fun _ -> ()) in
  assert (Plugin.Fiber.state (Plugin.use ctx ok) = Plugin.Fiber.Active)

let%test "restart clears a Failed fiber once conditions improve" =
  let ctx = Plugin.make () in
  let attempts = ref 0 in
  let comp =
    Plugin.component ~name:"flaky" (fun _ ->
        incr attempts;
        if !attempts = 1 then failwith "first time fails")
  in
  let f = Plugin.use ctx comp in
  assert (Plugin.Fiber.state f = Plugin.Fiber.Failed);
  Plugin.restart f;
  Plugin.Fiber.state f = Plugin.Fiber.Active && !attempts = 2

let%test "duplicate provider fails the second fiber, first is intact" =
  let ctx = Plugin.make () in
  let key : int Plugin.Key.t = Plugin.Key.create ~name:"solo" () in
  let mk name v =
    Plugin.component ~name ~provide:[ Plugin.Key.Ex key ] (fun cctx ->
        ignore (Plugin.provide cctx key v))
  in
  let f1 = Plugin.use ctx (mk "one" 1) in
  let f2 = Plugin.use ctx (mk "two" 2) in
  assert (Plugin.Fiber.state f1 = Plugin.Fiber.Active);
  assert (Plugin.Fiber.state f2 = Plugin.Fiber.Failed);
  assert (
    match Plugin.Fiber.error f2 with
    | Some (Plugin.Duplicate_provider "solo") -> true
    | _ -> false);
  assert (Plugin.get ctx key = 1);
  (* after the first provider leaves, an explicit restart succeeds *)
  Plugin.dispose f1;
  Plugin.restart f2;
  Plugin.Fiber.state f2 = Plugin.Fiber.Active && Plugin.get ctx key = 2

let%test "providing an undeclared key fails the fiber" =
  let ctx = Plugin.make () in
  let key : int Plugin.Key.t = Plugin.Key.create ~name:"undeclared" () in
  let comp =
    Plugin.component ~name:"sneaky" (fun cctx ->
        ignore (Plugin.provide cctx key 1))
  in
  let f = Plugin.use ctx comp in
  Plugin.Fiber.state f = Plugin.Fiber.Failed
  && match Plugin.Fiber.error f with
     | Some (Plugin.Undeclared_provision "undeclared") -> true
     | _ -> false

(* ── Access discipline ──────────────────────────────────────────────── *)

let%test "reading an undeclared key raises Undeclared_access" =
  let ctx = Plugin.make () in
  let key : int Plugin.Key.t = Plugin.Key.create ~name:"secret" () in
  let _ = Plugin.provide ctx key 5 in
  let comp =
    Plugin.component ~name:"nosy" (fun cctx -> ignore (Plugin.get cctx key))
  in
  let f = Plugin.use ctx comp in
  Plugin.Fiber.state f = Plugin.Fiber.Failed
  && match Plugin.Fiber.error f with
     | Some (Plugin.Undeclared_access "secret") -> true
     | _ -> false

let%test "reading outside the active window raises Inactive_access" =
  let ctx = Plugin.make () in
  let key : int Plugin.Key.t = Plugin.Key.create ~name:"svc" () in
  let leaked = ref None in
  let comp =
    Plugin.component ~name:"c" ~inject:[ Plugin.Key.Ex key ] (fun cctx ->
        leaked := Some cctx)
  in
  let f = Plugin.use ctx comp in
  let _ = Plugin.provide ctx key 1 in
  assert (Plugin.Fiber.state f = Plugin.Fiber.Active);
  let cctx = Option.get !leaked in
  assert (Plugin.get cctx key = 1);
  Plugin.dispose f;
  match Plugin.get cctx key with
  | exception Plugin.Inactive_access "svc" -> true
  | _ -> false

(* ── Isolation and interception ─────────────────────────────────────── *)

let%test_unit "isolation gives a key independent bindings per realm" =
  let ctx = Plugin.make () in
  let key : string Plugin.Key.t = Plugin.Key.create ~name:"db" () in
  let _ = Plugin.provide ctx key "shared" in
  let sandbox = Plugin.isolate ctx (Plugin.Key.Ex key) in
  (* the isolated realm starts empty even though the default realm is bound *)
  assert (Plugin.find sandbox key = None);
  let _ = Plugin.provide sandbox key "sandboxed" in
  assert (Plugin.find sandbox key = Some "sandboxed");
  assert (Plugin.find ctx key = Some "shared");
  (* a component instantiated on the isolated context sees its realm *)
  let seen = ref None in
  let comp =
    Plugin.component ~name:"c" ~inject:[ Plugin.Key.Ex key ] (fun cctx ->
        seen := Some (Plugin.get cctx key))
  in
  let f = Plugin.use sandbox comp in
  assert (Plugin.Fiber.state f = Plugin.Fiber.Active);
  assert (!seen = Some "sandboxed")

let%test "named realms are shared between contexts naming them" =
  let ctx = Plugin.make () in
  let key : int Plugin.Key.t = Plugin.Key.create ~name:"cache" () in
  let a = Plugin.isolate ~realm:"tenant1" ctx (Plugin.Key.Ex key) in
  let b = Plugin.isolate ~realm:"tenant1" ctx (Plugin.Key.Ex key) in
  let c = Plugin.isolate ~realm:"tenant2" ctx (Plugin.Key.Ex key) in
  let _ = Plugin.provide a key 11 in
  Plugin.find b key = Some 11 && Plugin.find c key = None

let%test_unit "interception metadata merges nearest-first" =
  let ctx = Plugin.make () in
  let key : unit Plugin.Key.t = Plugin.Key.create ~name:"api" () in
  let ex = Plugin.Key.Ex key in
  assert (Plugin.interception ctx ex = None);
  let outer = Plugin.intercept ctx ex (`Assoc [ ("timeout", `Int 10); ("retries", `Int 3) ]) in
  let inner = Plugin.intercept outer ex (`Assoc [ ("timeout", `Int 60) ]) in
  (match Plugin.interception inner ex with
   | Some (`Assoc fields) ->
     assert (List.assoc "timeout" fields = `Int 60);
     assert (List.assoc "retries" fields = `Int 3)
   | _ -> assert false);
  match Plugin.interception outer ex with
  | Some (`Assoc fields) -> assert (List.assoc "timeout" fields = `Int 10)
  | _ -> assert false

(* ── Events ─────────────────────────────────────────────────────────── *)

let%test_unit "listeners are tracked effects and fire in order" =
  let ctx = Plugin.make () in
  let ev : int Plugin.Event.t = Plugin.Event.create "tick" in
  let log = ref [] in
  let root_listener = Plugin.on ctx ev (fun n -> push log (Printf.sprintf "root:%d" n)) in
  let comp =
    Plugin.component ~name:"listener" (fun cctx ->
        ignore (Plugin.on cctx ev (fun n -> push log (Printf.sprintf "plugin:%d" n))))
  in
  let f = Plugin.use ctx comp in
  Plugin.emit ctx ev 1;
  assert (!log = [ "root:1"; "plugin:1" ]);
  (* unloading the plugin removes its listener, and only its listener *)
  Plugin.dispose f;
  Plugin.emit ctx ev 2;
  assert (!log = [ "root:1"; "plugin:1"; "root:2" ]);
  Plugin.Disposer.dispose root_listener;
  Plugin.emit ctx ev 3;
  assert (!log = [ "root:1"; "plugin:1"; "root:2" ])

(* ── Toolset service ────────────────────────────────────────────────── *)

module Dummy_tool : Tool.TOOL with type input = unit and type output = string =
struct
  let name = "dummy"
  let aliases = []
  let description = "a test tool"

  type input = unit
  type output = string

  let json_schema () = `Assoc [ ("type", `String "object") ]
  let parse_args _ = Ok ()
  let format_output s = s
  let is_mutating = false
  let describe_action () = "run the dummy test tool"

  type _ Effect.t += Exec : input -> output Effect.t

  let execute () = "dummy output"
end

let%test_unit "toolset registration is revertible" =
  let ctx = Plugin.make () in
  let _ = Plugin.use ctx Plugin.Toolset.provider in
  assert (Plugin.Toolset.snapshot ctx = []);
  let tool = Tool.Tool (module Dummy_tool) in
  let comp =
    Plugin.component ~name:"tool-pack" ~inject:[ Plugin.Key.Ex Plugin.Toolset.key ]
      (fun cctx -> ignore (Plugin.Toolset.register cctx tool))
  in
  let f = Plugin.use ctx comp in
  assert (
    List.map Tool.name_of_packed (Plugin.Toolset.snapshot ctx) = [ "dummy" ]);
  Plugin.dispose f;
  assert (Plugin.Toolset.snapshot ctx = [])

(* ── Nested components ──────────────────────────────────────────────── *)

let%test_unit "disposing a parent cascades to its children" =
  let ctx = Plugin.make () in
  let log = ref [] in
  let child name =
    Plugin.component ~name (fun cctx ->
        push log (name ^ "+");
        ignore (Plugin.on_dispose cctx (fun () -> push log (name ^ "-"))))
  in
  let parent =
    Plugin.component ~name:"parent" (fun cctx ->
        ignore (Plugin.use cctx (child "c1"));
        ignore (Plugin.use cctx (child "c2")))
  in
  let f = Plugin.use ctx parent in
  assert (!log = [ "c1+"; "c2+" ]);
  assert (List.length (Plugin.fibers ctx) = 3);
  Plugin.dispose f;
  (* children retire in LIFO order with the rest of the parent's effects *)
  assert (!log = [ "c1+"; "c2+"; "c2-"; "c1-" ]);
  assert (Plugin.fibers ctx = [])

let%test "a self-dependent component stays pending without crashing" =
  let ctx = Plugin.make () in
  let key : unit Plugin.Key.t = Plugin.Key.create ~name:"self" () in
  let comp =
    Plugin.component ~name:"ouroboros" ~inject:[ Plugin.Key.Ex key ]
      ~provide:[ Plugin.Key.Ex key ] (fun cctx ->
        ignore (Plugin.provide cctx key ()))
  in
  Plugin.Fiber.state (Plugin.use ctx comp) = Plugin.Fiber.Pending

(* ── Observer ───────────────────────────────────────────────────────── *)

let%test "observer sees every state transition" =
  let ctx = Plugin.make () in
  let log = ref [] in
  Plugin.observe ctx (fun f ->
      push log
        (Format.asprintf "%s:%a" (Plugin.Fiber.name f) Plugin.Fiber.pp_state
           (Plugin.Fiber.state f)));
  let comp = Plugin.component ~name:"watched" (fun _ -> ()) in
  let f = Plugin.use ctx comp in
  Plugin.dispose f;
  !log
  = [
      "watched:loading";
      "watched:active";
      "watched:unloading";
      "watched:pending";
      "watched:disposed";
    ]

(* ── Reconciliation ─────────────────────────────────────────────────── *)

let%test_unit "reconcile creates, keeps, rebuilds, and disposes entries" =
  let ctx = Plugin.make () in
  let key : string Plugin.Key.t = Plugin.Key.create ~name:"value" () in
  let plugin config =
    let text = Yojson.Safe.Util.(config |> member "text" |> to_string) in
    Plugin.component ~name:"echo" ~provide:[ Plugin.Key.Ex key ] (fun cctx ->
        ignore (Plugin.provide cctx key text))
  in
  let r = Plugin.Reconcile.create ctx in
  let entry ?(enabled = true) id text =
    { Plugin.Reconcile.id; enabled; config = `Assoc [ ("text", `String text) ]; plugin }
  in
  (* create *)
  Plugin.Reconcile.apply r [ entry "e1" "hello" ];
  assert (Plugin.find ctx key = Some "hello");
  let f1 = Option.get (Plugin.Reconcile.fiber r "e1") in
  (* unchanged entry keeps its fiber *)
  Plugin.Reconcile.apply r [ entry "e1" "hello" ];
  assert (Option.get (Plugin.Reconcile.fiber r "e1") == f1);
  (* config change rebuilds *)
  Plugin.Reconcile.apply r [ entry "e1" "world" ];
  assert (Plugin.find ctx key = Some "world");
  assert (not (Option.get (Plugin.Reconcile.fiber r "e1") == f1));
  (* disable disposes but keeps the slot *)
  Plugin.Reconcile.apply r [ entry ~enabled:false "e1" "world" ];
  assert (Plugin.find ctx key = None);
  assert (Plugin.Reconcile.fiber r "e1" = None);
  (* re-enable *)
  Plugin.Reconcile.apply r [ entry "e1" "back" ];
  assert (Plugin.find ctx key = Some "back");
  (* removal disposes *)
  Plugin.Reconcile.apply r [];
  assert (Plugin.find ctx key = None);
  assert (Plugin.fibers ctx = [])

let%test "reconcile rejects duplicate ids" =
  let ctx = Plugin.make () in
  let r = Plugin.Reconcile.create ctx in
  let entry id =
    {
      Plugin.Reconcile.id;
      enabled = true;
      config = `Null;
      plugin = (fun _ -> Plugin.component ~name:id (fun _ -> ()));
    }
  in
  match Plugin.Reconcile.apply r [ entry "dup"; entry "dup" ] with
  | exception Invalid_argument _ -> true
  | () -> false

(* ── Temporal composability: full recovery ──────────────────────────── *)

let%test "loading then unloading recovers the initial environment" =
  let ctx = Plugin.make () in
  let x : int Plugin.Key.t = Plugin.Key.create ~name:"x" () in
  let ev : unit Plugin.Event.t = Plugin.Event.create "e" in
  let fired = ref 0 in
  let comp =
    Plugin.component ~name:"everything" ~provide:[ Plugin.Key.Ex x ]
      (fun cctx ->
        ignore (Plugin.provide cctx x 99);
        ignore (Plugin.on cctx ev (fun () -> incr fired));
        ignore (Plugin.use cctx (Plugin.component ~name:"kid" (fun _ -> ()))))
  in
  let f = Plugin.use ctx comp in
  Plugin.emit ctx ev ();
  assert (!fired = 1);
  assert (Plugin.find ctx x = Some 99);
  assert (List.length (Plugin.fibers ctx) = 2);
  Plugin.dispose f;
  Plugin.emit ctx ev ();
  (* binding gone, listener gone, child gone: the context is recovered *)
  !fired = 1 && Plugin.find ctx x = None && Plugin.fibers ctx = []
