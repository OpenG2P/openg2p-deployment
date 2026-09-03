#!/usr/bin/env bash
# =============================================================================
# OpenG2P Sandbox Orchestrator — runs on your laptop
# =============================================================================
# SSHes into one Ubuntu 24.04 VM and runs the on-box install scripts
# (roles/infra/run.sh) remotely.
#
# Typical flow:
#   cd automation/sandbox/aws
#   ./openg2p-aws-provision.sh --config aws-config.yaml   # optional
#   cd ..
#   cp sandbox-config.example.yaml sandbox-config.yaml
#   ./openg2p-sandbox.sh --config sandbox-config.yaml
#
# This installs the sandbox INFRASTRUCTURE only (Kubernetes, Rancher, Nginx,
# Wireguard, DNS + TLS) and then prints what to try next. Installing an
# environment — a namespace with its own sub-domain and the OpenG2P commons
# stack — is a separate follow-on step, and several can live on one sandbox:
#
#   cd ../environment && ./env-cluster.sh --config env-config.yaml
#
# Idempotent — node state at /var/lib/openg2p/deploy-state/; laptop markers
# under ./.state/. Use --force to re-run completed stages.
# =============================================================================

set -euo pipefail

# Set by paths whose non-zero exit is a reported outcome rather than a crash
# (e.g. --check finding unmet prerequisites). Keeps the exit code meaningful
# for scripting without printing a misleading [FATAL] banner.
EXPECTED_EXIT=false

trap '
    rc=$?
    if [[ $rc -ne 0 && "${EXPECTED_EXIT:-false}" != "true" ]]; then
        echo "" >&2
        echo "[FATAL] openg2p-sandbox.sh exited with status ${rc} at line ${LINENO} (${BASH_COMMAND})" >&2
        echo "[FATAL] log: ${LOG_FILE:-<not set>}" >&2
    fi
    ssh_cleanup 2>/dev/null || true
' EXIT

echo "[boot] openg2p-sandbox.sh starting (bash ${BASH_VERSION})" >&2

if (( BASH_VERSINFO[0] < 4 )); then
    echo "[FATAL] bash 4 or later required (detected ${BASH_VERSION})." >&2
    echo "[FATAL] macOS: 'brew install bash', then re-open the shell." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
PROVISION_OUTPUT=""
RUN_STAGE="all"          # all | infra
RUN_PHASE=""             # optional phase within infra (1|2|3) or env (1|2)
FORCE_MODE=false
DRY_RUN=false
PROBE_ONLY=false
CHECK_ONLY=false
ASSUME_YES=false
LOG_FILE="${SCRIPT_DIR}/logs/openg2p-sandbox-$(date '+%Y%m%d-%H%M%S').log"

# Laptop-safe logging + cfg() from shared utils.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../production/lib/shared/utils.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/ssh-utils.sh"
# DNS/TLS preflight — validated on the laptop BEFORE the node is touched.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/acme.sh"

# Override STATE_DIR for laptop-side orchestrator markers.
STATE_DIR="${SCRIPT_DIR}/.state"

# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)            CONFIG_FILE="$2";       shift 2 ;;
            --provision-output)  PROVISION_OUTPUT="$2";  shift 2 ;;
            --stage)             RUN_STAGE="$2";         shift 2 ;;
            --phase)             RUN_PHASE="$2";         shift 2 ;;
            --force)             FORCE_MODE=true;        shift ;;
            --dry-run)           DRY_RUN=true;           shift ;;
            --probe)             PROBE_ONLY=true;        shift ;;
            --check)             CHECK_ONLY=true;        shift ;;
            --yes|-y)            ASSUME_YES=true;        shift ;;
            --reset-laptop)
                log_warn "Clearing laptop-side state at ${STATE_DIR}"
                rm -rf "${STATE_DIR}"
                exit 0
                ;;
            --help|-h) show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1" \
                          "This flag is not recognized" \
                          "Run with --help to see available options" \
                          "$0 --help"
                exit 1
                ;;
        esac
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        log_error "No config file specified" \
                  "The --config flag is required" \
                  "Copy sandbox-config.example.yaml and provide it" \
                  "$0 --config sandbox-config.yaml"
        exit 1
    fi

    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"

    case "$RUN_STAGE" in
        all|infra) ;;
        *)
            log_error "Invalid --stage: '${RUN_STAGE}'" \
                      "Expected one of: all, infra" \
                      "Environments are installed separately — see automation/environment/"
            exit 1
            ;;
    esac
}

show_help() {
    cat <<'EOF'
OpenG2P Sandbox Orchestrator
================================

Runs on your laptop. SSHes into one Ubuntu 24.04 VM and executes the on-box
scripts (roles/infra/run.sh) remotely.

Usage:
  ./openg2p-sandbox.sh --config sandbox-config.yaml [options]

Options:
  --config <file>            Path to sandbox-config.yaml (required)
  --provision-output <file>  Path to provision-output.yaml (auto-detect if blank)
  --stage <name>             What to run: all | infra  (default: all — the
                             sandbox installs infrastructure only)
  --phase <n>                Pass --phase N (1|2|3) through to roles/infra/run.sh
  --probe                    SSH-probe the node and exit (no changes)
  --check                    Validate config + DNS/TLS prerequisites and exit.
                             Makes no SSH connection and changes nothing —
                             use this to confirm you are ready to install.
  --force                    Ignore completion markers, re-run stages
  --dry-run                  Print what would run, do nothing
  --yes, -y                  Skip the interactive prerequisite confirmation
  --reset-laptop             Clear laptop-side .state/ markers and exit
  --help                     Show this help

Before you start — DNS & TLS prerequisites (one-time, manual):
  The sandbox issues real Let's Encrypt certificates, so it needs a REAL
  registered domain plus a DNS API token. Free option, ~2 minutes:
    1. Sign up at https://desec.io/
    2. Create a domain, e.g. mydept.dedyn.io
    3. Create an API token at https://desec.io/tokens
    4. Set `domain` and `tls.api_token` in sandbox-config.yaml
  The script verifies all of this before touching the VM and stops if the
  token or domain is wrong. No inbound connectivity is required.

Config layering:
  1. sandbox-config.yaml     — your preferences (cluster_name, domain, tls.*)
  2. provision-output.yaml   — AWS-derived state (node_ip, wireguard.endpoint,
                               ssh_host, ssh_user, ssh_key). Auto-detected next
                               to sandbox-config.yaml; its keys win on conflict.

Prerequisites on the VM:
  • Ubuntu 24.04 LTS, passwordless sudo for the SSH user (ubuntu@)
  • Reachable over SSH from this laptop (public IP / EIP)

After AWS provisioning:
  cd automation/sandbox
  cp sandbox-config.example.yaml sandbox-config.yaml
  ./openg2p-sandbox.sh --config sandbox-config.yaml --check
  ./openg2p-sandbox.sh --config sandbox-config.yaml

Environments (namespace + Istio + OpenG2P commons) are installed separately:
  cd ../environment && ./env-cluster.sh --config env-config.yaml
EOF
}

# ---------------------------------------------------------------------------
validate_orchestrator_config() {
    # node_ip must resolve after overlay (required by on-box infra script).
    if [[ -z "$(cfg node_ip)" ]]; then
        log_error "node_ip is blank after loading config + provision-output" \
                  "AWS overlay missing or incomplete" \
                  "Run aws/openg2p-aws-provision.sh, or set node_ip in sandbox-config.yaml"
        exit 1
    fi

    # SSH endpoint must resolve (ssh_resolve_role will also check key file).
    local host
    host=$(cfg ssh_host)
    if [[ -z "$host" ]]; then host=$(cfg public_ip); fi
    if [[ -z "$host" ]]; then host=$(cfg wireguard.endpoint); fi
    if [[ -z "$host" ]]; then
        log_error "No SSH host in config" \
                  "ssh_host / public_ip / wireguard.endpoint are blank" \
                  "Ensure provision-output.yaml exists next to sandbox-config.yaml"
        exit 1
    fi

    if [[ -z "$(cfg ssh_key)" ]]; then
        log_error "ssh_key is blank" \
                  "Cannot SSH without a key path" \
                  "Set ssh_key in provision-output.yaml or sandbox-config.yaml"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# DNS / TLS prerequisites — checked on the LAPTOP before the node is touched.
# ---------------------------------------------------------------------------
# The sandbox uses real Let's Encrypt certificates, which requires a registered
# domain and a working DNS API credential. Both are manual, one-time steps the
# operator must complete first. Catching a bad token here saves discovering it
# 20 minutes into an install, with a half-configured VM to clean up.
confirm_tls_prerequisites() {
    local domain=$(cfg "domain" "")
    local provider=$(cfg 'tls.dns_provider' 'desec')

    log_step "PREFLIGHT" "DNS & TLS prerequisites"

    cat <<EOF

  This sandbox issues REAL, browser-trusted certificates from Let's Encrypt.
  Self-signed certificates are not used: services inside the cluster call each
  other over HTTPS and fail when the issuing CA is not publicly trusted.

  That requires two things you must set up yourself, once:

    1. A REAL registered domain.
       Free option (~2 minutes, no purchase):
         a. Sign up at  https://desec.io/
         b. Create a domain, e.g.  mydept.dedyn.io
         c. Set  domain: "<yours>"  in $(basename "$CONFIG_FILE")

    2. A DNS API token for that domain, so the installer can write the ACME
       challenge record and the A records.
         deSEC:  https://desec.io/tokens  ->  tls.api_token

  You do NOT need to expose this machine to the internet, and you do NOT need
  to change your organisation's DNS. Validation is DNS-01: outbound only.

  Configured:
    domain        : ${domain:-<not set>}
    dns_provider  : ${provider}
    node_ip       : $(cfg node_ip)

EOF

    # Hard, programmatic verification (live API check for deSEC).
    if ! acme_preflight; then
        echo ""
        log_error "DNS / TLS prerequisites are not met — not starting the install" \
                  "The checks above must pass before any changes are made to the node" \
                  "Fix the reported problem in $(basename "$CONFIG_FILE") and re-run this command"
        exit 1
    fi

    # Confirmation prompt. Skipped with --yes, and auto-skipped when stdin is
    # not a terminal (CI / piped runs) so automation is not blocked.
    if [[ "$ASSUME_YES" == "true" ]]; then
        log_info "--yes supplied — continuing without prompting."
        return 0
    fi
    if [[ ! -t 0 ]]; then
        log_info "Non-interactive session — continuing without prompting."
        return 0
    fi

    echo ""
    read -rp "  Prerequisites verified. Proceed with the install? [y/N]: " _reply
    case "$_reply" in
        [yY]|[yY][eE][sS]) echo "" ;;
        *) log_info "Aborted by user — nothing was changed."; exit 0 ;;
    esac
}

# ---------------------------------------------------------------------------
stage_and_run_infra() {
    local marker="orchestrator/infra"
    if [[ -n "$RUN_PHASE" ]]; then marker="orchestrator/infra-phase${RUN_PHASE}"; fi

    if [[ "$FORCE_MODE" != "true" ]] && skip_if_done "$marker" "infrastructure install"; then
        return 0
    fi

    log_step "INFRA" "Stage bundle and run roles/infra/run.sh on remote"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would stage sandbox tree and run: roles/infra/run.sh --config sandbox-config.yaml${RUN_PHASE:+ --phase $RUN_PHASE}"
        return 0
    fi

    ssh_stage_sandbox "$SCRIPT_DIR" "$CONFIG_FILE" "$PROVISION_OUTPUT"

    local remote_cmd="cd ${REMOTE_WORK_DIR} && OPENG2P_ORCHESTRATED=1 bash roles/infra/run.sh --config sandbox-config.yaml"
    if [[ -n "$RUN_PHASE" ]]; then remote_cmd+=" --phase ${RUN_PHASE}"; fi
    if [[ "$FORCE_MODE" == "true" ]]; then remote_cmd+=" --force"; fi

    log_info "Remote: ${remote_cmd}"
    ssh_run "node" "$remote_cmd"

    mark_orchestrator_done "$marker"
}

# Ensure parent dirs exist for nested markers like orchestrator/infra.done
mark_orchestrator_done() {
    local marker="$1"
    mkdir -p "${STATE_DIR}/$(dirname "$marker")"
    mark_step_done "$marker"
}

# ---------------------------------------------------------------------------
pull_laptop_artifacts() {
    log_step "ARTIFACTS" "Pull Wireguard peer config and kubeconfig to laptop"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would pull peer1.conf, rke2-remote.yaml into ${LAPTOP_ARTIFACT_DIR}/"
        return 0
    fi

    mkdir -p "$LAPTOP_ARTIFACT_DIR"

    # No CA certificate to pull: certificates are issued by Let's Encrypt and
    # are trusted by every browser and container image out of the box.
    if ssh_pull "node" "/etc/wireguard/peers/peer1/peer1.conf" \
            "${LAPTOP_ARTIFACT_DIR}/peer1.conf" 2>/dev/null; then
        log_success "  Wireguard peer → ${LAPTOP_ARTIFACT_DIR}/peer1.conf"
    else
        log_warn "  Could not pull peer1.conf (Wireguard may not be ready yet)"
    fi

    if ssh_pull "node" "/etc/rancher/rke2/rke2-remote.yaml" \
            "${LAPTOP_ARTIFACT_DIR}/rke2-remote.yaml" 2>/dev/null; then
        chmod 600 "${LAPTOP_ARTIFACT_DIR}/rke2-remote.yaml" 2>/dev/null || true
        log_success "  kubeconfig     → ${LAPTOP_ARTIFACT_DIR}/rke2-remote.yaml"
    else
        log_warn "  Could not pull rke2-remote.yaml"
    fi
}

# Resolve ssh_key to an absolute path for copy-pasteable summary commands.
_resolve_ssh_key_display() {
    local key
    key=$(cfg ssh_key "")
    key="${key/#\~/$HOME}"
    if [[ -n "$key" && "$key" != /* ]]; then
        key="${SCRIPT_DIR}/${key}"
    fi
    # Prefer a path relative to SCRIPT_DIR when possible (shorter for display).
    case "$key" in
        "${SCRIPT_DIR}/"*) echo "./${key#${SCRIPT_DIR}/}" ;;
        *) echo "$key" ;;
    esac
}

show_completion_summary() {

    local node_ip rancher_host domain public_ip ssh_user ssh_key_disp
    local public_access cluster_name rancher_pw wg_subnet wg_server_ip
    node_ip=$(cfg node_ip)
    domain=$(cfg domain "")
    cluster_name=$(cfg cluster_name "openg2p")
    public_access=$(cfg public_access "false")
    public_ip=$(cfg ssh_host)
    if [[ -z "$public_ip" ]]; then public_ip=$(cfg public_ip); fi
    if [[ -z "$public_ip" ]]; then public_ip=$(cfg wireguard.endpoint); fi
    ssh_user=$(cfg ssh_user "ubuntu")
    ssh_key_disp=$(_resolve_ssh_key_display)
    rancher_host="rancher.${domain}"
    wg_subnet=$(cfg "wireguard.subnet" "10.15.0.0/16")
    # Wireguard server address is typically .1 in the WG subnet (e.g. 10.15.0.1)
    wg_server_ip="${wg_subnet%%/*}"
    wg_server_ip="${wg_server_ip%.*}.1"

    # Live-fetch Rancher admin password from the node.
    rancher_pw="<failed to fetch — see kubectl command below>"
    rancher_pw=$(ssh_run "node" \
        "KUBECONFIG=/etc/rancher/rke2/rke2.yaml /var/lib/rancher/rke2/bin/kubectl -n cattle-system get secret rancher-secret -o jsonpath='{.data.adminPassword}' 2>/dev/null | base64 -d 2>/dev/null" \
        2>/dev/null) || rancher_pw="<failed to fetch>"
    if [[ -z "$rancher_pw" ]]; then
        rancher_pw=$(ssh_run "node" \
            "cat /var/lib/openg2p/deploy-state/rancher-admin-password 2>/dev/null" \
            2>/dev/null) || rancher_pw="<failed to fetch>"
    fi
    if [[ -z "$rancher_pw" ]]; then rancher_pw="<empty — secret may not exist>"; fi

    local access_line="private — reachable only via Wireguard / VPC"
    if [[ "$public_access" == "true" ]]; then
        access_line="PUBLIC — 80/443 open to the Internet"
    fi

    local summary_dir="${SCRIPT_DIR}/setup-output"
    local summary_file="${summary_dir}/SETUP-SUMMARY.txt"
    mkdir -p "$summary_dir"
    chmod 700 "$summary_dir" 2>/dev/null || true

    local art="${LAPTOP_ARTIFACT_DIR}"
    case "$art" in
        "${SCRIPT_DIR}/"*) art="./${art#${SCRIPT_DIR}/}" ;;
    esac

    local config_disp
    config_disp=$(basename "$CONFIG_FILE")

    local headline="OpenG2P Sandbox Infrastructure — SETUP COMPLETE"
    local whats_next_block=""

    whats_next_block=$(cat <<NEXTBLOCK
══════════════════════════════════════════════════════════════════════════════
  WHAT'S NEXT
══════════════════════════════════════════════════════════════════════════════

  The sandbox INFRASTRUCTURE is ready. Nothing more is needed to log in and
  look around — try these two things first:

    1. Bring up Wireguard (STEP 1 below), then open in a browser:

           https://${rancher_host}

       Log in as 'admin' with the password above. The certificate is a real
       Let's Encrypt one, so you should see no browser warning. If the page
       does not load at all, check DNS first (STEP 2 below).

    2. Confirm the cluster is healthy:

           ssh -i ${ssh_key_disp} ${ssh_user}@${public_ip} \\
             "sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml \\
              /var/lib/rancher/rke2/bin/kubectl get nodes"

       One node, status Ready.

  ── THEN: install an environment ────────────────────────────────────────────

  An environment is a namespace on this cluster with its own sub-domain and the
  OpenG2P commons stack (PostgreSQL, Kafka, MinIO, Keycloak, eSignet, Superset,
  ODK, ...). You can create several on one sandbox — dev, qa, pilot.

  Environments are installed by a SEPARATE tool, not by this script:

      cd ../environment
      cp env-config.example.yaml env-config.yaml
      #  edit: environment: "dev"   base_domain: "dev.${domain}"
      ./env-cluster.sh --config env-config.yaml

  It creates the namespace, Rancher Project, Istio Gateway and the commons
  charts. It does NOT set up host-level access, so first do these two on the
  sandbox VM for each new environment:

    1) DNS — point the environment's wildcard at this node:

           *.dev.${domain}   A   ${node_ip}
           dev.${domain}     A   ${node_ip}

    2) TLS + Nginx — obtain a wildcard certificate and serve it:

           ssh -i ${ssh_key_disp} ${ssh_user}@${public_ip}
           sudo /opt/acme.sh/acme.sh --issue --dns dns_desec \\
                -d dev.${domain} -d '*.dev.${domain}' \\
                --server letsencrypt \\
                --home /opt/acme.sh --config-home /opt/acme.sh/data
           # then add an Nginx server block for *.dev.${domain}
           # (copy the pattern in /etc/nginx/sites-available/openg2p-infra.conf)
NEXTBLOCK
)

    cat > "$summary_file" <<EOF


╔══════════════════════════════════════════════════════════════════════════════╗
║                                                                              ║
║    ${headline}
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝

  Cluster:     ${cluster_name}
  Node IP:     ${node_ip}  (private)
  Public IP:   ${public_ip}
  Rancher:     https://${rancher_host}
  Access:      ${access_line}

  SSH into the VM (from this laptop):

      ssh -i ${ssh_key_disp} ${ssh_user}@${public_ip}


  CREDENTIALS — KEEP THESE SAFE

    ┌─ Rancher local admin ────────────────────────────────────────────────────┐
    │   username:  admin                                                       │
    │   password:  ${rancher_pw}
    │   (also in K8s secret: cattle-system/rancher-secret)                     │
    └──────────────────────────────────────────────────────────────────────────┘

══════════════════════════════════════════════════════════════════════════════
  WHAT TO DO NEXT — on your laptop
══════════════════════════════════════════════════════════════════════════════

  STEP 1.  Wireguard VPN

      Artifacts already pulled (if present):
        ${art}/peer1.conf

      Or pull manually anytime:

      ssh -i ${ssh_key_disp} ${ssh_user}@${public_ip} \\
          "sudo cat /etc/wireguard/peers/peer1/peer1.conf" > peer1.conf

      Import peer1.conf into the Wireguard app and activate the tunnel.
      Verify:  ping ${wg_server_ip}

  STEP 2.  DNS and certificates — nothing to do

      Hostnames under ${domain} are published as public A records pointing at
      ${node_ip}, so your normal resolver answers them. No /etc/hosts entries,
      no /etc/resolver files, no local DNS server.

      Certificates come from Let's Encrypt and are already trusted by your
      browser and by every container in the cluster. There is no CA to install.

      Verify:  nslookup ${rancher_host}      -> ${node_ip}

      If that returns nothing, your resolver is stripping private addresses
      from public DNS answers ("DNS rebinding protection" — common on
      pfSense/OPNsense, Fritz!Box and OpenDNS). Point that client at a public
      resolver, e.g. add to peer1.conf under [Interface]:  DNS = 1.1.1.1

  STEP 3.  Login to Rancher (local authentication)

      Open:     https://${rancher_host}
      Username: admin
      Password: (see CREDENTIALS above)

      Create additional users in Rancher:
        ☰ → Users & Authentication → Users


══════════════════════════════════════════════════════════════════════════════
  OPTIONAL — kubectl / helm from your laptop (Wireguard must be active)
══════════════════════════════════════════════════════════════════════════════

      Already pulled (if present):  ${art}/rke2-remote.yaml

      Or pull manually:

      ssh -i ${ssh_key_disp} ${ssh_user}@${public_ip} \\
          "sudo cat /etc/rancher/rke2/rke2-remote.yaml" > ~/.kube/openg2p-sandbox
      chmod 600 ~/.kube/openg2p-sandbox
      export KUBECONFIG=~/.kube/openg2p-sandbox
      # or: export KUBECONFIG=${art}/rke2-remote.yaml
      kubectl get nodes


${whats_next_block}


  Log:     ${LOG_FILE}
  Summary: ${summary_file}

EOF

    chmod 600 "$summary_file" 2>/dev/null || true
    cat "$summary_file"
    log_success "Setup summary saved to ${summary_file}"
}


# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    mkdir -p "${SCRIPT_DIR}/logs" "${SCRIPT_DIR}/.state/orchestrator" "${SCRIPT_DIR}/artifacts"
    exec > >(tee -a "$LOG_FILE") 2>&1

    log_banner "OpenG2P Sandbox Orchestrator" "Laptop → SSH → on-box install scripts"
    log_info "Config: ${CONFIG_FILE}"
    log_info "Log:    ${LOG_FILE}"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Mode:   dry-run"
    fi
    echo ""

    load_config "$CONFIG_FILE"

    # Auto-detect provision-output overlay next to sandbox-config.yaml.
    if [[ -z "$PROVISION_OUTPUT" ]]; then
        PROVISION_OUTPUT="$(dirname "$CONFIG_FILE")/provision-output.yaml"
    fi
    if [[ -f "$PROVISION_OUTPUT" ]]; then
        log_info "Loading provision-output overlay: ${PROVISION_OUTPUT}"
        load_config "$PROVISION_OUTPUT"
    else
        PROVISION_OUTPUT=""
        log_info "No provision-output.yaml found — using sandbox-config.yaml only"
    fi

    # --check: answer "am I ready to install?" without connecting anywhere.
    # DNS/TLS problems are fatal; a missing VM/SSH detail is only a warning, so
    # the DNS side can be validated before the machine even exists.
    if [[ "$CHECK_ONLY" == "true" ]]; then
        log_step "CHECK" "Validating configuration and DNS/TLS prerequisites"
        local check_rc=0
        acme_preflight || check_rc=1

        echo ""
        log_info "VM / SSH settings (needed to install, not to obtain certificates):"
        local _v
        for _v in node_ip ssh_host ssh_key; do
            local _val
            _val=$(cfg "$_v" "")
            if [[ -n "$_val" ]]; then
                log_success "  ${_v} = ${_val}"
            else
                log_warn "  ${_v} is not set"
            fi
        done

        echo ""
        if [[ $check_rc -eq 0 ]]; then
            log_success "DNS/TLS prerequisites are satisfied — you are ready to install."
            log_info "Run:  $(basename "$0") --config $(basename "$CONFIG_FILE")"
        else
            log_error "DNS/TLS prerequisites are NOT satisfied" \
                      "See the error above" \
                      "Fix it in $(basename "$CONFIG_FILE"), then re-run with --check"
            EXPECTED_EXIT=true
        fi
        return $check_rc
    fi

    validate_orchestrator_config

    init_state_dir
    mkdir -p "${STATE_DIR}/orchestrator"
    ssh_init

    if [[ "$PROBE_ONLY" == "true" ]]; then
        log_step "PROBE" "SSH + sudo check"
        ssh_probe "node"
        log_success "Probe complete — node is reachable."
        return 0
    fi

    # Gate the whole run on DNS/TLS prerequisites being genuinely in place.
    # Deliberately before ssh_probe: nothing on the node is touched until the
    # domain and DNS credential are proven to work.
    if [[ "$DRY_RUN" != "true" ]]; then
        confirm_tls_prerequisites
    fi

    log_step "PROBE" "SSH + sudo check"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would probe SSH + sudo"
    else
        ssh_probe "node"
    fi

    # The sandbox installs INFRASTRUCTURE only. Environments are installed
    # separately with automation/environment/.
    stage_and_run_infra
    pull_laptop_artifacts
    show_completion_summary

    log_success "Orchestrator finished."
}

main "$@"
