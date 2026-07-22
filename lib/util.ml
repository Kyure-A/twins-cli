let is_ascii_space = function
  | ' ' | '\t' | '\r' | '\n' | '\012' -> true
  | _ -> false

let normalize_space value =
  let buffer = Buffer.create (String.length value) in
  let pending_space = ref false in
  String.iter
    (fun character ->
      if is_ascii_space character then pending_space := Buffer.length buffer > 0
      else (
        if !pending_space then Buffer.add_char buffer ' ';
        pending_space := false;
        Buffer.add_char buffer character))
    value;
  Buffer.contents buffer |> String.trim

let contains ~needle haystack =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  let rec loop offset =
    if offset + needle_length > haystack_length then false
    else if String.sub haystack offset needle_length = needle then true
    else loop (offset + 1)
  in
  needle_length = 0 || loop 0

let index_from_opt value ~from needle =
  let value_length = String.length value in
  let needle_length = String.length needle in
  let rec loop offset =
    if offset + needle_length > value_length then None
    else if String.sub value offset needle_length = needle then Some offset
    else loop (offset + 1)
  in
  if from < 0 || from > value_length then None else loop from

let between ~left ~right value =
  match index_from_opt value ~from:0 left with
  | None -> None
  | Some left_index -> (
      let content_start = left_index + String.length left in
      match index_from_opt value ~from:content_start right with
      | None -> None
      | Some right_index ->
          Some (String.sub value content_start (right_index - content_start)))

let strip_quotes value =
  let value = String.trim value in
  let length = String.length value in
  if length >= 2 then
    let first = value.[0] and last = value.[length - 1] in
    if (first = '\'' && last = '\'') || (first = '"' && last = '"') then
      String.sub value 1 (length - 2)
    else value
  else value

let deduplicate values =
  let seen = Hashtbl.create (List.length values) in
  List.filter
    (fun value ->
      if Hashtbl.mem seen value then false
      else (
        Hashtbl.add seen value ();
        true))
    values

let take count values =
  let rec loop remaining accumulator = function
    | _ when remaining <= 0 -> List.rev accumulator
    | [] -> List.rev accumulator
    | value :: rest -> loop (remaining - 1) (value :: accumulator) rest
  in
  loop count [] values

let rec mkdir_p directory =
  if directory = "" || directory = "." || directory = Filename.dirname directory
  then ()
  else if Sys.file_exists directory then ()
  else (
    mkdir_p (Filename.dirname directory);
    Unix.mkdir directory 0o700)
