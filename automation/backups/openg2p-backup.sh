#!/usr/bin/env bash
# =============================================================================
# OpenG2P Backup Orchestrator
# =============================================================================
# Runs ON YOUR LAPTOP. Drives a 4th "backup" node + the 3 production nodes
# via SSH to install, run, verify, and restore backups for the OpenG2P
# platform.
#
# Subcommands:
#   install   One-time bootstrap of all enabled groups
#   run       Execute backups for one or all enabled groups (also used by cron)
#   verify    Cheap integrity checks (no data restored)
#   drill     Weekly: verify + dry-run-restore + write status
#   list      Show available backups per group
#   restore   Restore a component (PG PITR, single PVC, etcd, full cluster)
#   status    Show last-run + last-drill status per group
#   help      Show this help
#
# Idempotent — state markers per role on the remote nodes; orchestrator state
# in ./.state/. Re-runs skip completed install steps. Use --force to re-run.
#
# Docs: operations/deployment/automation/backups.md
# =============================================================================

set -euo pipefail

trap '
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "" >&2
        echo "[FATAL] openg2p-backup.sh exited with status ${rc} at line ${LINENO} (${BASH_COMMAND})" >&2
        echo "[FATAL] log: ${LOG_FILE:-<not set>}" >&2
    fi
' EXIT

echo "[boot] openg2p-backup.sh starting (bash ${BASH_VERSION})" >&2

if (( BASH_VERSINFO[0] < 4 )); then
    echo "[FATAL] bash 4 or later required (detected ${BASH_VERSION})." >&2
    echo "[FATAL] macOS: 'brew install bash', then re-open the shell." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
SUBCOMMAND=""
RUN_GROUP="all"
RESTORE_TARGET=""
RESTORE_PIT=""
DRY_RUN=false
FORCE_MODE=false
ENABLE_SECRET_ENCRYPTION=false
SKIP_PREFLIGHT=false
LOG_FILE="${SCRIPT_DIR}/logs/openg2p-backup-$(date '+%Y%m%d-%H%M%S').log"

mkdir -p "${SCRIPT_DIR}/logs" "${SCRIPT_DIR}/.state"

# Source the foundation. utils.sh in turn sources production/lib/shared/utils.sh
# and production/lib/ssh-utils.sh — giving us logging, config parsing, ssh_run,
# ssh_push, ssh_probe etc. for free.
# shellcheck source=lib/utils.sh
source "${SCRIPT_DIR}/lib/utils.sh"

# Module libs are sourced lazily by each subcommand so a missing one only
# breaks the affected component, not `--help`.

# ---------------------------------------------------------------------------
parse_args() {
    if [[ $# -lt 1 ]]; then show_help; exit 1; fi

    SUBCOMMAND="$1"; shift

    case "$SUBCOMMAND" in
        help|--help|-h) show_help; exit 0 ;;
        install|run|verify|drill|list|restore|status) ;;
        *)
            log_error "Unknown subcommand: '${SUBCOMMAND}'" \
                      "Expected one of: install, run, verify, drill, list, restore, status, help" \
                      "Run with --help for the full reference"
            exit 1
            ;;
    esac

    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)                       CONFIG_FILE="$2";       shift 2 ;;
            --component|--group)            RUN_GROUP="$2";         shift 2 ;;
            --target)                       RESTORE_TARGET="$2";    shift 2 ;;
            --point-in-time)                RESTORE_PIT="$2";       shift 2 ;;
            --dry-run)                      DRY_RUN=true;           shift ;;
            --force)                        FORCE_MODE=true;        shift ;;
            --enable-secret-encryption)     ENABLE_SECRET_ENCRYPTION=true; shift ;;
            --skip-preflight)               SKIP_PREFLIGHT=true;    shift ;;
            --help|-h) show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1" \
                          "This flag is not recognized" \
                          "Run with --help"
                exit 1
                ;;
        esac
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        log_error "No config file specified" \
                  "--config is required" \
                  "Copy backup-config.example.yaml and provide it" \
                  "$0 ${SUBCOMMAND} --config backup-config.yaml"
        exit 1
    fi
    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"

    case "$RUN_GROUP" in
        all|pg|etcd|rancher|nfs|configs) ;;
        *)
            log_error "Invalid --component '${RUN_GROUP}'" \
                      "Expected one of: all, pg, etcd, rancher, nfs, configs"
            exit 1
            ;;
    esac
}

show_help() {
    cat <<'EOF'
OpenG2P Backup Orchestrator
===============================

Runs on your laptop. SSHes into a backup node + 3 production nodes.

Usage:
  ./openg2p-backup.sh <subcommand> --config backup-config.yaml [options]

Subcommands:
  install                    One-time bootstrap of all enabled groups.
                             Use --enable-secret-encryption to also turn on
                             etcd encryption-at-rest (requires brief apiserver
                             restart on the compute node — maintenance window).

  run [--component X]        Execute backups now. Default: all enabled groups.
                             Used by cron on the backup host. Components:
                             pg, etcd, rancher, nfs, configs.

  verify [--component X]     Lightweight integrity checks per group. No data
                             restored. Used by `drill` internally.

  drill                      Weekly drill: verify + dry-run restore for every
                             enabled group. Updates status file consumed by
                             `status` and (Phase 2) the alerting layer.

  list [--component X]       Inventory of available backups per group.

  restore --component X      Restore a component:
          --target <spec>      pg:      target = ignored (use --point-in-time)
          [--point-in-time T]  nfs:     target = <namespace>/<pvc>
          [--dry-run]          rancher: target = 'cluster' or '<namespace>'
                               etcd:    target = 'latest' or snapshot file
                               configs: target = <subsystem> e.g. wireguard

  status                     Show last-run and last-drill state per group.
                             Reads /var/lib/openg2p-backup/.status.json on
                             the backup host.

Common options:
  --config <file>            Path to backup-config.yaml (required)
  --force                    Ignore install state markers, re-run all steps
  --skip-preflight           Skip backup-host preflight (re-runs only)
  --help                     Show this help

Examples:
  # First-time install (all enabled groups)
  ./openg2p-backup.sh install --config backup-config.yaml

  # Enable etcd encryption-at-rest (separate maintenance step)
  ./openg2p-backup.sh install --config backup-config.yaml --enable-secret-encryption

  # Run only the postgres backup now
  ./openg2p-backup.sh run --config backup-config.yaml --component pg

  # Restore postgres to a specific point in time
  ./openg2p-backup.sh restore --config backup-config.yaml --component pg \
      --point-in-time '2026-04-26 14:00:00'

  # Restore one PVC's data
  ./openg2p-backup.sh restore --config backup-config.yaml --component nfs \
      --target keycloak/keycloak-data

  # Status report
  ./openg2p-backup.sh status --config backup-config.yaml

Group toggles (in backup-config.yaml under groups:):
  Each group is independently switchable. Disabled groups are skipped on
  install/run/verify/drill and reported as 'disabled' by status.

Docs: operations/deployment/automation/backups.md
EOF
}

# ---------------------------------------------------------------------------
# Init pipeline — every subcommand needs config + cluster facts + ssh init.
# ---------------------------------------------------------------------------
init_runtime() {
    log_info "Loading backup config: ${CONFIG_FILE}"
    load_config "$CONFIG_FILE"

    load_cluster_config        # merges prod-config + provision-output

    ssh_init                   # production lib helper: ControlMaster dir

    # Print a small banner so cron logs are easy to spot.
    log_banner "OpenG2P Backup Orchestrator" "subcommand: ${SUBCOMMAND}  group: ${RUN_GROUP}"

    log_info "Enabled groups: $(enabled_groups | tr '\n' ' ')"
}

# ---------------------------------------------------------------------------
# Backup-host preflight — runs the function defined in lib/utils.sh remotely.
# ---------------------------------------------------------------------------
remote_preflight() {
    if [[ "$SKIP_PREFLIGHT" == "true" ]]; then
        log_warn "Skipping backup-host preflight (--skip-preflight)"
        return 0
    fi

    log_step "P" "Backup host preflight (remote)"

    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"

    # Push utils.sh + the prod shared utils to a tmpdir on the backup host
    # so we can call backup_host_preflight there.
    local tmpdir; tmpdir=$(mktemp -d -t openg2p-backup-stage.XXXXXX)
    trap "rm -rf '$tmpdir'" RETURN

    mkdir -p "$tmpdir/lib"
    cp "${SCRIPT_DIR}/lib/utils.sh" "$tmpdir/lib/utils.sh"
    mkdir -p "$tmpdir/production-lib"
    cp "${SCRIPT_DIR}/../production/lib/shared/utils.sh" "$tmpdir/production-lib/utils.sh"

    # Inline a thin wrapper that adjusts paths and invokes the function.
    cat > "$tmpdir/run-preflight.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "\$SCRIPT_DIR/production-lib/utils.sh"
# Provide cfg() shim — preflight only needs it via parameters, but
# load_config-less mode means CONFIG is empty; that's fine.
# shellcheck source=/dev/null
PROD_SHARED_LIB="\$SCRIPT_DIR/production-lib/utils.sh" \\
    bash -c '
        # re-source utils with adjusted constants
        source "'\$SCRIPT_DIR'/production-lib/utils.sh"
        $(declare -f group_enabled enabled_groups backup_host_preflight)
        backup_host_preflight "${repo_root}"
    '
EOF
    chmod +x "$tmpdir/run-preflight.sh"

    ssh_push "backup" "${tmpdir}/" "/tmp/openg2p-backup-preflight/"
    if ! ssh_run "backup" "bash /tmp/openg2p-backup-preflight/run-preflight.sh"; then
        log_error "Backup host preflight failed" \
                  "See output above" \
                  "Resize the VM or fix the issue, then re-run" \
                  "$0 ${SUBCOMMAND} --config ${CONFIG_FILE}"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# SSH probes — verify we can reach all 4 nodes for the enabled groups.
# ---------------------------------------------------------------------------
probe_required_nodes() {
    log_step "P" "SSH probes"

    # Backup host always required.
    ssh_probe "backup" || exit 1

    # Per-group node requirements:
    #   pg       → storage
    #   etcd     → compute
    #   rancher  → compute
    #   nfs      → storage (read NFS export) + compute (read kubectl for sidecar manifest)
    #   configs  → rp + compute
    local need_storage=false need_compute=false need_rp=false
    if group_enabled pg;       then need_storage=true; fi
    if group_enabled etcd;     then need_compute=true; fi
    if group_enabled rancher;  then need_compute=true; fi
    if group_enabled nfs;      then need_storage=true; need_compute=true; fi
    if group_enabled configs;  then need_compute=true; need_rp=true; fi

    [[ "$need_storage" == "true" ]] && (ssh_probe "storage" || exit 1)
    [[ "$need_compute" == "true" ]] && (ssh_probe "compute" || exit 1)
    [[ "$need_rp"      == "true" ]] && (ssh_probe "rp"      || exit 1)
}

# ---------------------------------------------------------------------------
# Subcommand dispatchers — module libs sourced on demand via load_group_module
# (defined in lib/utils.sh so the cron wrappers can use it too).
# ---------------------------------------------------------------------------
do_install() {
    init_runtime
    probe_required_nodes
    remote_preflight

    # Resolve passphrase files now (generates if missing) — fails fast if
    # the keystore path is unwritable.
    local restic_pass pgbr_pass
    restic_pass=$(ensure_passphrase_file "restic_passphrase_file" "restic")
    pgbr_pass=$(ensure_passphrase_file "pgbackrest_passphrase_file" "pgBackRest")
    log_info "Resolved passphrase files."

    # 1. Backup-host bootstrap (apt + repos + cron + env file)
    # shellcheck source=lib/restic.sh
    source "${SCRIPT_DIR}/lib/restic.sh"
    log_step "1" "Backup host bootstrap"
    bootstrap_backup_host "$restic_pass" "$pgbr_pass"

    # 2. Per-group install — each is gated by group_enabled.
    if group_enabled pg; then
        log_step "2a" "PG (pgBackRest) install"
        # shellcheck source=lib/pgbackrest.sh
        source "${SCRIPT_DIR}/lib/pgbackrest.sh"
        pg_install
    else
        log_warn "Group 'pg' disabled — skipping pgBackRest install."
    fi

    if group_enabled etcd; then
        log_step "2b" "etcd snapshot schedule"
        # shellcheck source=lib/etcd.sh
        source "${SCRIPT_DIR}/lib/etcd.sh"
        etcd_install
    else
        log_warn "Group 'etcd' disabled — skipping etcd snapshot setup."
    fi

    if group_enabled rancher; then
        log_step "2c" "rancher-backup operator + ResourceSet"
        # shellcheck source=lib/rancher.sh
        source "${SCRIPT_DIR}/lib/rancher.sh"
        rancher_install
    else
        log_warn "Group 'rancher' disabled — skipping rancher-backup install."
    fi

    if group_enabled nfs; then
        log_step "2d" "NFS read-only mount + restic repo"
        # shellcheck source=lib/nfs.sh
        source "${SCRIPT_DIR}/lib/nfs.sh"
        nfs_install
    else
        log_warn "Group 'nfs' disabled — skipping NFS backup setup."
    fi

    if group_enabled configs; then
        log_step "2e" "Config (WG/Nginx/CA/RKE2 FS) restic repo"
        # shellcheck source=lib/configs.sh
        source "${SCRIPT_DIR}/lib/configs.sh"
        configs_install
    else
        log_warn "Group 'configs' disabled — skipping config backup setup."
    fi

    # 3. Optional: etcd encryption-at-rest (gated, requires apiserver restart)
    if [[ "$ENABLE_SECRET_ENCRYPTION" == "true" ]]; then
        log_step "3" "Etcd encryption-at-rest (apiserver restart!)"
        # shellcheck source=lib/etcd.sh
        source "${SCRIPT_DIR}/lib/etcd.sh"
        local key_file
        key_file=$(ensure_passphrase_file "etcd_at_rest_key_file" "etcd-at-rest" true)
        encryption_enable "$key_file"
    else
        log_info "Etcd encryption-at-rest NOT enabled — pass --enable-secret-encryption during a maintenance window to turn it on."
    fi

    # 4. Cron deployment on the backup host
    log_step "4" "Cron schedule on backup host"
    deploy_cron

    log_success "Install complete."
    log_info "Run a smoke backup now:  ${0##*/} run --config ${CONFIG_FILE} --component all"
}

do_run() {
    init_runtime
    # Run is invoked by cron — preflight is too noisy. Skip unless --force.
    [[ "$FORCE_MODE" == "true" ]] && remote_preflight

    local groups_to_run
    if [[ "$RUN_GROUP" == "all" ]]; then
        groups_to_run=$(enabled_groups)
    else
        if ! group_enabled "$RUN_GROUP"; then
            log_warn "Group '${RUN_GROUP}' is disabled in config — nothing to do."
            exit 0
        fi
        groups_to_run="$RUN_GROUP"
    fi

    local g
    for g in $groups_to_run; do
        log_step "RUN" "$g"
        load_group_module "$g"
        "${g}_run" || {
            log_error "Run failed for group '${g}'" "See output above" "Investigate"
            # Don't exit — we want all groups attempted; final status will reflect.
        }
    done
    log_success "Run complete for: ${groups_to_run}"
}

do_verify() {
    init_runtime
    local groups_to_run
    if [[ "$RUN_GROUP" == "all" ]]; then
        groups_to_run=$(enabled_groups)
    else
        group_enabled "$RUN_GROUP" || { log_warn "Group disabled — nothing to verify."; exit 0; }
        groups_to_run="$RUN_GROUP"
    fi
    local g
    for g in $groups_to_run; do
        log_step "VERIFY" "$g"
        load_group_module "$g"
        "${g}_verify"
    done
}

do_drill() {
    init_runtime
    # shellcheck source=lib/drills.sh
    source "${SCRIPT_DIR}/lib/drills.sh"
    drills_run_all
}

do_list() {
    init_runtime
    local groups_to_run
    if [[ "$RUN_GROUP" == "all" ]]; then
        groups_to_run=$(enabled_groups)
    else
        groups_to_run="$RUN_GROUP"
    fi
    local g
    for g in $groups_to_run; do
        echo ""
        echo "=== ${g} ==="
        load_group_module "$g"
        "${g}_list" || log_warn "list failed for ${g}"
    done
}

do_restore() {
    init_runtime
    if [[ "$RUN_GROUP" == "all" ]]; then
        log_error "restore requires --component" \
                  "Restoring 'all' is the full-rebuild runbook" \
                  "See operations/deployment/automation/backups/restoration/full-rebuild.md"
        exit 1
    fi
    group_enabled "$RUN_GROUP" || {
        log_error "Group '${RUN_GROUP}' is disabled in config" \
                  "Cannot restore a disabled group" \
                  "Enable it in backup-config.yaml first"
        exit 1
    }
    load_group_module "$RUN_GROUP"
    "${RUN_GROUP}_restore" "$RESTORE_TARGET" "$RESTORE_PIT" "$DRY_RUN"
}

do_status() {
    init_runtime
    log_step "STATUS" "per-group state"
    echo ""
    printf "%-10s %-10s %-22s %-10s %-22s %-8s\n" \
        "GROUP" "STATE" "LAST-RUN" "RESULT" "LAST-DRILL" "RESULT"
    printf "%-10s %-10s %-22s %-10s %-22s %-8s\n" \
        "----------" "----------" "----------------------" "----------" "----------------------" "--------"
    local g
    for g in pg etcd rancher nfs configs; do
        local state; state=$(group_state_str "$g")
        if [[ "$state" == "disabled" ]]; then
            printf "%-10s %-10s %-22s %-10s %-22s %-8s\n" "$g" "$state" "-" "-" "-" "-"
            continue
        fi
        # Read the JSON status file from the backup host.
        local snippet
        snippet=$(ssh_run "backup" "jq -r --arg g \"$g\" '.components[\$g] // {} | [(.last_run//\"-\"),(.last_run_result//\"-\"),(.last_drill//\"-\"),(.last_drill_result//\"-\")] | @tsv' < /var/lib/openg2p-backup/.status.json 2>/dev/null || echo '-\\t-\\t-\\t-'") || snippet=$'-\t-\t-\t-'
        local last_run last_run_r last_drill last_drill_r
        IFS=$'\t' read -r last_run last_run_r last_drill last_drill_r <<<"$snippet"
        printf "%-10s %-10s %-22s %-10s %-22s %-8s\n" \
            "$g" "$state" "${last_run:--}" "${last_run_r:--}" "${last_drill:--}" "${last_drill_r:--}"
    done
    echo ""
}

# ---------------------------------------------------------------------------
# bootstrap_backup_host — apt + repo dirs + lib/ deploy + SSH trust to other nodes
# ---------------------------------------------------------------------------
# Args: <restic_pass_file> <pgbr_pass_file>
# After this, the backup host has everything it needs to run cron jobs
# autonomously: lib/, config, passphrases, and SSH keys to rp/compute/storage.
# ---------------------------------------------------------------------------
bootstrap_backup_host() {
    local restic_pass_file="$1"
    local pgbr_pass_file="$2"
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"

    log_info "Pushing lib/ + manifests/ + config to backup host..."
    ssh_run "backup" "install -d -m 0755 /opt/openg2p-backup/lib /opt/openg2p-backup/manifests /opt/openg2p-backup/roles"
    ssh_push "backup" "${SCRIPT_DIR}/lib/"        "/opt/openg2p-backup/lib/"
    ssh_push "backup" "${SCRIPT_DIR}/manifests/"  "/opt/openg2p-backup/manifests/"
    ssh_push "backup" "${SCRIPT_DIR}/roles/"      "/opt/openg2p-backup/roles/"
    # Production lib has to be reachable too, since lib/utils.sh sources it.
    ssh_run "backup" "install -d -m 0755 /opt/openg2p-backup/production-lib"
    ssh_push "backup" "${SCRIPT_DIR}/../production/lib/" "/opt/openg2p-backup/production-lib/"

    # Push merged config — backup-config.yaml + prod-config.yaml stitched
    # together so the backup host can ssh_resolve_role for every role.
    log_info "Staging merged config on backup host..."
    local stage; stage=$(mktemp -d -t openg2p-backup-cfg.XXXXXX)
    cp "$CONFIG_FILE" "$stage/backup-config.yaml"

    local prod_cfg="$(cfg prod_config)"
    [[ "$prod_cfg" = /* ]] || prod_cfg="${SCRIPT_DIR}/${prod_cfg}"
    {
        echo ""
        echo "# ─── merged from prod-config.yaml at install time ───"
        cat "$prod_cfg"
        local prov="$(dirname "$prod_cfg")/provision-output.yaml"
        if [[ -f "$prov" ]]; then
            echo ""
            echo "# ─── merged from provision-output.yaml ───"
            cat "$prov"
        fi
    } >> "$stage/backup-config.yaml"

    ssh_push "backup" "${stage}/backup-config.yaml" "/etc/openg2p-backup/config.yaml"
    rm -rf "$stage"

    # Run roles/backup-host/install.sh on the backup host with passphrases.
    log_info "Running backup-host install.sh..."
    local restic_pass; restic_pass="$(< "$restic_pass_file")"
    local pgbr_pass; pgbr_pass="$(< "$pgbr_pass_file")"
    ssh_run "backup" "BACKUP_REPO_ROOT='${repo_root}' \
                      KEEP_DAILY='$(cfg retention.keep_daily 7)' \
                      KEEP_WEEKLY='$(cfg retention.keep_weekly 4)' \
                      KEEP_MONTHLY='$(cfg retention.keep_monthly 6)' \
                      bash /opt/openg2p-backup/roles/backup-host/install.sh \
                      $(printf '%q' "$restic_pass") \
                      $(printf '%q' "$pgbr_pass")"

    # Generate an SSH key on the backup host for orchestrating other nodes.
    log_info "Setting up backup-host → {rp,compute,storage} SSH trust..."
    local backup_pubkey
    backup_pubkey=$(ssh_run "backup" "set -euo pipefail
        install -d -o root -g root -m 0700 /root/.ssh
        if [[ ! -f /root/.ssh/openg2p-backup-orch ]]; then
            ssh-keygen -t ed25519 -N '' -f /root/.ssh/openg2p-backup-orch \
                -C 'openg2p-backup-orch@backup'
        fi
        cat /root/.ssh/openg2p-backup-orch.pub" | tail -1)

    # Authorize on rp, compute, storage for the configured ssh_user.
    local role
    for role in rp compute storage; do
        local resolved; resolved="$(ssh_resolve_role "$role")"
        local user="${resolved%%|*}"
        local rest="${resolved#*|}"
        ssh_run "$role" "set -euo pipefail
            install -d -o ${user} -g ${user} -m 0700 /home/${user}/.ssh
            touch /home/${user}/.ssh/authorized_keys
            chmod 0600 /home/${user}/.ssh/authorized_keys
            chown ${user}:${user} /home/${user}/.ssh/authorized_keys
            grep -qF '${backup_pubkey}' /home/${user}/.ssh/authorized_keys || \
                echo '${backup_pubkey}' >> /home/${user}/.ssh/authorized_keys"
    done

    # Drop SSH config on backup host so role resolution from cron works.
    ssh_run "backup" "set -euo pipefail
        cat > /root/.ssh/config <<EOC
Host openg2p-rp
    HostName $(cfg rp_private_ip)
    User $(cfg rp_ssh_user ubuntu)
    IdentityFile /root/.ssh/openg2p-backup-orch
    StrictHostKeyChecking accept-new
Host openg2p-compute
    HostName $(cfg compute_private_ip)
    User $(cfg compute_ssh_user ubuntu)
    IdentityFile /root/.ssh/openg2p-backup-orch
    StrictHostKeyChecking accept-new
Host openg2p-storage
    HostName $(cfg storage_private_ip)
    User $(cfg storage_ssh_user ubuntu)
    IdentityFile /root/.ssh/openg2p-backup-orch
    StrictHostKeyChecking accept-new
EOC
        chmod 0600 /root/.ssh/config"

    # Wrapper scripts cron will call.
    log_info "Installing /usr/local/bin/openg2p-backup-{run,drill,status} wrappers..."
    ssh_run "backup" "set -euo pipefail
cat > /usr/local/bin/openg2p-backup-run <<'EOC'
#!/usr/bin/env bash
# Invoked by cron: openg2p-backup-run <group>
# Sets OPENG2P_ON_BACKUP_HOST=1 so lib functions short-circuit ssh-to-self.
# /etc/openg2p-backup/config.yaml is the pre-merged backup+prod config
# (stitched together at install time on the laptop, then pushed here),
# so a single load_config call gives us every key we need — no separate
# load_cluster_config step like the laptop orchestrator does.
set -euo pipefail
export OPENG2P_ON_BACKUP_HOST=1
group=\"\${1:-}\"
[[ -z \"\$group\" ]] && { echo 'usage: openg2p-backup-run <group>'; exit 1; }
source /opt/openg2p-backup/lib/utils.sh
load_config /etc/openg2p-backup/config.yaml
case \"\$group\" in
    pg)      source /opt/openg2p-backup/lib/pgbackrest.sh ;;
    *)       source /opt/openg2p-backup/lib/\${group}.sh ;;
esac
\"\${group}_run\"
EOC
chmod +x /usr/local/bin/openg2p-backup-run

cat > /usr/local/bin/openg2p-backup-drill <<'EOC'
#!/usr/bin/env bash
# Invoked by cron: weekly drill across all enabled groups.
# Sets OPENG2P_ON_BACKUP_HOST=1 so lib functions short-circuit ssh-to-self.
# See openg2p-backup-run for the load_config-without-load_cluster_config
# rationale.
set -euo pipefail
export OPENG2P_ON_BACKUP_HOST=1
source /opt/openg2p-backup/lib/utils.sh
load_config /etc/openg2p-backup/config.yaml
# drills_run_all calls load_group_module per group — but that's the
# laptop-side path resolver. Source each group lib manually here so
# <group>_drill is in scope.
for g in pg etcd rancher nfs configs; do
    case \"\$g\" in
        pg) lib_file=pgbackrest.sh ;;
        *)  lib_file=\"\${g}.sh\" ;;
    esac
    [[ -f /opt/openg2p-backup/lib/\$lib_file ]] && source /opt/openg2p-backup/lib/\$lib_file
done
source /opt/openg2p-backup/lib/drills.sh
drills_run_all
EOC
chmod +x /usr/local/bin/openg2p-backup-drill

cat > /usr/local/bin/openg2p-backup-status <<'EOC'
#!/usr/bin/env bash
jq . /var/lib/openg2p-backup/.status.json
EOC
chmod +x /usr/local/bin/openg2p-backup-status

# Compatibility shim — backup host's lib/utils.sh expects production lib at
# ../../production/lib/shared/utils.sh relative to BACKUPS_ROOT_DIR. We
# laid them down at /opt/openg2p-backup/{lib,production-lib}; symlink to
# the path utils.sh hardcodes.
mkdir -p /opt/openg2p-backup/../production/lib
ln -sfn /opt/openg2p-backup/production-lib/shared /opt/openg2p-backup/../production/lib/shared
ln -sfn /opt/openg2p-backup/production-lib/ssh-utils.sh /opt/openg2p-backup/../production/lib/ssh-utils.sh
"

    log_success "Backup host bootstrapped."
}

# ---------------------------------------------------------------------------
# deploy_cron — render cron.template with per-group schedules and install
# at /etc/cron.d/openg2p-backup on the backup host.
# ---------------------------------------------------------------------------
deploy_cron() {
    local cron_src="${SCRIPT_DIR}/roles/backup-host/cron.template"
    local stage; stage=$(mktemp -t openg2p-cron.XXXXXX)
    trap "rm -f '$stage'" RETURN

    # Substitute schedule placeholders + disable lines for disabled groups.
    # NOTE: no __RANCHER_CRON__ — rancher backup cadence is owned by the
    # in-cluster Schedule CR. See lib/rancher.sh and the cron.template header.
    sed -e "s|__MAILTO__|root|g" \
        -e "s|__PG_FULL_CRON__|$(group_enabled pg && cfg schedules.pg_full '0 2 * * 0' || echo '#0 2 * * 0')|g" \
        -e "s|__PG_DIFF_CRON__|$(group_enabled pg && cfg schedules.pg_diff '0 2 * * 1-6' || echo '#0 2 * * 1-6')|g" \
        -e "s|__ETCD_CRON__|$(group_enabled etcd && cfg schedules.etcd_pull '15 */6 * * *' || echo '#15 */6 * * *')|g" \
        -e "s|__NFS_CRON__|$(group_enabled nfs && cfg schedules.nfs '30 3 * * *' || echo '#30 3 * * *')|g" \
        -e "s|__CONFIGS_CRON__|$(group_enabled configs && cfg schedules.configs '30 3 * * *' || echo '#30 3 * * *')|g" \
        -e "s|__DRILL_CRON__|$(cfg schedules.drill '0 5 * * 0')|g" \
        "$cron_src" > "$stage"

    ssh_push "backup" "$stage" "/etc/cron.d/openg2p-backup"
    ssh_run "backup" "chmod 0644 /etc/cron.d/openg2p-backup && systemctl reload cron"
    log_success "Cron deployed on backup host."
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    case "$SUBCOMMAND" in
        install) do_install ;;
        run)     do_run ;;
        verify)  do_verify ;;
        drill)   do_drill ;;
        list)    do_list ;;
        restore) do_restore ;;
        status)  do_status ;;
    esac
}

# Tee logs to file like the production orchestrator does.
{
    main "$@"
} 2>&1 | tee -a "$LOG_FILE"
