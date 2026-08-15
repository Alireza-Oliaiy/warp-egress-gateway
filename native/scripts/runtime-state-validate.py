#!/usr/bin/python3 -I
"""Strict validator for the root-owned intentional-disconnect record."""

from __future__ import annotations

import datetime as dt
import json
import re
import sys
import uuid
from pathlib import Path
from typing import Any


MAX_INTENT_BYTES = 4096
EXPECTED_FIELDS = {
    "version",
    "state",
    "created_at",
    "request_id",
    "actor",
}
ACTOR_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.@-]{0,127}\Z")
UTC_TIMESTAMP_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\Z")


class InvalidIntent(ValueError):
    """The record is syntactically valid input but violates the schema."""


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise InvalidIntent("duplicate key")
        result[key] = value
    return result


def validate_record(record: Any) -> None:
    if type(record) is not dict or set(record) != EXPECTED_FIELDS:
        raise InvalidIntent("unexpected record fields")
    if type(record["version"]) is not int or record["version"] != 1:
        raise InvalidIntent("unsupported record version")
    if record["state"] != "intentionally_disconnected":
        raise InvalidIntent("unexpected state")

    created_at = record["created_at"]
    if type(created_at) is not str or not UTC_TIMESTAMP_RE.fullmatch(created_at):
        raise InvalidIntent("invalid creation timestamp")
    try:
        dt.datetime.strptime(created_at, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as exc:
        raise InvalidIntent("invalid creation timestamp") from exc

    request_id = record["request_id"]
    if type(request_id) is not str:
        raise InvalidIntent("invalid request ID")
    try:
        parsed_request_id = uuid.UUID(request_id)
    except ValueError as exc:
        raise InvalidIntent("invalid request ID") from exc
    if parsed_request_id.version != 4 or str(parsed_request_id) != request_id:
        raise InvalidIntent("invalid request ID")

    actor = record["actor"]
    if type(actor) is not str or not ACTOR_RE.fullmatch(actor):
        raise InvalidIntent("invalid actor")


def validate_path(path: Path) -> None:
    payload = path.read_bytes()
    if not payload or len(payload) > MAX_INTENT_BYTES:
        raise InvalidIntent("record size outside bounds")
    try:
        text = payload.decode("utf-8", errors="strict")
        record = json.loads(
            text,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=lambda _value: (_ for _ in ()).throw(
                InvalidIntent("non-standard numeric constant")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise InvalidIntent("invalid JSON") from exc
    validate_record(record)


def main() -> int:
    if len(sys.argv) != 2:
        return 2
    try:
        validate_path(Path(sys.argv[1]))
    except (InvalidIntent, OSError):
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
