#!/usr/bin/env python3
"""Journalled host-file installation. No container or Matter storage operations."""
import argparse
import base64
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import tempfile
import time

UNIT = 'cue-matter-ipv6-rules.service'
OWNER = 'cue-matter-ipv6-v1'
FILES = {
    'cue-matter-ipv6-rules': ('usr/local/sbin/cue-matter-ipv6-rules', 0o755),
    'cue-matter-ipv6-wait-nic': ('usr/local/sbin/cue-matter-ipv6-wait-nic', 0o755),
    'unit': ('etc/systemd/system/' + UNIT, 0o644),
    'defaults': ('etc/default/cue-matter-ipv6-rules', 0o644),
    'modules': ('etc/modules-load.d/cue-matter-ipv6.conf', 0o644),
}


@contextmanager
def rules_lock(root):
    path = root / 'run/cue-matter-ipv6/rules.lock'
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with path.open('a') as handle:
        deadline = time.monotonic() + 10
        while True:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise RuntimeError('rules lock timeout during rollback')
                time.sleep(.1)
        yield


def run(args, allowed=(0,)):
    result = subprocess.run(args, capture_output=True, text=True, timeout=470)
    if result.returncode not in allowed:
        raise RuntimeError('command failed: ' + ' '.join(args) + ': ' + result.stderr[:1000])
    return result.stdout.strip()


def atomic(path, data, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.cue-stage-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def snapshot(path):
    if path.is_symlink():
        raise RuntimeError('refusing symlink: ' + str(path))
    if not path.exists():
        return None
    if not path.is_file():
        raise RuntimeError('not a regular file: ' + str(path))
    info = path.stat()
    if info.st_uid != os.geteuid() or info.st_gid != os.getegid():
        raise RuntimeError('unexpected file owner: ' + str(path))
    return {'data': base64.b64encode(path.read_bytes()).decode(),
            'mode': stat.S_IMODE(info.st_mode)}


class Transaction:
    def __init__(self, root=Path('/'), command=run):
        self.root = root
        self.command = command
        self.journal = root / 'var/lib/cue-matter-ipv6/transaction.json'

    def save(self, record):
        atomic(self.journal, json.dumps(record, sort_keys=True).encode(), 0o600)

    def load(self):
        return json.loads(self.journal.read_text())

    def owned_rules(self):
        rules = self.command(['ip6tables', '-w', '5', '-S']).splitlines()
        result = []
        for line in rules:
            tokens = shlex.split(line)
            if '--comment' in tokens and tokens[tokens.index('--comment') + 1] == OWNER:
                if tokens[:1] == ['-A'] and tokens[1] in ('INPUT', 'OUTPUT'):
                    result.append(tokens)
        return result

    def apply(self, stage):
        if self.journal.exists() and self.load()['state'] not in ('committed', 'rolled_back'):
            raise RuntimeError('unfinished transaction: run rollback before installing again')
        entries = {}
        for name, (relative, mode) in FILES.items():
            source = stage / name
            if name == 'modules' and not source.exists():
                continue
            data = source.read_bytes()
            if not data:
                raise RuntimeError('empty staged file: ' + name)
            if name.startswith('cue-matter-'):
                self.command(['sh', '-n', str(source)])
            entries[name] = {'old': snapshot(self.root / relative),
                             'new': {'data': base64.b64encode(data).decode(), 'mode': mode}}
        active = self.command(['systemctl', 'is-active', UNIT], (0, 3, 4))
        enabled = self.command(['systemctl', 'is-enabled', UNIT], (0, 1, 4))
        if active not in ('active', 'inactive', 'failed', 'unknown') or enabled not in ('enabled', 'disabled', 'not-found', ''):
            raise RuntimeError('unsupported prior unit state: ' + active + '/' + enabled)
        record = {'state': 'pending', 'files': entries, 'active': active,
                  'enabled': enabled, 'rules_before': self.owned_rules()}
        # Durable journal precedes every replacement. One retained rollback generation.
        self.save(record)
        try:
            for name, entry in entries.items():
                relative, mode = FILES[name]
                atomic(self.root / relative, base64.b64decode(entry['new']['data']), mode)
            self.command(['systemctl', 'daemon-reload'])
            self.command(['systemctl', 'enable', UNIT])
            self.command(['systemctl', 'restart', UNIT])
        except Exception:
            self.rollback()
            raise

    def commit(self):
        record = self.load()
        if record['state'] != 'pending':
            raise RuntimeError('no pending transaction to commit')
        record['state'] = 'committed'
        self.save(record)

    def rollback(self):
        record = self.load()
        if record['state'] == 'rolled_back':
            return
        # Validate all drift before making any changes, including retry after interruption.
        for name, entry in record['files'].items():
            current = snapshot(self.root / FILES[name][0])
            if current != entry['old'] and current != entry['new']:
                raise RuntimeError('rollback refused: independent change to ' + name)
        record['state'] = 'rolling_back'
        self.save(record)
        self.command(['systemctl', 'stop', UNIT], (0, 5))
        if record['enabled'] != 'enabled':
            self.command(['systemctl', 'disable', UNIT], (0, 1))
        with rules_lock(self.root):
            before = record['rules_before'][:]
            for rule in self.owned_rules():
                if rule in before:
                    before.remove(rule)
                else:
                    self.command(['ip6tables', '-w', '5', '-D'] + rule[1:])
        for name, entry in record['files'].items():
            path = self.root / FILES[name][0]
            old = entry['old']
            if old is None:
                path.unlink(missing_ok=True)
                if path.parent.exists():
                    directory = os.open(path.parent, os.O_RDONLY)
                    try:
                        os.fsync(directory)
                    finally:
                        os.close(directory)
            else:
                atomic(path, base64.b64decode(old['data']), old['mode'])
        self.command(['systemctl', 'daemon-reload'])
        if record['enabled'] == 'enabled':
            self.command(['systemctl', 'enable', UNIT])
        if record['active'] == 'active':
            self.command(['systemctl', 'restart', UNIT])
        record['state'] = 'rolled_back'
        self.save(record)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('apply', 'commit', 'rollback'))
    parser.add_argument('--stage', type=Path)
    parser.add_argument('--inherited-lock', type=int)
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise RuntimeError('run as root')
    lockpath = Path('/run/cue-matter-ipv6/install.lock')
    lockpath.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = args.inherited_lock
    if fd is None:
        fd = os.open(lockpath, os.O_CREAT | os.O_RDWR, 0o600)
    elif os.fstat(fd).st_ino != lockpath.stat().st_ino or os.fstat(fd).st_dev != lockpath.stat().st_dev:
        raise RuntimeError('inherited lock is not the installer lock')
    deadline = time.monotonic() + 10
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise RuntimeError('installer lock timeout')
            time.sleep(.1)
    transaction = Transaction()
    if args.action == 'apply':
        if args.stage is None:
            raise RuntimeError('--stage is required')
        transaction.apply(args.stage)
    elif args.action == 'commit':
        transaction.commit()
    else:
        transaction.rollback()


if __name__ == '__main__':
    main()
