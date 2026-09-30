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

timetable_help=$("${cli[@]}" timetable --help=plain)
grep -q -- '--all' <<<"$timetable_help"
grep -q -- '--profile' <<<"$timetable_help"
grep -q -- '--no-reuse-connections' <<<"$timetable_help"
grep -q -- '--no-persist-session' <<<"$timetable_help"
grades_help=$("${cli[@]}" grades --help=plain)
grep -q -- '--no-persist-session' <<<"$grades_help"
if grep -q -- '--no-persist-session' <<<"$registration_help"; then
  exit 1
fi

menu_output=$("${cli[@]}" menu)
grep -q $'registration\tRSW0001000-flow' <<<"$menu_output"
grep -q $'grades\tSIW0001200-flow' <<<"$menu_output"

smoke_directory=$(mktemp -d)
trap 'rm -rf -- "$smoke_directory"' EXIT
session_file="$smoke_directory/session"

# These failures are local validation only, before any session or network read.
expect_timetable_json_error() {
  local expected_code=$1
  shift
  local status=0
  "${cli[@]}" timetable --json --session "$session_file" "$@" \
    > "$smoke_directory/timetable.stdout" \
    2> "$smoke_directory/timetable.stderr" || status=$?
  test "$status" -eq 1
  test ! -s "$smoke_directory/timetable.stdout"
  test "$(< "$smoke_directory/timetable.stderr")" = \
    "{\"error\":{\"code\":\"$expected_code\"}}"
}

expect_profiled_timetable_error() {
  local expected_code=$1
  shift
  local status=0
  "${cli[@]}" timetable --json --profile --session "$session_file" "$@" \
    > "$smoke_directory/profile.stdout" \
    2> "$smoke_directory/profile.stderr" || status=$?
  test "$status" -eq 1
  test ! -s "$smoke_directory/profile.stdout"
  {
    IFS= read -r profile_line
    IFS= read -r error_line
    if IFS= read -r extra_line; then
      exit 1
    fi
  } < "$smoke_directory/profile.stderr"
  grep -q '^{"profile":{' <<<"$profile_line"
  grep -Fq '"version":1' <<<"$profile_line"
  grep -Fq '"operation":"timetable"' <<<"$profile_line"
  grep -Fq '"outcome":"failure"' <<<"$profile_line"
  grep -Fq '"http":[]' <<<"$profile_line"
  test "$error_line" = "{\"error\":{\"code\":\"$expected_code\"}}"
}

expect_timetable_json_error invalid_argument
expect_timetable_json_error invalid_argument --all --module autumn-a
expect_timetable_json_error invalid_argument --module winter-z
expect_profiled_timetable_error invalid_argument --module winter-z --no-reuse-connections
grep -Fq '"stages":[]' <<<"$profile_line"
grep -Fq '"transport":"default"' <<<"$profile_line"
grep -Fq '"connectionsCreated":null' <<<"$profile_line"
test ! -e "$session_file"

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

pre_help=$("${cli[@]}" pre-registration add --help=plain)
grep -q -- '--group=ID_OR_NAME' <<<"$pre_help"
grep -q -- '--rank=N' <<<"$pre_help"
set +e
pre_cancel=$(printf 'n\n' | "${cli[@]}" pre-registration add TEST000 --module autumn-a --group test --session "$session_file" 2>&1)
pre_cancel_status=$?
pre_invalid=$("${cli[@]}" pre-registration add TEST000 --module autumn-a --group test --rank 0 --yes --session "$session_file" 2>&1)
pre_invalid_status=$?
set -e
test "$pre_cancel_status" -eq 1
grep -q '事前登録を中止しました' <<<"$pre_cancel"
test "$pre_invalid_status" -eq 1
grep -q -- '--rank must be positive' <<<"$pre_invalid"
test ! -e "$session_file"

notice_help=$("${cli[@]}" notices --help=plain)
grep -q -- '--all' <<<"$notice_help"
grep -q -- '--metadata' <<<"$notice_help"
grep -q -- '--max-pages=N' <<<"$notice_help"
grep -q -- '--no-reuse-connections' <<<"$notice_help"
grep -q -- '--no-persist-session' <<<"$notice_help"

set +e
invalid_pages=$("${cli[@]}" notices --max-pages 0 --metadata --json --session "$session_file" 2>&1)
invalid_pages_status=$?
set -e
test "$invalid_pages_status" -eq 1
grep -q -- '--max-pages must be 1..100' <<<"$invalid_pages"
test ! -e "$session_file"

# Synthetic legacy cookies must be retained, while status enables managed login.
printf '# legacy fixture\nsid\tfake-fixture\n' > "$session_file"
cp "$session_file" "$session_file.before"
status_output=$("${cli[@]}" auth status --session "$session_file")
test "$status_output" = "logged out"
cmp "$session_file" "$session_file.before"

# A synthetic legacy file fails during loading, without contacting TWINS.
expect_timetable_json_error protocol_error --all
cmp "$session_file" "$session_file.before"

# Profiling preserves the same local failure and adds one separate JSON line.
# The synthetic legacy session fails before any HTTP request or cookie write.
expect_profiled_timetable_error protocol_error --all
grep -Fq '"stage":"session_load","outcome":"failure"' <<<"$profile_line"
grep -Fq '"transport":"reuse"' <<<"$profile_line"
grep -Fq '"connectionsCreated":0' <<<"$profile_line"
cmp "$session_file" "$session_file.before"

expect_profiled_timetable_error protocol_error --all --no-reuse-connections
grep -Fq '"stage":"session_load","outcome":"failure"' <<<"$profile_line"
grep -Fq '"transport":"default"' <<<"$profile_line"
grep -Fq '"connectionsCreated":null' <<<"$profile_line"
cmp "$session_file" "$session_file.before"

expect_profiled_timetable_error protocol_error --module spring-a
grep -Fq '"transport":"reuse"' <<<"$profile_line"
grep -Fq '"connectionsCreated":0' <<<"$profile_line"
cmp "$session_file" "$session_file.before"

expect_profiled_timetable_error protocol_error --module spring-a --no-reuse-connections
grep -Fq '"transport":"default"' <<<"$profile_line"
grep -Fq '"connectionsCreated":null' <<<"$profile_line"
cmp "$session_file" "$session_file.before"

# The diagnostic opt-out also works for ordinary reads without profiling.
expect_timetable_json_error protocol_error --module spring-a --no-reuse-connections
expect_timetable_json_error protocol_error --all --no-reuse-connections
cmp "$session_file" "$session_file.before"

expect_timetable_json_error protocol_error --all --no-persist-session
expect_timetable_json_error protocol_error --module spring-a --no-persist-session
cmp "$session_file" "$session_file.before"
