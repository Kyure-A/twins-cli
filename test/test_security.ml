let origin = Uri.of_string "https://twins.tsukuba.ac.jp/campusweb/portal.do"
let uri path = Uri.of_string ("https://twins.tsukuba.ac.jp" ^ path)
let session () = Session.create ~path:"/unused-fixture-session" ()
let add session cookie = Session.update_cookie ~now:1000. session ~origin cookie

let header session target =
  Session.cookie_header ~now:1001. session (Uri.of_string target)

let eq = Alcotest.(check string)

let expect_error operation =
  match Internal_error.protect operation with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected failure"

let test_scoping () =
  let jar = session () in
  add jar "sid=host; Path=/campusweb; Secure";
  eq "same origin and path" "sid=host"
    (header jar "https://twins.tsukuba.ac.jp/campusweb/portal.do");
  eq "path boundary" ""
    (header jar "https://twins.tsukuba.ac.jp/campusweb-other");
  eq "host-only" "" (header jar "https://other.twins.tsukuba.ac.jp/campusweb/");
  eq "unrelated host" "" (header jar "https://example.test/campusweb/");
  eq "secure" "" (header jar "http://twins.tsukuba.ac.jp/campusweb/");
  add jar "parent=ok; Domain=.tsukuba.ac.jp; Path=/";
  eq "university domain" "parent=ok" (header jar "https://other.tsukuba.ac.jp/");
  add jar "bad=foreign; Domain=example.test; Path=/";
  add jar "bad=public-suffix; Domain=ac.jp; Path=/";
  eq "invalid domains ignored" "" (header jar "https://example.test/");
  ()

let test_paths_and_empty () =
  let jar = session () in
  add jar "id=default";
  add jar "id=root; Path=/";
  add jar "id=narrow; Path=/campusweb/portal.do";
  eq "longest path first" "id=narrow; id=default; id=root"
    (Session.cookie_header ~now:1001. jar origin);
  add jar "id=; Path=/campusweb";
  eq "empty value is not deletion" "id=narrow; id=; id=root"
    (Session.cookie_header ~now:1001. jar origin);
  add jar "id=deleted; Path=/campusweb; Max-Age=-1";
  eq "delete only matching path" "id=narrow; id=root"
    (Session.cookie_header ~now:1001. jar origin)

let test_expiry () =
  let jar = session () in
  add jar "one=live; Max-Age=2; Expires=Thu, 01 Jan 1970 00:00:00 GMT";
  eq "max-age takes precedence" "one=live"
    (Session.cookie_header ~now:1001. jar origin);
  eq "expires as time passes" "" (Session.cookie_header ~now:1002. jar origin);
  add jar "one=live";
  add jar "one=gone; Expires=Thu, 01 Jan 1970 00:00:00 GMT";
  eq "expires deletion" "" (Session.cookie_header ~now:1001. jar origin);
  List.iter
    (fun date ->
      Alcotest.(check (option (float 0.001)))
        date (Some 784111777.) (Session.cookie_date date))
    [
      "Sun, 06 Nov 1994 08:49:37 GMT";
      "Sunday, 06-Nov-94 08:49:37 GMT";
      "Sun Nov 6 08:49:37 1994";
    ];
  Alcotest.(check (option (float 0.)))
    "invalid calendar date" None
    (Session.cookie_date "Fri, 30 Feb 2024 08:00:00 GMT")

let test_prefixes () =
  let jar = session () in
  List.iter (add jar)
    [
      "__Secure-bad=x";
      "__Host-bad=x; Secure; Path=/campusweb";
      "__Host-bad=x; Secure; Path=/; Domain=twins.tsukuba.ac.jp";
      "bad\r\nheader=x";
      "bad=x\r\nheader";
    ];
  eq "invalid prefixes and headers ignored" ""
    (Session.cookie_header ~now:1001. jar origin);
  add jar "__Host-good=x; Secure; Path=/";
  eq "valid host prefix" "__Host-good=x"
    (Session.cookie_header ~now:1001. jar origin)

let with_file operation =
  let path = Filename.temp_file "twins-cookie-fixture" ".json" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () -> operation path)

let read path =
  let ch = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in ch)
    (fun () -> really_input_string ch (in_channel_length ch))

let test_persistence () =
  with_file (fun path ->
      let jar = Session.create ~path () in
      Session.update_cookie jar ~origin
        "sid=fake-fixture; Path=/campusweb; Secure; Max-Age=3600";
      Session.save jar;
      Alcotest.(check int)
        "private permissions" 0o600
        ((Unix.stat path).Unix.st_perm land 0o777);
      let loaded = Session.load ~path () in
      eq "round trip" "sid=fake-fixture" (Session.cookie_header loaded origin);
      eq "scope preserved" "" (Session.cookie_header loaded (uri "/other"));
      let legacy = "# old fixture\nsid\tfake-fixture\n" in
      let ch = open_out path in
      output_string ch legacy;
      close_out ch;
      expect_error (fun () -> Session.load ~path ());
      (match Twins.status ~session_file:path () with
      | Ok status ->
          Alcotest.(check bool)
            "legacy status logged out" false status.logged_in
      | Error error -> Alcotest.fail (Error.to_string error));
      eq "legacy file retained byte for byte" legacy (read path);
      expect_error (fun () ->
          Session.authenticate ~path (fun pending ->
              Session.update_cookie pending ~origin
                "sid=failed-login; Path=/; Secure";
              failwith "fixture login rejected"));
      eq "failed authentication retains prior file" legacy (read path);
      Session.authenticate ~path (fun pending ->
          Session.update_cookie pending ~origin
            "sid=successful-login; Path=/; Secure");
      eq "successful authentication atomically replaces prior file"
        "sid=successful-login"
        (Session.cookie_header (Session.load ~path ()) origin))

let run_request ?body send =
  Lwt_main.run (Http_client.request_lwt ~send ?body (session ()) `POST origin 8)

let test_redirect_block () =
  List.iter
    (fun location ->
      let calls = ref 0 in
      let send ~headers:_ _ _ _ =
        incr calls;
        Lwt.return (307, Cohttp.Header.init_with "location" location, "")
      in
      expect_error (fun () -> run_request ~body:"password=fixture" send);
      Alcotest.(check int)
        "credential never replayed to blocked target" 1 !calls)
    [
      "https://example.test/";
      "http://twins.tsukuba.ac.jp/";
      "https://twins.tsukuba.ac.jp:444/";
      "https://name@twins.tsukuba.ac.jp/";
    ];
  List.iter
    (fun target ->
      expect_error (fun () -> Http_client.validate_uri (Uri.of_string target)))
    [ "file:///etc/passwd"; "https://twins.tsukuba.ac.jp.example.test/" ]

let test_redirect_replay () =
  let calls = ref [] in
  let send ~headers meth target body =
    calls :=
      (meth, Uri.path target, body, Cohttp.Header.get headers "cookie")
      :: !calls;
    if List.length !calls = 1 then
      Lwt.return
        ( 307,
          Cohttp.Header.of_list
            [
              ("location", "/other");
              ("set-cookie", "sid=scoped; Path=/campusweb; Secure");
            ],
          "" )
    else Lwt.return (200, Cohttp.Header.init (), "ok")
  in
  ignore (run_request ~body:"password=fixture" send);
  match !calls with
  | (`POST, "/other", Some "password=fixture", None) :: _ -> ()
  | _ ->
      Alcotest.fail
        "307 must replay body only to allowed origin with recalculated cookies"

let test_redirect_get () =
  let calls = ref 0 in
  let send ~headers meth _ body =
    incr calls;
    if !calls = 1 then
      Lwt.return
        (303, Cohttp.Header.init_with "location" "portal.do?page=main", "")
    else (
      Alcotest.(check bool) "303 becomes GET" true (meth = `GET);
      Alcotest.(check (option string)) "body removed" None body;
      Alcotest.(check (option string))
        "content type removed" None
        (Cohttp.Header.get headers "content-type");
      Lwt.return (200, Cohttp.Header.init (), "ok"))
  in
  ignore
    (Lwt_main.run
       (Http_client.request_lwt ~send ~body:"secret=fixture"
          ~extra_headers:
            (Cohttp.Header.init_with "content-type"
               "application/x-www-form-urlencoded")
          (session ()) `POST origin 8))

let test_bounds () =
  let calls = ref 0 in
  let send ~headers:_ _ _ _ =
    incr calls;
    Lwt.return (302, Cohttp.Header.init_with "location" "/campusweb/loop", "")
  in
  expect_error (fun () -> run_request send);
  Alcotest.(check int) "redirect cap" 9 !calls;
  let cancelled = ref false in
  expect_error (fun () ->
      Http_client.with_timeout 0.01 (fun () ->
          let promise = Lwt_unix.sleep 10. in
          Lwt.on_cancel promise (fun () -> cancelled := true);
          promise));
  Alcotest.(check bool) "timeout cancels request" true !cancelled

let () =
  Alcotest.run "TWINS transport security"
    [
      ( "cookies",
        [
          Alcotest.test_case "domain, host and transport scope" `Quick
            test_scoping;
          Alcotest.test_case "path matching and empty values" `Quick
            test_paths_and_empty;
          Alcotest.test_case "expiry and UTC dates" `Quick test_expiry;
          Alcotest.test_case "prefix and header validation" `Quick test_prefixes;
          Alcotest.test_case "private persistence and legacy status" `Quick
            test_persistence;
        ] );
      ( "HTTP",
        [
          Alcotest.test_case "blocked redirects" `Quick test_redirect_block;
          Alcotest.test_case "307 replay and scoped cookies" `Quick
            test_redirect_replay;
          Alcotest.test_case "303 strips body headers" `Quick test_redirect_get;
          Alcotest.test_case "redirect and timeout bounds" `Quick test_bounds;
        ] );
    ]
