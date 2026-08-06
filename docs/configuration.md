# Configuration Guide

Caravan can be configured via a TOML file located at `~/.caravan/config.toml` (or custom path via `CARAVAN_CONFIG`), environment variables, or command-line flags.

## TOML Config Structure

Configuration settings can be defined either at the top-level or scoped within an `[orchestrator]` section block for clean organization.

### Single Endpoint / Top-Level Style
```toml
provider = "llama_cpp"
model = "LiquidAI/LFM2.5-2.6B-GGUF"
base_url = "http://127.0.0.1:8080"
max_turns = 20
stream = true
```

### Orchestrator Table Style
```toml
stream = true
max_turns = 100

[orchestrator]
provider = "llama_cpp"
model = "LiquidAI/LFM2.5-2.6B-GGUF"
base_url = "http://127.0.0.1:8080"
system = "You are a concise AI assistant."
```

## Key Lookup & Fallback Hierarchy

When Caravan reads configuration options (`provider`, `model`, `base_url`, `api_key`, `system`, `max_turns`, etc.), it checks sources in the following fallback sequence:

1. **Environment Variables**: `CARAVAN_PROVIDER`, `CARAVAN_MODEL`, `CARAVAN_BASE_URL`, `OPENAI_API_KEY`, etc.
2. **Root TOML Keys**: Top-level entries in `config.toml` (e.g. `provider = "..."`).
3. **Orchestrator TOML Section**: Keys nested under `[orchestrator]` (e.g. `[orchestrator] provider = "..."`).
4. **Hardcoded Module Defaults**: Internal defaults defined in core modules.

## Example Config Reference

For a complete reference with all supported options and subagent configurations, see [example_config.toml](example_config.toml).

## CLI Overrides & Diagnostics

You can inspect active diagnostics and verify your configuration anytime:

```bash
# Verify system status and network connectivity
dune exec caravan -- doctor

# Run with temporary model overrides
dune exec caravan -- --provider openai --model gpt-4o
```
