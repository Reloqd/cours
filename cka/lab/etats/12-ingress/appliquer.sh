#!/usr/bin/env bash
# Chapitre 12 : addon ingress, Secret TLS autosigné boutique-tls, Ingress boutique.
set -euo pipefail
source "$(dirname "$0")/../../lib/commun.sh"
cd "$(dirname "$0")"
verifier_cluster

activer_addon ingress ingress-nginx deployment/ingress-nginx-controller
deploiement_pret ingress-nginx ingress-nginx-controller
k -n ingress-nginx wait --for=condition=Complete job --all --timeout=300s

# Certificat de l'apprenant (~/cka/boutique, exercice 12.2) : réutilisé s'il existe,
# car les exercices 13 et 14 s'en servent comme --cacert.
rep="$CKA_DOSSIER/boutique"; mkdir -p "$rep"
if [ ! -s "$rep/boutique-tls.key" ] || [ ! -s "$rep/boutique-tls.crt" ]; then
  openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
    -keyout "$rep/boutique-tls.key" -out "$rep/boutique-tls.crt" \
    -subj "/CN=boutique.example" \
    -addext "subjectAltName=DNS:boutique.example,DNS:*.boutique.example" 2>/dev/null
fi
existe -n boutique secret boutique-tls \
  || k -n boutique create secret tls boutique-tls --cert="$rep/boutique-tls.crt" --key="$rep/boutique-tls.key"

# Le webhook de validation d'ingress-nginx peut refuser la connexion quelques secondes.
reessayer 20 3 appliquer ingress-boutique.yaml
attendre 180 "adresse de l'Ingress boutique" \
  sh -c "kubectl --context '$CTX' -n boutique get ingress boutique -o jsonpath='{.status.loadBalancer.ingress[0].ip}' | grep -q ."
succes "Ingress boutique servi par ingress-nginx sur $(ip_noeud_cp) (HTTP 80 redirigé, HTTPS 443)"
