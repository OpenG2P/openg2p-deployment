#!/usr/bin/env bash
# =============================================================================
# OpenG2P Environment Setup for Multi-Node Configuration — Cluster
# =============================================================================
# Run this from your workstation (or any machine with kubectl access) to:
#   1. Create the K8s namespace
#   2. Create a Rancher Project and associate the namespace
#   3. Create the Istio Gateway for *.<base_domain>
#   4. Install openg2p-commons-base (PostgreSQL, Kafka, MinIO, etc.)
#   5. Install openg2p-commons-services (eSignet, Superset, ODK, etc.)
#
# Prerequisites:
#   - kubectl configured with admin access to the cluster
#   - helm installed
#   - Nginx node configured (DNS, TLS cert, server block — see README)
#   - DNS records pointing *.<base_domain> to the Nginx node
#
# Usage:
#   ./env-cluster.sh --config env-config.yaml
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
RUN_STEP=""
FORCE_MODE=false

source "${SCRIPT_DIR}/lib/utils.sh"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)  CONFIG_FILE="$2"; shift 2 ;;
            --step)    RUN_STEP="$2"; shift 2 ;;
            --force)   FORCE_MODE=true; shift ;;
            --help|-h) show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1" \
                          "This flag is not recognized" \
                          "Run with --help to see available options"
                exit 1
                ;;
        esac
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        log_error "No config file specified" \
                  "The --config flag is required" \
                  "Provide the path to your env-config.yaml" \
                  "$0 --config env-config.yaml"
        exit 1
    fi

    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
}

show_help() {
    cat <<'EOF'
OpenG2P Environment Setup for Multi-Node Configuration
==================================================

Usage:
  ./env-cluster.sh --config env-config.yaml [options]

Options:
  --config <file>    Path to environment config file (required)
  --step <N>         Run only a specific step (1-5)
  --force            Re-run all steps (helm will uninstall and reinstall)
  --help             Show this help message

Steps:
  1  Create K8s namespace
  2  Create Rancher Project
  3  Create Istio Gateway
  4  Install openg2p-commons-base
  5  Install openg2p-commons-services

Prerequisites:
  - kubectl access to the cluster (KUBECONFIG set or ~/.kube/config)
  - helm installed
  - Nginx node configured (DNS, TLS cert, server block — see README)
EOF
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
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

clean_uninstall_release() {
    local env_name="$1"
    local release_name="$2"
    local cleanup_level="${3:-light}"

    if ! helm status "$release_name" -n "$env_name" &>/dev/null; then
        return 0
    fi

    log_warn "Stale Helm release '${release_name}' found in '${env_name}'. Uninstalling..."
    helm uninstall "$release_name" -n "$env_name" --wait --timeout 5m || {
        log_warn "helm uninstall returned non-zero. Continuing..."
    }

    # Clean up orphaned hook resources
    log_info "Cleaning up orphaned hook resources for '${release_name}'..."
    kubectl delete jobs -n "$env_name" --all --ignore-not-found > /dev/null 2>&1 || true
    for suffix in postgres-init keycloak-init client-secrets-sync; do
        kubectl delete serviceaccount "${release_name}-${suffix}" -n "$env_name" --ignore-not-found > /dev/null 2>&1 || true
        kubectl delete configmap "${release_name}-${suffix}" -n "$env_name" --ignore-not-found > /dev/null 2>&1 || true
    done
    kubectl delete rolebinding "${release_name}-client-secrets-sync" -n "$env_name" --ignore-not-found > /dev/null 2>&1 || true
    kubectl delete role "${release_name}-client-secrets-sync" -n "$env_name" --ignore-not-found > /dev/null 2>&1 || true

    if [[ "$cleanup_level" == "full" ]]; then
        log_info "Cleaning up ALL secrets and PVCs in '${env_name}'..."
        local pv_names
        pv_names=$(kubectl get pvc -n "$env_name" -o jsonpath='{.items[*].spec.volumeName}' 2>/dev/null || true)
        kubectl delete secrets -n "$env_name" --all --ignore-not-found > /dev/null 2>&1 || true
        kubectl delete pvc -n "$env_name" --all --ignore-not-found > /dev/null 2>&1 || true
        if [[ -n "$pv_names" ]]; then
            sleep 5
            for pv in $pv_names; do
                kubectl delete pv "$pv" --ignore-not-found > /dev/null 2>&1 || true
            done
        fi
    fi

    sleep 3
}

helm_install_chart() {
    local env_name="$1"
    local release_name="$2"
    local chart_ref="$3"
    local chart_version="$4"
    local display_name="$5"
    shift 5

    local -a helm_args=(
        install "$release_name" "$chart_ref"
        -n "$env_name"
        --wait
        --timeout 20m
    )

    if [[ -n "$chart_version" && "$chart_ref" == openg2p/* ]]; then
        helm_args+=(--version "$chart_version")
    fi

    helm_args+=("$@")

    log_info "Running: helm install ${release_name} ..."
    log_info "(this may take 15-20 minutes)"
    echo ""

    if ! helm "${helm_args[@]}"; then
        log_error "Helm install failed for ${display_name}" \
                  "The chart installation did not complete successfully" \
                  "Check pod status and logs" \
                  "kubectl get pods -n ${env_name} --field-selector=status.phase!=Running"
        echo ""
        log_info "Diagnostic info:"
        kubectl get pods -n "$env_name" --field-selector=status.phase!=Running 2>/dev/null || true
        echo ""
        kubectl get jobs -n "$env_name" 2>/dev/null || true
        return 1
    fi

    log_success "${display_name} installed successfully."
}

wait_for_all_ready() {
    local env_name="$1"
    local description="$2"
    local timeout="${3:-900}"
    local interval=15
    local elapsed=0

    log_info "Waiting for ${description} to be fully ready..."

    while [[ $elapsed -lt $timeout ]]; do
        local not_ready
        not_ready=$(kubectl get deployments,statefulsets -n "$env_name" -o json 2>/dev/null | \
            jq -r '.items[] | select((.status.readyReplicas // 0) != (.status.replicas // 1)) | "\(.kind)/\(.metadata.name)"' 2>/dev/null || true)

        if [[ -z "$not_ready" ]]; then
            log_success "All ${description} resources in '${env_name}' are ready."
            return 0
        fi

        echo -ne "\r  Waiting for: $(echo "$not_ready" | tr '\n' ', ')... ${elapsed}s/${timeout}s"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo ""
    log_error "${description} not ready after ${timeout}s" \
              "Some resources did not become ready in time" \
              "Check pod status" \
              "kubectl get pods -n ${env_name} --field-selector=status.phase!=Running"
    return 1
}

# ---------------------------------------------------------------------------
# Step 1: Create K8s namespace
# ---------------------------------------------------------------------------
step1_namespace() {
    local env_name=$(cfg "environment")

    log_step "1" "Creating Kubernetes namespace '${env_name}'"

    if kubectl get namespace "$env_name" &>/dev/null; then
        log_info "Namespace '${env_name}' already exists."
    else
        kubectl create namespace "$env_name" || {
            log_error "Failed to create namespace '${env_name}'" \
                      "kubectl create namespace failed" \
                      "Check cluster connectivity" \
                      "kubectl get nodes"
            return 1
        }
        log_success "Namespace '${env_name}' created."
    fi
}

# ---------------------------------------------------------------------------
# Step 2: Create Rancher Project
# ---------------------------------------------------------------------------
step2_rancher_project() {
    local env_name=$(cfg "environment")

    log_step "2" "Creating Rancher Project for '${env_name}'"

    # Check if a project with this name already exists
    local existing_project
    existing_project=$(kubectl get projects.management.cattle.io -n local \
        -o json 2>/dev/null | \
        jq -r --arg name "$env_name" \
        '.items[] | select(.spec.displayName == $name) | .metadata.name' 2>/dev/null | head -1 || true)

    if [[ -n "$existing_project" ]]; then
        log_info "Rancher Project '${env_name}' already exists (ID: ${existing_project})."
    else
        log_info "Creating Rancher Project '${env_name}'..."
        local project_id
        project_id=$(kubectl create -f - -o jsonpath='{.metadata.name}' <<PROJEOF
apiVersion: management.cattle.io/v3
kind: Project
metadata:
  generateName: p-
  namespace: local
spec:
  displayName: ${env_name}
  clusterName: local
PROJEOF
        ) || {
            log_warn "Failed to create Rancher Project. You can create it manually in Rancher UI."
            return 0
        }
        existing_project="$project_id"
        log_success "Rancher Project '${env_name}' created (ID: ${existing_project})."
    fi

    # Move namespace into the project
    local project_ns_value="local:${existing_project}"
    local current_annotation
    current_annotation=$(kubectl get namespace "$env_name" \
        -o jsonpath='{.metadata.annotations.field\.cattle\.io/projectId}' 2>/dev/null || true)

    if [[ "$current_annotation" == "$project_ns_value" ]]; then
        log_info "Namespace '${env_name}' already in Rancher Project."
    else
        log_info "Moving namespace '${env_name}' into Rancher Project..."
        kubectl annotate namespace "$env_name" \
            "field.cattle.io/projectId=${project_ns_value}" --overwrite > /dev/null 2>&1 || {
            log_warn "Could not annotate namespace. Move it manually in Rancher UI."
        }
        log_success "Namespace '${env_name}' associated with Rancher Project."
    fi
}

# ---------------------------------------------------------------------------
# Step 3: Create Istio Gateway
# ---------------------------------------------------------------------------
step3_istio_gateway() {
    local env_name=$(cfg "environment")
    local base_domain=$(cfg "base_domain")

    log_step "3" "Creating Istio Gateway for '${env_name}'"

    if kubectl -n "$env_name" get gateway internal &>/dev/null; then
        log_info "Istio Gateway 'internal' already exists in namespace '${env_name}'."
    else
        log_info "Creating Istio Gateway for *.${base_domain}..."
        kubectl apply -f - <<GWEOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: internal
  namespace: ${env_name}
spec:
  selector:
    istio: ingressgateway
  servers:
    - hosts:
        - "${base_domain}"
        - "*.${base_domain}"
      port:
        name: http2-redirect-https
        number: 8081
        protocol: HTTP2
      tls:
        httpsRedirect: true
    - hosts:
        - "${base_domain}"
        - "*.${base_domain}"
      port:
        name: http2
        number: 8080
        protocol: HTTP2
GWEOF
    fi

    log_success "Istio Gateway configured for *.${base_domain}."
}

# ---------------------------------------------------------------------------
# Step 4: Install openg2p-commons-base
# ---------------------------------------------------------------------------
step4_commons_base() {
    local env_name=$(cfg "environment")

    if ! cfg_bool "modules.commons"; then
        log_info "openg2p-commons disabled in config — skipping."
        return 0
    fi

    log_step "4" "Installing openg2p-commons-base in '${env_name}'"

    local base_domain=$(cfg "base_domain")
    local chart_name=$(cfg "commons_base.chart_name" "openg2p-commons-base")
    local chart_ref=$(get_chart_ref "commons_base.chart_path" "$chart_name")
    local chart_version=$(cfg "commons_base.chart_version" "2.0.0-develop")
    local release_name="commons"

    ensure_helm_repo || return 1

    # Check if already installed (and not --force)
    if helm status "$release_name" -n "$env_name" &>/dev/null && [[ "$FORCE_MODE" != "true" ]]; then
        log_info "openg2p-commons-base already installed. Use --force to reinstall."
        return 0
    fi

    # Clean uninstall if force mode or stale release
    if [[ "$FORCE_MODE" == "true" ]]; then
        clean_uninstall_release "$env_name" "$release_name" "full"
    fi

    log_info "Chart:    ${chart_ref}"
    log_info "Version:  ${chart_version}"
    log_info "Release:  ${release_name}"
    log_info "Domain:   ${base_domain}"
    echo ""

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
        "${extra[@]}" \
        || return 1

    wait_for_all_ready "$env_name" "base infrastructure" 900
}

# ---------------------------------------------------------------------------
# Step 5: Install openg2p-commons-services
# ---------------------------------------------------------------------------
step5_commons_services() {
    local env_name=$(cfg "environment")

    if ! cfg_bool "modules.commons"; then
        log_info "openg2p-commons disabled in config — skipping."
        return 0
    fi

    log_step "5" "Installing openg2p-commons-services in '${env_name}'"

    local base_domain=$(cfg "base_domain")
    local chart_name=$(cfg "commons_services.chart_name" "openg2p-commons-services")
    local chart_ref=$(get_chart_ref "commons_services.chart_path" "$chart_name")
    local chart_version=$(cfg "commons_services.chart_version" "2.0.0-develop")
    local release_name="commons-services"
    local base_release="commons"

    ensure_helm_repo || return 1

    # Check if already installed (and not --force)
    if helm status "$release_name" -n "$env_name" &>/dev/null && [[ "$FORCE_MODE" != "true" ]]; then
        log_info "openg2p-commons-services already installed. Use --force to reinstall."
        return 0
    fi

    # Verify base chart is installed
    if ! helm status "$base_release" -n "$env_name" &>/dev/null; then
        log_error "openg2p-commons-base not installed" \
                  "The base chart must be installed first (step 4)" \
                  "Run the full setup or --step 4 first" \
                  "helm status ${base_release} -n ${env_name}"
        return 1
    fi

    # Clean uninstall if force mode or stale release
    if [[ "$FORCE_MODE" == "true" ]]; then
        clean_uninstall_release "$env_name" "$release_name" "light"
    fi

    log_info "Chart:        ${chart_ref}"
    log_info "Version:      ${chart_version}"
    log_info "Release:      ${release_name}"
    log_info "Base release: ${base_release}"
    log_info "Domain:       ${base_domain}"
    echo ""

    # Extra helm args from config
    local extra_args=$(cfg "commons_services.extra_helm_args" "")
    local -a extra=()
    if [[ -n "$extra_args" ]]; then
        # shellcheck disable=SC2206
        extra=($extra_args)
    fi

    helm_install_chart "$env_name" "$release_name" "$chart_ref" "$chart_version" \
        "openg2p-commons-services" \
        --set "global.baseDomain=${base_domain}" \
        --set "global.postgresqlHost=${base_release}-postgresql" \
        --set "global.redisInstallationName=${base_release}-redis" \
        --set "global.redisAuthInstallationName=${base_release}-redis-auth" \
        --set "global.minioInstallationName=${base_release}-minio" \
        --set "global.mailInstallationName=${base_release}-mail" \
        --set "global.kafkaInstallationName=${base_release}-kafka" \
        --set "global.softhsmInstallationName=${base_release}-softhsm" \
        "${extra[@]}" \
        || return 1

    wait_for_all_ready "$env_name" "service deployments" 900
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
show_summary() {
    local env_name=$(cfg "environment")
    local base_domain=$(cfg "base_domain")

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║   Environment Setup Complete!                                ║${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Environment:  ${BOLD}${env_name}${NC}"
    echo -e "${GREEN}║${NC}  Namespace:    ${BOLD}${env_name}${NC}"
    echo -e "${GREEN}║${NC}  Base domain:  ${BOLD}${base_domain}${NC}"
    echo -e "${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}Service URLs:${NC}"
    echo -e "${GREEN}║${NC}    MinIO:       https://minio.${base_domain}"
    echo -e "${GREEN}║${NC}    Superset:    https://superset.${base_domain}"
    echo -e "${GREEN}║${NC}    OpenSearch:  https://opensearch.${base_domain}"
    echo -e "${GREEN}║${NC}    Kafka UI:    https://kafka.${base_domain}"
    echo -e "${GREEN}║${NC}    eSignet:     https://esignet.${base_domain}"
    echo -e "${GREEN}║${NC}    ODK Central: https://odk.${base_domain}"
    echo -e "${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}Next steps:${NC}"
    echo -e "${GREEN}║${NC}  1. Assign users in Rancher → Project '${env_name}' → Members"
    echo -e "${GREEN}║${NC}  2. Verify services: curl -s https://minio.${base_domain}"
    echo -e "${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    log_banner "OpenG2P Environment Setup" "Cluster · Namespace + Rancher + Helm"

    load_config "$CONFIG_FILE"

    local env_name=$(cfg "environment")
    local base_domain=$(cfg "base_domain")

    if [[ -z "$env_name" ]]; then
        log_error "No environment name specified" \
                  "The 'environment' key is missing or empty" \
                  "Set environment: dev (or qa, staging, pilot) in your config"
        exit 1
    fi

    if [[ -z "$base_domain" ]]; then
        log_error "No base_domain specified" \
                  "base_domain is required for multi-node setup" \
                  "Set base_domain: qa.openg2p.org in your config"
        exit 1
    fi

    # Verify kubectl access
    ensure_kubeconfig || exit 1
    kubectl cluster-info &>/dev/null || {
        log_error "Cannot connect to Kubernetes cluster" \
                  "kubectl cluster-info failed" \
                  "Check your KUBECONFIG and cluster connectivity" \
                  "kubectl cluster-info"
        exit 1
    }

    # Verify helm is available
    check_command "helm" "Install Helm: https://helm.sh/docs/intro/install/" || exit 1

    log_info "Environment:  ${BOLD}${env_name}${NC}"
    log_info "Base domain:  ${BOLD}${base_domain}${NC}"
    log_info "Config file:  ${CONFIG_FILE}"
    echo ""

    case "${RUN_STEP:-all}" in
        1)  step1_namespace ;;
        2)  step2_rancher_project ;;
        3)  step3_istio_gateway ;;
        4)  step4_commons_base ;;
        5)  step5_commons_services ;;
        all)
            step1_namespace
            step2_rancher_project
            step3_istio_gateway
            step4_commons_base
            step5_commons_services
            show_summary
            ;;
        *)
            log_error "Invalid step: ${RUN_STEP}" \
                      "Valid steps are: 1-5, or omit for all" \
                      "Use --step 1 through --step 5"
            exit 1
            ;;
    esac

    if [[ "${RUN_STEP:-all}" == "all" ]]; then
        log_success "Environment '${env_name}' setup completed successfully!"
    fi
}

main "$@"
