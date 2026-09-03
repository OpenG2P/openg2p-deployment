#!/usr/bin/env bash
# =============================================================================
# OpenG2P Environment Setup
# =============================================================================
# Creates an OpenG2P environment (namespace) and deploys modules into it.
# Run this AFTER base infrastructure is complete (roles/infra/run.sh).
#
# Preferred — from your laptop (SSHes into the VM, same pattern as the
# sandbox orchestrator / production environment stage):
#   ./roles/environment/run.sh --config environment-config.yaml
#
# Or via the full orchestrator:
#   ./openg2p-sandbox.sh --config sandbox-config.yaml --stage environment
#
# Advanced — run ON the Ubuntu VM as root (after infra is installed):
#   sudo ./roles/environment/run.sh --config environment-config.yaml
#
# Docs: https://docs.openg2p.org/deployment/concepts/openg2p-deployment-model#environments
# =============================================================================

set -euo pipefail

ROLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Charts, helmfile, and lib/ live at the sandbox root (two levels up).
SCRIPT_DIR="$(cd "${ROLE_DIR}/../.." && pwd)"
CONFIG_FILE=""
RUN_PHASE=""
FORCE_MODE=false
DRY_RUN=false
# Set after we know laptop vs on-box.
LOG_FILE=""

source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/acme.sh"
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
                  "Copy environment-config.example.yaml to environment-config.yaml and provide it" \
                  "$0 --config environment-config.yaml"
        exit 1
    fi

    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
}

show_help() {
    cat <<'EOF'
OpenG2P Environment Setup
===========================

Preferred — from your laptop, via the orchestrator (SSHes into the VM):
  ./openg2p-sandbox.sh --config sandbox-config.yaml --stage environment

Direct — run this role script yourself, ON the Ubuntu VM as root,
after the infra stage has completed:
  sudo bash roles/environment/run.sh --config environment-config.yaml [options]

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
  Base infrastructure must be set up first (roles/infra/run.sh / orchestrator).
  From the laptop, ssh_* must be set (usually via provision-output.yaml).

Docs: https://docs.openg2p.org/deployment/concepts/openg2p-deployment-model#environments
EOF
}

# ---------------------------------------------------------------------------
# Detect run mode: on-box (RKE2 node) vs laptop (SSH into the node).
# ---------------------------------------------------------------------------
is_onbox_node() {
    [[ -f /etc/rancher/rke2/rke2.yaml ]] || [[ "${OPENG2P_ORCHESTRATED:-}" == "1" ]]
}

resolve_sandbox_config_path() {
    local sandbox_config_path
    sandbox_config_path=$(cfg "sandbox_config" "")
    if [[ -z "$sandbox_config_path" ]]; then
        sandbox_config_path=$(cfg "infra_config" "sandbox-config.yaml")
    fi
    [[ "$sandbox_config_path" = /* ]] || sandbox_config_path="${SCRIPT_DIR}/${sandbox_config_path}"
    echo "$sandbox_config_path"
}

load_sn_and_provision_overlays() {
    # Sets PROVISION_OUTPUT_RESOLVED (path or empty). Logs to stderr/console only.
    PROVISION_OUTPUT_RESOLVED=""
    local sandbox_config_path
    sandbox_config_path=$(resolve_sandbox_config_path)
    if [[ -f "$sandbox_config_path" ]]; then
        log_info "Loading sandbox config from: ${sandbox_config_path}"
        load_config "$sandbox_config_path"
        load_config "$CONFIG_FILE"
    else
        log_warn "Single-node config not found: ${sandbox_config_path}"
        log_warn "node_ip, domain,ssh_* must be set somehow."
    fi

    local provision_output
    provision_output="$(dirname "$sandbox_config_path")/provision-output.yaml"
    if [[ ! -f "$provision_output" ]]; then
        provision_output="$(dirname "$CONFIG_FILE")/provision-output.yaml"
    fi
    if [[ -f "$provision_output" ]]; then
        log_info "Loading provision-output overlay: ${provision_output}"
        load_config "$provision_output"
        load_config "$CONFIG_FILE"
        PROVISION_OUTPUT_RESOLVED="$provision_output"
    fi
}

ssh_endpoint_available() {
    local host key
    host=$(cfg "ssh_host" "")
    if [[ -z "$host" ]]; then host=$(cfg "public_ip" ""); fi
    if [[ -z "$host" ]]; then host=$(cfg "wireguard.endpoint" ""); fi
    key=$(cfg "ssh_key" "")
    [[ -n "$host" && -n "$key" ]]
}

# ---------------------------------------------------------------------------
# Laptop path — SSH into the VM and run the on-box install there.
# ---------------------------------------------------------------------------
run_from_laptop() {
    log_banner "OpenG2P Environment Setup" "Laptop · SSH → on-box install"

    if [[ $EUID -eq 0 ]]; then
        log_warn "You are running this with sudo on the laptop — that is not needed."
        log_warn "Prefer: ./roles/environment/run.sh --config environment-config.yaml"
        echo ""
    fi

    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/lib/ssh-utils.sh"

    load_config "$CONFIG_FILE"

    local env_name
    env_name=$(cfg "environment")
    if [[ -z "$env_name" ]]; then
        log_error "No environment name specified" \
                  "The 'environment' key is missing or empty in your config" \
                  "Set environment: dev (or qa, staging, pilot, etc.) in your config"
        exit 1
    fi

    local sandbox_config_path
    sandbox_config_path=$(resolve_sandbox_config_path)
    load_sn_and_provision_overlays
    local provision_output="${PROVISION_OUTPUT_RESOLVED:-}"

    if ! ssh_endpoint_available; then
        log_error "Cannot reach the sandbox VM from this laptop" \
                  "Kubeconfig is not local (this is not the RKE2 node) and ssh_host/ssh_key are blank" \
                  "Set ssh_* in provision-output.yaml or sandbox-config.yaml, or run on the VM after infra" \
                  "./openg2p-sandbox.sh --config sandbox-config.yaml --stage environment"
        exit 1
    fi

    if [[ ! -f "$sandbox_config_path" ]]; then
        log_error "sandbox-config.yaml not found: ${sandbox_config_path}" \
                  "Environment install from the laptop needs the sandbox config for SSH" \
                  "Set sandbox_config in environment-config.yaml"
        exit 1
    fi

    log_info "Environment: ${BOLD}${env_name}${NC}"
    log_info "Mode:        laptop → SSH → on-box roles/environment/run.sh"
    log_info "Log:         ${LOG_FILE}"
    log_info "Config:      ${CONFIG_FILE}"
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would stage and run on remote: roles/environment/run.sh --config environment-config.yaml${RUN_PHASE:+ --phase $RUN_PHASE}"
        return 0
    fi

    ssh_init
    trap 'ssh_cleanup 2>/dev/null || true' EXIT
    ssh_probe "node" || exit 1

    ssh_stage_sandbox "$SCRIPT_DIR" "$sandbox_config_path" "$provision_output" "$CONFIG_FILE"

    local remote_cmd="cd ${REMOTE_WORK_DIR} && OPENG2P_ORCHESTRATED=1 bash roles/environment/run.sh --config environment-config.yaml"
    if [[ -n "$RUN_PHASE" ]]; then remote_cmd+=" --phase ${RUN_PHASE}"; fi
    if [[ "$FORCE_MODE" == "true" ]]; then remote_cmd+=" --force"; fi

    log_info "Remote: ${remote_cmd}"
    ssh_run "node" "$remote_cmd"

    log_success "Environment '${env_name}' setup completed on the remote node."
}

# ---------------------------------------------------------------------------
show_env_summary() {
    local env_name=$(cfg "environment")
    local base_domain=$(get_env_base_domain)
    # Per-env Keycloak deployed by the commons-base chart (Rancher uses local auth)
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
# On-box path — original install (runs on the RKE2 VM as root).
# ---------------------------------------------------------------------------
run_onbox() {
    log_banner "OpenG2P Environment Setup" "On-box · Phase 1 + Phase 2"

    check_root "$@"
    init_state_dir

    load_config "$CONFIG_FILE"

    local env_name
    env_name=$(cfg "environment")
    if [[ -z "$env_name" ]]; then
        log_error "No environment name specified" \
                  "The 'environment' key is missing or empty in your config" \
                  "Set environment: dev (or qa, staging, pilot, etc.) in your config"
        exit 1
    fi

    local sandbox_config_path
    sandbox_config_path=$(resolve_sandbox_config_path)
    if [[ -f "$sandbox_config_path" ]]; then
        log_info "Loading sandbox config from: ${sandbox_config_path}"
        load_config "$sandbox_config_path"
        load_config "$CONFIG_FILE"
    else
        log_warn "Single-node config not found: ${sandbox_config_path}"
        log_warn "node_ip, domain,etc. must be set in env config."
    fi

    # When staged by the orchestrator, provision-output may sit alongside.
    local provision_output
    provision_output="$(dirname "$CONFIG_FILE")/provision-output.yaml"
    if [[ -f "$provision_output" ]]; then
        log_info "Loading provision-output overlay: ${provision_output}"
        load_config "$provision_output"
        load_config "$CONFIG_FILE"
    fi

    if [[ "$FORCE_MODE" == "true" ]]; then
        reset_state "env-${env_name}."
    fi

    local base_domain
    base_domain=$(get_env_base_domain)

    log_info "Environment:    ${BOLD}${env_name}${NC}"
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

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    if is_onbox_node; then
        LOG_FILE="/var/log/openg2p-env-$(date '+%Y%m%d-%H%M%S').log"
        # Ensure we can write the log when root (check_root runs later).
        if [[ $EUID -eq 0 ]]; then
            touch "$LOG_FILE" 2>/dev/null || true
        fi
        exec > >(tee -a "$LOG_FILE") 2>&1
        run_onbox "$@"
    else
        mkdir -p "${SCRIPT_DIR}/logs"
        LOG_FILE="${SCRIPT_DIR}/logs/openg2p-env-$(date '+%Y%m%d-%H%M%S').log"
        exec > >(tee -a "$LOG_FILE") 2>&1
        run_from_laptop
    fi
}

main "$@"
