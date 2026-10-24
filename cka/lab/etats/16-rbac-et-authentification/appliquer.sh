#!/usr/bin/env bash
# Chapitre 16 : utilisateur alice (certificat signé par l'API CSR, contexte alice@cka),
# Role/RoleBinding developpeur(s), ClusterRole lecteur-noeuds, ServiceAccount deployeur.
set -euo pipefail
source "$(dirname "$0")/../../lib/commun.sh"
cd "$(dirname "$0")"
verifier_cluster

appliquer rbac-alice.yaml
appliquer rbac-deployeur.yaml

# Certificat d'alice : à réémettre dès que le cluster (donc sa CA) a été recréé.
rep="$CKA_DOSSIER/rbac"; mkdir -p "$rep"
if kubectl --context "alice@$PROFIL" auth whoami >/dev/null 2>&1; then
  info "certificat d'alice encore valide pour ce cluster"
else
  [ -f "$rep/alice.key" ] || openssl genrsa -out "$rep/alice.key" 3072 2>/dev/null
  openssl req -new -key "$rep/alice.key" -subj "/CN=alice/O=developpeurs" -out "$rep/alice.csr"
  k delete csr alice --ignore-not-found
  sed "s|@REQUEST@|$(base64 -w0 < "$rep/alice.csr")|" csr-alice.yaml | k apply -f -
  k certificate approve alice
  attendre 60 "émission du certificat d'alice" \
    sh -c "kubectl --context '$CTX' get csr alice -o jsonpath='{.status.certificate}' | grep -q ."
  k get csr alice -o jsonpath='{.status.certificate}' | base64 -d > "$rep/alice.crt"
  kubectl config set-credentials alice --client-key="$rep/alice.key" \
    --client-certificate="$rep/alice.crt" --embed-certs=true >/dev/null
fi
kubectl config set-context "alice@$PROFIL" --cluster="$PROFIL" --user=alice --namespace=boutique >/dev/null
kubectl --context "alice@$PROFIL" auth whoami
succes "alice (groupe developpeurs) et ServiceAccount deployeur en place"
