# Eight-worker read experiment — 2026-09-30

## Result and workload

The eight-worker experiment failed to fetch the complete workload. Serial and
four-process controls succeeded; one concurrent timetable read failed at
parsing. The eight-worker duration is not a valid speedup measurement.

The workload is grades, all eight timetable modules, and complete class/general
notice lists. Notices are the TWINS announcement search/list screen, accessed
by `notices` (`KJW0001100-flow`), not another timetable module. Earlier totals
around ten seconds included all these data sources; timetable alone took about
2.7 seconds in this run.

| Mode | Wall time | Coverage |
|---|---:|---|
| Serial, four CLI calls | 12.502 s | Complete |
| Four CLI processes | 11.527 s | Complete; all outputs equal to serial |
| Pool of eight CLI processes | 9.805 s | **Incomplete**; autumn-c failed after 0.717 s |

Eight workers split `timetable --all` into eight single-module calls, retaining
grades and the two notice calls, for eleven planned calls over the same data.
Both notice readers and grades started first; timetable modules filled the
remaining slots. The notice lock stayed enabled. The first eight jobs started
before the error was observed, and the final three queued timetable jobs never
started. Running peers finished under the existing per-command bound.

Four completed timetable modules matched their serial snapshots. Grades and
both complete notice lists also matched. The failed autumn-c command received
HTTP 200 with a 1,464-byte body, then reported a protocol error in
`timetable_parse`. This resembles the short invalid notice-flow responses in
the previous investigation, but this probe does not independently establish
the server's internal timetable-state behavior. All single-module commands
start the same `RSW0001000-flow`, so cross-execution interference remains the
leading explanation.

Authentication remained valid before and after the experiment. No retries or
remaining rounds were attempted after the failure. A planned three-round run
therefore produced only one serial/four/eight comparison.

## Remaining latency

The complete four-process run finished grades in 0.706 s and all timetable
modules in 2.824 s. General notices finished in 7.402 s and the other notice
reader, including its lock wait, in 11.525 s. The serialized notice lane still
determines the finish time. Even successful parallel timetable reads would
not remove that work.

Splitting the timetable also repeats initialization: eight single-module calls
require sixteen logical GETs before redirects, compared with nine for the
batch implementation. Both complete controls recorded eighteen HTTP hops for
their batch timetable. Extra workers are not equivalent to less server work.

A candidate for a later optimization is fetching both notice kinds within one
Web Flow, reusing the current search form after completing the first kind.
Existing diagnostics retain a search form and execution key after search and
paging. This may remove one expensive initialization, but it has not yet been
implemented or validated by complete-output comparisons. No speedup is claimed
for that candidate.

## Implementation and validation

The canonical GitHub flake was pinned to
`9144ef7feb360a20d76a5cb47d4d7e946939db61` and warmed before timing. Every worker
used `--no-persist-session`. The script never inspected or copied a real cookie
file, stored account results, fetched notice details, or changed registration.
It compared returned rows only in memory. The retained profiles include only
allowlisted numbers, fixed labels and module slugs, with no URLs, flow keys,
course values or notice content.

The single-module API now validates the selected module/term before parsing
when the response exposes recognizable selection controls, matching the
existing batch behavior. The probe additionally compares every
module array against the serial batch, then reconstructs and checks the whole
eight-module result before calling an eight-worker run successful.

All 98 offline OCaml tests and Nix package/CLI smoke checks passed on
aarch64-darwin. Three new synthetic Node integration tests cover the eleven-job
queue and eight-worker bound, full-result mismatches, error redaction, stopping
queued work after failure, draining active peers and final authentication.
They use an isolated fake executable and invented data without network access.
Independent review found no blocking issue in the scheduler or comparison.

The normal `self` sync adapter remains sequential; this experiment does not
enable eight workers in production.

```sh
node scripts/benchmark-parallel-reads.mjs \
  9144ef7feb360a20d76a5cb47d4d7e946939db61 \
  /tmp/twins-eight-way.json 3 eight-way
```

Numeric evidence: [eight-way-read-performance-2026-09-30.json](eight-way-read-performance-2026-09-30.json).
