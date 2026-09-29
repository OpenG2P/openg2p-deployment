#!/usr/bin/env bash
# =============================================================================
# OpenG2P AWS Add-Node — helpers
# =============================================================================
# Sourced by openg2p-aws-provision.sh and openg2p-aws-destroy.sh.
# Shared AWS helpers cover credentials, VPC/subnet/key pickers, AMI
# resolution, run-instances, waits, and YAML writers.
# Adds add-node-specific interactive pickers (instance type, disk, AZ, SG,
# instance name) and a confirmation summary.
# =============================================================================

# Resolve path relative to this file so sourcing works regardless of cwd.
_ADD_NODE_AWS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${_ADD_NODE_AWS_LIB_DIR}/../../../production/aws/lib/aws-utils.sh"

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------
# Read a line from the controlling TTY. Echoes the answer (may be empty).
aws_prompt() {
    local prompt="$1"
    local default="${2:-}"
    local answer=""
    if [[ -n "$default" ]]; then
        read -rp "${prompt} [${default}]: " answer </dev/tty
        if [[ -z "$answer" ]]; then answer="$default"; fi
    else
        read -rp "${prompt}: " answer </dev/tty
    fi
    echo "$answer"
}

# True if the string is a positive integer.
aws_is_positive_int() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# ---------------------------------------------------------------------------
# Instance type — validate against AWS, prompt with default
# ---------------------------------------------------------------------------
# Echoes the chosen instance type on stdout.
aws_pick_instance_type() {
    local cfg_type="$1"
    local default="${2:-t3a.2xlarge}"

    if [[ -n "$cfg_type" ]]; then
        if ! aws_cli ec2 describe-instance-types --instance-types "$cfg_type" \
                --query 'InstanceTypes[0].InstanceType' --output text >/dev/null 2>&1; then
            log_error "Instance type '${cfg_type}' is not available in ${AWS_REGION:-default}" \
                      "instance_type in your config is invalid or not offered in this region" \
                      "Clear instance_type to pick interactively, or choose a valid type" \
                      "aws ec2 describe-instance-types --query 'InstanceTypes[].InstanceType' --output text"
            return 1
        fi
        echo "$cfg_type"
        return 0
    fi

    if ! aws_is_tty; then
        log_info "Non-interactive — using default instance type '${default}'" >&2
        aws_save_choice instance_type "$default"
        echo "$default"
        return 0
    fi

    log_info "Select EC2 instance type (default: ${default})" >&2
    while true; do
        local pick
        pick=$(aws_prompt "  Instance type" "$default")
        if [[ -z "$pick" ]]; then
            echo "  Instance type cannot be empty." >&2
            continue
        fi
        if aws_cli ec2 describe-instance-types --instance-types "$pick" \
                --query 'InstanceTypes[0].InstanceType' --output text >/dev/null 2>&1; then
            aws_save_choice instance_type "$pick"
            echo "$pick"
            return 0
        fi
        echo "  '${pick}' is not a valid instance type in ${AWS_REGION:-default}. Try again." >&2
    done
}

# ---------------------------------------------------------------------------
# Root EBS volume size (gp3) — positive integer GiB
# ---------------------------------------------------------------------------
aws_pick_disk_gb() {
    local cfg_gb="$1"
    local default="${2:-128}"
    local min_gb="${3:-8}"

    if [[ -n "$cfg_gb" ]]; then
        if ! aws_is_positive_int "$cfg_gb"; then
            log_error "disk_gb '${cfg_gb}' is not a positive integer"
            return 1
        fi
        if (( cfg_gb < min_gb )); then
            log_error "disk_gb ${cfg_gb} is below the minimum of ${min_gb} GiB"
            return 1
        fi
        echo "$cfg_gb"
        return 0
    fi

    if ! aws_is_tty; then
        log_info "Non-interactive — using default root disk ${default} GiB gp3" >&2
        aws_save_choice disk_gb "$default"
        echo "$default"
        return 0
    fi

    log_info "Select root EBS volume size (gp3, default: ${default} GiB)" >&2
    while true; do
        local pick
        pick=$(aws_prompt "  Root volume size in GiB" "$default")
        if ! aws_is_positive_int "$pick"; then
            echo "  Enter a positive integer (e.g. 128)." >&2
            continue
        fi
        if (( pick < min_gb )); then
            echo "  Minimum is ${min_gb} GiB. Try again." >&2
            continue
        fi
        aws_save_choice disk_gb "$pick"
        echo "$pick"
        return 0
    done
}

# ---------------------------------------------------------------------------
# Availability Zone — list AZs that have at least one subnet in the VPC
# ---------------------------------------------------------------------------
# Echoes the chosen AZ name (e.g. ap-south-1a) on stdout.
aws_pick_az() {
    local vpc_id="$1"
    local cfg_az="$2"

    if [[ -n "$cfg_az" ]]; then
        # Validate AZ exists in region AND has a subnet in this VPC.
        local hit
        hit=$(aws_cli ec2 describe-subnets \
            --filters "Name=vpc-id,Values=${vpc_id}" "Name=availability-zone,Values=${cfg_az}" \
            --query 'Subnets[0].SubnetId' --output text 2>/dev/null || true)
        if [[ -z "$hit" || "$hit" == "None" ]]; then
            log_error "AZ '${cfg_az}' has no subnets in VPC ${vpc_id}" \
                      "az in your config is empty for this VPC, or the AZ name is wrong" \
                      "Clear az in aws-config.yaml to pick interactively"
            return 1
        fi
        echo "$cfg_az"
        return 0
    fi

    log_info "No az in config — querying Availability Zones with subnets in ${vpc_id}..." >&2

    # Distinct AZs that have subnets in this VPC. Tab: AZ  subnet-count
    local lines
    lines=$(aws_cli ec2 describe-subnets --filters "Name=vpc-id,Values=${vpc_id}" \
        --query 'Subnets[].AvailabilityZone' --output text 2>/dev/null \
        | tr '\t' '\n' | sort -u)

    if [[ -z "$lines" ]]; then
        log_error "No subnets (hence no AZs) in VPC ${vpc_id}" "" "Create a subnet first"
        return 1
    fi

    local -a azs=()
    while IFS= read -r az; do
        [[ -z "$az" ]] && continue
        azs+=("$az")
    done <<< "$lines"

    if [[ ${#azs[@]} -eq 1 ]]; then
        log_info "Only one AZ with subnets — using ${azs[0]}" >&2
        aws_save_choice az "${azs[0]}"
        echo "${azs[0]}"
        return 0
    fi

    if ! aws_is_tty; then
        log_error "Multiple AZs in VPC ${vpc_id}, no TTY for prompt" \
                  "Cannot pick automatically" \
                  "Set az in aws-config.yaml from the list below"
        for a in "${azs[@]}"; do echo "    ${a}" >&2; done
        return 1
    fi

    log_info "Available Availability Zones in ${vpc_id}:" >&2
    for ((i=0; i<${#azs[@]}; i++)); do
        printf "  [%d] %s\n" "$((i+1))" "${azs[$i]}" >&2
    done

    while true; do
        local pick
        read -rp "  Select [1-${#azs[@]}] or paste AZ name: " pick </dev/tty
        if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#azs[@]} )); then
            local chosen="${azs[$((pick-1))]}"
            aws_save_choice az "$chosen"
            echo "$chosen"
            return 0
        fi
        # Accept a pasted AZ name if it's in the list
        for a in "${azs[@]}"; do
            if [[ "$pick" == "$a" ]]; then
                aws_save_choice az "$pick"
                echo "$pick"
                return 0
            fi
        done
        echo "  Invalid selection, try again." >&2
    done
}

# ---------------------------------------------------------------------------
# Subnet in a specific VPC + AZ
# Prefers MapPublicIpOnLaunch=true so the instance is reachable over SSH.
# ---------------------------------------------------------------------------
aws_pick_subnet_in_az() {
    local vpc_id="$1"
    local az="$2"
    local cfg_subnet="$3"

    if [[ -n "$cfg_subnet" ]]; then
        local got
        got=$(aws_cli ec2 describe-subnets --subnet-ids "$cfg_subnet" \
            --query 'Subnets[0].[VpcId,AvailabilityZone]' --output text 2>/dev/null || true)
        local got_vpc="${got%%$'\t'*}"
        local got_az="${got##*$'\t'}"
        if [[ "$got_vpc" != "$vpc_id" || "$got_az" != "$az" ]]; then
            log_error "Subnet '${cfg_subnet}' is not in VPC '${vpc_id}' / AZ '${az}'" \
                      "subnet_id, vpc_id, and az in config don't match" \
                      "Clear subnet_id in aws-config.yaml to pick interactively"
            return 1
        fi
        echo "$cfg_subnet"
        return 0
    fi

    log_info "No subnet_id in config — querying subnets in ${vpc_id} / ${az}..." >&2

    local lines
    lines=$(aws_cli ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${vpc_id}" "Name=availability-zone,Values=${az}" \
        --query 'Subnets[].[SubnetId,CidrBlock,MapPublicIpOnLaunch,DefaultForAz,Tags[?Key==`Name`]|[0].Value]' \
        --output text 2>/dev/null)

    if [[ -z "$lines" ]]; then
        log_error "No subnets in VPC ${vpc_id} AZ ${az}" "" "Create a subnet in this AZ first"
        return 1
    fi

    local -a public_ids=() public_descs=() all_ids=() all_descs=()
    while IFS=$'\t' read -r id cidr is_pub is_def name; do
        [[ -z "$id" ]] && continue
        local namestr="" def_marker=""
        if [[ -n "$name" && "$name" != "None" ]]; then namestr=" — ${name}"; fi
        if [[ "$is_def" == "True" ]]; then def_marker=" (default-AZ)"; fi
        local desc="${id}  ${cidr}${def_marker}${namestr}"
        all_ids+=("$id");      all_descs+=("$desc")
        if [[ "$is_pub" == "True" ]]; then
            public_ids+=("$id"); public_descs+=("$desc")
        fi
    done <<< "$lines"

    local -a ids=() descs=()
    if [[ ${#public_ids[@]} -gt 0 ]]; then
        ids=("${public_ids[@]}"); descs=("${public_descs[@]}")
    else
        log_warn "No subnets with MapPublicIpOnLaunch=true in ${az}." >&2
        log_warn "Showing all subnets — instance may not get a public IP." >&2
        ids=("${all_ids[@]}"); descs=("${all_descs[@]}")
    fi

    if [[ ${#ids[@]} -eq 1 ]]; then
        log_info "Only one suitable subnet — using ${ids[0]}" >&2
        aws_save_choice subnet_id "${ids[0]}"
        echo "${ids[0]}"
        return 0
    fi

    if ! aws_is_tty; then
        log_error "Multiple subnets in ${vpc_id}/${az}, no TTY for prompt" \
                  "Cannot pick automatically" \
                  "Set subnet_id in aws-config.yaml from the list below"
        for d in "${descs[@]}"; do echo "    ${d}" >&2; done
        return 1
    fi

    log_info "Available subnets in ${vpc_id} / ${az}:" >&2
    for ((i=0; i<${#ids[@]}; i++)); do
        printf "  [%d] %s\n" "$((i+1))" "${descs[$i]}" >&2
    done

    while true; do
        local pick
        read -rp "  Select [1-${#ids[@]}] or paste Subnet ID: " pick </dev/tty
        if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#ids[@]} )); then
            local chosen="${ids[$((pick-1))]}"
            aws_save_choice subnet_id "$chosen"
            echo "$chosen"
            return 0
        fi
        if [[ "$pick" =~ ^subnet-[0-9a-f]+$ ]]; then
            if aws_cli ec2 describe-subnets --subnet-ids "$pick" >/dev/null 2>&1; then
                aws_save_choice subnet_id "$pick"
                echo "$pick"
                return 0
            fi
            echo "  '${pick}' not found, try again." >&2
            continue
        fi
        echo "  Invalid selection, try again." >&2
    done
}

# ---------------------------------------------------------------------------
# Security Group — list existing SGs in the VPC (never creates one)
# ---------------------------------------------------------------------------
# Echoes the chosen SG ID on stdout.
aws_pick_security_group() {
    local vpc_id="$1"
    local cfg_sg="$2"

    if [[ -n "$cfg_sg" ]]; then
        local got_vpc
        got_vpc=$(aws_cli ec2 describe-security-groups --group-ids "$cfg_sg" \
            --query 'SecurityGroups[0].VpcId' --output text 2>/dev/null || true)
        if [[ "$got_vpc" != "$vpc_id" ]]; then
            log_error "Security group '${cfg_sg}' is not in VPC '${vpc_id}'" \
                      "sg_id and vpc_id in config don't match" \
                      "Clear sg_id in aws-config.yaml to pick interactively"
            return 1
        fi
        echo "$cfg_sg"
        return 0
    fi

    log_info "No sg_id in config — querying security groups in ${vpc_id}..." >&2

    # Tab: GroupId  GroupName  Description
    local lines
    lines=$(aws_cli ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query 'SecurityGroups[].[GroupId,GroupName,Description]' \
        --output text 2>/dev/null)

    if [[ -z "$lines" ]]; then
        log_error "No security groups in VPC ${vpc_id}" \
                  "Cannot launch without an existing SG" \
                  "Create one (or reuse an existing cluster SG) and re-run"
        return 1
    fi

    local -a ids=() descs=()
    while IFS=$'\t' read -r id name desc; do
        [[ -z "$id" ]] && continue
        ids+=("$id")
        # Truncate long descriptions for the menu
        local dshort="$desc"
        if [[ ${#dshort} -gt 60 ]]; then dshort="${dshort:0:57}..."; fi
        descs+=("${id}  ${name}  — ${dshort}")
    done <<< "$lines"

    if [[ ${#ids[@]} -eq 1 ]]; then
        log_info "Only one security group — using ${ids[0]}" >&2
        aws_save_choice sg_id "${ids[0]}"
        echo "${ids[0]}"
        return 0
    fi

    if ! aws_is_tty; then
        log_error "Multiple security groups in VPC ${vpc_id}, no TTY for prompt" \
                  "Cannot pick automatically" \
                  "Set sg_id in aws-config.yaml from the list below"
        for d in "${descs[@]}"; do echo "    ${d}" >&2; done
        return 1
    fi

    log_info "Available security groups in ${vpc_id}:" >&2
    for ((i=0; i<${#ids[@]}; i++)); do
        printf "  [%d] %s\n" "$((i+1))" "${descs[$i]}" >&2
    done

    while true; do
        local pick
        read -rp "  Select [1-${#ids[@]}] or paste SG ID: " pick </dev/tty
        if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#ids[@]} )); then
            local chosen="${ids[$((pick-1))]}"
            aws_save_choice sg_id "$chosen"
            echo "$chosen"
            return 0
        fi
        if [[ "$pick" =~ ^sg-[0-9a-f]+$ ]]; then
            if aws_cli ec2 describe-security-groups --group-ids "$pick" >/dev/null 2>&1; then
                aws_save_choice sg_id "$pick"
                echo "$pick"
                return 0
            fi
            echo "  '${pick}' not found, try again." >&2
            continue
        fi
        echo "  Invalid selection, try again." >&2
    done
}

# ---------------------------------------------------------------------------
# Instance Name tag
# ---------------------------------------------------------------------------
aws_pick_instance_name() {
    local cfg_name="$1"
    local project="$2"
    local default="${project}-k8s-node-2"

    if [[ -n "$cfg_name" ]]; then
        if ! aws_validate_instance_name "$cfg_name"; then
            return 1
        fi
        echo "$cfg_name"
        return 0
    fi

    if ! aws_is_tty; then
        log_error "instance_name is blank and no TTY for prompt" \
                  "Cannot invent a unique Name tag in --non-interactive mode" \
                  "Set instance_name in aws-config.yaml (e.g. ${default})"
        return 1
    fi

    log_info "Enter the EC2 Name tag (appears in the AWS Console)" >&2
    while true; do
        local pick
        pick=$(aws_prompt "  Instance name" "$default")
        if aws_validate_instance_name "$pick"; then
            aws_save_choice instance_name "$pick"
            echo "$pick"
            return 0
        fi
    done
}

# AWS Name tags are free-form, but we enforce a practical subset so names
# stay usable as hostnames / add-node node_name values later.
aws_validate_instance_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        echo "  Name cannot be empty." >&2
        return 1
    fi
    if [[ ${#name} -gt 255 ]]; then
        echo "  Name exceeds 255 characters." >&2
        return 1
    fi
    # Allow letters, digits, hyphen, underscore, period, space.
    if ! [[ "$name" =~ ^[A-Za-z0-9._[:space:]-]+$ ]]; then
        echo "  Name may only contain letters, digits, . _ - and spaces." >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Key pair — resolve + ensure, re-prompting for a missing local .pem
# ---------------------------------------------------------------------------
# aws_ensure_key_pair hard-fails when key_mode=existing and the configured
# key_path is absent. That blocks re-runs after a first interactive pick
# saved a default path the operator never copied the .pem to.
#
# This wrapper:
#   1. Runs the normal pick (honours config / interactive menu)
#   2. If mode=existing and the .pem is missing, prompts for the real path
#      (TTY) or fails with a clear fix (non-interactive)
# Echoes "<mode>|<name>|<path>" like aws_pick_key_pair.
aws_resolve_key_pair() {
    local cfg_mode="$1"
    local cfg_name="$2"
    local cfg_path="$3"
    local project="$4"
    local default_dir="$5"

    local resolved
    resolved=$(aws_pick_key_pair "$cfg_mode" "$cfg_name" "$cfg_path" \
        "$project" "$default_dir") || return 1

    local mode="${resolved%%|*}"
    local rest="${resolved#*|}"
    local name="${rest%%|*}"
    local path="${rest##*|}"
    path=$(aws_expand_path "$path")

    if [[ "$mode" == "existing" && ! -f "$path" ]]; then
        log_warn "Key pair '${name}' is configured, but local .pem is missing:" >&2
        log_warn "  ${path}" >&2

        if ! aws_is_tty; then
            log_error "Key file '${path}' not found locally" \
                      "key_mode is 'existing' but key_path does not point to a real file" \
                      "Set key_path in aws-config.yaml to your .pem, or clear key_mode to re-pick" \
                      "ls ~/sshkeys/${name}.pem"
            return 1
        fi

        # Offer common guesses so the operator can accept with Enter.
        local guess=""
        for candidate in \
            "${HOME}/sshkeys/${name}.pem" \
            "${HOME}/.ssh/${name}.pem" \
            "${default_dir}/${name}.pem"
        do
            if [[ -f "$candidate" ]]; then
                guess="$candidate"
                break
            fi
        done

        log_info "Enter the path to your local .pem for '${name}'" >&2
        while true; do
            local pick
            if [[ -n "$guess" ]]; then
                pick=$(aws_prompt "  Path to ${name}.pem" "$guess")
            else
                pick=$(aws_prompt "  Path to ${name}.pem")
            fi
            pick=$(aws_expand_path "$pick")
            if [[ -f "$pick" ]]; then
                path="$pick"
                aws_save_choice key_path "$path"
                log_success "Using local key at ${path}" >&2
                break
            fi
            echo "  File not found: ${pick}. Try again (or Ctrl-C to abort)." >&2
        done
    fi

    aws_ensure_key_pair "$name" "$path" "$mode" "$project" || return 1
    echo "${mode}|${name}|${path}"
}

# ---------------------------------------------------------------------------
# Pre-launch confirmation
# ---------------------------------------------------------------------------
aws_confirm_launch() {
    local name="$1"
    local instance_type="$2"
    local disk_gb="$3"
    local ami="$4"
    local vpc_id="$5"
    local az="$6"
    local subnet_id="$7"
    local sg_id="$8"
    local key_name="$9"
    local project="${10}"

    cat >&2 <<EOF

╔════════════════════════════════════════════════════════════════════╗
║  Ready to launch EC2 instance                                      ║
╠════════════════════════════════════════════════════════════════════╣
║  Name:           ${name}
║  Type:           ${instance_type}
║  Root disk:      ${disk_gb} GiB gp3 (encrypted)
║  AMI:            ${ami}
║  Region / AZ:    ${AWS_REGION} / ${az}
║  VPC:            ${vpc_id}
║  Subnet:         ${subnet_id}
║  Security Group: ${sg_id}
║  Key pair:       ${key_name}
║  Project tag:    ${project}
╚════════════════════════════════════════════════════════════════════╝

EOF

    if ! aws_is_tty; then
        log_info "Non-interactive — proceeding without confirmation." >&2
        return 0
    fi

    local answer
    read -rp "  Proceed with launch? [Y/n]: " answer </dev/tty
    case "${answer:-Y}" in
        Y|y|yes|YES) return 0 ;;
        *)
            log_warn "Launch cancelled by user."
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Rich instance details after launch (ID, IPs, AZ, type, state, …)
# Echoes a multi-line block on stdout suitable for the summary / log.
# ---------------------------------------------------------------------------
aws_describe_instance_details() {
    local id="$1"
    aws_cli ec2 describe-instances --instance-ids "$id" \
        --query 'Reservations[0].Instances[0].{
            InstanceId:InstanceId,
            State:State.Name,
            InstanceType:InstanceType,
            PublicIp:PublicIpAddress,
            PrivateIp:PrivateIpAddress,
            PublicDns:PublicDnsName,
            PrivateDns:PrivateDnsName,
            Az:Placement.AvailabilityZone,
            SubnetId:SubnetId,
            VpcId:VpcId,
            KeyName:KeyName,
            ImageId:ImageId,
            LaunchTime:LaunchTime
        }' --output json 2>/dev/null
}

# ---------------------------------------------------------------------------
# Add-node identity — distinct ManagedBy tag so destroy never touches
# instances tagged ManagedBy=openg2p-aws-provision.
# ---------------------------------------------------------------------------
ADD_NODE_MANAGED_BY="openg2p-aws-add-node"

# Launch one Ubuntu instance tagged ManagedBy=openg2p-aws-add-node.
# Same args as aws_run_instance. Echoes instance ID on stdout.
aws_run_add_node_instance() {
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

    log_info "Launching add-node (${instance_type}, ${disk_gb} GB gp3)..." >&2

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
            "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${project}},{Key=Role,Value=${role}},{Key=ManagedBy,Value=${ADD_NODE_MANAGED_BY}}]" \
            "ResourceType=volume,Tags=[{Key=Name,Value=${name}-root},{Key=Project,Value=${project}},{Key=Role,Value=${role}},{Key=ManagedBy,Value=${ADD_NODE_MANAGED_BY}}]" \
        --query 'Instances[0].InstanceId' --output text)
    echo "$id"
}

# Find a non-terminated add-node instance by Name + Project + ManagedBy.
# Also accepts instances listed in provision-output (covers an earlier launch
# that used ManagedBy=openg2p-aws-provision before this helper existed).
aws_find_add_node_instance() {
    local name="$1"
    local project="$2"
    local output_file="${3:-}"

    local id=""
    id=$(aws_cli ec2 describe-instances \
        --filters \
            "Name=tag:Name,Values=${name}" \
            "Name=tag:Project,Values=${project}" \
            "Name=tag:ManagedBy,Values=${ADD_NODE_MANAGED_BY}" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[0].InstanceId | [0]' \
        --output text 2>/dev/null || true)

    if [[ -n "$id" && "$id" != "None" ]]; then
        echo "$id"
        return 0
    fi

    # Fallback: provision-output from a prior run of THIS script.
    if [[ -n "$output_file" && -f "$output_file" ]]; then
        local out_id out_name
        out_id=$(awk -F'"' '/^instance_id:/{print $2; exit}' "$output_file" 2>/dev/null || true)
        out_name=$(awk -F'"' '/^instance_name:/{print $2; exit}' "$output_file" 2>/dev/null || true)
        if [[ -n "$out_id" && "$out_name" == "$name" ]]; then
            local state
            state=$(aws_cli ec2 describe-instances --instance-ids "$out_id" \
                --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || true)
            case "$state" in
                pending|running|stopping|stopped)
                    echo "$out_id"
                    return 0
                    ;;
            esac
        fi
    fi

    echo ""
}

# Terminate a single instance and wait until it is fully gone.
aws_terminate_instance() {
    local id="$1"
    local label="${2:-$id}"

    log_info "Terminating ${label} (${id})..." >&2
    aws_cli ec2 terminate-instances --instance-ids "$id" \
        --query 'TerminatingInstances[0].[InstanceId,CurrentState.Name]' --output text >&2
    log_info "Waiting for ${label} to terminate..." >&2
    aws_cli ec2 wait instance-terminated --instance-ids "$id"
    log_success "  ${label}: terminated" >&2
}

# Resolve provision-output path from config (relative to SCRIPT_DIR).
aws_provision_output_path() {
    local script_dir="$1"
    local out
    out=$(cfg provision_output_file "./provision-output.yaml")
    [[ "$out" = /* ]] || out="${script_dir}/${out}"
    echo "$(cd "$(dirname "$out")" 2>/dev/null && pwd)/$(basename "$out")"
}

# Resolve which instance the destroy script should target.
# Priority:
#   1. --instance-id CLI override
#   2. instance_id in provision-output.yaml (must still exist)
#   3. instance_name in config + ManagedBy filter
#   4. Interactive menu of ManagedBy=openg2p-aws-add-node instances
# Echoes "instance_id|instance_name" on stdout.
aws_resolve_destroy_target() {
    local project="$1"
    local script_dir="$2"
    local cli_instance_id="${3:-}"

    if [[ -n "$cli_instance_id" ]]; then
        local name state managed
        local meta
        meta=$(aws_cli ec2 describe-instances --instance-ids "$cli_instance_id" \
            --query 'Reservations[0].Instances[0].[Tags[?Key==`Name`]|[0].Value,State.Name,Tags[?Key==`ManagedBy`]|[0].Value]' \
            --output text 2>/dev/null || true)
        if [[ -z "$meta" ]]; then
            log_error "Instance '${cli_instance_id}' not found"
            return 1
        fi
        name="${meta%%$'\t'*}"
        local rest="${meta#*$'\t'}"
        state="${rest%%$'\t'*}"
        managed="${rest##*$'\t'}"
        if [[ "$state" == "terminated" || "$state" == "shutting-down" ]]; then
            log_error "Instance '${cli_instance_id}' is already ${state}"
            return 1
        fi
        if [[ "$managed" != "$ADD_NODE_MANAGED_BY" ]]; then
            # Allow if it matches provision-output (legacy first launches).
            local out_path out_id
            out_path=$(aws_provision_output_path "$script_dir")
            out_id=""
            [[ -f "$out_path" ]] && out_id=$(awk -F'"' '/^instance_id:/{print $2; exit}' "$out_path" 2>/dev/null || true)
            if [[ "$out_id" != "$cli_instance_id" ]]; then
                log_error "Instance '${cli_instance_id}' is not managed by ${ADD_NODE_MANAGED_BY}" \
                          "ManagedBy=${managed:-<none>} — refusing to delete (safety)" \
                          "Only instances created by openg2p-aws-provision.sh can be destroyed here"
                return 1
            fi
            log_warn "Instance has ManagedBy=${managed:-<none>} but matches provision-output — allowing (legacy)." >&2
        fi
        [[ -z "$name" || "$name" == "None" ]] && name="$cli_instance_id"
        echo "${cli_instance_id}|${name}"
        return 0
    fi

    local out_path
    out_path=$(aws_provision_output_path "$script_dir")
    if [[ -f "$out_path" ]]; then
        local out_id out_name
        out_id=$(awk -F'"' '/^instance_id:/{print $2; exit}' "$out_path" 2>/dev/null || true)
        out_name=$(awk -F'"' '/^instance_name:/{print $2; exit}' "$out_path" 2>/dev/null || true)
        if [[ -n "$out_id" ]]; then
            local state
            state=$(aws_cli ec2 describe-instances --instance-ids "$out_id" \
                --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || true)
            case "$state" in
                pending|running|stopping|stopped)
                    log_info "Target from provision-output.yaml: ${out_id} (${out_name})" >&2
                    echo "${out_id}|${out_name:-$out_id}"
                    return 0
                    ;;
                *)
                    log_warn "provision-output instance ${out_id} is ${state:-missing} — looking further..." >&2
                    ;;
            esac
        fi
    fi

    local cfg_name
    cfg_name=$(cfg instance_name)
    if [[ -n "$cfg_name" ]]; then
        local found
        found=$(aws_find_add_node_instance "$cfg_name" "$project" "$out_path")
        if [[ -n "$found" && "$found" != "None" ]]; then
            log_info "Target from instance_name=${cfg_name}: ${found}" >&2
            echo "${found}|${cfg_name}"
            return 0
        fi
    fi

    # List ManagedBy=openg2p-aws-add-node instances for this project.
    log_info "No provision-output target — listing add-node instances for Project=${project}..." >&2
    local lines
    lines=$(aws_cli ec2 describe-instances \
        --filters \
            "Name=tag:Project,Values=${project}" \
            "Name=tag:ManagedBy,Values=${ADD_NODE_MANAGED_BY}" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`]|[0].Value,InstanceType,PrivateIpAddress,State.Name]' \
        --output text 2>/dev/null || true)

    if [[ -z "$lines" ]]; then
        log_error "No add-node instances found to destroy" \
                  "Nothing tagged ManagedBy=${ADD_NODE_MANAGED_BY} Project=${project}" \
                  "If you launched before ManagedBy tagging, pass --instance-id <id> explicitly"
        return 1
    fi

    local -a ids=() descs=()
    while IFS=$'\t' read -r id name itype pip state; do
        [[ -z "$id" ]] && continue
        ids+=("$id")
        descs+=("${id}  ${name:-?}  ${itype}  ${pip}  (${state})")
    done <<< "$lines"

    if [[ ${#ids[@]} -eq 1 ]]; then
        log_info "Only one add-node instance — targeting ${ids[0]}" >&2
        local n="${descs[0]}"
        n="${n#*  }"; n="${n%%  *}"
        echo "${ids[0]}|${n}"
        return 0
    fi

    if ! aws_is_tty; then
        log_error "Multiple add-node instances, no TTY for prompt" \
                  "Pass --instance-id or ensure provision-output.yaml is present"
        for d in "${descs[@]}"; do echo "    ${d}" >&2; done
        return 1
    fi

    log_info "Select instance to destroy:" >&2
    for ((i=0; i<${#ids[@]}; i++)); do
        printf "  [%d] %s\n" "$((i+1))" "${descs[$i]}" >&2
    done
    while true; do
        local pick
        read -rp "  Select [1-${#ids[@]}]: " pick </dev/tty
        if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#ids[@]} )); then
            local chosen="${ids[$((pick-1))]}"
            local n="${descs[$((pick-1))]}"
            n="${n#*  }"; n="${n%%  *}"
            echo "${chosen}|${n}"
            return 0
        fi
        echo "  Invalid selection, try again." >&2
    done
}
