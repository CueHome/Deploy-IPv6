# Second review — Final-Fix

Date: 17 September 2026. Reviewed baseline: 599a50c248b3e2ef7a80357ed68a1a2e01ff0b66.
Main remained 831e45a55e9c6fd4fbb55e5c24a70023e1bffc02 when checked.

## Release decision

HOLD for production. This review includes executable shell regressions, a passing
Linux network-namespace CI run and saved environment evidence. No current board tests have run.
Local Docker points at Colima, whose daemon socket is absent. Do not count the
simulated Linux-command tests as kernel, systemd, controller or HA qualification.
The separate namespace test provides limited kernel evidence, not field qualification.

## Environment evidence

Saved 8–9 September snapshots show ARM64 Rockchip hardware, host-networked Matter
containers and operational port 5540. QA1's recorded kernel was
5.10.160-rockchip-rk356x; HA and another mDNS responder were present alongside the
bridge. The recorded NetworkManager IPv6 methods differed: QA1 auto, QA2 manual.
These are historical observations, not current inventory. Board names alone do
not establish support for a distribution, network manager or firewall backend.

Source evidence read locally: `artifacts/qa1-local-build-2026-09-09/preflight-output.txt`,
`artifacts/qa2-production-d777d95-status.md`, and
`artifacts/ipv6-fix2-audit-2026-09-08/report-source.md` in the parent workspace.
Raw evidence includes private network information and is intentionally not copied here.

## What changed and why

Each numbered entry describes a concrete failure mode. Entries 1–6 were first
fixed in the preceding package; the others were addressed or qualified in this pass.

1. Missing option values caused opaque shell errors: reject them with a useful message.
2. SKU separators/control characters reached root-written filenames: restrict characters and length.
3. Unbounded wait input risked integer errors or excessive delays: accept only 1–300 seconds.
4. Baseline with module loading mutated the kernel: reject that option combination early.
5. Download verification could be bypassed: reject bypass and retain a commit-pinned payload.
6. Reinstalling an active oneshot did not execute updated configuration: explicitly restart the host rules unit.
7. Signal cleanup could return and continue work: INT/TERM now exit with conventional failure codes.
8. Timestamp-only filenames could collide: create unique, private log/evidence files.
9. Wrapper directory locks could survive process death: replace with an advisory descriptor lock and a 10-second acquisition bound.
10. Concurrent direct installs could overwrite each other: serialize installers with a separate descriptor lock.
11. Concurrent rules helpers could duplicate check-then-insert operations: serialize the helper with its own descriptor lock.
12. Firewall lock waits were unlimited: cap each check/insert at five seconds. A helper failure stays nonzero.
13. Missing runtime NIC configuration silently selected end1: refuse a missing pin.
14. Leading-dash, dot and overlong interface names could reach tools: validate the installer and generated helpers.
15. A NIC such as vlan.10 was interpreted as a regex and matched vlanX10: count/show exact interface tokens.
16. Existence alone was reported as readiness: require carrier, multicast and a link-local address without tentative/dadfailed flags.
17. Invalid runtime wait overrides silently fell back: reject them explicitly.
18. Module loading preceded fleet/NIC checks: move it after identity checks and add confirmation unless --yes. Persistent module configuration is deferred to installation.
19. Hosts without systemd could reach installation: check the running manager before installing service files.
20. Service lock directories disappear across boot and service starts could exceed implicit deadlines: declare a preserved runtime directory and an explicit 450-second start deadline. The deadline allows the configured NIC wait plus bounded rule commands; it is not a connectivity SLA.

## Verification

- `sh test/preflight.sh`: syntax plus 11 early rejection cases pass.
- `python3 test/runtime.py`: 11 tests execute generated shell helpers using simulated Linux commands. Tests cover duplicate application, missing/invalid NIC pins, lock failure, insertion failure, carrier, DAD, bounded waits and literal VLAN matching.
- `TEST_REVISION=599a50c python3 test/runtime.py -k tentative`: fails as expected; the old helper incorrectly returns success. The same test passes on the candidate.
- `git diff --check`: passes.
- [CI run 35177460447](https://github.com/CueHome/Deploy-IPv6/actions/runs/35177460447)
  passed on exact source/delivery commit `54a64c56cbdfc864b603e013bdeef69996ac6840`.
  In addition to both test programs, `sudo sh test/linux-netns.sh` passed using
  real Linux iptables and interfaces in an isolated namespace: repeat application
  was identical, an unrelated SSH rule survived, and carrier loss failed readiness.
  This does not verify systemd, production kernels, nft/legacy coexistence or controller traffic.

The locks' real Linux cross-process behavior, service restart propagation, the
new manager gate and module persistence are source-reviewed but need Linux
integration coverage. An abrupt SIGKILL can still interrupt file/rule updates.

## Remaining release blockers

- Failure-atomic installer and ownership-aware rollback are not implemented.
- Broad legacy firewall rules remain. Introduce owned chains and narrower flow
  policy only with mDNS unicast/multicast and bidirectional CASE qualification.
- There is no automatic firewall reload reconciliation or supported OS profile
  implementation yet. Do not claim the OS cannot override these rules.
- Mixed nft/legacy enforcement needs explicit classification and tests.
- Hardware/OS matrix for all intended two to five configurations is missing.
- Reboot, firewall reload, carrier loss, interface recreation, HA coexistence,
  independent discovery/CASE/subscription and three-hour soak are unperformed.

Use `python3 tools/inventory.py` on each target for a bounded read-only snapshot.
Keep its output private. Select the persistence adapter from that evidence;
do not indiscriminately enable IPv6, replace network profiles, change Docker
ordering or flush host firewall state. This branch must remain unmerged until
these blockers are closed with evidence.
