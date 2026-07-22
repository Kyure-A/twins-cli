exception E of Error.t

let fail error = raise (E error)

let invalidf fmt =
  Printf.ksprintf (fun message -> fail (Error.Invalid_argument message)) fmt

let protocolf fmt =
  Printf.ksprintf (fun message -> fail (Error.Protocol_error message)) fmt

let authentication_required () = fail Error.Authentication_required
let http ~status ~uri = fail (Error.Http_error { status; uri })

let protect f =
  try Ok (f ()) with
  | E error -> Error error
  | exn -> (
      match Error.of_exn exn with
      | Some error -> Error error
      | None -> raise exn)
