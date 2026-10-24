#!/usr/bin/env bash
# Examen blanc (annexe B), à lancer depuis l'instantané I4.
#   lab/examen-blanc/preparer.sh       remise à zéro puis préparation des tâches 1 à 17
#   lab/examen-blanc/preparer.sh 14    injecte la panne de la tâche 14
#   lab/examen-blanc/preparer.sh 15    injecte la panne de la tâche 15
set -euo pipefail
source "$(dirname "$0")/../lib/commun.sh"

EXAMEN="$CKA_DOSSIER/examen"
NAMESPACES="examen-rbac examen-app examen-sched examen-svc examen-gw examen-ing examen-net examen-sto examen-helm examen-crd"
SAUVEGARDE=/root/lab-examen   # copie d'origine du manifeste du scheduler, hors de manifests/

marquer() { k -n default patch configmap examen-blanc --type=merge -p "{\"data\":{\"$1\":\"injectee\"}}" >/dev/null; }

panne_14() {
  existe -n default configmap examen-blanc || echec "lance d'abord preparer.sh sans argument."
  local nus
  nus=$(k get pods -A --field-selector "spec.nodeName=$NOEUD_2" \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
    | grep '^examen-' || true)
  if [ -n "$nus" ]; then
    alerte "pods d'examen sur $NOEUD_2 ; après 5 minutes de NotReady, ceux qui n'ont pas de contrôleur seront supprimés :"
    printf '   %s\n' $nus >&2
  fi
  ssh_noeud "$NOEUD_2" 'sudo systemctl disable --now kubelet' 2>/dev/null
  marquer t14
  succes "tâche 14 prête : le nœud $NOEUD_2 passera NotReady d'ici une minute."
}

panne_15() {
  existe -n default configmap examen-blanc || echec "lance d'abord preparer.sh sans argument."
  ssh_noeud "$NOEUD_CP" "sudo mkdir -p $SAUVEGARDE && sudo cp -n /etc/kubernetes/manifests/kube-scheduler.yaml $SAUVEGARDE/ \
    && sudo sed -i 's/^\(    - \)kube-scheduler\$/\1kube-schedulr/' /etc/kubernetes/manifests/kube-scheduler.yaml"
  marquer t15
  succes "tâche 15 prête : les nouveaux pods vont rester Pending."
}

remise_a_zero() {
  info "remise à zéro d'un éventuel passage précédent"
  # Pannes 14 et 15 laissées en place.
  ssh_noeud "$NOEUD_2" 'sudo systemctl enable --now kubelet' >/dev/null 2>&1 || true
  ssh_noeud "$NOEUD_CP" "if sudo test -f $SAUVEGARDE/kube-scheduler.yaml; then \
      sudo cp $SAUVEGARDE/kube-scheduler.yaml /etc/kubernetes/manifests/kube-scheduler.yaml && sudo rm -rf $SAUVEGARDE; fi; \
      sudo rm -f /var/lib/minikube/backup/examen.db" >/dev/null
  k -n default delete configmap examen-blanc --ignore-not-found >/dev/null
  # shellcheck disable=SC2086
  k delete namespace $NAMESPACES --ignore-not-found --wait=true >/dev/null
  k delete storageclass lente --ignore-not-found >/dev/null
  local pv
  for pv in $(k get pv -o jsonpath='{range .items[?(@.spec.storageClassName=="lente")]}{.metadata.name}{" "}{end}'); do
    k delete pv "$pv" --wait=false >/dev/null
  done
  k taint nodes --all dedie- >/dev/null 2>&1 || true
  rm -f "$EXAMEN/t01.txt" "$EXAMEN/t17.txt"
  k wait --for=condition=Ready node --all --timeout=180s >/dev/null
  k -n kube-system wait --for=condition=Ready pod -l component=kube-scheduler --timeout=180s >/dev/null
}

prerequis_i4() {
  verifier_cluster
  existe -n boutique deployment front || echec "namespace boutique incomplet : restaure l'instantané I4."
  existe gatewayclass eg || echec "GatewayClass eg absente : restaure l'instantané I4."
  existe crd certificates.cert-manager.io || echec "cert-manager absent : restaure l'instantané I4."
  existe storageclass rapide || echec "addon csi-hostpath-driver absent : restaure l'instantané I4."
}

objets() {
  cat <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: parametres
  namespace: examen-app
data:
  MODE: examen
---
apiVersion: v1
kind: Secret
metadata:
  name: identifiants
  namespace: examen-app
stringData:
  password: Examen-2026
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: calcul
  namespace: examen-app
  labels:
    app: calcul
spec:
  replicas: 1
  selector:
    matchLabels:
      app: calcul
  template:
    metadata:
      labels:
        app: calcul
    spec:
      containers:
      - name: agnhost
        image: registry.k8s.io/e2e-test-images/agnhost:2.66.1
        args: ["netexec", "--http-port=8080"]
        resources:
          requests:
            cpu: 100m
            memory: 32Mi
          limits:
            cpu: 300m
            memory: 64Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalogue
  namespace: examen-svc
  labels:
    app: catalogue
spec:
  replicas: 2
  selector:
    matchLabels:
      app: catalogue
  template:
    metadata:
      labels:
        app: catalogue
    spec:
      containers:
      - name: agnhost
        image: registry.k8s.io/e2e-test-images/agnhost:2.66.1
        args: ["netexec", "--http-port=8080"]
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: catalogue
  namespace: examen-svc
spec:
  selector:
    app: catalog
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalogue-v1
  namespace: examen-gw
spec:
  replicas: 1
  selector:
    matchLabels:
      app: catalogue
      version: v1
  template:
    metadata:
      labels:
        app: catalogue
        version: v1
    spec:
      containers:
      - name: agnhost
        image: registry.k8s.io/e2e-test-images/agnhost:2.66.1
        args: ["netexec", "--http-port=8080"]
        ports:
        - containerPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: catalogue-v2
  namespace: examen-gw
spec:
  replicas: 1
  selector:
    matchLabels:
      app: catalogue
      version: v2
  template:
    metadata:
      labels:
        app: catalogue
        version: v2
    spec:
      containers:
      - name: agnhost
        image: registry.k8s.io/e2e-test-images/agnhost:2.66.1
        args: ["netexec", "--http-port=8080"]
        ports:
        - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: catalogue-v1
  namespace: examen-gw
spec:
  selector:
    app: catalogue
    version: v1
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: catalogue-v2
  namespace: examen-gw
spec:
  selector:
    app: catalogue
    version: v2
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: examen-gw
  namespace: examen-gw
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: docs
  namespace: examen-ing
  labels:
    app: docs
spec:
  replicas: 1
  selector:
    matchLabels:
      app: docs
  template:
    metadata:
      labels:
        app: docs
    spec:
      containers:
      - name: nginx
        image: nginx:1.30.6-alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: docs
  namespace: examen-ing
spec:
  selector:
    app: docs
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: bdd
  namespace: examen-net
  labels:
    app: bdd
spec:
  nodeSelector:
    kubernetes.io/hostname: @NOEUD_CP@
  containers:
  - name: bdd
    image: registry.k8s.io/e2e-test-images/agnhost:2.66.1
    args: ["netexec", "--http-port=5432"]
    ports:
    - containerPort: 5432
---
apiVersion: v1
kind: Pod
metadata:
  name: front
  namespace: examen-net
  labels:
    role: front
spec:
  nodeSelector:
    kubernetes.io/hostname: @NOEUD_CP@
  containers:
  - name: front
    image: busybox:1.37.0
    command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: autre
  namespace: examen-net
  labels:
    role: autre
spec:
  nodeSelector:
    kubernetes.io/hostname: @NOEUD_CP@
  containers:
  - name: autre
    image: busybox:1.37.0
    command: ["sleep", "infinity"]
EOF
}

preparer() {
  prerequis_i4
  remise_a_zero

  info "namespaces et objets préexistants"
  local ns
  for ns in $NAMESPACES; do k create namespace "$ns" >/dev/null; done
  # Pods de examen-net sur le control plane : la tâche 14 rend cka-m02 NotReady,
  # et les pods nus d'un nœud NotReady sont supprimés au bout de 300 s.
  objets | sed "s/@NOEUD_CP@/$NOEUD_CP/" | k apply -f - >/dev/null
  k -n default create configmap examen-blanc --from-literal=preparation="$(date -Iseconds)" >/dev/null

  info "taint dedie=donnees:NoSchedule sur le nœud disque=ssd"
  k taint nodes -l disque=ssd dedie=donnees:NoSchedule --overwrite >/dev/null

  info "etcdctl et etcdutl dans le nœud $NOEUD_CP (copiés depuis l'image etcd)"
  ssh_noeud "$NOEUD_CP" 'set -e; cid=$(sudo crictl ps --name etcd -q | head -1);
    sudo install -m 0755 /run/containerd/io.containerd.runtime.v2.task/k8s.io/$cid/rootfs/usr/local/bin/etcdctl \
      /run/containerd/io.containerd.runtime.v2.task/k8s.io/$cid/rootfs/usr/local/bin/etcdutl /usr/local/bin/' >/dev/null
  ssh_noeud "$NOEUD_CP" 'etcdctl version' | head -1

  mkdir -p "$EXAMEN"

  info "attente des charges de travail"
  for d in examen-app/calcul examen-svc/catalogue examen-gw/catalogue-v1 examen-gw/catalogue-v2 examen-ing/docs; do
    deploiement_pret "${d%/*}" "${d#*/}" >/dev/null
  done
  k -n examen-net wait --for=condition=Ready pod --all --timeout=300s >/dev/null
  k -n examen-gw wait --for=condition=Programmed gateway/examen-gw --timeout=300s >/dev/null

  succes "examen prêt. Réponses écrites dans $EXAMEN/. Chronomètre : 2 heures."
  info "tâches 14 et 15 : lance « $0 14 » puis « $0 15 » quand tu y arrives."
  info "correction : lab/examen-blanc/corriger.sh"
}

case "${1:-}" in
  "") preparer ;;
  14) panne_14 ;;
  15) panne_15 ;;
  *) echo "usage : $0 [14|15]" >&2; exit 2 ;;
esac
