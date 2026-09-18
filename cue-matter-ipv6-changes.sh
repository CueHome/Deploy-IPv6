#!/bin/sh
# cue-matter-ipv6-phase1.sh
#
# Phase 1 of PRODUCTION IPv6 / MATTER IMPLEMENTATION GUIDE (8 Sep 2026)
# Host IPv6 unit first. This script NEVER touches the Matter container.
#
# Boards: Orange Pi CM5 (RK3588S) and Orange Pi CM4 (RK3566).
# Other SBCs still run, with a board warning.
#
#   1. Detect the board and validate THIS box's LAN NIC         (guide 3.1)
#   2. Record the fleet-unit row (SKU + IPv4 + MAC + NIC)       (guide 1)
#   3. Read-only baseline, determine posture A or B             (guide 3.2)
#   4. Install cue-matter-ipv6-rules + systemd unit, enable it  (guide 3.3)
#   5. Prove: unit enabled/active, ten NIC rules, send = OK 12  (guide 3.4)
#   6. Print the compose pin and the Phase 1 done checklist     (guide 3.4/3.5)
#
# It does NOT change UFW policy, FORWARD, sysctl, IPV6=yes, or any container.
# Phase 2 (build/v1.0.0) is a separate, later step. Pairing is a Founder dispatch.
#
# Usage:
#   sudo ./cue-matter-ipv6-phase1.sh --nic end1 --sku HC2609-00001 \
#        [--expect-ipv4 192.168.1.72] [--expect-mac 00:00:a4:cd:da:e3] \
#        [--require-board opi-cm5|opi-cm4] [--nic-wait 30] \
#        [--baseline-only] [--yes] [--allow-nonstandard-nic] [--load-modules]
#
# Exit codes:
#   0 ok | 1 usage/preflight | 2 fleet-row or board mismatch
#   3 proof failed | 4 host cannot do IPv6 (kernel/ip6tables) — separate window
set -eu
umask 077

# sudo often hands over a trimmed PATH; ip/ip6tables/systemctl live in sbin.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin:/usr/bin:/bin:$PATH
export PATH

PROG=$(basename "$0")
NIC=""
SKU=""
EXPECT_IPV4=""
EXPECT_MAC=""
REQUIRE_BOARD=""
NIC_WAIT=30
BASELINE_ONLY=0
ASSUME_YES=0
ALLOW_NONSTANDARD=0
LOAD_MODULES=0
EVIDENCE_DIR=${CUE_EVIDENCE_DIR:-/var/log/cue-matter-ipv6}

SBIN=/usr/local/sbin/cue-matter-ipv6-rules
WAITBIN=/usr/local/sbin/cue-matter-ipv6-wait-nic
UNIT=/etc/systemd/system/cue-matter-ipv6-rules.service
DEFAULTS=/etc/default/cue-matter-ipv6-rules
MODCONF=/etc/modules-load.d/cue-matter-ipv6.conf
EXPECTED_RULES=10

log()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf '\nSTOP: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
    sed -n '3,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-1}"
}

# ---------------------------------------------------------------- arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --nic|--sku|--expect-ipv4|--expect-mac|--require-board|--nic-wait)
            [ $# -ge 2 ] && [ -n "$2" ] || die "missing value for $1" ;;
    esac
    case "$1" in
        --nic)                   NIC=${2:-};            shift 2 ;;
        --nic=*)                 NIC=${1#*=};           shift ;;
        --sku)                   SKU=${2:-};            shift 2 ;;
        --sku=*)                 SKU=${1#*=};           shift ;;
        --expect-ipv4)           EXPECT_IPV4=${2:-};    shift 2 ;;
        --expect-ipv4=*)         EXPECT_IPV4=${1#*=};   shift ;;
        --expect-mac)            EXPECT_MAC=${2:-};     shift 2 ;;
        --expect-mac=*)          EXPECT_MAC=${1#*=};    shift ;;
        --require-board)         REQUIRE_BOARD=${2:-};  shift 2 ;;
        --require-board=*)       REQUIRE_BOARD=${1#*=}; shift ;;
        --nic-wait)              NIC_WAIT=${2:-};       shift 2 ;;
        --nic-wait=*)            NIC_WAIT=${1#*=};      shift ;;
        --baseline-only)         BASELINE_ONLY=1;       shift ;;
        -y|--yes)                ASSUME_YES=1;          shift ;;
        --allow-nonstandard-nic) ALLOW_NONSTANDARD=1;   shift ;;
        --load-modules)          LOAD_MODULES=1;        shift ;;
        -h|--help)               usage 0 ;;
        *) printf 'Unknown argument: %s\n\n' "$1" >&2; usage 1 ;;
    esac
done

case "$NIC_WAIT" in
    ''|*[!0-9]*|????*) die "--nic-wait must be an integer from 1 to 300" ;;
esac
[ "$NIC_WAIT" -ge 1 ] && [ "$NIC_WAIT" -le 300 ] || die "--nic-wait must be from 1 to 300"
case "$SKU" in
    *[!a-zA-Z0-9_-]*) die "--sku may contain only letters, digits, underscore and hyphen" ;;
esac
[ "${#SKU}" -le 80 ] || die "--sku is too long (maximum 80)"
if [ "$BASELINE_ONLY" -eq 1 ] && [ "$LOAD_MODULES" -eq 1 ]; then
    die "--baseline-only cannot be combined with --load-modules"
fi

# ------------------------------------------------------- board identification
# CUE_DT_ROOT is a test hook: point it at a fake tree to rehearse the board
# checks on a non-target box. Unset in production.
dt_read() {
    for f in "${CUE_DT_ROOT:-}/proc/device-tree/$1" "${CUE_DT_ROOT:-}/sys/firmware/devicetree/base/$1"; do
        if [ -r "$f" ]; then
            tr -d '\000' < "$f"
            return 0
        fi
    done
    return 1
}

BOARD_MODEL=$(dt_read model 2>/dev/null || echo "")
BOARD_COMPAT=$(dt_read compatible 2>/dev/null | tr '\000' ' ' || echo "")
BOARD_RELEASE=""
if [ -r /etc/orangepi-release ]; then
    BOARD_RELEASE=$(awk -F= '/^BOARD=/ {print $2}' /etc/orangepi-release 2>/dev/null | tr -d '"')
elif [ -r /etc/armbian-release ]; then
    BOARD_RELEASE=$(awk -F= '/^BOARD=/ {print $2}' /etc/armbian-release 2>/dev/null | tr -d '"')
fi
[ -n "$BOARD_MODEL" ] || BOARD_MODEL="unknown (no device-tree model)"

BOARD_SOC=unknown
case "$BOARD_COMPAT$BOARD_MODEL" in
    *rk3588s*|*RK3588S*) BOARD_SOC=rk3588s ;;
    *rk3588*|*RK3588*)   BOARD_SOC=rk3588 ;;
    *rk3566*|*RK3566*)   BOARD_SOC=rk3566 ;;
    *rk3568*|*RK3568*)   BOARD_SOC=rk3568 ;;
esac

# Board key + the NIC names the house-LAN port takes on that board.
# Rockchip vendor kernels name the onboard GbE end0/end1; mainline uses enP*/eth0.
BOARD_KEY=unknown
BOARD_LABEL="$BOARD_MODEL"
BOARD_EXPECT_NICS=""
case "$BOARD_MODEL$BOARD_RELEASE" in
    *CM5*|*cm5*)
        BOARD_KEY=opi-cm5
        BOARD_LABEL="Orange Pi CM5 (${BOARD_SOC})"
        BOARD_EXPECT_NICS="end1 end0 eth0 enP3p49s0 enP4p65s0" ;;
    *CM4*|*cm4*)
        BOARD_KEY=opi-cm4
        BOARD_LABEL="Orange Pi CM4 (${BOARD_SOC})"
        BOARD_EXPECT_NICS="end0 end1 eth0" ;;
    *[Oo]range*[Pp]i*|*OrangePi*|*orangepi*)
        BOARD_KEY=opi-other
        BOARD_LABEL="Orange Pi, model not in table (${BOARD_SOC})"
        BOARD_EXPECT_NICS="end0 end1 eth0" ;;
esac
# RK3566 CM4 and RK3588S CM5 are the two supported modules; a bare SoC match
# still gives a useful NIC hint when the DT model string is non-standard.
if [ "$BOARD_KEY" = unknown ]; then
    case "$BOARD_SOC" in
        rk3588s|rk3588) BOARD_EXPECT_NICS="end1 end0 eth0" ;;
        rk3566|rk3568)  BOARD_EXPECT_NICS="end0 end1 eth0" ;;
    esac
fi

ARCH=$(uname -m 2>/dev/null || echo unknown)
KERNEL=$(uname -r 2>/dev/null || echo unknown)

# ------------------------------------------------------------- NIC required
# The guide is explicit: the NIC belongs to THIS box. Never inherit end1 from
# another family, and never let a default pick it for you.
if [ -z "$NIC" ]; then
    NIC=${CUE_LAN_NIC:-}
fi
if [ -z "$NIC" ]; then
    printf 'No NIC given.\n' >&2
    printf 'Pass --nic <name> (or export CUE_LAN_NIC) for THIS box only.\n' >&2
    printf 'Board: %s\n' "$BOARD_LABEL" >&2
    [ -n "$BOARD_EXPECT_NICS" ] &&
        printf 'House-LAN NIC on this board is usually one of: %s\n' "$BOARD_EXPECT_NICS" >&2
    printf 'Interfaces on this host:\n' >&2
    ip -br link 2>/dev/null >&2 || true
    exit 1
fi
case "$NIC" in
    -*|*[!a-zA-Z0-9_.:-]*) die "Invalid NIC name: $NIC" ;;
esac
[ "${#NIC}" -le 15 ] || die "NIC name exceeds Linux IFNAMSIZ (15 characters)"
case "$NIC" in .|..) die "Invalid NIC name: $NIC" ;; esac

# ------------------------------------------------------------- 0. preflight
step "0. Preflight"
[ "$(id -u)" = 0 ] || die "run as root (sudo $PROG --nic $NIC ...)"

for t in ip ip6tables python3; do
    command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
done
if [ "$BASELINE_ONLY" -eq 0 ]; then
    RECOVER="$(CDPATH= cd -- "$(dirname "$0")" && pwd)/recover-install.py"
    [ -r "$RECOVER" ] || die "missing companion recover-install.py; use the complete verified release"
    python3 -c 'import sys; assert sys.version_info >= (3, 8)' || die "Python 3.8 or later required"
    command -v systemctl >/dev/null 2>&1 || die "missing required tool: systemctl"
    command -v install   >/dev/null 2>&1 || die "missing required tool: install"
    command -v flock >/dev/null 2>&1 || die "missing required tool: flock"
    [ -d /run/systemd/system ] || die "installation requires systemd as the running service manager"
    # The descriptor remains open until the installer exits, including signal exit.
    install -d -m 0700 /run/cue-matter-ipv6
    exec 9>/run/cue-matter-ipv6/install.lock
    flock -w 10 9 || die "another installer is active (10 second lock timeout)"
fi
log "root: yes    tools: ok"

log "board    : $BOARD_LABEL"
log "dt model : $BOARD_MODEL"
[ -n "$BOARD_RELEASE" ] && log "release  : $BOARD_RELEASE"
log "soc/arch : $BOARD_SOC / $ARCH"
log "kernel   : $KERNEL"

case "$ARCH" in
    aarch64|arm64) ;;
    *) warn "arch is $ARCH — CM5/CM4 modules are aarch64; are you on the right box?" ;;
esac

if [ -n "$REQUIRE_BOARD" ] && [ "$REQUIRE_BOARD" != "$BOARD_KEY" ]; then
    die "board mismatch: --require-board $REQUIRE_BOARD, detected $BOARD_KEY ($BOARD_LABEL)" 2
fi
case "$BOARD_KEY" in
    opi-cm5|opi-cm4) ;;
    *) warn "board not in the CM5/CM4 table (detected: $BOARD_KEY) — proceeding, but confirm the NIC by hand" ;;
esac

# --- IPv6 must exist in the kernel. The host unit punches ACCEPT holes; it
# --- cannot resurrect a stack that is switched off. That is a separate window.
[ -d /proc/sys/net/ipv6 ] ||
    die "kernel IPv6 stack absent (/proc/sys/net/ipv6 missing) — likely ipv6.disable=1 in the boot cmdline. Separate window; do not continue to Phase 2." 4
if grep -q 'ipv6\.disable=1' /proc/cmdline 2>/dev/null; then
    die "ipv6.disable=1 is in /proc/cmdline (Orange Pi images ship this on some builds). Fix the boot args in a separate window, reboot, then re-run." 4
fi
# The per-interface value is what the kernel actually enforces on a link.
# conf.all.disable_ipv6 is a write-time broadcast, not a live override: a box
# can read all=1 from boot and still have IPv6 up on the house NIC because
# something (usually NetworkManager) set that NIC back to 0 afterwards. So the
# NIC's own value is the gate; all/default are recorded as a reboot risk.
sysctl_get() { cat "/proc/sys/net/ipv6/conf/$1/disable_ipv6" 2>/dev/null || echo "?"; }
D_ALL=$(sysctl_get all)
D_NIC=$(sysctl_get "$NIC")
D_DEF=$(sysctl_get default)
log "ipv6 disable_ipv6: all=$D_ALL default=$D_DEF $NIC=$D_NIC  (the NIC value governs)"
if [ "$D_NIC" = 1 ]; then
    die "net.ipv6.conf.$NIC.disable_ipv6=1 — IPv6 is off on the house NIC. Separate window (this programme does not change sysctl)." 4
fi
if [ "$D_NIC" = "?" ]; then
    die "no /proc/sys/net/ipv6/conf/$NIC/disable_ipv6 — the kernel has no IPv6 state for this NIC. Separate window." 4
fi
if [ "$D_ALL" = 1 ]; then
    warn "conf.all.disable_ipv6=1 is stored on this host while $NIC is live at 0 — something re-enabled the NIC after boot. Phase 1 can proceed, but this box MUST be reboot-verified and the config fixed in a separate window, or it comes back dark."
    grep -rIn 'disable_ipv6' /etc/sysctl.conf /etc/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d 2>/dev/null |
        sed 's/^/  sets it: /' || true
fi
if [ "$D_DEF" = 1 ]; then
    warn "conf.default.disable_ipv6=1 — any new or re-created interface comes up without IPv6; note it on the row"
fi
if [ "$BASELINE_ONLY" = 0 ] && { [ "$D_ALL" != 0 ] || [ "$D_DEF" != 0 ]; }; then
    die "IPv6 provisioning is inconsistent. Run provision-ipv6.py --nic $NIC --check, then the explicit --apply provisioning step before installing firewall rules." 4
fi


ip link show dev "$NIC" >/dev/null 2>&1 || {
    printf 'NIC %s does not exist on this box.\n' "$NIC" >&2
    printf 'Board: %s\n' "$BOARD_LABEL" >&2
    [ -n "$BOARD_EXPECT_NICS" ] &&
        printf 'Usually one of: %s\n' "$BOARD_EXPECT_NICS" >&2
    printf 'Interfaces:\n' >&2
    ip -br link >&2 || true
    die "wrong NIC — do not copy a NIC name from another SKU" 1
}

case "$NIC" in
    lo|docker0|br-*|tailscale0|wg0|virbr*|veth*)
        [ "$ALLOW_NONSTANDARD" -eq 1 ] ||
            die "$NIC is not a house-LAN NIC (guide 3.1). Pick the UP Ethernet NIC to the house switch." ;;
    wlan*|wlp*)
        [ "$ALLOW_NONSTANDARD" -eq 1 ] ||
            die "$NIC is Wi-Fi. Only allowed for a Wi-Fi-only SKU: re-run with --allow-nonstandard-nic." ;;
esac

if [ -n "$BOARD_EXPECT_NICS" ]; then
    nic_expected=0
    for n in $BOARD_EXPECT_NICS; do
        [ "$n" = "$NIC" ] && nic_expected=1
    done
    [ "$nic_expected" -eq 1 ] ||
        warn "$NIC is not a usual house-LAN name for $BOARD_LABEL (expected one of: $BOARD_EXPECT_NICS) — confirm against the fleet row"
fi

# --------------------------------------------------- 1. identify + 2. fleet row
step "1. Identify this NIC (guide 3.1)"
ip -br link
log ""
log "Selected NIC: $NIC"
ip -br addr show dev "$NIC" || true
ip -6 addr show dev "$NIC" || true

LINK_STATE=$(cat "/sys/class/net/$NIC/operstate" 2>/dev/null || echo unknown)
MAC=$(cat "/sys/class/net/$NIC/address" 2>/dev/null || echo unknown)
IPV4=$(ip -4 -o addr show dev "$NIC" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
[ -n "${IPV4:-}" ] || IPV4=none
LINK_LOCAL=$(ip -6 -o addr show dev "$NIC" scope link 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
[ -n "${LINK_LOCAL:-}" ] || LINK_LOCAL=none

[ "$LINK_STATE" = up ] || warn "$NIC operstate is '$LINK_STATE' (guide wants an UP interface)"
[ "$LINK_LOCAL" != none ] || warn "$NIC has no fe80::/64 link-local address"
ip link show dev "$NIC" 2>/dev/null | head -1 | grep -q MULTICAST ||
    warn "$NIC does not carry the MULTICAST flag — mDNS on ff02::fb cannot work"

step "2. Fleet-unit row (guide 1 — never select a box by hostname)"
printf '  SKU      : %s\n' "${SKU:-<NOT GIVEN>}"
printf '  Board    : %s\n' "$BOARD_LABEL"
printf '  IPv4     : %s\n' "$IPV4"
printf '  MAC      : %s\n' "$MAC"
printf '  NIC      : %s (%s)\n' "$NIC" "$LINK_STATE"
printf '  fe80     : %s\n' "$LINK_LOCAL"
printf '  hostname : %s  <- identification value only, NEVER a selector\n' "$(hostname 2>/dev/null || echo unknown)"

if [ -z "$SKU" ] && [ "$BASELINE_ONLY" -eq 0 ]; then
    die "--sku is required for an install run: the fleet row must be recorded (guide 1)"
fi

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
if [ -n "$EXPECT_IPV4" ] && [ "$EXPECT_IPV4" != "$IPV4" ]; then
    die "IPv4 mismatch: row says $EXPECT_IPV4, this box is $IPV4 — you are on the wrong SBC" 2
fi
if [ -n "$EXPECT_MAC" ] && [ "$(lower "$EXPECT_MAC")" != "$(lower "$MAC")" ]; then
    die "MAC mismatch: row says $EXPECT_MAC, this box is $MAC — you are on the wrong SBC" 2
fi
if [ -n "$EXPECT_IPV4$EXPECT_MAC" ]; then
    log "  row check: IP/MAC match the expected fleet row"
else
    warn "no --expect-ipv4/--expect-mac given: confirm the row above against the fleet sheet before continuing"
fi

# Module loading is allowed only after NIC and fleet validation and confirmation.
if [ "$LOAD_MODULES" -eq 1 ] && [ "$ASSUME_YES" -eq 0 ]; then
    printf 'Load IPv6 kernel modules on %s? Type the NIC name: ' "$NIC"
    read -r module_reply || module_reply=""
    [ "$module_reply" = "$NIC" ] || die "module loading not confirmed"
fi
PERSIST_MODULES=0
# --- ip6tables must be able to read the filter table. On Rockchip vendor
# --- kernels ip6table_filter is often a module that is not yet loaded.
IP6T_VER=$(ip6tables -V 2>/dev/null || echo unknown)
log "ip6tables: $IP6T_VER"
if ! ip6tables -S >/dev/null 2>&1; then
    if [ "$LOAD_MODULES" -eq 1 ]; then
        warn "ip6tables filter table unreadable — loading ip6table_filter"
        modprobe ip6table_filter 2>/dev/null || true
        modprobe ip6_tables 2>/dev/null || true
    fi
    if ! ip6tables -S >/dev/null 2>&1; then
        printf 'ip6tables cannot read the filter table on this kernel.\n' >&2
        printf 'On Orange Pi CM5/CM4 vendor kernels this is usually a missing module.\n' >&2
        printf 'Try:  modprobe ip6table_filter   (or re-run with --load-modules)\n' >&2
        printf 'If modprobe fails, the kernel lacks CONFIG_IP6_NF_FILTER — separate window.\n' >&2
        die "ip6tables filter table unavailable" 4
    fi
    log "ip6tables filter table now readable"
    if [ "$LOAD_MODULES" -eq 1 ] && [ "$BASELINE_ONLY" -eq 0 ]; then
        PERSIST_MODULES=1
        log "module persistence staged for installation"
    fi
fi
case "$IP6T_VER" in
    *nf_tables*) log "backend  : nf_tables (rules land in the nft ruleset; ufw6 chains, if any, share it)" ;;
    *legacy*)    log "backend  : legacy xtables" ;;
esac
if [ -x /usr/sbin/ip6tables-legacy ] && [ -x /usr/sbin/ip6tables-nft ]; then
    case "$IP6T_VER" in
        *nf_tables*) ip6tables-legacy -S 2>/dev/null | grep -q '^-A' &&
            warn "the legacy ip6tables ruleset is non-empty while the default backend is nf_tables — two rulesets are live on this box" ;;
    esac
fi

# ------------------------------------------------------------- 3. baseline
send_probe() {
    CUE_LAN_NIC="$NIC" python3 - <<'PY'
import errno, os, socket
nic = os.environ.get("CUE_LAN_NIC", "end1")
s = None
try:
    i = socket.if_nametoindex(nic)
    s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, i)
    n = s.sendto(bytes(12), ("ff02::fb", 5353, 0, i))
    print("OK", n, nic)
except OSError as e:
    print(errno.errorcode.get(e.errno, e.errno), e)
finally:
    if s is not None:
        s.close()
PY
}

count_nic_rules() {
    ip6tables -S 2>/dev/null | awk -v nic="$NIC" '
        {for (i=1;i<NF;i++) if (($i=="-i" || $i=="-o") && $(i+1)==nic) {n++;break}}
        END {print n+0}'
}

show_nic_rules() {
    ip6tables -S | awk -v nic="$NIC" '
        {for (i=1;i<NF;i++) if (($i=="-i" || $i=="-o") && $(i+1)==nic) {print;break}}'
}

# The ten lines the unit is responsible for (guide 3.3), checked individually so
# unrelated pre-existing NIC rules cannot mask a missing one.
rule_present() {
    ip6tables -w 5 -C "$@" 2>/dev/null ||
        ip6tables -w 5 -C "$@" -m comment --comment cue-matter-ipv6-v1 2>/dev/null
}
check_expected_rules() {
    missing=0
    for port in 5353 5540; do
        rule_present INPUT  -i "$NIC" -p udp --sport "$port" -j ACCEPT 2>/dev/null || { warn "missing: INPUT  -i $NIC udp --sport $port"; missing=$((missing + 1)); }
        rule_present INPUT  -i "$NIC" -p udp --dport "$port" -j ACCEPT 2>/dev/null || { warn "missing: INPUT  -i $NIC udp --dport $port"; missing=$((missing + 1)); }
        rule_present OUTPUT -o "$NIC" -p udp --sport "$port" -j ACCEPT 2>/dev/null || { warn "missing: OUTPUT -o $NIC udp --sport $port"; missing=$((missing + 1)); }
        rule_present OUTPUT -o "$NIC" -p udp --dport "$port" -j ACCEPT 2>/dev/null || { warn "missing: OUTPUT -o $NIC udp --dport $port"; missing=$((missing + 1)); }
    done
    rule_present INPUT  -i "$NIC" -p ipv6-icmp -j ACCEPT 2>/dev/null || { warn "missing: INPUT  -i $NIC ipv6-icmp"; missing=$((missing + 1)); }
    rule_present OUTPUT -o "$NIC" -p ipv6-icmp -j ACCEPT 2>/dev/null || { warn "missing: OUTPUT -o $NIC ipv6-icmp"; missing=$((missing + 1)); }
    return "$missing"
}

step "3. Baseline — read-only (guide 3.2)"
log "-- ip6tables -S | head -8"
ip6tables -S 2>/dev/null | head -8 || warn "could not read ip6tables"
log ""
log "-- policies"
ip6tables -S 2>/dev/null | grep -E '^-P ' || true
log ""
log "-- /etc/default/ufw"
grep IPV6 /etc/default/ufw 2>/dev/null || log "(no IPV6 line / no ufw defaults file)"
log ""
log "-- ufw6 chains"
if ip6tables -S 2>/dev/null | grep -q 'ufw6-'; then log "present"; else log "none"; fi
log ""
log "-- existing $NIC rules: $(count_nic_rules)"
log ""
log "-- send test to ff02::fb:5353 via $NIC"
BEFORE_SEND=$(send_probe 2>&1) || true
log "   $BEFORE_SEND"

OUT_POLICY=$(ip6tables -S 2>/dev/null | awk '/^-P OUTPUT/ {print $3; exit}')
case "$OUT_POLICY" in
    DROP)   POSTURE="A — DROP (install unit; send MUST become OK 12)" ;;
    ACCEPT) POSTURE="B — ACCEPT (still install the unit for persistence; do NOT flip policy)" ;;
    *)      POSTURE="unknown OUTPUT policy '${OUT_POLICY:-?}' — read guide 2 before continuing" ;;
esac
log ""
log "Posture: $POSTURE"

if [ "$BASELINE_ONLY" -eq 1 ]; then
    step "Baseline collected — no configuration changes; UDP probe was sent"
    log "Re-run without --baseline-only to install the host unit."
    exit 0
fi

# ------------------------------------------------------- boot-ordering check
# Orange Pi images boot with NetworkManager (or systemd-networkd). If no
# wait-online service is enabled, network-online.target is reached early and a
# oneshot can fire before udev has renamed the NIC. The unit gets a bounded
# NIC wait below, but an enabled wait-online is still the cleaner state.
WAIT_ONLINE="none"
for svc in NetworkManager-wait-online.service systemd-networkd-wait-online.service networking.service; do
    if systemctl is-enabled "$svc" >/dev/null 2>&1; then
        WAIT_ONLINE="$svc"
        break
    fi
done
log ""
log "wait-online: $WAIT_ONLINE"
[ "$WAIT_ONLINE" = none ] &&
    warn "no wait-online service enabled — relying on the unit's ${NIC_WAIT}s NIC wait to survive boot"

# -------------------------------------------------------------- confirmation
if [ "$ASSUME_YES" -eq 0 ]; then
    step "About to install the host unit on $NIC ($BOARD_LABEL)"
    log "Writes: $SBIN, $WAITBIN, $UNIT, $DEFAULTS"
    log "Does NOT touch: UFW policy, FORWARD, sysctl, IPV6=, any container."
    printf 'Type the NIC name to confirm [%s]: ' "$NIC"
    read -r reply || reply=""
    [ "$reply" = "$NIC" ] || die "not confirmed (you typed '${reply}')"
fi

# --------------------------------------------------------------- 4. install
step "4. Install host unit (guide 3.3)"
TMPD=$(mktemp -d)
TX_ACTIVE=0
cleanup_install() {
    result=$?
    trap - EXIT INT TERM
    if [ "$TX_ACTIVE" = 1 ]; then
        python3 "$RECOVER" rollback --inherited-lock 9 || {
            warn "automatic rollback incomplete; run recover-install.py rollback before retrying"
            result=3
        }
    fi
    rm -rf "$TMPD"
    exit "$result"
}
trap cleanup_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Stage every payload before touching installed files.
cat >"$TMPD/cue-matter-ipv6-rules" <<'RULES_EOF'
#!/bin/sh
set -eu
nic=${CUE_LAN_NIC:-}
case "$nic" in
    ""|-*|.|..|*[!a-zA-Z0-9_.:-]*) echo "Invalid CUE_LAN_NIC" >&2; exit 1 ;;
esac
[ "${#nic}" -le 15 ] || exit 1
ip link show dev "$nic" >/dev/null
exec 8>/run/cue-matter-ipv6/rules.lock
flock -w 10 8 || { echo "rules lock timeout" >&2; exit 1; }
allow() {
    chain=$1
    shift
    ip6tables -w 5 -C "$chain" "$@" 2>/dev/null ||
        ip6tables -w 5 -C "$chain" "$@" -m comment --comment cue-matter-ipv6-v1 2>/dev/null ||
        ip6tables -w 5 -I "$chain" 1 "$@" -m comment --comment cue-matter-ipv6-v1
}
for port in 5353 5540; do
    allow INPUT  -i "$nic" -p udp --sport "$port" -j ACCEPT
    allow INPUT  -i "$nic" -p udp --dport "$port" -j ACCEPT
    allow OUTPUT -o "$nic" -p udp --sport "$port" -j ACCEPT
    allow OUTPUT -o "$nic" -p udp --dport "$port" -j ACCEPT
done
allow INPUT  -i "$nic" -p ipv6-icmp -j ACCEPT
allow OUTPUT -o "$nic" -p ipv6-icmp -j ACCEPT
RULES_EOF


# ExecStartPre helper: bounded wait for the renamed NIC. Separate file so no
# shell metacharacter ever passes through systemd's Exec-line expansion.
cat >"$TMPD/cue-matter-ipv6-wait-nic" <<'WAIT_EOF'
#!/bin/sh
# Wait for the Cue LAN NIC to exist. Orange Pi CM5/CM4 rename the onboard GbE
# in udev; a oneshot ordered after network-online.target can still be early.
set -eu
nic=${CUE_LAN_NIC:-}
wait_for=${CUE_NIC_WAIT:-30}
case "$nic" in
    ""|-*|.|..|*[!a-zA-Z0-9_.:-]*) echo "Invalid CUE_LAN_NIC" >&2; exit 1 ;;
esac
[ "${#nic}" -le 15 ] || exit 1
case "$wait_for" in
    ''|*[!0-9]*|????*) echo "Invalid CUE_NIC_WAIT" >&2; exit 1 ;;
esac
[ "$wait_for" -ge 1 ] && [ "$wait_for" -le 300 ] || exit 1
n=0
while [ "$n" -lt "$wait_for" ]; do
    if ip link show dev "$nic" >/dev/null 2>&1; then
        # Presence alone can precede carrier and duplicate-address detection.
        if ip -o link show dev "$nic" | grep -q 'LOWER_UP' &&
            ip -o link show dev "$nic" | grep -q 'MULTICAST' &&
            ip -6 -o addr show dev "$nic" scope link |
                awk '/inet6 fe80:/ && !/tentative|dadfailed/ {ok=1} END {exit !ok}'; then
            exit 0
        fi
    fi
    n=$((n + 1))
    sleep 1
done
echo "NIC $nic has no usable carrier/multicast/link-local address within ${wait_for}s" >&2
exit 1
WAIT_EOF


cat >"$TMPD/unit" <<UNIT_EOF
[Unit]
Description=Allow Matter IPv6 traffic on the Cue LAN interface
Wants=network-online.target
After=network-online.target ufw.service docker.service
PartOf=docker.service

[Service]
Type=oneshot
RuntimeDirectory=cue-matter-ipv6
RuntimeDirectoryMode=0700
RuntimeDirectoryPreserve=yes
TimeoutStartSec=500
Environment=CUE_LAN_NIC=$NIC
Environment=CUE_NIC_WAIT=$NIC_WAIT
EnvironmentFile=-$DEFAULTS
ExecStartPre=$WAITBIN
ExecStart=$SBIN
RemainAfterExit=yes
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target docker.service
UNIT_EOF
log "installed $UNIT (ExecStartPre NIC wait: ${NIC_WAIT}s — deviation from guide 3.3, see notes)"

{
    printf 'CUE_LAN_NIC=%s\n' "$NIC"
    printf 'CUE_NIC_WAIT=%s\n' "$NIC_WAIT"
} > "$TMPD/defaults"
if [ "$PERSIST_MODULES" -eq 1 ]; then
    printf 'ip6_tables\nip6table_filter\n' > "$TMPD/modules"
fi
python3 "$RECOVER" apply --stage "$TMPD" --inherited-lock 9
TX_ACTIVE=1

# ----------------------------------------------------------------- 5. prove
step "5. Prove Phase 1 (guide 3.4)"
FAIL=0
RULES_VERDICT="not evaluated"

ENABLED=$(systemctl is-enabled cue-matter-ipv6-rules.service 2>&1 || true)
ACTIVE=$(systemctl is-active  cue-matter-ipv6-rules.service 2>&1 || true)
log "is-enabled : $ENABLED"
log "is-active  : $ACTIVE"
case "$ENABLED" in enabled) ;; *) warn "unit not enabled"; FAIL=1 ;; esac
case "$ACTIVE"  in active)  ;; *) warn "unit not active";  FAIL=1 ;; esac

log ""
log "-- $NIC rules"
show_nic_rules
RULES=$(count_nic_rules)
log ""
log "$NIC-scoped lines in ip6tables: $RULES (guide expects $EXPECTED_RULES)"
if check_expected_rules; then
    RULES_VERDICT="all $EXPECTED_RULES unit rules present"
    log "all $EXPECTED_RULES unit rules verified present (ip6tables -C)"
    [ "$RULES" -eq "$EXPECTED_RULES" ] ||
        warn "$RULES lines match $NIC, i.e. $((RULES - EXPECTED_RULES)) pre-existing rule(s) alongside the unit's ten — note this on the fleet row"
else
    RULES_VERDICT="INCOMPLETE — one or more of the ten unit rules is absent"
    warn "one or more of the ten unit rules is absent"
    FAIL=1
fi

log ""
log "-- policies unchanged (must still read as the baseline above)"
ip6tables -S | grep -E '^-P ' || true

log ""
log "-- send test"
AFTER_SEND=$(send_probe 2>&1) || true
log "   $AFTER_SEND"
case "$AFTER_SEND" in
    "OK 12 $NIC"|"OK 12"*) log "   send = OK 12" ;;
    *) warn "send did not return OK 12 — Phase 1 is NOT done"; FAIL=1 ;;
esac

# -------------------------------------------------------------- 6. evidence
mkdir -p "$EVIDENCE_DIR"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE=$(mktemp "$EVIDENCE_DIR/phase1-${SKU:-$NIC}-$STAMP.XXXXXX")
{
    printf 'CueRated Matter — Phase 1 host unit\n'
    printf 'timestamp_utc : %s\n' "$STAMP"
    printf 'sku           : %s\n' "${SKU:-unrecorded}"
    printf 'board         : %s\n' "$BOARD_LABEL"
    printf 'board_key     : %s\n' "$BOARD_KEY"
    printf 'dt_model      : %s\n' "$BOARD_MODEL"
    printf 'soc_arch      : %s / %s\n' "$BOARD_SOC" "$ARCH"
    printf 'kernel        : %s\n' "$KERNEL"
    printf 'ip6tables     : %s\n' "$IP6T_VER"
    printf 'ipv4          : %s\n' "$IPV4"
    printf 'mac           : %s\n' "$MAC"
    printf 'nic           : %s\n' "$NIC"
    printf 'fe80          : %s\n' "$LINK_LOCAL"
    printf 'nic_wait_s    : %s\n' "$NIC_WAIT"
    printf 'wait_online   : %s\n' "$WAIT_ONLINE"
    printf 'disable_ipv6  : all=%s default=%s %s=%s\n' "$D_ALL" "$D_DEF" "$NIC" "$D_NIC"
    printf 'posture       : %s\n' "$POSTURE"
    printf 'send_before   : %s\n' "$BEFORE_SEND"
    printf 'send_after    : %s\n' "$AFTER_SEND"
    printf 'unit_enabled  : %s\n' "$ENABLED"
    printf 'unit_active   : %s\n' "$ACTIVE"
    printf 'nic_rules     : %s lines matching %s — %s\n' "$RULES" "$NIC" "$RULES_VERDICT"
    printf 'matter_rebuilt: no (Phase 1 never touches the container)\n'
    printf '\n-- ip6tables policies --\n'
    ip6tables -S | grep -E '^-P ' || true
    printf '\n-- %s rules --\n' "$NIC"
    show_nic_rules
} > "$EVIDENCE"
log ""
log "evidence written: $EVIDENCE"

# ---------------------------------------------------------------- 6. verdict
if [ "$FAIL" -ne 0 ]; then
    step "PHASE 1 FAILED"
    log "Do NOT build or recreate CueRated Matter on this box."
    log "Shipping build/v1.0.0 onto a box that still returns EPERM only gives a dark bridge (#31 holds Matter)."
    log "Fix the host, re-run: systemctl restart cue-matter-ipv6-rules.service, then re-run this script."
    exit 3
fi

python3 "$RECOVER" commit --inherited-lock 9
TX_ACTIVE=0
step "PHASE 1 DONE (guide 3.5)"
log "  [x] $SBIN present, mode 0755"
log "  [x] unit enabled and active"
log "  [x] CUE_LAN_NIC=$NIC pinned for THIS box ($BOARD_LABEL)"
log "  [x] $EXPECTED_RULES NIC-scoped rules present"
log "  [x] send test OK 12"
log "  [x] Matter container NOT rebuilt"

step "Next: compose pin only — do NOT recreate Matter now (guide 3.4)"
cat <<COMPOSE_EOF
network_mode: host
environment:
  MDNS_NETWORK_INTERFACE: \${CUE_LAN_NIC:-$NIC}
COMPOSE_EOF

log ""
log "Then, and only then, Phase 2: build/v1.0.0 (guide 4)."
log "Pairing stays a later Founder dispatch. Never pair to debug IPv6."
log ""
log "Reboot check on this board:  systemctl status cue-matter-ipv6-rules.service"
log "If a firewall reload flushes the rules: systemctl restart cue-matter-ipv6-rules.service"
log "Manual run needs the pin:   CUE_LAN_NIC=$NIC $SBIN"
log "Do NOT: ufw disable/enable, IPV6=yes, flip DROP<->ACCEPT, docker pull cue_matter."
