#!/usr/bin/env bash
# =============================================================================
# OpenG2P Backup — storage node: pgBackRest client configuration
# =============================================================================
# Runs ON the storage node (under sudo) via ssh_run from the orchestrator.
# Inputs are passed as environment variables (see lib/pgbackrest.sh).
#
# What this does:
#   1. Install pgbackrest package
#   2. Trust the backup host's pgbackrest pubkey for the postgres user
#   3. Write /etc/pgbackrest/pgbackrest.conf
#   4. Edit postgresql.conf: archive_mode, archive_command, archive_timeout
#   5. Reload PostgreSQL
# Idempotent — safe to re-run.
# =============================================================================

set -euo pipefail

: "${PGBR_STANZA:?required}"
: "${PGBR_PG_VERSION:?required}"
: "${PGBR_PG_PORT:?required}"
: "${PGBR_PARALLEL:=4}"
: "${PGBR_ARCHIVE_TIMEOUT:=60}"
: "${PGBR_BACKUP_HOST_IP:?required}"
: "${PGBR_BACKUP_PUBKEY:?required}"
: "${PGBR_REPO_CIPHER_PASS:?required}"
: "${PGBR_REPO_PATH:?required}"
: "${PGBR_RETENTION_FULL:=4}"
: "${PGBR_RETENTION_DIFF:=7}"

PG_CONF="/etc/postgresql/${PGBR_PG_VERSION}/main/postgresql.conf"
PG_HBA="/etc/postgresql/${PGBR_PG_VERSION}/main/pg_hba.conf"
POSTGRES_HOME="/var/lib/postgresql"

echo "[storage/pg] Installing pgbackrest..."
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pgbackrest

echo "[storage/pg] Configuring SSH trust for postgres user..."
install -d -o postgres -g postgres -m 0700 "${POSTGRES_HOME}/.ssh"
touch "${POSTGRES_HOME}/.ssh/authorized_keys"
chown postgres:postgres "${POSTGRES_HOME}/.ssh/authorized_keys"
chmod 0600 "${POSTGRES_HOME}/.ssh/authorized_keys"
if ! grep -qF "${PGBR_BACKUP_PUBKEY}" "${POSTGRES_HOME}/.ssh/authorized_keys" 2>/dev/null; then
    echo "${PGBR_BACKUP_PUBKEY}" >> "${POSTGRES_HOME}/.ssh/authorized_keys"
    echo "[storage/pg] Added backup-host pgbackrest pubkey to postgres authorized_keys."
else
    echo "[storage/pg] Backup-host pubkey already trusted."
fi

# Generate the postgres user's OWN keypair. pgBackRest's archive_command runs
# as postgres and SSHes storage → pgbackrest@backup to push WAL; that needs a
# postgres keypair whose pubkey is authorized on the backup host. pg_install
# reads this pubkey afterward (it's the sole line on stdout tagged below).
if [[ ! -f "${POSTGRES_HOME}/.ssh/id_ed25519" ]]; then
    sudo -u postgres ssh-keygen -t ed25519 -N '' \
        -f "${POSTGRES_HOME}/.ssh/id_ed25519" -C "postgres@openg2p-storage"
fi
chmod 0600 "${POSTGRES_HOME}/.ssh/id_ed25519"

# Trust the backup host's host key (needed when archive_command pushes WAL via
# SSH to the repo host).
sudo -u postgres ssh-keyscan -H "${PGBR_BACKUP_HOST_IP}" 2>/dev/null \
    >> "${POSTGRES_HOME}/.ssh/known_hosts" || true
chmod 0600 "${POSTGRES_HOME}/.ssh/known_hosts" 2>/dev/null || true
chown postgres:postgres "${POSTGRES_HOME}/.ssh/known_hosts" 2>/dev/null || true

echo "[storage/pg] Writing /etc/pgbackrest/pgbackrest.conf..."
install -d -o postgres -g postgres -m 0750 /etc/pgbackrest /var/log/pgbackrest /var/spool/pgbackrest
cat > /etc/pgbackrest/pgbackrest.conf <<CONF
[global]
repo1-host=${PGBR_BACKUP_HOST_IP}
repo1-host-user=pgbackrest
repo1-path=${PGBR_REPO_PATH}
repo1-retention-full=${PGBR_RETENTION_FULL}
repo1-retention-diff=${PGBR_RETENTION_DIFF}
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=${PGBR_REPO_CIPHER_PASS}
process-max=${PGBR_PARALLEL}
log-level-console=info
log-level-file=detail
start-fast=y
compress-type=zst
compress-level=3
spool-path=/var/spool/pgbackrest
archive-async=y

[${PGBR_STANZA}]
pg1-path=/var/lib/postgresql/${PGBR_PG_VERSION}/main
pg1-port=${PGBR_PG_PORT}
CONF
chmod 0640 /etc/pgbackrest/pgbackrest.conf
chown root:postgres /etc/pgbackrest/pgbackrest.conf

echo "[storage/pg] Configuring postgresql.conf for WAL archiving..."
# Use ALTER SYSTEM-style postgresql.auto.conf override so we don't trample
# any operator edits in postgresql.conf itself.
# shellcheck disable=SC2016
sudo -u postgres psql -p "${PGBR_PG_PORT}" -d postgres <<SQL
ALTER SYSTEM SET wal_level = 'replica';
ALTER SYSTEM SET archive_mode = 'on';
ALTER SYSTEM SET archive_command = 'pgbackrest --stanza=${PGBR_STANZA} archive-push %p';
ALTER SYSTEM SET archive_timeout = '${PGBR_ARCHIVE_TIMEOUT}';
ALTER SYSTEM SET max_wal_senders = 10;
SQL

# archive_mode change requires a full restart, not just reload. Other
# settings reload fine. Detect whether a restart is needed (only the first
# time we run; on re-runs archive_mode is already 'on').
needs_restart=false
current_archive_mode=$(sudo -u postgres psql -p "${PGBR_PG_PORT}" -d postgres -tAc "SHOW archive_mode")
if [[ "$current_archive_mode" != "on" ]]; then
    needs_restart=true
fi

if [[ "$needs_restart" == "true" ]]; then
    echo "[storage/pg] archive_mode flipping on → full restart required."
    systemctl restart "postgresql@${PGBR_PG_VERSION}-main"
else
    echo "[storage/pg] archive_mode already on → reload only."
    systemctl reload "postgresql@${PGBR_PG_VERSION}-main"
fi

echo "[storage/pg] Done."
