let entry ?(slot = "1") code =
  Registration.{ code; identity = [ slot; "fixture course" ] }

let before = [ entry "OLD" ]
let after = [ entry "OLD"; entry "NEW" ]

let expect_error run =
  match run () with
  | exception _ -> ()
  | _ -> Alcotest.fail "expected verification failure"

let test_add ~saved ~other_changed () =
  let reads = ref 0 in
  let posts = ref [] in
  let read () =
    incr reads;
    if !reads = 1 then before
    else if other_changed then [ entry ~slot:"2" "OLD"; entry "NEW" ]
    else if saved then after
    else before
  in
  let post _ form event fields =
    posts := (form, event, fields) :: !posts;
    after
    (* Even a success-shaped write response cannot establish success. *)
  in
  let run () =
    Registration.add ~read ~snapshot:Fun.id ~post
      ~limited:(fun _ -> false)
      ~code:"NEW" ~day:"1" ~period:"2" ~force_limit:false
  in
  if (not saved) || other_changed then expect_error run else run ();
  Alcotest.(check int) "independent read before and after" 2 !reads;
  Alcotest.(check (list string))
    "writes sent once" [ "insert"; "input" ]
    (List.map (fun (_, event, _) -> event) !posts);
  Alcotest.(check (list (pair string string)))
    "specific course only"
    [ ("jikanwariCode", "NEW") ]
    (let _, _, fields = List.hd !posts in
     fields)

let test_remove ~saved ~other_changed () =
  let reads = ref 0 in
  let posts = ref [] in
  let read () =
    incr reads;
    if !reads = 1 then after
    else if other_changed then []
    else if saved then before
    else after
  in
  let targets _ =
    [
      Html.
        {
          year = "2026";
          department = "fixture";
          code = "NEW";
          day = "1";
          period = "2";
          description = "Fixture";
        };
    ]
  in
  let post _ form event _ =
    posts := (form, event) :: !posts;
    before
  in
  let run () =
    Registration.remove ~read ~snapshot:Fun.id ~targets ~post
      ~confirmed:(fun _ code -> code = "NEW")
      ~code:"NEW"
  in
  if (not saved) || other_changed then expect_error run else run ();
  Alcotest.(check int) "independent inquiry" 2 !reads;
  Alcotest.(check (list (pair string string)))
    "two-phase removal"
    [ ("InputForm", "delete"); ("DeleteForm", "delete") ]
    !posts

let test_safety () =
  let posts = ref 0 in
  let post _ _ _ _ =
    incr posts;
    after
  in
  expect_error (fun () ->
      Registration.add
        ~read:(fun () -> after)
        ~snapshot:Fun.id ~post
        ~limited:(fun _ -> false)
        ~code:"NEW" ~day:"1" ~period:"2" ~force_limit:false);
  Alcotest.(check int) "existing course not resubmitted" 0 !posts;
  expect_error (fun () ->
      Registration.add
        ~read:(fun () -> before)
        ~snapshot:Fun.id ~post
        ~limited:(fun _ -> true)
        ~code:"NEW" ~day:"1" ~period:"2" ~force_limit:false);
  Alcotest.(check int) "no unapproved credit override" 2 !posts;
  posts := 0;
  let targets _ =
    [
      Html.
        {
          year = "2026";
          department = "fixture";
          code = "NEW";
          day = "1";
          period = "2";
          description = "Fixture";
        };
    ]
  in
  expect_error (fun () ->
      Registration.remove
        ~read:(fun () -> after)
        ~snapshot:Fun.id ~targets ~post
        ~confirmed:(fun _ _ -> false)
        ~code:"NEW");
  Alcotest.(check int) "unexpected confirmation not submitted" 1 !posts

let () =
  Alcotest.run "TWINS verified registration"
    [
      ( "registration",
        [
          Alcotest.test_case "add fresh verification" `Quick
            (test_add ~saved:true ~other_changed:false);
          Alcotest.test_case "add stale server state" `Quick
            (test_add ~saved:false ~other_changed:false);
          Alcotest.test_case "add preserves other records" `Quick
            (test_add ~saved:true ~other_changed:true);
          Alcotest.test_case "remove fresh verification" `Quick
            (test_remove ~saved:true ~other_changed:false);
          Alcotest.test_case "remove stale server state" `Quick
            (test_remove ~saved:false ~other_changed:false);
          Alcotest.test_case "remove preserves other records" `Quick
            (test_remove ~saved:true ~other_changed:true);
          Alcotest.test_case "preflight and confirmation" `Quick test_safety;
        ] );
    ]
