# Read performance implementation and review — 2026-09-30

## Implemented scope

Five implementation owners handled the five proposed changes, followed by a
combined review and integration checks.

1. Single-module and all-module timetable reads now reuse sequential GET
   connections by default. `--no-reuse-connections` supports diagnostics.
   Registration mutations retain their separate transport.
2. The private `self` adapter uses one `timetable --all --json` command instead
   of eight single-module processes. It validates every module before merging
   any timetable result. The logical timetable GET count falls from 16 to 9;
   a complete TWINS sync uses four CLI processes instead of eleven.
3. Notice search POSTs remain outside the pool. Only subsequent GET pagination
   uses the scoped connection pool, including cleanup on partial results and
   failures.
4. Requests advertise gzip, with identity fallback and an identity diagnostic
   setting. Decoding validates gzip framing and checksums, supports concatenated
   members, and limits decoded responses to 32 MiB. Profiles distinguish
   decoded `bytes` from encoded-body `wireBytes`.
5. Notice accumulation uses a hash table and reverse list, preserving the
   first object, encounter order, bounds, and completeness. This removes the
   quadratic item scan and list copying.

## Review findings addressed

- Structured errors in `self` must come from the last nonempty stderr line:
  Nix can prepend build logs or warnings. The adapter now validates that exact
  safe error envelope and preserves bounded retry and authentication recovery.
- An all-module batch needs a 120-second process deadline rather than the
  former 30-second single-module deadline.
- HTTP timeouts have a distinct sanitized `timeout` code. A transport timeout
  is not treated as a successful empty timetable or as a missing result table.
- Cohttp 6.2.1 can select a connection whose response announced closure before
  its EOF callback removes it. A bounded loopback probe reproduced an immediate
  follow-up GET timeout in three of three attempts. The transport retires such
  a pool after consuming the response and sends the next unsent GET on a new
  connection; it does not replay requests.

## Measurement limits

Canonical pinned GitHub flakes were used for authenticated reads. Full parsed
outputs were compared in memory; no course rows, notice text, URLs, flow keys,
cookies, or credentials are retained in the performance records.

The initial timing pass overlapped this task's full `self` verification and was
discarded as a performance comparison. It also included one failed preliminary
notice read whose diagnostic was not retained; its cause cannot be attributed
to the independently reproduced close-response race. An isolated repeat read
completed, and notice timings varied substantially. No end-to-end notice
speedup is claimed from that preliminary sample.

After those checks stopped, three alternating comparisons of the final
reviewed revision (`6bed88692c6215c6d83253f996b222585435fdb1`) showed the
all-module timetable median at 2.779 seconds versus 4.047 seconds for the
previous default (`fb116c5efc4b683ed1b4a9470c67f5a2c26fde22`), a 31.3%
reduction. Every complete parsed output matched. All three final reads used
one connection for 18 HTTP hops. The earlier implementation measured
2.563 seconds versus 4.026 seconds (36.3%); both experiments are retained in
the accompanying JSON record. These are small diagnostic samples, not latency
guarantees. Timings include the canonical Nix command after package warmup.

TWINS returned equal encoded and decoded body sizes in the measured timetable
reads (2,515,618 bytes), including when gzip was advertised. Compression support
is implemented and verified offline; an additional live compression benefit
was not observed.

The implemented notice collector's offline native benchmark used OCaml 5.4.1,
100 items per page, and nine-sample medians. At 1,000 unique items it took
0.096 ms versus 2.770 ms; at 5,000 it took 0.604 ms versus 63.114 ms. Allocation
at 5,000 items fell from 287.266 MiB to 1.538 MiB. Complete results matched for
unique/duplicate data and limit boundaries. These numbers exclude HTTP and
HTML parsing, so they are not CLI end-to-end speedups.

## Validation

- Nix package checks include all 81 offline tests, plus a CLI smoke
  check. Tests cover gzip corruption/truncation/checksums/expansion bounds,
  complete body consumption, connection cleanup, no automatic retries,
  notice limits, first-occurrence ordering, and transport restoration.
- The `self` integration passed all 387 tests, TypeScript checks, build, secret
  checks, and formatting checks for the changed files. Its repository-wide
  formatting check still reports one unchanged pre-existing Markdown file.
- Live adapter verification uses a temporary snapshot root and the canonical
  pinned runner, then deletes the temporary snapshots. The private adapter
  record retains only counts, coverage, command count, and timings. With the
  final CLI revision pinned, all 11 coverage slices were complete using four
  commands. The single all-module timetable command took 2.827 seconds; the
  complete adapter run took 15.431 seconds. This is an acceptance check, not a
  before/after measurement of the adapter.
