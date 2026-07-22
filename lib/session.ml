type t = { cookies : (string, string) Hashtbl.t; path : string }

let default_path () =
  match Sys.getenv_opt "TWINS_SESSION" with
  | Some path when String.trim path <> "" -> path
  | _ ->
      let state_root =
        match Sys.getenv_opt "XDG_STATE_HOME" with
        | Some path when String.trim path <> "" -> path
        | _ ->
            let home = (Unix.getpwuid (Unix.getuid ())).Unix.pw_dir in
            Filename.concat home ".local/state"
      in
      Filename.concat state_root "twins-cli/session"

let create ?path () =
  {
    cookies = Hashtbl.create 8;
    path = Option.value path ~default:(default_path ());
  }

let load ?path () =
  let session = create ?path () in
  (if Sys.file_exists session.path then
     let channel = open_in session.path in
     Fun.protect
       ~finally:(fun () -> close_in_noerr channel)
       (fun () ->
         try
           while true do
             let line = input_line channel in
             if line <> "" && line.[0] <> '#' then
               match String.index_opt line '\t' with
               | None -> ()
               | Some index ->
                   let name = String.sub line 0 index in
                   let value =
                     String.sub line (index + 1) (String.length line - index - 1)
                   in
                   if name <> "" then Hashtbl.replace session.cookies name value
           done
         with End_of_file -> ()));
  session

let save session =
  let directory = Filename.dirname session.path in
  Util.mkdir_p directory;
  let channel =
    open_out_gen
      [ Open_wronly; Open_creat; Open_trunc; Open_text ]
      0o600 session.path
  in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () ->
      output_string channel "# TWINS session cookies; keep this file private.\n";
      Hashtbl.to_seq session.cookies
      |> List.of_seq
      |> List.sort (fun (left, _) (right, _) -> String.compare left right)
      |> List.iter (fun (name, value) ->
          Printf.fprintf channel "%s\t%s\n" name value));
  Unix.chmod session.path 0o600

let clear session =
  Hashtbl.clear session.cookies;
  if Sys.file_exists session.path then Sys.remove session.path

let is_empty session = Hashtbl.length session.cookies = 0

let cookie_header session =
  Hashtbl.to_seq session.cookies
  |> List.of_seq
  |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  |> List.map (fun (name, value) -> name ^ "=" ^ value)
  |> String.concat "; "

let update_cookie session set_cookie =
  let pair =
    match String.index_opt set_cookie ';' with
    | None -> set_cookie
    | Some index -> String.sub set_cookie 0 index
  in
  match String.index_opt pair '=' with
  | None -> ()
  | Some index ->
      let name = String.sub pair 0 index |> String.trim in
      let value =
        String.sub pair (index + 1) (String.length pair - index - 1)
        |> String.trim
      in
      if name = "" then ()
      else if value = "" then Hashtbl.remove session.cookies name
      else Hashtbl.replace session.cookies name value
