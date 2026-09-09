#!/usr/bin/env python3
"""Authoritative strict protocol shared by the Admin app and root helper."""

from __future__ import annotations

import copy
import json
import re
import uuid
from typing import Any


PROTOCOL_VERSION = 1
OPERATIONS = frozenset({"status", "health", "repair-routing"})
REPAIR_RESULT_CODES = frozenset({"unsafe_precondition", "partial_mutation_failure", "postcondition_failed"})
MAX_HELPER_INPUT_BYTES = 4096
MAX_HELPER_OUTPUT_BYTES = 64 * 1024
MAX_HTTP_BODY_BYTES = 1024

STATES = frozenset({"ok", "degraded", "failed", "intentionally_disconnected"})
RESULT_CODES = REPAIR_RESULT_CODES | frozenset(
    {
        "ok",
        "evaluation_unhealthy",
        "mutation_lock_busy",
        "observation_unavailable",
        "operation_timeout",
        "helper_protocol_error",
    }
)
EVIDENCE_KEYS = frozenset(
    {
        "version",
        "wireguard",
        "handshake",
        "handshake_age_seconds",
        "direct",
        "warp",
        "routing",
        "kill_switch",
        "forwarding",
        "monitoring",
        "failed_units",
    }
)
_RESPONSE_KEYS = frozenset(
    {"protocol", "request_id", "operation", "ok", "result_code", "changed", "state", "evidence"}
)
_REQUEST_KEYS = frozenset({"protocol", "operation", "request_id"})
_SEMVER_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
_SECRET_FRAGMENTS = (
    "privatekey",
    "presharedkey",
    "password",
    "cookie",
    "csrftoken",
    "wgcfaccount",
    "environment",
)


class ProtocolError(ValueError):
    """Input or output is outside the frozen Slice 1B protocol."""


def _duplicate_rejecting_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolError("duplicate JSON key")
        result[key] = value
    return result


def _reject_constant(_value: str) -> None:
    raise ProtocolError("non-finite JSON number")


def loads_exact_json(raw: bytes, *, maximum: int) -> object:
    """Decode one bounded UTF-8 JSON value, rejecting duplicates and trailing data."""

    if type(raw) is not bytes or not raw or len(raw) > maximum:
        raise ProtocolError("JSON size is invalid")
    try:
        text = raw.decode("utf-8", errors="strict")
        decoder = json.JSONDecoder(
            object_pairs_hook=_duplicate_rejecting_object,
            parse_constant=_reject_constant,
        )
        stripped = text.lstrip()
        value, end = decoder.raw_decode(stripped)
        if stripped[end:].strip():
            raise ProtocolError("trailing JSON data")
        return value
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, ProtocolError) as exc:
        raise ProtocolError("JSON is malformed") from exc


def canonical_uuid4(value: object) -> str:
    if type(value) is not str or len(value) != 36:
        raise ProtocolError("request_id is invalid")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as exc:
        raise ProtocolError("request_id is invalid") from exc
    if parsed.version != 4 or parsed.variant != uuid.RFC_4122 or str(parsed) != value:
        raise ProtocolError("request_id is not canonical UUIDv4")
    return value


def validate_request(value: object) -> dict[str, object]:
    if type(value) is not dict or set(value) != _REQUEST_KEYS:
        raise ProtocolError("request fields do not match schema")
    if type(value["protocol"]) is not int or value["protocol"] != PROTOCOL_VERSION:
        raise ProtocolError("protocol is unsupported")
    if type(value["operation"]) is not str or value["operation"] not in OPERATIONS:
        raise ProtocolError("operation is unsupported")
    canonical_uuid4(value["request_id"])
    return copy.deepcopy(value)


def loads_request(raw: bytes) -> dict[str, object]:
    return validate_request(loads_exact_json(raw, maximum=MAX_HELPER_INPUT_BYTES))


def encode_request(operation: str, request_id: str) -> bytes:
    value = validate_request(
        {"protocol": PROTOCOL_VERSION, "operation": operation, "request_id": request_id}
    )
    return json.dumps(value, allow_nan=False, ensure_ascii=True, separators=(",", ":")).encode("ascii")


def _enum(value: object, allowed: frozenset[str], label: str) -> str:
    if type(value) is not str or value not in allowed:
        raise ProtocolError(f"{label} is invalid")
    return value


def _reject_secrets(value: object) -> None:
    if type(value) is dict:
        for key, child in value.items():
            if type(key) is not str:
                raise ProtocolError("object key is invalid")
            normalized = re.sub(r"[^a-z0-9]", "", key.lower())
            if any(fragment in normalized for fragment in _SECRET_FRAGMENTS):
                raise ProtocolError("secret-like field is forbidden")
            _reject_secrets(child)
    elif type(value) is list:
        for child in value:
            _reject_secrets(child)


def validate_evidence(value: object) -> dict[str, object]:
    if type(value) is not dict or set(value) != EVIDENCE_KEYS:
        raise ProtocolError("evidence fields do not match schema")
    version = value["version"]
    if type(version) is not str or (version != "unknown" and not _SEMVER_RE.fullmatch(version)):
        raise ProtocolError("evidence.version is invalid")
    _enum(value["wireguard"], frozenset({"up", "down", "unknown"}), "evidence.wireguard")
    _enum(value["handshake"], frozenset({"ok", "stale", "none", "unknown"}), "evidence.handshake")
    handshake_age = value["handshake_age_seconds"]
    if handshake_age is not None and (type(handshake_age) is not int or handshake_age < 0):
        raise ProtocolError("evidence.handshake_age_seconds is invalid")
    _enum(value["direct"], frozenset({"ok", "failed", "unknown"}), "evidence.direct")
    _enum(value["warp"], frozenset({"on", "off", "failed", "unknown"}), "evidence.warp")
    _enum(value["routing"], frozenset({"ok", "failed", "unknown"}), "evidence.routing")
    _enum(value["kill_switch"], frozenset({"active", "inactive", "unknown"}), "evidence.kill_switch")
    _enum(value["forwarding"], frozenset({"enabled", "disabled", "unknown"}), "evidence.forwarding")
    _enum(value["monitoring"], frozenset({"ok", "failed", "unknown"}), "evidence.monitoring")
    failed_units = value["failed_units"]
    if failed_units is not None and (type(failed_units) is not int or failed_units < 0):
        raise ProtocolError("evidence.failed_units is invalid")
    _reject_secrets(value)
    return copy.deepcopy(value)


def validate_response(value: object) -> dict[str, object]:
    if type(value) is not dict or set(value) != _RESPONSE_KEYS:
        raise ProtocolError("response fields do not match schema")
    if type(value["protocol"]) is not int or value["protocol"] != PROTOCOL_VERSION:
        raise ProtocolError("response protocol is unsupported")
    canonical_uuid4(value["request_id"])
    _enum(value["operation"], OPERATIONS, "response.operation")
    if type(value["ok"]) is not bool:
        raise ProtocolError("response.ok is invalid")
    result_code = _enum(value["result_code"], RESULT_CODES, "response.result_code")
    repair = value["operation"] == "repair-routing"
    if type(value["changed"]) is not bool or (value["changed"] and (not repair or result_code != "ok")):
        raise ProtocolError("changed is permitted only for a verified successful repair")
    if not repair and result_code in REPAIR_RESULT_CODES:
        raise ProtocolError("repair failure code on a read-only operation")
    state = _enum(value["state"], STATES, "response.state")
    evidence = validate_evidence(value["evidence"])
    if result_code == "ok":
        if value["ok"] is not True or state not in ({"ok", "degraded"} if repair else {"ok"}):
            raise ProtocolError("successful response fields are inconsistent")
        required_healthy = {
            "wireguard": "up",
            "direct": "ok",
            "warp": "on",
            "routing": "ok",
            "kill_switch": "active",
            "monitoring": "ok",
        }
        if repair and state == "degraded":
            required_healthy = {"wireguard": "up", "routing": "ok", "kill_switch": "active"}
        if any(evidence[key] != expected for key, expected in required_healthy.items()):
            raise ProtocolError("ok state lacks required dataplane evidence")
    elif result_code == "evaluation_unhealthy":
        if repair or value["ok"] is not True or state != "failed":
            raise ProtocolError("unhealthy evaluation fields are inconsistent")
    elif value["ok"] is not False or state != "failed":
        raise ProtocolError("failed response fields are inconsistent")
    _reject_secrets(value)
    encoded = json.dumps(value, allow_nan=False, ensure_ascii=True, separators=(",", ":")).encode("ascii")
    if len(encoded) > MAX_HELPER_OUTPUT_BYTES:
        raise ProtocolError("response is oversized")
    return copy.deepcopy(value)


def loads_response(raw: bytes) -> dict[str, object]:
    return validate_response(loads_exact_json(raw, maximum=MAX_HELPER_OUTPUT_BYTES))


def encode_response(value: object) -> bytes:
    validated = validate_response(value)
    return json.dumps(validated, allow_nan=False, ensure_ascii=True, separators=(",", ":")).encode("ascii")


def unknown_evidence(*, version: str = "unknown") -> dict[str, object]:
    return {
        "version": version,
        "wireguard": "unknown",
        "handshake": "unknown",
        "handshake_age_seconds": None,
        "direct": "unknown",
        "warp": "unknown",
        "routing": "unknown",
        "kill_switch": "unknown",
        "forwarding": "unknown",
        "monitoring": "unknown",
        "failed_units": None,
    }
