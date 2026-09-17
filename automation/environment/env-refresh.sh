#!/usr/bin/env bash
# =============================================================================
# OpenG2P Environment Refresh — one-shot "reinstall this environment fresh"
# =============================================================================
# Wraps the full fresh-install procedure into a single command:
#
#   0. Confirm the target namespace (and that env-config.yaml agrees with it)
#   1. Uninstall everything in the namespace  (env-cluster-uninstall.sh, no --full)
#   2. Resolve the latest commons chart version and confirm it with you
#   3. Write that version into env-config.yaml (both base + services)
#   4. Install                                (env-cluster.sh)
#   5. Verify releases / pods / jobs and report
#
# The namespace, Istio Gateway and Rancher Project are intentionally preserved
# (step 1 never passes --full), so the reinstall is fast.
#
# Usage:
#   ./env-refresh.sh --namespace trial
#   ./env-refresh.sh --namespace trial --version 0.0.0-develop.194
#   ./env-refresh.sh --namespace trial --yes          # unattended
#   ./env-refresh.sh --namespace trial --dry-run      # show plan only
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE=""
CONFIG_FILE="${SCRIPT_DIR}/env-config.yaml"
VERSION=""
SKIP_CONFIRM=false
DRY_RUN=false

CHANGELOG_URL="https://openg2p.gitlab.io/versions/commons/CHANGELOG.html"

source "${SCRIPT_DIR}/lib/utils.sh"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --namespace) NAMESPACE="$2"; shift 2 ;;
            --config)    CONFIG_FILE="$2"; shift 2 ;;
            --version)   VERSION="$2"; shift 2 ;;
            --yes)       SKIP_CONFIRM=true; shift ;;
            --dry-run)   DRY_RUN=true; shift ;;
            --help|-h)   show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1" \
                          "This flag is not recognized" \
                          "Run with --help to see available options"
                exit 1
                ;;
        esac
    done

    if [[ -z "$NAMESPACE" ]]; then
        log_error "No namespace specified" \
                  "The --namespace flag is required" \
                  "Name the environment you want rebuilt" \
                  "$0 --namespace trial"
        exit 1
    fi

    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
}

show_help() {
    cat <<'EOF'
OpenG2P Environment Refresh
===========================

Rebuilds an environment from scratch in one command: uninstall, bump the
commons chart version to the latest published build, reinstall, verify.

Usage:
  ./env-refresh.sh --namespace <name> [options]

Options:
  --namespace <name>   Environment / namespace to rebuild (required)
  --config <file>      Env config file (default: env-config.yaml)
  --version <ver>      Use this chart version instead of prompting for latest
  --yes                Skip all confirmation prompts (unattended / CI)
  --dry-run            Print the plan and exit without changing anything
  --help               Show this help message

What it does:
  1. Uninstalls all Helm releases, secrets and PVCs in the namespace
     (via env-cluster-uninstall.sh — never with --full, so the namespace,
     Istio Gateway and Rancher Project survive)
  2. Resolves the latest commons version from the published CHANGELOG and
     asks you to confirm it
  3. Writes that version into both commons_base and commons_services
  4. Runs env-cluster.sh to install
  5. Verifies releases are deployed, pods Running, Jobs Complete

DESTRUCTIVE: step 1 deletes all PVCs in the namespace. That is real data
loss (Postgres, MinIO, Kafka). You are shown exactly what will go and asked
to confirm before anything happens.
EOF
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
run_or_echo() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${BLUE}[DRY-RUN]${NC} $*"
        return 0
    fi
    eval "$@"
}

# Resolves the newest version from the published CHANGELOG page.
# The page is HTML; strip tags and take the first version-looking token,
# which is the most recently published build.
fetch_latest_version() {
    curl -sL --max-time 25 "$CHANGELOG_URL" 2>/dev/null \
        | sed -e 's/<[^>]*>//g' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-(develop|rc)\.[0-9]+)?' \
        | head -1
}

# Lists the next few versions, for the "pick another" prompt.
fetch_recent_versions() {
    curl -sL --max-time 25 "$CHANGELOG_URL" 2>/dev/null \
        | sed -e 's/<[^>]*>//g' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-(develop|rc)\.[0-9]+)?' \
        | head -8
}

# Helm repo for the commons charts. Must match what env-cluster.sh uses —
# same GitHub Rancher index as production / Rancher Apps UI.
commons_repo_alias() {
    cfg "commons_base.chart_repo_alias" "openg2p"
}

commons_repo_url() {
    cfg "commons_base.chart_repo" \
        "https://openg2p.github.io/openg2p-helm/rancher"
}

# Confirms a version actually exists in the Helm repo for BOTH charts.
# Pre-release versions are hidden unless --devel is passed.
version_exists_in_repo() {
    local ver="$1"
    local alias
    alias=$(commons_repo_alias)
    local chart found
    for chart in openg2p-commons-base openg2p-commons-services; do
        found=$(helm search repo "${alias}/${chart}" --versions --devel 2>/dev/null \
                | awk -v v="$ver" '$2 == v {print $2; exit}')
        [[ -z "$found" ]] && return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# Step 0: validate namespace against the config
# ---------------------------------------------------------------------------
# Guard against the worst failure mode: uninstalling namespace A while
# env-config.yaml would then install into namespace B.
validate_namespace_matches_config() {
    load_config "$CONFIG_FILE"

    local cfg_env
    cfg_env=$(cfg "environment")

    if [[ -z "$cfg_env" ]]; then
        log_error "No 'environment' key in ${CONFIG_FILE##*/}" \
                  "The config must name the environment it installs" \
                  "Set environment: ${NAMESPACE} in the config"
        exit 1
    fi

    if [[ "$cfg_env" != "$NAMESPACE" ]]; then
        log_error "Namespace mismatch: --namespace '${NAMESPACE}' vs config 'environment: ${cfg_env}'" \
                  "This would uninstall '${NAMESPACE}' but install into '${cfg_env}'" \
                  "Point --namespace at '${cfg_env}', or edit the config (and its base_domain) to match" \
                  "grep -n 'environment:\\|base_domain:' ${CONFIG_FILE}"
        exit 1
    fi

    log_success "Config '${CONFIG_FILE##*/}' targets namespace '${NAMESPACE}'."
}

# ---------------------------------------------------------------------------
# Step 0b: show what will be destroyed, then confirm
# ---------------------------------------------------------------------------
confirm_destruction() {
    local base_domain
    base_domain=$(cfg "base_domain")

    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  FRESH INSTALL — the following WILL be destroyed             ║${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║${NC}  Namespace:   ${BOLD}${NAMESPACE}${NC}"
    echo -e "${YELLOW}║${NC}  Base domain: ${BOLD}${base_domain}${NC}"
    echo -e "${YELLOW}║${NC}"

    echo -e "${YELLOW}║${NC}  ${BOLD}Helm releases${NC}:"
    local releases
    releases=$(helm list -n "$NAMESPACE" -q 2>/dev/null || true)
    if [[ -n "$releases" ]]; then
        while IFS= read -r r; do
            [[ -n "$r" ]] && echo -e "${YELLOW}║${NC}    - ${r}"
        done <<< "$releases"
    else
        echo -e "${YELLOW}║${NC}    (none)"
    fi

    echo -e "${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}  ${BOLD}PVCs — THIS IS REAL DATA LOSS${NC}:"
    local pvcs
    pvcs=$(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $1"  ("$4")"}' || true)
    if [[ -n "$pvcs" ]]; then
        while IFS= read -r p; do
            [[ -n "$p" ]] && echo -e "${YELLOW}║${NC}    - ${p}"
        done <<< "$pvcs"
    else
        echo -e "${YELLOW}║${NC}    (none)"
    fi

    echo -e "${YELLOW}║${NC}"
    printf "${YELLOW}║${NC}  Also: %s pods, %s secrets, %s jobs\n" \
        "$(kubectl get pods    -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')" \
        "$(kubectl get secrets -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')" \
        "$(kubectl get jobs    -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')"

    echo -e "${YELLOW}║${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║${NC}  ${BOLD}PRESERVED${NC} (--full is never used):"
    echo -e "${YELLOW}║${NC}    - namespace/${NAMESPACE}"
    echo -e "${YELLOW}║${NC}    - Istio Gateway(s) created by env-cluster.sh"
    echo -e "${YELLOW}║${NC}    - Rancher Project"
    echo -e "${YELLOW}║${NC}    - Nginx config, TLS certs, DNS records"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    [[ "$DRY_RUN" == "true" ]] && return 0
    if [[ "$SKIP_CONFIRM" == "true" ]]; then
        log_warn "Skipping destruction confirmation (--yes)."
        return 0
    fi

    echo -e "${RED}${BOLD}This permanently deletes the data listed above.${NC}"
    echo -n "To confirm, type the namespace name '${NAMESPACE}': "
    read -r reply
    if [[ "$reply" != "$NAMESPACE" ]]; then
        log_error "Confirmation failed" \
                  "Expected '${NAMESPACE}', got '${reply}'" \
                  "Aborting — nothing has been changed"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Step 0c: resolve + confirm the chart version
# ---------------------------------------------------------------------------
resolve_version() {
    local current
    current=$(cfg "commons_base.chart_version")

    # Explicit --version wins; no prompt.
    if [[ -n "$VERSION" ]]; then
        log_info "Using version from --version: ${BOLD}${VERSION}${NC}"
        return 0
    fi

    log_info "Fetching latest commons version from the published CHANGELOG..."
    local latest
    latest=$(fetch_latest_version || true)

    if [[ -z "$latest" ]]; then
        log_warn "Could not read the CHANGELOG at ${CHANGELOG_URL}"
        log_warn "Falling back to the version already in the config: ${current}"
        VERSION="$current"
        return 0
    fi

    echo ""
    echo -e "  Currently configured : ${BOLD}${current}${NC}"
    echo -e "  Latest published     : ${BOLD}${GREEN}${latest}${NC}"
    echo ""

    if [[ "$SKIP_CONFIRM" == "true" || "$DRY_RUN" == "true" ]]; then
        VERSION="$latest"
        log_info "Using latest: ${VERSION}"
        return 0
    fi

    echo "  Recent published versions:"
    fetch_recent_versions | sed 's/^/    /'
    echo ""
    echo -n "Use ${latest}? [Y = yes / n = keep ${current} / or type a version]: "
    read -r reply

    case "$reply" in
        ""|y|Y|yes|YES) VERSION="$latest" ;;
        n|N|no|NO)      VERSION="$current" ;;
        *)              VERSION="$reply" ;;
    esac

    log_info "Selected version: ${BOLD}${VERSION}${NC}"
}

verify_version_available() {
    local alias url
    alias=$(commons_repo_alias)
    url=$(commons_repo_url)

    log_info "Checking that ${VERSION} exists in ${url} for both charts..."

    # Ensure the alias exists and points at the configured repo before we
    # search it — otherwise we'd be validating against a stale/other repo.
    helm repo add "$alias" "$url" --force-update >/dev/null 2>&1 || true
    helm repo update "$alias" >/dev/null 2>&1 || true

    if version_exists_in_repo "$VERSION"; then
        log_success "Version ${VERSION} is available for both commons charts."
        return 0
    fi

    log_warn "Could not find ${VERSION} for both charts in the 'openg2p' Helm repo."
    log_warn "The repo index may be stale, or that build may not be published yet."

    [[ "$DRY_RUN" == "true" ]] && return 0
    if [[ "$SKIP_CONFIRM" == "true" ]]; then
        log_warn "Continuing anyway (--yes)."
        return 0
    fi

    echo -n "Continue anyway? [y/N]: "
    read -r reply
    case "$reply" in
        y|Y|yes|YES) return 0 ;;
        *)
            log_error "Aborted before making any changes" \
                      "Version ${VERSION} was not found in the repo" \
                      "Pick a published version and re-run" \
                      "helm search repo $(commons_repo_alias)/openg2p-commons-base --versions --devel | head"
            exit 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Step 1: uninstall
# ---------------------------------------------------------------------------
do_uninstall() {
    log_step "1" "Uninstalling everything in namespace '${NAMESPACE}'"

    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        log_info "Namespace '${NAMESPACE}' does not exist — nothing to uninstall."
        log_info "env-cluster.sh will create it during the install."
        return 0
    fi

    # --yes because this wrapper already took an explicit confirmation.
    # Deliberately NOT --full: namespace / Gateway / Rancher Project survive.
    run_or_echo "'${SCRIPT_DIR}/env-cluster-uninstall.sh' --namespace '${NAMESPACE}' --yes" || {
        log_error "Uninstall failed for namespace '${NAMESPACE}'" \
                  "env-cluster-uninstall.sh returned non-zero" \
                  "Inspect what is left behind before retrying" \
                  "kubectl get all,pvc -n ${NAMESPACE}"
        exit 1
    }

    log_success "Namespace '${NAMESPACE}' cleared."
}

# ---------------------------------------------------------------------------
# Step 2: write the version into the config
# ---------------------------------------------------------------------------
update_config_version() {
    log_step "2" "Setting commons chart version to ${VERSION}"

    local current
    current=$(cfg "commons_base.chart_version")

    if [[ "$current" == "$VERSION" ]]; then
        log_info "Config already pinned to ${VERSION} — no change needed."
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${BLUE}[DRY-RUN]${NC} would set chart_version: \"${VERSION}\" (commons_base + commons_services) in ${CONFIG_FILE}"
        return 0
    fi

    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

    # Rewrite only the chart_version lines; -i.tmp keeps this portable
    # between GNU sed and BSD/macOS sed.
    sed -i.tmp -E "s|^([[:space:]]*chart_version:[[:space:]]*).*|\1\"${VERSION}\"|" "$CONFIG_FILE"
    rm -f "${CONFIG_FILE}.tmp"

    local changed
    changed=$(grep -c "chart_version: \"${VERSION}\"" "$CONFIG_FILE" || true)
    if [[ "$changed" -lt 2 ]]; then
        log_error "Failed to update chart_version in ${CONFIG_FILE##*/}" \
                  "Expected 2 updated lines (base + services), found ${changed}" \
                  "Restore the backup and edit by hand" \
                  "mv ${CONFIG_FILE}.bak ${CONFIG_FILE}"
        exit 1
    fi

    log_success "chart_version set to ${VERSION} in both charts (backup: ${CONFIG_FILE##*/}.bak)."
}

# ---------------------------------------------------------------------------
# Step 3: install
# ---------------------------------------------------------------------------
do_install() {
    log_step "3" "Installing environment '${NAMESPACE}'"

    # No --force (that would wipe PVCs again) and no --step (run all steps).
    run_or_echo "'${SCRIPT_DIR}/env-cluster.sh' --config '${CONFIG_FILE}'" || {
        log_error "Install failed for namespace '${NAMESPACE}'" \
                  "env-cluster.sh returned non-zero" \
                  "Check pods and Helm release status" \
                  "kubectl get pods -n ${NAMESPACE} | grep -v Running"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Step 4: verify
# ---------------------------------------------------------------------------
verify_install() {
    log_step "4" "Verifying environment '${NAMESPACE}'"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${BLUE}[DRY-RUN]${NC} would verify releases / pods / jobs"
        return 0
    fi

    local problems=0

    echo ""
    log_info "Helm releases:"
    helm list -n "$NAMESPACE" 2>/dev/null | sed 's/^/    /'

    local bad_releases
    bad_releases=$(helm list -n "$NAMESPACE" -o json 2>/dev/null \
        | jq -r '.[] | select(.status != "deployed") | "\(.name) (\(.status))"' 2>/dev/null || true)
    if [[ -n "$bad_releases" ]]; then
        log_warn "Releases not in 'deployed' state:"
        echo "$bad_releases" | sed 's/^/    - /'
        problems=$((problems + 1))
    else
        log_success "All Helm releases are 'deployed'."
    fi

    local bad_pods
    bad_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null \
        | grep -vE 'Running|Completed' || true)
    if [[ -n "$bad_pods" ]]; then
        log_warn "Pods not Running/Completed:"
        echo "$bad_pods" | sed 's/^/    /'
        problems=$((problems + 1))
    else
        log_success "All pods are Running or Completed."
    fi

    local bad_jobs
    bad_jobs=$(kubectl get jobs -n "$NAMESPACE" -o json 2>/dev/null \
        | jq -r '.items[] | select((.status.succeeded // 0) < (.spec.completions // 1)) | .metadata.name' 2>/dev/null || true)
    if [[ -n "$bad_jobs" ]]; then
        log_warn "Jobs not complete:"
        echo "$bad_jobs" | sed 's/^/    - /'
        problems=$((problems + 1))
    else
        log_success "All Jobs are complete."
    fi

    echo ""
    if [[ $problems -gt 0 ]]; then
        log_error "Environment '${NAMESPACE}' came up with ${problems} problem area(s)" \
                  "See the warnings above for what is unhealthy" \
                  "Inspect the failing resources" \
                  "kubectl get pods,jobs -n ${NAMESPACE}"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    log_banner "OpenG2P Environment Refresh" "Uninstall · Bump version · Install · Verify"

    ensure_kubeconfig || exit 1
    kubectl cluster-info &>/dev/null || {
        log_error "Cannot connect to Kubernetes cluster" \
                  "kubectl cluster-info failed" \
                  "Check your KUBECONFIG and cluster connectivity" \
                  "kubectl cluster-info"
        exit 1
    }
    check_command "helm" "Install Helm: https://helm.sh/docs/intro/install/" || exit 1
    check_command "jq"   "Install jq: brew install jq" || exit 1

    [[ "$DRY_RUN" == "true" ]] && log_warn "DRY RUN — nothing will be changed."

    log_info "Namespace:   ${BOLD}${NAMESPACE}${NC}"
    log_info "Config file: ${CONFIG_FILE}"

    # Step 0 — safety gates, all before anything is touched
    validate_namespace_matches_config
    confirm_destruction
    resolve_version
    verify_version_available

    # Steps 1-4 — the actual work
    do_uninstall
    update_config_version
    do_install || exit 1
    verify_install || exit 1

    local base_domain
    base_domain=$(cfg "base_domain")

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   Environment refreshed successfully                         ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Namespace:   ${BOLD}${NAMESPACE}${NC}"
    echo -e "${GREEN}║${NC}  Version:     ${BOLD}${VERSION}${NC}"
    echo -e "${GREEN}║${NC}  Base domain: ${BOLD}${base_domain}${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

main "$@"
