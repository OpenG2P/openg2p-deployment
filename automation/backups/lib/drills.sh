#!/usr/bin/env bash
# =============================================================================
# OpenG2P Backup — drills harness
# =============================================================================
# Runs every <group>_drill function for each enabled group, aggregates
# pass/fail, and updates the per-component status JSON. Surfaces a final
# pass/fail summary that the (Phase 2) alerting layer reads.
# =============================================================================

set -euo pipefail

drills_run_all() {
    log_info "Starting weekly drill across all enabled groups."
    local g
    local total_pass=0 total_fail=0 fails=()

    for g in $(enabled_groups); do
        log_step "DRILL" "$g"
        # shellcheck source=/dev/null
        load_group_module "$g"
        if "${g}_drill"; then
            log_success "${g} drill passed."
            total_pass=$((total_pass + 1))
        else
            log_warn "${g} drill FAILED."
            total_fail=$((total_fail + 1))
            fails+=("$g")
        fi
    done

    echo ""
    echo "============================================================"
    echo "Drill summary: ${total_pass} passed, ${total_fail} failed"
    if (( total_fail > 0 )); then
        echo "Failed components: ${fails[*]}"
        echo "Status: ./openg2p-backup.sh status --config ${CONFIG_FILE:-backup-config.yaml}"
        echo "============================================================"
        return 1
    fi
    echo "All enabled components verified."
    echo "============================================================"
    return 0
}
