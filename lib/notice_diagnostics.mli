(** Opt-in, content-free diagnostics for notice flow failures. No page text,
    request identifiers, URI, form value, or exception message is retained. *)

type phase = Initial | Search | Page

val enabled : unit -> bool

val run :
  ?after_phase:(phase -> unit) ->
  enabled:bool ->
  emit:(Yojson.Safe.t -> unit) ->
  is_success:('a -> bool) ->
  (unit -> 'a) ->
  'a

(** [after_phase] runs once after each successful scoped operation, before its
    value is returned. It is inactive when diagnostics are disabled. A callback
    exception fails the current stage and restores the enclosing context. *)

val with_phase : phase -> page_index:int -> (unit -> 'a) -> 'a

val record_response :
  ?uri:Uri.t ->
  status:int ->
  body:string ->
  soup:Soup.soup Soup.node ->
  unit ->
  unit
(** Record a materialized response before status/authentication validation.
    Calls outside an active phase do nothing. Marker fields report literal
    presence only and must not be interpreted as confirmed server diagnoses. *)
