type cookie = {
  name : string;
  value : string;
  domain : string;
  path : string;
  secure : bool;
  host_only : bool;
  expires : float option;
  created : float;
}

type t = { mutable cookies : cookie list; path : string }

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
  { cookies = []; path = Option.value path ~default:(default_path ()) }

let expired ~now cookie =
  Option.fold ~none:false ~some:(fun expires -> expires <= now) cookie.expires

let prune ?(now = Unix.time ()) session =
  session.cookies <-
    List.filter (fun cookie -> not (expired ~now cookie)) session.cookies

let valid_name value =
  value <> ""
  && String.for_all
       (fun c ->
         Char.code c > 32
         && Char.code c < 127
         && not (String.contains "()<>@,;:\\\"/[]?={} " c))
       value

let valid_value value =
  String.for_all
    (fun c ->
      Char.code c >= 32
      && Char.code c < 127
      && c <> ';' && c <> '\\' && c <> ',')
    value

let cookie_to_json cookie =
  `Assoc
    [
      ("name", `String cookie.name);
      ("value", `String cookie.value);
      ("domain", `String cookie.domain);
      ("path", `String cookie.path);
      ("secure", `Bool cookie.secure);
      ("host_only", `Bool cookie.host_only);
      ( "expires",
        Option.fold ~none:`Null ~some:(fun v -> `Float v) cookie.expires );
      ("created", `Float cookie.created);
    ]

let cookie_of_json json =
  let open Yojson.Safe.Util in
  let cookie =
    {
      name = json |> member "name" |> to_string;
      value = json |> member "value" |> to_string;
      domain = json |> member "domain" |> to_string;
      path = json |> member "path" |> to_string;
      secure = json |> member "secure" |> to_bool;
      host_only = json |> member "host_only" |> to_bool;
      expires = json |> member "expires" |> to_option to_number;
      created = json |> member "created" |> to_number;
    }
  in
  if
    (not (valid_name cookie.name && valid_value cookie.value))
    || cookie.domain = ""
    || (not (String.starts_with ~prefix:"/" cookie.path))
    || (not (Float.is_finite cookie.created))
    || Option.fold ~none:false
         ~some:(fun v -> not (Float.is_finite v))
         cookie.expires
  then failwith "invalid cookie";
  cookie

let load ?path ?(allow_incompatible = false) () =
  let session = create ?path () in
  (if Sys.file_exists session.path then
     (* Read outside the parser handler so filesystem errors retain their type.
       Old unscoped cookies are never guessed, sent, deleted, or overwritten. *)
     let channel = open_in session.path in
     let source =
       Fun.protect
         ~finally:(fun () -> close_in_noerr channel)
         (fun () -> really_input_string channel (in_channel_length channel))
     in
     try
       let open Yojson.Safe.Util in
       let json = Yojson.Safe.from_string source in
       if json |> member "version" |> to_int <> 2 then failwith "version";
       session.cookies <-
         json |> member "cookies" |> to_list |> List.map cookie_of_json;
       prune session
     with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ | Failure _ ->
       if not allow_incompatible then
         Internal_error.protocolf
           "saved TWINS session format is unscoped or invalid; run `twins auth \
            login` (existing file retained)");
  session

let save session =
  prune session;
  let directory = Filename.dirname session.path in
  Util.mkdir_p directory;
  let temporary, channel =
    Filename.open_temp_file ~temp_dir:directory ~perms:0o600 ".twins-session-"
      ".json"
  in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr channel;
      if Sys.file_exists temporary then Sys.remove temporary)
    (fun () ->
      Yojson.Safe.to_channel channel
        (`Assoc
           [
             ("version", `Int 2);
             ("cookies", `List (List.map cookie_to_json session.cookies));
           ]);
      output_char channel '\n';
      close_out channel;
      Unix.rename temporary session.path)

let authenticate ?path operation =
  let session = create ?path () in
  operation session;
  save session

let clear session =
  session.cookies <- [];
  if Sys.file_exists session.path then Sys.remove session.path

let is_empty session =
  prune session;
  session.cookies = []

let domain_matches ~host cookie =
  host = cookie.domain
  || (not cookie.host_only)
     && String.ends_with ~suffix:("." ^ cookie.domain) host

let path_matches ~request_path (cookie : cookie) =
  request_path = cookie.path
  || String.starts_with ~prefix:cookie.path request_path
     && (String.ends_with ~suffix:"/" cookie.path
        || String.length request_path > String.length cookie.path
           && request_path.[String.length cookie.path] = '/')

let cookie_header ?(now = Unix.time ()) session uri =
  prune ~now session;
  let host =
    Uri.host uri |> Option.value ~default:"" |> String.lowercase_ascii
  in
  let request_path = match Uri.path uri with "" -> "/" | path -> path in
  session.cookies
  |> List.filter (fun cookie ->
      domain_matches ~host cookie
      && path_matches ~request_path cookie
      && ((not cookie.secure) || Uri.scheme uri = Some "https"))
  |> List.stable_sort (fun (a : cookie) (b : cookie) ->
      let order = compare (String.length b.path) (String.length a.path) in
      if order = 0 then Float.compare a.created b.created else order)
  |> List.map (fun cookie -> cookie.name ^ "=" ^ cookie.value)
  |> String.concat "; "

let default_cookie_path request_path =
  match String.rindex_opt request_path '/' with
  | Some index when index > 0 -> String.sub request_path 0 index
  | _ -> "/"

let split_pair value =
  match String.index_opt value '=' with
  | None -> (String.trim value, "")
  | Some i ->
      ( String.sub value 0 i |> String.trim,
        String.sub value (i + 1) (String.length value - i - 1) |> String.trim )

(* RFC 6265 cookie-date tokens. Compute UTC seconds without depending on the
   machine's local timezone or DST. Accept the common RFC 1123/850/asctime forms. *)
let cookie_date value =
  let tokens =
    String.map
      (fun c ->
        match c with
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | ':' -> c
        | _ -> ' ')
      value
    |> String.split_on_char ' '
    |> List.filter (( <> ) "")
  in
  let months =
    [
      "jan";
      "feb";
      "mar";
      "apr";
      "may";
      "jun";
      "jul";
      "aug";
      "sep";
      "oct";
      "nov";
      "dec";
    ]
  in
  let month =
    List.find_map
      (fun token ->
        List.find_index (( = ) (String.lowercase_ascii token)) months
        |> Option.map (( + ) 1))
      tokens
  in
  let clock =
    List.find_map
      (fun token ->
        match String.split_on_char ':' token with
        | [ h; m; s ] -> (
            match
              (int_of_string_opt h, int_of_string_opt m, int_of_string_opt s)
            with
            | Some h, Some m, Some s -> Some (h, m, s)
            | _ -> None)
        | _ -> None)
      tokens
  in
  let numbers = List.filter_map int_of_string_opt tokens in
  match (month, clock, numbers) with
  | Some month, Some (hour, minute, second), [ day; year ] ->
      let year =
        if year >= 70 && year <= 99 then year + 1900
        else if year >= 0 && year <= 69 then year + 2000
        else year
      in
      let leap = year mod 400 = 0 || (year mod 4 = 0 && year mod 100 <> 0) in
      let days =
        match month with
        | 2 -> if leap then 29 else 28
        | 4 | 6 | 9 | 11 -> 30
        | _ -> 31
      in
      if
        year < 1601 || day < 1 || day > days || hour < 0 || hour > 23
        || minute < 0 || minute > 59 || second < 0 || second > 59
      then None
      else
        let y = if month <= 2 then year - 1 else year in
        let era = y / 400 in
        let yoe = y - (era * 400) in
        let m = if month > 2 then month - 3 else month + 9 in
        let doy = (((153 * m) + 2) / 5) + day - 1 in
        let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
        let days = (era * 146097) + doe - 719468 in
        Some
          ((float_of_int days *. 86400.)
          +. float_of_int ((hour * 3600) + (minute * 60) + second))
  | _ -> None

let update_cookie ?(now = Unix.time ()) session ~origin set_cookie =
  match String.split_on_char ';' set_cookie |> List.map String.trim with
  | [] -> ()
  | pair :: attributes ->
      let name, value = split_pair pair in
      let host =
        Uri.host origin |> Option.value ~default:"" |> String.lowercase_ascii
      in
      let attributes =
        List.map
          (fun attr ->
            let key, value = split_pair attr in
            (String.lowercase_ascii key, value))
          attributes
      in
      let attribute name = List.assoc_opt name attributes in
      let domain, host_only =
        match attribute "domain" with
        | None -> (host, true)
        | Some domain ->
            let domain = String.lowercase_ascii domain in
            ( (if String.starts_with ~prefix:"." domain then
                 String.sub domain 1 (String.length domain - 1)
               else domain),
              false )
      in
      (* TWINS uses one university origin. Only its verified parent domain may
         broaden a cookie; never accept public suffixes or unrelated domains. *)
      let allowed_domain =
        domain = host
        || domain = "tsukuba.ac.jp"
           && String.ends_with ~suffix:".tsukuba.ac.jp" host
      in
      let path =
        match attribute "path" with
        | Some path when String.starts_with ~prefix:"/" path -> path
        | _ -> default_cookie_path (Uri.path origin)
      in
      let secure = List.mem_assoc "secure" attributes in
      let expires =
        match Option.bind (attribute "max-age") Int64.of_string_opt with
        | Some age when age <= 0L -> Some 0.
        | Some age -> Some (now +. Int64.to_float age)
        | None -> Option.bind (attribute "expires") cookie_date
      in
      let valid_prefix =
        ((not (String.starts_with ~prefix:"__Secure-" name)) || secure)
        && ((not (String.starts_with ~prefix:"__Host-" name))
           || (secure && host_only && attribute "path" = Some "/"))
      in
      if
        String.contains pair '=' && valid_name name && valid_value value
        && host <> "" && allowed_domain && valid_prefix
        && ((not secure) || Uri.scheme origin = Some "https")
      then (
        let same cookie =
          cookie.name = name && cookie.domain = domain && cookie.path = path
        in
        let created =
          match List.find_opt same session.cookies with
          | Some cookie -> cookie.created
          | None -> now
        in
        let cookie =
          { name; value; domain; path; secure; host_only; expires; created }
        in
        session.cookies <-
          List.filter (fun cookie -> not (same cookie)) session.cookies;
        if not (expired ~now cookie) then
          session.cookies <- session.cookies @ [ cookie ])
