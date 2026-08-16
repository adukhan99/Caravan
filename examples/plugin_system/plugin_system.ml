(** Plugin system — Caravan example.

    Demonstrates the spatiotemporal composability runtime
    ([Caravan.Plugin]): revertible effects, reactive service injection,
    lifecycle cascades, and declarative reconciliation. Runs entirely
    offline:

      dune exec examples/plugin_system/plugin_system.exe
*)

open Caravan

let section title = Printf.printf "\n── %s ──\n%!" title

(* Watch every lifecycle transition the runtime performs. *)
let install_observer ctx =
  Plugin.observe ctx (fun f ->
      Printf.printf "  [lifecycle] %-12s -> %s\n%!" (Plugin.Fiber.name f)
        (Format.asprintf "%a" Plugin.Fiber.pp_state (Plugin.Fiber.state f)))

(* ── Services ─────────────────────────────────────────────────────────── *)

(* A typed service key: plugins depending on it declare it in [inject]. *)
type greeting_style = { prefix : string }

let style_key : greeting_style Plugin.Key.t =
  Plugin.Key.create ~name:"greeting-style" ()

let () =
  let ctx = Plugin.make () in
  install_observer ctx;

  section "1. A plugin waits for its dependency, then activates";
  let greeter =
    Plugin.component ~name:"greeter" ~inject:[ Plugin.Key.Ex style_key ]
      (fun cctx ->
        let style = Plugin.get cctx style_key in
        Printf.printf "  greeter says: %s, world!\n%!" style.prefix;
        ignore
          (Plugin.on_dispose cctx (fun () ->
               Printf.printf "  greeter cleaned up\n%!")))
  in
  let greeter_fiber = Plugin.use ctx greeter in
  Printf.printf "  (greeter is %s — no style provided yet)\n%!"
    (Format.asprintf "%a" Plugin.Fiber.pp_state
       (Plugin.Fiber.state greeter_fiber));

  let withdraw = Plugin.provide ctx style_key { prefix = "Hello" } in
  (* ^ the greeter activated reactively the moment the style appeared *)

  section "2. Withdrawing the service deactivates dependents first";
  Plugin.Disposer.dispose withdraw;
  ignore (Plugin.provide ctx style_key { prefix = "Salut" });
  (* ^ and providing a replacement reactivates them *)

  section "3. A tool pack: registrations vanish with their plugin";
  ignore (Plugin.use ctx Plugin.Toolset.provider);
  let file_tools =
    Plugin.component ~name:"file-tools"
      ~inject:[ Plugin.Key.Ex Plugin.Toolset.key ] (fun cctx ->
        ignore
          (Plugin.Toolset.register cctx
             (Tool.Tool (module CaravanTools.Read_file.Read_file))))
  in
  let pack = Plugin.use ctx file_tools in
  let show_tools () =
    Printf.printf "  toolset: [%s]\n%!"
      (String.concat "; "
         (List.map Tool.name_of_packed (Plugin.Toolset.snapshot ctx)))
  in
  show_tools ();
  Plugin.dispose pack;
  show_tools ();

  section "4. Declarative reconciliation";
  let echo_key : string Plugin.Key.t = Plugin.Key.create ~name:"echo" () in
  let echo_plugin config =
    let text = Yojson.Safe.Util.(config |> member "text" |> to_string) in
    Plugin.component ~name:"echo" ~provide:[ Plugin.Key.Ex echo_key ]
      (fun cctx -> ignore (Plugin.provide cctx echo_key text))
  in
  let r = Plugin.Reconcile.create ctx in
  let entry text =
    {
      Plugin.Reconcile.id = "echo";
      enabled = true;
      config = `Assoc [ ("text", `String text) ];
      plugin = echo_plugin;
    }
  in
  Plugin.Reconcile.apply r [ entry "one" ];
  Printf.printf "  echo service: %s\n%!" (Plugin.get ctx echo_key);
  Plugin.Reconcile.apply r [ entry "two" ];
  (* ^ config changed: the entry was rebuilt (dispose + fresh fiber) *)
  Printf.printf "  echo service: %s\n%!" (Plugin.get ctx echo_key);
  Plugin.Reconcile.apply r [];
  Printf.printf "  echo service after removal: %s\n%!"
    (match Plugin.find ctx echo_key with Some s -> s | None -> "(gone)");

  section "done";
  Printf.printf "  live fibers: %d\n%!" (List.length (Plugin.fibers ctx))
