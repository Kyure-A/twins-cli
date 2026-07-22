open Lwt.Infix

type response = {
  status : int;
  headers : Cohttp.Header.t;
  body : string;
  uri : Uri.t;
}

let user_agent = "twins-cli/0.1 (+https://github.com/Kyure-A/twins-cli)"

let headers session extra =
  let headers = Cohttp.Header.add extra "user-agent" user_agent in
  let cookie = Session.cookie_header session in
  if cookie = "" then headers else Cohttp.Header.add headers "cookie" cookie

let update_cookies session headers =
  Cohttp.Header.get_multi headers "set-cookie"
  |> List.iter (Session.update_cookie session)

let redirect_method status meth body =
  match (status, meth) with
  | 303, _ -> (`GET, None)
  | (301 | 302), (`POST | `PUT | `PATCH | `DELETE) -> (`GET, None)
  | _ -> (meth, body)

let rec request_lwt ?body ?(extra_headers = Cohttp.Header.init ()) session meth
    uri redirects =
  if redirects < 0 then Lwt.fail (Error.E "too many HTTP redirects")
  else
    let request_headers = headers session extra_headers in
    Cohttp_lwt_unix.Client.call ?body ~headers:request_headers meth uri
    >>= fun (response, response_body) ->
    let response_headers = Cohttp.Response.headers response in
    let status = Cohttp.Response.status response |> Cohttp.Code.code_of_status in
    update_cookies session response_headers;
    Cohttp_lwt.Body.to_string response_body >>= fun body_string ->
    match (status, Cohttp.Header.get response_headers "location") with
    | (301 | 302 | 303 | 307 | 308), Some location ->
        let next_uri = Uri.resolve "" uri (Uri.of_string location) in
        let next_method, next_body = redirect_method status meth body in
        request_lwt ?body:next_body ~extra_headers session next_method next_uri
          (redirects - 1)
    | _ ->
        Lwt.return
          { status; headers = response_headers; body = body_string; uri }

let request ?body ?extra_headers session meth uri =
  Lwt_main.run (request_lwt ?body ?extra_headers session meth uri 8)

let get session uri = request session `GET uri

let encode_form fields =
  fields
  |> List.map (fun (name, value) -> (name, [ value ]))
  |> Uri.encoded_of_query

let post_form session uri fields =
  let encoded = encode_form fields in
  let headers =
    Cohttp.Header.init_with "content-type"
      "application/x-www-form-urlencoded; charset=UTF-8"
  in
  let body = Cohttp_lwt.Body.of_string encoded in
  request ~body ~extra_headers:headers session `POST uri

let ensure_success response =
  if response.status < 200 || response.status >= 300 then
    Error.failf "TWINS returned HTTP %d for %s" response.status
      (Uri.to_string response.uri)
