#!/usr/bin/env bash
# =============================================================================
# OpenG2P Environment Role — entry script (runs ON THE LAPTOP)
# =============================================================================
# Unlike rp/compute/storage roles which run on the target VM, this role
# runs from the orchestrator's host (your laptop) and targets the cluster
# via kubectl + helm. The orchestrator dispatches it locally — not via SSH.
#
# Phases:
#   1 — scaffolding: kubeconfig fetch, Rancher ClusterRepo, namespace,
#                    Rancher Project, Istio Gateway, external-PG secret
#   2 — commons install: openg2p-commons-base + openg2p-commons-services
#                        (gated by environment.install_commons in config)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"   # automation/production/
CONFIG_FILE=""
PROVISION_OUTPUT=""
RUN_PHASE=""
FORCE_MODE=false

source "${WORK_DIR}/lib/shared/utils.sh"
# Laptop-side state — same convention as the orchestrator.
STATE_DIR="${WORK_DIR}/.state"
# SSH helpers — phases fetch kubeconfig from compute + PG superuser password
# from storage. ssh-utils provides ssh_run / ssh_pull driven by prod-config keys.
source "${WORK_DIR}/lib/ssh-utils.sh"

# Load phase scripts on demand.
load_phase() {
    case "$1" in
        1) source "${SCRIPT_DIR}/phase1.sh" ;;
        2) source "${SCRIPT_DIR}/phase2.sh" ;;
        *) log_error "Unknown phase: $1" "Valid phases are 1 and 2"; exit 1 ;;
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
        log_error "environment role requires --phase <1|2>"
        exit 1
    fi
}

main() {
    parse_args "$@"
    load_config "$CONFIG_FILE"
    # Provision-output overlay (private IPs, SSH paths) — same precedence as
    # the orchestrator: overlay wins for AWS-derived keys.
    if [[ -n "$PROVISION_OUTPUT" && -f "$PROVISION_OUTPUT" ]]; then
        load_config "$PROVISION_OUTPUT"
    fi

    mkdir -p "${STATE_DIR}/environment"
    load_phase "$RUN_PHASE"
    "phase${RUN_PHASE}_main"
}

main "$@"
