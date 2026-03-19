#!/usr/bin/env bash
# =============================================================================
# OpenG2P Base Infrastructure Setup
# =============================================================================
# Sets up the complete base infrastructure on a single Ubuntu 24.04 VM:
#   Phase 1 (bash):     Tools, firewall, RKE2, Wireguard, NFS, TLS certs, Nginx
#   Phase 2 (helmfile): Istio, Rancher, Keycloak, Monitoring, Logging
#
# After this completes, run openg2p-environment.sh to create environments.
#
# Usage:
#   sudo ./openg2p-infra.sh --config infra-config.yaml
#
# Options:
#   --config <file>    Path to infra-config.yaml (required)
#   --phase <1|2>      Run only a specific phase
#   --force            Re-run all steps (ignore completion markers)
#   --dry-run          Show what would be done without executing
#   --reset            Clear all infra state markers and exit
#   --help             Show this help message
#
# Docs: https://docs.openg2p.org/deployment/deployment-instructions/infrastructure-setup
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
RUN_PHASE=""
FORCE_MODE=false
DRY_RUN=false
LOG_FILE="/var/log/openg2p-infra-$(date '+%Y%m%d-%H%M%S').log"

# ---------------------------------------------------------------------------
# Source libraries
# ---------------------------------------------------------------------------
source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/phase1.sh"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --phase)
                RUN_PHASE="$2"
                shift 2
                ;;
            --force)
                FORCE_MODE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --reset)
                init_state_dir
                reset_state "phase1."
                reset_state "phase2."
                exit 0
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
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
                  "Copy infra-config.example.yaml to infra-config.yaml and provide it" \
                  "$0 --config infra-config.yaml"
        exit 1
    fi

    if [[ ! "$CONFIG_FILE" = /* ]]; then
        CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
    fi
}

show_help() {
    cat <<'EOF'
OpenG2P Base Infrastructure Setup
===================================

Sets up the complete base infrastructure on a single Ubuntu 24.04 VM.
After this completes, run openg2p-environment.sh to create environments.

Usage:
  sudo ./openg2p-infra.sh --config infra-config.yaml [options]

Options:
  --config <file>    Path to configuration file (required)
  --phase <1|2>      Run only Phase 1 (host setup) or Phase 2 (platform Helmfile)
  --force            Ignore completion markers, re-run all steps
  --dry-run          Show what would be done without executing
  --reset            Clear all infra state markers and exit
  --help             Show this help message

Phases:
  Phase 1: Host-level (tools, RKE2, Wireguard, NFS, TLS certs, Nginx)
  Phase 2: Platform-level (Istio, Rancher, Keycloak, Monitoring, Logging)

Steps:
  1. Copy infra-config.example.yaml → infra-config.yaml and fill in values
  2. Ensure DNS A records for Rancher and Keycloak hostnames point to this VM
  3. Run: sudo ./openg2p-infra.sh --config infra-config.yaml
  4. Wait ~15-25 minutes
  5. Complete post-install steps (Rancher bootstrap, Rancher-Keycloak integration)
  6. Then run openg2p-environment.sh to set up an OpenG2P environment

Docs: https://docs.openg2p.org/deployment/deployment-instructions/infrastructure-setup
EOF
}

# ---------------------------------------------------------------------------
# Phase 2: Platform components via Helmfile
# ---------------------------------------------------------------------------
run_phase2() {
    local step_id="phase2.helmfile"

    log_step "2" "Phase 2 — Platform Components (Helmfile)"

    ensure_kubeconfig || return 1

    # Verify cluster is healthy
    log_info "Verifying Kubernetes cluster is healthy..."
    if ! kubectl get nodes | grep -qw Ready; then
        log_error "Kubernetes node is not in Ready state" \
                  "RKE2 may still be initializing or has an issue" \
                  "Check node status and RKE2 logs" \
                  "kubectl get nodes; journalctl -u rke2-server -n 30"
        return 1
    fi
    log_success "Kubernetes cluster is healthy."

    # Install Istio via istioctl (not Helm — Istio uses its own installer)
    install_istio_if_needed || return 1

    # Generate helmfile values from config
    generate_helmfile_infra_values

    # Run Helmfile
    log_info "Running Helmfile sync for platform components..."
    log_info "This may take 10-20 minutes on first run."
    cd "${SCRIPT_DIR}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would execute: helmfile -f helmfile-infra.yaml sync"
        helmfile -f helmfile-infra.yaml diff 2>/dev/null || log_warn "helmfile diff may fail on first run (expected)."
        return 0
    fi

    helmfile -f helmfile-infra.yaml sync 2>&1 | tee -a "$LOG_FILE" || {
        log_error "Helmfile sync failed" \
                  "One or more Helm releases failed to install" \
                  "Review the output above for specific errors" \
                  "helmfile -f helmfile-infra.yaml sync --debug 2>&1 | tail -50"
        echo ""
        log_info "Troubleshooting tips:"
        log_info "  1. Check pod status:  kubectl get pods -A | grep -v Running"
        log_info "  2. Check events:      kubectl get events -A --sort-by=.lastTimestamp | tail -20"
        log_info "  3. Re-run to retry:   sudo $0 --config $(basename "$CONFIG_FILE")"
        return 1
    }

    log_success "Phase 2 complete — all platform components deployed."
}

# ---------------------------------------------------------------------------
# Generate helmfile-infra-values.yaml from config
# ---------------------------------------------------------------------------
generate_helmfile_infra_values() {
    local values_file="${SCRIPT_DIR}/helmfile-infra-values.yaml"

    cat > "$values_file" <<EOF
# Auto-generated from infra config — do not edit manually
# Generated at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

rancher_hostname: "$(cfg 'rancher_hostname')"
keycloak_hostname: "$(cfg 'keycloak_hostname')"
node_ip: "$(cfg 'node_ip')"

rancher:
  version: "$(cfg 'rancher.version' '2.12.3')"
  replicas: $(cfg 'rancher.replicas' '1')

keycloak:
  replicas: $(cfg 'keycloak.replicas' '1')
EOF

    log_success "Helmfile infra values generated at ${values_file}"
}

# ---------------------------------------------------------------------------
# Install Istio via istioctl
# ---------------------------------------------------------------------------
install_istio_if_needed() {
    local step_id="phase2.istio"

    if is_step_done "$step_id" && [[ "$FORCE_MODE" != "true" ]]; then
        log_info "Skipping Istio installation — already completed."
        return 0
    fi

    if kubectl -n istio-system get deployment istiod &>/dev/null; then
        log_success "Istio (istiod) is already deployed."
        mark_step_done "$step_id"
        return 0
    fi

    log_info "Installing Istio via istioctl..."
    local istio_operator="${SCRIPT_DIR}/charts/istio-install/templates/operator.yaml"

    if [[ ! -f "$istio_operator" ]]; then
        log_error "Istio operator YAML not found at ${istio_operator}" \
                  "The automation charts directory may be incomplete" \
                  "Ensure the charts/istio-install directory exists"
        return 1
    fi

    istioctl install -f "$istio_operator" -y || {
        log_error "istioctl install failed" \
                  "Istio could not be installed on the cluster" \
                  "Check cluster access and istioctl version compatibility" \
                  "istioctl version; kubectl get nodes" \
                  "https://istio.io/latest/docs/setup/install/istioctl/"
        return 1
    }

    wait_for_deployment "istio-system" "istiod" 300 || return 1

    wait_for_command "Istio ingress gateway pods" \
        "kubectl -n istio-system get pods -l istio=ingressgateway -o jsonpath='{.items[*].status.phase}' | grep -q Running" \
        300 10

    mark_step_done "$step_id"
    log_success "Istio installed and healthy."
}

# ---------------------------------------------------------------------------
# Post-deployment summary
# ---------------------------------------------------------------------------
show_summary() {
    local rancher_host=$(cfg "rancher_hostname")
    local keycloak_host=$(cfg "keycloak_hostname")

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║   Base Infrastructure Setup Complete!                        ║${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Rancher:    ${BOLD}https://${rancher_host}${NC}"
    echo -e "${GREEN}║${NC}  Keycloak:   ${BOLD}https://${keycloak_host}${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}Next steps:${NC}                                                ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  1. Open Rancher and bootstrap admin password              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  2. Integrate Rancher with Keycloak (OIDC)                 ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}     Docs: https://docs.openg2p.org/deployment/             ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}       deployment-instructions/infrastructure-setup          ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}       #id-11.-integrating-rancher-with-keycloak             ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  3. Configure Wireguard VPN on your laptop                 ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}     Peer config: /etc/wireguard_app_users/peer1/peer1.conf ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  4. Run openg2p-environment.sh to create an environment    ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Log file: ${LOG_FILE}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    log_banner "OpenG2P Base Infrastructure Setup" "Single-node · Phase 1 + Phase 2"

    check_root "$@"
    init_state_dir

    if [[ "$FORCE_MODE" == "true" ]]; then
        reset_state "phase1."
        reset_state "phase2."
    fi

    # Load and validate config
    load_config "$CONFIG_FILE"
    validate_config \
        "node_ip" \
        "node_name" \
        "rancher_hostname" \
        "keycloak_hostname" \
        "letsencrypt_email"

    log_info "Deployment log: ${LOG_FILE}"
    log_info "Config file:    ${CONFIG_FILE}"
    log_info "Node:           $(cfg 'node_name') @ $(cfg 'node_ip')"
    log_info "Rancher:        $(cfg 'rancher_hostname')"
    log_info "Keycloak:       $(cfg 'keycloak_hostname')"
    echo ""

    case "${RUN_PHASE:-all}" in
        1)
            check_ubuntu_version
            check_system_resources
            check_dns_for_domains "$(cfg 'node_ip')" \
                "$(cfg 'rancher_hostname')" \
                "$(cfg 'keycloak_hostname')"
            run_phase1
            ;;
        2)
            run_phase2
            ;;
        all)
            check_ubuntu_version
            check_system_resources
            check_dns_for_domains "$(cfg 'node_ip')" \
                "$(cfg 'rancher_hostname')" \
                "$(cfg 'keycloak_hostname')"
            run_phase1
            run_phase2
            show_summary
            ;;
        *)
            log_error "Invalid phase: ${RUN_PHASE}" \
                      "Valid phases are: 1, 2, or omit for all" \
                      "Use --phase 1 or --phase 2"
            exit 1
            ;;
    esac

    if [[ "${RUN_PHASE:-all}" == "all" ]]; then
        log_success "Base infrastructure setup completed successfully!"
    fi
}

main "$@" 2>&1 | tee -a "$LOG_FILE"
