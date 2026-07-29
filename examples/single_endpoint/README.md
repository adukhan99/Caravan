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

| Provider   | `provider`  | `model`        | `base_url`                                           |
|------------|-------------|----------------|------------------------------------------------------|
| OpenAI     | `"openai"`  | `"gpt-4o-mini"`| *(default — omit `base_url`)*                        |
| Ollama     | `"ollama"`  | `"llama3.2"`   | `"http://127.0.0.1:11434/v1"`                        |
| llama.cpp  | `"llama_cpp"`| `"default"`   | `"http://127.0.0.1:8080/v1"`                         |
| Gemini     | `"openai"`  | `"gemini-2.0-flash"` | `"https://generativelanguage.googleapis.com/v1beta/openai"` |

> **Note:** Gemini uses the `"openai"` provider type because it exposes an
> OpenAI-compatible endpoint. Set `OPENAI_API_KEY` to your Gemini API key.

## Config Keys Reference

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
`base_url` at your server:

```toml
provider = "openai"
model    = "my-custom-model"
base_url = "http://my-server:8000/v1"
# openai_api_key = "..."   # if your server requires auth
```
