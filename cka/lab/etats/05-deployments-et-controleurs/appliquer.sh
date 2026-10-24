#!/usr/bin/env bash
# Chapitre 5 : Deployments front et api, leurs Services, DaemonSet agent-noeud,
# CronJob rapport, PodDisruptionBudget front.
set -euo pipefail
source "$(dirname "$0")/../../lib/commun.sh"
cd "$(dirname "$0")"
verifier_cluster

# Historique de l'exercice : 1.29 (rév. 1), 1.30.6 annotée (rév. 2), undo (rév. 3),
# undo --to-revision=2 (rév. 4).
if ! existe -n boutique deployment front; then
  sed -e 's/nginx:1.30.6-alpine/nginx:1.29-alpine/' -e '/change-cause/d' -e '/annotations:/d' front.yaml | k apply -f -
  deploiement_pret boutique front
  k -n boutique set image deployment/front nginx=nginx:1.30.6-alpine
  k -n boutique annotate deployment/front kubernetes.io/change-cause="image nginx:1.30.6-alpine" --overwrite
  deploiement_pret boutique front
  k -n boutique rollout undo deployment/front
  deploiement_pret boutique front
  k -n boutique rollout undo deployment/front --to-revision=2
  deploiement_pret boutique front
fi

for f in front.yaml api.yaml services.yaml agent-noeud.yaml rapport.yaml pdb-front.yaml; do
  appliquer "$f"
done
deploiement_pret boutique front
deploiement_pret boutique api
k -n boutique rollout status daemonset/agent-noeud --timeout=300s
succes "front, api, agent-noeud, rapport et PDB front en place"
