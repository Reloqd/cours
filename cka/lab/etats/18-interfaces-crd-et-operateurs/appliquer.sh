#!/usr/bin/env bash
# Chapitre 18 : RuntimeClass runc-standard, CRD sauvegardes.boutique.example et
# ressource redis-quotidienne, ClusterRole agrégée, ClusterIssuer autosigne,
# Certificate boutique-gw, listener https sur boutique-gw-tls.
set -euo pipefail
source "$(dirname "$0")/../../lib/commun.sh"
cd "$(dirname "$0")"
verifier_cluster

appliquer runtimeclass.yaml
appliquer crd-sauvegardes.yaml
k wait --for=condition=Established crd/sauvegardes.boutique.example --timeout=60s
appliquer redis-quotidienne.yaml
k -n boutique patch sauvegarde redis-quotidienne --subresource=status --type=merge \
  -p '{"status":{"derniereExecution":"2026-10-23T02:00:00Z"}}'
appliquer clusterrole-sauvegardes-lecture.yaml

# Le webhook de cert-manager peut refuser la connexion juste après son démarrage.
reessayer 20 3 appliquer cert-manager-objets.yaml
k wait --for=condition=Ready clusterissuer/autosigne --timeout=120s
k -n boutique wait --for=condition=Ready certificate/boutique-gw --timeout=180s
# Exercice 18.11 : Secret supprimé, cert-manager le réémet (révision 2).
if [ "$(k -n boutique get certificate boutique-gw -o jsonpath='{.status.revision}')" = "1" ]; then
  k -n boutique delete secret boutique-gw-tls
  attendre 120 "réémission de boutique-gw-tls" \
    sh -c "kubectl --context '$CTX' -n boutique get certificate boutique-gw -o jsonpath='{.status.revision}' | grep -qx 2"
  k -n boutique wait --for=condition=Ready certificate/boutique-gw --timeout=120s
fi

appliquer gateway.yaml
k -n boutique wait --for=condition=Programmed gateway/boutique-gw --timeout=300s
succes "CRD, ressource redis-quotidienne et certificat boutique-gw-tls en place (instantané I4)"
