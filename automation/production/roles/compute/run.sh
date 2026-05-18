#!/usr/bin/env bash
# =============================================================================
# OpenG2P Compute Node — entry script (runs ON the compute node via SSH)
# =============================================================================
# Phases:
#   1 — host setup: tools, ufw, NFS client, RKE2 server, NFS CSI StorageClass
#   2 — helmfile sync: Istio, Rancher, Keycloak, monitoring, logging
#   3 — Rancher-Keycloak SAML integration (vendored from single-node)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE=""
RUN_PHASE=""
FORCE_MODE=false

source "${WORK_DIR}/lib/shared/utils.sh"
source "${WORK_DIR}/lib/shared/hostnames.sh"

# Load phase scripts on demand to keep startup fast.
load_phase() {
    case "$1" in
        1) source "${SCRIPT_DIR}/phase1.sh" ;;
        2) source "${SCRIPT_DIR}/phase2.sh" ;;
        3) source "${WORK_DIR}/lib/shared/phase3.sh" ;;
    esac
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config) CONFIG_FILE="$2"; shift 2 ;;
            --phase)  RUN_PHASE="$2";  shift 2 ;;
            --force)  FORCE_MODE=true; shift ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done
    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${WORK_DIR}/${CONFIG_FILE}"

    if [[ -z "$RUN_PHASE" ]]; then
        log_error "Compute role requires --phase <1|2|3>"
        exit 1
    fi
}

main() {
    parse_args "$@"

    check_root
    init_state_dir

    if [[ "$FORCE_MODE" == "true" ]]; then
        reset_state "compute.phase${RUN_PHASE}."
    fi

    load_config "$CONFIG_FILE"
    hostnames_bridge_config_keys

    log_banner "OpenG2P Compute Node" "Phase ${RUN_PHASE}"

    load_phase "$RUN_PHASE"

    case "$RUN_PHASE" in
        1) run_compute_phase1 ;;
        2) run_compute_phase2 ;;
        3)
            # Phase 3 calls the Rancher API at https://<rancher_hostname>
            # from this node, which only resolves if rancher/keycloak hostnames
            # are in /etc/hosts pointing at the RP's private IP. Ensure they
            # are — self-heals if phase 1 was run with an older script.
            ensure_admin_hostnames_in_etc_hosts
            run_phase3   # vendored from single-node — Rancher-Keycloak SAML
            ;;
        *) log_error "Invalid phase: ${RUN_PHASE}"; exit 1 ;;
    esac

    log_success "Compute node phase ${RUN_PHASE} complete."
}

main "$@"
