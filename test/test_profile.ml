open Yojson.Safe.Util

let eq = Alcotest.(check string)
let private_text = "synthetic-secret-must-not-appear"

let target =
  Uri.of_string
    ("https://twins.tsukuba.ac.jp/campusweb/fixture?key=" ^ private_text)

let session () = Session.create ~path:("/unused/" ^ private_text) ()

let capture operation =
  let events = ref [] in
  let result =
    try
      Ok
        (Profile.run ~enabled:true
           ~emit:(fun json -> events := json :: !events)
           operation)
    with exn -> Error exn
  in
  Alcotest.(check int) "one profile event" 1 (List.length !events);
  let report = List.hd !events |> member "profile" in
  let raw = Yojson.Safe.to_string report in
  let contains needle =
    let rec scan index =
      index + String.length needle <= String.length raw
      && (String.sub raw index (String.length needle) = needle
         || scan (index + 1))
    in
    scan 0
  in
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        "no private fields or values" false (contains needle))
    [ private_text; "https://"; "cookie"; "uri"; "flowExecutionKey" ];
  let rec finite = function
    | `Float value ->
        Alcotest.(check bool)
          "finite nonnegative time" true
          (Float.is_finite value && value >= 0.)
    | `Assoc fields -> List.iter (fun (_, value) -> finite value) fields
    | `List values -> List.iter finite values
    | _ -> ()
  in
  finite report;
  Alcotest.(check bool) "profile context restored" false (Profile.enabled ());
  (result, report)

let test_opt_in () =
  let emitted = ref false in
  let result =
    Profile.run ~enabled:false
      ~emit:(fun _ -> emitted := true)
      (fun () ->
        Profile.measure Profile.Session_load (fun () ->
            Alcotest.(check bool) "disabled" false (Profile.enabled ());
            Profile.http_complete (Profile.start_http ()) ~bytes:23
              ~wire_bytes:23;
            "unchanged result"))
  in
  eq "value preserved" "unchanged result" result;
  Alcotest.(check bool) "no default diagnostic output" false !emitted

let test_stages () =
  let module_ = Profile.module_of_slug "spring-a" in
  let result, report =
    capture (fun () ->
        Profile.measure Profile.Session_load (fun () -> ());
        Profile.scope ?module_ Profile.Module_fetch (fun () ->
            Profile.measure Profile.Html_parse (fun () -> ()));
        Profile.measure Profile.Json_output (fun () -> {|{"snapshots":{}}|}))
  in
  (match result with
  | Ok value -> eq "stdout data unchanged" {|{"snapshots":{}}|} value
  | Error _ -> Alcotest.fail "unexpected failure");
  eq "success" "success" (report |> member "outcome" |> to_string);
  let stages = report |> member "stages" |> to_list in
  Alcotest.(check (list string))
    "nested stages recorded"
    [ "session_load"; "html_parse"; "module_fetch"; "json_output" ]
    (List.map (fun stage -> stage |> member "stage" |> to_string) stages);
  eq "module context inherited" "spring-a"
    (List.nth stages 1 |> member "module" |> to_string);
  Alcotest.(check int)
    "no requests" 0
    (report |> member "http" |> to_list |> List.length)

let test_redirect_hops () =
  let calls = ref 0 in
  let call ?body:_ ~headers:_ _ _ =
    incr calls;
    let headers =
      if !calls = 1 then
        Cohttp.Header.init_with "location" (Uri.to_string target)
      else Cohttp.Header.init_with "set-cookie" ("sid=" ^ private_text)
    in
    let status = if !calls = 1 then `Found else `OK in
    Lwt.return (Cohttp.Response.make ~status ~headers (), private_text)
  in
  let send ~headers meth uri body =
    Http_client.send_with ~call ~read_body:Lwt.return ~headers meth uri body
  in
  let result, report =
    capture (fun () ->
        Profile.scope Profile.Initial_flow (fun () ->
            Lwt_main.run
              (Http_client.request_lwt ~send (session ()) `GET target 8)))
  in
  (match result with
  | Ok response -> eq "body unchanged" private_text (Http_client.body response)
  | Error _ -> Alcotest.fail "unexpected request failure");
  let hops = report |> member "http" |> to_list in
  Alcotest.(check int) "every actual redirect hop recorded" 2 (List.length hops);
  Alcotest.(check (list int))
    "response statuses" [ 302; 200 ]
    (List.map (fun hop -> hop |> member "status" |> to_int) hops);
  Alcotest.(check (list int))
    "ordered indexes" [ 1; 2 ]
    (List.map (fun hop -> hop |> member "index" |> to_int) hops);
  List.iter
    (fun hop ->
      eq "logical stage" "initial_flow" (hop |> member "stage" |> to_string);
      Alcotest.(check int)
        "body byte count only"
        (String.length private_text)
        (hop |> member "bytes" |> to_int);
      Alcotest.(check int)
        "identity wire body byte count"
        (String.length private_text)
        (hop |> member "wireBytes" |> to_int);
      eq "hop succeeded" "success" (hop |> member "outcome" |> to_string))
    hops

let test_http_failure ~after_headers () =
  let call ?body:_ ~headers:_ _ _ =
    if after_headers then
      Lwt.return (Cohttp.Response.make ~status:`OK (), private_text)
    else Lwt.fail (Failure private_text)
  in
  let read_body _ = Lwt.fail (Failure private_text) in
  let result, report =
    capture (fun () ->
        Profile.scope ?module_:(Profile.module_of_slug "autumn-b")
          Profile.Module_fetch (fun () ->
            Lwt_main.run
              (Http_client.send_with ~call ~read_body
                 ~headers:(Cohttp.Header.init_with "cookie" private_text)
                 `GET target None)))
  in
  (match result with
  | Error (Failure message) ->
      eq "original error preserved" private_text message
  | _ -> Alcotest.fail "expected failure");
  eq "request failure" "failure" (report |> member "outcome" |> to_string);
  let hops = report |> member "http" |> to_list in
  Alcotest.(check int) "failed hop recorded once" 1 (List.length hops);
  let hop = List.hd hops in
  eq "hop failed" "failure" (hop |> member "outcome" |> to_string);
  eq "status known only after headers"
    (if after_headers then "200" else "null")
    (hop |> member "status" |> Yojson.Safe.to_string);
  eq "incomplete body has no byte count" "null"
    (hop |> member "bytes" |> Yojson.Safe.to_string);
  eq "incomplete body has no wire byte count" "null"
    (hop |> member "wireBytes" |> Yojson.Safe.to_string);
  Alcotest.(check bool)
    "body timing available only after headers" after_headers
    (member "bodyMs" hop <> `Null)

let test_initial_facts () =
  let _, report =
    capture (fun () ->
        let soup =
          Html.parse
            {|<input name="moduleCode" value="4"><input name="gakkiKbnCode" value="B">|}
        in
        Profile.initial_flow ~timetable_recognized:true
          ~selected_module:(Timetable_batch.selected_module soup))
  in
  eq "whitelisted initial module" "autumn-a"
    (report |> member "initialFlow" |> member "selectedModule" |> to_string);
  let _, unknown =
    capture (fun () ->
        let soup =
          Html.parse
            (Printf.sprintf
               {|<input name="moduleCode" value="%s"><input name="gakkiKbnCode" value="B">|}
               private_text)
        in
        Profile.initial_flow ~timetable_recognized:false
          ~selected_module:(Timetable_batch.selected_module soup))
  in
  eq "unknown control omitted" "null"
    (unknown |> member "initialFlow" |> member "selectedModule"
   |> Yojson.Safe.to_string);
  Alcotest.(check bool)
    "arbitrary module text rejected" true
    (Profile.module_of_slug private_text = None)

let test_failure_coherence () =
  let path = Filename.temp_file "twins-profile-fixture" ".session" in
  Fun.protect
    ~finally:(fun () -> Sys.remove path)
    (fun () ->
      let channel = open_out path in
      output_string channel private_text;
      close_out channel;
      let result, report =
        capture (fun () ->
            match Twins.timetable_all ~session_file:path () with
            | Ok _ -> Alcotest.fail "legacy fixture must fail locally"
            | Error error ->
                failwith (Error.to_safe_yojson error |> Yojson.Safe.to_string))
      in
      (match result with
      | Error (Failure json) ->
          eq "normal safe error remains separate"
            {|{"error":{"code":"protocol_error"}}|} json
      | _ -> Alcotest.fail "expected local error");
      eq "failed session stage" "session_load"
        (report |> member "stages" |> to_list |> List.hd |> member "stage"
       |> to_string);
      Alcotest.(check int)
        "no request on fixture failure" 0
        (report |> member "http" |> to_list |> List.length))

let () =
  Alcotest.run "TWINS opt-in profiling"
    [
      ( "profiling",
        [
          Alcotest.test_case "disabled preserves default behavior" `Quick
            test_opt_in;
          Alcotest.test_case "stages and success result" `Quick test_stages;
          Alcotest.test_case "each HTTP redirect hop without private data"
            `Quick test_redirect_hops;
          Alcotest.test_case "HTTP header failure" `Quick
            (test_http_failure ~after_headers:false);
          Alcotest.test_case "HTTP body failure" `Quick
            (test_http_failure ~after_headers:true);
          Alcotest.test_case "initial module facts use whitelist" `Quick
            test_initial_facts;
          Alcotest.test_case "failed session and JSON error coherence" `Quick
            test_failure_coherence;
        ] );
    ]
