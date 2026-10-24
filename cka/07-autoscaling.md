---
title: "CKA — 7. Ressources et autoscaling"
description: "Le pipeline des métriques de ressources, metrics-server et kubectl top, l'algorithme exact du HorizontalPodAutoscaler v2 (tolérance configurable, fenêtres de stabilisation, policies, conditions), le VPA et le Cluster Autoscaler, appliqués au Deployment api de la boutique."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 7. Ressources et autoscaling

Un cluster bien dimensionné un lundi matin ne l'est plus le vendredi soir. Kubernetes propose trois réponses à la variation de charge : ajouter des pods (autoscaling horizontal), agrandir ceux qui existent (autoscaling vertical), ajouter des nœuds (autoscaling de cluster). Toutes reposent sur la même matière première : des mesures de consommation CPU et mémoire, rapportées aux `requests` que tu as déclarées. Ce chapitre suit cette matière de bout en bout. Il part du kubelet qui mesure, passe par metrics-server qui agrège et par l'API `metrics.k8s.io` qui expose, puis décortique le contrôleur HorizontalPodAutoscaler jusqu'à la dernière ligne de son algorithme : formule, tolérance, pods pas encore prêts, fenêtres de stabilisation, politiques de vitesse, conditions d'état. Il termine par le Vertical Pod Autoscaler et le Cluster Autoscaler, que le CKA demande de comprendre sans les installer.

Le programme v1.37 y consacre explicitement la compétence *Configure workload autoscaling* (domaine *Workloads and Scheduling*), et le chapitre couvre aussi la partie « mesure » de *Monitor cluster and application resource usage* (domaine *Troubleshooting*, approfondie au [chapitre 21](21-journaux-et-metriques.md)). À l'examen, la tâche type tient en une phrase : « crée un HPA pour tel Deployment, entre 2 et 6 réplicas, 50 % de CPU, avec une fenêtre de stabilisation de descente de 30 secondes ». Elle se fait en deux minutes si tu connais le chemin le plus court et les champs exacts ; elle coûte dix minutes et des points si tu cherches `behavior` dans la documentation. Les requests et limits elles-mêmes, les classes QoS et le redimensionnement en place des pods sont traités au [chapitre 4](04-pods.md) : ce chapitre s'en sert sans les répéter.

### 7.1 Trois boucles pour une même question

Les trois mécanismes d'autoscaling ne se concurrencent pas : ils agissent à des niveaux différents et se passent le relais.

```
          LES TROIS BOUCLES D'AUTOSCALING
═══════════════════════════════════════════════════════════════════

  charge ↑
     │
     ▼
  ┌──────────────────────────┐   modifie spec.replicas
  │ HPA (contrôleur intégré, │──────────────────────────▶ Deployment
  │ kube-controller-manager) │   via la sous-ressource      │
  └──────────────────────────┘   /scale                     ▼
                                                     nouveaux pods
  ┌──────────────────────────┐   modifie les requests       │
  │ VPA (add-on, 3 composants│──────────────────────────▶   │
  │ + CRD)                   │   (éviction ou resize)       ▼
  └──────────────────────────┘                     pods Pending faute
                                                   de place sur les nœuds
  ┌──────────────────────────┐   crée / supprime            │
  │ Cluster Autoscaler ou    │◀─────────────────────────────┘
  │ Karpenter (add-on, lié au│   des machines chez le fournisseur
  │ fournisseur de cloud)    │──────────────────────────▶ nouveaux nœuds
  └──────────────────────────┘
```

| | HPA | VPA | Cluster Autoscaler / Karpenter |
|---|---|---|---|
| Ce qui change | nombre de réplicas | requests (et limits) des conteneurs | nombre de nœuds |
| Où il vit | kube-controller-manager (intégré) | add-on : recommender, updater, admission-controller | add-on, intégré au fournisseur de cloud |
| API | `autoscaling/v2`, GA | CRD `autoscaling.k8s.io/v1` | configuration propre à l'outil |
| Signal | métriques (utilisation rapportée aux requests, ou valeurs) | historique de consommation, OOM | pods `Pending` non planifiables ; requests des pods |
| À l'examen | à créer et dépanner | à comprendre | à comprendre |

Le dernier rang du tableau fixe tes priorités : le HPA doit être un réflexe, les deux autres une culture solide.

### 7.2 Ce que les requests deviennent pour l'autoscaling

Le [chapitre 4.6](04-pods.md) a montré le double rôle des ressources d'un conteneur : la `request` est une réservation comptée par le scheduler, la `limit` une borne imposée par le noyau (quota CFS pour le CPU, OOM kill pour la mémoire). L'autoscaling ajoute un troisième rôle à la request : elle devient le **dénominateur** de l'utilisation.

Quand un HPA vise `averageUtilization: 50` sur le CPU, il ne vise pas 50 % d'un cœur ni 50 % de la limite, mais 50 % de la request. Pour un pod `api` (requests `cpu: 50m`), la cible est donc 25 millicœurs en moyenne. Deux conséquences en découlent. D'abord, l'utilisation peut dépasser 100 % : un pod `api` qui consomme 200m (permis par sa limite de 500m) affiche 400 %. Ensuite, une request mal choisie fausse tout l'autoscaling : trop basse, le HPA ajoute des pods au moindre frémissement ; trop haute, il ne réagit jamais.

Le contrôleur calcule la request d'un pod en additionnant celles de **tous** ses conteneurs, y compris les sidecars natifs (init containers en `restartPolicy: Always`). Si un seul conteneur n'a pas de request pour la ressource suivie, le calcul échoue pour tout le HPA, avec l'erreur `missing request for cpu in container X of Pod Y`. C'est un piège réel : ajouter à un Deployment un sidecar sans requests suffit à casser un HPA qui fonctionnait. Les ressources de niveau pod (`spec.resources`, bêta et activées en 1.37) changent la donne : si elles sont renseignées et que le HPA ne cible pas un conteneur précis, c'est la request du pod qui sert de dénominateur.

> [!tip] Réflexe d'examen
> Un HPA en `<unknown>` alors que metrics-server répond : regarde d'abord les requests de **chaque** conteneur du pod (`kubectl get deploy X -o jsonpath='{.spec.template.spec.containers[*].resources}'`). Un LimitRange avec `defaultRequest` (chapitre 8.11) protège un namespace entier de cet oubli.

### 7.3 Le pipeline des métriques de ressources

Les métriques qu'utilisent le HPA, le VPA et `kubectl top` suivent un chemin précis, et chaque maillon est une cause de panne possible.

```
          PIPELINE DES MÉTRIQUES DE RESSOURCES
═══════════════════════════════════════════════════════════════════

  NŒUD (chacun)
  ┌──────────────────────────────────────────────┐
  │ containerd ──▶ cgroups ──▶ cAdvisor (intégré │
  │                            au kubelet)       │
  │ kubelet :10250  /metrics/resource            │◀─┐ HTTPS, toutes les
  └──────────────────────────────────────────────┘  │ --metric-resolution
                                                    │ (15 s en amont,
  ┌──────────────────────────────────────────────┐  │  60 s sous minikube)
  │ metrics-server (Deployment, kube-system)     │──┘
  │  garde en mémoire les DERNIERS points        │
  │  aucune historisation                        │
  └──────────────────┬───────────────────────────┘
                     │ enregistré par l'APIService
                     │ v1beta1.metrics.k8s.io
                     ▼
  ┌──────────────────────────────────────────────┐
  │ kube-apiserver — couche d'agrégation         │
  │ /apis/metrics.k8s.io/v1beta1/nodes           │
  │ /apis/metrics.k8s.io/v1beta1/namespaces/…/pods│
  └───────┬──────────────────┬──────────────┬────┘
          ▼                  ▼              ▼
     HPA (controller-   VPA recommender   kubectl top
     manager, v1beta1   (add-on)          (préfère v1,
     seulement)                           repli sur v1beta1)
```

Le kubelet mesure la consommation à partir des cgroups (via cAdvisor, intégré au kubelet) et l'expose sur son point `/metrics/resource`. metrics-server interroge chaque kubelet à intervalle fixe, garde les derniers échantillons en mémoire et les sert à travers l'API d'agrégation : il s'enregistre auprès de l'apiserver par un objet APIService, et l'apiserver lui relaie toute requête sur le groupe `metrics.k8s.io`. Rien n'est stocké dans etcd, rien n'est historisé : metrics-server est une source pour l'autoscaling, pas un outil de supervision (son propre README le déconseille explicitement comme source de monitoring).

Deux définitions comptent pour lire les chiffres. Le **CPU** est un taux : la dérivée d'un compteur cumulé de temps CPU sur une fenêtre (champ `window` de la réponse), exprimée en cœurs. La **mémoire** est le *working set* au moment de la mesure : la mémoire anonyme plus une part du cache de pages que le noyau ne peut pas toujours récupérer. C'est aussi la mesure que le kubelet compare à ses seuils d'éviction ; elle dépasse donc souvent le RSS affiché dans le conteneur.

Kubernetes 1.37 a promu l'API `metrics.k8s.io/v1`, strictement identique à `v1beta1`. Mais metrics-server v0.9.0, la version courante et celle de l'addon minikube, ne sert encore que `v1beta1`, et le contrôleur HPA ne sait lire que `v1beta1`. `kubectl top` essaie `v1` puis se replie sur `v1beta1`, ce qui le rend transparent. Le piège est ailleurs : la page « Resource metrics pipeline » de la documentation v1.37 donne ses exemples en `v1` ; recopiés tels quels sur un cluster équipé de metrics-server v0.9.0, ils échouent en `NotFound`. Interroge `v1beta1` :

```bash
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes/cka-m02 | python3 -m json.tool
kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/boutique/pods | python3 -m json.tool
```

### 7.4 metrics-server : installation, options, diagnostic

#### Installation

Sur un cluster vierge, la méthode officielle applique le manifeste de la dernière version publiée :

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

Le manifeste crée dans `kube-system` un ServiceAccount, des rôles RBAC (dont `get` sur `nodes/metrics`, la sous-ressource qui donne accès au point `/metrics/resource` des kubelets), un Service, un Deployment et l'APIService `v1beta1.metrics.k8s.io` (avec `insecureSkipTLSVerify: true`, `groupPriorityMinimum: 100`, `versionPriority: 100`). La matrice de compatibilité du projet associe metrics-server 0.9.x à Kubernetes 1.34 et plus. Sous minikube, l'addon fait la même chose en une commande :

```bash
minikube -p cka addons enable metrics-server
```

Les deux installations ne passent pas les mêmes options au conteneur :

| Option | Manifeste amont v0.9.0 | Addon minikube v1.39.0 | Rôle |
|---|---|---|---|
| `--secure-port` | `10250` | `4443` | port HTTPS de metrics-server lui-même |
| `--metric-resolution` | `15s` | **`60s`** | intervalle entre deux collectes |
| `--kubelet-preferred-address-types` | `InternalIP,ExternalIP,Hostname` | idem | adresse utilisée pour joindre chaque kubelet |
| `--kubelet-use-node-status-port` | oui | oui | port lu dans `node.status.daemonEndpoints.kubeletEndpoint.port` |
| `--kubelet-insecure-tls` | **non** | **oui** | ne pas vérifier le certificat de service des kubelets |
| `--cert-dir` | `/tmp` | `/tmp` | certificats autosignés de metrics-server |

#### Pourquoi `--kubelet-insecure-tls` existe

metrics-server parle aux kubelets en HTTPS et vérifie par défaut leur certificat de **service** (celui que présente le kubelet sur le port 10250). Or un kubelet installé par kubeadm ou minikube génère par défaut un certificat de service **autosigné**, que la CA du cluster ne connaît pas. La vérification échoue et metrics-server journalise des erreurs `x509: cannot validate certificate`. Deux solutions : désactiver la vérification par `--kubelet-insecure-tls` (ce que fait minikube, acceptable pour un lab, pas pour la production), ou activer `serverTLSBootstrap: true` dans la configuration des kubelets pour qu'ils demandent un certificat signé par la CA du cluster, au prix d'une approbation manuelle de leurs CertificateSigningRequest (le mécanisme des CSR est au [chapitre 16.3](16-rbac-et-authentification.md)).

#### Diagnostic

Trois commandes couvrent l'essentiel des pannes de la chaîne :

```bash
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl -n kube-system get deploy metrics-server
kubectl -n kube-system logs deploy/metrics-server --tail=20
```

```
NAME                     SERVICE                      AVAILABLE   AGE
v1beta1.metrics.k8s.io   kube-system/metrics-server   True        2m
```

Une colonne `AVAILABLE` à `False (MissingEndpoints)` signifie que le pod n'est pas prêt ; `False (FailedDiscoveryCheck)` que l'apiserver n'arrive pas à le joindre (réseau, NetworkPolicy). Côté client, `error: Metrics API not available` traduit un APIService indisponible, et `error: metrics not available yet` une API qui répond sans avoir encore de points pour l'objet demandé : il faut au moins une collecte complète après le démarrage du pod.

> [!info] minikube ≠ examen
> Sous minikube, l'addon collecte toutes les **60 s** (`--metric-resolution=60s`) et ignore la vérification TLS des kubelets. Sur le lab, `kubectl top nodes` répond environ une minute après `addons enable` (63 s et 69 s selon les mesures, voir l'exercice 7.1), et à nouveau environ une minute après chaque `minikube -p cka start`. Sur un cluster d'examen installé avec le manifeste amont, la collecte a lieu toutes les **15 s** ; metrics-server y est généralement déjà installé, et l'énoncé le dit s'il faut l'installer.

### 7.5 kubectl top

`kubectl top` est le seul client de l'API de métriques que tu utiliseras à l'examen. Il a deux sous-commandes :

```bash
kubectl top nodes                                   # tous les nœuds
kubectl top nodes --sort-by=cpu --no-headers        # tri : cpu ou memory
kubectl top nodes --show-capacity                   # % rapportés à la capacité
kubectl top pods -n boutique                        # pods d'un namespace
kubectl top pods -A --sort-by=memory                # tous les namespaces
kubectl top pods -n boutique -l app=api --containers   # détail par conteneur
kubectl top pods -n boutique --sum                  # ligne de total
```

Les pourcentages de `kubectl top nodes` sont calculés par défaut sur l'**allocatable** du nœud (capacité moins réservations du système et du kubelet), et sur la capacité brute avec `--show-capacity`. `kubectl top pods` n'affiche aucun pourcentage : les valeurs sont absolues, en millicœurs et en Mio.

```
NAME      CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)
cka       110m         1%       1081Mi          3%
cka-m02   45m          0%       481Mi           1%
cka-m03   62m          0%       479Mi           1%
```

> [!info] minikube ≠ examen
> Sous le pilote docker, chaque nœud minikube annonce la capacité de **l'hôte** : sur le poste de référence, `cpu: 8` et `memory: 32019572Ki` pour chacun des trois nœuds, allocatable identique. Les pourcentages de `kubectl top nodes` sont donc calculés sur 8 cœurs et 32 Gio par nœud, alors que les trois nœuds se partagent en réalité ces mêmes ressources : 1081Mi s'affichent 3 %. Sur un cluster kubeadm, chaque nœud annonce les ressources de sa propre VM et les pourcentages ont leur sens habituel. Ne tire aucune conclusion de saturation des pourcentages minikube ; lis les valeurs absolues.

La tâche d'examen classique sur `top` demande un nom, pas une analyse : « écris dans `/opt/resultat.txt` le nom du pod du namespace X qui consomme le plus de CPU ». `--sort-by` trie par ordre décroissant, `--no-headers` supprime la ligne d'en-tête :

```bash
kubectl top pods -n boutique --sort-by=cpu --no-headers | head -1 | awk '{print $1}' > /opt/resultat.txt
```

### 7.6 Le HorizontalPodAutoscaler : objet et boucle de contrôle

Le HPA est à la fois un objet de l'API (groupe `autoscaling`, version stable `v2` ; la `v1` reste servie mais ne connaît que le CPU) et un contrôleur intégré au kube-controller-manager. Le contrôleur ne touche jamais aux pods : il écrit le nombre de réplicas souhaité dans la sous-ressource `scale` de sa cible, désignée par `spec.scaleTargetRef`. Toute ressource qui expose `/scale` peut donc être autoscalée : Deployment, ReplicaSet, StatefulSet, ReplicationController, et les ressources personnalisées dont la CRD déclare la sous-ressource `scale` (chapitre 18.5.4). Un DaemonSet ne l'expose pas : il n'a pas de nombre de réplicas.

```
     UNE ITÉRATION DU CONTRÔLEUR HPA (toutes les 15 s)
═══════════════════════════════════════════════════════════════════

  1. lire /scale de la cible ───▶ réplicas actuels + sélecteur de pods
         │ échec ⇒ AbleToScale=False (FailedGetScale)
         ▼
  2. pour CHAQUE métrique de spec.metrics :
       lire les mesures (metrics.k8s.io, custom…, external…)
       écarter / corriger les pods non prêts, sans mesure
       ⇒ un nombre de réplicas proposé
         │ échec ⇒ ScalingActive=False (FailedGet…Metric)
         ▼
  3. garder la PLUS GRANDE proposition
         ▼
  4. stabilisation (fenêtre) ──▶ policies de vitesse ──▶ [min, max]
         │                                     ScalingLimited=True
         ▼                                     si une borne a mordu
  5. écrire /scale si le résultat diffère ──▶ événement SuccessfulRescale
```

Les réglages globaux de la boucle sont des options du kube-controller-manager, modifiables uniquement par l'administrateur du cluster :

| Option de kube-controller-manager | Défaut | Effet |
|---|---|---|
| `--horizontal-pod-autoscaler-sync-period` | `15s` | période de la boucle |
| `--horizontal-pod-autoscaler-tolerance` | `0.1` | tolérance par défaut (7.9) |
| `--horizontal-pod-autoscaler-downscale-stabilization` | `5m0s` | fenêtre de stabilisation de descente par défaut (7.8) |
| `--horizontal-pod-autoscaler-cpu-initialization-period` | `5m0s` | période après le démarrage d'un pod où ses mesures CPU sont suspectes (7.7) |
| `--horizontal-pod-autoscaler-initial-readiness-delay` | `30s` | délai pendant lequel un pod non prêt est considéré « en cours d'initialisation » (7.7) |
| `--concurrent-horizontal-pod-autoscaler-syncs` | `5` | HPA traités en parallèle |

#### Les cinq types de métriques

`spec.metrics` est une liste ; chaque élément a un `type` et la sous-structure du même nom.

| `type` | Source | Types de cible (`target.type`) | Exemple |
|---|---|---|---|
| `Resource` | `metrics.k8s.io` : CPU ou mémoire des pods | `Utilization` (`averageUtilization`, en % de la request) ou `AverageValue` (`averageValue`) | CPU à 50 % |
| `ContainerResource` | idem, mais un seul conteneur du pod (GA depuis 1.30) | idem, plus le champ `container` | CPU du conteneur `agnhost` seulement, sidecar ignoré |
| `Pods` | `custom.metrics.k8s.io`, métrique par pod | `AverageValue` seulement | requêtes par seconde par pod |
| `Object` | `custom.metrics.k8s.io`, métrique d'un autre objet du namespace | `Value` ou `AverageValue` (divisée par le nombre de pods) | requêtes par seconde d'un Ingress |
| `External` | `external.metrics.k8s.io`, hors cluster | `Value` ou `AverageValue` | messages en attente dans une file |

Les types `Pods`, `Object` et `External` exigent un adaptateur (Prometheus Adapter, KEDA…) qui sert les API `custom.metrics.k8s.io` ou `external.metrics.k8s.io`. À l'examen, tu ne rencontreras en pratique que `Resource`, avec `Utilization` sur le CPU ou `AverageValue` sur la mémoire.

### 7.7 L'algorithme pas à pas

#### La formule et ce qu'elle cache

La documentation résume l'algorithme en une ligne :

```
desiredReplicas = ceil( currentReplicas × currentMetricValue / desiredMetricValue )
```

Le code du contrôleur (v1.37) est plus précis, et les différences comptent. Pour une métrique `Resource` en `Utilization`, il procède ainsi :

1. Il liste les pods sélectionnés par la cible et récupère leurs mesures.
2. Il écarte les pods en cours de suppression (`deletionTimestamp`) et les pods `Failed`. Il met de côté les pods **sans mesure** et, pour le CPU, les pods **pas encore prêts**.
3. Il calcule l'utilisation sur les pods restants comme un **rapport de sommes**, en pourcentage entier tronqué : `utilisation = Σ consommation × 100 / Σ requests`. Ce n'est pas la moyenne des pourcentages de chaque pod : un pod qui a une request plus grosse pèse davantage.
4. Il en déduit le rapport `ratio = utilisation / cible`.
5. S'il n'y a ni pod mis de côté, ni pod sans mesure : si le ratio est dans la tolérance, il ne change rien ; sinon il propose `ceil(ratio × nombre de pods prêts)`. C'est le nombre de **pods mesurés**, pas `spec.replicas`, qui multiplie le ratio.

Un calcul sur le fil rouge rend tout cela concret. Le Deployment `api` tourne avec 2 pods, chacun avec `requests.cpu: 50m`, et le HPA vise 50 %. Sous charge, les deux pods consomment au total 180m :

```
  Σ requests     = 2 × 50m           = 100m
  utilisation    = 180 × 100 / 100   = 180 %
  ratio          = 180 / 50          = 3,6     (hors de [0,9 ; 1,1])
  proposition    = ceil(3,6 × 2)     = ceil(7,2) = 8
  bornes [2, 6]  ⇒ 6                 ScalingLimited=True (TooManyReplicas)
```

La montée de 2 à 6 se fait en une seule itération : la politique de montée par défaut autorise `max(4 pods, 100 % de 2) = 4` pods de plus par période de 15 s (7.8), soit exactement 6.

#### Les pods non prêts et les mesures manquantes

Un pod qui démarre fausse les mesures dans les deux sens : une JVM qui chauffe consomme beaucoup de CPU sans servir de trafic ; un pod tout juste créé n'a pas encore de mesure. Le contrôleur corrige ces biais de façon systématiquement **conservatrice** :

| Situation | Traitement si le ratio indique une MONTÉE | Traitement si le ratio indique une DESCENTE |
|---|---|---|
| Pod sans mesure | compté comme consommant **0 %** de sa request | compté comme consommant **100 %** de sa request (ou la cible si elle dépasse 100 %) |
| Pod pas encore prêt (CPU seulement) | compté à **0 %** | ignoré |

Après cette correction, le contrôleur recalcule le ratio. Si le nouveau ratio tombe dans la tolérance, ou s'il **inverse le sens** (une montée devenue descente, ou l'inverse), il ne fait rien. Autrement dit, les incertitudes freinent toujours l'action, jamais ne l'amplifient. Le statut du HPA affiche toutefois l'utilisation **d'origine**, avant correction : ne t'étonne pas de lire 120 % sans qu'aucun pod ne soit ajouté.

Pour le CPU, « pas encore prêt » obéit à deux options du controller-manager. Pendant `--horizontal-pod-autoscaler-cpu-initialization-period` (5 min) après le démarrage d'un pod, sa mesure n'est retenue que s'il est `Ready` et que l'échantillon a été pris entièrement pendant qu'il l'était. Pendant `--horizontal-pod-autoscaler-initial-readiness-delay` (30 s), un pod non prêt est réputé en cours d'initialisation même s'il a déjà été prêt brièvement. La bonne pratique qui en découle se règle dans le pod, pas dans le HPA : une `startupProbe` ou une `readinessProbe` qui ne passe qu'une fois le pic de démarrage passé.

#### Plusieurs métriques

Avec plusieurs entrées dans `spec.metrics`, chacune produit sa proposition et le contrôleur retient la **plus grande**. Si une métrique ne peut pas être lue et que les autres proposent une descente, il ne descend pas : il ne réduit jamais la capacité sur la foi d'informations partielles. Il peut en revanche monter si une métrique lisible le demande.

### 7.8 `behavior` : la vitesse et la stabilité

Sans réglage, un HPA monte immédiatement et descend prudemment. Le champ `spec.behavior` (stable depuis `autoscaling/v2`) règle séparément les deux sens, `scaleUp` et `scaleDown`, avec quatre champs chacun : `stabilizationWindowSeconds`, `policies`, `selectPolicy` et `tolerance`.

#### La fenêtre de stabilisation

À chaque itération, le contrôleur enregistre sa recommandation horodatée. Avant d'agir, il regarde les recommandations de la fenêtre :

- en **descente**, il applique la **plus haute** recommandation de la fenêtre. Une baisse de charge passagère ne retire donc rien tant qu'elle n'a pas duré toute la fenêtre. La condition `AbleToScale` passe alors en `ScaleDownStabilized` (« recent recommendations were higher than current one, applying the highest recent recommendation ») ;
- en **montée**, il applique la **plus basse**, ce qui exige qu'un pic ait duré toute la fenêtre avant d'ajouter des pods (raison `ScaleUpStabilized`).

Par défaut, la fenêtre de descente vaut 300 s (ou la valeur de `--horizontal-pod-autoscaler-downscale-stabilization`) et celle de montée 0 s. Les valeurs admises vont de 0 à 3600 secondes.

#### Les policies et `selectPolicy`

Une policy limite le changement sur une période glissante : `type: Pods` (un nombre absolu de pods) ou `type: Percent` (un pourcentage des réplicas actuels, arrondi au supérieur), `value`, et `periodSeconds` (de 1 à 1800). Quand plusieurs policies coexistent, `selectPolicy` choisit : `Max` (défaut) retient celle qui autorise le plus grand changement, `Min` la plus restrictive, `Disabled` interdit tout changement dans ce sens.

Les valeurs par défaut reproduisent le comportement historique du HPA :

```yaml
behavior:
  scaleDown:
    stabilizationWindowSeconds: 300   # en réalité : valeur de l'option du controller-manager
    selectPolicy: Max
    policies:
    - type: Percent
      value: 100                      # tout peut partir d'un coup, jusqu'à minReplicas
      periodSeconds: 15
  scaleUp:
    stabilizationWindowSeconds: 0
    selectPolicy: Max
    policies:
    - type: Pods
      value: 4
      periodSeconds: 15
    - type: Percent
      value: 100                      # max(+4 pods, doublement) toutes les 15 s
      periodSeconds: 15
```

Il suffit d'écrire ce qui diffère : l'API **complète elle-même** le reste. Dès que `behavior` est présent, la valeur par défaut de chaque champ absent est écrite dans l'objet stocké, à une exception près : `scaleDown.stabilizationWindowSeconds` reste vide si tu ne le fixes pas, pour que l'option du controller-manager continue de s'appliquer. Le HPA `api` du fil rouge ne précise que la fenêtre de descente ; voici ce que l'API en garde :

```bash
kubectl -n boutique get hpa api -o jsonpath='{.spec.behavior}' | python3 -m json.tool
```

```
{
    "scaleDown": {
        "policies": [
            {
                "periodSeconds": 15,
                "type": "Percent",
                "value": 100
            }
        ],
        "selectPolicy": "Max",
        "stabilizationWindowSeconds": 60
    },
    "scaleUp": {
        "policies": [
            {
                "periodSeconds": 15,
                "type": "Pods",
                "value": 4
            },
            {
                "periodSeconds": 15,
                "type": "Percent",
                "value": 100
            }
        ],
        "selectPolicy": "Max",
        "stabilizationWindowSeconds": 0
    }
}
```

Deux exemples de la documentation méritent d'être sus par cœur, car ils reviennent dans les énoncés. Limiter la descente à 10 % par minute **et** à 5 pods par minute au plus :

```yaml
behavior:
  scaleDown:
    policies:
    - type: Percent
      value: 10
      periodSeconds: 60
    - type: Pods
      value: 5
      periodSeconds: 60
    selectPolicy: Min
```

Interdire toute descente (le HPA ne fait plus que monter) :

```yaml
behavior:
  scaleDown:
    selectPolicy: Disabled
```

> [!warning]
> Les policies s'appliquent **après** la stabilisation, en même temps que les bornes `minReplicas` et `maxReplicas` : le contrôleur retient la limite la plus restrictive, et `ScalingLimited` dit laquelle a mordu (`ScaleUpLimit` ou `ScaleDownLimit` pour une policy, `TooManyReplicas` ou `TooFewReplicas` pour une borne). Le nombre de pods qu'une policy `Percent` permet d'ajouter ou de retirer est arrondi au supérieur : 10 % de 3 réplicas autorisent 1 pod, jamais 0.

### 7.9 La tolérance configurable (GA en 1.37)

La tolérance est la zone morte autour de la cible. Le contrôleur ne fait rien tant que le ratio reste dans l'intervalle `[1 − tolérance de descente ; 1 + tolérance de montée]`. Avec la valeur globale par défaut, 0,1, un HPA qui vise 50 % ne bouge pas entre 45 % et 55 %. Cette valeur se règle pour tout le cluster par l'option `--horizontal-pod-autoscaler-tolerance` du kube-controller-manager ; elle ne se règle pas par l'API.

Depuis Kubernetes 1.37, la **tolérance par HPA et par sens** est stable (feature gate `HPAConfigurableTolerance` : alpha en 1.33, bêta en 1.35, GA et verrouillée en 1.37). Le champ s'appelle `tolerance` et se place dans chaque règle de `behavior` :

```yaml
behavior:
  scaleUp:
    tolerance: 0.05     # monte dès que le ratio dépasse 1,05
  scaleDown:
    tolerance: 0.15     # ne descend que sous un ratio de 0,85
```

Les chemins exacts sont donc `spec.behavior.scaleUp.tolerance` et `spec.behavior.scaleDown.tolerance`. Le type est une **Quantity** positive ou nulle, pas un pourcentage : `0.05` signifie 5 %. L'API la stocke sous sa forme canonique : relue avec `kubectl get -o yaml`, `0.05` devient `50m` et `0.15` devient `150m`, ce qui surprend la première fois. Un champ absent prend la tolérance globale. La doc d'API résume l'effet sur un exemple : cible mémoire de 100Mi, tolérances de 5 % en descente et de 1 % en montée, le HPA agit sous 95Mi ou au-dessus de 101Mi.

L'intérêt est l'asymétrie. Un service sensible à la latence veut monter tôt (petite tolérance de montée) et descendre tard (grande tolérance de descente, plus une fenêtre de stabilisation). Un grand Deployment de 200 pods, à l'inverse, trouve la tolérance globale trop grossière : 10 % de 200, ce sont 20 pods de marge.

### 7.10 Descendre à zéro, se mettre en veille

**Mise à zéro.** Avec la feature gate `HPAScaleToZero`, bêta et **activée** par défaut depuis 1.37, `minReplicas: 0` est accepté, mais seulement si le HPA porte au moins une métrique `Object` ou `External` : une métrique de ressource ne se mesure que sur des pods qui tournent, elle ne pourrait jamais faire remonter de zéro. L'apiserver refuse un HPA à `minReplicas: 0` sans métrique de ce type. Pendant qu'il maintient la cible à zéro, le HPA affiche une condition `ScaledToZero` à `True` ; elle repasse à `False` avec la raison `NotScaledToZero` à la remontée. La porte étant active, le contrôleur pose aussi cette condition, à `False` (`NotScaledToZero`), sur **tout** HPA dès son premier changement d'échelle, même avec `minReplicas: 2` : sur le lab, `kubectl describe hpa api` montre quatre conditions après la première montée de l'exercice 7.3, et trois seulement avant.

**Mise en veille implicite.** Si quelqu'un met lui-même la cible à 0 réplica alors que `minReplicas` est supérieur à 0, le HPA cesse d'agir et passe `ScalingActive` à `False` avec la raison `ScalingDisabled` (« scaling is disabled since the replica count of the target is zero »). Il reprend dès que la cible repasse au-dessus de zéro. C'est la façon propre de suspendre un service autoscalé sans supprimer son HPA.

### 7.11 Créer et lire un HPA à l'examen

#### Le chemin le plus court

`kubectl autoscale` crée directement un HPA `autoscaling/v2`. Depuis kubectl 1.34, la cible CPU s'écrit `--cpu`, qui accepte un pourcentage (cible `Utilization`) ou une quantité (cible `AverageValue`) ; `--memory` fait de même pour la mémoire. L'ancienne option `--cpu-percent` est dépréciée et exclusive de `--cpu`.

```bash
kubectl -n boutique autoscale deployment api --min=2 --max=6 --cpu=50%
kubectl -n boutique autoscale deployment api --min=2 --max=6 --cpu=500m --memory=200Mi  # en valeurs
```

`--max` est obligatoire ; sans `--min`, l'apiserver applique `minReplicas: 1`. Le HPA prend le nom de la cible, sauf `--name`. Sans aucune cible de métrique, l'API ajoute d'office une métrique CPU à **80 %** d'utilisation : un HPA créé par `kubectl -n boutique autoscale deployment api --max=6` n'est donc pas « sans métrique ».

`kubectl autoscale` ne connaît pas `behavior`. Quand l'énoncé demande une fenêtre de stabilisation ou une policy, génère le YAML, complète-le, applique-le :

```bash
kubectl -n boutique autoscale deployment api --min=2 --max=6 --cpu=50% \
  --dry-run=client -o yaml > ~/cka/boutique/hpa-api.yaml
vim ~/cka/boutique/hpa-api.yaml          # ajouter spec.behavior
kubectl apply -f ~/cka/boutique/hpa-api.yaml
```

Ou corrige l'objet existant par un patch fusionné, plus rapide quand il n'y a qu'un champ :

```bash
kubectl -n boutique patch hpa api --type=merge \
  -p '{"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":60}}}}'
```

`kubectl explain hpa.spec.behavior.scaleDown` (et `--recursive`) donne la structure exacte sans quitter le terminal. Dans la documentation, les pages à ouvrir sont « Horizontal Pod Autoscaling » (concept, section *Configurable scaling behavior*) et « HorizontalPodAutoscaler Walkthrough » (exemple complet en `autoscaling/v2`).

#### Lire l'état

```bash
kubectl -n boutique get hpa
```

```
NAME   REFERENCE        TARGETS       MINPODS   MAXPODS   REPLICAS   AGE
api    Deployment/api   cpu: 2%/50%   2         6         2          4m
```

La colonne `TARGETS` affiche `cpu: <unknown>/50%` tant qu'aucune mesure n'a été obtenue : normal pendant la première minute, anormal au-delà. `kubectl describe hpa` donne le détail des métriques (pourcentage et valeur brute moyenne), le `behavior`, les conditions et les événements :

```
Metrics:                                               ( current / target )
  resource cpu on pods  (as a percentage of request):  2% (1m) / 50%
Min replicas:                                          2
Max replicas:                                          6
Behavior:
  Scale Up:
    Stabilization Window: 0 seconds
    Select Policy: Max
    Policies:
      - Type: Pods     Value: 4    Period: 15 seconds
      - Type: Percent  Value: 100  Period: 15 seconds
  Scale Down:
    Stabilization Window: 60 seconds
    Select Policy: Max
    Policies:
      - Type: Percent  Value: 100  Period: 15 seconds
Deployment pods:                                       2 current / 2 desired
Conditions:
  Type            Status  Reason              Message
  ----            ------  ------              -------
  AbleToScale     True    ReadyForNewScale    recommended size matches current size
  ScalingActive   True    ValidMetricFound    the HPA was able to successfully calculate a replica count from cpu resource utilization (percentage of request)
  ScalingLimited  True    TooFewReplicas      the desired replica count is less than the minimum replica count
```

`ScalingLimited=True` n'est pas ici une anomalie : à 2 % d'utilisation, l'algorithme propose `ceil(0,04 × 2) = 1` réplica, et la borne `minReplicas: 2` le remonte. C'est l'état normal d'un HPA au repos. La condition passe à `False` (`DesiredWithinRange`) quand la recommandation tombe entre les bornes, par exemple quand le ratio reste dans la tolérance.

Les trois conditions se lisent dans l'ordre de la boucle de 7.6 :

| Condition | Question posée | Raisons fréquentes |
|---|---|---|
| `AbleToScale` | Le contrôleur peut-il lire et écrire `/scale`, et rien ne retient-il l'action ? | `True` : `SucceededGetScale`, `ReadyForNewScale`, `SucceededRescale`, `ScaleDownStabilized`, `ScaleUpStabilized` ; `False` : `FailedGetScale` (cible absente ou mal nommée), `FailedUpdateScale` |
| `ScalingActive` | Le HPA est-il actif et sait-il calculer un nombre de réplicas ? | `True` : `ValidMetricFound` ; `False` : `FailedGetResourceMetric`, `FailedGetContainerResourceMetric`, `FailedGetPodsMetric`, `FailedGetObjectMetric`, `FailedGetExternalMetric`, `InvalidSelector`, `AmbiguousSelector` (deux HPA sur les mêmes pods), `ScalingDisabled` |
| `ScalingLimited` | Une borne ou une policy a-t-elle rogné la recommandation ? | `False` : `DesiredWithinRange` ; `True` : `TooManyReplicas`, `TooFewReplicas`, `ScaleUpLimit`, `ScaleDownLimit` |

Les événements complètent le tableau : `SuccessfulRescale` (« New size: 6; reason: cpu resource utilization (percentage of request) above target », puis « reason: All metrics below target » à la descente), `FailedGetResourceMetric` et `FailedComputeMetricsReplicas` quand les mesures manquent. `kubectl events -n boutique --for hpa/api` les isole.

### 7.12 HPA, Deployments et `kubectl apply`

Le HPA et toi écrivez le même champ, `spec.replicas` de la cible. Plusieurs pièges en découlent.

Un `kubectl -n boutique scale deployment api --replicas=1` est annulé à l'itération suivante : la cible passe sous `minReplicas`, et le HPA la remonte avec le motif « Current number of replicas below Spec.MinReplicas ». De même au-dessus de `maxReplicas`. Pour changer durablement l'échelle d'un service autoscalé, on modifie le HPA, pas la cible.

Plus sournois : si le manifeste du Deployment contient `replicas: 2` et que tu le réappliques pendant que le HPA maintient 6 pods, `kubectl apply` remet 2, le HPA remonte à 6 quinze secondes plus tard, et le service oscille. La documentation recommande de **retirer `spec.replicas` du manifeste** d'une cible autoscalée. Attention à la manière : retirer le champ du fichier puis réappliquer en client-side apply supprime le champ de l'objet, qui reprend sa valeur par défaut, 1, le temps d'une itération du HPA. La procédure propre passe par `kubectl -n boutique apply edit-last-applied deployment/api` (supprimer `replicas` de l'annotation `last-applied-configuration`), puis seulement par la modification du fichier ; en server-side apply, on transfère la propriété du champ (chapitre 3.8.2).

Pendant un rolling update, le HPA continue de régler `spec.replicas` du Deployment, et le contrôleur de Deployment répartit ce nombre entre l'ancien et le nouveau ReplicaSet. Rien de particulier à faire. Sur un StatefulSet, le HPA agit de même, et les pods sont ajoutés ou retirés dans l'ordre des ordinaux.

### 7.13 Le Vertical Pod Autoscaler

Le VPA répond à une autre question : « quelles requests ce conteneur devrait-il avoir ? ». Il ne fait pas partie de Kubernetes : c'est un projet de SIG Autoscaling (dépôt `kubernetes/autoscaler`), à installer, qui ajoute la CRD `VerticalPodAutoscaler` du groupe `autoscaling.k8s.io/v1`. Au 23 octobre 2026, la version courante est **VPA 1.8.1** (21 octobre 2026), compatible avec Kubernetes 1.36 à 1.38 ; la branche 1.7 couvre 1.35 à 1.37.

```
          ARCHITECTURE DU VPA
═══════════════════════════════════════════════════════════════════

  metrics.k8s.io ──▶ ┌─────────────┐  écrit status.recommendation
  (+ OOM, historique)│ recommender │───────────────────┐
                     └─────────────┘                   ▼
                                              ┌──────────────────┐
                     ┌─────────────┐  compare │ VerticalPod-     │
                     │  updater    │◀─────────│ Autoscaler (CRD) │
                     └──────┬──────┘          └──────────────────┘
                            │ évince (Recreate)          ▲
                            │ ou redimensionne en place  │ lit
                            ▼                            │
                     pods de la cible            ┌───────┴─────────┐
                            ▲  requests réécrites│ admission-      │
                            └────────────────────│ controller      │
                               à la (re)création │ (webhook        │
                                                 │ mutant)         │
                                                 └─────────────────┘
```

Le **recommender** observe la consommation et les OOM, et calcule pour chaque conteneur une cible (`target`), une borne basse (`lowerBound`) et une borne haute (`upperBound`), rangées dans `status.recommendation`. L'**updater** compare les pods en cours aux recommandations et agit selon le mode. L'**admission-controller** est un webhook mutant qui réécrit les requests (et les limits, proportionnellement) de chaque pod créé pour la cible. Le VPA a besoin de metrics-server.

Le mode se choisit dans `spec.updatePolicy.updateMode` :

| Mode | Effet | Statut dans le VPA |
|---|---|---|
| `Off` | recommandations calculées et publiées, jamais appliquées | stable |
| `Initial` | requests posées à la création des pods seulement | stable |
| `Recreate` | pods évincés quand leurs requests s'écartent trop des recommandations, recréés avec les nouvelles valeurs | stable |
| `InPlaceOrRecreate` | redimensionnement **en place** (sous-ressource `resize`, chapitre 4.12) quand c'est possible, éviction sinon | GA depuis VPA 1.6.0 (alpha 1.4.0, bêta 1.5.0) ; sa feature gate a disparu en 1.7.0 |
| `InPlace` | redimensionnement en place uniquement, jamais d'éviction : en cas d'impossibilité, le VPA attend et réessaie | alpha depuis VPA 1.7.0, feature gate `InPlace` à activer sur l'updater et l'admission-controller |
| `Auto` | alias de `Recreate` | déprécié depuis VPA 1.4.0 |

`InPlaceOrRecreate` exploite le redimensionnement en place des pods, GA dans Kubernetes depuis 1.35 : le pod garde son nom, son IP et souvent ses conteneurs. Le VPA retombe sur l'éviction quand le redimensionnement est infaisable (place insuffisante sur le nœud, changement de classe QoS, qui est interdit en place). L'updater respecte les PodDisruptionBudgets pour ses évictions.

`spec.resourcePolicy.containerPolicies` borne les recommandations par conteneur (`minAllowed`, `maxAllowed`), choisit les ressources gérées (`controlledResources`, `cpu` et `memory` par défaut) et ce qui est réécrit (`controlledValues` : `RequestsAndLimits` par défaut, qui conserve le rapport limite/request ; ou `RequestsOnly`). Le VPA respecte aussi les LimitRange du namespace : une recommandation qui dépasserait un `max` est ramenée à ce maximum.

Un VPA en mode recommandation pour `api` s'écrirait ainsi ; il n'est pas appliqué dans le lab, faute de CRD installée :

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: api
  namespace: boutique
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  updatePolicy:
    updateMode: "Off"
  resourcePolicy:
    containerPolicies:
    - containerName: agnhost
      minAllowed:
        cpu: 25m
        memory: 32Mi
      maxAllowed:
        cpu: 500m
        memory: 256Mi
      controlledValues: RequestsOnly
```

Trois limites sont à connaître. Le VPA **ne doit pas** piloter la même ressource qu'un HPA : si le HPA vise 50 % de la request CPU et que le VPA augmente la request CPU, l'utilisation baisse, le HPA retire des pods, la consommation par pod remonte, le VPA augmente encore la request… Les deux se combinent seulement sur des ressources distinctes (VPA sur la mémoire, HPA sur le CPU) ou avec un HPA sur métriques personnalisées. Le VPA n'agit que sur des pods gérés par un contrôleur. Enfin, il n'est pas compatible avec les ressources de niveau pod (`spec.resources`) : son admission-controller peut produire des pods que l'API refuse.

L'installation officielle clone le dépôt et lance un script (`./hack/vpa-up.sh` dans `vertical-pod-autoscaler/`), qui génère les certificats du webhook et applique CRD, RBAC et composants ; un chart Helm existe aussi. Rien de cela n'est attendu à l'examen.

### 7.14 Le Cluster Autoscaler et Karpenter

Quand le HPA crée des pods que les nœuds ne peuvent plus accueillir, ces pods restent `Pending` avec un événement `FailedScheduling` (« Insufficient cpu », chapitre 8.2). C'est le signal qu'attend un **autoscaler de nœuds**. SIG Autoscaling en parraine deux.

Le **Cluster Autoscaler** gère des *groupes de nœuds* préconfigurés (un groupe d'instances chez le fournisseur). Il ajoute un nœud au groupe le plus adapté quand des pods sont non planifiables, en simulant le scheduler pour vérifier qu'ils tiendraient sur le nouveau nœud. Il retire un nœud quand celui-ci est sous-utilisé : la plus grande des deux fractions « somme des requests CPU / allocatable » et « somme des requests mémoire / allocatable » passe sous `--scale-down-utilization-threshold` (0,5 par défaut), pendant `--scale-down-unneeded-time` (10 minutes par défaut), et tous ses pods peuvent être replacés ailleurs. Il vide alors le nœud par l'API d'éviction, en respectant les PodDisruptionBudgets, puis supprime la machine. L'annotation `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` sur un pod empêche la suppression de son nœud.

**Karpenter** ne raisonne pas en groupes : à partir de contraintes (objets NodePool), il choisit lui-même le type de machine qui convient aux pods en attente (*auto-provisioning*), et gère tout le cycle de vie des nœuds (renouvellement à échéance, mise à jour d'image). Il est publié comme bibliothèque que chaque fournisseur intègre (AWS, Azure notamment).

Les deux décident sur les **requests** des pods, jamais sur leur consommation réelle. Un cluster dont les pods n'ont pas de requests ne déclenche jamais d'ajout de nœud ; un cluster aux requests gonflées n'en retire jamais. C'est la raison profonde pour laquelle le CKA insiste sur les requests, les LimitRange et les quotas (chapitre 8).

### 7.15 Pièges courants

```
Piège 1 : HPA sur un pod sans request
══════════════════════════════════════
  MAUVAIS  : averageUtilization sur un conteneur sans requests.cpu
             (ou un sidecar ajouté sans requests)
  SYMPTÔME : TARGETS cpu: <unknown>/50%, ScalingActive=False
             FailedGetResourceMetric : missing request for cpu in
             container X of Pod Y
  BON      : une request CPU sur CHAQUE conteneur, ou un LimitRange
             avec defaultRequest dans le namespace

Piège 2 : --cpu-percent, ou confondre utilisation et valeur
════════════════════════════════════════════════════════════
  MAUVAIS  : --cpu-percent=50 (déprécié depuis kubectl 1.34,
             avertissement) ; --cpu=500m pour « 50 % de CPU »
  SYMPTÔME : avertissement de dépréciation ; cible AverageValue
             500m au lieu de Utilization 50
  BON      : --cpu=50%  (le % fait la différence)

Piège 3 : Chercher behavior dans kubectl autoscale
═══════════════════════════════════════════════════
  MAUVAIS  : perdre du temps à chercher une option --stabilization
  BON      : --dry-run=client -o yaml, ajouter spec.behavior,
             apply ; ou kubectl patch hpa --type=merge

Piège 4 : stabilizationWindowSeconds au mauvais niveau
═══════════════════════════════════════════════════════
  MAUVAIS  : spec.behavior.stabilizationWindowSeconds: 30
  SYMPTÔME : strict decoding error: unknown field
  BON      : spec.behavior.scaleDown.stabilizationWindowSeconds: 30

Piège 5 : La tolérance en pourcentage
══════════════════════════════════════
  MAUVAIS  : tolerance: 5          (= 500 % de marge)
  BON      : tolerance: 0.05       (relue « 50m » dans le YAML stocké)

Piège 6 : Conclure trop vite sous minikube
═══════════════════════════════════════════
  SYMPTÔME : le HPA « ne réagit pas » pendant une minute
  CAUSE    : --metric-resolution=60s de l'addon + période de 15 s
             du contrôleur + fenêtre de stabilisation en descente
  BON      : kubectl get hpa -w et patienter 2 à 3 minutes

Piège 7 : Réappliquer un Deployment autoscalé
══════════════════════════════════════════════
  MAUVAIS  : manifeste avec replicas: 2, kubectl apply sous charge
  SYMPTÔME : 6 → 2 → 6 pods, service dégradé entre les deux
  BON      : retirer spec.replicas du manifeste (edit-last-applied
             d'abord), régler l'échelle dans le HPA

Piège 8 : Exemples metrics.k8s.io/v1 de la documentation
═════════════════════════════════════════════════════════
  SYMPTÔME : kubectl get --raw /apis/metrics.k8s.io/v1/… → NotFound
  CAUSE    : metrics-server v0.9.0 ne sert que v1beta1
  BON      : /apis/metrics.k8s.io/v1beta1/…
```

> [!summary] À retenir
> - Le HPA est un contrôleur du kube-controller-manager qui écrit dans la sous-ressource `/scale` de sa cible toutes les 15 s ; un DaemonSet ne peut pas être autoscalé.
> - L'utilisation se mesure en pourcentage de la **request** (somme de tous les conteneurs, sidecars compris) : un seul conteneur sans request rend le HPA aveugle.
> - Formule : `ceil(ratio × pods prêts mesurés)`, avec `ratio = Σ consommation / Σ requests / cible` ; dans la tolérance, aucune action. Pods sans mesure et pods non prêts sont traités de façon conservatrice.
> - Tolérance : 0,1 par défaut (`--horizontal-pod-autoscaler-tolerance`), réglable par HPA et par sens depuis 1.37 GA dans `spec.behavior.scaleUp.tolerance` et `spec.behavior.scaleDown.tolerance` (Quantity : `0.05` = 5 %).
> - `behavior` par défaut : montée sans fenêtre, `max(+4 pods, +100 %)` par 15 s ; descente avec une fenêtre de 300 s et jusqu'à 100 % par 15 s. On n'écrit que ce qui diffère.
> - Conditions : `AbleToScale` (accès à `/scale`, stabilisation), `ScalingActive` (métriques lisibles), `ScalingLimited` (bornes ou policies).
> - metrics-server v0.9.0 sert `metrics.k8s.io/v1beta1` seulement ; minikube le configure avec `--metric-resolution=60s` et `--kubelet-insecure-tls`, et ses nœuds annoncent la capacité de l'hôte.
> - Le VPA (CRD `autoscaling.k8s.io/v1`, version 1.8.1) recommande ou applique des requests ; `InPlaceOrRecreate` est GA depuis VPA 1.6.0 ; jamais sur la même ressource qu'un HPA.
> - Cluster Autoscaler et Karpenter ajoutent des nœuds pour les pods `Pending` et en retirent selon les **requests**, pas selon la consommation réelle.

### 7.16 Exercices

#### Exercice 7.1 — Activer la chaîne de métriques

**Point de départ** : fin des exercices du [chapitre 6](06-configmaps-et-secrets.md) (namespace `boutique` avec `front`, `api`, `agent-noeud`, `rapport` et `outils`).

Active metrics-server sur le cluster `cka`. Vérifie que l'APIService qui sert l'API de métriques est disponible, puis affiche la consommation des trois nœuds triée par mémoire, et celle de chaque conteneur des pods `api` du namespace `boutique`. Interroge enfin directement l'API de métriques pour le nœud `cka-m02` et relève la durée de la fenêtre de mesure (`window`).

> [!example]- Solution
> ```bash
> minikube -p cka addons enable metrics-server
> kubectl -n kube-system rollout status deployment metrics-server
> kubectl get apiservice v1beta1.metrics.k8s.io
> # attendre environ une minute (première collecte, --metric-resolution=60s)
> kubectl top nodes --sort-by=memory
> kubectl -n boutique top pods -l app=api --containers
> kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes/cka-m02 | python3 -m json.tool
> ```
>
> L'addon installe le Deployment `metrics-server` et l'APIService `v1beta1.metrics.k8s.io`. Juste après le rollout, l'APIService peut encore afficher `False (FailedDiscoveryCheck)` (constaté sur le lab : la sonde de l'apiserver n'a pas encore abouti), et tant que la première collecte n'a pas eu lieu, `kubectl top` répond `error: Metrics API not available` ou `metrics not available yet` : ce n'est pas une panne, `kubectl top nodes` a répondu 69 s après `addons enable`. Les arguments de l'addon se lisent avec `kubectl -n kube-system get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}'` ; tu y retrouves `--metric-resolution=60s` et `--kubelet-insecure-tls`. Les pourcentages de `kubectl top nodes` sont minuscules parce que chaque nœud annonce la capacité de l'hôte (7.5). L'API se lit en `v1beta1` : la version `v1`, GA dans Kubernetes 1.37, n'est pas servie par metrics-server v0.9.0.
>
> **Vérification** : `kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'` affiche `True`, `kubectl top nodes` liste `cka`, `cka-m02` et `cka-m03`, et la réponse JSON de l'API contient `"kind": "NodeMetrics"` avec un champ `window`.

#### Exercice 7.2 — Créer le HPA `api`

**Point de départ** : exercice 7.1.

Dans le namespace `boutique`, crée un HorizontalPodAutoscaler `autoscaling/v2` nommé `api` qui pilote le Deployment `api` entre 2 et 6 réplicas pour une utilisation CPU moyenne de 50 % des requests. La descente doit être stabilisée sur 60 secondes ; le reste du comportement garde ses valeurs par défaut. Range le manifeste dans `~/cka/boutique/hpa-api.yaml`. Calcule ensuite, sans regarder le cluster, la consommation CPU moyenne par pod qui correspond à la cible.

> [!example]- Solution
> ```bash
> kubectl -n boutique autoscale deployment api --min=2 --max=6 --cpu=50% \
>   --dry-run=client -o yaml > ~/cka/boutique/hpa-api.yaml
> vim ~/cka/boutique/hpa-api.yaml
> ```
>
> Après nettoyage et ajout de `behavior`, le fichier contient :
>
> ```yaml
> apiVersion: autoscaling/v2
> kind: HorizontalPodAutoscaler
> metadata:
>   name: api
>   namespace: boutique
> spec:
>   scaleTargetRef:
>     apiVersion: apps/v1
>     kind: Deployment
>     name: api
>   minReplicas: 2
>   maxReplicas: 6
>   metrics:
>   - type: Resource
>     resource:
>       name: cpu
>       target:
>         type: Utilization
>         averageUtilization: 50
>   behavior:
>     scaleDown:
>       stabilizationWindowSeconds: 60
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/hpa-api.yaml
> kubectl -n boutique get hpa api
> kubectl -n boutique describe hpa api
> ```
>
> La cible est de 50 % de `requests.cpu: 50m`, soit **25m** en moyenne par pod. `kubectl autoscale` ne sait pas écrire `behavior`, d'où le passage par le YAML. L'API complète le comportement : `scaleUp` reçoit sa fenêtre de 0 s et ses deux policies, `scaleDown` garde ta fenêtre de 60 s et reçoit sa policy de 100 % par 15 s (7.8). Au repos, les pods `api` consomment quelques millicœurs : l'algorithme propose 1 réplica, la borne `minReplicas` le ramène à 2, et `ScalingLimited` passe à `True` avec la raison `TooFewReplicas` une fois la fenêtre de 60 s écoulée (7.11). C'est l'état normal d'un HPA au repos.
>
> **Vérification** : `kubectl -n boutique get hpa api` affiche `Deployment/api`, `MINPODS 2`, `MAXPODS 6`, `REPLICAS 2` et, après une minute, une valeur chiffrée dans `TARGETS` (`cpu: 2%/50%` par exemple) ; `kubectl -n boutique get hpa api -o jsonpath='{.spec.behavior.scaleDown.stabilizationWindowSeconds}'` affiche `60`.

#### Exercice 7.3 — Faire monter le HPA

**Point de départ** : exercice 7.2.

Crée dans `boutique` un Deployment temporaire `charge` (labels `app=charge` et `tier=outils`, image `busybox:1.37.0`, 2 réplicas) dont chaque pod lance **quatre** boucles `wget` en parallèle vers `http://api:8080/hostname`. Observe la montée du HPA `api` jusqu'à son maximum, puis explique, à partir de `kubectl -n boutique describe hpa api`, quelle condition indique que le maximum a rogné la recommandation.

> [!example]- Solution
> ```yaml
> # ~/cka/boutique/charge.yaml
> apiVersion: apps/v1
> kind: Deployment
> metadata:
>   name: charge
>   namespace: boutique
>   labels:
>     app: charge
>     tier: outils
> spec:
>   replicas: 2
>   selector:
>     matchLabels:
>       app: charge
>   template:
>     metadata:
>       labels:
>         app: charge
>         tier: outils
>     spec:
>       containers:
>       - name: charge
>         image: busybox:1.37.0
>         command: ["sh", "-c"]
>         args:
>         - |
>           for i in 1 2 3 4; do
>             ( while true; do wget -q -O /dev/null http://api:8080/hostname; done ) &
>           done
>           wait
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/charge.yaml
> kubectl -n boutique get hpa api -w          # Ctrl+C quand REPLICAS atteint 6
> kubectl -n boutique top pods -l app=api
> kubectl -n boutique describe hpa api
> kubectl events -n boutique --for hpa/api
> ```
>
> Huit boucles (4 par pod, 2 pods) envoient des requêtes en continu. agnhost répond vite, mais chaque requête lui coûte du CPU (traitement HTTP et ligne de journal) ; la consommation dépasse alors largement les 25m visés par pod. Le délai avant la première réaction est normal : jusqu'à 60 s pour la collecte suivante de metrics-server, puis jusqu'à 15 s pour l'itération du HPA. Une fois le seuil franchi, la montée se fait d'un bloc : la policy par défaut autorise `max(4, 100 % de 2) = 4` pods de plus en 15 s, soit exactement 6. Les nouveaux pods `api` démarrent prêts en quelques secondes (readiness sur `/hostname`) et la charge se répartit sur six pods. Sur le lab, `TARGETS` est passé de `2%` à `262%` 36 s après la création de `charge`, et `REPLICAS` de 2 à 6 quinze secondes plus tard ; à six réplicas, l'utilisation reste vers `175%` (80 à 100m par pod `api`). Rien ne limite `charge` à ce stade : chacun de ses deux pods consomme environ 2,5 cœurs de ton poste. Si `TARGETS` reste sous 55 % après trois minutes (machine hôte lente ou très rapide), augmente la charge avec `kubectl -n boutique scale deployment charge --replicas=4`.
>
> Si tu rejoues cet exercice après le [chapitre 8](08-ordonnancement-et-admission.md) (instantané I1 ou au-delà), le LimitRange `boutique-limites` donne au conteneur de `charge` la limite CPU par défaut de 200m : la même charge ne fait plus monter le HPA qu'à **4** réplicas. Il faut alors `kubectl -n boutique scale deployment charge --replicas=4`, ou des limites explicites dans `charge.yaml`. À partir de l'instantané I2, les NetworkPolicies du [chapitre 14.11](14-network-policies.md) bloquent en plus le trafic de `charge` vers `api` : seuls les pods `tier=web`, `app=outils` et les contrôleurs d'Ingress et de Gateway y ont accès.
>
> Dans `describe`, `ScalingLimited` vaut `True` avec la raison `TooManyReplicas` (« the desired replica count is more than the maximum replica count ») tant que la proposition dépasse 6, et l'événement `SuccessfulRescale` indique « New size: 6; reason: cpu resource utilization (percentage of request) above target ». Une quatrième condition est apparue avec ce premier changement d'échelle, `ScaledToZero` à `False` (`NotScaledToZero`, « the HPA controller did not scale the workload to zero ») : elle ne concerne que la mise à zéro (7.10).
>
> **Vérification** : `kubectl -n boutique get hpa api` affiche `REPLICAS 6` et une utilisation supérieure à `50%` dans `TARGETS` ; `kubectl -n boutique get deploy api` affiche `6/6`.

#### Exercice 7.4 — Arrêter la charge et observer la descente

**Point de départ** : exercice 7.3.

Supprime le Deployment `charge`. Mesure le temps que met le HPA à revenir à 2 réplicas et explique les trois délais qui le composent. Vérifie que l'état final correspond au fil rouge.

> [!example]- Solution
> ```bash
> kubectl -n boutique delete deployment charge
> date; kubectl -n boutique get hpa api -w     # Ctrl+C au retour à 2 réplicas
> kubectl -n boutique describe hpa api | sed -n '/Conditions/,$p'
> ```
>
> Le retour à 2 réplicas prend sur le lab entre deux minutes et demie et trois minutes (2 min 26 s et 2 min 49 s mesurées). Trois délais s'additionnent : la mesure de metrics-server avant que la baisse soit entière, jusqu'à deux minutes sous minikube, car le CPU est un taux calculé sur la fenêtre de collecte de 60 s, et la première collecte qui suit la suppression mêle encore la charge (`108%` relevés, avant `2%` à la suivante) ; la **fenêtre de stabilisation de 60 s**, pendant laquelle le HPA applique la plus haute recommandation récente (6), d'où la raison `ScaleDownStabilized` sur `AbleToScale` ; l'itération suivante du contrôleur (15 s au plus). La policy de descente par défaut (100 % par 15 s) autorise ensuite le passage direct de 6 à la borne de 2. Sans la fenêtre de 60 s que tu as fixée, la descente aurait attendu les 300 s par défaut.
>
> L'événement final est `SuccessfulRescale` avec « New size: 2; reason: All metrics below target ».
>
> **Vérification** : `kubectl -n boutique get deploy charge` répond `NotFound`, `kubectl -n boutique get hpa api` affiche `REPLICAS 2`, et `kubectl -n boutique get deploy api` affiche `2/2`. C'est l'état laissé par le chapitre 7 : addon metrics-server et HPA `api`.

#### Exercice 7.5 — Diagnostiquer un HPA aveugle et régler la tolérance

**Point de départ** : exercice 7.4.

Dans `boutique`, crée un Deployment temporaire `sans-requests` (image `busybox:1.37.0`, commande `sleep 3600`, 1 réplica, **sans** section `resources`) et un HPA `sans-requests` (1 à 3 réplicas, 60 % de CPU). Explique pourquoi il reste en `<unknown>` en citant la condition et son message. Ajoute ensuite à ce HPA une tolérance de montée de 5 % et une tolérance de descente de 15 %, et constate sous quelle forme l'API les stocke. Supprime enfin les deux objets.

> [!example]- Solution
> ```bash
> kubectl -n boutique create deployment sans-requests --image=busybox:1.37.0 -- sleep 3600
> kubectl -n boutique autoscale deployment sans-requests --min=1 --max=3 --cpu=60%
> # attendre une à deux minutes
> kubectl -n boutique get hpa sans-requests
> kubectl -n boutique describe hpa sans-requests | sed -n '/Conditions/,$p'
> ```
>
> `TARGETS` reste à `cpu: <unknown>/60%`. La condition `ScalingActive` est `False`, raison `FailedGetResourceMetric`, avec un message de la forme « the HPA was unable to compute the replica count: failed to get cpu utilization: missing request for cpu in container busybox of Pod sans-requests-… ». Pendant la première minute, avant la première collecte du pod, le message est d'abord `did not receive metrics for targeted pods (pods might be unready)` puis `unable to get metrics for resource cpu: no metrics returned from resource metrics API` : le diagnostic ne se lit qu'une fois le pod mesuré (70 s sur le lab). metrics-server mesure bien ce pod, mais une utilisation en pourcentage n'a pas de sens sans request.
>
> ```bash
> kubectl -n boutique patch hpa sans-requests --type=merge \
>   -p '{"spec":{"behavior":{"scaleUp":{"tolerance":0.05},"scaleDown":{"tolerance":0.15}}}}'
> kubectl -n boutique get hpa sans-requests -o jsonpath='{.spec.behavior.scaleUp.tolerance} {.spec.behavior.scaleDown.tolerance}{"\n"}'
> kubectl -n boutique delete hpa sans-requests
> kubectl -n boutique delete deployment sans-requests
> ```
>
> La tolérance est une Quantity : l'API la stocke sous forme canonique, `50m` pour 0,05 et `150m` pour 0,15. Le HPA ne monterait qu'au-dessus d'un ratio de 1,05 et ne descendrait que sous 0,85. Ajouter `behavior` par patch a aussi rempli toutes les autres valeurs par défaut de `scaleUp` et `scaleDown`.
>
> **Vérification** : la commande `jsonpath` affiche `50m 150m` avant la suppression ; ensuite `kubectl -n boutique get hpa` ne liste plus que `api` et `kubectl -n boutique get deploy sans-requests` répond `NotFound`.

---
