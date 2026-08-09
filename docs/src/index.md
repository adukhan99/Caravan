# Caravan

**Caravan** is a typed agentic CLI harness and LLM orchestration framework
for OCaml — a working autonomous agent out of the box, light enough for
HPC nodes, containers, and non-root environments.

```
❯ /agent summarize the files in this directory
⏺ ls({"path": "."})
  ⎿ # ls .  (cwd: /home/you/project) (+14 lines) [0.0s]
  ✔ Task finished: An OCaml project with a dune build, 3 libraries…
```

## Why Caravan

| | |
|---|---|
| **Accountable** | Every model call, tool call, and nudge is a structured event; sessions write JSONL transcripts to `~/.caravan/logs/`. |
| **13 providers** | From a 1B llama on a laptop to Claude / GPT-4o / Gemini, behind one interface. |
| **Governed** | Tool permission modes `auto` / `ask` / `readonly`; verified TLS. |
| **Scripting-native** | `caravan agent "task" --json` → one JSON object, real exit codes. |
| **Hygienic** | One binary, one 0600 TOML config, no runtime file spew. |
| **Typed** | Pipelines are `'a -> ('b, string) result`; tools are typed first-class modules. |

## Where to go

- New here → [Installation](install.md), then [Quick Start](quickstart.md).
- Driving the CLI → [CLI Reference](cli.md) and [Configuration](configuration.md).
- Building agents → [Agents](agents.md), [Subagents](subagents.md), [Slip](slip.md).
- Writing OCaml against Caravan → [Library Guide](library.md) and the
  [API reference](https://adukhan99.github.io/Caravan/api/) (odoc).
