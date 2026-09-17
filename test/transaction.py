import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('recover', Path(__file__).resolve().parents[1] / 'recover-install.py')
recover = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recover)


class TransactionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.stage = self.root / 'stage'
        self.stage.mkdir()
        self.calls = []
        self.failed = False
        self.fail_restart = False
        self.rules = ['-A INPUT -p tcp --dport 2022 -j ACCEPT']
        self.before = {}
        for name, (relative, mode) in recover.FILES.items():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('#!/bin/sh\n# old ' + name + '\n')
            path.chmod(mode)
            self.before[name] = recover.snapshot(path)
            (self.stage/name).write_text('#!/bin/sh\n# new ' + name + '\n')
        self.tx = recover.Transaction(self.root, self.command)

    def command(self, args, allowed=(0,)):
        self.calls.append(args)
        if args[:2] == ['systemctl', 'is-active']: return 'active'
        if args[:2] == ['systemctl', 'is-enabled']: return 'enabled'
        if args[:2] == ['systemctl', 'restart']:
            if self.fail_restart and not self.failed:
                self.failed = True
                self.rules.append('-A OUTPUT -o end1 -p udp --dport 5353 -j ACCEPT -m comment --comment '+recover.OWNER)
                raise RuntimeError('injected startup failure')
        if args[0] == 'ip6tables':
            if '-S' in args: return '\n'.join(self.rules)
            if '-D' in args:
                rule = '-A ' + ' '.join(args[args.index('-D')+1:])
                self.rules.remove(rule)
        return ''

    def assert_restored(self):
        for name, (relative, _) in recover.FILES.items():
            self.assertEqual(recover.snapshot(self.root/relative), self.before[name])

    def test_success_commit_and_explicit_rollback(self):
        self.tx.apply(self.stage)
        self.assertEqual(self.tx.load()['state'], 'pending')
        self.tx.commit()
        self.tx.rollback()
        self.assert_restored()
        self.assertEqual(self.tx.load()['state'], 'rolled_back')

    def test_service_failure_restores_files_and_only_new_owned_rules(self):
        old_owned = '-A INPUT -i end1 -p ipv6-icmp -j ACCEPT -m comment --comment '+recover.OWNER
        self.rules.append(old_owned)
        before = self.rules[:]
        self.fail_restart = True
        with self.assertRaisesRegex(RuntimeError, 'startup failure'):
            self.tx.apply(self.stage)
        self.assert_restored()
        self.assertEqual(self.rules, before)

    def test_failure_during_second_file_replacement(self):
        original = recover.atomic
        fired = False
        target = self.root / recover.FILES['cue-matter-ipv6-wait-nic'][0]
        def fault(path, data, mode):
            nonlocal fired
            if path == target and not fired:
                fired = True
                raise OSError('injected disk error')
            return original(path, data, mode)
        with patch.object(recover, 'atomic', fault):
            with self.assertRaises(OSError): self.tx.apply(self.stage)
        self.assert_restored()

    def test_independent_edit_refuses_rollback_before_any_command(self):
        self.tx.apply(self.stage)
        path = self.root / recover.FILES['defaults'][0]
        path.write_text('operator change\n')
        self.calls.clear()
        with self.assertRaisesRegex(RuntimeError, 'independent change'):
            self.tx.rollback()
        self.assertEqual(self.calls, [])
        self.assertEqual(path.read_text(), 'operator change\n')

    def test_interrupted_pending_requires_recovery(self):
        self.tx.apply(self.stage)
        with self.assertRaisesRegex(RuntimeError, 'unfinished'):
            self.tx.apply(self.stage)
        recover.Transaction(self.root, self.command).rollback()
        self.assert_restored()

    def test_process_death_after_first_replacement_is_recoverable(self):
        code = '''
import importlib.util,os,sys
from pathlib import Path
s=importlib.util.spec_from_file_location('recover',sys.argv[1])
m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
root=Path(sys.argv[2]);original=m.atomic
def crash(path,data,mode):
    original(path,data,mode)
    if path==root/m.FILES['cue-matter-ipv6-rules'][0]: os._exit(77)
def command(args,allowed=(0,)):
    if args[:2]==['systemctl','is-active']: return 'active'
    if args[:2]==['systemctl','is-enabled']: return 'enabled'
    return ''
m.atomic=crash
m.Transaction(root,command).apply(root/'stage')
'''
        result = subprocess.run([sys.executable, '-c', code, str(Path(recover.__file__)), str(self.root)], timeout=5)
        self.assertEqual(result.returncode, 77)
        self.assertEqual(self.tx.load()['state'], 'pending')
        self.tx.rollback()
        self.assert_restored()

    def test_rollback_repeat_has_no_actions(self):
        self.tx.apply(self.stage)
        self.tx.rollback()
        self.calls.clear()
        self.tx.rollback()
        self.assertEqual(self.calls, [])

    def test_repeat_committed_install_preserves_identical_bytes(self):
        self.tx.apply(self.stage)
        self.tx.commit()
        first = {n: recover.snapshot(self.root/p) for n,(p,_) in recover.FILES.items()}
        self.tx.apply(self.stage)
        self.tx.commit()
        self.assertEqual(first, {n: recover.snapshot(self.root/p) for n,(p,_) in recover.FILES.items()})

    def test_empty_stage_does_not_modify_destination(self):
        (self.stage/'defaults').write_text('')
        with self.assertRaisesRegex(RuntimeError, 'empty'): self.tx.apply(self.stage)
        self.assert_restored()
        self.assertFalse(self.tx.journal.exists())

    def test_symlink_destination_refused(self):
        path = self.root / recover.FILES['defaults'][0]
        path.unlink()
        path.symlink_to(self.stage/'defaults')
        with self.assertRaisesRegex(RuntimeError, 'symlink'): self.tx.apply(self.stage)
        self.assertFalse(self.tx.journal.exists())

    def test_new_install_rollback_removes_only_created_files(self):
        for relative, _ in recover.FILES.values(): (self.root/relative).unlink()
        original = self.command
        def cold(args, allowed=(0,)):
            if args[:2]==['systemctl','is-active']: return 'inactive'
            if args[:2]==['systemctl','is-enabled']: return 'not-found'
            return original(args, allowed)
        self.tx.command = cold
        self.tx.apply(self.stage)
        self.tx.rollback()
        for relative, _ in recover.FILES.values(): self.assertFalse((self.root/relative).exists())


if __name__ == '__main__': unittest.main()
