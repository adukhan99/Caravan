# Web UI

```bash
caravan web [--port 8787]
```

A single, fully embedded page — no assets on disk, no JS toolchain, no
CDN dependencies for the app itself — served on **127.0.0.1 only**. It is
a personal cockpit, not a deployment target.

## What it does

- **Chat** with the active model, or tick **agent** to run autonomous
  tasks; every reply shows the tool calls that produced it plus token
  usage;
- **⚙ Settings**: edit every config key and paste API keys from the
  browser — the no-shell configuration path. Key values are write-only
  (the API reports only set/unset) and land in the same 0600 TOML file;
- live provider/model/token counters in the header.

## JSON API

| Endpoint | Purpose |
|----------|---------|
| `GET /api/state` | provider, model, token totals, permission mode |
| `POST /api/chat` `{"message": "…"}` | one chat turn |
| `POST /api/agent` `{"task": "…"}` | autonomous run; response includes a `tools` audit trail |
| `GET /api/config` | editable settings + per-provider key presence (never key values) |
| `POST /api/config` `{"key","value"}` | edit a whitelisted setting |
| `POST /api/key` `{"provider","key"}` | store an API key |

## Security posture

- binds loopback only; no auth layer — do not port-forward it;
- `POST /api/config` is whitelisted to the documented settings keys;
  arbitrary TOML paths are rejected;
- permission modes apply to web runs too; `ask` degrades to deny since
  no prompt is possible.
