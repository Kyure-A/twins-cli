type t =
  | Authentication_required
  | Invalid_argument of string
  | Http_error of { status : int; uri : Uri.t }
  | Protocol_error of string
  | Cancelled of string
  | Io_error of string
  | Unexpected_error of string

val to_string : t -> string
val of_exn : exn -> t option
