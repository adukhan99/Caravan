# Configuration Guide

Caravan reads one TOML file — `~/.caravan/config.toml` by default, or the
path in `CARAVAN_CONFIG`. `caravan init` writes it for you (mode 0600);
`caravan config set KEY VALUE` edits it from the CLI.

## Resolution order

For every setting, the first source that provides a value wins:

1. **CLI flags** — `-p/--provider`, `-m/--model`, `--base-url`, `-s/--system`;
2. **Environment** — `CARAVAN_PROVIDER`, `CARAVAN_MODEL`, `CARAVAN_BASE_URL`,
   `CARAVAN_STREAM`, `CARAVAN_MAX_TURNS`, `CARAVAN_PERMISSIONS`,
   `CARAVAN_TRANSCRIPT`, `CARAVAN_NUDGE`, `CARAVAN_STRICT_MODE`,
   `CARAVAN_SPINNER`, `CARAVAN_TLS_INSECURE`, provider key vars;
3. **TOML root keys**, then the same keys inside `[orchestrator]`;
4. **Registry / module defaults**.

## Core keys

```toml
provider    = "anthropic"          # see `caravan providers`
model       = "claude-sonnet-4-5"  # omit to use the provider default
# base_url  = "http://my-gateway:8000/v1"   # custom endpoints
system      = "You are a concise research assistant."

stream      = true       # stream tokens as they arrive
max_turns   = 15         # agent turn budget
nudge       = true       # budget-awareness nudges in agent loops
permissions = "auto"     # auto | ask | readonly (mutating-tool policy)
transcript  = true       # JSONL session logs in ~/.caravan/logs/
strict_mode = 1          # bash tool: 0 permissive, 1 single-command, 2 hidden
```

## API keys

```toml
[api_keys]
anthropic = "sk-ant-..."
groq      = "gsk_..."
```

Environment variables (`ANTHROPIC_API_KEY`, `GROQ_API_KEY`, …) take
precedence and are the recommended place for secrets; the `[api_keys]`
table exists for machines where a private 0600 file beats env plumbing
(e.g. cron, HPC batch scripts).

## Spinner

```toml
[spinner]
enabled = true    # auto-disabled whenever stderr is not a TTY
verbose = false
# Per-tool verbs; arrays pick one at random for personality:
thinking = ["Thinking", "Pondering", "Mulling"]
bash     = ["Running", "Executing"]
```

## Subagents and multi-provider setups

`[[subagents]]` tables define delegate-able workers, and `[providers.<name>]`
tables define extra endpoints for them. See
[example_config.toml](example_config.toml) and the two swarm examples in
`examples/`.

## MCP servers

```toml
[[mcp.servers]]
name      = "filesystem"
transport = "stdio"
command   = "npx"
args      = ["-y", "@modelcontextprotocol/server-filesystem", "/home/user/ws"]
```

## Diagnostics

```bash
caravan doctor          # config validity, key presence, endpoint reachability
caravan config show     # print the active config file
caravan config path     # where it lives
```
