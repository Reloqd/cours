#!/usr/bin/env bash
# Chapitre 11 : CoreDNS à 2 réplicas ; boutique.example et api.boutique.example
# ajoutés au bloc hosts de minikube, vers l'IP du nœud control plane (contrôleur
# d'Ingress du chapitre 12).
set -euo pipefail
source "$(dirname "$0")/../../lib/commun.sh"
cd "$(dirname "$0")"
verifier_cluster

ip=$(ip_noeud_cp)
if k -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | grep -q 'boutique\.example'; then
  info "Corefile déjà modifié"
else
  k -n kube-system get configmap coredns -o yaml \
    | sed -E "s/^( *)([0-9.]+ host\.minikube\.internal)\$/\1\2\n\1$ip boutique.example api.boutique.example/" \
    | k replace -f -
fi
k -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | grep -q "$ip boutique.example api.boutique.example" \
  || echec "entrée hosts absente du Corefile (bloc hosts de minikube introuvable ?)"

k -n kube-system scale deployment coredns --replicas=2
# Le plugin reload relirait le Corefile en 30 à 90 s ; on redémarre pour aller vite.
k -n kube-system rollout restart deployment coredns
k -n kube-system rollout status deployment coredns --timeout=300s
succes "CoreDNS : 2 réplicas, boutique.example et api.boutique.example -> $ip"
