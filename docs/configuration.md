# Configuration Guide

OrchCaml uses a TOML configuration file located at `~/.orchcaml/config.toml`. This file allows you to set default models, providers, and API keys.

## File Location

- **Linux/macOS**: `~/.orchcaml/config.toml`
- **Windows**: Not explicitly supported, but defaults to `./.orchcaml/config.toml` if `HOME` is not set.

## Configuration Keys

The following keys are supported at the top level of the `config.toml` file.

| Key | Type | Description | Environment Override |
| :--- | :--- | :--- | :--- |
| `provider` | String | The default LLM provider (`ollama`, `openai`, `llama_cpp`). | `--provider` flag |
| `model` | String | The default model name to use. | `MODEL` or `--model` flag |
| `base_url` | String | Base URL for the provider API. | `--base-url` flag |
| `system` | String | Default system prompt for new sessions. | `--system` flag |
| `strict_mode` | Integer | Controls tool safety and visibility (see below). | `ORCHCAML_STRICT_MODE` |
| `max_turns` | Integer | Maximum number of turns an agent can take (default: 10). | `MAX_TURNS` |
| `openai_api_key` | String | API key for OpenAI-compatible providers. | `OPENAI_API_KEY` |
| `search_api_key` | String | API key for the Brave Search tool. | `SEARCH_API_KEY` |

## Strict Mode (`strict_mode`)

The `strict_mode` key (default: `1`) controls the safety and behavior of the `bash` tool.

| Level | Name | Description |
| :--- | :--- | :--- |
| `0` | Off | No restrictions. Multi-command strings (using `;` or `\n`) are executed sequentially. |
| `1` | Strict | (Default) Enforces single-command execution. Tool calls containing `;` or `\n` are rejected, forcing the agent to issue separate calls for each step. |
| `2` | Hidden | The `bash` tool is entirely disabled and removed from the agent's available tools. |

## Example `config.toml`

```toml
# Default provider settings
provider = "ollama"
model = "llama3.2"

# Agent settings
max_turns = 15
system = "You are a helpful OCaml programming assistant."

# API Keys for tools and providers
openai_api_key = "sk-..."
search_api_key = "..."
```

## Environment Variables

OrchCaml checks environment variables before looking at the config file. For example:
- `OPENAI_API_KEY` will override `openai_api_key` in the TOML.
- `MAX_TURNS` will override `max_turns` in the TOML.
- `ORCHCAML_STRICT_MODE` will override `strict_mode` in the TOML.

## Command Line Arguments

Flags passed to the `orchcaml` binary will always take the highest precedence.

```bash
# Use a specific model regardless of config
dune exec orchcaml -- --model gpt-4o
```
