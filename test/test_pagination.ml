let parse = Soup.parse

let page rows pager =
  parse
    ("<table><tr><th>ジャンル</th><th>科目</th><th>担当者</th><th>表題</th><th>掲示期間</th><th>掲載日時</th></tr>"
   ^ rows ^ "</table>" ^ pager)

let row id =
  "<tr><td>fixture</td><td>Course</td><td>Teacher</td><td><a \
   href='campussquare.do?seqNo=" ^ id ^ "'>Title " ^ id
  ^ "</a></td><td>Term</td><td>2026-09-20</td></tr>"

let next =
  "<a rel='next' href='campussquare.do?_eventId=page&amp;pageNo=2'>次へ</a>"

let last = "<span class='pager'><a aria-disabled='true'>次へ</a></span>"

let items soup =
  match Twins.parse_notices soup with
  | Ok items -> items
  | Error e -> Alcotest.fail (Error.to_string e)

let collect ?(limit = None) ?(max_pages = 20) pages =
  let pending = ref (List.tl pages) in
  let fetch _ _ =
    match !pending with
    | [] -> Alcotest.fail "unexpected page request"
    | page :: rest ->
        pending := rest;
        page
  in
  Notice_pagination.collect ~fetch ~parse:items
    ~next:(fun soup -> Notice_pagination.next soup)
    ~id:(fun (notice : Twins.notice) -> notice.seq)
    ~limit ~max_pages (List.hd pages)

let check reason count pages result =
  Alcotest.(check (option string))
    "reason" reason result.Notice_pagination.reason;
  Alcotest.(check string)
    "completeness"
    (if reason = None then "complete" else "partial")
    result.completeness;
  Alcotest.(check int) "items" count (List.length result.items);
  Alcotest.(check int) "pages" pages result.pages_fetched

let test_all () =
  let result =
    collect
      [ page (row "1" ^ row "1" ^ row "2") next; page (row "2" ^ row "3") last ]
  in
  check None 3 2 result;
  let json = Twins.notice_result_to_yojson result in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "metadata contract" "complete"
    (json |> member "completeness" |> to_string);
  Alcotest.(check int)
    "JSON items" 3
    (json |> member "items" |> to_list |> List.length)

let test_limit () =
  check (Some "limit") 1 1
    (collect ~limit:(Some 1) [ page (row "1" ^ row "2") next ]);
  check (Some "limit") 1 1 (collect ~limit:(Some 1) [ page (row "1") next ]);
  check None 1 1 (collect ~limit:(Some 1) [ page (row "1") last ]);
  check (Some "limit") 0 1 (collect ~limit:(Some 0) [ page (row "1") last ])

let collect_entries ?(limit = None) ?(max_pages = 20) pages =
  let pages = Array.of_list pages in
  Notice_pagination.collect
    ~fetch:(fun _ href -> int_of_string href)
    ~parse:(Array.get pages)
    ~next:(fun index ->
      if index + 1 = Array.length pages then Notice_pagination.End
      else Notice_pagination.Next (string_of_int (index + 1)))
    ~id:fst ~limit ~max_pages 0

let test_first_occurrence_order () =
  let first = ("C", "first C") in
  let result =
    collect_entries
      [
        [ first; ("B", "first B"); ("C", "same-page duplicate") ];
        [ ("A", "first A"); ("B", "later-page duplicate"); ("D", "first D") ];
      ]
  in
  check None 4 2 result;
  Alcotest.(check (list (pair string string)))
    "first payload and encounter order"
    [ first; ("B", "first B"); ("A", "first A"); ("D", "first D") ]
    result.items;
  Alcotest.(check bool)
    "retain the original item" true
    (List.hd result.items == first);
  let repeated =
    collect_entries
      [
        [ first; ("B", "first B") ]; [ ("B", "changed B"); ("C", "changed C") ];
      ]
  in
  check (Some "pagination_loop") 2 2 repeated;
  Alcotest.(check (list (pair string string)))
    "a reordered repeated page retains the first payloads"
    [ first; ("B", "first B") ]
    repeated.items

let test_distinct_limit_boundaries () =
  let pages =
    [
      [ ("B", "first B"); ("A", "first A"); ("B", "duplicate B") ];
      [ ("A", "duplicate A"); ("C", "first C"); ("D", "first D") ];
      [ ("E", "first E") ];
    ]
  in
  List.iter
    (fun (limit, reason, fetched, expected) ->
      let result = collect_entries ~limit:(Some limit) pages in
      check reason (List.length expected) fetched result;
      Alcotest.(check (list string))
        (Printf.sprintf "distinct limit %d preserves order" limit)
        expected
        (List.map fst result.items))
    [
      (0, Some "limit", 1, []);
      (1, Some "limit", 1, [ "B" ]);
      (2, Some "limit", 1, [ "B"; "A" ]);
      (3, Some "limit", 2, [ "B"; "A"; "C" ]);
      (4, Some "limit", 2, [ "B"; "A"; "C"; "D" ]);
      (5, None, 3, [ "B"; "A"; "C"; "D"; "E" ]);
      (6, None, 3, [ "B"; "A"; "C"; "D"; "E" ]);
    ];
  check (Some "page_limit") 2 1 (collect_entries ~max_pages:1 pages)

let test_collect_failures () =
  let run ~fetch ~parse =
    Notice_pagination.collect ~fetch ~parse
      ~next:(fun _ -> Notice_pagination.Next "next")
      ~id:fst ~limit:None ~max_pages:20 0
  in
  Alcotest.check_raises "fetch failure is propagated"
    (Failure "fixture fetch failed") (fun () ->
      ignore
        (run
           ~fetch:(fun _ _ -> failwith "fixture fetch failed")
           ~parse:(fun _ -> [ ("A", "first A") ])));
  let parsed = ref [] in
  Alcotest.check_raises "later parser failure is propagated"
    (Failure "fixture parser failed") (fun () ->
      ignore
        (run
           ~fetch:(fun _ _ -> 1)
           ~parse:(fun index ->
             parsed := index :: !parsed;
             if index = 1 then failwith "fixture parser failed"
             else [ ("A", "first A") ])));
  Alcotest.(check (list int))
    "parse each fetched page once" [ 0; 1 ] (List.rev !parsed);
  check None 1 1 (collect_entries [ [ ("A", "fresh call") ] ])

let test_bounds () =
  check (Some "page_limit") 1 1 (collect ~max_pages:1 [ page (row "1") next ]);
  check (Some "pagination_loop") 1 2
    (collect [ page (row "1") next; page (row "1") next ]);
  check (Some "pagination_loop") 2 2
    (collect [ page (row "1") next; page (row "2") next ])

let test_unknown () =
  check (Some "unsupported_pagination") 1 1
    (collect
       [
         page (row "1")
           "<a \
            href='campussquare.do?_eventId_paging=&amp;_pageCount=invalid&amp;_displayCount=100'>2</a>";
       ]);

  check (Some "unsupported_pagination") 1 1
    (collect
       [
         page (row "1")
           "<a onclick='unknownNext()' href='javascript:void(0)'>次へ</a>";
       ]);
  check (Some "unsupported_pagination") 1 1
    (collect
       [
         page (row "1")
           "<select \
            name='pageNumber'><option>1</option><option>2</option></select>";
       ]);
  check (Some "unsupported_pagination") 1 1
    (collect
       [
         page (row "1") "<div class='pagination'><a href='?page=2'>2</a></div>";
       ])

let test_empty_and_missing () =
  check None 0 1 (collect [ page "" "<a href='portal.do?page=main'>Home</a>" ]);
  (match Twins.parse_notices (parse "<h1>Maintenance</h1>") with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "missing table must fail");
  match
    Twins.parse_notices
      (page
         "<tr><td>Genre</td><td>Course</td><td>Teacher</td><td>Missing \
          ID</td><td>Term</td><td>Date</td></tr>"
         "")
  with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "unidentified row must fail"

let test_structure () =
  let secret = "PRIVATE_TOKEN_FIXTURE" in
  let soup =
    Soup.parse
      ("<table><thead><tr><th>ジャンル</th><th>" ^ secret
     ^ "</th></tr></thead><tbody><tr><td>" ^ secret
     ^ "</td></tr></tbody></table><input type='hidden' value='" ^ secret
     ^ "'><a href='campussquare.do?_flowExecutionKey=" ^ secret
     ^ "&amp;pageNo=2'>次へ</a>")
  in
  let rendered = Html.structure soup |> Yojson.Safe.to_string in
  Alcotest.(check bool)
    "no private values or data cells" false
    (String.split_on_char '"' rendered |> List.mem secret);
  let open Yojson.Safe.Util in
  let table = Html.structure soup |> member "tables" |> to_list |> List.hd in
  Alcotest.(check int) "thead count" 1 (table |> member "thead_rows" |> to_int)

let test_campus_pager () =
  let link number =
    Printf.sprintf
      "<a \
       href='campussquare.do?_flowExecutionKey=fixture&amp;_eventId_paging=&amp;_displayCount=100&amp;_pageCount=%d'>%d</a>"
      number number
  in
  let first = (1, page (row "A") (link 2 ^ link 3)) in
  let second = (2, page (row "B") (link 1 ^ link 3)) in
  let third = (3, page (row "C") (link 1 ^ link 2)) in
  let fetch (current, _) href =
    (* The response itself carries no page number; retain the followed link's
       number even if Web Flow redirects to an opaque execution URL. *)
    let number = Notice_pagination.page_number ~current href in
    match number with
    | 2 -> (number, snd second)
    | 3 -> (number, snd third)
    | _ -> Alcotest.fail "unexpected page"
  in
  let result =
    Notice_pagination.collect ~fetch
      ~parse:(fun (_, soup) -> items soup)
      ~next:(fun (current_page, soup) ->
        Notice_pagination.next ~current_page soup)
      ~id:(fun (notice : Twins.notice) -> notice.seq)
      ~limit:None ~max_pages:20 first
  in
  check None 3 3 result;
  Alcotest.(check (list string))
    "all distinct page IDs" [ "A"; "B"; "C" ]
    (List.map (fun (notice : Twins.notice) -> notice.seq) result.items);
  match Notice_pagination.next ~current_page:1 (page (row "A") (link 3)) with
  | Notice_pagination.Unsupported -> ()
  | _ -> Alcotest.fail "must not skip unlinked page 2"

let test_observed_tables () =
  let fixture file =
    let ch = open_in ("fixtures/" ^ file) in
    let content =
      Fun.protect
        ~finally:(fun () -> close_in ch)
        (fun () -> really_input_string ch (in_channel_length ch))
    in
    items (Soup.parse content)
  in
  let classes = fixture "notices-classes.html" in
  let general = fixture "notices-general.html" in
  Alcotest.(check (list string))
    "class IDs and exact row count"
    [ "FIXTURE001"; "FIXTURE002" ]
    (List.map (fun (notice : Twins.notice) -> notice.seq) classes);
  Alcotest.(check (list string))
    "general IDs and exact row count"
    [ "FIXTURE003"; "FIXTURE004" ]
    (List.map (fun (notice : Twins.notice) -> notice.seq) general);
  Alcotest.(check string)
    "class course mapping" "Fixture course A" (List.hd classes).course;
  Alcotest.(check string)
    "class teacher mapping" "Fixture teacher A" (List.hd classes).instructor;
  Alcotest.(check string) "general absent course" "" (List.hd general).course;
  Alcotest.(check string)
    "general title mapping" "Fixture general title A" (List.hd general).title

let () =
  Alcotest.run "TWINS pagination"
    [
      ( "notices",
        [
          Alcotest.test_case "multiple pages, dedup and metadata" `Quick
            test_all;
          Alcotest.test_case "item limits" `Quick test_limit;
          Alcotest.test_case "first occurrence payload and order" `Quick
            test_first_occurrence_order;
          Alcotest.test_case "distinct item limit boundaries" `Quick
            test_distinct_limit_boundaries;
          Alcotest.test_case "collector failures propagate" `Quick
            test_collect_failures;
          Alcotest.test_case "page limits and cycles" `Quick test_bounds;
          Alcotest.test_case "unknown pagers are partial" `Quick test_unknown;
          Alcotest.test_case "empty vs malformed" `Quick test_empty_and_missing;
          Alcotest.test_case "redacted structural diagnostics" `Quick
            test_structure;
          Alcotest.test_case "observed thead and general columns" `Quick
            test_observed_tables;
          Alcotest.test_case "observed numeric CampusSquare pager" `Quick
            test_campus_pager;
        ] );
    ]
