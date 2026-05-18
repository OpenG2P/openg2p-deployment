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

# Resolve <service>_hostname for one of: rancher | keycloak | grafana | prometheus
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
get_keycloak_hostname()   { _resolve_admin_hostname keycloak; }
get_grafana_hostname()    { _resolve_admin_hostname grafana; }
get_prometheus_hostname() { _resolve_admin_hostname prometheus; }

# Bridge production flat keys to the dotted keys vendored single-node code reads.
# Call this once after load_config "$CONFIG_FILE".
hostnames_bridge_config_keys() {
    # Only bridge if not already set, so user could override either way.
    if [[ -z "${CONFIG[keycloak.admin_email]:-}" ]]; then
        CONFIG[keycloak.admin_email]="$(cfg 'keycloak_admin_email' '')"
    fi
    if [[ -z "${CONFIG[rancher.version]:-}" ]]; then
        CONFIG[rancher.version]="$(cfg 'rancher_version' '2.12.3')"
    fi
}

# Ensure rancher.<domain> / keycloak.<domain> / grafana.<domain> /
# prometheus.<domain> are in /etc/hosts pointing at the RP's INTERNAL IP —
# required for phase 3's API calls from the compute node, since admin tools
# are reachable only via the RP's vNIC-internal address (which compute
# usually does not have a DNS resolver for).
#
# Idempotent and additive — does not remove unrelated /etc/hosts entries.
ensure_admin_hostnames_in_etc_hosts() {
    local rp_internal
    rp_internal=$(cfg "rp_internal_ip" "")
    if [[ -z "$rp_internal" ]]; then
        # Fall back to old rp_private_ip for backward compatibility during
        # transition; warn if neither is set.
        rp_internal=$(cfg "rp_private_ip" "")
    fi
    if [[ -z "$rp_internal" ]]; then
        log_warn "rp_internal_ip not in config; cannot ensure /etc/hosts entries"
        return 0
    fi
    local host service
    for service in rancher keycloak grafana prometheus; do
        host=$(_resolve_admin_hostname "$service")
        if [[ -z "$host" ]]; then
            log_warn "Cannot resolve hostname for ${service} (set ${service}_hostname or public_domain)"
            continue
        fi
        if ! grep -qE "(^|[[:space:]])${host}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
            echo "${rp_internal} ${host}" >> /etc/hosts
            log_info "Added /etc/hosts entry: ${rp_internal} ${host}"
        fi
    done
}
