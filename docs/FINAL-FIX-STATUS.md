# Final-Fix implementation checkpoint

Superseded for current progress by [Second review](SECOND-REVIEW.md).
The following records the initial package, not the latest branch status.

Base: 831e45a (remote main observed 17 September 2026).
Branch: Final-Fix. Do not merge or deploy this checkpoint.

## Completed first package

- Reject missing CLI values, unsafe SKU filenames, unbounded NIC wait and baseline/module-load combinations before host mutation.
- Reject wrapper digest bypass and pin the default payload URL and digest to an immutable commit.
- Explicitly restart the host rules service after configuration updates, including an already-active oneshot. This does not request a Docker restart; Linux integration validation remains required.
- Terminate after INT/TERM with cleanup on exit.
- Private newly-created evidence/log files and unique filenames.
- Added executable early-rejection checks and an Ubuntu CI job.

Local evidence: `sh test/preflight.sh` passes 11 rejection cases and shell syntax; `git diff --check` passes. These checks do not exercise Linux service/firewall behavior. CI results must be inspected separately.

## Open implementation packages

1. Common concurrency control across direct installer, wrapper and service; bounded iptables lock waits.
2. Ownership-aware staged installation and recovery/rollback, including failures during file replacement and rule application.
3. Explicit supported OS/network-manager/firewall profiles, inventory MAC verification, and mixed-backend handling. Board identity alone is not an OS compatibility contract.
4. Owned firewall rules with a physically qualified Matter/mDNS flow policy. Current broad rules are retained in this checkpoint; narrowing without controller tests would risk regression.
5. Reload and interface-recreation recovery with drift detection and tested boot ordering. Do not globally reorder Docker or override OS network configuration without profile evidence.
6. Readiness checks, durable failure evidence, log retention, and controller-level verification.

## Field gates and information required

For each of the intended two to five board configurations, obtain board/model, distribution/version, kernel, network manager, firewall/backend, LAN NIC/MAC and IPv6 configuration. Use read-only inventory first. No board access or changes occurred in this package.

Qualify initial install, active-service upgrade, interruption, rollback, firewall reload, reboot and interface recovery on Linux. Verify SSH, HA, Docker and existing Matter discovery/CASE/subscriptions. Preserve commissioned identity and topology. Then run the three-hour soak. The current branch is not production-qualified and cannot guarantee persistence against arbitrary OS changes.

Owner: this implementation thread. Diagnosis checkpoints: 10 minutes; narrow implementation and focused regression checkpoints: 20 minutes; board qualification checkpoints: 10 minutes. Checkpoints do not waive validation or shorten a soak.
