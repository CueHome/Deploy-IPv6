"""Real temporary sysctl trees; never loads policy or touches host networking."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('recovery', Path(__file__).resolve().parents[1] / 'recover-install.py')
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class Conflicts(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def put(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data)
        return path

    def check(self, nic='end1'):
        before = {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        result = recovery.persistent_ipv6_conflicts(self.root, nic)
        after = {str(p): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(before, after)
        return result

    def test_qa4_conflict_and_symlink_dedup(self):
        self.put('etc/sysctl.d/99-cuehome-ipv6.conf', 'net.ipv6.conf.end1.disable_ipv6=0\n')
        source = self.put('etc/sysctl.conf', '# original\nnet.ipv6.conf.all.disable_ipv6=1\nnet.ipv6.conf.default.disable_ipv6=1\n')
        (self.root / 'etc/sysctl.d/99-sysctl.conf').symlink_to('../sysctl.conf')
        result = self.check()
        self.assertEqual([x['line'] for x in result], [2, 3])
        self.assertEqual(Path(result[0]['file']).resolve(), source.resolve())

    def test_same_basename_etc_masks_vendor(self):
        self.put('usr/lib/sysctl.d/99-test.conf', 'net.ipv6.conf.all.disable_ipv6=1\n')
        self.put('etc/sysctl.d/99-test.conf', 'net.ipv6.conf.all.disable_ipv6=0\n')
        self.assertEqual(self.check(), [])

    def test_distinct_file_later_enable_does_not_hide_conflict(self):
        self.put('etc/sysctl.d/10-test.conf', 'net.ipv6.conf.all.disable_ipv6=1\n')
        self.put('etc/sysctl.d/99-test.conf', 'net.ipv6.conf.all.disable_ipv6=0\n')
        self.assertEqual(len(self.check()), 1)

    def test_slash_glob_and_optional_assignment(self):
        self.put('etc/sysctl.conf', '-net/ipv6/conf/end*/disable_ipv6 = 1 # disable\nnet.ipv6.conf.lo.disable_ipv6 = 1 ; note\n')
        self.assertEqual(len(self.check()), 2)

    def test_comments_other_interfaces_and_enabled_are_not_conflicts(self):
        self.put('etc/sysctl.conf', '# net.ipv6.conf.all.disable_ipv6=1\nnet.ipv6.conf.wlan0.disable_ipv6=1\nnet.ipv6.conf.end1.disable_ipv6=0\n')
        self.assertEqual(self.check(), [])

    def test_dev_null_mask(self):
        self.put('usr/lib/sysctl.d/99-test.conf', 'net.ipv6.conf.all.disable_ipv6=1\n')
        path = self.root / 'etc/sysctl.d/99-test.conf'
        path.parent.mkdir(parents=True)
        path.symlink_to('/dev/null')
        self.assertEqual(self.check(), [])

    def test_vlan_slash_notation(self):
        self.put('etc/sysctl.conf', 'net/ipv6/conf/eth0.100/disable_ipv6=1\n')
        self.assertEqual(len(self.check('eth0.100')), 1)

    def test_invalid_nic(self):
        with self.assertRaises(ValueError): self.check('../bad')


if __name__ == '__main__': unittest.main()
