---
title: "CKA — 11. CoreDNS et la résolution de noms"
description: "La spécification DNS de Kubernetes, CoreDNS et son Corefile, le bloc hosts de minikube et sa persistance, le resolv.conf des pods et les conséquences de ndots:5, dnsPolicy et dnsConfig, et une méthode de dépannage DNS."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 11. CoreDNS et la résolution de noms

Le chapitre 10 a donné aux applications des adresses stables ; celui-ci leur donne des noms. Il couvre la compétence *Understand and use CoreDNS* et la partie DNS de *Troubleshoot services and networking*. À l'examen, le DNS apparaît sous trois formes : des tâches de lecture (« trouve l'enregistrement de tel Service ou de tel pod et écris-le dans un fichier »), des tâches de configuration (« fais résoudre tel nom par CoreDNS », « donne à ce pod tel serveur DNS ») et surtout des pannes, car un DNS cassé se déguise en n'importe quoi : une application qui ne démarre pas, un Ingress en 502, une NetworkPolicy « qui bloque tout ». Le chapitre part du schéma d'ensemble, détaille les enregistrements que Kubernetes garantit, ouvre le Corefile plugin par plugin, explique ce que fait réellement le `ndots:5` de chaque pod, puis applique tout cela au fil rouge : CoreDNS passe à deux réplicas et apprend les noms `boutique.example` et `api.boutique.example`, dont l'Ingress du chapitre 12 aura besoin.

### 11.1 Le DNS du cluster en un schéma

```
RÉSOLUTION DE « api » DEPUIS LE POD outils (namespace boutique)
═══════════════════════════════════════════════════════════════

  pod outils
   /etc/resolv.conf  (écrit par le kubelet à la création du pod)
     search boutique.svc.cluster.local svc.cluster.local cluster.local
     nameserver 10.96.0.10
     options ndots:5
        │  « api » : 0 point < 5 → essais avec les suffixes de recherche
        │  1er essai : api.boutique.svc.cluster.local.
        ▼
  Service kube-dns 10.96.0.10:53 (UDP et TCP) ── kube-proxy (DNAT, chapitre 10.5)
        ▼
  pod coredns (kube-system), image coredns:v1.14.6
   plugin kubernetes : connaît Services, EndpointSlices, Namespaces, Pods
                       par un watch sur l'API → réponse 10.110.27.164
   plugin forward    : tout ce qui n'est pas du cluster → le resolv.conf
                       du NŒUD (CoreDNS tourne en dnsPolicy: Default)
        ▼
  serveur DNS du nœud : 192.168.49.1 dans le lab (DNS embarqué de Docker)
```

Trois éléments de configuration relient ces étapes. Le **kubelet** de chaque nœud connaît l'adresse du DNS et le domaine du cluster, dans `/var/lib/kubelet/config.yaml` : `clusterDNS: [10.96.0.10]` et `clusterDomain: cluster.local` dans le lab, comme sous kubeadm par défaut. Le **Service** `kube-dns` porte cette adresse, choisie dans la bande statique de la plage des Services (chapitre 10.3) ; il garde ce nom pour des raisons historiques, alors que ce sont des pods CoreDNS qui le servent. Enfin la **ConfigMap** `kube-system/coredns` contient le Corefile, la configuration de CoreDNS.

Un nom de cluster est **relatif à un namespace**. Depuis `boutique`, `api` désigne `api.boutique.svc.cluster.local` ; depuis un pod de `default`, `api` ne désigne rien, il faut écrire `api.boutique`. C'est la première chose à vérifier quand « le DNS ne marche pas » pour un seul client.

### 11.2 Les enregistrements garantis

La spécification *Kubernetes DNS-Based Service Discovery* (schéma 1.1.0) fixe les enregistrements qu'un DNS de cluster conforme doit servir. Tout le reste, même s'il fonctionne avec CoreDNS, est un détail d'implémentation. Voici ces enregistrements appliqués aux Services du fil rouge (adresses du texte : les tiennes diffèrent).

| Objet | Nom interrogé | Type | Réponse |
|---|---|---|---|
| Service ClusterIP `api` | `api.boutique.svc.cluster.local` | A | `10.110.27.164` (la ClusterIP) |
| Port **nommé** `http` de `api` | `_http._tcp.api.boutique.svc.cluster.local` | SRV | `0 100 8080 api.boutique.svc.cluster.local.` |
| ClusterIP de `api` | `164.27.110.10.in-addr.arpa` | PTR | `api.boutique.svc.cluster.local.` |
| Service headless `api-pods` | `api-pods.boutique.svc.cluster.local` | A | une réponse par pod **prêt** : `10.244.195.201`, `10.244.34.135` |
| Port nommé de `api-pods` | `_http._tcp.api-pods.boutique.svc.cluster.local` | SRV | une réponse par pod : `0 50 8080 10-244-195-201.api-pods.boutique.svc.cluster.local.`… |
| Un pod derrière `api-pods` | `10-244-34-135.api-pods.boutique.svc.cluster.local` | A | `10.244.34.135` |
| Service ExternalName `meteo` | `meteo.boutique.svc.cluster.local` | CNAME | `example.com.` |
| Un pod quelconque | `10-244-34-135.boutique.pod.cluster.local` | A | `10.244.34.135` |
| Version du schéma | `dns-version.cluster.local` | TXT | `"1.1.0"` |

Quelques règles se cachent derrière ce tableau.

Les **SRV** n'existent que pour les ports **nommés** : `_<nom du port>._<protocole en minuscules>.<service>.<namespace>.svc.<domaine>`. Le Service `front`, dont le port n'a pas de nom, n'en a pas ; c'est pour cela que le port de `api` s'appelle `http` (chapitre 10.2). Une réponse SRV donne priorité, poids, port et cible ; CoreDNS met la priorité à 0 et répartit un poids total de 100 entre les cibles : 100 pour la cible unique d'un Service ClusterIP, 50 chacune pour deux pods d'un Service headless.

Pour un Service **headless**, le nom propre de chaque pod est `<hostname>.<service>.<namespace>.svc.<domaine>`. Le `<hostname>` est le champ `hostname` du point d'accès, que le contrôleur EndpointSlice remplit quand le pod déclare `spec.hostname` et un `spec.subdomain` égal au nom du Service : c'est ce que fait un StatefulSet, d'où `redis-0.redis.boutique.svc.cluster.local` au chapitre 15. Faute de `hostname`, CoreDNS utilise l'adresse du pod écrite avec des tirets. Seuls les points d'accès `ready` apparaissent (chapitre 10.4), sauf si le Service déclare `publishNotReadyAddresses: true`.

L'enregistrement **`<ip-à-tirets>.<namespace>.pod.cluster.local`** est un héritage de kube-dns. Avec l'option `pods insecure` du Corefile par défaut, CoreDNS répond à **n'importe quelle** adresse écrite ainsi, sans vérifier qu'un pod la porte ; `pods verified` vérifierait, `pods disabled` supprimerait ces réponses. C'est l'enregistrement qu'attendent les tâches d'examen du type « écris dans un fichier la résolution DNS du pod X ».

Ces enregistrements suivent l'état du cluster presque en temps réel. Le plugin `kubernetes` tient en mémoire, par un *watch* sur l'API, la liste des Services, des EndpointSlices et des namespaces : un Service créé est résolvable dès que CoreDNS a reçu l'événement, en général en moins d'une seconde, et le Corefile désactive le cache pour `cluster.local` afin de ne pas retarder ces changements. Le délai que tu observes vient plutôt des **clients** : une réponse est valable 30 secondes (`ttl 30`), et une application ou une bibliothèque qui la garde en cache verra un pod disparu d'un Service headless jusqu'à l'expiration, parfois bien au-delà.

> [!tip] Réflexe d'examen
> Pour une tâche « résous le Service et le pod et note le résultat », lance un pod jetable avec des outils DNS et redirige la sortie sur ta machine : `kubectl run dnstest --rm -i --restart=Never --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.7 -- nslookup api.boutique.svc.cluster.local > fichier`. Pour le pod, transforme son adresse (`kubectl get pod -o wide`) en `a-b-c-d.<namespace>.pod.cluster.local`. Donne toujours le nom complet : tu n'as pas à te demander dans quel namespace tourne ton pod de test.

#### Pourquoi le DNS ne remplace pas la ClusterIP

On pourrait imaginer un Service sans adresse virtuelle, dont le nom renverrait à tour de rôle l'adresse de chaque pod : c'est exactement ce que fait un Service headless, et Kubernetes ne l'utilise pas par défaut. La documentation (*Virtual IPs and Service Proxies*) en donne les raisons : beaucoup de bibliothèques ne respectent pas le TTL des enregistrements et gardent une réponse trop longtemps ; certaines applications ne résolvent un nom qu'une fois, au démarrage, et gardent l'adresse indéfiniment ; et des TTL très courts, qui corrigeraient les deux premiers défauts, feraient exploser la charge sur le DNS. Avec une ClusterIP, l'adresse résolue ne change jamais pendant la vie du Service : c'est kube-proxy qui suit les pods, sans rien demander au client. Un client d'un Service headless, lui, doit re-résoudre le nom pour voir arriver ou partir des pods ; c'est acceptable pour un client qui gère lui-même ses pairs (un pilote de base de données répliquée, un StatefulSet), pas pour une application ordinaire.

### 11.3 CoreDNS dans le cluster

CoreDNS est installé par `kubeadm init` (phase `addon/coredns`), dans `kube-system`. Les objets à connaître :

| Objet | Nom | Points notables |
|---|---|---|
| Deployment | `coredns` | 2 réplicas sous kubeadm, **1 sous minikube** ; anti-affinité préférée sur `kubernetes.io/hostname` ; toleration de la taint du control plane ; `priorityClassName: system-cluster-critical` |
| Pods | `coredns-…`, label `k8s-app=kube-dns` | requests 100m / 70Mi, limite mémoire 170Mi ; vivacité `/health` sur 8080, disponibilité `/ready` sur 8181 ; **`dnsPolicy: Default`** |
| Service | `kube-dns`, ClusterIP `10.96.0.10` | ports `dns` 53/UDP, `dns-tcp` 53/TCP, `metrics` 9153/TCP |
| ConfigMap | `coredns`, clé `Corefile` | montée en `/etc/coredns/Corefile` |
| ServiceAccount, ClusterRole, ClusterRoleBinding | `coredns`, `system:coredns` | `list` et `watch` sur endpoints, services, pods, namespaces et `endpointslices.discovery.k8s.io` |

Le `dnsPolicy: Default` de CoreDNS est essentiel : CoreDNS hérite du `resolv.conf` de son nœud, ce qui lui donne ses serveurs amont, et il ne s'interroge pas lui-même. Le label `k8s-app=kube-dns` (et non `app=coredns`) sert de sélecteur au Service, aux NetworkPolicies qui autorisent le DNS (chapitre 14.7) et à `kubectl logs -l`.

Les permissions comptent aussi : un CoreDNS qui ne peut plus lister les EndpointSlices répond `SERVFAIL` aux noms du cluster. La ClusterRole `system:coredns` doit contenir les `endpointslices` du groupe `discovery.k8s.io`.

#### Observer CoreDNS

Trois sources renseignent sur la santé de CoreDNS. Les **journaux** (`kubectl -n kube-system logs -l k8s-app=kube-dns --prefix`) donnent les erreurs, les rechargements et, si le plugin `log` est actif, chaque requête. Les **sondes** donnent l'état vu par le kubelet : un pod `0/1` a sa sonde `/ready` en échec, souvent parce que le plugin `kubernetes` n'arrive pas à synchroniser son cache avec l'API. Les **métriques**, enfin, exposées au format Prometheus sur le port 9153, se lisent sans outil de supervision par un simple transfert de port :

```bash
kubectl -n kube-system port-forward deployment/coredns 9153:9153 &
curl -s http://127.0.0.1:9153/metrics | grep -E '^coredns_(build_info|dns_responses_total|reload_failed_total)' | head
kill %1
```

`coredns_build_info` confirme la version (v1.14.6 dans le lab), `coredns_dns_responses_total` ventile les réponses par code (`NOERROR`, `NXDOMAIN`, `SERVFAIL`…) et par plugin, `coredns_reload_failed_total` compte les rechargements refusés (11.5). Une proportion soudaine de `SERVFAIL` pointe vers l'amont ou vers les droits RBAC ; une avalanche de `NXDOMAIN` sur des noms à suffixes multiples trahit l'effet de `ndots` (11.6).

> [!info] minikube ≠ examen
> Au **premier** démarrage d'un profil, minikube réduit CoreDNS à **1 réplica** (sauf avec `--disable-optimizations` ou sur un cluster à plusieurs control planes) et modifie le Corefile : il ajoute le plugin `log`, qui journalise chaque requête, et un bloc `hosts` qui fait résoudre `host.minikube.internal` vers ton poste (`192.168.49.1`). Un cluster kubeadm a 2 réplicas et le Corefile par défaut, sans `log` ni `hosts`. Ces deux retouches ne sont faites qu'à la création du profil (11.5).

### 11.4 Le Corefile

#### Structure

Voici le Corefile du lab, tel que minikube l'a laissé :

```bash
kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'
```

```
.:53 {
    log
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    hosts {
       192.168.49.1 host.minikube.internal
       fallthrough
    }
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30 {
       disable success cluster.local
       disable denial cluster.local
    }
    loop
    reload
    loadbalance
}
```

Un Corefile est une suite de **blocs serveur**. L'en-tête `.:53` dit : « pour la zone racine `.` (donc tous les noms), sur le port 53 ». Un autre bloc, `interne.example:53 { … }`, traiterait à part les noms de cette zone : CoreDNS envoie chaque requête au bloc dont la zone est **la plus spécifique**. À l'intérieur d'un bloc, chaque ligne active un **plugin** avec ses options.

#### Les plugins un par un

| Plugin | Rôle | Détail utile |
|---|---|---|
| `log` | journalise chaque requête sur la sortie standard | ajouté par minikube ; absent sous kubeadm ; à ajouter pour un dépannage |
| `errors` | journalise les erreurs | |
| `health` | `http://:8080/health`, sonde de vivacité | `lameduck 5s` : à l'arrêt, se déclare en échec 5 s avant de s'éteindre |
| `ready` | `http://:8181/ready`, sonde de disponibilité | répond 200 quand tous les plugins sont prêts (le plugin `kubernetes` après sa première synchronisation) |
| `kubernetes` | répond pour `cluster.local` et les zones inverses | `pods insecure` (11.2) ; `fallthrough in-addr.arpa ip6.arpa` : une adresse inverse inconnue passe au plugin suivant au lieu d'un NXDOMAIN ; `ttl 30` (défaut du plugin : 5 s) |
| `prometheus` | métriques sur `:9153` | port `metrics` du Service |
| `hosts` | répond depuis une liste de type `/etc/hosts` | ajouté par minikube (11.5) |
| `forward` | relaie le reste vers des serveurs amont | `/etc/resolv.conf` = celui du pod CoreDNS, donc du nœud ; `max_concurrent 1000` limite les requêtes simultanées |
| `cache` | met en cache les réponses 30 s au plus | `disable success/denial cluster.local` : les réponses du cluster ne sont **pas** mises en cache, le plugin `kubernetes` les sert déjà depuis sa mémoire et un cache ne ferait que retarder les changements |
| `loop` | détecte une boucle de relais et **arrête** CoreDNS | voir 11.8 |
| `reload` | relit le Corefile quand il change | contrôle toutes les 30 s, ± 15 s de gigue |
| `loadbalance` | mélange l'ordre des A, AAAA et MX d'une réponse | répartition grossière entre les pods d'un Service headless |

#### L'ordre d'exécution n'est pas l'ordre d'écriture

Point subtil et fréquent dans les questions pièges : **l'ordre des lignes dans le Corefile ne compte pas**. CoreDNS exécute les plugins dans un ordre fixé à la compilation (fichier `plugin.cfg` de CoreDNS). Pour ceux du lab, cet ordre est : `reload`, `ready`, `health`, `prometheus`, `errors`, `log`, `loadbalance`, `cache`, `hosts`, `kubernetes`, `loop`, `forward`. Deux conséquences : le `cache` est consulté avant tout le reste, et **`hosts` passe avant `kubernetes`**. Toute requête, y compris pour `api.boutique.svc.cluster.local`, traverse d'abord le plugin `hosts`, qui doit donc la laisser passer quand il ne la connaît pas : c'est le rôle de `fallthrough`.

### 11.5 Modifier le Corefile

#### Le geste

On modifie la ConfigMap, et c'est tout :

```bash
kubectl -n kube-system get configmap coredns -o yaml > ~/cka/reseau/coredns-avant.yaml
kubectl -n kube-system edit configmap coredns
```

Le kubelet met à jour le fichier monté dans chaque pod CoreDNS (la propagation d'une ConfigMap montée prend jusqu'à une minute environ, chapitre 6.4), puis le plugin `reload` remarque le changement d'empreinte du fichier à son prochain contrôle (30 s ± 15 s) et recharge la configuration **sans interruption de service**. La documentation de Kubernetes conseille de compter **deux minutes**. Les journaux de CoreDNS le confirment (`Reloading` puis `Reloading complete`). Pour aller plus vite, on redémarre les pods : `kubectl -n kube-system rollout restart deployment coredns`.

Le rechargement a une propriété précieuse : **si le nouveau Corefile est invalide, CoreDNS garde l'ancienne configuration** et écrit une erreur dans ses journaux (la métrique `coredns_reload_failed_total` augmente). La panne reste donc invisible… jusqu'au prochain redémarrage d'un pod CoreDNS, qui démarre avec le fichier invalide et part en `CrashLoopBackOff`. C'est la panne 16 du chapitre 23. Après chaque modification, regarde les journaux avant de passer à autre chose.

#### Le plugin hosts

Le bloc `hosts` sert une liste au format de `/etc/hosts` écrite **dans** le Corefile : une adresse, puis un ou plusieurs noms. Ses règles :

- sans `fallthrough`, le plugin répond **SERVFAIL** à tout nom qu'il ne connaît pas, dans toutes les zones du bloc serveur ; comme il s'exécute avant `kubernetes` et `forward`, oublier `fallthrough` casse **toute** la résolution du cluster ;
- les enregistrements créés ont un TTL de 3600 s (option `ttl`), plafonné à 30 s par le plugin `cache` ;
- les entrées produisent aussi les enregistrements inverses (PTR), sauf avec `no_reverse` ;
- un nom présent avec une adresse IPv4 seulement reçoit une réponse vide (NOERROR, sans erreur) à une requête AAAA ;
- **un seul** bloc `hosts` par bloc serveur : en ajouter un second fait échouer le chargement (`plugin/hosts: this plugin can only be used once per Server Block`). On ajoute donc des lignes au bloc existant.

Le fil rouge s'en sert à l'exercice 11.4 : `boutique.example` et `api.boutique.example` doivent résoudre vers l'adresse du nœud `cka`, où écoutera le contrôleur d'Ingress du chapitre 12.11. Le bloc devient :

```
    hosts {
       192.168.49.1 host.minikube.internal
       192.168.49.2 boutique.example api.boutique.example
       fallthrough
    }
```

#### Autres personnalisations

Un **domaine délégué** (*stub domain*) se déclare par un bloc serveur supplémentaire, à côté du bloc `.:53` :

```
interne.example:53 {
    errors
    cache 30
    forward . 192.0.2.53
}
```

Toute requête pour `*.interne.example` part vers `192.0.2.53` ; le reste suit le bloc `.:53`. Pour imposer des serveurs amont précis à tout le cluster au lieu de ceux du nœud, on remplace `forward . /etc/resolv.conf` par `forward . 192.0.2.1 192.0.2.2`. `forward` n'accepte que des adresses : un nom de serveur n'y a pas de sens, puisque c'est précisément ce serveur qui résout les noms.

#### Ce que minikube fait du Corefile au redémarrage

Le code de minikube v1.39.0 (fonction `addCoreDNSEntry` de `pkg/minikube/node/start.go`) n'injecte le bloc `hosts`, le plugin `log` et la réduction à 1 réplica que **lors du premier démarrage du nœud control plane** (condition `!starter.PreExists`). Même alors, il commence par chercher `host.minikube.internal` dans un bloc `hosts` existant, et ne touche à rien s'il l'y trouve ; s'il trouve un bloc `hosts` sans cette entrée, il ajoute sa ligne **dans** ce bloc au lieu d'en créer un second. Un `minikube -p cka stop` suivi d'un `start` ne réapplique pas non plus la phase `addon/coredns` de kubeadm quand la configuration du cluster n'a pas changé ; et quand elle la réapplique, kubeadm **conserve** un Corefile modifié et le nombre de réplicas en place. Tes lignes `boutique.example` et tes deux réplicas survivent donc à un arrêt et un redémarrage du lab, à condition de garder la ligne `host.minikube.internal` dans le bloc : c'est vérifié sur le lab, où après `minikube -p cka stop` puis `start` le bloc `hosts` est intact et `coredns` revient à `2/2`. Les pods CoreDNS mettent une trentaine de secondes à redevenir prêts après les nœuds ; une requête lancée avant échoue en délai dépassé. En cas de doute, `lab/etats/11-coredns/appliquer.sh` rétablit cet état.

### 11.6 Le resolv.conf des pods et ndots

#### Ce qu'écrit le kubelet

Pour un pod en `dnsPolicy: ClusterFirst` (la valeur par défaut), le kubelet compose le `resolv.conf` à partir de sa configuration et de celle du nœud :

```bash
kubectl -n boutique exec outils -- cat /etc/resolv.conf
```

```
search boutique.svc.cluster.local svc.cluster.local cluster.local lan
nameserver 10.96.0.10
options ndots:5
```

`nameserver` est la seule adresse de `clusterDNS`. La ligne `search` contient trois domaines construits sur le namespace du pod, suivis des domaines de recherche du nœud s'il en a. Dans le lab, le `resolv.conf` des nœuds est généré par Docker à partir de celui de ton poste : les domaines de recherche de ton poste (`lan` ici, souvent aucun, parfois ceux d'un VPN) finissent donc au bout de la ligne `search` de chaque pod. `options ndots:5` est une valeur **en dur** dans le kubelet.

#### Ce que signifie ndots:5

L'option `ndots:n` du résolveur dit : un nom qui contient **moins de n points** est d'abord essayé **avec chaque domaine de recherche**, et seulement ensuite tel quel ; un nom qui en contient n ou plus est d'abord essayé tel quel. Un nom terminé par un point (`example.com.`) est absolu : jamais de recherche.

Avec `ndots:5`, presque tous les noms passent d'abord par la liste de recherche. C'est voulu : `api` (0 point), `api.boutique` (1 point), `api.boutique.svc` (2 points) doivent être complétés pour fonctionner. Mais le prix est lourd pour les noms extérieurs :

```
RÉSOLUTION DE « example.com » (1 point < 5) DEPUIS UN POD DE boutique
═════════════════════════════════════════════════════════════════════

  1. example.com.boutique.svc.cluster.local.   → NXDOMAIN (plugin kubernetes)
  2. example.com.svc.cluster.local.            → NXDOMAIN
  3. example.com.cluster.local.                → NXDOMAIN
  4. example.com.                              → réponse (forward)

  4 allers-retours au lieu d'1, multipliés par 2 si le client demande
  A et AAAA (getaddrinfo de la glibc le fait) : 8 requêtes.
  Un nom de 4 points (api.eu-west.services.example.com) en fait autant.
```

Les journaux de CoreDNS du lab, grâce au plugin `log`, montrent ces requêtes une à une (exercice 11.1) :

```
[INFO] 10.244.34.140:43125 - 21875 "A IN example.com.boutique.svc.cluster.local. udp 56 false 512" NXDOMAIN qr,aa,rd 149 0.000187s
[INFO] 10.244.34.140:52961 - 64230 "A IN example.com.svc.cluster.local. udp 47 false 512" NXDOMAIN qr,aa,rd 140 0.000139s
[INFO] 10.244.34.140:38377 - 2840 "A IN example.com.cluster.local. udp 43 false 512" NXDOMAIN qr,aa,rd 136 0.000121s
[INFO] 10.244.34.140:41612 - 10557 "A IN example.com. udp 29 false 512" NOERROR qr,rd,ra 61 0.021483s
```

Si ton poste a des domaines de recherche, ils s'intercalent avant la dernière ligne : une requête de plus par domaine (`example.com.lan.`), à laquelle répond l'amont (`NXDOMAIN qr,rd,ra`).

Chaque ligne donne l'adresse du client (le pod lui-même : il n'y a pas de masquage entre un pod et un Service, chapitre 10.5), le type et le nom demandés, le code de réponse et la durée. Les drapeaux `qr,aa` des NXDOMAIN signalent une réponse **faisant autorité** : c'est CoreDNS lui-même qui sait que ces noms n'existent pas. La dernière réponse, sans `aa`, vient de l'amont (`ra` : récursion disponible).

Les parades, de la plus locale à la plus globale : écrire les noms extérieurs **avec un point final** dans la configuration des applications (`example.com.`) ; baisser `ndots` pour un pod précis par `dnsConfig` (11.7), en sachant qu'avec `ndots:1`, `api.boutique` ne serait plus complété ; ou alléger le coût global avec un cache local (11.9). Le plugin `autopath` de CoreDNS peut aussi répondre en une fois en devinant le namespace du client, au prix de `pods verified` et d'une surveillance de tous les pods.

#### Les outils ne se valent pas

Le résolveur qui applique `search` et `ndots` est celui de la bibliothèque C du programme. `getent hosts api` et `nslookup api` (celui de BIND, dans `jessie-dnsutils` ou `netshoot`) l'appliquent. **`dig` ne l'applique pas** : `dig api` interroge le nom `api.` tel quel et échoue ; il faut `dig +search api`, ou le nom complet. Les images Alpine (`netshoot`, `nginx:…-alpine`, `curlimages/curl`) utilisent la bibliothèque musl, dont le résolveur interroge les serveurs différemment de la glibc ; pour un diagnostic qui doit refléter le comportement d'une application, interroge depuis une image proche de la sienne, et pour un diagnostic du DNS lui-même, préfère `dig` avec des noms complets.

### 11.7 dnsPolicy et dnsConfig

Le champ `spec.dnsPolicy` d'un pod choisit la base de son `resolv.conf` :

| `dnsPolicy` | Base du resolv.conf | Usage |
|---|---|---|
| `ClusterFirst` (**défaut**) | DNS du cluster, recherche du namespace, `ndots:5` ; pour un pod en `hostNetwork`, se comporte comme `Default` | presque tous les pods |
| `ClusterFirstWithHostNet` | comme `ClusterFirst`, **même** en `hostNetwork` | pods en `hostNetwork` qui doivent résoudre les Services (chapitre 9.6) |
| `Default` | le `resolv.conf` du **nœud** (celui que désigne l'option `resolvConf` du kubelet) | CoreDNS lui-même, pods qui ne doivent pas dépendre du DNS du cluster |
| `None` | **rien** : tout vient de `spec.dnsConfig` | configuration entièrement maîtrisée |

> [!warning] « Default » n'est pas la valeur par défaut
> La valeur par défaut de `dnsPolicy` est `ClusterFirst`. `Default` désigne la configuration du nœud. Un pod en `dnsPolicy: Default` ne résout aucun Service du cluster.

Le champ `spec.dnsConfig` complète la base choisie, quelle que soit la politique (il est **obligatoire** avec `None`) :

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dns-perso
  namespace: boutique
spec:
  dnsPolicy: None
  dnsConfig:
    nameservers:            # au plus 3 ; au moins 1 avec dnsPolicy: None
    - 10.96.0.10
    searches:               # au plus 32 domaines, 2048 caractères au total
    - boutique.svc.cluster.local
    options:                # name obligatoire, value facultative
    - name: ndots
      value: "1"
    - name: timeout
      value: "2"
  containers:
  - name: dnsutils
    image: registry.k8s.io/e2e-test-images/jessie-dnsutils:1.7
    command: ["sleep", "3600"]
```

Le `resolv.conf` obtenu :

```
search boutique.svc.cluster.local
nameserver 10.96.0.10
options timeout:2 ndots:1
```

Les règles de fusion sont simples : les serveurs et domaines de `dnsConfig` s'**ajoutent** à ceux de la politique (doublons retirés), et une option de même nom **remplace** celle de la base (`ndots:2` dans `dnsConfig` d'un pod `ClusterFirst` remplace `ndots:5`). La valeur d'une option est une **chaîne** : `value: "1"` entre guillemets, sinon l'API refuse un entier. Quand la configuration du nœud dépasse les limites (plus de 3 serveurs, par exemple), le kubelet tronque et le signale par un événement `DNSConfigForming` sur le pod (`Nameserver limits were exceeded, some nameservers have been omitted…`).

`dnsPolicy` et `dnsConfig` sont figés à la création du pod : on les change dans le gabarit d'un Deployment (ce qui recrée les pods) ou en recréant un pod nu. Deux champs voisins complètent la panoplie. `spec.setHostnameAsFQDN: true` fait renvoyer le nom complet par `hostname` (64 caractères au plus, sinon le pod ne démarre pas). `spec.hostAliases` ajoute des lignes au `/etc/hosts` du pod, que le kubelet gère :

```yaml
spec:
  hostAliases:
  - ip: 192.168.49.2
    hostnames:
    - boutique.example
    - api.boutique.example
```

L'effet ressemble à celui du bloc `hosts` de CoreDNS, mais la portée diffère du tout au tout : `hostAliases` ne concerne que ce pod, ne passe pas par le DNS (un `dig` ne le voit pas, `getent hosts` et les applications si) et ne se modifie qu'en recréant le pod ; le bloc `hosts` vaut pour tout le cluster et se change à chaud. Pour un besoin ponctuel d'une seule application, `hostAliases` évite de toucher à un composant partagé ; pour un nom que tout le cluster doit connaître, comme `boutique.example`, c'est le Corefile. N'écris pas toi-même dans `/etc/hosts` d'un conteneur : le kubelet en est propriétaire et ta modification disparaît au redémarrage du conteneur.

### 11.8 Dépanner le DNS

#### La méthode

Quand un pod ne résout pas un nom, avance du client vers le serveur :

```
MÉTHODE : « LE DNS NE MARCHE PAS »
═════════════════════════════════

  1. Le nom est-il juste, pour CE namespace ?
       api depuis default ≠ api depuis boutique → nom complet
  2. Le resolv.conf du pod est-il celui attendu ?
       kubectl exec <pod> -- cat /etc/resolv.conf
       nameserver ≠ 10.96.0.10 → dnsPolicy (hostNetwork ? Default ?)
  3. Le DNS du cluster répond-il, depuis un pod de test ?
       kubectl run dnstest --rm -i --restart=Never \
         --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.7 -- \
         nslookup kubernetes.default.svc.cluster.local
  4. Les pods CoreDNS tournent-ils et sont-ils prêts ?
       kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
  5. Le Service kube-dns a-t-il des backends ?
       kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns
  6. Que disent les journaux ?
       kubectl -n kube-system logs -l k8s-app=kube-dns --prefix --tail=30
       (ajouter le plugin log au Corefile pour voir chaque requête)
  7. Une NetworkPolicy bloque-t-elle UDP ou TCP 53 ? (chapitre 14.7)
       délai d'attente au lieu de NXDOMAIN → filtrage
  8. L'amont répond-il ? (noms extérieurs seulement)
       resolv.conf du nœud, plugin forward
```

| Symptôme | Cause probable |
|---|---|
| `NXDOMAIN` pour un Service qui existe | mauvais namespace dans le nom, faute de frappe, ou Service headless sans pod prêt |
| `connection timed out; no servers could be reached` | CoreDNS injoignable : NetworkPolicy sur le port 53, pods CoreDNS absents, kube-proxy |
| Noms du cluster OK, noms extérieurs KO | amont injoignable (resolv.conf du nœud, `forward`), ou filtrage en sortie |
| `SERVFAIL` partout | plugin `hosts` sans `fallthrough`, droits RBAC de CoreDNS, API injoignable |
| CoreDNS en `CrashLoopBackOff`, journal `plugin/loop: Loop … detected` | le nœud renvoie vers lui-même (resolv.conf qui pointe une adresse locale, typiquement `127.0.0.53` de systemd-resolved) |
| CoreDNS en `CrashLoopBackOff` après un redémarrage, sans boucle | Corefile invalide, resté invisible tant que `reload` gardait l'ancien (panne 16) |
| Lenteur sur les noms extérieurs seulement | `ndots:5` et liste de recherche longue ; timeout sur AAAA |

#### Court-circuiter le Service

L'étape 3 de la méthode mélange deux composants : kube-proxy, qui traduit `10.96.0.10` vers un pod CoreDNS, et CoreDNS lui-même. Pour les séparer, interroge directement un pod CoreDNS par son adresse, puis le Service :

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl -n boutique exec outils -- dig +short @10.244.142.66 api.boutique.svc.cluster.local
kubectl -n boutique exec outils -- dig +short @10.96.0.10 api.boutique.svc.cluster.local
```

Si le pod répond et pas le Service, le problème est entre les deux : EndpointSlice vide (pods CoreDNS non prêts), règles de kube-proxy sur le nœud du client. Si aucun ne répond, regarde CoreDNS lui-même, ou une NetworkPolicy qui filtre l'entrée des pods CoreDNS. Un Service `kube-dns` **sans** backend prêt se reconnaît d'ailleurs à son symptôme : comme pour tout Service (chapitre 10.5), kube-proxy **rejette** immédiatement la requête au lieu de la laisser expirer, et `dig` signale un refus de connexion plutôt qu'un délai (exercice 11.6).

#### Le DNS vu depuis un nœud

Kubernetes ne configure pas le `resolv.conf` des **nœuds** pour utiliser le DNS du cluster : depuis un shell sur un nœud, `nslookup api.boutique.svc.cluster.local` échoue, et c'est normal. Pour tester CoreDNS depuis un nœud, désigne explicitement le serveur (`dig @10.96.0.10 …`, si `dig` est installé) ou passe par un pod. À l'inverse, un pod en `dnsPolicy: Default` ou en `hostNetwork` sans `ClusterFirstWithHostNet` résout comme le nœud, donc sans les noms du cluster.

#### La boucle de relais

Le cas `plugin/loop` mérite une explication. Sur un nœud qui utilise systemd-resolved, `/etc/resolv.conf` contient `nameserver 127.0.0.53`. Un CoreDNS qui hérite de ce fichier (il tourne en `dnsPolicy: Default`) relaie vers `127.0.0.53`… de **son propre** netns, c'est-à-dire vers lui-même. Le plugin `loop` envoie au démarrage une requête de test (`HINFO` sur un nom aléatoire) ; s'il la voit revenir, il écrit `[FATAL] plugin/loop: Loop (127.0.0.1:… -> :53) detected for zone "."` et arrête CoreDNS. La correction se fait côté kubelet : son option `resolvConf` doit désigner le fichier des vrais serveurs (`/run/systemd/resolve/resolv.conf`), ce que kubeadm fait automatiquement quand il détecte systemd-resolved. Supprimer `loop` du Corefile ne répare rien : la boucle consommerait la mémoire et le processeur au lieu d'arrêter le pod.

### 11.9 NodeLocal DNSCache

NodeLocal DNSCache est un DaemonSet facultatif qui place un cache DNS (une instance de CoreDNS) **sur chaque nœud**, à l'écoute d'une adresse de lien local choisie par l'administrateur (`169.254.20.10` dans les exemples). Les pods l'interrogent directement : leurs requêtes ne passent plus par la traduction de kube-proxy ni par la table conntrack, qui sont la source de pertes et de délais de 5 s sur UDP dans les gros clusters. Le cache relaie les noms du cluster vers CoreDNS, en TCP, et le reste vers l'amont. Il réduit la latence et la charge sur CoreDNS, sans changer la sémantique des noms. C'est un sujet de culture générale pour le CKA : retiens le pourquoi (conntrack, latence, charge) et le comment (un cache par nœud, une adresse locale), pas sa procédure d'installation.

### 11.10 Pièges courants

```
Piège 1 : Interroger un Service d'un autre namespace par son nom court
══════════════════════════════════════════════════════════════════════
  MAUVAIS : depuis default, nslookup api
  SYMPTÔME : NXDOMAIN ; on accuse CoreDNS.
  BON : api.boutique, ou api.boutique.svc.cluster.local.

Piège 2 : dig sans +search
══════════════════════════
  MAUVAIS : dig api   (depuis outils)
  SYMPTÔME : NXDOMAIN alors que nslookup api fonctionne.
  BON : dig +search api, ou dig api.boutique.svc.cluster.local.

Piège 3 : Un bloc hosts sans fallthrough
════════════════════════════════════════
  MAUVAIS : hosts { 192.168.49.2 boutique.example }
  SYMPTÔME : SERVFAIL pour TOUS les autres noms, y compris les
             Services : hosts s'exécute avant kubernetes.
  BON : terminer le bloc par fallthrough.

Piège 4 : Un second bloc hosts
═══════════════════════════════
  MAUVAIS : ajouter « hosts { … } » sous celui de minikube
  SYMPTÔME : reload refusé (ancienne config gardée) ; au prochain
             redémarrage, CoreDNS en CrashLoopBackOff.
  BON : ajouter des lignes au bloc existant.

Piège 5 : Croire qu'un Corefile invalide se voit tout de suite
═══════════════════════════════════════════════════════════════
  SYMPTÔME : tout marche… jusqu'au redémarrage d'un pod CoreDNS.
  BON : après chaque modification, kubectl -n kube-system logs
        -l k8s-app=kube-dns : chercher « Reloading complete »
        ou l'erreur de chargement.

Piège 6 : dnsPolicy: Default « pour avoir le comportement par défaut »
═══════════════════════════════════════════════════════════════════════
  SYMPTÔME : le pod ne résout plus aucun Service.
  BON : ne pas écrire dnsPolicy, ou écrire ClusterFirst.

Piège 7 : Chercher un SRV sur un port sans nom
═══════════════════════════════════════════════
  MAUVAIS : dig SRV _http._tcp.front.boutique.svc.cluster.local
  SYMPTÔME : NXDOMAIN ; le port de front n'a pas de nom.
  BON : nommer le port du Service.

Piège 8 : Supprimer le plugin loop pour « réparer » CoreDNS
═══════════════════════════════════════════════════════════
  SYMPTÔME : CoreDNS ne redémarre plus en boucle mais sature.
  BON : corriger resolvConf du kubelet (ou le resolv.conf du nœud).
```

> [!summary] À retenir
> - Chaîne de résolution : `resolv.conf` du pod (écrit par le kubelet : `clusterDNS`, `clusterDomain`) → Service `kube-dns` `10.96.0.10` → pods CoreDNS (`k8s-app=kube-dns`) → plugin `kubernetes` pour `cluster.local`, plugin `forward` vers le DNS du nœud pour le reste.
> - Enregistrements garantis : A du Service (ClusterIP), A multiples d'un headless (pods prêts), SRV des **ports nommés** `_port._proto.svc.ns.svc.cluster.local`, `hostname.service.ns.svc…` pour les pods d'un headless, CNAME d'un ExternalName, `a-b-c-d.ns.pod.cluster.local` (`pods insecure`).
> - CoreDNS : Deployment `coredns` (2 réplicas kubeadm, 1 minikube), ConfigMap `coredns`, `dnsPolicy: Default`, sondes `/health` 8080 et `/ready` 8181, métriques 9153.
> - L'ordre des plugins est celui de la compilation, pas du Corefile : `hosts` passe avant `kubernetes` et doit finir par `fallthrough`, sinon SERVFAIL général.
> - Une modification du Corefile prend effet en deux minutes environ via `reload` ; un Corefile invalide est ignoré jusqu'au prochain redémarrage, qui le fait planter.
> - `ndots:5` : un nom de moins de 5 points passe d'abord par les trois domaines de recherche ; un point final rend un nom absolu ; `dig` n'applique la recherche qu'avec `+search`.
> - `dnsPolicy` : `ClusterFirst` par défaut ; `ClusterFirstWithHostNet` pour `hostNetwork` ; `Default` = le nœud ; `None` impose `dnsConfig` (3 serveurs, 32 domaines au plus ; valeurs d'options en chaînes).
> - minikube ne touche au Corefile et au nombre de réplicas qu'au premier démarrage du profil ; une ligne ajoutée au bloc `hosts` existant et les deux réplicas survivent à `stop`/`start` (vérifié).

### 11.11 Exercices

Les exercices 11.3 et 11.4 modifient durablement le cluster (état du chapitre) ; les autres sont des explorations ou des objets temporaires.

#### Exercice 11.1 — Lire le resolv.conf et compter les requêtes de ndots

**Point de départ** : fin du chapitre 10.

Affiche le `resolv.conf` d'`outils` et celui d'un pod CoreDNS. Depuis `outils`, résous `api` avec `dig`, puis avec `dig +search`, puis avec `nslookup`. Crée ensuite dans `boutique` un pod `dnsutils` (`registry.k8s.io/e2e-test-images/jessie-dnsutils:1.7`, `sleep 3600`), résous `example.com` depuis ce pod, et compte dans les journaux de CoreDNS les requêtes que cette seule résolution a produites. Garde `dnsutils` pour l'exercice suivant.

> [!example]- Solution
> ```bash
> kubectl -n boutique exec outils -- cat /etc/resolv.conf
> kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[0].spec.dnsPolicy}{"\n"}'
> minikube -p cka ssh -- cat /etc/resolv.conf
> ```
>
> `outils` a les trois domaines de recherche de `boutique`, `nameserver 10.96.0.10` et `ndots:5`. Les pods CoreDNS sont en `dnsPolicy: Default` : leur `resolv.conf` est celui du nœud (`nameserver 192.168.49.1`). L'image de CoreDNS ne contient pas de shell ; on lit donc le fichier du nœud, dont il hérite.
>
> ```bash
> kubectl -n boutique exec outils -- dig +short api
> kubectl -n boutique exec outils -- dig +short +search api
> kubectl -n boutique exec outils -- nslookup api
> ```
>
> `dig +short api` ne renvoie rien (le nom `api.` n'existe pas), `dig +search` et `nslookup` renvoient la ClusterIP de `api`, `nslookup` en affichant le nom complet `api.boutique.svc.cluster.local`. Le `nslookup` de netshoot ajoute une ligne `;; Got recursion not available from 10.96.0.10` : pour les noms qu'il sert lui-même (plugins `kubernetes` et `hosts`), CoreDNS répond sans le drapeau `ra`. La réponse est juste, ignore l'avertissement.
>
> ```bash
> kubectl -n boutique run dnsutils --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.7 --restart=Never --command -- sleep 3600
> kubectl -n boutique wait --for=condition=Ready pod/dnsutils --timeout=120s
> IP_DNSUTILS=$(kubectl -n boutique get pod dnsutils -o jsonpath='{.status.podIP}')
> kubectl -n boutique exec dnsutils -- nslookup example.com
> kubectl -n kube-system logs -l k8s-app=kube-dns --tail=200 | grep "$IP_DNSUTILS" | grep 'example.com'
> ```
>
> La création affiche un avertissement `would violate PodSecurity "restricted:latest"` : c'est le mode `warn` du namespace (chapitre 8), le pod est bien admis. Les journaux montrent quatre requêtes `A` : `example.com.boutique.svc.cluster.local.`, `example.com.svc.cluster.local.`, `example.com.cluster.local.` en `NXDOMAIN`, puis `example.com.` en `NOERROR`, plus une requête `NXDOMAIN` par domaine de recherche de ton poste (11.6), juste avant la dernière. Le `nslookup` de BIND 9.9 de cette image ne demande que des enregistrements A ; un programme qui passe par `getaddrinfo` demanderait aussi les AAAA et doublerait le compte.
>
> **Vérification** : `kubectl -n kube-system logs -l k8s-app=kube-dns --tail=200 | grep "$IP_DNSUTILS" | grep -c 'example.com'` affiche `4`, plus le nombre de domaines de recherche de ton poste (`6` avec deux domaines ; davantage si tu as relancé la commande), et `kubectl -n boutique exec dnsutils -- nslookup example.com.` (point final) n'ajoute qu'une seule ligne au journal.

#### Exercice 11.2 — Interroger tous les types d'enregistrements

**Point de départ** : exercice 11.1.

Depuis `outils`, à l'aide de `dig` et de noms complets, obtiens : l'enregistrement A de `api`, le SRV `_http._tcp.api.boutique.svc.cluster.local`, les A et les SRV du Service headless `api-pods`, le nom propre d'un pod `api` sous `api-pods`, l'enregistrement de ce même pod sous `pod.cluster.local`, le PTR de la ClusterIP de `api`, et le CNAME de `meteo`. Vérifie avec `dnsutils` qu'un pod d'un autre namespace devrait écrire `api.boutique`. Supprime enfin `dnsutils`.

> [!example]- Solution
> ```bash
> kubectl -n boutique exec outils -- dig +noall +answer api.boutique.svc.cluster.local
> kubectl -n boutique exec outils -- dig +noall +answer SRV _http._tcp.api.boutique.svc.cluster.local
> kubectl -n boutique exec outils -- dig +noall +answer api-pods.boutique.svc.cluster.local
> kubectl -n boutique exec outils -- dig +noall +answer SRV _http._tcp.api-pods.boutique.svc.cluster.local
> ```
>
> ```
> api.boutique.svc.cluster.local. 30 IN	A	10.110.27.164
> _http._tcp.api.boutique.svc.cluster.local. 30 IN SRV 0 100 8080 api.boutique.svc.cluster.local.
> api-pods.boutique.svc.cluster.local. 30	IN A	10.244.195.201
> api-pods.boutique.svc.cluster.local. 30	IN A	10.244.34.135
> _http._tcp.api-pods.boutique.svc.cluster.local.	30 IN SRV 0 50 8080 10-244-195-201.api-pods.boutique.svc.cluster.local.
> _http._tcp.api-pods.boutique.svc.cluster.local.	30 IN SRV 0 50 8080 10-244-34-135.api-pods.boutique.svc.cluster.local.
> ```
>
> Le TTL vaut 30 à chaque fois : c'est le `ttl 30` du plugin `kubernetes`, et le cache est désactivé pour `cluster.local`. L'ordre des A du headless change d'une requête à l'autre (`loadbalance`). Avec l'adresse d'un pod `api` lue dans la sortie précédente :
>
> ```bash
> IP_API=$(kubectl -n boutique get pods -l app=api -o jsonpath='{.items[0].status.podIP}')
> NOM=$(echo "$IP_API" | tr . -)
> kubectl -n boutique exec outils -- dig +short "$NOM.api-pods.boutique.svc.cluster.local"
> kubectl -n boutique exec outils -- dig +short "$NOM.boutique.pod.cluster.local"
> kubectl -n boutique exec outils -- dig +short -x "$(kubectl -n boutique get svc api -o jsonpath='{.spec.clusterIP}')"
> kubectl -n boutique exec outils -- dig +noall +answer meteo.boutique.svc.cluster.local
> kubectl -n boutique exec outils -- dig +short SRV _http._tcp.front.boutique.svc.cluster.local
> ```
>
> Les deux premières commandes renvoient l'adresse du pod ; le PTR renvoie `api.boutique.svc.cluster.local.` ; `meteo` renvoie une ligne `CNAME example.com.` suivie des adresses de `example.com` ; le SRV de `front` ne renvoie rien, son port n'ayant pas de nom.
>
> Pour simuler un client d'un autre namespace, on lui donne la liste de recherche de `default` par le nom complet :
>
> ```bash
> kubectl -n boutique exec dnsutils -- nslookup api.default.svc.cluster.local
> kubectl -n boutique exec dnsutils -- nslookup api.boutique
> kubectl -n boutique delete pod dnsutils --now
> ```
>
> La première échoue (`NXDOMAIN`, il n'y a pas de Service `api` dans `default`) : c'est ce que produirait `api` tout court depuis un pod de `default`. La seconde réussit grâce au deuxième domaine de recherche (`api.boutique` + `.svc.cluster.local`).
>
> **Vérification** : `kubectl -n boutique exec outils -- dig +short SRV _http._tcp.api.boutique.svc.cluster.local` renvoie `0 100 8080 api.boutique.svc.cluster.local.`, et `kubectl -n boutique get pod dnsutils` répond `NotFound`.

#### Exercice 11.3 — Passer CoreDNS à deux réplicas

**Point de départ** : exercice 11.2.

Passe le Deployment `coredns` à 2 réplicas, comme sur un cluster kubeadm. Vérifie qu'ils tournent sur deux nœuds différents et pourquoi, et que le Service `kube-dns` a bien deux backends sur chacun de ses ports.

> [!example]- Solution
> ```bash
> kubectl -n kube-system scale deployment coredns --replicas=2
> kubectl -n kube-system rollout status deployment coredns --timeout=180s
> kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
> kubectl -n kube-system get deployment coredns -o jsonpath='{.spec.template.spec.affinity.podAntiAffinity}{"\n"}'
> kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns
> ```
>
> Les deux pods sont sur des nœuds différents grâce à l'anti-affinité **préférée** (`weight: 100`, `topologyKey: kubernetes.io/hostname`) du Deployment créé par kubeadm : elle n'est pas obligatoire, elle n'empêcherait pas deux pods sur un même nœud si un seul nœud était disponible. L'EndpointSlice de `kube-dns` liste deux adresses pour les ports 53 (UDP et TCP) et 9153.
>
> Ce nombre de réplicas tient dans l'objet Deployment : minikube v1.39.0 ne le ramène à 1 qu'à la création du profil, pas à un `stop` suivi d'un `start` (11.5, vérifié sur le lab).
>
> **Vérification** : `kubectl -n kube-system get deployment coredns` affiche `2/2`, et `kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[*].spec.nodeName}'` affiche deux noms de nœuds différents.

#### Exercice 11.4 — Faire résoudre boutique.example par CoreDNS

**Point de départ** : exercice 11.3.

Sauvegarde la ConfigMap `coredns` dans `~/cka/reseau/coredns-avant.yaml`. Ajoute au bloc `hosts` existant une ligne qui fait résoudre `boutique.example` et `api.boutique.example` vers l'adresse du nœud `cka` (donnée par `minikube -p cka ip`), sans retirer `host.minikube.internal` ni `fallthrough`. Vérifie la prise en compte dans les journaux de CoreDNS, puis la résolution depuis `outils`, y compris celle d'un nom du cluster.

> [!example]- Solution
> ```bash
> minikube -p cka ip
> kubectl -n kube-system get configmap coredns -o yaml > ~/cka/reseau/coredns-avant.yaml
> kubectl -n kube-system edit configmap coredns
> ```
>
> Dans l'éditeur, le bloc devient (respecte l'indentation des lignes voisines) :
>
> ```
>         hosts {
>            192.168.49.1 host.minikube.internal
>            192.168.49.2 boutique.example api.boutique.example
>            fallthrough
>         }
> ```
>
> La forme non interactive, celle du script du lab, insère la ligne après celle de `host.minikube.internal` et remplace la ConfigMap :
>
> ```bash
> IP_CP=$(minikube -p cka ip)
> kubectl -n kube-system get configmap coredns -o yaml \
>   | sed -E "s/^( *)([0-9.]+ host\.minikube\.internal)\$/\1\2\n\1$IP_CP boutique.example api.boutique.example/" \
>   | kubectl replace -f -
> ```
>
> N'utilise qu'une des deux formes. On observe ensuite le rechargement (jusqu'à deux minutes), ou on le force :
>
> ```bash
> kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | sed -n '/hosts {/,/}/p'
> kubectl -n kube-system logs -l k8s-app=kube-dns --prefix --tail=20 | grep -i reload
> kubectl -n kube-system rollout restart deployment coredns
> kubectl -n kube-system rollout status deployment coredns --timeout=180s
> kubectl -n boutique exec outils -- dig +short boutique.example
> kubectl -n boutique exec outils -- dig +short api.boutique.example
> kubectl -n boutique exec outils -- dig +short api.boutique.svc.cluster.local
> kubectl -n boutique exec outils -- nslookup api.boutique.example
> ```
>
> Les journaux montrent `Reloading`, une ligne `plugin/reload: Running configuration SHA512 = …`, puis `Reloading complete` sur chaque pod (40 s et 65 s après le `replace` sur le lab), ou, après le redémarrage, de nouveaux pods sans erreur. Les deux noms en `.example` résolvent vers `192.168.49.2`, et le nom du Service `api` résout toujours vers sa ClusterIP : le `fallthrough` a bien laissé passer la requête vers le plugin `kubernetes`. Le `nslookup` passe d'abord par la liste de recherche (2 points < 5), où `kubernetes` répond NXDOMAIN (et l'amont pour les domaines de ton poste), avant d'essayer le nom absolu ; il affiche une ligne `;; Got recursion not available from 10.96.0.10` par requête servie par CoreDNS lui-même (voir l'exercice 11.1). Le contrôleur d'Ingress qui répondra sur `192.168.49.2` arrive au chapitre 12.11 ; pour l'instant, seul le nom est prêt.
>
> En cas d'erreur dans l'édition, rétablis la sauvegarde : `kubectl replace -f ~/cka/reseau/coredns-avant.yaml`.
>
> **Vérification** : `kubectl -n boutique exec outils -- dig +short boutique.example` affiche `192.168.49.2`, `kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | grep -c 'host.minikube.internal\|boutique.example\|fallthrough'` affiche au moins `3`, et `kubectl -n kube-system get pods -l k8s-app=kube-dns` montre deux pods `Running` sans redémarrage récent.

#### Exercice 11.5 — Un pod en dnsPolicy None

**Point de départ** : exercice 11.4. Cet exercice est temporaire.

Crée dans `boutique` le pod `dns-perso` du 11.7 (`dnsPolicy: None`, serveur `10.96.0.10`, seul domaine de recherche `boutique.svc.cluster.local`, options `ndots:1` et `timeout:2`). Lis son `resolv.conf`. Résous-y `api`, `api.boutique`, `api.boutique.svc.cluster.local` et `boutique.example`, et explique chaque résultat. Essaie ensuite de créer un pod `dns-vide` en `dnsPolicy: None` sans `dnsConfig`. Supprime les pods.

> [!example]- Solution
> ```bash
> cat > ~/cka/reseau/dns-perso.yaml <<'EOF'
> apiVersion: v1
> kind: Pod
> metadata:
>   name: dns-perso
>   namespace: boutique
> spec:
>   dnsPolicy: None
>   dnsConfig:
>     nameservers:
>     - 10.96.0.10
>     searches:
>     - boutique.svc.cluster.local
>     options:
>     - name: ndots
>       value: "1"
>     - name: timeout
>       value: "2"
>   containers:
>   - name: dnsutils
>     image: registry.k8s.io/e2e-test-images/jessie-dnsutils:1.7
>     command: ["sleep", "3600"]
> EOF
> kubectl apply -f ~/cka/reseau/dns-perso.yaml
> kubectl -n boutique wait --for=condition=Ready pod/dns-perso --timeout=120s
> kubectl -n boutique exec dns-perso -- cat /etc/resolv.conf
> for n in api api.boutique api.boutique.svc.cluster.local boutique.example; do
>   echo "== $n"; kubectl -n boutique exec dns-perso -- nslookup "$n" | tail -n 3
> done
> ```
>
> Le `resolv.conf` contient exactement `search boutique.svc.cluster.local`, `nameserver 10.96.0.10` et `options timeout:2 ndots:1` (le kubelet écrit les options dans cet ordre). `api` (0 point < 1) est complété par l'unique domaine de recherche et résout. `api.boutique` (1 point, donc au moins `ndots`) est d'abord essayé tel quel, et part vers l'amont : or `.boutique` est un vrai domaine de premier niveau d'Internet. Sur le lab, `api.boutique.` existe et le pod reçoit deux adresses publiques sans aucun rapport avec le Service ; si l'amont avait répondu `NXDOMAIN`, le résolveur aurait complété en `api.boutique.boutique.svc.cluster.local`, qui n'existe pas. Dans les deux cas, **le Service `api` n'est pas atteint**, alors que ce nom fonctionne dans un pod ordinaire : c'est le danger d'un `ndots` bas, un nom court qui s'échappe vers Internet. Le nom complet résout. `boutique.example` est essayé tel quel en premier et résout tout de suite par le bloc `hosts` : un seul aller-retour au lieu de quatre.
>
> ```bash
> kubectl -n boutique run dns-vide --image=busybox:1.37.0 --restart=Never --overrides='{"spec":{"dnsPolicy":"None"}}' -- sleep 60
> ```
>
> L'API refuse : ``spec.dnsConfig: Required value: must provide `dnsConfig` when `dnsPolicy` is None``.
>
> ```bash
> kubectl -n boutique delete pod dns-perso --now
> ```
>
> **Vérification** : `kubectl -n boutique get pods dns-perso dns-vide` répond `NotFound` pour les deux, et `kubectl -n boutique exec outils -- dig +short +search api.boutique` résout toujours depuis un pod ordinaire.

#### Exercice 11.6 — Reconnaître un DNS sans backend

**Point de départ** : exercice 11.5. Cet exercice est temporaire et rétablit 2 réplicas à la fin.

Ramène le Deployment `coredns` à 0 réplica. Depuis `outils`, interroge `api.boutique.svc.cluster.local` avec `dig` (un seul essai, délai de 2 secondes) et note la nature de l'échec. Retrouve sur un nœud la règle de kube-proxy qui produit ce comportement, puis rétablis 2 réplicas et vérifie le retour de la résolution.

> [!example]- Solution
> ```bash
> kubectl -n kube-system scale deployment coredns --replicas=0
> kubectl -n kube-system wait --for=delete pod -l k8s-app=kube-dns --timeout=60s
> kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns
> kubectl -n boutique exec outils -- dig +time=2 +tries=1 api.boutique.svc.cluster.local
> minikube -p cka ssh -n cka-m02 -- "sudo iptables -t filter -S KUBE-SERVICES | grep kube-dns"
> ```
>
> Le `wait` compte : pendant les secondes d'arrêt des pods (le `lameduck 5s` du plugin `health`), l'EndpointSlice les garde avec `ready: false`, `serving: true`, `terminating: true`, kube-proxy les utilise encore faute d'autre point d'accès (10.4), et `dig` répond normalement ou expire selon l'instant. Une fois les pods partis, l'EndpointSlice de `kube-dns` n'a plus aucune adresse (colonnes `PORTS` et `ENDPOINTS` à `<unset>`). `dig` échoue alors presque instantanément (0,06 s mesuré) avec `;; communications error to 10.96.0.10#53: connection refused` puis `;; no servers could be reached` (code de sortie 9), et non au bout de ses 2 secondes : la table `filter` du nœud contient, pour chacun des ports du Service, une règle `"kube-system/kube-dns:dns has no endpoints" … -j REJECT --reject-with icmp-port-unreachable`, et le message ICMP de refus arrive tout de suite au client. Un délai d'attente aurait orienté vers un filtrage (NetworkPolicy) ou vers un pod CoreDNS présent mais muet.
>
> ```bash
> kubectl -n kube-system scale deployment coredns --replicas=2
> kubectl -n kube-system rollout status deployment coredns --timeout=180s
> kubectl -n boutique exec outils -- dig +short api.boutique.svc.cluster.local
> kubectl -n boutique exec outils -- dig +short boutique.example
> ```
>
> Les nouveaux pods relisent le Corefile de la ConfigMap : l'entrée `boutique.example` de l'exercice 11.4 est toujours là. Un `dig` lancé à l'instant où `rollout status` rend la main peut encore être refusé : laisse une seconde à kube-proxy pour remplacer la règle `REJECT` par les nouveaux points d'accès.
>
> **Vérification** : `kubectl -n kube-system get deployment coredns` affiche `2/2`, `kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns` liste deux adresses, et `dig +short boutique.example` depuis `outils` renvoie `192.168.49.2`.

---
