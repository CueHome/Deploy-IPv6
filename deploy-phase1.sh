#!/bin/sh
# deploy-phase1.sh — MeshCentral group-action wrapper for the Phase 1 host unit.
#
# Repo: https://github.com/CueHome/Deploy-IPv6
# Runs cue-matter-ipv6-changes.sh (PRODUCTION IPv6 / MATTER IMPLEMENTATION GUIDE,
# 8 Sep 2026, Phase 1). Never touches the Matter container. Phase 2 and pairing
# stay separate, later, Founder-dispatched steps.
#
# In MeshCentral: My Devices -> select devices -> Run Commands
#   Shell: "Linux/BSD/macOS Command Shell"      Run as: "agent"
#
# Modes:
#   baseline   (default) diagnostic: writes logs and sends a UDP probe.
#   install    installs + enables the host unit, then proves it.
#
# Per-box values are DERIVED, never typed, because a group action sends identical
# text to every device:
#   NIC = the interface holding the default IPv4 route, cross-checked against the
#         board's expected names (Orange Pi CM5 / CM4). An off-list or ambiguous
#         NIC still aborts an install: rules on the wrong NIC give a dark bridge.
#   SKU = the hostname when it looks like a unit id (CC0123-010001), otherwise
#         auto-<hostname>-<mac>, which is unique per box because the MAC is.
#         Nothing to type, and no box is skipped for being named `cuehome`.
# Set CUE_STRICT_ID=1 to refuse instead any box whose hostname is not a unit id
# (guide 1's rule that a shared name must never identify a unit).
#
# Every run ends with one scannable line, including how long it took:
#   CUE-PHASE1 OK rc=0 host=... sku=... board=... nic=... ip=... mac=...
#              posture=A send=OK 12 rules=10 fe80=yes mode=install
#              elapsed=11s phase1=4s
#
# Overrides (environment):
#   CUE_SKU=...            record this exact unit id for this box
#   CUE_STRICT_ID=1        refuse boxes whose hostname is not a unit id
#   CUE_LAN_NIC=...        skip default-route derivation for this box
#   CUE_PHASE1_URL=...     fetch the Phase 1 script from elsewhere
#   CUE_PHASE1_SHA256=...  expected digest (default: pinned below)
#   CUE_SKIP_DIGEST=1      rejected; verification is mandatory
#   CUE_LOAD_MODULES=1     load ip6table_filter if the filter table is missing
#   CUE_NIC_WAIT=30        boot-time NIC wait baked into the unit
#
# Exit codes are the Phase 1 script's own:
#   0 ok | 1 usage/preflight | 2 identity/board mismatch | 3 proof failed
#   4 host cannot do IPv6 | 64 wrapper usage | 65 fetch/verify failed
set -eu
umask 077

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin:/usr/bin:/bin:$PATH
export PATH

MODE=${1:-baseline}
case "$MODE" in
    baseline|install) ;;
    -h|--help) sed -n '3,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'usage: deploy-phase1.sh [baseline|install]\n' >&2; exit 64 ;;
esac

if [ "${CUE_SKIP_DIGEST:-0}" = 1 ]; then
    printf 'ABORT: digest bypass is not supported\n' >&2
    exit 65
fi
if [ "$MODE" = baseline ] && [ "${CUE_LOAD_MODULES:-0}" = 1 ]; then
    printf 'ABORT: baseline cannot load kernel modules\n' >&2
    exit 64
fi
case "${CUE_SKU:-}" in
    *[!a-zA-Z0-9_-]*) printf 'ABORT: invalid CUE_SKU\n' >&2; exit 64 ;;
esac

PHASE1_URL=${CUE_PHASE1_URL:-https://raw.githubusercontent.com/CueHome/Deploy-IPv6/7bdae5925230b20615c8e945a63f491c7b5aa00e/cue-matter-ipv6-changes.sh}
PHASE1_SHA256=${CUE_PHASE1_SHA256:-82ad62e949bbe1657c9fc4ea8cca09f776f813abfeefae2640833f91cbeb092a}
LOGDIR=/var/log/cue-matter-ipv6
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
START_EPOCH=$(date -u +%s)
HOST=$(hostname 2>/dev/null || echo unknown)

# summary fields, all pre-set so `set -u` is safe on an early abort
SKU=""; SKU_SRC=""; NIC=""; NIC_SRC=""; BOARD=""; EXPECT=""
IPV4=""; MAC=""; FE80=""; POSTURE=""; SEND=""; RULES=""
TMPD=""; LOCK=""; LOG=""; PHASE1_SECS="?"

result() {
    _now=$(date -u +%s)
    _elapsed=$((_now - START_EPOCH))
    _line=$(printf 'CUE-PHASE1 %s rc=%s host=%s sku=%s board=%s nic=%s ip=%s mac=%s posture=%s send=%s rules=%s fe80=%s mode=%s elapsed=%ss phase1=%ss %s' \
        "$1" "$2" "$HOST" "${SKU:-?}" "${BOARD:-?}" "${NIC:-?}" "${IPV4:-?}" "${MAC:-?}" \
        "${POSTURE:-?}" "${SEND:-?}" "${RULES:-?}" "${FE80:-?}" "$MODE" \
        "$_elapsed" "$PHASE1_SECS" "${3:-}")
    printf '%s\n' "$_line"
    # keep the verdict in the log too, so a later audit does not depend on
    # whatever MeshCentral still has in its output pane
    if [ -n "$LOG" ] && [ -w "$LOG" ]; then
        printf '%s\n' "$_line" >> "$LOG"
    fi
}
abort() {
    printf 'ABORT: %s\n' "$1" >&2
    result ABORT "${2:-1}" "reason=$1"
    exit "${2:-1}"
}
# shellcheck disable=SC2329  # invoked via trap
cleanup() {
    [ -n "$TMPD" ] && rm -rf "$TMPD"
    return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '== CueRated Matter Phase 1 deploy (%s) on %s at %s\n' "$MODE" "$HOST" "$STAMP"

# ------------------------------------------------------------------ 1. root
if [ "$(id -u)" != 0 ]; then
    abort "not root (MeshCentral must run this as agent, not as the logged-in user)" 1
fi

# ------------------------------------------------------------------ 2. lock
command -v flock >/dev/null 2>&1 || abort "missing required tool: flock" 1
command -v install >/dev/null 2>&1 || abort "missing required tool: install" 1
install -d -m 0700 /run/cue-matter-ipv6
exec 9>/run/cue-matter-ipv6/wrapper.lock
flock -w 10 9 || abort "another wrapper is active (10 second lock timeout)" 1

# ------------------------------------------------------------- 3. board read
dt=""
for f in /proc/device-tree/model /sys/firmware/devicetree/base/model; do
    if [ -r "$f" ]; then
        dt=$(tr -d '\000' < "$f")
        break
    fi
done
case "$dt" in
    *CM5*|*cm5*) BOARD=opi-cm5; EXPECT="end1 end0 eth0 enP3p49s0 enP4p65s0" ;;
    *CM4*|*cm4*) BOARD=opi-cm4; EXPECT="end0 end1 eth0" ;;
    *)           BOARD=unknown; EXPECT="" ;;
esac
printf 'board    : %s (dt model: %s)\n' "$BOARD" "${dt:-none}"

# -------------------------------------------------------------------- 4. NIC
if [ -n "${CUE_LAN_NIC:-}" ]; then
    NIC=$CUE_LAN_NIC
    NIC_SRC=override
else
    command -v ip >/dev/null 2>&1 || abort "iproute2 (ip) not installed" 1
    cands=$(ip -4 route show default 2>/dev/null |
            awk '{for (i = 1; i <= NF; i++) if ($i == "dev") print $(i + 1)}' |
            sort -u)
    ncand=$(printf '%s' "$cands" | grep -c . 2>/dev/null || true)
    [ -n "$ncand" ] || ncand=0
    if [ "$ncand" -eq 0 ]; then
        abort "no default IPv4 route — cannot tell which NIC faces the house switch; re-run this box with CUE_LAN_NIC=<nic>" 2
    fi
    if [ "$ncand" -gt 1 ]; then
        abort "default route is ambiguous across $(printf '%s' "$cands" | tr '\n' ' ')— re-run this box with CUE_LAN_NIC=<nic>" 2
    fi
    NIC=$cands
    NIC_SRC=default-route
fi

case "$NIC" in
    ''|-*|*[!a-zA-Z0-9_.:-]*) abort "derived NIC name '$NIC' is not a valid interface name" 1 ;;
esac
[ "${#NIC}" -le 15 ] || abort "NIC name exceeds 15 characters" 1
ip link show dev "$NIC" >/dev/null 2>&1 || abort "NIC '$NIC' does not exist on this box" 1
case "$NIC" in
    lo|docker0|br-*|virbr*|veth*|tailscale0|wg0)
        abort "derived NIC '$NIC' is not a house-LAN interface — the default route leaves via an overlay or bridge on this box; re-run with CUE_LAN_NIC=<nic>" 2 ;;
esac

# Cross-check against the board. Unattended install must not guess; a baseline
# run changes nothing, so it reports and continues.
if [ -n "$EXPECT" ]; then
    ok=0
    for n in $EXPECT; do
        [ "$n" = "$NIC" ] && ok=1
    done
    if [ "$ok" -eq 0 ]; then
        if [ "$MODE" = install ]; then
            abort "'$NIC' is not a usual house-LAN name for $BOARD (expected one of: $EXPECT) — check this box by hand before installing" 2
        fi
        printf 'WARN: %s is not a usual house-LAN name for %s (expected: %s)\n' "$NIC" "$BOARD" "$EXPECT" >&2
    fi
fi

IPV4=$(ip -4 -o addr show dev "$NIC" 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}')
[ -n "$IPV4" ] || IPV4=none
MAC=$(cat "/sys/class/net/$NIC/address" 2>/dev/null || echo unknown)
if ip -6 -o addr show dev "$NIC" scope link 2>/dev/null | grep -q fe80; then
    FE80=yes
else
    FE80=no
fi
printf 'nic      : %s (from %s) ip=%s mac=%s fe80=%s\n' "$NIC" "$NIC_SRC" "$IPV4" "$MAC" "$FE80"

# --------------------------------------------------------------- 5. identity
# The fleet row needs an identifier, not a typed serial. A unit-id hostname is
# used as-is; anything else becomes auto-<hostname>-<mac>, unique because the
# MAC is. CUE_STRICT_ID=1 restores the refuse-unless-unit-id behaviour.
if [ -n "${CUE_SKU:-}" ]; then
    SKU=$CUE_SKU
    SKU_SRC=override
else
    case "$HOST" in
        [A-Za-z][A-Za-z][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9]*)
            SKU=$HOST
            SKU_SRC=hostname ;;
        *)
            if [ "${CUE_STRICT_ID:-0}" = 1 ]; then
                abort "hostname '$HOST' is not a unit id and CUE_STRICT_ID=1 is set; re-run this box with CUE_SKU=<unit id>" 2
            fi
            macsuffix=$(printf '%s' "$MAC" | tr -d ':' | tr -c '\-A-Za-z0-9._' '-')
            hostpart=$(printf '%s' "$HOST" | tr -c '\-A-Za-z0-9_' '-')
            SKU="auto-$hostpart-$macsuffix"
            SKU_SRC=auto-hostname-mac ;;
    esac
fi
printf 'sku      : %s (from %s)\n' "$SKU" "$SKU_SRC"
case "$SKU" in
    ''|*[!a-zA-Z0-9_-]*) abort "SKU must contain only letters, digits, underscore and hyphen" 2 ;;
esac
[ "${#SKU}" -le 80 ] || abort "SKU exceeds 80 characters" 2

# --------------------------------------------------------- 6. fetch + verify
TMPD=$(mktemp -d)
P1="$TMPD/cue-matter-ipv6-phase1.sh"

if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --retry-delay 2 --max-time 90 -o "$P1" "$PHASE1_URL" ||
        abort "download failed: $PHASE1_URL" 65
elif command -v wget >/dev/null 2>&1; then
    wget -q -T 90 -t 3 -O "$P1" "$PHASE1_URL" ||
        abort "download failed: $PHASE1_URL" 65
else
    abort "neither curl nor wget is available to fetch the Phase 1 script" 65
fi
[ -s "$P1" ] || abort "downloaded Phase 1 script is empty" 65

GOT=""
if command -v sha256sum >/dev/null 2>&1; then
    GOT=$(sha256sum "$P1" | awk '{print $1}')
elif command -v openssl >/dev/null 2>&1; then
    GOT=$(openssl dgst -sha256 "$P1" | awk '{print $NF}')
fi
if [ -z "$GOT" ]; then
    abort "no sha256sum or openssl on this box to verify the script" 65
elif [ "$GOT" != "$PHASE1_SHA256" ]; then
    printf 'expected sha256: %s\n' "$PHASE1_SHA256" >&2
    printf 'observed sha256: %s\n' "$GOT" >&2
    abort "Phase 1 script digest mismatch — the repo file changed; update CUE_PHASE1_SHA256 in this wrapper before deploying" 65
else
    printf 'verified : sha256 %s\n' "$GOT"
fi

# ----------------------------------------------------------------- 7. run it
set -- --nic "$NIC" --sku "$SKU" --yes
if [ "$BOARD" != unknown ]; then
    set -- "$@" --require-board "$BOARD"
fi
if [ "${CUE_LOAD_MODULES:-0}" = 1 ]; then
    set -- "$@" --load-modules
fi
if [ -n "${CUE_NIC_WAIT:-}" ]; then
    set -- "$@" --nic-wait "$CUE_NIC_WAIT"
fi
if [ "$MODE" = baseline ]; then
    set -- "$@" --baseline-only
fi

mkdir -p "$LOGDIR"
LOG=$(mktemp "$LOGDIR/deploy-$MODE-$SKU-$STAMP.XXXXXX")
printf 'running  : sh cue-matter-ipv6-phase1.sh %s\n\n' "$*"

rc=0
_p0=$(date -u +%s)
    sh "$P1" "$@" 9>&- </dev/null >"$LOG" 2>&1 || rc=$?
_p1=$(date -u +%s)
PHASE1_SECS=$((_p1 - _p0))
cat "$LOG"

# --------------------------------------------------------------- 8. summarise
SEND=$(grep -Eo 'OK 12|EPERM|EACCES|EAFNOSUPPORT|ENETUNREACH|ENETDOWN|EADDRNOTAVAIL|EINVAL' "$LOG" | tail -1 || true)
POSTURE=$(sed -n 's/^Posture: \([AB]\) .*/\1/p' "$LOG" | tail -1)
RULES=$(sed -n 's/.* lines in ip6tables: \([0-9][0-9]*\) .*/\1/p' "$LOG" | tail -1)
if [ -z "$RULES" ]; then
    RULES=$(sed -n 's/^-- existing .* rules: \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
fi

printf '\nlog      : %s\n' "$LOG"
printf 'timing   : phase1 %ss, wrapper total %ss (started %s)\n' \
    "$PHASE1_SECS" "$(( $(date -u +%s) - START_EPOCH ))" "$STAMP"

case "$rc" in
    0) if [ "$MODE" = baseline ]; then result BASELINE-OK "$rc"; else result OK "$rc"; fi ;;
    1) result PREFLIGHT-FAIL "$rc" ;;
    2) result IDENTITY-MISMATCH "$rc" ;;
    3) result PROOF-FAIL "$rc" "action=do-not-build-matter-on-this-box" ;;
    4) result NO-IPV6-ON-HOST "$rc" "action=separate-window-kernel-or-ip6tables" ;;
    *) result UNKNOWN-FAIL "$rc" ;;
esac
exit "$rc"
