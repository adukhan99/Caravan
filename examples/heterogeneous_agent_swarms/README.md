# Heterogeneous Agent Swarm Example

> **Gemini orchestrates; Qwen3.5 workers execute.**  
> Remote API tokens are spent only on high-level reasoning — all mechanical,
> bounded tasks are farmed out to local inference at zero API cost.

---

## Architecture

```
User prompt
    │
    ▼
┌──────────────────────────────────────────────┐
│  Gemini 2.5 Pro — Orchestrator               │  ← remote API (expensive)
│  Decomposes, plans, and synthesises          │
│  Has access to: finish + delegate tools only │
└──────┬───────────────────────────────────────┘
       │  calls delegate{"subagent":"code_writer","task":"..."}
       ▼
┌──────────────────────────────────────────────┐
│  Subagent Router (Caravan Delegate tool)     │
│  · Validates spec at startup (compile-time)  │
│  · Builds Qwen3.5 provider from config       │
│  · Creates cold Session (no history leak)    │
│  · Injects compaction suffix into sys prompt │
└──────┬───────────────────────────────────────┘
       │
       ├─────────────────────────────────────────┐
       │  code_writer (qwen3:5b @ localhost)      │  ← local, free
       │  tools: bash, read_file, write_file      │
       │  gres: { thinking=true, tools=true }     │
       ├─────────────────────────────────────────┘
       │  summarizer (qwen3:5b @ localhost)       │
       │  tools: (none)                           │
       │  gres: { thinking=false, tools=false }   │
       └─────────────────────────────────────────┘
```

---

## Prerequisites

| Component | What you need |
|---|---|
| Gemini API access | `GEMINI_API_KEY` env var |
| Local Ollama | `ollama serve` + `ollama pull qwen3:5b` |
| Caravan built | `opam install . --deps-only && dune build` |

---

## Config (`config.toml`)

Copy `config.toml` from this directory to `~/.caravan/config.toml` (or point
`CARAVAN_CONFIG` at it).

## Running the example

```bash
# From the repo root
dune exec examples/heterogeneous_agent_swarms/swarm.exe
```

Or start the REPL with this config and use `/agent` commands — the delegate
tool will be available automatically.

---

## GRES resource model

Inspired by SLURM's [Generic Resources (GRES)](https://slurm.schedmd.com/gres.html),
each `[[subagents]]` entry can carry a `[gres]` sub-table:

```toml
[gres]
thinking  = true   # extended reasoning / thinking tokens
tools     = true   # tool-calling support
vision    = false  # multi-modal image input
gen_image = false  # image generation output
```

All fields default to `true` (full capabilities) except `gen_image` which is
`false` by default.  Unknown keys are preserved in `extra` for forward
compatibility — add `gpu_memory_gb = 8` today and it will round-trip without
breaking anything.
