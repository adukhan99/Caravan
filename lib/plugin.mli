(** Spatiotemporal composability — a dynamic plugin runtime for Caravan.

    This module implements the programming paradigm described in
    {{:https://github.com/cordiverse/paper}"A Programming Paradigm for
    Spatiotemporal Composability"} (Shi, Zhang, Cui — Peking University /
    DeepSeek-AI, 2026), the formal foundation behind the Cordis framework
    and the DeepSeek agent harness. It gives Caravan a backend for
    components that can be loaded, unloaded, and rewired at runtime with
    two structural guarantees:

    - {b Temporal composability} — every side effect a component performs
      through its context is paired with an inverse (a disposer) that the
      runtime tracks; unloading the component replays the inverses in LIFO
      order, so removal fully reverts its contribution ({!track},
      {!provide}, {!on}, {!use} are all tracked this way).
    - {b Spatial composability} — a component declares the service keys it
      [inject]s and the keys it may [provide]; the runtime resolves the
      declarations reactively, activating a component when its
      dependencies are all provided and deactivating it (before the
      provider finishes withdrawing, so teardown code can still read the
      service) when they go away.

    Terminology follows the paper: a {e component} pairs declarations with
    an effectful body; a {!Fiber.t} is one live instantiation of a
    component; the {e context} ({!type-context}) is the single entity through
    which every interaction with the shared environment passes.

    The lifecycle implemented here is the paper's base calculus extended
    with failure (section 4.2 + 4.3.4): transitions are synchronous and
    run to completion; the asynchrony layer (section 4.3.3) does not apply
    to this synchronous OCaml core. *)

(** {1 Typed keys} *)

(** Typed, generative service keys. A key created with ['a Key.create]
    can only ever bind values of type ['a]; distinct calls create
    distinct keys even at the same type. *)
module Key : sig
  type 'a t
  (** A key binding values of type ['a]. *)

  type ex = Ex : 'a t -> ex
  (** A key with its value type hidden — used in [inject]/[provide]
      declarations. *)

  val create : ?name:string -> unit -> 'a t
  (** [create ~name ()] makes a fresh key. [name] is used in error
      messages and diagnostics only. *)

  val name : 'a t -> string
end

(** {1 Contexts} *)

type context
(** The unified context: carrier of both effects and coeffects. Every
    component receives its own derived context; the root context is
    created by {!make}. *)

exception Inactive_context
(** Raised when creating an effect on a context whose fiber is not in a
    state that can own effects (i.e. not loading or active). *)

exception Undeclared_access of string
(** Raised by {!get} when a component reads a key that neither it nor
    any ancestor declared in [inject]. *)

exception Inactive_access of string
(** Raised by {!get} when the declaring fiber is not committed to a
    provider for the key (reading outside the active window). *)

exception Unprovided of string
(** Raised by {!get} at the root context when no active provider binds
    the key. *)

exception Duplicate_provider of string
(** Raised by {!provide} when another live provider already binds the
    key in the same realm (single-source discipline). Inside a component
    body this marks the fiber [Failed] rather than propagating. *)

exception Undeclared_provision of string
(** Raised by {!provide} when a component provides a key absent from its
    [provide] declaration. *)

val make : unit -> context
(** Create a fresh runtime and return its root context. The root is
    always active and its effects are never auto-disposed (their
    disposers are still returned to the caller). *)

(** {1 Revertible effects} *)

(** Handles for disposing a tracked effect early. Most callers can
    [ignore] the handle — the owning fiber disposes tracked effects
    automatically when it unloads. Root-context effects are the
    exception: the handle is their only teardown path. *)
module Disposer : sig
  type t

  val dispose : t -> unit
  (** Run the disposal now. One-shot: later calls (including the
      owning fiber's unload) are no-ops. *)
end

val track : ?label:string -> context -> (unit -> unit -> unit) -> Disposer.t
(** [track ctx run] executes [run ()] now and tracks the disposer it
    returns on the context's fiber. Disposal is one-shot and LIFO: when
    the fiber unloads, disposers run newest-first. [label] is for
    diagnostics. *)

val on_dispose : ?label:string -> context -> (unit -> unit) -> Disposer.t
(** [on_dispose ctx f] tracks [f] as teardown without a setup step.
    Equivalent to [track ctx (fun () -> f)]. *)

(** {1 Services (reactive coeffects)} *)

val provide : context -> 'a Key.t -> 'a -> Disposer.t
(** [provide ctx key v] binds [v] at [key] in the realm the context
    resolves [key] to. The binding is a tracked effect: it is withdrawn
    when the disposer is run or the providing fiber unloads. Withdrawal is
    ordered: dependents are deactivated first (and may still {!get} the
    service during their own teardown), then the binding is removed.
    A component must list [key] in its [provide] declaration. *)

val get : context -> 'a Key.t -> 'a
(** [get ctx key] reads the service bound at [key]. Inside a component
    the read is checked against declarations: the key must be
    [inject]-declared by the component (or an ancestor), and the
    declaring fiber must be committed to an active provider — otherwise
    {!Undeclared_access} or {!Inactive_access} is raised. At the root
    context the read is unchecked and raises {!Unprovided} if absent. *)

val find : context -> 'a Key.t -> 'a option
(** [find ctx key] is a weak lookup: the current binding at [key] in the
    context's realm, or [None]. No declaration discipline is enforced;
    intended for hosts and tests, not component bodies. *)

(** {1 Isolation and interception} *)

val isolate : ?realm:string -> context -> Key.ex -> context
(** [isolate ctx (Key.Ex key)] derives a context in which [key] resolves
    in a different realm: a fresh private realm by default, or the named
    global realm if [realm] is given (contexts naming the same [realm]
    share bindings). Components instantiated via {!use} on the derived
    context inherit the isolation. Deriving a context is not an effect:
    recovery is discarding it. *)

val intercept : context -> Key.ex -> Yojson.Safe.t -> context
(** [intercept ctx (Key.Ex key) meta] derives a context carrying
    metadata for accesses to [key]. Metadata from enclosing derivations
    is shallow-merged with the nearest derivation winning per field. *)

val interception : context -> Key.ex -> Yojson.Safe.t option
(** [interception ctx (Key.Ex key)] returns the merged interception
    metadata the context carries for [key], if any. A service
    implementation can consult the metadata of the context an access
    came from. *)

(** {1 Events} *)

(** Typed event channels with revertibly-registered listeners. *)
module Event : sig
  type 'a t
  (** An event carrying payloads of type ['a]. *)

  val create : string -> 'a t
  val name : 'a t -> string
end

val on : ?label:string -> context -> 'a Event.t -> ('a -> unit) -> Disposer.t
(** [on ctx ev f] registers [f] as a listener — a tracked effect, so the
    listener is removed when the fiber unloads (or when the returned
    disposer runs). Listeners fire in registration order. *)

val emit : context -> 'a Event.t -> 'a -> unit
(** [emit ctx ev x] invokes every registered listener with [x].
    Exceptions from listeners propagate to the emitter. *)

(** {1 Components and fibers} *)

type component
(** A component: [inject]/[provide] declarations paired with an
    effectful body. Instantiate with {!use}. *)

val component :
  name:string ->
  ?inject:Key.ex list ->
  ?provide:Key.ex list ->
  (context -> unit) ->
  component
(** [component ~name ~inject ~provide body] declares a component.
    [body] runs on (re)activation with the fiber's own context; every
    mutation it makes must go through that context ({!track},
    {!provide}, {!on}, {!use}), which is what makes unloading revert it.
    [inject] lists the keys the body may {!get}; the fiber activates
    only while all of them are provided. [provide] lists the keys the
    body may {!provide}. *)

(** Live instantiations of components. *)
module Fiber : sig
  type t

  type state =
    | Pending    (** installed; waiting for its dependencies *)
    | Loading    (** body executing *)
    | Active     (** body completed; effects in place *)
    | Unloading  (** teardown in progress *)
    | Failed     (** body raised; effects rolled back — see {!error} *)
    | Disposed   (** retired and removed *)

  val state : t -> state
  val name : t -> string
  val uid : t -> int
  (** Unique per instantiation; never reused within a runtime. *)

  val error : t -> exn option
  (** The exception that marked the fiber [Failed], if any. *)

  val pp_state : Format.formatter -> state -> unit
end

val use : context -> component -> Fiber.t
(** [use ctx comp] instantiates [comp] as a fiber under [ctx] — itself a
    tracked effect of the instantiating fiber, so disposing the parent
    retires the child. The fiber activates immediately if its [inject]
    declarations are satisfied, and reactively (de)activates as
    providers come and go. A body that raises marks the fiber [Failed]
    with its effects rolled back; siblings are unaffected. *)

val dispose : Fiber.t -> unit
(** Retire the fiber: deactivate it (recovering all its effects) and
    remove it from the runtime. Idempotent. *)

val restart : Fiber.t -> unit
(** Force the fiber through a full reload: deactivate if active, clear a
    [Failed] state, then re-evaluate against current providers. *)

val fibers : context -> Fiber.t list
(** All live fibers of the runtime, in instantiation order. *)

val observe : context -> (Fiber.t -> unit) -> unit
(** Install a callback invoked after every fiber state change.
    Callbacks accumulate and fire in registration order; exceptions
    they raise are swallowed. For UIs and logging. *)

val trace_transitions : context -> unit
(** Install an observer that emits a {!Trace.Plugin_transition} event
    for every fiber state change, putting plugin lifecycles in the
    session transcript. *)

(** Well-known service keys the Caravan harness binds, so plugins can
    [inject] harness facilities by name. *)
module Services : sig
  val provider : Provider.packed_provider Key.t
  (** The active LLM provider. The CLI provides it at session setup and
      re-provides it on [/provider] and [/model] switches, so dependent
      plugins reload against the new provider. *)
end

(** {1 Tool registry service} *)

(** Bridges the plugin runtime to Caravan's agent toolsets: a service
    holding a mutable set of {!Tool.packed_tool}s that plugins extend
    revertibly. *)
module Toolset : sig
  type t
  (** The registry value bound at {!key}. *)

  val key : t Key.t
  val provider : component
  (** Provides an empty registry; [use] it once, then let plugins
      [inject] {!key} and call {!register}. *)

  val register : context -> Tool.packed_tool -> Disposer.t
  (** [register ctx tool] adds [tool] as a tracked effect — the tool
      disappears from the registry when the registering fiber unloads.
      Requires {!key} to be readable from [ctx] (see {!get}). *)

  val snapshot : context -> Tool.packed_tool list
  (** The currently registered tools, in registration order — pass to
      [Session.create] / [Agent.run]. *)
end

(** {1 Declarative reconciliation} *)

(** A minimal declarative loader: describe the desired set of plugin
    instantiations as entries; [apply] diffs the description against the
    running fibers and instantiates, disposes, or rebuilds the
    difference (paper section 5.2.1, without persistence). *)
module Reconcile : sig
  type entry = {
    id : string;  (** stable identity used as the reconciliation key *)
    enabled : bool;
    config : Yojson.Safe.t;
    plugin : Yojson.Safe.t -> component;  (** applied to [config] *)
  }

  type t

  val create : context -> t
  (** A reconciler instantiating its fibers on the given context. *)

  val apply : t -> entry list -> unit
  (** Reconcile the running set against [entries]: new enabled entries
      are instantiated, absent ones disposed, and entries whose
      [enabled] flag or [config] changed are rebuilt (disposed and
      re-instantiated). Unchanged entries are left running. Raises
      [Invalid_argument] on duplicate ids. *)

  val fiber : t -> string -> Fiber.t option
  (** The fiber currently backing an entry id, if instantiated. *)
end
