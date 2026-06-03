#!/usr/bin/env bash
# =============================================================================
# OpenG2P AWS provisioning — shared helpers
# =============================================================================
# Sourced by openg2p-aws-provision.sh and openg2p-aws-destroy.sh.
# Requires: aws CLI v2, bash 4+, jq (optional but improves error messages).
# =============================================================================

# ---------------------------------------------------------------------------
# AWS CLI wrapper — pins region and profile if set.
# ---------------------------------------------------------------------------
aws_cli() {
    local args=()
    if [[ -n "${AWS_REGION:-}"  ]]; then args+=(--region  "$AWS_REGION"); fi
    if [[ -n "${AWS_PROFILE:-}" ]]; then args+=(--profile "$AWS_PROFILE"); fi
    aws "${args[@]}" "$@"
}

# ---------------------------------------------------------------------------
# Sanity check — credentials work, account is accessible
# ---------------------------------------------------------------------------
# Expand a leading ~ to $HOME. Bash doesn't expand ~ in quoted strings or
# in values read from YAML, so config-supplied paths like "~/keys/foo.pem"
# wouldn't otherwise resolve. Echoes the expanded path on stdout.
aws_expand_path() {
    local p="$1"
    [[ -z "$p" ]] && { echo ""; return 0; }
    p="${p/#\~\//${HOME}/}"   # ~/foo  → /home/user/foo
    p="${p/#\~/${HOME}}"      # bare ~ → /home/user
    echo "$p"
}

# Fail loudly if a value is empty — guards the silent-empty trap that
# `var=$(fn_calling_aws)` falls into (set -e is suppressed inside $() so
# functions that should fail can leak through with an empty result).
aws_require_nonempty() {
    local label="$1"
    local value="$2"
    if [[ -z "$value" || "$value" == "None" ]]; then
        log_error "Empty/missing value: ${label}" \
                  "An AWS call returned no result (probably failed)" \
                  "Look for an AWS error in the lines above" \
                  "" ""
        exit 1
    fi
}

aws_check_credentials() {
    # Use --query to pull out exactly what we need as tab-separated text.
    # Avoids fragile string parsing of JSON.
    # `if !` keeps the failing case inside an "ignored by set -e" context.
    local result
    if ! result=$(aws_cli sts get-caller-identity --query '[Account,Arn]' --output text 2>&1); then
        log_error "AWS credentials check failed" \
                  "aws sts get-caller-identity returned an error" \
                  "Verify your credentials, region, and that aws CLI v2 is installed" \
                  "aws sts get-caller-identity"
        echo "$result" >&2
        return 1
    fi
    local account="${result%%$'\t'*}"
    local user="${result##*$'\t'}"
    log_success "AWS account ${account} accessible (${user})"
}

# ---------------------------------------------------------------------------
# Detect this laptop's public IP (for sensible default admin_cidr)
# ---------------------------------------------------------------------------
aws_detect_my_public_ip() {
    local ip
    ip=$(curl -sS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '\r\n ')
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "${ip}/32"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Interactivity helpers
# ---------------------------------------------------------------------------
# True if stdin is a real terminal (so prompting makes sense).
aws_is_tty() {
    [[ "${NON_INTERACTIVE:-false}" != "true" && -t 0 ]]
}

# Persist a choice back to the user's aws-config.yaml so re-runs are stable.
# CONFIG_FILE is set by the provision script's parse_args.
aws_save_choice() {
    local key="$1"
    local value="$2"
    if [[ -n "${CONFIG_FILE:-}" && -f "${CONFIG_FILE}" ]]; then
        yaml_set_key "$CONFIG_FILE" "$key" "$value"
        log_info "  ↳ Saved ${key}=${value} to $(basename "$CONFIG_FILE")" >&2
    fi
}

# ---------------------------------------------------------------------------
# VPC: smart picker
#   • config-set    → validate and use
#   • exactly one   → auto-pick (and save)
#   • multiple+TTY  → numbered prompt (and save)
#   • multiple+CI   → fail with clear list of options
# Echoes the chosen VPC ID on stdout. Logs go to stderr.
# ---------------------------------------------------------------------------
aws_pick_vpc() {
    local cfg_vpc="$1"

    if [[ -n "$cfg_vpc" ]]; then
        if ! aws_cli ec2 describe-vpcs --vpc-ids "$cfg_vpc" \
                --query 'Vpcs[0].VpcId' --output text >/dev/null 2>&1; then
            log_error "VPC '${cfg_vpc}' not found in region ${AWS_REGION:-default}" \
                      "vpc_id in your config doesn't exist or is in another region" \
                      "Clear vpc_id in aws-config.yaml to pick interactively"
            return 1
        fi
        echo "$cfg_vpc"
        return 0
    fi

    log_info "No vpc_id in config — querying available VPCs..." >&2

    # Tab-separated: VPC_ID  IsDefault  CIDR  Name
    local lines
    lines=$(aws_cli ec2 describe-vpcs \
        --query 'Vpcs[].[VpcId,IsDefault,CidrBlock,Tags[?Key==`Name`]|[0].Value]' \
        --output text 2>/dev/null)

    if [[ -z "$lines" ]]; then
        log_error "No VPCs found in region ${AWS_REGION:-default}" \
                  "Cannot proceed without a VPC" \
                  "Create one: aws ec2 create-default-vpc"
        return 1
    fi

    local -a ids=() descs=()
    while IFS=$'\t' read -r id is_default cidr name; do
        [[ -z "$id" ]] && continue
        ids+=("$id")
        local marker="" namestr=""
        if [[ "$is_default" == "True" ]]; then marker=" (default)"; fi
        if [[ -n "$name" && "$name" != "None" ]]; then namestr=" — ${name}"; fi
        descs+=("${id}  ${cidr}${marker}${namestr}")
    done <<< "$lines"

    if [[ ${#ids[@]} -eq 1 ]]; then
        log_info "Only one VPC available — using ${ids[0]} (${descs[0]#* })" >&2
        aws_save_choice vpc_id "${ids[0]}"
        echo "${ids[0]}"
        return 0
    fi

    if ! aws_is_tty; then
        log_error "Multiple VPCs in region ${AWS_REGION:-default}, no TTY for prompt" \
                  "Cannot pick automatically, --non-interactive set or no terminal" \
                  "Set vpc_id in aws-config.yaml from the list below"
        for d in "${descs[@]}"; do echo "    ${d}" >&2; done
        return 1
    fi

    log_info "Multiple VPCs available in region ${AWS_REGION:-default}:" >&2
    for ((i=0; i<${#ids[@]}; i++)); do
        printf "  [%d] %s\n" "$((i+1))" "${descs[$i]}" >&2
    done

    while true; do
        local pick
        read -rp "  Select [1-${#ids[@]}] or paste VPC ID: " pick </dev/tty
        if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#ids[@]} )); then
            local chosen="${ids[$((pick-1))]}"
            aws_save_choice vpc_id "$chosen"
            echo "$chosen"
            return 0
        fi
        if [[ "$pick" =~ ^vpc-[0-9a-f]+$ ]]; then
            # Validate the pasted ID
            if aws_cli ec2 describe-vpcs --vpc-ids "$pick" >/dev/null 2>&1; then
                aws_save_choice vpc_id "$pick"
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
# Subnet: smart picker
# Same pattern as VPC. Filters to public subnets (MapPublicIpOnLaunch=true)
# since the OpenG2P deployment requires public IPs on all 3 nodes.
# ---------------------------------------------------------------------------
aws_pick_subnet() {
    local vpc_id="$1"
    local cfg_subnet="$2"

    if [[ -n "$cfg_subnet" ]]; then
        local got_vpc
        got_vpc=$(aws_cli ec2 describe-subnets --subnet-ids "$cfg_subnet" \
            --query 'Subnets[0].VpcId' --output text 2>/dev/null)
        if [[ "$got_vpc" != "$vpc_id" ]]; then
            log_error "Subnet '${cfg_subnet}' is not in VPC '${vpc_id}'" \
                      "subnet_id and vpc_id in config don't match" \
                      "Clear subnet_id in aws-config.yaml to pick interactively"
            return 1
        fi
        echo "$cfg_subnet"
        return 0
    fi

    log_info "No subnet_id in config — querying subnets in ${vpc_id}..." >&2

    # Tab-separated: SubnetId  AZ  CIDR  MapPublicIpOnLaunch  DefaultForAz  Name
    local lines
    lines=$(aws_cli ec2 describe-subnets --filters "Name=vpc-id,Values=${vpc_id}" \
        --query 'Subnets[].[SubnetId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch,DefaultForAz,Tags[?Key==`Name`]|[0].Value]' \
        --output text 2>/dev/null)

    if [[ -z "$lines" ]]; then
        log_error "No subnets in VPC ${vpc_id}" "" "Create a subnet first"
        return 1
    fi

    local -a public_ids=() public_descs=() all_ids=() all_descs=()
    while IFS=$'\t' read -r id az cidr is_pub is_def name; do
        [[ -z "$id" ]] && continue
        local namestr="" def_marker=""
        if [[ -n "$name" && "$name" != "None" ]]; then namestr=" — ${name}"; fi
        if [[ "$is_def" == "True" ]]; then def_marker=" (default-AZ)"; fi
        local desc="${id}  ${az}  ${cidr}${def_marker}${namestr}"
        all_ids+=("$id");      all_descs+=("$desc")
        if [[ "$is_pub" == "True" ]]; then
            public_ids+=("$id"); public_descs+=("$desc")
        fi
    done <<< "$lines"

    # Prefer public subnets — that's what we need for public IP assignment.
    local -a ids=() descs=()
    if [[ ${#public_ids[@]} -gt 0 ]]; then
        ids=("${public_ids[@]}"); descs=("${public_descs[@]}")
    else
        log_warn "No subnets with MapPublicIpOnLaunch=true in this VPC." >&2
        log_warn "Showing all subnets — instances may not get public IPs unless the subnet is reconfigured." >&2
        ids=("${all_ids[@]}"); descs=("${all_descs[@]}")
    fi

    if [[ ${#ids[@]} -eq 1 ]]; then
        log_info "Only one suitable subnet — using ${ids[0]} (${descs[0]#* })" >&2
        aws_save_choice subnet_id "${ids[0]}"
        echo "${ids[0]}"
        return 0
    fi

    if ! aws_is_tty; then
        log_error "Multiple subnets in VPC ${vpc_id}, no TTY for prompt" \
                  "Cannot pick automatically" \
                  "Set subnet_id in aws-config.yaml from the list below"
        for d in "${descs[@]}"; do echo "    ${d}" >&2; done
        return 1
    fi

    log_info "Available subnets in ${vpc_id}:" >&2
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

aws_get_vpc_cidr() {
    local vpc_id="$1"
    aws_cli ec2 describe-vpcs --vpc-ids "$vpc_id" \
        --query 'Vpcs[0].CidrBlock' --output text
}

# ---------------------------------------------------------------------------
# Ubuntu 24.04 LTS AMI resolution (Canonical owner)
# ---------------------------------------------------------------------------
aws_resolve_ubuntu_ami() {
    local ami="$1"
    if [[ -n "$ami" ]]; then
        # Validate
        if ! aws_cli ec2 describe-images --image-ids "$ami" \
                --query 'Images[0].ImageId' --output text >/dev/null 2>&1; then
            log_error "AMI '${ami}' not found in this region"
            return 1
        fi
        echo "$ami"
        return 0
    fi

    log_info "Resolving latest Ubuntu Server 24.04 LTS AMI..." >&2
    local resolved
    resolved=$(aws_cli ec2 describe-images \
        --owners 099720109477 \
        --filters \
            "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
            "Name=state,Values=available" \
            "Name=architecture,Values=x86_64" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text 2>/dev/null)
    if [[ -z "$resolved" || "$resolved" == "None" ]]; then
        # Fallback: try the older naming pattern (some regions use hvm-ssd not hvm-ssd-gp3)
        resolved=$(aws_cli ec2 describe-images \
            --owners 099720109477 \
            --filters \
                "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-noble-24.04-amd64-server-*" \
                "Name=state,Values=available" \
                "Name=architecture,Values=x86_64" \
            --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
            --output text 2>/dev/null)
    fi
    if [[ -z "$resolved" || "$resolved" == "None" ]]; then
        log_error "Could not resolve an Ubuntu 24.04 AMI" \
                  "No matching Canonical AMI in this region" \
                  "Specify ubuntu_ami in your config"
        return 1
    fi
    log_info "Resolved AMI: ${resolved}" >&2
    echo "$resolved"
}

# ---------------------------------------------------------------------------
# Key pair: smart picker
#   • key_mode=create        → create new (or reuse if AWS already has it)
#   • key_mode=existing      → use the named existing key
#   • key_mode blank + TTY   → list keys + offer create-new menu
#   • key_mode blank + CI    → default to "create" with the configured name
# Echoes "<mode>|<name>|<path>" so the caller can hand off to aws_ensure_key_pair.
# ---------------------------------------------------------------------------
aws_pick_key_pair() {
    local cfg_mode="$1"
    local cfg_name="$2"
    local cfg_path="$3"
    local project="$4"
    local default_dir="$5"

    # Resolve defaults for name + path
    if [[ -z "$cfg_name" ]]; then cfg_name="${project}-key"; fi
    if [[ -z "$cfg_path" ]]; then cfg_path="${default_dir}/${cfg_name}.pem"; fi
    cfg_path=$(aws_expand_path "$cfg_path")    # ~/keys/x → /home/u/keys/x

    # If the resolved path is a directory (or ends in /), it's missing the
    # filename. Append <key_name>.pem so writes go to a file, not a dir.
    if [[ -d "$cfg_path" || "$cfg_path" == */ ]]; then
        local original="$cfg_path"
        cfg_path="${cfg_path%/}/${cfg_name}.pem"
        log_info "key_path was a directory ('${original}') — using '${cfg_path}'" >&2
        # Persist the resolved full path so subsequent runs don't re-derive it.
        aws_save_choice key_path "$cfg_path"
    fi

    # If mode is set explicitly, just pass through.
    if [[ "$cfg_mode" == "create" || "$cfg_mode" == "existing" ]]; then
        echo "${cfg_mode}|${cfg_name}|${cfg_path}"
        return 0
    fi

    # Mode blank — list existing keys and offer interactive choice
    log_info "No key_mode in config — querying existing key pairs..." >&2

    local lines
    lines=$(aws_cli ec2 describe-key-pairs \
        --query 'KeyPairs[].[KeyName,KeyType]' --output text 2>/dev/null || true)

    if ! aws_is_tty; then
        log_info "Non-interactive — defaulting to key_mode=create with name '${cfg_name}'" >&2
        aws_save_choice key_mode create
        aws_save_choice key_name "$cfg_name"
        echo "create|${cfg_name}|${cfg_path}"
        return 0
    fi

    log_info "Choose how to handle the SSH key pair:" >&2
    printf "  [%d] %s\n" 1 "Create new key pair  (will be saved to ${cfg_path})" >&2
    local -a names=()
    if [[ -n "$lines" ]]; then
        local i=1
        while IFS=$'\t' read -r name ktype; do
            [[ -z "$name" ]] && continue
            i=$((i + 1))   # avoid ((i++)) which exits 1 when i is 0 under set -e
            names+=("$name")
            printf "  [%d] %s\n" "$i" "Use existing: ${name} (${ktype})" >&2
        done <<< "$lines"
    fi

    while true; do
        local pick
        read -rp "  Select [1-$((${#names[@]}+1))]: " pick </dev/tty
        if [[ "$pick" == "1" ]]; then
            # Confirm / customize the new key name (default = pre-set value)
            local custom
            read -rp "  Name for new key pair [${cfg_name}]: " custom </dev/tty
            if [[ -n "$custom" ]]; then cfg_name="$custom"; fi
            cfg_path="${default_dir}/${cfg_name}.pem"
            aws_save_choice key_mode create
            aws_save_choice key_name "$cfg_name"
            echo "create|${cfg_name}|${cfg_path}"
            return 0
        fi
        if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 2 && pick <= ${#names[@]}+1 )); then
            local chosen="${names[$((pick-2))]}"
            # Existing key needs a local .pem path — ask user
            local default_path="${default_dir}/${chosen}.pem"
            local user_path
            read -rp "  Path to your local .pem for '${chosen}' [${default_path}]: " user_path </dev/tty
            if [[ -z "$user_path" ]]; then user_path="$default_path"; fi
            user_path=$(aws_expand_path "$user_path")
            aws_save_choice key_mode existing
            aws_save_choice key_name "$chosen"
            aws_save_choice key_path "$user_path"
            echo "existing|${chosen}|${user_path}"
            return 0
        fi
        echo "  Invalid selection, try again." >&2
    done
}

# ---------------------------------------------------------------------------
# Key pair: create-or-verify
# ---------------------------------------------------------------------------
aws_ensure_key_pair() {
    local key_name="$1"
    local key_path="$2"
    local mode="$3"     # "create" or "existing"
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
                          "Either delete the AWS key pair (aws ec2 delete-key-pair --key-name ${key_name}) and re-run, or copy the .pem file to ${key_path}"
                return 1
            fi
            log_info "Creating new key pair '${key_name}'..."
            # Sanity-check the path is a file, not a directory. Shell '>'
            # to a directory gives the cryptic "Is a directory" error.
            if [[ -d "$key_path" || "$key_path" == */ ]]; then
                log_error "key_path '${key_path}' is a directory, not a file" \
                          "Set key_path to a full .pem file path in aws-config.yaml" \
                          "Example: key_path: \"~/.ssh/openg2p-prod-key.pem\"" \
                          "" ""
                return 1
            fi
            mkdir -p "$(dirname "$key_path")"
            aws_cli ec2 create-key-pair \
                --key-name "$key_name" \
                --key-format pem \
                --tag-specifications "ResourceType=key-pair,Tags=[{Key=Project,Value=${project}},{Key=ManagedBy,Value=openg2p-aws-provision}]" \
                --query 'KeyMaterial' --output text > "$key_path"
            chmod 0400 "$key_path"
            log_success "Key pair created. Private key saved to ${key_path} (mode 0400)."
            ;;
        existing)
            local exists
            exists=$(aws_cli ec2 describe-key-pairs --key-names "$key_name" \
                --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || true)
            if [[ -z "$exists" || "$exists" == "None" ]]; then
                log_error "Key pair '${key_name}' not found in AWS" \
                          "key_mode is 'existing' but the named key pair doesn't exist" \
                          "Either import it first or switch key_mode to 'create'"
                return 1
            fi
            if [[ ! -f "$key_path" ]]; then
                log_error "Key file '${key_path}' not found locally" \
                          "key_mode is 'existing' but key_path does not point to a real file" \
                          "Place your .pem file at the configured path"
                return 1
            fi
            chmod 0400 "$key_path" 2>/dev/null || true
            log_success "Using existing key pair '${key_name}' with .pem at ${key_path}"
            ;;
        *)
            log_error "Invalid key_mode: '${mode}'" "Expected 'create' or 'existing'"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Security groups — describe-or-create with role-specific ingress
# ---------------------------------------------------------------------------
# Echoes the SG ID on stdout; logs go to stderr.
aws_ensure_security_group() {
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
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${project}},{Key=Role,Value=${role}},{Key=ManagedBy,Value=openg2p-aws-provision}]" \
        --query 'GroupId' --output text)
    echo "$sg_id"
}

# Add ingress rule (idempotent). Reports per-rule status:
#   "added"    — rule did not exist and was created
#   "exists"   — rule already present (idempotent skip; expected on re-runs
#                or when a pre-existing SG is being reused)
#   "FAILED"   — anything else (real error); script halts.
# Args after sg_id are passed verbatim to authorize-security-group-ingress.
aws_add_ingress() {
    local sg_id="$1"; shift
    local label="$1"; shift   # short human label, e.g. "TCP/22 from admin"

    local result rc
    result=$(aws_cli ec2 authorize-security-group-ingress --group-id "$sg_id" "$@" 2>&1) && rc=0 || rc=$?

    if [[ $rc -eq 0 ]]; then
        log_info "    + ${label}: added" >&2
        return 0
    fi
    if echo "$result" | grep -q 'InvalidPermission.Duplicate'; then
        log_info "    · ${label}: already present" >&2
        return 0
    fi
    log_error "Failed to add ingress rule '${label}'" \
              "AWS rejected authorize-security-group-ingress" \
              "Inspect the SG and re-run" \
              "$result" \
              ""
    exit 1
}

# ---------------------------------------------------------------------------
# Apply role-specific ingress rules.
# ---------------------------------------------------------------------------
# Public-facing ENI for the RP node:
#   • Wireguard endpoint (UDP wg_port from world)
#   • Public Nginx server blocks (env-automation will use 443 from world)
#   • Admin SSH access from admin_cidr
# Single SG for the RP node (single-NIC layout). INFRA phase only opens:
#   • SSH + ping from admin_cidr
#   • Wireguard endpoint (UDP wg_port from world)
#   • All intra-VPC traffic (admin 80/443 from compute/storage, NFS,
#     intra-cluster, WG-decapsulated egress, etc.)
#
# Public 80/443 are deliberately NOT opened here. During infra setup the only
# services are admin tools (Rancher, Keycloak), which must stay private —
# reachable only via Wireguard or from inside the VPC. Admin protection is
# enforced at three layers: this SG (no public 80/443), host ufw (admin 80/443
# only from private + WG subnets), and an nginx source-allowlist on the admin
# server blocks. The ENVIRONMENT automation opens public 80/443 later, when
# citizen-facing services actually exist; admin keeps its nginx allowlist so it
# stays unreachable from the internet even then.
aws_apply_sg_rules_rp() {
    local sg_id="$1"
    local admin_cidr="$2"
    local vpc_cidr="$3"
    local wg_port="$4"

    aws_add_ingress "$sg_id" "TCP/22  from ${admin_cidr}" \
        --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${admin_cidr},Description=admin SSH}]"
    aws_add_ingress "$sg_id" "ICMP    from ${admin_cidr}" \
        --ip-permissions "IpProtocol=icmp,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=${admin_cidr},Description=admin ping}]"
    aws_add_ingress "$sg_id" "UDP/${wg_port} (Wireguard) from 0.0.0.0/0" \
        --ip-permissions "IpProtocol=udp,FromPort=${wg_port},ToPort=${wg_port},IpRanges=[{CidrIp=0.0.0.0/0,Description=Wireguard}]"
    aws_add_ingress "$sg_id" "ALL     from ${vpc_cidr} (intra-VPC; covers admin 80/443 from compute/storage and WG-decapsulated egress)" \
        --ip-permissions "IpProtocol=-1,IpRanges=[{CidrIp=${vpc_cidr},Description=intra-VPC}]"
}

aws_apply_sg_rules_compute() {
    local sg_id="$1"; local admin_cidr="$2"; local vpc_cidr="$3"
    aws_add_ingress "$sg_id" "TCP/22  from ${admin_cidr}" \
        --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${admin_cidr},Description=admin SSH}]"
    aws_add_ingress "$sg_id" "ICMP    from ${admin_cidr}" \
        --ip-permissions "IpProtocol=icmp,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=${admin_cidr},Description=admin ping}]"
    aws_add_ingress "$sg_id" "ALL     from ${vpc_cidr} (intra-VPC)" \
        --ip-permissions "IpProtocol=-1,IpRanges=[{CidrIp=${vpc_cidr},Description=intra-VPC}]"
}

aws_apply_sg_rules_storage() {
    local sg_id="$1"; local admin_cidr="$2"; local vpc_cidr="$3"
    aws_add_ingress "$sg_id" "TCP/22  from ${admin_cidr}" \
        --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${admin_cidr},Description=admin SSH}]"
    aws_add_ingress "$sg_id" "ICMP    from ${admin_cidr}" \
        --ip-permissions "IpProtocol=icmp,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=${admin_cidr},Description=admin ping}]"
    aws_add_ingress "$sg_id" "ALL     from ${vpc_cidr} (intra-VPC)" \
        --ip-permissions "IpProtocol=-1,IpRanges=[{CidrIp=${vpc_cidr},Description=intra-VPC}]"
}

# ---------------------------------------------------------------------------
# Elastic IP — allocate-or-find by Project tag + Role tag
# ---------------------------------------------------------------------------
# Try to allocate (or find existing) an Elastic IP. Soft-fails: on any error
# (typically AddressLimitExceeded), echoes empty and returns 0 — caller must
# fall back to the auto-assigned dynamic public IP.
aws_ensure_eip() {
    local project="$1"
    local role_tag="$2"     # e.g. "reverse-proxy-eip"

    local alloc_id
    alloc_id=$(aws_cli ec2 describe-addresses \
        --filters "Name=tag:Project,Values=${project}" "Name=tag:Role,Values=${role_tag}" \
        --query 'Addresses[0].AllocationId' --output text 2>/dev/null || true)

    if [[ -n "$alloc_id" && "$alloc_id" != "None" ]]; then
        log_info "Elastic IP for ${role_tag} already allocated (${alloc_id})." >&2
        echo "$alloc_id"
        return 0
    fi

    log_info "Allocating new Elastic IP for ${role_tag}..." >&2
    local result
    if ! result=$(aws_cli ec2 allocate-address --domain vpc \
            --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Project,Value=${project}},{Key=Role,Value=${role_tag}},{Key=ManagedBy,Value=openg2p-aws-provision}]" \
            --query 'AllocationId' --output text 2>&1); then
        log_warn "Could not allocate Elastic IP: ${result}" >&2
        if echo "$result" | grep -q 'AddressLimitExceeded'; then
            log_warn "  EIP quota reached. Free unused ones with:" >&2
            log_warn "    aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].[AllocationId,PublicIp]' --output table" >&2
            log_warn "    aws ec2 release-address --allocation-id <alloc-id>" >&2
            log_warn "  Or request a quota increase in the AWS console." >&2
        fi
        echo ""
        return 0
    fi
    echo "$result"
}

aws_get_eip_address() {
    local alloc_id="$1"
    aws_cli ec2 describe-addresses --allocation-ids "$alloc_id" \
        --query 'Addresses[0].PublicIp' --output text
}

aws_associate_eip() {
    local alloc_id="$1"; local instance_id="$2"

    # Skip if already associated to this instance
    local current
    current=$(aws_cli ec2 describe-addresses --allocation-ids "$alloc_id" \
        --query 'Addresses[0].InstanceId' --output text 2>/dev/null || true)
    if [[ "$current" == "$instance_id" ]]; then
        log_info "Elastic IP ${alloc_id} already associated to ${instance_id}." >&2
        return 0
    fi

    # For multi-ENI instances, target ENI-0 (DeviceIndex=0) explicitly —
    # `--instance-id` alone fails with "must specify a private IP address or
    # network interface ID" on multi-ENI instances.
    local eni0
    eni0=$(aws_cli ec2 describe-instances --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].NetworkInterfaces[?Attachment.DeviceIndex==`0`].NetworkInterfaceId | [0]' \
        --output text 2>/dev/null)

    if [[ -n "$eni0" && "$eni0" != "None" ]]; then
        aws_cli ec2 associate-address --allocation-id "$alloc_id" \
            --network-interface-id "$eni0" \
            --query 'AssociationId' --output text >/dev/null
    else
        # Fallback for single-ENI instances (compute, storage if ever used)
        aws_cli ec2 associate-address --allocation-id "$alloc_id" \
            --instance-id "$instance_id" \
            --query 'AssociationId' --output text >/dev/null
    fi
    log_success "Associated Elastic IP ${alloc_id} → ${instance_id}." >&2
}

# ---------------------------------------------------------------------------
# Instances
# ---------------------------------------------------------------------------
# Looks up an instance by Name tag + Project tag, in non-terminated state.
# Echoes instance ID or empty.
aws_find_instance() {
    local name="$1"; local project="$2"
    aws_cli ec2 describe-instances \
        --filters \
            "Name=tag:Name,Values=${name}" \
            "Name=tag:Project,Values=${project}" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[0].InstanceId | [0]' \
        --output text 2>/dev/null
}

aws_run_instance() {
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

    log_info "Launching ${role} (${instance_type}, ${disk_gb} GB gp3)..." >&2

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
            "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${project}},{Key=Role,Value=${role}},{Key=ManagedBy,Value=openg2p-aws-provision}]" \
            "ResourceType=volume,Tags=[{Key=Project,Value=${project}},{Key=Role,Value=${role}},{Key=ManagedBy,Value=openg2p-aws-provision}]" \
        --query 'Instances[0].InstanceId' --output text)
    echo "$id"
}

aws_disable_source_dest_check() {
    local id="$1"
    # RP is now single-ENI, so the simple instance-level form works. (The
    # multi-ENI form would require --network-interface-id targeting; that
    # path was removed along with the dual-NIC launch.)
    aws_cli ec2 modify-instance-attribute --instance-id "$id" --no-source-dest-check
}

aws_get_instance_ips() {
    local id="$1"
    # Echoes "public_ip|private_ip"
    aws_cli ec2 describe-instances --instance-ids "$id" \
        --query 'Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress]' \
        --output text | awk '{print $1"|"$2}'
}

aws_wait_running() {
    local id="$1"; local label="${2:-$id}"
    log_info "Waiting for ${label} (${id}) to reach 'running'..." >&2
    aws_cli ec2 wait instance-running --instance-ids "$id"
    log_success "  ${label}: running" >&2
}

aws_wait_status_ok() {
    local id="$1"; local label="${2:-$id}"
    log_info "Waiting for ${label} (${id}) status checks (typically 2-5 min)..." >&2
    aws_cli ec2 wait instance-status-ok --instance-ids "$id"
    log_success "  ${label}: status checks passed" >&2
}

# Wait for SSH to be reachable. Verbose: prints a progress line every ~30s
# with the last SSH error so a stalled wait is visible. Returns 0 on success,
# 1 on timeout. Increase the per-call timeout if your AMI's cloud-init is slow.
aws_wait_ssh() {
    local host="$1"
    local user="$2"
    local key="$3"
    local timeout="${4:-600}"
    local label="${5:-$host}"

    log_info "Waiting for SSH on ${label} (${user}@${host}, up to ${timeout}s)..." >&2

    local start_ts; start_ts=$(date +%s)
    local end=$(( start_ts + timeout ))
    local attempt=0 last_err=""

    while [[ $(date +%s) -lt $end ]]; do
        attempt=$((attempt + 1))
        if last_err=$(ssh -i "$key" \
                -o BatchMode=yes \
                -o StrictHostKeyChecking=accept-new \
                -o ConnectTimeout=5 \
                -o UserKnownHostsFile=/dev/null \
                -o LogLevel=ERROR \
                "${user}@${host}" "true" 2>&1); then
            local elapsed=$(( $(date +%s) - start_ts ))
            log_success "  ${label}: SSH up (attempt ${attempt}, ${elapsed}s)" >&2
            return 0
        fi
        # Periodic progress every ~30s so the user sees it's still trying
        # and what's blocking — common causes: SG missing your IP, key perms,
        # cloud-init not yet finished installing the public key.
        if (( attempt % 6 == 0 )); then
            local elapsed=$(( $(date +%s) - start_ts ))
            local err_summary; err_summary=$(echo "$last_err" | tr '\n' ' ' | cut -c1-120)
            log_info "  ${label}: still waiting (${elapsed}s / ${timeout}s, attempt ${attempt}) — last error: ${err_summary}" >&2
        fi
        sleep 5
    done

    log_error "Timed out waiting for SSH on ${label}" \
              "Could not SSH to ${user}@${host} within ${timeout}s" \
              "Last error: ${last_err}" \
              "ssh -i ${key} ${user}@${host}"
    return 1
}

# ---------------------------------------------------------------------------
# YAML key writer — flat one-key-per-line schema (matches prod-config.yaml).
# Updates in place, or appends if key not present.
# ---------------------------------------------------------------------------
yaml_set_key() {
    local file="$1"
    local key="$2"
    local value="$3"

    # Quote the value to avoid YAML ambiguity
    local quoted="\"${value//\"/\\\"}\""

    if grep -q "^${key}:" "$file" 2>/dev/null; then
        local tmp
        tmp=$(mktemp)
        awk -v k="$key" -v v="$quoted" '
            $0 ~ "^"k":" { print k": "v; next }
            { print }
        ' "$file" > "$tmp"
        mv "$tmp" "$file"
    else
        echo "${key}: ${quoted}" >> "$file"
    fi
}
