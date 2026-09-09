type link = { id : string; name : string; status : string; href : string }

type course = {
  code : string;
  name : string;
  instructor : string;
  schedule : string;
  capacity : string;
  first_choices : string;
  rank : int option;
  rank_field : string option;
}

let link_to_yojson (link : link) =
  `Assoc
    [
      ("id", `String link.id);
      ("name", `String link.name);
      ("status", `String link.status);
    ]

let course_to_yojson (course : course) =
  `Assoc
    [
      ("code", `String course.code);
      ("name", `String course.name);
      ("instructor", `String course.instructor);
      ("schedule", `String course.schedule);
      ("capacity", `String course.capacity);
      ("first_choices", `String course.first_choices);
      ("rank", match course.rank with None -> `Null | Some n -> `Int n);
    ]

let links ~event ~key soup =
  soup |> Soup.select "a[href]" |> Soup.to_list
  |> List.filter_map (fun anchor ->
      let href = Soup.attribute "href" anchor |> Option.get in
      if Html.query_param "_eventId" href <> Some event then None
      else
        match Html.query_param key href with
        | None ->
            Internal_error.protocolf "TWINS pre-registration link lacks %s" key
        | Some id ->
            let status =
              match Option.bind (Soup.parent anchor) Soup.parent with
              | Some row -> (
                  match Html.cell_texts row with
                  | _ :: status :: _ -> status
                  | _ -> "")
              | None -> ""
            in
            Some { id; name = Html.node_text anchor; status; href })

let rank_of_string value =
  match String.trim value with
  | "" -> None
  | value -> (
      match int_of_string_opt value with
      | Some n when n > 0 -> Some n
      | _ ->
          Internal_error.protocolf "TWINS returned an invalid preference rank")

let course_tables soup =
  soup |> Soup.select "table" |> Soup.to_list
  |> List.filter (fun table ->
      let headers =
        table |> Soup.select "th" |> Soup.to_list |> List.map Html.node_text
      in
      List.mem "科目番号" headers
      && List.mem "主担当教員" headers
      && (List.mem "希望 順位" headers || List.mem "優先 順位" headers))

let courses soup =
  course_tables soup
  |> List.concat_map (fun table ->
      Html.rows table
      |> List.filter_map (fun row ->
          match Html.cell_texts row with
          | rank_text :: code :: name :: instructor :: schedule :: capacity
            :: first_choices :: _
            when code <> "科目番号" ->
              let rank_input =
                Soup.select_one "input[name^='yusenJuni_']" row
              in
              let rank =
                match rank_input with
                | None -> rank_of_string rank_text
                | Some input ->
                    Soup.attribute "value" input
                    |> Option.value ~default:"" |> rank_of_string
              in
              let rank_field = Option.bind rank_input (Soup.attribute "name") in
              Some
                {
                  code;
                  name;
                  instructor;
                  schedule;
                  capacity;
                  first_choices;
                  rank;
                  rank_field;
                }
          | _ -> None))

let inquiry soup =
  if not (Util.contains ~needle:"事前登録希望情報" (Html.article_text soup)) then
    Internal_error.protocolf "TWINS did not return the pre-registration inquiry";
  let result = courses soup in
  List.iter
    (fun c ->
      if c.rank = None then
        Internal_error.protocolf "TWINS inquiry has an unranked course")
    result;
  result

let input_courses soup =
  let form =
    match Html.form_by_name "InputForm" soup with
    | Some f when Soup.attribute "id" f = Some "rishuYobiEntryForm" -> f
    | _ ->
        Internal_error.protocolf
          "TWINS did not return the pre-registration input form"
  in
  let fields = Html.form_fields form in
  let count =
    Option.bind (List.assoc_opt "kamokuCnt" fields) int_of_string_opt
  in
  let result = courses form in
  if count <> Some (List.length result) || result = [] then
    Internal_error.protocolf
      "TWINS pre-registration course count does not match its form";
  List.iter
    (fun c ->
      let field =
        match c.rank_field with
        | Some f -> f
        | None -> Internal_error.protocolf "Missing preference input"
      in
      let index = String.sub field 10 (String.length field - 10) in
      if List.assoc_opt ("jikanwariCode_" ^ index) fields <> Some c.code then
        Internal_error.protocolf
          "TWINS visible course code does not match its form")
    result;
  result

let find_link id (links : link list) =
  match List.filter (fun l -> l.id = id || l.name = id) links with
  | [ link ] -> link
  | [] ->
      Internal_error.protocolf
        "Pre-registration category/group %S is unavailable or closed" id
  | _ ->
      Internal_error.protocolf "Pre-registration category/group %S is ambiguous"
        id

let choose ~get ~event ~key id page =
  (find_link id (links ~event ~key page)).href |> get

let group_page ~open_flow ~get ~category =
  open_flow "RSW0001300-flow"
  |> choose ~get ~event:"inputCategory" ~key:"categorycd" category

let input_page ~open_flow ~get ~category ~group =
  group_page ~open_flow ~get ~category
  |> choose ~get ~event:"input" ~key:"yobiKamokuKubunCode" group

let preferences courses =
  courses
  |> List.filter_map (fun c -> Option.map (fun rank -> (c.code, rank)) c.rank)
  |> List.sort compare

let prepare ~code ~rank courses =
  if rank < 1 || rank > List.length courses then
    Internal_error.protocolf
      "Preference rank must be between 1 and the group course count";
  let target =
    match List.filter (fun c -> c.code = code) courses with
    | [ target ] -> target
    | _ ->
        Internal_error.protocolf
          "Course %s is absent or ambiguous in this group" code
  in
  if List.exists (fun c -> c.code <> code && c.rank = Some rank) courses then
    Internal_error.protocolf
      "Preference rank %d is already used; existing choices were not changed"
      rank;
  let field =
    match target.rank_field with
    | Some f -> f
    | None -> Internal_error.protocolf "Missing preference input"
  in
  let expected =
    List.map
      (fun c -> if c.code = code then { c with rank = Some rank } else c)
      courses
  in
  (target, field, expected)

let check_confirmation expected soup =
  if
    (not (Util.contains ~needle:"登録は完了していません" (Html.article_text soup)))
    || preferences (courses soup) <> preferences expected
    || List.length (courses soup) <> List.length (preferences expected)
    || Soup.select_one "input[onclick='insertSubmit()']" soup = None
  then
    Internal_error.protocolf
      "TWINS confirmation does not match the requested preferences; nothing \
       was submitted"

let verify ~before ~code ~rank after =
  if
    List.filter (fun c -> c.code = code && c.rank = Some rank) after
    |> List.length <> 1
  then
    Internal_error.protocolf
      "TWINS inquiry did not verify %s at rank %d; inspect current state \
       before retrying"
      code rank;
  let other courses =
    courses |> List.filter (fun c -> c.code <> code) |> preferences
  in
  if other before <> other after then
    Internal_error.protocolf
      "Other pre-registration choices changed; inspect TWINS before retrying";
  List.find (fun c -> c.code = code) after

let add ~open_flow ~get ~post ~category ~group ~code ~rank =
  let before = open_flow "RSW0001400-flow" |> inquiry in
  let page = input_page ~open_flow ~get ~category ~group in
  let target, field, expected = input_courses page |> prepare ~code ~rank in
  if target.rank <> Some rank then (
    let confirmation = post page "check" [ (field, string_of_int rank) ] in
    check_confirmation expected confirmation;
    ignore (post confirmation "insert" []));
  open_flow "RSW0001400-flow" |> inquiry |> verify ~before ~code ~rank
