## 6. Control plane hautement disponible

Un seul control plane, c'est un point de défaillance unique. Si `cp1` tombe, les pods déjà lancés continuent de tourner, mais plus rien ne peut changer dans le cluster : ni déploiement, ni mise à l'échelle, ni remplacement d'un pod mort.

### 6.1 Deux topologies

```
TOPOLOGIE EMPILÉE (stacked etcd) — défaut de kubeadm
═════════════════════════════════════════════════════

            ┌──────────── load balancer (VIP :6443) ────────────┐
            ▼                        ▼                           ▼
  ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
  │ cp1              │   │ cp2              │   │ cp3              │
  │  kube-apiserver  │   │  kube-apiserver  │   │  kube-apiserver  │
  │  controller-mgr  │   │  controller-mgr  │   │  controller-mgr  │
  │  scheduler       │   │  scheduler       │   │  scheduler       │
  │  etcd ◀──────────┼───┼─▶ etcd ◀─────────┼───┼─▶ etcd           │
  └──────────────────┘   └──────────────────┘   └──────────────────┘
  Chaque API server parle à l'etcd LOCAL (127.0.0.1:2379).
  Perdre une machine = perdre un API server ET un membre etcd.


TOPOLOGIE ETCD EXTERNE
══════════════════════

            ┌──────────── load balancer (VIP :6443) ────────────┐
            ▼                        ▼                           ▼
  ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
  │ cp1  apiserver   │   │ cp2  apiserver   │   │ cp3  apiserver   │
  │      ctrl, sched │   │      ctrl, sched │   │      ctrl, sched │
  └────────┬─────────┘   └────────┬─────────┘   └────────┬─────────┘
           └──────────────────────┼──────────────────────┘
                                  ▼
  ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
  │ etcd1            │◀─▶│ etcd2            │◀─▶│ etcd3            │
  └──────────────────┘   └──────────────────┘   └──────────────────┘
  Pannes découplées, mais 6 machines et une PKI etcd à fournir.
```

| | etcd empilé | etcd externe |
|---|-------------|--------------|
| **Machines minimum** | 3 | 3 control planes + 3 etcd |
| **Mise en place** | `kubeadm join --control-plane` suffit | PKI etcd et section `etcd.external` à fournir |
| **Perte d'une machine** | Un API server **et** un membre etcd | L'un ou l'autre |
| **Usage** | Cas général, examen | Gros clusters, exigences de séparation |

### 6.2 Le quorum d'etcd

etcd réplique ses données selon l'algorithme **Raft** : une écriture n'est validée que lorsque la **majorité** des membres l'a enregistrée. Cette majorité s'appelle le quorum.

```
Quorum = floor(N/2) + 1
═══════════════════════

  Membres   Quorum   Pannes tolérées
  ───────   ──────   ───────────────
     1         1           0
     2         2           0   ← PIRE qu'un seul membre
     3         2           1
     4         3           1   ← n'apporte rien par rapport à 3
     5         3           2

  Deux membres : le quorum exige les DEUX. La panne de l'un OU de
  l'autre bloque tout. On double le risque de panne sans gagner
  la moindre tolérance.

  Règle : toujours un nombre IMPAIR de membres (3 ou 5).
```

Sans quorum, etcd refuse les écritures et les lectures cohérentes. L'API server ne peut plus servir les requêtes, même en lecture : `kubectl get pods` échoue. Les pods déjà lancés continuent de tourner, car les kubelets n'ont pas besoin de l'API pour maintenir l'existant.

### 6.3 controlPlaneEndpoint se décide à l'init

```
Où est gravé controlPlaneEndpoint :
═══════════════════════════════════

  controlPlaneEndpoint: k8s-api.example:6443
           │
           ├──▶ SAN du certificat pki/apiserver.crt
           ├──▶ server: dans admin.conf, super-admin.conf
           ├──▶ server: dans kubelet.conf de CHAQUE nœud
           ├──▶ server: dans cluster-info (discovery des futurs joins)
           └──▶ ConfigMap kubeadm-config

  Init SANS controlPlaneEndpoint :
    → l'adresse de cp1 (192.168.10.11) est gravée partout.
    → passer en HA = régénérer le certificat de l'API et tous les
      kubeconfigs, sur chaque nœud.

  Init AVEC un NOM :
    → déplacer l'API = changer la résolution du nom.
      Aucun certificat, aucun kubeconfig à toucher.
```

C'est pourquoi le cours initialise `cp1` avec `controlPlaneEndpoint: k8s-api.example:6443`, résolu d'abord vers `cp1` lui-même, puis vers l'adresse virtuelle une fois kube-vip en place. Les SAN du certificat (`certSANs`) contiennent aussi l'adresse virtuelle `192.168.10.10`, pour pouvoir l'utiliser directement.

### 6.4 Le load balancer : HAProxy et keepalived

kubeadm ne fournit rien devant les API servers. Il faut une adresse qui reste joignable quand un control plane tombe, et qui achemine les connexions TCP du port 6443 vers un API server vivant.

La solution classique associe deux outils sur des **machines dédiées** :
- **keepalived** maintient une adresse virtuelle partagée par VRRP : une machine la porte, une autre la reprend si la première tombe ;
- **HAProxy** répartit les connexions entre les API servers et retire ceux qui ne répondent plus.

```
# /etc/haproxy/haproxy.cfg (extrait)
frontend k8s-api
    bind *:6443
    mode tcp
    option tcplog
    default_backend k8s-api

backend k8s-api
    mode tcp
    balance roundrobin
    option httpchk
    http-check connect ssl
    http-check send meth GET uri /readyz
    http-check expect status 200
    server cp1 192.168.10.11:6443 check verify none
    server cp2 192.168.10.12:6443 check verify none
    server cp3 192.168.10.13:6443 check verify none
```

**Pourquoi `/readyz`** : ce point de contrôle est accessible sans authentification (ClusterRole `system:public-info-viewer`). Il échoue dès que l'API server perd etcd ou commence à s'arrêter, ce qui retire le nœud **avant** que les requêtes n'échouent. `/healthz` est déprécié, et `/livez` ne dit que si le processus est vivant, pas s'il peut servir.

**Sur les control planes eux-mêmes**, HAProxy entre en conflit avec l'API server : celui-ci écoute le port 6443 sur **toutes** les adresses de la machine. L'adresse virtuelle doit alors utiliser un autre port (8443 par exemple), que `controlPlaneEndpoint` reprend.

### 6.5 Le load balancer : kube-vip

**kube-vip**, retenu par ce cours, se déploie en **pod statique** sur chaque control plane. Aucune machine supplémentaire n'est nécessaire.

```
kube-vip en mode ARP :
══════════════════════

  ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
  │ cp1             │   │ cp2             │   │ cp3             │
  │ kube-vip LEADER │   │ kube-vip        │   │ kube-vip        │
  │ eth0:           │   │ (en attente)    │   │ (en attente)    │
  │  192.168.10.11  │   │                 │   │                 │
  │  192.168.10.10 ◀┼── adresse virtuelle portée par le leader  │
  │ kube-apiserver  │   │ kube-apiserver  │   │ kube-apiserver  │
  │ écoute 0.0.0.0  │   │                 │   │                 │
  └────────┬────────┘   └─────────────────┘   └─────────────────┘
           │
           └── élection par un Lease : kube-system/plndr-cp-lock

  Le leader tombe :
    1. il cesse de renouveler le Lease
    2. une autre instance prend le Lease
    3. elle ajoute 192.168.10.10 à son interface
    4. elle l'annonce par ARP gratuit → les voisins mettent à jour
       leur table ARP, le trafic suit

  Pas de conflit de port : l'API server du leader écoute sur toutes
  les adresses, il reçoit directement le trafic de la VIP.

  ⚠ Dans ce mode, kube-vip NE RÉPARTIT PAS la charge : tout arrive
    sur le leader. Il assure la disponibilité, pas la répartition.
```

Le manifeste se génère avec l'image de kube-vip elle-même, en root sur un control plane :

```bash
export VIP=192.168.10.10
export INTERFACE=eth0          # l'interface qui porte 192.168.10.0/24
export KVVERSION=$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases | jq -r '.[0].name')
ctr image pull ghcr.io/kube-vip/kube-vip:$KVVERSION
ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:$KVVERSION vip /kube-vip \
  manifest pod --interface $INTERFACE --address $VIP \
  --controlplane --arp --leaderElection \
  | tee /etc/kubernetes/manifests/kube-vip.yaml
```

Le manifeste monte `/etc/kubernetes/admin.conf`, dont kube-vip a besoin pour manipuler son Lease. Sur un control plane joint, ce fichier n'existe qu'**après** le join : on dépose donc le manifeste après `kubeadm join`, en le copiant depuis `cp1`.

**kube-vip déployé avant `kubeadm init`** : c'est l'autre façon de faire, pour que l'adresse virtuelle existe dès le premier instant. Il faut alors que kube-vip utilise `super-admin.conf` **pendant** l'init. À cet instant, le ClusterRoleBinding qui donne ses droits à `admin.conf` n'existe pas encore. Privé d'accès à l'API, kube-vip ne publie pas l'adresse, et l'init attend une API injoignable jusqu'à expiration du délai.

```bash
# avant l'init
sed -i 's#path: /etc/kubernetes/admin.conf#path: /etc/kubernetes/super-admin.conf#' \
  /etc/kubernetes/manifests/kube-vip.yaml
# après l'init : l'opération inverse
```

**Sur un control plane joint**, le kubelet s'adresse à l'API server **local** plutôt qu'à l'adresse virtuelle (feature gate `ControlPlaneKubeletLocalMode`, active par défaut en 1.35). Le kubelet ne dépend ainsi pas du load balancer pour enregistrer son propre nœud.

### 6.6 Gérer les membres d'etcd

L'image d'etcd contient `etcdctl`, qu'on appelle depuis le pod. Les certificats sont montés dans le conteneur aux mêmes chemins que sur l'hôte :

```bash
kubectl -n kube-system exec etcd-cp1 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list -w table
```

```
+------------------+---------+------+----------------------------+----------------------------+------------+
|        ID        | STATUS  | NAME |         PEER ADDRS         |        CLIENT ADDRS        | IS LEARNER |
+------------------+---------+------+----------------------------+----------------------------+------------+
| 2d3f0b9c8a1e4f57 | started | cp1  | https://192.168.10.11:2380 | https://192.168.10.11:2379 |      false |
| 6b8e1a2c3d4f5a69 | started | cp2  | https://192.168.10.12:2380 | https://192.168.10.12:2379 |      false |
| 9c7d6e5f4a3b2c18 | started | cp3  | https://192.168.10.13:2380 | https://192.168.10.13:2379 |      false |
+------------------+---------+------+----------------------------+----------------------------+------------+
```

D'autres commandes utiles (mêmes options TLS) :

| Commande | Rôle |
|----------|------|
| `endpoint health --cluster` | Santé de chaque membre |
| `endpoint status --cluster -w table` | Leader, taille de la base, révision, terme Raft |
| `member remove <ID>` | Retirer un membre mort (chapitre 12.4) |

### 6.7 L'élection de leader des composants

Trois API servers servent tous en même temps : ils sont sans état, etcd porte l'état. Il n'en va pas de même pour **kube-controller-manager** et **kube-scheduler** : deux schedulers actifs placeraient deux fois le même pod. Ces composants pratiquent donc l'**élection de leader** : une seule instance travaille, les autres attendent.

```bash
kubectl -n kube-system get lease kube-controller-manager kube-scheduler plndr-cp-lock \
  -o custom-columns=NOM:.metadata.name,DETENTEUR:.spec.holderIdentity,RENOUVELE:.spec.renewTime
```

```
NOM                       DETENTEUR                                    RENOUVELE
kube-controller-manager   cp2_4f1c9e2a-...                             2026-10-07T14:02:11.402Z
kube-scheduler            cp1_8a7b3c1d-...                             2026-10-07T14:02:12.118Z
plndr-cp-lock             cp1                                          2026-10-07T14:02:12.553Z
```

Avec les réglages par défaut (Lease de 15 secondes), une instance qui tombe est relayée en une quinzaine de secondes. Le chapitre 11.5 montre la conséquence pour le dépannage : une instance cassée qui n'était pas leader ne produit **aucun symptôme**.

### 6.8 Pièges courants

```
Piège 1 : Deux control planes
══════════════════════════════
  MAUVAIS : "deux, c'est déjà de la HA"
  → quorum = 2 sur 2 : la moindre panne bloque etcd.
  BON     : 3 ou 5.

Piège 2 : HAProxy sur les control planes, port 6443
════════════════════════════════════════════════════
  SYMPTÔME : HAProxy ne démarre pas, "cannot bind socket".
  CAUSE    : l'API server écoute déjà 0.0.0.0:6443.
  BON      : un autre port pour la VIP, ou kube-vip.

Piège 3 : kube-vip avec admin.conf avant l'init
════════════════════════════════════════════════
  SYMPTÔME : l'init expire à wait-control-plane, la VIP n'apparaît pas.
  BON      : super-admin.conf pendant l'init, puis retour à admin.conf.

Piège 4 : Membre etcd fantôme
══════════════════════════════
  SYMPTÔME : un control plane détruit sans "kubeadm reset" ;
             etcd compte toujours 3 membres dont un mort.
  → plus aucune panne tolérée.
  BON      : etcdctl member remove <ID> (chapitre 12.4).

Piège 5 : Le contrôle de santé sur /livez ou sur TCP
═════════════════════════════════════════════════════
  → un API server vivant mais coupé d'etcd reçoit encore du trafic.
  BON : /readyz.
```

---
