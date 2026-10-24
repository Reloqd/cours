---
title: "CKA — 3. kubectl efficace : kubeconfig, impératif, sorties"
description: "Tout ce qui fait gagner des minutes à l'examen : kubeconfig et contextes, générateurs impératifs, explain, jsonpath, custom-columns et sort-by, sélecteurs, patch et replace, apply côté client et côté serveur, events, wait, exec et kuberc."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 3. kubectl efficace : kubeconfig, impératif, sorties

Ce chapitre est un chapitre de vitesse. Le CKA donne deux heures pour quinze à vingt tâches : six à huit minutes chacune, lecture de l'énoncé et vérification comprises. On n'y gagne pas en connaissant plus d'objets, mais en produisant un manifeste correct en vingt secondes, en extrayant une valeur d'un objet en une ligne, en sachant quelle commande modifie un champ sans tout réécrire. Le chapitre couvre le kubeconfig et les contextes, l'opposition entre impératif et déclaratif, chaque générateur utile, `kubectl explain`, les formats de sortie (jsonpath, custom-columns, sort-by), les sélecteurs, les commandes de modification, apply côté client et côté serveur, `kubectl events`, `wait`, `exec`, puis la configuration du terminal et le fichier de préférences `kuberc`. Aucune compétence du programme ne s'intitule « kubectl », mais toutes s'exercent avec lui, de *Understand application deployments and how to perform rolling update and rollbacks* à *Troubleshoot services and networking* : chaque minute économisée ici se reporte sur les tâches difficiles. Toutes les commandes sont données en entier (`kubectl`) ; l'alias `k`, présent à l'examen, est présenté en 3.10.

### 3.1 Le kubeconfig

#### 3.1.1 Structure

kubectl lit ses paramètres de connexion dans un fichier **kubeconfig**, de `kind: Config`. Il contient trois listes nommées et un pointeur : des **clusters** (adresse de l'API et autorité de certification), des **users** (les identifiants : certificat client, jeton, ou plugin `exec`), des **contexts**, chacun associant un cluster, un user et un namespace par défaut, et enfin `current-context`, le contexte utilisé quand on ne précise rien. Voici, épuré, celui qu'écrit minikube pour le profil `cka` :

```yaml
apiVersion: v1
kind: Config
clusters:
- name: cka
  cluster:
    server: https://192.168.49.2:8443
    certificate-authority: /home/apprenant/.minikube/ca.crt
users:
- name: cka
  user:
    client-certificate: /home/apprenant/.minikube/profiles/cka/client.crt
    client-key: /home/apprenant/.minikube/profiles/cka/client.key
contexts:
- name: cka
  context:
    cluster: cka
    user: cka
    namespace: default
current-context: cka
```

minikube référence les certificats **par chemin**. D'autres outils les embarquent en base64 dans `certificate-authority-data`, `client-certificate-data` et `client-key-data` ; `kubectl config view` masque alors ces valeurs (`DATA+OMITTED`, `REDACTED`) sauf avec `--raw`. Un chemin relatif dans un kubeconfig est relatif à l'emplacement du fichier. Pour fabriquer un kubeconfig autonome, transportable sur une autre machine, `kubectl config view --minify --flatten` ne garde que le contexte courant et embarque les certificats.

#### 3.1.2 Ordre de chargement et fusion

| Priorité | Source | Fusion |
|---|---|---|
| 1 | option `--kubeconfig=<fichier>` (une seule fois) | aucune : ce fichier seul |
| 2 | variable `KUBECONFIG=<f1>:<f2>:…` | fusion de tous les fichiers listés |
| 3 | `~/.kube/config` | aucune |

Quand `KUBECONFIG` liste plusieurs fichiers, le **premier qui définit une valeur l'emporte**, et une entrée n'est jamais complétée par un fichier suivant : si deux fichiers déclarent un user `cka`, seul celui du premier compte, en entier. Les écritures suivent une autre règle : une entrée existante est modifiée dans le fichier qui la définit ; une entrée nouvelle, et `current-context` lui-même, sont écrits dans le **premier fichier existant** de la liste. Ensuite, le contexte retenu est celui de `--context`, sinon `current-context` ; le cluster et le user sont ceux de `--cluster` et `--user`, sinon ceux du contexte ; et chaque champ peut encore être remplacé par une option (`--server`, `--certificate-authority`, `--token`…). Le namespace suit la même logique : `-n`/`--namespace`, sinon celui du contexte, sinon `default`.

> [!info] minikube ≠ examen
> Le lab écrit son contexte `cka` dans `~/.kube/config` (ou dans le fichier désigné par `KUBECONFIG`), avec l'API en **8443**. À l'examen, tu travailles sur des hôtes rejoints par `ssh` dont le kubeconfig est déjà en place, et le cluster écoute sur **6443**. Certaines tâches demandent encore de basculer de contexte : la commande à taper est alors donnée dans l'énoncé, et tu la tapes.

#### 3.1.3 Les commandes de contexte

| Besoin | Commande |
|---|---|
| Contexte courant | `kubectl config current-context` |
| Lister les contextes (`*` = courant) | `kubectl config get-contexts` (`-o name` pour les noms seuls) |
| Basculer | `kubectl config use-context boutique` |
| Créer ou compléter un contexte | `kubectl config set-context boutique --cluster=cka --user=cka --namespace=boutique` |
| Changer le namespace du contexte courant | `kubectl config set-context --current --namespace=boutique` |
| Voir la configuration effective | `kubectl config view --minify` |
| Lire un champ | `kubectl config view --minify -o jsonpath='{..namespace}'` |
| Corriger l'adresse d'un cluster | `kubectl config set-cluster cka --server=https://192.168.49.2:8443` |
| Renommer, supprimer | `kubectl config rename-context a b`, `kubectl config delete-context a` |
| Retirer une valeur | `kubectl config unset contexts.boutique.namespace` |

`set-context` sur un nom existant **fusionne** : seules les options passées changent. Sa sortie dit `Context "boutique" created.` ou `Context "boutique" modified.`, et `use-context` répond `Switched to context "boutique".` Ne confonds pas le `-n` de `set-context`, qui fixe le namespace **enregistré** dans le contexte, avec le `-n` des autres commandes, qui ne vaut que pour la commande en cours.

> [!tip] Réflexe d'examen
> Un énoncé donne toujours un namespace. Écris-le dans chaque commande (`-n boutique`) plutôt que de modifier le namespace du contexte : une tâche suivante, qui vise un autre namespace, n'héritera pas d'un réglage oublié. Le seul `set-context --current --namespace` sûr est celui que tu annules en fin de tâche.

### 3.2 Impératif ou déclaratif

kubectl offre trois façons de gérer les objets.

| Approche | Exemples | Trace | Usage à l'examen |
|---|---|---|---|
| Commandes impératives | `kubectl create deployment`, `run`, `expose`, `scale`, `set image`, `label` | aucune | création rapide d'objets simples, retouches ponctuelles |
| Configuration impérative | `kubectl create -f`, `replace -f`, `delete -f` | le fichier | rarement ; `replace --force` pour les champs immuables |
| Configuration déclarative | `kubectl apply -f <fichier ou dossier>` | le fichier + l'état mémorisé dans l'objet | tout objet que l'énoncé décrit en détail |

La méthode qui gagne du temps combine les deux : un **générateur** produit le squelette correct (`apiVersion`, `kind`, sélecteurs, indentation), tu l'enregistres, tu complètes à l'éditeur ce que le générateur ne sait pas faire (sondes, volumes, affinités), puis tu appliques. `--dry-run=client -o yaml` fait produire l'objet par kubectl sans l'envoyer ; `--dry-run=server` l'envoie à l'apiserver, qui le fait passer par toute la chaîne (authentification, admission, validation, chapitre 2.8) sans l'écrire dans etcd ; `--dry-run=none`, la valeur par défaut, exécute vraiment. Le second est le meilleur contrôle avant un `apply` sur un objet sensible : il détecte un quota dépassé, une politique PodSecurity violée, un champ inconnu.

```bash
kubectl create deployment front --image=nginx:1.29-alpine --replicas=3 --port=80 \
  --dry-run=client -o yaml > ~/cka/boutique/brouillon-front.yaml
vim ~/cka/boutique/brouillon-front.yaml
kubectl apply --dry-run=server -f ~/cka/boutique/brouillon-front.yaml -n boutique
```

Avec `-n`, la plupart des générateurs écrivent le namespace dans `metadata.namespace` ; sans `-n`, le manifeste n'en porte pas et ira dans le namespace de la commande qui l'appliquera. kubectl 1.37 n'écrit plus `creationTimestamp: null` dans les objets générés, mais laisse `status: {}` et `resources: {}`, inoffensifs.

### 3.3 Les générateurs

#### 3.3.1 kubectl run

`kubectl run` ne crée plus que des **pods** nus. Le nom du pod sert aussi de nom au conteneur et de label par défaut (`run=<nom>`), que `--labels`/`-l` remplace.

```bash
kubectl run outils --image=nicolaka/netshoot:v0.16 --labels=app=outils,tier=outils \
  --dry-run=client -o yaml -- sleep infinity
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  labels:
    app: outils
    tier: outils
  name: outils
spec:
  containers:
  - args:
    - sleep
    - infinity
    image: nicolaka/netshoot:v0.16
    name: outils
    resources: {}
  dnsPolicy: ClusterFirst
  restartPolicy: Always
status: {}
```

Ce qui suit `--` devient `args` : l'image garde son `ENTRYPOINT` et seul son `CMD` est remplacé. Avec `--command`, il devient `command`, qui remplace l'`ENTRYPOINT`. Pour une image sans `ENTRYPOINT`, comme busybox, les deux formes exécutent la même chose ; pour une image qui en a un, `args` ne fait que lui passer des arguments. En cas de doute, `--command`.

| Option | Effet |
|---|---|
| `--image` | image du conteneur (obligatoire) |
| `--port=80` | `containerPort` |
| `--env=CLE=val` (répétable) | variable d'environnement |
| `--labels=a=b,c=d` | labels (remplacent `run=<nom>`) |
| `--restart=Always` (défaut), `OnFailure`, `Never` | `restartPolicy` du pod |
| `--command` | ce qui suit `--` va dans `command` |
| `--expose --port=80` | crée aussi un Service ClusterIP de même nom |
| `-it --rm` | interactif, pod supprimé à la sortie |
| `--overrides='{…}'` | JSON fusionné dans l'objet généré |

Le pod jetable, interactif, est l'outil de test réseau par excellence : `kubectl run test --image=busybox:1.37.0 --rm -it --restart=Never -n boutique -- wget -qO- -T 3 http://api:8080/hostname`. Avec `--restart=Never` et `-i`, le code de sortie de la commande est rendu par kubectl. L'option `-f` de `kubectl run`, déjà ignorée, est dépréciée en 1.37.

#### 3.3.2 kubectl create

| Sous-commande | Exemple | À savoir |
|---|---|---|
| `namespace` | `kubectl create namespace boutique` | |
| `deployment` | `kubectl create deployment front --image=nginx:1.29-alpine --replicas=3 --port=80` | label et sélecteur `app=<nom>` ; conteneur nommé d'après l'image (`nginx`) ; `-- cmd` va dans `command` ; `--image` répétable pour plusieurs conteneurs |
| `service clusterip\|nodeport\|loadbalancer` | `kubectl create service nodeport front --tcp=80:80 --node-port=30080` | sélecteur `app=<nom du Service>`, pas celui d'un Deployment : préférer `expose` |
| `service externalname` | `kubectl create service externalname meteo --external-name=example.com` | |
| `configmap` | `kubectl create configmap api-config --from-literal=LOG_LEVEL=info --from-file=index.html --from-env-file=app.env` | `--from-file=cle=fichier` renomme la clé |
| `secret generic` | `kubectl create secret generic api-secret --from-literal=DB_PASSWORD=changeme-123` | valeurs encodées en base64, pas chiffrées |
| `secret tls` | `kubectl create secret tls boutique-tls --cert=tls.crt --key=tls.key` | type `kubernetes.io/tls` |
| `secret docker-registry` | `--docker-server=… --docker-username=… --docker-password=…` | type `kubernetes.io/dockerconfigjson` |
| `job` | `kubectl create job migration --image=busybox:1.37.0 -- sh -c 'echo ok'` | `restartPolicy: Never` ; `--from=cronjob/rapport` lance un CronJob à la main |
| `cronjob` | `kubectl create cronjob rapport --image=busybox:1.37.0 --schedule='*/5 * * * *' -- date` | `restartPolicy: OnFailure` |
| `ingress` | `kubectl create ingress web --class=nginx --rule='boutique.example/*=front:80,tls=boutique-tls'` | `/*` donne `Prefix /`, `/` seul donne `Exact` |
| `role`, `clusterrole` | `kubectl create role developpeur --verb=get,list --resource=pods,pods/log` | interroge l'API pour valider les ressources |
| `rolebinding`, `clusterrolebinding` | `--role=… \| --clusterrole=…`, `--user`, `--group`, `--serviceaccount=boutique:deployeur` | |
| `serviceaccount` | `kubectl create serviceaccount deployeur` | |
| `token` | `kubectl create token deployeur --duration=1h` | jeton lié, non stocké (3.9) |
| `quota` | `kubectl create quota q --hard=pods=30,requests.cpu=4` | |
| `poddisruptionbudget` | `kubectl create pdb front --selector=app=front --min-available=2` | |
| `priorityclass` | `kubectl create priorityclass boutique-critique --value=100000` | |

`kubectl autoscale deployment api --min=2 --max=6 --cpu=50%` crée un HorizontalPodAutoscaler `autoscaling/v2`. En 1.37, l'option se nomme **`--cpu`** (pourcentage ou quantité, `--memory` existe aussi) ; l'ancienne `--cpu-percent` fonctionne encore mais affiche `Flag --cpu-percent has been deprecated`. Le comportement de descente, lui, ne se génère pas ([chapitre 7](07-autoscaling.md)).

#### 3.3.3 kubectl expose

`kubectl expose` crée un Service à partir d'un objet existant dont il **recopie le sélecteur** : c'est la manière sûre d'exposer un Deployment, car le sélecteur correspond par construction.

```bash
kubectl expose deployment api --port=8080 --target-port=http -n boutique
kubectl expose deployment front --port=80 --type=NodePort --name=front-np -n boutique
```

Il accepte les pods, Services, Deployments, ReplicaSets et ReplicationControllers, à condition que leur sélecteur se réduise à des `matchLabels`. Sans `--port`, il reprend les ports déclarés par les conteneurs ; sans `--name`, il prend le nom de l'objet exposé. Il ne sait pas fixer un `nodePort` précis : pour `30080`, on génère avec `--dry-run=client -o yaml` et on ajoute la ligne, ou on patche après coup ([chapitre 10](10-services.md)).

#### 3.3.4 Ce qui ne se génère pas

Aucun générateur ne produit de DaemonSet, de StatefulSet, de PersistentVolume, de PersistentVolumeClaim, de StorageClass, de NetworkPolicy ni d'objet Gateway API. Deux recours. Copier l'exemple de la page de documentation correspondante (la recherche de kubernetes.io est autorisée et rapide : *daemonset*, *persistent volumes*, *network policies*), puis l'adapter. Ou dériver un objet voisin : un DaemonSet est un Deployment sans `replicas` ni `strategy`.

```bash
kubectl create deployment agent-noeud --image=busybox:1.37.0 --dry-run=client -o yaml \
  -- sh -c 'while true; do date; sleep 60; done' \
  | sed -e 's/^kind: Deployment/kind: DaemonSet/' -e '/^  replicas:/d' -e '/^  strategy:/d' \
  > ~/cka/boutique/brouillon-agent-noeud.yaml
```

Oublier `strategy: {}` donnerait, à l'apply, une erreur de champ inconnu : la validation stricte est la valeur par défaut de `--validate`.

#### 3.3.5 Variables d'accélération

Deux variables, posées dans `~/.bashrc` en début d'examen, raccourcissent les options les plus tapées :

```bash
export do="--dry-run=client -o yaml"     # kubectl run x --image=y $do > x.yaml
export now="--force --grace-period=0"    # kubectl delete pod x $now
```

Elles reposent sur le découpage des mots par bash : `$do` non entre guillemets devient quatre arguments. **zsh ne découpe pas** une variable non citée : il faut y écrire `${=do}`, ou définir des alias. Le terminal d'examen est en bash ; vérifie sur ton poste lequel tu entraînes. `$now` supprime un pod sans attendre son arrêt ; kubectl le signale par `Warning: Immediate deletion does not wait for confirmation that the running resource has been terminated.` Réserve-le aux pods jetables : sur un pod de StatefulSet, un remplaçant pourrait démarrer pendant que l'ancien écrit encore.

### 3.4 Explorer l'API : explain et api-resources

`kubectl explain` affiche la documentation de n'importe quel champ, tirée du schéma OpenAPI v3 que publie **le cluster interrogé** : il connaît donc les CRD installées et la version exacte de l'API. C'est plus rapide que la documentation web pour retrouver un nom de champ, son type et sa valeur par défaut.

```bash
kubectl explain pod.spec.terminationGracePeriodSeconds
```

```
KIND:       Pod
VERSION:    v1

FIELD: terminationGracePeriodSeconds <integer>


DESCRIPTION:
    Optional duration in seconds the pod needs to terminate gracefully. May be
    decreased in delete request. Value must be non-negative integer. The value
    zero indicates stop immediately via the kill signal (no opportunity to shut
    down). If this value is nil, the default grace period will be used instead.
    The grace period is the duration in seconds after the processes running in
    the pod are sent a termination signal and the time when the processes are
    forcibly halted with a kill signal. Set this value longer than the expected
    cleanup time for your process. Defaults to 30 seconds.
```

Le chemin part du type (`pod`, `deploy`, `cronjob`…, noms courts acceptés) et suit les champs ; les listes se traversent sans index (`pod.spec.containers.livenessProbe`). `--recursive` affiche toute l'arborescence sous le champ, avec les types, sans les descriptions ; `--max-depth=N` en limite la profondeur (avec `--recursive` seulement) :

```bash
kubectl explain deployment.spec.strategy --recursive
```

```
GROUP:      apps
KIND:       Deployment
VERSION:    v1

FIELD: strategy <DeploymentStrategy>


DESCRIPTION:
    The deployment strategy to use to replace existing pods with new ones.
    DeploymentStrategy describes how to replace existing pods with new ones.
    
FIELDS:
  rollingUpdate	<RollingUpdateDeployment>
    maxSurge	<IntOrString>
    maxUnavailable	<IntOrString>
  type	<string>
  enum: Recreate, RollingUpdate
```

Les types se lisent ainsi : `<[]Container>` est une liste d'objets, `<map[string]string>` une table de chaînes, `<IntOrString>` accepte `1` comme `25%`, et `-required-` signale un champ obligatoire (`containers <[]Container> -required-` dans `pod.spec`). `--api-version=apps/v1` choisit une version quand plusieurs sont servies.

`kubectl api-resources` liste les ressources que sert le cluster, avec leurs noms courts, leur groupe/version, leur portée et leur kind ; `-o wide` ajoute les verbes autorisés. Ses filtres répondent à des questions d'examen : `--namespaced=false` (objets globaux), `--api-group=networking.k8s.io`, `--verbs=list`, `--categories=all`. `kubectl api-versions` donne les couples groupe/version. Ensemble, ils disent quel `apiVersion` écrire dans un manifeste écrit de mémoire.

> [!tip] Réflexe d'examen
> Tu hésites sur un nom de champ (`tolerationSeconds` ou `tolerationSecond` ? `matchExpressions` sous quel parent ?) : `kubectl explain` répond en trois secondes, sans quitter le terminal. Garde la documentation web pour les exemples complets à copier.

### 3.5 Lire : formats de sortie

#### 3.5.1 Formats simples

| Option | Résultat |
|---|---|
| `-o wide` | colonnes supplémentaires (nœud et IP des pods, IP et OS des nœuds) |
| `-o yaml`, `-o json` | l'objet complet, sans `managedFields` (sauf `--show-managed-fields`) |
| `-o kyaml` | KYAML, dialecte de YAML propre à Kubernetes, sans ambiguïté de type (GA en 1.37) |
| `-o name` | `type/nom`, idéal pour `xargs` |
| `--show-labels`, `-L app,tier` | tous les labels, ou certains en colonnes |
| `--no-headers` | sans en-tête, pour `wc -l` ou `awk` |
| `--show-kind` | préfixe le type, utile avec plusieurs types (`get deploy,svc`) |
| `-A` | tous les namespaces (ajoute une colonne `NAMESPACE`) |

`kubectl get all` ne liste pas tout : seulement la catégorie `all` (pods, Services, Deployments, ReplicaSets, StatefulSets, DaemonSets, Jobs, CronJobs, HPA). Ni ConfigMap, ni Secret, ni PVC, ni Ingress n'y figurent ; nomme les types que tu cherches (`kubectl get deploy,svc,cm,secret,pvc,ing -n boutique`).

#### 3.5.2 jsonpath

`-o jsonpath='<modèle>'` extrait des valeurs de l'objet JSON. Le modèle mêle du texte et des expressions entre accolades ; le `$` initial est facultatif.

| Syntaxe | Sens | Exemple |
|---|---|---|
| `.champ`, `['champ']` | enfant | `{.metadata.name}` |
| `[n]`, `[-1:]`, `[a:b]` | indice, tranche (pas de bouclage des indices négatifs) | `{.items[0].metadata.name}` |
| `[*]` | tous les éléments | `{.items[*].metadata.name}` |
| `..` | descente récursive | `{..image}` |
| `[?(@.champ=="v")]` | filtre (`==`, `!=`, `<`, `>`…, sur chaînes, nombres, booléens) | `{.status.conditions[?(@.type=="Ready")].status}` |
| `{range …}…{end}` | boucle | `{range .items[*]}{.metadata.name}{"\n"}{end}` |
| `{"\t"}`, `{"\n"}` | texte littéral entre guillemets doubles | séparateurs |
| `\.` | point littéral dans une clé | `{.metadata.labels.kubernetes\.io/hostname}` |

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'
```

```
cka 192.168.49.2
cka-m02 192.168.49.3
cka-m03 192.168.49.4
```

Cinq comportements à connaître. Une clé absente produit une chaîne vide, sans erreur (`--allow-missing-template-keys=true` par défaut) : une faute de frappe ne se voit pas, elle donne juste une ligne vide. Une table ou une liste imbriquée s'affiche en JSON compact (`{"cpu":"8","memory":"32019572Ki"}`). `[*]` sur une liste produit les valeurs séparées par des espaces ; `{range}` imbriqués permettent une ligne par conteneur. Les expressions régulières (`=~`) ne sont **pas** prises en charge : filtre avec `grep`, ou avec `jq`, qui n'est pas garanti sur les hôtes d'examen (`yq`, lui, y est). Enfin, `-o jsonpath-as-json` rend le résultat en JSON indenté, pratique pour explorer un sous-arbre, et `--template` avec `-o go-template` reste l'outil des transformations (`{{.data.DB_PASSWORD | base64decode}}` décode un Secret).

Dans le shell, entoure le modèle de guillemets **simples**, qui protègent les `"` et les `$` qu'il contient. Une clé contenant des points (labels et annotations préfixés) s'échappe par `\.` ; le reste du chemin s'écrit normalement : `{.metadata.annotations.kubernetes\.io/change-cause}`.

#### 3.5.3 custom-columns

`-o custom-columns=EN-TETE:chemin,EN-TETE:chemin` construit un tableau ; les chemins sont des expressions jsonpath sans accolades (les accolades sont tolérées), filtres compris. Une liste devient des valeurs séparées par des virgules, une valeur absente s'affiche `<none>`.

```bash
kubectl get nodes -o custom-columns='NOM:.metadata.name,IP:.status.addresses[?(@.type=="InternalIP")].address,PRET:.status.conditions[?(@.type=="Ready")].status,CPU:.status.capacity.cpu'
```

```
NOM       IP             PRET   CPU
cka       192.168.49.2   True   8
cka-m02   192.168.49.3   True   8
cka-m03   192.168.49.4   True   8
```

Pour un tableau réutilisable, `-o custom-columns-file=colonnes.txt` lit les en-têtes sur la première ligne et les chemins, alignés, sur la seconde.

#### 3.5.4 sort-by

`--sort-by=<chemin jsonpath>` trie la liste **côté client**, par ordre croissant uniquement. Le tri est numérique pour les nombres, chronologique pour les dates, et il comprend les quantités : `--sort-by=.status.capacity.memory` classe `500Mi` avant `1Gi`. Les objets qui n'ont pas le champ viennent en tête ; si **aucun** ne l'a, kubectl échoue avec `-o name`, `yaml`, `json`, `jsonpath` ou `custom-columns` (`error: couldn't find any field with path "{.status.inexistant}" in the list of objects`), mais l'affichage en tableau, par défaut ou avec `-o wide`, se contente d'un trompeur `No resources found`, avec un code de retour 0 : une faute de frappe dans le chemin fait croire à une liste vide. Pour l'ordre décroissant ou « le dernier », combine avec `--no-headers` et `tail -1` ou `tac`.

```bash
kubectl get pods -A --sort-by=.metadata.creationTimestamp
kubectl -n kube-system get pods --sort-by='.status.containerStatuses[0].restartCount'
kubectl get pv --sort-by=.spec.capacity.storage
```

> [!warning]
> Mets toujours entre guillemets un chemin qui contient des crochets. Sans eux, `[0]` est un motif de fichiers pour le shell : bash le laisse passer tant qu'aucun fichier ne correspond, zsh refuse aussitôt (`no matches found: --sort-by=.status.containerStatuses[0].restartCount`).

### 3.6 Sélectionner : labels et champs

Les **sélecteurs de labels** (`-l`, `--selector`) sont évalués par l'apiserver. Ils combinent des conditions par des virgules, toutes obligatoires :

| Forme | Sens |
|---|---|
| `-l app=front`, `app==front` | égalité |
| `-l tier!=batch` | différence (inclut les objets sans le label) |
| `-l 'tier in (web,api)'`, `'tier notin (batch)'` | appartenance à un ensemble |
| `-l tier`, `-l '!tier'` | présence, absence du label |
| `-l app=front,tier=web` | ET logique ; il n'y a pas de OU entre clés différentes |

Les **sélecteurs de champs** (`--field-selector`) ne connaissent que `=`, `==` et `!=`, et seulement quelques champs par type. Tous les types acceptent `metadata.name` et `metadata.namespace` ; les pods acceptent `spec.nodeName`, `spec.restartPolicy`, `spec.schedulerName`, `spec.serviceAccountName`, `spec.hostNetwork`, `status.phase`, `status.podIP`, `status.podIPs` et `status.nominatedNodeName` ; les événements `involvedObject.kind`, `involvedObject.name`, `reason`, `type`… ; les Secrets `type` ; les Services `spec.clusterIP` et `spec.type` ; les nœuds `spec.unschedulable`. Un champ non pris en charge est refusé par le serveur (`"…" is not a known field selector`).

```bash
kubectl get pods -A --field-selector spec.nodeName=cka-m02 -o wide
kubectl get pods -A --field-selector status.phase!=Running
kubectl get events -A --field-selector type=Warning
kubectl get nodes -l '!node-role.kubernetes.io/control-plane'
```

La différence avec un filtre jsonpath `?()` est importante : les sélecteurs réduisent ce que **renvoie le serveur**, ils marchent avec `-w`, `delete`, `logs` ; le filtre jsonpath trie ce que **kubectl a reçu**, seulement à l'affichage. Pour supprimer tous les pods d'un nœud qui ne sont pas `Running`, c'est `--field-selector`, pas jsonpath.

Deux options aident à comprendre ce que fait kubectl. `-w` (`--watch`) garde la commande ouverte et affiche chaque changement ; `--output-watch-events` y ajoute une colonne `EVENT` (`ADDED`, `MODIFIED`, `DELETED`). `-v=6` journalise chaque requête HTTP et son code, `-v=8` les en-têtes et le corps ; `kubectl get --raw /api/v1/namespaces/boutique/pods` interroge un chemin d'API brut, `--raw '/readyz?verbose'` un point de santé.

### 3.7 Modifier un objet existant

#### 3.7.1 Les commandes ciblées

| Besoin | Commande |
|---|---|
| Changer l'image d'un conteneur | `kubectl set image deployment/front nginx=nginx:1.30.6-alpine` |
| Requests et limits | `kubectl set resources deployment/front -c nginx --requests=cpu=50m,memory=32Mi --limits=cpu=200m,memory=64Mi` |
| Variables d'environnement | `kubectl set env deployment/api LOG_LEVEL=debug`, `--from=configmap/api-config`, `LOG_LEVEL-` pour retirer |
| ServiceAccount d'un modèle de pod | `kubectl set serviceaccount deployment/front deployeur` |
| Sujets d'un binding | `kubectl set subject rolebinding/developpeurs --group=developpeurs` |
| Réplicas | `kubectl scale deployment front --replicas=3` |
| Labels | `kubectl label pod outils tier=outils`, `--overwrite` pour changer une valeur, `tier-` pour retirer |
| Annotations | `kubectl annotate deployment front kubernetes.io/change-cause="passage en 1.30.6"` |
| Redémarrer les pods d'un contrôleur | `kubectl rollout restart deployment/front` |

`kubectl label` refuse de changer une valeur existante sans `--overwrite` (`'tier' already has a value (web), and --overwrite is false`). Toutes ces commandes acceptent `--dry-run=client -o yaml` et, pour la plupart, `--local -f <fichier>`, qui transforme un manifeste local sans contacter le cluster : `kubectl set image --local -f brouillon-front.yaml nginx=nginx:1.30.6-alpine -o yaml`.

#### 3.7.2 kubectl edit

`kubectl edit` ouvre l'objet dans l'éditeur désigné par `KUBE_EDITOR`, à défaut `EDITOR`, à défaut `vi`, et l'envoie à l'enregistrement. Si l'apiserver refuse, kubectl rouvre le fichier avec l'erreur en commentaire en tête ; si tu quittes sans corriger, il répond `Edit cancelled, no valid changes were saved.` et conserve tes modifications : `A copy of your changes has been stored to "/tmp/kubectl-edit-….yaml"`. Ce fichier sert ensuite à `kubectl replace --force -f` quand le champ était immuable.

#### 3.7.3 kubectl patch

`kubectl patch` envoie une modification partielle, en une ligne, sans éditeur. Trois formats existent, et leur traitement des listes est le piège :

| `--type` | Norme | Listes | Particularités |
|---|---|---|---|
| `strategic` (défaut) | propre à Kubernetes | fusionnées selon une clé (`name` pour les conteneurs) | indisponible sur les ressources personnalisées (CRD) |
| `merge` | RFC 7386 | **remplacées** entièrement ; `null` supprime une clé | marche partout |
| `json` | RFC 6902 | opérations par indice (`add`, `remove`, `replace`, `test`, `move`, `copy`) | `~1` code `/` et `~0` code `~` dans un chemin |

```bash
kubectl patch deployment front -n boutique \
  -p '{"spec":{"template":{"spec":{"containers":[{"name":"nginx","image":"nginx:1.30.6-alpine"}]}}}}'
kubectl patch deployment front -n boutique --type=json \
  -p '[{"op":"replace","path":"/spec/replicas","value":2},{"op":"add","path":"/metadata/labels/app.kubernetes.io~1name","value":"front"}]'
kubectl patch deployment front -n boutique --subresource=scale --type=merge -p '{"spec":{"replicas":3}}'
```

Le premier patch, stratégique, ne touche que l'image du conteneur `nginx` et garde ses ports et ses ressources. Le même corps envoyé en `--type=merge` **remplacerait toute la liste** `containers` par un conteneur réduit à son nom et son image : ports, sondes et ressources disparaîtraient. `--subresource` vise une sous-ressource (`status`, `scale`, `resize` pour le redimensionnement en place des pods, [chapitre 4](04-pods.md)). `kubectl patch` répond `deployment.apps/front patched`, ou `patched (no change)` si l'objet était déjà conforme.

#### 3.7.4 replace et les champs immuables

`kubectl replace -f` remplace l'objet entier par le contenu du fichier (`PUT`) ; le fichier doit donc être complet. Certains champs, eux, ne se modifient jamais après création : presque toute la spec d'un pod, le sélecteur d'un Deployment, le `clusterIP` d'un Service, le modèle d'un Job. Pour un pod, l'apiserver ne laisse changer que l'image des conteneurs et des init containers, `activeDeadlineSeconds`, l'**ajout** de tolérances et `terminationGracePeriodSeconds` dans un cas particulier ; toute autre modification échoue :

```
The Pod "essai" is invalid: spec: Forbidden: pod updates may not change fields other than `spec.containers[*].image`,`spec.initContainers[*].image`,`spec.activeDeadlineSeconds`,`spec.tolerations` (only additions to existing tolerations),`spec.terminationGracePeriodSeconds` (allow it to be set to 1 if it was previously negative)
…
```

Les ressources CPU et mémoire font exception par la sous-ressource `resize` (chapitre 4). Pour le reste, `kubectl replace --force -f pod.yaml` supprime l'objet, **attend** sa disparition (jusqu'à 5 minutes par défaut), puis le recrée. Le fichier peut venir de `kubectl get -o yaml` tel quel : kubectl efface la `resourceVersion` avant de recréer, et l'apiserver attribue un nouvel `uid`. L'attente comprend le délai de grâce du pod (30 s par défaut, entièrement consommé par un conteneur qui ignore SIGTERM, comme `sleep` en PID 1) ; `--grace-period=0` avec `--force` l'abrège, au prix d'une suppression immédiate.

#### 3.7.5 delete et diff

| Option de `kubectl delete` | Effet |
|---|---|
| `--grace-period=N` | délai de grâce ; `--now` équivaut à 1 |
| `--force --grace-period=0` | retire l'objet de l'API sans attendre le kubelet (`force deleted`) |
| `--cascade=background\|foreground\|orphan` | sort des dépendants (chapitre 2.13) |
| `--wait=false` | rend la main sans attendre la disparition (finalizers) |
| `-i`, `--interactive` | demande confirmation |
| `--all`, `-l`, `--field-selector` | sélection multiple |

La suppression répond `deployment.apps "front" deleted from boutique namespace` pour un objet namespacé, `namespace "x" deleted` pour un objet global. `kubectl diff -f <fichier>` montre ce qu'un `apply` changerait, en diff unifié ; son code de retour vaut 0 sans différence, 1 avec différences, plus de 1 en cas d'erreur. La variable `KUBECTL_EXTERNAL_DIFF` choisit l'outil de comparaison.

### 3.8 Apply côté client et côté serveur

#### 3.8.1 Apply côté client

`kubectl apply`, sans option, calcule lui-même la modification. Il compare trois versions de l'objet : le fichier que tu appliques, l'objet vivant, et la **dernière configuration appliquée**, qu'il stocke en JSON dans l'annotation `kubectl.kubernetes.io/last-applied-configuration`. Un champ présent dans l'annotation mais absent du nouveau fichier est supprimé de l'objet ; un champ absent des deux (écrit par un contrôleur, ou par `kubectl scale`) est laissé tel quel. C'est ce qui permet d'appliquer plusieurs fois le même fichier sans effacer ce que d'autres ont ajouté.

Trois limites en découlent. Un objet créé par `kubectl create` n'a pas d'annotation : le premier `apply` affiche `Warning: resource … is missing the kubectl.kubernetes.io/last-applied-configuration annotation which is required by kubectl apply …` puis la crée (`kubectl create --save-config` l'aurait posée d'emblée). Un objet volumineux dépasse vite la limite de 256 Kio des annotations : les grosses CRD échouent avec un message `Too long: must have at most 262144 bytes`. Et deux personnes qui appliquent chacune leur fichier s'écrasent sans le savoir : l'annotation ne dit pas **qui** a écrit quoi.

#### 3.8.2 Server-side apply

Avec `kubectl apply --server-side`, kubectl envoie le fichier tel quel (un `PATCH` de type `application/apply-patch+yaml`) et c'est l'apiserver qui fusionne. Il enregistre, pour chaque champ, le **gestionnaire** (*field manager*) qui l'a fixé, dans `metadata.managedFields`. Chaque écriture y laisse une trace, apply ou non :

| Écriture | Gestionnaire enregistré | Opération |
|---|---|---|
| `kubectl apply` (côté client) | `kubectl-client-side-apply` | `Update` |
| `kubectl apply --server-side` | `kubectl` (ou `--field-manager=…`) | `Apply` |
| `kubectl create …`, `edit`, `patch`, `replace` | `kubectl-create`, `kubectl-edit`, `kubectl-patch`, `kubectl-replace` | `Update` |
| `kubectl set …`, `label`, `annotate`, `run`, `expose` | `kubectl-set`, `kubectl-label`, `kubectl-annotate`, `kubectl-run`, `kubectl-expose` | `Update` |
| un contrôleur, `kubectl scale` | dérivé de l'en-tête `User-Agent` (`kube-controller-manager`, `kubectl`) | `Update` |

Quand un apply veut **changer** la valeur d'un champ possédé par un autre gestionnaire, l'apiserver refuse par un **conflit** :

```
error: Apply failed with 1 conflict: conflict with "equipe-a": .data.couleur
Please review the fields above--they currently have other managers. Here
are the ways you can resolve this warning:
* If you intend to manage all of these fields, please re-run the apply
  command with the `--force-conflicts` flag.
* If you do not intend to manage all of the fields, please edit your
  manifest to remove references to the fields that should keep their
  current managers.
* You may co-own fields by updating your manifest to match the existing
  value; in this case, you'll become the manager if the other manager(s)
  stop managing the field (remove it from their configuration).
See https://kubernetes.io/docs/reference/using-api/server-side-apply/#conflicts
```

Les trois issues sont celles qu'énumère le message : forcer (`--force-conflicts`), ce qui change la valeur et transfère la propriété du champ ; retirer le champ de son fichier, et laisser l'autre gestionnaire le garder ; ou adopter la valeur existante, et partager la propriété. Un champ retiré d'un fichier appliqué côté serveur est supprimé de l'objet seulement si aucun autre gestionnaire ne le possède. `kubectl get -o yaml` masque `managedFields` ; `--show-managed-fields` les montre, et un modèle jsonpath les lit directement (`{.metadata.managedFields[*].manager}`). Les écritures `Update` (edit, patch, scale, contrôleurs) ne provoquent jamais de conflit : elles prennent la propriété des champs qu'elles modifient. C'est pourquoi, après un `kubectl scale`, un `apply --server-side` qui fixe `replicas` entre en conflit, alors qu'un `apply` côté client écrasait sans prévenir.

Le passage d'un mode à l'autre est prévu : un objet géré par `kubectl apply` peut être repris par `kubectl apply --server-side`, qui lit l'annotation pour transférer la propriété des champs sans conflit (avec le gestionnaire par défaut `kubectl`), et l'inverse fonctionne car le mode serveur tient l'annotation à jour. Le mode serveur demande les verbes `patch` (et `create` pour une création) ; il accepte `--subresource` ; `--dry-run=server` le prévisualise.

#### 3.8.3 Lequel choisir

| Situation | Choix |
|---|---|
| Fichiers de l'examen, objets simples | `kubectl apply -f` (côté client) : universel, rapide |
| Grosses CRD, bundles (Gateway API, opérateurs) | `--server-side` : pas de limite d'annotation ; la procédure officielle de Gateway API l'impose ([chapitre 13](13-gateway-api.md)) |
| Plusieurs outils ou équipes sur un même objet | `--server-side --field-manager=<nom>` : les conflits deviennent visibles |
| Un contrôleur doit garder la main sur un champ (`replicas` sous HPA) | retirer ce champ de ses manifestes, quel que soit le mode |

Helm 4 installe désormais par server-side apply ([chapitre 17](17-helm-et-kustomize.md)) : les conflits de gestionnaires y deviennent un sujet courant.

### 3.9 Observer et attendre : events, wait, exec, token

#### 3.9.1 kubectl events

`kubectl events` (stable depuis 1.28) affiche les événements **triés chronologiquement**, avec les colonnes `LAST SEEN`, `TYPE`, `REASON`, `OBJECT` (`Pod/essai`) et `MESSAGE`. Ses options : `--for pod/essai` (un objet), `--types=Warning` (un type), `-w` (suivre), `-A` (tous les namespaces). `kubectl get events`, lui, ne trie pas : il faut `--sort-by=.metadata.creationTimestamp`, plus fiable que `.lastTimestamp`, vide pour les événements de nouvelle génération. Les événements ne vivent qu'**une heure** (`--event-ttl` de l'apiserver) : un incident plus ancien n'en a plus. `kubectl describe` affiche ceux de l'objet décrit ; depuis 1.36, pour plusieurs objets à la fois, il faut `--show-events`.

#### 3.9.2 kubectl wait

`kubectl wait` bloque jusqu'à ce qu'une condition soit vraie, ce qui rend un enchaînement de commandes fiable et sert de vérification de fin de tâche.

```bash
kubectl wait --for=condition=Ready pod/essai -n boutique --timeout=60s
kubectl wait --for=condition=Available deployment/front -n boutique --timeout=2m
kubectl wait --for=jsonpath='{.status.phase}'=Running pod/essai -n boutique
kubectl wait --for=delete pod/essai -n boutique --timeout=60s
kubectl wait --for=create configmap/essai -n boutique --timeout=30s
kubectl wait --for=condition=Ready node --all --timeout=10m
```

La valeur attendue d'une condition est `true` par défaut (`--for=condition=Ready=false` attend l'inverse), comparée sans tenir compte de la casse. Plusieurs `--for` se combinent en ET, `create` toujours en premier. `--timeout` vaut 30 s par défaut ; `0` vérifie une fois sans attendre, une valeur négative attend une semaine. En cas d'échec, la commande rend un code non nul : `timed out waiting for the condition on pods/essai`.

#### 3.9.3 kubectl exec

```bash
kubectl exec outils -n boutique -- nslookup api
kubectl exec -it outils -n boutique -- bash
kubectl exec deploy/api -n boutique -c agnhost -- env
```

Depuis 1.35, le `--` qui sépare les options de kubectl de la commande à lancer est **obligatoire** :

```
error: exec [POD] [COMMAND] is not supported anymore. Use exec [POD] -- [COMMAND] instead
See 'kubectl exec -h' for help and examples
```

`-c` choisit le conteneur (à défaut, celui désigné par l'annotation `kubectl.kubernetes.io/default-container`, sinon le premier) ; `deploy/<nom>` ou `svc/<nom>` vise le premier pod correspondant. La commande est exécutée telle quelle, sans shell : `-- sh -c 'echo $HOSTNAME'` pour une expansion. `kubectl cp` exige `tar` dans le conteneur, absent des images *distroless* comme celle d'etcd.

#### 3.9.4 kubectl create token

`kubectl create token <ServiceAccount>` demande à l'apiserver un jeton signé, **lié** au ServiceAccount et à durée limitée, par la sous-ressource `serviceaccounts/token`. Il n'est stocké nulle part : perdu, on en demande un autre. Sans `--duration`, le serveur applique sa valeur par défaut, une heure ; il refuse moins de 10 minutes et plafonne à `--service-account-max-token-expiration` s'il est fixé. `--audience` change le destinataire prévu, `--bound-object-kind` et `--bound-object-name` (Pod, Secret ou Node) le rendent invalide quand l'objet disparaît. Le [chapitre 16](16-rbac-et-authentification.md) s'en sert pour le ServiceAccount `deployeur`.

### 3.10 Configurer son terminal

#### 3.10.1 Alias, complétion, éditeur

Sur les hôtes d'examen, l'alias `k` et la complétion Bash de kubectl sont déjà en place. Sur ton poste, reproduis-les à l'identique pour t'entraîner dans les mêmes conditions :

```bash
cat >> ~/.bashrc <<'EOF'
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
export do="--dry-run=client -o yaml"
export now="--force --grace-period=0"
EOF
source ~/.bashrc
```

La complétion Bash exige le paquet `bash-completion`. Sous zsh, `source <(kubectl completion zsh)` dans `~/.zshrc` suffit, et la complétion suit automatiquement l'alias (si `compdef` est introuvable, ajouter `autoload -Uz compinit; compinit` avant). La complétion propose aussi les **noms d'objets** du cluster : `kubectl -n kube-system logs kube-sch<Tab>`.

Pour le YAML, trois réglages de vim évitent les erreurs d'indentation, les plus fréquentes et les plus longues à trouver :

```bash
cat >> ~/.vimrc <<'EOF'
set expandtab tabstop=2 shiftwidth=2
EOF
```

Si un collage décale l'indentation, `:set paste` avant de coller, `:set nopaste` après. `export KUBE_EDITOR=nano` change l'éditeur de `kubectl edit` pour qui préfère. Enfin, kubectl traduit une partie de ses messages selon la locale : avec `LANG=fr_FR.UTF-8`, `kubectl config --help` répond `Supprimer le contexte spécifié du kubeconfig`. Les sorties de ce cours, comme celles de l'examen, sont en anglais ; `export LANG=C` sur ton poste les reproduit.

#### 3.10.2 kuberc, les préférences de kubectl (bêta)

Depuis 1.34, kubectl lit un fichier de préférences distinct du kubeconfig, `~/.kube/kuberc` (en bêta, activé par défaut). Il ne contient ni cluster ni identifiants, seulement des **alias** de commandes, des **valeurs par défaut** d'options et, depuis 1.35, une **politique des plugins d'identification** (`credentialPluginPolicy`). Son format, `kubectl.config.k8s.io/v1beta1`, `kind: Preference` :

```yaml
apiVersion: kubectl.config.k8s.io/v1beta1
kind: Preference
aliases:
- name: gpb
  command: get
  prependArgs:
  - pods
  options:
  - name: namespace
    default: boutique
  - name: output
    default: wide
defaults:
- command: delete
  options:
  - name: interactive
    default: "true"
```

`kubectl gpb` devient alors `kubectl get --namespace=boutique --output=wide pods`, et `kubectl delete` demande confirmation (`Do you want to continue? (y/N)`). Une option explicite l'emporte toujours sur la valeur par défaut (`kubectl delete … --interactive=false`). Le nom d'un alias ne doit pas masquer une commande intégrée, et les options globales se placent **après** lui : placées avant, kubectl le prend pour un plugin (`flags cannot be placed before plugin name`). `appendArgs` ajoute des arguments en fin de commande, après un éventuel `--`.

| Commande ou réglage | Effet |
|---|---|
| `kubectl kuberc view` | affiche le fichier en vigueur |
| `kubectl kuberc set --section defaults --command get --option output=wide` | ajoute une valeur par défaut (crée `~/.kube/kuberc` au besoin) |
| `kubectl kuberc set --section aliases --name gpb --command get --prependarg pods --option namespace=boutique` | ajoute un alias |
| `--kuberc <fichier>` ou `KUBERC=<fichier>` | utilise un autre fichier (qui doit exister) |
| `KUBERC=off` | ignore tout fichier kuberc |
| `KUBECTL_KUBERC=false` | désactive la fonction elle-même |

> [!warning]
> Une valeur par défaut dans `~/.kube/kuberc` s'applique à **tous** les appels de kubectl, scripts compris : un `interactive=true` sur `delete` bloque un script qui supprime des objets, un `server-side=true` sur `apply` change les gestionnaires de champs de tout ce que tu appliques. Pour le lab, garde-le dans un fichier séparé, passé par `--kuberc` ou `KUBERC` quand tu le veux. À l'examen, n'en écris pas : l'alias `k` et la complétion suffisent, et une bêta n'est pas un appui à prendre sous la pression du chronomètre.

### 3.11 Pièges courants

```
Piège 1 : Oublier le namespace de l'énoncé
══════════════════════════════════════════
  MAUVAIS  : kubectl create deployment web --image=nginx:1.30.6-alpine
             (tâche : « dans le namespace examen-app »)
  SYMPTÔME : l'objet existe… dans default ; la tâche vaut zéro.
  BON      : -n <namespace> dans chaque commande, puis vérifier
             avec kubectl get … -n <namespace>.

Piège 2 : kubectl create service au lieu d'expose
══════════════════════════════════════════════════
  MAUVAIS  : kubectl create service clusterip api-svc --tcp=8080:8080
  SYMPTÔME : sélecteur app=api-svc, aucun pod derrière le Service.
  BON      : kubectl expose deployment api --name=api-svc --port=8080

Piège 3 : Patch merge sur une liste
═══════════════════════════════════
  MAUVAIS  : kubectl patch deploy front --type=merge -p '{…containers:[{name,image}]}'
  SYMPTÔME : ports, sondes et ressources du conteneur disparus.
  BON      : patch stratégique (défaut), kubectl set image, ou patch json
             ciblé ("/spec/template/spec/containers/0/image").

Piège 4 : Modifier un champ immuable d'un pod avec apply ou edit
════════════════════════════════════════════════════════════════
  SYMPTÔME : « pod updates may not change fields other than … »
  BON      : kubectl get pod x -o yaml > x.yaml ; corriger ;
             kubectl replace --force -f x.yaml
             (ou le fichier /tmp/kubectl-edit-….yaml laissé par edit).

Piège 5 : Croire un jsonpath vide
═════════════════════════════════
  SYMPTÔME : sortie vide, aucune erreur.
  CAUSE    : faute de frappe dans un chemin, ou clé à points non
             échappée (kubernetes.io/hostname) : clé absente = vide.
  BON      : construire le chemin pas à pas avec -o jsonpath-as-json,
             échapper les points des clés avec \.

Piège 6 : Crochets non protégés dans le shell
═════════════════════════════════════════════
  MAUVAIS  : --sort-by=.status.containerStatuses[0].restartCount
  SYMPTÔME : zsh : « no matches found » ; bash : erreur si un fichier
             du dossier correspond au motif.
  BON      : '--sort-by=.status.containerStatuses[0].restartCount'

Piège 7 : exec sans le double tiret
═══════════════════════════════════
  MAUVAIS  : kubectl exec outils nslookup api
  SYMPTÔME : « exec [POD] [COMMAND] is not supported anymore »
  BON      : kubectl exec outils -- nslookup api

Piège 8 : Une valeur par défaut kuberc oubliée
══════════════════════════════════════════════
  SYMPTÔME : un script bloqué sur « Do you want to continue? »,
             ou des conflits de field managers inattendus.
  BON      : kubectl kuberc view ; KUBERC=off pour vérifier.
```

> [!summary] À retenir
> - Le kubeconfig associe clusters, users et contexts ; `KUBECONFIG` fusionne (le premier fichier gagne), `--kubeconfig` ne fusionne pas ; à l'examen, nomme le namespace dans chaque commande.
> - Génère, ne tape pas : `--dry-run=client -o yaml > fichier`, complète, applique ; `--dry-run=server` fait passer l'objet par l'admission sans l'écrire.
> - `run` fait des pods (`--` → `args`, `--command` → `command`), `create deployment` met `-- cmd` dans `command`, `expose` recopie le sélecteur, `create service` sélectionne `app=<nom du Service>`, `autoscale` utilise `--cpu` en 1.37.
> - `kubectl explain <type>.<champ>` donne nom, type, défaut ; `--recursive` (et `--max-depth`) l'arborescence ; `api-resources` les groupes, versions et portées.
> - jsonpath : guillemets simples, `{range}{end}`, filtres `?(@.type=="InternalIP")`, `\.` dans les clés, clé absente = vide ; custom-columns pour un tableau ; `--sort-by` trie croissant, quantités et dates comprises.
> - Les sélecteurs de labels et de champs filtrent côté serveur ; les filtres jsonpath, côté client.
> - Patch stratégique par défaut ; `merge` remplace les listes ; `json` opère par indice ; les champs immuables d'un pod imposent `replace --force`.
> - Apply côté client mémorise une annotation ; côté serveur, l'apiserver suit les gestionnaires de champs dans `managedFields` et signale les conflits, levés par `--force-conflicts`.
> - `kubectl events --for` trie chronologiquement ; `kubectl wait` attend une condition, un jsonpath, une création ou une suppression ; `exec` exige `--` depuis 1.35.
> - kuberc (bêta) ajoute alias et valeurs par défaut à kubectl ; garde-le hors de `~/.kube/kuberc` pour ne pas changer le comportement des scripts.

### 3.12 Exercices

#### Exercice 3.1 — Le namespace et le contexte `boutique`

**Point de départ** : exercice 2.8, ou instantané I0.

Crée le dossier `~/cka/boutique/`. Génère sans rien créer le manifeste du namespace `boutique` dans `~/cka/boutique/namespace.yaml`, puis applique-le. Crée un contexte kubeconfig `boutique` qui utilise le cluster `cka`, le user `cka` et le namespace `boutique`, et bascule dessus. Montre que les commandes sans `-n` visent désormais `boutique`.

> [!example]- Solution
> ```bash
> mkdir -p ~/cka/boutique
> kubectl create namespace boutique --dry-run=client -o yaml > ~/cka/boutique/namespace.yaml
> cat ~/cka/boutique/namespace.yaml
> kubectl apply -f ~/cka/boutique/namespace.yaml
> kubectl config set-context boutique --cluster=cka --user=cka --namespace=boutique
> kubectl config use-context boutique
> kubectl config get-contexts
> kubectl get pods
> ```
>
> ```
> CURRENT   NAME       CLUSTER   AUTHINFO   NAMESPACE
> *         boutique   cka       cka        boutique
>           cka        cka       cka        default
> ```
>
> Le manifeste généré ne contient que `apiVersion: v1`, `kind: Namespace`, `metadata.name: boutique` et des `spec: {}`/`status: {}` vides. `kubectl apply` répond `namespace/boutique created` ; `set-context` répond `Context "boutique" created.` et `use-context` `Switched to context "boutique".` La dernière commande répond `No resources found in boutique namespace.` : le namespace vient du contexte. Le fichier garde le manifeste, rejouable sur un autre cluster.
>
> **Vérification** : `kubectl config view --minify -o jsonpath='{..namespace}'` affiche `boutique`, et `kubectl get namespace boutique -o jsonpath='{.metadata.labels}'` affiche `{"kubernetes.io/metadata.name":"boutique"}`.

#### Exercice 3.2 — Les brouillons du fil rouge

**Point de départ** : exercice 3.1.

Sans créer aucun objet, génère dans `~/cka/boutique/` trois brouillons qui serviront aux chapitres 4 et 5 : `brouillon-front.yaml`, un Deployment `front` en `nginx:1.29-alpine`, 3 réplicas, port 80 ; `brouillon-outils.yaml`, un pod `outils` en `nicolaka/netshoot:v0.16`, labels `app=outils` et `tier=outils`, qui exécute `sleep infinity` ; `brouillon-rapport.yaml`, un CronJob `rapport` en `busybox:1.37.0`, toutes les 5 minutes, qui lance `sh -c 'date; echo rapport genere'`. Fais valider les trois par l'apiserver sans les créer. Indique ce que chaque générateur a mis dans `command` ou dans `args`.

> [!example]- Solution
> ```bash
> cd ~/cka/boutique
> kubectl create deployment front --image=nginx:1.29-alpine --replicas=3 --port=80 \
>   --dry-run=client -o yaml > brouillon-front.yaml
> kubectl run outils --image=nicolaka/netshoot:v0.16 --labels=app=outils,tier=outils \
>   --dry-run=client -o yaml -- sleep infinity > brouillon-outils.yaml
> kubectl create cronjob rapport --image=busybox:1.37.0 --schedule='*/5 * * * *' \
>   --dry-run=client -o yaml -- sh -c 'date; echo rapport genere' > brouillon-rapport.yaml
> kubectl apply --dry-run=server -f brouillon-front.yaml -f brouillon-outils.yaml -f brouillon-rapport.yaml
> grep -A3 -E 'command:|args:' brouillon-outils.yaml brouillon-rapport.yaml
> ```
>
> ```
> deployment.apps/front created (server dry run)
> pod/outils created (server dry run)
> cronjob.batch/rapport created (server dry run)
> ```
>
> L'apiserver a accepté les trois objets, admission comprise, sans les écrire. `kubectl run` a placé `sleep` et `infinity` dans `args` : le conteneur garde l'`ENTRYPOINT` de son image, ces arguments ne remplacent que son `CMD`. `kubectl create cronjob` a placé `sh`, `-c` et le script dans `command`, avec `restartPolicy: OnFailure`. Le Deployment a les labels et le sélecteur `app: front` et un conteneur nommé `nginx`. Ces brouillons sont incomplets par nature (pas de labels `tier`, ni de ressources, ni de fuseau horaire) : les chapitres 4 et 5 les compléteront.
>
> **Vérification** : `kubectl get deploy,pods,cronjobs` répond `No resources found in boutique namespace.`, et `ls ~/cka/boutique` liste `brouillon-front.yaml`, `brouillon-outils.yaml`, `brouillon-rapport.yaml` et `namespace.yaml`.

#### Exercice 3.3 — Trouver un champ avec explain

**Point de départ** : exercice 3.2.

Sans documentation web, réponds aux questions suivantes avec `kubectl explain` et `kubectl api-resources`. Quel champ d'un pod fixe le délai de grâce à l'arrêt, de quel type est-il, et quelle est sa valeur par défaut ? Quels sont les sous-champs de `spec.strategy` d'un Deployment, et lesquels acceptent un pourcentage ? Dans quel groupe et quelle version vivent les CronJobs, et quel est leur nom court ? Le champ `containers` d'un pod est-il obligatoire ?

> [!example]- Solution
> ```bash
> kubectl explain pod.spec.terminationGracePeriodSeconds | head -5
> kubectl explain deployment.spec.strategy --recursive
> kubectl explain cronjob | head -3
> kubectl api-resources | grep -i cronjob
> kubectl explain pod.spec --recursive --max-depth=1 | grep containers
> ```
>
> Le délai de grâce est `terminationGracePeriodSeconds <integer>`, 30 secondes par défaut (fin de la description). `spec.strategy` contient `type <string>` et `rollingUpdate`, lui-même formé de `maxSurge <IntOrString>` et `maxUnavailable <IntOrString>` : ce sont eux qui acceptent `1` comme `25%`. `kubectl explain cronjob` commence par `GROUP: batch`, `KIND: CronJob`, `VERSION: v1`, et `api-resources` donne le nom court `cj`. Enfin, `pod.spec` affiche `containers <[]Container> -required-` : c'est une liste obligatoire.
>
> **Vérification** : `kubectl create cronjob verif --image=busybox:1.37.0 --schedule='0 * * * *' --dry-run=client -o jsonpath='{.apiVersion}{"\n"}'` affiche `batch/v1`, la même version que celle lue dans `explain`.

#### Exercice 3.4 — jsonpath sur les nœuds

**Point de départ** : exercice 3.3.

Écris dans `~/cka/requetes/noeuds.txt` une ligne par nœud, triée par nom, de la forme `<nom> <IP interne> <version du kubelet>`. Affiche ensuite, en une commande, les noms des nœuds dont la condition `Ready` vaut `True`. Affiche enfin le nom du nœud de control plane en utilisant son label de rôle, puis la valeur de son label `kubernetes.io/hostname`.

> [!example]- Solution
> ```bash
> mkdir -p ~/cka/requetes
> kubectl get nodes --sort-by=.metadata.name \
>   -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' \
>   > ~/cka/requetes/noeuds.txt
> cat ~/cka/requetes/noeuds.txt
> kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | awk '$2=="True"{print $1}'
> kubectl get nodes -l node-role.kubernetes.io/control-plane -o name
> kubectl get node cka -o jsonpath='{.metadata.labels.kubernetes\.io/hostname}{"\n"}'
> ```
>
> ```
> cka 192.168.49.2 v1.37.0
> cka-m02 192.168.49.3 v1.37.0
> cka-m03 192.168.49.4 v1.37.0
> ```
>
> La deuxième commande liste les trois nœuds. Un filtre jsonpath ne sait pas retenir un **objet** selon la valeur d'un de ses sous-éléments puis afficher un autre champ du même objet dans une boucle ; on sort donc les deux colonnes et on filtre avec `awk`. Le sélecteur `-l node-role.kubernetes.io/control-plane` teste la **présence** du label, dont la valeur est vide : il renvoie `node/cka`. Le point de `kubernetes.io/hostname` est échappé ; sans l'échappement, la sortie serait vide, sans erreur.
>
> **Vérification** : `wc -l < ~/cka/requetes/noeuds.txt` affiche `3`, et `sort -c ~/cka/requetes/noeuds.txt` ne signale rien (fichier trié).

#### Exercice 3.5 — custom-columns et sort-by sur `kube-system`

**Point de départ** : exercice 3.4.

Affiche les pods de `kube-system` sous forme de tableau à colonnes `POD`, `NOEUD`, `IMAGES` et `REDEMARRAGES` (redémarrages du premier conteneur), trié par nombre de redémarrages croissant. Affiche ensuite le nom du pod le plus récemment créé de tout le cluster. Produis enfin la liste, sans doublon et triée, de toutes les images de conteneurs qui tournent dans le cluster.

> [!example]- Solution
> ```bash
> kubectl -n kube-system get pods \
>   --sort-by='.status.containerStatuses[0].restartCount' \
>   -o custom-columns='POD:.metadata.name,NOEUD:.spec.nodeName,IMAGES:.spec.containers[*].image,REDEMARRAGES:.status.containerStatuses[0].restartCount'
> kubectl get pods -A --sort-by=.metadata.creationTimestamp --no-headers -o custom-columns=NS:.metadata.namespace,POD:.metadata.name | tail -1
> kubectl get pods -A -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n' | sort -u
> ```
>
> Le tableau liste les pods du namespace du moins au plus redémarré (tous à `0` sur un cluster neuf, l'ordre initial est alors conservé). La colonne `IMAGES` sépare par des virgules les images d'un pod qui a plusieurs conteneurs. Le tri par `creationTimestamp` est chronologique, croissant : `tail -1` garde le plus récent. La liste des images contient notamment `quay.io/calico/node:v3.32.2`, `registry.k8s.io/coredns/coredns:v1.14.6`, `registry.k8s.io/etcd:3.7.0-0`, les quatre images `registry.k8s.io/kube-*:v1.37.0` et `gcr.io/k8s-minikube/storage-provisioner:v5`.
>
> **Vérification** : `kubectl get pods -A -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n' | sort -u | grep -c 'v1.37.0'` affiche `4` (apiserver, controller-manager, scheduler, proxy).

#### Exercice 3.6 — Sélecteurs de labels et de champs

**Point de départ** : exercice 3.5.

Compte les pods placés sur chaque nœud, d'abord pour `cka-m02` par un sélecteur de champ, puis pour tous les nœuds en une seule commande. Liste dans tous les namespaces les pods qui ne sont pas en phase `Running`. Dans `kube-system`, affiche les pods dont le label `k8s-app` vaut `kube-dns` ou `kube-proxy`, avec la valeur de ce label en colonne. Explique enfin pourquoi `kubectl get pods -A -o jsonpath='{.items[?(@.spec.nodeName=="cka-m02")].metadata.name}'` donne les mêmes noms que la première commande, mais pas pour le même coût.

> [!example]- Solution
> ```bash
> kubectl get pods -A --field-selector spec.nodeName=cka-m02 --no-headers | wc -l
> kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c
> kubectl get pods -A --field-selector status.phase!=Running
> kubectl -n kube-system get pods -l 'k8s-app in (kube-dns,kube-proxy)' -L k8s-app
> ```
>
> Sur le lab au repos, `cka-m02` porte `calico-node` et `kube-proxy` (et éventuellement `storage-provisioner`, qui n'est pas épinglé) ; `uniq -c` donne le compte de chaque nœud, `cka` en tête avec les pods du control plane. La troisième commande répond `No resources found` tant que tout tourne. La quatrième affiche le pod CoreDNS et les trois pods kube-proxy, avec une colonne `K8S-APP`.
>
> Les deux méthodes trouvent les mêmes pods, mais le sélecteur de champ est évalué par l'apiserver, qui ne renvoie que les pods de `cka-m02` ; le filtre jsonpath fait télécharger **tous** les pods du cluster à kubectl, qui les trie ensuite à l'affichage. Sur un gros cluster, la différence se compte en mégaoctets ; et seul le sélecteur fonctionne avec `delete`, `-w` ou `logs`.
>
> **Vérification** : le nombre affiché par la première commande est égal à celui que `uniq -c` donne pour `cka-m02`.

#### Exercice 3.7 — Server-side apply et conflit de gestionnaires

**Point de départ** : exercice 3.6.

Dans `boutique`, l'équipe A applique côté serveur, avec le gestionnaire `equipe-a`, une ConfigMap `essai-ssa` qui contient `couleur: bleu` et `taille: M`. L'équipe B applique ensuite, avec le gestionnaire `equipe-b`, un manifeste qui ne contient que `couleur: rouge`. Observe le refus, puis force la modification. Montre, à partir de `managedFields`, quel gestionnaire possède quel champ. Que se passe-t-il si l'équipe A réapplique son fichier ? Supprime ensuite la ConfigMap.

> [!example]- Solution
> ```bash
> cat > ~/cka/boutique/essai-ssa-a.yaml <<'EOF'
> apiVersion: v1
> kind: ConfigMap
> metadata:
>   name: essai-ssa
>   namespace: boutique
> data:
>   couleur: bleu
>   taille: M
> EOF
> cat > ~/cka/boutique/essai-ssa-b.yaml <<'EOF'
> apiVersion: v1
> kind: ConfigMap
> metadata:
>   name: essai-ssa
>   namespace: boutique
> data:
>   couleur: rouge
> EOF
> kubectl apply --server-side --field-manager=equipe-a -f ~/cka/boutique/essai-ssa-a.yaml
> kubectl apply --server-side --field-manager=equipe-b -f ~/cka/boutique/essai-ssa-b.yaml
> ```
>
> Le premier apply répond `configmap/essai-ssa serverside-applied`. Le second échoue : `error: Apply failed with 1 conflict: conflict with "equipe-a": .data.couleur`, suivi des trois manières de résoudre le conflit. L'équipe B voulait changer une valeur possédée par l'équipe A.
>
> ```bash
> kubectl apply --server-side --field-manager=equipe-b --force-conflicts -f ~/cka/boutique/essai-ssa-b.yaml
> kubectl get configmap essai-ssa \
>   -o jsonpath='{range .metadata.managedFields[*]}{.manager}{" "}{.operation}{" "}{.fieldsV1}{"\n"}{end}'
> ```
>
> ```
> equipe-a Apply {"f:data":{"f:taille":{}}}
> equipe-b Apply {"f:data":{"f:couleur":{}}}
> ```
>
> Le forçage a changé la valeur et transféré la propriété de `couleur` à `equipe-b` ; `equipe-a` ne garde que `taille`. jsonpath lit `managedFields` directement, alors que `-o yaml` les masquerait sans `--show-managed-fields`. Si l'équipe A réapplique son fichier, c'est à son tour d'être refusée : `conflict with "equipe-b": .data.couleur`. Avec un apply côté client, la dernière équipe aurait écrasé l'autre en silence.
>
> ```bash
> kubectl apply --server-side --field-manager=equipe-a -f ~/cka/boutique/essai-ssa-a.yaml
> kubectl delete configmap essai-ssa
> rm ~/cka/boutique/essai-ssa-a.yaml ~/cka/boutique/essai-ssa-b.yaml
> ```
>
> **Vérification** : `kubectl get configmap essai-ssa` répond `Error from server (NotFound): configmaps "essai-ssa" not found`.

#### Exercice 3.8 — Champ immuable, replace --force, wait et events

**Point de départ** : exercice 3.7.

Dans `boutique`, crée le pod `essai` (image `busybox:1.37.0`, commande `sleep 3600`) et attends qu'il soit prêt avec `kubectl wait`. Enregistre-le dans `~/cka/boutique/essai.yaml`, remplace `3600` par `7200` et tente un `kubectl replace`. Fais aboutir la modification, mesure le temps que prend la commande et explique-le. Affiche les événements du pod dans l'ordre chronologique, vérifie avec `exec` la commande qui tourne, puis supprime le pod et attends sa disparition.

> [!example]- Solution
> ```bash
> kubectl run essai --image=busybox:1.37.0 --restart=Never --command -- sleep 3600
> kubectl wait --for=condition=Ready pod/essai --timeout=60s
> kubectl get pod essai -o yaml > ~/cka/boutique/essai.yaml
> sed -i 's/"3600"/"7200"/; s/- 3600$/- "7200"/' ~/cka/boutique/essai.yaml
> grep -A2 'command:' ~/cka/boutique/essai.yaml
> kubectl replace -f ~/cka/boutique/essai.yaml
> ```
>
> `kubectl wait` répond `pod/essai condition met`. Le `replace` simple échoue : `The Pod "essai" is invalid: spec: Forbidden: pod updates may not change fields other than …`, car la commande d'un conteneur est immuable.
>
> ```bash
> time kubectl replace --force -f ~/cka/boutique/essai.yaml
> kubectl wait --for=condition=Ready pod/essai --timeout=60s
> kubectl events --for pod/essai
> kubectl exec essai -- cat /proc/1/cmdline | tr '\0' ' '; echo
> ```
>
> `replace --force` affiche `pod "essai" deleted from boutique namespace` puis `pod/essai replaced`, au bout d'une trentaine de secondes. kubectl supprime le pod et attend sa disparition : `sleep`, PID 1 du conteneur, ignore SIGTERM, et le kubelet ne le tue qu'au terme du délai de grâce de 30 s. Le fichier tiré de `get -o yaml` est réutilisable tel quel, kubectl effaçant la `resourceVersion` avant la recréation. Il contient aussi `spec.nodeName` : le nouveau pod naît déjà lié au nœud de l'ancien, sans passer par le scheduler. `kubectl events --for pod/essai` liste donc, dans l'ordre, ceux de l'ancien pod, de même nom et vieux de moins d'une heure (`Scheduled`, `Pulling`, `Pulled`, `Created`, `Started`, puis `Killing`), puis `Pulled`, `Created` et `Started` du nouveau, **sans** `Scheduled`. `exec` affiche `sleep 7200`.
>
> ```bash
> kubectl delete pod essai --wait=false
> kubectl wait --for=delete pod/essai --timeout=60s
> rm ~/cka/boutique/essai.yaml
> ```
>
> **Vérification** : la dernière commande `wait` répond `pod/essai condition met` (ou rend la main sans message si le pod a déjà disparu), et `kubectl get pods` répond `No resources found in boutique namespace.`

#### Exercice 3.9 — Un fichier kuberc d'essai, puis retour au contexte `cka`

**Point de départ** : exercice 3.8.

Crée un fichier de préférences `~/cka/kuberc`, distinct de `~/.kube/kuberc`, qui définit l'alias `gpb` (pods de `boutique` en sortie `wide`) et rend `kubectl delete` interactif. Utilise l'alias avec ce fichier, puis crée une ConfigMap `jetable` dans `boutique` et montre que sa suppression demande confirmation avec ce fichier, et pas sans lui. Termine en revenant au contexte `cka` : les chapitres suivants, comme les énoncés d'examen, nomment toujours le namespace.

> [!example]- Solution
> ```bash
> printf 'apiVersion: kubectl.config.k8s.io/v1beta1\nkind: Preference\n' > ~/cka/kuberc
> kubectl kuberc set --kuberc ~/cka/kuberc --section aliases --name gpb --command get \
>   --prependarg pods --option namespace=boutique --option output=wide
> kubectl kuberc set --kuberc ~/cka/kuberc --section defaults --command delete --option interactive=true
> kubectl kuberc view --kuberc ~/cka/kuberc
> KUBERC=$HOME/cka/kuberc kubectl gpb
> ```
>
> Le fichier initial est indispensable : un fichier désigné par `--kuberc` doit exister. Chaque `set` répond `Updated …/cka/kuberc`, et `view` affiche les sections `aliases` et `defaults`. `kubectl gpb` devient `kubectl get --namespace=boutique --output=wide pods` et répond `No resources found in boutique namespace.`
>
> ```bash
> kubectl create configmap jetable -n boutique --from-literal=a=b
> KUBERC=$HOME/cka/kuberc kubectl delete configmap jetable -n boutique
> ```
>
> ```
> You are about to delete the following 1 resource(s):
> configmap/jetable
> Do you want to continue? (y/N): n
> deletion is cancelled
> ```
>
> Toute réponse autre que `y` annule. Sans `KUBERC`, kubectl lit `~/.kube/kuberc`, absent : la suppression est immédiate.
>
> ```bash
> kubectl delete configmap jetable -n boutique
> kubectl config use-context cka
> ```
>
> **Vérification** : `kubectl config current-context` affiche `cka`, `kubectl config get-contexts -o name` liste `boutique` et `cka`, et `kubectl get configmaps -n boutique` ne montre que `kube-root-ca.crt`. L'état du cluster est celui que le fil rouge attend : le namespace `boutique`, vide.

---
