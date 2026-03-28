#!/usr/bin/env bash
# =============================================================================
# OpenG2P Multi-Node Environment Setup — Nginx Node
# =============================================================================
# Run this script on the Nginx node to:
#   1. Obtain a Let's Encrypt wildcard certificate for *.<base_domain>
#   2. Create an Nginx server block that proxies to the Istio ingress
#
# Prerequisites:
#   - Nginx is installed and running
#   - certbot is installed
#   - You have access to create DNS TXT records for the domain
#   - The Istio ingress upstream is already configured in Nginx
#
# Usage:
#   sudo ./env-nginx.sh --config env-config.yaml
#
# After this script completes:
#   - Go to your workstation and run env-cluster.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
FORCE_MODE=false

source "${SCRIPT_DIR}/lib/utils.sh"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)  CONFIG_FILE="$2"; shift 2 ;;
            --force)   FORCE_MODE=true; shift ;;
            --help|-h) show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1" \
                          "This flag is not recognized" \
                          "Run with --help to see available options"
                exit 1
                ;;
        esac
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        log_error "No config file specified" \
                  "The --config flag is required" \
                  "Provide the path to your env-config.yaml" \
                  "$0 --config env-config.yaml"
        exit 1
    fi

    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
}

show_help() {
    cat <<'EOF'
OpenG2P Multi-Node Environment Setup — Nginx Node
=====================================================

Usage:
  sudo ./env-nginx.sh --config env-config.yaml [options]

Options:
  --config <file>    Path to environment config file (required)
  --force            Re-run all steps even if already completed
  --help             Show this help message

What this script does:
  1. Obtains a Let's Encrypt wildcard certificate via DNS-01 challenge
     (you will be prompted to create TXT records)
  2. Creates an Nginx server block for *.<base_domain> → Istio ingress

After completion:
  Go to your workstation and run: ./env-cluster.sh --config env-config.yaml
EOF
}

# ---------------------------------------------------------------------------
# Step 1: Obtain Let's Encrypt wildcard certificate
# ---------------------------------------------------------------------------
step1_certificates() {
    local base_domain=$(cfg "base_domain")
    local email=$(cfg "letsencrypt_email")
    local challenge=$(cfg "letsencrypt_challenge" "dns")

    log_step "1" "Obtaining Let's Encrypt certificate for *.${base_domain}"

    if [[ -z "$email" ]]; then
        log_error "letsencrypt_email not set" \
                  "Required for obtaining Let's Encrypt certificates" \
                  "Set letsencrypt_email in your config file"
        return 1
    fi

    # Check if cert already exists
    if [[ -d "/etc/letsencrypt/live/${base_domain}" ]] && [[ "$FORCE_MODE" != "true" ]]; then
        log_success "Let's Encrypt cert for ${base_domain} already exists. Use --force to re-obtain."
        return 0
    fi

    # Wildcard certs require DNS-01 challenge
    if [[ "$challenge" == "http" ]]; then
        log_error "HTTP-01 challenge cannot issue wildcard certificates" \
                  "Environment certs need wildcard (*.${base_domain})" \
                  "Use dns, dns-cloudflare, or dns-route53 challenge" \
                  "Set letsencrypt_challenge: dns in your config"
        return 1
    fi

    check_command "certbot" "apt install certbot" || return 1

    if systemctl is-active --quiet nginx 2>/dev/null; then
        log_info "Stopping Nginx temporarily for certificate generation..."
        systemctl stop nginx
    fi

    log_info "Requesting wildcard certificate for *.${base_domain} (challenge: ${challenge})..."

    case "$challenge" in
        dns)
            echo ""
            echo -e "${YELLOW}You will be prompted to create DNS TXT records.${NC}"
            echo -e "${YELLOW}Create the records at your DNS provider, wait for propagation,${NC}"
            echo -e "${YELLOW}then press Enter in the certbot prompt to continue.${NC}"
            echo ""
            certbot certonly --manual --preferred-challenges dns --agree-tos \
                --email "$email" -d "${base_domain}" -d "*.${base_domain}" || {
                log_error "Certificate request failed for *.${base_domain}" \
                          "DNS-01 challenge failed" \
                          "Verify TXT records were created correctly" \
                          "dig TXT _acme-challenge.${base_domain}"
                # Restart nginx before exiting
                systemctl start nginx 2>/dev/null || true
                return 1
            }
            ;;
        dns-cloudflare)
            check_command "certbot" "apt install python3-certbot-dns-cloudflare" || return 1
            certbot certonly --dns-cloudflare \
                --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
                --dns-cloudflare-propagation-seconds 30 \
                --non-interactive --agree-tos --email "$email" \
                -d "${base_domain}" -d "*.${base_domain}" || {
                log_error "Certificate request failed for *.${base_domain}" \
                          "Cloudflare DNS-01 challenge failed" \
                          "Check API token and zone permissions"
                systemctl start nginx 2>/dev/null || true
                return 1
            }
            ;;
        dns-route53)
            certbot certonly --dns-route53 --dns-route53-propagation-seconds 30 \
                --non-interactive --agree-tos --email "$email" \
                -d "${base_domain}" -d "*.${base_domain}" || {
                log_error "Certificate request failed for *.${base_domain}" \
                          "Route53 DNS-01 challenge failed" \
                          "Check AWS credentials"
                systemctl start nginx 2>/dev/null || true
                return 1
            }
            ;;
        *)
            log_error "Unknown challenge type: '${challenge}'" \
                      "Valid values: dns, dns-cloudflare, dns-route53" \
                      "Set letsencrypt_challenge in your config"
            systemctl start nginx 2>/dev/null || true
            return 1
            ;;
    esac

    # Restart Nginx
    if systemctl is-enabled --quiet nginx 2>/dev/null; then
        systemctl start nginx
    fi

    log_success "Wildcard certificate obtained for *.${base_domain}."
}

# ---------------------------------------------------------------------------
# Step 2: Create Nginx server block
# ---------------------------------------------------------------------------
step2_nginx_server_block() {
    local env_name=$(cfg "environment")
    local base_domain=$(cfg "base_domain")

    log_step "2" "Creating Nginx server block for *.${base_domain}"

    # Determine cert paths
    local env_cert="/etc/letsencrypt/live/${base_domain}/fullchain.pem"
    local env_key="/etc/letsencrypt/live/${base_domain}/privkey.pem"

    for f in "$env_cert" "$env_key"; do
        if [[ ! -f "$f" ]]; then
            log_error "TLS cert not found: ${f}" \
                      "Step 1 (certificate) may not have completed" \
                      "Run this script again or check certbot output" \
                      "ls -la /etc/letsencrypt/live/${base_domain}/"
            return 1
        fi
    done

    # Check that the istio_ingress upstream exists
    if ! grep -rq "upstream.*istio_ingress" /etc/nginx/ 2>/dev/null; then
        log_warn "No 'istio_ingress' upstream found in Nginx config."
        log_warn "Make sure an upstream block exists that points to the cluster's Istio ingress."
        log_warn "Example: upstream istio_ingress { server <cluster_ip>:30080; }"
    fi

    local nginx_conf="/etc/nginx/sites-available/openg2p-env-${env_name}.conf"
    log_info "Writing Nginx config: ${nginx_conf}"

    cat > "$nginx_conf" <<EOF
# OpenG2P environment: ${env_name}
# Domain: *.${base_domain}
# Generated by env-nginx.sh — do not edit manually.

server {
    listen 80;
    server_name *.${base_domain} ${base_domain};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name *.${base_domain} ${base_domain};
    ssl_certificate     ${env_cert};
    ssl_certificate_key ${env_key};
    ssl_protocols       TLSv1.2 TLSv1.3;
    location / {
        proxy_pass                      http://istio_ingress;
        proxy_http_version              1.1;
        proxy_buffering                 on;
        proxy_buffers                   8 16k;
        proxy_buffer_size               16k;
        proxy_busy_buffers_size         32k;
        proxy_set_header                Upgrade \$http_upgrade;
        proxy_set_header                Connection "upgrade";
        proxy_set_header                Host \$host;
        proxy_set_header                X-Real-IP \$remote_addr;
        proxy_set_header                X-Forwarded-Host \$host;
        proxy_set_header                X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header                X-Forwarded-Proto https;
        proxy_pass_request_headers      on;
    }
}
EOF

    # Enable the site
    ln -sf "$nginx_conf" "/etc/nginx/sites-enabled/openg2p-env-${env_name}.conf"

    nginx -t || {
        log_error "Nginx config test failed" \
                  "Syntax error in generated config" \
                  "Review: ${nginx_conf}" \
                  "nginx -t"
        return 1
    }

    systemctl reload nginx || {
        log_error "Nginx reload failed" \
                  "Check Nginx error log" \
                  "Review Nginx status" \
                  "systemctl status nginx; journalctl -u nginx --no-pager -n 20"
        return 1
    }

    log_success "Nginx configured for *.${base_domain} → Istio ingress."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    log_banner "OpenG2P Environment Setup" "Nginx Node · TLS + Server Block"

    check_root "$@"

    load_config "$CONFIG_FILE"

    local env_name=$(cfg "environment")
    local base_domain=$(cfg "base_domain")

    if [[ -z "$env_name" ]]; then
        log_error "No environment name specified" \
                  "The 'environment' key is missing or empty" \
                  "Set environment: dev (or qa, staging, pilot) in your config"
        exit 1
    fi

    if [[ -z "$base_domain" ]]; then
        log_error "No base_domain specified" \
                  "base_domain is required for multi-node setup" \
                  "Set base_domain: qa.openg2p.org in your config"
        exit 1
    fi

    log_info "Environment:  ${BOLD}${env_name}${NC}"
    log_info "Base domain:  ${BOLD}${base_domain}${NC}"
    log_info "Config file:  ${CONFIG_FILE}"
    echo ""

    step1_certificates
    step2_nginx_server_block

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Nginx Setup Complete!                                       ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Environment:  ${BOLD}${env_name}${NC}"
    echo -e "${GREEN}║${NC}  Domain:       ${BOLD}*.${base_domain}${NC}"
    echo -e "${GREEN}║${NC}  Certificate:  Let's Encrypt wildcard"
    echo -e "${GREEN}║${NC}  Nginx:        Configured and reloaded"
    echo -e "${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}Next step:${NC}"
    echo -e "${GREEN}║${NC}  On your workstation, run:"
    echo -e "${GREEN}║${NC}    ${BOLD}./env-cluster.sh --config env-config.yaml${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

main "$@"
