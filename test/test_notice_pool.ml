open Lwt.Infix

(* Exercise the real scoped transport against synthetic notice pages on
   loopback. No saved session or university endpoint is used. *)
type fixture = {
  uri : string -> Uri.t;
  opened : int ref;
  closed : int ref;
  requests : (string * string) list ref;
}

let close_noerr socket =
  Lwt.catch (fun () -> Lwt_unix.close socket) (fun _ -> Lwt.return_unit)

let with_server pages operation =
  let listener = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Lwt_main.run
    (Lwt_unix.bind listener (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)));
  Lwt_unix.listen listener 10;
  let port =
    match Lwt_unix.getsockname listener with
    | Unix.ADDR_INET (_, port) -> port
    | _ -> assert false
  in
  let opened = ref 0 and closed = ref 0 and requests = ref [] in
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
          let meth, path =
            match String.split_on_char ' ' request with
            | meth :: path :: _ -> (meth, path)
            | _ -> ("malformed", "/malformed")
          in
          requests := !requests @ [ (meth, path) ];
          if path = "/drop" then Lwt.return_unit
          else if path = "/hang" then Lwt_io.read_char_opt ic >|= fun _ -> ()
          else
            let body = List.assoc path pages in
            Lwt_io.write oc
              (Printf.sprintf
                 "HTTP/1.1 200 OK\r\n\
                  Content-Length: %d\r\n\
                  Connection: keep-alive\r\n\
                  \r\n\
                  %s"
                 (String.length body) body)
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
  Fun.protect
    ~finally:(fun () ->
      Lwt.cancel accepting;
      List.iter Lwt.cancel !handlers;
      Lwt_main.run
        (close_noerr listener >>= fun () -> Lwt_list.iter_s close_noerr !sockets))
    (fun () ->
      operation
        {
          uri =
            (fun path ->
              Uri.of_string (Printf.sprintf "http://127.0.0.1:%d%s" port path));
          opened;
          closed;
          requests;
        })

let send ?(timeout = 2.) fixture path meth =
  let _, _, body =
    Lwt_main.run
      (Lwt_unix.with_timeout timeout (fun () ->
           Http_client.send ~headers:(Cohttp.Header.init ()) meth
             (fixture.uri path) None))
  in
  Soup.parse body

let page id next =
  "<table><tr><th>ジャンル</th><th>表題</th><th>掲示期間</th><th>掲載日時</th></tr>"
  ^ "<tr><td>Fixture</td><td><a href='?seqNo=" ^ id ^ "'>Title " ^ id
  ^ "</a></td><td>Term</td><td>Date</td></tr></table>"
  ^ Option.fold ~none:""
      ~some:(fun href -> "<a rel='next' href='" ^ href ^ "'>次へ</a>")
      next

let parse soup =
  match Twins.parse_notices soup with
  | Ok rows -> rows
  | Error error -> failwith (Error.to_string error)

let read ?reuse_connections ?(search = "/search") ?(timeout = 2.)
    ?(max_pages = 20) fixture =
  Notice_read.run ?reuse_connections
    ~search:(fun () -> send fixture search `POST)
    ~collect:(fun first ->
      Notice_pagination.collect
        ~fetch:(fun _ href -> send ~timeout fixture href `GET)
        ~parse
        ~next:(fun soup -> Notice_pagination.next soup)
        ~id:(fun (notice : Twins.notice) -> notice.seq)
        ~limit:None ~max_pages first)
    ()

let pump () = Lwt_main.run (Lwt_unix.sleep 0.01)

let expect_failure operation =
  match operation () with
  | _ -> Alcotest.fail "expected notice read failure"
  | exception _ -> ()

let all_pages =
  [
    ("/search", page "A" (Some "/page-2"));
    ("/page-2", page "B" (Some "/page-3"));
    ("/page-3", page "C" None);
  ]

let test_reuse_and_opt_out () =
  List.iter
    (fun reuse_connections ->
      with_server all_pages (fun fixture ->
          let result = read ~reuse_connections fixture in
          pump ();
          Alcotest.(check (list string))
            "all page outputs preserved" [ "A"; "B"; "C" ]
            (List.map (fun (notice : Twins.notice) -> notice.seq) result.items);
          Alcotest.(check int) "all pages fetched" 3 result.pages_fetched;
          Alcotest.(check string) "complete" "complete" result.completeness;
          Alcotest.(check (list (pair string string)))
            "search POST happens once, followed by GET pagination"
            [ ("POST", "/search"); ("GET", "/page-2"); ("GET", "/page-3") ]
            !(fixture.requests);
          let expected = if reuse_connections then 2 else 3 in
          Alcotest.(check int)
            "only pagination connections are reused" expected !(fixture.opened);
          Alcotest.(check int)
            "all connections closed" expected !(fixture.closed);
          ignore (send fixture "/search" `POST);
          ignore (send fixture "/search" `POST);
          Alcotest.(check int)
            "subsequent POSTs use restored default transport" (expected + 2)
            !(fixture.opened)))
    [ true; false ]

let test_default_and_single_page () =
  with_server
    [ ("/search", page "A" None) ]
    (fun fixture ->
      let result = read fixture in
      pump ();
      Alcotest.(check int) "single page output" 1 result.pages_fetched;
      Alcotest.(check int) "no pagination connection opened" 1 !(fixture.opened);
      Alcotest.(check int) "search connection closed" 1 !(fixture.closed));
  with_server all_pages (fun fixture ->
      ignore (read fixture);
      pump ();
      Alcotest.(check int) "reuse enabled by default" 2 !(fixture.opened);
      Alcotest.(check int) "default pool closed" 2 !(fixture.closed))

let test_page_limit () =
  with_server all_pages (fun fixture ->
      let result = read ~max_pages:2 fixture in
      pump ();
      Alcotest.(check (option string))
        "limit preserved" (Some "page_limit") result.reason;
      Alcotest.(check int)
        "no extra page requested" 2
        (List.length !(fixture.requests));
      Alcotest.(check int) "partial result closes pool" 2 !(fixture.closed))

let test_failure_cleanup () =
  let cases =
    [
      ("parse failure", "/page-2", "<p>Missing notice table</p>");
      ("request EOF", "/drop", "");
      ("request timeout", "/hang", "");
    ]
  in
  List.iter
    (fun (label, target, response) ->
      with_server
        [ ("/search", page "A" (Some target)); (target, response) ]
        (fun fixture ->
          expect_failure (fun () -> read ~timeout:0.03 fixture);
          pump ();
          Alcotest.(check int)
            (label ^ " closes both connections")
            2 !(fixture.closed);
          Alcotest.(check int)
            (label ^ " never replays a request")
            2
            (List.length !(fixture.requests));
          ignore (send fixture "/search" `POST);
          Alcotest.(check int)
            (label ^ " restores POST transport")
            3 !(fixture.opened)))
    cases

let test_search_failure () =
  with_server [] (fun fixture ->
      expect_failure (fun () -> read ~search:"/drop" fixture);
      pump ();
      Alcotest.(check int)
        "failed search never starts pagination" 1 !(fixture.opened);
      Alcotest.(check (list (pair string string)))
        "search POST never replayed"
        [ ("POST", "/drop") ]
        !(fixture.requests);
      Alcotest.(check int) "failed search connection closed" 1 !(fixture.closed))

let () =
  Alcotest.run "notice pagination connection reuse"
    [
      ( "scoped reads",
        [
          Alcotest.test_case "GET reuse, output equality and opt-out" `Quick
            test_reuse_and_opt_out;
          Alcotest.test_case "default reuse and single-page no-op" `Quick
            test_default_and_single_page;
          Alcotest.test_case "page-limit cleanup" `Quick test_page_limit;
          Alcotest.test_case "parse, EOF and timeout cleanup" `Quick
            test_failure_cleanup;
          Alcotest.test_case "search failure is never pooled or replayed" `Quick
            test_search_failure;
        ] );
    ]
