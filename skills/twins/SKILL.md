---
name: twins
description: Operate a University of Tsukuba TWINS/CAMPUSSQUARE account through the twins-cli Nix flake. Use for TWINS authentication status, grades, timetables, class or general notices, unread notices, class cancellations, course registration or removal, and low-level TWINS menu flows. Trigger on TWINS, CAMPUSSQUARE, 筑波大学, 成績, 時間割, 掲示, 休講, and 履修登録 requests.
---

# TWINS

Use the unofficial `twins` CLI instead of navigating the TWINS web UI. Keep
routine reads direct and make account-changing operations deliberate.

## Resolve the CLI

Run every command as:

```console
nix run github:Kyure-A/twins-cli -- COMMAND ...
```

For example:

```console
nix run github:Kyure-A/twins-cli -- grades --json
```

Command examples below are the arguments after the runner's `--`. A `twins`
binary already on `PATH` (for example from `nix profile install` or a build of
this repository) is an acceptable substitute only when `twins --version`
matches the flake. If Nix is unavailable and no matching binary exists, report
that blocker instead of guessing at another tool.

Do not inspect the repository or reread its README for routine operations.
Run `COMMAND --help=plain` only when an option is unclear or a command fails
because the interface changed.

## Authenticate safely

Before the first authenticated operation in a task, run `auth status`. If
logged out, or an authenticated command reports that login is required, obtain
a fresh session with `auth login`:

- Interactive terminal: `auth login -u UNIFIED_AUTH_ID` prompts for the
  password on a hidden prompt.
- Non-interactive: set `TWINS_USERNAME` and pipe the password from a secret
  store into `auth login --password-stdin` (`TWINS_PASSWORD` is also
  honored by the CLI).
- Use a different session file only when the user asks, via `--session FILE`
  or `TWINS_SESSION`.

Then rerun `auth status` and resume the original request.

- Never request, accept, echo, or store a TWINS password in chat, and never
  put one in a shell argument. Let the user's secret store or hidden prompt
  supply it.
- Legacy unscoped sessions appear logged out; reauthenticate through the normal
  login flow. A failed login leaves the prior file untouched.
- Never inspect or reveal the session cookie file. The CLI stores only session
  cookies under `$XDG_STATE_HOME/twins-cli/session` or
  `~/.local/state/twins-cli/session`.
- If login fails, report the exact failing layer (Nix, network, unified
  authentication, TWINS). Do not fall back to browser automation unless the
  user asks for that expansion.

Run `auth logout` only when the user explicitly asks to remove the saved local
session.

## Choose the operation

Prefer JSON whenever the command supports it:

- Get grades with `grades --json`.
- Get a timetable with `timetable --module MODULE --json`.
- For all eight modules, use one `timetable --all --json` call. It returns a
  `snapshots` object mapping every module slug to its row array, including empty
  arrays. The single-module command returns only its row array. Choose exactly
  one of `--module` or `--all`.
- List notices with `notices --kind classes|general --json`.
- Filter notices with `--unread`, `--title TEXT`, or `--limit N`.
- For complete mirror reads use `notices --all --max-pages 20 --metadata --json`;
  inspect `completeness` and `reason`. Never treat a partial result as a complete
  replacement. Unknown JavaScript pagers are reported as partial.
- Notice pagination reuses GET connections after the search POST by default.
  Use `--no-reuse-connections` only for a requested transport comparison.
- Read one notice with `notice --kind classes|general ID`.
- Get cancellations with `cancellations --from YYYY-MM-DD --to YYYY-MM-DD`; add `--all` only when the user wants unregistered courses too.
- List known low-level flows with `menu --json`.

Use these module mappings:

- 春A/B/C: `spring-a`, `spring-b`, `spring-c`
- 夏季休業: `summer`
- 秋A/B/C: `autumn-a`, `autumn-b`, `autumn-c`
- 春季休業: `spring-break`

Use explicit ISO dates and interpret relative dates in `Asia/Tokyo`. Do not guess an ambiguous module. Ask when the answer would materially change the result.

Treat opening a notice as potentially marking it read. When the user asks only to list or summarize which notices are unread, list metadata first and do not fetch every notice body without permission.

Return only the academic or account data needed for the request. Do not persist, export, or commit grades, notices, or session data unless explicitly asked.

## Diagnose timetable performance

For an explicitly requested parallel-read experiment, `grades`, `timetable`,
and `notices` support `--no-persist-session`. Each process uses the saved login
but keeps cookie updates and authentication-failure clearing in memory, leaving
the saved session file unchanged. Do not copy or inspect the cookie file. This
does not create separate server login sessions. Use independent flows, bound
concurrency, compare complete outputs with a serial control using the same flag,
and check `auth status` after all workers finish. Keep ordinary reads persistent;
this option is for diagnostics, not automatic login recovery.

For a requested notice-flow investigation, add `notices --diagnose`. Its stderr
report distinguishes initial/search/pagination responses using only HTTP status,
counts, and allowlisted structural facts. Flow-key presence/equality and selected
notice-kind categories are retained without the underlying values or text.
Marker booleans alone do not establish a server-side cause. Never fetch notice
details or persist raw pages just to diagnose notice-list concurrency.

When investigating fetch latency, add `--profile` to the requested timetable
read, for example `timetable --all --json --profile`. It supports single-module
reads too and follows the same authentication policy above. Do not enable it for
routine reads or perform registration changes to benchmark fetching.

Stdout retains the normal timetable data. Stderr receives one JSON line under
`profile` with version `1`, success/failure outcome, wall/CPU milliseconds,
per-stage timings, and HTTP-hop status, body bytes, and timings. Batch profiles
also identify the initial flow's selected module when recognizable. These
diagnostics exclude URLs, cookies, flow keys, course data, and raw page text.
On failure the profile line precedes the existing error line; distinguish the
two objects instead of treating all stderr as a single error document.

Nested stages overlap and must not be summed. HTTP `headersMs` includes
connection setup and server response time; `bodyMs` covers body consumption
and content decoding. `bytes` is the materialized response size; `wireBytes`
is the encoded HTTP body after transfer framing, excluding headers and TLS.
Requests advertise gzip by default; `TWINS_HTTP_COMPRESSION=identity` disables
negotiation for a requested comparison. Servers may return identity either way,
so compare `wireBytes` and complete outputs before claiming compression gains.
Malformed gzip, unsupported encodings, and decoded bodies over 32 MiB fail
before parsing. The total
excludes Nix and process startup, so compare it with runner wall time when
investigating that overhead. Report measured timings separately from proposed
optimizations; an unidentified initial module does not justify skipping its
explicit selection.

Timetable reads reuse HTTP connections by default, including single-module
reads and reads without profiling. For a requested comparison, compare the
normal profiled read with `--no-reuse-connections`; this diagnostic option also
works without `--profile`. Reuse uses sequential GET requests, one connection
at a time, pipeline depth one, and no automatic retries, then closes the pool
on success or failure. Registration changes do not use this pool. The profile
reports `transport` as `reuse`, or `default` with reuse disabled.
`connectionsCreated` is unknown (`null`) with reuse disabled; the reuse count
measures created connection objects, not successful sockets. Verify equality of
complete timetable outputs when comparing variants.

## Change registration

Treat `registration add`, `registration remove`, and any `raw --event` submission as account-changing operations.

Before adding a course:

1. Require the exact course code, module, weekday, and starting period.
2. Map weekdays from Monday `1` through Sunday `7`; accept periods `1` through `9`.
3. Present the resolved course code, module, weekday, and period.
4. Obtain explicit user confirmation immediately before execution.
5. After confirmation, run `registration add COURSE_CODE --module MODULE --day DAY --period PERIOD --yes`.

Before removing a course:

1. Require the exact course code and module.
2. Present both values and explain that the registration will be removed.
3. Obtain explicit user confirmation immediately before execution.
4. After confirmation, run `registration remove COURSE_CODE --module MODULE --yes`.

Never add `--yes` before confirmation. Never add `--force-limit` preemptively. If TWINS reports an annual credit-limit override, show the result and obtain separate confirmation before retrying with `--force-limit`.

After a successful change, report the exact CLI result. Normal registration
changes are verified by a fresh query, including preservation of other courses. If a mutation times out or returns an ambiguous result, do not retry automatically; check current state or ask the user to verify it first.

## Lottery pre-registration

Use `pre-registration`, not ordinary `registration add`, for 事前登録対象 courses:

1. `pre-registration groups --module MODULE --json` lists currently open groups.
2. `pre-registration courses --module MODULE --group ID_OR_NAME --json` shows
   the group's courses, current ranks, capacity, and first-choice counts.
3. Resolve the exact course, group, and rank from the live results. Once the user
   authorizes that preference, run `pre-registration add COURSE_CODE --module
   MODULE --group ID_OR_NAME --rank N --yes --json`.
4. `pre-registration list --json` returns the stored preferences. The add command
   also re-fetches this inquiry before reporting success.

Preferences in other courses are preserved; rank collisions fail rather than
reordering them. A matching existing preference is a verified no-op. Do not
interpret `pre_registered` as confirmed enrollment. If a write fails ambiguously,
read the inquiry before retrying. Category/group identifiers must come from live
links; never infer them from a course number or weekday.

## Use raw flows sparingly

Prefer a dedicated command whenever one exists. Use `raw MENU_OR_FLOW` without `--event` only for a requested low-level read.

Before sending `raw --event`:

1. Resolve the flow, form, event, and every `NAME=VALUE` field.
2. Explain that the event is a low-level form submission whose side effects may be unclear.
3. Obtain explicit confirmation.
4. Add `--yes` only after confirmation.

Do not invent flow names, form names, events, or field values. Discover available flows with `menu --json` and inspect `raw --help=plain` when necessary.

## Handle failures

Timetable JSON reads emit stdout only after the entire request succeeds; do not
replace a local mirror after a failed batch. Operational failures and invalid
module selection return exit status 1 with `{"error":{"code":"..."}}` on
stderr; HTTP failures also include `httpStatus`. Codes include
`authentication_required`, `http_error`, `protocol_error`, `timeout`, `io_error`,
`invalid_argument`, `cancelled`, and `unexpected_error`. These errors omit
server content, URLs, and session details. Argument-parser syntax errors retain
their usual diagnostics.

Show actionable CLI errors concisely without exposing cookies or credentials. If TWINS markup or a Spring Web Flow has changed, report that the unofficial client may need an update. Do not fall back to browser automation or the official web interface unless the user asks for that expansion.
