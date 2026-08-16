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

## Open items / future direction

- **Wire the harness onto the runtime.** `bin/main.ml` still assembles
  tools/providers statically. Next steps, in rough order of value:
  session toolsets read from `Toolset.snapshot` (live `/tools` +
  MCP-server mounts as plugins), providers as a service key, subagent
  sandboxes via `isolate`.
- **Config-driven plugin entries.** A `[[plugins]]` TOML table feeding
  `Reconcile` would give end users declarative composition without
  writing OCaml.
- **Lifecycle events into `Trace`.** `observe` exists; emitting
  structured `Trace` events from it would put plugin transitions in the
  session transcript.
- *(carried over from the overhaul log's field notes)* Provider/tool
  exceptions surface to the user but are not written to the JSONL
  transcript — `Trace` should gain an Error event emitted from the
  REPL/agent catch sites so failed sessions are auditable too.
