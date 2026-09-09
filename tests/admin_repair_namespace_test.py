#!/usr/bin/env python3
"""Real kernel repair exclusively inside a new anonymous network namespace.

The parent performs no network commands. Before any fixture mutation, the
child verifies a different namespace inode and a completely empty network.
"""
import base64
import itertools
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from admin import helper


def isolated(parent_namespace):
    assert os.geteuid() == 0
    assert os.stat('/proc/self/ns/net').st_ino != parent_namespace, 'refuse default namespace'

    def run(argv, *, data=None):
        result = subprocess.run(argv, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5, check=False)
        assert result.returncode == 0, 'isolated fixture command failed (output suppressed)'
        return result.stdout

    assert [link['ifname'] for link in json.loads(run(('/usr/sbin/ip', '-j', 'link', 'show')))] == ['lo']
    assert json.loads(run(('/usr/sbin/ip', '-j', '-4', 'route', 'show', 'table', 'all'))) == []
    with tempfile.TemporaryDirectory(prefix='admin-repair-netns-') as directory:
        root = Path(directory)
        def file(relative, text):
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding='ascii')
            target.chmod(0o600)
            return target
        file('etc/warp-egress-gateway/warp-gateway.env',
             'UPLINK_IF="ens33"\nTRANSIT_IF="ens35"\nWARP_IF="wg-egress"\n'
             'ROUTING_TABLE_ID="4242"\nROUTING_TABLE_NAME="warp_gateway"\n'
             'SOURCE_RULE_PRIORITY="100"\nINGRESS_RULE_PRIORITY="110"\n')
        file('etc/warp-egress-dashboard/dashboard.env', 'DASHBOARD_LISTEN=172.20.31.5\nDASHBOARD_PORT=8787\n')
        file('etc/warp-egress-admin-console/network.json',
             '{"address":"172.20.31.5","uplink_if":"ens33","transit_if":"ens35"}')
        lock = file('run/warp-egress-gateway/admin-mutation.lock', '')
        lock.parent.chmod(0o700)
        for name, kind, address in (('ens33', 'dummy', '172.20.31.5/24'),
                                    ('ens35', 'dummy', '10.1.1.222/30'),
                                    ('wg-egress', 'wireguard', '172.16.0.2/32')):
            run(('/usr/sbin/ip', 'link', 'add', name, 'type', kind))
            run(('/usr/sbin/ip', 'address', 'add', address, 'dev', name))
            run(('/usr/sbin/ip', 'link', 'set', name, 'up'))
        # Ephemeral synthetic key in this disposable fixture, never output.
        key = file('synthetic-wg-key', base64.b64encode(b'k' * 32).decode() + '\n')
        peer = base64.b64encode(b'q' * 32).decode()
        run(('/usr/bin/wg', 'set', 'wg-egress', 'private-key', str(key), 'peer', peer,
             'endpoint', '192.0.2.1:2408', 'allowed-ips', '0.0.0.0/0'))
        run(('/usr/sbin/ip', 'route', 'add', 'default', 'via', '172.20.31.254', 'dev', 'ens33'))
        run(('/usr/sbin/ip', 'route', 'add', '198.51.100.0/24', 'dev', 'ens35', 'table', '200'))
        run(('/usr/sbin/nft', '-f', '-'), data=b'''table inet warp_gateway {
 chain forward {
  type filter hook forward priority 0; policy accept;
  iifname "ens35" oifname != "wg-egress" counter drop comment "WARP_KILL_SWITCH"
 }
}
''')
        transaction = helper.RoutingRepair(root=root)
        request = dict(protocol=1, operation='repair-routing', request_id='123e4567-e89b-42d3-a456-426614174000')
        result = transaction.run(request, version='0.5.1')
        assert result['result_code'] == 'ok' and result['changed'] is True, result['result_code']
        result = transaction.run(request, version='0.5.1')
        assert result['result_code'] == 'ok' and result['changed'] is False, result['result_code']
        for count in (1, 2, 3):
            for missing in itertools.combinations((100, 110, 'default'), count):
                for item in missing:
                    if item == 'default': run(('/usr/sbin/ip', 'route', 'del', 'default', 'table', '4242'))
                    else: run(('/usr/sbin/ip', 'rule', 'del', 'pref', str(item)))
                result = transaction.run(request, version='0.5.1')
                assert result['result_code'] == 'ok' and result['changed'] is True, result['result_code']
        run(('/usr/sbin/ip', 'rule', 'add', 'pref', '100', 'from', '192.0.2.2', 'table', '4242'))
        before = run(('/usr/sbin/ip', '-j', '-4', 'rule', 'show'))
        assert transaction.run(request)['result_code'] == 'unsafe_precondition'
        assert run(('/usr/sbin/ip', '-j', '-4', 'rule', 'show')) == before
        assert lock.stat().st_mode & 0o777 == 0o600
    print('PASS real isolated-network-namespace repair: all missing combinations, no-op, ambiguity, immutable snapshots')


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--isolated':
        isolated(int(sys.argv[2]))
        return
    assert len(sys.argv) == 1
    missing = [tool for tool in ('unshare', 'ip', 'wg', 'nft') if not shutil.which(tool)]
    if missing:
        if os.environ.get('GITHUB_ACTIONS') == 'true': raise RuntimeError('required CI namespace tools missing')
        print('SKIP real namespace repair: missing local tools ' + ', '.join(missing))
        return
    command = ['unshare', '--net', '--', sys.executable, '-B', str(Path(__file__).resolve()),
               '--isolated', str(os.stat('/proc/self/ns/net').st_ino)]
    if os.geteuid() != 0: command = ['sudo', '-n', '--', *command]
    result = subprocess.run(command, timeout=90, check=False)
    if result.returncode != 0: raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
