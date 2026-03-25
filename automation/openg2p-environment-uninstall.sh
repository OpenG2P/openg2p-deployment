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
# Usage:
#   sudo ./openg2p-environment-uninstall.sh --config env-config.yaml
#
# Or specify the environment directly:
#   sudo ./openg2p-environment-uninstall.sh --environment qa
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""

source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/env-phase1.sh"

# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)  CONFIG_FILE="$2"; shift 2 ;;
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
                  "$0 --config env-config.yaml"
        exit 1
    fi

    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
}

show_help() {
    cat <<'EOF'
OpenG2P Environment Uninstall
================================

Usage:
  sudo ./openg2p-environment-uninstall.sh --config env-config.yaml

Options:
  --config <file>    Path to environment config file (required)
  --help             Show this help message

WARNING: This permanently deletes ALL data in the environment including
databases, files, secrets, and Kubernetes resources. This is IRREVERSIBLE.
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    check_root "$@"
    ensure_kubeconfig || exit 1

    # Load config
    load_config "$CONFIG_FILE"
    local ENV_NAME=$(cfg "environment")

    # Load infra config for domain_mode, local_domain, node_ip
    local infra_config_path=$(cfg "infra_config" "infra-config.yaml")
    [[ "$infra_config_path" = /* ]] || infra_config_path="${SCRIPT_DIR}/${infra_config_path}"
    if [[ -f "$infra_config_path" ]]; then
        load_config "$infra_config_path"
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
        # Clean state markers anyway
        rm -f "${STATE_DIR}/env-${ENV_NAME}."*.done 2>/dev/null || true
        exit 0
    fi

    # Show warning
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  WARNING: DESTRUCTIVE OPERATION                             ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║${NC}  This will ${BOLD}PERMANENTLY DELETE${NC} environment '${BOLD}${ENV_NAME}${NC}':      "
    echo -e "${RED}║${NC}                                                              ${RED}║${NC}"
    echo -e "${RED}║${NC}    • All Helm releases (commons, commons-services)           ${RED}║${NC}"
    echo -e "${RED}║${NC}    • ALL databases (PostgreSQL data)                         ${RED}║${NC}"
    echo -e "${RED}║${NC}    • ALL secrets (Keycloak clients, credentials)             ${RED}║${NC}"
    echo -e "${RED}║${NC}    • ALL persistent volumes (MinIO files, OpenSearch data)   ${RED}║${NC}"
    echo -e "${RED}║${NC}    • ALL Jobs, ServiceAccounts, ConfigMaps                   ${RED}║${NC}"
    echo -e "${RED}║${NC}    • Istio Gateway, Nginx config, TLS certificates           ${RED}║${NC}"
    echo -e "${RED}║${NC}    • Rancher Project                                         ${RED}║${NC}"
    echo -e "${RED}║${NC}    • The Kubernetes namespace itself                         ${RED}║${NC}"
    echo -e "${RED}║${NC}                                                              ${RED}║${NC}"
    echo -e "${RED}║  This action is IRREVERSIBLE.                                ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "Type 'yes' to confirm deletion of environment '${ENV_NAME}': " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""

    log_info "Uninstalling environment '${ENV_NAME}'..."

    # ── Step 1: Uninstall Helm releases ─────────────────────────────────
    log_info "Uninstalling Helm releases..."

    # Services chart first (depends on base)
    if helm status "commons-services" -n "$ENV_NAME" &>/dev/null; then
        log_info "Uninstalling commons-services..."
        helm uninstall "commons-services" -n "$ENV_NAME" --wait --timeout 5m || {
            log_warn "helm uninstall commons-services returned non-zero. Continuing..."
        }
        log_success "commons-services uninstalled."
    else
        log_info "commons-services not found — skipping."
    fi

    # Base chart
    if helm status "commons" -n "$ENV_NAME" &>/dev/null; then
        log_info "Uninstalling commons..."
        helm uninstall "commons" -n "$ENV_NAME" --wait --timeout 5m || {
            log_warn "helm uninstall commons returned non-zero. Continuing..."
        }
        log_success "commons uninstalled."
    else
        log_info "commons not found — skipping."
    fi

    # Any other releases in the namespace
    local other_releases
    other_releases=$(helm list -n "$ENV_NAME" -q 2>/dev/null || true)
    for release in $other_releases; do
        log_info "Uninstalling remaining release '${release}'..."
        helm uninstall "$release" -n "$ENV_NAME" --wait --timeout 5m || true
    done

    # ── Step 2: Clean up orphaned hook resources ────────────────────────
    log_info "Cleaning up orphaned Jobs, ServiceAccounts, ConfigMaps..."

    # Known hook resources from base chart
    for suffix in postgres-init keycloak-init client-secrets-sync; do
        kubectl delete job "commons-${suffix}" -n "$ENV_NAME" --ignore-not-found > /dev/null 2>&1 || true
        kubectl delete serviceaccount "commons-${suffix}" -n "$ENV_NAME" --ignore-not-found > /dev/null 2>&1 || true
        kubectl delete configmap "commons-${suffix}" -n "$ENV_NAME" --ignore-not-found > /dev/null 2>&1 || true
    done

    # Known hook resources from services chart
    for suffix in esignet-postgres-init mock-identity-system-postgres-init keymanager-postgres-init keymanager-keygen master-data-postgres-init superset-init-db; do
        kubectl delete job "commons-services-${suffix}" -n "$ENV_NAME" --ignore-not-found > /dev/null 2>&1 || true
        kubectl delete serviceaccount "commons-services-${suffix}" -n "$ENV_NAME" --ignore-not-found > /dev/null 2>&1 || true
    done

    # keycloak-init jobs with revision numbers
    kubectl delete jobs -n "$ENV_NAME" -l app.kubernetes.io/name=keycloak-init --ignore-not-found > /dev/null 2>&1 || true

    # Catch-all: delete ALL remaining jobs
    kubectl delete jobs -n "$ENV_NAME" --all --ignore-not-found > /dev/null 2>&1 || true

    # Clean up RBAC resources
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
    local domain_mode=$(cfg "domain_mode" "custom")
    if [[ "$domain_mode" == "local" ]]; then
        local base_domain=$(get_env_base_domain)
        if [[ -n "$base_domain" ]]; then
            log_info "Removing TLS certificate for *.${base_domain}..."
            rm -rf "/etc/openg2p/certs/${base_domain}" 2>/dev/null || true
            log_success "TLS certificate removed."
        fi
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

main "$@"
