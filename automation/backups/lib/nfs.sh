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
# Written on backup host when the canonical path is poisoned (post-DR EIO).
NFS_MOUNT_POINT_MARKER="/var/lib/openg2p-backup/.nfs-mount-point"

# _nfs_resolve_mount_point — effective RO mount path on the backup host.
_nfs_resolve_mount_point() {
    local marked
    marked="$(run_on_backup "cat ${NFS_MOUNT_POINT_MARKER} 2>/dev/null || true" | tr -d '\r\n' || true)"
    if [[ -n "${marked}" ]]; then
        printf '%s' "${marked}"
    else
        printf '%s' "${NFS_MOUNT_POINT}"
    fi
}

# _nfs_ensure_ro_mount — on backup host: drop stale mounts, refresh fstab, mount RO.
# After DR rebuild the storage private IP changes; a leftover mount to the old
# server returns EIO. x-systemd.automount makes this worse: any path access
# re-triggers the dead mount, so mkdir/chmod fail even after a soft umount.
_nfs_ensure_ro_mount() {
    local storage_ip="$1"
    local export_root="$2"
    run_on_backup "set -euo pipefail
        CANON='${NFS_MOUNT_POINT}'
        MARKER='${NFS_MOUNT_POINT_MARKER}'
        MP=\"\$CANON\"
        SRC='${storage_ip}:${export_root}'
        install -d -m 0755 \"\$(dirname \"\$MARKER\")\"

        _nfs_unit() {
            local path=\"\$1\" suffix=\"\$2\"
            if command -v systemd-escape >/dev/null 2>&1; then
                systemd-escape -p --suffix=\"\$suffix\" \"\$path\"
            fi
        }

        _nfs_stop_systemd() {
            local path=\"\$1\" u
            for u in \"\$(_nfs_unit \"\$path\" automount)\" \"\$(_nfs_unit \"\$path\" mount)\"; do
                [[ -n \"\$u\" ]] || continue
                systemctl stop \"\$u\" 2>/dev/null || true
                systemctl disable \"\$u\" 2>/dev/null || true
                systemctl reset-failed \"\$u\" 2>/dev/null || true
            done
        }

        # /proc/mounts is local — never hangs on a dead NFS server.
        _nfs_is_mounted() {
            local path=\"\$1\"
            awk -v p=\"\$path\" '\$2 == p { found=1 } END { exit !found }' /proc/mounts
        }

        _nfs_force_unmount() {
            local path=\"\$1\" i
            _nfs_stop_systemd \"\$path\"
            for i in 1 2 3 4 5; do
                if _nfs_is_mounted \"\$path\"; then
                    umount -f -l \"\$path\" 2>/dev/null || umount -l \"\$path\" 2>/dev/null || true
                    sleep 1
                else
                    break
                fi
            done
            while read -r tgt; do
                [[ -n \"\$tgt\" ]] || continue
                umount -f -l \"\$tgt\" 2>/dev/null || true
            done < <(awk -v p=\"\$path\" '\$2 == p || index(\$2, p \"/\") == 1 { print \$2 }' /proc/mounts)
        }

        _nfs_write_fstab() {
            local path=\"\$1\"
            if [[ ! -f /etc/fstab ]]; then
                return 0
            fi
            # Drop both canonical and fallback lines, then write the active path.
            # noauto+_netdev only (no x-systemd.automount) — cron/install mount explicitly.
            awk -v c=\"\$CANON\" -v f=\"\${CANON}-dr\" '
                \$2 != c && \$2 != f { print }
            ' /etc/fstab > /tmp/openg2p-fstab.new
            echo \"\${SRC} \${path} nfs ro,soft,timeo=30,retrans=2,noauto,_netdev 0 0\" >> /tmp/openg2p-fstab.new
            mv /tmp/openg2p-fstab.new /etc/fstab
            systemctl daemon-reload 2>/dev/null || true
        }

        _nfs_prepare_mountpoint() {
            local err
            if _nfs_is_mounted \"\$MP\"; then
                return 0
            fi
            err=\$(mkdir -p \"\$MP\" 2>&1) && chmod 0755 \"\$MP\" && return 0
            if grep -qi 'input/output error\\|i/o error' <<< \"\$err\"; then
                echo \"WARN: \${MP} dentry poisoned (EIO); switching to \${CANON}-dr\" >&2
                MP=\"\${CANON}-dr\"
                _nfs_write_fstab \"\$MP\"
                _nfs_force_unmount \"\$MP\"
                mkdir -p \"\$MP\"
                chmod 0755 \"\$MP\"
                return 0
            fi
            echo \"\$err\" >&2
            return 1
        }

        # Stop old automount before any path access, then rewrite fstab.
        _nfs_stop_systemd \"\$CANON\"
        _nfs_stop_systemd \"\${CANON}-dr\"
        _nfs_write_fstab \"\$MP\"
        _nfs_force_unmount \"\$CANON\"
        _nfs_force_unmount \"\${CANON}-dr\"

        _nfs_prepare_mountpoint

        if ! _nfs_is_mounted \"\$MP\"; then
            mount -t nfs -o ro,soft,timeo=30,retrans=2 \"\$SRC\" \"\$MP\"
        else
            if ! awk -v p=\"\$MP\" -v s=\"\$SRC\" '\$2 == p && index(\$1, s) == 1 { found=1 } END { exit !found }' /proc/mounts; then
                umount -f -l \"\$MP\" 2>/dev/null || true
                mount -t nfs -o ro,soft,timeo=30,retrans=2 \"\$SRC\" \"\$MP\"
            fi
        fi
        timeout 10 ls \"\$MP\" >/dev/null

        if [[ \"\$MP\" != \"\$CANON\" ]]; then
            printf '%s\n' \"\$MP\" > \"\$MARKER\"
        else
            rm -f \"\$MARKER\"
        fi
    "
}

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
    # root-owned files (restic runs as root and must see everything).
    _nfs_ensure_storage_export "$export_root" "$backup_ip" || return 1

    log_info "Mounting NFS export ${storage_ip}:${export_root} read-only on backup host..."
    ssh_run "backup" "set -euo pipefail
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nfs-common restic jq
    "
    _nfs_ensure_ro_mount "$storage_ip" "$export_root"

    ssh_run "backup" "set -euo pipefail
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

    log_success "NFS read-only mount established + restic repo ready."
}

# _nfs_ensure_storage_export — storage node must export RO to the backup host
# and (if ufw is active) allow NFS ports. Idempotent; safe to call from nfs_run
# after storage rebuild / firewall reset (common post-upgrade failure mode).
_nfs_ensure_storage_export() {
    local export_root="$1"
    local backup_ip="$2"
    log_info "Ensuring storage exports ${export_root} to backup host ${backup_ip} (ro)..."
    ssh_run "storage" "set -euo pipefail
        install -d -m 0755 '${export_root}'
        line='${export_root} ${backup_ip}(ro,sync,no_subtree_check,no_root_squash)'
        touch /etc/exports
        if ! grep -qF '${backup_ip}' /etc/exports; then
            echo \"\$line\" >> /etc/exports
        fi
        exportfs -ra
        exportfs -v | grep -q '${export_root}' || { echo 'export not active' >&2; exit 1; }

        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
            ufw allow from ${backup_ip} to any port 2049 proto tcp comment 'NFS from backup host'
            ufw allow from ${backup_ip} to any port 111  proto tcp comment 'rpcbind from backup host'
            ufw allow from ${backup_ip} to any port 111  proto udp comment 'rpcbind from backup host'
        fi

        # Confirm NFS server is listening (nfs-kernel-server / nfs-server).
        if systemctl is-active --quiet nfs-server 2>/dev/null \
           || systemctl is-active --quiet nfs-kernel-server 2>/dev/null; then
            true
        else
            systemctl start nfs-kernel-server 2>/dev/null \
              || systemctl start nfs-server 2>/dev/null \
              || { echo 'NFS server service not active' >&2; systemctl status nfs-kernel-server nfs-server 2>&1 | head -40 >&2; exit 1; }
        fi
    " || {
        log_error "Storage NFS export/firewall check failed for ${backup_ip}" \
                  "mount.nfs Connection timed out usually means ufw/security-group or nfs-server down" \
                  "Verify: ssh storage 'exportfs -v; ufw status; systemctl status nfs-kernel-server'"
        return 1
    }
}

# ---------------------------------------------------------------------------
# nfs_run — restic backup + sidecar manifest generation.
# ---------------------------------------------------------------------------
nfs_run() {
    local started; started="$(ts_utc)"
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local export_root="$(cfg nfs.export_root /srv/nfs/openg2p)"
    local storage_ip="$(cfg storage_private_ip)"
    local backup_ip="$(cfg backup_private_ip)"
    local restic_pass_file
    restic_pass_file="$(ensure_passphrase_file restic_passphrase_file restic false)"
    local restic_pass; restic_pass="$(< "$restic_pass_file")"

    # Re-assert export + firewall every run (storage rebuild / upgrade often
    # drops backup-host from /etc/exports and ufw → Connection timed out).
    _nfs_ensure_storage_export "$export_root" "$backup_ip" || return 1

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
    _nfs_ensure_ro_mount "$storage_ip" "$export_root" || {
        log_error "NFS mount failed for ${storage_ip}:${export_root}" \
                  "From backup host: showmount -e ${storage_ip}; ping ${storage_ip}" \
                  "Also check AWS SG / VPC NACL allows TCP 2049 from backup → storage"
        return 1
    }
    local nfs_mp
    nfs_mp="$(_nfs_resolve_mount_point)"

    run_on_backup "set -euo pipefail
        export RESTIC_REPOSITORY=${repo_root}/restic/nfs
        export RESTIC_PASSWORD='$(printf '%q' "$restic_pass")'
        mountpoint -q ${nfs_mp} || mount ${nfs_mp}
        cd ${nfs_mp}
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
    #   • For each dir D, capture as $d, then find the PV whose native
    #     spec.nfs.path ends with "/$d" OR whose CSI volumeAttributes.subdir
    #     equals $d (nfs-csi / nfs.csi.k8s.io PVs have no spec.nfs.path — the
    #     server-side location lives under .spec.csi.volumeAttributes). Emit
    #     the merged record.
    run_on_backup "set -euo pipefail
        install -d -m 0750 ${repo_root}/nfs
        MP=\$(cat ${NFS_MOUNT_POINT_MARKER} 2>/dev/null || echo ${NFS_MOUNT_POINT})
        mountpoint -q \"\$MP\" 2>/dev/null || mount \"\$MP\" 2>/dev/null || true
        nfs_listing=\$(ls -1 \"\$MP\" 2>/dev/null | jq -R . | jq -s .)
        jq -n \
            --argjson pvs \"\$(jq '.items // []' /tmp/openg2p-pv.json)\" \
            --argjson dirs \"\$nfs_listing\" '
            \$dirs
            | map(. as \$d | {
                nfs_path: \$d,
                pv: ((\$pvs | map(select(
                        (.spec.nfs.path // \"\" | tostring | endswith(\"/\" + \$d))
                        or ((.spec.csi.volumeAttributes.subdir // \"\") == \$d)
                        or (((.spec.claimRef.namespace // \"\") + \"-\" + (.spec.claimRef.name // \"\") + \"-\" + .metadata.name) == \$d)
                     )))[0] // null)
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
# nfs_restore — restic → stage on backup host → push onto live NFS on storage.
# Args: <target=namespace/pvc> <snapshot_or_unused> <dry_run>
# ---------------------------------------------------------------------------
# Like pg_restore (data lands on storage), this pushes restored PVC bytes to
# the Bound PV path on the NEW storage node — not only a /tmp stage.
#
# Each nfs_run writes TWO restic snapshots:
#   1) tag=nfs           — real export data
#   2) tag=pvc-manifest  — only .pvc-mapping.yaml (taken AFTER #1)
# Always prefer --tag nfs for data restores.
#
# Destination = Bound PV CSI subDir (or native NFS basename) when present, so
# post-DR pods (new UUID) receive the restored (old UUID) contents.
nfs_restore() {
    local target="$1"
    local snapshot="${2:-}"
    local dry_run="$3"
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local export_root="$(cfg nfs.export_root /srv/nfs/openg2p)"
    local storage_ip="$(cfg storage_private_ip)"
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

    local snap_ref="latest"
    local tag_args="--tag nfs"
    if [[ -n "$snapshot" ]]; then
        snap_ref="$snapshot"
        # Hex snapshot ids are exact; keep --tag nfs for "latest" only.
        if [[ "$snapshot" =~ ^[0-9a-fA-F]{8,}$ ]]; then
            tag_args=""
        fi
    fi

    # Source path inside restic (often pre-disaster UUID).
    local src_path
    src_path=$(run_on_backup "jq -r --arg ns '${ns}' --arg pvc '${pvc}' \
        '.[] | select(.pvc_namespace==\$ns and .pvc_name==\$pvc) | .nfs_path' \
        ${repo_root}/nfs/.pvc-mapping.yaml 2>/dev/null" | tail -1)
    [[ "$src_path" == "null" ]] && src_path=""

    # Live Bound destination on the NEW storage (post-DR UUID).
    local dest_path=""
    dest_path=$(ssh_run "compute" "set -euo pipefail
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        kubectl get pv -o json 2>/dev/null | jq -r --arg ns '${ns}' --arg pvc '${pvc}' '
          .items[]
          | select(.status.phase==\"Bound\")
          | select(.spec.claimRef.namespace==\$ns and .spec.claimRef.name==\$pvc)
          | (.spec.csi.volumeAttributes.subDir
             // (.spec.nfs.path // \"\" | split(\"/\") | last)
             // empty)
        ' | head -1" | grep -v '^$' | tail -1 || true)

    if [[ -z "$dest_path" ]]; then
        dest_path="$src_path"
        log_warn "No Bound PV for ${ns}/${pvc} — will push to sidecar path '${dest_path:-<unset>}'"
    else
        log_info "Bound PV destination on storage: ${export_root}/${dest_path}"
    fi

    local stage_dir="/tmp/openg2p-nfs-restore/${ns}-${pvc}-$(date -u +%Y%m%dT%H%M%SZ)"

    if [[ "$dry_run" == "true" ]]; then
        log_info "[dry-run] would restore from restic (src='${src_path:-auto}', snap=${snap_ref}) to ${stage_dir}"
        log_info "[dry-run] would push onto storage ${storage_ip}:${export_root}/${dest_path:-?}"
        return 0
    fi

    log_info "Restoring PVC ${ns}/${pvc} from restic on backup host..."
    run_on_backup "set -euo pipefail
        export RESTIC_REPOSITORY=${repo_root}/restic/nfs
        export RESTIC_PASSWORD='$(printf '%q' "$restic_pass")'
        install -d -m 0700 '${stage_dir}'

        SRC='${src_path}'
        # If sidecar path missing from snapshot (post-DR empty UUID), find old path by PVC name.
        if [[ -z \"\$SRC\" ]] || ! restic ls ${tag_args} '${snap_ref}' 2>/dev/null | grep -Fq \"\$SRC\"; then
            echo \"Looking up restic path containing '${pvc}'...\"
            SRC=\$(restic ls ${tag_args} '${snap_ref}' 2>/dev/null \
                | grep -F '${pvc}' \
                | sed -E 's|.*/([^/]*${pvc}[^/]*)/.*|\\1|;t;d' \
                | head -1 || true)
            # Prefer full directory basenames matching namespace-pvc- or *-pvc-*
            if [[ -z \"\$SRC\" ]]; then
                SRC=\$(restic ls ${tag_args} '${snap_ref}' 2>/dev/null \
                    | grep -E '/[^/]*${pvc}[^/]*/?\$' \
                    | sed -E 's|.*/||;s|/||g' \
                    | grep -F '${pvc}' \
                    | head -1 || true)
            fi
        fi
        if [[ -z \"\$SRC\" ]]; then
            # Broader: any path component with the pvc name
            SRC=\$(restic ls ${tag_args} '${snap_ref}' 2>/dev/null \
                | grep -F '${pvc}' | head -1 \
                | sed -E 's|^/+||;s|/mnt/openg2p-nfs-ro(-dr)?/||;s|/.*||' || true)
        fi
        [[ -n \"\$SRC\" ]] || {
            echo \"ERROR: could not find '${ns}/${pvc}' data in restic snapshot '${snap_ref}'\" >&2
            echo \"Try: restic snapshots --tag nfs --compact && restic ls <id> | grep ${pvc}\" >&2
            exit 1
        }
        echo \"Restic source path component: \$SRC\"
        printf '%s\\n' \"\$SRC\" > '${stage_dir}/.openg2p-src-path'

        restic restore ${tag_args} '${snap_ref}' --target '${stage_dir}' --include \"*\$SRC*\"

        count=\$(find '${stage_dir}' -mindepth 1 ! -name '.openg2p-src-path' | wc -l)
        (( count > 0 )) || { echo \"ERROR: empty restore at ${stage_dir}\" >&2; exit 1; }
        echo \"Staged \$count paths under ${stage_dir}\"
        du -sh '${stage_dir}'/* 2>/dev/null || du -sh '${stage_dir}'
    "

    # Locate the restored tree (inner UUID dir).
    local src_component data_dir
    src_component=$(run_on_backup "cat '${stage_dir}/.openg2p-src-path' 2>/dev/null" | tr -d '\r\n' | tail -1)
    data_dir=$(run_on_backup "set -euo pipefail
        if [[ -d '${stage_dir}/${src_component}' ]]; then echo '${stage_dir}/${src_component}'
        else find '${stage_dir}' -type d -name '${src_component}' | head -1
        fi" | grep '^/' | tail -1)

    [[ -n "$data_dir" ]] || {
        log_error "Could not locate restored data dir under ${stage_dir}" \
                  "src_component=${src_component}" ""
        return 1
    }
    [[ -n "$dest_path" ]] || dest_path="$src_component"

    log_info "Pushing restored data to storage ${storage_ip}:${export_root}/${dest_path} ..."
    # Quote paths on the laptop so the backup-host script has safe literals.
    local dest_q data_q
    dest_q=$(printf '%q' "${export_root}/${dest_path}")
    data_q=$(printf '%q' "${data_dir}")
    run_on_backup "set -euo pipefail
        DEST=${dest_q}
        SSH_STOR=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
        if grep -q '^Host openg2p-storage' /root/.ssh/config 2>/dev/null; then
            SSH_STOR+=(openg2p-storage)
        else
            SSH_STOR+=(-i /root/.ssh/openg2p-backup-orch ubuntu@${storage_ip})
        fi
        \"\${SSH_STOR[@]}\" \"sudo mkdir -p \$DEST && \
            if [ -n \\\"\\\$(ls -A \$DEST 2>/dev/null)\\\" ]; then \
              sudo rm -rf \$DEST.precrash; sudo mv \$DEST \$DEST.precrash; sudo mkdir -p \$DEST; \
            fi\"
        tar -C ${data_q} -czf - . | \"\${SSH_STOR[@]}\" \"sudo tar -C \$DEST -xzf -\"
        \"\${SSH_STOR[@]}\" \"sudo chown -R 1001:1001 \$DEST 2>/dev/null || true; sudo du -sh \$DEST\"
    "

    log_success "PVC ${ns}/${pvc} restored from restic and pushed to ${export_root}/${dest_path} on storage."
    log_warn "Bounce the workload so it remounts: kubectl -n ${ns} rollout restart deploy/sts as appropriate."
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
