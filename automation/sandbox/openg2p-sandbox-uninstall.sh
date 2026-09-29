#!/usr/bin/env bash
# =============================================================================
# OpenG2P Sandbox — Infrastructure Uninstall (laptop orchestrator)
# =============================================================================
# Wipes the OpenG2P installation off the single VM WITHOUT destroying the VM
# itself. Use after a failed install when you want to start over without
# re-provisioning, or to tear down the sandbox for any reason.
#
# What it removes (on the VM via roles/infra/uninstall.sh):
#   • RKE2 + all in-cluster workloads (Istio, Rancher, monitoring, logging)
#   • All environments and their data
#   • Wireguard VPN, Nginx, NFS exports, TLS certs + acme.sh renewal cron
#   • On-box deployment state markers
#   • Laptop .state/ markers and ./artifacts/
#
# Keeps:
#   • The VM itself and AWS resources (use aws/openg2p-aws-destroy.sh for those)
#
# Usage (from your laptop):
#   ./openg2p-sandbox-uninstall.sh --config sandbox-config.yaml
#
# Advanced — run on-box directly:
#   sudo bash roles/infra/uninstall.sh
# =============================================================================

set -uo pipefail   # NOT -e — uninstall must continue even when bits are missing

trap '
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "" >&2
        echo "[FATAL] openg2p-sandbox-uninstall.sh exited with status ${rc} at line ${LINENO} (${BASH_COMMAND})" >&2
        echo "[FATAL] log: ${LOG_FILE:-<not set>}" >&2
    fi
    ssh_cleanup 2>/dev/null || true
' EXIT

if (( BASH_VERSINFO[0] < 4 )); then
    echo "[FATAL] bash 4 or later required (detected ${BASH_VERSION})." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
PROVISION_OUTPUT=""
ASSUME_YES=false
SKIP_SSH=false
LOG_FILE="${SCRIPT_DIR}/logs/openg2p-sandbox-uninstall-$(date '+%Y%m%d-%H%M%S').log"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../production/lib/shared/utils.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/ssh-utils.sh"

STATE_DIR="${SCRIPT_DIR}/.state"

# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)            CONFIG_FILE="$2";       shift 2 ;;
            --provision-output)  PROVISION_OUTPUT="$2";  shift 2 ;;
            --yes|-y)            ASSUME_YES=true;        shift ;;
            --skip-ssh)          SKIP_SSH=true;          shift ;;
            --help|-h)           show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1" \
                          "This flag is not recognized" \
                          "Run with --help to see available options" \
                          "$0 --help"
                exit 1
                ;;
        esac
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        log_error "No config file specified" \
                  "The --config flag is required" \
                  "Copy sandbox-config.example.yaml and provide it" \
                  "$0 --config sandbox-config.yaml"
        exit 1
    fi
    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi
}

show_help() {
    cat <<'EOF'
OpenG2P Sandbox — Infrastructure Uninstall
==============================================

Runs on your laptop. SSHes into the VM and runs roles/infra/uninstall.sh.
Does NOT destroy the VM (use aws/openg2p-aws-destroy.sh for AWS resources).

Usage:
  ./openg2p-sandbox-uninstall.sh --config sandbox-config.yaml [options]

Options:
  --config <file>            Path to sandbox-config.yaml (required)
  --provision-output <file>  Path to provision-output.yaml (auto-detect if blank)
  --yes / -y                 Skip the typed confirmation prompt
  --skip-ssh                 Skip remote teardown (laptop-side cleanup only)
  --help                     Show this help

After uninstall, reinstall with:
  ./openg2p-sandbox.sh --config sandbox-config.yaml
EOF
}

confirm() {
    local cluster_name
    cluster_name=$(cfg cluster_name)
    [[ -z "$cluster_name" ]] && cluster_name="openg2p"

    local host
    host=$(cfg ssh_host)
    if [[ -z "$host" ]]; then host=$(cfg public_ip); fi
    if [[ -z "$host" ]]; then host=$(cfg wireguard.endpoint); fi
    [[ -z "$host" ]] && host="<unknown>"

    echo ""
    log_warn "════════════════════════════════════════════════════════════════"
    log_warn " You are about to UNINSTALL OpenG2P infrastructure from:"
    log_warn "   • Node:  ${host}"
    log_warn ""
    log_warn " This removes the cluster, all environments, Wireguard, Nginx,"
    log_warn " NFS exports, TLS certs, and deployment state."
    log_warn " The VM itself remains provisioned and reachable."
    log_warn "════════════════════════════════════════════════════════════════"
    echo ""

    if [[ "$ASSUME_YES" == "true" ]]; then
        log_info "--yes set; skipping confirmation prompt."
        return 0
    fi

    local typed
    read -rp "Type cluster_name '${cluster_name}' to confirm: " typed
    if [[ "$typed" != "$cluster_name" ]]; then
        log_error "Confirmation mismatch. Aborting."
        exit 1
    fi
}

uninstall_remote() {
    log_step "UNINSTALL" "Stage bundle and run roles/infra/uninstall.sh on remote"

    if [[ "$SKIP_SSH" == "true" ]]; then
        log_info "[--skip-ssh] would stage and run: roles/infra/uninstall.sh --yes"
        return 0
    fi

    ssh_stage_sandbox "$SCRIPT_DIR" "$CONFIG_FILE" "$PROVISION_OUTPUT" ""

    local remote_cmd="cd ${REMOTE_WORK_DIR} && bash roles/infra/uninstall.sh --yes"
    log_info "Remote: ${remote_cmd}"
    if ssh_run "node" "$remote_cmd"; then
        log_success "  Remote infrastructure uninstall complete."
    else
        log_warn "  Remote uninstall reported errors (continuing with laptop cleanup)."
    fi
}

clear_laptop_state() {
    log_step "LAPTOP CLEANUP" "Clear .state/ markers and pulled artifacts"

    if [[ -d "$STATE_DIR" ]]; then
        rm -rf "$STATE_DIR"
        log_success "  removed ${STATE_DIR}"
    else
        log_info "  no .state/ to remove"
    fi

    local artifacts="${SCRIPT_DIR}/artifacts"
    if [[ -d "$artifacts" ]]; then
        rm -rf "$artifacts"
        log_success "  removed ${artifacts}"
    fi

    local setup_output="${SCRIPT_DIR}/setup-output"
    if [[ -d "$setup_output" ]]; then
        rm -rf "$setup_output"
        log_success "  removed ${setup_output}"
    fi
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    mkdir -p "${SCRIPT_DIR}/logs"

    log_banner "OpenG2P Sandbox — Infrastructure Uninstall" "In-place teardown · keeps VM"

    log_info "Config: ${CONFIG_FILE}"
    log_info "Log:    ${LOG_FILE}"
    echo ""

    load_config "$CONFIG_FILE"

    if [[ -z "$PROVISION_OUTPUT" ]]; then
        PROVISION_OUTPUT="$(dirname "$CONFIG_FILE")/provision-output.yaml"
    fi
    if [[ -f "$PROVISION_OUTPUT" ]]; then
        log_info "Loading provision-output overlay: ${PROVISION_OUTPUT}"
        load_config "$PROVISION_OUTPUT"
    else
        PROVISION_OUTPUT=""
        log_info "No provision-output.yaml found — using sandbox-config.yaml only"
    fi

    confirm

    if [[ "$SKIP_SSH" != "true" ]]; then
        if [[ -z "$(cfg ssh_key)" ]]; then
            log_error "ssh_key is blank" \
                      "Cannot SSH without a key path" \
                      "Set ssh_key in provision-output.yaml or sandbox-config.yaml"
            exit 1
        fi
        ssh_init
        ssh_probe "node" || exit 1
    fi

    uninstall_remote
    clear_laptop_state

    echo ""
    log_success "Uninstall complete. The VM is still provisioned and reachable."
    log_info    "To start fresh: ./openg2p-sandbox.sh --config $(basename "$CONFIG_FILE")"
}

main "$@" 2>&1 | tee -a "$LOG_FILE"
