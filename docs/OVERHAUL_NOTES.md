# Overhaul Notes — `overhaul` branch

> Phase 2 additions are at the [bottom](#phase-2--the-second-brief).

Running log of pain points found while crawling the code, and what was done
about each. Kept up to date as work proceeds (newest entries appended per
section). Written for review; delete after merging if unwanted.

## Pain points found in the original code

### Correctness bugs
1. **`Agent.is_finished` scans the whole history for *any* `finish` call.**
   After one task completes, every later `/agent` task in the same session is
   instantly considered "finished" because the old `finish` tool call is still
   in history. → Fixed: completion is now judged from the messages of the
   current run only.
2. **`Memory.Ring.make ~window:0` drops every message.** `Session.create`
   guards `memory_size = 0 → max_int`, but `Session.summarise` re-created a
   `Summary` memory without the guard, so `/memory 0` followed by summarise
   silently discarded the conversation. → Guard moved into `Ring.make`/
   `Summary.create` themselves so no caller can get it wrong.
3. **Delegate tool description frozen at module load.** `description` said
   "(no subagents configured)" forever because it was computed before
   `Delegate.make` populated the registry. → computed at `make` time.
4. **`bash` tool lost stderr.** `Unix.open_process_in` only captures stdout;
   compiler errors etc. leaked to the terminal and the model never saw them.
   → run through `sh -c '… 2>&1'` with exit-status reporting; also removed
   the naive `;`/newline splitter (broke quoted strings, heredocs) in
   non-strict mode — the shell parses the command now.
5. **Wire JSON included `timestamp` and non-standard fields in messages.**
   OpenAI tolerates unknown fields; stricter compatible endpoints reject
   them. → wire serialization (`messages_to_wire_json`) is now separate from
   export serialization (which keeps timestamps).
6. **`bin/main.ml get_available_tools` read `lib/tools/*.ml` from CWD at
   runtime** (regex-scraping descriptions). Dead code, and broken for any
   installed binary. → deleted.
7. **Unknown `--provider` silently fell back to Ollama.** → provider registry
   with a real error listing supported names.

### Bugs found *during* the overhaul (by the new tests / e2e harness)
- **Auto-summarize fired on every turn when `memory_size = 0`.** The
  threshold check `length > memory_size` didn't treat 0 as "unlimited", so
  an unlimited-memory session paid a hidden summarization LLM call after
  each tool turn (and wiped its own history). Caught by the stale-finish
  regression test; fixed in `Session.run_turn_step`.
- **First permission wrapper broke all tools.** `run_with_effects`'s
  default `on_exec` ("No exec handler registered.") captured the
  `Exec_tool` effect that tools rely on falling through. Caught by the
  mock-server end-to-end run; `run_with_effects` now only handles effects
  whose handlers were explicitly supplied.

### Security
8. **No TLS certificate verification anywhere.** All three HTTPS handlers
   (`openai_compatible`, `fetch`, `search`) created a bare
   `Ssl.create_context TLSv1_2` — no peer verification, and an `Obj.magic`
   on the socket type. → single shared `Caravan.Tls` module: TLS 1.2+,
   `Verify_peer` with system CA paths, hostname check; opt-out only via
   `CARAVAN_TLS_INSECURE=1` (printed loudly). `Obj.magic` is contained in
   one commented place instead of three silent ones.
9. **`caravan init` wrote API keys to a world-readable config.** → config is
   written `0o600` and key input is no-echo.

### Repo / build hygiene
10. `puppeteer-config.json` duplicated at repo root and `scripts/`. → one copy.
11. `Caravan.opam` carried `dune {>= "3.21" & >= "3.21"}` (explicit dep
    duplicating the lang stanza). → removed the explicit dep.
12. **No build/test CI at all** (only a docs deploy workflow). → added
    `.github/workflows/ci.yml` (build + test matrix on OCaml 5.2/5.3).
13. `scripts/install.sh` assumed it was already inside a checkout — broken as
    the advertised `curl | bash` one-liner. → clones/updates the repo,
    installs the binary on PATH via `dune install`, then runs the wizard.
14. Version string `0.1.0` hardcoded in `bin/main.ml` and `lib/mcp.ml`.
    → single `Caravan.Version.v`.
15. Expect-tests were flaky: they captured live spinner frames whose verbs are
    randomized (`⠋ Compressing...` vs `⠋ Summarizing...` diff on day one).
    → spinner auto-disables when stderr is not a TTY, so tests never see it.

### Design / UX pain points
16. Library modules printed directly to stdout/stderr (`Session` printed
    "Assistant:", tool traces, MCP chatter). → `Trace` event module: the
    library emits structured events; the CLI installs a pretty renderer; a
    JSONL sink writes an auditable transcript per session.
17. Permission system existed (`Permission`, `Effects.Ask_permission`) but
    nothing installed a handler → every tool ran unchecked. → wired: config
    `permission_mode = "auto" | "ask" | "readonly"`, enforced in the REPL and
    one-shot agent runs.
18. `fetch`/`search` spawned a whole new domain + event loop per call when the
    `Get_net` effect was unhandled. → net handler installed by `Session`
    around tool dispatch, so tools reuse the session's event loop.
19. Only 3 providers, all hand-listed in `bin/main.ml`; no Anthropic; API keys
    only via `OPENAI_API_KEY`. → data-driven registry (ollama, llama.cpp,
    openai, anthropic, groq, openrouter, together, deepseek, mistral, gemini,
    xai, vllm, custom) each with its own key env var, default model, and a
    curated model ladder from ~1B local models to frontier.
20. No non-interactive agent mode: the only way to run an agentic task was
    inside the REPL. HPC/scripting-hostile. → `caravan agent "<task>"`
    (aliases: `run`) with `--max-turns`, `--quiet`, `--json`, proper exit
    codes, transcript logging.
21. Defaults inconsistent: fallback model was `gpt-oss:20b` in `main.ml`,
    `llama3.2` in `doctor`/`init`. → one source of truth in the registry.
22. `MAX_TURNS`/strict-mode read at module-init time (stale env, differing
    defaults in two files). → read lazily through `Config`.
23. Long help/usage text only in the REPL; CLI `--help` was bare. → cmdliner
    man pages fleshed out.

### Notes on things deliberately left alone
- `Openai_compatible.config.timeout` is accepted but not yet enforced
  (cohttp-eio has no per-request timeout hook here); left in place so the
  API doesn't churn twice when it lands.
- `gen_tools.ml` build-time generator: crude but works; documented its
  contract (a tool file must contain `module <Capitalized-filename>`).
- `redis-sync` stays an optional-feeling hard dep (removing it would break
  the advertised Redis memory); Redis_store still can't satisfy `MEMORY`
  (needs connection params at construction) — documented as such.
- Package/library naming (`Caravan` capitalized) left as-is: renaming to
  lowercase `caravan` would churn every file for cosmetic gain.

## Decisions made during the overhaul
- **Anthropic support** uses Anthropic's OpenAI-compatible endpoint
  (`https://api.anthropic.com/v1/`) rather than a bespoke `/v1/messages`
  client — one code path for every provider, tool-calling included. The
  compat layer's minor limitations are documented in `docs/providers.md`.
- **Web UI** (`caravan web`) is a single self-contained HTML page embedded in
  the binary, served on localhost only (request/response JSON; token
  streaming is a possible future upgrade). No JS toolchain, no assets on
  disk — hygienic by construction.
- **Nudge**: two forms. `/nudge <text>` in the REPL queues a steering note
  injected before the next model call; in agent loops, an automatic nudge
  reminds the model of the task and remaining turn budget at the halfway
  point and again near exhaustion.

---

## Phase 2 — the second brief

### Decisions worth human review

1. **minttea declined, hand-rolled editor chosen** (Task 3). minttea
   0.0.2 hard-depends on the Riot actor runtime (0.0.5) — a second
   scheduler that would contend with Eio in one binary, and both are
   pre-0.1. `bin/editor.ml` (~350 dependency-free lines) delivers the
   asked-for features: arrows/Home/End/Ctrl-chords, persistent history,
   live slash palette with Tab completion, Ctrl-C line-cancel. Verified
   with a scripted PTY harness. If minttea matures onto a neutral event
   loop, transcribing the render layer later remains easy — the widget
   vocabulary (Ui.panel/rule/palette) is already isolated.
2. **Slip fuel semantics** (Task 4): the step cap counts *interpreter*
   steps; native data ops (sum/sort/where over a million rows) cost one
   step. This makes the engine useful for real data while keeping
   lambda-driven loops bounded. Recursion is allowed (define is visible
   to the closure via the shared env) — the cap is the safety net.
   `eval` runs quoted code in a fresh environment with the same fuel.
3. **Subagents are config-first, failure-tolerant** (Task 5): a broken
   [[subagents]] entry warns and is skipped — startup never fails because
   a worker is misconfigured. Workers always get `finish` injected.
   `delegate` is classed mutating so ask/readonly govern the whole tree.
4. **Web config editing is whitelisted** (Task 2): POST /api/config only
   accepts `Config.editable_keys`; arbitrary TOML paths (e.g.
   `api_keys.openai`) are rejected there — keys go through POST /api/key,
   which never echoes values back. "ask" permission mode degrades to
   deny on the web (no prompt surface).
5. **Docs site = mdBook + odoc** (Task 1): mdBook's sidebar/search gives
   the readthedocs feel with a single static binary in CI (no Python, no
   theme code in-repo). Sources stay plain markdown in docs/src/, so
   GitHub renders them too. Mermaid renders client-side on the published
   site via a tiny theme JS shim (CDN); GitHub renders the same fences
   natively. The old mermaid-CLI/puppeteer render pipeline was deleted.

### Experimental features that may warrant attention
- Slip's `eval`/`read` reflection: sandboxed and fuel-shared, but it is
  the most "creative" surface — if it ever worries anyone, deleting the
  two builtins is a 5-line change.
- The PTY line editor assumes ANSI/VT sequences (fine everywhere Linux/
  macOS; untested on Windows terminals — as is the rest of Caravan).
- Web settings panel writes live to the same config the CLI reads;
  concurrent writes last-writer-wins (single-user tool, acceptable).
