#!/usr/bin/env bash
# Chapitre 17 : release Helm vitrine (podinfo) dans demo, cert-manager par Helm,
# overlay Kustomize recette dans boutique-recette.
set -euo pipefail
source "$(dirname "$0")/../../lib/commun.sh"
cd "$(dirname "$0")"
verifier_cluster

h repo add podinfo https://stefanprodan.github.io/podinfo --force-update >/dev/null
h repo update podinfo >/dev/null

# Même historique que l'exercice : install, upgrade (ui.message), rollback vers 1.
if h -n demo status vitrine >/dev/null 2>&1; then
  info "release vitrine déjà installée"
else
  h install vitrine podinfo/podinfo --version "$PODINFO_VERSION" \
    -n demo --create-namespace --set replicaCount=2 --wait --timeout 5m
  h upgrade vitrine podinfo/podinfo --version "$PODINFO_VERSION" \
    -n demo --reuse-values --set ui.message=Bonjour --wait --timeout 5m
  h rollback vitrine 1 -n demo --wait --timeout 5m
fi
h -n demo history vitrine

if h -n cert-manager status cert-manager >/dev/null 2>&1; then
  info "release cert-manager déjà installée"
else
  h install cert-manager oci://quay.io/jetstack/charts/cert-manager --version "$CERT_MANAGER_VERSION" \
    --namespace cert-manager --create-namespace --set crds.enabled=true
fi
for d in cert-manager cert-manager-cainjector cert-manager-webhook; do
  deploiement_pret cert-manager "$d"
done

# Copie de travail de l'apprenant (exercices 17.7 et 17.8), sans écraser la sienne.
[ -d "$CKA_DOSSIER/kustomize" ] || { mkdir -p "$CKA_DOSSIER"; cp -r kustomize "$CKA_DOSSIER/kustomize"; }
k apply -k kustomize/overlays/recette
deploiement_pret boutique-recette front
succes "demo/vitrine, cert-manager et boutique-recette en place"
