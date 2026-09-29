#!/usr/bin/env bash
# =============================================================================
# OpenG2P AWS Sandbox Teardown — runs on your laptop
# =============================================================================
# Destroys resources created by openg2p-aws-provision.sh:
#   instances, EIP, security groups, and (optionally) the key pair —
# all tagged Project=<project> AND ManagedBy=openg2p-aws-single-node.
#
# Only deletes resources tagged ManagedBy=openg2p-aws-single-node.
#
# Requires explicit confirmation by typing the project name back.
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
KEEP_KEY=false
ASSUME_YES=false
DRY_RUN=false
LOG_FILE="${SCRIPT_DIR}/logs/aws-sandbox-destroy-$(date '+%Y%m%d-%H%M%S').log"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../production/lib/shared/utils.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/aws-utils.sh"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)    CONFIG_FILE="$2"; shift 2 ;;
            --keep-key)  KEEP_KEY=true;    shift ;;
            --yes|-y)    ASSUME_YES=true;  shift ;;
            --dry-run)   DRY_RUN=true;     shift ;;
            --help|-h)
                cat <<'EOF'
OpenG2P AWS Sandbox Teardown

Usage:
  ./openg2p-aws-destroy.sh --config aws-config.yaml [options]

Options:
  --config <file>  AWS config (required)
  --keep-key       Keep the key pair (and local .pem)
  --yes / -y       Don't prompt for confirmation
  --dry-run        List what would be deleted; do not destroy anything
  --help, -h       Show this help

What gets deleted (Project=<project> AND ManagedBy=openg2p-aws-single-node):
  • EC2 instance(s)
  • Elastic IP(s)
  • Security group(s)
  • Script-created key pair (unless --keep-key)
  • Stray volumes / snapshots / ENIs with those tags
  • ../provision-output.yaml

What is NEVER deleted:
  • Production cluster resources (ManagedBy=openg2p-aws-provision)
  • Add-node instances (ManagedBy=openg2p-aws-add-node)
  • VPC / subnets
  • Pre-existing key pairs you selected as "existing"
EOF
                exit 0
                ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done
    [[ -z "$CONFIG_FILE" ]] && { log_error "--config is required"; exit 1; }
    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
}

main() {
    parse_args "$@"

    mkdir -p "${SCRIPT_DIR}/logs"
    exec > >(tee -a "$LOG_FILE") 2>&1

    log_banner "OpenG2P AWS Sandbox Teardown" \
               "Destroys instance, EIP, SG, key (ManagedBy=${SANDBOX_MANAGED_BY})"
    log_info "Config: ${CONFIG_FILE}"
    log_info "Log:    ${LOG_FILE}"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Mode:   dry-run (no resources will be destroyed)"
    fi
    echo ""

    load_config "$CONFIG_FILE"
    export AWS_REGION
    AWS_REGION="$(cfg region)"
    aws_check_credentials

    local project
    project=$(cfg project)
    log_info "Project: ${project}"
    log_info "Region:  ${AWS_REGION}"
    log_info "Filter:  Project=${project} + ManagedBy=${SANDBOX_MANAGED_BY}"

    # Preview what would be deleted
    local ids eip_allocs sg_ids
    ids=$(aws_cli ec2 describe-instances \
        --filters "Name=tag:Project,Values=${project}" \
                  "Name=tag:ManagedBy,Values=${SANDBOX_MANAGED_BY}" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)
    eip_allocs=$(aws_cli ec2 describe-addresses \
        --filters "Name=tag:Project,Values=${project}" \
                  "Name=tag:ManagedBy,Values=${SANDBOX_MANAGED_BY}" \
        --query 'Addresses[].AllocationId' --output text 2>/dev/null || true)
    sg_ids=$(aws_cli ec2 describe-security-groups \
        --filters "Name=tag:Project,Values=${project}" \
                  "Name=tag:ManagedBy,Values=${SANDBOX_MANAGED_BY}" \
        --query 'SecurityGroups[].GroupId' --output text 2>/dev/null || true)

    cat <<EOF

╔════════════════════════════════════════════════════════════════════╗
║  About to DESTROY sandbox AWS resources                            ║
╠════════════════════════════════════════════════════════════════════╣
║  Project:    ${project}
║  ManagedBy:  ${SANDBOX_MANAGED_BY}
║  Instances:  ${ids:-<none>}
║  EIPs:       ${eip_allocs:-<none>}
║  SGs:        ${sg_ids:-<none>}
╚════════════════════════════════════════════════════════════════════╝

EOF

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would terminate instances, release EIPs, delete SGs/keys, remove provision-output"
        log_success "Dry-run complete — nothing changed."
        return 0
    fi

    if [[ "$ASSUME_YES" != "true" ]]; then
        log_warn "This permanently destroys the sandbox AWS resources listed above."
        local typed
        read -rp "Type the project name '${project}' to confirm: " typed </dev/tty
        if [[ "$typed" != "$project" ]]; then
            log_error "Confirmation mismatch. Aborting."
            exit 1
        fi
    else
        log_info "--yes set; skipping confirmation."
    fi

    # ── 1. Terminate instances ──────────────────────────────────────────
    log_step "1" "Terminating EC2 instances"
    if [[ -n "$ids" ]]; then
        log_info "  Terminating: ${ids}"
        # shellcheck disable=SC2086
        aws_cli ec2 terminate-instances --instance-ids $ids \
            --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' --output table
        log_info "  Waiting for instances to fully terminate..."
        # shellcheck disable=SC2086
        aws_cli ec2 wait instance-terminated --instance-ids $ids
        log_success "  All instances terminated."
    else
        log_info "  No active instances tagged Project=${project} ManagedBy=${SANDBOX_MANAGED_BY}"
    fi

    # ── 2. Release Elastic IPs ──────────────────────────────────────────
    log_step "2" "Releasing Elastic IPs"
    if [[ -n "$eip_allocs" ]]; then
        for alloc in $eip_allocs; do
            log_info "  Releasing ${alloc}..."
            # Disassociate first if still attached
            local assoc
            assoc=$(aws_cli ec2 describe-addresses --allocation-ids "$alloc" \
                --query 'Addresses[0].AssociationId' --output text 2>/dev/null || true)
            if [[ -n "$assoc" && "$assoc" != "None" ]]; then
                aws_cli ec2 disassociate-address --association-id "$assoc" 2>/dev/null || true
            fi
            aws_cli ec2 release-address --allocation-id "$alloc" || \
                log_warn "  Could not release ${alloc} (may already be gone)"
        done
        log_success "  Elastic IPs released."
    else
        log_info "  No EIPs tagged Project=${project} ManagedBy=${SANDBOX_MANAGED_BY}"
    fi

    # ── 3. Delete security groups ───────────────────────────────────────
    log_step "3" "Deleting security groups"
    if [[ -n "$sg_ids" ]]; then
        # Brief pause so ENIs detach after instance termination
        sleep 5
        for sg in $sg_ids; do
            log_info "  Deleting ${sg}..."
            if ! aws_cli ec2 delete-security-group --group-id "$sg" 2>&1; then
                log_warn "  Could not delete ${sg} — may have lingering ENI dependencies"
                log_warn "  Inspect: aws ec2 describe-network-interfaces --filters Name=group-id,Values=${sg}"
            fi
        done
        log_success "  Security groups deleted."
    else
        log_info "  No SGs tagged Project=${project} ManagedBy=${SANDBOX_MANAGED_BY}"
    fi

    # ── 4. Key pair — only if WE created it ─────────────────────────────
    if [[ "$KEEP_KEY" == "true" ]]; then
        log_step "4" "Keeping key pair (--keep-key set)"
    else
        log_step "4" "Deleting key pair (only if script-created)"
        local owned_keys
        owned_keys=$(aws_cli ec2 describe-key-pairs \
            --filters "Name=tag:Project,Values=${project}" \
                      "Name=tag:ManagedBy,Values=${SANDBOX_MANAGED_BY}" \
            --query 'KeyPairs[].KeyName' --output text 2>/dev/null || true)

        if [[ -z "$owned_keys" ]]; then
            local cfg_kn
            cfg_kn=$(cfg key_name)
            if [[ -n "$cfg_kn" ]] && \
               aws_cli ec2 describe-key-pairs --key-names "$cfg_kn" \
                   --query 'KeyPairs[0].KeyName' --output text >/dev/null 2>&1; then
                log_warn "  Key pair '${cfg_kn}' is NOT tagged ManagedBy=${SANDBOX_MANAGED_BY}"
                log_warn "  → pre-existing / user-supplied; keeping it in AWS"
            else
                log_info "  No script-created key pair found for Project=${project}"
            fi
        else
            for key_name in $owned_keys; do
                aws_cli ec2 delete-key-pair --key-name "$key_name"
                log_success "  Deleted key pair '${key_name}' (created by this script)"

                local key_path
                key_path=$(cfg key_path)
                if [[ -z "$key_path" ]]; then key_path="${SCRIPT_DIR}/keys/${key_name}.pem"; fi
                key_path="${key_path/#\~\//${HOME}/}"
                [[ "$key_path" = /* ]] || key_path="${SCRIPT_DIR}/${key_path}"
                if [[ -f "$key_path" ]]; then
                    rm -f "$key_path"
                    log_success "  Removed local .pem at ${key_path}"
                fi
            done
        fi
    fi

    # ── 5. Sweep leftover volumes / snapshots / ENIs ────────────────────
    log_step "5" "Sweeping leftover EBS volumes / snapshots / ENIs"

    local stray_vols
    stray_vols=$(aws_cli ec2 describe-volumes \
        --filters "Name=tag:Project,Values=${project}" \
                  "Name=tag:ManagedBy,Values=${SANDBOX_MANAGED_BY}" \
                  "Name=status,Values=available,creating,error" \
        --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)
    if [[ -n "$stray_vols" ]]; then
        log_info "  Deleting volumes: ${stray_vols}"
        for v in $stray_vols; do
            aws_cli ec2 delete-volume --volume-id "$v" 2>/dev/null \
                || log_warn "  Could not delete volume ${v}"
        done
    else
        log_info "  No stray volumes"
    fi

    local stray_snaps
    stray_snaps=$(aws_cli ec2 describe-snapshots \
        --owner-ids self \
        --filters "Name=tag:Project,Values=${project}" \
                  "Name=tag:ManagedBy,Values=${SANDBOX_MANAGED_BY}" \
        --query 'Snapshots[].SnapshotId' --output text 2>/dev/null || true)
    if [[ -n "$stray_snaps" ]]; then
        log_info "  Deleting snapshots: ${stray_snaps}"
        for s in $stray_snaps; do
            aws_cli ec2 delete-snapshot --snapshot-id "$s" 2>/dev/null \
                || log_warn "  Could not delete snapshot ${s}"
        done
    else
        log_info "  No stray snapshots"
    fi

    local stray_enis
    stray_enis=$(aws_cli ec2 describe-network-interfaces \
        --filters "Name=tag:Project,Values=${project}" \
                  "Name=tag:ManagedBy,Values=${SANDBOX_MANAGED_BY}" \
                  "Name=status,Values=available" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || true)
    if [[ -n "$stray_enis" ]]; then
        log_info "  Deleting ENIs: ${stray_enis}"
        for e in $stray_enis; do
            aws_cli ec2 delete-network-interface --network-interface-id "$e" 2>/dev/null \
                || log_warn "  Could not delete ENI ${e}"
        done
    else
        log_info "  No stray network interfaces"
    fi

    # ── 6. Remove provision-output.yaml ─────────────────────────────────
    log_step "6" "Remove stale provision-output"
    local out
    out=$(aws_sn_provision_output_path "$SCRIPT_DIR")
    if [[ -f "$out" ]]; then
        rm -f "$out" "${out}.prev"
        log_success "Removed ${out}"
    else
        log_info "No provision-output.yaml to remove."
    fi

    # ── 7. Final sweep ──────────────────────────────────────────────────
    log_step "7" "Sweep — anything still tagged Project=${project} ManagedBy=${SANDBOX_MANAGED_BY}"
    local leftover
    leftover=$(aws_cli resourcegroupstaggingapi get-resources \
        --tag-filters "Key=Project,Values=${project}" "Key=ManagedBy,Values=${SANDBOX_MANAGED_BY}" \
        --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || true)
    if [[ -n "$leftover" ]]; then
        log_warn "Leftover resources (delete manually):"
        echo "$leftover" | tr '\t' '\n' | sed 's/^/    /'
    else
        log_success "Nothing left tagged Project=${project} ManagedBy=${SANDBOX_MANAGED_BY}"
    fi

    cat <<EOF

╔════════════════════════════════════════════════════════════════════╗
║  Single-node teardown complete                                     ║
╠════════════════════════════════════════════════════════════════════╣
║  Re-provision:                                                     ║
║    ./openg2p-aws-provision.sh --config aws-config.yaml             ║
║                                                                    ║
║  Log: ${LOG_FILE}
╚════════════════════════════════════════════════════════════════════╝

EOF
}

main "$@"
