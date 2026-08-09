# Single Endpoint Example

The simplest possible Caravan setup: one provider, one model, one endpoint.
Start here before moving on to the swarm examples.

## Quick Start

1. **Copy the config** to your Caravan config directory:

   ```bash
   mkdir -p ~/.caravan
   cp config.toml ~/.caravan/config.toml
   ```

2. **Set your API key** (for OpenAI-compatible cloud providers):

   ```bash
   export OPENAI_API_KEY="sk-..."
   ```

   Local providers (Ollama, llama.cpp) do not require a key.

3. **Run Caravan:**

   ```bash
   caravan
   ```

## Switching Providers

Edit `config.toml` and change the three core fields:

| Provider   | `provider`   | `model`               | key env var         |
|------------|--------------|-----------------------|---------------------|
| Ollama     | `"ollama"`   | `"llama3.2"`          | — (local)           |
| llama.cpp  | `"llama_cpp"`| `"default"`           | — (local)           |
| OpenAI     | `"openai"`   | `"gpt-4o-mini"`       | `OPENAI_API_KEY`    |
| Anthropic  | `"anthropic"`| `"claude-sonnet-4-5"` | `ANTHROPIC_API_KEY` |
| Gemini     | `"gemini"`   | `"gemini-2.0-flash"`  | `GEMINI_API_KEY`    |
| Groq       | `"groq"`     | `"llama-3.3-70b-versatile"` | `GROQ_API_KEY` |

Run `caravan providers` for the full list (13 backends) with live key
status, and `caravan providers --ladder` for a curated model per weight
class. Base URLs default sensibly per provider — only set `base_url` for
custom endpoints.

## Config Keys Reference

> **Note:** Configuration keys can be placed at the root level of `config.toml` or grouped inside an `[orchestrator]` block (e.g. `[orchestrator] provider = "llama_cpp"`). Caravan resolves root keys first, falling back to `[orchestrator]` keys automatically.

| Key              | Type    | Default  | Description                                      |
|------------------|---------|----------|--------------------------------------------------|
| `provider`       | string  | `"ollama"` | Backend to use (`openai`, `ollama`, `llama_cpp`) |
| `model`          | string  | —        | Model identifier passed to the provider API      |
| `base_url`       | string  | *(provider default)* | Override the API base URL              |
| `openai_api_key` | string  | —        | API key (prefer `OPENAI_API_KEY` env var)        |
| `stream`         | bool    | `true`   | Stream tokens as they arrive                     |
| `spinner.enabled`| bool    | `true`   | Show spinner while waiting for a response        |
| `spinner.verbose`| bool    | `false`  | Print tool call details to stderr                |
| `max_turns`      | int     | `20`     | Maximum turns in an agentic `/agent` loop        |

## Using a Custom Endpoint

Any OpenAI-compatible server works. Set `provider = "openai"` and point
`base_url` at your server (or encapsulate inside `[orchestrator]`):

```toml
provider = "openai"
model    = "my-custom-model"
base_url = "http://my-server:8000/v1"
# openai_api_key = "..."   # if your server requires auth
```
