#!/usr/bin/env bash
# =============================================================================
# OpenG2P Deployment Automation — Phase 3: Rancher-Keycloak Integration
# =============================================================================
# Automates Step 11 from the infrastructure setup guide:
#   - Bootstrap Rancher admin password
#   - Configure Keycloak admin email and realm settings
#   - Create SAML client on Keycloak for Rancher
#   - Configure Rancher to use Keycloak SAML as auth provider
#
# Rancher admin password resolution (no password in config file):
#   1. Environment variable RANCHER_ADMIN_PASSWORD
#   2. K8s secret cattle-system/rancher-secret (from previous run)
#   3. Bootstrap password from K8s secret (fresh install) → auto-generate
#   4. Force reset via kubectl exec (user changed password manually)
#
# Ref: https://docs.openg2p.org/deployment/base-infrastructure/rancher#rancher-keycloak-integration
# Sourced by openg2p-infra.sh — do not run directly.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Helper: get Keycloak admin access token
# ─────────────────────────────────────────────────────────────────────────────
keycloak_get_token() {
    local kc_url="$1"
    local kc_password="$2"
    local kc_username="${3:-}"

    # If username not specified, try email-as-username first (the state after
    # our script enables it), then fall back to plain "admin"
    local token_response token
    local usernames_to_try

    # Try the provided email/username first (works after email-as-username is enabled),
    # then fall back to "admin" (works on fresh installs before email is configured)
    if [[ -n "$kc_username" && "$kc_username" != "admin" ]]; then
        usernames_to_try=("$kc_username" "admin")
    else
        usernames_to_try=("admin")
    fi

    for uname in "${usernames_to_try[@]}"; do
        token_response=$(curl -sk -X POST "${kc_url}/realms/master/protocol/openid-connect/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "username=${uname}" \
            -d "password=${kc_password}" \
            -d "grant_type=password" \
            -d "client_id=admin-cli" 2>/dev/null)
        token=$(echo "$token_response" | jq -r '.access_token // empty')
        if [[ -n "$token" ]]; then
            echo "$token"
            return 0
        fi
    done

    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Keycloak Admin API call
# ─────────────────────────────────────────────────────────────────────────────
keycloak_api() {
    local method="$1"
    local url="$2"
    local token="$3"
    local data="${4:-}"

    if [[ -n "$data" ]]; then
        curl -sk -X "$method" "$url" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$data" 2>/dev/null
    else
        curl -sk -X "$method" "$url" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" 2>/dev/null
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Rancher API call
# ─────────────────────────────────────────────────────────────────────────────
rancher_api() {
    local method="$1"
    local url="$2"
    local token="$3"
    local data="${4:-}"

    if [[ -n "$data" ]]; then
        curl -sk -X "$method" "$url" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "$data" 2>/dev/null
    else
        curl -sk -X "$method" "$url" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" 2>/dev/null
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Try Rancher login, return token or empty
# ─────────────────────────────────────────────────────────────────────────────
rancher_try_login() {
    local url="$1"
    local password="$2"
    local response
    response=$(curl -sk -X POST "${url}/v3-public/localProviders/local?action=login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"admin\",\"password\":\"${password}\"}" 2>/dev/null)
    echo "$response" | jq -r '.token // empty'
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: Rancher-Keycloak SAML integration
# ─────────────────────────────────────────────────────────────────────────────
run_phase3() {
    local step_id="phase3.rancher_keycloak"

    if is_step_done "$step_id" && [[ "$FORCE_MODE" != "true" ]]; then
        log_info "Skipping Rancher-Keycloak integration — already completed."
        return 0
    fi

    log_step "3" "Phase 3 — Rancher-Keycloak SAML Integration"

    ensure_kubeconfig || return 1

    local rancher_host=$(get_rancher_hostname)
    local keycloak_host=$(get_keycloak_hostname)
    local rancher_url="https://${rancher_host}"
    local keycloak_url="https://${keycloak_host}"
    local admin_email=$(cfg "keycloak.admin_email" "admin@openg2p.org")

    # ── Step 3.1: Wait for Rancher and Keycloak to be ready ──────────────
    log_info "Waiting for Rancher and Keycloak to be fully ready..."

    wait_for_command "Rancher deployment ready" \
        "kubectl -n cattle-system rollout status deployment/rancher --timeout=5s" \
        600 15 || {
        log_error "Rancher is not ready" \
                  "Rancher deployment did not become available" \
                  "Check Rancher pods" \
                  "kubectl -n cattle-system get pods"
        return 1
    }

    wait_for_command "Keycloak pods ready" \
        "kubectl -n keycloak-system get pods -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' | grep -q True" \
        600 15 || {
        log_error "Keycloak is not ready" \
                  "Keycloak pods did not become available" \
                  "Check Keycloak pods" \
                  "kubectl -n keycloak-system get pods"
        return 1
    }

    sleep 10

    # ── Step 3.2: Bootstrap Rancher admin password ───────────────────────
    log_info "Bootstrapping Rancher admin password..."

    local rancher_admin_password=""
    local rancher_token=""

    # Source 1: Environment variable
    if [[ -n "${RANCHER_ADMIN_PASSWORD:-}" ]]; then
        rancher_admin_password="$RANCHER_ADMIN_PASSWORD"
        log_info "Trying password from RANCHER_ADMIN_PASSWORD env var..."
        rancher_token=$(rancher_try_login "$rancher_url" "$rancher_admin_password")
        if [[ -n "$rancher_token" ]]; then
            log_success "Rancher login successful (source: env var)."
        else
            log_warn "Env var password didn't work."
            rancher_admin_password=""
        fi
    fi

    # Source 2: K8s secret from previous script run
    if [[ -z "$rancher_token" ]]; then
        local secret_password
        secret_password=$(kubectl -n cattle-system get secret rancher-secret \
            -o jsonpath='{.data.adminPassword}' 2>/dev/null | base64 -d 2>/dev/null)
        if [[ -n "$secret_password" ]]; then
            log_info "Trying password from K8s secret cattle-system/rancher-secret..."
            rancher_token=$(rancher_try_login "$rancher_url" "$secret_password")
            if [[ -n "$rancher_token" ]]; then
                rancher_admin_password="$secret_password"
                log_success "Rancher login successful (source: K8s secret)."
            else
                log_warn "K8s secret password didn't work."
            fi
        fi
    fi

    # Source 3: Bootstrap password (fresh install)
    if [[ -z "$rancher_token" ]]; then
        log_info "Trying bootstrap password (fresh install)..."
        local bootstrap_password
        bootstrap_password=$(kubectl -n cattle-system get secret bootstrap-secret \
            -o jsonpath='{.data.bootstrapPassword}' 2>/dev/null | base64 -d 2>/dev/null)

        if [[ -z "$bootstrap_password" ]]; then
            bootstrap_password=$(kubectl -n cattle-system get pods -l app=rancher \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | \
                xargs -I{} kubectl -n cattle-system logs {} 2>/dev/null | \
                grep "Bootstrap Password:" | head -1 | awk '{print $NF}')
        fi

        if [[ -n "$bootstrap_password" ]]; then
            rancher_token=$(rancher_try_login "$rancher_url" "$bootstrap_password")
            if [[ -n "$rancher_token" ]]; then
                # Bootstrap worked — auto-generate a proper password
                rancher_admin_password="openg2p-$(openssl rand -hex 8)"
                log_info "Bootstrap login successful. Setting new admin password..."
                curl -sk -X POST "${rancher_url}/v3/users?action=changepassword" \
                    -H "Authorization: Bearer ${rancher_token}" \
                    -H "Content-Type: application/json" \
                    -d "{\"currentPassword\":\"${bootstrap_password}\",\"newPassword\":\"${rancher_admin_password}\"}" \
                    > /dev/null 2>&1
                # Re-login with new password
                rancher_token=$(rancher_try_login "$rancher_url" "$rancher_admin_password")
                log_success "Rancher admin password auto-generated and set."
            else
                log_warn "Bootstrap password didn't work either."
            fi
        fi
    fi

    # Source 4: Force reset via kubectl exec
    if [[ -z "$rancher_token" ]]; then
        log_warn "All passwords failed. Force-resetting via kubectl exec..."
        local reset_output
        reset_output=$(kubectl -n cattle-system exec deploy/rancher -- reset-password 2>/dev/null)
        local reset_password
        reset_password=$(echo "$reset_output" | tail -1 | tr -d '[:space:]')

        if [[ -n "$reset_password" ]]; then
            rancher_token=$(rancher_try_login "$rancher_url" "$reset_password")
            if [[ -n "$rancher_token" ]]; then
                rancher_admin_password="openg2p-$(openssl rand -hex 8)"
                log_info "Reset successful. Setting new admin password..."
                curl -sk -X POST "${rancher_url}/v3/users?action=changepassword" \
                    -H "Authorization: Bearer ${rancher_token}" \
                    -H "Content-Type: application/json" \
                    -d "{\"currentPassword\":\"${reset_password}\",\"newPassword\":\"${rancher_admin_password}\"}" \
                    > /dev/null 2>&1
                rancher_token=$(rancher_try_login "$rancher_url" "$rancher_admin_password")
                log_success "Rancher admin password reset and updated."
            fi
        fi
    fi

    # Final check
    if [[ -z "$rancher_token" ]]; then
        log_error "Cannot login to Rancher" \
                  "All methods failed (env var, K8s secret, bootstrap, kubectl reset)" \
                  "Try: RANCHER_ADMIN_PASSWORD=yourpass sudo $0 --config ... --phase 3" \
                  "Or: kubectl -n cattle-system exec -it deploy/rancher -- reset-password"
        return 1
    fi

    # Set server URL
    rancher_api PUT "${rancher_url}/v3/settings/server-url" "$rancher_token" \
        "{\"value\":\"${rancher_url}\"}" > /dev/null 2>&1

    # Save password to K8s secret for future runs
    kubectl -n cattle-system create secret generic rancher-secret \
        --from-literal=adminPassword="${rancher_admin_password}" \
        --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

    log_success "Rancher admin ready. Password saved to cattle-system/rancher-secret."

    # ── Step 3.3: Get Keycloak admin password ────────────────────────────
    log_info "Retrieving Keycloak admin credentials..."

    local kc_admin_password
    kc_admin_password=$(kubectl -n keycloak-system get secret keycloak \
        -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null)

    if [[ -z "$kc_admin_password" ]]; then
        log_error "Could not retrieve Keycloak admin password" \
                  "The keycloak secret in keycloak-system namespace may not exist" \
                  "Check Keycloak secrets" \
                  "kubectl -n keycloak-system get secrets"
        return 1
    fi
    log_success "Retrieved Keycloak admin password."

    local kc_token
    kc_token=$(keycloak_get_token "$keycloak_url" "$kc_admin_password" "$admin_email")

    if [[ -z "$kc_token" ]]; then
        log_error "Could not get Keycloak admin access token" \
                  "Login to Keycloak Admin API failed" \
                  "Check Keycloak is accessible" \
                  "curl -sk ${keycloak_url}/realms/master/.well-known/openid-configuration"
        return 1
    fi
    log_success "Keycloak admin token acquired."

    # ── Step 3.4: Configure Keycloak admin email ─────────────────────────
    log_info "Configuring Keycloak admin user email..."

    # Find admin user — try by username "admin" first, then by email
    local admin_users admin_user_id
    admin_users=$(keycloak_api GET "${keycloak_url}/admin/realms/master/users?username=admin&exact=true" "$kc_token")
    admin_user_id=$(echo "$admin_users" | jq -r '.[0].id // empty')

    if [[ -z "$admin_user_id" ]]; then
        # With email-as-username enabled, search by email
        admin_users=$(keycloak_api GET "${keycloak_url}/admin/realms/master/users?email=${admin_email}&exact=true" "$kc_token")
        admin_user_id=$(echo "$admin_users" | jq -r '.[0].id // empty')
    fi

    if [[ -z "$admin_user_id" ]]; then
        # Last resort: get all users and find one with admin role
        admin_users=$(keycloak_api GET "${keycloak_url}/admin/realms/master/users?max=50" "$kc_token")
        admin_user_id=$(echo "$admin_users" | jq -r '.[0].id // empty')
    fi

    if [[ -z "$admin_user_id" ]]; then
        log_error "Could not find Keycloak admin user" \
                  "Searched by username 'admin' and email '${admin_email}'" \
                  "Check Keycloak users" \
                  "curl -sk ${keycloak_url}/admin/realms/master/users -H 'Authorization: Bearer TOKEN'"
        return 1
    fi

    keycloak_api PUT "${keycloak_url}/admin/realms/master/users/${admin_user_id}" "$kc_token" \
        "{\"email\":\"${admin_email}\",\"emailVerified\":true,\"firstName\":\"Admin\",\"lastName\":\"User\"}" \
        > /dev/null 2>&1

    log_success "Keycloak admin email set to ${admin_email}."

    # ── Step 3.5: Enable email-as-username in master realm ───────────────
    log_info "Enabling 'email as username' in master realm..."

    keycloak_api PUT "${keycloak_url}/admin/realms/master" "$kc_token" \
        "{\"registrationEmailAsUsername\":true}" > /dev/null 2>&1

    log_success "Email-as-username enabled in master realm."

    # ── Step 3.6: Create SAML client for Rancher on Keycloak ─────────────
    log_info "Creating SAML client for Rancher on Keycloak..."

    local saml_client_id="https://${rancher_host}/v1-saml/keycloak/saml/metadata"
    local saml_acs_url="https://${rancher_host}/v1-saml/keycloak/saml/acs"

    # Check if client already exists (search all clients and filter by clientId)
    local all_clients existing_client_id
    all_clients=$(keycloak_api GET "${keycloak_url}/admin/realms/master/clients?max=200" "$kc_token")
    existing_client_id=$(echo "$all_clients" | jq -r --arg cid "$saml_client_id" '.[] | select(.clientId == $cid) | .id' 2>/dev/null | head -1)

    if [[ -n "$existing_client_id" ]]; then
        log_info "SAML client already exists on Keycloak — updating."
    fi

    local saml_client_payload
    saml_client_payload=$(cat <<JSONEOF
{
    "clientId": "${saml_client_id}",
    "name": "rancher",
    "enabled": true,
    "protocol": "saml",
    "rootUrl": "${rancher_url}",
    "adminUrl": "${saml_acs_url}",
    "baseUrl": "/",
    "redirectUris": ["${rancher_url}/*"],
    "attributes": {
        "saml_force_name_id_format": "true",
        "saml.force.post.binding": "true",
        "saml.multivalued.roles": "false",
        "saml.encrypt": "false",
        "saml.server.signature": "true",
        "saml.server.signature.keyinfo.ext": "false",
        "saml.signing.certificate": "",
        "saml.assertion.signature": "true",
        "saml_name_id_format": "username",
        "saml.client.signature": "false",
        "saml.authnstatement": "true",
        "saml_signature_canonicalization_method": "http://www.w3.org/2001/10/xml-exc-c14n#"
    },
    "fullScopeAllowed": true,
    "frontchannelLogout": true
}
JSONEOF
)

    if [[ -n "$existing_client_id" ]]; then
        keycloak_api PUT "${keycloak_url}/admin/realms/master/clients/${existing_client_id}" \
            "$kc_token" "$saml_client_payload" > /dev/null 2>&1
    else
        keycloak_api POST "${keycloak_url}/admin/realms/master/clients" \
            "$kc_token" "$saml_client_payload" > /dev/null 2>&1
    fi

    # Refresh token and re-fetch client to get UUID
    kc_token=$(keycloak_get_token "$keycloak_url" "$kc_admin_password" "$admin_email")
    all_clients=$(keycloak_api GET "${keycloak_url}/admin/realms/master/clients?max=200" "$kc_token")
    local client_uuid
    client_uuid=$(echo "$all_clients" | jq -r --arg cid "$saml_client_id" '.[] | select(.clientId == $cid) | .id' 2>/dev/null | head -1)

    if [[ -z "$client_uuid" ]]; then
        log_error "Failed to create SAML client on Keycloak" \
                  "The client creation API call may have failed" \
                  "Check Keycloak logs" \
                  "kubectl -n keycloak-system logs -l app.kubernetes.io/name=keycloak --tail=30"
        return 1
    fi

    log_success "SAML client created/updated on Keycloak (ID: ${client_uuid})."

    # ── Step 3.7: Add predefined protocol mappers ────────────────────────
    log_info "Adding SAML protocol mappers..."

    local mappers='[
        {"name":"X500 email","protocol":"saml","protocolMapper":"saml-user-attribute-idp-mapper","consentRequired":false,"config":{"attribute.nameformat":"urn:oasis:names:tc:SAML:2.0:attrname-format:uri","user.attribute":"email","friendly.name":"email","attribute.name":"urn:oid:1.2.840.113549.1.9.1"}},
        {"name":"X500 givenName","protocol":"saml","protocolMapper":"saml-user-attribute-idp-mapper","consentRequired":false,"config":{"attribute.nameformat":"urn:oasis:names:tc:SAML:2.0:attrname-format:uri","user.attribute":"firstName","friendly.name":"givenName","attribute.name":"urn:oid:2.5.4.42"}},
        {"name":"X500 surname","protocol":"saml","protocolMapper":"saml-user-attribute-idp-mapper","consentRequired":false,"config":{"attribute.nameformat":"urn:oasis:names:tc:SAML:2.0:attrname-format:uri","user.attribute":"lastName","friendly.name":"surname","attribute.name":"urn:oid:2.5.4.4"}},
        {"name":"role list","protocol":"saml","protocolMapper":"saml-role-list-mapper","consentRequired":false,"config":{"single":"true","attribute.nameformat":"Basic","friendly.name":"","attribute.name":"Role"}}
    ]'

    local existing_mappers
    existing_mappers=$(keycloak_api GET "${keycloak_url}/admin/realms/master/clients/${client_uuid}/protocol-mappers/models" "$kc_token")

    echo "$mappers" | jq -c '.[]' | while read -r mapper; do
        local mapper_name
        mapper_name=$(echo "$mapper" | jq -r '.name')
        if echo "$existing_mappers" | jq -r '.[].name' 2>/dev/null | grep -qx "$mapper_name"; then
            log_info "  Mapper '${mapper_name}' already exists — skipping."
            continue
        fi
        keycloak_api POST "${keycloak_url}/admin/realms/master/clients/${client_uuid}/protocol-mappers/models" \
            "$kc_token" "$mapper" > /dev/null 2>&1
        log_info "  Added mapper: ${mapper_name}"
    done

    log_success "SAML protocol mappers configured."

    # ── Step 3.8: Disable Client Signature Required ──────────────────────
    log_info "Disabling Client Signature Required on SAML client..."

    kc_token=$(keycloak_get_token "$keycloak_url" "$kc_admin_password" "$admin_email")
    keycloak_api PUT "${keycloak_url}/admin/realms/master/clients/${client_uuid}" "$kc_token" \
        "{\"attributes\":{\"saml.client.signature\":\"false\"}}" > /dev/null 2>&1

    log_success "Client Signature Required disabled."

    # ── Step 3.9: Configure Rancher SAML auth provider ───────────────────
    log_info "Configuring Keycloak SAML auth provider in Rancher..."

    # Refresh Rancher token
    rancher_token=$(rancher_try_login "$rancher_url" "$rancher_admin_password")
    if [[ -z "$rancher_token" ]]; then
        log_error "Could not refresh Rancher token" \
                  "Login to Rancher failed" \
                  "Check Rancher accessibility"
        return 1
    fi

    # Download IDP metadata
    local saml_metadata_url="${keycloak_url}/realms/master/protocol/saml/descriptor"
    local idp_metadata
    idp_metadata=$(curl -sk "$saml_metadata_url" 2>/dev/null)

    if [[ -z "$idp_metadata" ]]; then
        log_error "Could not fetch Keycloak SAML metadata" \
                  "The SAML descriptor endpoint is not accessible" \
                  "Check Keycloak URL" \
                  "curl -sk ${saml_metadata_url}"
        return 1
    fi

    # Generate SP certificate for Rancher SAML
    local sp_cert_dir="/tmp/rancher-saml-sp"
    mkdir -p "$sp_cert_dir"
    openssl req -x509 -newkey rsa:2048 -keyout "${sp_cert_dir}/sp.key" \
        -out "${sp_cert_dir}/sp.crt" -days 3650 -nodes \
        -subj "/CN=rancher-saml-sp" 2>/dev/null

    local sp_cert_pem sp_key_pem
    sp_cert_pem=$(cat "${sp_cert_dir}/sp.crt")
    sp_key_pem=$(cat "${sp_cert_dir}/sp.key")

    # Build payload in a temp file (avoids shell escaping issues with large XML)
    local saml_payload_file="/tmp/rancher-saml-payload.json"
    jq -n \
        --arg displayNameField "givenName" \
        --arg userNameField "email" \
        --arg uidField "email" \
        --arg groupsField "member" \
        --arg entityID "$saml_client_id" \
        --arg rancherApiHost "$rancher_url" \
        --arg idpMetadataContent "$idp_metadata" \
        --arg spCert "$sp_cert_pem" \
        --arg spKey "$sp_key_pem" \
        '{
            "displayNameField": $displayNameField,
            "userNameField": $userNameField,
            "uidField": $uidField,
            "groupsField": $groupsField,
            "entityID": $entityID,
            "rancherApiHost": $rancherApiHost,
            "idpMetadataContent": $idpMetadataContent,
            "spCert": $spCert,
            "spKey": $spKey
        }' > "$saml_payload_file"

    log_info "SAML payload written to ${saml_payload_file} ($(wc -c < "$saml_payload_file") bytes)"

    # If SAML was previously configured (even partially/broken), reset it
    local current_saml
    current_saml=$(rancher_api GET "${rancher_url}/v3/keycloakConfigs/keycloak" "$rancher_token")
    local saml_enabled
    saml_enabled=$(echo "$current_saml" | jq -r '.enabled // false' 2>/dev/null)
    if [[ "$saml_enabled" == "true" ]]; then
        log_info "Existing SAML config found (enabled) — disabling before reconfiguring..."
        rancher_api POST "${rancher_url}/v3/keycloakConfigs/keycloak?action=disable" "$rancher_token" > /dev/null 2>&1
        sleep 3
    fi
    # Also clear any stale/broken config by resetting the auth config object
    local saml_rv
    saml_rv=$(echo "$current_saml" | jq -r '.resourceVersion // empty' 2>/dev/null)
    if [[ -n "$saml_rv" && "$saml_rv" != "null" ]]; then
        log_info "Clearing stale Keycloak auth config (resourceVersion: ${saml_rv})..."
        kubectl get authconfigs.management.cattle.io keycloak -o json 2>/dev/null | \
            jq '.metadata.annotations = {} | .enabled = false | del(.idpMetadataContent) | del(.spCert) | del(.spKey)' | \
            kubectl replace -f - > /dev/null 2>&1 || true
        sleep 2
    fi

    # Step 1: PUT the config to save it on the Rancher object
    log_info "Saving SAML config to Rancher (PUT)..."
    curl -sk -X PUT "${rancher_url}/v3/keycloakConfigs/keycloak" \
        -H "Authorization: Bearer ${rancher_token}" \
        -H "Content-Type: application/json" \
        -d @"${saml_payload_file}" > /dev/null 2>&1
    sleep 2

    # Step 2: POST to testAndEnable to activate it
    log_info "Enabling SAML auth provider (testAndEnable)..."
    local saml_response
    saml_response=$(curl -sk -X POST "${rancher_url}/v3/keycloakConfigs/keycloak?action=testAndEnable" \
        -H "Authorization: Bearer ${rancher_token}" \
        -H "Content-Type: application/json" \
        -d @"${saml_payload_file}" 2>/dev/null)

    local saml_error
    saml_error=$(echo "$saml_response" | jq -r '.message // empty' 2>/dev/null)

    if echo "$saml_response" | jq -r '.type // empty' 2>/dev/null | grep -qi "error"; then
        if [[ "$saml_error" == *"An error occurred logging in"* ]]; then
            log_warn "Rancher returned a login error — this is expected and can be ignored."
            log_warn "The integration is successful if 'Login with Keycloak' appears on the login page."
        else
            log_error "Failed to enable Keycloak SAML in Rancher" \
                      "Error: ${saml_error}" \
                      "Check Rancher and Keycloak logs" \
                      "kubectl -n cattle-system logs deploy/rancher --tail=30"
            return 1
        fi
    fi

    log_success "Keycloak SAML auth provider configured in Rancher."
    rm -rf "$sp_cert_dir" "$saml_payload_file"

    # ── Step 3.10: Configure access mode ─────────────────────────────────
    log_info "Setting Rancher access mode to 'allow cluster members + authorized users'..."

    rancher_api PUT "${rancher_url}/v3/keycloakConfigs/keycloak" "$rancher_token" \
        "{\"accessMode\":\"restricted\",\"allowedPrincipalIds\":[\"keycloak_user://${admin_email}\"]}" \
        > /dev/null 2>&1

    log_success "Rancher access mode configured."

    # ── Done ─────────────────────────────────────────────────────────────
    log_success "Rancher-Keycloak SAML integration complete."
    log_info ""
    log_info "  Rancher admin password: ${rancher_admin_password}"
    log_info "  Keycloak admin email:   ${admin_email}"
    log_info "  Rancher login URL:      ${rancher_url}"
    log_info "  Keycloak admin URL:     ${keycloak_url}/admin/"
    log_info ""
    log_info "  The Rancher login page should now show 'Login with Keycloak'."
    log_info "  Use the Keycloak admin email (${admin_email}) to log in."
    log_info ""

    # Save for summary display
    echo "${rancher_admin_password}" > /var/lib/openg2p/deploy-state/rancher-admin-password
    chmod 600 /var/lib/openg2p/deploy-state/rancher-admin-password

    mark_step_done "$step_id"
}
