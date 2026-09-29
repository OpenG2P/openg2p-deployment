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
# Sourced by roles/environment/run.sh — do not run directly.
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
    # Auto-derive: <environment>.<domain>
    local env_name=$(cfg "environment")
    local domain=$(cfg "domain" "")
    echo "${env_name}.${domain}"
}

# The environment's label under the sandbox domain — used as the DNS subname
# when publishing records (e.g. base "dev.mydept.dedyn.io" under domain
# "mydept.dedyn.io" yields "dev"). Empty when base_domain was set explicitly
# to something outside the sandbox domain.
get_env_dns_subname() {
    local base_domain=$(get_env_base_domain)
    local domain=$(cfg "domain" "")
    [[ -z "$domain" || "$base_domain" == "$domain" ]] && { echo ""; return; }
    case "$base_domain" in
        *".${domain}") echo "${base_domain%".${domain}"}" ;;
        *)             echo "" ;;
    esac
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
    if [[ ! -f "${STATE_DIR}/phase3.rancher_config.done" ]]; then
        log_error "Infrastructure setup not complete" \
                  "The infra script (roles/infra/run.sh) must finish all 3 phases first" \
                  "Run roles/infra/run.sh before creating environments" \
                  "sudo bash roles/infra/run.sh --config sandbox-config.yaml"
        return 1
    fi
    log_success "Infrastructure setup confirmed."

    # Validate required config
    local base_domain=$(get_env_base_domain)
    if [[ -z "$base_domain" ]]; then
        log_error "Could not determine base_domain for this environment" \
                  "It auto-derives as <environment>.<domain> — ensure both are set" \
                  "Check 'environment' and 'domain' in your config (or set base_domain explicitly)"
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
# Publishes the environment's wildcard A record and obtains a Let's Encrypt
# wildcard certificate for *.<base_domain> via the ACME DNS-01 challenge.
#
# The cert is issued as a SAN covering BOTH the environment apex and the
# wildcard. The apex is listed first deliberately: acme.sh names its internal
# state directory after the first -d, and a literal '*' in a directory name is
# a lasting nuisance.
env_phase1_step2_certificates() {
    local env_name=$(cfg "environment")
    local step_id="env-${env_name}.phase1.certificates"
    skip_if_done "$step_id" "TLS certificate for ${env_name}" && return 0

    local base_domain=$(get_env_base_domain)
    local node_ip=$(cfg "node_ip")
    local subname=$(get_env_dns_subname)

    log_step "E1.2" "Publishing DNS records and obtaining the TLS certificate for *.${base_domain}"

    acme_preflight || return 1
    acme_install_client || return 1

    # Wildcard A record so every service hostname in this environment resolves
    # (e.g. keycloak.dev.<domain>, superset.dev.<domain>) with no local DNS.
    if [[ -n "$subname" ]]; then
        acme_publish_a_record "*.${subname}" "$node_ip" || return 1
        acme_publish_a_record "$subname"     "$node_ip" || return 1
    else
        log_warn "base_domain '${base_domain}' is not under domain '$(cfg 'domain' '')'."
        log_warn "  Skipping automatic A records — create them yourself:"
        log_warn "      *.${base_domain}   A   ${node_ip}"
        log_warn "      ${base_domain}     A   ${node_ip}"
    fi

    # Let the new records reach public DNS before spending a Let's Encrypt
    # validation attempt — see acme_wait_dns_propagation for why.
    acme_wait_dns_propagation "$base_domain"

    acme_issue_cert "$base_domain" "$base_domain" "*.${base_domain}" || return 1

    mark_step_done "$step_id"
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
    local base_domain=$(get_env_base_domain)

    # Per-environment public exposure.
    #
    #   public: false (default) — this environment answers only clients coming
    #                             over Wireguard or from inside the VPC, even
    #                             if sandbox public_access has opened 80/443.
    #   public: true            — this environment answers anyone.
    #
    # The firewall is host-wide, so it cannot separate one environment from
    # another. Nginx routes by hostname, so the allow/deny list here is what
    # makes "public for dev, private for everything else" possible.
    local env_public env_allow
    env_public=$(cfg "public" "false")
    if [[ "$env_public" == "true" ]]; then
        env_allow=""
        log_warn "Environment '${env_name}' will be served to ANY client (public: true)."
        log_warn "  Every service under *.${base_domain} becomes publicly reachable."
        log_warn "  This also requires public_access: true in the sandbox config."
    else
        local wg_subnet_cidr vpc_cidr
        wg_subnet_cidr=$(cfg "wireguard.subnet" "10.15.0.0/16")
        vpc_cidr=$(echo "$node_ip" | awk -F. '{printf "%s.%s.0.0/16", $1, $2}')
        env_allow="    allow ${wg_subnet_cidr};
    allow ${vpc_cidr};
    allow 127.0.0.1;
    deny all;"
    fi

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
# Generated by roles/environment/run.sh — do not edit manually.

server {
    listen 80;
    server_name *.${base_domain} ${base_domain};
${env_allow}
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name *.${base_domain} ${base_domain};
    ssl_certificate     ${env_cert};
    ssl_certificate_key ${env_key};
    ssl_protocols       TLSv1.2 TLSv1.3;
${env_allow}
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
# Run all Phase 1 steps
# ─────────────────────────────────────────────────────────────────────────────
# Note: there is no CA-distribution step. Certificates are issued by Let's
# Encrypt, whose root is already in every container image's trust store, so
# in-cluster services trust the environment's HTTPS endpoints out of the box.
run_env_phase1() {
    local env_name=$(cfg "environment")

    log_step "E1" "Phase 1 — Environment Infrastructure for '${env_name}'"

    env_phase1_step1_validate
    env_phase1_step2_certificates
    env_phase1_step3_nginx
    env_phase1_step4_namespace
    env_phase1_step5_rancher_project
    env_phase1_step6_istio_gateway

    log_success "Phase 1 complete — environment infrastructure for '${env_name}' is ready."
}
