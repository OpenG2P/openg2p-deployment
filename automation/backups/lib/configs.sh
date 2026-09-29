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
    # restic is usually already present from backup-host bootstrap / nfs_install.
    # Skip apt when possible — unattended-upgrades often holds the dpkg lock and
    # would abort DR install --force. Only init if the repo is missing (never
    # wipe an existing configs repo on a surviving backup node).
    ssh_run "backup" "set -euo pipefail
        if ! command -v restic >/dev/null 2>&1; then
            for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
                if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
                   && ! fuser /var/lib/dpkg/lock >/dev/null 2>&1; then
                    break
                fi
                echo \"Waiting for dpkg lock (attempt \$i/12)...\"
                sleep 10
            done
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq restic
        fi
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

    # Self-heal: repo may be missing after a fresh backup node or wiped disk.
    # Same idempotent init as configs_install (never overwrite an existing repo).
    run_on_backup "set -euo pipefail
        if ! command -v restic >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq restic
        fi
        install -d -m 0700 ${repo_root}/restic
        if ! RESTIC_REPOSITORY=${repo_root}/restic/configs \
             RESTIC_PASSWORD='$(printf '%q' "$restic_pass")' \
             restic cat config >/dev/null 2>&1; then
            echo 'Initialising configs restic repo...'
            RESTIC_REPOSITORY=${repo_root}/restic/configs \
            RESTIC_PASSWORD='$(printf '%q' "$restic_pass")' \
                restic init
        fi"

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
# configs_restore — restic → extract → push onto live node paths.
# Args: <target=tag> <pit=snapshot-id|'latest'|empty> <dry_run>
# ---------------------------------------------------------------------------
# RP tags (wireguard, nginx, openg2p) land on the RP node under /etc/...
# Compute tags (rke2-*) land on the compute node (needed for etcd reset).
#
# Snapshot selection MUST match stdin-filename /${target}.tar.gz — every
# configs snapshot also carries the global tag "openg2p", so
# `restic snapshots --tag openg2p` returns ALL streams (wrong for --target openg2p).
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

    local dest_role="" dest_paths="" ssh_host_alias="" dest_ip="" dest_user=""
    case "$target" in
        wireguard)   dest_role=rp;      dest_paths="/etc/wireguard"; ssh_host_alias=openg2p-rp ;;
        nginx)       dest_role=rp;      dest_paths="/etc/nginx";     ssh_host_alias=openg2p-rp ;;
        openg2p)     dest_role=rp;      dest_paths="/etc/openg2p";   ssh_host_alias=openg2p-rp ;;
        rke2-tls)    dest_role=compute; dest_paths="/var/lib/rancher/rke2/server/tls"; ssh_host_alias=openg2p-compute ;;
        rke2-cred)   dest_role=compute; dest_paths="/var/lib/rancher/rke2/server/cred"; ssh_host_alias=openg2p-compute ;;
        rke2-token)  dest_role=compute; dest_paths="/var/lib/rancher/rke2/server/token /var/lib/rancher/rke2/server/node-token"; ssh_host_alias=openg2p-compute ;;
        rke2-config) dest_role=compute; dest_paths="/etc/rancher/rke2"; ssh_host_alias=openg2p-compute ;;
        *)
            log_error "Unknown configs target '${target}'" \
                      "Tags: wireguard nginx openg2p rke2-tls rke2-cred rke2-token rke2-config" ""
            return 1
            ;;
    esac

    if [[ "$dest_role" == "rp" ]]; then
        dest_ip="$(cfg rp_private_ip)"
        dest_user="$(cfg rp_ssh_user ubuntu)"
    else
        dest_ip="$(cfg compute_private_ip)"
        dest_user="$(cfg compute_ssh_user ubuntu)"
    fi

    local stage_dir="/tmp/openg2p-configs-restore/${target}-$(date -u +%Y%m%dT%H%M%SZ)"
    local snap_ref="$pit"
    [[ -z "$snap_ref" || "$snap_ref" == "latest" ]] && snap_ref=""

    if [[ "$dry_run" == "true" ]]; then
        log_info "[dry-run] would restic-restore path=/${target}.tar.gz snap=${snap_ref:-latest} → ${stage_dir}"
        log_info "[dry-run] would push onto ${dest_role} ${dest_user}@${dest_ip} paths: ${dest_paths}"
        return 0
    fi

    log_info "Restoring configs tag=${target} from restic on backup host..."
    run_on_backup "set -euo pipefail
        export RESTIC_REPOSITORY=${repo_root}/restic/configs
        export RESTIC_PASSWORD='$(printf '%q' "$restic_pass")'
        if [[ -n '${snap_ref}' ]]; then
            snap='${snap_ref}'
        else
            # Match stdin-filename from configs_run (/wireguard.tar.gz etc.).
            # Do NOT use --tag openg2p alone — that tag is on every stream.
            snap=\$(restic snapshots --json \
                | jq -r --arg f '/${target}.tar.gz' \
                    '[.[] | select(.paths[]? == \$f)] | .[-1].id // empty')
        fi
        [[ -n \$snap && \$snap != null ]] || {
            echo \"No snapshot with path /${target}.tar.gz\" >&2
            restic snapshots --compact >&2 || true
            exit 1
        }
        echo \"Using restic snapshot \$snap\"
        install -d -m 0700 '${stage_dir}'
        restic restore \"\$snap\" --target '${stage_dir}'
        cd '${stage_dir}'
        tarball=\$(find . -name '${target}.tar.gz' | head -1)
        [[ -n \$tarball ]] || { echo 'No ${target}.tar.gz in restic restore' >&2; ls -laR; exit 1; }
        mkdir -p extracted
        tar -xzf \"\$tarball\" -C extracted
        echo \"Extracted to ${stage_dir}/extracted\"
        find extracted -maxdepth 4 -type d | head -40
        first='${dest_paths%% *}'
        if [[ ! -e \"extracted\${first}\" && ! -e \"extracted/\${first#/}\" ]]; then
            echo \"ERROR: extracted tree missing expected path \${first}\" >&2
            find extracted | head -50 >&2
            exit 1
        fi
    "

    log_info "Pushing ${target} onto ${dest_role} (${dest_ip}) → ${dest_paths} ..."
    # Expand paths on the laptop — avoids nested \${p} quoting through
    # laptop → backup → ssh → remote bash.
    local aside_cmds="" verify_cmds="" p
    for p in ${dest_paths}; do
        aside_cmds+="if [ -e $(printf '%q' "$p") ]; then sudo rm -rf $(printf '%q' "${p}.precrash"); sudo mv $(printf '%q' "$p") $(printf '%q' "${p}.precrash"); echo aside: ${p}; fi; "
        aside_cmds+="sudo mkdir -p $(printf '%q' "$(dirname "$p")"); "
        verify_cmds+="sudo ls -ld $(printf '%q' "$p") 2>/dev/null || sudo ls -l $(printf '%q' "$p") 2>/dev/null || true; "
    done
    local aside_q verify_q
    aside_q=$(printf '%q' "set -euo pipefail; ${aside_cmds}")
    verify_q=$(printf '%q' "set -euo pipefail; ${verify_cmds}")

    run_on_backup "set -euo pipefail
        EXTRACT='${stage_dir}/extracted'
        [[ -d \$EXTRACT ]] || { echo \"missing \$EXTRACT\" >&2; exit 1; }
        SSH_BASE=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
        if grep -q '^Host ${ssh_host_alias}' /root/.ssh/config 2>/dev/null; then
            SSH_CMD=(\"\${SSH_BASE[@]}\" ${ssh_host_alias})
        else
            SSH_CMD=(\"\${SSH_BASE[@]}\" -i /root/.ssh/openg2p-backup-orch ${dest_user}@${dest_ip})
        fi

        \"\${SSH_CMD[@]}\" ${aside_q}
        tar -C \"\$EXTRACT\" -czf - . | \"\${SSH_CMD[@]}\" 'sudo tar -C / -xzf -'
        \"\${SSH_CMD[@]}\" ${verify_q}
    "

    case "$target" in
        wireguard)
            log_info "Restarting WireGuard on RP..."
            ssh_run "rp" "sudo systemctl restart wg-quick@wg0 2>/dev/null || sudo systemctl restart wg-quick@wg0.service 2>/dev/null || true
                sudo wg show 2>/dev/null | head -20 || true" || true
            ;;
        nginx)
            log_info "Reloading nginx on RP..."
            ssh_run "rp" "sudo nginx -t && sudo systemctl reload nginx" || \
                log_warn "nginx reload failed — fix config then: systemctl reload nginx"
            ;;
        openg2p)
            log_info "Restarting dnsmasq (if present) on RP..."
            ssh_run "rp" "sudo systemctl restart dnsmasq 2>/dev/null || true" || true
            ;;
        rke2-*)
            log_warn "RKE2 FS state written on compute. Do not restart rke2 here — pair with etcd cluster-reset when needed."
            ;;
    esac

    log_success "configs '${target}' restored onto ${dest_role}:${dest_paths}"
    log_warn "Prior contents (if any) kept as *.precrash on that node."
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
