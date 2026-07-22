(lang dune 3.12)
(name twins-cli)
(generate_opam_files true)

(package
 (name twins-cli)
 (synopsis "Command-line client for the University of Tsukuba TWINS")
 (description "An unofficial OCaml client for TWINS/CAMPUSSQUARE.")
 (authors "Kyure-A")
 (maintainers "Kyure-A")
 (license GPL-3.0-only)
 (source (github Kyure-A/twins-cli))
 (depends
  (ocaml (>= 5.1))
  dune
  cmdliner
  cohttp-lwt-unix
  (alcotest :with-test)
  lambdasoup
  lwt
  uri
  yojson))
