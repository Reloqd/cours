#!/usr/bin/env bash
# Pannes des chapitres 22 et 23, à injecter depuis l'instantané I4.
#   lab/pannes.sh liste
#   lab/pannes.sh casser NN
#   lab/pannes.sh verifier NN
# Ne lis pas ce script avant d'avoir trouvé : il donne les causes.
set -euo pipefail
source "$(dirname "$0")/lib/commun.sh"

# Numéro | chapitre | symptôme (sans la cause)
PANNES=(
  "01|22|Les nouveaux pods de front ne démarrent pas et le déploiement n'avance plus."
  "02|22|Un pod de api redémarre en boucle."
  "03|22|Après un redémarrage de api, les nouveaux pods ne démarrent pas."
  "04|22|/api/ de front répond 504 au bout d'une minute ; api.boutique.example répond 503."
  "05|22|Le Service front (ClusterIP, NodePort 30080) ne répond plus, alors que les pods de front sont sains."
  "06|22|Les résolutions DNS échouent depuis les pods de boutique."
  "07|22|La mise à jour de front-v2 n'avance plus : aucun nouveau pod n'apparaît."
  "08|22|redis-0 reste Pending après un redémarrage."
  "09|22|Les pods de api tournent, mais le Service api n'a plus aucun backend."
  "10|22|redis-0 redémarre en boucle."
  "11|23|Les nouveaux pods restent Pending, sans aucun événement."
  "12|23|Un kubectl scale ne crée plus aucun pod."
  "13|23|Le nœud cka-m03 est NotReady."
  "14|23|Le nœud cka-m02 est NotReady."
  "15|23|kubectl n'obtient plus de réponse de l'API."
  "16|23|Plus aucune résolution DNS ne fonctionne dans le cluster."
  "17|23|Les Services existants répondent, mais un Service créé maintenant reste injoignable."
  "18|23|Les pods ont quitté cka-m02 et plus rien n'y est planifié."
  "19|23|kubectl échoue avec « connection refused »."
)

MANIFESTES=/etc/kubernetes/manifests
SAUVEGARDE=/root/lab-pannes   # copies d'origine, hors du dossier des manifestes

usage() { echo "usage : $0 liste | casser NN | verifier NN" >&2; exit 2; }

# --- Outils de vérification ----------------------------------------------------
ECHECS=0
controle() {  # controle "<description>" <commande…>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then succes "$desc"; else alerte "$desc : NON"; ECHECS=$((ECHECS + 1)); fi
}
egal() { [ "$1" = "$2" ]; }
depuis_outils() {  # code HTTP obtenu depuis le pod outils
  k -n boutique exec outils -- curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || true
}
http_ok_depuis_outils() { [ "$(depuis_outils "$1")" = "200" ]; }
rollout_fini() { k -n "$1" rollout status "$2" --timeout="${3:-20s}"; }
manifestes_propres() {  # rien d'autre que les 4 manifestes d'origine
  [ "$(ssh_noeud "$NOEUD_CP" "sudo ls -1 $MANIFESTES" | tr -d '\r' | sort | tr '\n' ' ')" \
    = "etcd.yaml kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml " ]
}
manifeste_contient() { ssh_noeud "$NOEUD_CP" "sudo grep -qF -- '$2' $MANIFESTES/$1"; }
pod_planifiable() {  # un pod de test reçoit un nœud
  k -n default delete pod verif-ordonnanceur --ignore-not-found --wait=true >/dev/null
  k -n default run verif-ordonnanceur --image=busybox:1.37.0 --restart=Never -- sleep 30 >/dev/null
  local ok=0
  k -n default wait --for=condition=PodScheduled pod/verif-ordonnanceur --timeout=30s >/dev/null 2>&1 || ok=1
  k -n default delete pod verif-ordonnanceur --wait=false >/dev/null 2>&1 || true
  return $ok
}
sauvegarder() {  # sauvegarder <nœud> <fichier>
  ssh_noeud "$1" "sudo mkdir -p $SAUVEGARDE && sudo cp -n $2 $SAUVEGARDE/"
}
cle_redis_ok() { [ "$(k -n boutique exec redis-0 -- redis-cli GET commandes 2>/dev/null | tr -d "\r")" = "42" ]; }
noeud_pret() { [ "$(k get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = "True" ]; }

# --- Pannes du chapitre 22 -----------------------------------------------------
casser_01() { k -n boutique set image deployment/front nginx=nginx:1.30.6-alpnie; }
verifier_01() {
  controle "image de front = nginx:1.30.6-alpine" \
    egal "$(k -n boutique get deploy front -o jsonpath='{.spec.template.spec.containers[0].image}')" nginx:1.30.6-alpine
  controle "rollout de front terminé" rollout_fini boutique deployment/front
  controle "3 pods front prêts" egal "$(k -n boutique get deploy front -o jsonpath='{.status.readyReplicas}')" 3
  controle "front répond 200 depuis outils" http_ok_depuis_outils http://front/
}

casser_02() {
  k -n boutique patch deployment api --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--option-inconnue"}]'
}
verifier_02() {
  controle "args de api = [netexec --http-port=8080]" \
    egal "$(k -n boutique get deploy api -o jsonpath='{.spec.template.spec.containers[0].args}')" '["netexec","--http-port=8080"]'
  controle "rollout de api terminé" rollout_fini boutique deployment/api
  controle "aucun pod api en CrashLoopBackOff" \
    sh -c "! kubectl --context '$CTX' -n boutique get pods -l app=api --no-headers | grep -q CrashLoopBackOff"
  controle "api répond depuis outils" http_ok_depuis_outils http://api:8080/hostname
}

casser_03() {
  local v
  v=$(k -n boutique get secret api-secret -o jsonpath='{.data.DB_PASSWORD}')
  [ -n "$v" ] || echec "clé DB_PASSWORD absente : le cluster n'est pas dans l'état I4."
  k -n boutique patch secret api-secret --type=merge -p "{\"data\":{\"DB_PASS\":\"$v\",\"DB_PASSWORD\":null}}"
  k -n boutique rollout restart deployment/api
}
verifier_03() {
  controle "Secret api-secret : DB_PASSWORD = changeme-123" \
    egal "$(k -n boutique get secret api-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d)" changeme-123
  controle "api lit toujours la clé DB_PASSWORD" \
    egal "$(k -n boutique get deploy api -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DB_PASSWORD")].valueFrom.secretKeyRef.key}')" DB_PASSWORD
  controle "rollout de api terminé" rollout_fini boutique deployment/api
  if k -n boutique get secret api-secret -o jsonpath='{.data.DB_PASS}' | grep -q .; then
    info "(la clé DB_PASS reste dans le Secret : inutile, tu peux la retirer)"
  fi
}

casser_04() { k -n boutique patch service api -p '{"spec":{"selector":{"app":"apl"}}}'; }
verifier_04() {
  controle "sélecteur du Service api = app=api, sans autre clé" \
    egal "$(k -n boutique get svc api -o jsonpath='{.spec.selector}')" '{"app":"api"}'
  controle "EndpointSlice de api avec des adresses prêtes" \
    sh -c "kubectl --context '$CTX' -n boutique get endpointslices -l kubernetes.io/service-name=api -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].addresses[0]}' | grep -q ."
  controle "front relaie /api/hostname (200)" http_ok_depuis_outils http://front/api/hostname
}

casser_05() { k -n boutique patch service front --type=json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]'; }
verifier_05() {
  controle "targetPort du Service front = 80" \
    egal "$(k -n boutique get svc front -o jsonpath='{.spec.ports[0].targetPort}')" 80
  controle "nodePort du Service front = 30080" \
    egal "$(k -n boutique get svc front -o jsonpath='{.spec.ports[0].nodePort}')" 30080
  controle "front répond 200 depuis outils" http_ok_depuis_outils http://front/
  controle "NodePort 30080 répond 200 depuis l'hôte" \
    sh -c "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://$(ip_noeud_cp):30080/ | grep -qx 200"
}

casser_06() {
  k -n boutique patch networkpolicy autorise-dns --type=json -p \
    '[{"op":"replace","path":"/spec/egress/0/ports/0/port","value":5353},{"op":"replace","path":"/spec/egress/0/ports/1/port","value":5353}]'
}
verifier_06() {
  controle "autorise-dns ouvre UDP 53 et TCP 53" \
    egal "$(k -n boutique get networkpolicy autorise-dns -o jsonpath='{range .spec.egress[0].ports[*]}{.protocol}/{.port} {end}')" "UDP/53 TCP/53 "
  controle "un pod front résout api.boutique.svc.cluster.local" \
    k -n boutique exec deploy/front -- nslookup -timeout=3 api.boutique.svc.cluster.local
}

casser_07() {
  k -n boutique patch deployment front-v2 --type=json -p \
    '[{"op":"replace","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"cpu":"2","memory":"32Mi"},"limits":{"cpu":"2","memory":"64Mi"}}}]'
}
millicpu() { case "$1" in *m) echo "${1%m}" ;; "") echo 0 ;; *) echo $(( ${1%.*} * 1000 )) ;; esac; }
dans_les_bornes() { [ "$(millicpu "$1")" -gt 0 ] && [ "$(millicpu "$1")" -le 1000 ] && [ "$(millicpu "$2")" -le 1000 ]; }
verifier_07() {
  local req lim
  req=$(k -n boutique get deploy front-v2 -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')
  lim=$(k -n boutique get deploy front-v2 -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}')
  controle "front-v2 : CPU dans les bornes de boutique-limites (max 1)" dans_les_bornes "$req" "$lim"
  controle "rollout de front-v2 terminé" rollout_fini boutique deployment/front-v2
  controle "front-v2 : 1 réplica prêt" egal "$(k -n boutique get deploy front-v2 -o jsonpath='{.spec.replicas}/{.status.readyReplicas}')" "1/1"
  [ "$req/$lim" = "50m/200m" ] || info "(valeurs d'origine : requests cpu 50m, limits cpu 200m ; tu as mis $req/$lim)"
}

casser_08() {
  k label node "$NOEUD_3" disque=hdd --overwrite
  k -n boutique delete pod redis-0 --wait=true
}
verifier_08() {
  controle "$NOEUD_3 porte disque=ssd" egal "$(k get node "$NOEUD_3" -o jsonpath='{.metadata.labels.disque}')" ssd
  controle "redis-0 prêt" k -n boutique wait --for=condition=Ready pod/redis-0 --timeout=60s
  controle "redis-0 tourne sur $NOEUD_3" egal "$(k -n boutique get pod redis-0 -o jsonpath='{.spec.nodeName}')" "$NOEUD_3"
  controle "redis a gardé la clé commandes (42)" cle_redis_ok
}

casser_09() {
  local ancien
  ancien=$(k -n boutique get rs -l app=api -o jsonpath='{range .items[?(@.spec.replicas>0)]}{.metadata.name}{"\n"}{end}')
  k -n boutique patch deployment api --type=json \
    -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":8081}]'
  sleep 5
  for rs in $ancien; do k -n boutique scale rs "$rs" --replicas=0; done
}
verifier_09() {
  controle "sonde de disponibilité de api sur /hostname, port http" \
    egal "$(k -n boutique get deploy api -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path} {.spec.template.spec.containers[0].readinessProbe.httpGet.port}')" "/hostname http"
  controle "rollout de api terminé" rollout_fini boutique deployment/api 60s
  controle "Service api avec des backends prêts" \
    sh -c "kubectl --context '$CTX' -n boutique get endpointslices -l kubernetes.io/service-name=api -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].addresses[0]}' | grep -q ."
  controle "api répond depuis outils" http_ok_depuis_outils http://api:8080/hostname
}

casser_10() {
  k -n boutique patch statefulset redis --type=json \
    -p '[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"4Mi"},{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"5Mi"}]'
}
verifier_10() {
  controle "redis : limits memory 256Mi, requests memory 64Mi" \
    egal "$(k -n boutique get sts redis -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}/{.spec.template.spec.containers[0].resources.requests.memory}')" "256Mi/64Mi"
  controle "redis-0 à la dernière révision du StatefulSet" \
    egal "$(k -n boutique get sts redis -o jsonpath='{.status.updateRevision}')" "$(k -n boutique get pod redis-0 -o jsonpath='{.metadata.labels.controller-revision-hash}')"
  controle "redis-0 prêt" k -n boutique wait --for=condition=Ready pod/redis-0 --timeout=60s
  controle "redis a gardé la clé commandes (42)" cle_redis_ok
}

# --- Pannes du chapitre 23 -----------------------------------------------------
casser_11() {
  sauvegarder "$NOEUD_CP" "$MANIFESTES/kube-scheduler.yaml"
  ssh_noeud "$NOEUD_CP" "sudo sed -i 's#kube-scheduler:$K8S_VERSION#kube-scheduler:v1.37.99#' $MANIFESTES/kube-scheduler.yaml"
}
verifier_11() {
  controle "image du scheduler = registry.k8s.io/kube-scheduler:$K8S_VERSION" \
    manifeste_contient kube-scheduler.yaml "image: registry.k8s.io/kube-scheduler:$K8S_VERSION"
  controle "aucun fichier en trop dans $MANIFESTES" manifestes_propres
  controle "kube-scheduler prêt" k -n kube-system wait --for=condition=Ready pod -l component=kube-scheduler --timeout=60s
  controle "un nouveau pod est planifié" pod_planifiable
}

casser_12() {
  sauvegarder "$NOEUD_CP" "$MANIFESTES/kube-controller-manager.yaml"
  ssh_noeud "$NOEUD_CP" "sudo sed -i 's#- --kubeconfig=/etc/kubernetes/controller-manager.conf#- --kubeconfig=/etc/kubernetes/controleur-manager.conf#' $MANIFESTES/kube-controller-manager.yaml"
}
verifier_12() {
  controle "--kubeconfig du controller-manager = /etc/kubernetes/controller-manager.conf" \
    manifeste_contient kube-controller-manager.yaml "- --kubeconfig=/etc/kubernetes/controller-manager.conf"
  controle "aucun fichier en trop dans $MANIFESTES" manifestes_propres
  controle "kube-controller-manager prêt" \
    k -n kube-system wait --for=condition=Ready pod -l component=kube-controller-manager --timeout=60s
  k -n default delete deployment verif-controleur --ignore-not-found >/dev/null
  k -n default create deployment verif-controleur --image=busybox:1.37.0 -- sleep 3600 >/dev/null
  controle "un Deployment de test obtient son pod" \
    k -n default wait --for=condition=Available deployment/verif-controleur --timeout=90s
  k -n default delete deployment verif-controleur --wait=false >/dev/null
}

casser_13() { ssh_noeud "$NOEUD_3" 'sudo systemctl disable --now kubelet'; }
verifier_13() {
  controle "kubelet de $NOEUD_3 activé au démarrage" \
    sh -c "minikube -p '$PROFIL' ssh -n '$NOEUD_3' -- systemctl is-enabled kubelet | grep -q '^enabled'"
  controle "kubelet de $NOEUD_3 actif" ssh_noeud "$NOEUD_3" 'systemctl is-active --quiet kubelet'
  controle "$NOEUD_3 Ready" noeud_pret "$NOEUD_3"
  controle "plus de taint unreachable sur $NOEUD_3" \
    sh -c "! kubectl --context '$CTX' get node '$NOEUD_3' -o jsonpath='{.spec.taints[*].key}' | grep -q unreachable"
}

casser_14() {
  sauvegarder "$NOEUD_2" /var/lib/kubelet/config.yaml
  ssh_noeud "$NOEUD_2" "sudo sed -i 's#clientCAFile: /var/lib/minikube/certs/ca.crt#clientCAFile: /var/lib/minikube/certs/ca-client.crt#' /var/lib/kubelet/config.yaml && sudo systemctl restart kubelet"
}
verifier_14() {
  controle "clientCAFile du kubelet de $NOEUD_2 = /var/lib/minikube/certs/ca.crt" \
    ssh_noeud "$NOEUD_2" "sudo grep -q 'clientCAFile: /var/lib/minikube/certs/ca.crt\$' /var/lib/kubelet/config.yaml"
  controle "kubelet de $NOEUD_2 actif" ssh_noeud "$NOEUD_2" 'systemctl is-active --quiet kubelet'
  controle "$NOEUD_2 Ready" noeud_pret "$NOEUD_2"
}

casser_15() {
  sauvegarder "$NOEUD_CP" "$MANIFESTES/kube-apiserver.yaml"
  ssh_noeud "$NOEUD_CP" "sudo sed -i 's#--etcd-servers=https://127.0.0.1:2379#--etcd-servers=https://127.0.0.1:2380#' $MANIFESTES/kube-apiserver.yaml"
  info "l'API va tomber dans les secondes qui viennent"
}
verifier_15() {
  controle "--etcd-servers de l'apiserver = https://127.0.0.1:2379" \
    manifeste_contient kube-apiserver.yaml "--etcd-servers=https://127.0.0.1:2379"
  controle "aucun fichier en trop dans $MANIFESTES" manifestes_propres
  controle "l'API répond (/readyz)" k get --raw /readyz
  controle "kube-apiserver prêt" k -n kube-system wait --for=condition=Ready pod -l component=kube-apiserver --timeout=60s
}

casser_16() {
  k -n kube-system get configmap coredns -o yaml | sed 's/^\( *\)forward \. /\1foward . /' | k replace -f -
  # Un kubelet au cache de ConfigMap en retard peut monter l'ancien Corefile :
  # on recommence tant qu'un pod CoreDNS devient prêt.
  local essai
  for essai in 1 2 3 4; do
    sleep 5
    k -n kube-system delete pod -l k8s-app=kube-dns --wait=true >/dev/null
    sleep 20
    k -n kube-system get pods -l k8s-app=kube-dns \
      -o jsonpath='{.items[*].status.containerStatuses[0].ready}' | grep -q true || break
  done
}
verifier_16() {
  local cf
  cf=$(k -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')
  controle "Corefile : forward . /etc/resolv.conf" sh -c "printf '%s' \"\$1\" | grep -q 'forward \. /etc/resolv.conf'" _ "$cf"
  controle "Corefile : aucune directive inconnue (foward)" sh -c "! printf '%s' \"\$1\" | grep -q foward" _ "$cf"
  controle "Corefile : entrée hosts du chapitre 11 conservée" sh -c "printf '%s' \"\$1\" | grep -q 'boutique.example api.boutique.example'" _ "$cf"
  controle "CoreDNS : 2 réplicas prêts" egal "$(k -n kube-system get deploy coredns -o jsonpath='{.status.readyReplicas}')" 2
  controle "outils résout api.boutique.svc.cluster.local" \
    k -n boutique exec outils -- nslookup -timeout=3 api.boutique.svc.cluster.local
  controle "outils résout boutique.example" k -n boutique exec outils -- nslookup -timeout=3 boutique.example
}

casser_17() {
  k -n kube-system get configmap kube-proxy -o yaml | sed 's/^\( *\)mode: iptables$/\1mode: iptable/' | k replace -f -
  k -n kube-system delete pod -l k8s-app=kube-proxy --wait=false
}
verifier_17() {
  controle "ConfigMap kube-proxy : mode iptables" \
    sh -c "kubectl --context '$CTX' -n kube-system get configmap kube-proxy -o jsonpath='{.data.config\\.conf}' | grep -q '^mode: iptables\$'"
  controle "kube-proxy prêt sur les 3 nœuds" rollout_fini kube-system daemonset/kube-proxy 60s
  k -n boutique delete service verif-proxy --ignore-not-found >/dev/null
  k -n boutique create service clusterip verif-proxy --tcp=8080:8080 >/dev/null
  k -n boutique set selector service verif-proxy app=api >/dev/null
  sleep 3
  controle "un Service créé maintenant répond" http_ok_depuis_outils http://verif-proxy:8080/hostname
  k -n boutique delete service verif-proxy >/dev/null
}

casser_18() {
  k cordon "$NOEUD_2"
  k taint node "$NOEUD_2" maintenance=oui:NoExecute --overwrite
}
verifier_18() {
  controle "$NOEUD_2 planifiable" \
    sh -c "[ -z \"\$(kubectl --context '$CTX' get node '$NOEUD_2' -o jsonpath='{.spec.unschedulable}')\" ]"
  controle "plus de taint maintenance sur $NOEUD_2" \
    sh -c "! kubectl --context '$CTX' get node '$NOEUD_2' -o jsonpath='{.spec.taints[*].key}' | grep -q maintenance"
  controle "agent-noeud tourne sur les 3 nœuds" rollout_fini boutique daemonset/agent-noeud 60s
  controle "plugin CSI revenu sur les 3 nœuds" rollout_fini kube-system daemonset/csi-hostpathplugin 120s
  controle "speaker MetalLB revenu sur les 3 nœuds" rollout_fini metallb-system daemonset/speaker 60s
}

casser_19() {
  local srv
  srv=$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$PROFIL\")].cluster.server}")
  kubectl config set-cluster "$PROFIL" --server="${srv%:*}:6443" >/dev/null
  info "kubeconfig modifié"
}
verifier_19() {
  controle "serveur du cluster $PROFIL = https://$(ip_noeud_cp):8443" \
    egal "$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$PROFIL\")].cluster.server}")" "https://$(ip_noeud_cp):8443"
  controle "kubectl joint l'API" k get --raw /readyz
}

# --- Aiguillage ------------------------------------------------------------------
[ $# -ge 1 ] || usage
case "$1" in
  liste)
    printf '%-4s %-9s %s\n' "N°" "Chapitre" "Symptôme"
    for p in "${PANNES[@]}"; do
      IFS='|' read -r n c s <<<"$p"
      printf '%-4s %-9s %s\n' "$n" "$c" "${s//cka-m0/$PROFIL-m0}"
    done
    ;;
  casser|verifier)
    [ $# -eq 2 ] || usage
    n=$(printf '%02d' "$((10#$2))" 2>/dev/null) || usage
    declare -F "casser_$n" >/dev/null || echec "panne inconnue : $2 (01 à 19)"
    if [ "$1" = casser ]; then
      verifier_cluster
      existe namespace boutique || echec "namespace boutique absent : restaure d'abord l'instantané I4."
      info "injection de la panne $n"
      "casser_$n" 2> >(grep -v '^Warning: would violate PodSecurity' >&2)
      for p in "${PANNES[@]}"; do
        [ "${p%%|*}" = "$n" ] && info "symptôme attendu : ${p##*|}"
      done
    else
      info "vérification de la panne $n"
      "verifier_$n"
      if [ "$ECHECS" -eq 0 ]; then
        succes "panne $n réparée proprement"
      else
        echec "panne $n : $ECHECS contrôle(s) en échec"
      fi
    fi
    ;;
  *) usage ;;
esac
