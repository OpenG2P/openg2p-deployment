#!/usr/bin/env bash
# =============================================================================
# Compute Node — Phase 1: host setup
# =============================================================================
# Steps:
#   C1.1  Resource prereq (16 vCPU, 64 GB RAM, 128 GB disk)
#   C1.2  apt basics + tools (kubectl, helm, istioctl, helmfile)
#   C1.3  ufw — K8s ports from private subnet + WG subnet
#   C1.4  inotify tuning + /etc/hosts (storage, RP)
#   C1.5  NFS client install and mount from storage node
#   C1.6  RKE2 server install (single control-plane, cluster-init)
#   C1.7  NFS CSI driver + default StorageClass nfs-csi
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────
# Tool installers (kubectl, helm, istioctl, helmfile)
# Adapted from single-node phase1.sh.
# ─────────────────────────────────────────────────────────────────────────

# Resilient download: follows redirects, FAILS on HTTP errors (not silently),
# RETRIES transient failures, and RESUMES partial transfers (-C -). Needed
# because some regions have slow/bursty links to dl.k8s.io / get.helm.sh and a
# plain `curl -sLO` dies mid-transfer with no error, leaving a truncated file.
robust_curl() {
    local url="$1" out="$2"
    curl -fSL \
        --retry 5 --retry-delay 3 --retry-all-errors \
        --continue-at - \
        --connect-timeout 20 --max-time 600 \
        -o "$out" "$url"
}

install_kubectl() {
    local version="${1:-v1.33.6}"
    if kubectl version --client &>/dev/null; then
        log_success "kubectl already installed."
        return 0
    fi
    log_info "Installing kubectl ${version}..."
    if ! robust_curl "https://dl.k8s.io/release/${version}/bin/linux/amd64/kubectl" kubectl; then
        log_error "Failed to download kubectl ${version} from dl.k8s.io" \
                  "curl exhausted its retries (slow/unstable link to the k8s CDN)" \
                  "Re-run this phase — the download resumes from where it stopped" \
                  "curl -fSL --retry 5 -C - -o kubectl https://dl.k8s.io/release/${version}/bin/linux/amd64/kubectl" \
                  ""
        exit 1
    fi
    install -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl
    # Verify the binary actually works — guards against a truncated download
    # slipping through.
    if ! kubectl version --client &>/dev/null; then
        log_error "kubectl installed but failed its self-check (truncated download?)" \
                  "/usr/local/bin/kubectl is not a working binary" \
                  "Re-run this phase to re-download; if it persists the node's link to dl.k8s.io is too slow" \
                  "kubectl version --client" \
                  ""
        exit 1
    fi
    log_success "kubectl ${version} installed."
}

install_helm() {
    local version="${1:-3.17.3}"
    if helm version &>/dev/null; then
        log_success "helm already installed."
        return 0
    fi
    log_info "Installing helm v${version}..."
    if ! robust_curl "https://get.helm.sh/helm-v${version}-linux-amd64.tar.gz" /tmp/helm.tar.gz; then
        log_error "Failed to download helm v${version} from get.helm.sh" "" \
                  "Re-run this phase — the download resumes" "" ""
        exit 1
    fi
    tar xzf /tmp/helm.tar.gz -C /tmp linux-amd64/helm
    install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
    rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
    log_success "helm v${version} installed."
}

install_istioctl() {
    local version="${1:-1.24.1}"
    if istioctl version --remote=false &>/dev/null; then
        log_success "istioctl already installed."
        return 0
    fi
    log_info "Installing istioctl ${version}..."
    pushd /tmp >/dev/null
    curl -sL https://istio.io/downloadIstio | ISTIO_VERSION="${version}" sh -
    install -m 0755 "istio-${version}/bin/istioctl" /usr/local/bin/istioctl
    rm -rf "istio-${version}"
    popd >/dev/null
    log_success "istioctl ${version} installed."
}

install_helmfile() {
    local version="${1:-1.1.0}"
    if helmfile version &>/dev/null; then
        log_success "helmfile already installed."
        return 0
    fi
    log_info "Installing helmfile v${version}..."
    if ! robust_curl "https://github.com/helmfile/helmfile/releases/download/v${version}/helmfile_${version}_linux_amd64.tar.gz" /tmp/helmfile.tar.gz; then
        log_error "Failed to download helmfile v${version} from github.com" "" \
                  "Re-run this phase — the download resumes" "" ""
        exit 1
    fi
    tar xzf /tmp/helmfile.tar.gz -C /tmp helmfile
    install -m 0755 /tmp/helmfile /usr/local/bin/helmfile
    rm -f /tmp/helmfile /tmp/helmfile.tar.gz
    log_success "helmfile v${version} installed."
}

# Resource/OS/network prereqs are covered by lib/shared/preflight.sh.

# ─────────────────────────────────────────────────────────────────────────
# C1.2  apt basics + tools
# ─────────────────────────────────────────────────────────────────────────
compute_install_tools() {
    local step="compute.phase1.tools"
    if skip_if_done "$step" "tools"; then return 0; fi

    log_step "C1.2" "Install apt basics and Kubernetes tooling"

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends \
        curl wget jq openssl dnsutils ca-certificates \
        apt-transport-https gnupg software-properties-common \
        ufw nfs-common

    install_kubectl   "v$(echo "$(cfg rke2_version v1.33.6+rke2r1)" | sed 's/+rke2r.*//;s/^v//')"
    install_helm      "3.17.3"
    install_istioctl  "1.24.1"
    install_helmfile  "1.1.0"

    if ! helm plugin list 2>/dev/null | grep -q '^diff'; then
        log_info "Installing helm-diff plugin v3.9.14..."
        helm plugin install https://github.com/databus23/helm-diff --version v3.9.14 \
            || log_warn "helm-diff install failed; helmfile may need --skip-diff-on-install."
    fi

    mark_step_done "$step"
}

# ─────────────────────────────────────────────────────────────────────────
# C1.3  ufw
# ─────────────────────────────────────────────────────────────────────────
compute_configure_ufw() {
    local step="compute.phase1.ufw"
    if skip_if_done "$step" "ufw rules"; then return 0; fi

    log_step "C1.3" "Configure ufw — K8s ports from private + WG subnets"

    local admin_cidr=$(cfg "admin_cidr" "0.0.0.0/0")
    local private_subnet=$(cfg "private_subnet")
    local wg_subnet=$(cfg "wg_subnet" "10.15.0.0/16")
    # Prefer rp_internal_ip (new key); fall back to rp_private_ip (legacy alias).
    local rp_internal_for_ufw=$(cfg "rp_internal_ip")
    if [[ -z "$rp_internal_for_ufw" ]]; then
        rp_internal_for_ufw=$(cfg "rp_private_ip")
    fi

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    # SSH from admin laptop (direct or via RP bastion via private subnet)
    ufw allow from "$admin_cidr" to any port 22 proto tcp
    ufw allow from "$private_subnet" to any port 22 proto tcp

    # Cluster-internal ports — allow from private subnet (covers single-node compute,
    # plus future worker nodes joining), and from WG subnet so admin laptops on VPN
    # can reach the K8s API directly.
    for cidr in "$private_subnet" "$wg_subnet"; do
        ufw allow from "$cidr" to any port 6443  proto tcp comment "K8s API"
        ufw allow from "$cidr" to any port 9345  proto tcp comment "RKE2 supervisor"
        ufw allow from "$cidr" to any port 10250 proto tcp comment "kubelet"
        ufw allow from "$cidr" to any port 2379  proto tcp comment "etcd client"
        ufw allow from "$cidr" to any port 2380  proto tcp comment "etcd peer"
        ufw allow from "$cidr" to any port 9796  proto tcp comment "node-exporter"
        ufw allow from "$cidr" to any port 8472  proto udp comment "VXLAN/CNI"
        ufw allow from "$cidr" to any port 30000:32767 proto tcp comment "NodePort"
        # ICMP is already permitted via ufw's default before.rules.
    done

    # Istio ingress NodePort 30080 from RP only (RP forwards public HTTPS to it)
    if [[ -n "$rp_internal_for_ufw" ]]; then
        ufw allow from "$rp_internal_for_ufw" to any port 30080 proto tcp comment "Istio ingress from RP"
    else
        log_warn "Neither rp_internal_ip nor rp_private_ip set; Istio NodePort 30080 not opened to RP."
    fi

    ufw --force enable

    mark_step_done "$step"
}

# ─────────────────────────────────────────────────────────────────────────
# C1.4  inotify tuning + /etc/hosts
# ─────────────────────────────────────────────────────────────────────────
compute_configure_sysctl_hosts() {
    local step="compute.phase1.sysctl-hosts"
    if skip_if_done "$step" "sysctl + /etc/hosts"; then return 0; fi

    log_step "C1.4" "inotify tuning and /etc/hosts entries"

    sysctl -w fs.inotify.max_user_watches=524288 >/dev/null
    sysctl -w fs.inotify.max_user_instances=1024 >/dev/null
    grep -q '^fs.inotify.max_user_watches' /etc/sysctl.conf || \
        echo "fs.inotify.max_user_watches=524288" >> /etc/sysctl.conf
    grep -q '^fs.inotify.max_user_instances' /etc/sysctl.conf || \
        echo "fs.inotify.max_user_instances=1024" >> /etc/sysctl.conf

    # Idempotent /etc/hosts edits — replace any prior managed block.
    # The customer admin hostnames (rancher, keycloak) resolve to the RP's INTERNAL IP so
    # that curl from this node (e.g. phase 3's API calls to Rancher) reaches
    # them via the RP's Nginx → Istio NodePort → cluster service path.
    # Cluster-internal references to storage/postgres use the raw private IP
    # directly (no aliases needed).
    local rp_internal=$(cfg "rp_internal_ip" "")
    if [[ -z "$rp_internal" ]]; then
        rp_internal=$(cfg "rp_private_ip" "")     # backward compat alias
    fi

    sed -i '/# openg2p-managed-begin/,/# openg2p-managed-end/d' /etc/hosts

    if [[ -n "$rp_internal" ]]; then
        local rancher_h=$(get_rancher_hostname)
        local keycloak_h=$(get_keycloak_hostname)
        {
            echo "# openg2p-managed-begin"
            for h in "$rancher_h" "$keycloak_h"; do
                [[ -n "$h" ]] && echo "${rp_internal}  ${h}"
            done
            echo "# openg2p-managed-end"
        } >> /etc/hosts
        log_info "Added /etc/hosts entries for admin hostnames → ${rp_internal}"
    fi

    mark_step_done "$step"
}

# ─────────────────────────────────────────────────────────────────────────
# C1.5  NFS client + mount
# ─────────────────────────────────────────────────────────────────────────
compute_configure_nfs_client() {
    local step="compute.phase1.nfs-client"
    if skip_if_done "$step" "NFS client mount"; then return 0; fi

    log_step "C1.5" "Mount NFS export from storage node"

    local cluster=$(cfg "cluster_name" "openg2p")
    local storage_ip=$(cfg "storage_private_ip")
    local export_root=$(cfg "nfs_export_path" "/srv/nfs")
    local mount_root=$(cfg "nfs_mount_path" "/mnt/nfs")
    local export_path="${export_root}/${cluster}"
    local mount_path="${mount_root}/${cluster}"

    mkdir -p "$mount_path"

    # Idempotent fstab — replace any prior openg2p line for this mount
    sed -i "\|${mount_path}|d" /etc/fstab
    echo "${storage_ip}:${export_path}  ${mount_path}  nfs  defaults,nofail,noatime,_netdev  0  0" >> /etc/fstab

    # Try the mount
    if mount -a 2>/dev/null; then
        log_success "NFS mounted: ${storage_ip}:${export_path} → ${mount_path}"
    else
        log_error "NFS mount failed" \
                  "The export from ${storage_ip} could not be mounted at ${mount_path}" \
                  "Verify storage node phase 1 is complete and NFS server is running" \
                  "showmount -e ${storage_ip}; journalctl -xe | tail -30"
        exit 1
    fi

    mark_step_done "$step"
}

# ─────────────────────────────────────────────────────────────────────────
# C1.6  RKE2 server install
# ─────────────────────────────────────────────────────────────────────────
compute_install_rke2() {
    local step="compute.phase1.rke2"
    if skip_if_done "$step" "RKE2 server"; then return 0; fi

    log_step "C1.6" "Install RKE2 single control-plane"

    local rke2_version=$(cfg "rke2_version" "v1.33.6+rke2r1")
    local node_name=$(cfg "compute_node_name" "compute-1")
    local node_ip=$(cfg "compute_private_ip")
    local token=$(cfg "rke2_token")
    if [[ -z "$token" ]]; then token="openg2p-$(openssl rand -hex 16)"; fi

    if systemctl is-active --quiet rke2-server 2>/dev/null; then
        log_info "RKE2 already running. Verifying kubectl access..."
        ensure_kubeconfig
        if kubectl get nodes &>/dev/null; then
            log_success "RKE2 OK."
            mark_step_done "$step"
            return 0
        fi
    fi

    mkdir -p /etc/rancher/rke2
    cat > /etc/rancher/rke2/config.yaml <<EOF
token: ${token}
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
    curl -sfL https://get.rke2.io | sh -

    systemctl enable rke2-server
    systemctl start rke2-server

    # Persist token for future add-node and kubeconfig pull
    mkdir -p /var/lib/openg2p/deploy-state
    echo "$token" > /var/lib/openg2p/deploy-state/rke2-token
    chmod 0600 /var/lib/openg2p/deploy-state/rke2-token

    ensure_kubeconfig

    cat > /etc/profile.d/openg2p-k8s.sh <<'EOF'
export PATH="$PATH:/var/lib/rancher/rke2/bin"
export KUBECONFIG="/etc/rancher/rke2/rke2.yaml"
EOF

    wait_for_command "K8s node Ready" \
        "kubectl get nodes | grep -w Ready" \
        300 10

    # Generate remote-access kubeconfig (private IP, not 127.0.0.1)
    local remote="/etc/rancher/rke2/rke2-remote.yaml"
    sed "s|https://127.0.0.1:6443|https://${node_ip}:6443|g" \
        /etc/rancher/rke2/rke2.yaml > "$remote"
    chmod 0600 "$remote"
    log_success "Remote kubeconfig at ${remote}"

    mark_step_done "$step"
}

# ─────────────────────────────────────────────────────────────────────────
# C1.7  NFS CSI driver + default StorageClass
# ─────────────────────────────────────────────────────────────────────────
compute_install_nfs_csi() {
    local step="compute.phase1.nfs-csi"
    if skip_if_done "$step" "NFS CSI driver"; then return 0; fi

    log_step "C1.7" "Install NFS CSI driver + default StorageClass nfs-csi"

    ensure_kubeconfig

    local cluster=$(cfg "cluster_name" "openg2p")
    local storage_ip=$(cfg "storage_private_ip")
    local export_root=$(cfg "nfs_export_path" "/srv/nfs")
    local export_path="${export_root}/${cluster}"

    if kubectl get storageclass nfs-csi &>/dev/null; then
        log_success "StorageClass nfs-csi already exists."
        mark_step_done "$step"
        return 0
    fi

    helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts >/dev/null
    helm repo update >/dev/null

    helm -n kube-system upgrade --install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
        --version v4.7.0 --wait

    cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
parameters:
  mountPermissions: "0777"
  server: ${storage_ip}
  share: ${export_path}
  subDir: '\${pvc.metadata.namespace}-\${pvc.metadata.name}-\${pv.metadata.name}'
provisioner: nfs.csi.k8s.io
reclaimPolicy: Retain
volumeBindingMode: Immediate
EOF

    log_success "StorageClass nfs-csi installed (server=${storage_ip}, share=${export_path})"

    mark_step_done "$step"
}

# ─────────────────────────────────────────────────────────────────────────
# Phase entry
# ─────────────────────────────────────────────────────────────────────────
run_compute_phase1() {
    compute_install_tools
    compute_configure_ufw
    compute_configure_sysctl_hosts
    compute_configure_nfs_client
    compute_install_rke2
    compute_install_nfs_csi
}
