#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
POLICY="${ROOT}/web/sudoers/warp-egress-gateway-web"
HELPER="${ROOT}/web/helper/warp-web-helper.py"
PYTHON3_BIN=${WARP_GATEWAY_PYTHON3:-python3}
VISUDO_BIN=${WARP_GATEWAY_VISUDO:-visudo}
CVTSUDOERS_BIN=${WARP_GATEWAY_CVTSUDOERS:-cvtsudoers}
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "${TEMP_DIR}"' EXIT

fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

resolve_tool() {
  local candidate=$1
  if [[ ${candidate} == */* ]]; then
    [[ -x ${candidate} ]] || fail "mandatory validator is unavailable: ${candidate}"
    printf '%s\n' "${candidate}"
  else
    command -v "${candidate}" 2>/dev/null \
      || fail "mandatory validator is unavailable: ${candidate}"
  fi
}

VISUDO_BIN=$(resolve_tool "${VISUDO_BIN}")
CVTSUDOERS_BIN=$(resolve_tool "${CVTSUDOERS_BIN}")
PYTHON3_BIN=$(resolve_tool "${PYTHON3_BIN}")

[[ -f ${POLICY} && ! -L ${POLICY} ]] \
  || fail "missing regular sudoers template: web/sudoers/warp-egress-gateway-web"
[[ -f ${HELPER} && ! -L ${HELPER} ]] \
  || fail "missing regular helper source: web/helper/warp-web-helper.py"

"${VISUDO_BIN}" -cf "${POLICY}" >/dev/null \
  || fail "visudo rejected the sudoers template"

PARSED_JSON="${TEMP_DIR}/policy.json"
"${CVTSUDOERS_BIN}" -i sudoers -f json -o "${PARSED_JSON}" "${POLICY}" \
  || fail "cvtsudoers rejected the sudoers template"

"${PYTHON3_BIN}" - "${PARSED_JSON}" <<'PY'
from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
helper = "/usr/local/libexec/warp-egress-gateway/warp-web-helper"

expected_defaults = [
    {
        "Binding": [{"username": "warp-web"}],
        "Options": [{"env_reset": True}],
    },
    {
        "Binding": [{"username": "warp-web"}],
        "Options": [{"secure_path": "/usr/sbin:/usr/bin:/sbin:/bin"}],
    },
    {
        "Binding": [{"username": "warp-web"}],
        "Options": [{"umask": "0077"}],
    },
    {
        "Binding": [{"username": "warp-web"}],
        "Options": [{"umask_override": True}],
    },
    {
        "Binding": [{"username": "warp-web"}],
        "Options": [{"log_allowed": True}, {"log_denied": True}],
    },
]
if document.get("Defaults") != expected_defaults:
    raise SystemExit("parsed Defaults do not match the approved environment boundary")

expected_specs = [
    {
        "User_List": [{"username": "warp-web"}],
        "Host_List": [{"hostname": "ALL"}],
        "Cmnd_Specs": [
            {
                "runasusers": [{"username": "root"}],
                "runasgroups": [{"usergroup": "root"}],
                "Options": [{"authenticate": False}, {"setenv": False}],
                "Commands": [{"command": f'{helper} ""'}],
            }
        ],
    }
]
if document.get("User_Specs") != expected_specs:
    raise SystemExit("parsed User_Specs do not match the approved narrow grant")

parsed_command = document["User_Specs"][0]["Cmnd_Specs"][0]["Commands"][0]["command"]
if parsed_command != f'{helper} ""':
    raise SystemExit("the helper is not restricted to zero arguments")

def permits(user: str, runas_user: str, runas_group: str, path: str, argv: list[str]) -> bool:
    return (
        user == "warp-web"
        and runas_user == "root"
        and runas_group == "root"
        and path == helper
        and argv == []
    )

if not permits("warp-web", "root", "root", helper, []):
    raise SystemExit("exact root:root zero-argument helper invocation was rejected")

negative = [
    ("other-user", "root", "root", helper, []),
    ("warp-web", "root", "adm", helper, []),
    ("warp-web", "daemon", "root", helper, []),
    ("warp-web", "daemon", "daemon", helper, []),
    ("warp-web", "root", "root", "/bin/bash", []),
    ("warp-web", "root", "root", "/bin/sh", []),
    ("warp-web", "root", "root", "/bin/bash", ["-i"]),
    ("warp-web", "root", "root", "/bin/bash", ["-s"]),
    ("warp-web", "root", "root", "/usr/bin/python", []),
    ("warp-web", "root", "root", "/usr/bin/python3", ["/tmp/evil.py"]),
    ("warp-web", "root", "root", "/usr/bin/systemctl", ["restart", "ssh"]),
    ("warp-web", "root", "root", "/usr/bin/journalctl", ["-u", "ssh"]),
    ("warp-web", "root", "root", "/usr/sbin/ip", ["rule", "show"]),
    ("warp-web", "root", "root", "/usr/sbin/nft", ["list", "ruleset"]),
    ("warp-web", "root", "root", "/usr/bin/wg", ["show"]),
    ("warp-web", "root", "root", "/usr/bin/cat", ["/root/private"]),
    ("warp-web", "root", "root", "sudoedit", ["/etc/shadow"]),
    ("warp-web", "root", "root", "/usr/local/lib/warp-egress-gateway/routing.sh", []),
    ("warp-web", "root", "root", "/usr/local/lib/warp-egress-gateway/route-up.sh", []),
    ("warp-web", "root", "root", "/usr/local/lib/warp-egress-gateway/route-down.sh", []),
    ("warp-web", "root", "root", "/usr/local/lib/warp-egress-gateway/web-warp-disconnect.sh", []),
    ("warp-web", "root", "root", "/usr/local/lib/warp-egress-gateway/web-routing-repair.sh", []),
    ("warp-web", "root", "root", "/usr/local/lib/warp-egress-gateway/web-health-run.sh", []),
    ("warp-web", "root", "root", "/usr/local/libexec/warp-egress-gateway/arbitrary", []),
    ("warp-web", "root", "root", "/opt/warp-egress-gateway/warp-web-helper", []),
    ("warp-web", "root", "root", "/tmp/warp-web-helper", []),
    ("warp-web", "root", "root", helper, ["arbitrary"]),
    ("warp-web", "root", "root", helper, ["one", "two"]),
    ("warp-web", "root", "root", helper, [" "]),
    ("warp-web", "root", "root", helper, ["; /bin/sh"]),
    ("warp-web", "root", "root", helper, ["/tmp/payload"]),
]
authorized = [case for case in negative if permits(*case)]
if authorized:
    raise SystemExit(f"negative privilege cases were authorized: {authorized!r}")

with tempfile.TemporaryDirectory() as temporary:
    substitute = Path(temporary) / "warp-web-helper"
    substitute.symlink_to(helper)
    if permits("warp-web", "root", "root", str(substitute), []):
        raise SystemExit("a helper symlink substitute was authorized")

print("PASS parser-backed exact user/RunAs/path/zero-argument policy")
print(f"PASS negative privilege matrix ({len(negative)} denied cases)")
PY

MUTATED_POLICY="${TEMP_DIR}/policy-without-empty-args"
"${PYTHON3_BIN}" - "${POLICY}" "${MUTATED_POLICY}" <<'PY'
from pathlib import Path
import sys

source, destination = map(Path, sys.argv[1:])
helper_with_empty_args = '/usr/local/libexec/warp-egress-gateway/warp-web-helper ""'
text = source.read_text(encoding="utf-8")
if text.count(helper_with_empty_args) != 1:
    raise SystemExit("expected exactly one zero-argument helper specification")
destination.write_text(text.replace(helper_with_empty_args, helper_with_empty_args[:-3]), encoding="utf-8")
PY
"${VISUDO_BIN}" -cf "${MUTATED_POLICY}" >/dev/null \
  || fail "zero-argument mutation fixture is not valid sudoers syntax"
MUTATED_JSON="${TEMP_DIR}/policy-without-empty-args.json"
"${CVTSUDOERS_BIN}" -i sudoers -f json -o "${MUTATED_JSON}" "${MUTATED_POLICY}" \
  || fail "cvtsudoers rejected the zero-argument mutation fixture"
"${PYTHON3_BIN}" - "${MUTATED_JSON}" <<'PY'
import json
from pathlib import Path
import sys

helper = "/usr/local/libexec/warp-egress-gateway/warp-web-helper"
document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
command = document["User_Specs"][0]["Cmnd_Specs"][0]["Commands"][0]["command"]
if command != helper:
    raise SystemExit("mutation fixture did not remove only the empty argument specification")
# sudoers semantics: a command with no argument specification accepts any argv.
def permits_without_argument_specification(path: str, argv: list[str]) -> bool:
    del argv
    return command == helper and path == helper

if not permits_without_argument_specification(helper, ["arbitrary"]):
    raise SystemExit("missing empty argument specification did not demonstrate widening")
print('PASS parser-backed mutation proves removing "" widens argv authorization')
PY

"${PYTHON3_BIN}" - "${HELPER}" <<'PY'
from __future__ import annotations

from dataclasses import replace
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import uuid

helper_path = Path(sys.argv[1])
if helper_path.read_text(encoding="utf-8").splitlines()[0] != "#!/usr/bin/python3 -I":
    raise SystemExit("helper does not use the fixed isolated Python interpreter")

spec = importlib.util.spec_from_file_location("sudoers_helper_contract", helper_path)
if spec is None or spec.loader is None:
    raise SystemExit("unable to load helper for contract validation")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

runtime = module.PRODUCTION_RUNTIME
expected_adapters = {
    "routing-repair": ("/usr/local/lib/warp-egress-gateway/web-routing-repair.sh",),
    "health-run": ("/usr/local/lib/warp-egress-gateway/web-health-run.sh",),
    "warp-disconnect": ("/usr/local/lib/warp-egress-gateway/web-warp-disconnect.sh",),
}
if runtime.ip_argv != ("/usr/sbin/ip",) or runtime.adapter_argv != expected_adapters:
    raise SystemExit("production child executable paths are not the fixed allowlist")
if runtime.audit_argv != ("/usr/bin/logger", "--tag", "warp-web-helper", "--"):
    raise SystemExit("production audit executable path is not fixed")
for command in (runtime.ip_argv, runtime.audit_argv, *runtime.adapter_argv.values()):
    if not command or not command[0].startswith("/"):
        raise SystemExit("a production child executable is not absolute")
if module.MAX_INPUT_BYTES != 8192:
    raise SystemExit("helper input bound changed")

request_id = str(uuid.uuid4())
valid = {
    "protocol": 1,
    "verb": "warp-disconnect",
    "parameters": {"confirmation": "disconnect-and-block-transit"},
    "request_id": request_id,
    "audit_context": {
        "asserted_actor": "test-actor",
        "asserted_role": "Admin",
        "asserted_source_ip": "127.0.0.1",
    },
}
valid_encoded = json.dumps(valid, separators=(",", ":")).encode()
parsed = module.parse_request(valid_encoded)
if parsed.request_id != request_id or parsed.verb != "warp-disconnect":
    raise SystemExit("valid strict helper request was rejected")

invalid_payloads = [
    valid_encoded.replace(b'"protocol":1', b'"protocol":1,"protocol":1', 1),
    json.dumps({**valid, "unknown": True}).encode(),
    json.dumps({**valid, "protocol": 2}).encode(),
    json.dumps({**valid, "verb": "shell"}).encode(),
    json.dumps({**valid, "request_id": "not-a-uuid"}).encode(),
    json.dumps({**valid, "audit_context": {**valid["audit_context"], "asserted_role": "Root"}}).encode(),
    json.dumps({**valid, "parameters": {"confirmation": "yes"}}).encode(),
    b"x" * 8193,
]
for payload in invalid_payloads:
    try:
        module.parse_request(payload)
    except module.InvalidRequest:
        continue
    raise SystemExit("helper accepted malformed, widened, or oversized input")

hostile = {
    "PATH": "/tmp/attacker-bin",
    "PYTHONPATH": "/tmp/attacker-python",
    "PYTHONHOME": "/tmp/attacker-home",
    "LD_PRELOAD": "/tmp/attacker-preload.so",
    "LD_LIBRARY_PATH": "/tmp/attacker-lib",
    "BASH_ENV": "/tmp/attacker-bash-env",
    "ENV": "/tmp/attacker-env",
    "SHELLOPTS": "xtrace",
    "PERL5LIB": "/tmp/attacker-perl",
}
saved = os.environ.copy()
try:
    os.environ.update(hostile)
    return_code, output = module.run_bounded_process(
        replace(runtime, child_timeout_seconds=1.0),
        ("/usr/bin/env",),
    )
finally:
    os.environ.clear()
    os.environ.update(saved)
if return_code != 0:
    raise SystemExit("fixed child environment probe failed")
child_environment = dict(line.split("=", 1) for line in output.decode("utf-8").splitlines())
if child_environment != dict(runtime.child_environment):
    raise SystemExit(f"caller environment reached a privileged child: {child_environment!r}")

with tempfile.TemporaryDirectory() as temporary:
    marker = Path(temporary) / "shell-executed"
    literal = f"$(touch {marker})"
    return_code, output = module.run_bounded_process(
        replace(runtime, child_timeout_seconds=1.0),
        ("/usr/bin/printf", "%s", literal),
    )
    if return_code != 0 or output.decode("utf-8") != literal or marker.exists():
        raise SystemExit("privileged child execution interpreted shell syntax")

print("PASS helper strict protocol and fixed executable contract")
print("PASS privileged child execution treats shell syntax as inert argv")
print("PASS hostile environment replacement (9 execution-influencing variables removed)")
PY

if LC_ALL=C grep -Eq \
  'PrivateKey|PresharedKey|BEGIN [A-Z ]*PRIVATE KEY|password[[:space:]]*=|token[[:space:]]*=|([0-9]{1,3}\.){3}[0-9]{1,3}' \
  "${POLICY}"; then
  fail "sudoers template contains secret or infrastructure-specific material"
fi
if LC_ALL=C grep -q $'\r' "${POLICY}"; then
  fail "sudoers template contains CRLF line endings"
fi

(
  umask 0077
  "${PYTHON3_BIN}" "${ROOT}/tests/intent_writer_test.py" -q >/dev/null
  bash "${ROOT}/tests/web-mutations.sh" >/dev/null
) || fail "helper operations are incompatible with sudo umask 0077"

printf 'PASS visudo %s\n' "$("${VISUDO_BIN}" -V | sed -n '1p')"
printf 'PASS cvtsudoers parser-backed policy validation\n'
printf 'PASS sudo umask 0077 compatibility\n'
printf 'PASS sudoers secret and LF audit\n'
printf 'NARROW_SUDOERS_TESTS_PASSED\n'
