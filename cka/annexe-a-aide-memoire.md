---
title: "CKA — Annexe A. Aide-mémoire"
description: "Commandes, squelettes YAML, chemins, ports, jsonpath et procédures éclair du CKA v1.37, rangés par domaine du programme."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## Annexe A. Aide-mémoire

Cette annexe rassemble sur quelques pages ce que le cours développe sur vingt-quatre chapitres. Elle ne remplace pas les explications : chaque rubrique renvoie au chapitre qui donne le mécanisme, les cas limites et les pièges. Elle sert à deux moments. Pendant la préparation, pour retrouver une commande ou un champ sans relire un chapitre entier. La veille de l'examen, pour une dernière lecture de ce qui doit sortir des doigts sans réfléchir.

Tout ce qui suit vaut pour Kubernetes v1.37, kubectl 1.37, Helm 4.3, etcd 3.7 et le lab minikube v1.39.0 du cours (profil `cka`, nœuds `cka`, `cka-m02`, `cka-m03`). Les squelettes YAML reprennent les objets du fil rouge quand ils existent, avec leurs noms et leurs valeurs exactes ; ils ont tous été contrôlés champ par champ contre les schémas OpenAPI de la v1.37. Quand minikube s'écarte d'un cluster kubeadm d'examen, l'encadré `minikube ≠ examen` donne les deux valeurs.

```
Plan de l'annexe :
══════════════════

  A.1  Les premières minutes             A.6  Architecture (25 %)
  A.2  kubectl au quotidien              A.7  Dépannage (30 %)
  A.3  Workloads et ordonnancement (15 %) A.8  Chemins et ports
  A.4  Services et réseau (20 %)         A.9  jsonpath et sorties
  A.5  Stockage (10 %)                   A.10 Procédures éclair
                                         A.11 Pages de doc à ouvrir
```

### A.1 Les premières minutes de l'examen

Chapitres [3](03-kubectl-efficace.md) et [24](24-examen.md). Sur les hôtes de l'examen, `kubectl` porte déjà l'alias `k` et la complétion Bash ; le système `base` n'a rien de tout cela. Chaque tâche commence par un changement de contexte que l'énoncé fournit : le copier tel quel.

```bash
kubectl config use-context <contexte-de-la-tâche>        # à CHAQUE tâche
export do="--dry-run=client -o yaml"                      # kubectl run web --image=… $do > web.yaml
export now="--force --grace-period=0"                     # kubectl delete pod web $now
cat >> ~/.vimrc <<'EOF'
set expandtab tabstop=2 shiftwidth=2
EOF
```

| Geste | Commande |
|---|---|
| Namespace par défaut du contexte courant | `kubectl config set-context --current --namespace=boutique` |
| Contexte courant | `kubectl config current-context` |
| Lister les contextes | `kubectl config get-contexts` |
| Devenir root sur un hôte d'examen | `ssh <nœud>` puis `sudo -i` ; revenir par `exit` (ssh imbriqué non pris en charge) |
| Copier / coller dans le terminal | `Ctrl+Shift+C` / `Ctrl+Shift+V` |

> [!info] minikube ≠ examen
> Dans le lab, on entre dans un nœud par `minikube -p cka ssh -n cka-m02` (utilisateur `docker`, `sudo` sans mot de passe). À l'examen, c'est `ssh <nœud>` puis `sudo -i`. Le lab n'a pas l'alias `k` : le chapitre 3 le pose.

### A.2 kubectl au quotidien

Chapitre [3](03-kubectl-efficace.md).

#### Générer plutôt qu'écrire

| Objet | Commande (ajouter `$do > fichier.yaml` pour obtenir le YAML) |
|---|---|
| Pod | `kubectl run outils --image=nicolaka/netshoot:v0.16 --labels=app=outils,tier=outils --command -- sleep infinity` |
| Pod jetable | `kubectl run test --rm -it --restart=Never --image=busybox:1.37.0 -- sh` |
| Deployment | `kubectl create deployment front --image=nginx:1.29-alpine --replicas=3 --port=80` |
| Service ClusterIP | `kubectl expose deployment api --port=8080 --target-port=http` |
| Service NodePort | `kubectl expose deployment front --name=front-np --type=NodePort --port=80` (puis fixer `nodePort`) |
| Service LoadBalancer | `kubectl expose deployment front --name=front-lb --type=LoadBalancer --port=80` |
| Service ExternalName | `kubectl create service externalname meteo --external-name=example.com` |
| Job | `kubectl create job migration --image=busybox:1.37.0 -- sh -c 'echo ok'` |
| CronJob | `kubectl create cronjob rapport --image=busybox:1.37.0 --schedule='*/5 * * * *' -- sh -c 'date'` |
| ConfigMap | `kubectl create configmap api-config --from-literal=APP_MODE=production --from-file=index.html` |
| Secret | `kubectl create secret generic api-secret --from-literal=DB_PASSWORD=changeme-123` |
| Secret TLS | `kubectl create secret tls boutique-tls --cert=tls.crt --key=tls.key` |
| Ingress | `kubectl create ingress docs --class=nginx --rule='docs.example/*=docs:80'` |
| Role | `kubectl create role lecture-pods --verb=get,list,watch --resource=pods` |
| RoleBinding | `kubectl create rolebinding lecteur-pods --role=lecture-pods --serviceaccount=examen-rbac:lecteur` |
| ClusterRole / binding | `kubectl create clusterrole lecteur-noeuds --verb=get,list,watch --resource=nodes` ; `kubectl create clusterrolebinding lecteur-noeuds-alice --clusterrole=lecteur-noeuds --user=alice` |
| ServiceAccount, jeton | `kubectl create serviceaccount deployeur` ; `kubectl create token deployeur --duration=1h` |
| HPA | `kubectl autoscale deployment api --min=2 --max=6 --cpu=50%` |
| PriorityClass | `kubectl create priorityclass boutique-critique --value=100000` |
| ResourceQuota | `kubectl create quota boutique-quota --hard=pods=30,requests.cpu=4,requests.memory=4Gi` |
| PDB | `kubectl create poddisruptionbudget front --selector=app=front --min-available=2` |

> [!warning] Trois générateurs trompeurs
> `kubectl create service nodeport catalogue-np --tcp=8080:8080` pose le sélecteur `app=catalogue-np`, pas celui du Deployment : préfère `kubectl expose`. `kubectl autoscale --cpu-percent=60` est déprécié en 1.37 (avertissement) : écris `--cpu=60%`. `kubectl run -f` est déprécié en 1.37 et l'option était déjà ignorée.

#### Lire, chercher, modifier

```bash
kubectl explain deployment.spec.strategy.rollingUpdate          # champ par champ
kubectl explain pod.spec --recursive | less                      # arbre complet
kubectl api-resources --namespaced=true -o wide                  # noms courts, verbes, groupes
kubectl api-resources --api-group=gateway.networking.k8s.io
kubectl get pods -A -o wide --show-labels
kubectl get pods -l 'tier in (web,api)' --field-selector=status.phase!=Running
kubectl label node cka-m03 disque=ssd                            # disque- pour retirer
kubectl annotate deployment front kubernetes.io/change-cause="image nginx:1.30.6-alpine"
kubectl set image deployment/front nginx=nginx:1.30.6-alpine
kubectl set resources deployment/api -c agnhost --requests=cpu=50m,memory=32Mi
kubectl scale deployment/api --replicas=3
kubectl patch deployment api -p '{"spec":{"replicas":3}}'                  # fusion stratégique
kubectl patch pv archives --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]'
kubectl edit deployment front                                     # refusé ? copie dans /tmp/kubectl-edit-*.yaml
kubectl replace --force -f pod.yaml                               # recrée (champs immuables d'un pod)
kubectl diff -f front.yaml                                        # avant un apply
kubectl apply --server-side -f gros-manifeste.yaml                # gros CRD, conflits de gestionnaires
kubectl wait --for=condition=Ready pod -l app=api --timeout=120s
kubectl wait --for=delete pod/test --timeout=60s
kubectl exec -it outils -- sh                                     # le « -- » est obligatoire depuis 1.35
```

> [!tip] Réflexe d'examen
> Un champ de pod refusé par `kubectl edit` (image mise à part, presque tout est immuable dans un pod) : kubectl enregistre ta version dans `/tmp/kubectl-edit-<nombres>.yaml`. `kubectl replace --force -f` ce fichier, et la tâche est faite.

### A.3 Workloads et ordonnancement (15 %)

#### A.3.1 Pod : ressources, sondes, sidecar natif

Chapitre [4](04-pods.md). Valeurs par défaut d'une sonde : `initialDelaySeconds: 0`, `periodSeconds: 10`, `timeoutSeconds: 1`, `successThreshold: 1` (obligatoirement 1 pour liveness et startup), `failureThreshold: 3`. Tant que la startupProbe n'a pas réussi, liveness et readiness ne tournent pas.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web-sondes
  namespace: boutique
  labels:
    app: web-sondes
    tier: web
spec:
  terminationGracePeriodSeconds: 30         # défaut 30
  containers:
  - name: nginx
    image: nginx:1.30.6-alpine
    ports:
    - name: http
      containerPort: 80
    resources:
      requests:
        cpu: 50m
        memory: 32Mi
      limits:
        cpu: 200m
        memory: 64Mi
    startupProbe:                            # 30 × 2 s pour démarrer
      httpGet:
        path: /
        port: http
      failureThreshold: 30
      periodSeconds: 2
    readinessProbe:                          # échec : retiré des EndpointSlices
      httpGet:
        path: /
        port: http
      periodSeconds: 5
    livenessProbe:                           # échec : conteneur redémarré
      tcpSocket:
        port: http
      periodSeconds: 10
    lifecycle:
      preStop:
        exec:
          command: ["sh", "-c", "sleep 5"]
```

Le sidecar natif est un init container avec `restartPolicy: Always` : il démarre avant les conteneurs principaux, tourne pendant toute la vie du pod et s'arrête après eux. GA depuis 1.33.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: journal-demo
  namespace: boutique
spec:
  initContainers:
  - name: suiveur
    image: busybox:1.37.0
    restartPolicy: Always                    # c'est ce champ qui en fait un sidecar
    command: ["sh", "-c", "tail -F /var/log/app/app.log"]
    volumeMounts:
    - name: journaux
      mountPath: /var/log/app
  containers:
  - name: app
    image: busybox:1.37.0
    command: ["sh", "-c", "while true; do date >> /var/log/app/app.log; sleep 5; done"]
    volumeMounts:
    - name: journaux
      mountPath: /var/log/app
  volumes:
  - name: journaux
    emptyDir: {}
```

| Classe QoS | Condition | Ordre d'éviction sous pression |
|---|---|---|
| Guaranteed | chaque conteneur a requests = limits, en CPU **et** en mémoire | en dernier |
| Burstable | au moins une request ou une limit, sans être Guaranteed | ensuite |
| BestEffort | aucune request ni limit | en premier |

Redimensionnement en place (GA en 1.35, CPU et mémoire seulement, la classe QoS ne peut pas changer) :

```bash
kubectl -n boutique patch pod outils --subresource resize --patch \
  '{"spec":{"containers":[{"name":"outils","resources":{"requests":{"cpu":"100m"},"limits":{"cpu":"300m"}}}]}}'
kubectl -n boutique get pod outils -o jsonpath='{.status.containerStatuses[0].resources}{"\n"}'
```

#### A.3.2 Deployment, mises à jour et retours arrière

Chapitre [5](05-deployments-et-controleurs.md). Défauts : `maxSurge: 25%`, `maxUnavailable: 25%`, `revisionHistoryLimit: 10`, `progressDeadlineSeconds: 600`, `minReadySeconds: 0`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: boutique
  labels:
    app: api
    tier: api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
        tier: api
    spec:
      containers:
      - name: agnhost
        image: registry.k8s.io/e2e-test-images/agnhost:2.66.1
        args: ["netexec", "--http-port=8080"]
        ports:
        - name: http
          containerPort: 8080
        readinessProbe:
          httpGet:
            path: /hostname
            port: http
        resources:
          requests:
            cpu: 50m
            memory: 32Mi
          limits:
            cpu: 500m
            memory: 128Mi
```

Le Deployment `front` ajoute une stratégie explicite :

```yaml
spec:
  strategy:
    type: RollingUpdate                      # ou Recreate (tout tuer, puis tout créer)
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
```

```bash
kubectl set image deployment/front nginx=nginx:1.30.6-alpine
kubectl annotate deployment/front kubernetes.io/change-cause="image nginx:1.30.6-alpine"
kubectl rollout status deployment/front --timeout=120s
kubectl rollout history deployment/front                       # colonne CHANGE-CAUSE
kubectl rollout history deployment/front --revision=2          # le gabarit de la révision 2
kubectl rollout undo deployment/front                          # révision précédente
kubectl rollout undo deployment/front --to-revision=1          # la révision 1 devient la plus récente
kubectl rollout pause deployment/front ; kubectl rollout resume deployment/front
kubectl rollout restart deployment/front                       # recrée les pods (annotation restartedAt)
```

#### A.3.3 DaemonSet, StatefulSet, Job, CronJob, PodDisruptionBudget

Chapitres [5](05-deployments-et-controleurs.md) et [15](15-stockage.md).

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: agent-noeud
  namespace: boutique
  labels:
    app: agent-noeud
    tier: outils
spec:
  selector:
    matchLabels:
      app: agent-noeud
  template:
    metadata:
      labels:
        app: agent-noeud
        tier: outils
    spec:
      tolerations:
      - operator: Exists                     # ajoutée au chapitre 8 : tourne même sur un nœud tainté
      containers:
      - name: agent
        image: busybox:1.37.0
        command: ["sh", "-c", "while true; do echo \"$(date) $NODE_NAME\"; sleep 60; done"]
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
          limits:
            cpu: 50m
            memory: 32Mi
```

Un StatefulSet donne à chaque pod un nom stable (`redis-0`), une entrée DNS stable par le Service headless nommé dans `serviceName`, et une PVC par pod tirée de `volumeClaimTemplates` (nommée `<modèle>-<pod>`, ici `data-redis-0`).

```yaml
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: boutique
spec:
  clusterIP: None
  selector:
    app: redis
  ports:
  - name: redis
    port: 6379
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis
  namespace: boutique
  labels:
    app: redis
    tier: donnees
spec:
  replicas: 1
  serviceName: redis
  selector:
    matchLabels:
      app: redis
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain
    whenScaled: Retain
  template:
    metadata:
      labels:
        app: redis
        tier: donnees
    spec:
      nodeSelector:
        disque: ssd
      containers:
      - name: redis
        image: redis:8.10.2-alpine
        args: ["--appendonly", "yes"]
        ports:
        - name: redis
          containerPort: 6379
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 256Mi
        volumeMounts:
        - name: data
          mountPath: /data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      storageClassName: rapide
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi
```

Un Job relance ses pods jusqu'à `completions` succès (`backoffLimit` par défaut : 6) ; son gabarit n'accepte que `restartPolicy: Never` ou `OnFailure`.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: migration
  namespace: boutique
spec:
  completions: 3
  parallelism: 2
  backoffLimit: 4
  ttlSecondsAfterFinished: 600               # Job et pods supprimés 10 min après la fin
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: migration
        image: busybox:1.37.0
        command: ["sh", "-c", "echo migration $HOSTNAME; sleep 5"]
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: rapport
  namespace: boutique
  labels:
    app: rapport
    tier: batch
spec:
  schedule: "*/5 * * * *"
  timeZone: Europe/Paris                     # TZ= ou CRON_TZ= dans schedule : refusés
  concurrencyPolicy: Forbid                  # Allow (défaut), Forbid, Replace
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    metadata:
      labels:
        app: rapport
        tier: batch
    spec:
      template:
        metadata:
          labels:
            app: rapport
            tier: batch
        spec:
          restartPolicy: OnFailure
          containers:
          - name: rapport
            image: busybox:1.37.0
            command: ["sh", "-c", "date; echo rapport genere"]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: front
  namespace: boutique
spec:
  minAvailable: 2                            # ou maxUnavailable, jamais les deux
  selector:
    matchLabels:
      app: front
```

```bash
kubectl create job manuel --from=cronjob/rapport              # déclencher un CronJob à la main
kubectl get jobs,pods -l app=rapport
```

#### A.3.4 ConfigMaps et Secrets

Chapitre [6](06-configmaps-et-secrets.md). Une variable d'environnement ne change jamais dans un conteneur qui tourne ; un volume ConfigMap ou Secret se met à jour (délai de synchronisation du kubelet), **sauf** monté par `subPath`. Un Secret est encodé en base64, pas chiffré.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: config-demo
  namespace: boutique
spec:
  containers:
  - name: app
    image: busybox:1.37.0
    command: ["sh", "-c", "env; ls /etc/secret; sleep 3600"]
    envFrom:
    - configMapRef:
        name: api-config                     # toutes les clés deviennent des variables
    env:
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: api-secret
          key: DB_PASSWORD
    - name: MODE
      valueFrom:
        configMapKeyRef:
          name: api-config
          key: APP_MODE
    - name: POD_IP                           # downward API
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
    volumeMounts:
    - name: secret
      mountPath: /etc/secret
      readOnly: true
    - name: html
      mountPath: /usr/share/nginx/html
  volumes:
  - name: secret
    secret:
      secretName: api-secret
  - name: html
    configMap:
      name: front-html
      items:                                 # facultatif : ne monter que certaines clés
      - key: index.html
        path: index.html
```

```bash
kubectl -n boutique get secret api-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d; echo
kubectl create secret docker-registry regcred --docker-server=registry.example \
  --docker-username=u --docker-password=p        # puis spec.imagePullSecrets: [{name: regcred}]
```

#### A.3.5 Ressources et autoscaling

Chapitre [7](07-autoscaling.md). Réplicas voulus = `ceil(réplicas actuels × valeur mesurée / cible)` ; aucune action si l'écart reste dans la tolérance (10 % par défaut, réglable par règle depuis la GA de 1.37). Stabilisation de descente par défaut : 300 s ; de montée : 0 s. Le HPA en `Utilization` exige des `requests` CPU sur les conteneurs ciblés et un metrics-server qui répond.

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api
  namespace: boutique
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  minReplicas: 2
  maxReplicas: 6
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 60
```

```bash
minikube -p cka addons enable metrics-server        # kubectl top répond ≈ 60 s plus tard
kubectl top nodes
kubectl top pods -n boutique --containers --sort-by=cpu
kubectl get hpa api -n boutique -w                  # TARGETS : cpu: 12%/50%
kubectl describe hpa api -n boutique                # conditions AbleToScale, ScalingActive, ScalingLimited
```

#### A.3.6 Ordonnancement et admission

Chapitre [8](08-ordonnancement-et-admission.md).

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: placement-demo
  namespace: boutique
  labels:
    app: placement-demo
spec:
  priorityClassName: boutique-critique
  nodeSelector:
    kubernetes.io/os: linux
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:                   # termes en OU ; expressions d'un terme en ET
        - matchExpressions:
          - key: disque
            operator: In                     # In, NotIn, Exists, DoesNotExist, Gt, Lt
            values: ["ssd"]
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 50
        preference:
          matchExpressions:
          - key: topology.kubernetes.io/zone
            operator: In
            values: ["zone-b"]
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              app: placement-demo
  tolerations:
  - key: dedie
    operator: Equal
    value: donnees
    effect: NoSchedule
  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway         # ou DoNotSchedule (défaut)
    labelSelector:
      matchLabels:
        app: placement-demo
  containers:
  - name: nginx
    image: nginx:1.30.6-alpine
```

```bash
kubectl taint node cka-m03 dedie=donnees:NoSchedule          # NoSchedule, PreferNoSchedule, NoExecute
kubectl taint node cka-m03 dedie=donnees:NoSchedule-         # retirer (le « - » final)
kubectl describe node cka-m03 | grep -A3 Taints
kubectl label namespace boutique pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/audit=restricted
```

| Taint posée par le système | Effet | Quand |
|---|---|---|
| `node.kubernetes.io/not-ready` | NoSchedule et NoExecute | condition Ready à False |
| `node.kubernetes.io/unreachable` | NoSchedule et NoExecute | condition Ready à Unknown (kubelet muet ≈ 50 s) |
| `node.kubernetes.io/unschedulable` | NoSchedule | `kubectl cordon` |
| `node.kubernetes.io/memory-pressure`, `disk-pressure`, `pid-pressure` | NoSchedule | pressions du kubelet |
| `node-role.kubernetes.io/control-plane` | NoSchedule | posée par kubeadm sur les control planes |

Le contrôleur d'admission `DefaultTolerationSeconds` ajoute à chaque pod une tolérance de 300 s à `not-ready` et `unreachable` : un pod survit cinq minutes sur un nœud perdu avant d'être évincé.

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: boutique-critique
value: 100000
globalDefault: false
preemptionPolicy: PreemptLowerPriority       # ou Never
description: "Pods critiques de la boutique"
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: boutique-quota
  namespace: boutique
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 4Gi
    limits.cpu: "8"
    limits.memory: 8Gi
    pods: "30"
    services: "12"
    persistentvolumeclaims: "6"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: boutique-limites
  namespace: boutique
spec:
  limits:
  - type: Container
    default:                                 # limits injectées si absentes
      cpu: 200m
      memory: 128Mi
    defaultRequest:                          # requests injectées si absentes
      cpu: 50m
      memory: 64Mi
    max:
      cpu: "1"
      memory: 1Gi
```

> [!warning] Quota et contrôleurs
> Un pod refusé par un ResourceQuota ne produit **aucun** pod en erreur : le ReplicaSet porte un événement `FailedCreate` (`exceeded quota`). Regarde `kubectl describe rs` ou `kubectl events`, pas `kubectl get pods`.

### A.4 Services et réseau (20 %)

#### A.4.1 Services

Chapitre [10](10-services.md). Plage NodePort : 30000-32767. Le ClusterIP n'existe que dans les règles de kube-proxy (mode `iptables` par défaut, `nftables` GA, `ipvs` déprécié depuis 1.35) : il ne répond pas au ping.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: boutique
spec:
  type: ClusterIP                            # défaut
  selector:
    app: api
  ports:
  - name: http                               # nom requis pour l'enregistrement SRV _http._tcp
    port: 8080
    targetPort: http                         # port nommé du conteneur
---
apiVersion: v1
kind: Service
metadata:
  name: front
  namespace: boutique
spec:
  type: NodePort
  selector:
    app: front
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30080
---
apiVersion: v1
kind: Service
metadata:
  name: front-lb
  namespace: boutique
spec:
  type: LoadBalancer                         # adresse fournie par MetalLB dans le lab
  externalTrafficPolicy: Cluster             # Local : garde l'IP client, nœuds sans pod exclus
  selector:
    app: front
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: api-pods
  namespace: boutique
spec:
  clusterIP: None                            # headless : le DNS rend les IP des pods
  selector:
    app: api
  ports:
  - name: http
    port: 8080
    targetPort: http
---
apiVersion: v1
kind: Service
metadata:
  name: meteo
  namespace: boutique
spec:
  type: ExternalName                         # simple CNAME, aucun proxy
  externalName: example.com
```

```bash
kubectl -n boutique get endpointslices -l kubernetes.io/service-name=api
kubectl -n boutique describe svc api                 # Endpoints vide ? sélecteur ou readiness
kubectl -n boutique port-forward svc/front 8080:80   # test depuis le poste
kubectl -n boutique exec outils -- curl -s http://api:8080/hostname
```

> [!info] minikube ≠ examen
> Le lab sert les Services LoadBalancer par l'addon `metallb` v0.9.6, configuré par la ConfigMap `metallb-system/config` (plage 192.168.49.100-192.168.49.120), sans les CRD `IPAddressPool` des versions récentes. Sur un cluster kubeadm sans fournisseur, un Service LoadBalancer reste en `<pending>` : il fonctionne alors comme un NodePort.

#### A.4.2 DNS

Chapitre [11](11-coredns.md). Service DNS : `kube-dns` en 10.96.0.10, domaine `cluster.local`.

| Nom | Résout vers |
|---|---|
| `api.boutique.svc.cluster.local` | ClusterIP du Service |
| `api-pods.boutique.svc.cluster.local` | IP de chaque pod prêt (headless) |
| `redis-0.redis.boutique.svc.cluster.local` | pod `redis-0` du StatefulSet (`<hostname>.<subdomain>`) |
| `_http._tcp.api.boutique.svc.cluster.local` | SRV : port nommé `http`, protocole TCP |
| `10-244-142-70.boutique.pod.cluster.local` | enregistrement A d'un pod par son IP |
| `meteo.boutique.svc.cluster.local` | CNAME vers `example.com` |

```
/etc/resolv.conf d'un pod du namespace boutique (dnsPolicy: ClusterFirst) :
search boutique.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

```bash
kubectl -n boutique exec outils -- dig +search +short api
kubectl -n boutique exec outils -- dig +short SRV _http._tcp.api.boutique.svc.cluster.local
kubectl -n kube-system get configmap coredns -o yaml            # Corefile
kubectl -n kube-system edit configmap coredns                   # plugin reload : relu sans redémarrage
kubectl -n kube-system rollout restart deployment coredns       # si l'on ne veut pas attendre
kubectl -n kube-system logs -l k8s-app=kube-dns
```

`dnsPolicy` : `ClusterFirst` (défaut), `ClusterFirstWithHostNet` (pod en `hostNetwork`), `Default` (hérite du nœud, malgré son nom), `None` (tout vient de `dnsConfig`).

#### A.4.3 Ingress

Chapitre [12](12-ingress.md). `pathType` : `Prefix` (par segments de chemin), `Exact`, `ImplementationSpecific`. Sans `ingressClassName`, la classe annotée `ingressclass.kubernetes.io/is-default-class: "true"` s'applique.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: boutique
  namespace: boutique
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - boutique.example
    - api.boutique.example
    secretName: boutique-tls
  rules:
  - host: boutique.example
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: front
            port:
              number: 80
  - host: api.boutique.example
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: api
            port:
              number: 8080
```

```bash
kubectl create ingress boutique -n boutique --class=nginx \
  --rule='boutique.example/*=front:80,tls=boutique-tls' \
  --rule='api.boutique.example/*=api:8080,tls=boutique-tls'          # « /* » donne Prefix « / »
IP=$(minikube -p cka ip)
curl -sk --resolve boutique.example:443:$IP https://boutique.example/
curl -s -H 'Host: api.boutique.example' http://$IP/hostname
```

> [!info] minikube ≠ examen
> L'addon `ingress` du lab installe ingress-nginx v1.15.1 (projet retiré le 24 mars 2026, l'API Ingress reste GA) dans le namespace `ingress-nginx`, IngressClass `nginx` par défaut, contrôleur épinglé sur `cka` en `hostPort` 80 et 443. À l'examen, le contrôleur et sa classe sont ceux que l'énoncé désigne : lis `kubectl get ingressclass`.

#### A.4.4 Gateway API

Chapitre [13](13-gateway-api.md). Rôles : le fournisseur livre la GatewayClass, l'opérateur du cluster le Gateway, l'équipe applicative les routes. `allowedRoutes.namespaces.from` vaut `Same` par défaut. Poids d'un `backendRef` : 1 par défaut ; la part d'un backend est son poids divisé par la somme.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: boutique-gw
  namespace: boutique
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: gw.boutique.example
    allowedRoutes:
      namespaces:
        from: Same
  - name: https
    protocol: HTTPS
    port: 443
    hostname: gw.boutique.example
    tls:
      mode: Terminate                        # défaut
      certificateRefs:
      - kind: Secret
        name: boutique-tls                   # boutique-gw-tls après le chapitre 18
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: front
  namespace: boutique
spec:
  parentRefs:
  - name: boutique-gw
    sectionName: https                       # nom du listener visé
  hostnames:
  - gw.boutique.example
  rules:
  - matches:                                 # règle la plus spécifique : en-tête
    - headers:
      - name: X-Version
        value: v2
    backendRefs:
    - name: front-v2
      port: 80
  - matches:
    - path:
        type: PathPrefix                     # Exact, PathPrefix (défaut), RegularExpression
        value: /
    backendRefs:
    - name: front
      port: 80
      weight: 90
    - name: front-v2
      port: 80
      weight: 10
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: redirection-https                    # nom libre
  namespace: boutique
spec:
  parentRefs:
  - name: boutique-gw
    sectionName: http
  hostnames:
  - gw.boutique.example
  rules:
  - filters:
    - type: RequestRedirect
      requestRedirect:
        scheme: https
        statusCode: 301
```

Réécriture de préfixe (route `api` du fil rouge) :

```yaml
rules:
- matches:
  - path:
      type: PathPrefix
      value: /api
  filters:
  - type: URLRewrite
    urlRewrite:
      path:
        type: ReplacePrefixMatch
        replacePrefixMatch: /
  backendRefs:
  - name: api
    port: 8080
```

ReferenceGrant, posé dans le namespace **cible**, pour qu'une route de `vitrine` vise un Service de `boutique` :

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1  # version stockée ; v1 aussi servie depuis Gateway API v1.5
kind: ReferenceGrant
metadata:
  name: vitrine-vers-boutique
  namespace: boutique
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: vitrine
  to:
  - group: ""
    kind: Service
```

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.2 \
  -n envoy-gateway-system --create-namespace
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
kubectl -n boutique wait --for=condition=Programmed gateway/boutique-gw --timeout=180s
GW=$(kubectl -n boutique get gateway boutique-gw -o jsonpath='{.status.addresses[0].value}')
curl -sk --resolve gw.boutique.example:443:$GW https://gw.boutique.example/ -H 'X-Version: v2'
kubectl -n boutique get httproute front -o jsonpath='{.status.parents[0].conditions}'   # Accepted, ResolvedRefs
```

#### A.4.5 NetworkPolicies

Chapitre [14](14-network-policies.md). Un pod n'est isolé dans une direction que si une politique le sélectionne pour cette direction ; les règles s'additionnent (union), jamais ne se retranchent. Dans `from`/`to`, deux éléments de liste sont en OU ; `podSelector` et `namespaceSelector` dans le **même** élément sont en ET.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: refus-par-defaut
  namespace: boutique
spec:
  podSelector: {}                            # tous les pods du namespace
  policyTypes: ["Ingress", "Egress"]         # aucune règle : tout est refusé
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: autorise-dns
  namespace: boutique
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
  - to:
    - namespaceSelector:                     # même élément : ET
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-entree
  namespace: boutique
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes: ["Ingress"]
  ingress:
  - from:                                    # quatre éléments : OU
    - podSelector:
        matchLabels:
          tier: web
    - podSelector:
        matchLabels:
          app: outils
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: envoy-gateway-system
    ports:
    - protocol: TCP
      port: 8080
```

```bash
kubectl -n boutique exec outils -- curl -s -m 3 http://api:8080/hostname   # refus = délai dépassé, pas « refused »
kubectl -n boutique describe networkpolicy api-entree
```

### A.5 Stockage (10 %)

Chapitre [15](15-stockage.md).

| Mode d'accès | Abréviation | Sens exact |
|---|---|---|
| ReadWriteOnce | RWO | lecture-écriture par **un nœud** (plusieurs pods de ce nœud possibles) |
| ReadOnlyMany | ROX | lecture seule par plusieurs nœuds |
| ReadWriteMany | RWX | lecture-écriture par plusieurs nœuds |
| ReadWriteOncePod | RWOP | lecture-écriture par **un seul pod** (GA 1.29) |

| Politique | Effet à la suppression de la PVC |
|---|---|
| `Retain` | PV conservé en `Released`, données intactes ; remise à disposition manuelle (retirer `claimRef`). Défaut d'un PV créé à la main |
| `Delete` | PV et volume supprimés. Défaut d'une StorageClass |
| `Recycle` | dépréciée (avertissement de l'API), `nfs` et `hostPath` seulement |

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: manuel
provisioner: kubernetes.io/no-provisioner      # aucun provisionnement dynamique
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: rapide
  # annotations: {storageclass.kubernetes.io/is-default-class: "true"}   # classe par défaut
provisioner: hostpath.csi.k8s.io
reclaimPolicy: Delete                          # défaut
volumeBindingMode: WaitForFirstConsumer        # défaut : Immediate
allowVolumeExpansion: true
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: archives
spec:
  capacity:
    storage: 1Gi
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manuel
  local:
    path: /mnt/archives                        # doit exister sur le nœud
  nodeAffinity:                                # obligatoire pour un volume local
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values: ["cka-m02"]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: archives
  namespace: boutique
spec:
  storageClassName: manuel                     # "" : aucune classe, pas la classe par défaut
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 500Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: archiveur
  namespace: boutique
spec:
  containers:
  - name: archiveur
    image: busybox:1.37.0
    command: ["sh", "-c", "date >> /archives/journal.txt; sleep 3600"]
    volumeMounts:
    - name: archives
      mountPath: /archives
  volumes:
  - name: archives
    persistentVolumeClaim:
      claimName: archives
---
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: redis-instantane
  namespace: boutique
spec:
  volumeSnapshotClassName: csi-hostpath-snapclass
  source:
    persistentVolumeClaimName: data-redis-0
```

```bash
kubectl get pv,pvc -A
kubectl -n boutique describe pvc archives                      # WaitForFirstConsumer : Pending jusqu'au pod
kubectl patch pv archives --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]'   # Released → Available
kubectl -n boutique patch pvc data-redis-0 -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
kubectl get storageclass                                       # (default) à côté de la classe par défaut
```

> [!info] minikube ≠ examen
> La classe par défaut du lab est `standard` (`k8s.io/minikube-hostpath`, Immediate, sans expansion ni affinité de nœud). Le pilote CSI `hostpath.csi.k8s.io` vient des addons `volumesnapshots` et `csi-hostpath-driver` ; sa classe `csi-hostpath-sc` est en `Immediate`, d'où la classe `rapide` en `WaitForFirstConsumer` du cours. À l'examen, lis `kubectl get sc` avant d'écrire une PVC.

### A.6 Architecture, installation et configuration (25 %)

#### A.6.1 RBAC, ServiceAccounts et certificats

Chapitre [16](16-rbac-et-authentification.md). Un Role et son RoleBinding vivent dans un namespace ; un ClusterRole peut être lié par un RoleBinding (droits limités au namespace du binding) ou par un ClusterRoleBinding (tout le cluster). Les ressources namespacées d'un groupe autre que le cœur portent leur groupe (`apps` pour `deployments`) ; le cœur s'écrit `""`.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: developpeur
  namespace: boutique
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["pods/log"]                    # sous-ressource : règle distincte
  verbs: ["get"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: developpeurs
  namespace: boutique
roleRef:                                     # immuable : supprimer et recréer pour changer
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: developpeur
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: developpeurs
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: lecteur-noeuds
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: lecteur-noeuds-alice
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: lecteur-noeuds
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: alice
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: deployeur
  namespace: boutique
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: deployeur
  namespace: boutique
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: deployeur
subjects:
- kind: ServiceAccount                       # pas d'apiGroup, namespace obligatoire
  name: deployeur
  namespace: boutique
---
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: alice
spec:
  request: LS0tLS1CRUdJTi4uLg==              # remplacer par : base64 -w0 alice.csr
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 604800                  # 7 jours (minimum accepté : 600)
  usages: ["client auth"]
```

```bash
kubectl auth can-i list pods -n boutique --as=alice --as-group=developpeurs   # sans --as-group : no
kubectl auth can-i --list -n boutique --as=system:serviceaccount:boutique:deployeur
kubectl auth can-i patch deployments/scale -n boutique --as=system:serviceaccount:boutique:deployeur
kubectl auth whoami                                                     # utilisateur et groupes vus par l'API
kubectl get clusterrole view -o yaml | grep -A3 aggregationRule
```

| Identité | Forme |
|---|---|
| ServiceAccount | utilisateur `system:serviceaccount:<ns>:<nom>`, groupes `system:serviceaccounts` et `system:serviceaccounts:<ns>` |
| Utilisateur X.509 | `CN` = utilisateur, chaque `O` = un groupe |
| Tout utilisateur authentifié | groupe `system:authenticated` |
| Rôles par défaut | `cluster-admin`, `admin`, `edit`, `view` (agrégés par `rbac.authorization.k8s.io/aggregate-to-<rôle>: "true"`) |

#### A.6.2 Helm et Kustomize

Chapitre [17](17-helm-et-kustomize.md). Helm 4 : `--atomic` devient `--rollback-on-failure`, `--force` devient `--force-replace` (les anciens noms restent, dépréciés) ; une nouvelle installation se fait en server-side apply ; `--wait` seul attend selon la stratégie `watcher`.

```bash
helm repo add podinfo https://stefanprodan.github.io/podinfo && helm repo update
helm search repo podinfo/podinfo --versions | head -3
helm show values podinfo/podinfo --version 6.15.0 | grep -n replicaCount
helm install vitrine podinfo/podinfo --version 6.15.0 -n demo --create-namespace --set replicaCount=2
helm upgrade vitrine podinfo/podinfo --version 6.15.0 -n demo --reuse-values --set ui.message=Bonjour
helm history vitrine -n demo
helm rollback vitrine 1 -n demo                     # crée une NOUVELLE révision
helm get values vitrine -n demo                     # valeurs fournies ; --all pour toutes
helm template vitrine podinfo/podinfo --version 6.15.0 --set replicaCount=2 > rendu.yaml
helm install vitrine oci://ghcr.io/stefanprodan/charts/podinfo --version 6.15.0 -n demo   # variante OCI
helm list -A
helm uninstall vitrine -n demo
```

> [!danger] `helm upgrade` sans `--reuse-values`
> Dès qu'un `--set` ou un `-f` accompagne `helm upgrade`, Helm repart des valeurs par défaut du chart plus les nouvelles valeurs : le `replicaCount=2` de l'installation disparaît. Sans aucune valeur nouvelle, Helm reprend celles de la release. `--reuse-values` garde les anciennes valeurs et y fusionne les nouvelles.

L'overlay ci-dessous est celui du chapitre 17 (exercice 17.8).

```yaml
# ~/cka/kustomize/overlays/recette/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: boutique-recette
resources:
- namespace.yaml
- ../../base
labels:
- pairs:
    env: recette
  includeTemplates: true                     # aussi sur les pods, pas dans les sélecteurs (commonLabels est déprécié)
replicas:
- name: front
  count: 1
configMapGenerator:
- name: front-html
  behavior: replace                          # remplace la ConfigMap générée par la base
  files:
  - index.html                               # copié dans l'overlay : pas de ../
```

Deux autres transformations courantes, hors fil rouge, à ajouter au même fichier :

```yaml
images:
- name: nginx
  newTag: 1.30.6-alpine
patches:
- target:
    kind: Deployment
    name: front
  patch: |-
    - op: add
      path: /metadata/annotations/recette
      value: "oui"
```

```bash
kubectl kustomize ~/cka/kustomize/overlays/recette | less     # rendu sans appliquer
kubectl apply -k ~/cka/kustomize/overlays/recette
kubectl delete -k ~/cka/kustomize/overlays/recette
```

Un `configMapGenerator` suffixe le nom par un hachage du contenu (`front-html-<hachage>`) et réécrit les références : changer la page déclenche un déploiement.

#### A.6.3 CRI, CRD et opérateurs

Chapitre [18](18-interfaces-crd-et-operateurs.md).

| Interface | Rôle | Où regarder |
|---|---|---|
| CRI | kubelet → runtime (containerd 2.x) | `crictl` sur le nœud, `/run/containerd/containerd.sock`, RuntimeClass |
| CNI | runtime → plugin réseau à la création du sandbox | `/etc/cni/net.d/`, `/opt/cni/bin/` |
| CSI | stockage externe par un pilote en pods | `kubectl get csidrivers,csinodes,volumeattachments` |

```bash
sudo crictl ps -a                 # conteneurs, y compris arrêtés
sudo crictl pods                  # sandboxes
sudo crictl logs <id>             # journal d'un conteneur, même si l'API est tombée
sudo crictl inspect <id> | less
sudo crictl images
```

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: runc-standard
handler: runc                                # nom du runtime dans la config de containerd
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: sauvegardes.boutique.example         # <pluriel>.<groupe>, obligatoirement
spec:
  group: boutique.example
  scope: Namespaced
  names:
    plural: sauvegardes
    singular: sauvegarde
    kind: Sauvegarde
    shortNames: ["svg"]
  versions:
  - name: v1
    served: true
    storage: true                            # une seule version de stockage
    subresources:
      status: {}
    additionalPrinterColumns:
    - name: Cible
      type: string
      jsonPath: .spec.cible
    - name: Planification
      type: string
      jsonPath: .spec.planification
    - name: Retention
      type: integer
      jsonPath: .spec.retention
    - name: Age
      type: date
      jsonPath: .metadata.creationTimestamp
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            required: ["cible"]
            properties:
              cible:
                type: string
              planification:
                type: string
              retention:
                type: integer
                minimum: 1
                maximum: 30
          status:
            type: object
            properties:
              derniereExecution:
                type: string
                format: date-time
---
apiVersion: boutique.example/v1
kind: Sauvegarde
metadata:
  name: redis-quotidienne
  namespace: boutique
spec:
  cible: redis
  planification: "0 2 * * *"
  retention: 7
```

```bash
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.21.2 \
  --namespace cert-manager --create-namespace --set crds.enabled=true
kubectl get crd -o jsonpath='{range .items[?(@.spec.group=="cert-manager.io")]}{.metadata.name}{"\n"}{end}'
kubectl -n boutique get certificate,certificaterequest,secret
```

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: autosigne
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: boutique-gw
  namespace: boutique
spec:
  secretName: boutique-gw-tls
  dnsNames:
  - gw.boutique.example
  issuerRef:
    name: autosigne
    kind: ClusterIssuer                      # Issuer par défaut
    group: cert-manager.io
```

#### A.6.4 kubeadm

Chapitre [19](19-kubeadm-installation-ha-et-mises-a-jour.md) (lab de VM `cp1` à `cp3`, `w1`, `w2`). Préalables d'un nœud : swap coupé ou toléré (`failSwapOn: false`), `net.ipv4.ip_forward = 1`, cgroup v2 (le kubelet 1.35+ refuse cgroup v1 par défaut), containerd 2.x avec `SystemdCgroup = true`, paquets `kubeadm`, `kubelet`, `kubectl` du dépôt `pkgs.k8s.io/core:/stable:/v1.37/deb/` bloqués par `apt-mark hold`.

```bash
sudo kubeadm init --control-plane-endpoint k8s-api.example:6443 \
  --apiserver-advertise-address 192.168.10.11 --pod-network-cidr 10.244.0.0/16 --upload-certs
kubeadm token create --print-join-command                      # jeton valable 24 h
sudo kubeadm init phase upload-certs --upload-certs            # nouvelle clé de certificats (2 h)
sudo kubeadm join k8s-api.example:6443 --token <t> --discovery-token-ca-cert-hash sha256:<h> \
  --control-plane --certificate-key <clé>                      # second control plane
sudo kubeadm certs check-expiration
sudo kubeadm certs renew all                                   # puis redémarrer les pods statiques
sudo kubeadm reset                                             # nettoie le nœud (pas le CNI ni iptables)
```

| Composant | Décalage permis par rapport au kube-apiserver le plus récent |
|---|---|
| kube-apiserver (HA) | une version mineure entre instances |
| kube-controller-manager, kube-scheduler | jusqu'à une mineure de moins |
| kubelet, kube-proxy | jusqu'à trois mineures de moins, jamais plus récents |
| kubectl | une mineure de plus ou de moins |

La procédure de mise à jour pas à pas est en A.10.2. Une mineure à la fois, control planes d'abord, nœud drainé avant de toucher au kubelet.

#### A.6.5 etcd

Chapitre [20](20-etcd-sauvegarde-et-restauration.md). Depuis etcd 3.6, `etcdctl` ne fait plus que **sauvegarder** (`snapshot save`) ; `snapshot status` et `snapshot restore` sont dans `etcdutl`. `ETCDCTL_API=3` est inutile en 3.7 (avertissement « unrecognized environment variable »). Les options globales (`--endpoints`, `--cacert`…) n'apparaissent plus dans `etcdctl --help` : `etcdctl options` les liste.

```bash
sudo etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health                        # puis, avec les mêmes options : endpoint status -w table, member list -w table
```

La procédure complète de sauvegarde et de restauration est en A.10.1.

### A.7 Dépannage (30 %)

Chapitres [21](21-journaux-et-metriques.md), [22](22-depanner-les-applications.md) et [23](23-depanner-le-cluster.md).

#### A.7.1 Journaux, événements, métriques

```bash
kubectl logs api-<hash> -n boutique                    # conteneur unique
kubectl logs deploy/api -n boutique                    # un pod du Deployment
kubectl logs -l app=api -n boutique --prefix          # tous les pods ; avec -l, 10 lignes par pod par défaut
kubectl logs web-sondes -c nginx -p                    # instance précédente : cause d'un redémarrage
kubectl logs journal-demo --all-containers --since=10m --timestamps
kubectl events -n boutique --for pod/web-sondes --types=Warning
kubectl get events -n boutique --sort-by=.metadata.creationTimestamp
kubectl describe pod web-sondes -n boutique            # section Events en bas
kubectl top pods -A --sort-by=memory
kubectl describe node cka-m02 | grep -A8 'Allocated resources'
```

#### A.7.2 Lire l'état d'un pod

| Symptôme | Cause habituelle | Où regarder |
|---|---|---|
| `Pending`, événement `FailedScheduling` | ressources, affinité, taint, PVC non liée | `kubectl describe pod` |
| `Pending` **sans** événement | scheduler absent ou cassé | `kubectl -n kube-system get pods`, manifeste du scheduler |
| `ErrImagePull`, `ImagePullBackOff` | image ou étiquette fausse, registre privé | événements, `imagePullSecrets` |
| `CreateContainerConfigError` | ConfigMap, Secret ou clé absents | événements |
| `CrashLoopBackOff` | processus qui sort, liveness trop sévère | `kubectl logs -p`, `lastState.terminated` |
| `OOMKilled` (raison du dernier arrêt) | limite mémoire dépassée | `kubectl get pod -o yaml`, code 137 |
| `Running` mais `0/1` | readiness en échec | `kubectl describe pod`, EndpointSlices vides |
| `Terminating` sans fin | finalizer, nœud injoignable | `metadata.finalizers`, état du nœud |
| ReplicaSet sans pod | quota, admission (PSA), webhook | `kubectl describe rs`, événements `FailedCreate` |

```bash
kubectl debug -it pod/api-<hash> -n boutique --image=nicolaka/netshoot:v0.16 --target=agnhost  # éphémère
kubectl debug pod/api-<hash> -n boutique -it --copy-to=api-debug --image=busybox:1.37.0 --share-processes
kubectl debug node/cka-m02 -it --image=busybox:1.37.0     # racine du nœud en /host ; chroot /host
kubectl delete pod node-debugger-cka-m02-<suffixe>        # le pod de debug de nœud reste : à supprimer
```

#### A.7.3 Nœuds et control plane

```bash
kubectl get nodes ; kubectl describe node cka-m03 | grep -A10 Conditions
kubectl -n kube-system get pods -o wide
kubectl get --raw='/readyz?verbose'                    # contrôles de santé de l'apiserver
# sur le nœud :
sudo systemctl status kubelet ; sudo journalctl -u kubelet -n 50 --no-pager
sudo systemctl status containerd
sudo crictl ps -a | grep -E 'kube|etcd'
sudo ls /var/log/pods/ ; sudo tail -n 30 /var/log/pods/kube-system_kube-apiserver-*/kube-apiserver/*.log
sudo cat /var/lib/kubelet/config.yaml
```

> [!info] minikube ≠ examen
> Un nœud passe `NotReady` (condition `Unknown`, taints `unreachable`) environ 40 à 50 s après l'arrêt de son kubelet, sur les deux environnements (`--node-monitor-grace-period` de 50 s). Le kubelet du nœud `cka` est `disabled` dans systemd (minikube le lance lui-même) ; ceux des workers sont `enabled`, comme sur kubeadm.

### A.8 Chemins et ports : minikube contre kubeadm

Chapitres [2](02-architecture.md), [19](19-kubeadm-installation-ha-et-mises-a-jour.md), [20](20-etcd-sauvegarde-et-restauration.md) et [23](23-depanner-le-cluster.md).

| Élément | Cluster kubeadm (examen) | Lab minikube `cka` |
|---|---|---|
| Port de l'API | 6443 | **8443** (`control-plane.minikube.internal:8443`) |
| Manifestes statiques | `/etc/kubernetes/manifests/` | identique |
| Certificats | `/etc/kubernetes/pki/` (etcd : `pki/etcd/`) | **`/var/lib/minikube/certs/`** (etcd : `certs/etcd/`) |
| Données etcd | `/var/lib/etcd` | **`/var/lib/minikube/etcd`** |
| Kubeconfigs | `/etc/kubernetes/{admin,super-admin,controller-manager,scheduler,kubelet}.conf` | identique |
| Config du kubelet | `/var/lib/kubelet/config.yaml` | identique (`staticPodPath`, `cgroupDriver: systemd`, `clusterDNS: [10.96.0.10]`) |
| Unité du kubelet | drop-in `10-kubeadm.conf` qui lit `/var/lib/kubelet/kubeadm-flags.env` | options **en dur** dans `ExecStart` ; `kubeadm-flags.env` ignoré |
| Binaires kubeadm, kubelet, kubectl | `/usr/bin/` | **`/var/lib/minikube/binaries/v1.37.0/`**, hors PATH |
| Config kubeadm | ConfigMap `kube-system/kubeadm-config` | aussi `/var/tmp/minikube/kubeadm.yaml` |
| `kubeadm certs check-expiration` | sans option | `--config /var/tmp/minikube/kubeadm.yaml` ou `--cert-dir /var/lib/minikube/certs` |
| etcdctl / etcdutl | sur le nœud | à installer (chapitre 20), présents seulement dans l'image etcd |
| Taint du control plane | `node-role.kubernetes.io/control-plane:NoSchedule` | **aucune** |
| CoreDNS | 2 réplicas | 1 réplica |
| Élection de leader (scheduler, controller-manager) | activée | `--leader-elect=false` |
| Certificat de l'apiserver | 1 an | 3 ans (les autres 1 an, CA 10 ans) |
| Nom du cluster (kubeadm) | `kubernetes` | `mk` |
| Accès à un nœud | `ssh <nœud>`, `sudo -i` | `minikube -p cka ssh -n <nœud>`, `sudo` |
| Journaux des pods | `/var/log/pods/<ns>_<pod>_<uid>/<conteneur>/0.log` | identique |
| Socket du runtime | `unix:///run/containerd/containerd.sock` | identique (`crictl` exige `sudo`) |

| Port | Composant | Remarque |
|---|---|---|
| 6443 (8443 dans le lab) | kube-apiserver | |
| 2379 / 2380 | etcd client / pairs | 2381 : métriques, sur 127.0.0.1 |
| 10250 | API du kubelet | `logs`, `exec`, métriques |
| 10248 | santé du kubelet | `curl http://127.0.0.1:10248/healthz` sur le nœud |
| 10257 | kube-controller-manager | HTTPS, sur 127.0.0.1 |
| 10259 | kube-scheduler | HTTPS, sur 127.0.0.1 |
| 10256 / 10249 | kube-proxy santé / métriques | |
| 30000-32767 | Services NodePort | TCP et UDP |
| 53 | CoreDNS | UDP et TCP, Service 10.96.0.10 |

| Réseau du lab | Valeur |
|---|---|
| Nœuds | `cka` 192.168.49.2, `cka-m02` 192.168.49.3, `cka-m03` 192.168.49.4 (`minikube -p cka ip` fait foi) |
| Pods | 10.244.0.0/16, blocs Calico /26 (sans lien avec `spec.podCIDR`) |
| Services | 10.96.0.0/12 ; `kubernetes` = 10.96.0.1, DNS = 10.96.0.10 |
| MetalLB | 192.168.49.100-192.168.49.120 |

### A.9 jsonpath et sorties utiles

Chapitre [3](03-kubectl-efficace.md). Les chaînes littérales se placent entre guillemets doubles dans l'expression, l'expression entière entre apostrophes.

```bash
# Nom et InternalIP de chaque nœud, triés
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' | sort
# Taints de chaque nœud
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints}{"\n"}{end}'
# Images de tous les pods
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\n"}{end}'
# Pods et condition Ready
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
# Version du kubelet de chaque nœud
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.kubeletVersion}{"\n"}{end}'
# Une clé de Secret, décodée
kubectl get secret api-secret -n boutique -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
# Serveur du contexte courant
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'
# CRD d'un groupe
kubectl get crd -o jsonpath='{range .items[?(@.spec.group=="cert-manager.io")]}{.metadata.name}{"\n"}{end}'
# Adresse d'un Gateway
kubectl get gateway boutique-gw -n boutique -o jsonpath='{.status.addresses[0].value}'
```

```bash
kubectl get pods -A -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,NOEUD:.spec.nodeName'
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount'
kubectl get pv --sort-by=.spec.capacity.storage
kubectl get pods -o name                                  # pod/front-… : pratique dans une boucle
kubectl get deploy front -o yaml | less                   # -o kyaml (GA 1.37) pour du YAML sans ambiguïté
```

### A.10 Procédures éclair

#### A.10.1 Sauvegarder et restaurer etcd

Chapitre [20](20-etcd-sauvegarde-et-restauration.md). Sur le control plane, en root.

```bash
# 1. Sauvegarde (etcdctl), puis contrôle (etcdutl)
etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /opt/etcd-backup.db
etcdutl snapshot status /opt/etcd-backup.db -w table

# 2. Restauration dans un NOUVEAU répertoire (inexistant ou vide)
etcdutl snapshot restore /opt/etcd-backup.db --data-dir /var/lib/etcd-restore \
  --bump-revision 1000000000 --mark-compacted

# 3. Faire pointer etcd dessus : seul le hostPath du volume etcd-data change
cp /etc/kubernetes/manifests/etcd.yaml /root/etcd.yaml.orig        # sauvegarde HORS de manifests/
vim /etc/kubernetes/manifests/etcd.yaml                             # volumes: etcd-data → path: /var/lib/etcd-restore

# 4. Attendre le retour de l'API (≈ 1 min), puis vérifier
crictl ps | grep -E 'etcd|kube-apiserver'
kubectl get pods -A
```

`--bump-revision` et `--mark-compacted` (obligatoire dès que `--bump-revision` est non nul) évitent que le cache de watch de l'apiserver serve des objets postérieurs à la sauvegarde. Sans ces options, redémarre kube-apiserver, kube-controller-manager et kube-scheduler (`crictl stop` sur leurs conteneurs) après la restauration.

> [!info] minikube ≠ examen
> Dans le lab : `minikube -p cka ssh`, puis les mêmes commandes avec `sudo`, les certificats sous `/var/lib/minikube/certs/etcd/`, les données sous `/var/lib/minikube/etcd`, la sauvegarde dans `/var/lib/minikube/backup/` et la restauration dans `/var/lib/minikube/etcd-restore`. etcdctl et etcdutl ne sont pas installés d'origine : le chapitre 20 les pose dans `/usr/local/bin` à partir de l'archive officielle v3.7.0.

#### A.10.2 Mettre à jour un cluster kubeadm (1.36 → 1.37)

Chapitre [19](19-kubeadm-installation-ha-et-mises-a-jour.md).

```bash
# Sur chaque nœud : dépôt de la mineure cible
sudo sed -i 's#/v1.36/#/v1.37/#' /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update && apt-cache madison kubeadm | head -3       # 1.37.1-1.1

# Premier control plane (cp1)
sudo apt-mark unhold kubeadm && sudo apt-get install -y kubeadm='1.37.1-1.1' && sudo apt-mark hold kubeadm
kubeadm version -o short
sudo kubeadm upgrade plan
sudo kubeadm upgrade apply v1.37.1
kubectl drain cp1 --ignore-daemonsets
sudo apt-mark unhold kubelet kubectl && sudo apt-get install -y kubelet='1.37.1-1.1' kubectl='1.37.1-1.1' \
  && sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload && sudo systemctl restart kubelet
kubectl uncordon cp1

# Autres control planes : même chose, mais « kubeadm upgrade node » au lieu de plan/apply
# Workers : kubeadm (et kubectl) → sudo kubeadm upgrade node → drain depuis un control plane
#           → kubelet → daemon-reload + restart → uncordon
```

#### A.10.3 Créer un utilisateur par CSR

Chapitre [16](16-rbac-et-authentification.md).

```bash
cd ~/cka/rbac
openssl genrsa -out alice.key 3072
openssl req -new -key alice.key -out alice.csr -subj "/CN=alice/O=developpeurs"
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: alice
spec:
  request: $(base64 -w0 alice.csr)
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 604800
  usages: ["client auth"]
EOF
kubectl certificate approve alice
kubectl get csr alice -o jsonpath='{.status.certificate}' | base64 -d > alice.crt
kubectl config set-credentials alice --client-certificate=alice.crt --client-key=alice.key --embed-certs=true
kubectl config set-context alice@cka --cluster=cka --user=alice --namespace=boutique
kubectl --context=alice@cka auth whoami
```

#### A.10.4 Drainer un nœud

Chapitre [8](08-ordonnancement-et-admission.md).

```bash
kubectl drain cka-m02 --ignore-daemonsets --delete-emptydir-data   # --force pour les pods sans contrôleur
#   error when evicting pods/"front-…" -n "boutique" (will retry after 5s):
#   Cannot evict pod as it would violate the pod's disruption budget.
kubectl get pdb -A                                                 # ALLOWED DISRUPTIONS à 0 ?
kubectl uncordon cka-m02
```

`drain` passe par l'API Eviction, qui respecte les PodDisruptionBudgets ; un pod nu (sans contrôleur) supprimé par `--force` ne revient jamais.

#### A.10.5 Réparer un pod statique du control plane

Chapitre [23](23-depanner-le-cluster.md).

```bash
ssh <control-plane> ; sudo -i                          # lab : minikube -p cka ssh, puis sudo
ls -l /etc/kubernetes/manifests/                       # un fichier en trop ? une copie .bak ?
crictl ps -a --name kube-scheduler                     # Exited ? redémarrages ?
crictl logs <id-du-dernier-conteneur>                  # l'erreur exacte
ls /var/log/pods/ | grep kube-scheduler                # quand crictl ne montre plus rien
journalctl -u kubelet -n 50 --no-pager | grep -i scheduler   # erreur de lecture du manifeste
cp /etc/kubernetes/manifests/kube-scheduler.yaml /root/       # sauvegarde HORS de manifests/
vim /etc/kubernetes/manifests/kube-scheduler.yaml      # corriger image, option, chemin
watch crictl ps                                        # le kubelet recrée le pod de lui-même
kubectl -n kube-system get pod kube-scheduler-<nœud>
```

> [!danger] La copie de sauvegarde dans `manifests/`
> Tout fichier du dossier `/etc/kubernetes/manifests/` est lu comme un manifeste, quelle que soit son extension : une copie `kube-scheduler.yaml.bak` y fait naître un second pod du même nom et embrouille le diagnostic. Les sauvegardes vont dans `/root/` ou `/tmp/`.

#### A.10.6 Ramener un nœud NotReady

Chapitre [23](23-depanner-le-cluster.md).

```bash
kubectl describe node cka-m02 | grep -A10 Conditions       # « Kubelet stopped posting node status » ?
minikube -p cka ssh -n cka-m02                             # examen : ssh cka-m02 ; sudo -i
sudo systemctl status kubelet                              # inactive ? disabled ? en boucle ?
sudo journalctl -u kubelet -n 50 --no-pager                # chemin introuvable, certificat, runtime
sudo systemctl enable --now kubelet
sudo systemctl status containerd
sudo cat /var/lib/kubelet/config.yaml                      # clientCAFile, staticPodPath, cgroupDriver
exit
kubectl get node cka-m02 -w                                # Ready en quelques secondes
```

### A.11 Pages de documentation à ouvrir à l'examen

Les sites autorisés pendant l'examen sont `kubernetes.io/docs`, `kubernetes.io/blog`, `helm.sh/docs` et, pour le CKA, `gateway-api.sigs.k8s.io`. Ces pages contiennent un exemple à copier pour chaque type de tâche.

| Tâche | Page (titre sur kubernetes.io sauf mention) |
|---|---|
| Sondes | Configure Liveness, Readiness and Startup Probes |
| Sidecar natif | Sidecar Containers |
| Rolling update, rollback | Deployments |
| ConfigMap, Secret dans un pod | Configure a Pod to Use a ConfigMap ; Secrets |
| HPA avec `behavior` | Horizontal Pod Autoscaling |
| Affinité, tolérances | Assigning Pods to Nodes ; Taints and Tolerations |
| Quotas, limites | Resource Quotas ; Limit Ranges |
| Services | Service |
| Ingress | Ingress |
| HTTPRoute, poids | gateway-api.sigs.k8s.io : HTTP traffic splitting ; HTTPRoute |
| NetworkPolicy | Network Policies |
| PV, PVC, StorageClass | Persistent Volumes ; Storage Classes |
| RBAC | Using RBAC Authorization |
| Utilisateur par CSR | Certificates and Certificate Signing Requests |
| Helm | helm.sh/docs : Using Helm ; helm install |
| Kustomize | Declarative Management of Kubernetes Objects Using Kustomize |
| CRD | Extend the Kubernetes API with CustomResourceDefinitions |
| kubeadm upgrade | Upgrading kubeadm clusters ; Upgrading Linux nodes |
| etcd | Operating etcd clusters for Kubernetes |
| Dépannage | Debug Pods ; Debug Services ; Troubleshooting Clusters ; Debugging Kubernetes Nodes With Kubectl |
| jsonpath | JSONPath Support ; kubectl Quick Reference |

> [!warning] Page etcd de kubernetes.io
> Pour la v1.37, la page « Operating etcd clusters for Kubernetes » présente encore la restauration par `etcdctl` comme simplement dépréciée. Elle est supprimée depuis etcd 3.6 : avec l'etcd 3.7 que pose kubeadm 1.37, seul `etcdutl snapshot restore` fonctionne.

---
