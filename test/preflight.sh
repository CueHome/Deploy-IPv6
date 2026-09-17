#!/bin/sh
# Executes early rejection paths without root, Linux networking, or file writes.
set -eu
cd "$(dirname "$0")/.."
reject() {
    expected=$1
    shift
    rc=0
    output=$("$@" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || { echo "unexpected success: $*"; exit 1; }
    case "$output" in
        *"$expected"*) ;;
        *) printf 'wrong rejection: %s\n' "$output"; exit 1 ;;
    esac
}
for script in cue-matter-ipv6-changes.sh deploy-phase1.sh; do
    sh -n "$script"
done
reject 'missing value' sh cue-matter-ipv6-changes.sh --nic
reject 'cannot be combined' sh cue-matter-ipv6-changes.sh --baseline-only --load-modules
reject 'only letters' sh cue-matter-ipv6-changes.sh --sku '../bad'
reject 'only letters' sh cue-matter-ipv6-changes.sh --sku 'bad name'
for value in 0 301 999999999999999999999999 a; do
    reject 'must be' sh cue-matter-ipv6-changes.sh --nic-wait "$value"
done
reject 'digest bypass' env CUE_SKIP_DIGEST=1 sh deploy-phase1.sh install
reject 'baseline cannot' env CUE_LOAD_MODULES=1 sh deploy-phase1.sh baseline
reject 'invalid CUE_SKU' env CUE_SKU='../bad' sh deploy-phase1.sh install
echo 'PASS: syntax and 11 early rejection cases'
