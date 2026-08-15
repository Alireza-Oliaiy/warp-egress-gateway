#!/usr/bin/python3 -I
"""Atomic fixed-path writer for intentional-disconnect runtime intent."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
from typing import Any
import uuid

MAX_INPUT_BYTES = 4096
MAX_INTENT_BYTES = 4096
ACTOR_RE = re.compile(r"[\x20-\x7e]{1,128}\Z")
INTENT_FIELDS = {"version", "state", "created_at", "request_id", "actor"}
INPUT_FIELDS = {"request_id", "asserted_actor"}
RFC3339_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\Z")


class IntentError(Exception):
    code = "intent_error"


class IntentInputError(IntentError):
    code = "invalid_internal_input"


class IntentConflict(IntentError):
    code = "intent_conflict"


@dataclass(frozen=True)
class IntentRuntime:
    directory: Path
    intent_path: Path
    expected_uid: int | None
    expected_gid: int | None
    enforce_permissions: bool


PRODUCTION_RUNTIME = IntentRuntime(
    directory=Path("/run/warp-egress-gateway"),
    intent_path=Path("/run/warp-egress-gateway/intentional-disconnect.json"),
    expected_uid=0,
    expected_gid=0,
    enforce_permissions=True,
)


def command_runtime() -> IntentRuntime:
    if os.environ.get("WARP_RUNTIME_STATE_TEST_MODE") == "1" and hasattr(os, "geteuid") and os.geteuid() != 0:
        directory = Path(os.environ["WARP_RUNTIME_STATE_TEST_DIR"])
        return IntentRuntime(
            directory=directory,
            intent_path=directory / "intentional-disconnect.json",
            expected_uid=os.getuid(),
            expected_gid=os.getgid(),
            enforce_permissions=os.environ.get("WARP_RUNTIME_STATE_TEST_ASSUME_SAFE") != "1",
        )
    return PRODUCTION_RUNTIME


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise IntentInputError()
        result[key] = value
    return result


def parse_uuid4(value: Any) -> str:
    if type(value) is not str:
        raise IntentInputError()
    try:
        parsed = uuid.UUID(value)
    except ValueError as exc:
        raise IntentInputError() from exc
    if parsed.version != 4 or str(parsed) != value:
        raise IntentInputError()
    return value


def parse_input(raw: bytes) -> dict[str, str]:
    if not raw or len(raw) > MAX_INPUT_BYTES:
        raise IntentInputError()
    try:
        value = json.loads(
            raw.decode("utf-8", errors="strict"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=lambda _value: (_ for _ in ()).throw(IntentInputError()),
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as exc:
        raise IntentInputError() from exc
    if type(value) is not dict or set(value) != INPUT_FIELDS:
        raise IntentInputError()
    request_id = parse_uuid4(value["request_id"])
    actor = value["asserted_actor"]
    if type(actor) is not str or not ACTOR_RE.fullmatch(actor):
        raise IntentInputError()
    return {"request_id": request_id, "asserted_actor": actor}


def validate_intent_value(value: Any) -> dict[str, Any]:
    if type(value) is not dict or set(value) != INTENT_FIELDS:
        raise IntentConflict()
    if list(value) != ["version", "state", "created_at", "request_id", "actor"]:
        raise IntentConflict()
    if type(value["version"]) is not int or value["version"] != 1:
        raise IntentConflict()
    if value["state"] != "intentionally_disconnected":
        raise IntentConflict()
    if type(value["created_at"]) is not str or not RFC3339_RE.fullmatch(value["created_at"]):
        raise IntentConflict()
    parse_uuid4(value["request_id"])
    if type(value["actor"]) is not str or not ACTOR_RE.fullmatch(value["actor"]):
        raise IntentConflict()
    return value


def inspect_intent(runtime: IntentRuntime) -> dict[str, Any] | None:
    try:
        before = runtime.intent_path.lstat()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise IntentConflict() from exc
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise IntentConflict()
    if runtime.enforce_permissions:
        if (
            runtime.expected_uid is None
            or runtime.expected_gid is None
            or before.st_uid != runtime.expected_uid
            or before.st_gid != runtime.expected_gid
            or stat.S_IMODE(before.st_mode) != 0o600
        ):
            raise IntentConflict()
    if before.st_size < 1 or before.st_size > MAX_INTENT_BYTES:
        raise IntentConflict()
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(runtime.intent_path, flags)
    except OSError as exc:
        raise IntentConflict() from exc
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise IntentConflict()
        raw = os.read(descriptor, MAX_INTENT_BYTES + 1)
    finally:
        os.close(descriptor)
    try:
        value = json.loads(
            raw.decode("utf-8", errors="strict"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=lambda _value: (_ for _ in ()).throw(IntentConflict()),
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, IntentInputError) as exc:
        raise IntentConflict() from exc
    return validate_intent_value(value)


def ensure_directory(runtime: IntentRuntime) -> None:
    try:
        metadata = runtime.directory.lstat()
    except OSError as exc:
        raise IntentConflict() from exc
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise IntentConflict()
    if runtime.intent_path.parent != runtime.directory:
        raise IntentConflict()
    if runtime.enforce_permissions:
        if (
            runtime.expected_uid is None
            or runtime.expected_gid is None
            or metadata.st_uid != runtime.expected_uid
            or metadata.st_gid != runtime.expected_gid
            or stat.S_IMODE(metadata.st_mode) != 0o700
        ):
            raise IntentConflict()


def create_intent(runtime: IntentRuntime, payload: dict[str, str]) -> dict[str, Any]:
    ensure_directory(runtime)
    existing = inspect_intent(runtime)
    if existing is not None:
        return {"created": False, "since": existing["created_at"]}
    request_id = parse_uuid4(payload.get("request_id"))
    actor = payload.get("asserted_actor")
    if type(actor) is not str or not ACTOR_RE.fullmatch(actor):
        raise IntentInputError()
    created_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    value = {
        "version": 1,
        "state": "intentionally_disconnected",
        "created_at": created_at,
        "request_id": request_id,
        "actor": actor,
    }
    encoded = json.dumps(value, separators=(",", ":"), ensure_ascii=True).encode("ascii") + b"\n"
    if len(encoded) > MAX_INTENT_BYTES:
        raise IntentInputError()

    descriptor = -1
    temporary = ""
    try:
        descriptor, temporary = tempfile.mkstemp(
            prefix=".intentional-disconnect.", dir=runtime.directory
        )
        if hasattr(os, "fchmod"):
            os.fchmod(descriptor, 0o600)
        else:
            os.chmod(temporary, 0o600)
        if hasattr(os, "fchown") and runtime.expected_uid is not None and runtime.expected_gid is not None:
            os.fchown(descriptor, runtime.expected_uid, runtime.expected_gid)
        offset = 0
        while offset < len(encoded):
            offset += os.write(descriptor, encoded[offset:])
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1

        # Never replace a record that appeared or became suspicious while the
        # temporary file was being prepared.
        if inspect_intent(runtime) is not None:
            raise IntentConflict()
        os.replace(temporary, runtime.intent_path)
        temporary = ""
        if hasattr(os, "O_DIRECTORY"):
            directory_fd = os.open(runtime.directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
    return {"created": True, "since": created_at}


def main() -> int:
    runtime = command_runtime()
    if runtime is PRODUCTION_RUNTIME and (not hasattr(os, "geteuid") or os.geteuid() != 0):
        print('{"ok":false,"code":"requires_root"}')
        return 8
    try:
        if len(sys.argv) == 2 and sys.argv[1] == "inspect":
            value = inspect_intent(runtime)
            if value is None:
                raise IntentConflict()
            result = {"ok": True, "created": False, "since": value["created_at"]}
        elif len(sys.argv) == 2 and sys.argv[1] == "validate-input":
            payload = parse_input(sys.stdin.buffer.read(MAX_INPUT_BYTES + 1))
            result = {"ok": True, "payload": payload}
        elif len(sys.argv) == 1:
            payload = parse_input(sys.stdin.buffer.read(MAX_INPUT_BYTES + 1))
            result = {"ok": True, **create_intent(runtime, payload)}
        else:
            raise IntentInputError()
        print(json.dumps(result, separators=(",", ":"), ensure_ascii=True))
        return 0
    except IntentError as exc:
        print(json.dumps({"ok": False, "code": exc.code}, separators=(",", ":")))
        return 4


if __name__ == "__main__":
    raise SystemExit(main())
