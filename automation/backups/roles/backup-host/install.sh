#!/usr/bin/env bash
# =============================================================================
# OpenG2P Backup — backup-host bootstrap (apt + repo dirs + env file + cron)
# =============================================================================
# Runs ON the backup host (under sudo) via ssh_run from the orchestrator.
# Inputs:
#   $1 — restic passphrase (raw string)
#   $2 — pgbackrest passphrase (raw string)
#   ENV: BACKUP_REPO_ROOT
# =============================================================================

set -euo pipefail

RESTIC_PASS="${1:-}"
PGBR_PASS="${2:-}"
BACKUP_REPO_ROOT="${BACKUP_REPO_ROOT:-/var/lib/openg2p-backup}"

[[ -n "$RESTIC_PASS" ]]   || { echo "missing restic passphrase arg"; exit 1; }
[[ -n "$PGBR_PASS"   ]]   || { echo "missing pgbackrest passphrase arg"; exit 1; }

echo "[backup-host] apt install: pgbackrest restic rsync nfs-common jq curl etcd-client"
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    pgbackrest restic rsync nfs-common jq curl etcd-client

echo "[backup-host] creating repo layout under ${BACKUP_REPO_ROOT}"
# The repo ROOT is 0755 (traversable by all) so non-root service users — the
# 'pgbackrest' user that owns ${BACKUP_REPO_ROOT}/pg — can reach their subdir.
# Sensitive content stays protected by the subdirs' own perms (restic dirs are
# root-only; pg is owned by the pgbackrest user).
install -d -o root -g root -m 0755 "${BACKUP_REPO_ROOT}"
install -d -o root -g root -m 0750 \
    "${BACKUP_REPO_ROOT}/pg" \
    "${BACKUP_REPO_ROOT}/etcd" \
    "${BACKUP_REPO_ROOT}/restic" \
    "${BACKUP_REPO_ROOT}/restic/nfs" \
    "${BACKUP_REPO_ROOT}/restic/configs" \
    "${BACKUP_REPO_ROOT}/nfs" \
    /etc/openg2p-backup

echo "[backup-host] writing passphrase files (mode 0600)"
umask 0177
printf '%s\n' "$RESTIC_PASS" > /etc/openg2p-backup/restic.pass
printf '%s\n' "$PGBR_PASS"   > /etc/openg2p-backup/pgbackrest.pass
umask 0022

cat > /etc/openg2p-backup/env <<EOF
# Sourced by cron entries.
RESTIC_REPO_ROOT=${BACKUP_REPO_ROOT}/restic
RESTIC_PASSWORD_FILE=/etc/openg2p-backup/restic.pass
PGBR_PASSWORD_FILE=/etc/openg2p-backup/pgbackrest.pass
KEEP_DAILY=${KEEP_DAILY:-7}
KEEP_WEEKLY=${KEEP_WEEKLY:-4}
KEEP_MONTHLY=${KEEP_MONTHLY:-6}
EOF

# Initial empty status file so the `status` subcommand always finds something.
[[ -f ${BACKUP_REPO_ROOT}/.status.json ]] || \
    echo '{"components":{}}' > "${BACKUP_REPO_ROOT}/.status.json"

echo "[backup-host] bootstrap complete."
