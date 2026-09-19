type field = string * string

val parse : string -> Soup.soup Soup.node
val node_text : 'a Soup.node -> string
val direct_cells : 'a Soup.node -> Soup.element Soup.node list
val cell_texts : 'a Soup.node -> string list
val rows : 'a Soup.node -> Soup.element Soup.node list
val table_by_id : string -> 'a Soup.node -> Soup.element Soup.node option

val table_by_headers :
  string list -> 'a Soup.node -> Soup.element Soup.node option

val form_by_name : string -> 'a Soup.node -> Soup.element Soup.node option
val form_fields : 'a Soup.node -> field list
val set_field : string -> string -> field list -> field list
val set_fields : field list -> field list -> field list
val remove_field : string -> field list -> field list
val flow_key : 'a Soup.node -> string option
val portal_hash : 'a Soup.node -> string option
val is_login_page : 'a Soup.node -> bool
val is_auth_error : 'a Soup.node -> bool
val title : 'a Soup.node -> string
val article_text : 'a Soup.node -> string
val messages : 'a Soup.node -> string list

type registration = {
  year : string;
  department : string;
  code : string;
  day : string;
  period : string;
  description : string;
}

val registrations : 'a Soup.node -> registration list
val query_param : string -> string -> string option

val structure : 'a Soup.node -> Yojson.Safe.t
(** Redacted table topology and pager descriptors; no account contents or state.
*)
