#!/usr/bin/env bash
# =============================================================================
# OpenG2P AWS Add-Node Teardown — runs on your laptop
# =============================================================================
# Deletes ONLY the EC2 instance created by openg2p-aws-provision.sh
# (ManagedBy=openg2p-aws-add-node).
#
# Safety boundaries (never touched by this script):
#   • VPC, subnets, security groups (pre-existing / shared)
#   • Key pairs that were selected as "existing"
#   • Other cluster instances (ManagedBy=openg2p-aws-provision)
#
# Target resolution (first match wins):
#   1. --instance-id <id>
#   2. instance_id in provision-output.yaml
#   3. instance_name in aws-config.yaml (ManagedBy=openg2p-aws-add-node)
#   4. Interactive menu of ManagedBy=openg2p-aws-add-node instances
#
# Usage:
#   ./openg2p-aws-destroy.sh --config aws-config.yaml
#   ./openg2p-aws-destroy.sh --config aws-config.yaml --yes
#   ./openg2p-aws-destroy.sh --config aws-config.yaml --dry-run
#   ./openg2p-aws-destroy.sh --config aws-config.yaml --instance-id i-0abc...
# =============================================================================

set -euo pipefail

trap '
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "" >&2
        echo "[FATAL] script exited with status ${rc} at line ${LINENO} (${BASH_COMMAND})" >&2
        echo "[FATAL] log: ${LOG_FILE:-<not set>}" >&2
    fi
' EXIT

if (( BASH_VERSINFO[0] < 4 )); then
    echo "[FATAL] bash 4+ required (detected ${BASH_VERSION}). On macOS: brew install bash" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
ASSUME_YES=false
DRY_RUN=false
INSTANCE_ID_OVERRIDE=""
LOG_FILE="${SCRIPT_DIR}/logs/aws-add-node-destroy-$(date '+%Y%m%d-%H%M%S').log"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../production/lib/shared/utils.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/aws-utils.sh"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)       CONFIG_FILE="$2";          shift 2 ;;
            --instance-id)  INSTANCE_ID_OVERRIDE="$2"; shift 2 ;;
            --yes|-y)       ASSUME_YES=true;           shift ;;
            --dry-run)      DRY_RUN=true;              shift ;;
            --help|-h)      show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1" "" "Run with --help for usage"
                exit 1
                ;;
        esac
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        log_error "No config file specified" \
                  "--config is required" \
                  "Provide the same aws-config.yaml used for provisioning" \
                  "$0 --config aws-config.yaml"
        exit 1
    fi
    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
    export CONFIG_FILE
    export NON_INTERACTIVE="$ASSUME_YES"
    export DRY_RUN
}

show_help() {
    cat <<'EOF'
OpenG2P AWS Add-Node Teardown
=============================

Usage:
  ./openg2p-aws-destroy.sh --config aws-config.yaml [options]

Options:
  --config <file>         AWS add-node config (required)
  --instance-id <id>      Explicit instance to terminate (skips auto-detect)
  --yes / -y              Skip confirmation prompt
  --dry-run               Resolve the target and print what would be deleted;
                          do not terminate or remove provision-output.yaml
  --help, -h              Show this help

What gets deleted:
  • The single EC2 instance created by openg2p-aws-provision.sh
  • Stale provision-output.yaml

What is NEVER deleted:
  • Security groups, VPCs, subnets (shared / pre-existing)
  • Existing key pairs you selected during provisioning
  • Other cluster nodes (ManagedBy=openg2p-aws-provision)
EOF
}

main() {
    parse_args "$@"

    mkdir -p "${SCRIPT_DIR}/logs"
    exec > >(tee -a "$LOG_FILE") 2>&1

    log_banner "OpenG2P AWS Add-Node Teardown" "Deletes only the add-node EC2 instance"
    log_info "Config: ${CONFIG_FILE}"
    log_info "Log:    ${LOG_FILE}"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Mode:   dry-run (no resources will be destroyed)"
    fi
    echo ""

    load_config "$CONFIG_FILE"
    validate_config project region

    export AWS_REGION
    AWS_REGION="$(cfg region)"
    log_info "AWS region: ${AWS_REGION}"
    aws_check_credentials

    local project
    project=$(cfg project)
    log_info "Project: ${project}"

    # ── Resolve target ──────────────────────────────────────────────────
    log_step "1" "Resolve add-node instance to destroy"
    local target instance_id instance_name
    target=$(aws_resolve_destroy_target "$project" "$SCRIPT_DIR" "$INSTANCE_ID_OVERRIDE") \
        || exit 1
    instance_id="${target%%|*}"
    instance_name="${target#*|}"
    aws_require_nonempty "Instance ID" "$instance_id"

    local details
    details=$(aws_cli ec2 describe-instances --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].[InstanceType,PrivateIpAddress,PublicIpAddress,Placement.AvailabilityZone,State.Name]' \
        --output text 2>/dev/null || true)
    local itype="${details%%$'\t'*}"
    local rest="${details#*$'\t'}"
    local pip="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"
    local pubip="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"
    local az="${rest%%$'\t'*}"
    local state="${rest##*$'\t'}"

    cat <<EOF

╔════════════════════════════════════════════════════════════════════╗
║  About to TERMINATE this add-node instance                         ║
╠════════════════════════════════════════════════════════════════════╣
║  Instance ID:   ${instance_id}
║  Name:          ${instance_name}
║  Type:          ${itype}
║  State:         ${state}
║  AZ:            ${az}
║  Private IP:    ${pip}
║  Public IP:     ${pubip:-<none>}
║  Project:       ${project}
╚════════════════════════════════════════════════════════════════════╝

EOF

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would terminate ${instance_id} (${instance_name})"
        log_info "[dry-run] would remove provision-output.yaml if it points at this instance"
        log_success "Dry-run complete — nothing changed."
        return 0
    fi

    # ── Confirm ─────────────────────────────────────────────────────────
    if [[ "$ASSUME_YES" != "true" ]]; then
        log_warn "This permanently destroys the instance above. SGs/VPC/keys are kept."
        local typed
        read -rp "Type the instance name '${instance_name}' to confirm: " typed </dev/tty
        if [[ "$typed" != "$instance_name" ]]; then
            log_error "Confirmation mismatch. Aborting."
            exit 1
        fi
    else
        log_info "--yes set; skipping confirmation."
    fi

    # ── Terminate ───────────────────────────────────────────────────────
    log_step "2" "Terminate instance"
    aws_terminate_instance "$instance_id" "$instance_name"

    # ── Clean provision-output ──────────────────────────────────────────
    log_step "3" "Remove stale provision-output"
    local out
    out=$(aws_provision_output_path "$SCRIPT_DIR")
    if [[ -f "$out" ]]; then
        local out_id
        out_id=$(awk -F'"' '/^instance_id:/{print $2; exit}' "$out" 2>/dev/null || true)
        if [[ -z "$out_id" || "$out_id" == "$instance_id" ]]; then
            rm -f "$out" "${out}.prev"
            log_success "Removed ${out}"
        else
            log_warn "provision-output.yaml refers to ${out_id}, not ${instance_id} — leaving it."
        fi
    else
        log_info "No provision-output.yaml to remove."
    fi

    # Clear saved instance_name so the next provision run re-prompts.
    if [[ -n "$(cfg instance_name)" ]]; then
        aws_save_choice instance_name ""
    fi

    cat <<EOF

╔════════════════════════════════════════════════════════════════════╗
║  Add-node teardown complete                                        ║
╠════════════════════════════════════════════════════════════════════╣
║  Terminated: ${instance_id} (${instance_name})
║                                                                    ║
║  Preserved (intentionally):                                        ║
║    • Security groups / VPC / subnets                               ║
║    • Key pairs                                                     ║
║    • Other cluster instances (ManagedBy=openg2p-aws-provision)      ║
║                                                                    ║
║  Re-provision:                                                     ║
║    ./openg2p-aws-provision.sh --config aws-config.yaml             ║
║                                                                    ║
║  Log: ${LOG_FILE}
╚════════════════════════════════════════════════════════════════════╝

EOF
}

main "$@"
