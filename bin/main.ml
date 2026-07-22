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

let session_file =
  let doc =
    "Store session cookies in $(docv). The default is \
     $XDG_STATE_HOME/twins-cli/session."
  in
  Arg.(value & opt (some string) None & info [ "session-file" ] ~docv:"PATH" ~doc)

let json =
  Arg.(value & flag & info [ "json" ] ~doc:"Print machine-readable JSON.")

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
    & info [ "u"; "username" ] ~docv:"USERNAME"
        ~doc:"TWINS username. Defaults to $TWINS_USERNAME, then an interactive prompt.")

let login_command =
  let execute session_file username =
    run (fun () ->
        let username =
          match (username, Sys.getenv_opt "TWINS_USERNAME") with
          | Some value, _ | None, Some value when String.trim value <> "" -> value
          | _ -> Util.prompt_line "TWINS username: "
        in
        let password = Util.read_password "TWINS password: " in
        Twins.login ?session_file ~username ~password ();
        print_endline "Logged in; the session cookie was saved locally.")
  in
  let term = Term.(const execute $ session_file $ username) in
  Cmd.v (Cmd.info "login" ~doc:"Log in and save a TWINS session.") term

let logout_command =
  let execute session_file =
    run (fun () ->
        Twins.logout ?session_file ();
        print_endline "Logged out; the local session was removed.")
  in
  Cmd.v (Cmd.info "logout" ~doc:"Log out and remove the saved session.")
    Term.(const execute $ session_file)

let status_command =
  let execute session_file =
    run (fun () ->
        let status = Twins.status ?session_file () in
        if status.logged_in then print_endline "logged-in"
        else print_endline "logged-out")
  in
  Cmd.v (Cmd.info "status" ~doc:"Check whether the saved session is valid.")
    Term.(const execute $ session_file)

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
  Cmd.v (Cmd.info "grades" ~doc:"List grades.")
    Term.(const execute $ session_file $ json)

let module_slug =
  let choices = List.map (fun (item : Twins.module_code) -> item.slug) Twins.modules in
  let doc = "Academic module: " ^ String.concat ", " choices ^ "." in
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
  Cmd.v (Cmd.info "timetable" ~doc:"Show the registered timetable.")
    Term.(const execute $ session_file $ module_slug $ json)

let course_code =
  Arg.(required & pos 0 (some string) None & info [] ~docv:"COURSE_CODE")

let yes =
  Arg.(
    value & flag
    & info [ "yes" ]
        ~doc:"Actually submit the mutation. Required for registration changes.")

let day =
  Arg.(
    required
    & opt (some int) None
    & info [ "day" ] ~docv:"1..7" ~doc:"Day number used by TWINS (Monday is 1).")

let period =
  Arg.(
    required
    & opt (some int) None
    & info [ "period" ] ~docv:"1..9" ~doc:"Starting class period.")

let require_yes yes =
  if not yes then Error.failf "refusing to change registration without --yes"

let register_command =
  let force_limit =
    Arg.(
      value & flag
      & info [ "force-limit" ]
          ~doc:"Accept TWINS' annual credit-limit override, if it appears.")
  in
  let execute session_file module_slug day period force_limit yes code =
    run (fun () ->
        require_yes yes;
        if day < 1 || day > 7 then Error.failf "--day must be between 1 and 7";
        if period < 1 || period > 9 then
          Error.failf "--period must be between 1 and 9";
        ignore
          (Twins.register ?session_file ~module_slug ~day ~period ~code
             ~force_limit ());
        Printf.printf "Registered %s.\n" code)
  in
  Cmd.v (Cmd.info "register" ~doc:"Register a course.")
    Term.(
      const execute $ session_file $ module_slug $ day $ period $ force_limit
      $ yes $ course_code)

let unregister_command =
  let execute session_file module_slug yes code =
    run (fun () ->
        require_yes yes;
        ignore (Twins.unregister ?session_file ~module_slug ~code ());
        Printf.printf "Unregistered %s.\n" code)
  in
  Cmd.v (Cmd.info "unregister" ~doc:"Delete a course registration.")
    Term.(const execute $ session_file $ module_slug $ yes $ course_code)

let notice_kind =
  Arg.(
    value
    & opt (enum [ ("classes", "classes"); ("general", "general") ]) "classes"
    & info [ "kind" ] ~docv:"KIND" ~doc:"Notice kind: classes or general.")

let notices_command =
  let unread =
    Arg.(value & flag & info [ "unread" ] ~doc:"Only show unread notices.")
  in
  let title =
    Arg.(value & opt string "" & info [ "title" ] ~docv:"TEXT" ~doc:"Filter by title.")
  in
  let limit =
    Arg.(value & opt int 50 & info [ "limit" ] ~docv:"N")
  in
  let execute session_file kind unread title limit json =
    run (fun () ->
        if limit < 0 then Error.failf "--limit must not be negative";
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
  Cmd.v (Cmd.info "notices" ~doc:"Search class or general notices.")
    Term.(const execute $ session_file $ notice_kind $ unread $ title $ limit $ json)

let notice_command =
  let seq = Arg.(required & pos 0 (some string) None & info [] ~docv:"ID") in
  let execute session_file kind seq =
    run (fun () -> Twins.notice_detail ?session_file ~kind seq |> print_endline)
  in
  Cmd.v (Cmd.info "notice" ~doc:"Show one notice body.")
    Term.(const execute $ session_file $ notice_kind $ seq)

let today () =
  let value = Unix.localtime (Unix.time ()) in
  Printf.sprintf "%04d-%02d-%02d" (value.tm_year + 1900) (value.tm_mon + 1)
    value.tm_mday

let cancellations_command =
  let date_option names doc =
    Arg.(value & opt string (today ()) & info names ~docv:"YYYY-MM-DD" ~doc)
  in
  let start_date = date_option [ "from" ] "First date to search." in
  let end_date = date_option [ "to" ] "Last date to search." in
  let all =
    Arg.(
      value & flag
      & info [ "all" ] ~doc:"Include cancellations for unregistered courses.")
  in
  let execute session_file start_date end_date all =
    run (fun () ->
        Twins.cancellations ?session_file ~start_date ~end_date
          ~registered_only:(not all) ()
        |> print_endline)
  in
  Cmd.v (Cmd.info "cancellations" ~doc:"Search class cancellations.")
    Term.(const execute $ session_file $ start_date $ end_date $ all)

let menu_command =
  let execute () =
    Twins.menu
    |> List.iter (fun (item : Twins.menu_item) ->
           Printf.printf "%s\t%s\n" item.name item.flow)
  in
  Cmd.v (Cmd.info "menu" ~doc:"List known TWINS menu flows.") Term.(const execute $ const ())

let raw_command =
  let flow = Arg.(required & pos 0 (some string) None & info [] ~docv:"MENU_OR_FLOW") in
  let form_name =
    Arg.(value & opt string "InputForm" & info [ "form" ] ~docv:"NAME")
  in
  let event = Arg.(value & opt (some string) None & info [ "event" ] ~docv:"EVENT") in
  let field =
    Arg.(value & opt_all string [] & info [ "field" ] ~docv:"NAME=VALUE")
  in
  let execute session_file form_name event field flow =
    run (fun () ->
        let fields =
          field
          |> List.map (fun assignment ->
                 match Util.parse_assignment assignment with
                 | Ok field -> field
                 | Error message -> Error.failf "%s" message)
        in
        Twins.raw ?session_file ~flow ~form_name ~event ~fields ()
        |> print_endline)
  in
  Cmd.v
    (Cmd.info "raw"
       ~doc:"Open a known menu flow and optionally submit one form event.")
    Term.(const execute $ session_file $ form_name $ event $ field $ flow)

let command =
  let doc = "Unofficial command-line client for the University of Tsukuba TWINS" in
  Cmd.group (Cmd.info "twins" ~version:"0.1.0" ~doc)
    [
      login_command; logout_command; status_command; grades_command;
      timetable_command; register_command; unregister_command; notices_command;
      notice_command; cancellations_command; menu_command; raw_command;
    ]

let () = exit (Cmd.eval command)
