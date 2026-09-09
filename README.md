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

# Notices and cancellations
twins notices --kind classes --unread --limit 20
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
