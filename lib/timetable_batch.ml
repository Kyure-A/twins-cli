(* Carry the last returned page through the traversal. A Web Flow execution key
   belongs to that page, not to the initial registration view. *)
let collect ~start ~flow_key ~select ~parse modules =
  let rec loop page collected = function
    | [] -> List.rev collected
    | module_ :: rest ->
        let page = select ~key:(flow_key page) module_ in
        let rows = parse module_ page in
        loop page ((module_, rows) :: collected) rest
  in
  match modules with [] -> [] | _ -> loop (start ()) [] modules

let search_query ~key ~module_code ~term_code =
  [
    ("_flowExecutionKey", [ key ]);
    ("_eventId", [ "search" ]);
    ("moduleCode", [ module_code ]);
    ("gakkiKbnCode", [ term_code ]);
  ]

(* Some TWINS versions expose the active module in form controls. Validate every
   explicit value when present; navigation links for the other modules are not
   evidence of the active selection. Never include returned values in errors. *)
let validate_selection ~module_code ~term_code soup =
  let check name expected =
    let inputs =
      Soup.select ("input[name='" ^ name ^ "']") soup
      |> Soup.to_list
      |> List.filter_map (fun input ->
          match Soup.attribute "type" input with
          | Some ("radio" | "checkbox")
            when Soup.attribute "checked" input = None ->
              None
          | _ -> Soup.attribute "value" input)
    in
    let selects =
      Soup.select ("select[name='" ^ name ^ "']") soup
      |> Soup.to_list
      |> List.filter_map (fun select ->
          let option =
            match Soup.select_one "option[selected]" select with
            | Some option -> Some option
            | None -> Soup.select_one "option" select
          in
          Option.bind option (Soup.attribute "value"))
    in
    if List.exists (fun value -> value <> expected) (inputs @ selects) then
      Internal_error.protocolf
        "TWINS timetable response does not match the requested module"
  in
  check "moduleCode" module_code;
  check "gakkiKbnCode" term_code
