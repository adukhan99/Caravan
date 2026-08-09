# Subagents

Declare workers in the config and the orchestrator model gets a
`delegate` tool — no OCaml required. Each worker starts **cold** (no
history bleed), runs its own tool loop on its own provider/model, and
returns a compact result.

## Declaring workers

```toml
# Optional master switch (default: on when [[subagents]] tables exist)
enable_subagents = true

# A worker on a lab endpoint, declared explicitly:
[providers.local_qwen]
base_url    = "http://127.0.0.1:8080/v1"
api_key_env = "QWEN_KEY"          # optional

[[subagents]]
name          = "coder"
provider      = "local_qwen"      # a [providers.*] table, or a registry name
model         = "qwen3:8b"
tools         = ["bash", "write_file", "read_file"]
system_prompt = "You write minimal, correct OCaml."
temperature   = 0.2               # optional
max_tokens    = 2048              # optional

# A worker on a registry provider — just name it:
[[subagents]]
name          = "reviewer"
provider      = "anthropic"
model         = "claude-haiku-4-5"
tools         = []                # finish is always added
system_prompt = "You review diffs ruthlessly but concisely."
```

## Using them

- `/subagents` shows the roster with provider/key health;
- the model calls `delegate {"subagent": "coder", "task": "…"}` —
  the task must be self-contained (workers have no memory of the parent
  conversation);
- results stream back into the orchestrator's context.

## Governance

- `delegate` is a **mutating** tool: `ask` prompts, `readonly` denies;
- every delegation and each worker's own tool calls flow through the
  transcript — the audit trail covers the whole tree;
- misconfigured entries (unknown provider, missing tool) degrade to
  startup warnings, never crashes; `caravan doctor` validates the roster;
- toggle without editing files: `/config set enable_subagents false`
  or `CARAVAN_SUBAGENTS=0`.

## Programmatic swarms

For dynamic spawning (models designing their own workers), see the two
swarm examples in
[`examples/`](https://github.com/adukhan99/Caravan/tree/main/examples)
and `Caravan.Subagent` in the API docs.
