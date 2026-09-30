open Lwt.Infix

(* A synthetic loopback-only HTTP/1.1 peer records physical connections. It
   never accesses a TWINS session or makes an external request. *)
type fixture = {
  uri : string -> Uri.t;
  opened : int ref;
  closed : int ref;
  requests : int ref;
}

let close_noerr socket =
  Lwt.catch (fun () -> Lwt_unix.close socket) (fun _ -> Lwt.return_unit)

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

let () =
  Alcotest.run "read-only connection reuse"
    [
      ( "transport",
        [
          Alcotest.test_case "reuse, complete bodies, cleanup, restore" `Quick
            test_reuse_and_restore;
          Alcotest.test_case "GET only" `Quick test_get_only;
          Alcotest.test_case "no automatic retry" `Quick test_no_retry;
          Alcotest.test_case "exception cleanup" `Quick test_exception_cleanup;
          Alcotest.test_case "timeout cleanup" `Quick test_timeout_cleanup;
        ] );
    ]
