#!/usr/bin/env bash
# Recrée le profil du cours et rejoue les états des chapitres jusqu'à l'instantané demandé.
#   lab/restaurer.sh <I0|I1|I2|I3|I4> [--oui]
set -euo pipefail
source "$(dirname "$0")/lib/commun.sh"

usage() { echo "usage : $0 <I0|I1|I2|I3|I4> [--oui]" >&2; exit 2; }

CIBLE="" ; OUI=0
for a in "$@"; do
  case "$a" in
    I0|I1|I2|I3|I4) CIBLE="$a" ;;
    --oui|-y) OUI=1 ;;
    *) usage ;;
  esac
done
[ -n "$CIBLE" ] || usage

# Chapitres rejoués pour chaque instantané (dossiers de lab/etats/).
declare -A DERNIER=( [I0]=00 [I1]=08 [I2]=14 [I3]=15 [I4]=18 )
limite="${DERNIER[$CIBLE]}"

if [ "$OUI" -ne 1 ]; then
  printf 'Le profil minikube « %s » va être SUPPRIMÉ puis recréé à l’état %s. Continuer ? [o/N] ' "$PROFIL" "$CIBLE"
  read -r rep
  case "$rep" in o|O|oui|OUI) ;; *) echo "abandon"; exit 1 ;; esac
fi

chrono_debut
DEBUT_TOTAL=$(date +%s)

info "suppression du profil $PROFIL"
minikube -p "$PROFIL" delete
# minikube laisse parfois le réseau Docker : un second delete le retire.
if docker network inspect "$PROFIL" >/dev/null 2>&1; then
  minikube -p "$PROFIL" delete
fi

"$LAB_DIR/demarrer.sh"

for d in "$LAB_DIR"/etats/[0-9][0-9]-*/; do
  n=$(basename "$d"); n="${n%%-*}"
  [ "$((10#$n))" -le "$((10#$limite))" ] || break
  info "état du chapitre $((10#$n)) ($(basename "$d"))"
  chrono_debut
  bash "$d/appliquer.sh"
  succes "chapitre $((10#$n)) appliqué en $(chrono_fin)"
done

s=$(( $(date +%s) - DEBUT_TOTAL ))
succes "instantané $CIBLE restauré en $((s / 60)) min $((s % 60)) s"
