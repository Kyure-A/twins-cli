import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const benchmark = fileURLToPath(
  new URL("../scripts/benchmark-parallel-reads.mjs", import.meta.url),
);
const modules = [
  "autumn-a", "autumn-b", "autumn-c", "spring-a", "spring-b", "spring-break",
  "spring-c", "summer",
];

// The only executable named nix on this test's PATH is this synthetic fixture.
// Its payloads are invented; no account, session file, or network is involved.
const fakeNix = `#!${process.execPath}
const fs = require('node:fs');
const path = require('node:path');
const root = process.env.FAKE_NIX_ROOT;
const scenario = process.env.FAKE_NIX_SCENARIO;
const args = process.argv.slice(process.argv.indexOf('--') + 1);
const modules = ${JSON.stringify(modules)};
const log = (event) => fs.appendFileSync(path.join(root, 'events.jsonl'), JSON.stringify({pid:process.pid,...event})+'\\n');
const sleep = ms => new Promise(resolve => setTimeout(resolve,ms));
const events = () => fs.readFileSync(path.join(root,'events.jsonl'),'utf8').trim().split('\\n').filter(Boolean).map(JSON.parse);
const waitFor = async predicate => {
  for(let i=0;i<500;i++) { if(predicate()) return; await sleep(10); }
  throw Error('fixture handshake timed out');
};
(async () => {
  if(args.includes('--help=plain')) { log({event:'help'}); return; }
  if(args[0]==='auth') { log({event:'auth'}); console.log('logged in'); return; }
  if(!args.includes('--no-persist-session')) throw Error('missing no-persist flag');
  const module = args.includes('--module') ? args[args.indexOf('--module')+1] : null;
  const operation = module ? 'timetable_'+module : args[0]==='notices' ? args[args.indexOf('--kind')+1] : args[0];
  const counter = path.join(root,operation+'.count');
  const ordinal = fs.existsSync(counter) ? Number(fs.readFileSync(counter,'utf8'))+1 : 1;
  fs.writeFileSync(counter,String(ordinal));
  const phase = module || ordinal===3 ? 'parallel8' : ordinal===2 ? 'parallel4' : 'serial';
  log({event:'start',operation,phase,module});
  if(scenario==='worker-failure' && phase==='parallel8') {
    await waitFor(() => events().filter(e=>e.event==='start' && e.phase==='parallel8').length===8);
    if(module==='autumn-a') {
      log({event:'failed',operation,phase});
      console.error(JSON.stringify({error:{code:'protocol_error',message:'PRIVATE_SYNTHETIC_ERROR'}}));
      process.exitCode=1;
      return;
    }
    await waitFor(() => events().some(e=>e.event==='failed'));
    // Keep peers running until the runner has observed the failed worker.
    await sleep(250);
  } else await sleep(30);
  const rows = name => [{syntheticModule:name, syntheticValue:7}];
  let data;
  if(args[0]==='timetable') {
    data=module ? rows(module) : {snapshots:Object.fromEntries(modules.map(name=>[name,rows(name)]))};
    if(scenario==='module-mismatch' && module==='autumn-a') data[0].syntheticValue=8;
    console.error(JSON.stringify({profile:{version:1,outcome:'success',wallMs:1,cpuMs:0,transport:'reuse',connectionsCreated:1,privateField:'PRIVATE_SYNTHETIC_PROFILE',stages:[{stage:'module_fetch',module:module??'spring-a',wallMs:1}],http:[{index:1,status:200,bytes:1,wireBytes:1,headersMs:1,bodyMs:0,uri:'PRIVATE_SYNTHETIC_URI'}]}}));
  } else if(args[0]==='grades') data=[{syntheticGrade:'fixture'}];
  else data={items:[{syntheticNotice:operation}],completeness:'complete',pages_fetched:1,reason:null};
  console.log(JSON.stringify(data));
  log({event:'end',operation,phase});
})().catch(() => { console.error(JSON.stringify({error:{code:'unexpected_error'}})); process.exitCode=1; });
`;

async function probe(scenario) {
  const directory = await mkdtemp(path.join(tmpdir(), "twins-benchmark-test-"));
  const executable = path.join(directory, "nix");
  const output = path.join(directory, "report.json");
  let child;
  let timer;
  try {
    await writeFile(executable, fakeNix);
    await chmod(executable, 0o700);
    child = spawn(process.execPath, [benchmark, "a".repeat(40), output, "1", "eight-way"], {
      env: {
        ...process.env,
        PATH: directory,
        FAKE_NIX_ROOT: directory,
        FAKE_NIX_SCENARIO: scenario,
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stderr = "";
    let stdout = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", data => { stdout += data; });
    child.stderr.on("data", data => { stderr += data; });
    let timedOut = false;
    timer = setTimeout(() => { timedOut = true; child.kill("SIGTERM"); }, 15000);
    const code = await new Promise((resolve, reject) => {
      child.on("error", reject);
      child.on("close", (code, signal) => resolve(signal ?? code));
    });
    assert.equal(timedOut, false, "synthetic benchmark must finish within its test bound");
    assert.equal(stderr, "", "runner should not expose unexpected diagnostics");
    const rendered = await readFile(output, "utf8");
    assert.equal(/PRIVATE_SYNTHETIC/.test(rendered + stdout), false, "saved metrics and console output omit unallowlisted fields");
    const report = JSON.parse(rendered);
    const events = (await readFile(path.join(directory, "events.jsonl"), "utf8"))
      .trim().split("\n").map(JSON.parse);
    return { code, report, events };
  } finally {
    clearTimeout(timer);
    if (child && child.exitCode === null && child.signalCode === null) child.kill("SIGTERM");
    // On assertion/timeout paths, also retire any detached synthetic workers.
    try {
      const events = (await readFile(path.join(directory, "events.jsonl"), "utf8"))
        .trim().split("\n").filter(Boolean).map(JSON.parse);
      const active = new Set();
      for (const event of events) {
        if (event.event === "start") active.add(event.pid);
        if (event.event === "end" || event.event === "failed") active.delete(event.pid);
      }
      for (const pid of active) {
        try { process.kill(pid, "SIGKILL"); } catch {}
      }
    } catch {}
    await rm(directory, { recursive: true, force: true });
  }
}

test("eight-way compares all 11 jobs against the complete serial control within the worker bound", async () => {
  const { code, report, events } = await probe("success");
  assert.equal(code, 0);
  assert.equal(report.success, true);
  assert.equal(report.authBefore, true);
  assert.equal(report.authAfter, true);
  assert.deepEqual(report.batches.map(batch => batch.mode), ["serial", "parallel4", "parallel8"]);
  const batch = report.batches.at(-1);
  assert.equal(batch.callsStarted, 11);
  assert.equal(batch.peakCliProcesses, 8);
  assert.deepEqual(batch.moduleMatches, Object.fromEntries(modules.map(name => [name, true])));
  assert.deepEqual(batch.matchesReference, { grades: true, timetable: true, classes: true, general: true });
  assert.equal(Object.keys(batch.profiles).length, 8);
  assert.equal(Object.keys(batch.operationsMs).length, 11);
  assert.ok(batch.timetableSpanMs >= 0);
  let active = 0;
  for (const event of events.filter(event => event.phase === "parallel8")) {
    if (event.event === "start") active++;
    if (event.event === "end") active--;
    assert.ok(active >= 0 && active <= 8, "synthetic workers must respect the eight-process bound");
  }
  assert.equal(active, 0);
  assert.equal(events.filter(event => event.event === "auth").length, 2);
});

test("a module result mismatch fails the run and still checks final authentication", async () => {
  const { code, report, events } = await probe("module-mismatch");
  assert.equal(code, 1);
  assert.equal(report.success, false);
  assert.equal(report.authAfter, true);
  assert.equal(report.failure.reason, "timetable_module_mismatch");
  assert.equal(report.batches.at(-1).moduleMatches["autumn-a"], false);
  assert.equal(events.at(-1).event, "auth");
});

test("a failed worker stops queued starts after failure and drains peers before final authentication", async () => {
  const { code, report, events } = await probe("worker-failure");
  assert.equal(code, 1);
  assert.equal(report.success, false);
  assert.equal(report.failure.reason, "protocol_error");
  assert.equal(report.authAfter, true);
  const batch = report.batches.at(-1);
  assert.equal(batch.callsStarted, 8, "the three queued jobs must not begin after failure");
  assert.equal(batch.peakCliProcesses, 8);
  const starts = events.filter(event => event.phase === "parallel8" && event.event === "start");
  assert.equal(starts.length, 8);
  assert.deepEqual(starts.filter(event => event.module).map(event => event.module).sort(), modules.slice(0, 5));
  const failedIndex = events.findIndex(event => event.event === "failed");
  assert.ok(failedIndex >= 0);
  assert.equal(events.slice(failedIndex + 1).some(event => event.event === "start"), false);
  assert.equal(events.at(-1).event, "auth");
  assert.equal(events.filter(event => event.phase === "parallel8" && event.event === "end").length, 7);
});
