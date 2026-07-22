exception E of string

let failf fmt = Printf.ksprintf (fun message -> raise (E message)) fmt

let protect f =
  try Ok (f ()) with
  | E message -> Error message
  | Sys_error message -> Error message
  | Unix.Unix_error (error, function_name, argument) ->
      Error
        (Printf.sprintf "%s: %s (%s)" function_name
           (Unix.error_message error) argument)
