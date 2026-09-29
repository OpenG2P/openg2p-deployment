#!/usr/bin/env bash
# =============================================================================
# OpenG2P Backup — Prometheus metrics (textfile + optional Pushgateway)
# =============================================================================
# Emits gauges under ${backup_repo_root}/metrics/ for node_exporter's textfile
# collector, and optionally POSTs the same payload to a Pushgateway (signoff
# pattern — useful when the backup host isn't scraped via node_exporter).
#
# Dead-man's switch: `openg2p_backup_master_last_success_timestamp` advances on
# any successful component run. Alert when time() - that > 26h.
# =============================================================================

set -euo pipefail

_metrics_dir() {
    echo "$(cfg backup_repo_root /var/lib/openg2p-backup)/metrics"
}

_metrics_enabled() {
    local v
    v="$(cfg monitoring.enabled false)"
    [[ "$v" == "true" || "$v" == "yes" || "$v" == "1" ]]
}

# metrics_emit_component_run <component> <result=ok|fail> <iso_ts>
metrics_emit_component_run() {
    _metrics_enabled || return 0
    local component="$1" result="$2" ts="$3"
    local status=0 epoch repo metrics_dir
    [[ "$result" == "ok" ]] && status=1
    epoch="$(date -u -d "$ts" +%s 2>/dev/null || date -u +%s)"
    repo="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    metrics_dir="${repo}/metrics"

    run_on_backup "set -euo pipefail
        dir='${metrics_dir}'
        install -d -m 0755 \"\$dir\"
        f=\"\$dir/openg2p-backup-${component}.prom\"
        tmp=\$(mktemp)
        {
            echo '# HELP openg2p_backup_run_status Last run status (1=ok, 0=fail).'
            echo '# TYPE openg2p_backup_run_status gauge'
            echo \"openg2p_backup_run_status{component=\\\"${component}\\\"} ${status}\"
            echo '# HELP openg2p_backup_run_timestamp_seconds Unix time of last run attempt.'
            echo '# TYPE openg2p_backup_run_timestamp_seconds gauge'
            echo \"openg2p_backup_run_timestamp_seconds{component=\\\"${component}\\\"} ${epoch}\"
        } > \"\$tmp\"
        if [[ ${status} -eq 1 ]]; then
            echo '# HELP openg2p_backup_last_success_timestamp Unix time of last successful component run.'
            echo '# TYPE openg2p_backup_last_success_timestamp gauge'
            echo \"openg2p_backup_last_success_timestamp{component=\\\"${component}\\\"} ${epoch}\" >> \"\$tmp\"
            {
                echo '# HELP openg2p_backup_master_last_success_timestamp Unix time of most recent successful backup across components.'
                echo '# TYPE openg2p_backup_master_last_success_timestamp gauge'
                echo \"openg2p_backup_master_last_success_timestamp ${epoch}\"
            } > \"\$dir/openg2p-backup-master.prom\"
        fi
        mv \"\$tmp\" \"\$f\"
        avail=\$(df -B1 --output=avail '${repo}' 2>/dev/null | tail -1 | tr -d ' ' || echo 0)
        {
            echo '# HELP openg2p_backup_disk_available_bytes Free bytes on backup repo filesystem.'
            echo '# TYPE openg2p_backup_disk_available_bytes gauge'
            echo \"openg2p_backup_disk_available_bytes \${avail:-0}\"
        } > \"\$dir/openg2p-backup-disk.prom\"
    " || true

    metrics_maybe_push || true
}

# metrics_emit_wal <size_bytes> <failed_count> <age_seconds>
metrics_emit_wal() {
    _metrics_enabled || return 0
    local size="$1" failed="$2" age="$3"
    local metrics_dir
    metrics_dir="$(_metrics_dir)"
    run_on_backup "set -euo pipefail
        dir='${metrics_dir}'
        install -d -m 0755 \"\$dir\"
        {
            echo '# HELP openg2p_pg_wal_size_bytes Size of PostgreSQL pg_wal directory on storage.'
            echo '# TYPE openg2p_pg_wal_size_bytes gauge'
            echo \"openg2p_pg_wal_size_bytes ${size}\"
            echo '# HELP openg2p_pg_archiver_failed_count pg_stat_archiver.failed_count.'
            echo '# TYPE openg2p_pg_archiver_failed_count gauge'
            echo \"openg2p_pg_archiver_failed_count ${failed}\"
            echo '# HELP openg2p_pg_archiver_last_archive_age_seconds Seconds since last archived WAL.'
            echo '# TYPE openg2p_pg_archiver_last_archive_age_seconds gauge'
            echo \"openg2p_pg_archiver_last_archive_age_seconds ${age}\"
        } > \"\$dir/openg2p-backup-wal.prom\"
    " || true
    metrics_maybe_push || true
}

metrics_maybe_push() {
    local url
    url="$(cfg monitoring.pushgateway_url "")"
    [[ -n "$url" ]] || return 0
    local instance metrics_dir
    instance="$(cfg monitoring.instance "$(cfg backup_private_ip backup-host)")"
    metrics_dir="$(_metrics_dir)"
    run_on_backup "set -euo pipefail
        dir='${metrics_dir}'
        [[ -d \$dir ]] || exit 0
        cat \"\$dir\"/*.prom 2>/dev/null | curl -sS --data-binary @- \
            \"${url%/}/metrics/job/openg2p-backup/instance/${instance}\" >/dev/null || true
    " || true
}

# Render + kubectl-apply PrometheusRule into cattle-monitoring-system (Rancher Monitoring).
# Skips cleanly when monitoring is disabled or the CRD/namespace is not yet present.
metrics_install_prometheusrule() {
    local apply
    apply="$(cfg monitoring.apply_prometheusrule true)"
    if ! _metrics_enabled; then
        log_info "monitoring.enabled=false — skip PrometheusRule"
        return 0
    fi
    if [[ "$apply" != "true" && "$apply" != "yes" && "$apply" != "1" ]]; then
        log_info "monitoring.apply_prometheusrule=false — skip PrometheusRule"
        return 0
    fi

    local ns instance raw_instance tmpl stage
    ns="$(cfg monitoring.namespace cattle-monitoring-system)"
    raw_instance="$(cfg monitoring.instance "")"
    [[ -n "$raw_instance" ]] || raw_instance="$(cfg cluster_name "")"
    [[ -n "$raw_instance" ]] || raw_instance="$(cfg backup_private_ip openg2p-backup)"
    # DNS-1123 subdomain: lowercase alnum and hyphens
    instance="$(printf '%s' "$raw_instance" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-50)"
    [[ -n "$instance" ]] || instance="openg2p-backup"

    tmpl="${BACKUPS_ROOT_DIR}/manifests/prometheusrule-backup.yaml.template"
    [[ -f "$tmpl" ]] || {
        log_warn "PrometheusRule template missing at ${tmpl}"
        return 0
    }

    log_info "Applying OpenG2P backup PrometheusRule → ${ns}/openg2p-backup-${instance}"

    # Preflight on compute: CRD + namespace must exist (Rancher Monitoring).
    if ! ssh_run "compute" "set -euo pipefail
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        kubectl get crd prometheusrules.monitoring.coreos.com >/dev/null
        kubectl get ns '${ns}' >/dev/null
    "; then
        log_warn "PrometheusRule CRD or namespace '${ns}' not found — Rancher Monitoring not ready; skip rule apply"
        return 0
    fi

    stage=$(mktemp -t openg2p-promrule.XXXXXX)
    sed -e "s|__BACKUP_INSTANCE__|${instance}|g" \
        -e "s|__MONITORING_NS__|${ns}|g" \
        "$tmpl" > "$stage"

    # Apply via compute (same pattern as rancher-backup manifests).
    local remote="/tmp/openg2p-backup-prometheusrule.yaml"
    push_file_as_root "compute" "$stage" "$remote" 0644
    rm -f "$stage"

    ssh_run "compute" "set -euo pipefail
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        kubectl apply -f '${remote}'
        kubectl -n '${ns}' get prometheusrule \"openg2p-backup-${instance}\" -o wide
    "
    log_success "PrometheusRule applied in ${ns}"
}
