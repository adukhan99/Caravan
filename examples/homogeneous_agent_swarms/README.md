# Homogeneous Agent Swarm Example

> **A single powerful model (e.g. Gemini 2.5 Pro) dynamically clones itself (homogeneous workers) on-the-fly.**  
> Rather than relying on a static pool of pre-configured subagents, the orchestrator spawns subagents dynamically with customized personas, instructions, and toolsets.

---

## Architecture

```
User prompt
    │
    ▼
┌──────────────────────────────────────────────┐
│  Gemini 2.5 Pro — Swarm Orchestrator         │  ← remote API (primary planner)
│  Decomposes, plans, and controls execution   │
│  Has access to: finish + spawn_agent tools    │
└──────┬───────────────────────────────────────┘
       │  calls spawn_agent{"role":"coder", "tools":["bash", "write_file"], ...}
       ▼
┌──────────────────────────────────────────────┐
│  Dynamic Subagent Swarm (Homogeneous Clones) │
│  · Runs same provider + model as parent      │
│  · Starts cold with no history bleed         │
│  · Permitted tools are dynamically filtered  │
└──────┬───────────────────────────────────────┘
       │
       ├─────────────────────────────────────────┐
       │  coder (gemini-2.5-pro clone)           │  ← dynamically spawned
       │  tools: bash, write_file, finish        │
       ├─────────────────────────────────────────┘
       │  reviewer (gemini-2.5-pro clone)        │  ← dynamically spawned
       │  tools: finish                          │
       └─────────────────────────────────────────┘
```

---

## Key Features

1. **Dynamic Cloning**: Subagents inherit the parent session's provider and model name automatically.
2. **On-the-Fly Role & Persona Definition**: The parent model specifies the system prompt and role for each worker child, tailoring their behavior to the specific step in the plan.
3. **Dynamic Tool Filtering**: The parent model selects the exact subset of tools the child has access to, minimizing prompt clutter, preventing model confusion, and ensuring security boundaries (e.g., granting filesystem access only to code-writing agents).
4. **Clean Recursive Spawning**: Supports passing the `spawn_agent` tool to children if hierarchical multi-layered swarms are desired.

---

## Prerequisites

| Component | What you need |
|---|---|
| Gemini API access | `GEMINI_API_KEY` env var |
| Caravan built | `opam install . --deps-only && dune build` |

---

## Config (`config.toml`)

Copy `config.toml` from this directory to `~/.caravan/config.toml` (or point `CARAVAN_CONFIG` at it).

To run locally with Ollama, update the `[orchestrator]` section in `config.toml`:
```toml
[orchestrator]
provider      = "ollama"
model         = "llama3.2"  # or your preferred local model
```

---

## Running the example

```bash
# From the repo root
GEMINI_API_KEY=<your-key> dune exec examples/homogeneous_agent_swarms/swarm.exe
```

---

## Code Structure

- [swarm.ml](file:///home/adukhan/Documents/Code/OCaml/Caravan/examples/homogeneous_agent_swarms/swarm.ml): Implements the dynamic `spawn_agent` tool and runs the orchestrator loop.
- [config.toml](file:///home/adukhan/Documents/Code/OCaml/Caravan/examples/homogeneous_agent_swarms/config.toml): Configures the Gemini and Ollama providers.
