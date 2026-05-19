#!/usr/bin/env bash
# =============================================================================
# OpenG2P Backup Automation — Utility Library
# =============================================================================
# Sourced by openg2p-backup.sh on the admin's laptop and by role scripts on
# remote nodes. Inherits logging, state markers, and config parsing from the
# production lib (../../production/lib/shared/utils.sh) — adds backup-specific
# helpers on top.
# =============================================================================

set -euo pipefail

BACKUPS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUPS_ROOT_DIR="$(cd "${BACKUPS_LIB_DIR}/.." && pwd)"
PROD_SHARED_LIB="${BACKUPS_ROOT_DIR}/../production/lib/shared/utils.sh"
PROD_SSH_LIB="${BACKUPS_ROOT_DIR}/../production/lib/ssh-utils.sh"

if [[ ! -f "$PROD_SHARED_LIB" ]]; then
    echo "[FATAL] Production shared lib not found at ${PROD_SHARED_LIB}" >&2
    echo "[FATAL] backup automation reuses the production utilities — make" >&2
    echo "[FATAL] sure the 'production/' tree is present alongside 'backups/'." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$PROD_SHARED_LIB"
# shellcheck source=/dev/null
[[ -f "$PROD_SSH_LIB" ]] && source "$PROD_SSH_LIB"

# Override STATE_DIR — backup orchestrator state lives next to its scripts.
STATE_DIR="${BACKUPS_ROOT_DIR}/.state"

# ---------------------------------------------------------------------------
# Group toggles
# ---------------------------------------------------------------------------
# Returns 0 if backup group <name> is enabled in config, 1 otherwise.
# Used by every subcommand to skip disabled components cleanly.
group_enabled() {
    local group="$1"
    local val="$(cfg "groups.${group}" "true")"
    [[ "$val" == "true" || "$val" == "yes" || "$val" == "1" ]]
}

# Iterate over enabled groups. Usage: for g in $(enabled_groups); do ... done
enabled_groups() {
    local g
    for g in pg etcd rancher nfs configs; do
        group_enabled "$g" && echo "$g"
    done
}

# Pretty-print group state for `status` subcommand.
group_state_str() {
    local g="$1"
    if group_enabled "$g"; then echo "enabled"; else echo "disabled"; fi
}

# ---------------------------------------------------------------------------
# Status file — read/write the per-component last-run + drill state.
# Lives at ${backup_repo_root}/.status.json on the backup host.
# Written by run/drill subcommands, read by the `status` subcommand.
# ---------------------------------------------------------------------------
# Schema:
#   {
#     "components": {
#       "pg":      { "last_run": "2026-04-27T02:00:00Z", "last_run_result": "ok",
#                    "last_drill": "2026-04-26T05:00:00Z", "last_drill_result": "ok",
#                    "details": "..." },
#       ...
#     }
#   }
#
# We keep this as plain JSON (jq required on the backup host) rather than
# inventing our own format — a Phase 2 alerting layer can scrape it directly.
# ---------------------------------------------------------------------------
STATUS_FILE_REMOTE_DEFAULT="/var/lib/openg2p-backup/.status.json"

# ---------------------------------------------------------------------------
# Passphrase / keystore handling
# ---------------------------------------------------------------------------
# Resolves a passphrase file path from config (with ~ expansion). If the
# file is empty or missing AND we're at install time, generates a random
# passphrase and writes it back. The orchestrator then ships the file to
# the backup host at install/<group>.pass.
ensure_passphrase_file() {
    local key="$1"               # config key, e.g. "restic_passphrase_file"
    local label="$2"             # human-readable label for prompts
    local generate="${3:-true}"  # generate if missing?

    local path
    path="$(cfg "$key")"
    if [[ -z "$path" ]]; then
        log_error "Config key '${key}' is empty" \
                  "Every backup group needs a passphrase file in your keystore" \
                  "Set '${key}' to a path under your p12 keystore directory" \
                  "" \
                  "operations/deployment/automation/backups/configuration.md"
        return 1
    fi
    path="${path/#\~/$HOME}"

    if [[ -f "$path" ]] && [[ -s "$path" ]]; then
        log_success "${label} passphrase: present at ${path}"
        echo "$path"
        return 0
    fi

    if [[ "$generate" != "true" ]]; then
        log_error "${label} passphrase file missing: ${path}" \
                  "The file does not exist or is empty" \
                  "Place the passphrase (single line) at ${path} mode 0600" \
                  "ls -l ${path}"
        return 1
    fi

    log_warn "${label} passphrase missing — generating a random 32-byte passphrase at ${path}"
    log_warn "MOVE THIS FILE INTO YOUR P12 KEYSTORE AFTER INSTALL — it is not committed."

    mkdir -p "$(dirname "$path")"
    head -c 32 /dev/urandom | base64 | tr -d '\n=' | head -c 40 > "$path"
    chmod 0600 "$path"
    echo "$path"
}

# ---------------------------------------------------------------------------
# Execution-locality helper
# ---------------------------------------------------------------------------
# True when we're running ON the backup host itself. The cron wrappers
# (/usr/local/bin/openg2p-backup-{run,drill}) export OPENG2P_ON_BACKUP_HOST=1
# before sourcing the libs. The orchestrator (laptop) does NOT set it.
#
# Why this matters: every lib function used to do `ssh_run "backup" "<cmd>"`
# unconditionally. When the orchestrator drives from the laptop, that's
# correct. When cron on the backup host invokes the same function via the
# wrapper, ssh-to-self fails (no SSH trust set up for backup→backup). Use
# run_on_backup instead.
on_backup_host() {
    [[ "${OPENG2P_ON_BACKUP_HOST:-}" == "1" ]]
}

# run_on_backup <cmd...> — execute <cmd> on the backup host.
# Local exec under sudo when we're on the backup host; SSH otherwise.
# The command can include heredocs / pipes / quotes — same semantics as
# ssh_run "backup".
run_on_backup() {
    if on_backup_host; then
        # Local exec — use sudo -E so the cron user's env (incl. our
        # OPENG2P_ON_BACKUP_HOST marker) reaches the sub-shell.
        sudo -E bash -lc "$*"
    else
        ssh_run "backup" "$@"
    fi
}

# ---------------------------------------------------------------------------
# SSH role resolution — extends the production ssh_resolve_role with 'backup'
# ---------------------------------------------------------------------------
# Production's ssh_resolve_role only knows rp/compute/storage. We override it
# here in a way that delegates back for those three (they read from the
# linked prod-config) and adds the new 'backup' role from backup-config.
#
# Implementation: redefine ssh_resolve_role to dispatch on role, falling
# through to a saved copy of the original for non-backup roles.

if declare -f ssh_resolve_role > /dev/null; then
    eval "$(echo "_prod_ssh_resolve_role()"; declare -f ssh_resolve_role | tail -n +2)"

    ssh_resolve_role() {
        local role="$1"
        if [[ "$role" == "backup" ]]; then
            local user host key
            user=$(cfg "backup_ssh_user" "ubuntu")
            host=$(cfg "backup_ssh_host")
            if [[ -z "$host" ]]; then host=$(cfg "backup_private_ip"); fi
            key=$(cfg "backup_ssh_key" "~/.ssh/id_rsa")
            if [[ -z "$host" ]]; then
                log_error "No SSH host resolved for role 'backup'" \
                          "backup_ssh_host and backup_private_ip both blank in backup-config.yaml" \
                          "Either run aws-provision with backup_node.enabled=true, or fill them in"
                return 1
            fi
            key="${key/#\~/$HOME}"
            echo "${user}|${host}|${key}"
        else
            _prod_ssh_resolve_role "$role"
        fi
    }
fi

# ---------------------------------------------------------------------------
# Cluster facts — read prod-config for IPs/SSH details of RP/compute/storage.
# ---------------------------------------------------------------------------
# The backup orchestrator's own config references prod_config: <path>. This
# helper merges that file into CONFIG so role resolution works for all 4
# roles with one CONFIG map.
load_cluster_config() {
    local prod_path
    prod_path="$(cfg "prod_config")"
    if [[ -z "$prod_path" ]]; then
        log_error "Backup config missing 'prod_config' key" \
                  "Cannot reach the cluster being backed up without it" \
                  "Set prod_config: <path> in backup-config.yaml"
        exit 1
    fi
    [[ "$prod_path" = /* ]] || prod_path="${BACKUPS_ROOT_DIR}/${prod_path}"
    if [[ ! -f "$prod_path" ]]; then
        log_error "prod_config not found: ${prod_path}" \
                  "The 3-node cluster's config file is missing" \
                  "Check the prod_config path in backup-config.yaml" \
                  "ls ${prod_path}"
        exit 1
    fi

    # Layer prod-config keys into the same CONFIG map. backup-config.yaml is
    # already loaded; load_config appends, last writer wins. We want backup-
    # config keys to win, so we save+restore them.
    log_info "Loading cluster config from ${prod_path}"

    local saved_keys=()
    local k
    for k in "${!CONFIG[@]}"; do
        saved_keys+=("${k}=${CONFIG[$k]}")
    done

    load_config "$prod_path"

    for entry in "${saved_keys[@]}"; do
        local key="${entry%%=*}"
        local val="${entry#*=}"
        CONFIG["$key"]="$val"
    done

    # Auto-detect provision-output.yaml next to prod-config.yaml — same
    # convention the production orchestrator uses.
    local provision_output="$(dirname "$prod_path")/provision-output.yaml"
    if [[ -f "$provision_output" ]]; then
        log_info "Loading provision output from ${provision_output}"
        load_config "$provision_output"
    fi
}

# ---------------------------------------------------------------------------
# Backup-host preflight (CPU/RAM hard, disk warn-and-continue)
# ---------------------------------------------------------------------------
# Run remotely via ssh_run "backup" — emits one-line PASS/FAIL/WARN per check,
# returns non-zero on any FAIL. The orchestrator surfaces the output verbatim.
#
# Requirements (operations/deployment/automation/backups/prerequisites.md):
#   • Ubuntu 24.04
#   • 4 vCPU, 8 GB RAM             — hard
#   • 64 GB root disk              — hard
#   • 1 TB recommended on backup_repo_root data volume — warn-only
#   • SSH outbound to RP/compute/storage works (caller's responsibility)
# ---------------------------------------------------------------------------
backup_host_preflight() {
    local repo_root="${1:-/var/lib/openg2p-backup}"

    local failures=0
    log_step "0" "Backup host preflight"

    # OS
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS" "/etc/os-release missing" "Install Ubuntu 24.04"
        return 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        log_error "Unsupported OS: ${PRETTY_NAME:-$ID}" \
                  "Backup automation requires Ubuntu 24.04" \
                  "Reinstall with Ubuntu 24.04 LTS"
        failures=$((failures + 1))
    else
        log_success "OS: ${PRETTY_NAME}"
    fi

    # CPU — HARD
    local cpus; cpus=$(nproc 2>/dev/null || echo 0)
    if (( cpus < 4 )); then
        log_error "Insufficient CPU: ${cpus} vCPU (4 required)" \
                  "Backup host runs pgBackRest + restic in parallel" \
                  "Resize VM to >= 4 vCPU"
        failures=$((failures + 1))
    else
        log_success "CPU: ${cpus} vCPU — OK"
    fi

    # RAM — HARD
    local ram_kb; ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local ram_gb=$(( ram_kb / 1024 / 1024 ))
    if (( ram_gb < 7 )); then        # allow 1 GB hypervisor variance off 8
        log_error "Insufficient RAM: ${ram_gb} GB (8 required)" \
                  "restic dedup + pgBackRest parallelism need headroom" \
                  "Resize VM to >= 8 GB RAM"
        failures=$((failures + 1))
    else
        log_success "RAM: ${ram_gb} GB — OK"
    fi

    # Root disk — HARD
    local root_gb; root_gb=$(df -BG / 2>/dev/null | tail -1 | awk '{print $2}' | tr -d 'G')
    if (( root_gb < 60 )); then
        log_error "Insufficient root disk: ${root_gb} GB (64 required)" \
                  "Need room for OS + tooling + logs" \
                  "Resize root volume to >= 64 GB"
        failures=$((failures + 1))
    else
        log_success "Root disk: ${root_gb} GB — OK"
    fi

    # Repo data volume — WARN-ONLY (per design)
    local repo_target="$repo_root"
    local repo_total_gb=0 repo_free_gb=0
    if [[ -d "$repo_target" ]] || mkdir -p "$repo_target" 2>/dev/null; then
        repo_total_gb=$(df -BG "$repo_target" 2>/dev/null | tail -1 | awk '{print $2}' | tr -d 'G' || echo 0)
        repo_free_gb=$(df -BG "$repo_target" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G' || echo 0)
    fi
    if (( repo_total_gb < 1000 )); then
        log_warn "Repo volume at ${repo_target}: ${repo_total_gb} GB total — recommended >= 1 TB"
        log_warn "Smaller volume = shorter retention. With current 6-month default,"
        log_warn "expect repo to fill before retention prunes. Proceeding anyway."
    else
        log_success "Repo volume: ${repo_total_gb} GB total, ${repo_free_gb} GB free — OK"
    fi

    # Required tools (apt installs them later; here we just report)
    local missing=()
    for t in ssh rsync curl jq; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if (( ${#missing[@]} > 0 )); then
        log_info "Missing pre-deps (will be apt-installed): ${missing[*]}"
    fi

    if (( failures > 0 )); then
        log_error "${failures} preflight check(s) FAILED" \
                  "Backup host does not meet hard minimums" \
                  "Fix the above and re-run"
        return 1
    fi
    log_success "Backup host preflight passed."
    return 0
}

# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------
# Returns absolute path to a file, expanding ~ and resolving relative-to
# the backups/ directory.
resolve_backup_path() {
    local p="$1"
    p="${p/#\~/$HOME}"
    [[ "$p" = /* ]] || p="${BACKUPS_ROOT_DIR}/${p}"
    echo "$p"
}

# JSON-escape a string for embedding in status-file writes.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    echo "$s"
}

# UTC timestamp in ISO-8601 — used everywhere we write to the status file.
ts_utc() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# ---------------------------------------------------------------------------
# Status file writer — shared by every group module.
# ---------------------------------------------------------------------------
# Lives here (not in pgbackrest.sh) so that cron-driven runs that source
# only ONE group lib can still write status. The status file is the Phase 2
# alerting layer's input — see operations/deployment/automation/backups/
# alerting.md.
#
# Args: <component> <event=last_run|last_drill> <ts> <result=ok|fail> <details>
_status_write_component() {
    local component="$1" event="$2" ts="$3" result="$4" details="$5"
    local file="/var/lib/openg2p-backup/.status.json"
    local d_esc; d_esc="$(json_escape "$details")"
    run_on_backup "set -euo pipefail
        f='${file}'
        [[ -f \$f ]] || echo '{\"components\":{}}' > \$f
        tmp=\$(mktemp)
        jq --arg c '${component}' \
           --arg ev '${event}' \
           --arg ts '${ts}' \
           --arg r '${result}' \
           --arg d '${d_esc}' \
           '.components[\$c] = (.components[\$c] // {}) +
            { (\$ev): \$ts, (\$ev + \"_result\"): \$r, (\$ev + \"_details\"): \$d }' \
           \$f > \$tmp && mv \$tmp \$f"
}

# ---------------------------------------------------------------------------
# Module dispatch — sources the lib file for a group.
# ---------------------------------------------------------------------------
# Lives in utils.sh (not openg2p-backup.sh) so that drills_run_all can call
# it from either the laptop orchestrator OR the backup-host cron wrapper.
# BACKUPS_LIB_DIR is set in utils.sh's preamble and resolves correctly in
# both contexts.
load_group_module() {
    local g="$1"
    local lib_file
    case "$g" in
        pg) lib_file="pgbackrest.sh" ;;
        *)  lib_file="${g}.sh" ;;
    esac
    # shellcheck source=/dev/null
    source "${BACKUPS_LIB_DIR}/${lib_file}"
}
