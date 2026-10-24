---
title: "CKA — 12. Ingress et contrôleurs d'Ingress"
description: "L'API Ingress en profondeur : rôle du contrôleur, IngressClass, règles et pathType, defaultBackend, TLS, annotations propres au contrôleur, kubectl create ingress, retrait d'ingress-nginx et dépannage, appliqués à la boutique."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 12. Ingress et contrôleurs d'Ingress

Un Service de type NodePort ou LoadBalancer expose un port TCP ou UDP : il ne sait rien de HTTP. Dès qu'il faut publier plusieurs applications web derrière une seule adresse, les répartir selon le nom d'hôte ou le chemin de l'URL, ou terminer TLS en un point unique, il faut un objet qui parle HTTP. C'est le rôle de l'**Ingress**, une API stable depuis Kubernetes 1.19, et du **contrôleur d'Ingress** qui la met en œuvre. Ce chapitre décortique l'objet champ par champ, explique la correspondance exacte des chemins (`pathType`), le backend par défaut, la terminaison TLS, les annotations propres à chaque contrôleur, la syntaxe de `kubectl create ingress` qui fait gagner de précieuses minutes à l'examen, et la méthode de dépannage. Il fait aussi le point sur le **retrait du projet ingress-nginx**, effectif le 24 mars 2026, et sur ce qu'il change, ou ne change pas, pour le CKA. La compétence officielle visée est *Know how to use Ingress controllers and Ingress resources*, dans le domaine *Services and Networking* (20 %) ; le dépannage relève aussi de *Troubleshoot services and networking*. À la fin du chapitre, la boutique est joignable en HTTPS sur `boutique.example` et `api.boutique.example`.

### 12.1 Le besoin : router en couche 7

Reprends l'état du fil rouge à la fin du [chapitre 10](10-services.md). `front` est publié en NodePort sur le port 30080 de chaque nœud et par le Service `front-lb`, auquel MetalLB a donné une adresse de la plage 192.168.49.100-120. Cela fonctionne, mais chaque application exposée consomme un port de nœud ou une adresse externe, le client doit connaître ce port, et chaque application doit gérer elle-même son certificat TLS. Le Service travaille en couche 4 : il voit des adresses et des ports, jamais un en-tête `Host` ni une URL.

L'Ingress se place un étage au-dessus. Un seul point d'entrée (une adresse, les ports 80 et 443) reçoit toutes les requêtes HTTP et HTTPS ; un proxy inverse lit l'en-tête `Host` et le chemin de chaque requête, choisit un Service, termine TLS au passage, et transmet la requête en clair au pod choisi. C'est l'hébergement virtuel par nom bien connu des serveurs web, piloté par l'API Kubernetes.

```
DU SERVICE À L'INGRESS
══════════════════════

  Couche 4 (chapitre 10) : un port par application
  ─────────────────────────────────────────────────
    client ──▶ 192.168.49.2:30080 ──▶ Service front ──▶ pods front
    client ──▶ 192.168.49.2:3xxxx ──▶ Service api   ──▶ pods api

  Couche 7 (ce chapitre) : une entrée, un routage par hôte et chemin
  ───────────────────────────────────────────────────────────────────
                                   ┌─ Host: boutique.example     ──▶ pods front
    client ──▶ 192.168.49.2:443 ──▶│
               (TLS terminé ici)   └─ Host: api.boutique.example ──▶ pods api
```

L'Ingress ne gère que HTTP et HTTPS. Pour exposer une base de données, un flux gRPC sur un port arbitraire ou du TCP brut, il reste le Service NodePort ou LoadBalancer, ou les routes TCP, UDP et TLS de la Gateway API (chapitre 13).

### 12.2 L'objet et le contrôleur : qui fait quoi

Un Ingress est une **déclaration** : « les requêtes pour tel hôte et tel chemin vont à tel Service ». À lui seul, il ne fait rien. La documentation le dit sans ambiguïté : créer une ressource Ingress sans contrôleur n'a aucun effet. Aucun composant du control plane ne lit les Ingress ; kube-proxy les ignore. Il faut un **contrôleur d'Ingress**, un logiciel tiers qui tourne en pods dans le cluster, surveille l'API et traduit les Ingress en configuration de son proxy (nginx, Envoy, HAProxy, Traefik…).

```
LE CHEMIN D'UNE REQUÊTE À TRAVERS UN INGRESS
════════════════════════════════════════════

   kube-apiserver
   ┌─────────────────────────────────────────────┐
   │ Ingress, IngressClass, Services,            │
   │ EndpointSlices, Secrets (TLS)               │
   └───────────────┬─────────────────────────────┘
                   │ watch
                   ▼
   ┌─────────────────────────────────────────────┐
   │ pod contrôleur (ex. ingress-nginx)          │
   │  1. lit les Ingress de SA classe            │
   │  2. résout chaque Service en adresses de    │
   │     pods via les EndpointSlices             │
   │  3. génère nginx.conf et le recharge        │
   │  4. écrit status.loadBalancer de l'Ingress  │
   └───────────────┬─────────────────────────────┘
                   │ proxy HTTP
   client ─────────┘
     │  GET / Host: boutique.example
     ▼
   pod contrôleur ──────────▶ 10.244.x.y:80 (pod front, en direct)
                    pas de passage par l'IP virtuelle du Service
```

Le dernier point du schéma a des conséquences pratiques. Le contrôleur ingress-nginx n'envoie pas les requêtes à l'adresse ClusterIP du Service : il lit les EndpointSlices et répartit lui-même la charge entre les adresses des pods. Le Service sert d'annuaire, pas de relais. Il en découle trois faits utiles. Un Service sans endpoint prêt (sélecteur faux, pods non prêts) donne une erreur 503 du contrôleur et non un refus de connexion. Le `sessionAffinity` du Service est sans effet sur le trafic venu de l'Ingress. Et une NetworkPolicy qui protège les pods doit autoriser la source réelle, c'est-à-dire les pods du contrôleur dans leur namespace (chapitre 14).

Le contrôleur publie l'adresse par laquelle il est joignable dans `status.loadBalancer.ingress` de chaque Ingress qu'il prend en charge. C'est la colonne `ADDRESS` de `kubectl get ingress`. Une colonne vide plus d'une minute après la création est le premier signe qu'**aucun contrôleur ne s'est reconnu** dans l'objet (section 12.13).

### 12.3 Le retrait d'ingress-nginx

Pendant dix ans, le contrôleur le plus répandu a été **ingress-nginx**, maintenu par le projet Kubernetes lui-même dans le dépôt `kubernetes/ingress-nginx`. Ce n'est plus le cas, et il faut connaître les dates exactes.

```
CHRONOLOGIE DU RETRAIT D'INGRESS-NGINX
══════════════════════════════════════

  11 nov. 2025 ── annonce « Ingress NGINX Retirement: What You Need to Know »
       │          (blog kubernetes.io) : maintenance au mieux jusqu'en mars 2026
       │
  29 janv. 2026 ─ déclaration du Steering Committee et du Security
       │          Response Committee : le retrait est confirmé
       │
  19 mars 2026 ── dernières versions : contrôleur v1.15.1 (et v1.14.5,
       │          v1.13.9), chart Helm 4.15.1
       │
  20 mars 2026 ── ingress2gateway 1.0 (outil de migration, chapitre 13.13)
       │
  24 mars 2026 ── RETRAIT EFFECTIF : dépôt archivé en lecture seule.
                  Plus aucune version, plus aucun correctif,
                  y compris de sécurité.
```

Ce que le retrait change : un cluster qui fait tourner ingress-nginx continue de fonctionner, les images et les charts restent téléchargeables, mais toute vulnérabilité découverte après le 24 mars 2026 restera ouverte. Le projet recommande de migrer vers la **Gateway API** (chapitre 13) ou vers un autre contrôleur d'Ingress maintenu. Pour repérer les installations concernées, le projet donne cette commande :

```bash
kubectl get pods --all-namespaces --selector app.kubernetes.io/name=ingress-nginx
```

Ce que le retrait ne change pas : **l'API Ingress**. Elle reste GA dans Kubernetes 1.37, soumise aux garanties de stabilité des API GA, et le projet n'a aucun projet de la supprimer. Elle est en revanche **gelée** : plus aucune évolution ne lui sera apportée, et la documentation recommande désormais Gateway plutôt qu'Ingress. Le programme CKA v1.37 contient toujours *Know how to use Ingress controllers and Ingress resources*. À l'examen, tu écris des objets Ingress standard ; le contrôleur qui les sert est celui que fournit l'environnement, et l'énoncé te donne la classe à utiliser.

| Sujet | Avant le retrait | Depuis le 24 mars 2026 |
|---|---|---|
| API `networking.k8s.io/v1` Ingress, IngressClass | GA | GA, gelée, aucune suppression prévue |
| Champs standard (`rules`, `pathType`, `tls`, `defaultBackend`) | identiques | identiques : tout ce chapitre reste valable |
| Contrôleur ingress-nginx | maintenu par le projet Kubernetes | archivé, sans correctif ; fonctionne encore |
| Annotations `nginx.ingress.kubernetes.io/*` | propres à ingress-nginx | propres à ingress-nginx, à migrer |
| Recommandation du projet | Ingress ou Gateway | Gateway API |

> [!warning] Deux « NGINX » différents
> **ingress-nginx** (dépôt `kubernetes/ingress-nginx`, IngressClass habituelle `nginx`, contrôleur `k8s.io/ingress-nginx`) est le projet retiré. Le **NGINX Ingress Controller** édité par F5 est un autre logiciel, toujours maintenu, qui figure dans la liste des contrôleurs de kubernetes.io. Leurs annotations ne sont pas compatibles. Ne les confonds pas en lisant une documentation.

> [!info] minikube ≠ examen
> minikube v1.39.0 installe toujours ingress-nginx **v1.15.1** par l'addon `ingress`, sans avertissement de dépréciation, et propose un nouvel addon `traefik`. Ce cours garde l'addon `ingress` : l'API qu'on y pratique est exactement celle de l'examen, et l'Ingress `boutique` servira de point de départ à la migration vers la Gateway API au chapitre 13. Sur le cluster de l'examen, vérifie toujours la classe disponible avec `kubectl get ingressclass` avant d'écrire un Ingress.

### 12.4 Anatomie d'un Ingress

Voici l'arbre complet de la spécification d'un Ingress `networking.k8s.io/v1`. Il est court : c'est tout ce que l'API standard sait exprimer.

```
Ingress (networking.k8s.io/v1, namespacé)
═════════════════════════════════════════
spec
├── ingressClassName ........ nom d'une IngressClass (12.5)
├── defaultBackend .......... backend des requêtes sans règle applicable (12.7)
│   ├── service
│   │   ├── name
│   │   └── port.number | port.name      (l'un OU l'autre)
│   └── resource ............ référence typée (apiGroup, kind, name),
│                             exclusive de service
├── tls[] ................... terminaison TLS (12.8)
│   ├── hosts[]
│   └── secretName .......... Secret kubernetes.io/tls du MÊME namespace
└── rules[]
    ├── host ................ nom DNS (jokers « *. » admis), jamais une IP
    └── http
        └── paths[]
            ├── path ........ chemin absolu
            ├── pathType .... Exact | Prefix | ImplementationSpecific
            │                 (OBLIGATOIRE)
            └── backend ..... même structure que defaultBackend
status
└── loadBalancer.ingress[] .. ip | hostname (+ ports), écrit par le contrôleur
```

Le serveur d'API valide plusieurs règles qu'il faut connaître, parce qu'un message de refus tombe vite à l'examen et qu'il vaut mieux savoir le lire. Un Ingress doit porter des `rules` ou un `defaultBackend` (« either `defaultBackend` or `rules` must be specified »). Chaque chemin doit avoir un `pathType` (« pathType must be specified ») ; pour `Exact` et `Prefix`, le chemin doit commencer par `/` et ne peut contenir ni `//`, ni `/./`, ni `/../`, ni `%2f`, ni finir par `/.` ou `/..`. Le `host` est un nom DNS valide, jamais une adresse IP (« must be a DNS name, not an IP address »). Un backend désigne soit un Service, soit une ressource, jamais les deux, et pour un Service soit un port par numéro, soit un port par nom, jamais les deux. Enfin, si l'ancienne annotation `kubernetes.io/ingress.class` et le champ `ingressClassName` sont présents à la création, ils doivent concorder.

Le port d'un backend est le port **du Service** (`spec.ports[].port` ou `spec.ports[].name`), pas celui du conteneur. Dans le fil rouge, le Service `api` expose le port 8080, nommé `http`, vers le `targetPort` `http` des pods : `port.number: 8080` et `port.name: http` y sont équivalents. Pour `front`, dont le port 80 n'a pas de nom, seul `port.number: 80` convient.

> [!tip] Réflexe d'examen
> `kubectl explain ingress.spec.rules.http.paths` affiche les champs et leur documentation sans quitter le terminal ; ajoute `--recursive` pour voir tout l'arbre d'un coup. La page à ouvrir dans la documentation autorisée est *Concepts → Services, Load Balancing, and Networking → Ingress* (`kubernetes.io/docs/concepts/services-networking/ingress/`) : elle contient des exemples complets à copier, dont un Ingress TLS.

### 12.5 IngressClass et classe par défaut

Plusieurs contrôleurs peuvent cohabiter dans un cluster. Pour qu'un Ingress soit pris en charge par le bon, chaque contrôleur se déclare par une **IngressClass**, objet de portée cluster :

```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
  annotations:
    ingressclass.kubernetes.io/is-default-class: "true"
spec:
  controller: k8s.io/ingress-nginx
```

Le champ `spec.controller` identifie le logiciel (une chaîne préfixée par un domaine, 250 caractères au plus) ; il est **immuable**. Chaque contrôleur ne traite que les Ingress dont `spec.ingressClassName` désigne une classe portant **son** nom de contrôleur. Le champ facultatif `spec.parameters` pointe vers une ressource de configuration propre au contrôleur, de portée `Cluster` (défaut) ou `Namespace` (il faut alors préciser `namespace`).

La **classe par défaut** se désigne par l'annotation `ingressclass.kubernetes.io/is-default-class: "true"`. Le mécanisme qui l'applique est le contrôleur d'admission **DefaultIngressClass**, activé par défaut dans kube-apiserver 1.37 : à la **création** d'un Ingress sans `ingressClassName`, il écrit dans le champ le nom de la classe par défaut. Trois conséquences en découlent. Il n'agit qu'à la création, jamais à la mise à jour : changer de classe par défaut ne déplace pas les Ingress existants. S'il n'existe aucune classe par défaut, l'Ingress reste sans classe, et seuls les contrôleurs configurés pour accepter les Ingress sans classe le prendront. S'il existe **plusieurs** classes marquées par défaut, la création de tout Ingress sans classe est **refusée** ; il faut retirer l'annotation de toutes les classes sauf une.

L'annotation `kubernetes.io/ingress.class` est l'ancien mécanisme, antérieur à Kubernetes 1.18. Elle n'a jamais été formellement définie et désignait le nom d'un contrôleur, quand le champ désigne un objet IngressClass. Ne l'utilise plus ; sache seulement la reconnaître dans un manifeste ancien.

> [!info] minikube ≠ examen
> L'addon `ingress` crée l'IngressClass `nginx` (contrôleur `k8s.io/ingress-nginx`), marquée par défaut, et lance le contrôleur avec l'option `--watch-ingress-without-class=true` : un Ingress sans classe y est donc pris en charge de deux façons, puisque l'admission lui attribue la classe `nginx` et que le contrôleur accepterait de toute façon un Ingress sans classe. Sur un cluster d'examen, il peut n'exister aucune classe par défaut. Écris **toujours** `ingressClassName` (ou `--class` avec `kubectl create ingress`) : c'est explicite et le correcteur le vérifie souvent.

### 12.6 Règles, hôtes et pathType

#### Les hôtes

Chaque élément de `rules` peut porter un `host`. Sans `host`, la règle s'applique à toute requête qui arrive sur l'adresse du contrôleur, quel que soit l'en-tête `Host`. Avec un `host` précis, l'en-tête `Host` doit lui être égal. Avec un joker, `*.boutique.example`, l'en-tête doit avoir exactement un label de plus : le joker couvre **un seul** label DNS.

| `host` | En-tête `Host` | Correspond ? |
|---|---|---|
| `*.boutique.example` | `api.boutique.example` | oui, suffixe commun |
| `*.boutique.example` | `v2.api.boutique.example` | non, le joker ne couvre qu'un label |
| `*.boutique.example` | `boutique.example` | non, le joker ne couvre qu'un label |

L'hôte et le chemin doivent **tous deux** correspondre pour que la règle s'applique.

#### Les trois pathType

Chaque chemin porte obligatoirement un `pathType`. Un manifeste sans `pathType` est refusé : c'est l'une des erreurs les plus fréquentes quand on recopie un vieil exemple écrit pour l'API `v1beta1`, qui n'est plus servie depuis Kubernetes 1.22.

- **`Exact`** : le chemin de l'URL doit être égal au chemin déclaré, à la casse près. `/foo` ne correspond ni à `/foo/`, ni à `/Foo`.
- **`Prefix`** : correspondance par **éléments** de chemin, séparés par `/`, sensible à la casse. Une requête correspond au préfixe *p* si les éléments de *p* sont, un à un, les premiers éléments du chemin demandé. Une barre oblique finale est ignorée, des deux côtés.
- **`ImplementationSpecific`** : l'interprétation revient à la classe d'Ingress. Le contrôleur peut le traiter comme `Prefix`, comme `Exact`, ou autrement ; ingress-nginx s'en sert pour les expressions régulières (12.9).

Le point qui fait échouer les candidats est la phrase « par éléments ». Un préfixe n'est **pas** un préfixe de chaîne de caractères : `Prefix /aaa/bb` ne correspond pas à `/aaa/bbb`, parce que le dernier élément `bb` n'est pas égal à `bbb`. La table de la documentation officielle mérite d'être connue par cœur :

| Type | Chemin(s) déclaré(s) | Chemin demandé | Correspond ? |
|---|---|---|---|
| Prefix | `/` | tous | oui |
| Exact | `/foo` | `/foo` | oui |
| Exact | `/foo` | `/bar` | non |
| Exact | `/foo` | `/foo/` | non |
| Exact | `/foo/` | `/foo` | non |
| Prefix | `/foo` | `/foo`, `/foo/` | oui |
| Prefix | `/foo/` | `/foo`, `/foo/` | oui |
| Prefix | `/aaa/bb` | `/aaa/bbb` | non |
| Prefix | `/aaa/bbb` | `/aaa/bbb` | oui |
| Prefix | `/aaa/bbb/` | `/aaa/bbb` | oui, barre finale ignorée |
| Prefix | `/aaa/bbb` | `/aaa/bbb/` | oui, barre finale acceptée |
| Prefix | `/aaa/bbb` | `/aaa/bbb/ccc` | oui, sous-chemin |
| Prefix | `/aaa/bbb` | `/aaa/bbbxyz` | non, pas un préfixe de chaîne |
| Prefix | `/`, `/aaa` | `/aaa/ccc` | oui, par `/aaa` |
| Prefix | `/`, `/aaa`, `/aaa/bbb` | `/aaa/bbb` | oui, par `/aaa/bbb` |
| Prefix | `/`, `/aaa`, `/aaa/bbb` | `/ccc` | oui, par `/` |
| Prefix | `/aaa` | `/ccc` | non, backend par défaut |
| Mixte | `/foo` (Prefix), `/foo` (Exact) | `/foo` | oui, l'Exact l'emporte |

#### La préséance

Quand plusieurs chemins d'un Ingress correspondent à une requête, la règle officielle est simple : **le chemin le plus long l'emporte** ; à longueur égale, un chemin `Exact` l'emporte sur un chemin `Prefix`. L'ordre d'écriture dans le manifeste ne compte pas. C'est ce qui permet de déclarer `/` vers `front` et `/api` vers `api` sans se soucier de l'ordre : `/api/hostname` va à `api` parce que `/api` est plus long que `/`.

L'API ne dit rien de la fusion de **plusieurs** Ingress : c'est le contrôleur qui décide. ingress-nginx fusionne toutes les règles d'un même hôte, quel que soit l'Ingress qui les déclare, dans un même bloc `server` ; deux Ingress qui déclarent le même hôte et le même chemin entrent alors en conflit, et l'issue dépend de règles propres au contrôleur. Évite ce cas : un hôte, un Ingress, sauf raison précise.

### 12.7 defaultBackend et trafic non routé

Une requête qui ne correspond à aucune règle, ni par l'hôte ni par le chemin, part vers le **backend par défaut**. Il y en a deux niveaux. Le champ `spec.defaultBackend` d'un Ingress en définit un pour cet Ingress ; un Ingress peut même ne contenir que lui, sans aucune règle, et envoyer tout son trafic à un seul Service. La documentation note cependant que le backend par défaut est d'ordinaire une option **du contrôleur**, et non un champ qu'on renseigne dans chaque Ingress. Sans `defaultBackend`, le traitement des requêtes non routées appartient au contrôleur.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: tout-vers-front
  namespace: boutique
spec:
  ingressClassName: nginx
  defaultBackend:
    service:
      name: front
      port:
        number: 80
```

ingress-nginx répond **404** à une requête dont l'hôte n'est déclaré nulle part : c'est son backend par défaut intégré. Sur le lab, `curl http://192.168.49.2/` sans en-tête `Host` connu renvoie 404, ce qui prouve que le contrôleur répond et que c'est le routage qui ne trouve rien. Un 404 n'est donc pas une panne du contrôleur : c'est un hôte ou un chemin qui ne correspond pas.

> [!note] Ingress sans règle et `kubectl create ingress`
> `kubectl create ingress tout-vers-front --class=nginx --default-backend=front:80` produit exactement le manifeste ci-dessus. kubectl refuse un Ingress qui n'a ni règle ni backend par défaut, avec le même raisonnement que l'API.

### 12.8 TLS

L'Ingress termine TLS au contrôleur. Le trafic entre le contrôleur et les pods reste en clair : c'est l'hypothèse de l'API. Le certificat et la clé vivent dans un **Secret de type `kubernetes.io/tls`**, avec les clés `tls.crt` et `tls.key`, dans **le même namespace que l'Ingress** : le champ `secretName` n'a pas de namespace. Le seul port TLS prévu par l'API est 443.

```yaml
spec:
  tls:
  - hosts:
    - boutique.example
    - api.boutique.example
    secretName: boutique-tls
  rules:
  - host: boutique.example
    # …
```

Les `hosts` de la section `tls` doivent correspondre aux `host` des règles : TLS ne s'applique pas à une règle sans hôte, puisqu'il faudrait un certificat valable pour tous les noms possibles. Plusieurs entrées `tls` avec des Secrets différents sont servies sur le même port 443 et départagées par **SNI**, l'extension TLS par laquelle le client annonce le nom qu'il demande. C'est pourquoi un test TLS doit envoyer le bon nom : `curl --resolve boutique.example:443:192.168.49.2 https://boutique.example/` le fait, `curl -k https://192.168.49.2/` ne le fait pas.

On crée le Secret à partir des fichiers PEM avec le générateur dédié, plus sûr que d'écrire du base64 à la main :

```bash
kubectl -n boutique create secret tls boutique-tls \
  --cert=boutique-tls.crt --key=boutique-tls.key
```

Deux comportements d'ingress-nginx sont à connaître, parce qu'ils surprennent pendant les tests. D'abord, dès qu'un hôte a une section TLS, le contrôleur **redirige HTTP vers HTTPS** avec un code **308** (option `ssl-redirect`, vraie par défaut ; l'annotation `nginx.ingress.kubernetes.io/ssl-redirect: "false"` la désactive pour un Ingress). Ensuite, si le Secret est introuvable, dans un autre namespace, ou ne couvre pas le nom demandé, le contrôleur ne refuse pas la connexion : il présente son certificat autosigné par défaut, dont le sujet est `CN=Kubernetes Ingress Controller Fake Certificate, O=Acme Co`. Un client qui vérifie le certificat échoue alors avec une erreur de vérification, ce qui oriente le diagnostic vers le Secret.

```
CE QUE VOIT LE CLIENT SELON LE CAS (ingress-nginx)
══════════════════════════════════════════════════

  http://boutique.example/          ──▶ 308, Location: https://boutique.example/
  https://boutique.example/         ──▶ certificat boutique-tls, 200
  https://inconnu.example/          ──▶ certificat « Fake Certificate », 404
  Secret absent ou mal nommé        ──▶ certificat « Fake Certificate »,
                                        curl : erreur de vérification
```

### 12.9 Annotations propres au contrôleur

L'API Ingress est volontairement minimale : hôte, chemin, backend, TLS. Tout le reste (réécriture d'URL, taille maximale du corps, délais, affinité de session, authentification, protocole vers le backend, redirections) passe par des **annotations** que chaque contrôleur définit à sa façon. C'est la principale faiblesse de l'Ingress : un manifeste chargé d'annotations n'est plus portable, et il faut les traduire une à une en changeant de contrôleur. La Gateway API (chapitre 13) intègre l'essentiel de ces fonctions dans des champs typés.

Pour ingress-nginx, les annotations commencent par `nginx.ingress.kubernetes.io/`. Les plus courantes :

| Annotation | Effet |
|---|---|
| `nginx.ingress.kubernetes.io/rewrite-target` | réécrit le chemin transmis au backend (avec groupes de capture) |
| `nginx.ingress.kubernetes.io/use-regex` | interprète les chemins comme expressions régulières (défaut `false`) |
| `nginx.ingress.kubernetes.io/ssl-redirect` | redirection HTTP→HTTPS quand l'Ingress a du TLS (défaut vrai) |
| `nginx.ingress.kubernetes.io/force-ssl-redirect` | redirection vers HTTPS même sans section TLS |
| `nginx.ingress.kubernetes.io/backend-protocol` | protocole vers les pods (`HTTP`, `HTTPS`, `GRPC`…) |
| `nginx.ingress.kubernetes.io/proxy-body-size` | taille maximale du corps des requêtes |

La réécriture est le cas d'école. Une application qui sert `/hostname` doit être publiée sous `/v1/hostname` : sans réécriture, le pod reçoit `/v1/hostname` et répond 404. Avec ingress-nginx, on capture la suite du chemin par une expression régulière et on la réinjecte :

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-v1
  namespace: boutique
  annotations:
    nginx.ingress.kubernetes.io/use-regex: "true"
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
  - host: essai.boutique.example
    http:
      paths:
      - path: /v1(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service:
            name: api
            port:
              number: 8080
```

`/v1` devient `/`, `/v1/` devient `/`, `/v1/hostname` devient `/hostname`. Le chemin est une expression régulière : il doit être en `ImplementationSpecific`. ingress-nginx v1.15 active par défaut l'option `strict-validate-path-type` : son webhook d'admission **refuse** un Ingress dont un chemin `Exact` ou `Prefix` contient autre chose que des lettres, des chiffres, `/`, `-` et `_`. Le message vient alors du webhook `validate.nginx.ingress.kubernetes.io`, pas du serveur d'API. Retiens aussi que dès qu'un Ingress d'un hôte utilise `rewrite-target`, ingress-nginx impose le modificateur d'expression régulière à **tous** les chemins de cet hôte, y compris ceux des autres Ingress : c'est une raison de plus pour tester ce genre d'annotation sur un hôte dédié, comme `essai.boutique.example` ici.

> [!warning] Une annotation mal orthographiée ne produit aucune erreur
> Les annotations sont des chaînes libres. `nginx.ingress.kubernetes.io/rewrite-targer` est acceptée par l'API et ignorée par le contrôleur. Quand un comportement attendu n'apparaît pas, relis la clé caractère par caractère avant de chercher ailleurs. ingress-nginx refuse en revanche les annotations de « snippet » (`allow-snippet-annotations` est faux par défaut) et celles dont le niveau de risque dépasse `annotations-risk-level`.

### 12.10 kubectl create ingress : la voie rapide

À l'examen, écrire un Ingress à la main prend du temps et invite aux erreurs d'indentation. Le générateur impératif produit le manifeste en une ligne. Sa syntaxe tient en un motif :

```
kubectl create ingress NOM --class=CLASSE \
  --rule="HÔTE/CHEMIN=SERVICE:PORT[,tls[=SECRET]]" [--rule=…] \
  [--default-backend=SERVICE:PORT] [--annotation=CLÉ=VALEUR]
```

Les détails de l'analyse, lus dans le code de kubectl 1.37, font toute la différence :

| Élément de `--rule` | Règle |
|---|---|
| `HÔTE` | facultatif : `--rule="/api*=api:8080"` crée une règle sans hôte ; joker admis (`*.boutique.example`) |
| `/CHEMIN` | obligatoire, commence par `/` ; la première `/` sépare l'hôte du chemin |
| `*` final | `pathType: Prefix`, et l'étoile est retirée du chemin |
| sans `*` final | `pathType: Exact` |
| `SERVICE:PORT` | port numérique → `port.number`, port alphabétique → `port.name` (nom du port **du Service**) |
| `,tls` | entrée TLS pour cet hôte, sans `secretName` (certificat par défaut du contrôleur) |
| `,tls=SECRET` | entrée TLS avec ce Secret ; les hôtes partageant un même Secret sont regroupés dans une seule entrée |

Plusieurs `--rule` sur le même hôte ajoutent des chemins à la même règle. Le piège majeur est celui de l'étoile : `--rule="boutique.example/=front:80"` produit un chemin `/` **`Exact`**, qui ne sert que la page d'accueil et renvoie 404 pour `/style.css`. Pour « tout le site », il faut `--rule="boutique.example/*=front:80"`. Vérifie toujours le `pathType` produit en passant d'abord par `--dry-run=client -o yaml`.

L'Ingress de la boutique s'écrit ainsi :

```bash
kubectl -n boutique create ingress boutique --class=nginx \
  --rule="boutique.example/*=front:80,tls=boutique-tls" \
  --rule="api.boutique.example/*=api:8080,tls=boutique-tls" \
  --dry-run=client -o yaml > ~/cka/boutique/ingress-boutique.yaml
```

Le manifeste produit (kubectl 1.37.1) :

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: boutique
  namespace: boutique
spec:
  ingressClassName: nginx
  rules:
  - host: boutique.example
    http:
      paths:
      - backend:
          service:
            name: front
            port:
              number: 80
        path: /
        pathType: Prefix
  - host: api.boutique.example
    http:
      paths:
      - backend:
          service:
            name: api
            port:
              number: 8080
        path: /
        pathType: Prefix
  tls:
  - hosts:
    - boutique.example
    - api.boutique.example
    secretName: boutique-tls
status:
  loadBalancer: {}
```

Les deux hôtes partagent `boutique-tls` : kubectl les a regroupés dans une seule entrée `tls`. Pour un besoin que le générateur ne couvre pas (`ImplementationSpecific`, backend `resource`, `parameters`), génère la base puis édite le fichier.

> [!tip] Réflexe d'examen
> `kubectl create ingress --help` affiche huit exemples prêts à adapter, dont la syntaxe `tls=` et `--default-backend`. C'est plus rapide que d'ouvrir la documentation. Après création, vérifie en une commande le résultat qui compte : `kubectl get ingress NOM -o jsonpath='{.spec.rules[*].http.paths[*].pathType}'`.

### 12.11 Le contrôleur du lab : l'addon ingress de minikube

L'addon s'active en une commande (1 min 18 s mesurée à la première activation, téléchargement des images compris ; la commande attend que le contrôleur soit prêt) :

```bash
minikube -p cka addons enable ingress
```

Il installe ingress-nginx v1.15.1 et kube-webhook-certgen v1.6.9 dans le namespace `ingress-nginx`. Les objets créés sont les suivants :

| Objet | Rôle |
|---|---|
| Deployment `ingress-nginx-controller` (1 réplica) | le proxy nginx et la boucle de contrôle |
| Jobs `ingress-nginx-admission-create` et `-patch` | génèrent le certificat du webhook et l'injectent |
| Service `ingress-nginx-controller` (NodePort, ports 80 et 443 vers des nodePorts aléatoires) | accès par n'importe quel nœud |
| Service `ingress-nginx-controller-admission` (ClusterIP 443) | webhook de validation des Ingress |
| IngressClass `nginx`, contrôleur `k8s.io/ingress-nginx`, classe par défaut | rattachement des Ingress |

Le contrôleur est épinglé au nœud control plane par `nodeSelector: minikube.k8s.io/primary: "true"` et publie les **`hostPort` 80 et 443** : le nœud `cka` (192.168.49.2) répond donc directement sur les ports 80 et 443, ce qui donne une adresse stable au lab. C'est cette adresse que le chapitre 11 a placée dans le bloc `hosts` du Corefile pour `boutique.example` et `api.boutique.example`. Les workers n'ont pas de `hostPort` : `curl http://192.168.49.3/` échoue, alors que le NodePort du Service répond sur tous les nœuds.

```
L'ADDON INGRESS DANS LE LAB
═══════════════════════════

  poste (192.168.49.1)
     │  https://boutique.example  (résolu en 192.168.49.2)
     ▼
  ┌──────────────────────── nœud cka 192.168.49.2 ────────────────────────┐
  │  hostPort 80/443 (plugin CNI portmap)                                 │
  │     │                                                                 │
  │     ▼                                                                 │
  │  pod ingress-nginx-controller (namespace ingress-nginx, IP 10.244.x)  │
  └─────┬──────────────────────────────────────────────────────────────────┘
        │ HTTP en clair, vers les IP des pods (EndpointSlices)
        ├──────────▶ pods front (cka, cka-m02, cka-m03)
        └──────────▶ pods api
```

Le pod du contrôleur n'est pas en `hostNetwork` avec containerd (l'addon ne l'active que pour CRI-O) : il a une adresse du réseau des pods, et c'est elle que verront les pods `front` et `api` comme adresse source. Le chapitre 14 en tient compte.

> [!info] minikube ≠ examen
> Dans le lab, l'Ingress est joignable sur 192.168.49.2, ports 80 et 443, grâce aux `hostPort`. Sur un cluster d'examen, le contrôleur est le plus souvent exposé par un Service NodePort ou LoadBalancer : l'adresse à tester est alors celle d'un nœud avec le nodePort, ou l'adresse externe du Service. `kubectl -n <namespace-du-contrôleur> get svc` te le dit en une ligne, et la colonne `ADDRESS` de l'Ingress indique ce que le contrôleur publie.

### 12.12 L'Ingress de la boutique

Le fil rouge expose deux hôtes : `boutique.example` vers `front:80`, `api.boutique.example` vers `api:8080`, tous deux en HTTPS avec le Secret `boutique-tls`, un certificat autosigné valable pour `boutique.example` et `*.boutique.example`. Le joker couvrira aussi `gw.boutique.example` au chapitre 13.

Le certificat se fabrique avec openssl. Les clients modernes, curl compris, ignorent le CN et ne regardent que l'extension `subjectAltName` : elle est indispensable.

```bash
cd ~/cka/boutique
openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
  -keyout boutique-tls.key -out boutique-tls.crt \
  -subj "/CN=boutique.example" \
  -addext "subjectAltName=DNS:boutique.example,DNS:*.boutique.example"
openssl x509 -in boutique-tls.crt -noout -subject -ext subjectAltName
```

```
subject=CN=boutique.example
X509v3 Subject Alternative Name: 
    DNS:boutique.example, DNS:*.boutique.example
```

`-nodes` laisse la clé privée en clair, ce qu'exige un Secret TLS (OpenSSL 3 accepte aussi `-noenc`, son nouveau nom). L'option `-addext` existe depuis OpenSSL 1.1.1.

Une fois le Secret et l'Ingress créés, l'état se lit en deux commandes :

```bash
kubectl -n boutique get ingress boutique
```

```
NAME       CLASS   HOSTS                                   ADDRESS        PORTS     AGE
boutique   nginx   boutique.example,api.boutique.example   192.168.49.2   80, 443   2m
```

La colonne `PORTS` vaut `80, 443` dès qu'une section `tls` existe. `ADDRESS` reste vide pendant les premières dizaines de secondes, le temps que le contrôleur traite l'objet et écrive son statut.

```bash
kubectl -n boutique describe ingress boutique
```

```
Name:             boutique
Labels:           <none>
Namespace:        boutique
Address:          192.168.49.2
Ingress Class:    nginx
Default backend:  <default>
TLS:
  boutique-tls terminates boutique.example,api.boutique.example
Rules:
  Host                  Path  Backends
  ----                  ----  --------
  boutique.example
                        /   front:80 (10.244.142.70:80,10.244.195.200:80,10.244.34.135:80)
  api.boutique.example
                        /   api:8080 (10.244.195.201:8080,10.244.34.136:8080)
Annotations:            <none>
Events:
  Type    Reason  Age   From                      Message
  ----    ------  ----  ----                      -------
  Normal  Sync    2m    nginx-ingress-controller  Scheduled for sync
```

`describe` est la commande de diagnostic par excellence : pour chaque backend, il affiche entre parenthèses les adresses des pods prêts trouvées dans les EndpointSlices, ou une erreur si le Service n'existe pas. Les adresses de pods ci-dessus sont des exemples : les tiennes diffèrent.

Les tests se font depuis le poste avec `curl --resolve`, qui force la résolution d'un nom vers une adresse tout en envoyant le bon `Host` et le bon SNI, sans toucher à `/etc/hosts` :

```bash
IP=$(minikube -p cka ip)
CA=~/cka/boutique/boutique-tls.crt
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  --resolve boutique.example:80:$IP http://boutique.example/
curl -s --cacert $CA --resolve boutique.example:443:$IP https://boutique.example/
curl -s --cacert $CA --resolve api.boutique.example:443:$IP https://api.boutique.example/hostname
curl -s --cacert $CA --resolve boutique.example:443:$IP https://boutique.example/api/hostname
```

```
308 https://boutique.example/
<h1>Boutique</h1><p>v1</p>
api-7d9c5b8f6-x2klm
api-7d9c5b8f6-q8rtn
```

La première requête montre la redirection 308 d'ingress-nginx. La deuxième sert la page de la ConfigMap `front-html` (chapitre 6). La troisième atteint `api` par son propre hôte. La quatrième passe par `front`, dont la configuration nginx relaie `/api/` vers le Service `api` : deux proxys en chaîne. `--cacert` fait vérifier le certificat par curl, ce qui teste aussi le Secret ; `-k` désactiverait cette vérification et masquerait une erreur de Secret.

Depuis le cluster, le Corefile modifié au chapitre 11 résout les deux noms vers 192.168.49.2 : `kubectl -n boutique exec outils -- curl -sk https://boutique.example/` donne la même page.

### 12.13 Dépanner un Ingress

La méthode suit le chemin de la requête, de l'objet vers le pod. À chaque étape, une commande et un symptôme caractéristique.

```
MÉTHODE : DE L'OBJET AU POD
═══════════════════════════

  1. Un contrôleur prend-il l'Ingress ?
     kubectl get ingressclass ; kubectl get ingress NOM
       → ADDRESS vide après 1 min : classe absente ou fausse,
         contrôleur arrêté, Ingress sans classe et pas de défaut
  2. Les backends existent-ils et ont-ils des pods prêts ?
     kubectl describe ingress NOM
       → <error: services "x" not found>, ou parenthèses vides
  3. La requête correspond-elle à une règle ?
     curl -v --resolve HÔTE:PORT:IP …
       → 404 : hôte ou chemin sans règle (pathType Exact ?)
  4. Le proxy arrive-t-il aux pods ?
     → 503 : aucun endpoint prêt ; 502 : pod qui ne répond pas
       ou mauvais port cible
  5. Que dit le contrôleur ?
     kubectl -n ingress-nginx logs deploy/ingress-nginx-controller
```

| Symptôme | Cause probable | Vérification |
|---|---|---|
| `ADDRESS` vide | aucune classe ou classe inconnue ; contrôleur arrêté | `kubectl get ingressclass`, pods du contrôleur |
| 404 pour un chemin attendu | `pathType: Exact` au lieu de `Prefix` ; hôte mal orthographié ; préfixe qui n'est pas un élément entier | `kubectl get ingress -o yaml` |
| 404 avec le bon chemin, hôte par IP | requête sans le bon en-tête `Host` | `curl --resolve` ou `-H 'Host: …'` |
| 503 | Service sans endpoint prêt (sélecteur, readiness) ou Service inexistant | `describe ingress`, `get endpointslices -l kubernetes.io/service-name=…` |
| 502 | le pod refuse la connexion sur le port cible | `targetPort` du Service, port du conteneur |
| Erreur de certificat, sujet « Fake Certificate » | Secret absent, dans un autre namespace, ou ne couvrant pas l'hôte | `kubectl -n NS get secret`, `openssl x509 -noout -ext subjectAltName` |
| 308 inattendu en HTTP | redirection TLS par défaut d'ingress-nginx | normal si l'Ingress a du TLS |
| Création refusée par `validate.nginx.ingress.kubernetes.io` | chemin avec caractères spéciaux en `Exact`/`Prefix`, annotation interdite | passer en `ImplementationSpecific`, retirer l'annotation |
| Création refusée « more than one default » | plusieurs IngressClass par défaut | retirer l'annotation en trop |

Le journal du contrôleur est précieux. ingress-nginx y écrit une ligne d'accès par requête, au format nginx, avec le Service amont choisi, et y signale les Services introuvables et les Secrets illisibles. Le chapitre 22 reprend cette démarche dans un cadre plus large.

### 12.14 Pièges courants

```
Piège 1 : L'étoile oubliée dans --rule
═══════════════════════════════════════
  MAUVAIS  : kubectl create ingress web --rule="boutique.example/=front:80"
  SYMPTÔME : la page d'accueil répond, /style.css renvoie 404
             (pathType: Exact)
  BON      : --rule="boutique.example/*=front:80"  → Prefix /

Piège 2 : Prefix pris pour un préfixe de chaîne
════════════════════════════════════════════════
  MAUVAIS  : path: /api  pathType: Prefix, en attendant que /apiv2 corresponde
  SYMPTÔME : /apiv2 part vers une autre règle ou en 404
  BON      : Prefix compare des ÉLÉMENTS de chemin entiers ; /api couvre
             /api, /api/ et /api/x, jamais /apiv2

Piège 3 : Ingress sans classe sur un cluster sans classe par défaut
═══════════════════════════════════════════════════════════════════
  SYMPTÔME : l'objet est créé, ADDRESS reste vide, rien ne répond
  BON      : toujours ingressClassName (ou --class), vérifié avec
             kubectl get ingressclass

Piège 4 : Secret TLS dans un autre namespace
════════════════════════════════════════════
  MAUVAIS  : Secret dans default, Ingress dans boutique
  SYMPTÔME : certificat « Kubernetes Ingress Controller Fake Certificate »
  BON      : le Secret vit dans le namespace de l'Ingress (secretName
             n'a pas de champ namespace)

Piège 5 : Port du conteneur au lieu du port du Service
═══════════════════════════════════════════════════════
  MAUVAIS  : backend front, port.number 8080 alors que le Service expose 80
  SYMPTÔME : 503, describe ingress affiche un backend sans adresses
  BON      : port.number = spec.ports[].port du Service,
             port.name = spec.ports[].name du Service

Piège 6 : Tester en HTTPS par l'adresse IP
═══════════════════════════════════════════
  MAUVAIS  : curl -k https://192.168.49.2/
  SYMPTÔME : 404 et certificat par défaut (ni Host ni SNI)
  BON      : curl --resolve boutique.example:443:192.168.49.2 \
               --cacert boutique-tls.crt https://boutique.example/

Piège 7 : Annotation d'un autre contrôleur
═══════════════════════════════════════════
  MAUVAIS  : copier une annotation nginx.ingress.kubernetes.io/* sur un
             Ingress servi par un autre contrôleur (ou l'inverse)
  SYMPTÔME : aucune erreur, aucun effet
  BON      : vérifier le contrôleur (kubectl get ingressclass) et sa
             documentation ; les annotations ne sont pas portables
```

> [!summary] À retenir
> - Un Ingress ne fait rien sans contrôleur ; le contrôleur ne prend que les Ingress de **sa** classe, désignée par `spec.ingressClassName`, et publie son adresse dans `status.loadBalancer` (colonne `ADDRESS`).
> - Le contrôleur DefaultIngressClass (actif par défaut) écrit la classe par défaut **à la création** d'un Ingress sans classe ; deux classes par défaut font refuser ces créations.
> - `pathType` est obligatoire. `Exact` : égalité stricte. `Prefix` : correspondance par **éléments** de chemin, barre finale ignorée. À plusieurs correspondances, le chemin **le plus long** gagne, puis `Exact` avant `Prefix`.
> - `kubectl create ingress` : `*` final → `Prefix`, sans `*` → `Exact` ; `,tls=SECRET` ajoute la section TLS ; vérifie toujours avec `--dry-run=client -o yaml`.
> - TLS : Secret `kubernetes.io/tls` (`tls.crt`, `tls.key`) dans **le namespace de l'Ingress**, hôtes de `tls` alignés sur ceux des règles, sélection par SNI ; ingress-nginx redirige HTTP en 308 et sert un « Fake Certificate » quand le Secret manque.
> - Le port d'un backend est celui **du Service** ; le contrôleur proxifie vers les IP des pods lues dans les EndpointSlices (503 si aucune n'est prête).
> - Les annotations sont propres à chaque contrôleur et silencieusement ignorées par les autres ; `rewrite-target` d'ingress-nginx exige `use-regex` et `ImplementationSpecific`.
> - ingress-nginx est retiré depuis le **24 mars 2026** (dépôt archivé, plus de correctifs) ; l'**API Ingress**, GA et gelée, reste au programme et n'a pas de suppression prévue.

### 12.15 Exercices

#### Exercice 12.1 — Activer et inspecter le contrôleur d'Ingress

**Point de départ** : fin des exercices du chapitre 11 (à défaut : `lab/restaurer.sh I1`, puis `lab/etats/10-*/appliquer.sh` et `lab/etats/11-*/appliquer.sh`).

Active l'addon `ingress` du profil `cka`. Attends que le Deployment du contrôleur soit disponible. Relève ensuite : le nom de l'IngressClass créée et son contrôleur ; si elle est marquée par défaut ; le nœud où tourne le contrôleur ; les ports exposés par le Service `ingress-nginx-controller`. Vérifie enfin depuis le poste que le contrôleur répond 404 à une requête sur `http://$(minikube -p cka ip)/`.

> [!example]- Solution
> ```bash
> minikube -p cka addons enable ingress
> kubectl -n ingress-nginx rollout status deployment ingress-nginx-controller --timeout=300s
> kubectl get ingressclass
> kubectl get ingressclass nginx -o jsonpath='{.metadata.annotations.ingressclass\.kubernetes\.io/is-default-class}{"\n"}'
> kubectl -n ingress-nginx get pods -o wide
> kubectl -n ingress-nginx get svc ingress-nginx-controller
> kubectl -n ingress-nginx get deploy ingress-nginx-controller \
>   -o jsonpath='{.spec.template.spec.containers[0].ports}{"\n"}'
> ```
>
> L'IngressClass `nginx` a pour contrôleur `k8s.io/ingress-nginx` et porte l'annotation de classe par défaut à `"true"`. Le pod `ingress-nginx-controller-…` tourne sur `cka`, à cause du `nodeSelector` `minikube.k8s.io/primary: "true"`. Le Service est de type NodePort avec deux nodePorts aléatoires, mais l'accès du lab passe par les `hostPort` 80 et 443 visibles dans la spécification du conteneur. Les deux pods des Jobs d'admission sont en `Completed` : c'est normal, ils ont généré le certificat du webhook puis se sont arrêtés.
>
> **Vérification** : `curl -s -o /dev/null -w '%{http_code}\n' http://$(minikube -p cka ip)/` affiche `404`. Le contrôleur répond, et aucune règle ne correspond à une requête sans hôte connu.

#### Exercice 12.2 — Le Secret TLS de la boutique

**Point de départ** : exercice 12.1.

Dans `~/cka/boutique/`, crée une clé RSA 2048 bits et un certificat autosigné valable 365 jours, de sujet `CN=boutique.example`, dont l'extension `subjectAltName` couvre `boutique.example` et `*.boutique.example`. Nomme les fichiers `boutique-tls.key` et `boutique-tls.crt`. Crée à partir d'eux le Secret `boutique-tls` de type `kubernetes.io/tls` dans le namespace `boutique`.

> [!example]- Solution
> ```bash
> cd ~/cka/boutique
> openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
>   -keyout boutique-tls.key -out boutique-tls.crt \
>   -subj "/CN=boutique.example" \
>   -addext "subjectAltName=DNS:boutique.example,DNS:*.boutique.example"
> kubectl -n boutique create secret tls boutique-tls \
>   --cert=boutique-tls.crt --key=boutique-tls.key
> ```
>
> `kubectl create secret tls` vérifie que la clé correspond au certificat, encode les deux fichiers en base64 et pose le type `kubernetes.io/tls` avec les clés `tls.crt` et `tls.key` qu'attendent les contrôleurs. Le joker `*.boutique.example` servira aussi au Gateway du chapitre 13.
>
> **Vérification** :
> ```bash
> kubectl -n boutique get secret boutique-tls -o jsonpath='{.type}{"\n"}'
> kubectl -n boutique get secret boutique-tls -o jsonpath='{.data.tls\.crt}' \
>   | base64 -d | openssl x509 -noout -ext subjectAltName
> ```
> La première commande affiche `kubernetes.io/tls`, la seconde `DNS:boutique.example, DNS:*.boutique.example` sous l'en-tête `X509v3 Subject Alternative Name:`.

#### Exercice 12.3 — L'Ingress boutique

**Point de départ** : exercice 12.2.

Crée dans `boutique` l'Ingress `boutique`, de classe `nginx`, qui envoie l'hôte `boutique.example`, chemin `/` en `Prefix`, vers le Service `front` port 80, et l'hôte `api.boutique.example`, chemin `/` en `Prefix`, vers le Service `api` port 8080. Les deux hôtes sont servis en TLS avec le Secret `boutique-tls`. Garde le manifeste dans `~/cka/boutique/ingress-boutique.yaml`. Vérifie depuis le poste la redirection HTTP, la page d'accueil en HTTPS avec vérification du certificat, et la réponse de `api` sur `/hostname`.

> [!example]- Solution
> ```bash
> kubectl -n boutique create ingress boutique --class=nginx \
>   --rule="boutique.example/*=front:80,tls=boutique-tls" \
>   --rule="api.boutique.example/*=api:8080,tls=boutique-tls" \
>   --dry-run=client -o yaml > ~/cka/boutique/ingress-boutique.yaml
> grep pathType ~/cka/boutique/ingress-boutique.yaml
> kubectl apply -f ~/cka/boutique/ingress-boutique.yaml
> kubectl -n boutique get ingress boutique -w
> ```
>
> Le `grep` doit afficher deux fois `pathType: Prefix` : c'est l'étoile finale de chaque règle qui l'a produit. Interromps le `-w` dès que la colonne `ADDRESS` affiche `192.168.49.2`. Si `kubectl apply` échoue avec une erreur de connexion au webhook `validate.nginx.ingress.kubernetes.io`, le contrôleur vient de démarrer : relance la commande quelques secondes plus tard.
>
> **Vérification** :
> ```bash
> IP=$(minikube -p cka ip); CA=~/cka/boutique/boutique-tls.crt
> curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' --resolve boutique.example:80:$IP http://boutique.example/
> curl -s --cacert $CA --resolve boutique.example:443:$IP https://boutique.example/
> curl -s --cacert $CA --resolve api.boutique.example:443:$IP https://api.boutique.example/hostname; echo
> ```
> Résultat attendu : `308 https://boutique.example/`, puis `<h1>Boutique</h1><p>v1</p>`, puis le nom d'un pod `api-…`. `kubectl -n boutique describe ingress boutique` montre `boutique-tls terminates boutique.example,api.boutique.example` et des adresses de pods pour chaque backend.

#### Exercice 12.4 — Exact, Prefix et préséance

**Point de départ** : exercice 12.3.

Crée dans `boutique` un Ingress temporaire `essai-chemins` de classe `nginx`, pour l'hôte `essai.boutique.example`, avec trois chemins : `/` en `Prefix` vers `front:80`, `/hostname` en `Exact` vers `api:8080`, `/echo` en `Prefix` vers `api:8080`. Sans TLS. Prédis puis vérifie le code HTTP et le backend atteint pour `/`, `/hostname`, `/hostname/`, `/echo?msg=ok`, `/echo/x?msg=ok` et `/echoo`. Supprime ensuite l'Ingress.

> [!example]- Solution
> ```bash
> kubectl -n boutique create ingress essai-chemins --class=nginx \
>   --rule="essai.boutique.example/*=front:80" \
>   --rule="essai.boutique.example/hostname=api:8080" \
>   --rule="essai.boutique.example/echo*=api:8080"
> kubectl -n boutique get ingress essai-chemins \
>   -o jsonpath='{range .spec.rules[0].http.paths[*]}{.path} {.pathType}{"\n"}{end}'
> ```
>
> Les trois `--rule` du même hôte forment une seule règle à trois chemins : `/ Prefix`, `/hostname Exact`, `/echo Prefix`. Les prédictions découlent de 12.6. `/hostname` correspond à `/hostname` (Exact) et à `/` (Prefix) : le plus long gagne, donc `api`. `/hostname/` ne correspond pas à l'Exact `/hostname` (la barre finale compte en Exact), seulement à `/` : la requête part vers `front`, dont nginx n'a pas de fichier `hostname` et répond 404. `/echo?msg=ok` et `/echo/x?msg=ok` correspondent au Prefix `/echo` (la chaîne de requête n'entre pas dans le chemin) : `api` répond `ok` pour le premier ; pour le second, agnhost reçoit `/echo/x`, qu'aucun de ses gestionnaires ne déclare, et c'est son gestionnaire racine qui répond 200 avec `NOW: <date>`. `/echoo` n'est pas un sous-chemin de `/echo` (élément différent) : il va vers `front`, 404.
>
> ```bash
> IP=$(minikube -p cka ip)
> for p in / /hostname /hostname/ '/echo?msg=ok' '/echo/x?msg=ok' /echoo; do
>   printf '%-16s ' "$p"
>   curl -s -o /tmp/corps -w '%{http_code} ' --resolve essai.boutique.example:80:$IP "http://essai.boutique.example$p"
>   head -c 40 /tmp/corps; echo
> done
> kubectl -n boutique delete ingress essai-chemins
> ```
>
> **Vérification** : `/` donne 200 et la page `Boutique v1` ; `/hostname` donne 200 et un nom de pod `api-…` ; `/hostname/` et `/echoo` donnent 404 avec une page nginx (le 404 vient de `front`, pas du contrôleur) ; `/echo?msg=ok` donne 200 et `ok` ; `/echo/x?msg=ok` donne 200 et `NOW: …`, preuve qu'il a atteint `api` et non `front`. Après la suppression, `kubectl -n boutique get ingress` ne liste plus que `boutique`.

#### Exercice 12.5 — Réécrire un chemin avec une annotation

**Point de départ** : exercice 12.4.

Publie `api` sous le préfixe `/v1` de l'hôte `essai.boutique.example`, de sorte que `http://essai.boutique.example/v1/hostname` atteigne `/hostname` sur `api`. Nomme l'Ingress `api-v1` (classe `nginx`, namespace `boutique`) et utilise les annotations d'ingress-nginx. Constate ensuite ce qui se passe si l'on remet le chemin en `Prefix`. Supprime l'Ingress à la fin.

> [!example]- Solution
> Écris `~/cka/boutique/ingress-api-v1.yaml` :
>
> ```yaml
> apiVersion: networking.k8s.io/v1
> kind: Ingress
> metadata:
>   name: api-v1
>   namespace: boutique
>   annotations:
>     nginx.ingress.kubernetes.io/use-regex: "true"
>     nginx.ingress.kubernetes.io/rewrite-target: /$2
> spec:
>   ingressClassName: nginx
>   rules:
>   - host: essai.boutique.example
>     http:
>       paths:
>       - path: /v1(/|$)(.*)
>         pathType: ImplementationSpecific
>         backend:
>           service:
>             name: api
>             port:
>               number: 8080
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/ingress-api-v1.yaml
> IP=$(minikube -p cka ip)
> curl -s --resolve essai.boutique.example:80:$IP http://essai.boutique.example/v1/hostname; echo
> sed -i 's/pathType: ImplementationSpecific/pathType: Prefix/' ~/cka/boutique/ingress-api-v1.yaml
> kubectl apply -f ~/cka/boutique/ingress-api-v1.yaml
> sed -i 's/pathType: Prefix/pathType: ImplementationSpecific/' ~/cka/boutique/ingress-api-v1.yaml
> kubectl -n boutique delete ingress api-v1
> ```
>
> Le groupe `(.*)` capture tout ce qui suit `/v1/`, et `rewrite-target: /$2` le transmet comme chemin : `/v1/hostname` devient `/hostname`. Le second `kubectl apply` est **refusé** : l'expression régulière contient des caractères interdits en `Prefix`, et l'option `strict-validate-path-type` du contrôleur fait rejeter l'objet par son webhook d'admission. La sortie commence par un avertissement, `Warning: path /v1(/|$)(.*) cannot be used with pathType Prefix`, puis le message d'erreur se termine par `admission webhook "validate.nginx.ingress.kubernetes.io" denied the request: ingress contains invalid paths: path /v1(/|$)(.*) cannot be used with pathType Prefix`, ce qui prouve que le refus vient du contrôleur et non du serveur d'API.
>
> **Vérification** : le premier `curl` affiche un nom de pod `api-…` ; le second `apply` échoue ; après la suppression, `kubectl -n boutique get ingress` ne liste plus que `boutique`.

#### Exercice 12.6 — Dépanner un Ingress cassé

**Point de départ** : exercice 12.5.

Crée l'Ingress cassé suivant, puis diagnostique-le sans le relire d'abord : observe le symptôme côté client, puis trouve la cause avec `kubectl`. Répare-le pour que `https://essai.boutique.example/` serve la page de la boutique avec le certificat `boutique-tls`, puis supprime-le.

```bash
kubectl -n boutique create ingress essai-casse --class=nginx \
  --rule="essai.boutique.example/*=front-web:80,tls=boutique-tsl"
```

> [!example]- Solution
> ```bash
> IP=$(minikube -p cka ip); CA=~/cka/boutique/boutique-tls.crt
> curl -s -o /dev/null -w '%{http_code}\n' --cacert $CA \
>   --resolve essai.boutique.example:443:$IP https://essai.boutique.example/
> curl -s -o /dev/null -w '%{http_code}\n' -k \
>   --resolve essai.boutique.example:443:$IP https://essai.boutique.example/
> kubectl -n boutique describe ingress essai-casse
> ```
>
> Le premier `curl`, qui vérifie le certificat, échoue avant même d'obtenir une réponse HTTP (code `000`) : le contrôleur présente son « Fake Certificate », faute de trouver le Secret `boutique-tsl` (faute de frappe). Le second, qui ignore le certificat avec `-k`, obtient `503`. `describe` donne les deux causes : la ligne `TLS` cite `boutique-tsl`, et le backend affiche `front-web:80 (<error: services "front-web" not found>)`. Deux erreurs indépendantes produisent deux symptômes distincts, ce qui arrive souvent à l'examen.
>
> ```bash
> kubectl -n boutique patch ingress essai-casse --type=json -p='[
>   {"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/name","value":"front"},
>   {"op":"replace","path":"/spec/tls/0/secretName","value":"boutique-tls"}]'
> curl -s --cacert $CA --resolve essai.boutique.example:443:$IP https://essai.boutique.example/; echo
> kubectl -n boutique delete ingress essai-casse
> ```
>
> **Vérification** : après le patch, le `curl` avec `--cacert` affiche `<h1>Boutique</h1><p>v1</p>` ; après la suppression, il ne reste que l'Ingress `boutique`. L'état laissé par le chapitre est l'addon `ingress`, le Secret `boutique-tls` et l'Ingress `boutique`.

---
