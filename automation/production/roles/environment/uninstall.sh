#!/usr/bin/env bash
# =============================================================================
# Environment Role — uninstall (runs ON THE LAPTOP)
# =============================================================================
# Wraps automation/environment/env-cluster-uninstall.sh with the env name
# resolved from prod-config and KUBECONFIG pointed at the cached compute
# kubeconfig.
#
# Modes:
#   default — uninstall all Helm releases + secrets/PVCs in the namespace,
#             preserve namespace + gateway + project for fast reinstall
#   --full  — also delete the Istio Gateway, namespace, and Rancher Project
#
# Usage (typically driven from openg2p-prod-uninstall.sh):
#   ./uninstall.sh --config <prod-config.yaml> [--full] [--yes]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE=""
FULL_MODE=false
SKIP_CONFIRM=false

source "${WORK_DIR}/lib/shared/utils.sh"
STATE_DIR="${WORK_DIR}/.state"

ENV_CLUSTER_UNINSTALL_SH="${WORK_DIR}/../environment/env-cluster-uninstall.sh"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config) CONFIG_FILE="$2"; shift 2 ;;
            --full)   FULL_MODE=true;   shift ;;
            --yes)    SKIP_CONFIRM=true; shift ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done
    [[ -z "$CONFIG_FILE" ]] && { log_error "--config required"; exit 1; }
    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${WORK_DIR}/${CONFIG_FILE}"
}

main() {
    parse_args "$@"
    load_config "$CONFIG_FILE"

    local env_name=$(cfg "environment.name" "prod")
    local kubeconfig_cache="${STATE_DIR}/environment/kubeconfig"
    if [[ ! -f "$kubeconfig_cache" ]]; then
        log_error "No cached kubeconfig at ${kubeconfig_cache}" \
                  "Phase 1 of the environment role must have run at least once" \
                  "Fetch the kubeconfig with: ./openg2p-prod.sh --role environment --phase 1 --config <config>"
        exit 1
    fi
    export KUBECONFIG="$kubeconfig_cache"

    if [[ ! -x "$ENV_CLUSTER_UNINSTALL_SH" ]]; then
        log_error "env-cluster-uninstall.sh not found or not executable: ${ENV_CLUSTER_UNINSTALL_SH}"
        exit 1
    fi

    local -a uninstall_args=(--namespace "$env_name")
    [[ "$FULL_MODE" == "true" ]] && uninstall_args+=(--full)
    [[ "$SKIP_CONFIRM" == "true" ]] && uninstall_args+=(--yes)

    log_step "ENV UNINSTALL" "Tearing down environment '${env_name}' (full=${FULL_MODE})"
    "$ENV_CLUSTER_UNINSTALL_SH" "${uninstall_args[@]}"

    log_success "Environment '${env_name}' teardown complete."
}

main "$@"
