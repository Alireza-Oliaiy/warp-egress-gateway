"use strict";

(() => {
  const csrfNode = document.querySelector('meta[name="csrf-token"]');
  const csrfToken = csrfNode ? csrfNode.getAttribute("content") : "";
  const healthButton = document.getElementById("run-health");
  const repairButton = document.getElementById("repair-routing");

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
    } finally {
      // Wait for the complete attempt, including JSON/rendering, before polling again.
      window.setTimeout(refreshStatus, 15000);
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
  async function repairRouting() {
    if (!repairButton || repairButton.disabled) return;
    if (!window.confirm("Repair only missing gateway policy-routing rules/default? WARP and the main default will not be restarted or changed.")) return;
    repairButton.disabled = true;
    repairButton.textContent = "Running…";
    text("repair-message", "Running bounded routing repair and safety verification…");
    try {
      const response = await fetch("/api/actions/repair-routing", {
        method: "POST", cache: "no-store", credentials: "same-origin",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
        body: '{"confirmation":"repair-routing"}',
      });
      const result = await readJson(response);
      text("repair-message", result.changed === true
        ? "Missing routing restored and verified. Status remains an independent read-only observation."
        : "Routing already healthy: no change required.");
    } catch (error) {
      const messages = {
        mutation_lock_busy: "Mutation lock is busy. No changes made; retry explicitly when idle.",
        unsafe_precondition: "Unsafe routing precondition: no changes made. Inspect gateway state.",
        operation_timeout: "Repair timed out. Partial changes may exist; inspect gateway state.",
        partial_mutation_failure: "Repair failed after a write attempt. Partial changes may exist; inspect gateway state.",
        postcondition_failed: "Final safety verification failed. Inspect gateway state; no automatic retry.",
        helper_unavailable: "Repair helper is unavailable.",
        privilege_denied: "Repair helper authorization is unavailable.",
        rate_limited: "Repair rate limit reached. Wait before an explicit retry.",
      };
      text("repair-message", Object.hasOwn(messages, error.message) ? messages[error.message] : "Routing repair failed. Inspect gateway state.");
    } finally {
      repairButton.disabled = false;
      repairButton.textContent = "Repair Routing";
    }
  }
  if (repairButton) repairButton.addEventListener("click", repairRouting);
  refreshStatus();
})();
