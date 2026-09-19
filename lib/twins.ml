type page = { response : Http_client.response; soup : Soup.soup Soup.node }

let host = "twins.tsukuba.ac.jp"
let campus_path = "/campusweb/"

let make_uri ?(query = []) path =
  Uri.make ~scheme:"https" ~host ~path:(campus_path ^ path) ~query ()

let absolute_uri base href =
  let scheme = Uri.scheme base |> Option.value ~default:"https" in
  Uri.resolve scheme base (Uri.of_string href)

let checked_page ?session response =
  Http_client.ensure_success response;
  let soup = Html.parse (Http_client.body response) in
  if Html.is_login_page soup || Html.is_auth_error soup then (
    Option.iter Session.clear session;
    Internal_error.authentication_required ());
  { response; soup }

let get_page session uri = Http_client.get session uri |> checked_page ~session

let post_page session uri fields =
  Http_client.post_form session uri fields |> checked_page ~session

let start_flow session flow_id =
  get_page session
    (make_uri "campussquare.do" ~query:[ ("_flowId", [ flow_id ]) ])

let flow_key page =
  match Html.flow_key page.soup with
  | Some key -> key
  | None ->
      Internal_error.protocolf "TWINS did not return a Web Flow execution key"

let form_fields_by_name page name =
  match Html.form_by_name name page.soup with
  | Some form -> Html.form_fields form
  | None -> Internal_error.protocolf "TWINS page does not contain form %S" name

let post_event session page ~form_name event replacements =
  let fields = form_fields_by_name page form_name in
  let fields = Html.set_fields (("_eventId", event) :: replacements) fields in
  post_page session (make_uri "campussquare.do") fields

let with_session ?session_file operation =
  let session = Session.load ?path:session_file () in
  Fun.protect
    ~finally:(fun () ->
      if not (Session.is_empty session) then Session.save session)
    (fun () -> operation session)

let find_login_form soup =
  soup |> Soup.select "form" |> Soup.to_list
  |> List.find_opt (fun form ->
      Soup.select_one "input[name='userName']" form <> None)

let login_exn ?session_file ~username ~password () =
  Session.authenticate ?path:session_file (fun session ->
      let initial = Http_client.get session (make_uri "") in
      Http_client.ensure_success initial;
      let soup = Html.parse (Http_client.body initial) in
      let form =
        match find_login_form soup with
        | Some form -> form
        | None -> Internal_error.protocolf "TWINS login form was not found"
      in
      let portal_hash =
        match Html.portal_hash soup with
        | Some hash -> hash
        | None -> Internal_error.protocolf "TWINS portal token was not found"
      in
      let fields =
        Html.form_fields form
        |> Html.set_fields
             [
               ("userName", username);
               ("password", password);
               ("action", "rwf");
               ("tabId", "home");
               ("page", "");
               ("rwfHash", portal_hash);
             ]
      in
      let result =
        Http_client.post_form session (make_uri "portal.do") fields
      in
      Http_client.ensure_success result;
      (if not (Util.contains ~needle:"login ok." (Http_client.body result)) then
         let message =
           let page = Html.parse (Http_client.body result) in
           match Html.messages page with
           | message :: _ -> message
           | [] -> Html.article_text page
         in
         let suffix = if message = "" then "" else ": " ^ message in
         Internal_error.protocolf "TWINS login failed%s" suffix);
      let main =
        Http_client.get session
          (make_uri "portal.do" ~query:[ ("page", [ "main" ]) ])
      in
      ignore (checked_page main))

let login ?session_file ~username ~password () =
  Internal_error.protect (fun () ->
      login_exn ?session_file ~username ~password ())

let logout_exn ?session_file () =
  let session = Session.load ~allow_incompatible:true ?path:session_file () in
  Fun.protect
    ~finally:(fun () -> Session.clear session)
    (fun () ->
      if not (Session.is_empty session) then
        ignore
          (Http_client.get session
             (make_uri "portal.do" ~query:[ ("page", [ "logout" ]) ])))

let logout ?session_file () =
  Internal_error.protect (fun () -> logout_exn ?session_file ())

type status = { logged_in : bool; title : string }

let status_exn ?session_file () =
  let session = Session.load ~allow_incompatible:true ?path:session_file () in
  if Session.is_empty session then { logged_in = false; title = "" }
  else
    let response =
      Http_client.get session
        (make_uri "portal.do" ~query:[ ("page", [ "main" ]) ])
    in
    Http_client.ensure_success response;
    let soup = Html.parse (Http_client.body response) in
    if Html.is_login_page soup || Html.is_auth_error soup then (
      Session.clear session;
      { logged_in = false; title = Html.title soup })
    else (
      Session.save session;
      { logged_in = true; title = Html.title soup })

let status ?session_file () =
  Internal_error.protect (fun () -> status_exn ?session_file ())

type grade = {
  year : string;
  term : string;
  category : string;
  code : string;
  name : string;
  instructor : string;
  credits : string;
  spring : string;
  autumn : string;
  score : string;
  total : string;
}

let grade_to_yojson grade =
  `Assoc
    [
      ("year", `String grade.year);
      ("term", `String grade.term);
      ("category", `String grade.category);
      ("code", `String grade.code);
      ("name", `String grade.name);
      ("instructor", `String grade.instructor);
      ("credits", `String grade.credits);
      ("spring", `String grade.spring);
      ("autumn", `String grade.autumn);
      ("score", `String grade.score);
      ("total", `String grade.total);
    ]

let parse_grades_exn soup =
  (* Older TWINS markup used id="auto-table-4"; current pages use un-id'd
     class="normal" tables identified by the grade header row. *)
  let table =
    match Html.table_by_id "auto-table-4" soup with
    | Some table -> Some table
    | None ->
        Html.table_by_headers [ "No."; "年度"; "学期"; "科目区分"; "科目番号"; "科目名" ] soup
  in
  match table with
  | None -> Internal_error.protocolf "TWINS grade table was not found"
  | Some table ->
      Html.rows table
      |> List.filter_map (fun row ->
          match Html.cell_texts row with
          | number :: year :: term :: category :: code :: name :: instructor
            :: credits :: spring :: autumn :: score :: total :: _
            when number <> "No." ->
              Some
                {
                  year;
                  term;
                  category;
                  code;
                  name;
                  instructor;
                  credits;
                  spring;
                  autumn;
                  score;
                  total;
                }
          | _ -> None)

let grades_exn ?session_file () =
  with_session ?session_file (fun session ->
      start_flow session "SIW0001200-flow" |> fun page ->
      parse_grades_exn page.soup)

let grades ?session_file () =
  Internal_error.protect (fun () -> grades_exn ?session_file ())

let parse_grades soup = Internal_error.protect (fun () -> parse_grades_exn soup)

module Module = struct
  type t =
    | Spring_a
    | Spring_b
    | Spring_c
    | Summer
    | Autumn_a
    | Autumn_b
    | Autumn_c
    | Spring_break

  let all =
    [
      Spring_a;
      Spring_b;
      Spring_c;
      Summer;
      Autumn_a;
      Autumn_b;
      Autumn_c;
      Spring_break;
    ]

  let to_string = function
    | Spring_a -> "spring-a"
    | Spring_b -> "spring-b"
    | Spring_c -> "spring-c"
    | Summer -> "summer"
    | Autumn_a -> "autumn-a"
    | Autumn_b -> "autumn-b"
    | Autumn_c -> "autumn-c"
    | Spring_break -> "spring-break"

  let label = function
    | Spring_a -> "春A"
    | Spring_b -> "春B"
    | Spring_c -> "春C"
    | Summer -> "夏休"
    | Autumn_a -> "秋A"
    | Autumn_b -> "秋B"
    | Autumn_c -> "秋C"
    | Spring_break -> "春休"

  let codes = function
    | Spring_a -> ("1", "A")
    | Spring_b -> ("2", "A")
    | Spring_c -> ("3", "A")
    | Summer -> ("A", "A")
    | Autumn_a -> ("4", "B")
    | Autumn_b -> ("5", "B")
    | Autumn_c -> ("6", "B")
    | Spring_break -> ("B", "B")

  let of_string value =
    match List.find_opt (fun candidate -> to_string candidate = value) all with
    | Some value -> Ok value
    | None ->
        Error
          (Error.Invalid_argument
             (Printf.sprintf "unknown module %S (use %s)" value
                (all |> List.map to_string |> String.concat ", ")))
end

module Day = struct
  type t = int

  let to_int value = value

  let of_int value =
    if value >= 1 && value <= 7 then Ok value
    else Error (Error.Invalid_argument "--day は 1 から 7 で指定してください。")
end

module Period = struct
  type t = int

  let to_int value = value

  let of_int value =
    if value >= 1 && value <= 9 then Ok value
    else Error (Error.Invalid_argument "--period は 1 から 9 で指定してください。")
end

let registration_page session module_ =
  let module_code, term_code = Module.codes module_ in
  let page = start_flow session "RSW0001000-flow" in
  let key = flow_key page in
  get_page session
    (make_uri "campussquare.do"
       ~query:
         [
           ("_flowExecutionKey", [ key ]);
           ("_eventId", [ "search" ]);
           ("moduleCode", [ module_code ]);
           ("gakkiKbnCode", [ term_code ]);
         ])

type timetable_entry = {
  module_label : string;
  day : string;
  period : string;
  code : string;
  description : string;
  intensive : bool;
}

let timetable_entry_to_yojson entry =
  `Assoc
    [
      ("module", `String entry.module_label);
      ("day", `String entry.day);
      ("period", `String entry.period);
      ("code", `String entry.code);
      ("description", `String entry.description);
      ("intensive", `Bool entry.intensive);
    ]

let cell_parts cell =
  Soup.trimmed_texts cell
  |> List.map Util.normalize_space
  |> List.filter (fun part -> part <> "")

let rec combine_shortest left right =
  match (left, right) with
  | left_value :: left_rest, right_value :: right_rest ->
      (left_value, right_value) :: combine_shortest left_rest right_rest
  | _ -> []

let parse_timetable_exn module_ soup =
  let regular =
    let table =
      match Html.table_by_id "auto-table-2-2" soup with
      | Some table -> Some table
      | None -> Html.table_by_headers [ "月曜日"; "火曜日"; "水曜日"; "木曜日"; "金曜日" ] soup
    in
    match table with
    | None -> Internal_error.protocolf "TWINS timetable table was not found"
    | Some table -> (
        match Html.rows table with
        | [] -> []
        | header :: periods ->
            let days =
              match Html.direct_cells header with
              | [] -> []
              | _corner :: day_cells -> List.map Html.node_text day_cells
            in
            periods
            |> List.concat_map (fun row ->
                match Html.direct_cells row with
                | [] -> []
                | period_cell :: course_cells ->
                    let period = Html.node_text period_cell in
                    combine_shortest days course_cells
                    |> List.filter_map (fun (day, cell) ->
                        let parts = cell_parts cell in
                        match parts with
                        | [] | [ "未登録" ] -> None
                        | code :: description ->
                            Some
                              {
                                module_label = Module.label module_;
                                day;
                                period;
                                code;
                                description =
                                  String.concat " " (code :: description);
                                intensive = false;
                              })))
  in
  let intensive =
    let table =
      match Html.table_by_id "auto-table-2-3" soup with
      | Some table -> Some table
      | None ->
          Html.table_by_headers [ "曜日"; "時限"; "科目番号"; "科目名"; "担当教員名" ] soup
    in
    let entry day period code name instructor =
      {
        module_label = Module.label module_;
        day;
        period;
        code;
        description =
          [ code; name; instructor ]
          |> List.filter (fun value -> value <> "")
          |> String.concat " ";
        intensive = true;
      }
    in
    match table with
    | None -> []
    | Some table ->
        Html.rows table
        |> List.filter_map (fun row ->
            match Html.cell_texts row with
            | day :: period :: code :: name :: _blank :: instructor :: _
              when code <> "科目番号" && code <> "" ->
                Some (entry day period code name instructor)
            | day :: period :: code :: name :: instructor :: _
              when code <> "科目番号" && code <> "" ->
                Some (entry day period code name instructor)
            | _ -> None)
  in
  regular @ intensive

let timetable_exn ?session_file module_ =
  with_session ?session_file (fun session ->
      let page = registration_page session module_ in
      parse_timetable_exn module_ page.soup)

let timetable ?session_file module_ =
  Internal_error.protect (fun () -> timetable_exn ?session_file module_)

let parse_timetable module_ soup =
  Internal_error.protect (fun () -> parse_timetable_exn module_ soup)

let registration_snapshot module_ page =
  (* Require a recognizable timetable even when it contains no entries. Also
     preserve locked courses without a DeleteCallA link and all deletion keys. *)
  let timetable =
    parse_timetable_exn module_ page.soup
    |> List.map (fun (entry : timetable_entry) ->
        Registration.
          {
            code = entry.code;
            identity =
              [
                "timetable";
                entry.module_label;
                entry.day;
                entry.period;
                entry.description;
                string_of_bool entry.intensive;
              ];
          })
  in
  let deletable =
    Html.registrations page.soup
    |> List.map (fun (entry : Html.registration) ->
        Registration.
          {
            code = entry.code;
            identity =
              [
                "deletable";
                entry.year;
                entry.department;
                entry.day;
                entry.period;
              ];
          })
  in
  timetable @ deletable

let register ?session_file ~module_ ~day ~period ~code ~force_limit () =
  Internal_error.protect (fun () ->
      with_session ?session_file (fun session ->
          Registration.add
            ~read:(fun () -> registration_page session module_)
            ~snapshot:(registration_snapshot module_)
            ~post:(fun page form_name event fields ->
              post_event session page ~form_name event fields)
            ~limited:(fun page ->
              Util.contains ~needle:"kyoseiToroku"
                (Http_client.body page.response)
              && not
                   (List.exists
                      (fun (entry : Html.registration) -> entry.code = code)
                      (Html.registrations page.soup)))
            ~code
            ~day:(string_of_int (Day.to_int day))
            ~period:(string_of_int (Period.to_int period))
            ~force_limit))

let unregister ?session_file ~module_ ~code () =
  Internal_error.protect (fun () ->
      with_session ?session_file (fun session ->
          Registration.remove
            ~read:(fun () -> registration_page session module_)
            ~snapshot:(registration_snapshot module_)
            ~targets:(fun page -> Html.registrations page.soup)
            ~post:(fun page form_name event fields ->
              post_event session page ~form_name event fields)
            ~confirmed:(fun page code ->
              let text = Html.article_text page.soup in
              Util.contains ~needle:"以下の時間割を削除" text
              && Util.contains ~needle:code text)
            ~code))

type notice = {
  seq : string;
  genre : string;
  course : string;
  instructor : string;
  title : string;
  period : string;
  posted : string;
}

let notice_to_yojson notice =
  `Assoc
    [
      ("id", `String notice.seq);
      ("genre", `String notice.genre);
      ("course", `String notice.course);
      ("instructor", `String notice.instructor);
      ("title", `String notice.title);
      ("period", `String notice.period);
      ("posted", `String notice.posted);
    ]

module Notice_kind = struct
  type t = Classes | General

  let all = [ Classes; General ]
  let to_string = function Classes -> "classes" | General -> "general"

  let of_string = function
    | "classes" -> Ok Classes
    | "general" -> Ok General
    | value ->
        Error
          (Error.Invalid_argument
             (Printf.sprintf "notice kind must be classes or general: %S" value))
end

let notices_page session ~kind ~unread ~title =
  let page = start_flow session "KJW0001100-flow" in
  let fields = form_fields_by_name page "keijiSearchForm" in
  let fields =
    fields
    |> Html.set_fields
         [
           ("_eventId", "findSelect");
           ( "keijitype",
             match kind with
             | Notice_kind.Classes -> "1"
             | Notice_kind.General -> "3" );
           ("keijiTitle", title);
         ]
  in
  let fields =
    if unread then Html.set_field "userMidokuFlg" "1" fields
    else Html.remove_field "userMidokuFlg" fields
  in
  post_page session (make_uri "campussquare.do") fields

let parse_notices_exn soup =
  (* Older markup used id="auto-table-3"; current result tables are un-id'd
     and start with ジャンル/科目/担当者/表題 headers. *)
  let table =
    match Html.table_by_id "auto-table-3" soup with
    | Some table -> Some table
    | None -> Html.table_by_headers [ "ジャンル"; "科目"; "担当者"; "表題" ] soup
  in
  match table with
  | None -> Internal_error.protocolf "TWINS notice result table was not found"
  | Some table ->
      Html.rows table
      |> List.filter_map (fun row ->
          match Html.cell_texts row with
          | genre :: course :: instructor :: title :: period :: posted :: _
            when genre <> "ジャンル" ->
              let seq =
                match
                  row |> Soup.select "a[href]" |> Soup.to_list
                  |> List.filter_map (fun anchor ->
                      Option.bind
                        (Soup.attribute "href" anchor)
                        (Html.query_param "seqNo"))
                with
                | seq :: _ -> seq
                | [] -> ""
              in
              if seq = "" then
                Internal_error.protocolf
                  "TWINS notice row is missing its detail identifier";
              Some { seq; genre; course; instructor; title; period; posted }
          | _ -> None)

let parse_notices soup =
  Internal_error.protect (fun () -> parse_notices_exn soup)

type notice_result = notice Notice_pagination.result

let notice_result_to_yojson (result : notice_result) =
  `Assoc
    [
      ("items", `List (List.map notice_to_yojson result.items));
      ("completeness", `String result.completeness);
      ("pages_fetched", `Int result.pages_fetched);
      ( "reason",
        Option.fold ~none:`Null
          ~some:(fun reason -> `String reason)
          result.reason );
    ]

let collect_notices session ~limit ~max_pages first =
  Notice_pagination.collect
    ~fetch:(fun page href ->
      get_page session (absolute_uri (Http_client.uri page.response) href))
    ~parse:(fun page -> parse_notices_exn page.soup)
    ~next:(fun page -> Notice_pagination.next page.soup)
    ~id:(fun notice -> notice.seq)
    ~limit ~max_pages first

let notices_with_metadata ?session_file ?(all = false) ?(max_pages = 20) ~kind
    ~unread ~title ~limit () =
  if limit < 0 then Error (Error.Invalid_argument "--limit は 0 以上で指定してください。")
  else if max_pages < 1 || max_pages > 100 then
    Error (Error.Invalid_argument "--max-pages must be 1..100")
  else
    Internal_error.protect (fun () ->
        with_session ?session_file (fun session ->
            let page = notices_page session ~kind ~unread ~title in
            collect_notices session
              ~limit:(if all then None else Some limit)
              ~max_pages page))

let notices ?session_file ~kind ~unread ~title ~limit () =
  notices_with_metadata ?session_file ~kind ~unread ~title ~limit ()
  |> Result.map (fun result -> result.Notice_pagination.items)

let notice_detail_exn ?session_file ~kind seq =
  with_session ?session_file (fun session ->
      let page = notices_page session ~kind ~unread:false ~title:"" in
      let rec find pages seen page =
        let href =
          page.soup |> Soup.select "a[href]" |> Soup.to_list
          |> List.find_map (fun anchor ->
              match Soup.attribute "href" anchor with
              | Some href when Html.query_param "seqNo" href = Some seq ->
                  Some href
              | _ -> None)
        in
        match href with
        | Some href ->
            get_page session (absolute_uri (Http_client.uri page.response) href)
            |> fun detail -> Html.article_text detail.soup
        | None -> (
            match Notice_pagination.next page.soup with
            | Notice_pagination.Next href
              when pages < 20 && not (List.mem href seen) ->
                let next =
                  get_page session
                    (absolute_uri (Http_client.uri page.response) href)
                in
                find (pages + 1) (href :: seen) next
            | Notice_pagination.End ->
                Internal_error.protocolf "notice %s was not found" seq
            | _ ->
                Internal_error.protocolf
                  "notice %s was not found before the pagination bound or an \
                   unsupported pager"
                  seq)
      in
      find 1 [] page)

let notice_detail ?session_file ~kind seq =
  Internal_error.protect (fun () -> notice_detail_exn ?session_file ~kind seq)

module Date = struct
  type t = { year : int; month : int; day : int }

  let is_leap year = year mod 400 = 0 || (year mod 4 = 0 && year mod 100 <> 0)

  let days_in_month year = function
    | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
    | 4 | 6 | 9 | 11 -> 30
    | 2 -> if is_leap year then 29 else 28
    | _ -> 0

  let of_string value =
    let invalid () =
      Error
        (Error.Invalid_argument
           (Printf.sprintf "date must use YYYY-MM-DD: %S" value))
    in
    match String.split_on_char '-' value with
    | [ year; month; day ]
      when String.length year = 4
           && String.length month = 2
           && String.length day = 2 -> (
        match
          ( int_of_string_opt year,
            int_of_string_opt month,
            int_of_string_opt day )
        with
        | Some year, Some month, Some day
          when year >= 1 && month >= 1 && month <= 12 && day >= 1
               && day <= days_in_month year month ->
            Ok { year; month; day }
        | _ -> invalid ())
    | _ -> invalid ()

  let to_string (value : t) =
    Printf.sprintf "%04d-%02d-%02d" value.year value.month value.day

  let parts (value : t) =
    [
      ("year", Printf.sprintf "%04d" value.year);
      ("month", Printf.sprintf "%02d" value.month);
      ("day", Printf.sprintf "%02d" value.day);
    ]
end

let cancellations_exn ?session_file ~start_date ~end_date ~registered_only () =
  with_session ?session_file (fun session ->
      let page = start_flow session "KHW0001100-flow" in
      let fields = form_fields_by_name page "searchForm" in
      let start_parts = Date.parts start_date in
      let end_parts = Date.parts end_date in
      let prefixed prefix parts =
        parts
        |> List.map (fun (suffix, value) -> (prefix ^ "_" ^ suffix, value))
      in
      let replacements =
        [
          ("dispType", "list");
          ("dispData", "all");
          ( "startDay",
            String.concat "/"
              (String.split_on_char '-' (Date.to_string start_date)) );
          ( "endDay",
            String.concat "/"
              (String.split_on_char '-' (Date.to_string end_date)) );
          ("_eventId_search", " 表 示 す る");
        ]
        @ prefixed "startDay" start_parts
        @ prefixed "endDay" end_parts
      in
      let fields = Html.set_fields replacements fields in
      let fields =
        if registered_only then Html.set_field "rishuchuFlg" "true" fields
        else Html.remove_field "rishuchuFlg" fields
      in
      let result = post_page session (make_uri "campussquare.do") fields in
      Html.article_text result.soup)

let cancellations ?session_file ~start_date ~end_date ~registered_only () =
  Internal_error.protect (fun () ->
      cancellations_exn ?session_file ~start_date ~end_date ~registered_only ())

type menu_item = { name : string; flow : string }

let menu =
  [
    { name = "student-portfolio"; flow = "CHW0001000-flow" };
    { name = "registration"; flow = "RSW0001000-flow" };
    { name = "course-category"; flow = "HTW1201000-flow" };
    { name = "registration-change"; flow = "RSW1201000-flow" };
    { name = "continued-registration"; flow = "RSW1201100-flow" };
    { name = "special-registration"; flow = "RSW1201200-flow" };
    { name = "pre-registration"; flow = "RSW0001300-flow" };
    { name = "pre-registration-status"; flow = "RSW0001400-flow" };
    { name = "graduation-check"; flow = "HTW0001000-flow" };
    { name = "qualification-check"; flow = "HTW0001100-flow" };
    { name = "grades"; flow = "SIW0001200-flow" };
    { name = "schedule"; flow = "PTW0001200-flow" };
    { name = "cancellations"; flow = "KHW0001100-flow" };
    { name = "surveys"; flow = "ENW0001100-flow" };
    { name = "notices"; flow = "KJW0001100-flow" };
    { name = "downloads"; flow = "SDW0001000-flow" };
    { name = "achievement"; flow = "PRW0004000-flow" };
    { name = "aspiration"; flow = "SNW1201800-flow" };
  ]

let resolve_flow name =
  match List.find_opt (fun (item : menu_item) -> item.name = name) menu with
  | Some item -> item.flow
  | None when Util.contains ~needle:"-flow" name -> name
  | None -> Internal_error.invalidf "unknown menu or flow %S" name

let raw_exn ?session_file ~flow ~form_name ~event ~fields () =
  with_session ?session_file (fun session ->
      let page = start_flow session (resolve_flow flow) in
      let page =
        match event with
        | None -> page
        | Some event -> post_event session page ~form_name event fields
      in
      Html.article_text page.soup)

let raw ?session_file ~flow ~form_name ~event ~fields () =
  Internal_error.protect (fun () ->
      raw_exn ?session_file ~flow ~form_name ~event ~fields ())

let pre_registration_io session =
  let open_flow flow = (start_flow session flow).soup in
  let get href =
    let uri = absolute_uri (make_uri "campussquare.do") href in
    if
      Uri.scheme uri <> Some "https"
      || Uri.host uri <> Some host
      || Uri.path uri <> campus_path ^ "campussquare.do"
    then Internal_error.protocolf "Unexpected pre-registration link destination";
    (get_page session uri).soup
  in
  let post soup event replacements =
    let form =
      match Html.form_by_name "InputForm" soup with
      | Some form when Soup.attribute "id" form = Some "rishuYobiEntryForm" ->
          form
      | _ -> Internal_error.protocolf "Missing pre-registration form"
    in
    let fields =
      Html.form_fields form
      |> Html.set_fields (("_eventId", event) :: replacements)
    in
    (post_page session (make_uri "campussquare.do") fields).soup
  in
  (open_flow, get, post)

let pre_registration_list ?session_file () =
  Internal_error.protect (fun () ->
      with_session ?session_file (fun session ->
          (start_flow session "RSW0001400-flow").soup
          |> Pre_registration.inquiry))

let pre_registration_groups ?session_file ~module_ () =
  Internal_error.protect (fun () ->
      with_session ?session_file (fun session ->
          let open_flow, get, _ = pre_registration_io session in
          Pre_registration.group_page ~open_flow ~get
            ~category:(Module.label module_ ^ "開始")
          |> Pre_registration.links ~event:"input" ~key:"yobiKamokuKubunCode"))

let pre_registration_courses ?session_file ~module_ ~group () =
  Internal_error.protect (fun () ->
      with_session ?session_file (fun session ->
          let open_flow, get, _ = pre_registration_io session in
          Pre_registration.input_page ~open_flow ~get
            ~category:(Module.label module_ ^ "開始")
            ~group
          |> Pre_registration.input_courses))

let pre_register ?session_file ~module_ ~group ~code ~rank () =
  if rank < 1 then Error (Error.Invalid_argument "--rank must be positive")
  else
    Internal_error.protect (fun () ->
        with_session ?session_file (fun session ->
            let open_flow, get, post = pre_registration_io session in
            Pre_registration.add ~open_flow ~get ~post
              ~category:(Module.label module_ ^ "開始")
              ~group ~code ~rank))
