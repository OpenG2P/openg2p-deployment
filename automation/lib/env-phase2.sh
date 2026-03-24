#!/usr/bin/env bash
# =============================================================================
# OpenG2P Environment Setup — Phase 2: Module Installation
# =============================================================================
# Installs OpenG2P modules into the environment namespace via Helm.
#
# openg2p-commons is split into two charts that must be installed in order:
#   1. openg2p-commons-base     — Infrastructure: PostgreSQL, Kafka, MinIO,
#                                  OpenSearch, Redis, SoftHSM, keycloak-init
#   2. openg2p-commons-services — Applications: eSignet, KeyManager, Superset,
#                                  ODK, master-data, reporting, mock-identity
#
# Future modules (Registry, PBMS, SPAR, G2P Bridge) will be added as
# separate steps.
#
# Sourced by openg2p-environment.sh — do not run directly.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Helpers: resolve chart references
# ─────────────────────────────────────────────────────────────────────────────
# Resolves a chart reference: local path if available, else repo_name/chart_name.
# Usage: get_chart_ref <config_key_for_path> <remote_chart_name>
get_chart_ref() {
    local path_key="$1"
    local remote_name="$2"
    local chart_path=$(cfg "$path_key" "")
    if [[ -n "$chart_path" ]]; then
        [[ "$chart_path" = /* ]] || chart_path="${SCRIPT_DIR}/${chart_path}"
        if [[ -d "$chart_path" ]]; then
            echo "$chart_path"
            return
        fi
        log_warn "Chart path '${chart_path}' not found. Falling back to remote chart."
    fi
    echo "openg2p/${remote_name}"
}

ensure_helm_repo() {
    local base_path=$(cfg "commons_base.chart_path" "")
    local svc_path=$(cfg "commons_services.chart_path" "")
    # If both charts are local, no repo needed
    if [[ -n "$base_path" && -n "$svc_path" ]]; then
        return 0
    fi

    local repo_url=$(cfg "commons_base.chart_repo" "https://openg2p.github.io/openg2p-helm")
    log_info "Ensuring Helm repo 'openg2p' is configured..."

    if helm repo list 2>/dev/null | grep -q "^openg2p"; then
        helm repo update openg2p > /dev/null 2>&1 || true
        log_info "Helm repo 'openg2p' updated."
    else
        helm repo add openg2p "$repo_url" > /dev/null 2>&1 || {
            log_error "Failed to add Helm repo" \
                      "Could not add repo at ${repo_url}" \
                      "Check internet connectivity" \
                      "helm repo add openg2p ${repo_url}"
            return 1
        }
        helm repo update openg2p > /dev/null 2>&1 || true
        log_success "Helm repo 'openg2p' added."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: clean uninstall a Helm release
# Mirrors the cleanup from the chart's own uninstall scripts to ensure
# stale hooks, Jobs, secrets, and PVCs don't block a fresh install.
# ─────────────────────────────────────────────────────────────────────────────
clean_uninstall_release() {
    local env_name="$1"
    local release_name="$2"
    local cleanup_level="${3:-light}"  # "light" or "full"

    if ! helm status "$release_name" -n "$env_name" &>/dev/null; then
        return 0
    fi

    log_warn "Stale Helm release '${release_name}' found in '${env_name}'. Uninstalling first..."
    helm uninstall "$release_name" -n "$env_name" --wait --timeout 5m || {
        log_warn "helm uninstall returned non-zero. Continuing..."
    }

    # Clean up orphaned Jobs, ServiceAccounts, ConfigMaps, RBAC left by hooks
    log_info "Cleaning up orphaned hook resources for '${release_name}'..."
    kubectl delete jobs -n "$env_name" --all --ignore-not-found > /dev/null 2>&1 || true
    # Clean known hook ServiceAccounts and ConfigMaps
    for suffix in postgres-init keycloak-init client-secrets-sync; do
        kubectl delete serviceaccount "${release_name}-${suffix}" -n "$env_name" --ignore-not-found > /dev/null 2>&1 || true
        kubectl delete configmap "${release_name}-${suffix}" -n "$env_name" --ignore-not-found > /dev/null 2>&1 || true
    done
    # Clean hook RBAC
    kubectl delete rolebinding "${release_name}-client-secrets-sync" -n "$env_name" --ignore-not-found > /dev/null 2>&1 || true
    kubectl delete role "${release_name}-client-secrets-sync" -n "$env_name" --ignore-not-found > /dev/null 2>&1 || true

    if [[ "$cleanup_level" == "full" ]]; then
        # Full cleanup: delete ALL secrets and PVCs (for base chart reinstall)
        log_info "Cleaning up ALL secrets and PVCs in '${env_name}'..."
        # Capture PV names before deleting PVCs
        local pv_names
        pv_names=$(kubectl get pvc -n "$env_name" -o jsonpath='{.items[*].spec.volumeName}' 2>/dev/null || true)
        kubectl delete secrets -n "$env_name" --all --ignore-not-found > /dev/null 2>&1 || true
        kubectl delete pvc -n "$env_name" --all --ignore-not-found > /dev/null 2>&1 || true
        # Delete released PVs
        if [[ -n "$pv_names" ]]; then
            sleep 5
            for pv in $pv_names; do
                kubectl delete pv "$pv" --ignore-not-found > /dev/null 2>&1 || true
            done
        fi
    fi

    sleep 3
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: install a Helm chart with standard error handling
# ─────────────────────────────────────────────────────────────────────────────
helm_install_chart() {
    local env_name="$1"
    local release_name="$2"
    local chart_ref="$3"
    local chart_version="$4"
    local display_name="$5"
    shift 5
    # Remaining args are --set flags

    local -a helm_args=(
        install "$release_name" "$chart_ref"
        -n "$env_name"
        --wait
        --timeout 20m
    )

    # Add chart version if specified (only for remote charts)
    if [[ -n "$chart_version" && "$chart_ref" == openg2p/* ]]; then
        helm_args+=(--version "$chart_version")
    fi

    # Add caller's --set flags
    helm_args+=("$@")

    log_info "Running: helm install ${release_name} ..."
    log_info "(this may take 15-20 minutes — Helm waits for all hooks to complete)"
    echo ""

    if ! helm "${helm_args[@]}"; then
        log_error "Helm install failed for ${display_name}" \
                  "The chart installation did not complete successfully" \
                  "Check pod status and logs" \
                  "kubectl get pods -n ${env_name} --field-selector=status.phase!=Running"
        echo ""
        log_info "Diagnostic info:"
        log_info "─────────────────────────────────────────────────────"
        kubectl get pods -n "$env_name" --field-selector=status.phase!=Running 2>/dev/null || true
        echo ""
        kubectl get jobs -n "$env_name" 2>/dev/null || true
        echo ""
        return 1
    fi

    log_success "${display_name} installed successfully."
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2.1: Install openg2p-commons-base
# ─────────────────────────────────────────────────────────────────────────────
env_phase2_step1_commons_base() {
    local env_name=$(cfg "environment")
    local step_id="env-${env_name}.phase2.commons_base"

    if is_step_done "$step_id" && [[ "$FORCE_MODE" != "true" ]]; then
        log_info "Skipping openg2p-commons-base — already installed. Use --force to reinstall."
        return 0
    fi

    if ! cfg_bool "modules.commons"; then
        log_info "openg2p-commons disabled in config — skipping."
        return 0
    fi

    log_step "E2.1" "Installing openg2p-commons-base in '${env_name}'"

    ensure_kubeconfig || return 1

    local base_domain=$(get_env_base_domain)
    local keycloak_url=$(get_keycloak_url)
    local cm_user=$(cfg "keycloak.client_manager_user" "")
    local cm_pass=$(cfg "keycloak.client_manager_password" "")
    local chart_name=$(cfg "commons_base.chart_name" "openg2p-commons-base")
    local chart_ref=$(get_chart_ref "commons_base.chart_path" "$chart_name")
    local chart_version=$(cfg "commons_base.chart_version" "2.0.0-develop")
    local release_name="commons"

    ensure_helm_repo || return 1

    # Clean uninstall if stale release exists (full cleanup: secrets + PVCs)
    clean_uninstall_release "$env_name" "$release_name" "full"

    # Always ensure keycloak-client-manager secret exists before install.
    # It may have been deleted by full cleanup above, by a manual uninstall,
    # or may never have been created if phase 1 was skipped.
    if [[ -n "$cm_pass" ]]; then
        if kubectl -n "$env_name" get secret keycloak-client-manager &>/dev/null; then
            log_info "Secret 'keycloak-client-manager' already exists."
        else
            log_info "Creating secret 'keycloak-client-manager' in namespace '${env_name}'..."
            kubectl -n "$env_name" create secret generic keycloak-client-manager \
                --from-literal=keycloak-client-manager-password="$cm_pass" || {
                log_error "Failed to create keycloak-client-manager secret" \
                          "This secret is required by the commons chart" \
                          "Check namespace and credentials"
                return 1
            }
            log_success "Secret 'keycloak-client-manager' created."
        fi
    else
        log_error "Keycloak client-manager password not available" \
                  "Cannot create the required keycloak-client-manager secret" \
                  "Set keycloak.client_manager_password in env config or check saved state"
        return 1
    fi

    log_info "Chart:    ${chart_ref}"
    log_info "Version:  ${chart_version}"
    log_info "Release:  ${release_name}"
    log_info "Domain:   ${base_domain}"
    log_info "Keycloak: ${keycloak_url}"
    log_info "User:     ${cm_user}"
    log_info ""

    # Extra helm args from config
    local extra_args=$(cfg "commons_base.extra_helm_args" "")
    local -a extra=()
    if [[ -n "$extra_args" ]]; then
        # shellcheck disable=SC2206
        extra=($extra_args)
    fi

    helm_install_chart "$env_name" "$release_name" "$chart_ref" "$chart_version" \
        "openg2p-commons-base" \
        --set "global.baseDomain=${base_domain}" \
        --set "global.keycloakBaseUrl=${keycloak_url}" \
        --set "keycloak-init.keycloak.url=${keycloak_url}" \
        --set "keycloak-init.keycloak.user=${cm_user}" \
        "${extra[@]}" \
        || return 1

    # Wait until ALL StatefulSets and Deployments are fully ready.
    # This is critical — services chart must not start until PostgreSQL,
    # Kafka, Redis, etc. are all accepting connections.
    log_info "Waiting for all base infrastructure to be fully ready..."
    local wait_timeout=900  # 15 minutes
    local wait_interval=15
    local wait_elapsed=0

    while [[ $wait_elapsed -lt $wait_timeout ]]; do
        local not_ready
        not_ready=$(kubectl get deployments,statefulsets -n "$env_name" -o json 2>/dev/null | \
            jq -r '.items[] | select((.status.readyReplicas // 0) != (.status.replicas // 1)) | "\(.kind)/\(.metadata.name)"' 2>/dev/null || true)

        if [[ -z "$not_ready" ]]; then
            log_success "All base infrastructure resources in '${env_name}' are ready."
            break
        fi

        echo -ne "\r  Waiting for: $(echo "$not_ready" | tr '\n' ', ')... ${wait_elapsed}s/${wait_timeout}s"
        sleep "$wait_interval"
        wait_elapsed=$((wait_elapsed + wait_interval))
    done

    if [[ $wait_elapsed -ge $wait_timeout ]]; then
        echo ""
        log_error "Base infrastructure not ready after ${wait_timeout}s" \
                  "Some resources did not become ready in time" \
                  "Check pod status" \
                  "kubectl get pods -n ${env_name} --field-selector=status.phase!=Running"
        return 1
    fi

    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2.2: Install openg2p-commons-services
# ─────────────────────────────────────────────────────────────────────────────
env_phase2_step2_commons_services() {
    local env_name=$(cfg "environment")
    local step_id="env-${env_name}.phase2.commons_services"

    if is_step_done "$step_id" && [[ "$FORCE_MODE" != "true" ]]; then
        log_info "Skipping openg2p-commons-services — already installed. Use --force to reinstall."
        return 0
    fi

    if ! cfg_bool "modules.commons"; then
        log_info "openg2p-commons disabled in config — skipping."
        return 0
    fi

    log_step "E2.2" "Installing openg2p-commons-services in '${env_name}'"

    ensure_kubeconfig || return 1

    local base_domain=$(get_env_base_domain)
    local keycloak_url=$(get_keycloak_url)
    local chart_name=$(cfg "commons_services.chart_name" "openg2p-commons-services")
    local chart_ref=$(get_chart_ref "commons_services.chart_path" "$chart_name")
    local chart_version=$(cfg "commons_services.chart_version" "2.0.0-develop")
    local release_name="commons-services"
    local base_release="commons"

    ensure_helm_repo || return 1

    # Verify base chart is installed
    if ! helm status "$base_release" -n "$env_name" &>/dev/null; then
        log_error "openg2p-commons-base not installed" \
                  "The base chart must be installed first (step E2.1)" \
                  "Run the full environment setup or --phase 2" \
                  "helm status ${base_release} -n ${env_name}"
        return 1
    fi

    # Clean uninstall if stale release exists (light cleanup: Jobs only, no PVCs)
    clean_uninstall_release "$env_name" "$release_name" "light"

    log_info "Chart:        ${chart_ref}"
    log_info "Version:      ${chart_version}"
    log_info "Release:      ${release_name}"
    log_info "Base release: ${base_release}"
    log_info "Domain:       ${base_domain}"
    log_info "Keycloak:     ${keycloak_url}"
    log_info ""

    # Extra helm args from config
    local extra_args=$(cfg "commons_services.extra_helm_args" "")
    local -a extra=()
    if [[ -n "$extra_args" ]]; then
        # shellcheck disable=SC2206
        extra=($extra_args)
    fi

    # Services chart needs references to base chart's infrastructure services
    helm_install_chart "$env_name" "$release_name" "$chart_ref" "$chart_version" \
        "openg2p-commons-services" \
        --set "global.baseDomain=${base_domain}" \
        --set "global.keycloakBaseUrl=${keycloak_url}" \
        --set "global.postgresqlHost=${base_release}-postgresql" \
        --set "global.redisInstallationName=${base_release}-redis" \
        --set "global.redisAuthInstallationName=${base_release}-redis-auth" \
        --set "global.minioInstallationName=${base_release}-minio" \
        --set "global.mailInstallationName=${base_release}-mail" \
        --set "global.kafkaInstallationName=${base_release}-kafka" \
        --set "global.softhsmInstallationName=${base_release}-softhsm" \
        "${extra[@]}" \
        || return 1

    # Wait until ALL deployments are fully ready before marking complete.
    log_info "Waiting for all service deployments to be fully ready..."
    local wait_timeout=900  # 15 minutes
    local wait_interval=15
    local wait_elapsed=0

    while [[ $wait_elapsed -lt $wait_timeout ]]; do
        local not_ready
        not_ready=$(kubectl get deployments -n "$env_name" -o json 2>/dev/null | \
            jq -r '.items[] | select((.status.availableReplicas // 0) != (.status.replicas // 1)) | .metadata.name' 2>/dev/null || true)

        if [[ -z "$not_ready" ]]; then
            log_success "All deployments in '${env_name}' are ready."
            break
        fi

        echo -ne "\r  Waiting for: $(echo "$not_ready" | tr '\n' ', ')... ${wait_elapsed}s/${wait_timeout}s"
        sleep "$wait_interval"
        wait_elapsed=$((wait_elapsed + wait_interval))
    done

    if [[ $wait_elapsed -ge $wait_timeout ]]; then
        echo ""
        log_error "Service deployments not ready after ${wait_timeout}s" \
                  "Some deployments did not become ready in time" \
                  "Check pod status" \
                  "kubectl get pods -n ${env_name} --field-selector=status.phase!=Running"
        return 1
    fi

    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Future module steps (placeholders)
# ─────────────────────────────────────────────────────────────────────────────
# env_phase2_step3_registry()   — Install openg2p-registry
# env_phase2_step4_pbms()       — Install openg2p-pbms
# env_phase2_step5_spar()       — Install openg2p-spar
# env_phase2_step6_g2p_bridge() — Install g2p-bridge

# ─────────────────────────────────────────────────────────────────────────────
# Run all Phase 2 steps
# ─────────────────────────────────────────────────────────────────────────────
run_env_phase2() {
    local env_name=$(cfg "environment")

    log_step "E2" "Phase 2 — Module Installation for '${env_name}'"

    env_phase2_step1_commons_base
    env_phase2_step2_commons_services

    # Future:
    # env_phase2_step3_registry
    # env_phase2_step4_pbms
    # env_phase2_step5_spar
    # env_phase2_step6_g2p_bridge

    log_success "Phase 2 complete — modules installed in '${env_name}'."
}
