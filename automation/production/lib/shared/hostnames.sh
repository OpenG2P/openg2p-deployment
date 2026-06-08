#!/usr/bin/env bash
# =============================================================================
# Shared hostname helpers + config-key bridge
# =============================================================================
# Sourced by compute/RP role scripts AFTER load_config has populated CONFIG[].
# Provides the helpers single-node's phase scripts expect, mapped to the
# production config keys.
#
# As of the rework that drops local CA / dnsmasq, admin hostnames are
# customer-supplied (not openg2p.internal). Resolution order:
#   1. <service>_hostname (explicit)
#   2. <service>.<public_domain> (derived)
#
# Hard fails if neither is set — the customer MUST provide hostnames.
# =============================================================================

# Resolve <service>_hostname for an admin service (currently: rancher).
_resolve_admin_hostname() {
    local service="$1"
    local explicit
    explicit=$(cfg "${service}_hostname")
    if [[ -n "$explicit" ]]; then
        echo "$explicit"
        return 0
    fi
    local domain
    domain=$(cfg "public_domain")
    if [[ -z "$domain" ]]; then
        # Last-ditch fallback so single-node helpers don't crash during
        # config-bridge calls before the script has reached its hard-fail
        # validation. Empty value is a clear-enough signal downstream.
        echo ""
        return 1
    fi
    echo "${service}.${domain}"
}

get_rancher_hostname()    { _resolve_admin_hostname rancher; }

# Bridge production flat keys to the dotted keys vendored single-node code reads.
# Call this once after load_config "$CONFIG_FILE".
hostnames_bridge_config_keys() {
    if [[ -z "${CONFIG[rancher.version]:-}" ]]; then
        CONFIG[rancher.version]="$(cfg 'rancher_version' '2.12.3')"
    fi
}
