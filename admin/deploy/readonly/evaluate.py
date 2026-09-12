#!/usr/bin/python3 -I
"""Fixed, zero-argument entry into the coherent Admin no-recovery bundle."""

import os
import sys


def main() -> int:
    if len(sys.argv) != 1:
        return 64
    if os.geteuid() != 0:
        return 77
    # Never inherit caller configuration overrides, shell startup files or PATH.
    # The root helper validates every bundle/configuration ancestor before use.
    os.execve(
        "/usr/bin/bash",
        ("/usr/bin/bash", "--noprofile", "--norc",
         "/opt/warp-egress-admin-console/readonly/v3/health-readonly.sh"),
        {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "HOME": "/root", "LANG": "C", "LC_ALL": "C"},
    )
    return 70  # execve never returns on success


if __name__ == "__main__":
    raise SystemExit(main())
