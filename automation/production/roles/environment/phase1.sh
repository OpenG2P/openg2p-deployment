#!/usr/bin/env bash
# =============================================================================
# Environment — Phase 1: scaffolding (runs ON THE LAPTOP)
# =============================================================================
# Steps:
#   E1.1  Laptop tooling preflight (kubectl, helm, ssh, jq)
#   E1.2  Open SSH tunnel to Kubernetes API on compute + fetch kubeconfig
#         (no Wireguard required — same SSH path as infra install)
#   E1.3  Verify connectivity through the tunnel
#   E1.4  Register OpenG2P Helm repos as Rancher CatalogV2 ClusterRepos
#   E1.5  Create env namespace
#   E1.6  Create Rancher Project + move namespace into it
#   E1.7  Create Istio Gateway for *.<base_domain>
#   E1.8  Fetch PG superuser password from storage node;
#         create the K8s Secret the commons chart expects
#
# Commons is NOT installed here — install from the Rancher UI only.
# Gated by install_environment in prod-config (default true).
# =============================================================================

# Rancher CatalogV2 ClusterRepos registered during env scaffolding:
#   • openg2p         — GitHub Rancher-flavoured index (Apps catalog UI)
#   • openg2p-gitlab  — GitLab Helm package registry (scripted / helm CLI)
OPENG2P_REPO_URL="https://openg2p.github.io/openg2p-helm/rancher"
OPENG2P_GITLAB_REPO_URL="https://gitlab.com/api/v4/projects/84460547/packages/helm/stable"
PG_SUPERUSER_FILE="/etc/openg2p/secrets/postgres-superuser.env"

# ---------------------------------------------------------------------------
# Resolve and cache the per-environment values that every step needs.
# ---------------------------------------------------------------------------
env_resolve_values() {
    ENV_NAME=$(cfg "environment.name" "prod")
    INSTALL_ENV=$(cfg_bool "install_environment" "true" && echo true || echo false)

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

    PG_SECRET_NAME="commons-postgresql"
    KUBECONFIG_CACHE="${STATE_DIR}/environment/kubeconfig"
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
# E1.2 — SSH tunnel to K8s API + kubeconfig (no Wireguard)
# ---------------------------------------------------------------------------
env_open_cluster_access() {
    log_step "E1.2" "Opening SSH tunnel to Kubernetes API on compute"

    # Ensure SSH ControlMaster helpers are initialised when run via
    # openg2p-prod-env-install.sh / run.sh (orchestrator already called ssh_init).
    if [[ ! -d "${SSH_CTRL_DIR:-}" ]]; then
        ssh_init
    fi

    trap 'ssh_k8s_tunnel_close 2>/dev/null || true' EXIT

    if ! ssh_k8s_tunnel_open "$KUBECONFIG_CACHE"; then
        log_error "Could not reach the Kubernetes API via SSH tunnel" \
                  "Environment scaffolding needs kubectl access through SSH to compute" \
                  "Verify compute SSH works and RKE2 is up, then re-run" \
                  "./openg2p-prod.sh --stage environment --config <your-config>"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# E1.3 — verify connectivity through the tunnel
# ---------------------------------------------------------------------------
env_verify_cluster() {
    log_step "E1.3" "Verifying connectivity to the Kubernetes cluster"

    if ! kubectl cluster-info >/dev/null 2>&1; then
        log_error "Cannot reach the cluster API through the SSH tunnel" \
                  "kubectl cluster-info failed using ${KUBECONFIG_CACHE}" \
                  "Check the tunnel and RKE2 on compute" \
                  "ssh compute 'sudo systemctl status rke2-server'"
        exit 1
    fi
    log_success "Cluster reachable via SSH tunnel. Server: $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
}

# ---------------------------------------------------------------------------
# E4 — register OpenG2P Helm repos as Rancher CatalogV2 ClusterRepos
# ---------------------------------------------------------------------------
env_register_one_clusterrepo() {
    local name="$1"
    local url="$2"

    local current_url=""
    if kubectl get clusterrepos.catalog.cattle.io "$name" >/dev/null 2>&1; then
        current_url=$(kubectl get clusterrepos.catalog.cattle.io "$name" \
            -o jsonpath='{.spec.url}' 2>/dev/null || true)
    fi

    if [[ "$current_url" == "$url" ]]; then
        log_info "Rancher ClusterRepo '${name}' already points at ${url} — unchanged."
        return 0
    fi

    if ! kubectl_apply_retry 4 10 <<YAML
apiVersion: catalog.cattle.io/v1
kind: ClusterRepo
metadata:
  name: ${name}
spec:
  url: ${url}
YAML
    then
        log_error "Failed to register the ClusterRepo '${name}'" \
                  "kubectl apply kept timing out / failing against the cluster" \
                  "Re-run the environment stage once Rancher is stable" \
                  "./openg2p-prod.sh --config <your-config> --stage environment"
        return 1
    fi

    if [[ -n "$current_url" ]]; then
        log_success "Rancher ClusterRepo '${name}' URL updated: ${current_url} -> ${url}."
        kubectl annotate clusterrepos.catalog.cattle.io "$name" \
            catalog.cattle.io/force-update="$(date -u +%s 2>/dev/null || echo refresh)" \
            --overwrite >/dev/null 2>&1 || true
    else
        log_success "Rancher ClusterRepo '${name}' registered (${url})."
    fi
}

env_register_clusterrepo() {
    log_step "E1.4" "Registering OpenG2P Helm repos in Rancher"

    if ! wait_for_command "Rancher catalog API (catalog.cattle.io) ready" \
            "kubectl get clusterrepos.catalog.cattle.io" \
            300 10; then
        log_error "Rancher catalog API did not become ready" \
                  "kubectl could not list catalog.cattle.io ClusterRepos within the timeout" \
                  "Check Rancher is up, then re-run the environment stage" \
                  "kubectl -n cattle-system get pods; kubectl get apiservices | grep cattle"
        exit 1
    fi

    env_register_one_clusterrepo "openg2p" "$OPENG2P_REPO_URL" || exit 1
    env_register_one_clusterrepo "openg2p-gitlab" "$OPENG2P_GITLAB_REPO_URL" || exit 1

    log_info "Rancher UI → Apps → Repositories will reflect both within ~30s."
}

# ---------------------------------------------------------------------------
# E5 — create env namespace
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
# E6 — create Rancher Project + move namespace into it
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
# E7 — Istio Gateway for *.<base_domain>
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
                  "Re-run the environment stage once the cluster is stable" \
                  "./openg2p-prod.sh --config <your-config> --stage environment"
        exit 1
    fi
    log_success "Istio Gateway configured for *.${ENV_BASE_DOMAIN}."
}

# ---------------------------------------------------------------------------
# E8 — fetch PG superuser password from storage node, create K8s Secret
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

phase1_show_summary() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║   Environment scaffolding complete                           ║${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Environment:  ${BOLD}${ENV_NAME}${NC}"
    echo -e "${GREEN}║${NC}  Namespace:    ${BOLD}${ENV_NAME}${NC}"
    echo -e "${GREEN}║${NC}  Base domain:  ${BOLD}${ENV_BASE_DOMAIN}${NC}"
    echo -e "${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}Next — install Commons from Rancher UI (required)${NC}"
    echo -e "${GREEN}║${NC}  1. Rancher → Apps → Charts → openg2p-commons-base"
    echo -e "${GREEN}║${NC}  2. Then install openg2p-commons-services (same namespace)"
    echo -e "${GREEN}║${NC}  3. Point PostgreSQL at ${STORAGE_PRIV}"
    echo -e "${GREEN}║${NC}     using secret ${PG_SECRET_NAME}"
    echo -e "${GREEN}║${NC}  4. To pick the Commons version, check the changelog:"
    echo -e "${GREEN}║${NC}     https://openg2p.gitlab.io/versions/commons/CHANGELOG.html"
    echo -e "${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
phase1_main() {
    env_resolve_values

    if [[ "$INSTALL_ENV" != "true" ]]; then
        log_warn "install_environment=false in config — skipping environment phase 1."
        log_warn "Set install_environment: true to enable, or run --stage environment manually."
        return 0
    fi

    log_step "ENV phase 1" "Scaffolding for environment '${ENV_NAME}' (base domain: ${ENV_BASE_DOMAIN})"

    env_preflight_tooling
    env_open_cluster_access
    env_verify_cluster
    env_register_clusterrepo
    env_create_namespace
    env_create_rancher_project
    env_create_istio_gateway
    env_create_pg_secret

    phase1_show_summary
    log_success "ENV phase 1 complete. Namespace + Project + Gateway + PG secret in place."
    ssh_k8s_tunnel_close 2>/dev/null || true
}
