#!/bin/sh
# Linux CI only. All network/firewall operations run in our temporary namespace.
set -eu
cd "$(dirname "$0")/.."
[ "$(id -u)" = 0 ] || { echo 'Run as root on a disposable Linux test host'; exit 1; }
for tool in ip ip6tables flock python3; do command -v "$tool" >/dev/null; done
tmp=$(mktemp -d)
ns="cue-ipv6-test-$$"
created=0
cleanup() {
    if [ "$created" = 1 ]; then ip netns del "$ns"; fi
    rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ip netns add "$ns"
created=1
ip -n "$ns" link add end1 type veth peer name peer1
ip -n "$ns" link set end1 up
ip -n "$ns" link set peer1 up
ip -n "$ns" -6 addr add fe80::123/64 dev end1 nodad
python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
source=Path('cue-matter-ipv6-changes.sh').read_text()
for marker, name in [('RULES_EOF','rules'),('WAIT_EOF','wait')]:
    body=source.split("<<'"+marker+"'\n",1)[1].split('\n'+marker,1)[0]
    body=body.replace('/run/cue-matter-ipv6/rules.lock',str(root/'rules.lock'))
    (root/name).write_text(body)
PY
ip netns exec "$ns" ip6tables -A INPUT -p tcp --dport 2022 -j ACCEPT
ip netns exec "$ns" env CUE_LAN_NIC=end1 CUE_NIC_WAIT=5 sh "$tmp/wait"
ip netns exec "$ns" env CUE_LAN_NIC=end1 sh "$tmp/rules"
ip netns exec "$ns" ip6tables -S > "$tmp/first"
ip netns exec "$ns" env CUE_LAN_NIC=end1 sh "$tmp/rules"
ip netns exec "$ns" ip6tables -S > "$tmp/second"
cmp "$tmp/first" "$tmp/second"
ip netns exec "$ns" ip6tables -C INPUT -p tcp --dport 2022 -j ACCEPT
[ "$(ip netns exec "$ns" ip6tables -S | grep -c '^-A ')" = 11 ]
ip -n "$ns" link set peer1 down
if ip netns exec "$ns" env CUE_LAN_NIC=end1 CUE_NIC_WAIT=1 sh "$tmp/wait"; then
    echo 'FAIL: link without carrier incorrectly ready'; exit 1
fi
echo 'PASS: real Linux rule application, idempotency, unrelated SSH rule preservation and carrier gate'
