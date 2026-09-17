# Recoverable installation — Final-Fix

This package remains a candidate, not authorization to deploy or merge.

## What changed and why

- The installer stages both shell helpers, the systemd unit, defaults and any
  module-load file before replacing installed files. Shell helpers pass `sh -n`.
- A Python 3.8+ companion records old bytes/modes, new bytes/modes, prior service
  active/enabled state and owned firewall rules in a durable journal before
  replacement. File replacement uses a same-directory temporary file, rename
  and fsync; this is a recoverable sequence, not one atomic multi-file change.
- The journal lives at `/var/lib/cue-matter-ipv6/transaction.json`, mode 0600.
  One previous generation is retained. A pending recovery blocks the next apply.
- A startup failure restores the preceding files and service configuration.
  Failure in the installer's subsequent proof also requests rollback.
- Newly inserted rules carry `cue-matter-ipv6-v1`. Matching untagged rules are
  borrowed without changing them. Rollback removes only tagged additions absent
  from the pre-install snapshot; existing tagged and unrelated rules survive.
- Rollback refuses files changed independently since installation instead of
  overwriting operator edits. Repeated rollback is a no-op after completion.
- Wrapper downloads verify both the installer and its recovery companion by
  immutable commit and SHA-256. Use the complete release for direct execution.

## Manual recovery

Retain a checkout/download of the exact release outside the wrapper's temporary
directory. On the same host, as root, run:

```sh
python3 recover-install.py rollback
```

This restores the single retained predecessor, including after a committed
installation. It does not restore Matter data or run Docker commands. The
recovery tool takes the installer lock; the installer passes its existing lock
descriptor when invoking the companion. Rollback also serializes rule deletion.

## Limits

- SIGKILL/power loss cannot execute an exit trap. The journal enables explicit
  recovery and prevents a new installation over unfinished work; there is no
  automatic boot-time journal recovery yet.
- Files must be regular, nonsymlink files owned by the invoking root UID/GID.
  Unsupported service states such as masked/runtime-enabled units are refused.
- Successfully loaded kernel modules are not unloaded on rollback: they may be
  shared with other services. The module-load configuration file is restored.
- This preserves the broad existing flow policy. Firewall narrowing, OS reload
  recovery and full board qualification remain separate open packages.
- External tools must not reuse the reserved rule comment. Independent firewall
  changes without that comment are never removed by this transaction.
- Recovery failure retains the journal for diagnosis/retry and exits nonzero.
  Disk loss or an unavailable firewall/service manager cannot be repaired by a
  software promise; do not treat an error exit as proof of successful rollback.

## Evidence

Source/delivery commit: `914cfe3bf148a97f018e954e8d2977aabd49c976`.
[CI run 35178764338](https://github.com/CueHome/Deploy-IPv6/actions/runs/35178764338)
passed: 11 preflight rejection cases, 11 helper tests, 11 transaction tests and
the actual Linux network-namespace rule/rollback tests. Systemctl remained
mocked in the transaction tests; no board or real service recovery was tested.

`test/transaction.py` executes the actual transaction implementation against
temporary files with injected service commands: startup failure, second-file
write failure, process death after the first replacement, independent edits,
interrupted journals, repeated install/rollback, empty stages, symlinks and new
installation rollback.

`test/linux-netns.sh` additionally exercises actual ip6tables tagged additions
and rollback in an isolated namespace, while mocking systemctl. Its result is
Linux rule evidence, not a test of systemd recovery or any production board.
