#!/usr/bin/env bash
# =============================================================================
# OpenG2P Sandbox — ACME (Let's Encrypt) + DNS provider helpers
# =============================================================================
# The sandbox uses REAL, publicly-trusted certificates from Let's Encrypt.
# Self-signed certs are not supported: in-cluster services call each other over
# HTTPS and fail when the issuing CA is not in the system trust store.
#
# Certificates are obtained with the ACME DNS-01 challenge:
#
#   node ──(1) write TXT _acme-challenge.<name>──▶ DNS provider API
#   node ──(2) "please issue <name>"─────────────▶ Let's Encrypt
#                            Let's Encrypt ──(3) DNS query──▶ DNS provider
#   node ◀──(4) signed certificate──────────────── Let's Encrypt
#
# Let's Encrypt never connects back to this machine, so NO inbound connectivity
# is required — only outbound HTTPS. That is what makes this work on-prem and
# behind NAT.
#
# ACME client: acme.sh. Chosen over certbot because it ships every DNS provider
# we support behind one uniform interface (`--dns dns_<x>` + env vars), is a
# single POSIX shell script with no Python/venv dependency, and persists both
# the DNS credentials and the nginx reload command so renewals are automatic.
#
# Sourced by roles/infra/run.sh and roles/environment/run.sh (issuance), and by
# openg2p-sandbox.sh (laptop-side preflight). Depends only on cfg, log_*,
# curl and coreutils — deliberately no jq, so the laptop needs nothing extra.
# =============================================================================

# Pinned acme.sh release — bump deliberately, not automatically.
ACME_VERSION="3.1.4"
ACME_HOME="/opt/acme.sh"
ACME_CONFIG_HOME="/opt/acme.sh/data"
ACME_BIN="${ACME_HOME}/acme.sh"

# Where issued certs are installed. Kept identical to the previous layout so
# the Nginx templates and get_cert_path() are unchanged.
OPENG2P_CERTS_DIR="/etc/openg2p/certs"

DESEC_API="https://desec.io/api/v1"

# Reserved / special-use TLDs. A public CA can never issue for these — this is
# a CA/Browser Forum rule ("internal names"), not a Let's Encrypt policy.
ACME_RESERVED_TLDS="test local localhost internal invalid example home lan corp"

# ─────────────────────────────────────────────────────────────────────────────
# Domain helpers
# ─────────────────────────────────────────────────────────────────────────────
acme_domain() { cfg "domain" ""; }

# True when the domain ends in a TLD that can never receive a public cert.
acme_domain_is_reserved() {
    local domain="${1:-$(acme_domain)}"
    local tld="${domain##*.}"
    local reserved
    for reserved in $ACME_RESERVED_TLDS; do
        [[ "$tld" == "$reserved" ]] && return 0
    done
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Provider plumbing
# ─────────────────────────────────────────────────────────────────────────────
# acme.sh DNS hook name for the configured provider.
acme_dns_hook() {
    case "$(cfg 'tls.dns_provider' 'desec')" in
        desec)      echo "dns_desec"   ;;
        cloudflare) echo "dns_cf"      ;;
        route53)    echo "dns_aws"     ;;
        acmedns)    echo "dns_acmedns" ;;
        *)          echo "" ;;
    esac
}

# Export the credential environment variables acme.sh expects for the provider.
# acme.sh persists these into its own config on first use, so renewals work
# without re-exporting.
acme_export_provider_creds() {
    local provider=$(cfg 'tls.dns_provider' 'desec')
    case "$provider" in
        desec)
            export DEDYN_TOKEN="$(cfg 'tls.api_token' '')"
            ;;
        cloudflare)
            export CF_Token="$(cfg 'tls.api_token' '')"
            export CF_Account_ID="$(cfg 'tls.cf_account_id' '')"
            ;;
        route53)
            # Blank credentials are valid: acme.sh falls back to the EC2
            # instance role, which is the common case on AWS.
            local ak=$(cfg 'tls.aws_access_key_id' '')
            local sk=$(cfg 'tls.aws_secret_access_key' '')
            [[ -n "$ak" ]] && export AWS_ACCESS_KEY_ID="$ak"
            [[ -n "$sk" ]] && export AWS_SECRET_ACCESS_KEY="$sk"
            ;;
        acmedns)
            export ACMEDNS_BASE_URL="$(cfg 'tls.acmedns_base_url' 'https://auth.acme-dns.io')"
            export ACMEDNS_USERNAME="$(cfg 'tls.acmedns_username' '')"
            export ACMEDNS_PASSWORD="$(cfg 'tls.acmedns_password' '')"
            export ACMEDNS_SUBDOMAIN="$(cfg 'tls.acmedns_subdomain' '')"
            ;;
        *)
            log_error "Unknown tls.dns_provider: '${provider}'" \
                      "Valid values: desec, cloudflare, route53, acmedns" \
                      "Fix tls.dns_provider in your config file"
            return 1
            ;;
    esac
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Preflight — validate DNS/TLS prerequisites BEFORE anything is installed
# ─────────────────────────────────────────────────────────────────────────────
# Runs on the laptop (orchestrator) and again on-box. Fails fast and loudly:
# a wrong token here would otherwise surface 20 minutes into the install.
acme_preflight() {
    local domain=$(acme_domain)
    local email=$(cfg 'tls.email' '')
    local provider=$(cfg 'tls.dns_provider' 'desec')
    local errors=0

    log_info "Validating DNS / TLS prerequisites..."

    # ── Domain ───────────────────────────────────────────────────────────
    if [[ -z "$domain" ]]; then
        log_error "'domain' is not set" \
                  "The sandbox needs a REAL registered domain for Let's Encrypt to certify" \
                  "Get a free one in ~2 min: sign up at https://desec.io/, create e.g. mydept.dedyn.io, then set 'domain' in your config" \
                  "" \
                  "https://desec.io/"
        return 1
    fi

    if acme_domain_is_reserved "$domain"; then
        log_error "'domain' uses a reserved TLD: ${domain}" \
                  "No public CA can ever issue a certificate for .${domain##*.} — this is a CA/Browser Forum rule, not a Let's Encrypt limitation" \
                  "Use a real registered domain. Free option: sign up at https://desec.io/ and create <name>.dedyn.io" \
                  "" \
                  "https://desec.io/"
        return 1
    fi

    if [[ "$domain" != *.* ]]; then
        log_error "'domain' does not look like a domain name: ${domain}" \
                  "Expected something like mydept.dedyn.io" \
                  "Fix 'domain' in your config file"
        return 1
    fi
    log_success "Domain: ${domain}"

    # ── Let's Encrypt account email ──────────────────────────────────────
    if [[ -z "$email" ]]; then
        log_error "'tls.email' is not set" \
                  "Let's Encrypt requires a contact address for expiry notices" \
                  "Set tls.email in your config file"
        ((errors++))
    elif [[ ! "$email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        log_error "'tls.email' is not a valid email address: ${email}" \
                  "Let's Encrypt will reject the account registration" \
                  "Fix tls.email in your config file"
        ((errors++))
    fi

    # ── Provider credentials ─────────────────────────────────────────────
    case "$provider" in
        desec)
            if [[ -z "$(cfg 'tls.api_token' '')" ]]; then
                log_error "'tls.api_token' is not set (dns_provider: desec)" \
                          "A deSEC API token is required to write the ACME challenge record" \
                          "Create one at https://desec.io/tokens and set tls.api_token" \
                          "" \
                          "https://desec.io/tokens"
                ((errors++))
            fi
            ;;
        cloudflare)
            [[ -z "$(cfg 'tls.api_token' '')" ]] && {
                log_error "'tls.api_token' is not set (dns_provider: cloudflare)" \
                          "A Cloudflare API token with DNS:Edit on the zone is required" \
                          "Create a scoped token and set tls.api_token"
                ((errors++)); }
            ;;
        route53)
            if [[ -z "$(cfg 'tls.aws_access_key_id' '')" ]]; then
                log_info "  route53: no static keys set — will use the EC2 instance role."
            fi
            ;;
        acmedns)
            [[ -z "$(cfg 'tls.acmedns_username' '')" ]] && {
                log_error "acme-dns credentials incomplete (dns_provider: acmedns)" \
                          "tls.acmedns_username / acmedns_password / acmedns_subdomain are required" \
                          "Register with your acme-dns server and fill in the tls.acmedns_* fields"
                ((errors++)); }
            ;;
        *)
            log_error "Unknown tls.dns_provider: '${provider}'" \
                      "Valid values: desec, cloudflare, route53, acmedns" \
                      "Fix tls.dns_provider in your config file"
            ((errors++))
            ;;
    esac

    [[ $errors -gt 0 ]] && return 1

    # ── Live credential check (deSEC only — it is the quick-start path) ──
    if [[ "$provider" == "desec" ]]; then
        acme_preflight_desec "$domain" || return 1
    else
        log_warn "Credentials for '${provider}' are not verified live — a wrong token will surface during issuance."
    fi

    # ── Staging notice ───────────────────────────────────────────────────
    if [[ "$(cfg 'tls.staging' 'false')" == "true" ]]; then
        log_warn "tls.staging is TRUE — certificates will come from the Let's Encrypt STAGING CA."
        log_warn "  These are NOT publicly trusted. Browsers and in-cluster services will still warn/fail."
        log_warn "  Set tls.staging: false and re-run with --force for real certificates."
    fi

    log_success "DNS / TLS prerequisites satisfied."
    return 0
}

# Verify the deSEC token works AND the domain exists in that account.
# This is the single highest-value check: it catches the two mistakes users
# actually make (typo'd token, domain never created).
acme_preflight_desec() {
    local domain="$1"
    local token=$(cfg 'tls.api_token' '')

    if ! command -v curl >/dev/null 2>&1; then
        log_warn "curl not available — skipping the live deSEC check."
        return 0
    fi

    log_info "  Verifying deSEC token and domain '${domain}'..."

    local body http_code
    body=$(curl -sS --max-time 20 -w '\n%{http_code}' \
        -H "Authorization: Token ${token}" \
        "${DESEC_API}/domains/${domain}/" 2>/dev/null) || {
        log_error "Could not reach the deSEC API" \
                  "No network path to ${DESEC_API} from this machine" \
                  "Check outbound HTTPS/internet access, then re-run" \
                  "curl -sS ${DESEC_API}/domains/"
        return 1
    }
    http_code=$(echo "$body" | tail -1)

    case "$http_code" in
        200)
            log_success "  deSEC token valid; domain '${domain}' found."
            return 0
            ;;
        401|403)
            log_error "deSEC rejected the API token (HTTP ${http_code})" \
                      "tls.api_token is wrong, expired, or lacks permission" \
                      "Create a fresh token at https://desec.io/tokens and update tls.api_token" \
                      "" \
                      "https://desec.io/tokens"
            return 1
            ;;
        404)
            log_error "Domain '${domain}' does not exist in your deSEC account" \
                      "The token is valid, but no such domain is registered to it" \
                      "Create the domain at https://desec.io/domains (it must match 'domain' exactly), then re-run" \
                      "" \
                      "https://desec.io/domains"
            return 1
            ;;
        *)
            log_error "Unexpected response from deSEC (HTTP ${http_code})" \
                      "Could not confirm the token/domain are usable" \
                      "Check https://desec.io/ status and your config, then re-run"
            return 1
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Publish A records so hostnames resolve without any local DNS server
# ─────────────────────────────────────────────────────────────────────────────
# Usage: acme_publish_a_record <subname> <ip>
#   subname is relative to `domain`, e.g. "rancher" or "*.dev" ("" = apex).
#
# Only implemented for deSEC (the quick-start path). For cloudflare/route53/
# acmedns the operator already runs their own DNS, so we print exactly what to
# create rather than pretending to manage their zone.
acme_publish_a_record() {
    local subname="$1"
    local ip="$2"
    local domain=$(acme_domain)
    local provider=$(cfg 'tls.dns_provider' 'desec')

    if [[ "$(cfg 'tls.publish_a_records' 'true')" != "true" ]]; then
        log_info "tls.publish_a_records is false — skipping A record for ${subname:-@}.${domain}"
        return 0
    fi

    local fqdn="${subname:+${subname}.}${domain}"

    if [[ "$provider" != "desec" ]]; then
        log_warn "A-record publishing is automated for deSEC only."
        log_warn "  Create this record in your '${provider}' zone manually:"
        log_warn "      ${fqdn}   A   ${ip}"
        return 0
    fi

    local token=$(cfg 'tls.api_token' '')
    log_info "Publishing DNS A record: ${fqdn} -> ${ip}"

    # Bulk endpoint: upserts, and avoids URL-encoding '*' into a path segment.
    local payload http_code body
    payload=$(printf '[{"subname":"%s","type":"A","ttl":3600,"records":["%s"]}]' "$subname" "$ip")

    body=$(curl -sS --max-time 30 -w '\n%{http_code}' -X PUT \
        -H "Authorization: Token ${token}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${DESEC_API}/domains/${domain}/rrsets/" 2>/dev/null) || {
        log_error "Failed to reach the deSEC API while publishing ${fqdn}" \
                  "Network error talking to ${DESEC_API}" \
                  "Check outbound internet access and re-run this phase"
        return 1
    }
    http_code=$(echo "$body" | tail -1)

    if [[ "$http_code" =~ ^2 ]]; then
        log_success "DNS: ${fqdn} -> ${ip} (TTL 3600)"
        return 0
    fi

    log_error "deSEC rejected the A record for ${fqdn} (HTTP ${http_code})" \
              "Response: $(echo "$body" | head -n -1 | head -c 300)" \
              "Verify tls.api_token has write access to '${domain}', then re-run" \
              "" \
              "https://desec.io/domains"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# acme.sh installation
# ─────────────────────────────────────────────────────────────────────────────
acme_install_client() {
    if [[ -x "$ACME_BIN" ]]; then
        log_success "acme.sh already installed at ${ACME_BIN}."
        return 0
    fi

    log_info "Installing acme.sh ${ACME_VERSION}..."

    # acme.sh refuses to install without crontab (it registers the renewal
    # job there). Ubuntu minimal/cloud images often ship without cron.
    if ! command -v crontab >/dev/null 2>&1; then
        log_info "Installing cron (required by acme.sh for auto-renewal)..."
        apt-get install -y -qq cron > /dev/null 2>&1 || {
            log_error "Failed to install cron" \
                      "acme.sh needs crontab to schedule certificate renewal" \
                      "Install it manually: apt-get install -y cron"
            return 1
        }
        systemctl enable --now cron > /dev/null 2>&1 || true
    fi

    local tarball="/tmp/acme.sh-${ACME_VERSION}.tar.gz"
    local srcdir="/tmp/acme.sh-${ACME_VERSION}"
    rm -rf "$srcdir"

    curl -fsSL -o "$tarball" \
        "https://github.com/acmesh-official/acme.sh/archive/refs/tags/${ACME_VERSION}.tar.gz" || {
        log_error "Failed to download acme.sh ${ACME_VERSION}" \
                  "Could not fetch the release tarball from GitHub" \
                  "Check outbound internet access, then re-run" \
                  "curl -fsSL https://github.com/acmesh-official/acme.sh/archive/refs/tags/${ACME_VERSION}.tar.gz -o /tmp/acme.tar.gz"
        return 1
    }

    tar -xzf "$tarball" -C /tmp || {
        log_error "Failed to extract the acme.sh tarball" "" "Re-run to retry"
        return 1
    }

    ( cd "$srcdir" && ./acme.sh --install \
        --home "$ACME_HOME" \
        --config-home "$ACME_CONFIG_HOME" \
        --cert-home "${ACME_HOME}/certs" \
        -m "$(cfg 'tls.email' '')" \
        --no-profile > /dev/null 2>&1 ) || {
        log_error "acme.sh installation failed" \
                  "The installer returned a non-zero status" \
                  "Try manually: cd ${srcdir} && ./acme.sh --install --home ${ACME_HOME}"
        return 1
    }

    rm -rf "$tarball" "$srcdir"

    # acme.sh defaults to ZeroSSL — pin the default CA to Let's Encrypt.
    "$ACME_BIN" --set-default-ca --server letsencrypt \
        --home "$ACME_HOME" --config-home "$ACME_CONFIG_HOME" > /dev/null 2>&1 || true

    # Credentials land in account.conf; acme.sh sets 600/700 at creation, but
    # tighten defensively in case the directories pre-existed.
    chown -R root:root "$ACME_HOME" 2>/dev/null || true
    chmod 700 "$ACME_HOME" "$ACME_CONFIG_HOME" 2>/dev/null || true
    chmod 600 "${ACME_CONFIG_HOME}/account.conf" 2>/dev/null || true

    log_success "acme.sh ${ACME_VERSION} installed (auto-renewal cron registered)."
}

# ─────────────────────────────────────────────────────────────────────────────
# Certificate issuance
# ─────────────────────────────────────────────────────────────────────────────
# Usage: acme_issue_cert <install_name> <primary_fqdn> [additional_fqdn ...]
#
#   install_name  directory under /etc/openg2p/certs/ to install into. Callers
#                 pass the hostname (infra) or base domain (environment) so
#                 get_cert_path() keeps working unchanged.
#   primary_fqdn  MUST be a non-wildcard name — acme.sh names its internal
#                 state directory after the first -d, and a literal '*' in a
#                 path is a persistent nuisance.
#
# Idempotent: acme.sh skips re-issuance while the cert is still fresh, unless
# FORCE_MODE is set.
acme_issue_cert() {
    local install_name="$1"; shift
    local primary="$1"
    local dest="${OPENG2P_CERTS_DIR}/${install_name}"

    if [[ -z "$primary" ]]; then
        log_error "acme_issue_cert called without a domain" "" "This is a bug in the automation"
        return 1
    fi

    acme_export_provider_creds || return 1

    local hook=$(acme_dns_hook)
    if [[ -z "$hook" ]]; then
        log_error "No acme.sh DNS hook for provider '$(cfg 'tls.dns_provider' 'desec')'" \
                  "" "Fix tls.dns_provider in your config file"
        return 1
    fi

    # Build -d args
    local -a domain_args=()
    local d
    for d in "$@"; do
        domain_args+=(-d "$d")
    done

    local -a extra_args=()
    [[ "$(cfg 'tls.staging' 'false')" == "true" ]] && extra_args+=(--staging)
    [[ "${FORCE_MODE:-false}" == "true" ]] && extra_args+=(--force)

    log_info "Requesting certificate for: $*"
    log_info "  (DNS-01 via ${hook} — outbound only, no inbound connectivity needed)"

    # The calling script already redirects stdout/stderr through tee, so
    # acme.sh's progress lands in the log without piping here (which would
    # otherwise mask its exit status behind tee's).
    local rc=0
    "$ACME_BIN" --issue \
        --dns "$hook" \
        "${domain_args[@]}" \
        --server letsencrypt \
        --keylength ec-256 \
        --home "$ACME_HOME" --config-home "$ACME_CONFIG_HOME" \
        "${extra_args[@]}" || rc=$?

    # rc 2 == "skipped, cert still valid" — treat as success.
    if [[ $rc -ne 0 && $rc -ne 2 ]]; then
        log_error "Certificate issuance failed for ${primary}" \
                  "acme.sh exited with status ${rc}" \
                  "Common causes: wrong DNS API token, the domain is not in that DNS account, or no outbound internet access" \
                  "${ACME_BIN} --issue --dns ${hook} -d ${primary} --server letsencrypt --home ${ACME_HOME} --config-home ${ACME_CONFIG_HOME} --debug"
        return 1
    fi

    # Install into the stable path the Nginx config reads, and register the
    # reload command. acme.sh persists the reloadcmd, so every future renewal
    # re-installs here and reloads Nginx automatically.
    mkdir -p "$dest"
    "$ACME_BIN" --install-cert -d "$primary" --ecc \
        --key-file       "${dest}/privkey.pem" \
        --fullchain-file "${dest}/fullchain.pem" \
        --reloadcmd      "systemctl reload nginx 2>/dev/null || true" \
        --home "$ACME_HOME" --config-home "$ACME_CONFIG_HOME" > /dev/null 2>&1 || {
        log_error "Failed to install the issued certificate to ${dest}" \
                  "acme.sh --install-cert returned an error" \
                  "Check ${ACME_HOME}/certs/${primary}_ecc/ for the issued files"
        return 1
    }

    chmod 600 "${dest}/privkey.pem" 2>/dev/null || true
    log_success "Certificate installed: ${dest}/fullchain.pem"
    return 0
}
