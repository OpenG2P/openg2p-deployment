#!/usr/bin/env bash
# =============================================================================
# OpenG2P 3-Node Production — SSH / orchestration helpers
# =============================================================================
# Sourced by openg2p-prod.sh on the admin's laptop.
#
# Responsibilities:
#   • Resolve (user, host, key) per role from config
#   • Multiplexed SSH via ControlMaster for fast repeated commands
#   • Push role scripts + config to remote nodes via rsync
#   • Run scripts remotely under sudo
#   • Pull artifacts (CA cert, kubeconfig, peer config) back to the laptop
# =============================================================================

# Where SSH ControlMaster sockets live on the laptop.
SSH_CTRL_DIR="${SSH_CTRL_DIR:-${HOME}/.ssh/openg2p-ctrl}"

# Where remote scripts and config land on each node.
REMOTE_WORK_DIR="/tmp/openg2p-deploy"

# Where artifacts pulled back from the cluster land on the laptop.
LAPTOP_ARTIFACT_DIR="${LAPTOP_ARTIFACT_DIR:-./artifacts}"

# ---------------------------------------------------------------------------
# Role resolution
# ---------------------------------------------------------------------------
# Echoes "user|host|keyfile" for the given role.
ssh_resolve_role() {
    local role="$1"
    local user host key

    case "$role" in
        rp)
            user=$(cfg "rp_ssh_user" "ubuntu")
            host=$(cfg "rp_ssh_host")
            if [[ -z "$host" ]]; then host=$(cfg "rp_public_ip"); fi
            key=$(cfg "rp_ssh_key" "~/.ssh/id_rsa")
            ;;
        compute)
            user=$(cfg "compute_ssh_user" "ubuntu")
            host=$(cfg "compute_ssh_host")
            if [[ -z "$host" ]]; then host=$(cfg "compute_private_ip"); fi
            key=$(cfg "compute_ssh_key" "~/.ssh/id_rsa")
            ;;
        storage)
            user=$(cfg "storage_ssh_user" "ubuntu")
            host=$(cfg "storage_ssh_host")
            if [[ -z "$host" ]]; then host=$(cfg "storage_private_ip"); fi
            key=$(cfg "storage_ssh_key" "~/.ssh/id_rsa")
            ;;
        *)
            log_error "Unknown role: '${role}'" \
                      "Expected one of: rp, compute, storage" \
                      "Check the --role argument"
            return 1
            ;;
    esac

    if [[ -z "$host" ]]; then
        log_error "No SSH host resolved for role '${role}'" \
                  "Both *_ssh_host and the corresponding *_ip are blank in your config" \
                  "Set either ${role}_ssh_host or the IP field for that role"
        return 1
    fi

    # Expand ~ in key path
    key="${key/#\~/$HOME}"

    echo "${user}|${host}|${key}"
}

# ---------------------------------------------------------------------------
# SSH option builder
# ---------------------------------------------------------------------------
# Echoes the ssh -o options needed for ControlMaster + (optional) ProxyJump.
ssh_options_for() {
    local role="$1"

    # Host key checking is disabled — we just provisioned these VMs ourselves
    # and the AWS API attests their identity. Trying to track host keys for
    # ephemeral cloud VMs and have them propagate through ProxyJump's inner
    # ssh causes interactive prompts in practice. Trade-off: a MITM during
    # initial connection wouldn't be caught — acceptable inside your own VPC.
    local opts=(
        -o "ControlMaster=auto"
        -o "ControlPath=${SSH_CTRL_DIR}/%r@%h:%p"
        -o "ControlPersist=300"
        -o "StrictHostKeyChecking=no"
        -o "UserKnownHostsFile=/dev/null"
        -o "LogLevel=ERROR"
        -o "ServerAliveInterval=30"
        -o "ServerAliveCountMax=3"
    )

    # Bastion: if ssh_jump_via_rp is set, route compute/storage through RP.
    if [[ "$role" != "rp" ]] && cfg_bool "ssh_jump_via_rp"; then
        local rp_resolved
        rp_resolved=$(ssh_resolve_role "rp") || return 1
        local rp_user="${rp_resolved%%|*}"
        local rp_rest="${rp_resolved#*|}"
        local rp_host="${rp_rest%%|*}"
        local rp_key="${rp_rest##*|}"

        opts+=(-o "ProxyJump=${rp_user}@${rp_host}")
        # Make sure the jump SSH knows the key — set IdentityFile via env
        opts+=(-o "IdentityFile=${rp_key}")
    fi

    printf '%s\n' "${opts[@]}"
}

# ---------------------------------------------------------------------------
# Init / cleanup
# ---------------------------------------------------------------------------
ssh_init() {
    mkdir -p "$SSH_CTRL_DIR"
    chmod 700 "$SSH_CTRL_DIR"
    mkdir -p "$LAPTOP_ARTIFACT_DIR"
}

ssh_cleanup() {
    ssh_k8s_tunnel_close 2>/dev/null || true
    # Close all ControlMaster sockets cleanly.
    for sock in "${SSH_CTRL_DIR}"/*; do
        [[ -S "$sock" ]] || continue
        local target
        target=$(basename "$sock")
        ssh -o "ControlPath=${sock}" -O exit "${target}" 2>/dev/null || true
    done
    for sock in "${SSH_CTRL_DIR}/k8s-tunnel/"*; do
        [[ -e "$sock" ]] || continue
        [[ -S "$sock" ]] || continue
        ssh -o "ControlPath=${sock}" -O exit unused 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# Kubernetes API access via SSH tunnel (no Wireguard required)
# ---------------------------------------------------------------------------
# The RKE2 API listens on compute's loopback (127.0.0.1:6443). The laptop
# already has SSH to compute's public IP (same path as infra install). Open a
# LocalForward and rewrite kubeconfig to https://127.0.0.1:<local_port> so
# kubectl/helm work during environment install without Wireguard.
#
# Globals set: K8S_TUNNEL_PORT, K8S_TUNNEL_PID, K8S_TUNNEL_CTRL
K8S_TUNNEL_PORT=""
K8S_TUNNEL_PID=""
K8S_TUNNEL_CTRL=""

ssh_k8s_tunnel_pick_port() {
    local port
    for port in $(seq 16443 16543); do
        if ! (echo >/dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1; then
            echo "$port"
            return 0
        fi
    done
    # Fallback — OS may still bind successfully.
    echo "16443"
}

# ssh_k8s_tunnel_open <kubeconfig_path>
# Pulls /etc/rancher/rke2/rke2.yaml, opens SSH -L to compute:6443, rewrites
# the kubeconfig server URL to the local tunnel port, exports KUBECONFIG.
# Safe to call again (closes any prior tunnel first). No Wireguard needed.
ssh_k8s_tunnel_open() {
    local kubeconfig="${1:?kubeconfig path required}"
    local resolved user host key
    local ctrl_path local_port

    ssh_k8s_tunnel_close 2>/dev/null || true

    resolved=$(ssh_resolve_role "compute") || return 1
    user="${resolved%%|*}"
    local rest="${resolved#*|}"
    host="${rest%%|*}"
    key="${rest##*|}"

    # Dedicated options — do NOT reuse ssh_options_for ControlMaster path, or
    # LocalForward would share a socket with unrelated ssh_run sessions.
    local -a tun_opts=(
        -o "StrictHostKeyChecking=no"
        -o "UserKnownHostsFile=/dev/null"
        -o "LogLevel=ERROR"
        -o "ServerAliveInterval=30"
        -o "ServerAliveCountMax=3"
        -o "ExitOnForwardFailure=yes"
    )
    if cfg_bool "ssh_jump_via_rp"; then
        local rp_resolved rp_user rp_host rp_key rp_rest
        rp_resolved=$(ssh_resolve_role "rp") || return 1
        rp_user="${rp_resolved%%|*}"
        rp_rest="${rp_resolved#*|}"
        rp_host="${rp_rest%%|*}"
        rp_key="${rp_rest##*|}"
        tun_opts+=(-o "ProxyJump=${rp_user}@${rp_host}" -o "IdentityFile=${rp_key}")
    fi

    mkdir -p "$(dirname "$kubeconfig")"
    log_info "Fetching RKE2 kubeconfig from compute via SSH..."
    local raw
    raw=$(ssh_run compute "sudo cat /etc/rancher/rke2/rke2.yaml" 2>/dev/null) || {
        log_error "Could not read /etc/rancher/rke2/rke2.yaml from compute" \
                  "SSH to compute succeeded earlier but kubeconfig is missing" \
                  "Check that RKE2 is installed: ssh compute 'sudo ls /etc/rancher/rke2/'"
        return 1
    }
    printf '%s\n' "$raw" > "$kubeconfig"
    chmod 0600 "$kubeconfig"

    local_port=$(ssh_k8s_tunnel_pick_port)
    mkdir -p "${SSH_CTRL_DIR}/k8s-tunnel"
    chmod 700 "${SSH_CTRL_DIR}/k8s-tunnel"
    ctrl_path="${SSH_CTRL_DIR}/k8s-tunnel/${user}@${host}:22"

    log_info "Opening SSH tunnel to Kubernetes API: localhost:${local_port} → compute:127.0.0.1:6443"

    ssh -f -N \
        -i "$key" \
        "${tun_opts[@]}" \
        -o "ControlMaster=yes" \
        -o "ControlPath=${ctrl_path}" \
        -o "ControlPersist=yes" \
        -L "${local_port}:127.0.0.1:6443" \
        "${user}@${host}" || {
        log_error "Failed to open SSH tunnel to the Kubernetes API on compute" \
                  "Could not bind LocalForward ${local_port} → 127.0.0.1:6443" \
                  "Check SSH to compute and that nothing blocks the forward"
        return 1
    }

    sed -E -i \
        "s#server: https://127\\.0\\.0\\.1:6443#server: https://127.0.0.1:${local_port}#g" \
        "$kubeconfig"
    local compute_priv
    compute_priv=$(cfg compute_private_ip 2>/dev/null || true)
    if [[ -n "$compute_priv" ]]; then
        sed -E -i \
            "s#server: https://${compute_priv}:6443#server: https://127.0.0.1:${local_port}#g" \
            "$kubeconfig"
    fi

    K8S_TUNNEL_PORT="$local_port"
    K8S_TUNNEL_CTRL="$ctrl_path"
    export KUBECONFIG="$kubeconfig"

    local waited=0
    while (( waited < 30 )); do
        if kubectl --kubeconfig "$kubeconfig" cluster-info >/dev/null 2>&1; then
            log_success "Kubernetes API reachable via SSH tunnel (localhost:${local_port})."
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    log_error "Kubernetes API not reachable through the SSH tunnel" \
              "Tunnel opened on localhost:${local_port} but kubectl cluster-info still fails" \
              "Check RKE2 is running on compute: ssh compute 'sudo systemctl status rke2-server'"
    ssh_k8s_tunnel_close 2>/dev/null || true
    return 1
}

ssh_k8s_tunnel_close() {
    if [[ -n "${K8S_TUNNEL_CTRL:-}" && -S "${K8S_TUNNEL_CTRL}" ]]; then
        ssh -o "ControlPath=${K8S_TUNNEL_CTRL}" -O exit unused 2>/dev/null || true
    fi
    local sock
    for sock in "${SSH_CTRL_DIR}/k8s-tunnel/"*; do
        [[ -e "$sock" ]] || continue
        [[ -S "$sock" ]] || continue
        ssh -o "ControlPath=${sock}" -O exit unused 2>/dev/null || true
    done
    K8S_TUNNEL_PORT=""
    K8S_TUNNEL_PID=""
    K8S_TUNNEL_CTRL=""
}

# ---------------------------------------------------------------------------
# Probe — verify SSH works for a role before doing anything.
# ---------------------------------------------------------------------------
ssh_probe() {
    local role="$1"
    local resolved
    resolved=$(ssh_resolve_role "$role") || return 1
    local user="${resolved%%|*}"
    local rest="${resolved#*|}"
    local host="${rest%%|*}"
    local key="${rest##*|}"

    log_info "SSH probe: ${role} → ${user}@${host}"

    local opts
    mapfile -t opts < <(ssh_options_for "$role")

    # Debug: print the exact ssh command we're about to run so any host /
    # ProxyJump / option discrepancy is visible.
    if [[ "${SSH_DEBUG:-0}" == "1" ]]; then
        log_info "  cmd: ssh -i ${key} ${opts[*]} -o BatchMode=yes -o ConnectTimeout=10 ${user}@${host} true" >&2
    fi

    # Show real ssh errors — don't squelch stderr.
    local ssh_err
    if ! ssh_err=$(ssh -i "$key" "${opts[@]}" \
            -o "BatchMode=yes" -o "ConnectTimeout=10" \
            "${user}@${host}" "true" 2>&1); then
        log_error "SSH connection failed: ${user}@${host}" \
                  "Cannot connect to the ${role} node" \
                  "ssh said: ${ssh_err}" \
                  "ssh -i ${key} ${user}@${host}"
        return 1
    fi

    # Verify passwordless sudo
    if ! ssh_err=$(ssh -i "$key" "${opts[@]}" -o "BatchMode=yes" \
             "${user}@${host}" "sudo -n true" 2>&1); then
        log_error "Passwordless sudo not available for ${user}@${host}" \
                  "The user must have NOPASSWD:ALL in sudoers (or run as root)" \
                  "ssh said: ${ssh_err}" \
                  "echo '${user} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/openg2p"
        return 1
    fi

    log_success "SSH + sudo OK on ${role}."
}

# ---------------------------------------------------------------------------
# Remote command execution
# ---------------------------------------------------------------------------
# ssh_run <role> <command...>
# Runs the command on the remote node under sudo. Streams stdout/stderr.
ssh_run() {
    local role="$1"; shift
    local resolved
    resolved=$(ssh_resolve_role "$role") || return 1
    local user="${resolved%%|*}"
    local rest="${resolved#*|}"
    local host="${rest%%|*}"
    local key="${rest##*|}"

    local opts
    mapfile -t opts < <(ssh_options_for "$role")

    # Non-login bash (--noprofile --norc -c): login shells source ~/.bash_logout,
    # where Ubuntu's clear_console returns non-zero without a TTY. If the remote
    # script used 'set -e', that logout failure overrides a successful 'exit 0'
    # and ssh_run returns 1 after printing good stdout — which then aborts
    # callers under set -e / pipefail (e.g. rancher_restore nfs_root=...).
    #
    # PATH is extended explicitly since we skip profile.
    # -n + </dev/null: never let ssh steal the caller's stdin (heredocs /
    # command-substitution pipelines).
    ssh -n -i "$key" "${opts[@]}" "${user}@${host}" \
        "sudo -E env TERM=dumb PATH=\"\$PATH:/var/lib/rancher/rke2/bin:/usr/local/bin:/usr/local/sbin\" \
         bash --noprofile --norc -c $(printf '%q' "$*")" </dev/null
}

# ssh_run_raw <role> <command...>
# Runs WITHOUT sudo (e.g. for sudo -n probe, or ad-hoc reads).
ssh_run_raw() {
    local role="$1"; shift
    local resolved
    resolved=$(ssh_resolve_role "$role") || return 1
    local user="${resolved%%|*}"
    local rest="${resolved#*|}"
    local host="${rest%%|*}"
    local key="${rest##*|}"

    local opts
    mapfile -t opts < <(ssh_options_for "$role")

    ssh -i "$key" "${opts[@]}" "${user}@${host}" "$*"
}

# ---------------------------------------------------------------------------
# File push — uses rsync over the ControlMaster connection.
# ---------------------------------------------------------------------------
# ssh_push <role> <local_src> <remote_dest>
# remote_dest is an absolute path on the remote node.
ssh_push() {
    local role="$1"; local src="$2"; local dest="$3"
    local resolved
    resolved=$(ssh_resolve_role "$role") || return 1
    local user="${resolved%%|*}"
    local rest="${resolved#*|}"
    local host="${rest%%|*}"
    local key="${rest##*|}"

    local opts
    mapfile -t opts < <(ssh_options_for "$role")

    # Make sure the remote dir exists and is owned by the SSH user.
    # We create the destination itself (not its parent) — `dirname` on a
    # trailing-slash path like /tmp/openg2p-deploy/ returns /tmp, and the
    # SSH user can't chmod root-owned /tmp.
    local dest_clean="${dest%/}"
    ssh -i "$key" "${opts[@]}" "${user}@${host}" \
        "mkdir -p $(printf '%q' "$dest_clean") && chmod 0755 $(printf '%q' "$dest_clean")" >/dev/null

    local rsync_ssh="ssh -i ${key}"
    for o in "${opts[@]}"; do
        rsync_ssh="${rsync_ssh} ${o}"
    done

    rsync -az --delete \
        -e "$rsync_ssh" \
        "$src" \
        "${user}@${host}:${dest}"
}

# ssh_push_file <role> <local_file> <remote_file>
# Upload a single file to an absolute path on the remote node.
# (ssh_run deliberately ignores stdin — use this instead of piping into ssh_run.)
ssh_push_file() {
    local role="$1" local_file="$2" remote_file="$3"
    local resolved
    resolved=$(ssh_resolve_role "$role") || return 1
    local user="${resolved%%|*}"
    local rest="${resolved#*|}"
    local host="${rest%%|*}"
    local key="${rest##*|}"

    local opts
    mapfile -t opts < <(ssh_options_for "$role")

    local remote_dir
    remote_dir="$(dirname "$remote_file")"
    ssh -i "$key" "${opts[@]}" "${user}@${host}" \
        "mkdir -p $(printf '%q' "$remote_dir")" >/dev/null

    local rsync_ssh="ssh -i ${key}"
    for o in "${opts[@]}"; do
        rsync_ssh="${rsync_ssh} ${o}"
    done

    rsync -az \
        -e "$rsync_ssh" \
        "$local_file" \
        "${user}@${host}:${remote_file}"
}

# ---------------------------------------------------------------------------
# File pull — copy a remote file to a laptop artifact path.
# ---------------------------------------------------------------------------
# ssh_pull <role> <remote_src> <local_dest>
# Reads via sudo (so root-owned files work) and streams to the laptop.
ssh_pull() {
    local role="$1"; local src="$2"; local dest="$3"
    local resolved
    resolved=$(ssh_resolve_role "$role") || return 1
    local user="${resolved%%|*}"
    local rest="${resolved#*|}"
    local host="${rest%%|*}"
    local key="${rest##*|}"

    local opts
    mapfile -t opts < <(ssh_options_for "$role")

    mkdir -p "$(dirname "$dest")"

    ssh -i "$key" "${opts[@]}" "${user}@${host}" \
        "sudo cat $(printf '%q' "$src")" > "$dest"
}

# ---------------------------------------------------------------------------
# Merge prod-config + provision-output (+ laptop-resolved overrides) for remote.
# ---------------------------------------------------------------------------
# Remote nodes (preflight + role scripts) only see prod-config.yaml — they do
# NOT load provision-output.yaml separately. This helper builds the same
# effective config the laptop orchestrator uses, including legacy-key
# promotion (rp_internal_ip → rp_private_ip) already applied to CONFIG.
write_merged_prod_config() {
    local dest="$1"
    local config_file="$2"
    local provision_output="${3:-}"

    if [[ -z "$provision_output" || ! -f "$provision_output" ]]; then
        provision_output="$(dirname "$config_file")/provision-output.yaml"
    fi

    cat "$config_file" > "$dest"

    if [[ -f "$provision_output" ]]; then
        {
            echo ""
            echo "# ─── merged from provision-output.yaml ───"
            cat "$provision_output"
        } >> "$dest"
    fi

    # Last-wins overlay: guarantees remote preflight/roles see the laptop's
    # effective values even when prod-config placeholders (key: "") confused
    # the parser or provision-output was not found on the first merge pass.
    local -a overlay_keys=(
        rp_public_ip rp_private_ip rp_internal_ip
        rp_ssh_host rp_ssh_user rp_ssh_key
        compute_private_ip compute_ssh_host compute_ssh_user compute_ssh_key
        storage_private_ip storage_ssh_host storage_ssh_user storage_ssh_key
        private_subnet admin_cidr wg_endpoint wg_port wg_peer_dns
    )
    local wrote_overlay=false key val
    for key in "${overlay_keys[@]}"; do
        val="$(cfg "$key" 2>/dev/null || true)"
        [[ -z "$val" ]] && continue
        if [[ "$wrote_overlay" == "false" ]]; then
            {
                echo ""
                echo "# ─── orchestrator-resolved overrides (laptop effective config) ───"
            } >> "$dest"
            wrote_overlay=true
        fi
        printf '%s: "%s"\n' "$key" "$val" >> "$dest"
    done
}

# ---------------------------------------------------------------------------
# Stage role bundle — push lib/shared/, role dir, and the config to remote.
# ---------------------------------------------------------------------------
# ssh_stage_role <role> <repo_root> <config_file> [provision_output]
# If provision_output is provided AND exists, it's appended to the staged
# prod-config.yaml so its keys override prod-config.yaml on the remote node.
#
# For role=rp, also gathers customer cert files (referenced by tls_* keys
# in prod-config.yaml) into stage/certs/, where RP phase 1 picks them up.
ssh_stage_role() {
    local role="$1"
    local repo_root="$2"
    local config_file="$3"
    local provision_output="${4:-}"

    log_info "Staging role bundle '${role}' on remote..."

    local stage
    stage=$(mktemp -d -t openg2p-stage.XXXXXX)
    trap "rm -rf '$stage'" RETURN

    # The orchestrator uses short role names (rp / compute / storage) but
    # the directory for the reverse-proxy role is named "reverse-proxy/".
    local role_dir="$role"
    if [[ "$role" == "rp" ]]; then role_dir="reverse-proxy"; fi

    mkdir -p "${stage}/lib"
    cp -r "${repo_root}/lib/shared" "${stage}/lib/shared"
    cp -r "${repo_root}/roles/${role_dir}" "${stage}/role"
    cp -r "${repo_root}/charts" "${stage}/charts"
    [[ -f "${repo_root}/helmfile-infra.yaml.gotmpl" ]] && \
        cp "${repo_root}/helmfile-infra.yaml.gotmpl" "${stage}/helmfile-infra.yaml.gotmpl"

    # For RP, gather customer cert files into stage/certs/. RP phase 1
    # reads from ${WORK_DIR}/certs/{wildcard,rancher,keycloak,...}.{cert,key,chain}.
    if [[ "$role" == "rp" ]]; then
        _stage_customer_certs "$config_file" "${stage}/certs"
    fi

    # Merge prod-config + provision-output + laptop-resolved overrides.
    write_merged_prod_config "${stage}/prod-config.yaml" "$config_file" "$provision_output"

    ssh_push "$role" "${stage}/" "${REMOTE_WORK_DIR}/"

    log_success "Staged ${role} bundle at ${REMOTE_WORK_DIR}/ on remote."
}

# Internal helper — read tls_* paths from prod-config.yaml and copy the
# referenced cert files into stage_certs_dir under stable names.
_stage_customer_certs() {
    local config_file="$1"
    local out_dir="$2"
    mkdir -p "$out_dir"

    local config_dir
    config_dir=$(cd "$(dirname "$config_file")" && pwd)

    # Read tls_* keys from the config file directly (we're on the laptop;
    # cfg() requires load_config which the caller may not have done yet).
    _read_tls_key() {
        local key="$1"
        grep -E "^${key}:[[:space:]]" "$config_file" 2>/dev/null \
            | head -1 \
            | sed -E 's/^[^:]+:[[:space:]]*"?([^"]*)"?[[:space:]]*(#.*)?$/\1/'
    }

    _resolve_path() {
        local p="$1"
        [[ -z "$p" ]] && { echo ""; return; }
        # Tilde expand
        p="${p/#\~\//${HOME}/}"
        # Relative paths resolve against config file's dir
        if [[ "$p" != /* ]]; then
            p="${config_dir}/${p}"
        fi
        echo "$p"
    }

    _copy_if_present() {
        local src="$1" dest="$2" label="$3" kind="${4:-cert}"   # kind: cert|key|chain
        [[ -z "$src" ]] && return 0
        if [[ ! -f "$src" ]]; then
            log_error "${label} file not found: ${src}" \
                      "Path resolved from prod-config.yaml does not exist" \
                      "Check the path is correct and readable" \
                      "ls -la ${src}" \
                      "https://docs.openg2p.org/operations/deployment/automation/three-node-automation#id-4.-customer-supplied-tls-certificates"
            return 1
        fi

        # Reject PFX/P12 — not supported in v1 (PEM only).
        case "${src,,}" in
            *.pfx|*.p12)
                log_error "${label}: PFX/P12 not supported yet (${src})" \
                          "Customer-supplied PFX support is deferred to a follow-up" \
                          "Convert to PEM with: openssl pkcs12 -in ${src} -nocerts -nodes -out key.pem && openssl pkcs12 -in ${src} -clcerts -nokeys -out cert.pem && openssl pkcs12 -in ${src} -cacerts -nokeys -out chain.pem" \
                          "" \
                          "https://docs.openg2p.org/operations/deployment/automation/three-node-automation#id-4.-customer-supplied-tls-certificates"
                return 1
                ;;
            *.zip)
                log_error "${label}: ZIP bundle not supported yet (${src})" \
                          "Extract the bundle, then point to the PEM files directly" \
                          "unzip ${src} -d ./certs/" \
                          "" \
                          "https://docs.openg2p.org/operations/deployment/automation/three-node-automation#id-4.-customer-supplied-tls-certificates"
                return 1
                ;;
        esac

        # Verify PEM-looking content. Certs and chains must have BEGIN
        # CERTIFICATE; keys must have BEGIN ... PRIVATE KEY.
        case "$kind" in
            cert|chain)
                if ! grep -q -- '-----BEGIN CERTIFICATE-----' "$src" 2>/dev/null; then
                    log_error "${label} is not a PEM certificate: ${src}" \
                              "No '-----BEGIN CERTIFICATE-----' line found" \
                              "Verify the file is PEM-format (not DER, not corrupted)" \
                              "head -3 ${src}" \
                              "https://docs.openg2p.org/operations/deployment/automation/three-node-automation#id-4.-customer-supplied-tls-certificates"
                    return 1
                fi
                ;;
            key)
                if ! grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$src" 2>/dev/null; then
                    log_error "${label} is not a PEM private key: ${src}" \
                              "No '-----BEGIN PRIVATE KEY-----' / 'RSA PRIVATE KEY' line found" \
                              "Verify the file is an unencrypted PEM private key" \
                              "head -3 ${src}" \
                              "https://docs.openg2p.org/operations/deployment/automation/three-node-automation#id-4.-customer-supplied-tls-certificates"
                    return 1
                fi
                ;;
        esac

        # Copy, normalising CRLF → LF (Windows-exported certs often have CRLF
        # which openssl on Linux tolerates but some tools choke on).
        tr -d '\r' < "$src" > "$dest"
        chmod 0644 "$dest"
        log_info "  staged: ${label} ← ${src}"
    }

    local wc wk
    wc=$(_resolve_path "$(_read_tls_key tls_wildcard_cert)")
    wk=$(_resolve_path "$(_read_tls_key tls_wildcard_key)")

    if [[ -n "$wc" || -n "$wk" ]]; then
        log_info "Staging customer wildcard cert..."
        _copy_if_present "$wc" "${out_dir}/wildcard.cert" "wildcard cert" cert || return 1
        _copy_if_present "$wk" "${out_dir}/wildcard.key"  "wildcard key"  key  || return 1
        # Optional chain
        local wch
        wch=$(_resolve_path "$(_read_tls_key tls_wildcard_chain)")
        if [[ -n "$wch" ]]; then
            _copy_if_present "$wch" "${out_dir}/wildcard.chain" "wildcard chain" chain || return 1
        fi
    else
        log_info "Staging per-FQDN customer certs..."
        local svc cert key chain
        for svc in rancher; do
            cert=$(_resolve_path "$(_read_tls_key "tls_${svc}_cert")")
            key=$(_resolve_path  "$(_read_tls_key "tls_${svc}_key")")
            chain=$(_resolve_path "$(_read_tls_key "tls_${svc}_chain")")
            if [[ -z "$cert" || -z "$key" ]]; then
                log_error "Missing cert/key for ${svc}" \
                          "Neither tls_wildcard_* nor tls_${svc}_{cert,key} set" \
                          "Fill in either the wildcard or per-service cert paths in prod-config.yaml" \
                          "" \
                          "https://docs.openg2p.org/operations/deployment/automation/three-node-automation#id-4.-customer-supplied-tls-certificates"
                return 1
            fi
            _copy_if_present "$cert"  "${out_dir}/${svc}.cert"  "${svc} cert"  cert || return 1
            _copy_if_present "$key"   "${out_dir}/${svc}.key"   "${svc} key"   key  || return 1
            if [[ -n "$chain" ]]; then
                _copy_if_present "$chain" "${out_dir}/${svc}.chain" "${svc} chain" chain || return 1
            fi
        done
    fi
}

# ---------------------------------------------------------------------------
# Run a role's entry script remotely.
# ---------------------------------------------------------------------------
# ssh_run_role <role> [extra args...]
ssh_run_role() {
    local role="$1"; shift
    log_info "Running ${role}/run.sh on remote (args: $*)"
    ssh_run "$role" "cd ${REMOTE_WORK_DIR} && bash role/run.sh --config prod-config.yaml $*"
}
