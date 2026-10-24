#!/usr/bin/env bash
# Chapitre 7 : addon metrics-server et HorizontalPodAutoscaler api.
set -euo pipefail
source "$(dirname "$0")/../../lib/commun.sh"
cd "$(dirname "$0")"
verifier_cluster

activer_addon metrics-server kube-system deployment/metrics-server
deploiement_pret kube-system metrics-server
appliquer hpa-api.yaml
succes "HPA api en place (les métriques arrivent environ 60 s après l'activation de l'addon)"
