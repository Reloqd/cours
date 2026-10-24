---
title: "CKA — 10. Services et EndpointSlices"
description: "Les Services ClusterIP, NodePort, LoadBalancer, ExternalName et headless, les EndpointSlices qui les alimentent, les règles iptables réelles de kube-proxy et le mode nftables, MetalLB dans le lab, les politiques de trafic et la dépréciation d'externalIPs."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 10. Services et EndpointSlices

Les adresses des pods changent à chaque recréation ; une application a besoin d'une adresse et d'un nom qui ne changent pas. C'est le rôle du Service. Ce chapitre couvre la compétence *Use ClusterIP, NodePort, LoadBalancer service types and endpoints* et prépare *Troubleshoot services and networking*, que le chapitre 22 met en pratique sur des pannes. Une tâche sur deux du domaine « Services and Networking » touche un Service, sous une forme ou une autre : exposer un Deployment sur un NodePort imposé, réparer un Service sans backend, créer un Service headless pour un StatefulSet, expliquer pourquoi un LoadBalancer reste en `<pending>`. Pour les réussir vite, il faut savoir générer le bon objet en une commande ; pour les réussir à coup sûr, il faut savoir ce qui se passe sous le capot : qui alloue l'adresse, qui calcule les backends, qui réécrit les paquets. Ce chapitre suit cet ordre, puis met en place les Services du fil rouge et l'addon MetalLB du lab.

### 10.1 Ce qu'est un Service

Un Service est un objet de l'API qui associe trois choses : une **adresse virtuelle stable** (la ClusterIP), un **nom DNS** stable (`api.boutique.svc.cluster.local`, chapitre 11.2), et un **ensemble de backends** désignés le plus souvent par un sélecteur de labels. Le Service lui-même ne fait rien : il décrit une intention que quatre composants réalisent.

```
QUI FAIT QUOI POUR UN SERVICE
═════════════════════════════

  kubectl apply (Service api, selector app=api, port 8080)
        │
        ▼
  kube-apiserver ── alloue la ClusterIP 10.110.27.164 dans 10.96.0.0/12
        │           (objet IPAddress, ServiceCIDR « kubernetes »)
        ▼
  controller-manager, contrôleur EndpointSlice
        │  surveille les pods app=api : adresse, nœud, zone, Ready
        ▼
  EndpointSlice api-7xq2c : 10.244.195.201:8080 (ready), 10.244.34.135:8080 (ready)
        │
        ├──▶ kube-proxy (chaque nœud) : règles DNAT 10.110.27.164:8080 → backends
        └──▶ CoreDNS : api.boutique.svc.cluster.local → 10.110.27.164

  Personne n'« écoute » sur 10.110.27.164 : aucune interface ne porte cette
  adresse. Elle n'existe que dans les règles de kube-proxy, sur chaque nœud.
```

Deux conséquences surprennent la première fois. Un `ping` vers une ClusterIP ne reçoit pas de réponse : kube-proxy ne traduit que les ports déclarés du Service, et ICMP n'en fait pas partie. Et le trafic est réparti **par connexion**, pas par requête : une connexion TCP longue (HTTP/2, gRPC, une connexion de base de données) reste sur le même pod pendant toute sa vie.

### 10.2 Anatomie d'un Service

Voici le Service `api` du fil rouge, dans sa forme définitive (exercice 10.1) :

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api
  namespace: boutique
  labels:
    app: api
    tier: api
spec:
  type: ClusterIP           # défaut ; NodePort, LoadBalancer ou ExternalName
  selector:
    app: api                # les pods backends : égalité de labels seulement
  ports:
  - name: http              # nom du port de Service (obligatoire s'il y a plusieurs ports)
    port: 8080              # port de la ClusterIP
    protocol: TCP           # défaut ; UDP et SCTP possibles
    targetPort: http        # port du pod : un numéro, ou le NOM d'un containerPort
```

Le sélecteur d'un Service n'accepte que l'égalité (`matchLabels` implicite) : pas d'expressions `In` ou `NotIn`, contrairement à un Deployment. Il doit correspondre aux labels des **pods**, pas à ceux du Deployment : c'est l'erreur la plus fréquente à l'examen (panne 04 du chapitre 22).

`targetPort` mérite une attention particulière. Avec un numéro, il désigne ce port sur chaque pod. Avec un **nom**, il désigne le `containerPort` qui porte ce nom dans chaque pod : le Deployment `api` déclare `containerPort: 8080` nommé `http`, le Service y renvoie par le nom. Le jour où l'application passe sur un autre port, on modifie le pod et pas le Service ; on peut même avoir, pendant une mise à jour, des pods sur l'ancien et le nouveau numéro derrière le même Service. Omis, `targetPort` prend la valeur de `port`.

Le nom du port de Service (`name: http`) a trois usages : il est obligatoire dès que le Service a plusieurs ports ; il sert de clé aux enregistrements DNS SRV (`_http._tcp.api.boutique.svc.cluster.local`, chapitre 11.2), qui n'existent que pour les ports nommés ; et il apparaît dans les commentaires des règles de kube-proxy. Un nom de port suit la syntaxe des labels DNS : minuscules, chiffres et tirets, commençant et finissant par un caractère alphanumérique, 15 caractères au plus pour un `containerPort`.

Les autres champs utiles, avec leur valeur par défaut :

| Champ | Défaut | Rôle |
|---|---|---|
| `spec.clusterIP` / `clusterIPs` | alloué par l'API server | adresse virtuelle ; `None` pour un Service headless ; immuable une fois attribuée |
| `spec.ipFamilyPolicy` | `SingleStack` | `PreferDualStack`, `RequireDualStack` sur un cluster double pile |
| `spec.sessionAffinity` | `None` | `ClientIP` : un client reste sur le même pod (10.10) |
| `spec.externalTrafficPolicy` | `Cluster` (NodePort, LoadBalancer) | `Local` : seulement les pods du nœud qui reçoit, IP source conservée |
| `spec.internalTrafficPolicy` | `Cluster` | `Local` : trafic interne vers les seuls pods du nœud du client |
| `spec.trafficDistribution` | absent | préférence de proximité : `PreferSameZone`, `PreferSameNode` (10.10) |
| `spec.publishNotReadyAddresses` | `false` | publier aussi les pods non prêts (DNS des StatefulSets en démarrage) |
| `spec.allocateLoadBalancerNodePorts` | `true` | LoadBalancer sans NodePort (10.8) |

#### Générer un Service vite

Deux commandes impératives existent. Elles ne se valent pas.

`kubectl expose` part d'un objet existant (Deployment, ReplicaSet, pod, Service) et **reprend son sélecteur** et ses labels. Sans `--target-port`, le `targetPort` vaut `--port` ; le port n'a pas de nom ; `--type` et `--name` choisissent le type et le nom.

```bash
kubectl -n boutique expose deployment api --port=8080 --target-port=http --dry-run=client -o yaml
kubectl -n boutique expose deployment front --name=front-lb --type=LoadBalancer --port=80
```

`kubectl create service <type> <nom>` construit un Service ex nihilo avec un sélecteur **`app=<nom>`**, que le nom corresponde à tes pods ou non, et des ports nommés d'après leurs numéros (`--tcp=80:8080` donne un port nommé `80-8080`).

```bash
kubectl -n boutique create service nodeport catalogue-np --tcp=8080:8080 --node-port=30090 --dry-run=client -o yaml
kubectl -n boutique create service externalname meteo --external-name example.com --dry-run=client -o yaml
kubectl -n boutique create service clusterip api-pods --clusterip=None --tcp=8080:8080 --dry-run=client -o yaml
```

> [!tip] Réflexe d'examen
> Pour exposer un Deployment existant, `kubectl expose` a toujours raison sur le sélecteur. Pour un NodePort imposé, `expose` n'a pas d'option `--node-port` : génère avec `--dry-run=client -o yaml`, ajoute `nodePort:` dans le fichier, puis applique. Après `kubectl create service`, vérifie le sélecteur (`kubectl get svc -o wide`, colonne `SELECTOR`). Les champs se retrouvent avec `kubectl explain service.spec.ports` ; la page de documentation est *Service* (*Concepts › Services, Load Balancing, and Networking*).

#### Variables d'environnement

Le kubelet injecte dans chaque conteneur, pour chaque Service **existant au moment où le pod démarre** dans son namespace, des variables `<NOM>_SERVICE_HOST` et `<NOM>_SERVICE_PORT` (nom en majuscules, tirets remplacés par des soulignés), plus des variables de compatibilité `<NOM>_PORT_…` héritées des liens Docker. Un pod créé avant le Service ne les a pas. Le DNS n'a pas ce défaut d'ordre et reste la méthode à privilégier ; `enableServiceLinks: false` dans la spécification du pod supprime ces variables quand un namespace en compte des centaines.

### 10.3 ClusterIP : l'adresse virtuelle

#### Allocation

L'API server alloue la ClusterIP dans la plage `--service-cluster-ip-range` (`10.96.0.0/12` dans le lab comme sous kubeadm par défaut). Depuis Kubernetes 1.33, où `MultiCIDRServiceAllocator` est GA, cette allocation est visible dans l'API : chaque adresse attribuée est un objet **IPAddress**, et chaque plage un objet **ServiceCIDR** (`networking.k8s.io/v1`). Le ServiceCIDR `kubernetes` est créé au démarrage à partir de l'option de l'API server ; un administrateur peut en ajouter d'autres pour agrandir l'espace sans redémarrer quoi que ce soit.

```bash
kubectl get servicecidrs
kubectl get ipaddresses | grep -E 'NAME|boutique/'
```

```
NAME         CIDRS          AGE
kubernetes   10.96.0.0/12   3d

NAME            PARENTREF
10.104.63.218   services/boutique/front
10.110.27.164   services/boutique/api
```

La plage est découpée en deux bandes. La taille de la bande basse vaut `min(max(16, taille/16), 256)` adresses : pour un /12 (1 048 576 adresses), 256. L'allocation **dynamique** pioche en priorité dans la bande haute ; la bande basse (`10.96.0.0` à `10.96.0.255` dans le lab) est réservée de fait aux adresses **choisies** à la main. C'est pourquoi `kubernetes` (`10.96.0.1`) et `kube-dns` (`10.96.0.10`) vivent dans la bande basse, et pourquoi, si tu dois imposer une ClusterIP (`spec.clusterIP: 10.96.0.50`), tu la prends là : aucun Service créé dynamiquement ne te l'aura volée.

Une ClusterIP est **immuable**. Pour en changer, il faut supprimer et recréer le Service (sauf passage vers ou depuis `ExternalName`, qui n'en a pas). Les clients qui utilisent le nom DNS ne s'en aperçoivent pas ; ceux qui ont écrit l'adresse en dur, si.

#### Le Service `kubernetes`

Le namespace `default` contient un Service particulier, `kubernetes`, dont l'adresse est la première de la plage. Ses backends sont les API servers, maintenus par l'API server lui-même et non par un sélecteur. C'est par lui que les pods joignent l'API (`https://kubernetes.default.svc`). Dans le lab, son port 443 mène au port **8443** du nœud `cka` ; sur un cluster kubeadm, au port 6443 de chaque control plane.

```bash
kubectl get endpointslices -n default -l kubernetes.io/service-name=kubernetes
```

```
NAME         ADDRESSTYPE   PORTS   ENDPOINTS      AGE
kubernetes   IPv4          8443    192.168.49.2   3d
```

### 10.4 EndpointSlices

#### Le contrôleur et ses objets

Pour chaque Service **doté d'un sélecteur**, le contrôleur EndpointSlice du controller-manager tient à jour un ou plusieurs objets **EndpointSlice** (`discovery.k8s.io/v1`), qui listent les adresses des pods correspondants et leur état. Ce sont ces objets, et non le Service, que kube-proxy et CoreDNS consomment.

```bash
kubectl -n boutique get endpointslices -l kubernetes.io/service-name=api
kubectl -n boutique get endpointslices -l kubernetes.io/service-name=api -o yaml
```

```
NAME        ADDRESSTYPE   PORTS   ENDPOINTS                      AGE
api-7xq2c   IPv4          8080    10.244.195.201,10.244.34.135   3d
```

```yaml
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: api-7xq2c
  namespace: boutique
  labels:
    app: api
    tier: api
    endpointslice.kubernetes.io/managed-by: endpointslice-controller.k8s.io
    kubernetes.io/service-name: api
addressType: IPv4
endpoints:
- addresses:
  - 10.244.195.201
  conditions:
    ready: true
    serving: true
    terminating: false
  nodeName: cka-m02
  targetRef:
    kind: Pod
    name: api-5f8b7c6d9-h2xkp
    namespace: boutique
  zone: zone-b
- addresses:
  - 10.244.34.135
  conditions:
    ready: true
    serving: true
    terminating: false
  nodeName: cka-m03
  targetRef:
    kind: Pod
    name: api-5f8b7c6d9-r8m4t
    namespace: boutique
  zone: zone-b
ports:
- name: http
  port: 8080
  protocol: TCP
```

Plusieurs détails se lisent dans cet objet. Le nom est celui du Service suivi d'un suffixe aléatoire ; le lien avec le Service passe par le label **`kubernetes.io/service-name`**, et c'est ce label qu'on filtre (`-l kubernetes.io/service-name=api`). Le label `endpointslice.kubernetes.io/managed-by` identifie le gestionnaire ; le contrôleur ne touche qu'aux tranches qui portent sa valeur, `endpointslice-controller.k8s.io`. Le port nommé `http` du Service y est résolu en numéro (`8080`) : si des pods déclaraient `http` sur des numéros différents, ils seraient rangés dans des tranches distinctes. Le champ `zone` vient du label `topology.kubernetes.io/zone` du nœud, posé au chapitre 8.3. Une tranche contient au plus 100 points d'accès par défaut (option `--max-endpoints-per-slice` du controller-manager, 1000 au maximum) ; au-delà, le contrôleur en crée une autre, et un client doit toujours agréger toutes les tranches d'un Service.

#### Les trois conditions

Chaque point d'accès porte trois conditions, qui pilotent le trafic :

| Condition | Signification pour un pod | Effet |
|---|---|---|
| `serving` | la condition `Ready` du pod est vraie | peut servir du trafic |
| `terminating` | le pod a reçu une date de suppression | en cours d'arrêt |
| `ready` | `serving` et pas `terminating` (toujours vrai si `publishNotReadyAddresses: true`) | **le seul critère des proxys en temps normal** |

C'est par là que la **sonde de disponibilité** (*readinessProbe*) agit sur le trafic : un pod `Running` dont la sonde échoue passe `ready: false`, disparaît des règles de kube-proxy et des réponses DNS d'un Service headless, sans être redémarré (panne 09 du chapitre 22). Pendant un déploiement progressif, un pod en arrêt passe `ready: false`, `serving: true`, `terminating: true` : les proxys cessent de lui envoyer de nouvelles connexions, mais peuvent encore l'utiliser si **tous** les points d'accès restants sont en arrêt, pour ne pas perdre de trafic.

#### Endpoints, l'ancienne API, est dépréciée

L'API `Endpoints` (`v1`, un seul objet par Service portant le nom du Service) est **dépréciée depuis Kubernetes 1.33**. Elle reste servie et continue d'être remplie, mais elle ne gère ni la double pile ni les informations de topologie, et elle tronque la liste au-delà de 1000 adresses. Toute lecture déclenche un avertissement :

```bash
kubectl -n boutique get endpoints api
```

```
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME   ENDPOINTS                                 AGE
api    10.244.195.201:8080,10.244.34.135:8080    3d
```

`kubectl describe service` affiche lui aussi une ligne `Endpoints:`, calculée à partir des EndpointSlices. C'est la commande la plus rapide pour répondre à « ce Service a-t-il des backends ? » :

```bash
kubectl -n boutique describe service api
```

```
Name:                     api
Namespace:                boutique
Labels:                   app=api
                          tier=api
Annotations:              <none>
Selector:                 app=api
Type:                     ClusterIP
IP Family Policy:         SingleStack
IP Families:              IPv4
IP:                       10.110.27.164
IPs:                      10.110.27.164
Port:                     http  8080/TCP
TargetPort:               http/TCP
Endpoints:                10.244.195.201:8080,10.244.34.135:8080
Session Affinity:         None
Internal Traffic Policy:  Cluster
Events:                   <none>
```

Une ligne `Endpoints:` vide est le symptôme le plus fréquent d'un Service cassé : sélecteur qui ne correspond à aucun pod, pods non prêts, ou `targetPort` nommé que les pods ne déclarent pas.

#### Un Service sans sélecteur

Un Service **sans** `selector` n'a pas de tranche automatique : c'est toi qui fournis les backends, par une EndpointSlice écrite à la main. C'est ainsi qu'on donne un nom de Service à une base de données hors du cluster, ou qu'on migre une application par morceaux.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: externe
  namespace: boutique
spec:
  ports:
  - name: http
    port: 80
    protocol: TCP
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: externe-1                                 # par convention, le nom du Service en préfixe
  namespace: boutique
  labels:
    kubernetes.io/service-name: externe           # le lien avec le Service : obligatoire
    endpointslice.kubernetes.io/managed-by: staff # tout sauf la valeur du contrôleur
addressType: IPv4
ports:
- name: http                                      # même nom que le port du Service
  port: 80
  protocol: TCP
endpoints:
- addresses:
  - 192.0.2.10                                    # adresse de démonstration (RFC 5737)
```

Quatre règles s'appliquent. Le label `kubernetes.io/service-name` est indispensable : sans lui, la tranche n'est reliée à rien. Le nom du port de la tranche doit correspondre à celui du port du Service. Une condition `ready` absente vaut `true`. Les adresses ne peuvent être ni des adresses de boucle locale (`127.0.0.0/8`), ni des adresses de lien local (`169.254.0.0/16`, `224.0.0.0/24`), ni la ClusterIP d'un autre Service. Enfin, `kubectl port-forward` refuse un Service sans sélecteur (`error: cannot attach to *v1.Service: invalid service 'externe': Service is defined without a selector`) : il ne sait transférer que vers un pod.

Le *mirroring* d'objets `Endpoints` écrits à la main vers des EndpointSlices existe encore, mais il est déprécié avec le reste de l'API : écris directement des EndpointSlices.

### 10.5 kube-proxy en mode iptables

#### Le principe

kube-proxy tourne en DaemonSet dans `kube-system`, en `hostNetwork`, un pod par nœud. Il surveille les Services et les EndpointSlices et programme le noyau du nœud. En mode `iptables`, le mode par défaut sous Linux et celui du lab, il écrit des chaînes dans les tables `nat` et `filter`. Le choix d'un backend se fait **une fois par connexion**, à l'aide du module `statistic` en mode aléatoire ; le module `conntrack` du noyau mémorise ensuite la traduction, et tous les paquets suivants de la connexion la suivent sans repasser par les règles.

```bash
kubectl -n kube-system get configmap kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode|^clusterCIDR'
```

```
clusterCIDR: 10.244.0.0/16
mode: iptables
```

#### La chaîne de traitement

Suis une connexion d'`outils` vers `api:8080` (la ClusterIP `10.110.27.164`), sur le nœud `cka-m02`. Les noms de chaînes `KUBE-SVC-…` et `KUBE-SEP-…` sont des empreintes (SHA-256 encodé en base32, tronqué à 16 caractères) du nom `namespace/service:port` et du protocole, plus l'adresse du point d'accès pour `KUBE-SEP` : ils sont stables, et identiques sur tous les clusters pour un même Service.

```bash
minikube -p cka ssh -n cka-m02
sudo iptables -t nat -S KUBE-SERVICES | grep 'boutique/'
```

```
-A KUBE-SERVICES -d 10.110.27.164/32 -p tcp -m comment --comment "boutique/api:http cluster IP" -m tcp --dport 8080 -j KUBE-SVC-ETGNB2QTAQD6EL4Q
-A KUBE-SERVICES -d 10.104.63.218/32 -p tcp -m comment --comment "boutique/front cluster IP" -m tcp --dport 80 -j KUBE-SVC-DFX7DWOQ4E3MOCC2
-A KUBE-SERVICES -d 192.168.49.100/32 -p tcp -m comment --comment "boutique/front-lb loadbalancer IP" -m tcp --dport 80 -j KUBE-EXT-5VZBIZ2ZISHLYD7P
…
```

```bash
sudo iptables -t nat -S KUBE-SVC-ETGNB2QTAQD6EL4Q
sudo iptables -t nat -S KUBE-SEP-4SQSYJZWRF7IITGD
```

```
-N KUBE-SVC-ETGNB2QTAQD6EL4Q
-A KUBE-SVC-ETGNB2QTAQD6EL4Q ! -s 10.244.0.0/16 -d 10.110.27.164/32 -p tcp -m comment --comment "boutique/api:http cluster IP" -m tcp --dport 8080 -j KUBE-MARK-MASQ
-A KUBE-SVC-ETGNB2QTAQD6EL4Q -m comment --comment "boutique/api:http -> 10.244.195.201:8080" -m statistic --mode random --probability 0.50000000000 -j KUBE-SEP-ZOGK2NCUBAI55F25
-A KUBE-SVC-ETGNB2QTAQD6EL4Q -m comment --comment "boutique/api:http -> 10.244.34.135:8080" -j KUBE-SEP-4SQSYJZWRF7IITGD

-N KUBE-SEP-4SQSYJZWRF7IITGD
-A KUBE-SEP-4SQSYJZWRF7IITGD -s 10.244.34.135/32 -m comment --comment "boutique/api:http" -j KUBE-MARK-MASQ
-A KUBE-SEP-4SQSYJZWRF7IITGD -p tcp -m comment --comment "boutique/api:http" -m tcp -j DNAT --to-destination 10.244.34.135:8080
```

```
CONNEXION outils → 10.110.27.164:8080, SUR cka-m02
═════════════════════════════════════════════════

  PREROUTING (nat)  ── paquet venu d'un pod (ou OUTPUT pour un processus du nœud)
       │
       ▼
  KUBE-SERVICES     ── une règle par (ClusterIP, port) : « boutique/api:http cluster IP »
       │ -d 10.110.27.164 --dport 8080
       ▼
  KUBE-SVC-ETGNB2QTAQD6EL4Q
       │ 1. source hors 10.244.0.0/16 ? → KUBE-MARK-MASQ (marque 0x4000)
       │ 2. tirage : probabilité 1/2 → KUBE-SEP-ZOGK… (10.244.195.201)
       │ 3. sinon (1/2 restant)       → KUBE-SEP-4SQS… (10.244.34.135)
       ▼
  KUBE-SEP-4SQSYJZWRF7IITGD
       │ 1. source = le pod lui-même (« hairpin ») ? → KUBE-MARK-MASQ
       │ 2. DNAT → 10.244.34.135:8080
       ▼
  routage (chapitre 9.5) : 10.244.34.128/26 via tunl0 → cka-m03
       ▼
  POSTROUTING → KUBE-POSTROUTING : paquet marqué 0x4000 ? → MASQUERADE --random-fully
                                    sinon RETURN (source d'origine conservée)
```

Le tirage mérite un mot. Avec N backends, la première règle a une probabilité de 1/N, la deuxième de 1/(N-1) parmi ce qui reste, et la dernière n'a pas de condition : chaque backend reçoit bien 1/N des connexions. Avec trois pods `front`, les probabilités affichées sont `0.33333333349`, `0.50000000000`, puis rien.

Le marquage `0x4000` décide du masquage de la source. Une connexion de pod à Service garde l'adresse du pod comme source (le backend voit qui l'appelle). Deux cas imposent de la masquer : le trafic qui vient de **hors** du réseau des pods (règle `! -s 10.244.0.0/16`, qui repose sur `clusterCIDR` dans la configuration de kube-proxy), et le cas où un pod s'appelle **lui-même** à travers le Service (sinon la réponse, de pod à pod, court-circuiterait la traduction inverse). Le masquage a lieu en sortie, dans `KUBE-POSTROUTING`.

#### Ce que kube-proxy écrit d'autre

La table `filter` porte les cas sans backend. Un Service dont aucun point d'accès n'est prêt n'a **aucune** règle dans la table `nat` ; à la place, une règle de la chaîne `filter`/`KUBE-SERVICES` rejette activement les connexions :

```
-A KUBE-SERVICES -d 10.110.27.164/32 -p tcp -m comment --comment "boutique/api:http has no endpoints" -m tcp --dport 8080 -j REJECT --reject-with icmp-port-unreachable
```

C'est ce qui distingue, du côté du client, un Service sans backend (**refus immédiat**, `Connection refused`) d'un backend filtré par une NetworkPolicy ou injoignable (**délai d'attente**). Ce simple indice oriente le dépannage.

Pour un NodePort, kube-proxy ajoute une règle dans `KUBE-NODEPORTS`, chaîne appelée en **dernière** position de `KUBE-SERVICES` pour toute destination locale au nœud (`-m addrtype --dst-type LOCAL`), puis une chaîne `KUBE-EXT-…` qui marque le trafic pour le masquage avant de rejoindre la chaîne `KUBE-SVC-…` du Service :

```
-A KUBE-NODEPORTS -d 127.0.0.0/8 -p tcp -m comment --comment "boutique/front" -m tcp --dport 30080 -m nfacct --nfacct-name  localhost_nps_accepted_pkts -j KUBE-EXT-DFX7DWOQ4E3MOCC2
-A KUBE-NODEPORTS -p tcp -m comment --comment "boutique/front" -m tcp --dport 30080 -j KUBE-EXT-DFX7DWOQ4E3MOCC2
-A KUBE-EXT-DFX7DWOQ4E3MOCC2 -m comment --comment "masquerade traffic for boutique/front external destinations" -j KUBE-MARK-MASQ
-A KUBE-EXT-DFX7DWOQ4E3MOCC2 -j KUBE-SVC-DFX7DWOQ4E3MOCC2
```

La première règle traite les connexions adressées à `127.0.0.1` du nœud et se contente de les compter (`nfacct`) avant le même saut : en mode iptables, un NodePort répond aussi sur l'adresse de boucle locale.

Avec `externalTrafficPolicy: Local`, la chaîne `KUBE-EXT-…` saute vers une chaîne `KUBE-SVL-…` qui ne contient que les points d'accès du nœud, et le marquage disparaît (10.10). Avec `sessionAffinity: ClientIP`, chaque chaîne `KUBE-SEP-…` enregistre la source avec le module `recent`, et la chaîne `KUBE-SVC-…` commence par des règles `-m recent --rcheck --seconds 10800 --reap` qui renvoient un client connu vers son pod.

#### Ce qu'il faut en retenir pour le dépannage

Les règles vivent dans le noyau de chaque nœud. Si kube-proxy s'arrête, elles **restent en place** : les Services existants continuent de marcher, mais aucun changement (nouveau Service, pod remplacé) n'est plus répercuté. C'est la panne 17 du chapitre 23. Les traductions déjà établies vivent dans la table conntrack : une connexion TCP ouverte vers un pod supprimé n'est pas « réparée » par la mise à jour des règles, elle échoue et le client doit se reconnecter. kube-proxy purge lui-même les entrées UDP des backends disparus, sans quoi un client DNS resterait collé à un pod CoreDNS mort.

> [!info] minikube ≠ examen
> Le lab et un cluster kubeadm 1.37 installé sans réglage particulier tournent tous deux en mode `iptables`, explicitement écrit dans la ConfigMap `kube-system/kube-proxy` (kubeadm 1.37 pose `mode: iptables` quand le champ est vide). Le lab kubeadm du chapitre 19, lui, est configuré en `nftables` : sur ce cluster, `iptables -t nat -S` ne montre rien des Services.

### 10.6 Les autres modes : nftables et ipvs

Le mode **nftables** est GA depuis Kubernetes 1.33. Il exige un noyau 5.13 ou plus récent. Il remplace les chaînes linéaires d'iptables par des **maps** nftables, consultées en temps constant : là où iptables parcourt une règle par Service jusqu'à trouver la bonne, nftables fait une seule recherche dans une table de hachage. Les mises à jour sont aussi plus rapides, ce qui compte au-delà de quelques milliers de Services. Le projet annonce que le mode par défaut passera un jour à `nftables` ; en 1.37, il reste `iptables`, et la documentation recommande d'écrire le mode explicitement pour qu'une mise à jour ne le change pas à ton insu.

Tout vit dans une seule table, `ip kube-proxy` (et `ip6 kube-proxy`). La map `service-ips` associe chaque triplet (adresse, protocole, port) à la chaîne de son Service ; la chaîne du Service tire un backend avec `numgen random` et fait la traduction en une instruction. Voici ce que montrerait, pour le même Service `api`, un nœud dont kube-proxy tourne en mode `nftables` (le lab minikube est en `iptables` : ces commandes n'y renvoient rien) :

```bash
sudo nft list map ip kube-proxy service-ips
sudo nft list chain ip kube-proxy service-4ZJIZ325-boutique/api/tcp/http
```

```
table ip kube-proxy {
	map service-ips {
		type ipv4_addr . inet_proto . inet_service : verdict
		comment "ClusterIP, ExternalIP and LoadBalancer IP traffic"
		elements = { 10.110.27.164 . tcp . 8080 : goto service-4ZJIZ325-boutique/api/tcp/http, … }
	}
}
table ip kube-proxy {
	chain service-4ZJIZ325-boutique/api/tcp/http {
		meta l4proto tcp dnat ip addr . port to numgen random mod 2 map { 0 : 10.244.195.201 . 8080, 1 : 10.244.34.135 . 8080 }
	}
}
```

(Extrait réduit aux règles utiles. Sans affinité de session, kube-proxy 1.37 n'écrit plus de chaîne par point d'accès : la traduction se fait directement dans la chaîne du Service. Les chaînes `endpoint-…` n'apparaissent qu'avec `sessionAffinity: ClientIP`.)

Le passage d'iptables à nftables change quelques comportements, que la documentation détaille dans *Virtual IPs and Service Proxies* : en nftables, les NodePorts ne répondent par défaut que sur l'adresse **principale** du nœud (`--nodeport-addresses primary`, contre toutes les adresses en iptables), ne répondent pas sur `127.0.0.1` sauf configuration explicite, et kube-proxy n'ajoute plus de règles d'acceptation pour traverser un pare-feu local. Pour changer de mode, on modifie `mode:` dans la ConfigMap `kube-proxy`, puis on redémarre le DaemonSet (`kubectl -n kube-system rollout restart daemonset kube-proxy`) ; une valeur invalide fait échouer kube-proxy au démarrage (panne 17).

Le mode **ipvs** est **déprécié depuis 1.35** : kube-proxy affiche un avertissement au démarrage. Le calendrier annoncé le désactive par défaut en 1.40 (réactivable par la feature gate `KubeProxyIPVS`) et le supprime en 1.43. Il n'a jamais su implémenter correctement tous les cas limites de l'API Service ; nftables le remplace.

### 10.7 NodePort

Un Service `NodePort` est un ClusterIP auquel s'ajoute un **port ouvert sur chaque nœud**. Tout paquet qui arrive sur ce port, sur n'importe quel nœud, est envoyé vers un backend, quel que soit le nœud qui l'héberge.

La plage vient de l'option `--service-node-port-range` de l'API server : **30000-32767** par défaut, comme dans le lab. Elle est elle aussi découpée en deux bandes : pour la plage par défaut, la bande **statique** couvre **30000-30085** et la bande **dynamique** 30086-32767. L'allocation automatique puise dans la bande dynamique tant qu'elle n'est pas épuisée ; un port choisi à la main a donc moins de risques d'être déjà pris s'il est dans la bande statique. Le `30080` du fil rouge y est. Un port demandé hors plage est refusé (`provided port is not in the valid range. The range of valid ports is 30000-32767`), un port déjà alloué aussi (`provided port is already allocated`).

En mode iptables, le NodePort répond sur **toutes** les adresses locales du nœud. Le trafic entrant est masqué (`KUBE-EXT-…`) : le pod voit pour source une adresse du nœud qui a reçu la connexion. Avec Calico en IPIP, c'est l'adresse du tunnel `tunl0` de ce nœud (`10.244.142.64` pour `cka`), que le pod tourne sur un autre nœud ou sur celui-là : les interfaces `cali*` n'ont pas d'adresse, et le noyau choisit celle de `tunl0` comme source (9.5). C'est le prix de la répartition entre nœuds ; `externalTrafficPolicy: Local` l'évite (10.10).

```bash
curl -s http://192.168.49.2:30080/
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.49.4:30080/
```

```
<h1>Boutique</h1><p>v1</p>
200
```

Le NodePort n'est pas un mécanisme d'exposition final : un client devrait connaître l'adresse d'un nœud vivant et un port non standard. Il sert de brique aux LoadBalancers, aux contrôleurs d'Ingress exposés par NodePort (celui de l'addon minikube, chapitre 12.11) et aux tests.

### 10.8 LoadBalancer et MetalLB

#### Le contrat

Un Service `LoadBalancer` est un NodePort auquel s'ajoute une demande : « qu'un répartiteur externe me donne une adresse ». Kubernetes ne fournit pas ce répartiteur. Sur un cloud, le *cloud-controller-manager* crée un répartiteur du fournisseur qui envoie le trafic vers les NodePorts, puis écrit l'adresse obtenue dans `status.loadBalancer.ingress`. Sans implémentation, rien ne se passe et la colonne `EXTERNAL-IP` reste **`<pending>` indéfiniment** : ce n'est pas une panne du Service, c'est l'absence d'un composant. C'est la situation de la plupart des clusters d'examen.

Quelques champs complètent le tableau. `spec.allocateLoadBalancerNodePorts: false` supprime l'allocation des NodePorts, pour les implémentations qui envoient le trafic directement aux pods. `spec.loadBalancerClass` désigne une implémentation précise ; il ne peut plus changer une fois posé. `spec.loadBalancerIP` est **déprécié depuis 1.24** : son sens variait selon les fournisseurs ; les implémentations proposent des annotations à la place. Enfin `status.loadBalancer.ingress[].ipMode` (`VIP` par défaut, ou `Proxy`) indique si le trafic arrive au nœud avec l'adresse du répartiteur pour destination.

kube-proxy connaît l'adresse externe : il installe une règle `loadbalancer IP` dans `KUBE-SERVICES` (10.5). Un pod du cluster qui appelle `192.168.49.100` est donc traduit directement sur son nœud, sans sortir vers le répartiteur.

#### MetalLB dans le lab

MetalLB est une implémentation de LoadBalancer pour les clusters sans cloud. En **mode L2**, celui du lab, un des pods `speaker` (un par nœud) est élu pour chaque adresse et répond aux requêtes ARP qui la concernent : le trafic destiné à `192.168.49.100` arrive donc sur ce nœud, où kube-proxy le traduit vers un backend. Il n'y a pas de répartition entre nœuds au niveau du réseau : la répartition se fait ensuite, par kube-proxy. Si le nœud élu tombe, un autre `speaker` reprend l'adresse et l'annonce par ARP gratuit.

L'addon `metallb` de minikube v1.39.0 installe **MetalLB v0.9.6** dans le namespace `metallb-system` (Deployment `controller`, DaemonSet `speaker`). Cette version ancienne se configure par une **ConfigMap** `metallb-system/config`, clé `config`, dont le contenu est lui-même un document YAML :

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: config
  namespace: metallb-system
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - 192.168.49.100-192.168.49.120
```

La plage doit appartenir au réseau des nœuds (`192.168.49.0/24`) sans toucher à la passerelle (`.1`) ni aux nœuds (`.2` à `.4`, une adresse de plus par nœud ajouté). Juste après `minikube -p cka addons enable metallb`, la ConfigMap existe mais sa plage est vide (`- -`) : aucun Service n'obtient d'adresse. Deux gestes la remplissent, et le lab a besoin des deux. `kubectl apply` de la ConfigMap est le geste Kubernetes ordinaire, valable sur n'importe quel cluster ; mais minikube garde sa propre copie de la plage dans le profil (`LoadBalancerStartIP` et `LoadBalancerEndIP` de `profiles/cka/config.json`) et, à chaque `minikube start`, réapplique la ConfigMap de l'addon avec cette copie : vide, elle écrase ta plage. La commande `minikube -p cka addons configure metallb` enregistre la plage dans le profil, puis réapplique l'addon, ce qui remplit aussi la ConfigMap. Elle pose deux questions (début et fin de plage) dans un terminal ; dans un script, on lui fournit les deux réponses par un tube, **avec une pause entre les deux** (minikube lit chaque réponse avec un nouveau lecteur à tampon : sans pause, le premier avale les deux lignes et rien n'est enregistré). L'option `--config-file` de `addons configure` est ignorée pour `metallb`. Le contrôleur MetalLB relit la ConfigMap dès qu'elle change et attribue une adresse aux Services en attente.

```
AFFECTATION D'UNE ADRESSE PAR METALLB (MODE L2)
═══════════════════════════════════════════════

  Service front-lb (type LoadBalancer) créé
       │
       ▼
  metallb controller ── prend 192.168.49.100 dans la plage
       │                écrit status.loadBalancer.ingress[0].ip
       │                événement IPAllocated « Assigned IP "192.168.49.100" »
       ▼
  speakers ── élisent un nœud pour cette adresse, ex. cka-m03
       │       événement nodeAssigned « announcing from node "cka-m03" »
       ▼
  ton poste (192.168.49.1) : ARP « qui a 192.168.49.100 ? »
       │       réponse du speaker de cka-m03 avec la MAC de cka-m03
       ▼
  paquet vers cka-m03 ── kube-proxy : KUBE-SERVICES « loadbalancer IP »
                         → KUBE-EXT → KUBE-SVC → un pod front (sur n'importe quel nœud)
```

> [!warning] MetalLB moderne se configure par CRD
> Depuis la version 0.13, MetalLB ne lit plus de ConfigMap : la plage est un objet **IPAddressPool** et l'annonce L2 un objet **L2Advertisement** (`metallb.io/v1beta1`, MetalLB v0.16 au moment de la rédaction). Ce que tu configures sur le lab ne s'écrit donc pas ainsi sur une installation récente. L'équivalent moderne de la ConfigMap ci-dessus est :
>
> ```yaml
> apiVersion: metallb.io/v1beta1
> kind: IPAddressPool
> metadata:
>   name: lab
>   namespace: metallb-system
> spec:
>   addresses:
>   - 192.168.49.100-192.168.49.120
> ---
> apiVersion: metallb.io/v1beta1
> kind: L2Advertisement
> metadata:
>   name: lab
>   namespace: metallb-system
> spec:
>   ipAddressPools:
>   - lab
> ```

> [!info] minikube ≠ examen
> Le lab a un LoadBalancer fonctionnel grâce à MetalLB, et ton poste, branché sur le même réseau Docker, joint directement les adresses `192.168.49.100` et suivantes : `minikube tunnel` est inutile. Un cluster d'examen n'a en général aucune implémentation : un Service LoadBalancer y reste `<pending>`, et on le teste par son NodePort. Autre particularité du lab : à chaque `minikube start`, minikube réapplique les manifestes des addons qu'il croit activés, dont la ConfigMap de MetalLB **rendue avec la plage mémorisée dans le profil**, vide si tu n'es pas passé par `addons configure`. Une plage posée seulement par `kubectl apply` disparaît donc au premier redémarrage : la ConfigMap revient à `- -`, le contrôleur journalise `not processing, still waiting for config`, et `front-lb` garde son `EXTERNAL-IP` affichée mais ne répond plus. D'où les deux gestes de l'exercice 10.4.

### 10.9 ExternalName et Services headless

#### ExternalName : un alias DNS

Un Service `ExternalName` n'a ni ClusterIP, ni sélecteur, ni règle kube-proxy. Il ne fait qu'une chose : CoreDNS répond à son nom par un enregistrement **CNAME** vers `spec.externalName`.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: meteo
  namespace: boutique
spec:
  type: ExternalName
  externalName: example.com
```

Un pod qui résout `meteo` obtient `example.com`, puis l'adresse de `example.com`. L'intérêt est l'indirection : le jour où le service météo est hébergé dans le cluster, on change le type du Service et les clients ne bougent pas. Deux pièges l'accompagnent. Pour HTTP et TLS, le client parle à `meteo` mais le serveur s'appelle `example.com` : l'en-tête `Host:` et le nom attendu dans le certificat ne correspondent pas, ce qui produit des 404 ou des erreurs TLS. Et `externalName` attend un **nom** : une chaîne qui ressemble à une adresse IPv4 est acceptée par l'API mais traitée comme un nom fait de chiffres, que les serveurs DNS ne résolvent pas. Pour pointer une adresse IP, on utilise un Service sans sélecteur et une EndpointSlice (10.4).

#### Headless : pas d'adresse virtuelle

Un Service **headless** se déclare avec `clusterIP: None` (la chaîne `None`, à ne pas confondre avec un champ absent). Il n'a pas d'adresse virtuelle, kube-proxy l'ignore totalement, et il n'y a donc aucune répartition par le cluster. Son seul effet est DNS : son nom résout directement vers les adresses des pods **prêts**, un enregistrement A par pod, et chaque pod obtient un nom propre sous le domaine du Service (chapitre 11.2).

```yaml
apiVersion: v1
kind: Service
metadata:
  name: api-pods
  namespace: boutique
  labels:
    app: api
    tier: api
spec:
  clusterIP: None
  selector:
    app: api
  ports:
  - name: http
    port: 8080
    protocol: TCP
    targetPort: http
```

On l'utilise quand le client veut choisir lui-même son backend (bases de données répliquées, découverte de pairs), et surtout pour les **StatefulSets** : `spec.serviceName` d'un StatefulSet désigne un Service headless qui donne à chaque pod un nom stable, `redis-0.redis.boutique.svc.cluster.local` au chapitre 15. Les EndpointSlices d'un Service headless portent le label `service.kubernetes.io/headless`. Un Service headless **sans** sélecteur est possible ; son port doit alors être égal à son `targetPort`. Les champs `sessionAffinity`, `externalIPs` et `loadBalancerIP` y sont ignorés, avec un avertissement de l'API.

### 10.10 Politiques de trafic

#### externalTrafficPolicy

Ce champ s'applique au trafic qui entre par un NodePort, une adresse de LoadBalancer ou une adresse externe.

| | `Cluster` (défaut) | `Local` |
|---|---|---|
| Backends possibles | tous les pods prêts du cluster | seulement les pods prêts **du nœud qui reçoit** |
| Source vue par le pod | masquée (adresse du nœud d'entrée ; avec Calico IPIP, celle de son tunnel) | **adresse réelle du client** |
| Nœud sans pod local | relaie vers un autre nœud | **jette** le trafic (règle `has no local endpoints`) |
| Répartition | uniforme entre pods | uniforme entre nœuds, pas entre pods |

`Local` sert quand l'application doit connaître l'adresse de ses clients (journaux, filtrage, limitation de débit) et pour éviter un saut réseau. Il impose qu'un répartiteur externe n'envoie le trafic qu'aux nœuds qui ont un pod : pour un Service LoadBalancer en `Local`, l'API alloue un **`healthCheckNodePort`**, sur lequel kube-proxy répond 200 seulement s'il a un pod local, et que les répartiteurs de cloud sondent. En mode L2, MetalLB n'annonce l'adresse que depuis un nœud qui héberge un pod prêt.

#### internalTrafficPolicy

Le pendant pour le trafic **interne** (vers la ClusterIP). `Local` restreint chaque client aux pods de son propre nœud, et le trafic est jeté s'il n'y en a pas. Typiquement : un DaemonSet d'agent (journaux, métriques) que les pods de chaque nœud doivent joindre localement.

#### sessionAffinity

`sessionAffinity: ClientIP` renvoie toutes les connexions d'une même adresse source vers le même pod, pendant `sessionAffinityConfig.clientIP.timeoutSeconds` secondes (**10800** par défaut, soit 3 heures, 86400 au maximum) après la dernière activité. L'affinité porte sur l'adresse **vue par kube-proxy** : derrière un NAT ou un proxy, tous les clients partagent une adresse et tombent sur le même pod. C'est un pis-aller pour les applications qui gardent un état en mémoire ; une session partagée (Redis, base) vaut mieux.

#### trafficDistribution

`spec.trafficDistribution` exprime une **préférence** de proximité, pas une contrainte. Le champ est GA depuis 1.33 ; en 1.37 il accepte :

| Valeur | Statut en 1.37 | Comportement |
|---|---|---|
| `PreferSameZone` | GA depuis 1.35 | les clients d'une zone utilisent les pods de leur zone s'il y en a ; sinon, tout le cluster |
| `PreferSameNode` | GA depuis 1.35 | les pods du nœud du client d'abord, puis ceux de sa zone, puis tout le cluster |
| `PreferClose` | déprécié (alias de `PreferSameZone`) | l'API accepte la valeur avec l'avertissement `spec.trafficDistribution: "PreferClose" is deprecated; use "PreferSameZone"` |

Le mécanisme passe par les EndpointSlices : le contrôleur ajoute à chaque point d'accès des indices (`hints.forZones`, `hints.forNodes`), que kube-proxy utilise pour filtrer les backends. Sans le champ, la répartition est uniforme. Une politique `Local` l'emporte sur `trafficDistribution` pour le type de trafic qu'elle concerne. La préférence ne tient pas compte de la charge : si une zone a beaucoup de clients et un seul pod, ce pod sature ; d'où l'intérêt des topologySpreadConstraints du chapitre 8.6, que `front` utilise justement sur la zone. L'annotation plus ancienne `service.kubernetes.io/topology-mode: Auto` poursuit le même but avec une heuristique proportionnelle au CPU des zones ; si elle est présente, elle prime sur le champ.

### 10.11 externalIPs, un champ déprécié

`spec.externalIPs` liste des adresses sur lesquelles kube-proxy accepte aussi le trafic du Service, sans qu'aucun contrôleur ne vérifie qu'elles appartiennent à quelqu'un. N'importe quel utilisateur autorisé à créer un Service pouvait ainsi détourner le trafic d'une adresse quelconque (CVE-2020-8554). Le champ est **déprécié depuis Kubernetes 1.36** ; l'API répond à toute création ou modification qui l'utilise par l'avertissement :

```
Warning: spec.externalIPs is deprecated and may no longer be implemented in some clusters
```

Le calendrier annoncé prévoit que kube-proxy cesse de l'implémenter par défaut à partir de 1.40 au plus tôt, avec une option pour le réactiver, puis l'abandon complet vers 1.43 au plus tôt. Le contrôleur d'admission `DenyServiceExternalIPs` permet de l'interdire dès maintenant. Les remplaçants sont un LoadBalancer géré par un contrôleur qui contrôle ses plages (MetalLB), ou un Gateway (chapitre 13). Ne confonds pas ce champ avec la colonne `EXTERNAL-IP` de `kubectl get svc`, qui affiche aussi l'adresse d'un LoadBalancer, ni avec les adresses `ExternalIP` d'un nœud : seule la première est dépréciée.

### 10.12 kubectl port-forward

`kubectl port-forward` ouvre un port sur ton poste et le relie, à travers l'API server et le kubelet, à un port d'**un** pod. Avec `svc/front`, kubectl choisit un pod parmi ceux du sélecteur et traduit le `targetPort` ; le trafic ne passe ni par la ClusterIP ni par kube-proxy, il n'y a aucune répartition, et la session s'arrête si ce pod disparaît. Par défaut, l'écoute se fait sur `localhost` seulement ; `--address 0.0.0.0` l'ouvre à toutes les adresses du poste.

```bash
kubectl -n boutique port-forward svc/front 8080:80
```

```
Forwarding from 127.0.0.1:8080 -> 80
Forwarding from [::1]:8080 -> 80
```

C'est l'outil de test idéal quand rien n'est exposé, et le moyen de joindre une interface d'administration sans l'exposer. Comme il exige un sélecteur, il ne fonctionne pas avec un Service sans sélecteur (10.4).

### 10.13 Dépanner un Service

Un Service ne marche pas : procède dans cet ordre, chaque étape éliminant une famille de causes. Le chapitre 22 l'applique aux pannes 04 et 05.

```
MÉTHODE : UN SERVICE QUI NE RÉPOND PAS
══════════════════════════════════════

  1. Le Service existe-t-il, dans le bon namespace, avec le bon port ?
       kubectl -n NS get svc NOM -o wide        (colonne SELECTOR)
  2. A-t-il des backends ?
       kubectl -n NS describe svc NOM           (ligne Endpoints)
       vide → sélecteur ≠ labels des pods ?     kubectl -n NS get pods -l <sélecteur>
            → pods non prêts ?                  kubectl -n NS get pods (READY 0/1)
            → targetPort nommé inconnu des pods ?
  3. Le pod répond-il directement, sans le Service ?
       kubectl -n NS exec outils -- curl -s -m 3 http://<IP du pod>:<port>/
       non → l'application, son port d'écoute, une NetworkPolicy (chapitre 14)
  4. Le Service répond-il par son adresse ?
       curl http://<ClusterIP>:<port>/
       « Connection refused » immédiat → aucun backend prêt, ou targetPort faux
       délai d'attente → réseau, NetworkPolicy, kube-proxy
  5. Par son nom ?
       échec seulement par le nom → DNS (chapitre 11.8)
  6. kube-proxy tourne-t-il sur le nœud du client ?
       kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide
       kubectl -n kube-system logs <pod kube-proxy>
```

| Symptôme | Cause probable |
|---|---|
| `Endpoints:` vide, pods `Running` et prêts | sélecteur du Service différent des labels des pods |
| `Endpoints:` vide, pods `Running` `0/1` | sonde de disponibilité en échec |
| `Endpoints:` rempli, `Connection refused` | `targetPort` qui ne correspond pas au port d'écoute du conteneur |
| `Endpoints:` rempli, délai d'attente | NetworkPolicy, pod qui n'écoute que sur `127.0.0.1`, réseau entre nœuds |
| ClusterIP OK, nom KO | DNS : mauvais namespace dans le nom, CoreDNS |
| NodePort KO sur un nœud précis | `externalTrafficPolicy: Local` sans pod sur ce nœud, ou kube-proxy en panne sur ce nœud |
| LoadBalancer `<pending>` | aucune implémentation (cloud, MetalLB), ou plage MetalLB vide ou épuisée |
| Nouveau Service KO, anciens OK | kube-proxy arrêté : les anciennes règles restent |

### 10.14 Pièges courants

```
Piège 1 : Sélecteur copié du Deployment, pas des pods
═════════════════════════════════════════════════════
  MAUVAIS : selector: {app: api, version: v2} alors que les pods n'ont que app=api
  SYMPTÔME : Endpoints: <vide>, connexion refusée immédiatement.
  BON : kubectl expose (reprend le sélecteur), ou comparer avec
        kubectl get pods --show-labels.

Piège 2 : kubectl create service et son sélecteur implicite
════════════════════════════════════════════════════════════
  MAUVAIS : kubectl create service nodeport web-np --tcp=80:80
            pour des pods app=web
  SYMPTÔME : le Service sélectionne app=web-np : aucun backend.
  BON : kubectl expose deployment web --name=web-np --type=NodePort,
        ou corriger le sélecteur avant d'appliquer.

Piège 3 : Confondre port, targetPort et nodePort
═════════════════════════════════════════════════
  MAUVAIS : targetPort: 30080 « parce que c'est le NodePort »
  SYMPTÔME : Connection refused ; nginx écoute sur 80.
  BON : port = port du Service, targetPort = port du conteneur,
        nodePort = port des nœuds (30000-32767).

Piège 4 : Attendre une EXTERNAL-IP sur un cluster sans implémentation
═════════════════════════════════════════════════════════════════════
  SYMPTÔME : <pending> pour toujours.
  BON : ce n'est pas une erreur du Service ; tester par le NodePort,
        qu'un Service LoadBalancer alloue aussi.

Piège 5 : Lire l'API Endpoints dans un script
══════════════════════════════════════════════
  MAUVAIS : kubectl get endpoints -o jsonpath=…
  SYMPTÔME : Warning: v1 Endpoints is deprecated in v1.33+ ; pas de
             double pile, pas de topologie, troncature à 1000.
  BON : kubectl get endpointslices -l kubernetes.io/service-name=NOM

Piège 6 : Une EndpointSlice manuelle sans le label de service
══════════════════════════════════════════════════════════════
  MAUVAIS : EndpointSlice nommée comme le Service, sans labels
  SYMPTÔME : le Service n'a aucun backend ; le nom ne suffit pas.
  BON : labels kubernetes.io/service-name: <service> et
        endpointslice.kubernetes.io/managed-by: <toi>.

Piège 7 : ExternalName vers une adresse IP
══════════════════════════════════════════
  MAUVAIS : externalName: 192.0.2.10
  SYMPTÔME : le nom ne résout pas.
  BON : Service sans sélecteur + EndpointSlice avec l'adresse.

Piège 8 : Croire que l'affinité ou la répartition se fait par requête
═════════════════════════════════════════════════════════════════════
  SYMPTÔME : un client HTTP/2 ou gRPC charge un seul pod.
  BON : kube-proxy répartit des CONNEXIONS ; répartir des requêtes
        demande un proxy de niveau 7 (Gateway, maillage de services).
```

> [!summary] À retenir
> - Un Service associe une ClusterIP virtuelle stable, un nom DNS et des backends ; l'API server alloue l'adresse (objets IPAddress et ServiceCIDR), le contrôleur EndpointSlice calcule les backends, kube-proxy programme les nœuds, CoreDNS publie le nom.
> - Le sélecteur porte sur les labels des pods, en égalité stricte ; `targetPort` peut être un nom de `containerPort` ; seuls les ports nommés ont des enregistrements SRV.
> - `kubectl expose` reprend le sélecteur de l'objet exposé ; `kubectl create service` impose `app=<nom>`.
> - Les EndpointSlices (`kubernetes.io/service-name`) remplacent l'API Endpoints, dépréciée depuis 1.33 ; seuls les points d'accès `ready` reçoivent du trafic, et la sonde de disponibilité pilote cette condition.
> - En iptables : `KUBE-SERVICES` → `KUBE-SVC-…` (tirage aléatoire) → `KUBE-SEP-…` (DNAT) ; marquage `KUBE-MARK-MASQ`, masquage dans `KUBE-POSTROUTING` ; Service sans backend = `REJECT` immédiat. Les règles survivent à l'arrêt de kube-proxy.
> - nftables est GA depuis 1.33 (noyau ≥ 5.13, NodePorts sur l'adresse principale seulement) ; iptables reste le défaut en 1.37 ; ipvs est déprécié depuis 1.35.
> - NodePort : 30000-32767, bande statique 30000-30085 pour les ports choisis ; LoadBalancer = NodePort + implémentation externe, sinon `<pending>`.
> - MetalLB du lab : v0.9.6, ConfigMap `metallb-system/config`, plage `192.168.49.100-192.168.49.120`, à enregistrer aussi dans le profil (`minikube -p cka addons configure metallb`) pour qu'elle survive à `minikube start` ; MetalLB moderne : CRD IPAddressPool et L2Advertisement.
> - `externalTrafficPolicy: Local` garde l'IP source et jette le trafic des nœuds sans pod ; `trafficDistribution` (`PreferSameZone`, `PreferSameNode`, GA 1.35 ; `PreferClose` déprécié) n'exprime qu'une préférence ; `externalIPs` est déprécié depuis 1.36.

### 10.15 Exercices

Les exercices 10.1 à 10.5 construisent l'état du chapitre ; 10.6 et 10.7 sont temporaires et défont ce qu'ils créent. Garde tes manifestes dans `~/cka/boutique/` et `~/cka/reseau/`.

#### Exercice 10.1 — Finaliser le Service api

**Point de départ** : fin du chapitre 9, ou instantané I1.

Le Service `api` a été créé au chapitre 5 par `kubectl expose`, sans nom de port et avec un `targetPort` numérique. Redéfinis-le de façon déclarative dans `~/cka/boutique/svc-api.yaml` : namespace `boutique`, type ClusterIP, sélecteur `app=api`, labels `app=api` et `tier=api`, un port nommé `http`, port 8080, `targetPort` désignant le port nommé `http` des pods. Vérifie que la ClusterIP n'a pas changé, que l'EndpointSlice liste les pods `api` prêts et que le Service répond depuis `outils`.

> [!example]- Solution
> ```bash
> kubectl -n boutique get svc api -o jsonpath='{.spec.clusterIP}{"\n"}'
> mkdir -p ~/cka/boutique
> cat > ~/cka/boutique/svc-api.yaml <<'EOF'
> apiVersion: v1
> kind: Service
> metadata:
>   name: api
>   namespace: boutique
>   labels:
>     app: api
>     tier: api
> spec:
>   type: ClusterIP
>   selector:
>     app: api
>   ports:
>   - name: http
>     port: 8080
>     protocol: TCP
>     targetPort: http
> EOF
> kubectl apply -f ~/cka/boutique/svc-api.yaml
> ```
>
> Si le Service avait été créé par `kubectl expose`, `kubectl apply` signale l'absence de l'annotation `kubectl.kubernetes.io/last-applied-configuration` et la pose lui-même : c'est un avertissement, pas une erreur. La liste `ports` d'un Service se fusionne sur la clé `port` : l'entrée 8080 existante reçoit le nom et le nouveau `targetPort`, et la ClusterIP, immuable, reste la même.
>
> ```bash
> kubectl -n boutique get svc api -o jsonpath='{.spec.clusterIP} {.spec.ports[0].name} {.spec.ports[0].targetPort}{"\n"}'
> kubectl -n boutique get endpointslices -l kubernetes.io/service-name=api
> kubectl -n boutique exec outils -- curl -s -m 3 http://api:8080/hostname; echo
> ```
>
> Si le `curl` lancé dans la foulée de l'`apply` échoue (`command terminated with exit code 7`, connexion refusée), relance-le : pendant une seconde environ, le port du Service s'appelle déjà `http` alors que l'EndpointSlice décrit encore un port sans nom, et kube-proxy, faute de point d'accès pour ce port, rejette les connexions (10.5).
>
> **Vérification** : la première commande affiche la même adresse qu'avant, suivie de `http http` ; l'EndpointSlice liste autant d'adresses que de pods `api` prêts (2 au repos, avec le HPA du chapitre 7) sur le port `8080` ; `curl` renvoie le nom d'un pod `api-…`.

#### Exercice 10.2 — Exposer front sur le NodePort 30080

**Point de départ** : exercice 10.1.

Passe le Service `front` en type `NodePort`, avec le port de nœud `30080` pour son port 80, dans `~/cka/boutique/svc-front.yaml`. Interroge-le depuis ton poste par l'adresse de chacun des trois nœuds. Essaie ensuite de créer un Service `essai-np` qui demanderait le port de nœud `29999`, et lis le refus.

> [!example]- Solution
> ```bash
> cat > ~/cka/boutique/svc-front.yaml <<'EOF'
> apiVersion: v1
> kind: Service
> metadata:
>   name: front
>   namespace: boutique
>   labels:
>     app: front
>     tier: web
> spec:
>   type: NodePort
>   selector:
>     app: front
>   ports:
>   - port: 80
>     protocol: TCP
>     targetPort: 80
>     nodePort: 30080
> EOF
> kubectl apply -f ~/cka/boutique/svc-front.yaml
> kubectl -n boutique get svc front
> for n in cka cka-m02 cka-m03; do curl -s -m 3 http://$(minikube -p cka ip -n $n):30080/; echo; done
> ```
>
> La forme impérative équivalente, utile à l'examen, est un `kubectl patch` sur la liste fusionnée par `port` : `kubectl -n boutique patch svc front -p '{"spec":{"type":"NodePort","ports":[{"port":80,"nodePort":30080}]}}'`. Le port `30080` est dans la bande statique (30000-30085), réservée aux choix manuels.
>
> ```bash
> kubectl -n boutique create service nodeport essai-np --tcp=80:80 --node-port=29999
> ```
>
> L'API refuse : `error: failed to create NodePort service: Service "essai-np" is invalid: spec.ports[0].nodePort: Invalid value: 29999: provided port is not in the valid range. The range of valid ports is 30000-32767`. Rien n'est créé. N'essaie pas de le vérifier avec `--dry-run=server` : l'allocateur de ports en mode dry-run ne contrôle que les doublons, pas la plage, et répond `service/essai-np created (server dry run)`. Un port déjà pris (`--node-port=30080`), lui, est refusé dans les deux modes (`provided port is already allocated`).
>
> **Vérification** : `kubectl -n boutique get svc front` affiche `NodePort` et `80:30080/TCP`, et les trois `curl` renvoient `<h1>Boutique</h1><p>v1</p>`.

#### Exercice 10.3 — Lire les règles de kube-proxy

**Point de départ** : exercice 10.2.

Sur le nœud `cka-m02`, sans rien modifier, retrouve : la règle de `KUBE-SERVICES` qui capture la ClusterIP de `api`, la chaîne `KUBE-SVC-…` correspondante et ses probabilités, la chaîne `KUBE-SEP-…` d'un des pods `api` et sa cible DNAT, puis la règle `KUBE-NODEPORTS` du port `30080` et la chaîne `KUBE-EXT-…` où elle mène. Relève la valeur de la marque de masquage. Combien de règles de tirage la chaîne du Service `front` contient-elle, et avec quelles probabilités ?

> [!example]- Solution
> ```bash
> minikube -p cka ssh -n cka-m02
> sudo iptables -t nat -S KUBE-SERVICES | grep 'boutique/api:http'
> sudo iptables -t nat -S KUBE-SVC-ETGNB2QTAQD6EL4Q
> sudo iptables -t nat -S KUBE-SEP-4SQSYJZWRF7IITGD
> sudo iptables -t nat -S KUBE-NODEPORTS | grep 30080
> sudo iptables -t nat -S KUBE-EXT-DFX7DWOQ4E3MOCC2
> sudo iptables -t nat -S KUBE-MARK-MASQ
> sudo iptables -t nat -S KUBE-SVC-DFX7DWOQ4E3MOCC2
> exit
> ```
>
> Les noms de chaînes ci-dessus sont ceux de `boutique/api:http`, de `boutique/front` et du point d'accès `10.244.34.135:8080` : les noms `KUBE-SVC` et `KUBE-EXT` ne dépendent que du namespace, du Service, du nom de port et du protocole, et sont donc les mêmes sur ton lab ; les noms `KUBE-SEP` dépendent aussi de l'adresse du pod. Prends le tien dans la sortie de la commande précédente plutôt que de le recopier. Si `sudo iptables -t nat -S` ne montrait rien de Kubernetes, essaie `sudo iptables-legacy-save -t nat` : les deux interfaces d'iptables ne voient pas les mêmes tables.
>
> La chaîne `KUBE-SVC-ETGNB2QTAQD6EL4Q` commence par la règle de marquage `! -s 10.244.0.0/16`, puis une règle `--probability 0.50000000000` et une règle sans condition. La chaîne `KUBE-SEP-…` marque le trafic dont la source est le pod lui-même, puis fait `DNAT --to-destination <IP du pod>:8080`. `KUBE-NODEPORTS` envoie `--dport 30080` vers `KUBE-EXT-DFX7DWOQ4E3MOCC2`, qui marque tout (`masquerade traffic for boutique/front external destinations`) puis saute dans `KUBE-SVC-DFX7DWOQ4E3MOCC2`. La marque est `0x4000/0x4000`. Avec trois pods `front`, la chaîne du Service contient trois règles de saut : `0.33333333349`, `0.50000000000`, puis une règle sans probabilité.
>
> **Vérification** : `minikube -p cka ssh -n cka-m02 -- "sudo iptables -t nat -S KUBE-SVC-DFX7DWOQ4E3MOCC2 | grep -c 'KUBE-SEP-'"` affiche le nombre de pods `front` prêts (3).

#### Exercice 10.4 — MetalLB et le Service front-lb

**Point de départ** : exercice 10.3.

Active l'addon `metallb`, attends ses pods et constate que sa plage est vide. Enregistre la plage `192.168.49.100-192.168.49.120` dans le profil minikube (adapte les trois premiers octets si `minikube -p cka ip` ne renvoie pas `192.168.49.2`) et vérifie la ConfigMap, puis écris dans `~/cka/reseau/metallb-config.yaml` la ConfigMap équivalente et applique-la. Crée ensuite dans `~/cka/boutique/svc-front-lb.yaml` le Service `front-lb`, de type LoadBalancer, port 80 vers les pods `app=front`, labels `app=front` et `tier=web`. Interroge-le depuis ton poste, retrouve dans ses événements le nœud qui annonce l'adresse, et compare la MAC apprise par ton poste à celle de ce nœud.

> [!example]- Solution
> ```bash
> minikube -p cka addons enable metallb
> kubectl -n metallb-system rollout status deployment/controller --timeout=300s
> kubectl -n metallb-system rollout status daemonset/speaker --timeout=300s
> kubectl -n metallb-system get configmap config -o jsonpath='{.data.config}'
> ```
>
> La plage affichée est `- -` : vide. On l'enregistre d'abord dans le profil. Dans un terminal, `minikube -p cka addons configure metallb` pose les deux questions (`-- Enter Load Balancer Start IP:` puis `-- Enter Load Balancer End IP:`) ; la forme suivante, par un tube, marche aussi dans un script, grâce à la pause entre les deux réponses :
>
> ```bash
> { echo 192.168.49.100; sleep 2; echo 192.168.49.120; } | minikube -p cka addons configure metallb
> kubectl -n metallb-system get configmap config -o jsonpath='{.data.config}'
> ```
>
> minikube répond `metallb was successfully configured` (`metallb a été configuré avec succès` en français) après avoir réappliqué l'addon : la ConfigMap contient maintenant `- 192.168.49.100-192.168.49.120`. On garde ensuite la même configuration sous forme de manifeste, le geste qui vaut sur tout cluster ; ici, `kubectl apply` répond `configmap/config unchanged` :
>
> ```bash
> mkdir -p ~/cka/reseau
> cat > ~/cka/reseau/metallb-config.yaml <<'EOF'
> apiVersion: v1
> kind: ConfigMap
> metadata:
>   name: config
>   namespace: metallb-system
> data:
>   config: |
>     address-pools:
>     - name: default
>       protocol: layer2
>       addresses:
>       - 192.168.49.100-192.168.49.120
> EOF
> kubectl apply -f ~/cka/reseau/metallb-config.yaml
> cat > ~/cka/boutique/svc-front-lb.yaml <<'EOF'
> apiVersion: v1
> kind: Service
> metadata:
>   name: front-lb
>   namespace: boutique
>   labels:
>     app: front
>     tier: web
> spec:
>   type: LoadBalancer
>   selector:
>     app: front
>   ports:
>   - port: 80
>     protocol: TCP
>     targetPort: 80
> EOF
> kubectl apply -f ~/cka/boutique/svc-front-lb.yaml
> kubectl -n boutique get svc front-lb -w
> ```
>
> Arrête l'observation (`Ctrl+C`) quand `EXTERNAL-IP` affiche `192.168.49.100` : la plage étant déjà là, l'adresse apparaît en général dès la première ligne, sans passage par `<pending>`. La forme impérative équivalente est `kubectl -n boutique expose deployment front --name=front-lb --type=LoadBalancer --port=80`.
>
> ```bash
> curl -s http://192.168.49.100/; echo
> kubectl -n boutique describe svc front-lb | sed -n '/^Events:/,$p'
> ip neigh show 192.168.49.100
> docker inspect -f '{{range .NetworkSettings.Networks}}{{.MacAddress}}{{end}}' cka-m03
> ```
>
> Les événements montrent `IPAllocated` (`Assigned IP "192.168.49.100"`, émis par le contrôleur) puis `nodeAssigned` (`announcing from node "cka-m03"` par exemple, émis par un speaker). La MAC associée à `192.168.49.100` dans la table ARP de ton poste est celle du conteneur du nœud annoncé : c'est lui qui répond aux requêtes ARP de cette adresse. Le Service a aussi reçu un NodePort (colonne `PORT(S)`, `80:3xxxx/TCP`), comme tout LoadBalancer.
>
> Après un `minikube -p cka stop` puis `start`, minikube réapplique la ConfigMap de l'addon avec la plage mémorisée dans le profil : grâce à `addons configure`, c'est la bonne. Si tu avais sauté cette étape, la plage serait revenue à `- -` ; la ligne suivante la rétablit au besoin :
>
> ```bash
> kubectl -n metallb-system get configmap config -o jsonpath='{.data.config}' | grep -q '192.168.49.100' || kubectl apply -f ~/cka/reseau/metallb-config.yaml
> ```
>
> **Vérification** : `kubectl -n boutique get svc front-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}'` affiche `192.168.49.100`, et `curl -s http://192.168.49.100/` renvoie `<h1>Boutique</h1><p>v1</p>`.

#### Exercice 10.5 — Le Service headless api-pods et le Service meteo

**Point de départ** : exercice 10.4.

Crée dans `~/cka/boutique/svc-api-pods.yaml` le Service headless `api-pods` (sélecteur `app=api`, port nommé `http` 8080 vers le port nommé `http`, labels `app=api` et `tier=api`), et dans `~/cka/boutique/svc-meteo.yaml` le Service `meteo` de type ExternalName vers `example.com`. Compare ce que kube-proxy et le DNS font de chacun, à l'aide d'`outils`.

> [!example]- Solution
> ```bash
> cat > ~/cka/boutique/svc-api-pods.yaml <<'EOF'
> apiVersion: v1
> kind: Service
> metadata:
>   name: api-pods
>   namespace: boutique
>   labels:
>     app: api
>     tier: api
> spec:
>   clusterIP: None
>   selector:
>     app: api
>   ports:
>   - name: http
>     port: 8080
>     protocol: TCP
>     targetPort: http
> EOF
> cat > ~/cka/boutique/svc-meteo.yaml <<'EOF'
> apiVersion: v1
> kind: Service
> metadata:
>   name: meteo
>   namespace: boutique
> spec:
>   type: ExternalName
>   externalName: example.com
> EOF
> kubectl apply -f ~/cka/boutique/svc-api-pods.yaml -f ~/cka/boutique/svc-meteo.yaml
> kubectl -n boutique get svc api-pods meteo
> kubectl -n boutique get endpointslices -l kubernetes.io/service-name=api-pods --show-labels
> kubectl -n boutique exec outils -- dig +short api-pods.boutique.svc.cluster.local
> kubectl -n boutique exec outils -- dig +short api.boutique.svc.cluster.local
> kubectl -n boutique exec outils -- dig +short meteo.boutique.svc.cluster.local
> minikube -p cka ssh -n cka-m02 -- "sudo iptables-save -t nat | grep -c 'boutique/api-pods\|boutique/meteo'"
> ```
>
> `api-pods` a `CLUSTER-IP None`, son EndpointSlice porte le label `service.kubernetes.io/headless`, et son nom résout vers les **adresses des pods** `api` ; `api` résout vers sa ClusterIP unique. `meteo` affiche `EXTERNAL-IP example.com` et résout vers `example.com.` suivi des adresses de ce domaine (un CNAME). Le dernier compteur vaut `0` : kube-proxy n'écrit aucune règle pour un Service headless ni pour un ExternalName (minikube ajoute `ssh: Process exited with status 1`, parce que `grep -c` sort en code 1 quand il ne trouve rien).
>
> **Vérification** : `kubectl -n boutique get svc` liste `api`, `api-pods`, `front`, `front-lb` et `meteo`, et `dig +short api-pods.boutique.svc.cluster.local` renvoie autant d'adresses qu'il y a de pods `api` prêts.

#### Exercice 10.6 — Un Service sans sélecteur

**Point de départ** : exercice 10.5. Cet exercice est temporaire.

Crée le Service `externe` (port nommé `http` 80, sans sélecteur) et l'EndpointSlice `externe-1` qui lui donne pour unique backend l'adresse d'un pod `front`, lue dynamiquement (elle simule ici un serveur hors du cluster). Interroge `externe` depuis `outils`, montre que `kubectl port-forward` le refuse, puis supprime les deux objets.

> [!example]- Solution
> ```bash
> IP_FRONT=$(kubectl -n boutique get pods -l app=front -o jsonpath='{.items[0].status.podIP}')
> echo "$IP_FRONT"
> cat > ~/cka/reseau/externe.yaml <<EOF
> apiVersion: v1
> kind: Service
> metadata:
>   name: externe
>   namespace: boutique
> spec:
>   ports:
>   - name: http
>     port: 80
>     protocol: TCP
> ---
> apiVersion: discovery.k8s.io/v1
> kind: EndpointSlice
> metadata:
>   name: externe-1
>   namespace: boutique
>   labels:
>     kubernetes.io/service-name: externe
>     endpointslice.kubernetes.io/managed-by: staff
> addressType: IPv4
> ports:
> - name: http
>   port: 80
>   protocol: TCP
> endpoints:
> - addresses:
>   - "${IP_FRONT}"
> EOF
> kubectl apply -f ~/cka/reseau/externe.yaml
> kubectl -n boutique describe svc externe | grep -E '^(Selector|Endpoints):'
> kubectl -n boutique exec outils -- curl -s -m 3 http://externe/; echo
> kubectl -n boutique port-forward svc/externe 8081:80
> ```
>
> Le here-document n'est pas protégé par des apostrophes (`<<EOF`) pour que le shell remplace `${IP_FRONT}`. `describe` montre `Selector: <none>` et l'adresse fournie dans `Endpoints`. `curl` renvoie la page de `front` : kube-proxy traite la tranche manuelle comme une tranche du contrôleur. `port-forward` échoue avec `invalid service 'externe': Service is defined without a selector`.
>
> ```bash
> kubectl delete -f ~/cka/reseau/externe.yaml
> ```
>
> **Vérification** : `kubectl -n boutique get svc,endpointslices | grep externe` ne renvoie plus rien.

#### Exercice 10.7 — Affinité de session et externalTrafficPolicy

**Point de départ** : exercice 10.6. Cet exercice est temporaire.

1. Crée le Service ClusterIP `api-collant` (sélecteur `app=api`, port 8080 vers `http`, `sessionAffinity: ClientIP`). Depuis `outils`, appelle six fois `/hostname` à travers `api`, puis à travers `api-collant`, et compare.
2. Crée le Service NodePort `api-externe` (sélecteur `app=api`, port 8080 vers `http`, port de nœud attribué automatiquement). Depuis ton poste, appelle `/clientip` par l'adresse d'un nœud qui n'héberge **aucun** pod `api`, puis par celle d'un nœud qui en héberge un. Passe le Service en `externalTrafficPolicy: Local` et recommence.
3. Supprime les deux Services.

> [!example]- Solution
> `kubectl create service clusterip api-collant` poserait le sélecteur `app=api-collant`, qui ne désigne aucun pod, et `kubectl expose` n'a pas d'option d'affinité : on écrit directement le manifeste.
>
> ```bash
> cat > ~/cka/reseau/api-collant.yaml <<'EOF'
> apiVersion: v1
> kind: Service
> metadata:
>   name: api-collant
>   namespace: boutique
> spec:
>   selector:
>     app: api
>   sessionAffinity: ClientIP
>   ports:
>   - name: http
>     port: 8080
>     targetPort: http
> EOF
> kubectl apply -f ~/cka/reseau/api-collant.yaml
> kubectl -n boutique get svc api-collant -o jsonpath='{.spec.sessionAffinityConfig.clientIP.timeoutSeconds}{"\n"}'
> kubectl -n boutique exec outils -- sh -c 'for i in 1 2 3 4 5 6; do curl -s api:8080/hostname; echo; done'
> kubectl -n boutique exec outils -- sh -c 'for i in 1 2 3 4 5 6; do curl -s api-collant:8080/hostname; echo; done'
> ```
>
> Le délai par défaut affiché est `10800`. À travers `api`, les noms de pods alternent au hasard ; à travers `api-collant`, les six réponses donnent le même pod.
>
> ```bash
> kubectl -n boutique expose deployment api --name=api-externe --type=NodePort --port=8080 --target-port=http
> NP=$(kubectl -n boutique get svc api-externe -o jsonpath='{.spec.ports[0].nodePort}')
> kubectl -n boutique get pods -l app=api -o wide
> ```
>
> Repère un nœud **sans** pod `api` (ici `cka`) et un nœud **avec** (ici `cka-m02`) :
>
> ```bash
> curl -s -m 3 http://$(minikube -p cka ip -n cka):$NP/clientip; echo
> curl -s -m 3 http://$(minikube -p cka ip -n cka-m02):$NP/clientip; echo
> kubectl -n boutique patch svc api-externe -p '{"spec":{"externalTrafficPolicy":"Local"}}'
> curl -s -m 3 http://$(minikube -p cka ip -n cka):$NP/clientip; echo "code $?"
> curl -s -m 3 http://$(minikube -p cka ip -n cka-m02):$NP/clientip; echo
> ```
>
> En `Cluster`, le pod voit une adresse source masquée : celle du tunnel du nœud d'entrée, `10.244.142.64:…` par `cka`, `10.244.195.192:…` par `cka-m02`, même quand le pod qui répond tourne sur ce nœud (10.7). En `Local`, l'appel par `cka` échoue au bout du délai (`code 28` : kube-proxy y jette le trafic, `has no local endpoints`), et l'appel par `cka-m02` renvoie `192.168.49.1:…`, l'adresse réelle de ton poste.
>
> ```bash
> kubectl -n boutique delete svc api-collant api-externe
> ```
>
> **Vérification** : `kubectl -n boutique get svc` liste de nouveau exactement `api`, `api-pods`, `front`, `front-lb` et `meteo`.

---
