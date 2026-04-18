#!/usr/bin/env bash
# =============================================================================
# OpenG2P Environment Teardown for Multi-Node Configuration — Cluster
# =============================================================================
# Reverse of env-cluster.sh. Runs from your workstation (or any machine with
# kubectl access) to tear down resources created in the environment namespace.
#
# Default mode (without --full):
#   - Uninstalls ALL Helm releases in the namespace (commons, commons-services,
#     and any other OpenG2P modules: Registry, PBMS, SPAR, G2P Bridge, etc.)
#   - Cleans orphaned hook resources (Jobs, ServiceAccounts, Roles, etc.)
#   - Deletes all Secrets and PVCs (including backing PVs) in the namespace
#   - PRESERVES: namespace, Istio Gateway, Rancher Project, Nginx config,
#                DNS records, TLS certificates
#
# --full mode:
#   - Everything in default mode, PLUS:
#   - Deletes the Istio Gateway
#   - Removes the namespace from its Rancher Project (and deletes the project
#     if the management CRD is available)
#   - Deletes the namespace itself
#   - PRESERVES: Nginx config, DNS records, TLS certificates (infra-level)
#
# This script NEVER touches:
#   - DNS records or the Nginx node
#   - Let's Encrypt certificates
#   - The cluster / Rancher / Istio installation itself
#   - Any other namespaces on the same cluster
#
# Usage:
#   ./env-cluster-uninstall.sh --config env-config.yaml              # default
#   ./env-cluster-uninstall.sh --config env-config.yaml --full       # full
#   ./env-cluster-uninstall.sh --config env-config.yaml --dry-run    # preview
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
FULL_MODE=false
SKIP_CONFIRM=false
DRY_RUN=false

source "${SCRIPT_DIR}/lib/utils.sh"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)  CONFIG_FILE="$2"; shift 2 ;;
            --full)    FULL_MODE=true; shift ;;
            --yes)     SKIP_CONFIRM=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --help|-h) show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1" \
                          "This flag is not recognized" \
                          "Run with --help to see available options"
                exit 1
                ;;
        esac
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        log_error "No config file specified" \
                  "The --config flag is required" \
                  "Provide the path to your env-config.yaml" \
                  "$0 --config env-config.yaml"
        exit 1
    fi

    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
}

show_help() {
    cat <<'EOF'
OpenG2P Environment Teardown for Multi-Node Configuration
=========================================================

Usage:
  ./env-cluster-uninstall.sh --config env-config.yaml [options]

Options:
  --config <file>    Path to environment config file (required)
  --full             Also delete Istio Gateway, Rancher Project, and namespace
  --yes              Skip confirmation prompt (for automation)
  --dry-run          Show what would be deleted, don't actually delete
  --help             Show this help message

Default (without --full):
  Uninstalls ALL Helm releases in the namespace (commons, commons-services,
  and any other module charts), cleans orphaned hook resources, and deletes
  all Secrets and PVCs. The namespace, Istio Gateway, and Rancher Project
  are preserved so the environment can be quickly reinstalled with
  env-cluster.sh.

--full:
  In addition, deletes the Istio Gateway, Rancher Project, and the
  namespace itself. Preserves infra-level resources (Nginx, certs, DNS).
EOF
}

# ---------------------------------------------------------------------------
# Preview: list resources that would be deleted
# ---------------------------------------------------------------------------
count_or_zero() {
    local value
    value=$(cat || true)
    if [[ -z "$value" ]]; then
        echo "0"
    else
        echo "$value" | wc -l | tr -d ' '
    fi
}

show_preview() {
    local env_name=$(cfg "environment")

    echo ""
    if [[ "$FULL_MODE" == "true" ]]; then
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  FULL TEARDOWN — the following WILL be deleted               ║${NC}"
        echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════╣${NC}"
    else
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  DEFAULT TEARDOWN — the following WILL be deleted            ║${NC}"
        echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════╣${NC}"
    fi
    echo -e "${YELLOW}║${NC}  Namespace: ${BOLD}${env_name}${NC}"
    echo -e "${YELLOW}║${NC}"

    # Helm releases
    local helm_releases
    helm_releases=$(helm list -n "$env_name" -q 2>/dev/null || true)
    local helm_count
    helm_count=$(echo -n "$helm_releases" | count_or_zero)
    echo -e "${YELLOW}║${NC}  ${BOLD}Helm releases${NC} (${helm_count}):"
    if [[ -n "$helm_releases" ]]; then
        while IFS= read -r r; do
            echo -e "${YELLOW}║${NC}    - ${r}"
        done <<< "$helm_releases"
    else
        echo -e "${YELLOW}║${NC}    (none)"
    fi
    echo -e "${YELLOW}║${NC}"

    # Jobs
    local jobs_count
    jobs_count=$(kubectl get jobs -n "$env_name" --no-headers 2>/dev/null | count_or_zero)
    echo -e "${YELLOW}║${NC}  ${BOLD}Jobs${NC} (hook leftovers): ${jobs_count}"

    # Secrets
    local secrets_count
    secrets_count=$(kubectl get secrets -n "$env_name" --no-headers 2>/dev/null | count_or_zero)
    echo -e "${YELLOW}║${NC}  ${BOLD}Secrets${NC}: ${secrets_count}"

    # PVCs + PVs
    local pvc_list
    pvc_list=$(kubectl get pvc -n "$env_name" -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.volumeName}{"\n"}{end}' 2>/dev/null || true)
    local pvc_count
    pvc_count=$(echo -n "$pvc_list" | count_or_zero)
    echo -e "${YELLOW}║${NC}  ${BOLD}PVCs + PVs${NC} (${pvc_count}):"
    if [[ -n "$pvc_list" ]]; then
        while IFS= read -r line; do
            echo -e "${YELLOW}║${NC}    - ${line}"
        done <<< "$pvc_list"
    else
        echo -e "${YELLOW}║${NC}    (none)"
    fi

    if [[ "$FULL_MODE" == "true" ]]; then
        echo -e "${YELLOW}║${NC}"
        echo -e "${YELLOW}║${NC}  ${BOLD}Istio Gateways${NC}:"
        local gw_list
        gw_list=$(kubectl get gateway -n "$env_name" -o name 2>/dev/null || true)
        if [[ -n "$gw_list" ]]; then
            while IFS= read -r gw; do
                echo -e "${YELLOW}║${NC}    - ${gw}"
            done <<< "$gw_list"
        else
            echo -e "${YELLOW}║${NC}    (none)"
        fi

        # Rancher project
        echo -e "${YELLOW}║${NC}"
        echo -e "${YELLOW}║${NC}  ${BOLD}Rancher Project association${NC}:"
        local project_id
        project_id=$(kubectl get namespace "$env_name" \
            -o jsonpath='{.metadata.annotations.field\.cattle\.io/projectId}' 2>/dev/null || true)
        if [[ -n "$project_id" ]]; then
            echo -e "${YELLOW}║${NC}    - ${project_id} (will unlink; project deleted if Rancher CRD present)"
        else
            echo -e "${YELLOW}║${NC}    (none)"
        fi

        echo -e "${YELLOW}║${NC}"
        echo -e "${YELLOW}║${NC}  ${BOLD}Namespace itself${NC}: ${env_name}"
    fi

    echo -e "${YELLOW}║${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║${NC}  ${BOLD}PRESERVED${NC} (not touched by this script):"
    if [[ "$FULL_MODE" == "true" ]]; then
        echo -e "${YELLOW}║${NC}    - Nginx config on the Nginx node"
        echo -e "${YELLOW}║${NC}    - Let's Encrypt certificates"
        echo -e "${YELLOW}║${NC}    - DNS records"
        echo -e "${YELLOW}║${NC}    - Cluster/Rancher/Istio installations"
    else
        echo -e "${YELLOW}║${NC}    - Namespace '${env_name}'"
        echo -e "${YELLOW}║${NC}    - Istio Gateway"
        echo -e "${YELLOW}║${NC}    - Rancher Project"
        echo -e "${YELLOW}║${NC}    - Nginx config, certificates, DNS records"
    fi
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
confirm_or_exit() {
    local env_name=$(cfg "environment")

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY RUN — no resources will be deleted."
        return 0
    fi

    if [[ "$SKIP_CONFIRM" == "true" ]]; then
        log_warn "Skipping confirmation (--yes)."
        return 0
    fi

    if [[ "$FULL_MODE" == "true" ]]; then
        echo -e "${RED}${BOLD}This will permanently delete the namespace and all data in it.${NC}"
        echo -n "To confirm, type the environment name '${env_name}': "
        read -r response
        if [[ "$response" != "$env_name" ]]; then
            log_error "Confirmation failed" \
                      "Expected '${env_name}', got '${response}'" \
                      "Aborting — no changes made"
            exit 1
        fi
    else
        echo -e "${RED}${BOLD}This will uninstall Helm releases and delete all Secrets/PVCs.${NC}"
        echo -n "Type 'yes' to continue: "
        read -r response
        if [[ "$response" != "yes" ]]; then
            log_error "Confirmation failed" \
                      "Aborting — no changes made"
            exit 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Wrapper: run a command, or just log it in dry-run mode
# ---------------------------------------------------------------------------
run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${BLUE}[DRY-RUN]${NC} $*"
    else
        eval "$@"
    fi
}

# ---------------------------------------------------------------------------
# Step 1: Uninstall ALL Helm releases in the namespace
# ---------------------------------------------------------------------------
# Discovers every Helm release in the namespace and uninstalls them all.
# Most OpenG2P modules (Registry, PBMS, SPAR, G2P Bridge, etc.) depend on
# commons infrastructure (PostgreSQL, Kafka, MinIO, Keycloak from the
# `commons` release), so we uninstall `commons` LAST. Other releases are
# uninstalled first in the order Helm returns them.
step_uninstall_helm_releases() {
    local env_name=$(cfg "environment")

    log_step "1" "Uninstalling all Helm releases in '${env_name}'"

    local all_releases
    all_releases=$(helm list -n "$env_name" -q 2>/dev/null || true)

    if [[ -z "$all_releases" ]]; then
        log_info "No Helm releases found in '${env_name}' — skipping."
        return 0
    fi

    # Split into: commons (last) and everything else (first).
    local other_releases=""
    local has_commons=false
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        if [[ "$r" == "commons" ]]; then
            has_commons=true
        else
            other_releases+="${r}"$'\n'
        fi
    done <<< "$all_releases"

    # Uninstall everything EXCEPT commons first
    if [[ -n "$other_releases" ]]; then
        while IFS= read -r release; do
            [[ -z "$release" ]] && continue
            log_info "Uninstalling Helm release '${release}'..."
            run_cmd "helm uninstall '${release}' -n '${env_name}' --wait --timeout 5m || true"
            log_success "Helm release '${release}' uninstalled."
        done <<< "$other_releases"
    fi

    # Uninstall commons last — other releases may depend on its infra
    if [[ "$has_commons" == "true" ]]; then
        log_info "Uninstalling Helm release 'commons' (infrastructure — last)..."
        run_cmd "helm uninstall 'commons' -n '${env_name}' --wait --timeout 5m || true"
        log_success "Helm release 'commons' uninstalled."
    fi
}

# ---------------------------------------------------------------------------
# Step 2: Clean orphaned hook resources
# ---------------------------------------------------------------------------
step_clean_hook_resources() {
    local env_name=$(cfg "environment")

    log_step "2" "Cleaning orphaned hook resources in '${env_name}'"

    # Jobs — Helm hooks often leave these behind
    run_cmd "kubectl delete jobs -n '${env_name}' --all --ignore-not-found"

    # Hook ServiceAccounts, ConfigMaps, Roles, RoleBindings
    for release in commons commons-services; do
        for suffix in postgres-init keycloak-init client-secrets-sync; do
            run_cmd "kubectl delete serviceaccount '${release}-${suffix}' -n '${env_name}' --ignore-not-found > /dev/null 2>&1 || true"
            run_cmd "kubectl delete configmap '${release}-${suffix}' -n '${env_name}' --ignore-not-found > /dev/null 2>&1 || true"
            run_cmd "kubectl delete rolebinding '${release}-${suffix}' -n '${env_name}' --ignore-not-found > /dev/null 2>&1 || true"
            run_cmd "kubectl delete role '${release}-${suffix}' -n '${env_name}' --ignore-not-found > /dev/null 2>&1 || true"
        done
    done

    log_success "Hook resources cleaned."
}

# ---------------------------------------------------------------------------
# Step 3: Delete Secrets
# ---------------------------------------------------------------------------
step_delete_secrets() {
    local env_name=$(cfg "environment")

    log_step "3" "Deleting all Secrets in '${env_name}'"

    run_cmd "kubectl delete secrets -n '${env_name}' --all --ignore-not-found"
    log_success "Secrets deleted."
}

# ---------------------------------------------------------------------------
# Step 4: Delete PVCs and PVs
# ---------------------------------------------------------------------------
step_delete_pvcs() {
    local env_name=$(cfg "environment")

    log_step "4" "Deleting PVCs and associated PVs in '${env_name}'"

    # Capture PV names before deleting PVCs (otherwise we lose the mapping)
    local pv_names
    pv_names=$(kubectl get pvc -n "$env_name" -o jsonpath='{.items[*].spec.volumeName}' 2>/dev/null || true)

    run_cmd "kubectl delete pvc -n '${env_name}' --all --ignore-not-found"

    if [[ -n "$pv_names" ]]; then
        # Give the PVCs a moment to release their PVs
        if [[ "$DRY_RUN" != "true" ]]; then
            sleep 5
        fi
        for pv in $pv_names; do
            run_cmd "kubectl delete pv '${pv}' --ignore-not-found"
        done
    fi

    log_success "PVCs and PVs deleted."
}

# ---------------------------------------------------------------------------
# Step 5 (--full): Delete Istio Gateway
# ---------------------------------------------------------------------------
step_delete_istio_gateway() {
    local env_name=$(cfg "environment")

    log_step "5" "Deleting Istio Gateway(s) in '${env_name}'"

    run_cmd "kubectl delete gateway --all -n '${env_name}' --ignore-not-found"
    log_success "Istio Gateways deleted."
}

# ---------------------------------------------------------------------------
# Step 6 (--full): Remove Rancher Project association and delete project
# ---------------------------------------------------------------------------
step_delete_rancher_project() {
    local env_name=$(cfg "environment")

    log_step "6" "Removing Rancher Project for '${env_name}'"

    # Read the project ID from the namespace annotation (before namespace deletion)
    local project_full
    project_full=$(kubectl get namespace "$env_name" \
        -o jsonpath='{.metadata.annotations.field\.cattle\.io/projectId}' 2>/dev/null || true)

    if [[ -z "$project_full" ]]; then
        log_info "Namespace has no Rancher Project annotation — skipping."
        return 0
    fi

    # project_full is like "local:p-xxxxx"
    local project_id="${project_full#*:}"
    log_info "Found Rancher Project association: ${project_full}"

    # If the management CRD exists, delete the project; otherwise instruct manual deletion
    if kubectl get crd projects.management.cattle.io &>/dev/null; then
        run_cmd "kubectl delete projects.management.cattle.io '${project_id}' -n local --ignore-not-found"
        log_success "Rancher Project '${project_id}' deleted."
    else
        log_manual_action \
            "Rancher management CRD not on this cluster — can't delete the project via kubectl." \
            "Delete Project ID '${project_id}' manually:" \
            "  Rancher UI → Cluster → Projects/Namespaces → ${project_id} → Delete"
    fi
}

# ---------------------------------------------------------------------------
# Step 7 (--full): Delete the namespace
# ---------------------------------------------------------------------------
step_delete_namespace() {
    local env_name=$(cfg "environment")

    log_step "7" "Deleting namespace '${env_name}'"

    if kubectl get namespace "$env_name" &>/dev/null; then
        run_cmd "kubectl delete namespace '${env_name}' --ignore-not-found"
        log_success "Namespace '${env_name}' deleted."
    else
        log_info "Namespace '${env_name}' does not exist — skipping."
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
show_summary() {
    local env_name=$(cfg "environment")
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${GREEN}║   DRY RUN complete — no resources were actually deleted.    ║${NC}"
    elif [[ "$FULL_MODE" == "true" ]]; then
        echo -e "${GREEN}║   Full teardown complete for '${env_name}'.${NC}"
    else
        echo -e "${GREEN}║   Default teardown complete for '${env_name}'.${NC}"
    fi
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    if [[ "$FULL_MODE" != "true" && "$DRY_RUN" != "true" ]]; then
        echo -e "${GREEN}║${NC}  Re-install anytime with:                                    "
        echo -e "${GREEN}║${NC}    ${BOLD}./env-cluster.sh --config ${CONFIG_FILE##*/}${NC}"
    fi
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    log_banner "OpenG2P Environment Teardown" "Cluster · Uninstall"

    load_config "$CONFIG_FILE"

    local env_name=$(cfg "environment")

    if [[ -z "$env_name" ]]; then
        log_error "No environment name specified" \
                  "The 'environment' key is missing or empty in the config" \
                  "Check your env-config.yaml"
        exit 1
    fi

    # Verify kubectl access
    ensure_kubeconfig || exit 1
    kubectl cluster-info &>/dev/null || {
        log_error "Cannot connect to Kubernetes cluster" \
                  "kubectl cluster-info failed" \
                  "Check your KUBECONFIG and cluster connectivity" \
                  "kubectl cluster-info"
        exit 1
    }

    # Verify helm is available
    check_command "helm" "Install Helm: https://helm.sh/docs/intro/install/" || exit 1

    log_info "Environment:  ${BOLD}${env_name}${NC}"
    log_info "Mode:         ${BOLD}$([[ "$FULL_MODE" == "true" ]] && echo "FULL" || echo "DEFAULT")${NC}"
    [[ "$DRY_RUN" == "true" ]] && log_info "Dry-run:      ${BOLD}yes${NC}"
    log_info "Config file:  ${CONFIG_FILE}"

    # Namespace check: if namespace is missing, nothing to do
    if ! kubectl get namespace "$env_name" &>/dev/null; then
        log_warn "Namespace '${env_name}' does not exist — nothing to uninstall."
        exit 0
    fi

    # Show what's about to be deleted
    show_preview

    # Confirm
    confirm_or_exit

    # Default teardown (always runs)
    step_uninstall_helm_releases
    step_clean_hook_resources
    step_delete_secrets
    step_delete_pvcs

    # Full teardown (optional)
    if [[ "$FULL_MODE" == "true" ]]; then
        step_delete_istio_gateway
        step_delete_rancher_project
        step_delete_namespace
    fi

    show_summary
}

main "$@"
