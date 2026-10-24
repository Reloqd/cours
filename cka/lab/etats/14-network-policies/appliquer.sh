#!/usr/bin/env bash
# Chapitre 14 : NetworkPolicies de boutique (refus par défaut, puis ouvertures).
set -euo pipefail
source "$(dirname "$0")/../../lib/commun.sh"
cd "$(dirname "$0")"
verifier_cluster

ip=$(ip_noeud_cp); reseau="${ip%.*}"
tunnel() { k get node "$1" -o jsonpath='{.metadata.annotations.projectcalico\.org/IPv4IPIPTunnelAddr}'; }
t1=$(tunnel "$NOEUD_CP"); t2=$(tunnel "$NOEUD_2"); t3=$(tunnel "$NOEUD_3")
[ -n "$t1" ] && [ -n "$t2" ] && [ -n "$t3" ] || echec "adresse de tunnel IPIP introuvable sur un nœud"
sed -e "s/@RESEAU@/$reseau/g" -e "s/@TUNNEL_CP@/$t1/" -e "s/@TUNNEL_M02@/$t2/" -e "s/@TUNNEL_M03@/$t3/" \
  networkpolicies.yaml | k apply -f -
info "web-entree : ${reseau}.0/24, $t1/32, $t2/32, $t3/32"
k -n boutique get networkpolicy
succes "8 NetworkPolicies appliquées (instantané I2 si tu t'arrêtes ici)"
