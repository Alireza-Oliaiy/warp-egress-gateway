#!/usr/bin/python3 -I
"""Create a deterministic nftables fingerprint without runtime counters or handles."""

from __future__ import annotations

import hashlib
import json
import sys
from typing import Any


MAX_INPUT_BYTES = 1024 * 1024


class InvalidNftSnapshot(ValueError):
    """The nft JSON document is malformed or outside the fixed contract."""


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise InvalidNftSnapshot()
        result[key] = value
    return result


def normalize(value: Any) -> Any:
    if type(value) is list:
        return [normalize(item) for item in value]
    if type(value) is dict:
        result: dict[str, Any] = {}
        for key, item in value.items():
            if key == "handle":
                continue
            if key == "counter" and type(item) is dict:
                result[key] = {
                    counter_key: normalize(counter_value)
                    for counter_key, counter_value in item.items()
                    if counter_key not in {"packets", "bytes"}
                }
            else:
                result[key] = normalize(item)
        return result
    return value


def fingerprint(raw: bytes) -> str:
    if not raw or len(raw) > MAX_INPUT_BYTES:
        raise InvalidNftSnapshot()
    try:
        value = json.loads(
            raw.decode("utf-8", errors="strict"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=lambda _value: (_ for _ in ()).throw(InvalidNftSnapshot()),
        )
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, ValueError) as exc:
        raise InvalidNftSnapshot() from exc
    if type(value) is not dict or set(value) != {"nftables"} or type(value["nftables"]) is not list:
        raise InvalidNftSnapshot()
    canonical = json.dumps(
        normalize(value),
        ensure_ascii=True,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("ascii")
    return hashlib.sha256(canonical).hexdigest()


def main() -> int:
    try:
        result = fingerprint(sys.stdin.buffer.read(MAX_INPUT_BYTES + 1))
    except InvalidNftSnapshot:
        return 2
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
