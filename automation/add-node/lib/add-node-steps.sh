#!/usr/bin/env bash
# =============================================================================
# OpenG2P Add-Node Automation — Step Functions
# =============================================================================
# Step implementations for joining a new Ubuntu 24.04 node to an existing
# RKE2 cluster as either a server (control-plane) or agent (worker).
#
# Sourced by openg2p-add-node.sh — do not run directly.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Validate configuration and reachability to the existing cluster
# ─────────────────────────────────────────────────────────────────────────────
step1_validate() {
    local step_id="add-node.validate"
    skip_if_done "$step_id" "Configuration and connectivity validation" && return 0

    log_step "1" "Validating configuration and connectivity"

    local errors=0

    # ── Required fields ──────────────────────────────────────────────────
    local required_keys=(server_url rke2_token node_ip node_name node_role rke2_version)
    for key in "${required_keys[@]}"; do
        if [[ -z "$(cfg "$key")" ]]; then
            log_warn "Missing required config key: '${key}'"
            ((errors++))
        fi
    done

    # ── IP format ────────────────────────────────────────────────────────
    local node_ip; node_ip=$(cfg "node_ip")
    if [[ -n "$node_ip" ]] && ! [[ "$node_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_warn "Invalid node_ip format: '${node_ip}'"
        ((errors++))
    fi

    # ── node_role must be server or worker ────────────────────────────────
    local role; role=$(cfg "node_role")
    if [[ "$role" != "server" && "$role" != "worker" ]]; then
        log_warn "node_role must be 'server' or 'worker' (got: '${role}')"
        ((errors++))
    fi

    # ── server_url format ────────────────────────────────────────────────
    local server_url; server_url=$(cfg "server_url")
    # Reject accidental extra slashes (https:////ip:port) which previously
    # passed a loose regex and produced host="//ip" for /dev/tcp.
    if [[ -n "$server_url" ]] && ! [[ "$server_url" =~ ^https://[A-Za-z0-9._-]+(:[0-9]+)?$ ]]; then
        log_warn "server_url must look like 'https://<ip-or-host>:9345' (got: '${server_url}')"
        ((errors++))
    fi

    if [[ $errors -gt 0 ]]; then
        log_error "Configuration validation failed with ${errors} error(s)" \
                  "Required fields are missing or invalid" \
                  "Review add-node-config.example.yaml for required fields"
        exit 1
    fi

    # ── Connectivity check to existing cluster's RKE2 supervisor port ────
    local host port
    if ! parse_rke2_server_url "$server_url" host port; then
        log_error "Could not parse server_url: '${server_url}'" \
                  "Expected https://<ip-or-host>:9345" \
                  "Fix server_url in add-node-config.yaml"
        exit 1
    fi
    log_info "server_url: ${server_url}"
    log_info "Checking TCP connectivity to ${host}:${port} (RKE2 supervisor)..."
    if ! check_tcp_port "$host" "$port" 5; then
        log_error "Cannot reach ${host}:${port}" \
                  "The RKE2 supervisor port on the primary node is not reachable from this node" \
                  "From THIS node run: nc -zv ${host} ${port} ; ping -c2 ${host}" \
                  "On the primary: systemctl is-active rke2-server ; sudo ufw status ; check SG allows TCP/9345 from ${node_ip}/32 or the VPC CIDR"
        exit 1
    fi
    log_success "Supervisor port reachable: ${host}:${port}."

    # ── Warn if rke2-server or rke2-agent already exists ──────────────────
    if systemctl list-unit-files 2>/dev/null | grep -qE '^rke2-(server|agent)\.service'; then
        if systemctl is-active --quiet rke2-server 2>/dev/null || \
           systemctl is-active --quiet rke2-agent 2>/dev/null; then
            log_warn "An RKE2 service is already running on this node."
            log_warn "If it's part of a different cluster, uninstall it first:"
            log_warn "  sudo /usr/local/bin/rke2-uninstall.sh"
        fi
    fi

    log_success "Configuration validated."
    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Install basic tools (apt packages + kubectl for server role)
# ─────────────────────────────────────────────────────────────────────────────
step2_tools() {
    local step_id="add-node.tools"
    skip_if_done "$step_id" "Prerequisite tools installation" && return 0

    log_step "2" "Installing prerequisite tools"

    apt-get update -qq || {
        log_error "apt-get update failed" \
                  "Package index could not be refreshed" \
                  "Check internet connectivity and /etc/apt/sources.list" \
                  "apt-get update"
        return 1
    }

    apt-get install -y -qq wget curl jq openssl dnsutils software-properties-common \
        apt-transport-https ca-certificates gnupg nfs-common > /dev/null 2>&1 || {
        log_error "Failed to install basic packages" \
                  "apt-get install failed" \
                  "Check internet connectivity and disk space"
        return 1
    }
    log_success "Basic tools installed (wget, curl, jq, openssl, dig, nfs-common)."

    # kubectl only useful on server (control-plane) nodes — agents don't get a kubeconfig
    local role; role=$(cfg "node_role")
    if [[ "$role" == "server" ]]; then
        local kube_version="v1.35.8"
        if ! kubectl version --client &>/dev/null; then
            log_info "Installing kubectl ${kube_version}..."
            curl -sLO "https://dl.k8s.io/release/${kube_version}/bin/linux/amd64/kubectl" || {
                log_error "Failed to download kubectl" "Download from dl.k8s.io failed" \
                          "Check internet connectivity"
                return 1
            }
            install -m 0755 kubectl /usr/local/bin/kubectl
            rm -f kubectl
            log_success "kubectl ${kube_version} installed."
        else
            log_success "kubectl is already installed."
        fi
    fi

    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Firewall (ufw) — same rule set as primary, scoped to VPC subnet
# ─────────────────────────────────────────────────────────────────────────────
step3_firewall() {
    local step_id="add-node.firewall"
    skip_if_done "$step_id" "Firewall setup" && return 0

    log_step "3" "Configuring firewall (ufw)"

    local node_ip; node_ip=$(cfg "node_ip")
    local vpc_cidr; vpc_cidr=$(cfg "vpc_subnet" "")
    if [[ -z "$vpc_cidr" ]]; then
        vpc_cidr=$(echo "$node_ip" | awk -F. '{printf "%s.%s.0.0/16", $1, $2}')
        log_info "vpc_subnet not set — derived /16 from node_ip: ${vpc_cidr}"
    fi
    local wg_subnet; wg_subnet=$(cfg "wireguard_subnet" "10.15.0.0/16")

    install_if_missing "ufw" \
        "command -v ufw" \
        "apt-get install -y -qq ufw > /dev/null 2>&1"

    ufw_allow() {
        local desc="$1"; shift
        if ! ufw allow "$@" > /dev/null; then
            log_error "ufw rule failed: ${desc}" "Command: ufw allow $*" \
                      "Check ufw version and syntax"
            return 1
        fi
        log_info "  ${desc}"
    }

    log_info "Resetting ufw to clean state..."
    ufw --force reset > /dev/null 2>&1
    ufw default deny incoming > /dev/null
    ufw default allow outgoing > /dev/null

    # Public: only SSH (no Nginx on worker/additional nodes)
    log_info "Allowing public ports..."
    ufw_allow "TCP 22    SSH" 22/tcp || return 1

    # Inter-node ports (VPC scope)
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
    if ! ufw allow from "$vpc_cidr" proto icmp > /dev/null; then
        log_warn "Could not add ICMP rule (non-critical, continuing)."
    else
        log_info "  ICMP      Ping"
    fi

    # Wireguard peer subnet (trusted)
    log_info "Allowing Wireguard peer subnet (${wg_subnet})..."
    ufw_allow "Wireguard subnet (all)" from "$wg_subnet" || return 1

    log_info "Enabling ufw..."
    ufw --force enable > /dev/null

    # inotify tuning (same as primary)
    log_info "Setting inotify limits for Kubernetes..."
    sysctl -w fs.inotify.max_user_watches=524288 > /dev/null 2>&1
    sysctl -w fs.inotify.max_user_instances=1024 > /dev/null 2>&1
    grep -q "fs.inotify.max_user_watches" /etc/sysctl.conf 2>/dev/null || \
        echo "fs.inotify.max_user_watches=524288" >> /etc/sysctl.conf
    grep -q "fs.inotify.max_user_instances" /etc/sysctl.conf 2>/dev/null || \
        echo "fs.inotify.max_user_instances=1024" >> /etc/sysctl.conf

    log_success "Firewall configured."
    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Install RKE2 (server or agent) and join the existing cluster
# ─────────────────────────────────────────────────────────────────────────────
step4_rke2() {
    local step_id="add-node.rke2"
    skip_if_done "$step_id" "RKE2 install and join" && return 0

    log_step "4" "Installing RKE2 and joining the existing cluster"

    local role;         role=$(cfg "node_role")
    local server_url;   server_url=$(cfg "server_url")
    local rke2_token;   rke2_token=$(cfg "rke2_token")
    local rke2_version; rke2_version=$(cfg "rke2_version" "v1.35.8+rke2r1")
    local node_name;    node_name=$(cfg "node_name")
    local node_ip;      node_ip=$(cfg "node_ip")

    # RKE2 distinguishes server vs agent via the INSTALL_RKE2_TYPE env var.
    # Both use /etc/rancher/rke2/config.yaml — the join fields ('server' and
    # 'token') are what tells this node to join an existing cluster instead
    # of bootstrapping a new one.
    local rke2_type="agent"
    [[ "$role" == "server" ]] && rke2_type="server"
    local service_name="rke2-${rke2_type}"

    # Idempotency: if the target service is already up, just verify and exit.
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        log_success "${service_name} is already running on this node."
        mark_step_done "$step_id"
        return 0
    fi

    log_info "Creating RKE2 configuration (role=${rke2_type})..."
    mkdir -p /etc/rancher/rke2
    {
        echo "server: ${server_url}"
        echo "token: ${rke2_token}"
        echo "node-name: ${node_name}"
        echo "node-ip: ${node_ip}"
        if [[ "$rke2_type" == "server" ]]; then
            # Match primary's settings. Ingress gateway label is intentionally
            # NOT set here — see README for why (keep ingress pinned to primary
            # unless the Istio operator config adds anti-affinity).
            echo "disable:"
            echo "  - rke2-ingress-nginx"
            echo "kubelet-arg:"
            echo "  - --allowed-unsafe-sysctls=net.ipv4.conf.all.src_valid_mark,net.ipv4.ip_forward"
            echo "  - --container-log-max-size=50Mi"
            echo "  - --container-log-max-files=5"
        else
            echo "kubelet-arg:"
            echo "  - --container-log-max-size=50Mi"
            echo "  - --container-log-max-files=5"
        fi
    } > /etc/rancher/rke2/config.yaml

    log_info "Downloading and installing RKE2 ${rke2_version} (type=${rke2_type})..."
    export INSTALL_RKE2_VERSION="${rke2_version}"
    export INSTALL_RKE2_TYPE="${rke2_type}"
    if ! curl -sfL https://get.rke2.io | sh -; then
        log_error "RKE2 download/install failed" \
                  "The install script could not complete" \
                  "Check internet connectivity and disk space" \
                  "curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=${rke2_version} INSTALL_RKE2_TYPE=${rke2_type} sh -" \
                  "https://docs.rke2.io/install/quickstart"
        return 1
    fi

    log_info "Enabling and starting ${service_name}..."
    systemctl enable "$service_name"
    systemctl start "$service_name" || {
        log_error "${service_name} failed to start" \
                  "Check system resources and /etc/rancher/rke2/config.yaml" \
                  "Review RKE2 logs" \
                  "journalctl -u ${service_name} -n 50 --no-pager"
        return 1
    }

    # Set up PATH for convenience (kubectl from bundled bin, KUBECONFIG only on server)
    cat > /etc/profile.d/openg2p-k8s.sh <<'PROFILE'
export PATH="$PATH:/var/lib/rancher/rke2/bin"
# On RKE2 server nodes, kubeconfig is at /etc/rancher/rke2/rke2.yaml.
# On agent nodes, this file does not exist — kubectl must be run from the primary.
if [[ -f /etc/rancher/rke2/rke2.yaml ]]; then
    export KUBECONFIG="/etc/rancher/rke2/rke2.yaml"
fi
PROFILE

    log_success "RKE2 ${rke2_type} is running."
    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Verify the node has joined the cluster
# ─────────────────────────────────────────────────────────────────────────────
step5_verify() {
    local step_id="add-node.verify"
    skip_if_done "$step_id" "Cluster join verification" && return 0

    log_step "5" "Verifying cluster membership"

    local role;      role=$(cfg "node_role")
    local node_name; node_name=$(cfg "node_name")

    if [[ "$role" == "server" ]]; then
        # Server nodes have a local kubeconfig. Wait for self to report Ready.
        export PATH="$PATH:/var/lib/rancher/rke2/bin"
        export KUBECONFIG="/etc/rancher/rke2/rke2.yaml"

        if [[ ! -f "$KUBECONFIG" ]]; then
            log_error "Kubeconfig not found at ${KUBECONFIG}" \
                      "RKE2 server may still be initializing, or it failed to start" \
                      "Check service status" \
                      "systemctl status rke2-server; journalctl -u rke2-server -n 50"
            return 1
        fi

        wait_for_command "Node '${node_name}' to appear as Ready" \
            "kubectl get node ${node_name} 2>/dev/null | tail -1 | awk '{print \$2}' | grep -qw Ready" \
            300 10 || {
            log_error "Node did not become Ready within timeout" \
                      "kubelet may still be starting, or CNI may not be ready" \
                      "Check node and service status" \
                      "kubectl get nodes; journalctl -u rke2-server -n 50"
            return 1
        }
        log_success "Node is Ready. Current cluster state:"
        kubectl get nodes -o wide || true
    else
        # Agent nodes — no local kubectl access. Service status is the best we can do here.
        log_info "Agent nodes cannot be verified locally (no kubeconfig on agents)."
        log_info "Checking that rke2-agent is active..."
        if ! systemctl is-active --quiet rke2-agent; then
            log_error "rke2-agent is not active" \
                      "The agent service failed to start or stay running" \
                      "Check logs on this node" \
                      "journalctl -u rke2-agent -n 50 --no-pager"
            return 1
        fi
        log_success "rke2-agent is active. Verify from the primary node with:"
        log_info "    kubectl get nodes -o wide"
        log_info "You should see '${node_name}' in the list within a minute or two."
    fi

    mark_step_done "$step_id"
}

# ─────────────────────────────────────────────────────────────────────────────
# Final: print the post-install manual-steps guide and write it to disk
# ─────────────────────────────────────────────────────────────────────────────
print_post_install_guide() {
    local role;           role=$(cfg "node_role")
    local node_name;      node_name=$(cfg "node_name")
    local node_ip;        node_ip=$(cfg "node_ip")
    local server_url;     server_url=$(cfg "server_url")
    local primary_host primary_port
    parse_rke2_server_url "$server_url" primary_host primary_port || primary_host="${server_url}"
    local guide_file="/root/openg2p-add-node-postinstall.txt"

    local rke2_svc="rke2-agent"
    [[ "$role" == "server" ]] && rke2_svc="rke2-server"

    local guide
    guide=$(cat <<EOF
=============================================================================
  NODE JOINED SUCCESSFULLY
=============================================================================
  Node name : ${node_name}
  Node IP   : ${node_ip}
  Role      : ${role} (${rke2_svc})
  Primary   : ${primary_host}

MANUAL FOLLOW-UP (do these after the node is Ready in 'kubectl get nodes'):

─────────────────────────────────────────────────────────────────────────────
1. Add this node to the Nginx upstream on the primary (OPTIONAL, for HA)
─────────────────────────────────────────────────────────────────────────────
   By default, Nginx on the primary proxies only to the primary's own
   Istio NodePort. Adding this node gives you load-balancing across both.

   SSH to the primary (${primary_host}) and run:
     sudo vi /etc/nginx/sites-available/openg2p-infra.conf

   Change the upstream block from:
       upstream istio_ingress {
           server ${primary_host}:30080;
       }
   To:
       upstream istio_ingress {
           server ${primary_host}:30080;
           server ${node_ip}:30080;
       }

   Then reload Nginx:
     sudo nginx -t && sudo systemctl reload nginx

   NOTE: This only makes sense if the istio-ingressgateway is also running
   on this node. By default it is pinned to the primary (nodeSelector
   shouldInstallIstioIngress=true). See step 3 below to enable it here.

─────────────────────────────────────────────────────────────────────────────
2. Verify node health (from the primary node)
─────────────────────────────────────────────────────────────────────────────
     kubectl get nodes -o wide
     kubectl describe node ${node_name}
     kubectl get pods -A -o wide | grep ${node_name}

─────────────────────────────────────────────────────────────────────────────
3. (OPTIONAL) Run istio-ingressgateway on this node too
─────────────────────────────────────────────────────────────────────────────
   WARNING: Without a pod anti-affinity / topology spread constraint on the
   ingress-gateway Deployment, adding this label can cause BOTH replicas
   (minReplicas=2) to land on the same node — which is not real HA.

   a) Edit the Istio operator config on the primary:
        automation/single-node/charts/istio-install/templates/operator.yaml

      Add under spec.components.ingressGateways[0].k8s:
          affinity:
            podAntiAffinity:
              preferredDuringSchedulingIgnoredDuringExecution:
                - weight: 100
                  podAffinityTerm:
                    topologyKey: kubernetes.io/hostname
                    labelSelector:
                      matchLabels:
                        istio: ingressgateway

   b) Re-apply the infra helmfile on the primary:
        cd automation/single-node
        helmfile -f helmfile-infra.yaml.gotmpl apply

   c) Label this node from the primary:
        kubectl label node ${node_name} shouldInstallIstioIngress=true

─────────────────────────────────────────────────────────────────────────────
4. NFS storage
─────────────────────────────────────────────────────────────────────────────
   The NFS server is on the primary (${primary_host}). This node already
   has 'nfs-common' installed so pods can mount PVCs from the 'nfs-csi'
   StorageClass. Nothing else to do on this node.

=============================================================================
This guide is saved to: ${guide_file}
=============================================================================
EOF
)
    echo ""
    echo "$guide"
    echo "$guide" > "$guide_file"
    chmod 644 "$guide_file"
}
