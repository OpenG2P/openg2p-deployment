#!/usr/bin/env bash
# =============================================================================
# OpenG2P Environment Setup — Phase 2: Module Installation
# =============================================================================
# Installs OpenG2P modules into the environment namespace via Helm.
# Currently supports openg2p-commons. Future modules (Registry, PBMS, SPAR,
# G2P Bridge) will be added as separate steps.
#
# Sourced by openg2p-environment.sh — do not run directly.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Helper: resolve openg2p-commons chart source
# ─────────────────────────────────────────────────────────────────────────────
get_commons_chart_ref() {
    local chart_path=$(cfg "commons.chart_path" "")
    if [[ -n "$chart_path" ]]; then
        # Resolve relative paths against SCRIPT_DIR
        [[ "$chart_path" = /* ]] || chart_path="${SCRIPT_DIR}/${chart_path}"
        if [[ -d "$chart_path" ]]; then
            echo "$chart_path"
            return
        fi
        log_warn "commons.chart_path '${chart_path}' not found. Falling back to remote chart."
    fi

    # Use remote chart from repo (must be repo_name/chart_name)
    echo "openg2p/openg2p-commons"
}

ensure_helm_repo() {
    local chart_path=$(cfg "commons.chart_path" "")
    if [[ -n "$chart_path" ]]; then
        # Local chart — no repo needed
        return 0
    fi

    local repo_url=$(cfg "commons.chart_repo" "https://openg2p.github.io/openg2p-helm")
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
# Step 2.1: Install openg2p-commons
# ─────────────────────────────────────────────────────────────────────────────
env_phase2_step1_commons() {
    local env_name=$(cfg "environment")
    local step_id="env-${env_name}.phase2.commons"

    if is_step_done "$step_id" && [[ "$FORCE_MODE" != "true" ]]; then
        log_info "Skipping openg2p-commons — already installed. Use --force to reinstall."
        return 0
    fi

    if ! cfg_bool "modules.commons"; then
        log_info "openg2p-commons disabled in config — skipping."
        return 0
    fi

    log_step "E2.1" "Installing openg2p-commons in '${env_name}'"

    ensure_kubeconfig || return 1

    local base_domain=$(get_env_base_domain)
    local keycloak_url=$(get_keycloak_url)
    local cm_user=$(cfg "keycloak.client_manager_user" "")
    local cm_pass=$(cfg "keycloak.client_manager_password" "")
    local chart_ref=$(get_commons_chart_ref)
    local chart_version=$(cfg "commons.chart_version" "")
    local release_name="commons"

    # Ensure helm repo is configured (for remote charts)
    ensure_helm_repo || return 1

    # Check if already installed
    if helm status "$release_name" -n "$env_name" &>/dev/null; then
        log_info "Helm release '${release_name}' already exists in '${env_name}'."
        log_info "Running helm upgrade..."
        local helm_action="upgrade"
    else
        log_info "Installing openg2p-commons..."
        local helm_action="install"
    fi

    # Build helm command
    local -a helm_args=(
        "$helm_action" "$release_name" "$chart_ref"
        -n "$env_name"
        --set "global.baseDomain=${base_domain}"
        --set "global.keycloakBaseUrl=${keycloak_url}"
        --set "keycloak-init.keycloak.url=${keycloak_url}"
        --set "keycloak-init.keycloak.user=${cm_user}"
        --wait
        --timeout 20m
    )

    # Add chart version if specified (only for remote charts)
    if [[ -n "$chart_version" && "$chart_ref" == "openg2p/openg2p-commons" ]]; then
        helm_args+=(--version "$chart_version")
    fi

    # Add any extra helm args from config
    local extra_args=$(cfg "commons.extra_helm_args" "")
    if [[ -n "$extra_args" ]]; then
        # shellcheck disable=SC2206
        helm_args+=($extra_args)
    fi

    log_info "Chart:    ${chart_ref}"
    log_info "Release:  ${release_name}"
    log_info "Domain:   ${base_domain}"
    log_info "Keycloak: ${keycloak_url}"
    log_info "User:     ${cm_user}"
    log_info ""
    log_info "Running: helm ${helm_action} ${release_name} ..."
    log_info "(this may take 15-20 minutes — Helm waits for all hooks to complete)"
    echo ""

    if ! helm "${helm_args[@]}"; then
        log_error "Helm ${helm_action} failed for openg2p-commons" \
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

    log_success "Helm ${helm_action} completed for openg2p-commons."

    # Verify deployments are ready
    log_info "Verifying all deployments are ready..."
    local not_ready
    not_ready=$(kubectl get deployments -n "$env_name" -o json 2>/dev/null | \
        jq -r '.items[] | select((.status.availableReplicas // 0) != (.status.replicas // 1)) | .metadata.name' 2>/dev/null || true)

    if [[ -n "$not_ready" ]]; then
        log_warn "Some deployments are not yet fully ready:"
        echo "$not_ready" | while read -r dep; do
            log_warn "  - ${dep}"
        done
        log_warn "They may still be starting. Check: kubectl get pods -n ${env_name}"
    else
        log_success "All deployments in '${env_name}' are ready."
    fi

    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Future module steps (placeholders)
# ─────────────────────────────────────────────────────────────────────────────
# env_phase2_step2_registry()   — Install openg2p-registry
# env_phase2_step3_pbms()       — Install openg2p-pbms
# env_phase2_step4_spar()       — Install openg2p-spar
# env_phase2_step5_g2p_bridge() — Install g2p-bridge

# ─────────────────────────────────────────────────────────────────────────────
# Run all Phase 2 steps
# ─────────────────────────────────────────────────────────────────────────────
run_env_phase2() {
    local env_name=$(cfg "environment")

    log_step "E2" "Phase 2 — Module Installation for '${env_name}'"

    env_phase2_step1_commons

    # Future:
    # env_phase2_step2_registry
    # env_phase2_step3_pbms
    # env_phase2_step4_spar
    # env_phase2_step5_g2p_bridge

    log_success "Phase 2 complete — modules installed in '${env_name}'."
}
