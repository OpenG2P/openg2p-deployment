#!/usr/bin/env bash
# =============================================================================
# OpenG2P Environment Role — entry script (runs ON THE LAPTOP)
# =============================================================================
# Unlike rp/compute/storage roles which run on the target VM, this role
# runs from the orchestrator's host (your laptop) and targets the cluster
# via kubectl + helm. The orchestrator dispatches it locally — not via SSH.
#
# Phases:
#   1 — scaffolding: kubeconfig fetch, Rancher ClusterRepos, namespace,
#                    Rancher Project, Istio Gateway, external-PG secret
#                    (gated by install_environment in prod-config)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"   # automation/production/
CONFIG_FILE=""
PROVISION_OUTPUT=""
RUN_PHASE=""
FORCE_MODE=false

source "${WORK_DIR}/lib/shared/utils.sh"
STATE_DIR="${WORK_DIR}/.state"
source "${WORK_DIR}/lib/ssh-utils.sh"

load_phase() {
    case "$1" in
        1) source "${SCRIPT_DIR}/phase1.sh" ;;
        *) log_error "Unknown phase: $1" "Valid phases: 1"; exit 1 ;;
    esac
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)            CONFIG_FILE="$2";       shift 2 ;;
            --provision-output)  PROVISION_OUTPUT="$2";  shift 2 ;;
            --phase)             RUN_PHASE="$2";         shift 2 ;;
            --force)             FORCE_MODE=true;        shift ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done
    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${WORK_DIR}/${CONFIG_FILE}"

    if [[ -z "$RUN_PHASE" ]]; then
        log_error "environment role requires --phase <1>"
        exit 1
    fi
}

main() {
    parse_args "$@"
    load_config "$CONFIG_FILE"
    if [[ -n "$PROVISION_OUTPUT" && -f "$PROVISION_OUTPUT" ]]; then
        load_config "$PROVISION_OUTPUT"
    elif [[ -z "$PROVISION_OUTPUT" ]]; then
        local auto="$(dirname "$CONFIG_FILE")/provision-output.yaml"
        [[ -f "$auto" ]] && load_config "$auto"
    fi

    mkdir -p "${STATE_DIR}/environment"
    load_phase "$RUN_PHASE"
    "phase${RUN_PHASE}_main"
}

main "$@"
