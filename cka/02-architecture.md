---
title: "CKA — 2. Architecture d'un cluster Kubernetes"
description: "Les composants du control plane et des nœuds, observés sur le lab minikube : pods statiques, kubelet, crictl, ports, chemin d'une requête, boucles de contrôle, watch, élection de leader, anatomie des objets, propriétaires et finalizers, groupes d'API et namespaces."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 2. Architecture d'un cluster Kubernetes

Ce chapitre démonte le cluster pièce par pièce. Il décrit chaque composant du control plane et des nœuds, ce qu'il fait, où il tourne, sur quel port il écoute et comment il dialogue avec les autres ; il suit une requête depuis `kubectl apply` jusqu'au conteneur ; il explique le moteur de tout Kubernetes, les boucles de contrôle alimentées par des *watch* ; il termine par l'anatomie des objets de l'API, leurs propriétaires, leurs finalizers et leurs namespaces. Le programme ne lui consacre qu'une ligne, *Troubleshoot cluster components*, mais tout le domaine *Troubleshooting* (30 %) en dépend : réparer un scheduler, un kubelet ou un apiserver suppose de savoir où ils vivent et comment ils démarrent, et comprendre pourquoi un objet ne disparaît pas ou pourquoi un pod reste `Pending` suppose de connaître la mécanique qui les fait converger. Chaque affirmation de ce chapitre est confrontée au lab : le nœud `cka` montre un control plane construit par kubeadm, avec quelques écarts que les encadrés signalent.

### 2.1 Un état désiré et des boucles qui convergent

Kubernetes ne reçoit pas des ordres, il reçoit des intentions. Quand tu crées un Deployment de trois réplicas, tu n'ordonnes pas « lance trois conteneurs » : tu enregistres dans la base du cluster un objet qui dit « il doit exister trois pods conformes à ce modèle ». Des programmes indépendants, les contrôleurs, observent en permanence l'écart entre cet état désiré (`spec`) et l'état observé (`status`), et agissent pour le réduire. Si un nœud meurt, personne ne « relance » les pods : le contrôleur constate qu'il en manque et en recrée. Cette idée, la réconciliation, explique la robustesse de Kubernetes et presque toutes ses bizarreries.

Elle impose une architecture en étoile. Un seul composant, **kube-apiserver**, lit et écrit l'état dans **etcd** ; tous les autres, contrôleurs, scheduler, kubelets, kube-proxy, ne parlent qu'à l'apiserver, jamais entre eux ni à etcd. Ils s'abonnent aux changements qui les concernent (les *watch*), décident localement, puis écrivent leur décision dans l'API, où d'autres la reprendront.

```
┌────────────────────────────────────────────────────────────────────────┐
│               LE CLUSTER DU LAB (profil minikube « cka »)              │
│                                                                        │
│  NŒUD cka (192.168.49.2) — control plane                               │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │ systemd : containerd ◀── kubelet ── lit /etc/kubernetes/manifests│  │
│  │                                                                  │  │
│  │ pods statiques (hostNetwork) :                                   │  │
│  │  ┌─────────┐   ┌────────────────┐   ┌───────────────────────┐    │  │
│  │  │ etcd    │◀──│ kube-apiserver │◀──│ kube-controller-mgr   │    │  │
│  │  │ :2379   │   │ :8443          │◀──│ kube-scheduler        │    │  │
│  │  └─────────┘   └───────▲────────┘   └───────────────────────┘    │  │
│  └────────────────────────┼─────────────────────────────────────────┘  │
│                           │  HTTPS, certificats signés par la CA       │
│          ┌────────────────┴───────────────┐                            │
│          │                                │                            │
│  NŒUD cka-m02 (.3)                NŒUD cka-m03 (.4)                    │
│  ┌──────────────────────┐         ┌──────────────────────┐             │
│  │ kubelet (systemd)    │         │ kubelet (systemd)    │             │
│  │ containerd (systemd) │         │ containerd (systemd) │             │
│  │ kube-proxy (DS)      │         │ kube-proxy (DS)      │             │
│  │ calico-node (DS)     │         │ calico-node (DS)     │             │
│  │ pods applicatifs     │         │ pods applicatifs     │             │
│  └──────────────────────┘         └──────────────────────┘             │
│                                                                        │
│  Le nœud cka porte aussi kubelet, kube-proxy et calico-node, et,       │
│  faute de taint, des pods applicatifs.                                 │
└────────────────────────────────────────────────────────────────────────┘
```

| Composant | Rôle | Forme sur un cluster kubeadm | Où sur le lab |
|---|---|---|---|
| kube-apiserver | Seule porte d'entrée de l'API, seul client d'etcd | Pod statique | `kube-apiserver-cka` |
| etcd | Base clé-valeur de tout l'état | Pod statique | `etcd-cka` |
| kube-scheduler | Choisit un nœud pour chaque pod | Pod statique | `kube-scheduler-cka` |
| kube-controller-manager | Fait tourner les contrôleurs intégrés | Pod statique | `kube-controller-manager-cka` |
| kubelet | Fait exister les pods d'un nœud | Service systemd | les trois nœuds |
| Runtime (containerd) | Crée les conteneurs, via CRI | Service systemd | containerd 2.3.4 |
| kube-proxy | Programme les Services dans le noyau | DaemonSet | `kube-proxy-*` |
| CNI (Calico) | Donne une IP et un réseau à chaque pod | DaemonSet + binaires | `calico-node-*` |
| CoreDNS | DNS des Services et des pods | Deployment | `coredns-*` (1 réplica) |

Les quatre premiers forment le **control plane** ; les trois suivants tournent sur **chaque nœud** ; kube-proxy, le CNI et CoreDNS sont des **addons**, des charges de travail ordinaires que l'installateur dépose dans `kube-system`.

### 2.2 Les composants du control plane

#### 2.2.1 kube-apiserver

L'apiserver est un serveur REST sans état : il authentifie chaque requête, l'autorise, la fait passer par l'admission, valide l'objet, l'écrit dans etcd et notifie les abonnés. Il ne prend aucune décision métier : il ne planifie rien, ne crée aucun pod de lui-même. Parce qu'il est sans état, on peut en faire tourner plusieurs côte à côte derrière un répartiteur de charge, tous actifs ([chapitre 19.4](19-kubeadm-installation-ha-et-mises-a-jour.md)). Il garde en mémoire un **cache de watch** par type de ressource, alimenté par etcd, qui sert la plupart des lectures et toutes les notifications : c'est lui qui permet à des milliers de clients de suivre les changements sans écraser etcd (2.10.4).

L'apiserver est aussi un proxy. `kubectl logs`, `exec` et `port-forward` passent par lui jusqu'au kubelet du nœud (port 10250) ; les API étendues, comme `metrics.k8s.io` de metrics-server, sont relayées par sa couche d'agrégation (chapitres 7.3 et 18.4.4).

#### 2.2.2 etcd

etcd est une base clé-valeur répliquée par l'algorithme Raft ([chapitre 20.2](20-etcd-sauvegarde-et-restauration.md)). Kubernetes y range chaque objet sous une clé de la forme `/registry/<ressource>/<namespace>/<nom>`, par exemple `/registry/configmaps/default/kube-root-ca.crt`, sérialisé en Protobuf. Chaque écriture incrémente un compteur global, la **révision** d'etcd ; c'est elle que l'API expose sous le nom de `resourceVersion`. etcd conserve l'historique des révisions jusqu'à ce que l'apiserver lui demande de le compacter, toutes les 5 minutes par défaut (`--etcd-compaction-interval`). Sur un cluster kubeadm comme sur le lab, etcd tourne en pod statique sur le control plane et n'écoute ses clients qu'en TLS mutuel : seuls l'apiserver et un administrateur muni des certificats `etcd/` peuvent lui parler.

> [!info] minikube ≠ examen
> Données etcd dans `/var/lib/minikube/etcd` (kubeadm : `/var/lib/etcd` ; dans le lab, `/var/lib/minikube/etcd-restore` après la restauration de l'exercice 20.5, et `lab/restaurer.sh I4` repart de `/var/lib/minikube/etcd`), certificats dans `/var/lib/minikube/certs/etcd` (kubeadm : `/etc/kubernetes/pki/etcd`). `etcdctl` et `etcdutl` sont absents du nœud `cka` ; ils existent dans l'image `registry.k8s.io/etcd:3.7.0-0`, qui n'a pas de shell. Le chapitre 20.3.3 les installe.

#### 2.2.3 kube-scheduler

Le scheduler surveille les pods dont `spec.nodeName` est vide et dont `spec.schedulerName` vaut `default-scheduler`. Pour chacun, il filtre les nœuds possibles (ressources, taints, affinités, volumes), note les survivants, puis publie sa décision en créant une sous-ressource **binding** du pod : c'est l'apiserver qui remplit alors `spec.nodeName`. Le scheduler ne lance rien et ne contacte aucun nœud. Quand il est absent, rien ne le remplace : les nouveaux pods restent `Pending` **sans aucun événement**, puisque l'événement `FailedScheduling` est écrit par le scheduler lui-même. Le [chapitre 8.2](08-ordonnancement-et-admission.md) détaille l'algorithme ; le [chapitre 23.4.5](23-depanner-le-cluster.md) exploite ce symptôme.

#### 2.2.4 kube-controller-manager

Un seul binaire, plusieurs dizaines de contrôleurs : Deployment, ReplicaSet, StatefulSet, DaemonSet, Job, CronJob, namespace, garbage collector, nœuds (node-lifecycle et node-ipam), EndpointSlice, ServiceAccount et jetons, PersistentVolume, HPA, certificats… L'option `--controllers` choisit lesquels tournent ; sa valeur par défaut `*` active tous ceux qui le sont par défaut, et trois sont désactivés par défaut (`bootstrap-signer-controller`, `token-cleaner-controller`, `selinux-warning-controller`). C'est pourquoi kubeadm, et minikube après lui, passe `--controllers=*,bootstrapsigner,tokencleaner` : les jetons de `kubeadm join` en ont besoin. Le controller-manager s'authentifie avec `/etc/kubernetes/controller-manager.conf` ; avec `--use-service-account-credentials=true`, chaque contrôleur agit sous son propre ServiceAccount de `kube-system`, ce qui permet au RBAC de limiter chacun à son métier.

Quand le controller-manager tombe, les pods existants continuent de tourner, mais plus rien ne converge : un `kubectl scale` modifie le Deployment sans qu'aucun pod n'apparaisse, un nœud mort n'est jamais déclaré `NotReady`, les EndpointSlices ne suivent plus les pods. C'est la panne 12 du chapitre 23.

#### 2.2.5 cloud-controller-manager

Sur un cloud, un cinquième composant, le cloud-controller-manager (port 10258), regroupe les contrôleurs qui parlent à l'API du fournisseur : adresses des nœuds, routes, Services `LoadBalancer`. kubeadm ne l'installe pas et le lab n'en a pas : c'est MetalLB qui jouera ce rôle pour les Services `LoadBalancer` au [chapitre 10.8](10-services.md).

### 2.3 Les composants des nœuds

#### 2.3.1 Le kubelet

Le kubelet est l'agent de chaque nœud, et le seul composant Kubernetes géré par systemd. Au démarrage, il enregistre son objet Node dans l'API (sous l'identité `system:node:<nœud>`), puis il surveille les pods dont `spec.nodeName` est le sien et les fait exister par l'intermédiaire du runtime. Il exécute les sondes, monte les volumes, applique les limites de ressources par les cgroups, remonte l'état des pods (`pods/status`) et du nœud, et renouvelle toutes les 10 secondes une Lease dans le namespace `kube-node-lease`, le battement de cœur qui prouve qu'il est vivant (2.11). Il lit aussi un dossier local de manifestes, ce qui lui permet de lancer des pods sans aucune API : les pods statiques (2.5).

Le kubelet expose une API HTTPS sur le port 10250 : c'est par elle que l'apiserver récupère les journaux, ouvre les sessions `exec` et relaie les `port-forward`. Elle exige une authentification (sur le lab, `authentication.anonymous.enabled: false` et `authorization.mode: Webhook` : le kubelet demande à l'apiserver si l'appelant a le droit).

#### 2.3.2 Le runtime : containerd et CRI

Le kubelet ne sait pas créer un conteneur. Il parle au runtime par **CRI** (Container Runtime Interface), une API gRPC servie sur un socket Unix, `unix:///run/containerd/containerd.sock` sur le lab (`containerRuntimeEndpoint` dans la configuration du kubelet). containerd 2.3.4 y répond, et délègue la création effective des processus à **runc** 1.4.3, qui pose namespaces Linux et cgroups. Chaque pod commence par un **sandbox** : un conteneur minuscule, l'image `registry.k8s.io/pause:3.10.2`, qui détient les namespaces réseau et IPC partagés par tous les conteneurs du pod. Kubernetes 1.37 exige containerd 2.x : la version 1.7 n'est plus prise en charge depuis 1.36. Le [chapitre 18.2](18-interfaces-crd-et-operateurs.md) revient sur CRI et `RuntimeClass`.

#### 2.3.3 kube-proxy

kube-proxy tourne en DaemonSet, un pod par nœud, en `hostNetwork`. Il surveille les Services et les EndpointSlices et les traduit en règles du noyau qui interceptent le trafic destiné à une IP de Service pour l'envoyer vers un pod. Le lab, comme kubeadm 1.37, l'utilise en mode `iptables`, écrit explicitement dans la ConfigMap `kube-system/kube-proxy` ; le mode `nftables` est stable depuis 1.33, `ipvs` est déprécié depuis 1.35. Détail au chapitre 10.

#### 2.3.4 Le plugin CNI et CoreDNS

Le kubelet ne configure pas non plus le réseau : à la création du sandbox, le runtime appelle le plugin **CNI** décrit dans `/etc/cni/net.d/` (sur le lab, `10-calico.conflist`), dont les binaires vivent dans `/opt/cni/bin`. Calico y crée l'interface du pod et lui attribue une IP ([chapitre 9](09-reseau-des-pods.md)). Sans CNI, un nœud reste `NotReady`. **CoreDNS**, enfin, est un Deployment ordinaire qui répond aux requêtes DNS des pods sur l'IP de Service `10.96.0.10` ([chapitre 11](11-coredns.md)).

> [!info] minikube ≠ examen
> Sur un cluster kubeadm, le control plane porte la taint `node-role.kubernetes.io/control-plane:NoSchedule` et CoreDNS compte 2 réplicas. Sur le lab, `cka` n'a **aucune** taint (`taints: []` dans la configuration kubeadm de minikube) et accueille donc des pods applicatifs, et CoreDNS n'a qu'un réplica (le chapitre 11 le passe à 2). La capacité annoncée par chaque nœud est celle de l'hôte (8 CPU, 32 Gio sur le poste de référence), pas celle demandée à minikube.

### 2.4 Les ports de chaque composant

Le tableau suivant donne les ports par défaut et leur adresse d'écoute sur un control plane kubeadm, puis ce qui change sur le lab. Il sert deux fois : pour ouvrir un pare-feu à l'installation (chapitre 19.2.1) et pour interroger un composant pendant un dépannage.

| Composant | Port | Écoute sous kubeadm | Sur le lab | Usage |
|---|---|---|---|---|
| kube-apiserver | 6443/TCP | toutes les adresses | **8443** | API HTTPS ; `/livez`, `/readyz` |
| etcd (clients) | 2379/TCP | 127.0.0.1 et IP du nœud | 127.0.0.1 et 192.168.49.2 | apiserver → etcd, TLS mutuel |
| etcd (pairs) | 2380/TCP | IP du nœud | 192.168.49.2 | réplication Raft entre membres |
| etcd (santé) | 2381/TCP | 127.0.0.1, HTTP | idem | `/livez`, `/readyz`, `/metrics` (sondes) |
| kube-scheduler | 10259/TCP | 127.0.0.1 | 127.0.0.1 | `/livez`, `/readyz`, `/metrics` |
| kube-controller-manager | 10257/TCP | 127.0.0.1 | 127.0.0.1 | `/healthz`, `/metrics` |
| cloud-controller-manager | 10258/TCP | — | absent | — |
| kubelet (API) | 10250/TCP | toutes les adresses | idem | logs, exec, port-forward, métriques |
| kubelet (santé) | 10248/TCP | 127.0.0.1, HTTP | idem | `/healthz` |
| kubelet (lecture seule) | 10255/TCP | désactivé (`readOnlyPort: 0`) | désactivé | — |
| kube-proxy (santé) | 10256/TCP | toutes les adresses | idem | `/healthz`, utilisé par les répartiteurs |
| kube-proxy (métriques) | 10249/TCP | 127.0.0.1 | 0.0.0.0 (ConfigMap) | `/metrics` |
| NodePort | 30000-32767 TCP/UDP | tous les nœuds | idem | Services `NodePort` (chapitre 10.7) |

Trois détails reviennent en dépannage. Le scheduler et le controller-manager n'écoutent que sur `127.0.0.1` (kubeadm leur passe `--bind-address=127.0.0.1`) : on les interroge depuis le nœud, pas depuis le poste. Leurs chemins `/healthz`, `/readyz` et `/livez` sont dispensés d'autorisation (`--authorization-always-allow-paths`, valeur par défaut) : un simple `curl -k` y répond `ok`. Et les sondes de kubeadm visent ces mêmes chemins : `/livez` et `/readyz` sur le port sécurisé de l'apiserver et du scheduler, `/healthz` sur 10257 pour le controller-manager, `/livez` et `/readyz` sur 2381 en HTTP pour etcd. Un composant que son manifeste fait écouter ailleurs que là où sa sonde le cherche est tué en boucle par le kubelet.

> [!info] minikube ≠ examen
> L'API du lab écoute sur **8443** : `https://192.168.49.2:8443`, et `control-plane.minikube.internal:8443` dans les kubeconfigs des nœuds. Un cluster kubeadm d'examen écoute sur **6443**. Une commande recopiée d'un lieu à l'autre sans corriger le port échoue par `connection refused` (panne 19 du chapitre 23).

> [!tip] Réflexe d'examen
> Pour savoir qui écoute où sur un nœud : `sudo ss -ltnp`, puis filtrer par nom de processus (`grep -E 'kube|etcd'`). La page « Ports and Protocols » de kubernetes.io (recherche : *ports and protocols*) redonne le tableau si la mémoire flanche.

### 2.5 Pods statiques et mirror pods

#### 2.5.1 Le mécanisme

L'apiserver ne peut pas être lancé par un Deployment : il faudrait qu'il existe déjà. kubeadm résout ce problème de l'œuf et de la poule par les **pods statiques**. Le kubelet surveille un dossier, `staticPodPath` dans sa configuration, `/etc/kubernetes/manifests` sur kubeadm comme sur le lab, et lance directement, par CRI, chaque pod qui y est décrit, sans rien demander à l'API. Il détecte les changements par inotify et, en filet de sécurité, relit le dossier toutes les 20 secondes (`fileCheckFrequency`). Il traite **tous** les fichiers qui ne commencent pas par un point, quelle que soit leur extension : `kube-apiserver.yaml.bak` est un manifeste comme un autre, alors que `.kube-apiserver.yaml` est ignoré.

```
Pod ordinaire contre pod statique :
═══════════════════════════════════

  Pod ordinaire                         Pod statique
  ─────────────                         ────────────
  kubectl ─▶ apiserver ─▶ etcd           /etc/kubernetes/manifests/x.yaml
               │                                  │ inotify + relecture 20 s
               ├─▶ contrôleur (RS, Job…)          ▼
               ├─▶ scheduler (nodeName)      ┌─────────┐   CRI   ┌────────────┐
               └─▶ kubelet du nœud ─▶ CRI    │ kubelet │ ──────▶ │ containerd │
                                             └────┬────┘         └────────────┘
                                                  │ dès que l'API répond :
                                                  ▼
                                   MIRROR POD « x-<nœud> » publié dans l'API
                                   (reflet en lecture seule, ownerReference
                                    vers l'objet Node)
```

Dès que l'apiserver est joignable, le kubelet publie pour chaque pod statique un **mirror pod** : un objet Pod qui reflète le pod local, nommé `<nom>-<nœud>` (`kube-apiserver-cka`, `etcd-cka`…), placé dans le namespace du manifeste (`default` s'il n'en indique pas). Le kubelet y recopie les labels et les annotations du manifeste et ajoute les siennes : `kubernetes.io/config.source: file`, `kubernetes.io/config.hash`, `kubernetes.io/config.seen` et surtout `kubernetes.io/config.mirror`, qui le désigne comme reflet. Il lui donne enfin une `ownerReference` vers l'objet Node du nœud, avec `controller: true` : c'est ainsi qu'on reconnaît un pod statique dans une liste (exercice 2.1), et c'est pourquoi le ramasse-miettes supprime les mirror pods d'un nœud qu'on retire du cluster.

#### 2.5.2 Les conséquences

**Modifier le manifeste suffit à redéployer.** Le kubelet voit le fichier changer, arrête l'ancien pod et lance le nouveau. Aucun `kubectl apply` n'est nécessaire, et aucun ne marcherait.

**Supprimer le mirror pod ne redémarre rien.** `kubectl delete pod kube-scheduler-cka` efface le reflet ; le kubelet le republie aussitôt, et le conteneur n'a pas bougé. Pour redémarrer réellement un pod statique, on sort son manifeste du dossier, on attend que le conteneur disparaisse (`sudo crictl ps --name kube-scheduler`), puis on le remet. Arrêter son conteneur par `sudo crictl stop` fonctionne aussi : le kubelet le relance, avec un compteur de redémarrages incrémenté.

**Les sauvegardes vont hors du dossier.** Une copie `kube-scheduler.yaml.bak` laissée dans `manifests/` décrit un second pod de même nom : le comportement est alors indéfini, et la vieille copie peut prendre le dessus. Le lab l'a vérifié : le kubelet a recréé le pod statique et journalisé `Deleted mirror pod as it didn't match the static Pod`. Range tes copies dans `/root/` ou dans un dossier de sauvegarde.

**Un pod statique ne peut pas référencer d'objet de l'API.** Pas de ServiceAccount, de ConfigMap ni de Secret dans sa spec : il doit pouvoir démarrer quand l'API n'existe pas encore. Depuis 1.37 (suppression de la feature gate `PreventStaticPodAPIReferences`), cette règle ne se désactive plus. Les pods statiques ne prennent pas non plus en charge les conteneurs éphémères de `kubectl debug` ([chapitre 22.5.1](22-depanner-les-applications.md)).

**Le namespace doit exister pour le reflet.** Si le manifeste vise un namespace absent, le kubelet lance le pod mais l'apiserver refuse le mirror pod : le pod tourne, invisible pour `kubectl`.

| | Pod statique | DaemonSet |
|---|---|---|
| Géré par | le kubelet d'un nœud | le contrôleur DaemonSet |
| Démarre sans API | oui | non |
| Mise à jour | éditer le fichier sur chaque nœud | `kubectl apply`, rolling update |
| Visible dans l'API | par son mirror pod, en lecture | objet complet |
| Usage | le control plane lui-même | agents de nœud (CNI, kube-proxy, journaux) |

> [!info] minikube ≠ examen
> Les manifestes du lab sont en `0600 root` (`sudo` obligatoire pour les lire), référencent `/var/lib/minikube/certs` au lieu de `/etc/kubernetes/pki`, et minikube ne les réécrit pas à un `minikube -p cka stop` puis `start` : une modification survit au redémarrage du cluster, en bien comme en mal. Le mécanisme lui-même, dossier, mirror pods, piège du `.bak`, est identique à kubeadm.

### 2.6 Le kubelet sous systemd

Le kubelet reçoit sa configuration de deux sources : un fichier `KubeletConfiguration` passé par `--config` (`/var/lib/kubelet/config.yaml`) et des options de ligne de commande, qui l'emportent en cas de conflit. Sur le nœud `cka` du lab :

```bash
minikube -p cka ssh
sudo systemctl status kubelet
```

```
  Loaded: loaded (/lib/systemd/system/kubelet.service; disabled; preset: enabled)
 Drop-In: /etc/systemd/system/kubelet.service.d
          └─10-kubeadm.conf
  Active: active (running) …
  CGroup: /system.slice/kubelet.service
          └─1382 /var/lib/minikube/binaries/v1.37.0/kubelet --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --config=/var/lib/kubelet/config.yaml --hostname-override=cka --kubeconfig=/etc/kubernetes/kubelet.conf --node-ip=192.168.49.2
```

`systemctl cat kubelet` montre l'unité et son complément (*drop-in*) `10-kubeadm.conf`, dont l'`ExecStart=` vide efface celui de l'unité avant d'en définir un nouveau. Les extraits utiles de la configuration :

```yaml
authentication: {anonymous: {enabled: false}, webhook: {enabled: true}, x509: {clientCAFile: /var/lib/minikube/certs/ca.crt}}
authorization: {mode: Webhook}
cgroupDriver: systemd
clusterDNS: [10.96.0.10]
clusterDomain: cluster.local
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock
healthzPort: 10248
rotateCertificates: true
staticPodPath: /etc/kubernetes/manifests
```

Le même fichier, avec le même `staticPodPath`, existe sur `cka-m02` et `cka-m03` : un worker surveille son dossier de manifestes, simplement vide. `cgroupDriver: systemd` n'est plus qu'une valeur de repli : depuis 1.34 (porte `KubeletCgroupDriverFromCRI`, stable et verrouillée), le kubelet demande le pilote de cgroups au runtime par l'appel CRI `RuntimeConfig` et **ignore** ce champ quand le runtime sait répondre, ce que fait containerd 2.x. Le journal du kubelet du lab le dit au démarrage : `"Using cgroup driver setting received from the CRI runtime" cgroupDriver="systemd"`. Le pilote se règle donc du côté de containerd (`SystemdCgroup = true`, [chapitre 19.2.5](19-kubeadm-installation-ha-et-mises-a-jour.md)), et le désaccord entre kubelet et runtime, cause classique de pannes autrefois, ne peut plus se produire ; seul un runtime qui ignore `RuntimeConfig` (containerd 1.x) fait encore lire ce champ, repli que Kubernetes 1.38 supprimera. `clusterDNS` est l'adresse que le kubelet écrit dans le `/etc/resolv.conf` de chaque pod. La configuration effective, après fusion des options, se lit aussi depuis l'API, sans entrer dans le nœud :

```bash
kubectl get --raw "/api/v1/nodes/cka-m02/proxy/configz" | tr ',' '\n' | grep -E 'staticPodPath|cgroupDriver'
```

Les journaux du kubelet se lisent par `sudo journalctl -u kubelet` dans le nœud (`-f` pour suivre, `--since "10 min ago"` pour borner). C'est le premier endroit où regarder quand un nœud passe `NotReady` ou qu'un pod statique ne démarre pas (chapitre 23).

> [!info] minikube ≠ examen
> Sous kubeadm, le drop-in `10-kubeadm.conf` assemble la ligne de commande à partir de variables, dont `KUBELET_KUBEADM_ARGS` lue dans `/var/lib/kubelet/kubeadm-flags.env` et `KUBELET_EXTRA_ARGS` lue dans `/etc/default/kubelet`. Sur le lab, les options sont **écrites en dur** dans `ExecStart` : `kubeadm-flags.env` existe mais n'est pas lu. Le kubelet est `disabled` sur `cka` (minikube le démarre lui-même) et `enabled` sur les workers, avec `Restart=always` et `RestartSec=600ms`. L'éviction pour manque de disque et le ramasse-miettes d'images sont désactivés (`evictionHard` à `0%`, `imageGCHighThresholdPercent: 100`). Les binaires `kubelet`, `kubeadm` et `kubectl` sont dans `/var/lib/minikube/binaries/v1.37.0/`, hors du `PATH`.

### 2.7 Voir le runtime avec crictl

Quand l'apiserver est tombé, `kubectl` ne voit plus rien ; le runtime, lui, sait toujours ce qui tourne. `crictl` est le client CRI de référence, au même niveau que le kubelet. Il lit son socket dans `/etc/crictl.yaml` (`runtime-endpoint: unix:///run/containerd/containerd.sock` sur le lab) et exige `sudo`, car le socket appartient à root : sans lui, l'erreur est `connect: permission denied`.

| Besoin | crictl (dans le nœud) | Équivalent kubectl |
|---|---|---|
| Lister les sandbox de pods | `sudo crictl pods` | `kubectl get pods -o wide` (filtré sur le nœud) |
| Lister les conteneurs, y compris arrêtés | `sudo crictl ps -a` | `kubectl get pods` + `describe` |
| Trouver un conteneur par nom | `sudo crictl ps --name kube-apiserver -q` | — |
| Lire les journaux | `sudo crictl logs --tail 20 <id>` | `kubectl logs` |
| Détails d'un conteneur, d'un sandbox | `sudo crictl inspect <id>`, `sudo crictl inspectp <id>` | `kubectl get pod -o yaml` |
| Images présentes | `sudo crictl images` | — |
| Consommation | `sudo crictl stats` | `kubectl top` |
| Arrêter un conteneur | `sudo crictl stop <id>` | `kubectl delete pod` (autre effet) |

La colonne `ATTEMPT` de `crictl ps -a` compte les redémarrages d'un conteneur, et un conteneur `Exited` y reste visible avec son code de sortie, là où l'API ne montre plus qu'un `CrashLoopBackOff`. Les journaux sont aussi des fichiers : `/var/log/pods/<namespace>_<pod>_<uid>/<conteneur>/0.log`, avec des liens dans `/var/log/containers/` ([chapitre 21.2.2](21-journaux-et-metriques.md)). `ctr` et `nerdctl` sont présents sur le lab mais parlent à containerd sans passer par CRI : ils voient les conteneurs de Kubernetes dans l'espace de noms containerd `k8s.io`, et rien ne les rend utiles à l'examen. Le chapitre 18.2.3 complète crictl ; le chapitre 23.4.3 s'en sert pour réparer un apiserver.

### 2.8 Le chemin d'une requête dans l'API server

Toute requête, celle de `kubectl` comme celle d'un contrôleur ou d'un kubelet, traverse la même chaîne. Une lecture (`get`, `list`, `watch`) s'arrête après l'autorisation ; une écriture la parcourt jusqu'au bout.

```
Une écriture dans l'API, de bout en bout :
══════════════════════════════════════════

  client (kubectl, contrôleur, kubelet…)
    │  HTTPS
    ▼
  ① AUTHENTIFICATION ── qui es-tu ?          échec → 401 Unauthorized
    │  certificat X.509 (CN = utilisateur, O = groupes), jeton de
    │  ServiceAccount, jeton d'amorçage, OIDC… ; sans identité :
    │  system:anonymous
    ▼
  ② AUTORISATION ────── en as-tu le droit ?  refus → 403 Forbidden
    │  modes essayés dans l'ordre (lab : Node, puis RBAC) ;
    │  le premier qui autorise l'emporte
    ▼
  ③ ADMISSION MUTANTE ─ compléter l'objet
    │  ServiceAccount, LimitRanger, DefaultStorageClass,
    │  DefaultTolerationSeconds…, puis MutatingAdmissionPolicy
    │  et webhooks mutants
    ▼
  ④ VALIDATION ──────── l'objet est-il conforme au schéma ?
    │                                          échec → 422 (Invalid)
    ▼
  ⑤ ADMISSION VALIDANTE ─ l'accepter ?       refus → 403 Forbidden
    │  PodSecurity, ResourceQuota, ValidatingAdmissionPolicy,
    │  webhooks validants
    ▼
  ⑥ ETCD ─────────────── écriture, nouvelle révision
    │                    resourceVersion périmé → 409 Conflict
    ▼
  ⑦ réponse 201/200 au client, et événement ADDED/MODIFIED
     envoyé par le cache de watch à tous les abonnés
```

L'authentification ne décide de rien : elle établit une identité. Un certificat client porte l'utilisateur dans son `CN` et les groupes dans ses `O` ; c'est ainsi que `kubectl` s'identifie sur le lab ([chapitre 16.2](16-rbac-et-authentification.md)). L'autorisation confronte cette identité au verbe, à la ressource et au namespace demandés : le mode **Node** limite chaque kubelet à ce qui concerne son nœud, **RBAC** traite tout le reste. L'admission, enfin, ne concerne que les écritures : elle ne peut ni bloquer ni modifier une lecture.

Kubernetes 1.37 active par défaut les contrôleurs d'admission suivants : `NamespaceLifecycle`, `LimitRanger`, `ServiceAccount`, `TaintNodesByCondition`, `PodSecurity`, `Priority`, `DefaultTolerationSeconds`, `DefaultStorageClass`, `StorageObjectInUseProtection`, `PodGroupProtection`, `PersistentVolumeClaimResize`, `RuntimeClass`, `CertificateApproval`, `CertificateSigning`, `ClusterTrustBundleAttest`, `CertificateSubjectRestriction`, `DefaultIngressClass`, `PodTopologyLabels`, `NodeDeclaredFeatureValidator`, `PodResizeValidator`, `MutatingAdmissionPolicy`, `MutatingAdmissionWebhook`, `ValidatingAdmissionPolicy`, `ValidatingAdmissionWebhook` et `ResourceQuota`. `--enable-admission-plugins` en **ajoute** ; kubeadm y met `NodeRestriction`, qui interdit à un kubelet de modifier les objets d'un autre nœud. Le chapitre 8.12 traite l'admission en détail.

| Code | Étape | Message typique côté kubectl |
|---|---|---|
| 401 | authentification | `error: You must be logged in to the server (Unauthorized)` |
| 403 | autorisation | `Error from server (Forbidden): pods is forbidden: User "alice" cannot list resource "pods" in API group "" in the namespace "boutique"` |
| 403 | admission | `… is forbidden: exceeded quota: …` ou `… violates PodSecurity "baseline:latest": …` |
| 422 | validation | `The Pod "essai" is invalid: spec: Forbidden: pod updates may not change fields other than …` |
| 409 | etcd | `Error from server (AlreadyExists): …` ou `the object has been modified; please apply your changes to the latest version and try again` |
| 404 | lecture | `Error from server (NotFound): pods "x" not found` |

Distinguer un 403 d'autorisation d'un 403 d'admission fait gagner du temps : le premier dit `User "…" cannot …` et se règle dans le RBAC (chapitre 16) ; le second nomme le contrôleur d'admission qui refuse (quota, PodSecurity, webhook) et se règle dans sa politique (chapitre 8). Enfin, `--dry-run=server` fait parcourir à une écriture **toute** la chaîne, admission comprise, sans l'étape ⑥ : c'est le meilleur test d'un manifeste avant de l'appliquer ([chapitre 3.2](03-kubectl-efficace.md)).

### 2.9 Du `kubectl apply` au conteneur

Suivons un Deployment de trois réplicas, de l'appui sur Entrée jusqu'au trafic. Chaque flèche est une écriture dans l'API, observée par le composant suivant grâce à son watch.

```
kubectl apply -f front.yaml  →  trois conteneurs nginx qui reçoivent du trafic
══════════════════════════════════════════════════════════════════════════════

 ① kubectl ── découverte (GVK → ressource), GET de l'objet, calcul du patch
      │       PATCH (ou POST s'il n'existe pas) /apis/apps/v1/namespaces/…/deployments
      ▼
 ② kube-apiserver ── authn, authz, admission, validation ──▶ etcd
      │       /registry/deployments/<ns>/front
      ▼  événement ADDED
 ③ contrôleur Deployment (controller-manager)
      │       crée le ReplicaSet front-<hash> (ownerReference → Deployment)
      ▼  événement ADDED
 ④ contrôleur ReplicaSet
      │       crée 3 Pods front-<hash>-<suffixe> (generateName,
      │       ownerReference → ReplicaSet), spec.nodeName vide
      ▼  événements ADDED (pods non planifiés)
 ⑤ kube-scheduler ── filtre, note, choisit cka-m02
      │       POST pods/front-…/binding  → spec.nodeName = cka-m02
      ▼  événement MODIFIED, vu par le kubelet de cka-m02
 ⑥ kubelet de cka-m02
      │  CRI RunPodSandbox ──▶ containerd : sandbox « pause », netns
      │      └─▶ CNI ADD (Calico) : veth, IP 10.244.x.y
      │  CRI PullImage   ──▶ téléchargement si l'image manque
      │  CRI CreateContainer + StartContainer ──▶ runc
      ▼
 ⑦ kubelet ── sondes ; PATCH pods/…/status : Running, puis Ready
      ▼  événement MODIFIED
 ⑧ contrôleur EndpointSlice ── ajoute l'IP prête aux EndpointSlices
      │       des Services dont le sélecteur choisit ce pod
      ▼
 ⑨ kube-proxy de CHAQUE nœud ── règles iptables mises à jour :
          l'IP du Service mène désormais à ce pod
```

Quatre leçons en découlent. **Personne ne se parle directement** : le scheduler ignore le kubelet, le contrôleur Deployment ignore le scheduler ; ils se coordonnent par les objets. **Chaque étape laisse une trace** : les événements `ScalingReplicaSet` (Deployment), `SuccessfulCreate` (ReplicaSet), `Scheduled` (scheduler), `Pulling`, `Pulled`, `Created`, `Started` (kubelet). Un pod bloqué se diagnostique donc en cherchant **la dernière trace écrite** : pas de `Scheduled`, regarde le scheduler ; `Scheduled` mais pas de `Pulled`, regarde l'image ou le nœud. **Une étape en panne n'arrête que la suite** : sans scheduler, Deployment et ReplicaSet existent, les pods aussi, mais en `Pending`. **Le chemin est asynchrone** : `kubectl apply` rend la main après l'étape ②, quand rien ne tourne encore ; d'où `kubectl rollout status` et `kubectl wait` (chapitres 5.5 et 3.9.2).

```bash
kubectl create deployment demo --image=nginx:1.30.6-alpine --replicas=3
kubectl events --for deployment/demo
kubectl events | tail -20
kubectl delete deployment demo
```

### 2.10 Boucles de contrôle, watch et resourceVersion

#### 2.10.1 Informers et réconciliation

Un contrôleur ne relit pas l'API en boucle. Il maintient, par un **informer**, une copie locale des objets qui l'intéressent : un *reflector* fait d'abord un `list` complet, puis ouvre un `watch` à partir de la `resourceVersion` de cette liste, et applique chaque événement reçu à son cache. Chaque événement place la clé de l'objet (`namespace/nom`) dans une file de travail ; des workers la dépilent et appellent la fonction de réconciliation.

```
Anatomie d'un contrôleur :
══════════════════════════

  kube-apiserver ── LIST, puis WATCH depuis resourceVersion=N ──┐
                                                                ▼
                       ┌─────────────── informer ────────────────┐
                       │ reflector ──▶ cache local (indexé)      │
                       │     └──▶ gestionnaires d'événements     │
                       └─────────────────────┬───────────────────┘
                                             │ clé « boutique/front »
                                             ▼
                                  file de travail (dédoublonnée,
                                  reprise avec délai en cas d'erreur)
                                             │
                                             ▼
                        réconcilier(clé) : lire l'état désiré et l'état
                        observé DANS LE CACHE, calculer l'écart, écrire
                        dans l'API ce qui le réduit
```

La réconciliation est **déclenchée par le niveau, pas par le front** : la fonction ne s'intéresse pas à l'événement qui l'a réveillée (« un pod a été supprimé »), elle compare l'état complet (« il en faut trois, j'en vois deux »). Un événement perdu ou deux événements fusionnés ne changent donc rien au résultat, et un contrôleur redémarré retrouve son chemin en relisant tout. C'est aussi pourquoi tu ne « répares » jamais à la main un objet géré : supprime un pod d'un ReplicaSet, un autre apparaît ; modifie un ReplicaSet géré par un Deployment, le Deployment le remet d'aplomb.

Plusieurs écrivains peuvent viser le même objet. L'API les départage par **concurrence optimiste** : une mise à jour (`PUT`) porte la `resourceVersion` lue ; si l'objet a changé entre-temps, etcd refuse et l'apiserver répond `409 Conflict` avec le message `the object has been modified; please apply your changes to the latest version and try again`. Le contrôleur relit et recommence. Tu croiseras ce message dans les événements de composants bavards ; il n'est grave que s'il persiste.

#### 2.10.2 resourceVersion et generation

La `resourceVersion` d'un objet est la révision d'etcd de sa dernière modification. Pour l'API, c'est une chaîne opaque que le client renvoie telle quelle ; depuis 1.35, la conformité exige qu'elle soit ordonnable comme un entier croissant au sein d'un même type de ressource. Une liste porte aussi sa propre `resourceVersion` dans `metadata` : la révision à laquelle elle a été construite, point de départ naturel d'un watch.

À ne pas confondre avec `metadata.generation`, que l'apiserver n'incrémente que lorsque la **spec** change (pas les labels, pas le status). Le contrôleur recopie la génération qu'il a traitée dans `status.observedGeneration` : tant que les deux diffèrent, la dernière demande n'a pas encore été prise en compte. Les Deployments, StatefulSets et DaemonSets l'utilisent depuis toujours ; les Pods ont `metadata.generation` et `status.observedGeneration` depuis 1.35.

#### 2.10.3 Le watch, son historique et le code 410

Un watch est une requête `GET` longue (`?watch=1&resourceVersion=N`) dont la réponse est un flux de documents JSON : `{"type":"ADDED","object":{…}}`, puis `MODIFIED`, `DELETED`, et éventuellement `BOOKMARK` (un repère qui ne porte que la `resourceVersion` atteinte, pour que le client puisse reprendre plus loin) ou `ERROR`. Le flux reprend exactement après la révision demandée : aucune modification ne se perd entre le `list` et le `watch`. L'apiserver coupe volontairement chaque watch au bout d'une durée tirée au hasard au-dessus de `--min-request-timeout` (1 800 s par défaut) ; le client se reconnecte à partir de la dernière révision reçue.

Cette reprise n'est possible que si l'historique existe encore. Comme l'apiserver fait compacter etcd toutes les 5 minutes, un client qui redemande une révision trop ancienne reçoit `410 Gone` (`too old resource version`) ; il doit alors refaire un `list` complet et repartir de sa révision. Les bookmarks réduisent ce risque pour les clients qui suivent des ressources peu actives. Depuis 1.32, un client peut aussi demander l'état initial dans le watch lui-même (`sendInitialEvents=true`, feature `WatchList`, en bêta) plutôt que par un gros `list`.

#### 2.10.4 Le cache de watch et ses conséquences

L'apiserver ne relaie pas les watch d'etcd un par un : il tient un seul watch par type vers etcd et sert tous ses clients depuis son **cache de watch**. Depuis 1.34 (*ConsistentListFromCache*, GA), il sert aussi depuis ce cache les `list` qui demandent les données les plus récentes, après s'être assuré auprès d'etcd que le cache a rattrapé la révision courante ; la lecture d'un objet unique par son nom, elle, interroge etcd. En temps normal, cette différence est invisible. Elle devient spectaculaire après une restauration d'etcd vers une révision plus ancienne : sur le lab, après restauration, `kubectl get cm temoin-apres` répondait `NotFound` (lecture dans etcd) pendant que `kubectl get cm` listait encore `temoin-apres` (cache figé sur une révision plus récente que celle d'etcd). Le chapitre 20.7.2 explique pourquoi `etcdutl snapshot restore --bump-revision … --mark-compacted` évite ce piège.

> [!note]
> `kubectl get -w` est un watch, `kubectl get` un list, `kubectl get <nom>` un get. Avec `-v=6`, kubectl journalise chaque requête HTTP et son code, sous la forme `"Response" verb="GET" url="https://192.168.49.2:8443/api/v1/namespaces/default/configmaps?limit=500" status="200 OK"` ; avec `-w`, une seconde requête porte `resourceVersion=…&watch=true`. C'est la meilleure façon de voir ce qui précède en action (exercice 2.6).

### 2.11 Élection de leader et Leases

Plusieurs apiservers peuvent servir en même temps, puisqu'ils sont sans état. Deux schedulers actifs, en revanche, placeraient le même pod deux fois, et deux contrôleurs ReplicaSet créeraient deux fois les pods manquants. Sur un control plane hautement disponible (chapitre 19.4), le scheduler et le controller-manager pratiquent donc l'**élection de leader** : chaque instance tente d'acquérir un verrou dans l'API, un objet **Lease** (`coordination.k8s.io/v1`) du namespace `kube-system`, nommé `kube-scheduler` ou `kube-controller-manager`. Celle qui le détient travaille ; les autres attendent.

| Champ ou option | Valeur par défaut | Sens |
|---|---|---|
| `spec.holderIdentity` | `<nœud>_<uuid>` | instance qui détient le verrou |
| `--leader-elect` | `true` | élection activée |
| `--leader-elect-lease-duration` | 15 s | délai après lequel un verrou non renouvelé est repris |
| `--leader-elect-renew-deadline` | 10 s | délai pendant lequel le leader tente de renouveler avant d'abandonner |
| `--leader-elect-retry-period` | 2 s | intervalle entre deux tentatives |

Un leader qui meurt est donc remplacé en une quinzaine de secondes. Corollaire de dépannage : sur un control plane à trois nœuds, un scheduler cassé qui n'était **pas** leader ne produit aucun symptôme, jusqu'au jour où il le devient. L'élection « coordonnée » (*CoordinatedLeaderElection*, objets `LeaseCandidate`), qui choisit le leader de plus basse version pendant une mise à jour, est en bêta et **désactivée** par défaut en 1.37.

Les Leases servent à deux autres choses. Chaque kube-apiserver publie la sienne dans `kube-system`, nommée `apiserver-<hachage>` et portant le label `apiserver.kubernetes.io/identity=kube-apiserver` (*APIServerIdentity*, bêta activée depuis 1.26) : on peut ainsi compter les apiservers vivants. Et chaque kubelet renouvelle toutes les 10 secondes la Lease de son nœud dans `kube-node-lease` (`leaseDurationSeconds: 40`). Le contrôleur des nœuds vérifie leur fraîcheur toutes les 5 secondes (`--node-monitor-period`) ; au-delà de 50 secondes sans nouvelles (`--node-monitor-grace-period`), il passe la condition `Ready` du nœud à `Unknown` et pose les taints `node.kubernetes.io/unreachable:NoSchedule` et `:NoExecute`. Les pods y tolèrent `NoExecute` pendant 300 secondes (tolérance ajoutée par l'admission `DefaultTolerationSeconds`) avant d'être évincés. Sur le lab, l'arrêt du kubelet de `cka-m03` a rendu le nœud `NotReady` en 44 secondes, 52 secondes après le dernier renouvellement de sa Lease ; le chapitre 23 en fait la panne 13.

> [!info] minikube ≠ examen
> Le lab passe `--leader-elect=false` au scheduler et au controller-manager : avec une seule instance, l'élection est inutile, et ces composants ne créent **aucune** Lease. `kubectl -n kube-system get lease kube-scheduler` y répond `NotFound`, alors que sur un cluster kubeadm, même à un seul control plane, les deux Leases existent et montrent leur détenteur. Les Leases des nœuds et celle de l'apiserver, elles, existent partout.

### 2.12 Anatomie d'un objet

Tout objet persistant de l'API a la même forme : `apiVersion` et `kind` désignent son type, `metadata` l'identifie et le relie aux autres, `spec` porte l'état désiré écrit par l'utilisateur, `status` l'état observé écrit par les contrôleurs. Les objets sans comportement, ConfigMap ou Secret, n'ont ni `spec` ni `status` mais des `data`. `status` est une **sous-ressource** distincte : un `PUT` sur l'objet ignore les changements de `status`, un `PUT` sur `…/status` ignore ceux de `spec`. C'est ce qui empêche un utilisateur et un contrôleur d'écraser mutuellement leurs écritures.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: demo-7c9d8f6b5-x2k4q           # unique par namespace et par type
  generateName: demo-7c9d8f6b5-         # préfixe : le serveur a complété le nom
  namespace: default
  uid: 3f0c2b7e-6a1d-4c55-9a51-0d7f6e2a8c11   # unique dans le temps et l'espace
  resourceVersion: "48211"             # révision etcd de la dernière écriture
  generation: 1                        # incrémenté à chaque changement de spec
  creationTimestamp: "2026-10-23T18:40:12Z"
  labels:                              # identifiants, sélectionnables
    app: demo
    pod-template-hash: 7c9d8f6b5
  annotations:                         # métadonnées libres, non sélectionnables
    kubernetes.io/description: "exemple"
  ownerReferences:                     # qui me possède (2.13)
  - apiVersion: apps/v1
    kind: ReplicaSet
    name: demo-7c9d8f6b5
    uid: 0b1e9a62-1f3a-4d2e-8c7f-5a6b7c8d9e0f
    controller: true
    blockOwnerDeletion: true
spec:
  containers:
  - name: nginx
    image: nginx:1.30.6-alpine
status:
  phase: Running
```

Ces valeurs sont des exemples ; la forme, elle, est celle de tout objet. Il y manque deux champs qui n'apparaissent qu'en situation : `deletionTimestamp` (2.13) et `finalizers`, ainsi que `managedFields`, que `kubectl get -o yaml` masque par défaut (chapitre 3).

#### 2.12.1 Noms

Un nom est unique pour un type et un namespace donnés, et seulement là : un Service et un Deployment peuvent s'appeler `front` tous les deux. L'`uid`, lui, est unique pour toute la vie du cluster : un objet supprimé puis recréé sous le même nom est un autre objet, et tout ce qui le référençait par `uid` (une `ownerReference`, une liaison `claimRef`) ne le reconnaît pas. La plupart des types exigent un nom de **sous-domaine DNS** (253 caractères au plus, minuscules, chiffres, `-` et `.`, commençant et finissant par un alphanumérique) ; les namespaces, les Services et quelques autres exigent un **label DNS** de 63 caractères au plus, sans point. Depuis 1.37 (*RelaxedServiceNameValidation*, GA), un nom de Service peut commencer par un chiffre. `generateName` demande au serveur de compléter un préfixe par un suffixe aléatoire ; `kubectl create -f` l'accepte, `kubectl apply` le refuse (`cannot use generate name with apply`), car il lui faut un nom pour retrouver l'objet à la fois suivante.

#### 2.12.2 Labels et annotations

Les **labels** identifient : on les sélectionne (`-l app=front`), et c'est par eux que les Services trouvent leurs pods, les ReplicaSets leurs réplicas, les NetworkPolicies leurs cibles. Les **annotations** décrivent : on ne peut pas les sélectionner, mais elles portent de l'information pour les outils (`kubernetes.io/change-cause`, `kubectl.kubernetes.io/last-applied-configuration`, configuration d'un contrôleur d'Ingress).

Les clés des deux ont la même syntaxe : un préfixe facultatif, sous-domaine DNS de 253 caractères au plus, une barre oblique, puis un nom obligatoire de 63 caractères au plus, commençant et finissant par un alphanumérique, avec `-`, `_` et `.` à l'intérieur. Les préfixes `kubernetes.io/` et `k8s.io/` sont réservés aux composants de Kubernetes ; une clé sans préfixe est réputée privée à l'utilisateur. Une **valeur** de label fait 63 caractères au plus et peut être vide (`node-role.kubernetes.io/control-plane=` sur `cka`) ; une valeur d'annotation n'a pas de limite propre, mais l'ensemble des annotations d'un objet ne doit pas dépasser 256 Kio. Le projet recommande la famille `app.kubernetes.io/*` (`name`, `instance`, `version`, `component`, `part-of`, `managed-by`) ; le cours utilise plus simplement `app` et `tier`.

### 2.13 Propriétaires, cascade et finalizers

#### 2.13.1 ownerReferences

Un objet qui en a créé un autre l'inscrit comme propriétaire dans ses `metadata.ownerReferences` : Deployment → ReplicaSet → Pod, Job → Pod, CronJob → Job, DaemonSet → Pod, Service → EndpointSlice, Node → mirror pod. Une référence nomme l'`apiVersion`, le `kind`, le `name` et l'`uid` du propriétaire ; `controller: true` désigne le propriétaire gestionnaire (un seul par objet), `blockOwnerDeletion: true` autorise ce dépendant à retarder la suppression de son propriétaire en mode *foreground*. Les références traversant les namespaces sont interdites : un dépendant namespacé ne peut avoir pour propriétaire qu'un objet du même namespace ou un objet global, et un objet global ne peut avoir qu'un propriétaire global. Une référence invalide est traitée comme absente, et le ramasse-miettes signale le cas par un événement `OwnerRefInvalidNamespace`.

Les labels et les propriétaires ne servent pas à la même chose. Le ReplicaSet **trouve** ses pods par son sélecteur de labels ; il les **possède** par leur `ownerReference`. Un pod nu qui porte les bons labels est adopté par un ReplicaSet dont le sélecteur le désigne ; un pod dont on change les labels est relâché (son `ownerReference` retirée) et remplacé.

#### 2.13.2 Les trois modes de suppression

Le contrôleur **garbage collector** du controller-manager supprime les objets dont tous les propriétaires ont disparu. Quand tu supprimes un propriétaire, tu choisis ce qu'il advient des dépendants :

| Mode | `kubectl delete --cascade=` | Ce qui se passe |
|---|---|---|
| Background (défaut) | `background` | Le propriétaire disparaît aussitôt ; le ramasse-miettes supprime ensuite les dépendants |
| Foreground | `foreground` | Le propriétaire reçoit `deletionTimestamp` et le finalizer `foregroundDeletion` ; il reste visible jusqu'à la suppression des dépendants marqués `blockOwnerDeletion` |
| Orphan | `orphan` | Le finalizer `orphan` retire les `ownerReferences` des dépendants, puis le propriétaire disparaît ; les dépendants survivent, orphelins |

Le mode `orphan` sert à remplacer un contrôleur sans toucher à ses pods : un Deployment recréé avec le même sélecteur et le même modèle **adopte** le ReplicaSet orphelin au lieu d'en créer un autre (exercice 2.7).

#### 2.13.3 Finalizers

Un **finalizer** est une clé dans `metadata.finalizers` qui interdit la suppression effective d'un objet tant qu'un contrôleur n'a pas fait son ménage. Quand on supprime un objet qui en porte, l'apiserver ne l'efface pas : il pose `metadata.deletionTimestamp`, répond `202 Accepted`, et l'objet reste visible, en état « Terminating » pour les pods, namespaces et volumes. Le contrôleur responsable fait son travail puis retire sa clé ; quand la liste est vide, l'apiserver efface l'objet. Une fois `deletionTimestamp` posé, on peut retirer des finalizers mais plus en ajouter, ni annuler la suppression.

| Finalizer | Posé sur | Retenu tant que |
|---|---|---|
| `kubernetes.io/pvc-protection` | PersistentVolumeClaim | un pod utilise la PVC ([chapitre 15.5](15-stockage.md)) |
| `kubernetes.io/pv-protection` | PersistentVolume | le PV est lié à une PVC |
| `kubernetes` (dans `spec.finalizers`) | Namespace | le contrôleur de namespace n'a pas supprimé tout son contenu (2.15) |
| `foregroundDeletion`, `orphan` | tout propriétaire | la suppression en cascade correspondante n'est pas terminée |

Un objet « bloqué en Terminating » est presque toujours un finalizer dont le contrôleur est absent ou en échec : un opérateur désinstallé avant ses ressources, un webhook injoignable, un volume encore monté. On lit `metadata.finalizers` et `deletionTimestamp`, on cherche pourquoi le contrôleur ne termine pas, et on ne retire le finalizer à la main (`kubectl patch … --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'`) qu'après avoir fait soi-même le ménage qu'il protégeait. Les finalizers personnels doivent porter un nom qualifié par un domaine (`boutique.example/blocage`).

> [!warning]
> `kubectl delete` attend par défaut la disparition effective de l'objet (`--wait=true`) : sur un objet retenu par un finalizer, la commande ne rend jamais la main. `--wait=false` rend la main dès que `deletionTimestamp` est posé.

### 2.14 Groupes, versions et ressources de l'API

L'API est découpée en **groupes**, chacun servi en une ou plusieurs **versions**. Le groupe historique, dit *core* ou *legacy*, vit sous `/api/v1` et ne s'écrit pas dans `apiVersion` (`apiVersion: v1` pour Pod, Service, ConfigMap, Secret, Node, Namespace, PersistentVolume…). Les autres vivent sous `/apis/<groupe>/<version>` et s'écrivent `groupe/version` : `apps/v1` (Deployment, StatefulSet, DaemonSet, ReplicaSet), `batch/v1` (Job, CronJob), `networking.k8s.io/v1` (Ingress, NetworkPolicy), `rbac.authorization.k8s.io/v1`, `storage.k8s.io/v1`, `coordination.k8s.io/v1` (Lease), `policy/v1` (PodDisruptionBudget)… Un chemin complet nomme la ressource au pluriel et en minuscules : `/apis/apps/v1/namespaces/boutique/deployments/front`.

On distingue le **kind** (`Deployment`, la forme de l'objet) de la **ressource** (`deployments`, l'URL qui le sert). La plupart des kinds ont une ressource, mais des ressources n'ont pas de kind propre : les **sous-ressources**, qui ont leur URL et leurs droits RBAC.

| Sous-ressource | Rôle | Utilisée par |
|---|---|---|
| `status` | état observé, écrit séparément de la spec | contrôleurs, kubelet |
| `scale` | nombre de réplicas | `kubectl scale`, HPA |
| `binding` | affectation d'un pod à un nœud | scheduler |
| `eviction` | éviction respectant les PodDisruptionBudgets | `kubectl drain` |
| `log`, `exec`, `attach`, `portforward` | accès aux conteneurs via le kubelet | `kubectl logs`, `exec`… |
| `ephemeralcontainers` | conteneurs de débogage | `kubectl debug` |
| `resize` | redimensionnement en place (GA 1.35) | `kubectl patch --subresource resize` |
| `token` (de `serviceaccounts`) | jeton lié à durée limitée | `kubectl create token` |

`kubectl api-resources` liste ce que sert **ce** cluster (colonnes `NAME`, `SHORTNAMES`, `APIVERSION`, `NAMESPACED`, `KIND`) ; `kubectl api-versions` liste les couples groupe/version. Les CRD et les API agrégées y apparaissent comme les ressources intégrées : c'est la même découverte, que kubectl met en cache dans `~/.kube/cache/discovery`.

| Niveau | Nom de version | Activé par défaut | Engagement |
|---|---|---|---|
| Alpha | `v1alpha1`… | non | peut changer ou disparaître sans préavis |
| Bêta | `v1beta1`… | non pour les API bêta apparues depuis 1.22 ; oui pour les plus anciennes | dépréciation au plus tard 9 mois ou 3 versions après son arrivée, suppression 9 mois ou 3 versions après la dépréciation |
| Stable | `v1`, `v2` | oui | reste servie pour toute la version majeure de Kubernetes |

Une ressource servie en plusieurs versions est **un seul objet** : etcd le stocke dans une version de stockage, et l'apiserver le convertit à la volée dans la version demandée. On peut donc lire en `v1` un objet créé en `v1beta1`, tant que les deux sont servies. Quand une version est retirée, ce sont les manifestes et les outils qui cassent, pas les objets stockés. Avant une mise à jour de cluster, on vérifie donc que ses manifestes n'utilisent plus d'API supprimée (chapitre 19).

### 2.15 Namespaces

Un namespace est une portée de noms et un périmètre d'application : RBAC (Role, RoleBinding), quotas (ResourceQuota, LimitRange), Pod Security Admission et la plupart des NetworkPolicies s'appliquent par namespace. Ce n'est **pas** une frontière réseau : sans NetworkPolicy, un pod joint tout pod de tout namespace ([chapitre 14.1](14-network-policies.md)). Les namespaces ne s'emboîtent pas, et certains objets n'appartiennent à aucun : Node, PersistentVolume, StorageClass, Namespace lui-même, ClusterRole, CustomResourceDefinition, IngressClass… `kubectl api-resources --namespaced=false` en donne la liste exacte.

| Namespace initial | Contenu |
|---|---|
| `default` | les objets créés sans namespace ; le Service `kubernetes` (10.96.0.1) |
| `kube-system` | les composants du système : mirror pods du control plane, kube-proxy, CoreDNS, Calico sur le lab |
| `kube-public` | lisible par tous, même sans authentification ; kubeadm y publie la ConfigMap `cluster-info` |
| `kube-node-lease` | une Lease par nœud, les battements de cœur des kubelets |

Un nom de namespace est un label DNS (63 caractères au plus), car il entre dans les noms DNS des Services : `api.boutique.svc.cluster.local`. Évite le préfixe `kube-`, réservé au système. Depuis 1.22, chaque namespace porte automatiquement le label `kubernetes.io/metadata.name: <nom>` : c'est lui qu'on sélectionne dans une NetworkPolicy pour désigner un namespace par son nom (chapitre 14.4).

Supprimer un namespace supprime **tout** ce qu'il contient. L'objet passe en phase `Terminating` et reste visible tant que le contrôleur de namespace n'a pas effacé chaque objet, puis retiré le finalizer `kubernetes` de `spec.finalizers`. Pendant ce temps, l'admission `NamespaceLifecycle` refuse toute création dans ce namespace. Un namespace bloqué en `Terminating` cache presque toujours un objet retenu par son propre finalizer, ou une API agrégée indisponible qui empêche de lister certains types : `kubectl get namespace <nom> -o yaml` affiche, dans `status.conditions`, la raison exacte.

### 2.16 Pièges courants

```
Piège 1 : Laisser une copie de manifeste dans manifests/
════════════════════════════════════════════════════════
  MAUVAIS  : sudo cp kube-scheduler.yaml kube-scheduler.yaml.bak
             (dans /etc/kubernetes/manifests)
  SYMPTÔME : deux pods de même nom, comportement indéfini ; la vieille
             copie peut reprendre la main après ta correction.
  BON      : sudo cp kube-scheduler.yaml /root/kube-scheduler.yaml.orig

Piège 2 : Supprimer le mirror pod pour « redémarrer » un composant
═══════════════════════════════════════════════════════════════════
  MAUVAIS  : kubectl -n kube-system delete pod kube-apiserver-cka
  SYMPTÔME : le pod réapparaît aussitôt, rien n'a redémarré, la
             nouvelle option du manifeste n'est toujours pas prise.
  BON      : modifier le manifeste (le kubelet recrée le pod), ou sortir
             le fichier du dossier puis le remettre.

Piège 3 : Chercher un événement FailedScheduling sans scheduler
════════════════════════════════════════════════════════════════
  SYMPTÔME : pods Pending, « Events: <none> ».
  CAUSE    : c'est le scheduler qui écrit FailedScheduling ; absent, il
             n'écrit rien.
  BON      : kubectl -n kube-system get pods -l component=kube-scheduler,
             puis crictl et journal du kubelet sur le control plane.

Piège 4 : Recopier le port de l'API entre lab et examen
═══════════════════════════════════════════════════════
  MAUVAIS  : https://<ip>:8443 sur un cluster kubeadm, ou :6443 sur le lab.
  SYMPTÔME : connection refused.
  BON      : lire --secure-port dans le manifeste de l'apiserver, ou
             kubectl config view --minify.

Piège 5 : kubectl delete qui ne rend jamais la main
═══════════════════════════════════════════════════
  CAUSE    : un finalizer retient l'objet ; --wait=true attend sa
             disparition.
  BON      : Ctrl+C (la suppression est déjà demandée), puis lire
             metadata.finalizers et le contrôleur responsable ;
             --wait=false pour ne pas bloquer.

Piège 6 : Chercher les Leases kube-scheduler sur le lab
═══════════════════════════════════════════════════════
  SYMPTÔME : NotFound sur minikube.
  CAUSE    : --leader-elect=false.
  BON      : sur un cluster kubeadm, elles existent ; sur le lab, les
             Leases utiles sont celles de kube-node-lease.

Piège 7 : Confondre resourceVersion et generation
═════════════════════════════════════════════════
  MAUVAIS  : « la resourceVersion a changé, le Deployment a donc
             été mis à jour ».
  BON      : resourceVersion change à chaque écriture (labels, status
             compris) ; generation seulement quand la spec change, et
             observedGeneration dit si le contrôleur l'a traitée.
```

> [!summary] À retenir
> - L'apiserver est le seul client d'etcd et le seul point de rencontre : tous les autres composants observent l'API par des watch et y écrivent leurs décisions.
> - Le control plane kubeadm tourne en pods statiques sous `/etc/kubernetes/manifests` ; le kubelet, seul service systemd, les lance sans API et publie des mirror pods `<nom>-<nœud>`, propriétés de l'objet Node.
> - Modifier un manifeste statique redéploie le composant ; supprimer son mirror pod ne fait rien ; une copie `.bak` dans le dossier est chargée, un fichier commençant par un point est ignoré.
> - Ports : apiserver 6443 (8443 sur le lab), etcd 2379/2380/2381, scheduler 10259, controller-manager 10257, kubelet 10250 et 10248, kube-proxy 10256 et 10249, NodePort 30000-32767.
> - Une écriture traverse authentification (401), autorisation (403), admission mutante, validation (422), admission validante (403), puis etcd (409) ; une lecture s'arrête après l'autorisation.
> - Un pod naît d'une chaîne Deployment → ReplicaSet → Pod → binding → kubelet → CRI → CNI : le diagnostic consiste à trouver la dernière étape qui a laissé un événement.
> - Les contrôleurs réconcilient sur l'état complet, pas sur l'événement ; un watch reprend depuis une `resourceVersion`, et `410 Gone` impose de relister.
> - Les Leases portent l'élection de leader (désactivée sur le lab), l'identité des apiservers et les battements des nœuds (40 s de bail, 50 s de grâce avant `NotReady`).
> - Les `ownerReferences` pilotent la suppression en cascade (`background` par défaut, `foreground`, `orphan`) ; un finalizer retient un objet en « Terminating » jusqu'à ce que son contrôleur le retire.
> - Un même objet est servi dans plusieurs versions d'API ; les namespaces isolent noms, droits et quotas, pas le réseau.

### 2.17 Exercices

#### Exercice 2.1 — Inventaire du control plane

**Point de départ** : instantané I0.

Dresse l'inventaire du namespace `kube-system`. Affiche, pour chaque pod, son nom, le `kind` de son propriétaire gestionnaire et son nœud, puis désigne les pods statiques. Dans le nœud `cka`, liste les manifestes statiques et affiche l'image et le port sécurisé de l'apiserver tels que le manifeste les déclare. Enfin, affiche les annotations `kubernetes.io/config.*` du mirror pod de l'apiserver.

> [!example]- Solution
> ```bash
> kubectl -n kube-system get pods \
>   -o custom-columns='POD:.metadata.name,PROPRIETAIRE:.metadata.ownerReferences[?(@.controller==true)].kind,NOEUD:.spec.nodeName'
> ```
>
> ```
> POD                                       PROPRIETAIRE   NOEUD
> calico-kube-controllers-db57f7644-sxwdz   ReplicaSet     cka
> calico-node-hw89l                         DaemonSet      cka-m02
> calico-node-j7vrk                         DaemonSet      cka-m03
> calico-node-sw48x                         DaemonSet      cka
> coredns-559f6c778d-kkpc5                  ReplicaSet     cka
> etcd-cka                                  Node           cka
> kube-apiserver-cka                        Node           cka
> kube-controller-manager-cka               Node           cka
> kube-proxy-jpwgc                          DaemonSet      cka
> …
> kube-scheduler-cka                        Node           cka
> storage-provisioner                       <none>         cka
> ```
>
> Les suffixes aléatoires diffèrent d'un cluster à l'autre. Les quatre pods possédés par un `Node` sont les pods statiques ; `storage-provisioner` est un pod nu de minikube, sans propriétaire, que rien ne recréerait. On complète dans le nœud :
>
> ```bash
> minikube -p cka ssh
> sudo ls -l /etc/kubernetes/manifests
> sudo grep -E 'image:|--secure-port' /etc/kubernetes/manifests/kube-apiserver.yaml
> exit
> kubectl -n kube-system get pod kube-apiserver-cka -o jsonpath='{.metadata.annotations}{"\n"}'
> ```
>
> Le dossier contient `etcd.yaml`, `kube-apiserver.yaml`, `kube-controller-manager.yaml` et `kube-scheduler.yaml`, en `-rw-------` root. Le manifeste déclare `--secure-port=8443` et l'image `registry.k8s.io/kube-apiserver:v1.37.0`. Les annotations contiennent `kubernetes.io/config.mirror`, `kubernetes.io/config.hash` (même valeur), `kubernetes.io/config.source` à `file` et `kubernetes.io/config.seen`.
>
> **Vérification** : `kubectl -n kube-system get pods -l tier=control-plane -o name` renvoie exactement les quatre pods `etcd-cka`, `kube-apiserver-cka`, `kube-controller-manager-cka` et `kube-scheduler-cka` : kubeadm leur pose les labels `component=<nom>` et `tier=control-plane`.

#### Exercice 2.2 — Le kubelet de deux nœuds

**Point de départ** : exercice 2.1.

Compare le kubelet de `cka` et celui de `cka-m02` : état de l'unité systemd (`is-enabled`, `is-active`), ligne de commande complète, et valeurs de `staticPodPath`, `cgroupDriver` et `clusterDNS` dans leur fichier de configuration. Retrouve ensuite `staticPodPath` de `cka-m02` sans entrer dans le nœud. Dis enfin quelles options seraient lues dans `kubeadm-flags.env` sur un cluster kubeadm, et si c'est le cas ici.

> [!example]- Solution
> ```bash
> minikube -p cka ssh
> systemctl is-enabled kubelet; systemctl is-active kubelet
> systemctl cat kubelet | grep -E '^ExecStart=.+|EnvironmentFile'
> sudo grep -E 'staticPodPath|cgroupDriver|clusterDNS' -A1 /var/lib/kubelet/config.yaml
> sudo cat /var/lib/kubelet/kubeadm-flags.env
> exit
> minikube -p cka ssh -n cka-m02
> systemctl is-enabled kubelet; systemctl is-active kubelet
> sudo grep -E 'staticPodPath|cgroupDriver' /var/lib/kubelet/config.yaml
> exit
> ```
>
> Sur `cka`, l'unité est `disabled` mais `active` : minikube démarre lui-même le kubelet du control plane. Sur `cka-m02`, elle est `enabled` et `active`. La ligne `ExecStart=` du drop-in porte toutes les options en dur (`--config=/var/lib/kubelet/config.yaml`, `--hostname-override`, `--kubeconfig=/etc/kubernetes/kubelet.conf`, `--node-ip`), et `grep EnvironmentFile` ne renvoie rien : `kubeadm-flags.env`, qui contient `KUBELET_KUBEADM_ARGS="--node-ip=192.168.49.2"`, n'est pas lu. Sur un cluster kubeadm, le drop-in lirait ce fichier et `/etc/default/kubelet`. Les deux nœuds ont `staticPodPath: /etc/kubernetes/manifests`, `cgroupDriver: systemd` et `clusterDNS` à `10.96.0.10`.
>
> ```bash
> kubectl get --raw "/api/v1/nodes/cka-m02/proxy/configz" | tr ',' '\n' | grep -E 'staticPodPath|cgroupDriver'
> ```
>
> **Vérification** : la dernière commande affiche `"staticPodPath":"/etc/kubernetes/manifests"` et `"cgroupDriver":"systemd"`, lus par l'apiserver dans le kubelet de `cka-m02`.

#### Exercice 2.3 — Ce que voit le runtime

**Point de départ** : exercice 2.2.

Dans le nœud `cka`, avec `crictl` : liste les sandbox de pods du namespace `kube-system`, trouve l'identifiant du conteneur `kube-scheduler`, affiche ses cinq dernières lignes de journal, et donne l'image du sandbox (*pause*) utilisée par containerd. Compare enfin le nombre de conteneurs en cours d'exécution vu par `crictl` avec celui que `kubectl` attribue au nœud `cka`.

> [!example]- Solution
> ```bash
> minikube -p cka ssh
> sudo crictl pods --namespace kube-system
> CID=$(sudo crictl ps --name kube-scheduler -q)
> sudo crictl logs --tail 5 "$CID"
> sudo crictl images | grep pause
> sudo crictl ps -q | wc -l
> exit
> kubectl get pods -A --field-selector spec.nodeName=cka \
>   -o jsonpath='{range .items[*]}{range .status.containerStatuses[?(@.started==true)]}{.name}{"\n"}{end}{end}' | wc -l
> ```
>
> `crictl pods --namespace kube-system` montre un sandbox `Ready` par pod de `kube-system` placé sur `cka`, dont les quatre pods statiques. Le journal du scheduler est celui que donnerait `kubectl -n kube-system logs kube-scheduler-cka --tail 5`. La ligne `pause` montre `registry.k8s.io/pause` en `3.10.2`. Les deux comptes coïncident : chaque conteneur démarré d'un pod placé sur `cka` est un conteneur `Running` pour containerd ; un éventuel écart d'une unité vient d'un conteneur en cours de (re)démarrage au moment de la mesure.
>
> **Vérification** : `sudo crictl ps --name kube-scheduler` (dans le nœud) affiche une ligne `Running` dont la colonne `POD` vaut `kube-scheduler-cka`.

#### Exercice 2.4 — Ports et points de santé

**Point de départ** : exercice 2.3.

Dans le nœud `cka`, identifie les ports en écoute de l'apiserver, d'etcd, du scheduler, du controller-manager, du kubelet et de kube-proxy, avec leur adresse d'écoute. Interroge ensuite sans certificat client : `/healthz` du controller-manager, `/livez` du scheduler, `/healthz` du kubelet et `/readyz` de l'apiserver. Explique pourquoi ces requêtes anonymes aboutissent. Depuis le poste, interroge enfin `/readyz?verbose` de l'apiserver avec kubectl.

> [!example]- Solution
> ```bash
> minikube -p cka ssh
> sudo ss -ltnp | grep -E 'kube|etcd'
> curl -sk https://127.0.0.1:10257/healthz; echo
> curl -sk https://127.0.0.1:10259/livez; echo
> curl -s http://127.0.0.1:10248/healthz; echo
> curl -sk https://127.0.0.1:8443/readyz; echo
> exit
> kubectl get --raw '/readyz?verbose' | tail -3
> ```
>
> `ss` doit montrer `kube-apiserver` sur le port 8443 de toutes les adresses (affichées `*` ou `0.0.0.0`), `etcd` sur `127.0.0.1:2379`, `192.168.49.2:2379`, `192.168.49.2:2380` et `127.0.0.1:2381`, `kube-scheduler` sur `127.0.0.1:10259`, `kube-controller` (nom de processus tronqué à 15 caractères) sur `127.0.0.1:10257`, `kubelet` sur le port 10250 de toutes les adresses et sur `127.0.0.1:10248`, `kube-proxy` sur les ports 10256 et 10249 de toutes les adresses. Les quatre `curl` répondent `ok`. Le scheduler et le controller-manager dispensent d'autorisation `/healthz`, `/readyz` et `/livez` (`--authorization-always-allow-paths`) ; le port 10248 du kubelet est du HTTP local sans authentification ; l'apiserver accepte les requêtes anonymes (`system:anonymous`) et le ClusterRole `system:public-info-viewer` autorise tout le monde à lire `/healthz`, `/livez`, `/readyz` et `/version`.
>
> **Vérification** : la dernière commande se termine par la ligne `readyz check passed`, précédée de contrôles `[+]… ok`.

#### Exercice 2.5 — Le pod statique `sonde`

**Point de départ** : exercice 2.4.

Sur le nœud `cka-m02`, crée un pod statique nommé `sonde`, image `busybox:1.37.0`, commande `sleep 3600`, labels `app=sonde` et `tier=outils`, sans namespace dans le manifeste. Observe son mirror pod : nom, namespace, propriétaire, labels. Supprime le mirror pod avec kubectl et montre que le conteneur n'a pas redémarré. Rends ensuite le manifeste invisible au kubelet **sans le supprimer**, constate la disparition du pod, puis retire définitivement le pod statique. L'état du cluster doit être celui de départ.

> [!example]- Solution
> ```bash
> minikube -p cka ssh -n cka-m02
> sudo tee /etc/kubernetes/manifests/sonde.yaml > /dev/null <<'EOF'
> apiVersion: v1
> kind: Pod
> metadata:
>   name: sonde
>   labels:
>     app: sonde
>     tier: outils
> spec:
>   containers:
>   - name: sonde
>     image: busybox:1.37.0
>     command: ["sleep", "3600"]
> EOF
> sudo crictl ps --name sonde
> exit
> kubectl get pod sonde-cka-m02 -o wide --show-labels
> kubectl get pod sonde-cka-m02 -o jsonpath='{.metadata.namespace} {.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
> ```
>
> Le manifeste n'indique pas de namespace : le mirror pod `sonde-cka-m02` apparaît dans `default`, `Running` sur `cka-m02`, avec les labels `app=sonde,tier=outils` recopiés du fichier. La seconde commande affiche `default Node/cka-m02`.
>
> ```bash
> kubectl delete pod sonde-cka-m02
> kubectl get pod sonde-cka-m02
> minikube -p cka ssh -n cka-m02
> sudo crictl ps --name sonde
> ```
>
> Le pod réapparaît en quelques secondes avec un `AGE` remis à zéro (pendant une ou deux secondes, il s'affiche `0/1 Pending`, le temps que le kubelet republie son statut), mais `crictl ps` montre le **même** identifiant de conteneur, toujours `Running`, avec `ATTEMPT` à 0 : seul le reflet a été recréé.
>
> ```bash
> sudo mv /etc/kubernetes/manifests/sonde.yaml /etc/kubernetes/manifests/.sonde.yaml
> sleep 35; sudo crictl ps --name sonde
> exit
> kubectl get pod sonde-cka-m02
> minikube -p cka ssh -n cka-m02 -- sudo rm /etc/kubernetes/manifests/.sonde.yaml
> ```
>
> Un fichier dont le nom commence par un point est ignoré par le kubelet : il arrête le pod, mais `sleep`, PID 1 du conteneur, ignore `SIGTERM`, et le conteneur ne disparaît qu'au bout du délai de grâce de 30 secondes (mesuré sur le lab : 30 s entre le `mv` et la disparition). Le mirror pod reste visible pendant ce temps ; ensuite, `crictl ps` n'affiche plus que son en-tête et `kubectl get` répond `Error from server (NotFound): pods "sonde-cka-m02" not found`. À l'inverse, un nom comme `sonde.yaml.bak` aurait été chargé. On supprime enfin le fichier caché.
>
> **Vérification** : `minikube -p cka ssh -n cka-m02 -- sudo ls -A /etc/kubernetes/manifests` n'affiche rien, et `kubectl get pods -A | grep sonde` ne renvoie aucune ligne.

#### Exercice 2.6 — Watch et resourceVersion

**Point de départ** : exercice 2.5.

Dans un premier terminal, surveille les ConfigMaps du namespace `default` en affichant le type de chaque événement. Dans un second, crée la ConfigMap `temoin` (clé `etat`, valeur `v1`), relève sa `resourceVersion`, passe la valeur à `v2`, relève à nouveau la `resourceVersion`, puis supprime-la. Observe ensuite les requêtes HTTP qu'émet `kubectl get configmaps -w` et dis quelle `resourceVersion` porte la requête de watch.

> [!example]- Solution
> ```bash
> # terminal 1
> kubectl -n default get configmaps -w --output-watch-events
> ```
>
> ```bash
> # terminal 2
> kubectl -n default create configmap temoin --from-literal=etat=v1
> kubectl -n default get configmap temoin -o jsonpath='{.metadata.resourceVersion}{"\n"}'
> kubectl -n default patch configmap temoin -p '{"data":{"etat":"v2"}}'
> kubectl -n default get configmap temoin -o jsonpath='{.metadata.resourceVersion}{"\n"}'
> kubectl -n default delete configmap temoin
> ```
>
> Le terminal 1 affiche d'abord un `ADDED` synthétique pour chaque ConfigMap existante (`kube-root-ca.crt`), puis `ADDED temoin`, `MODIFIED temoin` et `DELETED temoin` :
>
> ```
> EVENT      NAME               DATA   AGE
> ADDED      kube-root-ca.crt   1      52m
> ADDED      temoin             1      0s
> MODIFIED   temoin             1      9s
> DELETED    temoin             1      17s
> ```
>
> La seconde `resourceVersion` est plus grande que la première : chaque écriture produit une nouvelle révision d'etcd. L'écart dépasse souvent 1, car la révision est globale à tout le cluster et d'autres objets (Leases, événements) s'écrivent entre-temps. Arrête le terminal 1 par Ctrl+C, puis :
>
> ```bash
> kubectl -n default get configmaps -w -v=6 2>&1 | grep -E 'GET|Response' | head -3
> ```
>
> On voit d'abord le `list` (`…/configmaps?limit=500`), puis le watch (`…/configmaps?resourceVersion=<N>&watch=true`), où `N` est la `resourceVersion` de la liste reçue juste avant : le watch reprend exactement où le list s'est arrêté. Ctrl+C pour sortir.
>
> **Vérification** : `kubectl -n default get configmap temoin` répond `Error from server (NotFound): configmaps "temoin" not found`.

#### Exercice 2.7 — Propriétaires, cascade et finalizer

**Point de départ** : exercice 2.6.

Dans `default`, crée le Deployment `gc-demo` (image `nginx:1.30.6-alpine`, 2 réplicas) et remonte la chaîne de propriété d'un de ses pods jusqu'au Deployment. Supprime le Deployment en laissant ses dépendants orphelins, montre que le ReplicaSet et les pods survivent sans propriétaire, puis recrée le même Deployment et montre qu'il adopte l'ancien ReplicaSet. Supprime-le ensuite normalement. Crée enfin une ConfigMap `verrou` portant le finalizer `boutique.example/blocage`, demande sa suppression sans bloquer ton terminal, observe son état, et termine la suppression. Rien ne doit rester dans `default`.

> [!example]- Solution
> ```bash
> kubectl create deployment gc-demo --image=nginx:1.30.6-alpine --replicas=2
> kubectl rollout status deployment/gc-demo
> POD=$(kubectl get pods -l app=gc-demo -o jsonpath='{.items[0].metadata.name}')
> RS=$(kubectl get pod "$POD" -o jsonpath='{.metadata.ownerReferences[0].name}')
> kubectl get pod "$POD" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
> kubectl get rs "$RS" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
> ```
>
> Le pod appartient à `ReplicaSet/gc-demo-<hash>`, qui appartient à `Deployment/gc-demo`.
>
> ```bash
> kubectl delete deployment gc-demo --cascade=orphan
> kubectl get rs "$RS" -o jsonpath='{.metadata.ownerReferences}{"\n"}'
> kubectl get pods -l app=gc-demo
> kubectl create deployment gc-demo --image=nginx:1.30.6-alpine --replicas=2
> kubectl get rs -l app=gc-demo
> kubectl get rs "$RS" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
> ```
>
> Après la suppression orpheline, le ReplicaSet n'a plus d'`ownerReferences` (la première jsonpath n'affiche rien) et ses deux pods tournent toujours, avec le même âge. Le Deployment recréé calcule le même `pod-template-hash` que l'ancien, trouve un ReplicaSet orphelin conforme et l'**adopte** : `kubectl get rs` ne montre qu'un seul ReplicaSet, à nouveau possédé par `Deployment/gc-demo`, et aucun pod n'a été recréé.
>
> ```bash
> kubectl delete deployment gc-demo
> kubectl apply -f - <<'EOF'
> apiVersion: v1
> kind: ConfigMap
> metadata:
>   name: verrou
>   namespace: default
>   finalizers:
>   - boutique.example/blocage
> data:
>   etat: "verrouille"
> EOF
> kubectl delete configmap verrou --wait=false
> kubectl get configmap verrou -o jsonpath='{.metadata.deletionTimestamp} {.metadata.finalizers}{"\n"}'
> kubectl patch configmap verrou --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
> ```
>
> La suppression en cascade par défaut (`background`) efface Deployment, ReplicaSet et pods. Pour `verrou`, `kubectl delete` affiche `configmap "verrou" deleted from default namespace` et rend la main grâce à `--wait=false`, mais l'objet existe encore : il porte un `deletionTimestamp` et son finalizer. Aucun contrôleur ne gère `boutique.example/blocage` ; c'est donc à nous de le retirer, et l'apiserver efface alors l'objet.
>
> **Vérification** : `kubectl get deployments,replicasets,configmaps -l app=gc-demo` répond `No resources found in default namespace.`, et `kubectl get configmap verrou` répond `Error from server (NotFound): configmaps "verrou" not found`.

#### Exercice 2.8 — Leases : élection et battements de cœur

**Point de départ** : exercice 2.7.

Liste toutes les Leases du cluster. Montre que le lab n'a pas de Lease d'élection pour le scheduler ni le controller-manager, et retrouve dans le manifeste du scheduler l'option qui l'explique. Affiche pour la Lease du nœud `cka-m03` son détenteur, sa durée et sa dernière date de renouvellement, et montre que cette date avance. Compte enfin les apiservers vivants à partir de leurs Leases.

> [!example]- Solution
> ```bash
> kubectl get leases -A
> kubectl -n kube-system get lease kube-scheduler kube-controller-manager
> minikube -p cka ssh -- sudo grep leader-elect /etc/kubernetes/manifests/kube-scheduler.yaml
> ```
>
> `kube-node-lease` contient trois Leases, `cka`, `cka-m02` et `cka-m03` ; `kube-system` contient au moins la Lease `apiserver-<hachage>`. La deuxième commande répond `Error from server (NotFound): leases.coordination.k8s.io "kube-scheduler" not found`, puis la même erreur pour `kube-controller-manager`. Le manifeste contient `- --leader-elect=false` : sans élection, aucune Lease n'est créée. Sur un cluster kubeadm, ces deux Leases existent et `spec.holderIdentity` y nomme l'instance active sous la forme `<nœud>_<uuid>`.
>
> ```bash
> kubectl -n kube-node-lease get lease cka-m03 \
>   -o jsonpath='{.spec.holderIdentity} {.spec.leaseDurationSeconds} {.spec.renewTime}{"\n"}'
> sleep 15
> kubectl -n kube-node-lease get lease cka-m03 -o jsonpath='{.spec.renewTime}{"\n"}'
> kubectl -n kube-system get lease -l apiserver.kubernetes.io/identity=kube-apiserver --no-headers | wc -l
> ```
>
> La Lease de `cka-m03` est détenue par `cka-m03`, avec un bail de `40` secondes ; quinze secondes plus tard, `renewTime` a avancé d'au moins dix secondes : le kubelet la renouvelle toutes les 10 secondes. Le dernier compte vaut `1`, un seul apiserver.
>
> **Vérification** : `kubectl get nodes` montre les trois nœuds `Ready`, cohérent avec trois Leases fraîches ; aucun objet n'a été créé.

---
