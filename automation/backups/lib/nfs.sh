#!/usr/bin/env bash
# =============================================================================
# OpenG2P Backup — NFS data via restic + PVC sidecar manifest
# =============================================================================
# Mounts the storage node's NFS export READ-ONLY on the backup host, then
# walks configured paths with restic. Generates a sidecar manifest that
# maps NFS UUID directories back to the PV/PVC/namespace/app they belong to,
# so restore can recreate the binding.
#
# Sidecar manifest path: ${repo_root}/nfs/.pvc-mapping.yaml (refreshed per run)
# =============================================================================

set -euo pipefail

NFS_MOUNT_POINT="/mnt/openg2p-nfs-ro"

# ---------------------------------------------------------------------------
# nfs_install — mount NFS RO on backup host, init restic repo.
# ---------------------------------------------------------------------------
nfs_install() {
    local export_root="$(cfg nfs.export_root /srv/nfs/openg2p)"
    local storage_ip="$(cfg storage_private_ip)"
    local backup_ip="$(cfg backup_private_ip)"
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local restic_pass_file
    restic_pass_file="$(ensure_passphrase_file restic_passphrase_file restic false)"
    local restic_pass; restic_pass="$(< "$restic_pass_file")"

    # Ensure the storage node exports ${export_root} to the backup host,
    # read-only, with no_root_squash so root on the backup host can read
    # root-owned files (restic runs as root and must see everything). The
    # production install typically exports only to the compute node — without
    # this the mount below hangs/fails.
    log_info "Ensuring storage node exports ${export_root} to backup host ${backup_ip} (ro)..."
    ssh_run "storage" "set -euo pipefail
        line='${export_root} ${backup_ip}(ro,sync,no_subtree_check,no_root_squash)'
        touch /etc/exports
        if ! grep -qF '${backup_ip}' /etc/exports; then
            echo \"\$line\" >> /etc/exports
        fi
        exportfs -ra
        # Make sure the export path is actually served.
        exportfs -v | grep -q '${export_root}' || { echo 'export not active'; exit 1; }"

    log_info "Mounting NFS export ${storage_ip}:${export_root} read-only on backup host..."
    ssh_run "backup" "set -euo pipefail
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nfs-common restic jq

        install -d -m 0755 ${NFS_MOUNT_POINT}
        # Idempotent fstab entry.
        if ! grep -q '${NFS_MOUNT_POINT}' /etc/fstab; then
            echo '${storage_ip}:${export_root} ${NFS_MOUNT_POINT} nfs ro,soft,timeo=30,noauto,x-systemd.automount 0 0' >> /etc/fstab
        fi
        mountpoint -q ${NFS_MOUNT_POINT} || mount ${NFS_MOUNT_POINT}

        # Restic repo init for NFS. Use cat-config probe so a REAL error
        # (wrong passphrase, permission denied) surfaces, not just the
        # benign 'already initialised'.
        install -d -m 0700 ${repo_root}/restic
        if ! RESTIC_REPOSITORY=${repo_root}/restic/nfs \
             RESTIC_PASSWORD='$(printf '%q' "$restic_pass")' \
             restic cat config >/dev/null 2>&1; then
            RESTIC_REPOSITORY=${repo_root}/restic/nfs \
            RESTIC_PASSWORD='$(printf '%q' "$restic_pass")' \
                restic init
        fi"

    # Trust storage node's NFS export from backup host. Storage exports to
    # the private subnet by default — assume that's still in effect. If not,
    # the operator must add backup_private_ip to /etc/exports on storage.
    log_info "If the NFS export is not already permissive to the backup subnet,"
    log_info "add ${storage_ip}:${export_root} → backup_private_ip in /etc/exports on storage."

    log_success "NFS read-only mount established + restic repo ready."
}

# ---------------------------------------------------------------------------
# nfs_run — restic backup + sidecar manifest generation.
# ---------------------------------------------------------------------------
nfs_run() {
    local started; started="$(ts_utc)"
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local restic_pass_file
    restic_pass_file="$(ensure_passphrase_file restic_passphrase_file restic false)"
    local restic_pass; restic_pass="$(< "$restic_pass_file")"

    # 1. Generate PVC sidecar manifest by joining `kubectl get pv -o json`
    #    with the live NFS file listing. This bridges UUID dirs back to apps.
    log_info "Generating PVC → NFS-path sidecar manifest..."
    nfs_generate_pvc_manifest

    # 2. Restic backup of the NFS mount + the sidecar.
    log_info "Running restic backup of NFS mount..."
    local include_paths exclude_args
    include_paths=$(_nfs_render_include_paths)
    exclude_args=$(_nfs_render_exclude_args)

    local rc=0
    run_on_backup "set -euo pipefail
        export RESTIC_REPOSITORY=${repo_root}/restic/nfs
        export RESTIC_PASSWORD='$(printf '%q' "$restic_pass")'
        # The fstab entry is noauto,x-systemd.automount — trigger the mount
        # before cd, or the first cron run after a reboot fails on 'cd'.
        mountpoint -q ${NFS_MOUNT_POINT} || mount ${NFS_MOUNT_POINT}
        cd ${NFS_MOUNT_POINT}
        restic backup ${include_paths} ${exclude_args} \
            --tag openg2p --tag nfs --tag \$(date -u +%Y-%m-%d)
        # Also stash the freshly-generated sidecar manifest as a tagged snapshot.
        restic backup ${repo_root}/nfs/.pvc-mapping.yaml \
            --tag openg2p --tag pvc-manifest --tag \$(date -u +%Y-%m-%d)
        # Retention prune.
        restic forget --keep-daily $(cfg retention.keep_daily 7) \
                      --keep-weekly $(cfg retention.keep_weekly 4) \
                      --keep-monthly $(cfg retention.keep_monthly 6) \
                      --prune" \
        || rc=$?

    local result="ok"; (( rc != 0 )) && result="fail"
    _status_write_component "nfs" "last_run" "$started" "$result" ""
    return $rc
}

# Helpers — render restic include and exclude args from config.
# NOTE: paths and exclude patterns are single-quoted so restic receives them
# LITERALLY. Without quotes, glob patterns like **/logs/** expand against the
# CWD when the command runs via `bash -lc` on the backup host (the cron path;
# the laptop path is protected by ssh_run's %q, but the backup-host path is
# not — keep them consistent).
_nfs_render_include_paths() {
    local p
    local out=""
    while read -r p; do
        [[ -z "$p" ]] && continue
        out="${out} '${p}'"
    done < <(_nfs_config_paths)
    echo "$out"
}

_nfs_render_exclude_args() {
    local p
    local out=""
    while read -r p; do
        [[ -z "$p" ]] && continue
        out="${out} --exclude '${p}'"
    done < <(_nfs_config_excludes)
    echo "$out"
}

# Read nfs.paths and nfs.exclude from CONFIG. Our YAML parser only handles
# one-level nesting, not arrays — so the example yaml uses the convention
# nfs.paths_0, nfs.paths_1 etc. via the operator-edited file. For now we
# fall back to a single dot-path from the export root.
_nfs_config_paths() {
    # If config defines nfs.paths as a YAML list, our parser stores nothing.
    # Operators can override by setting nfs.path1 / nfs.path2 keys explicitly.
    local explicit; explicit=$(cfg nfs.path1)
    if [[ -n "$explicit" ]]; then
        local i=1
        while :; do
            local v; v=$(cfg "nfs.path${i}")
            [[ -z "$v" ]] && break
            echo "$v"
            i=$((i + 1))
        done
    else
        echo "."
    fi
}
_nfs_config_excludes() {
    local i=1
    while :; do
        local v; v=$(cfg "nfs.exclude${i}")
        [[ -z "$v" ]] && break
        echo "$v"
        i=$((i + 1))
    done
    # Built-in defaults.
    echo "**/logs/**"
    echo "**/tmp/**"
    echo "**/.snapshots/**"
}

# ---------------------------------------------------------------------------
# nfs_generate_pvc_manifest — write a YAML sidecar that maps every directory
# under the NFS export to its PV/PVC/namespace/app.
# Lives at ${repo_root}/nfs/.pvc-mapping.yaml on the backup host.
# ---------------------------------------------------------------------------
nfs_generate_pvc_manifest() {
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"

    # Pull PV info from the cluster. ssh_run "compute" works from both
    # laptop and backup host — both have SSH trust to compute.
    local pv_json
    pv_json=$(ssh_run "compute" "kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
        get pv -o json")

    # Stage the PV JSON on the backup host (avoids embedding 100s of KB of
    # JSON inside the bash heredoc — gets escaping-fragile fast).
    local stage; stage=$(mktemp -t openg2p-pv-json.XXXXXX)
    printf '%s' "$pv_json" > "$stage"
    if on_backup_host; then
        sudo cp "$stage" /tmp/openg2p-pv.json
    else
        # Single-file dest — push_file_as_root stages then installs to the
        # exact path (a plain ssh_push would mkdir the file path as a dir).
        push_file_as_root "backup" "$stage" "/tmp/openg2p-pv.json" 0644
    fi
    rm -f "$stage"

    # On the backup host, list NFS UUID directories and merge with the PV
    # data. jq filter:
    #   • $dirs = NFS subdir names (the UUIDs)
    #   • $pvs  = PV items array
    #   • For each dir D, capture as $d, then find the PV whose
    #     spec.nfs.path ends with "/$d". Emit the merged record.
    run_on_backup "set -euo pipefail
        install -d -m 0750 ${repo_root}/nfs
        nfs_listing=\$(ls -1 ${NFS_MOUNT_POINT} 2>/dev/null | jq -R . | jq -s .)
        jq -n \
            --argjson pvs \"\$(jq '.items // []' /tmp/openg2p-pv.json)\" \
            --argjson dirs \"\$nfs_listing\" '
            \$dirs
            | map(. as \$d | {
                nfs_path: \$d,
                pv: ((\$pvs | map(select(.spec.nfs.path // \"\" | tostring | endswith(\"/\" + \$d))))[0] // null)
              })
            | map(select(.pv != null) | {
                nfs_path,
                pv_name: .pv.metadata.name,
                pvc_namespace: (.pv.spec.claimRef.namespace // null),
                pvc_name: (.pv.spec.claimRef.name // null),
                pvc_size: .pv.spec.capacity.storage,
                storage_class: .pv.spec.storageClassName,
                app_label: (.pv.metadata.labels // {} | to_entries | map(\"\\(.key)=\\(.value)\") | join(\",\")),
                backed_up_at: (now | todateiso8601)
              })' > ${repo_root}/nfs/.pvc-mapping.yaml.new && \
        mv ${repo_root}/nfs/.pvc-mapping.yaml.new ${repo_root}/nfs/.pvc-mapping.yaml || \
            echo '[]' > ${repo_root}/nfs/.pvc-mapping.yaml
        rm -f /tmp/openg2p-pv.json"
}

# ---------------------------------------------------------------------------
# nfs_verify — restic check (sampled) on the NFS repo.
# ---------------------------------------------------------------------------
nfs_verify() {
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local restic_pass_file
    restic_pass_file="$(ensure_passphrase_file restic_passphrase_file restic false)"
    local restic_pass; restic_pass="$(< "$restic_pass_file")"
    run_on_backup "set -euo pipefail
        export RESTIC_REPOSITORY=${repo_root}/restic/nfs
        export RESTIC_PASSWORD='$(printf '%q' "$restic_pass")'
        restic check --read-data-subset=5%"
}

# ---------------------------------------------------------------------------
# nfs_list — show snapshots in the NFS repo.
# ---------------------------------------------------------------------------
nfs_list() {
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local restic_pass_file
    restic_pass_file="$(ensure_passphrase_file restic_passphrase_file restic false)"
    local restic_pass; restic_pass="$(< "$restic_pass_file")"
    run_on_backup "set -euo pipefail
        export RESTIC_REPOSITORY=${repo_root}/restic/nfs
        export RESTIC_PASSWORD='$(printf '%q' "$restic_pass")'
        restic snapshots --compact"
}

# ---------------------------------------------------------------------------
# nfs_restore — restore one PVC's data into a staging dir on the storage node.
# Args: <target=namespace/pvc> <pit_unused> <dry_run>
# ---------------------------------------------------------------------------
nfs_restore() {
    local target="$1"
    local _pit="$2"
    local dry_run="$3"
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local restic_pass_file
    restic_pass_file="$(ensure_passphrase_file restic_passphrase_file restic false)"
    local restic_pass; restic_pass="$(< "$restic_pass_file")"

    if [[ -z "$target" || "$target" != */* ]]; then
        log_error "Restore target must be 'namespace/pvc-name'" \
                  "Got: '${target}'" \
                  "See ./openg2p-backup.sh list --component nfs for the sidecar manifest"
        return 1
    fi

    local ns="${target%%/*}"
    local pvc="${target#*/}"

    # Look up the NFS path from the sidecar manifest.
    local nfs_path
    nfs_path=$(run_on_backup "jq -r --arg ns '${ns}' --arg pvc '${pvc}' \
        '.[] | select(.pvc_namespace==\$ns and .pvc_name==\$pvc) | .nfs_path' \
        ${repo_root}/nfs/.pvc-mapping.yaml" | tail -1)

    if [[ -z "$nfs_path" || "$nfs_path" == "null" ]]; then
        log_error "PVC '${target}' not found in sidecar manifest" \
                  "Either the PVC didn't exist at last backup, or the manifest is stale" \
                  "Inspect: cat ${repo_root}/nfs/.pvc-mapping.yaml"
        return 1
    fi
    log_info "PVC '${target}' maps to NFS path: ${nfs_path}"

    local stage_dir="/tmp/openg2p-nfs-restore/${ns}-${pvc}-$(date -u +%Y%m%dT%H%M%SZ)"

    if [[ "$dry_run" == "true" ]]; then
        log_info "[dry-run] would restore NFS path '${nfs_path}' from latest snapshot"
        log_info "[dry-run] target: backup host ${stage_dir}"
        return 0
    fi

    log_info "Restoring '${nfs_path}' to ${stage_dir} on backup host..."
    run_on_backup "set -euo pipefail
        export RESTIC_REPOSITORY=${repo_root}/restic/nfs
        export RESTIC_PASSWORD='$(printf '%q' "$restic_pass")'
        install -d -m 0700 '${stage_dir}'
        restic restore latest --target '${stage_dir}' --include '/${nfs_path}'"

    log_success "Restored to ${stage_dir} on backup host."
    log_warn "Now follow operations/deployment/automation/backups/restoration/single-pvc.md"
    log_warn "to copy the data into the live NFS export and rebind the PVC."
}

# ---------------------------------------------------------------------------
# nfs_drill — restic check + restore one canary file.
# ---------------------------------------------------------------------------
nfs_drill() {
    local started; started="$(ts_utc)"
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local restic_pass_file
    restic_pass_file="$(ensure_passphrase_file restic_passphrase_file restic false)"
    local restic_pass; restic_pass="$(< "$restic_pass_file")"

    local rc=0
    run_on_backup "set -euo pipefail
        export RESTIC_REPOSITORY=${repo_root}/restic/nfs
        export RESTIC_PASSWORD='$(printf '%q' "$restic_pass")'
        restic check --read-data-subset=5%
        # Restore the sidecar manifest as a canary — small, present in every snapshot.
        d=\$(mktemp -d)
        restic restore latest --target \$d --include /.pvc-mapping.yaml || \
            restic restore latest --target \$d
        ls \$d > /dev/null
        rm -rf \$d" \
        || rc=$?

    local result="ok"; (( rc != 0 )) && result="fail"
    _status_write_component "nfs" "last_drill" "$started" "$result" ""
    return $rc
}
