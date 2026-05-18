#!/usr/bin/env bash
# =============================================================================
# OpenG2P 3-Node Production — Preflight Check (runs on each node)
# =============================================================================
# Per-node validation of: OS, resources (CPU/RAM/disk), SSD type, internet
# egress, configured-IP-matches-host, and port-conflict.
#
# Invoked by the laptop orchestrator early in the run, on all 3 nodes in
# parallel, BEFORE any installation work happens. Hard-fail thresholds match
# the OpenG2P resource-requirements doc:
#
#   role     CPU   RAM    Disk
#   storage   8    32 GB  256 GB
#   compute  16    64 GB  128 GB
#   rp        4    16 GB   64 GB
#
# Exit code:  0 = all checks pass (warnings allowed),  1 = any FAIL.
# Output:     human-readable lines, [PASS]/[WARN]/[FAIL] prefix.
# =============================================================================

set -uo pipefail   # NOT -e — keep running even when checks fail

ROLE=""
CONFIG_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)   ROLE="$2";        shift 2 ;;
        --config) CONFIG_FILE="$2"; shift 2 ;;
        *)        shift ;;
    esac
done

if [[ -z "$ROLE" || -z "$CONFIG_FILE" ]]; then
    echo "[FAIL] preflight invocation: --role and --config are required"
    exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${DIR}/utils.sh"

[[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="$(pwd)/${CONFIG_FILE}"
load_config "$CONFIG_FILE"

FAILS=0
WARNS=0

emit_pass() { echo "[PASS] $1"; }
emit_warn() { echo "[WARN] $1"; WARNS=$((WARNS + 1)); }
emit_fail() { echo "[FAIL] $1"; FAILS=$((FAILS + 1)); }

# ─────────────────────────────────────────────────────────────────────────
# OS
# ─────────────────────────────────────────────────────────────────────────
check_os() {
    if [[ ! -f /etc/os-release ]]; then
        emit_fail "OS detection: /etc/os-release missing"
        return
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        emit_fail "OS: ${PRETTY_NAME:-$ID} (need Ubuntu 24.04)"
        return
    fi
    local major="${VERSION_ID%%.*}"
    if [[ "$major" -lt 24 ]]; then
        emit_fail "Ubuntu ${VERSION_ID} (need 24.04 or later)"
        return
    fi
    emit_pass "OS: Ubuntu ${VERSION_ID}"
}

# ─────────────────────────────────────────────────────────────────────────
# CPU / RAM / disk size / disk type
# ─────────────────────────────────────────────────────────────────────────
check_resources() {
    local req_cpu req_ram req_disk
    case "$ROLE" in
        storage) req_cpu=8;  req_ram=32; req_disk=256 ;;
        compute) req_cpu=16; req_ram=64; req_disk=128 ;;
        rp)      req_cpu=2;  req_ram=4;  req_disk=64  ;;
        *) emit_fail "Unknown role '${ROLE}'"; return ;;
    esac

    # CPU
    local cpu
    cpu=$(nproc 2>/dev/null || echo 0)
    if [[ "$cpu" -lt "$req_cpu" ]]; then
        emit_fail "CPU: ${cpu} vCPU (need ≥${req_cpu})"
    else
        emit_pass "CPU: ${cpu} vCPU"
    fi

    # RAM — compare in MB to avoid integer-truncation false fails.
    # /proc/meminfo MemTotal on a "4 GiB" VM is typically ~3793 MB (the
    # kernel reserves space). With kB→GB integer division this would be 3,
    # and a 4-min check would falsely fail. We allow 10% slack and compare
    # in MB.
    local ram_kb ram_mb req_ram_mb ram_min_mb
    ram_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
    ram_kb=${ram_kb:-0}
    ram_mb=$((ram_kb / 1024))
    req_ram_mb=$((req_ram * 1024))
    ram_min_mb=$(( req_ram_mb * 9 / 10 ))
    if [[ "$ram_mb" -lt "$ram_min_mb" ]]; then
        emit_fail "RAM: ${ram_mb} MB (need ≥${req_ram} GB ≈ ${req_ram_mb} MB)"
    else
        emit_pass "RAM: ${ram_mb} MB (~$(( (ram_mb + 512) / 1024 )) GB)"
    fi

    # Root disk size — allow 20% slack (cloud images sometimes ship smaller and
    # you resize the volume but not the FS, etc.)
    local disk_gb disk_min
    disk_gb=$(df -BG / 2>/dev/null | tail -1 | awk '{print $2}' | tr -d 'G')
    disk_gb=${disk_gb:-0}
    disk_min=$((req_disk - req_disk / 5))
    if [[ "$disk_gb" -lt "$disk_min" ]]; then
        emit_fail "Disk: ${disk_gb} GB on / (need ≥${req_disk})"
    else
        emit_pass "Disk: ${disk_gb} GB on /"
    fi

    # SSD detection (best-effort — cloud volumes sometimes don't expose this)
    local root_dev rotational_file rotational
    root_dev=$(findmnt -no SOURCE / 2>/dev/null | sed 's/[0-9]*$//' | sed 's|/dev/||' | sed 's|mapper/||' | sed 's/-part.*//' | sed 's/p$//')
    rotational_file="/sys/block/${root_dev}/queue/rotational"
    if [[ -f "$rotational_file" ]]; then
        rotational=$(cat "$rotational_file" 2>/dev/null)
        if [[ "$rotational" == "1" ]]; then
            emit_warn "Disk type: rotational HDD (SSD strongly recommended)"
        else
            emit_pass "Disk type: SSD"
        fi
    else
        emit_pass "Disk type: indeterminate (typical for cloud VMs — assumed SSD)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# Internet egress (apt + RKE2 + helm charts all need outbound HTTPS)
# ─────────────────────────────────────────────────────────────────────────
check_internet() {
    if curl -sSI --max-time 10 https://get.rke2.io >/dev/null 2>&1; then
        emit_pass "Internet egress (https://get.rke2.io reachable)"
    else
        emit_fail "Internet egress: cannot reach https://get.rke2.io"
        emit_fail "  install needs to download RKE2, helm charts, and apt packages"
    fi
}

# ─────────────────────────────────────────────────────────────────────────
# Configured private IP is actually present on this host
# ─────────────────────────────────────────────────────────────────────────
check_ip_matches() {
    # Collect every IP the role is expected to have bound. Storage/compute
    # have a single private IP; RP has TWO NICs (public + internal).
    local -a expected_ips=()
    case "$ROLE" in
        storage) expected_ips+=("$(cfg storage_private_ip)") ;;
        compute) expected_ips+=("$(cfg compute_private_ip)") ;;
        rp)
            # New keys preferred; legacy rp_private_ip is the fallback alias.
            local pub int
            pub=$(cfg rp_public_ip)
            int=$(cfg rp_internal_ip)
            [[ -z "$int" ]] && int=$(cfg rp_private_ip)
            [[ -n "$pub" ]] && expected_ips+=("$pub")
            [[ -n "$int" ]] && expected_ips+=("$int")
            ;;
    esac

    if [[ ${#expected_ips[@]} -eq 0 ]]; then
        emit_warn "IP check skipped — no expected IPs in config for role ${ROLE}"
        return
    fi

    local actual
    actual=$(ip -4 -br addr 2>/dev/null | awk '$1!="lo"{print $3}' | paste -sd, - 2>/dev/null)

    local ip
    for ip in "${expected_ips[@]}"; do
        if ip -4 addr 2>/dev/null | grep -q "inet ${ip}/"; then
            emit_pass "IP: ${ip} bound on this host"
        else
            emit_fail "IP ${ip} (configured for ${ROLE}) NOT bound on this host"
            emit_fail "  this host has: ${actual:-<none>}"
            if [[ "$ROLE" == "rp" ]]; then
                emit_fail "  → RP needs TWO NICs: rp_public_ip (Wireguard) + rp_internal_ip (admin Nginx)"
                emit_fail "  → see https://docs.openg2p.org/operations/deployment/automation/three-node-automation#id-2.-two-network-interfaces-on-the-reverse-proxy-vm"
            else
                emit_fail "  → wrong node targeted, or *_private_ip is wrong"
            fi
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────
# Port conflicts — services we'll claim, that already have a listener
# ─────────────────────────────────────────────────────────────────────────
check_ports() {
    local ports=()
    case "$ROLE" in
        storage) ports=(2049 "$(cfg postgres_port 5432)") ;;
        compute) ports=(6443 9345 10250 30080) ;;
        rp)      ports=(80 443 53 "$(cfg wg_port 51820)") ;;
    esac

    for p in "${ports[@]}"; do
        local match
        match=$(ss -tlnu 2>/dev/null | awk -v port=":${p}$" '$5 ~ port {print $5; exit}')
        if [[ -n "$match" ]]; then
            local who
            who=$(ss -tlnup 2>/dev/null | awk -v port=":${p}$" '$5 ~ port {print $7; exit}')
            emit_warn "Port ${p}: already in use (${who:-unknown}) — re-runs are safe; first install may conflict"
        else
            emit_pass "Port ${p}: free"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────
echo "========== preflight: ${ROLE} on $(hostname) =========="
check_os
check_resources
check_internet
check_ip_matches
check_ports
echo ""
echo "Summary: ${FAILS} fail, ${WARNS} warn"
exit $(( FAILS > 0 ? 1 : 0 ))
