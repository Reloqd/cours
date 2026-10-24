---
title: "CKA — Annexe C. Le lab : scripts, instantanés, pannes"
description: "Mode d'emploi du dossier lab/ : démarrage, restauration des instantanés I0 à I4, contenu de chaque état, pannes des chapitres 22 et 23, examen blanc et dépannage du lab lui-même."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## Annexe C. Le lab : scripts, instantanés, pannes

Le cours s'appuie sur un seul cluster minikube, le profil `cka`, que tu fais évoluer de chapitre en chapitre. Ce fil rouge a un défaut : une erreur au chapitre 8 peut te suivre jusqu'au chapitre 18, et tu voudras parfois attaquer le chapitre 22 sans avoir refait les vingt et un premiers. Le dossier `lab/` règle ces deux problèmes. Il reconstruit sur demande l'état exact laissé par les exercices de n'importe quel chapitre, il injecte les pannes des chapitres de dépannage et vérifie tes réparations, et il prépare puis corrige l'examen blanc de l'[annexe B](annexe-b-examen-blanc.md). Cette annexe décrit chaque script, le contenu de chaque instantané, les durées réellement mesurées, et la façon de dépanner le lab quand c'est lui qui flanche.

Tout ce qui suit a été exécuté sur minikube v1.39.0, Kubernetes v1.37.0, kubectl 1.37.1 et Helm 4.3.0, le 23 octobre 2026, sur un poste Linux à 8 CPU et 30 Gio de RAM.

### C.1 Le dossier `lab/`

```
lab/
├── README.md                   résumé de cette annexe
├── demarrer.sh                 prérequis, démarrage du profil, attente des nœuds   → I0
├── restaurer.sh                supprime, recrée, rejoue les états                  → I0 … I4
├── lib/commun.sh               fonctions partagées (non exécutable)
├── etats/
│   ├── 03-kubectl-efficace/        manifestes YAML + appliquer.sh
│   ├── 04-pods/
│   ├── 05-deployments-et-controleurs/
│   ├── 06-configmaps-et-secrets/
│   ├── 07-autoscaling/
│   ├── 08-ordonnancement-et-admission/                                         ← I1
│   ├── 10-services/
│   ├── 11-coredns/
│   ├── 12-ingress/
│   ├── 13-gateway-api/
│   ├── 14-network-policies/                                                    ← I2
│   ├── 15-stockage/                                                            ← I3
│   ├── 16-rbac-et-authentification/
│   ├── 17-helm-et-kustomize/
│   └── 18-interfaces-crd-et-operateurs/                                        ← I4
├── pannes.sh                   liste | casser NN | verifier NN
└── examen-blanc/
    ├── preparer.sh             préparation générale, puis « 14 » et « 15 » à la demande
    └── corriger.sh             note par tâche et total sur 100
```

Les scripts sont écrits en Bash strict (`set -euo pipefail`) et n'utilisent que `docker`, `minikube`, `kubectl`, `helm`, `openssl` et `curl`, plus les outils de base du système. Ils se lancent depuis n'importe quel dossier : `lab/restaurer.sh I4` depuis le dossier du cours, ou le chemin complet depuis ailleurs.

Ils visent **toujours** le contexte kubeconfig du profil (`kubectl --context cka`, `helm --kube-context cka`), quel que soit ton contexte courant. Tu peux donc rester sur `alice@cka` ou sur `boutique` sans risque de lancer une restauration avec les droits d'alice. Trois variables d'environnement en règlent le comportement :

| Variable | Défaut | Effet |
|---|---|---|
| `CKA_PROFIL` | `cka` | Profil minikube, donc nom du contexte et préfixe des nœuds (`cka`, `cka-m02`, `cka-m03`). |
| `CKA_DOSSIER` | `~/cka` | Ton dossier de travail. Les scripts y recréent ce dont les exercices suivants ont besoin (voir C.4) et y lisent les réponses de l'examen blanc (`examen/`). |
| `CKA_FORCER` | `0` | `1` : démarrer malgré une limite inotify trop basse. À éviter, voir C.7.1. |

> [!warning]
> Un `appliquer.sh` remet les objets de **son** chapitre dans l'état de fin de chapitre, sans rien savoir des chapitres suivants. Rejouer `etats/05-…/appliquer.sh` sur un cluster en I4 ferait revenir `front` et `api` à leur définition du chapitre 5 (sans ConfigMaps, sans PriorityClass). Les états se rejouent dans l'ordre, ce que fait `restaurer.sh`. Pour revenir en arrière, restaure l'instantané voulu.

### C.2 Démarrer : `lab/demarrer.sh`

Le script vérifie d'abord le poste : présence des six outils (`docker`, `minikube`, `kubectl`, `helm`, `openssl`, `curl`), Docker utilisable sans `sudo`, versions de minikube (v1.39.0), de kubectl (1.37) et de Helm (4.x), mémoire disponible (10 Gio au moins, 12 conseillés), et surtout la **limite inotify** (`fs.inotify.max_user_instances` ≥ 512 et `fs.inotify.max_user_watches` ≥ 524288). Une version différente ne produit qu'un avertissement ; une limite inotify trop basse arrête le script, sauf avec `CKA_FORCER=1`.

Il lance ensuite la commande du chapitre 1.6, puis attend que les trois nœuds soient `Ready`, que le DaemonSet `calico-node` soit déployé partout et que CoreDNS réponde :

```bash
minikube start -p cka --driver=docker --container-runtime=containerd \
  --kubernetes-version=v1.37.0 --nodes=3 --cni=calico --cpus=2 --memory=3072
kubectl --context cka wait --for=condition=Ready node --all --timeout=10m
```

Mesuré avec le cache de minikube déjà rempli (image de nœud et préchargement de Kubernetes téléchargés une fois pour toutes) : entre **57 s et 3 min 51 s** selon les essais, l'écart venant du téléchargement des images Calico par chaque nœud. Le tout premier démarrage d'un poste ajoute le téléchargement de l'image de nœud (≈ 510 Mio) et du préchargement (≈ 350 Mio).

```
 OK cluster cka prêt en 3 min 51 s (instantané I0)
NAME      STATUS   ROLES           AGE     VERSION   INTERNAL-IP    …
cka       Ready    control-plane   3m38s   v1.37.0   192.168.49.2   …
cka-m02   Ready    <none>          3m23s   v1.37.0   192.168.49.3   …
cka-m03   Ready    <none>          3m11s   v1.37.0   192.168.49.4   …
```

Si le profil existe déjà, `demarrer.sh` le redémarre sans rien effacer : c'est un `minikube start` ordinaire. Pour repartir de zéro, c'est `restaurer.sh I0`.

### C.3 Restaurer un instantané : `lab/restaurer.sh`

```bash
lab/restaurer.sh I2          # demande confirmation
lab/restaurer.sh I4 --oui    # sans confirmation
```

Sous minikube, un instantané n'est pas une image de machine virtuelle qu'on recharge : c'est un état **reconstruit**. Le script supprime le profil (deux fois si minikube laisse son réseau Docker derrière lui, voir C.7.4), relance `demarrer.sh`, puis exécute dans l'ordre chaque `etats/NN-*/appliquer.sh` jusqu'au dernier chapitre de l'instantané. Chaque étape affiche sa durée. Les `appliquer.sh` attendent explicitement la fin de ce qu'ils lancent (`kubectl rollout status`, `kubectl wait`, conditions `Programmed` ou `Ready`) : quand le script rend la main, l'état est utilisable.

| Instantané | Fin du chapitre | États rejoués | Durée mesurée |
|---|---|---|---|
| I0 | 1 | aucun | 0 min 57 s à 3 min 51 s |
| I1 | 8 | 03 à 08 | 10 min 27 s |
| I2 | 14 | 03 à 14 | 7 min 23 s |
| I3 | 15 | 03 à 15 | 10 min 09 s |
| I4 | 18 | 03 à 18 | 14 min 23 s |

Chaque restauration part de nœuds neufs, qui retéléchargent toutes les images (Calico, nginx, busybox, netshoot, agnhost, redis, Envoy, cert-manager, podinfo…) : les durées dépendent surtout de ton débit, et le démarrage seul a varié de 57 s à 3 min 51 s d'un essai à l'autre. Compte un quart d'heure pour I4 (14 min 23 s mesurées), davantage sur une connexion lente. Les étapes les plus longues sont le chapitre 15 (addons `volumesnapshots` et `csi-hostpath-driver`, agrandissement et instantané du volume de redis : 2 à 5 minutes), le chapitre 8 (trois rollouts successifs) et le chapitre 12 (minikube attend que le contrôleur d'Ingress réponde).

> [!tip]
> Un `minikube -p cka stop` suivi d'un `minikube -p cka start` conserve tout (objets, addons, données) en deux minutes environ (arrêt en 1 min 20 s à 1 min 26 s, démarrage en 29 s, mesurés sur l'état I4). Garde `restaurer.sh` pour repartir d'un état propre ou sauter des chapitres.

### C.4 Contenu des instantanés

Chaque ligne du tableau suivant correspond à un dossier de `lab/etats/`. Les manifestes y portent exactement les noms, labels, images et valeurs des solutions des exercices ; ouvre-les pour comparer ton travail.

| État | Ajouté ou modifié | Instantané |
|---|---|---|
| `03` | namespace `boutique` ; contexte kubeconfig `boutique` (cluster `cka`, user `cka`, namespace `boutique`), non courant | |
| `04` | pod `outils` (netshoot v0.16, `sleep infinity`, `app=outils tier=outils`), redimensionné en place à requests cpu 100m / limits cpu 300m | |
| `05` | Deployment `front` (`nginx:1.30.6-alpine`, 3 réplicas, maxSurge 1, maxUnavailable 0, historique de rollout de l'exercice 5.3 : révisions 3 et 4) ; Deployment `api` (agnhost 2.66.1 `netexec --http-port=8080`, 2 réplicas, port `http`) ; Services `api` et `front` en ClusterIP ; DaemonSet `agent-noeud` ; CronJob `rapport` (`*/5 * * * *`, Europe/Paris) ; PodDisruptionBudget `front` (minAvailable 2) | |
| `06` | ConfigMaps `front-html` (page v1), `front-conf` (`/api/` relayé vers `api:8080`), `api-config` ; Secret `api-secret` (`DB_PASSWORD`) ; montages dans `front`, `envFrom` et `secretKeyRef` dans `api` | |
| `07` | addon `metrics-server` ; HPA `api` (autoscaling/v2, 2 à 6, CPU 50 %, descente stabilisée 60 s) | |
| `08` | labels `topology.kubernetes.io/zone` (`zone-a` sur `cka`, `zone-b` sur les workers) et `disque=ssd` sur `cka-m03` ; topologySpreadConstraint de `front` ; anti-affinité préférée et PriorityClass `boutique-critique` (100000) pour `api` ; toleration `Exists` d'`agent-noeud` ; ResourceQuota `boutique-quota` ; LimitRange `boutique-limites` ; Pod Security Admission `enforce=baseline`, `warn` et `audit` `restricted`. Aucune taint | **I1** |
| `10` | Service `api` (port nommé `http`) ; `front` en NodePort 30080 ; addon `metallb` et sa plage `.100` à `.120` du réseau des nœuds ; Services `front-lb` (LoadBalancer), `api-pods` (headless), `meteo` (ExternalName `example.com`) | |
| `11` | CoreDNS à 2 réplicas ; `boutique.example` et `api.boutique.example` ajoutés au bloc `hosts` du Corefile, vers l'IP du nœud `cka` | |
| `12` | addon `ingress` ; Secret TLS `boutique-tls` (certificat autosigné pour `boutique.example` et `*.boutique.example`) ; Ingress `boutique` (deux hôtes, TLS) | |
| `13` | Envoy Gateway v1.9.2 (release Helm `eg`) ; GatewayClass `eg` ; `front-v2` (page v2) et son Service ; Gateway `boutique-gw` (listeners `http` et `https`) ; HTTPRoutes `front` (90/10, en-tête `X-Version: v2`), `api` (`/api` réécrit en `/`) et `redirection-https` | |
| `14` | huit NetworkPolicies : `refus-par-defaut`, `autorise-dns`, `web-entree`, `web-sortie`, `api-entree`, `api-sortie`, `redis-entree`, `outils-sortie` | **I2** |
| `15` | StorageClass `manuel`, PV local `archives` sur `cka-m02` et PVC `archives` (liée par `volumeName`) ; addons `volumesnapshots` et `csi-hostpath-driver` ; StorageClass `rapide` ; Service headless et StatefulSet `redis` (clé `commandes` = 42, volume `data-redis-0` porté à 2Gi) ; VolumeSnapshot `redis-instantane` | **I3** |
| `16` | utilisateur `alice` (CSR approuvée, contexte `alice@cka`) ; Role `developpeur` et RoleBinding `developpeurs` ; ClusterRole `lecteur-noeuds` et sa liaison ; ServiceAccount, Role et RoleBinding `deployeur` | |
| `17` | release Helm `vitrine` (podinfo 6.15.0, namespace `demo`, révision 3 après rollback) ; cert-manager v1.21.2 (release `cert-manager`) ; overlay Kustomize `recette` dans `boutique-recette` | |
| `18` | RuntimeClass `runc-standard` ; CRD `sauvegardes.boutique.example` et ressource `redis-quotidienne` (avec son statut) ; ClusterRole agrégée `sauvegardes-lecture` ; ClusterIssuer `autosigne` ; Certificate `boutique-gw` (révision 2, après l'exercice de réconciliation) ; listener `https` sur `boutique-gw-tls` | **I4** |

Quelques éléments vivent hors du cluster ou demandent un réglage que les exercices ne montrent pas. Les scripts s'en chargent pour que les chapitres suivants fonctionnent :

| Élément | Où | Pourquoi |
|---|---|---|
| `boutique-tls.key`, `boutique-tls.crt` | `~/cka/boutique/` | Les exercices des chapitres 13 et 14 s'en servent comme `--cacert`. Si les fichiers existent, le Secret est recréé à partir d'eux ; sinon ils sont générés. |
| `alice.key`, `alice.csr`, `alice.crt` | `~/cka/rbac/` | Un cluster recréé a une nouvelle autorité : le certificat d'alice est réémis (la clé est gardée), et les identifiants `alice` de ton kubeconfig sont mis à jour. |
| `kustomize/base/`, `kustomize/overlays/recette/` | `~/cka/kustomize/` | Copiés seulement si le dossier n'existe pas : ton propre travail n'est jamais écrasé. |
| dépôt Helm `podinfo` | ta configuration Helm | `helm repo add podinfo https://stefanprodan.github.io/podinfo`, comme au chapitre 17.3.1. |
| `/mnt/archives/journal.txt` | nœud `cka-m02` | Trace de l'exercice 15.2. |
| plage MetalLB | profil minikube | Voir C.7.6 : sans elle, MetalLB perd sa configuration à chaque `minikube start`. |
| `nodeSelector` de `csi-hostpath-resizer` | `kube-system` | Voir C.7.7 : sans lui, l'agrandissement d'un volume échoue deux fois sur trois. |

### C.5 Les pannes : `lab/pannes.sh`

Les chapitres 22 et 23 s'entraînent sur dix-neuf pannes, toutes à injecter depuis l'instantané **I4**. Le script ne te dit que le symptôme : à toi de mener l'enquête, comme à l'examen. N'ouvre pas `pannes.sh` avant d'avoir trouvé, il contient les causes.

```bash
lab/pannes.sh liste          # numéro, chapitre, symptôme
lab/pannes.sh casser 04      # injecte la panne 04
lab/pannes.sh verifier 04    # contrôle la réparation
```

| N° | Chapitre | Symptôme |
|---|---|---|
| 01 | 22 | Les nouveaux pods de `front` ne démarrent pas et le déploiement n'avance plus. |
| 02 | 22 | Un pod de `api` redémarre en boucle. |
| 03 | 22 | Après un redémarrage de `api`, les nouveaux pods ne démarrent pas. |
| 04 | 22 | `/api/` de `front` répond 504 au bout d'une minute ; `api.boutique.example` répond 503. |
| 05 | 22 | Le Service `front` (ClusterIP, NodePort 30080) ne répond plus, alors que les pods de `front` sont sains. |
| 06 | 22 | Les résolutions DNS échouent depuis les pods de `boutique`. |
| 07 | 22 | La mise à jour de `front-v2` n'avance plus : aucun nouveau pod n'apparaît. |
| 08 | 22 | `redis-0` reste Pending après un redémarrage. |
| 09 | 22 | Les pods de `api` tournent, mais le Service `api` n'a plus aucun backend. |
| 10 | 22 | `redis-0` redémarre en boucle. |
| 11 | 23 | Les nouveaux pods restent Pending, sans aucun événement. |
| 12 | 23 | Un `kubectl scale` ne crée plus aucun pod. |
| 13 | 23 | Le nœud `cka-m03` est NotReady. |
| 14 | 23 | Le nœud `cka-m02` est NotReady. |
| 15 | 23 | kubectl n'obtient plus de réponse de l'API. |
| 16 | 23 | Plus aucune résolution DNS ne fonctionne dans le cluster. |
| 17 | 23 | Les Services existants répondent, mais un Service créé maintenant reste injoignable. |
| 18 | 23 | Les pods ont quitté `cka-m02` et plus rien n'y est planifié. |
| 19 | 23 | kubectl échoue avec « connection refused ». |

`verifier` ne se contente pas de constater que le symptôme a disparu : il contrôle que la réparation est **propre**. Il vérifie la bonne image, le bon sélecteur, le bon chemin ou le bon port, la valeur d'origine d'un paramètre, l'absence de fichier en trop dans `/etc/kubernetes/manifests`, qu'un nœud réparé le reste après un redémarrage, ou qu'un rollout est vraiment terminé. Chaque contrôle s'affiche avec `OK` ou `NON`, et le code de retour vaut 0 seulement si tout est bon :

```
==> vérification de la panne 10
 OK redis : limits memory 256Mi, requests memory 64Mi
 !! redis-0 à la dernière révision du StatefulSet : NON
 OK redis-0 prêt
 OK redis a gardé la clé commandes (42)
ERREUR panne 10 : 1 contrôle(s) en échec
```

Traite les pannes une à une : casse, enquête, répare par la voie normale (kubectl, manifeste, systemctl), vérifie, puis passe à la suivante. Une panne réparée proprement ramène le cluster à I4. Si tu t'es perdu, `restaurer.sh I4` repart de zéro. Pour les pannes du control plane, le script garde une copie d'origine du fichier modifié dans `/root/lab-pannes/` du nœud concerné, hors du dossier des manifestes ; ne t'en sers qu'en dernier recours, ce n'est pas l'exercice.

> [!warning]
> La panne 19 modifie **ton** kubeconfig. Tant qu'elle n'est pas réparée, les autres commandes de `pannes.sh`, de l'examen blanc et de `restaurer.sh` échouent aussi, puisqu'elles passent par le contexte `cka`.

### C.6 L'examen blanc : `lab/examen-blanc/`

L'[annexe B](annexe-b-examen-blanc.md) donne les dix-sept énoncés et leurs solutions. Le déroulé est le suivant :

```
lab/restaurer.sh I4 --oui        # cluster propre (facultatif si tu es déjà en I4)
lab/examen-blanc/preparer.sh     # ≈ 13 s à 1 min
   … 2 heures de tâches, réponses écrites dans ~/cka/examen/ …
lab/examen-blanc/preparer.sh 14  # au moment d'aborder la tâche 14
lab/examen-blanc/preparer.sh 15  # au moment d'aborder la tâche 15
lab/examen-blanc/corriger.sh     # note par tâche, total sur 100, seuil 66
lab/restaurer.sh I4 --oui        # pour repartir d'un cluster propre
```

`preparer.sh` commence par effacer un éventuel passage précédent : namespaces `examen-*`, StorageClass `lente` et ses volumes, taint posée sur le nœud `disque=ssd`, sauvegarde etcd, fichiers `t01.txt` et `t17.txt`, et remise en état du kubelet de `cka-m02` et du scheduler si les tâches 14 et 15 n'avaient pas été réparées. Il crée ensuite tout ce que les énoncés supposent existant : les dix namespaces `examen-*`, les Deployments `calcul`, `catalogue`, `catalogue-v1`, `catalogue-v2` et `docs` avec leurs Services (dont le Service `catalogue` au sélecteur fautif), les pods `bdd`, `front` et `autre`, le Gateway `examen-gw`, la ConfigMap `parametres` et le Secret `identifiants`, la taint `dedie=donnees:NoSchedule` sur `cka-m03`, et `etcdctl` et `etcdutl` 3.7.0 dans `/usr/local/bin` du nœud `cka` (copiés depuis l'image d'etcd, sans accès Internet), comme sur un nœud d'examen.

Les pannes des tâches 14 et 15 ne sont injectées qu'à la demande, parce qu'elles gênent tout le reste : un nœud en moins pour la première, plus aucun pod planifié pour la seconde.

> [!danger] La tâche 14 a un prix
> Un nœud NotReady reçoit la taint `node.kubernetes.io/unreachable:NoExecute`. Au bout de 300 secondes, ses pods sont évincés, et un pod **sans contrôleur** (`config-pod`, `journal`, `stockeur`…) n'est jamais recréé : la tâche correspondante tombe à zéro. `preparer.sh 14` liste les pods d'examen présents sur `cka-m02` avant de casser le nœud. Répare-le en moins de cinq minutes, ou garde la tâche 14 pour la fin.

`corriger.sh` note chaque tâche par des contrôles objectifs : contenu exact des fichiers de réponse, champs des objets, droits réels (`kubectl auth can-i`), trafic réel (requêtes vers le NodePort, l'Ingress et le Gateway, connexions entre pods de `examen-net`), état des pods et des nœuds, validité de la sauvegarde etcd (`etcdutl snapshot status`). Chaque critère rapporte une partie des points de la tâche ; les tâches 14 et 15 valent zéro si leur panne n'a pas été injectée. Extrait :

```
Tâche 9 (7 pts) — HTTPRoute catalogue 80/20 (examen-gw)
   [+1] attachée au Gateway examen-gw
   [+1] hôte catalogue.example
   [+2] catalogue-v1 poids 80, catalogue-v2 poids 20
   [+1] route Accepted et ResolvedRefs
   [+2] partage observé sur 100 requêtes : v1=79 v2=21 (attendu ≈ 80/20)
   => 7/7
…
 OK note : 100 / 100 (seuil 66) — réussi
==> pour repartir d'un cluster propre : lab/restaurer.sh I4
```

Le correcteur a été validé dans les deux sens : un passage complet obtient 100, une préparation suivie d'aucune réponse obtient 0. Tu peux le relancer autant de fois que tu veux pendant l'examen, il ne modifie rien (il crée seulement un pod de test éphémère pour la tâche 15).

### C.7 Dépanner le lab lui-même

#### C.7.1 La limite inotify

C'est la panne la plus fréquente et la plus trompeuse du lab. Chaque nœud minikube est un conteneur Docker qui tourne en root sans espace de noms utilisateur : les instances inotify de ses processus (containerd et un `containerd-shim` par conteneur, le kubelet, kube-proxy, systemd, l'API server…) comptent dans la même limite que les processus root de ton poste. Avec la valeur par défaut d'Ubuntu (`max_user_instances = 128`), l'état I4 complet en consomme environ 120 à lui seul : la limite est atteinte.

Les symptômes ne ressemblent pas à une panne de limite :

| Ce que tu vois | Où |
|---|---|
| `Failed to allocate directory watch: Too many open files` | sortie de `systemctl` dans un nœud |
| `"command failed" err="failed complete: fsnotify watcher init: too many open files"` | journal d'un pod kube-proxy relancé, qui reste en `Error` |
| `"Failed to start cAdvisor" err="inotify_init: too many open files"`, nœud NotReady | `journalctl -u kubelet` après un redémarrage du kubelet |
| `driver name hostpath.csi.k8s.io not found in the list of registered CSI drivers`, pod bloqué en `Terminating` | événements d'un pod qui utilise un volume CSI |
| un conteneur tué par manque de mémoire affiché `Error` (code 137) au lieu de `OOMKilled` | `kubectl describe pod` ; containerd journalise `failed to watch oom events … too many open files` |
| `minikube node add` en échec (`Failed to create control group inotify object`) | sortie de minikube |

Le remède demande `sudo`, une fois pour toutes :

```bash
sudo sysctl fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288
printf 'fs.inotify.max_user_instances = 512\nfs.inotify.max_user_watches = 524288\n' \
  | sudo tee /etc/sysctl.d/99-inotify.conf
```

Si tu ne peux pas modifier la limite tout de suite, `minikube -p cka stop` puis `minikube -p cka start` remet généralement le cluster d'aplomb : au redémarrage, le kubelet et kube-proxy obtiennent leurs instances avant les conteneurs applicatifs. Ce n'est qu'un palliatif, que la prochaine panne de nœud remettra en cause.

#### C.7.2 Un démarrage lent

`minikube start` rend la main alors que le dernier nœud est encore `NotReady` : Calico n'est pas préchargé et chaque nœud télécharge ses trois images (≈ 260 Mo). C'est pourquoi `demarrer.sh` attend explicitement les nœuds, puis `calico-node`. Sur une connexion lente, cette attente dépasse cinq minutes ; le délai du script est de dix. Si un nœud reste `NotReady` au-delà, regarde ses pods `calico-node` (`kubectl -n kube-system get pods -o wide -l k8s-app=calico-node`) : un `Init` bloqué signale un téléchargement qui traîne, ou la limite inotify.

Après un `minikube -p cka start`, compte encore une minute avant que tout réponde : `kubectl top` renvoie `Metrics API not available` pendant environ 60 secondes, les pods qui utilisent un volume CSI restent `Unknown` environ 70 secondes, le temps que le plugin se réenregistre, et MetalLB réannonce ses adresses en une trentaine de secondes.

#### C.7.3 `minikube addons list` ment

En multi-nœud, `minikube addons list` affiche `disabled` pour des addons qui tournent : `storage-provisioner` et `default-storageclass` juste après la création, puis **tous** les addons après un `stop`/`start`. Ne te fie qu'aux objets : `kubectl -n ingress-nginx get deploy`, `kubectl -n metallb-system get pods`, `kubectl -n kube-system get deploy metrics-server`. Les scripts du lab font de même.

#### C.7.4 `minikube delete` à relancer

`minikube -p cka delete` supprime les conteneurs et les volumes, mais laisse souvent le réseau Docker `cka` : minikube tente de le supprimer alors que les conteneurs des workers y sont encore attachés. Un second `minikube -p cka delete` (« Le profil "cka" n'existe pas, tentative de suppression quand même ») le retire. `restaurer.sh` le fait pour toi, et `demarrer.sh` supprime un réseau `cka` orphelin avant de démarrer.

```bash
docker network ls --filter name=cka      # vide quand tout est propre
```

#### C.7.5 La mémoire

Chaque nœud reçoit 3 Gio (`--memory=3072`), soit 9 Gio pour le cluster. Le control plane est le plus chargé : en I4, le nœud `cka` porte l'API server, etcd, le contrôleur d'Ingress et une partie des pods du fil rouge ; mesuré par `docker stats`, il occupe 2,0 Gio sur 3 (67 %), les deux workers environ 0,7 Gio chacun. `docker stats --no-stream` montre l'occupation réelle de chaque nœud ; `kubectl top nodes` affiche des pourcentages calculés sur la mémoire **de ton poste**, que chaque nœud annonce comme sa capacité, et n'aide donc pas ici. Si ton poste manque de mémoire, ferme les applications lourdes plutôt que de réduire `--memory` : un essai à 2,2 Gio par nœud plaçait déjà le control plane à 84 % de sa limite, avec moins d'addons que l'état I4.

#### C.7.6 MetalLB perd sa plage après un redémarrage

À chaque `minikube start`, minikube réapplique les manifestes de ses addons, dont la ConfigMap `metallb-system/config`, avec la plage enregistrée **dans le profil**. L'exercice 10.4 enregistre la plage dans le profil (`minikube addons configure metallb`) avant de l'appliquer par `kubectl apply`. Si l'on saute la première étape, la plage posée seulement par `kubectl apply` est écrasée au `start` suivant par une plage vide (`addresses: - -`) : le contrôleur journalise `not processing, still waiting for config`, et `front-lb` comme le Gateway gardent leur EXTERNAL-IP à l'affichage mais ne répondent plus. L'état `10` fait comme l'exercice : il enregistre la plage dans le profil, en plus de la ConfigMap. `minikube addons configure metallb` pose deux questions ; dans un terminal, réponds-y simplement. Par un tube, il faut une pause entre les deux réponses, faute de quoi minikube avale les deux lignes à la première question et n'enregistre rien :

```bash
{ echo 192.168.49.100; sleep 2; echo 192.168.49.120; } | minikube -p cka addons configure metallb
```

#### C.7.7 L'agrandissement d'un volume CSI reste bloqué

L'addon `csi-hostpath-driver` lance son `csi-resizer` dans un StatefulSet à un seul pod, qui ne parle qu'au plugin de **son** nœud. Si ce pod ne tourne pas sur le nœud qui porte le volume, l'agrandissement échoue en boucle avec `VolumeResizeFailed … rpc error: code = NotFound desc = volume id … does not exist in the volumes list`. L'état `15` place le resizer sur le nœud de `redis-0` avant d'agrandir `data-redis-0` ; fais de même si tu agrandis un autre volume :

```bash
kubectl -n kube-system patch statefulset csi-hostpath-resizer \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"cka-m03"}}}}}'
```

Le réglage survit à un `minikube start` : minikube réapplique l'addon avec `kubectl apply`, qui ne retire pas un champ qu'il n'a jamais posé.

#### C.7.8 Le réseau 192.168.49.0/24 est déjà pris

minikube choisit pour le profil le premier réseau privé libre à partir de `192.168.49.0/24`. Si un autre profil minikube ou un réseau Docker l'occupe déjà, le cluster naît ailleurs (par exemple en `192.168.58.0/24`) et toutes les adresses du cours changent : nœuds, plage MetalLB, entrées du Corefile. Les scripts du lab ne codent aucune adresse en dur : ils lisent `minikube -p cka ip` et en déduisent le réseau des nœuds, la plage MetalLB (`.100` à `.120`), l'entrée `hosts` de CoreDNS et le bloc `ipBlock` de `web-entree`. Dans tes propres commandes, fais de même, et remplace mentalement `192.168.49` par ton réseau dans les sorties du cours.

```bash
minikube -p cka ip                                       # fait foi
docker network inspect cka --format '{{json .IPAM.Config}}'
```

> [!summary] À retenir
> - `lab/restaurer.sh <I0…I4> --oui` reconstruit un instantané depuis rien en 1 à 15 minutes ; `minikube -p cka stop` puis `start` garde l'état courant.
> - Les états de `lab/etats/` reproduisent les solutions des exercices et se rejouent dans l'ordre ; ils recréent aussi les fichiers de `~/cka/` dont les chapitres suivants ont besoin.
> - `lab/pannes.sh casser NN` puis `verifier NN`, toujours depuis I4 ; `verifier` exige une réparation propre, pas seulement la disparition du symptôme.
> - L'examen blanc se prépare depuis I4 ; les pannes des tâches 14 et 15 s'injectent à la demande ; un nœud NotReady plus de cinq minutes fait perdre les pods sans contrôleur.
> - La limite inotify de l'hôte explique la plupart des comportements étranges du lab : relève-la avant tout.
> - Après un `minikube start`, compte une minute de convalescence (métriques, CSI, MetalLB) ; `minikube addons list` n'est pas fiable en multi-nœud.
