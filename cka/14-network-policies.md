---
title: "CKA — 14. NetworkPolicies"
description: "Sémantique exacte des NetworkPolicies (isolement par direction, union des règles, sélecteurs, piège ET/OU, ipBlock, ports et endPort), refus par défaut et DNS, traduction d'adresse des NodePort et LoadBalancer sous Calico, méthode de test, et sécurisation complète de la boutique."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 14. NetworkPolicies

Par défaut, le réseau d'un cluster Kubernetes est plat et ouvert : n'importe quel pod joint n'importe quel autre pod, dans n'importe quel namespace, sur n'importe quel port. Les **NetworkPolicies** permettent de restreindre ces flux en couches 3 et 4, par des listes d'autorisations attachées aux pods au moyen de sélecteurs de labels. L'API est courte, mais sa sémantique est pleine de subtilités qui font la différence à l'examen : une politique n'isole qu'une direction, les règles s'additionnent sans jamais se contredire, un tiret de trop dans le YAML transforme un ET en OU, les ports sont ceux des pods et non des Services, et les adresses vues par la politique dépendent de la traduction d'adresse faite en amont. Ce chapitre traite tout cela, puis construit pas à pas la protection de la boutique, avec une méthode de test rigoureuse depuis le pod `outils`. Les compétences officielles concernées sont *Define and enforce Network Policies*, dans *Services and Networking* (20 %), et, pour le diagnostic, *Troubleshoot services and networking*. La fin du chapitre correspond à l'instantané **I2**.

### 14.1 Le modèle : ouvert par défaut, liste d'autorisations

Le modèle réseau de Kubernetes (chapitre 9.1) exige que tout pod puisse joindre tout pod sans traduction d'adresse. Rien, dans ce modèle, ne restreint quoi que ce soit. Une NetworkPolicy ajoute des restrictions, selon trois principes.

Premier principe : **c'est une liste d'autorisations, jamais une interdiction**. Une NetworkPolicy ne contient que des règles qui autorisent. Il n'existe pas de règle « refuse » ; le refus naît de l'**isolement** : dès qu'un pod est sélectionné par une politique pour une direction, tout ce qui n'est pas explicitement autorisé dans cette direction est refusé.

Deuxième principe : **les politiques s'additionnent**. Si plusieurs politiques s'appliquent à un pod pour une direction, ce qui est autorisé est l'**union** de ce qu'elles autorisent. L'ordre d'évaluation n'a pas d'importance, et aucune politique ne peut retirer ce qu'une autre autorise.

Troisième principe : **l'API ne fait rien seule**. Comme l'Ingress, la NetworkPolicy est une déclaration. C'est le plugin réseau (CNI) qui la met en œuvre ; un CNI qui ne la gère pas l'accepte… et l'ignore, sans erreur ni avertissement (14.9).

Une NetworkPolicy est namespacée et ne concerne que des connexions dont au moins une extrémité est un pod. Elle agit en couches 3 et 4 : adresses, protocoles (TCP, UDP, SCTP) et ports. Elle ne sait rien des noms d'hôtes, des URL, de TLS, ni des noms de Services.

### 14.2 L'isolement, direction par direction

Chaque pod a deux états d'isolement indépendants, un pour l'entrée (*ingress*) et un pour la sortie (*egress*).

```
LES DEUX ISOLEMENTS D'UN POD
════════════════════════════

  Aucune politique ne sélectionne le pod pour cette direction
     → non isolé : tout est permis dans cette direction

  Au moins une politique le sélectionne (podSelector) ET a la
  direction dans ses policyTypes
     → isolé : seul passe ce qu'autorise l'UNION des règles
       de toutes ces politiques pour cette direction

  ┌───────────────┐   egress de A    ingress de B   ┌───────────────┐
  │    pod A      │ ──────────────▶ ─────────────▶ │    pod B      │
  │ (source)      │  autorisé par   autorisé par   │ (destination) │
  └───────────────┘  les règles de  les règles de  └───────────────┘
                     sortie de A    entrée de B

  Une connexion A → B passe si ET SEULEMENT SI la sortie de A
  l'autorise ET l'entrée de B l'autorise (chaque côté non isolé
  autorise tout).
```

La troisième case du schéma est la source de nombreuses erreurs de diagnostic. Autoriser l'entrée de `api` depuis `front` ne suffit pas si `front` est isolé en sortie : il faut aussi que la sortie de `front` autorise `api`. Dans un namespace en refus par défaut dans les deux directions, chaque flux exige donc **deux** autorisations, une à chaque extrémité.

Deux exceptions complètent la règle. Le **trafic de retour** d'une connexion autorisée est implicitement autorisé : les NetworkPolicies sont à états, on n'écrit pas de règle pour la réponse. Et le trafic **entre un pod et son propre nœud** est toujours autorisé : la documentation précise qu'un pod isolé en entrée accepte les connexions venues de son nœud. C'est ce qui permet aux sondes du kubelet (chapitre 4.8) de fonctionner sous un refus total. Un pod ne peut pas non plus se bloquer lui-même : ce qu'il envoie à sa propre adresse ou à `localhost` ne passe pas par le filtrage.

### 14.3 Anatomie d'une NetworkPolicy

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-entree
  namespace: boutique
spec:
  podSelector:              # À QUI s'applique la politique (namespace de la politique)
    matchLabels:
      app: api
  policyTypes:              # QUELLES directions elle isole
  - Ingress
  ingress:                  # CE QUI est autorisé en entrée (liste de règles, OU)
  - from:                   # d'où (liste de pairs, OU)
    - podSelector:
        matchLabels:
          tier: web
    ports:                  # vers quels ports (liste, OU) ; ET avec from
    - protocol: TCP
      port: 8080
```

`spec.podSelector` sélectionne les pods **du namespace de la politique** auxquels elle s'applique ; vide (`{}`), il les sélectionne tous. `policyTypes` liste les directions isolées. `ingress` et `egress` sont des listes de règles : une connexion est autorisée si elle satisfait **au moins une** règle. Dans une règle, `from` (ou `to`) et `ports` se combinent en **ET** : la connexion doit venir d'un des pairs **et** viser un des ports. À l'intérieur de `from` comme de `ports`, les éléments se combinent en **OU**.

La valeur par défaut de `policyTypes` est un piège classique. Si le champ est omis, le serveur d'API le remplit ainsi : `Ingress` **toujours**, et `Egress` **seulement si** la politique contient une section `egress`. Une politique qui ne contient que des règles `egress` sans `policyTypes` isole donc… l'entrée aussi, sans rien y autoriser. Et une politique qui veut refuser toute sortie, sans aucune règle `egress`, doit écrire `Egress` dans `policyTypes`, faute de quoi elle n'isolerait que l'entrée. Écris toujours `policyTypes` explicitement.

La différence entre un champ **absent** et un champ **vide** est le second piège. Elle tient en une table :

| Écriture | Sens |
|---|---|
| `podSelector: {}` (spec) | tous les pods du namespace de la politique |
| `policyTypes: [Ingress]` sans `ingress` | isole l'entrée, n'autorise rien : refus total en entrée |
| `ingress: []` | idem : aucune règle, rien n'est autorisé |
| `ingress: [{}]` | une règle vide : tout est autorisé en entrée |
| règle sans `from` | toutes les sources |
| règle sans `ports` | tous les ports |
| `from: [{podSelector: {}}]` | tous les pods du namespace de la politique |
| `from: [{namespaceSelector: {}}]` | tous les pods de tous les namespaces |
| `from: [{}]` | refusé par l'API : « must specify a peer » |

`ingress: [{}]` et `ingress: []` ne diffèrent que de deux accolades et ont des effets opposés. Le premier ouvre tout, le second ferme tout.

> [!tip] Réflexe d'examen
> Il n'existe **pas** de `kubectl create networkpolicy` : la liste des générateurs de `kubectl create` en 1.37 n'en contient aucun. Ouvre la page *Concepts → Services, Load Balancing, and Networking → Network Policies* (`kubernetes.io/docs/concepts/services-networking/network-policies/`) : elle contient un exemple complet et les cinq politiques par défaut (refus et autorisation, entrée et sortie), à copier puis adapter. `kubectl explain networkpolicy.spec.ingress.from` rappelle les champs. Après création, `kubectl describe networkpolicy` montre la façon dont Kubernetes a interprété ton YAML : c'est la meilleure relecture.

### 14.4 Les pairs : podSelector, namespaceSelector, ipBlock

Un pair (élément de `from` ou de `to`) désigne une source ou une destination de quatre façons :

| Pair | Désigne |
|---|---|
| `podSelector` seul | les pods du **namespace de la politique** dont les labels correspondent |
| `namespaceSelector` seul | **tous** les pods des namespaces dont les labels correspondent |
| `namespaceSelector` **et** `podSelector` dans le même élément | les pods correspondants **dans** les namespaces correspondants |
| `ipBlock` | une plage d'adresses (`cidr`), moins des sous-plages (`except`) |

On ne peut pas désigner un namespace par son nom : seulement par ses labels. Le control plane pose sur chaque namespace un label immuable, **`kubernetes.io/metadata.name`**, dont la valeur est le nom du namespace. C'est le moyen standard de viser un namespace précis :

```yaml
- namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: ingress-nginx
```

Les sélecteurs acceptent `matchLabels` et `matchExpressions` (`In`, `NotIn`, `Exists`, `DoesNotExist`), comme partout dans Kubernetes. Un `ipBlock` ne se combine avec rien : l'API refuse un élément qui contient à la fois `ipBlock` et un sélecteur (« may not specify both ipBlock and another peer »). Chaque `except` doit être strictement inclus dans `cidr` (« must be a strict subset of `cidr` »).

La documentation précise que `ipBlock` vise des adresses **extérieures** au cluster, parce que les adresses des pods sont éphémères. Calico compare l'adresse quelle qu'elle soit : un `ipBlock` qui recouvre le réseau des pods autorise aussi des pods, dans tous les namespaces. Pour désigner des pods, utilise toujours des sélecteurs.

Le cas des pods en `hostNetwork` est explicitement indéfini par la documentation ; dans l'implémentation la plus courante, et c'est le cas de Calico, leur trafic est traité comme celui de l'adresse du nœud : les sélecteurs ne les voient pas, un `ipBlock` couvrant l'adresse du nœud si.

### 14.5 Le piège ET/OU du YAML

C'est le piège le plus célèbre des NetworkPolicies, et il tient à **un tiret**. Compare ces deux extraits :

```yaml
# ÉCRITURE 1 : UN pair qui combine deux sélecteurs (ET)
ingress:
- from:
  - namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: boutique
    podSelector:
      matchLabels:
        app: outils
```

```yaml
# ÉCRITURE 2 : DEUX pairs (OU)
ingress:
- from:
  - namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: boutique
  - podSelector:
      matchLabels:
        app: outils
```

```
CE QUE CHAQUE ÉCRITURE AUTORISE (politique dans le namespace essai-np)
═══════════════════════════════════════════════════════════════════════

  Écriture 1 (ET) : from = [ {ns boutique ET pod app=outils} ]
     ✔ outils dans boutique
     ✘ tout autre pod de boutique
     ✘ un pod app=outils dans essai-np

  Écriture 2 (OU) : from = [ {ns boutique}, {pod app=outils} ]
     ✔ TOUS les pods de boutique
     ✔ les pods app=outils du namespace DE LA POLITIQUE (essai-np),
       puisqu'un podSelector seul vise ce namespace
     ✘ un pod app=outils d'un troisième namespace
```

Dans l'écriture 1, `podSelector` est une clé du **même** élément de liste que `namespaceSelector` (aligné sous lui, sans tiret) : les deux conditions doivent être vraies. Dans l'écriture 2, le tiret ouvre un **second** élément : l'une ou l'autre suffit. L'écriture 2 est presque toujours une erreur quand l'intention était « tel pod de tel namespace » : elle ouvre le namespace entier.

`kubectl describe` lève tout doute, parce qu'il affiche un bloc `From:` par élément de la liste. Pour l'écriture 1 :

```
  Allowing ingress traffic:
    To Port: 8080/TCP
    From:
      NamespaceSelector: kubernetes.io/metadata.name=boutique
      PodSelector: app=outils
```

Pour l'écriture 2 :

```
  Allowing ingress traffic:
    To Port: 8080/TCP
    From:
      NamespaceSelector: kubernetes.io/metadata.name=boutique
    From:
      PodSelector: app=outils
```

Deux blocs `From:`, deux pairs, un OU. Le même raisonnement vaut pour `to` en sortie, et pour la combinaison de `from` et `ports` : un tiret devant `ports` en ferait une **seconde règle**, sans source restreinte, qui ouvrirait ce port à tout le monde.

### 14.6 Ports, protocoles et endPort

Un élément de `ports` a trois champs. `protocol` vaut `TCP`, `UDP` ou `SCTP`, et **`TCP` par défaut** : une règle DNS qui oublie `protocol: UDP` n'autorise que le DNS sur TCP, et la résolution échoue. `port` est un numéro ou un **nom de port** ; un nom est résolu, pour chaque pod sélectionné, d'après les `containerPort` nommés de ce pod. Sans `port`, tous les ports du protocole sont visés. `endPort` étend `port` à une **plage** inclusive.

```yaml
ports:
- protocol: TCP
  port: 32000
  endPort: 32768
```

`endPort` est stable depuis Kubernetes 1.25, avec trois contraintes vérifiées par l'API : il exige `port` (« may not be specified when `port` is not specified »), un `port` numérique et non nommé (« may not be specified when `port` is non-numeric »), et une valeur supérieure ou égale à `port` (« must be greater than or equal to `port` »). La documentation avertit qu'un CNI qui ne gère pas `endPort` n'applique que `port` ; Calico le gère. `kubectl describe` affiche une plage sous la forme `To Port Range: 32000-32768/TCP`.

Le point le plus important de cette section est ailleurs : **les ports d'une NetworkPolicy sont ceux des pods, après traduction d'adresse**. Quand un pod appelle un Service, kube-proxy remplace l'adresse et le port virtuels du Service par l'adresse et le `targetPort` d'un pod, avant que le filtrage n'ait lieu. La politique ne voit jamais l'adresse ClusterIP ni le `port` du Service.

```
CE QUE VOIT LA POLITIQUE QUAND front APPELLE http://api:8080
═════════════════════════════════════════════════════════════

  pod front ── 10.96.x.y:8080 (ClusterIP du Service api)
               │ kube-proxy (DNAT) : port 8080 du Service → targetPort http
               ▼
             10.244.a.b:8080 (pod api)  ◀── c'est CE couple que filtrent
                                            la sortie de front ET
                                            l'entrée de api
```

Dans la boutique, port du Service et port du pod coïncident (80 pour `front`, 8080 pour `api`), ce qui masque le phénomène. Il saute aux yeux dès qu'ils diffèrent : un Service qui publie le port 80 vers un `targetPort` 8080 exige une règle sur **8080**. Le cas d'école est l'accès au serveur d'API depuis un pod : le Service `kubernetes` publie 443 (10.96.0.1:443), mais le paquet filtré va à l'adresse du nœud control plane sur le port réel de l'apiserver. Une sortie autorisée vers « 443 » ne suffit pas ; il faut un `ipBlock` sur l'adresse du control plane avec le port **8443** sur le lab, **6443** sur un cluster kubeadm.

### 14.7 Les politiques par défaut et le DNS

La documentation donne cinq politiques de référence, à connaître par leur forme :

| Intention | `podSelector` | `policyTypes` | Règles |
|---|---|---|---|
| refuser toute entrée | `{}` | `[Ingress]` | aucune |
| refuser toute sortie | `{}` | `[Egress]` | aucune |
| refuser tout | `{}` | `[Ingress, Egress]` | aucune |
| autoriser toute entrée | `{}` | `[Ingress]` | `ingress: [{}]` |
| autoriser toute sortie | `{}` | `[Egress]` | `egress: [{}]` |

Une politique d'autorisation totale rend inopérante, pour sa direction, toute autre politique du namespace : l'union contient tout. Un refus par défaut, à l'inverse, n'empêche pas les autres politiques d'ouvrir des flux : il fixe seulement le point de départ.

Un refus de sortie bloque aussi **le DNS** : la documentation le rappelle explicitement. Sans résolution, `curl http://api:8080` échoue avant même de tenter la connexion, et des applications refusent de démarrer (nginx résout au démarrage les noms de ses `proxy_pass`). Tout refus de sortie s'accompagne donc d'une autorisation vers le DNS du cluster. La politique se rédige vers les **pods** CoreDNS, puisque l'adresse 10.96.0.10 du Service est traduite avant le filtrage :

```yaml
egress:
- to:
  - namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: kube-system
    podSelector:
      matchLabels:
        k8s-app: kube-dns
  ports:
  - protocol: UDP
    port: 53
  - protocol: TCP
    port: 53
```

Le pair combine les deux sélecteurs dans un seul élément (14.5) : seuls les pods `k8s-app=kube-dns` de `kube-system`. Les deux protocoles sont nécessaires : UDP pour les requêtes ordinaires, TCP quand une réponse est tronquée. Le port est celui des pods CoreDNS, 53, qui est aussi celui du Service. Le label `k8s-app=kube-dns` est porté par les pods CoreDNS de kubeadm comme de minikube, pour raison historique (chapitre 11).

### 14.8 Le trafic du nœud, ipBlock et la traduction d'adresse source

C'est la partie la plus délicate de la sémantique, et la plus souvent fausse dans les supports de cours. La documentation la pose en une phrase : quand le trafic d'entrée ou de sortie du cluster subit une réécriture d'adresse, il n'est **pas défini** si elle a lieu avant ou après l'évaluation des NetworkPolicies, et le comportement varie selon le CNI, le fournisseur et l'implémentation des Services. Il faut donc raisonner sur l'implémentation réelle. Voici celle du lab : kube-proxy en mode `iptables`, Calico en IPIP, pods en 10.244.0.0/16, nœuds en 192.168.49.0/24.

Un Service NodePort ou LoadBalancer avec `externalTrafficPolicy: Cluster` (la valeur par défaut, celle de `front` et `front-lb`) peut envoyer une requête reçue par un nœud vers un pod d'un **autre** nœud. Pour que la réponse revienne par le même chemin, kube-proxy **masque** l'adresse source (SNAT) : le pod ne voit jamais l'adresse du client. Le noyau traite le paquet en trois temps : traduction de destination (DNAT) à l'arrivée, filtrage au moment du transfert, traduction de source (SNAT) au départ. Les NetworkPolicies de Calico sont appliquées au moment du transfert vers le pod.

```
NODEPORT, externalTrafficPolicy: Cluster (kube-proxy iptables, Calico IPIP)
═══════════════════════════════════════════════════════════════════════════

 poste 192.168.49.1 ── TCP → 192.168.49.2:30080 (nœud cka)
                        │ arrivée : DNAT vers un pod front tiré au hasard,
                        │           paquet marqué « à masquer »
        ┌───────────────┴────────────────────────┐
  pod sur cka (local)                      pod sur cka-m03 (distant)
        │                                        │
  transfert : politique d'entrée           départ de cka : SNAT vers l'adresse
  du pod évaluée avec la source            de tunl0 de cka (10.244.142.64),
  D'ORIGINE, 192.168.49.1                  encapsulation IPIP vers 192.168.49.4
        │                                        │
  départ : SNAT vers l'adresse             arrivée sur cka-m03 : décapsulation,
  de tunl0 de cka (10.244.142.64) :        transfert : politique d'entrée du pod
  les interfaces cali* n'ont pas           évaluée avec la source 10.244.142.64
  d'adresse                                      │
        │                                        │
  le pod VOIT l'adresse après SNAT,       le pod voit 10.244.142.64
  la politique a VU 192.168.49.1
```

Deux cas, donc, et deux adresses sources différentes pour la politique d'entrée du pod. Quand le pod est sur le nœud qui reçoit la requête, la politique voit l'adresse **d'origine** du client (ici le poste, 192.168.49.1), même si le pod, lui, verra ensuite l'adresse de tunnel du nœud (10.244.142.64 pour `cka`). Quand le pod est sur un autre nœud, la politique voit l'**adresse du tunnel IPIP** du nœud d'arrivée, une adresse du réseau 10.244.0.0/16 que Calico réserve à chaque nœud et publie dans l'annotation `projectcalico.org/IPv4IPIPTunnelAddr` de l'objet Node :

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.projectcalico\.org/IPv4IPIPTunnelAddr}{"\n"}{end}'
```

```
cka	10.244.142.64
cka-m02	10.244.195.192
cka-m03	10.244.34.128
```

Ces adresses sont la première de chaque bloc /26 attribué au nœud (chapitre 9.4) ; elles changent à chaque création du cluster, les tiennes diffèrent. Elles ne sont jamais attribuées à un pod.

Pour qu'un pod protégé reste joignable par NodePort et LoadBalancer depuis le réseau des nœuds, la politique doit donc autoriser deux familles d'adresses : le **réseau des nœuds et de leurs clients** (192.168.49.0/24, qui contient le poste, les nœuds et la plage MetalLB) pour le cas local, et les **adresses de tunnel** des trois nœuds, en /32, pour le cas distant. Autoriser tout 10.244.0.0/16 marcherait aussi, mais ouvrirait le port à tous les pods de tous les namespaces, ce que la politique veut justement éviter.

L'autre solution est de supprimer la traduction : avec `externalTrafficPolicy: Local` (chapitre 10.10), kube-proxy ne transmet qu'aux pods du nœud qui reçoit la requête, sans SNAT ; la politique et le pod voient tous deux l'adresse du client, et seul un `ipBlock` sur les clients légitimes est nécessaire. En contrepartie, un nœud sans pod prêt ne répond plus. Le fil rouge garde `Cluster`, la valeur par défaut, et autorise donc les deux familles.

Le trafic qui passe par le contrôleur d'Ingress ou par le proxy Envoy ne relève pas de ce cas : ces proxys sont des pods, qui ouvrent eux-mêmes une connexion vers l'adresse du pod de destination, sans traduction. Leur adresse source est celle de leur pod, dans leur namespace : un `namespaceSelector` suffit.

> [!info] minikube ≠ examen
> Les adresses exactes et le nom de l'annotation dépendent du CNI et de son mode d'encapsulation : IPIP ici (`projectcalico.org/IPv4IPIPTunnelAddr`), VXLAN ailleurs, aucune encapsulation avec d'autres plugins. À l'examen, une tâche de NetworkPolicy porte sur des sélecteurs et des ports entre pods ; si elle mentionne des clients externes, lis-la à la lumière de 14.8 et vérifie par un test réel.

### 14.9 Qui applique les NetworkPolicies : le CNI

L'API NetworkPolicy est implémentée par le plugin réseau. Calico la gère complètement, y compris `endPort` ; son agent Felix, dans chaque pod `calico-node`, surveille les NetworkPolicies, les pods et les namespaces, et programme le filtrage du noyau de son nœud. Flannel, au contraire, ne gère pas les NetworkPolicies : sur un cluster Flannel seul, les objets sont acceptés et n'ont **aucun effet**. Avant de dépanner une politique qui « ne marche pas », vérifie que le CNI la met en œuvre.

Le relevé du lab montre le comportement de Calico. Une politique prend effet en moins de trois secondes, sur des pods placés sur des nœuds différents. Un flux refusé se traduit par une **expiration** (le paquet est jeté), pas par un refus de connexion. Les politiques survivent à `minikube -p cka stop` puis `start`. La documentation ajoute deux règles générales. Un pod créé après la politique est isolé dès son démarrage ; un pod créé pendant que le CNI traite une nouvelle politique peut démarrer brièvement sans protection ou sans connectivité. Et l'effet d'une nouvelle politique sur une connexion **déjà établie** est laissé à l'implémentation, et la documentation déconseille de modifier politiques, pods ou namespaces d'une façon qui toucherait des connexions en cours. Pour tester une politique, ouvre donc toujours de **nouvelles** connexions (une commande `curl` par essai), jamais une session gardée ouverte.

L'API a des limites que la documentation énumère. Elle ne sait pas viser un Service par son nom, ni un nœud par son nom (seulement par adresse), ni journaliser les connexions refusées, ni exprimer un refus explicite qui l'emporterait sur une autorisation, ni empêcher un pod de recevoir le trafic de son nœud ou de `localhost`, ni imposer une politique à tous les namespaces. Ces besoins relèvent de politiques propres au CNI ou d'un maillage de services.

### 14.10 Méthode de test

Une NetworkPolicy ne se valide pas en la relisant : elle se valide par des connexions réelles, autorisées **et** refusées. La méthode tient en quatre règles.

**Tester les deux sens de chaque flux.** Pour chaque flux, vérifie qu'il passe depuis une source autorisée et qu'il échoue depuis une source non autorisée. Un test qui ne vérifie que ce qui doit passer ne prouve rien : un namespace sans aucune politique le réussit aussi.

**Choisir le bon client.** Le pod `outils` est autorisé en sortie vers tout (`outils-sortie`) : il teste l'**entrée** des pods visés sans que sa propre sortie ne brouille le résultat. Pour tester la **sortie** d'un pod, on lance le client depuis ce pod (`kubectl exec deploy/front -- wget …`, `kubectl exec deploy/api -- /agnhost connect …`). Pour représenter un intrus, un pod sans label autorisé, dans le namespace ou dans un namespace sans politique.

**Borner le temps et lire le code de sortie.** Un refus de Calico est une expiration ; sans délai maximal, l'outil attend des minutes. Les commandes de référence :

| Outil | Commande | Succès | Refus par politique | Refus de connexion |
|---|---|---|---|---|
| curl | `curl -s -o /dev/null -m 3 -w '%{http_code}\n' URL` | code HTTP, sortie 0 | `000`, sortie **28** | `000`, sortie **7** |
| nc | `nc -z -w 3 HÔTE PORT` | sortie 0 | sortie 1 après 3 s | sortie 1 immédiate |
| wget (busybox) | `wget -q -O- -T 3 URL` | contenu | `download timed out` | `Connection refused` |
| agnhost | `/agnhost connect --timeout=3s HÔTE:PORT` | rien, sortie 0 | `TIMEOUT` | `REFUSED` |

La différence entre expiration et refus de connexion est un indice de premier ordre. Une expiration désigne un filtrage (ou une route manquante) ; un refus immédiat désigne l'absence de processus à l'écoute, ou un Service sans endpoint, pour lequel kube-proxy rejette activement la connexion.

**Ne pas tester par un chemin qui contourne le filtrage.** `kubectl port-forward` atteint le pod par son espace réseau, sur `localhost` : il fonctionne même sous un refus total. `kubectl exec POD -- curl localhost` aussi. Les sondes du kubelet passent toujours (14.2). Aucun de ces chemins ne dit quoi que ce soit d'une politique.

Une fois les tests faits, `kubectl describe networkpolicy -n NS` relit les politiques telles que l'API les a comprises, et `kubectl get pods -n NS --show-labels` vérifie que les labels visés existent vraiment. Un sélecteur qui ne sélectionne rien est valide et silencieux.

### 14.11 Sécuriser la boutique

Le fil rouge applique le principe du moindre privilège au namespace `boutique` : tout est refusé, puis chaque flux nécessaire est ouvert, aux deux extrémités.

```
LES FLUX AUTORISÉS DE LA BOUTIQUE
═════════════════════════════════

  ingress-nginx ─┐
  envoy-gateway- ┤               ┌──────────────┐ 8080 ┌───────────┐ 6379 ┌───────────┐
  system         ├── 80 ───────▶ │ tier=web     │ ───▶ │ app=api   │ ───▶ │ app=redis │
  outils ────────┤               │ front,       │      │           │      │ (ch. 15)  │
  réseau des     │               │ front-v2     │      └───────────┘      └───────────┘
  nœuds + tunnels┘               └──────────────┘           ▲
  (NodePort, LB)                                            │ 8080
                                   tier=web, outils, ingress-nginx,
                                   envoy-gateway-system ────┘

  Tous les pods ── UDP/TCP 53 ──▶ kube-system, k8s-app=kube-dns
  outils ──────── tout ─────────▶ tout
  Toujours permis : kubelet → pods de son nœud (sondes)
```

Huit politiques réalisent ce schéma. Les deux premières posent le cadre : refus total et DNS.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: refus-par-defaut
  namespace: boutique
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: autorise-dns
  namespace: boutique
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
```

Le niveau web reçoit ses clients sur le port 80 et n'a le droit de sortir que vers `api`. La politique d'entrée a deux règles : les clients internes au cluster, désignés par sélecteurs, et le réseau des nœuds avec les adresses de tunnel (14.8). Les trois adresses /32 ci-dessous sont celles du relevé de référence ; l'exercice 14.3 les génère à partir de ton cluster.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-entree
  namespace: boutique
spec:
  podSelector:
    matchLabels:
      tier: web
  policyTypes:
  - Ingress
  ingress:
  - ports:
    - protocol: TCP
      port: 80
    from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: envoy-gateway-system
    - podSelector:
        matchLabels:
          app: outils
  - ports:
    - protocol: TCP
      port: 80
    from:
    - ipBlock:
        cidr: 192.168.49.0/24
    - ipBlock:
        cidr: 10.244.142.64/32
    - ipBlock:
        cidr: 10.244.195.192/32
    - ipBlock:
        cidr: 10.244.34.128/32
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-sortie
  namespace: boutique
spec:
  podSelector:
    matchLabels:
      tier: web
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: api
    ports:
    - protocol: TCP
      port: 8080
```

`ports` est écrit avant `from` dans les règles de `web-entree` : l'ordre des clés d'un objet YAML n'a pas d'importance, et cette disposition permet d'ajouter des pairs en fin de fichier. Les deux règles pourraient être fusionnées en une seule ; les séparer rend `describe` plus lisible. Les quatre dernières politiques ferment le niveau `api`, préparent `redis` (qui n'existera qu'au chapitre 15 : une politique peut viser des pods qui n'existent pas encore) et laissent `outils` sortir librement.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-entree
  namespace: boutique
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          tier: web
    - podSelector:
        matchLabels:
          app: outils
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: envoy-gateway-system
    ports:
    - protocol: TCP
      port: 8080
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-sortie
  namespace: boutique
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
  - Egress
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: redis
    ports:
    - protocol: TCP
      port: 6379
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: redis-entree
  namespace: boutique
spec:
  podSelector:
    matchLabels:
      app: redis
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: api
    ports:
    - protocol: TCP
      port: 6379
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: outils-sortie
  namespace: boutique
spec:
  podSelector:
    matchLabels:
      app: outils
  policyTypes:
  - Egress
  egress:
  - {}
```

`api-entree` ne contient qu'une règle à quatre pairs (OU) et un port (ET) : quatre sources, un seul port. `outils-sortie` utilise `egress: [{}]` : une règle vide autorise toute destination et tout port. Le pod `outils` reste isolé en **entrée** par `refus-par-defaut`, ce qui ne gêne rien : `kubectl exec` passe par le kubelet et le runtime, pas par le réseau des pods.

Pour une même direction et un même pod, les politiques s'additionnent. La sortie d'un pod `front` est l'union de `autorise-dns` et de `web-sortie` : DNS et `api:8080`, rien d'autre. L'entrée d'un pod `api` est celle de `api-entree` seule. Le tableau des flux attendus, qui sert de grille de test, en découle :

| Source | Destination | Attendu | Politiques en jeu |
|---|---|---|---|
| `outils` | `front:80`, `api:8080` | passe | `outils-sortie`, `web-entree` / `api-entree` |
| `outils` | Internet | passe | `outils-sortie` |
| pod `front` | `api:8080` | passe | `web-sortie`, `api-entree` |
| pod `front` | Internet | expiration | `web-sortie` (DNS seul en plus) |
| pod `api` | `front:80` | expiration | `api-sortie` |
| pod `intrus` (boutique) | `front:80` | expiration | `refus-par-defaut` (sortie de l'intrus) |
| pod `intrus` | DNS | passe | `autorise-dns` |
| pod d'un autre namespace | `front:80`, `api:8080` | expiration | `web-entree`, `api-entree` |
| poste | NodePort 30080, `front-lb` | passe | `web-entree`, seconde règle |
| poste | Ingress, Gateway (HTTPS) | passe | `web-entree` / `api-entree` par namespace |
| kubelet | sondes de `front`, `api` | passe | trafic du nœud, toujours permis |

### 14.12 Dépanner une NetworkPolicy

```
MÉTHODE : DU FLUX À LA POLITIQUE
════════════════════════════════

  1. Le symptôme est-il une EXPIRATION ? (curl code 28, TIMEOUT)
       non, refus immédiat → pas un problème de politique :
       Service, endpoints, port (chapitres 10 et 22)
  2. Quelles politiques sélectionnent la SOURCE en sortie ?
     Quelles politiques sélectionnent la DESTINATION en entrée ?
       kubectl -n NS get netpol ; kubectl -n NS get pod P --show-labels
  3. Pour chaque côté isolé : un pair et un port correspondent-ils ?
       kubectl -n NS describe netpol …   (lire les blocs From:/To:)
       → labels réels des pods et des namespaces
       → port du POD (targetPort), protocole (TCP par défaut)
  4. Le DNS passe-t-il ? (nslookup / dig depuis la source)
  5. Le CNI applique-t-il les politiques ? (Calico : pods calico-node prêts)
```

| Symptôme | Cause fréquente |
|---|---|
| plus rien ne résout dans le namespace | refus de sortie sans politique DNS, ou DNS limité à TCP (protocole par défaut) |
| un pod joint `api` par son IP mais pas par son nom | DNS bloqué en sortie |
| `api` refuse `front` alors que `api-entree` l'autorise | sortie de `front` non autorisée (oubli de l'autre extrémité) |
| tout un namespace atteint le pod | tiret en trop : `podSelector` séparé du `namespaceSelector` (OU) |
| règle sans effet | label visé absent ou mal orthographié ; port du Service au lieu du port du pod |
| NodePort accessible une fois sur deux | `ipBlock` sans les adresses de tunnel (14.8) |
| aucune politique n'a d'effet | CNI sans prise en charge des NetworkPolicies |
| sortie ouverte alors qu'on voulait la fermer | `policyTypes` omis : `Egress` n'est ajouté que s'il existe une section `egress` |

L'exercice 22.6 reprend ce diagnostic sur une panne injectée : la politique `autorise-dns` dont le port a été changé.

### 14.13 Pièges courants

```
Piège 1 : Le tiret qui transforme un ET en OU
══════════════════════════════════════════════
  MAUVAIS  : - namespaceSelector: {…boutique}
             - podSelector: {app: outils}
  SYMPTÔME : tout le namespace boutique passe
  BON      : - namespaceSelector: {…boutique}
               podSelector: {app: outils}      (même élément)

Piège 2 : Refus de sortie sans DNS
═══════════════════════════════════
  SYMPTÔME : « could not resolve host », nginx qui ne démarre plus
             (host not found in upstream)
  BON      : autoriser UDP ET TCP 53 vers k8s-app=kube-dns de kube-system,
             appliquée avec ou avant le refus

Piège 3 : Une seule extrémité ouverte
══════════════════════════════════════
  MAUVAIS  : api-entree autorise tier=web, mais front est isolé en sortie
  SYMPTÔME : expiration de front vers api
  BON      : sous refus total, chaque flux = une règle de sortie à la
             source + une règle d'entrée à la destination

Piège 4 : Le port du Service
═════════════════════════════
  MAUVAIS  : port: 80 parce que le Service publie 80 vers targetPort 8080
  SYMPTÔME : expiration
  BON      : la politique voit l'adresse et le port du POD (après DNAT)

Piège 5 : policyTypes omis
═══════════════════════════
  MAUVAIS  : une politique « refus de sortie » sans section egress ni
             policyTypes
  SYMPTÔME : elle isole l'ENTRÉE (Ingress est toujours ajouté), pas la sortie
  BON      : policyTypes explicite, toujours

Piège 6 : ingress: [{}] au lieu de ingress: []
═══════════════════════════════════════════════
  SYMPTÔME : le « refus » autorise tout
  BON      : pas de règle du tout (ou []) pour refuser ; [{}] = tout permis

Piège 7 : Tester avec port-forward
═══════════════════════════════════
  SYMPTÔME : « ça marche » alors que la politique refuse tout
  BON      : tester depuis un pod, par le réseau des pods, avec un délai
             (curl -m 3, nc -w 3) et lire le code de sortie

Piège 8 : NodePort et SNAT
═══════════════════════════
  MAUVAIS  : ipBlock limité à l'adresse du client externe
  SYMPTÔME : NodePort qui répond pour certains pods seulement
  BON      : avec externalTrafficPolicy: Cluster, autoriser aussi les
             adresses que la traduction donne aux paquets (tunnels IPIP
             des nœuds sous Calico), ou passer en Local
```

> [!summary] À retenir
> - Une NetworkPolicy ne fait qu'autoriser ; le refus vient de l'**isolement** : un pod sélectionné pour une direction n'accepte plus que l'**union** des règles de toutes les politiques qui le sélectionnent pour cette direction.
> - Une connexion passe si la **sortie** de la source **et** l'**entrée** de la destination l'autorisent ; le retour est implicite ; le trafic du nœud vers ses pods (sondes) passe toujours.
> - `policyTypes` par défaut : `Ingress` toujours, `Egress` seulement s'il y a une section `egress`. Écris-le toujours. `[]` refuse tout, `[{}]` autorise tout.
> - Dans une règle, `from`/`to` **ET** `ports` ; dans une liste, **OU**. `namespaceSelector` et `podSelector` dans le **même** élément = ET ; avec un tiret chacun = OU. `kubectl describe` affiche un bloc `From:` par pair.
> - `podSelector` seul vise le namespace de la politique ; un namespace se vise par son label `kubernetes.io/metadata.name` ; `ipBlock` ne se combine avec rien.
> - Ports : ceux **des pods** après DNAT ; `protocol` vaut `TCP` par défaut (DNS : UDP **et** TCP 53) ; `endPort` exige un `port` numérique inférieur ou égal.
> - NodePort/LoadBalancer en `externalTrafficPolicy: Cluster` : la source vue dépend du nœud qui livre (client d'origine en local, adresse de tunnel IPIP du nœud d'arrivée à distance sous Calico) ; `Local` préserve l'adresse du client.
> - Pas de générateur `kubectl create networkpolicy` : copie depuis la page *Network Policies* de la documentation. Teste avec un délai (`curl -m 3`, `nc -w 3`), depuis la bonne source, dans les deux sens ; une expiration signale un filtrage.

### 14.14 Exercices

#### Exercice 14.1 — Constater l'ouverture par défaut

**Point de départ** : exercice 13.7 (à défaut : `lab/restaurer.sh I1`, puis `lab/etats/10-*/appliquer.sh` à `lab/etats/13-*/appliquer.sh` dans l'ordre).

Vérifie qu'aucune NetworkPolicy n'existe dans `boutique`. Crée deux pods de test, tous deux avec l'image `nicolaka/netshoot:v0.16` et la commande `sleep infinity` : `intrus` dans `boutique` avec le label `app=intrus`, et `sonde-np` dans `default` avec le label `app=sonde-np`. Depuis `outils`, `intrus` et `sonde-np`, teste avec un délai de 3 secondes l'accès à `front` (port 80) et à `api` (port 8080, chemin `/hostname`), ainsi que la résolution DNS de `api.boutique.svc.cluster.local`.

> [!example]- Solution
> ```bash
> kubectl -n boutique get networkpolicy
> kubectl -n boutique run intrus --image=nicolaka/netshoot:v0.16 --labels=app=intrus \
>   --command -- sleep infinity
> kubectl -n default run sonde-np --image=nicolaka/netshoot:v0.16 --labels=app=sonde-np \
>   --command -- sleep infinity
> kubectl -n boutique wait --for=condition=Ready pod/intrus --timeout=120s
> kubectl -n default wait --for=condition=Ready pod/sonde-np --timeout=120s
> essai() {
>   echo "== $1/$2"
>   kubectl -n $1 exec $2 -- curl -s -o /dev/null -m 3 -w 'front %{http_code}\n' http://front.boutique/
>   kubectl -n $1 exec $2 -- curl -s -m 3 http://api.boutique:8080/hostname; echo
>   kubectl -n $1 exec $2 -- dig +short +time=2 +tries=1 api.boutique.svc.cluster.local
> }
> essai boutique outils; essai boutique intrus; essai default sonde-np
> ```
>
> La fonction `essai` prend le namespace et le pod client ; elle s'écrit de la même façon sous bash et sous zsh. Les noms courts `front.boutique` et `api.boutique` fonctionnent depuis tout namespace grâce aux domaines de recherche du `resolv.conf` des pods (chapitre 11.6). Le pod `intrus` reçoit les requests et limits par défaut du LimitRange `boutique-limites` (chapitre 8.11), ce qui satisfait le ResourceQuota ; l'avertissement PodSecurity `restricted` est attendu.
>
> **Vérification** : `kubectl -n boutique get networkpolicy` affiche `No resources found in boutique namespace.` ; depuis les trois pods, `front 200`, un nom de pod `api-…` et l'adresse ClusterIP du Service `api`. Sans politique, tout est ouvert, y compris pour un pod d'un autre namespace.

#### Exercice 14.2 — Refus par défaut et DNS

**Point de départ** : exercice 14.1.

Dans `boutique`, crée la NetworkPolicy `refus-par-defaut` (tous les pods, entrée et sortie) et la NetworkPolicy `autorise-dns` (sortie de tous les pods vers les pods `k8s-app=kube-dns` du namespace `kube-system`, UDP et TCP 53), dans un même `kubectl apply`. Refais les tests de l'exercice 14.1 et teste l'Ingress de la boutique depuis le poste. Explique chaque résultat.

> [!example]- Solution
> Écris `~/cka/boutique/np-refus-dns.yaml` avec les deux premières politiques de 14.11, puis :
>
> ```bash
> kubectl apply -f ~/cka/boutique/np-refus-dns.yaml
> kubectl -n boutique exec outils -- curl -s -o /dev/null -m 3 -w '%{http_code}\n' http://front/; echo "code $?"
> kubectl -n boutique exec intrus -- dig +short +time=2 +tries=1 api.boutique.svc.cluster.local
> kubectl -n boutique exec intrus -- curl -s -o /dev/null -m 3 -w '%{http_code}\n' http://front/; echo "code $?"
> kubectl -n default exec sonde-np -- curl -s -o /dev/null -m 3 -w '%{http_code}\n' http://front.boutique/; echo "code $?"
> IP=$(minikube -p cka ip)
> curl -s -o /dev/null -m 30 -w '%{http_code}\n' --cacert ~/cka/boutique/boutique-tls.crt \
>   --resolve boutique.example:443:$IP https://boutique.example/
> ```
>
> `outils`, `intrus` et `sonde-np` obtiennent tous `000` et `command terminated with exit code 28`, mais pas pour la même raison : `outils` et `intrus` sont arrêtés dès leur **sortie**, puisque `refus-par-defaut` isole aussi tous les pods de `boutique` en sortie ; `sonde-np`, dont le namespace n'a aucune politique, est arrêté par l'**entrée** de `front`. Le DNS fonctionne depuis `intrus` grâce à `autorise-dns`. L'Ingress répond `504` après une quinzaine de secondes : ingress-nginx tente jusqu'à trois connexions de 5 secondes chacune (`proxy-connect-timeout` 5 s, `proxy-next-upstream-tries` 3) vers des pods `front` désormais injoignables, puis abandonne. Les pods restent `Ready` : les sondes du kubelet passent toujours. Les deux politiques sont appliquées ensemble pour qu'aucun pod ne redémarre entre les deux sans DNS.
>
> **Vérification** : `kubectl -n boutique get networkpolicy` liste `autorise-dns` et `refus-par-defaut` ; `kubectl -n boutique describe networkpolicy refus-par-defaut` affiche `<none> (Selected pods are isolated for ingress connectivity)` et `<none> (Selected pods are isolated for egress connectivity)` ; `kubectl -n boutique get pods` montre tous les pods prêts.

#### Exercice 14.3 — Le niveau web, NodePort compris

**Point de départ** : exercice 14.2.

Crée `web-sortie` (sortie des pods `tier=web` vers les pods `app=api` sur TCP 8080). Crée une première version de `web-entree` : entrée des pods `tier=web` sur TCP 80 depuis les namespaces `ingress-nginx` et `envoy-gateway-system`, depuis les pods `app=outils`, et depuis le réseau des nœuds (/24 de l'adresse de `cka`). Teste 30 fois le NodePort 30080 de `cka` depuis le poste et regarde dans le journal de `front` l'adresse source vue par nginx. Complète ensuite `web-entree` avec les adresses de tunnel IPIP de chaque nœud (en /32), lues dans les annotations des nœuds, et refais le test, puis teste `front-lb`, l'Ingress et le Gateway.

> [!example]- Solution
> Écris `~/cka/boutique/np-web-sortie.yaml` avec `web-sortie` (14.11) et applique-le. Fabrique la première version de `web-entree` à partir du réseau réel du lab :
>
> ```bash
> kubectl apply -f ~/cka/boutique/np-web-sortie.yaml
> NET=$(minikube -p cka ip | cut -d. -f1-3).0/24
> cat > ~/cka/boutique/np-web-entree.yaml <<EOF
> apiVersion: networking.k8s.io/v1
> kind: NetworkPolicy
> metadata:
>   name: web-entree
>   namespace: boutique
> spec:
>   podSelector:
>     matchLabels:
>       tier: web
>   policyTypes:
>   - Ingress
>   ingress:
>   - ports:
>     - protocol: TCP
>       port: 80
>     from:
>     - namespaceSelector:
>         matchLabels:
>           kubernetes.io/metadata.name: ingress-nginx
>     - namespaceSelector:
>         matchLabels:
>           kubernetes.io/metadata.name: envoy-gateway-system
>     - podSelector:
>         matchLabels:
>           app: outils
>   - ports:
>     - protocol: TCP
>       port: 80
>     from:
>     - ipBlock:
>         cidr: $NET
> EOF
> kubectl apply -f ~/cka/boutique/np-web-entree.yaml
> IP=$(minikube -p cka ip)
> for i in $(seq 30); do curl -s -o /dev/null -m 2 -w '%{http_code}\n' http://$IP:30080/; done | sort | uniq -c
> kubectl -n boutique get pods -l app=front -o wide
> kubectl -n boutique logs -l app=front --prefix --tail=20 | grep curl
> ```
>
> Une partie des requêtes répond `200`, les autres `000` : les réussites sont celles que kube-proxy a envoyées au pod `front` placé sur `cka`, pour lequel la politique voit l'adresse d'origine du poste, couverte par le /24. Les échecs sont les requêtes envoyées aux pods de `cka-m02` et `cka-m03` : elles y arrivent par le tunnel IPIP avec, pour source, l'adresse de tunnel de `cka`, que la politique ne connaît pas (14.8). Le journal de nginx montre l'adresse source vue **par le pod** après traduction : l'adresse de tunnel de `cka` (`10.244.142.64`), jamais celle du poste, y compris pour le pod placé sur `cka`. Sans le `grep`, le journal est surtout fait des lignes `kube-probe/1.37` des sondes, qui arrivent avec l'adresse de tunnel du nœud du pod (`10.244.34.128` pour un pod de `cka-m03`) et passaient déjà sous le refus total (14.2). Ajoute maintenant les adresses de tunnel :
>
> ```bash
> kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.projectcalico\.org/IPv4IPIPTunnelAddr}{"\n"}{end}'
> for t in $(kubectl get nodes -o jsonpath='{.items[*].metadata.annotations.projectcalico\.org/IPv4IPIPTunnelAddr}'); do
>   printf '    - ipBlock:\n        cidr: %s/32\n' "$t" >> ~/cka/boutique/np-web-entree.yaml
> done
> tail -8 ~/cka/boutique/np-web-entree.yaml
> kubectl apply -f ~/cka/boutique/np-web-entree.yaml
> for i in $(seq 30); do curl -s -o /dev/null -m 2 -w '%{http_code}\n' http://$IP:30080/; done | sort | uniq -c
> LB=$(kubectl -n boutique get svc front-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
> for i in $(seq 30); do curl -s -o /dev/null -m 2 -w '%{http_code}\n' http://$LB/; done | sort | uniq -c
> CA=~/cka/boutique/boutique-tls.crt
> curl -s --cacert $CA --resolve boutique.example:443:$IP https://boutique.example/; echo
> GW=$(kubectl -n boutique get gateway boutique-gw -o jsonpath='{.status.addresses[0].value}')
> curl -s --cacert $CA --resolve gw.boutique.example:443:$GW -H 'X-Version: v2' https://gw.boutique.example/; echo
> ```
>
> Les ajouts sont des éléments de la liste `from` de la seconde règle, ce que vérifie le `tail`. La boucle sur le NodePort et celle sur `front-lb` donnent maintenant `30 200`. L'Ingress et le Gateway répondent : leurs proxys sont des pods des namespaces autorisés.
>
> **Vérification** : `kubectl -n boutique describe networkpolicy web-entree` affiche deux règles séparées par `----------`, la première avec deux `NamespaceSelector` et un `PodSelector`, la seconde avec quatre `IPBlock` ; le NodePort et `front-lb` répondent `200` trente fois sur trente ; l'Ingress affiche `<h1>Boutique</h1><p>v1</p>` et le Gateway `<h1>Boutique</h1><p>v2</p>`. En revanche, `https://boutique.example/api/hostname` et `https://gw.boutique.example/api/hostname` échouent encore : l'entrée de `api` est fermée.

#### Exercice 14.4 — Le niveau api, redis et outils

**Point de départ** : exercice 14.3.

Crée les politiques `api-entree` (entrée des pods `app=api` sur TCP 8080 depuis `tier=web`, `app=outils` et les namespaces `ingress-nginx` et `envoy-gateway-system`), `api-sortie` (sortie des pods `app=api` vers `app=redis` sur TCP 6379), `redis-entree` (entrée des pods `app=redis` sur TCP 6379 depuis `app=api`) et `outils-sortie` (sortie libre pour `app=outils`). Déroule ensuite la grille de test de 14.11, puis supprime les pods `intrus` et `sonde-np`.

> [!example]- Solution
> Écris `~/cka/boutique/np-api-redis-outils.yaml` avec les quatre dernières politiques de 14.11, puis :
>
> ```bash
> kubectl apply -f ~/cka/boutique/np-api-redis-outils.yaml
> t() { kubectl "$@" >/dev/null 2>&1 && echo "passe" || echo "bloqué"; }
> echo -n "outils → front:80       "; t -n boutique exec outils -- curl -s -f -m 3 http://front/
> echo -n "outils → api:8080       "; t -n boutique exec outils -- curl -s -f -m 3 http://api:8080/hostname
> echo -n "outils → Internet       "; t -n boutique exec outils -- curl -s -o /dev/null -m 5 https://example.com/
> echo -n "front → api:8080        "; t -n boutique exec deploy/front -- wget -q -O- -T 3 http://api:8080/hostname
> echo -n "front → Internet        "; t -n boutique exec deploy/front -- wget -q -O- -T 3 http://example.com/
> echo -n "api → front:80          "; t -n boutique exec deploy/api -- /agnhost connect --timeout=3s front:80
> echo -n "intrus → front:80       "; t -n boutique exec intrus -- curl -s -f -m 3 http://front/
> echo -n "intrus → DNS            "; t -n boutique exec intrus -- dig +short +time=2 +tries=1 api.boutique.svc.cluster.local
> echo -n "sonde-np → front:80     "; t -n default exec sonde-np -- curl -s -f -m 3 http://front.boutique/
> echo -n "sonde-np → api:8080     "; t -n default exec sonde-np -- curl -s -f -m 3 http://api.boutique:8080/hostname
> IP=$(minikube -p cka ip); CA=~/cka/boutique/boutique-tls.crt
> GW=$(kubectl -n boutique get gateway boutique-gw -o jsonpath='{.status.addresses[0].value}')
> curl -s --cacert $CA --resolve api.boutique.example:443:$IP https://api.boutique.example/hostname; echo
> curl -s --cacert $CA --resolve boutique.example:443:$IP https://boutique.example/api/hostname; echo
> curl -s --cacert $CA --resolve gw.boutique.example:443:$GW https://gw.boutique.example/api/hostname; echo
> kubectl -n boutique delete pod intrus --now
> kubectl -n default delete pod sonde-np --now
> ```
>
> La fonction `t` lance une commande `kubectl` et n'affiche que son issue. `--now` évite d'attendre les 30 secondes du délai de grâce : `sleep` ignore SIGTERM (chapitre 4.10). `outils` atteint tout (`outils-sortie` pour sa sortie, `web-entree` et `api-entree` pour l'entrée des cibles). `front` atteint `api` parce que **deux** politiques l'autorisent, `web-sortie` à la source et `api-entree` à la destination, mais pas Internet. `api` ne peut pas joindre `front` : sa sortie se limite au DNS et à `redis` ; agnhost affiche `TIMEOUT`. `intrus` résout les noms mais ne joint rien. `sonde-np`, dans un namespace sans politique, peut tout émettre, mais l'entrée de `front` et d'`api` le refuse. Les trois accès HTTPS à `api` passent, respectivement par le contrôleur d'Ingress, par `front` puis `api`, et par le proxy Envoy. `redis-entree` et `api-sortie` ne sont pas testables avant le chapitre 15, qui crée `redis`.
>
> **Vérification** : la grille affiche `passe` pour les trois lignes `outils`, pour `front → api:8080` et `intrus → DNS`, et `bloqué` pour toutes les autres ; les trois `curl` HTTPS affichent un nom de pod `api-…` ; `kubectl -n boutique get networkpolicy` liste huit politiques : `api-entree`, `api-sortie`, `autorise-dns`, `outils-sortie`, `redis-entree`, `refus-par-defaut`, `web-entree`, `web-sortie`.

#### Exercice 14.5 — Le piège ET/OU

**Point de départ** : exercice 14.4.

Crée le namespace `essai-np` et, dedans, le pod `multi` (image `registry.k8s.io/e2e-test-images/agnhost:2.66.1`, arguments `porter`, label `app=multi`, variables d'environnement `SERVE_PORT_8080=a`, `SERVE_PORT_8081=b`, `SERVE_PORT_8085=c`, `SERVE_PORT_9000=d`) et le pod `client` (`nicolaka/netshoot:v0.16`, `sleep infinity`, label `app=outils`). Crée dans `essai-np` la politique `et-ou` qui n'autorise l'entrée de `multi`, sur TCP 8080, qu'au pod `outils` du namespace `boutique`. Vérifie que `outils` passe et que `client` est refusé. Ajoute ensuite un tiret devant `podSelector` dans la politique, réapplique, et explique ce qui change.

> [!example]- Solution
> ```bash
> kubectl create namespace essai-np
> kubectl -n essai-np run multi --image=registry.k8s.io/e2e-test-images/agnhost:2.66.1 \
>   --labels=app=multi --env=SERVE_PORT_8080=a --env=SERVE_PORT_8081=b \
>   --env=SERVE_PORT_8085=c --env=SERVE_PORT_9000=d -- porter
> kubectl -n essai-np run client --image=nicolaka/netshoot:v0.16 --labels=app=outils \
>   --command -- sleep infinity
> kubectl -n essai-np wait --for=condition=Ready pod --all --timeout=120s
> ```
>
> Écris `~/cka/essai-np-et-ou.yaml` :
>
> ```yaml
> apiVersion: networking.k8s.io/v1
> kind: NetworkPolicy
> metadata:
>   name: et-ou
>   namespace: essai-np
> spec:
>   podSelector:
>     matchLabels:
>       app: multi
>   policyTypes:
>   - Ingress
>   ingress:
>   - from:
>     - namespaceSelector:
>         matchLabels:
>           kubernetes.io/metadata.name: boutique
>       podSelector:
>         matchLabels:
>           app: outils
>     ports:
>     - protocol: TCP
>       port: 8080
> ```
>
> ```bash
> kubectl apply -f ~/cka/essai-np-et-ou.yaml
> M=$(kubectl -n essai-np get pod multi -o jsonpath='{.status.podIP}')
> kubectl -n boutique exec outils -- curl -s -m 3 http://$M:8080/; echo " (outils)"
> kubectl -n essai-np exec client -- curl -s -m 3 http://$M:8080/; echo " code $? (client)"
> kubectl -n essai-np describe networkpolicy et-ou | sed -n '/Spec:/,$p'
> sed -i 's/^      podSelector:/    - podSelector:/' ~/cka/essai-np-et-ou.yaml
> kubectl apply -f ~/cka/essai-np-et-ou.yaml
> kubectl -n essai-np exec client -- curl -s -m 3 http://$M:8080/; echo " (client)"
> kubectl -n essai-np describe networkpolicy et-ou | sed -n '/Spec:/,$p'
> ```
>
> Avec l'écriture d'origine, un seul pair combine les deux sélecteurs : seul `outils` de `boutique` passe (`a`), `client` expire. Le `sed` transforme la clé `podSelector` du pair en un **second pair** : la règle autorise désormais tout pod de `boutique` **ou** tout pod `app=outils` de `essai-np`, le namespace de la politique. `client` passe alors. Les deux `describe` le montrent : un bloc `From:` avec deux sélecteurs, puis deux blocs `From:`. Note que la sortie de `outils` n'est pas en cause : `outils-sortie` l'autorise vers tout.
>
> **Vérification** : premier essai, `a (outils)` puis un code `28` pour `client` ; après le `sed`, `a (client)` ; le second `describe` contient deux lignes `From:`.

#### Exercice 14.6 — Une plage de ports avec endPort

**Point de départ** : exercice 14.5.

Remplace la politique `et-ou` par la politique `plage-ports`, qui n'autorise l'entrée de `multi` que depuis le pod `outils` de `boutique`, sur la plage TCP 8080 à 8085. Prédis puis vérifie le résultat sur les ports 8080, 8081, 8085 et 9000. Essaie ensuite d'écrire la même plage avec un port nommé, et explique le refus. Supprime enfin le namespace `essai-np`.

> [!example]- Solution
> Écris `~/cka/essai-np-plage.yaml` :
>
> ```yaml
> apiVersion: networking.k8s.io/v1
> kind: NetworkPolicy
> metadata:
>   name: plage-ports
>   namespace: essai-np
> spec:
>   podSelector:
>     matchLabels:
>       app: multi
>   policyTypes:
>   - Ingress
>   ingress:
>   - from:
>     - namespaceSelector:
>         matchLabels:
>           kubernetes.io/metadata.name: boutique
>       podSelector:
>         matchLabels:
>           app: outils
>     ports:
>     - protocol: TCP
>       port: 8080
>       endPort: 8085
> ```
>
> ```bash
> kubectl -n essai-np delete networkpolicy et-ou
> kubectl apply -f ~/cka/essai-np-plage.yaml
> M=$(kubectl -n essai-np get pod multi -o jsonpath='{.status.podIP}')
> for p in 8080 8081 8085 9000; do
>   printf '%s : ' $p
>   kubectl -n boutique exec outils -- curl -s -m 3 http://$M:$p/ || printf 'expiration'
>   echo
> done
> kubectl -n essai-np describe networkpolicy plage-ports | grep 'To Port'
> sed 's/port: 8080/port: http/' ~/cka/essai-np-plage.yaml | kubectl apply -f -
> kubectl delete namespace essai-np
> ```
>
> 8080, 8081 et 8085 sont dans la plage inclusive et répondent `a`, `b` et `c` ; 9000 est hors plage et expire. `describe` affiche `To Port Range: 8080-8085/TCP`. La variante nommée est refusée par le serveur d'API avec le message « may not be specified when `port` is non-numeric » : une plage n'a de sens qu'entre deux numéros. Le namespace `essai-np` et ses pods disparaissent avec la dernière commande.
>
> **Vérification** : `8080 : a`, `8081 : b`, `8085 : c`, puis pour 9000 la ligne `command terminated with exit code 28` de kubectl suivie de `expiration` ; le second `apply` échoue ; `kubectl get ns essai-np` répond `NotFound`. L'état laissé est celui de l'instantané **I2** : les huit NetworkPolicies de `boutique`, sans pod de test.

---
