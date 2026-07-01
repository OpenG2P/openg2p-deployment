#!/usr/bin/env bash
# =============================================================================
# OpenG2P Backup — etcd snapshots (RKE2 built-in) + optional encryption-at-rest
# =============================================================================
# RKE2 ships an `etcd-snapshot` controller. We just configure its schedule and
# rsync-pull the resulting files to the backup host.
#
# Snapshots live on the compute node at:
#   /var/lib/rancher/rke2/server/db/snapshots/
#
# Backup host receives them at:
#   ${repo_root}/etcd/<filename>
#
# Encryption-at-rest is opt-in (--enable-secret-encryption). When on:
#   • Generates AES-CBC key under /var/lib/rancher/rke2/server/cred/encryption-config.json
#   • Adds --kube-apiserver-arg=encryption-provider-config=... to RKE2 config
#   • Restarts rke2-server (apiserver unavailable ~30-60s, workloads OK)
#   • Re-writes existing Secrets through new encrypter so etcd is uniformly ciphertext
#
# Upstream:
#   https://docs.rke2.io/backup_restore
#   https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# etcd_install — runs on orchestrator. Configures RKE2 snapshot schedule on
# compute, sets up SSH trust + receive dir on backup host.
# ---------------------------------------------------------------------------
etcd_install() {
    local snapshot_count="$(cfg retention.etcd_snapshot_count 28)"
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local etcd_repo="${repo_root}/etcd"
    local backup_ip="$(cfg backup_private_ip)"

    log_info "Configuring RKE2 etcd snapshot schedule on compute node..."
    ssh_run "compute" "set -euo pipefail
        cfg=/etc/rancher/rke2/config.yaml
        [[ -f \$cfg ]] || { echo 'RKE2 config.yaml missing — is RKE2 installed?'; exit 1; }
        # Remove any prior snapshot keys (for idempotency) then append.
        sed -i '/^etcd-snapshot-/d' \$cfg
        cat >> \$cfg <<EOC
etcd-snapshot-schedule-cron: '0 */6 * * *'
etcd-snapshot-retention: ${snapshot_count}
etcd-snapshot-dir: '/var/lib/rancher/rke2/server/db/snapshots'
EOC
        systemctl restart rke2-server"

    log_info "Preparing receive directory on backup host..."
    ssh_run "backup" "install -d -m 0750 ${etcd_repo}"

    log_info "Setting up rsync pull from compute → backup..."
    # Generate (or reuse) an SSH key pair on the backup host that can SSH to
    # the compute node's root for pulling snapshot files. Snapshots are
    # readable only by root on RKE2.
    local backup_pubkey
    backup_pubkey=$(ssh_run "backup" "set -euo pipefail
        install -d -o root -g root -m 0700 /root/.ssh
        if [[ ! -f /root/.ssh/openg2p-etcd-pull ]]; then
            ssh-keygen -t ed25519 -N '' -f /root/.ssh/openg2p-etcd-pull -C 'openg2p-etcd-pull@backup'
        fi
        cat /root/.ssh/openg2p-etcd-pull.pub" | tail -1)

    # Authorize the backup host's pull key on compute's root. We intentionally
    # do NOT use a forced command="rsync ..." restriction: the exact rsync
    # --server flags vary by version so a hardcoded match breaks the pull, and
    # the etcd_restore path also needs scp TO compute (a forced rsync command
    # would block it). Keep the milder no-forwarding restrictions. The key is
    # dedicated and only reachable from within the private VPC.
    ssh_run "compute" "set -euo pipefail
        install -d -o root -g root -m 0700 /root/.ssh
        touch /root/.ssh/authorized_keys
        chmod 0600 /root/.ssh/authorized_keys
        grep -qF '${backup_pubkey}' /root/.ssh/authorized_keys || \
            echo 'no-port-forwarding,no-X11-forwarding,no-agent-forwarding ${backup_pubkey}' \
            >> /root/.ssh/authorized_keys"

    # Save compute IP for the rsync command at run time.
    ssh_run "backup" "echo '$(cfg compute_private_ip)' > /etc/openg2p-backup/etcd-source-ip"

    log_success "etcd snapshot schedule + pull pipeline configured."
}

# ---------------------------------------------------------------------------
# etcd_run — pull all snapshots that don't exist locally.
# ---------------------------------------------------------------------------
etcd_run() {
    local started; started="$(ts_utc)"
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local rc=0

    log_info "Pulling new etcd snapshots..."
    run_on_backup "set -euo pipefail
        compute_ip=\$(cat /etc/openg2p-backup/etcd-source-ip)
        rsync -av --ignore-existing \
            -e 'ssh -i /root/.ssh/openg2p-etcd-pull -o StrictHostKeyChecking=accept-new' \
            root@\${compute_ip}:/var/lib/rancher/rke2/server/db/snapshots/ \
            ${repo_root}/etcd/" \
        || rc=$?

    # Trim by age — RKE2 itself trims on the source per etcd-snapshot-retention,
    # but the backup host may keep them longer. Default: keep N most recent.
    local keep="$(cfg retention.etcd_snapshot_count 28)"
    run_on_backup "set -euo pipefail
        cd ${repo_root}/etcd
        ls -1t etcd-snapshot-* 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f"

    local result="ok"; (( rc != 0 )) && result="fail"
    _status_write_component "etcd" "last_run" "$started" "$result" ""
    return $rc
}

# ---------------------------------------------------------------------------
# etcd_verify — run etcdutl snapshot status on the latest pulled file.
# ---------------------------------------------------------------------------
etcd_verify() {
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    log_info "Verifying latest etcd snapshot..."
    run_on_backup "set -euo pipefail
        latest=\$(ls -1t ${repo_root}/etcd/etcd-snapshot-* 2>/dev/null | head -1)
        [[ -n \$latest ]] || { echo 'No etcd snapshots present'; exit 1; }
        # etcdutl ships in RKE2 — install standalone on backup host if needed.
        if ! command -v etcdutl >/dev/null 2>&1; then
            echo 'etcdutl missing on backup host. Install via:'
            echo '  apt install -y etcd-client   # provides etcdctl/etcdutl'
            exit 1
        fi
        etcdutl --write-out=table snapshot status \$latest"
}

# ---------------------------------------------------------------------------
# etcd_list — list pulled snapshot files newest first.
# ---------------------------------------------------------------------------
etcd_list() {
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    run_on_backup "ls -lh ${repo_root}/etcd/ | head -50"
}

# ---------------------------------------------------------------------------
# etcd_restore — does NOT actually restore in-place. Stages the snapshot to
# /tmp on the compute node and prints the runbook command for the operator
# to run manually under a maintenance window. In-place etcd restore wipes
# the cluster — too dangerous to automate from a generic CLI.
# ---------------------------------------------------------------------------
# Args: <target='latest'|filename> <pit_unused> <dry_run>
etcd_restore() {
    local target="${1:-latest}"
    local _pit="$2"
    local dry_run="$3"
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"

    local snap
    if [[ "$target" == "latest" ]]; then
        snap=$(run_on_backup "ls -1t ${repo_root}/etcd/etcd-snapshot-* | head -1" | tail -1)
    else
        snap="${repo_root}/etcd/${target}"
    fi
    log_info "Selected snapshot: ${snap}"

    if [[ "$dry_run" == "true" ]]; then
        log_info "[dry-run] would stage ${snap} to compute /tmp/openg2p-etcd-restore/"
        log_info "[dry-run] would print: rke2 server --cluster-reset --cluster-reset-restore-path=..."
        return 0
    fi

    ssh_run "compute" "install -d -m 0700 /tmp/openg2p-etcd-restore"
    run_on_backup "scp -i /root/.ssh/openg2p-etcd-pull \
        -o StrictHostKeyChecking=accept-new \
        ${snap} root@$(cfg compute_private_ip):/tmp/openg2p-etcd-restore/"

    log_warn "Snapshot staged on compute at /tmp/openg2p-etcd-restore/"
    log_warn "Etcd in-place restore is a CLUSTER RESET. Read the runbook before continuing:"
    log_warn "  operations/deployment/automation/backups/restoration/etcd-in-place.md"
    log_warn "When ready, run on the compute node:"
    log_warn "  systemctl stop rke2-server"
    log_warn "  rke2 server --cluster-reset --cluster-reset-restore-path=/tmp/openg2p-etcd-restore/$(basename "$snap")"
}

# ---------------------------------------------------------------------------
# etcd_drill — verify latest snapshot only (no restore — too disruptive).
# ---------------------------------------------------------------------------
etcd_drill() {
    local started; started="$(ts_utc)"
    if etcd_verify; then
        _status_write_component "etcd" "last_drill" "$started" "ok" "snapshot status verified"
        return 0
    else
        _status_write_component "etcd" "last_drill" "$started" "fail" "snapshot status check failed"
        return 1
    fi
}

# ===========================================================================
# Encryption-at-rest for Secrets (gated by --enable-secret-encryption)
# ===========================================================================
encryption_enable() {
    local key_file="$1"

    log_warn "Enabling etcd encryption-at-rest. This restarts kube-apiserver"
    log_warn "(brief — workloads keep running). Maintenance window recommended."

    # Read the key (single line, base64 already or raw — we re-encode to
    # the format Kubernetes expects: base64-encoded 32-byte key).
    local key_b64; key_b64="$(< "$key_file")"
    # If the user supplied raw bytes, base64 them; if already base64, leave.
    if ! echo "$key_b64" | base64 -d >/dev/null 2>&1; then
        key_b64="$(printf '%s' "$key_b64" | base64 -w0)"
    fi

    log_info "Pushing EncryptionConfiguration to compute node..."
    ssh_run "compute" "set -euo pipefail
        install -d -o root -g root -m 0700 /var/lib/rancher/rke2/server/cred
        cat > /var/lib/rancher/rke2/server/cred/encryption-config.json <<EOC
{
  \"kind\": \"EncryptionConfiguration\",
  \"apiVersion\": \"apiserver.config.k8s.io/v1\",
  \"resources\": [
    {
      \"resources\": [\"secrets\"],
      \"providers\": [
        { \"aescbc\": { \"keys\": [{ \"name\": \"openg2p\", \"secret\": \"${key_b64}\" }] } },
        { \"identity\": {} }
      ]
    }
  ]
}
EOC
        chmod 0600 /var/lib/rancher/rke2/server/cred/encryption-config.json

        # Add the apiserver flag to RKE2 config (idempotent).
        cfg=/etc/rancher/rke2/config.yaml
        if ! grep -q 'encryption-provider-config' \$cfg 2>/dev/null; then
            echo 'kube-apiserver-arg:' >> \$cfg
            echo '  - encryption-provider-config=/var/lib/rancher/rke2/server/cred/encryption-config.json' >> \$cfg
        fi

        systemctl restart rke2-server
        # Wait for apiserver to come back.
        for i in \$(seq 1 60); do
            kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get ns kube-system >/dev/null 2>&1 && break
            sleep 2
        done"

    log_info "Re-writing all existing Secrets through new encrypter (transparent to apps)..."
    ssh_run "compute" "kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
        get secrets --all-namespaces -o json | \
        kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml replace -f -"

    log_success "Etcd encryption-at-rest enabled. Apps see no change."
    log_warn "Custody reminder: ${key_file} is now load-bearing. LOSING IT = SECRETS UNRECOVERABLE FROM BACKUPS."
}
