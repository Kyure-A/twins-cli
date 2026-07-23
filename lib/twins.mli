module Module : sig
  type t

  val all : t list
  val of_string : string -> (t, Error.t) result
  val to_string : t -> string
  val label : t -> string
end

module Day : sig
  type t

  val of_int : int -> (t, Error.t) result
  val to_int : t -> int
end

module Period : sig
  type t

  val of_int : int -> (t, Error.t) result
  val to_int : t -> int
end

module Notice_kind : sig
  type t

  val all : t list
  val of_string : string -> (t, Error.t) result
  val to_string : t -> string
end

module Date : sig
  type t

  val of_string : string -> (t, Error.t) result
  val to_string : t -> string
end

type status = { logged_in : bool; title : string }

type grade = {
  year : string;
  term : string;
  category : string;
  code : string;
  name : string;
  instructor : string;
  credits : string;
  spring : string;
  autumn : string;
  score : string;
  total : string;
}

type timetable_entry = {
  module_label : string;
  day : string;
  period : string;
  code : string;
  description : string;
  intensive : bool;
}

type notice = {
  seq : string;
  genre : string;
  course : string;
  instructor : string;
  title : string;
  period : string;
  posted : string;
}

type menu_item = { name : string; flow : string }

val login :
  ?session_file:string ->
  username:string ->
  password:string ->
  unit ->
  (unit, Error.t) result

val logout : ?session_file:string -> unit -> (unit, Error.t) result
val status : ?session_file:string -> unit -> (status, Error.t) result
val grades : ?session_file:string -> unit -> (grade list, Error.t) result
val grade_to_yojson : grade -> Yojson.Safe.t
val parse_grades : Soup.soup Soup.node -> (grade list, Error.t) result

val timetable :
  ?session_file:string -> Module.t -> (timetable_entry list, Error.t) result

val timetable_entry_to_yojson : timetable_entry -> Yojson.Safe.t

val parse_timetable :
  Module.t -> Soup.soup Soup.node -> (timetable_entry list, Error.t) result

val register :
  ?session_file:string ->
  module_:Module.t ->
  day:Day.t ->
  period:Period.t ->
  code:string ->
  force_limit:bool ->
  unit ->
  (unit, Error.t) result

val unregister :
  ?session_file:string ->
  module_:Module.t ->
  code:string ->
  unit ->
  (unit, Error.t) result

val notices :
  ?session_file:string ->
  kind:Notice_kind.t ->
  unread:bool ->
  title:string ->
  limit:int ->
  unit ->
  (notice list, Error.t) result

val notice_to_yojson : notice -> Yojson.Safe.t
val parse_notices : Soup.soup Soup.node -> (notice list, Error.t) result

val notice_detail :
  ?session_file:string ->
  kind:Notice_kind.t ->
  string ->
  (string, Error.t) result

val cancellations :
  ?session_file:string ->
  start_date:Date.t ->
  end_date:Date.t ->
  registered_only:bool ->
  unit ->
  (string, Error.t) result

val menu : menu_item list

val raw :
  ?session_file:string ->
  flow:string ->
  form_name:string ->
  event:string option ->
  fields:(string * string) list ->
  unit ->
  (string, Error.t) result
