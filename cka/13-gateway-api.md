---
title: "CKA — 13. Gateway API"
description: "La Gateway API v1.6 en profondeur : modèle de rôles, canaux, GatewayClass, Gateway et listeners, HTTPRoute (correspondances, préséance, filtres, poids), statuts et conditions, ReferenceGrant, GRPCRoute, migration depuis Ingress, avec Envoy Gateway v1.9.2 installé par Helm."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 13. Gateway API

La Gateway API est la successeure officielle de l'Ingress. Elle sépare ce que l'Ingress mélangeait (l'infrastructure, le point d'entrée, les règles de routage), elle exprime dans des champs typés ce qui exigeait des annotations (redirections, réécritures, routage sur en-tête, partage pondéré du trafic), et elle encadre les références entre namespaces. Le programme CKA v1.37 lui consacre une compétence à part entière, *Use the Gateway API to manage Ingress traffic*, dans le domaine *Services and Networking* (20 %), et le site `gateway-api.sigs.k8s.io` fait partie de la documentation autorisée pendant l'examen du CKA. Ce chapitre présente le modèle de rôles et les canaux de publication, installe Envoy Gateway v1.9.2 par Helm, détaille GatewayClass, Gateway et HTTPRoute champ par champ, les règles de préséance, les filtres, les statuts et leurs raisons, ReferenceGrant et GRPCRoute, puis migre l'Ingress du [chapitre 12](12-ingress.md) vers un Gateway. À la fin, la boutique est servie en HTTPS sur `gw.boutique.example`, avec un partage 90/10 entre `front` et une nouvelle version `front-v2`.

### 13.1 Pourquoi une nouvelle API

Le chapitre 12 a montré les limites de l'Ingress. Son API ne connaît que l'hôte, le chemin, le backend et TLS ; tout le reste passe par des annotations propres à chaque contrôleur, ni typées, ni validées, ni portables. Un seul objet porte à la fois le point d'entrée, le certificat et les règles de chaque application : dans un cluster partagé, l'équipe d'une application qui peut écrire son Ingress peut aussi choisir le certificat et l'hôte, et entrer en conflit avec une autre équipe. Enfin, l'API ne sait router que HTTP et HTTPS.

La Gateway API répond point par point. Elle découpe la configuration en ressources distinctes, chacune possédée par un rôle. Elle intègre dans le schéma les fonctions les plus demandées : correspondance sur les en-têtes, la méthode et les paramètres de requête, partage pondéré, redirections, réécritures, modification d'en-têtes, miroir de trafic. Elle définit des règles de préséance et de fusion que toutes les implémentations doivent respecter, là où l'Ingress laissait chaque contrôleur décider. Elle couvre aussi gRPC, TLS, TCP et UDP. Et elle est publiée sous forme de CRD, hors du cœur de Kubernetes : elle évolue à son propre rythme, sans attendre une version mineure du cluster.

| | Ingress | Gateway API |
|---|---|---|
| Ressources | Ingress, IngressClass | GatewayClass, Gateway, HTTPRoute, GRPCRoute, ReferenceGrant… |
| Livraison | intégrée à kube-apiserver | CRD installées à part |
| Point d'entrée | implicite (ports 80 et 443 du contrôleur) | explicite : `listeners` du Gateway |
| Routage | hôte et chemin | hôte, chemin, en-têtes, méthode, paramètres de requête |
| Fonctions avancées | annotations propres au contrôleur | filtres typés, poids, délais |
| Multi-équipes | un objet pour tout | rôles séparés, poignée de main Gateway ↔ route |
| Protocoles | HTTP, HTTPS | HTTP, HTTPS, gRPC, TLS, TCP, UDP |
| Évolution | gelée | active (v1.6 en juin 2026) |

### 13.2 Le modèle de rôles

La Gateway API part d'un constat : dans un cluster partagé, tout le monde n'a pas les mêmes responsabilités. Elle définit trois rôles, chacun associé à une ressource.

```
LES RÔLES ET LEURS RESSOURCES
═════════════════════════════

  Fournisseur d'infrastructure  ──▶  GatewayClass   (portée cluster)
  (« Ian »)                          « quel logiciel, quelle configuration »
        │                                  ▲
        │                                  │ gatewayClassName
  Opérateur du cluster          ──▶  Gateway        (namespacé)
  (« Chihiro »)                      « quelle adresse, quels ports,
        │                              quels certificats, qui peut s'attacher »
        │                                  ▲
        │                                  │ parentRefs  (+ allowedRoutes
        │                                  │              côté Gateway)
  Développeur d'application     ──▶  HTTPRoute      (namespacé)
  (« Ana »)                          « quelles requêtes vers quels Services »
                                           │
                                           │ backendRefs
                                           ▼
                                     Services, pods
```

Les noms Ian, Chihiro et Ana sont ceux de la documentation officielle. Le guide de migration y ajoute l'*administrateur d'application*, qui partage avec l'opérateur la gestion des Gateway. Rien n'oblige à séparer ces rôles : sur un petit cluster, une même personne les tient tous, et un seul Role RBAC peut couvrir les trois ressources. L'intérêt est de **pouvoir** les séparer. Avec RBAC (chapitre 16), on donne aux équipes applicatives le droit d'écrire des HTTPRoute dans leur namespace, sans droit sur les Gateway : elles ne peuvent ni changer de certificat, ni ouvrir un port.

Le rattachement d'une route à un Gateway est une **poignée de main à double sens**. La route désigne le Gateway dans `parentRefs`. Le Gateway, dans `allowedRoutes` de chaque listener, dit quels namespaces et quels types de routes il accepte. Les deux doivent être d'accord. Une route qui vise un Gateway sans y être admise reste détachée, avec une condition qui le dit (13.11).

### 13.3 Ressources, versions et canaux

La Gateway API publie ses ressources en deux **canaux**. Le canal *Standard* contient les ressources et les champs stables, avec des garanties de compatibilité. Le canal *Experimental* contient tout le Standard, plus les ressources alpha et les champs pas encore promus, sans garantie de compatibilité. Une fonction naît toujours en Experimental, puis passe en Standard ou disparaît. La documentation recommande le canal Standard par défaut.

Au 23 octobre 2026, la dernière version stable est **v1.6.3**. Son canal Standard contient dix CRD, toutes dans le groupe `gateway.networking.k8s.io` :

| Ressource | Nom court | Version stockée | Rôle |
|---|---|---|---|
| GatewayClass | `gc` | v1 (v1beta1 aussi servie) | classe de Gateway, liée à un contrôleur |
| Gateway | `gtw` | v1 (v1beta1 aussi servie) | point d'entrée : adresses, listeners |
| HTTPRoute | | v1 (v1beta1 aussi servie) | routage HTTP |
| GRPCRoute | | v1 | routage gRPC (Standard depuis v1.1) |
| ReferenceGrant | `refgrant` | **v1beta1** (v1 servie) | autorise une référence entre namespaces |
| BackendTLSPolicy | `btlspolicy` | v1 | TLS entre la passerelle et le backend (Standard depuis v1.4) |
| ListenerSet | `lset` | v1 | listeners ajoutés à un Gateway depuis un autre objet (Standard depuis v1.5) |
| TLSRoute | | v1 | routage TLS par SNI (Standard depuis v1.5) |
| TCPRoute, UDPRoute | | v1 | routage TCP et UDP (Standard depuis v1.6) |

Le canal Experimental y ajoute notamment XBackend, XBackendTrafficPolicy et XMesh, dans le groupe distinct `gateway.networking.x-k8s.io`. La commande d'installation officielle du canal Standard est :

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/standard-install.yaml
```

La documentation impose `--server-side`, et la raison pratique est la taille. Un apply côté client recopie tout l'objet dans l'annotation `kubectl.kubernetes.io/last-applied-configuration`, et l'ensemble des annotations d'un objet est limité à 256 Kio : la CRD HTTPRoute du canal Experimental v1.6.3 pèse près de 300 Ko en JSON compact et dépasse cette limite ; celle du canal Standard, 243 Ko, la frôle. Chaque CRD porte deux annotations qui disent ce qui est installé : `gateway.networking.k8s.io/bundle-version` et `gateway.networking.k8s.io/channel`. Le paquet installe aussi une ValidatingAdmissionPolicy, `safe-upgrades.gateway.networking.k8s.io`, qui refuse deux opérations : appliquer des CRD Experimental par-dessus des CRD Standard, et installer des CRD d'une version antérieure à v1.5.0.

```bash
kubectl get crd gateways.gateway.networking.k8s.io \
  -o go-template='version={{ index .metadata.annotations "gateway.networking.k8s.io/bundle-version" }} channel={{ index .metadata.annotations "gateway.networking.k8s.io/channel" }}{{ "\n" }}'
```

> [!note] Gateway API ≠ Kubernetes
> Les CRD de la Gateway API ne sont pas livrées avec kube-apiserver : un cluster 1.37 nu n'a ni `Gateway` ni `HTTPRoute`. `kubectl api-resources --api-group=gateway.networking.k8s.io` vide signifie « CRD non installées ». La documentation de kubernetes.io décrit la Gateway API comme un module complémentaire (*add-on*) ; sa référence est sur `gateway-api.sigs.k8s.io`.

### 13.4 Installer Envoy Gateway avec Helm

Comme l'Ingress, la Gateway API n'est qu'une déclaration : il faut une implémentation. Le lab utilise **Envoy Gateway**, projet de la communauté Envoy, dans sa version **v1.9.2** (28 septembre 2026). minikube v1.39.0 n'a pas d'addon Gateway : l'installation passe par le chart Helm officiel, publié en OCI.

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.2 \
  -n envoy-gateway-system --create-namespace
kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
```

```
Pulled: docker.io/envoyproxy/gateway-helm:v1.9.2
Digest: sha256:be034275b55deeddd6b7bc1f4da6eeb02b8efc418a4a29e2b1977851b24b1e63
…
deployment.apps/envoy-gateway condition met
```

L'installation prend environ 45 secondes, dont près de 40 pour le Job `eg-gateway-helm-certgen`, qui fabrique les certificats internes. Le chart installe :

- le Deployment `envoy-gateway` (image `docker.io/envoyproxy/gateway:v1.9.2`), le **contrôleur** : il surveille les objets Gateway API et pilote les proxys ;
- le Service `envoy-gateway` (ClusterIP), par lequel les proxys reçoivent leur configuration ;
- par défaut (`crds.enabled: true`), les **CRD de la Gateway API v1.6.1 du canal Experimental**, les CRD propres à Envoy Gateway (`gateway.envoyproxy.io/v1alpha1` : `envoyproxies`, `clienttrafficpolicies`, `backendtrafficpolicies`, `securitypolicies`…) et la politique `safe-upgrades` ;
- la ConfigMap `envoy-gateway-config`, qui fixe le nom du contrôleur : `gateway.envoyproxy.io/gatewayclass-controller`.

Le chart ne crée **pas** de GatewayClass : c'est à toi de le faire (13.5). Les CRD sont dans le répertoire `crds/` d'un sous-chart, avec la conséquence habituelle de Helm : elles sont installées au premier `helm install`, **jamais mises à jour** par `helm upgrade`. Une montée de version d'Envoy Gateway commence donc par l'application manuelle des nouvelles CRD. Si le cluster a déjà des CRD Gateway API gérées par ailleurs, on installe le chart avec `--set crds.enabled=false`.

```
CE QUE FAIT ENVOY GATEWAY D'UN GATEWAY
══════════════════════════════════════

  Gateway boutique-gw (namespace boutique)
        │ le contrôleur envoy-gateway le voit
        ▼
  namespace envoy-gateway-system
  ┌──────────────────────────────────────────────────────────────┐
  │ Deployment  envoy-boutique-boutique-gw-<hash>                │
  │   conteneurs : envoy (envoyproxy/envoy:distroless-v1.39.1),  │
  │                shutdown-manager                              │
  │ Service     envoy-boutique-boutique-gw-<hash>  LoadBalancer  │
  │   80 → 10080, 443 → 10443 dans le conteneur                  │
  └──────────────────────────────────────────────────────────────┘
        │ MetalLB attribue une adresse (192.168.49.10x)
        ▼
  status.addresses[0].value du Gateway
```

Chaque Gateway reçoit **son propre** proxy Envoy, un Deployment et un Service de type LoadBalancer dans `envoy-gateway-system`. Leurs labels `gateway.envoyproxy.io/owning-gateway-name` et `gateway.envoyproxy.io/owning-gateway-namespace` permettent de les retrouver. Envoy Gateway décale les ports privilégiés de 10 000 dans le conteneur (80 devient 10080, 443 devient 10443) pour que le proxy tourne sans la capacité `CAP_NET_BIND_SERVICE` ; le Service, lui, expose bien 80 et 443. Dans le lab, c'est MetalLB (chapitre 10) qui donne une adresse à ce Service ; sans fournisseur de LoadBalancer, le Gateway resterait `Programmed=False` (13.11).

> [!info] minikube ≠ examen
> Le lab installe lui-même les CRD (par le chart d'Envoy Gateway, canal Experimental v1.6.1) et le contrôleur. Le programme demande de **savoir utiliser** la Gateway API, pas d'installer une implémentation donnée : sur un cluster d'examen, commence par `kubectl get gatewayclass` et `kubectl api-resources --api-group=gateway.networking.k8s.io` pour savoir ce qui est disponible. Les objets que tu écris (Gateway, HTTPRoute, ReferenceGrant) sont standard et indépendants de l'implémentation. Note aussi que la matrice de compatibilité publiée par Envoy Gateway liste la v1.9 comme testée sur Kubernetes 1.33 à 1.36 ; elle fonctionne sur le lab en 1.37.0, ce que le relevé du lab a vérifié, mais la 1.37 n'y figure pas officiellement.

### 13.5 GatewayClass

La GatewayClass est l'équivalent de l'IngressClass : un objet de portée cluster qui associe un nom à un contrôleur.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

`spec.controllerName` est obligatoire et **immuable** (« Value is immutable » si l'on tente de le changer). Le champ facultatif `parametersRef` pointe vers une ressource de configuration propre à l'implémentation ; chez Envoy Gateway, c'est une `EnvoyProxy`, qui permet par exemple de changer le type du Service créé pour chaque Gateway. `description` est un texte libre, affiché en dernière colonne de `kubectl get gatewayclass -o wide` (colonne de priorité 1, absente de la sortie par défaut).

Le contrôleur qui se reconnaît dans `controllerName` écrit la condition `Accepted` dans le statut de la classe :

```bash
kubectl get gatewayclass
```

```
NAME   CONTROLLER                                      ACCEPTED   AGE
eg     gateway.envoyproxy.io/gatewayclass-controller   True       15s
```

`ACCEPTED` à `Unknown` avec la raison `Pending` signifie qu'aucun contrôleur ne s'est reconnu : `controllerName` mal orthographié, ou contrôleur absent. Il n'y a pas de notion de classe « par défaut » : un Gateway nomme toujours sa classe.

### 13.6 Gateway et listeners

Le Gateway décrit un point d'entrée. Ses deux champs obligatoires sont `gatewayClassName` et `listeners`. Un **listener** est un couple port-protocole, éventuellement restreint à un nom d'hôte, avec sa configuration TLS et la liste des routes qu'il admet.

```
Gateway (gateway.networking.k8s.io/v1, namespacé)
═════════════════════════════════════════════════
spec
├── gatewayClassName ........ obligatoire
├── addresses[] ............. adresses demandées (facultatif ; sinon
│                             attribuées par l'implémentation)
├── infrastructure .......... labels et annotations à propager, parametersRef
└── listeners[] ............. 1 à 64, obligatoire
    ├── name ................ obligatoire, unique : c'est le « sectionName »
    ├── port ................ obligatoire, 1-65535
    ├── protocol ............ obligatoire : HTTP, HTTPS, TLS, TCP, UDP
    ├── hostname ............ filtre sur l'hôte (joker « *. » admis)
    ├── tls
    │   ├── mode ............ Terminate (défaut) | Passthrough
    │   ├── certificateRefs[] Secrets kubernetes.io/tls (64 au plus)
    │   └── options
    └── allowedRoutes
        ├── namespaces.from . Same (défaut) | All | Selector (+ selector)
        └── kinds[] ......... types de routes admis (défaut : selon protocole)
status
├── addresses[] ............. adresses effectives (type, value)
├── conditions[] ............ Accepted, Programmed…
└── listeners[] ............. name, attachedRoutes, supportedKinds, conditions
```

Les règles de validation sont écrites en CEL dans les CRD, et le serveur d'API refuse un Gateway qui les enfreint, avec le message exact : `tls` interdit pour les protocoles HTTP, TCP et UDP (« tls must not be specified for protocols ['HTTP', 'TCP', 'UDP'] ») ; mode `Terminate` obligatoire pour HTTPS ; `mode` obligatoire pour TLS ; pas de `hostname` pour TCP et UDP ; noms de listeners uniques ; combinaison port, protocole et hostname unique ; et en mode `Terminate`, au moins un `certificateRefs` ou des `options`.

Le Secret de `certificateRefs` est un Secret `kubernetes.io/tls` ordinaire, le même qu'au chapitre 12 : `boutique-tls` sert tel quel. Par défaut, il est cherché dans le namespace du Gateway ; un Secret d'un autre namespace exige un ReferenceGrant (13.12).

`allowedRoutes.namespaces.from` vaut `Same` par défaut : seules les routes du namespace du Gateway peuvent s'y attacher. `All` ouvre à tous les namespaces, `Selector` à ceux dont les labels correspondent à `selector`. C'est l'opérateur qui décide qui peut publier sur son point d'entrée.

Le `hostname` d'un listener filtre les routes : une route qui déclare des `hostnames` doit en avoir au moins un qui recoupe celui du listener, sinon elle n'est pas acceptée (raison `NoMatchingListenerHostname`). Un listener `gw.boutique.example` accepte une route sans `hostnames`, ou une route qui déclare `gw.boutique.example` ou `*.boutique.example`. Un listener `*.boutique.example` accepte `gw.boutique.example` et même `a.b.boutique.example` : côté Gateway API, un joker est une **correspondance de suffixe** sur un ou plusieurs labels, alors que celui de l'Ingress ne couvre qu'un label (12.6).

### 13.7 HTTPRoute : rattachement, hôtes, règles

```
HTTPRoute (gateway.networking.k8s.io/v1, namespacé)
═══════════════════════════════════════════════════
spec
├── parentRefs[] ............ 32 au plus : name, namespace, sectionName, port
├── hostnames[] ............. 16 au plus
└── rules[] ................. 16 au plus (128 correspondances en tout)
    ├── name ................ facultatif, unique dans la route
    ├── matches[] ........... 64 au plus ; défaut : PathPrefix « / »
    │   ├── path ............ type Exact | PathPrefix (défaut) |
    │   │                     RegularExpression, value (défaut « / »)
    │   ├── headers[] ....... name, value, type Exact (défaut) | RegularExpression
    │   ├── queryParams[] ... name, value, type
    │   └── method .......... GET, POST…
    ├── filters[] ........... 13.9
    ├── backendRefs[] ....... 16 au plus : name, namespace, port, weight
    │                         (défaut 1, de 0 à 1 000 000), filters
    └── timeouts ............ request, backendRequest
```

`parentRefs` désigne le ou les Gateway visés. `namespace` vaut par défaut celui de la route. `sectionName` restreint le rattachement à **un listener**, désigné par son nom ; `port` le restreint aux listeners d'un port (support étendu). Sans l'un ni l'autre, la route s'attache à **tous** les listeners du Gateway qui l'admettent. C'est ce détail qui rend possible la redirection HTTP→HTTPS (13.10).

`hostnames` filtre sur l'en-tête `Host`. Le port éventuel de l'en-tête est ignoré, les adresses IP sont interdites, et un joker `*.` ne peut être que le premier label. Si ni la route ni le listener ne déclarent d'hôte, la route s'applique à tout hôte.

Les **correspondances** suivent une logique à deux niveaux qu'il faut connaître par cœur, car elle est l'inverse d'une intuition courante :

```
ET À L'INTÉRIEUR D'UNE CORRESPONDANCE, OU ENTRE LES CORRESPONDANCES
═══════════════════════════════════════════════════════════════════

  rules:
  - matches:
    - path: {value: /foo}           ┐ UNE correspondance :
      headers:                      │ chemin /foo… ET en-tête version: 2
      - {name: version, value: "2"} ┘
    - path: {value: /v2/foo}        ── OU une autre : chemin /v2/foo…

  → la règle s'applique si (/foo… ET version: 2) OU /v2/foo…
```

Une règle sans `matches` reçoit la valeur par défaut `PathPrefix /` : elle prend tout. Une correspondance qui ne contient que des `headers` reçoit, elle aussi, un `path` par défaut `PathPrefix /`. `PathPrefix` a exactement la sémantique du `Prefix` de l'Ingress : comparaison par éléments de chemin, barre finale ignorée ; `/api` couvre `/api`, `/api/` et `/api/hostname`, pas `/apix`. `Exact` est une égalité stricte, sensible à la casse. `RegularExpression` a une conformité propre à chaque implémentation. Le nom d'un en-tête est insensible à la casse.

`backendRefs` liste les destinations. Le port est celui **du Service**, obligatoire pour un Service. Plusieurs destinations se partagent le trafic au **prorata de leur `weight`** : 90 et 10 donnent 90 % et 10 %, et le total n'a pas besoin de faire 100. Un poids nul n'envoie rien. Une règle sans `backendRefs` et sans filtre qui produit une réponse renvoie 500.

Les règles d'erreur sont précises, et utiles au dépannage : une requête qui devrait aller vers une destination **invalide** (Service introuvable, référence entre namespaces non autorisée) reçoit un **500**, et si une destination sur deux de même poids est invalide, la moitié du trafic reçoit 500 ; une destination valide **sans endpoint prêt** devrait renvoyer un **503** ; une requête qu'aucune règle attachée ne prend reçoit un **404**.

### 13.8 La préséance des règles

Quand plusieurs règles, d'une ou de plusieurs HTTPRoute attachées au même listener, correspondent à une requête, **une seule** s'applique. La spécification impose l'ordre de décision ; c'est une des grandes différences avec l'Ingress, où la fusion dépendait du contrôleur.

```
PRÉSÉANCE DES CORRESPONDANCES HTTPROUTE (spécification v1.6)
════════════════════════════════════════════════════════════

  0. Hôte : la route au nom d'hôte le plus précis l'emporte
     (le plus de caractères en nom non joker, puis le plus de caractères)
  1. Correspondance de chemin Exact
  2. PathPrefix avec le plus grand nombre de caractères
  3. Présence d'une correspondance de méthode
  4. Le plus grand nombre de correspondances d'en-têtes
  5. Le plus grand nombre de correspondances de paramètres de requête
     (RegularExpression : préséance propre à l'implémentation)
  ── égalité persistante entre ROUTES ──
  6. La route la plus ancienne (creationTimestamp)
  7. L'ordre alphabétique de « namespace/nom »
  ── égalité persistante DANS une route ──
  8. La première règle dans l'ordre de la liste
```

Appliqué à la boutique, cela donne des résultats qui ne dépendent ni de l'ordre d'écriture, ni de l'ordre de création. La route `front` a deux règles : en-tête `X-Version: v2` (chemin implicite `/`) vers `front-v2`, et `/` vers `front` et `front-v2`. La route `api` a une règle `/api`.

| Requête | Règles candidates | Gagnante | Pourquoi |
|---|---|---|---|
| `GET /` | front/2 | front/2 (90/10) | seule candidate |
| `GET /` + `X-Version: v2` | front/1, front/2 | front/1 | même chemin, plus d'en-têtes (critère 4) |
| `GET /api/hostname` | api/1, front/2 | api/1 | préfixe plus long (critère 2) |
| `GET /api/hostname` + `X-Version: v2` | api/1, front/1, front/2 | api/1 | la longueur du préfixe passe avant les en-têtes |
| `GET /apix` | front/2 | front/2 | `/api` ne couvre pas `/apix` |

La quatrième ligne est un piège d'examen classique : on croit que l'en-tête, plus « spécifique », l'emporte. Ce n'est pas le cas, le chemin passe avant.

### 13.9 Les filtres

Un filtre transforme la requête ou la réponse. Il se place au niveau de la règle (`rules[].filters`) ou d'une destination (`backendRefs[].filters`). Les implémentations doivent appliquer les filtres dans l'ordre de la liste quand c'est possible.

| Type | Support | Effet |
|---|---|---|
| `RequestHeaderModifier` | Core | ajoute (`add`), remplace (`set`) ou retire (`remove`) des en-têtes de requête |
| `RequestRedirect` | Core | répond par une redirection (schéma, hôte, port, chemin, code) |
| `ResponseHeaderModifier` | Extended | même chose sur les en-têtes de réponse |
| `URLRewrite` | Extended | réécrit l'hôte et/ou le chemin avant transmission |
| `RequestMirror` | Extended | copie la requête vers un autre backend, réponse ignorée |
| `CORS` | Extended | gère les en-têtes CORS (Standard depuis v1.5) |
| `ExtensionRef` | propre à l'implémentation | renvoie vers une ressource de l'implémentation |

**RequestRedirect** renvoie une réponse 3xx sans contacter de backend. `scheme` (`http` ou `https`), `hostname`, `port`, `path` modifient l'URL de l'en-tête `Location` ; ce qui n'est pas précisé vient de la requête. `statusCode` vaut **302** par défaut et accepte 301, 302, 303, 307 et 308 (301 et 302 en support Core, les autres en Extended). Sans `port`, le port suit le schéma : 80 pour `http`, 443 pour `https`, et il n'apparaît pas dans `Location` quand c'est le port par défaut.

**URLRewrite** modifie la requête transmise. `hostname` remplace l'en-tête `Host`. `path` prend deux formes : `ReplaceFullPath` remplace tout le chemin, `ReplacePrefixMatch` ne remplace que la partie couverte par la correspondance `PathPrefix` de la règle. Cette seconde forme est la plus utile, et la spécification en donne la table exacte :

| Chemin demandé | Préfixe de la règle | `replacePrefixMatch` | Chemin transmis |
|---|---|---|---|
| `/foo/bar` | `/foo` | `/xyz` | `/xyz/bar` |
| `/foo/bar` | `/foo/` | `/xyz/` | `/xyz/bar` |
| `/foo` | `/foo` | `/xyz` | `/xyz` |
| `/foo/` | `/foo` | `/xyz` | `/xyz/` |
| `/foo/bar` | `/foo` | (vide) | `/bar` |
| `/foo` | `/foo` | `/` | `/` |
| `/foo/` | `/foo` | `/` | `/` |

Les tests de conformité de la Gateway API vérifient aussi que `/strip-prefix/three`, avec le préfixe `/strip-prefix` remplacé par `/`, devient `/three` : le remplacement par `/` « retire » le préfixe sans doubler la barre oblique. C'est exactement ce que fait la route `api` de la boutique : `/api/hostname` arrive chez agnhost en `/hostname`.

Trois contraintes sont vérifiées par le serveur d'API dès l'écriture, avec ces messages :

- `RequestRedirect` et `backendRefs` dans la même règle : « RequestRedirect filter must not be used together with backendRefs ». Une redirection ne transmet rien, elle n'a pas de destination.
- `ReplacePrefixMatch` exige **exactement une** correspondance, de type `PathPrefix` : « When using URLRewrite filter with path.replacePrefixMatch, exactly one PathPrefix match must be specified ».
- `type` et champ assorti doivent concorder : `ReplacePrefixMatch` avec `replacePrefixMatch`, `ReplaceFullPath` avec `replaceFullPath`.

`URLRewrite` et `RequestRedirect` sont en outre incompatibles dans une même règle ; une implémentation qui reçoit une combinaison de filtres qu'elle ne sait pas appliquer met la route en `Accepted=False` avec la raison `IncompatibleFilters`.

### 13.10 Rattacher une route à un seul listener : la redirection HTTP→HTTPS

Le Gateway de la boutique a deux listeners sur le même nom d'hôte : `http` (80) et `https` (443). On veut que toute requête en clair soit redirigée vers HTTPS, et que seul HTTPS serve l'application. Il faut donc deux familles de routes, chacune attachée à **un seul** listener par `sectionName`.

```
DEUX LISTENERS, DEUX FAMILLES DE ROUTES
═══════════════════════════════════════

  Gateway boutique-gw
  ┌──────────────────────────────┬──────────────────────────────────┐
  │ listener http  :80           │ listener https :443 (boutique-tls)│
  │ hostname gw.boutique.example │ hostname gw.boutique.example      │
  └───────────────▲──────────────┴───────────────▲──────────────────┘
                  │ sectionName: http            │ sectionName: https
  HTTPRoute redirection-https          HTTPRoute front   HTTPRoute api
   RequestRedirect                      /  + X-Version    /api
   scheme https, 301                    → front, front-v2 → api (réécrit)
```

Imagine que l'on oublie `sectionName`. La route de redirection s'attacherait aussi au listener `https` ; sur ce listener, elle et la seconde règle de `front` correspondraient toutes deux à `/` avec le même nombre d'en-têtes : égalité, donc c'est la route **la plus ancienne** qui gagne (critère 6). Si la redirection a été créée la première, chaque requête HTTPS est redirigée vers… la même URL HTTPS : une boucle de redirection infinie. Dans l'autre sens, la route `front` sans `sectionName` servirait la boutique en clair sur le port 80, ce qu'on voulait justement empêcher. `sectionName` rend l'intention explicite et indépendante de l'ordre de création.

La route de redirection :

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: redirection-https
  namespace: boutique
spec:
  parentRefs:
  - name: boutique-gw
    sectionName: http
  hostnames:
  - gw.boutique.example
  rules:
  - filters:
    - type: RequestRedirect
      requestRedirect:
        scheme: https
        statusCode: 301
```

La règle n'a pas de `matches` (donc `PathPrefix /` : tout), pas de `backendRefs` (interdit avec une redirection), et le chemin d'origine est conservé : `http://gw.boutique.example/api/hostname` répond `301` avec `Location: https://gw.boutique.example/api/hostname`.

### 13.11 Statuts et conditions

Toute la Gateway API se dépanne par les statuts. Chaque objet en porte, chacun avec des conditions normalisées : `type`, `status` (`True`, `False`, `Unknown`), `reason`, `message`, `observedGeneration`. Une condition dont `observedGeneration` est inférieure à `metadata.generation` est **périmée** : le contrôleur n'a pas encore traité la dernière modification.

| Objet | Condition | `True` | Raisons de `False` (ou `Unknown`) |
|---|---|---|---|
| GatewayClass | `Accepted` | le contrôleur gère la classe | `InvalidParameters`, `Unsupported`, `UnsupportedVersion` ; `Unknown`/`Pending` : aucun contrôleur |
| Gateway | `Accepted` | configuration valide (raison `Accepted`, ou `ListenersNotValid` si un listener seulement est invalide) | `Invalid`, `InvalidParameters`, `UnsupportedAddress`, `ListenersNotValid` ; `Unknown`/`Pending` |
| Gateway | `Programmed` | configuration poussée au plan de données, adresse attribuée | `Invalid`, `Pending`, `NoResources`, `AddressNotAssigned`, `AddressNotUsable` |
| Listener | `Accepted`, `Programmed`, `ResolvedRefs`, `Conflicted` | (`Conflicted` : `False` est le bon état) | `PortUnavailable`, `UnsupportedProtocol`, `InvalidCertificateRef`, `InvalidRouteKinds`, `RefNotPermitted`, `HostnameConflict`, `ProtocolConflict` |
| Route (par parent) | `Accepted` | la route est attachée à ce parent | `NotAllowedByListeners`, `NoMatchingListenerHostname`, `NoMatchingParent`, `UnsupportedValue`, `IncompatibleFilters` ; `Unknown`/`Pending` |
| Route (par parent) | `ResolvedRefs` | toutes les références sont résolues | `RefNotPermitted`, `InvalidKind`, `BackendNotFound`, `UnsupportedProtocol` |
| Route (par parent) | `PartiallyInvalid` | certaines règles seulement sont invalides (n'existe qu'à `True`) | — |

Le statut d'une route est rangé **par parent** : `status.parents[]` contient une entrée par Gateway visé, avec le `controllerName` de l'implémentation qui l'a écrite et ses propres conditions. Une route attachée à deux Gateway peut être acceptée par l'un et refusée par l'autre. Le statut d'un Gateway donne aussi, pour chaque listener, le nombre de routes attachées (`attachedRoutes`) : c'est le moyen le plus rapide de vérifier qu'un `sectionName` fait ce qu'on croit.

Envoy Gateway met le Gateway en `Programmed=False`, raison `AddressNotAssigned`, message « No addresses have been assigned to the Gateway », tant que le Service LoadBalancer de son proxy n'a pas d'adresse ; puis en `Programmed=True` avec le message « Address assigned to the Gateway, 1/1 envoy replicas available ». Ses routes acceptées portent le message « Route is accepted », et une référence non autorisée le message « Failed to process route rule 0 backendRef 0: Backend ref to Service vitrine/vitrine not permitted by any ReferenceGrant. ».

Les commandes de lecture à connaître :

```bash
kubectl get gateway -A                       # CLASS, ADDRESS, PROGRAMMED
kubectl -n boutique wait --for=condition=Programmed gateway/boutique-gw --timeout=180s
kubectl -n boutique get gateway boutique-gw -o jsonpath='{.status.addresses[0].value}{"\n"}'
kubectl -n boutique get gateway boutique-gw \
  -o jsonpath='{range .status.listeners[*]}{.name}{"\t"}{.attachedRoutes}{"\n"}{end}'
kubectl -n boutique get httproute front \
  -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
kubectl -n boutique describe httproute front   # statut complet, lisible
```

> [!tip] Réflexe d'examen
> `kubectl get httproute` n'affiche que `HOSTNAMES` et `AGE` : il ne dit rien de l'état. Après chaque route créée, lis ses conditions (`describe` ou le jsonpath ci-dessus) et attends `Accepted=True` et `ResolvedRefs=True` avant de tester avec curl. Une route non acceptée ne produit aucune erreur à la création : seul le statut parle.

### 13.12 ReferenceGrant et références entre namespaces

Par défaut, une référence ne traverse pas les namespaces. Une HTTPRoute de `boutique` qui envoie vers un Service de `vitrine`, ou un Gateway de `boutique` qui utilise un Secret de `certificats`, est **invalide** tant que le propriétaire de la cible ne l'a pas autorisée. L'autorisation est un **ReferenceGrant**, créé **dans le namespace de la cible** :

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: ReferenceGrant
metadata:
  name: boutique-vers-vitrine
  namespace: vitrine
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: boutique
  to:
  - group: ""
    kind: Service
    name: vitrine
```

Lis-le ainsi : « dans `vitrine`, j'autorise les HTTPRoute du namespace `boutique` à référencer le Service `vitrine` ». `from` liste des triplets groupe, type, namespace : les **noms** des objets sources sont volontairement absents, car quiconque peut écrire une HTTPRoute dans un namespace peut la nommer comme il veut. `to` liste des couples groupe et type, avec un `name` facultatif ; sans `name`, tous les objets de ce type du namespace sont autorisés. Le groupe vide `""` désigne le groupe de base (Services, Secrets). Les cas de support Core sont un Secret référencé par un `certificateRefs` et un Service référencé par un `backendRef`. Les ReferenceGrant s'additionnent et ne peuvent pas entrer en conflit.

Le sens de la poignée de main se retient avec une image : c'est le **propriétaire de la ressource référencée** qui ouvre sa porte, jamais le demandeur qui s'invite. Sans ReferenceGrant, la route reste acceptée par le Gateway, mais sa condition `ResolvedRefs` passe à `False` avec la raison `RefNotPermitted`, et les requêtes concernées reçoivent un 500. La spécification interdit au passage de révéler si la cible existe : le message parle de l'absence d'autorisation, jamais de l'absence du Service.

Le rattachement d'une route à un Gateway d'un autre namespace n'utilise **pas** ReferenceGrant : il passe par `allowedRoutes` du listener (13.6), qui joue le même rôle côté Gateway.

> [!note] Versions de ReferenceGrant
> ReferenceGrant est stocké en `v1beta1` et servi en `v1beta1` et `v1` depuis la v1.5. Écris `apiVersion: gateway.networking.k8s.io/v1` ; un manifeste ancien en `v1beta1` reste accepté. C'est la seule ressource standard dont la version stockée n'est pas `v1`, parce qu'elle doit à terme rejoindre une API de Kubernetes gérée par SIG Auth.

### 13.13 Migrer d'Ingress vers la Gateway API

La correspondance entre les deux API est directe pour tout ce qui est standard :

| Ingress | Gateway API |
|---|---|
| `ingressClassName` | `gatewayClassName` du Gateway |
| point d'entrée implicite (80, 443) | `listeners` explicites du Gateway |
| `tls[].hosts`, `tls[].secretName` | listener HTTPS par hôte, `tls.certificateRefs` |
| `rules[].host` | `hostnames` de la HTTPRoute (et `hostname` du listener) |
| `paths[].path`, `pathType: Exact` / `Prefix` | `matches[].path`, type `Exact` / `PathPrefix` |
| `backend.service.name`, `port.number` | `backendRefs[].name`, `port` |
| `defaultBackend` | une règle explicite `PathPrefix /` (pas d'équivalent direct) |
| annotation de redirection TLS | filtre `RequestRedirect` sur le listener HTTP |
| annotation de réécriture | filtre `URLRewrite` |
| annotation de canari, de poids | `backendRefs[].weight` |
| annotations sans équivalent | extensions de l'implémentation (politiques, `ExtensionRef`) |

Le projet fournit l'outil **ingress2gateway** (v1.0 le 20 mars 2026, v1.2.0 le 7 juillet 2026), qui lit des Ingress, depuis le cluster ou depuis des fichiers, et imprime les objets Gateway API équivalents. Il ne crée rien : il écrit sur la sortie standard. Voici sa sortie réelle (v1.2.0) pour l'Ingress `boutique` du chapitre 12 :

```bash
kubectl -n boutique get ingress boutique -o yaml > ingress-boutique-live.yaml
ingress2gateway print --providers=ingress-nginx -n boutique --input-file=ingress-boutique-live.yaml
```

```
┌─ WARN  ────────────────────────────────────────
│  Gateway API does not support configuring URL normalization (RFC 3986, Section 6). Please check if this matters for your use case and consult implementation-specific details.
│  source: STANDARD_EMITTER
└─
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  annotations:
    gateway.networking.k8s.io/generator: ingress2gateway-1.2.0
  name: nginx
  namespace: boutique
spec:
  gatewayClassName: nginx
  listeners:
  - hostname: api.boutique.example
    name: api-boutique-example-http
    port: 80
    protocol: HTTP
  - hostname: api.boutique.example
    name: api-boutique-example-https
    port: 443
    protocol: HTTPS
    tls:
      certificateRefs:
      - group: ""
        kind: Secret
        name: boutique-tls
  - hostname: boutique.example
    name: boutique-example-http
    port: 80
    protocol: HTTP
  - hostname: boutique.example
    name: boutique-example-https
    …
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  annotations:
    gateway.networking.k8s.io/generator: ingress2gateway-1.2.0
  name: boutique-boutique-example-http
  namespace: boutique
spec:
  hostnames:
  - boutique.example
  parentRefs:
  - name: nginx
    port: 80
  rules:
  - filters:
    - requestRedirect:
        scheme: https
        statusCode: 308
      type: RequestRedirect
    matches:
    - path:
        type: PathPrefix
        value: /
…
(extrait : la sortie compte quatre HTTPRoute, dans cet ordre :
 boutique-api-boutique-example, vers api:8080 par le listener
 api-boutique-example-https ; boutique-api-boutique-example-http,
 redirection 308 de api.boutique.example ; celle ci-dessus ;
 boutique-boutique-example, vers front:80 par le listener
 boutique-example-https)
```

L'outil a reproduit fidèlement le comportement d'ingress-nginx, y compris ce qui n'était écrit nulle part : la redirection **308** vers HTTPS, implicite chez ingress-nginx dès qu'un hôte a du TLS, devient une route `RequestRedirect` explicite sur les listeners HTTP. Il a créé un listener HTTP et un listener HTTPS par hôte, et repris la classe `nginx` comme nom de GatewayClass : avant d'appliquer, il faut la remplacer par une classe qui existe (`eg` dans le lab), ou demander une sortie adaptée avec `--emitter envoy-gateway`. L'option `--providers` est obligatoire ; `--allow-experimental-gw-api` autorise les champs du canal Experimental. Les annotations non traduisibles donnent lieu à des avertissements : c'est la liste de ce qu'il reste à migrer à la main.

Une migration réelle se fait en parallèle : on déploie le Gateway à côté du contrôleur d'Ingress, on teste par la nouvelle adresse avec `curl --resolve`, puis on bascule le DNS, et on retire l'Ingress seulement ensuite. C'est ce que fait ce cours : l'Ingress `boutique` reste en place, et le Gateway sert un autre nom, `gw.boutique.example`.

### 13.14 GRPCRoute et les autres routes, en aperçu

**GRPCRoute** (Standard depuis v1.1) route les appels gRPC par service et par méthode, plutôt que par chemin HTTP. Ses correspondances portent sur `method` (`service`, `method`, type `Exact` par défaut ou `RegularExpression`) et sur les `headers` (les métadonnées gRPC) :

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata:
  name: catalogue-grpc
  namespace: boutique
spec:
  parentRefs:
  - name: boutique-gw
    sectionName: https
  hostnames:
  - grpc.boutique.example
  rules:
  - matches:
    - method:
        service: boutique.Catalogue
        method: Lister
    backendRefs:
    - name: catalogue-grpc
      port: 50051
```

Ce manifeste est un exemple ; il n'est pas appliqué dans le fil rouge. La documentation recommande des noms d'hôte distincts pour gRPC et pour le HTTP ordinaire : une implémentation peut refuser une GRPCRoute et une HTTPRoute qui partagent un nom d'hôte sur le même listener. Une HTTPRoute suffit pour du gRPC simple ; GRPCRoute rend l'intention explicite et ouvre les fonctions propres à gRPC. Les autres routes du canal Standard, TLSRoute (routage TLS par SNI, souvent en `Passthrough`), TCPRoute et UDPRoute (routage par port, listeners `TCP`/`UDP` sans `hostname`), complètent ce que l'Ingress ne savait pas faire. Le programme ne demande pas d'en maîtriser le détail.

### 13.15 Le Gateway de la boutique

Le fil rouge ajoute une seconde version du site, `front-v2`, et publie la boutique par un Gateway, à côté de l'Ingress du chapitre 12.

```
LA BOUTIQUE DERRIÈRE boutique-gw
════════════════════════════════

  client ── gw.boutique.example (adresse lue dans status.addresses)
     │
     ├── :80  listener http  ── redirection-https ── 301 → https://…
     │
     └── :443 listener https (boutique-tls)
            │
            ├── /api…            ─ route api ─── URLRewrite /api → / ─▶ api:8080
            ├── X-Version: v2    ─ route front ─ règle 1 ────────────▶ front-v2:80
            └── / (le reste)     ─ route front ─ règle 2 ─┬ 90 % ────▶ front:80
                                                          └ 10 % ────▶ front-v2:80
```

`front-v2` est la copie de `front` avec une autre page : un Deployment d'un réplica (`nginx:1.30.6-alpine`, labels `app=front-v2` et `tier=web`, mêmes ressources et même sonde que `front`), la ConfigMap `front-html-v2` qui contient `<h1>Boutique</h1><p>v2</p>`, montée sur `/usr/share/nginx/html`, et le Service `front-v2` sur le port 80. Il ne monte pas `front-conf` : la configuration nginx par défaut de l'image suffit à servir la page.

Le Gateway `boutique-gw` porte les deux listeners de 13.10, tous deux restreints à `gw.boutique.example` et aux routes du même namespace :

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: boutique-gw
  namespace: boutique
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: gw.boutique.example
    allowedRoutes:
      namespaces:
        from: Same
  - name: https
    protocol: HTTPS
    port: 443
    hostname: gw.boutique.example
    tls:
      mode: Terminate
      certificateRefs:
      - kind: Secret
        name: boutique-tls
    allowedRoutes:
      namespaces:
        from: Same
```

```bash
kubectl -n boutique get gateway boutique-gw
```

```
NAME          CLASS   ADDRESS          PROGRAMMED   AGE
boutique-gw   eg      192.168.49.101   True         45s
```

L'adresse vient de MetalLB : 192.168.49.100 est déjà prise par `front-lb` (chapitre 10), le proxy du Gateway reçoit donc en général la suivante. Ne l'écris jamais en dur : lis-la dans le statut, comme le font tous les tests de ce chapitre.

```bash
GW=$(kubectl -n boutique get gateway boutique-gw -o jsonpath='{.status.addresses[0].value}')
CA=~/cka/boutique/boutique-tls.crt
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  --resolve gw.boutique.example:80:$GW http://gw.boutique.example/
curl -s --cacert $CA --resolve gw.boutique.example:443:$GW https://gw.boutique.example/
curl -s --cacert $CA --resolve gw.boutique.example:443:$GW -H 'X-Version: v2' https://gw.boutique.example/
curl -s --cacert $CA --resolve gw.boutique.example:443:$GW https://gw.boutique.example/api/hostname
```

```
301 https://gw.boutique.example/
<h1>Boutique</h1><p>v1</p>
<h1>Boutique</h1><p>v2</p>
api-7d9c5b8f6-x2klm
```

La deuxième commande affiche `v1` neuf fois sur dix en moyenne, `v2` sinon : c'est le partage pondéré. Le certificat présenté sur 443 est `boutique-tls`, valable pour `*.boutique.example` : `--cacert` le vérifie. Une requête sans hôte connu (`curl http://$GW/`) reçoit 404, puisqu'aucune route ne correspond.

### 13.16 Dépanner un Gateway et ses routes

```
MÉTHODE : DE LA CLASSE À LA REQUÊTE
═══════════════════════════════════

  1. kubectl get gatewayclass           ACCEPTED=True ?
       Unknown/Pending → controllerName faux ou contrôleur absent
  2. kubectl get gateway -n NS          PROGRAMMED=True, ADDRESS remplie ?
       AddressNotAssigned → pas de LoadBalancer (MetalLB ?)
       Accepted=False → listener invalide (describe : raison par listener)
  3. attachedRoutes par listener         le compte est-il celui attendu ?
  4. statut de chaque route, par parent  Accepted / ResolvedRefs
       NotAllowedByListeners      → allowedRoutes (namespace, kinds)
       NoMatchingListenerHostname → hostnames sans intersection
       NoMatchingParent           → sectionName ou port inexistant
       RefNotPermitted            → ReferenceGrant manquant
       BackendNotFound            → nom ou namespace du Service faux
  5. curl --resolve HÔTE:PORT:ADRESSE   404 / 500 / 503 ?
  6. journaux : kubectl -n envoy-gateway-system logs deploy/envoy-gateway
```

| Symptôme côté client | Cause | Où regarder |
|---|---|---|
| connexion refusée ou délai sur l'adresse | Gateway non programmé, pas d'adresse | `get gateway`, conditions |
| 404 | route non attachée, hôte ou chemin sans règle | `attachedRoutes`, `Accepted`, `hostnames` |
| 500 | backend invalide (Service absent, référence non autorisée) | `ResolvedRefs` de la route |
| 503 | Service sans endpoint prêt | `kubectl get endpointslices -l kubernetes.io/service-name=…` |
| boucle de redirection | route de redirection attachée au listener HTTPS | `sectionName`, `attachedRoutes` |
| erreur de certificat | Secret absent, ou ne couvrant pas l'hôte du listener | conditions du listener (`InvalidCertificateRef`) |
| création refusée par le serveur d'API | règle CEL de la CRD (redirection + backendRefs, `tls` sur HTTP…) | message d'erreur, qui cite la règle |

### 13.17 Pièges courants

```
Piège 1 : Route rattachée à tous les listeners
═══════════════════════════════════════════════
  MAUVAIS  : parentRefs: [{name: boutique-gw}] pour la redirection
  SYMPTÔME : boucle de redirection en HTTPS, ou site servi en clair
  BON      : sectionName: http pour la redirection,
             sectionName: https pour les routes applicatives

Piège 2 : RequestRedirect avec des backendRefs
═══════════════════════════════════════════════
  SYMPTÔME : « RequestRedirect filter must not be used together with
             backendRefs » à la création
  BON      : une règle de redirection n'a pas de destination

Piège 3 : Croire que l'en-tête l'emporte sur le chemin
═══════════════════════════════════════════════════════
  MAUVAIS  : X-Version: v2 sur /api/hostname « doit » aller à front-v2
  SYMPTÔME : la requête va à api
  BON      : ordre de préséance : Exact, longueur du préfixe, méthode,
             PUIS nombre d'en-têtes

Piège 4 : ReferenceGrant dans le mauvais namespace
═══════════════════════════════════════════════════
  MAUVAIS  : ReferenceGrant créé dans boutique (namespace de la route)
  SYMPTÔME : ResolvedRefs=False, RefNotPermitted, réponses 500
  BON      : le ReferenceGrant vit dans le namespace de la CIBLE (vitrine)

Piège 5 : Hostnames sans intersection
══════════════════════════════════════
  MAUVAIS  : listener gw.boutique.example, route hostnames: [boutique.example]
  SYMPTÔME : Accepted=False, NoMatchingListenerHostname ; 404
  BON      : hostname de route égal, ou couvert par un joker du listener

Piège 6 : Se fier à kubectl get httproute
══════════════════════════════════════════
  SYMPTÔME : l'objet « existe », rien ne marche
  BON      : lire status.parents[].conditions (describe) ; une route non
             acceptée ne produit aucune erreur à la création

Piège 7 : Adresse du Gateway écrite en dur
═══════════════════════════════════════════
  MAUVAIS  : curl --resolve gw.boutique.example:443:192.168.49.101 …
  SYMPTÔME : le test échoue quand MetalLB a donné une autre adresse
  BON      : GW=$(kubectl get gateway … -o jsonpath='{.status.addresses[0].value}')

Piège 8 : ReplacePrefixMatch avec plusieurs correspondances
════════════════════════════════════════════════════════════
  SYMPTÔME : refus à la création (« exactly one PathPrefix match must be
             specified »)
  BON      : une règle par préfixe à réécrire
```

> [!summary] À retenir
> - La Gateway API est livrée en **CRD** (v1.6.3 au 23 octobre 2026) ; canal Standard par défaut, canal Experimental en plus. Envoy Gateway v1.9.2 installe par son chart les CRD v1.6.1 **Experimental** et ne crée pas de GatewayClass.
> - Trois rôles, trois ressources : GatewayClass (`controllerName` immuable), Gateway (listeners : `name`, `port`, `protocol`, `hostname`, `tls`, `allowedRoutes` à `Same` par défaut), HTTPRoute (`parentRefs`, `hostnames`, `rules`).
> - `sectionName` attache une route à **un** listener ; sans lui, elle s'attache à tous ceux qui l'admettent. C'est la clé de la redirection HTTP→HTTPS.
> - Dans `matches` : **ET** à l'intérieur d'une correspondance, **OU** entre correspondances ; défaut `PathPrefix /`. `PathPrefix` compare des éléments de chemin entiers.
> - Préséance : hôte le plus précis, `Exact`, préfixe le plus long, méthode, nombre d'en-têtes, nombre de paramètres, puis route la plus ancienne, ordre alphabétique, ordre des règles.
> - Filtres : `RequestRedirect` (302 par défaut, jamais avec `backendRefs`), `URLRewrite` (`ReplacePrefixMatch` avec une seule correspondance `PathPrefix`), modification d'en-têtes, miroir ; `weight` partage le trafic au prorata.
> - Statuts : Gateway `Accepted` et `Programmed` ; route `Accepted` et `ResolvedRefs`, **par parent**. 404 = rien ne correspond, 500 = backend invalide, 503 = pas d'endpoint.
> - Une référence vers un autre namespace exige un **ReferenceGrant dans le namespace de la cible** ; sans lui, `ResolvedRefs=False`, raison `RefNotPermitted`.
> - `ingress2gateway print --providers=ingress-nginx` traduit des Ingress en Gateway et HTTPRoute, redirection 308 implicite comprise ; il faut ensuite adapter `gatewayClassName`.

### 13.18 Exercices

#### Exercice 13.1 — Installer Envoy Gateway et la GatewayClass eg

**Point de départ** : exercice 12.6 (à défaut : `lab/restaurer.sh I1`, puis `lab/etats/10-*/appliquer.sh`, `lab/etats/11-*/appliquer.sh` et `lab/etats/12-*/appliquer.sh`).

Installe Envoy Gateway v1.9.2 avec Helm : release `eg`, namespace `envoy-gateway-system` (à créer par Helm), chart OCI officiel. Attends que le Deployment du contrôleur soit disponible. Relève la version et le canal des CRD Gateway API installées, ainsi que le nom du contrôleur. Crée ensuite la GatewayClass `eg` qui lui correspond, et vérifie qu'elle est acceptée.

> [!example]- Solution
> ```bash
> helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.9.2 \
>   -n envoy-gateway-system --create-namespace
> kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
> kubectl get crd gateways.gateway.networking.k8s.io \
>   -o go-template='version={{ index .metadata.annotations "gateway.networking.k8s.io/bundle-version" }} channel={{ index .metadata.annotations "gateway.networking.k8s.io/channel" }}{{ "\n" }}'
> kubectl -n envoy-gateway-system get configmap envoy-gateway-config -o yaml | grep controllerName
> ```
>
> La version affichée est `v1.6.1`, le canal `experimental` : ce sont les CRD embarquées dans le chart, pas la dernière version publiée de la Gateway API. Le nom du contrôleur est `gateway.envoyproxy.io/gatewayclass-controller`. Écris ensuite `~/cka/boutique/gatewayclass-eg.yaml` :
>
> ```yaml
> apiVersion: gateway.networking.k8s.io/v1
> kind: GatewayClass
> metadata:
>   name: eg
> spec:
>   controllerName: gateway.envoyproxy.io/gatewayclass-controller
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/gatewayclass-eg.yaml
> ```
>
> **Vérification** : `kubectl get gatewayclass eg` affiche `ACCEPTED True` ; `helm -n envoy-gateway-system list` montre la release `eg` en `deployed`, chart `gateway-helm-v1.9.2`.

#### Exercice 13.2 — La seconde version du site : front-v2

**Point de départ** : exercice 13.1.

Dans `boutique`, crée la ConfigMap `front-html-v2` dont la clé `index.html` vaut `<h1>Boutique</h1><p>v2</p>`, le Deployment `front-v2` (un réplica, image `nginx:1.30.6-alpine`, labels `app=front-v2` et `tier=web` sur le Deployment et les pods, port 80, sonde de disponibilité HTTP sur `/` port 80, requests 50m/32Mi, limits 200m/64Mi, ConfigMap montée sur `/usr/share/nginx/html`), et le Service ClusterIP `front-v2` sur le port 80. Garde le manifeste dans `~/cka/boutique/front-v2.yaml`.

> [!example]- Solution
> ```yaml
> apiVersion: v1
> kind: ConfigMap
> metadata:
>   name: front-html-v2
>   namespace: boutique
> data:
>   index.html: |
>     <h1>Boutique</h1><p>v2</p>
> ---
> apiVersion: apps/v1
> kind: Deployment
> metadata:
>   name: front-v2
>   namespace: boutique
>   labels:
>     app: front-v2
>     tier: web
> spec:
>   replicas: 1
>   selector:
>     matchLabels:
>       app: front-v2
>   template:
>     metadata:
>       labels:
>         app: front-v2
>         tier: web
>     spec:
>       containers:
>       - name: nginx
>         image: nginx:1.30.6-alpine
>         ports:
>         - containerPort: 80
>         readinessProbe:
>           httpGet:
>             path: /
>             port: 80
>         resources:
>           requests:
>             cpu: 50m
>             memory: 32Mi
>           limits:
>             cpu: 200m
>             memory: 64Mi
>         volumeMounts:
>         - name: html
>           mountPath: /usr/share/nginx/html
>       volumes:
>       - name: html
>         configMap:
>           name: front-html-v2
> ---
> apiVersion: v1
> kind: Service
> metadata:
>   name: front-v2
>   namespace: boutique
>   labels:
>     app: front-v2
>     tier: web
> spec:
>   selector:
>     app: front-v2
>   ports:
>   - port: 80
>     protocol: TCP
>     targetPort: 80
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/front-v2.yaml
> kubectl -n boutique rollout status deployment front-v2
> ```
>
> L'apply affiche un avertissement `would violate PodSecurity "restricted:latest"` : c'est le mode `warn=restricted` posé sur `boutique` au chapitre 8. Le pod est admis, puisque seul le niveau `baseline` est imposé. Le sélecteur `app=front-v2` garantit que le Service `front` (sélecteur `app=front`) ne voit pas ces pods : les deux versions restent séparables, ce dont le partage pondéré a besoin.
>
> Si le `curl` de la vérification, lancé dans la foulée, échoue avec `command terminated with exit code 7`, relance-le : kube-proxy met une à deux secondes à programmer les règles d'un Service tout neuf.
>
> **Vérification** : `kubectl -n boutique exec outils -- curl -s http://front-v2/` affiche `<h1>Boutique</h1><p>v2</p>`, et `kubectl -n boutique get endpointslices -l kubernetes.io/service-name=front-v2` montre une adresse prête.

#### Exercice 13.3 — Le Gateway boutique-gw

**Point de départ** : exercice 13.2.

Crée dans `boutique` le Gateway `boutique-gw` de classe `eg` avec deux listeners pour l'hôte `gw.boutique.example` : `http` (HTTP, port 80) et `https` (HTTPS, port 443, terminaison TLS avec le Secret `boutique-tls`). Les deux n'admettent que les routes du namespace du Gateway. Attends qu'il soit programmé, puis range son adresse dans la variable `GW` sans l'écrire en dur. Vérifie le nombre de routes attachées à chaque listener.

> [!example]- Solution
> Écris `~/cka/boutique/gateway-boutique.yaml` avec le manifeste de 13.15, puis :
>
> ```bash
> kubectl apply -f ~/cka/boutique/gateway-boutique.yaml
> kubectl -n boutique wait --for=condition=Programmed gateway/boutique-gw --timeout=180s
> GW=$(kubectl -n boutique get gateway boutique-gw -o jsonpath='{.status.addresses[0].value}')
> echo $GW
> kubectl -n boutique get gateway boutique-gw \
>   -o jsonpath='{range .status.listeners[*]}{.name}{"\t"}{.attachedRoutes}{"\n"}{end}'
> kubectl -n envoy-gateway-system get deploy,svc \
>   -l gateway.envoyproxy.io/owning-gateway-name=boutique-gw,gateway.envoyproxy.io/owning-gateway-namespace=boutique
> ```
>
> Envoy Gateway crée dans `envoy-gateway-system` un Deployment et un Service LoadBalancer nommés `envoy-boutique-boutique-gw-<hash>`. MetalLB donne une adresse au Service, Envoy Gateway la recopie dans `status.addresses`, et le Gateway passe `Programmed=True`. Aucune route n'est encore attachée : les deux listeners affichent `0`.
>
> **Vérification** : `kubectl -n boutique get gateway boutique-gw` affiche `PROGRAMMED True` et une adresse de la plage 192.168.49.100-120 ; `curl -s -o /dev/null -w '%{http_code}\n' --resolve gw.boutique.example:80:$GW http://gw.boutique.example/` affiche `404`, puisque le proxy répond mais qu'aucune route ne correspond.

#### Exercice 13.4 — Routes front et redirection HTTP→HTTPS

**Point de départ** : exercice 13.3.

Crée dans `boutique` la HTTPRoute `front`, attachée au seul listener `https` de `boutique-gw`, pour l'hôte `gw.boutique.example` : les requêtes portant l'en-tête `X-Version: v2` vont à `front-v2:80` ; les autres, sur `/`, vont à `front:80` avec un poids de 90 et à `front-v2:80` avec un poids de 10. Crée la HTTPRoute `redirection-https`, attachée au seul listener `http`, qui redirige tout vers HTTPS avec le code 301. Vérifie la redirection, l'en-tête, et mesure le partage sur 200 requêtes.

> [!example]- Solution
> Écris `~/cka/boutique/httproute-front.yaml` :
>
> ```yaml
> apiVersion: gateway.networking.k8s.io/v1
> kind: HTTPRoute
> metadata:
>   name: front
>   namespace: boutique
> spec:
>   parentRefs:
>   - name: boutique-gw
>     sectionName: https
>   hostnames:
>   - gw.boutique.example
>   rules:
>   - matches:
>     - headers:
>       - name: X-Version
>         value: v2
>     backendRefs:
>     - name: front-v2
>       port: 80
>   - matches:
>     - path:
>         type: PathPrefix
>         value: /
>     backendRefs:
>     - name: front
>       port: 80
>       weight: 90
>     - name: front-v2
>       port: 80
>       weight: 10
> ```
>
> et `~/cka/boutique/httproute-redirection.yaml` avec le manifeste `redirection-https` de 13.10.
>
> ```bash
> kubectl apply -f ~/cka/boutique/httproute-front.yaml -f ~/cka/boutique/httproute-redirection.yaml
> kubectl -n boutique get httproute front redirection-https \
>   -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .status.parents[*].conditions[*]}{.type}={.status} {end}{"\n"}{end}'
> GW=$(kubectl -n boutique get gateway boutique-gw -o jsonpath='{.status.addresses[0].value}')
> CA=~/cka/boutique/boutique-tls.crt
> curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' --resolve gw.boutique.example:80:$GW http://gw.boutique.example/
> curl -s --cacert $CA --resolve gw.boutique.example:443:$GW -H 'X-Version: v2' https://gw.boutique.example/
> for i in $(seq 200); do
>   curl -s --cacert $CA --resolve gw.boutique.example:443:$GW https://gw.boutique.example/ | grep -o 'v[12]'
> done | sort | uniq -c
> ```
>
> La première règle n'a qu'un en-tête ; son chemin vaut par défaut `PathPrefix /`. À chemin égal, elle l'emporte sur la seconde parce qu'elle a plus de correspondances d'en-têtes (13.8), quel que soit l'ordre des règles. Le comptage final donne environ 180 `v1` et 20 `v2` ; le tirage est aléatoire à chaque requête, l'écart de quelques unités est normal.
>
> **Vérification** : les deux routes affichent `Accepted=True ResolvedRefs=True` ; la redirection répond `301 https://gw.boutique.example/` ; la requête avec en-tête affiche `v2` ; le comptage est proche de 90/10. `kubectl -n boutique get gateway boutique-gw -o jsonpath='{range .status.listeners[*]}{.name}={.attachedRoutes} {end}'` affiche `http=1 https=1`.

#### Exercice 13.5 — La route api et la préséance

**Point de départ** : exercice 13.4.

Crée dans `boutique` la HTTPRoute `api`, attachée au listener `https` de `boutique-gw`, pour l'hôte `gw.boutique.example` : le préfixe `/api` est envoyé à `api:8080`, en remplaçant ce préfixe par `/`. Prédis puis vérifie la réponse de `/api/hostname`, de `/api/hostname` avec l'en-tête `X-Version: v2`, de `/api` et de `/apix`. Vérifie aussi la redirection de `http://gw.boutique.example/api/hostname`.

> [!example]- Solution
> Écris `~/cka/boutique/httproute-api.yaml` :
>
> ```yaml
> apiVersion: gateway.networking.k8s.io/v1
> kind: HTTPRoute
> metadata:
>   name: api
>   namespace: boutique
> spec:
>   parentRefs:
>   - name: boutique-gw
>     sectionName: https
>   hostnames:
>   - gw.boutique.example
>   rules:
>   - matches:
>     - path:
>         type: PathPrefix
>         value: /api
>     filters:
>     - type: URLRewrite
>       urlRewrite:
>         path:
>           type: ReplacePrefixMatch
>           replacePrefixMatch: /
>     backendRefs:
>     - name: api
>       port: 8080
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/httproute-api.yaml
> GW=$(kubectl -n boutique get gateway boutique-gw -o jsonpath='{.status.addresses[0].value}')
> CA=~/cka/boutique/boutique-tls.crt
> gwcurl() { curl -s --resolve gw.boutique.example:443:$GW --cacert $CA "$@"; }
> gwcurl https://gw.boutique.example/api/hostname; echo
> gwcurl -H 'X-Version: v2' https://gw.boutique.example/api/hostname; echo
> gwcurl https://gw.boutique.example/api; echo
> gwcurl -o /dev/null -w '%{http_code}\n' https://gw.boutique.example/apix
> curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' \
>   --resolve gw.boutique.example:80:$GW http://gw.boutique.example/api/hostname
> ```
>
> `/api/hostname` est réécrit en `/hostname` et renvoie le nom d'un pod `api-…`. Avec l'en-tête `X-Version: v2`, la réponse est la même : le préfixe `/api` (4 caractères) est plus long que `/` et le chemin passe avant les en-têtes. `/api` devient `/`, servi par le gestionnaire racine d'agnhost, qui répond `NOW: <date>`. `/apix` n'est pas couvert par `/api` (élément différent) : il tombe dans la règle `/` de `front`, dont nginx répond 404. En HTTP, la redirection conserve le chemin.
>
> **Vérification** : sorties attendues, dans l'ordre : `api-…`, `api-…`, `NOW: …`, `404`, `301 https://gw.boutique.example/api/hostname`. Le listener `https` compte maintenant deux routes attachées.

#### Exercice 13.6 — Une référence vers un autre namespace

**Point de départ** : exercice 13.5.

Crée le namespace `vitrine`, un Deployment `vitrine` (`nginx:1.30.6-alpine`) et son Service `vitrine` sur le port 80. Dans `boutique`, crée la HTTPRoute `vitrine`, attachée au listener `https` de `boutique-gw` pour `gw.boutique.example`, qui envoie le préfixe `/vitrine` vers le Service `vitrine` du namespace `vitrine` (port 80), en remplaçant le préfixe par `/`. Observe l'état de la route et la réponse, puis autorise la référence avec le ReferenceGrant `boutique-vers-vitrine`, limité à ce Service. Supprime ensuite la route et le namespace `vitrine`.

> [!example]- Solution
> ```bash
> kubectl create namespace vitrine
> kubectl -n vitrine create deployment vitrine --image=nginx:1.30.6-alpine
> kubectl -n vitrine expose deployment vitrine --port=80
> kubectl -n vitrine rollout status deployment vitrine
> ```
>
> Écris `~/cka/boutique/httproute-vitrine.yaml` :
>
> ```yaml
> apiVersion: gateway.networking.k8s.io/v1
> kind: HTTPRoute
> metadata:
>   name: vitrine
>   namespace: boutique
> spec:
>   parentRefs:
>   - name: boutique-gw
>     sectionName: https
>   hostnames:
>   - gw.boutique.example
>   rules:
>   - matches:
>     - path:
>         type: PathPrefix
>         value: /vitrine
>     filters:
>     - type: URLRewrite
>       urlRewrite:
>         path:
>           type: ReplacePrefixMatch
>           replacePrefixMatch: /
>     backendRefs:
>     - name: vitrine
>       namespace: vitrine
>       port: 80
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/httproute-vitrine.yaml
> kubectl -n boutique get httproute vitrine \
>   -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}) {.message}{"\n"}{end}'
> GW=$(kubectl -n boutique get gateway boutique-gw -o jsonpath='{.status.addresses[0].value}')
> CA=~/cka/boutique/boutique-tls.crt
> gwcurl() { curl -s --resolve gw.boutique.example:443:$GW --cacert $CA "$@"; }
> gwcurl -o /dev/null -w '%{http_code}\n' https://gw.boutique.example/vitrine/
> ```
>
> La route est acceptée (`Accepted=True`), mais `ResolvedRefs=False`, raison `RefNotPermitted`, et la requête reçoit `500`. Le ReferenceGrant se crée **dans `vitrine`**, le namespace de la cible. Écris `~/cka/boutique/referencegrant-vitrine.yaml` avec le manifeste de 13.12, puis :
>
> ```bash
> kubectl apply -f ~/cka/boutique/referencegrant-vitrine.yaml
> sleep 5
> kubectl -n boutique get httproute vitrine \
>   -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {end}{"\n"}'
> gwcurl https://gw.boutique.example/vitrine/ | grep -o '<title>.*</title>'
> kubectl -n boutique delete httproute vitrine
> kubectl delete namespace vitrine
> ```
>
> **Vérification** : après le ReferenceGrant, la route affiche `Accepted=True ResolvedRefs=True` et la requête renvoie `<title>Welcome to nginx!</title>`. Après le nettoyage, `kubectl -n boutique get httproute` ne liste plus que `api`, `front` et `redirection-https`, et `kubectl get ns vitrine` répond `NotFound`.

#### Exercice 13.7 — Traduire l'Ingress avec ingress2gateway

**Point de départ** : exercice 13.6.

Télécharge ingress2gateway v1.2.0 pour Linux x86_64 depuis sa page de versions GitHub, vérifie sa somme de contrôle, et range le binaire dans `~/cka/outils/`. Traduis l'Ingress `boutique` en objets Gateway API, sans rien appliquer. Explique les objets produits, et ce qu'il faudrait changer pour les appliquer sur le lab.

> [!example]- Solution
> ```bash
> mkdir -p ~/cka/outils && cd ~/cka/outils
> V=v1.2.0; U=https://github.com/kubernetes-sigs/ingress2gateway/releases/download/$V
> curl -fsSLO $U/ingress2gateway_Linux_x86_64.tar.gz
> curl -fsSLO $U/checksums.txt
> grep Linux_x86_64 checksums.txt | sha256sum -c -
> tar xzf ingress2gateway_Linux_x86_64.tar.gz ingress2gateway
> ./ingress2gateway version
> kubectl -n boutique get ingress boutique -o yaml > ingress-boutique-live.yaml
> ./ingress2gateway print --providers=ingress-nginx -n boutique \
>   --input-file=ingress-boutique-live.yaml > gateway-depuis-ingress.yaml
> grep -E '^kind:|^  name:|gatewayClassName|statusCode|sectionName' gateway-depuis-ingress.yaml
> ```
>
> L'avertissement `WARN` sur la normalisation des URL s'affiche à l'écran : il part sur la sortie d'erreur, pas dans le fichier. La sortie contient un Gateway `nginx` à quatre listeners (HTTP et HTTPS pour chacun des deux hôtes, le Secret `boutique-tls` sur les listeners HTTPS), deux HTTPRoute de redirection `RequestRedirect` en 308 attachées par `port: 80`, et deux HTTPRoute applicatives attachées par `sectionName` au listener HTTPS de leur hôte. L'outil a rendu explicite la redirection HTTP→HTTPS qu'ingress-nginx faisait implicitement. Pour appliquer ce résultat sur le lab, il faudrait remplacer `gatewayClassName: nginx` par `eg` (aucune GatewayClass `nginx` n'existe) et accepter que le nom `nginx` du Gateway soit peu parlant. On ne l'applique pas : le fil rouge a déjà son Gateway.
>
> **Vérification** : `sha256sum -c` affiche `OK` ; `./ingress2gateway version` affiche `ingress2gateway version: 1.2.0` ; `grep -c '^kind: HTTPRoute' gateway-depuis-ingress.yaml` affiche `4` ; `kubectl get gateway -A` ne liste toujours que `boutique-gw`. L'état laissé par le chapitre est Envoy Gateway, la GatewayClass `eg`, `front-v2`, le Gateway `boutique-gw` et les HTTPRoute `front`, `api` et `redirection-https`.

---
