#!/usr/bin/env bash
# =============================================================================
# OpenG2P Environment Setup — Phase 1: Environment Infrastructure
# =============================================================================
# Sets up per-environment infrastructure on the VM:
#   - TLS certificate for *.<base_domain>
#   - Nginx server block → Istio ingress
#   - K8s namespace
#   - Rancher Project (for RBAC)
#   - Istio Gateway
#
# Sourced by openg2p-environment.sh — do not run directly.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Helpers: derive environment base domain and Keycloak URL
# ─────────────────────────────────────────────────────────────────────────────
get_env_base_domain() {
    local explicit=$(cfg "base_domain" "")
    if [[ -n "$explicit" ]]; then
        echo "$explicit"
        return
    fi
    # Auto-derive in local mode: <environment>.<local_domain>
    local domain_mode=$(cfg "domain_mode" "custom")
    if [[ "$domain_mode" == "local" ]]; then
        local env_name=$(cfg "environment")
        local local_domain=$(cfg "local_domain" "openg2p.test")
        echo "${env_name}.${local_domain}"
    else
        echo ""
    fi
}

get_keycloak_url() {
    local domain_mode=$(cfg "domain_mode" "custom")
    local keycloak_host
    if [[ "$domain_mode" == "local" ]]; then
        keycloak_host="keycloak.$(cfg 'local_domain' 'openg2p.test')"
    else
        keycloak_host=$(cfg "keycloak_hostname")
    fi
    echo "https://${keycloak_host}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1.1: Validate prerequisites
# ─────────────────────────────────────────────────────────────────────────────
env_phase1_step1_validate() {
    local env_name=$(cfg "environment")
    local step_id="env-${env_name}.phase1.validate"
    skip_if_done "$step_id" "Environment prerequisites" && return 0

    log_step "E1.1" "Validating environment prerequisites"

    ensure_kubeconfig || return 1

    # Check that infra script completed
    if [[ ! -f "${STATE_DIR}/phase3.rancher_keycloak.done" ]]; then
        log_error "Infrastructure setup not complete" \
                  "The infra script (openg2p-infra.sh) must finish all 3 phases first" \
                  "Run openg2p-infra.sh before creating environments" \
                  "sudo ./openg2p-infra.sh --config infra-config.yaml"
        return 1
    fi
    log_success "Infrastructure setup confirmed."

    # Validate required config
    local base_domain=$(get_env_base_domain)
    if [[ -z "$base_domain" ]]; then
        log_error "No base_domain for this environment" \
                  "In custom mode, base_domain must be explicitly set in env config" \
                  "Set base_domain: dev.yourdomain.org in your config"
        return 1
    fi
    log_info "Environment base domain: ${base_domain}"

    local node_ip=$(cfg "node_ip")
    if [[ -z "$node_ip" ]]; then
        log_error "node_ip not set" \
                  "node_ip must be available (from infra config or env config)" \
                  "Set infra_config path or add node_ip to env config"
        return 1
    fi

    log_success "Environment prerequisites validated."
    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1.2: TLS certificate for environment domain
# ─────────────────────────────────────────────────────────────────────────────
env_phase1_step2_certificates() {
    local env_name=$(cfg "environment")
    local step_id="env-${env_name}.phase1.certificates"
    skip_if_done "$step_id" "TLS certificates for ${env_name}" && return 0

    local domain_mode=$(cfg "domain_mode" "custom")
    local tls_method=$(cfg "tls.method" "")
    local base_domain=$(get_env_base_domain)

    if [[ "$domain_mode" == "local" ]]; then
        env_phase1_step2_certificates_local "$base_domain"
    elif [[ "$tls_method" == "provided" ]]; then
        env_phase1_step2_certificates_provided "$base_domain"
    else
        env_phase1_step2_certificates_letsencrypt "$base_domain"
    fi
    mark_step_done "$step_id"
}

env_phase1_step2_certificates_provided() {
    local base_domain="$1"
    log_step "E1.2" "Installing user-provided TLS certificate for *.${base_domain}"

    local cert_src=$(cfg "tls.cert" "")
    local key_src=$(cfg "tls.key" "")

    # Fall back to infra-level rancher cert if env-level not set (wildcard reuse)
    if [[ -z "$cert_src" ]]; then
        cert_src=$(cfg "tls.rancher_cert" "")
        key_src=$(cfg "tls.rancher_key" "")
    fi

    if [[ -z "$cert_src" || -z "$key_src" ]]; then
        log_error "tls.cert and tls.key are required when tls.method is 'provided'" \
                  "Set the paths to your wildcard certificate and key in the config" \
                  "Check the tls section in your env config"
        return 1
    fi

    install_provided_cert "$base_domain" "$cert_src" "$key_src" || return 1
    log_success "User-provided certificate installed for *.${base_domain}."
}

env_phase1_step2_certificates_local() {
    local base_domain="$1"
    log_step "E1.2" "Generating TLS certificate for *.${base_domain}"

    local ca_dir="/etc/openg2p/ca"
    local certs_dir="/etc/openg2p/certs"
    local cert_path="${certs_dir}/${base_domain}"

    # CA must already exist from infra setup
    if [[ ! -f "${ca_dir}/ca.key" || ! -f "${ca_dir}/ca.crt" ]]; then
        log_error "Local CA not found at ${ca_dir}" \
                  "The infra script should have created the CA" \
                  "Re-run openg2p-infra.sh phase 1" \
                  "ls -la ${ca_dir}"
        return 1
    fi

    if [[ -f "${cert_path}/fullchain.pem" && -f "${cert_path}/privkey.pem" ]]; then
        log_success "Certificate for *.${base_domain} already exists."
        return 0
    fi

    log_info "Generating wildcard certificate for *.${base_domain}..."
    mkdir -p "$cert_path"

    cat > "${cert_path}/openssl.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no
[req_distinguished_name]
C = XX
ST = OpenG2P
L = OpenG2P
O = OpenG2P
CN = *.${base_domain}
[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = *.${base_domain}
DNS.2 = ${base_domain}
EOF

    openssl genrsa -out "${cert_path}/privkey.pem" 2048 2>/dev/null
    openssl req -new -key "${cert_path}/privkey.pem" \
        -config "${cert_path}/openssl.cnf" -out "${cert_path}/cert.csr" 2>/dev/null
    openssl x509 -req -in "${cert_path}/cert.csr" \
        -CA "${ca_dir}/ca.crt" -CAkey "${ca_dir}/ca.key" -CAcreateserial \
        -out "${cert_path}/cert.pem" -days 825 -sha256 \
        -extensions v3_req -extfile "${cert_path}/openssl.cnf" 2>/dev/null
    cat "${cert_path}/cert.pem" "${ca_dir}/ca.crt" > "${cert_path}/fullchain.pem"
    rm -f "${cert_path}/cert.csr" "${cert_path}/openssl.cnf" "${cert_path}/cert.pem"
    chmod 600 "${cert_path}/privkey.pem"

    log_success "Wildcard certificate generated for *.${base_domain}."
}

env_phase1_step2_certificates_letsencrypt() {
    local base_domain="$1"
    log_step "E1.2" "Obtaining Let's Encrypt certificate for *.${base_domain}"

    local email=$(cfg "letsencrypt_email")
    local challenge=$(cfg "letsencrypt_challenge" "dns")

    if [[ -z "$email" ]]; then
        log_error "letsencrypt_email not set" \
                  "Required for obtaining Let's Encrypt certificates" \
                  "Set letsencrypt_email in your config file"
        return 1
    fi

    # Check if cert already exists
    if [[ -d "/etc/letsencrypt/live/${base_domain}" ]]; then
        log_success "Let's Encrypt cert for ${base_domain} already exists."
        return 0
    fi

    # For environments we need a wildcard cert: *.dev.openg2p.org
    # Wildcard certs require DNS-01 challenge (HTTP-01 doesn't support wildcards)
    if [[ "$challenge" == "http" ]]; then
        log_error "HTTP-01 challenge cannot issue wildcard certificates" \
                  "Environment certs need wildcard (*.${base_domain})" \
                  "Use dns, dns-cloudflare, or dns-route53 challenge" \
                  "Set letsencrypt_challenge: dns in your config"
        return 1
    fi

    if systemctl is-active --quiet nginx 2>/dev/null; then
        log_info "Stopping Nginx temporarily for certificate generation..."
        systemctl stop nginx
    fi

    log_info "Requesting wildcard certificate for *.${base_domain} (challenge: ${challenge})..."

    case "$challenge" in
        dns)
            log_info "Manual DNS-01: certbot will prompt you to create TXT records."
            certbot certonly --manual --preferred-challenges dns --agree-tos \
                --email "$email" -d "${base_domain}" -d "*.${base_domain}" || {
                log_error "Cert failed for *.${base_domain}" "DNS-01 challenge failed" \
                          "Verify: dig TXT _acme-challenge.${base_domain}"; return 1; } ;;
        dns-cloudflare)
            certbot certonly --dns-cloudflare \
                --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
                --dns-cloudflare-propagation-seconds 30 \
                --non-interactive --agree-tos --email "$email" \
                -d "${base_domain}" -d "*.${base_domain}" || {
                log_error "Cert failed for *.${base_domain}" "Cloudflare DNS-01 failed" \
                          "Check API token and zone permissions"; return 1; } ;;
        dns-route53)
            certbot certonly --dns-route53 --dns-route53-propagation-seconds 30 \
                --non-interactive --agree-tos --email "$email" \
                -d "${base_domain}" -d "*.${base_domain}" || {
                log_error "Cert failed for *.${base_domain}" "Route53 DNS-01 failed" \
                          "Check AWS credentials"; return 1; } ;;
        *) log_error "Unknown challenge: '${challenge}'" "Valid: dns, dns-cloudflare, dns-route53" ""; return 1 ;;
    esac

    # Restart Nginx if it was running
    if systemctl is-enabled --quiet nginx 2>/dev/null; then
        systemctl start nginx
    fi

    log_success "Wildcard certificate obtained for *.${base_domain}."
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1.3: Nginx server block for environment domain
# ─────────────────────────────────────────────────────────────────────────────
env_phase1_step3_nginx() {
    local env_name=$(cfg "environment")
    local step_id="env-${env_name}.phase1.nginx"
    skip_if_done "$step_id" "Nginx for ${env_name}" && return 0

    log_step "E1.3" "Adding Nginx server block for environment '${env_name}'"

    local node_ip=$(cfg "node_ip")
    local domain_mode=$(cfg "domain_mode" "custom")
    local base_domain=$(get_env_base_domain)

    local env_cert env_key
    env_cert=$(get_cert_path "$base_domain" "cert")
    env_key=$(get_cert_path "$base_domain" "key")

    for f in "$env_cert" "$env_key"; do
        if [[ ! -f "$f" ]]; then
            log_error "TLS cert not found: ${f}" \
                      "Certificate step may not have completed" \
                      "Run this script again from phase 1" \
                      "ls -la $(dirname "$f")"
            return 1
        fi
    done

    local nginx_conf="/etc/nginx/sites-available/openg2p-env-${env_name}.conf"
    log_info "Writing Nginx config: ${nginx_conf}"

    cat > "$nginx_conf" <<EOF
# OpenG2P environment: ${env_name}
# Domain: *.${base_domain}
# Generated by openg2p-environment.sh — do not edit manually.

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

    ln -sf "$nginx_conf" "/etc/nginx/sites-enabled/openg2p-env-${env_name}.conf"

    nginx -t || {
        log_error "Nginx config test failed" \
                  "Syntax error in generated environment config" \
                  "Review the config file" \
                  "nginx -t; cat ${nginx_conf}"
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
    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1.4: K8s namespace
# ─────────────────────────────────────────────────────────────────────────────
env_phase1_step4_namespace() {
    local env_name=$(cfg "environment")
    local step_id="env-${env_name}.phase1.namespace"
    skip_if_done "$step_id" "Namespace '${env_name}'" && return 0

    log_step "E1.4" "Creating Kubernetes namespace '${env_name}'"

    ensure_kubeconfig || return 1

    if kubectl get namespace "$env_name" &>/dev/null; then
        log_info "Namespace '${env_name}' already exists."
    else
        kubectl create namespace "$env_name" || {
            log_error "Failed to create namespace '${env_name}'" \
                      "kubectl create namespace failed" \
                      "Check cluster connectivity" \
                      "kubectl get nodes"
            return 1
        }
        log_success "Namespace '${env_name}' created."
    fi

    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1.5: Rancher Project
# ─────────────────────────────────────────────────────────────────────────────
env_phase1_step5_rancher_project() {
    local env_name=$(cfg "environment")
    local step_id="env-${env_name}.phase1.rancher_project"
    skip_if_done "$step_id" "Rancher Project '${env_name}'" && return 0

    log_step "E1.5" "Creating Rancher Project for '${env_name}'"

    ensure_kubeconfig || return 1

    # Check if a project with this name already exists
    local existing_project
    existing_project=$(kubectl get projects.management.cattle.io -n local \
        -o json 2>/dev/null | \
        jq -r --arg name "$env_name" \
        '.items[] | select(.spec.displayName == $name) | .metadata.name' 2>/dev/null | head -1 || true)

    if [[ -n "$existing_project" ]]; then
        log_info "Rancher Project '${env_name}' already exists (ID: ${existing_project})."
    else
        log_info "Creating Rancher Project '${env_name}'..."
        local project_id
        project_id=$(kubectl create -f - -o jsonpath='{.metadata.name}' <<PROJEOF
apiVersion: management.cattle.io/v3
kind: Project
metadata:
  generateName: p-
  namespace: local
spec:
  displayName: ${env_name}
  clusterName: local
PROJEOF
        ) || {
            log_warn "Failed to create Rancher Project. You can create it manually in Rancher UI."
            mark_step_done "$step_id"
            return 0
        }
        existing_project="$project_id"
        log_success "Rancher Project '${env_name}' created (ID: ${existing_project})."
    fi

    # Move namespace into the project (set the annotation)
    local project_ns_value="local:${existing_project}"
    local current_annotation
    current_annotation=$(kubectl get namespace "$env_name" \
        -o jsonpath='{.metadata.annotations.field\.cattle\.io/projectId}' 2>/dev/null || true)

    if [[ "$current_annotation" == "$project_ns_value" ]]; then
        log_info "Namespace '${env_name}' already in Rancher Project."
    else
        log_info "Moving namespace '${env_name}' into Rancher Project..."
        kubectl annotate namespace "$env_name" \
            "field.cattle.io/projectId=${project_ns_value}" --overwrite > /dev/null 2>&1 || {
            log_warn "Could not annotate namespace. Move it manually in Rancher UI."
        }
        log_success "Namespace '${env_name}' associated with Rancher Project."
    fi

    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1.6: Istio Gateway
# ─────────────────────────────────────────────────────────────────────────────
env_phase1_step6_istio_gateway() {
    local env_name=$(cfg "environment")
    local step_id="env-${env_name}.phase1.istio_gateway"
    skip_if_done "$step_id" "Istio Gateway for '${env_name}'" && return 0

    log_step "E1.6" "Creating Istio Gateway for '${env_name}'"

    ensure_kubeconfig || return 1

    local base_domain=$(get_env_base_domain)

    if kubectl -n "$env_name" get gateway internal &>/dev/null; then
        log_info "Istio Gateway 'internal' already exists in namespace '${env_name}'."
    else
        log_info "Creating Istio Gateway for *.${base_domain}..."
        kubectl apply -f - <<GWEOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: internal
  namespace: ${env_name}
spec:
  selector:
    istio: ingressgateway
  servers:
    - hosts:
        - "${base_domain}"
        - "*.${base_domain}"
      port:
        name: http2
        number: 8080
        protocol: HTTP2
GWEOF
    fi

    log_success "Istio Gateway configured for *.${base_domain}."
    mark_step_done "$step_id"
}


# ─────────────────────────────────────────────────────────────────────────────
# Step 1.8: CA certificate ConfigMap (local mode only)
# ─────────────────────────────────────────────────────────────────────────────
# In local mode, services inside pods need to trust our self-signed CA
# when talking to https://keycloak.openg2p.test. We create a ConfigMap
# with the CA cert so it can be mounted into pods and added to trust stores.
env_phase1_step8_ca_configmap() {
    local domain_mode=$(cfg "domain_mode" "custom")
    [[ "$domain_mode" == "local" ]] || return 0

    local env_name=$(cfg "environment")
    log_step "E1.8" "Creating CA certificate ConfigMap in namespace '${env_name}'"

    ensure_kubeconfig || return 1

    local ca_cert="/etc/openg2p/ca/ca.crt"
    if [[ ! -f "$ca_cert" ]]; then
        log_error "CA certificate not found at ${ca_cert}" \
                  "The infra script should have created the CA" \
                  "Re-run openg2p-infra.sh phase 1"
        return 1
    fi

    if kubectl -n "$env_name" get configmap openg2p-ca-cert &>/dev/null; then
        log_info "ConfigMap 'openg2p-ca-cert' already exists — updating..."
        kubectl -n "$env_name" create configmap openg2p-ca-cert \
            --from-file=ca.crt="$ca_cert" --dry-run=client -o yaml | \
            kubectl apply -f - > /dev/null 2>&1
    else
        kubectl -n "$env_name" create configmap openg2p-ca-cert \
            --from-file=ca.crt="$ca_cert" || {
            log_error "Failed to create CA cert ConfigMap" \
                      "kubectl create configmap failed"
            return 1
        }
    fi

    log_success "ConfigMap 'openg2p-ca-cert' created with CA certificate."
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all Phase 1 steps
# ─────────────────────────────────────────────────────────────────────────────
run_env_phase1() {
    local env_name=$(cfg "environment")

    log_step "E1" "Phase 1 — Environment Infrastructure for '${env_name}'"

    env_phase1_step1_validate
    env_phase1_step2_certificates
    env_phase1_step3_nginx
    env_phase1_step4_namespace
    env_phase1_step5_rancher_project
    env_phase1_step6_istio_gateway
    env_phase1_step8_ca_configmap

    log_success "Phase 1 complete — environment infrastructure for '${env_name}' is ready."
}
