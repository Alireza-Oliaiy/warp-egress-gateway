"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const ROOT = path.resolve(__dirname, "..");
const APP = fs.readFileSync(path.join(ROOT, "web", "dashboard", "static", "app.js"), "utf8");
const INDEX = fs.readFileSync(path.join(ROOT, "web", "dashboard", "static", "index.html"), "utf8");
const FIXTURE_DIRECTORY = path.join(ROOT, "web", "dashboard", "fixtures");
const ELEMENT_IDS = [
  "ui-message",
  "overall-state",
  "hostname",
  "version",
  "uptime",
  "last-updated",
  "warp-tunnel",
  "warp-interface",
  "handshake",
  "public-ip",
  "colo",
  "location",
  "direct-path",
  "warp-path",
  "rule-100",
  "rule-110",
  "table-100",
  "main-default",
  "kill-switch",
  "ipv4-forwarding",
  "health",
  "monitor",
  "health-timer",
  "monitor-timer",
  "failed-units",
];

class ClassList {
  constructor(initial = []) {
    this.values = new Set(initial);
  }

  add(...names) {
    names.forEach((name) => this.values.add(name));
  }

  remove(...names) {
    names.forEach((name) => this.values.delete(name));
  }

  contains(name) {
    return this.values.has(name);
  }
}

function fixture(name, generatedAt) {
  const status = JSON.parse(fs.readFileSync(path.join(FIXTURE_DIRECTORY, `${name}.json`), "utf8"));
  status.generated_at = generatedAt;
  return status;
}

function initialClasses(id) {
  const tag = INDEX.match(new RegExp(`<[^>]+id=["']${id}["'][^>]*>`));
  if (!tag) return [];
  const classAttribute = tag[0].match(/class=["']([^"']*)["']/);
  return classAttribute ? classAttribute[1].split(/\s+/).filter(Boolean) : [];
}

async function render(status, { requestFails = false } = {}) {
  const elements = Object.fromEntries(
    ELEMENT_IDS.map((id) => [id, { id, textContent: "", hidden: false, classList: new ClassList(initialClasses(id)) }]),
  );
  const intervals = [];
  const document = {
    body: { dataset: {} },
    getElementById(id) {
      return elements[id] || null;
    },
  };
  const context = vm.createContext({
    console,
    document,
    fetch: async () => {
      if (requestFails) throw new Error("synthetic request failure");
      return { ok: true, json: async () => structuredClone(status) };
    },
    Intl,
    Date,
    Error,
    Number,
    String,
    setInterval(callback, milliseconds) {
      intervals.push({ callback, milliseconds });
      return intervals.length;
    },
  });

  vm.runInContext(APP, context, { filename: "app.js" });
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
  return { document, elements, intervals };
}

async function main() {
  const freshTimestamp = new Date().toISOString();

  const healthy = await render(fixture("healthy", freshTimestamp));
  assert.equal(healthy.document.body.dataset.uiState, "ready");
  assert.equal(healthy.elements["ui-message"].hidden, true, "fresh ONLINE status must not show a problem banner");
  assert.match(healthy.elements["last-updated"].textContent, /\u00b7 UTC[+-]\d{1,2}(?::\d{2})?$/);
  assert.equal(healthy.elements["warp-interface"].textContent, "UP");
  assert.equal(healthy.elements["warp-interface"].classList.contains("badge"), true);
  assert.equal(healthy.elements["warp-interface"].classList.contains("badge-good"), true);
  assert.equal(healthy.intervals.some(({ milliseconds }) => milliseconds === 5000), true);

  const degraded = await render(fixture("degraded", freshTimestamp));
  assert.equal(degraded.elements["ui-message"].hidden, false);
  assert.equal(degraded.elements["ui-message"].textContent, "DEGRADED \u00b7 One or more observations require attention");
  assert.equal(degraded.elements["ui-message"].classList.contains("system-banner-warn"), true);

  const failed = await render(fixture("failed", freshTimestamp));
  assert.equal(failed.elements["ui-message"].hidden, false);
  assert.equal(failed.elements["ui-message"].textContent, "OFFLINE \u00b7 Gateway status requires attention");
  assert.equal(failed.elements["ui-message"].classList.contains("system-banner-bad"), true);

  const staleTimestamp = new Date(Date.now() - 31000).toISOString();
  const stale = await render(fixture("healthy", staleTimestamp));
  assert.equal(stale.document.body.dataset.uiState, "stale");
  assert.equal(stale.elements["ui-message"].hidden, false);
  assert.equal(stale.elements["ui-message"].textContent, "STALE \u00b7 Telemetry is older than 30 seconds");
  assert.equal(stale.elements["ui-message"].classList.contains("system-banner-warn"), true);

  const unavailable = await render(fixture("healthy", freshTimestamp), { requestFails: true });
  assert.equal(unavailable.document.body.dataset.uiState, "unavailable");
  assert.equal(unavailable.elements["ui-message"].hidden, false);
  assert.equal(unavailable.elements["ui-message"].textContent, "UNKNOWN \u00b7 Current gateway status is unavailable");
  assert.equal(unavailable.elements["ui-message"].classList.contains("system-banner-neutral"), true);

  console.log("Dashboard UI behavior tests passed.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
