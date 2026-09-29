#!/usr/bin/env bash
# =============================================================================
# OpenG2P AWS Sandbox Provisioning — runs on your laptop
# =============================================================================
# Creates: 1 key pair, 1 security group, 1 Elastic IP (preferred), and
# 1 EC2 instance (Ubuntu Server 24.04 LTS, m5a.4xlarge by default) for the
# sandbox deployment.
#
# After provisioning:
#   - The instance is 'running', status checks are 'ok', and SSH-reachable
#   - ../provision-output.yaml is written with node_ip / wireguard.endpoint
#
# Then from your laptop run openg2p-sandbox.sh (orchestrator SSHes in
# and runs roles/infra/run.sh on the VM).
#
# Usage:
#   cp aws-config.example.yaml aws-config.yaml
#   # edit aws-config.yaml
#   ./openg2p-aws-provision.sh --config aws-config.yaml
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
NON_INTERACTIVE=false
SKIP_SSH_WAIT=false
FORCE_MODE=false
DRY_RUN=false
SSH_WAIT_TIMEOUT=600
LOG_FILE="${SCRIPT_DIR}/logs/aws-sandbox-$(date '+%Y%m%d-%H%M%S').log"

# Shared logging + cfg(); sandbox AWS helpers wrap shared AWS utils.
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
OpenG2P AWS Sandbox Provisioning
====================================

Usage:
  ./openg2p-aws-provision.sh --config aws-config.yaml [options]

Options:
  --config <file>      Path to AWS config (required)
  --non-interactive    Never prompt — fail if any required value is unspecified
  --skip-ssh-wait      Don't wait for SSH after the instance passes status checks
  --ssh-timeout <sec>  SSH wait timeout (default: 600)
  --force              If an instance with the same Name already exists, terminate
                       it first and launch a fresh one (sandbox ManagedBy only)
  --dry-run            Resolve selection and print what would be created; do not
                       create, terminate, or write output
  --help, -h           Show this help

What gets created (tagged ManagedBy=openg2p-aws-single-node):
  • 1 key pair        (or referenced existing)
  • 1 security group  (sandbox ports + Wireguard)
  • 1 Elastic IP      (preferred for Wireguard endpoint stability; soft-fallback)
  • 1 EC2 instance    (Ubuntu 24.04 LTS, default m5a.4xlarge / 128 GB gp3)

When values like vpc_id, subnet_id, or key_mode are blank in your config,
the script queries AWS, presents a menu, and saves your selection back to
aws-config.yaml so subsequent runs are stable.

# After provisioning, provision-output.yaml is written next to sandbox-config.yaml.
# Then from the sandbox directory on your laptop:
#   cd .. && ./openg2p-sandbox.sh --config sandbox-config.yaml
#
# Teardown:
#   ./openg2p-aws-destroy.sh --config aws-config.yaml
EOF
}

validate_aws_config() {
    # vpc_id, subnet_id, key_* are interactive / auto-derived — not required here.
    validate_config \
        project region \
        instance_type disk_gb \
        wg_port provision_output_file
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    mkdir -p "${SCRIPT_DIR}/logs" "${SCRIPT_DIR}/keys"
    exec > >(tee -a "$LOG_FILE") 2>&1

    log_banner "OpenG2P AWS Sandbox" "Provision 1× Ubuntu EC2 (m5a.4xlarge)"
    log_info "Config: ${CONFIG_FILE}"
    log_info "Log:    ${LOG_FILE}"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Mode:   dry-run (no resources will be created)"
    fi
    echo ""

    load_config "$CONFIG_FILE"
    validate_aws_config

    export AWS_REGION
    AWS_REGION="$(cfg region)"
    log_info "AWS region: ${AWS_REGION}"

    aws_check_credentials

    local project
    project=$(cfg project)
    log_info "Project: ${project}"

    # ── VPC + subnet ────────────────────────────────────────────────────
    log_step "1" "Select VPC and subnet"
    local vpc_id subnet_id vpc_cidr
    vpc_id=$(aws_pick_vpc "$(cfg vpc_id)") || exit 1
    subnet_id=$(aws_pick_subnet "$vpc_id" "$(cfg subnet_id)") || exit 1
    vpc_cidr=$(aws_get_vpc_cidr "$vpc_id")
    log_success "VPC:    ${vpc_id} (CIDR: ${vpc_cidr})"
    log_success "Subnet: ${subnet_id}"

    # ── admin_cidr ──────────────────────────────────────────────────────
    local admin_cidr
    admin_cidr="$(cfg admin_cidr)"
    if [[ -z "$admin_cidr" ]]; then
        admin_cidr="0.0.0.0/0"
        log_warn "admin_cidr unset — defaulting to 0.0.0.0/0 (SSH from any IP)."
        log_warn "Set admin_cidr in aws-config.yaml to an office/VPN range for a tighter lock."
    elif [[ "$admin_cidr" == "0.0.0.0/0" ]]; then
        log_warn "admin_cidr is OPEN (0.0.0.0/0). SSH/ping reachable from anywhere."
    else
        log_success "admin_cidr: ${admin_cidr}"
    fi

    local public_web
    public_web="$(cfg public_web "false")"

    # ── AMI ─────────────────────────────────────────────────────────────
    log_step "2" "Resolve Ubuntu AMI"
    local ami
    ami=$(aws_resolve_ubuntu_ami "$(cfg ubuntu_ami)") || exit 1
    log_success "AMI: ${ami}"

    # ── Key pair ────────────────────────────────────────────────────────
    log_step "3" "Select EC2 Key Pair"
    local key_resolved
    key_resolved=$(aws_pick_key_pair \
        "$(cfg key_mode)" "$(cfg key_name)" "$(cfg key_path)" \
        "$project" "${SCRIPT_DIR}/keys") || exit 1
    local key_mode="${key_resolved%%|*}"
    local key_rest="${key_resolved#*|}"
    local key_name="${key_rest%%|*}"
    local key_path="${key_rest##*|}"
    aws_ensure_key_pair_sandbox "$key_name" "$key_path" "$key_mode" "$project"

    # ── Security group ──────────────────────────────────────────────────
    log_step "4" "Create / reuse security group"
    local wg_port instance_name sg_name sg_id
    wg_port=$(cfg wg_port "51820")
    instance_name=$(cfg instance_name "${project}")
    sg_name=$(cfg sg_name "${project}-sandbox")

    sg_id=$(aws_ensure_security_group_sandbox \
        "$sg_name" "OpenG2P sandbox - SSH, HTTPS, Wireguard, RKE2" \
        "$vpc_id" "$project" "sandbox")
    aws_require_nonempty "Security group" "$sg_id"
    aws_apply_sg_rules_sandbox "$sg_id" "$admin_cidr" "$vpc_cidr" "$wg_port" "$public_web"
    log_success "SG: ${sg_name} (${sg_id})"

    # ── Elastic IP ──────────────────────────────────────────────────────
    log_step "5" "Allocate Elastic IP (Wireguard endpoint stability)"
    local eip_alloc="" eip_addr=""
    eip_alloc=$(aws_ensure_eip_sandbox "$project" "sandbox-eip")
    if [[ -z "$eip_alloc" || "$eip_alloc" == "None" ]]; then
        eip_alloc=""
        log_warn "No Elastic IP available — instance will use its auto-assigned public IP."
        log_warn "That IP can change on stop/start (Wireguard peers / endpoint must be updated)."
    else
        eip_addr=$(aws_get_eip_address "$eip_alloc")
        aws_require_nonempty "Elastic IP address" "$eip_addr"
        log_success "EIP: ${eip_addr} (alloc: ${eip_alloc})"
    fi

    # ── Instance sizing ─────────────────────────────────────────────────
    local instance_type disk_gb disk_iops disk_throughput
    instance_type=$(cfg instance_type "m5a.4xlarge")
    disk_gb=$(cfg disk_gb "128")
    disk_iops=$(cfg disk_iops "3000")
    disk_throughput=$(cfg disk_throughput "125")

    # ── Dry-run / confirm / launch ──────────────────────────────────────
    log_step "6" "Launch EC2 instance"

    local out_path
    out_path=$(aws_sn_provision_output_path "$SCRIPT_DIR")

    local instance_id
    instance_id=$(aws_find_sandbox_instance "$instance_name" "$project")

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] resolved selection — no AWS resources will be created or terminated"
        log_info "[dry-run]   Name:           ${instance_name}"
        log_info "[dry-run]   Type:           ${instance_type}"
        log_info "[dry-run]   Root disk:      ${disk_gb} GiB gp3"
        log_info "[dry-run]   AMI:            ${ami}"
        log_info "[dry-run]   Region:         ${AWS_REGION}"
        log_info "[dry-run]   VPC / subnet:   ${vpc_id} / ${subnet_id}"
        log_info "[dry-run]   Security Group: ${sg_id}"
        log_info "[dry-run]   Key pair:       ${key_name}"
        log_info "[dry-run]   EIP:            ${eip_addr:-<ephemeral public IP>}"
        log_info "[dry-run]   public_web:     ${public_web}"
        log_info "[dry-run]   Project tag:    ${project}"
        if [[ -n "$instance_id" && "$instance_id" != "None" ]]; then
            if [[ "$FORCE_MODE" == "true" ]]; then
                log_info "[dry-run] would terminate existing ${instance_id} (--force), then launch fresh"
            else
                log_info "[dry-run] would reuse existing instance ${instance_id}"
            fi
        else
            log_info "[dry-run] would call ec2 run-instances for a new instance"
        fi
        log_success "Dry-run complete — nothing changed."
        return 0
    fi

    if [[ -n "$instance_id" && "$instance_id" != "None" ]]; then
        if [[ "$FORCE_MODE" == "true" ]]; then
            log_warn "--force: terminating existing sandbox instance ${instance_id} (${instance_name})"
            aws_cli ec2 terminate-instances --instance-ids "$instance_id" >/dev/null
            aws_cli ec2 wait instance-terminated --instance-ids "$instance_id"
            instance_id=""
        else
            log_info "Instance already exists (${instance_name}): ${instance_id}"
            log_info "Reusing — will wait for running / status checks / SSH."
            log_info "Pass --force to terminate it and launch a fresh instance."
        fi
    fi

    if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
        instance_id=$(aws_run_sandbox_instance \
            "$instance_name" "$project" "sandbox" \
            "$ami" "$instance_type" "$subnet_id" "$sg_id" "$key_name" \
            "$disk_gb" "$disk_iops" "$disk_throughput")
        aws_require_nonempty "Instance ID" "$instance_id"
        log_success "Launched: ${instance_id}"
    fi

    # ── Wait running ────────────────────────────────────────────────────
    log_step "7" "Wait for instance readiness"
    aws_wait_running "$instance_id" "sandbox"

    # Wireguard needs source/dest check disabled.
    aws_disable_source_dest_check "$instance_id"
    log_success "Source/dest check disabled (required for Wireguard)."

    if [[ -n "$eip_alloc" ]]; then
        aws_associate_eip "$eip_alloc" "$instance_id"
    fi

    aws_wait_status_ok "$instance_id" "sandbox"

    # ── IPs ─────────────────────────────────────────────────────────────
    local ips public_ip private_ip
    ips=$(aws_get_instance_ips "$instance_id")
    private_ip="${ips#*|}"
    public_ip="${eip_addr:-}"
    if [[ -z "$public_ip" || "$public_ip" == "None" ]]; then
        public_ip="${ips%|*}"
        log_info "Public IP (ephemeral, no EIP): ${public_ip}"
    fi
    aws_require_nonempty "Private IP" "$private_ip"
    aws_require_nonempty "Public IP" "$public_ip"
    log_info "Public IP:  ${public_ip}"
    log_info "Private IP: ${private_ip}"

    # ── SSH wait ────────────────────────────────────────────────────────
    if [[ "$SKIP_SSH_WAIT" == "true" ]]; then
        log_step "8" "Skipping SSH wait (--skip-ssh-wait)"
    else
        log_step "8" "Wait for SSH"
        aws_wait_ssh "$public_ip" "ubuntu" "$key_path" "$SSH_WAIT_TIMEOUT" "sandbox" \
            || exit 1
    fi

    write_provision_output \
        "$instance_id" "$instance_name" "$instance_type" \
        "$public_ip" "$private_ip" "$vpc_cidr" "$admin_cidr" \
        "$key_path" "$sg_id" "$ami" "$disk_gb"

    show_summary \
        "$instance_id" "$instance_name" "$instance_type" \
        "$public_ip" "$private_ip" "$key_path"
}

# ---------------------------------------------------------------------------
write_provision_output() {
    local instance_id="$1" instance_name="$2" instance_type="$3"
    local public_ip="$4" private_ip="$5" vpc_cidr="$6" admin_cidr="$7"
    local key_path="$8" sg_id="$9" ami="${10}" disk_gb="${11}"

    local out
    out=$(cfg provision_output_file "../provision-output.yaml")
    [[ "$out" = /* ]] || out="${SCRIPT_DIR}/${out}"
    out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"

    log_step "9" "Writing provision-output.yaml"

    if [[ -f "$out" ]]; then
        cp "$out" "${out}.prev"
    fi

    # Prefer paths relative to the sandbox/ directory (sibling of aws/).
    local key_for_infra="$key_path"
    local infra_dir
    infra_dir="$(dirname "$out")"
    case "$key_path" in
        "${infra_dir}/"*) key_for_infra="./${key_path#${infra_dir}/}" ;;
    esac

    cat > "$out" <<EOF
# =============================================================================
# OpenG2P sandbox provision-output — AWS-derived configuration
# =============================================================================
# AUTO-GENERATED by aws/openg2p-aws-provision.sh — overwritten on every run.
#
# Loaded as an overlay by the laptop orchestrator (openg2p-sandbox.sh) and
# by the install scripts. Keys here win over sandbox-config.yaml on conflict
# (node_ip, wireguard.endpoint, ssh_host, ssh_user, ssh_key, …).
#
# Generated:  $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Region:     ${AWS_REGION}
# Project:    $(cfg project)
# =============================================================================

# ─── Suggested sandbox-config.yaml values (auto-loaded as overlay) ─────────
node_ip:   "${private_ip}"
# node_name is deliberately NOT emitted. It is a user preference set in
# sandbox-config.yaml, not AWS-derived state, and this overlay wins on
# conflict — emitting it would silently override what the operator chose.

wireguard:
  endpoint: "${public_ip}"

# ─── Instance metadata ───────────────────────────────────────────────────
instance_id:     "${instance_id}"
instance_name:   "${instance_name}"
instance_type:   "${instance_type}"
ami:             "${ami}"
disk_gb:         ${disk_gb}
sg_id:           "${sg_id}"

public_ip:       "${public_ip}"
private_ip:      "${private_ip}"
private_subnet:  "${vpc_cidr}"
admin_cidr:      "${admin_cidr}"

ssh_host:        "${public_ip}"
ssh_user:        "ubuntu"
ssh_key:         "${key_for_infra}"

wg_endpoint:     "${public_ip}"
wg_port:         "$(cfg wg_port 51820)"
EOF

    log_success "Wrote ${out}"
}

show_summary() {
    local instance_id="$1" instance_name="$2" instance_type="$3"
    local public_ip="$4" private_ip="$5" key_path="$6"

    local out
    out=$(cfg provision_output_file "../provision-output.yaml")
    [[ "$out" = /* ]] || out="${SCRIPT_DIR}/${out}"
    out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"

    cat <<EOF

╔════════════════════════════════════════════════════════════════════╗
║  AWS sandbox provisioning complete                                 ║
╠════════════════════════════════════════════════════════════════════╣
║                                                                    ║
║  Instance ID:   ${instance_id}
║  Name:          ${instance_name}
║  Type:          ${instance_type}
║  Public IP:     ${public_ip}
║  Private IP:    ${private_ip}
║                                                                    ║
║  SSH:           ssh -i ${key_path} ubuntu@${public_ip}
║  Output:        ${out}
║                                                                    ║
║  Next — install from your laptop:                                  ║
║    cd ..                                                           ║
║    cp sandbox-config.example.yaml sandbox-config.yaml              ║
║    # node_ip / wireguard.endpoint / ssh_* come from                ║
║    # provision-output.yaml (auto-loaded as an overlay)             ║
║    ./openg2p-sandbox.sh --config sandbox-config.yaml \\            ║
║      --probe                                                       ║
║    ./openg2p-sandbox.sh --config sandbox-config.yaml               ║
║                                                                    ║
║  (On-box scripts still run ON the VM — the orchestrator SSHes      ║
║   in, stages automation/sandbox/, and executes them for you.)      ║
║                                                                    ║
║  Log: ${LOG_FILE}
║                                                                    ║
║  Destroy later:                                                    ║
║    ./openg2p-aws-destroy.sh --config aws-config.yaml               ║
║                                                                    ║
╚════════════════════════════════════════════════════════════════════╝

EOF
}

main "$@"
