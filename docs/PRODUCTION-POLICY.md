# IPv6 production policy

The production test host had `all.disable_ipv6=1` and `default.disable_ipv6=1`, while NetworkManager
had enabled IPv6 on end1. A successful send in that state did not demonstrate persistent provisioning.

The rules installer now refuses installation with inconsistent global/default values. Baseline mode
remains diagnostic (it writes logs and sends a probe). An explicit separate provisioning step is supplied:

    sudo python3 provision-ipv6.py --nic end1 --check
    sudo python3 provision-ipv6.py --nic end1 --apply

Apply installs `cue-matter-ipv6-policy.service`, ordered after systemd-sysctl and before networking
and Docker, plus `/etc/cue-matter-ipv6.conf`. It enables all/default/loopback and the selected LAN NIC.
The NIC key tolerates a late udev rename at boot; default=0 covers subsequently created interfaces.
The existing rules service still waits for carrier and a usable link-local address.

This is an explicit host-wide IPv6 enablement policy. It does not rewrite administrator sysctl files,
change firewall policy, restart containers, or operate on MQTT/HA. Before checking or applying policy,
it rejects persistent disable directives targeting all/default/loopback/the selected NIC, with file
and line evidence. Administrators must reconcile those settings explicitly; the tool does not
silently compete with them at boot. The scan respects same-basename sysctl.d priority and /dev/null
masks, and is intentionally conservative about distinct-file overrides. Later manual writes or
external managers can still disable IPv6; this is not an enforcement daemon.
It refuses kernel `ipv6.disable=1`, unsafe interface names, and different existing policy files.
Prior runtime values are retained under /var/tmp/cue-ipv6-policy-*. Failed installs retain evidence
and do not automatically disable IPv6 again, since that could remove live IPv6 addresses.

After provisioning, run the existing Phase 1 installer and verify a reboot on a Linux test host.
Pass the same NIC as CUE_LAN_NIC to the Matter production Compose example. This repository does not
edit an external container deployment generator.

Tests: `python3 test/provision.py`, `sh test/preflight.sh`, `python3 test/transaction.py`,
`python3 test/runtime.py`. The new policy rendering is unit-tested; real systemd ordering, network
namespace and reboot qualification remain required before rollout. No test device was changed.
