# QA4 configuration conflict guard — 2026-09-21

## Scope and reason

QA4's container used host networking but its selected LAN interface had IPv6 disabled.
Readable IPv6 configuration files were not proof of a usable IPv6 interface. Persistent
enabling and disabling directives coexisted. This is host configuration evidence, not
proof of which process last wrote the kernel setting.

The installer and explicit provisioning tool now refuse persistent disabling directives
for all/default/loopback/the selected NIC before their host changes. Diagnostics identify
the file, line and directive. No administrator configuration is rewritten automatically.
The scanner respects same-basename directory priority, symlink deduplication and /dev/null
masks. A disabling directive in a distinct file remains a conflict even if another file
enables IPv6; it is a conservative policy guard, not a complete systemd/procps interpreter.
Unreadable policy fails closed. The provisioning tool also refuses non-regular policy
targets rather than replacing a symlink or special file.

## Evidence

- Eight real temporary-filesystem policy tests cover the observed contradictory policy,
  symlink deduplication, vendor overrides, later enabling overrides, slash notation,
  wildcard directives, comments, unrelated interfaces, masks and unsafe interface input.
  Each successful scan verifies all fixture bytes remain unchanged.
- Provisioning tests cover unit ordering, unsafe input, and conflict refusal before
  runtime reads or file replacement. Existing preflight, runtime-helper and journal tests
  remain mandatory. CI also exercises actual Linux network namespaces.
- The deployment wrapper must pin the updated installer and recovery companion to the
  same immutable payload commit, with independently verified SHA-256 digests.

## No regression boundary / rollout gate

This change does not restart containers, change HA, edit Matter state, reset fabrics,
change network-manager profiles, flush firewall rules or switch firewall backends.
The explicit provisioning tool from the prior local commit remains a separate host-wide
enablement operation, not part of the wrapper. It is not automatically invoked.

Source tests are NOT approval for fleet rollout. For each supported board/OS image:

1. Reconcile disabling settings with the host owner; do not simply add another override.
2. Inventory the effective nft/legacy firewall and its manager. An ACCEPT in another
   backend cannot cancel an effective DROP. Do not toggle UFW IPv6 or flush policy blindly.
3. Use a maintenance window and retain SSH access and rollback evidence. Apply the agreed
   host policy explicitly, then the verified Phase 1 installer.
4. Prove carrier, usable IPv6, multicast send and independent controller discovery/CASE/
   subscriptions. A local accepted send alone is not end-to-end readiness.
5. Repeat after reboot, network-manager restart, firewall reload and interface recreation;
   check HA connectivity and unchanged Matter identity/fabrics/endpoints.

No automatic fight against an OS manager, watchdog policy rewrite, board mutation or
reboot was performed for this source change. Actual systemd ordering, firewall-reload
persistence and the two-to-five-board qualification matrix remain release gates.
