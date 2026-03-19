#!/usr/bin/env bash
# =============================================================================
# OpenG2P Deployment Automation — Utility Library
# =============================================================================
# Shared functions for logging, error handling, state management, and checks.
# Sourced by openg2p-infra.sh and openg2p-environment.sh — do not run directly.
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
    if [[ -n "${5:-}" ]]; then
        echo -e "${RED}║${NC}  ${BOLD}Docs:${NC}           $5"
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
    local title="${1:-OpenG2P Automated Deployment}"
    local subtitle="${2:-Single-node · Helmfile}"
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
# State management — tracks completed steps for idempotency
# ---------------------------------------------------------------------------
STATE_DIR="/var/lib/openg2p/deploy-state"

init_state_dir() {
    mkdir -p "$STATE_DIR"
}

mark_step_done() {
    local step_id="$1"
    touch "${STATE_DIR}/${step_id}.done"
    log_success "Step '${step_id}' completed and marked."
}

is_step_done() {
    local step_id="$1"
    [[ -f "${STATE_DIR}/${step_id}.done" ]]
}

skip_if_done() {
    local step_id="$1"
    local description="$2"
    if is_step_done "$step_id"; then
        log_info "Skipping '${description}' — already completed. Use --force to re-run."
        return 0
    fi
    return 1
}

reset_state() {
    local prefix="${1:-}"
    if [[ -n "$prefix" ]]; then
        log_warn "Resetting state markers with prefix '${prefix}'..."
        rm -f "${STATE_DIR}/${prefix}"*.done
    else
        log_warn "Resetting all deployment state markers..."
        rm -rf "${STATE_DIR}"
        mkdir -p "${STATE_DIR}"
    fi
    log_success "State reset complete."
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
                  "Make sure you copied the example config and edited it" \
                  "cp *-config.example.yaml config.yaml"
        exit 1
    fi

    local current_parent=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
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
# Config validation — caller provides required keys list
# ---------------------------------------------------------------------------
validate_config() {
    local -a required_keys=("$@")
    log_info "Validating configuration..."
    local errors=0

    for key in "${required_keys[@]}"; do
        if [[ -z "$(cfg "$key")" ]]; then
            log_warn "Missing required config key: '${key}'"
            ((errors++))
        fi
    done

    # Validate IP format if node_ip is present
    local ip=$(cfg "node_ip")
    if [[ -n "$ip" ]] && ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_warn "Invalid IP address format: '${ip}'"
        ((errors++))
    fi

    # Validate email format if letsencrypt_email is present
    local email=$(cfg "letsencrypt_email")
    if [[ -n "$email" ]] && ! [[ "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        log_warn "Invalid email format: '${email}'"
        ((errors++))
    fi

    if [[ $errors -gt 0 ]]; then
        log_error "Configuration validation failed with ${errors} error(s)" \
                  "Required fields are missing or invalid in your config file" \
                  "Review the example config file for required fields and formats"
        exit 1
    fi

    log_success "Configuration validated successfully."
}

# ---------------------------------------------------------------------------
# System prerequisite checks
# ---------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root" \
                  "You are running as user '$(whoami)'" \
                  "Re-run with sudo or switch to root" \
                  "sudo $0 $*"
        exit 1
    fi
}

check_ubuntu_version() {
    log_info "Checking Ubuntu version..."
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS version" \
                  "/etc/os-release not found" \
                  "This script requires Ubuntu 24.04 LTS"
        exit 1
    fi

    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        log_error "Unsupported operating system: ${ID}" \
                  "This script is designed for Ubuntu" \
                  "Install Ubuntu 24.04 LTS on this machine" \
                  "" \
                  "https://ubuntu.com/download/server"
        exit 1
    fi

    if [[ ! "$VERSION_ID" =~ ^24\.04 ]]; then
        log_warn "Ubuntu ${VERSION_ID} detected. This script is tested on 24.04 LTS."
        log_warn "Proceeding, but you may encounter issues."
    else
        log_success "Ubuntu ${VERSION_ID} detected — OK."
    fi
}

check_system_resources() {
    log_info "Checking system resources..."
    local min_cpus=16
    local min_ram_gb=60
    local min_disk_gb=100

    local cpus
    cpus=$(nproc 2>/dev/null || echo 0)
    local ram_kb
    ram_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
    local ram_gb=$(( ram_kb / 1024 / 1024 ))
    local disk_gb
    disk_gb=$(df -BG / 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')

    local warn=0
    if [[ $cpus -lt $min_cpus ]]; then
        log_warn "CPUs: ${cpus} detected, ${min_cpus} recommended."
        ((warn++))
    else
        log_success "CPUs: ${cpus} — OK."
    fi

    if [[ $ram_gb -lt $min_ram_gb ]]; then
        log_warn "RAM: ${ram_gb} GB detected, ${min_ram_gb}+ GB recommended."
        ((warn++))
    else
        log_success "RAM: ${ram_gb} GB — OK."
    fi

    if [[ $disk_gb -lt $min_disk_gb ]]; then
        log_warn "Disk: ${disk_gb} GB free, ${min_disk_gb}+ GB recommended."
        ((warn++))
    else
        log_success "Disk: ${disk_gb} GB free — OK."
    fi

    if [[ $warn -gt 0 ]]; then
        log_warn "System resources are below recommended specs."
        read -rp "Continue anyway? (y/N): " ans
        if [[ ! "$ans" =~ ^[Yy] ]]; then
            log_info "Aborted by user."
            exit 0
        fi
    fi
}

# ---------------------------------------------------------------------------
# DNS verification — accepts a list of "domain:expected_ip" pairs
# ---------------------------------------------------------------------------
check_dns_resolution() {
    local domain="$1"
    local expected_ip="$2"

    log_info "Checking DNS resolution for ${domain}..."

    local resolved_ip
    resolved_ip=$(dig +short "$domain" 2>/dev/null | tail -1)

    if [[ -z "$resolved_ip" ]]; then
        log_error "DNS resolution failed for '${domain}'" \
                  "No DNS A record found for this domain" \
                  "Create an A record pointing '${domain}' to '${expected_ip}' at your DNS provider" \
                  "dig +short ${domain}" \
                  "https://docs.openg2p.org/deployment/resource-requirements#domain-mapping"
        return 1
    fi

    if [[ "$resolved_ip" != "$expected_ip" ]]; then
        log_warn "DNS for '${domain}' resolves to '${resolved_ip}' but expected '${expected_ip}'."
        log_warn "This may be correct if you are using a load balancer or proxy."
    else
        log_success "DNS: ${domain} → ${resolved_ip} — OK."
    fi
    return 0
}

check_dns_for_domains() {
    local expected_ip="$1"
    shift
    local domains=("$@")

    log_info "Verifying DNS records..."
    local dns_ok=true

    for domain in "${domains[@]}"; do
        if ! check_dns_resolution "$domain" "$expected_ip"; then
            dns_ok=false
        fi
    done

    if [[ "$dns_ok" != "true" ]]; then
        log_manual_action \
            "DNS records are not configured correctly." \
            "Create A records for the domains listed above, pointing to ${expected_ip}" \
            "DNS propagation can take minutes to hours."
        exit 1
    fi

    log_success "All DNS records verified."
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

wait_for_pod_ready() {
    local namespace="$1"
    local label="$2"
    local timeout="${3:-300}"

    wait_for_command \
        "Pod with label '${label}' in namespace '${namespace}'" \
        "kubectl -n ${namespace} get pods -l ${label} -o jsonpath='{.items[*].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True" \
        "$timeout"
}

wait_for_deployment() {
    local namespace="$1"
    local deployment="$2"
    local timeout="${3:-300}"

    wait_for_command \
        "Deployment '${deployment}' in namespace '${namespace}'" \
        "kubectl -n ${namespace} rollout status deployment/${deployment} --timeout=5s" \
        "$timeout"
}

# ---------------------------------------------------------------------------
# Tool installation helpers
# ---------------------------------------------------------------------------
install_if_missing() {
    local tool_name="$1"
    local check_command="$2"
    local install_commands="$3"
    local doc_url="${4:-}"

    if eval "$check_command" &>/dev/null; then
        log_success "${tool_name} is already installed."
        return 0
    fi

    log_info "Installing ${tool_name}..."
    if ! eval "$install_commands"; then
        log_error "Failed to install ${tool_name}" \
                  "The install command exited with an error" \
                  "Check your internet connectivity and try again" \
                  "" \
                  "$doc_url"
        return 1
    fi

    if ! eval "$check_command" &>/dev/null; then
        log_error "${tool_name} was installed but verification failed" \
                  "The binary may not be in PATH or may be the wrong version" \
                  "Try running the check command manually" \
                  "$check_command"
        return 1
    fi

    log_success "${tool_name} installed successfully."
}

# ---------------------------------------------------------------------------
# Kubernetes helpers
# ---------------------------------------------------------------------------
ensure_kubeconfig() {
    if [[ -f /etc/rancher/rke2/rke2.yaml ]]; then
        export KUBECONFIG="/etc/rancher/rke2/rke2.yaml"
        export PATH="$PATH:/var/lib/rancher/rke2/bin"
    else
        log_error "Kubeconfig not found at /etc/rancher/rke2/rke2.yaml" \
                  "RKE2 may not be installed or running" \
                  "Run the infrastructure setup first (openg2p-infra.sh)" \
                  "systemctl status rke2-server"
        return 1
    fi
}
