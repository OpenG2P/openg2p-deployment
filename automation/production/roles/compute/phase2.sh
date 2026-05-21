#!/usr/bin/env bash
# =============================================================================
# Compute Node — Phase 2: Platform components via Helmfile
# =============================================================================
# Steps:
#   C2.1  Render helmfile-infra-values.yaml from prod-config
#   C2.2  Install Istio via istioctl (uses charts/istio-install/templates/operator.yaml)
#   C2.3  helmfile sync — Rancher, Keycloak (with embedded NFS-backed Postgres),
#         monitoring, logging, Istio EnvoyFilter, Gateways, VirtualServices
# =============================================================================

# Hostname helpers come from lib/shared/hostnames.sh (sourced by compute/run.sh).

# ─────────────────────────────────────────────────────────────────────────
# C2.1  Render helmfile values
# ─────────────────────────────────────────────────────────────────────────
compute_render_helmfile_values() {
    local values_file="${WORK_DIR}/helmfile-infra-values.yaml"
    local rancher_host=$(get_rancher_hostname)
    local keycloak_host=$(get_keycloak_hostname)

    cat > "$values_file" <<EOF
# Auto-generated from prod-config — do not edit manually
# Generated at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

rancher_hostname:    "${rancher_host}"
keycloak_hostname:   "${keycloak_host}"
node_ip:             "$(cfg 'compute_private_ip')"

rancher:
  version:  "$(cfg 'rancher_version' '2.12.3')"
  replicas: $(cfg 'rancher_replicas' '1')

keycloak:
  replicas: $(cfg 'keycloak_replicas' '1')
EOF

    log_success "Helmfile values rendered at ${values_file}"
}

# ─────────────────────────────────────────────────────────────────────────
# C2.2  Istio (istioctl)
# ─────────────────────────────────────────────────────────────────────────
compute_install_istio() {
    local step="compute.phase2.istio"
    if skip_if_done "$step" "Istio install"; then return 0; fi

    log_step "C2.2" "Install Istio via istioctl"

    ensure_kubeconfig

    if kubectl -n istio-system get deployment istiod &>/dev/null; then
        log_success "Istio (istiod) already deployed."
        mark_step_done "$step"
        return 0
    fi

    local operator="${WORK_DIR}/charts/istio-install/templates/operator.yaml"
    if [[ ! -f "$operator" ]]; then
        log_error "Istio operator YAML not found: ${operator}" \
                  "charts/istio-install/ may be missing on the staging dir" \
                  "Re-run from the laptop orchestrator"
        exit 1
    fi

    istioctl install -f "$operator" -y

    wait_for_deployment "istio-system" "istiod" 300
    wait_for_command "Istio ingress gateway pods" \
        "kubectl -n istio-system get pods -l istio=ingressgateway -o jsonpath='{.items[*].status.phase}' | grep -q Running" \
        300 10

    mark_step_done "$step"
}

# ─────────────────────────────────────────────────────────────────────────
# C2.3  Helmfile sync
# ─────────────────────────────────────────────────────────────────────────
compute_helmfile_sync() {
    local step="compute.phase2.helmfile"
    if skip_if_done "$step" "helmfile sync"; then return 0; fi

    log_step "C2.3" "helmfile sync — Rancher, Keycloak, monitoring, logging"

    ensure_kubeconfig

    cd "${WORK_DIR}"

    log_info "Running helmfile sync. First run takes 10-20 minutes."
    if ! helmfile -f helmfile-infra.yaml.gotmpl sync; then
        log_error "helmfile sync failed" \
                  "One or more Helm releases did not install" \
                  "Inspect output and pod state" \
                  "helmfile -f helmfile-infra.yaml.gotmpl sync --debug 2>&1 | tail -50"
        log_info "Triage:"
        log_info "  kubectl get pods -A | grep -v Running"
        log_info "  kubectl get events -A --sort-by=.lastTimestamp | tail -20"
        exit 1
    fi

    log_success "helmfile sync complete — platform components installed."
    mark_step_done "$step"
}

# ─────────────────────────────────────────────────────────────────────────
# Phase entry
# ─────────────────────────────────────────────────────────────────────────
run_compute_phase2() {
    compute_render_helmfile_values
    compute_install_istio
    compute_helmfile_sync
}
