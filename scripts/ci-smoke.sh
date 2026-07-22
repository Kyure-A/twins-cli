#!/usr/bin/env bash
set -euo pipefail

if (( $# == 0 )); then
  cli=(dune exec twins --)
else
  cli=("$@")
fi

main_help=$("${cli[@]}" --help=plain)
grep -q '^       auth COMMAND' <<<"$main_help"
grep -q '^       registration COMMAND' <<<"$main_help"

login_help=$("${cli[@]}" auth login --help=plain)
grep -q -- '--session=FILE' <<<"$login_help"
grep -q -- '-u ID' <<<"$login_help"
grep -q -- '--password-stdin' <<<"$login_help"

registration_help=$("${cli[@]}" registration add --help=plain)
grep -q -- '-y, --yes' <<<"$registration_help"

menu_output=$("${cli[@]}" menu)
grep -q $'registration\tRSW0001000-flow' <<<"$menu_output"
grep -q $'grades\tSIW0001200-flow' <<<"$menu_output"

smoke_directory=$(mktemp -d)
trap 'rm -rf -- "$smoke_directory"' EXIT
session_file="$smoke_directory/session"

status_output=$("${cli[@]}" auth status --session "$session_file")
test "$status_output" = "logged out"

set +e
mutation_output=$(printf 'n\n' | "${cli[@]}" registration add TEST000 \
  --module autumn-a --day 1 --period 1 --session "$session_file" 2>&1)
mutation_status=$?
set -e

test "$mutation_status" -eq 1
grep -q "登録を中止しました" <<<"$mutation_output"

test ! -e "$session_file"

set +e
invalid_module_output=$("${cli[@]}" timetable --module winter-z 2>&1)
invalid_module_status=$?
invalid_day_output=$("${cli[@]}" registration add TEST000 \
  --module autumn-a --day 0 --period 1 --yes 2>&1)
invalid_day_status=$?
invalid_period_output=$("${cli[@]}" registration add TEST000 \
  --module autumn-a --day 1 --period 10 --yes 2>&1)
invalid_period_status=$?
invalid_date_output=$("${cli[@]}" cancellations --from 2025-02-29 2>&1)
invalid_date_status=$?
set -e

test "$invalid_module_status" -eq 1
grep -q 'unknown module "winter-z"' <<<"$invalid_module_output"
test "$invalid_day_status" -eq 1
grep -q -- '--day は 1 から 7' <<<"$invalid_day_output"
test "$invalid_period_status" -eq 1
grep -q -- '--period は 1 から 9' <<<"$invalid_period_output"
test "$invalid_date_status" -eq 1
grep -q 'date must use YYYY-MM-DD: "2025-02-29"' <<<"$invalid_date_output"
