# Plugin System Example

A tour of `Caravan.Plugin`, the spatiotemporal composability runtime
(see [docs/src/plugins.md](../../docs/src/plugins.md)). Runs entirely
offline — no provider, no network:

```bash
dune exec examples/plugin_system/plugin_system.exe
```

What it shows:

1. **Reactive activation** — a `greeter` component declares a dependency
   on a `greeting-style` service and sits `pending` until some provider
   binds it; the moment the service appears the component activates.
2. **Ordered withdrawal** — disposing the service deactivates the
   dependent *first* (its teardown can still read the service), then
   removes the binding; providing a replacement reactivates it.
3. **Revertible tool registration** — a plugin registers `read_file`
   into the shared `Toolset` service; unloading the plugin removes the
   tool automatically. No manual cleanup code anywhere.
4. **Declarative reconciliation** — a desired-state entry list is
   diffed against the running fibers: config changes rebuild the fiber,
   removal disposes it.

Every lifecycle transition is printed by an observer installed with
`Plugin.observe`.
