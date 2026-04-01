#!/usr/bin/env bash
# =============================================================================
# OpenG2P Base Infrastructure Setup
# =============================================================================
# Sets up the complete base infrastructure on a single Ubuntu 24.04 VM:
#   Phase 1 (bash):     Tools, firewall, RKE2, Wireguard, NFS, DNS, TLS, Nginx
#   Phase 2 (helmfile): Istio, Rancher, Keycloak, Monitoring, Logging
#   Phase 3 (APIs):     Rancher bootstrap, Rancher-Keycloak SAML integration
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
source "${SCRIPT_DIR}/lib/phase2.sh"
source "${SCRIPT_DIR}/lib/phase3.sh"

# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)  CONFIG_FILE="$2"; shift 2 ;;
            --phase)   RUN_PHASE="$2"; shift 2 ;;
            --force)   FORCE_MODE=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --reset)   init_state_dir; reset_state "phase1."; reset_state "phase2."; reset_state "phase3."; exit 0 ;;
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
  --phase <1|2|3>    Run only a specific phase
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
show_summary() {
    local domain_mode=$(cfg "domain_mode" "custom")
    local node_ip=$(cfg "node_ip")
    local cluster_display_name=$(cfg "cluster_name" "openg2p")
    local rancher_host=$(get_rancher_hostname)
    local keycloak_host=$(get_keycloak_hostname)
    local local_domain=$(cfg "local_domain" "openg2p.test")
    local admin_email=$(cfg "keycloak.admin_email" "admin@openg2p.org")
    # cluster_subnet is an undocumented override; default is split tunnel
    local allowed_ips=$(cfg "wireguard.cluster_subnet" "split-tunnel")

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║   Base Infrastructure Setup Complete!                        ║${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Domain mode: ${BOLD}${domain_mode}${NC}"
    echo -e "${GREEN}║${NC}  Cluster:     ${BOLD}${cluster_display_name}${NC}"
    echo -e "${GREEN}║${NC}  Rancher:     ${BOLD}https://${rancher_host}${NC}"
    echo -e "${GREEN}║${NC}  Keycloak:    ${BOLD}https://${keycloak_host}${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}Laptop Setup (do these steps on your machine):${NC}             ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}Step 1: Wireguard VPN${NC}                                      ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Copy peer config from the VM:                            ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}      sudo cp /etc/wireguard/peers/peer1/peer1.conf /tmp/    ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}      sudo chmod 644 /tmp/peer1.conf                         ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Then SCP to your laptop and import into Wireguard app.   ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    If endpoint IP differs from node_ip (e.g. public IP),    ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    set wireguard.endpoint in config or edit peer1.conf.     ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"

    if [[ "$domain_mode" == "local" ]]; then
        if [[ "$allowed_ips" == "0.0.0.0/0" ]]; then
            echo -e "${GREEN}║${NC}  ${BOLD}Step 2: DNS${NC}                                                ${GREEN}║${NC}"
            echo -e "${GREEN}║${NC}    Full tunnel — DNS push is included in peer config.      ${GREEN}║${NC}"
            echo -e "${GREEN}║${NC}    All *.${local_domain} resolves automatically.             ${GREEN}║${NC}"
        else
            echo -e "${GREEN}║${NC}  ${BOLD}Step 2: Per-domain DNS (split tunnel)${NC}                      ${GREEN}║${NC}"
            echo -e "${GREEN}║${NC}    macOS:                                                  ${GREEN}║${NC}"
            echo -e "${GREEN}║${NC}      sudo mkdir -p /etc/resolver                          ${GREEN}║${NC}"
            echo -e "${GREEN}║${NC}      echo 'nameserver ${node_ip}'                          ${GREEN}║${NC}"
            echo -e "${GREEN}║${NC}        | sudo tee /etc/resolver/${local_domain}             ${GREEN}║${NC}"
            echo -e "${GREEN}║${NC}    Windows (PowerShell as Admin):                          ${GREEN}║${NC}"
            echo -e "${GREEN}║${NC}      Add-DnsClientNrptRule -Namespace '.${local_domain}'    ${GREEN}║${NC}"
            echo -e "${GREEN}║${NC}        -NameServers '${node_ip}'                             ${GREEN}║${NC}"
            echo -e "${GREEN}║${NC}    Linux:                                                  ${GREEN}║${NC}"
            echo -e "${GREEN}║${NC}      sudo resolvectl dns wg0 ${node_ip}                     ${GREEN}║${NC}"
            echo -e "${GREEN}║${NC}      sudo resolvectl domain wg0 '~${local_domain}'          ${GREEN}║${NC}"
        fi
        echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}  ${BOLD}Step 3: Install CA certificate${NC}                             ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}    Copy /etc/openg2p/ca/ca.crt from the VM, then:           ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}    macOS:                                                   ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}      sudo security add-trusted-cert -d -r trustRoot \\      ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}        -k /Library/Keychains/System.keychain ca.crt          ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}    Windows: Import into Trusted Root CAs                    ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}    Linux:                                                   ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}      sudo cp ca.crt /usr/local/share/ca-certificates/       ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}      sudo update-ca-certificates                            ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    fi

    echo -e "${GREEN}║${NC}  ${BOLD}Step 4: kubectl/helm access from laptop${NC}                    ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Copy remote kubeconfig from the VM:                       ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}      sudo cp /etc/rancher/rke2/rke2-remote.yaml /tmp/        ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}      sudo chmod 644 /tmp/rke2-remote.yaml                     ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    SCP to laptop, then:                                      ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}      export KUBECONFIG=~/rke2-remote.yaml                     ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}      kubectl get nodes                                        ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}Login:${NC}                                                      ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Open https://${rancher_host} and click 'Login with Keycloak' ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Username: ${BOLD}${admin_email}${NC}"
    echo -e "${GREEN}║${NC}    Password: Keycloak admin password (see below)              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}Credentials (note these down!):${NC}                            ${GREEN}║${NC}"
    # Show Rancher admin password if saved
    local saved_pw_file="/var/lib/openg2p/deploy-state/rancher-admin-password"
    if [[ -f "$saved_pw_file" ]]; then
        local saved_pw
        saved_pw=$(cat "$saved_pw_file")
        echo -e "${GREEN}║${NC}  Rancher local admin:    user: ${BOLD}admin${NC}  password: ${BOLD}${saved_pw}${NC}"
        echo -e "${GREEN}║${NC}  (also in K8s secret: cattle-system/rancher-secret)         ${GREEN}║${NC}"
    fi
    echo -e "${GREEN}║${NC}  Keycloak admin password: see K8s secret                    ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    keycloak-system/keycloak (key: admin-password)            ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}What's next:${NC}                                                ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Run openg2p-environment.sh to create an environment.       ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}AWS EC2 users:${NC}                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Create and attach a security group for your instance:      ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    cd automation/single-node/aws                             ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    ./create-security-group.sh --vpc-id <VPC_ID>             ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Also disable source/dest check on the instance:            ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    aws ec2 modify-instance-attribute \\                      ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}      --instance-id <ID> --no-source-dest-check              ${GREEN}║${NC}"
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

    log_banner "OpenG2P Base Infrastructure Setup" "Single-node · Phase 1 + Phase 2"

    check_root "$@"
    init_state_dir

    if [[ "$FORCE_MODE" == "true" ]]; then
        reset_state "phase1."
        reset_state "phase2."
        reset_state "phase3."
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
    log_info "Cluster:        $(cfg 'cluster_name' 'openg2p')"
    log_info "Node:           $(cfg 'node_name' 'node1') @ $(cfg 'node_ip')"
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
        3)
            run_phase3
            ;;
        all)
            check_prerequisites
            if [[ "$domain_mode" == "custom" ]]; then
                check_dns_for_domains "$(cfg 'node_ip')" "$rancher_host" "$keycloak_host"
            fi
            run_phase1
            run_phase2
            run_phase3
            show_summary
            ;;
        *)
            log_error "Invalid phase: ${RUN_PHASE}" \
                      "Valid phases are: 1, 2, 3, or omit for all" \
                      "Use --phase 1, --phase 2, or --phase 3"
            exit 1
            ;;
    esac

    if [[ "${RUN_PHASE:-all}" == "all" ]]; then
        log_success "Base infrastructure setup completed successfully!"
    fi
}

# Redirect all output to both console and log file.
# We use exec + process substitution instead of piping (main | tee) because
# piping runs main in a subshell where set -e is disabled for pipeline
# commands, which could mask failures and let the script continue silently.
exec > >(tee -a "$LOG_FILE") 2>&1

main "$@"
