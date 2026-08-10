(** Shared HTTPS connection handler.

    This is the single place Caravan performs TLS. Unlike the three
    copy-pasted handlers it replaces, it verifies the peer certificate
    against the system CA store and checks the hostname.

    Verification can be disabled only by exporting
    [CARAVAN_TLS_INSECURE=1] — useful for self-signed local endpoints —
    and Caravan warns loudly on stderr the first time it happens. *)

let insecure_requested () =
  match Sys.getenv_opt "CARAVAN_TLS_INSECURE" with
  | Some ("1" | "true" | "yes") -> true
  | _ -> false

let warned = ref false

let warn_insecure () =
  if not !warned then begin
    warned := true;
    Printf.eprintf
      "[Caravan] WARNING: CARAVAN_TLS_INSECURE is set — TLS certificate \
       verification is DISABLED for this session.\n%!"
  end

(** [https_handler] plugs into [Cohttp_eio.Client.make ~https]. *)
let https_handler uri raw_sock =
  let host = Uri.host uri |> Option.value ~default:"" in
  let ssl_ctx = Ssl.create_context Ssl.TLSv1_2 Ssl.Client_context in
  if insecure_requested () then warn_insecure ()
  else begin
    (* Trust the system CA store and require a valid chain. The callback
       stays [None]: [Verify_peer] alone enforces verification, while
       [Ssl.client_verify_callback] would noisily print the certificate
       chain to stdout on every connection. *)
    ignore (Ssl.set_default_verify_paths ssl_ctx);
    Ssl.set_verify ssl_ctx [Ssl.Verify_peer] None
  end;
  (* cohttp-eio hands us a generic stream socket; eio-ssl needs the unix
     flavour. The coercion is safe on every platform Caravan targets
     (the socket always originates from Eio_unix) but cannot be expressed
     without magic until cohttp-eio exposes the concrete type. *)
  let ctx =
    Eio_ssl.Context.create ~ctx:ssl_ctx
      (Obj.magic raw_sock : Eio_unix.Net.stream_socket_ty Eio.Resource.t)
  in
  let ssl_sock = Eio_ssl.Context.ssl_socket ctx in
  Ssl.set_client_SNI_hostname ssl_sock host;
  if not (insecure_requested ()) then begin
    (* Bind hostname verification into the X509 verify step. *)
    Ssl.set_hostflags ssl_sock [Ssl.No_partial_wildcards];
    Ssl.set_host ssl_sock host
  end;
  let connected = Eio_ssl.connect ctx in
  (connected :> _ Eio.Flow.two_way)

(** Build a cohttp-eio client appropriate for [uri]'s scheme. *)
let make_client net uri =
  match Uri.scheme uri with
  | Some "https" -> Cohttp_eio.Client.make ~https:(Some https_handler) net
  | _ -> Cohttp_eio.Client.make ~https:None net
