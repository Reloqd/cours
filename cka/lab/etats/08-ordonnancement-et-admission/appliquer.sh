#!/usr/bin/env bash
# Chapitre 8 : labels de nœuds, contraintes de placement, PriorityClass,
# ResourceQuota, LimitRange et Pod Security Admission sur boutique.
# Aucune taint ne reste : les exercices de taint sont annulés en fin de chapitre.
set -euo pipefail
source "$(dirname "$0")/../../lib/commun.sh"
cd "$(dirname "$0")"
verifier_cluster

k label node "$NOEUD_CP" topology.kubernetes.io/zone=zone-a --overwrite
k label node "$NOEUD_2" "$NOEUD_3" topology.kubernetes.io/zone=zone-b --overwrite
k label node "$NOEUD_3" disque=ssd --overwrite

for f in namespace.yaml priorityclass.yaml quota-et-limites.yaml front.yaml api.yaml agent-noeud.yaml; do
  appliquer "$f"
done
deploiement_pret boutique front
deploiement_pret boutique api
k -n boutique rollout status daemonset/agent-noeud --timeout=300s
succes "placement, priorité, quota, limites et PSA en place (instantané I1 si tu t'arrêtes ici)"
