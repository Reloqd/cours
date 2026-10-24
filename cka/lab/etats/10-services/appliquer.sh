#!/usr/bin/env bash
# Chapitre 10 : Services api, front (NodePort 30080), front-lb (LoadBalancer),
# api-pods (headless), meteo (ExternalName) ; addon MetalLB et sa plage.
set -euo pipefail
source "$(dirname "$0")/../../lib/commun.sh"
cd "$(dirname "$0")"
verifier_cluster

activer_addon metallb metallb-system deployment/controller
k -n metallb-system rollout status deployment/controller --timeout=300s
k -n metallb-system rollout status daemonset/speaker --timeout=300s

ip=$(ip_noeud_cp); reseau="${ip%.*}"
# La plage doit aussi être enregistrée dans le profil : à chaque « minikube start »,
# minikube réapplique l'addon avec la plage du profil et écraserait la ConfigMap.
# « addons configure » lit deux lignes sur l'entrée standard, d'où la pause.
{ echo "${reseau}.100"; sleep 2; echo "${reseau}.120"; } | mk addons configure metallb >/dev/null
sed "s/@RESEAU@/$reseau/g" metallb-config.yaml | k apply -f -

appliquer services.yaml
attendre 180 "adresse externe de front-lb" \
  sh -c "kubectl --context '$CTX' -n boutique get svc front-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' | grep -q ."
lb=$(k -n boutique get svc front-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
succes "Services en place ; MetalLB ${reseau}.100-${reseau}.120 ; front-lb = $lb"
