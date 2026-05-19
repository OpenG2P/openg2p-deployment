#!/usr/bin/env bash
# =============================================================================
# OpenG2P Backup — rancher-backup operator (resource-level export)
# =============================================================================
# What this captures: the Kubernetes resources that DO NOT come back from a
# fresh helmfile install — Secrets (incl. Helm release Secrets, runtime TLS),
# ConfigMaps, PV/PVCs, Namespaces, ServiceAccounts, and curated CR groups
# (Rancher, cert-manager, Prometheus, Istio, Keycloak, Logging).
#
# Output: encrypted tarball nightly to a PVC on NFS. The NFS restic backup
# captures the tarball — single point of dedup/encryption downstream.
#
# Cadence is owned by the in-cluster Schedule CR (manifests/rancher-backup-
# schedule.yaml). The cron entry on the backup host is NOT used for nightly
# backups — that would double-trigger. `rancher_run` is for ad-hoc/before-
# upgrade invocation by the operator from the laptop.
#
# Upstream:
#   https://ranchermanager.docs.rancher.com/integrations-in-rancher/backup-restore-and-disaster-recovery
#   https://github.com/rancher/backup-restore-operator
# =============================================================================

set -euo pipefail

RANCHER_BACKUP_NS="cattle-resources-system"
RANCHER_BACKUP_PVC="openg2p-rancher-backup"
RANCHER_BACKUP_ENC_SECRET="openg2p-backup-encryption"
RANCHER_CHARTS_REPO_URL="https://charts.rancher.io/"

# ---------------------------------------------------------------------------
# rancher_install — runs on orchestrator (laptop). Drives compute via SSH.
# ---------------------------------------------------------------------------
rancher_install() {
    local chart_version="$(cfg versions.rancher_backup_chart 7.0.0)"
    local resourceset_file="${BACKUPS_ROOT_DIR}/manifests/rancher-backup-resourceset.yaml"
    local schedule_file="${BACKUPS_ROOT_DIR}/manifests/rancher-backup-schedule.yaml"

    log_info "Pre-flight: validating ResourceSet GVKs against live cluster..."
    rancher_validate_resourceset || log_warn "ResourceSet has unknown GVKs — see warnings above. Proceeding."

    # Build the encryption Secret YAML locally — far less fragile than
    # building it through 3 layers of bash heredoc escaping on the remote.
    local restic_pass_file
    restic_pass_file="$(ensure_passphrase_file restic_passphrase_file restic false)"
    local restic_pass; restic_pass="$(< "$restic_pass_file")"

    # Derive a 32-byte AES key from the restic passphrase (sha256 → 32 bytes).
    local key_b64
    key_b64=$(printf '%s' "$restic_pass" | openssl dgst -sha256 -binary 2>/dev/null | base64 | tr -d '\n')

    # The Secret holds an EncryptionConfiguration document, base64'd into the
    # data field (per upstream operator docs).
    local enc_doc enc_doc_b64
    enc_doc=$(cat <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: openg2p
              secret: ${key_b64}
      - identity: {}
EOF
)
    enc_doc_b64=$(printf '%s' "$enc_doc" | base64 | tr -d '\n')

    # Stage all manifests in a tmpdir, then push as one rsync.
    local stage; stage=$(mktemp -d -t openg2p-rancher-stage.XXXXXX)
    trap "rm -rf '$stage'" RETURN

    cp "$resourceset_file" "$stage/resourceset.yaml"
    cp "$schedule_file"    "$stage/schedule.yaml"

    cat > "$stage/encryption-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${RANCHER_BACKUP_ENC_SECRET}
  namespace: ${RANCHER_BACKUP_NS}
type: Opaque
data:
  encryption-provider-config.yaml: ${enc_doc_b64}
EOF

    cat > "$stage/pvc.yaml" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${RANCHER_BACKUP_PVC}
  namespace: ${RANCHER_BACKUP_NS}
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 50Gi
EOF

    cat > "$stage/namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${RANCHER_BACKUP_NS}
EOF

    log_info "Pushing manifests to compute node..."
    ssh_run "compute" "install -d -m 0750 /tmp/openg2p-rancher-backup"
    ssh_push "compute" "${stage}/" "/tmp/openg2p-rancher-backup/"

    log_info "Installing rancher-backup operator (chart ${chart_version}) on compute..."
    ssh_run "compute" "set -euo pipefail
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        export PATH=\$PATH:/var/lib/rancher/rke2/bin

        # Ensure the rancher-charts repo is added (production install adds
        # rancher-stable for Rancher itself, not necessarily rancher-charts).
        if ! helm repo list 2>/dev/null | awk '{print \$1}' | grep -qx 'rancher-charts'; then
            helm repo add rancher-charts ${RANCHER_CHARTS_REPO_URL}
        fi
        helm repo update rancher-charts >/dev/null 2>&1 || helm repo update >/dev/null 2>&1 || true

        kubectl apply -f /tmp/openg2p-rancher-backup/namespace.yaml
        kubectl apply -f /tmp/openg2p-rancher-backup/encryption-secret.yaml
        kubectl apply -f /tmp/openg2p-rancher-backup/pvc.yaml

        helm upgrade --install rancher-backup-crd rancher-charts/rancher-backup-crd \
            --namespace ${RANCHER_BACKUP_NS} --version ${chart_version} --wait
        helm upgrade --install rancher-backup rancher-charts/rancher-backup \
            --namespace ${RANCHER_BACKUP_NS} --version ${chart_version} --wait

        kubectl apply -f /tmp/openg2p-rancher-backup/resourceset.yaml
        kubectl apply -f /tmp/openg2p-rancher-backup/schedule.yaml"

    log_success "rancher-backup operator + ResourceSet + nightly Schedule installed."
    log_info "Nightly cadence is driven by the in-cluster Schedule CR; the"
    log_info "backup-host cron file deliberately has NO rancher entry to avoid"
    log_info "double-triggering. Use 'openg2p-backup.sh run --component rancher'"
    log_info "for ad-hoc backups (e.g. pre-upgrade)."
}

# ---------------------------------------------------------------------------
# rancher_validate_resourceset — list api-resources, warn on unknown GVKs.
# ---------------------------------------------------------------------------
rancher_validate_resourceset() {
    local known
    known=$(ssh_run "compute" "kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml api-resources --no-headers 2>/dev/null | awk '{print \$NF}' | sort -u" 2>/dev/null) || {
        log_warn "Could not query api-resources from compute — skipping validation."
        return 0
    }

    local groups; mapfile -t groups < <(grep -E '^\s+- apiVersion:' "${BACKUPS_ROOT_DIR}/manifests/rancher-backup-resourceset.yaml" | sed -E 's/.*"([^"]+)".*/\1/' | awk -F/ '{print $1}' | sort -u)
    local unknown=0
    for g in "${groups[@]}"; do
        [[ -z "$g" ]] && continue
        # 'v1' (core) is always present; skip.
        [[ "$g" == "v1" ]] && continue
        if ! grep -qx "$g" <<<"$known"; then
            log_warn "ResourceSet references unknown API group on this cluster: ${g}"
            unknown=$((unknown + 1))
        fi
    done
    (( unknown > 0 )) && return 1 || return 0
}

# ---------------------------------------------------------------------------
# rancher_run — trigger an on-demand Backup CR. ONLY for operator-initiated
# ad-hoc backups (pre-upgrade snapshots, etc.). Nightly cadence is owned by
# the in-cluster Schedule CR — this is NOT called from cron.
# ---------------------------------------------------------------------------
rancher_run() {
    local started; started="$(ts_utc)"
    local rc=0

    local backup_name="openg2p-ondemand-$(date -u +%Y%m%d%H%M%S)"
    log_info "Triggering on-demand Backup: ${backup_name}"

    ssh_run "compute" "set -euo pipefail
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        cat <<EOC | kubectl apply -f -
apiVersion: resources.cattle.io/v1
kind: Backup
metadata:
  name: ${backup_name}
spec:
  resourceSetName: openg2p-resource-set
  encryptionConfigSecretName: ${RANCHER_BACKUP_ENC_SECRET}
  storageLocation:
    persistentVolumeClaim:
      claimName: ${RANCHER_BACKUP_PVC}
EOC
        # Wait up to 10 min for completion.
        for i in \$(seq 1 60); do
            phase=\$(kubectl get backup.resources.cattle.io ${backup_name} -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null)
            [[ \$phase == 'True' ]] && exit 0
            sleep 10
        done
        echo 'rancher-backup did not become Ready in 10 minutes' >&2
        kubectl describe backup.resources.cattle.io ${backup_name} >&2
        exit 1" || rc=$?

    local result="ok"; (( rc != 0 )) && result="fail"
    _status_write_component "rancher" "last_run" "$started" "$result" "$backup_name"
    return $rc
}

# ---------------------------------------------------------------------------
# rancher_verify — confirm the latest tarball exists, is non-zero, and is
# a readable gzip.
#
# Approach: read the PVC's NFS path from kubectl (PV.spec.nfs.path), then
# tar -tzf the latest *.tar.gz over SSH to the storage node. Much simpler
# than spawning a debug pod with `kubectl run --overrides`.
# ---------------------------------------------------------------------------
rancher_verify() {
    log_info "Verifying latest rancher-backup tarball..."

    # Find the PV bound to our PVC and read its NFS path.
    local nfs_path
    nfs_path=$(ssh_run "compute" "kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
        get pvc -n ${RANCHER_BACKUP_NS} ${RANCHER_BACKUP_PVC} -o jsonpath='{.spec.volumeName}' \
        | xargs -I{} kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get pv {} -o jsonpath='{.spec.nfs.path}'" \
        | tail -1)

    if [[ -z "$nfs_path" ]]; then
        log_error "Could not resolve NFS path for PVC '${RANCHER_BACKUP_PVC}'" \
                  "PVC may not be bound yet, or the PV's StorageClass isn't NFS-based" \
                  "kubectl -n ${RANCHER_BACKUP_NS} get pvc ${RANCHER_BACKUP_PVC} -o yaml"
        return 1
    fi
    log_info "PVC bound to NFS path: ${nfs_path}"

    # The path is on the NFS export. From storage's local POV it's under
    # nfs_export_path (typically /srv/nfs/openg2p). The PV's nfs.path is
    # the EXPORTED path — same on storage's filesystem because the export
    # is a directory bind in /etc/exports.
    ssh_run "storage" "set -euo pipefail
        latest=\$(ls -1t ${nfs_path}/*.tar.gz 2>/dev/null | head -1)
        if [[ -z \$latest ]]; then
            echo 'No rancher-backup tarballs found yet at ${nfs_path}' >&2
            exit 1
        fi
        size=\$(stat -c %s \$latest)
        if (( size < 100 )); then
            echo \"Tarball is suspiciously small: \$size bytes\" >&2
            exit 1
        fi
        echo \"Latest: \$latest (\$size bytes)\"
        # Note: rancher-backup tarballs are encrypted when encryptionConfig is
        # set, so 'tar -tzf' won't list contents. We can at least confirm gzip
        # integrity with 'gzip -t'.
        gzip -t \$latest && echo 'gzip integrity OK'"
}

# ---------------------------------------------------------------------------
# rancher_list — show Backup CRs.
# ---------------------------------------------------------------------------
rancher_list() {
    ssh_run "compute" "kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
        get backup.resources.cattle.io -A"
}

# ---------------------------------------------------------------------------
# rancher_restore — apply a Restore CR pointing at the most recent tarball.
# Args: <target='cluster'|namespace> <pit_unused> <dry_run>
# ---------------------------------------------------------------------------
rancher_restore() {
    local target="${1:-cluster}"
    local _pit="$2"
    local dry_run="$3"

    log_info "Discovering most recent Backup tarball..."
    local latest
    latest=$(ssh_run "compute" "kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
        get backup.resources.cattle.io -A -o jsonpath='{range .items[*]}{.status.filename}{\"\\n\"}{end}' \
        | sort | tail -1") || { log_error "Could not list backups" "" ""; return 1; }
    latest=$(echo "$latest" | tail -1)
    [[ -z "$latest" ]] && { log_error "No backup tarballs found" "" ""; return 1; }
    log_info "Latest tarball: ${latest}"

    if [[ "$dry_run" == "true" ]]; then
        log_info "[dry-run] would create Restore CR consuming ${latest}"
        return 0
    fi

    ssh_run "compute" "set -euo pipefail
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        cat <<EOC | kubectl apply -f -
apiVersion: resources.cattle.io/v1
kind: Restore
metadata:
  name: openg2p-restore-$(date -u +%Y%m%d%H%M%S)
spec:
  backupFilename: ${latest}
  encryptionConfigSecretName: ${RANCHER_BACKUP_ENC_SECRET}
  storageLocation:
    persistentVolumeClaim:
      claimName: ${RANCHER_BACKUP_PVC}
EOC"
    log_warn "Restore CR created. Watch progress:"
    log_warn "  kubectl get restore.resources.cattle.io -A -w"
}

# ---------------------------------------------------------------------------
# rancher_drill — verify tarball integrity only.
# ---------------------------------------------------------------------------
rancher_drill() {
    local started; started="$(ts_utc)"
    if rancher_verify; then
        _status_write_component "rancher" "last_drill" "$started" "ok" "tarball integrity"
        return 0
    else
        _status_write_component "rancher" "last_drill" "$started" "fail" "tarball integrity"
        return 1
    fi
}
