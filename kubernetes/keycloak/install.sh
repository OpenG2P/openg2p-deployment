#!/usr/bin/env bash

export KEYCLOAK_HOSTNAME=${KEYCLOAK_HOSTNAME:-keycloak.openg2p.net}
export KEYCLOAK_ISTIO_GATEWAY=${KEYCLOAK_ISTIO_GATEWAY:-true}
export KEYCLOAK_ISTIO_VIRTUALSERVICE=${KEYCLOAK_ISTIO_VIRTUALSERVICE:-true}
export KEYCLOAK_GATEWAY_NAME=${KEYCLOAK_GATEWAY_NAME:-keycloak}
export TLS=${TLS:-false}
export NS=${NS:-keycloak-system}

kubectl create ns $NS

helm repo add openg2p https://openg2p.github.io/openg2p-helm
helm repo update

helm -n $NS upgrade --install keycloak openg2p/keycloak \
    -f values-keycloak.yaml \
    $@

if [[ "$KEYCLOAK_ISTIO_GATEWAY" == "true" ]]; then
    if [[ "$TLS" == "true" ]]; then
        envsubst < istio-gateway-tls.template.yaml | kubectl -n $NS apply -f -
    else
        envsubst < istio-gateway.template.yaml | kubectl -n $NS apply -f -
    fi
fi

if [[ "$KEYCLOAK_ISTIO_VIRTUALSERVICE" == "true" ]]; then
    envsubst < istio-virtualservice.template.yaml | kubectl -n $NS apply -f -
fi
