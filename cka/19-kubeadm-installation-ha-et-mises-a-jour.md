---
title: "CKA — 19. kubeadm : installer, haute disponibilité, mettre à jour"
description: "Préparer les nœuds, initialiser et joindre un cluster kubeadm, passer en haute disponibilité, mettre à jour de 1.36 à 1.37, gérer les certificats et défaire un nœud."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 19. kubeadm : installer, haute disponibilité, mettre à jour

Ce chapitre couvre le cycle de vie complet d'un cluster construit avec kubeadm : préparer les machines, initialiser le premier control plane, joindre des nœuds, passer en haute disponibilité, mettre à jour le cluster d'une version mineure à la suivante, surveiller et renouveler les certificats, enfin défaire proprement un nœud. C'est le cœur du domaine *Cluster Architecture, Installation and Configuration* (25 %), dont quatre compétences officielles relèvent directement : *Prepare underlying infrastructure for installing a Kubernetes cluster*, *Create and manage Kubernetes clusters using kubeadm*, *Manage the lifecycle of Kubernetes clusters* et *Implement and configure a highly-available control plane*. Il nourrit aussi *Troubleshoot clusters and nodes*, car un nœud qui ne rejoint pas ou un kubelet qui ne redémarre plus après une mise à jour sont des pannes typiques. À l'examen, la tâche la plus fréquente est la mise à jour d'un control plane, puis d'un worker, vers la mineure suivante : quelques minutes de commandes où l'ordre compte plus que la vitesse de frappe. Viennent ensuite la jonction d'un nœud dont le jeton a expiré, le renouvellement de certificats et la préparation d'une machine (paquet à installer, paramètres du noyau, runtime).

Le cours voisin consacré à kubeadm (dossier [`../kubeadm/`](../kubeadm/00-introduction.md)) détaille chaque mécanisme sur cinq chapitres ; il vise Kubernetes 1.34 → 1.35. Ce chapitre-ci se suffit pour l'examen, vise 1.36 → 1.37, et renvoie au cours kubeadm pour l'approfondissement : préparation des nœuds ([chapitre 3](../kubeadm/03-preparation-des-noeuds.md)), `kubeadm init` et ses phases ([chapitre 4](../kubeadm/04-kubeadm-init.md)), jonction et bootstrap TLS ([chapitre 5](../kubeadm/05-join-et-bootstrap-tls.md)), haute disponibilité ([chapitre 6](../kubeadm/06-haute-disponibilite.md)).

### 19.1 Le lab de ce chapitre

#### 19.1.1 Pourquoi un lab de machines virtuelles

minikube construit son cluster avec kubeadm, mais il pilote lui-même `init` et `join`, avec ses propres réglages, et il ne sait pas mettre à jour un cluster en place. Installer, passer en haute disponibilité et mettre à jour se pratiquent donc sur cinq VM, celles du cours kubeadm ([section 1.5](../kubeadm/01-introduction-et-contexte.md)). Le cluster minikube `cka` ne sert ici qu'à lire une configuration kubeadm réelle, ses certificats et ses jetons (exercices 19.1 à 19.3) ; il sort du chapitre inchangé.

| Rôle | Nom | Adresse |
|---|---|---|
| Control plane | `cp1` | 192.168.10.11 |
| Control plane | `cp2` | 192.168.10.12 |
| Control plane | `cp3` | 192.168.10.13 |
| Worker | `w1` | 192.168.10.21 |
| Worker | `w2` | 192.168.10.22 |
| Adresse virtuelle de l'API | `k8s-api.example` | 192.168.10.10 (kube-vip, mode ARP) |

Les autres réglages sont fixes : pods en 10.244.0.0/16 (Flannel), Services en 10.96.0.0/12, containerd 2.3, kube-proxy en mode `nftables`, Debian 13 ou Ubuntu 24.04 sur des VM de 2 vCPU et 2 à 4 Go. Les commandes du lab de VM s'exécutent sur la machine nommée en commentaire (`# sur cp1`), après `ssh cp1` ; `kubectl` se lance depuis `cp1`, qui détient le kubeconfig administrateur.

```
Le fil rouge du lab de VM :
═══════════════════════════

  Exercice 19.4           Exercice 19.6            Exercice 19.7
  préparation, init  ──▶  haute disponibilité ──▶  mise à jour
  cp1 + w1 + w2           cp1 à cp3, kube-vip      1.36.5 → 1.37.1
  ┌──────┐                ┌──────┐                 ┌──────┐
  │  S1  │                │  S2  │                 │  S3  │
  └──────┘                └──────┘                 └──────┘
  Kubernetes 1.36.5       Kubernetes 1.36.5        Kubernetes 1.37.1

  S1 : cp1 + w1 + w2 en 1.36, Flannel   (repris par 19.5 et 19.6)
  S2 : cp1 à cp3 derrière kube-vip, w1, w2, 1.36   (repris par 19.7)
  S3 : le même cluster en 1.37          (repris par 19.8)
```

Le cluster naît en **1.36.5**, dernier correctif de la 1.36 au 23 octobre 2026, pour être mis à jour vers **1.37.1**, dernier correctif de la 1.37 (`dl.k8s.io/release/stable-1.37.txt`). Le cours kubeadm suit la même démarche une mineure plus tôt : partout où il écrit `v1.34` ou `v1.35`, ce lab écrit `v1.36` ou `v1.37`, et les noms, adresses et fichiers restent les mêmes.

#### 19.1.2 Ce que kubeadm fabrique, en bref

kubeadm n'est pas un démon : chaque commande écrit des fichiers et quelques objets dans l'API, puis rend la main. Il fabrique trois autorités de certification (Kubernetes, etcd, front-proxy) et les certificats qu'elles signent sous `/etc/kubernetes/pki`, les kubeconfigs des composants sous `/etc/kubernetes/*.conf`, les manifestes des pods statiques sous `/etc/kubernetes/manifests`, la configuration du kubelet (`/var/lib/kubelet/config.yaml`, `/var/lib/kubelet/kubeadm-flags.env` et, depuis l'abandon de l'annotation de socket CRI, `/var/lib/kubelet/instance-config.yaml` qui ne contient que `containerRuntimeEndpoint`), et dans l'API les ConfigMaps `kube-system/kubeadm-config`, `kube-system/kubelet-config` et `kube-system/kube-proxy`, plus les jetons de bootstrap. Il **n'installe pas** le runtime, ni les paquets `kubelet` et `kubectl`, ni le CNI, ni le load balancer de l'API, et il ne sauvegarde pas etcd. Le chapitre 2 a montré pourquoi le kubelet est le seul service systemd et comment il lance les pods statiques ; le [chapitre 2 du cours kubeadm](../kubeadm/02-architecture.md) détaille l'arborescence et les trois PKI.

La ConfigMap `kubeadm-config` est la **mémoire** du cluster pour kubeadm : `join` et `upgrade` y relisent la `ClusterConfiguration`. Une option ajoutée à la main dans un manifeste, sans passer par elle, disparaît à la mise à jour suivante, puisque `upgrade` régénère les manifestes à partir de cette ConfigMap.

#### 19.1.3 kubeadm dans le lab minikube

> [!info] minikube ≠ examen
> Sur un cluster kubeadm d'examen, `kubeadm` est dans `/usr/bin`, sa configuration n'existe souvent que dans la ConfigMap `kubeadm-config`, les certificats sont sous `/etc/kubernetes/pki` et l'API écoute sur 6443. Dans le nœud `cka`, kubeadm est hors du PATH (`/var/lib/minikube/binaries/v1.37.0/kubeadm`), la configuration utilisée par minikube est sur disque (`/var/tmp/minikube/kubeadm.yaml`, API `kubeadm.k8s.io/v1beta4`), les certificats sont sous `/var/lib/minikube/certs`, l'API écoute sur 8443 derrière `controlPlaneEndpoint: control-plane.minikube.internal:8443`, et le cluster s'appelle `mk`. On y lit tout ; on n'y met rien à jour.

| Réglage lu dans `/var/tmp/minikube/kubeadm.yaml` | Valeur dans le lab minikube | Valeur par défaut de kubeadm |
|---|---|---|
| `localAPIEndpoint.bindPort` | 8443 | 6443 |
| `nodeRegistration.taints` | `[]` (aucune taint) | `node-role.kubernetes.io/control-plane:NoSchedule` |
| `certificatesDir` | `/var/lib/minikube/certs` | `/etc/kubernetes/pki` |
| `clusterName` | `mk` | `kubernetes` |
| `etcd.local.dataDir` | `/var/lib/minikube/etcd` | `/var/lib/etcd` |
| `networking.podSubnet` | `10.244.0.0/16` | vide (aucune allocation de `podCIDR`) |
| `networking.serviceSubnet` | `10.96.0.0/12` | `10.96.0.0/12` |
| `certificateValidityPeriod` (ConfigMap) | `8760h0m0s` | `8760h0m0s` (1 an) |
| `caCertificateValidityPeriod` (ConfigMap) | `87600h0m0s` | `87600h0m0s` (10 ans) |

### 19.2 Préparer les nœuds

Le *preflight* de `kubeadm init` et `kubeadm join` contrôle une partie des prérequis ; ses erreurs bloquent, ses avertissements non. On le lance seul, sans rien modifier, avec `sudo kubeadm init phase preflight`. L'ignorer (`--ignore-preflight-errors=<Contrôle>` ou `=all`) déplace presque toujours le problème plus loin, sous une forme moins lisible. Le [chapitre 3 du cours kubeadm](../kubeadm/03-preparation-des-noeuds.md) justifie chaque prérequis ; voici ce qu'il faut savoir faire vite.

#### 19.2.1 Identité, ports, ressources

Chaque nœud doit avoir un nom d'hôte, une adresse MAC et un `product_uuid` uniques (`hostnamectl`, `ip -br link`, `sudo cat /sys/class/dmi/id/product_uuid`) : deux VM clonées sans précaution s'écrasent dans le même objet Node. Un control plane exige 2 CPU (`NumCPU`) et 1700 Mo (`Mem`) ; les ports 6443, 2379-2380, 10250, 10257 et 10259 doivent être libres sur un control plane (`Port-6443`…), 10250 et la plage NodePort 30000-32767 sur un worker. `nc 127.0.0.1 6443 -zv -w 2` teste un port.

#### 19.2.2 Noyau : modules et paramètres

```bash
# sur chaque nœud
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<'EOF' | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables
```

`net.ipv4.ip_forward = 1` est le seul contrôle **bloquant** du preflight dans ce domaine (`FileContent--proc-sys-net-ipv4-ip_forward`) : le nœud doit router le trafic des pods. Les deux clés `bridge-nf-call-*` n'existent que si `br_netfilter` est chargé ; elles font passer par netfilter le trafic qui traverse un pont Linux, sans quoi les règles de kube-proxy ne voient pas le trafic entre deux pods du même pont. Un fichier dans `/etc/sysctl.d/` rend le réglage persistant ; `sysctl -w` seul le perd au redémarrage.

> [!tip] Réflexe d'examen
> Une tâche « prépare ce nœud » demande en général de poser des paramètres sysctl **persistants**, d'installer un paquet `.deb` fourni et d'activer un service. Écris le fichier dans `/etc/sysctl.d/`, applique avec `sudo sysctl --system`, installe par `sudo dpkg -i <fichier>.deb` (ou `sudo apt-get install ./<fichier>.deb`, qui résout les dépendances), active par `sudo systemctl enable --now <service>`, puis vérifie chaque point : `sysctl <clé>`, `systemctl is-active <service>`. Si le runtime à brancher est Docker Engine, il faut le shim `cri-dockerd`, dont le socket est `unix:///var/run/cri-dockerd.sock` ; quand plusieurs runtimes sont détectés, kubeadm exige `--cri-socket`.

#### 19.2.3 Le swap

Par défaut, le kubelet refuse de démarrer si du swap est actif (`failSwapOn: true`). Depuis la 1.34, le swap des nœuds (*NodeSwap*) est stable : avec `failSwapOn: false`, le kubelet tolère le swap, mais les pods n'en profitent qu'avec `memorySwap.swapBehavior: LimitedSwap` (et seulement les pods Burstable) ; la valeur par défaut `NoSwap` les en prive. Le swap exige cgroup v2. Le preflight ne lève qu'un **avertissement** (`[WARNING Swap]: swap is supported for cgroup v2 only. The kubelet must be properly configured to use swap…`) : il ne connaît pas la configuration que recevra le kubelet. D'où le piège classique : l'init passe le preflight, puis échoue à la phase `wait-control-plane` parce que le kubelet refuse de démarrer, et seul `journalctl -u kubelet` nomme le swap.

```yaml
# Tolérer le swap (document KubeletConfiguration du fichier de kubeadm)
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
failSwapOn: false
memorySwap:
  swapBehavior: LimitedSwap
```

> [!warning] Deux pages officielles se contredisent
> La page « Installing kubeadm » (v1.37) admet un swap toléré par `failSwapOn: false` ; la page « Upgrading kubeadm clusters » de la même version exige toujours « Swap must be disabled ». Le code et la page de gestion du swap donnent raison à la première. Le lab suit la voie qui satisfait les deux : swap désactivé.

```bash
# sur chaque nœud
sudo swapoff -a
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
sudo systemctl mask swap.target      # bloque aussi le swap activé par systemd-gpt-auto-generator
swapon --show                        # doit être vide
```

#### 19.2.4 cgroup v2 et `failCgroupV1`

Depuis la 1.35, `failCgroupV1` vaut `true` par défaut : un kubelet 1.35 ou plus récent **refuse de démarrer** sur un hôte en cgroup v1, et le contrôle `SystemVerification` du preflight devient une erreur. Pendant un `kubeadm upgrade`, ce contrôle porte sur la mineure **suivante** du kubelet : une machine en cgroup v1 bloque donc la mise à jour avant même qu'on touche au kubelet. La vérification tient en une commande :

```bash
stat -fc %T /sys/fs/cgroup/      # cgroup2fs = cgroup v2 ; tmpfs = cgroup v1
```

Le contournement (`failCgroupV1: false` dans la ConfigMap `kube-system/kubelet-config`, et l'erreur de preflight ignorée) n'est qu'un sursis : la suppression du support de cgroup v1 est engagée (KEP-5573). Le pilote de cgroups, lui, se règle côté runtime : le kubelet 1.37 adopte celui que containerd 2.x lui annonce (19.2.5), et le `cgroupDriver: systemd` que kubeadm écrit depuis la 1.22 ne sert plus que de repli.

#### 19.2.5 containerd 2.x

La matrice de compatibilité de containerd recommande containerd 2.3 ou 2.2 pour Kubernetes 1.36, et 2.4 ou 2.3 pour la 1.37 ; containerd 1.7 est en fin de vie depuis le 30 septembre 2026. Le lab utilise donc containerd **2.3**, valable pour les deux mineures (le paquet `containerd.io` du dépôt de Docker en est à 2.3.6, les binaires officiels à v2.3.7 ; dans les deux cas, `containerd --version` fait foi).

```
Qui fixe le pilote de cgroups ?
════════════════════════════════

  kubelet 1.36 / 1.37 : demande au runtime par l'appel CRI RuntimeConfig
  ├── containerd 2.x : répond → SystemdCgroup de containerd fait foi
  └── containerd 1.x : ne connaît pas l'appel → le kubelet se rabat sur
                       son propre cgroupDriver (repli conservé en 1.37)

  kubeadm 1.37, preflight ContainerRuntimeVersion :
    [WARNING] You must update your container runtime to a version that
    supports the CRI method RuntimeConfig. Falling back to using
    cgroupDriver from kubelet config will be removed in 1.38. …

  Kubernetes 1.38 : le repli disparaît, containerd 1.x est refusé.
```

containerd 1.x n'est plus pris en charge depuis la 1.36 ; il fonctionne encore en 1.37 grâce à ce repli, et sera refusé en 1.38.

> [!note] Écart avec le cours kubeadm
> Le cours kubeadm, écrit pour la 1.35, annonçait la fin du repli en 1.36. Elle a été reportée deux fois : le kubelet 1.37 le conserve, la 1.38 le supprimera.

En containerd 2.x, le réglage `SystemdCgroup = true` se trouve dans la section `[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]` (en 1.x : `[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]`). Un paquet de distribution peut aussi livrer un `config.toml` qui désactive le plugin CRI (`disabled_plugins = ["cri"]`) : on repart de la configuration par défaut.

```bash
# sur chaque nœud, containerd 2.3 installé
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
containerd config dump | grep SystemdCgroup        # SystemdCgroup = true
sudo crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock
```

#### 19.2.6 Les paquets de pkgs.k8s.io

Le dépôt communautaire `pkgs.k8s.io` a **un dépôt par version mineure** : `https://pkgs.k8s.io/core:/stable:/v1.36/deb/` ne contient que des 1.36.x (de 1.36.0-1.1 à 1.36.5-1.1 au 23 octobre 2026), `…/v1.37/deb/` que des 1.37.x (1.37.0-1.1 et 1.37.1-1.1). Les anciens dépôts `apt.kubernetes.io` et `yum.kubernetes.io` sont gelés. La clé de signature est **la même pour toutes les mineures** (empreinte `DE15 B144 86CD 377B 9E87 6E1A 2346 54DA 9A29 6436`, vérifiée sur les `Release.key` de v1.35, v1.36 et v1.37) : changer de mineure revient à changer l'URL, sans toucher au trousseau.

```bash
# sur chaque nœud : installation en 1.36
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet='1.36.5-*' kubeadm='1.36.5-*' kubectl='1.36.5-*' cri-tools
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
```

`apt-mark hold` empêche une mise à jour système de faire monter ces trois paquets hors de la procédure ; `apt-mark showhold` liste les paquets retenus. Le paquet `kubelet` tire `kubernetes-cni` (plugins CNI de base dans `/opt/cni/bin`) ; `cri-tools` (crictl) s'installe à part. Juste après l'installation, le kubelet **redémarre en boucle** : il attend `/var/lib/kubelet/config.yaml`, que seuls `kubeadm init` ou `join` écriront. C'est normal.

### 19.3 Initialiser et joindre

#### 19.3.1 Le fichier de configuration v1beta4

En 1.37, kubeadm ne lit plus qu'**une** version de son API de configuration : `kubeadm.k8s.io/v1beta4` (courante depuis la 1.31). La `v1beta3`, dépréciée depuis la 1.31, est supprimée ; un ancien fichier se convertit avec `kubeadm config migrate --old-config ancien.yaml --new-config nouveau.yaml`, lancé par un kubeadm 1.36 ou plus ancien (la note de version de la 1.37 cite le binaire 1.35). Une API `v1` existe dans le code comme copie de `v1beta4`, mais n'est pas encore utilisable. Ce que `v1beta4` change pour toi : `extraArgs` et `kubeletExtraArgs` sont des listes `name`/`value` (un drapeau peut être répété), les durées des certificats se règlent par `certificateValidityPeriod` et `caCertificateValidityPeriod`, l'algorithme des clés par `encryptionAlgorithm` (`RSA-2048` par défaut, `RSA-3072`, `RSA-4096`, `ECDSA-P256`), et deux kinds s'ajoutent, `UpgradeConfiguration` et `ResetConfiguration`.

Le fichier du cluster S1 est celui du [chapitre 4.2 du cours kubeadm](../kubeadm/04-kubeadm-init.md), à la version près :

```yaml
# kubeadm.yaml — cluster S1 (cp1)
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.10.11
  bindPort: 6443
nodeRegistration:
  name: cp1
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: 192.168.10.11
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.36.5
controlPlaneEndpoint: k8s-api.example:6443
networking:
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
  dnsDomain: cluster.local
apiServer:
  certSANs:
    - k8s-api.example
    - 192.168.10.10
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: nftables
```

Sans `kubernetesVersion`, kubeadm prend `stable-1`, c'est-à-dire le dernier correctif de **sa propre** mineure lu sur `dl.k8s.io` (à défaut d'Internet, sa propre version). Sans `mode` pour kube-proxy, kubeadm 1.37 écrit explicitement `mode: iptables` dans la ConfigMap `kube-proxy`. `controlPlaneEndpoint` est gravé dans le certificat de l'API et dans tous les kubeconfigs : un **nom** stable posé dès le premier nœud permet de passer en haute disponibilité sans rien régénérer (19.4.2).

#### 19.3.2 Lancer l'init

```bash
# sur cp1
kubeadm config validate --config kubeadm.yaml
sudo kubeadm config images pull --config kubeadm.yaml
sudo kubeadm init --config kubeadm.yaml --upload-certs
```

L'équivalent en drapeaux, tel qu'on le tape quand l'énoncé ne fournit pas de fichier :

```bash
sudo kubeadm init --control-plane-endpoint k8s-api.example:6443 \
  --apiserver-advertise-address 192.168.10.11 \
  --pod-network-cidr 10.244.0.0/16 --kubernetes-version v1.36.5 --upload-certs
```

`kubeadm init` enchaîne des **phases** (`preflight`, `certs`, `kubeconfig`, `etcd`, `control-plane`, `kubelet-start`, `wait-control-plane`, `upload-config`, `upload-certs`, `mark-control-plane`, `bootstrap-token`, `kubelet-finalize`, `addon`, `show-join-command`), rejouables une à une (`kubeadm init phase <phase>`) : c'est l'outil de réparation par excellence, détaillé au [chapitre 4.5 du cours kubeadm](../kubeadm/04-kubeadm-init.md). Les phases `certs` et `kubeconfig` réutilisent un fichier existant valide ; pour régénérer, on écarte d'abord l'ancien. Un init raté se rejoue après `sudo kubeadm reset -f` (19.8).

Après l'init, trois gestes : copier le kubeconfig administrateur, installer le CNI, et décider des taints.

```bash
# sur cp1
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
kubectl get nodes        # NotReady tant que le CNI n'a pas écrit /etc/cni/net.d, puis Ready
```

`admin.conf` porte l'identité `kubernetes-admin`, membre du groupe `kubeadm:cluster-admins`, lié à `cluster-admin` par RBAC : ses droits sont révocables. `super-admin.conf`, écrit seulement sur le nœud de l'init, appartient à `system:masters` et contourne RBAC ; il se garde pour les urgences (chapitre 16.2).

#### 19.3.3 Jetons et commande de jonction

Un nœud rejoint le cluster avec un **jeton de bootstrap** (`abcdef.0123456789abcdef` : 6 caractères d'identifiant public, 16 de secret, stocké dans le Secret `kube-system/bootstrap-token-<id>`) et le **hash de la clé publique de la CA** (`--discovery-token-ca-cert-hash sha256:…`). Le jeton prouve que le nœud connaît un secret du cluster ; le hash prouve au nœud que la CA reçue, lue sans authentification dans la ConfigMap `kube-public/cluster-info`, est bien celle du cluster attendu. Un jeton vit **24 heures** par défaut, puis le contrôleur `tokencleaner` le supprime : celui que l'init a affiché a souvent expiré quand on veut ajouter un nœud. On en crée un, avec la commande complète :

```bash
# sur cp1
sudo kubeadm token create --print-join-command
sudo kubeadm token create --ttl 2h --print-join-command
sudo kubeadm token list
sudo kubeadm token delete <id>
```

`--print-join-command` lit l'adresse de l'API et la CA dans le kubeconfig utilisé (`/etc/kubernetes/admin.conf` par défaut) et imprime une seule ligne : `kubeadm join <hôte>:<port> --token <jeton> --discovery-token-ca-cert-hash sha256:<hash>`. `--ttl 0` crée un jeton qui n'expire jamais, à proscrire. Le hash se recalcule à partir de la CA :

```bash
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
  | openssl pkey -pubin -outform der 2>/dev/null \
  | openssl dgst -sha256 -hex | sed 's/^.* //'
```

(`openssl pkey` fonctionne pour une CA RSA comme ECDSA, là où `openssl rsa`, utilisé par la documentation, échoue sur une clé ECDSA.)

> [!info] minikube ≠ examen
> minikube joint ses workers avec `kubeadm token create --print-join-command --ttl=0` : `kubeadm token list` dans le nœud `cka` montre ces jetons avec un TTL `<forever>` et une expiration `<never>`, ce qu'on ne laisse jamais sur un vrai cluster. Pendant les 24 heures qui suivent la création du cluster, la liste contient aussi le jeton ordinaire créé par `kubeadm init`, au TTL décroissant. La commande imprimée vise `control-plane.minikube.internal:8443` et le hash se calcule sur `/var/lib/minikube/certs/ca.crt` (exercice 19.3).

```bash
# sur w1 et w2
sudo kubeadm join k8s-api.example:6443 --token <jeton> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

Le kubelet du nœud s'authentifie avec le jeton (`system:bootstrap:<id>`), dépose une CSR que le controller-manager approuve et signe, puis bascule sur un certificat client renouvelable (`/var/lib/kubelet/pki/kubelet-client-current.pem`) : c'est le bootstrap TLS, détaillé au [chapitre 5.3 du cours kubeadm](../kubeadm/05-join-et-bootstrap-tls.md). Le binaire kubeadm qui fait le `join` doit être de la même version que celui qui a fait l'`init` ou la dernière mise à jour.

#### 19.3.4 Lire la configuration d'un cluster existant

À l'examen, on hérite d'un cluster dont on ignore les réglages. Trois ConfigMaps les donnent :

```bash
kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}'
kubectl -n kube-system get cm kubelet-config -o jsonpath='{.data.kubelet}'
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode'
grep -E '^\s+- --' /etc/kubernetes/manifests/kube-apiserver.yaml   # sur le control plane
```

Pour changer un réglage durablement, on passe par ces ConfigMaps, jamais par le seul fichier local : `kubectl -n kube-system edit cm kubelet-config`, puis sur chaque nœud `sudo kubeadm upgrade node phase kubelet-config` (qui réécrit `/var/lib/kubelet/config.yaml` depuis la ConfigMap) et `sudo systemctl restart kubelet`. Pour un composant du control plane : modifier `kubeadm-config`, puis rejouer `kubeadm init phase control-plane <composant> --config <fichier>` sur chaque control plane.

### 19.4 Haute disponibilité

#### 19.4.1 Deux topologies

```
ETCD EMPILÉ (stacked) — défaut de kubeadm      ETCD EXTERNE
══════════════════════════════════════════     ════════════════════════════════

      VIP k8s-api.example:6443                       VIP k8s-api.example:6443
     ┌──────────┼──────────┐                     ┌──────────┼──────────┐
     ▼          ▼          ▼                     ▼          ▼          ▼
  ┌──────┐  ┌──────┐  ┌──────┐               ┌──────┐  ┌──────┐  ┌──────┐
  │ cp1  │  │ cp2  │  │ cp3  │               │ cp1  │  │ cp2  │  │ cp3  │
  │ api  │  │ api  │  │ api  │               │ api  │  │ api  │  │ api  │
  │ etcd◀┼──┼▶etcd◀┼──┼▶etcd │               └──┬───┘  └──┬───┘  └──┬───┘
  └──────┘  └──────┘  └──────┘                  └─────────┼─────────┘
  chaque apiserver parle à son etcd                ┌──────┐┌──────┐┌──────┐
  local (127.0.0.1:2379)                           │etcd1 ││etcd2 ││etcd3 │
                                                   └──────┘└──────┘└──────┘
```

| | etcd empilé | etcd externe |
|---|---|---|
| Machines minimum | 3 | 3 control planes + 3 etcd |
| Mise en place | `kubeadm join --control-plane` suffit | PKI etcd et section `etcd.external` à fournir |
| Perte d'une machine | un apiserver **et** un membre etcd | l'un ou l'autre |
| Ce qu'en fait l'examen | cas général | à reconnaître (chapitre 20.10.2) |

etcd ne tolère la perte de membres que tant qu'une **majorité** reste joignable : 3 membres tolèrent une panne, 5 en tolèrent deux, 2 n'en tolèrent aucune (pire qu'un seul). Le chapitre 20.2 détaille Raft et le quorum. En etcd externe, la `ClusterConfiguration` déclare `etcd.external.endpoints`, `caFile`, `certFile` et `keyFile` (par convention `/etc/kubernetes/pki/etcd/ca.crt`, `/etc/kubernetes/pki/apiserver-etcd-client.crt` et `.key`), et ce sont ces valeurs qu'on retrouve dans les drapeaux `--etcd-*` de l'apiserver.

#### 19.4.2 Le point d'entrée stable

kubeadm ne fournit rien devant les apiservers. Il faut une adresse qui survive à la perte d'un control plane : HAProxy et keepalived sur des machines dédiées, ou, dans ce lab, **kube-vip** en pod statique sur chaque control plane, qui porte l'adresse virtuelle 192.168.10.10 sur le détenteur d'un Lease (`kube-system/plndr-cp-lock`) et l'annonce par ARP gratuit. En mode ARP, kube-vip assure la disponibilité, pas la répartition : tout le trafic arrive sur le leader. Le [chapitre 6.5 du cours kubeadm](../kubeadm/06-haute-disponibilite.md) donne la génération du manifeste et le piège de `super-admin.conf` quand kube-vip est posé avant l'init. Parce que `controlPlaneEndpoint` est un nom (`k8s-api.example`), passer de `cp1` à l'adresse virtuelle consiste à changer la résolution du nom dans `/etc/hosts` : le certificat de l'API contient déjà `k8s-api.example` et `192.168.10.10` (`certSANs`).

#### 19.4.3 Joindre un control plane

Un control plane supplémentaire a besoin des **mêmes** autorités de certification et de la même paire `sa.key`/`sa.pub` que le premier, puisque ces éléments ne se régénèrent pas. `--upload-certs` les chiffre avec une **clé de certificats** (AES, 32 octets en hexadécimal) et les pose dans le Secret `kube-system/kubeadm-certs`, **supprimé au bout de deux heures**, comme la clé.

```bash
# sur cp1 : republier les certificats (nouvelle clé) et produire la commande complète
sudo kubeadm init phase upload-certs --upload-certs      # affiche « Using certificate key: … »
sudo kubeadm token create --print-join-command --certificate-key <clé>

# sur cp2 (puis cp3, avec son adresse)
sudo kubeadm join k8s-api.example:6443 --token <jeton> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane --certificate-key <clé> \
  --apiserver-advertise-address 192.168.10.12
```

`kubeadm certs certificate-key` génère une clé à l'avance, qu'on passe ensuite à `init --certificate-key` (ou au champ `certificateKey` de l'`InitConfiguration` : `--config` et `--certificate-key` ne se combinent pas). Le join d'un control plane télécharge et déchiffre les certificats partagés, génère ses propres certificats feuilles, écrit les manifestes, puis ajoute son membre etcd **comme learner** (membre non votant qui rattrape le journal sans compter dans le quorum) avant de le **promouvoir** : en 1.37 ce comportement est définitif, la feature gate `EtcdLearnerMode` ayant disparu (kubeadm 1.37 n'a plus qu'une gate, `RootlessControlPlane`, alpha et dépréciée). De même, le kubelet d'un control plane joint parle à son apiserver **local** plutôt qu'à l'adresse virtuelle (ancien `ControlPlaneKubeletLocalMode`, désormais permanent).

#### 19.4.4 Vérifier un control plane hautement disponible

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods -l tier=control-plane -o wide
kubectl -n kube-system get lease kube-controller-manager kube-scheduler plndr-cp-lock \
  -o custom-columns=NOM:.metadata.name,DETENTEUR:.spec.holderIdentity
kubectl -n kube-system exec etcd-cp1 -- etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key member list
```

```
2d3f0b9c8a1e4f57, started, cp1, https://192.168.10.11:2380, https://192.168.10.11:2379, false
6b8e1a2c3d4f5a69, started, cp2, https://192.168.10.12:2380, https://192.168.10.12:2379, false
9c7d6e5f4a3b2c18, started, cp3, https://192.168.10.13:2380, https://192.168.10.13:2379, false
```

Trois apiservers servent en même temps ; le controller-manager et le scheduler, eux, pratiquent l'**élection de leader** (un seul actif, les autres attendent le Lease) : une instance cassée qui n'est pas leader ne produit aucun symptôme, ce qui explique qu'une panne se voie mieux sur un control plane unique (chapitre 23.4.5). La dernière colonne de `member list` (`IS LEARNER`) doit valoir `false` partout une fois les joins terminés.

### 19.5 La politique de décalage des versions

Une mise à jour fait cohabiter deux versions pendant des minutes ou des heures. La politique officielle (*Version Skew Policy*) dit lesquelles peuvent coexister ; kubeadm l'applique et refuse de sortir des clous. Sa page est publiée sous `kubernetes.io/releases/`, hors de `/docs` : elle ne fait pas partie des adresses autorisées à l'examen (chapitre 24.7), d'où l'intérêt de retenir le tableau ci-dessous.

| Composant | Règle, par rapport à kube-apiserver | Versions admises face à un apiserver 1.37 |
|---|---|---|
| kube-apiserver (HA) | instances à une mineure d'écart au plus | 1.37 et 1.36 |
| kube-controller-manager, kube-scheduler | jamais plus récents ; une mineure de retard au plus | 1.37, 1.36 |
| kubelet | jamais plus récent ; **trois** mineures de retard au plus | 1.37, 1.36, 1.35, 1.34 |
| kube-proxy | jamais plus récent que l'apiserver ; trois mineures de retard au plus ; ±3 par rapport au kubelet voisin | 1.37 à 1.34 |
| kubectl | une mineure d'écart, dans les deux sens | 1.38, 1.37, 1.36 |

Quand les apiservers d'un cluster HA sont à deux versions (1.37 et 1.36, en pleine mise à jour), les bornes se resserrent sur la plus ancienne : un kubelet 1.37 n'est pas admis tant qu'un apiserver 1.36 tourne. D'où l'ordre imposé : **tous les control planes d'abord, les kubelets ensuite**, une mineure à la fois. Un kubelet laissé trois mineures en arrière bloque la mise à jour suivante du control plane.

kubeadm ajoute ses propres règles : il déploie un control plane de **sa** mineure ou de la précédente (kubeadm 1.37 : 1.37 ou 1.36), accepte des kubelets jusqu'à trois mineures plus anciens (1.34 à 1.37), et met à jour un nœud géré par un kubeadm de la même mineure ou de la précédente. Ses refus sont explicites :

```
Specified version to upgrade to "v1.38.0" is too high; kubeadm can upgrade only 1 minor version at a time
Specified version to upgrade to "v1.37.1" is at least one minor release higher than the kubeadm minor release (37 > 36). Such an upgrade is not supported
```

Le second message est celui qu'on obtient en lançant `kubeadm upgrade apply v1.37.1` avec le kubeadm 1.36 encore installé : on a oublié de mettre kubeadm à jour en premier.

> [!warning] Une phrase périmée dans la documentation
> La page « Installing kubeadm » dit encore qu'« une mineure » d'écart est admise entre le kubelet et le control plane. La politique officielle, que kubeadm applique (`MaximumAllowedMinorVersionKubeletSkew = 3`), en admet trois. Retiens trois, et « jamais plus récent que l'apiserver ».

### 19.6 Mettre à jour de 1.36 à 1.37

#### 19.6.1 L'ordre des opérations

```
Mise à jour 1.36.5 → 1.37.1, cluster S2 :
═════════════════════════════════════════

  TOUS LES NŒUDS  : dépôt pkgs.k8s.io v1.36 → v1.37

  cp1 (premier)   : kubeadm 1.37.1 → upgrade plan → upgrade apply v1.37.1
                    → CNI → drain → kubelet + kubectl → restart → uncordon
  cp2             : kubeadm → upgrade node → drain → kubelet + kubectl → uncordon
  cp3 (dernier)   : idem cp2 ; c'est ICI que CoreDNS et kube-proxy montent
  w1, puis w2     : kubeadm + kubectl → upgrade node → drain → kubelet → uncordon

  Un nœud à la fois. Jamais de saut de mineure (1.36 → 1.38 interdit).
```

#### 19.6.2 Changer de dépôt

C'est l'oubli le plus fréquent : tant que le fichier de source pointe sur `v1.36`, `apt-cache madison kubeadm` ne liste que des 1.36.x. Sur **chaque** nœud, avant d'y toucher :

```bash
# sur chaque nœud
sudo sed -i 's#/v1.36/deb/#/v1.37/deb/#' /etc/apt/sources.list.d/kubernetes.list
cat /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-cache madison kubeadm
```

```
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.37/deb/ /
   kubeadm | 1.37.1-1.1 | https://pkgs.k8s.io/core:/stable:/v1.37/deb  Packages
   kubeadm | 1.37.0-1.1 | https://pkgs.k8s.io/core:/stable:/v1.37/deb  Packages
```

Une mise à jour de **correctif** (1.37.0 → 1.37.1) ne demande pas ce changement : le même dépôt contient tous les correctifs de la mineure.

#### 19.6.3 Le premier control plane

```bash
# sur cp1
sudo apt-mark unhold kubeadm && \
sudo apt-get update && sudo apt-get install -y kubeadm='1.37.1-*' && \
sudo apt-mark hold kubeadm
kubeadm version -o short          # v1.37.1
sudo kubeadm upgrade plan
```

`upgrade plan` ne fonctionne que sur un control plane qui possède `/etc/kubernetes/admin.conf`. Il vérifie que le cluster est en état d'être mis à jour, interroge `dl.k8s.io` pour connaître les versions disponibles (on lui passe une version, `kubeadm upgrade plan v1.37.1`, pour éviter Internet), et affiche le plan :

```
[preflight] Running pre-flight checks.
[upgrade/config] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
[upgrade/config] Use 'kubeadm init phase upload-config kubeadm --config your-config-file' to re-upload it.
[upgrade] Running cluster health checks
[upgrade] Fetching available versions to upgrade to
[upgrade/versions] Cluster version: 1.36.5
[upgrade/versions] kubeadm version: v1.37.1
[upgrade/versions] Target version: v1.37.1
[upgrade/versions] Latest version in the v1.36 series: v1.36.5

Components that must be upgraded manually after you have upgraded the control plane with 'kubeadm upgrade apply':
COMPONENT   NODE      CURRENT   TARGET
kubelet     cp1       v1.36.5   v1.37.1
kubelet     cp2       v1.36.5   v1.37.1
kubelet     cp3       v1.36.5   v1.37.1
kubelet     w1        v1.36.5   v1.37.1
kubelet     w2        v1.36.5   v1.37.1

Upgrade to the latest stable version:

COMPONENT                 NODE      CURRENT   TARGET
kube-apiserver            cp1       v1.36.5   v1.37.1
kube-apiserver            cp2       v1.36.5   v1.37.1
kube-apiserver            cp3       v1.36.5   v1.37.1
kube-controller-manager   cp1       v1.36.5   v1.37.1
…
kube-proxy                          1.36.5    v1.37.1
CoreDNS                             v1.14.2   v1.14.6
etcd                      cp1       3.6.8-0   3.7.0-0
etcd                      cp2       3.6.8-0   3.7.0-0
etcd                      cp3       3.6.8-0   3.7.0-0

You can now apply the upgrade by executing the following command:

	kubeadm upgrade apply v1.37.1

_____________________________________________________________________
```

Suit un second tableau, l'état des *component configs* (`kubeproxy.config.k8s.io` et `kubelet.config.k8s.io`, colonne `MANUAL UPGRADE REQUIRED` à `no`). Le plan montre les sauts de version : etcd passe de 3.6.8 à **3.7.0** (image `registry.k8s.io/etcd:3.7.0-0`), CoreDNS de v1.14.2 à **v1.14.6**. Les contrôles de santé qui le précèdent sont au nombre de trois : créer un Job de test dans `kube-system` (contrôle sauté si aucun nœud n'est schedulable), vérifier que tous les **control planes** sont Ready (les workers ne sont pas examinés), vérifier que les manifestes statiques existent.

```bash
# sur cp1
sudo kubeadm upgrade apply v1.37.1
```

```
[upgrade/preflight] Running preflight checks
[upgrade] Running cluster health checks
[upgrade/preflight] You have chosen to upgrade the cluster version to "v1.37.1"
[upgrade/versions] Cluster version: v1.36.5
[upgrade/versions] kubeadm version: v1.37.1
[upgrade] Are you sure you want to proceed? [y/N]: y
[upgrade/preflight] Pulling images required for setting up a Kubernetes cluster
…
[upgrade/control-plane] Upgrading your static Pod-hosted control plane to version "v1.37.1" (timeout: 5m0s)...
[upgrade/staticpods] Preparing for "etcd" upgrade
[upgrade/staticpods] Renewing etcd-server certificate
…
[upgrade/staticpods] Component "kube-scheduler" upgraded successfully!
[upgrade/control-plane] The control plane instance for this node was successfully upgraded!
…
[upgrade/kubelet-config] The kubelet configuration for this node was successfully upgraded!
…
[upgrade/addon] Skipping upgrade of addons because control plane instances [cp2 cp3] have not been upgraded
…
[upgrade] SUCCESS! A control plane node of your cluster was upgraded to "v1.37.1".

[upgrade] Now please proceed with upgrading the rest of the nodes by following the right order.
```

`-y` (ou `--yes`) supprime la question ; `--dry-run` montre sans rien changer ; `--etcd-upgrade=false` laisse etcd tel quel ; `--certificate-renewal=false` désactive le renouvellement des certificats (19.7.3). Les mêmes réglages s'écrivent dans un fichier `UpgradeConfiguration` passé par `--config` :

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: UpgradeConfiguration
apply:
  kubernetesVersion: v1.37.1
  certificateRenewal: true
  etcdUpgrade: true
```

> [!warning] Le message de fin a changé
> La page « Upgrading kubeadm clusters » montre encore `[upgrade/successful] SUCCESS! Your cluster was upgraded to "v1.37.x". Enjoy!`. Le kubeadm 1.37.1 écrit `[upgrade] SUCCESS! A control plane node of your cluster was upgraded to "v1.37.1".` : seul **ce nœud** est à jour, et le message le dit enfin.

Reste le CNI : kubeadm n'y touche pas. Pour Flannel, on réapplique le manifeste de la version voulue (`kubectl apply -f …/kube-flannel.yml`) ; sur les autres control planes, cette étape est inutile puisque le CNI tourne en DaemonSet.

#### 19.6.4 Ce que fait `upgrade apply`

`upgrade apply` enchaîne des phases, rejouables (`kubeadm upgrade apply phase <phase>`) : `preflight`, `control-plane`, `upload-config`, `kubeconfig`, `kubelet-config`, `bootstrap-token`, `addon` (`coredns`, `kube-proxy`) et `post-upgrade`. Quatre comportements méritent d'être connus.

**Les manifestes sont remplacés un par un, avec retour arrière.** Pour etcd puis kube-apiserver, kube-controller-manager et kube-scheduler, kubeadm écrit le nouveau manifeste dans un dossier temporaire, sauvegarde l'ancien dans `/etc/kubernetes/tmp/kubeadm-backup-manifests-<date>-<heure>`, le remplace, attend que le hash du pod miroir change puis que le pod soit prêt (5 minutes au plus), et revient en arrière si le composant ne repart pas. Avant de toucher à etcd, il copie ses données dans `/etc/kubernetes/tmp/kubeadm-backup-etcd-<date>-<heure>` : c'est une copie de secours, pas une sauvegarde au sens du chapitre 20.6. Ces dossiers restent après la mise à jour et se nettoient à la main.

**Les certificats sont renouvelés au passage**, composant par composant (19.7.3).

**Les addons attendent le dernier control plane.** Depuis la 1.28, CoreDNS et kube-proxy ne montent qu'une fois **tous** les control planes à jour : kubeadm compare l'image du pod `kube-apiserver` de chaque control plane à celle du nœud courant. Sur `cp1`, ils sont donc sautés ; c'est le `kubeadm upgrade node` de `cp3` qui les applique (`[addons] Applied essential addon: CoreDNS`, puis `… kube-proxy`). On met donc les control planes à jour **l'un après l'autre**, et on ne lance le dernier qu'une fois les autres terminés.

**Tous les conteneurs redémarrent** une fois le kubelet mis à jour, car le hash de la spec des conteneurs change.

#### 19.6.5 kubelet et kubectl du control plane

```bash
# depuis cp1
kubectl drain cp1 --ignore-daemonsets
# sur cp1
sudo apt-mark unhold kubelet kubectl && \
sudo apt-get update && sudo apt-get install -y kubelet='1.37.1-*' kubectl='1.37.1-*' && \
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet
# depuis cp1
kubectl uncordon cp1
```

Le drain est **obligatoire** pour une mise à jour de mineure du kubelet : la mise à jour en place d'un kubelet d'une mineure à l'autre n'est pas prise en charge. Les pods de DaemonSet restent (`--ignore-daemonsets`) ; un pod avec un volume `emptyDir` exige `--delete-emptydir-data`, un pod sans contrôleur `--force`, et un PodDisruptionBudget peut bloquer l'éviction (chapitre 8.14). `daemon-reload` relit l'unité et son drop-in, que le paquet a pu modifier. Les pods statiques du control plane, eux, ne sont pas évincés par le drain : ce sont des pods miroirs.

> [!tip] Réflexe d'examen
> `kubectl get nodes` affiche dans la colonne `VERSION` la version du **kubelet**, pas celle du control plane. Après `upgrade apply`, `cp1` y figure toujours en `v1.36.5` ; la version de l'API se lit dans `kubectl version` (`Server Version`), celle des composants dans les images des pods statiques. Une tâche « mets à jour cp1 en 1.37.1 » n'est terminée que lorsque la colonne affiche `v1.37.1` et que le nœud est `Ready` et schedulable.

#### 19.6.6 Les autres control planes

```bash
# sur cp2, puis sur cp3 une fois cp2 terminé
sudo apt-mark unhold kubeadm && \
sudo apt-get update && sudo apt-get install -y kubeadm='1.37.1-*' && \
sudo apt-mark hold kubeadm
sudo kubeadm upgrade node
# puis drain, kubelet et kubectl, restart, uncordon, comme en 19.6.5
```

`upgrade node` ne prend pas de version : il relit la `ClusterConfiguration` (que `upgrade apply` a mise à jour), régénère les manifestes de ce nœud, renouvelle ses certificats, met à jour la configuration du kubelet, et, sur le dernier control plane, les addons. Ni `upgrade plan`, ni CNI. Il décide qu'il tourne sur un control plane si `/etc/kubernetes/manifests/kube-apiserver.yaml` existe : un manifeste d'apiserver déplacé pour un dépannage et oublié hors du dossier fait traiter le nœud comme un worker. Lancer `upgrade apply` sur `cp2` au lieu de `upgrade node` n'est pas la procédure : `apply` est réservé au premier control plane.

#### 19.6.7 Les workers

```bash
# sur w1
sudo apt-mark unhold kubeadm kubectl && \
sudo apt-get update && sudo apt-get install -y kubeadm='1.37.1-*' kubectl='1.37.1-*' && \
sudo apt-mark hold kubeadm kubectl
sudo kubeadm upgrade node          # sur un worker : configuration du kubelet seulement
# depuis cp1
kubectl drain w1 --ignore-daemonsets
# sur w1
sudo apt-mark unhold kubelet && \
sudo apt-get update && sudo apt-get install -y kubelet='1.37.1-*' && \
sudo apt-mark hold kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet
# depuis cp1
kubectl uncordon w1
```

Sur un worker, `upgrade node` s'authentifie avec `/etc/kubernetes/kubelet.conf` (il n'y a pas d'`admin.conf`), télécharge la configuration commune et réécrit `/var/lib/kubelet/config.yaml` : `[upgrade/kubelet-config] The kubelet configuration for this node was successfully upgraded!`. La page officielle des workers fait monter `kubectl` en même temps que `kubeadm`, pour que le `kubectl` local reste dans la fenêtre de ±1 mineure. On passe ensuite à `w2`, seulement quand `w1` est `Ready`.

#### 19.6.8 Vérifier, et reprendre après un échec

```bash
kubectl get nodes
kubectl version
kubectl -n kube-system get pods -o custom-columns=POD:.metadata.name,IMAGE:.spec.containers[0].image
```

```
NAME   STATUS   ROLES           AGE   VERSION
cp1    Ready    control-plane   4d    v1.37.1
cp2    Ready    control-plane   4d    v1.37.1
cp3    Ready    control-plane   4d    v1.37.1
w1     Ready    <none>          4d    v1.37.1
w2     Ready    <none>          4d    v1.37.1
```

`kubeadm upgrade` est **idempotent** : après une coupure en plein milieu, on le relance. Pour remettre un control plane d'aplomb sans changer de version, `sudo kubeadm upgrade apply --force v1.37.1`. Si le retour arrière automatique a échoué, les manifestes de `/etc/kubernetes/tmp/kubeadm-backup-manifests-*` se remettent dans `/etc/kubernetes/manifests`, et les données de `kubeadm-backup-etcd-*` dans `/var/lib/etcd`. `kubeadm upgrade diff` montre la différence entre les manifestes en place et ceux qu'une version produirait.

> [!tip] Réflexe d'examen
> La tâche donne souvent un seul nœud et une version exacte. Sur un control plane : dépôt, `kubeadm`, `upgrade plan`, `upgrade apply vX.Y.Z` (ou `upgrade node` si ce n'est pas le premier), drain, `kubelet` et `kubectl`, `daemon-reload`, `restart kubelet`, uncordon. Sur un worker : dépôt, `kubeadm` et `kubectl`, `upgrade node`, drain, `kubelet`, `daemon-reload`, `restart`, uncordon. Le drain et l'uncordon se lancent depuis un nœud qui a un kubeconfig, en général le control plane : à l'examen, `exit` pour revenir à la machine de départ, puis `ssh` vers le bon hôte. La page « Upgrading kubeadm clusters » de kubernetes.io contient toutes les commandes : garde-la ouverte.

### 19.7 Les certificats

#### 19.7.1 Durées et inventaire

kubeadm signe les certificats **feuilles** pour **un an** (`certificateValidityPeriod: 8760h0m0s`) et les trois **CA** pour **dix ans** (`caCertificateValidityPeriod: 87600h0m0s`), en antidatant de cinq minutes le début de validité des CA. Les deux durées se règlent dans la `ClusterConfiguration` v1beta4, avec l'unité `h` au plus.

```bash
# sur cp1
sudo kubeadm certs check-expiration
```

La commande liste les certificats de `/etc/kubernetes/pki` et ceux qu'embarquent `admin.conf`, `super-admin.conf`, `controller-manager.conf` et `scheduler.conf`, puis les trois CA. Elle **exclut `kubelet.conf`** : le kubelet renouvelle lui-même son certificat client (`rotateCertificates: true`, fichiers sous `/var/lib/kubelet/pki`), par une CSR que le controller-manager approuve automatiquement. La colonne `EXTERNALLY MANAGED` signale un certificat dont la CA n'a pas sa clé sur le disque (mode *External CA*) : kubeadm ne sait pas le renouveler.

> [!info] minikube ≠ examen
> Dans le nœud `cka`, `kubeadm certs check-expiration` sans option échoue : la valeur par défaut du drapeau `--cert-dir` (`/etc/kubernetes/pki`) l'emporte sur la ConfigMap, qui dit pourtant `certificatesDir: /var/lib/minikube/certs`. Il faut `--config /var/tmp/minikube/kubeadm.yaml` ou `--cert-dir /var/lib/minikube/certs`. Le certificat `apiserver` y vaut 3 ans (il est émis par minikube), les autres 1 an. La CA `ca` est elle aussi celle de minikube (`CN=minikubeCA`), créée une fois pour toutes dans le dossier de minikube du poste et réutilisée à chaque recréation du cluster : sa date d'expiration peut donc précéder celles d'`etcd-ca` et de `front-proxy-ca`, que kubeadm génère avec le cluster.

```bash
minikube -p cka ssh
# dans le nœud cka
sudo /var/lib/minikube/binaries/v1.37.0/kubeadm certs check-expiration \
  --config /var/tmp/minikube/kubeadm.yaml
```

```
CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
admin.conf                 Oct 23, 2027 18:16 UTC   364d            ca                      no
apiserver                  Oct 22, 2029 18:16 UTC   2y364d          ca                      no
apiserver-etcd-client      Oct 23, 2027 18:16 UTC   364d            etcd-ca                 no
apiserver-kubelet-client   Oct 23, 2027 18:16 UTC   364d            ca                      no
controller-manager.conf    Oct 23, 2027 18:16 UTC   364d            ca                      no
etcd-healthcheck-client    Oct 23, 2027 18:16 UTC   364d            etcd-ca                 no
etcd-peer                  Oct 23, 2027 18:16 UTC   364d            etcd-ca                 no
etcd-server                Oct 23, 2027 18:16 UTC   364d            etcd-ca                 no
front-proxy-client         Oct 23, 2027 18:16 UTC   364d            front-proxy-ca          no
scheduler.conf             Oct 23, 2027 18:16 UTC   364d            ca                      no
super-admin.conf           Oct 23, 2027 18:16 UTC   364d            ca                      no

CERTIFICATE AUTHORITY   EXPIRES                  RESIDUAL TIME   EXTERNALLY MANAGED
ca                      Oct 20, 2036 18:16 UTC   9y              no
etcd-ca                 Oct 20, 2036 18:16 UTC   9y              no
front-proxy-ca          Oct 20, 2036 18:16 UTC   9y              no
```

| Certificat | Fichier | Signé par | Rôle |
|---|---|---|---|
| `apiserver` | `pki/apiserver.crt` | `ca` | certificat serveur de l'API |
| `apiserver-kubelet-client` | `pki/apiserver-kubelet-client.crt` | `ca` | l'apiserver parle aux kubelets (`logs`, `exec`) |
| `apiserver-etcd-client` | `pki/apiserver-etcd-client.crt` | `etcd-ca` | l'apiserver parle à etcd (rangé à la racine de `pki/`) |
| `front-proxy-client` | `pki/front-proxy-client.crt` | `front-proxy-ca` | couche d'agrégation (metrics-server…) |
| `etcd-server`, `etcd-peer` | `pki/etcd/server.crt`, `peer.crt` | `etcd-ca` | etcd vers ses clients, et entre membres (usages serveur **et** client) |
| `etcd-healthcheck-client` | `pki/etcd/healthcheck-client.crt` | `etcd-ca` | client de santé |

Pour lire un certificat sans kubeadm : `sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate -subject`, et `-ext subjectAltName` pour les noms qu'il couvre.

#### 19.7.2 Renouveler à la main

```bash
# sur chaque control plane, l'un après l'autre
sudo kubeadm certs renew all
```

```
[renew] Reading configuration from the "kubeadm-config" ConfigMap in namespace "kube-system"...
[renew] Use 'kubeadm init phase upload-config kubeadm --config your-config-file' to re-upload it.

certificate embedded in the kubeconfig file for the admin to use and for kubeadm itself renewed
certificate for serving the Kubernetes API renewed
…
certificate embedded in the kubeconfig file for the super-admin renewed

Done renewing certificates. You must restart the kube-apiserver, kube-controller-manager, kube-scheduler and etcd, so that they can use the new certificates.
```

Le renouvellement est **inconditionnel**, quelle que soit la date d'expiration, et réutilise les attributs du certificat existant (CN, organisation, SAN) plutôt que la ConfigMap. `kubeadm certs renew apiserver` (ou `admin.conf`, `etcd-server`…) renouvelle un seul certificat. Il ne renouvelle **jamais** une CA : kubeadm ne sait pas faire tourner les CA.

La dernière ligne est la plus importante. Les composants ne relisent pas tous leurs certificats à chaud : il faut **redémarrer les pods statiques**, et ni `kubectl delete pod` (qui ne supprime que le miroir) ni `systemctl restart kubelet` ne le font. La méthode officielle sort les manifestes du dossier, attend que le kubelet arrête les pods (sa scrutation, `fileCheckFrequency`, vaut 20 s ; en pratique il réagit en quelques secondes), puis les remet :

```bash
# sur cp1
sudo mkdir -p /root/manifests-pause
sudo mv /etc/kubernetes/manifests/{etcd,kube-apiserver,kube-controller-manager,kube-scheduler}.yaml /root/manifests-pause/
sleep 20; sudo crictl ps --name 'kube-apiserver|etcd'          # plus rien
sudo mv /root/manifests-pause/*.yaml /etc/kubernetes/manifests/
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config         # le kubeconfig copié contient l'ANCIEN certificat
```

On déplace **seulement** les quatre manifestes du control plane : `kube-vip.yaml`, dans le même dossier, porte l'adresse virtuelle et reste en place. Une alternative plus fine arrête le conteneur et laisse le kubelet le relancer : `sudo crictl stop $(sudo crictl ps --name kube-apiserver -q)`. Sur un cluster HA, on traite un control plane à la fois.

#### 19.7.3 Le renouvellement automatique

`kubeadm upgrade apply` et `kubeadm upgrade node` renouvellent les certificats de chaque composant qu'ils mettent à jour : `etcd-server`, `etcd-peer`, `etcd-healthcheck-client` pour etcd local ; `apiserver`, `apiserver-kubelet-client`, `front-proxy-client` et `apiserver-etcd-client` pour l'apiserver ; les certificats embarqués dans `controller-manager.conf` et `scheduler.conf` ; enfin ceux d'`admin.conf` et de `super-admin.conf`. Un cluster mis à jour au moins une fois par an n'expire donc jamais, et c'est le comportement voulu par kubeadm. `--certificate-renewal=false` le désactive. Les CA et `kubelet.conf` ne sont pas concernés. Un composant dont le manifeste ne change pas (même version, relance avec `--force`) n'est pas redémarré, et ses certificats ne sont pas renouvelés.

### 19.8 `kubeadm reset` et retrait d'un nœud

`kubeadm reset` défait, au mieux, ce qu'`init` ou `join` a écrit sur **la machine**. Il enchaîne trois phases : `preflight`, `remove-etcd-member` (sur un control plane à etcd empilé : retire le membre local du cluster etcd, puis vide le dossier de données) et `cleanup-node`, qui arrête le kubelet, démonte et vide `/var/lib/kubelet`, supprime les conteneurs gérés par Kubernetes, vide `/etc/kubernetes/manifests` et le dossier des certificats (`/etc/kubernetes/pki`), supprime `admin.conf`, `super-admin.conf`, `kubelet.conf`, `bootstrap-kubelet.conf`, `controller-manager.conf` et `scheduler.conf`, et vide `/etc/kubernetes/tmp` si on le demande (`--cleanup-tmp-dir`).

Il **ne fait pas** quatre choses, dont les trois premières sont rappelées par son message de fin : il ne nettoie ni la configuration du CNI (`/etc/cni/net.d`), ni les règles réseau de kube-proxy (iptables, nftables, IPVS), ni `$HOME/.kube/config`, et il **ne supprime pas l'objet Node** de l'API. En etcd externe, il ne touche à aucune donnée etcd. La méthode officielle pour les règles réseau lance `kube-proxy --cleanup` dans un conteneur de l'image `kube-proxy` ; sur un nœud qui quitte le cluster, supprimer les tables de kube-proxy suffit.

```bash
# depuis cp1
kubectl drain w2 --ignore-daemonsets --delete-emptydir-data --force
# sur w2
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d
sudo nft delete table ip kube-proxy     # kube-proxy en mode nftables : tables « kube-proxy »
sudo nft delete table ip6 kube-proxy    # des familles ip et ip6
rm -rf $HOME/.kube
# depuis cp1
kubectl delete node w2
```

Pour rejoindre ensuite : nouveau jeton (19.3.3) et `kubeadm join`. Si on oublie de supprimer `/etc/cni/net.d` et qu'un autre CNI est déployé plus tard, deux configurations se concurrencent. Si on oublie `kubectl delete node`, l'objet reste `NotReady` jusqu'au retour d'un nœud du même nom. Pour un control plane **mort** (qu'on ne peut plus `reset`), son membre etcd reste dans le cluster et réduit la tolérance aux pannes : on le retire avec `etcdctl member remove <ID>` depuis un membre vivant (chapitre 20.10.3), puis `kubectl delete node`.

### 19.9 Pièges courants

```
Piège 1 : Le dépôt de paquets resté sur l'ancienne mineure
══════════════════════════════════════════════════════════
  SYMPTÔME : apt-get install kubeadm='1.37.1-*' → "Version '1.37.1-*' for
             'kubeadm' was not found" ; apt-cache madison ne liste que 1.36.x.
  BON      : changer v1.36 → v1.37 dans /etc/apt/sources.list.d/kubernetes.list,
             puis apt-get update, sur CHAQUE nœud.

Piège 2 : upgrade apply avec l'ancien kubeadm
═════════════════════════════════════════════
  MAUVAIS  : kubeadm upgrade apply v1.37.1 (kubeadm encore en 1.36)
  SYMPTÔME : "... is at least one minor release higher than the kubeadm
             minor release (37 > 36). Such an upgrade is not supported"
  BON      : unhold, installer kubeadm 1.37.1, hold, kubeadm version -o short.

Piège 3 : upgrade apply sur un autre control plane que le premier
═════════════════════════════════════════════════════════════════
  MAUVAIS  : kubeadm upgrade apply v1.37.1 sur cp2
  BON      : kubeadm upgrade node sur cp2, cp3 et les workers.

Piège 4 : Croire la colonne VERSION de kubectl get nodes
════════════════════════════════════════════════════════
  SYMPTÔME : "cp1 est encore en v1.36.5" juste après upgrade apply.
  CAUSE    : VERSION = version du kubelet, pas du control plane.
  BON      : finir par kubelet + daemon-reload + restart ; vérifier
             kubectl version et les images des pods statiques.

Piège 5 : Oublier daemon-reload, restart ou uncordon
════════════════════════════════════════════════════
  SYMPTÔME : le paquet kubelet est en 1.37.1 mais le nœud affiche 1.36.5 ;
             ou le nœud est Ready,SchedulingDisabled.
  BON      : systemctl daemon-reload && systemctl restart kubelet ;
             kubectl uncordon <nœud>.

Piège 6 : Renouveler les certificats sans redémarrer les composants
═══════════════════════════════════════════════════════════════════
  MAUVAIS  : kubeadm certs renew all, puis rien
  SYMPTÔME : check-expiration montre les nouvelles dates, mais l'apiserver
             présente toujours l'ancien certificat, qui finit par expirer.
  BON      : redémarrer etcd, apiserver, controller-manager, scheduler
             (manifestes sortis puis remis) et recopier admin.conf.

Piège 7 : check-expiration sur minikube sans --config
═════════════════════════════════════════════════════
  SYMPTÔME : couldn't load the certificate file /etc/kubernetes/pki/ca.crt
  BON      : --config /var/tmp/minikube/kubeadm.yaml
             ou --cert-dir /var/lib/minikube/certs

Piège 8 : Rejoindre avec un jeton expiré
════════════════════════════════════════
  SYMPTÔME : "could not find a JWS signature in the cluster-info ConfigMap
             for token ID ..."
  BON      : kubeadm token create --print-join-command sur un control plane.

Piège 9 : reset sans nettoyage ni delete node
═════════════════════════════════════════════
  SYMPTÔME : le nœud rejoint mais le réseau des pods est incohérent, ou
             un Node fantôme reste NotReady.
  BON      : rm -rf /etc/cni/net.d, règles nftables/iptables, $HOME/.kube,
             puis kubectl delete node depuis le control plane.
```

> [!summary] À retenir
> - kubeadm 1.37 ne lit que l'API de configuration `kubeadm.k8s.io/v1beta4` ; la ConfigMap `kube-system/kubeadm-config` est sa mémoire, relue par `join` et `upgrade`.
> - Un nœud se prépare par : modules `overlay` et `br_netfilter`, `ip_forward=1` (bloquant), swap désactivé ou toléré (`failSwapOn: false`), cgroup v2 (`failCgroupV1: true` depuis 1.35), containerd 2.x avec `SystemdCgroup = true`, paquets d'un dépôt pkgs.k8s.io **par mineure**, `apt-mark hold`.
> - `kubeadm token create --print-join-command` remplace un jeton expiré (24 h par défaut) ; `--certificate-key` et `kubeadm init phase upload-certs --upload-certs` servent aux control planes (clé et Secret valables 2 h).
> - Décalage admis : apiservers à ±1 mineure, controller-manager et scheduler jamais plus récents, kubelet et kube-proxy jusqu'à trois mineures de retard, kubectl ±1. kubeadm met à jour une mineure à la fois.
> - Ordre de mise à jour : dépôt sur chaque nœud ; premier control plane `upgrade plan` puis `upgrade apply vX.Y.Z` ; autres control planes et workers `upgrade node` ; sur chaque nœud drain, kubelet (+ kubectl), `daemon-reload`, `restart kubelet`, uncordon.
> - CoreDNS et kube-proxy ne montent qu'avec le dernier control plane ; etcd passe de 3.6.8 à 3.7.0 et CoreDNS de v1.14.2 à v1.14.6 entre 1.36 et 1.37.
> - Certificats feuilles : 1 an ; CA : 10 ans. `kubeadm upgrade` les renouvelle au passage ; `kubeadm certs renew all` exige ensuite de redémarrer les pods statiques et de recopier `admin.conf`. `kubelet.conf` tourne tout seul.
> - `kubeadm reset` ne nettoie ni le CNI, ni les règles réseau, ni `$HOME/.kube`, ni l'objet Node.

### 19.10 Exercices

#### Exercice 19.1 — Lire la configuration kubeadm du lab

**Point de départ** : fin du chapitre 18, ou instantané I4.

Dans le nœud `cka`, retrouve dans le fichier de configuration utilisé par minikube la version de l'API kubeadm, le port de l'API, le dossier des certificats, le dossier des données etcd, le réseau des pods et le `controlPlaneEndpoint`. Depuis ton poste, compare avec la ConfigMap `kube-system/kubeadm-config` et relève les durées de validité des certificats et l'algorithme des clés. Enfin, vérifie le mode de kube-proxy.

> [!example]- Solution
> ```bash
> minikube -p cka ssh
> # dans le nœud cka
> sudo grep -E '^(apiVersion|kind)|bindPort|certificatesDir|dataDir|podSubnet|controlPlaneEndpoint' \
>   /var/tmp/minikube/kubeadm.yaml
> exit
> # sur le poste
> kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' \
>   | grep -E 'certificatesDir|ValidityPeriod|encryptionAlgorithm|clusterName|controlPlaneEndpoint'
> kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode'
> ```
>
> Le fichier sur disque est une particularité de minikube ; sur un cluster d'examen, seule la ConfigMap existe, et c'est elle que relisent `join` et `upgrade`. Les deux sources doivent concorder : `kubeadm.k8s.io/v1beta4`, `bindPort: 8443`, `certificatesDir: /var/lib/minikube/certs`, `dataDir: /var/lib/minikube/etcd`, `podSubnet: "10.244.0.0/16"`, `controlPlaneEndpoint: control-plane.minikube.internal:8443`, et dans la ConfigMap `certificateValidityPeriod: 8760h0m0s`, `caCertificateValidityPeriod: 87600h0m0s`, `encryptionAlgorithm: RSA-2048`, `clusterName: mk`.
>
> **Vérification** : la dernière commande affiche `mode: iptables`, et chaque valeur relevée correspond au tableau de la section 19.1.3.

#### Exercice 19.2 — Surveiller l'expiration des certificats

**Point de départ** : exercice 19.1.

Dans le nœud `cka`, affiche l'expiration de tous les certificats gérés par kubeadm. Explique pourquoi la commande sans option échoue, et pourquoi le certificat `apiserver` ne vaut pas un an. Confirme sa date de fin et ses noms alternatifs avec `openssl`.

> [!example]- Solution
> ```bash
> minikube -p cka ssh
> # dans le nœud cka
> sudo /var/lib/minikube/binaries/v1.37.0/kubeadm certs check-expiration    # échoue
> sudo /var/lib/minikube/binaries/v1.37.0/kubeadm certs check-expiration \
>   --config /var/tmp/minikube/kubeadm.yaml
> sudo openssl x509 -in /var/lib/minikube/certs/apiserver.crt -noout -enddate -ext subjectAltName
> exit
> ```
>
> Sans option, kubeadm cherche `/etc/kubernetes/pki/ca.crt` : la valeur par défaut du drapeau `--cert-dir` l'emporte sur la ConfigMap. Avec `--config`, il lit `certificatesDir: /var/lib/minikube/certs`. Le certificat `apiserver` est émis par minikube pour trois ans (`CertExpiration` de son profil) ; tous les autres, émis par kubeadm, valent un an, et les CA dix ans. Sur un cluster d'examen, `sudo kubeadm certs check-expiration` suffit.
>
> **Vérification** : la ligne `apiserver` affiche une durée résiduelle d'environ `2y364d` à la création du cluster, les autres environ `364d`, les CA `9y` ; `openssl` affiche la même date `notAfter` et des SAN qui contiennent `192.168.49.2` et `control-plane.minikube.internal`.

#### Exercice 19.3 — Jetons de jonction

**Point de départ** : exercice 19.2.

Dans le nœud `cka`, liste les jetons de bootstrap et repère ceux qui n'expirent jamais. Crée un jeton valable une heure en affichant la commande de jonction complète, recalcule toi-même le hash de la CA et compare-le à celui de la commande, puis supprime le jeton créé.

> [!example]- Solution
> ```bash
> minikube -p cka ssh
> # dans le nœud cka
> K=/var/lib/minikube/binaries/v1.37.0/kubeadm
> sudo $K token list
> sudo $K token create --ttl 1h --print-join-command
> sudo openssl x509 -pubkey -in /var/lib/minikube/certs/ca.crt \
>   | openssl pkey -pubin -outform der 2>/dev/null \
>   | openssl dgst -sha256 -hex | sed 's/^.* //'
> sudo $K token list
> sudo $K token delete <id>          # les 6 premiers caractères du jeton créé
> exit
> ```
>
> `token list` montre les jetons que minikube a créés pour joindre `cka-m02` et `cka-m03`, avec `<forever>` et `<never>` : minikube les crée avec `--ttl=0`, ce qu'on ne fait pas sur un vrai cluster. Si le cluster a moins d'un jour, une troisième ligne porte le jeton de 24 heures de `kubeadm init` (TTL `17h`, par exemple, sept heures après la création), que le contrôleur `tokencleaner` supprimera à son expiration. `--print-join-command` lit l'adresse et la CA dans `/etc/kubernetes/admin.conf` : la commande vise `control-plane.minikube.internal:8443`. Le hash calculé par `openssl` est celui qui suit `sha256:`. Rien n'est joint : la commande n'est pas exécutée.
>
> **Vérification** : le hash recalculé est identique à celui de la commande imprimée ; après `token delete`, `token list` ne montre plus le jeton d'une heure (son TTL affichait `59m` juste après la création).

#### Exercice 19.4 — Monter le cluster S1

**Point de départ** : cinq VM Debian 13 ou Ubuntu 24.04 neuves, nommées et adressées selon la section 19.1.1, avec `k8s-api.example` résolu vers 192.168.10.11 dans le `/etc/hosts` de chacune.

Prépare `cp1`, `w1` et `w2` (modules, sysctl persistants, swap, containerd 2.3 avec `SystemdCgroup = true`, paquets 1.36.5 retenus). Initialise `cp1` avec le fichier de la section 19.3.1, installe Flannel, joins `w1` et `w2` avec un jeton créé pour l'occasion. Prends l'instantané **S1**.

> [!example]- Solution
> ```bash
> # sur cp1, w1, w2 : préparation (détails : section 19.2 et ../kubeadm/03-preparation-des-noeuds.md)
> printf 'overlay\nbr_netfilter\n' | sudo tee /etc/modules-load.d/k8s.conf
> sudo modprobe overlay && sudo modprobe br_netfilter
> printf 'net.ipv4.ip_forward = 1\nnet.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\n' \
>   | sudo tee /etc/sysctl.d/k8s.conf
> sudo sysctl --system
> sudo swapoff -a && sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab && sudo systemctl mask swap.target
> stat -fc %T /sys/fs/cgroup/                       # cgroup2fs
> # containerd 2.3 installé (paquet containerd.io 2.3.x ou binaires v2.3.7), puis :
> containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
> sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
> sudo systemctl restart containerd
> # dépôt v1.36 et paquets : commandes de la section 19.2.6
>
> # sur cp1
> sudo kubeadm init --config kubeadm.yaml --upload-certs
> mkdir -p $HOME/.kube && sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
> sudo chown $(id -u):$(id -g) $HOME/.kube/config
> kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
> sudo kubeadm token create --print-join-command
>
> # sur w1 puis w2 : la commande imprimée
> sudo kubeadm join k8s-api.example:6443 --token <jeton> --discovery-token-ca-cert-hash sha256:<hash>
> ```
>
> L'ordre compte : sans `br_netfilter` chargé, les clés `bridge-nf-call-*` n'existent pas et `sysctl --system` les signale ; sans `SystemdCgroup = true`, containerd 2.x annonce le pilote `cgroupfs`, que le kubelet adopte (19.2.5) : l'init réussit, mais le nœud tourne avec deux gestionnaires de cgroups concurrents sur un hôte systemd, configuration que la documentation (page « Container Runtimes ») signale comme instable sous pression de ressources. Le jeton de l'init suffirait s'il a moins de 24 heures ; en créer un est le geste à retenir.
>
> **Vérification** : sur `cp1`, `kubectl get nodes` montre `cp1`, `w1` et `w2` en `Ready`, version `v1.36.5` ; `kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode'` affiche `mode: nftables` ; `apt-mark showhold` liste `kubeadm`, `kubectl`, `kubelet`. Prends alors l'instantané S1.

#### Exercice 19.5 — Retirer puis rejoindre un worker

**Point de départ** : exercice 19.4, ou instantané S1.

Retire proprement `w2` du cluster : vide-le, réinitialise-le, nettoie ce que `kubeadm reset` laisse, supprime l'objet Node. Fais-le ensuite rejoindre le cluster avec un jeton valable deux heures.

> [!example]- Solution
> ```bash
> # sur cp1
> kubectl drain w2 --ignore-daemonsets --delete-emptydir-data --force
> # sur w2
> sudo kubeadm reset -f
> sudo rm -rf /etc/cni/net.d
> sudo nft delete table ip kube-proxy && sudo nft delete table ip6 kube-proxy
> rm -rf $HOME/.kube
> # sur cp1
> kubectl delete node w2
> sudo kubeadm token create --ttl 2h --print-join-command
> # sur w2
> sudo kubeadm join k8s-api.example:6443 --token <jeton> --discovery-token-ca-cert-hash sha256:<hash>
> ```
>
> `reset` arrête le kubelet, supprime les conteneurs, vide `/var/lib/kubelet`, `/etc/kubernetes/manifests` et `/etc/kubernetes/pki`, et efface les kubeconfigs ; il laisse le CNI, les règles de kube-proxy et l'objet Node. Un nouveau join remet un nœud du même nom, avec un nouveau certificat de kubelet.
>
> **Vérification** : entre `delete node` et le join, `kubectl get nodes` ne montre plus `w2` ; après le join, `w2` repasse `Ready` en quelques secondes (le DaemonSet Flannel y redémarre) et `sudo ls /etc/cni/net.d` sur `w2` montre `10-flannel.conflist`. Le cluster est équivalent à S1.

#### Exercice 19.6 — Passer en haute disponibilité

**Point de départ** : exercice 19.5, ou instantané S1.

Prépare `cp2` et `cp3` comme à l'exercice 19.4. Déploie kube-vip sur `cp1` pour l'adresse 192.168.10.10 ([chapitre 6.5 du cours kubeadm](../kubeadm/06-haute-disponibilite.md)), fais pointer `k8s-api.example` vers 192.168.10.10 sur les cinq machines, puis joins `cp2` et `cp3` comme control planes. Vérifie les trois membres etcd. Prends l'instantané **S2**.

> [!example]- Solution
> ```bash
> # sur cp1 (root) : manifeste kube-vip, interface eth0 (cf. ../kubeadm/06-haute-disponibilite.md)
> # → /etc/kubernetes/manifests/kube-vip.yaml ; puis, sur les cinq machines :
> sudo sed -i '/k8s-api\.example/d' /etc/hosts
> echo '192.168.10.10 k8s-api.example' | sudo tee -a /etc/hosts
> getent hosts k8s-api.example                              # 192.168.10.10
>
> # sur cp1
> sudo kubeadm init phase upload-certs --upload-certs       # note la clé
> sudo kubeadm token create --print-join-command --certificate-key <clé>
>
> # sur cp2 (puis cp3 avec --apiserver-advertise-address 192.168.10.13)
> sudo kubeadm join k8s-api.example:6443 --token <jeton> \
>   --discovery-token-ca-cert-hash sha256:<hash> \
>   --control-plane --certificate-key <clé> --apiserver-advertise-address 192.168.10.12
> # copie de kube-vip.yaml depuis cp1 vers /etc/kubernetes/manifests/ de cp2 et cp3, APRÈS le join
>
> # sur cp1
> kubectl -n kube-system exec etcd-cp1 -- etcdctl --endpoints=https://127.0.0.1:2379 \
>   --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
>   --key=/etc/kubernetes/pki/etcd/server.key member list
> ```
>
> La clé de certificats et le Secret `kubeadm-certs` ne vivent que deux heures : on les republie juste avant les joins. Le manifeste kube-vip monte `admin.conf`, qui n'existe sur `cp2` et `cp3` qu'après leur join. Chaque nouveau membre etcd entre en learner puis est promu.
>
> **Vérification** : `kubectl get nodes` montre `cp1`, `cp2`, `cp3` avec le rôle `control-plane` et `w1`, `w2`, tous `Ready` en `v1.36.5` ; `member list` affiche trois lignes `started` terminées par `false` ; `ip -br addr` sur le leader du Lease `plndr-cp-lock` montre 192.168.10.10. Prends l'instantané S2.

#### Exercice 19.7 — Mettre à jour le cluster en 1.37.1

**Point de départ** : exercice 19.6, ou instantané S2.

Mets à jour tout le cluster de 1.36.5 vers 1.37.1, sans saut de procédure : `cp1` d'abord, puis `cp2`, `cp3`, `w1` et `w2`. Note sur quel nœud CoreDNS et kube-proxy sont mis à jour. Prends l'instantané **S3**.

> [!example]- Solution
> ```bash
> # sur les cinq machines
> sudo sed -i 's#/v1.36/deb/#/v1.37/deb/#' /etc/apt/sources.list.d/kubernetes.list && sudo apt-get update
>
> # sur cp1
> sudo apt-mark unhold kubeadm && sudo apt-get install -y kubeadm='1.37.1-*' && sudo apt-mark hold kubeadm
> sudo kubeadm upgrade plan
> sudo kubeadm upgrade apply v1.37.1 -y
> kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
> kubectl drain cp1 --ignore-daemonsets
> sudo apt-mark unhold kubelet kubectl && sudo apt-get install -y kubelet='1.37.1-*' kubectl='1.37.1-*' \
>   && sudo apt-mark hold kubelet kubectl
> sudo systemctl daemon-reload && sudo systemctl restart kubelet
> kubectl uncordon cp1
>
> # sur cp2, puis cp3 : kubeadm 1.37.1, puis
> sudo kubeadm upgrade node
> # drain (depuis cp1), kubelet + kubectl, daemon-reload, restart, uncordon
>
> # sur w1, puis w2
> sudo apt-mark unhold kubeadm kubectl && sudo apt-get install -y kubeadm='1.37.1-*' kubectl='1.37.1-*' \
>   && sudo apt-mark hold kubeadm kubectl
> sudo kubeadm upgrade node
> # drain (depuis cp1), kubelet, daemon-reload, restart, uncordon (depuis cp1)
> ```
>
> Sur `cp1` et `cp2`, la phase `addon` affiche `Skipping upgrade of addons because control plane instances [...] have not been upgraded` ; c'est `upgrade node` sur `cp3` qui applique CoreDNS v1.14.6 et kube-proxy v1.37.1. Pendant toute la mise à jour, un seul nœud est vidé à la fois, et les workers ne sont touchés qu'une fois les trois control planes à jour.
>
> **Vérification** : `kubectl get nodes` affiche les cinq nœuds `Ready` en `v1.37.1` ; `kubectl version` donne `Server Version: v1.37.1` ; `kubectl -n kube-system get pods -o custom-columns=POD:.metadata.name,IMAGE:.spec.containers[0].image | grep -E 'etcd|coredns|kube-proxy'` montre `etcd:3.7.0-0`, `coredns:v1.14.6` et `kube-proxy:v1.37.1` ; `member list` affiche toujours trois membres. Prends l'instantané S3.

#### Exercice 19.8 — Renouveler les certificats d'un control plane

**Point de départ** : exercice 19.7, ou instantané S3.

Sur `cp1`, constate que la mise à jour a déjà renouvelé les certificats. Renouvelle-les tous à la main, fais-les prendre en compte par les composants sans toucher à kube-vip, et mets à jour ton kubeconfig.

> [!example]- Solution
> ```bash
> # sur cp1
> sudo kubeadm certs check-expiration                 # dates = jour de la mise à jour + 1 an
> sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate
> sudo kubeadm certs renew all
> sudo mkdir -p /root/manifests-pause
> sudo mv /etc/kubernetes/manifests/{etcd,kube-apiserver,kube-controller-manager,kube-scheduler}.yaml /root/manifests-pause/
> sleep 20
> sudo mv /root/manifests-pause/*.yaml /etc/kubernetes/manifests/
> sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
> sudo chown $(id -u):$(id -g) $HOME/.kube/config
> ```
>
> Le renouvellement écrit de nouveaux fichiers ; seuls les processus qui les relisent en profitent. Sortir les quatre manifestes arrête etcd et l'apiserver de `cp1` : le cluster continue de répondre par `cp2` et `cp3` (etcd garde son quorum à deux sur trois). `kube-vip.yaml` reste en place. Sur un vrai cluster HA, on refait la même chose sur `cp2` puis `cp3`.
>
> **Vérification** : `sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate` donne une date postérieure à la précédente ; `echo | openssl s_client -connect 192.168.10.11:6443 2>/dev/null | openssl x509 -noout -enddate` affiche **la même** date (l'apiserver présente bien le nouveau certificat) ; `kubectl get nodes` répond avec le kubeconfig recopié.

---
