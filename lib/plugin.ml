(* Spatiotemporal composability runtime — see plugin.mli for the model
   and the paper reference. Implementation notes:

   - Transitions are the paper's base calculus + failure: synchronous,
     run to completion. The engine is a work queue (`settle`) drained
     until no fiber's target view differs from its committed view.
   - Withdrawal ordering (paper 4.3.1): a provider entering teardown is
     marked Unloading first (it stops counting as a provider), its
     installed dependents are deactivated next (they can still read the
     binding, which is removed only afterwards), and only then do its
     own disposers run. *)

module Disposer = struct
  type t = unit -> unit

  let dispose d = d ()
end

exception Inactive_context
exception Undeclared_access of string
exception Inactive_access of string
exception Unprovided of string
exception Duplicate_provider of string
exception Undeclared_provision of string

(* ── Type witnesses (generative, à la Hmap) ─────────────────────────── *)

module Tid = struct
  type _ t = ..
end

module type TID = sig
  type a
  type _ Tid.t += Tid : a Tid.t
end

type 'a tid = (module TID with type a = 'a)

let new_tid (type s) () : s tid =
  (module struct
    type a = s
    type _ Tid.t += Tid : a Tid.t
  end)

type ('a, 'b) teq = Teq : ('a, 'a) teq

let eq_tid : type a b. a tid -> b tid -> (a, b) teq option =
 fun (module A) (module B) -> match A.Tid with B.Tid -> Some Teq | _ -> None

(* ── Keys ───────────────────────────────────────────────────────────── *)

module Key = struct
  type 'a t = { kuid : int; kname : string; ktid : 'a tid }
  type ex = Ex : 'a t -> ex

  let counter = ref 0

  let create ?(name = "key") () =
    incr counter;
    { kuid = !counter; kname = name; ktid = new_tid () }

  let name k = k.kname
  let ex_uid (Ex k) = k.kuid
end

(* ── Events ─────────────────────────────────────────────────────────── *)

module Event = struct
  type 'a t = { euid : int; ename : string; etid : 'a tid }

  let counter = ref 0

  let create name =
    incr counter;
    { euid = !counter; ename = name; etid = new_tid () }

  let name e = e.ename
end

type listener = Listener : 'a Event.t * ('a -> unit) -> listener

(* ── Realms ─────────────────────────────────────────────────────────── *)

(* A realm identifies one binding slot for one key; isolation redirects
   a key to a different realm (paper Definition 28). The key uid is part
   of the realm so the store needs no second index. *)
type realm =
  | Rdefault of int (* key uid *)
  | Rnamed of int * string (* key uid, shared global realm name *)
  | Rlocal of int * int (* key uid, private realm id *)

type binding = B : 'a Key.t * 'a -> binding

(* ── Core recursive structures ──────────────────────────────────────── *)

type state =
  | SPending
  | SLoading
  | SActive
  | SUnloading
  | SFailed of exn
  | SDisposed

type component = {
  c_name : string;
  c_inject : Key.ex list;
  c_provide : Key.ex list;
  c_apply : context -> unit;
}

and context = {
  rt : runtime;
  cfiber : fiber option; (* None = root *)
  iso : (int * realm) list; (* key uid -> realm, nearest first *)
  meta : (int * Yojson.Safe.t) list; (* interception, nearest first *)
}

and fiber = {
  f_uid : int;
  f_comp : component;
  f_parent : context;
  mutable f_ctx : context;
  mutable f_state : state;
  mutable f_disposables : (string * (unit -> unit)) list; (* newest first *)
  mutable f_committed : (int * int) list option; (* key uid -> provider uid, sorted *)
  mutable f_retired : bool;
}

and impl = {
  i_realm : realm;
  i_key : Key.ex;
  i_value : binding;
  i_provider : fiber option; (* None = root-provided *)
  mutable i_active : bool; (* false once withdrawal has begun *)
}

and runtime = {
  mutable r_next_uid : int;
  mutable r_next_realm : int;
  mutable r_fibers : fiber list; (* instantiation order *)
  r_store : (realm, impl) Hashtbl.t;
  r_listeners : (int, listener list ref) Hashtbl.t;
  r_queue : fiber Queue.t;
  mutable r_settling : bool;
  mutable r_observers : (fiber -> unit) list; (* registration order *)
}

let root_uid = -1

let make () =
  let rt =
    {
      r_next_uid = 0;
      r_next_realm = 0;
      r_fibers = [];
      r_store = Hashtbl.create 16;
      r_listeners = Hashtbl.create 16;
      r_queue = Queue.create ();
      r_settling = false;
      r_observers = [];
    }
  in
  { rt; cfiber = None; iso = []; meta = [] }

let observe ctx fn = ctx.rt.r_observers <- ctx.rt.r_observers @ [ fn ]

let set_state f st =
  f.f_state <- st;
  List.iter (fun fn -> try fn f with _ -> ()) f.f_parent.rt.r_observers

(* ── Realm resolution ───────────────────────────────────────────────── *)

let resolve_realm_uid ctx kuid =
  match List.assoc_opt kuid ctx.iso with
  | Some r -> r
  | None -> Rdefault kuid

let resolve_realm ctx (key : 'a Key.t) = resolve_realm_uid ctx key.Key.kuid

let provider_uid impl =
  match impl.i_provider with None -> root_uid | Some f -> f.f_uid

(* A binding satisfies dependents only while it has not begun withdrawal
   and its provider (if a fiber) is Active — the union over Active
   fibers of paper eq. 40. *)
let impl_provided impl =
  impl.i_active
  &&
  match impl.i_provider with
  | None -> true
  | Some f -> ( match f.f_state with SActive -> true | _ -> false)

(* ── Target views ───────────────────────────────────────────────────── *)

let declares f kuid =
  List.exists (fun ex -> Key.ex_uid ex = kuid) f.f_comp.c_inject

let target f : (int * int) list option =
  if f.f_retired then None
  else
    match f.f_state with
    | SDisposed | SFailed _ -> None
    | _ ->
      let resolve acc ex =
        match acc with
        | None -> None
        | Some view -> (
          let kuid = Key.ex_uid ex in
          match Hashtbl.find_opt f.f_parent.rt.r_store (resolve_realm_uid f.f_ctx kuid) with
          | Some impl when impl_provided impl -> Some ((kuid, provider_uid impl) :: view)
          | _ -> None)
      in
      (match List.fold_left resolve (Some []) f.f_comp.c_inject with
       | None -> None
       | Some view -> Some (List.sort compare view))

(* ── Effects ────────────────────────────────────────────────────────── *)

let track ?(label = "track") ctx run =
  (match ctx.cfiber with
   | None -> ()
   | Some f -> (
     match f.f_state with
     | SLoading | SActive -> ()
     | SPending | SUnloading | SFailed _ | SDisposed -> raise Inactive_context));
  let disposer = run () in
  let armed = ref true in
  let rec wrapped () =
    if !armed then begin
      armed := false;
      (match ctx.cfiber with
       | None -> ()
       | Some f ->
         f.f_disposables <-
           List.filter (fun (_, d) -> d != wrapped) f.f_disposables);
      disposer ()
    end
  in
  (match ctx.cfiber with
   | None -> ()
   | Some f -> f.f_disposables <- (label, wrapped) :: f.f_disposables);
  wrapped

let on_dispose ?(label = "on_dispose") ctx f = track ~label ctx (fun () -> f)

let run_disposables f =
  let ds = f.f_disposables in
  f.f_disposables <- [];
  (* Best-effort teardown: a raising disposer must not strand the rest. *)
  List.iter (fun (_label, d) -> try d () with _ -> ()) ds

(* ── The engine ─────────────────────────────────────────────────────── *)

let schedule rt f = Queue.add f rt.r_queue

(* Enqueue every fiber that declares the key of [impl] and resolves it
   to the same realm (paper Algorithm 3). *)
let notify_realm rt impl =
  let kuid = Key.ex_uid impl.i_key in
  List.iter
    (fun g ->
      if declares g kuid && resolve_realm_uid g.f_ctx kuid = impl.i_realm then
        schedule rt g)
    rt.r_fibers

let rec step rt f =
  match f.f_state with
  | SLoading | SUnloading | SDisposed -> ()
  | SFailed _ -> if f.f_retired then set_state f SDisposed
  | SPending ->
    if f.f_retired then set_state f SDisposed
    else (
      match target f with
      | Some view -> activate rt f view
      | None -> ())
  | SActive ->
    if target f <> f.f_committed then begin
      deactivate rt f;
      step rt f (* the target may be satisfiable again (or retirement pending) *)
    end

and activate rt f view =
  set_state f SLoading;
  f.f_committed <- Some view;
  (match f.f_comp.c_apply f.f_ctx with
   | () ->
     set_state f SActive;
     (* Our provisions now count as provided: wake dependents. *)
     Hashtbl.iter
       (fun _realm impl ->
         match impl.i_provider with
         | Some p when p == f -> notify_realm rt impl
         | _ -> ())
       rt.r_store;
     (* The body may itself have disturbed our dependencies. *)
     schedule rt f
   | exception e ->
     run_disposables f;
     f.f_committed <- None;
     set_state f (SFailed e))

and deactivate rt f =
  (* L-Leave: stop providing; dependents recompute and drain first. *)
  set_state f SUnloading;
  drain_dependents rt f;
  (* L-Unload: run the accumulator (LIFO), discard the committed view. *)
  run_disposables f;
  f.f_committed <- None;
  set_state f SPending;
  schedule rt f

and drain_dependents rt f =
  List.iter
    (fun g ->
      if g != f then
        match (g.f_state, g.f_committed) with
        | SActive, Some view when List.exists (fun (_, p) -> p = f.f_uid) view ->
          deactivate rt g;
          schedule rt g
        | _ -> ())
    rt.r_fibers

and retire_fiber rt f =
  if not f.f_retired then begin
    f.f_retired <- true;
    (match f.f_state with SActive -> deactivate rt f | _ -> ());
    match f.f_state with
    | SPending | SFailed _ -> set_state f SDisposed
    | _ -> ()
  end

let settle rt =
  if not rt.r_settling then begin
    rt.r_settling <- true;
    Fun.protect
      ~finally:(fun () ->
        rt.r_settling <- false;
        rt.r_fibers <-
          List.filter
            (fun f -> match f.f_state with SDisposed -> false | _ -> true)
            rt.r_fibers)
      (fun () ->
        while not (Queue.is_empty rt.r_queue) do
          step rt (Queue.pop rt.r_queue)
        done)
  end

let maybe_settle rt = if not rt.r_settling then settle rt

(* ── Services ───────────────────────────────────────────────────────── *)

let provide (type a) ctx (key : a Key.t) (value : a) =
  (match ctx.cfiber with
   | None -> ()
   | Some f ->
     if not (List.exists (fun ex -> Key.ex_uid ex = key.Key.kuid) f.f_comp.c_provide)
     then raise (Undeclared_provision key.Key.kname));
  let rt = ctx.rt in
  let realm = resolve_realm ctx key in
  (match Hashtbl.find_opt rt.r_store realm with
   | Some existing when existing.i_active -> raise (Duplicate_provider key.Key.kname)
   | _ -> ());
  let impl =
    {
      i_realm = realm;
      i_key = Key.Ex key;
      i_value = B (key, value);
      i_provider = ctx.cfiber;
      i_active = true;
    }
  in
  let dispose_binding () =
    impl.i_active <- false;
    (* Withdrawal ordering: installed dependents deactivate while the
       binding is still readable; only then does it leave the store. If
       the providing fiber is already Unloading, its dependents were
       drained before this disposer ran and this loop finds nothing. *)
    List.iter
      (fun g ->
        match (g.f_state, g.f_committed) with
        | SActive, Some view
          when List.exists
                 (fun (k, p) -> k = key.Key.kuid && p = provider_uid impl)
                 view ->
          deactivate rt g;
          schedule rt g
        | _ -> ())
      rt.r_fibers;
    (* Remove only our own entry: a reentrant provide during the drain
       may already have claimed the realm. *)
    (match Hashtbl.find_opt rt.r_store realm with
     | Some cur when cur == impl -> Hashtbl.remove rt.r_store realm
     | _ -> ());
    notify_realm rt impl;
    maybe_settle rt
  in
  let disposer =
    track ~label:("provide " ^ key.Key.kname) ctx (fun () ->
        Hashtbl.replace rt.r_store realm impl;
        notify_realm rt impl;
        dispose_binding)
  in
  maybe_settle rt;
  disposer

let unpack : type a. a Key.t -> binding -> a option =
 fun key (B (k, v)) ->
  match eq_tid k.Key.ktid key.Key.ktid with Some Teq -> Some v | None -> None

let find (type a) ctx (key : a Key.t) : a option =
  match Hashtbl.find_opt ctx.rt.r_store (resolve_realm ctx key) with
  | None -> None
  | Some impl -> unpack key impl.i_value

let get (type a) ctx (key : a Key.t) : a =
  let read_store fctx : a option =
    match Hashtbl.find_opt ctx.rt.r_store (resolve_realm fctx key) with
    | Some impl -> unpack key impl.i_value
    | None -> None
  in
  match ctx.cfiber with
  | None -> (
    match read_store ctx with
    | Some v -> v
    | None -> raise (Unprovided key.Key.kname))
  | Some start ->
    (* Paper Algorithm 6: walk the fiber chain; the first fiber that
       declares the key must be committed to a provider for it. *)
    let rec walk f =
      if declares f key.Key.kuid then
        match f.f_committed with
        | Some view when List.mem_assoc key.Key.kuid view -> (
          match read_store f.f_ctx with
          | Some v -> v
          | None -> raise (Inactive_access key.Key.kname))
        | _ -> raise (Inactive_access key.Key.kname)
      else
        match f.f_parent.cfiber with
        | Some parent -> walk parent
        | None -> raise (Undeclared_access key.Key.kname)
    in
    walk start

(* ── Isolation and interception ─────────────────────────────────────── *)

let isolate ?realm ctx ex =
  let kuid = Key.ex_uid ex in
  let r =
    match realm with
    | Some name -> Rnamed (kuid, name)
    | None ->
      ctx.rt.r_next_realm <- ctx.rt.r_next_realm + 1;
      Rlocal (kuid, ctx.rt.r_next_realm)
  in
  { ctx with iso = (kuid, r) :: ctx.iso }

let intercept ctx ex meta =
  { ctx with meta = (Key.ex_uid ex, meta) :: ctx.meta }

let interception ctx ex =
  let kuid = Key.ex_uid ex in
  let entries =
    List.filter_map (fun (k, m) -> if k = kuid then Some m else None) ctx.meta
  in
  match entries with
  | [] -> None
  | [ m ] -> Some m
  | nearest_first ->
    (* Shallow-merge JSON objects, nearest derivation winning per field;
       for non-objects the nearest entry wins outright. *)
    let merge acc m =
      match (acc, m) with
      | `Assoc a, `Assoc b ->
        `Assoc (a @ List.filter (fun (k, _) -> not (List.mem_assoc k a)) b)
      | acc, _ -> acc
    in
    Some (List.fold_left merge (List.hd nearest_first) (List.tl nearest_first))

(* ── Events ─────────────────────────────────────────────────────────── *)

let on ?(label = "listener") ctx (ev : 'a Event.t) (fn : 'a -> unit) =
  let cell =
    match Hashtbl.find_opt ctx.rt.r_listeners ev.Event.euid with
    | Some cell -> cell
    | None ->
      let cell = ref [] in
      Hashtbl.replace ctx.rt.r_listeners ev.Event.euid cell;
      cell
  in
  let entry = Listener (ev, fn) in
  track ~label:(label ^ " on " ^ ev.Event.ename) ctx (fun () ->
      cell := !cell @ [ entry ];
      fun () -> cell := List.filter (fun e -> e != entry) !cell)

let emit (type a) ctx (ev : a Event.t) (x : a) =
  match Hashtbl.find_opt ctx.rt.r_listeners ev.Event.euid with
  | None -> ()
  | Some cell ->
    List.iter
      (fun (Listener (e, fn)) ->
        match eq_tid e.Event.etid ev.Event.etid with
        | Some Teq -> fn x
        | None -> ())
      !cell

(* ── Components and fibers ──────────────────────────────────────────── *)

let component ~name ?(inject = []) ?(provide = []) apply =
  { c_name = name; c_inject = inject; c_provide = provide; c_apply = apply }

module Fiber = struct
  type t = fiber

  type state = Pending | Loading | Active | Unloading | Failed | Disposed

  let state f =
    match f.f_state with
    | SPending -> Pending
    | SLoading -> Loading
    | SActive -> Active
    | SUnloading -> Unloading
    | SFailed _ -> Failed
    | SDisposed -> Disposed

  let name f = f.f_comp.c_name
  let uid f = f.f_uid
  let error f = match f.f_state with SFailed e -> Some e | _ -> None

  let pp_state ppf st =
    Format.pp_print_string ppf
      (match st with
      | Pending -> "pending"
      | Loading -> "loading"
      | Active -> "active"
      | Unloading -> "unloading"
      | Failed -> "failed"
      | Disposed -> "disposed")
end

let use ctx comp =
  let rt = ctx.rt in
  rt.r_next_uid <- rt.r_next_uid + 1;
  let f =
    {
      f_uid = rt.r_next_uid;
      f_comp = comp;
      f_parent = ctx;
      f_ctx = ctx;
      f_state = SPending;
      f_disposables = [];
      f_committed = None;
      f_retired = false;
    }
  in
  f.f_ctx <- { ctx with cfiber = Some f };
  rt.r_fibers <- rt.r_fibers @ [ f ];
  let (_ : unit -> unit) =
    track ~label:("use " ^ comp.c_name) ctx (fun () ->
        schedule rt f;
        fun () -> retire_fiber rt f)
  in
  maybe_settle rt;
  f

let dispose f =
  let rt = f.f_parent.rt in
  retire_fiber rt f;
  maybe_settle rt

let restart f =
  let rt = f.f_parent.rt in
  if not f.f_retired then begin
    (match f.f_state with
     | SActive -> deactivate rt f
     | SFailed _ -> set_state f SPending
     | _ -> ());
    schedule rt f;
    maybe_settle rt
  end

let fibers ctx =
  List.filter
    (fun f -> match f.f_state with SDisposed -> false | _ -> true)
    ctx.rt.r_fibers

let trace_transitions ctx =
  observe ctx (fun f ->
      Trace.emit
        (Trace.Plugin_transition
           {
             name = Fiber.name f;
             uid = Fiber.uid f;
             state = Format.asprintf "%a" Fiber.pp_state (Fiber.state f);
           }))

(* ── Well-known harness service keys ────────────────────────────────── *)

module Services = struct
  let provider : Provider.packed_provider Key.t =
    Key.create ~name:"provider" ()
end

(* ── Tool registry service ──────────────────────────────────────────── *)

module Toolset = struct
  type t = { mutable tools : Tool.packed_tool list }

  let key : t Key.t = Key.create ~name:"toolset" ()

  let provider =
    component ~name:"toolset" ~provide:[ Key.Ex key ] (fun ctx ->
        let (_ : unit -> unit) = provide ctx key { tools = [] } in
        ())

  let register ctx tool =
    let reg = get ctx key in
    track ~label:("register " ^ Tool.name_of_packed tool) ctx (fun () ->
        reg.tools <- reg.tools @ [ tool ];
        fun () -> reg.tools <- List.filter (fun t -> t != tool) reg.tools)

  let snapshot ctx = (get ctx key).tools
end

(* ── Declarative reconciliation ─────────────────────────────────────── *)

module Reconcile = struct
  type entry = {
    id : string;
    enabled : bool;
    config : Yojson.Safe.t;
    plugin : Yojson.Safe.t -> component;
  }

  type slot = { s_entry : entry; s_fiber : Fiber.t option }
  type t = { r_ctx : context; mutable slots : (string * slot) list }

  let create ctx = { r_ctx = ctx; slots = [] }

  let instantiate t (e : entry) =
    if e.enabled then Some (use t.r_ctx (e.plugin e.config)) else None

  let apply t entries =
    let ids = List.map (fun (e : entry) -> e.id) entries in
    let rec dup = function
      | [] -> None
      | x :: rest -> if List.mem x rest then Some x else dup rest
    in
    (match dup ids with
     | Some id -> invalid_arg ("Plugin.Reconcile.apply: duplicate entry id " ^ id)
     | None -> ());
    (* Dispose fibers whose entries are gone. *)
    List.iter
      (fun (id, slot) ->
        if not (List.mem id ids) then Option.iter dispose slot.s_fiber)
      t.slots;
    (* Create, keep, or rebuild each surviving entry. *)
    t.slots <-
      List.map
        (fun (e : entry) ->
          let slot =
            match List.assoc_opt e.id t.slots with
            | Some old
              when old.s_entry.enabled = e.enabled
                   && old.s_entry.config = e.config ->
              { s_entry = e; s_fiber = old.s_fiber }
            | Some old ->
              Option.iter dispose old.s_fiber;
              { s_entry = e; s_fiber = instantiate t e }
            | None -> { s_entry = e; s_fiber = instantiate t e }
          in
          (e.id, slot))
        entries

  let fiber t id =
    match List.assoc_opt id t.slots with
    | Some { s_fiber = Some f; _ } -> Some f
    | _ -> None
end
