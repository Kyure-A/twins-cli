open Soup

type field = string * string

let parse = Soup.parse

let node_text node =
  Soup.trimmed_texts node |> String.concat " " |> Util.normalize_space

let direct_cells row =
  row |> Soup.children |> Soup.elements
  |> Soup.filter (fun element ->
      let name = Soup.name element in
      name = "td" || name = "th")
  |> Soup.to_list

let cell_texts row = direct_cells row |> List.map node_text
let rows table = table $$ "> tbody > tr" |> Soup.to_list

let table_by_id id soup =
  soup $$ "table" |> Soup.to_list
  |> List.find_opt (fun table -> Soup.attribute "id" table = Some id)

let form_by_name name soup =
  soup $$ "form" |> Soup.to_list
  |> List.find_opt (fun form -> Soup.attribute "name" form = Some name)

let control_name control =
  match Soup.attribute "name" control with
  | Some name when String.trim name <> "" -> Some name
  | _ -> None

let input_fields input =
  match control_name input with
  | None -> []
  | Some name -> (
      let input_type =
        Soup.attribute "type" input
        |> Option.value ~default:"text"
        |> String.lowercase_ascii
      in
      let value = Soup.attribute "value" input |> Option.value ~default:"" in
      match input_type with
      | "submit" | "button" | "reset" | "file" | "image" -> []
      | "checkbox" | "radio" ->
          if Soup.has_attribute "checked" input then [ (name, value) ] else []
      | _ -> [ (name, value) ])

let select_fields select =
  match control_name select with
  | None -> []
  | Some name ->
      let options = select $$ "option" |> Soup.to_list in
      let selected =
        options
        |> List.filter (fun option -> Soup.has_attribute "selected" option)
      in
      let selected =
        match selected with
        | [] -> ( match options with [] -> [] | first :: _ -> [ first ])
        | values -> values
      in
      selected
      |> List.map (fun option ->
          ( name,
            Soup.attribute "value" option
            |> Option.value ~default:(node_text option) ))

let textarea_fields textarea =
  match control_name textarea with
  | None -> []
  | Some name -> [ (name, Soup.texts textarea |> String.concat "") ]

let form_fields form =
  let inputs =
    form $$ "input" |> Soup.to_list |> List.concat_map input_fields
  in
  let selects =
    form $$ "select" |> Soup.to_list |> List.concat_map select_fields
  in
  let textareas =
    form $$ "textarea" |> Soup.to_list |> List.concat_map textarea_fields
  in
  inputs @ selects @ textareas

let set_field name value fields =
  (name, value) :: List.filter (fun (candidate, _) -> candidate <> name) fields

let set_fields replacements fields =
  List.fold_left
    (fun current (name, value) -> set_field name value current)
    fields replacements

let remove_field name fields =
  List.filter (fun (candidate, _) -> candidate <> name) fields

let flow_key soup =
  soup $$ "input[name='_flowExecutionKey']" |> Soup.to_list
  |> List.filter_map (Soup.attribute "value")
  |> List.find_opt (fun value -> String.trim value <> "")

let portal_hash soup =
  match
    soup $$ "script" |> Soup.to_list
    |> List.filter_map (fun script ->
        let source = Soup.texts script |> String.concat "" in
        match Util.between ~left:"'rwfHash'" ~right:"\n" source with
        | None -> None
        | Some line -> Util.between ~left:"'" ~right:"'" line)
  with
  | hash :: _ -> Some hash
  | [] -> None

let is_login_page soup =
  Soup.select_one "input[name='userName']" soup <> None
  && Soup.select_one "input[name='password']" soup <> None

let is_auth_error soup =
  Soup.select_one "form[name='authorizationError']" soup <> None
  || Soup.select_one "form#authorizationError" soup <> None

let title soup =
  match Soup.select_one "title" soup with
  | None -> ""
  | Some title -> node_text title

let article_text soup =
  let articles = soup $$ "article" |> Soup.to_list in
  let roots =
    if articles = [] then [ Soup.coerce soup ]
    else List.map Soup.coerce articles
  in
  roots
  |> List.concat_map Soup.trimmed_texts
  |> List.map Util.normalize_space
  |> List.filter (fun text -> text <> "")
  |> String.concat "\n"

let messages soup =
  soup $$ ".error, .errors, .err, .message, .messages, .alert" |> Soup.to_list
  |> List.map node_text
  |> List.filter (fun text -> text <> "")
  |> Util.deduplicate

type registration = {
  year : string;
  department : string;
  code : string;
  day : string;
  period : string;
  description : string;
}

let call_arguments function_name source =
  let left = function_name ^ "(" in
  match Util.between ~left ~right:")" source with
  | None -> None
  | Some arguments ->
      Some
        (arguments |> String.split_on_char ','
        |> List.map (fun argument ->
            argument |> String.trim |> Util.strip_quotes))

let registrations soup =
  soup $$ "a[onclick]" |> Soup.to_list
  |> List.filter_map (fun anchor ->
      match Soup.attribute "onclick" anchor with
      | None -> None
      | Some onclick -> (
          match call_arguments "DeleteCallA" onclick with
          | Some [ year; department; code; day; period ] ->
              let description =
                match Soup.parent anchor with
                | None -> node_text anchor
                | Some parent -> node_text parent
              in
              Some { year; department; code; day; period; description }
          | _ -> None))

let query_param name href =
  try Uri.get_query_param (Uri.of_string href) name
  with Invalid_argument _ -> None
