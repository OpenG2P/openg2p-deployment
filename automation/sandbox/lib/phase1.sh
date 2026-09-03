#!/usr/bin/env bash
# =============================================================================
# OpenG2P Deployment Automation — Phase 1: Host-Level Setup
# =============================================================================
# Installs all host-level components on the VM: tools, firewall, RKE2,
# Wireguard, NFS, public DNS records, a Let's Encrypt TLS certificate, and Nginx.
# No local DNS server is installed — names resolve via the real public zone.
# Sourced by roles/infra/run.sh — do not run directly.
# =============================================================================

# Resolve the deployment repo root (parent of automation/).
# Supports two layouts:
#   1. Full git clone:  .../openg2p-deployment/automation/sandbox/lib → ../../../
#   2. Orchestrator stage: /tmp/openg2p-deploy/lib → ../  (nfs-server + kubernetes
#      are staged alongside the sandbox tree by ssh_stage_sandbox)
_SN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_SN_LIB_DIR}/../../../nfs-server/install-nfs-server.sh" ]]; then
    REPO_ROOT="$(cd "${_SN_LIB_DIR}/../../.." && pwd)"
elif [[ -f "${_SN_LIB_DIR}/../nfs-server/install-nfs-server.sh" ]]; then
    REPO_ROOT="$(cd "${_SN_LIB_DIR}/.." && pwd)"
else
    REPO_ROOT="$(cd "${_SN_LIB_DIR}/../../.." && pwd)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Helper: get effective Rancher hostname (derived from the sandbox domain)
# ─────────────────────────────────────────────────────────────────────────────
get_rancher_hostname() {
    echo "rancher.$(cfg 'domain' '')"
}

# ─────────────────────────────────────────────────────────────────────────────
# Tool installers — dedicated functions for tools whose install commands
# have nested subshells that break when passed through eval
# ─────────────────────────────────────────────────────────────────────────────
install_kubectl() {
    local version="${1:-v1.36.1}"
    if kubectl version --client &>/dev/null; then
        log_success "kubectl is already installed."
        return 0
    fi
    log_info "Installing kubectl ${version}..."
    curl -sLO "https://dl.k8s.io/release/${version}/bin/linux/amd64/kubectl" || {
        log_error "Failed to download kubectl ${version}" \
                  "Download from dl.k8s.io failed" \
                  "Check internet connectivity" \
                  "curl -sLO https://dl.k8s.io/release/${version}/bin/linux/amd64/kubectl" \
                  "https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/"
        return 1
    }
    install -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl
    log_success "kubectl ${version} installed."
}

install_helm() {
    local version="${1:-3.17.3}"
    if helm version &>/dev/null; then
        log_success "helm is already installed."
        return 0
    fi
    log_info "Installing Helm v${version}..."
    local url="https://get.helm.sh/helm-v${version}-linux-amd64.tar.gz"
    curl -sL "$url" -o /tmp/helm.tar.gz || {
        log_error "Failed to download Helm v${version}" \
                  "Download from get.helm.sh failed" \
                  "Check internet connectivity" \
                  "curl -sL ${url}" \
                  "https://helm.sh/docs/intro/install/"
        return 1
    }
    tar xzf /tmp/helm.tar.gz -C /tmp linux-amd64/helm || {
        log_error "Failed to extract Helm archive" \
                  "The downloaded file may be corrupt"
        rm -f /tmp/helm.tar.gz
        return 1
    }
    install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
    rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
    log_success "Helm v${version} installed."
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

install_helmfile() {
    local version="${1:-1.1.0}"
    if helmfile version &>/dev/null; then
        log_success "helmfile is already installed."
        return 0
    fi
    log_info "Installing helmfile v${version}..."
    local url="https://github.com/helmfile/helmfile/releases/download/v${version}/helmfile_${version}_linux_amd64.tar.gz"
    curl -sL "$url" -o /tmp/helmfile.tar.gz || {
        log_error "Failed to download helmfile v${version}" \
                  "Download from GitHub failed" \
                  "Check internet connectivity and that version ${version} exists" \
                  "curl -sI ${url}" \
                  "https://github.com/helmfile/helmfile/releases"
        return 1
    }
    tar xzf /tmp/helmfile.tar.gz -C /tmp helmfile || {
        log_error "Failed to extract helmfile archive" \
                  "The downloaded file may be corrupt" \
                  "Try downloading manually" \
                  "curl -sL ${url} | file -"
        rm -f /tmp/helmfile.tar.gz
        return 1
    }
    install -m 0755 /tmp/helmfile /usr/local/bin/helmfile
    rm -f /tmp/helmfile /tmp/helmfile.tar.gz
    log_success "helmfile v${version} installed."
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

    install_kubectl "v1.33.6" || return 1

    install_helm "3.17.3" || return 1

    install_istioctl "1.24.1" || return 1

    install_helmfile "1.1.0" || return 1

    if ! helm plugin list 2>/dev/null | grep -q diff; then
        log_info "Installing helm-diff plugin v3.9.14 (required by Helmfile)..."
        helm plugin install https://github.com/databus23/helm-diff --version v3.9.14 || {
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

    log_step "1.2" "Configuring firewall (ufw)"

    local node_ip=$(cfg "node_ip")
    local wg_port=$(cfg "wireguard.port" "51820")
    # public_access: when false (default), the web ports (80/443) are reachable
    # ONLY over Wireguard or from inside the VPC — NOT from the public Internet,
    # even if the VM has a public IP. Set it to "true" to expose the sandbox
    # publicly (see the security warning in sandbox-config.example.yaml).
    local public_access=$(cfg "public_access" "false")

    # Install ufw if not present
    install_if_missing "ufw" \
        "command -v ufw" \
        "apt-get install -y -qq ufw > /dev/null 2>&1"

    # Helper: add ufw rule, log it, fail clearly if it errors
    ufw_allow() {
        local desc="$1"; shift
        if ! ufw allow "$@" > /dev/null; then
            log_error "ufw rule failed: ${desc}" \
                      "Command: ufw allow $*" \
                      "Check ufw version and syntax" \
                      "ufw --version"
            return 1
        fi
        log_info "  ${desc}"
    }

    # Reset ufw to clean state (non-interactive)
    log_info "Resetting ufw to clean state..."
    ufw --force reset > /dev/null 2>&1

    # Default policy: deny inbound, allow outbound
    ufw default deny incoming > /dev/null
    ufw default allow outgoing > /dev/null

    # VPC scope (node's /16) and Wireguard subnet — used for the default,
    # private web-port rules and the inter-node rules below.
    local vpc_cidr wg_subnet_cidr
    vpc_cidr=$(echo "$node_ip" | awk -F. '{printf "%s.%s.0.0/16", $1, $2}')
    wg_subnet_cidr=$(cfg "wireguard.subnet" "10.15.0.0/16")

    # ── Always-public ports ──────────────────────────────────────────────
    # SSH (management channel) and the Wireguard UDP port (so external clients
    # can establish the tunnel in the first place) are always world-reachable.
    log_info "Allowing always-public ports (SSH, Wireguard)..."
    ufw_allow "TCP 22    SSH"              22/tcp                         || return 1
    ufw_allow "UDP ${wg_port}  Wireguard"  "${wg_port}/udp"               || return 1

    # ── Web ports (80/443) — private by default ──────────────────────────
    # By default the sandbox is NOT exposed to the public Internet. The web
    # ports are reachable only over Wireguard (the wg-subnet allow-all rule
    # below) or from inside the VPC. Set public_access: true to expose them
    # to the world (0.0.0.0/0) — this carries real security risk.
    if [[ "$public_access" == "true" ]]; then
        log_warn "public_access=true — exposing 80/443 to the PUBLIC INTERNET (0.0.0.0/0)."
        log_warn "  The Rancher admin UI and all environment services will be publicly reachable."
        ufw_allow "TCP 443   HTTPS (Nginx, PUBLIC)"  443/tcp             || return 1
        ufw_allow "TCP 80    HTTP  (redirect, PUBLIC)" 80/tcp            || return 1
    else
        log_info "Restricting 80/443 to Wireguard + VPC (private by default)..."
        ufw_allow "TCP 443 HTTPS (VPC)"   from "$vpc_cidr"       to any port 443 proto tcp || return 1
        ufw_allow "TCP 80  HTTP  (VPC)"   from "$vpc_cidr"       to any port 80  proto tcp || return 1
        ufw_allow "TCP 443 HTTPS (WG)"    from "$wg_subnet_cidr" to any port 443 proto tcp || return 1
        ufw_allow "TCP 80  HTTP  (WG)"    from "$wg_subnet_cidr" to any port 80  proto tcp || return 1
    fi

    # ── Inter-node / VPC (for multi-node scaling) ────────────────────────
    # These ports only need to be reachable from other cluster nodes.
    # We allow from the node's /16 subnet as a reasonable VPC-level scope.
    # On a sandbox setup these are accessed locally; the rules are
    # pre-configured so that adding worker nodes later "just works."
    log_info "Allowing inter-node ports from ${vpc_cidr}..."

    ufw_allow "TCP 6443  K8s API"          from "$vpc_cidr" to any port 6443 proto tcp          || return 1
    ufw_allow "TCP 9345  RKE2 supervisor"  from "$vpc_cidr" to any port 9345 proto tcp          || return 1
    ufw_allow "TCP 10250 Kubelet"          from "$vpc_cidr" to any port 10250 proto tcp         || return 1
    ufw_allow "TCP 2379  etcd client"      from "$vpc_cidr" to any port 2379 proto tcp          || return 1
    ufw_allow "TCP 2380  etcd peer"        from "$vpc_cidr" to any port 2380 proto tcp          || return 1
    ufw_allow "UDP 8472  VXLAN (CNI)"      from "$vpc_cidr" to any port 8472 proto udp          || return 1
    ufw_allow "TCP 9796  Node metrics"     from "$vpc_cidr" to any port 9796 proto tcp          || return 1
    ufw_allow "TCP 30000-32767 NodePorts"  from "$vpc_cidr" to any port 30000:32767 proto tcp   || return 1
    ufw_allow "TCP 2049  NFS"              from "$vpc_cidr" to any port 2049 proto tcp          || return 1
    # ICMP doesn't use ports — different syntax
    if ! ufw allow from "$vpc_cidr" proto icmp > /dev/null; then
        log_warn "Could not add ICMP rule (non-critical, continuing)."
    else
        log_info "  ICMP      Ping"
    fi

    # ── Wireguard VPN peers (trusted, allow all) ──────────────────────
    # VPN peers are authenticated via Wireguard keys — allow them full
    # access to services on this node (DNS, HTTPS, K8s API, etc.)
    log_info "Allowing all traffic from Wireguard peers (${wg_subnet_cidr})..."
    ufw_allow "Wireguard subnet (all)" from "$wg_subnet_cidr"  || return 1

    # Enable ufw (non-interactive)
    log_info "Enabling ufw..."
    ufw --force enable > /dev/null

    # Increase inotify limits — RKE2/K8s exhausts the defaults, causing
    # "Too many open files" errors for apt, systemd, and other tools
    log_info "Setting inotify limits for Kubernetes..."
    sysctl -w fs.inotify.max_user_watches=524288 > /dev/null 2>&1
    sysctl -w fs.inotify.max_user_instances=1024 > /dev/null 2>&1
    if ! grep -q "fs.inotify.max_user_watches" /etc/sysctl.conf 2>/dev/null; then
        echo "fs.inotify.max_user_watches=524288" >> /etc/sysctl.conf
    fi
    if ! grep -q "fs.inotify.max_user_instances" /etc/sysctl.conf 2>/dev/null; then
        echo "fs.inotify.max_user_instances=1024" >> /etc/sysctl.conf
    fi

    log_success "Firewall configured. Rules:"
    ufw status numbered 2>/dev/null | while IFS= read -r line; do
        log_info "  $line"
    done

    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: RKE2 Kubernetes cluster
# ─────────────────────────────────────────────────────────────────────────────
phase1_step3_rke2() {
    local step_id="phase1.rke2"
    skip_if_done "$step_id" "RKE2 Kubernetes cluster" && return 0

    log_step "1.3" "Installing RKE2 Kubernetes cluster"

    local rke2_version=$(cfg "rke2_version" "v1.33.6+rke2r1")
    local node_name=$(cfg "node_name" "node1")
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
  - --container-log-max-size=50Mi
  - --container-log-max-files=5
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

    # Generate a remote-access kubeconfig with the node's private IP
    # (the default rke2.yaml uses 127.0.0.1 which only works on the VM)
    local remote_kubeconfig="/etc/rancher/rke2/rke2-remote.yaml"
    log_info "Generating remote-access kubeconfig at ${remote_kubeconfig}..."
    sed "s|https://127.0.0.1:6443|https://${node_ip}:6443|g" \
        /etc/rancher/rke2/rke2.yaml > "$remote_kubeconfig"
    chmod 600 "$remote_kubeconfig"
    log_success "Remote kubeconfig ready: ${remote_kubeconfig}"
    log_info "Copy this file to your laptop to access the cluster via kubectl/helm."

    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Wireguard VPN (native — runs as a systemd service, not a K8s pod)
# ─────────────────────────────────────────────────────────────────────────────
phase1_step4_wireguard() {
    local step_id="phase1.wireguard"
    skip_if_done "$step_id" "Wireguard VPN" && return 0

    log_step "1.4" "Installing Wireguard VPN (native)"

    local node_ip=$(cfg "node_ip")
    local wg_port=$(cfg "wireguard.port" "51820")
    local wg_subnet=$(cfg "wireguard.subnet" "10.15.0.0/16")
    local wg_peers=$(cfg "wireguard.peers" "254")
    # Default: split tunnel — only route Wireguard + VPC traffic through VPN.
    # Users can set cluster_subnet to "0.0.0.0/0" for full tunnel if preferred.
    local allowed_ips=$(cfg "wireguard.cluster_subnet" "")
    if [[ -z "$allowed_ips" ]]; then
        local vpc_cidr_wg
        vpc_cidr_wg=$(echo "$node_ip" | awk -F. '{printf "%s.%s.0.0/16", $1, $2}')
        allowed_ips="${wg_subnet}, ${vpc_cidr_wg}"
    fi
    local wg_endpoint=$(cfg "wireguard.endpoint" "$node_ip")
    local wg_iface="wg0"
    local peer_dir="/etc/wireguard/peers"

    # Idempotency: if wg0 is already up and peer configs exist, skip
    if systemctl is-active --quiet "wg-quick@${wg_iface}" 2>/dev/null && [[ -d "$peer_dir/peer1" ]]; then
        log_success "Wireguard is already running (wg-quick@${wg_iface})."
        mark_step_done "$step_id"
        return 0
    fi

    # Install wireguard-tools (kernel module is built-in on Ubuntu 24.04)
    install_if_missing "wireguard" \
        "wg version" \
        "apt-get install -y -qq wireguard-tools > /dev/null 2>&1" \
        "https://www.wireguard.com/install/"

    # Enable IP forwarding (required for VPN routing)
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi

    # Parse subnet: e.g. "10.15.0.0/16" -> base="10.15" mask="16"
    local subnet_base subnet_mask
    subnet_base=$(echo "$wg_subnet" | cut -d'/' -f1)
    subnet_mask=$(echo "$wg_subnet" | cut -d'/' -f2)

    # Extract first two octets for IP generation (assumes /16 subnet)
    local octet1 octet2
    octet1=$(echo "$subnet_base" | cut -d'.' -f1)
    octet2=$(echo "$subnet_base" | cut -d'.' -f2)

    log_info "Generating Wireguard keys and configs..."
    log_info "  Interface: ${wg_iface}, Port: ${wg_port}, Subnet: ${wg_subnet}, Peers: ${wg_peers}"

    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard

    # Generate server keys
    local server_privkey server_pubkey
    server_privkey=$(wg genkey)
    server_pubkey=$(echo "$server_privkey" | wg pubkey)

    # Server IP is .0.1 in the subnet
    local server_ip="${octet1}.${octet2}.0.1/${subnet_mask}"

    # Build server config header
    cat > "/etc/wireguard/${wg_iface}.conf" <<EOF
# OpenG2P Wireguard server — auto-generated by roles/infra/run.sh
[Interface]
Address = ${server_ip}
ListenPort = ${wg_port}
PrivateKey = ${server_privkey}
PostUp = iptables -A FORWARD -i ${wg_iface} -j ACCEPT; iptables -A FORWARD -o ${wg_iface} -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE
PostDown = iptables -D FORWARD -i ${wg_iface} -j ACCEPT; iptables -D FORWARD -o ${wg_iface} -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE
EOF

    # DNS line for peer configs.
    #
    # The sandbox runs NO local DNS server: hostnames are published as public A
    # records in the real DNS zone (see lib/acme.sh), so a peer's normal
    # resolver answers them and no DNS push is needed. Left blank by default.
    #
    # Set wireguard.peer_dns to a public resolver (e.g. "1.1.1.1") if a peer's
    # own resolver strips RFC1918 answers from public DNS — "DNS rebinding
    # protection", on by default in pfSense/OPNsense, Fritz!Box, OpenDNS and
    # some appliance firmware. That is the one common failure mode here.
    local peer_dns=$(cfg "wireguard.peer_dns" "")
    local peer_dns_line=""
    [[ -n "$peer_dns" ]] && peer_dns_line="DNS = ${peer_dns}"

    # Generate peer configs
    mkdir -p "$peer_dir"
    local peer_num=1
    local peer_octet3=0
    local peer_octet4=2  # .0.1 is the server, peers start at .0.2

    while [[ $peer_num -le $wg_peers ]]; do
        local peer_privkey peer_pubkey peer_psk
        peer_privkey=$(wg genkey)
        peer_pubkey=$(echo "$peer_privkey" | wg pubkey)
        peer_psk=$(wg genpsk)

        local peer_ip="${octet1}.${octet2}.${peer_octet3}.${peer_octet4}"

        # Add peer to server config
        cat >> "/etc/wireguard/${wg_iface}.conf" <<EOF

# peer${peer_num}
[Peer]
PublicKey = ${peer_pubkey}
PresharedKey = ${peer_psk}
AllowedIPs = ${peer_ip}/32
EOF

        # Write individual peer config file
        mkdir -p "${peer_dir}/peer${peer_num}"
        cat > "${peer_dir}/peer${peer_num}/peer${peer_num}.conf" <<EOF
[Interface]
Address = ${peer_ip}/${subnet_mask}
PrivateKey = ${peer_privkey}
${peer_dns_line}

[Peer]
PublicKey = ${server_pubkey}
PresharedKey = ${peer_psk}
Endpoint = ${wg_endpoint}:${wg_port}
AllowedIPs = ${allowed_ips}
PersistentKeepalive = 25
EOF

        # Advance IP: .0.2, .0.3, ... .0.255, .1.0, .1.1, ...
        # Use $(( )) assignment form — (( var++ )) returns exit code 1
        # when the OLD value is 0, which kills the script under set -e.
        peer_octet4=$((peer_octet4 + 1))
        if [[ $peer_octet4 -gt 255 ]]; then
            peer_octet4=0
            peer_octet3=$((peer_octet3 + 1))
        fi
        peer_num=$((peer_num + 1))
    done

    chmod 600 /etc/wireguard/${wg_iface}.conf
    chmod -R 600 "$peer_dir"
    # Directories need execute bit to be traversable
    find "$peer_dir" -type d -exec chmod 700 {} \;

    log_success "Generated server config and ${wg_peers} peer configs."

    # Enable and start Wireguard
    log_info "Starting Wireguard (wg-quick@${wg_iface})..."
    systemctl enable "wg-quick@${wg_iface}"
    systemctl start "wg-quick@${wg_iface}" || {
        log_error "Wireguard failed to start" \
                  "wg-quick@${wg_iface} could not be started" \
                  "Check the Wireguard config and system logs" \
                  "journalctl -u wg-quick@${wg_iface} -n 20 --no-pager; cat /etc/wireguard/${wg_iface}.conf"
        return 1
    }

    # Verify it's running
    if wg show "$wg_iface" &>/dev/null; then
        log_success "Wireguard interface ${wg_iface} is up."
    else
        log_error "Wireguard interface ${wg_iface} is not active" \
                  "wg-quick started but the interface may not have come up" \
                  "Check logs and config" \
                  "wg show; journalctl -u wg-quick@${wg_iface} -n 20"
        return 1
    fi

    log_info ""
    log_info "Peer configs are at: ${peer_dir}/"
    log_info "  Example: ${peer_dir}/peer1/peer1.conf"
    log_info "Copy a peer config to your laptop and import into Wireguard client."
    log_info "No DNS setup is needed on the client — hostnames under $(cfg 'domain' '') are"
    log_info "published as public A records and resolve via the client's normal resolver."
    log_info ""

    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: NFS Server
# ─────────────────────────────────────────────────────────────────────────────
phase1_step5_nfs_server() {
    local step_id="phase1.nfs_server"
    skip_if_done "$step_id" "NFS server" && return 0

    log_step "1.5" "Installing NFS server"

    local cluster_name=$(cfg "cluster_name" "openg2p")
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
    local cluster_name=$(cfg "cluster_name" "openg2p")
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
# Step 7: DNS records + TLS certificate (Let's Encrypt)
# ─────────────────────────────────────────────────────────────────────────────
# The sandbox runs NO local DNS server. Hostnames are published as A records in
# the real public zone, so clients and pods resolve them with their normal
# resolver. The certificate is issued by Let's Encrypt over the ACME DNS-01
# challenge — outbound only, nothing ever connects back to this machine.
phase1_step7_certificates() {
    local step_id="phase1.certificates"
    skip_if_done "$step_id" "DNS records and TLS certificate" && return 0

    log_step "1.7" "Publishing DNS records and obtaining the TLS certificate"

    local node_ip=$(cfg "node_ip")
    local rancher_host=$(get_rancher_hostname)

    # Re-validate here as well as in the orchestrator: roles/infra/run.sh can be
    # invoked directly on-box, bypassing the laptop-side preflight.
    acme_preflight || return 1
    acme_install_client || return 1

    # Publish the infra hostname so it resolves without any local DNS server.
    acme_publish_a_record "rancher" "$node_ip" || return 1

    # Single-name cert; the per-environment wildcard is issued in env phase 1.
    acme_wait_dns_propagation "$rancher_host"

    acme_issue_cert "$rancher_host" "$rancher_host" || return 1

    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 8: Nginx Reverse Proxy
# ─────────────────────────────────────────────────────────────────────────────
phase1_step9_nginx() {
    local step_id="phase1.nginx"
    skip_if_done "$step_id" "Nginx reverse proxy" && return 0

    log_step "1.8" "Installing and configuring Nginx reverse proxy"

    local node_ip=$(cfg "node_ip")
    local rancher_host=$(get_rancher_hostname)

    install_if_missing "nginx" \
        "nginx -v" \
        "apt-get install -y -qq nginx > /dev/null 2>&1" \
        "https://nginx.org/en/linux_packages.html"

    local rancher_cert rancher_key
    rancher_cert=$(get_cert_path "$rancher_host" "cert")
    rancher_key=$(get_cert_path "$rancher_host" "key")

    for cert in "$rancher_cert" "$rancher_key"; do
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
    server_name ${rancher_host};
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

    log_success "Nginx configured for ${rancher_host}."
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
    phase1_step7_certificates   # public A records + Let's Encrypt certificate
    phase1_step9_nginx          # Nginx reverse proxy using the issued certificate

    log_success "Phase 1 complete — all host-level components installed."
}
