---
title: "CKA — 22. Dépanner les applications et le réseau"
description: "Une méthode couche par couche, le catalogue des états de pods et de leurs causes, les sondes, les rollouts bloqués, kubectl debug, puis le dépannage des Services, du DNS, des NetworkPolicies, des Ingress et des Gateway, mis en pratique sur dix pannes du fil rouge."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 22. Dépanner les applications et le réseau

Une tâche de dépannage d'application commence toujours par un symptôme vu de l'extérieur : « la page renvoie 502 », « le déploiement n'avance plus », « le pod redémarre en boucle ». Entre ce symptôme et sa cause, il y a une pile de couches (nom DNS, Ingress ou Gateway, Service, EndpointSlice, disponibilité des pods, conteneur, configuration, nœud) et chacune laisse des traces précises dans l'API. Ce chapitre donne une méthode pour descendre cette pile sans rien oublier, le catalogue des états et raisons qu'affiche un pod avec leurs causes et leurs remèdes, le fonctionnement des sondes et des rollouts bloqués, l'outil `kubectl debug` sous ses trois formes, puis le dépannage du réseau applicatif : Services, DNS, NetworkPolicies, Ingress et Gateway API. Il correspond à la compétence « Troubleshoot services and networking » du domaine Troubleshooting (30 %), et s'appuie sur « Manage and evaluate container output streams » ([chapitre 21](21-journaux-et-metriques.md)). Les exercices sont dix pannes réelles injectées dans le fil rouge par `lab/pannes.sh` : l'énoncé ne donne que le symptôme, comme à l'examen.

### 22.1 La méthode : du symptôme vers la cause

#### 22.1.1 Les couches

```
La pile d'une requête vers la boutique
══════════════════════════════════════

  client ── nom DNS ──▶ point d'entrée ──▶ Service ──▶ EndpointSlice ──▶ pod prêt ──▶ conteneur
            (CoreDNS,    (Ingress,          (ClusterIP,  (sélecteur,       (readiness)   (port, config,
             /etc/hosts)  Gateway,           ports,       targetPort)                     ressources)
                          NodePort, LB)      kube-proxy)
                                   │
            à chaque saut : une NetworkPolicy peut jeter le paquet (Calico)
                                   │
            sous tout cela : le nœud (kubelet, runtime, CNI) → chapitre 23
```

Deux stratégies se complètent. **Descendre** depuis le symptôme (le client, puis le point d'entrée, puis le Service…) quand l'énoncé décrit ce que voit un utilisateur. **Remonter** depuis les objets (pods, puis EndpointSlices, puis Service…) quand l'énoncé désigne un objet en échec. Dans les deux cas, on teste chaque couche isolément avant de passer à la suivante : un `curl` direct sur l'IP d'un pod écarte d'un coup DNS, Service et kube-proxy ; un `curl` sur l'IP du Service écarte DNS.

Trois questions orientent le diagnostic avant même la première commande. **Qu'est-ce qui a changé ?** `kubectl rollout history`, les âges dans `kubectl get`, les événements récents (`kubectl events`). **Quelle est l'étendue ?** Un pod, tous les pods d'un Deployment, tous les pods d'un nœud, tout le namespace, tout le cluster : chaque réponse désigne une couche différente. **Le symptôme est-il un refus ou un silence ?** C'est la question la plus rentable de ce chapitre.

#### 22.1.2 Refus ou silence

Une connexion TCP qui échoue échoue de deux façons, et elles ne disent pas la même chose.

| Ce que voit le client | Ce qui s'est passé | Causes typiques |
|---|---|---|
| refus immédiat (`connection refused`, curl code 7, nginx 502) | un système a **répondu** par un RST TCP ou un ICMP « port unreachable » | aucun processus n'écoute sur ce port du pod ; Service sans endpoint prêt (règle `REJECT` de kube-proxy) |
| attente puis échec (`timed out`, curl code 28, nginx 504) | le paquet a été **jeté** sans réponse | NetworkPolicy (Calico jette), routage cassé entre nœuds, `externalTrafficPolicy: Local` sans pod local, pare-feu |

kube-proxy, en mode iptables, installe pour un Service qui n'a aucun endpoint prêt une règle `REJECT` dans la chaîne `KUBE-SERVICES` de la table `filter` : le client reçoit un refus net. Calico, lui, applique les NetworkPolicies dans la chaîne `FORWARD` **avant** les règles de kube-proxy et **jette** ce qu'aucune politique n'autorise. Dans le fil rouge, où le chapitre 14 a posé un refus par défaut sur tout le namespace `boutique`, un même défaut peut donc produire un refus vu depuis `outils` (dont la sortie est libre) et un silence vu depuis `front` (dont la sortie est restreinte). Les exercices 22.4 et 22.5 le montrent.

> [!tip] Réflexe d'examen
> Teste avec `curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 <url>` depuis un pod, et regarde le code de sortie : `kubectl exec` affiche `command terminated with exit code 7` pour un refus, `… 28` pour un délai dépassé. Le code HTTP `000` signifie qu'aucune réponse HTTP n'est arrivée.

#### 22.1.3 La boîte à outils

| Couche | Commandes |
|---|---|
| Pod et conteneur | `kubectl get pods -o wide`, `kubectl describe pod`, `kubectl logs [-p]`, `kubectl events --for pod/…` |
| Contrôleur | `kubectl get deploy,rs`, `kubectl rollout status/history`, `kubectl describe rs` (événements `FailedCreate`) |
| Service | `kubectl get svc,endpointslices -l kubernetes.io/service-name=<svc>`, comparaison sélecteur / labels, `targetPort` / ports du conteneur |
| Réseau | `kubectl exec outils -- curl …`, `dig`, `nc -zv`, `kubectl get netpol`, `kubectl debug` (22.5) |
| Point d'entrée | `kubectl describe ingress`, journal du contrôleur, `kubectl get gateway,httproute`, conditions (22.9, 22.10) |
| Nœud | `kubectl describe node`, puis le [chapitre 23](23-depanner-le-cluster.md) |

### 22.2 Le catalogue des états d'un pod

#### 22.2.1 Phase et colonne STATUS

La **phase** d'un pod (`status.phase`) n'a que cinq valeurs : `Pending`, `Running`, `Succeeded`, `Failed`, `Unknown`. La colonne `STATUS` de `kubectl get pods` n'est pas la phase : kubectl la calcule en prenant, dans l'ordre, la raison du pod (`status.reason`, par exemple `Evicted`), puis la raison d'attente ou de fin des init containers (`Init:…`), puis celle des conteneurs (`CrashLoopBackOff`, `ErrImagePull`, `OOMKilled`, `Completed`…), et affiche `Terminating` dès que le pod a une `deletionTimestamp`. C'est donc un résumé, utile mais trompeur : un pod en `CrashLoopBackOff` est en phase `Running`. Pour la vérité, lis `kubectl get pod <p> -o yaml` : `status.phase`, `status.conditions` et `status.containerStatuses[].state` / `lastState`.

| STATUS | Phase | Où regarder | Causes principales |
|---|---|---|---|
| `Pending` (sans nœud) | Pending | événement `FailedScheduling` | ressources, taints, affinités, PVC, scheduler absent |
| `ContainerCreating` | Pending | événements `FailedMount`, `FailedCreatePodSandBox` | volume, Secret/ConfigMap de volume absent, CNI |
| `ErrImagePull`, `ImagePullBackOff` | Pending | événement `Failed` du kubelet | nom ou étiquette d'image, registre privé, quota du registre |
| `CreateContainerConfigError` | Pending | événement `Failed` | ConfigMap, Secret ou clé introuvable ; `runAsNonRoot` avec une image root |
| `RunContainerError`, `StartError` | Running | `lastState.terminated` (code 128) | commande absente de l'image, montage impossible |
| `CrashLoopBackOff` | Running | `kubectl logs -p`, `lastState` | l'application sort : erreur, option, configuration, sonde de vie |
| `OOMKilled` | Running | `lastState.terminated.reason`, code 137 | limite mémoire trop basse ou fuite |
| `Running` mais `0/1` | Running | événements `Unhealthy` | sonde de disponibilité en échec |
| `Completed` | Succeeded | — | normal pour un Job ; anormal pour un Deployment (le processus se termine) |
| `Error` | Failed (ou Running) | `lastState`, journaux | code de sortie non nul |
| `Evicted` | Failed | `status.reason`, `status.message` | pression du nœud, API d'éviction |
| `Terminating` qui dure | — | `metadata.finalizers`, état du nœud | finalizer non levé, kubelet injoignable, `preStop` long |
| `Init:N/M`, `Init:CrashLoopBackOff` | Pending | `kubectl logs -c <init>` | init container en échec |
| `SchedulingGated` | Pending | `spec.schedulingGates` | portes d'ordonnancement non levées |

#### 22.2.2 Pending

Un pod `Pending` sans `NODE` dans `kubectl get pods -o wide` n'a pas été placé. Le scheduler l'explique dans un événement `FailedScheduling` dont le message suit un format fixe :

```
0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 Insufficient memory. preemption: 0/3 nodes are available: 1 Preemption is not helpful for scheduling, 2 No preemption victims found for incoming pod.
```

La première partie compte, pour chaque raison, combien de nœuds ont été écartés pour elle (chaque nœud n'est compté qu'une fois, sous la raison du premier filtre qui l'a rejeté). La partie `preemption:` dit si évincer des pods de moindre priorité aurait aidé. Les raisons, telles qu'écrites dans le code de la 1.37 :

| Message | Filtre | Cause |
|---|---|---|
| `Insufficient cpu`, `Insufficient memory` | NodeResourcesFit | somme des `requests` > allocatable (pas la consommation, voir 21.6.3) |
| `node(s) had untolerated taint(s)` | TaintToleration | taint `NoSchedule`/`NoExecute` sans toleration ; en 1.37 le message ne cite plus la taint, lis `kubectl describe node` |
| `node(s) were unschedulable` | NodeUnschedulable | nœud cordonné |
| `node(s) didn't match Pod's node affinity/selector` | NodeAffinity | `nodeSelector` ou affinité requise sans nœud correspondant |
| `node(s) didn't match pod affinity rules`, `… anti-affinity rules` | InterPodAffinity | affinité entre pods requise |
| `node(s) didn't match pod topology spread constraints` | PodTopologySpread | `whenUnsatisfiable: DoNotSchedule` |
| `node(s) didn't have free ports for the requested pod ports` | NodePorts | `hostPort` déjà pris |
| `pod has unbound immediate PersistentVolumeClaims` | VolumeBinding | PVC `Immediate` non liée |
| `node(s) didn't match PersistentVolume's node affinity` | VolumeBinding | PV local ou CSI attaché à un autre nœud |
| `node(s) didn't find available persistent volumes to bind` | VolumeBinding | aucun PV compatible pour une PVC `WaitForFirstConsumer` |

Deux cas de `Pending` n'ont **pas** d'événement `FailedScheduling`. Le premier : aucun scheduler ne tourne, ou le pod demande un `schedulerName` qui n'existe pas ; personne n'essaie, personne ne se plaint (chapitre 23.4.5). Le second : le pod n'existe pas du tout. Un quota dépassé, une LimitRange violée ou un refus de Pod Security empêchent la **création** du pod : on ne voit aucun pod, seulement un événement `FailedCreate` sur le ReplicaSet (22.4.2).

Un pod placé mais bloqué en `ContainerCreating` a dépassé le scheduler : le problème est sur le nœud. `FailedMount` désigne un volume (ConfigMap ou Secret absent d'un volume, PVC non attachée) ; `FailedCreatePodSandBox` désigne presque toujours le CNI, avec le message du plugin (pour Calico : `plugin type="calico" failed (add): …`), voir le [chapitre 9.3](09-reseau-des-pods.md).

#### 22.2.3 ErrImagePull et ImagePullBackOff

Le kubelet demande l'image au runtime. En cas d'échec, le conteneur passe en `ErrImagePull`, puis, pendant l'attente avant l'essai suivant, en `ImagePullBackOff`. Le délai entre deux essais commence à **10 secondes** et double à chaque échec jusqu'à un plafond de **300 secondes** fixé dans le code du kubelet. Les événements racontent la séquence :

```
Normal   Pulling   spec.containers{nginx}: Pulling image "nginx:1.30.6-alpnie"
Warning  Failed    spec.containers{nginx}: Failed to pull image "nginx:1.30.6-alpnie": rpc error: code = NotFound desc = failed to pull and unpack image "docker.io/library/nginx:1.30.6-alpnie": failed to resolve reference "docker.io/library/nginx:1.30.6-alpnie": docker.io/library/nginx:1.30.6-alpnie: not found
Warning  Failed    spec.containers{nginx}: Error: ErrImagePull
Normal   BackOff   spec.containers{nginx}: Back-off pulling image "nginx:1.30.6-alpnie"
Warning  Failed    spec.containers{nginx}: Error: ImagePullBackOff
```

(Extrait de `kubectl describe pod`, colonnes `Age` et `From` omises : en 1.37, `describe` préfixe chaque message du champ concerné, ici `spec.containers{nginx}:` ; `kubectl events` affiche le message seul.)

Le message de containerd désigne la cause : `not found` (étiquette ou dépôt inexistant), `pull access denied` ou `401 Unauthorized` (registre privé : il manque un `imagePullSecrets`, chapitre 6.6), `429 Too Many Requests` (quota du registre), `no match for platform in manifest` (architecture). `InvalidImageName` signale une référence syntaxiquement fausse ; `ErrImageNeverPull`, une image absente avec `imagePullPolicy: Never`. Corriger l'image dans le contrôleur crée de nouveaux pods ; le pod en attente ne se répare pas tout seul tant que son spec reste faux.

#### 22.2.4 CrashLoopBackOff

Le conteneur démarre, puis s'arrête. Avec `restartPolicy: Always` (seule valeur permise dans un Deployment) ou `OnFailure`, le kubelet le relance avec un délai exponentiel : **10 s, 20 s, 40 s, 80 s, 160 s, puis 300 s** à chaque fois, et remet le compteur à zéro après **10 minutes** de fonctionnement sans incident. `CrashLoopBackOff` est l'état d'attente entre deux relances, mais le kubelet ne l'inscrit qu'en resynchronisant le pod : d'ici là, le conteneur reste `terminated` et STATUS affiche `Error`, parfois jusqu'à la synchronisation suivante, qui le relance (constaté dans le lab sur plusieurs pods : `Error` la plupart du temps, et des relances plus espacées que le barème ; d'autres, comme `api` à l'exercice 22.2, passent aussitôt en `CrashLoopBackOff`). Les deux affichages désignent la même boucle ; voir 21.3.2 pour la lecture des journaux dans ce cas. En 1.37, deux fonctions modifient ce barème : `KubeletCrashLoopBackOffMax` (bêta, active) permet de fixer par nœud un plafond plus bas avec le champ `crashLoopBackOff.maxContainerRestartPeriod` de la configuration du kubelet (entre `1s` et `300s`) ; `ReduceDefaultCrashLoopBackOffDecay` (alpha, inactive) ramènerait le barème à 1 s puis 60 s. Sans configuration particulière, c'est 10 s et 300 s.

La cause est dans l'instance précédente du conteneur :

```bash
kubectl -n boutique logs <pod> -p --tail=20
kubectl -n boutique get pod <pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'
```

| Code de sortie | Sens | Piste |
|---|---|---|
| 0 | le processus s'est terminé normalement | commande qui rend la main (un `echo`, un script sans boucle) dans un Deployment |
| 1, 2… | erreur de l'application | lire le journal : option inconnue, fichier de configuration, connexion refusée |
| 126 | commande non exécutable | permissions, mauvais binaire |
| 127 | commande introuvable par le shell | `sh -c` qui appelle un programme absent |
| 128 | le runtime n'a pas pu lancer le processus | raison `StartError` : exécutable absent de l'image (`exec: "xyz": executable file not found in $PATH`) |
| 137 | tué par SIGKILL (128 + 9) | `OOMKilled`, ou arrêt forcé après `terminationGracePeriodSeconds`, ou sonde de vie |
| 143 | terminé par SIGTERM (128 + 15) | arrêt demandé (suppression, sonde de vie) que l'application a respecté |

Une sonde de vie en échec produit aussi une boucle de redémarrages : les événements montrent alors `Liveness probe failed: …` suivi de `Container <c> failed liveness probe, will be restarted` (22.3).

#### 22.2.5 CreateContainerConfigError et RunContainerError

`CreateContainerConfigError` survient **avant** la création du conteneur, quand le kubelet assemble sa configuration : une variable `valueFrom` ou un `envFrom` vers une ConfigMap ou un Secret introuvable, une clé absente (`Error: couldn't find key DB_PASSWORD in Secret boutique/api-secret`), ou un `runAsNonRoot: true` avec une image qui tourne en root. Le kubelet réessaie à chaque synchronisation du pod : réparer la ConfigMap ou le Secret suffit, le pod démarre seul, sans nouveau déploiement. Une référence `optional: true` lève l'erreur.

`RunContainerError` (ou `StartError` dans `lastState`) survient **après** la création, quand le runtime lance le processus : exécutable introuvable dans l'image, `workingDir` impossible, montage en conflit. Le message de l'événement vient de runc et se termine par la cause précise.

#### 22.2.6 OOMKilled et le code 137

La limite mémoire d'un conteneur devient `memory.max` de son cgroup. Quand la consommation l'atteint et que le noyau ne peut plus récupérer de cache, il tue un processus du cgroup ; sous cgroup v2, le kubelet active `memory.oom.group`, si bien que **tout le conteneur** est tué (champ `singleProcessOOMKill` du kubelet, `false` par défaut sous cgroup v2). Le statut garde la trace :

```
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
```

`OOMKilled` est la seule raison qui prouve un dépassement de la limite du conteneur ; un code 137 avec la raison `Error` est en principe un SIGKILL d'une autre origine. Une exception dans le lab : sur un poste dont la limite inotify n'a pas été relevée, containerd ne parvient pas à surveiller les événements OOM de certains conteneurs et affiche `Error`, code 137, pour un vrai OOM (encadré de la section 4.7) ; `sudo dmesg` dans le nœud tranche (`Memory cgroup out of memory: Killed process …`). Le remède est de relever la limite (et souvent la request), ou de corriger l'application. Le redimensionnement en place (chapitre 4.12) évite de recréer le pod quand la politique `resizePolicy` le permet. Un OOM du nœud entier, lui, est une autre affaire : le kubelet l'annonce par un événement `SystemOOM` sur le nœud.

#### 22.2.7 Evicted, Terminating et Completed

Un pod **évincé par le kubelet** (pression mémoire, disque ou PID du nœud) passe en phase `Failed` avec `status.reason: Evicted` et un message du type `The node was low on resource: memory. …`. Il reste dans l'API, inerte, jusqu'à sa suppression ou jusqu'au ramasse-miettes de pods du controller-manager, qui ne se déclenche qu'au-delà de 12 500 pods terminés (`--terminated-pod-gc-threshold`). Le contrôleur, lui, a déjà créé un remplaçant. Pour nettoyer : `kubectl delete pods --field-selector=status.phase=Failed -n <ns>`. Les deux autres formes d'éviction (API d'éviction utilisée par `kubectl drain`, qui respecte les PodDisruptionBudgets, et taint `NoExecute`, qui ne les respecte pas) suppriment les pods au lieu de les laisser en `Failed` (chapitre 8, et 23.3 pour les taints).

> [!info] minikube ≠ examen
> Les nœuds du lab ont l'éviction pour manque de disque désactivée (`evictionHard` à `0%` pour `nodefs` et `imagefs`) et annoncent la mémoire de l'hôte : tu n'y verras pas d'éviction par pression du kubelet. Sur un nœud kubeadm, les seuils par défaut s'appliquent (`memory.available` 100Mi, `nodefs.available` 10 %, `nodefs.inodesFree` 5 %, `imagefs.available` 15 %).

Un pod **bloqué en `Terminating`** a une `deletionTimestamp` mais n'est pas retiré de l'API. Trois causes : un **finalizer** que personne ne lève (`kubectl get pod <p> -o jsonpath='{.metadata.finalizers}'`) ; un **kubelet injoignable**, qui ne peut pas confirmer l'arrêt des conteneurs (nœud `NotReady`, chapitre 23.2) ; un `preStop` ou une application qui ignore SIGTERM, auquel cas le pod disparaît au bout de `terminationGracePeriodSeconds` (30 s par défaut). On lève un finalizer orphelin par `kubectl patch pod <p> --type=merge -p '{"metadata":{"finalizers":null}}'`. La suppression forcée, `kubectl delete pod <p> --grace-period=0 --force`, retire l'objet de l'API **sans** attendre le kubelet ; kubectl le rappelle par `Warning: Immediate deletion does not wait for confirmation that the running resource has been terminated. The resource may continue to run on the cluster indefinitely.` Sur un pod de StatefulSet dont le nœud est injoignable, c'est dangereux : le contrôleur recrée aussitôt un pod du même nom ailleurs, alors que l'ancien tourne peut-être encore et écrit sur le même volume.

`Completed` (phase `Succeeded`) est l'état normal d'un pod de Job. Dans un Deployment, il signale une commande qui rend la main : le kubelet la relance, et le pod finit en `CrashLoopBackOff` avec un code de sortie 0.

### 22.3 Les sondes en échec

Le kubelet exécute les sondes depuis le nœud, dans l'espace réseau de l'hôte : les NetworkPolicies ne les bloquent pas (Calico laisse passer le trafic de l'hôte vers ses pods). Leurs paramètres par défaut sont `initialDelaySeconds: 0`, `periodSeconds: 10`, `timeoutSeconds: 1`, `successThreshold: 1`, `failureThreshold: 3`. Une sonde HTTP réussit pour tout code de 200 à 399 ; une sonde TCP, si la connexion s'établit ; une sonde `exec`, si la commande sort avec 0.

| Sonde en échec | Conséquence | Indice |
|---|---|---|
| readiness | condition `Ready=False`, pod retiré des EndpointSlices (`ready: false`), plus de trafic ; le conteneur continue | `READY 0/1`, `STATUS Running`, événements `Readiness probe failed` |
| liveness | conteneur tué (SIGTERM puis SIGKILL) et relancé | `RESTARTS` qui grimpe, `Liveness probe failed`, puis `failed liveness probe, will be restarted` |
| startup | tant qu'elle n'a pas réussi, les deux autres sont suspendues ; après `failureThreshold` échecs, le conteneur est tué | redémarrages au démarrage seulement |

Le message de l'événement `Unhealthy` reprend la sortie de la sonde et suffit au diagnostic : `HTTP probe failed with statuscode: 404` (mauvais chemin), `Get "http://10.244.195.201:8081/hostname": dial tcp 10.244.195.201:8081: connect: connection refused` (mauvais port, ou application pas encore à l'écoute), `context deadline exceeded (Client.Timeout exceeded while awaiting headers)` (réponse plus lente que `timeoutSeconds`). Compare toujours le port et le chemin de la sonde à ce qu'écoute réellement le conteneur : un port nommé (`port: http`) doit exister dans `ports[].name` du même conteneur.

### 22.4 Les rollouts bloqués

#### 22.4.1 Le mécanisme

Une mise à jour de Deployment crée un nouveau ReplicaSet et fait glisser les réplicas de l'ancien vers le nouveau, dans les bornes de `maxSurge` et `maxUnavailable` (chapitre 5.4). Si les nouveaux pods ne deviennent jamais disponibles, le glissement s'arrête : avec `maxUnavailable: 0`, les anciens pods restent tous en place et le service continue, ce qui rend la panne discrète. Le contrôleur mesure la progression : faute de progrès pendant `progressDeadlineSeconds` (600 s par défaut), il pose la condition `Progressing=False` avec la raison `ProgressDeadlineExceeded`. Il ne fait rien d'autre : pas de retour arrière automatique.

```bash
kubectl -n boutique rollout status deployment/front --timeout=30s
# Waiting for deployment "front" rollout to finish: 1 out of 3 new replicas have been updated...
# error: timed out waiting for the condition
# … après 600 s sans progrès :
# error: deployment "front" exceeded its progress deadline
kubectl -n boutique get deploy front -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
kubectl -n boutique rollout history deployment/front
kubectl -n boutique rollout undo deployment/front
```

`rollout history --revision=N` affiche le gabarit d'une révision ; comparer deux révisions avec `diff` montre exactement ce qui a changé. `rollout undo` remet le gabarit de la révision précédente (ou `--to-revision=N`), ce qui reprend un ReplicaSet existant au lieu d'en créer un.

Un **StatefulSet** se comporte autrement. Avec la politique `OrderedReady` par défaut, si le gabarit mis à jour produit un pod qui n'est jamais `Running` et prêt, le contrôleur s'arrête et attend ce pod. La documentation le dit explicitement (« Forced rollback ») : revenir à un bon gabarit **ne suffit pas**, le contrôleur continue d'attendre le pod cassé ; il faut aussi **supprimer ce pod** pour qu'il soit recréé avec le gabarit corrigé. L'exercice 22.10 le met en scène.

#### 22.4.2 Quand le contrôleur ne peut pas créer de pod

Les contrôles d'admission s'appliquent à la création de chaque pod, pas au gabarit du Deployment : un gabarit accepté peut produire des pods refusés. Le symptôme est alors l'absence de pod, une condition `ReplicaFailure=True` de raison `FailedCreate` sur le Deployment, et un événement `FailedCreate` sur le ReplicaSet dont le message nomme le contrôle qui a refusé :

| Message de `FailedCreate` | Contrôle | Remède |
|---|---|---|
| `maximum cpu usage per Container is 1, but limit is 2` | LimitRange (`max`) | ramener requests et limits sous le maximum |
| `minimum memory usage per Container is …` | LimitRange (`min`) | relever |
| `exceeded quota: boutique-quota, requested: requests.cpu=…, used: …, limited: requests.cpu=4` | ResourceQuota | réduire, ou libérer du quota |
| `failed quota: boutique-quota: must specify limits.cpu for: nginx; requests.cpu for: nginx` | ResourceQuota sans LimitRange | déclarer les ressources |
| `violates PodSecurity "baseline:latest": …` | Pod Security Admission | retirer le privilège demandé |
| `error looking up service account …` | ServiceAccount | créer le ServiceAccount |

L'ordre compte : la LimitRange (`LimitRanger`) vérifie avant Pod Security, qui vérifie avant le quota (`ResourceQuota` est toujours le dernier). Un pod qui viole la LimitRange **et** le quota n'affiche que le message de la LimitRange. Quand le gabarit lui-même est incohérent (request supérieure à la limit), c'est la validation de l'API qui refuse la modification du Deployment ou du StatefulSet, avant tout contrôle d'admission : `spec.template.spec.containers[0].resources.requests: Invalid value: "64Mi": must be less than or equal to memory limit of 8Mi`.

### 22.5 `kubectl debug`

`kubectl debug` a trois usages : ajouter un **conteneur éphémère** à un pod qui tourne, créer une **copie modifiée** d'un pod, ouvrir un pod privilégié sur un **nœud**. Le chapitre 4.11 a présenté le conteneur éphémère ; voici le détail.

#### 22.5.1 Le conteneur éphémère

```bash
kubectl -n boutique debug -it <pod> --image=nicolaka/netshoot:v0.16 --target=<conteneur> --profile=baseline
```

kubectl ajoute un élément à `spec.ephemeralContainers` par la sous-ressource `pods/ephemeralcontainers` (droit RBAC `patch` sur cette sous-ressource), le kubelet le démarre dans le pod existant, et kubectl s'y attache. Sans `-c`, le nom est tiré au hasard et annoncé : `Defaulting debug container name to debugger-8xzrl.` Le conteneur partage l'espace réseau du pod (même IP, mêmes ports, **mêmes NetworkPolicies**) et ses volumes s'il les monte ; avec `--target`, il rejoint aussi l'espace de processus du conteneur visé, dont le processus principal devient le PID 1 visible par `ps`, et dont le système de fichiers se lit par `/proc/1/root`. C'est la façon de déboguer une image *distroless* sans shell : `kubectl exec` y échoue (`exec: "sh": executable file not found in $PATH`), le conteneur éphémère apporte ses propres outils.

Ses limites sont fixées par l'API : pas de ports, pas de sondes, pas de ressources (il n'entre pas dans le calcul du quota), jamais relancé, et **impossible à retirer** : il reste dans le spec, terminé, jusqu'à la suppression du pod. Les pods statiques n'acceptent pas de conteneurs éphémères ; pour etcd ou l'API server, on passe par le nœud (22.5.4 et chapitre 23.4.3).

#### 22.5.2 Les profils

Le profil ajuste le `securityContext` et le pod selon l'usage. Depuis la 1.36, le profil par défaut est `general` ; `legacy`, l'ancien défaut, est déprécié (retrait prévu en 1.39). La page « Debug Running Pods » de la documentation 1.37 dit encore que `legacy` est le défaut : l'aide de `kubectl debug` 1.37 et son code disent `general`, et ce sont eux qui font foi.

| Profil | Conteneur éphémère | Copie de pod (`--copy-to`) | Nœud (`node/…`) |
|---|---|---|---|
| `general` (défaut) | ajoute `SYS_PTRACE` | ajoute `SYS_PTRACE`, partage des processus, retire labels, annotations, sondes, init containers | racine du nœud en `/host`, espaces réseau, PID et IPC de l'hôte |
| `baseline` | `securityContext` vidé, aucune capacité ajoutée | idem + partage des processus, retraits | `securityContext` vidé, pas de `/host` ni d'espaces de l'hôte |
| `restricted` | non-root, `drop: ALL`, pas d'escalade, seccomp `RuntimeDefault` | idem + partage, retraits | idem, sans espaces de l'hôte |
| `netadmin` | ajoute `NET_ADMIN` et `NET_RAW` | idem + partage, retraits | idem + espaces de l'hôte |
| `sysadmin` | `privileged: true` | idem + partage, retraits | privilégié + espaces de l'hôte + `/host` |

> [!danger] Pod Security et le profil `general`
> Depuis le chapitre 8, le namespace `boutique` applique Pod Security au niveau `baseline` (`enforce=baseline`). Ce niveau interdit d'ajouter une capacité hors de la liste par défaut, et `SYS_PTRACE` n'y figure pas. Un `kubectl debug` sans `--profile` dans `boutique` est donc **refusé** par l'admission, avec un message du type `violates PodSecurity "baseline:latest": non-default capabilities (container "debugger-…" must not include "SYS_PTRACE" in securityContext.capabilities.add)`. Passe `--profile=baseline` (ou `restricted`), ou débogue depuis le nœud. Le même raisonnement vaut à l'examen dans tout namespace étiqueté par Pod Security.

#### 22.5.3 La copie de pod

```bash
kubectl -n boutique debug <pod> -it --copy-to=<pod>-copie --container=<c> --profile=baseline -- sh
kubectl -n boutique debug <pod> --copy-to=<pod>-copie --set-image='*=busybox:1.37.0' --profile=baseline
```

`--copy-to` crée un **nouveau pod** à partir du spec de l'original, sans toucher à l'original (sauf avec `--replace`, qui le supprime). C'est l'outil pour un conteneur qui plante au démarrage : `--container=<c> -- sh` remplace sa commande par un shell, ce qui permet d'inspecter le système de fichiers et de lancer la commande d'origine à la main. `--set-image` change des images (même syntaxe que `kubectl set image`), `--share-processes` (vrai par défaut avec `--copy-to`) partage l'espace de processus, `--same-node` place la copie sur le nœud de l'original, `--keep-labels`, `--keep-annotations`, `--keep-liveness`, `--keep-readiness`, `--keep-startup` et `--keep-init-containers` gardent ce que le profil retirerait.

Le profil, le partage des processus et ces retraits ne s'appliquent que si la copie reçoit un conteneur de débogage (`--image`) ou si la commande d'un conteneur est remplacée (`--container=<c> -- …`). Une copie faite avec le seul `--set-image`, comme dans la seconde commande ci-dessus, garde tels quels les labels et les sondes de l'original. Si l'original appartient à un ReplicaSet, celui-ci adopte la copie, se retrouve avec un pod de trop et la supprime dans la seconde : le ReplicaSet porte alors l'événement `SuccessfulDelete … Deleted pod: <copie>` (constaté avec un pod `api`). Ajoute `--image` ou `--container=… -- sh` pour que le profil s'applique et retire les labels.

Dans les autres cas, la copie n'a **pas les labels** de l'original (sauf `--keep-labels`) : aucun Service ne l'inclut, et les NetworkPolicies qui sélectionnent par label (`tier=web`, `app=api`) ne s'y appliquent pas ; seules s'appliquent celles qui sélectionnent tous les pods (`refus-par-defaut`, `autorise-dns`). Une copie de `api` ne joint donc plus `redis`. N'oublie pas de la supprimer : c'est un pod nu.

#### 22.5.4 Le débogage d'un nœud

```bash
kubectl debug node/cka-m02 -it --image=busybox:1.37.0 -n default
```

Le pod `node-debugger-cka-m02-xxxxx` est créé sur le nœud avec le profil `general` : espaces réseau, PID et IPC de l'hôte, racine du nœud montée en `/host` ; `chroot /host` donne un shell presque équivalent à une connexion SSH. Il est créé dans le namespace courant : choisis-en un sans Pod Security restrictive (`-n default`), sinon `baseline` le refuse (volume `hostPath`, espaces de l'hôte). En sortant, le pod reste `Completed` et doit être supprimé à la main. Le [chapitre 23.4.3](23-depanner-le-cluster.md) en rappelle la limite : il crée un pod, donc il ne remplace pas SSH quand l'API ne répond plus.

#### 22.5.5 Les autres outils

`kubectl exec <pod> -- <commande>` exige le séparateur `--` depuis la 1.35. `kubectl port-forward pod/<p> 8080:8080` (ou `svc/<s>`) ouvre un tunnel depuis ton poste vers un pod : utile pour tester l'application sans Service ni Ingress, il ne passe ni par kube-proxy ni par les NetworkPolicies. `kubectl cp` exige `tar` dans le conteneur.

### 22.6 Dépanner un Service

#### 22.6.1 La chaîne

```
Service api (ClusterIP 10.105.37.214, port 8080, targetPort http, sélecteur app=api)
     │
     │ contrôleur EndpointSlice (kube-controller-manager)
     ▼
EndpointSlice api-xxxxx : adresses des pods app=api, port résolu (http → 8080),
                          conditions ready/serving/terminating par adresse
     │
     │ kube-proxy (chaque nœud) : DNAT ClusterIP:8080 → IP_pod:8080 pour les adresses prêtes ;
     │                            REJECT si aucune n'est prête
     ▼
pod api prêt, processus à l'écoute sur 8080
```

Chaque flèche est un point de rupture, et chacun se teste :

```bash
kubectl -n boutique get svc api -o wide                                    # type, IP, ports, sélecteur
kubectl -n boutique get pods -l app=api -o wide --show-labels              # le sélecteur trouve-t-il des pods ?
kubectl -n boutique get endpointslices -l kubernetes.io/service-name=api   # adresses et port résolu
kubectl -n boutique get endpointslices -l kubernetes.io/service-name=api \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'
kubectl -n boutique exec outils -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://<IP_pod>:8080/hostname
kubectl -n boutique exec outils -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://api:8080/hostname
```

| Constat | Cause |
|---|---|
| aucun pod ne porte les labels du sélecteur | sélecteur faux (faute de frappe, label renommé) |
| EndpointSlice avec des adresses mais `ready=false` | sondes de disponibilité en échec (22.3) |
| EndpointSlice prête, port inattendu dans la colonne `PORTS` | `targetPort` faux, ou port nommé absent du conteneur |
| pod joignable en direct, Service injoignable | kube-proxy (chapitre 23.6), ou NetworkPolicy sur le chemin |
| Service joignable par IP, pas par nom | DNS (22.7) |
| NodePort injoignable de l'extérieur, ClusterIP joignable | `externalTrafficPolicy: Local` sans pod local, pare-feu, politique d'entrée qui ignore le réseau des nœuds |

L'API `Endpoints` existe encore, mais sa lecture est dépréciée depuis la 1.33 (`Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice`) : lis les EndpointSlices, qui portent les conditions par adresse. Un Service `ExternalName` n'a ni IP ni EndpointSlice : ce n'est qu'un CNAME servi par CoreDNS. Un Service headless (`clusterIP: None`) n'a pas de règle kube-proxy : le DNS renvoie directement les IP des pods prêts.

#### 22.6.2 Ce que fait kube-proxy

Sur un nœud, les règles se lisent avec `iptables-save` (chapitre 10.5) :

```bash
minikube -p cka ssh -n cka-m02
sudo iptables-save -t nat | grep 'boutique/api'
sudo iptables-save -t filter | grep 'boutique/api'
```

Un Service sain apparaît dans la table `nat` (chaînes `KUBE-SVC-…` puis une `KUBE-SEP-…` par adresse prête, avec le `DNAT`). Un Service sans adresse prête n'apparaît que dans la table `filter`, avec un commentaire `has no endpoints` et la cible `REJECT`. Si un Service récent n'apparaît nulle part alors que ses EndpointSlices sont prêtes, kube-proxy ne fait plus son travail sur ce nœud : c'est une panne de composant (exercice 23.7).

### 22.7 Dépanner le DNS

La résolution d'un nom de Service suit le `resolv.conf` du pod (`nameserver 10.96.0.10`, domaines de recherche `<ns>.svc.cluster.local svc.cluster.local cluster.local`, `options ndots:5`, chapitre 11.6). La démarche :

1. **Depuis quel pod ?** Teste depuis un pod soumis aux mêmes politiques que celui qui échoue. `outils` a une sortie libre (`outils-sortie`) : s'il résout et que `front` ne résout pas, le problème est une NetworkPolicy, pas CoreDNS.
2. **Le message.** `NXDOMAIN` : le serveur a répondu que le nom n'existe pas (faute de frappe, mauvais namespace, Service absent). `SERVFAIL` : CoreDNS n'a pas pu résoudre (amont injoignable pour un nom externe). `connection timed out; no servers could be reached` : aucune réponse, donc paquets jetés (NetworkPolicy) ou pods CoreDNS présents mais muets. Un CoreDNS absent ou sans pod prêt donne au contraire un **refus** immédiat (`communications error to 10.96.0.10#53: connection refused` avec `dig`) pour un client à sortie libre : kube-proxy rejette le trafic d'un Service sans endpoint (exercices 11.6 et 23.6).
3. **CoreDNS est-il là ?** `kubectl -n kube-system get pods -l k8s-app=kube-dns`, `kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns`, journal de CoreDNS.
4. **Les politiques de sortie.** Le DNS passe par UDP **et** TCP 53, vers les pods `k8s-app=kube-dns` de `kube-system`. Le port d'une règle de NetworkPolicy est celui du **pod de destination après DNAT** : pour CoreDNS, 53 côté Service comme côté conteneur.

```bash
kubectl -n boutique exec deploy/front -- nslookup -timeout=3 api.boutique.svc.cluster.local
kubectl -n boutique exec outils -- dig +short api.boutique.svc.cluster.local
kubectl -n boutique exec outils -- dig @10.96.0.10 +time=2 +tries=1 kubernetes.default.svc.cluster.local
kubectl -n boutique exec outils -- cat /etc/resolv.conf
```

L'image `nginx:1.30.6-alpine` de `front` contient le `nslookup` de busybox, ce qui permet de tester depuis le pod réellement concerné sans conteneur éphémère.

### 22.8 Dépanner les NetworkPolicies

Les NetworkPolicies s'additionnent (union des règles autorisantes) et ne s'appliquent qu'aux pods qu'elles sélectionnent, direction par direction (chapitre 14.2). Une connexion de A vers B doit être autorisée **deux fois** : en sortie de A, par une politique qui sélectionne A, et en entrée de B, par une politique qui sélectionne B. Le diagnostic en découle :

```bash
kubectl -n boutique get networkpolicy
kubectl -n boutique describe networkpolicy web-entree
kubectl -n boutique get pod <A> --show-labels          # quelles politiques sélectionnent A ?
```

Les erreurs classiques : la politique de sortie oubliée (seule l'entrée de B a été ouverte) ; le DNS oublié dans un namespace en refus par défaut ; le **port** de la règle confondu avec le port du Service (la règle compare le port du pod, après DNAT : un Service `80 → targetPort 8080` exige une règle sur 8080) ; le piège ET/OU du YAML (`- namespaceSelector` et `podSelector` dans le même élément de liste, ou dans deux éléments) ; un `ipBlock` qui ne couvre pas l'adresse source réellement vue par la politique pour le trafic NodePort ou LoadBalancer : sous Calico en IPIP, l'adresse du client si le pod tourne sur le nœud d'entrée, l'adresse de **tunnel** du nœud d'entrée s'il tourne ailleurs, jamais l'adresse du nœud sur le réseau des nœuds (14.8).

Pour tester avec les politiques **exactes** d'un pod, un conteneur éphémère dans ce pod est l'outil idéal : il partage son espace réseau. Pour confirmer qu'une politique est en cause, une politique temporaire qui autorise tout pour le pod concerné, appliquée puis retirée, tranche en quelques secondes ; Calico applique les changements de politique presque instantanément. Avec Calico, un trafic refusé est **jeté** : le symptôme est toujours un délai dépassé, jamais un refus.

### 22.9 Dépanner un Ingress

```
client ── boutique.example ──▶ 192.168.49.2:443 (hostPort du contrôleur ingress-nginx, nœud cka)
            │
            ▼  règle de l'Ingress boutique : hôte + chemin (pathType Prefix)
         Service front:80 ──▶ EndpointSlices ──▶ IP_pod:80   (le contrôleur parle aux pods en direct)
```

Le contrôleur ingress-nginx ne passe pas par l'IP du Service : il lit les EndpointSlices et envoie les requêtes aux pods, depuis son propre pod (namespace `ingress-nginx`), ce qui compte pour les NetworkPolicies (`web-entree` l'autorise sur le port 80). Les codes de retour pointent la couche :

| Code | Signification côté ingress-nginx |
|---|---|
| 404 | aucune règle ne correspond à l'hôte ou au chemin (le backend par défaut répond) |
| 308 | redirection vers HTTPS : la section `tls` couvre cet hôte |
| 503 | le Service visé n'a aucun endpoint prêt, ou n'existe pas |
| 502 | le pod a refusé la connexion (rien n'écoute sur le port résolu) |
| 504 | aucune réponse dans le délai (paquets jetés par une politique, pod figé) |

```bash
kubectl -n boutique get ingress boutique                  # colonne ADDRESS renseignée ?
kubectl -n boutique describe ingress boutique             # règles, backends et leurs adresses
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=20
curl -sk --resolve boutique.example:443:$(minikube -p cka ip) https://boutique.example/ -o /dev/null -w '%{http_code}\n'
```

> [!info] minikube ≠ examen
> Sur le lab, le contrôleur est celui de l'addon `ingress` (ingress-nginx v1.15.1, projet retiré le 24 mars 2026 mais toujours fonctionnel) : un seul réplica, épinglé sur `cka`, qui publie les ports 80 et 443 en `hostPort` ; d'où `--resolve …:$(minikube -p cka ip)`. Une requête envoyée à `cka-m02` sur le port 80 n'aboutit pas, faute de `hostPort` sur ce nœud. À l'examen, le contrôleur, sa classe et son exposition (souvent un Service `NodePort`) sont fixés par l'environnement : lis `kubectl get ingressclass` et `kubectl get svc -A | grep -i ingress` avant de tester.

Un certificat servi qui s'appelle `Kubernetes Ingress Controller Fake Certificate` signale un Secret TLS introuvable, d'un mauvais type ou dans un autre namespace que l'Ingress (`curl -vk … 2>&1 | grep subject`). Un Ingress sans `ingressClassName` n'est pris en charge que s'il existe une classe par défaut (le contrôleur de l'addon l'est). Le [chapitre 12](12-ingress.md) détaille ces objets.

### 22.10 Dépanner une Gateway

Gateway API inscrit son diagnostic dans les `status`, à chaque niveau. On les lit de haut en bas :

```bash
kubectl get gatewayclass eg                                    # ACCEPTED=True
kubectl -n boutique get gateway boutique-gw                    # PROGRAMMED=True, ADDRESS
kubectl -n boutique get httproute
kubectl -n boutique get httproute api -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
```

| Objet | Condition | Raisons d'échec (v1.6) |
|---|---|---|
| GatewayClass | `Accepted` | contrôleur absent : condition jamais posée ; `InvalidParameters` |
| Gateway | `Accepted`, `Programmed` | `ListenersNotValid`, `Invalid`, `AddressNotAssigned` (pas d'adresse : MetalLB, quota de LB), `Pending` |
| listener (`status.listeners[]`) | `Accepted`, `ResolvedRefs`, `Programmed`, `Conflicted` | `InvalidCertificateRef` (Secret TLS absent ou invalide), `RefNotPermitted` (Secret d'un autre namespace sans ReferenceGrant), `PortUnavailable`, `HostnameConflict` |
| HTTPRoute (`status.parents[]`) | `Accepted` | `NotAllowedByListeners` (`allowedRoutes`), `NoMatchingListenerHostname`, `NoMatchingParent` (`sectionName` faux) |
| HTTPRoute | `ResolvedRefs` | `BackendNotFound`, `RefNotPermitted` (backend d'un autre namespace sans ReferenceGrant), `InvalidKind` |

Une route dont un backend est invalide **reste acceptée** : la spécification impose de répondre **500** aux requêtes destinées à ce backend (au prorata des poids s'il y en a plusieurs). Un backend valide mais sans endpoint prêt donne **503** avec Envoy (`no healthy upstream`). Un hôte que ne couvre aucune route donne **404**. Envoy Gateway crée, dans `envoy-gateway-system`, un Deployment et un Service `LoadBalancer` par Gateway, étiquetés `gateway.envoyproxy.io/owning-gateway-name` et `…-namespace` ; leurs journaux et leurs événements complètent les conditions. L'adresse se lit toujours dans `.status.addresses[0].value`, jamais en dur. Le [chapitre 13](13-gateway-api.md) détaille ces objets.

### 22.11 Pièges courants

```
Piège 1 : Réparer le pod au lieu du contrôleur
══════════════════════════════════════════════
  MAUVAIS  : kubectl -n boutique edit pod front-5b7f9c6d48-x7p2k  (corriger l'image)
  SYMPTÔME : le pod est remplacé, ou la modification refusée ; la panne revient.
  BON      : corriger le Deployment (set image, rollout undo) : le gabarit fait foi.

Piège 2 : Lire les journaux d'un ancien pod pendant un rollout bloqué
═════════════════════════════════════════════════════════════════════
  MAUVAIS  : kubectl -n boutique logs deploy/api
  BON      : nommer le pod en échec, avec -p s'il redémarre.

Piège 3 : Tester un Service depuis un pod qui n'a pas les mêmes politiques
══════════════════════════════════════════════════════════════════════════
  MAUVAIS  : « depuis outils ça marche, donc le réseau est bon »
  CAUSE    : outils a une sortie libre ; front non.
  BON      : tester depuis le pod concerné (exec, ou conteneur éphémère).

Piège 4 : Confondre port du Service et port du pod dans une NetworkPolicy
═════════════════════════════════════════════════════════════════════════
  SYMPTÔME : délai dépassé alors que la règle « ouvre le port du Service ».
  BON      : la règle porte sur le port du conteneur, après DNAT.

Piège 5 : Corriger le gabarit d'un StatefulSet sans supprimer le pod cassé
══════════════════════════════════════════════════════════════════════════
  SYMPTÔME : rollout status attend indéfiniment ; le pod garde l'ancien gabarit.
  BON      : après correction, kubectl -n boutique delete pod redis-0.

Piège 6 : kubectl debug sans profil dans un namespace baseline
══════════════════════════════════════════════════════════════
  SYMPTÔME : refus PodSecurity, SYS_PTRACE interdit.
  BON      : --profile=baseline (ou restricted).

Piège 7 : Chercher le pod d'un ReplicaSet bloqué par l'admission
════════════════════════════════════════════════════════════════
  SYMPTÔME : aucun pod, aucun FailedScheduling.
  BON      : kubectl describe rs → FailedCreate : le message nomme le contrôle.

Piège 8 : Supprimer de force un pod de StatefulSet sur un nœud injoignable
══════════════════════════════════════════════════════════════════════════
  RISQUE   : deux pods de même identité écrivent sur le même volume.
  BON      : rétablir le nœud, ou s'assurer qu'il est vraiment arrêté.
```

> [!summary] À retenir
> - Descendre la pile (DNS, point d'entrée, Service, EndpointSlice, readiness, conteneur) en testant chaque couche isolément ; distinguer refus (quelqu'un répond : rien n'écoute, Service sans endpoint) et silence (paquet jeté : NetworkPolicy).
> - STATUS n'est pas la phase : lire `state`, `lastState`, `conditions` et les événements. `Pending` sans `FailedScheduling` = pas de scheduler ; pas de pod du tout = refus d'admission (`FailedCreate` sur le ReplicaSet).
> - Délais : tirage d'image et redémarrages de 10 s à 300 s par doublement ; remise à zéro des redémarrages après 10 minutes sans incident ; `progressDeadlineSeconds` 600.
> - `CreateContainerConfigError` = ConfigMap, Secret ou clé introuvable : réparer la ressource suffit. `OOMKilled` + 137 = limite mémoire. 128 = exécutable absent.
> - Un rollout bloqué se lit dans `rollout status`, les conditions et `rollout history` ; `rollout undo` répare un gabarit fautif. StatefulSet : corriger puis supprimer le pod cassé.
> - `kubectl debug` : conteneur éphémère (`--target`, mêmes réseau et politiques que le pod), copie (`--copy-to`, sans labels dès qu'elle reçoit un conteneur de débogage ou une nouvelle commande), nœud (`node/…`, `/host`) ; profil `general` par défaut depuis 1.36, refusé par un namespace `baseline` : `--profile=baseline`.
> - Service : sélecteur ↔ labels, EndpointSlice prête et port résolu, `targetPort` ↔ conteneur ; NetworkPolicy : sortie de la source ET entrée de la destination, ports après DNAT, DNS en UDP et TCP 53.
> - Ingress : 404 pas de règle, 503 pas d'endpoint, 502 refus, 504 silence. Gateway : conditions `Accepted`, `Programmed`, `ResolvedRefs` ; backend invalide = 500.

### 22.12 Exercices

Les exercices 22.1 à 22.10 reprennent les pannes 01 à 10. Chacune s'injecte depuis l'instantané I4, ou depuis l'état laissé par la panne précédente une fois réparée et vérifiée, en lançant depuis le dossier du cours `lab/pannes.sh casser NN`. Diagnostique et répare comme à l'examen, sans lire le script, puis contrôle avec `lab/pannes.sh verifier NN`. Si une réparation tourne mal, `lab/restaurer.sh I4` remet tout en ordre. Les exercices 22.11 et 22.12 se font sans script.

Pour les tests HTTP depuis l'hôte, définis une fois : `IP=$(minikube -p cka ip)`.

#### Exercice 22.1 — Panne 01 : la nouvelle version ne se déploie pas

**Point de départ** : instantané I4.

Lance `lab/pannes.sh casser 01`. L'équipe signale qu'une nouvelle version de `front` a été poussée il y a quelques minutes, mais que le déploiement n'avance pas ; le site, lui, répond toujours. Trouve la cause, remets `front` sur l'image `nginx:1.30.6-alpine` et assure-toi que le déploiement se termine.

> [!example]- Solution
> ```bash
> kubectl -n boutique get deploy front
> kubectl -n boutique get pods -l app=front
> ```
>
> ```
> NAME    READY   UP-TO-DATE   AVAILABLE   AGE
> front   3/3     1            3           3h
>
> NAME                     READY   STATUS             RESTARTS   AGE
> front-5b7f9c6d48-x7p2k   0/1     ImagePullBackOff   0          2m
> front-7c6d9b8f5d-k2x7q   1/1     Running            0          3h
> front-7c6d9b8f5d-m8w4r   1/1     Running            0          3h
> front-7c6d9b8f5d-t9h2n   1/1     Running            0          3h
> ```
>
> Un seul nouveau pod (`UP-TO-DATE 1`) : `maxSurge: 1` autorise un pod de plus, `maxUnavailable: 0` interdit de retirer un ancien tant que le nouveau n'est pas disponible. Les trois anciens servent toujours, d'où un site intact. Les événements du nouveau pod donnent la cause :
>
> ```bash
> kubectl -n boutique events --for pod/front-5b7f9c6d48-x7p2k --types=Warning
> ```
>
> ```
> LAST SEEN   TYPE      REASON   OBJECT                       MESSAGE
> 98s         Warning   Failed   Pod/front-5b7f9c6d48-x7p2k   Failed to pull image "nginx:1.30.6-alpnie": rpc error: code = NotFound desc = failed to pull and unpack image "docker.io/library/nginx:1.30.6-alpnie": failed to resolve reference "docker.io/library/nginx:1.30.6-alpnie": docker.io/library/nginx:1.30.6-alpnie: not found
> 98s         Warning   Failed   Pod/front-5b7f9c6d48-x7p2k   Error: ErrImagePull
> 71s         Warning   Failed   Pod/front-5b7f9c6d48-x7p2k   Error: ImagePullBackOff
> ```
>
> L'étiquette `1.30.6-alpnie` n'existe pas. On corrige le gabarit, pas le pod, en revenant à la révision précédente ou en remettant la bonne image :
>
> ```bash
> kubectl -n boutique rollout history deployment/front
> kubectl -n boutique rollout undo deployment/front
> # équivalent : kubectl -n boutique set image deployment/front nginx=nginx:1.30.6-alpine
> kubectl -n boutique rollout status deployment/front --timeout=120s
> ```
>
> `rollout undo` reprend l'ancien ReplicaSet, qui a déjà ses trois pods : le pod fautif est supprimé et le rollout se termine aussitôt. Sans intervention, la condition `Progressing` serait passée à `False` (`ProgressDeadlineExceeded`) après 600 s, sans autre effet.
>
> **Vérification** : `lab/pannes.sh verifier 01` affiche `panne 01 réparée proprement` ; `kubectl -n boutique get deploy front -o jsonpath='{.spec.template.spec.containers[0].image}'` affiche `nginx:1.30.6-alpine`.

#### Exercice 22.2 — Panne 02 : un pod qui redémarre en boucle

**Point de départ** : exercice 22.1, ou instantané I4.

Lance `lab/pannes.sh casser 02`. Un pod de `api` redémarre en boucle. Trouve pourquoi, à partir des journaux, et répare sans recréer le Deployment.

> [!example]- Solution
> ```bash
> kubectl -n boutique get pods -l app=api
> ```
>
> ```
> NAME                   READY   STATUS             RESTARTS      AGE
> api-6c8b7d9f4b-2kq9z   1/1     Running            0             3h
> api-6c8b7d9f4b-w7m5x   1/1     Running            0             3h
> api-7f9d5c8b6d-h4t8p   0/1     CrashLoopBackOff   3 (25s ago)   80s
> ```
>
> `kubectl logs deploy/api` montrerait le journal d'un ancien pod sain (21.3.2). On lit l'instance précédente du pod en échec :
>
> ```bash
> kubectl -n boutique logs api-7f9d5c8b6d-h4t8p -p | tail -1
> kubectl -n boutique get pod api-7f9d5c8b6d-h4t8p -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
> kubectl -n boutique get deploy api -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}'
> ```
>
> ```
> Error: unknown flag: --option-inconnue
> 1
> ["netexec","--http-port=8080","--option-inconnue"]
> ```
>
> agnhost affiche son aide puis, en dernière ligne, l'erreur, et sort avec le code 1. L'option a été ajoutée au gabarit ; on la retire en revenant à la révision précédente :
>
> ```bash
> kubectl -n boutique rollout undo deployment/api
> # équivalent : kubectl -n boutique patch deployment api --type=json \
> #   -p '[{"op":"remove","path":"/spec/template/spec/containers/0/args/2"}]'
> kubectl -n boutique rollout status deployment/api --timeout=120s
> ```
>
> **Vérification** : `lab/pannes.sh verifier 02` réussit ; `kubectl -n boutique exec outils -- curl -s http://api:8080/hostname` affiche le nom d'un pod `api`.

#### Exercice 22.3 — Panne 03 : les nouveaux pods ne démarrent pas

**Point de départ** : exercice 22.2, ou instantané I4.

Lance `lab/pannes.sh casser 03`. Après un redémarrage de `api` demandé par l'équipe, les nouveaux pods ne démarrent pas. Répare sans modifier le Deployment `api` : il doit continuer à lire la clé `DB_PASSWORD` du Secret `api-secret`, dont la valeur doit rester `changeme-123`.

> [!example]- Solution
> ```bash
> kubectl -n boutique get pods -l app=api
> kubectl -n boutique events --types=Warning | tail -3
> ```
>
> ```
> NAME                   READY   STATUS                       RESTARTS   AGE
> api-6c8b7d9f4b-2kq9z   1/1     Running                      0          3h
> api-6c8b7d9f4b-w7m5x   1/1     Running                      0          3h
> api-84d6f7b9c5-q2n7v   0/1     CreateContainerConfigError   0          75s
>
> LAST SEEN   TYPE      REASON   OBJECT                     MESSAGE
> 12s         Warning   Failed   Pod/api-84d6f7b9c5-q2n7v   Error: couldn't find key DB_PASSWORD in Secret boutique/api-secret
> ```
>
> Le kubelet n'a même pas créé le conteneur : il ne trouve pas la clé que référence `secretKeyRef`. Les anciens pods tournent, car leurs variables d'environnement ont été résolues à leur démarrage. Le Secret :
>
> ```bash
> kubectl -n boutique get secret api-secret -o jsonpath='{.data}{"\n"}'
> ```
>
> ```
> {"DB_PASS":"Y2hhbmdlbWUtMTIz"}
> ```
>
> La clé a été renommée ; sa valeur (`changeme-123` en base64) est intacte. Une opération `move` de JSON Patch la renomme sans la recopier :
>
> ```bash
> kubectl -n boutique patch secret api-secret --type=json \
>   -p '[{"op":"move","from":"/data/DB_PASS","path":"/data/DB_PASSWORD"}]'
> kubectl -n boutique rollout status deployment/api --timeout=120s
> ```
>
> Aucun redéploiement n'est nécessaire : le kubelet retente la création du conteneur à chaque synchronisation du pod (au plus tard après `syncFrequency`, une minute), trouve la clé, et le rollout reprend où il s'était arrêté.
>
> **Vérification** : `kubectl -n boutique get secret api-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d` affiche `changeme-123`, et `lab/pannes.sh verifier 03` réussit.

#### Exercice 22.4 — Panne 04 : la partie /api/ de la boutique ne répond plus

**Point de départ** : exercice 22.3, ou instantané I4.

Lance `lab/pannes.sh casser 04`. Les utilisateurs signalent que `https://api.boutique.example/hostname` répond 503 et que la page `https://boutique.example/api/hostname` n'aboutit plus. Les pods `api` sont tous `Running` et prêts. Trouve et répare.

> [!example]- Solution
> On reproduit depuis l'hôte, puis on descend la pile :
>
> ```bash
> curl -sk --resolve api.boutique.example:443:$IP https://api.boutique.example/hostname -o /dev/null -w '%{http_code}\n'
> kubectl -n boutique get pods -l app=api
> kubectl -n boutique get endpointslices -l kubernetes.io/service-name=api
> ```
>
> ```
> 503
> NAME                   READY   STATUS    RESTARTS   AGE
> api-6c8b7d9f4b-2kq9z   1/1     Running   0          3h
> api-6c8b7d9f4b-w7m5x   1/1     Running   0          3h
> NAME        ADDRESSTYPE   PORTS     ENDPOINTS   AGE
> api-7hx2c   IPv4          <unset>   <unset>     3h
> ```
>
> Des pods sains, mais une EndpointSlice vide : le lien entre le Service et les pods est rompu. On compare le sélecteur aux labels :
>
> ```bash
> kubectl -n boutique get svc api -o jsonpath='{.spec.selector}{"\n"}'
> kubectl -n boutique get pods -l app=api --show-labels | head -2
> ```
>
> ```
> {"app":"apl"}
> NAME                   READY   STATUS    RESTARTS   AGE   LABELS
> api-6c8b7d9f4b-2kq9z   1/1     Running   0          3h    app=api,pod-template-hash=6c8b7d9f4b,tier=api,topology.kubernetes.io/zone=zone-a
> ```
>
> Le sélecteur vise `app=apl`, les pods portent `app=api` (le label de zone est copié du nœud sur le pod, chapitre 8.3). Avant de réparer, observe les deux symptômes, qui illustrent 22.1.2 :
>
> ```bash
> kubectl -n boutique exec outils -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://api:8080/hostname
> kubectl -n boutique exec outils -- curl -s -o /dev/null -w '%{http_code} %{time_total}\n' --max-time 90 http://front/api/hostname
> ```
>
> ```
> 000
> command terminated with exit code 7
> 504 60.004117
> ```
>
> Depuis `outils`, dont la sortie est libre, la connexion est **refusée** tout de suite : kube-proxy rejette le trafic vers un Service sans endpoint (code 7). Depuis `front`, le même paquet n'est pas réécrit par un DNAT (il n'y a pas de pod cible) et part vers l'IP du Service ; la politique `web-sortie` n'autorise `front` qu'à joindre les pods `app=api`, Calico le **jette**, et nginx abandonne au bout de `proxy_connect_timeout` (60 s) avec un 504. Sans NetworkPolicy, `front` aurait reçu le même refus que `outils` et renvoyé un 502 immédiat. ingress-nginx, qui lit les EndpointSlices, répond lui-même 503 pour un Service sans endpoint.
>
> ```bash
> kubectl -n boutique set selector service api app=api
> kubectl -n boutique get endpointslices -l kubernetes.io/service-name=api
> ```
>
> `kubectl set selector` remplace tout le sélecteur, ce qui évite de laisser une clé parasite. L'EndpointSlice se remplit en une seconde.
>
> **Vérification** : `curl -sk --resolve boutique.example:443:$IP https://boutique.example/api/hostname` affiche un nom de pod `api`, et `lab/pannes.sh verifier 04` réussit.

#### Exercice 22.5 — Panne 05 : le Service front ne répond plus

**Point de départ** : exercice 22.4, ou instantané I4.

Lance `lab/pannes.sh casser 05`. La page d'accueil ne s'affiche plus, ni par `http://$IP:30080/` ni depuis le cluster, alors que les trois pods `front` sont `Running` et prêts. Répare en conservant le type `NodePort` et le port 30080.

> [!example]- Solution
> ```bash
> curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://$IP:30080/
> kubectl -n boutique get pods -l app=front -o wide
> kubectl -n boutique get endpointslices -l kubernetes.io/service-name=front
> ```
>
> ```
> 000
> NAME                     READY   STATUS    RESTARTS   AGE   IP               NODE      …
> front-7c6d9b8f5d-k2x7q   1/1     Running   0          3h    10.244.142.71    cka       …
> front-7c6d9b8f5d-m8w4r   1/1     Running   0          3h    10.244.195.199   cka-m02   …
> front-7c6d9b8f5d-t9h2n   1/1     Running   0          3h    10.244.34.135    cka-m03   …
> NAME          ADDRESSTYPE   PORTS   ENDPOINTS                                    AGE
> front-x2k9p   IPv4          8080    10.244.142.71,10.244.195.199,10.244.34.135   3h
> ```
>
> Les pods sont prêts (leur sonde vise le port 80 directement) et l'EndpointSlice les contient, mais avec le port **8080**, alors que nginx écoute sur 80. On isole la couche en testant un pod en direct, sur ses deux ports :
>
> ```bash
> kubectl -n boutique exec outils -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://10.244.142.71:80/
> kubectl -n boutique exec outils -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://10.244.142.71:8080/
> kubectl -n boutique get svc front -o jsonpath='{.spec.ports[0]}{"\n"}'
> ```
>
> ```
> 200
> 000
> command terminated with exit code 28
> {"nodePort":30080,"port":80,"protocol":"TCP","targetPort":8080}
> ```
>
> Le pod répond sur 80. Sur 8080, on n'obtient pas un refus mais un **délai dépassé** (code 28) : la politique `web-entree` n'ouvre que le port 80 des pods `tier=web`, et Calico jette le reste avant même que le pod puisse répondre. Sans cette politique, la connexion aurait été refusée immédiatement (rien n'écoute sur 8080). C'est le `targetPort` du Service qui est faux :
>
> ```bash
> kubectl -n boutique patch service front --type=json \
>   -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":80}]'
> ```
>
> Un patch JSON ne touche que ce champ : le type et le `nodePort` 30080 restent en place.
>
> **Vérification** : `curl -s -o /dev/null -w '%{http_code}\n' http://$IP:30080/` affiche `200`, et `lab/pannes.sh verifier 05` réussit.

#### Exercice 22.6 — Panne 06 : le DNS ne répond plus dans boutique

**Point de départ** : exercice 22.5, ou instantané I4.

Lance `lab/pannes.sh casser 06`. Un développeur signale que, depuis les pods de `boutique`, les résolutions DNS échouent en délai dépassé. Les pods déjà démarrés continuent de servir, mais tout redémarrage de `front` est désormais risqué. Trouve et répare.

> [!example]- Solution
> On teste depuis un pod réellement concerné, puis depuis `outils` :
>
> ```bash
> kubectl -n boutique exec deploy/front -- nslookup -timeout=3 api.boutique.svc.cluster.local
> kubectl -n boutique exec outils -- dig +short api.boutique.svc.cluster.local
> kubectl -n kube-system get pods -l k8s-app=kube-dns
> ```
>
> ```
> ;; connection timed out; no servers could be reached
>
> command terminated with exit code 1
> 10.105.37.214
> NAME                       READY   STATUS    RESTARTS   AGE
> coredns-7d4c9b8f6d-9xk2m   1/1     Running   0          3h
> coredns-7d4c9b8f6d-tq4zl   1/1     Running   0          3h
> ```
>
> CoreDNS fonctionne et répond à `outils`, dont la sortie est libre ; seul `front` n'obtient rien. Le silence (et non `NXDOMAIN`) désigne des paquets jetés : une NetworkPolicy de sortie. Dans `boutique`, la seule qui ouvre le DNS est `autorise-dns` :
>
> ```bash
> kubectl -n boutique get networkpolicy autorise-dns -o jsonpath='{.spec.egress[0].ports}{"\n"}'
> ```
>
> ```
> [{"port":5353,"protocol":"UDP"},{"port":5353,"protocol":"TCP"}]
> ```
>
> Les requêtes partent vers `10.96.0.10:53`, sont réécrites vers un pod CoreDNS sur le port 53, et c'est ce port, après DNAT, que compare la politique. 5353 n'autorise rien d'utile.
>
> ```bash
> kubectl -n boutique patch networkpolicy autorise-dns --type=json -p \
>   '[{"op":"replace","path":"/spec/egress/0/ports/0/port","value":53},{"op":"replace","path":"/spec/egress/0/ports/1/port","value":53}]'
> kubectl -n boutique exec deploy/front -- nslookup -timeout=3 api.boutique.svc.cluster.local
> ```
>
> Le risque annoncé était réel : nginx résout `api` (dans `proxy_pass http://api:8080/`) au chargement de sa configuration ; un pod `front` redémarré sans DNS sort en erreur (`nginx: [emerg] host not found in upstream "api" in /etc/nginx/conf.d/default.conf:4`, vérifié en supprimant un pod pendant la panne) et redémarre en boucle (`Error`, puis `CrashLoopBackOff`).
>
> **Vérification** : la résolution depuis `front` renvoie l'adresse du Service `api`, et `lab/pannes.sh verifier 06` réussit.

#### Exercice 22.7 — Panne 07 : la nouvelle version de front-v2 ne se déploie pas

**Point de départ** : exercice 22.6, ou instantané I4.

Lance `lab/pannes.sh casser 07`. Une modification de `front-v2` a été appliquée il y a quelques minutes, mais elle ne se déploie pas : `kubectl -n boutique rollout status deployment/front-v2` n'aboutit pas. La page v2 est toujours servie. Trouve la cause et ramène `front-v2` à ses ressources d'origine (requests 50m et 32Mi, limits 200m et 64Mi), de sorte que le déploiement se termine.

> [!example]- Solution
> ```bash
> kubectl -n boutique get deploy front-v2
> kubectl -n boutique get rs,pods -l app=front-v2
> kubectl -n boutique get deploy front-v2 -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
> ```
>
> ```
> NAME       READY   UP-TO-DATE   AVAILABLE   AGE
> front-v2   1/1     0            1           2h
>
> NAME                                  DESIRED   CURRENT   READY   AGE
> replicaset.apps/front-v2-6d8f7c9b4f   1         1         1       2h
> replicaset.apps/front-v2-7d4b9c8f6    1         0         0       2m
>
> NAME                            READY   STATUS    RESTARTS   AGE
> pod/front-v2-6d8f7c9b4f-q8m2t   1/1     Running   0          2h
> Available=True MinimumReplicasAvailable
> Progressing=True NewReplicaSetCreated
> ReplicaFailure=True FailedCreate
> ```
>
> Le nouveau ReplicaSet veut un pod (`DESIRED 1`) et n'en a aucun (`CURRENT 0`) : le pod n'a jamais été créé, il n'y a donc ni pod en échec ni `FailedScheduling` à chercher. L'ancien pod sert toujours, car avec un seul réplica les valeurs par défaut de la stratégie (25 %) donnent `maxSurge` 1 et `maxUnavailable` 0. La condition `ReplicaFailure` renvoie au ReplicaSet :
>
> ```bash
> kubectl -n boutique describe rs front-v2-7d4b9c8f6 | tail -2
> ```
>
> ```
>   Warning  FailedCreate  3m18s                   replicaset-controller  Error creating: pods "front-v2-7d4b9c8f6-lchgd" is forbidden: maximum cpu usage per Container is 1, but limit is 2
>   Warning  FailedCreate  2m27s (x16 over 3m17s)  replicaset-controller  (combined from similar events): Error creating: pods "front-v2-7d4b9c8f6-4t8b9" is forbidden: maximum cpu usage per Container is 1, but limit is 2
> ```
>
> La LimitRange `boutique-limites` plafonne chaque conteneur à 1 CPU ; le nouveau gabarit demande 2 CPU en request et en limit. Le quota `boutique-quota` n'est pas en cause : il resterait de la place sous ses 4 CPU de requests et 8 CPU de limits, et de toute façon `LimitRanger` passe avant `ResourceQuota` dans la chaîne d'admission. Le contrôleur de ReplicaSet réessaie avec un délai croissant. Chaque essai porte un nom de pod différent, donc un message différent : `describe` liste d'abord neuf événements distincts, puis les suivants sont regroupés sous `(combined from similar events):` (21.5.1). Au bout d'une minute environ, le compteur cesse d'augmenter : la bibliothèque client limite chaque émetteur à une rafale de 25 événements par objet, puis à un toutes les cinq minutes, alors que le contrôleur continue de réessayer. `rollout history` confirme ce qui a changé, puis on rétablit les valeurs d'origine :
>
> ```bash
> kubectl -n boutique rollout history deployment/front-v2
> kubectl -n boutique set resources deployment front-v2 --requests=cpu=50m,memory=32Mi --limits=cpu=200m,memory=64Mi
> kubectl -n boutique rollout status deployment/front-v2 --timeout=120s
> ```
>
> Le gabarit redevient identique à celui de l'ancien ReplicaSet, que le contrôleur reprend tel quel ; le ReplicaSet fautif retombe à zéro. `kubectl -n boutique rollout undo deployment/front-v2` aboutit au même résultat. Sans intervention, la condition `Progressing` serait passée à `False` (`ProgressDeadlineExceeded`) au bout de 600 s, sans autre effet : l'ancien pod aurait continué à servir indéfiniment.
>
> **Vérification** : `kubectl -n boutique rollout status deployment/front-v2` se termine, `curl -sk --resolve gw.boutique.example:443:$(kubectl -n boutique get gateway boutique-gw -o jsonpath='{.status.addresses[0].value}') -H 'X-Version: v2' https://gw.boutique.example/` contient `v2`, et `lab/pannes.sh verifier 07` réussit.

#### Exercice 22.8 — Panne 08 : redis-0 reste Pending

**Point de départ** : exercice 22.7, ou instantané I4.

Lance `lab/pannes.sh casser 08`. Après un redémarrage, `redis-0` reste `Pending`. Remets-le en service **sans modifier le StatefulSet `redis`** et sans perdre ses données.

> [!example]- Solution
> ```bash
> kubectl -n boutique get pod redis-0 -o wide
> kubectl -n boutique events --for pod/redis-0
> ```
>
> ```
> NAME      READY   STATUS    RESTARTS   AGE   IP       NODE     …
> redis-0   0/1     Pending   0          40s   <none>   <none>   …
>
> LAST SEEN   TYPE      REASON             OBJECT        MESSAGE
> …
> 41s         Normal    Killing            Pod/redis-0   Stopping container redis
> 40s         Warning   FailedScheduling   Pod/redis-0   0/3 nodes are available: 3 node(s) didn't match Pod's node affinity/selector. preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
> ```
>
> Le nom `redis-0` étant réutilisé d'une incarnation à l'autre, `--for pod/redis-0` ramène aussi les événements de l'ancien pod, jusqu'à son arrêt (`Killing`) ; seule la dernière ligne concerne le pod actuel. Aucun nœud ne satisfait les contraintes de placement. Le pod en a deux : le `nodeSelector` du gabarit et l'affinité du PV de sa PVC.
>
> ```bash
> kubectl -n boutique get sts redis -o jsonpath='{.spec.template.spec.nodeSelector}{"\n"}'
> kubectl get nodes -L disque
> kubectl get pv $(kubectl -n boutique get pvc data-redis-0 -o jsonpath='{.spec.volumeName}') -o jsonpath='{.spec.nodeAffinity.required}{"\n"}'
> ```
>
> ```
> {"disque":"ssd"}
> NAME      STATUS   ROLES           AGE   VERSION   DISQUE
> cka       Ready    control-plane   4h    v1.37.0
> cka-m02   Ready    <none>          4h    v1.37.0
> cka-m03   Ready    <none>          4h    v1.37.0   hdd
> {"nodeSelectorTerms":[{"matchExpressions":[{"key":"topology.hostpath.csi/node","operator":"In","values":["cka-m03"]}]}]}
> ```
>
> Le label `disque` de `cka-m03` vaut `hdd`. Le PV, provisionné par le pilote CSI hostpath, ne peut de toute façon être monté que sur `cka-m03` : retirer le `nodeSelector` ne servirait à rien (le message deviendrait `node(s) didn't match PersistentVolume's node affinity` pour les deux autres nœuds), et c'est interdit par l'énoncé. Le label est la seule réparation correcte :
>
> ```bash
> kubectl label node cka-m03 disque=ssd --overwrite
> kubectl -n boutique wait --for=condition=Ready pod/redis-0 --timeout=120s
> ```
>
> Le scheduler retente le pod dès que le nœud change ; aucune action sur le pod n'est nécessaire.
>
> **Vérification** : `kubectl -n boutique exec redis-0 -- redis-cli GET commandes` affiche `42` (la clé écrite au chapitre 15), et `lab/pannes.sh verifier 08` réussit.

#### Exercice 22.9 — Panne 09 : le Service api n'a plus de backend

**Point de départ** : exercice 22.8, ou instantané I4.

Lance `lab/pannes.sh casser 09`. Les pods `api` tournent, mais le Service `api` n'a plus aucun backend et `https://api.boutique.example/hostname` répond 503. Répare.

> [!example]- Solution
> ```bash
> kubectl -n boutique get pods -l app=api
> kubectl -n boutique get endpointslices -l kubernetes.io/service-name=api \
>   -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" ready="}{.conditions.ready}{"\n"}{end}'
> ```
>
> ```
> NAME                   READY   STATUS    RESTARTS   AGE
> api-5d8c7f6b9a-6tq2w   0/1     Running   0          2m
> api-5d8c7f6b9a-zx8kh   0/1     Running   0          2m
> 10.244.195.201 ready=false
> 10.244.34.137 ready=false
> ```
>
> Cette fois le sélecteur est bon (les adresses sont là), mais aucune n'est prête : les pods tournent sans passer leur sonde de disponibilité.
>
> ```bash
> kubectl -n boutique events --for pod/api-5d8c7f6b9a-6tq2w --types=Warning
> kubectl -n boutique get deploy api -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}{"\n"}{.spec.template.spec.containers[0].ports}{"\n"}'
> ```
>
> ```
> LAST SEEN   TYPE      REASON      OBJECT                     MESSAGE
> 5s          Warning   Unhealthy   Pod/api-5d8c7f6b9a-6tq2w   Readiness probe failed: Get "http://10.244.195.201:8081/hostname": dial tcp 10.244.195.201:8081: connect: connection refused
> {"failureThreshold":3,"httpGet":{"path":"/hostname","port":8081,"scheme":"HTTP"},"periodSeconds":10,"successThreshold":1,"timeoutSeconds":1}
> [{"containerPort":8080,"name":"http","protocol":"TCP"}]
> ```
>
> La sonde vise le port 8081, où rien n'écoute en TCP ; l'application sert sur 8080, le port nommé `http`. Les anciens pods, qui auraient dû continuer à servir pendant ce rollout (`maxUnavailable` vaut 0 avec 2 réplicas), ont disparu : leur ReplicaSet a été ramené à zéro à la main, ce qu'un `kubectl -n boutique get rs -l app=api` montre. On rétablit la sonde telle qu'elle était, avec le port nommé :
>
> ```bash
> kubectl -n boutique patch deployment api --type=json \
>   -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":"http"}]'
> kubectl -n boutique rollout status deployment/api --timeout=120s
> kubectl -n boutique get rs -l app=api
> ```
>
> Le gabarit redevient identique à celui de l'ancien ReplicaSet : le contrôleur le réutilise (même hachage `pod-template-hash`) et le remonte à 2, puis réduit le ReplicaSet fautif. `rollout undo` aboutirait au même résultat.
>
> **Vérification** : les deux adresses de l'EndpointSlice affichent `ready=true`, `curl -sk --resolve api.boutique.example:443:$IP https://api.boutique.example/hostname` répond un nom de pod, et `lab/pannes.sh verifier 09` réussit. Juste après la fin du rollout, l'EndpointSlice peut encore lister l'adresse d'un pod fautif en cours d'arrêt (`ready=false`) et ingress-nginx répondre `503` une ou deux secondes, le temps de recharger ses backends : relance le `curl`.

#### Exercice 22.10 — Panne 10 : redis-0 redémarre en boucle

**Point de départ** : exercice 22.9, ou instantané I4.

Lance `lab/pannes.sh casser 10`. `redis-0` redémarre en boucle depuis une modification du StatefulSet. Rétablis `redis` avec ses ressources mémoire d'origine (request 64Mi, limit 256Mi) et vérifie que la clé `commandes` écrite au chapitre 15 est intacte.

> [!example]- Solution
> ```bash
> kubectl -n boutique get pod redis-0
> kubectl -n boutique describe pod redis-0 | grep -A4 'Last State'
> kubectl -n boutique get sts redis -o jsonpath='{.spec.template.spec.containers[0].resources}{"\n"}'
> ```
>
> ```
> NAME      READY   STATUS             RESTARTS      AGE
> redis-0   0/1     CrashLoopBackOff   4 (50s ago)   3m
>     Last State:     Terminated
>       Reason:       OOMKilled
>       Exit Code:    137
>       Started:      Fri, 23 Oct 2026 21:41:12 +0200
>       Finished:     Fri, 23 Oct 2026 21:41:12 +0200
> {"limits":{"cpu":"200m","memory":"5Mi"},"requests":{"cpu":"50m","memory":"4Mi"}}
> ```
>
> `OOMKilled` et 137 : le noyau a tué redis parce qu'il dépassait la limite mémoire de son cgroup, et le gabarit montre une limite de `5Mi` (request `4Mi`), bien trop basse pour charger le serveur et ses données. Selon l'instant, la colonne STATUS affiche `CrashLoopBackOff` ou `Error` : le kubelet n'inscrit l'attente qu'en resynchronisant le pod (22.2.4). Si `Reason` vaut `Error` avec le même code 137, c'est la limite inotify de ton poste qui a empêché containerd d'observer l'OOM (22.2.6) ; `minikube -p cka ssh -n cka-m03 -- 'sudo dmesg | grep -i "out of memory" | tail -1'` le confirme (`Memory cgroup out of memory: Killed process … (redis-server)`). On rétablit les deux valeurs d'un coup (une request supérieure à la limit serait refusée par la validation) :
>
> ```bash
> kubectl -n boutique set resources statefulset redis --requests=memory=64Mi --limits=memory=256Mi
> kubectl -n boutique rollout status statefulset/redis --timeout=60s
> ```
>
> `rollout status` ne se termine pas (`Waiting for 1 pods to be ready...`, puis `error: timed out waiting for the condition`) : avec la politique `OrderedReady`, le contrôleur attend que `redis-0`, cassé, devienne prêt avant d'appliquer le nouveau gabarit, ce qui n'arrivera jamais (« Forced rollback », 22.4.1). Le pod garde l'ancien gabarit, comme le montre son label `controller-revision-hash`, différent de `.status.updateRevision`. On le supprime pour qu'il soit recréé avec le bon :
>
> ```bash
> kubectl -n boutique delete pod redis-0
> kubectl -n boutique rollout status statefulset/redis --timeout=120s
> kubectl -n boutique exec redis-0 -- redis-cli GET commandes
> ```
>
> Le second `rollout status` se termine par `partitioned roll out complete: 1 new pods have been updated...`. La PVC `data-redis-0` n'est pas touchée par la suppression du pod : la donnée écrite avec `--appendonly yes` est rechargée.
>
> **Vérification** : `redis-cli GET commandes` affiche `42`, et `lab/pannes.sh verifier 10` réussit.

#### Exercice 22.11 — Un conteneur éphémère dans api

**Point de départ** : exercice 22.10, ou instantané I4.

Sans `kubectl exec`, ajoute à un pod `api` un conteneur éphémère nommé `sonde`, image `nicolaka/netshoot:v0.16`, qui voit les processus du conteneur `agnhost`. Constate d'abord que le profil par défaut est refusé dans `boutique`. Depuis ce conteneur, affiche les processus visibles, la variable `APP_MODE` du processus agnhost, puis vérifie que le pod joint `redis-0` sur le port 6379 mais pas `front` sur le port 80. Explique ces deux résultats.

> [!example]- Solution
> ```bash
> POD=$(kubectl -n boutique get pods -l app=api -o jsonpath='{.items[0].metadata.name}')
> kubectl -n boutique debug $POD --image=nicolaka/netshoot:v0.16 --target=agnhost -c sonde -- sleep 600
> ```
>
> ```
> Targeting container "agnhost". If you don't see processes from this container it may be because the container runtime doesn't support this feature.
> Error from server (Forbidden): pods "api-6c8b7d9f4b-2kq9z" is forbidden: violates PodSecurity "baseline:latest": non-default capabilities (container "sonde" must not include "SYS_PTRACE" in securityContext.capabilities.add)
> ```
>
> Le profil `general` ajoute `SYS_PTRACE`, que le niveau `baseline` imposé à `boutique` interdit. Avec le profil `baseline` :
>
> ```bash
> kubectl -n boutique debug $POD --image=nicolaka/netshoot:v0.16 --target=agnhost -c sonde --profile=baseline -- sleep 600
> kubectl -n boutique exec $POD -c sonde -- ps -o pid,user,args
> kubectl -n boutique exec $POD -c sonde -- sh -c 'tr "\0" "\n" < /proc/1/environ | grep APP_MODE'
> kubectl -n boutique exec $POD -c sonde -- nc -zv -w 3 redis-0.redis 6379
> kubectl -n boutique exec $POD -c sonde -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 3 http://front/
> ```
>
> ```
> PID   USER     COMMAND
>     1 root     /agnhost netexec --http-port=8080
>    23 root     sleep 600
>    31 root     ps -o pid,user,args
> APP_MODE=production
> Connection to redis-0.redis (10.244.34.140) 6379 port [tcp/redis] succeeded!
> 000
> command terminated with exit code 28
> ```
>
> Le conteneur éphémère est lancé ici avec une commande `sleep 600` pour pouvoir y exécuter ensuite plusieurs commandes ; en session interactive, on aurait utilisé `-it` sans commande. Avec `--target`, il partage l'espace de processus d'`agnhost`, qui y est le PID 1 ; `/proc/1/environ` montre l'environnement injecté par `envFrom` (et aussi `DB_PASSWORD` : quiconque peut déboguer un pod lit ses secrets). Il partage surtout l'espace réseau du pod, donc ses NetworkPolicies : `api-sortie` autorise `redis` sur 6379, rien n'autorise `front`, et le refus est un délai dépassé (code 28). Le conteneur ne peut pas être retiré : il reste dans `spec.ephemeralContainers` et se termine au bout de 600 s.
>
> **Vérification** : `kubectl -n boutique get pod $POD -o jsonpath='{.spec.ephemeralContainers[*].name}'` affiche `sonde`. Pour retrouver un pod sans conteneur éphémère, supprime-le : le Deployment le recrée.

#### Exercice 22.12 — Lire l'état d'une route cassée

**Point de départ** : exercice 22.11, ou instantané I4.

Crée dans `boutique` une HTTPRoute temporaire `catalogue`, attachée au listener `https` de `boutique-gw`, hôte `gw.boutique.example`, qui envoie le préfixe `/catalogue` vers un Service `catalogue` port 80 qui n'existe pas. Lis ses conditions, mesure le code HTTP obtenu sur `/catalogue` et sur `/`, puis supprime la route.

> [!example]- Solution
> ```yaml
> apiVersion: gateway.networking.k8s.io/v1
> kind: HTTPRoute
> metadata:
>   name: catalogue
>   namespace: boutique
> spec:
>   parentRefs:
>   - name: boutique-gw
>     sectionName: https
>   hostnames:
>   - gw.boutique.example
>   rules:
>   - matches:
>     - path:
>         type: PathPrefix
>         value: /catalogue
>     backendRefs:
>     - name: catalogue
>       port: 80
> ```
>
> ```bash
> # enregistre le manifeste ci-dessus dans ~/cka/boutique/route-catalogue.yaml, puis :
> kubectl -n boutique apply -f ~/cka/boutique/route-catalogue.yaml
> kubectl -n boutique get httproute catalogue -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
> GW=$(kubectl -n boutique get gateway boutique-gw -o jsonpath='{.status.addresses[0].value}')
> curl -sk --resolve gw.boutique.example:443:$GW https://gw.boutique.example/catalogue -o /dev/null -w '%{http_code}\n'
> curl -sk --resolve gw.boutique.example:443:$GW https://gw.boutique.example/ -o /dev/null -w '%{http_code}\n'
> kubectl -n boutique delete httproute catalogue
> ```
>
> ```
> Accepted=True Accepted
> ResolvedRefs=False BackendNotFound
> 500
> 200
> ```
>
> La route est acceptée (le listener `https` admet les routes du même namespace et l'hôte correspond), mais sa référence ne se résout pas : `ResolvedRefs=False`, raison `BackendNotFound`. Conformément à la spécification, la Gateway répond 500 aux requêtes qui auraient dû aller vers ce backend. `/catalogue` est plus spécifique que le `/` de la route `front`, il est donc servi par `catalogue` ; `/` reste servi par `front`. Une erreur de route n'affecte que ses propres correspondances.
>
> **Vérification** : `kubectl -n boutique get httproute` ne liste plus que `api`, `front` et `redirection-https`.

---
