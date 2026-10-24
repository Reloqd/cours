---
title: "CKA — 6. ConfigMaps et Secrets"
description: "Configurer les applications sans reconstruire leurs images : ConfigMaps et Secrets, leur consommation en variables et en volumes, la propagation des mises à jour, les objets immuables, les volumes projetés et la downward API, puis le chiffrement des Secrets au repos dans etcd, pour Kubernetes v1.37."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 6. ConfigMaps et Secrets

Une même image doit pouvoir tourner en recette et en production, avec des adresses, des niveaux de journalisation et des mots de passe différents. Kubernetes sépare donc la configuration de l'image en deux objets : la **ConfigMap** pour les réglages ordinaires, le **Secret** pour les données sensibles. Ce chapitre explique comment les créer vite, les quatre façons de les consommer, ce qui se passe réellement quand on les modifie (et pourquoi la moitié des consommateurs ne voient jamais la modification), ce que le Secret protège vraiment et ce qu'il ne protège pas, puis comment l'administrateur chiffre les Secrets dans etcd. Le programme officiel l'énonce par la compétence *Use ConfigMaps and Secrets to configure applications* ; les volumes `configMap`, `secret`, `projected` et `downwardAPI` relèvent aussi de *Configure volume types, access modes and reclaim policies*. Le chiffrement au repos n'est pas nommé dans le programme, mais il touche au manifeste de l'API server, terrain classique des tâches d'administration du control plane. À l'examen, une tâche typique demande une variable tirée d'une ConfigMap et un Secret monté dans un répertoire, en deux minutes : les générateurs de kubectl et la bonne page de documentation font la différence.

### 6.1 Séparer la configuration de l'image

Une ConfigMap est un objet de l'API, dans un namespace, qui stocke des paires clé-valeur. Elle a deux champs de données : `data`, pour des chaînes UTF-8, et `binaryData`, pour des octets quelconques encodés en base64. Les clés ne contiennent que des lettres, des chiffres, `-`, `_` et `.`, et une clé ne peut pas figurer dans les deux champs. L'objet entier ne doit pas dépasser **1 Mio** : une ConfigMap transporte des fichiers de configuration, pas des données.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: api-config
  namespace: boutique
data:
  APP_MODE: production
  LOG_LEVEL: info
```

Trois contraintes structurent l'usage. Un pod ne peut référencer qu'une ConfigMap de **son propre namespace**. Un pod statique ne peut en référencer aucune (et depuis 1.37 la porte `PreventStaticPodAPIReferences` n'existe plus pour contourner la règle). Enfin la ConfigMap doit exister **avant** le pod qui en dépend, sauf référence marquée `optional: true` : le kubelet ne démarre pas un conteneur dont la configuration manque (section 6.3).

### 6.2 Créer une ConfigMap

`kubectl create configmap` accepte quatre sources, combinables dans une même commande :

| Source | Clé obtenue | Valeur |
|---|---|---|
| `--from-literal=CLE=valeur` | `CLE` | `valeur` |
| `--from-file=chemin/fichier.conf` | nom du fichier (`fichier.conf`) | contenu du fichier |
| `--from-file=cle=chemin/fichier` | `cle` | contenu du fichier |
| `--from-file=repertoire/` | un par fichier ordinaire au nom valide ; sous-répertoires et liens ignorés | contenu de chaque fichier |
| `--from-env-file=fichier.env` | une par ligne `CLE=valeur` (lignes vides et `#` ignorées) | le texte après `=`, **guillemets compris** |

Le dernier piège est fréquent : une ligne `MODE="production"` dans un fichier d'environnement produit la valeur `"production"`, guillemets inclus, puisque kubectl ne fait aucune interprétation de shell. Un fichier dont le contenu n'est pas de l'UTF-8 valide atterrit dans `binaryData`.

```bash
kubectl -n boutique create configmap api-config \
  --from-literal=APP_MODE=production --from-literal=LOG_LEVEL=info \
  --dry-run=client -o yaml > ~/cka/boutique/api-config.yaml
```

Pour **modifier** une ConfigMap à partir des mêmes sources, sans éditeur, on régénère et on applique : `kubectl create configmap … --dry-run=client -o yaml | kubectl apply -f -`. Le générateur produit l'objet complet, `kubectl apply` calcule la différence. Pour une seule valeur, `kubectl -n boutique patch configmap api-config -p '{"data":{"LOG_LEVEL":"debug"}}'` suffit, et `kubectl edit` reste possible.

> [!tip] Réflexe d'examen
> Pour un fichier, `--from-file` garde le contenu exact, retours à la ligne compris, et nomme la clé d'après le fichier : c'est la forme qui se monte ensuite telle quelle dans un répertoire. Attention au tilde : dans `--from-file=~/x.conf`, le shell ne développe pas `~` (le mot commence par `--`). Place-toi dans le répertoire, ou écris `$HOME`.

### 6.3 Consommer une ConfigMap

#### En variables d'environnement

Une clé précise devient une variable avec `env[].valueFrom.configMapKeyRef` ; toutes les clés d'un coup, avec `envFrom[].configMapRef`, éventuellement préfixées par `prefix`. En cas de doublon, `env` l'emporte sur `envFrom` ([chapitre 4.3](04-pods.md)).

```yaml
    envFrom:
    - configMapRef:
        name: api-config
    env:
    - name: NIVEAU
      valueFrom:
        configMapKeyRef:
          name: api-config
          key: LOG_LEVEL
```

`envFrom` n'importe que `data`, pas `binaryData`. En 1.37, le kubelet importe toutes les clés : depuis que les noms de variables admettent tout caractère ASCII imprimable sauf `=` (1.34), toute clé de ConfigMap est un nom de variable acceptable, et l'événement `InvalidEnvironmentVariableNames` qu'évoque encore la documentation ne se produit plus pour ce motif. Une clé `app.mode` devient donc une variable `app.mode` : légale, mais inutilisable depuis un script shell, qui ne sait pas écrire `$app.mode`. Préfère des clés en majuscules et soulignés pour ce qui doit devenir une variable.

#### En volume

Un volume `configMap` écrit chaque clé dans un fichier du même nom, sous le point de montage. `items` restreint les clés projetées et choisit leur chemin, `defaultMode` (défaut `0644`) et `mode` règlent les permissions. Le volume est monté **en lecture seule**, et il **masque** tout ce que l'image contenait à cet endroit : monter une ConfigMap sur `/etc/nginx/conf.d` fait disparaître le `default.conf` d'origine.

```yaml
spec:
  containers:
  - name: nginx
    volumeMounts:
    - name: conf
      mountPath: /etc/nginx/conf.d
  volumes:
  - name: conf
    configMap:
      name: front-conf
      items:
      - key: default.conf
        path: default.conf
```

Pour déposer un seul fichier dans un répertoire existant sans masquer le reste, on monte avec `subPath`, qui désigne un fichier du volume :

```yaml
    volumeMounts:
    - name: conf
      mountPath: /etc/nginx/conf.d/boutique.conf
      subPath: default.conf
```

C'est commode, et c'est un piège : un fichier monté par `subPath` **n'est jamais mis à jour** (section 6.4).

#### Quand la configuration manque

| Situation | Effet | Message |
|---|---|---|
| ConfigMap absente, référencée en variable | conteneur non créé, `CreateContainerConfigError` | `configmap "api-config" not found` |
| clé absente (`configMapKeyRef`) | `CreateContainerConfigError` | `couldn't find key LOG_LEVEL in ConfigMap boutique/api-config` |
| ConfigMap absente, montée en volume | pod bloqué en `ContainerCreating` | événement `FailedMount` : `MountVolume.SetUp failed for volume "conf" : configmap "front-conf" not found` |
| référence avec `optional: true` | le pod démarre ; variable absente, ou volume vide (rempli plus tard si la ConfigMap apparaît) | aucun |

Le kubelet réessaie de lui-même : dès que la ConfigMap ou la clé apparaît, le conteneur démarre, sans qu'on touche au pod. Le même tableau vaut pour les Secrets (`secret "api-secret" not found`, `couldn't find key DB_PASSWORD in Secret boutique/api-secret`) : c'est la panne 03 du [chapitre 22](22-depanner-les-applications.md).

### 6.4 Propagation des mises à jour

Modifier une ConfigMap ne redémarre rien. Ce que voit l'application dépend entièrement de la façon dont elle consomme la ConfigMap, et c'est l'une des questions les plus mal comprises du sujet.

#### Le mécanisme des volumes

Le kubelet ne copie pas les clés directement sous le point de montage. Il écrit un jeu complet de fichiers dans un répertoire horodaté, fait pointer un lien `..data` vers lui, et chaque fichier visible n'est qu'un lien vers `..data/<clé>`. Pour une mise à jour, il écrit un nouveau répertoire horodaté, puis **remplace le lien `..data` en une seule opération atomique** : l'application voit l'ancien jeu complet ou le nouveau, jamais un mélange.

```
/usr/share/nginx/html  (volume configMap front-html)
═══════════════════════════════════════════════════

  index.html ──▶ ..data/index.html
  ..data     ──▶ ..2026_10_23_20_14_07.3012744591/      ← jeu courant
                 ..2026_10_23_20_14_07.3012744591/index.html

  mise à jour :  1. écriture de ..2026_10_23_20_31_52.1147880236/index.html
                 2. bascule atomique de ..data vers ce répertoire
                 3. suppression de l'ancien répertoire

  subPath : le conteneur reçoit un montage direct du fichier de l'ANCIEN
            répertoire ; la bascule de ..data ne le concerne pas.
```

Le moment de la mise à jour dépend de deux délais. Le kubelet vérifie les volumes de chaque pod à chaque **synchronisation périodique** (`syncFrequency`, 1 minute par défaut dans la configuration du kubelet), et il lit la ConfigMap dans un cache local alimenté, par défaut, par un **watch** sur l'API (`configMapAndSecretChangeDetectionStrategy: Watch`). Le délai total peut donc atteindre la période de synchronisation plus la propagation du watch : compte jusqu'à une minute environ, parfois un peu plus, et des pods différents du même Deployment voient le changement à des instants différents. Modifier une annotation du pod déclenche une synchronisation immédiate.

#### Ce que chaque consommateur voit

| Consommation | Mise à jour vue par le conteneur | Pour l'appliquer |
|---|---|---|
| volume `configMap` ou `secret` monté en répertoire | **oui**, après le délai de synchronisation | rien côté Kubernetes ; l'application doit relire le fichier |
| volume monté avec `subPath` | **jamais** | recréer le pod |
| variable `env` ou `envFrom` | **jamais** (l'environnement d'un processus est figé à son démarrage) | recréer le pod : `kubectl rollout restart deployment/…` |
| volume `projected` ou `downwardAPI` | oui (sauf `subPath`) | idem volume |

« Le fichier a changé » ne veut pas dire « l'application a changé ». nginx sert les fichiers statiques à chaque requête : un nouvel `index.html` est visible dès la bascule. Mais il lit sa configuration au démarrage : un nouveau `default.conf` reste ignoré jusqu'à un `nginx -s reload` ou un redémarrage. Dans un Deployment, la façon propre est `kubectl -n boutique rollout restart deployment/front`, qui remplace les pods progressivement, sans coupure.

> [!note] Rendre la mise à jour explicite
> Deux pratiques évitent ces ambiguïtés. La première : nommer chaque version de configuration différemment (`front-conf-v2`) et changer la référence dans le modèle du Deployment ; le changement de modèle déclenche un rollout, et le retour arrière ramène l'ancienne configuration avec l'ancienne révision. C'est ce que fait automatiquement le générateur `configMapGenerator` de Kustomize, en suffixant le nom d'un hachage du contenu ([chapitre 17.10](17-helm-et-kustomize.md)). La seconde : rendre ces ConfigMaps immuables (section 6.7).

### 6.5 Secrets : ce qui change, ce qui ne change pas

Un Secret se consomme exactement comme une ConfigMap (`secretKeyRef`, `envFrom[].secretRef`, volume `secret` avec `secretName`), avec les mêmes règles de mise à jour. Ce qui le distingue tient en quelques protections, et en une absence de protection qu'il faut connaître par cœur.

**Base64 n'est pas du chiffrement.** Les valeurs du champ `data` sont encodées en base64 parce que l'API transporte du JSON et qu'un Secret peut contenir des octets quelconques. Quiconque peut lire l'objet lit le secret :

```bash
kubectl -n boutique get secret api-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d; echo
```

```
changeme-123
```

Pour écrire un manifeste sans encoder à la main, le champ `stringData` accepte du texte brut ; le serveur d'API le fusionne dans `data` et ne le restitue jamais (en cas de doublon, `stringData` l'emporte). Si tu encodes toi-même, utilise `echo -n` : un `echo` sans `-n` ajoute un retour à la ligne qui fait partie du mot de passe.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: api-secret
  namespace: boutique
type: Opaque
stringData:
  DB_PASSWORD: changeme-123
```

Les protections réelles sont les suivantes. Un Secret n'est envoyé qu'aux nœuds dont un pod en a besoin. Le kubelet monte les volumes de Secrets dans un **tmpfs**, jamais sur disque, et efface sa copie quand le pod disparaît. `kubectl describe secret` n'affiche que la taille des valeurs (`DB_PASSWORD:  12 bytes`), et `kubectl describe pod` seulement l'origine d'une variable (`<set to the key 'DB_PASSWORD' in secret 'api-secret'>`). L'autorisation RBAC sépare les Secrets des autres objets ([chapitre 16](16-rbac-et-authentification.md)) ; mais attention, accorder `list` ou `watch` sur les Secrets d'un namespace revient à donner **tous** leurs contenus, pas seulement leurs noms, et quiconque peut créer un pod dans le namespace peut y monter n'importe quel Secret de ce namespace. Enfin, dans etcd, un Secret est stocké **en clair** tant que l'administrateur n'a pas configuré le chiffrement au repos (section 6.9).

Le type du Secret (`type`) indique les clés attendues et permet à l'API de les valider :

| Type | Usage | Clés | Création impérative |
|---|---|---|---|
| `Opaque` (défaut, chaîne vide équivalente) | données quelconques | libres | `kubectl create secret generic` |
| `kubernetes.io/tls` | certificat et clé TLS (Ingress, Gateway) | `tls.crt`, `tls.key` | `kubectl create secret tls NOM --cert=… --key=…` |
| `kubernetes.io/dockerconfigjson` | identifiants de registre | `.dockerconfigjson` | `kubectl create secret docker-registry` |
| `kubernetes.io/dockercfg` | ancien format `~/.dockercfg` | `.dockercfg` | |
| `kubernetes.io/basic-auth` | identifiant et mot de passe | `username`, `password` | |
| `kubernetes.io/ssh-auth` | clé SSH | `ssh-privatekey` | |
| `kubernetes.io/service-account-token` | jeton de ServiceAccount à longue durée, créé à la main | `token`, `ca.crt`, `namespace` | ([chapitre 16.9](16-rbac-et-authentification.md)) |
| `bootstrap.kubernetes.io/token` | jeton d'amorçage de kubeadm | `token-id`, `token-secret`… | ([chapitre 19.3.3](19-kubeadm-installation-ha-et-mises-a-jour.md)) |

Comme une ConfigMap, un Secret est limité à **1 Mio**. Monté en volume, chaque clé donne un fichier en mode `0644` par défaut ; `defaultMode: 0400` le restreint. En YAML, `0400` est lu comme un nombre octal ; en JSON, qui ne connaît pas l'octal, il faut écrire la valeur décimale `256`.

> [!warning] Variables d'environnement et secrets
> Un Secret en variable d'environnement est pratique et c'est la forme qu'attendent beaucoup d'applications, mais il fuit plus facilement : il est visible dans `/proc/<pid>/environ` de tout processus du conteneur, hérité par chaque sous-processus, et souvent recopié dans les journaux d'erreur ou les rapports de plantage. Un fichier dans un volume, lisible par le seul utilisateur de l'application (`defaultMode: 0400`), se protège mieux et se met à jour sans redémarrage.

### 6.6 Les Secrets de registre et `imagePullSecrets`

Pour tirer une image d'un registre privé, le kubelet a besoin d'identifiants. On les range dans un Secret de type `kubernetes.io/dockerconfigjson`, que le générateur fabrique :

```bash
kubectl -n boutique create secret docker-registry registre-prive \
  --docker-server=registre.example --docker-username=lecteur --docker-password='s3cret'
```

La clé `.dockerconfigjson` contient alors, encodé en base64, le JSON `{"auths":{"registre.example":{"username":"lecteur","password":"s3cret","auth":"bGVjdGV1cjpzM2NyZXQ="}}}`, où `auth` n'est que `lecteur:s3cret` en base64. Sans `--docker-server`, le générateur vise `https://index.docker.io/v1/`.

Le pod désigne ce Secret dans `spec.imagePullSecrets`, une liste de noms de Secrets **du même namespace**, valable pour tous ses conteneurs. Le kubelet présente au registre les identifiants dont le nom de serveur correspond à l'image ; les autres sont ignorés, si bien qu'un pod peut tirer des images publiques et privées. Pour ne pas répéter la liste dans chaque pod, on l'attache au ServiceAccount : l'admission `ServiceAccount` la recopie dans tout pod qui utilise ce compte ([chapitre 16.9](16-rbac-et-authentification.md)).

Un Secret référencé mais absent n'empêche pas le pod d'être créé : le kubelet tente le téléchargement sans ces identifiants et ne le note que dans son journal (`"Unable to retrieve pull secret, the image pull may not succeed." … secret="boutique/registre-absent"`). Depuis 1.37, l'événement `FailedToRetrieveImagePullSecret` (`Unable to retrieve some image pull secrets (registre-absent); attempting to pull the image may not succeed.`) n'est plus émis qu'en cas d'**échec** du téléchargement : un pod qui démarre normalement n'en porte aucun, même avec un Secret absent dans sa liste. Si l'image est vraiment privée, le pod finit en `ErrImagePull` puis `ImagePullBackOff`, et l'événement accompagne alors chaque échec en nommant le Secret manquant.

> [!note] Images déjà présentes sur le nœud
> Une image privée déjà téléchargée sur un nœud pouvait autrefois être utilisée par n'importe quel pod de ce nœud, avec `imagePullPolicy: IfNotPresent`, sans identifiants. Depuis 1.35, la porte `KubeletEnsureSecretPulledImages` (bêta, active par défaut) fait vérifier par le kubelet que le pod dispose des identifiants qui ont servi au téléchargement ; la politique par défaut, `NeverVerifyPreloadedImages`, exempte seulement les images présentes avant que le kubelet ne tienne ce registre.

### 6.7 ConfigMaps et Secrets immuables

Le champ `immutable: true` (stable depuis 1.21) fige le contenu d'une ConfigMap ou d'un Secret. Les champs `data` et `binaryData` ne peuvent plus changer, et `immutable` ne peut plus revenir à `false` ; seules les métadonnées (labels, annotations) restent modifiables. Toute tentative est refusée :

```
The ConfigMap "parametres-figes" is invalid: data: Forbidden: field is immutable when `immutable` is set
```

On y gagne deux choses. La sûreté d'abord : une configuration de production ne peut plus être modifiée par erreur, et une nouvelle version passe par un nouvel objet, référencé explicitement. La charge ensuite : le kubelet ne surveille plus ces objets, ce qui allège l'API server sur un cluster qui monte des dizaines de milliers de ConfigMaps. Pour changer le contenu, on supprime et on recrée l'objet ; les pods qui le montaient gardent leurs fichiers, mais la documentation recommande de les recréer aussi.

### 6.8 Volumes projetés et downward API

#### La downward API

La downward API expose au conteneur des informations sur **son propre pod**, sans lui donner accès à l'API. Deux références existent : `fieldRef` pour un champ du pod, `resourceFieldRef` pour une ressource d'un conteneur. Tous les champs ne sont pas disponibles des deux façons :

| Champ | Variable (`env`) | Volume `downwardAPI` |
|---|---|---|
| `metadata.name`, `metadata.namespace`, `metadata.uid` | oui | oui |
| `metadata.labels['cle']`, `metadata.annotations['cle']` | oui | oui |
| `metadata.labels`, `metadata.annotations` (tous, une ligne `cle="valeur"` chacun) | non | oui |
| `spec.nodeName`, `spec.serviceAccountName` | oui | non |
| `status.podIP`, `status.podIPs`, `status.hostIP`, `status.hostIPs` | oui | non |
| `resourceFieldRef` : `requests.cpu`, `limits.cpu`, `requests.memory`, `limits.memory`, `…ephemeral-storage`, `…hugepages-*` | oui | oui |

Une limit absente est remplacée par l'allocatable du nœud. `divisor` règle l'unité de la valeur exposée (`1Mi` pour des mébioctets, `1m` pour des millicœurs). Le volume suit les changements : un label modifié, ou une ressource redimensionnée en place ([chapitre 4.12](04-pods.md)), se retrouve dans le fichier ; la variable, elle, garde la valeur du démarrage. Le DaemonSet `agent-noeud` de l'[exercice 5.5](05-deployments-et-controleurs.md) lit ainsi `spec.nodeName` dans `NODE_NAME`.

#### Les volumes projetés

Un volume `projected` réunit dans un **même répertoire** plusieurs sources : `configMap`, `secret`, `downwardAPI`, `serviceAccountToken`, `clusterTrustBundle` et `podCertificate`. Toutes doivent être dans le namespace du pod. Les paramètres sont presque ceux des volumes individuels, à deux différences près : la source Secret s'écrit `name` (et non `secretName`), et `defaultMode` ne se fixe qu'au niveau du volume projeté, chaque élément pouvant ensuite fixer son propre `mode`.

```yaml
  volumes:
  - name: tout
    projected:
      defaultMode: 0440
      sources:
      - configMap:
          name: api-config
          items:
          - key: APP_MODE
            path: mode
      - secret:
          name: api-secret
          items:
          - key: DB_PASSWORD
            path: db/mot-de-passe
            mode: 0400
      - serviceAccountToken:
          audience: coffre.example
          expirationSeconds: 3600
          path: jeton
```

La source `serviceAccountToken` produit un jeton lié au pod, pour une audience donnée, avec une durée de validité d'une heure par défaut (600 secondes au minimum), renouvelé automatiquement par le kubelet : c'est le mécanisme même qui fournit son jeton à chaque pod ([chapitre 16.9](16-rbac-et-authentification.md)). Comme pour les autres volumes, un montage par `subPath` ne reçoit aucune mise à jour.

### 6.9 Chiffrer les Secrets au repos

#### Le problème

Le serveur d'API écrit chaque objet dans etcd, sous une clé `/registry/<ressource>/<namespace>/<nom>`. Par défaut, il l'écrit **tel quel**, sérialisé en protobuf : le préfixe `k8s` suivi d'un octet nul, puis les champs de l'objet, valeurs des Secrets comprises, **en clair** (le base64 n'existe que dans la représentation JSON de l'API). Quiconque lit le répertoire de données d'etcd, une sauvegarde ([chapitre 20.6](20-etcd-sauvegarde-et-restauration.md)) ou un disque recyclé lit tous les mots de passe du cluster.

Le chiffrement au repos (*encryption at rest*) fait chiffrer par l'API server les ressources choisies avant de les écrire. Il se configure par un fichier `EncryptionConfiguration` passé à l'option `--encryption-provider-config` du kube-apiserver.

```
ÉCRITURE ET LECTURE D'UN SECRET AVEC CHIFFREMENT
════════════════════════════════════════════════

 kubectl create secret …                                kubectl get secret …
        │                                                      ▲
        ▼                                                      │ déchiffré
 kube-apiserver ── 1er fournisseur de la liste : CHIFFRE        │ par le premier
        │          (aescbc, clé « cle1 »)                       │ fournisseur dont
        ▼                                                      │ le préfixe correspond
 etcd : /registry/secrets/boutique/api-secret                  │
        k8s:enc:aescbc:v1:cle1:<octets chiffrés> ───────────────┘
        (sans chiffrement : k8s\0<protobuf en clair>)
```

#### La configuration

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: cle1
              secret: c2VjcmV0IGlzIHNlY3VyZQ==
      - identity: {}
```

Chaque entrée de `resources` associe une liste de ressources (`secrets`, `configmaps`, `ressource.groupe`, ou les jokers `*.apps`, `*.` pour le groupe principal, `*.*` pour tout) à une liste **ordonnée** de fournisseurs. Les règles sont strictes :

- le **premier** fournisseur **chiffre** toutes les écritures ; si c'est `identity`, rien n'est chiffré ;
- à la lecture, chaque fournisseur dont le préfixe correspond aux données essaie, dans l'ordre ; `identity` en fin de liste permet de relire les objets écrits **avant** l'activation du chiffrement ;
- dans un fournisseur, la **première** clé chiffre, toutes les clés servent au déchiffrement : c'est ce qui permet la rotation ;
- une entrée ne contient qu'un type de fournisseur ; une entrée plus précise doit précéder un joker qui la recouvre (par exemple `events` en `identity` avant `*.*`).

| Fournisseur | Chiffrement | Clé | Remarque de la documentation |
|---|---|---|---|
| `identity` | aucun | | défaut implicite |
| `aescbc` | AES-CBC, remplissage PKCS#7 | 16, 24 ou 32 octets | jugé faible (attaques par oracle de remplissage), mais c'est l'exemple de la documentation |
| `aesgcm` | AES-GCM, nonce aléatoire | 16, 24 ou 32 octets | rotation obligatoire toutes les 200 000 écritures |
| `secretbox` | XSalsa20 et Poly1305 | 32 octets | robuste |
| `kms` v2 | chiffrement d'enveloppe, clés maîtresses dans un service externe | | le seul qui protège aussi contre la compromission de l'hôte |
| `kms` v1 | idem | | déprécié depuis 1.28 |

Les fournisseurs locaux (`aescbc`, `aesgcm`, `secretbox`) gardent la clé dans le fichier de configuration, sur chaque control plane : ils protègent contre le vol d'etcd ou d'une sauvegarde, pas contre l'accès à un control plane. Le fichier doit être lisible par root seul.

#### La procédure

1. Générer une clé de 32 octets aléatoires, encodée en base64 : `head -c 32 /dev/urandom | base64`.
2. Écrire le fichier sur le control plane, par convention `/etc/kubernetes/enc/enc.yaml`, en mode `0600`.
3. Sauvegarder le manifeste de l'API server **hors** de `/etc/kubernetes/manifests` : une copie laissée dans ce dossier, même nommée `.bak`, est chargée comme un second pod statique ([chapitre 2.5](02-architecture.md)).
4. Dans `/etc/kubernetes/manifests/kube-apiserver.yaml`, ajouter l'option, le montage et le volume :

```yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --encryption-provider-config=/etc/kubernetes/enc/enc.yaml
    volumeMounts:
    - name: enc
      mountPath: /etc/kubernetes/enc
      readOnly: true
  volumes:
  - name: enc
    hostPath:
      path: /etc/kubernetes/enc
      type: DirectoryOrCreate
```

(Fragment : les options, montages et volumes existants restent en place ; on ajoute ces lignes à leurs listes.) Le kubelet détecte la modification du manifeste et recrée le pod statique de l'API server ; l'API est injoignable pendant ce temps, une minute environ. L'option et le volume vont toujours **ensemble** : le processus de l'API server tourne dans un conteneur, et un fichier présent sur le nœud mais non monté donne un API server qui ne démarre pas.

5. Vérifier : un **nouveau** Secret apparaît chiffré dans etcd, avec le préfixe `k8s:enc:aescbc:v1:cle1:`, et se lit normalement par l'API.
6. Réécrire les Secrets **existants**, qui restent en clair tant qu'ils ne sont pas réécrits : `kubectl get secrets -A -o json | kubectl replace -f -` (la commande se relance sans danger en cas de conflit d'écriture). L'API `storagemigration.k8s.io/v1`, stable depuis 1.37, offre une alternative déclarative : un objet `StorageVersionMigration` sur la ressource `secrets`.
7. Une fois tout réécrit, retirer `identity` de la liste, pour qu'aucun Secret en clair ne soit plus accepté à la lecture.

La rotation d'une clé suit le même principe en plusieurs temps : ajouter la nouvelle clé en **deuxième** position et redémarrer tous les API servers (tous savent la lire), la passer en **première** position et redémarrer (tous l'utilisent pour écrire), réécrire tous les Secrets, puis retirer l'ancienne clé. Pour désactiver le chiffrement, on place `identity` en **premier** (en gardant l'ancien fournisseur derrière pour la lecture), on redémarre, on réécrit tous les Secrets, et seulement ensuite on retire l'option. Avec `--encryption-provider-config-automatic-reload=true`, l'API server relit le fichier toutes les minutes environ, sans redémarrage.

> [!danger] Perdre la clé, c'est perdre les Secrets
> Si l'API server ne peut plus déchiffrer une ressource (clé perdue, ordre des fournisseurs erroné, option retirée trop tôt), toute lecture de cette ressource échoue. Retirer l'option alors que des Secrets sont encore chiffrés produit l'erreur `identity transformer tried to read encrypted data` à chaque lecture. Le seul recours, sans la clé, est de supprimer les objets directement dans etcd. Sauvegarde la clé avant toute manipulation, et sur un cluster à plusieurs control planes, garde exactement la même configuration partout.

> [!info] minikube ≠ examen
> Le chemin `/etc/kubernetes/enc/enc.yaml` et la modification du manifeste sont identiques sur les deux. Ce qui change : sur minikube, on entre dans le nœud par `minikube -p cka ssh` (éditeur `vi`, fourni par `vim-tiny`), les certificats d'etcd sont dans `/var/lib/minikube/certs/etcd/` au lieu de `/etc/kubernetes/pki/etcd/`, et `etcdctl` n'est pas installé sur le nœud avant le chapitre 20 : on l'appelle dans le pod `etcd-cka`, dont l'image le contient. Sur un cluster kubeadm d'examen, on se connecte par `ssh` au control plane, puis `sudo -i`, et `etcdctl` est en général disponible sur le nœud.

> [!tip] Réflexe d'examen
> Page à ouvrir : « Encrypting Confidential Data at Rest » (kubernetes.io/docs/tasks/administer-cluster/encrypt-data/). Elle donne le fichier, le fragment de manifeste et la commande de vérification `etcdctl … get /registry/secrets/default/secret1 | hexdump -C`. Avant d'éditer le manifeste : copie de sauvegarde dans `/root/`. Après : `watch crictl ps` (avec `sudo`) jusqu'au retour du conteneur `kube-apiserver`, puis `kubectl get --raw /readyz`.

### 6.10 Pièges courants

```
Piège 1 : Attendre qu'une variable d'environnement se mette à jour
══════════════════════════════════════════════════════════════════
  SYMPTÔME : ConfigMap modifiée, l'application garde l'ancienne valeur
  CAUSE    : env et envFrom sont lus une fois, au démarrage du conteneur
  BON      : kubectl -n boutique rollout restart deployment/api

Piège 2 : Monter un fichier par subPath et compter sur la mise à jour
═════════════════════════════════════════════════════════════════════
  SYMPTÔME : le fichier ne change jamais, même après plusieurs minutes
  BON      : monter le répertoire entier (dans un dossier dédié), ou recréer le pod

Piège 3 : Monter une ConfigMap sur un répertoire de l'image
═══════════════════════════════════════════════════════════
  SYMPTÔME : les autres fichiers du répertoire ont disparu (mime.types…)
  BON      : un répertoire dédié, ou subPath pour un fichier isolé

Piège 4 : Encoder un secret avec echo
═════════════════════════════════════
  MAUVAIS  : echo motdepasse | base64      (retour à la ligne inclus)
  BON      : echo -n motdepasse | base64, ou stringData, ou --from-literal

Piège 5 : Les guillemets d'un fichier --from-env-file
═════════════════════════════════════════════════════
  MAUVAIS  : MODE="production" dans le fichier
  SYMPTÔME : la valeur vaut "production", guillemets compris
  BON      : MODE=production

Piège 6 : Un Secret dans un autre namespace
═══════════════════════════════════════════
  SYMPTÔME : CreateContainerConfigError, secret "x" not found
  BON      : le Secret doit être dans le namespace du pod ; le copier

Piège 7 : Option d'encryption sans volume
═════════════════════════════════════════
  MAUVAIS  : --encryption-provider-config=… ajouté, hostPath oublié
  SYMPTÔME : API server qui redémarre en boucle, kubectl injoignable
  BON      : option + volumeMounts + volumes ; diagnostic par crictl ps -a
             et crictl logs sur le nœud (chapitre 23)

Piège 8 : identity en premier
═════════════════════════════
  SYMPTÔME : configuration en place, mais etcd contient toujours k8s\0…
  CAUSE    : seul le PREMIER fournisseur chiffre
  BON      : aescbc (ou secretbox, kms) en tête, identity en dernier

Piège 9 : Retirer le chiffrement d'un coup
══════════════════════════════════════════
  SYMPTÔME : « identity transformer tried to read encrypted data »
  BON      : identity en tête, redémarrage, réécriture des Secrets,
             puis seulement retrait de l'option
```

> [!summary] À retenir
> - ConfigMap et Secret : objets d'un namespace, 1 Mio au plus, consommés par les pods du même namespace seulement, jamais par un pod statique.
> - Générateurs : `--from-literal`, `--from-file` (clé = nom du fichier), `--from-env-file` (guillemets conservés) ; modifier par `create … --dry-run=client -o yaml | kubectl apply -f -`.
> - Variable : `configMapKeyRef`/`secretKeyRef` ou `envFrom` ; `env` l'emporte sur `envFrom` ; une ConfigMap ou une clé manquante donne `CreateContainerConfigError`, un volume manquant `ContainerCreating` et `FailedMount`.
> - Volume : un fichier par clé, en lecture seule, qui masque le répertoire ; mise à jour atomique par le lien `..data`, dans la minute environ (synchronisation du kubelet + watch).
> - Jamais mis à jour : les variables d'environnement et les montages `subPath` ; on recrée les pods (`rollout restart`).
> - Base64 n'est pas du chiffrement ; un Secret est protégé par RBAC, par sa distribution limitée aux nœuds concernés et par le tmpfs, pas par son encodage ; `list` sur les Secrets donne leur contenu.
> - `imagePullSecrets` : Secret `kubernetes.io/dockerconfigjson` du même namespace, au niveau du pod ou du ServiceAccount.
> - `immutable: true` : contenu figé, retour impossible, moins de charge sur l'API server.
> - Downward API : `spec.nodeName` et `status.podIP` en variable seulement, tous les labels en volume seulement ; le volume suit les changements, la variable non.
> - Chiffrement au repos : `EncryptionConfiguration`, premier fournisseur = chiffrement, `identity` en dernier pour relire l'existant, option + volume dans le manifeste de l'API server, puis réécriture des Secrets existants ; préfixe `k8s:enc:aescbc:v1:<clé>:` dans etcd.

### 6.11 Exercices

Les exercices 6.1 et 6.2 complètent `front` et `api` ; les suivants créent des objets temporaires, supprimés à la fin de chaque exercice. L'exercice 6.7 modifie le control plane : il est avancé, entièrement réversible, et laisse le cluster dans son état initial.

#### Exercice 6.1 — La page et la configuration de `front`

**Point de départ** : exercice 5.9, ou instantané I0 suivi, dans l'ordre, de `lab/etats/03-kubectl-efficace/appliquer.sh`, `lab/etats/04-pods/appliquer.sh` et `lab/etats/05-deployments-et-controleurs/appliquer.sh`.

Dans `boutique`, crée la ConfigMap `front-html` dont la clé `index.html` contient `<h1>Boutique</h1><p>v1</p>`, et la ConfigMap `front-conf` dont la clé `default.conf` contient une configuration nginx qui écoute le port 80, sert `/usr/share/nginx/html` pour `/` et relaie `/api/` vers `http://api:8080/`. Monte `front-html` sur `/usr/share/nginx/html` et `front-conf` sur `/etc/nginx/conf.d` dans le Deployment `front`, en documentant la révision. Vérifie depuis `outils` que `front` sert la page et relaie l'API.

> [!example]- Solution
> ```bash
> mkdir -p ~/cka/boutique/front && cd ~/cka/boutique/front
> printf '<h1>Boutique</h1><p>v1</p>\n' > index.html
> cat > default.conf <<'EOF'
> server {
>     listen 80;
>     location / { root /usr/share/nginx/html; }
>     location /api/ { proxy_pass http://api:8080/; }
> }
> EOF
> kubectl -n boutique create configmap front-html --from-file=index.html \
>   --dry-run=client -o yaml > ~/cka/boutique/front-html.yaml
> kubectl -n boutique create configmap front-conf --from-file=default.conf \
>   --dry-run=client -o yaml > ~/cka/boutique/front-conf.yaml
> kubectl apply -f ~/cka/boutique/front-html.yaml -f ~/cka/boutique/front-conf.yaml
> ```
>
> Dans `~/cka/boutique/front.yaml`, on remplace la valeur de l'annotation `kubernetes.io/change-cause` par `montage des ConfigMaps front-html et front-conf`, et on ajoute au modèle de pod :
>
> ```yaml
> spec:
>   template:
>     spec:
>       containers:
>       - name: nginx
>         volumeMounts:
>         - name: html
>           mountPath: /usr/share/nginx/html
>         - name: conf
>           mountPath: /etc/nginx/conf.d
>       volumes:
>       - name: html
>         configMap:
>           name: front-html
>       - name: conf
>         configMap:
>           name: front-conf
> ```
>
> (fragment à fusionner dans le manifeste existant : le conteneur `nginx` garde son image, son port, sa sonde et ses ressources)
>
> ```bash
> kubectl apply -f ~/cka/boutique/front.yaml
> kubectl -n boutique rollout status deployment/front
> ```
>
> Les ConfigMaps sont créées **avant** la modification du Deployment : sinon, les nouveaux pods resteraient en `ContainerCreating` (`FailedMount`), et, grâce à `maxUnavailable: 0`, les anciens continueraient de servir. L'annotation et le modèle changent dans la même écriture : la nouvelle révision reçoit directement la bonne cause, sans l'héritage de `image nginx:1.30.6-alpine`. nginx résout le nom `api` au démarrage, par le DNS du cluster et le domaine de recherche `boutique.svc.cluster.local` : le Service `api` créé au chapitre 5 doit exister, faute de quoi nginx refuse de démarrer (`host not found in upstream "api"`).
>
> Juste après la fin du rollout, une première requête peut encore être aiguillée vers un ancien pod, déjà supprimé, que kube-proxy n'a pas fini de retirer de ses règles (une à deux secondes sur le lab) : le `curl` reste alors bloqué deux minutes. Interromps-le par Ctrl+C et relance-le, ou ajoute `-m 5` à `curl`.
>
> **Vérification** :
>
> ```bash
> kubectl -n boutique exec outils -- curl -s http://front/
> kubectl -n boutique exec outils -- curl -s http://front/api/hostname; echo
> kubectl -n boutique rollout history deployment/front | grep -E '^[45] '
> ```
>
> ```
> <h1>Boutique</h1><p>v1</p>
> api-7d9c5b8f4-k2m9x
> 4         image nginx:1.30.6-alpine
> 5         montage des ConfigMaps front-html et front-conf
> ```

#### Exercice 6.2 — `api-config` et `api-secret` dans `api`

**Point de départ** : exercice 6.1.

Dans `boutique`, crée la ConfigMap `api-config` (`APP_MODE=production`, `LOG_LEVEL=info`) et le Secret `api-secret` (clé `DB_PASSWORD`, valeur `changeme-123`). Fais lire au Deployment `api` toutes les clés de `api-config` comme variables d'environnement, et la variable `DB_PASSWORD` depuis le Secret. Vérifie les variables dans un pod, ce qu'en montre `kubectl describe`, et relis la valeur du Secret depuis l'API.

> [!example]- Solution
> ```bash
> kubectl -n boutique create configmap api-config \
>   --from-literal=APP_MODE=production --from-literal=LOG_LEVEL=info \
>   --dry-run=client -o yaml > ~/cka/boutique/api-config.yaml
> kubectl -n boutique create secret generic api-secret \
>   --from-literal=DB_PASSWORD=changeme-123 \
>   --dry-run=client -o yaml > ~/cka/boutique/api-secret.yaml
> kubectl apply -f ~/cka/boutique/api-config.yaml -f ~/cka/boutique/api-secret.yaml
> ```
>
> Dans `~/cka/boutique/api.yaml`, au conteneur `agnhost` :
>
> ```yaml
>         envFrom:
>         - configMapRef:
>             name: api-config
>         env:
>         - name: DB_PASSWORD
>           valueFrom:
>             secretKeyRef:
>               name: api-secret
>               key: DB_PASSWORD
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/api.yaml
> kubectl -n boutique rollout status deployment/api
> ```
>
> Le fichier `api-secret.yaml` contient la valeur en base64 (`Y2hhbmdlbWUtMTIz`) : ne le confonds pas avec une version chiffrée, et ne le range pas dans un dépôt de code. Comme les variables sont lues au démarrage, le rollout (nouveau modèle, nouveaux pods) est précisément ce qui les fait prendre en compte.
>
> **Vérification** :
>
> ```bash
> kubectl -n boutique exec deploy/api -- env | grep -E '^(APP_MODE|LOG_LEVEL|DB_PASSWORD)=' | sort
> kubectl -n boutique describe pod -l app=api | grep -m1 -A3 'Environment Variables from'
> kubectl -n boutique get secret api-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d; echo
> ```
>
> ```
> APP_MODE=production
> DB_PASSWORD=changeme-123
> LOG_LEVEL=info
>     Environment Variables from:
>       api-config  ConfigMap  Optional: false
>     Environment:
>       DB_PASSWORD:  <set to the key 'DB_PASSWORD' in secret 'api-secret'>  Optional: false
> changeme-123
> ```
>
> `describe` ne montre que l'origine de la variable ; `exec … env` et la lecture de l'objet montrent la valeur. C'est l'état que reprennent tous les chapitres suivants.

#### Exercice 6.3 — Qui voit la mise à jour ?

**Point de départ** : exercice 6.2.

Crée dans `boutique` une ConfigMap temporaire `propagation` (clé `message`, valeur `v1`) et un pod temporaire `propagation` (`busybox:1.37.0`, `sleep 3600`) qui la consomme de trois façons : variable `MESSAGE`, volume complet monté sur `/config`, et fichier `message` monté seul par `subPath` sur `/sous-chemin/message`. Passe la valeur à `v2`, mesure qui la voit et au bout de combien de temps, puis supprime le pod et la ConfigMap.

> [!example]- Solution
> ```yaml
> apiVersion: v1
> kind: ConfigMap
> metadata:
>   name: propagation
>   namespace: boutique
> data:
>   message: v1
> ---
> apiVersion: v1
> kind: Pod
> metadata:
>   name: propagation
>   namespace: boutique
> spec:
>   terminationGracePeriodSeconds: 1
>   containers:
>   - name: appli
>     image: busybox:1.37.0
>     command: ["sleep", "3600"]
>     env:
>     - name: MESSAGE
>       valueFrom:
>         configMapKeyRef: {name: propagation, key: message}
>     volumeMounts:
>     - name: cm
>       mountPath: /config
>     - name: cm
>       mountPath: /sous-chemin/message
>       subPath: message
>   volumes:
>   - name: cm
>     configMap:
>       name: propagation
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/propagation.yaml
> kubectl -n boutique wait --for=condition=Ready pod/propagation
> kubectl -n boutique exec propagation -- ls -la /config
> kubectl -n boutique patch configmap propagation -p '{"data":{"message":"v2"}}'
> for i in $(seq 1 24); do
>   kubectl -n boutique exec propagation -- \
>     sh -c 'echo "$(date +%T) volume=$(cat /config/message) subpath=$(cat /sous-chemin/message) env=$MESSAGE"'
>   sleep 5
> done
> kubectl -n boutique delete pod propagation --now
> kubectl -n boutique delete configmap propagation
> ```
>
> Le listing de `/config` montre le mécanisme de la section 6.4 : `message -> ..data/message`, `..data -> ..2026_…`, et le répertoire horodaté. Les apostrophes de la boucle protègent `$(cat …)` et `$MESSAGE` du shell local : ils sont interprétés dans le conteneur. Une même ConfigMap peut être montée deux fois par le même volume, une fois en répertoire, une fois par `subPath`.
>
> **Vérification** : les premières lignes affichent `volume=v1 subpath=v1 env=v1` ; au bout d'une minute environ (le délai varie : 43 à 46 s mesurées sur le lab pour un pod démarré depuis une minute, cinq secondes au plus pour un pod qui venait de démarrer), elles deviennent `volume=v2 subpath=v1 env=v1`, et ne changent plus. Seul le volume complet suit la modification. Pour accélérer l'observation, `kubectl -n boutique annotate pod propagation essai=1` déclenche une synchronisation immédiate du kubelet.

#### Exercice 6.4 — Un Secret de registre

**Point de départ** : exercice 6.3.

Crée dans `boutique` un Secret temporaire `registre-prive` donnant accès au registre `registre.example` (utilisateur `lecteur`, mot de passe `s3cret`) et décode son contenu. Crée ensuite un pod temporaire `prive` (`busybox:1.37.0`, `sleep 3600`) qui déclare deux secrets de registre : `registre-prive` et un Secret inexistant `registre-absent`. Explique pourquoi le pod démarre et ce que signalent ses événements. Supprime le pod et le Secret.

> [!example]- Solution
> ```bash
> kubectl -n boutique create secret docker-registry registre-prive \
>   --docker-server=registre.example --docker-username=lecteur --docker-password='s3cret'
> kubectl -n boutique get secret registre-prive -o jsonpath='{.type}{"\n"}'
> kubectl -n boutique get secret registre-prive -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d; echo
> ```
>
> Le point de la clé `.dockerconfigjson` doit être échappé dans jsonpath (`\.`), sinon il serait lu comme un séparateur de champs.
>
> ```yaml
> apiVersion: v1
> kind: Pod
> metadata:
>   name: prive
>   namespace: boutique
> spec:
>   terminationGracePeriodSeconds: 1
>   imagePullSecrets:
>   - name: registre-prive
>   - name: registre-absent
>   containers:
>   - name: appli
>     image: busybox:1.37.0
>     command: ["sleep", "3600"]
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/prive.yaml
> kubectl -n boutique wait --for=condition=Ready pod/prive --timeout=60s
> kubectl -n boutique events --for pod/prive | grep -i secret
> NOEUD=$(kubectl -n boutique get pod prive -o jsonpath='{.spec.nodeName}')
> minikube -p cka ssh -n "$NOEUD" -- "sudo journalctl -u kubelet --since '-5min' | grep -m1 'pull secret'"
> ```
>
> L'image `busybox` vient de Docker Hub : les identifiants de `registre.example` ne lui correspondent pas et ne sont pas présentés. Le Secret absent n'empêche pas la création : le kubelet tire l'image sans lui, et le pod démarre. Ses événements ne disent rien du Secret manquant (le `grep` ne renvoie rien) : depuis 1.37, `FailedToRetrieveImagePullSecret` n'est émis que si un téléchargement échoue, et seul le journal du kubelet garde la trace. Pour voir l'événement, il faut un téléchargement qui échoue, par exemple une image du registre fictif :
>
> ```bash
> kubectl -n boutique run prive-image --image=registre.example/appli:1.0 --restart=Never \
>   --overrides='{"spec":{"imagePullSecrets":[{"name":"registre-prive"},{"name":"registre-absent"}]}}'
> sleep 10; kubectl -n boutique events --for pod/prive-image | grep -E 'ErrImagePull|ImagePullSecret'
> kubectl -n boutique delete pod prive prive-image --now
> kubectl -n boutique delete secret registre-prive
> ```
>
> **Vérification** :
>
> ```
> kubernetes.io/dockerconfigjson
> {"auths":{"registre.example":{"username":"lecteur","password":"s3cret","auth":"bGVjdGV1cjpzM2NyZXQ="}}}
> pod/prive condition met
> … "Unable to retrieve pull secret, the image pull may not succeed." pod="boutique/prive" secret="boutique/registre-absent" err="secret \"registre-absent\" not found"
> …   Warning   Failed                            Pod/prive-image   Error: ErrImagePull
> …   Warning   FailedToRetrieveImagePullSecret   Pod/prive-image   Unable to retrieve some image pull secrets (registre-absent); attempting to pull the image may not succeed.
> ```
>
> Le pod `prive` était `Running`, le pod `prive-image` en `ImagePullBackOff` (`registre.example` n'existe pas), avant leur suppression.

#### Exercice 6.5 — Une ConfigMap immuable

**Point de départ** : exercice 6.4.

Crée dans `boutique` une ConfigMap temporaire immuable `parametres-figes` (clé `seuil`, valeur `10`). Essaie de changer la valeur, puis de rendre l'objet modifiable, puis de lui ajouter une annotation. Remplace enfin la valeur par `20` de la seule façon possible, et supprime l'objet.

> [!example]- Solution
> ```yaml
> apiVersion: v1
> kind: ConfigMap
> metadata:
>   name: parametres-figes
>   namespace: boutique
> data:
>   seuil: "10"
> immutable: true
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/parametres-figes.yaml
> kubectl -n boutique patch configmap parametres-figes -p '{"data":{"seuil":"20"}}'
> kubectl -n boutique patch configmap parametres-figes -p '{"immutable":false}'
> kubectl -n boutique annotate configmap parametres-figes revue=faite
> sed -i 's/seuil: "10"/seuil: "20"/' ~/cka/boutique/parametres-figes.yaml
> kubectl replace --force -f ~/cka/boutique/parametres-figes.yaml
> kubectl -n boutique get configmap parametres-figes -o jsonpath='{.data.seuil}{"\n"}'
> kubectl -n boutique delete configmap parametres-figes
> ```
>
> `"10"` est entre guillemets : une valeur de `data` doit être une chaîne, et un `10` nu serait un entier YAML, refusé à la création. Les deux premiers patchs échouent, l'annotation passe (les métadonnées restent modifiables), et `replace --force` supprime puis recrée l'objet.
>
> **Vérification** :
>
> ```
> The ConfigMap "parametres-figes" is invalid: data: Forbidden: field is immutable when `immutable` is set
> The ConfigMap "parametres-figes" is invalid: immutable: Forbidden: field is immutable when `immutable` is set
> configmap/parametres-figes annotated
> configmap "parametres-figes" deleted from boutique namespace
> configmap/parametres-figes replaced
> 20
> ```

#### Exercice 6.6 — Un volume projeté et la downward API

**Point de départ** : exercice 6.5.

Crée dans `boutique` un pod temporaire `identite` (`busybox:1.37.0`, `sleep 3600`, labels `app=identite` et `version=1`, requests `50m`/`32Mi`, limits `100m`/`64Mi`) qui reçoit :

- une variable `LIMITE_MEMOIRE_MI` égale à sa limite mémoire exprimée en Mio ;
- un volume projeté monté sur `/etc/identite`, en mode `0440` par défaut, réunissant tous les labels du pod (fichier `labels`), son nom (fichier `nom`), la clé `APP_MODE` de `api-config` (fichier `mode`) et la clé `DB_PASSWORD` de `api-secret` (fichier `db/mot-de-passe`, mode `0400`).

Change ensuite le label `version` en `2` et observe le fichier `labels`. Supprime le pod.

> [!example]- Solution
> ```yaml
> apiVersion: v1
> kind: Pod
> metadata:
>   name: identite
>   namespace: boutique
>   labels:
>     app: identite
>     version: "1"
> spec:
>   terminationGracePeriodSeconds: 1
>   containers:
>   - name: appli
>     image: busybox:1.37.0
>     command: ["sleep", "3600"]
>     resources:
>       requests: {cpu: 50m, memory: 32Mi}
>       limits: {cpu: 100m, memory: 64Mi}
>     env:
>     - name: LIMITE_MEMOIRE_MI
>       valueFrom:
>         resourceFieldRef: {resource: limits.memory, divisor: 1Mi}
>     volumeMounts:
>     - name: tout
>       mountPath: /etc/identite
>   volumes:
>   - name: tout
>     projected:
>       defaultMode: 0440
>       sources:
>       - downwardAPI:
>           items:
>           - path: labels
>             fieldRef: {fieldPath: metadata.labels}
>           - path: nom
>             fieldRef: {fieldPath: metadata.name}
>       - configMap:
>           name: api-config
>           items:
>           - key: APP_MODE
>             path: mode
>       - secret:
>           name: api-secret
>           items:
>           - key: DB_PASSWORD
>             path: db/mot-de-passe
>             mode: 0400
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/identite.yaml
> kubectl -n boutique wait --for=condition=Ready pod/identite
> kubectl -n boutique exec identite -- sh -c 'echo $LIMITE_MEMOIRE_MI; cat /etc/identite/labels; echo; cat /etc/identite/nom /etc/identite/mode; echo'
> kubectl -n boutique exec identite -- ls -lL /etc/identite/mode /etc/identite/db/mot-de-passe
> kubectl -n boutique label pod identite version=2 --overwrite
> sleep 60; kubectl -n boutique exec identite -- cat /etc/identite/labels; echo
> kubectl -n boutique delete pod identite --now
> ```
>
> `version: "1"` est entre guillemets : une valeur de label est une chaîne. Le label `metadata.labels` complet n'existe qu'en volume, pas en variable. `ls -lL` suit les liens symboliques jusqu'aux fichiers réels pour en afficher les permissions. Le processus tourne en root : les modes `0440` et `0400` ne le gênent pas, mais un processus d'un autre utilisateur, sans `fsGroup`, ne pourrait plus lire ces fichiers.
>
> **Vérification** : la première commande affiche `64`, puis `app="identite"` et `version="1"` sur deux lignes, puis `identiteproduction` (les fichiers `nom` et `mode` ne se terminent pas par un retour à la ligne : `cat` colle leurs contenus) ; les permissions sont `-r--r-----` pour `mode` et `-r--------` pour `mot-de-passe` ; après le changement de label, le fichier `labels` contient `version="2"` (dans la minute environ), alors que rien n'a redémarré.

#### Exercice 6.7 — Chiffrer les Secrets au repos (avancé, réversible)

**Point de départ** : exercice 6.6 (le Secret `api-secret` existe).

> [!warning] Cet exercice modifie le control plane
> Tu vas éditer le manifeste du pod statique `kube-apiserver` dans le nœud `cka`. Pendant chaque redémarrage de l'API server (une minute environ), `kubectl` ne répond plus. Une erreur dans le manifeste peut empêcher l'API server de redémarrer : la copie de sauvegarde faite à l'étape 2 est ton filet, et `lab/restaurer.sh I0` reste le dernier recours. L'exercice se termine par le **retour exact à l'état initial** : aucun chiffrement ne doit rester actif pour la suite du cours.

1. Vérifie que `api-secret` est stocké en clair dans etcd.
2. Active le chiffrement `aescbc` des Secrets, avec une clé nommée `cle1`, par le fichier `/etc/kubernetes/enc/enc.yaml` du nœud `cka`, en gardant la lecture des Secrets non chiffrés.
3. Crée un Secret `demo-chiffre` (clé `jeton`, valeur `abc123`) dans `boutique` et montre qu'il est chiffré dans etcd, alors que `api-secret` ne l'est pas encore ; puis chiffre tous les Secrets existants.
4. Reviens à l'état initial : tous les Secrets en clair dans etcd, option retirée du manifeste, fichiers supprimés, `demo-chiffre` supprimé.

> [!example]- Solution
> **Étape 1** — sur le poste, une fonction qui lit une clé d'etcd par l'`etcdctl` de l'image d'etcd (les certificats y sont montés au même chemin que sur le nœud) :
>
> ```bash
> etcdlire() {
>   kubectl -n kube-system exec etcd-cka -- etcdctl --endpoints=https://127.0.0.1:2379 \
>     --cacert=/var/lib/minikube/certs/etcd/ca.crt \
>     --cert=/var/lib/minikube/certs/etcd/server.crt \
>     --key=/var/lib/minikube/certs/etcd/server.key \
>     get "$1" --print-value-only
> }
> etcdlire /registry/secrets/boutique/api-secret | head -c 4 | od -c | head -1
> etcdlire /registry/secrets/boutique/api-secret | grep -a -c changeme-123
> ```
>
> La première commande affiche `0000000   k   8   s  \0` (le préfixe protobuf d'un objet non chiffré), la seconde `1` : le mot de passe est lisible tel quel.
>
> **Étape 2** — dans le nœud :
>
> ```bash
> minikube -p cka ssh
> sudo mkdir -p /etc/kubernetes/enc
> CLE=$(head -c 32 /dev/urandom | base64)
> sudo tee /etc/kubernetes/enc/enc.yaml > /dev/null <<EOF
> apiVersion: apiserver.config.k8s.io/v1
> kind: EncryptionConfiguration
> resources:
>   - resources:
>       - secrets
>     providers:
>       - aescbc:
>           keys:
>             - name: cle1
>               secret: ${CLE}
>       - identity: {}
> EOF
> sudo chmod 600 /etc/kubernetes/enc/enc.yaml
> sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.orig
> sudo vi /etc/kubernetes/manifests/kube-apiserver.yaml
> ```
>
> Dans le manifeste, on ajoute une ligne à la liste `command`, un élément à `volumeMounts` et un élément à `volumes` :
>
> ```yaml
>     - --encryption-provider-config=/etc/kubernetes/enc/enc.yaml
> ```
>
> ```yaml
>     - mountPath: /etc/kubernetes/enc
>       name: enc
>       readOnly: true
> ```
>
> ```yaml
>   - hostPath:
>       path: /etc/kubernetes/enc
>       type: DirectoryOrCreate
>     name: enc
> ```
>
> ```bash
> sudo diff /root/kube-apiserver.yaml.orig /etc/kubernetes/manifests/kube-apiserver.yaml
> exit
> until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 5; done; echo API prete
> kubectl -n kube-system get pod kube-apiserver-cka -o yaml | grep encryption-provider-config
> ```
>
> Le `diff` doit montrer exactement les huit lignes ajoutées. La sauvegarde est dans `/root`, hors du dossier `manifests`. La variable `CLE` n'existe que dans la session `ssh` : la clé n'est écrite que dans le fichier, lisible par root seul.
>
> **Étape 3** — sur le poste :
>
> ```bash
> kubectl -n boutique create secret generic demo-chiffre --from-literal=jeton=abc123
> etcdlire /registry/secrets/boutique/demo-chiffre | head -c 22; echo
> etcdlire /registry/secrets/boutique/api-secret | grep -a -c changeme-123
> kubectl get secrets -A -o json | kubectl replace -f -
> etcdlire /registry/secrets/boutique/api-secret | head -c 22; echo
> etcdlire /registry/secrets/boutique/api-secret | grep -a -c changeme-123
> kubectl -n boutique get secret api-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d; echo
> ```
>
> Le nouveau Secret commence par `k8s:enc:aescbc:v1:cle1`, mais `api-secret`, écrit avant l'activation, est encore en clair (`1`) : le chiffrement ne s'applique qu'aux écritures. Après `replace`, il est chiffré à son tour (`0` occurrence du mot de passe), et l'API le restitue normalement : le chiffrement est transparent pour les clients.
>
> **Étape 4** — retour arrière, dans le bon ordre. Dans le nœud, on place `identity` en tête des fournisseurs, en gardant `aescbc` derrière pour pouvoir relire les Secrets chiffrés :
>
> ```bash
> minikube -p cka ssh
> sudo vi /etc/kubernetes/enc/enc.yaml
> ```
>
> ```yaml
> apiVersion: apiserver.config.k8s.io/v1
> kind: EncryptionConfiguration
> resources:
>   - resources:
>       - secrets
>     providers:
>       - identity: {}
>       - aescbc:
>           keys:
>             - name: cle1
>               secret: <la clé, inchangée>
> ```
>
> Le manifeste n'ayant pas changé, le kubelet ne recrée pas le pod : on arrête le conteneur, qu'il relance aussitôt avec le fichier modifié.
>
> ```bash
> sudo crictl stop $(sudo crictl ps --name kube-apiserver -q)
> exit
> until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 5; done; echo API prete
> kubectl get secrets -A -o json | kubectl replace -f -
> etcdlire /registry/secrets/boutique/api-secret | grep -a -c changeme-123
> ```
>
> Le compte revient à `1` : `api-secret` est de nouveau écrit en clair. Alors seulement, on retire l'option :
>
> ```bash
> minikube -p cka ssh
> sudo cp /root/kube-apiserver.yaml.orig /etc/kubernetes/manifests/kube-apiserver.yaml
> sudo rm -rf /etc/kubernetes/enc /root/kube-apiserver.yaml.orig
> exit
> until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 5; done; echo API prete
> kubectl -n boutique delete secret demo-chiffre
> ```
>
> Retirer l'option avant d'avoir réécrit les Secrets aurait rendu `api-secret` illisible (`identity transformer tried to read encrypted data`), et `api` n'aurait plus pu démarrer de nouveau pod. Le `cp` vers `manifests` remplace le fichier modifié : le kubelet recrée l'API server sans l'option. On supprime `/etc/kubernetes/enc` seulement ensuite, puisque l'API server modifié montait ce répertoire.
>
> **Vérification** :
>
> ```bash
> minikube -p cka ssh -- 'sudo grep -c encryption /etc/kubernetes/manifests/kube-apiserver.yaml; ls /etc/kubernetes'
> etcdlire /registry/secrets/boutique/api-secret | head -c 4 | od -c | head -1
> kubectl -n boutique get secret api-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d; echo
> kubectl -n boutique get secret demo-chiffre
> ```
>
> ```
> 0
> addons  admin.conf  controller-manager.conf  kubelet.conf  manifests  scheduler.conf  super-admin.conf
> 0000000   k   8   s  \0
> changeme-123
> Error from server (NotFound): secrets "demo-chiffre" not found
> ```
>
> L'option a disparu du manifeste, le répertoire `enc` aussi, `api-secret` est stocké en clair comme au départ, et `demo-chiffre` n'existe plus. Le namespace `boutique` est dans l'état laissé par l'exercice 6.2 : c'est le point de départ du chapitre 7.

---
