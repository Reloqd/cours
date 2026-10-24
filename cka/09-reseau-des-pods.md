---
title: "CKA — 9. Le réseau des pods et le CNI"
description: "Le modèle réseau de Kubernetes, les espaces de noms réseau et les paires veth, la spécification CNI telle que containerd l'applique, Calico en IPIP dans le lab, le trajet réel d'un paquet entre pods, hostNetwork et hostPort."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 9. Le réseau des pods et le CNI

Ce chapitre ouvre la partie « Services et réseau », qui pèse 20 % de l'examen. Il descend sous les Services, là où vivent les adresses des pods : comment un pod obtient son adresse, qui la lui donne, par où passe un paquet qui va d'un pod à un autre, sur le même nœud ou d'un nœud à l'autre. Il couvre la compétence *Understand connectivity between Pods* et la part réseau de *Understand extension interfaces (CNI, CSI, CRI, etc.)*, que le chapitre 18 reprend du côté des interfaces. L'examen ne te demandera pas d'écrire un plugin CNI. Il te demandera, en revanche, de comprendre pourquoi un nœud reste `NotReady` faute de configuration CNI, pourquoi un pod reste en `ContainerCreating`, où se trouvent `/etc/cni/net.d` et `/opt/cni/bin`, ce que change `hostNetwork: true`, et de raisonner sur un trajet réseau quand « ça ne passe pas ». Tout ce qui suit est observé sur le lab, où Calico tourne en mode IPIP : tu verras les interfaces, les routes et les paquets encapsulés de tes propres yeux.

### 9.1 Le modèle réseau de Kubernetes

Kubernetes ne fournit pas de réseau. Il fixe un **contrat**, que d'autres composants remplissent. Ce contrat tient en trois règles :

1. chaque pod reçoit sa propre adresse IP, unique dans le cluster, et tous les conteneurs d'un pod partagent cette adresse (ils se parlent par `localhost`) ;
2. tout pod peut joindre tout autre pod, sur le même nœud ou sur un autre, **sans traduction d'adresse** : l'adresse source que voit le pod destinataire est celle du pod émetteur ;
3. les agents d'un nœud (le kubelet, les démons système) peuvent joindre les pods de ce nœud.

Ce modèle « une IP par pod, à plat » est un choix délibéré. Les anciens systèmes de conteneurs partageaient l'adresse de la machine et publiaient des ports : il fallait alors coordonner les ports entre applications, et une application ne voyait jamais l'adresse réelle de son client. Avec une adresse par pod, un pod se comporte comme une petite machine : il écoute sur le port qu'il veut, sans conflit avec ses voisins, et les outils classiques (journaux, pare-feu, `netstat`) voient de vraies adresses.

Kubernetes découpe ensuite le travail entre plusieurs acteurs. Retenir qui fait quoi est la moitié du dépannage réseau :

| Besoin | Qui le réalise | Où le regarder |
|---|---|---|
| Créer l'espace de noms réseau du pod | le runtime de conteneurs (containerd), à la demande du kubelet par le CRI | `crictl pods`, `ip netns` sur le nœud |
| Brancher le pod au réseau et lui donner une IP | le plugin CNI (Calico dans le lab) | `/etc/cni/net.d`, `/opt/cni/bin`, pods du CNI |
| Router entre pods de nœuds différents | le CNI (routes, tunnels, BGP) | `ip route` sur les nœuds |
| Adresse stable et répartition vers les pods (Services) | kube-proxy ou un CNI qui le remplace | chapitre 10 |
| Noms DNS | CoreDNS | chapitre 11 |
| Filtrage entre pods (NetworkPolicy) | le CNI, s'il les implémente | chapitre 14 |
| Entrée depuis l'extérieur (Ingress, Gateway) | un contrôleur tiers | chapitres 12 et 13 |

Un cluster manipule trois plans d'adressage qui **ne doivent jamais se chevaucher** : celui des nœuds, celui des pods et celui des Services. Dans le lab :

```
LES TROIS PLANS D'ADRESSAGE DU LAB
═══════════════════════════════════

  Nœuds      192.168.49.0/24   réseau Docker « cka », passerelle .1 (ton poste)
             cka .2   cka-m02 .3   cka-m03 .4
             → adresses « réelles », portées par l'interface eth0 de chaque nœud

  Pods       10.244.0.0/16     IPPool Calico « default-ipv4-ippool »
             découpé en blocs /26 attribués aux nœuds
             → adresses réelles aussi, portées par l'eth0 de chaque pod

  Services   10.96.0.0/12      --service-cluster-ip-range de l'API server
             kubernetes = 10.96.0.1    kube-dns = 10.96.0.10
             → adresses VIRTUELLES : aucune interface ne les porte,
               seules les règles de kube-proxy les connaissent (chapitre 10)
```

La distinction entre les deux premiers plans et le troisième est fondamentale : on peut faire un `ping` vers un pod, pas vers une adresse de Service. Le chapitre 10.1 explique pourquoi.

> [!info] minikube ≠ examen
> Dans le lab, Calico v3.32.2 est installé par minikube sous forme de manifeste dans `kube-system`, en IPIP, avec des pods en `10.244.0.0/16`. Sur un cluster d'examen, le CNI est celui que l'énoncé a installé (souvent Calico, parfois Flannel ou Cilium) et les plages sont celles de son `kubeadm init`. Ne présume jamais d'un CNI : `kubectl -n kube-system get pods -o wide` et `ls /etc/cni/net.d` sur un nœud te le disent en dix secondes.

### 9.2 Espaces de noms réseau, sandbox et paires veth

#### Un espace de noms réseau par pod

Sous Linux, un *network namespace* (netns) est une pile réseau complète et isolée : ses interfaces, ses adresses, sa table de routage, ses règles netfilter, ses sockets. Chaque pod en possède un. Ce n'est pas un conteneur applicatif qui le détient, mais le **sandbox** du pod : quand le kubelet demande au runtime de créer un pod (appel CRI `RunPodSandbox`), containerd crée le netns, y démarre le petit conteneur *pause* (`registry.k8s.io/pause:3.10.2` dans le lab), puis fait brancher ce netns au réseau par le plugin CNI. Les conteneurs du pod sont ensuite lancés **dans** ce netns.

Trois conséquences pratiques en découlent. Les conteneurs d'un pod partagent l'adresse et l'espace de ports : deux conteneurs d'un même pod ne peuvent pas écouter tous deux sur le port 80, et un sidecar joint l'application par `localhost`. Le redémarrage d'un conteneur (après un `OOMKilled`, une sonde de vivacité en échec) **ne change pas** l'adresse du pod, puisque le sandbox survit. En revanche, un pod recréé (nouvel objet, nouveau sandbox) reçoit en général une nouvelle adresse : c'est la raison d'être des Services.

Sur un nœud du lab, containerd épingle chaque netns dans `/var/run/netns/` sous un nom `cni-<uuid>` :

```bash
minikube -p cka ssh -n cka-m02
sudo ip netns list
```

```
cni-5b0e6c7a-2d41-8f3e-9a1b-7c4e2f0d9a63 (id: 3)
cni-a71c9e02-6b3d-4f58-8e1a-2c9d0b7f4e15 (id: 2)
cni-0f3d8b6e-91a2-4c7d-b5e8-6a2f1c9d3e04 (id: 1)
…
```

Tu peux entrer dans l'un d'eux sans passer par `kubectl` (`sudo ip netns exec cni-… ip -4 -br addr`) : c'est utile quand l'API est injoignable, ou pour un pod dont l'image ne contient aucun outil.

#### La paire veth

Un netns isolé ne sert à rien s'il n'est relié à rien. Le lien est une **paire veth** : deux interfaces virtuelles reliées comme les deux bouts d'un câble. Ce qui entre par un bout sort par l'autre. Le plugin CNI en place un bout dans le netns du pod, sous le nom `eth0`, et laisse l'autre dans le netns du nœud. Avec Calico, ce bout côté nœud s'appelle `cali` suivi de onze caractères hexadécimaux.

Pour retrouver le bout côté nœud de la paire d'un pod, on lit dans le pod l'index de l'interface paire (`iflink`), puis on cherche cet index sur le nœud :

```bash
kubectl -n boutique exec outils -- cat /sys/class/net/eth0/iflink
```

```
13
```

```bash
minikube -p cka ssh -n cka-m02
ip -o link | grep '^13:'
```

```
13: cali1f0e7b8c2a9@if4: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1480 qdisc noqueue state UP mode DEFAULT group default \    link/ether ee:ee:ee:ee:ee:ee brd ff:ff:ff:ff:ff:ff link-netns cni-a71c9e02-6b3d-4f58-8e1a-2c9d0b7f4e15
```

Le `@if4` désigne l'index de `eth0` dans le netns du pod, `link-netns` le netns où il vit. Les numéros varient d'un cluster à l'autre ; la méthode, elle, marche partout et avec tous les CNI à base de veth.

```
UN NŒUD DU LAB (cka-m02) VU DE L'INTÉRIEUR
══════════════════════════════════════════

  ┌─ pod outils (netns cni-a71c…) ─┐   ┌─ pod api-…-h2xkp (netns cni-0f3d…) ─┐
  │ eth0  10.244.195.196/32        │   │ eth0  10.244.195.201/32             │
  │ défaut via 169.254.1.1         │   │ défaut via 169.254.1.1              │
  └──────────┬─────────────────────┘   └──────────┬──────────────────────────┘
             │ paire veth                           │ paire veth
  ┌──────────┴──────────────────────────────────────┴──────────────────────────┐
  │ cali1f0e7b8c2a9                       cali0c6b2f8e4d1        (netns nœud)  │
  │ MAC ee:ee:ee:ee:ee:ee, proxy ARP, pas d'adresse IP                         │
  │                                                                            │
  │ table de routage :                                                         │
  │   10.244.195.196 dev cali1f0e7b8c2a9        ← un /32 par pod local         │
  │   10.244.195.201 dev cali0c6b2f8e4d1                                       │
  │   10.244.142.64/26 via 192.168.49.2 dev tunl0 onlink  ← bloc de cka        │
  │   10.244.34.128/26 via 192.168.49.4 dev tunl0 onlink  ← bloc de cka-m03    │
  │                                                                            │
  │ tunl0  10.244.195.192/32 (tunnel IPIP)     eth0  192.168.49.3/24           │
  └────────────────────────────────────────────────────┬───────────────────────┘
                                                        │
                                          réseau Docker « cka » 192.168.49.0/24
```

Aucun pont (bridge) dans ce schéma : Calico route au niveau 3. D'autres CNI (le plugin `bridge` de référence, Flannel) relient au contraire toutes les veth d'un nœud à un pont Linux (`cni0`, `cbr0`) qui porte la passerelle des pods. Les deux approches respectent le modèle ; elles se dépannent différemment.

### 9.3 La spécification CNI

#### Ce qu'est le CNI

Le *Container Network Interface* est une spécification de la CNCF, accompagnée d'une bibliothèque (`libcni`) et de plugins de référence. Elle définit un contrat très simple entre un **runtime** (celui qui crée les conteneurs) et un **plugin** (celui qui les branche au réseau) : le plugin est un **exécutable**, appelé une fois par opération, qui reçoit ses paramètres par des variables d'environnement et sa configuration en JSON sur son entrée standard, et qui répond en JSON sur sa sortie standard. Il n'y a ni démon imposé ni API réseau : un plugin peut être un script.

La version courante de la spécification est la **1.1.0**. Kubernetes exige un plugin compatible avec la 0.4.0 au moins et recommande la 1.0.0 ; la configuration Calico du lab déclare `"cniVersion": "1.0.0"`.

Depuis Kubernetes 1.24, **ce n'est plus le kubelet qui appelle le CNI**. Les options `--network-plugin` et `--cni-bin-dir` du kubelet ont été supprimées avec dockershim : c'est le runtime de conteneurs, containerd ou CRI-O, qui lit la configuration et exécute les plugins. Quand un énoncé te parle du CNI d'un nœud, c'est donc la configuration de containerd qu'il faut avoir en tête, pas celle du kubelet.

#### Les deux dossiers à connaître

containerd 2.x lit la configuration CNI dans la section `[plugins.'io.containerd.cri.v1.runtime'.cni]` de son `config.toml`. Les valeurs par défaut de containerd 2.3 (celui du lab) sont :

```
[plugins.'io.containerd.cri.v1.runtime'.cni]
  bin_dirs = ['/opt/cni/bin']      # où chercher les exécutables (bin_dir, au singulier, est déprécié depuis 2.1)
  conf_dir = '/etc/cni/net.d'      # où chercher la configuration
  max_conf_num = 1                 # nombre de fichiers de configuration chargés
```

La règle de chargement mérite d'être sue par cœur : containerd prend les fichiers de `/etc/cni/net.d` d'extension `.conf`, `.conflist` ou `.json`, les trie par **ordre lexicographique** et, avec `max_conf_num = 1`, **n'utilise que le premier**. Un fichier `00-autre.conflist` déposé par erreur à côté de `10-calico.conflist` prend donc la main sur tous les nouveaux pods. Inversement, pour neutraliser une configuration sans la supprimer, il suffit de changer son extension : c'est exactement ce que fait minikube sur les configurations livrées avec l'image de ses nœuds.

```bash
minikube -p cka ssh -n cka-m02
sudo ls -la /etc/cni/net.d/
```

```
-rw------- 1 root root  576 Oct 23 18:16 10-calico.conflist
-rw-r--r-- 1 root root  469 Aug 25 02:16 10-crio-bridge.conflist.disabled.mk_disabled
-rw-r--r-- 1 root root  639 Nov 13  2022 87-podman-bridge.conflist.mk_disabled
-rw------- 1 root root 2804 Oct 23 18:16 calico-kubeconfig
-rw-r--r-- 1 root root    0 Oct 23 18:16 cni.lock
```

`10-calico.conflist` est en mode 0600 : sa lecture exige `sudo`. `calico-kubeconfig` contient le jeton du ServiceAccount `calico-cni-plugin`, avec lequel le plugin interroge l'API ; ne l'affiche pas dans un journal ou un ticket. Le contenu de la configuration, déposé par l'init container `install-cni` du pod `calico-node`, est le suivant (le nom du nœud et le MTU sont remplis à l'installation) :

```
{
  "name": "k8s-pod-network",
  "cniVersion": "1.0.0",
  "plugins": [
    {
      "type": "calico",
      "log_level": "info",
      "log_file_path": "/var/log/calico/cni/cni.log",
      "datastore_type": "kubernetes",
      "nodename": "cka-m02",
      "mtu": 0,
      "ipam": { "type": "calico-ipam" },
      "policy": { "type": "k8s" },
      "kubernetes": { "kubeconfig": "/etc/cni/net.d/calico-kubeconfig" }
    },
    {
      "type": "portmap",
      "snat": true,
      "capabilities": { "portMappings": true }
    }
  ]
}
```

Chaque champ a un rôle précis. `name` identifie le réseau. `plugins` est une **chaîne** : le runtime appelle `calico`, puis `portmap`, en passant à chacun le résultat du précédent (`prevResult`). `type` est le nom de l'exécutable cherché dans `/opt/cni/bin` : il doit donc exister un fichier `/opt/cni/bin/calico` et un `/opt/cni/bin/portmap`. `ipam` délègue l'attribution d'adresse à un second exécutable, `calico-ipam` ; un plugin plus simple utiliserait `host-local`, qui distribue les adresses d'une plage locale au nœud (le `spec.podCIDR`, par exemple). `"mtu": 0` demande au plugin de reprendre le MTU détecté par Calico (9.4). `capabilities.portMappings` annonce que `portmap` sait réaliser les `hostPort` : sans cette capacité dans la chaîne, un `hostPort` serait accepté par l'API et ignoré sur le nœud (9.6).

#### Les opérations et les variables

Le runtime indique l'opération dans la variable `CNI_COMMAND` :

| Opération | Quand le runtime l'appelle | Ce que fait le plugin |
|---|---|---|
| `ADD` | création du sandbox d'un pod | crée l'interface `CNI_IFNAME` dans le netns, attribue l'adresse, pose les routes ; renvoie interfaces, IP, routes, DNS |
| `DEL` | suppression du sandbox | défait ce qu'`ADD` a fait, libère l'adresse ; doit réussir même si tout a déjà disparu (appel « au mieux », répétable) |
| `CHECK` | contrôle périodique optionnel | vérifie que le réseau du conteneur est conforme au résultat d'`ADD` (introduit en 0.4.0) |
| `VERSION` | découverte | renvoie les versions de la spécification que le plugin comprend |
| `STATUS` | spécification 1.1.0 | indique si le plugin est prêt à servir des `ADD` |
| `GC` | spécification 1.1.0 | nettoie les ressources orphelines (adresses, règles) |

Pour une chaîne, `ADD` exécute les plugins dans l'ordre de la liste et `DEL` dans l'ordre **inverse**. Les autres paramètres arrivent eux aussi par l'environnement :

| Variable | Contenu |
|---|---|
| `CNI_COMMAND` | l'opération (`ADD`, `DEL`, `CHECK`, `VERSION`…) |
| `CNI_CONTAINERID` | identifiant du sandbox, attribué par le runtime |
| `CNI_NETNS` | chemin du netns, par exemple `/var/run/netns/cni-a71c…` |
| `CNI_IFNAME` | nom de l'interface à créer dans le netns : `eth0` pour Kubernetes |
| `CNI_ARGS` | paires `CLE=valeur` séparées par des `;` ; containerd y passe notamment `K8S_POD_NAMESPACE` et `K8S_POD_NAME` |
| `CNI_PATH` | liste des dossiers où chercher les exécutables (`/opt/cni/bin`) |

La configuration JSON arrive sur l'entrée standard, complétée par le runtime (`runtimeConfig`, par exemple la liste des `portMappings` du pod pour `portmap`). Le résultat d'un `ADD` réussi revient en JSON sur la sortie standard ; une erreur revient en JSON avec un code, et le runtime la remonte dans les événements du pod.

```
CRÉATION D'UN POD, CÔTÉ RÉSEAU
══════════════════════════════

  kubelet ── CRI RunPodSandbox ──▶ containerd
                                     │ 1. crée le netns /var/run/netns/cni-<uuid>
                                     │ 2. lance le conteneur pause dedans
                                     │ 3. lit /etc/cni/net.d (premier fichier)
                                     │ 4. exécute /opt/cni/bin/calico
                                     │      CNI_COMMAND=ADD  CNI_IFNAME=eth0
                                     │      CNI_NETNS=/var/run/netns/cni-<uuid>
                                     │      stdin : la configuration JSON
                                     │        └─▶ calico-ipam : une IP du bloc du nœud
                                     │        └─▶ crée la paire veth, eth0 = IP/32,
                                     │            route /32 vers caliXXXX
                                     │ 5. exécute /opt/cni/bin/portmap (hostPort éventuels)
                                     ▼
  kubelet ◀── IP du sandbox ──── containerd
     │
     └──▶ status.podIP / status.podIPs du pod dans l'API
```

#### Quand le CNI manque ou se trompe

Trois symptômes reviennent à l'examen. **Nœud `NotReady` avec `cni plugin not initialized`** (ou `NetworkReady=false … no network config found in /etc/cni/net.d`) : le dossier de configuration est vide, ou les pods du CNI ne tournent pas sur ce nœud ; tant qu'il n'y a pas de configuration, seuls les pods en `hostNetwork` démarrent (c'est ce qui permet au CNI de s'installer lui-même). **Pod bloqué en `ContainerCreating`** avec un événement `FailedCreatePodSandBox … failed to setup network for sandbox` : l'`ADD` a échoué ; le message qui suit vient du plugin (exécutable absent de `/opt/cni/bin`, API injoignable pour l'IPAM, plage épuisée). **Pod `Running` mais injoignable depuis un autre nœud** : l'`ADD` a réussi, c'est le routage entre nœuds qui manque (pods du CNI en échec sur un nœud, tunnel bloqué par un pare-feu). Le chapitre 23 traite ces pannes du côté du nœud.

> [!tip] Réflexe d'examen
> Pour identifier le CNI d'un cluster : `ls /etc/cni/net.d/` sur un nœud (le premier fichier fait foi), puis `kubectl get pods -A -o wide | grep -Ei 'calico|flannel|cilium|weave'`. La page de documentation à ouvrir est *Network Plugins* (kubernetes.io, rubrique *Concepts › Extending Kubernetes › Compute, Storage, and Networking Extensions*).

### 9.4 Calico dans le lab

#### Les composants

Calico se compose, dans le lab, de trois éléments installés par le manifeste `/var/tmp/minikube/cni.yaml` (pas d'opérateur Tigera, pas de namespace `calico-system`) :

- le DaemonSet `calico-node`, un pod par nœud, en `hostNetwork`. Son init container `install-cni` copie les exécutables `calico` et `calico-ipam` dans `/opt/cni/bin` et écrit `10-calico.conflist`. Son conteneur principal fait tourner **Felix**, qui programme les routes et les règles netfilter du nœud (dont les NetworkPolicies), et **BIRD**, un démon BGP qui annonce aux autres nœuds le bloc d'adresses de son nœud ;
- le Deployment `calico-kube-controllers`, qui nettoie les objets Calico orphelins (blocs de nœuds supprimés, par exemple) ;
- des CRD dans le groupe `crd.projectcalico.org/v1`, où Calico range son état (`datastore_type: kubernetes`) : pools, blocs, affinités de blocs, configuration de Felix.

Le lab n'installe pas l'API server de Calico : l'API `projectcalico.org/v3` et l'outil `calicoctl` n'y sont pas ; on lit les objets par leur nom complet de CRD.

#### L'IPPool et les blocs

L'**IPPool** définit la plage des pods et la façon de les joindre :

```bash
kubectl get ippools.crd.projectcalico.org default-ipv4-ippool -o yaml
```

```yaml
apiVersion: crd.projectcalico.org/v1
kind: IPPool
metadata:
  name: default-ipv4-ippool
spec:
  allowedUses: [Workload, Tunnel]
  assignmentMode: Automatic
  blockSize: 26
  cidr: 10.244.0.0/16
  ipipMode: Always
  natOutgoing: true
  nodeSelector: all()
  vxlanMode: Never
```

L'IPAM de Calico ne distribue pas les adresses une à une à l'échelle du cluster : il découpe le pool en **blocs** de taille `blockSize` (/26, soit 64 adresses) et attribue des blocs aux nœuds. Un nœud qui a besoin d'adresses prend un bloc libre ; s'il remplit le sien, il en prend un autre. Chaque nœud n'annonce ainsi qu'une route par bloc, au lieu d'une par pod. Une adresse du bloc sert à l'interface du tunnel (`allowedUses: Tunnel`), visible dans une annotation du nœud.

Le piège classique du lab se trouve là : **les adresses des pods ne suivent pas `spec.podCIDR`**. Le controller-manager attribue bien un /24 à chaque nœud (`--allocate-node-cidrs=true --cluster-cidr=10.244.0.0/16`), mais `calico-ipam` l'ignore et distribue ses propres blocs :

```bash
kubectl get nodes -o custom-columns='NOEUD:.metadata.name,PODCIDR:.spec.podCIDR,TUNNEL:.metadata.annotations.projectcalico\.org/IPv4IPIPTunnelAddr'
kubectl get blockaffinities.crd.projectcalico.org
```

```
NOEUD     PODCIDR         TUNNEL
cka       10.244.0.0/24   10.244.142.64
cka-m02   10.244.1.0/24   10.244.195.192
cka-m03   10.244.2.0/24   10.244.34.128

NAME                        AGE
cka-10-244-142-64-26        3d
cka-m02-10-244-195-192-26   3d
cka-m03-10-244-34-128-26    3d
```

Un pod en `10.244.195.x` tourne donc sur `cka-m02`, quoi que dise `spec.podCIDR`. Sur un cluster qui utilise Flannel (comme le lab kubeadm du chapitre 19), c'est l'inverse : Flannel prend `spec.podCIDR` tel quel, et l'adresse d'un pod trahit son nœud. Pour savoir où tourne un pod, la seule source sûre reste `kubectl get pod -o wide`.

#### IPIP, VXLAN ou routage direct

Un pod de `cka-m02` qui écrit à `10.244.34.135` (un pod de `cka-m03`) émet un paquet dont la destination n'est connue que de Calico. Le réseau physique, lui, ne connaît que `192.168.49.0/24`. Calico propose trois façons de franchir ce réseau :

| Mode | Principe | Surcoût | Quand |
|---|---|---|---|
| Routage direct (`ipipMode: Never`, `vxlanMode: Never`) | le paquet du pod part tel quel ; les routeurs du réseau doivent connaître les blocs (BGP avec eux, ou nœuds dans un même segment L2) | aucun | réseau maîtrisé |
| **IPIP** (`ipipMode: Always`, le lab) | le paquet du pod est **encapsulé** dans un paquet IP de nœud à nœud (protocole IP 4) ; BIRD échange les routes en BGP | 20 octets par paquet | défaut des manifestes Calico |
| VXLAN (`vxlanMode: Always`) | encapsulation dans de l'UDP 4789, sans BGP | 50 octets | réseaux qui filtrent le protocole 4 (certains clouds) |

Les modes IPIP et VXLAN acceptent aussi la valeur `CrossSubnet` : encapsulation seulement entre nœuds de sous-réseaux différents, routage direct à l'intérieur d'un même sous-réseau. Le lab, avec `Always`, encapsule tout le trafic entre nœuds, même si les trois nœuds partagent le même segment Docker.

#### Le MTU

L'encapsulation réduit la place disponible. L'interface `eth0` d'un nœud a un MTU de 1500 octets ; un paquet IPIP lui ajoute un en-tête IP de 20 octets ; le paquet d'un pod ne doit donc pas dépasser 1480 octets. Le manifeste du lab laisse Calico détecter ce MTU (`veth_mtu: "0"` dans la ConfigMap `calico-config`) : il l'applique à `tunl0`, aux interfaces `cali*` et à l'`eth0` des pods.

```bash
kubectl -n boutique exec outils -- ip link show eth0
```

```
4: eth0@if13: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1480 qdisc noqueue state UP mode DEFAULT group default qlen 1000
    link/ether 3a:51:9c:0e:22:7d brd ff:ff:ff:ff:ff:ff link-netnsid 0
```

Un MTU mal réglé produit un symptôme très reconnaissable : le `ping` passe, une requête HTTP courte aussi, mais les grosses réponses (une page, un téléchargement, une poignée de main TLS) restent bloquées. Le test qui tranche est un `ping` qui interdit la fragmentation (`ping -M do -s 1452 <ip>` : 1452 octets de données + 28 d'en-têtes = 1480).

### 9.5 Le trajet réel d'un paquet

#### Dans le pod : une passerelle qui n'existe pas

Regarde la table de routage du pod `outils` :

```bash
kubectl -n boutique exec outils -- ip -4 -br addr show dev eth0
kubectl -n boutique exec outils -- ip route
```

```
eth0@if13        UP             10.244.195.196/32
default via 169.254.1.1 dev eth0
169.254.1.1 dev eth0 scope link
```

L'adresse du pod est un **/32** : le pod ne se croit sur aucun sous-réseau, il envoie tout à sa passerelle `169.254.1.1`. Aucune interface ne porte cette adresse. Calico active le *proxy ARP* sur l'interface `cali*` côté nœud : quand le pod demande « qui a 169.254.1.1 ? », le nœud répond avec la MAC `ee:ee:ee:ee:ee:ee` de cette interface, et chaque paquet du pod arrive ainsi dans la pile réseau du nœud, qui le route.

```bash
kubectl -n boutique exec outils -- ip neigh
```

```
10.244.195.192 dev eth0 lladdr ee:ee:ee:ee:ee:ee STALE
169.254.1.1 dev eth0 lladdr ee:ee:ee:ee:ee:ee REACHABLE
```

La première entrée est l'adresse du tunnel du nœud (9.4) : quand le nœud écrit lui-même à un pod local (sonde du kubelet, `ping` lancé depuis le nœud), il prend cette adresse pour source (`ip route get 10.244.195.196` sur le nœud affiche `src 10.244.195.192`), et le pod lui répond par la même MAC. L'état (`REACHABLE`, `DELAY`, `STALE`) ne dit que l'âge de la dernière confirmation.

#### Sur le nœud : un /32 par pod, un /26 par nœud voisin

La table de routage de `cka-m02` contient tout ce qu'il faut pour suivre un paquet :

```bash
minikube -p cka ssh -n cka-m02
ip route
```

```
default via 192.168.49.1 dev eth0
10.244.34.128/26 via 192.168.49.4 dev tunl0 proto bird metric 1024 onlink
10.244.142.64/26 via 192.168.49.2 dev tunl0 proto bird metric 1024 onlink
blackhole 10.244.195.192/26 proto bird
10.244.195.194 dev cali8a4e2d6b0f3 scope link metric 1024
10.244.195.196 dev cali1f0e7b8c2a9 scope link metric 1024
10.244.195.198 dev cali7a3d5e9b1c4 scope link metric 1024
10.244.195.201 dev cali0c6b2f8e4d1 scope link metric 1024
172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1 linkdown
192.168.49.0/24 dev eth0 proto kernel scope link src 192.168.49.3
```

Chaque ligne a une raison d'être, sauf celle de `docker0` : cette interface éteinte (`linkdown`) appartient au démon Docker que contient l'image des nœuds minikube, et ne sert pas aux pods. Les routes `/32` vers les `cali*`, posées par Felix, mènent aux pods locaux. Les routes `/26 … dev tunl0 proto bird onlink`, apprises par BIRD auprès des autres nœuds, envoient les blocs distants dans le tunnel IPIP ; `onlink` dit au noyau de considérer la passerelle comme directement joignable par cette interface. La route `blackhole` du bloc local garantit qu'une adresse du bloc qui ne correspond à aucun pod vivant est jetée sur place, au lieu de repartir vers la route par défaut et de boucler.

#### Pod à pod sur le même nœud

Quand `outils` (10.244.195.196) écrit à un pod `front` du même nœud (10.244.195.198), le paquet sort par l'`eth0` du pod, arrive sur `cali1f0e7b8c2a9`, est routé par le nœud vers la route `/32` du destinataire et ressort par `cali7a3d5e9b1c4`. Il ne touche ni `tunl0` ni l'`eth0` du nœud, et son TTL perd une unité (un saut de routage). Aucune traduction d'adresse : le pod `front` voit `10.244.195.196` comme source.

#### Pod à pod entre nœuds

Quand `outils` écrit à un pod `api` de `cka-m03` (10.244.34.135), le trajet est plus long :

```
outils (cka-m02) ──▶ api-…-r8m4t (cka-m03), CALICO IPIP
══════════════════════════════════════════════════════

  pod outils          src 10.244.195.196   dst 10.244.34.135
      │ eth0 → cali1f0e7b8c2a9 (proxy ARP 169.254.1.1)
      ▼
  cka-m02 : route 10.244.34.128/26 via 192.168.49.4 dev tunl0 onlink
      │ tunl0 ENCAPSULE :
      │ ┌─────────────────────────────────────────────────────────┐
      │ │ IP externe  src 192.168.49.3  dst 192.168.49.4  proto 4 │
      │ │ ┌─────────────────────────────────────────────────────┐ │
      │ │ │ IP interne  src 10.244.195.196  dst 10.244.34.135   │ │
      │ │ │ TCP/ICMP…                                           │ │
      │ │ └─────────────────────────────────────────────────────┘ │
      │ └─────────────────────────────────────────────────────────┘
      ▼ eth0 de cka-m02 ─── réseau Docker 192.168.49.0/24 ───▶ eth0 de cka-m03
  cka-m03 : tunl0 DÉCAPSULE, route 10.244.34.135 dev cali… scope link
      ▼
  pod api      voit src 10.244.195.196 (adresse réelle, pas de NAT)
```

Le paquet traverse deux routages (un sur chaque nœud) : un `ping` entre pods de nœuds différents affiche `ttl=62`, contre `ttl=63` entre pods d'un même nœud. L'encapsulation est observable avec `tcpdump` sur l'`eth0` d'un nœud, filtré sur le protocole IP 4 (exercice 9.3) :

```
10:42:07.311958 IP 192.168.49.3 > 192.168.49.4: IP 10.244.195.196 > 10.244.34.135: ICMP echo request, id 41, seq 1, length 64
10:42:07.312077 IP 192.168.49.4 > 192.168.49.3: IP 10.244.34.135 > 10.244.195.196: ICMP echo reply, id 41, seq 1, length 64
```

#### Vers un nœud ou vers l'extérieur

La règle « pas de NAT » ne vaut qu'**entre pods**. Un paquet qu'un pod envoie hors du pool (vers l'adresse d'un nœud, vers Internet) est masqué par Calico (`natOutgoing: true`) : il prend l'adresse du nœud d'origine en sortant par son `eth0`. Un `ping` d'`outils` vers `192.168.49.4` arrive donc sur `cka-m03` avec la source `192.168.49.3`. Sans ce masquage, la réponse d'un serveur extérieur partirait vers une adresse `10.244.x.x` que personne ne sait router.

### 9.6 hostNetwork et hostPort

#### hostNetwork : partager la pile du nœud

Un pod déclaré avec `spec.hostNetwork: true` ne reçoit **pas** de netns propre : ses conteneurs tournent dans le netns du nœud. Le runtime n'appelle pas le CNI pour lui. Le pod a pour adresse celle du nœud, voit toutes ses interfaces et peut écouter sur n'importe quel port du nœud.

C'est indispensable pour les composants qui fabriquent le réseau lui-même ou qui doivent exister avant lui : les pods statiques du control plane (etcd, kube-apiserver…), `kube-proxy`, `calico-node`. C'est aussi un risque : un pod en `hostNetwork` contourne l'isolement réseau, voit le trafic du nœud, et entre en conflit de port avec tout ce qui écoute déjà sur la machine (deux pods en `hostNetwork` qui veulent le port 80 ne peuvent pas cohabiter sur un même nœud). Trois conséquences pratiques :

- **Le DNS** : avec la politique par défaut `dnsPolicy: ClusterFirst`, un pod en `hostNetwork` **retombe sur la résolution du nœud** (comportement de `Default`) et ne résout pas les noms du cluster. Pour lui donner le DNS du cluster, il faut `dnsPolicy: ClusterFirstWithHostNet` (chapitre 11.7).
- **Les ports** : l'API remplit d'office `hostPort` avec la valeur de `containerPort` pour chaque port déclaré d'un pod en `hostNetwork`. Le scheduler en tient compte : deux pods qui déclarent le même port ne seront pas placés sur le même nœud.
- **L'admission** : le niveau `baseline` de Pod Security Admission interdit `hostNetwork`. Dans le namespace `boutique`, en `enforce=baseline` depuis le chapitre 8, la création est refusée :

```
Error from server (Forbidden): error when creating "STDIN": pods "hote-reseau" is forbidden: violates PodSecurity "baseline:latest": host namespaces (hostNetwork=true)
```

#### hostPort : publier un port du nœud vers un pod

`hostPort` est plus discret : le pod garde son netns et son adresse, mais un port du nœud est redirigé vers l'un de ses ports.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: porte-hote
  namespace: default
spec:
  nodeSelector:
    kubernetes.io/hostname: cka-m03
  containers:
  - name: nginx
    image: nginx:1.30.6-alpine
    ports:
    - containerPort: 80
      hostPort: 8080          # le port 8080 de cka-m03 mène au port 80 du pod
      protocol: TCP
```

Ce n'est ni le kubelet ni kube-proxy qui réalise cette redirection, mais le **plugin CNI** `portmap`, à condition que la chaîne de configuration l'annonce (`"capabilities": {"portMappings": true}`) : le runtime lui passe alors la liste des ports du pod, et `portmap` pose des règles de DNAT dans des chaînes `CNI-HOSTPORT-DNAT` et `CNI-DN-…` de la table `nat`. Le port n'est ouvert que sur le nœud qui héberge le pod, et l'option `hostIP` permet de le limiter à une seule adresse de ce nœud. Le scheduler vérifie la disponibilité : un second pod qui demande le même `hostPort` et le même protocole sur un nœud déjà pris y est refusé avec la raison `node(s) didn't have free ports for the requested pod ports`. `hostPort` est lui aussi interdit par le niveau `baseline`.

Le contrôleur d'Ingress de l'addon minikube, au chapitre 12.11, publie ainsi les ports 80 et 443 du nœud `cka`. Voici comment choisir entre les trois mécanismes qui exposent un pod sur l'adresse d'un nœud :

| | `hostNetwork: true` | `hostPort` | Service `NodePort` (chapitre 10.7) |
|---|---|---|---|
| Netns du pod | celui du nœud | propre au pod | propre au pod |
| Qui réalise l'exposition | personne : le processus écoute directement | plugin CNI `portmap` (DNAT) | kube-proxy (DNAT) |
| Nœuds où le port répond | celui du pod | celui du pod | **tous** les nœuds |
| Plage de ports | toutes | toutes | 30000-32767 par défaut |
| Répartition entre plusieurs pods | non | non | oui |
| Pod Security `baseline` | interdit | interdit | sans objet |
| Usage typique | composants système, CNI, kube-proxy | contrôleur d'Ingress sur un nœud dédié | exposer une application |

### 9.7 Ce que fait kube-proxy (aperçu)

Le réseau des pods relie des adresses réelles. Les Services ajoutent une couche d'adresses **virtuelles** : `10.96.0.10` pour le DNS, `10.110.27.164` pour `api`… Ce n'est pas le CNI qui les fait exister, mais **kube-proxy**, un DaemonSet de `kube-system` qui tourne en `hostNetwork` sur chaque nœud. Il surveille les Services et les EndpointSlices et traduit chaque adresse virtuelle en règles de DNAT du noyau, en mode `iptables` dans le lab (ConfigMap `kube-system/kube-proxy`, clé `config.conf`, `mode: iptables`). Le paquet qu'un pod envoie à `10.110.27.164:8080` est réécrit vers `10.244.34.135:8080` **sur le nœud d'origine**, avant même le routage : il suit ensuite exactement le trajet de pod à pod décrit en 9.5. Le chapitre 10.5 démonte ces règles une à une.

Certains CNI remplacent kube-proxy par leur propre implémentation (Cilium, ou Calico en mode eBPF) : il n'y a alors plus de pods `kube-proxy`, et les règles des Services se lisent avec les outils de ce CNI. Si un énoncé te montre un cluster sans DaemonSet `kube-proxy` dont les Services fonctionnent, c'est ce cas de figure.

### 9.8 Diagnostiquer le réseau des pods

Face à « le pod A ne joint pas le pod B », procède couche par couche, du plus proche au plus lointain :

| Question | Commande | Si la réponse est non |
|---|---|---|
| Les deux pods ont-ils une IP et sont-ils `Running` ? | `kubectl get pod -o wide` | `ContainerCreating` : lire les événements, l'`ADD` CNI a échoué |
| Le CNI tourne-t-il sur les deux nœuds ? | `kubectl -n kube-system get pods -o wide \| grep calico` | réparer le pod du CNI du nœud concerné |
| Le nœud est-il `Ready` ? | `kubectl get nodes` | `cni plugin not initialized` : configuration absente de `/etc/cni/net.d` |
| La route vers le bloc distant existe-t-elle ? | `ip route` sur le nœud source | BGP ou tunnel en échec : journaux de `calico-node` |
| Le paquet sort-il encapsulé, arrive-t-il ? | `tcpdump -ni eth0 ip proto 4` dans un pod de débogage du nœud | réseau entre nœuds filtré (protocole 4, ou UDP 4789 en VXLAN) |
| Une NetworkPolicy filtre-t-elle ? | `kubectl get networkpolicy -A` | chapitre 14.12 |
| Les petits paquets passent, pas les gros ? | `ping -M do -s 1452` | MTU incohérent |

Pour la commande `tcpdump`, le plus simple est un pod de débogage de nœud : `kubectl debug node/<nœud>` crée un pod dans le netns du nœud, et le profil `netadmin` lui accorde `NET_ADMIN` et `NET_RAW`. Ce pod partage les espaces de noms du nœud : crée-le dans `default`, jamais dans `boutique`, où `baseline` le refuserait.

> [!tip] Réflexe d'examen
> `kubectl debug node/<nœud> -it --image=<image> --profile=netadmin -n default` te donne un shell avec les outils de l'image, dans la pile réseau du nœud, sans rien installer sur la machine. Pense à supprimer le pod `node-debugger-…` en sortant : il reste `Completed`.

### 9.9 Pièges courants

```
Piège 1 : Déduire le nœud d'un pod de spec.podCIDR
════════════════════════════════════════════════════
  MAUVAIS : « le pod est en 10.244.1.x, il tourne sur cka-m02 »
  SYMPTÔME : on dépanne le mauvais nœud ; avec Calico, les blocs /26
             n'ont rien à voir avec les /24 de spec.podCIDR.
  BON : kubectl get pod -o wide, ou kubectl get blockaffinities.

Piège 2 : Deux fichiers dans /etc/cni/net.d
════════════════════════════════════════════
  MAUVAIS : laisser un 00-test.conflist à côté de 10-calico.conflist
  SYMPTÔME : les NOUVEAUX pods reçoivent une adresse d'un autre réseau
             et ne joignent plus rien ; les anciens marchent encore.
  BON : un seul fichier actif ; neutraliser les autres en changeant
        leur extension (.disabled), comme le fait minikube.

Piège 3 : Chercher le CNI dans la configuration du kubelet
══════════════════════════════════════════════════════════
  MAUVAIS : grep cni /var/lib/kubelet/config.yaml
  SYMPTÔME : rien ; --network-plugin et --cni-bin-dir n'existent plus
             depuis 1.24.
  BON : c'est le runtime qui appelle le CNI : /etc/cni/net.d,
        /opt/cni/bin, section cni du config.toml de containerd.

Piège 4 : Un pod en hostNetwork qui ne résout pas les Services
══════════════════════════════════════════════════════════════
  MAUVAIS : hostNetwork: true en gardant dnsPolicy par défaut
  SYMPTÔME : nslookup api.boutique.svc.cluster.local échoue ;
             /etc/resolv.conf est celui du nœud.
  BON : dnsPolicy: ClusterFirstWithHostNet.

Piège 5 : hostNetwork ou hostPort dans un namespace en baseline
════════════════════════════════════════════════════════════════
  MAUVAIS : kubectl -n boutique apply d'un pod hostNetwork
  SYMPTÔME : Forbidden … violates PodSecurity "baseline:latest":
             host namespaces (hostNetwork=true)
  BON : lire les labels pod-security.kubernetes.io du namespace ;
        utiliser un namespace prévu pour cela (default dans le lab).

Piège 6 : Faire un ping vers une adresse de Service
════════════════════════════════════════════════════
  MAUVAIS : ping 10.96.0.10 pour « tester le DNS »
  SYMPTÔME : aucune réponse alors que le DNS fonctionne.
  BON : une ClusterIP est virtuelle ; tester le service lui-même
        (nslookup, curl sur le bon port).
```

> [!summary] À retenir
> - Le modèle réseau : une IP par pod, tous les pods se joignent sans NAT, les agents d'un nœud joignent ses pods ; Kubernetes fixe le contrat, le CNI le remplit.
> - Le netns d'un pod appartient à son sandbox (conteneur pause) : redémarrer un conteneur garde l'IP, recréer le pod en donne une nouvelle.
> - Depuis 1.24, c'est le runtime (containerd) qui appelle le CNI : configuration dans `/etc/cni/net.d` (premier fichier par ordre lexicographique, un seul chargé), exécutables dans `/opt/cni/bin`.
> - Un plugin CNI est un exécutable : opération dans `CNI_COMMAND` (`ADD`, `DEL`, `CHECK`, `VERSION`, plus `STATUS` et `GC` en 1.1.0), paramètres `CNI_*` dans l'environnement, configuration JSON sur stdin, résultat JSON sur stdout ; une chaîne s'exécute dans l'ordre pour `ADD`, à rebours pour `DEL`.
> - Calico du lab : IPPool `10.244.0.0/16`, blocs /26 par nœud indépendants de `spec.podCIDR`, IPIP `Always`, MTU 1480, proxy ARP via `169.254.1.1`, une route /32 par pod local et une route /26 par nœud voisin via `tunl0`.
> - Entre pods : routage sans NAT (TTL 63 sur le même nœud, 62 entre nœuds) ; vers l'extérieur du pool : masquage (`natOutgoing`).
> - `hostNetwork` partage la pile du nœud (DNS : `ClusterFirstWithHostNet`) ; `hostPort` est réalisé par le plugin `portmap` sur le seul nœud du pod ; les deux sont interdits par `baseline`.
> - Les adresses de Service sont virtuelles : elles n'existent que dans les règles de kube-proxy (chapitre 10).

### 9.10 Exercices

Ces exercices ne modifient pas l'état du fil rouge : ils l'explorent. Tes adresses, noms de pods et index d'interfaces différeront de ceux du texte ; la méthode, non.

#### Exercice 9.1 — Cartographier les adresses du cluster

**Point de départ** : fin du chapitre 8, ou instantané I1.

Relève, pour chaque nœud : son adresse interne, son `spec.podCIDR`, l'adresse de son tunnel IPIP et le bloc Calico qui lui est affecté. Relève ensuite l'adresse et le nœud de chaque pod du namespace `boutique`, et vérifie que chaque adresse appartient au bloc de son nœud. Termine par la plage des Services et l'adresse du Service `kube-dns`.

> [!example]- Solution
> ```bash
> kubectl get nodes -o custom-columns='NOEUD:.metadata.name,IP:.status.addresses[?(@.type=="InternalIP")].address,PODCIDR:.spec.podCIDR,TUNNEL:.metadata.annotations.projectcalico\.org/IPv4IPIPTunnelAddr'
> kubectl get blockaffinities.crd.projectcalico.org
> kubectl get ippools.crd.projectcalico.org default-ipv4-ippool -o jsonpath='{.spec.cidr} {.spec.blockSize} {.spec.ipipMode}{"\n"}'
> kubectl -n boutique get pods -o custom-columns='POD:.metadata.name,IP:.status.podIP,NOEUD:.spec.nodeName' --sort-by=.spec.nodeName
> kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}{"\n"}'
> kubectl get servicecidrs
> ```
>
> Le tunnel d'un nœud est la première adresse de son bloc (`10.244.195.192` pour `cka-m02`), et toutes les adresses de pods de ce nœud tombent dans le même /26 (`10.244.195.192` à `10.244.195.255`), alors que `spec.podCIDR` annonce `10.244.1.0/24`. Les pods du DaemonSet `agent-noeud` en donnent une illustration nette : un pod par nœud, une adresse dans chacun des trois blocs. L'objet ServiceCIDR `kubernetes` reprend la valeur de `--service-cluster-ip-range` de l'API server.
>
> **Vérification** : `kubectl get ippools.crd.projectcalico.org default-ipv4-ippool -o jsonpath='{.spec.cidr}'` affiche `10.244.0.0/16`, `kubectl get servicecidrs` affiche `kubernetes   10.96.0.0/12`, et l'adresse de `kube-dns` est `10.96.0.10`.

#### Exercice 9.2 — Suivre la paire veth du pod outils

**Point de départ** : exercice 9.1.

Depuis le pod `outils`, relève son adresse, sa passerelle et l'index de l'interface paire de son `eth0`. Entre ensuite dans le nœud qui l'héberge et retrouve l'interface `cali*` correspondante, son adresse MAC et la route `/32` qui mène au pod. Retrouve enfin le netns du pod par `ip netns`.

> [!example]- Solution
> ```bash
> kubectl -n boutique get pod outils -o wide
> kubectl -n boutique exec outils -- ip -4 -br addr show dev eth0
> kubectl -n boutique exec outils -- ip route
> kubectl -n boutique exec outils -- cat /sys/class/net/eth0/iflink
> ```
>
> Puis, dans le nœud indiqué par la colonne `NODE` (ici `cka-m02`), avec l'index lu ci-dessus (ici 13) et l'adresse du pod :
>
> ```bash
> minikube -p cka ssh -n cka-m02
> ip -o link | grep '^13:'
> ip route | grep 10.244.195.196
> cat /proc/sys/net/ipv4/conf/cali1f0e7b8c2a9/proxy_arp
> sudo ip netns list
> sudo ip netns exec cni-a71c9e02-6b3d-4f58-8e1a-2c9d0b7f4e15 ip -4 -br addr
> exit
> ```
>
> L'interface d'index 13 est `cali1f0e7b8c2a9`, de MAC `ee:ee:ee:ee:ee:ee`, sans adresse IP ; la route `10.244.195.196 dev cali1f0e7b8c2a9 scope link metric 1024` y mène ; `proxy_arp` vaut `1`, ce qui explique la passerelle fictive `169.254.1.1`. Le nom du netns figure aussi au bout de la ligne `ip -o link` (`link-netns cni-…`).
>
> **Vérification** : `ip netns exec` dans le bon netns affiche, après la ligne `lo`, `eth0@if13  UP  10.244.195.196/32`, la même adresse que `kubectl -n boutique get pod outils -o wide`.

#### Exercice 9.3 — Observer le trafic entre pods et l'encapsulation IPIP

**Point de départ** : exercice 9.2.

Depuis `outils`, envoie trois `ping` vers un pod `front` du **même** nœud, puis vers un pod `api` d'un **autre** nœud, puis vers l'adresse de ce second nœud. Compare les TTL. Capture enfin sur l'`eth0` du nœud d'`outils` les paquets IPIP de ce trafic, à l'aide d'un pod de débogage de nœud créé dans le namespace `default` avec l'image `nicolaka/netshoot:v0.16`, et supprime-le ensuite.

> [!example]- Solution
> ```bash
> kubectl -n boutique get pods -l 'app in (front,api)' -o wide
> # un pod front sur le nœud d'outils (cka-m02) et un pod api sur cka-m03
> kubectl -n boutique exec outils -- ping -c 3 10.244.195.198
> kubectl -n boutique exec outils -- ping -c 3 10.244.34.135
> kubectl -n boutique exec outils -- ping -c 3 192.168.49.4
> ```
>
> Le premier `ping` affiche `ttl=63` (un routage, sur `cka-m02`), le deuxième `ttl=62` (un routage sur chaque nœud), le troisième `ttl=63` (le nœud distant répond directement ; à l'aller, Calico a masqué la source en `192.168.49.3`).
>
> Pour la capture, ouvre un second terminal et lance-la avant de relancer le `ping` inter-nœuds depuis le premier :
>
> ```bash
> kubectl debug node/cka-m02 -n default -it --image=nicolaka/netshoot:v0.16 --profile=netadmin -- tcpdump -ni eth0 -c 2 ip proto 4
> ```
>
> ```bash
> kubectl -n boutique exec outils -- ping -c 1 10.244.34.135
> ```
>
> `tcpdump` affiche deux lignes, `IP 192.168.49.3 > 192.168.49.4: IP 10.244.195.196 > 10.244.34.135: ICMP echo request, id …, seq 1, length 64` puis la réponse, et s'arrête (le double en-tête `IP … : IP …` est la marque de l'encapsulation). Le `ping` vers le pod du même nœud ne produit, lui, aucun paquet IPIP. Le pod de débogage est créé dans `default` parce qu'il partage les espaces de noms du nœud, ce que `baseline` refuserait dans `boutique`.
>
> ```bash
> kubectl -n default get pods -o name | grep node-debugger- | xargs kubectl -n default delete
> ```
>
> **Vérification** : `kubectl -n default get pods` ne liste plus de `node-debugger-…`, et les deux paquets capturés portaient bien un en-tête externe entre adresses de nœuds et un en-tête interne entre adresses de pods.

#### Exercice 9.4 — Lire la configuration CNI d'un nœud

**Point de départ** : exercice 9.3.

Sur `cka-m03`, relève le fichier de configuration CNI actif et les fichiers neutralisés, la liste des plugins de la chaîne et le type d'IPAM, puis vérifie que chaque exécutable référencé existe dans `/opt/cni/bin`. Affiche les dernières lignes du journal du plugin Calico. Dis enfin quel fichier containerd utiliserait si l'on déposait un `05-essai.conflist` dans le même dossier.

> [!example]- Solution
> ```bash
> minikube -p cka ssh -n cka-m03
> sudo ls -la /etc/cni/net.d/
> sudo grep -E '"(type|cniVersion|name)"' /etc/cni/net.d/10-calico.conflist
> ls /opt/cni/bin/ | grep -Ex 'calico|calico-ipam|portmap'
> sudo tail -n 5 /var/log/calico/cni/cni.log
> exit
> ```
>
> Le fichier actif est `10-calico.conflist` ; les fichiers en `.mk_disabled` sont ignorés parce que leur extension n'est ni `.conf`, ni `.conflist`, ni `.json`. La chaîne contient `calico` (IPAM `calico-ipam`) puis `portmap`, et les trois exécutables sont présents. Le journal montre les `ADD` et `DEL` des derniers pods créés ou supprimés sur ce nœud (`Calico CNI IPAM assigned addresses…`, `Releasing address…`).
>
> Un `05-essai.conflist` passerait **avant** `10-calico.conflist` dans l'ordre lexicographique : avec `max_conf_num = 1`, containerd n'utiliserait plus que lui pour les nouveaux pods de ce nœud. Ne le crée pas sur le lab.
>
> **Vérification** : `ls /opt/cni/bin/ | grep -Ex 'calico|calico-ipam|portmap'` affiche trois lignes, et `sudo ls /etc/cni/net.d/*.conflist` n'en affiche qu'une, `10-calico.conflist`.

#### Exercice 9.5 — Un pod en hostNetwork, un pod en hostPort

**Point de départ** : exercice 9.4.

1. Tente de créer dans `boutique` un pod `hote-reseau` (`busybox:1.37.0`, `sleep 3600`, `hostNetwork: true`, placé sur `cka-m03`) et lis le refus.
2. Crée-le dans `default`. Compare son adresse et son `/etc/resolv.conf` à ceux d'`outils`, puis recrée-le avec `dnsPolicy: ClusterFirstWithHostNet` et compare de nouveau.
3. Crée dans `default` le pod `porte-hote` du 9.6 (`nginx:1.30.6-alpine`, `hostPort: 8080` vers le port 80, sur `cka-m03`), interroge-le depuis ton poste par l'adresse de `cka-m03`, retrouve la règle de DNAT posée par `portmap`, puis montre qu'un second pod `porte-hote-2` identique reste `Pending`.
4. Supprime les trois pods.

> [!example]- Solution
> ```bash
> mkdir -p ~/cka/reseau
> cat > ~/cka/reseau/hote-reseau.yaml <<'EOF'
> apiVersion: v1
> kind: Pod
> metadata:
>   name: hote-reseau
> spec:
>   hostNetwork: true
>   nodeSelector:
>     kubernetes.io/hostname: cka-m03
>   containers:
>   - name: boite
>     image: busybox:1.37.0
>     command: ["sleep", "3600"]
> EOF
> kubectl -n boutique apply -f ~/cka/reseau/hote-reseau.yaml
> ```
>
> Le refus cite `violates PodSecurity "baseline:latest": host namespaces (hostNetwork=true)`. Dans `default`, sans label Pod Security, le pod est admis :
>
> ```bash
> kubectl -n default apply -f ~/cka/reseau/hote-reseau.yaml
> kubectl -n default wait --for=condition=Ready pod/hote-reseau --timeout=60s
> kubectl -n default get pod hote-reseau -o wide
> kubectl -n default exec hote-reseau -- cat /etc/resolv.conf
> kubectl -n boutique exec outils -- cat /etc/resolv.conf
> ```
>
> L'adresse du pod est celle du nœud (`192.168.49.4`) et son `resolv.conf` est celui du nœud, que Docker a généré à partir de celui de ton poste : `nameserver 192.168.49.1`, les domaines de recherche de ton poste s'il en a (`search lan`, par exemple) et `options edns0 trust-ad ndots:0`. `outils`, lui, interroge `10.96.0.10` avec les domaines de recherche du cluster. Le champ `dnsPolicy` d'un pod est immuable : on supprime et on recrée.
>
> ```bash
> kubectl -n default delete pod hote-reseau --now
> sed -i 's/^  hostNetwork: true$/  hostNetwork: true\n  dnsPolicy: ClusterFirstWithHostNet/' ~/cka/reseau/hote-reseau.yaml
> kubectl -n default apply -f ~/cka/reseau/hote-reseau.yaml
> kubectl -n default wait --for=condition=Ready pod/hote-reseau --timeout=60s
> kubectl -n default exec hote-reseau -- cat /etc/resolv.conf
> ```
>
> Le fichier contient désormais `nameserver 10.96.0.10`, `search default.svc.cluster.local svc.cluster.local cluster.local` et `options ndots:5`. Si ton poste a des domaines de recherche, le kubelet les ajoute à la fin de la ligne `search` (`… cluster.local lan`) : il complète toujours la liste du cluster par celle du `resolv.conf` du nœud (chapitre 11.6).
>
> ```bash
> cat > ~/cka/reseau/porte-hote.yaml <<'EOF'
> apiVersion: v1
> kind: Pod
> metadata:
>   name: porte-hote
> spec:
>   nodeSelector:
>     kubernetes.io/hostname: cka-m03
>   containers:
>   - name: nginx
>     image: nginx:1.30.6-alpine
>     ports:
>     - containerPort: 80
>       hostPort: 8080
>       protocol: TCP
> EOF
> kubectl -n default apply -f ~/cka/reseau/porte-hote.yaml
> kubectl -n default wait --for=condition=Ready pod/porte-hote --timeout=60s
> curl -s -o /dev/null -w '%{http_code}\n' http://$(minikube -p cka ip -n cka-m03):8080/
> minikube -p cka ssh -n cka-m03 -- 'sudo iptables-save -t nat | grep -E "CNI-HOSTPORT-DNAT .*8080|DNAT --to-destination .*:80$"'
> sed 's/name: porte-hote$/name: porte-hote-2/' ~/cka/reseau/porte-hote.yaml | kubectl -n default apply -f -
> kubectl -n default get pod porte-hote-2
> kubectl -n default get events --field-selector involvedObject.name=porte-hote-2 --sort-by=.lastTimestamp | tail -n 2
> ```
>
> `curl` renvoie `200` ; la table `nat` de `cka-m03` contient une règle `CNI-HOSTPORT-DNAT … --dports 8080` qui saute vers une chaîne `CNI-DN-…`, laquelle fait un `DNAT --to-destination <IP du pod>:80`. Le filtre ramène aussi des lignes `KUBE-SEP-… --comment "boutique/front" … --to-destination …:80` : ce sont les règles de kube-proxy pour le Service `front` (chapitre 10.5), sans rapport avec `hostPort`. `porte-hote-2` reste `Pending` avec un événement `FailedScheduling` qui mentionne `node(s) didn't have free ports for the requested pod ports` (et `didn't match Pod's node affinity/selector` pour les deux autres nœuds).
>
> ```bash
> kubectl -n default delete pod hote-reseau porte-hote porte-hote-2 --now
> ```
>
> **Vérification** : `kubectl -n default get pods` ne liste plus aucun des trois pods, et `curl -s -m 3 http://$(minikube -p cka ip -n cka-m03):8080/` échoue (plus rien ne répond sur ce port).

---
