let capture ?(enabled = true) operation =
  let reports = ref [] in
  let value =
    Notice_diagnostics.run ~enabled
      ~emit:(fun report -> reports := report :: !reports)
      ~is_success:Result.is_ok operation
  in
  (value, List.rev !reports)

let response ?uri ?(status = 200) body =
  Notice_diagnostics.record_response ?uri ~status ~body ~soup:(Html.parse body)
    ()

let report reports =
  match reports with
  | [ `Assoc [ ("noticeDiagnostics", report) ] ] -> report
  | _ -> Alcotest.fail "expected one diagnostic report"

let field name = function
  | `Assoc pairs -> List.assoc name pairs
  | _ -> Alcotest.fail "expected object"

let first_page reports =
  match field "pages" (report reports) with
  | `List (page :: _) -> page
  | _ -> Alcotest.fail "expected page"

let bool name expected page =
  Alcotest.check Alcotest.bool name expected
    (field name page |> Yojson.Safe.Util.to_bool)

let test_disabled () =
  let _, reports =
    capture ~enabled:false (fun () ->
        Notice_diagnostics.with_phase Initial ~page_index:1 (fun () ->
            response "<html>private</html>");
        Ok ())
  in
  Alcotest.check Alcotest.int "no report" 0 (List.length reports)

let test_classification_and_privacy () =
  let private_values =
    [
      "secret-cookie-value";
      "private-flow-key";
      "private-course-name";
      "private.example";
    ]
  in
  let body =
    "<html><title>private-course-name</title>"
    ^ "<form name='keijiSearchForm'><input name='_flowExecutionKey' \
       value='private-flow-key'></form>"
    ^ "<a \
       href='https://private.example/?cookie=secret-cookie-value'>private-course-name</a>"
    ^ "<table><tr><th>ジャンル</th><th>表題</th><th>掲示期間</th><th>掲載日時</th></tr>"
    ^ "<tr><td>private-course-name</td></tr></table></html>"
  in
  let _, reports =
    capture (fun () ->
        Notice_diagnostics.with_phase Search ~page_index:1 (fun () ->
            response
              ~uri:
                (Uri.of_string
                   "https://private.example/?_flowExecutionKey=private-flow-key&_flowId=private-flow")
              body);
        Ok ())
  in
  let page = first_page reports in
  bool "responseQueryHasFlowKey" true page;
  bool "responseQueryHasFlowId" true page;
  bool "hasNoticeSearchForm" true page;
  bool "hasNoticeTable" true page;
  bool "hasGradeTable" false page;
  bool "hasTimetableTable" false page;
  bool "hasLoginForm" false page;
  bool "invalidFlowMarker" false page;
  Alcotest.check Alcotest.int "body byte length" (String.length body)
    (field "bodyBytes" page |> Yojson.Safe.Util.to_int);
  let rec check_strings = function
    | `String value ->
        Alcotest.check Alcotest.bool "every string value is allowlisted" true
          (List.mem value
             [
               "initial";
               "search";
               "page";
               "success";
               "failure";
               "classes";
               "general";
             ])
    | `Assoc fields -> List.iter (fun (_, value) -> check_strings value) fields
    | `List values -> List.iter check_strings values
    | _ -> ()
  in
  check_strings (`List reports);
  let rendered = Yojson.Safe.to_string (`List reports) in
  List.iter
    (fun private_value ->
      let contains =
        let n = String.length private_value in
        let rec check i =
          i + n <= String.length rendered
          && (String.sub rendered i n = private_value || check (i + 1))
        in
        check 0
      in
      Alcotest.check Alcotest.bool "private string absent" false contains)
    private_values

let test_flow_routing () =
  let check body =
    let _, reports =
      capture (fun () ->
          Notice_diagnostics.with_phase Initial ~page_index:1 (fun () ->
              response body);
          Ok ())
    in
    first_page reports
  in
  let action_only =
    check
      "<form name='keijiSearchForm' \
       action='campussquare.do?_flowExecutionKey=private-action-key&amp;_flowId=private-flow'><select \
       name='keijitype'><option value='1'>classes</option><option value='3' \
       selected>general</option></select></form>"
  in
  bool "searchFormHasFlowKeyField" false action_only;
  bool "searchFormActionHasFlowKey" true action_only;
  bool "searchFormActionHasFlowId" true action_only;
  bool "pageHasFlowKey" false action_only;
  Alcotest.check Alcotest.string "selected kind allowlisted" "general"
    (field "selectedKind" action_only |> Yojson.Safe.Util.to_string);
  let hidden_and_pager =
    check
      "<form name='keijiSearchForm'><input name='_flowExecutionKey' \
       value='private-hidden-key'><input name='keijitype' value='1' \
       type='radio' checked><input name='keijitype' value='3' \
       type='radio'></form><a \
       href='campussquare.do?_eventId_paging=1&amp;_flowExecutionKey=private-hidden-key'>Next</a>"
  in
  bool "searchFormHasFlowKeyField" true hidden_and_pager;
  bool "searchFormActionHasFlowKey" false hidden_and_pager;
  bool "pageHasFlowKey" true hidden_and_pager;
  bool "pagerFlowKeyMatchesPage" true hidden_and_pager;
  let mismatch =
    check
      "<input name='_flowExecutionKey' value='private-hidden-key'><a \
       href='campussquare.do?_eventId_paging=1&amp;_flowExecutionKey=other-private-key'>Next</a>"
  in
  bool "pagerFlowKeyMatchesPage" false mismatch;
  let unknown =
    check
      "<form name='keijiSearchForm'><input name='keijitype' \
       value='private-unknown-kind'></form>"
  in
  Alcotest.check Alcotest.bool "unknown kind is null" true
    (field "selectedKind" unknown = `Null);
  Alcotest.check Alcotest.bool "missing pager is null" true
    (field "pagerFlowKeyMatchesPage" unknown = `Null)

let test_error_markers () =
  let _, reports =
    capture (fun () ->
        Notice_diagnostics.with_phase Page ~page_index:3 (fun () ->
            response ~status:500
              "<form \
               id='authorizationError'></form><p>セッションがタイムアウトしました。</p><p>別のウィンドウで同時操作 \
               不正な操作</p><pre>NoSuchFlowExecutionException \
               LockTimeoutException</pre>");
        Error ())
  in
  let page = first_page reports in
  List.iter
    (fun name -> bool name true page)
    [
      "hasAuthorizationError";
      "sessionExpiredMarker";
      "invalidFlowMarker";
      "windowMarker";
      "concurrentAccessMarker";
      "operationErrorMarker";
      "flowLockMarker";
    ];
  Alcotest.check Alcotest.string "failed result" "failure"
    (field "outcome" (report reports) |> Yojson.Safe.Util.to_string);
  Alcotest.check Alcotest.int "page number" 3
    (field "pageIndex" page |> Yojson.Safe.Util.to_int)

let test_exception_and_restoration () =
  let reports = ref [] in
  (try
     Notice_diagnostics.run ~enabled:true
       ~emit:(fun report -> reports := report :: !reports)
       ~is_success:(fun () -> true)
       (fun () ->
         Notice_diagnostics.with_phase Initial ~page_index:1 (fun () ->
             response "<input name='userName'><input name='password'>";
             failwith "private-exception-value"))
   with Failure _ -> ());
  bool "hasLoginForm" true (first_page !reports);
  Alcotest.check Alcotest.string "exception failed" "failure"
    (field "outcome" (report !reports) |> Yojson.Safe.Util.to_string);
  response "outside scope";
  let _, next = capture (fun () -> Ok ()) in
  Alcotest.check Alcotest.int "state restored" 0
    (field "responsesChecked" (report next) |> Yojson.Safe.Util.to_int)

let test_bounded () =
  let _, reports =
    capture (fun () ->
        for page_index = 1 to 150 do
          Notice_diagnostics.with_phase Page ~page_index (fun () -> response "")
        done;
        Ok ())
  in
  let report = report reports in
  bool "truncated" true report;
  Alcotest.check Alcotest.int "bounded pages" 128
    (field "pages" report |> Yojson.Safe.Util.to_list |> List.length);
  Alcotest.check Alcotest.int "bounded stages" 128
    (field "stages" report |> Yojson.Safe.Util.to_list |> List.length);
  Alcotest.check Alcotest.int "all responses counted" 150
    (field "responsesChecked" report |> Yojson.Safe.Util.to_int)

let test_foreign_tables () =
  let _, reports =
    capture (fun () ->
        Notice_diagnostics.with_phase Search ~page_index:1 (fun () ->
            response
              "<table id='auto-table-4'></table><table \
               id='auto-table-2-2'></table>");
        Ok ())
  in
  let page = first_page reports in
  bool "hasGradeTable" true page;
  bool "hasTimetableTable" true page;
  bool "hasNoticeTable" false page

let () =
  Alcotest.run "notice diagnostics"
    [
      ( "safe report",
        [
          Alcotest.test_case "disabled" `Quick test_disabled;
          Alcotest.test_case "classification and privacy" `Quick
            test_classification_and_privacy;
          Alcotest.test_case "flow routing classifications" `Quick
            test_flow_routing;
          Alcotest.test_case "fixed error markers" `Quick test_error_markers;
          Alcotest.test_case "exception and state restoration" `Quick
            test_exception_and_restoration;
          Alcotest.test_case "bounded report" `Quick test_bounded;
          Alcotest.test_case "other screen tables" `Quick test_foreign_tables;
        ] );
    ]
