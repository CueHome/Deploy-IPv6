#!/usr/bin/env python3
"""Explicit Linux provisioning step; never operates on containers, HA, or MQTT.

Install a persistent, ordered IPv6 policy before running deploy-phase1.sh.
Run --check first. --apply is an explicit host mutation; repository tests never apply it.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile

POLICY = '/etc/cue-matter-ipv6.conf'
UNIT = 'cue-matter-ipv6-policy.service'


def render(nic):
    if not re.fullmatch(r'[a-zA-Z0-9_-]{1,15}', nic) or nic == 'lo':
        raise ValueError('Specify the physical LAN interface; unsafe/ambiguous interface name')
    policy = ''.join(f'net.ipv6.conf.{name}.disable_ipv6 = 0\n'
                     for name in ('all', 'default', 'lo'))
    # The NIC may not yet have its udev name at boot; default=0 covers its later creation.
    policy += f'-net.ipv6.conf.{nic}.disable_ipv6 = 0\n'
    unit = f'''[Unit]
Description=Persistent Cue Matter IPv6 policy
After=systemd-sysctl.service
Before=NetworkManager.service networking.service docker.service cue-matter-ipv6-rules.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/sysctl -p {POLICY}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
'''
    return policy, unit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--nic', required=True)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--check', action='store_true')
    group.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    policy, unit = render(args.nic)
    if 'ipv6.disable=1' in Path('/proc/cmdline').read_text().split():
        raise RuntimeError('Kernel IPv6 is disabled; boot argument remediation and reboot required')
    names = ('all', 'default', 'lo', args.nic)
    paths = [Path('/proc/sys/net/ipv6/conf') / name / 'disable_ipv6' for name in names]
    before = [path.read_text().strip() for path in paths]
    print(dict(zip(names, before)))
    if args.check:
        if any(value != '0' for value in before):
            raise SystemExit('IPv6 policy is inconsistent; explicit provisioning required')
        return
    if os.geteuid() != 0:
        raise RuntimeError('Apply requires root')
    # Refuse to overwrite existing management policy; repeated identical installs are safe.
    targets = {Path(POLICY): policy, Path('/etc/systemd/system') / UNIT: unit}
    for path, value in targets.items():
        if path.exists() and path.read_text() != value:
            raise RuntimeError(f'Existing policy differs: {path}; review before replacing')
    backup = Path(tempfile.mkdtemp(prefix='cue-ipv6-policy-', dir='/var/tmp'))
    (backup / 'previous-values.txt').write_text(str(dict(zip(names, before))) + '\n')
    for path, value in targets.items():
        fd, temp = tempfile.mkstemp(dir=path.parent, prefix='.cue-ipv6-')
        with os.fdopen(fd, 'w') as stream:
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp, 0o644)
        os.replace(temp, path)
    subprocess.run(['systemctl', 'daemon-reload'], check=True)
    subprocess.run(['systemctl', 'enable', UNIT], check=True)
    subprocess.run(['systemctl', 'restart', UNIT], check=True)
    if any(path.read_text().strip() != '0' for path in paths):
        raise RuntimeError(f'Policy did not apply; retained evidence: {backup}')
    print(f'Policy applied; prior values retained in {backup}. Run phase1 and reboot qualification.')


if __name__ == '__main__':
    main()
