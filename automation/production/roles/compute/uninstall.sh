#!/usr/bin/env bash
# =============================================================================
# OpenG2P Compute Node — Uninstall
# =============================================================================
# Reverses everything roles/compute/phase{1,2,3}.sh installed:
#   - RKE2 (via rke2-uninstall.sh — removes cluster, etcd, all helm releases:
#     Istio, Rancher, Keycloak, monitoring, logging)
#   - kubectl / helm / istioctl / helmfile binaries
#   - NFS client mount, sysctl tweaks, /etc/hosts managed block
#   - ufw rules, state markers
#
# Keeps generic OS tools. Idempotent.
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

    log_banner "Compute — Uninstall" "RKE2 + tools + NFS client + state"

    # ── 1. RKE2 uninstall (the heavy lift) ──────────────────────────────
    # rke2-uninstall.sh wipes the K8s cluster, containerd state, CNI, all
    # in-cluster workloads (Istio, Rancher, Keycloak, monitoring, logging),
    # /var/lib/rancher, /etc/rancher, and the rke2 binary.
    log_step "C-U.1" "Run rke2-uninstall.sh (wipes cluster, etcd, all helm releases)"
    if systemctl list-unit-files rke2-server.service 2>/dev/null | grep -q rke2-server; then
        systemctl stop rke2-server 2>/dev/null || true
    fi
    if   [[ -x /usr/local/bin/rke2-uninstall.sh ]]; then
        /usr/local/bin/rke2-uninstall.sh 2>/dev/null || true
        log_success "  /usr/local/bin/rke2-uninstall.sh executed"
    elif [[ -x /usr/bin/rke2-uninstall.sh ]]; then
        /usr/bin/rke2-uninstall.sh 2>/dev/null || true
        log_success "  /usr/bin/rke2-uninstall.sh executed"
    else
        log_info "  rke2-uninstall.sh not present — RKE2 probably never installed"
    fi
    # Belt-and-braces: directory leftovers
    rm -rf /var/lib/rancher /etc/rancher

    # ── 2. Remove user-installed K8s tooling ───────────────────────────
    log_step "C-U.2" "Remove kubectl / helm / istioctl / helmfile binaries"
    rm -f /usr/local/bin/kubectl /usr/local/bin/helm /usr/local/bin/istioctl /usr/local/bin/helmfile
    # Helm plugin store (root's HELM_DATA_HOME)
    rm -rf /root/.local/share/helm /root/.cache/helm /root/.config/helm 2>/dev/null || true
    log_success "  binaries removed"

    # ── 3. NFS client teardown ─────────────────────────────────────────
    log_step "C-U.3" "Unmount NFS and remove client packages"
    local nfs_mount=$(cfg nfs_mount_path "/mnt/nfs")
    if mountpoint -q "$nfs_mount" 2>/dev/null; then
        umount -f "$nfs_mount" 2>/dev/null || umount -l "$nfs_mount" 2>/dev/null || true
        log_info "  unmounted ${nfs_mount}"
    fi
    if [[ -f /etc/fstab ]]; then
        # Remove the openg2p NFS line we added (matches by mount path).
        sed -i "\#${nfs_mount}#d" /etc/fstab
    fi
    [[ -d "$nfs_mount" ]] && rmdir "$nfs_mount" 2>/dev/null || true
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y nfs-common 2>/dev/null || true
    log_success "  NFS client torn down"

    # ── 4. Revert /etc/hosts managed block ─────────────────────────────
    log_step "C-U.4" "Remove /etc/hosts openg2p-managed block"
    if [[ -f /etc/hosts ]]; then
        sed -i '/# openg2p-managed-begin/,/# openg2p-managed-end/d' /etc/hosts
    fi
    log_success "  /etc/hosts cleaned"

    # ── 5. Revert sysctl tweaks ────────────────────────────────────────
    log_step "C-U.5" "Revert inotify sysctl tweaks"
    if [[ -f /etc/sysctl.conf ]]; then
        sed -i '/^fs\.inotify\.max_user_watches=524288[[:space:]]*$/d'  /etc/sysctl.conf
        sed -i '/^fs\.inotify\.max_user_instances=1024[[:space:]]*$/d' /etc/sysctl.conf
    fi
    log_success "  sysctl reverted (defaults restored on next boot)"

    # ── 6. Remove profile snippet ──────────────────────────────────────
    rm -f /etc/profile.d/openg2p-k8s.sh

    # ── 7. Reset host firewall ─────────────────────────────────────────
    log_step "C-U.6" "Reset ufw"
    if command -v ufw >/dev/null 2>&1; then
        ufw --force reset 2>/dev/null || true
        ufw --force disable 2>/dev/null || true
        log_success "  ufw reset + disabled"
    fi

    # ── 8. Clear state markers + openg2p dirs ──────────────────────────
    log_step "C-U.7" "Clear deploy-state markers and /etc/openg2p"
    rm -rf /var/lib/openg2p
    rm -rf /etc/openg2p
    log_success "  state cleared"

    apt-get autoremove -y 2>/dev/null || true

    echo ""
    log_success "Compute uninstall complete."
}

main "$@"
