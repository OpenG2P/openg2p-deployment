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
# Ref: https://docs.openg2p.org/deployment/base-infrastructure/rancher#rancher-keycloak-integration
# Sourced by openg2p-infra.sh — do not run directly.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# Helper: get Keycloak admin access token
# ─────────────────────────────────────────────────────────────────────────────
keycloak_get_token() {
    local kc_url="$1"
    local kc_password="$2"

    local token_response
    token_response=$(curl -sk -X POST "${kc_url}/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=admin" \
        -d "password=${kc_password}" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" 2>/dev/null)

    echo "$token_response" | jq -r '.access_token // empty'
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
    local rancher_admin_password=$(cfg "rancher.admin_password" "")

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

    # Give services a moment to fully initialize after pods are ready
    sleep 10

    # ── Step 3.2: Bootstrap Rancher admin password ───────────────────────
    log_info "Bootstrapping Rancher admin password..."

    # Get bootstrap password from K8s secret
    local bootstrap_password
    bootstrap_password=$(kubectl -n cattle-system get secret bootstrap-secret \
        -o jsonpath='{.data.bootstrapPassword}' 2>/dev/null | base64 -d 2>/dev/null)

    if [[ -z "$bootstrap_password" ]]; then
        # Try the older method — Rancher might store it differently
        bootstrap_password=$(kubectl -n cattle-system get pods -l app=rancher \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | \
            xargs -I{} kubectl -n cattle-system logs {} 2>/dev/null | \
            grep "Bootstrap Password:" | head -1 | awk '{print $NF}')
    fi

    if [[ -z "$bootstrap_password" ]]; then
        log_error "Could not retrieve Rancher bootstrap password" \
                  "The bootstrap-secret may not exist yet or Rancher is still initializing" \
                  "Check if Rancher is fully started" \
                  "kubectl -n cattle-system get secret bootstrap-secret -o yaml"
        return 1
    fi
    log_success "Retrieved Rancher bootstrap password."

    # Auto-generate admin password if not provided
    if [[ -z "$rancher_admin_password" ]]; then
        rancher_admin_password="openg2p-$(openssl rand -hex 8)"
        log_info "Auto-generated Rancher admin password."
    fi

    # Login with bootstrap password and set new admin password
    local login_response
    login_response=$(curl -sk -X POST "${rancher_url}/v3-public/localProviders/local?action=login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"admin\",\"password\":\"${bootstrap_password}\"}" 2>/dev/null)

    local rancher_token
    rancher_token=$(echo "$login_response" | jq -r '.token // empty')

    if [[ -z "$rancher_token" ]]; then
        # Maybe admin password was already set (re-run scenario)
        login_response=$(curl -sk -X POST "${rancher_url}/v3-public/localProviders/local?action=login" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"admin\",\"password\":\"${rancher_admin_password}\"}" 2>/dev/null)
        rancher_token=$(echo "$login_response" | jq -r '.token // empty')

        if [[ -n "$rancher_token" ]]; then
            log_success "Rancher admin already bootstrapped (login successful with configured password)."
        else
            log_error "Cannot login to Rancher with bootstrap or configured password" \
                      "Rancher may have been bootstrapped with a different password" \
                      "Check Rancher UI manually or reset the admin password" \
                      "kubectl -n cattle-system exec -it deploy/rancher -- reset-password"
            return 1
        fi
    else
        # Set new admin password
        log_info "Setting Rancher admin password..."
        curl -sk -X POST "${rancher_url}/v3/users?action=changepassword" \
            -H "Authorization: Bearer ${rancher_token}" \
            -H "Content-Type: application/json" \
            -d "{\"currentPassword\":\"${bootstrap_password}\",\"newPassword\":\"${rancher_admin_password}\"}" \
            > /dev/null 2>&1

        # Set server URL
        rancher_api PUT "${rancher_url}/v3/settings/server-url" "$rancher_token" \
            "{\"value\":\"${rancher_url}\"}" > /dev/null 2>&1

        # Save password to K8s secret for future reference
        kubectl -n cattle-system create secret generic rancher-secret \
            --from-literal=adminPassword="${rancher_admin_password}" \
            --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1

        # Re-login with new password to get a fresh token
        login_response=$(curl -sk -X POST "${rancher_url}/v3-public/localProviders/local?action=login" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"admin\",\"password\":\"${rancher_admin_password}\"}" 2>/dev/null)
        rancher_token=$(echo "$login_response" | jq -r '.token // empty')

        log_success "Rancher admin password set and saved to secret cattle-system/rancher-secret."
    fi

    if [[ -z "$rancher_token" ]]; then
        log_error "Failed to obtain Rancher API token after bootstrap" \
                  "Login succeeded but no token was returned" \
                  "Check Rancher API accessibility" \
                  "curl -sk ${rancher_url}/v3"
        return 1
    fi

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

    # Get Keycloak access token
    local kc_token
    kc_token=$(keycloak_get_token "$keycloak_url" "$kc_admin_password")

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

    # Get admin user ID
    local admin_users
    admin_users=$(keycloak_api GET "${keycloak_url}/admin/realms/master/users?username=admin&exact=true" "$kc_token")
    local admin_user_id
    admin_user_id=$(echo "$admin_users" | jq -r '.[0].id // empty')

    if [[ -z "$admin_user_id" ]]; then
        log_error "Could not find Keycloak admin user" \
                  "The admin user may not exist in the master realm" \
                  "Check Keycloak users" \
                  "curl -sk ${keycloak_url}/admin/realms/master/users -H 'Authorization: Bearer TOKEN'"
        return 1
    fi

    # Update admin user with email
    keycloak_api PUT "${keycloak_url}/admin/realms/master/users/${admin_user_id}" "$kc_token" \
        "{\"email\":\"${admin_email}\",\"emailVerified\":true,\"firstName\":\"Admin\",\"lastName\":\"User\"}" \
        > /dev/null 2>&1

    log_success "Keycloak admin email set to ${admin_email}."

    # ── Step 3.5: Enable email-as-username in master realm ───────────────
    log_info "Enabling 'email as username' in master realm..."

    # Get current realm config
    local realm_config
    realm_config=$(keycloak_api GET "${keycloak_url}/admin/realms/master" "$kc_token")

    # Update realm to enable registrationEmailAsUsername
    keycloak_api PUT "${keycloak_url}/admin/realms/master" "$kc_token" \
        "{\"registrationEmailAsUsername\":true}" > /dev/null 2>&1

    log_success "Email-as-username enabled in master realm."

    # ── Step 3.6: Create SAML client for Rancher on Keycloak ─────────────
    log_info "Creating SAML client for Rancher on Keycloak..."

    local saml_client_id="https://${rancher_host}/v1-saml/keycloak/saml/metadata"
    local saml_acs_url="https://${rancher_host}/v1-saml/keycloak/saml/acs"

    # Check if client already exists
    local existing_clients
    existing_clients=$(keycloak_api GET "${keycloak_url}/admin/realms/master/clients?clientId=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${saml_client_id}'))" 2>/dev/null || echo "${saml_client_id}")" "$kc_token")
    local existing_client_id
    existing_client_id=$(echo "$existing_clients" | jq -r '.[0].id // empty')

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
        local create_response
        create_response=$(keycloak_api POST "${keycloak_url}/admin/realms/master/clients" \
            "$kc_token" "$saml_client_payload")
    fi

    # Re-fetch client to get the internal ID
    # Refresh token (may have expired during the process)
    kc_token=$(keycloak_get_token "$keycloak_url" "$kc_admin_password")

    existing_clients=$(keycloak_api GET "${keycloak_url}/admin/realms/master/clients?clientId=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${saml_client_id}'))" 2>/dev/null || echo "${saml_client_id}")" "$kc_token")
    local client_uuid
    client_uuid=$(echo "$existing_clients" | jq -r '.[0].id // empty')

    if [[ -z "$client_uuid" ]]; then
        log_error "Failed to create SAML client on Keycloak" \
                  "The client creation API call may have failed" \
                  "Check Keycloak logs" \
                  "kubectl -n keycloak-system logs -l app.kubernetes.io/name=keycloak --tail=30"
        return 1
    fi

    log_success "SAML client created/updated on Keycloak (ID: ${client_uuid})."

    # ── Step 3.7: Add predefined protocol mappers to the dedicated scope ─
    log_info "Adding SAML protocol mappers..."

    # Get the dedicated client scope
    local dedicated_scopes
    dedicated_scopes=$(keycloak_api GET "${keycloak_url}/admin/realms/master/clients/${client_uuid}/default-client-scopes" "$kc_token")

    # Add predefined mappers directly to the client's protocol mappers
    local mappers='[
        {
            "name": "X500 email",
            "protocol": "saml",
            "protocolMapper": "saml-user-attribute-idp-mapper",
            "consentRequired": false,
            "config": {
                "attribute.nameformat": "urn:oasis:names:tc:SAML:2.0:attrname-format:uri",
                "user.attribute": "email",
                "friendly.name": "email",
                "attribute.name": "urn:oid:1.2.840.113549.1.9.1"
            }
        },
        {
            "name": "X500 givenName",
            "protocol": "saml",
            "protocolMapper": "saml-user-attribute-idp-mapper",
            "consentRequired": false,
            "config": {
                "attribute.nameformat": "urn:oasis:names:tc:SAML:2.0:attrname-format:uri",
                "user.attribute": "firstName",
                "friendly.name": "givenName",
                "attribute.name": "urn:oid:2.5.4.42"
            }
        },
        {
            "name": "X500 surname",
            "protocol": "saml",
            "protocolMapper": "saml-user-attribute-idp-mapper",
            "consentRequired": false,
            "config": {
                "attribute.nameformat": "urn:oasis:names:tc:SAML:2.0:attrname-format:uri",
                "user.attribute": "lastName",
                "friendly.name": "surname",
                "attribute.name": "urn:oid:2.5.4.4"
            }
        },
        {
            "name": "role list",
            "protocol": "saml",
            "protocolMapper": "saml-role-list-mapper",
            "consentRequired": false,
            "config": {
                "single": "true",
                "attribute.nameformat": "Basic",
                "friendly.name": "",
                "attribute.name": "Role"
            }
        }
    ]'

    # Get existing mappers to avoid duplicates
    local existing_mappers
    existing_mappers=$(keycloak_api GET "${keycloak_url}/admin/realms/master/clients/${client_uuid}/protocol-mappers/models" "$kc_token")

    echo "$mappers" | jq -c '.[]' | while read -r mapper; do
        local mapper_name
        mapper_name=$(echo "$mapper" | jq -r '.name')

        # Skip if mapper already exists
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

    # Refresh token
    kc_token=$(keycloak_get_token "$keycloak_url" "$kc_admin_password")

    keycloak_api PUT "${keycloak_url}/admin/realms/master/clients/${client_uuid}" "$kc_token" \
        "{\"attributes\":{\"saml.client.signature\":\"false\"}}" > /dev/null 2>&1

    log_success "Client Signature Required disabled."

    # ── Step 3.9: Configure Rancher SAML auth provider ───────────────────
    log_info "Configuring Keycloak SAML auth provider in Rancher..."

    # Refresh Rancher token
    login_response=$(curl -sk -X POST "${rancher_url}/v3-public/localProviders/local?action=login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"admin\",\"password\":\"${rancher_admin_password}\"}" 2>/dev/null)
    rancher_token=$(echo "$login_response" | jq -r '.token // empty')

    if [[ -z "$rancher_token" ]]; then
        log_error "Could not refresh Rancher token" \
                  "Login to Rancher failed" \
                  "Check Rancher accessibility"
        return 1
    fi

    # Get Keycloak SAML descriptor
    local saml_metadata_url="${keycloak_url}/realms/master/protocol/saml/descriptor"

    local rancher_saml_config
    rancher_saml_config=$(cat <<JSONEOF
{
    "enabled": true,
    "type": "keycloakConfig",
    "accessMode": "unrestricted",
    "displayNameField": "givenName",
    "userNameField": "email",
    "uidField": "email",
    "groupsField": "member",
    "entityID": "${saml_client_id}",
    "rancherApiHost": "${rancher_url}",
    "idpMetadataContent": "",
    "spCert": "",
    "spKey": ""
}
JSONEOF
)

    # First, download the IDP metadata and embed it
    local idp_metadata
    idp_metadata=$(curl -sk "$saml_metadata_url" 2>/dev/null)

    if [[ -z "$idp_metadata" ]]; then
        log_error "Could not fetch Keycloak SAML metadata" \
                  "The SAML descriptor endpoint is not accessible" \
                  "Check Keycloak URL" \
                  "curl -sk ${saml_metadata_url}"
        return 1
    fi

    # Generate a self-signed SP certificate for Rancher SAML
    local sp_cert_dir="/tmp/rancher-saml-sp"
    mkdir -p "$sp_cert_dir"
    openssl req -x509 -newkey rsa:2048 -keyout "${sp_cert_dir}/sp.key" \
        -out "${sp_cert_dir}/sp.crt" -days 3650 -nodes \
        -subj "/CN=rancher-saml-sp" 2>/dev/null

    local sp_cert_pem sp_key_pem
    sp_cert_pem=$(cat "${sp_cert_dir}/sp.crt")
    sp_key_pem=$(cat "${sp_cert_dir}/sp.key")

    # Escape for JSON (replace newlines)
    local idp_metadata_escaped sp_cert_escaped sp_key_escaped
    idp_metadata_escaped=$(echo "$idp_metadata" | jq -Rs '.')
    sp_cert_escaped=$(echo "$sp_cert_pem" | jq -Rs '.')
    sp_key_escaped=$(echo "$sp_key_pem" | jq -Rs '.')

    # Build the final payload with embedded metadata
    local saml_enable_payload
    saml_enable_payload=$(jq -n \
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
        }')

    # Enable Keycloak SAML auth in Rancher
    local saml_response
    saml_response=$(rancher_api POST "${rancher_url}/v3/keycloakConfigs/keycloak?action=testAndEnable" \
        "$rancher_token" "$saml_enable_payload")

    local saml_error
    saml_error=$(echo "$saml_response" | jq -r '.message // empty' 2>/dev/null)

    # Rancher sometimes returns an error message but the integration still works
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

    # Clean up SP cert temp files
    rm -rf "$sp_cert_dir"

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

    # Save integration details for the summary
    echo "${rancher_admin_password}" > /var/lib/openg2p/deploy-state/rancher-admin-password
    chmod 600 /var/lib/openg2p/deploy-state/rancher-admin-password

    mark_step_done "$step_id"
}
