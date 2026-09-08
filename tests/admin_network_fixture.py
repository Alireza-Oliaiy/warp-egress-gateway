#!/usr/bin/env python3
"""Create isolated, non-secret address fixtures for Admin deployment tests."""
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
dashboard = root / "etc/warp-egress-dashboard/dashboard.env"
gateway = root / "etc/warp-egress-gateway/warp-gateway.env"
observed = root / "network-addresses.json"
for path, content in (
    (dashboard, "DASHBOARD_LISTEN=192.0.2.10\nDASHBOARD_PORT=8787\n"),
    (gateway, 'UPLINK_IF="ens160"\nTRANSIT_IF="ens192"\nWARP_IF="warp0"\n'),
    (observed, json.dumps({
        interface: [{"ifname": interface, "addr_info": [
            {"family": "inet", "local": address, "prefixlen": 24, "scope": "global"}
        ]}] for interface, address in (("ens160", "192.0.2.10"), ("ens192", "10.1.1.222"))
    })),
):
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
        path.write_text(content, encoding="ascii")
        path.chmod(0o600 if path == gateway else 0o644)
