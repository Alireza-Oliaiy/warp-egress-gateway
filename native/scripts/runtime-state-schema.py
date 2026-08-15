#!/usr/bin/python3 -I
"""Canonical schema primitives for intentional-disconnect runtime state."""

from __future__ import annotations

import re
from typing import Any


INTENT_ACTOR_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.@-]{0,127}\Z")


def intent_actor_is_valid(value: Any) -> bool:
    return type(value) is str and INTENT_ACTOR_RE.fullmatch(value) is not None
