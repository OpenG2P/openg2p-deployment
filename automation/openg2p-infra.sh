#!/usr/bin/env bash
# =============================================================================
# OpenG2P Base Infrastructure Setup
# =============================================================================
# Sets up the complete base infrastructure on a single Ubuntu 24.04 VM:
#   Phase 1 (bash):     Tools, firewall, RKE2, Wireguard, NFS, DNS, TLS, Nginx
#   Phase 2 (helmfile): Istio, Rancher, Keycloak, Monitoring, Logging
#
# Supports two domain modes:
#   "custom" — your own domains + Let's Encrypt (production)
#   "local"  — local DNS (dnsmasq) + self-signed CA (sandbox/pilot)
#
# After this completes, run openg2p-environment.sh to create environments.
#
# Usage:
#   sudo ./openg2p-infra.sh --config infra-config.yaml
#
# Docs: https://docs.openg2p.org/deployment/deployment-instructions/infrastructure-setup
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
RUN_PHASE=""
FORCE_MODE=false
DRY_RUN=false
LOG_FILE="/var/log/openg2p-infra-$(date '+%Y%m%d-%H%M%S').log"

source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/phase1.sh"

# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)  CONFIG_FILE="$2"; shift 2 ;;
            --phase)   RUN_PHASE="$2"; shift 2 ;;
            --force)   FORCE_MODE=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --reset)   init_state_dir; reset_state "phase1."; reset_state "phase2."; exit 0 ;;
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
                  "Copy infra-config.example.yaml to infra-config.yaml and provide it" \
                  "$0 --config infra-config.yaml"
        exit 1
    fi

    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
}

show_help() {
    cat <<'EOF'
OpenG2P Base Infrastructure Setup
===================================

Usage:
  sudo ./openg2p-infra.sh --config infra-config.yaml [options]

Options:
  --config <file>    Path to configuration file (required)
  --phase <1|2>      Run only Phase 1 (host setup) or Phase 2 (platform Helmfile)
  --force            Ignore completion markers, re-run all steps
  --dry-run          Show what would be done without executing
  --reset            Clear all infra state markers and exit
  --help             Show this help message

Domain modes (set in config file):
  custom  — Your own domains + Let's Encrypt (default, for production)
  local   — Local DNS + self-signed CA (for sandboxes, no domain needed)

Docs: https://docs.openg2p.org/deployment/deployment-instructions/infrastructure-setup
EOF
}

# ---------------------------------------------------------------------------
# Phase 2: Platform components via Helmfile
# ---------------------------------------------------------------------------
run_phase2() {
    log_step "2" "Phase 2 — Platform Components (Helmfile)"

    ensure_kubeconfig || return 1

    log_info "Verifying Kubernetes cluster is healthy..."
    if ! kubectl get nodes | grep -qw Ready; then
        log_error "Kubernetes node is not in Ready state" \
                  "RKE2 may still be initializing" \
                  "Check node status and RKE2 logs" \
                  "kubectl get nodes; journalctl -u rke2-server -n 30"
        return 1
    fi
    log_success "Kubernetes cluster is healthy."

    install_istio_if_needed || return 1
    generate_helmfile_infra_values

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
generate_helmfile_infra_values() {
    local values_file="${SCRIPT_DIR}/helmfile-infra-values.yaml"
    local rancher_host=$(get_rancher_hostname)
    local keycloak_host=$(get_keycloak_hostname)

    cat > "$values_file" <<EOF
# Auto-generated from infra config — do not edit manually
# Generated at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

rancher_hostname: "${rancher_host}"
keycloak_hostname: "${keycloak_host}"
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
                  "Check cluster access and istioctl version" \
                  "istioctl version; kubectl get nodes"
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
show_summary() {
    local domain_mode=$(cfg "domain_mode" "custom")
    local rancher_host=$(get_rancher_hostname)
    local keycloak_host=$(get_keycloak_hostname)

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║   Base Infrastructure Setup Complete!                        ║${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Domain mode: ${BOLD}${domain_mode}${NC}"
    echo -e "${GREEN}║${NC}  Rancher:     ${BOLD}https://${rancher_host}${NC}"
    echo -e "${GREEN}║${NC}  Keycloak:    ${BOLD}https://${keycloak_host}${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}Next steps:${NC}                                                ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"

    if [[ "$domain_mode" == "local" ]]; then
        local wg_name=$(cfg "wireguard.name" "wireguard_app_users")
        echo -e "${GREEN}║${NC}  1. Set up Wireguard VPN on your laptop:                   ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}     • Copy peer config from: /etc/${wg_name}/peer1/  ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}     • The config includes DNS push — once connected,       ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}       your laptop will resolve *.openg2p.test automatically ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}  2. Install the CA certificate on your laptop to avoid      ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}     browser warnings:                                       ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}     • CA cert: /etc/openg2p/ca/ca.crt                      ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}     • macOS: Import into Keychain → System → Always Trust  ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}     • Windows: Import into Trusted Root CAs                ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}     • Linux: Copy to /usr/local/share/ca-certificates/     ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}              then run: sudo update-ca-certificates          ${GREEN}║${NC}"
    else
        echo -e "${GREEN}║${NC}  1. Configure Wireguard VPN on your laptop                 ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}     Peer config: /etc/wireguard_app_users/peer1/peer1.conf ${GREEN}║${NC}"
    fi

    echo -e "${GREEN}║${NC}  3. Open Rancher and bootstrap admin password              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  4. Integrate Rancher with Keycloak (OIDC)                 ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}     Docs: https://docs.openg2p.org/deployment/             ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}       deployment-instructions/infrastructure-setup          ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}       #id-11.-integrating-rancher-with-keycloak             ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  5. Run openg2p-environment.sh to create an environment    ${GREEN}║${NC}"
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

    load_config "$CONFIG_FILE"

    local domain_mode=$(cfg "domain_mode" "custom")
    log_info "Domain mode: ${BOLD}${domain_mode}${NC}"

    if [[ "$domain_mode" == "local" ]]; then
        validate_config "node_ip" "node_name"
    else
        validate_config "node_ip" "node_name" "rancher_hostname" "keycloak_hostname" "letsencrypt_email"
    fi

    local rancher_host=$(get_rancher_hostname)
    local keycloak_host=$(get_keycloak_hostname)

    log_info "Deployment log: ${LOG_FILE}"
    log_info "Config file:    ${CONFIG_FILE}"
    log_info "Node:           $(cfg 'node_name') @ $(cfg 'node_ip')"
    log_info "Rancher:        ${rancher_host}"
    log_info "Keycloak:       ${keycloak_host}"
    echo ""

    case "${RUN_PHASE:-all}" in
        1)
            check_prerequisites
            if [[ "$domain_mode" == "custom" ]]; then
                check_dns_for_domains "$(cfg 'node_ip')" "$rancher_host" "$keycloak_host"
            fi
            run_phase1
            ;;
        2)
            run_phase2
            ;;
        all)
            check_prerequisites
            if [[ "$domain_mode" == "custom" ]]; then
                check_dns_for_domains "$(cfg 'node_ip')" "$rancher_host" "$keycloak_host"
            fi
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
