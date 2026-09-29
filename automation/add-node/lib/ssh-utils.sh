#!/usr/bin/env bash
# =============================================================================
# OpenG2P Add-Node — SSH / orchestration helpers (laptop side)
# =============================================================================
# Sourced by openg2p-add-node.sh and openg2p-remove-node.sh on the admin laptop.
# Roles:
#   • node     — the new machine being joined
#   • primary  — an existing control-plane (for remove / verify)
# =============================================================================

# Short path + hashed ControlPath (%C) stay under the Unix socket name limit (108).
# Default under /tmp so the laptop orchestrator works without writing to ~/.ssh.
# Override with SSH_CTRL_DIR=... if needed.
SSH_CTRL_DIR="${SSH_CTRL_DIR:-/tmp/og2p-an-${UID}}"
REMOTE_WORK_DIR="/tmp/openg2p-add-node"

# ---------------------------------------------------------------------------
# Role resolution — echoes "user|host|keyfile"
# ---------------------------------------------------------------------------
ssh_resolve_role() {
    local role="$1"
    local user host key

    case "$role" in
        node)
            user=$(cfg "ssh_user" "ubuntu")
            host=$(cfg "ssh_host")
            if [[ -z "$host" ]]; then host=$(cfg "public_ip"); fi
            if [[ -z "$host" ]]; then host=$(cfg "node_ip"); fi
            key=$(cfg "ssh_key" "")
            ;;
        primary)
            user=$(cfg "primary_ssh_user" "$(cfg ssh_user ubuntu)")
            host=$(cfg "primary_ssh_host")
            key=$(cfg "primary_ssh_key" "$(cfg ssh_key "")")
            ;;
        *)
            log_error "Unknown SSH role: '${role}'" \
                      "Expected 'node' or 'primary'" \
                      "Check the orchestrator call site"
            return 1
            ;;
    esac

    if [[ -z "$host" ]]; then
        log_error "No SSH host for role '${role}'" \
                  "ssh_host / primary_ssh_host is blank in add-node-config.yaml" \
                  "Set ssh_host (new node) or primary_ssh_host (control-plane). After AWS provision, copy from aws/provision-output.yaml."
        return 1
    fi

    if [[ -z "$key" ]]; then
        log_error "No SSH key for role '${role}'" \
                  "ssh_key / primary_ssh_key is blank" \
                  "Set ssh_key to your .pem path (e.g. from aws/provision-output.yaml)"
        return 1
    fi

    key="${key/#\~/$HOME}"
    if [[ ! -f "$key" ]]; then
        log_error "SSH key file not found: ${key}" \
                  "ssh_key path does not exist on this laptop" \
                  "Fix ssh_key in add-node-config.yaml"
        return 1
    fi

    echo "${user}|${host}|${key}"
}

ssh_options_for() {
    local _role="$1"
    local opts=(
        -o "ControlMaster=auto"
        -o "ControlPath=${SSH_CTRL_DIR}/%C"
        -o "ControlPersist=300"
        -o "StrictHostKeyChecking=no"
        -o "UserKnownHostsFile=/dev/null"
        -o "LogLevel=ERROR"
        -o "ServerAliveInterval=30"
        -o "ServerAliveCountMax=3"
    )
    printf '%s\n' "${opts[@]}"
}

ssh_init() {
    mkdir -p "$SSH_CTRL_DIR"
    chmod 700 "$SSH_CTRL_DIR"
}

ssh_cleanup() {
    for sock in "${SSH_CTRL_DIR}"/*; do
        [[ -S "$sock" ]] || continue
        local target
        target=$(basename "$sock")
        ssh -o "ControlPath=${sock}" -O exit "${target}" 2>/dev/null || true
    done
}

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

    local ssh_err
    if ! ssh_err=$(ssh -i "$key" "${opts[@]}" \
            -o "BatchMode=yes" -o "ConnectTimeout=15" \
            "${user}@${host}" "true" 2>&1); then
        log_error "SSH connection failed: ${user}@${host}" \
                  "Cannot connect to the ${role} from this laptop" \
                  "ssh said: ${ssh_err}" \
                  "ssh -i ${key} ${user}@${host}"
        return 1
    fi

    if ! ssh_err=$(ssh -i "$key" "${opts[@]}" -o "BatchMode=yes" \
             "${user}@${host}" "sudo -n true" 2>&1); then
        log_error "Passwordless sudo not available for ${user}@${host}" \
                  "The user must have NOPASSWD sudo (or run as root)" \
                  "ssh said: ${ssh_err}" \
                  "echo '${user} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/openg2p"
        return 1
    fi

    log_success "SSH + sudo OK on ${role}."
}

# ssh_run <role> <command...>  — remote under sudo
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

# Stage join bundle + config onto the new node.
ssh_stage_join() {
    local repo_root="$1"
    local config_file="$2"

    log_info "Staging add-node bundle on remote node..."

    local stage
    stage=$(mktemp -d -t openg2p-add-node-stage.XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -rf '$stage'" RETURN

    mkdir -p "${stage}/lib" "${stage}/role"
    cp -r "${repo_root}/lib/utils.sh" "${stage}/lib/utils.sh"
    cp -r "${repo_root}/lib/add-node-steps.sh" "${stage}/lib/add-node-steps.sh"
    cp -r "${repo_root}/roles/join/." "${stage}/role/"
    cp "$config_file" "${stage}/add-node-config.yaml"

    ssh_push "node" "${stage}/" "${REMOTE_WORK_DIR}/"
    log_success "Staged bundle at ${REMOTE_WORK_DIR}/ on the new node."
}

# Run the remote join entrypoint.
ssh_run_join() {
    local extra_args=("$@")
    log_info "Running join/run.sh on remote (args: ${extra_args[*]})"
    local quoted=""
    local a
    for a in "${extra_args[@]}"; do
        quoted+=" $(printf '%q' "$a")"
    done
    ssh_run "node" "cd ${REMOTE_WORK_DIR} && bash role/run.sh --config add-node-config.yaml${quoted}"
}

# Overlay AWS provision-output.yaml keys into CONFIG (laptop-side only).
# Looks next to config, then at aws/provision-output.yaml under SCRIPT_DIR.
load_provision_overlay() {
    local config_file="$1"
    local script_dir="$2"
    local candidates=(
        "$(dirname "$config_file")/provision-output.yaml"
        "${script_dir}/aws/provision-output.yaml"
        "${script_dir}/provision-output.yaml"
    )
    local f
    for f in "${candidates[@]}"; do
        if [[ -f "$f" ]]; then
            log_info "Loading AWS overlay: ${f}"
            # Re-parse into CONFIG (later keys overwrite — load_config appends/overwrites)
            local current_parent=""
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ "$line" =~ ^[[:space:]]*# ]] && continue
                [[ "$line" =~ ^[[:space:]]*$ ]] && continue
                local stripped="${line#"${line%%[![:space:]]*}"}"
                local indent=$(( ${#line} - ${#stripped} ))
                stripped="${stripped%%#*}"
                stripped="${stripped%"${stripped##*[![:space:]]}"}"
                [[ "$stripped" == *":"* ]] || continue
                local key="${stripped%%:*}"
                local value="${stripped#*:}"
                key="${key%"${key##*[![:space:]]}"}"
                key="${key#"${key%%[![:space:]]*}"}"
                value="${value#"${value%%[![:space:]]*}"}"
                value="${value%\"}"; value="${value#\"}"
                value="${value%\'}"; value="${value#\'}"
                if [[ -z "$value" ]]; then
                    [[ $indent -eq 0 ]] && current_parent="$key"
                else
                    if [[ $indent -gt 0 && -n "$current_parent" ]]; then
                        CONFIG["${current_parent}.${key}"]="$value"
                    else
                        current_parent=""
                        CONFIG["$key"]="$value"
                    fi
                fi
            done < "$f"

            # Map AWS output → add-node SSH / identity keys when blank.
            if [[ -z "$(cfg node_ip)" && -n "$(cfg private_ip)" ]]; then
                CONFIG["node_ip"]="$(cfg private_ip)"
            fi
            if [[ -z "$(cfg node_name)" && -n "$(cfg instance_name)" ]]; then
                CONFIG["node_name"]="$(cfg instance_name)"
            fi
            if [[ -z "$(cfg ssh_host)" && -n "$(cfg public_ip)" ]]; then
                CONFIG["ssh_host"]="$(cfg public_ip)"
            fi
            # provision-output already has ssh_host / ssh_user / ssh_key when written by AWS script.
            log_success "Overlay applied (ssh_host=$(cfg ssh_host) node_ip=$(cfg node_ip))"
            return 0
        fi
    done
    return 0
}
