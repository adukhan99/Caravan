# Configuration

One TOML file: `~/.caravan/config.toml` (or the path in `CARAVAN_CONFIG`).
`caravan init` writes it (mode 0600). Edit it from any surface — no shell
required:

```bash
caravan config set permissions ask     # CLI
/config set permissions ask            # REPL (and /key <provider> for keys)
# web UI: ⚙ settings panel
```

## Resolution order

1. **CLI flags** — `-p/--provider`, `-m/--model`, `--base-url`, `-s/--system`;
2. **Environment** — `CARAVAN_PROVIDER`, `CARAVAN_MODEL`, `CARAVAN_BASE_URL`,
   `CARAVAN_STREAM`, `CARAVAN_MAX_TURNS`, `CARAVAN_PERMISSIONS`,
   `CARAVAN_TRANSCRIPT`, `CARAVAN_NUDGE`, `CARAVAN_SUBAGENTS`,
   `CARAVAN_STRICT_MODE`, `CARAVAN_SPINNER`, `CARAVAN_TLS_INSECURE`,
   provider key vars (`ANTHROPIC_API_KEY`, …);
3. **TOML root keys**, then the same keys inside `[orchestrator]`;
4. **Registry / module defaults**.

## Core keys

```toml
provider    = "anthropic"          # see `caravan providers`
model       = "claude-sonnet-4-5"  # omit → provider default
# base_url  = "http://my-gateway:8000/v1"
system      = "You are a concise research assistant."

stream      = true       # stream tokens as they arrive
max_turns   = 15         # agent turn budget
nudge       = true       # budget-awareness nudges in agent loops
permissions = "auto"     # auto | ask | readonly
transcript  = true       # JSONL session logs in ~/.caravan/logs/
strict_mode = 1          # bash tool: 0 permissive, 1 single-command, 2 hidden
enable_subagents = true  # offer delegate when [[subagents]] exist
```

`caravan config keys` (or `/config keys`) lists every editable key with
accepted values.

## API keys

```toml
[api_keys]
anthropic = "sk-ant-..."
groq      = "gsk_..."
```

Environment variables take precedence and are the recommended home for
secrets; the `[api_keys]` table is for hosts where a private 0600 file
beats env plumbing (cron, HPC batch scripts).

## Subagents

See [Subagents](subagents.md) for `[[subagents]]` and `[providers.*]`
tables.

## Spinner

```toml
[spinner]
enabled = true    # auto-disabled when stderr is not a TTY
verbose = false
thinking = ["Thinking", "Pondering", "Mulling"]   # arrays pick at random
```

## MCP servers

```toml
[[mcp.servers]]
name      = "filesystem"
transport = "stdio"
command   = "npx"
args      = ["-y", "@modelcontextprotocol/server-filesystem", "/home/you/ws"]
```

## Diagnostics

```bash
caravan doctor          # validity, key presence, reachability, subagents
caravan config show     # print the active file
caravan config path     # where it lives
```

A fully annotated example lives at
[`docs/example_config.toml`](https://github.com/adukhan99/Caravan/blob/main/docs/example_config.toml).
