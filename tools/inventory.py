#!/usr/bin/env python3
"""Read-only Linux inventory. Prints JSON; never writes files or reads tokens.

Run with Python 3 on each intended host. Output includes network addresses and
must be retained privately, not committed to the public repository.
"""
import json
import platform
import shutil
import subprocess
from pathlib import Path


def read(path):
    try:
        return Path(path).read_text().replace('\x00', ' ').strip()
    except (OSError, UnicodeError) as exc:
        return {'unavailable': type(exc).__name__}


def probe(argv):
    if not shutil.which(argv[0]):
        return {'unavailable': argv[0]}
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=3)
        return {'rc': result.returncode, 'stdout': result.stdout[:24000],
                'stderr': result.stderr[:2000], 'truncated': len(result.stdout) > 24000}
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {'unavailable': type(exc).__name__}


def inventory():
    commands = {
        'links': ['ip', '-j', 'link', 'show'],
        'addresses': ['ip', '-j', '-6', 'addr', 'show'],
        'routes': ['ip', '-j', '-6', 'route', 'show', 'table', 'all'],
        'ipv4_routes': ['ip', '-j', '-4', 'route', 'show', 'default'],
        'firewall_version': ['ip6tables', '-V'],
        'firewall': ['ip6tables', '-w', '1', '-S'],
        'legacy_firewall': ['ip6tables-legacy', '-w', '1', '-S'],
        'nft_firewall': ['nft', '-j', 'list', 'ruleset'],
        'network_manager': ['nmcli', '-t', '-f', 'NAME,TYPE,DEVICE', 'connection', 'show', '--active'],
        'network_services': ['systemctl', 'is-active', 'NetworkManager', 'systemd-networkd', 'ufw', 'docker'],
        'rules_unit': ['systemctl', 'cat', 'cue-matter-ipv6-rules.service'],
        'ipv6_sockets': ['ss', '-6', '-lun'],
        'containers': ['docker', 'ps', '--format', '{{.Names}} {{.Status}}'],
    }
    return {
        'scope': 'Read-only snapshot; not commissioning, recovery or compliance proof',
        'kernel': platform.release(), 'architecture': platform.machine(),
        'os_release': read('/etc/os-release'), 'board': read('/proc/device-tree/model'),
        'pid1': read('/proc/1/comm'), 'boot_id': read('/proc/sys/kernel/random/boot_id'),
        'ipv6_disabled_all': read('/proc/sys/net/ipv6/conf/all/disable_ipv6'),
        'ipv6_disabled_default': read('/proc/sys/net/ipv6/conf/default/disable_ipv6'),
        'probes': {key: probe(argv) for key, argv in commands.items()},
    }


if __name__ == '__main__':
    print(json.dumps(inventory(), indent=2))
