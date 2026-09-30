import { spawn } from "node:child_process";
import { writeFile } from "node:fs/promises";
import { isDeepStrictEqual } from "node:util";
const revision = process.argv[2],
  output = process.argv[3];
const rounds = Number(process.argv[4] ?? "1");
if (
  !/^[a-f0-9]{40}$/.test(revision ?? "") ||
  !output ||
  ![1, 2, 3].includes(rounds)
)
  throw Error("Expected REVISION OUTPUT [ROUNDS=1..3]");
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
        try {
          const last = JSON.parse(stderr.trim().split("\n").at(-1));
          if (known.has(last?.error?.code)) safeCode = last.error.code;
        } catch {}
        reject(
          Object.assign(Error("command_failed"), {
            safe: {
              exitCode: code,
              reason: limit ?? safeCode ?? "unclassified_command_failure",
            },
          }),
        );
        return;
      }
      resolve({ stdout, stderr, ms: performance.now() - start });
    });
  });
}
const operations = [
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
  method:
    "Canonical warmed GitHub flake; grades, all timetable, all class notices, all general notices. Every worker uses --no-persist-session; no cookie files copied or inspected, no returned account data persisted. Full parsed JSON equality in memory. Alternating serial and four concurrent CLI processes.",
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
  let firstFailure;
  async function operation(spec) {
    try {
      const r = await run([...spec.args, "--no-persist-session"]);
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
            ].includes(e.message)
              ? e.message
              : "invalid_or_failed_output",
          }),
        },
      });
      firstFailure ??= failure;
      stopAll();
      throw failure;
    }
  }
  if (mode === "serial") {
    for (const spec of operations) await operation(spec);
  } else {
    const settled = await Promise.allSettled(operations.map(operation));
    const failed = settled.filter((x) => x.status === "rejected");
    if (failed.length) throw firstFailure;
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
