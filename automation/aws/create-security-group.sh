#!/usr/bin/env bash
# =============================================================================
# Create AWS Security Group for OpenG2P Single-Node Deployment
# =============================================================================
# Creates a security group called "openg2p-single-node" with all the inbound
# rules required for an OpenG2P K8s cluster. The rules are multi-node ready
# (etcd, VXLAN, RKE2 supervisor ports are included for future scaling).
#
# Prerequisites:
#   - AWS CLI installed and configured (aws configure)
#   - A VPC ID where the security group should be created
#
# Usage:
#   ./create-security-group.sh --vpc-id vpc-xxxxxxxxx [--region ap-south-1] [--vpc-cidr 172.29.0.0/16]
#
# After creation:
#   1. Attach the security group to your EC2 instance
#   2. Disable source/destination check (required for Wireguard VPN):
#      aws ec2 modify-instance-attribute --instance-id i-xxx --no-source-dest-check
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SG_NAME="openg2p-single-node"
SG_DESCRIPTION="OpenG2P single-node K8s cluster — SSH, HTTPS, Wireguard, RKE2, etcd, CNI, NodePorts"
VPC_ID=""
VPC_CIDR=""
REGION=""
WG_PORT="51820"

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        --vpc-id)    VPC_ID="$2"; shift 2 ;;
        --vpc-cidr)  VPC_CIDR="$2"; shift 2 ;;
        --region)    REGION="$2"; shift 2 ;;
        --wg-port)   WG_PORT="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 --vpc-id vpc-xxxxxxxxx [--region ap-south-1] [--vpc-cidr 172.29.0.0/16] [--wg-port 51820]"
            echo ""
            echo "Options:"
            echo "  --vpc-id    VPC ID (required)"
            echo "  --vpc-cidr  VPC CIDR for inter-node rules (auto-detected if omitted)"
            echo "  --region    AWS region (uses default from aws configure if omitted)"
            echo "  --wg-port   Wireguard UDP port (default: 51820)"
            exit 0
            ;;
        *) echo "Unknown option: $1. Use --help for usage."; exit 1 ;;
    esac
done

if [[ -z "$VPC_ID" ]]; then
    echo "Error: --vpc-id is required."
    echo "Usage: $0 --vpc-id vpc-xxxxxxxxx [--region ap-south-1] [--vpc-cidr 172.29.0.0/16]"
    exit 1
fi

REGION_FLAG=""
if [[ -n "$REGION" ]]; then
    REGION_FLAG="--region ${REGION}"
fi

# ---------------------------------------------------------------------------
# Auto-detect VPC CIDR if not provided
# ---------------------------------------------------------------------------
if [[ -z "$VPC_CIDR" ]]; then
    echo "Auto-detecting VPC CIDR for ${VPC_ID}..."
    VPC_CIDR=$(aws ec2 describe-vpcs $REGION_FLAG --vpc-ids "$VPC_ID" \
        --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null)
    if [[ -z "$VPC_CIDR" || "$VPC_CIDR" == "None" ]]; then
        echo "Error: Could not auto-detect VPC CIDR. Provide it with --vpc-cidr."
        exit 1
    fi
    echo "  VPC CIDR: ${VPC_CIDR}"
fi

# ---------------------------------------------------------------------------
# Check if security group already exists
# ---------------------------------------------------------------------------
echo ""
echo "Checking if security group '${SG_NAME}' already exists in ${VPC_ID}..."
EXISTING_SG=$(aws ec2 describe-security-groups $REGION_FLAG \
    --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

if [[ -n "$EXISTING_SG" && "$EXISTING_SG" != "None" ]]; then
    echo "Security group '${SG_NAME}' already exists: ${EXISTING_SG}"
    echo "Delete it first if you want to recreate:"
    echo "  aws ec2 delete-security-group $REGION_FLAG --group-id ${EXISTING_SG}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Create the security group
# ---------------------------------------------------------------------------
echo "Creating security group '${SG_NAME}'..."
SG_ID=$(aws ec2 create-security-group $REGION_FLAG \
    --group-name "$SG_NAME" \
    --description "$SG_DESCRIPTION" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text)

echo "  Created: ${SG_ID}"

# ---------------------------------------------------------------------------
# Add inbound rules
# ---------------------------------------------------------------------------
echo ""
echo "Adding inbound rules..."

# ── Public access (from anywhere) ────────────────────────────────────────
echo "  [public] TCP 22    — SSH"
aws ec2 authorize-security-group-ingress $REGION_FLAG --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 > /dev/null

echo "  [public] TCP 443   — HTTPS (Nginx reverse proxy)"
aws ec2 authorize-security-group-ingress $REGION_FLAG --group-id "$SG_ID" \
    --protocol tcp --port 443 --cidr 0.0.0.0/0 > /dev/null

echo "  [public] TCP 80    — HTTP (redirect / Let's Encrypt)"
aws ec2 authorize-security-group-ingress $REGION_FLAG --group-id "$SG_ID" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 > /dev/null

echo "  [public] UDP ${WG_PORT}  — Wireguard VPN"
aws ec2 authorize-security-group-ingress $REGION_FLAG --group-id "$SG_ID" \
    --protocol udp --port "$WG_PORT" --cidr 0.0.0.0/0 > /dev/null

# ── Inter-node / VPC (for multi-node scaling) ────────────────────────────
echo "  [vpc]    TCP 6443  — K8s API server"
aws ec2 authorize-security-group-ingress $REGION_FLAG --group-id "$SG_ID" \
    --protocol tcp --port 6443 --cidr "$VPC_CIDR" > /dev/null

echo "  [vpc]    TCP 9345  — RKE2 supervisor (node join)"
aws ec2 authorize-security-group-ingress $REGION_FLAG --group-id "$SG_ID" \
    --protocol tcp --port 9345 --cidr "$VPC_CIDR" > /dev/null

echo "  [vpc]    TCP 10250 — Kubelet API"
aws ec2 authorize-security-group-ingress $REGION_FLAG --group-id "$SG_ID" \
    --protocol tcp --port 10250 --cidr "$VPC_CIDR" > /dev/null

echo "  [vpc]    TCP 2379  — etcd client"
aws ec2 authorize-security-group-ingress $REGION_FLAG --group-id "$SG_ID" \
    --protocol tcp --port 2379 --cidr "$VPC_CIDR" > /dev/null

echo "  [vpc]    TCP 2380  — etcd peer"
aws ec2 authorize-security-group-ingress $REGION_FLAG --group-id "$SG_ID" \
    --protocol tcp --port 2380 --cidr "$VPC_CIDR" > /dev/null

echo "  [vpc]    UDP 8472  — VXLAN (Canal/Flannel CNI)"
aws ec2 authorize-security-group-ingress $REGION_FLAG --group-id "$SG_ID" \
    --protocol udp --port 8472 --cidr "$VPC_CIDR" > /dev/null

echo "  [vpc]    TCP 9796  — Node metrics (Prometheus)"
aws ec2 authorize-security-group-ingress $REGION_FLAG --group-id "$SG_ID" \
    --protocol tcp --port 9796 --cidr "$VPC_CIDR" > /dev/null

echo "  [vpc]    TCP 30000-32767 — K8s NodePort range"
aws ec2 authorize-security-group-ingress $REGION_FLAG --group-id "$SG_ID" \
    --protocol tcp --port 30000-32767 --cidr "$VPC_CIDR" > /dev/null

echo "  [vpc]    TCP 2049  — NFS"
aws ec2 authorize-security-group-ingress $REGION_FLAG --group-id "$SG_ID" \
    --protocol tcp --port 2049 --cidr "$VPC_CIDR" > /dev/null

echo "  [vpc]    ICMP      — Ping"
aws ec2 authorize-security-group-ingress $REGION_FLAG --group-id "$SG_ID" \
    --protocol icmp --port -1 --cidr "$VPC_CIDR" > /dev/null

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "=================================================="
echo "  Security group created: ${SG_ID}"
echo "  Name:  ${SG_NAME}"
echo "  VPC:   ${VPC_ID}"
echo "=================================================="
echo ""
echo "Next steps:"
echo ""
echo "  1. Attach to your EC2 instance:"
echo "     aws ec2 modify-instance-attribute ${REGION_FLAG} \\"
echo "       --instance-id <INSTANCE_ID> \\"
echo "       --groups ${SG_ID}"
echo ""
echo "  2. Disable source/destination check (required for Wireguard VPN):"
echo "     aws ec2 modify-instance-attribute ${REGION_FLAG} \\"
echo "       --instance-id <INSTANCE_ID> \\"
echo "       --no-source-dest-check"
echo ""
