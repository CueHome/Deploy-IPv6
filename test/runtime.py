"""Execute generated shell helpers using simulated Linux commands.

Only the /run lock path is redirected to a temporary directory. No firewall or
service operations run on the host. This is shell behavior, not kernel proof.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'cue-matter-ipv6-changes.sh').read_text()
if os.environ.get('TEST_REVISION'):
    SOURCE = subprocess.check_output(
        ['git', 'show', os.environ['TEST_REVISION'] + ':cue-matter-ipv6-changes.sh'], text=True)
MOCK = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name=Path(sys.argv[0]).name
args=sys.argv[1:]
root=Path(os.environ['FIXTURE'])
with (root/'calls').open('a') as f: f.write(json.dumps([name]+args)+'\\n')
if name=='flock': sys.exit(1 if os.environ.get('LOCK_FAIL') else 0)
if name=='sleep': sys.exit(0)
if name=='ip':
    if os.environ.get('NIC_MISSING'): sys.exit(1)
    if 'addr' in args:
        print('2: end1 inet6 fe80::123/64 scope link '+os.environ.get('ADDRESS_FLAGS',''))
    else:
        print('2: end1: <UP,MULTICAST'+('' if os.environ.get('NO_CARRIER') else ',LOWER_UP')+'>')
    sys.exit(0)
if name=='ip6tables':
    assert args[:2]==['-w','5'], args
    args=args[2:]
    state=root/'rules.json'
    rules=json.loads(state.read_text()) if state.exists() else []
    op,chain=args[:2]
    rule=[chain]+(args[3:] if op=='-I' else args[2:])
    if op=='-C': sys.exit(0 if rule in rules else 1)
    if op=='-I':
        if os.environ.get('INSERT_FAIL'): sys.exit(1)
        rules.append(rule);state.write_text(json.dumps(rules));sys.exit(0)
sys.exit(2)
'''


class Runtime(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, FIXTURE=str(self.root), CUE_LAN_NIC='end1', CUE_NIC_WAIT='2')
        self.env['PATH'] = str(self.root) + os.pathsep + os.environ['PATH']
        for name in ('ip', 'ip6tables', 'flock', 'sleep'):
            path = self.root / name
            path.write_text(MOCK)
            path.chmod(0o755)

    def run_helper(self, marker, **env):
        body = SOURCE.split("<<'" + marker + "'\n", 1)[1].split('\n'+marker, 1)[0]
        body = body.replace('/run/cue-matter-ipv6/rules.lock', str(self.root/'rules.lock'))
        return subprocess.run(['sh', '-c', body], env=dict(self.env, **env),
                              capture_output=True, text=True, timeout=5)

    def calls(self):
        path = self.root/'calls'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_repeat_application_is_idempotent(self):
        for _ in range(2):
            self.assertEqual(self.run_helper('RULES_EOF').returncode, 0)
        self.assertEqual(len(json.loads((self.root/'rules.json').read_text())), 10)
        self.assertFalse(any('-F' in call or '-P' in call for call in self.calls()))

    def test_missing_pin_never_guesses_end1(self):
        self.assertNotEqual(self.run_helper('RULES_EOF', CUE_LAN_NIC='').returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_invalid_helper_nic(self):
        for nic in ('../x', '-bad', 'abcdefghijklmnop', '.'):
            self.assertNotEqual(self.run_helper('RULES_EOF', CUE_LAN_NIC=nic).returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_lock_failure_never_changes_rules(self):
        self.assertNotEqual(self.run_helper('RULES_EOF', LOCK_FAIL='1').returncode, 0)
        self.assertFalse(any(c[0]=='ip6tables' for c in self.calls()))

    def test_rule_insert_failure_is_not_success(self):
        self.assertNotEqual(self.run_helper('RULES_EOF', INSERT_FAIL='1').returncode, 0)

    def test_ready_interface(self):
        self.assertEqual(self.run_helper('WAIT_EOF').returncode, 0)

    def test_tentative_and_failed_dad_never_ready(self):
        for flags in ('tentative', 'dadfailed'):
            self.assertNotEqual(self.run_helper('WAIT_EOF', ADDRESS_FLAGS=flags).returncode, 0)

    def test_missing_carrier_never_ready(self):
        self.assertNotEqual(self.run_helper('WAIT_EOF', NO_CARRIER='1').returncode, 0)

    def test_missing_interface_wait_is_bounded(self):
        self.assertNotEqual(self.run_helper('WAIT_EOF', NIC_MISSING='1').returncode, 0)
        self.assertEqual(sum(c[0]=='sleep' for c in self.calls()), 2)

    def test_invalid_wait_override_rejected(self):
        for value in ('0', '301', '99999999999999999999999', 'a'):
            self.assertNotEqual(self.run_helper('WAIT_EOF', CUE_NIC_WAIT=value).returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_vlan_rule_count_uses_literal_interface(self):
        body = SOURCE.split('count_nic_rules() {\n', 1)[1].split('\n}', 1)[0]
        # Execute the actual function body with a shell function as its input.
        script = '''ip6tables() {
            printf '%s\\n' '-A INPUT -i vlan.10 -j ACCEPT' '-A INPUT -i vlanX10 -j ACCEPT'
        }
        NIC=vlan.10
        ''' + body
        result = subprocess.run(['sh', '-c', script], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), '1')


if __name__ == '__main__':
    unittest.main()
