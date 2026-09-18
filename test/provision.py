import importlib.util
from pathlib import Path
import unittest

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

if __name__ == '__main__': unittest.main()
