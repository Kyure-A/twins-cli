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

(* Header rows may live in <thead> while records are in <tbody>. Preserve
   their document order and still support older unsectioned tables. *)
let rows table =
  let headers = table $$ "> thead > tr" |> Soup.to_list in
  let body =
    match table $$ "> tbody > tr" |> Soup.to_list with
    | [] -> table $$ "> tr" |> Soup.to_list
    | body_rows -> body_rows
  in
  headers @ body

let table_by_id id soup =
  soup $$ "table" |> Soup.to_list
  |> List.find_opt (fun table -> Soup.attribute "id" table = Some id)

(** First table with a row whose cell texts include every [headers] entry. *)
let table_by_headers headers soup =
  soup $$ "table" |> Soup.to_list
  |> List.find_opt (fun table ->
      rows table
      |> List.exists (fun row ->
          let cells = cell_texts row in
          List.for_all (fun header -> List.mem header cells) headers))

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

(* Diagnostic output is deliberately structural: no data cells, URLs, input
   values, scripts, or arbitrary labels can escape into support logs. *)
let structure soup =
  let labels =
    [
      "ジャンル";
      "科目";
      "担当者";
      "表題";
      "掲示期間";
      "掲載日時";
      "No.";
      "年度";
      "学期";
      "科目番号";
      "科目名";
      "曜日";
      "時限";
    ]
  in
  let label value = if List.mem value labels then `String value else `Null in
  let count selector root =
    Soup.select selector root |> Soup.to_list |> List.length
  in
  let row_labels selector table =
    Soup.select selector table |> Soup.to_list |> Util.take 2
    |> List.map (fun row -> `List (List.map label (cell_texts row)))
  in
  let tables =
    Soup.select "table" soup |> Soup.to_list
    |> List.mapi (fun index table ->
        `Assoc
          [
            ("index", `Int index);
            ("thead_rows", `Int (count "> thead > tr" table));
            ("tbody_rows", `Int (count "> tbody > tr" table));
            ("direct_rows", `Int (count "> tr" table));
            ("thead_labels", `List (row_labels "> thead > tr" table));
            ("tbody_labels", `List (row_labels "> tbody > tr" table));
            ("direct_labels", `List (row_labels "> tr" table));
          ])
  in
  let next_labels = [ "次"; "次へ"; "次ページ"; "次のページ"; "next"; ">"; ">>" ] in
  let controls =
    [
      "a";
      "button";
      "input[type='button']";
      "input[type='submit']";
      "span[onclick]";
    ]
    |> List.concat_map (fun selector ->
        Soup.select selector soup |> Soup.to_list)
    |> List.filter (fun node ->
        Soup.attribute "rel" node = Some "next"
        || List.mem (String.lowercase_ascii (node_text node)) next_labels
        || List.exists
             (fun attribute ->
               Option.fold ~none:false
                 ~some:(fun value ->
                   Util.contains ~needle:"page" (String.lowercase_ascii value))
                 (Soup.attribute attribute node))
             [ "href"; "onclick" ]
        || String.length (node_text node) <= 80
           && Util.contains ~needle:"次" (node_text node)
        || Option.fold ~none:false
             ~some:(fun value -> List.mem value next_labels)
             (Soup.attribute "value" node))
    |> List.map (fun node ->
        let href = Soup.attribute "href" node |> Option.value ~default:"" in
        let query = Uri.query (Uri.of_string href) in
        let safe_query =
          query
          |> List.map (fun (name, values) ->
              let value =
                if
                  List.mem
                    (String.lowercase_ascii name)
                    [
                      "page";
                      "pageno";
                      "pagenumber";
                      "pageindex";
                      "_pagecount";
                      "_displaycount";
                    ]
                then
                  values
                  |> List.filter (fun value ->
                      String.length value <= 6
                      && String.for_all
                           (function '0' .. '9' -> true | _ -> false)
                           value)
                else []
              in
              `Assoc
                [
                  ("name", `String name);
                  ( "numeric_values",
                    `List (List.map (fun value -> `String value) value) );
                ])
        in
        let source =
          Soup.attribute "onclick" node |> Option.value ~default:href
        in
        let function_name =
          match String.index_opt source '(' with
          | Some index -> String.sub source 0 index |> String.trim
          | None -> ""
        in
        let function_name =
          if
            String.length function_name <= 64
            && String.for_all
                 (function
                   | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' | ':' ->
                       true
                   | _ -> false)
                 function_name
          then function_name
          else ""
        in
        `Assoc
          [
            ("tag", `String (Soup.name node));
            ( "label_number",
              match int_of_string_opt (node_text node) with
              | Some number -> `Int number
              | None -> `Null );
            ( "next_caption",
              `Bool
                (Util.contains ~needle:"次" (node_text node)
                || Util.contains ~needle:"next"
                     (String.lowercase_ascii (node_text node))) );
            ( "previous_caption",
              `Bool
                (Util.contains ~needle:"前" (node_text node)
                || Util.contains ~needle:"prev"
                     (String.lowercase_ascii (node_text node))) );
            ("has_onclick", `Bool (Soup.has_attribute "onclick" node));
            ( "javascript",
              `Bool
                (String.starts_with ~prefix:"javascript:"
                   (String.lowercase_ascii href)) );
            ("query", `List safe_query);
            ("function", `String function_name);
          ])
  in
  `Assoc [ ("tables", `List tables); ("next_controls", `List controls) ]
