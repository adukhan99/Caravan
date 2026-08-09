(** [caravan web] — a minimal, self-contained web front-end.

    Serves a single embedded HTML page on localhost (no assets on disk, no
    JS toolchain) and a JSON API:

      POST /api/chat   {"message": "..."}          → chat turn
      POST /api/agent  {"task": "..."}             → autonomous agent run
      GET  /api/state                              → provider/model/usage

    Tool activity is captured per-request via a temporary [Trace] sink and
    returned alongside the reply so the page can show an audit trail.
    The server binds 127.0.0.1 only — it is a personal cockpit, not a
    deployment target. *)

open Caravan

let html_page = {html|<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Caravan</title>
<style>
  :root {
    --bg: #14100c; --panel: #1e1813; --ink: #e8ddcf; --dim: #8d8172;
    --amber: #e6a23c; --rose: #e0685e; --teal: #4fb8a8; --line: #33291f;
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--ink);
         font: 15px/1.5 ui-monospace, "JetBrains Mono", Menlo, monospace; }
  header { padding: 14px 20px; border-bottom: 1px solid var(--line);
           display: flex; align-items: baseline; gap: 14px; }
  header h1 { margin: 0; font-size: 17px; letter-spacing: 4px;
              background: linear-gradient(90deg, var(--amber), var(--rose));
              -webkit-background-clip: text; background-clip: text; color: transparent; }
  header .meta { color: var(--dim); font-size: 12px; }
  #log { padding: 20px; max-width: 900px; margin: 0 auto;
         padding-bottom: 140px; }
  .msg { margin: 14px 0; white-space: pre-wrap; word-wrap: break-word; }
  .msg.user   { color: var(--amber); }
  .msg.user::before { content: "you ❯ "; color: var(--dim); }
  .msg.bot    { color: var(--ink); }
  .msg.bot::before { content: "caravan ❯ "; color: var(--teal); }
  .msg.err    { color: var(--rose); }
  .tools { border-left: 2px solid var(--line); margin: 6px 0 6px 8px;
           padding-left: 12px; color: var(--dim); font-size: 12.5px; }
  .tools .t::before { content: "⏺ "; color: var(--rose); }
  .usage { color: var(--dim); font-size: 11.5px; margin-top: 4px; }
  form { position: fixed; bottom: 0; left: 0; right: 0;
         background: linear-gradient(transparent, var(--bg) 30%);
         padding: 24px 20px 20px; }
  .bar { max-width: 900px; margin: 0 auto; display: flex; gap: 10px;
         background: var(--panel); border: 1px solid var(--line);
         border-radius: 10px; padding: 10px 12px; }
  .bar input[type=text] { flex: 1; background: none; border: none; outline: none;
         color: var(--ink); font: inherit; }
  .bar button { background: var(--amber); color: #14100c; border: none;
         border-radius: 6px; padding: 6px 14px; font: inherit; cursor: pointer; }
  .bar button:disabled { opacity: .4; cursor: wait; }
  .bar label { color: var(--dim); font-size: 12px; display: flex;
         align-items: center; gap: 5px; user-select: none; }
  .spin { display: inline-block; animation: r 1s linear infinite; }
  @keyframes r { to { transform: rotate(360deg); } }
</style>
<header>
  <h1>☾ CARAVAN</h1>
  <span class="meta" id="meta">…</span>
</header>
<div id="log"></div>
<form id="f">
  <div class="bar">
    <input type="text" id="q" placeholder="message — or describe a task and tick agent"
           autocomplete="off" autofocus>
    <label><input type="checkbox" id="agent"> agent</label>
    <button id="go">send</button>
  </div>
</form>
<script>
const log = document.getElementById('log');
const q = document.getElementById('q');
const go = document.getElementById('go');
const agent = document.getElementById('agent');

function add(cls, text) {
  const d = document.createElement('div');
  d.className = 'msg ' + cls;
  d.textContent = text;
  log.appendChild(d);
  window.scrollTo(0, document.body.scrollHeight);
  return d;
}

async function refreshMeta() {
  try {
    const r = await fetch('/api/state');
    const s = await r.json();
    document.getElementById('meta').textContent =
      s.provider + '/' + s.model + ' · ▲' + s.tokens_in + ' ▼' + s.tokens_out + ' tok';
  } catch (e) {}
}

document.getElementById('f').addEventListener('submit', async (ev) => {
  ev.preventDefault();
  const text = q.value.trim();
  if (!text) return;
  q.value = '';
  add('user', text);
  const wait = add('bot', '');
  wait.innerHTML = '<span class="spin">◐</span>';
  go.disabled = true;
  try {
    const url = agent.checked ? '/api/agent' : '/api/chat';
    const key = agent.checked ? 'task' : 'message';
    const r = await fetch(url, {
      method: 'POST',
      headers: {'content-type': 'application/json'},
      body: JSON.stringify({[key]: text})
    });
    const j = await r.json();
    wait.remove();
    if (j.tools && j.tools.length) {
      const t = document.createElement('div');
      t.className = 'tools';
      j.tools.forEach(x => {
        const e = document.createElement('div');
        e.className = 't';
        e.textContent = x;
        t.appendChild(e);
      });
      log.appendChild(t);
    }
    if (j.error) add('err', j.error);
    else {
      add('bot', j.reply);
      if (j.usage) {
        const u = document.createElement('div');
        u.className = 'usage';
        u.textContent = j.usage;
        log.appendChild(u);
      }
    }
  } catch (e) {
    wait.remove();
    add('err', 'request failed: ' + e);
  }
  go.disabled = false;
  q.focus();
  refreshMeta();
});
refreshMeta();
</script>
|html}

type state = {
  mutable session    : Session.t;
  mutable tokens_in  : int;
  mutable tokens_out : int;
  provider_name      : string;
  model              : string;
}

let read_body body =
  Eio.Buf_read.(of_flow body ~max_size:10_000_000 |> take_all)

let json_response ?(status = `OK) json =
  Cohttp_eio.Server.respond_string
    ~headers:(Http.Header.of_list [("content-type", "application/json")])
    ~status ~body:(Yojson.Safe.to_string json) ()

let html_response () =
  Cohttp_eio.Server.respond_string
    ~headers:(Http.Header.of_list [("content-type", "text/html; charset=utf-8")])
    ~status:`OK ~body:html_page ()

let record_usage st (result : _ Types.result_with_meta) =
  match result.usage with
  | Some u ->
    st.tokens_in <- st.tokens_in + u.prompt_tokens;
    st.tokens_out <- st.tokens_out + u.completion_tokens
  | None -> ()

(** Run [f] capturing tool-trace lines for the response payload. *)
let with_captured_tools f =
  let captured = ref [] in
  let sink ev =
    match ev with
    | Trace.Tool_call_start { name; args } ->
      let preview = if String.length args > 80 then String.sub args 0 80 ^ "…" else args in
      captured := Printf.sprintf "%s %s" name preview :: !captured
    | _ -> ()
  in
  let result = Trace.with_sink sink f in
  (result, List.rev !captured)

let handle_message st net clock ~agent_mode text =
  let (outcome, tools) =
    with_captured_tools (fun () ->
      if agent_mode then
        match Agent.run net clock st.session text with
        | Ok (sess', result) ->
          st.session <- sess';
          record_usage st result;
          Ok result
        | Error e -> Error e
      else begin
        let (sess', result) = Session.turn net clock st.session text in
        st.session <- sess';
        record_usage st result;
        Ok result
      end)
  in
  match outcome with
  | Ok result ->
    let usage_line = Monitor.format_usage result in
    `Assoc [
      ("reply", `String result.Types.value.Types.content);
      ("tools", `List (List.map (fun t -> `String t) tools));
      ("usage", `String usage_line);
    ]
  | Error e ->
    `Assoc [
      ("error", `String e);
      ("tools", `List (List.map (fun t -> `String t) tools));
    ]

let callback st net clock _conn request body =
  let path = Http.Request.resource request in
  let meth = Http.Request.meth request in
  match meth, path with
  | `GET, "/" -> html_response ()
  | `GET, "/api/state" ->
    json_response (`Assoc [
      ("provider",   `String st.provider_name);
      ("model",      `String st.model);
      ("tokens_in",  `Int st.tokens_in);
      ("tokens_out", `Int st.tokens_out);
    ])
  | `POST, ("/api/chat" | "/api/agent") ->
    let agent_mode = path = "/api/agent" in
    let raw = read_body body in
    (try
       let json = Yojson.Safe.from_string raw in
       let key = if agent_mode then "task" else "message" in
       (match Yojson.Safe.Util.member key json with
        | `String text when String.trim text <> "" ->
          json_response (handle_message st net clock ~agent_mode text)
        | _ ->
          json_response ~status:`Bad_request
            (`Assoc [("error", `String (Printf.sprintf "missing '%s' field" key))]))
     with exn ->
       json_response ~status:`Internal_server_error
         (`Assoc [("error", `String (Caravan_error.humanize exn))]))
  | _ ->
    Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"not found" ()

let serve ~port ~provider_name ~model ~make_session =
  Eio_main.run @@ fun env ->
  Effects.with_net env#net @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  let session = make_session env in
  let st = { session; tokens_in = 0; tokens_out = 0; provider_name; model } in
  let socket =
    Eio.Net.listen ~sw ~backlog:16 ~reuse_addr:true env#net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server =
    Cohttp_eio.Server.make ()
      ~callback:(fun conn req body -> callback st env#net env#clock conn req body)
  in
  Ui.println_ansi (Ui.green (Printf.sprintf "  ☾ Caravan web UI listening on http://127.0.0.1:%d" port));
  Ui.println_ansi (Ui.dim "    (localhost only — Ctrl-C to stop)");
  Cohttp_eio.Server.run socket server
    ~on_error:(fun exn -> Trace.log "error" "web: %s" (Printexc.to_string exn))
