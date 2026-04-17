#!/usr/bin/env bash
# =============================================================================
# OpenG2P Domain Migration
# =============================================================================
# Migrates an OpenG2P deployment from local mode (self-signed certs,
# *.openg2p.test) to custom mode (public domain names, Let's Encrypt).
#
# This is a non-destructive operation: no data is lost, no services are
# reinstalled. Only domain-related configuration is updated.
#
# What it does:
#   Phase 1: Infrastructure domain migration
#     - Validates DNS records for new hostnames
#     - Obtains Let's Encrypt certificates for Rancher + Keycloak
#     - Updates Nginx server blocks with new hostnames and cert paths
#     - Patches Keycloak KC_HOSTNAME to new hostname
#     - Updates Rancher server-url
#     - Re-configures Rancher-Keycloak SAML with new hostnames
#     - Removes CoreDNS local domain forward (no longer needed)
#     - Updates infra-config.yaml
#
#   Phase 2: Per-environment migration (for each environment listed)
#     - Obtains Let's Encrypt wildcard cert for *.new_base_domain
#     - Updates Nginx env server block
#     - Patches Istio Gateway with new hosts
#     - Helm upgrades commons-base and commons-services with new domain
#     - Updates env-config.yaml
#
# Usage:
#   sudo ./openg2p-migrate-domain.sh --config migrate-config.yaml
#
# Rollback: Backup files (.pre-migration) are created for all modified configs.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
LOG_FILE="/var/log/openg2p-migrate-$(date '+%Y%m%d-%H%M%S').log"

source "${SCRIPT_DIR}/lib/utils.sh"
source "${SCRIPT_DIR}/lib/phase1.sh"
source "${SCRIPT_DIR}/lib/phase3.sh"
source "${SCRIPT_DIR}/lib/env-phase1.sh"

# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)  CONFIG_FILE="$2"; shift 2 ;;
            --help|-h) show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1" \
                          "Run with --help to see options" \
                          "$0 --help"
                exit 1
                ;;
        esac
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        log_error "No config file specified" \
                  "The --config flag is required" \
                  "Copy migrate-config.example.yaml and edit it" \
                  "$0 --config migrate-config.yaml"
        exit 1
    fi

    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
}

show_help() {
    cat <<'EOF'
OpenG2P Domain Migration
===========================

Migrates from local mode (self-signed, *.openg2p.test) to custom mode
(public domains, Let's Encrypt). Non-destructive — no data loss.

Usage:
  sudo ./openg2p-migrate-domain.sh --config migrate-config.yaml

Options:
  --config <file>    Path to migration config file (required)
  --help             Show this help message

Prerequisites:
  - Infrastructure running in local mode
  - DNS A records for new hostnames point to the VM
  - infra-config.yaml and env-config files on the VM
EOF
}

# ---------------------------------------------------------------------------
# Helper: backup a file before modifying
# ---------------------------------------------------------------------------
backup_file() {
    local file="$1"
    local backup="${file}.pre-migration"
    if [[ -f "$file" && ! -f "$backup" ]]; then
        cp "$file" "$backup"
        log_info "Backed up: ${file} → ${backup}"
    fi
}

# ---------------------------------------------------------------------------
# Helper: update a YAML config file key (simple sed-based, handles top-level
# and one-level nested keys)
# ---------------------------------------------------------------------------
update_yaml_key() {
    local file="$1"
    local key="$2"
    local value="$3"

    if [[ "$key" == *.* ]]; then
        # Nested key: e.g., keycloak.admin_email
        local parent="${key%%.*}"
        local child="${key#*.}"
        # Match "  child: ..." under the parent section
        sed -i "s|^\([[:space:]]*\)${child}:.*|  ${child}: \"${value}\"|" "$file"
    else
        # Top-level key
        if grep -q "^${key}:" "$file"; then
            sed -i "s|^${key}:.*|${key}: \"${value}\"|" "$file"
        else
            # Key doesn't exist — append it
            echo "${key}: \"${value}\"" >> "$file"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Phase 1: Infrastructure domain migration
# ---------------------------------------------------------------------------
migrate_infra() {
    log_step "M1" "Phase 1 — Infrastructure Domain Migration"

    local new_rancher_host=$(cfg "new_rancher_hostname")
    local new_keycloak_host=$(cfg "new_keycloak_hostname")
    local new_domain_mode=$(cfg "new_domain_mode" "custom")
    local tls_method=$(cfg "tls.method" "letsencrypt")
    local node_ip=$(cfg "node_ip")

    if [[ -z "$new_rancher_host" || -z "$new_keycloak_host" ]]; then
        log_error "new_rancher_hostname and new_keycloak_hostname are required"
        return 1
    fi

    # ── M1.1: Validate DNS ──────────────────────────────────────────────
    log_info "Validating DNS records for new hostnames..."
    check_dns_for_domains "$node_ip" "$new_rancher_host" "$new_keycloak_host"

    # ── M1.2: Obtain/install TLS certificates ───────────────────────────
    # Temporarily set config values so cert functions resolve correctly
    CONFIG["rancher_hostname"]="$new_rancher_host"
    CONFIG["keycloak_hostname"]="$new_keycloak_host"
    CONFIG["domain_mode"]="custom"
    CONFIG["tls.method"]="$tls_method"

    if [[ "$tls_method" == "provided" ]]; then
        log_info "Installing user-provided TLS certificates..."

        local rancher_cert_src=$(cfg "tls.rancher_cert" "")
        local rancher_key_src=$(cfg "tls.rancher_key" "")
        local keycloak_cert_src=$(cfg "tls.keycloak_cert" "")
        local keycloak_key_src=$(cfg "tls.keycloak_key" "")

        if [[ -z "$keycloak_cert_src" && -n "$rancher_cert_src" ]]; then
            keycloak_cert_src="$rancher_cert_src"
            keycloak_key_src="$rancher_key_src"
        fi

        install_provided_cert "$new_rancher_host" "$rancher_cert_src" "$rancher_key_src" || return 1
        install_provided_cert "$new_keycloak_host" "$keycloak_cert_src" "$keycloak_key_src" || return 1
    else
        log_info "Obtaining Let's Encrypt certificates..."
        local le_email=$(cfg "tls.letsencrypt_email" "")
        local le_challenge=$(cfg "tls.letsencrypt_challenge" "dns")

        CONFIG["tls.letsencrypt_email"]="$le_email"
        CONFIG["tls.letsencrypt_challenge"]="$le_challenge"

        local cf_token=$(cfg "tls.cloudflare_api_token" "")
        if [[ -n "$cf_token" ]]; then
            CONFIG["tls.cloudflare_api_token"]="$cf_token"
        fi

        phase1_step8_certificates_letsencrypt
    fi

    # Ensure Nginx is running (cert generation may have stopped it)
    if systemctl is-enabled --quiet nginx 2>/dev/null && ! systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl start nginx
    fi

    # ── M1.3: Update Nginx infra server blocks ──────────────────────────
    log_info "Updating Nginx infrastructure server blocks..."

    local rancher_cert rancher_key keycloak_cert keycloak_key
    rancher_cert=$(get_cert_path "$new_rancher_host" "cert")
    rancher_key=$(get_cert_path "$new_rancher_host" "key")
    keycloak_cert=$(get_cert_path "$new_keycloak_host" "cert")
    keycloak_key=$(get_cert_path "$new_keycloak_host" "key")

    backup_file "/etc/nginx/sites-available/openg2p-infra.conf"

    cat > /etc/nginx/sites-available/openg2p-infra.conf <<EOF
upstream istio_ingress {
    server ${node_ip}:30080;
}
server {
    listen 80;
    server_name ${new_rancher_host} ${new_keycloak_host};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name ${new_rancher_host};
    ssl_certificate     ${rancher_cert};
    ssl_certificate_key ${rancher_key};
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
server {
    listen 443 ssl;
    server_name ${new_keycloak_host};
    ssl_certificate     ${keycloak_cert};
    ssl_certificate_key ${keycloak_key};
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

    nginx -t || { log_error "Nginx config test failed"; return 1; }
    systemctl reload nginx
    log_success "Nginx updated for ${new_rancher_host} and ${new_keycloak_host}."

    # ── M1.4: Patch Keycloak KC_HOSTNAME ────────────────────────────────
    log_info "Patching Keycloak KC_HOSTNAME to ${new_keycloak_host}..."

    ensure_kubeconfig || return 1

    kubectl -n keycloak-system set env statefulset/keycloak \
        "KC_HOSTNAME=${new_keycloak_host}" > /dev/null 2>&1 || {
        log_warn "Could not patch KC_HOSTNAME via set env, trying direct patch..."
        kubectl -n keycloak-system get statefulset keycloak -o json | \
            jq --arg host "$new_keycloak_host" '
                (.spec.template.spec.containers[0].env) |=
                (map(select(.name != "KC_HOSTNAME")) + [{"name":"KC_HOSTNAME","value":$host}])
            ' | kubectl apply -f - > /dev/null 2>&1
    }

    log_info "Waiting for Keycloak to restart with new hostname..."
    kubectl -n keycloak-system rollout status statefulset/keycloak --timeout=180s || {
        log_warn "Keycloak rollout status timed out. It may still be restarting."
    }
    sleep 10
    log_success "Keycloak KC_HOSTNAME set to ${new_keycloak_host}."

    # ── M1.5: Update Keycloak Istio Gateway + VirtualService ────────────
    log_info "Updating Keycloak Istio Gateway and VirtualService..."

    # Update the Gateway
    kubectl -n keycloak-system get gateway keycloak -o json 2>/dev/null | \
        jq --arg host "$new_keycloak_host" \
           '.spec.servers[0].hosts = [$host]' | \
        kubectl apply -f - > /dev/null 2>&1 || log_warn "Could not update Keycloak Gateway."

    # Update the VirtualService
    kubectl -n keycloak-system get virtualservice keycloak -o json 2>/dev/null | \
        jq --arg host "$new_keycloak_host" \
           '.spec.hosts = [$host]' | \
        kubectl apply -f - > /dev/null 2>&1 || log_warn "Could not update Keycloak VirtualService."

    log_success "Keycloak Istio routing updated."

    # ── M1.6: Update Rancher server-url ──────────────────────────────────
    log_info "Updating Rancher server-url to https://${new_rancher_host}..."

    local rancher_admin_password="${RANCHER_ADMIN_PASSWORD:-}"

    if [[ -z "$rancher_admin_password" ]]; then
        rancher_admin_password=$(cat /var/lib/openg2p/deploy-state/rancher-admin-password 2>/dev/null || true)
    fi

    if [[ -z "$rancher_admin_password" ]]; then
        rancher_admin_password=$(kubectl -n cattle-system get secret rancher-secret \
            -o jsonpath='{.data.adminPassword}' 2>/dev/null | base64 -d 2>/dev/null || true)
    fi

    if [[ -z "$rancher_admin_password" ]]; then
        log_warn "Could not find Rancher admin password. Skipping Rancher server-url update."
        log_warn "Update manually: Rancher → Global Settings → server-url"
    else
        # Try login with old URL first, then new
        local rancher_token=""
        local old_rancher_host=$(get_rancher_hostname)
        for try_url in "https://${new_rancher_host}" "https://${old_rancher_host}"; do
            rancher_token=$(rancher_try_login "$try_url" "$rancher_admin_password")
            if [[ -n "$rancher_token" ]]; then
                break
            fi
        done

        if [[ -n "$rancher_token" ]]; then
            rancher_api PUT "https://${new_rancher_host}/v3/settings/server-url" "$rancher_token" \
                "{\"value\":\"https://${new_rancher_host}\"}" > /dev/null 2>&1 || \
            rancher_api PUT "https://${old_rancher_host}/v3/settings/server-url" "$rancher_token" \
                "{\"value\":\"https://${new_rancher_host}\"}" > /dev/null 2>&1
            log_success "Rancher server-url updated."
        else
            log_warn "Could not login to Rancher. Update server-url manually."
        fi
    fi

    # ── M1.7: Re-configure SAML with new hostnames ──────────────────────
    log_info "Re-configuring Rancher-Keycloak SAML for new hostnames..."

    # Override hostnames in CONFIG so phase3 functions use new values
    CONFIG["domain_mode"]="custom"
    CONFIG["rancher_hostname"]="$new_rancher_host"
    CONFIG["keycloak_hostname"]="$new_keycloak_host"

    # Reset the phase3 state marker so it re-runs
    rm -f "${STATE_DIR}/phase3.rancher_keycloak.done"
    FORCE_MODE=true
    run_phase3

    log_success "SAML re-configured for new hostnames."

    # ── M1.8: Remove CoreDNS local domain forward ───────────────────────
    log_info "Removing CoreDNS local domain forward (no longer needed)..."

    local old_local_domain=$(cfg "local_domain" "openg2p.test")
    local current_corefile
    current_corefile=$(kubectl -n kube-system get configmap rke2-coredns-rke2-coredns \
        -o jsonpath='{.data.Corefile}' 2>/dev/null || true)

    if echo "$current_corefile" | grep -q "${old_local_domain}"; then
        kubectl -n kube-system get configmap rke2-coredns-rke2-coredns -o json | \
            jq --arg domain "${old_local_domain}" '
                .data.Corefile = (.data.Corefile | split("\n") |
                    reduce .[] as $line (
                        {in_block: false, depth: 0, lines: []};
                        if (.in_block) then
                            if ($line | test("\\{")) then .depth += 1
                            elif ($line | test("\\}")) then
                                if .depth == 0 then .in_block = false
                                else .depth -= 1 end
                            else . end
                        elif ($line | test($domain + ":53")) then
                            .in_block = true
                        else
                            .lines += [$line]
                        end
                    ) | .lines | join("\n")
                )
            ' | kubectl apply -f - > /dev/null 2>&1 || log_warn "Could not remove CoreDNS local domain forward."

        kubectl -n kube-system rollout restart deployment rke2-coredns-rke2-coredns > /dev/null 2>&1 || true
        log_success "CoreDNS local domain forward removed."
    else
        log_info "CoreDNS has no local domain forward — nothing to remove."
    fi

    # ── M1.9: Update infra-config.yaml ──────────────────────────────────
    log_info "Updating infra-config.yaml..."

    local infra_config_path=$(cfg "infra_config" "infra-config.yaml")
    [[ "$infra_config_path" = /* ]] || infra_config_path="${SCRIPT_DIR}/${infra_config_path}"

    if [[ -f "$infra_config_path" ]]; then
        backup_file "$infra_config_path"
        update_yaml_key "$infra_config_path" "domain_mode" "$new_domain_mode"
        update_yaml_key "$infra_config_path" "rancher_hostname" "$new_rancher_host"
        update_yaml_key "$infra_config_path" "keycloak_hostname" "$new_keycloak_host"
        update_yaml_key "$infra_config_path" "tls.method" "$tls_method"
        if [[ "$tls_method" == "letsencrypt" ]]; then
            local le_email=$(cfg "tls.letsencrypt_email" "")
            local le_challenge=$(cfg "tls.letsencrypt_challenge" "dns")
            update_yaml_key "$infra_config_path" "tls.letsencrypt_email" "$le_email"
            update_yaml_key "$infra_config_path" "tls.letsencrypt_challenge" "$le_challenge"
        fi
        log_success "infra-config.yaml updated."
    else
        log_warn "infra-config.yaml not found at ${infra_config_path}. Update it manually."
    fi

    log_success "Phase 1 — Infrastructure domain migration complete."
}

# ---------------------------------------------------------------------------
# Phase 2: Per-environment domain migration
# ---------------------------------------------------------------------------
migrate_environments() {
    log_step "M2" "Phase 2 — Environment Domain Migration"

    local node_ip=$(cfg "node_ip")
    local new_keycloak_host=$(cfg "new_keycloak_hostname")
    local new_keycloak_url="https://${new_keycloak_host}"
    local le_email=$(cfg "tls.letsencrypt_email" "$(cfg 'letsencrypt_email' '')")
    local le_challenge=$(cfg "tls.letsencrypt_challenge" "$(cfg 'letsencrypt_challenge' 'dns')")

    # Parse environment list from config
    # The YAML parser doesn't handle arrays, so we parse the environments
    # section manually from the migration config file.
    local env_index=0
    while true; do
        local env_name env_config env_domain
        # Read environment entries using grep/awk from the raw config file
        env_name=$(awk "/^environments:/{found=1} found && /- name:/{i++; if(i==$((env_index+1))) print \$3}" "$CONFIG_FILE" | tr -d '"' | tr -d "'")

        [[ -z "$env_name" ]] && break

        env_config=$(awk "/^environments:/{found=1} found && /config_file:/{i++; if(i==$((env_index+1))) print \$2}" "$CONFIG_FILE" | tr -d '"' | tr -d "'")
        env_domain=$(awk "/^environments:/{found=1} found && /new_base_domain:/{i++; if(i==$((env_index+1))) print \$2}" "$CONFIG_FILE" | tr -d '"' | tr -d "'")

        if [[ -z "$env_domain" ]]; then
            log_warn "No new_base_domain for environment '${env_name}' — skipping."
            env_index=$((env_index + 1))
            continue
        fi

        log_info "━━━ Migrating environment: ${env_name} → ${env_domain} ━━━"

        migrate_single_environment "$env_name" "$env_config" "$env_domain" \
            "$node_ip" "$new_keycloak_url" "$le_email" "$le_challenge"

        env_index=$((env_index + 1))
    done

    if [[ $env_index -eq 0 ]]; then
        log_info "No environments listed in migration config — skipping Phase 2."
    else
        log_success "Phase 2 — All ${env_index} environment(s) migrated."
    fi
}

migrate_single_environment() {
    local env_name="$1"
    local env_config_file="$2"
    local new_base_domain="$3"
    local node_ip="$4"
    local new_keycloak_url="$5"
    local le_email="$6"
    local le_challenge="$7"

    ensure_kubeconfig || return 1

    # Check namespace exists
    if ! kubectl get namespace "$env_name" &>/dev/null; then
        log_warn "Namespace '${env_name}' does not exist — skipping."
        return 0
    fi

    # ── E1: Let's Encrypt wildcard cert ─────────────────────────────────
    log_info "[${env_name}] Obtaining wildcard cert for *.${new_base_domain}..."

    if [[ -d "/etc/letsencrypt/live/${new_base_domain}" ]]; then
        log_info "Cert for ${new_base_domain} already exists."
    else
        CONFIG["letsencrypt_email"]="$le_email"
        CONFIG["letsencrypt_challenge"]="$le_challenge"
        CONFIG["domain_mode"]="custom"

        # Wildcard certs require DNS-01
        if [[ "$le_challenge" == "http" ]]; then
            log_error "HTTP challenge cannot issue wildcard certs for *.${new_base_domain}" \
                      "Use dns, dns-cloudflare, or dns-route53"
            return 1
        fi

        if systemctl is-active --quiet nginx 2>/dev/null; then
            systemctl stop nginx
        fi

        case "$le_challenge" in
            dns)
                certbot certonly --manual --preferred-challenges dns --agree-tos \
                    --email "$le_email" -d "${new_base_domain}" -d "*.${new_base_domain}" || {
                    log_error "Cert failed for *.${new_base_domain}"; return 1; } ;;
            dns-cloudflare)
                certbot certonly --dns-cloudflare \
                    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
                    --dns-cloudflare-propagation-seconds 30 \
                    --non-interactive --agree-tos --email "$le_email" \
                    -d "${new_base_domain}" -d "*.${new_base_domain}" || {
                    log_error "Cert failed for *.${new_base_domain}"; return 1; } ;;
            dns-route53)
                certbot certonly --dns-route53 --dns-route53-propagation-seconds 30 \
                    --non-interactive --agree-tos --email "$le_email" \
                    -d "${new_base_domain}" -d "*.${new_base_domain}" || {
                    log_error "Cert failed for *.${new_base_domain}"; return 1; } ;;
        esac

        if systemctl is-enabled --quiet nginx 2>/dev/null; then
            systemctl start nginx
        fi
        log_success "[${env_name}] Wildcard cert obtained for *.${new_base_domain}."
    fi

    # ── E2: Update Nginx env server block ───────────────────────────────
    log_info "[${env_name}] Updating Nginx server block..."

    local env_cert="/etc/letsencrypt/live/${new_base_domain}/fullchain.pem"
    local env_key="/etc/letsencrypt/live/${new_base_domain}/privkey.pem"
    local nginx_conf="/etc/nginx/sites-available/openg2p-env-${env_name}.conf"

    backup_file "$nginx_conf"

    cat > "$nginx_conf" <<EOF
# OpenG2P environment: ${env_name}
# Domain: *.${new_base_domain}
# Generated by openg2p-migrate-domain.sh

server {
    listen 80;
    server_name *.${new_base_domain} ${new_base_domain};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name *.${new_base_domain} ${new_base_domain};
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

    nginx -t && systemctl reload nginx
    log_success "[${env_name}] Nginx updated for *.${new_base_domain}."

    # ── E3: Patch Istio Gateway ─────────────────────────────────────────
    log_info "[${env_name}] Updating Istio Gateway..."

    kubectl -n "$env_name" get gateway internal -o json 2>/dev/null | \
        jq --arg domain "$new_base_domain" \
           '.spec.servers[0].hosts = [$domain, ("*." + $domain)]' | \
        kubectl apply -f - > /dev/null 2>&1 || log_warn "Could not update Istio Gateway."

    log_success "[${env_name}] Istio Gateway updated for *.${new_base_domain}."

    # ── E4: Helm upgrade commons-base ───────────────────────────────────
    log_info "[${env_name}] Upgrading commons-base with new domain..."

    # The commons-base chart deploys its own per-env Keycloak and derives
    # both keycloakBaseUrl and keycloakInternalUrl from baseDomain/Release.Name
    # automatically. Do NOT override those — changing baseDomain cascades.
    if helm status commons -n "$env_name" &>/dev/null; then
        helm upgrade commons $(helm get metadata commons -n "$env_name" -o json 2>/dev/null | jq -r '.chart // "openg2p/openg2p-commons-base"') \
            -n "$env_name" \
            --reuse-values \
            --set "global.baseDomain=${new_base_domain}" \
            --timeout 10m --wait || {
            log_warn "[${env_name}] commons-base upgrade failed. May need manual intervention."
        }
        log_success "[${env_name}] commons-base upgraded."
    else
        log_info "[${env_name}] commons-base release not found — skipping."
    fi

    # ── E5: Helm upgrade commons-services ───────────────────────────────
    log_info "[${env_name}] Upgrading commons-services with new domain..."

    if helm status commons-services -n "$env_name" &>/dev/null; then
        helm upgrade commons-services $(helm get metadata commons-services -n "$env_name" -o json 2>/dev/null | jq -r '.chart // "openg2p/openg2p-commons-services"') \
            -n "$env_name" \
            --reuse-values \
            --set "global.baseDomain=${new_base_domain}" \
            --timeout 10m --wait || {
            log_warn "[${env_name}] commons-services upgrade failed. May need manual intervention."
        }
        log_success "[${env_name}] commons-services upgraded."
    else
        log_info "[${env_name}] commons-services release not found — skipping."
    fi

    # ── E6: Update env-config.yaml ──────────────────────────────────────
    if [[ -n "$env_config_file" ]]; then
        local env_config_path="$env_config_file"
        [[ "$env_config_path" = /* ]] || env_config_path="${SCRIPT_DIR}/${env_config_path}"
        if [[ -f "$env_config_path" ]]; then
            backup_file "$env_config_path"
            update_yaml_key "$env_config_path" "base_domain" "$new_base_domain"
            log_success "[${env_name}] env-config.yaml updated."
        else
            log_warn "env-config not found at ${env_config_path}. Update manually."
        fi
    fi

    log_success "[${env_name}] Environment migration complete."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    log_banner "OpenG2P Domain Migration" "Local → Custom mode"

    check_root "$@"
    init_state_dir
    ensure_kubeconfig || exit 1

    # Load migration config
    load_config "$CONFIG_FILE"

    # Load infra config for node_ip, current hostnames, etc.
    local infra_config_path=$(cfg "infra_config" "infra-config.yaml")
    [[ "$infra_config_path" = /* ]] || infra_config_path="${SCRIPT_DIR}/${infra_config_path}"
    if [[ -f "$infra_config_path" ]]; then
        load_config "$infra_config_path"
        # Re-load migration config so its values take precedence
        load_config "$CONFIG_FILE"
    else
        log_error "infra-config.yaml not found at ${infra_config_path}"
        exit 1
    fi

    local new_rancher=$(cfg "new_rancher_hostname")
    local new_keycloak=$(cfg "new_keycloak_hostname")

    echo ""
    log_info "Current mode:     ${BOLD}$(cfg 'domain_mode' 'local')${NC}"
    log_info "New mode:         ${BOLD}$(cfg 'new_domain_mode' 'custom')${NC}"
    log_info "New Rancher:      ${BOLD}${new_rancher}${NC}"
    log_info "New Keycloak:     ${BOLD}${new_keycloak}${NC}"
    log_info "Node IP:          ${BOLD}$(cfg 'node_ip')${NC}"
    echo ""

    # Confirmation
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  DOMAIN MIGRATION                                           ║${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║${NC}  This will migrate the deployment from local mode to        ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}  custom mode with the new domain names shown above.         ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}                                                              ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}  Config files will be updated in place (backups created).    ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}  No data will be lost — this is a non-destructive operation. ${YELLOW}║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "Type MIGRATE to proceed: " confirm
    if [[ "$confirm" != "MIGRATE" ]]; then
        log_info "Migration cancelled."
        exit 0
    fi
    echo ""

    migrate_infra
    migrate_environments

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}║   Domain Migration Complete!                                 ║${NC}"
    echo -e "${GREEN}║                                                              ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Rancher:   ${BOLD}https://${new_rancher}${NC}"
    echo -e "${GREEN}║${NC}  Keycloak:  ${BOLD}https://${new_keycloak}${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Config files updated (backups: *.pre-migration)             ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  ${BOLD}Laptop steps:${NC}                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    1. You can remove /etc/resolver entries (local DNS)       ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    2. You can remove the self-signed CA from trust store     ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    3. Update Wireguard peer DNS (optional — public DNS works)${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}    4. Update kubectl config if hostnames changed              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Log: ${LOG_FILE}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

exec > >(tee -a "$LOG_FILE") 2>&1

main "$@"
