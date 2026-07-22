let parse = Soup.parse

let test_portal_hash () =
  let soup =
    parse
      {|<html><body><form><input name="userName"><input name="password"></form>
        <script>var portalConf = { 'rwfHash' : 'token-123',
        'x': 1 };</script></body></html>|}
  in
  Alcotest.(check (option string))
    "hash" (Some "token-123") (Html.portal_hash soup);
  Alcotest.(check bool) "login page" true (Html.is_login_page soup)

let test_auth_error () =
  let soup =
    parse
      {|<html><body><h1>認証エラー</h1>
        <form name="authorizationError"></form></body></html>|}
  in
  Alcotest.(check bool) "authorization error" true (Html.is_auth_error soup)

let test_form_fields () =
  let soup =
    parse
      {|<form name="InputForm">
          <input type="hidden" name="_flowExecutionKey" value="e1s2">
          <input name="text" value="old">
          <input type="checkbox" name="on" value="yes" checked>
          <input type="checkbox" name="off" value="no">
          <select name="choice"><option value="a">A</option><option value="b" selected>B</option></select>
        </form>|}
  in
  let form =
    match Html.form_by_name "InputForm" soup with
    | Some form -> form
    | None -> Alcotest.fail "expected InputForm"
  in
  let fields = Html.form_fields form in
  Alcotest.(check (option string))
    "hidden" (Some "e1s2")
    (List.assoc_opt "_flowExecutionKey" fields);
  Alcotest.(check (option string))
    "selected" (Some "b")
    (List.assoc_opt "choice" fields);
  Alcotest.(check (option string))
    "unchecked omitted" None
    (List.assoc_opt "off" fields)

let test_registrations () =
  let soup =
    parse
      {|<table><tr><td><a onclick="DeleteCallA('2026','26','ABC123','1','2')">ABC123 Course</a></td></tr></table>|}
  in
  match Html.registrations soup with
  | [ registration ] ->
      Alcotest.(check string) "course code" "ABC123" registration.code;
      Alcotest.(check string) "day" "1" registration.day;
      Alcotest.(check string) "period" "2" registration.period
  | registrations ->
      Alcotest.failf "expected one registration, got %d"
        (List.length registrations)

let test_grades () =
  let soup =
    parse
      {|<table id="auto-table-4"><tbody>
          <tr><th>No.</th><th>年度</th></tr>
          <tr><td>1</td><td>2025</td><td>春</td><td>専門</td><td>ABC123</td><td>Test Course</td><td>Teacher</td><td>2.0</td><td>A</td><td></td><td>90</td><td>A</td></tr>
        </tbody></table>|}
  in
  match Twins.parse_grades soup with
  | Error error -> Alcotest.fail (Error.to_string error)
  | Ok [ grade ] ->
      Alcotest.(check string) "grade code" "ABC123" grade.code;
      Alcotest.(check string) "score" "90" grade.score;
      Alcotest.(check string)
        "JSON contract"
        {|{"year":"2025","term":"春","category":"専門","code":"ABC123","name":"Test Course","instructor":"Teacher","credits":"2.0","spring":"A","autumn":"","score":"90","total":"A"}|}
        (Twins.grade_to_yojson grade |> Yojson.Safe.to_string)
  | Ok grades ->
      Alcotest.failf "expected one grade, got %d" (List.length grades)

let test_timetable () =
  let soup =
    parse
      {|<table id="auto-table-2-2"><tbody>
          <tr><th></th><th>月</th><th>火</th></tr>
          <tr><th>1</th><td>ABC123<br>Test Course</td><td>未登録</td></tr>
        </tbody></table>|}
  in
  let module_ =
    match Twins.Module.of_string "autumn-a" with
    | Ok module_ -> module_
    | Error error -> Alcotest.fail (Error.to_string error)
  in
  match Twins.parse_timetable module_ soup with
  | Error error -> Alcotest.fail (Error.to_string error)
  | Ok [ entry ] ->
      Alcotest.(check string) "module" "秋A" entry.module_label;
      Alcotest.(check string) "day" "月" entry.day;
      Alcotest.(check string) "code" "ABC123" entry.code
  | Ok entries ->
      Alcotest.failf "expected one entry, got %d" (List.length entries)

let check_invalid label = function
  | Error (Error.Invalid_argument _) -> ()
  | Error error ->
      Alcotest.failf "%s: expected Invalid_argument, got %s" label
        (Error.to_string error)
  | Ok _ -> Alcotest.failf "%s: expected an error" label

let test_domain_types () =
  List.iter
    (fun module_ ->
      let encoded = Twins.Module.to_string module_ in
      match Twins.Module.of_string encoded with
      | Ok decoded ->
          Alcotest.(check string)
            "module round trip" encoded
            (Twins.Module.to_string decoded)
      | Error error -> Alcotest.fail (Error.to_string error))
    Twins.Module.all;
  List.iter
    (fun kind ->
      let encoded = Twins.Notice_kind.to_string kind in
      match Twins.Notice_kind.of_string encoded with
      | Ok decoded ->
          Alcotest.(check string)
            "notice kind round trip" encoded
            (Twins.Notice_kind.to_string decoded)
      | Error error -> Alcotest.fail (Error.to_string error))
    Twins.Notice_kind.all;
  Twins.Module.of_string "winter-z" |> check_invalid "module";
  Twins.Notice_kind.of_string "administrative" |> check_invalid "notice kind";
  Twins.Day.of_int 0 |> check_invalid "day below bound";
  Twins.Day.of_int 8 |> check_invalid "day above bound";
  Twins.Period.of_int 0 |> check_invalid "period below bound";
  Twins.Period.of_int 10 |> check_invalid "period above bound";
  (match Twins.Day.of_int 1 with
  | Ok day -> Alcotest.(check int) "first day" 1 (Twins.Day.to_int day)
  | Error error -> Alcotest.fail (Error.to_string error));
  (match Twins.Day.of_int 7 with
  | Ok day -> Alcotest.(check int) "last day" 7 (Twins.Day.to_int day)
  | Error error -> Alcotest.fail (Error.to_string error));
  (match Twins.Period.of_int 1 with
  | Ok period ->
      Alcotest.(check int) "first period" 1 (Twins.Period.to_int period)
  | Error error -> Alcotest.fail (Error.to_string error));
  (match Twins.Period.of_int 9 with
  | Ok period ->
      Alcotest.(check int) "last period" 9 (Twins.Period.to_int period)
  | Error error -> Alcotest.fail (Error.to_string error));
  Twins.Date.of_string "2025-02-29" |> check_invalid "non-leap date";
  match Twins.Date.of_string "2024-02-29" with
  | Ok date ->
      Alcotest.(check string)
        "leap date" "2024-02-29"
        (Twins.Date.to_string date)
  | Error error -> Alcotest.fail (Error.to_string error)

let test_structured_errors () =
  let uri = Uri.of_string "https://example.test/failure" in
  let error = Error.Http_error { status = 503; uri } in
  Alcotest.(check string)
    "HTTP error rendering"
    "TWINS returned HTTP 503 for https://example.test/failure"
    (Error.to_string error);
  (match Error.of_exn (Failure "TLS handshake failed") with
  | Some (Error.Unexpected_error message) ->
      Alcotest.(check bool) "failure translated" true (String.length message > 0)
  | Some error -> Alcotest.fail (Error.to_string error)
  | None -> Alcotest.fail "expected a translated failure");
  (match Error.of_exn (Invalid_argument "malformed URI") with
  | Some (Error.Unexpected_error _) -> ()
  | Some error -> Alcotest.fail (Error.to_string error)
  | None -> Alcotest.fail "expected a translated invalid argument");
  Alcotest.(check bool)
    "fatal exception preserved" true
    (Error.of_exn Out_of_memory = None);
  let missing_table = Twins.parse_grades (parse "<html></html>") in
  (match missing_table with
  | Error (Error.Protocol_error _) -> ()
  | Error error -> Alcotest.fail (Error.to_string error)
  | Ok _ -> Alcotest.fail "expected a protocol error");
  (match Twins.status ~session_file:"/" () with
  | Error (Error.Io_error _) -> ()
  | Error error -> Alcotest.fail (Error.to_string error)
  | Ok _ -> Alcotest.fail "expected an I/O error");
  let classes =
    match Twins.Notice_kind.of_string "classes" with
    | Ok kind -> kind
    | Error error -> Alcotest.fail (Error.to_string error)
  in
  match Twins.notices ~kind:classes ~unread:false ~title:"" ~limit:(-1) () with
  | Error (Error.Invalid_argument _) -> ()
  | Error error -> Alcotest.fail (Error.to_string error)
  | Ok _ -> Alcotest.fail "expected an invalid limit error"

let () =
  Alcotest.run "TWINS HTML"
    [
      ( "parsing",
        [
          Alcotest.test_case "portal hash" `Quick test_portal_hash;
          Alcotest.test_case "auth error" `Quick test_auth_error;
          Alcotest.test_case "form fields" `Quick test_form_fields;
          Alcotest.test_case "registrations" `Quick test_registrations;
          Alcotest.test_case "grades" `Quick test_grades;
          Alcotest.test_case "timetable" `Quick test_timetable;
          Alcotest.test_case "domain types" `Quick test_domain_types;
          Alcotest.test_case "structured errors" `Quick test_structured_errors;
        ] );
    ]
