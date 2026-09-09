let parse = Soup.parse

let headers rank =
  "<thead><tr><th>" ^ rank
  ^ "<br>順位</th><th>科目番号</th><th>科目名</th><th>主担当教員</th><th>曜時限</th><th>定員</th><th>第1希望<br>人数</th></tr></thead>"

let row rank code name =
  "<tr><td>" ^ rank ^ "</td><td>" ^ code ^ "</td><td>" ^ name
  ^ "</td><td>Teacher</td><td>他0</td><td>100</td><td>13</td></tr>"

let input ranks =
  let fields i rank code =
    Printf.sprintf
      "<input name='yusenJuni_%d' value='%s'><input type='hidden' \
       name='jikanwariCode_%d' value='%s'><input type='hidden' name='nendo_%d' \
       value='2026'><input type='hidden' name='jikanwariShozokuCode_%d' \
       value='1F'>"
      i rank i code i i
  in
  parse
    ("<form id='rishuYobiEntryForm' name='InputForm'><input \
      name='_flowExecutionKey' value='test'><input name='kamokuCnt' \
      value='2'><table>" ^ headers "希望" ^ "<tbody>"
    ^ row (fields 1 (fst ranks) "TEST001") "TEST001" "First"
    ^ row (fields 2 (snd ranks) "TEST002") "TEST002" "Second"
    ^ "</tbody></table></form>")

let result rows =
  "<table>" ^ headers "優先" ^ "<tbody>" ^ rows ^ "</tbody></table>"

let inquiry rows = parse ("<article>＜事前登録希望情報＞" ^ result rows ^ "</article>")

let confirmation rows =
  parse
    ("<article>登録は完了していません<form id='rishuYobiEntryForm' name='InputForm'>"
   ^ result rows
   ^ "<input type='button' onclick='insertSubmit()'></form></article>")

let expect_error f =
  match f () with
  | exception _ -> ()
  | _ -> Alcotest.fail "expected fail-closed behavior"

let test_parsing () =
  let courses = Pre_registration.input_courses (input ("", "2")) in
  Alcotest.(check int) "course count" 2 (List.length courses);
  let first = List.hd courses in
  Alcotest.(check (option string))
    "rank field" (Some "yusenJuni_1") first.rank_field;
  Alcotest.(check (option int)) "blank" None first.rank;
  let _, field, expected =
    Pre_registration.prepare ~code:"TEST001" ~rank:1 courses
  in
  Alcotest.(check string) "target field" "yusenJuni_1" field;
  Alcotest.(check (list (pair string int)))
    "preserved other rank"
    [ ("TEST001", 1); ("TEST002", 2) ]
    (Pre_registration.preferences expected);
  expect_error (fun () ->
      Pre_registration.prepare ~code:"MISSING" ~rank:1 courses);
  expect_error (fun () ->
      Pre_registration.prepare ~code:"TEST001" ~rank:2 courses);
  expect_error (fun () ->
      Pre_registration.prepare ~code:"TEST001" ~rank:3 courses);
  expect_error (fun () ->
      Pre_registration.input_courses (parse "<form name='InputForm'></form>"));
  expect_error (fun () ->
      Pre_registration.inquiry (parse "<h1>Maintenance</h1>"));
  Alcotest.(check int)
    "explicit empty inquiry" 0
    (List.length (Pre_registration.inquiry (inquiry "")))

let test_links () =
  let page =
    parse
      "<table><tr><td><a \
       href='campussquare.do?_eventId=input&amp;yobiKamokuKubunCode=04066&amp;_flowExecutionKey=test'>秋A随時(TEST001)</a></td><td>未登録</td></tr></table>"
  in
  let links =
    Pre_registration.links ~event:"input" ~key:"yobiKamokuKubunCode" page
  in
  let link = Pre_registration.find_link "04066" links in
  Alcotest.(check string) "status" "未登録" link.status;
  Alcotest.(check string)
    "name lookup" "04066" (Pre_registration.find_link "秋A随時(TEST001)" links).id;
  let json = Pre_registration.link_to_yojson link |> Yojson.Safe.to_string in
  Alcotest.(check bool) "execution key omitted" false (String.contains json '?');
  expect_error (fun () -> Pre_registration.find_link "04067" links)

let test_flow ~mismatch ~already () =
  let inserted = ref false in
  let posts = ref [] in
  let gets = ref [] in
  let old_rank = if already then "1" else "" in
  let old_rows =
    (if already then row "1" "TEST001" "First" else "")
    ^ row "2" "TEST002" "Second"
  in
  let new_rows = row "1" "TEST001" "First" ^ row "2" "TEST002" "Second" in
  let open_flow = function
    | "RSW0001400-flow" -> inquiry (if !inserted then new_rows else old_rows)
    | "RSW0001300-flow" ->
        parse
          "<a href='category?_eventId=inputCategory&amp;categorycd=04'>秋A開始</a>"
    | _ -> Alcotest.fail "unexpected flow"
  in
  let get href =
    gets := href :: !gets;
    if String.starts_with ~prefix:"category?" href then
      parse
        "<a \
         href='group?_eventId=input&amp;yobiKamokuKubunCode=04066'>秋A随時(TEST001)</a>"
    else if String.starts_with ~prefix:"group?" href then input (old_rank, "2")
    else Alcotest.fail "unexpected navigation"
  in
  let post _ event fields =
    posts := event :: !posts;
    match event with
    | "check" ->
        Alcotest.(check (list (pair string string)))
          "only requested rank is replaced"
          [ ("yusenJuni_1", "1") ]
          fields;
        confirmation (if mismatch then row "1" "WRONG" "Wrong" else new_rows)
    | "insert" ->
        inserted := true;
        parse "<h1>groups</h1>"
    | _ -> Alcotest.fail "unexpected mutation"
  in
  let run () =
    Pre_registration.add ~open_flow ~get ~post ~category:"秋A開始" ~group:"04066"
      ~code:"TEST001" ~rank:1
  in
  if mismatch then (
    expect_error run;
    Alcotest.(check bool)
      "never inserts mismatched confirmation" false !inserted)
  else
    let saved = run () in
    Alcotest.(check (option int))
      "fresh inquiry verifies rank" (Some 1) saved.rank;
    Alcotest.(check (list string))
      "two-phase mutation, or no-op when already saved"
      (if already then [] else [ "insert"; "check" ])
      !posts;
    Alcotest.(check int) "category and group navigation" 2 (List.length !gets)

let test_verify () =
  let before =
    Pre_registration.inquiry (inquiry (row "2" "TEST002" "Second"))
  in
  let unchanged =
    Pre_registration.inquiry
      (inquiry (row "1" "TEST001" "First" ^ row "2" "TEST002" "Second"))
  in
  ignore (Pre_registration.verify ~before ~code:"TEST001" ~rank:1 unchanged);
  expect_error (fun () ->
      Pre_registration.verify ~before ~code:"TEST001" ~rank:1 before);
  let lost = Pre_registration.inquiry (inquiry (row "1" "TEST001" "First")) in
  expect_error (fun () ->
      Pre_registration.verify ~before ~code:"TEST001" ~rank:1 lost)

let fixture name =
  let ch = open_in ("fixtures/" ^ name ^ ".html") in
  let text =
    Fun.protect
      ~finally:(fun () -> close_in ch)
      (fun () -> really_input_string ch (in_channel_length ch))
  in
  parse text

let test_browser_markup () =
  let courses = Pre_registration.input_courses (fixture "input") in
  Alcotest.(check int) "observed browser form" 1 (List.length courses);
  let _, _, expected =
    Pre_registration.prepare ~code:"TEST001" ~rank:1 courses
  in
  Pre_registration.check_confirmation expected (fixture "confirm")

let () =
  Alcotest.run "TWINS pre-registration"
    [
      ( "pre-registration",
        [
          Alcotest.test_case "sanitized browser markup" `Quick
            test_browser_markup;
          Alcotest.test_case "input validation and preservation" `Quick
            test_parsing;
          Alcotest.test_case "observed links" `Quick test_links;
          Alcotest.test_case "full two-phase flow" `Quick
            (test_flow ~mismatch:false ~already:false);
          Alcotest.test_case "mismatched confirmation" `Quick
            (test_flow ~mismatch:true ~already:false);
          Alcotest.test_case "already registered is a verified no-op" `Quick
            (test_flow ~mismatch:false ~already:true);
          Alcotest.test_case "fresh inquiry and unchanged other choices" `Quick
            test_verify;
        ] );
    ]
