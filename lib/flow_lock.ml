(* The server's notice flow is shared by both notice kinds in one login. Keep
   the lock file empty and persistent: unlinking it could give waiting readers
   different inodes. Only the adjacent lock file is opened, never the session. *)
let active = Hashtbl.create 4

let lock_path session_path =
  let directory =
    try Unix.realpath (Filename.dirname session_path)
    with Unix.Unix_error (Unix.ENOENT, _, _) ->
      (* An absent session directory cannot contain a saved login. Preserve the
         public unauthenticated result without creating state just for a lock. *)
      Internal_error.authentication_required ()
  in
  Filename.concat directory (Filename.basename session_path ^ ".notices.lock")

let invalid_file () =
  Internal_error.protocolf "unsafe TWINS notice flow lock file"

let valid_stat stat =
  stat.Unix.st_kind = Unix.S_REG
  && stat.Unix.st_uid = Unix.getuid ()
  && stat.Unix.st_perm = 0o600 && stat.Unix.st_nlink = 1
  && stat.Unix.st_size = 0

let same_file first second =
  first.Unix.st_dev = second.Unix.st_dev
  && first.Unix.st_ino = second.Unix.st_ino

let close_noerr fd = try Unix.close fd with Unix.Unix_error _ -> ()

let open_lock path =
  let rec attempt remaining =
    if remaining = 0 then invalid_file ();
    let before =
      try Some (Unix.lstat path)
      with Unix.Unix_error (Unix.ENOENT, _, _) -> None
    in
    Option.iter
      (fun stat -> if not (valid_stat stat) then invalid_file ())
      before;
    let flags =
      [ Unix.O_RDWR; Unix.O_CLOEXEC; Unix.O_NONBLOCK ]
      @ match before with None -> [ Unix.O_CREAT; Unix.O_EXCL ] | Some _ -> []
    in
    match Unix.openfile path flags 0o600 with
    | fd -> (
        try
          let opened = Unix.fstat fd in
          let after = Unix.lstat path in
          if
            (not
               (valid_stat opened && valid_stat after && same_file opened after))
            || Option.fold ~none:false
                 ~some:(fun stat -> not (same_file stat opened))
                 before
          then invalid_file ();
          fd
        with exn ->
          close_noerr fd;
          raise exn)
    | exception Unix.Unix_error ((Unix.EEXIST | Unix.ENOENT), _, _) ->
        attempt (remaining - 1)
  in
  attempt 3

let with_lock ~session_path ?(timeout_seconds = 120.) operation =
  if
    (not (Float.is_finite timeout_seconds))
    || timeout_seconds <= 0. || timeout_seconds > 300.
  then
    Internal_error.invalidf
      "notice flow lock timeout must be > 0 and <= 300 seconds";
  let path = lock_path session_path in
  let pid = Unix.getpid () in
  if Hashtbl.find_opt active path = Some pid then
    Internal_error.invalidf "nested TWINS notice flow lock acquisition";
  let fd = open_lock path in
  let held = ref false in
  Fun.protect
    ~finally:(fun () ->
      (if !held then
         try Unix.lockf fd Unix.F_ULOCK 0 with Unix.Unix_error _ -> ());
      Hashtbl.remove active path;
      close_noerr fd)
    (fun () ->
      let deadline = Unix.gettimeofday () +. timeout_seconds in
      let rec acquire () =
        try Unix.lockf fd Unix.F_TLOCK 0
        with
        | Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN | Unix.EINTR), _, _) ->
          let remaining = deadline -. Unix.gettimeofday () in
          if remaining <= 0. then
            Internal_error.timeoutf
              "timed out waiting for the TWINS notice flow lock";
          (try ignore (Unix.select [] [] [] (min 0.05 remaining))
           with Unix.Unix_error (Unix.EINTR, _, _) -> ());
          acquire ()
      in
      acquire ();
      held := true;
      let opened = Unix.fstat fd in
      let current = Unix.lstat path in
      if not (valid_stat current && same_file opened current) then
        invalid_file ();
      Hashtbl.replace active path pid;
      operation ())
