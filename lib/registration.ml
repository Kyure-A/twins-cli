type entry = { code : string; identity : string list }

let contains code entries = List.exists (fun entry -> entry.code = code) entries

let verify ~adding ~before ~after ~code =
  let others entries =
    entries
    |> List.filter (fun entry -> entry.code <> code)
    |> List.sort compare
  in
  if contains code after <> adding then
    Internal_error.protocolf
      "fresh TWINS inquiry did not verify %s of %s; inspect current state \
       before retrying"
      (if adding then "registration" else "removal")
      code;
  if others before <> others after then
    Internal_error.protocolf
      "fresh TWINS inquiry shows other registration records changed; inspect \
       current state before retrying"

let add ~read ~snapshot ~post ~limited ~code ~day ~period ~force_limit =
  let before_page = read () in
  let before = snapshot before_page in
  if contains code before then
    Internal_error.protocolf "%s is already registered" code;
  let input =
    post before_page "InputForm" "input" [ ("yobi", day); ("jigen", period) ]
  in
  let result = post input "InputForm" "insert" [ ("jikanwariCode", code) ] in
  if limited result then (
    if not force_limit then
      Internal_error.protocolf
        "registration requires overriding the annual credit limit; rerun with \
         --force-limit if that is permitted";
    ignore (post result "InputForm" "kyoseiTorokuGakusei" []));
  (* A new Web Flow query, never the response of the write, establishes success. *)
  let after = read () |> snapshot in
  verify ~adding:true ~before ~after ~code

let remove ~read ~snapshot ~targets ~post ~confirmed ~code =
  let before_page = read () in
  let before = snapshot before_page in
  let target =
    match
      List.find_opt
        (fun (item : Html.registration) -> item.code = code)
        (targets before_page)
    with
    | Some target -> target
    | None ->
        Internal_error.protocolf
          "%s is not deletable (it may be unregistered or outside the \
           registration period)"
          code
  in
  let confirmation =
    post before_page "DeleteForm" "delete"
      [
        ("nendo", target.year);
        ("jikanwariShozokuCode", target.department);
        ("jikanwariCode", target.code);
        ("yobi", target.day);
        ("jigen", target.period);
      ]
  in
  if not (confirmed confirmation code) then
    Internal_error.protocolf
      "TWINS did not show the expected deletion confirmation";
  ignore (post confirmation "InputForm" "delete" []);
  let after = read () |> snapshot in
  verify ~adding:false ~before ~after ~code
