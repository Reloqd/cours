---
title: "CKA — 17. Helm et Kustomize"
description: "Installer et paramétrer des composants avec Helm 4 (dépôts, OCI, valeurs, révisions, rollback) et avec Kustomize (bases, overlays, générateurs, patches)."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 17. Helm et Kustomize

Jusqu'ici, chaque objet du fil rouge est né d'un manifeste écrit à la main ou d'une commande impérative. Ce n'est pas ainsi qu'on installe un contrôleur d'Ingress, un opérateur ou une pile de supervision : ces composants comptent des dizaines d'objets (CRD, RBAC, webhooks, Deployments) que leurs auteurs publient sous forme de **chart Helm** ou de **base Kustomize**. Le programme du CKA y consacre une compétence explicite, *Use Helm and Kustomize to install cluster components*, dans le domaine *Cluster Architecture, Installation and Configuration* (25 %). À l'examen, une tâche Helm ou Kustomize se résout en deux ou trois commandes, à condition de connaître leur mécanique : où Helm range l'état d'une release, ce que devient une valeur lors d'un `upgrade`, pourquoi Kustomize renomme une ConfigMap. Ce chapitre traite Helm 4.3 (avec chaque différence par rapport à Helm 3, encore répandu) et Kustomize v5.8.1, intégré à kubectl 1.37. Il installe aussi cert-manager, l'opérateur que le [chapitre 18](18-interfaces-crd-et-operateurs.md) configure.

### 17.1 Deux philosophies : modèles contre superpositions

Helm et Kustomize répondent à la même question (comment produire des manifestes adaptés à un environnement sans les recopier) par deux voies opposées.

```
HELM : des modèles qu'on remplit                 KUSTOMIZE : des manifestes qu'on transforme
═════════════════════════════════                ═════════════════════════════════════════════

  chart/                                           base/
  ├── Chart.yaml                                   ├── kustomization.yaml
  ├── values.yaml     ← valeurs par défaut         ├── deployment.yaml   ← YAML valide,
  └── templates/                                   └── service.yaml        applicable seul
      └── deployment.yaml                                   ▲
          replicas: {{ .Values.replicaCount }}              │ resources: [../../base]
                │                                  overlays/recette/
                │  helm install … --set …          └── kustomization.yaml
                ▼                                      namespace, labels, replicas,
  moteur de templates Go (+ Sprig)                     images, patches, générateurs
                │                                           │
                ▼                                           ▼  kubectl kustomize / apply -k
  manifestes rendus ──▶ API server                 manifestes transformés ──▶ API server
  + une RÉVISION stockée dans le cluster           (aucun état propre : seul le résultat compte)
```

| | Helm 4 | Kustomize v5 |
|---|---|---|
| **Unité** | chart (paquet versionné) | dossier contenant un `kustomization.yaml` |
| **Paramétrage** | valeurs (`values.yaml`, `-f`, `--set`) injectées dans des templates Go | transformations déclaratives appliquées à du YAML valide |
| **Distribution** | dépôts HTTP (`index.yaml`) ou registres OCI | dépôts Git, dossiers locaux |
| **État dans le cluster** | oui : une révision par opération, dans un Secret | non |
| **Historique et rollback** | `helm history`, `helm rollback` | celui de ton gestionnaire de versions |
| **Outil** | binaire `helm` séparé | intégré à kubectl (`-k`) |
| **Cas d'usage typique** | installer un logiciel tiers | décliner ses propres manifestes par environnement |

Les deux se combinent : on rend un chart avec `helm template` puis on le retouche avec Kustomize, ou l'inverse grâce à un post-renderer (17.7). Le choix se fait au cas par cas, et la section 17.14 y revient.

### 17.2 Helm 4 : les concepts

Helm est un **client pur**. Depuis Helm 3, aucun composant ne tourne dans le cluster (Tiller, le serveur de Helm 2, a disparu) : le binaire `helm` lit ton kubeconfig, parle à l'API server avec tes droits, et ne peut donc rien faire que tu ne puisses faire avec kubectl. Quatre notions suffisent à tout décrire.

Un **chart** est un paquet de templates et de valeurs par défaut, identifié par un nom et une version SemVer (`podinfo` 6.15.0). Une **release** est une instance d'un chart installée dans un namespace sous un nom choisi (`vitrine` dans `demo`) : le même chart peut donner dix releases. Chaque opération sur une release (install, upgrade, rollback) crée une **révision** numérotée, qui fige le chart, les valeurs fournies et les manifestes rendus. Enfin, les **valeurs** sont l'arbre YAML qui alimente les templates : celles du chart (`values.yaml`), surchargées par les tiennes.

#### 17.2.1 Anatomie d'un chart

```
podinfo/                         ← helm pull podinfo/podinfo --untar
├── Chart.yaml          apiVersion (v2 ; v1 accepté), name, version (du chart),
│                       appVersion (du logiciel), kubeVersion, dependencies
├── values.yaml         valeurs par défaut, documentées par l'auteur
├── values.schema.json  (facultatif) schéma JSON qui valide les valeurs
├── templates/          templates Go → manifestes
│   ├── _helpers.tpl    définitions réutilisables (noms, labels), jamais rendues seules
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── NOTES.txt       texte affiché après install/upgrade
│   └── tests/          pods annotés helm.sh/hook: test (lancés par helm test)
├── crds/               (facultatif) CRD NON templatées, installées avant le reste
└── charts/             (facultatif) sous-charts (dépendances)
```

Le champ `version` de `Chart.yaml` est celui que vise `--version` ; `appVersion` n'est qu'une information. Le podinfo de ce chapitre a les deux à `6.15.0`, mais c'est une coïncidence : le chart de cert-manager, lui, est en `v1.21.2` avec un `v` devant, et c'est cette chaîne exacte qu'il faut passer.

Les **hooks** sont des manifestes annotés `helm.sh/hook` (`pre-install`, `post-install`, `pre-upgrade`, `post-upgrade`, `pre-rollback`, `post-rollback`, `pre-delete`, `post-delete`, `test`) que Helm crée à un moment précis du cycle de vie, en dehors de la release proprement dite. L'annotation `helm.sh/hook-delete-policy` (`before-hook-creation` par défaut, `hook-succeeded`, `hook-failed`) dit quand les supprimer. cert-manager s'en sert : son Job `cert-manager-startupapicheck` est un hook `post-install` qui attend que le webhook réponde, puis se supprime (`hook-succeeded`).

Le dossier `crds/` obéit à des règles à part, fixées depuis Helm 3 et inchangées en Helm 4 : les CRD qu'il contient ne sont pas des templates, elles sont créées à l'installation si elles n'existent pas encore (`--skip-crds` pour s'en abstenir), **jamais mises à jour** par un `upgrade` et **jamais supprimées** par un `uninstall`. C'est un choix délibéré du projet : supprimer une CRD supprime toutes ses ressources. Beaucoup d'auteurs contournent la règle en plaçant leurs CRD dans `templates/` derrière une valeur, comme cert-manager (`crds.enabled`, exercice 17.6 ; leur protection à la désinstallation est décrite en 17.5.3).

#### 17.2.2 Où Helm range ses données

Côté poste, Helm suit la spécification XDG. Sous Linux, la liste des dépôts est dans `~/.config/helm/repositories.yaml`, les index téléchargés dans `~/.cache/helm/repository/`, les identifiants de registres OCI dans `~/.config/helm/registry/config.json`. Les variables `HELM_CONFIG_HOME`, `HELM_CACHE_HOME` et `HELM_DATA_HOME` déplacent ces trois racines ; `helm env` affiche les valeurs effectives, dont `HELM_MAX_HISTORY` (10 par défaut) et `HELM_NAMESPACE`.

Côté cluster, l'état d'une release vit **dans le namespace de la release**, sous forme de Secrets (17.5). Rien n'est écrit dans `kube-system`, contrairement à Helm 2.

> [!warning] Le namespace par défaut est celui du contexte
> Sans `-n`, Helm prend le namespace du contexte kubeconfig courant, exactement comme kubectl. Si tu travailles dans le contexte `boutique` créé au [chapitre 3](03-kubectl-efficace.md), un `helm install` sans `-n` installe dans `boutique`, et un `helm list` sans `-n` ne montre pas les releases de `demo`. Passe toujours `-n`, et `helm list -A` pour tout voir.

### 17.3 Trouver et inspecter un chart

#### 17.3.1 Dépôts HTTP

Un dépôt « classique » est un simple serveur HTTP qui expose un `index.yaml` (la liste des charts et de leurs versions) et les archives `.tgz`. On l'enregistre sous un nom local, puis on rafraîchit son index :

```bash
helm repo add podinfo https://stefanprodan.github.io/podinfo
helm repo update
helm repo list
helm search repo podinfo --versions | head -4
```

```
"podinfo" has been added to your repositories
Hang tight while we grab the latest from your chart repositories...
...Successfully got an update from the "podinfo" chart repository
Update Complete. ⎈Happy Helming!⎈
NAME     	URL
podinfo  	https://stefanprodan.github.io/podinfo
NAME           	CHART VERSION	APP VERSION	DESCRIPTION
podinfo/podinfo	6.15.0       	6.15.0     	Podinfo Helm chart for Kubernetes
podinfo/podinfo	6.14.1       	6.14.1     	Podinfo Helm chart for Kubernetes
podinfo/podinfo	6.14.0       	6.14.0     	Podinfo Helm chart for Kubernetes
```

`helm search repo` ne cherche que dans les index **locaux** : un chart publié hier reste invisible tant que tu n'as pas lancé `helm repo update`. Sans `--versions`, il n'affiche que la dernière version stable ; `--devel` ajoute les préversions. `helm search hub` interroge Artifact Hub sur Internet, ce qui n'a aucun intérêt à l'examen.

#### 17.3.2 Registres OCI

Depuis Helm 3.8, un chart peut aussi être stocké comme un artefact OCI, dans le même registre que les images. Il n'y a alors ni `repo add` ni index : la référence complète `oci://registre/chemin/nom` se passe directement à chaque commande, avec la version en `--version`.

```bash
helm show chart oci://ghcr.io/stefanprodan/charts/podinfo --version 6.15.0
```

```
Pulled: ghcr.io/stefanprodan/charts/podinfo:6.15.0
Digest: sha256:ff3d3e14728f75476ed4d43c14f80d52d81d36bc16906843463d464c6146f0d8
apiVersion: v1
appVersion: 6.15.0
description: Podinfo Helm chart for Kubernetes
…
name: podinfo
version: 6.15.0
```

Helm 4 accepte en plus une référence par **empreinte** : `oci://ghcr.io/stefanprodan/charts/podinfo@sha256:ff3d3e14…`. Le chart n'est installé que si son contenu correspond à l'empreinte, ce qui protège contre une étiquette réécrite. Pour un registre privé, `helm registry login` prend désormais **le nom de domaine seul** (`helm registry login ghcr.io`) : Helm 4 refuse une URL complète, que Helm 3 tolérait. `helm search repo` ne voit pas les charts OCI, puisqu'il n'y a pas d'index.

Les éditeurs basculent vers OCI. cert-manager l'écrit en toutes lettres : ses charts OCI (`oci://quay.io/jetstack/charts/cert-manager`) sont la source de vérité, publiés dès la sortie d'une version, et le dépôt HTTP historique `https://charts.jetstack.io` n'est mis à jour que quelques heures plus tard.

#### 17.3.3 Lire avant d'installer

`helm show` lit un chart sans rien installer : `chart` (le `Chart.yaml`), `values` (le `values.yaml` complet), `readme`, `crds` (le contenu du dossier `crds/`) et `all`. C'est la commande qui te donne le nom exact d'une valeur :

```bash
helm show values podinfo/podinfo --version 6.15.0 | grep -n -E '^replicaCount|^ui:' -A3
```

```
3:replicaCount: 1
4-logLevel: info
5-host: #0.0.0.0
6-backend: #http://backend-podinfo:9898/echo
--
17:ui:
18-  color: "#34577c"
19-  message: ""
20-  logo: ""
```

La valeur `ui.message` est vide par défaut ; le template du Deployment ne pose la variable `PODINFO_UI_MESSAGE` que si elle est renseignée, et podinfo affiche alors son message intégré, `greetings from podinfo v6.15.0`.

`helm pull podinfo/podinfo --version 6.15.0 --untar` télécharge et décompresse le chart dans le dossier courant, pour lire ses templates ou l'installer depuis le disque (`helm install vitrine ./podinfo`).

> [!tip] Réflexe d'examen
> Ne devine jamais le nom d'une valeur. `helm show values <chart> | grep -i <mot>` prend cinq secondes ; une valeur mal orthographiée dans `--set` est **ignorée sans erreur** (sauf si le chart fournit un `values.schema.json` qui l'interdit), et la tâche est perdue sans que rien ne te prévienne.

### 17.4 Installer une release

#### 17.4.1 La commande

```bash
helm install vitrine podinfo/podinfo --version 6.15.0 \
  -n demo --create-namespace --set replicaCount=2
```

Le premier argument est le nom de la release (`--generate-name` en invente un), le second la référence du chart sous l'une de ses six formes : `dépôt/nom`, archive `.tgz`, dossier décompressé, URL d'archive, `--repo <url> nom`, ou `oci://…`. `--version` accepte une version exacte ou une contrainte (`^6.14.0`) ; sans elle, Helm prend la dernière version stable, ce qui rend la commande non reproductible. `--create-namespace` crée le namespace s'il manque ; sans elle, l'installation échoue dans un namespace inexistant. Attention : ce namespace n'appartient pas à la release, et `helm uninstall` ne le supprimera pas.

`helm install` échoue si une release du même nom existe déjà dans le namespace. `helm upgrade --install` (ou `-i`) installe si la release manque et met à jour sinon : c'est la forme idempotente, celle qu'on met dans un script et celle qui pardonne une seconde tentative à l'examen.

#### 17.4.2 Passer des valeurs

| Option | Effet | Exemple |
|---|---|---|
| `-f`, `--values fichier.yaml` | fusionne un fichier (répétable ; le plus à droite l'emporte) | `-f commun.yaml -f prod.yaml` |
| `--set clé=valeur` | une valeur, type deviné (`true`, `2` deviennent booléen, entier) | `--set ui.message=Bonjour` |
| `--set-string` | force le type chaîne | `--set-string image.tag=1.30` |
| `--set-json` | valeur JSON (objet, liste) | `--set-json 'backends=["http://a","http://b"]'` |
| `--set-file` | contenu d'un fichier comme valeur | `--set-file config=./app.conf` |
| `--set-literal` | chaîne prise telle quelle, sans interprétation des virgules ni des points | |

La syntaxe de `--set` a ses pièges. Un point descend dans l'arbre (`ui.message`), un indice désigne un élément de liste (`ingress.hosts[0].host=x`), des accolades écrivent une liste (`--set liste={a,b}`), une virgule sépare deux affectations (`--set a=1,b=2`), si bien qu'une virgule dans une valeur doit s'échapper (`\,`), comme un point dans une clé (`\.`). `--set clé=null` supprime une clé des valeurs par défaut. Dès que l'arbre se complique, un fichier `-f` est plus sûr.

L'ordre de priorité, du plus faible au plus fort, est le suivant : `values.yaml` du chart, valeurs du chart parent pour un sous-chart, fichiers `-f` de gauche à droite, puis les options `--set*` dans l'ordre de la ligne de commande. Le résultat fusionné s'appelle les *computed values*.

#### 17.4.3 Ce que fait réellement `helm install`

```
helm install vitrine podinfo/podinfo -n demo --set replicaCount=2
════════════════════════════════════════════════════════════════

  1. charge le chart (cache, dépôt ou OCI) et fusionne les valeurs
  2. installe les CRD du dossier crds/ absentes (avant le rendu, pour
     que l'API connaisse déjà leurs kinds)
  3. rend les templates  → manifestes + hooks + NOTES
  4. valide les manifestes contre l'OpenAPI du cluster
     (--disable-openapi-validation pour s'en passer)
  5. crée le namespace si --create-namespace
  6. écrit la révision 1 : Secret sh.helm.release.v1.vitrine.v1
     status=pending-install
  7. hooks pre-install (et attente de leur fin)
  8. crée les objets : server-side apply par défaut en Helm 4,
     gestionnaire de champs « helm »
  9. attente selon --wait (défaut hookOnly : n'attend PAS les pods)
 10. hooks post-install (et attente de leur fin)
 11. révision 1 → status=deployed, description « Install complete »
```

```
NAME: vitrine
LAST DEPLOYED: Fri Oct 23 22:10:41 2026
NAMESPACE: demo
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
NOTES:
1. Get the application URL by running these commands:
  echo "Visit http://127.0.0.1:8080 to use your application"
  kubectl -n demo port-forward deploy/vitrine-podinfo 8080:9898
```

Les objets s'appellent `vitrine-podinfo` : la plupart des charts composent le nom de la release et celui du chart (le helper `fullname` de `_helpers.tpl`). Le chart podinfo crée ici un Service et un Deployment, plus trois pods de test qui ne sont créés que par `helm test vitrine -n demo`.

`STATUS: deployed` signifie que les objets ont été acceptés par l'API, pas que les pods tournent. Avec la stratégie d'attente par défaut de Helm 4 (`hookOnly`, 17.7), la commande rend la main dès les objets créés ; c'est `kubectl -n demo rollout status deployment vitrine-podinfo` ou `--wait` qui te dira si l'application démarre.

#### 17.4.4 Simuler et rendre

Trois façons de voir les manifestes sans les créer, aux garanties différentes :

| Commande | Contacte le cluster | Ce qu'elle garantit |
|---|---|---|
| `helm template vitrine podinfo/podinfo -n demo --set …` | non (capacités par défaut) | le rendu des templates, rien de plus |
| `helm install … --dry-run=client` | non | rendu + affichage de la release simulée (`STATUS: pending-install`) |
| `helm install … --dry-run=server` | oui | rendu + validation par l'API server (admission comprise), sans rien persister |

`helm template` inclut les hooks et les pods de test ; `--skip-tests` retire ces derniers, `-s templates/deployment.yaml` (`--show-only`) ne rend qu'un fichier. Les manifestes rendus sont du YAML ordinaire, que tu peux relire, versionner ou appliquer avec kubectl, mais alors sans release ni historique. Le `--dry-run` sans valeur de Helm 3 est déprécié en Helm 4 : il fonctionne en émettant `--dry-run is deprecated and should be replaced with '--dry-run=client'`. Un rendu qui contient des Secrets les affiche en clair ; `--hide-secret` les masque avec `--dry-run`.

### 17.5 L'état d'une release dans le cluster

#### 17.5.1 Un Secret par révision

Chaque révision est un Secret du namespace de la release, nommé `sh.helm.release.v1.<release>.v<N>`, de type `helm.sh/release.v1`. Ce format est celui de Helm 3, repris tel quel par Helm 4 : un cluster passé de l'un à l'autre garde ses releases.

```bash
kubectl -n demo get secrets -l owner=helm -L status,version
```

```
NAME                            TYPE                 DATA   AGE   STATUS       VERSION
sh.helm.release.v1.vitrine.v1   helm.sh/release.v1   1      6m    superseded   1
sh.helm.release.v1.vitrine.v2   helm.sh/release.v1   1      3m    superseded   2
sh.helm.release.v1.vitrine.v3   helm.sh/release.v1   1      40s   deployed     3
```

Les labels `owner=helm`, `name`, `status` et `version` permettent à Helm de retrouver ses révisions par sélecteur ; `modifiedAt` (date de la dernière écriture, en secondes Unix) s'y ajoute. La clé unique `release` contient l'enregistrement complet (chart, valeurs fournies, manifestes rendus, hooks, notes), sérialisé en JSON, compressé en gzip puis encodé en base64, le tout encodé une seconde fois en base64 par l'API Secret :

```bash
kubectl -n demo get secret sh.helm.release.v1.vitrine.v2 -o jsonpath='{.data.release}' \
  | base64 -d | base64 -d | gzip -d | head -c 300; echo
```

Trois conséquences pratiques. Supprimer le namespace supprime tout l'historique de ses releases. Qui a le droit de lire les Secrets d'un namespace lit aussi les valeurs de ses releases, mots de passe compris. Et une révision restée en `pending-install`, `pending-upgrade` ou `pending-rollback` (opération interrompue) bloque la suivante avec l'erreur `another operation (install/upgrade/rollback) is in progress` : on en sort par `helm rollback` vers la dernière révision saine, ou en supprimant le Secret de la révision en attente.

`HELM_DRIVER` choisit un autre stockage (`configmap`, `memory`, `sql`) ; `secret` est la valeur par défaut et il n'y a pas de raison d'en changer.

#### 17.5.2 Lire une release

| Commande | Ce qu'elle affiche |
|---|---|
| `helm list -n demo` / `helm list -A` | releases déployées ou en échec (`-a` pour tous les statuts, `--superseded`, `--uninstalled`…) |
| `helm status vitrine -n demo` | l'en-tête d'install (statut, révision, notes) ; `--show-resources` liste les objets |
| `helm history vitrine -n demo` | toutes les révisions conservées |
| `helm get values vitrine -n demo` | les valeurs **fournies** (`USER-SUPPLIED VALUES`) ; `-a` pour les valeurs calculées ; `--revision N` |
| `helm get manifest vitrine -n demo` | les manifestes rendus de la révision |
| `helm get notes` / `hooks` / `metadata` / `all` | le reste de l'enregistrement |

```bash
helm list -A
```

```
NAME        	NAMESPACE           	REVISION	UPDATED                                 	STATUS  	CHART               	APP VERSION
cert-manager	cert-manager        	1       	2026-10-23 22:31:07.410229915 +0200 CEST	deployed	cert-manager-v1.21.2	v1.21.2
eg          	envoy-gateway-system	1       	2026-10-23 19:02:55.120871300 +0200 CEST	deployed	gateway-helm-v1.9.2 	v1.9.2
vitrine     	demo                	3       	2026-10-23 22:16:30.902117443 +0200 CEST	deployed	podinfo-6.15.0      	6.15.0
```

On y retrouve la release `eg` d'Envoy Gateway, installée au [chapitre 13](13-gateway-api.md). La colonne CHART concatène le nom et la version du chart ; `helm list` trie par nom (`-d` pour trier par date).

#### 17.5.3 Désinstaller

`helm uninstall vitrine -n demo` supprime les objets de la dernière révision, puis tous les Secrets de la release. Il épargne trois catégories d'objets : les CRD du dossier `crds/`, les objets annotés `helm.sh/resource-policy: keep` (cert-manager pose cette annotation sur ses CRD, valeur `crds.keep: true` par défaut), et le namespace créé par `--create-namespace`. `--keep-history` conserve les Secrets (la release passe en `uninstalled` et reste visible par `helm list --uninstalled`), ce qui autorise un `helm rollback` ultérieur. `--cascade` choisit la propagation de suppression (`background` par défaut, `foreground`, `orphan`).

### 17.6 Mettre à jour, consulter l'historique, revenir en arrière

#### 17.6.1 `helm upgrade` et le sort des valeurs

`helm upgrade` rend à nouveau le chart (éventuellement dans une autre version) avec un nouveau jeu de valeurs, applique la différence et crée la révision suivante. Toute la difficulté tient dans ce « nouveau jeu de valeurs » : Helm ne fusionne **pas** automatiquement tes anciennes valeurs avec les nouvelles.

| Options | Valeurs de la nouvelle révision |
|---|---|
| aucune valeur fournie (ni `-f` ni `--set`) | les valeurs fournies de la révision précédente, recopiées |
| `--set ui.message=Bonjour` seul | **uniquement** `ui.message=Bonjour` : `replicaCount=2` est perdu, le chart revient à 1 réplica |
| `--reuse-values --set ui.message=Bonjour` | anciennes valeurs fournies + nouvelles (les nouvelles l'emportent) ; les **défauts** restent ceux de l'ancien chart |
| `--reset-then-reuse-values --set …` | défauts du **nouveau** chart + anciennes valeurs fournies + nouvelles |
| `--reset-values` | défauts du chart + valeurs de la ligne de commande seulement |

La deuxième ligne est le piège classique : on croit modifier un paramètre, on en réinitialise dix. `--reuse-values` convient tant que la version du chart ne change pas ; lors d'un changement de version, il conserve les anciens défauts et peut priver le nouveau chart d'une valeur qu'il attend, d'où `--reset-then-reuse-values` (apparue dans Helm 3.14). La solution la plus robuste reste de garder toutes tes valeurs dans un fichier versionné et de le repasser à chaque fois avec `-f`.

```bash
helm upgrade vitrine podinfo/podinfo --version 6.15.0 -n demo \
  --reuse-values --set ui.message=Bonjour
```

```
Release "vitrine" has been upgraded. Happy Helming!
NAME: vitrine
LAST DEPLOYED: Fri Oct 23 22:14:02 2026
NAMESPACE: demo
STATUS: deployed
REVISION: 2
DESCRIPTION: Upgrade complete
…
```

Si l'upgrade échoue, la nouvelle révision passe en `failed` et la précédente reste `deployed`, mais les objets déjà modifiés le restent. `--rollback-on-failure` (l'ancien `--atomic`) revient automatiquement à la dernière révision réussie et force la stratégie d'attente `watcher` ; `--cleanup-on-fail` supprime les objets créés par l'upgrade raté. `--history-max` (10 par défaut, `HELM_MAX_HISTORY`) borne le nombre de révisions conservées : au-delà, les plus anciennes sont supprimées et on ne peut plus y revenir.

#### 17.6.2 `helm history` et `helm rollback`

```bash
helm history vitrine -n demo
helm rollback vitrine 1 -n demo
helm history vitrine -n demo
```

```
REVISION	UPDATED                 	STATUS    	CHART         	APP VERSION	DESCRIPTION
1       	Fri Oct 23 22:10:41 2026	superseded	podinfo-6.15.0	6.15.0     	Install complete
2       	Fri Oct 23 22:14:02 2026	deployed  	podinfo-6.15.0	6.15.0     	Upgrade complete
Rollback was a success! Happy Helming!
REVISION	UPDATED                 	STATUS    	CHART         	APP VERSION	DESCRIPTION
1       	Fri Oct 23 22:10:41 2026	superseded	podinfo-6.15.0	6.15.0     	Install complete
2       	Fri Oct 23 22:14:02 2026	superseded	podinfo-6.15.0	6.15.0     	Upgrade complete
3       	Fri Oct 23 22:16:30 2026	deployed  	podinfo-6.15.0	6.15.0     	Rollback to 1
```

Un rollback **ne revient pas** au numéro 1 : il crée une révision 3 qui recopie le chart, les valeurs et les manifestes de la révision 1. L'historique ne fait que croître, ce qui le rend auditable. Sans numéro, `helm rollback vitrine` revient à la révision précédente. `helm history --show-rollback-revision` (Helm 4) ajoute une colonne ROLLBACK qui indique la révision restaurée.

Le parallèle avec `kubectl rollout undo` ([chapitre 5](05-deployments-et-controleurs.md)) est trompeur. Le rollback d'un Deployment ne restaure que le gabarit de pods ; celui de Helm restaure **tous** les objets du chart, et supprime ceux que la révision cible ne contenait pas.

### 17.7 Ce que Helm 4 change

Helm 4.0 est sorti le 17 novembre 2025 ; la branche 4.3 est courante en octobre 2026 (4.3.1 le 15 octobre). Helm 3 ne reçoit plus que des correctifs de sécurité, jusqu'au 11 novembre 2026. Les charts `apiVersion: v2` fonctionnent à l'identique et le stockage des releases n'a pas changé ; ce qui change, c'est la façon d'appliquer et d'attendre, et le nom de quelques options.

| Sujet | Helm 3 | Helm 4.3 |
|---|---|---|
| Méthode d'application | client-side, *three-way merge* (ancien manifeste, nouveau, objet vivant) | **server-side apply** pour toute nouvelle installation (`--server-side`, vrai par défaut à l'install) |
| Upgrade et rollback | three-way merge | `--server-side=auto` : reprend la méthode de la révision précédente ; une release née sous Helm 3 reste en client-side tant qu'on ne force pas `--server-side=true` |
| Conflits de champs | l'upgrade écrase silencieusement | conflit SSA si un autre gestionnaire possède le champ ; `--force-conflicts` reprend la main |
| Attente | `--wait` booléen (absent : n'attend que les hooks) | `--wait` devient une **stratégie** : `hookOnly` (défaut si l'option est absente), `watcher` (`--wait` seul, statut kstatus), `legacy` (l'attente de Helm 3) ; `--wait=true/false` déprécié |
| Retour arrière automatique | `--atomic` | `--rollback-on-failure` (`--atomic` déprécié, encore accepté) |
| Remplacement forcé | `--force` | `--force-replace` (`--force` déprécié) |
| Simulation | `--dry-run` booléen | `--dry-run=client|server|none` (`--dry-run` seul déprécié) |
| Post-renderers | un exécutable quelconque | un **plugin** Helm seulement |
| `helm registry login` | URL complète tolérée | nom de domaine seul |
| `helm template --hide-notes`, `--render-subchart-notes` | options actives | dépréciées, sans effet, retirées en Helm 5 |
| Installation OCI | par étiquette | par étiquette ou par empreinte `@sha256:` |
| Stockage des révisions | Secrets `sh.helm.release.v1.*` | identique |

Les options dépréciées restent acceptées et affichent un avertissement, par exemple `Flag --atomic has been deprecated, use --rollback-on-failure instead`. Ne les écris plus.

#### 17.7.1 Server-side apply et `helm upgrade`

Avec server-side apply ([chapitre 3](03-kubectl-efficace.md)), l'API server tient dans `metadata.managedFields` la liste des champs que chaque gestionnaire a fixés. Helm 4 applique sous le nom de gestionnaire `helm` (le nom de son binaire). Deux effets se voient en exploitation.

Le premier concerne les modifications faites à côté de Helm. Sous Helm 3, si quelqu'un avait lancé `kubectl scale deployment vitrine-podinfo --replicas=5`, l'upgrade suivant remettait la valeur du chart sans prévenir, puisque le three-way merge comparait l'objet vivant au manifeste attendu. Sous Helm 4, la mise à l'échelle a transféré la propriété de `spec.replicas` au gestionnaire de kubectl ; si le chart fixe une autre valeur, l'apply de Helm rencontre un **conflit** et l'upgrade échoue, même s'il ne change aucune valeur de la release :

```
Error: UPGRADE FAILED: conflict occurred while applying object demo/vitrine-podinfo apps/v1, Kind=Deployment: Apply failed with 1 conflict: conflict with "kubectl" with subresource "scale" using apps/v1: .spec.replicas
```

La révision tentée reste dans l'historique en `failed`, la précédente reste `deployed`, et le Deployment garde ses 5 réplicas. `--force-conflicts` reprend la propriété du champ : l'upgrade suivant réussit et remet la valeur du chart. C'est voulu : Helm ne piétine plus en silence le travail d'un autre acteur, opérateur ou humain.

Le second concerne les releases existantes. Une release installée par Helm 3 a été appliquée en client-side ; `--server-side=auto` la laisse ainsi, pour ne pas provoquer de conflits imprévus au premier upgrade sous Helm 4. On la bascule délibérément avec `helm upgrade … --server-side=true` : Helm convertit alors les gestionnaires client-side en gestionnaires server-side. Un bénéfice annexe du server-side apply : plus d'annotation `kubectl.kubernetes.io/last-applied-configuration`, donc plus de limite de taille d'annotation sur les très grosses CRD.

#### 17.7.2 Les stratégies d'attente

```
--wait absent       → hookOnly : attend les hooks (Jobs, Pods), PAS les objets du chart
--wait              → watcher  : suit chaque objet avec kstatus (Deployment disponible,
                                 Service avec adresse, Job terminé si --wait-for-jobs…)
--wait=legacy       → l'algorithme d'attente de Helm 3, par interrogations périodiques
--timeout 5m0s      → délai de CHAQUE opération d'attente (défaut 5 min)
```

Le comportement par défaut correspond à celui de Helm 3 sans `--wait` : rendre la main vite. Mais `hookOnly` attend bien les hooks, ce qui explique qu'installer cert-manager prenne une demi-minute : le hook `post-install` `startupapicheck` ne réussit que quand le webhook répond. Pour qu'une installation ne soit déclarée réussie qu'avec des pods prêts, ajoute `--wait`.

> [!tip] Réflexe d'examen
> Une tâche Helm suppose le binaire présent sur l'hôte de la tâche : commence par `helm version`. Les sous-commandes utiles à l'examen (`repo add`, `search repo`, `show values`, `install`, `upgrade --install`, `list`, `history`, `rollback`, `get values`, `template`, `uninstall`) sont identiques en Helm 3 et 4 ; seules les options du tableau ci-dessus diffèrent. Épingle toujours `--version`, passe toujours `-n`, et vérifie avec `helm list -n <ns>` puis `kubectl get` : une release `deployed` n'est pas une application qui tourne.

### 17.8 Kustomize : le principe

Kustomize part d'un constat : un manifeste YAML valide est déjà le meilleur modèle possible. Plutôt que d'y percer des trous à remplir, il le laisse intact et décrit, dans un fichier `kustomization.yaml`, des **transformations** à lui appliquer : changer le namespace, ajouter des labels, remplacer une image, fixer un nombre de réplicas, générer des ConfigMaps, appliquer des patches. Une **base** décrit l'application commune ; une **overlay** référence la base et y ajoute ses transformations. La base ignore l'existence des overlays.

Kustomize est intégré à kubectl depuis la 1.14 ; kubectl 1.37 embarque **Kustomize v5.8.1**, que `kubectl version --client` affiche. Deux points d'entrée suffisent :

| Commande | Effet |
|---|---|
| `kubectl kustomize <dossier>` | rend le résultat sur la sortie standard, sans contacter le cluster |
| `kubectl apply -k <dossier>` | rend puis applique (client-side apply par défaut, `--server-side` possible) |
| `kubectl diff -k <dossier>` | compare le rendu à l'état du cluster |
| `kubectl delete -k <dossier>` | supprime les objets du rendu |

Le binaire autonome `kustomize build` donne le même rendu et offre en plus `kustomize edit` (modification du `kustomization.yaml` en ligne de commande) et `kustomize edit fix` (migration des champs dépréciés). À l'examen, seul kubectl compte.

### 17.9 Le fichier `kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:                 # fichiers, dossiers contenant un kustomization.yaml, URL Git
- deployment.yaml
- ../../base
namespace: boutique-recette
namePrefix: rec-           # aussi nameSuffix
labels:
- pairs:
    env: recette
  includeSelectors: false  # défaut : n'ajoute pas aux sélecteurs
  includeTemplates: true   # ajoute aussi aux gabarits de pods
commonAnnotations:
  equipe: catalogue
images:
- name: nginx              # nom d'image tel qu'il apparaît dans les manifestes
  newName: registry.example/nginx
  newTag: "1.30.6-alpine"  # ou digest: sha256:…
replicas:
- name: front
  count: 1
configMapGenerator: []
secretGenerator: []
generatorOptions: {}
patches: []
```

Les champs `apiVersion` et `kind` sont facultatifs mais conseillés. Chaque transformation porte sur **toutes** les ressources connues de la kustomization, y compris celles héritées d'une base. Le tableau ci-dessous résume leur comportement, vérifié avec kubectl 1.37.

| Champ | Effet | Point d'attention |
|---|---|---|
| `resources` | liste des entrées | un dossier doit contenir un `kustomization.yaml` |
| `namespace` | fixe `metadata.namespace` des objets namespacés | **renomme** aussi un objet `Namespace` présent dans les ressources ; dans les (Cluster)RoleBindings, ne réécrit que les sujets ServiceAccount nommés `default` |
| `namePrefix`, `nameSuffix` | renomment les objets | les références (volume ConfigMap, `serviceName`…) ne sont réécrites que vers des objets **connus** de la kustomization |
| `labels` | ajoute des labels | par défaut **seulement** `metadata.labels` ; `includeTemplates: true` ajoute aux gabarits de pods, `includeSelectors: true` aussi aux sélecteurs |
| `commonAnnotations` | ajoute des annotations | partout, gabarits compris |
| `images` | change `newName`, `newTag` ou `digest` des conteneurs dont l'image porte le nom `name` | sans effet si aucun conteneur n'utilise ce nom |
| `replicas` | fixe `spec.replicas` (Deployment, ReplicaSet, StatefulSet, ReplicationController) | un nom qui ne correspond à aucun objet est une **erreur** |
| `configMapGenerator`, `secretGenerator` | génèrent des objets avec suffixe de hachage | 17.10 |
| `patches` | patches stratégiques ou JSON 6902 | 17.11 |
| `components` | inclut des fragments réutilisables (`kind: Component`) | optionnel, pour composer des variantes |

Plusieurs champs historiques sont dépréciés en v5. Ils fonctionnent encore, mais kubectl affiche un avertissement sur la sortie d'erreur :

```
# Warning: 'commonLabels' is deprecated. Please use 'labels' instead. Run 'kustomize edit fix' to update your Kustomization automatically.
# Warning: 'patchesStrategicMerge' is deprecated. Please use 'patches' instead. Run 'kustomize edit fix' to update your Kustomization automatically.
```

| Champ déprécié | Remplaçant | Différence de comportement |
|---|---|---|
| `commonLabels` | `labels` avec `includeSelectors: true` | `commonLabels` touche **toujours** les sélecteurs ; `labels` ne le fait que sur demande |
| `patchesStrategicMerge` | `patches` (avec `path` ou `patch`) | aucune |
| `patchesJson6902` | `patches` (avec `target`) | aucune |
| `bases` | `resources` | aucune |
| `vars` | `replacements` | `replacements` copie un champ vers d'autres, sans syntaxe `$(VAR)` |

La différence entre `commonLabels` et `labels` n'est pas cosmétique. Le sélecteur d'un Deployment est **immuable** : ajouter un label de sélecteur à un Deployment déjà déployé fait échouer l'apply (`field is immutable`), et un Service dont le sélecteur gagne un label que les pods n'ont pas encore perd tous ses backends. Le comportement par défaut de `labels` évite ces deux accidents.

### 17.10 Générateurs et suffixe de hachage

Un générateur fabrique une ConfigMap ou un Secret à partir de fichiers (`files`), de paires littérales (`literals`) ou de fichiers d'environnement (`envs`, une ligne `CLÉ=valeur` par entrée). Pour `files`, la clé est le nom du fichier, ou celle que tu imposes avec `clé=chemin`.

```yaml
configMapGenerator:
- name: front-html
  files:
  - index.html                 # clé « index.html »
secretGenerator:
- name: front-secret
  literals:
  - CLE=valeur                 # type Opaque par défaut ; « type: » pour un autre
```

Le résultat porte un **suffixe de hachage** calculé sur le nom et le contenu (pas sur les labels ni le namespace) : `front-html-b97596tc55`. Kustomize réécrit en même temps toutes les références à `front-html` dans les objets qu'il connaît (volumes, `envFrom`, `valueFrom`). La conséquence est le vrai intérêt du mécanisme :

```
Modifier index.html avec un générateur
══════════════════════════════════════

  contenu modifié ─▶ nouveau hachage ─▶ ConfigMap front-html-t55hf2hm4k (NOUVELLE)
                                        │
                                        ▼
                     Deployment : volume.configMap.name réécrit
                                        │
                                        ▼
                     gabarit de pods modifié ─▶ ROLLOUT automatique
                                                (nouvelles pods, nouvelle page)

  L'ancienne ConfigMap front-html-2cbdmhthgc reste dans le cluster :
  kubectl apply -k ne supprime rien (pas de « prune »). Elle sert de
  filet pendant le rollout, puis se supprime à la main.
```

Sans générateur, modifier une ConfigMap montée en volume propage le fichier aux pods au bout de la période de synchronisation du kubelet, sans redémarrage, et une ConfigMap consommée en variables d'environnement n'est jamais relue ([chapitre 6](06-configmaps-et-secrets.md)). Le hachage transforme un changement de configuration en déploiement versionné, réversible par `kubectl rollout undo`.

`generatorOptions` règle tous les générateurs du fichier : `disableNameSuffixHash: true` supprime le suffixe (et le rollout automatique), `labels` et `annotations` étiquettent les objets générés, `immutable: true` les rend immuables. Dans une overlay, un générateur qui porte le nom d'un objet généré par la base doit déclarer `behavior: merge` (ajoute ou remplace des clés) ou `behavior: replace` (remplace tout le contenu) ; sans cela, Kustomize refuse :

```
error: merging from generator &{…}: id resid.ResId{…Kind:"ConfigMap"…, Name:"front-html", …} exists; can not use behavior: 'unspecified', behavior must be merge or replace
```

Enfin, par sécurité, un générateur ne lit que des fichiers situés **dans ou sous** le dossier de sa kustomization (`--load-restrictor=LoadRestrictionsRootOnly`, défaut). Une overlay qui pointe `files: [../../base/index.html]` est refusée (`security; file '…/base/index.html' is not in or below '…/overlays/recette'`). Le fichier doit être copié dans l'overlay.

### 17.11 Patches

Le champ `patches` accepte deux formats, en fichier (`path`) ou en ligne (`patch`), éventuellement restreints par une cible (`target`).

Un **patch stratégique** ressemble à un extrait de l'objet : il en reprend `apiVersion`, `kind` et `metadata.name`, puis seulement les champs à changer. Les listes connues de Kubernetes sont fusionnées par clé (les conteneurs par `name`, les ports par `containerPort`), si bien qu'on modifie un conteneur sans réécrire les autres. La directive `$patch: delete` supprime un élément.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: front
spec:
  template:
    spec:
      containers:
      - name: nginx            # clé de fusion : seul ce conteneur est touché
        resources:
          limits:
            memory: 128Mi      # les autres champs du conteneur sont conservés
```

Un **patch JSON 6902** est une liste d'opérations (`add`, `remove`, `replace`, `move`, `copy`, `test`) sur des chemins JSON Pointer ; il est précis mais fragile, car il dépend des indices de listes. Il exige une cible :

```yaml
patches:
- path: patch-ressources.yaml          # stratégique, cible lue dans le fichier
- target:
    kind: Deployment
    name: front                        # accepte une expression régulière
  patch: |-
    - op: add
      path: /spec/template/spec/containers/0/env
      value:
      - name: MODE
        value: recette
```

`target` filtre sur `group`, `version`, `kind`, `name`, `namespace`, `labelSelector` et `annotationSelector` ; un même patch stratégique peut ainsi s'appliquer à plusieurs objets s'il porte une cible (le nom dans le fichier est alors ignoré). Les patches et `replicas` désignent les objets par leur nom d'origine, avant `namePrefix`.

### 17.12 Bases et overlays

```
~/cka/kustomize/
├── base/                        ← l'application, sans environnement
│   ├── kustomization.yaml          resources + configMapGenerator
│   ├── deployment.yaml             Deployment front (3 réplicas)
│   ├── service.yaml                Service front
│   └── index.html                  <h1>Boutique</h1><p>v1</p>
└── overlays/
    └── recette/                 ← une variante
        ├── kustomization.yaml      resources: [namespace.yaml, ../../base]
        ├── namespace.yaml          + namespace, labels, replicas, generator replace
        └── index.html              <h1>Boutique</h1><p>v1-recette</p>
```

Une overlay peut empiler d'autres overlays, et une ressource peut être une URL Git (`https://github.com/org/depot//chemin?ref=v1.2.0`), ce qui permet de consommer la base d'un éditeur en l'épinglant à une étiquette. Kustomize trie le rendu dans un ordre qui place les `Namespace` et les CRD en tête : `kubectl apply -k` crée donc le namespace avant les objets qu'il contient, en un seul passage.

> [!warning] `-f` n'est pas `-k`
> `kubectl apply -f overlays/recette/` traite chaque fichier YAML du dossier comme un objet : `kustomization.yaml` échoue (aucune ressource de kind `Kustomization` dans l'API), et les autres fichiers sont appliqués **tels quels**, sans transformation, dans le namespace courant. Une base ne se déploie pas non plus seule si elle ne fixe pas de namespace : son rendu atterrirait dans le namespace du contexte.

### 17.13 Appliquer et vérifier

La méthode qui évite les surprises tient en trois temps : rendre et relire (`kubectl kustomize`), comparer (`kubectl diff -k`), appliquer (`kubectl apply -k`). `kubectl diff` simule chaque objet côté serveur sans rien créer : sur une overlay qui apporte son propre namespace, il échoue tant que ce namespace n'existe pas (exercice 17.8). Le rendu est déterministe : deux personnes qui ont les mêmes fichiers octet pour octet obtiennent les mêmes suffixes de hachage.

```bash
kubectl kustomize ~/cka/kustomize/overlays/recette | grep -E '^kind|^  name|replicas|env:'
kubectl apply -k ~/cka/kustomize/overlays/recette
```

```
namespace/boutique-recette created
configmap/front-html-2cbdmhthgc created
service/front created
deployment.apps/front created
```

`kubectl apply -k` n'élague pas : retirer une ressource du `kustomization.yaml` ne la supprime pas du cluster. `kubectl delete -k` sur l'ancienne version, ou une suppression explicite, est nécessaire. L'option `--prune` de `kubectl apply` existe mais reste alpha ; ne t'en sers pas.

### 17.14 Helm ou Kustomize ?

| Situation | Outil | Pourquoi |
|---|---|---|
| Installer un logiciel tiers (contrôleur, opérateur, supervision) | Helm | l'éditeur publie un chart, maintient ses valeurs, ses CRD et ses mises à jour |
| Décliner tes propres manifestes en dev, recette, prod | Kustomize | pas de langage de template, le YAML reste lisible et valide |
| Revenir à l'état d'hier en une commande | Helm | historique de révisions dans le cluster |
| Retoucher un chart tiers sur un point que ses valeurs n'exposent pas | les deux | `helm template … > rendu.yaml` puis une kustomization avec patches, ou un post-renderer Kustomize empaqueté en plugin Helm 4 |
| Tâche d'examen « installe X avec Helm » / « applique l'overlay Y » | celui qui est demandé | la correction vérifie la release ou les objets |

Kustomize sait aussi gonfler un chart lui-même (champ `helmCharts`), mais seulement avec `kubectl kustomize --enable-helm` et un binaire `helm` installé : c'est un usage marginal.

### 17.15 Pièges courants

```
Piège 1 : helm upgrade --set sans --reuse-values
═════════════════════════════════════════════════
  MAUVAIS  : helm upgrade vitrine podinfo/podinfo -n demo --set ui.message=Bonjour
  SYMPTÔME : le message change… et le Deployment repasse à 1 réplica :
             replicaCount=2 n'a pas été reconduit.
  BON      : --reuse-values (même version de chart), ou -f valeurs.yaml
             complet à chaque upgrade.

Piège 2 : Oublier -n
════════════════════
  SYMPTÔME : « release: not found », ou une release installée dans le
             namespace du contexte courant au lieu de celui demandé.
  BON      : -n <ns> sur CHAQUE commande helm ; helm list -A pour vérifier.

Piège 3 : Croire qu'une release « deployed » tourne
════════════════════════════════════════════════════
  SYMPTÔME : STATUS: deployed, pods en ImagePullBackOff.
  CAUSE    : Helm 4 attend par défaut les hooks seulement (hookOnly).
  BON      : --wait (stratégie watcher), ou kubectl rollout status.

Piège 4 : Une valeur mal orthographiée
══════════════════════════════════════
  MAUVAIS  : --set replicacount=2
  SYMPTÔME : aucune erreur, 1 réplica.
  BON      : helm show values … | grep -i replica, puis
             helm get values <release> -n <ns> pour relire.

Piège 5 : Les CRD et helm uninstall
═══════════════════════════════════
  SYMPTÔME : après uninstall, les CRD (et leurs ressources) sont toujours là ;
             ou, à l'inverse, un upgrade n'a pas mis à jour une CRD de crds/.
  CAUSE    : crds/ n'est ni mis à jour ni supprimé ; resource-policy: keep.
  BON      : gérer les CRD explicitement (kubectl apply / delete), en
             connaissance de cause : supprimer une CRD supprime ses objets.

Piège 6 : commonLabels sur une application déjà déployée
════════════════════════════════════════════════════════
  SYMPTÔME : « spec.selector: Invalid value … field is immutable ».
  BON      : labels (sans includeSelectors) ; includeTemplates: true si
             les pods doivent porter le label.

Piège 7 : Générateur redéfini dans une overlay sans behavior
════════════════════════════════════════════════════════════
  SYMPTÔME : « behavior must be merge or replace ».
  BON      : behavior: replace (ou merge) dans l'overlay.

Piège 8 : Fichier hors de la racine de la kustomization
═══════════════════════════════════════════════════════
  SYMPTÔME : « security; file … is not in or below … ».
  BON      : copier le fichier dans le dossier de l'overlay.

Piège 9 : kubectl apply -f sur un dossier Kustomize
═══════════════════════════════════════════════════
  SYMPTÔME : erreur sur kind Kustomization, objets bruts créés dans le
             namespace courant.
  BON      : kubectl apply -k.
```

> [!summary] À retenir
> - Helm est un client pur ; l'état d'une release est une suite de Secrets `sh.helm.release.v1.<release>.v<N>` (type `helm.sh/release.v1`) dans le namespace de la release, au même format en Helm 3 et 4.
> - `helm show values` avant toute installation ; `--version` toujours épinglé ; `-n` sur chaque commande ; `helm upgrade --install` pour l'idempotence.
> - Un `upgrade` qui reçoit des valeurs oublie les anciennes : `--reuse-values` (même chart) ou `--reset-then-reuse-values` (nouveau chart), ou un fichier `-f` complet.
> - `helm rollback <release> <N>` crée une nouvelle révision copiée de la révision N ; `helm history` ne fait que croître (borne : `--history-max`, 10).
> - Helm 4 : server-side apply par défaut à l'installation (`--server-side=auto` à l'upgrade), `--wait` devenu stratégie (`hookOnly` par défaut, `watcher` avec `--wait`), `--atomic` → `--rollback-on-failure`, `--force` → `--force-replace`, `--dry-run=client|server`.
> - Les CRD du dossier `crds/` ne sont ni mises à jour ni supprimées par Helm ; cert-manager installe les siennes par `--set crds.enabled=true` et les protège par `helm.sh/resource-policy: keep`.
> - Kustomize v5.8.1 (kubectl 1.37) : `labels` au lieu de `commonLabels` (sélecteurs intacts par défaut), `patches` au lieu de `patchesStrategicMerge`/`patchesJson6902`.
> - Les générateurs ajoutent un suffixe de hachage et réécrivent les références : changer le contenu déclenche un rollout ; l'ancienne ConfigMap reste, `apply -k` n'élague pas.
> - `kubectl kustomize` pour relire, `kubectl diff -k` pour comparer, `kubectl apply -k` pour appliquer ; jamais `-f` sur un dossier Kustomize.

### 17.16 Exercices

Les fichiers de ce chapitre vont dans `~/cka/helm/` et `~/cka/kustomize/`. Le pod `outils` du namespace `boutique` ([chapitre 4](04-pods.md)) sert de client HTTP : sa NetworkPolicy `outils-sortie` ([chapitre 14](14-network-policies.md)) l'autorise à joindre n'importe quel namespace.

#### Exercice 17.1 — Inspecter un chart

**Point de départ** : fin du chapitre 16, ou instantané I3 (les exercices de ce chapitre n'utilisent pas les objets du chapitre 16).

Ajoute le dépôt Helm `podinfo` (`https://stefanprodan.github.io/podinfo`). Écris dans `~/cka/helm/podinfo-versions.txt` les trois versions les plus récentes du chart `podinfo/podinfo`. Trouve, sans rien installer, le nom exact et la valeur par défaut de la valeur qui règle le nombre de réplicas et de celle qui règle le message de l'interface.

> [!example]- Solution
> ```bash
> mkdir -p ~/cka/helm
> helm repo add podinfo https://stefanprodan.github.io/podinfo
> helm repo update
> helm search repo podinfo/podinfo --versions | head -4 | tail -3 | awk '{print $2}' > ~/cka/helm/podinfo-versions.txt
> helm show values podinfo/podinfo --version 6.15.0 | grep -n -E '^replicaCount|^ui:' -A3
> ```
>
> `helm search repo` lit l'index local : sans `helm repo update`, une version récente pourrait manquer. La première ligne de sa sortie est l'en-tête, d'où `head -4 | tail -3`. Les valeurs s'appellent `replicaCount` (défaut 1) et `ui.message` (défaut chaîne vide, ce qui laisse podinfo afficher `greetings from podinfo v6.15.0`).
>
> **Vérification** : `cat ~/cka/helm/podinfo-versions.txt` affiche `6.15.0`, `6.14.1`, `6.14.0`, une par ligne ; `helm repo list` contient `podinfo`.

#### Exercice 17.2 — Installer la release `vitrine`

**Point de départ** : exercice 17.1.

Installe le chart `podinfo/podinfo` en version 6.15.0 sous le nom de release `vitrine`, dans le namespace `demo` (à créer par Helm), avec 2 réplicas. Attends que le Deployment soit disponible. Montre où Helm a enregistré la révision.

> [!example]- Solution
> ```bash
> helm install vitrine podinfo/podinfo --version 6.15.0 \
>   -n demo --create-namespace --set replicaCount=2
> kubectl -n demo rollout status deployment vitrine-podinfo
> helm list -n demo
> kubectl -n demo get secrets -l owner=helm -L status,version
> ```
>
> Helm 4 n'attend pas les pods par défaut (stratégie `hookOnly`) : `rollout status` fait l'attente. On aurait aussi pu ajouter `--wait` à l'installation. La révision 1 est le Secret `sh.helm.release.v1.vitrine.v1`, de type `helm.sh/release.v1`, label `status=deployed`.
>
> **Vérification** : `kubectl -n demo get deployment vitrine-podinfo` affiche `READY 2/2` ; `helm list -n demo` montre `vitrine`, révision 1, `deployed`, chart `podinfo-6.15.0` ; `kubectl -n boutique exec outils -- curl -s http://vitrine-podinfo.demo:9898/api/info | grep message` affiche `"message": "greetings from podinfo v6.15.0",`.

#### Exercice 17.3 — Mettre à jour sans perdre de valeurs

**Point de départ** : exercice 17.2.

Mets à jour la release `vitrine` pour que podinfo affiche le message `Bonjour`, en conservant les 2 réplicas. Vérifie le message servi, puis affiche l'historique et les valeurs fournies de la révision courante.

> [!example]- Solution
> ```bash
> helm upgrade vitrine podinfo/podinfo --version 6.15.0 -n demo \
>   --reuse-values --set ui.message=Bonjour
> kubectl -n demo rollout status deployment vitrine-podinfo
> kubectl -n boutique exec outils -- curl -s http://vitrine-podinfo.demo:9898/api/info | grep message
> helm history vitrine -n demo
> helm get values vitrine -n demo
> ```
>
> Sans `--reuse-values`, la révision 2 ne contiendrait que `ui.message` et le Deployment reviendrait à 1 réplica (17.6.1). Le message passe par la variable d'environnement `PODINFO_UI_MESSAGE` du conteneur : le gabarit de pods change, d'où un rollout.
>
> **Vérification** : la commande `curl` affiche `"message": "Bonjour",` ; `helm get values vitrine -n demo` affiche `USER-SUPPLIED VALUES:` suivi de `replicaCount: 2` et `ui:` / `message: Bonjour` ; `kubectl -n demo get deployment vitrine-podinfo` reste à `2/2`.

#### Exercice 17.4 — Revenir à la révision 1

**Point de départ** : exercice 17.3.

Ramène la release `vitrine` à la configuration de sa révision 1. Quel est le numéro de la révision obtenue ? Affiche les valeurs fournies de la révision courante, puis celles de la révision 2.

> [!example]- Solution
> ```bash
> helm rollback vitrine 1 -n demo
> helm history vitrine -n demo
> helm get values vitrine -n demo
> helm get values vitrine -n demo --revision 2
> kubectl -n demo rollout status deployment vitrine-podinfo
> ```
>
> Le rollback crée la révision **3**, de description `Rollback to 1`, qui recopie chart, valeurs et manifestes de la révision 1 ; les révisions 1 et 2 passent en `superseded`. La révision 2 reste consultable tant que `--history-max` (10) n'est pas atteint.
>
> **Vérification** : `helm history` montre trois lignes, la 3 en `deployed` ; `helm get values vitrine -n demo` n'affiche plus que `replicaCount: 2` ; la commande `curl` de l'exercice 17.3 affiche de nouveau `"message": "greetings from podinfo v6.15.0",` ; `kubectl -n demo get secrets -l owner=helm` liste trois Secrets.

#### Exercice 17.5 — Rendu local et variante OCI

**Point de départ** : exercice 17.4.

Écris dans `~/cka/helm/vitrine-rendu.yaml` les manifestes que produirait la release `vitrine` (namespace `demo`, 2 réplicas), sans les pods de test et sans contacter le cluster. Installe ensuite, depuis le registre OCI `oci://ghcr.io/stefanprodan/charts/podinfo` en version 6.15.0, une release temporaire `vitrine-oci` dans `demo`, en attendant que ses pods soient prêts. Supprime-la ensuite.

> [!example]- Solution
> ```bash
> helm template vitrine podinfo/podinfo --version 6.15.0 -n demo \
>   --set replicaCount=2 --skip-tests > ~/cka/helm/vitrine-rendu.yaml
> grep -E '^kind|^  name|replicas' ~/cka/helm/vitrine-rendu.yaml
>
> helm install vitrine-oci oci://ghcr.io/stefanprodan/charts/podinfo --version 6.15.0 \
>   -n demo --wait --timeout 3m
> helm list -n demo
> helm uninstall vitrine-oci -n demo
> ```
>
> `helm template` ne crée aucune release : le fichier est du YAML ordinaire (un Service et un Deployment `vitrine-podinfo`). La version OCI ne demande pas de `helm repo add` : la référence `oci://` suffit, et Helm affiche l'empreinte du chart téléchargé. `--wait` seul choisit la stratégie `watcher`, qui attend le Deployment disponible avant de déclarer la release `deployed`.
>
> **Vérification** : `grep -c '^kind' ~/cka/helm/vitrine-rendu.yaml` affiche `2` ; après l'installation, `helm list -n demo` montrait deux releases ; après `helm uninstall` (`release "vitrine-oci" uninstalled`), `kubectl -n demo get deployments` ne liste plus que `vitrine-podinfo`, `kubectl -n demo get secrets -l name=vitrine-oci` répond `No resources found in demo namespace.`, et `helm list -n demo` ne montre que `vitrine`, toujours en révision 3.

#### Exercice 17.6 — Installer cert-manager

**Point de départ** : exercice 17.5.

Installe cert-manager v1.21.2 avec Helm, depuis son registre OCI officiel, sous le nom de release `cert-manager` dans le namespace `cert-manager`, CRD comprises. Vérifie ses composants, ses CRD et ses webhooks. Écris dans `~/cka/helm/crd-cert-manager.txt` la liste des CRD du groupe `cert-manager.io` exactement (une par ligne).

> [!example]- Solution
> ```bash
> helm install cert-manager oci://quay.io/jetstack/charts/cert-manager \
>   --version v1.21.2 \
>   --namespace cert-manager \
>   --create-namespace \
>   --set crds.enabled=true
> kubectl -n cert-manager get deploy,pods
> kubectl get crd | grep cert-manager.io
> kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations | grep cert-manager
> kubectl get crd -o jsonpath='{range .items[?(@.spec.group=="cert-manager.io")]}{.metadata.name}{"\n"}{end}' \
>   > ~/cka/helm/crd-cert-manager.txt
> cat ~/cka/helm/crd-cert-manager.txt
> ```
>
> C'est la commande de la documentation de cert-manager : chart OCI, version avec son `v`, `crds.enabled=true` pour que le chart installe les six CRD (sans cette valeur, il n'en installe aucune et les Issuers du chapitre 18 seraient refusés). La commande dure une demi-minute environ (27 secondes mesurées sur le lab, images comprises) : la stratégie `hookOnly` attend le Job `post-install` `cert-manager-startupapicheck`, qui teste l'API jusqu'à ce que le webhook réponde, puis disparaît (`hook-delete-policy: before-hook-creation,hook-succeeded`).
>
> Le filtre par `grep cert-manager.io` ramène six CRD, dont `challenges.acme.cert-manager.io` et `orders.acme.cert-manager.io`, qui appartiennent au groupe `acme.cert-manager.io`. Seul le filtre sur `.spec.group` répond exactement à la consigne.
>
> **Vérification** : trois Deployments `cert-manager`, `cert-manager-cainjector`, `cert-manager-webhook` à `1/1` ; `helm list -n cert-manager` montre la release en `deployed`, chart `cert-manager-v1.21.2` ; le fichier contient quatre lignes : `certificaterequests.cert-manager.io`, `certificates.cert-manager.io`, `clusterissuers.cert-manager.io`, `issuers.cert-manager.io` ; `helm get values cert-manager -n cert-manager` affiche `crds:` / `enabled: true`.

> [!warning] cert-manager 1.21 et Kubernetes 1.37
> La page *Supported releases* de cert-manager annonce, au 23 octobre 2026, la prise en charge de Kubernetes 1.33 à 1.36 pour la 1.21 ; aucune version publiée ne cite encore la 1.37 (la 1.22 est attendue vers novembre 2026). Le cours utilise la v1.21.2, dernière version stable publiée (11 septembre 2026). Les API dont cert-manager dépend (CRD `apiextensions.k8s.io/v1`, webhooks `admissionregistration.k8s.io/v1`, Leases, Secrets) sont stables et aucune n'est touchée par les retraits de la 1.37 ; en production, tu attendrais la version qui liste ta mineure.

#### Exercice 17.7 — La base Kustomize

**Point de départ** : exercice 17.6.

Crée dans `~/cka/kustomize/base/` une base qui décrit l'application `front` : un Deployment `front` (`nginx:1.30.6-alpine`, 3 réplicas, labels `app=front` et `tier=web`, port 80, sonde readiness HTTP `/` sur le port 80, requests 50m/32Mi, limits 200m/64Mi), qui monte la ConfigMap `front-html` en `/usr/share/nginx/html` ; un Service ClusterIP `front` (port 80) ; un générateur `front-html` dont la clé `index.html` contient `<h1>Boutique</h1><p>v1</p>`. Rends la base sans l'appliquer et observe le nom de la ConfigMap.

> [!example]- Solution
> ```bash
> mkdir -p ~/cka/kustomize/base && cd ~/cka/kustomize/base
> cat > index.html <<'EOF'
> <h1>Boutique</h1><p>v1</p>
> EOF
> ```
>
> `deployment.yaml` :
>
> ```yaml
> apiVersion: apps/v1
> kind: Deployment
> metadata:
>   name: front
>   labels:
>     app: front
>     tier: web
> spec:
>   replicas: 3
>   selector:
>     matchLabels:
>       app: front
>   template:
>     metadata:
>       labels:
>         app: front
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
>           name: front-html
> ```
>
> `service.yaml` :
>
> ```yaml
> apiVersion: v1
> kind: Service
> metadata:
>   name: front
>   labels:
>     app: front
>     tier: web
> spec:
>   selector:
>     app: front
>   ports:
>   - port: 80
>     targetPort: 80
> ```
>
> `kustomization.yaml` :
>
> ```yaml
> apiVersion: kustomize.config.k8s.io/v1beta1
> kind: Kustomization
> resources:
> - deployment.yaml
> - service.yaml
> configMapGenerator:
> - name: front-html
>   files:
>   - index.html
> ```
>
> ```bash
> kubectl kustomize ~/cka/kustomize/base | grep -n 'front-html'
> ```
>
> La base ne monte pas `front-conf` (le proxy vers `api` du [chapitre 6](06-configmaps-et-secrets.md)) : dans un namespace sans Service `api`, nginx refuserait de démarrer (`host not found in upstream`). Elle ne fixe pas de namespace : appliquée seule, elle irait dans le namespace du contexte, d'où le simple rendu.
>
> **Vérification** : le rendu contient `name: front-html-b97596tc55` deux fois, pour la ConfigMap et pour la référence du volume (le suffixe est identique si ton `index.html` l'est octet pour octet) ; `kubectl get ns boutique-recette` répond encore `NotFound`.

#### Exercice 17.8 — L'overlay `recette`

**Point de départ** : exercice 17.7.

Crée l'overlay `~/cka/kustomize/overlays/recette/` qui déploie la base dans le namespace `boutique-recette` (objet Namespace compris), avec 1 réplica, le label `env: recette` sur tous les objets et sur les pods (sans toucher aux sélecteurs), et une page `index.html` qui contient `<h1>Boutique</h1><p>v1-recette</p>`. Applique-la et vérifie la page servie.

> [!example]- Solution
> ```bash
> mkdir -p ~/cka/kustomize/overlays/recette && cd ~/cka/kustomize/overlays/recette
> cat > index.html <<'EOF'
> <h1>Boutique</h1><p>v1-recette</p>
> EOF
> ```
>
> `namespace.yaml` :
>
> ```yaml
> apiVersion: v1
> kind: Namespace
> metadata:
>   name: boutique-recette
> ```
>
> `kustomization.yaml` :
>
> ```yaml
> apiVersion: kustomize.config.k8s.io/v1beta1
> kind: Kustomization
> namespace: boutique-recette
> resources:
> - namespace.yaml
> - ../../base
> labels:
> - pairs:
>     env: recette
>   includeTemplates: true
> replicas:
> - name: front
>   count: 1
> configMapGenerator:
> - name: front-html
>   behavior: replace
>   files:
>   - index.html
> ```
>
> ```bash
> kubectl kustomize . | grep -E '^kind|^  name:|namespace:|replicas|env: recette'
> kubectl diff -k .               # échoue tant que le namespace n'existe pas (voir plus bas)
> kubectl apply -k .
> kubectl -n boutique-recette rollout status deployment front
> kubectl -n boutique exec outils -- curl -s http://front.boutique-recette
> ```
>
> `labels` sans `includeSelectors` laisse les sélecteurs à `app: front` ; `includeTemplates: true` pose `env: recette` sur les pods. Le générateur redéfinit `front-html` : `behavior: replace` est obligatoire, et le fichier doit se trouver dans l'overlay. `kubectl diff -k` échoue ici avec `Error from server (NotFound): namespaces "boutique-recette" not found` (code de retour 2) : il simule chaque objet côté serveur, et la simulation du Namespace ne le crée pas, si bien que les objets qu'il doit contenir sont refusés. Il ne devient utile qu'une fois le namespace en place ; relancé après l'`apply`, il ne montre rien (code 0). Si le `curl` lancé dans la foulée du `rollout status` est refusé (`command terminated with exit code 7`), relance-le une seconde plus tard : kube-proxy n'avait pas encore programmé le Service tout juste créé ([chapitre 10](10-services.md)).
>
> **Vérification** : `kubectl apply -k` crée `namespace/boutique-recette`, `configmap/front-html-2cbdmhthgc`, `service/front`, `deployment.apps/front` ; `kubectl -n boutique-recette get deploy front` affiche `1/1` ; `kubectl -n boutique-recette get pods -l env=recette` liste un pod ; `kubectl -n boutique-recette get deploy front -o jsonpath='{.spec.selector.matchLabels}'` affiche `{"app":"front"}` ; le `curl` renvoie `<h1>Boutique</h1><p>v1-recette</p>`.

#### Exercice 17.9 — Le hachage en action

**Point de départ** : exercice 17.8.

Remplace temporairement la page de l'overlay par `<h1>Boutique</h1><p>v2-recette</p>` et applique. Observe le rollout et les ConfigMaps du namespace. Reviens ensuite à `v1-recette`, réapplique, et supprime la ConfigMap devenue orpheline.

> [!example]- Solution
> ```bash
> cd ~/cka/kustomize/overlays/recette
> sed -i 's/v1-recette/v2-recette/' index.html
> kubectl apply -k .
> kubectl -n boutique-recette rollout status deployment front
> kubectl -n boutique-recette get configmaps
> kubectl -n boutique exec outils -- curl -s -m 5 http://front.boutique-recette
>
> sed -i 's/v2-recette/v1-recette/' index.html
> kubectl apply -k .
> kubectl -n boutique-recette rollout status deployment front
> kubectl -n boutique-recette delete configmap front-html-t55hf2hm4k
> ```
>
> Le nouveau contenu donne un nouveau nom (`front-html-t55hf2hm4k`), la référence du volume change, le gabarit de pods aussi : le Deployment lance un rollout et la page change dès que le nouveau pod est prêt, sans attendre la synchronisation des volumes par le kubelet. Revenir au contenu d'origine redonne le même nom qu'avant (`front-html-2cbdmhthgc`), car le hachage ne dépend que du nom et du contenu. `kubectl apply -k` ne supprime rien : la ConfigMap `v2` reste jusqu'à sa suppression manuelle. Si tes suffixes diffèrent, lis-les dans `kubectl -n boutique-recette get configmaps`. Le `-m 5` du `curl` borne l'attente : juste après la fin du rollout, une requête peut encore partir vers l'ancien pod, déjà arrêté, et rester sans réponse (sans `-m`, `curl` attend deux minutes puis sort en code 28, constaté sur le lab) ; relance-la une seconde plus tard.
>
> **Vérification** : pendant la première étape, deux ConfigMaps `front-html-*` coexistent et `curl` renvoie `v2-recette` ; à la fin, `kubectl -n boutique-recette get configmaps` ne liste que `front-html-2cbdmhthgc` (et `kube-root-ca.crt`), `curl` renvoie `<h1>Boutique</h1><p>v1-recette</p>`, et `kubectl -n boutique-recette rollout history deployment front` affiche les révisions 2 et 3 : le retour au gabarit d'origine a réutilisé le ReplicaSet de la révision 1, renuméroté 3 ([chapitre 5](05-deployments-et-controleurs.md)).

État laissé par ce chapitre : release Helm `vitrine` (révision 3, 2 réplicas) dans `demo`, cert-manager v1.21.2 dans `cert-manager`, overlay `recette` appliquée dans `boutique-recette`.

---
