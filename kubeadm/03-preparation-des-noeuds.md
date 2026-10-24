## 3. Préparation des nœuds

kubeadm ne s'installe pas sur une machine quelconque. Chaque prérequis a une raison d'être, et le contrôle préalable (*preflight*) n'en vérifie qu'une partie. Comprendre ces raisons permet de lire ses messages au lieu de les contourner.

### 3.1 Le preflight

Le preflight s'exécute au début de `kubeadm init` et de `kubeadm join`. Ses contrôles sont de deux sortes :

```
[ERROR …]    → bloque la commande
[WARNING …]  → la laisse continuer

  On peut ignorer une erreur :
    --ignore-preflight-errors=<NomDuControle>   (ou =all)

  C'est presque toujours une mauvaise idée : l'erreur signale un
  problème qui ressurgira plus tard, sous une forme moins lisible.
```

Le preflight se lance aussi seul, sans rien modifier sur la machine :

```bash
sudo kubeadm init phase preflight
```

Quelques contrôles notables :

| Contrôle | Niveau | Condition |
|----------|--------|-----------|
| `NumCPU` | Erreur | Au moins 2 CPU sur un control plane |
| `Mem` | Erreur | Au moins 1700 Mo sur un control plane |
| `FileContent--proc-sys-net-ipv4-ip_forward` | Erreur | `ip_forward` à 1 |
| `Port-6443`, `Port-10250`… | Erreur | Ports libres |
| `DirAvailable--var-lib-etcd` | Erreur | Répertoire d'etcd vide |
| `Swap` | **Avertissement** | Swap actif (voir 3.3) |

### 3.2 Identité des machines

Chaque nœud doit avoir un **nom d'hôte**, une **adresse MAC** et un **`product_uuid`** uniques. Le problème se pose surtout avec des VM clonées depuis un même modèle. Deux nœuds portant le même nom s'écrasent l'un l'autre dans l'objet Node, et certains CNI identifient les machines par leur MAC ou leur UUID.

```bash
hostnamectl
ip -br link
sudo cat /sys/class/dmi/id/product_uuid
```

Le nom du nœud dans Kubernetes est, par défaut, le nom d'hôte de la machine. On peut l'imposer avec `nodeRegistration.name` dans la configuration de kubeadm.

### 3.3 Le swap

Par défaut, le kubelet **refuse de démarrer** si du swap est actif : son paramètre `failSwapOn` vaut `true`.

La raison est historique. La gestion de la mémoire des pods (requêtes, limites, éviction, classes de QoS) a été conçue en supposant que la mémoire d'un conteneur est de la mémoire vive. Un conteneur qui déborderait silencieusement sur le disque fausserait tous ces calculs.

```
Le swap en 1.35 :
═════════════════

  NodeSwap est stable depuis la 1.34, mais DÉSACTIVÉ tant qu'on ne
  le demande pas. Il exige :
    - cgroup v2
    - failSwapOn: false                    (KubeletConfiguration)
    - memorySwap.swapBehavior: LimitedSwap (sinon NoSwap : les pods
                                            n'utilisent pas le swap)

  Le preflight de kubeadm ne lève qu'un AVERTISSEMENT [WARNING Swap] :
  il ne connaît pas la configuration que recevra le kubelet.

  Conséquence piégeuse :
    kubeadm init   → preflight OK (avertissement noyé dans la sortie)
                   → phase kubelet-start : le kubelet refuse de démarrer
                   → phase wait-control-plane : délai dépassé
                   → message final qui NE PARLE PAS du swap
    Seuls les journaux du kubelet le nomment.
```

Pour l'examen comme pour ce cours, on désactive le swap :

```bash
sudo swapoff -a
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
sudo systemctl mask swap.target
```

Le `mask swap.target` n'est pas décoratif. Sur un système à systemd, une partition dont le type GPT est « Linux swap » est activée automatiquement par `systemd-gpt-auto-generator`, **même si `/etc/fstab` n'en parle pas**. Le swap réapparaît alors à chaque démarrage, et le kubelet refuse de repartir après un simple redémarrage de la machine. Masquer `swap.target` empêche l'activation de tous les swaps, quelle que soit leur origine.

### 3.4 Modules et paramètres du noyau

```
Ce dont Kubernetes a besoin dans le noyau :
═══════════════════════════════════════════

  overlay        → système de fichiers overlayfs, utilisé par
                   containerd pour empiler les couches des images

  br_netfilter   → fait passer le trafic qui traverse un pont Linux
                   dans netfilter. Sans lui, les règles de kube-proxy
                   ou du CNI ne voient pas le trafic échangé entre
                   deux pods branchés sur le même pont (cni0).

  net.ipv4.ip_forward = 1
                 → le nœud route le trafic des pods.
                   Contrôle BLOQUANT du preflight.

  net.bridge.bridge-nf-call-iptables  = 1
  net.bridge.bridge-nf-call-ip6tables = 1
                 → activent le comportement de br_netfilter
                   (ces clés n'existent que si le module est chargé)
```

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system
```

**Vérifier ce qu'un module fournit, pas `lsmod`** : c'est un réflexe d'expert.

```
Pourquoi lsmod ment :
═════════════════════

  Cas 1 : module compilé dans le noyau
    → il fonctionne, mais n'apparaît JAMAIS dans lsmod.

  Cas 2 : système durci
    → certains profils de durcissement posent dans /etc/modprobe.d/ :
         install overlay /bin/true
    → "modprobe overlay" exécute /bin/true, sort en SUCCÈS
      et ne charge rien.

  La seule vérification fiable porte sur ce que le module APPORTE :
    grep -w overlay /proc/filesystems     → overlayfs disponible
    ls /proc/sys/net/bridge/              → br_netfilter actif
```

### 3.5 Le runtime de conteneurs

Le kubelet ne lance pas les conteneurs lui-même. Il délègue ce travail à un **runtime** qui parle l'interface **CRI** (Container Runtime Interface), le plus souvent **containerd**.

```
  kubelet ──── CRI (gRPC) ────▶ containerd ──▶ runc ──▶ conteneur
                                     │
                    unix:///run/containerd/containerd.sock
```

#### Le cgroup driver

Le kubelet et le runtime créent chacun des cgroups pour les pods. Ils doivent le faire **de la même manière**. Sur un système à systemd avec cgroup v2, ce pilote est `systemd`. S'ils divergent, deux gestionnaires se disputent la même arborescence de cgroups : les pods redémarrent en boucle, sans message d'erreur clair.

```bash
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd

containerd config dump | grep SystemdCgroup     # doit afficher true
```

La section qui porte ce réglage dépend de la version de containerd :

```toml
# containerd 2.x (format de configuration version 3)
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = true

# containerd 1.x (format de configuration version 2)
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
```

#### containerd 1.x arrive en fin de course

```
Qui décide du cgroup driver ?
═════════════════════════════

  Historiquement : le kubelet décide (cgroupDriver dans config.yaml)
    → kubeadm le fixe à "systemd" depuis la 1.22.

  En 1.35 : le kubelet DEMANDE au runtime, par l'appel CRI RuntimeConfig
    (feature gate KubeletCgroupDriverFromCRI).
    ├── containerd 2.x : répond → c'est SystemdCgroup de containerd
    │                    qui fait foi
    └── containerd 1.x : ne connaît pas l'appel → le kubelet se rabat
                         sur son propre réglage

  En 1.36 : le repli disparaît.
    → un kubelet 1.36 ou plus récent REFUSE containerd 1.x.

  Les paquets des distributions sont parfois encore en 1.7 :
    containerd --version
```

#### crictl

`crictl` est l'outil en ligne de commande qui interroge le runtime par la CRI. Il sert constamment en dépannage, surtout quand l'API server est tombé. On lui indique le socket une fois pour toutes :

```bash
sudo crictl config --set runtime-endpoint=unix:///run/containerd/containerd.sock
```

| Commande | Rôle |
|----------|------|
| `crictl ps` | Conteneurs en cours |
| `crictl ps -a` | Tous les conteneurs, y compris terminés |
| `crictl pods` | Sandboxes de pods |
| `crictl logs <id>` | Sortie d'un conteneur |
| `crictl inspect <id>` | Détail d'un conteneur (montages, état, code de sortie) |
| `crictl images` | Images présentes sur le nœud |

### 3.6 Les paquets et pkgs.k8s.io

Les paquets `kubelet`, `kubeadm` et `kubectl` sont publiés sur `pkgs.k8s.io`. Ce dépôt a une particularité qui pèse sur toute la vie du cluster : **un dépôt distinct par version mineure**. Les anciens dépôts `apt.kubernetes.io` et `yum.kubernetes.io` sont gelés depuis 2023.

```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
```

```
Un dépôt par mineure : la conséquence
═════════════════════════════════════

  /etc/apt/sources.list.d/kubernetes.list
    deb … https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /
                                             ─────
                                               │
  apt-cache madison kubeadm                    │
    kubeadm | 1.35.2-1.1 | …                   │  ne liste QUE
    kubeadm | 1.35.1-1.1 | …                   │  des 1.35.x
    kubeadm | 1.35.0-1.1 | …                   │

  Pour passer en 1.36 : changer d'abord l'URL du dépôt.
  C'est l'oubli le plus fréquent lors d'une mise à jour (chapitre 7).
```

Le `apt-mark hold` empêche une mise à jour système de faire monter ces paquets par accident. Un kubelet mis à jour avant le control plane sortirait des écarts de version tolérés (chapitre 7.2).

**Note** : juste après l'installation, le kubelet **redémarre en boucle**. C'est le comportement attendu. Il cherche `/var/lib/kubelet/config.yaml`, que seuls `kubeadm init` ou `kubeadm join` écriront, et systemd le relance toutes les quelques secondes en attendant. Il n'y a rien à corriger.

### 3.7 Les ports

```
┌──────────────────────── CONTROL PLANE ─────────────────────────┐
│  TCP 6443        kube-apiserver           ← tous               │
│  TCP 2379-2380   etcd (clients, pairs)    ← API server, etcd   │
│  TCP 10250       API du kubelet           ← control plane      │
│  TCP 10259       kube-scheduler           ← le nœud lui-même   │
│  TCP 10257       kube-controller-manager  ← le nœud lui-même   │
└────────────────────────────────────────────────────────────────┘
┌─────────────────────────── WORKER ─────────────────────────────┐
│  TCP 10250       API du kubelet           ← control plane      │
│  TCP 10256       kube-proxy (santé)       ← load balancers     │
│  TCP/UDP 30000-32767  Services NodePort   ← tous               │
└────────────────────────────────────────────────────────────────┘

  + les ports du CNI (Flannel en VXLAN : UDP 8472 entre nœuds)
```

Les ports 10257 et 10259 sont les ports sécurisés (HTTPS) du controller-manager et du scheduler. Les anciens ports non sécurisés 10251 et 10252, qu'on trouve encore dans de vieux tutoriels, n'existent plus.

### 3.8 Pièges courants

```
Piège 1 : Le swap qui revient au redémarrage
═════════════════════════════════════════════
  SYMPTÔME : après un reboot, le nœud reste NotReady, kubelet failed.
  CAUSE    : partition GPT de type swap activée par systemd,
             sans ligne dans /etc/fstab.
  BON      : systemctl mask swap.target

Piège 2 : Croire le preflight sur le swap
══════════════════════════════════════════
  MAUVAIS : "le preflight est passé, le nœud est prêt"
  → le swap n'est qu'un avertissement ; l'échec survient plus loin.
  BON     : swapon --show doit être vide AVANT l'init.

Piège 3 : Vérifier un module avec lsmod
════════════════════════════════════════
  MAUVAIS : lsmod | grep overlay
  BON     : grep -w overlay /proc/filesystems

Piège 4 : cgroup driver incohérent
═══════════════════════════════════
  SYMPTÔME : les pods du control plane redémarrent en boucle,
             l'init échoue à wait-control-plane.
  BON      : containerd config dump | grep SystemdCgroup → true

Piège 5 : Oublier apt-mark hold
════════════════════════════════
  → un "apt upgrade" de routine fait monter le kubelet au-dessus
    du control plane.
```

---
