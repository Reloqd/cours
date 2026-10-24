## 2. Architecture d'un cluster kubeadm

Avant d'installer quoi que ce soit, il faut savoir ce que kubeadm fabrique. Presque toutes les difficultés rencontrées plus tard, en mise à jour comme en dépannage, s'expliquent par ce chapitre.

### 2.1 Ce que kubeadm fabrique, et ce qu'il ne fait pas

| Ce qu'il fabrique | Où |
|-------------------|-----|
| Trois autorités de certification et les certificats qu'elles signent | `/etc/kubernetes/pki/` |
| Les kubeconfigs des composants et de l'administrateur | `/etc/kubernetes/*.conf` |
| Les manifestes de pods statiques du control plane | `/etc/kubernetes/manifests/` |
| La configuration du kubelet | `/var/lib/kubelet/config.yaml`, `kubeadm-flags.env` |
| Les jetons et les droits RBAC du bootstrap TLS | API, namespace `kube-system` |
| Les addons CoreDNS et kube-proxy | API, namespace `kube-system` |

Ce qu'il **ne fait pas** :
- installer le runtime de conteneurs, ni les paquets `kubelet` et `kubectl`, dont il suppose la présence ;
- installer un CNI : sans lui, les nœuds restent `NotReady` ;
- fournir le load balancer qui répartit le trafic entre plusieurs API servers ;
- provisionner des machines ;
- sauvegarder etcd.

Ce partage des rôles est délibéré. kubeadm se veut une brique, sur laquelle d'autres outils (Kubespray, Cluster API) construisent.

### 2.2 Le kubelet, seul service du cluster

C'est l'idée qui explique tout le reste : **le kubelet est le seul composant Kubernetes qui tourne comme service systemd**. etcd, kube-apiserver, kube-controller-manager et kube-scheduler tournent en **pods statiques**.

Un pod statique est décrit par un fichier YAML posé dans un dossier que surveille le kubelet (`staticPodPath`, qui vaut `/etc/kubernetes/manifests` sur un cluster kubeadm). Le kubelet lit ce fichier et lance les conteneurs directement par le runtime, **sans rien demander à l'API server**.

```
Le problème de l'œuf et de la poule, et sa solution :
═════════════════════════════════════════════════════

  Un pod "normal" a besoin de toute la chaîne :

  kubectl apply ─▶ API server ─▶ etcd
                       │
                       ├─▶ controller-manager : Deployment → ReplicaSet → Pod
                       ├─▶ scheduler          : Pod → nœud
                       └─▶ kubelet du nœud    : Pod → conteneurs

  Impossible pour l'API server lui-même : il faudrait qu'il existe
  déjà pour être créé.

  Un pod statique court-circuite toute la chaîne :

  /etc/kubernetes/manifests/kube-apiserver.yaml
                │
                │  lu toutes les ~20 s (fileCheckFrequency)
                ▼
        ┌──────────────┐   CRI    ┌──────────────┐
        │   kubelet    │ ───────▶ │  containerd  │ ──▶ conteneur kube-apiserver
        └──────┬───────┘          └──────────────┘
               │
               │  une fois l'API server joignable :
               ▼
        publie un MIRROR POD dans l'API (lecture seule)
        → c'est lui que montre "kubectl get pods -n kube-system"
```

### 2.3 Pods statiques et mirror pods : les conséquences pratiques

Ce mécanisme a quatre conséquences qu'on retrouve sans cesse, à l'examen comme en production.

**Modifier un manifeste suffit à redéployer un composant.** Le kubelet détecte le changement et recrée le pod. Il n'y a ni commande à lancer, ni `kubectl apply`.

**Supprimer le mirror pod ne redémarre rien.** `kubectl delete pod kube-apiserver-cp1` supprime le reflet, que le kubelet republie aussitôt. Le conteneur, lui, continue de tourner. Pour redémarrer réellement un pod statique :

```bash
sudo mv /etc/kubernetes/manifests/kube-scheduler.yaml /root/
sudo crictl ps --name kube-scheduler        # attendre que le conteneur disparaisse
sudo mv /root/kube-scheduler.yaml /etc/kubernetes/manifests/
```

**Quand l'API server tombe, `kubectl` devient aveugle.** Il faut alors travailler sur le nœud, avec `crictl` qui interroge directement le runtime, et avec les journaux du kubelet (chapitre 11).

**Une copie de sauvegarde n'a pas sa place dans le dossier des manifestes.** Un fichier `kube-apiserver.yaml.bak` est lu comme un manifeste à part entière. Les copies vont ailleurs, dans `/root/` par exemple.

### 2.4 Les trois PKI

kubeadm crée **trois autorités de certification indépendantes**. La confiance ne se croise pas entre elles : un certificat signé par l'une n'est jamais accepté par un composant qui attend l'autre.

```
Les trois autorités et ce qu'elles signent :
════════════════════════════════════════════

  CA KUBERNETES (pki/ca.crt, CN=kubernetes)
  ├── apiserver.crt                  certificat serveur de l'API (port 6443)
  ├── apiserver-kubelet-client.crt   l'API server parle aux kubelets
  │                                  (kubectl logs, exec, port-forward)
  ├── admin.conf, super-admin.conf   certificats clients embarqués
  ├── controller-manager.conf
  ├── scheduler.conf
  └── kubelets                       certificats clients des nœuds (CSR)

  CA ETCD (pki/etcd/ca.crt, CN=etcd-ca)
  ├── etcd/server.crt                etcd sert ses clients (port 2379)
  ├── etcd/peer.crt                  membres etcd entre eux (port 2380)
  ├── etcd/healthcheck-client.crt    sonde de santé
  └── apiserver-etcd-client.crt      l'API server parle à etcd
                                     ⚠ rangé à la racine de pki/,
                                       mais signé par la CA etcd

  CA FRONT-PROXY (pki/front-proxy-ca.crt, CN=front-proxy-ca)
  └── front-proxy-client.crt         l'API server relaie vers les API
                                     étendues (aggregation layer,
                                     ex. metrics-server)

  HORS PKI : sa.key / sa.pub
  └── paire de clés (pas un certificat) qui signe les jetons
      des ServiceAccounts. DOIT être identique sur tous les
      control planes, sinon un jeton émis par un API server
      est refusé par les autres.
```

C'est parce que ces trois autorités et `sa.key` **ne se régénèrent pas** qu'un nouveau control plane doit les recevoir des autres (chapitre 5.6). Des autorités différentes feraient deux clusters.

### 2.5 Les kubeconfigs

| Fichier | Identité | Rôle |
|---------|----------|------|
| `admin.conf` | `kubernetes-admin`, groupe `kubeadm:cluster-admins` | Administration courante |
| `super-admin.conf` | groupe `system:masters` | Accès de dernier recours |
| `controller-manager.conf` | `system:kube-controller-manager` | Composant |
| `scheduler.conf` | `system:kube-scheduler` | Composant |
| `kubelet.conf` | `system:node:<nom>`, groupe `system:nodes` | Kubelet du nœud |

**`admin.conf` et `super-admin.conf`** (depuis la 1.29) : la différence est fondamentale.

```
admin.conf :
  identité kubernetes-admin ∈ groupe kubeadm:cluster-admins
                                      │
            ClusterRoleBinding kubeadm:cluster-admins
                                      │
                                      ▼
                              ClusterRole cluster-admin
  → les droits PASSENT PAR LE RBAC : on peut les révoquer.

super-admin.conf :
  identité ∈ groupe system:masters
  → system:masters CONTOURNE le RBAC : aucun binding ne peut
    lui retirer ses droits.
  → écrit uniquement sur le nœud où "kubeadm init" a tourné.
  → accès de dernier recours, le jour où le ClusterRoleBinding
    kubeadm:cluster-admins aurait été supprimé.
```

Avant la 1.29, `admin.conf` appartenait à `system:masters` : un fichier fuité donnait un accès irrévocable, sauf à changer toute la CA. La séparation corrige ce défaut.

### 2.6 Arborescence sur le disque

```
/etc/kubernetes/
├── admin.conf
├── super-admin.conf             (nœud de l'init seulement)
├── controller-manager.conf
├── scheduler.conf
├── kubelet.conf                 → pointe vers /var/lib/kubelet/pki/kubelet-client-current.pem
├── manifests/
│   ├── etcd.yaml
│   ├── kube-apiserver.yaml
│   ├── kube-controller-manager.yaml
│   └── kube-scheduler.yaml
└── pki/
    ├── ca.crt, ca.key
    ├── apiserver.crt, .key
    ├── apiserver-kubelet-client.crt, .key
    ├── apiserver-etcd-client.crt, .key
    ├── front-proxy-ca.crt, .key
    ├── front-proxy-client.crt, .key
    ├── sa.key, sa.pub
    └── etcd/
        ├── ca.crt, ca.key
        ├── server.crt, .key
        ├── peer.crt, .key
        └── healthcheck-client.crt, .key

/var/lib/kubelet/
├── config.yaml                  KubeletConfiguration, commune à tous les nœuds
├── kubeadm-flags.env            drapeaux propres à CE nœud
└── pki/
    ├── kubelet-client-current.pem   → lien vers le certificat client en cours
    └── kubelet.crt, kubelet.key     certificat serveur (autosigné par défaut)

/var/lib/etcd/                   données d'etcd (control planes)
/etc/cni/net.d/                  configuration du CNI (écrite par le CNI)
```

### 2.7 Les objets de kubeadm dans l'API

| Objet | Rôle |
|-------|------|
| ConfigMap `kube-system/kubeadm-config` | La `ClusterConfiguration` : **source de vérité** que relisent `join` et `upgrade` |
| ConfigMap `kube-system/kubelet-config` | La configuration commune des kubelets |
| ConfigMap `kube-system/kube-proxy` | La configuration de kube-proxy |
| ConfigMap `kube-public/cluster-info` | Lisible sans authentification, sert à la discovery du join |
| Secrets `kube-system/bootstrap-token-<id>` | Les jetons de join |
| Secret `kube-system/kubeadm-certs` | Les certificats partagés, chiffrés, **supprimés au bout de 2 heures** |

**Note importante** : le ConfigMap `kubeadm-config` est la mémoire du cluster pour kubeadm. Une modification faite seulement dans un manifeste, sans passer par lui, disparaît à la prochaine mise à jour (chapitre 10).

### 2.8 Le kubelet et systemd

La ligne de commande du kubelet est assemblée par un fichier complémentaire de systemd, `10-kubeadm.conf`, installé par le paquet. Son emplacement varie selon la distribution et le paquet : plutôt que de le retenir, on l'affiche.

```bash
systemctl cat kubelet
```

```
D'où viennent les options du kubelet :
══════════════════════════════════════

  10-kubeadm.conf (drop-in systemd, fourni par le paquet)
  │
  ├── KUBELET_KUBECONFIG_ARGS
  │     --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf
  │     --kubeconfig=/etc/kubernetes/kubelet.conf
  │
  ├── KUBELET_CONFIG_ARGS
  │     --config=/var/lib/kubelet/config.yaml       ← ConfigMap kubelet-config
  │
  ├── EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
  │     KUBELET_KUBEADM_ARGS="--node-ip=… "         ← écrit par kubeadm,
  │                                                    propre au nœud
  │
  └── EnvironmentFile=-/etc/default/kubelet         (/etc/sysconfig/kubelet
        KUBELET_EXTRA_ARGS="…"                       sur Red Hat)
                                                    ← réservé à l'administrateur,
                                                      jamais touché par kubeadm

  En cas de conflit : un drapeau l'emporte sur config.yaml.
```

Pour lire rapidement les drapeaux d'un composant du control plane :

```bash
grep -E '^\s+- --' /etc/kubernetes/manifests/kube-apiserver.yaml
```

---
