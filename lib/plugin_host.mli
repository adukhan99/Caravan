(** The harness side of the plugin runtime: config-driven composition.

    [Plugin] supplies the mechanism (components, fibers, services);
    this module supplies the policy the Caravan CLI and web front-ends
    share: a named registry of plugin {e builders}, `[[plugins]]` config
    entries reconciled into running fibers, the shared {!Plugin.Toolset}
    the session reads its tools from, and the active-provider service.

    A {e builder} is a named function [Yojson.Safe.t -> Plugin.component];
    config entries reference builders by name, so end users compose the
    harness declaratively without writing OCaml:

    {v
    [[plugins]]
    plugin = "tools.builtin"

    [[plugins]]
    id      = "fs"
    plugin  = "tools.mcp"
    command = "npx"
    args    = ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    v}

    When the config declares no [[plugins]] table, {!load} synthesizes
    the default composition — built-in tools plus one MCP mount per
    [[mcp.servers]] entry — so existing configs behave exactly as
    before. When [[plugins]] entries exist they are merged over those
    defaults by [id] (a user entry with a default's id replaces it, so
    e.g. [enabled = false] can switch a default off). *)

type t

val create : ?builtin_tools:(unit -> Tool.packed_tool list) -> unit -> t
(** Build a host: a fresh {!Plugin} runtime with {!Plugin.trace_transitions}
    installed, the {!Plugin.Toolset} provider mounted, and two builders
    pre-registered:

    - ["tools.builtin"] — registers [builtin_tools ()] into the toolset
      (an optional [exclude] string-array in its config drops tools by
      name). Only registered when [builtin_tools] is given.
    - ["tools.mcp"] — connects to an MCP server ([name], [command],
      [args] fields) and registers its tools; disposing the fiber
      closes the server process and removes the tools. *)

val context : t -> Plugin.context
(** The host's root context — for [use]/[provide]/inspection. *)

val register_builder : t -> string -> (Yojson.Safe.t -> Plugin.component) -> unit
(** Add or replace a named builder. Call before {!load}. *)

val load : t -> unit
(** Read `[[plugins]]` from config (merged over the synthesized
    defaults, see above) and reconcile the running fibers to it.
    Entries naming an unknown builder are skipped with a warning.
    Safe to call again to re-read the config. *)

val entries : t -> Config.plugin_config list
(** The entry list currently applied, in order. *)

val set_enabled : t -> id:string -> bool -> (unit, string) result
(** Enable or disable one entry by id for this session (the config
    file is not modified). [Error] if the id is unknown. *)

val fiber : t -> string -> Plugin.Fiber.t option
(** The fiber backing an entry id, if instantiated. *)

val tools : t -> Tool.packed_tool list
(** Live snapshot of the shared toolset — pass to [Session.create]. *)

val realm_context : t -> realm:string -> Plugin.context
(** The named toolset realm's context, materialized on first use (its
    own {!Plugin.Toolset} provider is mounted in the realm). A
    `[[plugins]]` entry with a [realm = "<name>"] field is instantiated
    with {!Plugin.Toolset.key} isolated to this realm, so the tools it
    registers land here instead of the shared toolset. *)

val realm_tools : t -> realm:string -> Tool.packed_tool list
(** Live snapshot of a named realm's toolset. Subagent workers declared
    with [realm = "<name>"] resolve these at delegation time — the
    sandbox contents can change between delegations. *)

val set_provider : t -> Provider.packed_provider -> unit
(** Bind (or rebind) the {!Plugin.Services.provider} service. The
    previous binding is withdrawn first, so provider-dependent plugins
    reload against the new provider. *)
