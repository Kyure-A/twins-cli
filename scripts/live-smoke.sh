#!/usr/bin/env bash
set -euo pipefail

twins_url=${TWINS_PUBLIC_URL:-https://twins.tsukuba.ac.jp/campusweb/}
response_file=$(mktemp)
trap 'rm -f -- "$response_file"' EXIT

curl --fail --silent --show-error --location \
  --retry 3 --retry-delay 2 --retry-all-errors \
  --connect-timeout 15 --max-time 45 \
  --user-agent "twins-cli-public-smoke/1.0" \
  --output "$response_file" "$twins_url"

grep -q 'name="userName"' "$response_file"
grep -q 'name="password"' "$response_file"
grep -q "'rwfHash'" "$response_file"
