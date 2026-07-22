open Cmdliner

let fail message =
  prerr_endline ("twins: " ^ message);
  exit 1

let run operation =
  try operation () with
  | Error.E message -> fail message
  | Sys_error message -> fail message
  | Unix.Unix_error (error, function_name, argument) ->
      fail
        (Printf.sprintf "%s: %s (%s)" function_name (Unix.error_message error)
           argument)

let session =
  let env = Cmd.Env.info "TWINS_SESSION" in
  let doc =
    "セッション Cookie の保存先。既定は XDG_STATE_HOME 以下です。"
  in
  Arg.(value & opt (some string) None & info [ "session" ] ~env ~docv:"FILE" ~doc)

let json =
  Arg.(value & flag & info [ "json" ] ~doc:"機械可読な JSON で出力します。")

let print_json value =
  Yojson.Safe.pretty_to_channel stdout value;
  output_char stdout '\n'

let clean_tsv value =
  String.map (function '\t' | '\r' | '\n' -> ' ' | character -> character) value

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
      value & flag
      & info [ "password-stdin" ] ~doc:"パスワードを標準入力の 1 行から読み取ります。")
  in
  let execute session_file username password_stdin =
    run (fun () ->
        let username =
          match (username, Sys.getenv_opt "TWINS_USERNAME") with
          | Some value, _ | None, Some value when String.trim value <> "" -> value
          | _ -> Util.prompt_line "統一認証 ID: "
        in
        let password =
          match Sys.getenv_opt "TWINS_PASSWORD" with
          | Some value when String.trim value <> "" -> value
          | _ when password_stdin -> input_line stdin
          | _ -> Util.read_password "パスワード（入力・貼り付け内容は表示されません）: "
        in
        Twins.login ?session_file ~username ~password ();
        print_endline "ログインしました。セッションを保存しました。")
  in
  let term = Term.(const execute $ session $ username $ password_stdin) in
  Cmd.v
    (Cmd.info "login" ~doc:"筑波大学統一認証でログインし、Cookie だけを保存します。")
    term

let logout_command =
  let execute session_file =
    run (fun () ->
        Twins.logout ?session_file ();
        print_endline "ローカルのセッションを削除しました。")
  in
  Cmd.v (Cmd.info "logout" ~doc:"保存した Cookie をローカルから削除します。")
    Term.(const execute $ session)

let status_command =
  let execute session_file =
    run (fun () ->
        let status = Twins.status ?session_file () in
        if status.logged_in then print_endline "logged in"
        else print_endline "logged out")
  in
  Cmd.v (Cmd.info "status" ~doc:"保存セッションが有効か確認します。")
    Term.(const execute $ session)

let auth_command =
  Cmd.group
    (Cmd.info "auth" ~doc:"認証セッションを管理します。")
    [ login_command; status_command; logout_command ]

let grades_command =
  let execute session_file json =
    run (fun () ->
        let grades = Twins.grades ?session_file () in
        if json then print_json (`List (List.map Twins.grade_to_yojson grades))
        else (
          print_tsv
            [
              "年度"; "学期"; "科目区分"; "科目番号"; "科目名"; "担当教員";
              "単位数"; "春学期"; "秋学期"; "評点"; "総合";
            ];
          List.iter
            (fun (grade : Twins.grade) ->
              print_tsv
                [
                  grade.year; grade.term; grade.category; grade.code; grade.name;
                  grade.instructor; grade.credits; grade.spring; grade.autumn;
                  grade.score; grade.total;
                ])
            grades))
  in
  Cmd.v (Cmd.info "grades" ~doc:"成績を一覧表示します。")
    Term.(const execute $ session $ json)

let module_slug =
  let choices = List.map (fun (item : Twins.module_code) -> item.slug) Twins.modules in
  let doc = "モジュール: " ^ String.concat ", " choices ^ "。" in
  Arg.(required & opt (some string) None & info [ "module" ] ~docv:"MODULE" ~doc)

let timetable_command =
  let execute session_file module_slug json =
    run (fun () ->
        let entries = Twins.timetable ?session_file module_slug in
        if json then
          print_json (`List (List.map Twins.timetable_entry_to_yojson entries))
        else (
          print_tsv [ "モジュール"; "曜日"; "時限"; "科目番号"; "内容"; "集中" ];
          List.iter
            (fun (entry : Twins.timetable_entry) ->
              print_tsv
                [
                  entry.module_label; entry.day; entry.period; entry.code;
                  entry.description; string_of_bool entry.intensive;
                ])
            entries))
  in
  Cmd.v (Cmd.info "timetable" ~doc:"履修時間割を表示します。")
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
    required
    & opt (some int) None
    & info [ "period" ] ~docv:"1..9" ~doc:"開始時限。")

let register_command =
  let force_limit =
    Arg.(
      value & flag
      & info [ "force-limit" ]
          ~doc:"TWINS が年間履修上限の確認を表示した場合に承認します。")
  in
  let execute session_file module_slug day period force_limit yes code =
    run (fun () ->
        if day < 1 || day > 7 then Error.failf "--day は 1 から 7 で指定してください。";
        if period < 1 || period > 9 then
          Error.failf "--period は 1 から 9 で指定してください。";
        if not (confirm yes (Printf.sprintf "%s を履修登録します。" code)) then
          Error.failf "登録を中止しました。";
        ignore
          (Twins.register ?session_file ~module_slug ~day ~period ~code
             ~force_limit ());
        Printf.printf "%s を履修登録しました。\n" code)
  in
  Cmd.v (Cmd.info "add" ~doc:"科目を履修登録します。")
    Term.(
      const execute $ session $ module_slug $ day $ period $ force_limit
      $ yes $ course_code)

let unregister_command =
  let execute session_file module_slug yes code =
    run (fun () ->
        if not (confirm yes (Printf.sprintf "%s の履修登録を削除します。" code)) then
          Error.failf "削除を中止しました。";
        ignore (Twins.unregister ?session_file ~module_slug ~code ());
        Printf.printf "%s の履修登録を削除しました。\n" code)
  in
  Cmd.v (Cmd.info "remove" ~doc:"科目の履修登録を削除します。")
    Term.(const execute $ session $ module_slug $ yes $ course_code)

let registration_command =
  Cmd.group
    (Cmd.info "registration" ~doc:"履修登録を管理します。")
    [ register_command; unregister_command ]

let notice_kind =
  Arg.(
    value
    & opt (enum [ ("classes", "classes"); ("general", "general") ]) "classes"
    & info [ "kind" ] ~docv:"KIND" ~doc:"掲示種別: classes または general。")

let notices_command =
  let unread =
    Arg.(value & flag & info [ "unread" ] ~doc:"未読の掲示だけを表示します。")
  in
  let title =
    Arg.(value & opt string "" & info [ "title" ] ~docv:"TEXT" ~doc:"表題で絞り込みます。")
  in
  let limit =
    Arg.(value & opt int 50 & info [ "limit" ] ~docv:"N")
  in
  let execute session_file kind unread title limit json =
    run (fun () ->
        if limit < 0 then Error.failf "--limit は 0 以上で指定してください。";
        let notices =
          Twins.notices ?session_file ~kind ~unread ~title ~limit ()
        in
        if json then print_json (`List (List.map Twins.notice_to_yojson notices))
        else (
          print_tsv [ "ID"; "ジャンル"; "科目"; "担当者"; "表題"; "掲示期間"; "掲載日時" ];
          List.iter
            (fun (notice : Twins.notice) ->
              print_tsv
                [
                  notice.seq; notice.genre; notice.course; notice.instructor;
                  notice.title; notice.period; notice.posted;
                ])
            notices))
  in
  Cmd.v (Cmd.info "notices" ~doc:"授業・一般掲示を検索します。")
    Term.(const execute $ session $ notice_kind $ unread $ title $ limit $ json)

let notice_command =
  let seq = Arg.(required & pos 0 (some string) None & info [] ~docv:"ID") in
  let execute session_file kind seq =
    run (fun () -> Twins.notice_detail ?session_file ~kind seq |> print_endline)
  in
  Cmd.v (Cmd.info "notice" ~doc:"掲示本文を表示します。")
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
  let all =
    Arg.(
      value & flag
      & info [ "all" ] ~doc:"未履修科目の休講情報も含めます。")
  in
  let execute session_file start_date end_date all =
    run (fun () ->
        Twins.cancellations ?session_file ~start_date ~end_date
          ~registered_only:(not all) ()
        |> print_endline)
  in
  Cmd.v (Cmd.info "cancellations" ~doc:"休講情報を検索します。")
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
  Cmd.v (Cmd.info "menu" ~doc:"既知の TWINS メニューフローを一覧表示します。")
    Term.(const execute $ json)

let raw_command =
  let flow = Arg.(required & pos 0 (some string) None & info [] ~docv:"MENU_OR_FLOW") in
  let form_name =
    Arg.(
      value
      & opt string "InputForm"
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
  let execute session_file form_name event field yes flow =
    run (fun () ->
        let fields =
          field
          |> List.map (fun assignment ->
                 match Util.parse_assignment assignment with
                 | Ok field -> field
                 | Error message -> Error.failf "%s" message)
        in
        Option.iter
          (fun event ->
            if
              not
                (confirm yes
                   (Printf.sprintf "%s にイベント %s を送信します。" flow event))
            then Error.failf "送信を中止しました。")
          event;
        Twins.raw ?session_file ~flow ~form_name ~event ~fields ()
        |> print_endline)
  in
  Cmd.v
    (Cmd.info "raw"
       ~doc:"メニューフローを開き、必要ならフォームイベントを 1 回送信します。")
    Term.(const execute $ session $ form_name $ event $ field $ yes $ flow)

let command =
  let doc = "筑波大学 TWINS を操作する OCaml 製 CLI" in
  Cmd.group (Cmd.info "twins" ~version:"0.1.0" ~doc)
    [
      auth_command; grades_command; timetable_command; registration_command;
      notices_command; notice_command; cancellations_command; menu_command;
      raw_command;
    ]

let () = exit (Cmd.eval command)
