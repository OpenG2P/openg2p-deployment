#!/usr/bin/env bash
# =============================================================================
# OpenG2P Backup — PostgreSQL via pgBackRest
# =============================================================================
# Topology:
#   • Backup host = repo host. Holds /var/lib/openg2p-backup/pg/.
#     Runs pgbackrest as user 'pgbackrest' (uid auto-assigned).
#   • Storage node = PG server. Runs pgbackrest as 'postgres' user, talks
#     to repo host via SSH. archive_command pushes WAL continuously.
#
# Backup types:
#   • Full     — Sunday 02:00     (cron on backup host)
#   • Diff     — Mon-Sat 02:00    (cron on backup host)
#   • WAL      — continuous, archive-push from PG (every archive_timeout=60s)
#
# RPO: ≈1 minute under normal operation; bounded by archive_timeout.
# RTO: minutes (PITR), tens of minutes (full restore).
#
# Upstream docs (linked from operations/deployment/automation/backups):
#   https://pgbackrest.org/user-guide.html
# =============================================================================

set -euo pipefail

# -- backup-host paths -------------------------------------------------------
PGBR_REPO_HOST_USER="pgbackrest"
PGBR_REPO_PATH_DEFAULT="/var/lib/openg2p-backup/pg"

# -- storage-node paths ------------------------------------------------------
PGBR_PG_USER="postgres"
PGBR_CONF_PATH="/etc/pgbackrest/pgbackrest.conf"

# ---------------------------------------------------------------------------
# pg_install — runs on the orchestrator (laptop), drives backup + storage
# ---------------------------------------------------------------------------
pg_install() {
    local stanza="$(cfg pg.stanza_name openg2p)"
    local parallel="$(cfg pg.parallel_jobs 4)"
    local archive_timeout="$(cfg pg.archive_timeout_seconds 60)"
    local pg_version="$(cfg postgres_version 16)"
    local pg_port="$(cfg postgres_port 5432)"
    local repo_path="$(cfg backup_repo_root /var/lib/openg2p-backup)/pg"
    local backup_private_ip="$(cfg backup_private_ip)"
    local pgbr_pass_file
    pgbr_pass_file="$(ensure_passphrase_file pgbackrest_passphrase_file pgBackRest false)"

    log_info "PG install: stanza=${stanza} parallel=${parallel} repo=${repo_path}"

    # 1. Install pgBackRest on backup host + create repo + service user.
    log_info "Configuring backup host as pgBackRest repo host..."
    local pgbr_pass; pgbr_pass="$(< "$pgbr_pass_file")"
    ssh_run "backup" "$(cat <<EOF
set -euo pipefail
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pgbackrest

id -u ${PGBR_REPO_HOST_USER} >/dev/null 2>&1 || \
    useradd -r -m -d /var/lib/${PGBR_REPO_HOST_USER} -s /bin/bash ${PGBR_REPO_HOST_USER}

# The home dir may already exist (apt's pgbackrest package, or a prior run)
# owned by root — useradd -m then leaves it root-owned and the service user
# can't traverse into it. Force ownership + a traversable mode on the home
# dir, THEN create .ssh (0700, the only mode ssh-keygen accepts).
install -d -o ${PGBR_REPO_HOST_USER} -g ${PGBR_REPO_HOST_USER} -m 0750 /var/lib/${PGBR_REPO_HOST_USER}
chown ${PGBR_REPO_HOST_USER}:${PGBR_REPO_HOST_USER} /var/lib/${PGBR_REPO_HOST_USER}
install -d -o ${PGBR_REPO_HOST_USER} -g ${PGBR_REPO_HOST_USER} -m 0700 /var/lib/${PGBR_REPO_HOST_USER}/.ssh

# The repo lives under the data-volume mount root (created root:root 0750 by
# the backup-host installer / cloud-init). Without o+x on that root, the
# pgbackrest service user can't traverse it to reach its repo subdir. Make
# the root traversable (subdirs keep their own restrictive perms), then own
# the repo subdir.
chmod 0755 "$(dirname "${repo_path}")"
install -d -o ${PGBR_REPO_HOST_USER} -g ${PGBR_REPO_HOST_USER} -m 0750 \
    ${repo_path} \
    /etc/pgbackrest \
    /var/log/pgbackrest

cat > /etc/pgbackrest/pgbackrest.conf <<CONF
[global]
repo1-path=${repo_path}
repo1-retention-full=$(cfg retention.pg_full_count 4)
repo1-retention-diff=$(cfg retention.pg_diff_count 7)
repo1-retention-archive=$(cfg retention.pg_full_count 4)
repo1-retention-archive-type=full
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=${pgbr_pass}
process-max=${parallel}
log-level-console=info
log-level-file=detail
start-fast=y
compress-type=zst
compress-level=3

[${stanza}]
pg1-host=$(cfg storage_private_ip)
pg1-host-user=${PGBR_PG_USER}
pg1-path=/var/lib/postgresql/${pg_version}/main
pg1-port=${pg_port}
CONF
chmod 0640 /etc/pgbackrest/pgbackrest.conf
chown root:${PGBR_REPO_HOST_USER} /etc/pgbackrest/pgbackrest.conf

# Generate SSH key for backup-host -> storage-node trust (postgres user).
if [[ ! -f /var/lib/${PGBR_REPO_HOST_USER}/.ssh/id_ed25519 ]]; then
    sudo -u ${PGBR_REPO_HOST_USER} ssh-keygen -t ed25519 -N '' \
        -f /var/lib/${PGBR_REPO_HOST_USER}/.ssh/id_ed25519 \
        -C "${PGBR_REPO_HOST_USER}@openg2p-backup"
fi
chmod 0700 /var/lib/${PGBR_REPO_HOST_USER}/.ssh
chmod 0600 /var/lib/${PGBR_REPO_HOST_USER}/.ssh/id_ed25519

cat /var/lib/${PGBR_REPO_HOST_USER}/.ssh/id_ed25519.pub
EOF
)" > /tmp/openg2p-pgbr-backup.pub

    local backup_pubkey; backup_pubkey="$(tail -1 /tmp/openg2p-pgbr-backup.pub)"
    log_info "Backup host pgbackrest pubkey collected."

    # 2. Install pgBackRest on storage node + configure pgbackrest.conf +
    #    edit postgresql.conf + restart Postgres + create stanza.
    log_info "Configuring storage node as pgBackRest client..."
    # Push to a DIRECTORY (trailing slash) — ssh_push mkdir -p's its dest and
    # rsyncs INTO it, so a file-named dest would land as <dir>/<file>/<file>.
    ssh_push "storage" "${SCRIPT_DIR:-${BACKUPS_ROOT_DIR}}/roles/storage/configure-pg.sh" \
        "/tmp/openg2p-backup/storage/"
    # cipher pass: raw, single-quoted (NOT printf %q — %q output wrapped in
    # single quotes leaves literal backslashes, corrupting the passphrase and
    # desyncing it from the backup-host side). Safe for base64 passphrases,
    # which contain no single quotes.
    ssh_run "storage" "PGBR_STANZA='${stanza}' \
                       PGBR_PG_VERSION='${pg_version}' \
                       PGBR_PG_PORT='${pg_port}' \
                       PGBR_PARALLEL='${parallel}' \
                       PGBR_ARCHIVE_TIMEOUT='${archive_timeout}' \
                       PGBR_BACKUP_HOST_IP='${backup_private_ip}' \
                       PGBR_BACKUP_PUBKEY='${backup_pubkey}' \
                       PGBR_REPO_CIPHER_PASS='${pgbr_pass}' \
                       PGBR_REPO_PATH='${repo_path}' \
                       PGBR_RETENTION_FULL='$(cfg retention.pg_full_count 4)' \
                       PGBR_RETENTION_DIFF='$(cfg retention.pg_diff_count 7)' \
                       bash /tmp/openg2p-backup/storage/configure-pg.sh"

    # 3. Establish the REVERSE SSH trust: pgBackRest's archive_command runs as
    #    postgres@storage and SSHes to pgbackrest@backup to push WAL. Capture
    #    the postgres pubkey (generated by configure-pg.sh) and authorize it on
    #    the backup host's pgbackrest user. Without this, `pgbackrest check`
    #    and all WAL archiving fail.
    log_info "Authorizing storage 'postgres' key on backup host (WAL push path)..."
    local postgres_pubkey
    postgres_pubkey=$(ssh_run "storage" "cat /var/lib/postgresql/.ssh/id_ed25519.pub" | tail -1)
    ssh_run "backup" "set -euo pipefail
        install -d -o ${PGBR_REPO_HOST_USER} -g ${PGBR_REPO_HOST_USER} -m 0700 /var/lib/${PGBR_REPO_HOST_USER}/.ssh
        touch /var/lib/${PGBR_REPO_HOST_USER}/.ssh/authorized_keys
        chown ${PGBR_REPO_HOST_USER}:${PGBR_REPO_HOST_USER} /var/lib/${PGBR_REPO_HOST_USER}/.ssh/authorized_keys
        chmod 0600 /var/lib/${PGBR_REPO_HOST_USER}/.ssh/authorized_keys
        grep -qF '${postgres_pubkey}' /var/lib/${PGBR_REPO_HOST_USER}/.ssh/authorized_keys || \
            echo '${postgres_pubkey}' >> /var/lib/${PGBR_REPO_HOST_USER}/.ssh/authorized_keys"

    # 3b. Host-key trust: pgbackrest@backup → postgres@storage (backup reads pg).
    #     The >> redirect runs as ROOT (outer sudo shell), so known_hosts is
    #     created root:root — pgbackrest's ssh (running as the pgbackrest user)
    #     then can't read it and StrictHostKeyChecking aborts every operation.
    #     MUST chown it to pgbackrest (the storage side does the same for
    #     postgres). This was the blocker after the .ssh permission fix.
    log_info "Trusting storage node host key from backup host..."
    ssh_run "backup" "set -euo pipefail
        ssh-keyscan -H $(cfg storage_private_ip) 2>/dev/null \
            >> /var/lib/${PGBR_REPO_HOST_USER}/.ssh/known_hosts
        chown ${PGBR_REPO_HOST_USER}:${PGBR_REPO_HOST_USER} /var/lib/${PGBR_REPO_HOST_USER}/.ssh/known_hosts
        chmod 0600 /var/lib/${PGBR_REPO_HOST_USER}/.ssh/known_hosts"

    # 4. Create stanza + first full backup. Idempotent: stanza-create on an
    #    existing stanza is a no-op.
    log_info "Creating stanza '${stanza}' and running first full backup..."
    ssh_run "backup" "sudo -u ${PGBR_REPO_HOST_USER} pgbackrest --stanza=${stanza} stanza-create"
    ssh_run "storage" "sudo -u ${PGBR_PG_USER} pgbackrest --stanza=${stanza} check"
    ssh_run "backup" "sudo -u ${PGBR_REPO_HOST_USER} pgbackrest --stanza=${stanza} --type=full backup"

    log_success "PG install complete."
}

# ---------------------------------------------------------------------------
# pg_run — invoked by cron. Determines full vs diff from $1, defaults to diff.
# Type can also be passed via env PGBR_TYPE.
# ---------------------------------------------------------------------------
pg_run() {
    local type="${PGBR_TYPE:-${1:-diff}}"
    local stanza="$(cfg pg.stanza_name openg2p)"
    local started; started="$(ts_utc)"

    log_info "PG run: type=${type} stanza=${stanza}"
    local rc=0
    run_on_backup "sudo -u ${PGBR_REPO_HOST_USER} pgbackrest --stanza=${stanza} --type=${type} backup" \
        || rc=$?

    local result="ok"; (( rc != 0 )) && result="fail"
    pg_status_write "$started" "$result" "type=${type}"
    return $rc
}

# ---------------------------------------------------------------------------
# pg_verify — pgbackrest verify on the latest backup set.
# ---------------------------------------------------------------------------
pg_verify() {
    local stanza="$(cfg pg.stanza_name openg2p)"
    log_info "PG verify: stanza=${stanza}"
    run_on_backup "sudo -u ${PGBR_REPO_HOST_USER} pgbackrest --stanza=${stanza} verify"
}

# ---------------------------------------------------------------------------
# pg_list — show backup inventory.
# ---------------------------------------------------------------------------
pg_list() {
    local stanza="$(cfg pg.stanza_name openg2p)"
    run_on_backup "sudo -u ${PGBR_REPO_HOST_USER} pgbackrest --stanza=${stanza} info"
}

# ---------------------------------------------------------------------------
# pg_restore — PITR. Always restores into a temp directory on the storage
# node so we never overwrite the live PG without explicit operator action.
# ---------------------------------------------------------------------------
# Args: <target_unused> <point_in_time> <dry_run>
# Operator does the live cutover by reading the runbook at
# operations/deployment/automation/backups/restoration/postgres-pitr.md.
pg_restore() {
    local _target="$1"
    local pit="$2"
    local dry_run="$3"
    local stanza="$(cfg pg.stanza_name openg2p)"
    local restore_dir="/var/lib/openg2p-backup-restore/pg-$(date -u +%Y%m%dT%H%M%SZ)"

    if [[ -z "$pit" ]]; then
        log_warn "No --point-in-time supplied — restoring latest full+diff with no PITR."
    fi

    if [[ "$dry_run" == "true" ]]; then
        log_info "[dry-run] would restore stanza=${stanza} to ${restore_dir}"
        log_info "[dry-run] would invoke: pgbackrest --stanza=${stanza} ${pit:+--type=time --target=\"${pit}\"} --target-action=promote restore"
        return 0
    fi

    log_info "Restoring stanza=${stanza} to ${restore_dir} on storage node"
    ssh_run "storage" "set -euo pipefail
        install -d -o ${PGBR_PG_USER} -g ${PGBR_PG_USER} -m 0700 ${restore_dir}
        sudo -u ${PGBR_PG_USER} pgbackrest --stanza=${stanza} \
            ${pit:+--type=time --target=\"${pit}\"} \
            --target-action=promote \
            --pg1-path=${restore_dir} \
            restore"

    log_success "Restored to ${restore_dir} on storage node."
    log_warn "This is a STAGED restore. To make it the live cluster, follow the runbook:"
    log_warn "  operations/deployment/automation/backups/restoration/postgres-pitr.md"
}

# ---------------------------------------------------------------------------
# pg_drill — verify + dry-run restore + canary SELECT.
# Restores last full into a tempdir, starts a temporary PG, runs SELECT,
# tears down. Used by lib/drills.sh.
# ---------------------------------------------------------------------------
pg_drill() {
    local stanza="$(cfg pg.stanza_name openg2p)"
    local canary="$(cfg pg.canary_table)"
    local started; started="$(ts_utc)"
    local pg_version="$(cfg postgres_version 16)"
    local drill_dir="/var/lib/openg2p-backup-restore/drill-pg-$(date -u +%Y%m%dT%H%M%SZ)"

    log_info "PG drill: verify + dry-run restore (stanza=${stanza})"

    local rc=0

    # Step 1: verify
    run_on_backup "sudo -u ${PGBR_REPO_HOST_USER} pgbackrest --stanza=${stanza} verify" \
        || { pg_status_write_drill "$started" "fail" "verify failed"; return 1; }

    # Step 2: restore latest into a temp pg path
    ssh_run "storage" "set -euo pipefail
        install -d -o ${PGBR_PG_USER} -g ${PGBR_PG_USER} -m 0700 ${drill_dir}
        sudo -u ${PGBR_PG_USER} pgbackrest --stanza=${stanza} \
            --pg1-path=${drill_dir} --type=immediate --target-action=promote restore" \
        || { pg_status_write_drill "$started" "fail" "restore failed"; return 1; }

    # Step 3: optionally start a temp PG and run canary SELECT
    if [[ -n "$canary" ]]; then
        local tmp_port=55432
        # archive_mode=off on the drill instance: without it the restored
        # cluster inherits archive_command pointing at the LIVE stanza and
        # could push WAL into the real repo during the drill (corruption).
        ssh_run "storage" "set -euo pipefail
            sudo -u ${PGBR_PG_USER} /usr/lib/postgresql/${pg_version}/bin/pg_ctl \
                -D ${drill_dir} -o '-p ${tmp_port} -c archive_mode=off' -l ${drill_dir}/pg.log start
            sleep 5
            sudo -u ${PGBR_PG_USER} psql -p ${tmp_port} -c 'SELECT count(*) FROM ${canary};' postgres
            sudo -u ${PGBR_PG_USER} /usr/lib/postgresql/${pg_version}/bin/pg_ctl \
                -D ${drill_dir} stop -m fast" \
            || { pg_status_write_drill "$started" "fail" "canary SELECT failed"; rc=1; }
    fi

    # Step 4: cleanup
    ssh_run "storage" "rm -rf ${drill_dir}" || true

    if (( rc == 0 )); then
        pg_status_write_drill "$started" "ok" "verify+restore${canary:+ +canary}"
    fi
    return $rc
}

# ---------------------------------------------------------------------------
# Status file writers — small helpers so each module updates the JSON
# status file consistently.
# ---------------------------------------------------------------------------
pg_status_write() {
    local ts="$1" result="$2" details="$3"
    _status_write_component "pg" "last_run" "$ts" "$result" "$details"
}
pg_status_write_drill() {
    local ts="$1" result="$2" details="$3"
    _status_write_component "pg" "last_drill" "$ts" "$result" "$details"
}

# NOTE: _status_write_component lives in lib/utils.sh so every group module
# can call it without having to source pgbackrest.sh first. The cron wrapper
# sources exactly one group module — this function MUST be available from
# the foundation lib.
