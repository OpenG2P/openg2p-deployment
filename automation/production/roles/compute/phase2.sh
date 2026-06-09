#!/usr/bin/env bash
# =============================================================================
# Compute Node — Phase 2: Platform components via Helmfile
# =============================================================================
# Steps:
#   C2.1  Render helmfile-infra-values.yaml from prod-config
#   C2.2  Install Istio via istioctl (uses charts/istio-install/templates/operator.yaml)
#   C2.3  helmfile sync — Rancher (local auth, embedded NFS-backed Postgres),
#         monitoring, logging, Istio EnvoyFilter, Gateways, VirtualServices
#   C2.4  Bootstrap Rancher — set a known admin password (saved to
#         cattle-system/rancher-secret), set server-url, rename the "local"
#         cluster to cluster_name (LOCAL auth — no Keycloak/SAML)
# =============================================================================

# Hostname helpers come from lib/shared/hostnames.sh (sourced by compute/run.sh).

# ─────────────────────────────────────────────────────────────────────────
# C2.1  Render helmfile values
# ─────────────────────────────────────────────────────────────────────────
compute_render_helmfile_values() {
    local values_file="${WORK_DIR}/helmfile-infra-values.yaml"
    local rancher_host=$(get_rancher_hostname)

    # Loki's dedicated MinIO root password: prefer the config value, else reuse
    # a previously persisted one, else generate + persist (stable across re-runs
    # so Loki and its MinIO keep agreeing on subsequent syncs).
    local secrets_dir="/etc/openg2p/secrets"
    local loki_minio_pw_file="${secrets_dir}/loki-minio.env"
    local loki_minio_pw
    loki_minio_pw=$(cfg 'loki_minio_root_password')
    if [[ -z "$loki_minio_pw" ]]; then
        if [[ -f "$loki_minio_pw_file" ]]; then
            loki_minio_pw=$(grep '^LOKI_MINIO_ROOT_PASSWORD=' "$loki_minio_pw_file" | cut -d= -f2-)
            log_info "Using existing Loki MinIO password from ${loki_minio_pw_file}"
        else
            loki_minio_pw=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)
            mkdir -p "$secrets_dir" && chmod 0700 "$secrets_dir"
            echo "LOKI_MINIO_ROOT_PASSWORD=${loki_minio_pw}" > "$loki_minio_pw_file"
            chmod 0600 "$loki_minio_pw_file"
            log_info "Generated Loki MinIO password (saved at ${loki_minio_pw_file})"
        fi
    fi

    cat > "$values_file" <<EOF
# Auto-generated from prod-config — do not edit manually
# Generated at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

rancher_hostname:    "${rancher_host}"
node_ip:             "$(cfg 'compute_private_ip')"

rancher:
  version:  "$(cfg 'rancher_version' '2.12.3')"
  replicas: $(cfg 'rancher_replicas' '1')

# Observability — Grafana Loki log store + its dedicated MinIO object store.
loki:
  retentionHours: $(cfg 'loki_retention_hours' '168')
  minio:
    rootUser:     "$(cfg 'loki_minio_root_user' 'loki')"
    rootPassword: "${loki_minio_pw}"
    size:         "$(cfg 'loki_minio_size' '50Gi')"

# Alerting notification channels. Empty value => that channel stays inactive
# (the Alertmanager receiver renders without it). WhatsApp is not supported.
alerting:
  slack:
    webhookUrl: "$(cfg 'alert_slack_webhook_url' '')"
    channel:    "$(cfg 'alert_slack_channel' '#alerts')"
  smtp:
    smarthost:  "$(cfg 'alert_smtp_smarthost' '')"
    from:       "$(cfg 'alert_smtp_from' '')"
    username:   "$(cfg 'alert_smtp_username' '')"
    password:   "$(cfg 'alert_smtp_password' '')"
    to:         "$(cfg 'alert_smtp_to' '')"
  telegram:
    botToken:   "$(cfg 'alert_telegram_bot_token' '')"
    chatId:     "$(cfg 'alert_telegram_chat_id' '')"

# Optional AI layer. Disabled by default — when false, no AI components install
# and the observability stack is unaffected. Model access via OpenRouter (cloud).
ai:
  enabled: $(cfg 'ai_enabled' 'false')
  openrouterApiKey: "$(cfg 'ai_openrouter_api_key' '')"
  model: "$(cfg 'ai_model' 'openrouter/qwen/qwen-2.5-72b-instruct')"
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

    log_step "C2.3" "helmfile sync — Rancher, monitoring, logging"

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
# C2.4  Bootstrap Rancher (LOCAL auth) — admin password, server-url, cluster name
# ─────────────────────────────────────────────────────────────────────────
# Rancher ships with a one-time random bootstrap password and names the cluster
# it manages "local". This step (idempotent) turns that into a usable install:
#   - reset the admin password to a known value, saved in the K8s secret
#     cattle-system/rancher-secret (the secret the completion summary reads)
#   - set the server-url to https://rancher.<domain>
#   - rename the built-in "local" cluster to cluster_name, so the Rancher UI
#     shows e.g. "openg2p" instead of "local"
#
# Rancher uses LOCAL authentication — there is NO Keycloak/SAML wiring here.
# (This is the Keycloak-free remainder of the former phase 3, which was removed
#  wholesale when the Keycloak<->Rancher SAML integration was dropped.)

# Try a Rancher local-auth login; echo the session token (empty on failure).
_rancher_try_login() {
    local url="$1" password="$2" response
    response=$(curl -sk -X POST "${url}/v3-public/localProviders/local?action=login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"admin\",\"password\":\"${password}\"}" 2>/dev/null)
    echo "$response" | jq -r '.token // empty' 2>/dev/null || true
}

# Authenticated Rancher API call.
_rancher_api() {
    local method="$1" url="$2" token="$3" data="${4:-}"
    if [[ -n "$data" ]]; then
        curl -sk -X "$method" "$url" -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" -d "$data" 2>/dev/null
    else
        curl -sk -X "$method" "$url" -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" 2>/dev/null
    fi
}

compute_bootstrap_rancher() {
    local step="compute.phase2.rancher_bootstrap"
    if skip_if_done "$step" "Rancher bootstrap"; then return 0; fi

    log_step "C2.4" "Bootstrap Rancher — admin password, server-url, cluster name"

    ensure_kubeconfig

    local rancher_host rancher_url
    rancher_host=$(get_rancher_hostname)
    rancher_url="https://${rancher_host}"

    # ── Wait for the Rancher deployment to be available ──────────────────
    wait_for_command "Rancher deployment ready" \
        "kubectl -n cattle-system rollout status deployment/rancher --timeout=5s" \
        600 15 || {
        log_error "Rancher is not ready" \
                  "Rancher deployment did not become available" \
                  "Check Rancher pods" \
                  "kubectl -n cattle-system get pods"
        exit 1
    }
    sleep 10

    # ── Verify we can actually REACH Rancher's API ───────────────────────
    # An unreachable API returns an empty body that looks just like a wrong
    # password, so probe connectivity explicitly before trying to log in.
    log_info "Probing Rancher API connectivity at ${rancher_url}..."
    local probe_code
    probe_code=$(curl -sk -o /dev/null --max-time 10 -w '%{http_code}' \
                 "${rancher_url}/v3-public" 2>/dev/null) || probe_code="000"
    case "$probe_code" in
        200|301|302|401|403) log_success "Rancher API reachable (HTTP ${probe_code})." ;;
        *)
            log_error "Cannot reach Rancher at ${rancher_url} (HTTP '${probe_code}')" \
                      "DNS resolution or TCP connect to ${rancher_url} failed from the compute node" \
                      "Check /etc/hosts maps ${rancher_host} to the RP private IP and that RP nginx routes 443 to compute:30080" \
                      "getent hosts ${rancher_host}; curl -kv ${rancher_url}/ping"
            exit 1
            ;;
    esac

    # ── Bootstrap the admin password ─────────────────────────────────────
    # Resolution order (no password is ever stored in the config file):
    #   1. RANCHER_ADMIN_PASSWORD env var (operator override)
    #   2. cattle-system/rancher-secret  (a previous run — makes this idempotent)
    #   3. cattle-system/bootstrap-secret (fresh install → auto-generate + set)
    #   4. kubectl exec reset-password    (operator changed it manually)
    log_info "Bootstrapping Rancher admin password..."
    local rancher_admin_password="" rancher_token=""

    # 1. env var
    if [[ -n "${RANCHER_ADMIN_PASSWORD:-}" ]]; then
        rancher_token=$(_rancher_try_login "$rancher_url" "$RANCHER_ADMIN_PASSWORD")
        if [[ -n "$rancher_token" ]]; then
            rancher_admin_password="$RANCHER_ADMIN_PASSWORD"
            log_success "Rancher login successful (source: RANCHER_ADMIN_PASSWORD)."
        fi
    fi

    # 2. existing rancher-secret
    if [[ -z "$rancher_token" ]]; then
        local secret_password
        secret_password=$(kubectl -n cattle-system get secret rancher-secret \
            -o jsonpath='{.data.adminPassword}' 2>/dev/null | base64 -d 2>/dev/null || true)
        if [[ -n "$secret_password" ]]; then
            rancher_token=$(_rancher_try_login "$rancher_url" "$secret_password")
            if [[ -n "$rancher_token" ]]; then
                rancher_admin_password="$secret_password"
                log_success "Rancher login successful (source: existing rancher-secret)."
            fi
        fi
    fi

    # 3. bootstrap password (fresh install) → set a generated admin password
    if [[ -z "$rancher_token" ]]; then
        log_info "Trying the one-time bootstrap password (fresh install)..."
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
            rancher_token=$(_rancher_try_login "$rancher_url" "$bootstrap_password")
            if [[ -n "$rancher_token" ]]; then
                rancher_admin_password="openg2p-$(openssl rand -hex 8)"
                log_info "Bootstrap login successful. Setting a new admin password..."
                curl -sk -X POST "${rancher_url}/v3/users?action=changepassword" \
                    -H "Authorization: Bearer ${rancher_token}" \
                    -H "Content-Type: application/json" \
                    -d "{\"currentPassword\":\"${bootstrap_password}\",\"newPassword\":\"${rancher_admin_password}\"}" \
                    > /dev/null 2>&1
                rancher_token=$(_rancher_try_login "$rancher_url" "$rancher_admin_password")
                [[ -n "$rancher_token" ]] && log_success "Rancher admin password generated and set."
            fi
        fi
    fi

    # 4. force reset via kubectl exec
    if [[ -z "$rancher_token" ]]; then
        log_warn "All known passwords failed — force-resetting via kubectl exec..."
        local reset_password
        reset_password=$(kubectl -n cattle-system exec deploy/rancher -- reset-password 2>/dev/null \
            | tail -1 | tr -d '[:space:]' || true)
        if [[ -n "$reset_password" ]]; then
            rancher_token=$(_rancher_try_login "$rancher_url" "$reset_password")
            if [[ -n "$rancher_token" ]]; then
                rancher_admin_password="openg2p-$(openssl rand -hex 8)"
                curl -sk -X POST "${rancher_url}/v3/users?action=changepassword" \
                    -H "Authorization: Bearer ${rancher_token}" \
                    -H "Content-Type: application/json" \
                    -d "{\"currentPassword\":\"${reset_password}\",\"newPassword\":\"${rancher_admin_password}\"}" \
                    > /dev/null 2>&1
                rancher_token=$(_rancher_try_login "$rancher_url" "$rancher_admin_password")
                [[ -n "$rancher_token" ]] && log_success "Rancher admin password reset and set."
            fi
        fi
    fi

    if [[ -z "$rancher_token" ]]; then
        log_error "Cannot log in to Rancher to bootstrap the admin password" \
                  "All methods failed (env var, rancher-secret, bootstrap-secret, kubectl reset)" \
                  "Retry with an explicit password, then re-run this phase" \
                  "RANCHER_ADMIN_PASSWORD=yourpass <orchestrator> --role compute --phase 2 --force"
        exit 1
    fi

    # ── Persist the admin password + set the server URL ──────────────────
    _rancher_api PUT "${rancher_url}/v3/settings/server-url" "$rancher_token" \
        "{\"value\":\"${rancher_url}\"}" > /dev/null 2>&1

    kubectl -n cattle-system create secret generic rancher-secret \
        --from-literal=adminPassword="${rancher_admin_password}" \
        --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1
    log_success "Rancher admin ready — password saved to cattle-system/rancher-secret."

    # ── Rename the built-in "local" cluster to cluster_name ──────────────
    local cluster_display_name
    cluster_display_name=$(cfg "cluster_name" "openg2p")
    if [[ "$cluster_display_name" != "local" ]]; then
        log_info "Setting Rancher cluster display name to '${cluster_display_name}'..."
        local rename_response rename_error
        rename_response=$(_rancher_api PUT "${rancher_url}/v3/clusters/local" "$rancher_token" \
            "{\"name\":\"${cluster_display_name}\"}")
        rename_error=$(echo "$rename_response" | jq -r '.message // empty' 2>/dev/null || true)
        if [[ -n "$rename_error" ]]; then
            log_warn "API rename failed (${rename_error}); trying kubectl patch..."
            kubectl patch clusters.management.cattle.io local --type=merge \
                -p "{\"spec\":{\"displayName\":\"${cluster_display_name}\"}}" > /dev/null 2>&1 || \
                log_warn "Could not rename cluster — rename it manually in the Rancher UI."
        else
            log_success "Rancher cluster display name set to '${cluster_display_name}'."
        fi
    fi

    mark_step_done "$step"
}

# ─────────────────────────────────────────────────────────────────────────
# Phase entry
# ─────────────────────────────────────────────────────────────────────────
run_compute_phase2() {
    compute_render_helmfile_values
    compute_install_istio
    compute_helmfile_sync
    compute_bootstrap_rancher
}
