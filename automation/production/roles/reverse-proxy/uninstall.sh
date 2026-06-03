#!/usr/bin/env bash
# =============================================================================
# OpenG2P Reverse Proxy Node — Uninstall
# =============================================================================
# Reverses everything roles/reverse-proxy/phase1.sh installed on this node:
# Wireguard, Nginx admin server blocks, customer certs, ufw rules, ip_forward
# sysctl, state markers. Keeps generic OS tools (curl, jq, openssl, etc.).
#
# Idempotent — every step is safe to run on a partially-installed or already-
# clean node. Designed to be invoked by openg2p-prod-uninstall.sh on the laptop.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE=""
PURGE_DATA=false

source "${WORK_DIR}/lib/shared/utils.sh"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)      CONFIG_FILE="$2"; shift 2 ;;
            --purge-data)  PURGE_DATA=true;  shift ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done
    [[ -n "$CONFIG_FILE" && "$CONFIG_FILE" != /* ]] && CONFIG_FILE="${WORK_DIR}/${CONFIG_FILE}"
}

main() {
    parse_args "$@"
    check_root
    [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]] && load_config "$CONFIG_FILE" || true

    log_banner "Reverse Proxy — Uninstall" "Wireguard + Nginx + certs + state"

    # ── 1. Stop services ────────────────────────────────────────────────
    log_step "RP-U.1" "Stop Wireguard and Nginx"
    if systemctl list-unit-files 'wg-quick@*' 2>/dev/null | grep -q wg-quick; then
        systemctl stop  wg-quick@wg0 2>/dev/null || true
        systemctl disable wg-quick@wg0 2>/dev/null || true
        log_info "  wg-quick@wg0 stopped/disabled"
    fi
    if systemctl list-unit-files nginx.service 2>/dev/null | grep -q nginx; then
        systemctl stop  nginx 2>/dev/null || true
        systemctl disable nginx 2>/dev/null || true
        log_info "  nginx stopped/disabled"
    fi

    # ── 2. Purge packages installed by phase1 ──────────────────────────
    # Keep generic tools (curl, jq, openssl, etc.) — they're useful regardless.
    log_step "RP-U.2" "Purge wireguard-tools and nginx"
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y wireguard-tools nginx nginx-common nginx-core 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    log_success "  packages purged"

    # ── 3. Remove configuration and data ───────────────────────────────
    log_step "RP-U.3" "Remove configs (wireguard, nginx, certs)"
    rm -rf /etc/wireguard
    rm -rf /etc/openg2p/certs
    rm -f  /etc/nginx/sites-available/openg2p-admin.conf
    rm -f  /etc/nginx/sites-enabled/openg2p-admin.conf
    # nginx pkg dirs are gone with purge; defensive cleanup
    rm -rf /etc/nginx 2>/dev/null || true
    log_success "  configs removed"

    # ── 4. Revert sysctl ip_forward (best-effort) ──────────────────────
    log_step "RP-U.4" "Revert ip_forward sysctl"
    if [[ -f /etc/sysctl.conf ]]; then
        # Remove the line we added; harmless if absent.
        sed -i '/^net\.ipv4\.ip_forward=1[[:space:]]*$/d' /etc/sysctl.conf
    fi
    sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
    log_success "  ip_forward reverted"

    # ── 5. Reset host firewall ─────────────────────────────────────────
    # wg-quick's PostDown should have removed the MASQUERADE + FORWARD rules
    # when wg-quick@wg0 was stopped. ufw reset is a belt-and-braces wipe.
    log_step "RP-U.5" "Reset ufw"
    if command -v ufw >/dev/null 2>&1; then
        ufw --force reset 2>/dev/null || true
        ufw --force disable 2>/dev/null || true
        log_success "  ufw reset + disabled"
    fi
    # Clear any stale iptables MASQUERADE rule (in case PostDown didn't run).
    iptables -t nat -D POSTROUTING -s "$(cfg wg_subnet '10.15.0.0/16')" -j MASQUERADE 2>/dev/null || true

    # ── 6. Clear state markers ─────────────────────────────────────────
    log_step "RP-U.6" "Clear deploy-state markers"
    rm -rf /var/lib/openg2p/deploy-state
    # /etc/openg2p may also hold secrets, peer configs etc.
    rm -rf /etc/openg2p
    log_success "  state cleared"

    echo ""
    log_success "Reverse Proxy uninstall complete."
}

main "$@"
