let unwrap = function
  | Ok value -> value
  | Error error -> Alcotest.fail (Error.to_string error)

let slugs =
  [
    "spring-a";
    "spring-b";
    "spring-c";
    "summer";
    "autumn-a";
    "autumn-b";
    "autumn-c";
    "spring-break";
  ]

let module_codes = [ "1"; "2"; "3"; "A"; "4"; "5"; "6"; "B" ]
let term_codes = [ "A"; "A"; "A"; "A"; "B"; "B"; "B"; "B" ]

let fixture index =
  let code = List.nth module_codes index in
  let term = List.nth term_codes index in
  let cell =
    if index = 3 then "未登録" else Printf.sprintf "FIX%d<br>Fixture course" index
  in
  Html.parse
    (Printf.sprintf
       {|<form><input name="_flowExecutionKey" value="e1s%d">
       <input name="moduleCode" value="%s"><input name="gakkiKbnCode" value="%s"></form>
       <table id="auto-table-2-2"><tr><th></th><th>月曜日</th></tr>
       <tr><th>1限</th><td>%s</td></tr></table>|}
       (index + 1) code term cell)

let flow_key page =
  match Html.flow_key page with
  | Some key -> key
  | None -> failwith "missing fixture flow key"

let test_traversal () =
  let starts = ref 0 in
  let calls = ref [] in
  let snapshots =
    Timetable_batch.collect
      ~start:(fun () ->
        incr starts;
        Html.parse {|<input name="_flowExecutionKey" value="e1s0">|})
      ~flow_key
      ~select:(fun ~key module_ ->
        let index = List.length !calls in
        Alcotest.(check string)
          "newest returned flow key"
          (Printf.sprintf "e1s%d" index)
          key;
        let slug = Twins.Module.to_string module_ in
        Alcotest.(check string) "traversal order" (List.nth slugs index) slug;
        calls := !calls @ [ slug ];
        fixture index)
      ~parse:(fun module_ page ->
        let index = List.length !calls - 1 in
        Timetable_batch.validate_selection
          ~module_code:(List.nth module_codes index)
          ~term_code:(List.nth term_codes index)
          page;
        Twins.parse_timetable module_ page |> unwrap)
      Twins.Module.all
  in
  Alcotest.(check int) "open flow only once" 1 !starts;
  Alcotest.(check (list string)) "all modules requested once" slugs !calls;
  let json = Twins.timetable_snapshots_to_yojson snapshots in
  let open Yojson.Safe.Util in
  let buckets = json |> member "snapshots" |> to_assoc in
  Alcotest.(check (list string))
    "complete explicit snapshot keys" slugs (List.map fst buckets);
  Alcotest.(check string)
    "empty module retained" "[]"
    (List.assoc "summer" buckets |> Yojson.Safe.to_string);
  List.iteri
    (fun index (module_, rows) ->
      if index <> 3 then
        match rows with
        | [ entry ] ->
            Alcotest.(check string)
              "selected module label"
              (Twins.Module.label module_)
              entry.Twins.module_label;
            Alcotest.(check string)
              "selected course"
              (Printf.sprintf "FIX%d" index)
              entry.code;
            Alcotest.(check string)
              "unchanged row JSON shape"
              (Printf.sprintf
                 {|{"module":"%s","day":"月曜日","period":"1限","code":"FIX%d","description":"FIX%d Fixture course","intensive":false}|}
                 (Twins.Module.label module_)
                 index index)
              (Twins.timetable_entry_to_yojson entry |> Yojson.Safe.to_string)
        | _ -> Alcotest.fail "expected one fixture row")
    snapshots

let expect_failure operation =
  match operation () with
  | exception _ -> ()
  | _ -> Alcotest.fail "expected failure without a partial result"

let test_failure ~during_parse () =
  let calls = ref 0 in
  let parsed = ref 0 in
  let emitted = ref false in
  expect_failure (fun () ->
      let snapshots =
        Timetable_batch.collect
          ~start:(fun () -> 0)
          ~flow_key:Fun.id
          ~select:(fun ~key _ ->
            incr calls;
            if (not during_parse) && !calls = 4 then
              failwith "fixture transport failure";
            key + 1)
          ~parse:(fun _ page ->
            incr parsed;
            if during_parse && page = 4 then failwith "fixture parser failure";
            [])
          Twins.Module.all
      in
      ignore (Twins.timetable_snapshots_to_yojson snapshots);
      emitted := true);
  Alcotest.(check int) "stop on first failing module" 4 !calls;
  Alcotest.(check int)
    "do not parse failed request"
    (if during_parse then 4 else 3)
    !parsed;
  Alcotest.(check bool) "no partial result emitted" false !emitted

let test_missing_key () =
  let calls = ref 0 in
  expect_failure (fun () ->
      Timetable_batch.collect
        ~start:(fun () ->
          Html.parse {|<input name="_flowExecutionKey" value="e1s0">|})
        ~flow_key
        ~select:(fun ~key:_ _ ->
          incr calls;
          Html.parse "<p>missing key</p>")
        ~parse:(fun _ _ -> [])
        Twins.Module.all);
  Alcotest.(check int) "never reuse initial key" 1 !calls

let test_selection () =
  let check html =
    Timetable_batch.validate_selection ~module_code:"2" ~term_code:"A"
      (Html.parse html)
  in
  check
    {|<input name="moduleCode" value="2"><input name="gakkiKbnCode" value="A">|};
  check
    {|<select name="moduleCode"><option value="1">A</option><option selected value="2">B</option></select>|};
  check
    {|<input type="radio" name="moduleCode" value="1"><input type="radio" name="moduleCode" value="2" checked>|};
  check {|<a href="?moduleCode=1">春A</a><a href="?moduleCode=3">春C</a>|};
  expect_failure (fun () -> check {|<input name="moduleCode" value="1">|});
  expect_failure (fun () -> check {|<input name="gakkiKbnCode" value="B">|});
  expect_failure (fun () ->
      check {|<select name="moduleCode"><option value="1">春A</option></select>|})

let test_query () =
  Alcotest.(check (list (pair string (list string))))
    "exact search query"
    [
      ("_flowExecutionKey", [ "e1s7" ]);
      ("_eventId", [ "search" ]);
      ("moduleCode", [ "6" ]);
      ("gakkiKbnCode", [ "B" ]);
    ]
    (Timetable_batch.search_query ~key:"e1s7" ~module_code:"6" ~term_code:"B")

let test_safe_errors () =
  let private_text = "synthetic-secret-not-for-output" in
  let cases =
    Error.
      [
        (Authentication_required, "authentication_required");
        (Invalid_argument private_text, "invalid_argument");
        (Protocol_error private_text, "protocol_error");
        (Timeout private_text, "timeout");
        (Io_error private_text, "io_error");
        (Unexpected_error private_text, "unexpected_error");
        (Cancelled private_text, "cancelled");
      ]
  in
  List.iter
    (fun (error, code) ->
      Alcotest.(check string)
        "error includes only stable code"
        (Printf.sprintf {|{"error":{"code":"%s"}}|} code)
        (Error.to_safe_yojson error |> Yojson.Safe.to_string))
    cases;
  Alcotest.(check string)
    "HTTP error strips URI and includes status"
    {|{"error":{"code":"http_error","httpStatus":503}}|}
    (Error.to_safe_yojson
       (Error.Http_error
          {
            status = 503;
            uri =
              Uri.of_string ("https://example.invalid/?session=" ^ private_text);
          })
    |> Yojson.Safe.to_string)

let () =
  Alcotest.run "TWINS timetable batch"
    [
      ( "batch",
        [
          Alcotest.test_case "all modules carry newest flow key and serialize"
            `Quick test_traversal;
          Alcotest.test_case "transport failure emits no partial batch" `Quick
            (test_failure ~during_parse:false);
          Alcotest.test_case "parse failure emits no partial batch" `Quick
            (test_failure ~during_parse:true);
          Alcotest.test_case "missing returned key aborts" `Quick
            test_missing_key;
          Alcotest.test_case "active module validation" `Quick test_selection;
          Alcotest.test_case "search query" `Quick test_query;
          Alcotest.test_case "sanitized JSON errors" `Quick test_safe_errors;
        ] );
    ]
