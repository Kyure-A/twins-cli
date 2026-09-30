type phase = Initial | Search | Page

let phase_name = function
  | Initial -> "initial"
  | Search -> "search"
  | Page -> "page"

let max_entries = 128

type state = {
  started : float;
  mutable context : (phase * int) option;
  mutable stages : Yojson.Safe.t list;
  mutable pages : Yojson.Safe.t list;
  mutable stages_seen : int;
  mutable responses_seen : int;
}

let active = ref None
let enabled () = !active <> None

let milliseconds started =
  let elapsed = (Unix.gettimeofday () -. started) *. 1000. in
  if Float.is_finite elapsed then Float.max 0. elapsed else 0.

let outcome success = `String (if success then "success" else "failure")

let report state success =
  `Assoc
    [
      ( "noticeDiagnostics",
        `Assoc
          [
            ("version", `Int 1);
            ("outcome", outcome success);
            ("wallMs", `Float (milliseconds state.started));
            ("stagesStarted", `Int state.stages_seen);
            ("responsesChecked", `Int state.responses_seen);
            ( "truncated",
              `Bool
                (state.stages_seen > max_entries
                || state.responses_seen > max_entries) );
            ("stages", `List (List.rev state.stages));
            ("pages", `List (List.rev state.pages));
          ] );
    ]

let run ~enabled ~emit ~is_success operation =
  if not enabled then operation ()
  else
    let previous = !active in
    let state =
      {
        started = Unix.gettimeofday ();
        context = None;
        stages = [];
        pages = [];
        stages_seen = 0;
        responses_seen = 0;
      }
    in
    active := Some state;
    match operation () with
    | result ->
        active := previous;
        emit (report state (is_success result));
        result
    | exception exn ->
        active := previous;
        emit (report state false);
        raise exn

let with_phase phase ~page_index operation =
  match !active with
  | None -> operation ()
  | Some state -> (
      let previous = state.context in
      let page_index = max 1 page_index in
      let started = Unix.gettimeofday () in
      let responses_before = state.responses_seen in
      state.context <- Some (phase, page_index);
      state.stages_seen <- state.stages_seen + 1;
      let retain = state.stages_seen <= max_entries in
      let finish success =
        state.context <- previous;
        if retain then
          state.stages <-
            `Assoc
              [
                ("phase", `String (phase_name phase));
                ("pageIndex", `Int page_index);
                ("outcome", outcome success);
                ("wallMs", `Float (milliseconds started));
                ( "responsesChecked",
                  `Int (state.responses_seen - responses_before) );
              ]
            :: state.stages
      in
      match operation () with
      | result ->
          finish true;
          result
      | exception exn ->
          finish false;
          raise exn)

let has_table ~id ~headers soup =
  Html.table_by_id id soup <> None || Html.table_by_headers headers soup <> None

(* These are deliberately fixed literals. Presence is only a classification
   signal: a notice itself can mention the same words. Never emit matched text,
   surrounding text, or an inferred message extracted from the response. *)
let marker_flags body soup =
  let text = Soup.texts soup |> String.concat "\n" |> String.lowercase_ascii in
  let raw = String.lowercase_ascii body in
  let has needles =
    List.exists (fun needle -> Util.contains ~needle text) needles
  in
  let raw_has needles =
    List.exists (fun needle -> Util.contains ~needle raw) needles
  in
  [
    ("otherScreenMarker", `Bool (has [ "別の画面"; "他の画面" ]));
    ("pageTransitionMarker", `Bool (has [ "画面遷移" ]));
    ("backOrRefreshMarker", `Bool (has [ "戻る"; "更新ボタン"; "再読み込み" ]));
    ("sessionMarker", `Bool (has [ "セッション"; "session" ]));
    ("expiryMarker", `Bool (has [ "有効期限" ]));
    ("multipleMarker", `Bool (has [ "複数" ]));
    ("exclusiveMarker", `Bool (has [ "排他" ]));
    ("processingMarker", `Bool (has [ "処理中" ]));
    ( "sessionExpiredMarker",
      `Bool
        (has
           [
             "セッションがタイムアウト";
             "セッションタイムアウト";
             "セッションの有効期限";
             "セッションが切れ";
             "セッションが無効";
             "session has expired";
             "session expired";
             "session timeout";
             "session timed out";
           ]) );
    ( "invalidFlowMarker",
      `Bool
        (has
           [
             "could not restore flow execution";
             "flow execution key";
             "不正な画面遷移";
             "画面遷移が不正";
           ]
        || raw_has
             [
               "nosuchflowexecutionexception";
               "flowexecutionrestorationfailureexception";
               "flowexecutionrepositoryexception";
             ]) );
    ( "windowMarker",
      `Bool
        (has
           [
             "別のウィンドウ";
             "複数のウィンドウ";
             "複数ウィンドウ";
             "別ウィンドウ";
             "他のウィンドウ";
             "window id is invalid";
             "invalid window";
           ]) );
    ( "concurrentAccessMarker",
      `Bool
        (has
           [
             "同時に操作";
             "同時操作";
             "同時アクセス";
             "多重ログイン";
             "重複ログイン";
             "同時ログイン";
             "concurrent access";
             "concurrent request";
             "already logged in";
           ]) );
    ( "operationErrorMarker",
      `Bool
        (has
           [
             "不正な操作";
             "操作が無効";
             "予期しないエラー";
             "処理中にエラー";
             "システムエラー";
             "unexpected error";
             "invalid operation";
           ]) );
    ( "flowLockMarker",
      `Bool
        (raw_has
           [
             "locktimeoutexception";
             "conversationlockexception";
             "could not acquire conversation lock";
           ]) );
  ]

let flow_flags soup =
  let search_form = Html.form_by_name "keijiSearchForm" soup in
  let search_fields = Option.fold ~none:[] ~some:Html.form_fields search_form in
  let form_action = Option.bind search_form (Soup.attribute "action") in
  let action_has parameter =
    Option.fold ~none:false
      ~some:(fun action -> Html.query_param parameter action <> None)
      form_action
  in
  let page_key = Html.flow_key soup in
  let selected_kind =
    search_fields
    |> List.filter_map (fun (name, value) ->
        if name = "keijitype" then Some value else None)
    |> List.sort_uniq String.compare
    |> function
    | [ "1" ] -> `String "classes"
    | [ "3" ] -> `String "general"
    | _ -> `Null
  in
  let pager_keys =
    Soup.select "a[href]" soup |> Soup.to_list
    |> List.filter_map (fun anchor ->
        match Soup.attribute "href" anchor with
        | Some href when Html.query_param "_eventId_paging" href <> None ->
            Some (Html.query_param "_flowExecutionKey" href)
        | _ -> None)
  in
  let pager_matches =
    match (page_key, pager_keys) with
    | Some key, (_ :: _ as keys) when List.for_all Option.is_some keys ->
        `Bool (List.for_all (( = ) (Some key)) keys)
    | _ -> `Null
  in
  [
    ("pageHasFlowKey", `Bool (Option.is_some page_key));
    ("pagerFlowKeyMatchesPage", pager_matches);
    ("selectedKind", selected_kind);
    ( "searchFormHasFlowKeyField",
      `Bool (List.mem_assoc "_flowExecutionKey" search_fields) );
    ("searchFormActionHasFlowKey", `Bool (action_has "_flowExecutionKey"));
    ("searchFormActionHasFlowId", `Bool (action_has "_flowId"));
  ]

let record_response ?uri ~status ~body ~soup () =
  match !active with
  | None -> ()
  | Some state -> (
      match state.context with
      | None -> ()
      | Some (phase, page_index) ->
          state.responses_seen <- state.responses_seen + 1;
          if state.responses_seen <= max_entries then
            let facts =
              [
                ("phase", `String (phase_name phase));
                ("pageIndex", `Int page_index);
                ( "httpStatus",
                  if status >= 100 && status <= 599 then `Int status else `Null
                );
                ("bodyBytes", `Int (String.length body));
                ( "responseQueryHasFlowKey",
                  `Bool
                    (Option.fold ~none:false
                       ~some:(fun uri ->
                         Uri.get_query_param uri "_flowExecutionKey" <> None)
                       uri) );
                ( "responseQueryHasFlowId",
                  `Bool
                    (Option.fold ~none:false
                       ~some:(fun uri ->
                         Uri.get_query_param uri "_flowId" <> None)
                       uri) );
                ( "hasNoticeSearchForm",
                  `Bool (Html.form_by_name "keijiSearchForm" soup <> None) );
                ( "hasNoticeTable",
                  `Bool
                    (Html.table_by_headers [ "ジャンル"; "表題"; "掲示期間"; "掲載日時" ] soup
                    <> None) );
                ( "hasGradeTable",
                  `Bool
                    (has_table ~id:"auto-table-4"
                       ~headers:[ "No."; "年度"; "学期"; "科目区分"; "科目番号"; "科目名" ]
                       soup) );
                ( "hasTimetableTable",
                  `Bool
                    (has_table ~id:"auto-table-2-2"
                       ~headers:[ "月曜日"; "火曜日"; "水曜日"; "木曜日"; "金曜日" ]
                       soup) );
                ("hasLoginForm", `Bool (Html.is_login_page soup));
                ("hasAuthorizationError", `Bool (Html.is_auth_error soup));
              ]
              @ flow_flags soup @ marker_flags body soup
            in
            state.pages <- `Assoc facts :: state.pages)
