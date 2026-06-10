#!/usr/bin/env bash
# =============================================================================
# Environment — Phase 1: scaffolding (runs ON THE LAPTOP)
# =============================================================================
# Steps:
#   E1.1  Laptop tooling preflight (kubectl, helm, ssh, jq)
#   E1.2  Auto-fetch RKE2 kubeconfig from compute node (cached locally)
#   E1.3  Verify connectivity to the cluster
#   E1.4  Register OpenG2P Helm repo as a Rancher CatalogV2 ClusterRepo
#   E1.5  Create env namespace
#   E1.6  Create Rancher Project + move namespace into it
#   E1.7  Create Istio Gateway for *.<base_domain>
#   E1.8  Fetch PG superuser password from storage node;
#         create the K8s Secret the commons chart expects
#
# All steps are idempotent — they check the live cluster state and skip
# if the desired object already exists. Re-run as many times as you need.
# =============================================================================

# The Rancher CatalogV2 ClusterRepo must point at the Rancher-flavoured index
# (…/openg2p-helm/rancher), not the root chart index. That sub-index carries the
# `catalog.cattle.io/*` annotations Rancher needs to surface the OpenG2P charts
# in the Apps catalog with proper display names.
OPENG2P_REPO_URL="https://openg2p.github.io/openg2p-helm/rancher"
PG_SUPERUSER_FILE="/etc/openg2p/secrets/postgres-superuser.env"

# ---------------------------------------------------------------------------
# Resolve and cache the per-environment values that every step needs.
# ---------------------------------------------------------------------------
env_resolve_values() {
    ENV_NAME=$(cfg "environment.name" "prod")
    INSTALL_ENV=$(cfg_bool "install_environment" "true" && echo true || echo false)
    INSTALL_COMMONS=$(cfg_bool "environment.install_commons" "true" && echo true || echo false)

    # base_domain — defaults to the top-level public_domain. Customer keeps the
    # same wildcard cert covering this base.
    ENV_BASE_DOMAIN=$(cfg "environment.base_domain" "")
    [[ -z "$ENV_BASE_DOMAIN" ]] && ENV_BASE_DOMAIN=$(cfg "public_domain" "")
    if [[ -z "$ENV_BASE_DOMAIN" ]]; then
        log_error "environment.base_domain and top-level public_domain are both empty" \
                  "Cannot determine the env base domain" \
                  "Set public_domain in prod-config.yaml (or environment.base_domain to override)"
        exit 1
    fi

    STORAGE_PRIV=$(cfg "storage_private_ip")
    COMPUTE_PRIV=$(cfg "compute_private_ip")
    if [[ -z "$STORAGE_PRIV" || -z "$COMPUTE_PRIV" ]]; then
        log_error "storage_private_ip / compute_private_ip not set" \
                  "Provision-output (or prod-config) must define both" \
                  "Re-run provisioning, or set the keys manually in prod-config.yaml"
        exit 1
    fi

    # Conventional secret name the commons chart looks up by default.
    # Matches env-cluster.sh's external-PG pre-flight.
    PG_SECRET_NAME="commons-postgresql"

    # Laptop-side kubeconfig cache — fetched from compute node, server URL
    # rewritten to the compute private IP (laptop must already be on WG).
    KUBECONFIG_CACHE="${STATE_DIR}/environment/kubeconfig"
    export KUBECONFIG="$KUBECONFIG_CACHE"
}

# ---------------------------------------------------------------------------
# E1.1 — laptop tooling preflight
# ---------------------------------------------------------------------------
env_preflight_tooling() {
    log_step "E1.1" "Laptop tooling preflight"

    local missing=()
    for tool in kubectl helm ssh jq; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done

    if (( ${#missing[@]} > 0 )); then
        log_error "Missing required tools on the laptop: ${missing[*]}" \
                  "These tools are required to install an environment" \
                  "See docs.openg2p.org → Provisioning → Operator's workstation for install commands"
        exit 1
    fi

    log_success "kubectl, helm, ssh, jq present."
}

# ---------------------------------------------------------------------------
# E1.2 — auto-fetch RKE2 kubeconfig from compute node
# ---------------------------------------------------------------------------
env_fetch_kubeconfig() {
    log_step "E1.2" "Fetching RKE2 kubeconfig from compute node"

    if [[ -f "$KUBECONFIG_CACHE" ]] && kubectl --kubeconfig "$KUBECONFIG_CACHE" \
            cluster-info >/dev/null 2>&1; then
        log_info "Existing kubeconfig at ${KUBECONFIG_CACHE} is valid — reusing."
        return 0
    fi

    mkdir -p "$(dirname "$KUBECONFIG_CACHE")"

    # Prefer the purpose-built remote kubeconfig the compute phase generates
    # (/etc/rancher/rke2/rke2-remote.yaml) — its server URL is already rewritten
    # to the compute private IP from the node's own perspective, so it stays in
    # sync with the API server's TLS SANs. Fall back to rke2.yaml (server
    # 127.0.0.1) + a manual rewrite for older installs that predate the remote
    # variant.
    local raw
    if raw=$(ssh_run compute "sudo cat /etc/rancher/rke2/rke2-remote.yaml" 2>/dev/null) \
            && [[ -n "$raw" ]]; then
        log_info "Pulling /etc/rancher/rke2/rke2-remote.yaml from compute (${COMPUTE_PRIV})..."
        printf '%s\n' "$raw" > "$KUBECONFIG_CACHE"
    else
        log_info "rke2-remote.yaml not found — falling back to rke2.yaml + rewrite..."
        raw=$(ssh_run compute "sudo cat /etc/rancher/rke2/rke2.yaml" 2>&1) || {
            log_error "Could not read kubeconfig from compute" \
                      "Neither rke2-remote.yaml nor rke2.yaml could be read over SSH" \
                      "Check that the compute node is up and SSH/sudo work; \
                       also verify your Wireguard VPN connection is up" \
                      "ssh compute 'sudo test -r /etc/rancher/rke2/rke2.yaml'"
            exit 1
        }
        # RKE2 writes server: https://127.0.0.1:6443 — rewrite so the laptop
        # (on the WG VPN) can reach the API server at the compute private IP.
        printf '%s\n' "$raw" \
            | sed -E "s#server: https://127\\.0\\.0\\.1:6443#server: https://${COMPUTE_PRIV}:6443#g" \
            > "$KUBECONFIG_CACHE"
    fi

    chmod 0600 "$KUBECONFIG_CACHE"
    log_success "Kubeconfig cached at ${KUBECONFIG_CACHE} (private API: ${COMPUTE_PRIV}:6443)"
}

# ---------------------------------------------------------------------------
# E1.3 — verify connectivity to the cluster
# ---------------------------------------------------------------------------
env_verify_cluster() {
    log_step "E1.3" "Verifying connectivity to the Kubernetes cluster"

    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_warn "Cannot reach the cluster API at the compute private IP (${COMPUTE_PRIV})."
        log_warn "The Kubernetes API is on the private channel — your laptop must be on"
        log_warn "the Wireguard VPN to reach it. This is expected during the initial"
        log_warn "unattended install (WG is connected as a post-install step)."
        log_warn ""
        log_warn "  → Connect Wireguard (see Step 4.1 of the install guide), then run:"
        log_warn "      ./openg2p-prod.sh --role environment --config <your-config>"
        log_warn ""
        # Exit 75 (EX_TEMPFAIL) signals the orchestrator to DEFER this stage
        # gracefully — non-fatal, not marked done, re-runnable once WG is up.
        exit 75
    fi
    log_success "Cluster reachable. Server: $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
}

# ---------------------------------------------------------------------------
# E1.4 — register OpenG2P Helm repo as a Rancher CatalogV2 ClusterRepo
# ---------------------------------------------------------------------------
env_register_clusterrepo() {
    log_step "E1.4" "Registering OpenG2P Helm repo in Rancher"

    # On a freshly-installed cluster the env stage runs right after infra, so
    # Rancher's catalog (catalog.cattle.io) API and overall kubectl discovery
    # may not be ready yet — calls time out mid-body
    # ("...request canceled while reading body"). E1.3's cluster-info probe is
    # too small to catch this. Gate on a clean LIST of ClusterRepos first: it
    # waits out both "Rancher still starting" and a briefly flaky tunnel, and
    # (unlike a name lookup) returns success for an empty collection, so it's an
    # unambiguous "API is up and answering" signal that also protects E1.5–E1.8.
    if ! wait_for_command "Rancher catalog API (catalog.cattle.io) ready" \
            "kubectl get clusterrepos.catalog.cattle.io" \
            300 10; then
        log_error "Rancher catalog API did not become ready" \
                  "kubectl could not list catalog.cattle.io ClusterRepos within the timeout" \
                  "Check Rancher is up and your Wireguard tunnel is stable, then re-run the environment stage" \
                  "kubectl -n cattle-system get pods; kubectl get apiservices | grep cattle"
        exit 1
    fi

    # Reconcile the URL rather than skip-on-exists: a repo created by an older
    # run may carry a stale URL (e.g. the root index instead of …/rancher), and
    # a plain existence check would never fix it.
    local current_url=""
    if kubectl get clusterrepos.catalog.cattle.io openg2p >/dev/null 2>&1; then
        current_url=$(kubectl get clusterrepos.catalog.cattle.io openg2p \
            -o jsonpath='{.spec.url}' 2>/dev/null || true)
    fi

    if [[ "$current_url" == "$OPENG2P_REPO_URL" ]]; then
        log_info "Rancher ClusterRepo 'openg2p' already points at ${OPENG2P_REPO_URL} — unchanged."
        return 0
    fi

    # apply reconciles spec.url whether the repo is new or its URL changed;
    # retry so a single transient body-read timeout doesn't abort the stage.
    if ! kubectl_apply_retry 4 10 <<YAML
apiVersion: catalog.cattle.io/v1
kind: ClusterRepo
metadata:
  name: openg2p
spec:
  url: ${OPENG2P_REPO_URL}
YAML
    then
        log_error "Failed to register the OpenG2P ClusterRepo" \
                  "kubectl apply kept timing out / failing against the cluster" \
                  "Re-run the environment stage once Rancher and the Wireguard tunnel are stable" \
                  "./openg2p-prod.sh --config <your-config> --stage environment"
        exit 1
    fi

    if [[ -n "$current_url" ]]; then
        log_success "Rancher ClusterRepo 'openg2p' URL updated: ${current_url} -> ${OPENG2P_REPO_URL}."
        # Nudge Rancher's catalog controller to re-download the index now.
        kubectl annotate clusterrepos.catalog.cattle.io openg2p \
            catalog.cattle.io/force-update="$(date -u +%s 2>/dev/null || echo refresh)" \
            --overwrite >/dev/null 2>&1 || true
    else
        log_success "Rancher ClusterRepo 'openg2p' registered (${OPENG2P_REPO_URL})."
    fi
    log_info "Rancher UI → Apps → Repositories will reflect it within ~30s."
}

# ---------------------------------------------------------------------------
# E1.5 — create env namespace
# ---------------------------------------------------------------------------
env_create_namespace() {
    log_step "E1.5" "Creating namespace '${ENV_NAME}'"

    if kubectl get namespace "$ENV_NAME" >/dev/null 2>&1; then
        log_info "Namespace '${ENV_NAME}' already exists."
        return 0
    fi
    kubectl create namespace "$ENV_NAME" >/dev/null
    log_success "Namespace '${ENV_NAME}' created."
}

# ---------------------------------------------------------------------------
# E1.6 — create Rancher Project + move namespace into it
# ---------------------------------------------------------------------------
env_create_rancher_project() {
    log_step "E1.6" "Creating Rancher Project '${ENV_NAME}'"

    if ! kubectl get crd projects.management.cattle.io >/dev/null 2>&1; then
        log_warn "Rancher Project CRD not found on this cluster — skipping (manual step)."
        log_warn "Open Rancher UI → Projects/Namespaces → Create Project '${ENV_NAME}' and move the namespace."
        return 0
    fi

    local existing
    existing=$(kubectl get projects.management.cattle.io -n local -o json 2>/dev/null \
        | jq -r --arg n "$ENV_NAME" \
            '.items[] | select(.spec.displayName == $n) | .metadata.name' \
        | head -1 || true)

    if [[ -n "$existing" ]]; then
        log_info "Rancher Project '${ENV_NAME}' already exists (ID: ${existing})."
    else
        existing=$(kubectl create -f - -o jsonpath='{.metadata.name}' <<YAML
apiVersion: management.cattle.io/v3
kind: Project
metadata:
  generateName: p-
  namespace: local
spec:
  displayName: ${ENV_NAME}
  clusterName: local
YAML
        ) || {
            log_warn "Rancher Project create failed — set it up manually in the UI."
            return 0
        }
        log_success "Rancher Project '${ENV_NAME}' created (ID: ${existing})."
    fi

    local target="local:${existing}"
    local current
    current=$(kubectl get namespace "$ENV_NAME" \
        -o jsonpath='{.metadata.annotations.field\.cattle\.io/projectId}' 2>/dev/null || true)
    if [[ "$current" == "$target" ]]; then
        log_info "Namespace '${ENV_NAME}' already in the Rancher Project."
        return 0
    fi
    kubectl annotate namespace "$ENV_NAME" \
        "field.cattle.io/projectId=${target}" --overwrite >/dev/null 2>&1 \
        || log_warn "Could not annotate namespace — move it manually in Rancher UI."
    log_success "Namespace '${ENV_NAME}' associated with Rancher Project."
}

# ---------------------------------------------------------------------------
# E1.7 — Istio Gateway for *.<base_domain>
# ---------------------------------------------------------------------------
env_create_istio_gateway() {
    log_step "E1.7" "Creating Istio Gateway for *.${ENV_BASE_DOMAIN}"

    if kubectl -n "$ENV_NAME" get gateway internal >/dev/null 2>&1; then
        log_info "Istio Gateway 'internal' already exists in namespace '${ENV_NAME}'."
        return 0
    fi

    if ! kubectl_apply_retry 4 10 <<YAML
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: internal
  namespace: ${ENV_NAME}
spec:
  selector:
    istio: ingressgateway
  servers:
    - hosts:
        - "${ENV_BASE_DOMAIN}"
        - "*.${ENV_BASE_DOMAIN}"
      port:
        name: http2-redirect-https
        number: 8081
        protocol: HTTP2
      tls:
        httpsRedirect: true
    - hosts:
        - "${ENV_BASE_DOMAIN}"
        - "*.${ENV_BASE_DOMAIN}"
      port:
        name: http2
        number: 8080
        protocol: HTTP2
YAML
    then
        log_error "Failed to create the Istio Gateway for *.${ENV_BASE_DOMAIN}" \
                  "kubectl apply kept timing out / failing against the cluster" \
                  "Re-run the environment stage once the cluster/tunnel are stable" \
                  "./openg2p-prod.sh --config <your-config> --stage environment"
        exit 1
    fi
    log_success "Istio Gateway configured for *.${ENV_BASE_DOMAIN}."
}

# ---------------------------------------------------------------------------
# E1.8 — fetch PG superuser password from storage node, create K8s Secret
# ---------------------------------------------------------------------------
env_create_pg_secret() {
    log_step "E1.8" "Creating external-PG superuser secret '${PG_SECRET_NAME}'"

    if kubectl -n "$ENV_NAME" get secret "$PG_SECRET_NAME" >/dev/null 2>&1; then
        log_info "Secret '${PG_SECRET_NAME}' already exists in '${ENV_NAME}' — skipping."
        return 0
    fi

    log_info "Pulling PG superuser password from storage node (${STORAGE_PRIV})..."

    local raw
    raw=$(ssh_run storage "sudo cat ${PG_SUPERUSER_FILE}" 2>/dev/null) || {
        log_error "Could not read ${PG_SUPERUSER_FILE} from storage node" \
                  "Storage role's phase1 should have generated it" \
                  "Re-run: ./openg2p-prod.sh --role storage --config <your-config>"
        exit 1
    }

    local pg_password
    pg_password=$(printf '%s\n' "$raw" | grep '^POSTGRES_PASSWORD=' | cut -d= -f2-)
    if [[ -z "$pg_password" ]]; then
        log_error "POSTGRES_PASSWORD missing from ${PG_SUPERUSER_FILE} on storage" \
                  "Unexpected file format" \
                  "ssh storage 'sudo cat ${PG_SUPERUSER_FILE}'"
        exit 1
    fi

    kubectl -n "$ENV_NAME" create secret generic "$PG_SECRET_NAME" \
        --from-literal=postgres-password="$pg_password" >/dev/null

    log_success "Secret '${PG_SECRET_NAME}' created in '${ENV_NAME}' (key: postgres-password)."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
phase1_main() {
    env_resolve_values

    if [[ "$INSTALL_ENV" != "true" ]]; then
        log_warn "install_environment=false in config — skipping environment phase 1."
        log_warn "Set install_environment: true to enable, or run --role environment manually."
        return 0
    fi

    log_step "ENV phase 1" "Scaffolding for environment '${ENV_NAME}' (base domain: ${ENV_BASE_DOMAIN})"

    env_preflight_tooling
    env_fetch_kubeconfig
    env_verify_cluster
    env_register_clusterrepo
    env_create_namespace
    env_create_rancher_project
    env_create_istio_gateway
    env_create_pg_secret

    log_success "ENV phase 1 complete. Namespace + Project + Gateway + PG secret in place."
}
