# Four-way read experiment — 2026-09-30

Follow-up: [cause isolation and guarded concurrent reads](notice-flow-resolution-2026-09-30.md)
resolves the interference observed here. This document preserves the original
failed experiment and its then-current uncertainty.

## Result

The four-way experiment did not produce a complete successful read. Both serial
controls completed, while both concurrent attempts failed in general notices.
There is no valid parallel speedup measurement, and the normal `self` adapter
remains sequential with its existing CLI pin.

| Attempt | Serial control | Four concurrent processes |
|---|---:|---|
| 1 | 15.042 s, complete | General notices failed; error category and failure time were not retained |
| 2 | 13.809 s, complete | General notices failed after 2.913 s: missing notice result table |

The second concurrent attempt completed grades and timetable processes before
the notice error; unfinished workers were terminated. A failed batch never
counts as successful coverage or replaces a snapshot. Its 2.913-second duration
measures time to failure, not time to fetch the requested data.

## Scope and controls

The four operations were grades, all eight timetable modules, complete class
notices, and complete general notices (`--all --max-pages 20 --metadata`).
Timetable modules remained sequential within their own flow. This experiment
does not test four-way timetable module traversal.

Every authenticated command used the canonical GitHub flake pinned to
`734bccf2750550a26207eaccbe4ecd819ccbddb4`. Each operation ran in its own process
with `--no-persist-session`, for both the serial and concurrent cases. Cookie
updates and authentication-failure clearing stayed in process memory. The
measurement program never inspected, copied, or exported a cookie file.
Separate processes also isolated the existing transport and profile globals.

An initial preflight found an expired login before any measured operation.
The established managed authentication recovery completed successfully before
the trials. Authentication was verified before and after each measured
attempt; all four checks reported logged in. No login or status operation ran
between worker launches or during a measured batch.

The first attempt stopped on its first parallel error, so the planned three
comparisons were not completed. The probe was then improved to classify known
text errors without retaining their original messages, preserve the first
failing operation, and record incomplete-batch timing. One diagnostic repeat
identified the missing result table. No further parallel retry was performed.

The probe validates all eight timetable keys and notice completeness, comparing
complete parsed outputs in memory when a batch finishes. Failed concurrent
batches did not reach the complete-output equality check. The retained JSON
contains only timings, equality flags, authentication booleans, and sanitized
failure categories; it contains no academic rows, notice text, cookies, URLs,
or flow keys.

## Interpretation

The observed failure is an unexpected page shape, not a measured transport
timeout. Class and general notices both open `KJW0001100-flow`, then submit
`keijiSearchForm` with different notice-kind selectors. Their client-side
execution keys and pagination responses are isolated by process.

Server-side interference between concurrent flows sharing a login is a
candidate explanation. The missing table alone does not identify the server's
internal state or prove that the two notice kinds specifically conflict.
A future discriminating experiment could serialize the two notice streams
while overlapping them with grades and timetable. Independent login sessions
would require separate evidence about the server's login behavior.

## Implementation and review

- `Session.t` has a per-instance persistence flag, defaulting to true. The
  diagnostic flag is available only on grades, timetable, and notice-list
  commands. Existing authentication and registration behavior is unchanged.
- Synthetic tests cover response-cookie updates, authentication clearing,
  exact saved-file preservation, absent directories, and ordinary persistence.
- All 83 offline tests and the Nix package/CLI smoke checks passed.
- Independent review found and fixed UTF-8 chunk decoding and output-limit
  success races in the measurement script. Script syntax and diff checks pass.

The reproducible probe is `scripts/benchmark-parallel-reads.mjs`; numeric
observations are in `parallel-read-performance-2026-09-30.json` beside this file.
