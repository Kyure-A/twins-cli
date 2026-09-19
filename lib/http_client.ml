open Lwt.Infix

type response = { status : int; body : string; uri : Uri.t }

let body response = response.body
let uri response = response.uri
let user_agent = "twins-cli/0.1 (+https://github.com/Kyure-A/twins-cli)"

let validate_uri uri =
  if
    Uri.scheme uri <> Some "https"
    || Uri.host uri
       |> Option.map String.lowercase_ascii
       <> Some "twins.tsukuba.ac.jp"
    || (Uri.port uri <> None && Uri.port uri <> Some 443)
    || Uri.userinfo uri <> None
  then
    Internal_error.protocolf
      "blocked HTTP target outside the TWINS HTTPS origin"

let headers session uri extra =
  let headers = Cohttp.Header.remove extra "cookie" in
  let headers = Cohttp.Header.add headers "user-agent" user_agent in
  let cookie = Session.cookie_header session uri in
  if cookie = "" then headers else Cohttp.Header.add headers "cookie" cookie

let update_cookies session uri headers =
  Cohttp.Header.get_multi headers "set-cookie"
  |> List.iter (Session.update_cookie session ~origin:uri)

let redirect_method status meth body =
  match (status, meth) with
  | 303, `HEAD -> (`HEAD, None)
  | 303, _ -> (`GET, None)
  | (301 | 302), (`POST | `PUT | `PATCH | `DELETE) -> (`GET, None)
  | _ -> (meth, body)

let send ~headers meth uri body =
  let body = Option.map Cohttp_lwt.Body.of_string body in
  Cohttp_lwt_unix.Client.call ?body ~headers meth uri
  >>= fun (response, response_body) ->
  Cohttp_lwt.Body.to_string response_body >|= fun body ->
  ( Cohttp.Response.status response |> Cohttp.Code.code_of_status,
    Cohttp.Response.headers response,
    body )

let rec request_lwt ?(send = send) ?body
    ?(extra_headers = Cohttp.Header.init ()) session meth uri redirects =
  validate_uri uri;
  if redirects < 0 then Internal_error.protocolf "too many HTTP redirects"
  else
    let request_headers = headers session uri extra_headers in
    send ~headers:request_headers meth uri body
    >>= fun (status, response_headers, body_string) ->
    update_cookies session uri response_headers;
    match (status, Cohttp.Header.get response_headers "location") with
    | (301 | 302 | 303 | 307 | 308), Some location ->
        let next_uri = Uri.resolve "https" uri (Uri.of_string location) in
        (* Validate before even constructing a replay; this protects login form
           credentials for 307/308 and rejects HTTPS downgrade redirects. *)
        validate_uri next_uri;
        let next_method, next_body = redirect_method status meth body in
        let extra_headers =
          if next_body = None then
            Cohttp.Header.remove extra_headers "content-type" |> fun headers ->
            Cohttp.Header.remove headers "content-length"
          else extra_headers
        in
        request_lwt ~send ?body:next_body ~extra_headers session next_method
          next_uri (redirects - 1)
    | _ -> Lwt.return { status; body = body_string; uri }

let timeout_seconds () =
  match Sys.getenv_opt "TWINS_HTTP_TIMEOUT" with
  | None -> 60.
  | Some value -> (
      match float_of_string_opt value with
      | Some seconds
        when Float.is_finite seconds && seconds >= 1. && seconds <= 300. ->
          seconds
      | _ -> Internal_error.invalidf "TWINS_HTTP_TIMEOUT must be 1..300 seconds"
      )

let with_timeout seconds operation =
  try Lwt_main.run (Lwt_unix.with_timeout seconds operation)
  with Lwt_unix.Timeout ->
    Internal_error.protocolf
      "TWINS HTTP request timed out; a submitted change may have succeeded; \
       inspect current state before retrying"

let request ?body ?extra_headers session meth uri =
  with_timeout (timeout_seconds ()) (fun () ->
      request_lwt ?body ?extra_headers session meth uri 8)

let get session uri = request session `GET uri

let encode_form fields =
  fields
  |> List.map (fun (name, value) -> (name, [ value ]))
  |> Uri.encoded_of_query

let post_form session uri fields =
  let body = encode_form fields in
  let headers =
    Cohttp.Header.init_with "content-type"
      "application/x-www-form-urlencoded; charset=UTF-8"
  in
  request ~body ~extra_headers:headers session `POST uri

let ensure_success response =
  if response.status < 200 || response.status >= 300 then
    Internal_error.http ~status:response.status
      ~uri:(Uri.with_query (Uri.with_fragment response.uri None) [])
