# twins-cli

An unofficial OCaml command-line client for the University of Tsukuba's
TWINS/CAMPUSSQUARE system. It drives the same HTML and Spring Web Flow endpoints
as the web interface; it does not use an official API.

## Features

- Session login, status, and logout
- Grades and timetables in TSV or JSON
- Course registration and removal
- Lottery pre-registration: groups, course preferences, registration, and inquiry
- Class and general notices
- Class cancellation lookup
- Low-level access to known TWINS menu flows

## Development

The locked Nix flake provides the complete toolchain and dependencies:

```console
nix develop
dune build @all
dune runtest
```

Build or run the packaged CLI without entering the development shell:

```console
nix build
nix run . -- --help
```

An opam package is also provided for non-Nix installations.

## Authentication

```console
twins auth login -u YOUR_UNIFIED_AUTH_ID
twins auth status
```

The password is read from a hidden prompt and is never stored. Only session
cookies are saved, with file mode `0600`, under
`$XDG_STATE_HOME/twins-cli/session` or `~/.local/state/twins-cli/session`.
Override the location with `TWINS_SESSION` or `--session FILE`.

Cookies retain their host/domain, path, Secure flag and expiry. Unscoped session
files from older versions are no longer usable: `auth status` reports logged
out, and `auth login` replaces the old file only after successful authentication.
A failed login retains the existing file. Session writes are atomic and private.
For explicit parallel-read experiments, `grades`, `timetable`, and `notices`
accept `--no-persist-session`. Each process loads the existing cookies normally
and applies response updates only in memory; it neither saves nor deletes the
session file, including on authentication failure. This avoids competing cookie
file writes but does not create independent server login sessions or establish
that concurrent Web Flows are supported. Use the same flag for serial controls
and verify authentication after the experiment. Ordinary reads keep their
existing persistence behavior.

Class and general notices share a server-side Web Flow: starting another notice
flow invalidates a preceding search or pagination execution in the same login.
`notices` and `notice` therefore hold a per-session-file process lock for the
whole operation, including session load/save and every page. The adjacent empty
`SESSION.notices.lock` file contains no cookies; waiting is bounded to 120
seconds and the lock is released on process exit. Do not remove the lock file
while readers are active. Four CLI readers may start together, with grades and
timetables proceeding while the two notice readers take turns. Use
`--no-persist-session` on every worker for concurrent read experiments.
The guard coordinates this CLI using the same session path; browser activity,
raw flow commands, and separate copies of a login do not share it.

`node scripts/benchmark-parallel-reads.mjs COMMIT_SHA OUTPUT_JSON 3` compares
three alternating serial/four-process batches using a full Git revision and
the canonical GitHub flake. It reads grades, all timetable modules, and complete
class/general notice lists. It compares complete JSON values in memory and
retains only timings, equality flags, and sanitized failures. A failure stops
the remaining workers; authentication is checked before and after the run.

The `eight-way` scenario compares serial and four-process batches with a pool
of up to eight processes over the same data. It splits the timetable into eight
single-module reads, for eleven CLI calls in total including grades and both
notice kinds. Notice readers retain their flow lock. Both notice readers start
early; the other slots fetch grades and timetable modules. Each module and the
reassembled eight-module result must match the `timetable --all` serial control.
Splitting repeats timetable flow initialization, so more processes need not be
faster. On the first observed eight-worker failure the pool stops admitting new
work, waits for already running bounded reads, and verifies authentication.
Only sanitized profiles, timings and comparison flags are retained.

```sh
node scripts/benchmark-parallel-reads.mjs COMMIT_SHA OUTPUT_JSON 3 eight-way
```

For notice-flow diagnosis, `notices --diagnose` adds one content-free JSON
report to stderr with the initial/search/pagination stage, page number, HTTP
status, and allowlisted page-shape facts. It never includes URLs, execution
keys, cookies, page text, or error messages. Literal error-marker matches are
signals, not a diagnosis. The benchmark's optional fifth argument selects a
controlled scenario such as `diagnose-four-way`, `notices-pair`, or
`notices-serial`; diagnostic scenarios let bounded peer reads finish after an
error so their outcomes can be compared.
`pause-initial` and `pause-search` use an explicit stdin barrier: one general
notice read pauses after the selected phase, a class notice read finishes, then
the first resumes. These scenarios explicitly bypass the flow lock. The
underlying diagnostic-only `--pause-after` option requires `--no-flow-lock`,
which in turn requires both `--diagnose` and `--no-persist-session`, and resumes
only on an exact `continue` line. These
scenarios establish flow interference; their duration is not a speed benchmark.

All requests and redirects stay on the TWINS HTTPS origin; cross-origin,
non-HTTPS and nonstandard-port targets are rejected before credentials can be
replayed. This matches the CLI's direct TWINS portal login flow.

Each request, including its redirect chain and response body, has a 60-second
timeout. Set `TWINS_HTTP_TIMEOUT` to 1..300 seconds to change it. A timed-out
mutation is never retried automatically; inspect the current state first.

HTTP requests advertise gzip by default and transparently decode compressed
responses. Servers that return an uncompressed body continue to work. Set
`TWINS_HTTP_COMPRESSION=identity` to disable compression negotiation for a
comparison or transport diagnosis (`gzip` restores the default). Decoded bodies
are limited to 32 MiB. Invalid gzip checksums, truncated streams, trailing junk,
and unsupported content encodings fail before HTML parsing.

For non-interactive use, `TWINS_USERNAME`, `TWINS_PASSWORD`, and
`--password-stdin` are supported. Remove the local session with:

```console
twins auth logout
```

## Usage

```console
# Grades and timetable
twins grades --json
twins timetable --module autumn-a
twins timetable --all --json

# Notices and cancellations
twins notices --kind classes --unread --limit 20
twins notices --kind classes --all --max-pages 20 --metadata --json
twins notice --kind classes NOTICE_ID
twins cancellations --from 2026-10-01 --to 2026-10-31

# Registration changes
twins registration add COURSE_CODE --module autumn-a --day 1 --period 1
twins registration remove COURSE_CODE --module autumn-a
```

Registration changes require confirmation. Pass `-y` or `--yes` only when the
operation has already been reviewed. Valid module names are `spring-a`,
`spring-b`, `spring-c`, `summer`, `autumn-a`, `autumn-b`, `autumn-c`, and
`spring-break`.

`registration add` and `remove` query a fresh registration flow after submitting.
Success requires the target course to be present/absent as requested and all
other timetable entries and registration keys to be unchanged. A success-looking
submission response is insufficient. Missing tables and mismatches fail with no
automatic retry.

### Timetable snapshots

Choose exactly one of `--module MODULE` or `--all`. A single-module JSON read
returns an array of timetable rows. `timetable --all --json` returns
`{"snapshots":{"spring-a":[],"spring-b":[],"spring-c":[],"summer":[],"autumn-a":[],"autumn-b":[],"autumn-c":[],"spring-break":[]}}`,
with each array containing that module's rows. All eight keys are present,
including modules with no courses.

The batch loads and saves the session once, opens one registration flow, and
queries modules sequentially using each response's latest flow execution key.
It writes stdout only after every module succeeds; a failed batch never emits
partial snapshots. With `--json`, operational failures and invalid module
selection return exit status 1 and a sanitized JSON error on stderr, such as
`{"error":{"code":"authentication_required"}}`. HTTP failures also include
`httpStatus`. Error output omits server content, URLs, and session details.
Request deadlines use the distinct `timeout` code.
Command-line syntax errors still use the argument parser's usual diagnostics.

### Timetable profiling

Add `--profile` to a timetable read when diagnosing performance:

```console
twins timetable --all --json --profile
```

It also works with `--module MODULE`. Normal stdout is unchanged; stderr gains
one JSON line under `profile`, with `version: 1`, operation outcome, total
`wallMs`/`cpuMs`, stage timings, and HTTP-hop timings. The stages cover session
load/save, initial flow, module fetches, HTML parsing, page/selection checks,
timetable parsing, and output. HTTP records include status, decoded response
`bytes`, encoded response `wireBytes`, `headersMs`, and `bodyMs`. Batch profiles
also report whether the initial
flow contained a recognized timetable and its selected module when identifiable.
Profiles contain no URLs, cookies, flow keys, course data, or raw page text.

`headersMs` includes connection setup and server time through response headers;
it is not server processing time alone. `bytes` counts the materialized body;
`wireBytes` counts the encoded HTTP body after transfer framing, excluding HTTP
headers and TLS overhead. `bodyMs` includes body consumption and content decoding.
Nested stages overlap, so do not sum them. Total timing covers
the CLI operation, excluding Nix and process startup; measure the runner's wall
time separately. On an operational failure, the profile line precedes the usual
error line and the exit status is unchanged. Without `--profile`, stderr keeps
its existing format. Argument-parser syntax errors do not emit a profile.

Timetable reads reuse HTTP connections by default for both single modules and
`--all`. For a comparison with connection reuse disabled, run both variants:

```console
twins timetable --all --json --profile
twins timetable --all --json --profile --no-reuse-connections
```

`--no-reuse-connections` also works with `--module MODULE` and without profiling
when diagnosing transport problems. The GET-only pool uses one connection at a
time, pipeline depth one, and no automatic retries. Requests remain sequential
and the pool closes at the end of the read, including failures. Registration
changes do not use this pool. Profiles identify `transport` as `reuse`, or
`default` when reuse is disabled; `connectionsCreated` is the number of
connection objects created by the pool, or `null` when reuse is disabled. This
count does not prove successful socket connections. Compare complete timetable
outputs as well as timings before drawing conclusions.

### Notice pagination and completeness

Notice listing reuses one GET-only connection pool for pagination after the
search POST completes. The search POST remains outside the pool. Use
`notices --no-reuse-connections` for a diagnostic comparison. Traversal remains
sequential with no automatic replay, and every exit path closes the pool.

Notice searches follow explicit Next links and the observed CampusSquare
`_eventId_paging` / `_pageCount` links without opening notice bodies. The
item limit defaults to 50; `--all` removes that limit. `--max-pages` defaults to
20 and accepts 1..100. Duplicate notice IDs are collapsed and loops are bounded.
`notice ID` also searches up to 20 listing pages before opening only the requested
body (opening it can mark it read).

`--metadata` emits a JSON object with `items`, `completeness` (`complete` or
`partial`), `pages_fetched`, and `reason` (`null`, `limit`, `page_limit`,
`pagination_loop`, or `unsupported_pagination`). Without it, `--json` emits the
notice array and partial coverage is reported on stderr. A missing result table
or a notice row without an ID is an error, not a complete empty result.

JavaScript-only or unrecognized pager controls are reported as partial; their
form events are never guessed. Authenticated table/header topology and numeric
CampusSquare paging links have been verified through redacted diagnostics;
fixtures reproduce that structure using synthetic records only.
Use the metadata when deciding whether absent notices can be removed from a
local mirror.

### Lottery pre-registration

Pre-registration records preferences for the university lottery; it does not
confirm enrollment. Use the group ID or exact name returned by `groups`, then
check the courses and saved preferences:

```console
twins pre-registration groups --module autumn-a --json
twins pre-registration courses --module autumn-a --group GROUP_ID --json
twins pre-registration add COURSE_CODE --module autumn-a --group GROUP_ID --rank 1
twins pre-registration list --json
```

`add` follows the current category and group links, changes only the requested
course's rank, checks the confirmation page, submits once, and fetches a fresh
inquiry. Existing preferences in the group are preserved. Rank conflicts,
closed groups, malformed forms, and unexpected confirmation contents fail
without submitting. An already-saved matching preference is verified without
resubmitting. After an ambiguous network failure, inspect `list` before retrying.
The `--yes` flag skips the CLI prompt when the specific operation is authorized.

Use `twins menu` to list known flows. The `raw` command can open one and
optionally submit a form event:

```console
twins raw graduation-check
twins raw notices --form keijiSearchForm --event findSelect \
  -F keijitype=3 -F keijiTitle=Scholarship
```

For parser diagnostics, add `--structure` to `raw`: it emits table topology,
allowlisted column labels, and pager descriptors without data cells, hidden
values, full URLs, or arbitrary page text.

Run `twins COMMAND --help` for the complete command reference.

## CI

GitHub Actions checks both the opam and Nix builds on Linux and macOS. It also
smoke-tests the installed executable. A daily unauthenticated check detects
changes to the public TWINS login page. TWINS credentials are not stored in
GitHub, so authenticated and mutating operations are not run in CI.

## Disclaimer

Use this tool only with your own account and follow university rules. TWINS
markup may change without notice, and service availability is outside this
project's control. Verify important registration changes in the official web
interface.

Official documentation: [TWINS manual](https://www.tsukuba.ac.jp/campuslife/tool-manual-twins/)
and [manual PDF](https://www.tsukuba.ac.jp/campuslife/calendar-ceremony/orientation-fall/twins_manual.pdf).

Licensed under GPL-3.0-only.
