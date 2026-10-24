#!/usr/bin/env bash
# Vérifie les prérequis, démarre le profil minikube du cours et attend les nœuds (instantané I0).
set -euo pipefail
source "$(dirname "$0")/lib/commun.sh"

verifier_prerequis() {
  local outil manquant=0
  for outil in docker minikube kubectl helm openssl curl; do
    command -v "$outil" >/dev/null 2>&1 || { alerte "outil absent du PATH : $outil"; manquant=1; }
  done
  [ "$manquant" -eq 0 ] || echec "installe les outils manquants (chapitre 1)."

  docker info >/dev/null 2>&1 || echec "Docker n'est pas utilisable sans sudo (groupe docker ?)."

  local v
  v=$(minikube version --short 2>/dev/null || true)
  [ "$v" = "$MINIKUBE_VERSION" ] || alerte "minikube $v détecté, le cours est écrit pour $MINIKUBE_VERSION."
  v=$(kubectl version --client -o json 2>/dev/null | sed -n 's/.*"minor": *"\([0-9]*\).*/\1/p' | head -1)
  [ "$v" = "37" ] || alerte "kubectl 1.${v:-?} détecté, le cours vise kubectl 1.37."
  v=$(helm version --template '{{.Version}}' 2>/dev/null || true)
  case "$v" in v4.*) ;; *) alerte "Helm ${v:-?} détecté, le cours vise Helm 4." ;; esac

  local inst watches
  inst=$(cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null || echo 0)
  watches=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
  if [ "$inst" -lt 512 ] || [ "$watches" -lt 524288 ]; then
    alerte "limite inotify trop basse : max_user_instances=$inst, max_user_watches=$watches."
    alerte "corrige-la : sudo sysctl fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288"
    if [ "${CKA_FORCER:-0}" = "1" ]; then
      alerte "CKA_FORCER=1 : on continue (risque de « Too many open files » et de nœuds NotReady)."
    else
      echec "démarrage refusé (CKA_FORCER=1 pour passer outre)."
    fi
  fi

  local libre
  libre=$(awk '/MemAvailable/ {print int($2 / 1048576)}' /proc/meminfo)
  [ "$libre" -ge 10 ] || alerte "seulement $libre Gio de RAM disponibles (12 conseillés)."
}

info "vérification des prérequis"
verifier_prerequis

if docker network inspect "$PROFIL" >/dev/null 2>&1 && ! docker container inspect "$PROFIL" >/dev/null 2>&1; then
  alerte "réseau Docker « $PROFIL » orphelin : suppression"
  minikube -p "$PROFIL" delete >/dev/null 2>&1 || true
fi

chrono_debut
info "démarrage du profil $PROFIL (Kubernetes $K8S_VERSION, 3 nœuds, Calico)"
minikube start -p "$PROFIL" --driver=docker --container-runtime=containerd \
  --kubernetes-version="$K8S_VERSION" --nodes=3 --cni=calico --cpus=2 --memory=3072

info "attente des nœuds Ready (les images Calico se téléchargent sur chaque nœud)"
k wait --for=condition=Ready node --all --timeout=10m
k -n kube-system rollout status daemonset/calico-node --timeout=10m
k -n kube-system rollout status deployment/coredns --timeout=5m
succes "cluster $PROFIL prêt en $(chrono_fin) (instantané I0)"
k get nodes -o wide
