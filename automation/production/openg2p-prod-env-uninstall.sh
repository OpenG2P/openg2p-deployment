#!/usr/bin/env bash
# =============================================================================
# OpenG2P 3-Node Production — ENVIRONMENT uninstall  (runs ON YOUR LAPTOP)
# =============================================================================
# Tears down ONE OpenG2P environment (the commons workloads + their data),
# leaving the underlying infrastructure intact so a re-run of the install
# (`openg2p-prod.sh`) cleanly refills everything.
#
# This is SEPARATE from openg2p-prod-uninstall.sh (which wipes the 3 nodes).
# Run this when you only want to reset the environment, not the platform.
#
# WHAT IT REMOVES
#   • All Helm releases in the environment namespace (commons-base,
#     commons-services, and any product modules installed there).
#   • Orphaned hook resources, ALL Secrets, and ALL PVCs + their backing PVs
#     in the namespace  →  this erases the environment's data on the NFS-backed
#     storage (the storage NODE and NFS server stay; only the data goes).
#   • The commons DATABASES on the storage node's host PostgreSQL, plus their
#     per-service application ROLES (esignetuser, keycloakuser, …).
#   • With --full: also the Istio Gateway, Rancher Project, and the namespace.
#
# WHAT IT PRESERVES
#   • The 3 VMs and everything installed by openg2p-prod.sh (RKE2, Istio,
#     Rancher, Keycloak admin, Wireguard, Nginx, NFS server).
#   • The host PostgreSQL SERVER and its SUPERUSER credentials
#     (/etc/openg2p/secrets/postgres-superuser.env on the storage node) —
#     those belong to the storage phase, not to the environment.
#
# AFTER THIS, re-run the install to recreate the environment fresh:
#     ./openg2p-prod.sh --role environment --config <prod-config.yaml>
#   (per-service DB users + passwords + K8s secrets are regenerated).
#
# Usage:
#   ./openg2p-prod-env-uninstall.sh --config prod-config.yaml
#   ./openg2p-prod-env-uninstall.sh --config prod-config.yaml --dry-run
#   ./openg2p-prod-env-uninstall.sh --config prod-config.yaml --full
#   ./openg2p-prod-env-uninstall.sh --config prod-config.yaml --keep-databases
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
PROVISION_OUTPUT=""
FULL_MODE=false
KEEP_DATABASES=false
SKIP_CONFIRM=false
DRY_RUN=false

source "${SCRIPT_DIR}/lib/shared/utils.sh"
STATE_DIR="${SCRIPT_DIR}/.state"
source "${SCRIPT_DIR}/lib/ssh-utils.sh"

ENV_CLUSTER_UNINSTALL_SH="${SCRIPT_DIR}/../environment/env-cluster-uninstall.sh"

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
    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
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
refill the environment.
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

    if [[ ! -f "$KUBECONFIG_CACHE" ]]; then
        log_info "No cached kubeconfig — fetching from compute (${COMPUTE_PRIV})..."
        mkdir -p "$(dirname "$KUBECONFIG_CACHE")"
        local raw
        if raw=$(ssh_run compute "sudo cat /etc/rancher/rke2/rke2-remote.yaml" 2>/dev/null) && [[ -n "$raw" ]]; then
            printf '%s\n' "$raw" > "$KUBECONFIG_CACHE"
        else
            raw=$(ssh_run compute "sudo cat /etc/rancher/rke2/rke2.yaml" 2>&1) || {
                log_error "Cannot fetch kubeconfig from compute" \
                          "Neither rke2-remote.yaml nor rke2.yaml is readable over SSH" \
                          "Check SSH/sudo to compute and that the cluster is up"
                exit 1
            }
            printf '%s\n' "$raw" \
                | sed -E "s#server: https://127\\.0\\.0\\.1:6443#server: https://${COMPUTE_PRIV}:6443#g" \
                > "$KUBECONFIG_CACHE"
        fi
        chmod 0600 "$KUBECONFIG_CACHE"
    fi
    export KUBECONFIG="$KUBECONFIG_CACHE"

    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot reach the cluster API (is Wireguard connected?)" \
                  "kubectl cluster-info failed using ${KUBECONFIG_CACHE}" \
                  "Connect the Wireguard VPN, then re-run"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Step 1 — Kubernetes teardown (reuse the environment automation's uninstaller).
# ---------------------------------------------------------------------------
teardown_kubernetes() {
    log_step "1" "Tearing down Kubernetes resources in namespace '${ENV_NAME}'"

    if [[ ! -x "$ENV_CLUSTER_UNINSTALL_SH" ]]; then
        log_error "env-cluster-uninstall.sh not found/executable: ${ENV_CLUSTER_UNINSTALL_SH}"
        exit 1
    fi

    local -a args=(--namespace "$ENV_NAME")
    [[ "$FULL_MODE" == "true" ]] && args+=(--full)
    [[ "$DRY_RUN" == "true" ]]   && args+=(--dry-run)
    # We already confirmed above; don't prompt twice.
    [[ "$DRY_RUN" != "true" ]]   && args+=(--yes)

    KUBECONFIG="$KUBECONFIG_CACHE" "$ENV_CLUSTER_UNINSTALL_SH" "${args[@]}"
}

# ---------------------------------------------------------------------------
# Step 2 — Drop the commons databases + per-service roles on the host PostgreSQL.
# Connects locally on the storage node as the postgres superuser (peer auth via
# the unix socket — no password needed). Preserves the superuser + server.
# ---------------------------------------------------------------------------
drop_host_databases() {
    if [[ "$KEEP_DATABASES" == "true" ]]; then
        log_info "--keep-databases set — leaving host PostgreSQL untouched."
        return 0
    fi

    log_step "2" "Dropping commons databases + roles on the storage host PostgreSQL"

    # Build the SQL: databases first (FORCE terminates live connections), then
    # the now-ownerless roles. ON_ERROR_STOP=0 so one failure doesn't abort.
    local sql=""
    local pair db role
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
# Step 3 — Clear the laptop-side orchestrator markers for the env stage, so a
# plain re-run of openg2p-prod.sh re-executes phase 1 (recreates the namespace,
# Rancher Project, Istio Gateway, and the commons-postgresql secret) and phase 2
# (reinstalls commons). Without this, the install skips phase 1 as "done" and
# phase 2 fails its external-PG secret pre-flight.
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
    log_success "Env phase markers cleared — a plain re-run of openg2p-prod.sh will rebuild the environment."
}

# ---------------------------------------------------------------------------
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
    log_info "Re-create the environment fresh with:"
    log_info "    ./openg2p-prod.sh --role environment --config ${CONFIG_FILE##*/}"
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    log_banner "OpenG2P Environment Uninstall" "Laptop-side · namespace + host PostgreSQL"
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
}

main "$@"
