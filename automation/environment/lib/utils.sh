#!/usr/bin/env bash
# =============================================================================
# OpenG2P Environment Setup for Multi-Node Configuration — Utility Library
# =============================================================================
# Shared functions for logging, config parsing, and Kubernetes helpers.
# Sourced by env-cluster.sh — do not run directly.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors and formatting
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_info()    { echo -e "${BLUE}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $(date '+%H:%M:%S') $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_step()    { echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
                echo -e "${BOLD}${CYAN}  STEP $1: $2${NC}"; \
                echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

log_error() {
    echo -e "\n${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ERROR${NC}"
    echo -e "${RED}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║${NC}  ${BOLD}What failed:${NC}    $1"
    echo -e "${RED}║${NC}  ${BOLD}Likely cause:${NC}   $2"
    echo -e "${RED}║${NC}  ${BOLD}What to check:${NC}  $3"
    if [[ -n "${4:-}" ]]; then
        echo -e "${RED}║${NC}  ${BOLD}Try running:${NC}    $4"
    fi
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}\n"
}

log_manual_action() {
    echo -e "\n${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  MANUAL ACTION REQUIRED${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║${NC}  $1"
    if [[ -n "${2:-}" ]]; then
        echo -e "${YELLOW}║${NC}  $2"
    fi
    if [[ -n "${3:-}" ]]; then
        echo -e "${YELLOW}║${NC}  $3"
    fi
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║${NC}  Once done, re-run this script to continue."
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}\n"
}

log_banner() {
    local title="${1:-OpenG2P Environment Setup}"
    local subtitle="${2:-}"
    echo -e "${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║                                                          ║"
    printf "  ║  %-56s  ║\n" "$title"
    printf "  ║  %-56s  ║\n" "$subtitle"
    echo "  ║                                                          ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ---------------------------------------------------------------------------
# Config loading — reads YAML using simple bash parser (no yq dependency)
# ---------------------------------------------------------------------------
declare -A CONFIG

load_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: ${config_file}" \
                  "The file does not exist at the specified path" \
                  "Copy env-config.example.yaml to env-config.yaml and edit it" \
                  "cp env-config.example.yaml env-config.yaml"
        exit 1
    fi

    local current_parent=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        local stripped="${line#"${line%%[![:space:]]*}"}"
        local indent=$(( ${#line} - ${#stripped} ))

        stripped="${stripped%%#*}"
        stripped="${stripped%"${stripped##*[![:space:]]}"}"

        if [[ "$stripped" == *":"* ]]; then
            local key="${stripped%%:*}"
            local value="${stripped#*:}"
            key="${key%"${key##*[![:space:]]}"}"
            key="${key#"${key%%[![:space:]]*}"}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%\"}"
            value="${value#\"}"
            value="${value%\'}"
            value="${value#\'}"

            if [[ -z "$value" ]]; then
                if [[ $indent -eq 0 ]]; then
                    current_parent="$key"
                fi
            else
                if [[ $indent -gt 0 && -n "$current_parent" ]]; then
                    CONFIG["${current_parent}.${key}"]="$value"
                else
                    current_parent=""
                    CONFIG["$key"]="$value"
                fi
            fi
        fi
    done < "$config_file"
}

cfg() {
    local key="$1"
    local default="${2:-}"
    echo "${CONFIG[$key]:-$default}"
}

cfg_bool() {
    local key="$1"
    local val="${CONFIG[$key]:-false}"
    [[ "$val" == "true" || "$val" == "yes" || "$val" == "1" ]]
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
check_command() {
    local cmd="$1"
    local install_hint="${2:-}"
    if ! command -v "$cmd" &>/dev/null; then
        log_error "'${cmd}' is not installed" \
                  "This tool is required but not found in PATH" \
                  "${install_hint:-Install ${cmd} and try again}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Kubernetes helpers
# ---------------------------------------------------------------------------
ensure_kubeconfig() {
    # Multi-node: KUBECONFIG should already be set in the user's environment
    # (e.g., ~/.kube/config or a downloaded file from Rancher/RKE2)
    if [[ -n "${KUBECONFIG:-}" && -f "$KUBECONFIG" ]]; then
        return 0
    fi

    # Check default location
    if [[ -f "${HOME}/.kube/config" ]]; then
        export KUBECONFIG="${HOME}/.kube/config"
        return 0
    fi

    # Check RKE2 location (in case running directly on cluster node)
    if [[ -f /etc/rancher/rke2/rke2.yaml ]]; then
        export KUBECONFIG="/etc/rancher/rke2/rke2.yaml"
        export PATH="$PATH:/var/lib/rancher/rke2/bin"
        return 0
    fi

    log_error "Kubeconfig not found" \
              "No kubeconfig found at KUBECONFIG, ~/.kube/config, or /etc/rancher/rke2/rke2.yaml" \
              "Set KUBECONFIG to point to your cluster kubeconfig file" \
              "export KUBECONFIG=/path/to/kubeconfig.yaml"
    return 1
}

# ---------------------------------------------------------------------------
# Wait helpers
# ---------------------------------------------------------------------------
wait_for_command() {
    local description="$1"
    local command="$2"
    local timeout="${3:-300}"
    local interval="${4:-10}"

    log_info "Waiting for: ${description} (timeout: ${timeout}s)..."
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if eval "$command" &>/dev/null; then
            log_success "${description} — ready."
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        echo -ne "\r  Waiting... ${elapsed}s / ${timeout}s"
    done
    echo ""
    log_error "Timed out waiting for: ${description}" \
              "The operation did not complete within ${timeout} seconds" \
              "Check the service logs for errors" \
              "$command"
    return 1
}
