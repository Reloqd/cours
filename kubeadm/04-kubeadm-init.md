## 4. Initialiser le control plane : kubeadm init

### 4.1 Drapeaux ou fichier de configuration

`kubeadm init` accepte deux façons d'exprimer ce qu'on veut :

| | Drapeaux | Fichier de configuration |
|---|----------|--------------------------|
| **Usage** | Cluster simple, examen | Tout vrai cluster |
| **Rejouable** | Non (historique du shell) | Oui, versionnable |
| **Couverture** | Partielle | **Totale** |
| **Réglages sans drapeau** | Inaccessibles | Configuration du kubelet, mode de kube-proxy, durée des certificats, timeouts… |

On ne peut pas mélanger les deux : avec `--config`, la plupart des drapeaux de configuration sont refusés.

On part des valeurs par défaut, que kubeadm sait afficher :

```bash
kubeadm config print init-defaults \
  --component-configs KubeletConfiguration,KubeProxyConfiguration > kubeadm.yaml
```

### 4.2 Le fichier de configuration v1beta4

Le fichier réunit plusieurs documents YAML, chacun avec son `kind`. Après nettoyage, on ne garde que ce qui s'écarte des valeurs par défaut :

```yaml
# kubeadm.yaml — configuration du cluster du cours
# ─────────────────────────────────────────────────────────────
# InitConfiguration : propre au nœud qu'on initialise. Sert une fois.
# ─────────────────────────────────────────────────────────────
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.10.11      # adresse annoncée par l'API server de cp1
  bindPort: 6443
nodeRegistration:
  name: cp1
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:                    # v1beta4 : liste name/value
    - name: node-ip
      value: 192.168.10.11
---
# ─────────────────────────────────────────────────────────────
# ClusterConfiguration : tout le cluster. Stockée dans le ConfigMap
# kube-system/kubeadm-config, relue par join et upgrade.
# ─────────────────────────────────────────────────────────────
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.35.0             # aligner sur "kubeadm version -o short"
controlPlaneEndpoint: k8s-api.example:6443   # adresse STABLE de l'API (chapitre 6.3)
networking:
  podSubnet: 10.244.0.0/16             # → controller-manager --cluster-cidr
  serviceSubnet: 10.96.0.0/12
  dnsDomain: cluster.local
apiServer:
  certSANs:                            # noms supplémentaires du certificat de l'API
    - k8s-api.example
    - 192.168.10.10
certificateValidityPeriod: 8760h0m0s   # 1 an (défaut)
caCertificateValidityPeriod: 87600h0m0s  # 10 ans (défaut)
---
# ─────────────────────────────────────────────────────────────
# KubeletConfiguration : distribuée à TOUS les nœuds
# (ConfigMap kube-system/kubelet-config)
# ─────────────────────────────────────────────────────────────
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
---
# ─────────────────────────────────────────────────────────────
# KubeProxyConfiguration (ConfigMap kube-system/kube-proxy)
# ─────────────────────────────────────────────────────────────
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: nftables                         # stable depuis 1.33 ; ipvs déprécié depuis 1.35
```

**Pourquoi un nom dans `controlPlaneEndpoint`** : cette valeur est gravée dans le certificat de l'API server et dans **tous** les kubeconfigs du cluster. Un nom DNS permet de déplacer l'adresse plus tard sans rien régénérer. Le chapitre 6.3 le démontre.

**Le fil rouge du cours** utilise ce fichier avec `kubernetesVersion: v1.34.x`, puisque le cluster naît en 1.34 pour être mis à jour au chapitre 7.

### 4.3 Versions de l'API de configuration

```
Historique de l'API de configuration :
══════════════════════════════════════

  v1beta1  ── supprimée (kubeadm 1.22)
  v1beta2  ── supprimée (kubeadm 1.27)
  v1beta3  ── dépréciée, SUPPRIMÉE en 1.37
  v1beta4  ── courante depuis la 1.31
               - extraArgs / kubeletExtraArgs : listes name/value
                 (au lieu de maps) → un drapeau peut être répété
               - nouveaux kinds : UpgradeConfiguration, ResetConfiguration
               - certificateValidityPeriod, caCertificateValidityPeriod
               - structure "timeouts" unifiée

  Convertir un ancien fichier :
    kubeadm config migrate --old-config ancien.yaml --new-config nouveau.yaml
```

```yaml
# v1beta3 (ancien)                    # v1beta4 (courant)
apiServer:                            apiServer:
  extraArgs:                            extraArgs:
    audit-log-maxage: "30"                - name: audit-log-maxage
                                            value: "30"
```

### 4.4 Avant de lancer : valider, précharger, simuler

```bash
# 1. Valider la syntaxe et les valeurs
kubeadm config validate --config kubeadm.yaml

# 2. Télécharger les images à l'avance : isole les problèmes de registre
kubeadm config images list --config kubeadm.yaml
sudo kubeadm config images pull --config kubeadm.yaml

# 3. Simuler toute l'init sans rien écrire sur le nœud
sudo kubeadm init --config kubeadm.yaml --dry-run
```

Puis on lance l'init :

```bash
sudo kubeadm init --config kubeadm.yaml --upload-certs
```

`--upload-certs` pousse dans le Secret `kubeadm-certs` les certificats que les futurs control planes devront partager (chapitre 5.6).

L'équivalent en drapeaux, tel qu'on le tape à l'examen :

```bash
sudo kubeadm init \
  --control-plane-endpoint k8s-api.example:6443 \
  --apiserver-advertise-address 192.168.10.11 \
  --pod-network-cidr 10.244.0.0/16 \
  --upload-certs
```

### 4.5 Les phases

`kubeadm init` enchaîne une suite de **phases**. Chacune peut être rejouée seule (`kubeadm init phase <phase>`) ou sautée (`--skip-phases`, ou `skipPhases` dans l'`InitConfiguration`). C'est l'outil de réparation par excellence : pour régénérer un seul artefact, on rejoue la seule phase qui le produit.

```
kubeadm init : les phases dans l'ordre
══════════════════════════════════════

  preflight ──────────── contrôles du nœud
      │
  certs ──────────────── /etc/kubernetes/pki/  (CA + certificats)
      │
  kubeconfig ─────────── /etc/kubernetes/*.conf
      │
  etcd ───────────────── manifests/etcd.yaml
      │
  control-plane ──────── manifests/kube-apiserver.yaml,
      │                  kube-controller-manager.yaml, kube-scheduler.yaml
      │
  kubelet-start ──────── /var/lib/kubelet/config.yaml, kubeadm-flags.env
      │                  + redémarrage du kubelet
      │                  → le kubelet lance les pods statiques
      │
  wait-control-plane ─── attend que les composants répondent
      │                  ⚠ là où la plupart des inits échouent
      │
  upload-config ──────── ConfigMaps kubeadm-config, kubelet-config
      │
  upload-certs ───────── Secret kubeadm-certs (si --upload-certs)
      │
  mark-control-plane ─── label + taint node-role.kubernetes.io/control-plane
      │
  bootstrap-token ────── jeton de join + RBAC du bootstrap TLS
      │                  + ConfigMap kube-public/cluster-info
      │
  kubelet-finalize ───── bascule le kubelet sur un certificat renouvelable
      │
  addon ──────────────── CoreDNS, kube-proxy
      │
  show-join-command ──── affiche les commandes de join
```

Chaque phase a son aide (`kubeadm init phase certs --help`) et ses sous-phases. Exemples de réparation :

```bash
# Régénérer admin.conf
sudo kubeadm init phase kubeconfig admin --config kubeadm.yaml

# Régénérer le certificat de l'API server (après avoir écarté l'ancien)
sudo kubeadm init phase certs apiserver --config kubeadm.yaml

# Republier les certificats partagés et obtenir une nouvelle clé
sudo kubeadm init phase upload-certs --upload-certs

# Réinstaller l'addon CoreDNS
sudo kubeadm init phase addon coredns --config kubeadm.yaml
```

**Règle d'or** : les phases `certs` et `kubeconfig` **réutilisent** un fichier existant valide (« Using existing … »). Pour régénérer un certificat ou un kubeconfig, on écarte d'abord l'ancien. Les phases `control-plane` et `etcd`, elles, **réécrivent** les manifestes : c'est ce qui permet de reconfigurer un composant (chapitre 10).

### 4.6 Quand l'init échoue

L'échec le plus courant survient pendant `wait-control-plane`. kubeadm a écrit les manifestes, le kubelet est censé lancer les pods, et kubeadm attend que les composants répondent avant d'abandonner au bout du délai. Le message final ne dit rien de la cause : il faut la chercher sur le nœud.

```bash
systemctl status kubelet
journalctl -xeu kubelet --no-pager | tail -50
sudo crictl ps -a
sudo crictl logs <identifiant-du-conteneur>
```

| Ce qu'on observe | Cause |
|------------------|-------|
| kubelet `failed`, message sur le swap | Swap actif (3.3) |
| Conteneurs qui redémarrent en boucle sans erreur claire | cgroup driver incohérent (3.5) |
| Aucun conteneur, erreurs de pull dans le journal du kubelet | Image introuvable, registre injoignable |
| etcd en boucle, `bind: cannot assign requested address` | `advertiseAddress` n'appartient pas au nœud : etcd écoute sur cette adresse |
| API server en boucle, connexion refusée vers 2379 | etcd ne démarre pas : lire ses journaux |

Après correction, on remet le nœud à zéro avant une nouvelle tentative (chapitre 12.5) :

```bash
sudo kubeadm reset -f
```

### 4.7 Après l'init : kubeconfig, CNI, taints

#### Le kubeconfig

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

On utilise `admin.conf`, jamais `super-admin.conf` au quotidien (chapitre 2.5).

#### Le CNI

Le nœud apparaît, mais **`NotReady`** :

```
Pourquoi NotReady juste après l'init :
══════════════════════════════════════

  /etc/cni/net.d/ est vide
        │
        ▼
  containerd : "no network config found"
        │
        ▼
  kubelet : NetworkReady=false, "cni plugin not initialized"
        │
        ▼
  Node : Ready=False + taint node.kubernetes.io/not-ready:NoSchedule
        │
        ▼
  CoreDNS : Pending (il n'a pas de réseau de pods)

  MAIS les pods en hostNetwork tournent quand même :
    - etcd, kube-apiserver, controller-manager, scheduler
    - kube-proxy
    - les agents du CNI eux-mêmes
  → c'est ce qui permet au CNI de s'installer sur un cluster
    qui n'a pas encore de réseau.
```

Le CNI sort du cadre de kubeadm, mais sa cohérence avec la configuration du cluster le concerne. Quand `podSubnet` est renseigné, kubeadm passe `--allocate-node-cidrs=true` et `--cluster-cidr` au controller-manager, qui attribue à chaque nœud un `/24` dans `spec.podCIDR`. Chaque CNI se positionne différemment :

| CNI | Rapport à `spec.podCIDR` | Contrainte |
|-----|--------------------------|------------|
| **Flannel** (ce cours) | L'utilise tel quel | Son réseau (`10.244.0.0/16` par défaut) doit égaler `podSubnet` |
| **Calico** | Gère ses propres réserves d'adresses | La réserve doit être comprise dans `podSubnet`. Son défaut historique, `192.168.0.0/16`, chevaucherait le réseau des nœuds de ce cours |
| **Cilium** | L'ignore en mode `cluster-pool` (défaut) | Ses propres paramètres d'allocation font foi |

Un CNI qui remplace kube-proxy (Cilium par exemple) demande de ne pas l'installer : `--skip-phases=addon/kube-proxy`.

Flannel s'installe en une commande :

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
kubectl get nodes          # Ready après quelques secondes
```

#### Les taints

Le control plane porte la taint `node-role.kubernetes.io/control-plane:NoSchedule`, qui en écarte les pods applicatifs. Sur un cluster d'un seul nœud, on la retire :

```bash
kubectl taint nodes cp1 node-role.kubernetes.io/control-plane:NoSchedule-
```

### 4.8 Pièges courants

```
Piège 1 : controlPlaneEndpoint oublié
══════════════════════════════════════
  MAUVAIS : kubeadm init sans --control-plane-endpoint
  → l'IP de cp1 est gravée partout ; passer en HA plus tard
    impose de régénérer certificats et kubeconfigs.
  BON : un nom stable dès le premier nœud, même pour un lab.

Piège 2 : podSubnet incohérent avec le CNI
═══════════════════════════════════════════
  SYMPTÔME : pods sans IP, ou routage cassé entre nœuds.
  BON : vérifier le réseau attendu par le CNI AVANT l'init.

Piège 3 : Rejouer une phase sur un fichier existant
════════════════════════════════════════════════════
  MAUVAIS : kubeadm init phase certs apiserver   (apiserver.crt présent)
  → kubeadm garde l'ancien certificat.
  BON : mv apiserver.{crt,key} /root/ puis rejouer la phase.

Piège 4 : Relancer init sans reset
═══════════════════════════════════
  → [ERROR DirAvailable--var-lib-etcd], [ERROR Port-6443]…
  BON : kubeadm reset -f, puis nettoyer (chapitre 12.5).

Piège 5 : Utiliser super-admin.conf comme kubeconfig courant
═════════════════════════════════════════════════════════════
  → droits irrévocables : à réserver aux urgences.
```

---
