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
RANCHER_BACKUP_RELEASE="rancher-backup"
RANCHER_BACKUP_ENC_SECRET="openg2p-backup-encryption"
RANCHER_CHARTS_REPO_URL="https://charts.rancher.io/"
# Stable name for BOTH the static NFS PersistentVolume and the operator's PVC.
RANCHER_BACKUP_PV="openg2p-rancher-backup-store"

# The backup-restore-operator stores tarballs to EITHER an S3 bucket OR a PVC
# mounted into the operator pod at /var/lib/backups (chart persistence.*). It
# has NO per-Backup "persistentVolumeClaim" storageLocation — Backup/Restore CRs
# simply OMIT storageLocation to use the operator's mounted PVC.
#
# IMPORTANT: with DYNAMIC persistence the chart names its PVC "<release>-
# <revision>" (see backupRestore.pvcName in the chart), so EVERY `helm upgrade`
# provisions a fresh, empty PVC, remounts it, and strands prior backups on the
# old volume. To keep a single, stable backup location we instead provision a
# STATIC NFS PV and bind the chart's PVC to it via persistence.volumeName (which
# also pins the PVC name), with persistence.storageClass="-" to turn OFF dynamic
# provisioning. The PVC still carries app.kubernetes.io/instance=<release>, so
# verify/restore resolve it by that label.

# ---------------------------------------------------------------------------
# rancher_install — runs on orchestrator (laptop). Drives compute via SSH.
# ---------------------------------------------------------------------------
rancher_install() {
    # rancher-charts publishes rancher-backup with the Rancher chart-version
    # scheme <chartVersion>+up<appVersion> — there is NO plain "7.0.0" chart, so
    # helm --version must be given a real chart version (e.g. 110.0.1+up11.0.2),
    # NOT the operator app version. Pin matches Rancher 2.15.x / RKE2 1.35
    # (OpenG2P default); older 107.x ships kuberlr-kubectl v5 which fails the
    # post-upgrade patch-sa Job on newer apiservers. Override via
    # versions.rancher_backup_chart.
    local chart_version="$(cfg versions.rancher_backup_chart 110.0.1+up11.0.2)"
    local resourceset_file="${BACKUPS_ROOT_DIR}/manifests/rancher-backup-resourceset.yaml"
    local schedule_file="${BACKUPS_ROOT_DIR}/manifests/rancher-backup-schedule.yaml"
    # Operator-mounted backup PVC: bound to a STATIC NFS PV (stable name, no
    # per-revision rotation). We read the NFS server/share from the cluster's
    # existing StorageClass so the backup volume lives on the same restic-tracked
    # NFS export.
    local pvc_storage_class="$(cfg rancher.pvc_storage_class nfs-csi)"
    local pvc_size="$(cfg rancher.pvc_size 50Gi)"

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

    cat > "$stage/namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${RANCHER_BACKUP_NS}
EOF

    log_info "Pushing manifests to compute node..."
    # Don't pre-create the dir via sudo — ssh_push makes it as the login user
    # and then chmods it; a root-owned dir would make that chmod fail. kubectl
    # apply (run via sudo below) can still read login-user-owned files.
    ssh_push "compute" "${stage}/" "/tmp/openg2p-rancher-backup/"

    # Determine the NFS server + base share from the cluster StorageClass so the
    # static backup PV lives on the same export the nfs restic job already tracks.
    log_info "Reading NFS server/share from StorageClass '${pvc_storage_class}'..."
    local nfs_info nfs_server nfs_share backup_path
    nfs_info=$(ssh_run "compute" "set -euo pipefail
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        s=\$(kubectl get sc ${pvc_storage_class} -o jsonpath='{.parameters.server}' 2>/dev/null || true)
        p=\$(kubectl get sc ${pvc_storage_class} -o jsonpath='{.parameters.share}' 2>/dev/null || true)
        echo \"\${s}|\${p}\"" | tail -1)
    nfs_server="${nfs_info%%|*}"
    nfs_share="${nfs_info#*|}"
    if [[ -z "$nfs_server" || -z "$nfs_share" ]]; then
        log_error "Could not read NFS server/share from StorageClass '${pvc_storage_class}'" \
                  "The static rancher-backup PV needs a concrete NFS server + path" \
                  "kubectl get sc ${pvc_storage_class} -o yaml"
        return 1
    fi
    backup_path="${nfs_share%/}/rancher-backup"
    log_info "rancher-backup will persist to ${nfs_server}:${backup_path}"

    # World-writable so the operator pod can write regardless of its runAsUser.
    log_info "Ensuring backup directory exists on storage node..."
    ssh_run "storage" "install -d -m 0777 '${backup_path}'"

    log_info "Installing rancher-backup operator (chart ${chart_version}) on compute..."
    ssh_run "compute" "set -euo pipefail
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        export PATH=\$PATH:/var/lib/rancher/rke2/bin:/usr/local/bin

        # Ensure the rancher-charts repo is added (production install adds
        # rancher-stable for Rancher itself, not necessarily rancher-charts).
        if ! helm repo list 2>/dev/null | awk '{print \$1}' | grep -qx 'rancher-charts'; then
            helm repo add rancher-charts ${RANCHER_CHARTS_REPO_URL}
        fi
        helm repo update rancher-charts >/dev/null 2>&1 || helm repo update >/dev/null 2>&1 || true

        kubectl apply -f /tmp/openg2p-rancher-backup/namespace.yaml
        kubectl apply -f /tmp/openg2p-rancher-backup/encryption-secret.yaml

        # Static NFS PV with a STABLE name. The chart binds its PVC to this via
        # persistence.volumeName, so the PVC name — and thus the on-disk backup
        # location — never rotates across helm upgrades.
        cat <<EOP | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${RANCHER_BACKUP_PV}
  labels:
    app.kubernetes.io/managed-by: openg2p-backup
spec:
  capacity:
    storage: ${pvc_size}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: \"\"
  nfs:
    server: ${nfs_server}
    path: ${backup_path}
EOP

        # Clear a stuck post-upgrade hook from a prior failed attempt so Helm
        # can recreate it (hook-delete-policy does not remove failed Jobs).
        kubectl -n ${RANCHER_BACKUP_NS} delete job ${RANCHER_BACKUP_RELEASE}-patch-sa --ignore-not-found >/dev/null 2>&1 || true

        helm upgrade --install rancher-backup-crd rancher-charts/rancher-backup-crd \
            --namespace ${RANCHER_BACKUP_NS} --version ${chart_version} --wait --timeout 10m

        # persistence.enabled + volumeName binds the operator PVC to our static
        # PV (stable name); storageClass='-' disables dynamic provisioning so the
        # chart does NOT create a per-revision '<release>-<revision>' PVC. Backup
        # CRs omit storageLocation and thus write to /var/lib/backups → our PV.
        # (Do NOT also set s3.enabled — the chart fails if both are configured.)
        # global.cattle.psp.enabled=false: PSP is gone on modern RKE2.
        helm_common=(
            upgrade --install rancher-backup rancher-charts/rancher-backup
            --namespace ${RANCHER_BACKUP_NS} --version ${chart_version}
            --set persistence.enabled=true
            --set persistence.storageClass=-
            --set persistence.volumeName=${RANCHER_BACKUP_PV}
            --set persistence.size=${pvc_size}
            --set global.cattle.psp.enabled=false
            --timeout 10m
        )

        if ! helm \"\${helm_common[@]}\" --wait; then
            echo '--- rancher-backup-patch-sa diagnosis ---' >&2
            kubectl -n ${RANCHER_BACKUP_NS} describe job ${RANCHER_BACKUP_RELEASE}-patch-sa >&2 || true
            kubectl -n ${RANCHER_BACKUP_NS} logs -l job-name=${RANCHER_BACKUP_RELEASE}-patch-sa --tail=80 >&2 || true
            kubectl -n ${RANCHER_BACKUP_NS} get pods -l job-name=${RANCHER_BACKUP_RELEASE}-patch-sa -o wide >&2 || true

            echo 'WARN: post-upgrade hook failed — applying SA patch manually and retrying helm --no-hooks' >&2
            kubectl -n ${RANCHER_BACKUP_NS} patch serviceaccount default \
                --type=merge -p '{\"automountServiceAccountToken\":false}' >/dev/null 2>&1 || true
            kubectl -n ${RANCHER_BACKUP_NS} delete job ${RANCHER_BACKUP_RELEASE}-patch-sa --ignore-not-found >/dev/null 2>&1 || true
            helm \"\${helm_common[@]}\" --wait --no-hooks
        fi

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
    # Prefer API group column. Fall back to parsing APIVERSION (group/version).
    known=$(ssh_run "compute" "kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml api-resources -o wide --no-headers 2>/dev/null \
        | awk '{
            # columns vary when SHORTNAMES empty; APIVERSION is the field containing '/'
            for (i=1;i<=NF;i++) if (\$i ~ /\//) { split(\$i,a,\"/\"); print a[1]; break }
          }' | sort -u" 2>/dev/null) || {
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
    local resourceset_file="${BACKUPS_ROOT_DIR}/manifests/rancher-backup-resourceset.yaml"

    # Rancher / rancher-backup-crd upgrades often wipe custom ResourceSets
    # (CRD reinstall). Re-apply ours before every on-demand Backup so we don't
    # burn 10 minutes retrying "openg2p-resource-set not found".
    if [[ ! -f "$resourceset_file" ]]; then
        log_error "Missing ${resourceset_file}" "" ""
        return 1
    fi
    log_info "Ensuring ResourceSet openg2p-resource-set is present..."
    local stage; stage=$(mktemp -d -t openg2p-rancher-rs.XXXXXX)
    trap "rm -rf '$stage'" RETURN
    cp "$resourceset_file" "$stage/resourceset.yaml"
    ssh_push "compute" "${stage}/" "/tmp/openg2p-rancher-backup/"
    if ! ssh_run "compute" "set -euo pipefail
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        export PATH=\$PATH:/var/lib/rancher/rke2/bin:/usr/local/bin
        # api-resources prints NAME + APIVERSION as separate columns — do not
        # grep for the full CRD name. Prefer get crd.
        if ! kubectl get crd resourcesets.resources.cattle.io >/dev/null 2>&1; then
            echo 'CRD resourcesets.resources.cattle.io missing — re-run: openg2p-backup.sh install --component rancher' >&2
            exit 1
        fi
        kubectl apply -f /tmp/openg2p-rancher-backup/resourceset.yaml
        kubectl get resourceset.resources.cattle.io openg2p-resource-set -o name"; then
        log_error "Could not apply ResourceSet openg2p-resource-set" \
                  "Common after Rancher/rancher-backup chart upgrades" \
                  "Re-run: ./openg2p-backup.sh install --config backup-config.yaml --component rancher --force"
        return 1
    fi

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
EOC
        # Wait up to 10 min. Break early on Ready=False OR a permanent
        # Reconciling error (e.g. ResourceSet missing) so we don't spin on Unknown/Retrying.
        ready='' msg='' recon_msg=''
        for i in \$(seq 1 60); do
            ready=\$(kubectl get backup.resources.cattle.io ${backup_name} \
                -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null || true)
            msg=\$(kubectl get backup.resources.cattle.io ${backup_name} \
                -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].message}' 2>/dev/null || true)
            recon_msg=\$(kubectl get backup.resources.cattle.io ${backup_name} \
                -o jsonpath='{.status.conditions[?(@.type==\"Reconciling\")].message}' 2>/dev/null || true)
            [[ \$ready == 'True' ]] && { echo \"rancher-backup Ready: \${msg:-ok}\"; exit 0; }
            [[ \$ready == 'False' ]] && break
            if [[ \$recon_msg == *'not found'* || \$recon_msg == *'Error'* ]]; then
                msg=\$recon_msg
                break
            fi
            sleep 10
        done
        echo \"rancher-backup not Ready (status='\${ready:-<none>}'): \${msg:-<no message>}\" >&2
        echo '--- backup describe ---' >&2
        kubectl describe backup.resources.cattle.io ${backup_name} >&2 || true
        echo '--- operator logs (tail 60) ---' >&2
        kubectl -n ${RANCHER_BACKUP_NS} logs -l app.kubernetes.io/instance=${RANCHER_BACKUP_RELEASE} --tail=60 >&2 || true
        exit 1" || rc=$?

    # Authoritative success check. The remote login-shell wrapper can, on some
    # nodes, corrupt the SSH exit status with environmental noise (no-TTY curses
    # errors in the profile) even after the backup itself succeeded. So when the
    # transport reports failure, confirm against the operator's own Ready
    # condition before declaring the run failed. The value on stdout is what we
    # trust here, not this probe's own exit code.
    if (( rc != 0 )); then
        local ready
        ready="$(ssh_run "compute" "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
            kubectl get backup.resources.cattle.io ${backup_name} \
                -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null" \
            | tail -1)"
        if [[ "$ready" == "True" ]]; then
            log_info "Backup ${backup_name} is Ready (recovered from a non-fatal SSH exit code)."
            rc=0
        fi
    fi

    local result="ok"; (( rc != 0 )) && result="fail"
    _status_write_component "rancher" "last_run" "$started" "$result" "$backup_name"
    return $rc
}

# _rancher_resolve_nfs_root — echo the on-server NFS path where the operator
# writes tarballs. stdout is ONLY the path (lines starting with /) so callers
# can safely `grep -E '^/'` to drop SSH/profile noise.
_rancher_resolve_nfs_root() {
    ssh_run "compute" "set -euo pipefail
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        export PATH=\$PATH:/var/lib/rancher/rke2/bin:/usr/local/bin

        # 1) Stable static PV (install --component rancher).
        p=\$(kubectl get pv ${RANCHER_BACKUP_PV} -o jsonpath='{.spec.nfs.path}' 2>/dev/null || true)
        if [[ -n \$p ]]; then echo \"\${p%/}\"; exit 0; fi

        # 2) Operator PVC — by label, then by stable name.
        pvc=\$(kubectl get pvc -n ${RANCHER_BACKUP_NS} \
            -l app.kubernetes.io/instance=${RANCHER_BACKUP_RELEASE} \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        if [[ -z \$pvc ]]; then
            pvc=\$(kubectl get pvc -n ${RANCHER_BACKUP_NS} ${RANCHER_BACKUP_PV} \
                -o jsonpath='{.metadata.name}' 2>/dev/null || true)
        fi
        [[ -z \$pvc ]] && { echo 'no rancher-backup PVC found' >&2; exit 1; }

        vol=\$(kubectl get pvc -n ${RANCHER_BACKUP_NS} \$pvc -o jsonpath='{.spec.volumeName}')
        [[ -z \$vol ]] && { echo 'rancher-backup PVC not bound yet' >&2; exit 1; }

        # Native NFS PV.
        p=\$(kubectl get pv \$vol -o jsonpath='{.spec.nfs.path}' 2>/dev/null || true)
        [[ -n \$p ]] && { echo \"\${p%/}\"; exit 0; }

        # CSI PV — share + subdir (reconstruct subdir when driver omits it).
        share=\$(kubectl get pv \$vol -o jsonpath='{.spec.csi.volumeAttributes.share}' 2>/dev/null || true)
        subdir=\$(kubectl get pv \$vol -o jsonpath='{.spec.csi.volumeAttributes.subdir}' 2>/dev/null || true)
        [[ -z \$subdir ]] && subdir=\"${RANCHER_BACKUP_NS}-\${pvc}-\${vol}\"
        if [[ -n \$share ]]; then echo \"\${share%/}/\${subdir}\"; exit 0; fi

        echo \"could not resolve NFS path for PV \${vol}\" >&2
        exit 1"
}

# ---------------------------------------------------------------------------
# rancher_verify — confirm the latest tarball exists, is non-zero, and is
# a readable gzip.
#
# Approach: resolve the PVC's on-server NFS path from kubectl, then gzip -t
# the latest *.tar.gz over SSH to the storage node. Much simpler than spawning
# a debug pod with `kubectl run --overrides`.
# ---------------------------------------------------------------------------
rancher_verify() {
    log_info "Verifying latest rancher-backup tarball..."

    # Keep only absolute-path lines — SSH/profile noise (blank lines, ncurses
    # errors) must not be mistaken for the export root.
    local root
    root=$(_rancher_resolve_nfs_root 2>/dev/null | grep -E '^/' | tail -1 || true)

    if [[ -z "$root" ]]; then
        log_error "Could not resolve the NFS path for rancher-backup storage" \
                  "Static PV '${RANCHER_BACKUP_PV}' may be missing, or the operator PVC is not bound" \
                  "Re-run: openg2p-backup.sh install --config <cfg> --component rancher"
        return 1
    fi
    log_info "rancher-backup NFS path: ${root}"

    # Search the resolved path and, for legacy CSI layouts, sibling subdirs
    # under the export root (per-revision PVCs from older installs).
    local export_root="${root%/*}"
    [[ "$export_root" == "$root" ]] && export_root="$root"

    ssh_run "storage" "set -euo pipefail
        shopt -s nullglob
        # encryptionConfigSecretName → operator writes *.tar.gz.enc (not plain .tar.gz).
        files=(\"${root}\"/*.tar.gz \"${root}\"/*.tar.gz.enc)
        if (( \${#files[@]} == 0 )); then
            files=('${export_root}'/${RANCHER_BACKUP_NS}-${RANCHER_BACKUP_RELEASE}-*/*.tar.gz \
                   '${export_root}'/${RANCHER_BACKUP_NS}-${RANCHER_BACKUP_RELEASE}-*/*.tar.gz.enc)
        fi
        if (( \${#files[@]} == 0 )); then
            echo 'No rancher-backup tarballs found at ${root}' >&2
            echo '--- ${root} (for debugging) ---' >&2
            ls -la \"${root}\"/ >&2 2>/dev/null || echo '(path not present on storage node)' >&2
            echo 'Run: openg2p-backup.sh run --component rancher  (trigger a backup first)' >&2
            exit 1
        fi
        latest=\"\${files[0]}\"
        for f in \"\${files[@]}\"; do [[ \$f -nt \$latest ]] && latest=\$f; done
        size=\$(stat -c %s \"\$latest\")
        if (( size < 100 )); then
            echo \"rancher tarball suspiciously small: \$size bytes (\$latest)\" >&2
            exit 1
        fi
        echo \"Latest: \$latest (\$size bytes)\"
        if [[ \$latest == *.enc ]]; then
            echo 'encrypted tarball present (gzip -t skipped — file is ciphertext)'
        else
            gzip -t \"\$latest\" && echo 'gzip integrity OK'
        fi"
}

# ---------------------------------------------------------------------------
# rancher_list — show Backup CRs.
# ---------------------------------------------------------------------------
rancher_list() {
    ssh_run "compute" "kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
        get backup.resources.cattle.io -A"
}

# ---------------------------------------------------------------------------
# rancher_restore — DR-aware: pull tarball from backup-host NFS restic, place
# on NEW storage NFS, apply Restore CR.
# Args: <target='cluster'|namespace> <cutoff_or_empty> <dry_run>
# ---------------------------------------------------------------------------
# --point-in-time / second arg = cutoff timestamp (ISO), e.g. '2026-07-22T00:00:00Z'
# or '2026-07-22'. Picks the newest rancher-backup *.tar.gz.enc in restic whose
# filename timestamp is strictly before the cutoff, copies it to the live
# rancher-backup NFS path, then applies a Restore CR (ignoreErrors=true).
#
# Without a cutoff, falls back to newest Backup CR filename already on the
# cluster (non-DR / same-cluster restore).
rancher_restore() {
    local target="${1:-cluster}"
    local cutoff="${2:-}"
    local dry_run="$3"
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local restic_pass_file
    restic_pass_file="$(ensure_passphrase_file restic_passphrase_file restic false)"
    local restic_pass; restic_pass="$(< "$restic_pass_file")"
    local storage_ip="$(cfg storage_private_ip)"

    local nfs_root
    # Tolerate ssh/logout noise: resolve may print the path then return non-zero
    # under pipefail if clear_console runs with set -e on the remote login shell.
    nfs_root="$(_rancher_resolve_nfs_root 2>/dev/null | grep -E '^/' | tail -1 || true)"
    [[ -n "$nfs_root" ]] || {
        log_error "Could not resolve rancher-backup NFS path" \
                  "Is the static PV openg2p-rancher-backup-store present?" \
                  "Try: kubectl get pv openg2p-rancher-backup-store -o yaml"
        return 1
    }
    log_info "rancher-backup NFS path on storage: ${nfs_root}"

    local latest=""
    if [[ -n "$cutoff" ]]; then
        log_info "DR mode: selecting rancher tarball from NFS restic before cutoff '${cutoff}'..."
        local cutoff_norm
        cutoff_norm=$(CUTOFF_RAW="$cutoff" python3 - <<'PY'
from datetime import datetime, timezone
import os, re, sys
raw = os.environ["CUTOFF_RAW"].strip().replace(" ", "T")
if re.fullmatch(r"\d{4}-\d{2}-\d{2}", raw):
    raw += "T00:00:00Z"
raw = raw.replace("Z", "+00:00")
try:
    dt = datetime.fromisoformat(raw)
except Exception:
    digits = re.sub(r"\D", "", os.environ["CUTOFF_RAW"])
    print(digits[:14] if digits else "")
    sys.exit(0)
if dt.tzinfo is None:
    dt = dt.replace(tzinfo=timezone.utc)
print(dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ"))
PY
)
        [[ -n "$cutoff_norm" ]] || {
            log_error "Could not parse cutoff '${cutoff}'" \
                      "Use e.g. 2026-07-22 or 2026-07-22T00:00:00Z" ""
            return 1
        }
        log_info "Normalized cutoff: ${cutoff_norm}"

        latest=$(run_on_backup "set -euo pipefail
            export RESTIC_REPOSITORY=${repo_root}/restic/nfs
            export RESTIC_PASSWORD='$(printf '%q' "$restic_pass")'
            CUTOFF='${cutoff_norm}'
            mapfile -t snaps < <(restic snapshots --tag nfs --json 2>/dev/null \
                | jq -r '.[].short_id' || true)
            (( \${#snaps[@]} > 0 )) || { echo 'No --tag nfs snapshots in restic' >&2; exit 1; }
            best=''
            best_ts=''
            best_sid=''
            for sid in \"\${snaps[@]}\"; do
                while IFS= read -r p; do
                    base=\$(basename \"\$p\")
                    [[ \$base == *.tar.gz.enc || \$base == *.tar.gz ]] || continue
                    ts=\$(echo \"\$base\" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z' | tail -1 || true)
                    [[ -n \$ts ]] || continue
                    if [[ \$ts < \$CUTOFF ]]; then
                        if [[ -z \$best_ts || \$ts > \$best_ts ]]; then
                            best=\$base
                            best_ts=\$ts
                            best_sid=\$sid
                        fi
                    fi
                done < <(restic ls \"\$sid\" 2>/dev/null | grep -E 'rancher-backup/[^/]+\\.tar\\.gz(\\.enc)?\$' || true)
            done
            [[ -n \$best ]] || { echo \"No rancher tarball in restic before cutoff \$CUTOFF\" >&2; exit 1; }
            echo \"\$best|\$best_sid|\$best_ts\"
        " | grep -E '\|' | tail -1) || {
            log_error "Failed to find a pre-cutoff rancher tarball in restic" \
                      "Check: restic snapshots --tag nfs; restic ls <id> | grep rancher-backup" \
                      "Cutoff was: ${cutoff_norm}"
            return 1
        }

        local tarball_base snap_id tarball_ts rest
        tarball_base="${latest%%|*}"
        rest="${latest#*|}"
        snap_id="${rest%%|*}"
        tarball_ts="${rest#*|}"
        log_info "Selected ${tarball_base} (ts=${tarball_ts}) from restic snapshot ${snap_id}"

        if [[ "$dry_run" == "true" ]]; then
            log_info "[dry-run] would restic-restore ${tarball_base} → ${nfs_root}/ on storage ${storage_ip}"
            log_info "[dry-run] would apply Restore CR backupFilename=${tarball_base} ignoreErrors=true"
            return 0
        fi

        log_info "Extracting tarball from restic on backup host and copying to new storage NFS..."
        local nfs_root_q dest_file_q tarball_q
        nfs_root_q=$(printf '%q' "$nfs_root")
        dest_file_q=$(printf '%q' "${nfs_root}/${tarball_base}")
        tarball_q=$(printf '%q' "$tarball_base")
        run_on_backup "set -euo pipefail
            export RESTIC_REPOSITORY=${repo_root}/restic/nfs
            export RESTIC_PASSWORD='$(printf '%q' "$restic_pass")'
            STAGE=\$(mktemp -d /tmp/openg2p-rancher-restore.XXXXXX)
            restic restore '${snap_id}' --target \"\$STAGE\" --include '*${tarball_base}*'
            FILE=\$(find \"\$STAGE\" -name ${tarball_q} -type f | head -1)
            [[ -n \$FILE && -s \$FILE ]] || { echo 'restic restore did not yield tarball' >&2; exit 1; }
            SSH_STOR=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
            if grep -q '^Host openg2p-storage' /root/.ssh/config 2>/dev/null; then
                SSH_STOR+=(openg2p-storage)
            else
                SSH_STOR+=(-i /root/.ssh/openg2p-backup-orch ubuntu@${storage_ip})
            fi
            DEST_DIR=${nfs_root_q}
            DEST_FILE=${dest_file_q}
            \"\${SSH_STOR[@]}\" \"sudo mkdir -p \$DEST_DIR\"
            sudo cat \"\$FILE\" | \"\${SSH_STOR[@]}\" \"sudo tee \$DEST_FILE >/dev/null\"
            \"\${SSH_STOR[@]}\" \"sudo chmod 0644 \$DEST_FILE; sudo ls -lh \$DEST_FILE\"
            rm -rf \"\$STAGE\"
        "
        latest="$tarball_base"
    else
        log_info "No cutoff supplied — using newest Backup CR filename on the cluster..."
        latest=$(ssh_run "compute" "kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
            get backup.resources.cattle.io -A -o jsonpath='{range .items[*]}{.status.filename}{\"\\n\"}{end}' \
            | sort | tail -1") || { log_error "Could not list backups" "" ""; return 1; }
        latest=$(echo "$latest" | tail -1)
        [[ -z "$latest" ]] && { log_error "No backup tarballs found" "" ""; return 1; }
        log_info "Latest tarball: ${latest}"
        log_warn "For full DR after storage rebuild, re-run with --point-in-time <cutoff> so the tarball is taken from backup-host restic onto the new NFS."
    fi

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
  name: openg2p-restore-\$(date -u +%Y%m%d%H%M%S)
spec:
  backupFilename: ${latest}
  encryptionConfigSecretName: ${RANCHER_BACKUP_ENC_SECRET}
  prune: false
  ignoreErrors: true
EOC"
    log_warn "Restore CR created (ignoreErrors=true). Watch progress:"
    log_warn "  kubectl get restore.resources.cattle.io -A -w"
    log_warn "After Done: patch native NFS PV server IPs if needed; CSI volumes — use nfs restore to push PVC data under Bound subDir."
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
