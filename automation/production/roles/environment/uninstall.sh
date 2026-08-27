#!/usr/bin/env bash
# =============================================================================
# OpenG2P Environment — Uninstall (runs ON THE LAPTOP)
# =============================================================================
# Tears down ONE OpenG2P environment. Invoked by openg2p-prod-env-uninstall.sh
# or directly: roles/environment/uninstall.sh --config prod-config.yaml
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE=""
PROVISION_OUTPUT=""
FULL_MODE=false
KEEP_DATABASES=false
SKIP_CONFIRM=false
DRY_RUN=false

source "${WORK_DIR}/lib/shared/utils.sh"
STATE_DIR="${WORK_DIR}/.state"
source "${WORK_DIR}/lib/ssh-utils.sh"

# Captured before K8s teardown — used by hook cleanup.
RELEASES_BEFORE=""

# Commons databases + their owning per-service roles, as created by the
# commons-base/commons-services postgres-init. KEEP IN SYNC with those charts'
# `databases:` blocks (commons-base values.yaml) and the master-data / iam /
# audit-manager DB names (commons-services values.yaml).
DB_ROLES=(
    "superset:superset"
    "odkdb:odkuser"
    "mosip_keymgr:keymgruser"
    "mosip_mockidentitysystem:mockidsystemuser"
    "mosip_esignet:esignetuser"
    "keycloak:keycloakuser"
    "master_data:master_data_user"
    "iam:iam_user"
    "audit_manager:audit_manager_user"
)

# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)            CONFIG_FILE="$2";       shift 2 ;;
            --provision-output)  PROVISION_OUTPUT="$2";  shift 2 ;;
            --full)              FULL_MODE=true;         shift ;;
            --keep-databases)    KEEP_DATABASES=true;    shift ;;
            --yes|-y)            SKIP_CONFIRM=true;      shift ;;
            --dry-run)           DRY_RUN=true;           shift ;;
            --help|-h)           show_help; exit 0 ;;
            *) log_error "Unknown option: $1" "Run with --help for usage"; exit 1 ;;
        esac
    done
    [[ -z "$CONFIG_FILE" ]] && { log_error "--config <prod-config.yaml> is required"; exit 1; }
    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${WORK_DIR}/${CONFIG_FILE}"
}

show_help() {
    cat <<'EOF'
OpenG2P 3-Node Production — Environment Uninstall (laptop-side)
==============================================================

Usage:
  ./openg2p-prod-env-uninstall.sh --config <prod-config.yaml> [options]

Options:
  --config <file>     Path to prod-config.yaml (required)
  --full              Also delete the Istio Gateway, Rancher Project, and the
                      namespace (default keeps them for fast re-install)
  --keep-databases    Skip the host-PostgreSQL drop (K8s teardown only)
  --dry-run           Show what would be removed; change nothing
  --yes, -y           Skip the typed-name confirmation prompt
  --help, -h          Show this help

Removes the environment's Helm releases + Secrets + PVCs/PVs, and DROPs the
commons databases + their per-service roles on the storage node's host
PostgreSQL. PRESERVES the 3 VMs, the platform, the NFS/PostgreSQL servers, and
the PostgreSQL SUPERUSER credentials. Re-run openg2p-prod.sh afterward to
refill the environment scaffolding, then reinstall Commons via Rancher UI.
EOF
}

# ---------------------------------------------------------------------------
# Resolve env name + ensure a working kubeconfig (cached by the env install;
# fetched from the compute node if absent).
# ---------------------------------------------------------------------------
resolve_and_prepare() {
    load_config "$CONFIG_FILE"
    if [[ -z "$PROVISION_OUTPUT" ]]; then
        local auto="$(dirname "$CONFIG_FILE")/provision-output.yaml"
        [[ -f "$auto" ]] && PROVISION_OUTPUT="$auto"
    fi
    [[ -n "$PROVISION_OUTPUT" && -f "$PROVISION_OUTPUT" ]] && load_config "$PROVISION_OUTPUT"

    ENV_NAME=$(cfg "environment.name" "prod")
    COMPUTE_PRIV=$(cfg "compute_private_ip")
    KUBECONFIG_CACHE="${STATE_DIR}/environment/kubeconfig"

    if [[ ! -d "${SSH_CTRL_DIR:-}" ]]; then
        ssh_init
    fi
    trap 'ssh_k8s_tunnel_close 2>/dev/null || true' EXIT

    # Reach the API over SSH (same as install) — Wireguard not required.
    if ! ssh_k8s_tunnel_open "$KUBECONFIG_CACHE"; then
        log_error "Cannot reach the cluster API via SSH tunnel" \
                  "kubectl needs SSH access to compute (public IP / jump host)" \
                  "Verify compute SSH and that RKE2 is running, then re-run"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# K8s teardown helpers (production-specific — does not use automation/environment/)
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

run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${BLUE}[DRY-RUN]${NC} $*"
    else
        eval "$@"
    fi
}

show_k8s_preview() {
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
    echo -e "${YELLOW}║${NC}  Namespace: ${BOLD}${ENV_NAME}${NC}"
    echo -e "${YELLOW}║${NC}"

    local helm_releases helm_count
    helm_releases=$(helm list -n "$ENV_NAME" -q 2>/dev/null || true)
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

    local jobs_count secrets_count pvc_list pvc_count
    jobs_count=$(kubectl get jobs -n "$ENV_NAME" --no-headers 2>/dev/null | count_or_zero)
    secrets_count=$(kubectl get secrets -n "$ENV_NAME" --no-headers 2>/dev/null | count_or_zero)
    pvc_list=$(kubectl get pvc -n "$ENV_NAME" -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.volumeName}{"\n"}{end}' 2>/dev/null || true)
    pvc_count=$(echo -n "$pvc_list" | count_or_zero)

    echo -e "${YELLOW}║${NC}  ${BOLD}Jobs${NC} (hook leftovers): ${jobs_count}"
    echo -e "${YELLOW}║${NC}  ${BOLD}Secrets${NC}: ${secrets_count}"
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
        gw_list=$(kubectl get gateway -n "$ENV_NAME" -o name 2>/dev/null || true)
        if [[ -n "$gw_list" ]]; then
            while IFS= read -r gw; do
                echo -e "${YELLOW}║${NC}    - ${gw}"
            done <<< "$gw_list"
        else
            echo -e "${YELLOW}║${NC}    (none)"
        fi
        echo -e "${YELLOW}║${NC}"
        echo -e "${YELLOW}║${NC}  ${BOLD}Namespace itself${NC}: ${ENV_NAME}"
    fi

    echo -e "${YELLOW}║${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║${NC}  ${BOLD}PRESERVED${NC}:"
    if [[ "$FULL_MODE" == "true" ]]; then
        echo -e "${YELLOW}║${NC}    - Nginx config, certificates, DNS records"
        echo -e "${YELLOW}║${NC}    - Cluster/Rancher/Istio installations"
    else
        echo -e "${YELLOW}║${NC}    - Namespace '${ENV_NAME}', Istio Gateway, Rancher Project"
        echo -e "${YELLOW}║${NC}    - Nginx config, certificates, DNS records"
    fi
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

confirm_or_exit() {
    [[ "$DRY_RUN" == "true" ]]  && { log_info "DRY RUN — nothing will be changed."; return 0; }
    [[ "$SKIP_CONFIRM" == "true" ]] && { log_warn "Skipping confirmation (--yes)."; return 0; }

    echo ""
    log_warn "This will REMOVE environment '${ENV_NAME}':"
    log_warn "  • all Helm releases + Secrets + PVCs/PVs in namespace '${ENV_NAME}' (DATA IS ERASED)"
    [[ "$KEEP_DATABASES" != "true" ]] && \
    log_warn "  • the commons databases + per-service roles on the storage host PostgreSQL"
    [[ "$FULL_MODE" == "true" ]] && \
    log_warn "  • the Istio Gateway, Rancher Project, and the namespace itself"
    log_warn "Preserves: the 3 VMs, the platform, NFS + PostgreSQL servers, and the PG superuser."
    echo ""
    echo -n "Type the environment name '${ENV_NAME}' to confirm: "
    read -r reply
    if [[ "$reply" != "$ENV_NAME" ]]; then
        log_error "Confirmation failed (expected '${ENV_NAME}') — aborting, nothing changed."
        exit 1
    fi
}

step_uninstall_helm_releases() {
    log_step "1a" "Uninstalling all Helm releases in '${ENV_NAME}'"

    if [[ -z "$RELEASES_BEFORE" ]]; then
        log_info "No Helm releases found in '${ENV_NAME}' — skipping."
        return 0
    fi

    local other_releases="" has_commons=false
    while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        if [[ "$r" == "commons" ]]; then
            has_commons=true
        else
            other_releases+="${r}"$'\n'
        fi
    done <<< "$RELEASES_BEFORE"

    if [[ -n "$other_releases" ]]; then
        while IFS= read -r release; do
            [[ -z "$release" ]] && continue
            log_info "Uninstalling Helm release '${release}'..."
            run_cmd "helm uninstall '${release}' -n '${ENV_NAME}' --wait --timeout 5m || true"
            log_success "Helm release '${release}' uninstalled."
        done <<< "$other_releases"
    fi

    if [[ "$has_commons" == "true" ]]; then
        log_info "Uninstalling Helm release 'commons' (infrastructure — last)..."
        run_cmd "helm uninstall 'commons' -n '${ENV_NAME}' --wait --timeout 5m || true"
        log_success "Helm release 'commons' uninstalled."
    fi
}

step_clean_hook_resources() {
    log_step "1b" "Cleaning orphaned hook resources in '${ENV_NAME}'"

    run_cmd "kubectl delete jobs -n '${ENV_NAME}' --all --ignore-not-found"

    if [[ -n "$RELEASES_BEFORE" ]]; then
        while IFS= read -r release; do
            [[ -z "$release" ]] && continue
            for suffix in postgres-init keycloak-init client-secrets-sync iam-pg-init audit-pg-init master-data-postgres-init; do
                run_cmd "kubectl delete serviceaccount '${release}-${suffix}' -n '${ENV_NAME}' --ignore-not-found > /dev/null 2>&1 || true"
                run_cmd "kubectl delete configmap '${release}-${suffix}' -n '${ENV_NAME}' --ignore-not-found > /dev/null 2>&1 || true"
                run_cmd "kubectl delete rolebinding '${release}-${suffix}' -n '${ENV_NAME}' --ignore-not-found > /dev/null 2>&1 || true"
                run_cmd "kubectl delete role '${release}-${suffix}' -n '${ENV_NAME}' --ignore-not-found > /dev/null 2>&1 || true"
            done
        done <<< "$RELEASES_BEFORE"
    fi

    log_success "Hook resources cleaned."
}

step_delete_secrets() {
    log_step "1c" "Deleting all Secrets in '${ENV_NAME}'"
    run_cmd "kubectl delete secrets -n '${ENV_NAME}' --all --ignore-not-found"
    log_success "Secrets deleted."
}

step_delete_pvcs() {
    log_step "1d" "Deleting PVCs and associated PVs in '${ENV_NAME}'"

    local pv_names
    pv_names=$(kubectl get pvc -n "$ENV_NAME" -o jsonpath='{.items[*].spec.volumeName}' 2>/dev/null || true)

    run_cmd "kubectl delete pvc -n '${ENV_NAME}' --all --ignore-not-found"

    if [[ -n "$pv_names" ]]; then
        if [[ "$DRY_RUN" != "true" ]]; then
            sleep 5
        fi
        for pv in $pv_names; do
            run_cmd "kubectl delete pv '${pv}' --ignore-not-found"
        done
    fi

    log_success "PVCs and PVs deleted."
}

step_delete_istio_gateway() {
    log_step "1e" "Deleting Istio Gateway(s) in '${ENV_NAME}'"
    run_cmd "kubectl delete gateway --all -n '${ENV_NAME}' --ignore-not-found"
    log_success "Istio Gateways deleted."
}

step_delete_rancher_project() {
    log_step "1f" "Removing Rancher Project for '${ENV_NAME}'"

    local project_full
    project_full=$(kubectl get namespace "$ENV_NAME" \
        -o jsonpath='{.metadata.annotations.field\.cattle\.io/projectId}' 2>/dev/null || true)

    if [[ -z "$project_full" ]]; then
        log_info "Namespace has no Rancher Project annotation — skipping."
        return 0
    fi

    local project_id="${project_full#*:}"
    log_info "Found Rancher Project association: ${project_full}"

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

step_delete_namespace() {
    log_step "1g" "Deleting namespace '${ENV_NAME}'"

    if kubectl get namespace "$ENV_NAME" &>/dev/null; then
        run_cmd "kubectl delete namespace '${ENV_NAME}' --ignore-not-found"
        log_success "Namespace '${ENV_NAME}' deleted."
    else
        log_info "Namespace '${ENV_NAME}' does not exist — skipping."
    fi
}

teardown_kubernetes() {
    log_step "1" "Tearing down Kubernetes resources in namespace '${ENV_NAME}'"

    if ! kubectl get namespace "$ENV_NAME" &>/dev/null; then
        log_warn "Namespace '${ENV_NAME}' does not exist — nothing to tear down in Kubernetes."
        return 0
    fi

    RELEASES_BEFORE=$(helm list -n "$ENV_NAME" -q 2>/dev/null || true)
    show_k8s_preview

    step_uninstall_helm_releases
    step_clean_hook_resources
    step_delete_secrets
    step_delete_pvcs

    if [[ "$FULL_MODE" == "true" ]]; then
        step_delete_istio_gateway
        step_delete_rancher_project
        step_delete_namespace
    fi
}

# ---------------------------------------------------------------------------
# Step 2 — Drop the commons databases + per-service roles on the host PostgreSQL.
# ---------------------------------------------------------------------------
drop_host_databases() {
    if [[ "$KEEP_DATABASES" == "true" ]]; then
        log_info "--keep-databases set — leaving host PostgreSQL untouched."
        return 0
    fi

    log_step "2" "Dropping commons databases + roles on the storage host PostgreSQL"

    local sql="" pair db role
    for pair in "${DB_ROLES[@]}"; do
        db="${pair%%:*}"
        sql+="DROP DATABASE IF EXISTS \"${db}\" WITH (FORCE);"$'\n'
    done
    for pair in "${DB_ROLES[@]}"; do
        role="${pair##*:}"
        sql+="DROP ROLE IF EXISTS \"${role}\";"$'\n'
    done

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would run on storage (sudo -u postgres psql):"
        printf '%s' "$sql" | sed 's/^/    /'
        return 0
    fi

    if printf '%s' "$sql" \
        | ssh_run storage "sudo -u postgres psql -v ON_ERROR_STOP=0 -d postgres -f -" 2>&1 \
        | sed 's/^/    [storage] /'
    then
        log_success "Commons databases + roles dropped (PostgreSQL server + superuser preserved)."
    else
        log_warn "Some DROP statements reported errors (see above)."
        log_warn "Dependent objects may need manual cleanup; the server itself is unaffected."
    fi
}

# ---------------------------------------------------------------------------
# Step 3 — Clear laptop-side orchestrator markers for the env stage.
# ---------------------------------------------------------------------------
clear_env_state_markers() {
    log_step "3" "Clearing laptop-side environment state markers"

    local markers=(
        "${STATE_DIR}/orchestrator/environment-phase1.done"
        "${STATE_DIR}/orchestrator/environment-phase2.done"
    )
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would remove:"
        printf '    %s\n' "${markers[@]}"
        return 0
    fi
    rm -f "${markers[@]}"
    log_success "Env phase markers cleared — a re-run of openg2p-prod.sh will rebuild the environment."
}

show_summary() {
    local suffix=""
    [[ "$DRY_RUN" == "true" ]] && suffix=" (dry-run — nothing was changed)"
    echo ""
    log_success "Environment '${ENV_NAME}' uninstall complete${suffix}."
    echo ""
    log_info "Preserved: the 3 VMs, the platform (RKE2/Istio/Rancher/Keycloak/WG/Nginx),"
    log_info "           the NFS + PostgreSQL servers, and the PostgreSQL superuser."
    [[ "$FULL_MODE" != "true" ]] && \
    log_info "           the namespace, Istio Gateway, and Rancher Project (re-used on re-install)."
    echo ""
    log_info "Re-create the environment scaffolding with:"
    log_info "    ./openg2p-prod.sh --stage environment --config ${CONFIG_FILE##*/}"
    log_info "Then install Commons via the Rancher UI."
}

main() {
    parse_args "$@"
    log_banner "OpenG2P Environment Uninstall" "Production · namespace + host PostgreSQL"
    resolve_and_prepare

    log_info "Environment:  ${BOLD}${ENV_NAME}${NC}"
    log_info "Mode:         ${BOLD}$([[ "$FULL_MODE" == "true" ]] && echo FULL || echo default)${NC}"
    [[ "$KEEP_DATABASES" == "true" ]] && log_info "Databases:    ${BOLD}preserved (--keep-databases)${NC}"
    [[ "$DRY_RUN" == "true" ]] && log_info "Dry-run:      ${BOLD}yes${NC}"

    confirm_or_exit
    teardown_kubernetes
    drop_host_databases
    clear_env_state_markers
    show_summary
    ssh_k8s_tunnel_close 2>/dev/null || true
}

main "$@"
