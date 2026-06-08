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
    # Close all ControlMaster sockets cleanly.
    for sock in "${SSH_CTRL_DIR}"/*; do
        [[ -S "$sock" ]] || continue
        local target
        target=$(basename "$sock")
        ssh -o "ControlPath=${sock}" -O exit "${target}" 2>/dev/null || true
    done
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

    ssh -i "$key" "${opts[@]}" "${user}@${host}" "sudo -E bash -lc $(printf '%q' "$*")"
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

    # Merge prod-config + provision-output into a single staged config.
    cat "$config_file" > "${stage}/prod-config.yaml"
    if [[ -n "$provision_output" && -f "$provision_output" ]]; then
        {
            echo ""
            echo "# ─── merged from provision-output.yaml at stage time ───"
            cat "$provision_output"
        } >> "${stage}/prod-config.yaml"
    fi

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
