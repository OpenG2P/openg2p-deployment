#!/usr/bin/env bash
# =============================================================================
# OpenG2P 3-Node Production — Uninstall (laptop-side orchestrator)
# =============================================================================
# Wipes the OpenG2P installation off the three VMs WITHOUT touching the VMs
# themselves. Use after a failed install when you want to start over without
# re-provisioning, or to roll back a deployment for any reason.
#
# What it removes (per node):
#   • Compute  — RKE2 + all in-cluster workloads (Istio, Rancher, Keycloak,
#                monitoring, logging: OpenTelemetry + Loki) via
#                rke2-uninstall.sh; kubectl/helm/
#                istioctl/helmfile binaries; NFS client mount; /etc/hosts
#                managed block; sysctl tweaks; ufw rules; state markers.
#   • RP       — Wireguard server + peer configs; Nginx admin server blocks;
#                customer certs on /etc/openg2p/certs; ip_forward sysctl;
#                MASQUERADE residue; ufw rules; state markers.
#   • Storage  — host PostgreSQL; NFS server + /etc/exports; ufw rules;
#                state markers. Data dirs preserved unless --purge-data.
#   • Laptop   — orchestrator state under .state/; pulled artifacts/.
#
# Keeps:
#   • The VMs themselves and the AWS resources around them (use
#     aws/openg2p-aws-destroy.sh to remove those).
#   • Generic OS tools (curl, jq, openssl, ssh, ufw, ca-certificates).
#   • By default, the Postgres data dir and NFS export contents on storage.
#
# Idempotent. Safe to re-run.
# =============================================================================

set -uo pipefail   # NOT -e — uninstall must continue even when bits are missing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
PROVISION_OUTPUT=""
TARGET_ROLE="all"
PURGE_DATA=false
ASSUME_YES=false
SKIP_SSH=false
LOG_FILE="${SCRIPT_DIR}/logs/openg2p-prod-uninstall-$(date '+%Y%m%d-%H%M%S').log"

source "${SCRIPT_DIR}/lib/shared/utils.sh"
source "${SCRIPT_DIR}/lib/ssh-utils.sh"

# Laptop-side state path (must match openg2p-prod.sh).
STATE_DIR="${SCRIPT_DIR}/.state"

# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)            CONFIG_FILE="$2";       shift 2 ;;
            --provision-output)  PROVISION_OUTPUT="$2";  shift 2 ;;
            --role)              TARGET_ROLE="$2";       shift 2 ;;
            --purge-data)        PURGE_DATA=true;        shift ;;
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
    [[ -z "$CONFIG_FILE" ]] && { log_error "--config is required"; exit 1; }
    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
    [[ ! -f "$CONFIG_FILE" ]] && { log_error "Config file not found: $CONFIG_FILE"; exit 1; }

    case "$TARGET_ROLE" in
        all|rp|compute|storage) ;;
        *) log_error "--role must be one of: all | rp | compute | storage (got: $TARGET_ROLE)"; exit 1 ;;
    esac
}

show_help() {
    cat <<'EOF'
OpenG2P 3-Node Production — Uninstall
======================================

Wipes the OpenG2P installation off the three VMs in place (does NOT destroy
the VMs). Use after a failed install to start over without re-provisioning.

Usage:
  ./openg2p-prod-uninstall.sh --config prod-config.yaml [options]

Options:
  --config <file>            Path to your prod-config.yaml (required)
  --provision-output <file>  Path to provision-output.yaml (auto-detected if blank)
  --role <name>              all | rp | compute | storage  (default: all)
                               Use --role to redo a single node without touching
                               the others.
  --purge-data               Also delete PostgreSQL data dir + NFS export
                               contents on storage. There is no undo. Default
                               is to preserve those directories.
  --yes / -y                 Skip the typed-name confirmation prompt
  --skip-ssh                 Skip remote teardown (laptop-side cleanup only)
  --help                     Show this help

Recovery escalation ladder (try in order):
  1. Re-run the install              — picks up where it left off
  2. ./openg2p-prod.sh --force ...   — re-runs every phase, ignoring markers
  3. ./openg2p-prod.sh --reset-laptop... — wipes laptop markers (after re-provision)
  4. THIS SCRIPT                     — wipes the VMs in place; then install fresh
EOF
}

confirm() {
    local cluster_name=$(cfg cluster_name)
    [[ -z "$cluster_name" ]] && cluster_name="openg2p"

    echo ""
    log_warn "════════════════════════════════════════════════════════════════"
    log_warn " You are about to UNINSTALL OpenG2P from these nodes:"
    if [[ "$TARGET_ROLE" == "all" || "$TARGET_ROLE" == "rp" ]]; then
        log_warn "   • Reverse Proxy:  $(cfg rp_ssh_host "$(cfg rp_public_ip)")"
    fi
    if [[ "$TARGET_ROLE" == "all" || "$TARGET_ROLE" == "compute" ]]; then
        log_warn "   • Compute:        $(cfg compute_ssh_host "$(cfg compute_private_ip)")"
    fi
    if [[ "$TARGET_ROLE" == "all" || "$TARGET_ROLE" == "storage" ]]; then
        log_warn "   • Storage:        $(cfg storage_ssh_host "$(cfg storage_private_ip)")"
    fi
    log_warn ""
    if [[ "$PURGE_DATA" == "true" ]]; then
        log_warn " --purge-data IS SET: PostgreSQL data and NFS exports will be DELETED."
    else
        log_warn " Data dirs (PostgreSQL, NFS export contents) will be preserved."
        log_warn " Pass --purge-data to delete them too."
    fi
    log_warn ""
    log_warn " This does NOT destroy the VMs themselves — they remain provisioned."
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

uninstall_role() {
    local role="$1"

    log_step "UNINSTALL ${role^^}" "Stage role bundle + run remote teardown"

    if [[ "$SKIP_SSH" == "true" ]]; then
        local would_purge=""
        [[ "$PURGE_DATA" == "true" ]] && would_purge=" --purge-data"
        log_info "[--skip-ssh] would stage and run: role/uninstall.sh --config prod-config.yaml${would_purge}"
        return 0
    fi

    # Reuse the install-side staging: it copies lib/shared, the role dir
    # (which now includes uninstall.sh), and the merged config.
    ssh_stage_role "$role" "$SCRIPT_DIR" "$CONFIG_FILE" "$PROVISION_OUTPUT"

    local extra=""
    [[ "$PURGE_DATA" == "true" ]] && extra="--purge-data"

    # Run uninstall.sh on the remote. `|| true` so a remote failure doesn't
    # abort other roles — every uninstall is best-effort by design.
    if ssh_run "$role" "cd ${REMOTE_WORK_DIR} && sudo bash role/uninstall.sh --config prod-config.yaml $extra"; then
        log_success "  ${role}: remote uninstall complete."
    else
        log_warn "  ${role}: remote uninstall reported errors (continuing)."
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

    # Pulled artifacts (peer configs, kubeconfig). Mirrors openg2p-prod.sh layout.
    local artifacts="${SCRIPT_DIR}/artifacts"
    if [[ -d "$artifacts" ]]; then
        rm -rf "$artifacts"
        log_success "  removed ${artifacts}"
    fi
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    mkdir -p "${SCRIPT_DIR}/logs"

    log_banner "OpenG2P 3-Node Production — Uninstall" "In-place teardown · keeps VMs"

    log_info "Config: ${CONFIG_FILE}"
    log_info "Log:    ${LOG_FILE}"
    echo ""

    load_config "$CONFIG_FILE"

    # Auto-detect provision-output.yaml alongside prod-config (same as install).
    if [[ -z "$PROVISION_OUTPUT" ]]; then
        PROVISION_OUTPUT="$(dirname "$CONFIG_FILE")/provision-output.yaml"
    fi
    if [[ -f "$PROVISION_OUTPUT" ]]; then
        log_info "Loading provision-output overlay: ${PROVISION_OUTPUT}"
        load_config "$PROVISION_OUTPUT"
    else
        PROVISION_OUTPUT=""
        log_info "No provision-output.yaml found — using prod-config.yaml only"
    fi

    confirm

    if [[ "$SKIP_SSH" != "true" ]]; then
        ssh_init
        trap ssh_cleanup EXIT
    fi

    # Teardown order (independent in practice, but logical sequence):
    #   compute first  — biggest job (RKE2), starts SSH-warming everything
    #   rp next        — turns off Wireguard endpoint last so other steps can use it
    #   storage last   — data layer
    if [[ "$TARGET_ROLE" == "all" || "$TARGET_ROLE" == "compute" ]]; then
        uninstall_role compute
    fi
    if [[ "$TARGET_ROLE" == "all" || "$TARGET_ROLE" == "rp" ]]; then
        uninstall_role rp
    fi
    if [[ "$TARGET_ROLE" == "all" || "$TARGET_ROLE" == "storage" ]]; then
        uninstall_role storage
    fi

    # Laptop-side cleanup runs on full or any partial uninstall — the markers
    # for a wiped node are stale either way.
    clear_laptop_state

    echo ""
    log_success "Uninstall complete. The VMs are still provisioned and reachable."
    log_info    "To start fresh, run: ./openg2p-prod.sh --config ${CONFIG_FILE}"
}

main "$@" 2>&1 | tee -a "$LOG_FILE"
