type next = End | Next of string | Unsupported

type 'a result = {
  items : 'a list;
  completeness : string;
  pages_fetched : int;
  reason : string option;
}

let disabled node =
  Soup.has_attribute "disabled" node
  || Soup.attribute "aria-disabled" node = Some "true"
  || Soup.attribute "class" node
     |> Option.value ~default:"" |> String.split_on_char ' '
     |> List.mem "disabled"

let next_label value =
  let value = String.lowercase_ascii (Util.normalize_space value) in
  List.mem value [ "next"; "next page"; "次"; "次へ"; "次ページ"; "次のページ"; ">"; ">>" ]

let pagination_control node =
  let href = Soup.attribute "href" node |> Option.value ~default:"" in
  let uri = Uri.of_string href in
  let page_query =
    Uri.query uri
    |> List.exists (fun (name, values) ->
        let name = String.lowercase_ascii name in
        List.mem name
          [
            "page";
            "pageno";
            "pagenumber";
            "pageindex";
            "currentpage";
            "_pagecount";
          ]
        && List.exists (fun value -> int_of_string_opt value <> None) values
        || name = "_eventid_paging"
        || name = "_eventid"
           && List.exists
                (fun value ->
                  Util.contains ~needle:"page" (String.lowercase_ascii value))
                values)
  in
  page_query
  || List.exists
       (fun attribute ->
         Option.fold ~none:false
           ~some:(fun value ->
             Util.contains ~needle:"page" (String.lowercase_ascii value))
           (Soup.attribute attribute node))
       [ "onclick" ]

let next ?(current_page = 1) soup =
  let controls =
    [ "a"; "button"; "input[type='button']"; "input[type='submit']" ]
    |> List.concat_map (fun selector ->
        Soup.select selector soup |> Soup.to_list)
  in
  let campus_controls =
    controls
    |> List.filter_map (fun node ->
        match Soup.attribute "href" node with
        | Some href when Html.query_param "_eventId_paging" href <> None ->
            Some
              ( href,
                Option.bind
                  (Html.query_param "_pageCount" href)
                  int_of_string_opt )
        | _ -> None)
  in
  if campus_controls <> [] then
    if
      List.exists
        (fun (_, number) ->
          Option.fold ~none:true ~some:(fun number -> number < 1) number)
        campus_controls
    then Unsupported
    else
      let forward =
        campus_controls
        |> List.filter_map (fun (href, number) ->
            match number with
            | Some number when number > current_page -> Some (number, href)
            | _ -> None)
        |> List.sort compare
      in
      match forward with
      | (number, href) :: _ when number = current_page + 1 -> Next href
      | _ :: _ -> Unsupported
      | [] -> End
  else
    let candidates =
      List.filter
        (fun node ->
          Soup.attribute "rel" node = Some "next"
          || next_label (Html.node_text node)
          || Option.fold ~none:false ~some:next_label
               (Soup.attribute "value" node)
          || Option.fold ~none:false ~some:next_label
               (Soup.attribute "aria-label" node))
        controls
    in
    let active = List.filter (fun node -> not (disabled node)) candidates in
    match active with
    | node :: _ -> (
        match Soup.attribute "href" node with
        | Some href
          when href <> ""
               && href.[0] <> '#'
               && (not
                     (String.starts_with ~prefix:"javascript:"
                        (String.lowercase_ascii href)))
               && Html.query_param "seqNo" href = None ->
            Next href
        | _ -> Unsupported)
    | [] ->
        (* A disabled Next control establishes an end; unknown pager controls do
         not. Never infer a JavaScript form event or fabricate page numbers. *)
        if candidates <> [] then End
        else if
          List.exists pagination_control controls
          || List.exists
               (fun selector -> Soup.select_one selector soup <> None)
               [
                 ".pagination";
                 ".pager";
                 "*[class*='paging']";
                 "*[id*='paging']";
                 "select[name*='page']";
                 "select[name*='Page']";
               ]
        then Unsupported
        else End

let page_number ~current href =
  match Option.bind (Html.query_param "_pageCount" href) int_of_string_opt with
  | Some number when number > 0 -> number
  | _ -> current + 1

let collect ~fetch ~parse ~next ~id ~limit ~max_pages first =
  let seen_ids = Hashtbl.create 128 in
  let finish reversed_items pages_fetched reason =
    let items = List.rev reversed_items in
    let items =
      match limit with Some limit -> Util.take limit items | None -> items
    in
    {
      items;
      pages_fetched;
      reason;
      completeness = (if reason = None then "complete" else "partial");
    }
  in
  let rec loop page pages seen_pages seen_links item_count reversed_items =
    let found = parse page in
    let fingerprint = List.map id found |> List.sort String.compare in
    if List.mem fingerprint seen_pages then
      finish reversed_items pages (Some "pagination_loop")
    else
      let item_count, reversed_items =
        List.fold_left
          (fun ((count, collected) as accumulator) item ->
            let key = id item in
            if Hashtbl.mem seen_ids key then accumulator
            else (
              Hashtbl.add seen_ids key ();
              (count + 1, item :: collected)))
          (item_count, reversed_items)
          found
      in
      let truncated =
        Option.fold ~none:false ~some:(fun limit -> item_count > limit) limit
      in
      if truncated then finish reversed_items pages (Some "limit")
      else
        match next page with
        | End -> finish reversed_items pages None
        | Unsupported ->
            finish reversed_items pages (Some "unsupported_pagination")
        | Next href ->
            if List.mem href seen_links then
              finish reversed_items pages (Some "pagination_loop")
            else if
              Option.fold ~none:false
                ~some:(fun limit -> item_count >= limit)
                limit
            then finish reversed_items pages (Some "limit")
            else if pages >= max_pages then
              finish reversed_items pages (Some "page_limit")
            else
              loop (fetch page href) (pages + 1)
                (fingerprint :: seen_pages)
                (href :: seen_links) item_count reversed_items
  in
  loop first 1 [] [] 0 []
