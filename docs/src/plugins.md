# Plugins — Spatiotemporal Composability

`Caravan.Plugin` is a dynamic-composition runtime: components that can be
loaded, unloaded, and rewired **while the system runs**, with the runtime
— not programmer discipline — guaranteeing that removal reverts every
side effect and that dependencies stay consistently wired.

It is an OCaml implementation of the model in
["A Programming Paradigm for Spatiotemporal Composability"](https://github.com/cordiverse/paper)
(Shi, Zhang, Cui — Peking University / DeepSeek-AI, 2026), the formal
foundation behind the Cordis framework and the DeepSeek agent harness
(dsh). The paper identifies two orthogonal guarantees:

- **Temporal composability** — every mutation a component makes carries
  an inverse the runtime tracks; unloading replays the inverses in LIFO
  order, so the environment is recovered exactly.
- **Spatial composability** — components declare what they *inject*
  (read from the environment) and *provide* (write to it); the runtime
  resolves the declarations reactively, activating a component when its
  dependencies are present and deactivating it when they go away.

Why this matters for an agent harness: a harness that composes tool
suites, providers, MCP servers, and memory backends at runtime — or that
one day installs components an agent generated for itself — needs to
remove a faulty component without restarting, and needs dependents to
react when a component is replaced. That is exactly what this runtime
makes structural.

## Quick start

```ocaml
open Caravan

(* A typed service key. *)
let db_key : Db.t Plugin.Key.t = Plugin.Key.create ~name:"database" ()

(* A provider component: declares what it may provide. *)
let db_plugin =
  Plugin.component ~name:"db" ~provide:[ Plugin.Key.Ex db_key ]
    (fun ctx ->
      let db = Db.connect () in
      ignore (Plugin.provide ctx db_key db);
      ignore (Plugin.on_dispose ctx (fun () -> Db.close db)))

(* A consumer component: declares what it injects. It will not run
   until the database is provided, and is deactivated (cleanly, with
   the db still readable during its teardown) when the db goes away. *)
let api_plugin =
  Plugin.component ~name:"api" ~inject:[ Plugin.Key.Ex db_key ]
    (fun ctx ->
      let db = Plugin.get ctx db_key in
      let server = Server.start db in
      ignore (Plugin.on_dispose ctx (fun () -> Server.stop server)))

let () =
  let ctx = Plugin.make () in
  let _api = Plugin.use ctx api_plugin in   (* pending: no db yet *)
  let db = Plugin.use ctx db_plugin in      (* both activate *)
  Plugin.dispose db                          (* api deactivates first,
                                                then db tears down *)
```

Run the offline demo:
`dune exec examples/plugin_system/plugin_system.exe`.

## The model in five pieces

| Paper concept | API | What it does |
|---|---|---|
| revertible effect | `Plugin.track ctx run` | run a setup step now, register its inverse; LIFO replay on unload |
| coeffect provision | `Plugin.provide ctx key v` | bind a typed service; tracked, withdrawal ordered after dependents drain |
| coeffect access | `Plugin.get ctx key` | read a service, checked against the component's declarations |
| component | `Plugin.component ~inject ~provide body` | declarations + effectful body |
| fiber | `Plugin.use ctx comp` | one live instantiation with a lifecycle: `Pending → Loading → Active → Unloading → …` (or `Failed`) |

Everything a component does to the outside world goes through its
context: `track`, `provide`, `on` (event listeners), `use` (child
components), `Toolset.register`. Because each is tracked, *teardown is
derived from loading* — components rarely need explicit cleanup code
beyond `on_dispose` for resources the runtime cannot see.

## The discipline (and its error messages)

Reads and writes are checked against declarations at the point of use:

| Violation | Exception |
|---|---|
| `get` on a key the component never declared | `Undeclared_access` |
| `get` while the declaring fiber is not committed to a provider | `Inactive_access` |
| `get` at root with no binding | `Unprovided` |
| `provide` on a key outside the component's `provide` list | `Undeclared_provision` |
| second provider for a key in the same realm | `Duplicate_provider` |
| creating effects on a non-loading, non-active context | `Inactive_context` |

A component body that raises (including any of the above) marks its
fiber `Failed` and rolls back the effects it had installed; siblings are
untouched. `Plugin.restart` retries a failed fiber explicitly — the
runtime deliberately does not retry a body that has proven unsound
against an unchanged environment (paper §4.3.4).

## Isolation and interception

`Plugin.isolate ctx (Key.Ex key)` derives a context in which `key`
resolves in a separate *realm* — a private one by default, or a shared
named one with `~realm:"tenant1"`. Components instantiated on the
derived context inherit it: the same key, different binding. Use it for
sandboxed subagents, per-session tool tables, or test doubles.

`Plugin.intercept ctx (Key.Ex key) json` attaches metadata to accesses
of `key` through the derived context; a service implementation can
consult it with `Plugin.interception` to adjust behaviour per consumer
(timeouts, rate limits, permissions) without the consumer changing.

## Events

`Plugin.Event.create`, `Plugin.on`, and `Plugin.emit` form a typed event
bus whose listener registrations are tracked effects — a plugin's
listeners disappear with the plugin.

## The toolset service

`Plugin.Toolset` bridges the runtime to Caravan's agents: a shared
registry of `Tool.packed_tool`s that plugins extend revertibly.

```ocaml
let ctx = Plugin.make () in
ignore (Plugin.use ctx Plugin.Toolset.provider);
let pack =
  Plugin.component ~name:"fs-tools"
    ~inject:[ Plugin.Key.Ex Plugin.Toolset.key ]
    (fun ctx ->
      ignore (Plugin.Toolset.register ctx
        (Tool.Tool (module CaravanTools.Read_file.Read_file))))
in
ignore (Plugin.use ctx pack);
(* hand the live tool list to an agent *)
let tools = Plugin.Toolset.snapshot ctx in
```

`snapshot` gives an ordinary `Tool.packed_tool list` for
`Session.create` / `Agent.run`; call it per run to pick up whatever the
plugin set currently provides.

## Declarative reconciliation

`Plugin.Reconcile` turns an entry list — id, enabled flag, JSON config,
component builder — into the corresponding set of running fibers, and
incrementally reconciles on every `apply`: new entries instantiate,
removed ones dispose, and a changed config or flag rebuilds just that
entry. This is the loader pattern of the paper's §5.2.1: an orchestrator
edits a description; the runtime performs the minimal transitions.

## Scope and honest limits

- **Synchronous core.** Transitions are the paper's base calculus +
  failure: atomic and run-to-completion. The asynchrony/inertia layer
  (paper §4.3.3) is not implemented; if a body blocks, `use` blocks.
  An Eio-fibered lifecycle is a natural future layer.
- **No hot code loading.** OCaml links statically; components are OCaml
  values, so "replacing a module" means rebuilding a fiber from a new
  component value (`Reconcile` covers the config-driven case). The
  paper's HMR chapter applies to its JavaScript host, not here.
- **Single-source is sticky.** A second provider for an occupied key
  fails at activation and stays `Failed` until an explicit `restart`,
  rather than being refused at instantiation.
- **Interception carries context metadata only** — the paper's per-key
  metadata monoids and component-declared metadata are simplified to
  JSON with nearest-wins shallow merge.

See [`docs/COMPOSABILITY_NOTES.md`](https://github.com/adukhan99/Caravan/blob/main/docs/COMPOSABILITY_NOTES.md)
for the running friction log of this subsystem.
