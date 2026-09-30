type t =
  | Authentication_required
  | Invalid_argument of string
  | Http_error of { status : int; uri : Uri.t }
  | Protocol_error of string
  | Cancelled of string
  | Io_error of string
  | Unexpected_error of string

let to_string = function
  | Authentication_required ->
      "TWINS session is missing or expired; run `twins auth login`"
  | Invalid_argument message
  | Protocol_error message
  | Cancelled message
  | Io_error message
  | Unexpected_error message ->
      message
  | Http_error { status; uri } ->
      Printf.sprintf "TWINS returned HTTP %d for %s" status (Uri.to_string uri)

let to_safe_yojson error =
  let code, details =
    match error with
    | Authentication_required -> ("authentication_required", [])
    | Invalid_argument _ -> ("invalid_argument", [])
    | Http_error { status; _ } -> ("http_error", [ ("httpStatus", `Int status) ])
    | Protocol_error _ -> ("protocol_error", [])
    | Cancelled _ -> ("cancelled", [])
    | Io_error _ -> ("io_error", [])
    | Unexpected_error _ -> ("unexpected_error", [])
  in
  `Assoc [ ("error", `Assoc (("code", `String code) :: details)) ]

let of_exn = function
  | Sys_error message -> Some (Io_error message)
  | Unix.Unix_error (error, function_name, argument) ->
      Some
        (Io_error
           (Printf.sprintf "%s: %s (%s)" function_name
              (Unix.error_message error) argument))
  | Out_of_memory | Stack_overflow | Sys.Break -> None
  | exn -> Some (Unexpected_error (Printexc.to_string exn))
