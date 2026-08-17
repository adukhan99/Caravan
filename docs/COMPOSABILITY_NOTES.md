# Composability Notes

Running log for the composability backend (`Caravan.Plugin`) — the new
direction after the overhaul (whose log this file replaces): porting the
model of DeepSeek/PKU's *"A Programming Paradigm for Spatiotemporal
Composability"* (the Cordis / dsh foundation) into Caravan so the
harness becomes modular and extensible at runtime. Same charter as the
old log: pain points, friction, decisions, and honest limits — newest
entries appended per section.

## What was built (2026-08-16)

`lib/plugin.ml{,i}` — the paper's model as one contained module:

- **Revertible effects** (`track`, `on_dispose`): every mutation returns
  a disposer the runtime accumulates; unload replays LIFO (paper §3.1,
  Cordis `ctx.effect`).
- **Reactive coeffects** (`provide`/`get`/`find` over typed generative
  keys): dependency satisfaction drives activation/deactivation; the
  withdrawal ordering of §4.3.1 is honored — dependents drain first and
  can still read the service during their own teardown.
- **Components & fibers** (`component`, `use`, `dispose`, `restart`,
  `Fiber.state`): the base calculus of §4.2 plus the failure layer of
  §4.3.4 — a raising body rolls back and marks the fiber `Failed`
  without disturbing siblings.
- **Isolation realms** (`isolate`, private or named-shared) and
  **interception metadata** (`intercept`/`interception`) — §3.2.3.
- **Typed event bus** (`Event`, `on`, `emit`) with tracked listeners.
- **`Toolset` service** — packed tools registered revertibly, snapshot
  handed to existing `Session`/`Agent` APIs unchanged.
- **`Reconcile`** — declarative entry list diffed into minimal fiber
  transitions (§5.2.1's loader, without persistence).

Tests: `test/test_plugin.ml`, 25 cases covering LIFO recovery, reactive
(de)activation, chain cascade ordering, teardown-window reads, failure
rollback/restart, access discipline, realms, interception merge, events,
toolset, nesting, reconciliation, and full environment recovery.
Example: `examples/plugin_system/`. Guide: `docs/src/plugins.md`.

## Friction encountered

1. **`effect` is a keyword in OCaml 5.3.** The paper/Cordis name for the
   tracking primitive can't be an OCaml identifier anymore. Named it
   `track`; kept the paper vocabulary everywhere else.
2. **Warning 5 punished the Cordis API shape.** Returning bare
   `unit -> unit` disposers meant every ignoring caller (the common
   case — the fiber auto-disposes) tripped `ignored-partial-application`
   at Caravan's zero-warning bar. Fixed at the API level: disposers are
   an abstract `Disposer.t` (`ignore` is clean; explicit early disposal
   is `Disposer.dispose`).
3. **GADT existentials escape in store lookups.** The heterogeneous
   store (`B : 'a Key.t * 'a -> binding`) needs the standard
   locally-abstract-type + equality-witness dance; inner closures must
   be annotated (`: a option`) or the existential "escapes its
   equation". Isolated in one `unpack` helper.
4. **Re-notify after activation, not just at provide time.** A
   provider's `provide` runs while its fiber is still `Loading`, when
   its bindings don't yet count (σ unions Active fibers only, paper
   eq. 40). Dependents must be re-notified when the provider commits to
   `Active` — missing this made chains stall in the first engine draft.
   Same subtlety in reverse: `Unloading` must stop counting *before*
   the provider's disposers run, or dependents would never drain first.

## Decisions / divergences from the paper (review welcome)

- **Synchronous base calculus, not the inertia layer (§4.3.3).** All
  transitions are atomic and run to completion; there is no in-flight
  `Future`. Rationale: Caravan's Eio usage is confined to
  provider/tool I/O, and a sync core is provable with plain unit tests.
  If plugin bodies ever need to await I/O, the natural next layer is an
  Eio-fibered `reload`/`unload` pair with the mutual chaining of
  Cordis's Algorithm 5 — the state space (`Unloading` etc.) is already
  shaped for it.
- **Single-source is sticky-Failed.** A second provider for an occupied
  key fails at its own activation (like Cordis's `provide` throw)
  instead of being refused at instantiation (the paper's O-Insert
  premise). It does not auto-retry when the first provider leaves —
  `restart` is explicit, per §4.3.4's no-silent-retry stance.
- **Interception simplified.** Context-carried JSON metadata with
  nearest-wins shallow merge; no per-key metadata monoids, no
  component-declared metadata, no provider functions `M_k -> V_k`. The
  full construction (Def. 30/31) buys expressiveness OCaml's type
  system makes expensive; revisit if a real consumer needs it.
- **No HMR chapter.** OCaml links statically; `Reconcile` covers
  config-driven rebuilds, and that's the honest extent of "hot
  replacement" without Dynlink adventures.
- **Registry scans are linear.** `notify`/`drain` iterate all fibers
  (as does Cordis's Algorithm 3). Fine for harness-scale plugin counts
  (tens); index by key uid if that assumption breaks.

## What was built (2026-08-17) — the harness wired onto the runtime

The open items of the first entry, fulfilled:

- **`Plugin_host` (lib/plugin_host.ml{,i})** — the policy layer the CLI
  runs on: a registry of named builders (`Yojson.Safe.t -> component`),
  `[[plugins]]` config entries reconciled into fibers, and two
  pre-registered builders: `tools.builtin` (registers the built-in
  tools; `exclude` drops by name) and `tools.mcp` (connects an MCP
  server on activation, closes it on disposal — MCP mounts are now
  revertible, and a failed connection is a visible `Failed` fiber
  instead of a swallowed warning).
- **Config-driven composition** — `Config.get_plugins` parses
  `[[plugins]]` (with a TOML→JSON converter for arbitrary per-plugin
  config). When the table is absent, `Plugin_host.load` synthesizes the
  classic composition (built-ins + `[[mcp.servers]]`), so every
  existing config behaves identically; declared entries merge over
  those defaults by id, so `enabled = false` can switch a default off.
- **`bin/main.ml` runs on the host** — `all_tools`/`init_mcp` replaced
  by the lazy host; sessions read `Toolset.snapshot`; the new
  `/plugins` command lists entries with live lifecycle states and
  `enable|disable <id>` reconciles one entry and refreshes the
  session's toolset in place (`Session.with_tools`, new).
- **Provider as a service** — `Plugin.Services.provider` is bound at
  session setup and re-bound on `/provider` and `/model` switches
  (withdraw-then-provide, so dependents reload against the new
  provider).
- **Lifecycle events in `Trace`** — `Plugin.trace_transitions` emits
  `Trace.Plugin_transition` per fiber state change (observers are now
  a list, not a single slot); rendered dim in verbose mode, always in
  the JSONL transcript.
- **The carried-over error gap, closed** — `Trace.Run_error` +
  `Trace.error`, emitted from the REPL turn/agent/summarize/one-shot
  catch sites. The renderer deliberately prints nothing for it (the
  catch sites already own the terminal output); the event exists so
  failed sessions leave auditable transcripts.

Tests: `test/test_plugin_host.ml`, 13 cases (config parsing, default
synthesis, merge-over-defaults, unknown-builder tolerance, live
enable/disable, custom builders, MCP failure isolation, provider
rebind reactivity, trace transitions, accumulating observers,
Run_error JSON shape, session tool swap). Smoke-tested end-to-end in
the REPL offline (`/plugins`, `/tools`, live disable).

### Friction encountered (this round)

5. **Emitting `Run_error` from catch sites risks double-printing.**
   The catch sites already print failures in their own formats (REPL
   red lines, one-shot stderr + exit codes, `--json` payloads), and
   several of those channels must not gain stray stdout lines. Decision:
   the renderer ignores `Run_error` entirely — the event's job is the
   transcript, the catch site keeps owning the terminal. Revisit if a
   front-end ever wants to be pure-sink.
6. **`init_mcp` was called at four entry points**, each of which had to
   keep working when the host is created lazily. A `lazy` host whose
   forcing performs the first `load` covers every path (including ones
   that never call the init explicitly).

### Decisions (review welcome)

- **`[[plugins]]` merges over defaults rather than replacing them.**
  A user adding one entry must not silently lose their MCP servers;
  overriding by id still allows disabling any default.
- **`/plugins` toggles are session-only** — the config file is not
  written. Persistence is `caravan config` / editing the TOML; the
  REPL toggle is for experimentation.
- **The delegate tool stays outside the plugin runtime** for now: it
  needs Eio handles (`~net ~clock`) at construction, so it is layered
  onto the snapshot per session as before.

## Open items / future direction

- **Subagent sandboxes via `isolate`.** Still open, deliberately:
  subagent tool lists are built eagerly from config
  (`Subagents.build_spec` → `Delegate.make`), with no context
  participating. Doing this honestly means threading a per-worker
  derived context (`isolate` on `Toolset.key`) through delegate
  construction so plugins can register worker-only tools — a refactor
  of the delegate path, not a bolt-on. Design sketch: give each
  `[[subagents]]` entry an optional `realm` field; workers with one
  resolve the toolset in that realm.
- **Per-plugin provider slots.** `Services.provider` is a single
  binding; `isolate` already supports realm-per-plugin providers when
  a consumer needs a different model — needs a config surface.
- **Async inertia layer** (paper §4.3.3) — unchanged from the first
  entry: an Eio-fibered `reload`/`unload` when plugin bodies need to
  await I/O without blocking `use`. MCP mounts are today's only slow
  activation (process spawn + handshake at startup, same cost as the
  old eager init).
- **Web UI parity**: the web front-end reads the same host via
  `make_session`, but has no `/plugins`-equivalent panel yet.
