#!/usr/bin/env bash
set -euo pipefail

if (( $# == 0 )); then
  cli=(dune exec twins --)
else
  cli=("$@")
fi

"${cli[@]}" --help=plain >/dev/null

menu_output=$("${cli[@]}" menu)
grep -q $'registration\tRSW0001000-flow' <<<"$menu_output"
grep -q $'grades\tSIW0001200-flow' <<<"$menu_output"

smoke_directory=$(mktemp -d)
trap 'rm -rf -- "$smoke_directory"' EXIT
session_file="$smoke_directory/session"

status_output=$("${cli[@]}" status --session-file "$session_file")
test "$status_output" = "logged-out"

set +e
mutation_output=$("${cli[@]}" register TEST000 --module autumn-a --day 1 \
  --period 1 --session-file "$session_file" 2>&1)
mutation_status=$?
set -e

test "$mutation_status" -eq 1
grep -q "without --yes" <<<"$mutation_output"

test ! -e "$session_file"
