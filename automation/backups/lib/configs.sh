#!/usr/bin/env bash
# =============================================================================
# OpenG2P Backup — config / filesystem-state via restic over SSH-tar streams
# =============================================================================
# Captures the small but critical files outside Kubernetes:
#
#   On RP node:
#     • /etc/wireguard/                (wg0.conf + peer keys per design)
#     • /etc/nginx/                    (vhost configs, includes)
#     • /etc/openg2p/                  (local CA, dnsmasq config, openg2p state)
#
#   On compute node:
#     • /var/lib/rancher/rke2/server/tls/    (cluster CA — restoring etcd
#                                              without this fails identity)
#     • /var/lib/rancher/rke2/server/cred/   (incl. encryption-config.json)
#     • /var/lib/rancher/rke2/server/token   (node-join secret)
#     • /etc/rancher/rke2/                   (config.yaml, registries.yaml)
#
# Each path is tar-streamed over SSH into restic on the backup host — no
# intermediate files. Single restic repo (configs) with tags for routing.
# =============================================================================

set -euo pipefail

# Per-source tar streams to capture. Format: source_role|tag|paths-space-sep
_CONFIGS_SOURCES=(
    "rp|wireguard|/etc/wireguard"
    "rp|nginx|/etc/nginx"
    "rp|openg2p|/etc/openg2p"
    "compute|rke2-tls|/var/lib/rancher/rke2/server/tls"
    "compute|rke2-cred|/var/lib/rancher/rke2/server/cred"
    "compute|rke2-token|/var/lib/rancher/rke2/server/token /var/lib/rancher/rke2/server/node-token"
    "compute|rke2-config|/etc/rancher/rke2"
)

# ---------------------------------------------------------------------------
# configs_install — apt-install restic + init the configs repo.
# ---------------------------------------------------------------------------
configs_install() {
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local restic_pass_file
    restic_pass_file="$(ensure_passphrase_file restic_passphrase_file restic false)"
    local restic_pass; restic_pass="$(< "$restic_pass_file")"

    log_info "Initialising configs restic repo on backup host..."
    # Note: we let "init on already-initialised repo" be a soft failure —
    # restic returns 1 with a clear message in that case. Real errors
    # (bad passphrase, permission denied) still surface in the log.
    ssh_run "backup" "set -euo pipefail
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq restic
        install -d -m 0700 ${repo_root}/restic
        if ! RESTIC_REPOSITORY=${repo_root}/restic/configs \
             RESTIC_PASSWORD='$(printf '%q' "$restic_pass")' \
             restic cat config >/dev/null 2>&1; then
            RESTIC_REPOSITORY=${repo_root}/restic/configs \
            RESTIC_PASSWORD='$(printf '%q' "$restic_pass")' \
                restic init
        fi"

    log_success "configs repo ready."
}

# ---------------------------------------------------------------------------
# configs_run — for each source, ssh node 'tar -cz <paths>' | ssh backup
# 'restic backup --stdin'. Tarred-then-piped is simpler than rsync here
# because the inputs are tiny and we want a single immutable snapshot.
# ---------------------------------------------------------------------------
configs_run() {
    local started; started="$(ts_utc)"
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local restic_pass_file
    restic_pass_file="$(ensure_passphrase_file restic_passphrase_file restic false)"
    local restic_pass; restic_pass="$(< "$restic_pass_file")"

    local entry
    local rc=0
    for entry in "${_CONFIGS_SOURCES[@]}"; do
        local source_role="${entry%%|*}"
        local rest="${entry#*|}"
        local tag="${rest%%|*}"
        local paths="${rest#*|}"

        log_info "Streaming ${source_role}:${paths} → configs repo (tag=${tag})"

        # Two execution shapes:
        #   • from laptop: producer SSH | consumer SSH (laptop → source) | (laptop → backup)
        #   • from backup host (cron): producer SSH | local restic
        # Both run the same producer side. Only the consumer differs.
        local resolved_src
        resolved_src="$(ssh_resolve_role "$source_role")"
        local src_user="${resolved_src%%|*}"
        local src_rest="${resolved_src#*|}"
        local src_host="${src_rest%%|*}"
        local src_key="${src_rest##*|}"

        local src_opts
        mapfile -t src_opts < <(ssh_options_for "$source_role")

        # Producer command (always SSH to the source role). sudo on source
        # for root-owned dirs (RKE2 paths).
        local producer=(ssh -i "$src_key" "${src_opts[@]}" "${src_user}@${src_host}" \
            "sudo tar -czf - --warning=no-file-changed ${paths} 2>/dev/null")

        # Consumer command depends on locality.
        local consumer_cmd="export RESTIC_REPOSITORY=${repo_root}/restic/configs;
            export RESTIC_PASSWORD='$(printf '%q' "$restic_pass")';
            restic backup --stdin --stdin-filename ${tag}.tar.gz \
                --tag openg2p --tag configs --tag ${tag} --tag $(date -u +%Y-%m-%d)"

        if on_backup_host; then
            # Pipe directly into local sudo bash on the backup host.
            "${producer[@]}" | sudo bash -c "$consumer_cmd" \
                || { rc=1; log_warn "stream failed for ${source_role}:${tag}"; }
        else
            # Pipe through a second SSH to the backup host.
            local resolved_dst; resolved_dst="$(ssh_resolve_role "backup")"
            local dst_user="${resolved_dst%%|*}"
            local dst_rest="${resolved_dst#*|}"
            local dst_host="${dst_rest%%|*}"
            local dst_key="${dst_rest##*|}"
            local dst_opts
            mapfile -t dst_opts < <(ssh_options_for "backup")

            "${producer[@]}" | \
            ssh -i "$dst_key" "${dst_opts[@]}" "${dst_user}@${dst_host}" \
                "sudo bash -c $(printf '%q' "$consumer_cmd")" \
                || { rc=1; log_warn "stream failed for ${source_role}:${tag}"; }
        fi
    done

    # Retention prune
    run_on_backup "set -euo pipefail
        export RESTIC_REPOSITORY=${repo_root}/restic/configs
        export RESTIC_PASSWORD='$(printf '%q' "$restic_pass")'
        restic forget --keep-daily $(cfg retention.keep_daily 7) \
                      --keep-weekly $(cfg retention.keep_weekly 4) \
                      --keep-monthly $(cfg retention.keep_monthly 6) \
                      --prune"

    local result="ok"; (( rc != 0 )) && result="fail"
    _status_write_component "configs" "last_run" "$started" "$result" ""
    return $rc
}

# ---------------------------------------------------------------------------
# configs_verify — restic check on the configs repo.
# ---------------------------------------------------------------------------
configs_verify() {
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local restic_pass_file
    restic_pass_file="$(ensure_passphrase_file restic_passphrase_file restic false)"
    local restic_pass; restic_pass="$(< "$restic_pass_file")"
    run_on_backup "set -euo pipefail
        export RESTIC_REPOSITORY=${repo_root}/restic/configs
        export RESTIC_PASSWORD='$(printf '%q' "$restic_pass")'
        restic check --read-data-subset=5%"
}

# ---------------------------------------------------------------------------
# configs_list — snapshots, grouped by tag.
# ---------------------------------------------------------------------------
configs_list() {
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local restic_pass_file
    restic_pass_file="$(ensure_passphrase_file restic_passphrase_file restic false)"
    local restic_pass; restic_pass="$(< "$restic_pass_file")"
    run_on_backup "set -euo pipefail
        export RESTIC_REPOSITORY=${repo_root}/restic/configs
        export RESTIC_PASSWORD='$(printf '%q' "$restic_pass")'
        restic snapshots --compact"
}

# ---------------------------------------------------------------------------
# configs_restore — restore one tagged stream (e.g. 'wireguard' or 'rke2-tls')
# to a staging dir on the backup host.
# Args: <target=tag> <pit=snapshot-id|'latest'> <dry_run>
# ---------------------------------------------------------------------------
configs_restore() {
    local target="$1"
    local pit="${2:-latest}"
    local dry_run="$3"
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local restic_pass_file
    restic_pass_file="$(ensure_passphrase_file restic_passphrase_file restic false)"
    local restic_pass; restic_pass="$(< "$restic_pass_file")"

    if [[ -z "$target" ]]; then
        log_error "configs restore needs --target <tag>" \
                  "Tags: wireguard nginx openg2p rke2-tls rke2-cred rke2-token rke2-config" \
                  "See ./openg2p-backup.sh list --component configs"
        return 1
    fi

    local stage_dir="/tmp/openg2p-configs-restore/${target}-$(date -u +%Y%m%dT%H%M%SZ)"

    if [[ "$dry_run" == "true" ]]; then
        log_info "[dry-run] would restore tag=${target} pit=${pit} to ${stage_dir}"
        return 0
    fi

    run_on_backup "set -euo pipefail
        export RESTIC_REPOSITORY=${repo_root}/restic/configs
        export RESTIC_PASSWORD='$(printf '%q' "$restic_pass")'
        # Pick the most recent snapshot with this tag.
        snap=\$(restic snapshots --tag '${target}' --json | jq -r '.[-1].id')
        [[ \$snap == 'null' || -z \$snap ]] && { echo \"No snapshot tagged '${target}'\"; exit 1; }
        install -d -m 0700 ${stage_dir}
        restic restore \$snap --target ${stage_dir}
        # Find the .tar.gz inside, extract to a sibling dir for inspection.
        cd ${stage_dir}
        tarball=\$(ls *.tar.gz 2>/dev/null | head -1)
        if [[ -n \$tarball ]]; then
            mkdir -p extracted
            tar -xzf \$tarball -C extracted
            echo \"Extracted to: ${stage_dir}/extracted\"
        fi
        ls -la ${stage_dir}"

    log_warn "Restored to ${stage_dir} on backup host. To install on target node:"
    case "$target" in
        wireguard|nginx|openg2p)
            log_warn "  scp -r contents to RP node, then restart wireguard/nginx as appropriate"
            ;;
        rke2-tls|rke2-cred|rke2-token|rke2-config)
            log_warn "  scp -r contents to compute node, used during cluster reset"
            log_warn "  See operations/deployment/automation/backups/restoration/etcd-in-place.md"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# configs_drill — restic check + restore-and-extract one stream as canary.
# ---------------------------------------------------------------------------
configs_drill() {
    local started; started="$(ts_utc)"
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local restic_pass_file
    restic_pass_file="$(ensure_passphrase_file restic_passphrase_file restic false)"
    local restic_pass; restic_pass="$(< "$restic_pass_file")"

    local rc=0
    run_on_backup "set -euo pipefail
        export RESTIC_REPOSITORY=${repo_root}/restic/configs
        export RESTIC_PASSWORD='$(printf '%q' "$restic_pass")'
        restic check --read-data-subset=5%
        # Canary: restore the openg2p tag (smallest, always present after install)
        d=\$(mktemp -d)
        snap=\$(restic snapshots --tag openg2p --json | jq -r '.[-1].id // empty')
        [[ -n \$snap ]] && restic restore \$snap --target \$d
        rm -rf \$d" \
        || rc=$?

    local result="ok"; (( rc != 0 )) && result="fail"
    _status_write_component "configs" "last_drill" "$started" "$result" ""
    return $rc
}
