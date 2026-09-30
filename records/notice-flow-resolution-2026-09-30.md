# Notice-flow interference and guarded concurrent reads — 2026-09-30

## Cause

Starting and completing another notice read invalidates an earlier notice
execution in the same login. Class and general lists both start
`KJW0001100-flow`; changing the notice-kind selector does not isolate the two
executions. This is an observed server-side flow-lifetime conflict. The
server's internal data structures and configuration were not inspected.

The failed responses were HTTP 200, 1,464 bytes, with a session-expiry marker
and no notice form or result table. Authentication remained valid before and
after every experiment, and a peer reader completed with the serial result.
Consequently a missing table here is not evidence that the login itself ended.
The initial hypothesis that the search POST omitted a flow key was rejected:
the normal form already supplies a hidden key, while its action has no key.

## Controlled evidence

Every experiment used the canonical GitHub flake and `--no-persist-session`.
Returned account JSON was compared only in memory. No real cookie file was
inspected, copied, or exported, and no notice details were opened.

| Experiment | Result |
|---|---|
| Four unguarded CLI processes | General notices failed at initialization; grades, timetable and class notices completed and matched the serial control. |
| Only the two notice readers concurrent | Class notices failed at search; general notices completed and matched. The failure is not specific to general notices. |
| Grades + timetable + one lane for both notice kinds | All four outputs matched. Serial 14.995 s; concurrent 10.571 s. |
| General initial page → pause → complete class read → resume general search | General search failed; class output matched the control. |
| General search results → pause → complete class read → resume general pagination | General page 2 failed; class output matched the control. |

The pause controls use stdin handshakes, not sleeps. They deliberately prevent
overlapping HTTP requests between the two notice readers. Both therefore show
that guarding only flow initialization or individual HTTP requests is
insufficient: the full notice execution must be protected until pagination
finishes. Their durations include the imposed pause and are not speed results.

The first three probes used `861d95d3eadf2bf807bf5c732b7642f0b383c280`; the two
barrier probes used `f3c3e493315218473af8425bd298738356c75519`.
The sanitized observations are in
[`notice-flow-cause-2026-09-30.json`](notice-flow-cause-2026-09-30.json).

## Implementation

`08c19d1f590f630b5c5b5169a03a3c9b2327661d` adds a per-session-path OS process
lock around `notices` and `notice`, covering session load, initialization,
search, every page and final session save. Grades and timetable remain
independent. The lock file is empty, mode 0600, bounded to a 120-second wait,
and released on exit or exception. It is retained between calls so waiters
always coordinate on the same inode.

Diagnostic barriers explicitly bypass the lock with `--no-flow-lock`, which
requires `--diagnose --no-persist-session`. Ordinary read commands keep the
guard enabled. Diagnostics retain only fixed labels, numeric values and
booleans; diagnostic errors also use the safe JSON error format.

The guard coordinates these CLI notice commands using the same session path.
Browsers, raw flow commands and copies of a login do not participate. The
experiment does not establish safety for concurrent cookie-persisting workers
or for parallel timetable modules. The `self` sync adapter and its pinned
revision were not changed by this follow-up experiment.

## Validation

All 98 offline tests and the Nix package/CLI smoke checks passed on
aarch64-darwin. Six lock tests exercise real separate processes, exclusion,
independent paths, timeout without entering the operation, exception release,
unsafe files, nested acquisition and missing session directories. CLI checks
cover diagnostic flag restrictions and content-free local failures.

Independent review confirmed the lifetime scope, pause ordering, worker
cleanup and full-output comparisons. Its diagnostic HTTP-error URL finding
was corrected before the final measurements.

## Four-process measurement

The final probe used `08c19d1f590f630b5c5b5169a03a3c9b2327661d`, warmed before
measurement. Three serial and three guarded four-process batches were run in
alternating order. Every batch returned complete notice coverage, all eight
timetable modules, and full parsed JSON equal to the first serial baseline.
Authentication was valid both before and after the entire run.

| Round | Serial | Four CLI processes, notice readers serialized |
|---|---:|---:|
| 1 | 13.029 s | 10.522 s |
| 2 | 12.644 s | 10.018 s |
| 3 | 12.163 s | 10.692 s |
| Median | **12.644 s** | **10.522 s** |

The median time fell by **16.8% (1.20× throughput for this fixed batch)**.
This is a small live sample, not a general server performance guarantee.
All four CLI processes overlap, but the two notice readers take turns, so at
most three independent read chains can make progress simultaneously. The
long notice chain remains the limiting work; this is not a fourfold speedup.
Per-operation wall times include lock waits. The script's 120-second total
worker bound also includes such waits and is separate from the CLI's lock
acquisition bound.

Reproduce from the repository with:

```sh
node scripts/benchmark-parallel-reads.mjs \
  08c19d1f590f630b5c5b5169a03a3c9b2327661d \
  /tmp/twins-guarded-four-way.json 3 four-way
```

The retained numeric evidence is
[`guarded-parallel-read-performance-2026-09-30.json`](guarded-parallel-read-performance-2026-09-30.json).
