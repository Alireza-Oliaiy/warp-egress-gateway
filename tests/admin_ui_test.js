"use strict";

// Execute the shipped browser script, not a duplicate polling implementation.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const ROOT = path.resolve(__dirname, "..");
const APP = fs.readFileSync(path.join(ROOT, "admin/static/admin.js"), "utf8");
const INDEX = fs.readFileSync(path.join(ROOT, "admin/static/index.html"), "utf8");
const INTERVAL = 15000;
const IDS = ["run-health", "overall-state", "version", "warp", "wireguard", "routing",
  "kill-switch", "forwarding", "monitoring", "last-refresh", "result-message", "repair-routing", "repair-message"];

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

async function flush() {
  await new Promise((resolve) => setImmediate(resolve));
}

class Clock {
  constructor() { this.now = 0; this.sequence = 0; this.timers = new Map(); }

  schedule(callback, delay, interval = false) {
    assert.ok(Number.isFinite(delay) && delay >= 0);
    const id = ++this.sequence;
    this.timers.set(id, { callback, due: this.now + delay, delay, interval });
    return id;
  }

  async advance(milliseconds) {
    const end = this.now + milliseconds;
    let dispatched = 0;
    for (;;) {
      const next = [...this.timers].filter(([, timer]) => timer.due <= end)
        .sort((a, b) => a[1].due - b[1].due || a[0] - b[0])[0];
      if (!next) break;
      assert.ok(++dispatched < 1000, "polling must not create a tight timer loop");
      const [id, timer] = next;
      this.now = timer.due;
      if (timer.interval) timer.due += timer.delay;
      else this.timers.delete(id);
      timer.callback(); // Native timers do not await an async callback.
      await flush();
    }
    this.now = end;
    await flush();
  }
}

function result(state = "ok") {
  return { protocol: 1, operation: "status", ok: true, changed: false, state,
    evidence: { version: "0.5.1", warp: "on", wireguard: "up", routing: "ok",
      kill_switch: "ok", forwarding: "unknown", monitoring: "ok" } };
}

function page() {
  const clock = new Clock();
  const calls = [];
  const confirmations = [];
  let approved = true;
  const elements = Object.fromEntries(IDS.map((id) => [id, {
    textContent: "", className: "", disabled: false, handlers: {},
    addEventListener(event, callback) { this.handlers[event] = callback; },
  }]));
  const document = {
    body: { dataset: {} },
    querySelector(selector) {
      assert.equal(selector, 'meta[name="csrf-token"]');
      return { getAttribute: (name) => { assert.equal(name, "content"); return "synthetic-csrf"; } };
    },
    getElementById(id) { return elements[id] || null; },
  };
  class TestDate { toLocaleTimeString() { return "12:34:56"; } }
  vm.runInNewContext(APP, {
    document, Date: TestDate,
    window: {
      confirm(message) { confirmations.push(message); return approved; },
      setInterval: (callback, delay) => clock.schedule(callback, delay, true),
      setTimeout: (callback, delay) => clock.schedule(callback, delay),
    },
    fetch(url, options) {
      assert.ok(["/api/status", "/api/actions/health", "/api/actions/repair-routing"].includes(url), "only the fixed repair action may mutate");
      const response = deferred();
      const body = deferred();
      const call = { url, options, started: clock.now, response, body,
        headers(ok = true) { response.resolve({ ok, json: () => body.promise }); },
        complete(value = result(), ok = true) { this.headers(ok); body.resolve(value); },
      };
      calls.push(call);
      return response.promise;
    },
  }, { filename: "admin.js" });
  return { clock, calls, elements, document,
    status: () => calls.filter((call) => call.url === "/api/status"),
    health: () => calls.filter((call) => call.url === "/api/actions/health"),
    clickHealth: () => elements["run-health"].handlers.click(),
    repair: () => calls.filter((call) => call.url === "/api/actions/repair-routing"),
    clickRepair: () => elements["repair-routing"].handlers.click(),
    decline: () => { approved = false; }, confirmations,
  };
}

async function testSlowStatusNeverOverlaps() {
  const ui = page();
  assert.equal(ui.status().length, 1, "initial Status must start automatically");
  await ui.clock.advance(4 * INTERVAL + 800);
  assert.equal(ui.status().length, 1, "a pending Status must not overlap any later periodic tick");
  ui.status()[0].headers();
  await ui.clock.advance(2 * INTERVAL);
  assert.equal(ui.status().length, 1, "response headers alone do not finish Status JSON processing");
  ui.status()[0].body.resolve(result());
  await flush();
  const completed = ui.clock.now;
  await ui.clock.advance(INTERVAL - 1);
  assert.equal(ui.status().length, 1);
  await ui.clock.advance(1);
  assert.equal(ui.status().length, 2, "polling resumes after completion plus the normal delay");
  assert.equal(ui.status()[1].started, completed + INTERVAL);
  await ui.clock.advance(3 * INTERVAL);
  assert.equal(ui.status().length, 2, "a later slow Status is serialized too");
}

async function testNormalCadenceAndRendering() {
  const ui = page();
  assert.equal(ui.status()[0].started, 0);
  assert.equal(ui.status()[0].options.cache, "no-store");
  assert.equal(ui.status()[0].options.credentials, "same-origin");
  assert.equal(ui.status()[0].options.headers.Accept, "application/json");
  for (const [index, state] of ["ok", "degraded", "failed", "intentionally_disconnected"].entries()) {
    assert.equal(ui.status().length, index + 1);
    ui.status()[index].complete(result(state));
    await flush();
    assert.equal(ui.document.body.dataset.state, state);
    assert.equal(ui.elements["overall-state"].textContent, state.toUpperCase());
    assert.equal(ui.elements["overall-state"].className,
      `badge ${state === "ok" ? "good" : state === "degraded" ? "warn" : state === "failed" ? "bad" : "neutral"}`);
    for (const [id, text, tone] of [["warp", "ON", "good"], ["wireguard", "UP", "good"],
      ["routing", "OK", "good"], ["kill-switch", "OK", "good"],
      ["forwarding", "UNKNOWN", "neutral"], ["monitoring", "OK", "good"]]) {
      assert.equal(ui.elements[id].textContent, text);
      assert.equal(ui.elements[id].className, `badge ${tone}`);
    }
    assert.equal(ui.elements.version.textContent, "0.5.1");
    assert.equal(ui.elements["last-refresh"].textContent, "12:34:56");
    assert.equal(ui.elements["result-message"].textContent,
      state === "ok" ? "Gateway evidence is healthy." : "Gateway evidence requires attention.");
    await ui.clock.advance(INTERVAL - 1);
    assert.equal(ui.status().length, index + 1);
    await ui.clock.advance(1);
  }
}

async function testErrorsWaitAndNeverMultiply() {
  for (const failure of ["fetch", "http", "json"]) {
    const ui = page();
    for (let attempt = 0; attempt < 3; attempt++) {
      const call = ui.status()[attempt];
      if (failure === "fetch") call.response.reject(new Error("synthetic network failure"));
      if (failure === "http") call.complete({ error: "observation_unavailable" }, false);
      if (failure === "json") { call.headers(); call.body.reject(new Error("invalid JSON")); }
      await flush();
      assert.equal(ui.document.body.dataset.state, "failed");
      assert.equal(ui.elements["result-message"].textContent, "Current Admin status is unavailable.");
      await ui.clock.advance(INTERVAL - 1);
      assert.equal(ui.status().length, attempt + 1, "errors must retain the full retry delay");
      await ui.clock.advance(1);
      assert.equal(ui.status().length, attempt + 2);
    }
    await ui.clock.advance(4 * INTERVAL);
    assert.equal(ui.status().length, 4, "pending retry must not multiply");
  }
}

async function testRunHealthStaysIndependent() {
  const ui = page();
  const running = ui.clickHealth();
  assert.equal(ui.health().length, 1, "Run Health is allowed while Status is pending");
  const button = ui.elements["run-health"];
  assert.equal(button.disabled, true);
  assert.equal(button.textContent, "Running…");
  await ui.clickHealth();
  assert.equal(ui.health().length, 1, "double clicks are still ignored");
  const health = ui.health()[0];
  assert.equal(health.options.method, "POST");
  assert.equal(health.options.headers["X-CSRF-Token"], "synthetic-csrf");
  assert.equal(health.options.headers["Content-Type"], "application/json");
  assert.equal(health.options.credentials, "same-origin");
  assert.equal(health.options.cache, "no-store");
  assert.equal(health.options.body, "{}");
  await ui.clock.advance(2 * INTERVAL);
  assert.equal(ui.status().length, 1);
  health.complete({ ...result(), operation: "health" });
  await running;
  assert.equal(button.disabled, false);
  assert.equal(button.textContent, "Run Health");
  assert.equal(ui.elements["result-message"].textContent, "Health evaluation completed: healthy.");
  await ui.clock.advance(INTERVAL);
  assert.equal(ui.status().length, 1, "Run Health completion must not create a Status timer");
  ui.status()[0].complete();
  await flush();
  const failed = ui.clickHealth();
  ui.health()[1].response.reject(new Error("synthetic health failure"));
  await failed;
  assert.equal(button.disabled, false);
  assert.equal(button.textContent, "Run Health");
  assert.equal(ui.elements["result-message"].textContent, "Health evaluation failed to complete.");
  await ui.clock.advance(INTERVAL);
  assert.equal(ui.status().length, 2, "independent Health failure must not stop Status polling");
  const pending = ui.clickHealth();
  ui.status()[1].complete();
  await flush();
  await ui.clock.advance(INTERVAL);
  assert.equal(ui.status().length, 3, "Status may continue while independent Run Health is pending");
  ui.health()[2].complete({ ...result("failed"), operation: "health" });
  await pending;
  assert.equal(ui.elements["result-message"].textContent, "Health evaluation completed: unhealthy.");
}

async function testRepairConfirmationAndDoubleSubmit() {
  const declined = page();
  declined.decline();
  await declined.clickRepair();
  assert.equal(declined.repair().length, 0, "declining never POSTs");
  assert.equal(declined.confirmations.length, 1);
  const ui = page();
  const pending = ui.clickRepair();
  assert.equal(ui.repair().length, 1);
  assert.equal(ui.elements["repair-routing"].disabled, true);
  assert.match(ui.elements["repair-message"].textContent, /Running/);
  await ui.clickRepair();
  assert.equal(ui.repair().length, 1);
  assert.equal(ui.confirmations.length, 1);
  const call = ui.repair()[0];
  assert.equal(call.options.method, "POST");
  assert.equal(call.options.body, '{"confirmation":"repair-routing"}');
  assert.equal(call.options.headers["X-CSRF-Token"], "synthetic-csrf");
  assert.equal(call.options.headers["Content-Type"], "application/json");
  assert.equal(call.options.credentials, "same-origin");
  assert.equal(call.options.cache, "no-store");
  ui.status()[0].complete();
  await flush();
  await ui.clock.advance(INTERVAL);
  assert.equal(ui.status().length, 2, "Status polling remains independent and serialized");
  assert.match(ui.elements["repair-message"].textContent, /Running/, "polling cannot overwrite action state");
  call.complete({ ...result("degraded"), operation: "repair-routing", changed: true });
  await pending;
  assert.match(ui.elements["repair-message"].textContent, /restored.*verified/i);
  assert.equal(ui.elements["repair-routing"].disabled, false);
  await ui.clock.advance(INTERVAL);
  assert.equal(ui.status().length, 2, "repair completion must not create another Status poll");
}

async function testRepairResultsAndFailures() {
  for (const [code, pattern] of [[null, /already healthy.*no change/i],
    ["mutation_lock_busy", /lock.*busy/i], ["unsafe_precondition", /unsafe.*no changes/i],
    ["operation_timeout", /timed out.*partial/i], ["partial_mutation_failure", /failed.*partial/i],
    ["postcondition_failed", /verification failed/i], ["helper_unavailable", /unavailable/i],
    ["seed-private-canary", /failed/i], ["fetch", /failed/i]]) {
    const ui = page();
    const pending = ui.clickRepair();
    if (code === "fetch") ui.repair()[0].response.reject(new Error("seed-private-canary"));
    else ui.repair()[0].complete(code ? { result_code: code } : { ...result(), operation: "repair-routing" }, !code);
    await pending;
    assert.match(ui.elements["repair-message"].textContent, pattern);
    assert.doesNotMatch(ui.elements["repair-message"].textContent, /seed-private-canary/);
    assert.equal(ui.elements["repair-routing"].disabled, false);
  }
  assert.ok(INDEX.includes('id="repair-message" role="status" aria-live="polite"'));
  assert.ok(!INDEX.includes('id="connect"') && !INDEX.includes('id="disconnect"'));
}

async function main() {
  for (const id of IDS) assert.ok(INDEX.includes(`id="${id}"`), `real UI must contain ${id}`);
  for (const test of [testSlowStatusNeverOverlaps, testNormalCadenceAndRendering,
    testErrorsWaitAndNeverMultiply, testRunHealthStaysIndependent,
    testRepairConfirmationAndDoubleSubmit, testRepairResultsAndFailures]) {
    await test();
    console.log(`PASS ${test.name}`);
  }
  console.log("Admin UI polling serialization and rendering tests passed.");
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
