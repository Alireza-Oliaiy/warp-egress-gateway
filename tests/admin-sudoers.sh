#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
POLICY=${ROOT}/admin/deploy/sudoers/warp-egress-gateway-admin
VISUDO_BIN=$(command -v visudo || true)

[[ -n ${VISUDO_BIN} ]] || { echo 'visudo is required for Admin sudoers tests.' >&2; exit 1; }
"${VISUDO_BIN}" -cf "${POLICY}"

expected='warp-admin ALL=(root:root) NOPASSWD:NOSETENV: /usr/local/libexec/warp-egress-gateway/warp-admin-helper ""'
mapfile -t rules < <(grep -Ev '^[[:space:]]*(#|$|Defaults:)' "${POLICY}")
[[ ${#rules[@]} -eq 1 && ${rules[0]} == "${expected}" ]]
if grep -q 'warp-web' "${POLICY}"; then
  echo 'warp-web unexpectedly appears in the Admin sudoers policy.' >&2
  exit 1
fi
if grep -Eq '(^|[[:space:],])SETENV:|\*|/bin/(ba)?sh|python|perl|systemctl|journalctl|/ip([[:space:]]|$)|/nft([[:space:]]|$)|/wg([[:space:]]|$)|warp-gateway([[:space:]]|$)' "${POLICY}"; then
  echo 'Admin sudoers policy contains a forbidden command or environment authority.' >&2
  exit 1
fi

python3 - "${POLICY}" <<'PY'
from pathlib import Path
import sys

line = next(
    item for item in Path(sys.argv[1]).read_text(encoding="ascii").splitlines()
    if item and not item.startswith("#") and not item.startswith("Defaults:")
)
allowed_user = "warp-admin"
allowed_argv = ("/usr/local/libexec/warp-egress-gateway/warp-admin-helper",)

def allowed(user: str, argv: tuple[str, ...], *, preserve_environment: bool = False) -> bool:
    return user == allowed_user and argv == allowed_argv and not preserve_environment and 'NOSETENV:' in line and line.endswith(' ""')

assert allowed("warp-admin", allowed_argv)
denied = (
    ("warp-admin", allowed_argv + ("status",), False),
    ("warp-web", allowed_argv, False),
    ("warp-admin", ("/bin/bash",), False),
    ("warp-admin", ("/bin/sh",), False),
    ("warp-admin", ("/usr/bin/python3",), False),
    ("warp-admin", ("/usr/bin/systemctl",), False),
    ("warp-admin", ("/usr/bin/journalctl",), False),
    ("warp-admin", ("/usr/sbin/ip",), False),
    ("warp-admin", ("/usr/sbin/nft",), False),
    ("warp-admin", ("/usr/bin/wg",), False),
    ("warp-admin", ("/usr/local/sbin/warp-gateway",), False),
    ("warp-admin", ("/usr/local/lib/warp-egress-gateway/health-readonly.sh",), False),
    ("warp-admin", allowed_argv, True),
)
for entry in denied:
    assert not allowed(entry[0], entry[1], preserve_environment=entry[2]), entry
print("Admin sudoers allow/deny matrix passed.")
PY
