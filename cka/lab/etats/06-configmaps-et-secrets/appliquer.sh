#!/usr/bin/env bash
# Chapitre 6 : ConfigMaps front-html, front-conf, api-config et Secret api-secret,
# consommés par front (volumes) et api (envFrom, secretKeyRef).
set -euo pipefail
source "$(dirname "$0")/../../lib/commun.sh"
cd "$(dirname "$0")"
verifier_cluster

for f in configmaps.yaml api-secret.yaml front.yaml api.yaml; do
  appliquer "$f"
done
deploiement_pret boutique front
deploiement_pret boutique api
succes "front sert la page v1 et relaie /api/ ; api lit api-config et api-secret"
