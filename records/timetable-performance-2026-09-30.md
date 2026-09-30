# Timetable fetch analysis — 2026-09-30

## Result

Sequential HTTP connection reuse reduced median end-to-end all-module fetch
time from **4.134 s to 2.873 s**, a **1.261 s / 30.5% reduction** in three
alternating comparisons per mode. All eight modules' complete output matched
in every comparison. Connection reuse is currently an **opt-in measurement
experiment**, not the default transport.

The principal avoidable cost is creating a TCP/TLS connection for every HTTP
hop. The default Cohttp 6.2.1 client uses `No_cache`; its implementation resolves
and connects on every call, then closes the connection after consuming the
response body. The experimental pool created one connection object for all
18 successful HTTP hops in each trial. It uses sequential requests, no
pipelining, and `retry:0`; failures do not trigger automatic replay.

## Measurement method

- All authenticated reads used pinned canonical GitHub flakes via `nix run`.
  No direct local executable, registrations or cancellations were used.
- Baseline profiler: `0c2dd347ee616ef9193f3e429cabdbbfaab19e44`.
- Paired comparison, both modes: `ac7e5fd7d0c0fb63742347e3d0db29ef3b73a043`.
- Warmed each exact flake with `timetable --help=plain`, then timed the complete
  spawned process and collected `--profile` stderr records.
- Comparison order: default, reuse, reuse, default, default, reuse. All reads
  were sequential against the same authenticated session.
- Timetable stdout was compared in memory as the complete parsed JSON object,
  including all row fields, and never written to disk. Only fixed diagnostic
  fields, numeric measurements, and equality booleans are retained in
  [the measurement record](timetable-profile-2026-09-30.json).
- Three trials are a diagnostic sample, not a broad latency guarantee. Network
  and remote-server timing vary; the first default process also had higher
  startup overhead. The reported improvement uses medians, not the slowest
  first trial.

| Trial | Default | Reuse |
|---|---:|---:|
| 1 | 5.407 s | 2.906 s |
| 2 | 3.969 s | 2.873 s |
| 3 | 4.134 s | 2.830 s |
| Median | **4.134 s** | **2.873 s** |

The earlier three default-only profiler runs were 4.885, 4.305 and 4.381 s.
The application remains pinned to the pre-profiling batch CLI `5e07a38`; this
analysis does not switch its transport or add UI.

## Time breakdown

Each column below uses the run whose total is its mode's median (default
trial 3 and reuse trial 2). Thus these are real representative breakdowns,
not a sum of independently chosen component medians.

| Component | Default | Reuse |
|---|---:|---:|
| HTTP call to response headers | 2,590 ms | 1,510 ms |
| Response body consumption | 943 ms | 781 ms |
| HTML DOM parsing | 377 ms | 356 ms |
| Other CLI work | 29 ms | 29 ms |
| Outside CLI profile: process/Nix/CLI startup and exit, profile emission | 194 ms | 197 ms |
| **End to end** | **4,134 ms** | **2,873 ms** |

`headersMs` includes resolution, TCP/TLS setup, request transmission, server
processing, network latency and response-header reading. It cannot isolate
TLS or pure server time. `bodyMs` includes body reading and buffering. The
outside-profile remainder is not a pure Nix-startup measurement. Stage scopes
are inclusive: `initial_flow` and `module_fetch` already contain HTTP, HTML
parsing and page checks, so they must not be added to those child timings.

The representative default process used 497 ms of CPU during 3,939 ms of CLI
wall time; the reuse process used 423 ms during 2,676 ms. CPU time overlaps
the wall-time components and is not an additional duration.

## Request shape and remaining opportunities

Every measured run made **9 logical GET operations**: one initial flow plus
eight module searches. Each produced a `302` followed by a `200`, for
**18 HTTP hops**. The nine HTML responses totaled **2,515,618 bytes**; all
redirect response bodies were empty. The same Web Flow execution key chain
must be followed in order. Simply parallelizing searches within that flow
would use stale keys.

1. **Promote connection reuse after deciding its production scope.** This is
   the only additional optimization with a measured end-to-end benefit in
   this analysis. Retain sequential traversal, complete response consumption,
   bounded timeouts, explicit connection cleanup and no automatic replay.
2. **Test HTTP compression support next.** The reuse trial still spent about
   0.78 s consuming 2.52 MB of HTML. Server support and net savings have not
   been measured. The current client neither requests nor decodes gzip;
   adding only `Accept-Encoding` is insufficient. Request compression only
   with a working decoder, then compare complete outputs and timing again.
3. **Reduce full-document parsing if needed.** Nine DOM parses cost about
   0.36 s after reuse. Timetable row extraction itself is only about 17 ms;
   optimizing table selectors alone will not recover the DOM-parsing cost.
   Reduced parsing must preserve flow, authentication and timetable checks.
4. **Investigate initial-page reuse, but do not skip a module yet.** The
   initial page has a recognizable timetable, but positive module detection
   was `null` in all nine runs. It therefore cannot safely replace the
   explicit spring-a search. A future improvement needs reliable active-module
   evidence and complete equality checks, or a verified way to request that
   module in the initial flow.
5. **Startup and persistence are lower priority.** Warm outside-profile
   overhead is roughly 0.2 s. Session load plus save is about 1–2 ms, JSON
   output below 1 ms, and redirects have no body allocation worth removing
   in this sample. The batch already loads/saves the session once. Direct
   store-binary execution was not tested because this environment requires
   canonical GitHub-flake invocation for authenticated university commands.

Application cache behavior already avoids TWINS reads on a valid cached
reload and module switch. A manual pull or change preview uses one all-module
batch. Apply uses preflight and final batches plus each action's own checks;
those reads validate different points in the mutation lifecycle and should
not be removed as part of this read-only performance analysis.

## Reproduction and code references

Normal diagnostic read:

```console
nix run github:Kyure-A/twins-cli/ac7e5fd7d0c0fb63742347e3d0db29ef3b73a043 -- timetable --all --json --profile
```

For the comparison, append `--reuse-connections`. Timetable data is on stdout;
the sanitized numeric profile is on stderr. Do not persist timetable stdout
unless that is explicitly intended. Profile output never includes cookies,
HTML, course data, request URLs, exception text or flow keys.

- [HTTP implementation](../lib/http_client.ml): default transport and scoped
  sequential `retry:0 / parallel:1 / depth:1` pool.
- [Timetable traversal](../lib/timetable_batch.ml) and
  [fetch orchestration](../lib/twins.ml).
- [Profiling schema](../lib/profile.ml).
- [Synthetic connection tests](../test/test_http_pool.ml): reuse across
  separate event-loop runs, GET-only guard, no retry on EOF, exception/timeout
  cleanup and default-transport restoration.
- Exact dependency source inspected: Cohttp 6.2.1 `cohttp-lwt/client.ml:10`
  selects `No_cache`; `cohttp-lwt/connection_cache.ml:12–29` resolves, connects
  and closes per call; its optional pool defaults to retry 2 at lines 52–53,
  and lines 139–154 enforce the configured retry limit. This experiment
  explicitly sets that limit to zero.

Validation for the comparison commit: **61 unit tests**, Nix package check,
CLI smoke check, and all six authenticated comparison outputs matched.
