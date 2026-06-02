#!/usr/bin/env bash
# =============================================================================
# OpenG2P Reverse Proxy Node — entry script (runs ON the RP node via SSH)
# =============================================================================
# Phases:
#   1 — Wireguard server, customer-supplied TLS cert ingest, Nginx admin
#       server blocks bound to rp_private_ip
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE=""
RUN_PHASE="1"
FORCE_MODE=false

source "${WORK_DIR}/lib/shared/utils.sh"
source "${WORK_DIR}/lib/shared/hostnames.sh"
source "${SCRIPT_DIR}/phase1.sh"

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
}

main() {
    parse_args "$@"

    check_root
    init_state_dir

    if [[ "$FORCE_MODE" == "true" ]]; then
        reset_state "rp.phase${RUN_PHASE}."
    fi

    load_config "$CONFIG_FILE"
    hostnames_bridge_config_keys

    log_banner "OpenG2P Reverse Proxy Node" "Phase ${RUN_PHASE}"

    case "$RUN_PHASE" in
        1) run_rp_phase1 ;;
        *) log_error "Invalid phase for RP role: ${RUN_PHASE}" "Valid: 1"; exit 1 ;;
    esac

    log_success "RP node phase ${RUN_PHASE} complete."
}

main "$@"
