#!/usr/bin/env bash
# =============================================================================
# OpenG2P Add-Node — laptop orchestrator
# =============================================================================
# Runs on your ADMIN LAPTOP.
# SSHes into the new Ubuntu 24.04 node, stages the join bundle, and executes
# the remote role script under sudo. You do NOT need to SSH in manually.
#
# Usage:
#   ./openg2p-add-node.sh --config add-node-config.yaml
#   ./openg2p-add-node.sh --config add-node-config.yaml --role worker
#   ./openg2p-add-node.sh --config add-node-config.yaml --dry-run
#   ./openg2p-add-node.sh --config add-node-config.yaml --probe
#
# After AWS provisioning, ssh_host / ssh_user / ssh_key / private_ip are taken
# from aws/provision-output.yaml automatically when present.
# =============================================================================

set -euo pipefail

trap '
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "" >&2
        echo "[FATAL] script exited with status ${rc} at line ${LINENO} (${BASH_COMMAND})" >&2
        echo "[FATAL] log: ${LOG_FILE:-<not set>}" >&2
    fi
    ssh_cleanup 2>/dev/null || true
' EXIT

if (( BASH_VERSINFO[0] < 4 )); then
    echo "[FATAL] bash 4+ required (detected ${BASH_VERSION}). On macOS: brew install bash" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
FORCE_MODE=false
DRY_RUN=false
PROBE_ONLY=false
ROLE_OVERRIDE=""
LOG_FILE="${SCRIPT_DIR}/logs/add-node-$(date '+%Y%m%d-%H%M%S').log"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/utils.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/ssh-utils.sh"

show_help() {
    cat <<'EOF'
OpenG2P Add Node — join a new Ubuntu 24.04 node to an existing RKE2 cluster
===========================================================================

Runs on your LAPTOP. SSHes into the new node and joins it to the cluster.

Usage:
  ./openg2p-add-node.sh --config add-node-config.yaml [options]

Options:
  --config <file>     Path to configuration file (required)
  --role server|worker
                      Override node_role from config
  --force             Ignore remote completion markers; re-run all join steps
  --dry-run           Probe SSH, stage nothing mutating; print what would run
                      on the remote node
  --probe             Only verify SSH + passwordless sudo to the new node
  --help, -h          Show this help

Config must include (or inherit from aws/provision-output.yaml):
  ssh_host / ssh_user / ssh_key   — how the laptop reaches the NEW node
  server_url, rke2_token, rke2_version, node_ip, node_name, node_role

What this does:
  1. Loads config (+ optional AWS provision-output overlay)
  2. Probes SSH + sudo on the new node
  3. Stages join scripts + config to /tmp/openg2p-add-node on the node
  4. Runs the remote join (ufw, RKE2 install, cluster join) under sudo
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)  CONFIG_FILE="$2"; shift 2 ;;
            --role)    ROLE_OVERRIDE="$2"; shift 2 ;;
            --force)   FORCE_MODE=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --probe)   PROBE_ONLY=true; shift ;;
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
                  "Copy add-node-config.example.yaml to add-node-config.yaml and provide it" \
                  "$0 --config add-node-config.yaml"
        exit 1
    fi
    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
    export DRY_RUN
}

resolve_role_interactive() {
    local current; current=$(cfg "node_role")
    if [[ -n "$ROLE_OVERRIDE" ]]; then
        if [[ "$ROLE_OVERRIDE" != "server" && "$ROLE_OVERRIDE" != "worker" ]]; then
            log_error "Invalid --role value: '${ROLE_OVERRIDE}'" \
                      "Must be 'server' or 'worker'"
            exit 1
        fi
        CONFIG["node_role"]="$ROLE_OVERRIDE"
        log_info "node_role overridden on CLI: ${ROLE_OVERRIDE}"
        return
    fi
    if [[ -z "$current" ]]; then
        echo ""
        echo "Which role should this node join as?"
        echo "  1) server  — control-plane node (runs etcd, apiserver). Choose this for HA."
        echo "  2) worker  — data-plane node (runs app pods only). Most common choice."
        echo ""
        local choice=""
        while [[ "$choice" != "1" && "$choice" != "2" ]]; do
            read -r -p "Enter choice [1/2]: " choice
        done
        if [[ "$choice" == "1" ]]; then
            CONFIG["node_role"]="server"
        else
            CONFIG["node_role"]="worker"
        fi
        log_info "node_role set interactively: $(cfg node_role)"
    fi
}

validate_laptop_config() {
    local errors=0
    local k
    for k in server_url rke2_token node_ip node_name rke2_version; do
        if [[ -z "$(cfg "$k")" ]]; then
            log_warn "Missing required config key: '${k}'"
            errors=$((errors + 1))
        fi
    done
    if [[ -z "$(cfg ssh_host)" ]]; then
        log_warn "Missing ssh_host (how this laptop reaches the new node)"
        errors=$((errors + 1))
    fi
    if [[ -z "$(cfg ssh_key)" ]]; then
        log_warn "Missing ssh_key (path to .pem on this laptop)"
        errors=$((errors + 1))
    fi
    if [[ $errors -gt 0 ]]; then
        log_error "Configuration validation failed with ${errors} error(s)" \
                  "Fill add-node-config.yaml (and/or run AWS provision so provision-output.yaml exists)" \
                  "See add-node-config.example.yaml"
        exit 1
    fi
}

main() {
    parse_args "$@"

    mkdir -p "${SCRIPT_DIR}/logs"
    exec > >(tee -a "$LOG_FILE") 2>&1

    log_banner "OpenG2P Add Node" "Laptop orchestrator → SSH join"
    log_info "Config: ${CONFIG_FILE}"
    log_info "Log:    ${LOG_FILE}"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Mode:   dry-run"
    fi
    echo ""

    # Do NOT require root or Ubuntu 24 on the laptop.
    load_config "$CONFIG_FILE"
    load_provision_overlay "$CONFIG_FILE" "$SCRIPT_DIR"
    resolve_role_interactive
    validate_laptop_config

    log_info "Target node: $(cfg ssh_user ubuntu)@$(cfg ssh_host)  (node_ip=$(cfg node_ip) name=$(cfg node_name) role=$(cfg node_role))"

    ssh_init
    ssh_probe node || exit 1

    if [[ "$PROBE_ONLY" == "true" ]]; then
        log_success "Probe-only complete."
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would stage join bundle to ${REMOTE_WORK_DIR}/ on the node"
        log_info "[dry-run] would run: role/run.sh --config add-node-config.yaml$( [[ "$FORCE_MODE" == "true" ]] && echo ' --force' ) --role $(cfg node_role)"
        log_success "Dry-run complete — nothing staged or changed on the remote node."
        return 0
    fi

    # Persist interactive / overlay-resolved keys into a staging copy so the
    # remote sees the same node_role / ssh-derived identity values.
    local staged_cfg
    staged_cfg=$(mktemp -t add-node-config.XXXXXX.yaml)
    cp "$CONFIG_FILE" "$staged_cfg"
    # Ensure critical keys are present on the remote config (yaml_set simple append/replace).
    _ensure_cfg_key() {
        local file="$1" key="$2" value="$3"
        local quoted="\"${value//\"/\\\"}\""
        if grep -q "^${key}:" "$file" 2>/dev/null; then
            local tmp; tmp=$(mktemp)
            awk -v k="$key" -v v="$quoted" '
                $0 ~ "^"k":" { print k": "v; next }
                { print }
            ' "$file" > "$tmp"
            mv "$tmp" "$file"
        else
            echo "${key}: ${quoted}" >> "$file"
        fi
    }
    _ensure_cfg_key "$staged_cfg" node_role "$(cfg node_role)"
    _ensure_cfg_key "$staged_cfg" node_ip "$(cfg node_ip)"
    _ensure_cfg_key "$staged_cfg" node_name "$(cfg node_name)"
    _ensure_cfg_key "$staged_cfg" server_url "$(cfg server_url)"
    _ensure_cfg_key "$staged_cfg" rke2_token "$(cfg rke2_token)"
    _ensure_cfg_key "$staged_cfg" rke2_version "$(cfg rke2_version)"
    _ensure_cfg_key "$staged_cfg" vpc_subnet "$(cfg vpc_subnet)"
    _ensure_cfg_key "$staged_cfg" wireguard_subnet "$(cfg wireguard_subnet 10.15.0.0/16)"

    ssh_stage_join "$SCRIPT_DIR" "$staged_cfg"
    rm -f "$staged_cfg"

    local remote_args=()
    [[ "$FORCE_MODE" == "true" ]] && remote_args+=(--force)
    remote_args+=(--role "$(cfg node_role)")

    log_step "1" "Join cluster on remote node"
    ssh_run_join "${remote_args[@]}" || exit 1

    echo ""
    log_success "Add-node orchestration complete."
    log_info "Verify from a control-plane: kubectl get nodes -o wide"
    log_info "Log: ${LOG_FILE}"
}

main "$@"
