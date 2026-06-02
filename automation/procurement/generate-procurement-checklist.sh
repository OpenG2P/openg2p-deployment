#!/usr/bin/env bash
# =============================================================================
# OpenG2P Procurement Checklist Generator
# =============================================================================
# Reads deployment-plan.yaml and prints a single, printable checklist that
# the customer hands to their network / cert / IT team.
#
# The plan should list ALL environments you intend to bring up. Procurement
# (especially TLS cert issuance from sovereign/commercial CAs) typically
# takes 2-4 weeks; planning every environment up front avoids serialising
# multiple procurement cycles.
#
# Usage:
#   ./generate-procurement-checklist.sh --plan deployment-plan.yaml
#   ./generate-procurement-checklist.sh --plan deployment-plan.yaml --out checklist.txt
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN_FILE=""
OUT_FILE=""
COLOR=true

# Reuse the YAML parser + logging from the environment automation.
source "${SCRIPT_DIR}/../environment/lib/utils.sh"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --plan)     PLAN_FILE="$2"; shift 2 ;;
            --out)      OUT_FILE="$2"; shift 2 ;;
            --no-color) COLOR=false; shift ;;
            --help|-h)  show_help; exit 0 ;;
            *)
                echo "Unknown option: $1" >&2
                echo "Run with --help for usage." >&2
                exit 1
                ;;
        esac
    done

    if [[ -z "$PLAN_FILE" ]]; then
        echo "Error: --plan is required." >&2
        echo "Usage: $0 --plan deployment-plan.yaml" >&2
        exit 1
    fi

    [[ "$PLAN_FILE" = /* ]] || PLAN_FILE="${SCRIPT_DIR}/${PLAN_FILE}"

    if [[ ! -f "$PLAN_FILE" ]]; then
        echo "Error: plan file not found: ${PLAN_FILE}" >&2
        echo "Copy deployment-plan.example.yaml to deployment-plan.yaml and edit it." >&2
        exit 1
    fi
}

show_help() {
    cat <<'EOF'
OpenG2P Procurement Checklist Generator
=======================================

Generates a printable checklist of everything to procure for an
OpenG2P deployment — DNS records, TLS certs, server access.

Usage:
  ./generate-procurement-checklist.sh --plan <file> [options]

Options:
  --plan <file>   Path to deployment-plan.yaml (required)
  --out <file>    Write checklist to a file in addition to stdout
  --no-color      Disable ANSI colour codes (recommended when --out is set)
  --help          Show this help

What gets printed:
  1. DNS A records to register (admin + every environment)
  2. TLS certificates to obtain (admin + every environment, wildcard)
  3. Where each cert should be placed on the Nginx node
  4. Server access requirements (SSH, kubectl)
  5. Network port requirements

Hand the printed output to your customer's network/cert/IT team
2-4 weeks before the planned install date.
EOF
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Strip ANSI sequences. Used when writing to a file.
strip_ansi() {
    sed -E 's/\x1B\[[0-9;]*[mK]//g'
}

# Conditionally apply colour. Wraps text in $1 colour code, or returns plain.
c() {
    if [[ "$COLOR" == "true" ]]; then
        printf '\033[%sm%s\033[0m' "$1" "$2"
    else
        printf '%s' "$2"
    fi
}

# Split comma-separated env list into an array.
parse_env_list() {
    local raw="$1"
    # Replace commas with spaces, then read into the array.
    local cleaned="${raw//,/ }"
    # shellcheck disable=SC2206
    ENVS=($cleaned)
}

# ---------------------------------------------------------------------------
# Section: title
# ---------------------------------------------------------------------------
print_header() {
    local org=$(cfg "organization" "(organization not set)")
    local hr
    hr=$(printf '═%.0s' $(seq 1 78))

    echo "$hr"
    echo "$(c '1;36' '  PROCUREMENT CHECKLIST — OpenG2P Deployment')"
    echo "  ${org}"
    echo "$hr"
    echo
    cat <<'EOF'
This document lists every DNS record, TLS certificate, and access
requirement needed to install OpenG2P end-to-end (infrastructure +
planned environments).

Hand this to your network, certificate, and IT teams as early as
possible — TLS certificate issuance (especially from sovereign or
commercial CAs) typically takes 2-4 weeks.

Once everything in this checklist is in place, the automation can
run infrastructure + environment installs back-to-back with no
mid-deployment delays.

EOF
}

# ---------------------------------------------------------------------------
# Section 1: DNS A records
# ---------------------------------------------------------------------------
print_dns_section() {
    local nginx_ip=$(cfg "nginx_node_ip")
    local rancher_host=$(cfg "rancher_hostname")
    local keycloak_host=$(cfg "keycloak_hostname")

    echo "$(c '1;33' '─── 1. DNS A RECORDS ─────────────────────────────────────────────────')"
    echo
    echo "  All hostnames below must resolve to the Nginx node's public IP:"
    echo "      $(c '1' "${nginx_ip}")"
    echo
    echo "  Admin hostnames (required):"

    if [[ -n "$rancher_host" ]]; then
        printf "      A   %-45s → %s\n" "${rancher_host}" "${nginx_ip}"
    fi
    if [[ -n "$keycloak_host" ]]; then
        printf "      A   %-45s → %s\n" "${keycloak_host}" "${nginx_ip}"
    fi
    echo

    echo "  Environment hostnames (one base + one wildcard per environment):"
    local env
    for env in "${ENVS[@]}"; do
        [[ -z "$env" ]] && continue
        local domain
        domain=$(cfg "env_${env}_base_domain")
        if [[ -z "$domain" ]]; then
            echo "      $(c '1;31' "⚠  env_${env}_base_domain is not set in the plan file")"
            continue
        fi
        printf "      A   %-45s → %s\n" "${domain}" "${nginx_ip}"
        printf "      A   %-45s → %s\n" "*.${domain}" "${nginx_ip}"
    done
    echo
}

# ---------------------------------------------------------------------------
# Section 2: TLS certificates
# ---------------------------------------------------------------------------
print_tls_section() {
    local rancher_host=$(cfg "rancher_hostname")
    local keycloak_host=$(cfg "keycloak_hostname")

    echo "$(c '1;33' '─── 2. TLS CERTIFICATES TO OBTAIN ────────────────────────────────────')"
    echo
    cat <<'EOF'
  Procure wildcard certs (per environment) and single-host certs (admin
  hostnames) from your chosen Certificate Authority — commercial CA
  (DigiCert, GlobalSign, Sectigo) or your country's sovereign / government
  CA. Let's Encrypt is suitable for sandboxes / PoCs but is rarely
  acceptable for production government deployments.

  Required format: PEM-encoded files with the full chain bundled
  (fullchain.pem). Accepted by the install scripts:
      • PEM fullchain + key       (*.fullchain.pem + *.key)
      • Separate cert + chain     (*.cert.pem + *.chain.pem + *.key)
      • PFX / P12                 (*.pfx / *.p12, with password)
      • ZIP bundle                (Sectigo / DigiCert style)

EOF

    echo "  Admin certificates:"
    if [[ -n "$rancher_host" ]]; then
        printf "      • %-45s (single-host cert)\n" "${rancher_host}"
    fi
    if [[ -n "$keycloak_host" ]]; then
        printf "      • %-45s (single-host cert)\n" "${keycloak_host}"
    fi
    echo

    echo "  Environment certificates (one wildcard per environment):"
    local env
    for env in "${ENVS[@]}"; do
        [[ -z "$env" ]] && continue
        local domain
        domain=$(cfg "env_${env}_base_domain")
        [[ -z "$domain" ]] && continue
        printf "      • %-45s (wildcard cert, must include apex)\n" "*.${domain}"
    done
    echo
}

# ---------------------------------------------------------------------------
# Section 3: Cert placement
# ---------------------------------------------------------------------------
print_placement_section() {
    local cert_base
    cert_base=$(cfg "cert_base_path" "/etc/openg2p/certs")

    echo "$(c '1;33' '─── 3. CERT PLACEMENT ON NGINX NODE ──────────────────────────────────')"
    echo
    echo "  Each cert should be placed on the Nginx (Reverse-Proxy) node at:"
    echo
    echo "      ${cert_base}/<domain>/fullchain.pem    (mode 644)"
    echo "      ${cert_base}/<domain>/privkey.pem      (mode 600)"
    echo
    echo "  Concrete paths for this deployment:"

    local rancher_host=$(cfg "rancher_hostname")
    local keycloak_host=$(cfg "keycloak_hostname")

    if [[ -n "$rancher_host" ]]; then
        echo "      ${cert_base}/${rancher_host}/"
    fi
    if [[ -n "$keycloak_host" ]]; then
        echo "      ${cert_base}/${keycloak_host}/"
    fi

    local env
    for env in "${ENVS[@]}"; do
        [[ -z "$env" ]] && continue
        local domain
        domain=$(cfg "env_${env}_base_domain")
        [[ -z "$domain" ]] && continue
        echo "      ${cert_base}/${domain}/"
    done
    echo
}

# ---------------------------------------------------------------------------
# Section 4: Server access
# ---------------------------------------------------------------------------
print_access_section() {
    local ssh_user=$(cfg "ssh_user" "ubuntu")
    local admin_cidr=$(cfg "admin_workstation_cidr" "(operator's public IP /32)")

    echo "$(c '1;33' '─── 4. SERVER ACCESS REQUIRED ────────────────────────────────────────')"
    echo
    cat <<EOF
  • SSH access to the Reverse-Proxy (Nginx) node
        user: ${ssh_user}
        from: ${admin_cidr}
  • SSH access to the cluster control-plane node(s)
        (only if not already covered by the operator workstation)
  • kubectl admin access to the cluster (kubeconfig file on the
        operator's workstation, with cluster-admin rights)

EOF
}

# ---------------------------------------------------------------------------
# Section 5: Network ports
# ---------------------------------------------------------------------------
print_ports_section() {
    echo "$(c '1;33' '─── 5. NETWORK PORTS / FIREWALL ──────────────────────────────────────')"
    echo
    cat <<'EOF'
  Nginx (Reverse Proxy) node:
      • 443/TCP   public        (citizen + admin HTTPS — admin via VPN only)
      • 80/TCP    public        (HTTP → 443 redirect)
      • 22/TCP    admin CIDR    (SSH)
      • 51820/UDP public        (Wireguard, if used)

  Cluster control-plane node:
      • 6443/TCP  operator      (Kubernetes API — kubectl)
      • internal mesh ports     (CNI, kubelet — within private subnet)

  Storage node (if separate):
      • 5432/TCP  private only  (PostgreSQL — cluster-internal access)
      • 2049/TCP  private only  (NFS — cluster-internal access)

EOF
}

# ---------------------------------------------------------------------------
# Section 6: Adding more environments later
# ---------------------------------------------------------------------------
print_addendum() {
    echo "$(c '1;33' '─── 6. ADDING MORE ENVIRONMENTS LATER ────────────────────────────────')"
    echo
    cat <<'EOF'
  If you need to bring up another environment after the initial deployment:

    1. Append the new env to the `environments:` list in
       deployment-plan.yaml and add its `env_<name>_base_domain` entry.
    2. Re-run this generator. The new checklist will list only the
       additional DNS records and certs you still need.
    3. Once those are in place, run:
           ./env-cluster.sh --config <env-config.yaml>

  No infrastructure rebuild needed — each environment is independent.

EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    # If writing to a file, force --no-color to keep the file clean.
    if [[ -n "$OUT_FILE" && "$COLOR" == "true" ]]; then
        COLOR=false
    fi

    # Parse the plan.
    load_config "$PLAN_FILE"

    local env_list
    env_list=$(cfg "environments" "")
    if [[ -z "$env_list" ]]; then
        echo "Error: 'environments' is not set in the plan file." >&2
        echo "Example: environments: \"dev,qa,prod\"" >&2
        exit 1
    fi
    parse_env_list "$env_list"

    # Render to stdout (and optionally to file).
    if [[ -n "$OUT_FILE" ]]; then
        {
            print_header
            print_dns_section
            print_tls_section
            print_placement_section
            print_access_section
            print_ports_section
            print_addendum
        } | tee "$OUT_FILE"
        echo
        echo "Checklist also written to: ${OUT_FILE}"
    else
        print_header
        print_dns_section
        print_tls_section
        print_placement_section
        print_access_section
        print_ports_section
        print_addendum
    fi
}

main "$@"
