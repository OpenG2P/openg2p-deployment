#!/usr/bin/env bash
# =============================================================================
# OpenG2P Remove-Node — laptop orchestrator
# =============================================================================
# Runs on your ADMIN LAPTOP. SSHes to a control-plane (primary) node and
# cordons / drains / deletes the target node via kubectl there.
#
# Usage:
#   ./openg2p-remove-node.sh --config add-node-config.yaml --node <node-name>
#   ./openg2p-remove-node.sh --config add-node-config.yaml --node worker --dry-run
#   ./openg2p-remove-node.sh --config add-node-config.yaml --node worker --yes
# =============================================================================

set -euo pipefail

trap '
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "" >&2
        echo "[FATAL] script exited with status ${rc} at line ${LINENO} (${BASH_COMMAND})" >&2
        echo "[FATAL] log: ${LOG_FILE:-<not set>}" >&2
    fi
    ssh_cleanup 2>/dev/null || true
' EXIT

if (( BASH_VERSINFO[0] < 4 )); then
    echo "[FATAL] bash 4+ required (detected ${BASH_VERSION})." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
NODE_NAME=""
DRAIN_TIMEOUT=300
SKIP_DRAIN=false
DRY_RUN=false
ASSUME_YES=false
LOG_FILE="${SCRIPT_DIR}/logs/remove-node-$(date '+%Y%m%d-%H%M%S').log"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/utils.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/ssh-utils.sh"

show_help() {
    cat <<'EOF'
OpenG2P Remove Node — drain and remove a node from the cluster
===============================================================

Runs on your LAPTOP. SSHes to a control-plane node and runs kubectl there.

Usage:
  ./openg2p-remove-node.sh --config add-node-config.yaml --node <node-name> [options]

Options:
  --config <file>     add-node-config.yaml (required — needs primary_ssh_*)
  --node <name>       Node to remove (as shown in 'kubectl get nodes')  [required]
  --timeout <sec>     Drain timeout in seconds (default: 300)
  --skip-drain        Skip cordon+drain
  --yes / -y          Skip the interactive confirmation prompt
  --dry-run           Print what would run; do not cordon, drain, or delete
  --help, -h          Show this help

Config keys used:
  primary_ssh_host / primary_ssh_user / primary_ssh_key
  (falls back to ssh_key for the key path if primary_ssh_key is blank)
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)     CONFIG_FILE="$2"; shift 2 ;;
            --node)       NODE_NAME="$2"; shift 2 ;;
            --timeout)    DRAIN_TIMEOUT="$2"; shift 2 ;;
            --skip-drain) SKIP_DRAIN=true; shift ;;
            --yes|-y)     ASSUME_YES=true; shift ;;
            --dry-run)    DRY_RUN=true; shift ;;
            --help|-h)    show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1" "" "Run with --help"
                exit 1
                ;;
        esac
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        log_error "No config file specified" "--config is required" \
                  "$0 --config add-node-config.yaml --node <name>"
        exit 1
    fi
    if [[ -z "$NODE_NAME" ]]; then
        log_error "Missing required flag: --node" \
                  "You must specify the node to remove" \
                  "From primary: kubectl get nodes"
        exit 1
    fi
    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
    export DRY_RUN
}

print_cleanup_guide() {
    local node="$1"
    cat <<EOF

=============================================================================
  NODE REMOVED FROM CLUSTER: ${node}
=============================================================================

FINAL MANUAL STEP — clean up the removed node itself (SSH to it):

    sudo systemctl stop rke2-agent 2>/dev/null || true
    sudo systemctl stop rke2-server 2>/dev/null || true
    sudo /usr/local/bin/rke2-killall.sh 2>/dev/null || true
    sudo /usr/local/bin/rke2-uninstall.sh 2>/dev/null || true
    sudo rm -rf /var/lib/openg2p /etc/rancher /var/lib/rancher

If provisioned with AWS add-node:
    cd aws && ./openg2p-aws-destroy.sh --config aws-config.yaml

=============================================================================
EOF
}

main() {
    parse_args "$@"

    mkdir -p "${SCRIPT_DIR}/logs"
    exec > >(tee -a "$LOG_FILE") 2>&1

    log_banner "OpenG2P Remove Node" "Laptop → primary kubectl: ${NODE_NAME}"
    log_info "Config: ${CONFIG_FILE}"
    log_info "Log:    ${LOG_FILE}"

    load_config "$CONFIG_FILE"
    load_provision_overlay "$CONFIG_FILE" "$SCRIPT_DIR"

    if [[ -z "$(cfg primary_ssh_host)" ]]; then
        log_error "primary_ssh_host is blank" \
                  "Remove-node needs SSH to a control-plane node" \
                  "Set primary_ssh_host / primary_ssh_user / primary_ssh_key in add-node-config.yaml"
        exit 1
    fi

    ssh_init
    ssh_probe primary || exit 1

    # Helpers that run kubectl on the primary
    k() {
        ssh_run primary "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml; export PATH=\"\$PATH:/var/lib/rancher/rke2/bin\"; $*"
    }

    if ! k "kubectl get node $(printf '%q' "$NODE_NAME")" >/dev/null 2>&1; then
        log_error "Node '${NODE_NAME}' not found in the cluster" \
                  "The node name does not match any existing node" \
                  "List nodes from primary: kubectl get nodes"
        exit 1
    fi

    local is_cp
    is_cp=$(k "kubectl get node $(printf '%q' "$NODE_NAME") -o jsonpath='{.metadata.labels.node-role\\.kubernetes\\.io/control-plane}'" 2>/dev/null || true)
    if [[ "$is_cp" == "true" ]]; then
        local cp_count
        cp_count=$(k "kubectl get nodes -l node-role.kubernetes.io/control-plane=true --no-headers 2>/dev/null | wc -l" | tr -d '[:space:]')
        if [[ "${cp_count:-0}" -le 1 ]]; then
            log_error "Refusing to remove the only control-plane node" \
                      "'${NODE_NAME}' is the last remaining control-plane" \
                      "Add another control-plane first"
            exit 1
        fi
        log_warn "Removing a control-plane node (${cp_count} → $((cp_count - 1)))."
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        if [[ "$SKIP_DRAIN" == "true" ]]; then
            log_info "[dry-run] would skip cordon+drain (--skip-drain)"
        else
            log_info "[dry-run] would: kubectl cordon ${NODE_NAME}  (on primary)"
            log_info "[dry-run] would: kubectl drain ${NODE_NAME} --timeout=${DRAIN_TIMEOUT}s"
        fi
        log_info "[dry-run] would: kubectl delete node ${NODE_NAME}"
        log_success "Dry-run complete — nothing changed."
        return 0
    fi

    cat <<EOF

╔════════════════════════════════════════════════════════════════════╗
║  About to REMOVE this node from the RKE2 cluster                   ║
╠════════════════════════════════════════════════════════════════════╣
║  Node:          ${NODE_NAME}
║  Action:        cordon → drain → kubectl delete node
║  Via:           primary control-plane SSH
╚════════════════════════════════════════════════════════════════════╝

EOF

    if [[ "$ASSUME_YES" != "true" ]]; then
        log_warn "This removes '${NODE_NAME}' from your existing RKE2 cluster."
        local answer
        if [[ -r /dev/tty ]]; then
            read -rp "Are you sure you want to remove node '${NODE_NAME}' from the existing RKE2 cluster? [yes/no]: " answer </dev/tty
        else
            read -rp "Are you sure you want to remove node '${NODE_NAME}' from the existing RKE2 cluster? [yes/no]: " answer
        fi
        case "${answer,,}" in
            yes|y) ;;
            *)
                log_info "Aborted — node was not removed."
                exit 0
                ;;
        esac
    else
        log_info "--yes set; skipping confirmation."
    fi

    if [[ "$SKIP_DRAIN" != "true" ]]; then
        log_info "Cordoning ${NODE_NAME}..."
        k "kubectl cordon $(printf '%q' "$NODE_NAME")"
        log_info "Draining ${NODE_NAME} (timeout: ${DRAIN_TIMEOUT}s)..."
        if ! k "kubectl drain $(printf '%q' "$NODE_NAME") --ignore-daemonsets --delete-emptydir-data --force --timeout=${DRAIN_TIMEOUT}s"; then
            log_error "Drain did not complete cleanly" \
                      "Some pods could not be evicted within the timeout" \
                      "Inspect pods on the node and retry, or use --skip-drain"
            exit 1
        fi
        log_success "Drain complete."
    else
        log_warn "Skipping cordon+drain (--skip-drain)."
    fi

    log_info "Deleting node object..."
    k "kubectl delete node $(printf '%q' "$NODE_NAME")"
    log_success "Node '${NODE_NAME}' removed from the cluster."
    print_cleanup_guide "$NODE_NAME"
}

main "$@"
