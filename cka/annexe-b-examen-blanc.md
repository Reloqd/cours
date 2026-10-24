---
title: "CKA — Annexe B. Examen blanc"
description: "Dix-sept tâches en deux heures, notées sur cent avec un seuil à 66, préparées et corrigées par les scripts du lab, puis leur corrigé commenté."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## Annexe B. Examen blanc

Cet examen blanc reproduit les conditions du CKA autant qu'un lab local le permet : dix-sept tâches pratiques, deux heures, cent points, réussite à 66. Les tâches couvrent les cinq domaines du programme v1.37 et reprennent les gestes travaillés dans les chapitres 3 à 23, sans les répéter mot pour mot : un énoncé d'examen donne le résultat attendu, jamais la commande. Un script prépare le cluster, un autre note ton travail tâche par tâche.

Passe-le une fois le chapitre 23 terminé, d'une traite, chronomètre en marche, avec pour seules aides les sites autorisés à l'examen. Ne lis le corrigé qu'après la correction automatique : une tâche ratée t'apprend plus en relisant ta propre tentative qu'en lisant la solution d'abord. Le chapitre [24](24-examen.md) explique comment exploiter ce résultat avant de passer aux sessions killer.sh.

```
Déroulé :
═════════

  lab/restaurer.sh I4 ──▶ lab/examen-blanc/preparer.sh ──▶ 2 h de tâches ──▶ corriger.sh ──▶ lab/restaurer.sh I4
                                                            │
                                                            ├─ tâche 14 : preparer.sh 14
                                                            └─ tâche 15 : preparer.sh 15
```

### B.1 Consignes générales

L'examen se déroule sur le cluster du cours, profil minikube `cka`, contexte kubeconfig `cka`. Commence par `kubectl config use-context cka` : à l'examen réel, chaque tâche impose un contexte différent et l'oubli de cette commande est la première cause de points perdus. Chaque tâche indique son namespace ; travaille dedans et nulle part ailleurs. Les réponses écrites vont dans le dossier `~/cka/examen/`, créé par la préparation.

Les ressources autorisées sont celles de l'examen : `kubernetes.io/docs`, `kubernetes.io/blog`, `helm.sh/docs` et `gateway-api.sigs.k8s.io`. Ni le cours, ni tes notes, ni un moteur de recherche. Les commandes dans un nœud passent par `minikube -p cka ssh -n <nœud>` puis `sudo`, là où l'examen réel donne `ssh <nœud>` puis `sudo -i`.

Les tâches sont indépendantes, sauf sur un point : une panne non réparée pèse sur la suite. La tâche 14 rend `cka-m02` indisponible (au-delà de cinq minutes, ses pods sont évincés), la tâche 15 empêche tout nouveau pod d'être planifié. Leurs pannes ne sont donc injectées qu'à la demande, par `lab/examen-blanc/preparer.sh 14` et `lab/examen-blanc/preparer.sh 15`, au moment où tu abordes ces tâches. Tu peux, comme à l'examen, traiter les tâches dans l'ordre de ton choix et marquer celles qui résistent pour y revenir.

> [!warning] Ce qui ne rapporte rien
> Une tâche faite dans le mauvais namespace, un objet au nom approximatif ou un fichier de réponse au mauvais endroit valent zéro, même si le travail est juste. Relis les noms de l'énoncé avant de valider chaque tâche.

### B.2 Préparation

Pars de l'instantané I4 (fin du chapitre 18). Si ton cluster en est loin, ou si tu as déjà passé l'examen blanc, restaure-le d'abord (5 à 10 minutes) :

```bash
lab/restaurer.sh I4                 # depuis le dossier du cours, comme tous les scripts du lab
lab/examen-blanc/preparer.sh
```

La préparation remet à zéro un éventuel passage précédent, crée les namespaces `examen-rbac`, `examen-app`, `examen-sched`, `examen-svc`, `examen-gw`, `examen-ing`, `examen-net`, `examen-sto`, `examen-helm` et `examen-crd`, y dépose les objets préexistants que citent les énoncés, pose une taint sur un nœud, installe `etcdctl` et `etcdutl` dans le nœud `cka` comme sur un control plane d'examen, puis attend que tout soit prêt. Elle se termine par :

```
 OK examen prêt. Réponses écrites dans /home/<toi>/cka/examen/. Chronomètre : 2 heures.
==> tâches 14 et 15 : lance « lab/examen-blanc/preparer.sh 14 » puis « lab/examen-blanc/preparer.sh 15 » quand tu y arrives.
==> correction : lab/examen-blanc/corriger.sh
```

Démarre alors le chronomètre. Ne lis pas les scripts : ils contiennent les réponses.

### B.3 Barème

| N° | Points | Domaine | Namespace | Sujet |
|---|---|---|---|---|
| 1 | 4 | Dépannage | (cluster) | inventaire des nœuds |
| 2 | 7 | Architecture | `examen-rbac` | ServiceAccount et droits en lecture |
| 3 | 6 | Workloads | `examen-app` | mise à jour et retour arrière |
| 4 | 5 | Workloads | `examen-app` | ConfigMap et Secret dans un pod |
| 5 | 6 | Workloads | `examen-app` | autoscaling horizontal |
| 6 | 6 | Workloads | `examen-sched` | affinité de nœud et taint |
| 7 | 5 | Workloads | `examen-app` | sidecar natif |
| 8 | 7 | Réseau | `examen-svc` | Service sans backend, NodePort |
| 9 | 7 | Réseau | `examen-gw` | HTTPRoute pondérée |
| 10 | 5 | Réseau | `examen-ing` | Ingress |
| 11 | 7 | Réseau | `examen-net` | NetworkPolicy |
| 12 | 6 | Stockage | (cluster), `examen-sto` | StorageClass, PVC, pod |
| 13 | 6 | Architecture | nœud `cka` | sauvegarde d'etcd |
| 14 | 6 | Dépannage | nœud `cka-m02` | nœud NotReady |
| 15 | 6 | Dépannage | `kube-system` | pods Pending |
| 16 | 5 | Architecture | `examen-helm` | release Helm |
| 17 | 6 | Architecture | `examen-crd` | CRD et opérateur |
| | **100** | | | seuil de réussite : **66** |

Par domaine : Workloads and Scheduling 28 points, Services and Networking 26, Cluster Architecture 24, Troubleshooting 16, Storage 6. Le dépannage pèse moins ici qu'à l'examen (30 %) : les pannes des chapitres 22 et 23 (`lab/pannes.sh`) sont l'entraînement complémentaire. Une tâche partiellement juste rapporte une partie de ses points, comme à l'examen réel.

### B.4 Le sujet

#### Tâche 1 — Inventaire des nœuds (4 points)

**Contexte** : `cka`. **Namespace** : aucun (objets de cluster).

Écris dans le fichier `~/cka/examen/t01.txt` une ligne par nœud du cluster, de la forme `<nom> <InternalIP>` (un seul espace entre les deux champs), triées par nom de nœud. Le fichier ne contient rien d'autre : ni en-tête ni ligne vide.

#### Tâche 2 — Lecture seule des pods (7 points)

**Contexte** : `cka`. **Namespace** : `examen-rbac`.

Crée le ServiceAccount `lecteur`. Crée le Role `lecture-pods`, qui autorise les verbes `get`, `list` et `watch` sur les pods et rien d'autre, et lie-le au ServiceAccount `lecteur` par le RoleBinding `lecteur-pods`. Vérifie avec `kubectl auth can-i` que ce ServiceAccount peut lister les pods de `examen-rbac` et ne peut pas les supprimer.

#### Tâche 3 — Mise à jour et retour arrière (6 points)

**Contexte** : `cka`. **Namespace** : `examen-app`.

Crée le Deployment `web` : image `nginx:1.29-alpine`, 3 réplicas, stratégie RollingUpdate avec `maxSurge` à 2 et `maxUnavailable` à 1. Mets-le à jour vers l'image `nginx:1.30.6-alpine` et attends la fin du déploiement. Ramène-le ensuite à sa révision 1 par l'historique des révisions, sans le supprimer ni le recréer. Les 3 pods doivent être prêts à la fin.

#### Tâche 4 — Configuration d'un pod (5 points)

**Contexte** : `cka`. **Namespace** : `examen-app`.

La ConfigMap `parametres` et le Secret `identifiants` existent. Crée le pod `config-pod` (image `busybox:1.37.0`, commande `sleep 3600`) dans lequel la variable d'environnement `MODE` prend la valeur de la clé `MODE` de la ConfigMap `parametres`, et où le Secret `identifiants` est monté en lecture seule dans `/etc/secret`, un fichier par clé.

#### Tâche 5 — Autoscaling horizontal (6 points)

**Contexte** : `cka`. **Namespace** : `examen-app`.

Le Deployment `calcul` existe. Crée le HorizontalPodAutoscaler `calcul` qui le fait varier entre 1 et 5 réplicas pour viser une utilisation moyenne du CPU de 60 %. Pour réduire le nombre de réplicas, l'autoscaler ne doit tenir compte que des recommandations des 30 dernières secondes (fenêtre de stabilisation de descente de 30 s).

#### Tâche 6 — Placement contraint (6 points)

**Contexte** : `cka`. **Namespace** : `examen-sched`.

Crée le pod `rapide` (image `nginx:1.30.6-alpine`). Il ne doit pouvoir être placé que sur un nœud qui porte le label `disque=ssd`, et cette contrainte doit s'exprimer par une affinité de nœud **requise** (ni `nodeSelector` ni `nodeName`). Le nœud visé porte la taint `dedie=donnees:NoSchedule` : ne la retire pas. Le pod doit être `Running`.

#### Tâche 7 — Sidecar natif (5 points)

**Contexte** : `cka`. **Namespace** : `examen-app`.

Crée le pod `journal`. Son conteneur principal (image `busybox:1.37.0`) ajoute une ligne datée toutes les 5 secondes au fichier `/var/log/app.log`. Un conteneur sidecar **natif** (image `busybox:1.37.0`) suit ce fichier et le recopie sur sa sortie standard, de sorte que `kubectl logs` sur ce sidecar affiche les lignes écrites. Les noms des conteneurs et du volume sont libres. Le pod doit être prêt.

#### Tâche 8 — Service sans backend et NodePort (7 points)

**Contexte** : `cka`. **Namespace** : `examen-svc`.

Le Service `catalogue` ne transmet le trafic à aucun pod, alors que le Deployment `catalogue` (pods à l'écoute sur le port 8080) tourne normalement. Répare le Service sans modifier le Deployment. Expose ensuite le Deployment `catalogue` par un second Service, `catalogue-np`, de type NodePort : port 8080 vers le port 8080 des pods, port de nœud 30090. Depuis ton poste, `curl http://$(minikube -p cka ip):30090/hostname` doit renvoyer le nom d'un pod `catalogue-…`.

#### Tâche 9 — Répartition par Gateway API (7 points)

**Contexte** : `cka`. **Namespace** : `examen-gw`.

Le Gateway `examen-gw` (classe `eg`, listener `http` sur le port 80) et les Services `catalogue-v1` et `catalogue-v2` (port 8080) existent. Crée l'HTTPRoute `catalogue`, attachée au Gateway `examen-gw`, pour le nom d'hôte `catalogue.example` : toutes les requêtes (préfixe `/`) sont réparties à 80 % vers `catalogue-v1` et à 20 % vers `catalogue-v2`.

#### Tâche 10 — Ingress (5 points)

**Contexte** : `cka`. **Namespace** : `examen-ing`.

Le Service `docs` (port 80) existe. Crée l'Ingress `docs`, de classe `nginx`, qui sert l'hôte `docs.example` : le chemin `/`, de type `Prefix`, est routé vers le Service `docs` sur le port 80.

#### Tâche 11 — Isoler une base de données (7 points)

**Contexte** : `cka`. **Namespace** : `examen-net`.

Les pods `bdd` (label `app=bdd`, à l'écoute en TCP 5432), `front` (label `role=front`) et `autre` (label `role=autre`) existent. Crée la NetworkPolicy `bdd-entree` : seuls les pods `role=front` du namespace peuvent joindre les pods `app=bdd`, et uniquement en TCP sur le port 5432 ; tout autre trafic entrant vers les pods `app=bdd` est refusé. Ne restreins pas le trafic des autres pods.

#### Tâche 12 — Stockage dynamique (6 points)

**Contexte** : `cka`. **Namespaces** : aucun pour la StorageClass, `examen-sto` pour le reste.

Crée la StorageClass `lente` : provisioner `hostpath.csi.k8s.io`, politique de récupération `Retain`, mode de liaison `WaitForFirstConsumer`. Dans `examen-sto`, crée la PersistentVolumeClaim `donnees` (200Mi, `ReadWriteOnce`, classe `lente`) et le pod `stockeur` (image `busybox:1.37.0`, commande `sleep 3600`) qui la monte en `/data`. La PVC doit être `Bound` et le pod `Running`.

#### Tâche 13 — Sauvegarde d'etcd (6 points)

**Contexte** : `cka`. **Nœud** : `cka`.

Sur le nœud `cka`, prends un instantané d'etcd et enregistre-le dans `/var/lib/minikube/backup/examen.db`. etcd écoute sur `https://127.0.0.1:2379` ; son CA, son certificat et sa clé de serveur sont dans `/var/lib/minikube/certs/etcd/` (`ca.crt`, `server.crt`, `server.key`). `etcdctl` et `etcdutl` sont installés sur le nœud. Vérifie que l'instantané est valide.

#### Tâche 14 — Nœud NotReady (6 points)

**Contexte** : `cka`. **Nœud** : `cka-m02`.

Lance d'abord `lab/examen-blanc/preparer.sh 14`. Le nœud `cka-m02` passe `NotReady` dans la minute qui suit. Trouve la cause et répare-la de façon durable : le nœud doit être `Ready` et le rester après un redémarrage de la machine.

#### Tâche 15 — Pods en attente (6 points)

**Contexte** : `cka`. **Namespace** : `kube-system`.

Lance d'abord `lab/examen-blanc/preparer.sh 15`. Les nouveaux pods du cluster restent `Pending`. Trouve la cause et répare-la. Ne laisse aucun fichier supplémentaire dans `/etc/kubernetes/manifests/` du nœud `cka`.

#### Tâche 16 — Release Helm (5 points)

**Contexte** : `cka`. **Namespace** : `examen-helm`.

Installe le chart `podinfo` en version 6.15.0 (celle du chapitre 17), depuis le dépôt `https://stefanprodan.github.io/podinfo`, sous le nom de release `exam-podinfo`, dans le namespace `examen-helm`, avec 2 réplicas. Les deux pods doivent être prêts.

#### Tâche 17 — CRD et opérateur (6 points)

**Contexte** : `cka`. **Namespace** : `examen-crd`.

Écris dans `~/cka/examen/t17.txt` le nom de chaque CustomResourceDefinition dont le groupe d'API est exactement `cert-manager.io`, un nom par ligne. Puis, dans `examen-crd`, crée l'Issuer `examen-issuer`, de type autosigné, et le Certificate `examen-cert` qu'il signe pour le nom DNS `examen.example`, rangé dans le Secret `examen-tls`. Le Certificate doit être prêt (`Ready`).

### B.5 Correction et remise en état

À la fin des deux heures, arrête-toi, même au milieu d'une tâche, et lance la correction :

```bash
lab/examen-blanc/corriger.sh
```

Le script vérifie chaque tâche par plusieurs critères, chacun valant une partie des points, et affiche le détail puis le total :

```
Tâche 3 (6 pts) — Deployment web : mise à jour puis retour à la révision 1 (examen-app)
   [+1] web : 3 réplicas
   [+1] stratégie maxSurge 2, maxUnavailable 1
   [+1] un ReplicaSet en nginx:1.30.6-alpine prouve la mise à jour
   [+2] image courante nginx:1.29-alpine en révision 3 ou plus
   [+1] 3 pods prêts
   => 6/6
…
 OK note : 81 / 100 (seuil 66) — réussi
```

La correction teste le résultat, pas la méthode : un objet juste obtenu par un chemin inattendu rapporte ses points, un objet presque juste n'en rapporte qu'une partie. Note pour chaque tâche manquée la compétence en cause et le chapitre qui la traite, puis relis le corrigé. Pour retrouver un cluster propre, que ce soit pour reprendre le fil des chapitres 20 à 23 ou repasser l'examen blanc plus tard :

```bash
lab/restaurer.sh I4
```

### B.6 Corrigé

Chaque solution donne une façon rapide d'obtenir le résultat, l'explication des choix, la vérification à faire avant de passer à la suite, et la page de documentation à ouvrir le jour de l'examen. Les commandes `kubectl` supposent le contexte `cka`.

#### Corrigé de la tâche 1

> [!example]- Solution
> ```bash
> mkdir -p ~/cka/examen
> kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
>   | sort > ~/cka/examen/t01.txt
> cat ~/cka/examen/t01.txt
> ```
>
> ```
> cka 192.168.49.2
> cka-m02 192.168.49.3
> cka-m03 192.168.49.4
> ```
>
> Le filtre `?(@.type=="InternalIP")` choisit la bonne entrée de `status.addresses`, qui contient aussi `Hostname` ; le prendre par son indice (`addresses[0]`) marche ici par chance, pas par construction. `range … end` produit une ligne par nœud, et `sort` garantit l'ordre demandé. Une autre voie, plus fragile, découpe `kubectl get nodes -o wide --no-headers` avec `awk '{print $1, $6}'` : elle dépend de la position de la colonne INTERNAL-IP et casserait si une colonne changeait.
>
> **Vérification** : `cat -A ~/cka/examen/t01.txt` montre trois lignes terminées par `$`, un seul espace par ligne, aucune ligne vide.
>
> **Doc à ouvrir** : « JSONPath Support » et « kubectl Quick Reference » (kubernetes.io).

#### Corrigé de la tâche 2

> [!example]- Solution
> ```bash
> kubectl -n examen-rbac create serviceaccount lecteur
> kubectl -n examen-rbac create role lecture-pods --verb=get,list,watch --resource=pods
> kubectl -n examen-rbac create rolebinding lecteur-pods --role=lecture-pods \
>   --serviceaccount=examen-rbac:lecteur
> kubectl auth can-i list pods -n examen-rbac --as=system:serviceaccount:examen-rbac:lecteur     # yes
> kubectl auth can-i delete pods -n examen-rbac --as=system:serviceaccount:examen-rbac:lecteur   # no
> ```
>
> `--serviceaccount` attend la forme `<namespace>:<nom>`, et l'identité d'un ServiceAccount, pour `--as`, s'écrit `system:serviceaccount:<namespace>:<nom>`. Tester avec `--as=lecteur` interrogerait les droits d'un utilisateur `lecteur` qui n'a rien à voir : la réponse `no` ne prouverait rien. Le Role ne vise que `pods`, sans `pods/log` ni autre sous-ressource, conformément à « rien d'autre ».
>
> **Vérification** : `kubectl -n examen-rbac describe rolebinding lecteur-pods` montre `Role/lecture-pods` et le sujet `ServiceAccount lecteur examen-rbac` ; les deux `can-i` répondent `yes` puis `no`.
>
> **Doc à ouvrir** : « Using RBAC Authorization » (kubernetes.io).

#### Corrigé de la tâche 3

> [!example]- Solution
> `kubectl create deployment` ne règle pas la stratégie : génère le YAML, ajoute-la, puis crée l'objet (`~/cka/examen/web.yaml`).
>
> ```yaml
> apiVersion: apps/v1
> kind: Deployment
> metadata:
>   name: web
>   namespace: examen-app
>   labels:
>     app: web
> spec:
>   replicas: 3
>   selector:
>     matchLabels:
>       app: web
>   strategy:
>     type: RollingUpdate
>     rollingUpdate:
>       maxSurge: 2
>       maxUnavailable: 1
>   template:
>     metadata:
>       labels:
>         app: web
>     spec:
>       containers:
>       - name: nginx
>         image: nginx:1.29-alpine
> ```
>
> ```bash
> kubectl apply -f ~/cka/examen/web.yaml
> kubectl -n examen-app rollout status deployment web
> kubectl -n examen-app set image deployment/web nginx=nginx:1.30.6-alpine
> kubectl -n examen-app rollout status deployment web
> kubectl -n examen-app rollout history deployment web                # révisions 1 et 2
> kubectl -n examen-app rollout undo deployment web --to-revision=1
> kubectl -n examen-app rollout status deployment web
> ```
>
> Le retour arrière ne crée pas un nouveau ReplicaSet : il remet à l'échelle celui de la révision 1, qui prend le numéro 3. C'est pourquoi `rollout history` affiche ensuite les révisions 2 et 3, et non 1. Réappliquer le fichier d'origine donnerait la même image, mais pas un retour « par l'historique » ; supprimer et recréer le Deployment perdrait l'historique et la trace de la mise à jour, que la correction contrôle.
>
> **Vérification** :
> ```bash
> kubectl -n examen-app get deploy web \
>   -o jsonpath='{.spec.template.spec.containers[0].image} {.metadata.annotations.deployment\.kubernetes\.io/revision} {.status.readyReplicas}{"\n"}'
> ```
> ```
> nginx:1.29-alpine 3 3
> ```
>
> **Doc à ouvrir** : « Deployments » (kubernetes.io), sections *Updating a Deployment* et *Rolling Back a Deployment*.

#### Corrigé de la tâche 4

> [!example]- Solution
> Commence par lire les objets existants : le nom exact de la clé compte.
>
> ```bash
> kubectl -n examen-app get configmap parametres -o yaml | grep -A2 '^data'
> kubectl -n examen-app get secret identifiants -o jsonpath='{.data}{"\n"}'
> kubectl -n examen-app run config-pod --image=busybox:1.37.0 --dry-run=client -o yaml \
>   --command -- sleep 3600 > ~/cka/examen/config-pod.yaml
> ```
>
> Fichier complété :
>
> ```yaml
> apiVersion: v1
> kind: Pod
> metadata:
>   name: config-pod
>   namespace: examen-app
> spec:
>   containers:
>   - name: config-pod
>     image: busybox:1.37.0
>     command: ["sleep", "3600"]
>     env:
>     - name: MODE
>       valueFrom:
>         configMapKeyRef:
>           name: parametres
>           key: MODE
>     volumeMounts:
>     - name: identifiants
>       mountPath: /etc/secret
>       readOnly: true
>   volumes:
>   - name: identifiants
>     secret:
>       secretName: identifiants
> ```
>
> ```bash
> kubectl apply -f ~/cka/examen/config-pod.yaml
> ```
>
> Un volume `secret` crée un fichier par clé du Secret, au contenu décodé. `envFrom` avec `configMapRef` aurait aussi donné `MODE`, puisque la clé porte ce nom, mais il importerait toutes les autres clés de la ConfigMap : `configMapKeyRef` répond exactement à l'énoncé.
>
> **Vérification** :
> ```bash
> kubectl -n examen-app exec config-pod -- printenv MODE        # examen
> kubectl -n examen-app exec config-pod -- ls /etc/secret       # password
> kubectl -n examen-app exec config-pod -- cat /etc/secret/password; echo
> ```
>
> **Doc à ouvrir** : « Configure a Pod to Use a ConfigMap » et « Secrets » (kubernetes.io).

#### Corrigé de la tâche 5

> [!example]- Solution
> `kubectl autoscale` produit la base, mais ne sait pas écrire `behavior` : génère, complète, applique.
>
> ```bash
> kubectl -n examen-app autoscale deployment calcul --min=1 --max=5 --cpu=60% \
>   --dry-run=client -o yaml > ~/cka/examen/hpa-calcul.yaml
> ```
>
> ```yaml
> apiVersion: autoscaling/v2
> kind: HorizontalPodAutoscaler
> metadata:
>   name: calcul
>   namespace: examen-app
> spec:
>   scaleTargetRef:
>     apiVersion: apps/v1
>     kind: Deployment
>     name: calcul
>   minReplicas: 1
>   maxReplicas: 5
>   metrics:
>   - type: Resource
>     resource:
>       name: cpu
>       target:
>         type: Utilization
>         averageUtilization: 60
>   behavior:
>     scaleDown:
>       stabilizationWindowSeconds: 30
> ```
>
> ```bash
> kubectl apply -f ~/cka/examen/hpa-calcul.yaml
> ```
>
> `--cpu=60%` remplace en 1.37 l'option `--cpu-percent`, dépréciée. Le pourcentage s'entend par rapport aux requests CPU des conteneurs : le Deployment `calcul` en déclare (100m), sans quoi le HPA afficherait `<unknown>` indéfiniment. La fenêtre de stabilisation de descente vaut 300 s par défaut ; l'énoncé la ramène à 30 s.
>
> **Vérification** : `kubectl -n examen-app get hpa calcul` montre `REFERENCE Deployment/calcul`, `MINPODS 1`, `MAXPODS 5` et, après une minute environ, `TARGETS cpu: 1%/60%` (avant, `<unknown>/60%` le temps que metrics-server publie une mesure). `kubectl -n examen-app get hpa calcul -o jsonpath='{.spec.behavior.scaleDown.stabilizationWindowSeconds}'` affiche `30`.
>
> **Doc à ouvrir** : « Horizontal Pod Autoscaling » (kubernetes.io), section *Configurable scaling behavior*.

#### Corrigé de la tâche 6

> [!example]- Solution
> ```bash
> kubectl get nodes -l disque=ssd                       # cka-m03
> kubectl describe node cka-m03 | grep -A1 Taints       # dedie=donnees:NoSchedule
> ```
>
> ```yaml
> apiVersion: v1
> kind: Pod
> metadata:
>   name: rapide
>   namespace: examen-sched
> spec:
>   affinity:
>     nodeAffinity:
>       requiredDuringSchedulingIgnoredDuringExecution:
>         nodeSelectorTerms:
>         - matchExpressions:
>           - key: disque
>             operator: In
>             values: ["ssd"]
>   tolerations:
>   - key: dedie
>     operator: Equal
>     value: donnees
>     effect: NoSchedule
>   containers:
>   - name: rapide
>     image: nginx:1.30.6-alpine
> ```
>
> Il faut les deux. L'affinité seule laisse le pod `Pending` : le seul nœud qui la satisfait est tainté, et l'événement `FailedScheduling` dit qu'un nœud a une taint non tolérée et que les deux autres ne correspondent pas à l'affinité. La tolérance seule n'attire rien : elle autorise `cka-m03` sans l'imposer, et le pod irait sur n'importe quel nœud. C'est le piège classique de cette tâche.
>
> **Vérification** : `kubectl -n examen-sched get pod rapide -o wide` affiche `Running` sur `cka-m03`.
>
> **Doc à ouvrir** : « Assigning Pods to Nodes » et « Taints and Tolerations » (kubernetes.io).

#### Corrigé de la tâche 7

> [!example]- Solution
> ```yaml
> apiVersion: v1
> kind: Pod
> metadata:
>   name: journal
>   namespace: examen-app
> spec:
>   initContainers:
>   - name: suiveur
>     image: busybox:1.37.0
>     restartPolicy: Always
>     command: ["sh", "-c", "trap 'exit 0' TERM; tail -F /var/log/app.log & wait"]
>     volumeMounts:
>     - name: journaux
>       mountPath: /var/log
>   containers:
>   - name: app
>     image: busybox:1.37.0
>     command: ["sh", "-c", "while true; do echo \"$(date) ligne\" >> /var/log/app.log; sleep 5; done"]
>     volumeMounts:
>     - name: journaux
>       mountPath: /var/log
>   volumes:
>   - name: journaux
>     emptyDir: {}
> ```
>
> Le sidecar natif est un init container avec `restartPolicy: Always` : un second conteneur placé dans `containers` serait un sidecar « classique », que l'énoncé n'accepte pas. Il démarre **avant** le conteneur principal, donc avant que le fichier existe : `tail -F` (et non `-f`) attend que le fichier apparaisse au lieu de sortir en erreur. Le `trap` lui fait quitter proprement sur `SIGTERM`, comme au chapitre 4.
>
> **Vérification** :
> ```bash
> kubectl -n examen-app get pod journal                     # READY 2/2, STATUS Running
> kubectl -n examen-app logs journal -c suiveur --tail=3    # lignes datées
> ```
>
> **Doc à ouvrir** : « Sidecar Containers » (kubernetes.io).

#### Corrigé de la tâche 8

> [!example]- Solution
> Diagnostic d'abord : un Service sans backend, c'est un sélecteur qui ne correspond à aucun pod prêt, ou des pods qui ne sont pas prêts.
>
> ```bash
> kubectl -n examen-svc describe service catalogue | grep -E 'Selector|Endpoints'   # Selector: app=catalog
> kubectl -n examen-svc get pods --show-labels                                       # app=catalogue
> kubectl -n examen-svc patch service catalogue -p '{"spec":{"selector":{"app":"catalogue"}}}'
> kubectl -n examen-svc get endpointslices -l kubernetes.io/service-name=catalogue  # deux adresses
> ```
>
> Pour le NodePort, `kubectl expose` reprend le sélecteur du Deployment ; on fixe le port de nœud dans le YAML avant de créer l'objet :
>
> ```bash
> kubectl -n examen-svc expose deployment catalogue --name=catalogue-np --type=NodePort \
>   --port=8080 --target-port=8080 --dry-run=client -o yaml > ~/cka/examen/catalogue-np.yaml
> ```
>
> ```yaml
> apiVersion: v1
> kind: Service
> metadata:
>   name: catalogue-np
>   namespace: examen-svc
>   labels:
>     app: catalogue
> spec:
>   type: NodePort
>   selector:
>     app: catalogue
>   ports:
>   - port: 8080
>     protocol: TCP
>     targetPort: 8080
>     nodePort: 30090
> ```
>
> ```bash
> kubectl apply -f ~/cka/examen/catalogue-np.yaml
> ```
>
> Modifier les labels du Deployment pour qu'ils collent au sélecteur fautif réparerait aussi le Service, mais l'énoncé l'interdit, et cela recréerait tous les pods. `kubectl create service nodeport catalogue-np --tcp=8080:8080 --node-port=30090` est un piège : il pose le sélecteur `app=catalogue-np`, qui ne désigne aucun pod.
>
> **Vérification** :
> ```bash
> curl -s http://$(minikube -p cka ip):30090/hostname; echo     # catalogue-<hachage>-<suffixe>
> ```
>
> **Doc à ouvrir** : « Service » et « Debug Services » (kubernetes.io).

#### Corrigé de la tâche 9

> [!example]- Solution
> ```yaml
> apiVersion: gateway.networking.k8s.io/v1
> kind: HTTPRoute
> metadata:
>   name: catalogue
>   namespace: examen-gw
> spec:
>   parentRefs:
>   - name: examen-gw
>   hostnames:
>   - catalogue.example
>   rules:
>   - matches:
>     - path:
>         type: PathPrefix
>         value: /
>     backendRefs:
>     - name: catalogue-v1
>       port: 8080
>       weight: 80
>     - name: catalogue-v2
>       port: 8080
>       weight: 20
> ```
>
> Les deux backends sont dans la **même** règle : c'est le poids relatif qui répartit, 80/(80+20) et 20/(80+20). Deux règles distinctes avec la même correspondance ne partageraient rien. Le Gateway admet les routes de son namespace (`allowedRoutes` `Same`) : la route doit donc être créée dans `examen-gw`, et `parentRefs` n'a pas besoin de namespace. Le `port` d'un `backendRef` vers un Service est obligatoire.
>
> **Vérification** :
> ```bash
> kubectl -n examen-gw get httproute catalogue \
>   -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status}{"\n"}{end}'   # Accepted=True, ResolvedRefs=True
> GW=$(kubectl -n examen-gw get gateway examen-gw -o jsonpath='{.status.addresses[0].value}')
> for i in $(seq 100); do curl -s -H 'Host: catalogue.example' http://$GW/hostname; echo; done \
>   | cut -d- -f2 | sort | uniq -c                                                   # ≈ 80 v1, ≈ 20 v2
> ```
>
> **Doc à ouvrir** : « HTTP traffic splitting » et « HTTPRoute » (gateway-api.sigs.k8s.io).

#### Corrigé de la tâche 10

> [!example]- Solution
> ```bash
> kubectl -n examen-ing create ingress docs --class=nginx --rule='docs.example/*=docs:80'
> kubectl -n examen-ing get ingress docs -o yaml | grep -A12 'spec:'
> ```
>
> Dans `--rule`, un chemin terminé par `/*` produit `path: /` et `pathType: Prefix` ; sans l'étoile, kubectl écrirait `pathType: Exact`, et seule la racine exacte serait servie. `--class` remplit `spec.ingressClassName`, préférable à l'ancienne annotation `kubernetes.io/ingress.class`.
>
> **Vérification** : la colonne ADDRESS de `kubectl -n examen-ing get ingress docs` prend la valeur `192.168.49.2` au bout de quelques dizaines de secondes, puis :
> ```bash
> curl -s -o /dev/null -w '%{http_code}\n' --resolve docs.example:80:$(minikube -p cka ip) http://docs.example/   # 200
> ```
>
> **Doc à ouvrir** : « Ingress » (kubernetes.io) et la page de référence `kubectl create ingress`.

#### Corrigé de la tâche 11

> [!example]- Solution
> ```yaml
> apiVersion: networking.k8s.io/v1
> kind: NetworkPolicy
> metadata:
>   name: bdd-entree
>   namespace: examen-net
> spec:
>   podSelector:
>     matchLabels:
>       app: bdd
>   policyTypes:
>   - Ingress
>   ingress:
>   - from:
>     - podSelector:
>         matchLabels:
>           role: front
>     ports:
>     - protocol: TCP
>       port: 5432
> ```
>
> Dès qu'une politique sélectionne `bdd` pour l'entrée, tout trafic entrant qu'aucune règle n'autorise est refusé : pas besoin d'une politique de refus séparée. Un `podSelector` seul dans `from` vise les pods du même namespace. N'ajoute pas `Egress` à `policyTypes` : `bdd` perdrait aussi sa sortie, DNS compris, et l'énoncé ne demande rien de tel. Une politique `podSelector: {}` aurait isolé tous les pods du namespace, `front` et `autre` compris.
>
> **Vérification** :
> ```bash
> BDD=$(kubectl -n examen-net get pod bdd -o jsonpath='{.status.podIP}')
> kubectl -n examen-net exec front -- wget -qO- -T 3 http://$BDD:5432/hostname; echo   # bdd
> kubectl -n examen-net exec autre -- wget -qO- -T 3 http://$BDD:5432/hostname         # wget: download timed out
> ```
>
> **Doc à ouvrir** : « Network Policies » (kubernetes.io).

#### Corrigé de la tâche 12

> [!example]- Solution
> ```yaml
> apiVersion: storage.k8s.io/v1
> kind: StorageClass
> metadata:
>   name: lente
> provisioner: hostpath.csi.k8s.io
> reclaimPolicy: Retain
> volumeBindingMode: WaitForFirstConsumer
> ---
> apiVersion: v1
> kind: PersistentVolumeClaim
> metadata:
>   name: donnees
>   namespace: examen-sto
> spec:
>   storageClassName: lente
>   accessModes: ["ReadWriteOnce"]
>   resources:
>     requests:
>       storage: 200Mi
> ---
> apiVersion: v1
> kind: Pod
> metadata:
>   name: stockeur
>   namespace: examen-sto
> spec:
>   containers:
>   - name: stockeur
>     image: busybox:1.37.0
>     command: ["sleep", "3600"]
>     volumeMounts:
>     - name: donnees
>       mountPath: /data
>   volumes:
>   - name: donnees
>     persistentVolumeClaim:
>       claimName: donnees
> ```
>
> Avec `WaitForFirstConsumer`, la PVC reste `Pending` tant qu'aucun pod ne l'utilise : c'est normal, pas une erreur. Le scheduler choisit d'abord le nœud du pod, puis le pilote CSI de ce nœud crée le volume, ce qui évite qu'un volume local naisse sur un nœud où le pod ne pourra pas aller. `reclaimPolicy: Retain` garde le PV et ses données quand la PVC sera supprimée.
>
> **Vérification** :
> ```bash
> kubectl -n examen-sto get pvc donnees          # STATUS Bound, CAPACITY 200Mi, STORAGECLASS lente
> kubectl get pv | grep examen-sto/donnees       # RECLAIM POLICY Retain
> kubectl -n examen-sto exec stockeur -- sh -c 'echo ok > /data/test && cat /data/test'
> ```
>
> **Doc à ouvrir** : « Storage Classes » et « Persistent Volumes » (kubernetes.io).

#### Corrigé de la tâche 13

> [!example]- Solution
> ```bash
> minikube -p cka ssh
> sudo mkdir -p /var/lib/minikube/backup
> sudo etcdctl --endpoints=https://127.0.0.1:2379 \
>   --cacert=/var/lib/minikube/certs/etcd/ca.crt \
>   --cert=/var/lib/minikube/certs/etcd/server.crt \
>   --key=/var/lib/minikube/certs/etcd/server.key \
>   snapshot save /var/lib/minikube/backup/examen.db
> sudo etcdutl snapshot status /var/lib/minikube/backup/examen.db -w table
> exit
> ```
>
> ```
> Snapshot saved at /var/lib/minikube/backup/examen.db
> Server version 3.7.0
> ```
>
> `snapshot save` ne crée pas le dossier de destination, d'où le `mkdir -p`. `sudo` est indispensable : les clés d'etcd sont lisibles par root seul. Depuis etcd 3.6, le contrôle se fait avec `etcdutl snapshot status`, `etcdctl` n'ayant plus que `snapshot save` ; `ETCDCTL_API=3` est inutile en 3.7 et ne provoque qu'un avertissement. À l'examen, si l'énoncé ne donne pas les chemins, lis-les dans le manifeste : `grep -E 'cert-file|key-file|trusted-ca-file|listen-client-urls' /etc/kubernetes/manifests/etcd.yaml` (sous `/etc/kubernetes/pki/etcd/` sur un cluster kubeadm).
>
> **Vérification** : le tableau de `etcdutl snapshot status` affiche une empreinte, une révision, le nombre de clés, une taille de quelques mégaoctets et la version `3.7.0`.
>
> **Doc à ouvrir** : « Operating etcd clusters for Kubernetes » (kubernetes.io), section *Backing up an etcd cluster*. Rappelle-toi que sa partie restauration par `etcdctl` est périmée (annexe A.11).

#### Corrigé de la tâche 14

> [!example]- Solution
> ```bash
> kubectl get nodes                                            # cka-m02 NotReady
> kubectl describe node cka-m02 | grep -A8 Conditions          # Unknown, « Kubelet stopped posting node status. »
> minikube -p cka ssh -n cka-m02                               # examen : ssh cka-m02 puis sudo -i
> sudo systemctl status kubelet --no-pager | head -4           # disabled ; Active: inactive (dead)
> sudo journalctl -u kubelet -n 20 --no-pager                  # arrêt propre, aucune erreur de démarrage
> sudo systemctl enable --now kubelet
> systemctl is-enabled kubelet                                 # enabled
> exit
> kubectl get node cka-m02 -w                                  # Ready en quelques secondes
> ```
>
> Le message « Kubelet stopped posting node status » oriente vers le kubelet lui-même : le contrôleur des nœuds ne reçoit plus de nouvelles depuis plus de 50 s. Le service est arrêté **et** désactivé : `systemctl start` suffirait à rendre le nœud `Ready`, mais il retomberait au prochain redémarrage, ce que l'énoncé exclut. `enable --now` règle les deux en une commande. Si le journal avait montré une erreur (fichier introuvable, certificat), il aurait fallu corriger `/var/lib/kubelet/config.yaml` avant de redémarrer.
>
> **Vérification** : `kubectl get node cka-m02` affiche `Ready`, et les taints `node.kubernetes.io/unreachable` ont disparu (`kubectl describe node cka-m02 | grep Taints` donne `<none>`).
>
> **Doc à ouvrir** : « Troubleshooting Clusters » (kubernetes.io).

#### Corrigé de la tâche 15

> [!example]- Solution
> ```bash
> kubectl run test-sched --image=busybox:1.37.0 --restart=Never -- sleep 30
> kubectl get pod test-sched -o wide             # Pending, NODE <none>
> kubectl describe pod test-sched | tail -2      # Events: <none> : personne n'essaie de le placer
> kubectl -n kube-system get pods -l component=kube-scheduler
> kubectl -n kube-system describe pod kube-scheduler-cka | grep -iE 'state|reason|message' | head
> ```
>
> Un pod `Pending` **sans** événement `FailedScheduling` désigne le scheduler, pas les nœuds. Son pod statique est en erreur (`RunContainerError`, `StartError` ou `CrashLoopBackOff` selon l'instant) et son message indique que l'exécutable `kube-schedulr` est introuvable : la commande du conteneur a été altérée dans le manifeste.
>
> ```bash
> minikube -p cka ssh                                          # examen : ssh <control-plane> puis sudo -i
> sudo ls /etc/kubernetes/manifests/                           # quatre manifestes, rien d'autre
> sudo grep -n -A2 'command:' /etc/kubernetes/manifests/kube-scheduler.yaml   # - kube-schedulr
> sudo cp /etc/kubernetes/manifests/kube-scheduler.yaml /root/kube-scheduler.yaml.avant   # copie HORS de manifests/
> sudo sed -i 's/^    - kube-schedulr$/    - kube-scheduler/' /etc/kubernetes/manifests/kube-scheduler.yaml
> sudo crictl ps --name kube-scheduler                         # Running après quelques secondes
> exit
> kubectl -n kube-system get pods -l component=kube-scheduler  # 1/1 Running
> kubectl get pod test-sched -o wide                           # planifié sur un nœud
> kubectl delete pod test-sched
> ```
>
> Le kubelet surveille le dossier des manifestes et recrée le pod statique dès que le fichier change. Modifier le pod miroir par `kubectl edit` ne sert à rien, et le supprimer ne fait que le voir réapparaître : la source de vérité est le fichier. La copie de sauvegarde va dans `/root/` : laissée dans `manifests/`, même sous un autre suffixe, elle serait chargée comme un second manifeste, ce que la correction pénalise.
>
> **Vérification** : `kubectl -n kube-system get pods -l component=kube-scheduler` affiche `1/1 Running`, un nouveau pod est planifié en quelques secondes, et `sudo ls /etc/kubernetes/manifests/` dans le nœud ne liste que `etcd.yaml`, `kube-apiserver.yaml`, `kube-controller-manager.yaml` et `kube-scheduler.yaml`.
>
> **Doc à ouvrir** : « Troubleshooting Clusters » et « Create static Pods » (kubernetes.io).

#### Corrigé de la tâche 16

> [!example]- Solution
> ```bash
> helm repo add podinfo https://stefanprodan.github.io/podinfo     # « already exists » si fait au chapitre 17
> helm repo update
> helm show values podinfo/podinfo --version 6.15.0 | grep -n replicaCount   # 3:replicaCount: 1
> helm install exam-podinfo podinfo/podinfo --version 6.15.0 \
>   -n examen-helm --set replicaCount=2 --wait --timeout 5m
> ```
>
> Vérifier le nom de la valeur dans `helm show values` évite de deviner : un `--set replicas=2` serait accepté sans erreur et ignoré par le chart. Le namespace existe déjà ; `--create-namespace` serait sans effet. `--wait` seul attend, en Helm 4, que les objets soient prêts au sens de kstatus. La variante OCI `oci://ghcr.io/stefanprodan/charts/podinfo --version 6.15.0` installe le même chart sans `helm repo add`. Comme le nom de release contient déjà `podinfo`, le chart nomme le Deployment et le Service `exam-podinfo`, et non `exam-podinfo-podinfo`.
>
> **Vérification** :
> ```bash
> helm -n examen-helm list                         # exam-podinfo  …  deployed  podinfo-6.15.0  6.15.0
> kubectl -n examen-helm get deploy exam-podinfo   # READY 2/2
> helm -n examen-helm get values exam-podinfo      # replicaCount: 2
> ```
>
> **Doc à ouvrir** : « helm install » et « Using Helm » (helm.sh/docs).

#### Corrigé de la tâche 17

> [!example]- Solution
> ```bash
> kubectl get crd -o jsonpath='{range .items[?(@.spec.group=="cert-manager.io")]}{.metadata.name}{"\n"}{end}' \
>   > ~/cka/examen/t17.txt
> cat ~/cka/examen/t17.txt
> ```
>
> ```
> certificaterequests.cert-manager.io
> certificates.cert-manager.io
> clusterissuers.cert-manager.io
> issuers.cert-manager.io
> ```
>
> Le piège est le `grep`. `kubectl get crd | grep cert-manager.io` ramène aussi `challenges.acme.cert-manager.io` et `orders.acme.cert-manager.io`, dont le groupe est `acme.cert-manager.io` : six lignes au lieu de quatre, et la réponse est fausse. Le filtre doit porter sur `spec.group`, en jsonpath comme ci-dessus ou avec `kubectl get crd -o custom-columns=NOM:.metadata.name,GROUPE:.spec.group --no-headers | awk '$2=="cert-manager.io" {print $1}'`.
>
> ```yaml
> apiVersion: cert-manager.io/v1
> kind: Issuer
> metadata:
>   name: examen-issuer
>   namespace: examen-crd
> spec:
>   selfSigned: {}
> ---
> apiVersion: cert-manager.io/v1
> kind: Certificate
> metadata:
>   name: examen-cert
>   namespace: examen-crd
> spec:
>   secretName: examen-tls
>   commonName: examen.example        # facultatif : évite l'événement BadConfig (DN d'émetteur vide)
>   dnsNames:
>   - examen.example
>   issuerRef:
>     name: examen-issuer
>     kind: Issuer
>     group: cert-manager.io
> ```
>
> Un Issuer namespacé ne sert que les Certificate de son namespace, d'où `kind: Issuer` dans `issuerRef` (c'est aussi la valeur par défaut). Le contrôleur crée la clé, une CertificateRequest, la fait signer par l'émetteur autosigné et range le résultat dans le Secret `examen-tls`, de type `kubernetes.io/tls`.
>
> **Vérification** :
> ```bash
> kubectl -n examen-crd get issuer examen-issuer              # READY True
> kubectl -n examen-crd wait --for=condition=Ready certificate/examen-cert --timeout=60s
> kubectl -n examen-crd get secret examen-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
>   | openssl x509 -noout -ext subjectAltName                  # DNS:examen.example
> ```
>
> **Doc à ouvrir** : la documentation de cert-manager n'est pas autorisée à l'examen. Les CRD d'un opérateur décrivent leur schéma : `kubectl explain issuer.spec.selfSigned` et `kubectl explain certificate.spec --recursive | less` donnent les champs. Pour la liste des CRD, « JSONPath Support » (kubernetes.io).

---
