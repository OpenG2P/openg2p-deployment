#!/usr/bin/env bash
# =============================================================================
# OpenG2P Sandbox — Base Infrastructure Setup
# =============================================================================
# Sets up the complete base infrastructure on a single Ubuntu 24.04 VM:
#   Phase 1 (bash):     Tools, firewall, RKE2, Wireguard, NFS, DNS records,
#                       Let's Encrypt TLS certificate, Nginx
#   Phase 2 (helmfile): Istio, Rancher, Monitoring, Logging
#   Phase 3 (APIs):     Rancher bootstrap (local admin, cluster name, RBAC roles, catalog repo)
#
# Hostnames live under a REAL registered domain and are published as public A
# records; certificates come from Let's Encrypt via the ACME DNS-01 challenge
# (outbound only). No local DNS server and no self-signed CA are involved.
# Private by default — the web UIs (80/443) are reachable only over Wireguard or
# from inside the VPC, even on a public IP. Set public_access: true to expose
# them to the Internet (security risk; see sandbox-config.example.yaml).
#
# Environments are installed separately — see automation/environment/.
#
# Preferred — from your laptop:
#   ./openg2p-sandbox.sh --config sandbox-config.yaml
#
# Advanced — run ON the Ubuntu VM as root:
#   sudo bash roles/infra/run.sh --config sandbox-config.yaml
#
# Optional AWS path (laptop):
#   cd aws && ./openg2p-aws-provision.sh --config aws-config.yaml
#   # If provision-output.yaml sits next to sandbox-config.yaml, it is
#   # loaded as an overlay (node_ip, wireguard.endpoint, ssh_*).
#
# Docs: https://docs.openg2p.org/deployment/deployment-instructions/infrastructure-setup
# =============================================================================

set -euo pipefail

ROLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Charts, helmfile, and lib/ live at the sandbox root (two levels up).
SCRIPT_DIR="$(cd "${ROLE_DIR}/../.." && pwd)"
CONFIG_FILE=""
PROVISION_OUTPUT=""
RUN_PHASE=""
FORCE_MODE=false
DRY_RUN=false
LOG_FILE="/var/log/openg2p-infra-$(date '+%Y%m%d-%H%M%S').log"

source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/acme.sh"
source "${SCRIPT_DIR}/lib/phase1.sh"
source "${SCRIPT_DIR}/lib/phase2.sh"
source "${SCRIPT_DIR}/lib/phase3.sh"

# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)            CONFIG_FILE="$2";       shift 2 ;;
            --provision-output)  PROVISION_OUTPUT="$2";  shift 2 ;;
            --phase)             RUN_PHASE="$2";         shift 2 ;;
            --force)             FORCE_MODE=true;        shift ;;
            --dry-run)           DRY_RUN=true;           shift ;;
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
                  "Copy sandbox-config.example.yaml to sandbox-config.yaml and provide it" \
                  "$0 --config sandbox-config.yaml"
        exit 1
    fi

    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
}

show_help() {
    cat <<'EOF'
OpenG2P Sandbox — Base Infrastructure Setup
=================================================

Usage:
  sudo bash roles/infra/run.sh --config sandbox-config.yaml [options]

Options:
  --config <file>            Path to configuration file (required)
  --provision-output <file>  Path to provision-output.yaml (auto-detected if blank)
  --phase <1|2|3>            Run only a specific phase
  --force                    Ignore completion markers, re-run all steps
  --dry-run                  Show what would be done without executing
  --reset                    Clear all infra state markers and exit
  --help                     Show this help message

Prefer the laptop orchestrator (openg2p-sandbox.sh). For AWS EC2 creation
from your laptop, use aws/openg2p-aws-provision.sh first.

Requires a REAL registered domain plus a DNS API token (see `domain` and
`tls.*` in sandbox-config.example.yaml) — certificates are issued by
Let's Encrypt over DNS-01. Free domain option: https://desec.io/

By default the sandbox is reachable only over Wireguard or from inside the VPC
— set public_access: true in the config to expose it to the public Internet
(carries security risk; see sandbox-config.example.yaml).

Docs: https://docs.openg2p.org/deployment/deployment-instructions/infrastructure-setup
EOF
}

# ---------------------------------------------------------------------------
show_summary() {
    local node_ip=$(cfg "node_ip")
    local cluster_display_name=$(cfg "cluster_name" "openg2p")
    local rancher_host=$(get_rancher_hostname)
    local domain=$(cfg "domain" "")
    local public_access=$(cfg "public_access" "false")
    # cluster_subnet is an undocumented override; default is split tunnel
    local allowed_ips=$(cfg "wireguard.cluster_subnet" "split-tunnel")

    # When driven by the laptop orchestrator, keep this brief — the
    # orchestrator prints the laptop next-steps guide.
    if [[ "${OPENG2P_ORCHESTRATED:-}" == "1" ]]; then
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║   Base Infrastructure Setup Complete (on-box)                ║${NC}"
        echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC}  Cluster:  ${BOLD}${cluster_display_name}${NC}"
        echo -e "${GREEN}║${NC}  Rancher:  ${BOLD}https://${rancher_host}${NC}"
        local saved_pw_file="/var/lib/openg2p/deploy-state/rancher-admin-password"
        if [[ -f "$saved_pw_file" ]]; then
            echo -e "${GREEN}║${NC}  Admin:    user ${BOLD}admin${NC}  password ${BOLD}$(cat "$saved_pw_file")${NC}"
        fi
        echo -e "${GREEN}║${NC}  Next steps will be printed by the laptop orchestrator.    ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}  Log: ${LOG_FILE}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        return 0
    fi

    local ssh_host ssh_user ssh_key
    ssh_host=$(cfg "ssh_host")
    if [[ -z "$ssh_host" ]]; then ssh_host=$(cfg "public_ip"); fi
    if [[ -z "$ssh_host" ]]; then ssh_host=$(cfg "wireguard.endpoint"); fi
    ssh_user=$(cfg "ssh_user" "ubuntu")
    ssh_key=$(cfg "ssh_key" "<your-key.pem>")

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║   Base Infrastructure Setup Complete!                        ║${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Cluster:     ${BOLD}${cluster_display_name}${NC}"
    echo -e "${GREEN}║${NC}  Rancher:     ${BOLD}https://${rancher_host}${NC}"
    if [[ "$public_access" == "true" ]]; then
        echo -e "${GREEN}║${NC}  Access:      ${BOLD}PUBLIC${NC} — 80/443 open to the Internet (0.0.0.0/0)"
    else
        echo -e "${GREEN}║${NC}  Access:      ${BOLD}private${NC} — reachable only via Wireguard / VPC"
    fi
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"

    if [[ -n "$ssh_host" ]]; then
        echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${GREEN}║${NC}  ${BOLD}SSH from your laptop:${NC}                                      ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}    ssh -i ${ssh_key} ${ssh_user}@${ssh_host}                 ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    fi

    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}Laptop Setup (do these steps on your machine):${NC}             ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}Step 1: Wireguard VPN${NC}                                      ${GREEN}║${NC}"
    if [[ -n "$ssh_host" ]]; then
        echo -e "${GREEN}║${NC}    From your laptop:                                         ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}      ssh -i ${ssh_key} ${ssh_user}@${ssh_host} \\              ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}        \"sudo cat /etc/wireguard/peers/peer1/peer1.conf\" \\  ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}        > peer1.conf                                          ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}    Import peer1.conf into the Wireguard app.                 ${GREEN}║${NC}"
    else
        echo -e "${GREEN}║${NC}    Copy peer config from the VM:                            ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}      sudo cp /etc/wireguard/peers/peer1/peer1.conf /tmp/    ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}      sudo chmod 644 /tmp/peer1.conf                         ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}    Then SCP to your laptop and import into Wireguard app.   ${GREEN}║${NC}"
    fi
    echo -e "${GREEN}║${NC}    If endpoint IP differs from node_ip (e.g. public IP),    ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    set wireguard.endpoint in config or edit peer1.conf.     ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"

    echo -e "${GREEN}║${NC}  ${BOLD}Step 2: DNS and certificates — nothing to do${NC}               ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Hostnames under ${domain}"
    echo -e "${GREEN}║${NC}    are public A records -> ${node_ip}, so your normal"
    echo -e "${GREEN}║${NC}    resolver answers them. No /etc/hosts, no local DNS.      ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Certificates are from Let's Encrypt — already trusted.   ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Verify:  nslookup rancher.${domain}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"

    echo -e "${GREEN}║${NC}  ${BOLD}Step 3: kubectl/helm access from laptop${NC}                    ${GREEN}║${NC}"
    if [[ -n "$ssh_host" ]]; then
        echo -e "${GREEN}║${NC}    From your laptop:                                         ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}      ssh -i ${ssh_key} ${ssh_user}@${ssh_host} \\              ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}        \"sudo cat /etc/rancher/rke2/rke2-remote.yaml\" \\     ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}        > ~/rke2-remote.yaml                                  ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}      export KUBECONFIG=~/rke2-remote.yaml                     ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}      kubectl get nodes                                        ${GREEN}║${NC}"
    else
        echo -e "${GREEN}║${NC}    Copy remote kubeconfig from the VM:                       ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}      sudo cp /etc/rancher/rke2/rke2-remote.yaml /tmp/        ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}      sudo chmod 644 /tmp/rke2-remote.yaml                     ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}    SCP to laptop, then:                                      ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}      export KUBECONFIG=~/rke2-remote.yaml                     ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}      kubectl get nodes                                        ${GREEN}║${NC}"
    fi
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}Login (Rancher uses local authentication):${NC}                  ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Open https://${rancher_host} and log in as the local admin.  ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    Username: ${BOLD}admin${NC}"
    echo -e "${GREEN}║${NC}    Password: Rancher local admin password (see below)         ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Create additional admin/users directly in Rancher:          ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    ☰ → Users & Authentication → Users                        ${GREEN}║${NC}"
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
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}What's next:${NC}                                                ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  From your laptop:                                           ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    ./openg2p-sandbox.sh --config sandbox-config.yaml \\${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}      --stage environment                                     ${GREEN}║${NC}"
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

    # Auto-detect provision-output.yaml next to sandbox-config.yaml unless
    # --provision-output was given explicitly.
    if [[ -z "$PROVISION_OUTPUT" ]]; then
        PROVISION_OUTPUT="$(dirname "$CONFIG_FILE")/provision-output.yaml"
    fi
    if [[ -f "$PROVISION_OUTPUT" ]]; then
        log_info "Loading provision-output overlay: ${PROVISION_OUTPUT}"
        load_config "$PROVISION_OUTPUT"
    else
        PROVISION_OUTPUT=""
        log_info "No provision-output.yaml found — using sandbox-config.yaml only"
    fi

    validate_config "node_ip" "node_name"

    local rancher_host=$(get_rancher_hostname)

    log_info "Deployment log: ${LOG_FILE}"
    log_info "Config file:    ${CONFIG_FILE}"
    log_info "Cluster:        $(cfg 'cluster_name' 'openg2p')"
    log_info "Node:           $(cfg 'node_name' 'node1') @ $(cfg 'node_ip')"
    log_info "Rancher:        ${rancher_host}"
    echo ""

    case "${RUN_PHASE:-all}" in
        1)
            check_prerequisites
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
