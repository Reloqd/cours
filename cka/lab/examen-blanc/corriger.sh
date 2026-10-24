#!/usr/bin/env bash
# Correction de l'examen blanc : note par tâche, total sur 100, seuil 66.
set -euo pipefail
source "$(dirname "$0")/../lib/commun.sh"

EXAMEN="$CKA_DOSSIER/examen"
verifier_cluster

TOTAL=0
NOTE=0
TACHE_PTS=0
tache() {  # tache <n°> <points> <intitulé>
  fin_tache
  TACHE_N="$1"; TACHE_MAX="$2"; TACHE_PTS=0
  printf '\n%sTâche %s%s (%s pts) — %s\n' "$_C_BLEU" "$1" "$_C_RAZ" "$2" "$3"
}
fin_tache() {
  if [ -n "${TACHE_N:-}" ]; then
    printf '   => %s/%s\n' "$TACHE_PTS" "$TACHE_MAX"
    NOTE=$((NOTE + TACHE_PTS)); TOTAL=$((TOTAL + TACHE_MAX))
  fi
  TACHE_N=""
}
critere() {  # critere <points> "<description>" <commande…>
  local pts="$1" desc="$2"; shift 2
  if "$@" >/dev/null 2>&1; then
    printf '   %s[+%s]%s %s\n' "$_C_VERT" "$pts" "$_C_RAZ" "$desc"; TACHE_PTS=$((TACHE_PTS + pts))
  else
    printf '   %s[ 0]%s %s\n' "$_C_ROUGE" "$_C_RAZ" "$desc"
  fi
}
egal() { [ "$1" = "$2" ]; }
jp() { k "$@" 2>/dev/null || true; }   # lecture tolérante : objet absent = chaîne vide
injectee() { [ "$(jp -n default get configmap examen-blanc -o jsonpath="{.data.$1}")" = "injectee" ]; }

IP=$(ip_noeud_cp)

# ------------------------------------------------------------------------------
tache 1 4 "nœuds et InternalIP dans t01.txt"
attendu=$(k get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' | sort)
obtenu=$(sed -e 's/\r$//' -e 's/[[:space:]]\+/ /g' -e 's/ $//' "$EXAMEN/t01.txt" 2>/dev/null | grep -v '^$' || true)
critere 4 "t01.txt contient « nom InternalIP » par nœud, trié par nom" egal "$obtenu" "$attendu"

# ------------------------------------------------------------------------------
tache 2 7 "ServiceAccount lecteur et Role lecture-pods (examen-rbac)"
critere 1 "ServiceAccount lecteur" k -n examen-rbac get sa lecteur
res=$(jp -n examen-rbac get role lecture-pods -o jsonpath='{.rules[*].resources[*]}')
verbes=$(jp -n examen-rbac get role lecture-pods -o jsonpath='{.rules[*].verbs[*]}' | tr ' ' '\n' | sort | tr '\n' ' ')
critere 2 "Role lecture-pods : get, list, watch sur pods" egal "$res|$verbes" "pods|get list watch "
critere 2 "RoleBinding lecteur-pods : Role lecture-pods -> SA examen-rbac/lecteur" egal \
  "$(jp -n examen-rbac get rolebinding lecteur-pods -o jsonpath='{.roleRef.kind}/{.roleRef.name}/{.subjects[?(@.kind=="ServiceAccount")].name}/{.subjects[?(@.kind=="ServiceAccount")].namespace}')" \
  "Role/lecture-pods/lecteur/examen-rbac"
critere 2 "auth can-i : list pods oui, delete pods non" sh -c "
  kubectl --context '$CTX' auth can-i list pods -n examen-rbac --as=system:serviceaccount:examen-rbac:lecteur | grep -qx yes &&
  kubectl --context '$CTX' auth can-i delete pods -n examen-rbac --as=system:serviceaccount:examen-rbac:lecteur | grep -qx no"

# ------------------------------------------------------------------------------
tache 3 6 "Deployment web : mise à jour puis retour à la révision 1 (examen-app)"
critere 1 "web : 3 réplicas" egal "$(jp -n examen-app get deploy web -o jsonpath='{.spec.replicas}')" 3
critere 1 "stratégie maxSurge 2, maxUnavailable 1" egal \
  "$(jp -n examen-app get deploy web -o jsonpath='{.spec.strategy.rollingUpdate.maxSurge}/{.spec.strategy.rollingUpdate.maxUnavailable}')" "2/1"
critere 1 "un ReplicaSet en nginx:1.30.6-alpine prouve la mise à jour" sh -c \
  "kubectl --context '$CTX' -n examen-app get rs -l app=web -o jsonpath='{.items[*].spec.template.spec.containers[*].image}' | grep -q 'nginx:1.30.6-alpine'"
critere 2 "image courante nginx:1.29-alpine en révision 3 ou plus" sh -c "
  [ \"\$(kubectl --context '$CTX' -n examen-app get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}')\" = nginx:1.29-alpine ] &&
  [ \"\$(kubectl --context '$CTX' -n examen-app get deploy web -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')\" -ge 3 ]"
critere 1 "3 pods prêts" egal "$(jp -n examen-app get deploy web -o jsonpath='{.status.readyReplicas}')" 3

# ------------------------------------------------------------------------------
tache 4 5 "pod config-pod : ConfigMap et Secret (examen-app)"
critere 1 "config-pod Running" egal "$(jp -n examen-app get pod config-pod -o jsonpath='{.status.phase}')" Running
critere 2 "MODE=examen, tiré de la ConfigMap parametres" sh -c "
  kubectl --context '$CTX' -n examen-app get pod config-pod -o jsonpath='{.spec.containers[0].env[?(@.name==\"MODE\")].valueFrom.configMapKeyRef.name}{.spec.containers[0].envFrom[*].configMapRef.name}' | grep -q parametres &&
  [ \"\$(kubectl --context '$CTX' -n examen-app exec config-pod -- printenv MODE)\" = examen ]"
critere 2 "Secret identifiants lisible dans /etc/secret/password" egal \
  "$(jp -n examen-app exec config-pod -- cat /etc/secret/password)" "Examen-2026"

# ------------------------------------------------------------------------------
tache 5 6 "HPA calcul (examen-app)"
hpa() { jp -n examen-app get hpa calcul -o jsonpath="$1"; }
critere 1 "HPA calcul vise le Deployment calcul" egal "$(hpa '{.spec.scaleTargetRef.kind}/{.spec.scaleTargetRef.name}')" "Deployment/calcul"
critere 2 "min 1, max 5" egal "$(hpa '{.spec.minReplicas}/{.spec.maxReplicas}')" "1/5"
critere 2 "CPU averageUtilization 60" egal \
  "$(hpa '{.spec.metrics[?(@.resource.name=="cpu")].resource.target.averageUtilization}')" 60
critere 1 "stabilisation de descente 30 s" egal "$(hpa '{.spec.behavior.scaleDown.stabilizationWindowSeconds}')" 30

# ------------------------------------------------------------------------------
tache 6 6 "pod rapide : affinité requise et toleration (examen-sched)"
rp() { jp -n examen-sched get pod rapide -o jsonpath="$1"; }
critere 1 "image nginx:1.30.6-alpine" egal "$(rp '{.spec.containers[0].image}')" nginx:1.30.6-alpine
critere 2 "affinité requise disque In [ssd]" egal \
  "$(rp '{.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[*].matchExpressions[?(@.key=="disque")].operator}/{.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[*].matchExpressions[?(@.key=="disque")].values[*]}')" "In/ssd"
critere 1 "toleration de la taint dedie" egal "$(rp '{.spec.tolerations[?(@.key=="dedie")].key}')" dedie
noeud=$(rp '{.spec.nodeName}')
critere 2 "Running sur le nœud disque=ssd" sh -c "
  [ \"\$(kubectl --context '$CTX' -n examen-sched get pod rapide -o jsonpath='{.status.phase}')\" = Running ] &&
  [ \"\$(kubectl --context '$CTX' get node '${noeud:-aucun}' -o jsonpath='{.metadata.labels.disque}')\" = ssd ]"

# ------------------------------------------------------------------------------
tache 7 5 "pod journal avec sidecar natif (examen-app)"
side=$(jp -n examen-app get pod journal -o jsonpath='{.spec.initContainers[?(@.restartPolicy=="Always")].name}')
critere 2 "un init container restartPolicy: Always (sidecar natif)" test -n "$side"
critere 1 "le sidecar suit /var/log/app.log" sh -c \
  "kubectl --context '$CTX' -n examen-app get pod journal -o jsonpath='{.spec.initContainers[?(@.restartPolicy==\"Always\")].command} {.spec.initContainers[?(@.restartPolicy==\"Always\")].args}' | grep -q /var/log/app.log"
critere 2 "journal prêt et le sidecar affiche des lignes" sh -c "
  kubectl --context '$CTX' -n examen-app wait --for=condition=Ready pod/journal --timeout=5s &&
  [ -n \"\$(kubectl --context '$CTX' -n examen-app logs journal -c '${side:-aucun}' --tail=5)\" ]"

# ------------------------------------------------------------------------------
tache 8 7 "Service catalogue réparé et NodePort catalogue-np (examen-svc)"
critere 3 "Service catalogue avec des backends prêts, Deployment inchangé" sh -c "
  [ \"\$(kubectl --context '$CTX' -n examen-svc get deploy catalogue -o jsonpath='{.spec.template.metadata.labels.app}')\" = catalogue ] &&
  kubectl --context '$CTX' -n examen-svc get endpointslices -l kubernetes.io/service-name=catalogue -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].addresses[0]}' | grep -q ."
critere 2 "catalogue-np : NodePort 30090 vers le port 8080" egal \
  "$(jp -n examen-svc get svc catalogue-np -o jsonpath='{.spec.type}/{.spec.ports[0].nodePort}/{.spec.ports[0].targetPort}')" "NodePort/30090/8080"
critere 2 "http://$IP:30090/hostname répond un pod catalogue" sh -c \
  "curl -s --max-time 5 http://$IP:30090/hostname | grep -q '^catalogue-'"

# ------------------------------------------------------------------------------
tache 9 7 "HTTPRoute catalogue 80/20 (examen-gw)"
hr() { jp -n examen-gw get httproute catalogue -o jsonpath="$1"; }
critere 1 "attachée au Gateway examen-gw" egal "$(hr '{.spec.parentRefs[0].name}')" examen-gw
critere 1 "hôte catalogue.example" egal "$(hr '{.spec.hostnames[*]}')" catalogue.example
critere 2 "catalogue-v1 poids 80, catalogue-v2 poids 20" egal \
  "$(hr '{.spec.rules[*].backendRefs[?(@.name=="catalogue-v1")].weight}/{.spec.rules[*].backendRefs[?(@.name=="catalogue-v2")].weight}')" "80/20"
critere 1 "route Accepted et ResolvedRefs" egal \
  "$(hr '{.status.parents[0].conditions[?(@.type=="Accepted")].status}/{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}')" "True/True"
gwip=$(jp -n examen-gw get gateway examen-gw -o jsonpath='{.status.addresses[0].value}')
v2=0; v1=0
if [ -n "$gwip" ]; then
  for _ in $(seq 100); do
    case "$(curl -s --max-time 3 -H 'Host: catalogue.example' "http://$gwip/hostname" || true)" in
      catalogue-v1-*) v1=$((v1 + 1)) ;; catalogue-v2-*) v2=$((v2 + 1)) ;;
    esac
  done
fi
critere 2 "partage observé sur 100 requêtes : v1=$v1 v2=$v2 (attendu ≈ 80/20)" \
  sh -c "[ $((v1 + v2)) -ge 95 ] && [ $v2 -ge 8 ] && [ $v2 -le 35 ]"

# ------------------------------------------------------------------------------
tache 10 5 "Ingress docs (examen-ing)"
ing() { jp -n examen-ing get ingress docs -o jsonpath="$1"; }
critere 1 "classe nginx" egal "$(ing '{.spec.ingressClassName}')" nginx
critere 1 "hôte docs.example" egal "$(ing '{.spec.rules[0].host}')" docs.example
critere 2 "/ Prefix -> docs:80" egal \
  "$(ing '{.spec.rules[0].http.paths[0].path}|{.spec.rules[0].http.paths[0].pathType}|{.spec.rules[0].http.paths[0].backend.service.name}|{.spec.rules[0].http.paths[0].backend.service.port.number}')" "/|Prefix|docs|80"
critere 1 "http://docs.example répond 200" sh -c \
  "curl -s -o /dev/null -w '%{http_code}' --max-time 5 --resolve docs.example:80:$IP http://docs.example/ | grep -qx 200"

# ------------------------------------------------------------------------------
tache 11 7 "NetworkPolicy bdd-entree (examen-net)"
np() { jp -n examen-net get networkpolicy bdd-entree -o jsonpath="$1"; }
critere 3 "sélecteur app=bdd, Ingress depuis role=front sur TCP 5432" sh -c "
  [ '$(np '{.spec.podSelector.matchLabels.app}')' = bdd ] &&
  echo '$(np '{.spec.policyTypes[*]}')' | grep -q Ingress &&
  [ '$(np '{.spec.ingress[*].from[*].podSelector.matchLabels.role}')' = front ] &&
  [ '$(np '{.spec.ingress[*].ports[*].port}')' = 5432 ]"
bdd=$(jp -n examen-net get pod bdd -o jsonpath='{.status.podIP}')
if existe -n examen-net networkpolicy bdd-entree; then
  critere 2 "front joint bdd:5432" k -n examen-net exec front -- wget -q -O /dev/null -T 3 "http://$bdd:5432/hostname"
  critere 2 "autre ne joint plus bdd:5432" sh -c \
    "! kubectl --context '$CTX' -n examen-net exec autre -- wget -q -O /dev/null -T 3 http://$bdd:5432/hostname"
else
  critere 4 "tests de connectivité (NetworkPolicy bdd-entree absente)" false
fi

# ------------------------------------------------------------------------------
tache 12 6 "StorageClass lente, PVC donnees, pod stockeur (examen-sto)"
critere 2 "lente : hostpath.csi.k8s.io, Retain, WaitForFirstConsumer" egal \
  "$(jp get storageclass lente -o jsonpath='{.provisioner}/{.reclaimPolicy}/{.volumeBindingMode}')" "hostpath.csi.k8s.io/Retain/WaitForFirstConsumer"
critere 2 "PVC donnees : 200Mi, RWO, lente, Bound" egal \
  "$(jp -n examen-sto get pvc donnees -o jsonpath='{.spec.resources.requests.storage}/{.spec.accessModes[0]}/{.spec.storageClassName}/{.status.phase}')" "200Mi/ReadWriteOnce/lente/Bound"
critere 2 "stockeur Running, donnees montée en /data" sh -c "
  [ \"\$(kubectl --context '$CTX' -n examen-sto get pod stockeur -o jsonpath='{.status.phase}')\" = Running ] &&
  vol=\$(kubectl --context '$CTX' -n examen-sto get pod stockeur -o jsonpath='{.spec.volumes[?(@.persistentVolumeClaim.claimName==\"donnees\")].name}') &&
  [ -n \"\$vol\" ] &&
  kubectl --context '$CTX' -n examen-sto get pod stockeur -o jsonpath=\"{.spec.containers[*].volumeMounts[?(@.name=='\$vol')].mountPath}\" | grep -qx /data"

# ------------------------------------------------------------------------------
tache 13 6 "sauvegarde etcd dans /var/lib/minikube/backup/examen.db"
critere 2 "fichier présent et non vide" ssh_noeud "$NOEUD_CP" 'sudo test -s /var/lib/minikube/backup/examen.db'
critere 4 "instantané etcd valide (etcdutl snapshot status)" \
  ssh_noeud "$NOEUD_CP" 'sudo etcdutl snapshot status /var/lib/minikube/backup/examen.db'

# ------------------------------------------------------------------------------
tache 14 6 "nœud $NOEUD_2 réparé"
if injectee t14; then
  critere 4 "$NOEUD_2 Ready" egal "$(jp get node "$NOEUD_2" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" True
  critere 2 "kubelet activé au démarrage" sh -c \
    "minikube -p '$PROFIL' ssh -n '$NOEUD_2' -- systemctl is-enabled kubelet | grep -q '^enabled'"
else
  critere 6 "panne non injectée (preparer.sh 14 jamais lancé)" false
fi

# ------------------------------------------------------------------------------
tache 15 6 "kube-scheduler réparé"
if injectee t15; then
  critere 2 "kube-scheduler prêt" k -n kube-system wait --for=condition=Ready pod -l component=kube-scheduler --timeout=10s
  critere 2 "manifeste corrigé, rien d'autre dans manifests/" sh -c "
    minikube -p '$PROFIL' ssh -n '$NOEUD_CP' -- sudo grep -qx \"'    - kube-scheduler'\" /etc/kubernetes/manifests/kube-scheduler.yaml &&
    [ \"\$(minikube -p '$PROFIL' ssh -n '$NOEUD_CP' -- sudo ls -1 /etc/kubernetes/manifests | tr -d '\r' | sort | tr '\n' ' ')\" = 'etcd.yaml kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml ' ]"
  k -n default delete pod verif-examen --ignore-not-found --wait=true >/dev/null 2>&1 || true
  k -n default run verif-examen --image=busybox:1.37.0 --restart=Never -- sleep 20 >/dev/null 2>&1 || true
  critere 2 "un nouveau pod est planifié" k -n default wait --for=condition=PodScheduled pod/verif-examen --timeout=30s
  k -n default delete pod verif-examen --wait=false >/dev/null 2>&1 || true
else
  critere 6 "panne non injectée (preparer.sh 15 jamais lancé)" false
fi

# ------------------------------------------------------------------------------
tache 16 5 "release Helm exam-podinfo (examen-helm)"
critere 2 "release exam-podinfo déployée" sh -c \
  "helm --kube-context '$CTX' -n examen-helm status exam-podinfo | grep -q 'STATUS: deployed'"
critere 1 "chart podinfo-$PODINFO_VERSION" sh -c \
  "helm --kube-context '$CTX' -n examen-helm list -f '^exam-podinfo\$' | grep -q 'podinfo-$PODINFO_VERSION'"
critere 2 "2 pods podinfo prêts" egal \
  "$(jp -n examen-helm get deploy exam-podinfo -o jsonpath='{.status.readyReplicas}')" 2

# ------------------------------------------------------------------------------
tache 17 6 "CRD de cert-manager.io, Issuer et Certificate (examen-crd)"
attendu=$(k get crd -o jsonpath='{range .items[?(@.spec.group=="cert-manager.io")]}{.metadata.name}{"\n"}{end}' | sort)
obtenu=$(sed 's/\r$//' "$EXAMEN/t17.txt" 2>/dev/null | awk 'NF && $1 != "NAME" {print $1}' | sort -u || true)
critere 2 "t17.txt liste exactement les CRD du groupe cert-manager.io" egal "$obtenu" "$attendu"
critere 2 "Issuer examen-issuer autosigné et prêt" egal \
  "$(jp -n examen-crd get issuer examen-issuer -o jsonpath='{.spec.selfSigned}/{.status.conditions[?(@.type=="Ready")].status}')" "{}/True"
critere 2 "Certificate examen-cert (examen.example -> examen-tls) prêt" sh -c "
  [ \"\$(kubectl --context '$CTX' -n examen-crd get certificate examen-cert -o jsonpath='{.spec.dnsNames[*]}/{.spec.secretName}/{.status.conditions[?(@.type==\"Ready\")].status}')\" = 'examen.example/examen-tls/True' ] &&
  kubectl --context '$CTX' -n examen-crd get secret examen-tls"

fin_tache
printf '\n'
if [ "$NOTE" -ge 66 ]; then
  succes "note : $NOTE / $TOTAL (seuil 66) — réussi"
else
  alerte "note : $NOTE / $TOTAL (seuil 66) — échec"
fi
info "pour repartir d'un cluster propre : lab/restaurer.sh I4"
