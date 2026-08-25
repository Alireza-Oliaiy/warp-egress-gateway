#!/usr/bin/env python3
"""Strict status contract shared by the collector and read-only server."""

from __future__ import annotations

import copy
from datetime import datetime, timezone
import ipaddress
import json
import re
from typing import Any, Mapping


MAX_STATUS_BYTES = 64 * 1024
SCHEMA_VERSION = 1
STALE_AFTER_SECONDS = 30

_TOP_LEVEL = {
    "schema_version",
    "generated_at",
    "overall",
    "system",
    "warp",
    "paths",
    "routing",
    "safety",
    "monitoring",
}
_SECRET_KEY_FRAGMENTS = {
    "privatekey",
    "presharedkey",
    "password",
    "token",
    "cookie",
    "tlsprivate",
    "wgcfaccount",
    "environmentdump",
    "sudoers",
}
_SEMVER_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
_HOSTNAME_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$")
_COLO_RE = re.compile(r"^[A-Z0-9]{3}$")
_LOCATION_RE = re.compile(r"^[A-Z0-9-]{2,32}$")
_TIMESTAMP_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")


class StatusValidationError(ValueError):
    """The snapshot is malformed, unsafe, or outside schema version 1."""


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise StatusValidationError("duplicate JSON key")
        value[key] = item
    return value


def _reject_constant(_value: str) -> None:
    raise StatusValidationError("non-finite JSON number")


def _exact_object(value: object, keys: set[str], label: str) -> dict[str, Any]:
    if type(value) is not dict or set(value) != keys:
        raise StatusValidationError(f"{label} fields do not match schema")
    return value


def _enum(value: object, allowed: set[str], label: str) -> str:
    if type(value) is not str or value not in allowed:
        raise StatusValidationError(f"{label} is invalid")
    return value


def _non_negative_int(value: object, label: str) -> int:
    if type(value) is not int or value < 0:
        raise StatusValidationError(f"{label} is invalid")
    return value


def _nullable_string(value: object, label: str, *, maximum: int = 128) -> str | None:
    if value is None:
        return None
    if type(value) is not str or not value or len(value) > maximum or any(ord(ch) < 32 for ch in value):
        raise StatusValidationError(f"{label} is invalid")
    return value


def _parse_generated_at(value: object) -> datetime:
    if type(value) is not str or not _TIMESTAMP_RE.fullmatch(value):
        raise StatusValidationError("generated_at is not canonical UTC")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError as exc:
        raise StatusValidationError("generated_at is invalid") from exc


def _reject_secret_keys(value: object) -> None:
    if type(value) is dict:
        for key, item in value.items():
            if type(key) is not str:
                raise StatusValidationError("JSON object key is not a string")
            normalized = re.sub(r"[^a-z0-9]", "", key.lower())
            if any(fragment in normalized for fragment in _SECRET_KEY_FRAGMENTS):
                raise StatusValidationError("secret-like field is forbidden")
            _reject_secret_keys(item)
    elif type(value) is list:
        for item in value:
            _reject_secret_keys(item)


def validate_status(value: object) -> dict[str, object]:
    """Validate and defensively copy one complete schema-version 1 snapshot."""

    _reject_secret_keys(value)
    root = _exact_object(value, _TOP_LEVEL, "status")
    if root["schema_version"] != SCHEMA_VERSION or type(root["schema_version"]) is not int:
        raise StatusValidationError("schema_version is unsupported")
    _parse_generated_at(root["generated_at"])

    overall = _exact_object(root["overall"], {"state"}, "overall")
    _enum(overall["state"], {"online", "degraded", "offline", "unknown"}, "overall.state")

    system = _exact_object(root["system"], {"hostname", "version", "uptime_seconds"}, "system")
    if type(system["hostname"]) is not str or not _HOSTNAME_RE.fullmatch(system["hostname"]):
        raise StatusValidationError("system.hostname is invalid")
    if type(system["version"]) is not str or (
        system["version"] != "unknown" and not _SEMVER_RE.fullmatch(system["version"])
    ):
        raise StatusValidationError("system.version is invalid")
    if system["uptime_seconds"] is not None:
        _non_negative_int(system["uptime_seconds"], "system.uptime_seconds")

    warp = _exact_object(
        root["warp"],
        {"state", "interface", "handshake_age_seconds", "public_ip", "colo", "location"},
        "warp",
    )
    _enum(warp["state"], {"connected", "disconnected", "unknown"}, "warp.state")
    _enum(warp["interface"], {"up", "down", "unknown"}, "warp.interface")
    if warp["handshake_age_seconds"] is not None:
        _non_negative_int(warp["handshake_age_seconds"], "warp.handshake_age_seconds")
    public_ip = _nullable_string(warp["public_ip"], "warp.public_ip", maximum=45)
    if public_ip is not None:
        try:
            ipaddress.ip_address(public_ip)
        except ValueError as exc:
            raise StatusValidationError("warp.public_ip is invalid") from exc
    colo = _nullable_string(warp["colo"], "warp.colo", maximum=3)
    if colo is not None and not _COLO_RE.fullmatch(colo):
        raise StatusValidationError("warp.colo is invalid")
    location = _nullable_string(warp["location"], "warp.location", maximum=32)
    if location is not None and not _LOCATION_RE.fullmatch(location):
        raise StatusValidationError("warp.location is invalid")

    paths = _exact_object(root["paths"], {"direct", "warp"}, "paths")
    for name in ("direct", "warp"):
        path = _exact_object(paths[name], {"state", "warp"}, f"paths.{name}")
        _enum(path["state"], {"ok", "failed", "unknown"}, f"paths.{name}.state")
        _enum(path["warp"], {"on", "off", "unknown"}, f"paths.{name}.warp")

    routing = _exact_object(
        root["routing"], {"rule_100", "rule_110", "table_100", "main_default"}, "routing"
    )
    for name in routing:
        _enum(routing[name], {"ok", "failed", "unknown"}, f"routing.{name}")

    safety = _exact_object(root["safety"], {"kill_switch", "ipv4_forwarding"}, "safety")
    _enum(safety["kill_switch"], {"active", "inactive", "unknown"}, "safety.kill_switch")
    if safety["ipv4_forwarding"] is not None and type(safety["ipv4_forwarding"]) is not bool:
        raise StatusValidationError("safety.ipv4_forwarding is invalid")

    monitoring = _exact_object(
        root["monitoring"],
        {"health", "monitor", "health_timer", "monitor_timer", "failed_units"},
        "monitoring",
    )
    for name in ("health", "monitor"):
        _enum(monitoring[name], {"ok", "warn", "failed", "unknown"}, f"monitoring.{name}")
    for name in ("health_timer", "monitor_timer"):
        _enum(monitoring[name], {"active", "inactive", "unknown"}, f"monitoring.{name}")
    if monitoring["failed_units"] is not None:
        _non_negative_int(monitoring["failed_units"], "monitoring.failed_units")
    return copy.deepcopy(root)


def loads_status(raw: bytes) -> dict[str, object]:
    """Decode one bounded strict JSON snapshot and apply the status contract."""

    if type(raw) is not bytes or len(raw) == 0 or len(raw) > MAX_STATUS_BYTES:
        raise StatusValidationError("snapshot size is invalid")
    try:
        value = json.loads(
            raw.decode("utf-8", errors="strict"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, StatusValidationError) as exc:
        raise StatusValidationError("snapshot JSON is invalid") from exc
    return validate_status(value)


def is_stale(
    value: Mapping[str, object],
    *,
    now: datetime | None = None,
    threshold_seconds: int = STALE_AFTER_SECONDS,
) -> bool:
    """Return true only when the validated snapshot is older than the threshold."""

    if type(threshold_seconds) is not int or threshold_seconds < 0:
        raise StatusValidationError("stale threshold is invalid")
    generated = _parse_generated_at(value.get("generated_at"))
    current = datetime.now(timezone.utc) if now is None else now
    if current.tzinfo is None:
        raise StatusValidationError("current time must be timezone-aware")
    return (current.astimezone(timezone.utc) - generated).total_seconds() > threshold_seconds
