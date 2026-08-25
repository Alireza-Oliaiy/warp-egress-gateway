"use strict";

(() => {
  const POLL_INTERVAL_MS = 5000;
  const STALE_AFTER_MS = 30000;
  let generatedAtMs = null;
  let requestFailed = false;

  const badgeClasses = ["badge-good", "badge-warn", "badge-bad", "badge-neutral"];
  const bannerClasses = ["system-banner-warn", "system-banner-bad", "system-banner-neutral"];
  const stateTone = {
    online: "good",
    connected: "good",
    up: "good",
    ok: "good",
    active: "good",
    degraded: "warn",
    warn: "warn",
    offline: "bad",
    disconnected: "bad",
    down: "bad",
    error: "bad",
    failed: "bad",
    inactive: "bad",
    stale: "warn",
    unknown: "neutral",
  };

  function node(id) {
    return document.getElementById(id);
  }

  function display(value, fallback = "UNKNOWN") {
    if (value === null || value === undefined || value === "") return fallback;
    return String(value);
  }

  function text(id, value, fallback = "UNKNOWN") {
    const target = node(id);
    if (target) target.textContent = display(value, fallback);
  }

  function badge(id, label, state) {
    const target = node(id);
    if (!target) return;
    target.textContent = display(label).toUpperCase();
    target.classList.remove(...badgeClasses);
    target.classList.add(`badge-${stateTone[state] || "neutral"}`);
  }

  function formatUptime(seconds) {
    if (!Number.isInteger(seconds) || seconds < 0) return "UNKNOWN";
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    if (days > 0) return `${days}d ${hours}h`;
    if (hours > 0) return `${hours}h ${minutes}m`;
    return `${minutes}m`;
  }

  function formatHandshake(seconds) {
    if (!Number.isInteger(seconds) || seconds < 0) return "UNKNOWN";
    if (seconds < 60) return `${seconds}s ago`;
    const minutes = Math.floor(seconds / 60);
    return `${minutes}m ${seconds % 60}s ago`;
  }

  function pathLabel(path) {
    return `${display(path.state)} · WARP ${display(path.warp)}`;
  }

  function showBanner(messageText, tone = "neutral") {
    const message = node("ui-message");
    if (!message) return;
    message.hidden = false;
    message.textContent = messageText;
    message.classList.remove(...bannerClasses);
    message.classList.add(`system-banner-${tone}`);
  }

  function renderSummary() {
    const uiState = document.body.dataset.uiState;
    const overall = document.body.dataset.overall || "unknown";
    const message = node("ui-message");
    if (!message) return;

    if (uiState === "loading") {
      showBanner("Loading the latest gateway snapshot…");
      return;
    }
    if (uiState === "unavailable") {
      showBanner("UNKNOWN · Current gateway status is unavailable", "neutral");
      return;
    }
    if (uiState === "stale") {
      showBanner("STALE · Telemetry is older than 30 seconds", "warn");
      return;
    }
    if (overall === "online") {
      message.hidden = true;
      message.textContent = "";
      message.classList.remove(...bannerClasses);
      return;
    }
    if (overall === "degraded") {
      showBanner("DEGRADED · One or more observations require attention", "warn");
      return;
    }
    if (overall === "offline") {
      showBanner("OFFLINE · Gateway status requires attention", "bad");
      return;
    }
    showBanner("UNKNOWN · Current gateway status is unavailable", "neutral");
  }

  function setUiState(state) {
    document.body.dataset.uiState = state;
    renderSummary();
  }

  function formatUtcOffset(date) {
    const totalMinutes = -date.getTimezoneOffset();
    const sign = totalMinutes >= 0 ? "+" : "-";
    const absoluteMinutes = Math.abs(totalMinutes);
    const hours = Math.floor(absoluteMinutes / 60);
    const minutes = absoluteMinutes % 60;
    return `UTC${sign}${hours}${minutes === 0 ? "" : `:${String(minutes).padStart(2, "0")}`}`;
  }

  function formatLastUpdated(timestampMs) {
    if (!Number.isFinite(timestampMs)) return "UNKNOWN";
    const updatedAt = new Date(timestampMs);
    const localTime = updatedAt.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
    return `${localTime} · ${formatUtcOffset(updatedAt)}`;
  }

  function renderStatus(status) {
    const overall = status.overall.state;
    document.body.dataset.overall = overall;
    badge("overall-state", overall === "online" ? "ONLINE" : overall === "offline" ? "ERROR" : overall, overall);
    text("hostname", status.system.hostname);
    text("version", status.system.version);
    text("uptime", formatUptime(status.system.uptime_seconds));

    badge("warp-tunnel", status.warp.state === "disconnected" ? "ERROR" : status.warp.state, status.warp.state);
    badge("warp-interface", status.warp.interface, status.warp.interface);
    text("handshake", formatHandshake(status.warp.handshake_age_seconds));
    text("public-ip", status.warp.public_ip);
    text("colo", status.warp.colo);
    text("location", status.warp.location);

    badge("direct-path", pathLabel(status.paths.direct), status.paths.direct.state);
    badge("warp-path", pathLabel(status.paths.warp), status.paths.warp.state);
    badge("rule-100", status.routing.rule_100, status.routing.rule_100);
    badge("rule-110", status.routing.rule_110, status.routing.rule_110);
    badge("table-100", status.routing.table_100, status.routing.table_100);
    badge("main-default", status.routing.main_default, status.routing.main_default);
    badge("kill-switch", status.safety.kill_switch, status.safety.kill_switch);
    const forwarding = status.safety.ipv4_forwarding;
    badge("ipv4-forwarding", forwarding === true ? "ACTIVE" : forwarding === false ? "ERROR" : "UNKNOWN", forwarding === true ? "active" : forwarding === false ? "failed" : "unknown");

    badge("health", status.monitoring.health, status.monitoring.health);
    badge("monitor", status.monitoring.monitor, status.monitoring.monitor);
    badge("health-timer", status.monitoring.health_timer, status.monitoring.health_timer);
    badge("monitor-timer", status.monitoring.monitor_timer, status.monitoring.monitor_timer);
    const failedUnits = status.monitoring.failed_units;
    badge("failed-units", failedUnits === null ? "UNKNOWN" : String(failedUnits), failedUnits === 0 ? "ok" : failedUnits === null ? "unknown" : "failed");

    generatedAtMs = Date.parse(status.generated_at);
    text("last-updated", formatLastUpdated(generatedAtMs));
    renderSummary();
  }

  function updateStaleState() {
    if (requestFailed) return;
    if (!Number.isFinite(generatedAtMs)) {
      setUiState("stale");
      return;
    }
    setUiState(Date.now() - generatedAtMs > STALE_AFTER_MS ? "stale" : "ready");
  }

  async function refreshStatus() {
    try {
      const response = await fetch("/api/status", { cache: "no-store", headers: { Accept: "application/json" } });
      if (!response.ok) throw new Error("status unavailable");
      const status = await response.json();
      renderStatus(status);
      requestFailed = false;
      updateStaleState();
    } catch (_error) {
      requestFailed = true;
      document.body.dataset.overall = "unknown";
      setUiState("unavailable");
      badge("overall-state", "UNKNOWN", "unknown");
    }
  }

  setUiState("loading");
  refreshStatus();
  setInterval(refreshStatus, POLL_INTERVAL_MS);
  setInterval(updateStaleState, 1000);
})();
