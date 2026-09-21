import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import subprocess

spec = importlib.util.spec_from_file_location('policy', Path(__file__).resolve().parents[1] / 'provision-ipv6.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)

class PolicyTests(unittest.TestCase):
    def test_order_and_late_nic(self):
        config, unit = policy.render('end1')
        for name in ('all', 'default', 'lo'):
            self.assertIn(f'net.ipv6.conf.{name}.disable_ipv6 = 0', config)
        self.assertIn('-net.ipv6.conf.end1.disable_ipv6 = 0', config)
        self.assertIn('After=systemd-sysctl.service', unit)
        self.assertIn('Before=NetworkManager.service networking.service docker.service', unit)

    def test_reject_injection_and_loopback(self):
        for nic in ('lo', '../end1', 'end1\nExecStart=evil', '', 'a' * 16):
            with self.assertRaises(ValueError): policy.render(nic)

    def test_conflict_blocks_apply_before_host_reads_or_writes(self):
        with patch('sys.argv', ['provision-ipv6.py', '--nic', 'end1', '--apply']), \
             patch.object(policy.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'check-policy')) as run, \
             patch.object(Path, 'read_text') as read, \
             patch.object(policy.os, 'replace') as replace:
            with self.assertRaises(subprocess.CalledProcessError): policy.main()
            self.assertEqual(run.call_count, 1)
            self.assertEqual(run.call_args.args[0][-3:], ['check-policy', '--nic', 'end1'])
            read.assert_not_called()
            replace.assert_not_called()

if __name__ == '__main__': unittest.main()
