"use strict";

(() => {
  const csrfNode = document.querySelector('meta[name="csrf-token"]');
  const csrfToken = csrfNode ? csrfNode.getAttribute("content") : "";
  const healthButton = document.getElementById("run-health");

  function node(id) {
    return document.getElementById(id);
  }

  function text(id, value) {
    const target = node(id);
    if (target) target.textContent = value === null || value === undefined || value === "" ? "UNKNOWN" : String(value);
  }

  function tone(value) {
    if (["ok", "on", "up", "active", "enabled"].includes(value)) return "good";
    if (["degraded", "stale"].includes(value)) return "warn";
    if (["failed", "down", "inactive", "disabled"].includes(value)) return "bad";
    return "neutral";
  }

  function badge(id, value) {
    const target = node(id);
    if (!target) return;
    target.textContent = value ? String(value).toUpperCase() : "UNKNOWN";
    target.className = `badge ${tone(value)}`;
  }

  function render(result) {
    const evidence = result.evidence;
    badge("overall-state", result.state);
    text("version", evidence.version);
    badge("warp", evidence.warp);
    badge("wireguard", evidence.wireguard);
    badge("routing", evidence.routing);
    badge("kill-switch", evidence.kill_switch);
    badge("forwarding", evidence.forwarding);
    badge("monitoring", evidence.monitoring);
    text("last-refresh", new Date().toLocaleTimeString());
    document.body.dataset.state = result.state;
  }

  async function readJson(response) {
    const value = await response.json();
    if (!response.ok) throw new Error(value.error || value.result_code || "request_failed");
    return value;
  }

  async function refreshStatus() {
    try {
      const response = await fetch("/api/status", {
        cache: "no-store",
        credentials: "same-origin",
        headers: { Accept: "application/json" },
      });
      const result = await readJson(response);
      render(result);
      text("result-message", result.state === "ok" ? "Gateway evidence is healthy." : "Gateway evidence requires attention.");
    } catch (_error) {
      badge("overall-state", "failed");
      text("result-message", "Current Admin status is unavailable.");
      document.body.dataset.state = "failed";
    }
  }

  async function runHealth() {
    if (!healthButton || healthButton.disabled) return;
    healthButton.disabled = true;
    healthButton.textContent = "Running…";
    text("result-message", "Running the read-only health evaluator…");
    try {
      const response = await fetch("/api/actions/health", {
        method: "POST",
        cache: "no-store",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": csrfToken,
        },
        body: "{}",
      });
      const result = await readJson(response);
      render(result);
      text("result-message", result.state === "ok" ? "Health evaluation completed: healthy." : "Health evaluation completed: unhealthy.");
    } catch (_error) {
      text("result-message", "Health evaluation failed to complete.");
    } finally {
      healthButton.disabled = false;
      healthButton.textContent = "Run Health";
    }
  }

  if (healthButton) healthButton.addEventListener("click", runHealth);
  refreshStatus();
  window.setInterval(refreshStatus, 15000);
})();
