---
title: "CKA — 15. Volumes, PV, PVC et StorageClasses"
description: "Volumes éphémères et persistants, règles de liaison PV/PVC, modes d'accès, politiques de récupération, StorageClasses et provisionnement dynamique, CSI, expansion, snapshots et StatefulSet, pratiqués sur le lab minikube."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 15. Volumes, PV, PVC et StorageClasses

Ce chapitre traite de tout ce qui permet à un pod de garder des données au-delà de la vie de ses conteneurs : les volumes déclarés dans le pod, les PersistentVolumes (PV) et les PersistentVolumeClaims (PVC) qui découplent le stockage de son usage, les StorageClasses qui automatisent sa création, l'architecture CSI qui relie Kubernetes aux systèmes de stockage, l'agrandissement, les instantanés et le stockage des StatefulSets. Le domaine *Storage* ne pèse que 10 % de l'examen, mais ses tâches sont courtes, déterministes et presque toujours les mêmes : créer une StorageClass, un PV, une PVC, un pod qui la monte, et comprendre pourquoi une PVC reste `Pending`. Ce sont des points faciles à prendre, à condition de connaître par cœur les règles de liaison, car un seul champ faux suffit à laisser la PVC en attente sans message d'erreur explicite. Le chapitre couvre les trois compétences du domaine, *Implement storage classes and dynamic volume provisioning*, *Configure volume types, access modes and reclaim policies* et *Manage persistent volumes and persistent volume claims*, ainsi que la partie stockage de *Understand extension interfaces (CNI, CSI, CRI, etc.)*, que le [chapitre 18](18-interfaces-crd-et-operateurs.md) reprend du point de vue des interfaces.

### 15.1 Du volume éphémère au volume persistant

Le système de fichiers d'un conteneur vient de son image, augmenté d'une couche inscriptible qui disparaît avec le conteneur. Quand le kubelet redémarre un conteneur après un crash, il repart de l'image : tout ce que le processus avait écrit est perdu. Un **volume** résout ce problème et un second, le partage de fichiers entre conteneurs d'un même pod. C'est un répertoire, déclaré une fois dans `spec.volumes`, puis monté par chaque conteneur qui en a besoin à l'endroit de son choix (`volumeMounts`). Sa durée de vie et son contenu dépendent de son type.

```
Ce que voit un conteneur :
══════════════════════════

  ┌────────────────────── pod ──────────────────────┐
  │  conteneur A                  conteneur B       │
  │  /         ← image + couche   /                 │
  │  /cache ───────┐  écrivable   /partage ───┐     │
  │  /data ──────┐ │                          │     │
  └──────────────┼─┼──────────────────────────┼─────┘
                 │ └── volume "cache" (emptyDir) ◀┘   vit et meurt avec le pod
                 │
                 └──── volume "data" (persistentVolumeClaim)
                               │
                       PVC ── PV ── stockage réel   survit au pod
```

Les types de volumes se rangent en trois familles. Les **volumes éphémères** naissent et meurent avec le pod : `emptyDir`, les volumes qui projettent des données de l'API (`configMap`, `secret`, `downwardAPI`, `projected`, traités au [chapitre 6](06-configmaps-et-secrets.md)), les volumes éphémères génériques et les volumes CSI en ligne. Les **volumes du nœud** (`hostPath`) exposent un répertoire de la machine. Les **volumes persistants** passent par une PVC et vivent indépendamment du pod.

| Type | Durée de vie | Usage typique | À savoir pour la 1.37 |
|---|---|---|---|
| `emptyDir` | celle du pod sur son nœud | espace de travail, partage entre conteneurs | survit au redémarrage d'un conteneur, pas à la suppression du pod |
| `hostPath` | celle du nœud | agents système (journaux, socket du runtime) | interdit par le profil `baseline` de Pod Security |
| `configMap`, `secret`, `downwardAPI`, `projected` | celle du pod, contenu tiré de l'API | configuration | [chapitre 6](06-configmaps-et-secrets.md) |
| `persistentVolumeClaim` | celle du PV | données durables | l'objet de ce chapitre |
| `ephemeral` (volume éphémère générique) | celle du pod, à travers une PVC créée et supprimée avec lui | espace de travail provisionné par une StorageClass | GA depuis 1.23 ; PVC nommée `<pod>-<volume>` |
| `csi` (volume CSI en ligne) | celle du pod | pilotes qui le prévoient | GA depuis 1.25 |
| `image` | celle du pod | monter une image OCI en lecture seule | GA depuis 1.36 |
| `local`, `nfs`, `iscsi`, `fc` | celle du stockage | stockage existant | `local` ne s'utilise qu'à travers un PV |

Les anciens pilotes intégrés des fournisseurs de cloud (`awsElasticBlockStore`, `azureDisk`, `gcePersistentDisk`, `cinder`, `vsphereVolume`…) ont été retirés du code de Kubernetes : les champs existent encore dans l'API, mais les opérations sont redirigées vers le pilote CSI correspondant (la *migration CSI*). `cephfs` et `rbd` n'existent plus depuis 1.31, et le volume `gitRepo` n'est plus fourni depuis 1.36 : la dernière version qui le proposait était la 1.35.

#### emptyDir

Un `emptyDir` est créé vide quand le pod est affecté à un nœud, et effacé définitivement quand le pod quitte ce nœud, pour quelque raison que ce soit. Un crash de conteneur n'efface rien : le pod reste sur le nœud. Par défaut, il est stocké sur le disque du nœud (sous `/var/lib/kubelet/pods/<uid>/volumes/`) et sa consommation compte dans le stockage éphémère du pod. `sizeLimit` en borne la taille : le kubelet évince le pod qui la dépasse. Avec `medium: Memory`, le kubelet monte un tmpfs : c'est rapide, mais chaque octet écrit est compté **dans la limite mémoire du conteneur qui l'écrit**, et un tmpfs sans `sizeLimit` peut grandir jusqu'à la mémoire allouable du nœud. Le champ `emptyDir.mode`, qui fixe les permissions du répertoire, est alpha et désactivé en 1.37 : ne compte pas dessus.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cache-demo
spec:
  containers:
  - name: app
    image: busybox:1.37.0
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts:
    - name: cache
      mountPath: /cache
  volumes:
  - name: cache
    emptyDir:
      medium: Memory
      sizeLimit: 64Mi
```

#### hostPath

Un `hostPath` monte un fichier ou un répertoire du nœud. Le champ facultatif `type` fait vérifier (ou créer) la cible avant le montage :

| `type` | Comportement |
|---|---|
| `""` (défaut) | aucune vérification |
| `DirectoryOrCreate` | crée le répertoire s'il manque (mode 0755, propriétaire du kubelet) |
| `Directory` | le répertoire doit exister |
| `FileOrCreate` | crée le fichier s'il manque (0644), **mais pas son répertoire parent** |
| `File` | le fichier doit exister |
| `Socket`, `CharDevice`, `BlockDevice` | l'objet du type indiqué doit exister |

Trois raisons rendent `hostPath` dangereux : il donne accès à des fichiers sensibles du nœud (identifiants du kubelet, socket du runtime, donc évasion de conteneur), deux pods identiques se comportent différemment selon le nœud où ils tombent, et l'espace consommé n'est compté nulle part. C'est pourquoi le profil `baseline` de Pod Security l'interdit. Dans le namespace `boutique`, placé en `enforce=baseline` au [chapitre 8](08-ordonnancement-et-admission.md), un pod avec un volume `hostPath` est refusé à la création. La bonne alternative pour du stockage local durable est le PV de type `local` (15.7), qui passe par une PVC et que Pod Security autorise.

### 15.2 PersistentVolume et PersistentVolumeClaim : le modèle

Le sous-système de stockage persistant sépare deux rôles. L'**administrateur** décrit le stockage disponible : un **PersistentVolume** est un objet de niveau cluster (sans namespace) qui représente un morceau de stockage réel, avec sa capacité, ses modes d'accès, sa politique de récupération et les détails techniques de son accès (serveur NFS, chemin local, identifiant CSI…). L'**utilisateur** exprime un besoin : une **PersistentVolumeClaim** est un objet namespacé qui demande une taille, des modes d'accès et éventuellement une classe. Un contrôleur du control plane rapproche les deux. Le pod, enfin, ne connaît que la PVC, qui doit se trouver **dans son namespace**.

```
Qui crée quoi :
═══════════════

  administrateur              utilisateur                 kube-controller-manager
  ──────────────              ───────────                 ───────────────────────
  StorageClass  ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐                       contrôleur "persistent-volume-binder"
  (comment créer)                 │ storageClassName
                                  ▼
  PersistentVolume ◀════════ PersistentVolumeClaim ◀──── pod (volumes[].persistentVolumeClaim)
  (cluster, sans namespace)  (namespace du pod)
        │                         ▲
        │ spec.claimRef ──────────┘  liaison 1-1, bidirectionnelle :
        │                            PV.spec.claimRef ↔ PVC.spec.volumeName
        ▼
  stockage réel (disque, export NFS, volume CSI…)
```

Un PV peut naître de deux façons. En **provisionnement statique**, l'administrateur crée lui-même le PV. En **provisionnement dynamique**, aucune PV existante ne convient : la PVC désigne une StorageClass, et le provisionneur de cette classe crée le stockage et le PV à la demande (15.6).

Les champs à connaître sans hésiter :

| Champ du PV | Rôle | Défaut |
|---|---|---|
| `spec.capacity.storage` | taille offerte | obligatoire |
| `spec.accessModes` | modes d'accès offerts (15.4) | obligatoire |
| `spec.volumeMode` | `Filesystem` ou `Block` | `Filesystem` |
| `spec.persistentVolumeReclaimPolicy` | `Retain`, `Delete` ou `Recycle` (15.5) | **`Retain`** pour un PV créé à la main ; celle de la classe pour un PV provisionné |
| `spec.storageClassName` | classe du PV | aucune classe |
| `spec.nodeAffinity` | nœuds depuis lesquels le volume est accessible | aucune (obligatoire pour `local`) |
| `spec.mountOptions` | options de montage, non validées | aucune |
| `spec.claimRef` | PVC liée ou réservée | posé par le contrôleur |
| source : `local`, `hostPath`, `nfs`, `csi`… | où est le stockage | une seule par PV, **immuable** |

| Champ de la PVC | Rôle | Défaut |
|---|---|---|
| `spec.resources.requests.storage` | taille minimale demandée | obligatoire |
| `spec.accessModes` | modes demandés | obligatoire |
| `spec.storageClassName` | classe demandée ; `""` = aucune classe | classe par défaut, si elle existe (15.3) |
| `spec.selector` | labels exigés sur le PV | aucun |
| `spec.volumeName` | PV précis demandé | posé par le contrôleur |
| `spec.volumeMode` | `Filesystem` ou `Block` | `Filesystem` |
| `spec.dataSource`, `spec.dataSourceRef` | pré-remplir depuis un snapshot, une PVC, un peupleur (15.10) | aucune |
| `spec.volumeAttributesClassName` | classe d'attributs modifiables (15.12) | aucune |

La spec d'une PVC est **immuable** une fois créée, à deux exceptions près : `resources.requests` et `volumeAttributesClassName`, modifiables seulement quand la PVC est liée, et `volumeName`, qui peut être renseigné une seule fois s'il était vide. Toute autre modification est refusée avec `spec is immutable after creation except resources.requests and volumeAttributesClassName for bound claims`. Côté PV, la source et `volumeMode` sont immuables ; la capacité, les modes, la politique de récupération, la classe et `claimRef` se modifient.

### 15.3 Les règles de liaison

La liaison est l'œuvre du contrôleur `persistent-volume-binder` du kube-controller-manager. Il surveille les PVC non liées et leur cherche un PV, puis écrit la liaison des deux côtés : `spec.volumeName` dans la PVC, `spec.claimRef` (namespace, nom et UID de la PVC) dans le PV. La liaison est **exclusive et 1-1** : un PV lié n'appartient qu'à une PVC, et la PVC reçoit le PV entier. Une PVC de 500Mi liée à un PV de 1Gi affiche une capacité de 1Gi. Le contrôleur repasse sur les PVC en attente toutes les 15 secondes (`--pvclaimbinder-sync-period`), et une PVC sans PV qui convienne reste `Pending` indéfiniment, jusqu'à ce qu'un PV adapté apparaisse.

Pour une PVC sans `volumeName`, un PV n'est candidat que s'il remplit **toutes** les conditions suivantes :

| Critère | Règle exacte |
|---|---|
| Phase | le PV est `Available` (pas `Released`, pas `Failed`), ou déjà réservé à cette PVC par son `claimRef` |
| Classe | `storageClassName` identique des deux côtés, la chaîne vide comptant comme « aucune classe » |
| Taille | capacité du PV ≥ demande de la PVC ; parmi les candidats, **le plus petit** l'emporte |
| Modes d'accès | le PV offre **au moins tous** les modes demandés ; les PV qui en offrent le moins sont examinés d'abord |
| `volumeMode` | identique (`Filesystem` des deux côtés si absent) |
| Sélecteur | si la PVC a un `selector`, les labels du PV doivent y répondre (`matchLabels` et `matchExpressions` combinés en ET) |
| VolumeAttributesClass | `volumeAttributesClassName` identique |
| Nœud | en mode `WaitForFirstConsumer`, l'affinité de nœud du PV doit accepter le nœud choisi par le scheduler |

Deux conséquences se retrouvent dans les énoncés. Une PVC dotée d'un `selector` **ne peut pas être provisionnée dynamiquement** : elle ne se lie qu'à des PV existants. Et un PV trop petit, même d'un octet, n'est jamais choisi, alors qu'un PV beaucoup plus grand l'est sans état d'âme.

#### Classe absente, classe vide, classe par défaut

C'est la règle qui piège le plus. Une PVC dont `storageClassName` vaut `""` demande explicitement **aucune classe** : elle ne se lie qu'à un PV sans classe et ne déclenche jamais de provisionnement. Une PVC **sans** champ `storageClassName` est autre chose : à sa création, le contrôleur d'admission `DefaultStorageClass` (actif par défaut) lui injecte le nom de la classe par défaut du cluster, celle qui porte l'annotation `storageclass.kubernetes.io/is-default-class: "true"`. S'il y a plusieurs classes par défaut, c'est la plus récemment créée qui gagne. S'il n'y en a aucune, le champ reste vide, et depuis 1.28 (*retroactive default StorageClass assignment*), le contrôleur le renseigne après coup dès qu'une classe par défaut apparaît ; une PVC dont le champ vaut explicitement `""` n'est jamais modifiée ainsi.

```
storageClassName dans la PVC :
══════════════════════════════

  absent ──▶ admission DefaultStorageClass
              ├─ une classe par défaut existe ──▶ champ = cette classe ──▶ PV de cette classe
              │                                                         ou provisionnement
              └─ aucune ──▶ champ vide, rempli plus tard si une classe par défaut apparaît

  ""     ──▶ aucune classe : PV sans classe uniquement, jamais de provisionnement

  "manuel" ─▶ PV de classe "manuel" ; provisionnement si la classe a un provisionneur actif
```

> [!warning]
> Un PV statique créé **sans** `storageClassName` n'a pas de classe. Une PVC créée sans `storageClassName` dans un cluster qui a une classe par défaut reçoit cette classe et **ne se liera jamais** à ce PV. Pour lier un PV sans classe, la PVC doit porter `storageClassName: ""` ; sinon, donne la même classe aux deux.

#### Réserver un PV : volumeName et claimRef

Pour lier une PVC à un PV précis, on renseigne `spec.volumeName` dans la PVC (pré-liaison). Le contrôleur lie alors directement, sans tenir compte du sélecteur ni de l'affinité de nœud, et **sans attendre de consommateur** même si la classe est en `WaitForFirstConsumer`. Il vérifie en revanche la taille, la classe, le `volumeMode` et les modes d'accès ; en cas d'écart, la PVC reste `Pending` avec un événement `VolumeMismatch` qui nomme le critère (`requested PV is too small`, `storageClassName does not match`, `incompatible accessMode`…). Si le PV est déjà lié à une autre PVC, l'événement dit `volume "<pv>" already bound to a different claim.` La pré-liaison ne réserve rien : une autre PVC peut prendre le PV d'abord. Pour réserver vraiment, on renseigne aussi `spec.claimRef` (namespace et nom, sans UID) dans le PV ; aucune autre PVC ne pourra alors le prendre.

### 15.4 Modes d'accès et volumeMode

Les modes d'accès décrivent ce que le stockage sait faire ; Kubernetes s'en sert pour apparier PV et PVC et, pour certains, pour contraindre le placement des pods.

| Mode | Abréviation | Sens exact |
|---|---|---|
| `ReadWriteOnce` | RWO | monté en lecture-écriture par **un seul nœud** ; plusieurs pods du **même nœud** peuvent l'utiliser ensemble |
| `ReadOnlyMany` | ROX | monté en lecture seule par plusieurs nœuds |
| `ReadWriteMany` | RWX | monté en lecture-écriture par plusieurs nœuds |
| `ReadWriteOncePod` | RWOP | monté en lecture-écriture par **un seul pod** dans tout le cluster ; GA depuis 1.29, volumes CSI seulement |

Trois subtilités font la différence à l'examen. RWO n'est pas « un seul pod » : deux pods sur le même nœud partagent un volume RWO sans erreur ; seul RWOP l'interdit, et le scheduler laisse alors le second pod `Pending` avec `node(s) unavailable due to PersistentVolumeClaim with ReadWriteOncePod access mode already in-use by another pod`. Ensuite, un volume se monte dans **un seul mode à la fois**, même s'il en offre plusieurs. Enfin, hors RWOP, les modes ne protègent pas les données : un PV déclaré ROX n'est pas garanti en lecture seule, c'est le `readOnly: true` du montage qui protège.

Le support dépend du type : `hostPath` et `local` ne proposent que RWO, RWOP étant réservé aux volumes CSI ; NFS fait RWO, ROX et RWX ; pour CSI, tout dépend du pilote. Comme les PVC sont namespacées, un volume RWX ou ROX ne se partage qu'entre pods **d'un même namespace**.

`volumeMode: Block` présente le volume comme un périphérique brut, sans système de fichiers : le conteneur le déclare dans `volumeDevices` (avec `devicePath`) au lieu de `volumeMounts`. Un PV `Block` ne se lie qu'à une PVC `Block`, et réciproquement.

### 15.5 Cycle de vie : phases, récupération et protection

#### Les phases

```
Phases d'un PV :
════════════════

             création (statique)        PVC liée
  (Pending) ───────▶ Available ─────────────────▶ Bound
                         ▲                          │ PVC supprimée
                         │                          ▼
     claimRef retiré  ───┴──────────────────── Released
     à la main                                      │
                                                    ├─ Retain  : reste Released (données intactes)
                                                    ├─ Delete  : PV et stockage supprimés
                                                    │            (échec ──▶ Failed)
                                                    └─ Recycle : rm -rf puis Available
                                                                 (échec ──▶ Failed)

Phases d'une PVC : Pending ──▶ Bound ──▶ (Lost si son PV disparaît)
```

`Pending` est la phase transitoire d'un PV qui vient d'être créé. `Released` signifie que la PVC a disparu mais que le stockage n'a pas été récupéré : le PV garde son `claimRef` vers l'ancienne PVC (avec son UID), et **aucune nouvelle PVC ne peut s'y lier**, même portant le même nom. `Failed` signale l'échec de la récupération automatique ; par exemple, un PV `local` en `Delete` sans provisionneur externe pour le gérer passe en `Failed`, faute de plugin capable de supprimer son stockage. Le champ `status.lastPhaseTransitionTime` (GA depuis 1.31) date le dernier changement de phase.

#### Les politiques de récupération

| Politique | Effet quand la PVC est supprimée | Pour qui |
|---|---|---|
| `Retain` | le PV passe `Released`, données intactes ; récupération manuelle | défaut d'un PV statique ; données précieuses |
| `Delete` | le PV **et** le stockage sont supprimés | défaut des PV provisionnés (hérité de la classe, elle-même en `Delete` par défaut) |
| `Recycle` | `rm -rf` du contenu puis retour en `Available` | **dépréciée**, seuls `nfs` et `hostPath` la gèrent |

`Recycle` est toujours acceptée par l'API, mais avec un avertissement : `Warning: spec.persistentVolumeReclaimPolicy: The Recycle reclaim policy is deprecated. Instead, the recommended approach is to use dynamic provisioning.` La politique d'un PV se change à tout moment, ce qui est le moyen de protéger un volume provisionné en `Delete` avant de supprimer sa PVC :

```bash
kubectl patch pv <pv> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
```

#### Remettre un PV Released à disposition

Un PV `Released` en `Retain` reste inutilisable tant que son `claimRef` pointe vers l'ancienne PVC. La procédure officielle est de supprimer le PV puis de le recréer, après avoir nettoyé ou non les données. Plus rapide, et très utilisé : retirer le `claimRef`. Le PV redevient `Available` et **les données restent** : le prochain locataire les verra, ce qui pose une question de confidentialité que l'administrateur doit trancher.

```bash
# Rendre le PV à tous
kubectl patch pv archives --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]'

# Variante : ne retirer que l'UID, le PV reste réservé à une PVC du même nom
kubectl patch pv archives --type=json -p '[{"op":"remove","path":"/spec/claimRef/uid"}]'
```

La variante tient à la règle de reconnaissance du contrôleur : un PV est considéré comme lié à une PVC si le namespace et le nom de son `claimRef` correspondent, et si l'UID, **quand il est renseigné**, correspond aussi. Sans UID, la PVC recréée sous le même nom est reconnue comme la destinataire du PV.

#### La protection des objets en cours d'utilisation

Supprimer une PVC encore utilisée par un pod, ou un PV encore lié, ne casse rien : deux finalizers retardent la suppression. Une PVC porte `kubernetes.io/pvc-protection` et reste `Terminating` tant qu'un pod (même `Pending`) la référence. Un PV porte `kubernetes.io/pv-protection` et reste `Terminating` tant qu'il est lié. Les PV provisionnés par un pilote CSI portent en plus `external-provisioner.volume.kubernetes.io/finalizer`, qui garantit que le stockage du back-end est supprimé avant l'objet PV, quel que soit l'ordre dans lequel on supprime PV et PVC (fonction *HonorPVReclaimPolicy*, GA depuis 1.33).

```
Name:          archives
Namespace:     boutique
StorageClass:  manuel
Status:        Terminating (lasts 12s)
Volume:        archives
…
Finalizers:    [kubernetes.io/pvc-protection]
```

Une PVC bloquée en `Terminating` se débloque en supprimant le pod qui l'utilise, jamais en retirant le finalizer à la main, qui ferait disparaître l'objet sous un pod qui écrit encore. Nouveauté de 1.37 (bêta, active par défaut) : le contrôleur de protection pose sur chaque PVC une condition `Unused`, `True` quand aucun pod non terminé ne la référence, avec la date depuis laquelle elle est inutilisée dans `lastTransitionTime`.

### 15.6 StorageClass et provisionnement dynamique

Une StorageClass décrit une catégorie de stockage et la façon de la créer. C'est un objet de niveau cluster, que les PVC désignent par son nom.

| Champ | Rôle | Défaut | Modifiable |
|---|---|---|---|
| `provisioner` | qui crée les volumes (nom du pilote CSI, `kubernetes.io/no-provisioner`…) | obligatoire | non |
| `parameters` | paramètres propres au provisionneur (512 au plus, 256 Kio en tout) | aucun | non |
| `reclaimPolicy` | politique des PV créés : `Delete` ou `Retain` | `Delete` | non |
| `volumeBindingMode` | `Immediate` ou `WaitForFirstConsumer` | `Immediate` | non |
| `allowVolumeExpansion` | autorise l'agrandissement des PVC de la classe | `false` | oui |
| `mountOptions` | options de montage des PV créés | aucune | oui |
| `allowedTopologies` | restreint les zones ou nœuds de provisionnement | aucune | oui |

Les quatre premiers champs sont immuables : pour changer le mode de liaison d'une classe, il faut la supprimer et la recréer (les PV existants n'en souffrent pas, ils ne référencent la classe que par son nom). La politique de la classe ne concerne que les PV qu'elle **provisionne** : un PV statique rangé dans une classe garde la sienne.

Sur le lab, minikube installe une classe par défaut :

```
NAME                 PROVISIONER                RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
standard (default)   k8s.io/minikube-hostpath   Delete          Immediate           false                  5h42m
```

On change de classe par défaut en retirant l'annotation de l'une et en la posant sur l'autre (toute valeur autre que `"true"` vaut faux) :

```bash
kubectl patch storageclass standard -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
kubectl patch storageclass rapide -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

#### Le déroulé d'un provisionnement

```
Provisionnement dynamique avec WaitForFirstConsumer :
═════════════════════════════════════════════════════

  1. PVC créée (classe "rapide") ──▶ Pending
       événement : WaitForFirstConsumer
       "waiting for first consumer to be created before binding"
  2. pod créé, qui monte la PVC
  3. kube-scheduler (plugin VolumeBinding) choisit un nœud compatible
       avec le pod ET avec la topologie du stockage,
       puis annote la PVC : volume.kubernetes.io/selected-node=cka-m03
  4. contrôleur PV : annote la PVC
       volume.kubernetes.io/storage-provisioner=hostpath.csi.k8s.io
       événement : ExternalProvisioning "Waiting for a volume to be created
       either by the external provisioner 'hostpath.csi.k8s.io' or manually…"
  5. external-provisioner (sidecar CSI) appelle CreateVolume sur le pilote,
       puis crée le PV (annotation pv.kubernetes.io/provisioned-by,
       nodeAffinity sur le nœud choisi, reclaimPolicy de la classe)
  6. contrôleur PV : liaison PV ↔ PVC ──▶ Bound
  7. kubelet du nœud : NodeStage/NodePublish, montage dans le pod

  En mode Immediate : les étapes 2 et 3 n'existent pas, le volume est créé
  dès la PVC, sans savoir où le pod tournera.
```

Le mode `Immediate` convient au stockage accessible de partout (NFS, stockage réseau sans zones). Pour tout stockage lié à une topologie (disque local, disque zonal d'un cloud), il provoque des pods non planifiables : le volume est créé dans une zone ou sur un nœud au hasard, et le pod doit ensuite y aller, quels que soient ses autres contraintes. `WaitForFirstConsumer` retarde liaison et provisionnement jusqu'à ce qu'un pod utilise la PVC, de sorte que le scheduler décide en connaissant toutes les contraintes (ressources, sélecteurs, affinités, taints). C'est le mode à choisir par défaut, et le seul raisonnable pour `local`.

> [!danger]
> Avec une classe `WaitForFirstConsumer`, n'utilise jamais `spec.nodeName` pour placer le pod. `nodeName` court-circuite le scheduler : personne ne pose l'annotation `selected-node`, la PVC reste `Pending` et le pod attend son volume. Contraindre le pod se fait par `nodeSelector` (par exemple `kubernetes.io/hostname: cka-m03`) ou par une affinité de nœud.

La classe `kubernetes.io/no-provisioner` signifie « pas de provisionnement » : elle ne sert qu'à regrouper des PV statiques sous un nom et, surtout, à leur donner le mode `WaitForFirstConsumer`. Une PVC de cette classe sans PV disponible reste `Pending` ; si un pod la consomme, il reste `Pending` à son tour avec `0/3 nodes are available: 3 node(s) didn't find available persistent volumes to bind.`

> [!info] minikube ≠ examen
> Un cluster kubeadm nu n'a **aucune** StorageClass : à l'examen, l'énoncé fournit la classe à utiliser ou demande un PV statique. Le lab a `standard`, servie par `k8s.io/minikube-hostpath` (pod nu `storage-provisioner` dans `kube-system`). Ses PV sont des `hostPath` sous `/tmp/hostpath-provisioner/<namespace>/<pvc>` **sans affinité de nœud** : le provisionneur crée le répertoire sur son propre nœud, mais le pod écrit dans le répertoire du nœud où il tourne, et rien ne l'empêche d'être replanifié ailleurs, où il trouvera un répertoire vide. Ce répertoire est persistant (il est monté depuis le volume Docker du nœud), contrairement au reste de `/tmp`, qui est un tmpfs. Enfin `standard` n'accepte pas l'agrandissement : `only dynamically provisioned pvc can be resized and the storageclass that provisions the pvc must support resize`.

### 15.7 Volumes local et classe sans provisionneur

Un PV `local` représente un disque, une partition ou un répertoire **déjà monté** sur un nœud précis. Contrairement à `hostPath`, le système connaît sa localisation : le PV porte une `nodeAffinity`, **obligatoire** pour ce type, et le scheduler n'envoie les pods qui l'utilisent que sur ce nœud. Il n'y a pas de provisionnement dynamique : l'administrateur crée les PV un par un, ou les fait créer par le *local static provisioner* du projet, qui découvre les disques montés dans un répertoire convenu et gère aussi leur nettoyage. Le chemin doit exister sur le nœud : sinon le pod reste `ContainerCreating` avec un événement `FailedMount` qui signale le chemin absent.

| | PV `hostPath` | PV `local` |
|---|---|---|
| Connaissance du nœud | aucune : le pod peut partir ailleurs | `nodeAffinity` obligatoire, respectée par le scheduler |
| Création du chemin | possible (`type: DirectoryOrCreate`) | jamais : le chemin doit exister |
| Bloc brut | non | oui (`volumeMode: Block`) |
| Pod Security `baseline` | pod avec `hostPath` refusé ; PV `hostPath` via PVC accepté | accepté (via PVC) |
| Usage prévu | tests sur un seul nœud | production de stockage local (bases de données répliquées) |
| Nœud perdu | données perdues, pod replanifié à vide | pod `Pending` jusqu'au retour du nœud |

Le fil rouge range le PV `local` `archives` dans une classe `manuel` sans provisionneur, en `WaitForFirstConsumer` :

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: manuel
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: archives
spec:
  capacity:
    storage: 1Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manuel
  volumeMode: Filesystem
  local:
    path: /mnt/archives
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - cka-m02
```

Pourquoi `WaitForFirstConsumer` ici ? En mode `Immediate`, la PVC se lierait au PV dès sa création, et un pod qui exigerait par ailleurs un autre nœud (sélecteur, anti-affinité, ressources) deviendrait non planifiable, car il ne peut aller que là où est son volume. En attendant le premier consommateur, le scheduler choisit le nœud en tenant compte à la fois du pod et de l'affinité du PV.

### 15.8 CSI : l'architecture

La *Container Storage Interface* est une spécification gRPC qui sépare Kubernetes des systèmes de stockage. Un pilote CSI implémente trois services : `Identity` (nom et capacités), `Controller` (créer, supprimer, attacher, agrandir, photographier un volume, sans accès au nœud) et `Node` (préparer et monter le volume sur un nœud). Kubernetes n'appelle jamais le service `Controller` lui-même : des **sidecars** maintenus par le projet traduisent les objets de l'API en appels gRPC.

```
Un pilote CSI dans le cluster :
═══════════════════════════════

  partie contrôleur (Deployment, StatefulSet ou dans le DaemonSet)
  ┌────────────────────────────────────────────────────────────────┐
  │ external-provisioner  PVC  ──▶ CreateVolume / DeleteVolume     │
  │ external-attacher     VolumeAttachment ──▶ ControllerPublish   │
  │ external-resizer      PVC agrandie ──▶ ControllerExpandVolume  │
  │ external-snapshotter  VolumeSnapshotContent ──▶ CreateSnapshot │
  │            └──────── socket unix ──────▶ pilote (Controller)   │
  └────────────────────────────────────────────────────────────────┘
  snapshot-controller (un par cluster) : VolumeSnapshot ──▶ VolumeSnapshotContent

  partie nœud (DaemonSet, un pod par nœud)
  ┌────────────────────────────────────────────────────────────────┐
  │ node-driver-registrar  inscrit le pilote auprès du kubelet     │
  │                        (/var/lib/kubelet/plugins_registry/)    │
  │ pilote (Node)          /var/lib/kubelet/plugins/<pilote>/csi.sock
  │ livenessprobe          santé du pilote                         │
  └──────────────▲─────────────────────────────────────────────────┘
                 │ NodeStageVolume / NodePublishVolume / NodeExpandVolume
              kubelet

  Objets de l'API : CSIDriver (capacités du pilote), CSINode (pilotes
  présents sur un nœud, clés de topologie), VolumeAttachment (attachement
  d'un volume à un nœud), CSIStorageCapacity (capacité par topologie).
```

Le PV d'un volume CSI porte une source `csi` avec `driver` (nom du pilote), `volumeHandle` (identifiant chez le pilote), `fsType` et `volumeAttributes`. L'objet `CSIDriver` indique notamment si le pilote demande un attachement (`attachRequired`), s'il veut connaître le pod (`podInfoOnMount`) et s'il publie sa capacité (`storageCapacity`) pour que le scheduler en tienne compte.

Sur le lab, l'addon `csi-hostpath-driver` installe le pilote de démonstration `hostpath.csi.k8s.io` (hostpathplugin v1.9.0) dans `kube-system` : un DaemonSet `csi-hostpathplugin` de six conteneurs (pilote, `node-driver-registrar`, `liveness-probe`, `csi-provisioner`, `csi-snapshotter`, `csi-external-health-monitor-controller`), deux StatefulSets `csi-hostpath-attacher` et `csi-hostpath-resizer`, et, avec l'addon `volumesnapshots`, le Deployment `snapshot-controller` (deux réplicas) et les CRD des snapshots. Le `CSIDriver` affiche `ATTACHREQUIRED false`, `PODINFOONMOUNT true`, `STORAGECAPACITY true` et les modes `Persistent,Ephemeral`.

Ce pilote a une particularité qui compte pour la suite : son `csi-provisioner` tourne **dans chaque pod du DaemonSet**, en mode nœud (`--node-deployment=true --strict-topology=true`). Chaque nœud crée ses propres volumes, dans `/var/lib/csi-hostpath-data/<volumeHandle>`, et chaque PV porte l'affinité `topology.hostpath.csi/node In [<nœud>]`. Le plugin étant un DaemonSet, il doit pouvoir tourner sur tous les nœuds : c'est pourquoi aucune taint ne reste sur le cluster à l'issue du chapitre 8.

> [!info] minikube ≠ examen
> Le pilote hostpath ne crée pas de système de fichiers par volume : un volume est un répertoire du nœud monté dans le pod. `df` dans le pod affiche donc la taille du système de fichiers du nœud, pas la capacité du PV ; la taille à croire est celle de `kubectl get pvc`. Après `minikube -p cka stop` puis `start`, les pods CSI restent en échec environ 70 secondes (`driver name hostpath.csi.k8s.io not found in the list of registered CSI drivers`) le temps que le pilote se réinscrive auprès du kubelet ; les données sont intactes.

### 15.9 Agrandir un volume

L'agrandissement d'une PVC est GA depuis 1.24 pour les volumes CSI, à trois conditions : la PVC est liée, sa classe a `allowVolumeExpansion: true`, et le pilote sait agrandir. On ne fait que **modifier la demande** de la PVC ; jamais un nouveau PV n'est créé.

```bash
kubectl -n boutique patch pvc data-redis-0 -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
```

L'admission `PersistentVolumeClaimResize` refuse la demande si la PVC n'est pas liée (`Only bound persistent volume claims can be expanded`) ou si sa classe n'autorise pas l'agrandissement (`only dynamically provisioned pvc can be resized and the storageclass that provisions the pvc must support resize`). Le reste est asynchrone. Le `external-resizer` appelle `ControllerExpandVolume` et met à jour la capacité du PV ; si le volume porte un système de fichiers, la PVC reçoit la condition `FileSystemResizePending`, et le kubelet du nœud agrandit le système de fichiers (`NodeExpandVolume`), à chaud si le volume est monté et que le système de fichiers le permet (ext3, ext4, XFS), sinon au prochain démarrage d'un pod qui l'utilise. Ce n'est qu'à la fin que `status.capacity` de la PVC prend la nouvelle valeur, avec l'événement `FileSystemResizeSuccessful`.

On ne **réduit** jamais un volume. Une valeur inférieure à la demande précédente n'est acceptée que pour se rattraper d'un agrandissement impossible (fonction *RecoverVolumeExpansionFailure*, GA depuis 1.34) : on peut redemander une taille plus petite que l'échec, mais toujours **supérieure à `status.capacity`**, et suivre `status.allocatedResourceStatuses`. Autre règle : ne modifie pas la capacité du PV à la main. Si PV et PVC affichent ensuite la même taille, le control plane conclut que l'agrandissement a déjà eu lieu et ne touche plus au stockage.

> [!info] minikube ≠ examen
> Ni `standard` ni `csi-hostpath-sc` (créée par l'addon sans `allowVolumeExpansion`, donc à `false`) n'acceptent l'agrandissement : c'est pour cela que le fil rouge crée sa propre classe `rapide`. Avec elle, l'opération réussit, à une condition propre à l'addon : son `csi-resizer` tourne dans un StatefulSet à un seul pod, `csi-hostpath-resizer-0`, qui parle au socket du pilote **de son propre nœud** (volume `hostPath` `/var/lib/kubelet/plugins/csi-hostpath`), et chaque nœud ne connaît que ses volumes. Si le resizer et le volume ne sont pas sur le même nœud, l'agrandissement reste bloqué indéfiniment, avec un avertissement répété toutes les quelques secondes : `VolumeResizeFailed … rpc error: code = NotFound desc = volume id … does not exist in the volumes list`. Le remède est de placer le resizer sur le nœud du volume par un `nodeSelector` (exercice 15.5). Le resizer bien placé, PV et PVC passent à la nouvelle taille en une dizaine de secondes ; entre-temps, le vieux `csi-resizer` v1.6.0 émet quelques avertissements transitoires sans conséquence : `VolumeResizeFailed … the object has been modified; please apply your changes to the latest version and try again`. Ne modifie pas `csi-hostpath-sc` elle-même : la modification survivrait à `minikube -p cka stop` puis `start` (minikube y réapplique ses addons par `kubectl apply`, qui ne retire pas un champ absent de sa dernière configuration, constaté sur le lab), mais la classe appartient à l'addon, qui la recrée sans ta modification s'il est désactivé puis réactivé.

### 15.10 Snapshots et clones

Les instantanés de volumes reposent sur trois ressources qui **ne font pas partie du cœur de l'API** : ce sont des CRD du groupe `snapshot.storage.k8s.io/v1`, installées par la distribution avec le `snapshot-controller`. Elles calquent le trio PVC, PV, StorageClass :

| Ressource | Portée | Analogue | Rôle |
|---|---|---|---|
| `VolumeSnapshot` | namespace | PVC | demande d'instantané d'une PVC (`spec.source.persistentVolumeClaimName`) |
| `VolumeSnapshotContent` | cluster | PV | l'instantané réel chez le pilote (`snapshotHandle`) |
| `VolumeSnapshotClass` | cluster | StorageClass | `driver`, `deletionPolicy` (`Delete` ou `Retain`, **obligatoire**), `parameters` ; immuable |

Le `snapshot-controller` crée et lie les `VolumeSnapshotContent` ; le sidecar `csi-snapshotter` appelle `CreateSnapshot` et `DeleteSnapshot`. Une VolumeSnapshotClass est la classe par défaut d'un pilote si elle porte l'annotation `snapshot.storage.kubernetes.io/is-default-class: "true"` ; il en faut au plus une par pilote. Pendant la prise d'un instantané, la PVC source est protégée : sa suppression attend que l'instantané soit prêt. L'instantané est prêt quand `status.readyToUse` vaut `true` ; `status.restoreSize` donne la taille minimale d'un volume restauré.

Restaurer, c'est créer une **nouvelle** PVC dont `dataSource` désigne l'instantané ; cloner, c'est désigner une PVC existante du même namespace (pas de `apiGroup` pour une PVC). Dans les deux cas, la PVC doit utiliser un pilote CSI qui le gère, et sa demande doit être au moins égale à la taille de la source. Le champ `dataSourceRef` généralise `dataSource` à des objets quelconques (les *peupleurs de volumes*, GA depuis 1.33) ; désigner une source d'un autre namespace exige la fonction alpha `CrossNamespaceVolumeDataSource`, désactivée par défaut.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: copie-de-donnees
  namespace: boutique
spec:
  storageClassName: rapide
  dataSource:
    name: donnees
    kind: PersistentVolumeClaim
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

> [!warning]
> Sur le lab, restaurer un instantané avec `csi-hostpath-sc` (mode `Immediate`) **échoue** dès qu'un autre nœud que celui de l'instantané prend la demande : chaque nœud a son provisionneur, et seul celui qui détient l'instantané peut le restaurer. La PVC reste `Pending` avec `ProvisioningFailed … failed to provision volume with StorageClass "csi-hostpath-sc": rpc error: code = NotFound desc = snapshot id … does not exist in the snapshots list`. La solution est celle de tout stockage topologique : une classe `WaitForFirstConsumer` et un pod contraint par `nodeSelector` au nœud de l'instantané. Les groupes d'instantanés (`VolumeGroupSnapshot`), stables depuis 1.36, relèvent eux aussi de CRD et ne sont pas au programme.

### 15.11 StatefulSet et volumeClaimTemplates

Le [chapitre 5](05-deployments-et-controleurs.md) a présenté l'identité stable des pods d'un StatefulSet ; le stockage en est l'autre moitié. Pour chaque entrée de `spec.volumeClaimTemplates`, le contrôleur crée **une PVC par pod**, nommée `<modèle>-<statefulset>-<ordinal>`, et la monte toujours dans le pod de même ordinal, quel que soit le nœud où il renaît. Le StatefulSet `redis` du fil rouge, avec un modèle `data`, produit la PVC `data-redis-0`. Supprimer le pod `redis-0` ne touche pas à `data-redis-0` : le pod recréé la retrouve, et le scheduler le renvoie sur le nœud du volume si celui-ci a une affinité.

```
StatefulSet redis, replicas: 1, volumeClaimTemplates: [data]
═══════════════════════════════════════════════════════════

  redis-0 ──monte──▶ PVC data-redis-0 ──▶ PV pvc-<uid> (rapide, nodeAffinity cka-m03)
  (si replicas: 3 : redis-1 ──▶ data-redis-1, redis-2 ──▶ data-redis-2)

  scale down 3 → 1 : redis-2 et redis-1 supprimés,
                     data-redis-2 et data-redis-1 GARDÉES (whenScaled: Retain)
  scale up 1 → 3   : redis-1 et redis-2 retrouvent leurs anciennes PVC
```

Le champ `spec.persistentVolumeClaimRetentionPolicy` (GA depuis 1.32) décide du sort de ces PVC, avec deux politiques indépendantes valant chacune `Retain` (défaut) ou `Delete` :

| Politique | S'applique quand… | `Delete` signifie |
|---|---|---|
| `whenDeleted` | le StatefulSet est supprimé | toutes les PVC des modèles sont supprimées après leurs pods (owner reference vers le StatefulSet) |
| `whenScaled` | le nombre de réplicas diminue | seules les PVC des pods retirés sont supprimées |

Ces politiques ne jouent que pour une suppression ou une réduction du StatefulSet : un pod recréé après la perte de son nœud garde sa PVC. Et la suppression d'une PVC entraîne celle du stockage si son PV est en `Delete`.

Deux restrictions sont classiques. `volumeClaimTemplates` est **immuable**, comme `selector`, `serviceName` et `podManagementPolicy` : pour agrandir les volumes d'un StatefulSet, on agrandit chaque PVC (15.9), le modèle restant à son ancienne valeur. Et les PVC créées à partir des modèles ne sont jamais supprimées par une mise à jour du StatefulSet.

### 15.12 VolumeAttributesClass et autres nouveautés

Une **VolumeAttributesClass** (`storage.k8s.io/v1`, GA depuis 1.34, toujours active depuis 1.36) décrit des attributs **modifiables** d'un volume, typiquement des IOPS ou un débit, là où la StorageClass fixe ce qui ne change pas. Elle porte un `driverName` et des `parameters` (immuables). Une PVC la désigne par `spec.volumeAttributesClassName`, qu'on peut changer sur une PVC liée : l'`external-resizer` appelle alors `ModifyVolume` sur le pilote. La colonne `VOLUMEATTRIBUTESCLASS` de `kubectl get pv` et `kubectl get pvc` vient de là ; elle affiche `<unset>` quand le champ est vide. Seuls les pilotes CSI qui implémentent `ModifyVolume` la gèrent, ce qui n'est pas le cas du pilote hostpath du lab : retiens le principe, sans pratique.

```yaml
apiVersion: storage.k8s.io/v1
kind: VolumeAttributesClass
metadata:
  name: argent
driverName: csi.stockage.example
parameters:
  iops: "3000"
  throughput: "50Mi"
```

Le volume **éphémère générique** est l'autre outil à connaître : un `volumes[].ephemeral.volumeClaimTemplate` dans un pod fait créer une PVC nommée `<pod>-<volume>`, possédée par le pod et supprimée avec lui. On obtient un espace de travail provisionné par n'importe quelle StorageClass, avec ses fonctions (taille, snapshots, capacité suivie), sans gérer de PVC à la main.

### 15.13 À l'examen : la méthode rapide

Aucune commande impérative ne crée de PV, de PVC ni de StorageClass : tout passe par du YAML. Le plus rapide est de copier les exemples de la documentation, que tu sais retrouver en quelques secondes avec la recherche du site :

| Besoin | Page de kubernetes.io/docs |
|---|---|
| PV, PVC, pod qui monte la PVC (exemple `hostPath` complet) | *Configure a Pod to Use a PersistentVolumeClaim for Storage* (`/docs/tutorials/configuration/configure-persistent-volume-storage/`) |
| règles de liaison, modes d'accès, `local`, expansion, `dataSource` | *Persistent Volumes* (`/docs/concepts/storage/persistent-volumes/`) |
| StorageClass, `WaitForFirstConsumer`, exemple `local` | *Storage Classes* (`/docs/concepts/storage/storage-classes/`) |
| `emptyDir`, `hostPath`, `local`, `csi` | *Volumes* (`/docs/concepts/storage/volumes/`) |
| VolumeSnapshot, VolumeSnapshotClass | *Volume Snapshots*, *Volume Snapshot Classes* |
| `persistentVolumeClaimRetentionPolicy` | *StatefulSets* |

`kubectl explain` complète la doc pour un champ précis : `kubectl explain pv.spec.local`, `kubectl explain pvc.spec.dataSourceRef`, `kubectl explain sts.spec.persistentVolumeClaimRetentionPolicy`, ou `kubectl explain pv.spec --recursive | less` pour voir tout l'arbre. Les noms courts économisent des frappes : `pv`, `pvc`, `sc`, `sts`. Les CRD des snapshots du lab n'en ont pas : écris `volumesnapshot` en entier.

> [!tip] Réflexe d'examen
> Une PVC `Pending` se diagnostique en trois commandes, toujours dans cet ordre : `kubectl describe pvc <nom>` (les événements disent presque tout : `WaitForFirstConsumer`, `FailedBinding`, `ProvisioningFailed`, `VolumeMismatch`), puis `kubectl get pv` pour comparer classe, taille, modes et phase, puis `kubectl get sc` pour vérifier le provisionneur et le mode de liaison. Pour lister les PV par taille, `kubectl get pv --sort-by=.spec.capacity.storage` trie bien numériquement (1Gi après 500Mi).

Avant de passer à la tâche suivante, vérifie l'état final, pas la commande : la PVC est `Bound`, au bon volume, avec la bonne classe ; le pod est `Running` et voit ses données (`kubectl exec … -- ls <point de montage>`). Une PVC en `WaitForFirstConsumer` sans pod n'est pas une erreur : c'est l'état attendu tant que l'énoncé ne demande pas de pod.

### 15.14 Pièges courants

```
Piège 1 : PVC sans storageClassName face à un PV sans classe
═════════════════════════════════════════════════════════════
  MAUVAIS  : PV sans storageClassName, PVC sans storageClassName,
             dans un cluster qui a une classe par défaut.
  SYMPTÔME : la PVC reçoit la classe par défaut, reste Pending ou se fait
             provisionner un autre volume ; le PV reste Available.
  BON      : storageClassName: "" dans la PVC, ou la même classe des deux côtés.

Piège 2 : nodeName avec une classe WaitForFirstConsumer
═══════════════════════════════════════════════════════
  MAUVAIS  : spec.nodeName: cka-m03 pour placer le pod.
  SYMPTÔME : la PVC reste Pending (aucun selected-node), le pod attend.
  BON      : nodeSelector: {kubernetes.io/hostname: cka-m03}.

Piège 3 : réutiliser un PV Released
═══════════════════════════════════
  MAUVAIS  : recréer la PVC supprimée en espérant retrouver le PV.
  SYMPTÔME : Pending ; FailedBinding « already bound to a different claim »
             si la PVC désigne le PV par volumeName.
  BON      : retirer spec.claimRef (ou seulement son uid) du PV.

Piège 4 : croire que RWO veut dire « un seul pod »
══════════════════════════════════════════════════
  SYMPTÔME : deux pods du même nœud écrivent dans le même volume RWO.
  BON      : ReadWriteOncePod pour l'exclusivité par pod (CSI seulement).

Piège 5 : agrandir une PVC d'une classe sans allowVolumeExpansion
═════════════════════════════════════════════════════════════════
  SYMPTÔME : Forbidden « only dynamically provisioned pvc can be resized
             and the storageclass that provisions the pvc must support resize ».
  BON      : allowVolumeExpansion: true dans la classe (champ modifiable),
             puis patch de la PVC ; jamais de réduction.

Piège 6 : modifier volumeClaimTemplates pour agrandir un StatefulSet
═════════════════════════════════════════════════════════════════════
  SYMPTÔME : mise à jour du StatefulSet refusée (champ immuable).
  BON      : patcher chaque PVC data-<sts>-<n>.

Piège 7 : PV local dont le chemin n'existe pas
══════════════════════════════════════════════
  SYMPTÔME : PVC Bound, pod planifié mais bloqué en ContainerCreating,
             événement FailedMount sur le chemin absent.
  BON      : créer le répertoire sur le nœud de la nodeAffinity avant le pod.

Piège 8 : retirer le finalizer pvc-protection d'une PVC Terminating
════════════════════════════════════════════════════════════════════
  SYMPTÔME : l'objet disparaît alors qu'un pod écrit encore dedans.
  BON      : supprimer (ou laisser finir) le pod qui l'utilise.
```

> [!summary] À retenir
> - Une PVC se lie à un PV `Available` de **même classe** (`""` = aucune), de capacité **≥** à la demande (le plus petit gagne), offrant **tous** les modes demandés, de même `volumeMode`, et conforme à son `selector`.
> - `storageClassName` absent = classe par défaut injectée à l'admission ; `""` = aucune classe et jamais de provisionnement.
> - `volumeName` pré-lie sans attendre de consommateur ; `claimRef` dans le PV réserve ; un PV `Released` garde son `claimRef` tant qu'on ne le retire pas.
> - PV statique : `Retain` par défaut ; PV provisionné : politique de la classe, `Delete` par défaut ; `Recycle` est dépréciée.
> - `WaitForFirstConsumer` pour tout stockage topologique (`local`, CSI zonal), avec `nodeSelector` et jamais `nodeName`.
> - RWO = un nœud, RWOP = un pod (CSI, GA 1.29), et un PV `local` exige une `nodeAffinity`.
> - Agrandir = patcher la PVC, classe en `allowVolumeExpansion: true` ; jamais de réduction ; `volumeClaimTemplates` est immuable.
> - Snapshots = CRD `snapshot.storage.k8s.io/v1` ; restaurer = nouvelle PVC avec `dataSource` et une taille ≥ `restoreSize`.
> - Une PVC `Pending` se lit dans `kubectl describe pvc` avant toute autre chose.

### 15.15 Exercices

#### Exercice 15.1 — Classe par défaut et classe vide

**Point de départ** : exercice 14.6, ou instantané I2.

Dans le namespace `boutique`, identifie la StorageClass par défaut du cluster. Crée deux PVC de 100Mi en `ReadWriteOnce` : `essai-defaut` sans champ `storageClassName`, et `essai-vide` avec `storageClassName: ""`. Explique l'état de chacune, retrouve le répertoire du PV créé pour `essai-defaut`, puis tente d'agrandir `essai-defaut` à 200Mi. Supprime enfin les deux PVC et vérifie que le PV d'`essai-defaut` a disparu.

> [!example]- Solution
> ```yaml
> # ~/cka/boutique/essais-pvc.yaml
> apiVersion: v1
> kind: PersistentVolumeClaim
> metadata:
>   name: essai-defaut
>   namespace: boutique
> spec:
>   accessModes:
>   - ReadWriteOnce
>   resources:
>     requests:
>       storage: 100Mi
> ---
> apiVersion: v1
> kind: PersistentVolumeClaim
> metadata:
>   name: essai-vide
>   namespace: boutique
> spec:
>   storageClassName: ""
>   accessModes:
>   - ReadWriteOnce
>   resources:
>     requests:
>       storage: 100Mi
> ```
>
> ```bash
> kubectl get storageclass
> kubectl apply -f ~/cka/boutique/essais-pvc.yaml
> kubectl -n boutique get pvc
> kubectl -n boutique get pvc essai-defaut -o jsonpath='{.spec.storageClassName}{"\n"}'
> kubectl -n boutique describe pvc essai-vide | sed -n '/Events/,$p'
> PV=$(kubectl -n boutique get pvc essai-defaut -o jsonpath='{.spec.volumeName}')
> kubectl get pv "$PV" -o jsonpath='{.spec.hostPath.path}{"\n"}'
> kubectl -n boutique patch pvc essai-defaut -p '{"spec":{"resources":{"requests":{"storage":"200Mi"}}}}'
> kubectl delete -f ~/cka/boutique/essais-pvc.yaml
> kubectl get pv "$PV"
> ```
>
> `standard (default)` est la classe par défaut. `essai-defaut` a reçu `storageClassName: standard` de l'admission `DefaultStorageClass` ; la classe étant en `Immediate`, le provisionneur de minikube a créé aussitôt un PV `hostPath` sous `/tmp/hostpath-provisioner/boutique/essai-defaut`, et la PVC est `Bound`. `essai-vide` demande explicitement l'absence de classe : aucun PV sans classe n'existe et le provisionnement est exclu, d'où l'événement `FailedBinding  no persistent volumes available for this claim and no storage class is set`. L'agrandissement est refusé par l'admission, car `standard` n'a pas `allowVolumeExpansion`. Le PV d'`essai-defaut` hérite de la politique `Delete` de la classe : il disparaît avec sa PVC.
>
> **Vérification** : `kubectl -n boutique get pvc` ne liste plus aucune PVC `essai-*`, et `kubectl get pv "$PV"` répond `Error from server (NotFound)`.

#### Exercice 15.2 — Un PV local lié au premier consommateur

**Point de départ** : exercice 15.1.

Crée la StorageClass `manuel` (provisionneur `kubernetes.io/no-provisioner`, mode `WaitForFirstConsumer`) et le PV `archives` : type `local`, chemin `/mnt/archives` à créer sur `cka-m02`, 1Gi, `ReadWriteOnce`, politique `Retain`, classe `manuel`, affinité de nœud `kubernetes.io/hostname=cka-m02`. Crée dans `boutique` la PVC `archives` (500Mi, `ReadWriteOnce`, classe `manuel`) et observe son état. Crée ensuite le pod `archiveur` (busybox:1.37.0, labels `app=archiveur` et `tier=outils`) qui monte la PVC en `/archives`, y ajoute la date dans `journal.txt`, puis dort une heure. Où le pod a-t-il été placé, et quelle capacité affiche la PVC ?

> [!example]- Solution
> ```bash
> minikube -p cka ssh -n cka-m02 -- sudo mkdir -p /mnt/archives
> ```
>
> Le chemin d'un volume `local` doit exister avant le montage ; il est pris hors de `/tmp`, qui est un tmpfs dans les nœuds du lab. Le manifeste de la classe et du PV est celui de la section 15.7, à enregistrer dans `~/cka/boutique/archives-pv.yaml`. La PVC et le pod :
>
> ```yaml
> # ~/cka/boutique/archives-pvc.yaml
> apiVersion: v1
> kind: PersistentVolumeClaim
> metadata:
>   name: archives
>   namespace: boutique
> spec:
>   storageClassName: manuel
>   accessModes:
>   - ReadWriteOnce
>   resources:
>     requests:
>       storage: 500Mi
> ```
>
> ```yaml
> # ~/cka/boutique/archiveur.yaml
> apiVersion: v1
> kind: Pod
> metadata:
>   name: archiveur
>   namespace: boutique
>   labels:
>     app: archiveur
>     tier: outils
> spec:
>   containers:
>   - name: archiveur
>     image: busybox:1.37.0
>     command: ["sh", "-c", "date >> /archives/journal.txt; sleep 3600"]
>     volumeMounts:
>     - name: archives
>       mountPath: /archives
>   volumes:
>   - name: archives
>     persistentVolumeClaim:
>       claimName: archives
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/archives-pv.yaml
> kubectl get sc manuel; kubectl get pv archives
> kubectl apply -f ~/cka/boutique/archives-pvc.yaml
> kubectl -n boutique describe pvc archives | sed -n '/Events/,$p'
> kubectl apply -f ~/cka/boutique/archiveur.yaml
> kubectl -n boutique get pod archiveur -o wide
> kubectl -n boutique get pvc archives
> minikube -p cka ssh -n cka-m02 -- sudo cat /mnt/archives/journal.txt
> ```
>
> Tant qu'aucun pod ne l'utilise, la PVC reste `Pending` avec l'événement `WaitForFirstConsumer  waiting for first consumer to be created before binding` : c'est voulu. À la création du pod, le scheduler cherche un nœud compatible à la fois avec le pod et avec un PV candidat ; seul `archives` convient (classe `manuel`, 1Gi ≥ 500Mi, RWO), et son affinité n'accepte que `cka-m02`. Le pod y est placé et la PVC se lie : elle affiche `1Gi`, la capacité du PV entier, et non les 500Mi demandés. La création du pod affiche les avertissements `would violate PodSecurity "restricted:latest"` du mode `warn` posé au chapitre 8 : ils n'empêchent rien, seul `baseline` est appliqué. La classe `manuel` affiche `RECLAIMPOLICY Delete`, sa valeur par défaut, sans effet sur le PV statique `archives`, qui garde son `Retain`.
>
> **Vérification** : `kubectl -n boutique get pod archiveur -o wide` montre `Running` sur `cka-m02` ; `kubectl -n boutique get pvc archives` affiche `Bound    archives   1Gi        RWO            manuel`, et le fichier `journal.txt` du nœud contient une date.

#### Exercice 15.3 — Du PV Released à la nouvelle liaison

**Point de départ** : exercice 15.2.

Supprime le pod `archiveur` puis la PVC `archives`, et relève l'état du PV. Recrée la PVC `archives` en la faisant désigner explicitement le PV `archives`, et explique pourquoi elle ne se lie pas. Rends le PV disponible sans le supprimer, vérifie que la PVC se lie seule, et que les données écrites à l'exercice précédent sont toujours là.

> [!example]- Solution
> ```yaml
> # ~/cka/boutique/archives-pvc.yaml (nouvelle version)
> apiVersion: v1
> kind: PersistentVolumeClaim
> metadata:
>   name: archives
>   namespace: boutique
> spec:
>   storageClassName: manuel
>   volumeName: archives
>   accessModes:
>   - ReadWriteOnce
>   resources:
>     requests:
>       storage: 500Mi
> ```
>
> ```bash
> kubectl -n boutique delete pod archiveur --now
> kubectl -n boutique delete pvc archives
> kubectl get pv archives
> kubectl apply -f ~/cka/boutique/archives-pvc.yaml
> kubectl -n boutique describe pvc archives | sed -n '/Events/,$p'
> kubectl get pv archives -o jsonpath='{.spec.claimRef}{"\n"}'
> kubectl patch pv archives --type=json -p '[{"op":"remove","path":"/spec/claimRef"}]'
> kubectl -n boutique get pvc archives -w        # Ctrl+C une fois Bound
> minikube -p cka ssh -n cka-m02 -- sudo cat /mnt/archives/journal.txt
> ```
>
> `--now` évite d'attendre 30 secondes : le `sh` du pod tourne en PID 1 et ignore SIGTERM, le kubelet attend donc la fin du délai de grâce avant de le tuer. L'ordre compte : supprimer d'abord la PVC laisserait celle-ci en `Terminating` (finalizer `kubernetes.io/pvc-protection`) jusqu'à la disparition du pod. Une fois la PVC partie, le PV passe `Released` et sa colonne `CLAIM` garde `boutique/archives` : la politique `Retain` conserve les données et le `claimRef`, qui porte l'UID de l'ancienne PVC. La nouvelle PVC a le même nom mais un autre UID, d'où `FailedBinding  volume "archives" already bound to a different claim.` Retirer le `claimRef` rend le PV `Available`. La PVC, pré-liée par `volumeName`, se lie au plus tard au passage suivant du contrôleur (15 secondes), sans attendre de consommateur malgré le mode `WaitForFirstConsumer`, et `storageClassName: manuel` évite l'injection de la classe par défaut, qui aurait provoqué `VolumeMismatch … storageClassName does not match`. Le nouveau locataire voit le `journal.txt` de l'ancien : rien n'a été nettoyé.
>
> **Vérification** : `kubectl get pv archives` affiche `Bound` et `boutique/archives` ; `kubectl -n boutique get pvc archives` affiche `Bound    archives   1Gi` ; le journal du nœud contient toujours la date de l'exercice 15.2.

#### Exercice 15.4 — Le stockage de Redis

**Point de départ** : exercice 15.3.

Active les addons `volumesnapshots` puis `csi-hostpath-driver`. Crée la StorageClass `rapide` (provisionneur `hostpath.csi.k8s.io`, politique `Delete`, `WaitForFirstConsumer`, agrandissement autorisé). Dans `boutique`, crée le Service headless `redis` (port 6379 nommé `redis`, sélecteur `app=redis`) et le StatefulSet `redis` : 1 réplica, `serviceName: redis`, image `redis:8.10.2-alpine` avec les arguments `--appendonly yes`, port 6379 nommé `redis`, labels `app=redis` et `tier=donnees`, `nodeSelector` `disque: ssd`, requests 50m/64Mi, limits 200m/256Mi, modèle de volume `data` de 1Gi en `ReadWriteOnce` dans la classe `rapide` monté en `/data`, politique de rétention `Retain` pour la suppression comme pour la réduction. Écris la clé `commandes` à la valeur `42`, supprime le pod `redis-0`, et vérifie que la clé a survécu.

> [!example]- Solution
> ```bash
> minikube -p cka addons enable volumesnapshots
> minikube -p cka addons enable csi-hostpath-driver
> kubectl -n kube-system rollout status daemonset csi-hostpathplugin
> kubectl get csidriver
> kubectl get volumesnapshotclass
> ```
>
> ```yaml
> # ~/cka/boutique/redis.yaml
> apiVersion: storage.k8s.io/v1
> kind: StorageClass
> metadata:
>   name: rapide
> provisioner: hostpath.csi.k8s.io
> reclaimPolicy: Delete
> volumeBindingMode: WaitForFirstConsumer
> allowVolumeExpansion: true
> ---
> apiVersion: v1
> kind: Service
> metadata:
>   name: redis
>   namespace: boutique
>   labels:
>     app: redis
>     tier: donnees
> spec:
>   clusterIP: None
>   selector:
>     app: redis
>   ports:
>   - name: redis
>     port: 6379
>     targetPort: redis
> ---
> apiVersion: apps/v1
> kind: StatefulSet
> metadata:
>   name: redis
>   namespace: boutique
>   labels:
>     app: redis
>     tier: donnees
> spec:
>   serviceName: redis
>   replicas: 1
>   selector:
>     matchLabels:
>       app: redis
>   persistentVolumeClaimRetentionPolicy:
>     whenDeleted: Retain
>     whenScaled: Retain
>   template:
>     metadata:
>       labels:
>         app: redis
>         tier: donnees
>     spec:
>       nodeSelector:
>         disque: ssd
>       containers:
>       - name: redis
>         image: redis:8.10.2-alpine
>         args: ["--appendonly", "yes"]
>         ports:
>         - name: redis
>           containerPort: 6379
>         resources:
>           requests:
>             cpu: 50m
>             memory: 64Mi
>           limits:
>             cpu: 200m
>             memory: 256Mi
>         volumeMounts:
>         - name: data
>           mountPath: /data
>   volumeClaimTemplates:
>   - metadata:
>       name: data
>     spec:
>       storageClassName: rapide
>       accessModes:
>       - ReadWriteOnce
>       resources:
>         requests:
>           storage: 1Gi
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/redis.yaml
> kubectl -n boutique rollout status statefulset redis
> kubectl -n boutique get pod redis-0 -o wide
> kubectl -n boutique get pvc data-redis-0
> kubectl get pv $(kubectl -n boutique get pvc data-redis-0 -o jsonpath='{.spec.volumeName}') \
>   -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0]}{"\n"}'
> kubectl -n boutique exec redis-0 -- redis-cli SET commandes 42
> kubectl -n boutique delete pod redis-0
> kubectl -n boutique wait --for=condition=Ready pod/redis-0 --timeout=120s
> kubectl -n boutique exec redis-0 -- redis-cli GET commandes
> ```
>
> Le `nodeSelector` envoie `redis-0` sur `cka-m03`, seul nœud `disque=ssd`. La classe étant en `WaitForFirstConsumer`, le provisionneur du plugin CSI de `cka-m03` crée le volume et un PV dont l'affinité est `topology.hostpath.csi/node In [cka-m03]`. Le pod recréé porte le même nom, retrouve la PVC `data-redis-0` et rejoue le journal AOF écrit dans `/data` : la clé est là. Le pod n'a pas besoin de réseau pour ces commandes, `kubectl exec` passant par le kubelet ; les NetworkPolicies du chapitre 14 (`redis-entree`, `api-sortie`) préparent déjà l'accès de `api` sur le port 6379.
>
> **Vérification** : `kubectl -n boutique get pvc data-redis-0` affiche `Bound` en classe `rapide` et `1Gi` ; la dernière commande affiche `42`.

#### Exercice 15.5 — Agrandir le volume de Redis

**Point de départ** : exercice 15.4.

Porte le volume de `redis-0` à 2Gi sans interrompre le pod. Tente au préalable de le faire en modifiant le StatefulSet, et explique le refus. Sur le lab, place d'abord le resizer de l'addon (StatefulSet `kube-system/csi-hostpath-resizer`) sur le nœud du volume (15.9). Suis l'opération jusqu'à son terme.

> [!example]- Solution
> ```bash
> kubectl -n boutique patch statefulset redis --type=json \
>   -p '[{"op":"replace","path":"/spec/volumeClaimTemplates/0/spec/resources/requests/storage","value":"2Gi"}]'
> kubectl -n boutique get pod redis-0 -o wide                     # NODE : cka-m03
> kubectl -n kube-system get pod csi-hostpath-resizer-0 -o wide
> kubectl -n kube-system patch statefulset csi-hostpath-resizer \
>   -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"cka-m03"}}}}}'
> kubectl -n kube-system rollout status statefulset csi-hostpath-resizer
> kubectl -n boutique patch pvc data-redis-0 -p '{"spec":{"resources":{"requests":{"storage":"2Gi"}}}}'
> kubectl -n boutique get pvc data-redis-0 -w        # Ctrl+C quand CAPACITY passe à 2Gi
> kubectl -n boutique describe pvc data-redis-0 | sed -n '/Events/,$p'
> ```
>
> Le premier patch est refusé : `The StatefulSet "redis" is invalid: spec.volumeClaimTemplates: Invalid value: […]: field is immutable`. On agrandit donc la PVC elle-même, ce que la classe `rapide` permet (`allowVolumeExpansion: true`). Avant cela, sur le lab, on place le resizer : le pod unique `csi-hostpath-resizer-0` ne sait agrandir que les volumes de son propre nœud, et le scheduler l'a placé sans rien savoir de `redis-0`. Le `nodeSelector` l'envoie sur `cka-m03`, nœud du volume ; le pod est recréé même s'il s'y trouvait déjà, puisque son modèle change. Sans ce geste, l'opération échoue deux fois sur trois : la PVC reste à 1Gi et ses événements répètent `VolumeResizeFailed … rpc error: code = NotFound desc = volume id … does not exist in the volumes list` ; poser le `nodeSelector` après coup suffit alors à la débloquer. Le resizer bien placé, le PV passe à 2Gi, puis le kubelet de `cka-m03` agrandit à chaud et la PVC affiche 2Gi une dizaine de secondes après le patch (9 secondes mesurées), avec l'événement final `FileSystemResizeSuccessful … MountVolume.NodeExpandVolume succeeded`. Les avertissements `VolumeResizeFailed … the object has been modified` qui apparaissent entre-temps viennent du vieux `csi-resizer` de l'addon et sont transitoires. Le `nodeSelector` du resizer survit à `minikube -p cka stop` puis `start`. Le modèle du StatefulSet reste à 1Gi : seul un futur `redis-1` en hériterait.
>
> **Vérification** : `kubectl -n boutique get pvc data-redis-0 -o jsonpath='{.status.capacity.storage}{"\n"}'` affiche `2Gi`, `redis-0` n'a pas redémarré (`RESTARTS` inchangé) et `kubectl -n boutique exec redis-0 -- redis-cli GET commandes` affiche toujours `42`.

#### Exercice 15.6 — Instantané et restauration

**Point de départ** : exercice 15.5.

Prends l'instantané `redis-instantane` de la PVC `data-redis-0` avec la classe `csi-hostpath-snapclass`. Une fois l'instantané prêt, écris dans `redis-0` la clé `apres-instantane` à la valeur `oui`. Restaure l'instantané dans une PVC temporaire `redis-restaure` et lis-la avec un pod temporaire `verif-restaure` (image `redis:8.10.2-alpine`, arguments `--appendonly yes`, labels `app=verif-restaure` et `tier=outils`). Vérifie que la copie contient `commandes` mais pas `apres-instantane`. Supprime ensuite le pod, la PVC restaurée et la clé `apres-instantane`, en gardant l'instantané.

> [!example]- Solution
> ```yaml
> # ~/cka/boutique/redis-instantane.yaml
> apiVersion: snapshot.storage.k8s.io/v1
> kind: VolumeSnapshot
> metadata:
>   name: redis-instantane
>   namespace: boutique
> spec:
>   volumeSnapshotClassName: csi-hostpath-snapclass
>   source:
>     persistentVolumeClaimName: data-redis-0
> ```
>
> ```yaml
> # ~/cka/boutique/redis-restaure.yaml
> apiVersion: v1
> kind: PersistentVolumeClaim
> metadata:
>   name: redis-restaure
>   namespace: boutique
> spec:
>   storageClassName: rapide
>   dataSource:
>     name: redis-instantane
>     kind: VolumeSnapshot
>     apiGroup: snapshot.storage.k8s.io
>   accessModes:
>   - ReadWriteOnce
>   resources:
>     requests:
>       storage: 2Gi
> ---
> apiVersion: v1
> kind: Pod
> metadata:
>   name: verif-restaure
>   namespace: boutique
>   labels:
>     app: verif-restaure
>     tier: outils
> spec:
>   nodeSelector:
>     kubernetes.io/hostname: cka-m03
>   containers:
>   - name: redis
>     image: redis:8.10.2-alpine
>     args: ["--appendonly", "yes"]
>     volumeMounts:
>     - name: data
>       mountPath: /data
>   volumes:
>   - name: data
>     persistentVolumeClaim:
>       claimName: redis-restaure
> ```
>
> ```bash
> kubectl apply -f ~/cka/boutique/redis-instantane.yaml
> kubectl -n boutique get volumesnapshot redis-instantane        # READYTOUSE true
> kubectl -n boutique get volumesnapshot redis-instantane -o jsonpath='{.status.restoreSize}{"\n"}'
> kubectl -n boutique exec redis-0 -- redis-cli SET apres-instantane oui
> kubectl apply -f ~/cka/boutique/redis-restaure.yaml
> kubectl -n boutique wait --for=condition=Ready pod/verif-restaure --timeout=180s
> kubectl -n boutique exec verif-restaure -- redis-cli GET commandes
> kubectl -n boutique exec verif-restaure -- redis-cli GET apres-instantane
> kubectl -n boutique delete pod verif-restaure
> kubectl -n boutique delete pvc redis-restaure
> kubectl -n boutique exec redis-0 -- redis-cli DEL apres-instantane
> ```
>
> L'instantané est pris par le `csi-snapshotter` du plugin de `cka-m03`, nœud du volume, et devient prêt en quelques secondes ; sa taille de restauration est celle du volume source, d'où la demande de 2Gi pour la copie. La restauration passe par la classe `rapide`, en `WaitForFirstConsumer`, et le pod est contraint par `nodeSelector` au nœud de l'instantané : c'est donc le provisionneur de `cka-m03`, celui qui détient l'instantané, qui crée le volume. Avec `csi-hostpath-sc` (`Immediate`), la demande pourrait échouer en `ProvisioningFailed … snapshot id … does not exist in the snapshots list` (15.10). La clé `apres-instantane`, écrite après l'instantané, n'existe pas dans la copie : `redis-cli`, appelé sans terminal, affiche alors une ligne vide (avec `-it`, il afficherait `(nil)`). Supprimer la PVC restaurée supprime aussi son PV, la classe étant en `Delete`.
>
> **Vérification** : la copie répond `42` à `GET commandes` et une ligne vide à `GET apres-instantane`. À la fin, `kubectl -n boutique get pvc` ne liste que `archives` et `data-redis-0`, et `kubectl -n boutique get volumesnapshot` liste `redis-instantane`. État : instantané **I3**.

---
