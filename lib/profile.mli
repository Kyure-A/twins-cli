type stage =
  | Session_load
  | Session_save
  | Initial_flow
  | Module_fetch
  | Html_parse
  | Page_check
  | Selection_check
  | Timetable_parse
  | Json_output
  | Text_output

type module_

val module_of_slug : string -> module_ option
val enabled : unit -> bool
val run : enabled:bool -> emit:(Yojson.Safe.t -> unit) -> (unit -> 'a) -> 'a
val measure : ?module_:module_ -> stage -> (unit -> 'a) -> 'a
val scope : ?module_:module_ -> stage -> (unit -> 'a) -> 'a

val initial_flow :
  timetable_recognized:bool -> selected_module:module_ option -> unit

type hop

val start_http : unit -> hop option
val http_headers : hop option -> status:int -> unit
val http_complete : hop option -> bytes:int -> unit
val http_failed : hop option -> unit
