#!/usr/bin/env bash
# =============================================================================
# OpenG2P Deployment Automation — Phase 1: Host-Level Setup
# =============================================================================
# Installs all host-level components on the VM: tools, RKE2, Wireguard, NFS,
# DNS (dnsmasq for local mode or verification for custom), TLS certs, and Nginx.
# Sourced by openg2p-infra.sh — do not run directly.
# =============================================================================

# Resolve the repo root (parent of automation/)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# Helper: get effective hostnames (derived in local mode, from config in custom)
# ─────────────────────────────────────────────────────────────────────────────
get_rancher_hostname() {
    local mode=$(cfg "domain_mode" "custom")
    if [[ "$mode" == "local" ]]; then
        echo "rancher.$(cfg 'local_domain' 'openg2p.test')"
    else
        cfg "rancher_hostname"
    fi
}

get_keycloak_hostname() {
    local mode=$(cfg "domain_mode" "custom")
    if [[ "$mode" == "local" ]]; then
        echo "keycloak.$(cfg 'local_domain' 'openg2p.test')"
    else
        cfg "keycloak_hostname"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Tool installers — dedicated functions for tools whose install commands
# have nested subshells that break when passed through eval
# ─────────────────────────────────────────────────────────────────────────────
install_kubectl() {
    if kubectl version --client &>/dev/null; then
        log_success "kubectl is already installed."
        return 0
    fi
    log_info "Installing kubectl..."
    local kube_version
    kube_version=$(curl -sL https://dl.k8s.io/release/stable.txt)
    if [[ -z "$kube_version" ]]; then
        log_error "Failed to fetch latest kubectl version" \
                  "Could not reach https://dl.k8s.io" \
                  "Check internet connectivity" \
                  "curl -sL https://dl.k8s.io/release/stable.txt" \
                  "https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/"
        return 1
    fi
    curl -sLO "https://dl.k8s.io/release/${kube_version}/bin/linux/amd64/kubectl" || {
        log_error "Failed to download kubectl ${kube_version}" \
                  "Download from dl.k8s.io failed" \
                  "Check internet connectivity" \
                  "curl -sLO https://dl.k8s.io/release/${kube_version}/bin/linux/amd64/kubectl"
        return 1
    }
    install -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl
    log_success "kubectl ${kube_version} installed."
}

install_istioctl() {
    local version="${1:-1.24.1}"
    if istioctl version --remote=false &>/dev/null; then
        log_success "istioctl is already installed."
        return 0
    fi
    log_info "Installing istioctl ${version}..."
    curl -sL https://istio.io/downloadIstio | ISTIO_VERSION="${version}" sh - || {
        log_error "Failed to download istioctl ${version}" \
                  "Download from istio.io failed" \
                  "Check internet connectivity" \
                  "" \
                  "https://istio.io/latest/docs/setup/getting-started/#download"
        return 1
    }
    install -m 0755 "istio-${version}/bin/istioctl" /usr/local/bin/istioctl
    rm -rf "istio-${version}"
    log_success "istioctl ${version} installed."
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Install prerequisite tools
# ─────────────────────────────────────────────────────────────────────────────
phase1_step1_tools() {
    local step_id="phase1.tools"
    skip_if_done "$step_id" "Prerequisite tools installation" && return 0

    log_step "1.1" "Installing prerequisite tools"

    apt-get update -qq || {
        log_error "apt-get update failed" \
                  "Package index could not be refreshed" \
                  "Check your internet connectivity and /etc/apt/sources.list" \
                  "apt-get update"
        return 1
    }

    apt-get install -y -qq wget curl jq openssl dnsutils software-properties-common \
        apt-transport-https ca-certificates gnupg > /dev/null 2>&1 || {
        log_error "Failed to install basic packages" \
                  "apt-get install failed" \
                  "Check internet connectivity and disk space" \
                  "apt-get install -y wget curl jq openssl dnsutils"
        return 1
    }
    log_success "Basic tools installed (wget, curl, jq, openssl, dig)."

    install_kubectl || return 1

    install_if_missing "helm" \
        "helm version" \
        "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash" \
        "https://helm.sh/docs/intro/install/"

    install_istioctl "1.24.1" || return 1

    install_if_missing "helmfile" \
        "helmfile version" \
        "curl -sL https://github.com/helmfile/helmfile/releases/latest/download/helmfile_linux_amd64.tar.gz | tar xz -C /tmp && install -m 0755 /tmp/helmfile /usr/local/bin/helmfile && rm -f /tmp/helmfile" \
        "https://github.com/helmfile/helmfile#installation"

    if ! helm plugin list 2>/dev/null | grep -q diff; then
        log_info "Installing helm-diff plugin (required by Helmfile)..."
        helm plugin install https://github.com/databus23/helm-diff || {
            log_warn "helm-diff plugin install failed. Helmfile may still work with --skip-diff-on-install."
        }
    fi
    log_success "helm-diff plugin — OK."

    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Firewall setup
# ─────────────────────────────────────────────────────────────────────────────
phase1_step2_firewall() {
    local step_id="phase1.firewall"
    skip_if_done "$step_id" "Firewall setup" && return 0

    log_step "1.2" "Configuring firewall"

    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        log_info "Disabling ufw (RKE2 manages its own iptables rules)..."
        ufw disable
    fi

    log_info "Firewall: ufw disabled. Ensure your external firewall allows ports:"
    log_info "  TCP: 6443, 9345, 10250, 30080, 30443, 443"
    log_info "  UDP: $(cfg 'wireguard.port' '51820')"
    log_info "  TCP: 2049 (NFS — internal only)"

    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: RKE2 Kubernetes cluster
# ─────────────────────────────────────────────────────────────────────────────
phase1_step3_rke2() {
    local step_id="phase1.rke2"
    skip_if_done "$step_id" "RKE2 Kubernetes cluster" && return 0

    log_step "1.3" "Installing RKE2 Kubernetes cluster"

    local rke2_version=$(cfg "rke2_version" "v1.31.4+rke2r1")
    local node_name=$(cfg "node_name")
    local node_ip=$(cfg "node_ip")
    local rke2_token=$(cfg "rke2_token" "openg2p-$(openssl rand -hex 16)")

    if systemctl is-active --quiet rke2-server 2>/dev/null; then
        log_info "RKE2 is already running. Verifying..."
        ensure_kubeconfig
        if kubectl get nodes &>/dev/null; then
            log_success "RKE2 is running and accessible."
            mark_step_done "$step_id"
            return 0
        fi
    fi

    log_info "Creating RKE2 configuration..."
    mkdir -p /etc/rancher/rke2
    cat > /etc/rancher/rke2/config.yaml <<EOF
token: ${rke2_token}
node-name: ${node_name}
node-ip: ${node_ip}
node-label:
  - "shouldInstallIstioIngress=true"
disable:
  - rke2-ingress-nginx
kubelet-arg:
  - --allowed-unsafe-sysctls=net.ipv4.conf.all.src_valid_mark,net.ipv4.ip_forward
EOF

    log_info "Downloading and installing RKE2 ${rke2_version}..."
    export INSTALL_RKE2_VERSION="${rke2_version}"
    if ! curl -sfL https://get.rke2.io | sh -; then
        log_error "RKE2 download/install failed" \
                  "The install script could not complete" \
                  "Check internet connectivity and disk space" \
                  "curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=${rke2_version} sh -" \
                  "https://docs.rke2.io/install/quickstart"
        return 1
    fi

    log_info "Enabling and starting RKE2 server..."
    systemctl enable rke2-server
    systemctl start rke2-server || {
        log_error "RKE2 server failed to start" \
                  "Check system resources and config at /etc/rancher/rke2/config.yaml" \
                  "Review RKE2 logs for details" \
                  "journalctl -u rke2-server -n 50 --no-pager" \
                  "https://docs.rke2.io/install/quickstart"
        return 1
    }

    ensure_kubeconfig

    cat > /etc/profile.d/openg2p-k8s.sh <<'PROFILE'
export PATH="$PATH:/var/lib/rancher/rke2/bin"
export KUBECONFIG="/etc/rancher/rke2/rke2.yaml"
PROFILE

    wait_for_command "Kubernetes node to be Ready" \
        "kubectl get nodes | grep -w Ready" \
        300 10 || {
        log_error "RKE2 node did not become Ready within timeout" \
                  "The kubelet may still be initializing" \
                  "Check node status and RKE2 logs" \
                  "kubectl get nodes; journalctl -u rke2-server -n 30 --no-pager"
        return 1
    }

    log_info "Saving kubeconfig backup to /root/rke2-kubeconfig-backup.yaml ..."
    cp /etc/rancher/rke2/rke2.yaml /root/rke2-kubeconfig-backup.yaml
    chmod 600 /root/rke2-kubeconfig-backup.yaml

    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Wireguard VPN
# ─────────────────────────────────────────────────────────────────────────────
phase1_step4_wireguard() {
    local step_id="phase1.wireguard"
    skip_if_done "$step_id" "Wireguard VPN" && return 0

    log_step "1.4" "Installing Wireguard VPN"

    local wg_name=$(cfg "wireguard.name" "wireguard_app_users")
    local wg_subnet=$(cfg "wireguard.subnet" "10.15.0.0/16")
    local wg_port=$(cfg "wireguard.port" "51820")
    local wg_peers=$(cfg "wireguard.peers" "254")
    local cluster_subnet=$(cfg "wireguard.cluster_subnet" "")
    local wg_script="${REPO_ROOT}/kubernetes/wireguard/wg.sh"

    if [[ ! -f "$wg_script" ]]; then
        log_error "Wireguard install script not found at ${wg_script}" \
                  "The openg2p-deployment repo may be incomplete" \
                  "Ensure you have cloned the full repo" \
                  "ls -la ${REPO_ROOT}/kubernetes/wireguard/"
        return 1
    fi

    if kubectl -n wireguard-system get daemonset "${wg_name//_/-}" &>/dev/null; then
        log_success "Wireguard DaemonSet already exists."
        mark_step_done "$step_id"
        return 0
    fi

    log_info "Deploying Wireguard: name=${wg_name}, subnet=${wg_subnet}, port=${wg_port}, peers=${wg_peers}"

    cd "${REPO_ROOT}/kubernetes/wireguard"
    if [[ -n "$cluster_subnet" ]]; then
        WG_MODE=k8s bash wg.sh "$wg_name" "$wg_subnet" "$wg_port" "$wg_peers" "$cluster_subnet"
    else
        WG_MODE=k8s bash wg.sh "$wg_name" "$wg_subnet" "$wg_port" "$wg_peers"
    fi || {
        log_error "Wireguard installation failed" \
                  "The wg.sh script exited with an error" \
                  "Check Wireguard pod logs" \
                  "kubectl -n wireguard-system logs -l app=${wg_name//_/-}"
        return 1
    }
    cd - > /dev/null

    sleep 5
    wait_for_command "Wireguard pod to start" \
        "kubectl -n wireguard-system get pods -l app=${wg_name//_/-} -o jsonpath='{.items[0].status.phase}' | grep -q Running" \
        120 10 || {
        log_warn "Wireguard pod may still be starting. Check manually later."
    }

    local domain_mode=$(cfg "domain_mode" "custom")
    if [[ "$domain_mode" == "local" ]]; then
        local node_ip=$(cfg "node_ip")
        log_info "Updating Wireguard peer configs to push DNS server (${node_ip})..."
        local peer_dir="/etc/${wg_name}"
        if [[ -d "$peer_dir" ]]; then
            find "$peer_dir" -name "peer*.conf" -type f | while read -r pconf; do
                if ! grep -q "^DNS" "$pconf"; then
                    sed -i "/^\[Interface\]/a DNS = ${node_ip}" "$pconf"
                    log_info "  Updated: $(basename "$pconf")"
                fi
            done
        fi
    fi

    log_info "Wireguard peer configs are at: /etc/${wg_name}/"
    log_info "Share the peer1.conf file with the DevOps team for VPN access."

    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: NFS Server
# ─────────────────────────────────────────────────────────────────────────────
phase1_step5_nfs_server() {
    local step_id="phase1.nfs_server"
    skip_if_done "$step_id" "NFS server" && return 0

    log_step "1.5" "Installing NFS server"

    local cluster_name=$(cfg "node_name" "openg2p")
    local nfs_path="/srv/nfs/${cluster_name}"
    local nfs_script="${REPO_ROOT}/nfs-server/install-nfs-server.sh"

    if systemctl is-active --quiet nfs-kernel-server 2>/dev/null && exportfs | grep -q /srv/nfs; then
        log_success "NFS server is already running with exports."
        mkdir -p "$nfs_path"
        chmod -R 777 /srv/nfs
        mark_step_done "$step_id"
        return 0
    fi

    if [[ ! -f "$nfs_script" ]]; then
        log_error "NFS install script not found at ${nfs_script}" \
                  "The openg2p-deployment repo may be incomplete" \
                  "Ensure you have cloned the full repo"
        return 1
    fi

    log_info "Running NFS server installation..."
    bash "$nfs_script" || {
        log_error "NFS server installation failed" \
                  "The install script exited with an error" \
                  "Check if nfs-kernel-server package is available" \
                  "apt-get install nfs-kernel-server"
        return 1
    }

    log_info "Creating NFS directory for cluster: ${nfs_path}"
    mkdir -p "$nfs_path"
    chmod -R 777 /srv/nfs

    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: NFS CSI Driver on Kubernetes
# ─────────────────────────────────────────────────────────────────────────────
phase1_step6_nfs_csi() {
    local step_id="phase1.nfs_csi"
    skip_if_done "$step_id" "NFS CSI driver" && return 0

    log_step "1.6" "Installing NFS CSI driver on Kubernetes"

    local node_ip=$(cfg "node_ip")
    local cluster_name=$(cfg "node_name" "openg2p")
    local nfs_path="/srv/nfs/${cluster_name}"
    local csi_script="${REPO_ROOT}/kubernetes/nfs-client/install-nfs-csi-driver.sh"

    if kubectl get storageclass nfs-csi &>/dev/null; then
        log_success "NFS CSI StorageClass 'nfs-csi' already exists."
        mark_step_done "$step_id"
        return 0
    fi

    if [[ ! -f "$csi_script" ]]; then
        log_error "NFS CSI install script not found at ${csi_script}" \
                  "The openg2p-deployment repo may be incomplete" \
                  "Ensure you have cloned the full repo"
        return 1
    fi

    log_info "Installing NFS CSI driver (server=${node_ip}, path=${nfs_path})..."
    cd "${REPO_ROOT}/kubernetes/nfs-client"
    NFS_SERVER="$node_ip" NFS_PATH="$nfs_path" bash install-nfs-csi-driver.sh || {
        log_error "NFS CSI driver installation failed" \
                  "Helm install of csi-driver-nfs or StorageClass creation failed" \
                  "Check helm and kubectl access to cluster" \
                  "helm -n kube-system list; kubectl get storageclass"
        cd - > /dev/null
        return 1
    }
    cd - > /dev/null

    wait_for_command "NFS CSI StorageClass to appear" \
        "kubectl get storageclass nfs-csi" \
        60 5

    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Local DNS (dnsmasq) — only in local domain_mode
# ─────────────────────────────────────────────────────────────────────────────
phase1_step7_local_dns() {
    local domain_mode=$(cfg "domain_mode" "custom")
    if [[ "$domain_mode" != "local" ]]; then
        return 0
    fi

    local step_id="phase1.local_dns"
    skip_if_done "$step_id" "Local DNS (dnsmasq)" && return 0

    log_step "1.7" "Setting up local DNS server (dnsmasq)"

    local node_ip=$(cfg "node_ip")
    local local_domain=$(cfg "local_domain" "openg2p.test")

    install_if_missing "dnsmasq" \
        "dnsmasq --version" \
        "apt-get install -y -qq dnsmasq > /dev/null 2>&1" \
        "https://thekelleys.org.uk/dnsmasq/doc.html"

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        log_info "Configuring systemd-resolved to coexist with dnsmasq..."
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/openg2p-dnsmasq.conf <<EOF
[Resolve]
DNSStubListener=no
EOF
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true
        systemctl restart systemd-resolved
    fi

    log_info "Configuring dnsmasq for *.${local_domain} -> ${node_ip}..."
    cat > /etc/dnsmasq.d/openg2p.conf <<EOF
# OpenG2P local DNS
address=/${local_domain}/${node_ip}
server=8.8.8.8
server=8.8.4.4
listen-address=127.0.0.1,${node_ip}
no-hosts
log-queries
log-facility=/var/log/dnsmasq-openg2p.log
EOF

    systemctl enable dnsmasq
    systemctl restart dnsmasq || {
        log_error "dnsmasq failed to start" \
                  "Another service may be using port 53" \
                  "Check if systemd-resolved is still holding port 53" \
                  "ss -tlnp | grep :53; systemctl status systemd-resolved"
        return 1
    }

    sleep 2
    local test_resolve
    test_resolve=$(dig +short "rancher.${local_domain}" @127.0.0.1 2>/dev/null)
    if [[ "$test_resolve" == "$node_ip" ]]; then
        log_success "Local DNS working: rancher.${local_domain} -> ${node_ip}"
    else
        log_error "Local DNS verification failed" \
                  "dnsmasq returned '${test_resolve}' instead of '${node_ip}'" \
                  "Check dnsmasq config and logs" \
                  "dig +short rancher.${local_domain} @127.0.0.1; cat /var/log/dnsmasq-openg2p.log"
        return 1
    fi

    log_info "Configuring the VM to use local DNS for resolution..."
    if ! grep -q "127.0.0.1" /etc/resolv.conf 2>/dev/null; then
        sed -i '1i nameserver 127.0.0.1' /etc/resolv.conf 2>/dev/null || {
            echo "nameserver 127.0.0.1" > /tmp/resolv.conf
            cat /etc/resolv.conf >> /tmp/resolv.conf 2>/dev/null
            mv /tmp/resolv.conf /etc/resolv.conf
        }
    fi

    log_success "dnsmasq configured. All *.${local_domain} resolves to ${node_ip}."
    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 8: TLS Certificates
# ─────────────────────────────────────────────────────────────────────────────
phase1_step8_certificates() {
    local step_id="phase1.certificates"
    skip_if_done "$step_id" "TLS certificates" && return 0

    local domain_mode=$(cfg "domain_mode" "custom")
    if [[ "$domain_mode" == "local" ]]; then
        phase1_step8_certificates_local
    else
        phase1_step8_certificates_letsencrypt
    fi
    mark_step_done "$step_id"
}

phase1_step8_certificates_local() {
    log_step "1.8" "Generating local CA and self-signed TLS certificates"

    local local_domain=$(cfg "local_domain" "openg2p.test")
    local rancher_host=$(get_rancher_hostname)
    local keycloak_host=$(get_keycloak_hostname)
    local ca_dir="/etc/openg2p/ca"
    local certs_dir="/etc/openg2p/certs"

    mkdir -p "$ca_dir" "$certs_dir"

    if [[ ! -f "${ca_dir}/ca.key" ]]; then
        log_info "Generating local Certificate Authority..."
        openssl genrsa -out "${ca_dir}/ca.key" 4096 2>/dev/null
        openssl req -x509 -new -nodes \
            -key "${ca_dir}/ca.key" -sha256 -days 3650 \
            -subj "/C=XX/ST=OpenG2P/L=OpenG2P/O=OpenG2P/CN=OpenG2P Local CA" \
            -out "${ca_dir}/ca.crt" 2>/dev/null
        chmod 600 "${ca_dir}/ca.key"
        log_success "Local CA created at ${ca_dir}/ca.crt"
    else
        log_success "Local CA already exists."
    fi

    for domain in "$rancher_host" "$keycloak_host"; do
        local cert_path="${certs_dir}/${domain}"
        if [[ -f "${cert_path}/fullchain.pem" && -f "${cert_path}/privkey.pem" ]]; then
            log_success "Certificate for ${domain} already exists."
            continue
        fi
        log_info "Generating certificate for ${domain}..."
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
CN = ${domain}
[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${domain}
DNS.2 = *.${local_domain}
DNS.3 = ${local_domain}
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
        log_success "Certificate generated for ${domain}."
    done

    log_success "All local certificates generated."
    log_info ""
    log_info "To avoid browser warnings, install the CA certificate on your laptop:"
    log_info "  CA cert: ${ca_dir}/ca.crt"
    log_info "  macOS:   Import into Keychain Access -> System -> Always Trust"
    log_info "  Windows: Import into Trusted Root Certification Authorities"
    log_info "  Linux:   sudo cp ca.crt /usr/local/share/ca-certificates/openg2p-ca.crt"
    log_info "           sudo update-ca-certificates"
    log_info ""
}

phase1_step8_certificates_letsencrypt() {
    log_step "1.8" "Obtaining Let's Encrypt TLS certificates"

    local email=$(cfg "letsencrypt_email")
    local challenge=$(cfg "letsencrypt_challenge" "dns")
    local rancher_host=$(get_rancher_hostname)
    local keycloak_host=$(get_keycloak_hostname)

    install_if_missing "certbot" \
        "certbot --version" \
        "apt-get install -y -qq certbot > /dev/null 2>&1" \
        "https://certbot.eff.org/"

    case "$challenge" in
        dns-cloudflare)
            install_if_missing "certbot-dns-cloudflare" \
                "pip3 show certbot-dns-cloudflare" \
                "apt-get install -y -qq python3-certbot-dns-cloudflare > /dev/null 2>&1 || pip3 install certbot-dns-cloudflare --break-system-packages"
            local cf_token=$(cfg "cloudflare_api_token")
            if [[ -z "$cf_token" ]]; then
                log_error "Cloudflare API token not set" \
                          "cloudflare_api_token is empty in config" \
                          "Set cloudflare_api_token in your config file" \
                          "" "https://dash.cloudflare.com/profile/api-tokens"
                return 1
            fi
            mkdir -p /etc/letsencrypt
            echo "dns_cloudflare_api_token = ${cf_token}" > /etc/letsencrypt/cloudflare.ini
            chmod 600 /etc/letsencrypt/cloudflare.ini
            ;;
        dns-route53)
            install_if_missing "certbot-dns-route53" \
                "pip3 show certbot-dns-route53" \
                "apt-get install -y -qq python3-certbot-dns-route53 > /dev/null 2>&1 || pip3 install certbot-dns-route53 --break-system-packages"
            ;;
    esac

    local certs_exist=true
    for domain in "$rancher_host" "$keycloak_host"; do
        [[ ! -d "/etc/letsencrypt/live/${domain}" ]] && certs_exist=false && break
    done
    if [[ "$certs_exist" == "true" ]]; then
        log_success "TLS certificates already exist for Rancher and Keycloak."
        return 0
    fi

    if systemctl is-active --quiet nginx 2>/dev/null; then
        log_info "Stopping Nginx temporarily for certificate generation..."
        systemctl stop nginx
    fi

    log_info "Requesting certificates (challenge: ${challenge})..."

    for domain in "$rancher_host" "$keycloak_host"; do
        [[ -d "/etc/letsencrypt/live/${domain}" ]] && { log_success "Cert for ${domain} exists."; continue; }
        log_info "Requesting certificate for ${domain}..."
        case "$challenge" in
            dns)
                log_info "Manual DNS-01: certbot will prompt you to create a TXT record."
                certbot certonly --manual --preferred-challenges dns --agree-tos \
                    --email "$email" -d "$domain" || {
                    log_error "Cert failed for ${domain}" "DNS-01 challenge failed" \
                              "Verify: dig TXT _acme-challenge.${domain}"; return 1; } ;;
            dns-cloudflare)
                certbot certonly --dns-cloudflare \
                    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
                    --dns-cloudflare-propagation-seconds 30 \
                    --non-interactive --agree-tos --email "$email" -d "$domain" || {
                    log_error "Cert failed for ${domain}" "Cloudflare DNS-01 failed" \
                              "Check API token and zone permissions"; return 1; } ;;
            dns-route53)
                certbot certonly --dns-route53 --dns-route53-propagation-seconds 30 \
                    --non-interactive --agree-tos --email "$email" -d "$domain" || {
                    log_error "Cert failed for ${domain}" "Route53 DNS-01 failed" \
                              "Check AWS credentials"; return 1; } ;;
            http)
                certbot certonly --standalone --non-interactive --agree-tos \
                    --email "$email" -d "$domain" || {
                    log_error "Cert failed for ${domain}" "HTTP-01 failed — port 80 not reachable?" \
                              "Ensure port 80 is open"; return 1; } ;;
            *) log_error "Unknown challenge: '${challenge}'" "Valid: dns, dns-cloudflare, dns-route53, http" ""; return 1 ;;
        esac
        log_success "Certificate obtained for ${domain}."
    done
    log_success "All TLS certificates obtained."
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 9: Nginx Reverse Proxy
# ─────────────────────────────────────────────────────────────────────────────
phase1_step9_nginx() {
    local step_id="phase1.nginx"
    skip_if_done "$step_id" "Nginx reverse proxy" && return 0

    log_step "1.9" "Installing and configuring Nginx reverse proxy"

    local node_ip=$(cfg "node_ip")
    local domain_mode=$(cfg "domain_mode" "custom")
    local rancher_host=$(get_rancher_hostname)
    local keycloak_host=$(get_keycloak_hostname)

    install_if_missing "nginx" \
        "nginx -v" \
        "apt-get install -y -qq nginx > /dev/null 2>&1" \
        "https://nginx.org/en/linux_packages.html"

    local rancher_cert rancher_key keycloak_cert keycloak_key
    if [[ "$domain_mode" == "local" ]]; then
        local certs_dir="/etc/openg2p/certs"
        rancher_cert="${certs_dir}/${rancher_host}/fullchain.pem"
        rancher_key="${certs_dir}/${rancher_host}/privkey.pem"
        keycloak_cert="${certs_dir}/${keycloak_host}/fullchain.pem"
        keycloak_key="${certs_dir}/${keycloak_host}/privkey.pem"
    else
        rancher_cert="/etc/letsencrypt/live/${rancher_host}/fullchain.pem"
        rancher_key="/etc/letsencrypt/live/${rancher_host}/privkey.pem"
        keycloak_cert="/etc/letsencrypt/live/${keycloak_host}/fullchain.pem"
        keycloak_key="/etc/letsencrypt/live/${keycloak_host}/privkey.pem"
    fi

    for cert in "$rancher_cert" "$rancher_key" "$keycloak_cert" "$keycloak_key"; do
        if [[ ! -f "$cert" ]]; then
            log_error "TLS cert not found: ${cert}" \
                      "Certificate step may not have completed" \
                      "Run the certificate step again" \
                      "ls -la $(dirname "$cert")"
            return 1
        fi
    done

    log_info "Generating Nginx configuration..."
    rm -f /etc/nginx/sites-enabled/default

    cat > /etc/nginx/sites-available/openg2p-infra.conf <<EOF
upstream istio_ingress {
    server ${node_ip}:30080;
}
server {
    listen 80;
    server_name ${rancher_host} ${keycloak_host};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name ${rancher_host};
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
    server_name ${keycloak_host};
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

    ln -sf /etc/nginx/sites-available/openg2p-infra.conf /etc/nginx/sites-enabled/openg2p-infra.conf

    nginx -t || {
        log_error "Nginx config test failed" \
                  "Syntax error in generated config" \
                  "Review the config file" \
                  "nginx -t; cat /etc/nginx/sites-available/openg2p-infra.conf"
        return 1
    }

    systemctl enable nginx
    systemctl restart nginx || {
        log_error "Nginx failed to start" \
                  "Another service may be using port 80 or 443" \
                  "Check listening ports" \
                  "ss -tlnp | grep -E ':80|:443'"
        return 1
    }

    log_success "Nginx configured for ${rancher_host} and ${keycloak_host}."
    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all Phase 1 steps
# ─────────────────────────────────────────────────────────────────────────────
run_phase1() {
    log_step "1" "Phase 1 — Host-Level Setup"

    # On re-runs, RKE2 may already be installed — silently set kubeconfig if available.
    # On fresh installs, RKE2 doesn't exist yet, so we skip without error.
    if [[ -f /etc/rancher/rke2/rke2.yaml ]]; then
        export KUBECONFIG="/etc/rancher/rke2/rke2.yaml"
        export PATH="$PATH:/var/lib/rancher/rke2/bin"
    fi

    phase1_step1_tools
    phase1_step2_firewall
    phase1_step3_rke2

    # Now RKE2 is guaranteed installed — hard stop if kubeconfig is missing
    ensure_kubeconfig

    phase1_step4_wireguard
    phase1_step5_nfs_server
    phase1_step6_nfs_csi
    phase1_step7_local_dns      # Only runs in local mode
    phase1_step8_certificates   # Branches: local CA or Let's Encrypt
    phase1_step9_nginx          # Uses certs from whichever mode

    log_success "Phase 1 complete — all host-level components installed."
}
