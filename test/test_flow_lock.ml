let with_directory operation =
  let directory = Filename.temp_file "twins-flow-lock-" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  Fun.protect
    ~finally:(fun () ->
      Sys.readdir directory
      |> Array.iter (fun name ->
          let path = Filename.concat directory name in
          if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then Unix.rmdir path
          else Sys.remove path);
      Unix.rmdir directory)
    (fun () -> operation directory)

let session directory name = Filename.concat directory name

let write fd value =
  let bytes = Bytes.of_string value in
  if Unix.write fd bytes 0 (Bytes.length bytes) <> Bytes.length bytes then
    failwith "short pipe write"

let read fd =
  let ready, _, _ = Unix.select [ fd ] [] [] 5. in
  if ready = [] then failwith "child synchronization timed out";
  let bytes = Bytes.create 1 in
  if Unix.read fd bytes 0 1 <> 1 then failwith "child pipe closed";
  Bytes.to_string bytes

let wait child =
  match snd (Unix.waitpid [] child) with
  | Unix.WEXITED 0 -> ()
  | _ -> Alcotest.fail "child lock check failed"

let fork operation =
  match Unix.fork () with
  | 0 -> (
      try
        operation ();
        Unix._exit 0
      with _ -> Unix._exit 1)
  | child -> child

let with_child operation check =
  let child = fork operation in
  Fun.protect
    ~finally:(fun () ->
      match Unix.waitpid [ Unix.WNOHANG ] child with
      | 0, _ ->
          Unix.kill child Sys.sigkill;
          ignore (Unix.waitpid [] child)
      | _ -> ()
      | exception Unix.Unix_error (Unix.ECHILD, _, _) -> ())
    (fun () -> check child)

let with_pipes operation =
  let a, b = Unix.pipe ~cloexec:true () in
  let c, d = Unix.pipe ~cloexec:true () in
  Fun.protect
    ~finally:(fun () -> List.iter Unix.close [ a; b; c; d ])
    (fun () -> operation a b c d)

let test_exclusion_and_empty () =
  with_directory (fun directory ->
      let path = session directory "session" in
      with_pipes (fun ready_read ready_write release_read release_write ->
          with_child
            (fun () ->
              Flow_lock.with_lock ~session_path:path (fun () ->
                  write ready_write "R";
                  ignore (read release_read)))
            (fun child ->
              ignore (read ready_read);
              let entered = ref false in
              (match
                 Internal_error.protect (fun () ->
                     Flow_lock.with_lock ~session_path:path ~timeout_seconds:0.1
                       (fun () -> entered := true))
               with
              | Error (Error.Timeout _) -> ()
              | _ -> Alcotest.fail "contending process must time out");
              Alcotest.(check bool) "operation not entered" false !entered;
              write release_write "R";
              wait child;
              Flow_lock.with_lock ~session_path:path (fun () -> entered := true);
              Alcotest.(check bool) "lock released" true !entered));
      let lock = Flow_lock.lock_path path in
      let stat = Unix.stat lock in
      Alcotest.(check int) "empty file" 0 stat.Unix.st_size;
      Alcotest.(check int) "private mode" 0o600 stat.Unix.st_perm;
      Alcotest.(check bool) "cookie file untouched" false (Sys.file_exists path))

let test_independent_sessions () =
  with_directory (fun directory ->
      with_pipes (fun ready_read ready_write release_read release_write ->
          with_child
            (fun () ->
              Flow_lock.with_lock ~session_path:(session directory "one")
                (fun () ->
                  write ready_write "R";
                  ignore (read release_read)))
            (fun child ->
              ignore (read ready_read);
              let entered = ref false in
              Flow_lock.with_lock ~session_path:(session directory "two")
                ~timeout_seconds:0.1 (fun () -> entered := true);
              Alcotest.(check bool)
                "independent operation entered" true !entered;
              write release_write "R";
              wait child)))

let test_failure_release () =
  with_directory (fun directory ->
      let path = session directory "session" in
      (try Flow_lock.with_lock ~session_path:path (fun () -> failwith "fixture")
       with Failure _ -> ());
      with_child
        (fun () ->
          Flow_lock.with_lock ~session_path:path ~timeout_seconds:0.1 (fun () ->
              ()))
        wait)

let test_unsafe_files () =
  with_directory (fun directory ->
      let path = session directory "session" in
      let lock = Flow_lock.lock_path path in
      let reject () =
        let entered = ref false in
        (match
           Internal_error.protect (fun () ->
               Flow_lock.with_lock ~session_path:path (fun () ->
                   entered := true))
         with
        | Error (Error.Protocol_error _) -> ()
        | _ -> Alcotest.fail "unsafe lock path must be rejected");
        Alcotest.(check bool) "unsafe operation not entered" false !entered
      in
      Unix.symlink (session directory "missing") lock;
      reject ();
      Sys.remove lock;
      Unix.mkdir lock 0o700;
      reject ();
      Unix.rmdir lock;
      let fd =
        Unix.openfile lock [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
      in
      write fd "data";
      Unix.close fd;
      reject ();
      Sys.remove lock;
      let fd =
        Unix.openfile lock [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
      in
      Unix.close fd;
      Unix.chmod lock 0o644;
      reject ())

let test_nested_lock () =
  with_directory (fun directory ->
      let path = session directory "session" in
      Flow_lock.with_lock ~session_path:path (fun () ->
          match
            Internal_error.protect (fun () ->
                Flow_lock.with_lock ~session_path:path (fun () -> ()))
          with
          | Error (Error.Invalid_argument _) -> ()
          | _ -> Alcotest.fail "nested lock must be rejected"))

let test_missing_session_directory () =
  with_directory (fun directory ->
      let missing = Filename.concat directory "absent" in
      let entered = ref false in
      (match
         Internal_error.protect (fun () ->
             Flow_lock.with_lock
               ~session_path:(Filename.concat missing "session") (fun () ->
                 entered := true))
       with
      | Error Error.Authentication_required -> ()
      | _ -> Alcotest.fail "missing session directory must be unauthenticated");
      Alcotest.(check bool) "operation not entered" false !entered;
      Alcotest.(check bool)
        "no state directory created" false (Sys.file_exists missing))

let () =
  Alcotest.run "notice-flow-lock"
    [
      ( "locking",
        [
          Alcotest.test_case "process exclusion, timeout and empty metadata"
            `Quick test_exclusion_and_empty;
          Alcotest.test_case "independent session paths overlap" `Quick
            test_independent_sessions;
          Alcotest.test_case "exception releases lock" `Quick
            test_failure_release;
          Alcotest.test_case "unsafe lock paths fail closed" `Quick
            test_unsafe_files;
          Alcotest.test_case "nested lock rejected" `Quick test_nested_lock;
          Alcotest.test_case "missing session directory is unauthenticated"
            `Quick test_missing_session_directory;
        ] );
    ]
