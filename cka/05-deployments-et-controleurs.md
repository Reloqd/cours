---
title: "CKA — 5. Deployments et autres contrôleurs"
description: "Les contrôleurs qui fabriquent et réparent les pods : ReplicaSet, Deployment et l'algorithme exact du rolling update, rollouts et retours arrière, DaemonSet, StatefulSet, Job, CronJob et PodDisruptionBudget, pour Kubernetes v1.37."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 5. Deployments et autres contrôleurs

Un pod seul ne se répare pas : si son nœud tombe, il est perdu, et si sa spec doit changer, il faut le recréer à la main. Ce chapitre étudie les objets qui font ce travail à ta place. Chacun est piloté par un contrôleur du kube-controller-manager qui compare en boucle l'état désiré à l'état observé ([chapitre 2.1](02-architecture.md)) : le ReplicaSet maintient un nombre de copies, le Deployment orchestre le passage d'une version à une autre, le DaemonSet place un pod par nœud, le StatefulSet donne à chaque pod une identité stable, le Job mène une tâche à son terme et le CronJob la planifie, tandis que le PodDisruptionBudget borne ce que les opérations de maintenance peuvent retirer. Le programme officiel y consacre deux compétences, *Understand application deployments and how to perform rolling update and rollbacks* et *Understand the primitives used to create robust, self-healing, application deployments*, et l'examen les vérifie presque à coup sûr : une mise à jour progressive avec des valeurs imposées de `maxSurge` et `maxUnavailable`, un retour à une révision précise, un DaemonSet, un CronJob. On y gagne des points vite à condition de connaître l'algorithme exact du rolling update, les arrondis, et la façon dont `kubectl rollout` manipule réellement les révisions.

### 5.1 Contrôleurs : déclarer un état, déléguer la réparation

Tous les contrôleurs de charge de travail suivent le même schéma. L'objet porte un **modèle de pod** (`spec.template`), un **sélecteur de labels** (`spec.selector`) qui désigne les pods dont il a la charge, et un objectif (un nombre de réplicas, un pod par nœud, un nombre de complétions). Le contrôleur crée les pods à partir du modèle et inscrit dans chacun une **référence de propriétaire** (`metadata.ownerReferences`, avec `controller: true`). Ce lien sert deux fois : il dit au contrôleur quels pods sont les siens, et il permet au ramasse-miettes de supprimer les pods quand leur propriétaire disparaît.

```
CHAÎNE DE PROPRIÉTÉ D'UN DEPLOYMENT
═══════════════════════════════════

  Deployment front ──(contrôleur Deployment)──▶ ReplicaSet front-6d4b8f7c9d   ← révision 2
        │                                       ReplicaSet front-5c8b6d4f7b   ← révision 1 (0 réplica)
        │                                               │
        │                                     (contrôleur ReplicaSet)
        │                                               ▼
        │                                  Pod front-6d4b8f7c9d-x2k8q
        │                                  Pod front-6d4b8f7c9d-9fj4d
        │                                  Pod front-6d4b8f7c9d-p7m2w
        │
  ownerReferences : Pod ──▶ ReplicaSet ──▶ Deployment
  kubectl delete deployment front : suppression en cascade (background) des ReplicaSets et des pods
```

La suppression d'un propriétaire se propage selon une politique choisie par le client : `background` (défaut de kubectl : le propriétaire disparaît tout de suite, ses dépendants ensuite), `foreground` (les dépendants d'abord, le propriétaire reste visible avec un finalizer `foregroundDeletion` jusqu'à la fin) ou `orphan` (les dépendants restent, sans propriétaire). Avec kubectl : `kubectl -n boutique delete deployment front --cascade=orphan` laisse les pods tourner, ce qui permet par exemple de recréer un Deployment dont on veut changer le sélecteur sans interrompre le service.

| Besoin | Contrôleur | Ce qu'il garantit |
|---|---|---|
| application sans état, N copies interchangeables | Deployment (qui pilote des ReplicaSets) | nombre de réplicas, mises à jour progressives, retour arrière |
| un agent sur chaque nœud | DaemonSet | un pod par nœud éligible, y compris les nœuds ajoutés plus tard |
| application à identité stable (base de données, quorum) | StatefulSet | noms et volumes stables, ordre de démarrage et d'arrêt |
| tâche finie | Job | N complétions réussies, avec un nombre borné d'échecs |
| tâche périodique | CronJob | un Job par échéance |

### 5.2 ReplicaSet

Un ReplicaSet maintient `spec.replicas` pods qui correspondent à son sélecteur. Il ne regarde pas l'image ni la version : il **compte**. S'il en manque, il en crée à partir du modèle ; s'il y en a trop, il en supprime. Cette logique de comptage a deux conséquences qu'il faut connaître.

La première est l'**adoption**. Un ReplicaSet considère comme siens tous les pods qui correspondent à son sélecteur et qui n'ont pas déjà un propriétaire contrôleur, même s'il ne les a pas créés. Un pod nu créé avec les mêmes labels est adopté, puis éventuellement supprimé s'il fait dépasser le nombre voulu. Les ReplicaSets d'un Deployment sont protégés contre ce piège : leur sélecteur inclut le label `pod-template-hash`, propre à chaque révision, qu'un pod créé à la main ne porte pas.

La seconde est l'**ordre de suppression** lors d'une réduction. Le contrôleur supprime d'abord les pods en attente (`Pending`, non planifiables), puis ceux dont l'annotation `controller.kubernetes.io/pod-deletion-cost` est la plus basse (valeur implicite 0, bêta active par défaut, respectée au mieux), puis ceux des nœuds qui portent le plus de réplicas, puis les plus récents.

On ne gère jamais à la main un ReplicaSet qui appartient à un Deployment : le Deployment le remet aussitôt à la valeur qu'il a décidée. Un `kubectl -n boutique scale rs front-6d4b8f7c9d --replicas=5` est annulé en une seconde. On agit toujours sur le Deployment.

### 5.3 Deployment : anatomie et valeurs par défaut

Un Deployment ajoute aux ReplicaSets la notion de **version**. Chaque modification de son modèle de pod produit un nouveau ReplicaSet, nommé `<deployment>-<pod-template-hash>`, et le Deployment fait passer les réplicas de l'ancien au nouveau selon sa stratégie. Les anciens ReplicaSets restent, à zéro réplica : ils sont l'**historique** qui permet le retour arrière. Leurs pods se nomment `<replicaset>-<5 caractères aléatoires>`.

Le générateur de kubectl produit l'essentiel ; on complète ensuite stratégie, sonde et ressources :

```bash
kubectl -n boutique create deployment front --image=nginx:1.29-alpine \
  --replicas=3 --port=80 --dry-run=client -o yaml > ~/cka/boutique/front.yaml
```

Le générateur nomme le conteneur d'après l'image (`nginx` ici, `agnhost` pour l'image agnhost) et ne pose que le label `app=<nom>`, dans le sélecteur comme dans le modèle. Le Deployment `front` complet du fil rouge est le suivant :

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: front
  namespace: boutique
  labels:
    app: front
    tier: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: front
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: front
        tier: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.29-alpine
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /
            port: 80
        resources:
          requests:
            cpu: 50m
            memory: 32Mi
          limits:
            cpu: 200m
            memory: 64Mi
```

| Champ | Défaut | Rôle |
|---|---|---|
| `replicas` | 1 | nombre de pods voulus ; à ne pas fixer si un HPA pilote le Deployment ([chapitre 7.12](07-autoscaling.md)) |
| `selector` | **obligatoire** en `apps/v1` | doit correspondre aux labels du modèle ; **immuable** après la création |
| `strategy.type` | `RollingUpdate` | ou `Recreate` |
| `strategy.rollingUpdate.maxSurge` | `25%` | pods en plus du nombre voulu pendant la mise à jour (arrondi **au-dessus**) |
| `strategy.rollingUpdate.maxUnavailable` | `25%` | pods voulus qui peuvent manquer (arrondi **au-dessous**) |
| `minReadySeconds` | 0 | durée pendant laquelle un pod doit rester prêt pour compter comme disponible |
| `progressDeadlineSeconds` | 600 | délai sans progrès avant de déclarer le rollout en échec ; doit dépasser `minReadySeconds` |
| `revisionHistoryLimit` | 10 | nombre d'anciens ReplicaSets conservés |
| `paused` | `false` | suspend les rollouts |
| `template.spec.restartPolicy` | `Always` | seule valeur permise |

Deux règles évitent les mauvaises surprises. Seule une modification du **modèle** (`spec.template`) crée une révision : changer `replicas`, la stratégie ou une annotation du Deployment ne crée rien et ne remplace aucun pod. Et le sélecteur ne change plus après la création : `kubectl apply` d'un manifeste au sélecteur modifié est refusé (`field is immutable`). Il faut alors supprimer le Deployment (avec `--cascade=orphan` si les pods doivent survivre) et le recréer.

> [!warning]
> Le sélecteur doit correspondre aux labels du modèle, sinon la création échoue : `` spec.template.metadata.labels: Invalid value: …: `selector` does not match template `labels` ``. Le modèle peut porter **plus** de labels que le sélecteur (`tier: web` en plus de `app: front`) : c'est même ce qu'on veut, puisque le sélecteur immuable doit rester minimal.

### 5.4 L'algorithme du rolling update

#### Deux bornes et leurs arrondis

La stratégie `RollingUpdate` remplace les pods par vagues, entre deux bornes calculées à partir du nombre voulu `R` :

- **`maxSurge`** fixe le plafond : jamais plus de `R + maxSurge` pods au total (anciens et nouveaux, prêts ou non). Un pourcentage est converti en nombre en arrondissant **au-dessus**.
- **`maxUnavailable`** fixe le plancher : jamais moins de `R − maxUnavailable` pods **disponibles**. Un pourcentage est converti en arrondissant **au-dessous**.

Les deux arrondis vont dans le sens de la prudence : on tolère un pod de plus plutôt qu'un pod disponible de moins. La validation refuse que les deux valeurs soient nulles (`may not be 0 when maxSurge is 0`), puisque le rollout ne pourrait jamais avancer. Mais un pourcentage peut s'arrondir à zéro : si les deux bornes **calculées** valent 0, le contrôleur force `maxUnavailable` à 1.

| R | maxSurge | maxUnavailable | Surge calculé | Indispo. calculé | Pods au total | Pods disponibles |
|---|---|---|---|---|---|---|
| 3 | 25 % (défaut) | 25 % (défaut) | ⌈0,75⌉ = 1 | ⌊0,75⌋ = 0 | 3 à 4 | jamais moins de 3 |
| 4 | 25 % | 25 % | 1 | 1 | 4 à 5 | au moins 3 |
| 10 | 25 % | 25 % | ⌈2,5⌉ = 3 | ⌊2,5⌋ = 2 | 10 à 13 | au moins 8 |
| 3 | 1 | 0 | 1 | 0 | 3 à 4 | jamais moins de 3 (`front`) |
| 3 | 0 | 10 % | 0 | ⌊0,3⌋ = 0 → forcé à 1 | 2 à 3 | au moins 2 |
| 1 | 25 % | 25 % | 1 | 0 | 1 à 2 | jamais 0 |

« Disponible » a un sens précis : un pod **prêt** (sa condition `Ready` est vraie, donc ses sondes de disponibilité réussissent) depuis au moins `minReadySeconds`. Sans sonde de disponibilité, un pod est prêt dès que ses conteneurs tournent, et le Deployment avance même si l'application répond en erreur : la `readinessProbe` est ce qui rend un rolling update sûr.

#### Le déroulé pour `front`

Le contrôleur alterne deux opérations. Il **augmente** le nouveau ReplicaSet tant que le total reste sous le plafond, puis il **réduit** les anciens tant que les pods disponibles restent au-dessus du plancher, en comptant comme indisponibles les nouveaux pods qui ne sont pas encore prêts. Pour `front` (R = 3, maxSurge 1, maxUnavailable 0) :

```
ROLLING UPDATE DE front : nginx 1.29 → 1.30.6   (plafond 4 pods, plancher 3 disponibles)
═══════════════════════════════════════════════════════════════════════════════════════

 étape  ancien RS (1.29)  nouveau RS (1.30.6)        total  disponibles  action suivante
 ─────  ────────────────  ─────────────────────────  ─────  ───────────  ──────────────────────────
   0          3                  0                     3         3       +1 nouveau (plafond 4)
   1          3                  1  (pas encore prêt)  4         3       attendre : 4 − 3 − 1 = 0 à retirer
   2          3                  1  prêt               4         4       −1 ancien
   3          2                  1                     3         3       +1 nouveau
   4          2                  2  (pas encore prêt)  4         3       attendre
   5          1                  2                     3         3       +1 nouveau
   6          1                  3  (pas encore prêt)  4         3       attendre
   7          0                  3                     3         3       terminé
```

À aucun moment moins de trois pods ne servent. Si un nouveau pod ne devient jamais prêt (image introuvable, sonde qui échoue), le rollout reste bloqué à l'étape 1 : trois anciens pods servent toujours, et le Deployment attend. C'est la vraie protection d'un `maxUnavailable: 0`, que la panne 01 du [chapitre 22](22-depanner-les-applications.md) met en scène.

#### Les cas particuliers

**Recreate.** Avec `strategy.type: Recreate`, tous les anciens pods sont supprimés, et le contrôleur attend leur disparition complète avant de créer les nouveaux. Il y a une coupure, mais jamais deux versions en même temps : c'est le choix pour une application qui ne supporte pas la cohabitation de deux versions (schéma de base incompatible, volume `ReadWriteOnce` monté par un seul pod). Le bloc `rollingUpdate` doit alors être absent.

**Mise à jour pendant un rollout.** Si le modèle change de nouveau en cours de route, le Deployment crée un troisième ReplicaSet et traite le deuxième comme un ancien : il ne termine pas la version intermédiaire (*rollover*).

**Mise à l'échelle pendant un rollout.** Si `replicas` change pendant qu'un rollout est en cours (ou en pause), les réplicas supplémentaires sont répartis entre les ReplicaSets actifs au prorata de leur taille (*proportional scaling*), le reste allant au plus gros.

**Pods en cours d'arrêt.** Un pod en `Terminating` ne compte plus comme réplica, alors qu'il consomme encore des ressources : le total réel peut dépasser le plafond pendant le délai de grâce. Depuis 1.35 (porte `DeploymentReplicaSetTerminatingReplicas`, bêta active), `status.terminatingReplicas` du Deployment et des ReplicaSets les compte.

### 5.5 Piloter un rollout avec kubectl

#### Déclencher une révision

Toute modification du modèle déclenche un rollout. Les commandes impératives couvrent les cas fréquents :

```bash
kubectl -n boutique set image deployment/front nginx=nginx:1.30.6-alpine
kubectl -n boutique set env deployment/api LOG_LEVEL=debug
kubectl -n boutique set resources deployment/front -c nginx --limits=cpu=300m
kubectl -n boutique edit deployment front
kubectl -n boutique rollout restart deployment/front
```

`kubectl set image` prend le **nom du conteneur** (`nginx`), pas celui de l'image ; `*` vise tous les conteneurs. `kubectl rollout restart` ne change rien d'utile : il pose l'annotation `kubectl.kubernetes.io/restartedAt` dans le modèle, ce qui suffit à créer une révision et à remplacer tous les pods. C'est la façon propre de relire une ConfigMap consommée en variables d'environnement ([chapitre 6.4](06-configmaps-et-secrets.md)).

`kubectl rollout status` suit la progression et rend la main à la fin. Ses messages décrivent l'état exact :

```
Waiting for deployment "front" rollout to finish: 1 out of 3 new replicas have been updated...
Waiting for deployment "front" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "front" rollout to finish: 2 of 3 updated replicas are available...
deployment "front" successfully rolled out
```

Avec `--timeout=2m`, la commande échoue au bout de deux minutes ; si le Deployment a dépassé son `progressDeadlineSeconds`, elle sort en erreur : `error: deployment "front" exceeded its progress deadline`.

#### L'historique et `kubernetes.io/change-cause`

`kubectl rollout history` liste les révisions, c'est-à-dire les ReplicaSets du Deployment, triés par leur annotation `deployment.kubernetes.io/revision`. La colonne `CHANGE-CAUSE` affiche l'annotation `kubernetes.io/change-cause` **du ReplicaSet** de chaque révision, ou `<none>`.

```
deployment.apps/front
REVISION  CHANGE-CAUSE
1         <none>
2         image nginx:1.30.6-alpine
```

Le mécanisme de cette annotation explique tous ses pièges. Le contrôleur Deployment **recopie les annotations du Deployment sur le ReplicaSet courant**, à chaque synchronisation (sauf quelques annotations techniques : révision, réplicas voulus, `last-applied-configuration`). Il en découle :

- on annote le Deployment **juste après** avoir changé le modèle : l'annotation atterrit sur le nouveau ReplicaSet ;
- annoter **avant** le changement est une erreur : le contrôleur réécrit aussitôt la cause de la révision **courante**, qui hérite d'un texte qui ne la décrit pas ;
- une révision créée sans nouvelle annotation hérite de la cause précédente, toujours présente sur le Deployment ;
- pour tout faire en une écriture, un seul patch modifie le modèle et l'annotation, ou un manifeste porte les deux et passe par `kubectl apply`.

```bash
kubectl -n boutique set image deployment/front nginx=nginx:1.30.6-alpine
kubectl -n boutique annotate deployment/front kubernetes.io/change-cause="image nginx:1.30.6-alpine" --overwrite
```

L'ancienne option `--record`, qui écrivait la ligne de commande dans cette annotation, existe toujours en 1.37, mais elle est **dépréciée et masquée** de l'aide : elle affiche `Flag --record has been deprecated, --record will be removed in the future`. Ne l'utilise plus.

`kubectl -n boutique rollout history deployment/front --revision=2` affiche le modèle complet d'une révision : c'est la façon de vérifier, avant un retour arrière, que la révision visée contient bien ce qu'on croit.

#### Le retour arrière, tel qu'il se passe vraiment

`kubectl -n boutique rollout undo deployment/front` revient à la révision précédente ; `--to-revision=N` vise une révision précise. Ce n'est pas un mécanisme du serveur, mais une opération de kubectl : il lit le ReplicaSet de la révision visée, recopie son **modèle** dans le Deployment, et remplace les annotations du Deployment par celles de ce ReplicaSet (sauf les annotations techniques). Le contrôleur voit alors un modèle identique à celui d'un ancien ReplicaSet : il le **réutilise** (même `pod-template-hash`) et lui donne le **numéro de révision suivant**. L'ancien numéro disparaît de l'historique.

```
AVANT undo                     APRÈS rollout undo                 APRÈS rollout undo --to-revision=2
REVISION  CHANGE-CAUSE         REVISION  CHANGE-CAUSE             REVISION  CHANGE-CAUSE
1         <none>               2         image nginx:1.30.6-…     3         <none>
2         image nginx:1.30.6-… 3         <none>                   4         image nginx:1.30.6-alpine
          (courante : 2)                 (courante : 3 = ex-1)              (courante : 4 = ex-2)
```

Trois conséquences pour l'examen. « Reviens à la révision 1 » se fait avec `--to-revision=1` tant que la révision 1 existe ; après un premier `undo`, elle s'appelle 3. Un `rollout undo` sur un Deployment en pause est refusé (`you cannot rollback a paused deployment; resume it first with 'kubectl rollout resume' and try again`). Et un retour vers une révision identique au modèle courant ne fait rien (`skipped rollback (current template already matches revision N)`). Le Deployment ne revient **jamais** de lui-même en arrière : un rollout bloqué le reste jusqu'à ce que quelqu'un agisse.

> [!danger] Le fichier et le cluster divergent
> `set image`, `annotate` et `rollout undo` modifient l'objet dans le cluster, pas ton fichier ; `rollout undo` le rappelle d'ailleurs sur un objet créé par `apply` (`Warning: … Rolling back will not update the kubectl.kubernetes.io/last-applied-configuration annotation …`). Un `kubectl apply -f front.yaml` ultérieur, avec l'ancienne image dans le fichier, relancerait un rollout vers l'ancienne version. Après toute modification impérative, remets le fichier en accord, puis vérifie que `kubectl diff -f front.yaml` n'affiche rien (code de retour 0).

#### Pause, reprise et conditions

`kubectl -n boutique rollout pause deployment/front` suspend les rollouts : les modifications du modèle s'accumulent sans remplacer de pod, puis `kubectl rollout resume` les applique en **une seule** révision. C'est utile pour changer image, ressources et variables d'un coup. Pendant la pause, `kubectl scale` fonctionne toujours.

L'état d'un rollout se lit dans les conditions du Deployment :

| Condition | Statut et raison | Signification |
|---|---|---|
| `Progressing` | `True`, `NewReplicaSetCreated` / `FoundNewReplicaSet` / `ReplicaSetUpdated` | rollout en cours, il avance |
| `Progressing` | `True`, `NewReplicaSetAvailable` | rollout terminé |
| `Progressing` | `False`, `ProgressDeadlineExceeded` | aucun progrès depuis `progressDeadlineSeconds` (600 s par défaut) |
| `Available` | `True`, `MinimumReplicasAvailable` / `False`, `MinimumReplicasUnavailable` | au moins `R − maxUnavailable` pods disponibles, ou non |
| `ReplicaFailure` | `True`, `FailedCreate` | le ReplicaSet ne peut pas créer de pods (quota dépassé, admission refusée) |

`ProgressDeadlineExceeded` ne fait qu'**informer** : le contrôleur continue d'essayer, et rien n'est annulé. Le nombre d'anciens ReplicaSets conservés est borné par `revisionHistoryLimit` ; à 0, plus aucun retour arrière n'est possible. Le nettoyage n'a lieu qu'une fois le rollout terminé : un Deployment qui enchaîne des rollouts bloqués peut garder plus d'anciens ReplicaSets que la limite.

> [!tip] Réflexe d'examen
> Énoncé type : « mets à jour vers l'image X, puis reviens à la version précédente ». Commandes : `set image`, `rollout status`, `rollout history`, `rollout undo`. Vérifie toujours l'image effective avec `kubectl -n boutique get deployment front -o jsonpath='{.spec.template.spec.containers[0].image}'` et l'état des pods, pas seulement la sortie de `undo`. La page à ouvrir : « Deployments » (kubernetes.io/docs/concepts/workloads/controllers/deployment/).

### 5.6 DaemonSet

Un DaemonSet place **un pod par nœud éligible** : agents de journalisation ou de supervision, plugins réseau (Calico tourne ainsi dans `kube-system`), pilotes de stockage, kube-proxy. Quand un nœud rejoint le cluster, il reçoit son pod ; quand il part, le pod est ramassé.

Le placement passe par le scheduler, mais de façon contrainte : le contrôleur DaemonSet crée un pod par nœud et y inscrit une affinité de nœud requise sur le **nom** du nœud (`matchFields` sur `metadata.name`), que le scheduler respecte. Un `nodeSelector` ou une affinité dans le modèle restreint les nœuds éligibles. Le contrôleur ajoute aussi d'office des tolerations, pour que l'agent tourne là où les autres pods ne vont pas :

| Toleration ajoutée | Effet |
|---|---|
| `node.kubernetes.io/not-ready`, `node.kubernetes.io/unreachable` | `NoExecute` : le pod n'est pas évincé d'un nœud malade |
| `node.kubernetes.io/disk-pressure`, `memory-pressure`, `pid-pressure` | `NoSchedule` : placement possible sur un nœud sous pression |
| `node.kubernetes.io/unschedulable` | `NoSchedule` : placement possible sur un nœud cordonné |
| `node.kubernetes.io/network-unavailable` | `NoSchedule`, seulement pour un pod en `hostNetwork` |

La taint `node-role.kubernetes.io/control-plane:NoSchedule` n'est **pas** dans cette liste : sur un cluster kubeadm, un DaemonSet ne tourne pas sur les control planes, sauf toleration explicite (l'[exercice 8.5](08-ordonnancement-et-admission.md) l'ajoute à `agent-noeud`).

> [!info] minikube ≠ examen
> Le control plane `cka` du lab ne porte aucune taint : `agent-noeud` y tourne comme sur les workers, et le DaemonSet annonce 3 pods. Sur un cluster kubeadm d'examen à un control plane et deux workers, le même DaemonSet en annonce 2.

Les mises à jour suivent `spec.updateStrategy`. `RollingUpdate` (défaut) remplace les pods nœud par nœud, avec `maxUnavailable` (défaut 1) et `maxSurge` (défaut 0) ; contrairement au Deployment, **exactement une** des deux valeurs doit être non nulle (`maxSurge` « may not be set when maxUnavailable is non-zero »). Avec `maxSurge: 1` et `maxUnavailable: 0`, le nouveau pod démarre à côté de l'ancien sur chaque nœud, ce qui est impossible si le pod réserve un `hostPort`. `OnDelete` ne remplace un pod que lorsque tu le supprimes. `kubectl rollout status`, `history`, `undo` et `restart` fonctionnent sur les DaemonSets.

> [!tip] Réflexe d'examen
> Il n'existe pas de `kubectl create daemonset`. Génère un Deployment, puis transforme-le : `kubectl -n boutique create deployment agent-noeud --image=busybox:1.37.0 --dry-run=client -o yaml > ds.yaml`, change `kind: Deployment` en `kind: DaemonSet`, supprime `replicas`, `strategy` et `status`. Trente secondes au lieu de trois minutes de frappe.

### 5.7 StatefulSet : l'identité stable

Un StatefulSet gère des pods qui ne sont **pas** interchangeables. Chacun reçoit un ordinal et un nom fixe, `<statefulset>-0`, `<statefulset>-1`…, qu'il garde quand il est recréé, sur n'importe quel nœud. Chacun reçoit aussi un nom DNS stable, `<pod>.<service>.<namespace>.svc.cluster.local`, à condition qu'un **Service headless** (sans adresse de cluster, [chapitre 10.9](10-services.md)) existe et que le StatefulSet le désigne dans `serviceName` ; c'est à toi de créer ce Service. Enfin, chaque pod reçoit ses propres volumes, créés à partir de `volumeClaimTemplates`, qui le suivent d'une recréation à l'autre : c'est l'objet du [chapitre 15.11](15-stockage.md), où le StatefulSet `redis` du fil rouge les met en pratique.

| Aspect | Comportement |
|---|---|
| Démarrage (`podManagementPolicy: OrderedReady`, défaut) | dans l'ordre 0, 1, 2…, chaque pod attendant que le précédent soit `Running` et prêt |
| Arrêt et réduction | dans l'ordre inverse ; un pod n'est arrêté que lorsque ses successeurs ont disparu |
| `podManagementPolicy: Parallel` | création et suppression simultanées ; ne concerne pas les mises à jour |
| Mise à jour `RollingUpdate` (défaut) | de l'ordinal le plus élevé au plus bas, un pod à la fois |
| `rollingUpdate.partition: N` | seuls les ordinaux ≥ N sont mis à jour : déploiement par étapes, canari |
| `rollingUpdate.maxUnavailable` | plusieurs pods à la fois (défaut 1, arrondi au-dessus, jamais 0) ; bêta, **active par défaut depuis 1.37** |
| `OnDelete` | remplacement seulement quand tu supprimes le pod |
| Labels posés par le contrôleur | `statefulset.kubernetes.io/pod-name` et `apps.kubernetes.io/pod-index` |
| Suppression du StatefulSet | aucun ordre garanti ; réduire à 0 d'abord pour un arrêt ordonné ; les volumes restent |

Un piège est documenté comme tel : avec `OrderedReady`, une mise à jour vers un modèle qui ne devient jamais prêt bloque le StatefulSet, et **revenir au bon modèle ne suffit pas**. Le contrôleur attend que le pod défectueux devienne prêt, ce qui n'arrivera pas ; il faut supprimer ce pod pour qu'il soit recréé avec le modèle corrigé. Le StatefulSet ne doit pas non plus fixer `terminationGracePeriodSeconds: 0`, et on ne force pas la suppression d'un de ses pods (`--grace-period=0 --force`) sans être sûr que le nœud est vraiment arrêté : deux pods du même nom pourraient écrire sur le même volume.

### 5.8 Job

#### Complétions et parallélisme

Un Job crée des pods jusqu'à obtenir un nombre de **complétions** réussies. Son modèle de pod n'accepte que `restartPolicy: OnFailure` ou `Never`. Deux champs règlent le travail :

| `completions` | `parallelism` | Type de Job | Fin |
|---|---|---|---|
| absent | absent | simple : les deux valent 1 | un pod réussi |
| N | P (défaut 1) | nombre fixe de complétions | N pods réussis ; jamais plus de P en même temps, ni plus que les complétions restantes |
| absent | P | file de travail | dès qu'un pod réussit, plus aucun pod n'est créé ; fin quand tous sont terminés |

Avec `completionMode: Indexed`, chaque pod reçoit un **index** de 0 à N−1 (variable `JOB_COMPLETION_INDEX`, annotation et label `batch.kubernetes.io/job-completion-index`, nom d'hôte `<job>-<index>`), et le Job se termine quand chaque index a réussi une fois. Mettre `parallelism` à 0 suspend de fait le Job ; `spec.suspend: true` le fait explicitement, en supprimant les pods actifs.

Le Job pose sur ses pods les labels `batch.kubernetes.io/job-name` et `batch.kubernetes.io/controller-uid`, et génère son propre sélecteur : on ne fixe pas `spec.selector`. `kubectl get job` affiche une colonne `STATUS` qui vaut `Running`, `Complete`, `Failed`, `Suspended`, `Terminating`, `FailureTarget` ou `SuccessCriteriaMet`, et une colonne `COMPLETIONS` (`2/3`).

```bash
kubectl -n boutique create job migration --image=busybox:1.37.0 \
  --dry-run=client -o yaml -- sh -c 'echo migration du lot sur $HOSTNAME; sleep 10' > migration.yaml
```

Le générateur pose `restartPolicy: Never` et nomme le conteneur comme le Job ; on ajoute ensuite `completions`, `parallelism` et `ttlSecondsAfterFinished`.

#### Échecs : backoffLimit et délais

Par défaut, chaque échec de pod compte. Au-delà de `backoffLimit` (défaut **6**), le Job est en échec : condition `Failed`, raison `BackoffLimitExceeded`, et les pods encore actifs sont arrêtés. Le décompte se fait de deux façons, et la première atteinte l'emporte : le nombre de pods en phase `Failed` (cas `Never`), et le nombre de redémarrages de conteneurs dans les pods actifs (cas `OnFailure`). Les pods en échec sont recréés avec un délai exponentiel de 10 s, 20 s, 40 s…, plafonné à **10 minutes**.

Le choix de la `restartPolicy` a un effet de bord : avec `OnFailure`, le kubelet relance le conteneur dans le même pod, et quand la limite est atteinte, ce pod est supprimé avec ses journaux. Pour déboguer un Job, `Never` garde chaque tentative dans un pod distinct, consultable.

`activeDeadlineSeconds` borne la durée totale du Job, toutes tentatives comprises, et prime sur `backoffLimit` : à l'échéance, les pods sont arrêtés et le Job échoue avec la raison `DeadlineExceeded`. Le champ existe aussi dans la spec du pod, avec un autre sens (durée d'un seul pod) : vérifie le niveau où tu le poses.

#### podFailurePolicy : décider selon la cause

Compter tous les échecs de la même façon est souvent faux : un code de sortie qui signale une donnée invalide ne guérira pas en réessayant, et un pod évincé pendant la maintenance d'un nœud n'est pas un échec de la tâche. `spec.podFailurePolicy` décide, pour chaque pod en échec, d'une action selon son code de sortie ou ses conditions. Elle **exige** `restartPolicy: Never` (sinon : `only "Never" is supported when podFailurePolicy is specified`).

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: import
  namespace: boutique
spec:
  backoffLimit: 6
  podFailurePolicy:
    rules:
    - action: FailJob
      onExitCodes:
        containerName: import
        operator: In
        values: [42]
    - action: Ignore
      onPodConditions:
      - type: DisruptionTarget
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: import
        image: busybox:1.37.0
        command: ["sh", "-c", "echo import; exit 0"]
```

Les règles sont évaluées dans l'ordre, la première qui correspond s'applique, et un échec qu'aucune règle ne couvre suit le décompte normal. Les actions possibles :

| Action | Effet |
|---|---|
| `FailJob` | le Job échoue immédiatement (raison `PodFailurePolicy`), ses pods actifs sont arrêtés |
| `Ignore` | l'échec ne compte pas dans `backoffLimit` ; un pod de remplacement est créé |
| `Count` | décompte normal |
| `FailIndex` | avec `backoffLimitPerIndex` : l'index échoue sans réessai |

`onExitCodes` compare les codes avec `In` ou `NotIn` (le code 0 est interdit dans la liste avec `In`), sur un conteneur nommé ou sur tous. `onPodConditions` reconnaît en pratique `DisruptionTarget`, posée sur les pods supprimés par une préemption, une éviction par l'API, une taint `NoExecute` ou le nettoyage des pods orphelins. Avec une politique d'échec, un pod en cours d'arrêt n'est remplacé qu'une fois réellement terminé (`podReplacementPolicy` vaut alors `Failed`, sans autre choix possible ; sans politique, la valeur par défaut est `TerminatingOrFailed`).

#### Index, politique de succès et fin du Job

Deux mécanismes affinent les Jobs indexés, tous deux **stables depuis 1.33**. `backoffLimitPerIndex` compte les échecs **par index** au lieu de globalement : un index qui dépasse sa limite est marqué en échec (`status.failedIndexes`) sans interrompre les autres, et le Job échoue à la fin si au moins un index a échoué. `maxFailedIndexes` arrête tout dès que trop d'index ont échoué. Quand `backoffLimitPerIndex` est fixé, `backoffLimit` vaut par défaut 2147483647.

`successPolicy` déclare le Job réussi **avant** que tous les index aient réussi, par des règles qui combinent `succeededIndexes` (une liste d'intervalles, `0,2-3`) et `succeededCount`. C'est le cas d'un calcul maître-esclaves où seule la réussite du maître compte : le Job reçoit la condition `SuccessCriteriaMet` (raison `SuccessPolicy`), les pods restants sont arrêtés, puis vient `Complete`. Si une politique d'échec se déclenche aussi, l'échec l'emporte.

Depuis 1.31, les conditions terminales `Complete` et `Failed` ne sont posées qu'**après** l'arrêt de tous les pods ; les conditions `SuccessCriteriaMet` et `FailureTarget` les précèdent et permettent de réagir plus tôt. Le Job terminé reste visible avec ses pods, pour qu'on lise leurs journaux, jusqu'à ce qu'on le supprime ou que `ttlSecondsAfterFinished` le fasse : passé ce délai, le contrôleur TTL supprime le Job **et ses pods** (à 0, dès la fin ; absent, jamais). `kubectl delete job` supprime aussi les pods.

> [!note] Jobs et sidecars
> Un sidecar natif ([chapitre 4.10](04-pods.md)) n'empêche pas un pod de Job de se terminer : quand le conteneur principal a fini, le kubelet arrête les sidecars et le pod atteint la phase `Succeeded`. Un sidecar déclaré dans `containers`, lui, bloque le Job indéfiniment.

### 5.9 CronJob

Un CronJob crée un Job à chaque échéance d'un calendrier au format cron, comme une ligne de crontab :

```
# ┌───────────── minute (0 - 59)
# │ ┌───────────── heure (0 - 23)
# │ │ ┌───────────── jour du mois (1 - 31)
# │ │ │ ┌───────────── mois (1 - 12)
# │ │ │ │ ┌───────────── jour de la semaine (0 - 6, dimanche = 0, ou sun…sat)
# * * * * *
```

Les pas (`*/5`, `0-23/2`), les listes, les intervalles et les macros `@hourly`, `@daily` (ou `@midnight`), `@weekly`, `@monthly`, `@yearly` (ou `@annually`) sont acceptés ; `?` équivaut à `*`.

| Champ | Défaut | Rôle |
|---|---|---|
| `schedule` | obligatoire | calendrier |
| `timeZone` | fuseau du kube-controller-manager | fuseau IANA dans lequel lire le calendrier (stable depuis 1.27) |
| `concurrencyPolicy` | `Allow` | `Forbid` : saute l'échéance si le Job précédent tourne encore ; `Replace` : remplace le Job en cours |
| `startingDeadlineSeconds` | aucun | retard maximal toléré pour lancer un Job ; au-delà, l'échéance est sautée |
| `suspend` | `false` | suspend les créations (sans toucher aux Jobs déjà lancés) |
| `successfulJobsHistoryLimit` | 3 | Jobs réussis conservés |
| `failedJobsHistoryLimit` | 1 | Jobs échoués conservés |
| `jobTemplate` | obligatoire | modèle de Job (avec ses propres labels) |

Le **fuseau** demande de la rigueur. `timeZone: Europe/Paris` fait lire le calendrier en heure de Paris, changements d'heure compris ; un nom invalide est refusé à la création (`unknown time zone Europe/Pari`), `Local` aussi, et les préfixes `CRON_TZ=` ou `TZ=` dans `schedule` sont rejetés (`cannot use TZ or CRON_TZ in schedule, use timeZone field instead`). Le champ ne touche **que** l'interprétation du calendrier : les conteneurs du Job gardent leur propre fuseau (UTC pour busybox), et un `date` y affiche l'heure UTC. Note aussi qu'un calendrier en minutes seules, comme le `*/5 * * * *` du fil rouge, se déclenche aux mêmes instants dans tous les fuseaux ; le fuseau ne change quelque chose que pour les champs heure, jour et mois.

Le contrôleur CronJob vérifie ses calendriers toutes les 10 secondes. Il en découle les règles de `startingDeadlineSeconds` : une valeur inférieure à 10 secondes peut faire sauter des exécutions. Quand le contrôleur a été indisponible, il compte les échéances manquées depuis la dernière exécution (ou seulement dans la fenêtre `startingDeadlineSeconds` si elle est fixée) ; au-delà de **100** échéances manquées, il ne lance rien et journalise `too many missed start times. Set or decrease .spec.startingDeadlineSeconds or check clock skew`. Avec `Forbid`, une échéance sautée parce que le Job précédent tournait compte comme manquée. Une suspension compte de même : sans `startingDeadlineSeconds`, la reprise (`suspend: false`) rattrape aussitôt l'échéance manquée.

Les Jobs créés se nomment `<cronjob>-<horaire prévu en minutes depuis l'époque Unix>` (par exemple `rapport-29879760` pour 20 h 00 UTC le 23 octobre 2026) et portent l'annotation `batch.kubernetes.io/cronjob-scheduled-timestamp`. Ce suffixe de 11 caractères explique la limite de **52 caractères** du nom d'un CronJob. Modifier un CronJob ne change que les Jobs à venir.

Pour tester un CronJob sans attendre l'échéance, on crée un Job à partir de son modèle :

```bash
kubectl -n boutique create job rapport-manuel --from=cronjob/rapport
```

Ce Job reçoit l'annotation `cronjob.kubernetes.io/instantiate: manual` et une référence de propriétaire **contrôleur** vers le CronJob : il compte dans l'historique de ce dernier et disparaît avec lui.

> [!tip] Réflexe d'examen
> `kubectl -n boutique create cronjob rapport --image=busybox:1.37.0 --schedule='*/5 * * * *' --dry-run=client -o yaml -- sh -c 'date; echo rapport genere'` produit l'essentiel ; ajoute `timeZone`, `concurrencyPolicy` et les limites d'historique à la main (aucune option ne les couvre). Le générateur pose `restartPolicy: OnFailure`. Mets toujours le calendrier entre apostrophes : sans elles, le shell développe les `*`.

### 5.10 PodDisruptionBudget

#### Perturbations volontaires et involontaires

Une **perturbation involontaire** est subie : panne matérielle, noyau en panique, nœud qui disparaît, éviction pour manque de ressources. Une **perturbation volontaire** est décidée : vidage d'un nœud avant maintenance (`kubectl drain`), mise à jour du cluster, réduction par l'autoscaler de cluster. Un PodDisruptionBudget (PDB, `policy/v1`) ne protège que contre les secondes, et seulement contre celles qui passent par l'**API d'éviction** (la sous-ressource `pods/eviction`), comme le fait `kubectl drain`. Une suppression directe (`kubectl delete pod`) l'ignore, tout comme le rolling update d'un Deployment ou d'un StatefulSet, qui a ses propres bornes (`maxUnavailable`). Les perturbations involontaires ne sont pas bloquées, mais elles **consomment** le budget.

L'API d'éviction répond `200 OK` (pod évincé, suppression gracieuse), `429 Too Many Requests` (le budget l'interdit pour l'instant ; `kubectl drain` réessaie toutes les 5 secondes) ou `500 Internal Server Error` (configuration incohérente, par exemple un pod couvert par plusieurs PDB). Un pod qu'aucun PDB ne couvre est toujours évincé.

#### Le budget

Un PDB désigne des pods par un sélecteur et fixe **soit** `minAvailable`, **soit** `maxUnavailable` (jamais les deux), en nombre ou en pourcentage. Un pod compte comme **sain** quand sa condition `Ready` est vraie. Le contrôleur de perturbation calcule les champs du statut : `expectedPods` (le nombre voulu, lu sur le contrôleur propriétaire des pods), `desiredHealthy`, `currentHealthy` et `disruptionsAllowed`.

| Spécification | Pods voulus | Pods sains requis | Évictions permises (tous sains) |
|---|---|---|---|
| `minAvailable: 2` (`front`) | 3 | 2 | 1 |
| `minAvailable: "50%"` | 7 | ⌈3,5⌉ = 4 | 3 |
| `maxUnavailable: 1` | 3 | 2 | 1 |
| `maxUnavailable: "30%"` | 3 | 3 − ⌈0,9⌉ = 2 | 1 |
| `maxUnavailable: "30%"` | 1 | 0 | 1 (100 % d'indisponibilité) |
| `minAvailable: 3` | 3 | 3 | **0** : `drain` ne finit jamais |

Les pourcentages sont arrondis **au-dessus** dans les deux sens, ce qui rend `maxUnavailable` en pourcentage plus permissif qu'il n'y paraît. `maxUnavailable` et les pourcentages exigent que les pods appartiennent à un contrôleur doté d'une échelle (Deployment, ReplicaSet, StatefulSet, ReplicationController, ou ressource personnalisée avec sous-ressource `scale`) ; pour des pods nus, seul un `minAvailable` entier est possible. Un sélecteur vide (`{}`) couvre tous les pods du namespace.

#### Les pods déjà malades

Que faire d'un pod `Running` mais non prêt, quand le budget est déjà entamé ? `spec.unhealthyPodEvictionPolicy` (stable depuis 1.31) décide. `IfHealthyBudget`, la valeur par défaut, ne l'autorise que si l'application n'est pas déjà en dessous de son budget, pour lui laisser une chance de guérir ; le revers est qu'une application en `CrashLoopBackOff` peut bloquer un `drain` indéfiniment. `AlwaysAllow` évince les pods non prêts sans condition, et c'est la valeur que la documentation recommande pour ne pas laisser une application défaillante bloquer la maintenance. Les pods `Pending`, `Succeeded` ou `Failed` sont toujours évinçables.

```bash
kubectl -n boutique create pdb front --selector=app=front --min-available=2
kubectl -n boutique get pdb front
```

```
NAME    MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
front   2               N/A               1                     8s
```

Le vidage de nœud, son interaction avec ce PDB et les messages de `kubectl drain` sont traités au [chapitre 8.14](08-ordonnancement-et-admission.md).

### 5.11 Synthèse : les primitives d'auto-réparation

Une application « robuste et auto-réparatrice », au sens du programme, combine plusieurs mécanismes qui agissent à des niveaux et à des vitesses différents. Les connaître ensemble permet de répondre à la question qu'on se pose devant toute panne : qui est censé réparer, et pourquoi ne l'a-t-il pas fait ?

| Panne | Qui réagit | Mécanisme | Délai typique |
|---|---|---|---|
| processus qui s'arrête | kubelet | `restartPolicy` ([chapitre 4.5](04-pods.md)) | immédiat, puis 10 s doublés jusqu'à 300 s |
| application bloquée | kubelet | `livenessProbe` | `failureThreshold × periodSeconds` (30 s par défaut) |
| application momentanément incapable de servir | contrôleur EndpointSlice | `readinessProbe` : retrait du trafic | idem, sans redémarrage |
| pod supprimé ou évincé | contrôleur du propriétaire (ReplicaSet, StatefulSet, DaemonSet, Job) | réconciliation du nombre de pods | quelques secondes |
| nœud perdu | contrôleur de cycle de vie des nœuds | `NotReady` après 50 s, taints `NoExecute`, éviction après la `tolerationSeconds` de 300 s posée par l'admission `DefaultTolerationSeconds` | environ 6 minutes |
| nouvelle version défectueuse | contrôleur Deployment | `maxUnavailable` + `readinessProbe` : rollout bloqué, ancienne version servie ; `ProgressDeadlineExceeded` | arrêt immédiat de la progression ; retour arrière **manuel** |
| maintenance d'un nœud | API d'éviction | PodDisruptionBudget | évictions retardées tant que le budget l'exige |
| tâche qui échoue | contrôleur Job | `backoffLimit`, `podFailurePolicy`, `activeDeadlineSeconds` | 10 s doublés jusqu'à 10 min entre essais |

Le fil rouge assemble ces primitives : `front` a trois réplicas, une sonde de disponibilité, une stratégie qui ne retire jamais un pod avant que son remplaçant soit prêt, et un PDB qui garde deux pods sains pendant les maintenances.

### 5.12 Pièges courants

```
Piège 1 : Annoter change-cause avant la modification
════════════════════════════════════════════════════
  MAUVAIS  : kubectl annotate deploy/front kubernetes.io/change-cause=… ; puis set image
  SYMPTÔME : la révision COURANTE prend la nouvelle cause, l'historique ment
  BON      : set image d'abord, annotate --overwrite ensuite (ou un seul apply)

Piège 2 : Viser un numéro de révision qui a changé
══════════════════════════════════════════════════
  SYMPTÔME : « unable to find the specified revision »
  CAUSE    : un undo renumérote la révision réutilisée (1 devient 3)
  BON      : kubectl rollout history (et --revision=N) avant chaque undo

Piège 3 : Réappliquer un fichier périmé
═══════════════════════════════════════
  MAUVAIS  : set image en impératif, puis plus tard kubectl apply -f front.yaml
  SYMPTÔME : retour inattendu à l'ancienne image
  BON      : remettre le fichier à jour ; kubectl diff -f front.yaml n'affiche rien

Piège 4 : maxSurge 0 et maxUnavailable 0
════════════════════════════════════════
  SYMPTÔME : « may not be 0 when `maxSurge` is 0 »
  BON      : au moins une des deux bornes non nulle (1 et 0 pour ne jamais baisser)

Piège 5 : DaemonSet avec maxSurge ET maxUnavailable
═══════════════════════════════════════════════════
  SYMPTÔME : « may not be set when maxUnavailable is non-zero »
  BON      : exactement une des deux valeurs non nulle

Piège 6 : Changer le sélecteur d'un Deployment
══════════════════════════════════════════════
  SYMPTÔME : « field is immutable »
  BON      : kubectl delete deploy front --cascade=orphan, puis recréer

Piège 7 : PDB qui interdit toute éviction
═════════════════════════════════════════
  MAUVAIS  : minAvailable égal au nombre de réplicas
  SYMPTÔME : kubectl drain boucle sur « Cannot evict pod … disruption budget »
  BON      : maxUnavailable: 1, ou minAvailable < réplicas

Piège 8 : timeZone et heure du conteneur
════════════════════════════════════════
  SYMPTÔME : le CronJob part à 2 h de Paris, mais « date » affiche 0 h ou 1 h
  CAUSE    : timeZone ne règle que le calendrier, le conteneur reste en UTC
  BON      : variable TZ dans le conteneur si l'application doit vivre à l'heure locale

Piège 9 : podFailurePolicy avec OnFailure
═════════════════════════════════════════
  SYMPTÔME : « only "Never" is supported when podFailurePolicy is specified »
  BON      : restartPolicy: Never dans le modèle du Job

Piège 10 : Les mots après « -- » de kubectl create deployment
═════════════════════════════════════════════════════════════
  MAUVAIS  : kubectl create deployment api --image=…agnhost:2.66.1 -- netexec --http-port=8080
  SYMPTÔME : RunContainerError ou CrashLoopBackOff : « netexec » remplace l'ENTRYPOINT
  CAUSE    : create deployment, create job et create cronjob mettent la suite
             de « -- » dans command (kubectl run, lui, la met dans args)
  BON      : générer sans « -- », puis écrire args: ["netexec", "--http-port=8080"]
```

> [!summary] À retenir
> - Les contrôleurs créent des pods depuis un modèle, les reconnaissent par sélecteur et `ownerReferences`, et les suppriment en cascade (`--cascade=orphan` pour les garder).
> - Seul un changement de `spec.template` crée une révision (un ReplicaSet) ; le sélecteur d'un Deployment est immuable et doit correspondre aux labels du modèle.
> - Rolling update : jamais plus de `R + maxSurge` pods, jamais moins de `R − maxUnavailable` disponibles ; `maxSurge` arrondi au-dessus, `maxUnavailable` au-dessous, défauts 25 % / 25 %.
> - « Disponible » = prêt depuis `minReadySeconds` : sans `readinessProbe`, un rolling update n'est pas sûr.
> - `rollout undo` recopie modèle et annotations du ReplicaSet visé, qui reçoit le numéro de révision suivant ; un Deployment ne revient jamais seul en arrière.
> - `kubernetes.io/change-cause` est recopiée du Deployment vers le ReplicaSet courant : annoter après la modification ; `--record` est déprécié.
> - DaemonSet : un pod par nœud, tolerations système automatiques mais pas celle du control plane ; une seule des bornes `maxSurge`/`maxUnavailable` non nulle.
> - Job : `backoffLimit` 6, délais jusqu'à 10 min, `podFailurePolicy` (exige `Never`), `backoffLimitPerIndex` et `successPolicy` pour les Jobs indexés, `ttlSecondsAfterFinished` pour le ménage.
> - CronJob : `timeZone` règle le calendrier seulement, `concurrencyPolicy` `Allow`/`Forbid`/`Replace`, historiques 3 et 1, `kubectl create job --from=cronjob/…` pour tester.
> - PDB : protège des évictions volontaires seulement, `minAvailable` ou `maxUnavailable`, pourcentages arrondis au-dessus, `unhealthyPodEvictionPolicy: AlwaysAllow` pour ne pas bloquer les drains.

### 5.13 Exercices

Ces exercices construisent l'essentiel de l'application `boutique` : à la fin du chapitre, le namespace contient les Deployments `front` et `api`, leurs Services, le DaemonSet `agent-noeud`, le CronJob `rapport` et le PodDisruptionBudget `front`, en plus du pod `outils`. Les manifestes vont dans `~/cka/boutique/`.

#### Exercice 5.1 — Le Deployment `front`

**Point de départ** : exercice 4.7, ou instantané I0 suivi de `lab/etats/03-kubectl-efficace/appliquer.sh` et `lab/etats/04-pods/appliquer.sh`.

Crée dans `boutique` le Deployment `front` : image `nginx:1.29-alpine`, 3 réplicas, labels `app=front` et `tier=web` (sélecteur sur `app=front` seulement), port de conteneur 80, stratégie `RollingUpdate` avec `maxSurge: 1` et `maxUnavailable: 0`, sonde de disponibilité HTTP sur `/` port 80, requests `50m`/`32Mi`, limits `200m`/`64Mi`. Le manifeste va dans `~/cka/boutique/front.yaml`. Observe le ReplicaSet créé et la chaîne de propriété d'un pod.

> [!example]- Solution
> ```bash
> kubectl -n boutique create deployment front --image=nginx:1.29-alpine \
>   --replicas=3 --port=80 --dry-run=client -o yaml > ~/cka/boutique/front.yaml
> vim ~/cka/boutique/front.yaml        # labels, stratégie, sonde, ressources
> kubectl apply -f ~/cka/boutique/front.yaml
> kubectl -n boutique rollout status deployment/front
> ```
>
> Le fichier final est celui de la section 5.3. Le générateur a nommé le conteneur `nginx` et posé `app: front` partout ; on ajoute `tier: web` aux labels du Deployment et du modèle, mais **pas** au sélecteur. Les ressources peuvent aussi être posées sans éditeur : `kubectl set resources --local -f front.yaml --requests=cpu=50m,memory=32Mi --limits=cpu=200m,memory=64Mi -o yaml`.
>
> **Vérification** :
>
> ```bash
> kubectl -n boutique get deployment,rs -l app=front
> POD=$(kubectl -n boutique get pod -l app=front -o jsonpath='{.items[0].metadata.name}')
> kubectl -n boutique get pod $POD -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
> ```
>
> ```
> NAME                    READY   UP-TO-DATE   AVAILABLE   AGE
> deployment.apps/front   3/3     3            3           40s
>
> NAME                               DESIRED   CURRENT   READY   AGE
> replicaset.apps/front-5c8b6d4f7b   3         3         3       40s
> ReplicaSet/front-5c8b6d4f7b
> ```
>
> Le suffixe du ReplicaSet (le `pod-template-hash`) diffère chez toi.

#### Exercice 5.2 — Mise à jour progressive vers nginx 1.30.6

**Point de départ** : exercice 5.1.

Mets à jour `front` vers `nginx:1.30.6-alpine` en documentant la révision par l'annotation `kubernetes.io/change-cause` avec la valeur `image nginx:1.30.6-alpine`. Observe le déroulé (nombre de pods par ReplicaSet), puis affiche l'historique et le détail de la révision 2.

> [!example]- Solution
> Dans un second terminal, avant de lancer la mise à jour :
>
> ```bash
> kubectl -n boutique get rs -l app=front -w
> ```
>
> Puis :
>
> ```bash
> kubectl -n boutique set image deployment/front nginx=nginx:1.30.6-alpine
> kubectl -n boutique annotate deployment/front kubernetes.io/change-cause="image nginx:1.30.6-alpine" --overwrite
> kubectl -n boutique rollout status deployment/front
> kubectl -n boutique rollout history deployment/front
> kubectl -n boutique rollout history deployment/front --revision=2
> ```
>
> Le terminal de surveillance montre le nouveau ReplicaSet monter de 0 à 3 un pod à la fois, et l'ancien descendre de 3 à 0, le total ne dépassant jamais 4 pods : c'est le tableau de la section 5.4. L'annotation est posée **après** `set image` : le contrôleur la recopie sur le nouveau ReplicaSet, et la révision 1 garde sa cause vide.
>
> **Vérification** :
>
> ```
> deployment.apps/front
> REVISION  CHANGE-CAUSE
> 1         <none>
> 2         image nginx:1.30.6-alpine
> ```
>
> et `kubectl -n boutique get deployment front -o jsonpath='{.spec.template.spec.containers[0].image}'` renvoie `nginx:1.30.6-alpine`.

#### Exercice 5.3 — Annuler, puis revenir

**Point de départ** : exercice 5.2.

Annule la mise à jour (retour à nginx 1.29), constate la renumérotation de l'historique, puis remets `front` en `nginx:1.30.6-alpine` **sans** taper le nom de l'image. Termine en remettant `~/cka/boutique/front.yaml` en accord avec le cluster.

> [!example]- Solution
> ```bash
> kubectl -n boutique rollout undo deployment/front
> kubectl -n boutique rollout status deployment/front
> kubectl -n boutique rollout history deployment/front
> kubectl -n boutique rollout undo deployment/front --to-revision=2
> kubectl -n boutique rollout status deployment/front
> kubectl -n boutique rollout history deployment/front
> ```
>
> Le premier `undo` recopie le modèle et les annotations de l'ancien ReplicaSet (révision 1) dans le Deployment : l'annotation `change-cause` disparaît du Deployment, puisque ce ReplicaSet n'en avait pas, et le ReplicaSet réutilisé devient la révision 3. La révision 2 existe toujours : `--to-revision=2` la réactive, avec sa cause, et elle devient la révision 4. On évite un second `undo` sans option, qui reviendrait aussi à la révision 2 mais par hasard plutôt que par intention.
>
> Chaque `undo` commence par un avertissement : `Warning: resource deployments/front was previously managed with 'kubectl apply'. Rolling back will not update the kubectl.kubernetes.io/last-applied-configuration annotation, which may cause unexpected behavior on future 'kubectl apply' operations.` C'est le piège de l'encadré de la section 5.5 : l'annotation et le fichier décrivent encore nginx 1.29. Pour le fichier, on reporte donc l'image et l'annotation :
>
> ```bash
> sed -i 's#image: nginx:1.29-alpine#image: nginx:1.30.6-alpine#' ~/cka/boutique/front.yaml
> kubectl annotate --local -f ~/cka/boutique/front.yaml \
>   kubernetes.io/change-cause="image nginx:1.30.6-alpine" -o yaml > /tmp/front.yaml \
>   && mv /tmp/front.yaml ~/cka/boutique/front.yaml
> kubectl diff -f ~/cka/boutique/front.yaml; echo "code de retour : $?"
> ```
>
> **Vérification** :
>
> ```
> deployment.apps/front
> REVISION  CHANGE-CAUSE
> 3         <none>
> 4         image nginx:1.30.6-alpine
> ```
>
> `kubectl diff` n'affiche rien et le code de retour vaut 0 : le fichier décrit exactement l'objet du cluster.

#### Exercice 5.4 — Le Deployment `api` et les premiers Services

**Point de départ** : exercice 5.3.

Crée dans `boutique` le Deployment `api` : image `registry.k8s.io/e2e-test-images/agnhost:2.66.1`, arguments `netexec --http-port=8080` (l'`ENTRYPOINT` de l'image est conservé), 2 réplicas, labels `app=api` et `tier=api`, port de conteneur 8080 nommé `http`, sonde de disponibilité HTTP sur `/hostname` port `http`, requests `50m`/`32Mi`, limits `500m`/`128Mi`. Expose ensuite `api` (port 8080) et `front` (port 80) par deux Services ClusterIP de même nom, et interroge-les depuis `outils`.

> [!example]- Solution
> On génère sans rien après `--`, puis on complète à la main :
>
> ```bash
> kubectl -n boutique create deployment api --image=registry.k8s.io/e2e-test-images/agnhost:2.66.1 \
>   --replicas=2 --port=8080 --dry-run=client -o yaml > ~/cka/boutique/api.yaml
> vim ~/cka/boutique/api.yaml     # args, nom du port, label tier, sonde, ressources
> ```
>
> Manifeste final :
>
> ```yaml
> apiVersion: apps/v1
> kind: Deployment
> metadata:
>   name: api
>   namespace: boutique
>   labels: {app: api, tier: api}
> spec:
>   replicas: 2
>   selector:
>     matchLabels: {app: api}
>   template:
>     metadata:
>       labels: {app: api, tier: api}
>     spec:
>       containers:
>       - name: agnhost
>         image: registry.k8s.io/e2e-test-images/agnhost:2.66.1
>         args: ["netexec", "--http-port=8080"]
>         ports:
>         - name: http
>           containerPort: 8080
>         readinessProbe:
>           httpGet: {path: /hostname, port: http}
>         resources:
>           requests: {cpu: 50m, memory: 32Mi}
>           limits: {cpu: 500m, memory: 128Mi}
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/api.yaml
> kubectl -n boutique rollout status deployment/api
> kubectl -n boutique expose deployment api --port=8080
> kubectl -n boutique expose deployment front --port=80
> ```
>
> `args` et non `command` : `command` remplacerait l'`ENTRYPOINT` `/agnhost`. C'est pourquoi on n'écrit rien après `--` : `kubectl create deployment api … -- netexec --http-port=8080` placerait ces mots dans `command`, et le conteneur exécuterait `netexec`, qui n'existe pas dans l'image (piège 10). `kubectl expose` reprend le sélecteur du Deployment (`app=api`) ; sans `--target-port`, le port cible vaut le port du Service. Les Services sont étudiés au [chapitre 10](10-services.md), qui passera le port cible d'`api` sur le nom `http`.
>
> Laisse deux ou trois secondes entre `expose` et la vérification : kube-proxy pose les règles d'un Service neuf en une à deux secondes sur le lab. Une requête lancée dans la foulée, par exemple en collant les deux blocs d'un coup, est refusée (`command terminated with exit code 7`), ou, si son premier paquet est parti avant toute règle, reste bloquée deux minutes avant d'échouer (code 28) : relance-la simplement.
>
> **Vérification** :
>
> ```bash
> kubectl -n boutique get deploy api
> kubectl -n boutique exec outils -- curl -s http://api:8080/hostname; echo
> kubectl -n boutique exec outils -- curl -s -o /dev/null -w '%{http_code}\n' http://front/
> ```
>
> ```
> NAME   READY   UP-TO-DATE   AVAILABLE   AGE
> api    2/2     2            2           50s
> api-7d9c5b8f4-k2m9x
> 200
> ```
>
> Le nom du pod qui répond change d'un appel à l'autre : le Service répartit entre les deux réplicas.

#### Exercice 5.5 — Le DaemonSet `agent-noeud`

**Point de départ** : exercice 5.4.

Crée dans `boutique` le DaemonSet `agent-noeud` (labels `app=agent-noeud` et `tier=outils`) dont le conteneur `agent` (`busybox:1.37.0`) écrit toutes les 60 secondes la date suivie du nom de son nœud, lu dans une variable `NODE_NAME` alimentée par le champ `spec.nodeName` ; requests `10m`/`16Mi`, limits `50m`/`32Mi`. Vérifie qu'un pod tourne sur chaque nœud et lis leurs journaux d'un coup.

> [!example]- Solution
> ```bash
> kubectl -n boutique create deployment agent-noeud --image=busybox:1.37.0 \
>   --dry-run=client -o yaml > ~/cka/boutique/agent-noeud.yaml
> vim ~/cka/boutique/agent-noeud.yaml
> ```
>
> Après transformation (`kind`, suppression de `replicas`, `strategy` et `status`, ajout de la commande, de la variable et des ressources) :
>
> ```yaml
> apiVersion: apps/v1
> kind: DaemonSet
> metadata:
>   name: agent-noeud
>   namespace: boutique
>   labels: {app: agent-noeud, tier: outils}
> spec:
>   selector:
>     matchLabels: {app: agent-noeud}
>   template:
>     metadata:
>       labels: {app: agent-noeud, tier: outils}
>     spec:
>       containers:
>       - name: agent
>         image: busybox:1.37.0
>         command: ["sh", "-c", "while true; do echo \"$(date) $NODE_NAME\"; sleep 60; done"]
>         env:
>         - name: NODE_NAME
>           valueFrom:
>             fieldRef: {fieldPath: spec.nodeName}
>         resources:
>           requests: {cpu: 10m, memory: 16Mi}
>           limits: {cpu: 50m, memory: 32Mi}
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/agent-noeud.yaml
> kubectl -n boutique rollout status daemonset/agent-noeud
> ```
>
> `$NODE_NAME` est développé par le shell ; `$(date)` est laissé intact par Kubernetes, faute de variable `date`, et exécuté par le shell ([chapitre 4.3](04-pods.md)).
>
> **Vérification** :
>
> ```bash
> kubectl -n boutique get ds agent-noeud
> kubectl -n boutique get pods -l app=agent-noeud -o wide
> kubectl -n boutique logs -l app=agent-noeud --prefix --tail=1
> ```
>
> ```
> NAME          DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR   AGE
> agent-noeud   3         3         3       3            3           <none>          30s
> …
> [pod/agent-noeud-4kq7z/agent] Fri Oct 23 20:03:12 UTC 2026 cka
> [pod/agent-noeud-m8x2d/agent] Fri Oct 23 20:03:12 UTC 2026 cka-m02
> [pod/agent-noeud-t5v9h/agent] Fri Oct 23 20:03:13 UTC 2026 cka-m03
> ```
>
> Trois pods, un par nœud, control plane compris (aucune taint dans le lab).

#### Exercice 5.6 — Le Job `migration`

**Point de départ** : exercice 5.5.

Crée dans `boutique` le Job `migration` (`busybox:1.37.0`, commande `echo migration du lot sur $HOSTNAME; sleep 10`) qui exige 3 complétions avec au plus 2 pods simultanés, et qui se supprime 600 secondes après sa fin. Observe le parallélisme, attends la fin, puis lis les journaux.

> [!example]- Solution
> ```bash
> kubectl -n boutique create job migration --image=busybox:1.37.0 --dry-run=client -o yaml \
>   -- sh -c 'echo migration du lot sur $HOSTNAME; sleep 10' > ~/cka/boutique/migration.yaml
> ```
>
> On ajoute les trois champs dans `spec` :
>
> ```yaml
> apiVersion: batch/v1
> kind: Job
> metadata:
>   name: migration
>   namespace: boutique
> spec:
>   completions: 3
>   parallelism: 2
>   ttlSecondsAfterFinished: 600
>   template:
>     spec:
>       restartPolicy: Never
>       containers:
>       - name: migration
>         image: busybox:1.37.0
>         command: ["sh", "-c", "echo migration du lot sur $HOSTNAME; sleep 10"]
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/migration.yaml
> kubectl -n boutique get pods -l batch.kubernetes.io/job-name=migration -w   # 2 pods, puis 1
> kubectl -n boutique wait --for=condition=complete job/migration --timeout=120s
> kubectl -n boutique logs -l batch.kubernetes.io/job-name=migration
> ```
>
> Deux pods démarrent ensemble ; quand ils ont fini, un seul est créé, puisqu'il ne reste qu'une complétion à obtenir (le parallélisme réel ne dépasse jamais les complétions restantes). Les apostrophes du shell local protègent `$HOSTNAME`, développé ensuite dans chaque pod.
>
> **Vérification** :
>
> ```
> job.batch/migration condition met
> ```
>
> `kubectl -n boutique get job migration` affiche `Complete` et `3/3`, et les journaux trois lignes `migration du lot sur migration-xxxxx`. Dix minutes après la fin, `kubectl -n boutique get job migration` répond `NotFound` : le contrôleur TTL a supprimé le Job et ses pods.

#### Exercice 5.7 — Une politique d'échec qui coupe court

**Point de départ** : exercice 5.6.

Un import échoue avec le code de sortie 42 quand son fichier est corrompu : inutile de réessayer. Crée dans `boutique` un Job temporaire `import-defaillant` (`busybox:1.37.0`, conteneur `import`, commande `echo fichier corrompu; exit 42`, `backoffLimit: 6`) qui échoue **dès le premier** code 42, et qui ne compte pas les pods supprimés par une perturbation. Compare avec le comportement sans politique, puis supprime le Job.

> [!example]- Solution
> ```yaml
> apiVersion: batch/v1
> kind: Job
> metadata:
>   name: import-defaillant
>   namespace: boutique
> spec:
>   backoffLimit: 6
>   podFailurePolicy:
>     rules:
>     - action: FailJob
>       onExitCodes:
>         containerName: import
>         operator: In
>         values: [42]
>     - action: Ignore
>       onPodConditions:
>       - type: DisruptionTarget
>   template:
>     spec:
>       restartPolicy: Never
>       containers:
>       - name: import
>         image: busybox:1.37.0
>         command: ["sh", "-c", "echo fichier corrompu; exit 42"]
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/import-defaillant.yaml
> kubectl -n boutique wait --for=condition=failed job/import-defaillant --timeout=120s
> kubectl -n boutique get job import-defaillant \
>   -o jsonpath='{.status.conditions[?(@.type=="Failed")].reason}{"\n"}{.status.conditions[?(@.type=="Failed")].message}{"\n"}'
> kubectl -n boutique get pods -l batch.kubernetes.io/job-name=import-defaillant
> kubectl -n boutique delete job import-defaillant
> ```
>
> Sans la règle `FailJob`, le contrôleur aurait créé jusqu'à sept pods (le premier puis six réessais), espacés de 10 s, 20 s, 40 s…, soit plus de dix minutes d'acharnement inutile. `restartPolicy: Never` est obligatoire avec une `podFailurePolicy`.
>
> **Vérification** :
>
> ```
> job.batch/import-defaillant condition met
> PodFailurePolicy
> Container import for pod boutique/import-defaillant-q8w2n failed with exit code 42 matching FailJob rule at index 0
> NAME                      READY   STATUS   RESTARTS   AGE
> import-defaillant-q8w2n   0/1     Error    0          15s
> ```
>
> Un seul pod a été créé.

#### Exercice 5.8 — Le CronJob `rapport`

**Point de départ** : exercice 5.7.

Crée dans `boutique` le CronJob `rapport` (labels `app=rapport` et `tier=batch`, posés aussi sur ses Jobs et ses pods) qui exécute toutes les 5 minutes, à l'heure de Paris, `date; echo rapport genere` dans un conteneur `busybox:1.37.0`, sans jamais deux exécutions simultanées, en gardant 3 Jobs réussis et 1 Job échoué. Déclenche une exécution manuelle sans attendre, lis son résultat, puis supprime ce Job manuel.

> [!example]- Solution
> ```bash
> kubectl -n boutique create cronjob rapport --image=busybox:1.37.0 --schedule='*/5 * * * *' \
>   --dry-run=client -o yaml -- sh -c 'date; echo rapport genere' > ~/cka/boutique/rapport.yaml
> ```
>
> Après ajout des labels, du fuseau, de la politique de concurrence et des limites d'historique :
>
> ```yaml
> apiVersion: batch/v1
> kind: CronJob
> metadata:
>   name: rapport
>   namespace: boutique
>   labels: {app: rapport, tier: batch}
> spec:
>   schedule: "*/5 * * * *"
>   timeZone: Europe/Paris
>   concurrencyPolicy: Forbid
>   successfulJobsHistoryLimit: 3
>   failedJobsHistoryLimit: 1
>   jobTemplate:
>     metadata:
>       labels: {app: rapport, tier: batch}
>     spec:
>       template:
>         metadata:
>           labels: {app: rapport, tier: batch}
>         spec:
>           restartPolicy: OnFailure
>           containers:
>           - name: rapport
>             image: busybox:1.37.0
>             command: ["sh", "-c", "date; echo rapport genere"]
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/rapport.yaml
> kubectl -n boutique create job rapport-manuel --from=cronjob/rapport
> kubectl -n boutique wait --for=condition=complete job/rapport-manuel --timeout=60s
> kubectl -n boutique logs job/rapport-manuel
> kubectl -n boutique delete job rapport-manuel
> ```
>
> Les labels sont posés à trois niveaux : sur le CronJob, sur le modèle de Job et sur le modèle de pod. Seul ce dernier atteint les pods, que sélectionneront les NetworkPolicies du [chapitre 14](14-network-policies.md). Le `date` du pod affiche l'heure UTC : `timeZone` ne règle que le calendrier.
>
> **Vérification** :
>
> ```bash
> kubectl -n boutique get cronjob rapport
> ```
>
> ```
> NAME      SCHEDULE      TIMEZONE       SUSPEND   ACTIVE   LAST SCHEDULE   AGE
> rapport   */5 * * * *   Europe/Paris   False     0        <none>          45s
> ```
>
> Les journaux du Job manuel affichaient une ligne de date en UTC puis `rapport genere`. Cinq minutes au plus après la création, `LAST SCHEDULE` se remplit et un Job `rapport-<nombre>` apparaît dans `kubectl -n boutique get jobs -l app=rapport`.

#### Exercice 5.9 — Le PodDisruptionBudget `front`

**Point de départ** : exercice 5.8.

Crée dans `boutique` un PodDisruptionBudget `front` qui garde au moins 2 pods `app=front` disponibles pendant les évictions volontaires. Lis le nombre d'évictions permises et les champs du statut, puis explique pourquoi un `kubectl -n boutique rollout restart deployment/front` n'est pas freiné par ce budget.

> [!example]- Solution
> ```bash
> kubectl -n boutique create pdb front --selector=app=front --min-available=2 \
>   --dry-run=client -o yaml > ~/cka/boutique/pdb-front.yaml
> kubectl apply -f ~/cka/boutique/pdb-front.yaml
> kubectl -n boutique get pdb front
> kubectl -n boutique get pdb front -o jsonpath='{.status}{"\n"}'
> ```
>
> Avec 3 pods sains et un minimum de 2, une seule éviction est permise à la fois. Le rolling update d'un Deployment n'utilise pas l'API d'éviction : il supprime les pods selon ses propres bornes (`maxUnavailable: 0` pour `front`), et le PDB ne le concerne pas. Le budget joue pour `kubectl drain`, au [chapitre 8.14](08-ordonnancement-et-admission.md).
>
> **Vérification** :
>
> ```
> NAME    MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
> front   2               N/A               1                     6s
> {"conditions":[…],"currentHealthy":3,"desiredHealthy":2,"disruptionsAllowed":1,"expectedPods":3,"observedGeneration":1}
> ```
>
> Le chapitre 6 part de cet état : `front` (révision 4, nginx 1.30.6), `api`, les Services `front` et `api`, `agent-noeud`, `rapport`, le PDB `front`, et `outils`.

---
