#!/usr/bin/env bash
# =============================================================================
# OpenG2P Infrastructure Uninstall
# =============================================================================
# Completely removes the OpenG2P base infrastructure: RKE2 cluster, all Helm
# releases, Wireguard VPN, dnsmasq, Nginx, NFS, TLS certificates, and all
# state markers.
#
# WARNING: This is DESTRUCTIVE and IRREVERSIBLE. The entire Kubernetes cluster
# and all data will be permanently deleted. All environments on this cluster
# will be destroyed.
#
# Usage:
#   sudo ./openg2p-infra-uninstall.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/utils.sh"

# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h) show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1" \
                          "This script takes no arguments" \
                          "Run with --help for usage" \
                          "$0 --help"
                exit 1
                ;;
        esac
    done
}

show_help() {
    cat <<'EOF'
OpenG2P Infrastructure Uninstall
===================================

Usage:
  sudo ./openg2p-infra-uninstall.sh

This script completely removes the OpenG2P base infrastructure:
  - RKE2 Kubernetes cluster (all pods, services, volumes)
  - All Helm releases across all namespaces
  - Wireguard VPN server and peer configs
  - dnsmasq DNS server
  - Nginx reverse proxy
  - NFS server and CSI driver
  - TLS certificates (local CA and Let's Encrypt)
  - All deployment state markers

WARNING: This is DESTRUCTIVE and IRREVERSIBLE. ALL data will be lost.
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    check_root "$@"

    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  WARNING: COMPLETE INFRASTRUCTURE TEARDOWN                  ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║${NC}  This will ${BOLD}PERMANENTLY DELETE${NC} the entire OpenG2P            "
    echo -e "${RED}║${NC}  infrastructure on this machine:                              "
    echo -e "${RED}║${NC}                                                              ${RED}║${NC}"
    echo -e "${RED}║${NC}    • RKE2 Kubernetes cluster and ALL workloads               ${RED}║${NC}"
    echo -e "${RED}║${NC}    • ALL environments and their data                         ${RED}║${NC}"
    echo -e "${RED}║${NC}    • Rancher, Keycloak, Istio, monitoring                    ${RED}║${NC}"
    echo -e "${RED}║${NC}    • Wireguard VPN server and ALL peer configs               ${RED}║${NC}"
    echo -e "${RED}║${NC}    • dnsmasq DNS server                                      ${RED}║${NC}"
    echo -e "${RED}║${NC}    • Nginx reverse proxy and TLS certificates                ${RED}║${NC}"
    echo -e "${RED}║${NC}    • NFS server exports                                      ${RED}║${NC}"
    echo -e "${RED}║${NC}    • All deployment state markers                            ${RED}║${NC}"
    echo -e "${RED}║${NC}                                                              ${RED}║${NC}"
    echo -e "${RED}║  This action is IRREVERSIBLE. ALL DATA WILL BE LOST.         ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "Type 'DELETE EVERYTHING' to confirm: " CONFIRM
    if [[ "$CONFIRM" != "DELETE EVERYTHING" ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""

    log_info "Starting complete infrastructure teardown..."

    # ── Step 1: Uninstall all Helm releases ─────────────────────────────
    if [[ -f /etc/rancher/rke2/rke2.yaml ]]; then
        export KUBECONFIG="/etc/rancher/rke2/rke2.yaml"
        export PATH="$PATH:/var/lib/rancher/rke2/bin"

        log_info "Uninstalling all Helm releases..."
        local namespaces
        namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        for ns in $namespaces; do
            local releases
            releases=$(helm list -n "$ns" -q 2>/dev/null || true)
            for release in $releases; do
                log_info "  Uninstalling ${release} in ${ns}..."
                helm uninstall "$release" -n "$ns" --wait --timeout 2m 2>/dev/null || true
            done
        done
        log_success "Helm releases uninstalled."
    else
        log_info "No kubeconfig found — skipping Helm cleanup."
    fi

    # ── Step 2: Stop and uninstall RKE2 ─────────────────────────────────
    log_info "Stopping and uninstalling RKE2..."

    if systemctl is-active --quiet rke2-server 2>/dev/null; then
        systemctl stop rke2-server
        log_info "RKE2 server stopped."
    fi
    systemctl disable rke2-server 2>/dev/null || true

    # RKE2 provides its own uninstall script
    if [[ -x /usr/local/bin/rke2-uninstall.sh ]]; then
        log_info "Running RKE2 uninstall script..."
        /usr/local/bin/rke2-uninstall.sh 2>/dev/null || true
        log_success "RKE2 uninstalled."
    elif [[ -x /usr/bin/rke2-uninstall.sh ]]; then
        /usr/bin/rke2-uninstall.sh 2>/dev/null || true
        log_success "RKE2 uninstalled."
    else
        log_warn "RKE2 uninstall script not found. Cleaning up manually..."
        rm -rf /etc/rancher /var/lib/rancher /var/lib/kubelet
        rm -f /usr/local/bin/rke2* /usr/local/bin/kubectl /usr/local/bin/helm
    fi

    # ── Step 3: Stop and remove Wireguard ───────────────────────────────
    log_info "Removing Wireguard VPN..."

    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        systemctl stop wg-quick@wg0
        systemctl disable wg-quick@wg0 2>/dev/null || true
    fi
    rm -rf /etc/wireguard
    log_success "Wireguard removed."

    # ── Step 4: Stop and remove dnsmasq ─────────────────────────────────
    log_info "Removing dnsmasq..."

    if systemctl is-active --quiet dnsmasq 2>/dev/null; then
        systemctl stop dnsmasq
        systemctl disable dnsmasq 2>/dev/null || true
    fi
    rm -f /etc/dnsmasq.d/openg2p.conf
    rm -f /var/log/dnsmasq-openg2p.log

    # Restore systemd-resolved if we disabled its stub listener
    if [[ -f /etc/systemd/resolved.conf.d/openg2p-dnsmasq.conf ]]; then
        rm -f /etc/systemd/resolved.conf.d/openg2p-dnsmasq.conf
        systemctl restart systemd-resolved 2>/dev/null || true
        log_info "systemd-resolved restored."
    fi
    log_success "dnsmasq removed."

    # ── Step 5: Stop and remove Nginx ───────────────────────────────────
    log_info "Removing Nginx configs..."

    rm -f /etc/nginx/sites-enabled/openg2p*.conf
    rm -f /etc/nginx/sites-available/openg2p*.conf
    if nginx -t &>/dev/null; then
        systemctl reload nginx 2>/dev/null || true
    fi
    log_success "Nginx configs removed."

    # ── Step 6: Remove NFS exports ──────────────────────────────────────
    log_info "Removing NFS exports..."

    # Remove openg2p NFS exports
    if [[ -f /etc/exports ]]; then
        sed -i '/openg2p/d' /etc/exports 2>/dev/null || true
        exportfs -ra 2>/dev/null || true
    fi
    # Don't delete /srv/nfs — user may have other NFS exports
    log_success "NFS exports removed."

    # ── Step 7: Remove TLS certificates ─────────────────────────────────
    log_info "Removing TLS certificates..."

    rm -rf /etc/openg2p/ca
    rm -rf /etc/openg2p/certs
    # Don't remove Let's Encrypt certs — they may be used by other services
    # and certbot manages them.
    log_success "Local CA and certificates removed."

    # ── Step 8: Clean up state and logs ─────────────────────────────────
    log_info "Cleaning up state and deployment markers..."

    rm -rf /var/lib/openg2p/deploy-state
    log_success "State markers removed."

    # ── Step 9: Remove hostname from /etc/hosts ─────────────────────────
    local vm_hostname
    vm_hostname=$(hostname 2>/dev/null || true)
    if [[ -n "$vm_hostname" ]]; then
        sed -i "/127.0.0.1 ${vm_hostname}/d" /etc/hosts 2>/dev/null || true
    fi

    # ── Done ────────────────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║   Infrastructure teardown complete.                          ║${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║${NC}   The following were removed:                                ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}     • RKE2 Kubernetes cluster                                ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}     • Wireguard VPN                                          ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}     • dnsmasq DNS                                            ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}     • Nginx configs                                          ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}     • NFS exports                                            ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}     • TLS certificates                                      ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}     • All deployment state                                   ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}   The VM is ready for a fresh installation.                  ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

main "$@"
