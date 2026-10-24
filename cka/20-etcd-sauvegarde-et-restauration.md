---
title: "CKA — 20. etcd : sauvegarde et restauration"
description: "Le rôle d'etcd, Raft et le quorum, etcdctl et etcdutl 3.7, la sauvegarde et la restauration d'etcd sur minikube et sur un cluster kubeadm, et le piège du cache de watch."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 20. etcd : sauvegarde et restauration

etcd est la seule mémoire du cluster : chaque objet que tu as créé depuis le chapitre 3, du namespace `boutique` à la release Helm `vitrine`, n'existe que sous la forme d'une clé dans etcd. Ce chapitre explique ce qu'etcd stocke et comment, pourquoi il lui faut une majorité de membres pour fonctionner, comment l'interroger avec `etcdctl`, puis comment le sauvegarder et le restaurer avec les outils d'etcd 3.7, qui ont changé de répartition depuis etcd 3.6. Le programme v1.37 ne nomme plus la sauvegarde d'etcd, mais elle relève de *Manage the lifecycle of Kubernetes clusters* (domaine *Cluster Architecture, Installation and Configuration*, 25 %), et une panne d'etcd relève de *Troubleshoot cluster components* (30 %). C'est l'une des tâches les plus constantes de l'examen : une sauvegarde à poser à un chemin donné, souvent suivie d'une restauration. Elle se réussit en cinq minutes si l'on connaît l'emplacement des certificats, les deux outils et le piège du cache de l'apiserver ; elle se rate à coup sûr sinon.

> [!warning] Ce que l'examen autorise
> La documentation d'etcd (`etcd.io`) **n'est pas** autorisée au CKA. Ta référence pendant l'épreuve est la page « Operating etcd clusters for Kubernetes » de kubernetes.io et l'aide des commandes (`etcdutl snapshot restore --help`). Les options `--bump-revision` et `--mark-compacted`, qui ne figurent pas sur cette page, sont donc à connaître par cœur.

### 20.1 Ce qu'etcd stocke pour Kubernetes

#### 20.1.1 Un magasin clé-valeur versionné

etcd est un magasin clé-valeur distribué. Seul **kube-apiserver** lui parle : le scheduler, le controller-manager, les kubelets et `kubectl` passent tous par l'apiserver (chapitre 2). Chaque objet est rangé sous une clé de la forme `/registry/<ressource>/<namespace>/<nom>` (préfixe réglable par `--etcd-prefix`, `/registry` par défaut) ; les ressources de groupe nommé issues d'une CRD prennent la forme `/registry/<groupe>/<ressource>/<namespace>/<nom>`.

```
Quelques clés du cluster du cours (instantané I4) :
═══════════════════════════════════════════════════

  /registry/namespaces/boutique
  /registry/deployments/boutique/front
  /registry/services/specs/boutique/api          ← les Services sont sous "specs"
  /registry/configmaps/boutique/front-html
  /registry/secrets/boutique/api-secret
  /registry/boutique.example/sauvegardes/boutique/redis-quotidienne   ← CRD du chapitre 18
  /registry/apiextensions.k8s.io/customresourcedefinitions/sauvegardes.boutique.example
  /registry/leases/kube-node-lease/cka-m02       ← battement de cœur des nœuds
```

Les valeurs des types intégrés sont encodées en **protobuf**, précédées de la signature `k8s\0` ; celles des ressources de CRD le sont en JSON. Un Secret y figure **tel que l'apiserver l'a écrit** : en clair (le base64 n'est qu'un encodage du manifeste, pas du stockage), sauf si le chiffrement au repos est configuré, auquel cas la valeur commence par `k8s:enc:` (chapitre 6). Une sauvegarde d'etcd contient donc tous les secrets du cluster : elle se protège comme eux.

etcd est **versionné** (MVCC). Un compteur global, la **révision**, augmente de un à chaque écriture, quelle que soit la clé ; chaque clé retient la révision de sa création et de sa dernière modification. Le `resourceVersion` que tu vois dans `metadata` est cette révision de modification. C'est elle qui permet le **watch** : un client demande « tout ce qui a changé depuis la révision N », et etcd lui envoie la suite. Les anciennes révisions s'accumulent jusqu'à ce qu'on les **compacte** : kube-apiserver demande un compactage toutes les 5 minutes (`--etcd-compaction-interval`, 5m0s par défaut). Le compactage libère l'historique, pas l'espace disque : il faut ensuite une **défragmentation** pour rendre la place au système de fichiers (20.10.4).

#### 20.1.2 L'apiserver et son cache de watch

L'apiserver ne relit pas etcd à chaque requête. Pour chaque type de ressource, il entretient un **cache de watch** : il liste les objets une fois, puis suit les changements par un watch etcd, et sert les listes et les watches de ses clients depuis ce cache. Une lecture d'objet par son nom (`kubectl get cm temoin`) va jusqu'à etcd ; une liste (`kubectl get cm`) est servie par le cache, après vérification que le cache a atteint la révision courante d'etcd. Les contrôleurs (*informers*) font de même de leur côté : ils gardent une copie locale et la tiennent à jour par watch, à partir de la dernière révision vue.

Tout cela suppose que la révision ne recule jamais. Une restauration la fait reculer. C'est l'origine du piège central de ce chapitre (20.7.2).

#### 20.1.3 La version d'etcd en 1.37

kubeadm 1.37 déploie **etcd 3.7.0** (image `registry.k8s.io/etcd:3.7.0-0`, compilée avec Go 1.26.5) ; kubeadm 1.36 déployait 3.6.8, ce qui explique le saut vu au chapitre 19.6.3. L'image est *distroless* : elle contient `/usr/local/bin/etcd`, `etcdctl` et `etcdutl`, mais ni shell, ni `ls`, ni `tar`. `kubectl exec` peut y lancer un de ces binaires, jamais `sh`.

```bash
kubectl -n kube-system exec etcd-cka -- etcd --version
kubectl -n kube-system exec etcd-cka -- etcdctl version
kubectl -n kube-system exec etcd-cka -- sh -c 'ls'
```

```
etcd Version: 3.7.0
Git SHA: 4d71f7c
Go Version: go1.26.5
Go OS/Arch: linux/amd64
etcdctl version: 3.7.0
API version: 3.7
error: Internal error occurred: … exec: "sh": executable file not found in $PATH
```

etcd 3.7 a aussi supprimé les options `--experimental-*` dépréciées et le démarrage à partir de l'ancien magasin v2 : un manifeste etcd recopié d'un vieux tutoriel peut ne plus démarrer.

### 20.2 Raft et le quorum

#### 20.2.1 Un leader, des suiveurs, une majorité

Les membres d'un cluster etcd se mettent d'accord par l'algorithme **Raft**. À tout instant, un seul membre est **leader** ; les autres sont **suiveurs**. Le leader reçoit toutes les écritures, les ajoute à son journal, les réplique, et ne les déclare **validées** (*committed*) qu'une fois qu'une **majorité** de membres les a écrites sur disque. Il envoie un battement de cœur toutes les 100 ms (`--heartbeat-interval`) ; un suiveur qui n'en reçoit plus pendant le délai d'élection, 1000 ms par défaut (`--election-timeout`), se porte candidat, incrémente le **terme** (*raft term*) et demande les votes. Celui qui obtient la majorité devient leader du nouveau terme.

```
Écriture validée dans un cluster de trois membres :
═══════════════════════════════════════════════════

  apiserver ── PUT ──▶ leader (cp1) ─┬─ ajoute au journal (1/3)
                                     ├─▶ cp2 : écrit, acquitte (2/3) ── MAJORITÉ ──▶ validé
                                     └─▶ cp3 : en retard ou mort  (rattrapera plus tard)

  Lecture linéarisable (défaut) : passe par le leader, qui confirme qu'il
  l'est toujours auprès d'une majorité (ReadIndex) avant de répondre.
  Lecture sérialisable (--consistency=s) : servie par le membre interrogé,
  éventuellement en retard, mais disponible même sans quorum.
```

La majorité s'appelle le **quorum** : ⌊N/2⌋ + 1 membres.

| Membres | Quorum | Pannes tolérées | Commentaire |
|---|---|---|---|
| 1 | 1 | 0 | lab, examen |
| 2 | 2 | 0 | **pire** qu'un seul membre : deux points de panne, aucune tolérance |
| 3 | 2 | 1 | minimum de la haute disponibilité |
| 4 | 3 | 1 | n'apporte rien sur 3, ralentit les écritures |
| 5 | 3 | 2 | recommandé par kubernetes.io pour la production |

D'où la règle : **toujours un nombre impair** de membres. Ajouter des membres augmente la disponibilité, pas les performances : chaque écriture doit atteindre plus de disques.

#### 20.2.2 Les learners

Un membre ajouté par `etcdctl member add --learner` est un **learner** : il reçoit le journal mais ne vote pas et ne compte pas dans le quorum. Une fois rattrapé, on le promeut (`etcdctl member promote <ID>`). Cela évite qu'un membre neuf, encore vide, fasse passer un cluster de 3 à 4 membres votants (quorum 3) au moment où il est le plus fragile. `kubeadm join --control-plane` procède toujours ainsi en 1.37 (chapitre 19.4.3) ; la colonne `IS LEARNER` de `member list` le montre.

#### 20.2.3 Ce que voit Kubernetes quand etcd perd le quorum

Sans quorum, etcd refuse les écritures et les lectures linéarisables. L'apiserver ne peut plus rien servir de cohérent : `kubectl` échoue ou expire, les contrôleurs s'arrêtent, rien ne se planifie. Les pods déjà lancés **continuent de tourner** : les kubelets n'ont pas besoin de l'API pour maintenir l'existant, ils ne peuvent seulement plus rien recevoir ni publier. Perdre un membre sur trois ne se voit pas ; en perdre deux arrête le cluster ; tout perdre impose une restauration.

| Situation | Effet | Remède |
|---|---|---|
| 1 membre sur 3 en panne, récupérable | aucun, quorum à 2 | réparer et redémarrer le membre |
| 1 membre sur 3 perdu définitivement | aucun, mais plus de marge | `member remove`, puis nouveau membre (20.10.3) |
| 2 membres sur 3 perdus | plus de quorum, API figée | restauration depuis un instantané (20.10.1) |
| Données effacées par erreur (namespace supprimé…) | quorum intact, données fausses | restauration du cluster entier (20.8, 20.9) |

### 20.3 etcdctl et etcdutl en 3.7

#### 20.3.1 Deux outils, deux rôles

Depuis etcd 3.6, le travail est partagé entre deux binaires. **`etcdctl`** est un client réseau : il parle à un serveur etcd **vivant**, par son point d'accès (`--endpoints`), avec les certificats TLS. **`etcdutl`** travaille **hors ligne**, sur des fichiers : un instantané ou un dossier de données, sans serveur.

| Besoin | Outil | Commande |
|---|---|---|
| Santé, statut, membres | etcdctl | `endpoint health`, `endpoint status`, `member list` |
| Lire des clés | etcdctl | `get <clé> [--prefix] [--keys-only]` |
| **Prendre** un instantané | etcdctl | `snapshot save <fichier>` |
| **Examiner** un instantané | **etcdutl** | `snapshot status <fichier>` |
| **Restaurer** un instantané | **etcdutl** | `snapshot restore <fichier> --data-dir <dossier>` |
| Gérer les membres | etcdctl | `member add/remove/update/promote` |
| Alarmes, compactage, défragmentation en ligne | etcdctl | `alarm list/disarm`, `compaction`, `defrag` |
| Défragmentation hors ligne | etcdutl | `defrag --data-dir <dossier>` |

`etcdctl snapshot` n'a plus qu'une sous-commande, `save` : **`etcdctl snapshot restore` et `etcdctl snapshot status` ont été supprimées en etcd 3.6.0**. Les lancer avec l'etcdctl 3.7 de kubeadm 1.37 échoue.

> [!warning] La page etcd de kubernetes.io est en retard
> La page « Operating etcd clusters for Kubernetes » (v1.37) présente la restauration et le statut dans deux onglets, « Use etcdutl » et « Use etcdctl (Deprecated) », et dit encore de ce dernier qu'il est « slated for removal from etcd v3.6 ». Il **est** supprimé depuis la 3.6.0. Paradoxe utile : la seule mention de la modification du `hostPath` du manifeste etcd figure dans cet onglet obsolète. Lis-le pour la méthode, jamais pour la commande.

#### 20.3.2 Les options globales et l'environnement

`ETCDCTL_API=3`, qu'on trouve partout, ne sert plus à rien : etcdctl ne connaît plus que l'API v3, et etcdctl 3.7 signale la variable par un avertissement (`"msg":"unrecognized environment variable","environment-variable":"ETCDCTL_API=3"`) avant de réussir quand même. Les options globales (`--endpoints`, `--cacert`, `--cert`, `--key`, `--write-out`…) sont **masquées** dans `etcdctl --help` depuis la 3.7 : `etcdctl options` les liste. Sans `--endpoints`, etcdctl vise `127.0.0.1:2379` : une adresse sans schéma, qu'il contacte en TLS si on lui a donné des certificats, en clair sinon (ce qui échoue sur l'etcd de kubeadm) ; écrire `--endpoints=https://127.0.0.1:2379` lève toute ambiguïté. Le délai de connexion par défaut est de 2 s (`--dial-timeout`), celui d'une commande de 5 s (`--command-timeout`). Le format de sortie se choisit par `-w` (`--write-out`) : `simple` (défaut), `table`, `json`, `fields`, `protobuf`.

Chaque option globale a sa variable d'environnement, préfixée par `ETCDCTL_` : `ETCDCTL_ENDPOINTS`, `ETCDCTL_CACERT`, `ETCDCTL_CERT`, `ETCDCTL_KEY`. Les clés étant lisibles par root seul, le plus simple est de passer root (`sudo -i`) puis d'exporter ; `sudo etcdctl` derrière un `export` fait en utilisateur ordinaire **perd** les variables, puisque sudo réinitialise l'environnement.

```bash
sudo -i
export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379 \
       ETCDCTL_CACERT=/etc/kubernetes/pki/etcd/ca.crt \
       ETCDCTL_CERT=/etc/kubernetes/pki/etcd/server.crt \
       ETCDCTL_KEY=/etc/kubernetes/pki/etcd/server.key
etcdctl member list
```

#### 20.3.3 Installer les outils

Sur un cluster d'examen, `etcdctl` et `etcdutl` sont en général déjà sur le control plane (`which etcdctl etcdutl`). Dans le lab, ils ne sont **pas** sur les nœuds : seule l'image etcd les contient. Deux méthodes, testées sur le nœud `cka`.

**Méthode 1, archive officielle d'etcd-io.** Le nœud a `curl`, `tar`, `sha256sum` et accès à Internet. On télécharge la même version que le serveur, et on vérifie la somme de contrôle publiée.

```bash
minikube -p cka ssh
# dans le nœud cka
cd /tmp
ETCD_VER=v3.7.0
curl -fsSLO https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz
curl -fsSLO https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/SHA256SUMS
grep linux-amd64.tar.gz SHA256SUMS | sha256sum -c -
tar xzf etcd-${ETCD_VER}-linux-amd64.tar.gz
sudo install -m 0755 etcd-${ETCD_VER}-linux-amd64/etcdctl etcd-${ETCD_VER}-linux-amd64/etcdutl /usr/local/bin/
```

```
etcd-v3.7.0-linux-amd64.tar.gz: OK
```

**Méthode 2, hors ligne, depuis le conteneur etcd en cours d'exécution.** Le système de fichiers d'un conteneur lancé par containerd est visible sur l'hôte sous `/run/containerd/io.containerd.runtime.v2.task/k8s.io/<id>/rootfs`. C'est aussi la méthode de secours à l'examen, si `etcdutl` manque sur le nœud.

```bash
# dans le nœud cka
CID=$(sudo crictl ps --name etcd -q)
sudo ls /run/containerd/io.containerd.runtime.v2.task/k8s.io/$CID/rootfs/usr/local/bin/
sudo cp /run/containerd/io.containerd.runtime.v2.task/k8s.io/$CID/rootfs/usr/local/bin/etcd{ctl,utl} /usr/local/bin/
```

```
etcd  etcdctl  etcdutl
```

Le `/tmp` du nœud est un tmpfs, perdu à l'arrêt ; `/usr/local/bin` est sur le disque du conteneur : les binaires y **survivent** à `minikube -p cka stop` puis `start`, pas à `minikube delete` ni à `lab/restaurer.sh`.

> [!info] minikube ≠ examen
> | | Cluster kubeadm (examen) | Lab minikube |
> |---|---|---|
> | Outils | `etcdctl` et `etcdutl` en général installés | absents des nœuds, à installer (20.3.3) |
> | Certificats etcd | `/etc/kubernetes/pki/etcd/` | `/var/lib/minikube/certs/etcd/` |
> | Client etcd de l'apiserver | `/etc/kubernetes/pki/apiserver-etcd-client.{crt,key}` | `/var/lib/minikube/certs/apiserver-etcd-client.{crt,key}` |
> | Données | `/var/lib/etcd` | `/var/lib/minikube/etcd` |
> | Manifeste | `/etc/kubernetes/manifests/etcd.yaml` | identique |
> | Point d'accès client | `https://127.0.0.1:2379` | identique (et `https://192.168.49.2:2379`) |
> | Accès au nœud | `ssh <nœud>` puis `sudo -i` | `minikube -p cka ssh`, utilisateur `docker`, `sudo` |

### 20.4 Trouver le point d'accès et les certificats

L'énoncé d'examen donne parfois les chemins ; souvent il dit seulement « etcd tourne sur ce nœud ». Ils se lisent dans deux manifestes. Côté **serveur**, `etcd.yaml` donne le certificat présenté par etcd et la CA qu'il exige de ses clients ; côté **client**, `kube-apiserver.yaml` donne le certificat avec lequel l'apiserver lui parle.

```bash
# dans le nœud cka
sudo grep -E -- '--(listen-client-urls|advertise-client-urls|cert-file|key-file|trusted-ca-file|data-dir)' \
  /etc/kubernetes/manifests/etcd.yaml
sudo grep -E -- '--etcd-' /etc/kubernetes/manifests/kube-apiserver.yaml
```

```
    - --advertise-client-urls=https://192.168.49.2:2379
    - --cert-file=/var/lib/minikube/certs/etcd/server.crt
    - --data-dir=/var/lib/minikube/etcd
    - --key-file=/var/lib/minikube/certs/etcd/server.key
    - --listen-client-urls=https://127.0.0.1:2379,https://192.168.49.2:2379
    - --trusted-ca-file=/var/lib/minikube/certs/etcd/ca.crt
    - --etcd-cafile=/var/lib/minikube/certs/etcd/ca.crt
    - --etcd-certfile=/var/lib/minikube/certs/apiserver-etcd-client.crt
    - --etcd-keyfile=/var/lib/minikube/certs/apiserver-etcd-client.key
    - --etcd-servers=https://127.0.0.1:2379
```

Trois paires certificat/clé, toutes signées par la CA d'etcd, conviennent comme client, parce qu'elles portent l'usage *client authentication* : `etcd/server.crt` (usages serveur **et** client, c'est celui qu'emploient la plupart des corrigés), `etcd/healthcheck-client.crt` (client seul) et `apiserver-etcd-client.crt` (client seul, rangé à la racine du dossier des certificats). La CA à passer en `--cacert` est **toujours** `etcd/ca.crt`, jamais la CA Kubernetes `ca.crt` : les trois PKI de kubeadm ne se font pas confiance mutuellement (chapitre 19.7.1).

Un contrôle sans certificat existe : etcd expose `/livez` et `/readyz` en HTTP simple sur le port des métriques (`--listen-metrics-urls=http://127.0.0.1:2381`), que les sondes du kubelet utilisent. `curl -s http://127.0.0.1:2381/readyz` répond `ok` sur le nœud.

### 20.5 Interroger etcd

Toutes les commandes de cette section se lancent en root dans le nœud `cka`, avec les variables d'environnement de 20.3.2 adaptées au lab :

```bash
minikube -p cka ssh
# dans le nœud cka
sudo -i
export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379 \
       ETCDCTL_CACERT=/var/lib/minikube/certs/etcd/ca.crt \
       ETCDCTL_CERT=/var/lib/minikube/certs/etcd/server.crt \
       ETCDCTL_KEY=/var/lib/minikube/certs/etcd/server.key
```

**La santé.** `endpoint health` écrit une clé de test par le consensus et mesure le temps : un membre sain qui a perdu le quorum répond « unhealthy ».

```bash
etcdctl endpoint health
etcdctl endpoint health --cluster        # tous les membres, d'après member list
```

```
https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 9.316484ms
```

**Le statut.** `endpoint status` donne, par membre : l'identifiant, la version du serveur et du stockage, la taille de la base et la part réellement utilisée, le quota, s'il est leader ou learner, le terme et l'index Raft, et les erreurs (dont les alarmes). En `-w table`, la sortie a seize colonnes ; le format `simple` les sépare par des virgules dans le même ordre (`ENDPOINT, ID, VERSION, STORAGE VERSION, DB SIZE, IN USE, PERCENTAGE NOT IN USE, QUOTA, IS LEADER, IS LEARNER, RAFT TERM, RAFT INDEX, RAFT APPLIED INDEX, ERRORS, DOWNGRADE TARGET VERSION, DOWNGRADE ENABLED`).

```bash
etcdctl endpoint status
```

```
https://127.0.0.1:2379, aec36adc501070cc, 3.7.0, 3.7.0, 9.8 MB, 5.1 MB, 48%, 2.1 GB, true, false, 3, 41352, 41352, , , false
```

Le quota de 2.1 GB est la valeur par défaut d'etcd (`--quota-backend-bytes`, 2 Gio ; 8 Gio au plus recommandés). La part « not in use » est l'espace qu'une défragmentation rendrait.

**Les membres.**

```bash
etcdctl member list
etcdctl member list -w table
```

```
aec36adc501070cc, started, cka, https://192.168.49.2:2380, https://192.168.49.2:2379, false
┌──────────────────┬─────────┬──────┬───────────────────────────┬───────────────────────────┬────────────┐
│        ID        │ STATUS  │ NAME │        PEER ADDRS         │       CLIENT ADDRS        │ IS LEARNER │
├──────────────────┼─────────┼──────┼───────────────────────────┼───────────────────────────┼────────────┤
│ aec36adc501070cc │ started │  cka │ https://192.168.49.2:2380 │ https://192.168.49.2:2379 │      false │
└──────────────────┴─────────┴──────┴───────────────────────────┴───────────────────────────┴────────────┘
```

L'identifiant d'un membre initial est dérivé de ses URL de pair et du jeton du cluster : le nœud `cka`, à l'adresse 192.168.49.2, retrouve donc `aec36adc501070cc` à chaque recréation du lab.

**Les clés.** `get` lit une clé ; avec `--prefix`, toutes les clés qui commencent par ce texte ; avec `--keys-only`, sans les valeurs. En format `simple`, etcdctl imprime chaque clé suivie de sa valeur sur une ligne à part, vide avec `--keys-only` : les lignes vides alternent avec les clés.

```bash
etcdctl get /registry/deployments/boutique/ --prefix --keys-only
etcdctl get /registry/deployments/boutique --prefix --keys-only | grep -v '^$'
etcdctl get /registry/namespaces/demo --print-value-only | od -An -c -N 8
etcdctl get /registry --prefix --keys-only | grep -c .
```

```
/registry/deployments/boutique/api

/registry/deployments/boutique/front

/registry/deployments/boutique/front-v2

/registry/deployments/boutique-recette/front
/registry/deployments/boutique/api
/registry/deployments/boutique/front
/registry/deployments/boutique/front-v2
   k   8   s  \0  \n 017  \n 002
```

La deuxième commande montre le piège du préfixe : sans la barre finale, `/registry/deployments/boutique` couvre aussi le namespace `boutique-recette` du chapitre 17. Les premiers octets d'une valeur, `k8s\0`, signent l'encodage protobuf de Kubernetes ; la dernière commande compte les clés. `--count-only` existe aussi, mais n'accepte que `-w fields`.

### 20.6 Sauvegarder

#### 20.6.1 `etcdctl snapshot save`

```bash
minikube -p cka ssh
# dans le nœud cka
sudo mkdir -p /var/lib/minikube/backup
sudo etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/minikube/certs/etcd/ca.crt \
  --cert=/var/lib/minikube/certs/etcd/server.crt \
  --key=/var/lib/minikube/certs/etcd/server.key \
  snapshot save /var/lib/minikube/backup/etcd-snap.db
```

```
{"level":"info",…,"msg":"fetched snapshot","endpoint":"https://127.0.0.1:2379","size":"3.9 MB","took":"21.736689ms","etcd-version":"3.7.0"}
Snapshot saved at /var/lib/minikube/backup/etcd-snap.db
Server version 3.7.0
```

Le serveur envoie une copie **cohérente** de sa base (le fichier bbolt), figée à une révision donnée, sans s'arrêter ni ralentir les clients de façon notable. etcdctl l'écrit d'abord dans `<fichier>.part`, ajoute à la fin une **empreinte SHA-256** qui servira à vérifier l'intégrité à la restauration, puis renomme le fichier : un fichier sans `.part` est complet. Quatre détails comptent à l'examen.

**Un seul point d'accès.** Avec plusieurs `--endpoints`, la commande refuse : `snapshot must be requested to one selected node, not multiple`. Sur un cluster HA, on sauvegarde un membre, en général le local.

**Le dossier doit exister.** `snapshot save` ne crée pas les dossiers parents : `mkdir -p` d'abord.

**sudo.** Les clés sont en `0600` root ; le fichier produit l'est aussi.

**Le chemin est celui de l'énoncé**, sur le nœud désigné. Une sauvegarde parfaite au mauvais endroit vaut zéro.

#### 20.6.2 `etcdutl snapshot status`

```bash
sudo etcdutl snapshot status /var/lib/minikube/backup/etcd-snap.db -w table
```

```
┌──────────┬──────────┬────────────┬────────────┬─────────┐
│   HASH   │ REVISION │ TOTAL KEYS │ TOTAL SIZE │ VERSION │
├──────────┼──────────┼────────────┼────────────┼─────────┤
│ ec659978 │     1016 │        518 │     3.9 MB │   3.7.0 │
└──────────┴──────────┴────────────┴────────────┴─────────┘
```

`REVISION` est la révision figée par l'instantané, `TOTAL KEYS` le nombre de clés (révisions conservées comprises), `VERSION` la version de stockage. La commande lit le fichier hors ligne : un fichier tronqué ou corrompu échoue ici, ce qui en fait la vérification à faire systématiquement après une sauvegarde. (Les pages d'etcd et de kubernetes.io montrent encore un tableau sans colonne `VERSION`, ajoutée depuis.)

#### 20.6.3 Ce que la sauvegarde ne contient pas

L'instantané contient **tout l'état de l'API** : objets, Secrets, CRD et leurs ressources, Leases, événements récents. Il ne contient **pas** les certificats et clés de `/etc/kubernetes/pki` (sans eux, un cluster reconstruit ne fait pas confiance aux anciens kubeconfigs), les manifestes statiques, la configuration des kubelets, les images, ni les données des volumes persistants. Une sauvegarde complète d'un control plane associe l'instantané et une copie de `/etc/kubernetes/pki`.

Deux autres sources de sauvegarde existent, à connaître sans les préférer. Copier `member/snap/db` depuis un dossier de données d'un etcd **arrêté** donne une base valable mais sans empreinte (la restauration exige alors `--skip-hash-check`), et sans les écritures encore dans le journal (`member/wal`) si l'etcd tournait. Lancer `etcdctl snapshot save` **dans** le pod etcd (`kubectl -n kube-system exec etcd-cka -- etcdctl … snapshot save /var/lib/minikube/etcd/snap-exec.db`) fonctionne, mais le seul dossier inscriptible et visible depuis le nœud est le dossier de données lui-même : à réserver à une démonstration.

### 20.7 Restaurer : le mécanisme

#### 20.7.1 Ce que fait `etcdutl snapshot restore`

```bash
sudo etcdutl snapshot restore /var/lib/minikube/backup/etcd-snap.db \
  --data-dir /var/lib/minikube/etcd-restore
```

La restauration ne touche à aucun etcd en marche : elle **fabrique un nouveau dossier de données** à partir de l'instantané. Elle vérifie l'empreinte, recopie la base, puis réécrit les métadonnées de cluster : nouvel identifiant de cluster, nouvel identifiant de membre, liste des membres tirée de ses options. Le membre restauré perd son ancienne identité ; c'est voulu, pour qu'il ne puisse pas rejoindre par erreur l'ancien cluster. On fait ensuite démarrer etcd sur ce dossier.

| Option de `etcdutl snapshot restore` (3.7.0) | Défaut | Rôle |
|---|---|---|
| `--data-dir` | `<name>.etcd` dans le dossier courant | dossier à créer ; il doit être **absent ou vide** |
| `--name` | `default` | nom du membre restauré |
| `--initial-cluster` | `default=http://localhost:2380` | membres du nouveau cluster |
| `--initial-advertise-peer-urls` | `http://localhost:2380` | URL de pair de ce membre |
| `--initial-cluster-token` | `etcd-cluster` | jeton du nouveau cluster |
| `--bump-revision` | `0` | révisions à ajouter à celle de l'instantané |
| `--mark-compacted` | `false` | marque tout l'historique comme compacté ; **obligatoire** si `--bump-revision` > 0, interdit sinon |
| `--skip-hash-check` | `false` | ignore l'empreinte (instantané copié d'un dossier de données) |
| `--wal-dir` | sous `--data-dir` | journal ailleurs que les données |

Deux erreurs de la table reviennent sans cesse. Restaurer dans le dossier en service : `data-dir "/var/lib/etcd" not empty or could not be read`, on choisit un **nouveau** dossier. Oublier `--data-dir` : la restauration crée `default.etcd` dans le dossier courant, qu'etcd n'utilisera jamais.

#### 20.7.2 Le piège du cache de watch

Après une restauration, la révision d'etcd **recule** : elle revient à celle de l'instantané, alors que l'apiserver, les contrôleurs et les kubelets ont vu passer des révisions plus récentes. Voici ce qu'on observe sur le lab en restaurant sans précaution (scénario relevé le 23 octobre 2026) : une ConfigMap `temoin-avant` créée avant la sauvegarde, une ConfigMap `temoin-apres` créée après, puis restauration.

```
etcdctl get /registry/configmaps/default/ --prefix --keys-only
  /registry/configmaps/default/kube-root-ca.crt
  /registry/configmaps/default/temoin-avant          ← etcd est bien restauré

kubectl get cm temoin-apres
  Error from server (NotFound): configmaps "temoin-apres" not found

kubectl get cm                                        ← liste servie par le cache
  kube-root-ca.crt   temoin-apres   temoin-avant      ← encore là 2 min 20 après
```

La lecture par nom va à etcd et dit vrai ; la liste vient du cache de watch, resté à la révision 1178 alors qu'etcd est revenu vers 1016. Le cache croit déjà connaître la révision courante d'etcd, puisqu'elle est plus **petite** que la sienne ; il ne se rafraîchit pas. Pire, les écritures suivantes réutilisent des numéros de révision (1017, 1018…) que les clients ont déjà vus pour d'autres changements : un watch repris « depuis 1178 » saute tout ce qui se passe entre 1017 et 1178. Les informers des contrôleurs restent faux de la même manière.

```
Révisions, sans et avec --bump-revision :
═════════════════════════════════════════

  avant le sinistre        ─────────────────────────────▶ 1178   (vu par les caches)
  instantané               ──────────────▶ 1016
  restauration simple      ──────────────▶ 1016 → 1017, 1018…    ✗ en dessous de 1178 :
                                                                    les caches ne voient rien
  restauration avec        ──────────────▶ 1016 + 1 000 000 000 = 1 000 001 016 → …
  --bump-revision 1e9                                             ✓ au-dessus de tout ce
  --mark-compacted         toute révision antérieure = « compactée » : un watch qui
                           reprend à 1178 reçoit « too old resource version » (410),
                           et le client refait une liste complète.
```

Deux remèdes. Le premier, recommandé par la documentation d'etcd dès qu'il y a des watchers, c'est-à-dire toujours avec Kubernetes : restaurer avec **`--bump-revision 1000000000 --mark-compacted`**. Le saut d'un milliard couvre une semaine d'écritures à moins de 1 500 par seconde ; `--mark-compacted` invalide toute révision antérieure, ce qui force chaque cache à se reconstruire. Testé sur le lab : sans aucun redémarrage de l'apiserver, la première réponse de l'API après la coupure ne contient plus l'objet postérieur à l'instantané, et la révision d'etcd vaut ensuite 1 000 001 549. Le second remède, celui que décrit kubernetes.io : redémarrer kube-apiserver après la restauration (et, par précaution, kube-controller-manager, kube-scheduler et les kubelets). Sur le lab, arrêter les trois conteneurs du control plane par crictl a suffi : 8 s plus tard, la liste était juste.

```bash
# remède 2, dans le nœud du control plane
for c in kube-apiserver kube-controller-manager kube-scheduler; do
  sudo crictl stop $(sudo crictl ps --name $c -q)
done
```

> [!tip] Réflexe d'examen
> Restaure **toujours** avec `--bump-revision 1000000000 --mark-compacted`, sauf si l'énoncé impose une commande. Si tu as restauré sans, redémarre l'apiserver, le controller-manager et le scheduler. Et vérifie par une **liste** (`kubectl get ns`, `kubectl -n demo get all`), pas seulement par une lecture d'objet.

#### 20.7.3 L'identité du membre restauré

Sans `--name`, `--initial-cluster` et `--initial-advertise-peer-urls`, le membre restauré s'appelle `default` et annonce `http://localhost:2380`, ce qui lui donne l'identifiant bien connu `8e9e05c52164694d`. Au démarrage, etcd, qui trouve un dossier de données existant, **ignore** ses options `--initial-*` ; il publie seulement son nom réel (`--name=cka`) et ses URL clientes. D'où ce qu'on lit après la restauration du lab :

```
8e9e05c52164694d, started, cka, http://localhost:2380, https://192.168.49.2:2379, false
```

Pour un membre unique, c'est sans conséquence. Pour un cluster de plusieurs membres, c'est rédhibitoire : chaque membre doit être restauré avec son nom, la liste complète des membres et ses propres URL de pair (20.10.1). Sur un control plane kubeadm unique qu'on voudra un jour étendre, on passe les mêmes options, tirées du manifeste (`--name`, `--initial-cluster`, `--initial-advertise-peer-urls`).

### 20.8 La procédure sur un cluster kubeadm (examen)

C'est la procédure à savoir dérouler sans réfléchir, sur un control plane unique, etcd en pod statique, données dans `/var/lib/etcd`.

```bash
# sur le control plane (ssh <nœud>, puis sudo -i)
# 1. Sauvegarder (si l'énoncé le demande) et vérifier
mkdir -p /opt/backup
etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /opt/backup/etcd.db
etcdutl snapshot status /opt/backup/etcd.db -w table

# 2. Restaurer dans un NOUVEAU dossier
etcdutl snapshot restore /opt/backup/etcd.db \
  --data-dir /var/lib/etcd-restore \
  --bump-revision 1000000000 --mark-compacted

# 3. Faire pointer etcd sur ce dossier : seul le hostPath du volume etcd-data change
cp /etc/kubernetes/manifests/etcd.yaml /root/etcd.yaml.orig          # copie HORS de manifests/
sed -i -E 's#^(\s+path: )/var/lib/etcd$#\1/var/lib/etcd-restore#' /etc/kubernetes/manifests/etcd.yaml
diff /root/etcd.yaml.orig /etc/kubernetes/manifests/etcd.yaml

# 4. Attendre le nouvel etcd, puis l'API
watch crictl ps --name etcd
kubectl get nodes
```

Le manifeste etcd de kubeadm monte le dossier de données par un volume `hostPath` nommé `etcd-data` ; dans le conteneur, le chemin reste `/var/lib/etcd` (`mountPath` et `--data-dir` inchangés). Changer le seul `hostPath` suffit donc :

```yaml
# /etc/kubernetes/manifests/etcd.yaml (extrait, après modification)
spec:
  containers:
  - command:
    - etcd
    - --data-dir=/var/lib/etcd            # inchangé : chemin DANS le conteneur
    volumeMounts:
    - mountPath: /var/lib/etcd            # inchangé
      name: etcd-data
  volumes:
  - hostPath:
      path: /var/lib/etcd-restore         # seul changement : dossier sur le nœud
      type: DirectoryOrCreate
    name: etcd-data
```

Le motif `sed` ne touche que la ligne `path: /var/lib/etcd` : `- mountPath:` commence par un tiret, `--data-dir=` aussi, et `path: /etc/kubernetes/pki/etcd` (le volume des certificats) ne finit pas par `/var/lib/etcd`. À l'examen, `vim` fait aussi bien ; ce qui compte est de vérifier par `diff` ou `grep -n 'path:'` qu'**une seule** ligne a changé. Une autre méthode, aussi juste, modifie les trois (`--data-dir`, `mountPath`, `hostPath`) ; une troisième arrête etcd, déplace l'ancien dossier, et restaure directement dans `/var/lib/etcd` vidé. Toutes donnent le même résultat ; la première est la plus rapide et la moins risquée.

Le kubelet détecte la modification du manifeste, arrête l'ancien pod etcd et en démarre un nouveau sur le dossier restauré. Pendant ce temps (une minute environ), l'apiserver perd etcd et `kubectl` échoue : c'est normal, on attend. Ne **pas** laisser de copie du manifeste dans `/etc/kubernetes/manifests` : un `etcd.yaml.bak` y serait chargé comme un manifeste à part entière, avec le même nom de pod que l'original ; le kubelet recréerait le pod etcd, et l'ancienne configuration pourrait l'emporter (chapitre 2).

La documentation de kubernetes.io recommande, pour un cluster à plusieurs apiservers, d'**arrêter tous les apiservers** avant de restaurer, puis de les redémarrer ensuite : on sort `kube-apiserver.yaml` du dossier des manifestes au début, on le remet à la fin. Sur un control plane unique, avec `--bump-revision` et `--mark-compacted`, ce n'est pas nécessaire.

### 20.9 La procédure sur le lab minikube

La même procédure, aux chemins de minikube, telle qu'elle a été testée. Le scénario des exercices 20.4 et 20.5 part de l'instantané I4 : sauvegarde, suppression du namespace `demo`, restauration.

```bash
minikube -p cka ssh
# dans le nœud cka
sudo etcdutl snapshot restore /var/lib/minikube/backup/etcd-snap.db \
  --data-dir /var/lib/minikube/etcd-restore --bump-revision 1000000000 --mark-compacted
sudo cp /etc/kubernetes/manifests/etcd.yaml /root/etcd.yaml.orig
sudo sed -i -E 's#^(\s+path: )/var/lib/minikube/etcd$#\1/var/lib/minikube/etcd-restore#' \
  /etc/kubernetes/manifests/etcd.yaml
sudo diff /root/etcd.yaml.orig /etc/kubernetes/manifests/etcd.yaml
```

```
91c91
<       path: /var/lib/minikube/etcd
---
>       path: /var/lib/minikube/etcd-restore
```

Seul le `hostPath` du volume `etcd-data` change ; `--data-dir` et `mountPath` restent `/var/lib/minikube/etcd`. Le motif ne touche ni `- mountPath:` ni le volume des certificats `/var/lib/minikube/certs/etcd`.

```
Chronologie relevée sur le lab (restaurations du 23 octobre 2026) :
════════════════════════════════════════════════════════════════════

  t = 0 s     manifeste etcd modifié
  t + 4 s     API injoignable : "Unable to connect to the server: …
              Client.Timeout exceeded"
  t + 50 s    nouveau conteneur etcd visible (crictl ps --name etcd)
  t + 65 s    API de nouveau joignable
  t + 70 s    première réponse de l'API : état de l'instantané, sans
              redémarrage de l'apiserver (avec --bump-revision)

  storage-provisioner et calico-kube-controllers redémarrent une fois
  pendant la coupure ; c'est sans conséquence.
```

Depuis le poste, on attend l'API puis on vérifie par des listes :

```bash
until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 5; done
kubectl get ns
kubectl -n demo get deploy,svc,pods
```

Le membre restauré porte l'identifiant `8e9e05c52164694d` et l'URL de pair `http://localhost:2380` (20.7.3). Le manifeste modifié **survit** à `minikube -p cka stop` puis `start` : minikube ne réécrit pas les manifestes statiques au redémarrage, le cluster repart sur `/var/lib/minikube/etcd-restore`. L'ancien dossier `/var/lib/minikube/etcd` reste sur le disque avec l'état d'après le sinistre ; on le garde, il ne gêne pas.

> [!danger] Rejouer l'exercice sans détruire l'etcd en service
> Si tu recommences la restauration, `/var/lib/minikube/etcd-restore` existe déjà **et c'est peut-être le dossier en service**. `etcdutl` refusera d'y écrire, et le `sed` ne trouvera plus `path: /var/lib/minikube/etcd` : il ne changera rien, sans le dire. Avant tout, lis le chemin en service (`sudo grep -n 'path:' /etc/kubernetes/manifests/etcd.yaml`), restaure dans un dossier neuf (`etcd-restore-2`), et adapte le motif. Ne supprime jamais le dossier que le manifeste désigne.

### 20.10 Cas particuliers

#### 20.10.1 Restaurer un etcd empilé à trois membres

Sur un cluster kubeadm HA (lab de VM, chapitre 19), tous les membres doivent repartir **du même instantané**, chacun avec son identité, sous un **nouveau** jeton de cluster. On arrête tout avant de restaurer.

```bash
# sur cp1, cp2 et cp3 : arrêter apiserver et etcd
sudo mkdir -p /root/manifests-pause
sudo mv /etc/kubernetes/manifests/{kube-apiserver,etcd}.yaml /root/manifests-pause/

# sur chaque cpN (adresse 192.168.10.1N), le même fichier etcd.db copié au préalable
sudo etcdutl snapshot restore /root/etcd.db \
  --name cpN \
  --initial-cluster cp1=https://192.168.10.11:2380,cp2=https://192.168.10.12:2380,cp3=https://192.168.10.13:2380 \
  --initial-cluster-token etcd-restaure \
  --initial-advertise-peer-urls https://192.168.10.1N:2380 \
  --data-dir /var/lib/etcd-restore --bump-revision 1000000000 --mark-compacted
sudo sed -i -E 's#^(\s+path: )/var/lib/etcd$#\1/var/lib/etcd-restore#' /root/manifests-pause/etcd.yaml

# sur les trois : remettre etcd, puis l'apiserver une fois etcd sain partout
sudo mv /root/manifests-pause/etcd.yaml /etc/kubernetes/manifests/
sudo mv /root/manifests-pause/kube-apiserver.yaml /etc/kubernetes/manifests/
```

Les trois membres se reconnaissent par la liste `--initial-cluster` gravée dans leurs dossiers et par le jeton commun. Un membre restauré avec un autre jeton, ou avec un autre instantané, forme un cluster à part. Ensuite, on redémarre controller-manager et scheduler sur chaque control plane.

#### 20.10.2 etcd externe

On reconnaît un etcd externe à trois indices : aucun `etcd.yaml` dans `/etc/kubernetes/manifests`, aucun pod `etcd-*` dans `kube-system`, et un `--etcd-servers` de l'apiserver qui vise d'autres machines. etcd y tourne en service systemd, en général sous un utilisateur `etcd`, avec ses options dans l'unité ou dans un fichier d'environnement (`systemctl cat etcd`). Les certificats à passer à etcdctl sont ceux des drapeaux `--etcd-cafile`, `--etcd-certfile`, `--etcd-keyfile` de l'apiserver.

```bash
# sur chaque control plane : arrêter l'apiserver
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /root/
# sur chaque machine etcd
sudo systemctl stop etcd
sudo etcdutl snapshot restore /root/etcd.db --name <nom> --initial-cluster <liste> \
  --initial-cluster-token etcd-restaure --initial-advertise-peer-urls https://<ip>:2380 \
  --data-dir /var/lib/etcd-restore --bump-revision 1000000000 --mark-compacted
sudo chown -R etcd:etcd /var/lib/etcd-restore
# --data-dir de l'unité (ou ETCD_DATA_DIR) → /var/lib/etcd-restore
sudo systemctl daemon-reload && sudo systemctl start etcd
# puis remettre les apiservers
sudo mv /root/kube-apiserver.yaml /etc/kubernetes/manifests/
```

Le `chown` est l'oubli typique : `etcdutl` lancé par root crée un dossier appartenant à root, que le service, s'il tourne sous `etcd`, ne peut pas ouvrir. `kubeadm reset` ne touche jamais un etcd externe.

#### 20.10.3 Remplacer un membre sans restaurer

Tant que le quorum tient, on ne restaure pas : on remplace. Depuis un membre vivant, on retire le membre mort par son identifiant, puis on en ajoute un nouveau. Sur un cluster kubeadm, `kubeadm join --control-plane` d'une machine neuve fait l'ajout (en learner, puis promotion) ; à la main, c'est `etcdctl member add <nom> --peer-urls=https://<ip>:2380 [--learner]`, puis le démarrage du nouveau membre avec `--initial-cluster-state=existing`.

```bash
etcdctl member list
etcdctl member remove 9c7d6e5f4a3b2c18
```

```
Member 9c7d6e5f4a3b2c18 removed from cluster …
```

Un control plane détruit sans `kubeadm reset` laisse ainsi un membre fantôme : le cluster compte trois membres dont un mort, et ne tolère plus aucune panne. `member remove` le corrige (chapitre 19.8).

#### 20.10.4 Espace disque, compactage et défragmentation

Quand la base atteint son quota (2 Gio par défaut), etcd lève l'alarme `NOSPACE` et passe en lecture et suppression seules : l'apiserver renvoie des erreurs `mvcc: database space exceeded` à chaque écriture. Le remède : compacter l'historique (l'apiserver le fait toutes les 5 minutes ; à la main, `etcdctl compaction <révision>`), défragmenter chaque membre pour rendre l'espace (`etcdctl defrag`, membre par membre, car un membre en défragmentation ne répond plus), puis lever l'alarme.

```bash
etcdctl alarm list
etcdctl defrag
etcdctl alarm disarm
```

kubernetes.io recommande de confier la défragmentation régulière à un outil dédié, `etcd-defrag`, éventuellement lancé par un CronJob. Hors ligne, `etcdutl defrag --data-dir <dossier>` défragmente un dossier de données d'un etcd arrêté.

### 20.11 Pièges courants

```
Piège 1 : etcdctl snapshot restore
══════════════════════════════════
  MAUVAIS  : etcdctl snapshot restore etcd.db --data-dir /var/lib/etcd-restore
  SYMPTÔME : « Error: unknown flag: --data-dir » : la sous-commande restore
             n'existe plus (supprimée en etcd 3.6) ; etcdctl snapshot status
             n'affiche que l'aide de « snapshot ».
  BON      : etcdutl snapshot restore etcd.db --data-dir /var/lib/etcd-restore

Piège 2 : Restaurer sans --bump-revision ni redémarrage de l'apiserver
══════════════════════════════════════════════════════════════════════
  SYMPTÔME : kubectl get <objet> dit NotFound, kubectl get <liste> le montre
             encore ; les contrôleurs agissent sur un état fantôme.
  BON      : --bump-revision 1000000000 --mark-compacted ;
             sinon, redémarrer apiserver, controller-manager, scheduler.

Piège 3 : --bump-revision sans --mark-compacted
═══════════════════════════════════════════════
  SYMPTÔME : "--mark-compacted required if --revision-bump > 0"
  BON      : les deux ensemble, toujours.

Piège 4 : Restaurer dans le dossier en service
══════════════════════════════════════════════
  SYMPTÔME : data-dir "/var/lib/etcd" not empty or could not be read
  BON      : un nouveau dossier, puis modifier le hostPath du manifeste.

Piège 5 : Modifier --data-dir au lieu du hostPath
═════════════════════════════════════════════════
  MAUVAIS  : --data-dir=/var/lib/etcd-restore, hostPath inchangé
  SYMPTÔME : etcd démarre sur un dossier vide DANS le conteneur, non monté :
             cluster vierge, données perdues au prochain redémarrage.
  BON      : changer le hostPath du volume etcd-data (ou les trois chemins).

Piège 6 : La mauvaise CA
════════════════════════
  MAUVAIS  : --cacert=/etc/kubernetes/pki/ca.crt
  SYMPTÔME : la connexion échoue sur une erreur TLS, etcdctl finit par
             "context deadline exceeded" ; la cause est dans la ligne
             de journal qui précède.
  BON      : --cacert=/etc/kubernetes/pki/etcd/ca.crt

Piège 7 : Les variables ETCDCTL_* perdues par sudo
══════════════════════════════════════════════════
  MAUVAIS  : export ETCDCTL_CACERT=… (en utilisateur), puis sudo etcdctl …
  SYMPTÔME : etcdctl, privé de certificats, parle en clair à un etcd
             en TLS et échoue.
  BON      : sudo -i, puis export ; ou options complètes sur la ligne.

Piège 8 : Une copie du manifeste laissée dans manifests/
════════════════════════════════════════════════════════
  MAUVAIS  : cp etcd.yaml /etc/kubernetes/manifests/etcd.yaml.bak
  SYMPTÔME : le kubelet charge aussi la copie, de même nom de pod :
             etcd est recréé, et l'ancienne configuration peut l'emporter.
  BON      : la copie va dans /root/.

Piège 9 : Le préfixe sans barre finale
══════════════════════════════════════
  MAUVAIS  : etcdctl get /registry/deployments/boutique --prefix --keys-only
  SYMPTÔME : les clés de boutique-recette apparaissent aussi.
  BON      : /registry/deployments/boutique/
```

> [!summary] À retenir
> - etcd est la seule mémoire du cluster ; seul l'apiserver lui parle. Clés `/registry/<ressource>/<namespace>/<nom>`, valeurs en protobuf, Secrets en clair sauf chiffrement au repos : un instantané se protège comme un secret.
> - Raft : un leader, validation à la majorité, quorum ⌊N/2⌋ + 1, nombre impair de membres. Sans quorum, l'API se fige mais les pods continuent de tourner.
> - kubeadm 1.37 déploie etcd 3.7.0. `etcdctl` parle au serveur (santé, membres, clés, `snapshot save`) ; `etcdutl` travaille sur les fichiers (`snapshot status`, `snapshot restore`). `etcdctl snapshot restore/status` n'existent plus depuis etcd 3.6, même si kubernetes.io les montre encore.
> - Les chemins se lisent dans `etcd.yaml` et `kube-apiserver.yaml` : point d'accès `https://127.0.0.1:2379`, CA `etcd/ca.crt`, client `etcd/server.crt` (ou `healthcheck-client`, ou `apiserver-etcd-client`). `ETCDCTL_API=3` est inutile.
> - Sauvegarde : `etcdctl … snapshot save <fichier>` sur un seul point d'accès, dossier existant, puis `etcdutl snapshot status <fichier> -w table`. Elle ne contient pas les certificats de `/etc/kubernetes/pki`.
> - Restauration : `etcdutl snapshot restore <fichier> --data-dir <nouveau dossier> --bump-revision 1000000000 --mark-compacted`, puis changer le seul `hostPath` du volume `etcd-data`, copie du manifeste hors de `manifests/`, attendre une minute, vérifier par des listes.
> - Sans `--bump-revision`, le cache de watch de l'apiserver et les informers restent figés sur l'ancien état : il faut alors redémarrer les composants du control plane.
> - Un membre restauré sans options s'appelle `default` et annonce `http://localhost:2380` ; en multi-membres, chacun se restaure avec `--name`, `--initial-cluster`, `--initial-advertise-peer-urls` et un jeton commun.

### 20.12 Exercices

#### Exercice 20.1 — Installer etcdctl et etcdutl

**Point de départ** : fin du chapitre 19 (le cluster minikube n'y a pas changé), ou instantané I4.

Dans le nœud `cka`, installe `etcdctl` et `etcdutl` en version 3.7.0, celle du serveur, depuis l'archive officielle d'etcd-io dont tu vérifies la somme de contrôle. Les deux binaires doivent être dans `/usr/local/bin`.

> [!example]- Solution
> ```bash
> kubectl -n kube-system exec etcd-cka -- etcd --version | head -1     # version du serveur
> minikube -p cka ssh
> # dans le nœud cka
> cd /tmp
> ETCD_VER=v3.7.0
> curl -fsSLO https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz
> curl -fsSLO https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/SHA256SUMS
> grep linux-amd64.tar.gz SHA256SUMS | sha256sum -c -
> tar xzf etcd-${ETCD_VER}-linux-amd64.tar.gz
> sudo install -m 0755 etcd-${ETCD_VER}-linux-amd64/etcdctl etcd-${ETCD_VER}-linux-amd64/etcdutl /usr/local/bin/
> ```
>
> On prend la version du serveur pour éviter toute différence de comportement entre client et serveur. Le fichier `SHA256SUMS` couvre toutes les archives de la version ; `grep` isole la ligne de la nôtre, que `sha256sum -c -` vérifie. Sans accès à Internet, la méthode 2 de la section 20.3.3 copie les binaires depuis le conteneur etcd.
>
> **Vérification** : `sha256sum -c` affiche `etcd-v3.7.0-linux-amd64.tar.gz: OK` ; `etcdctl version` affiche `etcdctl version: 3.7.0` et `API version: 3.7` ; `etcdutl version` affiche `etcdutl version: 3.7.0`.

#### Exercice 20.2 — Explorer etcd

**Point de départ** : exercice 20.1.

Sans connaître les chemins à l'avance, retrouve dans les manifestes du nœud `cka` le point d'accès client d'etcd et les certificats à utiliser. Avec ces valeurs, affiche la santé du membre, son statut (qui est leader, quelle taille de base), la liste des membres en tableau, la liste des Deployments du namespace `boutique` tels qu'ils sont stockés, et la clé de la ressource `redis-quotidienne` du chapitre 18. Compte enfin les clés du namespace `demo`.

> [!example]- Solution
> ```bash
> minikube -p cka ssh
> # dans le nœud cka
> sudo grep -E -- '--(listen-client-urls|cert-file|key-file|trusted-ca-file)' /etc/kubernetes/manifests/etcd.yaml
> sudo -i
> export ETCDCTL_ENDPOINTS=https://127.0.0.1:2379 \
>        ETCDCTL_CACERT=/var/lib/minikube/certs/etcd/ca.crt \
>        ETCDCTL_CERT=/var/lib/minikube/certs/etcd/server.crt \
>        ETCDCTL_KEY=/var/lib/minikube/certs/etcd/server.key
> etcdctl endpoint health
> etcdctl endpoint status -w table
> etcdctl member list -w table
> etcdctl get /registry/deployments/boutique/ --prefix --keys-only | grep -v '^$'
> etcdctl get /registry/boutique.example/ --prefix --keys-only | grep -v '^$'
> etcdctl get /registry --prefix --keys-only | grep -c '/demo/'
> exit
> ```
>
> Le manifeste etcd donne ce que le serveur présente et exige ; `server.crt` porte aussi l'usage client et convient. La barre finale du préfixe évite de ramasser `boutique-recette`. Les ressources d'une CRD sont rangées sous leur groupe : `/registry/boutique.example/sauvegardes/boutique/redis-quotidienne`. Le dernier comptage inclut toutes les ressources du namespace `demo` (Deployment, ReplicaSet, pods, Service, Secrets de la release Helm, ServiceAccount, ConfigMap `kube-root-ca.crt`…), ainsi que les EndpointSlices et les événements récents.
>
> **Vérification** : `endpoint health` affiche `is healthy: successfully committed proposal` ; la colonne `IS LEADER` du statut vaut `true` ; le tableau des membres compte une ligne, `cka`, `https://192.168.49.2:2380` ; les Deployments listés sont `api`, `front` et `front-v2` ; le comptage pour `demo` est supérieur à zéro (note-le, il resservira).

#### Exercice 20.3 — Sauvegarder etcd

**Point de départ** : exercice 20.2.

Sauvegarde etcd dans `/var/lib/minikube/backup/etcd-snap.db` sur le nœud `cka`, en options explicites sur la ligne de commande (sans variables d'environnement). Vérifie l'intégrité de la sauvegarde et note sa révision.

> [!example]- Solution
> ```bash
> minikube -p cka ssh
> # dans le nœud cka
> sudo mkdir -p /var/lib/minikube/backup
> sudo etcdctl --endpoints=https://127.0.0.1:2379 \
>   --cacert=/var/lib/minikube/certs/etcd/ca.crt \
>   --cert=/var/lib/minikube/certs/etcd/server.crt \
>   --key=/var/lib/minikube/certs/etcd/server.key \
>   snapshot save /var/lib/minikube/backup/etcd-snap.db
> sudo etcdutl snapshot status /var/lib/minikube/backup/etcd-snap.db -w table
> sudo ls -l /var/lib/minikube/backup/
> exit
> ```
>
> Le dossier `/var/lib/minikube/backup` est sur le volume Docker du nœud : il survit à un arrêt, contrairement à `/tmp`. Les options explicites sont la forme qu'attend un correcteur et qui ne dépend d'aucun état du shell. `snapshot status` relit le fichier hors ligne ; c'est la preuve que la sauvegarde est exploitable.
>
> **Vérification** : `snapshot save` se termine par `Snapshot saved at /var/lib/minikube/backup/etcd-snap.db` et `Server version 3.7.0` ; le tableau de `snapshot status` montre une révision non nulle et `VERSION` à `3.7.0` ; `ls -l` montre un fichier `-rw-------` appartenant à `root`, sans fichier `.part`.

#### Exercice 20.4 — Le sinistre

**Point de départ** : exercice 20.3. La sauvegarde `etcd-snap.db` doit exister : sans elle, ne lance pas cet exercice.

Simule une erreur d'exploitation : supprime le namespace `demo` et attends sa disparition complète. Constate la perte de la release Helm `vitrine`.

> [!example]- Solution
> ```bash
> kubectl -n demo get all
> helm -n demo list
> kubectl delete namespace demo
> kubectl wait --for=delete namespace/demo --timeout=180s
> kubectl get ns demo
> helm -n demo list
> ```
>
> Supprimer un namespace supprime tout ce qu'il contient, y compris les Secrets où Helm range l'historique de ses releases. Aucune commande Kubernetes ne le fait revenir : la seule copie est dans l'instantané de l'exercice 20.3. Une restauration d'etcd ramène **tout le cluster** à l'heure de cet instantané : les objets créés ou modifiés depuis ailleurs (Jobs du CronJob `rapport`, état du HPA, Leases) reviendront aussi en arrière. En production, c'est un marteau ; on lui préfère une sauvegarde par namespace (outil dédié, ou manifestes versionnés). Ici, c'est exactement le scénario d'examen.
>
> **Vérification** : `kubectl get ns demo` répond `Error from server (NotFound): namespaces "demo" not found` ; `helm -n demo list` n'affiche plus aucune release.

#### Exercice 20.5 — Restaurer etcd

**Point de départ** : exercice 20.4.

Restaure etcd à partir de `/var/lib/minikube/backup/etcd-snap.db` dans le dossier `/var/lib/minikube/etcd-restore`, de façon que les caches de l'apiserver et des contrôleurs ne puissent pas rester sur l'état d'après le sinistre, et sans redémarrer l'apiserver. Fais démarrer etcd sur ce dossier et vérifie le retour du namespace `demo` et de la release `vitrine`.

> [!example]- Solution
> ```bash
> minikube -p cka ssh
> # dans le nœud cka
> sudo grep -n 'path:' /etc/kubernetes/manifests/etcd.yaml        # dossier en service : /var/lib/minikube/etcd
> sudo etcdutl snapshot restore /var/lib/minikube/backup/etcd-snap.db \
>   --data-dir /var/lib/minikube/etcd-restore --bump-revision 1000000000 --mark-compacted
> sudo cp /etc/kubernetes/manifests/etcd.yaml /root/etcd.yaml.orig
> sudo sed -i -E 's#^(\s+path: )/var/lib/minikube/etcd$#\1/var/lib/minikube/etcd-restore#' \
>   /etc/kubernetes/manifests/etcd.yaml
> sudo diff /root/etcd.yaml.orig /etc/kubernetes/manifests/etcd.yaml
> exit
> # sur le poste : attendre l'API (≈ 1 minute)
> until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 5; done
> kubectl get ns demo
> kubectl -n demo get deploy,svc,pods
> helm -n demo list
> minikube -p cka ssh -- 'sudo etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/var/lib/minikube/certs/etcd/ca.crt --cert=/var/lib/minikube/certs/etcd/server.crt --key=/var/lib/minikube/certs/etcd/server.key member list'
> ```
>
> `--bump-revision 1000000000 --mark-compacted` fait repartir les révisions au-dessus de toutes celles que les caches ont vues et déclare l'ancien historique compacté : chaque watch interrompu reçoit « too old resource version » et son client refait une liste complète, depuis l'état restauré. Les pods de `vitrine` reviennent avec leurs objets : leurs conteneurs avaient été tués pendant le sinistre, le kubelet les relance (`RESTARTS 1`). Dans les secondes qui suivent le retour de l'API, le ReplicaSet peut créer deux pods de plus, en `Pending`, qu'il supprime dès que les anciens ont redémarré : c'est transitoire. Le membre restauré n'a reçu ni nom ni URL de pair : il annonce `http://localhost:2380`, sans conséquence pour un membre unique (20.7.3).
>
> **Vérification** : `diff` montre une seule ligne changée (`path: /var/lib/minikube/etcd-restore`) ; `kubectl get ns demo` affiche `demo   Active` ; les pods de `demo` repassent `Running` ; `helm -n demo list` affiche la release `vitrine` au statut `deployed` ; `member list` affiche `8e9e05c52164694d, started, cka, http://localhost:2380, https://192.168.49.2:2379, false`. Le cluster est revenu à l'état I4, avec etcd sur `/var/lib/minikube/etcd-restore`.

#### Exercice 20.6 — Sauvegarder comme l'apiserver, et transposer

**Point de départ** : exercice 20.5.

Une tâche d'examen précise : « Sauvegarde etcd dans `/var/lib/minikube/backup/etcd-client-apiserver.db` en utilisant le certificat client avec lequel kube-apiserver s'adresse à etcd. » Retrouve ce certificat dans le manifeste de l'apiserver, fais la sauvegarde, vérifie-la, et vérifie que la révision d'etcd dépasse désormais le milliard. Écris enfin, sans l'exécuter, la suite de commandes équivalente pour un control plane kubeadm dont les certificats sont sous `/etc/kubernetes/pki` et les données sous `/var/lib/etcd`, avec sauvegarde dans `/opt/backup/etcd.db` et restauration dans `/var/lib/etcd-restore`.

> [!example]- Solution
> ```bash
> minikube -p cka ssh
> # dans le nœud cka
> sudo grep -E -- '--etcd-(servers|cafile|certfile|keyfile)' /etc/kubernetes/manifests/kube-apiserver.yaml
> sudo etcdctl --endpoints=https://127.0.0.1:2379 \
>   --cacert=/var/lib/minikube/certs/etcd/ca.crt \
>   --cert=/var/lib/minikube/certs/apiserver-etcd-client.crt \
>   --key=/var/lib/minikube/certs/apiserver-etcd-client.key \
>   snapshot save /var/lib/minikube/backup/etcd-client-apiserver.db
> sudo etcdutl snapshot status /var/lib/minikube/backup/etcd-client-apiserver.db -w table
> exit
> ```
>
> Le certificat client de l'apiserver (`apiserver-etcd-client.crt`) est signé par la CA d'etcd et porte l'usage client : etcd l'accepte comme n'importe quel client. La CA reste `etcd/ca.crt`. Transposée sur un cluster kubeadm d'examen, la procédure complète devient :
>
> ```bash
> # ssh <control plane>, puis sudo -i
> mkdir -p /opt/backup
> etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
>   --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
>   snapshot save /opt/backup/etcd.db
> etcdutl snapshot status /opt/backup/etcd.db -w table
> etcdutl snapshot restore /opt/backup/etcd.db --data-dir /var/lib/etcd-restore \
>   --bump-revision 1000000000 --mark-compacted
> cp /etc/kubernetes/manifests/etcd.yaml /root/etcd.yaml.orig
> sed -i -E 's#^(\s+path: )/var/lib/etcd$#\1/var/lib/etcd-restore#' /etc/kubernetes/manifests/etcd.yaml
> diff /root/etcd.yaml.orig /etc/kubernetes/manifests/etcd.yaml
> ```
>
> **Vérification** : le tableau de `snapshot status` affiche une `REVISION` supérieure à 1000000000, preuve que la restauration de l'exercice 20.5 a bien fait sauter la révision ; la même valeur se lit en direct par `sudo etcdctl … endpoint status -w json`, champ `"revision"` de l'en-tête. La transposition ne diffère de la procédure du lab que par trois chemins : `/etc/kubernetes/pki/etcd` au lieu de `/var/lib/minikube/certs/etcd`, `/var/lib/etcd` au lieu de `/var/lib/minikube/etcd`, et le dossier de sauvegarde imposé.

---
