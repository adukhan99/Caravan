# Quick Start

## Chat

```bash
caravan
```

Type to chat. `/` opens the live command palette — Tab completes. Arrows
edit; Up/Down recall history.

## Let it work autonomously

Inside the REPL:

```
/agent find the failing test in this repo and explain why it fails
```

Or from a script / batch job:

```bash
caravan agent "profile the hot loop in sim.c and propose a fix" \
    --max-turns 20 --json | jq -r .result
```

Exit code 0 on success, 1 on failure or exhausted turn budget. `--json`
returns the result, token usage, and the transcript path.

## Switch models

```bash
caravan -p ollama -m llama3.2:1b        # tiny local
caravan -p anthropic                    # frontier (uses provider default model)
caravan providers --ladder              # a curated model per weight class
```

## The browser cockpit

```bash
caravan web        # http://127.0.0.1:8787 — localhost only
```

Chat, run agent tasks with a visible tool audit trail, and edit every
setting (including API keys) from the ⚙ settings panel.

## Guard rails

```bash
caravan config set permissions ask      # confirm before mutating tools
CARAVAN_PERMISSIONS=readonly caravan agent "audit this repo"   # look, don't touch
```
