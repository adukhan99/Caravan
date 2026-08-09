# Agents, Permissions & Transcripts

## The agent loop

`/agent` and `caravan agent` run a ReAct-style loop: the model calls
tools, sees results, and signals completion with the `finish` tool.
The loop is budgeted (`max_turns`) and **nudged**: at the halfway point
and near exhaustion, Caravan reminds the model of the task and remaining
turns — this measurably reduces wandering in long runs. Disable with
`nudge = false`.

## Tools

Run `/tools` to see the active set (✎ marks mutating tools):

`bash` · `read_file` / `write_file` · `ls` / `grep` / `sed` / `touch` /
`mkdir` · `web_fetch` / `web_search` · `lisp` · `summarize` · `finish` ·
`delegate` (when [subagents](subagents.md) are configured) · plus any
MCP-server tools from the config.

## Permissions

```toml
permissions = "auto"   # auto | ask | readonly
```

| Mode | Behavior |
|------|----------|
| `auto` | all tools run (default) |
| `ask` | interactive y/n/always prompt before each mutating tool |
| `readonly` | mutating tools denied outright — audit-safe runs |

Mutating: `bash`, `write_file`, `sed`, `touch`, `mkdir`, `delegate`.
Switch live with `/permissions ask`, per-run with
`CARAVAN_PERMISSIONS=readonly`. In the web UI, `ask` degrades to deny
(there is no prompt surface).

## Transcripts

With `transcript = true` (default) every session appends structured
events to `~/.caravan/logs/session-<timestamp>-<pid>.jsonl`:

```json
{"ts":1786349217.4,"event":"tool_call_start","name":"bash","args":"{\"command\":\"dune test\"}"}
{"ts":1786349219.1,"event":"tool_call_end","name":"bash","output":"…","duration_s":1.7}
{"ts":1786349226.0,"event":"task_finished","summary":"All tests pass after the fix."}
```

`caravan agent --json` includes the transcript path, so pipelines can
archive exactly what their agent did. Under the hood this is
`Caravan.Trace` — one event stream feeding the terminal renderer, the
JSONL sink, and anything you attach (see [Library Guide](library.md)).

## Memory

Sessions keep a sliding window (`/memory <n>`, 0 = unlimited) and can
compact on demand (`/summarise`) or automatically when the window
overflows. Summary and hierarchical memories are available to library
users, plus Redis for shared multi-process context.
