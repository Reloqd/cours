---
title: "CKA — 1. L'examen, le programme et le lab"
description: "Le format de l'examen CKA v1.37, son programme rapporté aux chapitres du cours, ce qui a changé de Kubernetes 1.35 à 1.37, et l'installation pas à pas du lab minikube à trois nœuds qui sert de fil rouge."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 1. L'examen, le programme et le lab

Ce chapitre pose le cadre de tout le cours. Il décrit ce que mesure le CKA et comment il se déroule, rapporte chaque compétence du programme officiel v1.37 aux chapitres qui la traitent, dresse la liste de ce qui a changé dans Kubernetes entre les versions 1.35 et 1.37, puis installe le lab sur lequel tu feras chaque exercice : un cluster minikube de trois nœuds, en Kubernetes v1.37.0, sur lequel se construit le fil rouge « boutique ». Il ne correspond à aucune compétence particulière du programme : il les cartographie toutes, de *Understand application deployments and how to perform rolling update and rollbacks* à *Troubleshoot clusters and nodes*, et te donne l'outil pour les travailler. Le lab compte autant que le texte : le CKA ne se réussit qu'en tapant des commandes, vite et juste, sur de vrais clusters. Tout ce que tu lis ici, tu dois l'avoir fait au moins une fois de tes mains avant le jour de l'examen.

### 1.1 Ce que certifie le CKA

Le *Certified Kubernetes Administrator* est une certification créée par la Linux Foundation et la Cloud Native Computing Foundation (CNCF). Elle atteste qu'un administrateur sait installer, configurer, exploiter et dépanner un cluster Kubernetes conforme. Ce n'est pas un questionnaire : l'examen est entièrement **pratique** (*performance-based*). Chaque tâche te demande de produire un état dans un cluster réel, ou parfois un fichier sur un hôte, et un correcteur automatique vérifie cet état une fois l'examen terminé.

Cette forme a deux conséquences qui orientent toute la préparation. La première : la connaissance ne suffit pas, il faut la vitesse. Deux heures pour quinze à vingt tâches laissent six à huit minutes par tâche, lecture de l'énoncé, recherche dans la documentation et vérification comprises. La seconde : seul compte l'état final. Le correcteur ne voit pas tes commandes, il interroge le cluster. Une ressource mal nommée, créée dans le mauvais namespace ou réparée « à chaud » d'une façon qui ne survit pas à un redémarrage vaut zéro, même si la démarche était juste.

La Linux Foundation propose trois certifications Kubernetes pratiques, qui se distinguent par leur public :

| | CKA | CKAD | CKS |
|---|---|---|---|
| Public | Administrateur de clusters | Développeur d'applications | Spécialiste de la sécurité |
| Version de Kubernetes de l'environnement (23 octobre 2026) | v1.37 | v1.37 | v1.35 |
| Seuil de réussite | 66 % | 66 % | 67 % |
| Prérequis | aucun | aucun | CKA réussi |
| Durée | 2 h | 2 h | 2 h |

Le CKA est donc la porte d'entrée de la filière d'administration : le CKS exige qu'on l'ait obtenu, et depuis le 18 juin 2026, réussir ou renouveler le CKS prolonge automatiquement le CKA jusqu'à la date d'expiration du CKS (programme CARE).

### 1.2 Le format de l'examen

#### Les chiffres

Les valeurs ci-dessous viennent de la FAQ et des pages d'instructions de la Linux Foundation, lues le 23 octobre 2026.

| Élément | Valeur |
|---|---|
| Durée | 2 heures |
| Tâches | 15 à 20 tâches pratiques, en ligne de commande sous Linux |
| Seuil de réussite | 66 % |
| Version de Kubernetes | v1.37 ; l'environnement est aligné sur la dernière version mineure 4 à 8 semaines après sa sortie |
| Langues des énoncés | anglais, chinois simplifié, japonais (le terminal et les échanges avec le surveillant restent en anglais) |
| Surveillance | à distance, par la plateforme PSI Bridge et son navigateur sécurisé (PSI Secure Browser) : webcam, micro et partage d'écran |
| Résultat | par courriel, dans les 24 heures qui suivent la fin de l'examen |
| Validité | 2 ans (3 ans pour un CKA obtenu avant le 1er avril 2024) ; renouvellement en repassant l'examen avant l'expiration |
| Prix (examen seul) | 445 USD ; 625 USD avec l'abonnement THRIVE-ONE ; 645 USD avec le cours LFS258 |
| Délai | 12 mois à compter de l'inscription pour planifier et passer l'examen, seconde tentative comprise |
| Seconde tentative | une (« One Retake ») |
| Simulateur | 2 sessions killer.sh de 36 heures chacune, absentes des inscriptions `CKA-SINGLE` |

Deux détails de calendrier comptent. Une réservation exige 24 heures d'avance (les machines virtuelles de l'examen sont préparées pour toi), et on peut la modifier ou l'annuler jusqu'à 24 heures avant l'heure prévue, pas après. Le jour venu, tu peux lancer la procédure d'accueil jusqu'à 30 minutes avant l'heure réservée, et tu dois avoir commencé au plus tard 30 minutes après : au-delà, tu es déclaré absent, sans remboursement ni seconde tentative. Le chapitre 24.9 détaille le déroulé complet de la journée.

#### Comment la note est calculée

La Linux Foundation corrige automatiquement et ne publie ni le barème ni le détail par tâche. Sa documentation dit seulement qu'une tâche peut souvent se réaliser de plusieurs façons, et que, sauf mention contraire dans l'énoncé, toute méthode est acceptée **pourvu qu'elle produise le bon résultat**. La FAQ de killer.sh, le simulateur officiel, ajoute que la note se calcule par sous-tâche réussie, en tenant compte de leur difficulté. Agis comme si c'était le cas : une tâche à moitié faite rapporte des points, une tâche laissée vide n'en rapporte aucun.

Le correcteur interroge l'état du cluster et des hôtes après la fin de l'examen. Ce qu'il vérifie est donc exactement ce que l'énoncé nomme : le nom de chaque objet, son namespace, ses labels, ses valeurs, le chemin et le contenu de chaque fichier demandé. C'est pour cette raison que chaque exercice du cours fixe des noms et des valeurs exacts, et se termine par une vérification.

> [!warning] Un réglage à chaud n'est pas une réparation
> Relancer un processus à la main, monter un fichier dans `/tmp` ou modifier un objet que son contrôleur va réécrire produit un état qui peut disparaître avant la correction. Une réparation doit tenir : un manifeste de pod statique corrigé dans `/etc/kubernetes/manifests`, un service systemd activé (`enable`) et pas seulement démarré, un Deployment modifié plutôt que son pod.

#### L'environnement en un coup d'œil

Tu passes l'examen dans un bureau Linux distant (XFCE), affiché par le navigateur sécurisé de PSI. À gauche, le panneau de contenu présente les tâches ; à droite, le bureau propose un terminal, Firefox (limité aux sites autorisés) et l'éditeur VSCodium. Le terminal s'ouvre sur une machine nommée `base`, qui ne porte **aucun** outil Kubernetes. Chaque tâche désigne un hôte et donne, dans un encadré, la commande `ssh` pour s'y connecter. C'est sur cet hôte, et seulement là, que tu trouves `kubectl` (avec l'alias `k` et la complétion Bash déjà configurés), `yq`, `curl`, `wget` et les pages de manuel.

```
L'environnement d'examen :
══════════════════════════

  ┌─ PSI Secure Browser ─────────────────────────────────────────────┐
  │ ┌──────────────┐ ┌─────────────────────────────────────────────┐ │
  │ │ Panneau de   │ │ Bureau distant (XFCE)                       │ │
  │ │ contenu :    │ │                                             │ │
  │ │ tâche 1      │ │  Terminal ──▶ shell sur base                │ │
  │ │ tâche 2      │ │                 │  rien : ni kubectl, ni yq │ │
  │ │ …            │ │                 │                           │ │
  │ │ encadré :    │ │                 │ ssh <hôte de la tâche>    │ │
  │ │ « ssh … »    │ │                 ▼                           │ │
  │ │ Quick        │ │           hôte SSH : kubectl + alias k,     │ │
  │ │ Reference    │ │           complétion Bash, yq, curl, wget,  │ │
  │ │              │ │           man ; sudo -i pour devenir root   │ │
  │ │              │ │                 │                           │ │
  │ │              │ │                 │ exit  ──▶ retour sur base │ │
  │ │              │ │                                             │ │
  │ │              │ │  Firefox : kubernetes.io/docs, blog, Helm,  │ │
  │ │              │ │            Gateway API                      │ │
  │ │              │ │  VSCodium, clavier virtuel                  │ │
  │ └──────────────┘ └─────────────────────────────────────────────┘ │
  └──────────────────────────────────────────────────────────────────┘

  Une tâche = un hôte. On revient sur base (exit) avant la suivante :
  le ssh imbriqué n'est pas pris en charge.
```

Trois règles en découlent dès maintenant, et le chapitre 24.2 y revient en détail. Tu tapes la commande `ssh` de l'encadré au début de **chaque** tâche, même si tu crois être déjà sur le bon hôte. Tu reviens sur `base` par `exit` à la fin de chaque tâche (deux fois si tu étais passé root par `sudo -i`). Et tu ne redémarres jamais `base` : cela ne relance pas ton environnement d'examen.

#### Les ressources autorisées

Pendant l'examen, le Firefox du bureau distant n'ouvre que la documentation autorisée. Pour le CKA, au 23 octobre 2026 :

| Ressource | Adresse | Remarque |
|---|---|---|
| Documentation de Kubernetes | https://kubernetes.io/docs | la recherche du site est permise, mais pas l'ouverture de résultats externes |
| Blog de Kubernetes | https://kubernetes.io/blog/ | utile pour les nouveautés récentes |
| Documentation de Helm | https://helm.sh/docs | |
| Documentation de Gateway API | https://gateway-api.sigs.k8s.io | **CKA seulement** (pas au CKAD) |
| Documentation propre à une tâche | liens de l'encadré *Quick Reference* | c'est par là qu'arrive la doc d'un outil tiers si une tâche en exige un |
| Traductions | par exemple https://kubernetes.io/zh/docs/ | la Linux Foundation recommande l'anglais, plus à jour |
| Sur les hôtes | pages `man`, documents de `/usr/share`, paquets de la distribution | |

Ce qui n'est **pas** dans la liste compte autant. `etcd.io` est autorisé au CKS, pas au CKA : la syntaxe d'`etcdutl` se trouve, pour toi, dans la page « Operating etcd clusters for Kubernetes » de kubernetes.io (chapitre 20). GitHub, les sites de Calico, d'Envoy Gateway ou de cert-manager ne sont pas accessibles, sauf si l'encadré *Quick Reference* d'une tâche y renvoie. Tout ce que le cours te fait installer avec ces outils, tu dois donc savoir le refaire avec ce que donne l'énoncé.

### 1.3 Le programme v1.37

Le programme officiel est publié par la CNCF dans le fichier `CKA_Curriculum_v1.37.pdf` du dépôt https://github.com/cncf/curriculum. Il répartit les compétences en cinq domaines, pondérés :

```
Répartition du CKA (programme v1.37) :
══════════════════════════════════════

  Troubleshooting                                   30 %  ██████████████████████████████
  Cluster Architecture, Installation and Config.    25 %  █████████████████████████
  Services and Networking                           20 %  ████████████████████
  Workloads and Scheduling                          15 %  ███████████████
  Storage                                           10 %  ██████████

  Le poids est celui du domaine dans la NOTE, pas dans le nombre
  de tâches : une tâche de dépannage peut peser 7 %, une tâche
  de stockage 4 %.
```

#### Correspondance entre le programme et le cours

Le tableau suivant reprend chaque compétence, dans la formulation anglaise du programme, et les chapitres qui la traitent. Les chapitres entre parenthèses y contribuent sans en faire leur sujet principal.

| Domaine (poids) | Compétence officielle (anglais) | Chapitres |
|---|---|---|
| Storage (10 %) | Implement storage classes and dynamic volume provisioning | 15 |
| | Configure volume types, access modes and reclaim policies | 15 (et 4, 6) |
| | Manage persistent volumes and persistent volume claims | 15 |
| Troubleshooting (30 %) | Troubleshoot clusters and nodes | 23 (et 19) |
| | Troubleshoot cluster components | 2, 23 |
| | Monitor cluster and application resource usage | 7, 21 |
| | Manage and evaluate container output streams | 21 |
| | Troubleshoot services and networking | 22 (et 10, 11, 14) |
| Workloads and Scheduling (15 %) | Understand application deployments and how to perform rolling update and rollbacks | 5 |
| | Use ConfigMaps and Secrets to configure applications | 6 |
| | Configure workload autoscaling | 7 |
| | Understand the primitives used to create robust, self-healing, application deployments | 4, 5 |
| | Configure Pod admission and scheduling (limits, node affinity, etc.) | 8 (et 4, 7) |
| Cluster Architecture, Installation and Configuration (25 %) | Manage role based access control (RBAC) | 16 |
| | Prepare underlying infrastructure for installing a Kubernetes cluster | 19 |
| | Create and manage Kubernetes clusters using kubeadm | 19 |
| | Manage the lifecycle of Kubernetes clusters | 19, 20 |
| | Implement and configure a highly-available control plane | 19 |
| | Use Helm and Kustomize to install cluster components | 17 |
| | Understand extension interfaces (CNI, CSI, CRI, etc.) | 18 (et 9, 15) |
| | Understand CRDs, install and configure operators | 18 |
| Services and Networking (20 %) | Understand connectivity between Pods | 9 |
| | Define and enforce Network Policies | 14 |
| | Use ClusterIP, NodePort, LoadBalancer service types and endpoints | 10 |
| | Use the Gateway API to manage Ingress traffic | 13 |
| | Know how to use Ingress controllers and Ingress resources | 12 |
| | Understand and use CoreDNS | 11 |

Le PDF v1.37 intitule le dernier domaine « Servicing and Networking » : c'est une coquille du document, le domaine s'appelle « Services and Networking » partout ailleurs, y compris sur la page de la certification.

#### Lire le programme entre les lignes

Le programme est court, et chaque ligne recouvre beaucoup. Quatre remarques aident à le lire.

La sauvegarde et la restauration d'etcd ne sont plus nommées, mais elles relèvent de *Manage the lifecycle of Kubernetes clusters*, au même titre que la mise à jour d'un cluster par kubeadm. Le cours les traite en entier au chapitre 20, et l'examen blanc de l'annexe B en contient une.

Le dépannage pèse 30 %, mais il ne se limite pas aux chapitres 21 à 23. Une tâche de dépannage porte toujours sur un objet d'un autre domaine : un Service sans backend, un pod Pending à cause d'une taint, une NetworkPolicy trop stricte, un PersistentVolumeClaim qui ne se lie pas. On ne dépanne bien que ce qu'on sait construire, et c'est pourquoi le cours construit d'abord (parties II à V) puis casse (partie VI).

« Understand » ne signifie pas « théorique ». *Understand extension interfaces (CNI, CSI, CRI, etc.)* se traduit à l'examen par des gestes : trouver la configuration CNI d'un nœud, lister des conteneurs avec `crictl`, créer une RuntimeClass, identifier le pilote CSI d'une StorageClass. Le chapitre 18 les pratique tous.

Enfin, *Create and manage Kubernetes clusters using kubeadm* et *Implement and configure a highly-available control plane* ne se pratiquent pas sur minikube. Le chapitre 19 utilise pour cela un lab de machines virtuelles, celui du cours voisin consacré à kubeadm (section 1.5).

### 1.4 Kubernetes en 2026 : ce qui a changé de 1.35 à 1.37

L'examen tourne en v1.37 depuis l'automne 2026, et une bonne partie de ce qu'on trouve en ligne a été écrit pour des versions antérieures. Les tableaux suivants recensent les changements des trois dernières versions qui touchent une compétence du programme, avec la version où chacun est intervenu et le chapitre qui en tient compte. Les dates de sortie : 1.35 le 17 décembre 2025, 1.36 le 22 avril 2026, 1.37 le 26 août 2026 (dernier correctif au 23 octobre 2026 : v1.37.1, publiée le 23 septembre 2026).

#### Arrivés un peu plus tôt, toujours d'actualité

Quelques changements antérieurs à la 1.35 restent mal connus et reviennent souvent :

| Changement | Version | Ce que cela change pour toi | Chapitre |
|---|---|---|---|
| Sidecars natifs GA : un init container avec `restartPolicy: Always` | 1.33 (porte de fonctionnalité `SidecarContainers` supprimée en 1.37) | le sidecar démarre avant le conteneur principal et s'arrête après lui | 4 |
| Lecture de l'API `Endpoints` dépréciée | 1.33 | `kubectl get endpoints` affiche `Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice` | 10 |
| kube-proxy en mode `nftables` GA | 1.33 | `iptables` reste le mode par défaut | 10, 19 |
| Swap des nœuds (`NodeSwap`) GA | 1.34 | `failSwapOn: false` et `memorySwap.swapBehavior` (`NoSwap` par défaut, ou `LimitedSwap`) | 19 |
| Fichier de préférences `kuberc` en bêta | 1.34 | alias et options par défaut de kubectl dans `~/.kube/kuberc` | 3 |
| Ressources au niveau du pod (`spec.resources`) en bêta | 1.34 | activées par défaut, pas encore GA | 4 |

#### Kubernetes 1.35

| Changement | Ce que cela change pour toi | Chapitre |
|---|---|---|
| Redimensionnement en place des pods GA | `kubectl patch pod … --subresource resize` modifie CPU et mémoire sans recréer le pod | 4, 7 |
| `kubectl exec POD COMMANDE` sans `--` refusé | il faut `kubectl exec POD -- COMMANDE` | 3, 4 |
| `failCgroupV1` vrai par défaut | le kubelet refuse de démarrer sur un hôte en cgroup v1 | 19 |
| Mode `ipvs` de kube-proxy déprécié | avertissement au démarrage ; désactivé par défaut prévu en 1.40, supprimé en 1.43 | 10, 19 |
| Dernière version à prendre en charge containerd 1.x | à partir de 1.36, containerd 2.x | 18, 19 |
| `trafficDistribution: PreferSameNode` GA | `PreferClose` devient un alias déprécié de `PreferSameZone` | 10 |
| kubectl ne gère plus les anciennes API bêta (`networking/v1beta1` Ingress, `policy/v1beta1` PDB…) | les manifestes anciens doivent passer en `v1` | 2 |
| `pods/exec`, `pods/attach`, `pods/portforward` exigent le verbe `create`, y compris en WebSocket | un Role qui ne donne que `get` sur `pods/exec` ne suffit plus | 16 |

#### Kubernetes 1.36

| Changement | Ce que cela change pour toi | Chapitre |
|---|---|---|
| `Service.spec.externalIPs` déprécié | avertissement de l'API ; suppression prévue en 1.43 | 10 |
| Volume `gitRepo` désactivé définitivement | utiliser un init container qui clone le dépôt | 15 |
| `kubectl debug` : profil `general` par défaut | `legacy` est déprécié (retrait prévu en 1.39) | 22 |
| `kubectl describe` sur plusieurs objets n'affiche plus les événements | `--show-events=true` pour les retrouver ; un objet unique les affiche toujours | 21 |
| MutatingAdmissionPolicy GA (`admissionregistration.k8s.io/v1`) | politiques de mutation en CEL, sans webhook | 8, 18 |
| `maxUnavailable` des StatefulSets désactivé par défaut après une régression | réactivé en 1.37 | 5 |

#### Kubernetes 1.37

| Changement | Ce que cela change pour toi | Chapitre |
|---|---|---|
| API de configuration kubeadm `v1beta3` supprimée | seule `v1beta4` est acceptée | 19 |
| etcd 3.7.0 déployé par kubeadm (image `3.7.0-0`) | `etcdctl snapshot restore` et `status` n'existent plus depuis etcd 3.6 : `etcdutl` | 20 |
| kubeadm écrit explicitement `mode: iptables` dans la configuration de kube-proxy | kube-proxy avertit quand le mode n'est pas explicite (bascule future vers `nftables`) | 10, 19 |
| Porte `PreventStaticPodAPIReferences` supprimée | un pod statique ne peut plus référencer de Secret ni de ConfigMap | 2, 23 |
| Tolérance configurable du HPA GA | `spec.behavior.scaleUp.tolerance` et `scaleDown.tolerance` ; 10 % par défaut | 7 |
| HPA à zéro réplica en bêta, activé | `minReplicas: 0`, seulement avec des métriques *object* ou *external* | 7 |
| `maxUnavailable` des StatefulSets en bêta, activé | mise à jour de plusieurs pods à la fois | 5 |
| Sortie KYAML GA | `kubectl get … -o kyaml` | 3 |
| API `metrics.k8s.io/v1` GA | `kubectl top` la préfère ; metrics-server v0.9.0 sert encore `v1beta1`, sur laquelle kubectl se replie | 7, 21 |
| `kubectl run -f` déprécié | l'option était déjà ignorée | 3 |
| CoreDNS v1.14.6 par défaut | | 11 |

#### L'écosystème

Quatre changements extérieurs au code de Kubernetes pèsent aussi sur l'examen. Le projet **ingress-nginx** a été retiré le 24 mars 2026 : son dépôt est archivé, plus aucun correctif ne paraît (dernier contrôleur : v1.15.1). L'API Ingress, elle, reste GA et au programme, et l'addon `ingress` de minikube v1.39.0 utilise toujours ce contrôleur : le chapitre 12.3 explique ce que cela change. **Gateway API** v1.6 (dernière version stable au 23 octobre 2026 : v1.6.3) fait passer TCPRoute et UDPRoute dans le canal standard ; le chapitre 13 l'utilise avec Envoy Gateway v1.9.2. **Helm 4**, sorti le 17 novembre 2025, renomme `--atomic` en `--rollback-on-failure` et `--force` en `--force-replace`, et applique les manifestes côté serveur (*server-side apply*) par défaut aux nouvelles installations ; Helm 3 ne reçoit plus que des correctifs de sécurité, jusqu'au 11 novembre 2026 (chapitre 17.7). Enfin, **containerd 1.7** est en fin de vie depuis le 30 septembre 2026 ; Kubernetes 1.37 est validé avec containerd 2.4 et 2.3 (chapitre 19.2.5).

> [!warning] Les habitudes périmées
> Méfie-toi de tout guide qui te fait taper l'une de ces commandes, encore très répandues :
>
> - `ETCDCTL_API=3 etcdctl …` : la variable est inutile depuis etcd 3.6, et etcdctl 3.7 affiche un avertissement `unrecognized environment variable` (la commande réussit quand même) ;
> - `etcdctl snapshot restore` : supprimée, c'est `etcdutl snapshot restore` ;
> - `kubectl exec mon-pod ls` : refusée depuis 1.35, c'est `kubectl exec mon-pod -- ls` ;
> - `kubectl set image … --record` : l'option est dépréciée et masquée de l'aide (elle est acceptée avec l'avertissement `Flag --record has been deprecated`) ; on documente une révision par l'annotation `kubernetes.io/change-cause` (chapitre 5.5) ;
> - `helm install --atomic` : renommée `--rollback-on-failure` dans Helm 4.

### 1.5 Pourquoi minikube d'abord, et ses limites

Un cluster d'entraînement doit se créer vite, se casser sans regret et se remettre dans un état connu en quelques minutes. minikube, avec le pilote Docker, remplit ces trois conditions : chaque nœud est un conteneur Docker (image `kicbase`, Debian 12) dans lequel tournent systemd, containerd, le kubelet et, sur le nœud de control plane, les composants lancés en pods statiques. À l'intérieur, minikube appelle **kubeadm** avec un fichier de configuration (`kubeadm init --config /var/tmp/minikube/kubeadm.yaml`) : le cluster obtenu a la structure d'un cluster kubeadm, avec ses manifestes dans `/etc/kubernetes/manifests`, son kubelet sous systemd, ses certificats et son etcd en pod statique. Presque tout ce que l'examen te demande de lire ou de réparer existe donc à l'identique dans le lab.

| | Lab minikube (ce cours) | Lab de VM kubeadm (chapitre 19) | Cluster d'examen |
|---|---|---|---|
| Création | une commande, 3 à 5 minutes | plusieurs heures la première fois | fourni |
| Remise à zéro | `lab/restaurer.sh`, 1 à 15 minutes selon l'instantané | instantanés d'hyperviseur | — |
| Construit par | kubeadm, piloté par minikube | kubeadm, à la main | kubeadm |
| Pods statiques, kubelet systemd, crictl | oui | oui | oui |
| `kubeadm init`, `join`, `upgrade` | non | oui | oui |
| Haute disponibilité du control plane | non | oui (kube-vip) | peut être demandée par une tâche |
| Ressources nécessaires | 4 CPU, 12 Gio libres | 5 VM | — |

Le lab a deux limites qu'il faut connaître. D'une part, ce qui relève de l'installation elle-même (préparer des nœuds, `kubeadm init` et `join`, monter un control plane hautement disponible, passer de 1.36 à 1.37) ne s'y pratique pas : minikube fait tout cela pour toi, avec ses propres réglages. Le chapitre 19 s'appuie donc sur un lab de machines virtuelles. D'autre part, minikube s'écarte d'un cluster kubeadm standard sur une série de points précis (port de l'API, chemins des certificats et des données etcd, taints, nombre de réplicas de CoreDNS…). La section 1.8 les recense tous, et chaque chapitre les rappelle dans un encadré `minikube ≠ examen` là où ils comptent.

Le lab suppose un **hôte Linux**. Sous macOS et Windows, Docker tourne dans une machine virtuelle et les adresses des nœuds (192.168.49.x) ne sont pas joignables depuis l'hôte (la documentation de minikube le précise pour Windows et WSL 2) : les nombreux exercices qui interrogent un NodePort, une adresse MetalLB ou le contrôleur d'Ingress par `curl` depuis le poste ne fonctionneraient pas tels qu'ils sont écrits.

### 1.6 Installer le lab pas à pas

#### Le poste

Il te faut un hôte Linux avec Docker (version 20.10 ou plus récente recommandée par minikube), 4 CPU et 12 Gio de mémoire libres, 20 Go de disque libres (le minimum que demande minikube) et un accès à Internet. Docker doit être utilisable **sans sudo** : minikube refuse le pilote docker quand on le lance en root, il doit tourner sous ton utilisateur, qui doit donc pouvoir parler au démon Docker. La procédure officielle de Docker ajoute ton utilisateur au groupe `docker` :

```bash
sudo usermod -aG docker "$USER"
newgrp docker          # ou se déconnecter et se reconnecter
docker version --format '{{.Server.Version}}'
```

> [!danger] Le groupe docker équivaut à root
> Appartenir au groupe `docker`, c'est pouvoir lancer un conteneur qui monte `/` de l'hôte : c'est un accès root. Sur un poste personnel d'entraînement, c'est acceptable ; sur une machine partagée, prends une VM dédiée au lab.

#### La limite inotify

C'est la contrainte la plus sournoise du lab, et elle se règle **avant** le premier démarrage. inotify est le mécanisme du noyau par lequel un processus surveille des fichiers. systemd, le kubelet, containerd, kube-proxy, Calico en ouvrent chacun plusieurs instances. Or les nœuds minikube sont des conteneurs qui tournent en root, sans espace de noms utilisateur séparé (le pilote Docker de minikube ne prend pas en charge `userns-remap`) : toutes leurs instances inotify comptent dans la limite **de l'utilisateur root de l'hôte**, `fs.inotify.max_user_instances`, dont la valeur par défaut du noyau est 128.

Un cluster nu de trois nœuds en consomme déjà une centaine (101 relevées : 45 sur `cka`, 25 et 31 sur les workers), un cluster chargé des addons du cours, 115, sans compter les processus root de l'hôte lui-même. La limite tombe vite, et les symptômes ne la désignent jamais clairement : un nœud ajouté qui ne démarre pas (`Failed to allocate manager object: Too many open files` dans le journal du conteneur), un kube-proxy en erreur (`fsnotify watcher init: too many open files`), un `calico-node` bloqué en `Init`, un nœud qui reste `NotReady` avec `cni plugin not initialized`, un `systemctl` qui affiche `Failed to allocate directory watch: Too many open files`. On relève donc la limite une fois pour toutes, avec les valeurs que recommande aussi le projet kind :

```bash
sudo sysctl fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288
printf 'fs.inotify.max_user_instances = 512\nfs.inotify.max_user_watches = 524288\n' \
  | sudo tee /etc/sysctl.d/99-inotify.conf
sudo sysctl --system | grep inotify
```

La première commande s'applique tout de suite, le fichier de `/etc/sysctl.d/` la rend persistante au redémarrage du poste.

#### kubectl 1.37

Le client doit rester à une version mineure près du serveur : un kubectl 1.37 parle aux control planes 1.36, 1.37 et 1.38. On installe le dernier correctif de la 1.37, v1.37.1, en vérifiant son empreinte SHA-256. Le fichier `kubectl.sha256` publié par le projet ne contient que l'empreinte, sans nom de fichier : on reconstitue la ligne attendue par `sha256sum --check`.

```bash
mkdir -p ~/telechargements-cka && cd ~/telechargements-cka
curl -fsSLO https://dl.k8s.io/release/v1.37.1/bin/linux/amd64/kubectl
curl -fsSLO https://dl.k8s.io/release/v1.37.1/bin/linux/amd64/kubectl.sha256
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

```
kubectl: OK
Client Version: v1.37.1
Kustomize Version: v5.8.1
```

Les deux espaces entre l'empreinte et le nom de fichier ne sont pas décoratifs : c'est le format que lit `sha256sum`. En cas d'écart, la commande affiche `kubectl: FAILED` et sort en erreur ; on ne va pas plus loin.

#### Helm 4.3

Helm s'installe depuis l'archive publiée sur `get.helm.sh`. Ici, le fichier d'empreinte a le format complet (empreinte, deux espaces, nom), et `sha256sum -c` le lit directement :

```bash
cd ~/telechargements-cka
curl -fsSLO https://get.helm.sh/helm-v4.3.1-linux-amd64.tar.gz
curl -fsSLO https://get.helm.sh/helm-v4.3.1-linux-amd64.tar.gz.sha256sum
sha256sum -c helm-v4.3.1-linux-amd64.tar.gz.sha256sum
tar xzf helm-v4.3.1-linux-amd64.tar.gz
sudo install -m 0755 linux-amd64/helm /usr/local/bin/helm
helm version --short
```

```
helm-v4.3.1-linux-amd64.tar.gz: OK
v4.3.1+gc0d08d0
```

#### minikube v1.39.0

Même principe, avec le piège du kubectl : le fichier `minikube-linux-amd64.sha256` ne contient que l'empreinte. Lui passer directement `sha256sum -c` échoue avec `no properly formatted checksum lines found`.

```bash
cd ~/telechargements-cka
curl -fsSLO https://github.com/kubernetes/minikube/releases/download/v1.39.0/minikube-linux-amd64
curl -fsSLO https://github.com/kubernetes/minikube/releases/download/v1.39.0/minikube-linux-amd64.sha256
echo "$(cat minikube-linux-amd64.sha256)  minikube-linux-amd64" | sha256sum -c -
sudo install -m 0755 minikube-linux-amd64 /usr/local/bin/minikube
minikube version
```

```
minikube-linux-amd64: OK
minikube version: v1.39.0
commit: 7a9f6a841470a207de8cf4bafcccee0969d8ba10
```

L'empreinte publiée pour cette version est `b738496da01be06bbaf80c688f57ce25acd3849fbb518155f3a88e03ef555aa4`.

#### Où minikube écrit

minikube range ses fichiers (images en cache, certificats, profils) dans `~/.minikube`, ou dans `$MINIKUBE_HOME/.minikube` si la variable est définie. Il ajoute le contexte du cluster au kubeconfig désigné par `$KUBECONFIG`, à défaut `~/.kube/config`, **et en fait le contexte courant**. Si ce kubeconfig porte déjà d'autres clusters, ton prochain `kubectl` visera le lab, et inversement le jour où tu rebasculeras : vérifie toujours `kubectl config current-context` avant une commande destructrice. Si tu préfères isoler complètement le lab, exporte un kubeconfig qui lui est propre dans chaque terminal de travail, avant de démarrer le cluster :

```bash
export KUBECONFIG=~/.kube/cka.yaml
```

Les certificats clients du contexte `cka` y sont référencés par leur chemin dans `~/.minikube` (ils ne sont pas incorporés au fichier) : copier ce kubeconfig sur une autre machine ne fonctionne pas.

#### Démarrer le cluster du cours

```bash
minikube start -p cka --driver=docker --container-runtime=containerd \
  --kubernetes-version=v1.37.0 --nodes=3 --cni=calico --cpus=2 --memory=3072
kubectl wait --for=condition=Ready node --all --timeout=10m
```

Chaque option a sa raison :

| Option | Effet | Pourquoi ce choix |
|---|---|---|
| `-p cka` | nom du profil : du cluster, du contexte kubeconfig, du réseau Docker et des conteneurs nœuds | toutes les commandes du cours portent `-p cka` ; sans elle, minikube vise le profil `minikube` |
| `--driver=docker` | chaque nœud est un conteneur Docker | pas d'hyperviseur, démarrage rapide |
| `--container-runtime=containerd` | containerd 2.3.4 dans chaque nœud | défaut de minikube v1.39, écrit pour être explicite ; c'est le runtime des clusters kubeadm de l'examen |
| `--kubernetes-version=v1.37.0` | version du cluster | la dernière que prend en charge minikube v1.39.0 ; l'examen est en 1.37 |
| `--nodes=3` | un control plane (`cka`) et deux workers (`cka-m02`, `cka-m03`) | ordonnancement, DaemonSets, drain et pannes de nœud demandent plusieurs nœuds |
| `--cni=calico` | Calico v3.32.2, installé par manifeste dans `kube-system` | il applique les NetworkPolicies (chapitre 14) et c'est un CNI courant sur les clusters kubeadm |
| `--cpus=2` | limite CPU par nœud, en principe | **non appliquée sous cgroup v2** (voir ci-dessous) |
| `--memory=3072` | limite mémoire de **chaque** nœud, en Mio | à 2200 Mio, le control plane chargé des addons du cours plafonnait à 84 % |

`minikube start` rend la main avant que tous les nœuds soient prêts : les images de Calico ne font pas partie du préchargement et chaque nœud les tire à sa création (`calico/node` pèse 123 Mo). C'est pourquoi la commande `kubectl wait` suit toujours. Compte trois à cinq minutes au total, davantage au tout premier démarrage, qui télécharge l'image `kicbase` (environ 508 Mio) et l'archive préchargée de Kubernetes v1.37.0 (348 Mio).

> [!info] minikube ≠ examen : la capacité des nœuds
> Sous cgroup v2, `--cpus` n'est pas appliqué : minikube cherche un fichier `cpu.max` à la racine de `/sys/fs/cgroup`, qui n'existe jamais en cgroup v2, et renonce (`Your kernel does not support CPU cfs period/quota` dans son journal). La mémoire, elle, est bien limitée. Mais dans les deux cas, chaque nœud **annonce la capacité de l'hôte** : sur un poste à 8 CPU et 32 Gio, chaque nœud affiche `cpu: 8` et environ 30 Gio de mémoire. Le scheduler croit donc disposer de 24 CPU et 90 Gio, alors que chaque nœud est en réalité plafonné à 3 Gio. `kubectl top nodes` calcule ses pourcentages sur cette fausse capacité. Sur un cluster d'examen, la capacité est celle de la machine virtuelle.

#### Vérifier le démarrage

Trois vérifications suffisent. Les nœuds d'abord :

```bash
kubectl get nodes -o wide
```

```
NAME      STATUS   ROLES           AGE     VERSION   INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION             CONTAINER-RUNTIME
cka       Ready    control-plane   4m12s   v1.37.0   192.168.49.2   <none>        Debian GNU/Linux 12 (bookworm)   7.0.0-38-generic (amd64)   containerd://2.3.4
cka-m02   Ready    <none>          3m55s   v1.37.0   192.168.49.3   <none>        Debian GNU/Linux 12 (bookworm)   7.0.0-38-generic (amd64)   containerd://2.3.4
cka-m03   Ready    <none>          3m42s   v1.37.0   192.168.49.4   <none>        Debian GNU/Linux 12 (bookworm)   7.0.0-38-generic (amd64)   containerd://2.3.4
```

La colonne `KERNEL-VERSION` affiche le noyau de ton hôte : un nœud minikube est un conteneur, il n'a pas de noyau à lui. Les pods système ensuite, qui doivent tous être `Running` et prêts :

```bash
kubectl -n kube-system get pods -o wide
```

```
NAME                                      READY   STATUS    RESTARTS   AGE     IP              NODE
calico-kube-controllers-db57f7644-sxwdz   1/1     Running   0          4m      10.244.142.65   cka
calico-node-hw89l                         1/1     Running   0          3m55s   192.168.49.3    cka-m02
calico-node-j7vrk                         1/1     Running   0          3m42s   192.168.49.4    cka-m03
calico-node-sw48x                         1/1     Running   0          4m      192.168.49.2    cka
coredns-559f6c778d-kkpc5                  1/1     Running   0          4m      10.244.142.66   cka
etcd-cka                                  1/1     Running   0          4m12s   192.168.49.2    cka
kube-apiserver-cka                        1/1     Running   0          4m12s   192.168.49.2    cka
kube-controller-manager-cka               1/1     Running   0          4m12s   192.168.49.2    cka
kube-proxy-4lcnc                          1/1     Running   0          3m55s   192.168.49.3    cka-m02
kube-proxy-jpwgc                          1/1     Running   0          4m      192.168.49.2    cka
kube-proxy-w96hs                          1/1     Running   0          3m42s   192.168.49.4    cka-m03
kube-scheduler-cka                        1/1     Running   0          4m12s   192.168.49.2    cka
storage-provisioner                       1/1     Running   0          4m      192.168.49.2    cka
```

(Les suffixes des noms de pods et les colonnes `NOMINATED NODE` et `READINESS GATES`, coupées ici, varient d'un cluster à l'autre.) Les pods en `hostNetwork` (etcd, l'API server, kube-proxy, `calico-node`…) portent l'adresse de leur nœud ; les autres reçoivent une adresse du réseau des pods, 10.244.0.0/16. Le profil enfin :

```bash
minikube profile list
```

```
┌─────────┬────────┬────────────┬──────────────┬─────────┬────────┬───────┬────────────────┬────────────────────┐
│ PROFILE │ DRIVER │  RUNTIME   │      IP      │ VERSION │ STATUS │ NODES │ ACTIVE PROFILE │ ACTIVE KUBECONTEXT │
├─────────┼────────┼────────────┼──────────────┼─────────┼────────┼───────┼────────────────┼────────────────────┤
│ cka     │ docker │ containerd │ 192.168.49.2 │ v1.37.0 │ OK     │ 3     │                │ *                  │
└─────────┴────────┴────────────┴──────────────┴─────────┴────────┴───────┴────────────────┴────────────────────┘
```

La colonne `ACTIVE PROFILE` reste vide : l'option `-p cka` vise le profil sans en faire le profil par défaut. C'est voulu : le cours écrit toujours `-p cka`, et une commande qui l'oublie échoue sur un profil `minikube` inexistant plutôt que d'agir en silence.

#### Arrêter, relancer, supprimer

Le lab se gère avec quatre commandes, chacune avec ses particularités :

| Commande | Effet | À savoir |
|---|---|---|
| `minikube -p cka stop` | arrête les trois conteneurs (1 min 20 s à 1 min 26 s mesurées) | objets, addons et volumes sont conservés |
| `minikube -p cka start` | relance le cluster arrêté (environ 30 s, nœuds prêts peu après) | les manifestes statiques ne sont pas réécrits ; metrics-server et les pilotes CSI mettent environ une minute à revenir |
| `minikube -p cka delete` | supprime conteneurs et volumes | laisse le réseau Docker `cka` : relance la commande une seconde fois pour faire place nette |
| `lab/restaurer.sh I2` | supprime et recrée le profil, puis rejoue les états du cours jusqu'à l'instantané demandé | 7 min 23 s mesurées pour I2 (de 1 à 15 minutes selon l'instantané) ; voir la section 1.9 |

Deux pièges de persistance complètent le tableau. Le répertoire `/tmp` de chaque nœud est un tmpfs : tout ce que tu y déposes disparaît à l'arrêt du cluster. Et `minikube -p cka addons list` affiche tous les addons `disabled` dès que le cluster a plusieurs nœuds et a été redémarré, alors qu'ils fonctionnent : pour savoir si un addon tourne, regarde ses pods, pas cette liste.

### 1.7 Le plan d'adressage du lab

Toutes les adresses du cours découlent du réseau Docker que minikube crée pour le profil :

```
Plan d'adressage du lab :
═════════════════════════

  Poste Linux (hôte Docker)
  └── pont Docker « cka »   192.168.49.0/24, passerelle 192.168.49.1 (= l'hôte)
        │
        ├── cka       192.168.49.2   control plane ; API https://192.168.49.2:8443
        │                            contrôleur d'Ingress en hostPort 80/443 (ch. 12)
        ├── cka-m02   192.168.49.3   worker
        ├── cka-m03   192.168.49.4   worker
        └── MetalLB   192.168.49.100 → 192.168.49.120   (Services LoadBalancer, ch. 10)

  Réseau des pods       10.244.0.0/16  IPPool Calico « default-ipv4-ippool »,
                                       IPIP, un bloc /26 attribué par nœud
  Réseau des Services   10.96.0.0/12   10.96.0.1  = Service « kubernetes »
                                       10.96.0.10 = kube-dns (CoreDNS)
  Domaine du cluster    cluster.local
  NodePort de « front » 30080 (ch. 10)

  Noms de test (domaine .example, réservé à la documentation, RFC 2606) :
    boutique.example, api.boutique.example  ──▶ Ingress (ch. 12)
    gw.boutique.example                     ──▶ Gateway (ch. 13)
  résolus par « curl --resolve » depuis le poste, et dans le cluster
  par le bloc hosts de CoreDNS (ch. 11).

  Les trois plages (nœuds, pods, Services) ne se chevauchent pas :
  c'est la condition du routage.
```

Les adresses des nœuds sont celles qu'attribue minikube quand le sous-réseau 192.168.49.0/24 est libre. Si un autre profil minikube ou un autre réseau Docker l'occupe déjà, minikube en choisit un autre : la commande `minikube -p cka ip` (adresse du control plane) fait toujours foi, et les exercices l'utilisent plutôt que d'écrire l'adresse en dur.

Les adresses des pods appellent une remarque, que le chapitre 9.4 développe. Le controller-manager attribue bien à chaque nœud un `spec.podCIDR` en /24 (10.244.0.0/24 pour `cka`, 10.244.1.0/24 pour `cka-m02`…), mais l'IPAM de Calico l'ignore et distribue ses propres blocs /26 : les pods de `cka` reçoivent par exemple des adresses en 10.244.142.64/26. Ne déduis jamais le nœud d'un pod de son adresse.

À l'intérieur des nœuds, les chemins utiles sont les suivants ; ceux qui diffèrent d'un cluster kubeadm sont marqués d'un astérisque :

| Élément | Chemin dans le lab | Sur un cluster kubeadm |
|---|---|---|
| Manifestes des pods statiques | `/etc/kubernetes/manifests` | identique |
| Certificats | `/var/lib/minikube/certs` (etcd : `…/certs/etcd`) * | `/etc/kubernetes/pki` |
| Données etcd | `/var/lib/minikube/etcd` *, puis `/var/lib/minikube/etcd-restore` après l'exercice 20.5 (`lab/restaurer.sh I4` repart de `/var/lib/minikube/etcd`) | `/var/lib/etcd` |
| Configuration du kubelet | `/var/lib/kubelet/config.yaml` | identique |
| Kubeconfigs des composants | `/etc/kubernetes/{admin,controller-manager,scheduler,kubelet}.conf` | identique |
| Binaires kubeadm, kubelet, kubectl | `/var/lib/minikube/binaries/v1.37.0/`, hors du `PATH` * | `/usr/bin` |
| Configuration kubeadm | `/var/tmp/minikube/kubeadm.yaml` * | souvent absente du disque ; ConfigMap `kube-system/kubeadm-config` |
| Journaux des pods | `/var/log/pods`, liens dans `/var/log/containers` | identique |
| Configuration CNI | `/etc/cni/net.d/10-calico.conflist`, binaires dans `/opt/cni/bin` | identique (selon le CNI) |

### 1.8 minikube ≠ examen : le tableau des écarts

Voici l'inventaire complet des différences entre le lab et un cluster kubeadm comme ceux de l'examen. Chaque chapitre rappelle, dans un encadré `> [!info] minikube ≠ examen`, celles qui le concernent.

| Sujet | Cluster kubeadm d'examen | Lab minikube `cka` | Chapitres |
|---|---|---|---|
| Port de l'API | 6443 | **8443** | 2, 3, 23 |
| Certificats | `/etc/kubernetes/pki` | `/var/lib/minikube/certs` ; `/etc/kubernetes/pki` absent du control plane | 16, 19, 20, 23 |
| Données etcd | `/var/lib/etcd` | `/var/lib/minikube/etcd`, puis `/var/lib/minikube/etcd-restore` après l'exercice 20.5 (`lab/restaurer.sh I4` repart de `/var/lib/minikube/etcd`) | 20, 23 |
| etcdctl, etcdutl | présents sur le nœud de control plane | absents des nœuds (installés au chapitre 20.3.3) ; présents dans l'image etcd, qui n'a pas de shell | 20 |
| kubeadm, kubelet, kubectl | dans le `PATH` | `/var/lib/minikube/binaries/v1.37.0/`, hors du `PATH` ; pas de kubectl utilisable dans les nœuds | 19, 23 |
| `kubeadm certs check-expiration` | sans option | exige `--config /var/tmp/minikube/kubeadm.yaml` ou `--cert-dir /var/lib/minikube/certs` | 19 |
| Certificat de l'API server | 1 an | 3 ans (émis par minikube) ; les autres 1 an, les CA 10 ans | 19 |
| Taint du control plane | `node-role.kubernetes.io/control-plane:NoSchedule` | **aucune** : les pods ordinaires se placent aussi sur `cka` | 8 |
| Élection de leader du scheduler et du controller-manager | activée | `--leader-elect=false` | 23 |
| CoreDNS | 2 réplicas | 1 réplica (passé à 2 au chapitre 11) | 11 |
| Unité systemd du kubelet | drop-in `10-kubeadm.conf` qui lit `/var/lib/kubelet/kubeadm-flags.env` et `/etc/default/kubelet` | options écrites en dur dans le drop-in, `kubeadm-flags.env` ignoré ; kubelet `disabled` sur `cka` (minikube le démarre lui-même) | 23 |
| Éviction disque et ramasse-miettes d'images | seuils par défaut | désactivés (`evictionHard` à `0%`, `imageGCHighThresholdPercent: 100`), `failSwapOn: false` | 21, 23 |
| Capacité des nœuds | celle de la VM | celle de l'hôte | 7, 8 |
| Accès aux nœuds | `ssh <nœud>` puis `sudo -i` | `minikube -p cka ssh [-n cka-m02]`, utilisateur `docker`, `sudo` sans mot de passe | tous |
| `crictl` | souvent utilisable en root | exige `sudo` ; version v1.35.0 | 18, 23 |
| Nom du cluster (côté kubeadm) | `kubernetes` | `mk` | 19 |
| `/tmp` des nœuds | sur disque | tmpfs, perdu à l'arrêt | 15, 20 |
| StorageClass par défaut | souvent aucune | `standard` (`k8s.io/minikube-hostpath`), hostPath sans affinité de nœud | 15 |
| MetalLB | versions récentes configurées par CRD (`IPAddressPool`) | addon v0.9.6 configuré par ConfigMap | 10 |

À l'inverse, tout ce qui suit est **identique** et vérifié sur le lab : le dossier `/etc/kubernetes/manifests` et le fonctionnement des pods statiques (y compris le piège d'une copie `.bak` laissée dans ce dossier, que le kubelet charge comme un manifeste), le fichier `/var/lib/kubelet/config.yaml` (`staticPodPath`, `cgroupDriver: systemd`, `clusterDNS`), `systemctl` et `journalctl -u kubelet`, `/var/log/pods`, `crictl` sur le socket de containerd, le délai de passage en `NotReady` d'un nœud dont le kubelet s'arrête (une cinquantaine de secondes), `kubectl debug node/…` et l'application des NetworkPolicies.

### 1.9 Le fil rouge « boutique » et les instantanés

#### Une application qui grandit de chapitre en chapitre

Les exercices du cours ne sont pas indépendants : ils construisent, chapitre après chapitre, une même petite application nommée « boutique », dans le namespace `boutique`. Un frontal nginx (`front`) sert une page et relaie `/api/` vers une API (`api`, l'image de test `agnhost`), qui s'appuie sur un Redis (`redis`) persistant. Autour d'eux viennent des outils (`outils`, `agent-noeud`), des tâches planifiées (`rapport`), puis tout ce qu'un administrateur ajoute : Services, DNS, Ingress, Gateway, NetworkPolicies, stockage, droits RBAC, Helm, Kustomize, une CRD et un opérateur.

Tous les objets portent deux labels : `app: <nom>` et `tier`, qui vaut `web`, `api`, `donnees`, `outils` ou `batch`. Tes manifestes vivent sur ton poste, dans `~/cka/`, rangés par thème :

```
~/cka/
├── versions.txt    inventaire des versions (chapitre 1)
├── boutique/       manifestes de l'application (chapitres 3 à 15)
├── requetes/       résultats de requêtes jsonpath (chapitre 3)
├── kuberc          fichier de préférences d'essai (chapitre 3)
├── priorites/      pods d'essai de la préemption (chapitre 8)
├── reseau/         essais réseau, Services, DNS (chapitres 9 à 11)
├── outils/         binaire ingress2gateway (chapitre 13)
├── rbac/           clé, CSR et certificat d'alice (chapitre 16)
├── helm/           rendus et listes de versions (chapitre 17)
├── kustomize/      base et overlay « recette » (chapitre 17)
├── extensions/     RuntimeClass, politiques d'admission (chapitre 18)
├── crd/            CRD sauvegardes et ses ressources (chapitre 18)
├── cert-manager/   émetteurs et certificats (chapitre 18)
├── journaux/       relevés de journaux et d'événements (chapitre 21)
├── noeuds/         relevés de nœuds (chapitre 23)
├── chrono/         essais chronométrés (chapitre 24)
└── examen/         réponses écrites de l'examen blanc (annexe B)
```

Le chapitre 14 y dépose aussi deux fichiers d'essai, `essai-np-et-ou.yaml` et `essai-np-plage.yaml`.

Chaque chapitre indique, au début de ses exercices, l'état dont il part, et à la fin, l'état qu'il laisse. Le tableau suivant résume ce qui reste dans le cluster après chaque chapitre ; les chapitres absents (2, 9, 19, 20 à 24) ne laissent rien de durable dans le cluster.

| Chapitre | Ce qui reste après les exercices | Instantané |
|---|---|---|
| 1 | cluster nu, trois nœuds prêts | **I0** |
| 3 | namespace `boutique`, contexte kubeconfig `boutique` | |
| 4 | pod `outils` (netshoot), redimensionné en place (requests cpu 100m, limits cpu 300m) | |
| 5 | Deployments `front` et `api`, Services `front` et `api`, DaemonSet `agent-noeud`, CronJob `rapport`, PodDisruptionBudget `front` | |
| 6 | ConfigMaps `front-html`, `front-conf`, `api-config`, Secret `api-secret`, montés dans `front` et consommés par `api` | |
| 7 | addon metrics-server, HorizontalPodAutoscaler `api` | |
| 8 | labels de zone et `disque=ssd` sur les nœuds, topologySpreadConstraint de `front`, anti-affinité et PriorityClass `boutique-critique` pour `api`, toleration `Exists` d'`agent-noeud`, ResourceQuota `boutique-quota`, LimitRange `boutique-limites`, Pod Security Admission sur `boutique` ; aucune taint | **I1** |
| 10 | Service `api` (port nommé `http`), `front` en NodePort 30080, Services `front-lb` (LoadBalancer), `api-pods` (headless) et `meteo` (ExternalName) ; addon MetalLB et sa plage | |
| 11 | CoreDNS à 2 réplicas, Corefile enrichi (bloc `hosts`) | |
| 12 | addon ingress, Secret `boutique-tls`, Ingress `boutique` | |
| 13 | Envoy Gateway (release `eg`), GatewayClass `eg`, Gateway `boutique-gw`, HTTPRoutes `front`, `api` et `redirection-https`, `front-v2` (Deployment, Service, ConfigMap `front-html-v2`) | |
| 14 | huit NetworkPolicies dans `boutique` | **I2** |
| 15 | StorageClasses `manuel` et `rapide`, PV et PVC `archives`, addons `volumesnapshots` et `csi-hostpath-driver`, Service headless et StatefulSet `redis` avec son volume agrandi à 2Gi, VolumeSnapshot `redis-instantane` | **I3** |
| 16 | utilisateur `alice` (contexte `alice@cka`), Role `developpeur` et RoleBinding `developpeurs`, ClusterRole `lecteur-noeuds` et sa liaison, ServiceAccount, Role et RoleBinding `deployeur` | |
| 17 | release Helm `vitrine` dans `demo`, cert-manager, namespace `boutique-recette` (overlay Kustomize) | |
| 18 | RuntimeClass `runc-standard`, CRD `sauvegardes.boutique.example` et sa ressource `redis-quotidienne`, ClusterRole agrégée `sauvegardes-lecture`, ClusterIssuer `autosigne`, Certificate `boutique-gw` ; listener `https` de `boutique-gw` passé sur le Secret `boutique-gw-tls` | **I4** |

#### Les instantanés

Cinq instantanés jalonnent le parcours. Sous minikube, un instantané n'est pas une image de machine : c'est un **état reconstruit par script**. `lab/restaurer.sh I2` supprime le profil `cka`, le recrée, puis rejoue l'état laissé par chaque chapitre jusqu'à l'instantané demandé. Cela prend de 1 à 15 minutes selon l'instantané (7 min 23 s mesurées pour I2, 14 min 23 s pour I4), et cela te permet de reprendre le cours à n'importe quel jalon, ou de repartir d'un état propre après une expérience qui a mal tourné.

```
Fil rouge et instantanés :
══════════════════════════

  ch. 1          ch. 2 à 8             ch. 9 à 14            ch. 15        ch. 16 à 18
  lab nu   ──▶   boutique :      ──▶   Services, DNS,  ──▶   stockage ──▶  RBAC, Helm,
                 pods, contrôleurs,    Ingress, Gateway,     redis         Kustomize,
                 config, HPA,          NetworkPolicies                     CRD, opérateur
                 ordonnancement
  ┌────┐                   ┌────┐                  ┌────┐      ┌────┐           ┌────┐
  │ I0 │                   │ I1 │                  │ I2 │      │ I3 │           │ I4 │
  └─┬──┘                   └─┬──┘                  └─┬──┘      └─┬──┘           └─┬──┘
    │                        │                       │           │                │
  repris par :             ch. 9 à 14             ch. 15      ch. 16 à 18    ch. 20 à 24,
  ch. 2 à 8                                                                  pannes,
                                                                             annexe B

  Chapitre 19 : lab de VM à part (instantanés S1, S2, S3) ;
  le cluster minikube n'y change pas.
```

Un exercice cite son point de départ ainsi : « **Point de départ** : exercice 10.4, ou instantané I2 ». Si tu as fait l'exercice précédent, continue ; sinon, restaure l'instantané.

#### Les scripts du lab

Le dossier `lab/` livré avec le cours contient tous les scripts ; on les lance depuis le dossier du cours. L'annexe C les décrit en détail ; leur interface suffit pour commencer :

| Commande | Rôle |
|---|---|
| `lab/demarrer.sh` | vérifie les prérequis (versions des outils, limite inotify), démarre le profil `cka` avec la commande de la section 1.6 et attend que les nœuds soient prêts : produit **I0** |
| `lab/restaurer.sh <I0\|I1\|I2\|I3\|I4> [--oui]` | supprime et recrée le profil (après confirmation, sauf avec `--oui`), puis rejoue dans l'ordre les états `lab/etats/NN-*/appliquer.sh` jusqu'à l'instantané |
| `lab/pannes.sh liste` | liste les pannes disponibles (chapitres 22 et 23) |
| `lab/pannes.sh casser NN` | injecte la panne `NN` depuis I4 |
| `lab/pannes.sh verifier NN` | vérifie que la panne `NN` est réparée |
| `lab/examen-blanc/preparer.sh` | prépare l'examen blanc de l'annexe B depuis I4 (`preparer.sh 14` et `preparer.sh 15` injectent les pannes de ces deux tâches) |
| `lab/examen-blanc/corriger.sh` | note chaque tâche de l'examen blanc et calcule le total sur 100 |

Ne lis pas `lab/pannes.sh` avant d'avoir fait les chapitres 22 et 23 : le script dit ce qu'il casse, et une panne dont on connaît la cause n'entraîne plus le diagnostic.

#### Où s'exécute chaque commande

Le cours distingue trois endroits, et chaque bloc de code n'en concerne qu'un. Les commandes `kubectl`, `helm`, `minikube` et `curl` vers les adresses du lab s'exécutent **sur ton poste**. Les commandes à lancer **dans un nœud** sont précédées de la commande d'accès, et utilisent `sudo` dès qu'elles touchent à un fichier système ou au runtime :

```bash
minikube -p cka ssh -n cka-m02
sudo crictl ps
exit
```

Pour une commande unique, la forme non interactive évite d'oublier le `exit` :

```bash
minikube -p cka ssh -n cka-m02 -- sudo crictl ps
```

Enfin, les commandes à lancer **dans un pod** passent par `kubectl exec`, toujours avec `--` avant la commande : `kubectl -n boutique exec outils -- nslookup api`.

### 1.10 Plan de travail conseillé

Le cours se suit dans l'ordre : chaque partie s'appuie sur l'état laissé par la précédente, et la partie VI (dépannage) suppose tout le reste acquis. Le rythme dépend de ton expérience. Le tableau ci-dessous propose dix semaines à raison de huit à dix heures par semaine, pour un administrateur Linux qui connaît les bases de Kubernetes ; un administrateur Kubernetes en poste peut tenir la variante en six semaines, en fusionnant les semaines indiquées.

| Semaine | Chapitres | Jalon | Variante en 6 semaines |
|---|---|---|---|
| 1 | 1, 2, 3 | lab installé, I0 ; kubectl rapide | semaine 1 |
| 2 | 4, 5, 6 | `front`, `api`, ConfigMaps et Secrets | semaine 1 |
| 3 | 7, 8 | HPA, ordonnancement, admission : **I1** | semaine 2 |
| 4 | 9, 10, 11 | réseau des pods, Services, DNS | semaine 2 |
| 5 | 12, 13, 14 | Ingress, Gateway API, NetworkPolicies : **I2** | semaine 3 |
| 6 | 15, 16 | stockage (**I3**), RBAC | semaine 3 |
| 7 | 17, 18 | Helm, Kustomize, CRD, opérateur : **I4** | semaine 4 |
| 8 | 19, 20 | lab de VM kubeadm, etcd | semaine 4 |
| 9 | 21, 22, 23 | pannes 01 à 19, chacune au moins deux fois | semaine 5 |
| 10 | 24, annexe B, killer.sh | examen blanc chronométré, killer.sh A puis B | semaine 6 |

Trois habitudes rendent ce plan efficace. Refais chaque exercice une seconde fois quelques jours plus tard, sans regarder la solution et en chronométrant : la vitesse vient de la répétition, pas de la lecture. Tiens une liste des commandes que tu as dû chercher, et relis-la chaque semaine. Et ne passe la session killer.sh qu'une fois le cours terminé (chapitre 24.8) : ses deux sessions sont précieuses, elles servent à mesurer, pas à apprendre.

### 1.11 Pièges courants

```
Piège 1 : La limite inotify laissée par défaut
═══════════════════════════════════════════════
  SYMPTÔME : un nœud NotReady, kube-proxy en Error avec
             "fsnotify watcher init: too many open files",
             calico-node bloqué en Init, "node add" qui échoue.
  CAUSE    : les nœuds tournent en root sur l'hôte ; leurs
             instances inotify épuisent max_user_instances (128).
  BON      : sysctl fs.inotify.max_user_instances=512
             fs.inotify.max_user_watches=524288, rendu persistant
             dans /etc/sysctl.d/, AVANT le premier démarrage.

Piège 2 : Oublier -p cka
════════════════════════
  MAUVAIS : minikube ssh, minikube ip, minikube addons enable …
  SYMPTÔME : minikube vise le profil "minikube" : erreur de profil
             introuvable, ou pire, un second cluster démarré.
  BON      : minikube -p cka … dans toutes les commandes.

Piège 3 : Enchaîner sans attendre les nœuds
═══════════════════════════════════════════
  SYMPTÔME : pods Pending ou ContainerCreating juste après le start,
             un nœud encore NotReady.
  CAUSE    : minikube start rend la main avant que Calico soit prêt.
  BON      : kubectl wait --for=condition=Ready node --all --timeout=10m

Piège 4 : Le mauvais cluster
════════════════════════════
  SYMPTÔME : une commande du cours appliquée à un autre cluster,
             ou un "connection refused" inattendu.
  CAUSE    : minikube a changé le contexte courant de ton kubeconfig,
             ou tu as basculé ailleurs depuis.
  BON      : kubectl config current-context avant toute action
             destructrice ; un KUBECONFIG dédié au lab si ton poste
             porte d'autres clusters.

Piège 5 : Vérifier une empreinte qui ne contient que l'empreinte
════════════════════════════════════════════════════════════════
  MAUVAIS : sha256sum -c minikube-linux-amd64.sha256
  SYMPTÔME : "no properly formatted checksum lines found".
  BON      : echo "$(cat minikube-linux-amd64.sha256)  minikube-linux-amd64" \
               | sha256sum -c -

Piège 6 : Croire la liste des addons
════════════════════════════════════
  SYMPTÔME : minikube -p cka addons list affiche tout "disabled"
             alors que metrics-server répond.
  CAUSE    : affichage erroné en multi-nœud après un redémarrage.
  BON      : kubectl get pods -A pour savoir ce qui tourne.

Piège 7 : Transposer le lab tel quel à l'examen
═══════════════════════════════════════════════
  MAUVAIS : chercher /var/lib/minikube/certs ou le port 8443
            sur un cluster d'examen.
  BON      : /etc/kubernetes/pki, /var/lib/etcd, port 6443 ;
             relire les encadrés "minikube ≠ examen".
```

> [!summary] À retenir
> - Le CKA est un examen pratique de 2 heures, 15 à 20 tâches, seuil de 66 %, sur Kubernetes v1.37 ; seul compte l'état final du cluster et des fichiers demandés.
> - Chaque tâche se fait sur un hôte désigné, rejoint par `ssh` depuis `base`, avec `kubectl`, l'alias `k` et la complétion déjà en place ; on revient sur `base` par `exit`, le ssh imbriqué n'est pas pris en charge.
> - Documentation autorisée : kubernetes.io/docs, kubernetes.io/blog, helm.sh/docs et, pour le CKA seulement, gateway-api.sigs.k8s.io ; etcd.io n'en fait pas partie.
> - Le dépannage pèse 30 % et porte sur des objets de tous les domaines ; la sauvegarde d'etcd relève de *Manage the lifecycle of Kubernetes clusters*.
> - De 1.35 à 1.37 : redimensionnement en place GA, `kubectl exec POD -- CMD` obligatoire, `etcdutl` pour restaurer, kubeadm `v1beta4` seule, tolérance du HPA GA, ingress-nginx retiré, Helm 4.
> - Le lab : minikube v1.39.0, profil `cka`, trois nœuds 192.168.49.2 à .4, Kubernetes v1.37.0, containerd, Calico ; inotify relevé avant tout.
> - minikube s'écarte de l'examen sur des points précis (port 8443, `/var/lib/minikube/certs`, aucune taint sur le control plane…) : les encadrés « minikube ≠ examen » les signalent.
> - Le fil rouge « boutique » se construit chapitre après chapitre ; `lab/restaurer.sh I0` à `I4` remet le cluster à un jalon en 1 à 15 minutes (14 min 23 s mesurées pour I4).

### 1.12 Exercices

#### Exercice 1.1 — Installer les outils du lab

**Point de départ** : un poste Linux avec Docker, sans cluster.

Sur ton poste, relève la limite inotify à 512 instances et 524 288 surveillances, de façon persistante. Installe dans `/usr/local/bin` kubectl v1.37.1, Helm v4.3.1 et minikube v1.39.0, en vérifiant l'empreinte SHA-256 de chaque téléchargement avant de l'installer. Vérifie enfin que Docker est utilisable sans `sudo`.

> [!example]- Solution
> ```bash
> # inotify, immédiat puis persistant
> sudo sysctl fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288
> printf 'fs.inotify.max_user_instances = 512\nfs.inotify.max_user_watches = 524288\n' \
>   | sudo tee /etc/sysctl.d/99-inotify.conf
>
> mkdir -p ~/telechargements-cka && cd ~/telechargements-cka
>
> # kubectl : le fichier .sha256 ne contient que l'empreinte
> curl -fsSLO https://dl.k8s.io/release/v1.37.1/bin/linux/amd64/kubectl
> curl -fsSLO https://dl.k8s.io/release/v1.37.1/bin/linux/amd64/kubectl.sha256
> echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
> sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
>
> # Helm : le fichier .sha256sum a le format complet
> curl -fsSLO https://get.helm.sh/helm-v4.3.1-linux-amd64.tar.gz
> curl -fsSLO https://get.helm.sh/helm-v4.3.1-linux-amd64.tar.gz.sha256sum
> sha256sum -c helm-v4.3.1-linux-amd64.tar.gz.sha256sum
> tar xzf helm-v4.3.1-linux-amd64.tar.gz
> sudo install -m 0755 linux-amd64/helm /usr/local/bin/helm
>
> # minikube : même piège que kubectl
> curl -fsSLO https://github.com/kubernetes/minikube/releases/download/v1.39.0/minikube-linux-amd64
> curl -fsSLO https://github.com/kubernetes/minikube/releases/download/v1.39.0/minikube-linux-amd64.sha256
> echo "$(cat minikube-linux-amd64.sha256)  minikube-linux-amd64" | sha256sum -c -
> sudo install -m 0755 minikube-linux-amd64 /usr/local/bin/minikube
> ```
>
> On vérifie l'empreinte **avant** `install`, et on s'arrête au moindre `FAILED` : un binaire altéré qu'on installe dans `/usr/local/bin` s'exécutera avec tes droits, et pour minikube avec l'accès à Docker. La limite inotify passe avant le premier démarrage parce que ses symptômes, une fois le cluster lancé, ressemblent à n'importe quelle autre panne de nœud.
>
> **Vérification** :
>
> ```bash
> sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches
> kubectl version --client
> helm version --short
> minikube version
> docker ps >/dev/null && echo "docker sans sudo : OK"
> ```
>
> Résultat attendu : `fs.inotify.max_user_instances = 512`, `fs.inotify.max_user_watches = 524288`, `Client Version: v1.37.1`, `v4.3.1+gc0d08d0`, `minikube version: v1.39.0`, puis `docker sans sudo : OK`. Si `docker ps` répond `permission denied while trying to connect to the Docker daemon socket`, ton utilisateur n'est pas encore dans le groupe `docker` de ta session : `newgrp docker`, ou reconnecte-toi.

#### Exercice 1.2 — Démarrer le cluster du cours (instantané I0)

**Point de départ** : exercice 1.1.

Démarre le profil minikube `cka` : pilote docker, runtime containerd, Kubernetes v1.37.0, trois nœuds, CNI Calico, 2 CPU et 3072 Mio par nœud. Attends que tous les nœuds soient prêts, puis crée sur ton poste le dossier `~/cka/` qui recevra tes manifestes.

> [!example]- Solution
> ```bash
> minikube start -p cka --driver=docker --container-runtime=containerd \
>   --kubernetes-version=v1.37.0 --nodes=3 --cni=calico --cpus=2 --memory=3072
> kubectl wait --for=condition=Ready node --all --timeout=10m
> mkdir -p ~/cka
> ```
>
> `lab/demarrer.sh`, lancé depuis le dossier du cours, fait la même chose après avoir contrôlé les prérequis : utilise-le les fois suivantes. La première fois, tape la commande toi-même pour lire ce qu'affiche minikube : création du réseau, téléchargement du préchargement, `Préparation de Kubernetes v1.37.0 sur containerd 2.3.4`, configuration de Calico, puis démarrage des nœuds `cka-m02` et `cka-m03`. Le `kubectl wait` n'est pas facultatif : minikube rend la main alors que le dernier nœud est souvent encore `NotReady`.
>
> **Vérification** :
>
> ```bash
> kubectl config current-context
> kubectl get nodes
> kubectl -n kube-system get pods --field-selector='status.phase!=Running'
> ```
>
> Résultat attendu : `cka` ; trois nœuds `cka`, `cka-m02`, `cka-m03` en `Ready`, en `v1.37.0` ; et `No resources found in kube-system namespace.` pour la dernière commande (tous les pods système tournent). Le cluster est dans l'état **I0**.

#### Exercice 1.3 — Explorer les nœuds

**Point de départ** : exercice 1.2, ou instantané I0.

Depuis ton poste, sans entrer dans les nœuds, relève pour chacun des trois nœuds : son adresse interne, son rôle, ses taints, sa capacité en CPU et en mémoire, et la liste des pods du namespace `kube-system` qui y tournent. Retrouve ensuite les trois conteneurs Docker qui portent ces nœuds et le sous-réseau du réseau Docker `cka`. Explique pourquoi la capacité affichée ne correspond pas aux options `--cpus=2 --memory=3072`.

> [!example]- Solution
> ```bash
> kubectl get nodes -o wide
> kubectl get nodes -o 'custom-columns=NOEUD:.metadata.name,CPU:.status.capacity.cpu,MEMOIRE:.status.capacity.memory,TAINTS:.spec.taints'
> kubectl describe node cka | grep -E '^(Roles|Labels|Taints)' -A3
> kubectl -n kube-system get pods -o wide --sort-by=.spec.nodeName
> kubectl -n kube-system get pods -o wide --field-selector=spec.nodeName=cka-m02
>
> docker ps --filter name=cka --format '{{.Names}}\t{{.Status}}'
> docker network inspect cka --format '{{json .IPAM.Config}}'
> ```
>
> `-o wide` donne l'adresse interne (192.168.49.2, .3 et .4) et le rôle : seul `cka` porte le label `node-role.kubernetes.io/control-plane`, d'où `ROLES control-plane` ; les workers affichent `<none>`, comme sur un cluster kubeadm où personne ne leur a ajouté de label de rôle. La colonne `TAINTS` vaut `<none>` pour les trois nœuds : sous minikube, même le control plane n'a pas de taint (tableau de la section 1.8). La sélection par champ `spec.nodeName` montre que `cka` porte les pods statiques et, le plus souvent, CoreDNS et `calico-kube-controllers`, créés avant l'arrivée des workers ; chaque worker porte au moins un `calico-node` et un `kube-proxy`, les pods des deux DaemonSets. `storage-provisioner`, un pod nu que rien n'épingle, peut se trouver sur n'importe quel nœud.
>
> La capacité affichée est celle de ton hôte (par exemple `8` CPU et `32019572Ki` sur un poste de 32 Gio), identique sur les trois nœuds. Le kubelet lit les ressources de la machine sur laquelle il tourne, c'est-à-dire, pour un conteneur, celles du noyau de l'hôte ; la limite mémoire posée par Docker sur le conteneur n'y change rien, et la limite CPU n'est même pas appliquée sous cgroup v2.
>
> **Vérification** : `docker ps` liste trois conteneurs `cka`, `cka-m02` et `cka-m03` à l'état `Up`, et `docker network inspect` affiche `[{"Subnet":"192.168.49.0/24","Gateway":"192.168.49.1"}]`. Si le sous-réseau diffère, c'est que 192.168.49.0/24 était occupé au démarrage : `minikube -p cka ip` te donne l'adresse réelle du control plane, à utiliser partout à la place de 192.168.49.2.

#### Exercice 1.4 — Entrer dans un nœud

**Point de départ** : exercice 1.3.

Entre dans le nœud `cka-m02` et vérifie : l'utilisateur sous lequel tu es connecté, le nom de la machine, l'état du service kubelet et s'il est activé au démarrage, les conteneurs gérés par containerd, et le contenu de `/etc/kubernetes/manifests`. Ressors du nœud. Fais ensuite la même vérification des manifestes sur `cka`, en une seule commande non interactive.

> [!example]- Solution
> ```bash
> minikube -p cka ssh -n cka-m02
> whoami                         # docker
> hostname                       # cka-m02
> systemctl is-active kubelet    # active
> systemctl is-enabled kubelet   # enabled
> crictl ps                      # échoue : permission denied sur le socket
> sudo crictl ps
> sudo ls -l /etc/kubernetes/manifests
> exit
>
> minikube -p cka ssh -- sudo ls -l /etc/kubernetes/manifests
> ```
>
> On est connecté en `docker`, avec un `sudo` sans mot de passe : c'est l'équivalent, sur le lab, du `ssh <nœud>` puis `sudo -i` de l'examen. `crictl` sans `sudo` échoue sur `/run/containerd/containerd.sock: connect: permission denied`, car le socket appartient à root. Sur `cka-m02`, `/etc/kubernetes/manifests` existe mais est vide : un worker n'a pas de pod statique, et son kubelet surveille quand même ce dossier (chapitre 2.6). Sur `cka`, il contient les quatre manifestes du control plane.
>
> Sur `cka`, `systemctl is-enabled kubelet` répondrait `disabled` : minikube démarre lui-même le kubelet du control plane. C'est un écart avec un cluster kubeadm, où le kubelet est activé partout (section 1.8).
>
> **Vérification** : `sudo crictl ps` sur `cka-m02` liste au moins les conteneurs `calico-node` et `kube-proxy` à l'état `Running`, et la dernière commande affiche quatre fichiers en `-rw-------` appartenant à root : `etcd.yaml`, `kube-apiserver.yaml`, `kube-controller-manager.yaml`, `kube-scheduler.yaml`.

#### Exercice 1.5 — Relever la version de chaque composant

**Point de départ** : exercice 1.4.

Établis l'inventaire des versions du lab : client kubectl et Kustomize intégré, serveur Kubernetes, kubelet et runtime de chaque nœud, images de chaque composant de `kube-system` (API server, controller-manager, scheduler, kube-proxy, etcd, CoreDNS, Calico, storage-provisioner), version d'etcd lue dans son propre binaire, version de minikube et de Helm. Consigne le résultat dans `~/cka/versions.txt`.

> [!example]- Solution
> ```bash
> {
>   kubectl version
>   kubectl get nodes -o 'custom-columns=NOEUD:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion'
>   kubectl -n kube-system get pods -o 'custom-columns=POD:.metadata.name,IMAGES:.spec.containers[*].image'
>   kubectl -n kube-system exec etcd-cka -- etcd --version
>   minikube version
>   helm version --short
> } > ~/cka/versions.txt 2>&1
> cat ~/cka/versions.txt
> ```
>
> `kubectl version` interroge le client et le serveur ; le serveur est en v1.37.0 (dernière version prise en charge par minikube v1.39.0), le client en v1.37.1, à une version de correctif près, ce qui est sans conséquence. Les versions du kubelet et du runtime viennent de `status.nodeInfo`, que chaque kubelet publie dans son objet Node. Les images donnent la version de chaque composant conteneurisé. Pour etcd, on interroge le binaire dans son conteneur : l'image est *distroless*, sans shell, mais `kubectl exec` peut y lancer directement un exécutable présent, ici `etcd`, et l'image contient aussi `etcdctl` et `etcdutl` (chapitre 20.1.3).
>
> **Vérification** : le fichier contient, entre autres, ces valeurs :
>
> ```
> Client Version: v1.37.1
> Kustomize Version: v5.8.1
> Server Version: v1.37.0
> NOEUD     KUBELET   RUNTIME
> cka       v1.37.0   containerd://2.3.4
> cka-m02   v1.37.0   containerd://2.3.4
> cka-m03   v1.37.0   containerd://2.3.4
> ```
>
> et les images `registry.k8s.io/kube-apiserver:v1.37.0` (de même pour `kube-controller-manager`, `kube-scheduler` et `kube-proxy`), `registry.k8s.io/etcd:3.7.0-0`, `registry.k8s.io/coredns/coredns:v1.14.6`, `quay.io/calico/node:v3.32.2`, `quay.io/calico/kube-controllers:v3.32.2`, `gcr.io/k8s-minikube/storage-provisioner:v5`, puis `etcd Version: 3.7.0`, `minikube version: v1.39.0` et `v4.3.1+gc0d08d0`. Le cluster est toujours dans l'état **I0** : aucun exercice de ce chapitre ne l'a modifié.

---
