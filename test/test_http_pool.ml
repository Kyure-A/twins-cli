open Lwt.Infix

(* A synthetic loopback-only HTTP/1.1 peer records physical connections. It
   never accesses a TWINS session or makes an external request. *)
type fixture = {
  uri : string -> Uri.t;
  opened : int ref;
  closed : int ref;
  requests : int ref;
  after_close_bytes : int ref;
}

let close_noerr socket =
  Lwt.catch (fun () -> Lwt_unix.close socket) (fun _ -> Lwt.return_unit)

(* Produced independently with Python's gzip.compress, mtime=0. *)
let gzip_body =
  "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\x4b\xce\xcf\x2d\x28\x4a\x2d\x2e\x4e\x4d\x51\x48\xcb\xac\x28\x29\x2d\x4a\x55\xf0\xf7\x06\x00\xbe\x30\xc0\x62\x15\x00\x00\x00"

let with_server operation =
  let listener = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_main.run
    (Lwt_unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)));
  Lwt_unix.listen listener 10;
  let port =
    match Lwt_unix.getsockname listener with
    | Unix.ADDR_INET (_, port) -> port
    | _ -> assert false
  in
  let opened = ref 0 and closed = ref 0 and requests = ref 0 in
  let after_close_bytes = ref 0 in
  let sockets = ref [] and handlers = ref [] in
  let handle socket =
    let ic = Lwt_io.of_fd ~mode:Lwt_io.input socket in
    let oc = Lwt_io.of_fd ~mode:Lwt_io.output socket in
    let rec headers () =
      Lwt_io.read_line_opt ic >>= function
      | None | Some "" | Some "\r" -> Lwt.return_unit
      | Some _ -> headers ()
    in
    let rec serve () =
      Lwt_io.read_line_opt ic >>= function
      | None -> Lwt.return_unit
      | Some request ->
          headers () >>= fun () ->
          incr requests;
          let path =
            match String.split_on_char ' ' request with
            | _meth :: path :: _ -> path
            | _ -> "/malformed"
          in
          if path = "/drop" then Lwt.return_unit
          else if path = "/hang" then
            (* Wait for EOF to prove client cancellation closes the transport. *)
            Lwt_io.read_char_opt ic >|= fun _ -> ()
          else if
            List.mem path
              [
                "/close";
                "/close-tokens";
                "/http10";
                "/http10-keepalive";
                "/http11-implicit";
                "/bad-gzip-close";
              ]
          then (
            let version =
              if String.starts_with ~prefix:"/http10" path then "HTTP/1.0"
              else "HTTP/1.1"
            in
            let extra =
              match path with
              | "/close" -> "Connection: close\r\n"
              | "/close-tokens" -> "Connection: Keep-Alive, ClOsE\r\n"
              | "/http10-keepalive" -> "Connection: keep-alive\r\n"
              | "/bad-gzip-close" ->
                  "Connection: close\r\nContent-Encoding: gzip\r\n"
              | _ -> ""
            in
            let body =
              if path = "/bad-gzip-close" then "invalid gzip" else "OK"
            in
            Lwt_io.write oc
              (Printf.sprintf "%s 200 OK\r\nContent-Length: %d\r\n%s\r\n"
                 version (String.length body) extra)
            >>= fun () ->
            (* Split the response to catch retiring a connection at headers,
               before the body has been consumed. *)
            Lwt_io.write oc (String.sub body 0 1) >>= fun () ->
            Lwt_io.flush oc >>= fun () ->
            Lwt.pause () >>= fun () ->
            Lwt_io.write oc (String.sub body 1 (String.length body - 1))
            >>= fun () ->
            Lwt_io.flush oc >>= fun () ->
            if path = "/http10-keepalive" || path = "/http11-implicit" then
              serve ()
            else
              (* Deliberately leave EOF pending. A correct client honors the
                 response's close semantics before sending another request. *)
              Lwt_io.read_char_opt ic >|= fun byte ->
              if byte <> None then incr after_close_bytes)
          else if path = "/gzip" || path = "/bad-gzip" then
            let body = if path = "/gzip" then gzip_body else "invalid gzip" in
            Lwt_io.write oc
              (Printf.sprintf
                 "HTTP/1.1 200 OK\r\n\
                  Content-Length: %d\r\n\
                  Content-Encoding: gzip\r\n\
                  Connection: keep-alive\r\n\
                  \r\n\
                  %s"
                 (String.length body) body)
            >>= fun () -> Lwt_io.flush oc >>= serve
          else
            Lwt_io.write oc
              "HTTP/1.1 200 OK\r\n\
               Content-Length: 2\r\n\
               Connection: keep-alive\r\n\
               \r\n\
               OK"
            >>= fun () -> Lwt_io.flush oc >>= serve
    in
    Lwt.finalize
      (fun () -> Lwt.catch serve (fun _ -> Lwt.return_unit))
      (fun () ->
        incr closed;
        close_noerr socket)
  in
  let rec accept () =
    Lwt_unix.accept listener >>= fun (socket, _) ->
    sockets := socket :: !sockets;
    incr opened;
    let handler = handle socket in
    handlers := handler :: !handlers;
    Lwt.async (fun () -> handler);
    accept ()
  in
  let accepting = accept () in
  let fixture =
    {
      uri =
        (fun path ->
          Uri.of_string (Printf.sprintf "http://127.0.0.1:%d%s" port path));
      opened;
      closed;
      requests;
      after_close_bytes;
    }
  in
  Fun.protect
    ~finally:(fun () ->
      Lwt.cancel accepting;
      List.iter Lwt.cancel !handlers;
      Lwt_main.run
        (close_noerr listener >>= fun () -> Lwt_list.iter_s close_noerr !sockets))
    (fun () -> operation fixture)

let send fixture path meth =
  Lwt_main.run
    (Lwt_unix.with_timeout 2. (fun () ->
         Http_client.send ~headers:(Cohttp.Header.init ()) meth
           (fixture.uri path) None))

let pump () = Lwt_main.run (Lwt_unix.sleep 0.01)

let expect_failure operation =
  match operation () with
  | _ -> Alcotest.fail "expected request failure"
  | exception _ -> ()

let test_reuse_and_restore () =
  with_server (fun fixture ->
      ignore (send fixture "/" `GET);
      ignore (send fixture "/" `GET);
      pump ();
      Alcotest.(check int) "default opens each request" 2 !(fixture.opened);
      Alcotest.(check int) "default closes each connection" 2 !(fixture.closed);
      Http_client.with_reused_connections (fun () ->
          for _ = 1 to 3 do
            let status, _, body = send fixture "/" `GET in
            Alcotest.(check int) "status" 200 status;
            Alcotest.(check string) "body fully read" "OK" body
          done;
          Alcotest.(check int)
            "three reads reuse one connection" 3 !(fixture.opened);
          Alcotest.(check int)
            "pooled connection open inside scope" 2 !(fixture.closed));
      pump ();
      Alcotest.(check int) "pool closes on success" 3 !(fixture.closed);
      ignore (send fixture "/" `GET);
      ignore (send fixture "/" `GET);
      pump ();
      Alcotest.(check int) "default transport restored" 5 !(fixture.opened);
      Alcotest.(check int) "every request sent once" 7 !(fixture.requests))

let test_get_only () =
  with_server (fun fixture ->
      Http_client.with_reused_connections (fun () ->
          expect_failure (fun () -> send fixture "/" `POST));
      Alcotest.(check int)
        "rejected before opening connection" 0 !(fixture.opened);
      Alcotest.(check int) "no request sent" 0 !(fixture.requests))

let test_nonpersistent_responses () =
  List.iter
    (fun path ->
      with_server (fun fixture ->
          Http_client.with_reused_connections (fun () ->
              let _, _, body = send fixture path `GET in
              Alcotest.(check string) "body drained before retirement" "OK" body;
              (* There is no sleep between reads: the next unsent GET must use
                 a new socket even before the old peer reports EOF. *)
              ignore (send fixture "/" `GET);
              ignore (send fixture "/" `GET);
              Alcotest.(check int)
                "fresh connection then reuse" 2 !(fixture.opened);
              Alcotest.(check int) "each GET sent once" 3 !(fixture.requests);
              Alcotest.(check int)
                "no bytes sent after close response" 0
                !(fixture.after_close_bytes));
          pump ();
          Alcotest.(check int)
            "both connections closed on scope exit" 2 !(fixture.closed)))
    [ "/close"; "/close-tokens"; "/http10" ];
  List.iter
    (fun path ->
      with_server (fun fixture ->
          Http_client.with_reused_connections (fun () ->
              ignore (send fixture path `GET);
              ignore (send fixture "/" `GET);
              Alcotest.(check int)
                "persistent response still reuses" 1 !(fixture.opened);
              Alcotest.(check int) "both GETs sent once" 2 !(fixture.requests))))
    [ "/http10-keepalive"; "/http11-implicit" ]

let test_retired_pool_decode_failure () =
  with_server (fun fixture ->
      expect_failure (fun () ->
          Http_client.with_reused_connections (fun () ->
              ignore (send fixture "/bad-gzip-close" `GET)));
      pump ();
      Alcotest.(check int)
        "retired pool closed before decode failure" 1 !(fixture.closed);
      Alcotest.(check int) "bad response never replayed" 1 !(fixture.requests);
      Alcotest.(check int)
        "retirement opens no replacement socket" 1 !(fixture.opened);
      ignore (send fixture "/" `POST);
      ignore (send fixture "/" `POST);
      pump ();
      Alcotest.(check int) "default POST transport restored" 3 !(fixture.opened);
      Alcotest.(check int) "all connections closed" 3 !(fixture.closed))

let test_no_retry () =
  with_server (fun fixture ->
      Http_client.with_reused_connections (fun () ->
          expect_failure (fun () -> send fixture "/drop" `GET));
      pump ();
      Alcotest.(check int)
        "EOF does not open retry connection" 1 !(fixture.opened);
      Alcotest.(check int) "EOF does not replay request" 1 !(fixture.requests);
      ignore (send fixture "/" `GET);
      Alcotest.(check int)
        "normal transport restored after failure" 2 !(fixture.opened))

let test_exception_cleanup () =
  with_server (fun fixture ->
      expect_failure (fun () ->
          Http_client.with_reused_connections (fun () ->
              ignore (send fixture "/" `GET);
              failwith "synthetic parser failure"));
      pump ();
      Alcotest.(check int)
        "parser failure closes connection" 1 !(fixture.closed);
      ignore (send fixture "/" `GET);
      ignore (send fixture "/" `GET);
      Alcotest.(check int)
        "exception restores default transport" 3 !(fixture.opened))

let test_timeout_cleanup () =
  with_server (fun fixture ->
      expect_failure (fun () ->
          Http_client.with_reused_connections (fun () ->
              Lwt_main.run
                (Lwt_unix.with_timeout 0.03 (fun () ->
                     Http_client.send ~headers:(Cohttp.Header.init ()) `GET
                       (fixture.uri "/hang") None))));
      pump ();
      Alcotest.(check int) "timeout closes connection" 1 !(fixture.closed);
      Alcotest.(check int)
        "timed-out request never replayed" 1 !(fixture.requests);
      ignore (send fixture "/" `GET);
      Alcotest.(check int)
        "timeout restores default transport" 2 !(fixture.opened))

let test_compressed_reuse () =
  with_server (fun fixture ->
      let events = ref [] in
      Profile.run ~enabled:true
        ~emit:(fun value -> events := value :: !events)
        (fun () ->
          Http_client.with_reused_connections (fun () ->
              let _, _, body = send fixture "/gzip" `GET in
              Alcotest.(check string)
                "gzip body decoded" "compressed fixture OK" body;
              let _, _, body = send fixture "/" `GET in
              Alcotest.(check string) "next response intact" "OK" body;
              Alcotest.(check int)
                "fully drained gzip reuses physical connection" 1
                !(fixture.opened)));
      pump ();
      Alcotest.(check int) "compression pool closes" 1 !(fixture.closed);
      let open Yojson.Safe.Util in
      let hops =
        List.hd !events |> member "profile" |> member "http" |> to_list
      in
      let first = List.hd hops in
      Alcotest.(check int)
        "decoded size in profile" 21
        (first |> member "bytes" |> to_int);
      Alcotest.(check int)
        "encoded size in profile" (String.length gzip_body)
        (first |> member "wireBytes" |> to_int);
      expect_failure (fun () ->
          Http_client.with_reused_connections (fun () ->
              ignore (send fixture "/bad-gzip" `GET)));
      pump ();
      Alcotest.(check int) "decoding failure closes pool" 2 !(fixture.closed);
      Alcotest.(check int)
        "decoding failure does not retry" 3 !(fixture.requests);
      ignore (send fixture "/" `GET);
      pump ();
      Alcotest.(check int)
        "decoding failure restores transport" 3 !(fixture.opened))

let test_timetable_defaults () =
  (* Loading this incompatible, synthetic session fails before any TWINS
     request. It lets the public read APIs select their real transport while
     keeping this wiring/cleanup regression entirely offline. *)
  let session_file = Filename.temp_file "twins-timetable-pool-" ".session" in
  Fun.protect
    ~finally:(fun () -> Sys.remove session_file)
    (fun () ->
      let channel = open_out session_file in
      output_string channel "# legacy fixture\nsid\tfake-fixture\n";
      close_out channel;
      let module_ = List.hd Twins.Module.all in
      let reads =
        [
          ( "single default",
            "reuse",
            fun () -> Twins.timetable ~session_file module_ |> Result.map ignore
          );
          ( "batch default",
            "reuse",
            fun () -> Twins.timetable_all ~session_file () |> Result.map ignore
          );
          ( "single opt-out",
            "default",
            fun () ->
              Twins.timetable ~session_file ~reuse_connections:false module_
              |> Result.map ignore );
          ( "batch opt-out",
            "default",
            fun () ->
              Twins.timetable_all ~session_file ~reuse_connections:false ()
              |> Result.map ignore );
        ]
      in
      with_server (fun fixture ->
          List.iter
            (fun (label, transport, read) ->
              let emitted = ref [] in
              let check_failure () =
                match read () with
                | Error (Error.Protocol_error _) -> ()
                | Error error -> Alcotest.fail (Error.to_string error)
                | Ok () -> Alcotest.fail "expected incompatible session failure"
              in
              (* Reuse is supported without profiling, too. *)
              check_failure ();
              Profile.run ~enabled:true
                ~emit:(fun event -> emitted := event :: !emitted)
                check_failure;
              let open Yojson.Safe.Util in
              let profile = List.hd !emitted |> member "profile" in
              Alcotest.(check string)
                label transport
                (profile |> member "transport" |> to_string);
              Alcotest.(check int)
                "session failure made no HTTP requests" 0
                (profile |> member "http" |> to_list |> List.length);
              (* A leaking pool would reuse this pair after the API returns. *)
              let opened_before = !(fixture.opened) in
              ignore (send fixture "/" `GET);
              ignore (send fixture "/" `GET);
              pump ();
              Alcotest.(check int)
                "failed read restores independent transport" (opened_before + 2)
                !(fixture.opened);
              Alcotest.(check int)
                "failed read leaves no pooled connection" !(fixture.opened)
                !(fixture.closed))
            reads))

let () =
  Alcotest.run "read-only connection reuse"
    [
      ( "transport",
        [
          Alcotest.test_case "reuse, complete bodies, cleanup, restore" `Quick
            test_reuse_and_restore;
          Alcotest.test_case "GET only" `Quick test_get_only;
          Alcotest.test_case "retire nonpersistent responses without replay"
            `Quick test_nonpersistent_responses;
          Alcotest.test_case "retirement and decode failure restore transport"
            `Quick test_retired_pool_decode_failure;
          Alcotest.test_case "no automatic retry" `Quick test_no_retry;
          Alcotest.test_case "exception cleanup" `Quick test_exception_cleanup;
          Alcotest.test_case "timeout cleanup" `Quick test_timeout_cleanup;
          Alcotest.test_case "gzip consumption, connection reuse, and cleanup"
            `Quick test_compressed_reuse;
          Alcotest.test_case "public timetable defaults, opt-out, and cleanup"
            `Quick test_timetable_defaults;
        ] );
    ]
