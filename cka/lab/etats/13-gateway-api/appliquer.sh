#!/usr/bin/env bash
# Chapitre 13 : Envoy Gateway (Helm), GatewayClass eg, front-v2, Gateway boutique-gw
# et HTTPRoutes front, api et redirection-https.
set -euo pipefail
source "$(dirname "$0")/../../lib/commun.sh"
cd "$(dirname "$0")"
verifier_cluster

if h -n envoy-gateway-system status eg >/dev/null 2>&1; then
  info "release eg déjà installée"
else
  h install eg oci://docker.io/envoyproxy/gateway-helm --version "$EG_VERSION" \
    -n envoy-gateway-system --create-namespace
fi
k wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

appliquer gatewayclass.yaml
appliquer front-v2.yaml
deploiement_pret boutique front-v2
reessayer 10 3 appliquer gateway.yaml
reessayer 10 3 appliquer httproutes.yaml
k -n boutique wait --for=condition=Programmed gateway/boutique-gw --timeout=300s
for r in front api redirection-https; do
  attendre 120 "HTTPRoute $r acceptée" \
    sh -c "kubectl --context '$CTX' -n boutique get httproute $r -o jsonpath='{.status.parents[0].conditions[?(@.type==\"Accepted\")].status}' | grep -qx True"
done
gw=$(k -n boutique get gateway boutique-gw -o jsonpath='{.status.addresses[0].value}')
succes "Gateway boutique-gw programmé, adresse $gw"
