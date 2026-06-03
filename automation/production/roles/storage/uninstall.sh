#!/usr/bin/env bash
# =============================================================================
# OpenG2P Storage Node — Uninstall
# =============================================================================
# Reverses everything roles/storage/phase1.sh installed: host PostgreSQL, NFS
# server, /etc/exports, secrets, ufw rules, state markers. Keeps generic tools.
#
# Data destruction policy:
#   • Default: stops + purges services and config; LEAVES /var/lib/postgresql
#     and the NFS export directory (typically /srv/nfs) on disk for safety.
#   • --purge-data: also deletes the Postgres data dir and NFS export contents.
#     There is no undo. Caller (openg2p-prod-uninstall.sh) gates this behind a
#     typed-name confirmation; here we just honour the flag.
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

    log_banner "Storage — Uninstall" "NFS server + host PostgreSQL + state"
    if [[ "$PURGE_DATA" == "true" ]]; then
        log_warn "--purge-data: PostgreSQL data dir AND NFS export contents will be DELETED."
    else
        log_info "Default mode: data dirs (/var/lib/postgresql, NFS export) will be preserved."
        log_info "Pass --purge-data to delete them too."
    fi

    # ── 1. Stop services ────────────────────────────────────────────────
    log_step "S-U.1" "Stop PostgreSQL and NFS server"
    if systemctl list-unit-files postgresql.service 2>/dev/null | grep -q postgresql; then
        systemctl stop  postgresql 2>/dev/null || true
        systemctl disable postgresql 2>/dev/null || true
        log_info "  postgresql stopped/disabled"
    fi
    if systemctl list-unit-files nfs-kernel-server.service 2>/dev/null | grep -q nfs-kernel-server; then
        systemctl stop  nfs-kernel-server 2>/dev/null || true
        systemctl disable nfs-kernel-server 2>/dev/null || true
        log_info "  nfs-kernel-server stopped/disabled"
    fi

    # ── 2. Purge packages ──────────────────────────────────────────────
    # postgresql purge removes the package + binaries; the data cluster under
    # /var/lib/postgresql is left in place by default (Debian/Ubuntu policy)
    # and is only removed if we also rm -rf below.
    log_step "S-U.2" "Purge postgresql and nfs-kernel-server"
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y 'postgresql*' nfs-kernel-server nfs-common 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
    log_success "  packages purged"

    # ── 3. Remove configs ──────────────────────────────────────────────
    log_step "S-U.3" "Remove /etc/exports and openg2p configs"
    # Clean only our managed lines from /etc/exports; if file is now empty, delete it.
    if [[ -f /etc/exports ]]; then
        # openg2p phase1 just writes /etc/exports with the NFS export line; safest
        # is to remove the file (apt purge removed nfs-kernel-server anyway).
        rm -f /etc/exports
    fi
    rm -rf /etc/openg2p
    log_success "  configs removed"

    # ── 4. Data destruction (gated by --purge-data) ────────────────────
    if [[ "$PURGE_DATA" == "true" ]]; then
        log_step "S-U.4" "Delete data dirs (--purge-data)"

        # NFS export — read from config if available, fall back to default
        local nfs_export
        nfs_export=$(cfg nfs_export_path "/srv/nfs")
        if [[ -d "$nfs_export" ]]; then
            rm -rf "$nfs_export"
            log_success "  removed NFS export dir: ${nfs_export}"
        fi

        # PostgreSQL data — Debian/Ubuntu standard location
        if [[ -d /var/lib/postgresql ]]; then
            rm -rf /var/lib/postgresql
            log_success "  removed /var/lib/postgresql"
        fi
        if [[ -d /etc/postgresql ]]; then
            rm -rf /etc/postgresql
            log_success "  removed /etc/postgresql"
        fi
    else
        log_step "S-U.4" "Preserving data dirs (no --purge-data)"
        log_info "  /var/lib/postgresql kept (Postgres data)"
        log_info "  $(cfg nfs_export_path '/srv/nfs') kept (NFS export contents)"
        log_info "  Run with --purge-data to delete them."
    fi

    # ── 5. Reset host firewall ─────────────────────────────────────────
    log_step "S-U.5" "Reset ufw"
    if command -v ufw >/dev/null 2>&1; then
        ufw --force reset 2>/dev/null || true
        ufw --force disable 2>/dev/null || true
        log_success "  ufw reset + disabled"
    fi

    # ── 6. Clear state markers ─────────────────────────────────────────
    log_step "S-U.6" "Clear deploy-state markers"
    rm -rf /var/lib/openg2p
    log_success "  state cleared"

    echo ""
    log_success "Storage uninstall complete."
}

main "$@"
