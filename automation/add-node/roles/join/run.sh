#!/usr/bin/env bash
# =============================================================================
# OpenG2P Add-Node — remote join entrypoint
# =============================================================================
# Runs ON the new Ubuntu 24.04 node (invoked via sudo from the laptop
# orchestrator). Do not run this directly unless debugging.
#
# Staged layout under /tmp/openg2p-add-node:
#   role/run.sh  lib/utils.sh  lib/add-node-steps.sh  add-node-config.yaml
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE=""
FORCE_MODE=false
DRY_RUN=false
ROLE_OVERRIDE=""

# shellcheck disable=SC1091
source "${WORK_DIR}/lib/utils.sh"
# shellcheck disable=SC1091
source "${WORK_DIR}/lib/add-node-steps.sh"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)  CONFIG_FILE="$2"; shift 2 ;;
            --role)    ROLE_OVERRIDE="$2"; shift 2 ;;
            --force)   FORCE_MODE=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --help|-h)
                echo "Remote join entrypoint — invoked by openg2p-add-node.sh from the laptop."
                exit 0
                ;;
            *)
                log_error "Unknown option: $1" "" "Remote run.sh args: --config --role --force --dry-run"
                exit 1
                ;;
        esac
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        log_error "No config file specified" "--config is required on the remote entrypoint"
        exit 1
    fi
    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${WORK_DIR}/${CONFIG_FILE}"
    export DRY_RUN
}

resolve_role_interactive() {
    local current; current=$(cfg "node_role")
    if [[ -n "$ROLE_OVERRIDE" ]]; then
        if [[ "$ROLE_OVERRIDE" != "server" && "$ROLE_OVERRIDE" != "worker" ]]; then
            log_error "Invalid --role value: '${ROLE_OVERRIDE}'" "Must be 'server' or 'worker'"
            exit 1
        fi
        CONFIG["node_role"]="$ROLE_OVERRIDE"
        log_info "node_role overridden on CLI: ${ROLE_OVERRIDE}"
        return
    fi
    if [[ -z "$current" ]]; then
        # Non-interactive remote: fail rather than prompt (no TTY from ssh).
        log_error "node_role is blank" \
                  "Set node_role in add-node-config.yaml or pass --role from the laptop" \
                  "node_role: worker   # or server"
        exit 1
    fi
}

main() {
    parse_args "$@"

    log_banner "OpenG2P Add Node (remote)" "Join this host to an existing RKE2 cluster"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Mode: dry-run (no changes will be made on this node)"
    fi

    check_root
    check_ubuntu_24

    init_state_dir
    if [[ "$FORCE_MODE" == "true" && "$DRY_RUN" != "true" ]]; then
        reset_state "add-node."
    elif [[ "$FORCE_MODE" == "true" && "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would clear add-node.* state markers (--force)"
    fi

    log_info "Loading config: $CONFIG_FILE"
    load_config "$CONFIG_FILE"
    resolve_role_interactive

    if [[ "$DRY_RUN" == "true" ]]; then
        local role; role=$(cfg node_role)
        log_info "[dry-run] would run step1_validate (config + TCP 9345 reachability)"
        log_info "[dry-run] would run step2_tools (apt packages${role:+; kubectl if role=server})"
        log_info "[dry-run] would run step3_firewall (ufw rules for VPC + Wireguard subnet)"
        log_info "[dry-run] would run step4_rke2 (install rke2 as '${role}' and join cluster)"
        log_info "[dry-run] would run step5_verify (confirm node Ready / agent active)"
        log_info "[dry-run] would write /root/openg2p-add-node-postinstall.txt"
        log_success "Dry-run complete — nothing changed on this node."
        return 0
    fi

    step1_validate
    step2_tools
    step3_firewall
    step4_rke2
    step5_verify
    print_post_install_guide

    echo ""
    log_success "Add-node workflow complete on this host."
}

main "$@"
