#!/usr/bin/env bash
# =============================================================================
# OpenG2P AWS Sandbox — helpers
# =============================================================================
# Sourced by openg2p-aws-provision.sh and openg2p-aws-destroy.sh.
# Reuses shared AWS helpers for credentials, VPC/subnet/key
# pickers, AMI resolution, waits, and YAML helpers.
# Adds sandbox-specific ManagedBy tagging, SG rules, launch, and EIP.
# =============================================================================

_SN_AWS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_SN_AWS_LIB_DIR}/../../../production/aws/lib/aws-utils.sh"

# Distinct ManagedBy so destroy only targets sandbox resources.
# NOTE: deliberately still "single-node", not "sandbox". This is an AWS TAG
# VALUE used to find and destroy existing resources. Changing it would
# orphan every already-provisioned sandbox from discovery and teardown.
SANDBOX_MANAGED_BY="openg2p-aws-single-node"

# ---------------------------------------------------------------------------
# Security group — describe-or-create with sandbox ManagedBy tag
# ---------------------------------------------------------------------------
aws_ensure_security_group_sandbox() {
    local name="$1"
    local description="$2"
    local vpc_id="$3"
    local project="$4"
    local role="$5"

    local sg_id
    sg_id=$(aws_cli ec2 describe-security-groups \
        --filters "Name=group-name,Values=${name}" "Name=vpc-id,Values=${vpc_id}" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)

    if [[ -n "$sg_id" && "$sg_id" != "None" ]]; then
        log_info "Reusing existing security group '${name}' (${sg_id}) — will verify rules" >&2
        echo "$sg_id"
        return 0
    fi

    log_info "Creating new security group '${name}'..." >&2
    sg_id=$(aws_cli ec2 create-security-group \
        --group-name "$name" \
        --description "$description" \
        --vpc-id "$vpc_id" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${project}},{Key=Role,Value=${role}},{Key=ManagedBy,Value=${SANDBOX_MANAGED_BY}}]" \
        --query 'GroupId' --output text)
    echo "$sg_id"
}

# ---------------------------------------------------------------------------
# Single-node SG ingress (mirrors create-security-group.sh)
# ---------------------------------------------------------------------------
#   • SSH + ICMP from admin_cidr
#   • Wireguard UDP from world (VPN tunnel)
#   • 80/443 from VPC (private) or 0.0.0.0/0 when public_web=true
#   • ALL from VPC (K8s API, RKE2, etcd, CNI, NodePorts, NFS, WG-decapsulated)
aws_apply_sg_rules_sandbox() {
    local sg_id="$1"
    local admin_cidr="$2"
    local vpc_cidr="$3"
    local wg_port="$4"
    local public_web="${5:-false}"

    aws_add_ingress "$sg_id" "TCP/22  from ${admin_cidr}" \
        --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${admin_cidr},Description=admin SSH}]"
    aws_add_ingress "$sg_id" "ICMP    from ${admin_cidr}" \
        --ip-permissions "IpProtocol=icmp,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=${admin_cidr},Description=admin ping}]"
    aws_add_ingress "$sg_id" "UDP/${wg_port} (Wireguard) from 0.0.0.0/0" \
        --ip-permissions "IpProtocol=udp,FromPort=${wg_port},ToPort=${wg_port},IpRanges=[{CidrIp=0.0.0.0/0,Description=Wireguard}]"

    if [[ "$public_web" == "true" || "$public_web" == "yes" || "$public_web" == "1" ]]; then
        aws_add_ingress "$sg_id" "TCP/443 from 0.0.0.0/0 (PUBLIC web)" \
            --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description=HTTPS public}]"
        aws_add_ingress "$sg_id" "TCP/80  from 0.0.0.0/0 (PUBLIC web)" \
            --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=HTTP public}]"
        log_warn "public_web=true — 80/443 open to the Internet. Pair with public_access: true in sandbox-config.yaml." >&2
    else
        aws_add_ingress "$sg_id" "TCP/443 from ${vpc_cidr} (private web)" \
            --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=${vpc_cidr},Description=HTTPS VPC}]"
        aws_add_ingress "$sg_id" "TCP/80  from ${vpc_cidr} (private web)" \
            --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=${vpc_cidr},Description=HTTP VPC}]"
    fi

    aws_add_ingress "$sg_id" "ALL from ${vpc_cidr} (intra-VPC; K8s/RKE2/NFS/WG-decapsulated)" \
        --ip-permissions "IpProtocol=-1,IpRanges=[{CidrIp=${vpc_cidr},Description=intra-VPC}]"
}

# ---------------------------------------------------------------------------
# Elastic IP — allocate-or-find with sandbox ManagedBy
# Soft-fails on quota exhaustion (caller falls back to ephemeral public IP).
# ---------------------------------------------------------------------------
aws_ensure_eip_sandbox() {
    local project="$1"
    local role_tag="$2"

    local alloc_id
    alloc_id=$(aws_cli ec2 describe-addresses \
        --filters "Name=tag:Project,Values=${project}" "Name=tag:Role,Values=${role_tag}" \
                  "Name=tag:ManagedBy,Values=${SANDBOX_MANAGED_BY}" \
        --query 'Addresses[0].AllocationId' --output text 2>/dev/null || true)

    if [[ -n "$alloc_id" && "$alloc_id" != "None" ]]; then
        log_info "Elastic IP for ${role_tag} already allocated (${alloc_id})." >&2
        echo "$alloc_id"
        return 0
    fi

    log_info "Allocating new Elastic IP for ${role_tag}..." >&2
    local result
    if ! result=$(aws_cli ec2 allocate-address --domain vpc \
            --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Project,Value=${project}},{Key=Role,Value=${role_tag}},{Key=ManagedBy,Value=${SANDBOX_MANAGED_BY}}]" \
            --query 'AllocationId' --output text 2>&1); then
        log_warn "Could not allocate Elastic IP: ${result}" >&2
        if echo "$result" | grep -q 'AddressLimitExceeded'; then
            log_warn "  EIP quota reached — provisioner will fall back to the" >&2
            log_warn "  auto-assigned public IP. Free unused EIPs or raise the quota." >&2
            log_warn "    aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].[AllocationId,PublicIp]' --output table" >&2
        fi
        echo ""
        return 0
    fi
    echo "$result"
}

# ---------------------------------------------------------------------------
# Key pair — create/verify with sandbox ManagedBy on new keys
# ---------------------------------------------------------------------------
aws_ensure_key_pair_sandbox() {
    local key_name="$1"
    local key_path="$2"
    local mode="$3"
    local project="$4"

    case "$mode" in
        create)
            local exists
            exists=$(aws_cli ec2 describe-key-pairs --key-names "$key_name" \
                --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || true)
            if [[ -n "$exists" && "$exists" != "None" ]]; then
                if [[ -f "$key_path" ]]; then
                    log_success "Key pair '${key_name}' already exists in AWS, .pem present locally."
                    return 0
                fi
                log_error "Key pair '${key_name}' exists in AWS but .pem is missing locally at ${key_path}" \
                          "Cannot recover the private key from AWS" \
                          "Either delete the AWS key pair and re-run, or copy the .pem to ${key_path}"
                return 1
            fi
            log_info "Creating new key pair '${key_name}'..."
            if [[ -d "$key_path" || "$key_path" == */ ]]; then
                log_error "key_path '${key_path}' is a directory, not a file" \
                          "Set key_path to a full .pem file path in aws-config.yaml"
                return 1
            fi
            mkdir -p "$(dirname "$key_path")"
            aws_cli ec2 create-key-pair \
                --key-name "$key_name" \
                --key-format pem \
                --tag-specifications "ResourceType=key-pair,Tags=[{Key=Project,Value=${project}},{Key=ManagedBy,Value=${SANDBOX_MANAGED_BY}}]" \
                --query 'KeyMaterial' --output text > "$key_path"
            chmod 0400 "$key_path"
            log_success "Key pair created. Private key saved to ${key_path} (mode 0400)."
            ;;
        existing)
            aws_ensure_key_pair "$key_name" "$key_path" "existing" "$project"
            ;;
        *)
            log_error "Invalid key_mode: '${mode}'" "Expected 'create' or 'existing'"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Find / launch sandbox instance (ManagedBy=openg2p-aws-single-node)
# ---------------------------------------------------------------------------
aws_find_sandbox_instance() {
    local name="$1"
    local project="$2"

    local id=""
    id=$(aws_cli ec2 describe-instances \
        --filters \
            "Name=tag:Name,Values=${name}" \
            "Name=tag:Project,Values=${project}" \
            "Name=tag:ManagedBy,Values=${SANDBOX_MANAGED_BY}" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[0].InstanceId | [0]' \
        --output text 2>/dev/null || true)

    if [[ -n "$id" && "$id" != "None" ]]; then
        echo "$id"
        return 0
    fi

    # Fallback: same Name+Project without ManagedBy (manual / legacy).
    id=$(aws_find_instance "$name" "$project")
    if [[ -n "$id" && "$id" != "None" ]]; then
        echo "$id"
        return 0
    fi
    echo ""
}

aws_run_sandbox_instance() {
    local name="$1"
    local project="$2"
    local role="$3"
    local ami="$4"
    local instance_type="$5"
    local subnet_id="$6"
    local sg_id="$7"
    local key_name="$8"
    local disk_gb="$9"
    local disk_iops="${10}"
    local disk_throughput="${11}"

    log_info "Launching sandbox (${instance_type}, ${disk_gb} GB gp3)..." >&2

    local bdm
    bdm=$(printf '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":%d,"VolumeType":"gp3","Iops":%d,"Throughput":%d,"DeleteOnTermination":true,"Encrypted":true}}]' \
        "$disk_gb" "$disk_iops" "$disk_throughput")

    local id
    id=$(aws_cli ec2 run-instances \
        --image-id "$ami" \
        --instance-type "$instance_type" \
        --key-name "$key_name" \
        --security-group-ids "$sg_id" \
        --subnet-id "$subnet_id" \
        --associate-public-ip-address \
        --block-device-mappings "$bdm" \
        --tag-specifications \
            "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${project}},{Key=Role,Value=${role}},{Key=ManagedBy,Value=${SANDBOX_MANAGED_BY}}]" \
            "ResourceType=volume,Tags=[{Key=Name,Value=${name}-root},{Key=Project,Value=${project}},{Key=Role,Value=${role}},{Key=ManagedBy,Value=${SANDBOX_MANAGED_BY}}]" \
        --query 'Instances[0].InstanceId' --output text)
    echo "$id"
}

# Resolve provision-output path from config (relative to SCRIPT_DIR).
aws_sn_provision_output_path() {
    local script_dir="$1"
    local out
    out=$(cfg provision_output_file "../provision-output.yaml")
    [[ "$out" = /* ]] || out="${script_dir}/${out}"
    echo "$(cd "$(dirname "$out")" 2>/dev/null && pwd)/$(basename "$out")"
}
