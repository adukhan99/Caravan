# Development

## Build & test

```bash
opam install . --deps-only --with-test -y
dune build          # zero warnings expected
dune test           # all offline — mock providers, no network
dune build @doc     # odoc API docs (requires odoc)
```

## CI

- `.github/workflows/ci.yml` — build + test on OCaml 5.2 / 5.3, plus a
  check that `Caravan.opam` stays in sync with `dune-project`;
- `.github/workflows/deploy.yml` — on push to `main`, builds this book
  (mdBook) and the odoc API reference and publishes both to GitHub Pages
  (`/` = book, `/api/` = odoc).

## Testing philosophy

Tests never touch the network: providers are mocked as first-class
modules. For end-to-end verification during development we drive the
real binary against a scripted OpenAI-compatible mock server and a PTY
harness for the line editor — every fixed bug gets a regression test.

## Repository map

```
bin/        CLI: main, line editor, Trace renderer, web UI, subagent wiring
lib/        core: types, session, agent, trace, tls, lisp, memory, …
lib/providers/  the OpenAI-compatible engine + registry
lib/tools/      tool modules (auto-registered at build time)
docs/       this book (src/) + example config + overhaul notes
examples/   single-endpoint config, two subagent-swarm programs
scripts/    installer, docs renderer
test/       inline test suite (ppx_expect / ppx_inline_test)
```

## Extending safely

- New tool → [Library Guide](library.md#writing-a-tool); mark it
  mutating if it changes state.
- New provider → registry entry, or a `PROVIDER` module for exotic APIs.
- Anything user-visible → emit `Trace` events, never print from `lib/`.
- New plugin / dynamic component → [Plugins](plugins.md); go through
  the context (`track`, `provide`, `on`) so unloading stays revertible.
- Keep the pain-point log honest:
  [`docs/COMPOSABILITY_NOTES.md`](https://github.com/adukhan99/Caravan/blob/main/docs/COMPOSABILITY_NOTES.md)
  records friction, divergences from the paper, and why decisions fell
  the way they did.
