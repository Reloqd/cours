---
title: "CKA — 8. Ordonnancement et admission des pods"
description: "Le fonctionnement du kube-scheduler (file, filtrage, score, binding), toutes les formes d'affinité, les topologySpreadConstraints, taints et tolerations, PriorityClass et préemption, ResourceQuota et LimitRange, les contrôleurs d'admission de la 1.37, Pod Security Admission, puis cordon, drain et PodDisruptionBudget."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 8. Ordonnancement et admission des pods

Entre le moment où tu valides un manifeste et celui où un conteneur démarre, un pod franchit deux portes. La première est l'**admission** : dans l'apiserver, une chaîne de contrôleurs complète l'objet (requests par défaut, tolerations par défaut, priorité), puis le valide contre les politiques du namespace (quota, limites, niveau de sécurité). La seconde est l'**ordonnancement** : le kube-scheduler choisit le nœud, en filtrant ceux qui ne conviennent pas, puis en classant les autres. Ce chapitre ouvre ces deux portes. Il commence par le scheduler, qu'il faut comprendre de l'intérieur pour lire un message `FailedScheduling` en une seconde ; il passe en revue chaque moyen d'orienter le placement (nodeSelector, affinités, répartition topologique, taints, priorités), puis les politiques d'admission d'un namespace (ResourceQuota, LimitRange, Pod Security Admission), et termine par l'opération de maintenance qui met tout cela à l'épreuve : vider un nœud sans casser le service.

Le programme v1.37 regroupe ces notions sous *Configure Pod admission and scheduling (limits, node affinity, etc.)*, dans le domaine *Workloads and Scheduling*. Le drain d'un nœud sert aussi *Manage the lifecycle of Kubernetes clusters* (il précède chaque mise à jour, [chapitre 19](19-kubeadm-installation-ha-et-mises-a-jour.md)), et le diagnostic d'un pod `Pending` est l'une des tâches les plus fréquentes de *Troubleshoot clusters and nodes*. Le chemin complet d'une requête (authentification, autorisation, admission, validation) est décrit au [chapitre 2](02-architecture.md), et les webhooks d'admission au [chapitre 18](18-interfaces-crd-et-operateurs.md) : on se concentre ici sur les contrôleurs d'admission intégrés qui touchent les pods.

### 8.1 Du manifeste au conteneur : les deux portes

```
          ADMISSION PUIS ORDONNANCEMENT D'UN POD
═══════════════════════════════════════════════════════════════════

  kubectl apply ──▶ kube-apiserver
                    │ authentification ▶ autorisation (RBAC)
                    │
                    │ ADMISSION, PHASE MUTANTE (dans l'ordre)
                    │   LimitRanger ........ requests/limits par défaut
                    │   ServiceAccount ..... compte et jeton projetés
                    │   Priority ........... priorityClassName ▶ priority
                    │   DefaultToleration-
                    │   Seconds ............ not-ready/unreachable 300 s
                    │   webhooks mutants
                    │ validation du schéma
                    │ ADMISSION, PHASE DE VALIDATION
                    │   LimitRanger (min/max), PodSecurity,
                    │   webhooks de validation, ResourceQuota (en dernier)
                    ▼
                  etcd : pod sans spec.nodeName, phase Pending
                    │
                    ▼ watch
  kube-scheduler ── file ▶ filtrage ▶ score ▶ binding (pods/binding)
                    │                 l'admission PodTopologyLabels
                    │                 copie zone/région du nœud
                    ▼ watch            sur le pod
  kubelet du nœud ── admission locale (ressources, taints NoExecute)
                    ▶ conteneurs démarrés
```

Deux conséquences pratiques découlent de cet ordre. Le **LimitRanger mute avant que ResourceQuota ne valide** : les valeurs par défaut injectées par un LimitRange sont donc comptées dans le quota, ce qui permet à un pod sans `resources` d'entrer dans un namespace soumis à quota (8.10, 8.11). Et un refus d'admission se produit **à la création** de l'objet pod : `kubectl run` reçoit l'erreur, mais quand c'est un ReplicaSet qui crée les pods, l'erreur atterrit dans les événements du ReplicaSet (`FailedCreate`), jamais dans ceux du Deployment. Un refus d'ordonnancement, lui, laisse le pod exister en `Pending` avec un événement `FailedScheduling`.

### 8.2 Le kube-scheduler de l'intérieur

#### La file d'attente

Le scheduler surveille les pods dont `spec.nodeName` est vide et dont `spec.schedulerName` désigne son profil (`default-scheduler` par défaut). Il les range dans une file à trois compartiments. La **file active** est triée par le plugin `PrioritySort` : priorité décroissante, puis ancienneté. La **file de repli** (*backoff*) accueille les pods qui viennent d'échouer, pour une attente qui commence à 1 s et double à chaque échec jusqu'à 10 s (`podInitialBackoffSeconds` et `podMaxBackoffSeconds` de la configuration du scheduler). Les **pods non planifiables** attendent un événement du cluster susceptible de les débloquer (un nœud ajouté, un pod supprimé, une taint retirée) ; les *queueing hints* des plugins décident quels événements les remettent en file. Un pod porteur de `spec.schedulingGates` n'entre même pas en file active : il reste à l'état `SchedulingGated` tant qu'un contrôleur n'a pas retiré ses portes (fonction stable depuis 1.30).

#### Le cycle d'ordonnancement et le cycle de binding

Chaque tentative passe par les points d'extension du *scheduling framework*, que les plugins implémentent :

```
          UNE TENTATIVE D'ORDONNANCEMENT
═══════════════════════════════════════════════════════════════════

  CYCLE D'ORDONNANCEMENT (un pod à la fois)
    PreFilter ── calculs préalables, rejet immédiat possible
    Filter ───── chaque nœud : faisable ou non   ──┐ aucun nœud ?
    PostFilter ─ seulement si aucun nœud : ◀───────┘ PRÉEMPTION (8.9)
    PreScore / Score / NormalizeScore ── note de 0 à 100 par plugin,
                                         × poids du plugin, somme
    Reserve ──── réserve les ressources dans le cache
    Permit ───── approuver, refuser ou faire attendre
  CYCLE DE BINDING (en parallèle pour plusieurs pods)
    PreBind ──── ex. provisionner et attacher un volume
    Bind ─────── écrit pods/binding ▶ spec.nodeName
    PostBind
```

Les cycles d'ordonnancement sont séquentiels, les cycles de binding concurrents. Le nœud retenu est celui qui obtient la meilleure somme pondérée ; en cas d'égalité, le scheduler tire au sort. Sur un grand cluster, il cesse de chercher des nœuds faisables une fois `percentageOfNodesToScore` atteint (calcul automatique : 50 % des nœuds pour 100 nœuds, 10 % pour 5 000, jamais moins de 5 %) ; sous 100 nœuds, il les évalue tous.

#### Les plugins actifs par défaut

| Plugin | Points d'extension | Poids au score | Ce qu'il vérifie ou favorise |
|---|---|---|---|
| `SchedulingGates` | PreEnqueue | — | `spec.schedulingGates` vide |
| `PrioritySort` | QueueSort | — | ordre de la file |
| `NodeName` | Filter | — | `spec.nodeName` si renseigné |
| `NodeUnschedulable` | Filter | — | nœud cordonné (`spec.unschedulable`) |
| `TaintToleration` | Filter, PreScore, Score | 3 | taints `NoSchedule`/`NoExecute` tolérées ; moins de `PreferNoSchedule` non tolérées |
| `NodeAffinity` | Filter, Score | 2 | `nodeSelector`, affinité de nœud requise et préférée |
| `NodePorts` | PreFilter, Filter | — | `hostPort` libres |
| `NodeResourcesFit` | PreFilter, Filter, Score | 1 | somme des requests ≤ allocatable ; score `LeastAllocated` par défaut |
| `VolumeRestrictions`, `NodeVolumeLimits`, `VolumeBinding`, `VolumeZone` | divers | — | contraintes des volumes (chapitre 15) |
| `PodTopologySpread` | PreFilter, Filter, PreScore, Score | 2 | `topologySpreadConstraints` |
| `InterPodAffinity` | PreFilter, Filter, PreScore, Score | 2 | affinité et anti-affinité entre pods |
| `DefaultPreemption` | PostFilter | — | préemption |
| `NodeResourcesBalancedAllocation` | Score | 1 | équilibre CPU/mémoire après placement |
| `ImageLocality` | Score | 1 | images déjà présentes sur le nœud |
| `DefaultBinder` | Bind | — | binding |

S'y ajoutent en 1.37 `DynamicResources` (DRA, poids 2) et `NodeDeclaredFeatures`, actifs parce que leurs fonctions sont stables. Retiens surtout le principe : **un filtre élimine, un score départage**. Une règle « préférée » (affinité préférée, `ScheduleAnyway`, `PreferNoSchedule`) n'est qu'un score : elle peut perdre contre un autre critère.

#### Lire un échec d'ordonnancement

Quand aucun nœud ne passe les filtres, le scheduler publie un événement `FailedScheduling` qui résume, nœud par nœud, la raison du rejet, puis le bilan de la tentative de préemption :

```bash
kubectl -n boutique describe pod affinite-nvme | sed -n '/Events/,$p'
```

```
Events:
  Type     Reason            Age   From               Message
  ----     ------            ----  ----               -------
  Warning  FailedScheduling  12s   default-scheduler  0/3 nodes are available: 3 node(s) didn't match Pod's node affinity/selector. preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling.
```

| Fragment du message | Plugin | Cause |
|---|---|---|
| `didn't match Pod's node affinity/selector` | NodeAffinity | `nodeSelector` ou affinité de nœud requise |
| `had untolerated taint(s)` | TaintToleration | taint `NoSchedule`/`NoExecute` non tolérée |
| `were unschedulable` | NodeUnschedulable | nœud cordonné |
| `Insufficient cpu`, `Insufficient memory`, `Insufficient <ressource étendue>` | NodeResourcesFit | requests trop grosses pour l'allocatable restant |
| `didn't match pod anti-affinity rules`, `didn't match pod affinity rules`, `didn't satisfy existing pods anti-affinity rules` | InterPodAffinity | affinités entre pods |
| `didn't match pod topology spread constraints` | PodTopologySpread | `DoNotSchedule` impossible à respecter |
| `didn't have free ports for the requested pod ports` | NodePorts | `hostPort` occupé |
| `had volume node affinity conflict` | VolumeBinding | PV attaché à un autre nœud |

> [!warning]
> Depuis la 1.37, le message de TaintToleration ne nomme plus la taint : `node(s) had untolerated taint(s)`. Les anciens supports montrent encore `had untolerated taint {node-role.kubernetes.io/control-plane: }`. Pour savoir laquelle, lis les nœuds : `kubectl get nodes -o custom-columns=NOM:.metadata.name,TAINTS:.spec.taints`.

Un pod `Pending` **sans aucun événement** est un autre symptôme : personne n'a tenté de le planifier. Soit le scheduler est arrêté (pod statique cassé, [chapitre 23](23-depanner-le-cluster.md)), soit `spec.schedulerName` désigne un scheduler qui n'existe pas, soit le pod porte des `schedulingGates`.

> [!info] minikube ≠ examen
> Le kube-scheduler du lab tourne avec `--leader-elect=false`, et chaque nœud annonce les 8 CPU et 32 Gio de l'hôte : le filtre `NodeResourcesFit` ne refusera presque jamais rien pour manque de CPU, alors qu'un nœud d'examen de 2 CPU se remplit vite. Les démonstrations de manque de ressources de ce chapitre utilisent donc une ressource étendue (exercice 8.4) plutôt que le CPU.

### 8.3 nodeName, nodeSelector et labels de nœuds

**`spec.nodeName`** court-circuite le scheduler : le pod est lié d'office au nœud nommé. Aucun filtre ne s'applique, ni taints `NoSchedule`, ni ressources. Le kubelet, qui fait sa propre admission, refuse alors le pod s'il ne tient pas (statut `OutOfcpu` ou `OutOfmemory`) ou s'il ne tolère pas une taint `NoExecute` du nœud. Si le nœud n'existe pas, le pod ne démarre jamais et peut être supprimé automatiquement par le ramasse-miettes de pods. `nodeName` est réservé aux schedulers personnalisés et au dépannage ; c'est aussi la raison pour laquelle un pod placé ainsi ignore un nœud cordonné.

**`spec.nodeSelector`** est la contrainte la plus simple : une table de labels que le nœud doit **tous** porter (ET logique). Les labels se posent et se retirent avec `kubectl label` :

```bash
kubectl label node cka-m03 disque=ssd                      # ajouter
kubectl label node cka-m03 disque=nvme --overwrite         # modifier
kubectl label node cka-m03 disque-                         # retirer
kubectl get nodes -L topology.kubernetes.io/zone,disque    # afficher en colonnes
kubectl get nodes -l disque=ssd                            # filtrer
```

Chaque nœud porte des labels bien connus posés par le kubelet : `kubernetes.io/hostname`, `kubernetes.io/os`, `kubernetes.io/arch`, et, chez un fournisseur de cloud, `topology.kubernetes.io/zone`, `topology.kubernetes.io/region` et `node.kubernetes.io/instance-type`. Sur un cluster nu (kubeadm comme minikube), il n'y a pas de zone : c'est à toi de la poser. Pour l'isolement de sécurité, préfère des clés que le kubelet ne peut pas modifier lui-même : l'admission `NodeRestriction` interdit aux kubelets de toucher aux labels préfixés `node-restriction.kubernetes.io/`.

Le fil rouge pose trois labels persistants, qui serviront jusqu'au chapitre 15 :

| Nœud | `topology.kubernetes.io/zone` | `disque` |
|---|---|---|
| `cka` | `zone-a` | — |
| `cka-m02` | `zone-b` | — |
| `cka-m03` | `zone-b` | `ssd` |

Depuis la 1.35, l'admission `PodTopologyLabels` (bêta, active) copie au moment du binding les labels `topology.kubernetes.io/zone` et `topology.kubernetes.io/region` du nœud sur le pod : un conteneur peut lire sa zone par l'API descendante (`fieldPath: metadata.labels['topology.kubernetes.io/zone']`).

### 8.4 L'affinité de nœud

`spec.affinity.nodeAffinity` généralise `nodeSelector` avec deux variantes. `requiredDuringSchedulingIgnoredDuringExecution` est un filtre : le pod ne va que sur un nœud qui satisfait la règle. `preferredDuringSchedulingIgnoredDuringExecution` est un score : chaque terme a un `weight` de 1 à 100, ajouté à la note des nœuds qui le satisfont. Le suffixe `IgnoredDuringExecution` signifie qu'un changement de labels après le placement ne déplace rien : le pod continue de tourner.

```yaml
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:            # termes reliés par OU
        - matchExpressions:           # expressions reliées par ET
          - key: disque
            operator: In
            values: ["ssd", "nvme"]
          - key: kubernetes.io/os
            operator: In
            values: ["linux"]
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 80
        preference:
          matchExpressions:
          - key: topology.kubernetes.io/zone
            operator: In
            values: ["zone-b"]
```

La logique booléenne est le piège principal : plusieurs `nodeSelectorTerms` se combinent par **OU**, plusieurs `matchExpressions` d'un même terme par **ET**. Si `nodeSelector` et une affinité requise coexistent, il faut satisfaire les **deux**. Un terme peut aussi contenir `matchFields`, qui ne connaît qu'un champ, `metadata.name`.

| Opérateur | Sens | Où |
|---|---|---|
| `In` / `NotIn` | la valeur du label est (n'est pas) dans `values` | nœuds et pods |
| `Exists` / `DoesNotExist` | la clé est présente (absente), sans `values` | nœuds et pods |
| `Gt` / `Lt` | la valeur, lue comme un entier, est supérieure (inférieure) à l'unique élément de `values` | **affinité de nœud seulement** |

`NotIn` et `DoesNotExist` donnent une anti-affinité de nœud ; les taints en sont l'alternative côté nœud (8.7). À l'examen, `kubectl explain pod.spec.affinity.nodeAffinity --recursive` affiche l'arborescence exacte, et la page « Assigning Pods to Nodes » contient un exemple complet à copier.

### 8.5 Affinité et anti-affinité entre pods

`podAffinity` et `podAntiAffinity` placent un pod en fonction des **pods déjà présents** : « mets-moi (ou ne me mets pas) dans un domaine X qui contient déjà un pod correspondant à Y ». Le domaine est défini par `topologyKey`, une clé de label de nœud : `kubernetes.io/hostname` pour « le même nœud », `topology.kubernetes.io/zone` pour « la même zone ». Y est un `labelSelector`, évalué par défaut dans le namespace du pod.

```yaml
spec:
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:              # le terme est ENVELOPPÉ en préféré
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              app: api
    podAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: topology.kubernetes.io/zone   # terme direct en requis
        labelSelector:
          matchLabels:
            app: redis
```

Attention à la structure, qui diffère de l'affinité de nœud : en `required`, la liste contient directement des termes (`topologyKey`, `labelSelector`…) ; en `preferred`, chaque élément contient un `weight` et un `podAffinityTerm`. Les opérateurs se limitent à `In`, `NotIn`, `Exists` et `DoesNotExist`. `topologyKey` est obligatoire et non vide.

Plusieurs champs affinent la sélection. `namespaces` liste des namespaces explicites ; `namespaceSelector` les choisit par labels (un sélecteur vide `{}` désigne **tous** les namespaces) ; les deux s'additionnent. `matchLabelKeys` et `mismatchLabelKeys`, stables depuis 1.33, reprennent la valeur d'un label du pod entrant pour l'ajouter au sélecteur, en égalité ou en différence : `matchLabelKeys: [pod-template-hash]` restreint l'affinité aux pods de la **même révision** d'un Deployment, ce qui évite qu'un rolling update soit gêné par les anciens pods.

Quelques comportements précis sont à connaître. Une anti-affinité **requise** des pods existants est respectée pour les nouveaux venus (symétrie) ; leurs règles **préférées**, non. Le premier pod d'un groupe qui a une affinité requise envers lui-même est accepté même si aucun pod ne correspond encore, pour éviter un blocage. Un nœud dépourvu du label `topologyKey` ne fait partie d'aucun domaine, ce qui produit des effets inattendus : tous les nœuds doivent porter la clé. L'admission `LimitPodHardAntiAffinityTopology`, qui limiterait l'anti-affinité requise à `kubernetes.io/hostname`, est **désactivée** par défaut. Enfin, ces calculs coûtent cher : la documentation les déconseille au-delà de quelques centaines de nœuds.

L'anti-affinité **préférée** sur `kubernetes.io/hostname` est le choix du fil rouge pour `api` : elle étale les pods sur les trois nœuds quand c'est possible, sans jamais bloquer le HPA du chapitre 7 quand il monte à 6 réplicas. Une anti-affinité requise limiterait `api` à 3 pods, un par nœud, et laisserait les suivants `Pending`.

### 8.6 Les contraintes de répartition topologique

`spec.topologySpreadConstraints` répond directement à la question « comment répartir N pods équitablement entre des domaines ? », là où l'anti-affinité ne sait dire que « au plus un par domaine ».

```yaml
spec:
  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway   # DoNotSchedule par défaut
    labelSelector:
      matchLabels:
        app: front
    # minDomains: 2                     # avec DoNotSchedule seulement
    # nodeAffinityPolicy: Honor         # défaut
    # nodeTaintsPolicy: Ignore          # défaut
    # matchLabelKeys: [pod-template-hash]
```

Le **skew** d'un domaine est le nombre de pods correspondants qu'il contient, moins le **minimum global** (le plus petit nombre parmi les domaines éligibles). `maxSkew` (obligatoire, supérieur à 0) borne ce skew. Avec `whenUnsatisfiable: DoNotSchedule` (défaut), c'est un filtre : un nœud dont le domaine dépasserait `maxSkew` est éliminé. Avec `ScheduleAnyway`, c'est un score qui favorise les domaines qui réduisent le déséquilibre.

Les autres champs règlent le calcul :

| Champ | Défaut | Effet |
|---|---|---|
| `minDomains` | se comporte comme 1 | si moins de `minDomains` domaines éligibles existent, le minimum global vaut 0 : force l'étalement sur un nombre minimal de domaines. Seulement avec `DoNotSchedule` (stable depuis 1.30) |
| `nodeAffinityPolicy` | `Honor` | `Honor` : seuls les nœuds compatibles avec le `nodeSelector`/l'affinité du pod comptent comme domaines ; `Ignore` : tous (stable depuis 1.33) |
| `nodeTaintsPolicy` | `Ignore` | `Ignore` : les taints n'excluent aucun nœud du calcul ; `Honor` : les nœuds à taint non tolérée sont exclus (stable depuis 1.33) |
| `matchLabelKeys` | vide | clés de labels du pod entrant dont la valeur est ajoutée au `labelSelector` (bêta, active ; depuis 1.34 l'apiserver **fusionne** explicitement ces paires dans `labelSelector`) |

Plusieurs contraintes se combinent par ET, et une seule contrainte est permise par couple (`topologyKey`, `whenUnsatisfiable`). Seuls les pods du même namespace comptent. Un nœud dépourvu de la clé est ignoré : il ne compte pas dans le calcul et ne reçoit aucun pod soumis à la contrainte, piège classique d'une faute de frappe dans un label. Le `labelSelector` doit correspondre aux labels du pod lui-même, sinon le pod ne se compte pas et les placements s'empilent.

Sur le lab, `zone-a` ne contient que `cka` et `zone-b` contient `cka-m02` et `cka-m03`. Pour les trois pods `front` avec `maxSkew: 1`, les répartitions par zone admissibles sont `[1, 2]` et `[2, 1]`. Après un premier pod en `zone-a` (`[1, 0]`), le second ira en `zone-b` (skew 1 sinon 2) ; le troisième peut aller dans l'une ou l'autre. À l'intérieur de `zone-b`, la contrainte de zone ne dit rien : ce sont les autres scores qui choisissent entre `cka-m02` et `cka-m03`.

Quand un pod ne déclare aucune contrainte et appartient à un Service, un ReplicaSet, un StatefulSet ou un ReplicationController, le scheduler applique des **contraintes par défaut** : `maxSkew: 3` sur `kubernetes.io/hostname` et `maxSkew: 5` sur `topology.kubernetes.io/zone`, toutes deux en `ScheduleAnyway`. Elles se remplacent dans la configuration du plugin `PodTopologySpread`. Rien ne rééquilibre les pods après coup : une réduction d'échelle peut laisser une répartition bancale, que seul un outil externe comme le *descheduler* corrige.

### 8.7 Taints et tolerations

L'affinité attire un pod vers des nœuds ; une **taint** repousse les pods d'un nœud, sauf ceux qui portent une **toleration** correspondante. Une taint a une clé, une valeur facultative et un effet :

| Effet | Pods nouveaux sans toleration | Pods déjà en cours d'exécution sans toleration |
|---|---|---|
| `NoSchedule` | jamais placés | restent |
| `PreferNoSchedule` | évités si possible (score) | restent |
| `NoExecute` | jamais placés | **évincés immédiatement**, ou après `tolerationSeconds` s'ils tolèrent la taint pour une durée limitée |

```bash
kubectl taint node cka-m03 dedie=donnees:NoSchedule        # poser
kubectl taint node cka-m03 dedie=donnees:NoExecute         # même clé, autre effet : deuxième taint
kubectl taint node cka-m03 dedie=analytique:NoSchedule --overwrite   # changer la valeur
kubectl taint node cka-m03 dedie=donnees:NoSchedule-       # retirer une taint précise
kubectl taint node cka-m03 dedie-                          # retirer toutes les taints de clé dedie
kubectl describe node cka-m03 | grep -A3 Taints
```

Une toleration correspond à une taint si les clés et les effets sont égaux et si l'opérateur le permet : `Equal` (défaut) exige la même valeur, `Exists` ignore la valeur (et ne doit pas en avoir). Deux cas particuliers : une clé vide avec `Exists` tolère **toutes** les taints ; un effet vide tolère tous les effets de la clé. `tolerationSeconds` n'est permis qu'avec l'effet `NoExecute`. Les opérateurs numériques `Gt` et `Lt` pour les tolerations existent en alpha depuis 1.35 (feature gate `TaintTolerationComparisonOperators`, désactivée par défaut) : ils ne sont pas utilisables sur un cluster standard 1.37.

```yaml
spec:
  tolerations:
  - key: dedie
    operator: Equal
    value: donnees
    effect: NoSchedule
  - key: dedie
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 60
  - operator: Exists          # tolère tout : réservé aux agents de nœud
```

Le scheduler traite les taints comme un filtre : il retire de la liste des taints du nœud celles que le pod tolère ; s'il en reste une `NoSchedule` ou `NoExecute`, le nœud est exclu ; s'il ne reste que des `PreferNoSchedule`, le nœud est pénalisé. Une toleration **autorise** sans **attirer** : un pod qui tolère `dedie=donnees` peut tout aussi bien atterrir ailleurs. Pour réserver des nœuds à une charge, il faut les deux mécanismes : une taint pour repousser les autres, une affinité de nœud (sur un label posé en même temps) pour attirer celle-ci.

L'éviction `NoExecute` est l'œuvre du *taint-eviction-controller* du kube-controller-manager (séparé du contrôleur de cycle de vie des nœuds depuis 1.29, stable depuis 1.34). Il **supprime** les pods : il ne passe pas par l'API d'éviction, donc **ne respecte pas les PodDisruptionBudgets**, et le pod reçoit la condition `DisruptionTarget` avec la raison `DeletionByTaintManager`. Un pod géré par un contrôleur est recréé ailleurs ; un **pod nu** (sans contrôleur) disparaît définitivement. Avant de poser une taint `NoExecute`, inventorie donc les pods du nœud.

Les tolerations ont une propriété unique : c'est le seul champ d'ordonnancement d'un pod qu'on peut modifier **après sa création**, et seulement par **ajout** (l'apiserver refuse de modifier ou retirer une toleration existante, sauf à réduire son `tolerationSeconds`). On peut ainsi protéger un pod nu d'une taint `NoExecute` imminente.

Pour un DaemonSet, une taint `NoSchedule` non tolérée fait sortir le nœud du nombre désiré sans tuer le pod déjà présent, qui continue de tourner ; une taint `NoExecute` non tolérée l'évince. Le compteur `DESIRED` ne baisse pas pour autant à la pose de la taint : en 1.37, une mise à jour de nœud ne fait resynchroniser le DaemonSet que s'il faut créer ou supprimer un pod, ce qui n'est pas le cas ici. Il reste à 3 jusqu'à la prochaine synchronisation pour une autre raison (un de ses pods supprimé ou modifié, le DaemonSet modifié), où il passe à 2 ; si le pod du nœud tainté a disparu entre-temps, il n'est pas recréé. Les agents de nœud (CNI, kube-proxy, collecteurs de journaux) portent donc en général `operator: Exists` sans clé, comme `agent-noeud` dans le fil rouge.

### 8.8 Les taints posées par le système et les tolerations par défaut

Le plan de contrôle pose et retire lui-même des taints qui traduisent l'état des nœuds. Le scheduler ne lit jamais les conditions d'un nœud, seulement ses taints.

| Taint | Effet | Posée par et quand |
|---|---|---|
| `node.kubernetes.io/not-ready` | `NoSchedule` et `NoExecute` | condition `Ready=False` ; aussi posée en `NoSchedule` à la création de tout nœud par l'admission `TaintNodesByCondition` |
| `node.kubernetes.io/unreachable` | `NoSchedule` et `NoExecute` | condition `Ready=Unknown` (kubelet muet au-delà de `--node-monitor-grace-period`, 50 s) |
| `node.kubernetes.io/unschedulable` | `NoSchedule` | nœud cordonné (`spec.unschedulable: true`) |
| `node.kubernetes.io/memory-pressure`, `disk-pressure`, `pid-pressure` | `NoSchedule` | conditions de pression du kubelet |
| `node.kubernetes.io/network-unavailable` | `NoSchedule` | réseau du nœud non configuré |
| `node.kubernetes.io/out-of-service` | `NoExecute` (posée à la main) | nœud déclaré hors service : suppression forcée des pods et détachement immédiat des volumes |
| `node.cloudprovider.kubernetes.io/uninitialized` | `NoSchedule` | kubelet démarré avec un fournisseur de cloud externe, en attente du cloud-controller-manager |
| `node-role.kubernetes.io/control-plane` | `NoSchedule` | posée par `kubeadm init` sur les nœuds du control plane |

En face, deux mécanismes ajoutent des tolerations sans que tu les écrives. L'admission **`DefaultTolerationSeconds`** ajoute à tout pod qui n'en a pas déjà deux tolerations `NoExecute` de **300 secondes**, pour `node.kubernetes.io/not-ready` et `node.kubernetes.io/unreachable` (réglables par les options `--default-not-ready-toleration-seconds` et `--default-unreachable-toleration-seconds` de l'apiserver). C'est pourquoi les pods d'un nœud qui tombe restent cinq minutes rattachés à lui avant d'être recréés ailleurs :

```bash
kubectl -n boutique get pod outils -o jsonpath='{range .spec.tolerations[*]}{.key}{" "}{.effect}{" "}{.tolerationSeconds}{"\n"}{end}'
```

```
node.kubernetes.io/not-ready NoExecute 300
node.kubernetes.io/unreachable NoExecute 300
```

Le **contrôleur de DaemonSet** ajoute aux pods qu'il crée des tolerations `NoExecute` sans limite de durée pour `not-ready` et `unreachable`, et des tolerations `NoSchedule` pour `memory-pressure`, `disk-pressure`, `pid-pressure`, `unschedulable` et, pour les pods en `hostNetwork`, `network-unavailable`. Les pods de DaemonSet ne sont donc jamais évincés par une panne de nœud et se placent même sur un nœud cordonné. Enfin, selon la documentation, le plan de contrôle ajoute la toleration `memory-pressure` aux pods de classe QoS `Guaranteed` ou `Burstable` : seuls les nouveaux pods `BestEffort` sont tenus à l'écart d'un nœud sous pression mémoire.

> [!info] minikube ≠ examen
> Le nœud `cka` du lab ne porte **aucune** taint (la configuration kubeadm de minikube contient `taints: []`) : les pods ordinaires s'y placent. Sur un cluster kubeadm d'examen, les nœuds du control plane portent `node-role.kubernetes.io/control-plane:NoSchedule`, et un pod sans toleration n'y va jamais. Pour reproduire l'examen, l'exercice 8.5 pose cette taint puis la retire : l'état du fil rouge ne garde aucune taint, car le plugin CSI du [chapitre 15](15-stockage.md) doit pouvoir tourner sur tous les nœuds.

### 8.9 PriorityClass et préemption

La **priorité** d'un pod est un entier : plus il est grand, plus le pod passe tôt dans la file du scheduler, et plus il peut en déloger d'autres. On ne l'écrit pas directement : on référence une **PriorityClass**, objet de portée cluster (`scheduling.k8s.io/v1`, nom court `pc`), et l'admission `Priority` copie sa valeur dans `spec.priority` à la création du pod. Une classe inexistante fait refuser le pod.

```bash
kubectl create priorityclass boutique-critique --value=100000 \
  --description="Pods essentiels de la boutique (api)."
kubectl get priorityclasses
```

Les règles de l'objet sont précises. `value` est un entier 32 bits **inférieur ou égal à 1 000 000 000** ; au-delà, l'espace est réservé aux deux classes système, `system-cluster-critical` (2 000 000 000) et `system-node-critical` (2 000 001 000), et le préfixe `system-` est interdit aux classes utilisateur. `globalDefault: true` fait de la classe la priorité des pods qui n'en demandent aucune ; une seule classe du cluster peut l'avoir, et sans elle ces pods ont la priorité 0. Changer `globalDefault` ou supprimer une classe ne modifie pas les pods existants. `preemptionPolicy` vaut `PreemptLowerPriority` par défaut ; `Never` donne une classe **non préemptive** : ses pods passent devant les autres dans la file mais ne délogent personne.

La **préemption** se déclenche au point d'extension PostFilter, quand aucun nœud ne passe les filtres. Le scheduler cherche un nœud où la suppression de pods **de priorité strictement inférieure** rendrait le pod placable, choisit le moins coûteux (le moins de victimes, les plus basses priorités, en évitant si possible de violer un PodDisruptionBudget), écrit ce nœud dans `status.nominatedNodeName` du pod en attente, puis supprime les victimes. Chaque victime reçoit l'événement `Preempted` (« Preempted by pod <uid> on node <nœud> ») et la condition `DisruptionTarget` de raison `PreemptionByScheduler`, et dispose de son délai de grâce pour s'arrêter. Plusieurs limites sont à connaître : le respect des PDB n'est qu'un « au mieux » (si aucune autre solution n'existe, la préemption les viole) ; le pod n'atterrit pas forcément sur le nœud nommé si un autre se libère entre-temps ; il n'y a pas de préemption entre nœuds (une victime qui gênerait par anti-affinité depuis un autre nœud n'est pas considérée) ; et une affinité envers des pods de priorité inférieure empêche leur préemption.

> [!warning]
> Dans un cluster partagé, rien n'empêche un utilisateur de créer des pods de très haute priorité. La parade est un ResourceQuota à portée `PriorityClass` (8.10), ou la configuration `limitedResources` de l'admission ResourceQuota, qui rend une classe inutilisable dans les namespaces sans quota explicite.

### 8.10 ResourceQuota

Un **ResourceQuota** borne la consommation **cumulée** d'un namespace. Il compte trois familles de ressources :

| Famille | Clés | Remarque |
|---|---|---|
| Calcul | `requests.cpu`, `requests.memory`, `limits.cpu`, `limits.memory` (`cpu` et `memory` = `requests.*`), `hugepages-<taille>`, `requests.<ressource étendue>` | somme sur les pods **non terminés** (ni `Succeeded`, ni `Failed`) |
| Stockage | `requests.storage`, `persistentvolumeclaims`, `<classe>.storageclass.storage.k8s.io/requests.storage`, `…/persistentvolumeclaims`, `requests.ephemeral-storage`, `limits.ephemeral-storage` | par classe de stockage possible |
| Nombre d'objets | `pods`, `services`, `services.loadbalancers`, `services.nodeports`, `configmaps`, `secrets`, `replicationcontrollers`, `resourcequotas`, `persistentvolumeclaims`, et la forme générique `count/<ressource>.<groupe>` (`count/deployments.apps`, `count/jobs.batch`…) | `pods` ne compte que les pods non terminés |

```bash
kubectl -n boutique create quota boutique-quota \
  --hard=requests.cpu=4,requests.memory=4Gi,limits.cpu=8,limits.memory=8Gi,pods=30,services=12,persistentvolumeclaims=6
kubectl -n boutique describe quota boutique-quota
```

La règle qui coûte des points à l'examen : **dès qu'un quota porte sur `cpu` ou `memory` (requests ou limits), chaque nouveau pod du namespace doit déclarer la ressource correspondante pour chacun de ses conteneurs**, sinon il est refusé à l'admission :

```
Error from server (Forbidden): pods "sans-ressources" is forbidden: failed quota: boutique-quota: must specify limits.cpu for: sans-ressources; limits.memory for: sans-ressources; requests.cpu for: sans-ressources; requests.memory for: sans-ressources
```

La liste nomme les **conteneurs** fautifs. La parade est un LimitRange qui fournit des valeurs par défaut (8.11), ou des ressources de niveau pod (bêta en 1.37), qui dispensent de ce contrôle par conteneur. Pour les autres ressources (stockage éphémère notamment), un pod qui ne déclare rien est simplement compté pour zéro.

Le dépassement produit un autre message, `exceeded quota: boutique-quota, requested: requests.cpu=1, used: requests.cpu=3380m, limited: requests.cpu=4`. Un quota ne touche jamais aux objets existants : il ne s'applique qu'aux créations et modifications suivantes. Juste après sa création, et tant que le contrôleur de quotas n'a pas calculé l'usage, les créations sont refusées avec `status unknown for quota` : attends quelques secondes. Et comme les pods d'un Deployment sont créés par son ReplicaSet, un Deployment trop gourmand est **accepté**, mais ses pods n'apparaissent pas : l'erreur est dans `kubectl describe rs`, événement `FailedCreate`.

Les **portées** restreignent ce qu'un quota compte. On les déclare par `spec.scopes` ou, plus finement, par `spec.scopeSelector` (opérateurs `In`, `NotIn`, `Exists`, `DoesNotExist`) :

| Portée | Pods comptés |
|---|---|
| `BestEffort` / `NotBestEffort` | classe QoS `BestEffort` / les autres (`BestEffort` ne peut limiter que le nombre de pods) |
| `Terminating` / `NotTerminating` | pods avec / sans `spec.activeDeadlineSeconds` |
| `PriorityClass` | pods d'une ou plusieurs PriorityClass (`scopeSelector` avec `In`) |
| `CrossNamespacePodAffinity` | pods dont l'affinité utilise `namespaces` ou `namespaceSelector` (un quota `pods: "0"` l'interdit) |
| `VolumeAttributesClass` | PVC qui référencent une VolumeAttributesClass donnée |

### 8.11 LimitRange

Un **LimitRange** agit pod par pod (ou conteneur par conteneur), là où le quota agit sur la somme. Il a deux fonctions : **injecter des valeurs par défaut** (phase mutante de l'admission `LimitRanger`) et **refuser les valeurs hors bornes** (phase de validation). Il n'a pas de générateur `kubectl create` : on l'écrit en YAML.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: boutique-limites
  namespace: boutique
spec:
  limits:
  - type: Container
    default:              # limits injectées si absentes
      cpu: 200m
      memory: 128Mi
    defaultRequest:       # requests injectées si absentes
      cpu: 50m
      memory: 64Mi
    max:                  # aucune limit (ni request) au-dessus
      cpu: "1"
      memory: 1Gi
    # min: …              # aucune request (ni limit) en dessous
    # maxLimitRequestRatio: {cpu: "4"}
```

| `type` | Champs admis | Portée |
|---|---|---|
| `Container` | `default`, `defaultRequest`, `min`, `max`, `maxLimitRequestRatio` | chaque conteneur |
| `Pod` | `min`, `max`, `maxLimitRequestRatio` | somme des conteneurs du pod |
| `PersistentVolumeClaim` | `min`, `max` | `requests.storage` de chaque PVC |

Les valeurs par défaut suivent des règles qu'il faut connaître exactement, car elles surprennent :

| Le conteneur déclare | Résultat |
|---|---|
| rien | request = `defaultRequest`, limit = `default` |
| une request seulement | limit = `default` (si elle est inférieure à la request, le pod est **invalide** : `must be less than or equal to cpu limit`) |
| une limit seulement | request = **la limit** (défaut appliqué par l'API avant l'admission), `defaultRequest` ignoré |
| les deux | rien n'est injecté ; seules les bornes sont vérifiées |

L'admission annote le pod de ce qu'elle a fait, par exemple `kubernetes.io/limit-ranger: 'LimitRanger plugin set: cpu, memory request for container sans-ressources; cpu, memory limit for container sans-ressources'`. Un dépassement de `max` produit `maximum cpu usage per Container is 1, but limit is 2`, et une contrainte `max` exige qu'une limit existe (`No limit is specified`), ce que `default` garantit. Comme le quota, un LimitRange ne touche pas aux pods existants. Avec deux LimitRange dans un namespace, la valeur par défaut retenue n'est pas déterministe : n'en crée qu'un.

LimitRange et ResourceQuota se complètent : le LimitRange garantit que chaque pod déclare des ressources raisonnables, le quota que leur somme reste dans l'enveloppe. Crée toujours le LimitRange **avant** ou **en même temps** que le quota : dans l'intervalle, tout pod sans ressources (y compris ceux d'un CronJob, comme `rapport`) est refusé.

### 8.12 Les contrôleurs d'admission

Les contrôleurs d'admission sont des modules compilés dans l'apiserver. Ils s'activent par `--enable-admission-plugins` (qui **ajoute** à la liste par défaut ; l'ordre de la liste est sans effet, l'ordre d'exécution est fixe) et se désactivent par `--disable-admission-plugins`. En v1.37, d'après le code de l'apiserver et sa référence générée, **25** contrôleurs sont actifs par défaut :

| Rôle | Contrôleurs actifs par défaut en 1.37 |
|---|---|
| Namespaces et comptes | `NamespaceLifecycle` (refuse les créations dans un namespace en cours de suppression ou inexistant), `ServiceAccount` |
| Ressources et ordonnancement | `LimitRanger`, `ResourceQuota`, `Priority`, `DefaultTolerationSeconds`, `TaintNodesByCondition`, `PodTopologyLabels`, `RuntimeClass`, `PodResizeValidator`, `NodeDeclaredFeatureValidator`, `PodGroupProtection` |
| Sécurité | `PodSecurity` |
| Stockage | `DefaultStorageClass`, `PersistentVolumeClaimResize`, `StorageObjectInUseProtection` |
| Réseau | `DefaultIngressClass` |
| Certificats | `CertificateApproval`, `CertificateSigning`, `CertificateSubjectRestriction`, `ClusterTrustBundleAttest` |
| Extension | `MutatingAdmissionPolicy`, `MutatingAdmissionWebhook`, `ValidatingAdmissionPolicy`, `ValidatingAdmissionWebhook` |

> [!note]
> La page « Admission Control in Kubernetes » de la documentation v1.37 ne liste encore que 20 contrôleurs par défaut : il lui manque `ClusterTrustBundleAttest`, `PodGroupProtection`, `PodTopologyLabels`, `NodeDeclaredFeatureValidator` et `PodResizeValidator`. La référence de l'option `--enable-admission-plugins` (page « kube-apiserver ») et le code font foi.

**`NodeRestriction` n'est pas actif par défaut** : kubeadm l'ajoute (`--enable-admission-plugins=NodeRestriction`), et minikube passe une liste explicite qui le contient. Parmi les contrôleurs désactivés par défaut, retiens `AlwaysPullImages`, `LimitPodHardAntiAffinityTopology`, `PodNodeSelector` et `PodTolerationRestriction` (sélecteur de nœuds et tolerations imposés par namespace via annotations), `EventRateLimit` et `DenyServiceExternalIPs`.

Pour savoir ce qui tourne réellement, lis le manifeste du pod statique de l'apiserver (sur le nœud du control plane : `/etc/kubernetes/manifests/kube-apiserver.yaml`, aussi bien sous kubeadm que sous minikube) :

```bash
kubectl -n kube-system get pod kube-apiserver-cka -o yaml | grep admission-plugins
```

```
    - --enable-admission-plugins=NamespaceLifecycle,LimitRanger,ServiceAccount,DefaultStorageClass,DefaultTolerationSeconds,NodeRestriction,MutatingAdmissionWebhook,ValidatingAdmissionWebhook,ResourceQuota
```

Cette liste de minikube s'ajoute aux contrôleurs par défaut : `PodSecurity` ou `Priority`, absents de la ligne, sont bien actifs. Pour activer un contrôleur à l'examen, édite le manifeste sur le nœud du control plane (après en avoir copié une sauvegarde **hors** de `/etc/kubernetes/manifests`), ajoute le nom à `--enable-admission-plugins`, et attends que le kubelet recrée l'apiserver (l'API reste injoignable quelques dizaines de secondes) ; un contrôleur qui a besoin d'un fichier de configuration la reçoit par `--admission-control-config-file`.

### 8.13 Pod Security Admission

Le contrôleur `PodSecurity`, stable depuis 1.25 et actif par défaut, applique les **Pod Security Standards** namespace par namespace. Il a remplacé PodSecurityPolicy, supprimée en 1.25. Les standards définissent trois niveaux cumulatifs :

| Niveau | Principe | Exemples de ce qui est interdit |
|---|---|---|
| `privileged` | aucune restriction | — |
| `baseline` | empêcher les escalades de privilèges connues, sans casser les images courantes | `hostNetwork`, `hostPID`, `hostIPC`, conteneurs `privileged`, volumes `hostPath`, `hostPort` (sauf 0), capacités ajoutées hors d'une liste (`NET_BIND_SERVICE`, `CHOWN`, `KILL`… ; pas `NET_ADMIN`, pas `SYS_PTRACE`), `host` dans les sondes, seccomp `Unconfined`, AppArmor `unconfined`, sysctls non sûrs |
| `restricted` | durcissement complet, au prix de la compatibilité | tout `baseline`, plus : `allowPrivilegeEscalation` différent de `false`, `runAsNonRoot` différent de `true`, `runAsUser: 0`, seccomp absent (exige `RuntimeDefault` ou `Localhost`), capacités non abandonnées (`drop: ["ALL"]` obligatoire, seul `NET_BIND_SERVICE` réajoutable), volumes autres que `configMap`, `csi`, `downwardAPI`, `emptyDir`, `ephemeral`, `persistentVolumeClaim`, `projected`, `secret` |

Chaque namespace choisit un niveau **par mode**, au moyen de labels :

| Mode | Effet d'une violation |
|---|---|
| `enforce` | le **pod** est refusé |
| `warn` | la requête passe, l'utilisateur reçoit un avertissement |
| `audit` | la requête passe, une annotation est ajoutée à l'événement du journal d'audit |

```bash
kubectl label namespace boutique \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted
```

Chaque mode accepte un label de version, `pod-security.kubernetes.io/<mode>-version`, qui fige la définition du niveau à celle d'une version mineure (`v1.37`) ; sans lui, la version est `latest`. La configuration par défaut du contrôleur (fichier d'admission `PodSecurityConfiguration`) applique `privileged` dans les trois modes aux namespaces sans label, et peut déclarer des exemptions par utilisateur, par RuntimeClass ou par namespace.

Le comportement exact sur les objets compte à l'examen. `enforce` ne s'applique **qu'aux pods** : un Deployment non conforme est accepté, et ce sont ses pods que le ReplicaSet ne parvient pas à créer (`FailedCreate` dans `kubectl describe rs`). `warn` et `audit`, eux, s'appliquent aussi aux **modèles de pods** des Deployments, DaemonSets, Jobs et autres, pour signaler les problèmes au plus tôt. Les sous-ressources `exec`, `attach`, `log`, `portforward`, `proxy`, `binding`, `eviction` et `status` ne sont pas évaluées, mais `ephemeralcontainers` l'est.

```
Error from server (Forbidden): pods "hote" is forbidden: violates PodSecurity "baseline:latest": host namespaces (hostNetwork=true)
```

```
Warning: would violate PodSecurity "restricted:latest": allowPrivilegeEscalation != false (container "essai-psa" must set securityContext.allowPrivilegeEscalation=false), unrestricted capabilities (container "essai-psa" must set securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true (pod or container "essai-psa" must set securityContext.runAsNonRoot=true), seccompProfile (pod or container "essai-psa" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

Avant de durcir un namespace, teste l'effet sur les pods existants : quand un label `enforce` est ajouté ou modifié, l'apiserver évalue les pods du namespace et renvoie un avertissement pour chaque violation, et `--dry-run=server` permet de le faire sans rien changer :

```bash
kubectl label --dry-run=server --overwrite namespace boutique pod-security.kubernetes.io/enforce=restricted
```

> [!warning]
> Une fois `boutique` en `enforce=baseline`, deux usages des chapitres suivants y sont refusés. `kubectl debug -it <pod> --image=…` avec le profil par défaut `general` ajoute la capacité `SYS_PTRACE` au conteneur éphémère, interdite en `baseline` : utilise `--profile=baseline` (ou `restricted`). `kubectl debug node/<nœud>` et tout pod en `hostNetwork` ont besoin des espaces de noms de l'hôte : crée-les dans un namespace non restreint, par exemple `-n default`.

### 8.14 Cordon, drain, uncordon et PodDisruptionBudget

#### Les trois commandes

`kubectl cordon` marque le nœud non planifiable (`spec.unschedulable: true`, d'où la taint `node.kubernetes.io/unschedulable:NoSchedule`) sans toucher aux pods présents. `kubectl drain` fait un `cordon` puis **évince** les pods du nœud par l'API d'éviction, qui respecte les PodDisruptionBudgets et les délais de grâce. `kubectl uncordon` rend le nœud planifiable ; les pods évincés **ne reviennent pas** d'eux-mêmes, rien ne rééquilibre le cluster.

`kubectl drain` refuse de démarrer tant que le nœud porte des pods qu'il ne sait pas traiter sans ton accord explicite :

| Pods présents | Erreur sans option | Option | Conséquence |
|---|---|---|---|
| pods de DaemonSet | `cannot delete DaemonSet-managed Pods (use --ignore-daemonsets to ignore)` | `--ignore-daemonsets` | laissés en place (les évincer ne servirait à rien : le contrôleur les recrée sur le nœud) |
| pods avec un volume `emptyDir` | `cannot delete Pods with local storage (use --delete-emptydir-data to override)` | `--delete-emptydir-data` | données de l'`emptyDir` perdues |
| pods nus, sans contrôleur | `cannot delete Pods that declare no controller (use --force to override)` | `--force` | pods **supprimés définitivement** |

Les autres options utiles sont `--grace-period` (remplace le délai de grâce des pods), `--timeout` (abandonne au-delà ; 0, la valeur par défaut, attend indéfiniment), `--pod-selector` (n'évince que les pods sélectionnés), `--dry-run=client|server` (liste ce qui serait fait) et `--disable-eviction` (supprime au lieu d'évincer, **contourne les PDB** : à réserver aux urgences). La commande d'examen typique, avant une mise à jour de nœud, est `kubectl drain <nœud> --ignore-daemonsets --delete-emptydir-data`, plus `--force` si l'énoncé accepte la perte de pods nus.

#### Le PodDisruptionBudget

Un **PodDisruptionBudget** (`policy/v1`, nom court `pdb`, créé au [chapitre 5](05-deployments-et-controleurs.md) pour `front`) protège un ensemble de pods, désigné par `spec.selector`, contre les **perturbations volontaires** qui passent par l'API d'éviction : `kubectl drain`, l'autoscaler de nœuds, l'updater du VPA. Il contient **soit** `minAvailable`, **soit** `maxUnavailable`, en nombre ou en pourcentage (arrondi au supérieur dans les deux cas). Un pod compte comme sain s'il a la condition `Ready=True`.

```bash
kubectl -n boutique get pdb front
```

```
NAME    MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
front   2               N/A               1                     3h
```

`ALLOWED DISRUPTIONS` (`status.disruptionsAllowed`) est le nombre d'évictions accordées à l'instant : pods sains moins `minAvailable`. Quand il vaut 0, l'API d'éviction répond **429 Too Many Requests**, « Cannot evict pod as it would violate the pod's disruption budget. », et `kubectl drain` réessaie toutes les 5 secondes jusqu'à ce qu'un remplaçant soit prêt ailleurs, ou jusqu'à son `--timeout` :

```
evicting pod boutique/front-6f9c7d5b8-2xk4p
error when evicting pods/"front-6f9c7d5b8-2xk4p" -n "boutique" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
```

Un PDB qui n'autorise **aucune** perturbation (`maxUnavailable: 0`, ou `minAvailable` égal au nombre de réplicas) rend le drain impossible tant qu'un de ses pods occupe le nœud : c'est voulu, l'opérateur doit négocier avec l'équipe de l'application. `spec.unhealthyPodEvictionPolicy` règle le cas des pods malades : `IfHealthyBudget` (défaut) n'autorise l'éviction d'un pod non prêt que si le budget est respecté, `AlwaysAllow` l'autorise toujours, ce que la documentation recommande pour qu'une application en panne ne bloque pas une maintenance.

Le PDB ne protège **que** des évictions. Supprimer un pod ou un Deployment, une taint `NoExecute`, la panne d'un nœud ou un `drain --disable-eviction` passent outre. Et la préemption ne le respecte qu'au mieux (8.9).

### 8.15 Pièges courants

```
Piège 1 : OU et ET dans l'affinité de nœud
═══════════════════════════════════════════
  MAUVAIS  : deux nodeSelectorTerms pour exiger « ssd ET zone-b »
  SYMPTÔME : le pod va sur un nœud qui n'a que l'un des deux labels
  BON      : un seul terme, deux matchExpressions (ET)

Piège 2 : Structure de l'anti-affinité préférée
════════════════════════════════════════════════
  MAUVAIS  : preferred… : - topologyKey: …  labelSelector: …
  SYMPTÔME : strict decoding error: unknown field "topologyKey"
  BON      : - weight: 100
               podAffinityTerm: {topologyKey: …, labelSelector: …}

Piège 3 : Toleration sans affinité pour « dédier » des nœuds
═════════════════════════════════════════════════════════════
  MAUVAIS  : seulement une toleration dedie=donnees sur la charge
  SYMPTÔME : les pods tolérants atterrissent aussi ailleurs
  BON      : taint (repousse les autres) + label et affinité de
             nœud (attire la charge)

Piège 4 : Taint NoExecute sur un nœud qui porte des pods nus
═════════════════════════════════════════════════════════════
  SYMPTÔME : le pod nu disparaît pour toujours, PDB ignoré
  BON      : inventorier les pods (ownerReferences), ajouter une
             toleration aux pods nus à garder, ou les recréer ailleurs

Piège 5 : Quota sans LimitRange
════════════════════════════════
  SYMPTÔME : failed quota: … must specify limits.cpu for: …
             (et les Jobs d'un CronJob ne créent plus de pods)
  BON      : LimitRange avec default et defaultRequest AVANT le quota

Piège 6 : Chercher l'erreur d'admission au mauvais endroit
═══════════════════════════════════════════════════════════
  SYMPTÔME : Deployment créé, 0 pod, rien dans describe deploy
  BON      : kubectl describe rs -l app=… → FailedCreate (quota,
             LimitRange, PodSecurity enforce)

Piège 7 : drain avec --force par réflexe, puis oubli d'uncordon
════════════════════════════════════════════════════════════════
  MAUVAIS  : kubectl drain cka-m02 --force, et on passe à la suite
  SYMPTÔME : pods nus détruits sans retour ; nœud resté
             Ready,SchedulingDisabled
  BON      : --ignore-daemonsets --delete-emptydir-data, lire la liste
             des pods nus, --force seulement si l'énoncé l'accepte ;
             kubectl uncordon <nœud> à la fin de la maintenance
```

> [!summary] À retenir
> - Admission (mutation : LimitRanger, Priority, DefaultTolerationSeconds ; validation : PodSecurity, ResourceQuota en dernier) puis ordonnancement (file, filtres, scores pondérés, binding) : un refus d'admission d'un pod de ReplicaSet se lit dans `describe rs`, un refus d'ordonnancement dans `FailedScheduling`.
> - Affinité de nœud : `nodeSelectorTerms` en OU, `matchExpressions` en ET ; `Gt`/`Lt` réservés aux nœuds ; `preferred` = score pondéré de 1 à 100.
> - Affinité entre pods : `topologyKey` obligatoire ; `preferred` enveloppe `podAffinityTerm` ; `matchLabelKeys`/`mismatchLabelKeys` stables depuis 1.33.
> - `topologySpreadConstraints` : skew = pods du domaine − minimum global ; `DoNotSchedule` par défaut, `minDomains` avec lui seulement ; `nodeAffinityPolicy: Honor` et `nodeTaintsPolicy: Ignore` par défaut.
> - Taints : `NoSchedule`, `PreferNoSchedule`, `NoExecute` ; l'éviction `NoExecute` supprime sans PDB ; toleration ajoutable à chaud (ajout seulement) ; `DefaultTolerationSeconds` = 300 s pour `not-ready` et `unreachable`.
> - PriorityClass : valeur ≤ 1 000 000 000 pour l'utilisateur, `globalDefault` unique, `preemptionPolicy: Never` pour une classe non préemptive ; préemption au PostFilter, PDB « au mieux ».
> - Un quota sur cpu/memory exige des ressources sur chaque conteneur ; un LimitRange les fournit ; une limit seule donne une request égale à la limit.
> - 25 contrôleurs d'admission par défaut en 1.37 ; `NodeRestriction` n'en fait pas partie (kubeadm l'ajoute).
> - PSA : niveaux `privileged`/`baseline`/`restricted`, modes `enforce` (pods seulement), `warn` et `audit` (aussi les modèles de pods), labels `pod-security.kubernetes.io/<mode>[-version]`.
> - `drain` = cordon + évictions respectant les PDB (429 et nouvel essai toutes les 5 s) ; `--ignore-daemonsets`, `--delete-emptydir-data`, `--force` (pods nus perdus) ; toujours `uncordon` à la fin.

### 8.16 Exercices

#### Exercice 8.1 — Labels de nœuds et affinité de nœud

**Point de départ** : exercice 7.5.

Pose les labels persistants du fil rouge : `topology.kubernetes.io/zone=zone-a` sur `cka`, `topology.kubernetes.io/zone=zone-b` sur `cka-m02` et `cka-m03`, `disque=ssd` sur `cka-m03`. Crée ensuite dans `boutique` un pod temporaire `affinite-ssd` (`busybox:1.37.0`, `sleep 3600`, labels `app=affinite-ssd` et `tier=outils`) contraint par une affinité de nœud **requise** aux nœuds `disque=ssd`, et un second pod `affinite-nvme`, identique mais contraint à `disque=nvme`. Explique l'état de chacun, puis supprime les deux pods.

> [!example]- Solution
> ```bash
> kubectl label node cka topology.kubernetes.io/zone=zone-a
> kubectl label node cka-m02 cka-m03 topology.kubernetes.io/zone=zone-b
> kubectl label node cka-m03 disque=ssd
> kubectl get nodes -L topology.kubernetes.io/zone,disque
> ```
>
> ```yaml
> # ~/cka/boutique/affinite-ssd.yaml
> apiVersion: v1
> kind: Pod
> metadata:
>   name: affinite-ssd
>   namespace: boutique
>   labels:
>     app: affinite-ssd
>     tier: outils
> spec:
>   affinity:
>     nodeAffinity:
>       requiredDuringSchedulingIgnoredDuringExecution:
>         nodeSelectorTerms:
>         - matchExpressions:
>           - key: disque
>             operator: In
>             values: ["ssd"]
>   containers:
>   - name: busybox
>     image: busybox:1.37.0
>     command: ["sleep", "3600"]
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/affinite-ssd.yaml
> sed -e 's/affinite-ssd/affinite-nvme/g' -e 's/\["ssd"\]/["nvme"]/' \
>   ~/cka/boutique/affinite-ssd.yaml | kubectl apply -f -
> kubectl -n boutique get pods affinite-ssd affinite-nvme -o wide
> kubectl -n boutique describe pod affinite-nvme | sed -n '/Events/,$p'
> kubectl -n boutique get pod affinite-ssd --show-labels
> kubectl -n boutique delete pod affinite-ssd affinite-nvme --now
> ```
>
> `affinite-ssd` tourne sur `cka-m03`, le seul nœud qui porte `disque=ssd`. `affinite-nvme` reste `Pending` : aucun nœud ne passe le filtre NodeAffinity, d'où « 0/3 nodes are available: 3 node(s) didn't match Pod's node affinity/selector. preemption: 0/3 nodes are available: 3 Preemption is not helpful for scheduling. » La préemption ne peut rien y faire : supprimer des pods ne change pas les labels d'un nœud. Les labels de `affinite-ssd` montrent aussi `topology.kubernetes.io/zone=zone-b`, copié du nœud au binding par l'admission `PodTopologyLabels`.
>
> **Vérification** : `kubectl get nodes -L topology.kubernetes.io/zone,disque` affiche `zone-a` pour `cka`, `zone-b` pour les deux autres et `ssd` pour `cka-m03` seulement ; `kubectl -n boutique get pods affinite-ssd affinite-nvme` répond `NotFound` pour les deux.

#### Exercice 8.2 — Répartir `front` entre les zones

**Point de départ** : exercice 8.1.

Ajoute au Deployment `front` une contrainte de répartition sur `topology.kubernetes.io/zone`, avec un skew maximal de 1, qui ne bloque jamais le placement, et qui compte les pods `app=front`. Vérifie la répartition obtenue par zone et calcule le skew.

> [!example]- Solution
> ```yaml
> # ~/cka/boutique/patch-front-repartition.yaml
> spec:
>   template:
>     spec:
>       topologySpreadConstraints:
>       - maxSkew: 1
>         topologyKey: topology.kubernetes.io/zone
>         whenUnsatisfiable: ScheduleAnyway
>         labelSelector:
>           matchLabels:
>             app: front
> ```
>
> ```bash
> kubectl -n boutique patch deployment front --patch-file ~/cka/boutique/patch-front-repartition.yaml
> kubectl -n boutique rollout status deployment front
> kubectl -n boutique get pods -l app=front \
>   -o custom-columns=POD:.metadata.name,NOEUD:.spec.nodeName,ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone
> ```
>
> Le patch modifie le modèle de pods : le Deployment fait un rolling update (maxSurge 1, maxUnavailable 0) et les nouveaux pods sont placés avec la contrainte. `ScheduleAnyway` en fait un score : la contrainte oriente sans jamais laisser un pod `Pending`. Avec une zone d'un nœud et une zone de deux, la répartition attendue est `[1, 2]` ou `[2, 1]` : skew de 1, conforme. Reporte la contrainte dans ton manifeste de `front` pour ne pas la perdre à la prochaine application. La colonne `ZONE` utilise le label copié sur le pod par `PodTopologyLabels`. Juste après la fin du rollout, un ancien pod encore en cours d'arrêt peut figurer dans la liste avec une zone `<none>` : il avait été placé avant la pose des labels de zone, et l'admission ne copie ce label qu'au binding.
>
> **Vérification** : `kubectl -n boutique get deploy front -o jsonpath='{.spec.template.spec.topologySpreadConstraints[0].whenUnsatisfiable}'` affiche `ScheduleAnyway`, la commande `custom-columns` montre 3 pods répartis 1/2 ou 2/1 entre `zone-a` et `zone-b`, et `kubectl -n boutique get deploy front` affiche `3/3`.

#### Exercice 8.3 — PriorityClass et anti-affinité de `api`

**Point de départ** : exercice 8.2.

Crée la PriorityClass `boutique-critique`, de valeur 100000, non globale, décrite par « Pods essentiels de la boutique (api). ». Modifie le Deployment `api` pour que ses pods l'utilisent et préfèrent (poids 100) ne pas partager un nœud avec un autre pod `app=api`. Vérifie la priorité effective des pods et leur répartition.

> [!example]- Solution
> ```bash
> kubectl create priorityclass boutique-critique --value=100000 \
>   --description="Pods essentiels de la boutique (api)." \
>   --dry-run=client -o yaml > ~/cka/boutique/priorityclass.yaml
> kubectl apply -f ~/cka/boutique/priorityclass.yaml
> ```
>
> ```yaml
> # ~/cka/boutique/patch-api-placement.yaml
> spec:
>   template:
>     spec:
>       priorityClassName: boutique-critique
>       affinity:
>         podAntiAffinity:
>           preferredDuringSchedulingIgnoredDuringExecution:
>           - weight: 100
>             podAffinityTerm:
>               topologyKey: kubernetes.io/hostname
>               labelSelector:
>                 matchLabels:
>                   app: api
> ```
>
> ```bash
> kubectl -n boutique patch deployment api --patch-file ~/cka/boutique/patch-api-placement.yaml
> kubectl -n boutique rollout status deployment api
> kubectl -n boutique get pods -l app=api \
>   -o custom-columns=POD:.metadata.name,NOEUD:.spec.nodeName,CLASSE:.spec.priorityClassName,PRIORITE:.spec.priority
> ```
>
> L'admission `Priority` a écrit `spec.priority: 100000` dans chaque nouveau pod. L'anti-affinité est préférée : les deux pods vont sur deux nœuds différents tant que c'est possible, mais rien n'empêche le HPA du chapitre 7 de monter à 6 réplicas sur 3 nœuds. La PriorityClass est de portée cluster : n'importe quel namespace peut l'utiliser, ce que l'exercice suivant exploite.
>
> **Vérification** : `kubectl get pc boutique-critique` affiche `100000` dans `VALUE`, `false` dans `GLOBAL-DEFAULT` et `PreemptLowerPriority` dans `PREEMPTIONPOLICY` (un jsonpath sur `.globalDefault` renverrait une chaîne vide : le générateur n'écrit pas ce champ à `false`, et l'API ne le remplit pas) ; la commande `custom-columns` montre 2 pods `api` sur deux nœuds différents, classe `boutique-critique`, priorité `100000` ; `kubectl -n boutique get hpa api` affiche toujours `REPLICAS 2`.

#### Exercice 8.4 — Observer une préemption

**Point de départ** : exercice 8.3.

Le CPU du lab ne se sature pas (8.2). Fais annoncer au nœud `cka-m02` une ressource étendue `example.com/jeton` de capacité 2. Dans un namespace temporaire `priorites`, crée un Deployment `remplissage` de 2 réplicas (`busybox:1.37.0`, `sleep 3600`, délai de grâce de 5 s) dont chaque pod consomme un jeton, puis un pod `urgent` identique mais de classe `boutique-critique`. Observe ce que fait le scheduler, puis supprime le namespace et la ressource étendue.

> [!example]- Solution
> ```bash
> kubectl patch node cka-m02 --subresource=status --type=json \
>   -p '[{"op":"add","path":"/status/capacity/example.com~1jeton","value":"2"}]'
> kubectl get node cka-m02 -o jsonpath='{.status.allocatable.example\.com/jeton}{"\n"}'
> kubectl create namespace priorites
> ```
>
> ```yaml
> # ~/cka/priorites/remplissage.yaml
> apiVersion: apps/v1
> kind: Deployment
> metadata:
>   name: remplissage
>   namespace: priorites
> spec:
>   replicas: 2
>   selector:
>     matchLabels:
>       app: remplissage
>   template:
>     metadata:
>       labels:
>         app: remplissage
>     spec:
>       terminationGracePeriodSeconds: 5
>       containers:
>       - name: attente
>         image: busybox:1.37.0
>         command: ["sleep", "3600"]
>         resources:
>           limits:
>             example.com/jeton: "1"
> ```
>
> ```yaml
> # ~/cka/priorites/urgent.yaml
> apiVersion: v1
> kind: Pod
> metadata:
>   name: urgent
>   namespace: priorites
> spec:
>   priorityClassName: boutique-critique
>   terminationGracePeriodSeconds: 5
>   containers:
>   - name: attente
>     image: busybox:1.37.0
>     command: ["sleep", "3600"]
>     resources:
>       limits:
>         example.com/jeton: "1"
> ```
>
> ```bash
> kubectl apply -f ~/cka/priorites/remplissage.yaml
> kubectl -n priorites rollout status deployment remplissage   # 2 pods sur cka-m02
> kubectl apply -f ~/cka/priorites/urgent.yaml
> kubectl -n priorites get pods -o wide -w                     # Ctrl+C après 10 s
> kubectl -n priorites get events --field-selector reason=Preempted
> ```
>
> Une ressource étendue n'existe que par sa déclaration dans le statut du nœud ; le kubelet la recopie dans l'allocatable à sa mise à jour de statut suivante (toutes les 10 s) : juste après le patch, la deuxième commande peut encore afficher une ligne vide, relance-la. Une ressource étendue se déclare en limit (la request prend la même valeur) et n'admet pas de surallocation. Les deux pods `remplissage` (priorité 0, aucune classe) occupent les deux jetons. `urgent` ne passe aucun filtre (`Insufficient example.com/jeton` sur les trois nœuds) : le PostFilter cherche des victimes de priorité inférieure, en trouve sur `cka-m02`, nomme ce nœud dans `status.nominatedNodeName` et supprime un pod `remplissage`, qui reçoit l'événement « Preempted by pod … on node cka-m02 ». Cinq secondes plus tard, `urgent` démarre sur `cka-m02`. Le ReplicaSet recrée aussitôt un pod `remplissage`, qui reste `Pending` : il ne peut pas préempter `urgent` (priorité supérieure) ni l'autre `remplissage` (priorité égale).
>
> ```bash
> kubectl delete namespace priorites
> kubectl patch node cka-m02 --subresource=status --type=json \
>   -p '[{"op":"remove","path":"/status/capacity/example.com~1jeton"}]'
> ```
>
> **Vérification** : avant le nettoyage, `kubectl -n priorites get pods` montre `urgent` en `Running` et un pod `remplissage` en `Pending`, et l'événement `Preempted` existe ; après, `kubectl get ns priorites` répond `NotFound` et, au bout de quelques secondes, `kubectl describe node cka-m02 | grep jeton` n'affiche plus rien.

#### Exercice 8.5 — La taint du control plane et la toleration universelle

**Point de départ** : exercice 8.4.

Reproduis le nœud de control plane d'un cluster kubeadm en posant sur `cka` la taint `node-role.kubernetes.io/control-plane:NoSchedule`. Observe l'effet sur le DaemonSet `agent-noeud`, puis donne-lui une toleration `operator: Exists`. Vérifie avec un pod temporaire `sonde-cp` (`busybox:1.37.0`, `sleep 300`) contraint par `nodeSelector` au nœud `cka` qu'un pod ordinaire n'y est plus admis. Retire enfin la taint et le pod.

> [!example]- Solution
> ```bash
> kubectl taint node cka node-role.kubernetes.io/control-plane:NoSchedule
> kubectl -n boutique get ds agent-noeud
> kubectl -n boutique patch daemonset agent-noeud --type=merge \
>   -p '{"spec":{"template":{"spec":{"tolerations":[{"operator":"Exists"}]}}}}'
> kubectl -n boutique rollout status daemonset agent-noeud
> kubectl -n boutique get ds agent-noeud
> kubectl -n boutique run sonde-cp --image=busybox:1.37.0 \
>   --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"cka"}}}' -- sleep 300
> kubectl -n boutique describe pod sonde-cp | sed -n '/Events/,$p'
> kubectl -n boutique delete pod sonde-cp
> kubectl taint node cka node-role.kubernetes.io/control-plane:NoSchedule-
> ```
>
> Juste après la taint, `kubectl -n boutique get ds agent-noeud` affiche toujours `DESIRED 3`, et le pod de `cka` continue de tourner, car `NoSchedule` n'évince rien. Le contrôleur de DaemonSet ne veut pourtant plus de pod sur `cka`, mais il ne recalcule son statut que lorsqu'il a un pod à créer ou à supprimer (8.7) : supprime le pod `agent-noeud` de `cka` et `DESIRED` tombe à 2, sans recréation sur ce nœud. La toleration `operator: Exists` sans clé tolère toutes les taints : après le rolling update du DaemonSet, un pod neuf tourne sur `cka` et `DESIRED` vaut 3 en toute rigueur. Le pod `sonde-cp` reste `Pending` avec « 0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 node(s) didn't match Pod's node affinity/selector. » : le message ne nomme pas la taint, lis-la sur le nœud. Reporte la toleration dans ton manifeste de `agent-noeud`.
>
> **Vérification** : `kubectl -n boutique get ds agent-noeud` affiche `3` en `DESIRED`, `CURRENT` et `READY` ; `kubectl -n boutique get ds agent-noeud -o jsonpath='{.spec.template.spec.tolerations}'` affiche `[{"operator":"Exists"}]` ; `kubectl describe node cka | grep Taints` affiche `Taints: <none>`.

#### Exercice 8.6 — Dédier un nœud, puis le vider par `NoExecute`

**Point de départ** : exercice 8.5.

Pose sur `cka-m03` la taint `dedie=donnees:NoSchedule`, redémarre le Deployment `api` et constate où vont ses pods. Crée dans `boutique` un pod `sursis` (`busybox:1.37.0`, `sleep 3600`, `nodeSelector` `disque: ssd`) qui tolère cette taint, ainsi que la taint `dedie=donnees:NoExecute` pendant 60 secondes. Avant d'ajouter la taint `dedie=donnees:NoExecute`, protège les pods nus de `cka-m03` qui doivent survivre. Observe les évictions, puis retire toutes les taints de clé `dedie`.

> [!example]- Solution
> ```bash
> kubectl taint node cka-m03 dedie=donnees:NoSchedule
> kubectl -n boutique rollout restart deployment api
> kubectl -n boutique rollout status deployment api
> kubectl -n boutique get pods -l app=api -o wide
> ```
>
> ```yaml
> # ~/cka/boutique/sursis.yaml
> apiVersion: v1
> kind: Pod
> metadata:
>   name: sursis
>   namespace: boutique
>   labels:
>     app: sursis
>     tier: outils
> spec:
>   nodeSelector:
>     disque: ssd
>   tolerations:
>   - key: dedie
>     operator: Equal
>     value: donnees
>     effect: NoSchedule
>   - key: dedie
>     operator: Equal
>     value: donnees
>     effect: NoExecute
>     tolerationSeconds: 60
>   containers:
>   - name: busybox
>     image: busybox:1.37.0
>     command: ["sleep", "3600"]
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/sursis.yaml
> kubectl get pods -A --field-selector spec.nodeName=cka-m03 \
>   -o custom-columns=NS:.metadata.namespace,NOM:.metadata.name,PROPRIETAIRE:.metadata.ownerReferences[0].kind
> ```
>
> Les pods dont la colonne `PROPRIETAIRE` vaut `<none>` sont des pods nus : selon les placements, `boutique/outils` et `kube-system/storage-provisioner` peuvent s'y trouver, en plus de `sursis`. Ajoute à chacun d'eux, sauf `sursis`, une toleration (opération d'ajout, la seule permise sur un pod existant) :
>
> ```bash
> kubectl -n boutique patch pod outils --type=json \
>   -p '[{"op":"add","path":"/spec/tolerations/-","value":{"key":"dedie","operator":"Equal","value":"donnees","effect":"NoExecute"}}]'
> # idem pour kube-system/storage-provisioner s'il est sur cka-m03
> kubectl taint node cka-m03 dedie=donnees:NoExecute
> kubectl get pods -A --field-selector spec.nodeName=cka-m03 -o wide
> kubectl -n boutique get pod sursis -w            # Ctrl+C après sa disparition
> kubectl taint node cka-m03 dedie-
> ```
>
> Avec `NoSchedule` seul, les pods déjà présents restent, mais les nouveaux pods `api` du redémarrage ne vont que sur `cka` et `cka-m02` (l'anti-affinité préférée les y étale). La taint `NoExecute` déclenche immédiatement la **suppression** des pods qui ne la tolèrent pas : pods `front` éventuels (recréés ailleurs, sans égard pour le PDB), pods de `kube-system` sans toleration. Restent `agent-noeud` (toleration `Exists`), `calico-node` et `kube-proxy` (qui tolèrent tout), les pods nus protégés, et `sursis`, marqué pour suppression au bout de ses 60 secondes de sursis, puis disparu 30 secondes plus tard (son `sleep` en PID 1 ignore SIGTERM : 94 s en tout sur le lab). Chaque suppression laisse un événement `TaintManagerEviction` (« Marking for deletion Pod boutique/sursis », visible par `kubectl get events -A --field-selector reason=TaintManagerEviction`), et les pods supprimés portent la condition `DisruptionTarget` de raison `DeletionByTaintManager`. Les pods terminés des Jobs de `rapport` présents sur le nœud sont supprimés eux aussi. `kubectl taint node cka-m03 dedie-` retire d'un coup les deux taints de clé `dedie`. Les pods partis ne reviennent pas sur `cka-m03` : rien ne rééquilibre. La toleration ajoutée aux pods nus reste (ajout seulement) ; elle est sans effet sans la taint.
>
> **Vérification** : `kubectl get pods -A --field-selector spec.nodeName=cka-m03` ne liste plus `sursis` mais toujours les pods de DaemonSet ; `kubectl -n boutique get pod outils` est `Running` ; `kubectl get nodes -o custom-columns=NOM:.metadata.name,TAINTS:.spec.taints` affiche `<none>` pour les trois nœuds ; `kubectl -n boutique get deploy` affiche tous les Deployments à jour et prêts.

#### Exercice 8.7 — ResourceQuota et LimitRange

**Point de départ** : exercice 8.6.

Crée dans `boutique` le ResourceQuota `boutique-quota` (requests.cpu 4, requests.memory 4Gi, limits.cpu 8, limits.memory 8Gi, pods 30, services 12, persistentvolumeclaims 6) et constate qu'un pod `sans-ressources` (`busybox:1.37.0`, `sleep 600`, sans `resources`) est refusé. Crée ensuite le LimitRange `boutique-limites` (type `Container` ; par défaut cpu 200m et memory 128Mi en limits, cpu 50m et memory 64Mi en requests ; maximum cpu 1 et memory 1Gi) et recrée `sans-ressources`. Montre enfin qu'un Deployment temporaire `gourmand` de 5 réplicas demandant chacune 1 CPU dépasse le quota, et dis où lire l'erreur. Supprime les objets temporaires.

> [!example]- Solution
> ```bash
> kubectl -n boutique create quota boutique-quota \
>   --hard=requests.cpu=4,requests.memory=4Gi,limits.cpu=8,limits.memory=8Gi,pods=30,services=12,persistentvolumeclaims=6 \
>   --dry-run=client -o yaml > ~/cka/boutique/quota.yaml
> kubectl apply -f ~/cka/boutique/quota.yaml
> kubectl -n boutique describe quota boutique-quota
> kubectl -n boutique run sans-ressources --image=busybox:1.37.0 -- sleep 600
> ```
>
> Le pod est refusé : « failed quota: boutique-quota: must specify limits.cpu for: sans-ressources; limits.memory for: sans-ressources; requests.cpu for: sans-ressources; requests.memory for: sans-ressources ». `describe quota` montre déjà l'usage des pods existants : environ 380m de requests CPU (3 × 50m pour `front`, 2 × 50m pour `api`, 100m pour `outils` redimensionné, 3 × 10m pour `agent-noeud`), 9 pods et 2 Services.
>
> ```yaml
> # ~/cka/boutique/limites.yaml
> apiVersion: v1
> kind: LimitRange
> metadata:
>   name: boutique-limites
>   namespace: boutique
> spec:
>   limits:
>   - type: Container
>     default:
>       cpu: 200m
>       memory: 128Mi
>     defaultRequest:
>       cpu: 50m
>       memory: 64Mi
>     max:
>       cpu: "1"
>       memory: 1Gi
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/limites.yaml
> kubectl -n boutique run sans-ressources --image=busybox:1.37.0 -- sleep 600
> kubectl -n boutique get pod sans-ressources -o jsonpath='{.spec.containers[0].resources}{"\n"}{.metadata.annotations.kubernetes\.io/limit-ranger}{"\n"}'
> ```
>
> ```yaml
> # ~/cka/boutique/gourmand-quota.yaml
> apiVersion: apps/v1
> kind: Deployment
> metadata:
>   name: gourmand
>   namespace: boutique
> spec:
>   replicas: 5
>   selector:
>     matchLabels:
>       app: gourmand
>   template:
>     metadata:
>       labels:
>         app: gourmand
>         tier: outils
>     spec:
>       containers:
>       - name: busybox
>         image: busybox:1.37.0
>         command: ["sleep", "3600"]
>         resources:
>           requests:
>             cpu: "1"
>           limits:
>             cpu: "1"
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/gourmand-quota.yaml
> kubectl -n boutique get deploy gourmand
> kubectl -n boutique describe rs -l app=gourmand | sed -n '/Events/,$p'
> kubectl -n boutique delete deployment gourmand
> kubectl -n boutique delete pod sans-ressources
> ```
>
> Le LimitRanger a injecté requests 50m/64Mi et limits 200m/128Mi, et l'a noté dans l'annotation `kubernetes.io/limit-ranger` : le second essai passe le quota. `gourmand` ne déclare pas de mémoire : le LimitRange la complète, et chaque pod demande 1 CPU, à la limite du `max`. Le Deployment est créé, mais seuls 3 pods apparaissent : le quatrième porterait les requests CPU à environ 4,4 cœurs, au-delà des 4 autorisés. L'erreur est dans les événements du **ReplicaSet** (`FailedCreate` … « exceeded quota: boutique-quota, requested: requests.cpu=1, used: requests.cpu=3430m, limited: requests.cpu=4 », chiffres selon l'usage du moment), pas dans ceux du Deployment, qui affiche seulement `3/5`. Le contrôleur de quotas recompte l'usage à chaque suppression.
>
> **Vérification** : `kubectl -n boutique get quota boutique-quota -o jsonpath='{.spec.hard}'` affiche les sept valeurs demandées ; `kubectl -n boutique get limitrange boutique-limites -o jsonpath='{.spec.limits[0].max}'` affiche `{"cpu":"1","memory":"1Gi"}` ; `kubectl -n boutique get deploy gourmand` et `kubectl -n boutique get pod sans-ressources` répondent `NotFound`.

#### Exercice 8.8 — Pod Security Admission sur `boutique`

**Point de départ** : exercice 8.7.

Vérifie d'abord, sans rien modifier, si les pods de `boutique` respecteraient le niveau `baseline`, puis le niveau `restricted`. Applique ensuite au namespace : `enforce=baseline`, `warn=restricted`, `audit=restricted`. Montre qu'un pod `hote` en `hostNetwork` est refusé, qu'un pod `essai-psa` ordinaire passe avec un avertissement, et qu'un pod `conforme` qui respecte `restricted` passe sans avertissement. Supprime les pods de test.

> [!example]- Solution
> ```bash
> kubectl label --dry-run=server --overwrite namespace boutique pod-security.kubernetes.io/enforce=baseline
> kubectl label --dry-run=server --overwrite namespace boutique pod-security.kubernetes.io/enforce=restricted
> kubectl label namespace boutique \
>   pod-security.kubernetes.io/enforce=baseline \
>   pod-security.kubernetes.io/warn=restricted \
>   pod-security.kubernetes.io/audit=restricted
> kubectl -n boutique run hote --image=busybox:1.37.0 \
>   --overrides='{"spec":{"hostNetwork":true}}' -- sleep 600
> kubectl -n boutique run essai-psa --image=busybox:1.37.0 -- sleep 600
> ```
>
> Le premier essai à blanc ne renvoie aucun avertissement : les pods du fil rouge respectent `baseline`. Le second renvoie un en-tête, `Warning: existing pods in namespace "boutique" violate the new PodSecurity enforce level "restricted:latest"`, puis une ligne par groupe de pods aux violations identiques, ici une seule pour tous : `Warning: agent-noeud-… (and 9 other pods): allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile` (le nombre dépend des pods présents). Aucun conteneur du fil rouge ne déclare `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]` ni de profil seccomp. `hote` est refusé (« violates PodSecurity "baseline:latest": host namespaces (hostNetwork=true) »). `essai-psa` est créé, avec l'avertissement `would violate PodSecurity "restricted:latest": …`.
>
> ```yaml
> # ~/cka/boutique/conforme.yaml
> apiVersion: v1
> kind: Pod
> metadata:
>   name: conforme
>   namespace: boutique
>   labels:
>     app: conforme
>     tier: outils
> spec:
>   securityContext:
>     runAsNonRoot: true
>     runAsUser: 1000
>     seccompProfile:
>       type: RuntimeDefault
>   containers:
>   - name: busybox
>     image: busybox:1.37.0
>     command: ["sleep", "600"]
>     securityContext:
>       allowPrivilegeEscalation: false
>       capabilities:
>         drop: ["ALL"]
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/conforme.yaml
> kubectl -n boutique delete pod essai-psa conforme
> ```
>
> `conforme` passe sans avertissement : chaque contrôle de `restricted` est satisfait au niveau du pod ou du conteneur, et les ressources viennent du LimitRange. Retiens que `enforce` ne vise que les pods : un Deployment au modèle non conforme serait accepté, avec seulement l'avertissement `warn`, et ses pods refusés au niveau du ReplicaSet.
>
> **Vérification** : `kubectl get ns boutique --show-labels` montre les trois labels `pod-security.kubernetes.io/enforce=baseline`, `warn=restricted` et `audit=restricted` ; `kubectl -n boutique get pods hote essai-psa conforme` répond `NotFound` pour les trois.

#### Exercice 8.9 — Drain de `cka-m02` bloqué par le PDB

**Point de départ** : exercice 8.8.

Regroupe d'abord les trois pods `front` sur `cka-m02`. Rends ensuite temporairement le PDB `front` impossible à satisfaire (minAvailable 3) et lance un drain de `cka-m02` limité à 45 secondes, en épargnant les pods nus `outils` et `storage-provisioner` ; explique l'échec. Remets le PDB à minAvailable 2, termine le drain, puis remets le nœud en service. Vérifie enfin l'état complet du fil rouge à la fin du chapitre.

> [!example]- Solution
> ```bash
> kubectl cordon cka
> kubectl cordon cka-m03
> kubectl -n boutique rollout restart deployment front
> kubectl -n boutique rollout status deployment front
> kubectl uncordon cka
> kubectl uncordon cka-m03
> kubectl -n boutique get pods -l app=front -o wide         # les 3 sur cka-m02
> kubectl -n boutique patch pdb front --type=merge -p '{"spec":{"minAvailable":3}}'
> kubectl -n boutique get pdb front                         # ALLOWED DISRUPTIONS 0
> kubectl drain cka-m02 --ignore-daemonsets --delete-emptydir-data \
>   --pod-selector='app!=outils,integration-test!=storage-provisioner' --timeout=45s
> ```
>
> Avec `cka` et `cka-m03` cordonnés, le rolling update ne peut placer les nouveaux pods `front` que sur `cka-m02` : `ScheduleAnyway` cède. Le `rollout restart` affiche au passage l'avertissement `Warning: would violate PodSecurity "restricted:latest": …` pour le conteneur `nginx` : c'est le mode `warn=restricted` posé en 8.8, qui examine aussi les modèles de pods ; rien n'est refusé. Avec `minAvailable: 3` pour 3 pods, `ALLOWED DISRUPTIONS` vaut 0 : chaque éviction d'un pod `front` reçoit un 429, et `kubectl drain` affiche toutes les 5 secondes « error when evicting pods/"front-…" -n "boutique" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget. », jusqu'à l'échec par « global timeout reached: 45s ». Les autres pods du nœud (pods `api`, `metrics-server` s'il y est) ont été évincés et recréés ailleurs ; le nœud reste cordonné. Le sélecteur `app!=outils,integration-test!=storage-provisioner` exclut du drain les deux pods nus du lab, que `--force` détruirait sans retour : à l'examen, tu utiliserais `--force` si l'énoncé l'accepte.
>
> ```bash
> kubectl -n boutique patch pdb front --type=merge -p '{"spec":{"minAvailable":2}}'
> kubectl drain cka-m02 --ignore-daemonsets --delete-emptydir-data \
>   --pod-selector='app!=outils,integration-test!=storage-provisioner' --timeout=180s
> kubectl get node cka-m02
> kubectl uncordon cka-m02
> ```
>
> Avec `minAvailable: 2`, une éviction est permise à la fois : le premier pod `front` part, son remplaçant démarre sur `cka` ou `cka-m03` (le nœud drainé est cordonné), et dès qu'il est prêt, le budget autorise l'éviction suivante. Les 429 intermédiaires sont normaux. Le drain se termine par `node/cka-m02 drained` ; le nœud affiche `Ready,SchedulingDisabled` jusqu'au `uncordon`.
>
> État du fil rouge à la fin du chapitre (instantané **I1**) :
>
> ```bash
> kubectl get nodes -L topology.kubernetes.io/zone,disque
> kubectl get nodes -o custom-columns=NOM:.metadata.name,TAINTS:.spec.taints
> kubectl get pc boutique-critique
> kubectl get ns boutique --show-labels
> kubectl -n boutique get hpa,pdb,quota,limitrange
> kubectl -n boutique get deploy,ds,cronjob,pods
> ```
>
> **Vérification** : `kubectl -n boutique get pdb front` affiche `MIN AVAILABLE 2` et `ALLOWED DISRUPTIONS 1` ; `kubectl get nodes` montre les trois nœuds `Ready` sans `SchedulingDisabled` ; la colonne `TAINTS` vaut `<none>` pour `cka`, `cka-m02` et `cka-m03` ; les labels de zone et `disque=ssd` sont en place ; `boutique` contient le HPA `api`, le PDB `front`, `boutique-quota`, `boutique-limites` et les labels Pod Security ; `front` (3/3), `api` (2/2) et `agent-noeud` (3 pods) sont prêts et `outils` est `Running`.

---
