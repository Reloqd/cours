# Fonctions communes aux scripts du lab. À sourcer, pas à exécuter.
# shellcheck shell=bash

PROFIL="${CKA_PROFIL:-cka}"
CTX="$PROFIL"
NOEUD_CP="$PROFIL"
NOEUD_2="$PROFIL-m02"
NOEUD_3="$PROFIL-m03"
CKA_DOSSIER="${CKA_DOSSIER:-$HOME/cka}"
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Versions épinglées (vérifiées le 23 octobre 2026).
K8S_VERSION="v1.37.0"
MINIKUBE_VERSION="v1.39.0"
EG_VERSION="v1.9.2"
CERT_MANAGER_VERSION="v1.21.2"
PODINFO_VERSION="6.15.0"

if [ -t 1 ]; then
  _C_BLEU=$'\e[1;34m'; _C_VERT=$'\e[1;32m'; _C_JAUNE=$'\e[1;33m'; _C_ROUGE=$'\e[1;31m'; _C_RAZ=$'\e[0m'
else
  _C_BLEU=""; _C_VERT=""; _C_JAUNE=""; _C_ROUGE=""; _C_RAZ=""
fi

info()   { printf '%s==>%s %s\n' "$_C_BLEU" "$_C_RAZ" "$*"; }
succes() { printf '%s OK%s %s\n' "$_C_VERT" "$_C_RAZ" "$*"; }
alerte() { printf '%s !!%s %s\n' "$_C_JAUNE" "$_C_RAZ" "$*" >&2; }
echec()  { printf '%sERREUR%s %s\n' "$_C_ROUGE" "$_C_RAZ" "$*" >&2; exit 1; }

# kubectl, helm et minikube toujours sur le cluster du lab, quel que soit le contexte courant.
k()  { kubectl --context "$CTX" "$@"; }
h()  { helm --kube-context "$CTX" "$@"; }
mk() { minikube -p "$PROFIL" "$@"; }

# Commande dans un nœud : ssh_noeud <nœud> '<commande>'
ssh_noeud() { minikube -p "$PROFIL" ssh -n "$1" -- "$2" </dev/null; }

ip_noeud_cp() { minikube -p "$PROFIL" ip; }

# Remplace les noms de nœuds du cours (cka, cka-m02…) si le profil a un autre nom.
adapter_profil() {
  if [ "$PROFIL" = "cka" ]; then cat; else sed -E "s/\bcka-m0([0-9])\b/${PROFIL}-m0\1/g"; fi
}

appliquer() {  # appliquer <fichier|dossier> [options kubectl apply]
  local cible="$1"; shift
  if [ -d "$cible" ]; then
    local f
    for f in "$cible"/*.yaml; do adapter_profil < "$f" | k apply "$@" -f -; done
  else
    adapter_profil < "$cible" | k apply "$@" -f -
  fi
}

# reessayer <essais> <pause> <commande…> : utile tant qu'un webhook d'admission démarre.
reessayer() {
  local essais="$1" pause="$2" n=1; shift 2
  until "$@"; do
    [ "$n" -ge "$essais" ] && return 1
    n=$((n + 1)); sleep "$pause"
  done
}

# attendre <délai en s> <description> <commande…> : boucle jusqu'au succès de la commande.
attendre() {
  local delai="$1" quoi="$2" debut; shift 2
  debut=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    if [ $(( $(date +%s) - debut )) -ge "$delai" ]; then
      alerte "délai dépassé (${delai} s) : $quoi"; return 1
    fi
    sleep 3
  done
}

existe() { k get "$@" >/dev/null 2>&1; }

deploiement_pret() {  # deploiement_pret <ns> <nom> [délai]
  k -n "$1" rollout status "deployment/$2" --timeout="${3:-300s}"
}

# activer_addon <addon> <ns> <objet témoin> : « addons list » ment en multi-nœud,
# on juge sur la présence d'un objet de l'addon.
activer_addon() {
  if k -n "$2" get "$3" >/dev/null 2>&1; then
    info "addon $1 déjà présent"
  else
    info "activation de l'addon $1"
    mk addons enable "$1"
  fi
}

chrono_debut() { _CHRONO=$(date +%s); }
chrono_fin()   { local s=$(( $(date +%s) - _CHRONO )); printf '%d min %02d s' $((s / 60)) $((s % 60)); }

verifier_cluster() {
  k get --raw /readyz >/dev/null 2>&1 \
    || echec "le cluster « $PROFIL » ne répond pas (contexte $CTX). Lance lab/demarrer.sh ou lab/restaurer.sh."
}
