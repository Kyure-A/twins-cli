import { spawn } from "node:child_process";
import { writeFile } from "node:fs/promises";
import { isDeepStrictEqual } from "node:util";
const revision = process.argv[2],
  output = process.argv[3];
const rounds = Number(process.argv[4] ?? "1");
const scenario = process.argv[5] ?? "four-way";
const scenarios = [
  "four-way",
  "diagnose-four-way",
  "notices-pair",
  "notices-serial",
  "general-and-timetable",
  "general-and-grades",
  "general-pair",
];
if (
  !/^[a-f0-9]{40}$/.test(revision ?? "") ||
  !output ||
  ![1, 2, 3].includes(rounds) ||
  !scenarios.includes(scenario)
)
  throw Error("Expected REVISION OUTPUT [ROUNDS=1..3]");
const diagnose = scenario !== "four-way";
function noticeDiagnostics(stderr) {
  const values = new Set([
    "initial",
    "search",
    "page",
    "success",
    "failure",
    "classes",
    "general",
  ]);
  const keys = new Set([
    "version",
    "outcome",
    "wallMs",
    "stagesStarted",
    "responsesChecked",
    "truncated",
    "phase",
    "pageIndex",
    "httpStatus",
    "bodyBytes",
    "hasNoticeSearchForm",
    "hasNoticeTable",
    "hasGradeTable",
    "hasTimetableTable",
    "hasLoginForm",
    "hasAuthorizationError",
    "sessionExpiredMarker",
    "invalidFlowMarker",
    "windowMarker",
    "concurrentAccessMarker",
    "operationErrorMarker",
    "flowLockMarker",
    "pageHasFlowKey",
    "pagerFlowKeyMatchesPage",
    "selectedKind",
    "searchFormHasFlowKeyField",
    "searchFormActionHasFlowKey",
    "searchFormActionHasFlowId",
    "responseQueryHasFlowKey",
    "responseQueryHasFlowId",
  ]);
  const clean = (obj) =>
    Object.fromEntries(
      Object.entries(obj).filter(
        ([k, v]) =>
          keys.has(k) &&
          (v === null ||
            typeof v === "boolean" ||
            (typeof v === "number" && Number.isFinite(v) && v >= 0) ||
            (typeof v === "string" && values.has(v))),
      ),
    );
  for (const line of stderr.trim().split("\n")) {
    try {
      const d = JSON.parse(line).noticeDiagnostics;
      if (d?.version === 1 && Array.isArray(d.pages) && Array.isArray(d.stages))
        return {
          ...clean(d),
          pages: d.pages.slice(0, 128).map(clean),
          stages: d.stages.slice(0, 128).map(clean),
        };
    } catch {}
  }
  return null;
}
const children = new Set();
let peak = 0;
const kill = (c) => {
  try {
    process.kill(-c.pid, "SIGKILL");
  } catch {}
};
const stopAll = () => {
  for (const c of children) kill(c);
};
for (const signal of ["SIGTERM", "SIGINT"])
  process.on(signal, () => {
    stopAll();
    process.exit(1);
  });
async function run(args) {
  const start = performance.now();
  return new Promise((resolve, reject) => {
    const c = spawn(
      "nix",
      ["run", `github:Kyure-A/twins-cli/${revision}`, "--", ...args],
      { detached: true, stdio: ["ignore", "pipe", "pipe"] },
    );
    children.add(c);
    peak = Math.max(peak, children.size);
    c.stdout.setEncoding("utf8");
    c.stderr.setEncoding("utf8");
    let stdout = "",
      stderr = "",
      limit = null;
    const timer = setTimeout(() => {
      limit = "timeout";
      kill(c);
    }, 120000);
    c.stdout.on("data", (d) => {
      stdout += d;
      if (stdout.length > 32 * 1024 * 1024) {
        limit = "stdout_limit";
        kill(c);
      }
    });
    c.stderr.on("data", (d) => {
      stderr += d;
      if (stderr.length > 2 * 1024 * 1024) {
        limit = "stderr_limit";
        kill(c);
      }
    });
    c.on("error", () => {
      clearTimeout(timer);
      children.delete(c);
      reject(Error("spawn_error"));
    });
    c.on("close", (code) => {
      clearTimeout(timer);
      children.delete(c);
      if (code !== 0 || limit !== null) {
        const known = new Set([
          "authentication_required",
          "invalid_argument",
          "http_error",
          "protocol_error",
          "timeout",
          "cancelled",
          "io_error",
          "unexpected_error",
        ]);
        let safeCode = null;
        let httpStatus;
        try {
          const last = JSON.parse(stderr.trim().split("\n").at(-1));
          if (known.has(last?.error?.code)) safeCode = last.error.code;
        } catch {}
        // Older text errors can contain URLs or server data. Match only known
        // local messages and retain the category, never the original string.
        if (safeCode === null) {
          const http = stderr.match(/TWINS returned HTTP ([1-5][0-9]{2}) for /);
          if (http) {
            safeCode = "http_error";
            httpStatus = Number(http[1]);
          } else {
            const categories = [
              [
                "TWINS notice result table was not found",
                "missing_notice_table",
              ],
              ["TWINS page does not contain form", "missing_form"],
              [
                "TWINS did not return a Web Flow execution key",
                "missing_flow_key",
              ],
              [
                "TWINS session is missing or expired",
                "authentication_required",
              ],
              ["TWINS HTTP request timed out", "timeout"],
              ["End_of_file", "transport_eof"],
              ["ECONNRESET", "connection_reset"],
              ["Broken pipe", "broken_pipe"],
            ];
            safeCode =
              categories.find(([message]) => stderr.includes(message))?.[1] ??
              null;
          }
        }
        reject(
          Object.assign(Error("command_failed"), {
            safe: {
              exitCode: code,
              reason: limit ?? safeCode ?? "unclassified_command_failure",
              elapsedMs: performance.now() - start,
              ...(httpStatus === undefined ? {} : { httpStatus }),
              ...(diagnose ? { diagnostics: noticeDiagnostics(stderr) } : {}),
            },
          }),
        );
        return;
      }
      resolve({ stdout, stderr, ms: performance.now() - start });
    });
  });
}
const allOperations = [
  { name: "grades", args: ["grades", "--json"] },
  { name: "timetable", args: ["timetable", "--all", "--json", "--profile"] },
  {
    name: "classes",
    args: [
      "notices",
      "--kind",
      "classes",
      "--all",
      "--max-pages",
      "20",
      "--metadata",
      "--json",
    ],
  },
  {
    name: "general",
    args: [
      "notices",
      "--kind",
      "general",
      "--all",
      "--max-pages",
      "20",
      "--metadata",
      "--json",
    ],
  },
];
const operations =
  scenario === "notices-pair"
    ? allOperations.slice(2)
    : scenario === "general-and-timetable"
      ? [allOperations[1], allOperations[3]]
      : scenario === "general-and-grades"
        ? [allOperations[0], allOperations[3]]
        : scenario === "general-pair"
          ? [
              allOperations[3],
              { ...allOperations[3], name: "general_duplicate" },
            ]
          : allOperations;
const expectedModules = [
  "spring-a",
  "spring-b",
  "spring-c",
  "summer",
  "autumn-a",
  "autumn-b",
  "autumn-c",
  "spring-break",
].sort();
const document = {
  measuredAt: new Date().toISOString(),
  revision,
  scenario,
  method:
    "Canonical warmed GitHub flake. Scenario selects the operations and concurrent grouping; peakCliProcesses records actual process overlap. Every worker uses --no-persist-session; no cookie files copied or inspected, no returned account data persisted. Full parsed JSON equality in memory. Diagnostic failure batch time includes peer completion; failed-operation elapsedMs is separate.",
  authBefore: false,
  authAfter: false,
  batches: [],
  success: false,
};
let reference;
async function batch(mode, round) {
  peak = 0;
  const started = performance.now();
  const results = {};
  const timings = {};
  const diagnostics = {};
  const failures = [];
  let firstFailure;
  const failureSummary = () => ({
    round,
    mode,
    externalMs: performance.now() - started,
    peakCliProcesses: peak,
    operationsMs: timings,
    complete: false,
    failure: firstFailure.safe,
    failures,
    diagnostics,
    matchesReference: Object.fromEntries(
      Object.keys(results).map((name) => [
        name,
        reference ? isDeepStrictEqual(reference[name], results[name]) : null,
      ]),
    ),
  });
  async function operation(spec) {
    try {
      const r = await run([
        ...spec.args,
        "--no-persist-session",
        ...(diagnose && spec.args[0] === "notices" ? ["--diagnose"] : []),
      ]);
      if (diagnose && spec.args[0] === "notices")
        diagnostics[spec.name] = noticeDiagnostics(r.stderr);
      if (
        diagnose &&
        spec.args[0] === "notices" &&
        diagnostics[spec.name] === null
      )
        throw Error("missing_notice_diagnostics");
      const data = JSON.parse(r.stdout);
      if (spec.name === "timetable") {
        if (
          !data.snapshots ||
          !isDeepStrictEqual(
            Object.keys(data.snapshots).sort(),
            expectedModules,
          ) ||
          Object.values(data.snapshots).some((x) => !Array.isArray(x))
        )
          throw Error("incomplete_timetable");
      } else if (spec.name === "grades") {
        if (!Array.isArray(data)) throw Error("invalid_grades");
      } else if (data.completeness !== "complete" || !Array.isArray(data.items))
        throw Error("incomplete_notices");
      results[spec.name] = data;
      timings[spec.name] = r.ms;
    } catch (e) {
      const failure = Object.assign(Error("operation_failed"), {
        safe: {
          operation: spec.name,
          ...(e.safe ?? {
            reason: [
              "incomplete_timetable",
              "invalid_grades",
              "incomplete_notices",
              "missing_notice_diagnostics",
            ].includes(e.message)
              ? e.message
              : "invalid_or_failed_output",
          }),
        },
      });
      firstFailure ??= failure;
      failures.push(failure.safe);
      if (!diagnose) stopAll();
      throw failure;
    }
  }
  try {
    if (mode === "serial") {
      for (const spec of operations) await operation(spec);
    } else {
      const tasks =
        scenario === "notices-serial"
          ? [
              operation(allOperations[0]),
              operation(allOperations[1]),
              (async () => {
                await operation(allOperations[3]);
                await operation(allOperations[2]);
              })(),
            ]
          : operations.map(operation);
      const settled = await Promise.allSettled(tasks);
      const failed = settled.filter((x) => x.status === "rejected");
      if (failed.length) throw firstFailure;
    }
  } catch (error) {
    const summary = failureSummary();
    document.batches.push(summary);
    console.log(JSON.stringify(summary));
    throw error;
  }
  reference ??= results;
  const equality = Object.fromEntries(
    operations.map((o) => [
      o.name,
      isDeepStrictEqual(reference[o.name], results[o.name]),
    ]),
  );
  const summary = {
    round,
    mode,
    externalMs: performance.now() - started,
    peakCliProcesses: peak,
    operationsMs: timings,
    matchesReference: equality,
    ...(diagnose ? { diagnostics } : {}),
  };
  document.batches.push(summary);
  console.log(JSON.stringify(summary));
  if (Object.values(equality).some((x) => !x))
    throw Object.assign(Error("result_mismatch"), {
      safe: {
        reason: "complete_output_mismatch",
        operations: Object.keys(equality).filter((k) => !equality[k]),
      },
    });
}
try {
  await run(["timetable", "--help=plain"]);
  document.authBefore =
    (await run(["auth", "status"])).stdout.trim() === "logged in";
  if (!document.authBefore)
    throw Object.assign(Error("authentication_unavailable"), {
      safe: { reason: "authentication_unavailable" },
    });
  for (let round = 1; round <= rounds; round++)
    for (const mode of round % 2 === 1
      ? ["serial", "parallel4"]
      : ["parallel4", "serial"])
      await batch(mode, round);
  document.success = true;
} catch (e) {
  document.failure = e.safe ?? { reason: "probe_failed" };
  console.log(JSON.stringify({ failure: document.failure }));
  process.exitCode = 1;
} finally {
  stopAll();
  try {
    document.authAfter =
      (await run(["auth", "status"])).stdout.trim() === "logged in";
  } catch {
    document.authAfter = false;
  }
  if (!document.authAfter) {
    document.success = false;
    process.exitCode = 1;
  }
  console.log(
    JSON.stringify({
      success: document.success,
      authBefore: document.authBefore,
      authAfter: document.authAfter,
    }),
  );
  await writeFile(output, JSON.stringify(document, null, 2) + "\n");
}
