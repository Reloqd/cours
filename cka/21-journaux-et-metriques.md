---
title: "CKA — 21. Journaux, événements et métriques"
description: "D'où viennent les journaux des conteneurs et des composants, comment les lire avec kubectl, crictl et journalctl, ce que disent les événements et ce que mesurent metrics-server et kubectl top."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 21. Journaux, événements et métriques

Dépanner, c'est d'abord observer. Avant de corriger quoi que ce soit, tu dois savoir où un conteneur écrit ce qu'il raconte, qui recueille ces lignes, combien de temps elles survivent, et quels autres témoins le cluster garde de ce qui s'est passé : les événements, l'état des nœuds, les métriques de consommation. Ce chapitre ouvre la partie consacrée au dépannage, qui pèse 30 % de l'examen. Il couvre deux compétences du programme, « Manage and evaluate container output streams » et « Monitor cluster and application resource usage », et prépare la troisième, « Troubleshoot cluster components », que le [chapitre 23](23-depanner-le-cluster.md) traite en entier. On y suit le chemin d'une ligne de journal depuis le `printf` d'une application jusqu'à ton terminal, on passe en revue toutes les options de `kubectl logs`, puis on lit les journaux des composants qui ne tournent pas dans des pods (kubelet, containerd), les événements, les métriques de metrics-server et le bilan d'allocation d'un nœud. Les chapitres [22](22-depanner-les-applications.md) et [23](23-depanner-le-cluster.md) s'appuient sur chacun de ces outils.

### 21.1 Les flux de sortie d'un conteneur

Un processus Linux reçoit trois descripteurs de fichier ouverts à son démarrage : 0 (l'entrée standard), 1 (la sortie standard, stdout) et 2 (la sortie d'erreur, stderr). Dans un conteneur, ce sont ces deux derniers flux, et eux seuls, que Kubernetes considère comme « les journaux du conteneur ». Le runtime (containerd, par l'intermédiaire de son processus `containerd-shim-runc-v2`) branche les descripteurs 1 et 2 du processus principal sur des tubes, lit tout ce qui y passe et l'écrit dans un fichier sur le disque du nœud. Une application qui écrit dans `/var/log/app.log` à l'intérieur de son conteneur, dans syslog ou dans un fichier de son volume, n'écrit donc **pas** dans ses journaux au sens de Kubernetes : `kubectl logs` ne montrera rien.

C'est la raison pour laquelle les images officielles redirigent leurs fichiers de journalisation vers les flux standard. L'image `nginx` crée par exemple `/var/log/nginx/access.log` comme un lien vers `/dev/stdout` et `error.log` comme un lien vers `/dev/stderr`. Quand une application ne sait écrire que dans un fichier, on lui adjoint un conteneur annexe qui relit ce fichier et le recopie sur sa propre sortie standard (le sidecar natif du chapitre 4, `journal`, en est l'exemple du fil rouge).

```
Le trajet d'une ligne de journal
════════════════════════════════

  conteneur                    nœud                               poste
  ─────────                    ────                               ─────
  processus                    containerd-shim
   fd 1 (stdout) ──tube──▶  ┐  lit, horodate, étiquette
   fd 2 (stderr) ──tube──▶  ┘  puis écrit dans
                               /var/log/pods/<ns>_<pod>_<uid>/<conteneur>/<N>.log
                                          ▲
                                          │ lecture directe du fichier
                               kubelet :10250 /containerLogs/…
                                          ▲
                                          │ HTTPS (proxy de l'API)
                               kube-apiserver  /api/v1/namespaces/<ns>/pods/<pod>/log
                                          ▲
                                          │
                                       kubectl logs ◀────────────────── toi
```

Deux conséquences découlent de ce schéma. D'abord, `kubectl logs` est une lecture **à la demande d'un fichier local au nœud** : il n'existe aucune base de journaux dans le cluster. Si le nœud disparaît, les journaux disparaissent avec lui ; si le pod est supprimé, le kubelet efface son dossier. Ensuite, la commande traverse l'API server puis le kubelet du nœud : un kubelet arrêté rend les journaux illisibles par `kubectl` alors même que les fichiers sont intacts sur le disque. On les lit alors directement sur le nœud (21.4).

Les deux flux sont mêlés dans le même fichier, dans l'ordre de leur arrivée, chaque ligne gardant la trace du flux d'origine. `kubectl logs` les restitue ensemble. Une fonction alpha, `PodLogsQuerySplitStreams` (désactivée par défaut en 1.37), permet de demander un seul flux par le paramètre `stream=Stdout` ou `stream=Stderr` de l'API ; tu ne la rencontreras pas à l'examen. Si le conteneur est déclaré avec `tty: true`, il n'y a plus qu'un pseudo-terminal et tout arrive sur stdout.

### 21.2 L'architecture de journalisation du nœud

#### 21.2.1 Le format CRI

Le kubelet et le runtime s'entendent sur un format de fichier normalisé par la CRI. Chaque ligne commence par trois champs séparés par une espace :

```
2026-10-23T18:40:01.102345678Z stdout F /docker-entrypoint.sh: Configuration complete; ready for start up
2026-10-23T18:40:01.141298765Z stderr F 2026/10/23 18:40:01 [notice] 1#1: nginx/1.30.6
│                              │      │ │
│                              │      │ └── le message, tel que l'application l'a écrit
│                              │      └──── étiquette : F (ligne complète) ou P (partielle)
│                              └─────────── flux d'origine : stdout ou stderr
└────────────────────────────────────────── horodatage RFC 3339 en nanosecondes, en UTC,
                                            posé par le runtime à la réception
```

L'horodatage est celui de la **réception** par le runtime, pas celui que l'application aurait pu inscrire dans son message ; c'est lui que `kubectl logs --timestamps` affiche, et c'est sur lui que reposent `--since` et `--since-time`. L'étiquette `P` sert aux lignes très longues : containerd découpe toute ligne qui dépasse `max_container_log_line_size` (16 Kio par défaut dans sa configuration CRI) en morceaux marqués `P`, le dernier étant marqué `F`. `kubectl logs` recolle les morceaux ; un agent de collecte qui lit les fichiers doit en faire autant.

#### 21.2.2 L'arborescence `/var/log/pods`

Le kubelet choisit l'emplacement du fichier et le transmet au runtime lors de la création du conteneur. La racine par défaut est `/var/log/pods` (champ `podLogsDir` de la configuration du kubelet). En dessous, un dossier par pod, un sous-dossier par conteneur, un fichier par démarrage du conteneur :

```
/var/log/pods/
└── boutique_front-7c6d9b8f5d-k2x7q_3f1e9c2a-6b7d-4e1f-9a0c-2d8e5f7a1b3c/
    │   └─ <namespace>_<nom du pod>_<UID du pod>
    └── nginx/                      ← nom du conteneur
        ├── 0.log                   ← premier démarrage (restartCount 0)
        └── 1.log                   ← après un redémarrage (restartCount 1)

/var/log/containers/
└── front-7c6d9b8f5d-k2x7q_boutique_nginx-<ID du conteneur sur 64 caractères>.log
        └─ lien symbolique vers /var/log/pods/…/nginx/1.log
```

Le nom de fichier `<N>.log` est le compteur de redémarrages du conteneur au moment de sa création. Le kubelet ne conserve qu'**un seul conteneur terminé** par conteneur du pod : quand le conteneur redémarre une deuxième fois, le fichier de l'avant-dernière instance est supprimé. C'est ce qui borne `kubectl logs --previous` à l'instance précédente, jamais aux instances plus anciennes.

Le dossier `/var/log/containers` ne contient que des liens symboliques, recréés par le kubelet à chaque démarrage de conteneur, dont le nom rassemble pod, namespace, conteneur et identifiant du conteneur. Il existe pour les agents de collecte (Fluent Bit, Vector, Promtail…) : un simple motif `/var/log/containers/*.log` leur donne tous les journaux du nœud avec les métadonnées dans le nom.

Pour un pod statique, l'UID qui figure dans le nom du dossier n'est pas tiré au hasard : le kubelet le calcule par un hachage du contenu du manifeste, du nom du nœud et de la source. **Modifier le manifeste change donc l'UID**, et les journaux du nouveau pod atterrissent dans un **nouveau dossier**. Sur le nœud control plane, cherche toujours avec un motif (`/var/log/pods/kube-system_kube-apiserver-cka_*`) et trie par date : le chapitre 23 s'en sert quand l'API ne répond plus.

> [!info] minikube ≠ examen
> Les chemins sont identiques sur un nœud kubeadm et dans les nœuds minikube : `/var/log/pods`, `/var/log/containers`, même format CRI. La seule différence est l'accès : `minikube -p cka ssh -n cka-m02` puis `sudo`, contre `ssh cka-m02` puis `sudo -i` à l'examen. Les fichiers appartiennent à root : sans `sudo`, `ls /var/log/pods/<dossier>` échoue.

#### 21.2.3 La rotation

Un conteneur bavard remplirait le disque du nœud en quelques heures. C'est le **kubelet**, pas le runtime, qui fait tourner les fichiers, selon quatre champs de sa configuration (`/var/lib/kubelet/config.yaml`) :

| Champ | Défaut | Rôle |
|---|---|---|
| `containerLogMaxSize` | `10Mi` | taille au-delà de laquelle le fichier courant est tourné |
| `containerLogMaxFiles` | `5` | nombre maximal de fichiers par conteneur, fichier courant compris (doit être supérieur à 1) |
| `containerLogMaxWorkers` | `1` | nombre de rotations menées en parallèle |
| `containerLogMonitorInterval` | `10s` | intervalle entre deux vérifications de taille |

Toutes les 10 secondes, le kubelet passe en revue les conteneurs **en cours d'exécution** (un conteneur arrêté n'écrit plus, on ne le fait pas tourner) et, pour chaque fichier courant qui dépasse la taille maximale, il procède dans cet ordre : il supprime les fichiers excédentaires les plus anciens pour n'en garder que `containerLogMaxFiles - 2` déjà tournés, compresse en gzip tous les anciens fichiers sauf le plus récent, renomme le fichier courant en `0.log.<AAAAMMJJ-hhmmss>`, puis demande au runtime, par l'appel CRI `ReopenContainerLog`, de rouvrir un `0.log` neuf. Le fichier tourné le plus récent reste non compressé pour qu'un agent de collecte puisse finir de le lire.

```
Après plusieurs rotations, avec les défauts (10Mi, 5 fichiers) :
════════════════════════════════════════════════════════════════

  0.log                              ← fichier courant, en cours d'écriture
  0.log.20261023-194215              ← dernier tourné, en clair
  0.log.20261023-194203.gz           ┐
  0.log.20261023-194151.gz           ├ anciens, compressés
  0.log.20261023-194139.gz           ┘
```

La vérification étant périodique, un conteneur très bavard peut dépasser `containerLogMaxSize` entre deux passages : la taille maximale est un seuil de déclenchement, pas une limite stricte.

> [!warning] `kubectl logs` ne lit que le fichier courant
> La documentation officielle le dit en toutes lettres : seul le contenu du dernier fichier est accessible par `kubectl logs`. Avec les défauts, un pod qui a écrit 40 Mio de journaux n'en montre au plus qu'une dizaine. Les lignes qui précèdent la dernière rotation ne se lisent plus que sur le nœud, dans les fichiers tournés (`zcat` pour les `.gz`). C'est une question classique : « pourquoi `kubectl logs` ne remonte-t-il pas jusqu'au démarrage ? »

Ni kubeadm ni minikube ne surchargent ces quatre champs dans la configuration qu'ils écrivent : vérifie-le avec `sudo grep -i containerlog /var/lib/kubelet/config.yaml` ; une sortie vide signifie que les défauts s'appliquent. Pour les modifier, on édite ce fichier sur chaque nœud (ou la ConfigMap `kube-system/kubelet-config` avant un `kubeadm upgrade node`) puis on redémarre le kubelet.

### 21.3 `kubectl logs` en détail

#### 21.3.1 Ce que fait la commande

`kubectl logs` lit la sous-ressource `log` du pod : `GET /api/v1/namespaces/<ns>/pods/<pod>/log?container=…&follow=…`. Il faut donc, en RBAC, le verbe `get` sur `pods/log` (c'est ce que le Role `developpeur` du chapitre 16 accorde). L'API server relaie la requête au kubelet du nœud sur le port 10250, qui ouvre le fichier et renvoie son contenu. Quand le kubelet ne répond pas, l'erreur le dit sans ambiguïté :

```
Error from server: Get "https://192.168.49.4:10250/containerLogs/boutique/redis-0/redis": dial tcp 192.168.49.4:10250: connect: connection refused
```

Quand le conteneur n'a pas encore démarré, il n'y a pas de fichier, et le kubelet renvoie un message qui résume déjà le diagnostic :

```
Error from server (BadRequest): container "nginx" in pod "front-6f8d7c5b9-p4z2m" is waiting to start: trying and failing to pull image
```

Les variantes de ce message sont fixées dans le code du kubelet : `image can't be pulled` pour `ErrImagePull`, `trying and failing to pull image` pour `ImagePullBackOff`, la raison brute pour les autres attentes (`ContainerCreating`, `CreateContainerConfigError`…), et `previous terminated container "x" in pod "y" not found` quand tu demandes `--previous` alors qu'il n'y a pas eu de redémarrage.

#### 21.3.2 Toutes les options

| Option | Défaut | Effet |
|---|---|---|
| `-c, --container NOM` | conteneur par défaut | choisit le conteneur, y compris un init container ou un conteneur éphémère |
| `--all-containers` | `false` | tous les conteneurs du pod (init compris), les uns après les autres |
| `-p, --previous` | `false` | l'instance précédente du conteneur, si elle existe |
| `-f, --follow` | `false` | suit le fichier en continu, comme `tail -f` |
| `--since=DURÉE` | tout | lignes plus récentes que la durée (`5s`, `2m`, `3h`) |
| `--since-time=DATE` | tout | lignes postérieures à une date RFC 3339 ; exclusif avec `--since` |
| `--tail=N` | `-1` sans sélecteur, `10` avec `-l` | les N dernières lignes |
| `--timestamps` | `false` | préfixe chaque ligne par l'horodatage CRI |
| `--prefix` | `false` | préfixe chaque ligne par `[pod/<pod>/<conteneur>] ` |
| `--limit-bytes=N` | `0` (pas de limite) | coupe la sortie après N octets |
| `-l, --selector` | — | tous les pods qui portent ces labels |
| `--max-log-requests=N` | `5` | nombre maximal de flux suivis en même temps avec `-l` et `-f` |
| `--all-pods` | `false` | avec `TYPE/NOM`, tous les pods de l'objet au lieu d'un seul (active `--prefix`) |
| `--pod-running-timeout` | `20s` | attente d'un pod en cours d'exécution, avec `TYPE/NOM` |
| `--ignore-errors` | `false` | avec `-f`, ne s'arrête pas sur l'erreur d'un des flux |
| `--insecure-skip-tls-verify-backend` | `false` | n'authentifie pas le certificat de service du kubelet (expiré, par exemple) |

Quelques comportements méritent d'être connus précisément.

**Choix du conteneur.** Un pod à un seul conteneur n'exige pas `-c`. Avec plusieurs conteneurs et sans `-c`, kubectl prend celui que désigne l'annotation `kubectl.kubernetes.io/default-container` s'il y en a une, sinon le premier conteneur de la liste, et il l'annonce sur la sortie d'erreur :

```
Defaulted container "compteur" out of: compteur, fragile
```

Les init containers ne sont jamais choisis par défaut : `-c <nom-de-l-init>` ou `--all-containers`.

**`--tail` et les sélecteurs.** Avec `-l`, la valeur par défaut tombe à 10 lignes par pod : `kubectl logs -l app=front` n'est donc pas l'équivalent de trois `kubectl logs` complets. Passe `--tail=-1` pour tout avoir.

**`-f` et `-l`.** Suivre plus de 5 flux à la fois est refusé avant même de commencer :

```
error: you are attempting to follow 6 log streams, but maximum allowed concurrency is 5, use --max-log-requests to increase the limit
```

Le compte porte sur les flux, c'est-à-dire pods × conteneurs avec `--all-containers`.

**`TYPE/NOM`.** `kubectl logs deployment/api`, `job/migration`, `statefulset/redis`, `daemonset/agent-noeud` ou `service/front` résolvent l'objet en la liste de ses pods, puis en choisissent **un seul**, selon un ordre fixé dans le code de kubectl : un pod placé sur un nœud avant un pod non placé, puis `Running` avant `Unknown` avant `Pending`, puis prêt avant non prêt, puis prêt depuis le plus longtemps, puis le plus de redémarrages, puis le plus ancien.

> [!danger] Le piège de `deploy/…` pendant un rollout bloqué
> Pendant une mise à jour qui échoue, les anciens pods sont `Running` et prêts, les nouveaux ne le sont pas. `kubectl logs deploy/api` choisit donc un **ancien** pod sain et t'affiche des journaux parfaitement normaux. Pour lire le pod qui casse, nomme-le (`kubectl get pods -l app=api` puis `kubectl logs <pod>`) ou passe `--all-pods`.

**`--previous` et les redémarrages.** Quand un conteneur redémarre en boucle, l'instance courante vient souvent de démarrer et n'a encore rien écrit, ou elle est en attente (`CrashLoopBackOff`) et n'a pas de fichier courant. Le message utile est presque toujours dans l'instance précédente : `kubectl logs <pod> -p`. Pour un conteneur sorti à cause d'une erreur de configuration, la dernière ligne suffit souvent : `kubectl logs <pod> -p --tail=5`.

#### 21.3.3 Un exemple complet sur le fil rouge

```bash
kubectl -n boutique logs deploy/front --tail=3 --timestamps
```

```
2026-10-23T18:40:01.141298765Z 2026/10/23 18:40:01 [notice] 1#1: start worker processes
2026-10-23T18:40:01.141887654Z 2026/10/23 18:40:01 [notice] 1#1: start worker process 30
2026-10-23T18:40:01.142012345Z 2026/10/23 18:40:01 [notice] 1#1: start worker process 31
```

Les messages `[notice]` de nginx arrivent par stderr, les lignes du script d'entrée de l'image par stdout ; `kubectl logs` ne distingue pas les deux, seul le fichier CRI garde la trace du flux. Les requêtes des sondes de disponibilité de `front` apparaissent aussi dans ce journal, avec l'agent utilisateur `kube-probe/1.37` : un pod dont le journal ne montre plus aucun `kube-probe` n'est plus sondé, ou ses sondes n'arrivent plus jusqu'à lui.

### 21.4 Les journaux des composants

#### 21.4.1 Deux familles de composants

Les composants de Kubernetes se rangent en deux familles, et le chemin de leurs journaux en découle.

| Composant | Où il tourne | Où sont ses journaux | Comment les lire |
|---|---|---|---|
| kubelet | service systemd | journald | `journalctl -u kubelet` |
| containerd | service systemd | journald | `journalctl -u containerd` |
| kube-apiserver, kube-controller-manager, kube-scheduler, etcd | pods statiques | `/var/log/pods/kube-system_<composant>-<nœud>_<uid>/` | `kubectl -n kube-system logs <pod>` ; sans API : `crictl logs` ou le fichier |
| kube-proxy, CoreDNS, CNI (calico-node…) | DaemonSet ou Deployment | `/var/log/pods/kube-system_…` | `kubectl -n kube-system logs` ; sans API : `crictl logs` |

Le kubelet et le runtime ne peuvent pas tourner dans des pods : ce sont eux qui créent les pods. Ils sont donc lancés par systemd et écrivent dans le journal système. Tout le reste est un conteneur, dont les journaux suivent le chemin de 21.2.

#### 21.4.2 `journalctl`

```bash
minikube -p cka ssh -n cka-m02
sudo journalctl -u kubelet --no-pager -n 50          # 50 dernières lignes
sudo journalctl -u kubelet -f                        # suivi en direct
sudo journalctl -u kubelet --since "10 min ago"      # fenêtre de temps
sudo journalctl -u kubelet -b --no-pager | grep -iE 'error|failed' | tail -20
sudo journalctl -u containerd --no-pager -n 20
```

`-u` filtre par unité, `-n` limite le nombre de lignes, `-f` suit, `--since`/`--until` bornent dans le temps (formats `"2026-10-23 18:00"`, `"10 min ago"`, `today`), `-b` se limite au démarrage courant, `--no-pager` évite le pager quand tu rediriges vers `grep`, `-x` ajoute des explications aux messages de systemd et `-e` saute à la fin. La combinaison `journalctl -xeu kubelet` est le réflexe après un échec de démarrage.

Les composants Kubernetes écrivent au format **klog**. Chaque ligne commence par un en-tête fixe :

```
E1023 18:52:07.418254    1382 run.go:72] "command failed" err="failed to construct kubelet dependencies: …"
│└──┘ └─────────────┘    └──┘ └───────┘ └────────────────────────────────────────────────────────────
│ │         │              │      │       message structuré : texte entre guillemets, puis clé="valeur"
│ │         │              │      └────── fichier source et ligne
│ │         │              └───────────── PID (ou identifiant de thread)
│ │         └──────────────────────────── heure, à la microseconde
│ └────────────────────────────────────── mois et jour (MMJJ)
└──────────────────────────────────────── sévérité : I (info), W (warning), E (error), F (fatal)
```

Trier par sévérité devient alors trivial : `grep '^E'` dans un fichier de pod statique, `grep ' E[0-9]\{4\} '` dans la sortie de `journalctl`, qui ajoute son propre préfixe (date, nom d'hôte, unité) devant l'en-tête klog. La verbosité se règle par l'option `-v` (ou `--v`) de chaque composant ; pour le kubelet, par le champ `logging.verbosity` de sa configuration. Au-delà de 4, les journaux deviennent volumineux : à réserver à une investigation courte.

#### 21.4.3 `crictl`

`crictl` parle directement au runtime par la CRI, sans passer par l'API server : c'est l'outil des situations où l'API est tombée. Sa configuration, `/etc/crictl.yaml`, pointe sur le socket de containerd.

```bash
sudo crictl ps                                   # conteneurs en cours d'exécution
sudo crictl ps -a                                # y compris les conteneurs terminés
sudo crictl ps -a --name kube-apiserver          # filtre sur le nom du conteneur
sudo crictl ps -a --name kube-apiserver -q       # identifiants seulement
sudo crictl pods --namespace kube-system         # sandboxes de pods
sudo crictl logs <id>                            # journal d'un conteneur
sudo crictl logs --tail 20 <id>
sudo crictl logs -f <id>
sudo crictl logs -p <id>                         # instance précédente
sudo crictl inspect <id>                         # détail JSON (état, code de sortie, montages)
```

```
CONTAINER       IMAGE           CREATED          STATE     NAME                      ATTEMPT   POD ID          POD                                NAMESPACE
a3c91f0d2e7b4   e5b1c2a9f8d7c   12 minutes ago   Running   calico-node               0         7d2e9a1c4b3f5   calico-node-hw89l                  kube-system
91be04d7c6a28   c1f7d3e8b2a96   12 minutes ago   Running   kube-proxy                0         0f6a8c2d9e1b7   kube-proxy-jpwgc                   kube-system
```

Les colonnes de `crictl ps` (version 1.35) sont `CONTAINER`, `IMAGE`, `CREATED`, `STATE`, `NAME`, `ATTEMPT`, `POD ID`, `POD` et `NAMESPACE`. `ATTEMPT` est le compteur de redémarrages du conteneur : une valeur qui grimpe d'un `crictl ps -a` à l'autre signale une boucle de redémarrage, même quand l'API ne permet plus de voir `CrashLoopBackOff`.

> [!info] minikube ≠ examen
> Dans les nœuds minikube, `crictl` exige `sudo` : sans lui, la commande échoue sur `connect: permission denied` vers `/run/containerd/containerd.sock`. Sur les hôtes de l'examen, tu passes root par `sudo -i` dès la connexion et la question ne se pose pas. Le reste (`journalctl -u kubelet`, `crictl ps -a`, `crictl logs`) se tape à l'identique.

#### 21.4.4 Lire les journaux d'un nœud par l'API

Le kubelet expose, sur son port 10250, un point d'accès `/logs/` que l'API server relaie par la sous-ressource `nodes/proxy`. Avec la configuration par défaut (`enableSystemLogHandler: true`), il sert le contenu de `/var/log` du nœud en lecture :

```bash
kubectl get --raw "/api/v1/nodes/cka-m02/proxy/logs/"           # liste de /var/log
kubectl get --raw "/api/v1/nodes/cka-m02/proxy/logs/pods/"      # les dossiers de pods
```

La fonction **Node log query**, stable depuis la 1.36 (feature gate `NodeLogQuery` verrouillée à vrai), va plus loin : `?query=kubelet` interroge journald sur le nœud, avec les paramètres `pattern` (expression régulière), `sinceTime`, `untilTime`, `tailLines` et `boot`. Elle n'est active que si le champ `enableSystemLogQuery` de la configuration du kubelet vaut `true` ; son défaut est `false`, et ni kubeadm ni minikube ne le changent. (La page « System Logs » de la documentation 1.37 affirme que `enableSystemLogHandler` suffit et qu'il vaut `false` par défaut ; la référence de configuration du kubelet et le code de la 1.37.1 disent l'inverse, et ce sont eux qui font foi.)

```bash
kubectl get --raw "/api/v1/nodes/cka-m02/proxy/logs/?query=kubelet&tailLines=5"
kubectl get --raw "/api/v1/nodes/cka-m02/proxy/logs/?query=kubelet&pattern=error"
```

> [!warning] `nodes/proxy` est un droit puissant
> Le verbe `get` sur `nodes/proxy` ouvre toute l'API du kubelet, y compris l'exécution de commandes dans les conteneurs du nœud. Ne l'accorde jamais pour « lire des journaux » : c'est un droit d'administrateur.

### 21.5 Les événements

#### 21.5.1 Ce qu'est un événement

Un événement est un objet de l'API (`Event`, dans le groupe core `v1` et dans `events.k8s.io/v1`) qu'un composant crée pour signaler quelque chose qui est arrivé à un autre objet : le scheduler a placé un pod, le kubelet n'a pas pu tirer une image, le contrôleur de ReplicaSet n'a pas pu créer un pod, le contrôleur des nœuds a déclaré un nœud injoignable. Ses champs principaux :

| Champ (core/v1) | Champ (events.k8s.io/v1) | Contenu |
|---|---|---|
| `involvedObject` | `regarding` | l'objet concerné (kind, name, namespace, uid) |
| `reason` | `reason` | un mot en CamelCase : `FailedScheduling`, `BackOff`, `Unhealthy`… |
| `message` | `note` | la phrase lisible, souvent la seule information utile |
| `type` | `type` | `Normal` ou `Warning` |
| `source.component` | `reportingController` | qui l'a émis : `kubelet`, `default-scheduler`, `replicaset-controller`… |
| `count`, `firstTimestamp`, `lastTimestamp` | `series`, `eventTime` | répétitions et dates |

Les événements sont **namespacés** : ils vivent dans le namespace de l'objet concerné. Ceux qui portent sur un objet sans namespace, un nœud par exemple, sont rangés dans le namespace `default`. `kubectl events --for node/cka-m03` lancé depuis le contexte `boutique` ne trouve donc rien : il faut `-n default` ou `-A`.

Ils sont **éphémères**. L'API server les écrit dans etcd avec un bail d'une durée fixée par son option `--event-ttl`, **une heure** par défaut. Passé ce délai, ils disparaissent. Un incident de la nuit ne laisse donc aucun événement le matin : il faudrait les avoir exportés (agent de collecte, `kubectl get events -w` redirigé). Pour vérifier la valeur d'un cluster kubeadm : `sudo grep event-ttl /etc/kubernetes/manifests/kube-apiserver.yaml` ; aucune ligne signifie le défaut.

Ils sont **agrégés**. Quand un composant émet plusieurs fois le même événement sur le même objet, la bibliothèque client met à jour l'objet existant (compteur `count` et `lastTimestamp`) au lieu d'en créer un nouveau. `kubectl describe` l'affiche sous la forme `(x12 over 5m)`. Quand dix événements semblables mais de messages différents arrivent en dix minutes, ils sont regroupés sous un message préfixé par `(combined from similar events):`. Un débit excessif est en outre limité à la source : un événement attendu peut manquer sur un objet très sollicité.

#### 21.5.2 Trois façons de les lire

```bash
kubectl -n boutique events                                    # triés chronologiquement
kubectl -n boutique events --types=Warning                    # seulement les avertissements
kubectl -n boutique events --for pod/redis-0                  # ceux d'un objet
kubectl -n boutique events --for deployment/front -w          # puis suivre les nouveaux
kubectl events -A --types=Warning                             # tout le cluster
```

```
LAST SEEN   TYPE      REASON      OBJECT                       MESSAGE
4m12s       Normal    Scheduled   Pod/bavard                   Successfully assigned boutique/bavard to cka-m02
4m11s       Normal    Pulled      Pod/bavard                   Container image "busybox:1.37.0" already present on machine
3m40s       Warning   BackOff     Pod/bavard                   Back-off restarting failed container fragile in pod bavard_boutique(8c2f…)
```

`kubectl events`, stable depuis la 1.28, est l'outil à privilégier : il **trie** les événements par date (en prenant `eventTime` quand `lastTimestamp` est vide, ce qui arrive pour les événements émis par l'API `events.k8s.io/v1`, comme ceux du scheduler), il filtre par objet avec `--for TYPE/NOM`, par type avec `--types` (`Normal`, `Warning`), et il suit avec `-w`. Ses colonnes sont `LAST SEEN`, `TYPE`, `REASON`, `OBJECT`, `MESSAGE`, plus `NAMESPACE` avec `-A`.

`kubectl get events` existe toujours, mais ne trie pas : il faut `--sort-by=.metadata.creationTimestamp` (ou `.lastTimestamp`, en sachant que les événements sans `lastTimestamp` se retrouvent alors en tête). On filtre par sélecteur de champ : `--field-selector type=Warning`, `--field-selector involvedObject.name=redis-0`, `--field-selector reason=FailedScheduling`.

`kubectl describe <objet>` affiche en bas les événements de l'objet. Depuis la 1.36, il ne le fait par défaut que lorsqu'il décrit **un seul** objet ; pour une liste ou un préfixe de nom, ajoute `--show-events=true`.

#### 21.5.3 Les raisons à connaître

| Raison | Émetteur | Signification |
|---|---|---|
| `Scheduled` / `FailedScheduling` | scheduler | pod placé / impossible à placer (message `0/3 nodes are available: …`) |
| `Pulling`, `Pulled` | kubelet | tirage d'image en cours, réussi |
| `Failed` | kubelet | échec de tirage ou de création du conteneur (`Error: ErrImagePull`, `Error: couldn't find key …`) |
| `BackOff` | kubelet | attente avant nouvel essai (`Back-off pulling image`, `Back-off restarting failed container`) |
| `Created`, `Started`, `Killing` | kubelet | cycle de vie du conteneur |
| `Unhealthy` | kubelet | sonde en échec (`Readiness probe failed: …`) |
| `FailedMount`, `FailedAttachVolume` | kubelet, attach-detach | volume impossible à monter ou attacher |
| `FailedCreatePodSandBox` | kubelet | sandbox impossible à créer, le plus souvent une erreur du plugin CNI |
| `SuccessfulCreate`, `FailedCreate` | contrôleurs (ReplicaSet, Job, StatefulSet…) | pod créé / création refusée par l'admission (quota, LimitRange, Pod Security) |
| `ScalingReplicaSet` | contrôleur de Deployment | un ReplicaSet monte ou descend |
| `NodeNotReady`, `NodeReady` | contrôleur des nœuds, kubelet | changement d'état d'un nœud (namespace `default`) |
| `TaintManagerEviction` | contrôleur d'éviction par taint | pod marqué pour suppression sur un nœud tainté `NoExecute` |
| `SuccessfulRescale`, `FailedGetResourceMetric` | HPA | mise à l'échelle, métriques indisponibles |
| `ProvisioningSucceeded`, `ProvisioningFailed`, `WaitForFirstConsumer` | contrôleurs de volumes | provisionnement d'un PV |

> [!tip] Réflexe d'examen
> Face à un objet qui « ne marche pas », la première commande est `kubectl -n <ns> events --for <type>/<nom>` ou un `describe`, la seconde `kubectl logs`. Un pod qui n'a jamais démarré n'a pas de journaux, mais il a toujours des événements, à condition qu'un composant ait essayé de faire quelque chose. L'absence totale d'événement est elle-même un indice : un pod `Pending` sans `FailedScheduling`, c'est un scheduler absent (chapitre 23).

### 21.6 Les métriques de ressources

#### 21.6.1 Le pipeline

Kubernetes ne garde aucun historique de consommation. Ce que montrent `kubectl top` et ce qu'utilise l'HPA (chapitre 7) vient d'un pipeline court et sans mémoire :

```
Pipeline des métriques de ressources
════════════════════════════════════

  noyau (cgroups) ──▶ runtime (stats CRI) ──▶ kubelet  /metrics/resource  (port 10250)
                                                  ▲
                                                  │ interrogé toutes les --metric-resolution
                                                  │
                                           metrics-server (Deployment, kube-system)
                                                  │ garde en mémoire le DERNIER relevé
                                                  ▼
                       APIService v1beta1.metrics.k8s.io ──▶ kube-apiserver (agrégation)
                                                  │
                         ┌────────────────────────┼─────────────────────┐
                         ▼                        ▼                     ▼
                    kubectl top           HorizontalPodAutoscaler     VPA
```

metrics-server n'est pas un composant du control plane mais une extension, enregistrée auprès de l'API server par un objet `APIService`. Il interroge chaque kubelet, conserve le dernier point et le sert par l'API `metrics.k8s.io`. Pas de base de séries temporelles, pas de graphe : pour cela, il faut Prometheus, hors programme.

Le CPU est rapporté comme une **moyenne** sur une fenêtre (champ `window` de la réponse), calculée à partir d'un compteur cumulé du noyau, en cœurs ou millicœurs (`110m` = 0,11 cœur). La mémoire est le **working set** à l'instant du relevé : la mémoire anonyme du conteneur plus la partie du cache de fichiers que le noyau ne peut pas libérer. C'est la grandeur que surveille aussi le kubelet pour ses évictions ; la limite mémoire du conteneur, elle, est appliquée par le noyau sur l'ensemble de la consommation du cgroup.

> [!note] `metrics.k8s.io/v1` et `v1beta1`
> Kubernetes 1.37 a promu l'API `metrics.k8s.io/v1`, identique à `v1beta1`. Mais metrics-server v0.9.0, celui de l'addon minikube et la version courante, ne sert que `v1beta1`. kubectl 1.37 essaie `v1` puis retombe sur `v1beta1`, et l'HPA n'utilise que `v1beta1`. Pour interroger l'API à la main dans le lab, écris donc `v1beta1` : les exemples en `v1` de la documentation renvoient une erreur 404 tant que metrics-server ne sert pas cette version.

```bash
kubectl get apiservice v1beta1.metrics.k8s.io                      # AVAILABLE doit valoir True
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes/cka-m02
kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/boutique/pods/redis-0
```

#### 21.6.2 `kubectl top`

```bash
kubectl top node                                    # tous les nœuds
kubectl top node --sort-by=memory                   # triés : cpu ou memory
kubectl top node --show-capacity                    # % rapportés à la capacité, pas à l'allocatable
kubectl -n boutique top pod                         # pods d'un namespace
kubectl top pod -A --sort-by=cpu                    # tout le cluster, du plus gros au plus petit
kubectl -n boutique top pod --containers            # détail par conteneur
kubectl -n boutique top pod -l app=front --sum      # sous-ensemble et total
kubectl -n boutique top pod redis-0 --containers
```

| Option | `top node` | `top pod` | Effet |
|---|---|---|---|
| `--sort-by=cpu\|memory` | oui | oui | tri décroissant |
| `-l, --selector` | oui | oui | filtre par labels |
| `--no-headers` | oui | oui | pour les scripts |
| `--show-capacity` | oui | — | pourcentages par rapport à `capacity` au lieu d'`allocatable` |
| `--containers` | — | oui | une ligne par conteneur (colonnes `POD`, `NAME`, `CPU(cores)`, `MEMORY(bytes)`) |
| `--sum` | — | oui | ligne de total |
| `-A`, `--field-selector` | — | oui | tous les namespaces, sélection par champ |
| `--show-swap` | oui | oui | consommation de swap, si le nœud en a |

Les erreurs courantes sont parlantes : `error: Metrics API not available` quand metrics-server ne répond pas (pas installé, pas encore prêt, APIService indisponible) ; `error: Metrics not available for pod …` pour un pod trop récent, dont le premier relevé n'a pas encore eu lieu.

> [!tip] Réflexe d'examen
> La tâche type est « trouve le pod qui consomme le plus de CPU parmi ceux qui portent le label X et écris son nom dans un fichier ». La réponse tient en une ligne : `kubectl top pod -l X --sort-by=cpu --no-headers | head -1 | awk '{print $1}' > fichier`. Attention au namespace (`-n` ou `-A`) et au fichier exact demandé.

> [!info] minikube ≠ examen
> Dans le lab, metrics-server est l'addon minikube (v0.9.0) avec `--metric-resolution=60s` et `--kubelet-insecure-tls` : `kubectl top` ne répond qu'environ une minute après l'activation ou après un `minikube start`, et les valeurs changent au plus une fois par minute. Surtout, chaque nœud annonce la **capacité de l'hôte** (8 CPU et 32 Gio sur le poste du relevé) : les pourcentages de `kubectl top node` sont minuscules (`1081Mi` = 3 %) et ne disent rien de la mémoire réellement disponible dans le conteneur nœud. Sur un cluster d'examen, metrics-server est en général déjà installé, et la capacité est celle de la machine virtuelle.

#### 21.6.3 Consommation n'est pas réservation

`kubectl top` mesure ce que les conteneurs **consomment**. Le scheduler, lui, raisonne uniquement sur ce qu'ils **réservent** : la somme des `requests` des pods déjà placés, comparée à l'`allocatable` du nœud. Un nœud peut donc refuser un pod (`Insufficient cpu`) alors que `kubectl top node` le montre presque oisif, parce que ses pods réservent beaucoup et consomment peu. À l'inverse, un nœud dont les pods n'ont pas de `requests` peut être saturé sans que le scheduler s'en soucie. La réservation se lit dans `kubectl describe node`.

### 21.7 Le bilan d'un nœud : `kubectl describe node`

`kubectl describe node cka-m02` assemble l'état d'un nœud en sections, dans cet ordre : labels, annotations et taints ; `Lease` (le bail de vie du kubelet, voir chapitre 23) ; `Conditions` ; `Addresses` ; `Capacity` et `Allocatable` ; `System Info` (versions du noyau, du runtime, du kubelet) ; `PodCIDR` ; `Non-terminated Pods` ; `Allocated resources` ; `Events`.

```
Conditions:
  Type                 Status  LastHeartbeatTime                 LastTransitionTime                Reason                       Message
  ----                 ------  -----------------                 ------------------                ------                       -------
  NetworkUnavailable   False   Fri, 23 Oct 2026 20:17:01 +0200   Fri, 23 Oct 2026 20:17:01 +0200   CalicoIsUp                   Calico is running on this node
  MemoryPressure       False   Fri, 23 Oct 2026 21:02:44 +0200   Fri, 23 Oct 2026 20:16:29 +0200   KubeletHasSufficientMemory   kubelet has sufficient memory available
  DiskPressure         False   Fri, 23 Oct 2026 21:02:44 +0200   Fri, 23 Oct 2026 20:16:29 +0200   KubeletHasNoDiskPressure     kubelet has no disk pressure
  PIDPressure          False   Fri, 23 Oct 2026 21:02:44 +0200   Fri, 23 Oct 2026 20:16:29 +0200   KubeletHasSufficientPID      kubelet has sufficient PID available
  Ready                True    Fri, 23 Oct 2026 21:02:44 +0200   Fri, 23 Oct 2026 20:17:05 +0200   KubeletReady                 kubelet is posting ready status
```

Les quatre conditions du kubelet (`MemoryPressure`, `DiskPressure`, `PIDPressure`, `Ready`) sont saines quand les trois premières valent `False` et la dernière `True`. `NetworkUnavailable` est posée par le CNI (ici Calico, raison `CalicoIsUp`). `LastHeartbeatTime` est la date du dernier calcul du kubelet ; `LastTransitionTime`, celle du dernier changement de valeur. Le chapitre 23 détaille ce que chaque combinaison signifie.

```
Capacity:
  cpu:                8
  ephemeral-storage:  490048472Ki
  memory:             32019572Ki
  pods:               110
Allocatable:
  cpu:                8
  ephemeral-storage:  490048472Ki
  memory:             32019572Ki
  pods:               110
…
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests     Limits
  --------           --------     ------
  cpu                600m (7%)    1500m (18%)
  memory             416Mi (1%)   864Mi (2%)
  ephemeral-storage  0 (0%)       0 (0%)
  hugepages-1Gi      0 (0%)       0 (0%)
  hugepages-2Mi      0 (0%)       0 (0%)
```

`Capacity` est ce que le nœud possède ; `Allocatable` ce qu'il offre aux pods, soit la capacité moins `kubeReserved`, `systemReserved` et le seuil d'éviction dur. Le tableau `Non-terminated Pods` liste chaque pod du nœud avec ses `requests` et `limits` CPU et mémoire en valeur et en pourcentage de l'allocatable ; `Allocated resources` en fait la somme. La colonne `Requests` est exactement ce que le scheduler compare à l'allocatable : à 100 %, plus aucun pod qui réserve cette ressource ne peut y être placé. La colonne `Limits` peut dépasser 100 % : c'est la surréservation (overcommit), légale, qui se paie par des OOM ou de l'étranglement CPU quand tout le monde consomme en même temps.

> [!info] minikube ≠ examen
> Les trois nœuds du lab annoncent la même capacité, celle de l'hôte, et un `Allocatable` égal à la capacité (minikube ne réserve rien). Les pourcentages d'`Allocated resources` y sont donc faibles quel que soit le nombre de pods. Sur un nœud kubeadm d'examen, `Allocatable` est un peu inférieur à `Capacity` (au minimum le seuil d'éviction `memory.available` de 100 Mio).

Pour un relevé synthétique de tous les nœuds, sans `describe`, une requête `custom-columns` suffit (chapitre 3) :

```bash
kubectl get nodes -o custom-columns='NOM:.metadata.name,CPU:.status.allocatable.cpu,MEMOIRE:.status.allocatable.memory,PRET:.status.conditions[?(@.type=="Ready")].status'
```

### 21.8 Pièges courants

```
Piège 1 : Chercher dans kubectl logs ce que l'application écrit dans un fichier
══════════════════════════════════════════════════════════════════════════════
  MAUVAIS  : kubectl logs mon-pod     (l'application écrit dans /var/log/app.log)
  SYMPTÔME : sortie vide, alors que l'application « journalise ».
  BON      : kubectl exec mon-pod -- tail /var/log/app.log, ou un sidecar
             qui recopie le fichier sur stdout.

Piège 2 : kubectl logs deploy/… pendant un rollout en échec
═══════════════════════════════════════════════════════════
  MAUVAIS  : kubectl -n boutique logs deploy/api   (le nouveau pod casse)
  SYMPTÔME : journaux d'un ANCIEN pod sain, rien d'anormal.
  BON      : kubectl -n boutique get pods -l app=api, puis logs <pod-en-échec> -p.

Piège 3 : Oublier --previous sur un conteneur qui redémarre
═══════════════════════════════════════════════════════════
  SYMPTÔME : journal vide, ou « is waiting to start: CrashLoopBackOff ».
  BON      : kubectl logs <pod> -p  — la cause est dans l'instance précédente.

Piège 4 : Croire que kubectl logs remonte au démarrage du conteneur
═══════════════════════════════════════════════════════════════════
  CAUSE    : seul le fichier courant est lu ; la rotation a lieu à 10Mi.
  BON      : lire les fichiers tournés sur le nœud (/var/log/pods/…, zcat *.gz).

Piège 5 : Chercher les événements d'un nœud dans le mauvais namespace
═════════════════════════════════════════════════════════════════════
  MAUVAIS  : kubectl -n boutique events --for node/cka-m03
  SYMPTÔME : « No events found in boutique namespace. »
  BON      : kubectl -n default events --for node/cka-m03   (ou -A).

Piège 6 : Chercher les événements d'un incident vieux de plus d'une heure
═════════════════════════════════════════════════════════════════════════
  CAUSE    : --event-ttl vaut 1h par défaut ; les événements ont expiré.
  BON      : se fier aux journaux, aux status des objets, ou exporter les
             événements en continu.

Piège 7 : Comparer kubectl top et les requests
══════════════════════════════════════════════
  MAUVAIS  : « le nœud est à 5 % de CPU, le pod devrait passer »
  SYMPTÔME : FailedScheduling : Insufficient cpu.
  BON      : kubectl describe node → Allocated resources → Requests.

Piège 8 : crictl sans sudo dans un nœud minikube
═════════════════════════════════════════════════
  SYMPTÔME : connect: permission denied sur containerd.sock.
  BON      : sudo crictl …  (à l'examen : sudo -i dès la connexion).
```

> [!summary] À retenir
> - Les journaux d'un conteneur sont ses seuls stdout et stderr, écrits par le runtime au format CRI (`horodatage flux F|P message`) dans `/var/log/pods/<ns>_<pod>_<uid>/<conteneur>/<N>.log`, avec des liens dans `/var/log/containers`.
> - `kubectl logs` passe par l'API server puis par le kubelet (port 10250) et lit le fichier courant seulement ; le kubelet garde une seule instance terminée (`-p`).
> - Rotation par le kubelet : `containerLogMaxSize` 10Mi, `containerLogMaxFiles` 5, contrôle toutes les 10 s ; fichiers tournés horodatés puis compressés.
> - Options clés de `kubectl logs` : `-c`, `-p`, `-f`, `--since`/`--since-time`, `--tail` (10 par défaut avec `-l`), `--timestamps`, `--all-containers`, `--prefix`, `--max-log-requests` (5) ; `deploy/…` ne lit qu'un pod, choisi parmi les sains.
> - kubelet et containerd écrivent dans journald (`journalctl -u kubelet`) ; les composants du control plane sont des pods statiques : `kubectl logs`, ou `crictl logs` et `/var/log/pods` quand l'API est tombée.
> - Les événements sont namespacés (ceux des nœuds dans `default`), agrégés, et expirent après `--event-ttl` (1 h) ; `kubectl events` les trie et filtre (`--for`, `--types`, `-w`).
> - metrics-server garde un seul relevé par objet ; `kubectl top` donne le CPU moyen et le working set mémoire ; metrics-server v0.9.0 sert `metrics.k8s.io/v1beta1`.
> - Le scheduler raisonne sur les `requests` (`describe node` → `Allocated resources`), pas sur la consommation de `kubectl top`.

### 21.9 Exercices

Ces exercices ne laissent rien de durable : les objets temporaires sont supprimés à la fin de chacun. Range tes réponses écrites dans `~/cka/journaux/` (`mkdir -p ~/cka/journaux`).

#### Exercice 21.1 — Retrouver un journal sur le disque

**Point de départ** : instantané I4 (état laissé par le chapitre 20).

Dans le namespace `boutique`, choisis le pod `front` le plus ancien. Sans utiliser `kubectl logs`, affiche les deux dernières lignes **brutes** de son journal telles qu'elles sont stockées sur le nœud, puis écris dans `~/cka/journaux/chemin-front.txt` le chemin complet du fichier courant de son conteneur `nginx`. Vérifie enfin que le lien correspondant existe dans `/var/log/containers`.

> [!example]- Solution
> ```bash
> mkdir -p ~/cka/journaux
> POD=$(kubectl -n boutique get pods -l app=front --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[0].metadata.name}')
> NOEUD=$(kubectl -n boutique get pod $POD -o jsonpath='{.spec.nodeName}')
> UID_POD=$(kubectl -n boutique get pod $POD -o jsonpath='{.metadata.uid}')
> N=$(kubectl -n boutique get pod $POD -o jsonpath='{.status.containerStatuses[?(@.name=="nginx")].restartCount}')
> echo "/var/log/pods/boutique_${POD}_${UID_POD}/nginx/${N}.log" | tee ~/cka/journaux/chemin-front.txt
> minikube -p cka ssh -n $NOEUD -- sudo tail -n 2 "$(cat ~/cka/journaux/chemin-front.txt)"
> minikube -p cka ssh -n $NOEUD -- "sudo ls -l /var/log/containers/ | grep ${POD}_boutique_nginx"
> ```
>
> Le chemin se construit entièrement à partir de l'API : namespace, nom et UID du pod, nom du conteneur, compteur de redémarrages. Les lignes brutes commencent par l'horodatage RFC 3339, le flux et l'étiquette `F` :
>
> ```
> 2026-10-23T19:12:21.203977412Z stdout F … - - [23/Oct/2026:19:12:21 +0000] "GET / HTTP/1.1" 200 … "-" "kube-probe/1.37" "-"
> 2026-10-23T19:12:31.204518873Z stdout F … - - [23/Oct/2026:19:12:31 +0000] "GET / HTTP/1.1" 200 … "-" "kube-probe/1.37" "-"
> ```
>
> La sonde de disponibilité de `front` interroge `/` toutes les 10 secondes : les dernières lignes sont presque toujours ses requêtes, écrites par nginx sur stdout (le journal d'accès de l'image est un lien vers `/dev/stdout`). Les messages de démarrage de nginx, plus haut dans le fichier, sont marqués `stderr`. Le lien de `/var/log/containers` porte le nom `<pod>_boutique_nginx-<id>.log` et pointe vers ce même fichier.
>
> **Vérification** : `minikube -p cka ssh -n $NOEUD -- sudo test -f "$(cat ~/cka/journaux/chemin-front.txt)" && echo présent` affiche `présent`.

#### Exercice 21.2 — Un pod à deux conteneurs

**Point de départ** : exercice 21.1.

Crée dans `boutique` le pod `bavard` ci-dessous (labels `app=bavard`, `tier=outils`), dont le conteneur `compteur` écrit une ligne toutes les 2 secondes et dont le conteneur `fragile` écrit sur ses deux flux puis sort en erreur au bout de 15 secondes. Attends au moins une minute, puis : affiche les journaux sans préciser de conteneur et note quel conteneur kubectl choisit ; affiche les 3 dernières lignes de chaque conteneur avec leur préfixe en une seule commande ; affiche le journal de l'instance précédente de `fragile` ; affiche les lignes de `compteur` des 10 dernières secondes avec leur horodatage. Ne supprime pas `bavard` : l'exercice suivant s'en sert.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: bavard
  namespace: boutique
  labels:
    app: bavard
    tier: outils
spec:
  containers:
  - name: compteur
    image: busybox:1.37.0
    command: ["sh", "-c", "i=0; while true; do echo \"compteur $i\"; i=$((i+1)); sleep 2; done"]
  - name: fragile
    image: busybox:1.37.0
    command: ["sh", "-c", "echo \"fragile demarre a $(date +%T)\"; echo 'fragile: erreur fatale' >&2; sleep 15; exit 3"]
```

> [!example]- Solution
> ```bash
> mkdir -p ~/cka/journaux
> # enregistre le manifeste ci-dessus dans ~/cka/journaux/bavard.yaml, puis :
> kubectl -n boutique apply -f ~/cka/journaux/bavard.yaml
> sleep 60
> kubectl -n boutique logs bavard | tail -2
> kubectl -n boutique logs bavard --all-containers --prefix --tail=3
> kubectl -n boutique logs bavard -c fragile -p
> kubectl -n boutique logs bavard -c compteur --since=10s --timestamps
> ```
>
> Sans `-c`, kubectl prend le premier conteneur de la liste et l'annonce sur stderr : `Defaulted container "compteur" out of: compteur, fragile`. Avec `--all-containers --prefix`, chaque ligne est préfixée par `[pod/bavard/compteur]` ou `[pod/bavard/fragile]`. Le journal de l'instance précédente de `fragile` contient ses deux lignes, stdout et stderr mêlés dans l'ordre d'arrivée :
>
> ```
> fragile demarre a 18:51:12
> fragile: erreur fatale
> ```
>
> Les ressources du pod ne sont pas déclarées : la LimitRange `boutique-limites` du chapitre 8 leur donne leurs valeurs par défaut, ce qui satisfait aussi le quota. Le pod respecte le niveau `baseline` de Pod Security ; l'avertissement `would violate PodSecurity "restricted:latest"` affiché à la création vient du label `warn=restricted` du namespace et n'empêche rien.
>
> **Vérification** : `kubectl -n boutique get pod bavard -o jsonpath='{.status.containerStatuses[?(@.name=="fragile")].lastState.terminated.exitCode}'` affiche `3`.

#### Exercice 21.3 — Lire les événements

**Point de départ** : exercice 21.2.

Affiche, triés par date, les seuls événements `Warning` du namespace `boutique`, puis ceux qui concernent le pod `bavard`. Écris dans `~/cka/journaux/raisons-bavard.txt` la liste des raisons distinctes des événements de `bavard`, une par ligne. Affiche ensuite les événements des nœuds du cluster. Détermine enfin, en lisant le manifeste de l'API server, combien de temps ces événements seront conservés. Supprime `bavard` pour finir.

> [!example]- Solution
> ```bash
> kubectl -n boutique events --types=Warning
> kubectl -n boutique events --for pod/bavard
> kubectl -n boutique get events --field-selector involvedObject.name=bavard \
>   -o jsonpath='{range .items[*]}{.reason}{"\n"}{end}' | sort -u > ~/cka/journaux/raisons-bavard.txt
> cat ~/cka/journaux/raisons-bavard.txt
> kubectl -n default events --for node/cka-m02
> kubectl events -A --types=Warning | grep -i node
> minikube -p cka ssh -- sudo grep -c event-ttl /etc/kubernetes/manifests/kube-apiserver.yaml
> kubectl -n boutique delete pod bavard
> ```
>
> Le fichier contient au moins `BackOff`, `Created`, `Pulled`, `Scheduled` et `Started` (et `Killing` si un conteneur a été tué). `BackOff` porte le message `Back-off restarting failed container fragile in pod bavard_boutique(…)`. Les événements des nœuds sont dans le namespace `default`, pas dans `boutique`. Le `grep -c` renvoie `0` : l'option `--event-ttl` n'est pas posée, la valeur par défaut d'une heure s'applique.
>
> **Vérification** : `grep -c . ~/cka/journaux/raisons-bavard.txt` affiche un nombre supérieur ou égal à 5, et `kubectl -n boutique get pod bavard` répond `NotFound`.

#### Exercice 21.4 — Consommation et réservation

**Point de départ** : exercice 21.3.

Vérifie que l'API de métriques est disponible. Écris dans `~/cka/journaux/pod-gourmand.txt` le nom du pod du namespace `boutique` qui consomme le plus de mémoire. Affiche la consommation par conteneur de `redis-0`. Lis ensuite la consommation brute du nœud `cka-m02` directement dans l'API `metrics.k8s.io`. Enfin, compare pour le nœud `cka` ce qu'affiche `kubectl top node` avec la colonne `Requests` d'`Allocated resources`, et explique l'écart.

> [!example]- Solution
> ```bash
> kubectl get apiservice v1beta1.metrics.k8s.io
> kubectl -n boutique top pod --sort-by=memory --no-headers | head -1 | awk '{print $1}' > ~/cka/journaux/pod-gourmand.txt
> cat ~/cka/journaux/pod-gourmand.txt
> kubectl -n boutique top pod redis-0 --containers
> kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes/cka-m02
> kubectl top node cka
> kubectl describe node cka | grep -A 8 'Allocated resources'
> ```
>
> La colonne `AVAILABLE` de l'APIService doit valoir `True` ; sinon, `kubectl top` répond `error: Metrics API not available`. La réponse brute est un objet `NodeMetrics` avec `timestamp`, `window` et `usage.cpu` en nanocœurs (`45123456n`), `usage.memory` en Kio. L'écart entre `top node` et `Allocated resources` est normal : la première commande mesure la consommation instantanée de tous les processus du nœud, y compris ceux qui n'ont pas de `requests` (le control plane, en partie) ; la seconde additionne les seules réservations déclarées, qui sont ce que le scheduler voit. Sous minikube, les deux pourcentages sont faibles parce que le dénominateur est la capacité de l'hôte.
>
> **Vérification** : `kubectl -n boutique get pod "$(cat ~/cka/journaux/pod-gourmand.txt)"` trouve le pod.

#### Exercice 21.5 — Les journaux du kubelet et de containerd

**Point de départ** : exercice 21.4.

Sur le nœud `cka-m02` : affiche les 20 dernières lignes du journal du kubelet ; compte les lignes de sévérité erreur émises depuis le démarrage du nœud ; affiche la ligne de commande avec laquelle systemd lance le kubelet ; liste avec `crictl` le conteneur `calico-node` du nœud et affiche ses 5 dernières lignes de journal. Compare enfin avec `kubectl logs` pour le même conteneur.

> [!example]- Solution
> ```bash
> minikube -p cka ssh -n cka-m02
> sudo journalctl -u kubelet --no-pager -n 20
> sudo journalctl -u kubelet -b --no-pager | grep -c ' E[0-9]\{4\} '
> systemctl cat kubelet | grep '^ExecStart=/'
> sudo crictl ps --name calico-node
> sudo crictl logs --tail 5 $(sudo crictl ps --name calico-node -q)
> exit
> kubectl -n kube-system logs $(kubectl -n kube-system get pods -l k8s-app=calico-node --field-selector spec.nodeName=cka-m02 -o name) -c calico-node --tail=5
> ```
>
> Le motif `' E[0-9]\{4\} '` repère l'en-tête klog d'une erreur (`E1023 …`) derrière le préfixe de journald. `systemctl cat` montre l'unité et son drop-in `10-kubeadm.conf` ; la ligne `ExecStart=/var/lib/minikube/binaries/v1.37.0/kubelet --bootstrap-kubeconfig=… --config=/var/lib/kubelet/config.yaml --hostname-override=cka-m02 --kubeconfig=/etc/kubernetes/kubelet.conf --node-ip=192.168.49.3` contient toutes les options en dur (sur un nœud kubeadm, elles viendraient de variables lues dans `/var/lib/kubelet/kubeadm-flags.env`). Les deux lectures du journal de `calico-node` donnent les mêmes lignes : `crictl logs` lit le même fichier que le kubelet, sans passer par l'API.
>
> **Vérification** : `minikube -p cka ssh -n cka-m02 -- systemctl is-active kubelet` affiche `active`.

#### Exercice 21.6 — Voir la rotation à l'œuvre

**Point de départ** : exercice 21.5.

Crée dans `boutique` le pod `torrent` (busybox 1.37.0, labels `app=torrent` et `tier=outils`) dont l'unique conteneur `torrent` écrit sans pause la même ligne sur sa sortie standard. Au bout d'une minute, liste les fichiers de son dossier de journaux sur son nœud et identifie le fichier courant, le dernier fichier tourné et les fichiers compressés. Mesure la taille de ce que renvoie `kubectl logs` et compare-la à la somme des fichiers. Supprime le pod et vérifie que son dossier a disparu.

> [!example]- Solution
> ```bash
> kubectl -n boutique run torrent --image=busybox:1.37.0 --labels=app=torrent,tier=outils \
>   --command -- sh -c 'while true; do echo "torrent: une ligne de journal volontairement longue pour remplir vite le fichier courant"; done'
> sleep 60
> NOEUD=$(kubectl -n boutique get pod torrent -o jsonpath='{.spec.nodeName}')
> minikube -p cka ssh -n $NOEUD -- 'sudo ls -l /var/log/pods/boutique_torrent_*/torrent/'
> kubectl -n boutique logs torrent | wc -c
> minikube -p cka ssh -n $NOEUD -- 'sudo du -cb /var/log/pods/boutique_torrent_*/torrent/* | tail -1'
> kubectl -n boutique delete pod torrent --grace-period=0
> minikube -p cka ssh -n $NOEUD -- 'sudo ls -d /var/log/pods/boutique_torrent_* 2>&1'
> ```
>
> `kubectl run` sans `--restart` crée un pod nu ; `--command --` remplace la commande de l'image. La LimitRange du namespace plafonne le conteneur à 200m de CPU, ce qui ralentit la boucle sans l'empêcher de produire plusieurs mégaoctets par seconde. La liste ressemble à :
>
> ```
> -rw-r----- 1 root root  6815744 Oct 23 19:42 0.log
> -rw-r----- 1 root root 11010048 Oct 23 19:42 0.log.20261023-194215
> -rw-r----- 1 root root   917504 Oct 23 19:42 0.log.20261023-194203.gz
> -rw-r----- 1 root root   921088 Oct 23 19:42 0.log.20261023-194151.gz
> -rw-r----- 1 root root   915712 Oct 23 19:41 0.log.20261023-194139.gz
> ```
>
> Cinq fichiers au plus : le courant, le dernier tourné en clair (qui peut dépasser 10 Mio, la taille n'étant vérifiée que toutes les 10 secondes), et des archives gzip une dizaine de fois plus petites (le message se répète, mais chaque ligne porte un horodatage différent). `kubectl logs | wc -c` renvoie moins que le seul `0.log` (le préfixe CRI est retiré) et beaucoup moins que la somme : seul le fichier courant est lu. Après la suppression, le kubelet efface le dossier du pod.
>
> **Vérification** : la dernière commande répond `No such file or directory`.

#### Exercice 21.7 — Interroger le journal d'un nœud par l'API

**Point de départ** : exercice 21.6.

Sans te connecter au nœud, liste le contenu de `/var/log` de `cka-m02` par l'API. Active ensuite sur ce seul nœud la fonction de requête des journaux, obtiens par l'API les 5 dernières lignes du journal du kubelet de `cka-m02`, puis remets la configuration du kubelet dans son état d'origine.

> [!example]- Solution
> ```bash
> kubectl get --raw "/api/v1/nodes/cka-m02/proxy/logs/"
> minikube -p cka ssh -n cka-m02
> sudo cp /var/lib/kubelet/config.yaml /root/config.yaml.orig
> echo 'enableSystemLogQuery: true' | sudo tee -a /var/lib/kubelet/config.yaml
> sudo systemctl restart kubelet
> exit
> kubectl wait --for=condition=Ready node/cka-m02 --timeout=60s
> kubectl get --raw "/api/v1/nodes/cka-m02/proxy/logs/?query=kubelet&tailLines=5"
> minikube -p cka ssh -n cka-m02 -- 'sudo cp /root/config.yaml.orig /var/lib/kubelet/config.yaml && sudo systemctl restart kubelet'
> ```
>
> La première requête fonctionne sans rien changer : `enableSystemLogHandler` vaut `true` par défaut et le kubelet sert `/var/log` en liste HTML (`containers/`, `pods/`, `journal/`…). La requête `?query=kubelet` exige en plus `enableSystemLogQuery: true` ; sans lui, le paramètre est ignoré ou refusé. Le champ est ajouté en fin de fichier, au premier niveau du document `KubeletConfiguration`. La sauvegarde est faite hors de tout dossier surveillé et la configuration d'origine est restaurée à la fin : le chapitre 23 apprend à diagnostiquer un kubelet dont la configuration est fausse.
>
> **Vérification** : `minikube -p cka ssh -n cka-m02 -- sudo grep -c enableSystemLogQuery /var/lib/kubelet/config.yaml` affiche `0` et `kubectl get node cka-m02` montre `Ready`.

---
