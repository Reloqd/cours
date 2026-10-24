#!/usr/bin/env bash
# Chapitre 3 : namespace boutique et contexte kubeconfig « boutique ».
set -euo pipefail
source "$(dirname "$0")/../../lib/commun.sh"
cd "$(dirname "$0")"
verifier_cluster

existe namespace boutique || appliquer namespace.yaml
kubectl config set-context boutique --cluster="$PROFIL" --user="$PROFIL" --namespace=boutique >/dev/null
succes "namespace boutique et contexte boutique (cluster $PROFIL, user $PROFIL)"
