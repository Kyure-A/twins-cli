open Cmdliner

let fail message =
  prerr_endline ("twins: " ^ message);
  exit 1

exception Cli_error of Error.t

let unwrap = function
  | Ok value -> value
  | Error error -> raise (Cli_error error)

let run operation =
  try operation () with
  | Cli_error error -> fail (Error.to_string error)
  | Sys_error message -> fail message
  | Unix.Unix_error (error, function_name, argument) ->
      fail
        (Printf.sprintf "%s: %s (%s)" function_name (Unix.error_message error)
           argument)
  | (Out_of_memory | Stack_overflow | Sys.Break) as fatal -> raise fatal
  | exn -> fail (Printexc.to_string exn)

let read_password prompt =
  match Sys.getenv_opt "TWINS_PASSWORD" with
  | Some password -> password
  | None ->
      output_string stderr prompt;
      flush stderr;
      let descriptor = Unix.descr_of_in_channel stdin in
      let attributes = Unix.tcgetattr descriptor in
      let hidden = { attributes with Unix.c_echo = false } in
      Fun.protect
        ~finally:(fun () ->
          Unix.tcsetattr descriptor Unix.TCSAFLUSH attributes;
          output_char stderr '\n';
          flush stderr)
        (fun () ->
          Unix.tcsetattr descriptor Unix.TCSAFLUSH hidden;
          input_line stdin)

let prompt_line prompt =
  output_string stderr prompt;
  flush stderr;
  input_line stdin |> String.trim

let parse_assignment value =
  match String.index_opt value '=' with
  | None -> Error (Printf.sprintf "expected NAME=VALUE, got %S" value)
  | Some index ->
      let name = String.sub value 0 index |> String.trim in
      let data =
        String.sub value (index + 1) (String.length value - index - 1)
      in
      if name = "" then Error "field name cannot be empty" else Ok (name, data)

let session =
  let env = Cmd.Env.info "TWINS_SESSION" in
  let doc = "セッション Cookie の保存先。既定は XDG_STATE_HOME 以下です。" in
  Arg.(
    value & opt (some string) None & info [ "session" ] ~env ~docv:"FILE" ~doc)

let json = Arg.(value & flag & info [ "json" ] ~doc:"機械可読な JSON で出力します。")

let print_json value =
  Yojson.Safe.pretty_to_channel stdout value;
  output_char stdout '\n'

let clean_tsv value =
  String.map
    (function '\t' | '\r' | '\n' -> ' ' | character -> character)
    value

let print_tsv fields =
  fields |> List.map clean_tsv |> String.concat "\t" |> print_endline

let username =
  Arg.(
    value
    & opt (some string) None
    & info [ "u"; "username" ] ~docv:"ID"
        ~doc:"統一認証 ID。省略時は TWINS_USERNAME、次に対話入力を使います。")

let login_command =
  let password_stdin =
    Arg.(
      value & flag & info [ "password-stdin" ] ~doc:"パスワードを標準入力の 1 行から読み取ります。")
  in
  let execute session_file username password_stdin =
    run (fun () ->
        let username =
          match (username, Sys.getenv_opt "TWINS_USERNAME") with
          | (Some value, _ | None, Some value) when String.trim value <> "" ->
              value
          | _ -> prompt_line "統一認証 ID: "
        in
        let password =
          match Sys.getenv_opt "TWINS_PASSWORD" with
          | Some value when String.trim value <> "" -> value
          | _ when password_stdin -> input_line stdin
          | _ -> read_password "パスワード（入力・貼り付け内容は表示されません）: "
        in
        Twins.login ?session_file ~username ~password () |> unwrap;
        print_endline "ログインしました。セッションを保存しました。")
  in
  let term = Term.(const execute $ session $ username $ password_stdin) in
  Cmd.v (Cmd.info "login" ~doc:"筑波大学統一認証でログインし、Cookie だけを保存します。") term

let logout_command =
  let execute session_file =
    run (fun () ->
        Twins.logout ?session_file () |> unwrap;
        print_endline "ローカルのセッションを削除しました。")
  in
  Cmd.v
    (Cmd.info "logout" ~doc:"保存した Cookie をローカルから削除します。")
    Term.(const execute $ session)

let status_command =
  let execute session_file =
    run (fun () ->
        let status = Twins.status ?session_file () |> unwrap in
        if status.logged_in then print_endline "logged in"
        else print_endline "logged out")
  in
  Cmd.v
    (Cmd.info "status" ~doc:"保存セッションが有効か確認します。")
    Term.(const execute $ session)

let auth_command =
  Cmd.group
    (Cmd.info "auth" ~doc:"認証セッションを管理します。")
    [ login_command; status_command; logout_command ]

let grades_command =
  let execute session_file json =
    run (fun () ->
        let grades = Twins.grades ?session_file () |> unwrap in
        if json then print_json (`List (List.map Twins.grade_to_yojson grades))
        else (
          print_tsv
            [
              "年度";
              "学期";
              "科目区分";
              "科目番号";
              "科目名";
              "担当教員";
              "単位数";
              "春学期";
              "秋学期";
              "評点";
              "総合";
            ];
          List.iter
            (fun (grade : Twins.grade) ->
              print_tsv
                [
                  grade.year;
                  grade.term;
                  grade.category;
                  grade.code;
                  grade.name;
                  grade.instructor;
                  grade.credits;
                  grade.spring;
                  grade.autumn;
                  grade.score;
                  grade.total;
                ])
            grades))
  in
  Cmd.v
    (Cmd.info "grades" ~doc:"成績を一覧表示します。")
    Term.(const execute $ session $ json)

let module_slug =
  let choices = Twins.Module.all |> List.map Twins.Module.to_string in
  let doc = "モジュール: " ^ String.concat ", " choices ^ "。" in
  Arg.(
    required & opt (some string) None & info [ "module" ] ~docv:"MODULE" ~doc)

let timetable_command =
  let execute session_file module_slug json =
    run (fun () ->
        let module_ = Twins.Module.of_string module_slug |> unwrap in
        let entries = Twins.timetable ?session_file module_ |> unwrap in
        if json then
          print_json (`List (List.map Twins.timetable_entry_to_yojson entries))
        else (
          print_tsv [ "モジュール"; "曜日"; "時限"; "科目番号"; "内容"; "集中" ];
          List.iter
            (fun (entry : Twins.timetable_entry) ->
              print_tsv
                [
                  entry.module_label;
                  entry.day;
                  entry.period;
                  entry.code;
                  entry.description;
                  string_of_bool entry.intensive;
                ])
            entries))
  in
  Cmd.v
    (Cmd.info "timetable" ~doc:"履修時間割を表示します。")
    Term.(const execute $ session $ module_slug $ json)

let course_code =
  Arg.(required & pos 0 (some string) None & info [] ~docv:"COURSE_CODE")

let yes = Arg.(value & flag & info [ "yes"; "y" ] ~doc:"確認なしで実行します。")

let confirm yes description =
  if yes then true
  else (
    Printf.eprintf "%s [y/N]: %!" description;
    match input_line stdin |> String.trim |> String.lowercase_ascii with
    | "y" | "yes" -> true
    | _ -> false)

let day =
  Arg.(
    required
    & opt (some int) None
    & info [ "day" ] ~docv:"1..7" ~doc:"曜日番号（月曜は 1）。")

let period =
  Arg.(
    required & opt (some int) None & info [ "period" ] ~docv:"1..9" ~doc:"開始時限。")

let register_command =
  let force_limit =
    Arg.(
      value & flag
      & info [ "force-limit" ] ~doc:"TWINS が年間履修上限の確認を表示した場合に承認します。")
  in
  let execute session_file module_slug day period force_limit yes code =
    run (fun () ->
        let module_ = Twins.Module.of_string module_slug |> unwrap in
        let day = Twins.Day.of_int day |> unwrap in
        let period = Twins.Period.of_int period |> unwrap in
        if not (confirm yes (Printf.sprintf "%s を履修登録します。" code)) then
          raise (Cli_error (Error.Cancelled "登録を中止しました。"));
        Twins.register ?session_file ~module_ ~day ~period ~code ~force_limit ()
        |> unwrap;
        Printf.printf "%s を履修登録し、再照会で確認しました。\n" code)
  in
  Cmd.v
    (Cmd.info "add" ~doc:"科目を履修登録します。")
    Term.(
      const execute $ session $ module_slug $ day $ period $ force_limit $ yes
      $ course_code)

let unregister_command =
  let execute session_file module_slug yes code =
    run (fun () ->
        let module_ = Twins.Module.of_string module_slug |> unwrap in
        if not (confirm yes (Printf.sprintf "%s の履修登録を削除します。" code)) then
          raise (Cli_error (Error.Cancelled "削除を中止しました。"));
        Twins.unregister ?session_file ~module_ ~code () |> unwrap;
        Printf.printf "%s の履修登録を削除し、再照会で確認しました。\n" code)
  in
  Cmd.v
    (Cmd.info "remove" ~doc:"科目の履修登録を削除します。")
    Term.(const execute $ session $ module_slug $ yes $ course_code)

let registration_command =
  Cmd.group
    (Cmd.info "registration" ~doc:"履修登録を管理します。")
    [ register_command; unregister_command ]

let print_pre_courses json courses =
  if json then
    print_json (`List (List.map Pre_registration.course_to_yojson courses))
  else
    List.iter
      (fun (c : Pre_registration.course) ->
        print_tsv
          [
            c.code;
            c.name;
            Option.fold ~none:"" ~some:string_of_int c.rank;
            c.capacity;
            c.first_choices;
          ])
      courses

let pre_registration_command =
  let group =
    Arg.(
      required
      & opt (some string) None
      & info [ "group" ] ~docv:"ID_OR_NAME" ~doc:"groups で確認した科目グループ ID または名前。")
  in
  let list_command =
    let execute session_file json =
      run (fun () ->
          Twins.pre_registration_list ?session_file ()
          |> unwrap |> print_pre_courses json)
    in
    Cmd.v
      (Cmd.info "list" ~doc:"保存済みの事前登録希望を照会します（履修確定ではありません）。")
      Term.(const execute $ session $ json)
  in
  let groups_command =
    let execute session_file module_slug json =
      run (fun () ->
          let module_ = Twins.Module.of_string module_slug |> unwrap in
          let groups =
            Twins.pre_registration_groups ?session_file ~module_ () |> unwrap
          in
          if json then
            print_json (`List (List.map Pre_registration.link_to_yojson groups))
          else
            List.iter
              (fun (g : Pre_registration.link) ->
                print_tsv [ g.id; g.name; g.status ])
              groups)
    in
    Cmd.v
      (Cmd.info "groups" ~doc:"受付中の科目グループを表示します。")
      Term.(const execute $ session $ module_slug $ json)
  in
  let courses_command =
    let execute session_file module_slug group json =
      run (fun () ->
          let module_ = Twins.Module.of_string module_slug |> unwrap in
          Twins.pre_registration_courses ?session_file ~module_ ~group ()
          |> unwrap |> print_pre_courses json)
    in
    Cmd.v
      (Cmd.info "courses" ~doc:"グループの科目・希望順位・定員を表示します。")
      Term.(const execute $ session $ module_slug $ group $ json)
  in
  let add_command =
    let rank =
      Arg.(
        value & opt int 1
        & info [ "rank" ] ~docv:"N" ~doc:"希望順位（既定は1）。既存の他科目の順位は保持します。")
    in
    let execute session_file module_slug group rank yes json code =
      run (fun () ->
          let module_ = Twins.Module.of_string module_slug |> unwrap in
          if rank < 1 then
            raise (Cli_error (Error.Invalid_argument "--rank must be positive"));
          if
            not
              (confirm yes
                 (Printf.sprintf "%s / %s: %s を第%d希望で事前登録します。"
                    (Twins.Module.label module_)
                    group code rank))
          then raise (Cli_error (Error.Cancelled "事前登録を中止しました。"));
          let result =
            Twins.pre_register ?session_file ~module_ ~group ~rank ~code ()
            |> unwrap
          in
          if json then
            print_json
              (`Assoc
                 [
                   ("status", `String "pre_registered");
                   ("enrollment_confirmed", `Bool false);
                   ("course", Pre_registration.course_to_yojson result);
                 ])
          else Printf.printf "%s を第%d希望で事前登録し、照会で確認しました（履修確定前）。\n" code rank)
    in
    Cmd.v
      (Cmd.info "add" ~doc:"1科目を事前登録し、新しい照会で保存を確認します。")
      Term.(
        const execute $ session $ module_slug $ group $ rank $ yes $ json
        $ course_code)
  in
  Cmd.group
    (Cmd.info "pre-registration" ~doc:"抽選対象科目の事前登録を管理します。")
    [ list_command; groups_command; courses_command; add_command ]

let notice_kind =
  let choices =
    Twins.Notice_kind.all
    |> List.map (fun kind -> (Twins.Notice_kind.to_string kind, kind))
  in
  let default = Twins.Notice_kind.of_string "classes" |> unwrap in
  Arg.(
    value
    & opt (enum choices) default
    & info [ "kind" ] ~docv:"KIND" ~doc:"掲示種別: classes または general。")

let notices_command =
  let unread = Arg.(value & flag & info [ "unread" ] ~doc:"未読の掲示だけを表示します。") in
  let title =
    Arg.(
      value & opt string "" & info [ "title" ] ~docv:"TEXT" ~doc:"表題で絞り込みます。")
  in
  let limit = Arg.(value & opt int 50 & info [ "limit" ] ~docv:"N") in
  let all = Arg.(value & flag & info [ "all" ] ~doc:"件数上限を外し、最大ページ数まで巡回します。") in
  let max_pages =
    Arg.(
      value & opt int 20
      & info [ "max-pages" ] ~docv:"N" ~doc:"取得ページ上限（1..100、既定20）。")
  in
  let metadata =
    Arg.(
      value & flag & info [ "metadata" ] ~doc:"items と取得範囲の完全性を含む JSON を出力します。")
  in
  let execute session_file kind unread title limit all max_pages metadata json =
    run (fun () ->
        let result =
          Twins.notices_with_metadata ?session_file ~all ~max_pages ~kind
            ~unread ~title ~limit ()
          |> unwrap
        in
        let notices = result.items in
        if result.completeness <> "complete" && not metadata then
          Printf.eprintf
            "twins: notice results are partial (%s); use --metadata for \
             coverage details\n"
            (Option.value ~default:"unknown" result.reason);
        if metadata then print_json (Twins.notice_result_to_yojson result)
        else if json then
          print_json (`List (List.map Twins.notice_to_yojson notices))
        else (
          print_tsv [ "ID"; "ジャンル"; "科目"; "担当者"; "表題"; "掲示期間"; "掲載日時" ];
          List.iter
            (fun (notice : Twins.notice) ->
              print_tsv
                [
                  notice.seq;
                  notice.genre;
                  notice.course;
                  notice.instructor;
                  notice.title;
                  notice.period;
                  notice.posted;
                ])
            notices))
  in
  Cmd.v
    (Cmd.info "notices" ~doc:"授業・一般掲示を検索します。")
    Term.(
      const execute $ session $ notice_kind $ unread $ title $ limit $ all
      $ max_pages $ metadata $ json)

let notice_command =
  let seq = Arg.(required & pos 0 (some string) None & info [] ~docv:"ID") in
  let execute session_file kind seq =
    run (fun () ->
        Twins.notice_detail ?session_file ~kind seq |> unwrap |> print_endline)
  in
  Cmd.v
    (Cmd.info "notice" ~doc:"掲示本文を表示します。")
    Term.(const execute $ session $ notice_kind $ seq)

let today () =
  let value = Unix.localtime (Unix.time ()) in
  Printf.sprintf "%04d-%02d-%02d" (value.tm_year + 1900) (value.tm_mon + 1)
    value.tm_mday

let cancellations_command =
  let date_option names doc =
    Arg.(value & opt string (today ()) & info names ~docv:"YYYY-MM-DD" ~doc)
  in
  let start_date = date_option [ "from" ] "検索開始日。" in
  let end_date = date_option [ "to" ] "検索終了日。" in
  let all = Arg.(value & flag & info [ "all" ] ~doc:"未履修科目の休講情報も含めます。") in
  let execute session_file start_date end_date all =
    run (fun () ->
        let start_date = Twins.Date.of_string start_date |> unwrap in
        let end_date = Twins.Date.of_string end_date |> unwrap in
        Twins.cancellations ?session_file ~start_date ~end_date
          ~registered_only:(not all) ()
        |> unwrap |> print_endline)
  in
  Cmd.v
    (Cmd.info "cancellations" ~doc:"休講情報を検索します。")
    Term.(const execute $ session $ start_date $ end_date $ all)

let menu_command =
  let execute json =
    if json then
      Twins.menu
      |> List.map (fun (item : Twins.menu_item) ->
          `Assoc [ ("name", `String item.name); ("flow", `String item.flow) ])
      |> fun items -> print_json (`List items)
    else
      Twins.menu
      |> List.iter (fun (item : Twins.menu_item) ->
          Printf.printf "%s\t%s\n" item.name item.flow)
  in
  Cmd.v
    (Cmd.info "menu" ~doc:"既知の TWINS メニューフローを一覧表示します。")
    Term.(const execute $ json)

let raw_command =
  let flow =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"MENU_OR_FLOW")
  in
  let form_name =
    Arg.(
      value & opt string "InputForm"
      & info [ "form" ] ~docv:"NAME" ~doc:"送信するフォーム名。")
  in
  let event =
    Arg.(
      value
      & opt (some string) None
      & info [ "event" ] ~docv:"EVENT" ~doc:"送信する Spring Web Flow イベント。")
  in
  let field =
    Arg.(
      value & opt_all string []
      & info [ "field"; "F" ] ~docv:"NAME=VALUE" ~doc:"フォーム値。複数指定できます。")
  in
  let structure =
    Arg.(
      value & flag
      & info [ "structure" ] ~doc:"テーブル構造とページ送り要素だけを匿名化 JSON で出力します。")
  in
  let execute session_file form_name event field yes flow structure =
    run (fun () ->
        let fields =
          field
          |> List.map (fun assignment ->
              match parse_assignment assignment with
              | Ok field -> field
              | Error message ->
                  raise (Cli_error (Error.Invalid_argument message)))
        in
        Option.iter
          (fun event ->
            if
              not
                (confirm yes (Printf.sprintf "%s にイベント %s を送信します。" flow event))
            then raise (Cli_error (Error.Cancelled "送信を中止しました。")))
          event;
        Twins.raw ?session_file ~structure ~flow ~form_name ~event ~fields ()
        |> unwrap |> print_endline)
  in
  Cmd.v
    (Cmd.info "raw" ~doc:"メニューフローを開き、必要ならフォームイベントを 1 回送信します。")
    Term.(
      const execute $ session $ form_name $ event $ field $ yes $ flow
      $ structure)

let command =
  let doc = "筑波大学 TWINS を操作する OCaml 製 CLI" in
  Cmd.group
    (Cmd.info "twins" ~version:"0.1.0" ~doc)
    [
      auth_command;
      grades_command;
      timetable_command;
      registration_command;
      pre_registration_command;
      notices_command;
      notice_command;
      cancellations_command;
      menu_command;
      raw_command;
    ]

let () = exit (Cmd.eval command)
