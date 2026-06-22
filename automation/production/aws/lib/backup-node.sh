#!/usr/bin/env bash
# =============================================================================
# OpenG2P AWS Provisioning — optional backup node helpers
# =============================================================================
# Sourced by openg2p-aws-provision.sh ONLY when backup_node.enabled=true.
# Provisions a 4th instance + a separate EBS data volume formatted and
# mounted at /var/lib/openg2p-backup via cloud-init.
# =============================================================================

# ---------------------------------------------------------------------------
# aws_apply_sg_rules_backup — SSH ingress from admin_cidr + intra-VPC.
# Argument: <sg_id> <admin_cidr> <vpc_cidr>
# Idempotent — same pattern as the existing aws_apply_sg_rules_* functions.
# ---------------------------------------------------------------------------
aws_apply_sg_rules_backup() {
    local sg_id="$1"
    local admin_cidr="$2"
    local vpc_cidr="$3"

    # SSH from admin (laptop) — for the orchestrator's install/restore use.
    aws_sg_authorize_ingress "$sg_id" "tcp" 22 22 "$admin_cidr" "SSH from admin" || true

    # SSH from anywhere in the VPC — RP/compute/storage may probe back during
    # install (e.g. host-key acceptance for archive_command). Cheap to allow.
    aws_sg_authorize_ingress "$sg_id" "tcp" 22 22 "$vpc_cidr" "SSH from VPC" || true

    # Postgres archive_command pushes to the backup host over SSH (port 22),
    # already covered by VPC ingress above. No separate port needed.
}

# ---------------------------------------------------------------------------
# aws_run_backup_instance — create instance with TWO block-device-mappings:
# /dev/sda1 root + /dev/sdf data. The data volume is formatted ext4 and
# mounted at /var/lib/openg2p-backup via cloud-init userdata.
#
# Args:
#   <name> <project> <ami> <type> <subnet> <sg> <key>
#   <root_gb> <data_gb> <data_iops> <data_throughput>
# Echoes the instance ID.
# ---------------------------------------------------------------------------
aws_run_backup_instance() {
    local name="$1" project="$2" ami="$3" type="$4" subnet="$5" sg="$6" key="$7"
    local root_gb="$8" data_gb="$9" data_iops="${10}" data_throughput="${11}"

    # cloud-init userdata: discover the second NVMe volume by-id (avoids the
    # /dev/sd* → /dev/nvme*n1 renaming on Nitro), format ext4, mkdir, fstab,
    # mount. Idempotent — won't reformat if already ext4.
    local userdata
    userdata=$(cat <<'UD'
#!/bin/bash
set -e
exec >>/var/log/openg2p-backup-userdata.log 2>&1

# Find the data volume — second non-root NVMe / xvd disk.
data_dev=""
for d in /dev/nvme1n1 /dev/xvdf /dev/sdf; do
    [[ -b "$d" ]] && { data_dev="$d"; break; }
done
[[ -z "$data_dev" ]] && { echo "no data volume found"; exit 0; }

# Format only if not already formatted.
fs=$(blkid -s TYPE -o value "$data_dev" || true)
if [[ -z "$fs" ]]; then
    mkfs.ext4 -L openg2p-backup -F "$data_dev"
fi

mkdir -p /var/lib/openg2p-backup
uuid=$(blkid -s UUID -o value "$data_dev")
grep -qE "UUID=$uuid" /etc/fstab || echo "UUID=$uuid /var/lib/openg2p-backup ext4 defaults,noatime 0 2" >> /etc/fstab
mountpoint -q /var/lib/openg2p-backup || mount /var/lib/openg2p-backup
chmod 0750 /var/lib/openg2p-backup
UD
)

    # Block device mapping JSON — two volumes.
    local bdm
    bdm=$(cat <<JSON
[
  {
    "DeviceName": "/dev/sda1",
    "Ebs": { "VolumeSize": ${root_gb}, "VolumeType": "gp3", "DeleteOnTermination": true, "Encrypted": true }
  },
  {
    "DeviceName": "/dev/sdf",
    "Ebs": { "VolumeSize": ${data_gb}, "VolumeType": "gp3", "Iops": ${data_iops}, "Throughput": ${data_throughput}, "DeleteOnTermination": false, "Encrypted": true }
  }
]
JSON
)

    local tagspec
    tagspec="ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${project}},{Key=Role,Value=backup}]"

    # --associate-public-ip-address: the deployer SSHes to the backup node by
    # public IP to install/run openg2p-backup.sh (same model as Compute/Storage).
    # Its SG already restricts SSH to admin_cidr, so the posture is unchanged.
    # Use aws_cli (not bare aws) so AWS_REGION/AWS_PROFILE are honoured.
    aws_cli ec2 run-instances \
        --image-id "$ami" \
        --instance-type "$type" \
        --subnet-id "$subnet" \
        --security-group-ids "$sg" \
        --key-name "$key" \
        --associate-public-ip-address \
        --block-device-mappings "$bdm" \
        --tag-specifications "$tagspec" \
        --user-data "$userdata" \
        --query 'Instances[0].InstanceId' \
        --output text
}
