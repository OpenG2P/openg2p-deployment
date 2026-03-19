#!/usr/bin/env bash
# =============================================================================
# OpenG2P Deployment Automation — Phase 2: Platform Components (Helmfile)
# =============================================================================
# Installs Istio, Rancher, Keycloak, Monitoring, and Logging on the K8s cluster
# using Helmfile. Sourced by openg2p-infra.sh — do not run directly.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Install Istio via istioctl (not Helm — Istio uses its own installer)
# ─────────────────────────────────────────────────────────────────────────────
install_istio_if_needed() {
    local step_id="phase2.istio"

    if is_step_done "$step_id" && [[ "$FORCE_MODE" != "true" ]]; then
        log_info "Skipping Istio installation — already completed."
        return 0
    fi

    if kubectl -n istio-system get deployment istiod &>/dev/null; then
        log_success "Istio (istiod) is already deployed."
        mark_step_done "$step_id"
        return 0
    fi

    log_info "Installing Istio via istioctl..."
    local istio_operator="${SCRIPT_DIR}/charts/istio-install/templates/operator.yaml"

    if [[ ! -f "$istio_operator" ]]; then
        log_error "Istio operator YAML not found at ${istio_operator}" \
                  "The automation charts directory may be incomplete" \
                  "Ensure the charts/istio-install directory exists"
        return 1
    fi

    istioctl install -f "$istio_operator" -y || {
        log_error "istioctl install failed" \
                  "Istio could not be installed on the cluster" \
                  "Check cluster access and istioctl version" \
                  "istioctl version; kubectl get nodes"
        return 1
    }

    wait_for_deployment "istio-system" "istiod" 300 || return 1
    wait_for_command "Istio ingress gateway pods" \
        "kubectl -n istio-system get pods -l istio=ingressgateway -o jsonpath='{.items[*].status.phase}' | grep -q Running" \
        300 10

    mark_step_done "$step_id"
    log_success "Istio installed and healthy."
}

# ─────────────────────────────────────────────────────────────────────────────
# Generate helmfile-infra-values.yaml from config
# ─────────────────────────────────────────────────────────────────────────────
generate_helmfile_infra_values() {
    local values_file="${SCRIPT_DIR}/helmfile-infra-values.yaml"
    local rancher_host=$(get_rancher_hostname)
    local keycloak_host=$(get_keycloak_hostname)

    cat > "$values_file" <<EOF
# Auto-generated from infra config — do not edit manually
# Generated at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

rancher_hostname: "${rancher_host}"
keycloak_hostname: "${keycloak_host}"
node_ip: "$(cfg 'node_ip')"

rancher:
  version: "$(cfg 'rancher.version' '2.12.3')"
  replicas: $(cfg 'rancher.replicas' '1')

keycloak:
  replicas: $(cfg 'keycloak.replicas' '1')
EOF

    log_success "Helmfile infra values generated at ${values_file}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Run Phase 2: Istio + Helmfile sync
# ─────────────────────────────────────────────────────────────────────────────
run_phase2() {
    log_step "2" "Phase 2 — Platform Components (Helmfile)"

    ensure_kubeconfig || return 1

    log_info "Verifying Kubernetes cluster is healthy..."
    if ! kubectl get nodes | grep -qw Ready; then
        log_error "Kubernetes node is not in Ready state" \
                  "RKE2 may still be initializing" \
                  "Check node status and RKE2 logs" \
                  "kubectl get nodes; journalctl -u rke2-server -n 30"
        return 1
    fi
    log_success "Kubernetes cluster is healthy."

    install_istio_if_needed || return 1
    generate_helmfile_infra_values

    log_info "Running Helmfile sync for platform components..."
    log_info "This may take 10-20 minutes on first run."
    cd "${SCRIPT_DIR}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would execute: helmfile -f helmfile-infra.yaml.gotmpl sync"
        helmfile -f helmfile-infra.yaml.gotmpl diff 2>/dev/null || log_warn "helmfile diff may fail on first run (expected)."
        return 0
    fi

    helmfile -f helmfile-infra.yaml.gotmpl sync 2>&1 | tee -a "$LOG_FILE" || {
        log_error "Helmfile sync failed" \
                  "One or more Helm releases failed to install" \
                  "Review the output above for specific errors" \
                  "helmfile -f helmfile-infra.yaml.gotmpl sync --debug 2>&1 | tail -50"
        echo ""
        log_info "Troubleshooting tips:"
        log_info "  1. Check pod status:  kubectl get pods -A | grep -v Running"
        log_info "  2. Check events:      kubectl get events -A --sort-by=.lastTimestamp | tail -20"
        log_info "  3. Re-run to retry:   sudo $0 --config $(basename "$CONFIG_FILE")"
        return 1
    }

    log_success "Phase 2 complete — all platform components deployed."
}
