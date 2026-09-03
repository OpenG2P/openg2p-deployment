#!/usr/bin/env bash
# =============================================================================
# OpenG2P Sandbox — SSH / orchestration helpers
# =============================================================================
# Sourced by openg2p-sandbox.sh on the admin's laptop.
#
# ControlMaster SSH (when supported), sudo -E, and rsync staging for a single
# Ubuntu node. Role name is always "node".
#
# SSH endpoint keys (from provision-output.yaml or sandbox-config.yaml):
#   ssh_host / ssh_user / ssh_key
# Fallbacks: public_ip, wireguard.endpoint for host.
#
# SSH multiplexing (ControlMaster) is enabled on Linux/macOS/WSL2. On Git Bash
# (MINGW/MSYS) it is disabled automatically — Unix-domain control sockets are
# unreliable there. Force either mode with OPENG2P_SSH_NO_MUX=1|0.
# =============================================================================

SSH_CTRL_DIR="${SSH_CTRL_DIR:-${HOME}/.ssh/openg2p-sandbox-ctrl}"
REMOTE_WORK_DIR="/tmp/openg2p-deploy"
LAPTOP_ARTIFACT_DIR="${LAPTOP_ARTIFACT_DIR:-./artifacts}"
_SSH_MUX_WARNED=false

# ---------------------------------------------------------------------------
# SSH multiplexing — off on Git Bash / when OPENG2P_SSH_NO_MUX=1
# ---------------------------------------------------------------------------
ssh_mux_enabled() {
    case "${OPENG2P_SSH_NO_MUX:-}" in
        1|true|TRUE|yes|YES) return 1 ;;
        0|false|FALSE|no|NO) return 0 ;;
    esac
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) return 1 ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Role resolution — single node only
# ---------------------------------------------------------------------------
# Echoes "user|host|keyfile".
ssh_resolve_role() {
    local role="${1:-node}"
    if [[ "$role" != "node" ]]; then
        log_error "Unknown role: '${role}'" \
                  "Single-node orchestrator only supports role 'node'" \
                  "Omit --role or pass --role node"
        return 1
    fi

    local user host key
    user=$(cfg "ssh_user" "ubuntu")
    host=$(cfg "ssh_host")
    if [[ -z "$host" ]]; then host=$(cfg "public_ip"); fi
    if [[ -z "$host" ]]; then host=$(cfg "wireguard.endpoint"); fi
    if [[ -z "$host" ]]; then host=$(cfg "wg_endpoint"); fi
    key=$(cfg "ssh_key" "")

    if [[ -z "$host" ]]; then
        log_error "No SSH host resolved" \
                  "ssh_host / public_ip / wireguard.endpoint are all blank" \
                  "Run aws/openg2p-aws-provision.sh first, or set ssh_host in sandbox-config.yaml" \
                  "Check provision-output.yaml next to your config"
        return 1
    fi

    if [[ -z "$key" ]]; then
        log_error "No SSH key path resolved" \
                  "ssh_key is blank in config / provision-output.yaml" \
                  "Set ssh_key to your .pem path (e.g. ./aws/keys/openg2p-sandbox.pem)"
        return 1
    fi

    # Expand ~ ; resolve relative paths against SCRIPT_DIR when available
    key="${key/#\~/$HOME}"
    if [[ "$key" != /* && -n "${SCRIPT_DIR:-}" ]]; then
        key="${SCRIPT_DIR}/${key}"
    fi
    if [[ ! -f "$key" ]]; then
        log_error "SSH key file not found: ${key}" \
                  "ssh_key does not point to a readable .pem" \
                  "Fix ssh_key in provision-output.yaml or sandbox-config.yaml" \
                  "ls -la ${key}"
        return 1
    fi

    echo "${user}|${host}|${key}"
}

ssh_options_for() {
    local _role="${1:-node}"
    local opts=(
        -o "StrictHostKeyChecking=no"
        -o "UserKnownHostsFile=/dev/null"
        -o "LogLevel=ERROR"
        -o "ServerAliveInterval=30"
        -o "ServerAliveCountMax=3"
    )
    if ssh_mux_enabled; then
        opts+=(
            -o "ControlMaster=auto"
            -o "ControlPath=${SSH_CTRL_DIR}/%r@%h:%p"
            -o "ControlPersist=300"
        )
    else
        opts+=(-o "ControlMaster=no")
    fi
    printf '%s\n' "${opts[@]}"
}

ssh_init() {
    mkdir -p "$LAPTOP_ARTIFACT_DIR"
    if ssh_mux_enabled; then
        mkdir -p "$SSH_CTRL_DIR"
        chmod 700 "$SSH_CTRL_DIR"
    else
        if [[ "$_SSH_MUX_WARNED" != "true" ]]; then
            log_info "SSH multiplexing disabled (Git Bash / OPENG2P_SSH_NO_MUX) — using direct SSH."
            _SSH_MUX_WARNED=true
        fi
    fi
}

ssh_cleanup() {
    ssh_mux_enabled || return 0
    for sock in "${SSH_CTRL_DIR}"/*; do
        [[ -S "$sock" ]] || continue
        local target
        target=$(basename "$sock")
        ssh -o "ControlPath=${sock}" -O exit "${target}" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
ssh_probe() {
    local role="${1:-node}"
    local resolved
    resolved=$(ssh_resolve_role "$role") || return 1
    local user="${resolved%%|*}"
    local rest="${resolved#*|}"
    local host="${rest%%|*}"
    local key="${rest##*|}"

    log_info "SSH probe: ${role} → ${user}@${host}"

    local opts
    mapfile -t opts < <(ssh_options_for "$role")

    local ssh_err
    if ! ssh_err=$(ssh -i "$key" "${opts[@]}" \
            -o "BatchMode=yes" -o "ConnectTimeout=10" \
            "${user}@${host}" "true" 2>&1); then
        log_error "SSH connection failed: ${user}@${host}" \
                  "Cannot connect to the sandbox VM" \
                  "ssh said: ${ssh_err}" \
                  "ssh -i ${key} ${user}@${host}"
        return 1
    fi

    if ! ssh_err=$(ssh -i "$key" "${opts[@]}" -o "BatchMode=yes" \
             "${user}@${host}" "sudo -n true" 2>&1); then
        log_error "Passwordless sudo not available for ${user}@${host}" \
                  "The user must have NOPASSWD:ALL in sudoers (Ubuntu cloud images usually do)" \
                  "ssh said: ${ssh_err}" \
                  "echo '${user} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/openg2p"
        return 1
    fi

    log_success "SSH + sudo OK on ${role}."
}

# ssh_run <role> <command...>
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

    ssh -n -i "$key" "${opts[@]}" "${user}@${host}" \
        "sudo -E env TERM=dumb PATH=\"\$PATH:/var/lib/rancher/rke2/bin:/usr/local/bin:/usr/local/sbin\" \
         bash --noprofile --norc -c $(printf '%q' "$*")" </dev/null
}

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

# ssh_push <role> <local_src> <remote_dest>
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

# ssh_pull <role> <remote_src> <local_dest>
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
# Stage the full sandbox automation tree + merged configs onto the VM.
# ---------------------------------------------------------------------------
# ssh_stage_sandbox <repo_root> <sandbox_config> [provision_output]
ssh_stage_sandbox() {
    local repo_root="$1"
    local sandbox_config="$2"
    local provision_output="${3:-}"

    log_info "Staging sandbox automation bundle on remote..."

    local stage
    stage=$(mktemp -d -t openg2p-sn-stage.XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -rf '$stage'" RETURN

    # Copy the install tree (scripts, lib, charts, helmfiles). Exclude laptop-
    # only / generated noise. Existing on-box install logic is unchanged —
    # we just ship the same files the operator would have cloned onto the VM.
    rsync -a \
        --exclude 'aws/keys/' \
        --exclude 'aws/logs/' \
        --exclude 'aws/aws-config.yaml' \
        --exclude 'logs/' \
        --exclude '.state/' \
        --exclude 'artifacts/' \
        --exclude 'setup-output/' \
        --exclude 'sandbox-config.yaml' \
        --exclude 'provision-output.yaml' \
        --exclude 'provision-output.yaml.prev' \
        --exclude '*.pem' \
        --exclude '.git/' \
        "${repo_root}/" "${stage}/"

    # On-box phase1 expects nfs-server/ and kubernetes/nfs-client/ at REPO_ROOT
    # (sibling of automation/ in a full clone). Stage them next to the
    # sandbox tree so REPO_ROOT resolves correctly on the remote.
    local git_root
    git_root="$(cd "${repo_root}/../.." && pwd)"
    if [[ ! -d "${git_root}/nfs-server" || ! -d "${git_root}/kubernetes/nfs-client" ]]; then
        log_error "Missing NFS install scripts in the deployment repo" \
                  "Expected ${git_root}/nfs-server and ${git_root}/kubernetes/nfs-client" \
                  "Clone the full openg2p-deployment repository" \
                  "ls ${git_root}/nfs-server ${git_root}/kubernetes/nfs-client"
        return 1
    fi
    mkdir -p "${stage}/kubernetes"
    rsync -a "${git_root}/nfs-server/" "${stage}/nfs-server/"
    rsync -a "${git_root}/kubernetes/nfs-client/" "${stage}/kubernetes/nfs-client/"
    log_info "Included nfs-server/ and kubernetes/nfs-client/ in stage bundle."

    # Merged sandbox config: user prefs + AWS overlay (last wins).
    cat "$sandbox_config" > "${stage}/sandbox-config.yaml"
    if [[ -n "$provision_output" && -f "$provision_output" ]]; then
        {
            echo ""
            echo "# ─── merged from provision-output.yaml at stage time ───"
            cat "$provision_output"
        } >> "${stage}/sandbox-config.yaml"
        # Also ship provision-output so on-box auto-detect still works if
        # someone re-runs scripts directly on the VM later.
        cp "$provision_output" "${stage}/provision-output.yaml"
    fi

    ssh_push "node" "${stage}/" "${REMOTE_WORK_DIR}/"

    log_success "Staged sandbox bundle at ${REMOTE_WORK_DIR}/ on remote."
}
