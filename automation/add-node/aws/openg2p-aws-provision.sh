#!/usr/bin/env bash
# =============================================================================
# OpenG2P AWS Add-Node Provisioning — runs on your laptop
# =============================================================================
# Creates a single Ubuntu Server 24.04 LTS EC2 instance in an EXISTING VPC
# and security group. Interactive when values are blank in the config.
#
# After provisioning the instance is 'running', status checks are 'ok', and
# (unless --skip-ssh-wait) SSH-reachable. Details are written to
# provision-output.yaml for use by ../openg2p-add-node.sh.
#
# Usage:
#   cp aws-config.example.yaml aws-config.yaml
#   # edit aws-config.yaml (region / project at minimum)
#   ./openg2p-aws-provision.sh --config aws-config.yaml
#   ./openg2p-aws-provision.sh --config aws-config.yaml --dry-run
# =============================================================================

set -euo pipefail

# Trap any non-zero exit (including silent set-e exits) and emit a line number.
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
NON_INTERACTIVE=false
SKIP_SSH_WAIT=false
FORCE_MODE=false
DRY_RUN=false
SSH_WAIT_TIMEOUT=600
LOG_FILE="${SCRIPT_DIR}/logs/aws-add-node-$(date '+%Y%m%d-%H%M%S').log"

# Shared logging + cfg() and AWS helpers.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../production/lib/shared/utils.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/aws-utils.sh"

# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)          CONFIG_FILE="$2";        shift 2 ;;
            --non-interactive) NON_INTERACTIVE=true;    shift ;;
            --skip-ssh-wait)   SKIP_SSH_WAIT=true;      shift ;;
            --ssh-timeout)     SSH_WAIT_TIMEOUT="$2";   shift 2 ;;
            --force)           FORCE_MODE=true;         shift ;;
            --dry-run)         DRY_RUN=true;            shift ;;
            --help|-h)         show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1" "" "Run with --help for usage"
                exit 1
                ;;
        esac
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        log_error "No config file specified" \
                  "--config is required" \
                  "Copy aws-config.example.yaml and provide it" \
                  "$0 --config aws-config.yaml"
        exit 1
    fi
    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
    export NON_INTERACTIVE
    export CONFIG_FILE
    export DRY_RUN
}

show_help() {
    cat <<'EOF'
OpenG2P AWS Add-Node Provisioning
=================================

Usage:
  ./openg2p-aws-provision.sh --config aws-config.yaml [options]

Options:
  --config <file>      Path to AWS add-node config (required)
  --non-interactive    Never prompt — fail if any required value is unspecified
                       (use in CI; default is interactive when stdin is a TTY)
  --skip-ssh-wait      Don't wait for SSH after the instance passes status checks
  --ssh-timeout <sec>  SSH wait timeout (default: 600)
  --force              If an add-node instance with the same Name already exists
                       (e.g. a previous run failed mid-way), terminate it first
                       and launch a fresh one. Refuses to touch other cluster nodes.
  --dry-run            Resolve selection (VPC/SG/AMI/…) and print what would be
                       launched; do not create, terminate, or write output.
  --help, -h           Show this help

What gets created (tagged ManagedBy=openg2p-aws-add-node):
  • 1 EC2 instance  (Ubuntu 24.04 LTS) in an existing VPC / SG / subnet

Interactive prompts (when the matching config key is blank):
  • EC2 instance type     (default: t3a.2xlarge)
  • Root EBS volume       (default: 128 GiB gp3)
  • Existing VPC
  • Availability Zone     (AZs that have subnets in the selected VPC)
  • Subnet                (in the selected AZ; prefers public subnets)
  • Existing Security Group (in the selected VPC)
  • EC2 Key Pair          (existing, or create new)
  • Instance Name tag

Selections are written back to aws-config.yaml so subsequent runs are stable.

Teardown (this instance only — never SGs / VPC / other cluster nodes):
  ./openg2p-aws-destroy.sh --config aws-config.yaml

After provisioning, provision-output.yaml is written next to this script.
Then join the node to the cluster:
  cd .. && sudo ./openg2p-add-node.sh --config add-node-config.yaml
EOF
}

# ---------------------------------------------------------------------------
# Validate AWS-specific config keys that must be present upfront.
# Interactive fields (vpc_id, az, subnet_id, sg_id, key_*, instance_name,
# instance_type, disk_gb) are deliberately NOT required here.
# ---------------------------------------------------------------------------
validate_aws_config() {
    validate_config project region provision_output_file
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    mkdir -p "${SCRIPT_DIR}/logs" "${SCRIPT_DIR}/keys"
    exec > >(tee -a "$LOG_FILE") 2>&1

    log_banner "OpenG2P AWS Add-Node" "Provision a single Ubuntu EC2 instance"
    log_info "Config: ${CONFIG_FILE}"
    log_info "Log:    ${LOG_FILE}"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Mode:   dry-run (no resources will be created)"
    fi
    echo ""

    load_config "$CONFIG_FILE"
    validate_aws_config

    # ── 1. Pin region for all aws calls ──────────────────────────────────
    export AWS_REGION
    AWS_REGION="$(cfg region)"
    log_info "AWS region: ${AWS_REGION}"

    aws_check_credentials

    local project
    project=$(cfg project)
    log_info "Project: ${project}"

    # ── 2. Instance type ────────────────────────────────────────────────
    log_step "1" "Select EC2 instance type"
    local instance_type
    instance_type=$(aws_pick_instance_type "$(cfg instance_type)" "t3a.2xlarge") || exit 1
    log_success "Instance type: ${instance_type}"

    # ── 3. Root EBS volume ──────────────────────────────────────────────
    log_step "2" "Select root EBS volume size"
    local disk_gb disk_iops disk_throughput
    disk_gb=$(aws_pick_disk_gb "$(cfg disk_gb)" "128") || exit 1
    disk_iops=$(cfg disk_iops 3000)
    disk_throughput=$(cfg disk_throughput 125)
    if ! aws_is_positive_int "$disk_iops" || ! aws_is_positive_int "$disk_throughput"; then
        log_error "disk_iops / disk_throughput must be positive integers" \
                  "Invalid gp3 tuning values in config"
        exit 1
    fi
    log_success "Root volume: ${disk_gb} GiB gp3 (IOPS=${disk_iops}, throughput=${disk_throughput} MB/s)"

    # ── 4. VPC ──────────────────────────────────────────────────────────
    log_step "3" "Select VPC"
    local vpc_id
    vpc_id=$(aws_pick_vpc "$(cfg vpc_id)") || exit 1
    log_success "VPC: ${vpc_id}"

    # ── 5. Availability Zone ────────────────────────────────────────────
    log_step "4" "Select Availability Zone"
    local az
    az=$(aws_pick_az "$vpc_id" "$(cfg az)") || exit 1
    log_success "AZ: ${az}"

    # ── 6. Subnet in that AZ ────────────────────────────────────────────
    log_step "5" "Select subnet in ${az}"
    local subnet_id
    subnet_id=$(aws_pick_subnet_in_az "$vpc_id" "$az" "$(cfg subnet_id)") || exit 1
    log_success "Subnet: ${subnet_id}"

    # ── 7. Security Group ───────────────────────────────────────────────
    log_step "6" "Select Security Group"
    local sg_id
    sg_id=$(aws_pick_security_group "$vpc_id" "$(cfg sg_id)") || exit 1
    log_success "Security Group: ${sg_id}"

    # ── 8. Key pair ─────────────────────────────────────────────────────
    log_step "7" "Select EC2 Key Pair"
    local key_resolved
    # Resolves + ensures; re-prompts for local .pem if a saved path is stale.
    key_resolved=$(aws_resolve_key_pair \
        "$(cfg key_mode)" "$(cfg key_name)" "$(cfg key_path)" \
        "$project" "${SCRIPT_DIR}/keys") || exit 1
    local key_mode="${key_resolved%%|*}"
    local key_rest="${key_resolved#*|}"
    local key_name="${key_rest%%|*}"
    local key_path="${key_rest##*|}"
    log_success "Key pair: ${key_name} (local: ${key_path})"

    # ── 9. Instance name ────────────────────────────────────────────────
    log_step "8" "Select instance Name tag"
    local instance_name role
    instance_name=$(aws_pick_instance_name "$(cfg instance_name)" "$project") || exit 1
    role=$(cfg role "k8s-node")
    log_success "Name: ${instance_name}  (Role=${role})"

    # ── 10. AMI ─────────────────────────────────────────────────────────
    log_step "9" "Resolve Ubuntu AMI"
    local ami
    ami=$(aws_resolve_ubuntu_ami "$(cfg ubuntu_ami)") || exit 1
    log_success "AMI: ${ami}"

    # ── 11. Confirm + launch ────────────────────────────────────────────
    log_step "10" "Launch EC2 instance"

    local out_path
    out_path=$(aws_provision_output_path "$SCRIPT_DIR")

    # Idempotent reuse — or --force replace of a prior add-node instance.
    local instance_id
    instance_id=$(aws_find_add_node_instance "$instance_name" "$project" "$out_path")

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] resolved selection — no AWS resources will be created or terminated"
        log_info "[dry-run]   Name:           ${instance_name}"
        log_info "[dry-run]   Type:           ${instance_type}"
        log_info "[dry-run]   Root disk:      ${disk_gb} GiB gp3 (IOPS=${disk_iops}, throughput=${disk_throughput})"
        log_info "[dry-run]   AMI:            ${ami}"
        log_info "[dry-run]   Region / AZ:    ${AWS_REGION} / ${az}"
        log_info "[dry-run]   VPC:            ${vpc_id}"
        log_info "[dry-run]   Subnet:         ${subnet_id}"
        log_info "[dry-run]   Security Group: ${sg_id}"
        log_info "[dry-run]   Key pair:       ${key_name}"
        log_info "[dry-run]   Role tag:       ${role}"
        log_info "[dry-run]   Project tag:    ${project}"
        if [[ -n "$instance_id" && "$instance_id" != "None" ]]; then
            if [[ "$FORCE_MODE" == "true" ]]; then
                log_info "[dry-run] would terminate existing ${instance_id} (--force), then launch a fresh instance"
            else
                log_info "[dry-run] would reuse existing instance ${instance_id} (pass --force to replace)"
            fi
        else
            log_info "[dry-run] would call ec2 run-instances for a new instance"
        fi
        log_info "[dry-run] would wait for status checks${SKIP_SSH_WAIT:+ (SSH wait skipped)}, write provision-output.yaml"
        log_success "Dry-run complete — nothing changed."
        return 0
    fi

    aws_confirm_launch \
        "$instance_name" "$instance_type" "$disk_gb" "$ami" \
        "$vpc_id" "$az" "$subnet_id" "$sg_id" "$key_name" "$project" \
        || exit 1

    if [[ -n "$instance_id" && "$instance_id" != "None" ]]; then
        if [[ "$FORCE_MODE" == "true" ]]; then
            log_warn "--force: terminating existing add-node instance ${instance_id} (${instance_name})"
            aws_terminate_instance "$instance_id" "$instance_name"
            instance_id=""
        else
            log_info "Instance already exists (${instance_name}): ${instance_id}"
            log_info "Reusing — will wait for running / status checks / SSH."
            log_info "Pass --force to terminate it and launch a fresh instance."
        fi
    fi

    if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
        instance_id=$(aws_run_add_node_instance \
            "$instance_name" "$project" "$role" \
            "$ami" "$instance_type" "$subnet_id" "$sg_id" "$key_name" \
            "$disk_gb" "$disk_iops" "$disk_throughput")
        aws_require_nonempty "Instance ID" "$instance_id"
        log_success "Launched: ${instance_id}"
    fi

    # ── 12. Wait for running + status checks ────────────────────────────
    log_step "11" "Wait for instance readiness"
    aws_wait_running "$instance_id" "$instance_name"
    aws_wait_status_ok "$instance_id" "$instance_name"

    # ── 13. Capture IPs ─────────────────────────────────────────────────
    local ips public_ip private_ip
    ips=$(aws_get_instance_ips "$instance_id")
    public_ip="${ips%|*}"
    private_ip="${ips#*|}"
    aws_require_nonempty "Private IP" "$private_ip"
    if [[ -z "$public_ip" || "$public_ip" == "None" ]]; then
        log_warn "No public IP assigned — SSH wait will use the private IP."
        log_warn "Ensure your laptop can reach ${private_ip} (VPN / bastion)."
        public_ip=""
    fi
    log_info "Public IP:  ${public_ip:-<none>}"
    log_info "Private IP: ${private_ip}"

    # ── 14. Wait for SSH ────────────────────────────────────────────────
    local ssh_host="${public_ip:-$private_ip}"
    if [[ "$SKIP_SSH_WAIT" == "true" ]]; then
        log_step "12" "Skipping SSH wait (--skip-ssh-wait)"
    else
        log_step "12" "Wait for SSH"
        aws_wait_ssh "$ssh_host" "ubuntu" "$key_path" "$SSH_WAIT_TIMEOUT" "$instance_name" \
            || exit 1
    fi

    # ── 15. Write output + summary ──────────────────────────────────────
    write_add_node_output \
        "$instance_id" "$instance_name" "$instance_type" \
        "$public_ip" "$private_ip" "$az" "$subnet_id" "$vpc_id" \
        "$sg_id" "$key_name" "$key_path" "$ami" "$disk_gb" "$role"

    show_add_node_summary \
        "$instance_id" "$instance_name" "$instance_type" \
        "$public_ip" "$private_ip" "$az" "$key_path" "$ssh_host"
}

# ---------------------------------------------------------------------------
write_add_node_output() {
    local instance_id="$1" instance_name="$2" instance_type="$3"
    local public_ip="$4" private_ip="$5" az="$6" subnet_id="$7" vpc_id="$8"
    local sg_id="$9" key_name="${10}" key_path="${11}" ami="${12}"
    local disk_gb="${13}" role="${14}"

    local out
    out=$(cfg provision_output_file "./provision-output.yaml")
    [[ "$out" = /* ]] || out="${SCRIPT_DIR}/${out}"
    out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"

    log_step "13" "Writing provision-output.yaml"

    if [[ -f "$out" ]]; then
        cp "$out" "${out}.prev"
    fi

    cat > "$out" <<EOF
# =============================================================================
# OpenG2P add-node provision-output — AWS-derived configuration
# =============================================================================
# AUTO-GENERATED by aws/openg2p-aws-provision.sh — overwritten on every run.
#
# Use these values when filling ../add-node-config.yaml:
#   node_ip:   ${private_ip}
#   node_name: ${instance_name}
#
# Generated:  $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Region:     ${AWS_REGION}
# Project:    $(cfg project)
# =============================================================================

instance_id:     "${instance_id}"
instance_name:   "${instance_name}"
instance_type:   "${instance_type}"
role:            "${role}"
ami:             "${ami}"
disk_gb:         ${disk_gb}

public_ip:       "${public_ip}"
private_ip:      "${private_ip}"
availability_zone: "${az}"
vpc_id:          "${vpc_id}"
subnet_id:       "${subnet_id}"
sg_id:           "${sg_id}"

ssh_host:        "${public_ip:-$private_ip}"
ssh_user:        "ubuntu"
ssh_key:         "${key_path}"
key_name:        "${key_name}"

# Suggested add-node-config.yaml values:
#   node_ip:   "${private_ip}"
#   node_name: "${instance_name}"
EOF

    log_success "Wrote ${out}"
}

show_add_node_summary() {
    local instance_id="$1" instance_name="$2" instance_type="$3"
    local public_ip="$4" private_ip="$5" az="$6" key_path="$7" ssh_host="$8"

    local out
    out=$(cfg provision_output_file "./provision-output.yaml")
    [[ "$out" = /* ]] || out="${SCRIPT_DIR}/${out}"
    out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"

    cat <<EOF

╔════════════════════════════════════════════════════════════════════╗
║  AWS add-node provisioning complete                                ║
╠════════════════════════════════════════════════════════════════════╣
║                                                                    ║
║  Instance ID:   ${instance_id}
║  Name:          ${instance_name}
║  Type:          ${instance_type}
║  AZ:            ${az}
║  Public IP:     ${public_ip:-<none>}
║  Private IP:    ${private_ip}
║                                                                    ║
║  SSH:           ssh -i ${key_path} ubuntu@${ssh_host}
║  Output:        ${out}
║                                                                    ║
║  Next — join this node to the RKE2 cluster:                        ║
║    1. SSH to the instance (above)                                  ║
║    2. Copy automation/add-node/ onto the node                       ║
║    3. Fill add-node-config.yaml:                                   ║
║         node_ip:   ${private_ip}
║         node_name: ${instance_name}
║         server_url / rke2_token / rke2_version from primary        ║
║    4. sudo ./openg2p-add-node.sh --config add-node-config.yaml     ║
║                                                                    ║
║  Log: ${LOG_FILE}
║                                                                    ║
║  Destroy this node later:                                          ║
║    ./openg2p-aws-destroy.sh --config aws-config.yaml               ║
║                                                                    ║
╚════════════════════════════════════════════════════════════════════╝

EOF
}

main "$@"
