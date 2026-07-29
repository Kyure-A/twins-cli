---
name: twins
description: Operate Kyre's University of Tsukuba TWINS/CAMPUSSQUARE account through the canonical GitHub flake for the unofficial twins CLI. Use for TWINS authentication status, grades, timetables, class or general notices, unread notices, class cancellations, course registration or removal, and low-level TWINS menu flows. Trigger on TWINS, CAMPUSSQUARE, 筑波大学, 成績, 時間割, 掲示, 休講, and 履修登録 requests.
---

# TWINS

Use the unofficial `twins` CLI from its canonical GitHub flake instead of navigating the TWINS web UI. Keep routine reads direct and make account-changing operations deliberate.

## Resolve the CLI

Always invoke the canonical GitHub flake directly:

```text
github:Kyure-A/twins-cli
```

Run every command in this form:

```console
nix run github:Kyure-A/twins-cli -- COMMAND ...
```

For example:

```console
nix run github:Kyure-A/twins-cli -- grades --json
```

Do not invoke a `twins` executable from `PATH` or a global installation, and do not run a local checkout. Treat command examples below as arguments following the runner's `--`. Do not inspect the repository or reread its README for routine operations. Run `nix run github:Kyure-A/twins-cli -- COMMAND --help=plain` only when an option is unclear or a command fails because the interface changed.

## Authenticate safely

Before the first authenticated operation in a task, run:

```console
nix run github:Kyure-A/twins-cli -- auth status
```

If logged out or an authenticated command reports that login is required,
recover the session through Kyre's existing Bitwarden Secrets Manager path:

```console
cd /Users/kyre/ghq/github.com/Kyure-A/self
nix develop -c npm run self -- secrets exec -- \
  npm run self -- university login
```

Then rerun:

```console
nix run github:Kyure-A/twins-cli -- auth status
```

Do not ask Kyre to perform a manual login or provide credentials while this
managed recovery path is available. If recovery fails, report the exact failing
layer only after attempting it. Never request, accept, print, or store a TWINS
password in chat. Never inspect or reveal the session-cookie file. Use the
default session unless the user explicitly supplies a different `--session`
path.

Run `nix run github:Kyure-A/twins-cli -- auth logout` only when the user explicitly asks to remove the saved local session.

## Choose the operation

Prefer JSON whenever the command supports it:

- Get grades with `grades --json`.
- Get a timetable with `timetable --module MODULE --json`.
- List notices with `notices --kind classes|general --json`.
- Filter notices with `--unread`, `--title TEXT`, or `--limit N`.
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

After a successful change, report the exact CLI result and advise verifying it in the official TWINS interface. If a mutation times out or returns an ambiguous result, do not retry automatically; check current state or ask the user to verify it first.

## Use raw flows sparingly

Prefer a dedicated command whenever one exists. Use `raw MENU_OR_FLOW` without `--event` only for a requested low-level read.

Before sending `raw --event`:

1. Resolve the flow, form, event, and every `NAME=VALUE` field.
2. Explain that the event is a low-level form submission whose side effects may be unclear.
3. Obtain explicit confirmation.
4. Add `--yes` only after confirmation.

Do not invent flow names, form names, events, or field values. Discover available flows with `menu --json` and inspect `raw --help=plain` when necessary.

## Handle failures

Show actionable CLI errors concisely without exposing cookies or credentials. If TWINS markup or a Spring Web Flow has changed, report that the unofficial client may need an update. Do not fall back to browser automation or the official web interface unless the user asks for that expansion.
