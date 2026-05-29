# Configuration Guide

Caravan can be configured via a TOML file located at `~/.caravan/config.toml` (or `./.caravan/config.toml` on Windows if `HOME` is not set), environment variables, or command-line flags.

## Example Config

For a complete list of all supported options, standard formats, and inline comments, see the annotated [example_config.toml](example_config.toml).

## Precedence

Configuration settings are resolved in the following order of increasing precedence (highest overrides lowest):
1. **Defaults**: Hardcoded fallback values within Caravan's core modules.
2. **Config File**: Settings loaded from your `config.toml` file.
3. **Environment Variables**: System environment variables (e.g. `OPENAI_API_KEY`, `MAX_TURNS`, `CARAVAN_STRICT_MODE`).
4. **Command Line Flags**: Arguments passed directly to the `caravan` binary at run time (e.g. `--model`, `--provider`, `--system`).

## Commands & Usage

You can override active configurations on the fly or view current settings during a session:
- Use `/config` within the REPL to view the current session's settings.
- Use command-line arguments to launch Caravan with temporary overrides:
  ```bash
  dune exec caravan -- --provider openai --model gpt-4o
  ```
