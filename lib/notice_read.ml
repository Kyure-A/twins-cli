(* Notice searches submit a form. Only the following GET pagination belongs in
   the scoped read transport; do not replay or pool the search POST. *)
let run ?(reuse_connections = true) ~search ~collect () =
  let first = search () in
  let read () = collect first in
  if reuse_connections then Http_client.with_reused_connections read
  else read ()
