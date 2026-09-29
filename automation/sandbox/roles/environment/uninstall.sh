#!/usr/bin/env bash
# =============================================================================
# OpenG2P Environment Uninstall
# =============================================================================
# Completely removes an OpenG2P environment: Helm releases, hooks, secrets,
# PVCs, PVs, Istio Gateway, Nginx config, Rancher Project, and namespace.
#
# WARNING: This is DESTRUCTIVE and IRREVERSIBLE. All data in the environment
# (databases, files, secrets) will be permanently deleted.
#
# Preferred — from your laptop (SSHes into the VM):
#   ./roles/environment/uninstall.sh --config environment-config.yaml
#
# Advanced — run ON the Ubuntu VM as root:
#   sudo ./roles/environment/uninstall.sh --config environment-config.yaml
# =============================================================================

set -uo pipefail   # NOT -e — uninstall should continue when bits are missing

ROLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Charts, helmfile, and lib/ live at the sandbox root (two levels up).
SCRIPT_DIR="$(cd "${ROLE_DIR}/../.." && pwd)"
CONFIG_FILE=""
ASSUME_YES=false

source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/env-phase1.sh"

# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)  CONFIG_FILE="$2"; shift 2 ;;
            --yes|-y)  ASSUME_YES=true; shift ;;
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
                  "Provide the same config used during environment setup" \
                  "$0 --config environment-config.yaml"
        exit 1
    fi

    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
}

show_help() {
    cat <<'EOF'
OpenG2P Environment Uninstall
================================

Preferred (from your laptop — SSHes into the VM):
  ./roles/environment/uninstall.sh --config environment-config.yaml

Advanced (ON the Ubuntu VM, as root):
  sudo ./roles/environment/uninstall.sh --config environment-config.yaml

Options:
  --config <file>    Path to environment config file (required)
  --yes / -y         Skip the typed confirmation prompt
  --help             Show this help message

WARNING: This permanently deletes ALL data in the environment including
databases, files, secrets, and Kubernetes resources. This is IRREVERSIBLE.
EOF
}

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
    PROVISION_OUTPUT_RESOLVED=""
    local sandbox_config_path
    sandbox_config_path=$(resolve_sandbox_config_path)
    if [[ -f "$sandbox_config_path" ]]; then
        log_info "Loading sandbox config from: ${sandbox_config_path}"
        load_config "$sandbox_config_path"
        load_config "$CONFIG_FILE"
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

confirm_env_delete() {
    local env_name="$1"

    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  WARNING: DESTRUCTIVE OPERATION                             ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║${NC}  This will ${BOLD}PERMANENTLY DELETE${NC} environment '${BOLD}${env_name}${NC}':      "
    echo -e "${RED}║${NC}                                                              ${RED}║${NC}"
    echo -e "${RED}║${NC}    • All Helm releases (commons, commons-services)           ${RED}║${NC}"
    echo -e "${RED}║${NC}    • ALL databases (PostgreSQL data)                         ${RED}║${NC}"
    echo -e "${RED}║${NC}    • ALL secrets (Keycloak clients, credentials)             ${RED}║${NC}"
    echo -e "${RED}║${NC}    • ALL persistent volumes (MinIO files, PVC data)          ${RED}║${NC}"
    echo -e "${RED}║${NC}    • ALL Jobs, ServiceAccounts, ConfigMaps                   ${RED}║${NC}"
    echo -e "${RED}║${NC}    • Istio Gateway, Nginx config, TLS certificates           ${RED}║${NC}"
    echo -e "${RED}║${NC}    • Rancher Project                                         ${RED}║${NC}"
    echo -e "${RED}║${NC}    • The Kubernetes namespace itself                         ${RED}║${NC}"
    echo -e "${RED}║${NC}                                                              ${RED}║${NC}"
    echo -e "${RED}║  This action is IRREVERSIBLE.                                ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ "$ASSUME_YES" == "true" ]]; then
        log_info "--yes set; skipping confirmation prompt."
        return 0
    fi

    local confirm
    read -rp "Type 'yes' to confirm deletion of environment '${env_name}': " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Laptop path — confirm locally, then SSH and run on-box uninstall.
# ---------------------------------------------------------------------------
run_from_laptop() {
    log_banner "OpenG2P Environment Uninstall" "Laptop · SSH → on-box teardown"

    if [[ $EUID -eq 0 ]]; then
        log_warn "You are running this with sudo on the laptop — that is not needed."
        log_warn "Prefer: ./roles/environment/uninstall.sh --config environment-config.yaml"
        echo ""
    fi

    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/lib/ssh-utils.sh"

    load_config "$CONFIG_FILE"
    local env_name
    env_name=$(cfg "environment")

    local sandbox_config_path
    sandbox_config_path=$(resolve_sandbox_config_path)
    load_sn_and_provision_overlays
    local provision_output="${PROVISION_OUTPUT_RESOLVED:-}"

    if [[ -z "$env_name" ]]; then
        log_error "Could not determine environment name" \
                  "The 'environment' key is missing or empty in your config"
        exit 1
    fi

    if ! ssh_endpoint_available; then
        log_error "Cannot reach the sandbox VM from this laptop" \
                  "Kubeconfig is not local (this is not the RKE2 node) and ssh_host/ssh_key are blank" \
                  "Set ssh_* in provision-output.yaml or sandbox-config.yaml, or run on the VM" \
                  "./roles/environment/uninstall.sh --config environment-config.yaml"
        exit 1
    fi

    if [[ ! -f "$sandbox_config_path" ]]; then
        log_error "sandbox-config.yaml not found: ${sandbox_config_path}" \
                  "Environment uninstall from the laptop needs the sandbox config for SSH" \
                  "Set sandbox_config in environment-config.yaml"
        exit 1
    fi

    confirm_env_delete "$env_name"

    ssh_init
    trap 'ssh_cleanup 2>/dev/null || true' EXIT
    ssh_probe "node" || exit 1

    ssh_stage_sandbox "$SCRIPT_DIR" "$sandbox_config_path" "$provision_output" "$CONFIG_FILE"

    local remote_cmd="cd ${REMOTE_WORK_DIR} && OPENG2P_ORCHESTRATED=1 bash roles/environment/uninstall.sh --config environment-config.yaml --yes"
    log_info "Remote: ${remote_cmd}"
    if ssh_run "node" "$remote_cmd"; then
        log_success "Environment '${env_name}' removed on the remote node."
    else
        log_warn "Remote uninstall reported errors — check the remote log / kubectl."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# On-box path — tear down the environment on the RKE2 VM.
# ---------------------------------------------------------------------------
run_onbox() {
    check_root "$@"
    ensure_kubeconfig || exit 1

    load_config "$CONFIG_FILE"
    local ENV_NAME
    ENV_NAME=$(cfg "environment")

    local sandbox_config_path
    sandbox_config_path=$(resolve_sandbox_config_path)
    if [[ -f "$sandbox_config_path" ]]; then
        load_config "$sandbox_config_path"
        load_config "$CONFIG_FILE"
    fi

    local provision_output
    provision_output="$(dirname "$CONFIG_FILE")/provision-output.yaml"
    if [[ -f "$provision_output" ]]; then
        load_config "$provision_output"
        load_config "$CONFIG_FILE"
    fi

    if [[ -z "$ENV_NAME" ]]; then
        log_error "Could not determine environment name" \
                  "The 'environment' key is missing or empty in your config"
        exit 1
    fi

    # Check namespace exists
    if ! kubectl get namespace "$ENV_NAME" &>/dev/null; then
        log_warn "Namespace '${ENV_NAME}' does not exist. Nothing to uninstall."
        rm -f "${STATE_DIR}/env-${ENV_NAME}."*.done 2>/dev/null || true
        exit 0
    fi

    confirm_env_delete "$ENV_NAME"

    log_info "Uninstalling environment '${ENV_NAME}'..."

    # ── Step 1: Uninstall Helm releases ─────────────────────────────────
    log_info "Uninstalling Helm releases..."

    if helm status "commons-services" -n "$ENV_NAME" &>/dev/null; then
        log_info "Uninstalling commons-services..."
        helm uninstall "commons-services" -n "$ENV_NAME" --wait --timeout 5m || {
            log_warn "helm uninstall commons-services returned non-zero. Continuing..."
        }
        log_success "commons-services uninstalled."
    else
        log_info "commons-services not found — skipping."
    fi

    if helm status "commons" -n "$ENV_NAME" &>/dev/null; then
        log_info "Uninstalling commons..."
        helm uninstall "commons" -n "$ENV_NAME" --wait --timeout 5m || {
            log_warn "helm uninstall commons returned non-zero. Continuing..."
        }
        log_success "commons uninstalled."
    else
        log_info "commons not found — skipping."
    fi

    local other_releases
    other_releases=$(helm list -n "$ENV_NAME" -q 2>/dev/null || true)
    for release in $other_releases; do
        log_info "Uninstalling remaining release '${release}'..."
        helm uninstall "$release" -n "$ENV_NAME" --wait --timeout 5m || true
    done

    # ── Step 2: Clean up orphaned hook resources ────────────────────────
    log_info "Cleaning up orphaned Jobs, ServiceAccounts, ConfigMaps..."

    for suffix in postgres-init keycloak-init client-secrets-sync; do
        kubectl delete job "commons-${suffix}" -n "$ENV_NAME" --ignore-not-found > /dev/null 2>&1 || true
        kubectl delete serviceaccount "commons-${suffix}" -n "$ENV_NAME" --ignore-not-found > /dev/null 2>&1 || true
        kubectl delete configmap "commons-${suffix}" -n "$ENV_NAME" --ignore-not-found > /dev/null 2>&1 || true
    done

    for suffix in esignet-postgres-init mock-identity-system-postgres-init keymanager-postgres-init keymanager-keygen master-data-postgres-init superset-init-db; do
        kubectl delete job "commons-services-${suffix}" -n "$ENV_NAME" --ignore-not-found > /dev/null 2>&1 || true
        kubectl delete serviceaccount "commons-services-${suffix}" -n "$ENV_NAME" --ignore-not-found > /dev/null 2>&1 || true
    done

    kubectl delete jobs -n "$ENV_NAME" -l app.kubernetes.io/name=keycloak-init --ignore-not-found > /dev/null 2>&1 || true
    kubectl delete jobs -n "$ENV_NAME" --all --ignore-not-found > /dev/null 2>&1 || true

    kubectl delete rolebinding "commons-client-secrets-sync" -n "$ENV_NAME" --ignore-not-found > /dev/null 2>&1 || true
    kubectl delete role "commons-client-secrets-sync" -n "$ENV_NAME" --ignore-not-found > /dev/null 2>&1 || true

    log_success "Orphaned resources cleaned up."

    # ── Step 3: Delete ALL secrets ──────────────────────────────────────
    log_info "Deleting ALL secrets in namespace '${ENV_NAME}'..."
    kubectl delete secrets -n "$ENV_NAME" --all --ignore-not-found > /dev/null 2>&1 || true
    log_success "Secrets deleted."

    # ── Step 4: Delete PVCs and PVs ─────────────────────────────────────
    log_info "Deleting PVCs and associated PVs..."
    local pv_names
    pv_names=$(kubectl get pvc -n "$ENV_NAME" -o jsonpath='{.items[*].spec.volumeName}' 2>/dev/null || true)
    kubectl delete pvc -n "$ENV_NAME" --all --ignore-not-found > /dev/null 2>&1 || true

    if [[ -n "$pv_names" ]]; then
        sleep 5
        for pv in $pv_names; do
            kubectl delete pv "$pv" --ignore-not-found > /dev/null 2>&1 || true
        done
    fi
    log_success "PVCs and PVs deleted."

    # ── Step 5: Delete Istio Gateway ────────────────────────────────────
    log_info "Deleting Istio Gateway..."
    kubectl -n "$ENV_NAME" delete gateway internal --ignore-not-found > /dev/null 2>&1 || true
    log_success "Istio Gateway deleted."

    # ── Step 6: Remove Nginx config ─────────────────────────────────────
    log_info "Removing Nginx config..."
    rm -f "/etc/nginx/sites-enabled/openg2p-env-${ENV_NAME}.conf" 2>/dev/null || true
    rm -f "/etc/nginx/sites-available/openg2p-env-${ENV_NAME}.conf" 2>/dev/null || true
    if nginx -t &>/dev/null; then
        systemctl reload nginx 2>/dev/null || true
    fi
    log_success "Nginx config removed."

    # ── Step 7: Remove TLS certificates ─────────────────────────────────
    local base_domain
    base_domain=$(get_env_base_domain)
    if [[ -n "$base_domain" ]]; then
        log_info "Removing TLS certificate for *.${base_domain}..."
        rm -rf "/etc/openg2p/certs/${base_domain}" 2>/dev/null || true

        # Also drop acme.sh's copy, otherwise its cron keeps renewing a
        # certificate for an environment that no longer exists.
        if [[ -x /opt/acme.sh/acme.sh ]]; then
            /opt/acme.sh/acme.sh --remove -d "$base_domain" --ecc \
                --home /opt/acme.sh --config-home /opt/acme.sh/data > /dev/null 2>&1 || true
            rm -rf "/opt/acme.sh/certs/${base_domain}_ecc" 2>/dev/null || true
        fi
        log_success "TLS certificate removed (renewal stopped)."
        log_warn "DNS records *.${base_domain} / ${base_domain} were NOT deleted —"
        log_warn "  remove them in your DNS provider if this environment is gone for good."
    fi

    # ── Step 8: Remove Rancher Project ──────────────────────────────────
    log_info "Removing Rancher Project..."
    local project_id
    project_id=$(kubectl get projects.management.cattle.io -n local \
        -o json 2>/dev/null | \
        jq -r --arg name "$ENV_NAME" \
        '.items[] | select(.spec.displayName == $name) | .metadata.name' 2>/dev/null | head -1 || true)

    if [[ -n "$project_id" ]]; then
        kubectl delete projects.management.cattle.io "$project_id" -n local --ignore-not-found > /dev/null 2>&1 || {
            log_warn "Could not delete Rancher Project. Remove it manually in Rancher UI."
        }
        log_success "Rancher Project '${ENV_NAME}' deleted."
    else
        log_info "No Rancher Project found for '${ENV_NAME}'."
    fi

    # ── Step 9: Delete namespace ────────────────────────────────────────
    log_info "Deleting namespace '${ENV_NAME}'..."
    kubectl delete namespace "$ENV_NAME" --ignore-not-found --timeout=120s > /dev/null 2>&1 || {
        log_warn "Namespace deletion timed out. It may still be terminating."
        log_warn "Check: kubectl get namespace ${ENV_NAME}"
    }
    log_success "Namespace '${ENV_NAME}' deleted."

    # ── Step 10: Clean state markers ────────────────────────────────────
    log_info "Cleaning up state markers..."
    rm -f "${STATE_DIR}/env-${ENV_NAME}."*.done 2>/dev/null || true
    log_success "State markers cleaned."

    # ── Done ────────────────────────────────────────────────────────────
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║   Environment '${ENV_NAME}' completely removed.${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    if is_onbox_node; then
        run_onbox "$@"
    else
        run_from_laptop
    fi
}

main "$@"
