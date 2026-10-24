#!/usr/bin/env bash
# Chapitre 15 : volume local archives (StorageClass manuel), addons CSI,
# StorageClass rapide, StatefulSet redis (clé écrite, volume porté à 2Gi)
# et VolumeSnapshot redis-instantane.
set -euo pipefail
source "$(dirname "$0")/../../lib/commun.sh"
cd "$(dirname "$0")"
verifier_cluster

# --- Volume local statique ---------------------------------------------------
# journal.txt : ce qu'y a écrit le pod archiveur de l'exercice 15.1.
ssh_noeud "$NOEUD_2" 'sudo mkdir -p /mnt/archives && { sudo test -s /mnt/archives/journal.txt || date | sudo tee /mnt/archives/journal.txt >/dev/null; }'
appliquer archives.yaml
k -n boutique wait --for=jsonpath='{.status.phase}'=Bound pvc/archives --timeout=60s

# --- Provisionnement dynamique CSI ------------------------------------------
activer_addon volumesnapshots kube-system deployment/snapshot-controller
activer_addon csi-hostpath-driver kube-system daemonset/csi-hostpathplugin
deploiement_pret kube-system snapshot-controller
k -n kube-system rollout status daemonset/csi-hostpathplugin --timeout=600s
k -n kube-system rollout status statefulset/csi-hostpath-attacher --timeout=300s
k -n kube-system rollout status statefulset/csi-hostpath-resizer --timeout=300s

appliquer storageclass-rapide.yaml
appliquer redis.yaml
k -n boutique rollout status statefulset/redis --timeout=600s
k -n boutique wait --for=condition=Ready pod/redis-0 --timeout=300s

if [ -z "$(k -n boutique exec redis-0 -- redis-cli GET commandes)" ]; then
  k -n boutique exec redis-0 -- redis-cli SET commandes 42
fi

# --- Agrandissement à 2Gi ----------------------------------------------------
# Le csi-resizer de l'addon (StatefulSet, un seul pod) ne parle qu'au plugin de
# son propre nœud : ailleurs, « volume id … does not exist in the volumes list ».
# On le place sur le nœud du volume, celui de redis-0.
noeud=$(k -n boutique get pod redis-0 -o jsonpath='{.spec.nodeName}')
k -n kube-system patch statefulset csi-hostpath-resizer \
  -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"$noeud\"}}}}}"
k -n kube-system rollout status statefulset/csi-hostpath-resizer --timeout=300s
k -n boutique patch pvc data-redis-0 -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
attendre 300 "agrandissement de data-redis-0" \
  sh -c "kubectl --context '$CTX' -n boutique get pvc data-redis-0 -o jsonpath='{.status.capacity.storage}' | grep -qx 2Gi"

# --- Instantané --------------------------------------------------------------
appliquer redis-instantane.yaml
k -n boutique wait --for=jsonpath='{.status.readyToUse}'=true volumesnapshot/redis-instantane --timeout=300s
succes "stockage en place (instantané I3 si tu t'arrêtes ici)"
