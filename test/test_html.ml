let parse value = Html.parse value

let test_portal_hash () =
  let soup =
    parse
      {|<html><body><form><input name="userName"><input name="password"></form>
        <script>var portalConf = { 'rwfHash' : 'token-123',
        'x': 1 };</script></body></html>|}
  in
  Alcotest.(check (option string)) "hash" (Some "token-123")
    (Html.portal_hash soup);
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
  let form = Option.get (Html.form_by_name "InputForm" soup) in
  let fields = Html.form_fields form in
  Alcotest.(check (option string)) "hidden" (Some "e1s2")
    (List.assoc_opt "_flowExecutionKey" fields);
  Alcotest.(check (option string)) "selected" (Some "b")
    (List.assoc_opt "choice" fields);
  Alcotest.(check (option string)) "unchecked omitted" None
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
      Alcotest.failf "expected one registration, got %d" (List.length registrations)

let test_grades () =
  let soup =
    parse
      {|<table id="auto-table-4"><tbody>
          <tr><th>No.</th><th>年度</th></tr>
          <tr><td>1</td><td>2025</td><td>春</td><td>専門</td><td>ABC123</td><td>Test Course</td><td>Teacher</td><td>2.0</td><td>A</td><td></td><td>90</td><td>A</td></tr>
        </tbody></table>|}
  in
  match Twins.parse_grades soup with
  | [ grade ] ->
      Alcotest.(check string) "grade code" "ABC123" grade.code;
      Alcotest.(check string) "score" "90" grade.score
  | grades -> Alcotest.failf "expected one grade, got %d" (List.length grades)

let test_timetable () =
  let soup =
    parse
      {|<table id="auto-table-2-2"><tbody>
          <tr><th></th><th>月</th><th>火</th></tr>
          <tr><th>1</th><td>ABC123<br>Test Course</td><td>未登録</td></tr>
        </tbody></table>|}
  in
  let module_code = Twins.module_of_slug "autumn-a" in
  match Twins.parse_timetable module_code soup with
  | [ entry ] ->
      Alcotest.(check string) "module" "秋A" entry.module_label;
      Alcotest.(check string) "day" "月" entry.day;
      Alcotest.(check string) "code" "ABC123" entry.code
  | entries -> Alcotest.failf "expected one entry, got %d" (List.length entries)

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
        ] );
    ]
