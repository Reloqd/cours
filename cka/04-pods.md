---
title: "CKA — 4. Pods et conteneurs"
description: "Le pod de l'intérieur : spec, cycle de vie, redémarrages, ressources et classes QoS, sondes, init containers, sidecars natifs, redimensionnement en place, arrêt gracieux et securityContext, pour Kubernetes v1.37."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 4. Pods et conteneurs

Tout ce que Kubernetes exécute finit dans un pod. Les Deployments, les DaemonSets, les Jobs du [chapitre 5](05-deployments-et-controleurs.md) ne sont que des fabriques de pods ; les Services du [chapitre 10](10-services.md) ne font que les choisir par leurs labels ; le scheduler du [chapitre 8](08-ordonnancement-et-admission.md) ne place que des pods. Ce chapitre démonte donc l'objet de base : ce qu'un pod partage entre ses conteneurs, comment il naît, vit et meurt, comment le kubelet décide de redémarrer un conteneur, comment se calculent ses ressources et sa classe de qualité de service, à quoi servent les trois sondes, comment s'enchaînent init containers et sidecars natifs, et comment on change ses ressources sans le recréer. À l'examen, ces notions apparaissent partout : une tâche qui demande « un pod avec un sidecar », « une sonde de disponibilité sur `/healthz` », « des limites mémoire » ou « un redimensionnement sans redémarrage » se règle en quelques minutes si le mécanisme est clair, et se transforme en piège sinon. Les compétences officielles concernées sont *Understand the primitives used to create robust, self-healing, application deployments*, *Configure Pod admission and scheduling (limits, node affinity, etc.)* pour la partie ressources, et *Configure volume types, access modes and reclaim policies* pour le volume `emptyDir` que partagent les conteneurs d'un pod. Le dépannage des pods en panne a son propre chapitre ([chapitre 22](22-depanner-les-applications.md)) ; ici, on construit les réflexes qui le rendent possible.

### 4.1 Le pod, plus petite unité déployable

Un pod est un groupe d'un ou plusieurs conteneurs que Kubernetes planifie **ensemble**, sur **un seul** nœud, et qui partagent un contexte d'exécution. Ce contexte, c'est d'abord un ensemble d'espaces de noms Linux. Quand le kubelet reçoit un pod, il demande au runtime (containerd dans le lab, par l'interface CRI) de créer un *bac à sable* (*sandbox*) : sous containerd, c'est un petit conteneur `pause` (image `registry.k8s.io/pause:3.10.2` dans le lab) qui ne fait rien d'autre que détenir les espaces de noms réseau, IPC et UTS. Le plugin CNI configure ensuite le réseau de ce bac à sable ([chapitre 9.2](09-reseau-des-pods.md)), puis chaque conteneur du pod est démarré *dans* ces espaces de noms. Il en découle les propriétés qui font l'intérêt du pod : une seule adresse IP pour tous ses conteneurs, un seul espace de ports (deux conteneurs ne peuvent pas écouter le même port), une communication possible par `localhost`, un même nom d'hôte. Les volumes sont déclarés au niveau du pod et montés dans les conteneurs qui le demandent. L'espace de noms PID, lui, reste séparé par défaut : chaque conteneur a son propre PID 1, sauf si tu poses `shareProcessNamespace: true`.

```
UN POD VU DU NŒUD
═════════════════

  ┌──────────────────────────── pod « appli-journal » ─────────────────────────────┐
  │  sandbox (conteneur pause) : netns + IPC + UTS   ── IP 10.244.195.197          │
  │                                                                                │
  │   ┌──────────────────────┐        ┌──────────────────────┐                     │
  │   │ conteneur « appli »  │        │ conteneur « journal »│                     │
  │   │ PID 1 = sh           │        │ PID 1 = sh           │  ← PID séparés      │
  │   │ écoute :8080         │◀──────▶│ localhost:8080       │  ← même réseau      │
  │   └──────────┬───────────┘        └──────────┬───────────┘                     │
  │              │  /var/log/appli               │  /var/log/appli                 │
  │              └──────────────┬────────────────┘                                 │
  │                     volume emptyDir « journaux » (vit et meurt avec le pod)    │
  └────────────────────────────────────────────────────────────────────────────────┘
```

Pourquoi un pod plutôt qu'un conteneur ? Parce que certains processus doivent vivre ensemble : un serveur et l'agent qui expédie ses journaux, une application et le mandataire qui chiffre son trafic, un service et le programme qui recharge sa configuration. Les placer dans un même pod garantit qu'ils seront sur le même nœud, démarrés et arrêtés ensemble, et qu'ils partageront réseau et volumes. Le revers est symétrique : deux composants qui doivent pouvoir se mettre à l'échelle indépendamment (un frontal et sa base de données) n'ont rien à faire dans le même pod.

Un pod n'est planifié **qu'une fois**. Le scheduler l'affecte à un nœud en remplissant `spec.nodeName` (le *binding*), et il ne le déplacera jamais. Si le nœud disparaît, ce pod-là est perdu : un contrôleur en crée un autre, avec un nouveau nom (sauf StatefulSet), un nouvel UID et une nouvelle adresse IP. Un pod créé à la main, sans contrôleur (un pod « nu »), n'est recréé par personne : c'est pourquoi les applications passent par les contrôleurs du [chapitre 5](05-deployments-et-controleurs.md), et pourquoi `kubectl drain` refuse par défaut de supprimer un pod nu.

La spec d'un pod est presque entièrement **immuable**. Le serveur d'API n'accepte de modifier que cinq champs, et le message d'erreur les énumère lui-même :

```
The Pod "outils" is invalid: spec: Forbidden: pod updates may not change fields other than
`spec.containers[*].image`,`spec.initContainers[*].image`,`spec.activeDeadlineSeconds`,
`spec.tolerations` (only additions to existing tolerations),`spec.terminationGracePeriodSeconds`
(allow it to be set to 1 if it was previously negative)
```

Les ressources CPU et mémoire font exception, mais par une porte dédiée, la sous-ressource `resize` (section 4.12) ; les conteneurs éphémères passent eux aussi par une sous-ressource (section 4.11). Pour tout le reste (une sonde, une variable, un volume), on supprime et on recrée : `kubectl replace --force -f pod.yaml` fait les deux en une commande ([chapitre 3.7.4](03-kubectl-efficace.md)).

> [!note]
> Un pod statique, lu par le kubelet dans `/etc/kubernetes/manifests` ([chapitre 2.5](02-architecture.md)), est un pod comme les autres du point de vue du conteneur, mais son objet dans l'API n'est qu'un miroir. Depuis Kubernetes 1.37, la porte `PreventStaticPodAPIReferences` est supprimée : un pod statique ne peut plus référencer ni ConfigMap ni Secret, sans retour possible. Il ne peut pas non plus être redimensionné en place (`static pods cannot be resized`).

### 4.2 Écrire un pod vite

À l'examen, on n'écrit jamais un pod de zéro. On le fait générer par `kubectl run`, puis on complète le YAML. Le générateur connaît l'image, le nom, les labels, les variables, le port et la politique de redémarrage ; tout le reste se tape dans l'éditeur.

```bash
kubectl -n boutique run essai --image=busybox:1.37.0 \
  --labels=app=essai,tier=outils --env=MODE=test \
  --dry-run=client -o yaml --command -- sleep 3600 > essai.yaml
```

Deux détails de syntaxe comptent. Avec `kubectl run`, ce qui suit `--` devient `args` du conteneur, et `command` avec l'option `--command` (la différence est expliquée en 4.3) ; attention, `kubectl create deployment`, `create job` et `create cronjob` placent au contraire ce qui suit `--` dans `command`. Et `--restart` choisit `spec.restartPolicy` : `Always` par défaut, `OnFailure` ou `Never` sinon. L'option `-f` de `kubectl run` est **dépréciée en 1.37** et déjà ignorée : le pod est construit uniquement à partir des arguments. Les anciennes options `--requests` et `--limits` ont disparu ; pour éviter de taper un bloc `resources` à la main, un générateur local fait l'affaire, car `kubectl set resources` sait travailler sur un fichier sans toucher au cluster :

```bash
kubectl -n boutique run essai --image=busybox:1.37.0 --dry-run=client -o yaml \
  --command -- sleep 3600 \
  | kubectl set resources --local -f - --requests=cpu=50m,memory=32Mi \
      --limits=cpu=100m,memory=64Mi -o yaml > essai.yaml
```

Le même `--local` existe pour `kubectl set image` et `kubectl set env`. Pour un champ dont tu as oublié la forme, `kubectl explain` répond plus vite que la documentation et décrit exactement la version du serveur :

```bash
kubectl explain pod.spec.containers.livenessProbe.httpGet
kubectl explain pod.spec.initContainers.restartPolicy
kubectl explain pod.spec.containers.resizePolicy --recursive
```

Les valeurs par défaut d'un pod, que le serveur d'API remplit si tu ne dis rien, méritent d'être connues : beaucoup de tâches se jouent sur elles.

| Champ | Valeur par défaut | Remarque |
|---|---|---|
| `restartPolicy` | `Always` | seule valeur permise dans un Deployment ; Job : `OnFailure` ou `Never` |
| `terminationGracePeriodSeconds` | `30` | délai entre le signal d'arrêt et `SIGKILL` (4.13) |
| `dnsPolicy` | `ClusterFirst` | résolution par CoreDNS ([chapitre 11.7](11-coredns.md)) |
| `serviceAccountName` | `default` | jeton monté automatiquement ([chapitre 16.9](16-rbac-et-authentification.md)) |
| `enableServiceLinks` | `true` | variables `<SERVICE>_SERVICE_HOST` injectées pour chaque Service du namespace |
| `containers[].imagePullPolicy` | `Always` si l'étiquette est `latest` ou absente, sinon `IfNotPresent` | fixé à la création, jamais recalculé |
| `containers[].terminationMessagePolicy` | `File` | `FallbackToLogsOnError` utile au débogage |
| `schedulerName` | `default-scheduler` | |

> [!tip] Réflexe d'examen
> Garde un fichier par objet, nommé comme l'objet, dans un dossier par tâche. Génère (`--dry-run=client -o yaml`), corrige dans vim, applique (`kubectl apply -f`), vérifie (`kubectl get … -o wide`, `kubectl describe`). Pour un pod à modifier hors des cinq champs permis, `kubectl replace --force -f fichier.yaml` supprime et recrée en une seule commande.

### 4.3 Commande, arguments et variables d'environnement

Une image définit deux choses : un `ENTRYPOINT` (l'exécutable) et un `CMD` (ses arguments par défaut). Kubernetes les remplace par deux champs du conteneur, `command` et `args`, selon une règle simple : `command` remplace l'`ENTRYPOINT`, `args` remplace le `CMD`, et chacun ne touche que ce qu'il remplace.

| `command` | `args` | Ce qui s'exécute | Exemple avec agnhost (`ENTRYPOINT ["/agnhost"]`, `CMD ["pause"]`) |
|---|---|---|---|
| absent | absent | `ENTRYPOINT` + `CMD` de l'image | `/agnhost pause` |
| absent | présent | `ENTRYPOINT` de l'image + `args` | `args: [netexec, --http-port=8080]` → `/agnhost netexec --http-port=8080` |
| présent | absent | `command` seul, le `CMD` est **ignoré** | `command: [/agnhost, netexec]` → `/agnhost netexec` |
| présent | présent | `command` + `args` | `command: [sh, -c]`, `args: ["echo $HOSTNAME"]` |

La troisième ligne est le piège classique : poser un `command` efface aussi les arguments par défaut de l'image, même si tu ne voulais changer que l'exécutable. Le Deployment `api` du fil rouge utilise la deuxième ligne : `args: ["netexec", "--http-port=8080"]` garde l'`ENTRYPOINT` `/agnhost` de l'image. À l'inverse, `nicolaka/netshoot` et `busybox` n'ont pas d'`ENTRYPOINT` (seulement `CMD ["zsh"]` et `CMD ["sh"]`) : pour elles, `command` et `args` reviennent au même.

Ni `command` ni `args` ne passent par un shell. Pas de redirection, pas de tube, pas de `$VAR` interprété : `command: ["echo", "$HOME"]` affiche littéralement `$HOME`. Quand il faut un shell, on l'appelle explicitement, `command: ["sh", "-c", "…"]`. Kubernetes applique en revanche sa propre substitution, avec la syntaxe `$(NOM)` : dans `command`, `args` et la valeur d'une variable `env`, `$(NOM)` est remplacé par la variable d'environnement `NOM` du conteneur si elle est **déjà définie** (plus haut dans la liste `env`, ou par `envFrom`). Une référence inconnue reste telle quelle, et `$$(NOM)` produit le texte littéral `$(NOM)`. Cette règle a une conséquence que peu de candidats voient venir : dans `sh -c "echo $(date)"`, Kubernetes cherche une variable nommée `date`, ne la trouve pas, laisse le texte intact, et c'est le shell qui exécute ensuite la substitution de commande. Le DaemonSet `agent-noeud` de l'[exercice 5.5](05-deployments-et-controleurs.md) fonctionne ainsi ; il cesserait de fonctionner le jour où une variable `date` serait définie dans le conteneur.

Les variables d'environnement viennent de trois sources. `env` les liste une à une, avec une valeur littérale (`value`) ou une référence (`valueFrom`) : une clé de ConfigMap ou de Secret ([chapitre 6](06-configmaps-et-secrets.md)), un champ du pod (`fieldRef`, par exemple `spec.nodeName` ou `status.podIP`), une ressource du conteneur (`resourceFieldRef`). `envFrom` importe d'un coup toutes les clés d'une ConfigMap ou d'un Secret, avec un `prefix` optionnel. Enfin l'image apporte ses propres `ENV`. En cas de doublon, `env` l'emporte sur `envFrom`, qui l'emporte sur l'image ; entre deux sources d'`envFrom`, la dernière gagne. Depuis 1.34, un nom de variable peut contenir n'importe quel caractère ASCII imprimable sauf `=`.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: variables
  namespace: boutique
spec:
  restartPolicy: Never
  containers:
  - name: appli
    image: busybox:1.37.0
    command: ["sh", "-c", "echo \"$(MESSAGE)\"; echo \"noeud=$NOEUD ip=$IP\""]
    env:
    - name: NOEUD
      valueFrom: {fieldRef: {fieldPath: spec.nodeName}}
    - name: IP
      valueFrom: {fieldRef: {fieldPath: status.podIP}}
    - name: MESSAGE
      value: "pod sur $(NOEUD)"
```

Ici `$(MESSAGE)` et `$(NOEUD)` sont résolus par Kubernetes avant le démarrage, `$NOEUD` et `$IP` par le shell. Les journaux affichent `pod sur cka-m03` puis `noeud=cka-m03 ip=10.244.34.135` (le nœud et l'adresse varient).

### 4.4 Cycle de vie : phases, conditions, états des conteneurs

L'état d'un pod se lit à trois niveaux, et confondre les trois est la première source d'erreurs de diagnostic.

La **phase** (`status.phase`) résume le pod en un mot. Elle ne prend que cinq valeurs :

| Phase | Signification |
|---|---|
| `Pending` | accepté par le cluster, mais au moins un conteneur n'est pas prêt à tourner : attente du scheduler, téléchargement d'images, init containers en cours |
| `Running` | lié à un nœud, tous les conteneurs créés, au moins un en cours d'exécution, de démarrage ou de redémarrage |
| `Succeeded` | tous les conteneurs terminés avec succès, et aucun ne sera redémarré |
| `Failed` | tous les conteneurs terminés, au moins un en échec (code non nul ou tué par le système), sans redémarrage prévu |
| `Unknown` | état impossible à obtenir, en général parce que le nœud ne répond plus |

Les **conditions** (`status.conditions`) détaillent les étapes franchies. Le kubelet et le control plane gèrent `PodScheduled` (nœud choisi), `PodReadyToStartContainers` (bac à sable créé, réseau configuré, volumes montés ; condition **stable depuis 1.37**), `Initialized` (init containers terminés), `ContainersReady` (tous les conteneurs prêts), `Ready` (le pod peut recevoir du trafic : c'est elle que lisent les EndpointSlices et les PodDisruptionBudgets), `DisruptionTarget` (le pod va être supprimé par une perturbation : préemption, éviction, nettoyage) et, depuis le redimensionnement en place, `PodResizePending` et `PodResizeInProgress` (section 4.12).

L'**état de chaque conteneur** (`status.containerStatuses[].state`) vaut `waiting`, `running` ou `terminated`, avec une raison (`reason`) et, pour un conteneur terminé, un code de sortie. Le précédent arrêt reste visible dans `lastState`, ce qui permet de lire la cause d'un plantage même après le redémarrage.

La colonne `STATUS` de `kubectl get pods` n'est **aucune** de ces trois choses : c'est un résumé calculé par kubectl, qui affiche la raison la plus parlante qu'il trouve. Il faut savoir la traduire :

| `STATUS` affiché | Ce qui se passe | Où regarder |
|---|---|---|
| `Pending` | pas encore de nœud | `kubectl describe pod` : événement `FailedScheduling` |
| `ContainerCreating` | bac à sable, volumes ou images en préparation | événements `FailedMount`, `FailedCreatePodSandBox` |
| `Init:0/2` | init containers en cours (0 terminé sur 2) | `kubectl logs pod -c <init>` |
| `Init:Error`, `Init:CrashLoopBackOff` | un init container échoue | journaux de l'init container |
| `PodInitializing` | init terminés, conteneurs principaux en création | |
| `Running` | au moins un conteneur tourne ; la colonne `READY` dit s'il est prêt | |
| `Completed` | phase `Succeeded` | |
| `Error` | conteneur terminé avec un code non nul, sans redémarrage, ou en attente de relance tant que le kubelet n'a pas inscrit `CrashLoopBackOff` | `kubectl logs` |
| `CrashLoopBackOff` | le conteneur plante en boucle, le kubelet attend avant de le relancer | `kubectl logs --previous` |
| `ErrImagePull`, `ImagePullBackOff` | image introuvable ou registre inaccessible | événements `Failed` |
| `CreateContainerConfigError` | ConfigMap, Secret ou clé manquants, ou `runAsNonRoot` violé | `kubectl describe pod` |
| `OOMKilled` | dernier arrêt par dépassement de la limite mémoire | `lastState.terminated` |
| `Terminating` | suppression en cours (`deletionTimestamp` posé) | |

```
CYCLE DE VIE D'UN POD (cas nominal)
═══════════════════════════════════

 création ─▶ PodScheduled ─▶ PodReadyToStartContainers ─▶ Initialized ─▶ ContainersReady ─▶ Ready
   │            │                    │                        │                │
 Pending     binding          sandbox + CNI           init containers    sondes readiness
             (scheduler)      + volumes (kubelet)     terminés           réussies
                                                    ── phase Running dès qu'un conteneur tourne ──

 fin : tous les conteneurs terminés, pas de redémarrage ─▶ Succeeded (tous 0) ou Failed
```

Les trois niveaux se lisent en une commande grâce à jsonpath ([chapitre 3.5.2](03-kubectl-efficace.md)) :

```bash
kubectl -n boutique get pod outils -o jsonpath='{.status.phase}{"\n"}'
kubectl -n boutique get pod outils -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'
kubectl -n boutique get pod outils -o jsonpath='{.status.containerStatuses[0].state}{"\n"}'
```

> [!note]
> Depuis Kubernetes 1.35, un pod porte un `metadata.generation` incrémenté à chaque modification de sa spec, et le kubelet publie dans `status.observedGeneration` la génération qu'il a prise en compte. C'est ainsi qu'on sait, après un redimensionnement, si le kubelet a vu la demande (section 4.12).

### 4.5 Redémarrages : restartPolicy et backoff

Quand un conteneur s'arrête, c'est le **kubelet**, sur le nœud, qui décide de le relancer, dans le même pod, sur le même nœud, avec la même adresse IP. Le pod ne change pas ; seul le compteur `restartCount` du conteneur augmente. Ce qui décide, c'est `spec.restartPolicy`, commune aux conteneurs principaux et aux init containers classiques :

| Code de sortie | `Always` (défaut) | `OnFailure` | `Never` | sidecar natif |
|---|---|---|---|---|
| 0 | redémarre | ne redémarre pas | ne redémarre pas | redémarre toujours |
| non nul (ou tué) | redémarre | redémarre | ne redémarre pas | redémarre toujours |

Les redémarrages successifs sont espacés par un délai exponentiel : 10 s, 20 s, 40 s, et ainsi de suite jusqu'à un plafond de 300 s (5 minutes). Pendant l'attente, kubectl affiche `CrashLoopBackOff`, ou `Error` tant que le kubelet n'a pas resynchronisé le pod (22.2.4). Un conteneur qui a tourné 10 minutes sans incident voit son délai remis à zéro. Le plafond se règle par nœud depuis la 1.35 (porte `KubeletCrashLoopBackOffMax`, bêta active) avec `crashLoopBackOff.maxContainerRestartPeriod` dans la configuration du kubelet, entre `1s` et `300s`.

Une fois le conteneur relancé, le journal de l'instance qui a planté reste accessible tant que la nouvelle instance n'a pas elle-même été remplacée : `kubectl logs <pod> --previous` (ou `-p`). C'est le premier réflexe devant un `CrashLoopBackOff`, car les journaux du conteneur courant sont souvent vides. Pendant l'attente entre deux relances, en revanche, l'instance « courante » est celle qui vient d'échouer, la seule terminée que le kubelet garde : `-p` répond alors `unable to retrieve container logs for containerd://<id>`, et c'est `kubectl logs <pod>` **sans** `-p` qui affiche son journal (21.3.2).

Depuis 1.35, la porte `ContainerRestartRules` (bêta, active par défaut) permet de poser une politique **par conteneur** : un champ `restartPolicy` sur un conteneur principal ou un init container classique, complété de règles `restartPolicyRules` qui redémarrent seulement sur certains codes de sortie. Dans un pod en `restartPolicy: Never`, un conteneur qui porte `restartPolicy: Never` et la règle `{action: Restart, exitCodes: {operator: In, values: [42]}}` est relancé chaque fois qu'il sort avec le code 42, et seulement dans ce cas ; c'est utile pour un traitement dont un code signifie « réessaie » et un autre « inutile d'insister ». Si `restartPolicyRules` est présent, `restartPolicy` doit l'être aussi sur le conteneur.

> [!warning]
> Redémarrer un conteneur n'est pas recréer un pod. Le kubelet ne corrige jamais une erreur de spec (mauvaise image, variable manquante, sonde fausse) : il rejoue la même spec. Un `CrashLoopBackOff` dû à une configuration ne disparaît qu'en corrigeant l'objet qui a créé le pod.

### 4.6 Ressources : requests, limits et classes QoS

#### Deux nombres, deux mécanismes

Chaque conteneur peut déclarer, pour le CPU et la mémoire, une **request** et une **limit**. Elles ne servent pas au même acteur. La request sert au **scheduler** : il place le pod sur un nœud dont l'*allocatable* (la capacité diminuée des réserves système) moins la somme des requests déjà placées peut l'accueillir ; la consommation réelle n'entre pas dans ce calcul. La limit sert au **noyau** : le kubelet la traduit en paramètres de cgroup v2 du conteneur, et le noyau les fait respecter.

| | CPU | Mémoire |
|---|---|---|
| Unité | cœurs ; `1` = `1000m`, `100m` = 0,1 cœur ; pas plus fin que `1m` | octets ; `Mi`, `Gi` (puissances de 2) ou `M`, `G` (puissances de 10) |
| Request : effet | priorité relative sous contention (`cpu.weight`) et placement | placement, et ordre d'éviction sous pression |
| Limit : effet | **étranglement** : quota par période de 100 ms (`cpu.max`) | **arrêt** : au-delà de `memory.max`, le noyau tue un processus (OOM) |
| Dépassement | le conteneur ralentit, il n'est jamais tué pour le CPU | `OOMKilled`, code de sortie 137 |

Pour une limit CPU de `200m`, le fichier `/sys/fs/cgroup/cpu.max` du conteneur contient `20000 100000` : 20 ms de calcul autorisées toutes les 100 ms. Pour une limit mémoire de `128Mi`, `/sys/fs/cgroup/memory.max` vaut `134217728`. Ces fichiers sont lisibles depuis le conteneur lui-même, ce qui en fait la meilleure preuve qu'une modification de ressources a vraiment atteint le noyau (exercice 4.7).

> [!danger] Le `m` de la mémoire
> `memory: 400m` est accepté par l'API et signifie 0,4 **octet** (le suffixe `m` veut dire « milli »). Le conteneur ne démarre pas, ou est tué aussitôt. Pour la mémoire, écris toujours `Mi` ou `Gi`. Note aussi que `M` (10⁶) et `Mi` (2²⁰) diffèrent de presque 5 %.

Si un conteneur déclare une limit sans request pour une ressource, et qu'aucun mécanisme d'admission (une LimitRange, [chapitre 8.11](08-ordonnancement-et-admission.md)) n'a fixé de request, **la request prend la valeur de la limit**. L'inverse n'est pas vrai : une request sans limit laisse le conteneur consommer jusqu'à la capacité du nœud.

> [!info] minikube ≠ examen
> Dans le lab, chaque nœud annonce la capacité de l'**hôte** (8 CPU et 32 Gio sur le poste de référence), pas celle de son conteneur Docker (3 Gio de mémoire réelle). Le scheduler croit donc disposer de bien plus que ce qui existe, et un pod qui demande 4 Gio est placé sans difficulté avant d'échouer à l'exécution. Sur un cluster kubeadm d'examen, la capacité est celle de la machine virtuelle, et un excès de requests laisse le pod en `Pending` avec `Insufficient memory`.

#### La classe QoS, calculée une fois pour toutes

À la création du pod, le serveur d'API lui attribue une classe de qualité de service, écrite dans `status.qosClass`. Le calcul porte sur **tous** les conteneurs du pod, init containers et sidecars compris, et sur le CPU et la mémoire seulement :

```
CALCUL DE LA CLASSE QoS
═══════════════════════

  Chaque conteneur a-t-il une limit ET une request > 0 pour le CPU ET la mémoire,
  avec request = limit pour chacun des deux ?
        │
       oui ──────────────────────────────────────────▶  Guaranteed
        │ non
        ▼
  Au moins un conteneur a-t-il une request ou une limit CPU ou mémoire ?
        │
       oui ──────────────────────────────────────────▶  Burstable
        │ non
        ▼
                                                        BestEffort
```

Comme une limit seule recopie sa valeur dans la request, un conteneur qui ne déclare **que** des limits CPU et mémoire est `Guaranteed`. Quelques cas à savoir trancher sans hésiter :

| Ressources déclarées | Classe |
|---|---|
| requests = limits pour CPU et mémoire, dans chaque conteneur | `Guaranteed` |
| limits CPU et mémoire seules (requests recopiées) | `Guaranteed` |
| requests et limits égales pour la mémoire, rien pour le CPU | `Burstable` |
| un conteneur `Guaranteed` et un sidecar sans ressources | `Burstable` |
| aucune request ni limit nulle part | `BestEffort` |
| seulement une ressource étendue (`nvidia.com/gpu`) | `BestEffort` |
| `outils` du fil rouge : requests 50m/64Mi, limits 200m/128Mi | `Burstable` |

La classe a deux effets concrets. Sous **pression** de ressources, le kubelet évince d'abord les pods `BestEffort`, puis les `Burstable` qui dépassent leurs requests, et les `Guaranteed` en dernier. Et quand le **noyau** doit tuer un processus faute de mémoire sur le nœud, il tient compte d'un ajustement `oom_score_adj` que le kubelet pose selon la classe :

| Classe | `oom_score_adj` |
|---|---|
| `Guaranteed` | -997 |
| `BestEffort` | 1000 |
| `Burstable` | min(max(2, 1000 − (1000 × request mémoire) / capacité mémoire du nœud), 999) |

La classe est figée à la création : un redimensionnement en place qui la changerait est refusé (section 4.12).

#### Init containers, sidecars et ressources effectives

Les init containers classiques s'exécutent l'un après l'autre, avant les conteneurs principaux ; les sidecars tournent en même temps qu'eux. Le scheduler raisonne donc sur une request **effective** du pod : la plus grande request parmi les init containers d'un côté, la somme des conteneurs principaux et des sidecars de l'autre, et il retient le maximum des deux (plus l'éventuel *overhead* de la RuntimeClass). Un init container qui demande 2 Gio pour une migration réserve ces 2 Gio sur le nœud, même si les conteneurs principaux n'en demandent que 128 Mio. Les quotas ([chapitre 8.10](08-ordonnancement-et-admission.md)) comptent aussi ces valeurs effectives.

> [!note]
> Les ressources au niveau du pod (`spec.resources`, porte `PodLevelResources`) sont en **bêta**, actives par défaut depuis 1.34 : on peut fixer un budget CPU et mémoire pour le pod entier, que ses conteneurs se partagent. Elles entrent alors dans le calcul de la QoS. Le programme du CKA s'en tient aux ressources par conteneur ; retiens seulement que le champ existe.

### 4.7 OOMKilled, étranglement et éviction

Trois phénomènes produisent des symptômes voisins et n'ont pas la même cause.

L'**OOM kill** est le fait du noyau. Quand les processus d'un conteneur dépassent `memory.max` et que le noyau ne peut plus récupérer de mémoire (cache de pages, par exemple), il tue un processus du cgroup avec `SIGKILL`. Si c'est le processus principal, le conteneur s'arrête avec le code 137 (128 + 9) et la raison `OOMKilled`. Le kubelet applique ensuite la `restartPolicy` : avec `Always`, le conteneur redémarre, replante, et le pod finit en `CrashLoopBackOff`. Le pod n'est pas supprimé et ne change pas de nœud.

```
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
```

> [!warning] `Error` (code 137) au lieu de `OOMKilled`
> La raison `OOMKilled` vient de containerd, qui surveille par inotify le fichier `memory.events` du cgroup de chaque conteneur. Sur un poste dont la limite inotify n'a pas été relevée (chapitre 1.6), cette surveillance échoue pour une partie des conteneurs : `journalctl -u containerd` dans le nœud montre `failed to watch oom events … failed to create inotify fd: too many open files`, et le conteneur tué s'affiche `Error`, code 137, au lieu de `OOMKilled`. Le noyau a pourtant bien tué le processus : `sudo dmesg` dans le nœud montre `Memory cgroup out of memory: Killed process … (sh)`. Ce n'est un comportement ni de Kubernetes ni de minikube, mais la limite de l'hôte, atteinte d'autant plus vite que le lab porte de nombreux conteneurs ; quand la surveillance a pu s'installer, le lab affiche bien `OOMKilled`.

L'**étranglement CPU** ne tue rien. Un conteneur qui atteint sa limit CPU attend la période suivante ; il ralentit. Le symptôme indirect est souvent une sonde qui dépasse son `timeoutSeconds` d'une seconde, et un redémarrage par la sonde de vivacité : la cause est alors la limit CPU, pas l'application.

L'**éviction** est le fait du kubelet, quand le **nœud** manque de mémoire, de disque ou d'identifiants de processus. Elle supprime des pods entiers (phase `Failed`, raison `Evicted`), dans l'ordre des classes QoS vu plus haut, et ces pods ne redémarrent pas sur place : c'est leur contrôleur qui en recrée ailleurs. Un pod nu évincé est perdu.

> [!info] minikube ≠ examen
> Le kubelet du lab a ses seuils d'éviction disque désactivés (`evictionHard` à `0%` pour `nodefs` et `imagefs`) et son ramasse-miettes d'images aussi : une démonstration d'éviction pour manque de disque n'y déclenchera rien. L'OOM kill, lui, est un mécanisme du noyau et se reproduit à l'identique (exercice 4.6).

### 4.8 Sondes : démarrage, vivacité, disponibilité

Le kubelet ne sait pas, par lui-même, si une application fonctionne : un processus vivant peut être bloqué, un serveur démarré peut ne pas encore avoir chargé ses données. Les sondes (*probes*) comblent ce manque. Ce sont des tests que le **kubelet du nœud** exécute périodiquement contre chaque conteneur.

| Sonde | Question posée | Conséquence d'un échec |
|---|---|---|
| `startupProbe` (démarrage) | l'application a-t-elle fini de démarrer ? | après `failureThreshold` échecs, le conteneur est tué et soumis à la `restartPolicy` ; tant qu'elle n'a pas réussi, les deux autres sondes ne tournent pas |
| `livenessProbe` (vivacité) | l'application est-elle encore capable de progresser ? | le conteneur est tué et redémarré |
| `readinessProbe` (disponibilité) | l'application peut-elle recevoir du trafic maintenant ? | le conteneur est marqué non prêt ; le pod sort des EndpointSlices de ses Services ; **rien n'est redémarré** |

Chaque sonde utilise exactement un mécanisme. `httpGet` envoie un GET à l'adresse IP du pod (sauf `host` explicite) ; un code de 200 à 399 est un succès ; les redirections ne sont suivies que vers le même hôte ; le `User-Agent` vaut `kube-probe/1.37`. `tcpSocket` réussit si la connexion s'établit. `exec` lance une commande **dans** le conteneur et réussit si elle sort avec 0 ; c'est le mécanisme le plus coûteux (un processus par essai). `grpc` interroge le service de santé gRPC standard. Le port d'une sonde HTTP ou TCP peut être un numéro ou le **nom** d'un port déclaré dans `ports` : le Deployment `api` du fil rouge sonde `port: http`.

| Champ | Défaut | Minimum | Rôle |
|---|---|---|---|
| `initialDelaySeconds` | 0 | 0 | attente après le démarrage du conteneur avant le premier essai |
| `periodSeconds` | 10 | 1 | intervalle entre deux essais |
| `timeoutSeconds` | 1 | 1 | délai de réponse d'un essai |
| `successThreshold` | 1 | 1 | succès consécutifs pour repasser au vert ; **doit valoir 1** pour `liveness` et `startup` |
| `failureThreshold` | 3 | 1 | échecs consécutifs avant de conclure à l'échec |
| `terminationGracePeriodSeconds` | celle du pod (30) | 1 | délai d'arrêt propre à une sonde `liveness` ou `startup` ; **interdit** sur `readiness` |

Avant son délai initial, une sonde de disponibilité compte comme un échec : un conteneur doté d'une `readinessProbe` démarre toujours **non prêt**. Un conteneur sans sonde est, lui, toujours considéré comme réussi pour la sonde manquante.

Le budget d'une sonde de démarrage vaut `initialDelaySeconds + failureThreshold × periodSeconds`. Si une application met jusqu'à 90 secondes à démarrer, une `startupProbe` avec `periodSeconds: 10` et `failureThreshold: 10` (100 secondes) la protège, et la `livenessProbe` peut garder des réglages courts pour détecter rapidement un blocage une fois l'application lancée. C'est exactement le rôle de la sonde de démarrage : éviter d'allonger le délai initial d'une sonde de vivacité, qui retarderait la détection de toutes les pannes futures.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sondes-completes
  namespace: boutique
spec:
  containers:
  - name: appli
    image: registry.k8s.io/e2e-test-images/agnhost:2.66.1
    args: ["netexec", "--http-port=8080"]
    ports:
    - name: http
      containerPort: 8080
    startupProbe:                 # budget : 24 × 5 s = 120 s pour démarrer
      httpGet: {path: /hostname, port: http}
      periodSeconds: 5
      failureThreshold: 24
    livenessProbe:                # le processus répond-il encore ?
      tcpSocket: {port: http}
      periodSeconds: 10
    readinessProbe:               # peut-il recevoir du trafic ?
      httpGet: {path: /hostname, port: http}
      periodSeconds: 5
```

> [!warning] Une sonde de vivacité ne teste pas les dépendances
> Si la `livenessProbe` interroge une page qui dépend de la base de données, une panne de la base redémarre **tous** les pods de l'application en même temps, sans rien réparer. La vivacité doit tester le processus lui-même ; la disponibilité peut, elle, tenir compte des dépendances, puisqu'elle ne fait que retirer le pod du trafic.

> [!tip] Réflexe d'examen
> Aucun générateur ne crée de sonde : copie le bloc depuis la page « Configure Liveness, Readiness and Startup Probes » (kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/) ou depuis `kubectl explain pod.spec.containers.readinessProbe`. Une sonde ne se modifie pas sur un pod existant : corrige le fichier et `kubectl replace --force -f`. Sur un Deployment, `kubectl edit` suffit et déclenche un rollout.

### 4.9 Init containers

Les init containers, déclarés dans `spec.initContainers`, s'exécutent **avant** les conteneurs principaux, **un par un**, dans l'ordre de la liste, et chacun doit **se terminer avec succès** avant que le suivant démarre. Ils servent à préparer le terrain : attendre qu'un service réponde, générer un fichier de configuration, appliquer une migration de schéma, ajuster des permissions sur un volume. Ils ont tous les champs d'un conteneur, mais un init container classique n'accepte ni `lifecycle`, ni `livenessProbe`, ni `readinessProbe`, ni `startupProbe` : sa seule notion de succès, c'est son code de sortie.

Le kubelet ne lance le premier init container qu'une fois le réseau et les volumes du pod prêts. En cas d'échec, il le relance selon la `restartPolicy` du pod, avec une nuance : si le pod est en `Always`, les init containers se comportent comme en `OnFailure` (un init container qui réussit n'est pas relancé). Si le pod est en `Never`, un init container en échec fait échouer **tout le pod**, phase `Failed`. Pendant ce temps, le pod reste `Pending`, la condition `Initialized` est fausse, et kubectl affiche `Init:N/M`, puis `PodInitializing` quand le dernier a fini.

Trois conséquences pratiques. Un init container peut être rejoué (redémarrage complet du bac à sable, nettoyage du cluster) : son code doit être **idempotent** et supporter qu'un fichier existe déjà. Il ne communique avec les conteneurs principaux que par un volume partagé (un `emptyDir` le plus souvent), puisqu'il est terminé quand ils démarrent. Et un init container qui ne se termine jamais bloque le pod indéfiniment : `activeDeadlineSeconds` sur le pod borne la durée totale, mais il s'applique aussi après l'initialisation et tue un pod qui fonctionne. On le réserve donc aux pods de Job.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: attend-api
  namespace: boutique
spec:
  initContainers:
  - name: attendre
    image: busybox:1.37.0
    command: ["sh", "-c", "until nslookup api.boutique.svc.cluster.local; do echo attente; sleep 2; done"]
  containers:
  - name: appli
    image: busybox:1.37.0
    command: ["sleep", "3600"]
```

### 4.10 Sidecars natifs

Un sidecar est un conteneur auxiliaire qui doit tourner **pendant toute la vie** de l'application principale : expéditeur de journaux, mandataire réseau, agent de synchronisation. Longtemps, on l'a déclaré comme un second conteneur de `containers`, ce qui posait trois problèmes : aucun ordre de démarrage garanti (l'application pouvait démarrer avant son mandataire), aucun ordre d'arrêt (le mandataire pouvait mourir avant que l'application ait fini de répondre), et surtout un pod de Job qui ne se terminait jamais, puisque le sidecar ne s'arrête pas de lui-même.

Kubernetes résout les trois avec les **sidecars natifs**, stables depuis 1.33 (la porte `SidecarContainers` a été supprimée en 1.37) : un sidecar est un **init container dont le champ `restartPolicy` vaut `Always`**.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: appli-avec-sidecar
  namespace: boutique
spec:
  initContainers:
  - name: journal
    image: busybox:1.37.0
    restartPolicy: Always                 # ce qui en fait un sidecar
    command: ["sh", "-c", "trap 'exit 0' TERM; tail -F /var/log/appli/app.log & wait"]
    volumeMounts: [{name: journaux, mountPath: /var/log/appli}]
  containers:
  - name: appli
    image: busybox:1.37.0
    command: ["sh", "-c", "while true; do date >> /var/log/appli/app.log; sleep 5; done"]
    volumeMounts: [{name: journaux, mountPath: /var/log/appli}]
  volumes: [{name: journaux, emptyDir: {}}]
```

Le fonctionnement se déduit de cette définition :

| Moment | Comportement d'un sidecar natif |
|---|---|
| Démarrage | il démarre à sa place dans la liste `initContainers` ; le kubelet passe à l'init container suivant dès que le sidecar est **démarré** (processus lancé, ou `startupProbe` réussie s'il en a une), sans attendre qu'il se termine |
| Exécution | il tourne en même temps que les conteneurs principaux ; il **redémarre toujours**, quelle que soit la `restartPolicy` du pod ; il accepte les trois sondes, et sa `readinessProbe` compte dans la disponibilité du pod |
| Arrêt du pod | le kubelet attend que **tous** les conteneurs principaux soient arrêtés, puis arrête les sidecars **dans l'ordre inverse** de leur déclaration, dans le même délai de grâce |
| Fin d'un Job | un sidecar n'empêche pas le pod de se terminer : quand le conteneur principal finit, les sidecars sont arrêtés et le Job peut être `Complete` |
| Ressources | comptés avec les conteneurs principaux dans la request effective et dans la QoS |
| Affichage | inclus dans la colonne `READY` (`2/2` pour un sidecar et un conteneur principal) |

Un sidecar mis à jour (nouvelle image) est redémarré seul, sans recréer le pod. Et comme le sidecar reçoit son signal d'arrêt en dernier, il dispose souvent de très peu de temps avant `SIGKILL` : un code de sortie non nul d'un sidecar à l'arrêt du pod est normal.

> [!warning] Le PID 1 et les signaux
> Dans un conteneur, le processus de PID 1 **ignore** les signaux pour lesquels il n'a pas installé de gestionnaire : un `sleep` ou un `tail` lancés directement en PID 1 ne réagissent pas à `SIGTERM`, et le conteneur attend tout le délai de grâce avant d'être tué par `SIGKILL`. D'où le motif `trap 'exit 0' TERM; commande & wait` du sidecar ci-dessus : le shell, en PID 1, attrape le signal et sort aussitôt. Sans lui, chaque arrêt du pod coûte 30 secondes, et un Job avec sidecar met 30 secondes de plus à se terminer.

> [!tip] Réflexe d'examen
> Une tâche qui dit « sidecar » sans autre précision se résout aujourd'hui avec un sidecar natif : `initContainers`, `restartPolicy: Always`, volume `emptyDir` partagé. La page « Sidecar Containers » (kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/) donne un exemple de Deployment et un exemple de Job à copier.

### 4.11 Conteneurs éphémères

Un conteneur éphémère est un conteneur ajouté à un pod **en cours d'exécution**, pour le déboguer, par la sous-ressource `ephemeralcontainers`. Il n'a ni ports, ni sondes, ni ressources garanties, il ne redémarre jamais, et il ne peut pas être retiré : il reste dans `spec.ephemeralContainers` jusqu'à la suppression du pod. On ne le crée pas en YAML, mais avec `kubectl debug` :

```bash
kubectl -n boutique debug -it outils --image=busybox:1.37.0 --target=outils
```

`--target` place le conteneur de débogage dans l'espace de noms PID du conteneur visé, ce qui permet de voir ses processus. Depuis 1.36, le profil par défaut de `kubectl debug` est `general`. Les usages (image distroless sans shell, copie de pod, débogage de nœud) sont traités au [chapitre 22.5](22-depanner-les-applications.md).

### 4.12 Redimensionnement en place

#### Le mécanisme

Jusqu'à la 1.32, changer la request ou la limit d'un conteneur imposait de recréer le pod. Le **redimensionnement en place** (*in-place pod resize*, porte `InPlacePodVerticalScaling`) est **stable depuis 1.35** : on modifie le CPU et la mémoire d'un conteneur qui tourne, sans recréer le pod, et le plus souvent sans même redémarrer le conteneur. La demande ne passe pas par une mise à jour ordinaire du pod (qui serait refusée, section 4.1), mais par une **sous-ressource** dédiée, `resize`, que kubectl sait cibler depuis sa version 1.32 :

```bash
kubectl -n boutique patch pod outils --subresource resize --patch \
  '{"spec":{"containers":[{"name":"outils","resources":{"requests":{"cpu":"100m"},"limits":{"cpu":"300m"}}}]}}'
```

`kubectl edit pod outils --subresource resize` et `kubectl apply --server-side --subresource resize -f fichier.yaml` y donnent aussi accès. Le patch stratégique fusionne la liste des conteneurs par leur **nom** : il faut donner `name`, et seules les valeurs citées changent.

La demande traverse ensuite plusieurs étapes, et il faut distinguer trois jeux de valeurs : les ressources **désirées** (`spec.containers[].resources`, ce que tu viens d'écrire), les ressources **allouées** (`status.containerStatuses[].allocatedResources`, ce que le kubelet a accepté de réserver) et les ressources **réelles** (`status.containerStatuses[].resources`, ce qui est appliqué au conteneur).

```
REDIMENSIONNEMENT EN PLACE
══════════════════════════

 kubectl patch … --subresource resize
        │  PATCH …/pods/outils/resize
        ▼
 kube-apiserver
   ├─ validation : CPU et mémoire seulement, classe QoS inchangée,
   │               aucune request ni limit retirée            ─▶ sinon 422 Invalid
   └─ admission PodResizeValidator (active par défaut en 1.37) :
                   requests du pod ≤ allocatable du nœud, nœud Linux
                                                               ─▶ sinon 403 Forbidden
        │
        ▼
 spec.containers[].resources = valeurs DÉSIRÉES   (metadata.generation + 1)
        │
        ▼  kubelet du nœud
   ├─ impossible sur ce nœud         ─▶ PodResizePending, reason Infeasible
   ├─ impossible pour l'instant      ─▶ PodResizePending, reason Deferred (réessais)
   └─ possible ─▶ allocatedResources mis à jour, condition PodResizeInProgress
        │
        ▼  CRI UpdateContainerResources : cgroups (cpu.max, cpu.weight, memory.max)
        │  ou redémarrage du conteneur si sa resizePolicy l'exige
        ▼
 status.containerStatuses[].resources = valeurs RÉELLES ; condition retirée
```

En 1.37, une demande dont les requests dépassent l'allocatable du nœud est **refusée dès l'admission** par le plugin `PodResizeValidator`, actif par défaut depuis la 1.36 : la commande échoue aussitôt, et rien n'est écrit dans le pod.

```
Error from server (Forbidden): pods "outils" is forbidden: node didn't have enough allocatable
resources: cpu, requested: 100000, allocatable: 8000
```

La page de documentation de la tâche montre encore, dans son exemple, une condition `PodResizePending` de raison `Infeasible` pour ce cas ; elle date d'avant ce plugin. La condition reste définie pour les refus que seul le kubelet peut décider. La raison `Deferred`, elle, est le cas courant d'une demande raisonnable sur un nœud trop chargé : la place existe en théorie, mais d'autres pods l'occupent. Le kubelet réessaie quand un pod part, par ordre de priorité (PriorityClass), puis `Guaranteed` avant `Burstable`, puis par ancienneté de la demande. Tant qu'un redimensionnement est en attente, le scheduler compte pour ce pod le **maximum** des requests désirées, allouées et réelles, pour ne pas surcharger le nœud.

#### `resizePolicy` : redémarrer ou non

Chaque conteneur peut dire, ressource par ressource, si une modification exige un redémarrage :

```yaml
    resizePolicy:
    - resourceName: cpu
      restartPolicy: NotRequired
    - resourceName: memory
      restartPolicy: RestartContainer
```

`NotRequired`, la valeur par défaut, applique la modification au conteneur vivant. `RestartContainer` redémarre le conteneur pour appliquer la nouvelle valeur : c'est le bon choix pour la mémoire d'une JVM ou de tout programme qui dimensionne son tas au démarrage. Si les deux ressources changent en même temps et que l'une exige un redémarrage, le conteneur redémarre. Un pod en `restartPolicy: Never` n'accepte que `NotRequired`. Et `resizePolicy` elle-même ne se modifie pas après la création : il faut la prévoir dans le manifeste d'origine.

#### Les limites

| Règle | Conséquence |
|---|---|
| CPU et mémoire seulement | pas de stockage éphémère, pas de ressources étendues |
| Classe QoS figée | un `Burstable` ne peut pas devenir `Guaranteed` : `Pod QOS Class may not change as a result of resizing` |
| Pas de retrait | une request ou une limit existante peut changer de valeur, pas disparaître |
| Baisse de mémoire avec `NotRequired` | le kubelet n'applique pas la nouvelle limit si la consommation la dépasse déjà ; la condition `PodResizeInProgress` reste posée (meilleur effort, sans garantie) |
| Pods exclus | pods statiques, pods Windows, conteneurs sous gestionnaire de CPU ou de mémoire en politique statique, conteneurs éphémères |
| Swap | un pod qui utilise du swap ne change sa mémoire qu'avec `RestartContainer` |
| Init containers | les sidecars sont redimensionnables ; depuis 1.37 (porte `InPlacePodVerticalScalingInitContainers` stable), un init container classique **en cours d'exécution** l'est aussi, avec `NotRequired` uniquement. La liste des limitations de la page de tâche dit encore le contraire : elle n'a pas suivi |
| Variables d'environnement | une variable alimentée par `resourceFieldRef` garde l'ancienne valeur jusqu'au redémarrage ; un volume downward API, lui, est mis à jour ([chapitre 6.8](06-configmaps-et-secrets.md)) |

Un dernier point relie ce chapitre au suivant : redimensionner en place un pod **géré par un Deployment** ne modifie pas son modèle. Le prochain rollout, ou le simple remplacement du pod, revient aux valeurs du modèle. Pour changer durablement les ressources d'une application, on modifie le Deployment (`kubectl set resources deployment/…`), ce qui crée de nouveaux pods ; le redimensionnement en place sert aux pods isolés, aux ajustements temporaires, et aux outils comme le VerticalPodAutoscaler ([chapitre 7.13](07-autoscaling.md)).

> [!tip] Réflexe d'examen
> Mots-clés de l'énoncé : « without restarting », « in place », « resize ». La page à ouvrir : « Resize CPU and Memory Resources assigned to Containers » (kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/). Vérifie ensuite **le statut**, pas la spec : `kubectl get pod P -o jsonpath='{.status.containerStatuses[0].resources}'` et `restartCount`.

### 4.13 Arrêt gracieux

Supprimer un pod n'est pas instantané, et c'est voulu : l'application doit pouvoir finir ses requêtes, vider ses tampons, fermer ses connexions. Le déroulé est le suivant.

```
ARRÊT D'UN POD (kubectl delete pod, éviction, rollout, scale down)
══════════════════════════════════════════════════════════════════

 t=0  API : deletionTimestamp posé, délai = terminationGracePeriodSeconds (30 s)
      kubectl affiche Terminating
        │
        ├──▶ control plane : le pod sort du trafic des Services
        │    (endpoint ready=false, terminating=true dans l'EndpointSlice)
        │
        └──▶ kubelet, sur le nœud, en parallèle :
               1. hook preStop de chaque conteneur qui en a un ─┐
               2. signal d'arrêt au PID 1 de chaque conteneur   │ un seul compte
                  (STOPSIGNAL de l'image, sinon SIGTERM ;       │ à rebours de
                   nginx : SIGQUIT)                              │ 30 s (+2 s une
               3. attente de la fin des processus               ─┘ fois si preStop déborde)
               4. sidecars arrêtés ensuite, en ordre inverse
               5. à l'échéance : SIGKILL à tout ce qui reste
               6. phase terminale, puis suppression de l'objet
```

Le délai couvre le **total** : si `preStop` prend 25 secondes sur 30, l'application n'a que 5 secondes après son signal. Les hooks `preStop` (et `postStart`) acceptent trois actions : `exec` (commande dans le conteneur), `httpGet`, et `sleep` (pause gérée par le kubelet, stable depuis 1.34, sans binaire `sleep` dans l'image). Un `preStop` de quelques secondes, par exemple `lifecycle: {preStop: {sleep: {seconds: 5}}}` dans le conteneur, est la parade classique au délai de propagation : le temps que kube-proxy et les répartiteurs retirent le pod de leurs listes, l'application continue de répondre.

Côté commande, `kubectl delete pod P` attend la fin (option `--wait=true` par défaut). `--grace-period=N` remplace le délai ; `--now` vaut `--grace-period=1`. `--grace-period=0 --force` supprime l'objet de l'API **sans attendre** le kubelet : les processus peuvent continuer de tourner sur le nœud un moment. C'est acceptable pour un pod de démonstration, dangereux pour un membre de StatefulSet (deux pods du même nom pourraient coexister).

> [!tip] Réflexe d'examen
> Les pods de test lancés avec `sleep 3600` ignorent `SIGTERM` (PID 1, encadré de la section 4.10) : chaque suppression coûte 30 secondes. Supprime-les avec `kubectl delete pod P --now`, ou ajoute `terminationGracePeriodSeconds: 1` dans le manifeste.

### 4.14 securityContext : les bases

Le champ `securityContext` existe à deux niveaux : sur le pod (`spec.securityContext`, qui vaut pour tous les conteneurs) et sur chaque conteneur (`containers[].securityContext`, qui **l'emporte** pour les champs qu'il redéfinit). Certains champs n'existent qu'à un niveau : `fsGroup` et `supplementalGroups` sont propres au pod, `privileged`, `capabilities`, `readOnlyRootFilesystem` et `allowPrivilegeEscalation` propres au conteneur.

| Champ | Effet |
|---|---|
| `runAsUser`, `runAsGroup` | UID et GID du processus principal, à la place de l'utilisateur de l'image |
| `runAsNonRoot: true` | le kubelet refuse de démarrer un conteneur qui tournerait en UID 0 |
| `fsGroup` | groupe propriétaire des volumes montés (et ajouté aux groupes du processus) |
| `readOnlyRootFilesystem: true` | système de fichiers racine du conteneur en lecture seule ; les volumes restent inscriptibles |
| `allowPrivilegeEscalation: false` | interdit à un processus de gagner des privilèges (setuid, `no_new_privs`) |
| `capabilities.drop` / `add` | retire ou ajoute des capacités Linux (`drop: ["ALL"]`, `add: ["NET_BIND_SERVICE"]`) |
| `privileged: true` | accès quasi complet à l'hôte ; à réserver aux agents système |
| `seccompProfile.type: RuntimeDefault` | filtre d'appels système par défaut du runtime |

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: non-root
  namespace: boutique
spec:
  securityContext:
    runAsUser: 1000
    runAsGroup: 3000
    fsGroup: 2000
  containers:
  - name: appli
    image: busybox:1.37.0
    command: ["sh", "-c", "id; sleep 3600"]
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: {drop: ["ALL"]}
```

Ses journaux affichent `uid=1000 gid=3000 groups=2000,3000`. Les erreurs de sécurité apparaissent au démarrage du conteneur, en `CreateContainerConfigError`, avec un message explicite dans `kubectl describe pod` : `container has runAsNonRoot and image will run as root` quand l'image démarre en root, `container has runAsNonRoot and image has non-numeric user (appuser), cannot verify user is non-root` quand l'image déclare un utilisateur par son nom (il faut alors ajouter un `runAsUser` numérique). Ces champs sont aussi ce que vérifie Pod Security Admission, qui refuse ou signale les pods trop permissifs selon le niveau du namespace : c'est l'objet du [chapitre 8.13](08-ordonnancement-et-admission.md).

### 4.15 Pièges courants

```
Piège 1 : Modifier les ressources d'un pod comme un autre champ
═══════════════════════════════════════════════════════════════
  MAUVAIS  : kubectl edit pod outils, puis changer resources
  SYMPTÔME : « pod updates may not change fields other than … »
  BON      : kubectl patch pod outils --subresource resize -p '…'
             (ou kubectl edit pod outils --subresource resize)

Piège 2 : Un command qui efface les arguments de l'image
═════════════════════════════════════════════════════════
  MAUVAIS  : command: ["/agnhost"]  en croyant garder « netexec »
  SYMPTÔME : le conteneur fait autre chose, ou sort aussitôt
  BON      : args seul pour garder l'ENTRYPOINT ; command + args sinon

Piège 3 : Une sonde de vivacité trop pressée
════════════════════════════════════════════
  SYMPTÔME : CrashLoopBackOff, « failed liveness probe, will be restarted »
             alors que l'application démarre simplement lentement
  BON      : une startupProbe dont le budget
             (initialDelaySeconds + failureThreshold × periodSeconds)
             couvre le démarrage le plus lent

Piège 4 : Le sidecar déclaré dans containers
════════════════════════════════════════════
  SYMPTÔME : le Job ne se termine jamais, le pod reste Running
  BON      : initContainers + restartPolicy: Always (sidecar natif)

Piège 5 : 400m de mémoire
═════════════════════════
  MAUVAIS  : memory: 400m   (0,4 octet)
  BON      : memory: 400Mi

Piège 6 : Changer de classe QoS par un redimensionnement
════════════════════════════════════════════════════════
  SYMPTÔME : « Pod QOS Class may not change as a result of resizing »
  BON      : rester dans la classe d'origine, ou recréer le pod

Piège 7 : Supprimer un pod « sleep » et attendre
════════════════════════════════════════════════
  SYMPTÔME : kubectl delete bloque 30 secondes
  CAUSE    : sleep en PID 1 ignore SIGTERM
  BON      : kubectl delete pod P --now

Piège 8 : kubectl exec sans « -- »
══════════════════════════════════
  MAUVAIS  : kubectl exec outils cat /etc/resolv.conf
  SYMPTÔME : refusé depuis kubectl 1.35
  BON      : kubectl exec outils -- cat /etc/resolv.conf
```

> [!summary] À retenir
> - Un pod partage réseau, IPC, UTS et volumes entre ses conteneurs ; il est planifié une fois, ne bouge jamais, et sa spec est immuable sauf `image`, `activeDeadlineSeconds`, ajout de `tolerations`, `terminationGracePeriodSeconds`, et les ressources par la sous-ressource `resize`.
> - `command` remplace l'`ENTRYPOINT` (et efface le `CMD`), `args` remplace le `CMD` ; `$(VAR)` est résolu par Kubernetes, `$VAR` par un shell qu'il faut appeler soi-même.
> - Phase, conditions et états de conteneurs sont trois niveaux distincts ; la colonne `STATUS` n'est qu'un résumé de kubectl.
> - Le kubelet redémarre les conteneurs selon `restartPolicy` (défaut `Always`) avec un délai de 10 s doublé jusqu'à 300 s ; `kubectl logs --previous` lit le conteneur qui a planté.
> - Requests pour le scheduler, limits pour le noyau : CPU étranglé, mémoire tuée (`OOMKilled`, code 137). Une limit seule recopie sa valeur dans la request.
> - QoS : `Guaranteed` si chaque conteneur a request = limit en CPU et en mémoire, `BestEffort` si rien nulle part, `Burstable` sinon ; figée à la création.
> - Startup protège le démarrage, liveness redémarre, readiness retire du trafic sans redémarrer ; défauts 10 s / 1 s / 3 échecs.
> - Init containers : séquentiels, jusqu'au succès ; sidecar natif : init container avec `restartPolicy: Always`, démarré avant, arrêté après, sans bloquer la fin d'un Job.
> - Redimensionnement en place (stable 1.35) : `--subresource resize`, `resizePolicy` (`NotRequired` par défaut), QoS inchangée ; en 1.37, l'admission `PodResizeValidator` refuse ce qui dépasse l'allocatable du nœud.
> - Arrêt : un seul délai de grâce (30 s) pour `preStop` et signal ; PID 1 sans gestionnaire ignore `SIGTERM`.

### 4.16 Exercices

Les exercices de ce chapitre se font dans le namespace `boutique`. Les commandes portent `-n boutique` explicitement, même si ton contexte `boutique` ([chapitre 3](03-kubectl-efficace.md)) est actif : c'est l'habitude à prendre pour l'examen, où chaque tâche précise son namespace. Seul le pod `outils` reste à la fin du chapitre ; tous les autres sont supprimés à la fin de leur exercice.

#### Exercice 4.1 — La boîte à outils `outils`

**Point de départ** : chapitre 3 terminé (namespace `boutique`), ou instantané I0 suivi de `lab/etats/03-kubectl-efficace/appliquer.sh`.

Dans le namespace `boutique`, crée un pod nommé `outils`, image `nicolaka/netshoot:v0.16`, qui exécute `sleep infinity`, avec les labels `app=outils` et `tier=outils`, des requests de `50m` de CPU et `64Mi` de mémoire et des limits de `200m` de CPU et `128Mi` de mémoire. Enregistre le manifeste dans `~/cka/boutique/outils.yaml`. Relève ensuite la classe QoS du pod, son nœud, son adresse IP, et la limite CPU vue par le noyau dans le conteneur.

> [!example]- Solution
> ```bash
> mkdir -p ~/cka/boutique
> kubectl -n boutique run outils --image=nicolaka/netshoot:v0.16 \
>   --labels=app=outils,tier=outils --dry-run=client -o yaml --command -- sleep infinity \
>   | kubectl set resources --local -f - --requests=cpu=50m,memory=64Mi \
>       --limits=cpu=200m,memory=128Mi -o yaml > ~/cka/boutique/outils.yaml
> kubectl -n boutique apply -f ~/cka/boutique/outils.yaml
> kubectl -n boutique wait --for=condition=Ready pod/outils --timeout=180s
> ```
>
> Une fois retiré le `status: {}` vide (kubectl 1.37 n'écrit plus `creationTimestamp: null`), le manifeste se lit ainsi, champs remis dans l'ordre :
>
> ```yaml
> apiVersion: v1
> kind: Pod
> metadata:
>   name: outils
>   namespace: boutique
>   labels:
>     app: outils
>     tier: outils
> spec:
>   containers:
>   - name: outils
>     image: nicolaka/netshoot:v0.16
>     command: ["sleep", "infinity"]
>     resources:
>       requests: {cpu: 50m, memory: 64Mi}
>       limits: {cpu: 200m, memory: 128Mi}
>   dnsPolicy: ClusterFirst
>   restartPolicy: Always
> ```
>
> `--command` place `sleep infinity` dans `command` ; sans lui, il irait dans `args`, ce qui reviendrait au même ici puisque netshoot n'a pas d'`ENTRYPOINT`. Requests et limits diffèrent : le pod est `Burstable`. Le premier démarrage peut prendre une minute : l'image de netshoot est volumineuse.
>
> **Vérification** :
>
> ```bash
> kubectl -n boutique get pod outils \
>   -o custom-columns=NOM:.metadata.name,NOEUD:.spec.nodeName,IP:.status.podIP,QOS:.status.qosClass
> kubectl -n boutique exec outils -- cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max
> ```
>
> ```
> NOM      NOEUD     IP               QOS
> outils   cka-m02   10.244.195.193   Burstable
> 20000 100000
> 134217728
> ```
>
> Le nœud et l'adresse varient d'un lab à l'autre ; la classe et les deux valeurs de cgroup, non.

#### Exercice 4.2 — Les trois sondes

**Point de départ** : exercice 4.1.

Dans `boutique`, crée trois pods portant le label `exercice=sondes` et observe leur comportement :

1. `sonde-vie` : image `registry.k8s.io/e2e-test-images/agnhost:2.66.1`, argument `liveness` (un serveur dont `/healthz` sur le port 8080 répond 200 pendant 10 secondes, puis 500), avec une sonde de vivacité HTTP sur ce chemin, délai initial 3 s, période 3 s.
2. `sonde-pret` : image `busybox:1.37.0`, `sleep 3600`, avec une sonde de disponibilité `exec` qui lit `/tmp/pret` toutes les 5 secondes. Rends le pod prêt, puis de nouveau non prêt, sans le recréer.
3. `sonde-demarrage` : image `busybox:1.37.0`, commande `sleep 30; touch /tmp/demarre; sleep 3600`, avec une sonde de démarrage `exec` qui lit `/tmp/demarre` (période 5 s, 3 échecs tolérés) et une sonde de vivacité identique. Constate l'échec, puis corrige le seuil pour que le pod démarre.

Supprime les trois pods à la fin.

> [!example]- Solution
> Enregistre les trois manifestes dans `~/cka/boutique/sondes.yaml` :
>
> ```yaml
> apiVersion: v1
> kind: Pod
> metadata: {name: sonde-vie, namespace: boutique, labels: {exercice: sondes}}
> spec:
>   containers:
>   - name: appli
>     image: registry.k8s.io/e2e-test-images/agnhost:2.66.1
>     args: ["liveness"]
>     livenessProbe:
>       httpGet: {path: /healthz, port: 8080}
>       initialDelaySeconds: 3
>       periodSeconds: 3
> ---
> apiVersion: v1
> kind: Pod
> metadata: {name: sonde-pret, namespace: boutique, labels: {exercice: sondes}}
> spec:
>   terminationGracePeriodSeconds: 1
>   containers:
>   - name: appli
>     image: busybox:1.37.0
>     command: ["sleep", "3600"]
>     readinessProbe:
>       exec: {command: ["cat", "/tmp/pret"]}
>       periodSeconds: 5
> ---
> apiVersion: v1
> kind: Pod
> metadata: {name: sonde-demarrage, namespace: boutique, labels: {exercice: sondes}}
> spec:
>   terminationGracePeriodSeconds: 1
>   containers:
>   - name: appli
>     image: busybox:1.37.0
>     command: ["sh", "-c", "sleep 30; touch /tmp/demarre; sleep 3600"]
>     startupProbe:
>       exec: {command: ["cat", "/tmp/demarre"]}
>       periodSeconds: 5
>       failureThreshold: 3
>     livenessProbe:
>       exec: {command: ["cat", "/tmp/demarre"]}
>       periodSeconds: 5
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/sondes.yaml
> kubectl -n boutique get pods -l exercice=sondes -w      # Ctrl+C après une minute
> kubectl -n boutique events --for pod/sonde-vie
> ```
>
> `sonde-vie` redémarre environ toutes les 20 secondes : 10 secondes de réponses 200, puis trois échecs à 3 secondes d'écart. Les événements montrent `Liveness probe failed: HTTP probe failed with statuscode: 500` puis `Container appli failed liveness probe, will be restarted`. Au bout de quelques cycles, le délai exponentiel s'installe et le pod passe par `CrashLoopBackOff`.
>
> `sonde-pret` est `Running` mais `0/1` : la sonde échoue, le fichier n'existe pas. On le crée, puis on l'efface :
>
> ```bash
> kubectl -n boutique exec sonde-pret -- touch /tmp/pret
> kubectl -n boutique get pod sonde-pret          # READY 1/1 en 5 secondes au plus
> kubectl -n boutique exec sonde-pret -- rm /tmp/pret
> kubectl -n boutique get pod sonde-pret          # READY 0/1 après 3 échecs, ~15 s ; RESTARTS 0
> ```
>
> `sonde-demarrage` a un budget de 3 × 5 = 15 secondes pour une application qui en met 30 : il est tué avant d'avoir démarré, à chaque tentative. Une sonde ne se modifie pas sur un pod existant ; on corrige le fichier (`failureThreshold: 12`, soit 60 secondes) et on recrée :
>
> ```bash
> sed -i 's/failureThreshold: 3/failureThreshold: 12/' ~/cka/boutique/sondes.yaml
> kubectl replace --force -f ~/cka/boutique/sondes.yaml
> kubectl -n boutique delete pod -l exercice=sondes --now       # une fois l'observation faite
> ```
>
> **Vérification** (`replace --force` a recréé les trois pods, sans conséquence ici) : après la correction, `kubectl -n boutique get pod sonde-demarrage` affiche `1/1 Running` avec `RESTARTS 0` environ 35 secondes après la création ; après le nettoyage, `kubectl -n boutique get pods -l exercice=sondes` répond `No resources found in boutique namespace.`

#### Exercice 4.3 — Un init container qui prépare le terrain

**Point de départ** : exercice 4.2.

Crée dans `boutique` un pod `init-demo` dont un init container `preparer` (`busybox:1.37.0`) attend 15 secondes puis écrit `<h1>Prepare par un init container</h1>` dans `index.html` d'un volume `emptyDir` nommé `travail`, et dont le conteneur principal `web` (`nginx:1.30.6-alpine`) sert ce volume à la place de `/usr/share/nginx/html`. Observe les états successifs, puis interroge le serveur depuis `outils`. Supprime le pod ensuite.

> [!example]- Solution
> Manifeste `~/cka/boutique/init-demo.yaml` :
>
> ```yaml
> apiVersion: v1
> kind: Pod
> metadata: {name: init-demo, namespace: boutique}
> spec:
>   initContainers:
>   - name: preparer
>     image: busybox:1.37.0
>     command: ["sh", "-c", "sleep 15; echo '<h1>Prepare par un init container</h1>' > /travail/index.html"]
>     volumeMounts: [{name: travail, mountPath: /travail}]
>   containers:
>   - name: web
>     image: nginx:1.30.6-alpine
>     volumeMounts: [{name: travail, mountPath: /usr/share/nginx/html}]
>   volumes: [{name: travail, emptyDir: {}}]
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/init-demo.yaml
> kubectl -n boutique get pod init-demo -w      # Init:0/1, puis PodInitializing, puis Running
> IP=$(kubectl -n boutique get pod init-demo -o jsonpath='{.status.podIP}')
> kubectl -n boutique exec outils -- curl -s http://$IP/
> kubectl -n boutique delete pod init-demo
> ```
>
> Le volume `emptyDir` naît avec le pod, avant l'init container, et survit à sa fin : c'est le seul canal entre les deux conteneurs, puisque `preparer` est terminé quand `web` démarre. Monté sur `/usr/share/nginx/html`, il masque le contenu de l'image à cet endroit.
>
> **Vérification** : `curl` renvoie `<h1>Prepare par un init container</h1>`, et `kubectl -n boutique get pod init-demo -o jsonpath='{.status.initContainerStatuses[0].state.terminated.reason}'` affichait `Completed` avant la suppression.

#### Exercice 4.4 — Un sidecar natif `journal`

**Point de départ** : exercice 4.3.

Crée dans `boutique` un pod `appli-journal` dont le conteneur principal `appli` (`busybox:1.37.0`) ajoute toutes les 5 secondes une ligne datée suivie de `commande traitee` au fichier `/var/log/appli/app.log`, et dont un sidecar natif nommé `journal` (`busybox:1.37.0`) suit ce fichier avec `tail -F` et s'arrête proprement sur `SIGTERM`. Les deux partagent un volume `emptyDir` nommé `journaux`. Lis les journaux du sidecar. Crée ensuite un Job `tache-journal` construit sur le même modèle, dont le conteneur principal écrit trois lignes puis se termine, et vérifie que le Job se termine malgré le sidecar. Supprime le pod et le Job.

> [!example]- Solution
> Manifeste `~/cka/boutique/sidecar.yaml` (le pod et le Job) :
>
> ```yaml
> apiVersion: v1
> kind: Pod
> metadata: {name: appli-journal, namespace: boutique}
> spec:
>   initContainers:
>   - name: journal
>     image: busybox:1.37.0
>     restartPolicy: Always
>     command: ["sh", "-c", "trap 'exit 0' TERM; tail -F /var/log/appli/app.log & wait"]
>     volumeMounts: [{name: journaux, mountPath: /var/log/appli}]
>   containers:
>   - name: appli
>     image: busybox:1.37.0
>     command: ["sh", "-c", "while true; do echo \"$(date) commande traitee\" >> /var/log/appli/app.log; sleep 5; done"]
>     volumeMounts: [{name: journaux, mountPath: /var/log/appli}]
>   volumes: [{name: journaux, emptyDir: {}}]
> ---
> apiVersion: batch/v1
> kind: Job
> metadata: {name: tache-journal, namespace: boutique}
> spec:
>   template:
>     spec:
>       restartPolicy: Never
>       initContainers:
>       - name: journal
>         image: busybox:1.37.0
>         restartPolicy: Always
>         command: ["sh", "-c", "trap 'exit 0' TERM; tail -F /var/log/appli/app.log & wait"]
>         volumeMounts: [{name: journaux, mountPath: /var/log/appli}]
>       containers:
>       - name: appli
>         image: busybox:1.37.0
>         command: ["sh", "-c", "for i in 1 2 3; do echo \"etape $i\" >> /var/log/appli/app.log; sleep 2; done"]
>         volumeMounts: [{name: journaux, mountPath: /var/log/appli}]
>       volumes: [{name: journaux, emptyDir: {}}]
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/sidecar.yaml
> kubectl -n boutique get pod appli-journal                 # READY 2/2
> kubectl -n boutique logs appli-journal -c journal --tail=3
> kubectl -n boutique wait --for=condition=complete job/tache-journal --timeout=120s
> ```
>
> Le sidecar est un init container : sans `-c journal`, `kubectl logs` lirait le conteneur principal (seul conteneur de `containers`), qui n'écrit rien sur sa sortie. Le `trap` sert à l'arrêt : sans lui, `tail` en PID 1 ignorerait `SIGTERM`, et le Job attendrait 30 secondes de plus que le kubelet tue son sidecar. `$(date)` n'est pas une variable connue du conteneur : Kubernetes le laisse intact et le shell l'exécute.
>
> **Vérification** :
>
> ```bash
> kubectl -n boutique get job tache-journal
> kubectl -n boutique get pods -l batch.kubernetes.io/job-name=tache-journal \
>   -o jsonpath='{.items[0].status.initContainerStatuses[0].state.terminated.exitCode}{"\n"}'
> kubectl -n boutique delete pod appli-journal --now
> kubectl -n boutique delete job tache-journal
> ```
>
> ```
> NAME            STATUS     COMPLETIONS   DURATION   AGE
> tache-journal   Complete   1/1           11s        14s
> 0
> ```
>
> La durée exacte varie (téléchargement d'image compris) ; le sidecar sort avec le code 0, signe qu'il a traité `SIGTERM`.

#### Exercice 4.5 — Trois classes QoS (et un cas piège)

**Point de départ** : exercice 4.4.

Crée dans `boutique` quatre pods `busybox:1.37.0` qui exécutent `sleep 3600`, tous avec le label `exercice=qos` : `qos-garanti` (requests et limits de `100m` et `32Mi`), `qos-variable` (requests `50m` et `32Mi`, limit mémoire `64Mi` seulement), `qos-minimal` (aucune ressource) et `qos-limites` (limits `100m` et `32Mi`, aucune request). Prédis la classe de chacun avant de la lire, puis compare l'`oom_score_adj` de leurs processus. Supprime-les.

> [!example]- Solution
> Manifeste `~/cka/boutique/qos.yaml` :
>
> ```yaml
> apiVersion: v1
> kind: Pod
> metadata: {name: qos-garanti, namespace: boutique, labels: {exercice: qos}}
> spec:
>   terminationGracePeriodSeconds: 1
>   containers:
>   - name: appli
>     image: busybox:1.37.0
>     command: ["sleep", "3600"]
>     resources:
>       requests: {cpu: 100m, memory: 32Mi}
>       limits: {cpu: 100m, memory: 32Mi}
> ---
> apiVersion: v1
> kind: Pod
> metadata: {name: qos-variable, namespace: boutique, labels: {exercice: qos}}
> spec:
>   terminationGracePeriodSeconds: 1
>   containers:
>   - name: appli
>     image: busybox:1.37.0
>     command: ["sleep", "3600"]
>     resources:
>       requests: {cpu: 50m, memory: 32Mi}
>       limits: {memory: 64Mi}
> ---
> apiVersion: v1
> kind: Pod
> metadata: {name: qos-minimal, namespace: boutique, labels: {exercice: qos}}
> spec:
>   terminationGracePeriodSeconds: 1
>   containers:
>   - name: appli
>     image: busybox:1.37.0
>     command: ["sleep", "3600"]
> ---
> apiVersion: v1
> kind: Pod
> metadata: {name: qos-limites, namespace: boutique, labels: {exercice: qos}}
> spec:
>   terminationGracePeriodSeconds: 1
>   containers:
>   - name: appli
>     image: busybox:1.37.0
>     command: ["sleep", "3600"]
>     resources:
>       limits: {cpu: 100m, memory: 32Mi}
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/qos.yaml
> kubectl -n boutique get pods -l exercice=qos -o custom-columns=NOM:.metadata.name,QOS:.status.qosClass
> for p in qos-garanti qos-variable qos-minimal qos-limites; do
>   echo "$p $(kubectl -n boutique exec $p -- cat /proc/1/oom_score_adj)"
> done
> kubectl -n boutique get pod qos-limites -o jsonpath='{.spec.containers[0].resources.requests}{"\n"}'
> kubectl -n boutique delete pods -l exercice=qos
> ```
>
> Le cas piège est `qos-limites` : sans request, le serveur d'API recopie les limits dans les requests, et le pod devient `Guaranteed`. La dernière commande avant la suppression le montre (`{"cpu":"100m","memory":"32Mi"}`). Pour `qos-variable`, la formule donne 1000 − (1000 × 32 Mio) / capacité mémoire du nœud : 999 sur un nœud de 32 Gio, un peu moins sur un poste qui a moins de mémoire.
>
> **Vérification** :
>
> ```
> NOM            QOS
> qos-garanti    Guaranteed
> qos-limites    Guaranteed
> qos-minimal    BestEffort
> qos-variable   Burstable
> qos-garanti -997
> qos-variable 999
> qos-minimal 1000
> qos-limites -997
> ```

#### Exercice 4.6 — Provoquer un OOMKilled

**Point de départ** : exercice 4.5.

Crée dans `boutique` un pod `gourmand` (`busybox:1.37.0`) limité à `32Mi` de mémoire, dont la commande double sans fin la taille d'une chaîne en mémoire : `x=a; while true; do x=$x$x; done`. Observe son état, la raison et le code de sa dernière terminaison, puis supprime-le.

> [!example]- Solution
> Manifeste `~/cka/boutique/gourmand.yaml` :
>
> ```yaml
> apiVersion: v1
> kind: Pod
> metadata: {name: gourmand, namespace: boutique}
> spec:
>   containers:
>   - name: appli
>     image: busybox:1.37.0
>     command: ["sh", "-c", "echo remplissage; x=a; while true; do x=$x$x; done"]
>     resources:
>       limits: {memory: 32Mi}
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/gourmand.yaml
> kubectl -n boutique get pod gourmand -w           # OOMKilled, puis CrashLoopBackOff (ou Error)
> kubectl -n boutique describe pod gourmand | grep -A4 'Last State'
> kubectl -n boutique delete pod gourmand --now
> ```
>
> `$x` n'a pas de parenthèses : Kubernetes ne le touche pas, c'est le shell qui l'interprète. La chaîne atteint 32 Mio en 25 doublements, quelques millisecondes : le noyau tue le shell, et la `restartPolicy` `Always` relance le conteneur, qui replante, d'où le délai exponentiel. La limit seule a fixé la request mémoire à `32Mi`, et l'absence de CPU rend le pod `Burstable`.
>
> **Vérification** :
>
> ```
>     Last State:     Terminated
>       Reason:       OOMKilled
>       Exit Code:    137
> ```
>
> et `kubectl -n boutique get pod gourmand -o jsonpath='{.status.containerStatuses[0].restartCount}'` renvoie un nombre qui croît à chaque observation. Si `Reason` vaut `Error` avec le même code 137, c'est la limite inotify de ton poste qui a empêché containerd d'observer l'OOM (encadré de la section 4.7) : relève-la.

#### Exercice 4.7 — Redimensionner `outils` sans le redémarrer

**Point de départ** : exercice 4.6 (ou exercice 4.1 : seul `outils` compte).

Sans recréer le pod ni redémarrer son conteneur, passe la request CPU de `outils` à `100m` et sa limit CPU à `300m` ; la mémoire ne change pas. Montre d'abord qu'une modification ordinaire est refusée, puis vérifie la prise en compte par le kubelet et par le noyau. Essaie ensuite deux demandes que le serveur d'API doit refuser : rendre le pod `Guaranteed`, et lui donner 100 CPU. Mets enfin `~/cka/boutique/outils.yaml` en accord avec l'état du pod.

> [!example]- Solution
> ```bash
> # 1. Une mise à jour ordinaire est refusée
> kubectl -n boutique patch pod outils -p \
>   '{"spec":{"containers":[{"name":"outils","resources":{"requests":{"cpu":"100m"}}}]}}'
> # The Pod "outils" is invalid: spec: Forbidden: pod updates may not change fields other than …
>
> # 2. Le redimensionnement passe par la sous-ressource resize
> kubectl -n boutique patch pod outils --subresource resize --patch \
>   '{"spec":{"containers":[{"name":"outils","resources":{"requests":{"cpu":"100m"},"limits":{"cpu":"300m"}}}]}}'
>
> # 3. Deux demandes refusées
> kubectl -n boutique patch pod outils --subresource resize --patch \
>   '{"spec":{"containers":[{"name":"outils","resources":{"requests":{"cpu":"300m","memory":"128Mi"}}}]}}'
> kubectl -n boutique patch pod outils --subresource resize --patch \
>   '{"spec":{"containers":[{"name":"outils","resources":{"requests":{"cpu":"100"},"limits":{"cpu":"100"}}}]}}'
>
> # 4. Le manifeste suit l'état réel
> kubectl set resources --local -f ~/cka/boutique/outils.yaml \
>   --requests=cpu=100m --limits=cpu=300m -o yaml > /tmp/outils.yaml \
>   && mv /tmp/outils.yaml ~/cka/boutique/outils.yaml
> ```
>
> La première tentative du point 3 rendrait requests et limits égales pour le CPU (`300m`) et la mémoire (`128Mi`) : le pod passerait de `Burstable` à `Guaranteed`, ce que la validation interdit (`The Pod "outils" is invalid: spec: Invalid value: "Burstable": Pod QOS Class may not change as a result of resizing`). La seconde demande 100 cœurs : le plugin d'admission `PodResizeValidator` la refuse avant tout enregistrement (`Error from server (Forbidden): pods "outils" is forbidden: node didn't have enough allocatable resources: cpu, requested: 100000, allocatable: 8000` ; la valeur `allocatable` est celle de ton hôte). Aucune `resizePolicy` n'étant déclarée, le CPU suit la valeur par défaut `NotRequired` : pas de redémarrage. Le fichier local est mis à jour pour la documentation ; un `kubectl apply` de ce fichier sur le pod existant ne changerait de toute façon rien, puisque les valeurs sont identiques.
>
> **Vérification** :
>
> ```bash
> kubectl -n boutique get pod outils -o jsonpath='{.status.containerStatuses[0].resources}{"\n"}{.status.containerStatuses[0].restartCount}{"\n"}'
> kubectl -n boutique get pod outils -o jsonpath='{range .status.conditions[*]}{.type} {end}{"\n"}'
> kubectl -n boutique exec outils -- cat /sys/fs/cgroup/cpu.max
> ```
>
> ```
> {"limits":{"cpu":"300m","memory":"128Mi"},"requests":{"cpu":"100m","memory":"64Mi"}}
> 0
> PodReadyToStartContainers Initialized Ready ContainersReady PodScheduled
> 30000 100000
> ```
>
> Les valeurs **réelles** du statut ont suivi, le compteur de redémarrages est resté à 0, aucune condition `PodResizePending` ou `PodResizeInProgress` ne subsiste, et le noyau applique désormais 30 ms de CPU par période de 100 ms. C'est l'état que le chapitre 5 reprend : `outils` reste en place pour toute la suite du cours.

---
