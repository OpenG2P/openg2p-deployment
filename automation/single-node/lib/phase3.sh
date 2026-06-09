#!/usr/bin/env bash
# =============================================================================
# OpenG2P Deployment Automation — Phase 3: Rancher Configuration
# =============================================================================
# Bootstraps and configures Rancher using LOCAL authentication (no SSO):
#   - Bootstrap Rancher admin password
#   - Set the Rancher server URL and cluster display name
#   - Create custom project RoleTemplates (no-secrets variants)
#
# Rancher uses local authentication. Administrators create additional users
# directly in Rancher (☰ → Users & Authentication → Users). There is no
# Keycloak/SAML integration at the infra level — the OpenG2P apps' Keycloak is
# installed per-environment by openg2p-environment.sh.
#
# Rancher admin password resolution (no password in config file):
#   1. Environment variable RANCHER_ADMIN_PASSWORD
#   2. K8s secret cattle-system/rancher-secret (from previous run)
#   3. Bootstrap password from K8s secret (fresh install) → auto-generate
#   4. Force reset via kubectl exec (user changed password manually)
#
# Ref: https://docs.openg2p.org/deployment/base-infrastructure/rancher
# Sourced by openg2p-infra.sh — do not run directly.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Rancher API call
# ─────────────────────────────────────────────────────────────────────────────
rancher_api() {
    local method="$1"
    local url="$2"
    local token="$3"
    local data="${4:-}"

    if [[ -n "$data" ]]; then
        curl -sk -X "$method" "$url" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$data" 2>/dev/null
    else
        curl -sk -X "$method" "$url" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" 2>/dev/null
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Try Rancher login, return token or empty
# ─────────────────────────────────────────────────────────────────────────────
rancher_try_login() {
    local url="$1"
    local password="$2"
    local response
    response=$(curl -sk -X POST "${url}/v3-public/localProviders/local?action=login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"admin\",\"password\":\"${password}\"}" 2>/dev/null)
    echo "$response" | jq -r '.token // empty' 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: Rancher configuration (local authentication)
# ─────────────────────────────────────────────────────────────────────────────
run_phase3() {
    local step_id="phase3.rancher_config"

    if is_step_done "$step_id" && [[ "$FORCE_MODE" != "true" ]]; then
        log_info "Skipping Rancher configuration — already completed."
        return 0
    fi

    log_step "3" "Phase 3 — Rancher Configuration (local authentication)"

    ensure_kubeconfig || return 1

    local rancher_host=$(get_rancher_hostname)
    local rancher_url="https://${rancher_host}"

    # ── Step 3.1: Wait for Rancher to be ready ───────────────────────────
    log_info "Waiting for Rancher to be fully ready..."

    wait_for_command "Rancher deployment ready" \
        "kubectl -n cattle-system rollout status deployment/rancher --timeout=5s" \
        600 15 || {
        log_error "Rancher is not ready" \
                  "Rancher deployment did not become available" \
                  "Check Rancher pods" \
                  "kubectl -n cattle-system get pods"
        return 1
    }

    sleep 10

    # ── Step 3.2: Bootstrap Rancher admin password ───────────────────────
    log_info "Bootstrapping Rancher admin password..."

    local rancher_admin_password=""
    local rancher_token=""

    # Source 1: Environment variable
    if [[ -n "${RANCHER_ADMIN_PASSWORD:-}" ]]; then
        rancher_admin_password="$RANCHER_ADMIN_PASSWORD"
        log_info "Trying password from RANCHER_ADMIN_PASSWORD env var..."
        rancher_token=$(rancher_try_login "$rancher_url" "$rancher_admin_password")
        if [[ -n "$rancher_token" ]]; then
            log_success "Rancher login successful (source: env var)."
        else
            log_warn "Env var password didn't work."
            rancher_admin_password=""
        fi
    fi

    # Source 2: K8s secret from previous script run
    if [[ -z "$rancher_token" ]]; then
        local secret_password
        secret_password=$(kubectl -n cattle-system get secret rancher-secret \
            -o jsonpath='{.data.adminPassword}' 2>/dev/null | base64 -d 2>/dev/null || true)
        if [[ -n "$secret_password" ]]; then
            log_info "Trying password from K8s secret cattle-system/rancher-secret..."
            rancher_token=$(rancher_try_login "$rancher_url" "$secret_password")
            if [[ -n "$rancher_token" ]]; then
                rancher_admin_password="$secret_password"
                log_success "Rancher login successful (source: K8s secret)."
            else
                log_warn "K8s secret password didn't work."
            fi
        fi
    fi

    # Source 3: Bootstrap password (fresh install)
    if [[ -z "$rancher_token" ]]; then
        log_info "Trying bootstrap password (fresh install)..."
        local bootstrap_password
        bootstrap_password=$(kubectl -n cattle-system get secret bootstrap-secret \
            -o jsonpath='{.data.bootstrapPassword}' 2>/dev/null | base64 -d 2>/dev/null || true)

        if [[ -z "$bootstrap_password" ]]; then
            bootstrap_password=$(kubectl -n cattle-system get pods -l app=rancher \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | \
                xargs -I{} kubectl -n cattle-system logs {} 2>/dev/null | \
                grep "Bootstrap Password:" | head -1 | awk '{print $NF}' || true)
        fi

        if [[ -n "$bootstrap_password" ]]; then
            rancher_token=$(rancher_try_login "$rancher_url" "$bootstrap_password")
            if [[ -n "$rancher_token" ]]; then
                rancher_admin_password="openg2p-$(openssl rand -hex 8)"
                log_info "Bootstrap login successful. Setting new admin password..."
                curl -sk -X POST "${rancher_url}/v3/users?action=changepassword" \
                    -H "Authorization: Bearer ${rancher_token}" \
                    -H "Content-Type: application/json" \
                    -d "{\"currentPassword\":\"${bootstrap_password}\",\"newPassword\":\"${rancher_admin_password}\"}" \
                    > /dev/null 2>&1
                rancher_token=$(rancher_try_login "$rancher_url" "$rancher_admin_password")
                log_success "Rancher admin password auto-generated and set."
            else
                log_warn "Bootstrap password didn't work either."
            fi
        fi
    fi

    # Source 4: Force reset via kubectl exec
    if [[ -z "$rancher_token" ]]; then
        log_warn "All passwords failed. Force-resetting via kubectl exec..."
        local reset_output
        reset_output=$(kubectl -n cattle-system exec deploy/rancher -- reset-password 2>/dev/null || true)
        local reset_password
        reset_password=$(echo "$reset_output" | tail -1 | tr -d '[:space:]')

        if [[ -n "$reset_password" ]]; then
            rancher_token=$(rancher_try_login "$rancher_url" "$reset_password")
            if [[ -n "$rancher_token" ]]; then
                rancher_admin_password="openg2p-$(openssl rand -hex 8)"
                log_info "Reset successful. Setting new admin password..."
                curl -sk -X POST "${rancher_url}/v3/users?action=changepassword" \
                    -H "Authorization: Bearer ${rancher_token}" \
                    -H "Content-Type: application/json" \
                    -d "{\"currentPassword\":\"${reset_password}\",\"newPassword\":\"${rancher_admin_password}\"}" \
                    > /dev/null 2>&1
                rancher_token=$(rancher_try_login "$rancher_url" "$rancher_admin_password")
                log_success "Rancher admin password reset and updated."
            fi
        fi
    fi

    # Final check
    if [[ -z "$rancher_token" ]]; then
        log_error "Cannot login to Rancher" \
                  "All methods failed (env var, K8s secret, bootstrap, kubectl reset)" \
                  "Try: RANCHER_ADMIN_PASSWORD=yourpass sudo $0 --config ... --phase 3" \
                  "Or: kubectl -n cattle-system exec -it deploy/rancher -- reset-password"
        return 1
    fi

    # Set server URL
    rancher_api PUT "${rancher_url}/v3/settings/server-url" "$rancher_token" \
        "{\"value\":\"${rancher_url}\"}" > /dev/null 2>&1

    # Save password to K8s secret for future runs
    kubectl -n cattle-system create secret generic rancher-secret \
        --from-literal=adminPassword="${rancher_admin_password}" \
        --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

    log_success "Rancher admin ready. Password saved to cattle-system/rancher-secret."

    # ── Step 3.2b: Set Rancher cluster display name ──────────────────────
    local cluster_display_name=$(cfg "cluster_name" "openg2p")
    if [[ "$cluster_display_name" != "local" ]]; then
        log_info "Setting Rancher cluster display name to '${cluster_display_name}'..."
        local rename_response
        rename_response=$(rancher_api PUT "${rancher_url}/v3/clusters/local" "$rancher_token" \
            "{\"name\":\"${cluster_display_name}\"}")
        local rename_error
        rename_error=$(echo "$rename_response" | jq -r '.message // empty' 2>/dev/null)
        if [[ -n "$rename_error" ]]; then
            log_warn "API rename failed (${rename_error}), trying kubectl patch..."
            kubectl patch clusters.management.cattle.io local --type=merge \
                -p "{\"spec\":{\"displayName\":\"${cluster_display_name}\"}}" > /dev/null 2>&1 || \
                log_warn "Could not rename cluster. You can rename it manually in Rancher UI."
        else
            log_success "Rancher cluster display name set to '${cluster_display_name}'."
        fi
    fi

    # ── Step 3.3: Create custom project RoleTemplates ─────────────────────
    # Rancher's built-in project roles (project-member, read-only) both include
    # full secrets access. We create two additional roles that exclude secrets,
    # which are essential for multi-tenant environments where not every user
    # should see database passwords, API keys, etc.
    log_info "Creating custom project RoleTemplates..."

    # Role: Project Member (No Secrets)
    # Full CRUD on workloads, networking, config — but zero access to secrets.
    if kubectl get roletemplates.management.cattle.io project-member-no-secrets &>/dev/null; then
        log_info "RoleTemplate 'project-member-no-secrets' already exists — skipping."
    else
        log_info "Creating RoleTemplate 'project-member-no-secrets'..."
        kubectl create -f - <<'RTEOF'
apiVersion: management.cattle.io/v3
kind: RoleTemplate
metadata:
  name: project-member-no-secrets
  labels:
    cattle.io/creator: openg2p-automation
displayName: "Project Member (No Secrets)"
context: project
builtin: false
rules:
  # Workloads: full CRUD
  - apiGroups: ["", "apps", "batch"]
    resources:
      - pods
      - pods/log
      - pods/portforward
      - pods/exec
      - replicationcontrollers
      - deployments
      - daemonsets
      - statefulsets
      - replicasets
      - jobs
      - cronjobs
    verbs: ["*"]
  # Networking: full CRUD
  - apiGroups: ["", "networking.k8s.io"]
    resources:
      - services
      - endpoints
      - ingresses
      - networkpolicies
    verbs: ["*"]
  # Config (no secrets): full CRUD
  - apiGroups: [""]
    resources:
      - configmaps
      - serviceaccounts
      - persistentvolumeclaims
    verbs: ["*"]
  # Events, quotas, namespaces: read-only
  - apiGroups: [""]
    resources:
      - events
      - resourcequotas
      - limitranges
      - namespaces
    verbs: ["get", "list", "watch"]
  # Autoscaling
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["*"]
  # Policy
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["*"]
RTEOF
        if [[ $? -eq 0 ]]; then
            log_success "RoleTemplate 'project-member-no-secrets' created."
        else
            log_warn "Failed to create RoleTemplate 'project-member-no-secrets'."
        fi
    fi

    # Role: Project Read-Only (No Secrets)
    # Read-only on all resources except secrets. Cannot create, update, or delete anything.
    if kubectl get roletemplates.management.cattle.io project-readonly-no-secrets &>/dev/null; then
        log_info "RoleTemplate 'project-readonly-no-secrets' already exists — skipping."
    else
        log_info "Creating RoleTemplate 'project-readonly-no-secrets'..."
        kubectl create -f - <<'RTEOF'
apiVersion: management.cattle.io/v3
kind: RoleTemplate
metadata:
  name: project-readonly-no-secrets
  labels:
    cattle.io/creator: openg2p-automation
displayName: "Project Read-Only (No Secrets)"
context: project
builtin: false
rules:
  # Workloads: read-only
  - apiGroups: ["", "apps", "batch"]
    resources:
      - pods
      - pods/log
      - replicationcontrollers
      - deployments
      - daemonsets
      - statefulsets
      - replicasets
      - jobs
      - cronjobs
    verbs: ["get", "list", "watch"]
  # Networking: read-only
  - apiGroups: ["", "networking.k8s.io"]
    resources:
      - services
      - endpoints
      - ingresses
      - networkpolicies
    verbs: ["get", "list", "watch"]
  # Config (no secrets): read-only
  - apiGroups: [""]
    resources:
      - configmaps
      - serviceaccounts
      - persistentvolumeclaims
      - events
      - resourcequotas
      - limitranges
      - namespaces
    verbs: ["get", "list", "watch"]
  # Autoscaling: read-only
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["get", "list", "watch"]
  # Policy: read-only
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["get", "list", "watch"]
RTEOF
        if [[ $? -eq 0 ]]; then
            log_success "RoleTemplate 'project-readonly-no-secrets' created."
        else
            log_warn "Failed to create RoleTemplate 'project-readonly-no-secrets'."
        fi
    fi

    # ── Done ─────────────────────────────────────────────────────────────
    log_success "Rancher configuration complete."
    log_info ""
    log_info "  Rancher login URL:      ${rancher_url}"
    log_info "  Local admin login:      Username: admin  |  Password: ${rancher_admin_password}"
    log_info ""
    log_info "  Rancher uses LOCAL authentication. Create additional users directly"
    log_info "  in Rancher: ☰ → Users & Authentication → Users."
    log_info ""

    # Save for summary display
    echo "${rancher_admin_password}" > /var/lib/openg2p/deploy-state/rancher-admin-password
    chmod 600 /var/lib/openg2p/deploy-state/rancher-admin-password

    mark_step_done "$step_id"
}
