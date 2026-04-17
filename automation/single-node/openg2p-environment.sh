#!/usr/bin/env bash
# =============================================================================
# OpenG2P Environment Setup
# =============================================================================
# Creates an OpenG2P environment (namespace) and deploys modules into it.
# Run this AFTER openg2p-infra.sh has completed the base infrastructure.
#
# Each environment gets:
#   - A K8s namespace
#   - A Rancher Project (for RBAC)
#   - TLS certificate for *.<env_base_domain>
#   - Nginx server block → Istio ingress
#   - Istio Gateway for hostname routing
#   - openg2p-commons (shared services: PostgreSQL, Kafka, MinIO, etc.)
#   - (future) OpenG2P modules: Registry, PBMS, SPAR, G2P Bridge
#
# Can be run multiple times with different configs to create multiple
# environments (dev, qa, staging, pilot) on the same cluster.
#
# Usage:
#   sudo ./openg2p-environment.sh --config env-config.yaml
#
# Docs: https://docs.openg2p.org/deployment/concepts/openg2p-deployment-model#environments
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
RUN_PHASE=""
FORCE_MODE=false
DRY_RUN=false
LOG_FILE="/var/log/openg2p-env-$(date '+%Y%m%d-%H%M%S').log"

source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/env-phase1.sh"
source "${SCRIPT_DIR}/lib/env-phase2.sh"

# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)  CONFIG_FILE="$2"; shift 2 ;;
            --phase)   RUN_PHASE="$2"; shift 2 ;;
            --force)   FORCE_MODE=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --help|-h) show_help; exit 0 ;;
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
                  "Copy env-config.example.yaml to env-config.yaml and provide it" \
                  "$0 --config env-config.yaml"
        exit 1
    fi

    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
}

show_help() {
    cat <<'EOF'
OpenG2P Environment Setup
===========================

Usage:
  sudo ./openg2p-environment.sh --config env-config.yaml [options]

Options:
  --config <file>    Path to environment config file (required)
  --phase <1|2>      Run only a specific phase
  --force            Ignore completion markers, re-run all steps
  --dry-run          Show what would be done without executing
  --help             Show this help message

Phases:
  1  Environment infrastructure (TLS, Nginx, namespace, Rancher Project, Istio GW)
  2  Module installation (openg2p-commons, and future modules)

Prerequisites:
  Base infrastructure must be set up first (run openg2p-infra.sh).

Docs: https://docs.openg2p.org/deployment/concepts/openg2p-deployment-model#environments
EOF
}

# ---------------------------------------------------------------------------
show_env_summary() {
    local env_name=$(cfg "environment")
    local base_domain=$(get_env_base_domain)
    # Per-env Keycloak deployed by the commons-base chart (not the infra Keycloak)
    local keycloak_url="https://keycloak.${base_domain}"

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║   Environment Setup Complete!                                ║${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Environment:  ${BOLD}${env_name}${NC}"
    echo -e "${GREEN}║${NC}  Namespace:    ${BOLD}${env_name}${NC}"
    echo -e "${GREEN}║${NC}  Base domain:  ${BOLD}${base_domain}${NC}"
    echo -e "${GREEN}║${NC}  Keycloak:     ${BOLD}${keycloak_url}${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}Service URLs:${NC}                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    MinIO:       https://minio.${base_domain}               ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Superset:    https://superset.${base_domain}             ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    OpenSearch:  https://opensearch.${base_domain}           ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Kafka UI:    https://kafka.${base_domain}                ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    eSignet:     https://esignet.${base_domain}              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    ODK Central: https://odk.${base_domain}                  ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}What's next:${NC}                                                ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Assign users to this environment in Rancher:               ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Rancher → Project '${env_name}' → Members → Add Member    ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Log: ${LOG_FILE}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    log_banner "OpenG2P Environment Setup" "Environment · Phase 1 + Phase 2"

    check_root "$@"
    init_state_dir

    # Load the environment config
    load_config "$CONFIG_FILE"

    local env_name=$(cfg "environment")
    if [[ -z "$env_name" ]]; then
        log_error "No environment name specified" \
                  "The 'environment' key is missing or empty in your config" \
                  "Set environment: dev (or qa, staging, pilot, etc.) in your config"
        exit 1
    fi

    # Load infra config to inherit node_ip, domain_mode, etc.
    local infra_config_path=$(cfg "infra_config" "infra-config.yaml")
    [[ "$infra_config_path" = /* ]] || infra_config_path="${SCRIPT_DIR}/${infra_config_path}"
    if [[ -f "$infra_config_path" ]]; then
        log_info "Loading infra config from: ${infra_config_path}"
        load_config "$infra_config_path"
        # Re-load env config so env values take precedence over infra values
        load_config "$CONFIG_FILE"
    else
        log_warn "Infra config not found: ${infra_config_path}"
        log_warn "node_ip, domain_mode, etc. must be set in env config."
    fi

    if [[ "$FORCE_MODE" == "true" ]]; then
        reset_state "env-${env_name}."
    fi

    local domain_mode=$(cfg "domain_mode" "custom")
    local base_domain=$(get_env_base_domain)

    log_info "Environment:    ${BOLD}${env_name}${NC}"
    log_info "Domain mode:    ${BOLD}${domain_mode}${NC}"
    log_info "Base domain:    ${BOLD}${base_domain}${NC}"
    log_info "Deployment log: ${LOG_FILE}"
    log_info "Config file:    ${CONFIG_FILE}"
    echo ""

    case "${RUN_PHASE:-all}" in
        1)
            run_env_phase1
            ;;
        2)
            run_env_phase2
            ;;
        all)
            run_env_phase1
            run_env_phase2
            show_env_summary
            ;;
        *)
            log_error "Invalid phase: ${RUN_PHASE}" \
                      "Valid phases are: 1, 2, or omit for all" \
                      "Use --phase 1 or --phase 2"
            exit 1
            ;;
    esac

    if [[ "${RUN_PHASE:-all}" == "all" ]]; then
        log_success "Environment '${env_name}' setup completed successfully!"
    fi
}

# Redirect all output to both console and log file.
exec > >(tee -a "$LOG_FILE") 2>&1

main "$@"
