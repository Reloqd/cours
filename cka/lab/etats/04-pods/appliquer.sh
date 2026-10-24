#!/usr/bin/env bash
# Chapitre 4 : pod permanent « outils », redimensionné en place.
set -euo pipefail
source "$(dirname "$0")/../../lib/commun.sh"
cd "$(dirname "$0")"
verifier_cluster

# La spec d'un pod est immuable : on ne réapplique pas un pod existant.
existe -n boutique pod outils || appliquer outils.yaml
k -n boutique wait --for=condition=Ready pod/outils --timeout=5m

cpu=$(k -n boutique get pod outils -o jsonpath='{.spec.containers[0].resources.requests.cpu}')
if [ "$cpu" != "100m" ]; then
  k -n boutique patch pod outils --subresource resize --patch \
    '{"spec":{"containers":[{"name":"outils","resources":{"requests":{"cpu":"100m"},"limits":{"cpu":"300m"}}}]}}'
fi
attendre 120 "redimensionnement de outils" \
  sh -c "kubectl --context '$CTX' -n boutique get pod outils -o jsonpath='{.status.containerStatuses[0].resources.limits.cpu}' | grep -qx 300m"
succes "pod outils prêt (requests cpu 100m, limits cpu 300m)"
