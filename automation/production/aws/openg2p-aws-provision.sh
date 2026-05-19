#!/usr/bin/env bash
# =============================================================================
# OpenG2P AWS Provisioning — runs on your laptop
# =============================================================================
# Creates: 1 key pair, 3 security groups, 1 Elastic IP, 3 EC2 instances
# (Ubuntu Server 24.04 LTS) for the production OpenG2P deployment.
#
# After provisioning:
#   - All instances are 'running' AND status checks 'ok' AND SSH-reachable
#   - prod-config.yaml is populated (or merged) with IPs, SSH paths, etc.
#
# Usage:
#   cp aws-config.example.yaml aws-config.yaml
#   # edit aws-config.yaml
#   ./openg2p-aws-provision.sh --config aws-config.yaml
# =============================================================================

set -euo pipefail

# Trap any non-zero exit (including silent set-e exits) and emit a line number.
# Preserves the original exit code.
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
SSH_WAIT_TIMEOUT=600
LOG_FILE="${SCRIPT_DIR}/logs/aws-provision-$(date '+%Y%m%d-%H%M%S').log"

# Reuse logging + cfg() from the production lib.
source "${SCRIPT_DIR}/../lib/shared/utils.sh"
source "${SCRIPT_DIR}/lib/aws-utils.sh"
# Optional backup-node helpers — only used when backup_node.enabled=true.
[[ -f "${SCRIPT_DIR}/lib/backup-node.sh" ]] && source "${SCRIPT_DIR}/lib/backup-node.sh"

# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)          CONFIG_FILE="$2";        shift 2 ;;
            --non-interactive) NON_INTERACTIVE=true;    shift ;;
            --skip-ssh-wait)   SKIP_SSH_WAIT=true;      shift ;;
            --ssh-timeout)     SSH_WAIT_TIMEOUT="$2";   shift 2 ;;
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
}

show_help() {
    cat <<'EOF'
OpenG2P AWS Provisioning
==========================

Usage:
  ./openg2p-aws-provision.sh --config aws-config.yaml [options]

Options:
  --config <file>      Path to AWS config (required)
  --non-interactive    Never prompt — fail if any required value is unspecified
                       (use in CI; default is interactive when stdin is a TTY)
  --skip-ssh-wait      Don't wait for SSH after instances pass status checks.
                       Use when you know SSH is up (or will be) but the wait
                       is hanging due to a network/SG issue you'll fix later.
  --ssh-timeout <sec>  Per-instance SSH wait timeout (default: 600).
  --help               Show this help

What gets created (all tagged with Project=<project>):
  • 1 key pair       (or referenced existing)
  • 3 security groups (one per role)
  • 1 Elastic IP     (attached to the RP node)
  • 3 EC2 instances  (RP, compute, storage)

When values like vpc_id, subnet_id, or key_mode are blank in your config,
the script queries AWS, presents a menu, and saves your selection back to
aws-config.yaml so subsequent runs are stable.

After provisioning, provision-output.yaml is written next to prod-config.yaml.
Then run:
  cd .. && ./openg2p-prod.sh --config prod-config.yaml
EOF
}

# ---------------------------------------------------------------------------
# Validate AWS-specific config keys
# ---------------------------------------------------------------------------
validate_aws_config() {
    # Required upfront. The following are deliberately NOT in the required
    # list — they're either prompted interactively, or auto-derived from
    # `project` when blank:
    #   • vpc_id, subnet_id           — interactive picker
    #   • key_mode, key_name, key_path — interactive picker
    #   • rp_name, compute_name, storage_name           — derive from project
    #   • rp_sg_name, compute_sg_name, storage_sg_name  — derive from project
    validate_config \
        project region \
        rp_instance_type compute_instance_type storage_instance_type \
        rp_disk_gb compute_disk_gb storage_disk_gb \
        wg_port provision_output_file
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    mkdir -p "${SCRIPT_DIR}/logs" "${SCRIPT_DIR}/keys"
    exec > >(tee -a "$LOG_FILE") 2>&1

    log_banner "OpenG2P AWS Provisioning" "Creates 3 EC2 instances + supporting resources"
    log_info "Config: ${CONFIG_FILE}"
    log_info "Log:    ${LOG_FILE}"
    echo ""

    load_config "$CONFIG_FILE"
    validate_aws_config

    # ── 1. Pin region for all aws calls ──────────────────────────────────
    export AWS_REGION
    AWS_REGION="$(cfg region)"
    log_info "AWS region: ${AWS_REGION}"

    aws_check_credentials

    # ── 2. Project + naming ─────────────────────────────────────────────
    local project=$(cfg project)
    log_info "Project: ${project}"

    # ── 3. VPC + subnet ─────────────────────────────────────────────────
    # Smart pickers: use config if set, auto-pick when single match, prompt
    # interactively when multiple, or fail with a list in --non-interactive.
    local vpc_id subnet_id vpc_cidr
    vpc_id=$(aws_pick_vpc "$(cfg vpc_id)")          || exit 1
    subnet_id=$(aws_pick_subnet "$vpc_id" "$(cfg subnet_id)")  || exit 1
    vpc_cidr=$(aws_get_vpc_cidr "$vpc_id")
    log_success "VPC:    ${vpc_id} (CIDR: ${vpc_cidr})"
    log_success "Subnet: ${subnet_id}"

    # ── 4. admin_cidr default = laptop's public IP /32 ──────────────────
    local admin_cidr=$(cfg admin_cidr)
    if [[ -z "$admin_cidr" ]]; then
        if admin_cidr=$(aws_detect_my_public_ip); then
            log_success "Auto-detected admin_cidr: ${admin_cidr} (this laptop's public IP)"
        else
            log_error "Could not auto-detect public IP" \
                      "checkip.amazonaws.com unreachable" \
                      "Set admin_cidr explicitly in aws-config.yaml"
            exit 1
        fi
    fi
    if [[ "$admin_cidr" == "0.0.0.0/0" ]]; then
        log_warn "admin_cidr is OPEN (0.0.0.0/0). SSH/ping reachable from anywhere."
        log_warn "Tighten this in aws-config.yaml after install for production."
    fi

    # ── 5. AMI ──────────────────────────────────────────────────────────
    local ami
    ami=$(aws_resolve_ubuntu_ami "$(cfg ubuntu_ami)")
    log_success "AMI: ${ami}"

    # ── 6. Key pair ─────────────────────────────────────────────────────
    # Smart picker — if key_mode is blank and stdin is a TTY, list existing
    # keys with a "create new" option. Otherwise default to create.
    local key_resolved
    key_resolved=$(aws_pick_key_pair \
        "$(cfg key_mode)" "$(cfg key_name)" "$(cfg key_path)" \
        "$project" "${SCRIPT_DIR}/keys") || exit 1
    local key_mode="${key_resolved%%|*}"
    local key_rest="${key_resolved#*|}"
    local key_name="${key_rest%%|*}"
    local key_path="${key_rest##*|}"
    aws_ensure_key_pair "$key_name" "$key_path" "$key_mode" "$project"

    # ── 7. Security groups ──────────────────────────────────────────────
    log_step "1" "Creating security groups"
    local rp_sg compute_sg storage_sg
    local wg_port=$(cfg wg_port "51820")

    # AWS SG descriptions must be ASCII-only — keep them simple.
    # SG names default to <project>-<role> if not set in config. The RP gets
    # TWO SGs — one for the public ENI (Wireguard, public services), one
    # for the internal ENI (admin services). Defence-in-depth: even if Nginx
    # bound to the wrong IP, the AWS layer still enforces the channel split.
    local rp_sg_public_name=$(cfg rp_sg_public_name "${project}-reverse-proxy-public")
    local rp_sg_internal_name=$(cfg rp_sg_internal_name "${project}-reverse-proxy-internal")
    local compute_sg_name=$(cfg compute_sg_name "${project}-k8s-node")
    local storage_sg_name=$(cfg storage_sg_name "${project}-storage")

    # AWS SG descriptions must be ASCII-only — keep them simple.
    local rp_sg_public rp_sg_internal

    rp_sg_public=$(aws_ensure_security_group \
        "$rp_sg_public_name" "OpenG2P RP public ENI - Wireguard and public services" \
        "$vpc_id" "$project" "reverse-proxy-public")
    aws_require_nonempty "RP public security group" "$rp_sg_public"
    aws_apply_sg_rules_rp_public "$rp_sg_public" "$admin_cidr" "$vpc_cidr" "$wg_port"
    log_success "  RP public SG:   ${rp_sg_public_name} (${rp_sg_public})"

    rp_sg_internal=$(aws_ensure_security_group \
        "$rp_sg_internal_name" "OpenG2P RP internal ENI - admin services only" \
        "$vpc_id" "$project" "reverse-proxy-internal")
    aws_require_nonempty "RP internal security group" "$rp_sg_internal"
    aws_apply_sg_rules_rp_internal "$rp_sg_internal" "$vpc_cidr"
    log_success "  RP internal SG: ${rp_sg_internal_name} (${rp_sg_internal})"

    compute_sg=$(aws_ensure_security_group \
        "$compute_sg_name" "OpenG2P K8s compute node" \
        "$vpc_id" "$project" "k8s-node")
    aws_require_nonempty "Compute security group" "$compute_sg"
    aws_apply_sg_rules_compute "$compute_sg" "$admin_cidr" "$vpc_cidr"
    log_success "  Compute SG:     ${compute_sg_name} (${compute_sg})"

    storage_sg=$(aws_ensure_security_group \
        "$storage_sg_name" "OpenG2P storage node - NFS and Postgres" \
        "$vpc_id" "$project" "storage")
    aws_require_nonempty "Storage security group" "$storage_sg"
    aws_apply_sg_rules_storage "$storage_sg" "$admin_cidr" "$vpc_cidr"
    log_success "  Storage SG:     ${storage_sg_name} (${storage_sg})"

    # ── 8. Elastic IP for RP (REQUIRED with multi-NIC) ─────────────────
    # The RP launches with two ENIs. AWS forbids AssociatePublicIpAddress
    # in multi-ENI launches, so the only way to give the RP a public IP
    # (= Wireguard endpoint) is to allocate + attach an Elastic IP to ENI-0.
    # If EIP allocation fails (quota), the install cannot continue.
    log_step "2" "Allocating Elastic IP for RP (required for multi-NIC)"
    local rp_eip_alloc rp_eip_addr=""
    rp_eip_alloc=$(aws_ensure_eip "$project" "reverse-proxy-eip")
    if [[ -z "$rp_eip_alloc" || "$rp_eip_alloc" == "None" ]]; then
        log_error "EIP allocation failed — required for multi-NIC RP" \
                  "AWS doesn't allow AssociatePublicIpAddress with multiple ENIs at launch, so the EIP is the only way to give the RP a public IP for Wireguard." \
                  "Free unused EIPs and re-run, OR request a quota increase in the AWS console." \
                  "aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].[AllocationId,PublicIp]' --output table" \
                  ""
        exit 1
    fi
    rp_eip_addr=$(aws_get_eip_address "$rp_eip_alloc")
    aws_require_nonempty "RP Elastic IP address" "$rp_eip_addr"
    log_success "  RP EIP: ${rp_eip_addr} (alloc: ${rp_eip_alloc})"

    # ── 9. Launch instances (parallel) ──────────────────────────────────
    log_step "3" "Launching 3 EC2 instances in parallel"

    # Auto-derive instance Name tags from project when blank in config.
    local rp_name=$(cfg rp_name "${project}-reverse-proxy")
    local compute_name=$(cfg compute_name "${project}-k8s-node-1")
    local storage_name=$(cfg storage_name "${project}-storage")

    local rp_id compute_id storage_id

    # RP — two ENIs at launch (vNIC-public for Wireguard, vNIC-internal for
    # admin Nginx). Uses aws_run_rp_instance (a specialised variant of
    # aws_run_instance that uses --network-interfaces instead of --subnet-id).
    rp_id=$(aws_find_instance "$rp_name" "$project")
    if [[ -z "$rp_id" || "$rp_id" == "None" ]]; then
        rp_id=$(aws_run_rp_instance \
            "$rp_name" "$project" \
            "$ami" "$(cfg rp_instance_type)" "$subnet_id" \
            "$rp_sg_public" "$rp_sg_internal" "$key_name" \
            "$(cfg rp_disk_gb 64)" "$(cfg rp_disk_iops 3000)" "$(cfg rp_disk_throughput 125)")
        aws_require_nonempty "RP instance ID" "$rp_id"
        log_success "  RP launched (${rp_name}, 2 ENIs):      ${rp_id}"
    else
        log_info "  RP already exists (${rp_name}): ${rp_id}"
    fi

    # Compute
    compute_id=$(aws_find_instance "$compute_name" "$project")
    if [[ -z "$compute_id" || "$compute_id" == "None" ]]; then
        compute_id=$(aws_run_instance \
            "$compute_name" "$project" "k8s-node" \
            "$ami" "$(cfg compute_instance_type)" "$subnet_id" "$compute_sg" "$key_name" \
            "$(cfg compute_disk_gb 128)" "$(cfg compute_disk_iops 3000)" "$(cfg compute_disk_throughput 125)")
        aws_require_nonempty "Compute instance ID" "$compute_id"
        log_success "  Compute launched (${compute_name}):      ${compute_id}"
    else
        log_info "  Compute already exists (${compute_name}): ${compute_id}"
    fi

    # Storage
    storage_id=$(aws_find_instance "$storage_name" "$project")
    if [[ -z "$storage_id" || "$storage_id" == "None" ]]; then
        storage_id=$(aws_run_instance \
            "$storage_name" "$project" "storage" \
            "$ami" "$(cfg storage_instance_type)" "$subnet_id" "$storage_sg" "$key_name" \
            "$(cfg storage_disk_gb 256)" "$(cfg storage_disk_iops 3000)" "$(cfg storage_disk_throughput 125)")
        aws_require_nonempty "Storage instance ID" "$storage_id"
        log_success "  Storage launched (${storage_name}):      ${storage_id}"
    else
        log_info "  Storage already exists (${storage_name}): ${storage_id}"
    fi

    # ── 10. Wait for running ────────────────────────────────────────────
    # Sequential — instances typically reach 'running' within ~30s of
    # launch, so all three are usually already there by the time we ask.
    # We tried parallel + wait-on-PIDs but `wait` was observed hanging on
    # Ubuntu after all backgrounded subshells exited (interaction between
    # the EXIT trap and subshell reaping). Sequential is rock-solid.
    log_step "4" "Waiting for all 3 instances to reach 'running' state"
    aws_wait_running "$rp_id"      "RP"
    aws_wait_running "$compute_id" "Compute"
    aws_wait_running "$storage_id" "Storage"
    log_success "All 3 instances running."

    # ── 11. Disable source/dest check on RP (Wireguard) ────────────────
    aws_disable_source_dest_check "$rp_id"
    log_success "Source/dest check disabled on RP (required for Wireguard forwarding)."

    # ── 12. Associate Elastic IP with RP (if we got one) ───────────────
    if [[ -n "$rp_eip_alloc" ]]; then
        aws_associate_eip "$rp_eip_alloc" "$rp_id"
    fi

    # ── 13. Wait for status checks (running != ready) ──────────────────
    # Sequential. With three instances launching at the same time, AWS's
    # status checks for all three usually complete close together — the
    # third one's wait often returns nearly immediately. Worst-case ~6 min
    # total, vs. ~5 min parallel. Trades a minute for reliability.
    log_step "5" "Waiting for all 3 instances to pass status checks"
    log_info "(This typically takes 2-5 minutes for the first instance,"
    log_info "then the others usually finish quickly after.)"
    aws_wait_status_ok "$rp_id"      "RP"
    aws_wait_status_ok "$compute_id" "Compute"
    aws_wait_status_ok "$storage_id" "Storage"
    log_success "All 3 instances passed status checks."

    # ── 14. Capture IPs ────────────────────────────────────────────────
    # RP has TWO ENIs — capture both private IPs separately:
    #   ENI-0 (DeviceIndex=0) → public-facing, EIP attached here
    #   ENI-1 (DeviceIndex=1) → internal, hosts admin Nginx
    local rp_eni0_private rp_eni1_private compute_ips storage_ips
    rp_eni0_private=$(aws_get_eni_private_ip "$rp_id" 0)
    rp_eni1_private=$(aws_get_eni_private_ip "$rp_id" 1)
    aws_require_nonempty "RP ENI-0 private IP" "$rp_eni0_private"
    aws_require_nonempty "RP ENI-1 private IP" "$rp_eni1_private"

    compute_ips=$(aws_get_instance_ips "$compute_id")
    storage_ips=$(aws_get_instance_ips "$storage_id")

    # rp_public_ip is the EIP attached to ENI-0 (mandatory in multi-NIC mode).
    # rp_internal_ip is ENI-1's private IP.
    local rp_public="$rp_eip_addr"
    local rp_internal="$rp_eni1_private"
    aws_require_nonempty "RP public IP (EIP)" "$rp_public"
    local compute_public="${compute_ips%|*}"
    local compute_private="${compute_ips#*|}"
    local storage_public="${storage_ips%|*}"
    local storage_private="${storage_ips#*|}"

    log_info "  RP:      public=${rp_public}  eni0(private)=${rp_eni0_private}  eni1(internal)=${rp_internal}"
    log_info "  Compute: public=${compute_public}  private=${compute_private}"
    log_info "  Storage: public=${storage_public}  private=${storage_private}"

    # ── 15. Wait for SSH on all 3 ──────────────────────────────────────
    if [[ "$SKIP_SSH_WAIT" == "true" ]]; then
        log_step "6" "Skipping SSH wait (--skip-ssh-wait)"
        log_warn "Provision-output will be written but SSH wasn't verified."
        log_warn "If openg2p-prod.sh fails its --probe step, fix SG/network and retry."
    else
        log_step "6" "Waiting for SSH to come up on all 3 instances"
        log_info "Common causes of slow SSH: cloud-init still installing the key,"
        log_info "your laptop's public IP not in admin_cidr (SG), or key perms."
        log_info "Pass --skip-ssh-wait to bypass; --ssh-timeout <sec> to extend the wait."

        aws_wait_ssh "$rp_public"      "ubuntu" "$key_path" "$SSH_WAIT_TIMEOUT" "RP"      || exit 1
        aws_wait_ssh "$compute_public" "ubuntu" "$key_path" "$SSH_WAIT_TIMEOUT" "Compute" || exit 1
        aws_wait_ssh "$storage_public" "ubuntu" "$key_path" "$SSH_WAIT_TIMEOUT" "Storage" || exit 1
    fi

    # ── 15b. Optional: provision the backup node ────────────────────────
    local backup_id="" backup_public="" backup_private=""
    if cfg_bool "backup_node.enabled"; then
        log_step "5b" "Provisioning backup node (backup_node.enabled=true)"
        provision_backup_node "$project" "$ami" "$subnet_id" "$key_name" "$key_path" \
                              "$vpc_id" "$vpc_cidr" "$admin_cidr"
        # provision_backup_node sets the locals via globals (bash subshell limit).
        backup_id="${BACKUP_INSTANCE_ID:-}"
        backup_public="${BACKUP_PUBLIC_IP:-}"
        backup_private="${BACKUP_PRIVATE_IP:-}"
    else
        log_info "Backup node not requested (backup_node.enabled=false)."
    fi

    # ── 16. Write provision-output.yaml ─────────────────────────────────
    # NB: rp_internal here is ENI-1's private IP (the admin Nginx bind
    # address). The legacy rp_private positional slot is preserved for
    # write_provision_output's existing signature — we pass rp_internal.
    write_provision_output \
        "$rp_public" "$rp_internal" \
        "$compute_public" "$compute_private" \
        "$storage_public" "$storage_private" \
        "$vpc_cidr" "$admin_cidr" "$key_path" \
        "$backup_public" "$backup_private"

    show_summary "$rp_public" "$compute_public" "$storage_public" \
                 "$key_path" "$rp_id" "$compute_id" "$storage_id" \
                 "$backup_public" "$backup_id"
}

# ---------------------------------------------------------------------------
# provision_backup_node — gated on backup_node.enabled. Creates SG + instance
# with a separate data volume. Sets globals BACKUP_INSTANCE_ID,
# BACKUP_PUBLIC_IP, BACKUP_PRIVATE_IP for the caller (avoids subshell loss).
# ---------------------------------------------------------------------------
provision_backup_node() {
    local project="$1" ami="$2" subnet_id="$3" key_name="$4" key_path="$5"
    local vpc_id="$6" vpc_cidr="$7" admin_cidr="$8"

    local sg_name=$(cfg backup_node.sg_name "${project}-backup")
    local name=$(cfg backup_node.name "${project}-backup")
    local type=$(cfg backup_node.instance_type "t3a.xlarge")
    local root_gb=$(cfg backup_node.root_disk_gb 64)
    local data_gb=$(cfg backup_node.data_disk_gb 1024)
    local data_iops=$(cfg backup_node.data_disk_iops 3000)
    local data_throughput=$(cfg backup_node.data_disk_throughput 125)

    local backup_sg
    backup_sg=$(aws_ensure_security_group \
        "$sg_name" "OpenG2P backup node - SSH" \
        "$vpc_id" "$project" "backup")
    aws_require_nonempty "Backup security group" "$backup_sg"
    aws_apply_sg_rules_backup "$backup_sg" "$admin_cidr" "$vpc_cidr"
    log_success "  Backup SG: ${sg_name} (${backup_sg})"

    BACKUP_INSTANCE_ID=$(aws_find_instance "$name" "$project")
    if [[ -z "$BACKUP_INSTANCE_ID" || "$BACKUP_INSTANCE_ID" == "None" ]]; then
        BACKUP_INSTANCE_ID=$(aws_run_backup_instance \
            "$name" "$project" "$ami" "$type" "$subnet_id" "$backup_sg" "$key_name" \
            "$root_gb" "$data_gb" "$data_iops" "$data_throughput")
        aws_require_nonempty "Backup instance ID" "$BACKUP_INSTANCE_ID"
        log_success "  Backup launched: ${BACKUP_INSTANCE_ID}"
    else
        log_info "  Backup already exists: ${BACKUP_INSTANCE_ID}"
    fi

    aws_wait_running    "$BACKUP_INSTANCE_ID" "Backup"
    aws_wait_status_ok  "$BACKUP_INSTANCE_ID" "Backup"

    local ips; ips=$(aws_get_instance_ips "$BACKUP_INSTANCE_ID")
    BACKUP_PUBLIC_IP="${ips%|*}"
    BACKUP_PRIVATE_IP="${ips#*|}"
    log_info "  Backup: public=${BACKUP_PUBLIC_IP}  private=${BACKUP_PRIVATE_IP}"

    if [[ "$SKIP_SSH_WAIT" != "true" ]]; then
        aws_wait_ssh "$BACKUP_PUBLIC_IP" "ubuntu" "$key_path" "$SSH_WAIT_TIMEOUT" "Backup" || exit 1
    fi
}

# ---------------------------------------------------------------------------
# Write a separate provision-output.yaml — only AWS-derived keys.
#
# The orchestrator loads this file as an overlay on top of prod-config.yaml,
# so AWS-provisioned values (IPs, SSH paths, etc.) win over any defaults the
# user has in prod-config. The user's hand-edited preferences in prod-config
# (cluster_name, internal_domain, keycloak_admin_email, postgres_*, etc.) are
# untouched and stable across re-provisioning.
# ---------------------------------------------------------------------------
write_provision_output() {
    # $2 is the RP's INTERNAL IP (ENI-1's private IP). Named `rp_priv` here
    # for backward-compat with the positional signature; emitted as both
    # `rp_internal_ip` (new — the orchestrator's authoritative key) AND
    # `rp_private_ip` (legacy alias for older configs still in use).
    local rp_pub="$1"      rp_priv="$2"
    local compute_pub="$3" compute_priv="$4"
    local storage_pub="$5" storage_priv="$6"
    local vpc_cidr="$7"    admin_cidr="$8"
    local key_path="$9"
    local backup_pub="${10:-}" backup_priv="${11:-}"

    local out=$(cfg provision_output_file "../provision-output.yaml")
    [[ "$out" = /* ]] || out="${SCRIPT_DIR}/${out}"
    out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"

    log_step "7" "Writing provision-output.yaml"

    # If a previous output exists, briefly archive it (single .prev — not a
    # timestamped backup, since the file is regenerable on every provision run).
    if [[ -f "$out" ]]; then
        cp "$out" "${out}.prev"
    fi

    # Make the key_path relative to prod-config.yaml's directory if we can —
    # makes the file portable across different repo checkouts.
    local key_for_prod="$key_path"
    local prod_dir
    prod_dir="$(dirname "$out")"
    case "$key_path" in
        "${prod_dir}/"*) key_for_prod="./${key_path#${prod_dir}/}" ;;
    esac

    cat > "$out" <<EOF
# =============================================================================
# OpenG2P provision-output — AWS-derived configuration
# =============================================================================
# AUTO-GENERATED by aws/openg2p-aws-provision.sh — overwritten on every run.
#
# The orchestrator (openg2p-prod.sh) loads this file AFTER prod-config.yaml,
# so values here override matching keys in prod-config.yaml.
#
# To override a value back, either:
#   1. Edit this file directly (changes survive until next provision run)
#   2. Or set the same key in prod-config.yaml with a "user override" comment
#      and tell the orchestrator to swap precedence (advanced — see README)
#
# Generated:  $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Region:     ${AWS_REGION}
# Project:    $(cfg project)
# =============================================================================

# ─── Reverse Proxy (two ENIs: public + internal) ────────────────────────
rp_public_ip:    "${rp_pub}"
rp_internal_ip:  "${rp_priv}"
rp_private_ip:   "${rp_priv}"   # legacy alias (= rp_internal_ip)
rp_ssh_host:     "${rp_pub}"
rp_ssh_user:     "ubuntu"
rp_ssh_key:      "${key_for_prod}"

# ─── Compute (K8s) ───────────────────────────────────────────────────────
compute_private_ip:  "${compute_priv}"
compute_ssh_host:    "${compute_pub}"
compute_ssh_user:    "ubuntu"
compute_ssh_key:     "${key_for_prod}"

# ─── Storage ─────────────────────────────────────────────────────────────
storage_private_ip:  "${storage_priv}"
storage_ssh_host:    "${storage_pub}"
storage_ssh_user:    "ubuntu"
storage_ssh_key:     "${key_for_prod}"

# ─── Network (derived from VPC) ──────────────────────────────────────────
private_subnet:  "${vpc_cidr}"
admin_cidr:      "${admin_cidr}"
wg_endpoint:     "${rp_pub}"
wg_port:         "$(cfg wg_port 51820)"

# ─── Identity ────────────────────────────────────────────────────────────
cluster_name:    "$(cfg project openg2p-prod)"
EOF

    # ── Optional backup node section ─────────────────────────────────────
    if [[ -n "$backup_priv" ]]; then
        cat >> "$out" <<EOF

# ─── Backup node (consumed by ../backups/openg2p-backup.sh) ──────────────
# Present only when backup_node.enabled=true in aws-config.yaml.
backup_private_ip:  "${backup_priv}"
backup_ssh_host:    "${backup_pub}"
backup_ssh_user:    "ubuntu"
backup_ssh_key:     "${key_for_prod}"
EOF
    fi

    log_success "Wrote ${out}"
}

show_summary() {
    local rp_pub="$1" compute_pub="$2" storage_pub="$3"
    local key_path="$4"
    local rp_id="$5" compute_id="$6" storage_id="$7"
    local backup_pub="${8:-}" backup_id="${9:-}"

    local out=$(cfg provision_output_file "../provision-output.yaml")
    [[ "$out" = /* ]] || out="${SCRIPT_DIR}/${out}"
    out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"

    cat <<EOF

╔════════════════════════════════════════════════════════════════════╗
║  AWS provisioning complete                                         ║
╠════════════════════════════════════════════════════════════════════╣
║                                                                    ║
║  Instances:                                                        ║
║    Reverse Proxy: ${rp_id} → ${rp_pub}
║    Compute:       ${compute_id} → ${compute_pub}
║    Storage:       ${storage_id} → ${storage_pub}
${backup_id:+║    Backup:        ${backup_id} → ${backup_pub}
}║
║  SSH key:          ${key_path}
║  provision-output: ${out}
║
║  The orchestrator auto-loads provision-output.yaml as an overlay
║  on top of prod-config.yaml. You only need to fill prod-config.yaml
║  with your own preferences (internal_domain, keycloak_admin_email,
║  versions, etc.) — IPs and SSH paths are inherited automatically.
║
║  Next:
║    cd ..
║    cp prod-config.example.yaml prod-config.yaml   # if you haven't already
║    # edit prod-config.yaml — only USER PREFERENCES, no IPs needed
║    ./openg2p-prod.sh --probe     --config prod-config.yaml
║    ./openg2p-prod.sh --preflight --config prod-config.yaml
║    ./openg2p-prod.sh             --config prod-config.yaml
║
║  Log: ${LOG_FILE}
║
╚════════════════════════════════════════════════════════════════════╝

EOF
}

main "$@"
