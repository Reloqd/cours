## 1. Introduction et contexte

### 1.1 Qu'est-ce que kubeadm ?

kubeadm est l'outil officiel du projet Kubernetes pour **amorcer** (bootstrap) un cluster conforme sur des machines existantes. Il fabrique tout ce dont un control plane a besoin pour démarrer : une infrastructure de clés, des kubeconfigs, les manifestes des composants, la configuration du kubelet, les droits RBAC du bootstrap. Il fait ensuite entrer d'autres machines dans le cluster, et il sait mettre le tout à jour.

kubeadm n'est **pas** un gestionnaire de cluster. Il ne tourne pas en permanence : chaque commande s'exécute, écrit des fichiers et quelques objets dans l'API, puis rend la main. Aucun démon kubeadm ne surveille quoi que ce soit.

En tant qu'administrateur, tu utilises kubeadm pour répondre à des besoins comme :
- Monter un cluster de trois control planes et deux workers sur des VM.
- Passer de Kubernetes 1.34 à 1.35 sans interrompre les applications.
- Renouveler des certificats qui expirent dans dix jours.
- Remettre en état un control plane dont l'API server ne démarre plus.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                  UN CLUSTER CONSTRUIT AVEC KUBEADM                      │
│                                                                         │
│   CONTROL PLANE (cp1)                                                   │
│   ┌───────────────────────────────────────────────────────────────┐    │
│   │  systemd                                                       │    │
│   │  ┌──────────────┐    ┌──────────────┐                         │    │
│   │  │  containerd  │◀───│   kubelet    │  lit /etc/kubernetes/   │    │
│   │  │  (runtime)   │    │  (service)   │      manifests/*.yaml   │    │
│   │  └──────┬───────┘    └──────────────┘                         │    │
│   │         │ lance les pods statiques :                          │    │
│   │         ▼                                                      │    │
│   │  ┌────────┐ ┌───────────────┐ ┌────────────┐ ┌───────────┐    │    │
│   │  │  etcd  │ │kube-apiserver │ │ controller │ │ scheduler │    │    │
│   │  │ :2379  │ │    :6443      │ │  manager   │ │           │    │    │
│   │  └────────┘ └───────┬───────┘ └────────────┘ └───────────┘    │    │
│   └─────────────────────┼─────────────────────────────────────────┘    │
│                         │ HTTPS (certificats signés par la CA)         │
│          ┌──────────────┴───────────────┐                              │
│          ▼                              ▼                              │
│   WORKER (w1)                    WORKER (w2)                           │
│   ┌───────────────────┐          ┌───────────────────┐                 │
│   │ kubelet (service) │          │ kubelet (service) │                 │
│   │ containerd        │          │ containerd        │                 │
│   │ kube-proxy (DS)   │          │ kube-proxy (DS)   │                 │
│   │ CNI (DS)          │          │ CNI (DS)          │                 │
│   │ pods applicatifs  │          │ pods applicatifs  │                 │
│   └───────────────────┘          └───────────────────┘                 │
│                                                                         │
│   kubeadm : absent à l'exécution. Il a écrit les fichiers, c'est tout. │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Historique

```
Timeline :

2016 ──── Kubernetes 1.4 : première version de kubeadm (alpha)
   │      - Objectif : "kubeadm init" et "kubeadm join", deux commandes
   │      - Remplace les scripts d'installation maison de chaque projet
   │
2018 ──── Kubernetes 1.13 : kubeadm passe en GA (stable)
   │      - Configuration par fichier, phases rejouables
   │
2019 ──── Haute disponibilité simplifiée
   │      - kubeadm join --control-plane
   │      - --upload-certs : partage des CA par un Secret chiffré
   │
2021 ──── Kubernetes 1.22 : cgroup driver systemd par défaut
   │
2022 ──── Kubernetes 1.24 : suppression de dockershim
   │      - Docker n'est plus un runtime direct : containerd ou CRI-O
   │      Kubernetes 1.25 : fin de la taint "master", place à "control-plane"
   │
2023 ──── Dépôts de paquets pkgs.k8s.io (un dépôt par version mineure)
   │      - apt.kubernetes.io et yum.kubernetes.io gelés
   │      Kubernetes 1.29 : apparition de super-admin.conf
   │
2024 ──── Kubernetes 1.31 : API de configuration v1beta4
   │
2025 ──── Kubernetes 1.33 : kube-proxy en mode nftables stable
   │      Kubernetes 1.34 : support du swap (NodeSwap) stable
   │      Kubernetes 1.35 : mode ipvs de kube-proxy déprécié,
   │                        dernière version compatible containerd 1.x
   │
2026 ──── Kubernetes 1.36 (avril) puis 1.37 (26 août)
          - 1.37 : suppression de l'API de configuration v1beta3
          - Le programme du CKA reste aligné sur la 1.35
```

### 1.3 Positionnement dans l'écosystème

kubeadm n'est qu'une des façons d'obtenir un cluster. Il occupe une place précise : la brique de base, sur laquelle d'autres outils construisent.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                  OBTENIR UN CLUSTER KUBERNETES                          │
│                                                                         │
│  Automatisation au-dessus de kubeadm     Distributions autonomes        │
│  ───────────────────────────────────     ──────────────────────         │
│  ┌─────────────────────┐                 ┌──────────────────────┐       │
│  │ Kubespray           │                 │ k3s / RKE2           │       │
│  │ Ansible, s'appuie   │                 │ Binaire unique,      │       │
│  │ sur kubeadm         │                 │ composants embarqués │       │
│  └─────────────────────┘                 └──────────────────────┘       │
│  ┌─────────────────────┐                 ┌──────────────────────┐       │
│  │ Cluster API         │                 │ Talos, k0s           │       │
│  │ Fournisseur de      │                 │ OS ou distribution   │       │
│  │ bootstrap kubeadm   │                 │ dédiés               │       │
│  └─────────────────────┘                 └──────────────────────┘       │
│                                                                         │
│  Brique de base                          Services managés               │
│  ──────────────                          ────────────────               │
│  ┌─────────────────────┐                 ┌──────────────────────┐       │
│  │ kubeadm             │                 │ EKS, GKE, AKS…       │       │
│  │ Officiel, minimal,  │                 │ Control plane géré   │       │
│  │ conforme            │                 │ par le fournisseur   │       │
│  └─────────────────────┘                 └──────────────────────┘       │
└─────────────────────────────────────────────────────────────────────────┘
```

| Critère | kubeadm | Kubespray | Cluster API | k3s / RKE2 | Managé |
|---------|---------|-----------|-------------|------------|--------|
| **Périmètre** | Bootstrap du cluster | Machines + cluster | Cycle de vie déclaratif | Distribution complète | Tout le control plane |
| **CNI, LB, stockage** | À installer | Inclus (choix) | Selon fournisseur | Inclus | Inclus |
| **Contrôle fin** | Total | Élevé | Élevé | Moyen | Faible |
| **Accès au control plane** | Total | Total | Total | Total | Aucun |
| **Utilisé au CKA** | **Oui** | Non | Non | Non | Non |

**Pourquoi le CKA s'appuie sur kubeadm** : c'est l'outil de référence du projet, il produit un cluster sans couche propriétaire, et il expose tout ce qu'un administrateur doit savoir manipuler. Pods statiques, certificats, etcd, kubelet : un cluster kubeadm montre les mécanismes que les autres outils cachent.

### 1.4 kubeadm et la certification CKA

#### Le programme

Le CKA est un examen **pratique** : pas de QCM, uniquement des tâches à réaliser dans de vrais clusters. Le programme (CNCF, v1.35) se répartit en cinq domaines :

```
Répartition du CKA (programme v1.35) :
══════════════════════════════════════

  Troubleshooting                              30%  ██████████████████████████████
  Cluster Architecture, Installation & Config  25%  █████████████████████████
  Services & Networking                        20%  ████████████████████
  Workloads & Scheduling                       15%  ███████████████
  Storage                                      10%  ██████████

  kubeadm couvre l'essentiel du domaine à 25 % et une grande part
  du domaine à 30 % : sur un cluster kubeadm, dépanner un nœud ou
  un composant, c'est lire des pods statiques, des certificats et
  les journaux du kubelet.
```

#### Correspondance entre le programme et ce cours

| Compétence du programme officiel | Chapitres |
|----------------------------------|-----------|
| Prepare underlying infrastructure for installing a Kubernetes cluster | 3 |
| Create and manage Kubernetes clusters using kubeadm | 2, 4, 5, 10, 12 |
| Manage the lifecycle of Kubernetes clusters | 7, 8, 9, 12 |
| Implement and configure a highly-available control plane | 6 |
| Understand extension interfaces (CNI, CSI, CRI, etc.), pour CRI et CNI | 3, 4 |
| Troubleshoot clusters and nodes | 11 |
| Troubleshoot cluster components | 2, 11 |

Les autres compétences du domaine (RBAC, Helm et Kustomize, CRD et opérateurs) et les domaines Workloads, Storage et Networking ne relèvent pas de kubeadm. Elles sont hors du périmètre de ce cours.

**Note sur etcd** : le programme v1.35 ne cite plus nommément la sauvegarde et la restauration d'etcd. Elles relèvent de *Manage the lifecycle of Kubernetes clusters*, et les guides de préparation de 2026 les donnent toujours comme un sujet probable. Le chapitre 9 les traite en entier.

#### Le format de l'examen

Le chapitre 13 détaille l'environnement et les réflexes de l'examen. Retiens dès maintenant que :
- l'examen dure **2 heures**, en ligne et sous surveillance, pour 15 à 20 tâches pratiques ;
- le seuil de réussite est de **66 %** ;
- l'inscription comprend une seconde tentative gratuite et deux sessions du simulateur killer.sh ;
- la certification est valable **2 ans**.

### 1.5 L'environnement de lab du cours

Tout le cours, exercices compris, s'appuie sur un **même cluster d'entraînement**. Les noms, adresses et outils ci-dessous ne changent jamais d'un chapitre à l'autre.

#### Les machines

Cinq VM sous Debian ou Ubuntu, sur n'importe quel hyperviseur **capable de prendre des instantanés** :

| Rôle | Nom | Adresse | Ressources minimales |
|------|-----|---------|----------------------|
| Control plane | `cp1` | 192.168.10.11 | 2 vCPU, 2 Go |
| Control plane | `cp2` | 192.168.10.12 | 2 vCPU, 2 Go |
| Control plane | `cp3` | 192.168.10.13 | 2 vCPU, 2 Go |
| Worker | `w1` | 192.168.10.21 | 2 vCPU, 2 Go |
| Worker | `w2` | 192.168.10.22 | 2 vCPU, 2 Go |

Un control plane exige au moins 2 vCPU et 1,7 Go de mémoire, sinon le preflight de kubeadm refuse de continuer. 4 Go par machine donnent du confort.

#### Le plan d'adressage

```
Plan d'adressage du cours :
═══════════════════════════

  Réseau des nœuds     192.168.10.0/24
  Adresse virtuelle    192.168.10.10    → nom k8s-api.example (kube-vip)
  Réseau des pods      10.244.0.0/16    → un /24 par nœud
  Réseau des Services  10.96.0.0/12     → valeur par défaut de kubeadm
                                           (10.96.0.1 = Service "kubernetes")

  Les trois réseaux ne se chevauchent pas : c'est une condition
  indispensable au routage.

  Le domaine .example est réservé à la documentation (RFC 2606) :
  aucun risque de collision avec un nom réel. Il est résolu par
  le fichier /etc/hosts de chaque machine.
```

#### Les composants extérieurs à kubeadm

kubeadm n'installe ni CNI ni load balancer. Le cours fixe les deux une fois pour toutes :

| Rôle | Choix du cours | Pourquoi |
|------|----------------|----------|
| Runtime | containerd 2.x | Obligatoire à partir de la 1.36 (voir 3.5) |
| CNI | Flannel | Son réseau par défaut est `10.244.0.0/16`, celui du cours |
| Load balancer de l'API | kube-vip (mode ARP) | Pod statique sur les control planes, aucune machine en plus |
| kube-proxy | Mode `nftables` | Stable depuis la 1.33, `ipvs` déprécié depuis la 1.35 |

#### Le fil rouge des exercices

Les exercices (fichier `exercices-pratiques.md`) s'enchaînent sur ce cluster, dans l'ordre des chapitres. Le cluster naît en **1.34** pour que le chapitre 7 puisse le mettre à jour vers la **1.35**, version de référence. Trois instantanés jalonnent le parcours :

```
Fil rouge :
═══════════

  Exercices 1-6          Exercice 7          Exercice 9          Exercice 10
  préparation, init  ──▶  workers      ──▶   HA kube-vip    ──▶  1.34 → 1.35
  (cp1 seul, 1.34)        ┌──────┐           ┌──────┐            ┌──────┐
                          │  S1  │           │  S2  │            │  S3  │
                          └──┬───┘           └──┬───┘            └──┬───┘
                             │                  │                   │
         repris par les exercices :             │                   │
         13 (etcd), 17 (pannes)       10 (mise à jour)   11-12, 14-16, 18

  S1 : cp1 + w1 + w2, 1.34, Flannel            (un seul control plane)
  S2 : cp1 à cp3 derrière kube-vip, w1, w2, 1.34
  S3 : le même cluster en 1.35
```

Certains exercices repartent volontairement de S1, à un seul control plane. Restaurer etcd y est plus simple, et une panne y reste visible : le chapitre 11 explique pourquoi la haute disponibilité masque les pannes.

#### Conventions

- Les commandes préfixées par `sudo` s'exécutent **sur le nœud** indiqué. Les commandes `kubectl` s'exécutent depuis une machine qui dispose d'un kubeconfig administrateur, en général `cp1`.
- Dans les versions, `x` désigne le dernier correctif disponible : `1.35.x` se lit « la 1.35 la plus récente ».
- Les sections **Pièges courants** regroupent, en fin de chapitre, les erreurs qui coûtent le plus de temps à l'examen.

---
