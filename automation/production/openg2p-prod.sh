#!/usr/bin/env bash
# =============================================================================
# OpenG2P 3-Node Production Infrastructure Orchestrator
# =============================================================================
# Runs ON YOUR LAPTOP. SSHes into 3 Ubuntu 24.04 nodes (RP, compute, storage)
# and drives role-specific phases on each.
#
# Roles:
#   reverse-proxy (rp) — Nginx (admin server blocks), Wireguard server, customer-supplied TLS certs
#   compute            — RKE2 single control-plane, Istio, Rancher, Keycloak
#   storage            — NFS server, Postgres host install
#
# Usage:
#   ./openg2p-prod.sh --config prod-config.yaml
#   ./openg2p-prod.sh --config prod-config.yaml --role storage
#   ./openg2p-prod.sh --config prod-config.yaml --role compute --phase 2
#   ./openg2p-prod.sh --config prod-config.yaml --probe
#
# Idempotent — state markers live on each node at /var/lib/openg2p/deploy-state/.
# Re-running picks up where it left off. Use --force to re-run completed steps.
# =============================================================================

set -euo pipefail

# Trap any non-zero exit (including silent set-e exits) and emit a line number.
trap '
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "" >&2
        echo "[FATAL] openg2p-prod.sh exited with status ${rc} at line ${LINENO} (${BASH_COMMAND})" >&2
        echo "[FATAL] log: ${LOG_FILE:-<not set>}" >&2
    fi
' EXIT

# Early visibility — anything before the tee redirect goes straight to the
# terminal. If the script silently dies, you should still see "starting".
echo "[boot] openg2p-prod.sh starting (bash ${BASH_VERSION})" >&2

# We use bash-4+ features (mapfile, parameter substitutions, process subs).
# Linux ships bash 5+ by default; macOS ships /bin/bash 3.2 — install a newer
# bash with `brew install bash` (and ensure it's first in PATH).
if (( BASH_VERSINFO[0] < 4 )); then
    echo "[FATAL] bash 4 or later required (detected ${BASH_VERSION})." >&2
    echo "[FATAL] macOS: 'brew install bash', then re-open the shell." >&2
    echo "[FATAL] Linux: your distro's bash should already be 4+; check PATH." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
PROVISION_OUTPUT=""
RUN_ROLE="all"
RUN_PHASE=""
FORCE_MODE=false
DRY_RUN=false
PROBE_ONLY=false
PREFLIGHT_ONLY=false
VALIDATE_CERTS_ONLY=false
SKIP_PREFLIGHT=false
LOG_FILE="${SCRIPT_DIR}/logs/openg2p-prod-$(date '+%Y%m%d-%H%M%S').log"

# Source shared utilities (logging, config loader, state) — same library used
# inside the remote nodes too. The orchestrator uses only the laptop-safe bits.
source "${SCRIPT_DIR}/lib/shared/utils.sh"
source "${SCRIPT_DIR}/lib/ssh-utils.sh"
# Hostname getters (get_rancher_hostname / get_keycloak_hostname). Laptop-safe:
# the getters only read CONFIG via cfg. Used by --validate-certs and the
# completion summary.
source "${SCRIPT_DIR}/lib/shared/hostnames.sh"

# Override STATE_DIR for the laptop side — orchestrator state is per-config.
STATE_DIR="${SCRIPT_DIR}/.state"

# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)            CONFIG_FILE="$2";       shift 2 ;;
            --provision-output)  PROVISION_OUTPUT="$2";  shift 2 ;;
            --role)              RUN_ROLE="$2";          shift 2 ;;
            --phase)             RUN_PHASE="$2";         shift 2 ;;
            --force)   FORCE_MODE=true;  shift ;;
            --dry-run) DRY_RUN=true;     shift ;;
            --probe)           PROBE_ONLY=true;     shift ;;
            --preflight)       PREFLIGHT_ONLY=true; shift ;;
            --validate-certs)  VALIDATE_CERTS_ONLY=true; shift ;;
            --skip-preflight)  SKIP_PREFLIGHT=true; shift ;;
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
                  "Copy prod-config.example.yaml and provide it" \
                  "$0 --config prod-config.yaml"
        exit 1
    fi

    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"

    case "$RUN_ROLE" in
        all|rp|reverse-proxy|compute|storage) ;;
        *)
            log_error "Invalid --role: '${RUN_ROLE}'" \
                      "Expected one of: all, rp, compute, storage"
            exit 1
            ;;
    esac

    # Normalize alias.
    # Avoid the `[[ test ]] && var=...` form: when the test is false (the
    # common case here), the whole compound returns 1 and `set -e` exits.
    if [[ "$RUN_ROLE" == "reverse-proxy" ]]; then
        RUN_ROLE="rp"
    fi
}

show_help() {
    cat <<'EOF'
OpenG2P 3-Node Production Orchestrator
========================================

Runs on your laptop. Drives 3 nodes via SSH.

Usage:
  ./openg2p-prod.sh --config prod-config.yaml [options]

Options:
  --config <file>            Path to user prod-config.yaml (required)
  --provision-output <file>  Path to provision-output.yaml (auto-detected if blank)
                             AWS-derived values that override --config keys
  --role  <name>             Run only one role: rp | compute | storage  (default: all)
  --phase <n>                Run only one phase within the role (1, 2, 3)
  --probe                    SSH-probe all 3 nodes and exit (no changes)
  --preflight                Run preflight on all 3 nodes and exit (no changes)
  --validate-certs           Validate customer TLS certs on your laptop and exit
                             (key↔cert match, expiry, SAN covers the hostnames).
                             No SSH, no nodes touched — run before installing.
  --skip-preflight           Skip preflight (use with caution — for re-runs only)
  --force                    Ignore completion markers, re-run all steps
  --dry-run                  Print what would run, do nothing
  --reset-laptop             Clear laptop-side state and exit
  --help                     Show this help

Config layering:
  1. prod-config.yaml         — your preferences (versions, hostnames, emails)
  2. provision-output.yaml    — AWS-derived state (IPs, SSH paths, private_subnet)
                                Auto-detected next to prod-config.yaml. Loaded
                                second; its keys win on conflict.

Order when --role all (default):
  1. SSH probes for all 3 nodes
  2. Storage node: phase 1 (NFS server + Postgres host)
  3. Compute node: phase 1 (RKE2 + NFS client)
  4. Reverse-proxy:  phase 1 (Wireguard, customer cert ingest, Nginx admin server blocks)
  5. Compute node: phase 2 (helmfile — Istio, Rancher, Keycloak, monitoring)
  6. Compute node: phase 3 (Rancher-Keycloak SAML)

State markers:
  • Each node:  /var/lib/openg2p/deploy-state/*.done
  • Laptop:     ./.state/orchestrator/*.done
EOF
}

# ---------------------------------------------------------------------------
validate_orchestrator_config() {
    # Back-compat shim: configs from the old dual-NIC era set rp_internal_ip
    # instead of rp_private_ip. Promote the legacy key into the canonical
    # one so the rest of the validation and downstream scripts see it.
    if [[ -z "$(cfg rp_private_ip)" && -n "$(cfg rp_internal_ip)" ]]; then
        CONFIG[rp_private_ip]="$(cfg rp_internal_ip)"
        log_info "Using legacy rp_internal_ip as rp_private_ip (rename in prod-config.yaml when convenient)"
    fi

    local required=(
        cluster_name
        rp_public_ip rp_private_ip
        compute_private_ip compute_node_name
        storage_private_ip storage_node_name
        private_subnet
        wg_subnet wg_port
        rke2_version rancher_version
        keycloak_admin_email
        postgres_version postgres_port
        nfs_export_path nfs_mount_path
    )
    validate_config "${required[@]}"

    # Customer hostnames: either public_domain (to auto-derive both) or
    # every individual *_hostname must be set.
    local pd=$(cfg public_domain)
    if [[ -z "$pd" ]]; then
        local missing=()
        for h in rancher_hostname keycloak_hostname; do
            [[ -z "$(cfg "$h")" ]] && missing+=("$h")
        done
        if [[ ${#missing[@]} -gt 0 ]]; then
            log_error "Customer hostnames not set" \
                      "public_domain is blank AND these per-service hostnames are missing: ${missing[*]}" \
                      "Set public_domain (e.g. openg2p.gov.eth) — it derives both — or fill in each *_hostname" \
                      "" \
                      "https://docs.openg2p.org/operations/deployment/automation/three-node-automation#id-3.-customer-supplied-dns-records"
            exit 1
        fi
    fi

    # TLS certs: either tls_wildcard_cert+key OR both tls_<svc>_cert+key
    # must be set, AND the referenced files must exist on the laptop.
    _validate_tls_cert_paths

    check_subnet_overlap
}

# Check that customer cert paths are set in config AND files exist on disk.
# Fails fast on the laptop before we burn time waiting for SSH/preflight.
_validate_tls_cert_paths() {
    local cfg_dir
    cfg_dir=$(cd "$(dirname "$CONFIG_FILE")" && pwd)

    _resolve() {
        local p="$1"
        [[ -z "$p" ]] && { echo ""; return; }
        p="${p/#\~\//${HOME}/}"
        [[ "$p" != /* ]] && p="${cfg_dir}/${p}"
        echo "$p"
    }

    local wc wk
    wc=$(_resolve "$(cfg tls_wildcard_cert)")
    wk=$(_resolve "$(cfg tls_wildcard_key)")

    if [[ -n "$wc" || -n "$wk" ]]; then
        # Wildcard mode — both must be set and exist
        if [[ -z "$wc" || -z "$wk" ]]; then
            log_error "Wildcard TLS cert/key both required" \
                      "Only one of tls_wildcard_cert / tls_wildcard_key is set in prod-config.yaml" \
                      "Set both (or clear both and use per-FQDN tls_<service>_cert/key instead)" \
                      "" \
                      "https://docs.openg2p.org/operations/deployment/automation/three-node-automation#id-4.-customer-supplied-tls-certificates"
            exit 1
        fi
        for f in "$wc" "$wk"; do
            [[ -f "$f" ]] || {
                log_error "TLS cert file not found: $f" \
                          "Path resolved from prod-config.yaml does not exist" \
                          "Verify the path is correct and the file is readable" \
                          "ls -la $f" \
                          "https://docs.openg2p.org/operations/deployment/automation/three-node-automation#id-4.-customer-supplied-tls-certificates"
                exit 1
            }
        done
        log_success "TLS certs validated (wildcard mode): cert=${wc}  key=${wk}"
    else
        # Per-FQDN mode — every service needs cert + key
        local svc cert key missing=()
        for svc in rancher keycloak; do
            cert=$(_resolve "$(cfg "tls_${svc}_cert")")
            key=$(_resolve  "$(cfg "tls_${svc}_key")")
            if [[ -z "$cert" || -z "$key" ]]; then missing+=("$svc"); continue; fi
            [[ -f "$cert" ]] || { log_error "TLS cert file not found for ${svc}: $cert" "" "" "" "https://docs.openg2p.org/operations/deployment/automation/three-node-automation#id-4.-customer-supplied-tls-certificates"; exit 1; }
            [[ -f "$key"  ]] || { log_error "TLS key file not found for ${svc}: $key"   "" "" "" "https://docs.openg2p.org/operations/deployment/automation/three-node-automation#id-4.-customer-supplied-tls-certificates"; exit 1; }
        done
        if [[ ${#missing[@]} -gt 0 ]]; then
            log_error "Customer TLS certs not configured" \
                      "Neither tls_wildcard_cert nor per-service tls_<svc>_cert/key are set for: ${missing[*]}" \
                      "Set tls_wildcard_cert + tls_wildcard_key OR both tls_<service>_cert/key pairs (rancher, keycloak) in prod-config.yaml" \
                      "" \
                      "https://docs.openg2p.org/operations/deployment/automation/three-node-automation#id-4.-customer-supplied-tls-certificates"
            exit 1
        fi
        log_success "TLS certs validated (per-FQDN mode: rancher, keycloak)"
    fi
}

# Deep, laptop-side TLS validation for `--validate-certs`. Mirrors the RP-side
# checks (roles/reverse-proxy/phase1.sh R1.5) but runs entirely on the laptop
# with NO SSH, so cert problems surface in seconds instead of mid-install.
# For each admin hostname (rancher, keycloak) it checks:
#   • the cert file parses as PEM X.509
#   • the private key matches the cert (public-key compare; RSA or EC)
#   • the cert is not expired (warns if it expires within 30 days)
#   • the SAN (or CN) actually covers the resolved hostname (wildcards honoured)
DOCS_TLS_URL="https://docs.openg2p.org/operations/deployment/automation/three-node-automation#id-4.-customer-supplied-tls-certificates"

validate_certs_deep() {
    local cfg_dir
    cfg_dir=$(cd "$(dirname "$CONFIG_FILE")" && pwd)

    _vc_resolve() {
        local p="$1"; [[ -z "$p" ]] && { echo ""; return; }
        p="${p/#\~\//${HOME}/}"; [[ "$p" != /* ]] && p="${cfg_dir}/${p}"; echo "$p"
    }

    # Does cert's SAN (or CN) cover host, honouring a leading wildcard?
    _vc_covers() {
        local cert="$1" host="$2" sans cn s wild
        sans=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null \
               | grep -oE 'DNS:[^,]+' | sed 's/DNS://;s/ //g')
        if [[ -z "$sans" ]]; then   # LibreSSL/macOS may lack -ext; fall back to -text
            sans=$(openssl x509 -in "$cert" -noout -text 2>/dev/null \
                   | awk '/Subject Alternative Name/{getline; print}' \
                   | tr ',' '\n' | sed 's/^ *DNS://;s/ //g')
        fi
        while IFS= read -r s; do
            [[ -z "$s" ]] && continue
            [[ "$s" == "$host" ]] && return 0
            if [[ "$s" == "*."* ]]; then wild="${s#\*.}"; [[ "$host" == *."$wild" ]] && return 0; fi
        done <<< "$sans"
        cn=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null \
             | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p' | tr -d ' ')
        [[ "$cn" == "$host" ]] && return 0
        [[ "$cn" == "*."* && "$host" == *."${cn#\*.}" ]] && return 0
        return 1
    }

    # Path + completeness checks first (reused from the install path). Exits on
    # missing/incomplete paths with a clear message.
    _validate_tls_cert_paths

    local wc wk mode
    wc=$(_vc_resolve "$(cfg tls_wildcard_cert)")
    wk=$(_vc_resolve "$(cfg tls_wildcard_key)")
    if [[ -n "$wc" ]]; then mode="wildcard"; else mode="per-FQDN"; fi
    log_info "Deep cert validation (${mode} mode) — laptop-only, no nodes touched"

    local fails=0 svc host cert key cpub kpub exp
    for svc in rancher keycloak; do
        case "$svc" in
            rancher)  host=$(get_rancher_hostname) ;;
            keycloak) host=$(get_keycloak_hostname) ;;
        esac
        if [[ -z "$host" ]]; then
            log_error "Cannot resolve ${svc} hostname" \
                      "public_domain is blank and ${svc}_hostname is not set" \
                      "Set public_domain or ${svc}_hostname in prod-config.yaml" \
                      "" "$DOCS_TLS_URL"
            fails=$((fails + 1)); continue
        fi

        if [[ "$mode" == "wildcard" ]]; then
            cert="$wc"; key="$wk"
        else
            cert=$(_vc_resolve "$(cfg "tls_${svc}_cert")")
            key=$(_vc_resolve  "$(cfg "tls_${svc}_key")")
        fi

        # 1. cert parses
        if ! openssl x509 -in "$cert" -noout -subject >/dev/null 2>&1; then
            log_error "${host}: not a readable PEM X.509 certificate" \
                      "openssl could not parse ${cert}" \
                      "Ensure it is a PEM cert (or fullchain); convert PFX/DER to PEM first" \
                      "openssl x509 -in ${cert} -noout -subject" "$DOCS_TLS_URL"
            fails=$((fails + 1)); continue
        fi

        # 2. key <-> cert match (public-key compare works for RSA and EC)
        cpub=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null | openssl md5 2>/dev/null | awk '{print $NF}')
        kpub=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl md5 2>/dev/null | awk '{print $NF}')
        [[ -z "$kpub" ]] && kpub=$(openssl rsa -in "$key" -pubout 2>/dev/null | openssl md5 2>/dev/null | awk '{print $NF}')
        if [[ -z "$cpub" || -z "$kpub" || "$cpub" != "$kpub" ]]; then
            log_error "${host}: private key does NOT match the certificate" \
                      "The supplied cert and key are not a pair" \
                      "Re-pair or re-issue the cert+key, then re-validate" \
                      "openssl x509 -in ${cert} -noout -pubkey | openssl md5; openssl pkey -in ${key} -pubout | openssl md5" \
                      "$DOCS_TLS_URL"
            fails=$((fails + 1)); continue
        fi

        # 3. expiry
        exp=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
        if ! openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1; then
            log_error "${host}: certificate is EXPIRED (notAfter ${exp})" \
                      "The cert is past its validity period" \
                      "Obtain a current cert from your CA" \
                      "openssl x509 -in ${cert} -noout -dates" "$DOCS_TLS_URL"
            fails=$((fails + 1)); continue
        fi
        if ! openssl x509 -in "$cert" -noout -checkend 2592000 >/dev/null 2>&1; then
            log_warn "${host}: certificate expires within 30 days (notAfter ${exp}) — plan a renewal"
        fi

        # 4. SAN/CN covers the hostname
        if ! _vc_covers "$cert" "$host"; then
            log_error "${host}: cert SAN/CN does not cover this hostname" \
                      "The cert is valid but not issued for ${host}" \
                      "Issue a cert covering ${host} (or *.<domain>), or fix public_domain / ${svc}_hostname to match the cert" \
                      "openssl x509 -in ${cert} -noout -text | grep -A1 'Subject Alternative Name'" \
                      "$DOCS_TLS_URL"
            fails=$((fails + 1)); continue
        fi

        log_success "  ${svc}: ${host} — OK (key matches, not expired, SAN covers; expires ${exp})"
    done

    if [[ "$fails" -gt 0 ]]; then
        log_error "Cert validation FAILED for ${fails} hostname(s)" \
                  "One or more certs are missing, mismatched, expired, or do not cover the hostname" \
                  "Fix the items above and re-run --validate-certs" \
                  "" "$DOCS_TLS_URL"
        exit 1
    fi
    log_success "All customer TLS certs are valid — safe to install."
}

# ---------------------------------------------------------------------------
# Sanity-check: WG subnet must not overlap private subnet, and all 3 node
# private IPs must fall inside private_subnet.
# ---------------------------------------------------------------------------
check_subnet_overlap() {
    local priv=$(cfg private_subnet)
    local wg=$(cfg wg_subnet)

    # Strip masks for a coarse first-octet comparison — good enough to catch
    # the common mistake of using the same /16 for both.
    local priv_base="${priv%%/*}"
    local wg_base="${wg%%/*}"
    local priv_2="${priv_base%.*.*}"
    local wg_2="${wg_base%.*.*}"

    if [[ "$priv_2" == "$wg_2" ]]; then
        log_error "Subnet overlap: private_subnet (${priv}) and wg_subnet (${wg}) share a prefix" \
                  "Wireguard peers will collide with private IPs" \
                  "Pick a different wg_subnet (e.g. 10.15.0.0/16 if private is 10.0.0.0/16)"
        exit 1
    fi

    # Verify each configured private IP falls inside private_subnet (first
    # two octets — coarse but catches IP-swap mistakes).
    local rp_ip=$(cfg rp_private_ip)
    if [[ -z "$rp_ip" ]]; then rp_ip=$(cfg rp_internal_ip); fi   # legacy alias
    local compute_ip=$(cfg compute_private_ip)
    local storage_ip=$(cfg storage_private_ip)
    for ip in "$rp_ip" "$compute_ip" "$storage_ip"; do
        local ip_2="${ip%.*.*}"
        if [[ "$ip_2" != "$priv_2" ]]; then
            log_warn "IP ${ip} appears to be outside private_subnet ${priv}"
            log_warn "  ufw rules use private_subnet — IPs outside it will be denied"
        fi
    done
}

# ---------------------------------------------------------------------------
probe_all() {
    log_step "0" "SSH probe — verifying access to all nodes"
    ssh_probe rp
    ssh_probe storage
    ssh_probe compute
    log_success "All 3 nodes reachable with passwordless sudo."
}

# ---------------------------------------------------------------------------
# Preflight — runs on all 3 nodes in parallel, aggregates, hard-fail on any
# FAIL line. Use --skip-preflight to bypass.
# ---------------------------------------------------------------------------
preflight_one() {
    local role="$1"
    local outfile="$2"

    # Push only what preflight needs: lib/shared/ + the config file.
    # Reuses the same /tmp/openg2p-deploy/ staging dir as full role bundles.
    {
        ssh_push "$role" "${SCRIPT_DIR}/lib/shared/" "${REMOTE_WORK_DIR}/lib/shared/"
        ssh_run "$role" "mkdir -p ${REMOTE_WORK_DIR} && cat > ${REMOTE_WORK_DIR}/prod-config.yaml" \
            < "$CONFIG_FILE" 2>/dev/null || true
    } >>"$outfile" 2>&1

    # Run preflight. Capture both stdout and exit code.
    local rc=0
    ssh_run "$role" \
        "cd ${REMOTE_WORK_DIR} && bash lib/shared/preflight.sh --role ${role} --config prod-config.yaml" \
        >>"$outfile" 2>&1 || rc=$?

    echo "::EXIT::${rc}" >> "$outfile"
}

preflight_all() {
    log_step "0" "Preflight — resource + network checks on all 3 nodes (parallel)"

    local tmp
    tmp=$(mktemp -d -t openg2p-preflight.XXXXXX)
    # NB: keep tmp around until end of function so we can show captured
    # output on failure. Cleaned up at the end on success.

    # Step 1 — push lib/shared to each node. Sequential foreground pushes
    # with per-node progress so a stall is immediately visible.
    log_info "Pushing preflight bundle to all 3 nodes..."
    for role in storage compute rp; do
        log_info "  → ${role}"
        if ! ssh_push "$role" "${SCRIPT_DIR}/lib/shared/" "${REMOTE_WORK_DIR}/lib/shared/" \
                > "${tmp}/${role}.push" 2>&1; then
            log_error "Failed to push preflight bundle to ${role}" \
                      "ssh/rsync returned non-zero" \
                      "$(cat "${tmp}/${role}.push")" \
                      "" ""
            rm -rf "$tmp"
            exit 1
        fi
    done

    # Step 2 — ship the merged config (prod-config + provision-output overlay).
    local merged="${tmp}/prod-config.yaml"
    cat "$CONFIG_FILE" > "$merged"
    if [[ -n "$PROVISION_OUTPUT" && -f "$PROVISION_OUTPUT" ]]; then
        {
            echo ""
            echo "# ─── merged from provision-output.yaml at preflight time ───"
            cat "$PROVISION_OUTPUT"
        } >> "$merged"
    fi
    log_info "Pushing merged config to all 3 nodes..."
    for role in storage compute rp; do
        log_info "  → ${role}"
        if ! ssh_run "$role" \
                "mkdir -p ${REMOTE_WORK_DIR} && cat > ${REMOTE_WORK_DIR}/prod-config.yaml" \
                < "$merged" > "${tmp}/${role}.cfg" 2>&1; then
            log_error "Failed to ship config to ${role}" \
                      "ssh returned non-zero" \
                      "$(cat "${tmp}/${role}.cfg")" \
                      "" ""
            rm -rf "$tmp"
            exit 1
        fi
    done

    # Step 3 — run preflight on each node. Parallel is fine here because
    # the slowest leg dominates and we already verified push/config worked.
    log_info "Running preflight on all 3 nodes (parallel)..."
    local pre_pids=()
    for role in storage compute rp; do
        (
            ssh_run "$role" \
                "cd ${REMOTE_WORK_DIR} && bash lib/shared/preflight.sh --role ${role} --config prod-config.yaml" \
                > "${tmp}/${role}.out" 2>&1
            echo $? > "${tmp}/${role}.rc"
        ) &
        pre_pids+=($!)
    done
    # Wait per-PID — `wait <pid>` ignores other children (notably the tee
    # subprocess from the script's exec-redirect, which would otherwise hang).
    for pid in "${pre_pids[@]}"; do
        wait "$pid" || true   # status is already captured in ${role}.rc
    done

    # Print all 3 outputs in fixed order.
    local total_fail=0
    for role in storage compute rp; do
        echo ""
        echo -e "${CYAN}── ${role} ─────────────────────────────────────${NC}"
        cat "${tmp}/${role}.out" 2>/dev/null
        local rc
        rc=$(cat "${tmp}/${role}.rc" 2>/dev/null || echo 1)
        if [[ "$rc" != "0" ]]; then
            total_fail=$((total_fail + 1))
        fi
    done
    echo ""

    # Inter-node TCP-22 reachability — WARN-only signal that the private
    # subnet routes between the 3 nodes. Real ports (5432, 2049, 30080)
    # aren't listening yet, so SSH/22 is the only thing reachable.
    log_info "Inter-node connectivity probe (SSH/22 over private subnet)..."
    local storage_ip=$(cfg storage_private_ip)
    local compute_ip=$(cfg compute_private_ip)
    local rp_ip=$(cfg rp_private_ip)
    if [[ -z "$rp_ip" ]]; then rp_ip=$(cfg rp_internal_ip); fi   # legacy alias

    inter_node_probe() {
        local from="$1" to_label="$2" to_ip="$3"
        if ssh_run "$from" \
            "timeout 5 bash -c '</dev/tcp/${to_ip}/22' 2>/dev/null" 2>/dev/null; then
            log_success "  ${from} → ${to_label} (${to_ip}:22) reachable"
        else
            log_warn   "  ${from} → ${to_label} (${to_ip}:22) NOT reachable — SG/firewall may block, install may fail later"
        fi
    }

    inter_node_probe compute storage "$storage_ip"
    inter_node_probe compute rp      "$rp_ip"
    inter_node_probe storage compute "$compute_ip"
    inter_node_probe rp      compute "$compute_ip"
    echo ""

    if [[ $total_fail -gt 0 ]]; then
        # Surface each failing node's [FAIL] lines right above the error
        # banner, so the user doesn't have to scroll up through the per-node
        # preflight output.
        echo ""
        log_warn "Failure summary (full per-node output is above):"
        for role in storage compute rp; do
            local rrc
            rrc=$(cat "${tmp}/${role}.rc" 2>/dev/null || echo 1)
            if [[ "$rrc" != "0" ]]; then
                echo -e "  ${RED}${role}${NC}:"
                grep '^\[FAIL\]' "${tmp}/${role}.out" 2>/dev/null | sed 's/^/    /' \
                    || echo "    (no [FAIL] lines captured — see ${tmp}/${role}.out)"
            fi
        done
        echo ""

        log_error "Preflight failed on ${total_fail} node(s)" \
                  "Resource or environment checks did not pass" \
                  "Fix the [FAIL] items above and re-run, or pass --skip-preflight (advanced)" \
                  "$0 --config $(basename "$CONFIG_FILE") --preflight"
        log_info "Preflight artifacts kept at: ${tmp}"
        exit 1
    fi
    log_success "Preflight passed on all 3 nodes."
    rm -rf "$tmp"
}

run_role_phase() {
    local role="$1"
    local phase="$2"

    local marker="orchestrator/${role}-phase${phase}"
    if [[ "$FORCE_MODE" != "true" ]] && skip_if_done "$marker" "${role} phase ${phase}"; then
        return 0
    fi

    log_step "${role^^} phase ${phase}" "Staging and executing on remote node"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would stage role bundle and run: role/run.sh --phase ${phase}"
        return 0
    fi

    ssh_stage_role "$role" "$SCRIPT_DIR" "$CONFIG_FILE" "$PROVISION_OUTPUT"

    local extra=""
    if [[ "$FORCE_MODE" == "true" ]]; then extra="--force"; fi
    ssh_run_role "$role" --phase "$phase" $extra

    mark_step_done "$marker"
}

# Loudly indicate when a previous run's completion markers exist, so that
# "phases skipped" is never silent. Critical after a re-provision/reset:
# stale laptop state will otherwise skip the whole install (machines stay bare).
notify_existing_state() {
    local dir="${STATE_DIR}/orchestrator"
    local markers=() f
    for f in "$dir"/*.done; do
        [[ -e "$f" ]] || continue
        markers+=("$f")
    done

    if [[ ${#markers[@]} -eq 0 ]]; then
        log_info "No prior orchestrator state found — every phase will run."
        return 0
    fi

    if [[ "$FORCE_MODE" == "true" ]]; then
        log_warn "--force set: ignoring ${#markers[@]} completion marker(s); all phases will RE-RUN."
        return 0
    fi

    local when
    log_warn "════════════════════════════════════════════════════════════════"
    log_warn " ${#markers[@]} phase(s) from a PREVIOUS run are marked complete and"
    log_warn " will be SKIPPED (this is a resume, not a fresh install):"
    for f in "${markers[@]}"; do
        when=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$f" 2>/dev/null \
               || stat -c '%y' "$f" 2>/dev/null | cut -d'.' -f1 \
               || echo '?')
        log_warn "     • $(basename "$f" .done)   (done ${when})"
    done
    log_warn ""
    log_warn " If the machines were RE-PROVISIONED or RESET since then, this state"
    log_warn " is STALE — nothing new will install and you'll get a bare cluster."
    log_warn " Clear it and re-run:"
    log_warn "     ./openg2p-prod.sh --reset-laptop --config <your-config>"
    log_warn " (or pass --force to re-run completed phases in place)"
    log_warn "════════════════════════════════════════════════════════════════"
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    mkdir -p "${SCRIPT_DIR}/logs" "${STATE_DIR}/orchestrator"

    log_banner "OpenG2P 3-Node Production Setup" "Orchestrator · runs on your laptop"

    log_info "Config: ${CONFIG_FILE}"
    log_info "Log:    ${LOG_FILE}"
    echo ""

    load_config "$CONFIG_FILE"

    # Auto-detect provision-output.yaml next to prod-config.yaml unless
    # --provision-output was given explicitly.
    if [[ -z "$PROVISION_OUTPUT" ]]; then
        PROVISION_OUTPUT="$(dirname "$CONFIG_FILE")/provision-output.yaml"
    fi
    if [[ -f "$PROVISION_OUTPUT" ]]; then
        log_info "Loading provision-output overlay: ${PROVISION_OUTPUT}"
        load_config "$PROVISION_OUTPUT"
    else
        PROVISION_OUTPUT=""   # not present — orchestrator behaves as before
        log_info "No provision-output.yaml found — using prod-config.yaml only"
    fi

    # Laptop-only cert validation — needs only cert + hostname config (NOT the
    # node IPs/subnet), so it runs BEFORE the full orchestrator validation and
    # can be used before the VMs are even provisioned. No SSH.
    if [[ "$VALIDATE_CERTS_ONLY" == "true" ]]; then
        validate_certs_deep
        exit 0
    fi

    validate_orchestrator_config

    ssh_init
    trap ssh_cleanup EXIT

    if [[ "$PROBE_ONLY" == "true" ]]; then
        probe_all
        log_success "Probe complete."
        exit 0
    fi

    if [[ "$PREFLIGHT_ONLY" == "true" ]]; then
        probe_all
        preflight_all
        log_success "Preflight complete."
        exit 0
    fi

    # Make any skipped-because-already-done phases visible BEFORE we start.
    notify_existing_state

    case "$RUN_ROLE" in
        all)
            probe_all
            [[ "$SKIP_PREFLIGHT" == "true" ]] || preflight_all
            run_role_phase storage 1
            run_role_phase compute 1
            run_role_phase rp      1
            run_role_phase compute 2
            run_role_phase compute 3
            show_summary
            ;;
        storage)
            ssh_probe storage
            run_role_phase storage "${RUN_PHASE:-1}"
            ;;
        compute)
            ssh_probe compute
            if [[ -n "$RUN_PHASE" ]]; then
                run_role_phase compute "$RUN_PHASE"
            else
                run_role_phase compute 1
                run_role_phase compute 2
                run_role_phase compute 3
            fi
            ;;
        rp)
            ssh_probe rp
            run_role_phase rp "${RUN_PHASE:-1}"
            ;;
    esac

    log_success "Orchestrator run complete."
}

show_summary() {
    local rancher_host=$(get_rancher_hostname 2>/dev/null)
    local keycloak_host=$(get_keycloak_hostname 2>/dev/null)
    local rp_private=$(cfg rp_private_ip)
    [[ -z "$rp_private" ]] && rp_private=$(cfg rp_internal_ip)   # legacy alias
    local rp_user=$(cfg rp_ssh_user ubuntu)
    local rp_host=$(cfg rp_ssh_host)
    if [[ -z "$rp_host" ]]; then rp_host=$(cfg rp_public_ip); fi
    local rp_key=$(cfg rp_ssh_key "~/.ssh/id_rsa")
    local compute_user=$(cfg compute_ssh_user ubuntu)
    local compute_host=$(cfg compute_ssh_host)
    if [[ -z "$compute_host" ]]; then compute_host=$(cfg compute_private_ip); fi
    local kc_email=$(cfg keycloak_admin_email)
    local wg_subnet=$(cfg wg_subnet "10.15.0.0/16")
    local wg_server_ip="${wg_subnet%.*.*/*}.0.1"

    # Live-fetch the local Rancher admin password and Keycloak password from
    # the cluster, so the summary contains exact ready-to-use credentials.
    # Errors here are non-fatal — we just print '<failed to fetch>'.
    local rancher_pw="<failed to fetch — see kubectl command below>"
    local keycloak_pw="<failed to fetch — see kubectl command below>"
    if ssh_run compute "true" >/dev/null 2>&1; then
        rancher_pw=$(ssh_run compute \
            "KUBECONFIG=/etc/rancher/rke2/rke2.yaml /var/lib/rancher/rke2/bin/kubectl -n cattle-system get secret rancher-secret -o jsonpath='{.data.adminPassword}' 2>/dev/null | base64 -d 2>/dev/null" \
            2>/dev/null) || rancher_pw="<failed to fetch>"
        keycloak_pw=$(ssh_run compute \
            "KUBECONFIG=/etc/rancher/rke2/rke2.yaml /var/lib/rancher/rke2/bin/kubectl -n keycloak-system get secret keycloak -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null" \
            2>/dev/null) || keycloak_pw="<failed to fetch>"
        if [[ -z "$rancher_pw"  ]]; then rancher_pw="<empty — secret may not exist>"; fi
        if [[ -z "$keycloak_pw" ]]; then keycloak_pw="<empty — secret may not exist>"; fi
    fi

    # Live-fetch the host PostgreSQL superuser credentials from the storage
    # node. The password is generated by storage phase 1 and saved at
    # /etc/openg2p/secrets/postgres-superuser.env (root-owned, mode 0600).
    # Currently no application uses this DB — it's idle until environment
    # automation creates per-environment databases. Surfacing it here so
    # the operator doesn't have to ssh into storage to find it later.
    local pg_host="$(cfg storage_private_ip)"
    local pg_port="$(cfg postgres_port 5432)"
    local pg_user="postgres"
    local pg_pw="<failed to fetch — sudo cat /etc/openg2p/secrets/postgres-superuser.env on storage>"
    if ssh_run storage "true" >/dev/null 2>&1; then
        local pg_env
        pg_env=$(ssh_run storage "cat /etc/openg2p/secrets/postgres-superuser.env 2>/dev/null" 2>/dev/null) || pg_env=""
        if [[ -n "$pg_env" ]]; then
            local fetched
            fetched=$(echo "$pg_env" | grep '^POSTGRES_PASSWORD=' | head -1 | cut -d= -f2-)
            if [[ -n "$fetched" ]]; then pg_pw="$fetched"; fi
            fetched=$(echo "$pg_env" | grep '^POSTGRES_HOST=' | head -1 | cut -d= -f2-)
            if [[ -n "$fetched" ]]; then pg_host="$fetched"; fi
            fetched=$(echo "$pg_env" | grep '^POSTGRES_PORT=' | head -1 | cut -d= -f2-)
            if [[ -n "$fetched" ]]; then pg_port="$fetched"; fi
        fi
    fi

    cat <<EOF


╔══════════════════════════════════════════════════════════════════════════════╗
║                                                                              ║
║    OpenG2P 3-Node Production Infrastructure — SETUP COMPLETE                 ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝

  ADMIN URLS (reachable only via Wireguard)

    Rancher:    https://${rancher_host}
    Keycloak:   https://${keycloak_host}

  (Grafana and Prometheus are reachable from inside the Rancher UI —
   Cluster Explorer → Monitoring — not on their own hostnames.)

  Each hostname should already resolve to the RP's PRIVATE IP via your
  customer's DNS:  ${rp_private}

  CREDENTIALS — KEEP THESE SAFE

    ┌─ Rancher local admin (use this for the FIRST login) ─────────────────────┐
    │   username:  admin                                                       │
    │   password:  ${rancher_pw}
    └──────────────────────────────────────────────────────────────────────────┘

    ┌─ Keycloak admin (use this AFTER you switch to "Login with Keycloak") ────┐
    │   username:  ${kc_email}
    │   password:  ${keycloak_pw}
    └──────────────────────────────────────────────────────────────────────────┘

    ┌─ PostgreSQL superuser on STORAGE node ───────────────────────────────────┐
    │   (currently idle — environment automation will use this later)          │
    │   host:      ${pg_host}
    │   port:      ${pg_port}
    │   username:  ${pg_user}
    │   password:  ${pg_pw}
    │   on disk:   /etc/openg2p/secrets/postgres-superuser.env  (mode 0600)    │
    └──────────────────────────────────────────────────────────────────────────┘


══════════════════════════════════════════════════════════════════════════════
  WHAT TO DO NEXT — on your laptop
══════════════════════════════════════════════════════════════════════════════

  STEP 1.  Pull the Wireguard peer config and connect

      ssh -i ${rp_key} ${rp_user}@${rp_host} \\
          "sudo cat /etc/wireguard/peers/peer1/peer1.conf" > peer1.conf

      Import peer1.conf into the Wireguard app and activate the tunnel.
      Verify: ping ${wg_server_ip}    (should respond)

  STEP 2.  (Skipped — no local CA)

      You provided customer-supplied certs from your CA. Browsers already
      trust them. If you see a cert warning when first opening Rancher,
      your cert chain is incomplete — re-run --validate-certs to confirm.

  STEP 3.  DNS resolution on your laptop

      Your customer's DNS should already resolve the admin hostnames
      to ${rp_private} (RP's private IP).

      If your customer's DNS isn't reachable from your laptop (no internal
      DNS exposure via WG), add a one-time /etc/hosts entry on your laptop:

        ${rp_private}  ${rancher_host} ${keycloak_host}

      Verify (macOS): dscacheutil -q host -a name ${rancher_host}
      Verify (Linux): getent hosts ${rancher_host}
      Both must return ${rp_private}.

  STEP 4.  Login to Rancher — FIRST TIME (use the LOCAL admin)

      Open:     https://${rancher_host}
      Click:    "Use a local user"   (the small link below the Keycloak button)
      Username: admin
      Password: (the Rancher local admin password from above)

      You're now in the Rancher UI as the local 'admin'.

  STEP 5.  (Optional) From inside Rancher, browse to the keycloak-system
           namespace → Secrets → "keycloak" → reveal the 'admin-password'
           value. This is the same password we already printed above; the
           UI is just a convenient way to retrieve it without using kubectl.

  STEP 6.  Logout, then login again — but this time with KEYCLOAK SSO

      In Rancher: top-right user menu → "Log Out".
      Back at the login page, click the "Login with Keycloak" button.
      You will be redirected to https://${keycloak_host}/...
      Username: ${kc_email}
      Password: (the Keycloak admin password from above)

      After authenticating, Keycloak will redirect you back to Rancher with
      a SAML assertion. Rancher should land you on the home page as the
      Keycloak-authenticated admin user. SAML SSO is now verified working.


══════════════════════════════════════════════════════════════════════════════
  OPTIONAL — kubectl from your laptop (Wireguard must be active)
══════════════════════════════════════════════════════════════════════════════

      mkdir -p ~/.kube
      ssh -i ${rp_key} ${compute_user}@${compute_host} \\
          "sudo cat /etc/rancher/rke2/rke2-remote.yaml" > ~/.kube/openg2p-prod
      chmod 600 ~/.kube/openg2p-prod
      export KUBECONFIG=~/.kube/openg2p-prod
      kubectl get nodes


  Log file:  ${LOG_FILE}

EOF
}

mkdir -p "${SCRIPT_DIR}/logs"
exec > >(tee -a "$LOG_FILE") 2>&1

main "$@"
