---
title: "CKA — 18. Interfaces d'extension, CRD et opérateurs"
description: "Les points d'extension de Kubernetes (CRI, CNI, CSI, admission, agrégation, CRD) et le patron opérateur, illustré par cert-manager."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 18. Interfaces d'extension, CRD et opérateurs

Kubernetes ne sait rien faire seul de ce qui touche au matériel ou au métier : il ne lance pas de conteneur, ne câble pas de réseau, ne monte pas de disque, ne délivre pas de certificat. Il définit des **interfaces** et laisse d'autres composants les implémenter : un runtime derrière la CRI, un plugin réseau derrière la CNI, un pilote de stockage derrière la CSI, des contrôleurs derrière des types d'API ajoutés par CRD. Le programme du CKA y consacre deux compétences du domaine *Cluster Architecture, Installation and Configuration* (25 %) : *Understand extension interfaces (CNI, CSI, CRI, etc.)* et *Understand CRDs, install and configure operators*. À l'examen, cela se traduit par des tâches très concrètes : interroger le runtime d'un nœud avec `crictl`, créer une RuntimeClass, lister les CRD d'un groupe, créer une ressource personnalisée valide, configurer un opérateur déjà installé. Ce chapitre fait le tour des points d'extension (les chapitres [9](09-reseau-des-pods.md) et [15](15-stockage.md) ont détaillé CNI et CSI), décortique les CRD jusqu'à la validation en CEL, puis configure cert-manager, l'opérateur installé au [chapitre 17](17-helm-et-kustomize.md).

### 18.1 Où Kubernetes s'étend

Les points d'extension se rangent en deux familles. Ceux du **nœud** sont des contrats entre le kubelet (ou le runtime) et un programme local, joint par un socket ou un exécutable. Ceux de l'**API** greffent de nouveaux types, de nouvelles règles ou de nouveaux serveurs sur l'API server.

```
┌──────────────────────────────── CONTROL PLANE ─────────────────────────────────┐
│  kube-apiserver                                                                │
│   ├─ CRD ──────────────────────── nouveaux types, stockés dans etcd            │
│   ├─ agrégation (APIService) ──── proxy vers un autre serveur d'API            │
│   │                               (metrics-server : metrics.k8s.io)            │
│   └─ admission                                                                 │
│       ├─ MutatingAdmissionPolicy / ValidatingAdmissionPolicy (CEL)             │
│       └─ webhooks mutants / validants (HTTPS vers un Service)                  │
│  contrôleurs et opérateurs ──── clients de l'API qui réconcilient les CRD      │
└────────────────────────────────────────┬───────────────────────────────────────┘
                                         │ watch / list / update
┌──────────────────────────────── NŒUD ──┴───────────────────────────────────────┐
│  kubelet                                                                       │
│   ├─ CRI (gRPC, unix:///run/containerd/containerd.sock) ──▶ containerd 2.x     │
│   │                                     │                    └─ shim ─▶ runc   │
│   │                                     └─ CNI (exécutables /opt/cni/bin,      │
│   │                                        config /etc/cni/net.d) ──▶ Calico   │
│   ├─ CSI (gRPC, /var/lib/kubelet/plugins/…) ──▶ pilote CSI (DaemonSet)         │
│   └─ device plugins (gRPC, /var/lib/kubelet/device-plugins/) ; DRA             │
└────────────────────────────────────────────────────────────────────────────────┘
```

| Interface | Appelant | Implémentation | Transport | Objets d'API associés |
|---|---|---|---|---|
| CRI | kubelet | containerd, CRI-O | gRPC sur socket Unix | RuntimeClass ; `Node.status.nodeInfo.containerRuntimeVersion`, `status.runtimeHandlers` |
| CNI | runtime (pas le kubelet) | Calico, Cilium, Flannel… | exécutable + JSON sur stdin | aucun dans le cœur (les CNI ajoutent leurs CRD) |
| CSI | kubelet, contrôleurs « sidecars » | pilote du fournisseur | gRPC sur socket Unix | CSIDriver, CSINode, VolumeAttachment, CSIStorageCapacity |
| Device plugins | kubelet | pilote GPU, FPGA… | gRPC | ressources étendues dans `Node.status.capacity` |
| DRA | scheduler, kubelet | pilote DRA | gRPC + API | DeviceClass, ResourceSlice, ResourceClaim, ResourceClaimTemplate |
| Admission | kube-apiserver | webhooks, politiques CEL | HTTPS, ou en processus | (Mutating\|Validating)WebhookConfiguration, (Mutating\|Validating)AdmissionPolicy(+Binding) |
| Agrégation | kube-apiserver | serveur d'API supplémentaire | HTTPS | APIService |
| CRD | kube-apiserver | (aucun code) | — | CustomResourceDefinition |

### 18.2 CRI : le kubelet et son runtime

#### 18.2.1 Le contrat

La Container Runtime Interface est une API gRPC (`runtime.v1`) que le runtime expose sur un socket Unix et que le kubelet appelle. Elle comprend deux services. `RuntimeService` gère les **sandboxes** (`RunPodSandbox`, `StopPodSandbox`, `RemovePodSandbox`) et les **conteneurs** (`CreateContainer`, `StartContainer`, `ExecSync`, `ContainerStats`…). `ImageService` gère les images (`PullImage`, `ListImages`, `RemoveImage`). Le kubelet trouve le socket dans sa configuration, champ `containerRuntimeEndpoint` de `/var/lib/kubelet/config.yaml` (`unix:///run/containerd/containerd.sock` sur les nœuds du lab).

```
Démarrage d'un pod, vu par la CRI
═════════════════════════════════

 kubelet                         containerd (plugin CRI)              noyau
 ───────                         ──────────────────────               ─────
 RunPodSandbox(pod, handler) ──▶ crée la sandbox :
                                  - netns + appel CNI ADD ──────────▶ veth, IP, routes
                                  - conteneur « pause »
                                    (registry.k8s.io/pause:3.10.2)
                                  - shim containerd-shim-runc-v2 ──▶ runc ─▶ namespaces,
                                                                            cgroups
 PullImage(image) ─────────────▶ tire l'image si absente
 CreateContainer(sandbox, cfg) ▶ prépare le conteneur dans la sandbox
 StartContainer(id) ───────────▶ shim ─▶ runc ─▶ processus
```

Le pod est donc d'abord une **sandbox** : un conteneur `pause` qui porte les espaces de noms partagés (réseau, IPC) et dont l'adresse IP est celle du pod. C'est le runtime, pas le kubelet, qui appelle le plugin CNI au moment de créer cette sandbox ; d'où le message `cni plugin not initialized` remonté par le kubelet quand `/etc/cni/net.d` est vide ([chapitre 9](09-reseau-des-pods.md)). Le **handler** passé à `RunPodSandbox` désigne la configuration de runtime à utiliser ; c'est par lui que passe la RuntimeClass (18.2.4).

Depuis la suppression de dockershim en 1.24, Docker n'est plus un runtime direct. En 1.37, containerd 1.7 n'est plus pris en charge (il est en fin de vie depuis le 30 septembre 2026) : le kubelet 1.37 garde encore un repli pour les runtimes qui n'implémentent pas l'appel CRI `RuntimeConfig`, mais ce repli disparaît en 1.38. Les nœuds du cours tournent sous containerd 2.3.4, avec runc 1.4.3.

#### 18.2.2 containerd 2.x et sa configuration

containerd lit `/etc/containerd/config.toml`. Sa version 2.x a introduit le format de configuration `version = 3`, dans lequel le plugin CRI est scindé et la configuration des runtimes vit sous `plugins.'io.containerd.cri.v1.runtime'`. Deux réglages y comptent pour Kubernetes : le pilote de cgroups de runc (`SystemdCgroup`, à `true` pour le pilote `systemd` recommandé), que le kubelet 1.37 adopte par l'appel CRI `RuntimeConfig` au lieu de son propre champ `cgroupDriver` (19.2.5), et la liste des runtimes, dont chaque nom est un **handler** utilisable par une RuntimeClass.

```toml
# containerd 2.x, format version 3 (« containerd config default »)
version = 3
[plugins.'io.containerd.cri.v1.runtime'.containerd]
  default_runtime_name = 'runc'
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc]
  runtime_type = 'io.containerd.runc.v2'
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = true
```

> [!info] minikube ≠ examen
> L'image de nœud de minikube copie un `config.toml` au format **version 2**, dont les sections s'écrivent `[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]` ; minikube y règle `SystemdCgroup = true` et l'image `pause` par `sed` au démarrage, et containerd 2.3.4 convertit ce format à la lecture. Un nœud installé par kubeadm selon la documentation ([chapitre 19](19-kubeadm-installation-ha-et-mises-a-jour.md)) porte en général le format version 3 produit par `containerd config default`. Dans les deux cas, le handler par défaut s'appelle `runc`.

#### 18.2.3 crictl, l'outil du nœud

`crictl` parle la CRI directement, sans passer par l'API server : c'est l'outil qui reste quand kubectl ne répond plus ([chapitre 23](23-depanner-le-cluster.md)). Il lit son socket dans `/etc/crictl.yaml` (`runtime-endpoint: unix:///run/containerd/containerd.sock`) et exige les droits root, puisque le socket appartient à root.

| Commande | Rôle |
|---|---|
| `crictl ps` / `ps -a` | conteneurs en cours / tous ; `--name`, `--pod`, `-q` (identifiants seuls) |
| `crictl pods` | sandboxes ; `--name`, `--namespace` (expressions régulières : `'^boutique$'` pour un nom exact), colonne RUNTIME (handler) |
| `crictl images` | images présentes sur le nœud |
| `crictl logs [-f] [--tail N] <id>` | journaux d'un conteneur, même arrêté |
| `crictl inspect <id>` / `inspectp <pod-id>` | état détaillé en JSON (PID, montages, réseau, handler) |
| `crictl exec -it <id> sh` | commande dans un conteneur |
| `crictl stats` / `statsp` | consommation par conteneur / par pod |
| `crictl info` | état et configuration du runtime (dont la configuration CRI et les handlers) |
| `crictl version` | versions du client, du runtime et de l'API CRI (`v1`) |
| `crictl rmi --prune` | supprime les images inutilisées |

Les noms de conteneurs CRI sont ceux du pod (`nginx`, `etcd`), pas les noms Docker composés d'autrefois ; filtrer par `--name` puis passer l'identifiant aux autres commandes est le réflexe : `sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q | head -1)`. Les nœuds du lab ont aussi `ctr` (client natif de containerd, qui voit les conteneurs Kubernetes dans le namespace containerd `k8s.io` : `sudo ctr -n k8s.io containers ls`) et `nerdctl`, mais ce sont des outils de containerd : ils ignorent les notions de pod et de sandbox.

> [!info] minikube ≠ examen
> Sur le lab, on entre dans un nœud par `minikube -p cka ssh -n cka-m02` (utilisateur `docker`) et `crictl` s'utilise avec `sudo` ; sans lui, il échoue sur `permission denied` au socket. À l'examen, `ssh <nœud>` puis `sudo -i`. La version de crictl du lab est v1.35.0, deux mineures sous Kubernetes 1.37 : les sous-commandes ci-dessus sont les mêmes.

#### 18.2.4 RuntimeClass

Une **RuntimeClass** (`node.k8s.io/v1`, objet de cluster) associe un nom utilisable dans les pods à un **handler** du runtime. Elle sert à faire tourner certains pods avec une configuration différente : un runtime à isolation forte (gVisor, Kata Containers) pour du code non fiable, ou une variante de runc avec d'autres options.

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: runc-standard        # nom référencé par spec.runtimeClassName
handler: runc                # nom du runtime dans la config CRI ; label DNS, immuable
# overhead:                  # facultatif : coût fixe ajouté aux requests du pod
#   podFixed:
#     cpu: 100m
#     memory: 64Mi
# scheduling:                # facultatif : où ce runtime existe
#   nodeSelector:
#     runtime/gvisor: "true"
#   tolerations: []
```

Un pod la choisit par `spec.runtimeClassName`. Le contrôleur d'admission `RuntimeClass`, actif par défaut, intervient alors à la création du pod : il **refuse** le pod si la RuntimeClass n'existe pas (`pods "x" is forbidden: pod rejected: RuntimeClass "inexistante" not found`), recopie `overhead.podFixed` dans `spec.overhead` (que le scheduler, les quotas et le kubelet ajoutent aux requests), et fusionne `scheduling.nodeSelector` et `scheduling.tolerations` dans ceux du pod (un conflit de `nodeSelector` fait rejeter le pod). Si la RuntimeClass existe mais que le runtime du nœud ne connaît pas son handler, le pod est accepté et planifié, puis la création de la sandbox échoue : événement `FailedCreatePodSandBox` dont le message se termine par `no runtime for "<handler>" is configured`.

Sans `runtimeClassName`, le kubelet passe un handler vide et le runtime applique son défaut (`default_runtime_name`). Le kubelet publie les handlers connus du runtime dans `Node.status.runtimeHandlers` : containerd y déclare une entrée au nom vide (le défaut) et une entrée `runc`.

### 18.3 CNI et CSI : rappel

#### 18.3.1 CNI

Le [chapitre 9](09-reseau-des-pods.md) a détaillé la spécification : le runtime exécute les plugins de `/opt/cni/bin` selon le premier fichier de configuration, par ordre alphabétique, de `/etc/cni/net.d`, avec les verbes `ADD`, `DEL` et `CHECK`. Sur le lab, `10-calico.conflist` enchaîne le plugin `calico` (IPAM `calico-ipam`) et `portmap`. Retiens pour ce chapitre que la CNI n'a **aucun objet** dans l'API du cœur : NetworkPolicy est une API de Kubernetes que le plugin choisit d'implémenter, et les réglages propres au plugin passent par ses CRD (`ippools.crd.projectcalico.org`).

#### 18.3.2 CSI

Le [chapitre 15](15-stockage.md) a détaillé l'architecture : un pilote CSI est un DaemonSet (partie nœud, appelée par le kubelet) plus des contrôleurs « sidecars » (external-provisioner, external-attacher, external-resizer, external-snapshotter) qui traduisent les objets Kubernetes en appels gRPC. Quatre objets d'API rendent ce contrat visible :

| Objet | Portée | Créé par | Ce qu'il dit |
|---|---|---|---|
| **CSIDriver** | cluster | l'installation du pilote | nom du pilote et comportement attendu : `attachRequired`, `podInfoOnMount`, `storageCapacity`, `fsGroupPolicy`, `volumeLifecycleModes`, `tokenRequests`, `requiresRepublish` |
| **CSINode** | un par nœud | le kubelet, quand le pilote s'enregistre | pilotes présents sur le nœud, identifiant du nœud pour chacun, clés de topologie, nombre maximal de volumes |
| **VolumeAttachment** | cluster | le contrôleur attach/detach | « le volume du PV X est attaché au nœud Y » ; seulement si le pilote exige l'attachement |
| CSIStorageCapacity | namespace | le provisioner | capacité disponible par segment de topologie |

Le pilote s'enregistre auprès du kubelet par un socket déposé dans `/var/lib/kubelet/plugins_registry/` (par le conteneur `node-driver-registrar`) ; le kubelet complète alors le CSINode du nœud. Sur le lab, le pilote `hostpath.csi.k8s.io` déclare `attachRequired: false` : aucun VolumeAttachment n'est jamais créé pour ses volumes, et `kubectl get volumeattachments` reste vide même avec la StatefulSet `redis` en marche. Sur un cluster de nuage dont le pilote attache des disques, chaque volume monté y a sa ligne, et un VolumeAttachment bloqué (`ATTACHED false`) est la première chose à regarder quand un pod reste en `ContainerCreating` avec un événement `FailedAttachVolume`.

### 18.4 Étendre l'API : admission et agrégation

#### 18.4.1 La chaîne d'admission

Le [chapitre 2](02-architecture.md) a suivi une requête jusqu'à etcd et le [chapitre 8](08-ordonnancement-et-admission.md) a présenté les contrôleurs d'admission intégrés. Deux phases les encadrent : la phase **mutante**, qui peut modifier l'objet, puis, après la validation du schéma, la phase **validante**, qui ne peut qu'accepter ou refuser. Les points d'extension s'insèrent à la fin de chaque phase, dans cet ordre fixé par l'API server 1.37 :

```
requête authentifiée et autorisée
   │
   ▼ ADMISSION MUTANTE
   │  plugins intégrés (NamespaceLifecycle, LimitRanger, ServiceAccount,
   │  DefaultStorageClass, RuntimeClass…)
   │  → MutatingAdmissionPolicy (CEL)
   │  → webhooks mutants (réinvoqués si reinvocationPolicy: IfNeeded)
   ▼
   validation du schéma de l'objet (OpenAPI, CEL des CRD)
   │
   ▼ ADMISSION VALIDANTE
   │  plugins intégrés (PodSecurity…)
   │  → ValidatingAdmissionPolicy (CEL)
   │  → webhooks validants (appelés en parallèle)
   │  → ResourceQuota (toujours en dernier)
   ▼
   etcd
```

Les plugins actifs par défaut en 1.37 sont : `CertificateApproval`, `CertificateSigning`, `CertificateSubjectRestriction`, `DefaultIngressClass`, `DefaultStorageClass`, `DefaultTolerationSeconds`, `LimitRanger`, `MutatingAdmissionPolicy`, `MutatingAdmissionWebhook`, `NamespaceLifecycle`, `PersistentVolumeClaimResize`, `PodSecurity`, `Priority`, `ResourceQuota`, `RuntimeClass`, `ServiceAccount`, `StorageObjectInUseProtection`, `TaintNodesByCondition`, `ValidatingAdmissionPolicy`, `ValidatingAdmissionWebhook`. L'option `--enable-admission-plugins` de l'API server **ajoute** des plugins à cette liste, elle ne la remplace pas ; `--disable-admission-plugins` en retire.

#### 18.4.2 Les webhooks d'admission

Un webhook est un service HTTPS que l'API server appelle avec un objet `AdmissionReview` et qui répond `allowed: true|false`, avec un patch JSON pour un webhook mutant. On le déclare dans une `MutatingWebhookConfiguration` ou une `ValidatingWebhookConfiguration` (`admissionregistration.k8s.io/v1`, objets de cluster), qui contiennent une liste `webhooks`. Voici, en substance, celle de cert-manager :

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: cert-manager-webhook
  annotations:
    cert-manager.io/inject-ca-from-secret: cert-manager/cert-manager-webhook-ca
webhooks:
- name: webhook.cert-manager.io
  rules:                                  # quelles requêtes sont envoyées
  - apiGroups: ["cert-manager.io", "acme.cert-manager.io"]
    apiVersions: ["v1"]
    operations: ["CREATE", "UPDATE"]
    resources: ["*/*"]
  namespaceSelector:                      # on peut exclure un namespace par label
    matchExpressions:
    - key: cert-manager.io/disable-validation
      operator: NotIn
      values: ["true"]
  clientConfig:
    service:                              # ou url: https://…
      name: cert-manager-webhook
      namespace: cert-manager
      path: /validate                     # port 443 par défaut
    # caBundle: rempli par le cainjector de cert-manager
  admissionReviewVersions: ["v1"]         # obligatoire
  sideEffects: None                       # obligatoire : None ou NoneOnDryRun
  failurePolicy: Fail                     # défaut Fail
  matchPolicy: Equivalent                 # défaut Equivalent
  timeoutSeconds: 30                      # défaut 10, de 1 à 30
```

Les champs se lisent ainsi. `rules` sélectionne opérations, groupes, versions et ressources (`pods`, `pods/status`, `*/scale`…) ; une règle sur `deployments` ne couvre pas la sous-ressource `deployments/scale`. `namespaceSelector` et `objectSelector` restreignent par labels ; `matchConditions` (jusqu'à 64 expressions CEL) affine encore. `clientConfig` désigne un Service du cluster ou une URL ; `caBundle` est la CA qui a signé le certificat du webhook, que l'API server exige. `failurePolicy` dit quoi faire si le webhook est **injoignable** ou répond de travers : `Fail` refuse la requête, `Ignore` la laisse passer. Un refus explicite (`allowed: false`) s'applique toujours, quelle que soit la politique. `timeoutSeconds` vaut 10 s par défaut. Pour un webhook mutant, `reinvocationPolicy: IfNeeded` le rappelle si un autre webhook a modifié l'objet après lui.

> [!danger] Le webhook qui bloque le cluster
> Un webhook en `failurePolicy: Fail` dont le Service n'a plus de pod prêt fait échouer **toutes** les requêtes qu'il couvre, avec `failed calling webhook "…"`. Si ses règles couvrent les pods ou les namespaces, plus rien ne se déploie, pas même le pod qui le réparerait. Le diagnostic commence par `kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations` ; le remède d'urgence est de supprimer la configuration (ou de passer sa politique à `Ignore`), puis de réparer le service. L'exercice 18.9 le provoque sur cert-manager.

#### 18.4.3 Les politiques d'admission en CEL

Écrire, héberger et sécuriser un webhook pour vérifier qu'un champ est inférieur à 5 est disproportionné. Les politiques d'admission font le même travail **dans l'API server**, avec des expressions CEL (Common Expression Language) :

| | ValidatingAdmissionPolicy | MutatingAdmissionPolicy |
|---|---|---|
| Statut en 1.37 | GA depuis 1.30 | GA depuis 1.36, active par défaut |
| API | `admissionregistration.k8s.io/v1` | `admissionregistration.k8s.io/v1` |
| Objets | `ValidatingAdmissionPolicy` + `ValidatingAdmissionPolicyBinding` | `MutatingAdmissionPolicy` + `MutatingAdmissionPolicyBinding` |
| Contenu | `validations[].expression` (vrai = accepté), `message`, `messageExpression`, `reason` | `mutations[]` : *apply configuration* (fusion façon server-side apply) ou JSON Patch |
| Action | dans le binding : `validationActions` = `Deny`, `Warn`, `Audit` (`Deny` et `Warn` sont exclusifs) | la mutation est appliquée |

Une politique sans binding n'a aucun effet : la politique décrit la logique et ce qu'elle intercepte (`matchConstraints`), le binding l'active et la restreint (`matchResources`), éventuellement avec un objet de paramètres (`paramKind` dans la politique, `paramRef` dans le binding, par exemple une ConfigMap). Les expressions disposent de `object`, `oldObject`, `request`, `params`, `namespaceObject` et `authorizer`. Un refus se lit ainsi :

```
The deployments "front" is invalid: : ValidatingAdmissionPolicy 'recette-replicas-max' with binding 'recette-replicas-max' denied request: en recette, 2 réplicas au plus
```

Le `failurePolicy` de la politique (`Fail` par défaut) gouverne les erreurs d'évaluation (expression qui plante, paramètre introuvable), pas les refus. L'exercice 18.8 met une politique en place puis la retire.

#### 18.4.4 L'agrégation d'API

Une CRD ajoute un type dont l'API server gère lui-même le stockage. L'**agrégation** va plus loin : elle délègue un groupe-version entier à **un autre serveur d'API**, que l'API server principal (sa couche `kube-aggregator`) joint en proxy. On la déclare par un objet `APIService` :

```bash
kubectl get apiservices | grep -v Local
```

```
NAME                     SERVICE                      AVAILABLE   AGE
v1beta1.metrics.k8s.io   kube-system/metrics-server   True        …
```

Les APIService marqués `Local` sont servis par l'API server lui-même (groupes du cœur et CRD) ; `v1beta1.metrics.k8s.io` est servi par metrics-server ([chapitre 7](07-autoscaling.md)), qui calcule ses réponses à la volée au lieu de les stocker dans etcd. C'est le critère de choix : une CRD suffit pour stocker des objets déclaratifs ; un serveur agrégé se justifie pour des données calculées, un stockage propre, ou des sous-ressources que les CRD ne savent pas offrir. L'API server s'authentifie auprès des serveurs agrégés avec le certificat `front-proxy-client` (CA `front-proxy-ca`, présents dans `/var/lib/minikube/certs` sur le lab, `/etc/kubernetes/pki` sous kubeadm) et leur transmet l'identité de l'appelant dans des en-têtes.

Un APIService indisponible (`AVAILABLE False`) a des effets surprenants : `kubectl api-resources` affiche `unable to retrieve the complete list of server APIs`, et la suppression d'un namespace reste bloquée en `Terminating`, avec la condition `NamespaceDeletionDiscoveryFailure`, parce que le contrôleur de namespaces ne peut plus énumérer tous les types à vider.

#### 18.4.5 Device plugins et DRA (concepts)

Le kubelet ne connaît que le CPU, la mémoire, le stockage éphémère et les hugepages. Un **device plugin** (un DaemonSet du fabricant) s'enregistre par gRPC sur `/var/lib/kubelet/device-plugins/kubelet.sock` et annonce une **ressource étendue**, par exemple `example.com/gpu: 4`, qui apparaît dans `capacity` et `allocatable` du nœud. Un pod la demande dans `resources.limits` (entier, sans surréservation ; `requests`, si présent, doit être égal) ; le scheduler compte les unités et le plugin indique au kubelet quels périphériques monter.

La **Dynamic Resource Allocation** (DRA, `resource.k8s.io/v1`, GA depuis 1.34) généralise ce modèle : le pilote publie des `ResourceSlice` décrivant chaque périphérique et ses attributs, l'administrateur définit des `DeviceClass`, et un pod réclame un périphérique par une `ResourceClaim` (ou un `ResourceClaimTemplate`, une réclamation par pod) référencée dans `spec.resourceClaims` puis dans `resources.claims` du conteneur. Le scheduler choisit le périphérique selon des critères en CEL. Au CKA, savoir reconnaître ces objets suffit.

### 18.5 CustomResourceDefinitions

#### 18.5.1 Anatomie

Une CRD (`apiextensions.k8s.io/v1`, objet de cluster) déclare un nouveau type ; dès qu'elle est acceptée, l'API server sert les chemins REST correspondants, stocke les objets dans etcd et les expose à kubectl, au RBAC, aux watches, comme n'importe quel type intégré. Voici la CRD du fil rouge, que l'exercice 18.4 crée :

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: sauvegardes.boutique.example      # OBLIGATOIREMENT <pluriel>.<groupe>
spec:
  group: boutique.example                 # /apis/boutique.example/…
  scope: Namespaced                       # ou Cluster ; immuable une fois Established
  names:
    kind: Sauvegarde                      # CamelCase, utilisé dans les manifestes
    listKind: SauvegardeList              # défaut : <kind>List
    plural: sauvegardes                   # minuscules, dans l'URL
    singular: sauvegarde                  # défaut : kind en minuscules
    shortNames:
    - svg                                 # kubectl get svg
  versions:
  - name: v1
    served: true                          # exposée par l'API
    storage: true                         # format d'écriture dans etcd (une seule)
    subresources:
      status: {}                          # active /status (18.5.4)
    additionalPrinterColumns:             # colonnes de kubectl get (18.5.5)
    - name: Cible
      type: string
      jsonPath: .spec.cible
    - name: Planification
      type: string
      jsonPath: .spec.planification
    - name: Retention
      type: integer
      jsonPath: .spec.retention
    - name: Age
      type: date
      jsonPath: .metadata.creationTimestamp
    schema:
      openAPIV3Schema:                    # schéma structurel obligatoire (18.5.2)
        type: object
        properties:
          spec:
            type: object
            required:
            - cible
            properties:
              cible:
                type: string
              planification:
                type: string
              retention:
                type: integer
                minimum: 1
                maximum: 30
          status:
            type: object
            properties:
              derniereExecution:
                type: string
                format: date-time
```

Une fois la CRD créée, l'API server publie le type et pose deux conditions : `NamesAccepted` (les noms n'entrent pas en conflit avec un autre type) puis `Established` (le type est servi). Un script attend la seconde avec `kubectl wait --for=condition=Established crd/<nom>` avant de créer des objets, faute de quoi il obtient `no matches for kind "Sauvegarde"`. Les groupes qui se terminent par `.k8s.io` ou `.kubernetes.io` sont réservés au projet : une CRD dans ces groupes exige l'annotation `api-approved.kubernetes.io`, d'où des groupes comme `boutique.example` ou `cert-manager.io` pour tout le reste.

```bash
kubectl api-resources --api-group=boutique.example
```

```
NAME          SHORTNAMES   APIVERSION            NAMESPACED   KIND
sauvegardes   svg          boutique.example/v1   true         Sauvegarde
```

Supprimer une CRD supprime **toutes** ses ressources, dans tous les namespaces : l'API server pose sur la CRD le finalizer `customresourcecleanup.apiextensions.k8s.io`, vide les objets, puis retire le type. Supprimer un namespace supprime, comme pour les types intégrés, les ressources personnalisées qu'il contient.

#### 18.5.2 Le schéma structurel et l'élagage

En `apiextensions.k8s.io/v1`, chaque version doit porter un **schéma structurel** : un sous-ensemble d'OpenAPI v3 où chaque nœud a un `type` (`object`, `array`, `string`, `integer`, `number`, `boolean`), où chaque champ est déclaré par `properties` (ou `additionalProperties` pour une map) et chaque élément de liste par `items`, et où les connecteurs `allOf`, `anyOf`, `oneOf`, `not` ne peuvent que restreindre des champs déjà déclarés en dehors d'eux. Un schéma qui enfreint ces règles est signalé par la condition `NonStructuralSchema`. Quelques mots-clés sont interdits (`$ref`, `definitions`, `patternProperties`, `additionalProperties: false`, `uniqueItems: true`…).

Le schéma structurel rend possible l'**élagage** (*pruning*) : un champ inconnu du schéma est supprimé avant l'écriture dans etcd, comme pour un type intégré. En pratique, kubectl le refuse avant : sa validation stricte par défaut (`--validate=strict`) fait rejeter par l'API server un manifeste qui contient `spec.retentionn` (`strict decoding error: unknown field "spec.retentionn"`). Avec `--validate=false`, l'objet est accepté et le champ disparaît silencieusement.

Les extensions `x-kubernetes-*` complètent OpenAPI pour les besoins de Kubernetes :

| Extension | Effet |
|---|---|
| `x-kubernetes-preserve-unknown-fields: true` | désactive l'élagage sous ce nœud (JSON libre) |
| `x-kubernetes-int-or-string: true` | accepte un entier ou une chaîne (comme `targetPort`) |
| `x-kubernetes-embedded-resource: true` | le nœud est un objet Kubernetes complet (`apiVersion`, `kind`, `metadata` validés) |
| `x-kubernetes-list-type: atomic \| set \| map` | sémantique de liste pour server-side apply ; `map` avec `x-kubernetes-list-map-keys` |
| `x-kubernetes-map-type: granular \| atomic` | idem pour une map |
| `x-kubernetes-validations` | règles CEL (18.5.3) |

Un `default` dans le schéma est appliqué à la création, à la lecture depuis etcd et après les webhooks mutants ; les valeurs par défaut appliquées à la lecture ne sont réécrites dans etcd qu'à la prochaine mise à jour de l'objet.

#### 18.5.3 Valider : OpenAPI puis CEL

Les mots-clés OpenAPI couvrent les cas simples : `required`, `minimum`/`maximum`, `minLength`/`maxLength`, `pattern`, `enum`, `minItems`/`maxItems`, `format` (`date-time`, `int32`…). Leur message d'erreur est fixe :

```
The Sauvegarde "redis-hebdo" is invalid: spec.retention: Invalid value: 99: spec.retention in body should be less than or equal to 30
```

Pour tout le reste, `x-kubernetes-validations` (GA depuis 1.29) accepte des règles CEL évaluées par l'API server. La variable `self` désigne le nœud où la règle est posée, et `oldSelf` sa valeur avant une mise à jour :

```yaml
spec:
  type: object
  properties:
    cible:
      type: string
      maxLength: 253                         # borne le coût estimé de la comparaison
      x-kubernetes-validations:
      - rule: "self == oldSelf"              # règle de transition : cible immuable
        message: "cible est immuable"
    planification:
      type: string
      maxLength: 64                          # borne le coût estimé de la règle
      x-kubernetes-validations:
      - rule: "self.split(' ').size() == 5"
        message: "planification : cinq champs cron séparés par une espace"
```

| Champ d'une règle | Rôle |
|---|---|
| `rule` | expression CEL qui doit valoir `true` |
| `message` / `messageExpression` | message fixe / message calculé en CEL |
| `reason` | `FieldValueInvalid` (défaut), `FieldValueForbidden`, `FieldValueRequired`, `FieldValueDuplicate` |
| `fieldPath` | champ à désigner dans l'erreur, s'il diffère du nœud de la règle |
| `optionalOldSelf` | évalue aussi la règle de transition à la création (`oldSelf` vide) |

Une règle qui mentionne `oldSelf` est une **règle de transition** : elle ne s'évalue qu'en mise à jour, quand l'ancienne et la nouvelle valeur existent. L'API server estime le coût de chaque règle quand on crée la CRD et refuse une règle potentiellement trop chère ; pour une chaîne ou une liste parcourue, borner sa taille (`maxLength`, `maxItems`) est la bonne pratique. Depuis 1.33, le *ratcheting* (GA) laisse passer la mise à jour d'un objet devenu invalide après un durcissement du schéma, tant que la partie invalide n'est pas modifiée ; les règles de transition n'en bénéficient pas.

#### 18.5.4 Sous-ressources

Avec `subresources.status: {}`, le champ `status` ne se modifie plus que par la sous-ressource `/status` : un `PUT` ou `PATCH` sur l'objet ignore `status`, un `PUT` ou `PATCH` sur `/status` ignore tout le reste. C'est ce qui sépare les rôles : l'utilisateur écrit `spec`, le contrôleur écrit `status`, et le RBAC les distingue (`sauvegardes` contre `sauvegardes/status`). `metadata.generation` n'augmente qu'avec les changements de `spec` ; un contrôleur recopie la génération traitée dans `status.observedGeneration` pour signaler qu'il est à jour. kubectl sait viser la sous-ressource :

```bash
kubectl -n boutique patch sauvegarde redis-quotidienne --subresource=status \
  --type=merge -p '{"status":{"derniereExecution":"2026-10-23T02:00:00Z"}}'
```

`subresources.scale` (avec `specReplicasPath`, `statusReplicasPath`, `labelSelectorPath`) expose `/scale` : `kubectl scale` et un HorizontalPodAutoscaler fonctionnent alors sur la ressource personnalisée.

#### 18.5.5 Présentation

`additionalPrinterColumns` définit les colonnes de `kubectl get` : `name`, `type` (`string`, `integer`, `number`, `boolean`, `date`, rendue en âge), `jsonPath`, `priority` (0 : affichée ; plus : seulement avec `-o wide`). La colonne NAME est implicite. `names.shortNames` donne les abréviations, `names.categories` range le type dans des catégories (`kubectl get all` n'affiche une ressource personnalisée que si sa CRD déclare la catégorie `all`). `selectableFields` (GA depuis 1.32) déclare des champs utilisables avec `--field-selector`. Enfin, kubectl lit le schéma publié : `kubectl explain sauvegarde.spec` documente les champs, avec leur `description` si la CRD en fournit.

#### 18.5.6 Versions et conversion

Une CRD peut servir plusieurs versions (`v1alpha1`, `v1`) ; chacune a son schéma et ses drapeaux `served` (exposée) et `storage` (format d'écriture, **une seule** à la fois). Quand on lit un objet dans une version différente de celle où il est stocké, l'API server le convertit selon `spec.conversion.strategy` : `None` (défaut) se contente de changer `apiVersion` et suppose des schémas compatibles ; `Webhook` appelle un service de conversion (`conversion.webhook.clientConfig`, `conversionReviewVersions`). kubectl choisit la version de plus haute priorité (`v2` > `v1` > `v1beta1` > `v1alpha1`) quand le manifeste ne précise rien.

`status.storedVersions` liste toutes les versions dans lesquelles des objets ont **pu** être écrits. On ne retire une version de `spec.versions` qu'après l'avoir sortie de cette liste, c'est-à-dire après avoir réécrit tous les objets dans la nouvelle version de stockage. En 1.37, la migration de version de stockage est GA (`storagemigration.k8s.io/v1`, objet `StorageVersionMigration`) et met `storedVersions` à jour à la fin ; à défaut, on relit et réécrit chaque objet puis on corrige le statut de la CRD par `kubectl patch crd <nom> --subresource=status`. Une version peut être marquée `deprecated: true` avec un `deprecationWarning`, que kubectl affiche à chaque usage.

### 18.6 Contrôleurs et patron opérateur

Une CRD seule ne fait rien : la ressource `redis-quotidienne` est un enregistrement dans etcd, que personne ne lit. Le comportement vient d'un **contrôleur**, programme qui surveille des objets par *watch* et agit pour que le monde réel corresponde à leur `spec`, exactement comme le contrôleur de Deployments crée des ReplicaSets ([chapitre 2](02-architecture.md)).

```
Boucle de réconciliation
════════════════════════

        ┌──────────────── watch (informer, cache local) ◀──── API server
        │                                                         ▲
        ▼                                                         │
  file de travail (clé ns/nom, dédoublonnée)                      │
        │                                                         │
        ▼                                                         │
  reconcile(ns/nom) :                                             │
    1. lire l'état voulu  (spec de la ressource)                  │
    2. lire l'état réel   (objets enfants, système externe)       │
    3. agir pour réduire l'écart (créer, modifier, supprimer) ────┤
    4. écrire status (conditions, observedGeneration) ────────────┘
    5. en cas d'erreur : remise en file avec délai croissant
```

Trois propriétés font un bon contrôleur. Il est **déclenché par niveau**, pas par événement : il compare l'état voulu à l'état réel à chaque passage, si bien qu'un événement perdu ou un redémarrage ne fait rien manquer. Il est **idempotent** : rejouer la réconciliation sur un état déjà conforme ne change rien. Il **rend compte** dans `status`, avec des conditions standard (`Ready`, `Reason`, `Message`). Pour le reste, il s'appuie sur les mécanismes du [chapitre 2](02-architecture.md) : `ownerReferences` sur ses objets enfants (le ramasse-miettes les supprime avec le parent), `finalizers` pour nettoyer une ressource externe avant la suppression, élection de leader par Lease quand il tourne en plusieurs réplicas.

Un **opérateur** est un contrôleur qui encode le savoir-faire d'un exploitant sur une application précise : ses CRD décrivent l'application dans les termes de l'exploitant (une base, ses sauvegardes, sa version), et sa boucle de réconciliation applique ce qu'un humain ferait (créer, mettre à jour, sauvegarder, basculer). On les écrit le plus souvent avec controller-runtime (Kubebuilder, Operator SDK). On les installe par un chart Helm, par un manifeste unique publié avec chaque version, ou par Operator Lifecycle Manager (OLM) sur les distributions qui l'embarquent. Installer un opérateur, c'est donc toujours installer trois choses : des **CRD**, un **contrôleur** (Deployment) avec son **RBAC**, souvent des **webhooks** ; le configurer, c'est créer ses ressources personnalisées.

### 18.7 cert-manager, un opérateur complet

cert-manager automatise la délivrance et le renouvellement de certificats X.509 dans Kubernetes. Il illustre tout ce chapitre : six CRD, un contrôleur, un webhook d'admission, un injecteur de CA, et des Secrets qu'il maintient en vie.

#### 18.7.1 Les composants

| Composant | Deployment (namespace `cert-manager`) | Rôle |
|---|---|---|
| contrôleur | `cert-manager` | réconcilie Issuers, Certificates, CertificateRequests, Orders et Challenges ACME ; élection de leader par Lease dans `kube-system` |
| webhook | `cert-manager-webhook` | valide (`ValidatingWebhookConfiguration`) et complète (`MutatingWebhookConfiguration`, sur la création des CertificateRequests) les ressources de cert-manager |
| cainjector | `cert-manager-cainjector` | remplit le `caBundle` des webhooks (annotation `cert-manager.io/inject-ca-from-secret`), des APIService et des conversions de CRD |
| startupapicheck | Job, hook Helm `post-install` | vérifie que l'API de cert-manager répond, puis disparaît |

| CRD | Groupe | Portée | Abréviations |
|---|---|---|---|
| `issuers.cert-manager.io` | `cert-manager.io` | Namespaced | `iss` |
| `clusterissuers.cert-manager.io` | `cert-manager.io` | Cluster | `ciss` |
| `certificates.cert-manager.io` | `cert-manager.io` | Namespaced | `cert`, `certs` |
| `certificaterequests.cert-manager.io` | `cert-manager.io` | Namespaced | `cr`, `crs` |
| `orders.acme.cert-manager.io` | `acme.cert-manager.io` | Namespaced | — |
| `challenges.acme.cert-manager.io` | `acme.cert-manager.io` | Namespaced | — |

Le chart pose aussi des ClusterRoles agrégées : `cert-manager-view` porte les labels `rbac.authorization.k8s.io/aggregate-to-view`, `aggregate-to-edit` et `aggregate-to-admin`, si bien qu'un utilisateur lié au rôle `view` d'un namespace lit ses Certificates sans autre configuration. L'exercice 18.7 applique le même mécanisme aux sauvegardes.

#### 18.7.2 Issuer et ClusterIssuer

Un **émetteur** décrit une autorité capable de signer. `Issuer` est namespacé et ne sert que les Certificates de son namespace ; `ClusterIssuer` sert tout le cluster, et les Secrets qu'il référence (la clé d'une CA, un jeton) sont cherchés dans le *cluster resource namespace*, `cert-manager` par défaut (option `--cluster-resource-namespace` du contrôleur). Les types intégrés sont `selfSigned` (le certificat est signé par sa propre clé), `ca` (une CA dont la clé est dans un Secret), `acme` (Let's Encrypt et consorts, défis HTTP-01 ou DNS-01), `vault` et `venafi` ; d'autres émetteurs s'ajoutent comme contrôleurs externes.

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: autosigne
spec:
  selfSigned: {}
```

Un émetteur `selfSigned` est prêt immédiatement (condition `Ready=True`). Il sert surtout à amorcer une PKI (émettre une CA, puis un émetteur `ca` qui s'en sert) ou à des tests. Un certificat auto-signé n'a pas de DN d'émetteur si son sujet est vide : cert-manager le signale par un événement `BadConfig` sur la CertificateRequest (`Certificate will be issued with an empty Issuer DN, which contravenes RFC 5280…`). Renseigner `commonName` (ou `subject`) l'évite.

#### 18.7.3 Du Certificate au Secret

Une ressource **Certificate** décrit le certificat voulu ; cert-manager produit et entretient le Secret qui le contient.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: boutique-gw
  namespace: boutique
spec:
  secretName: boutique-gw-tls          # obligatoire : Secret produit, même namespace
  commonName: gw.boutique.example      # sujet non vide (cf. 18.7.2)
  dnsNames:
  - gw.boutique.example
  issuerRef:                           # obligatoire
    name: autosigne
    kind: ClusterIssuer                # défaut : Issuer
    group: cert-manager.io             # défaut : cert-manager.io
  # duration: 2160h                    # défaut : 90 jours (minimum 1 h)
  # renewBefore: 720h                  # défaut : 1/3 de la durée effective
  # privateKey: {algorithm: RSA, size: 2048, rotationPolicy: Always}  # défauts
```

```
Réconciliation d'un Certificate
═══════════════════════════════

 Certificate boutique-gw ─┐
                          │ 1. trigger : le Secret n'existe pas → Issuing=True
                          │    (« Issuing certificate as Secret does not exist »)
                          ▼
 Secret temporaire boutique-gw-xxxxx  ← 2. key manager : nouvelle clé privée
                          │
                          ▼ 3. request manager : CSR signée par cette clé
 CertificateRequest boutique-gw-1 (annotation de révision 1, ownerRef → Certificate)
                          │ 4. approbateur interne → Approved=True
                          │ 5. contrôleur de l'émetteur selfSigned → signe, Ready=True
                          ▼
 Secret boutique-gw-tls   ← 6. issuing : tls.crt, tls.key, ca.crt
   type kubernetes.io/tls      annotations cert-manager.io/certificate-name,
                               cert-manager.io/issuer-name…
                          │
                          ▼ 7. Certificate : Ready=True, revision=1,
 consommateurs              notBefore, notAfter, renewalTime
 (Gateway, Ingress, pods)
```

Le nom de la CertificateRequest est stable : `<certificate>-<révision>`. `spec.revisionHistoryLimit` vaut 1 par défaut : à la révision suivante, la précédente est supprimée. Le contrôleur recommence le cycle dans trois cas : le Secret disparaît ou ne correspond plus à la `spec` (nom DNS ajouté, émetteur changé), ou l'heure `renewalTime` arrive (`notAfter` moins `renewBefore`, soit le dernier tiers de la validité par défaut). Depuis cert-manager 1.18, `privateKey.rotationPolicy` vaut `Always` : chaque réémission génère une nouvelle clé. Supprimer le Certificate ne supprime pas son Secret, sauf si le contrôleur tourne avec `--enable-certificate-owner-ref`.

#### 18.7.4 Certificats automatiques et dépannage

Pour un Ingress, l'annotation `cert-manager.io/cluster-issuer: <nom>` (ou `cert-manager.io/issuer`) suffit : le composant *ingress-shim* du contrôleur crée un Certificate pour chaque entrée `tls` de l'Ingress. Le même mécanisme existe pour les Gateways, mais il doit être activé (valeur Helm `config.gatewayAPI.enabled=true`) ; ce chapitre décrit le Certificate explicitement, ce qui marche sans réglage et montre chaque étape. Si tu actives l'intégration par `helm upgrade`, souviens-toi de la section 17.6.1 ([chapitre 17](17-helm-et-kustomize.md)) : sans `--reuse-values`, `crds.enabled` retomberait à sa valeur par défaut.

Le dépannage suit la chaîne du schéma ci-dessus, de haut en bas : `kubectl describe certificate` (conditions et événements), puis la CertificateRequest de la révision en cours (`Approved`, `Ready`, message), puis l'émetteur (`kubectl describe clusterissuer`), enfin les journaux du contrôleur (`kubectl -n cert-manager logs deploy/cert-manager`). Un refus à la création d'une ressource de cert-manager qui mentionne `failed calling webhook "webhook.cert-manager.io"` désigne, lui, le webhook (18.4.2). L'outil `cmctl` simplifie tout cela, mais il n'existe pas à l'examen.

### 18.8 Pièges courants

```
Piège 1 : crictl sans sudo, ou depuis le mauvais nœud
═════════════════════════════════════════════════════
  SYMPTÔME : « connect: permission denied » sur containerd.sock,
             ou un conteneur introuvable.
  BON      : sudo crictl … sur le nœud qui héberge le pod
             (kubectl get pod -o wide pour le trouver).

Piège 2 : runtimeClassName vers une classe ou un handler inconnus
═════════════════════════════════════════════════════════════════
  SYMPTÔME : « pod rejected: RuntimeClass "x" not found » (classe absente),
             ou ContainerCreating + FailedCreatePodSandBox
             « no runtime for "y" is configured » (handler absent du runtime).
  BON      : kubectl get runtimeclass ; handler = nom de la section
             runtimes.<handler> de la config de containerd.

Piège 3 : Nom de CRD incohérent
═══════════════════════════════
  MAUVAIS  : metadata.name: sauvegarde.boutique.example (singulier)
  SYMPTÔME : la CRD est refusée : le nom doit être <spec.names.plural>.<spec.group>.
  BON      : sauvegardes.boutique.example.

Piège 4 : Créer une ressource avant que la CRD soit Established
═══════════════════════════════════════════════════════════════
  SYMPTÔME : « no matches for kind "Sauvegarde" in version … » dans un script.
  BON      : kubectl wait --for=condition=Established crd/<nom>.

Piège 5 : Modifier status sans la sous-ressource
═════════════════════════════════════════════════
  SYMPTÔME : « patched (no change) » : le status est ignoré.
  BON      : kubectl patch … --subresource=status.

Piège 6 : Filtrer les CRD d'un groupe avec grep
════════════════════════════════════════════════
  MAUVAIS  : kubectl get crd | grep cert-manager.io
  SYMPTÔME : orders/challenges.acme.cert-manager.io comptés à tort.
  BON      : jsonpath sur .spec.group=="cert-manager.io".

Piège 7 : Une politique qui oublie les sous-ressources
══════════════════════════════════════════════════════
  SYMPTÔME : la VAP refuse un patch de spec.replicas mais laisse passer
             kubectl scale.
  CAUSE    : resources: ["deployments"] ne couvre pas deployments/scale.
  BON      : ajouter la sous-ressource aux règles, en connaissance de
             cause (l'objet reçu est alors un Scale).

Piège 8 : Le webhook en failurePolicy Fail sans pod prêt
═════════════════════════════════════════════════════════
  SYMPTÔME : « failed calling webhook … » à chaque création concernée.
  BON      : rétablir les pods derrière le Service du webhook ; en
             urgence, supprimer la WebhookConfiguration, puis la
             réinstaller (helm upgrade, ou manifeste de l'opérateur).

Piège 9 : Basculer un Gateway sur un Secret qui n'existe pas encore
═══════════════════════════════════════════════════════════════════
  SYMPTÔME : listener https ResolvedRefs=False (InvalidCertificateRef),
             plus de TLS sur ce listener.
  BON      : attendre Certificate Ready=True avant de changer certificateRefs.
```

> [!summary] À retenir
> - Le kubelet parle au runtime par la CRI (gRPC sur `containerRuntimeEndpoint`) ; c'est le runtime qui appelle la CNI en créant la sandbox ; `crictl` (avec `sudo`) interroge le runtime sans l'API server.
> - Une RuntimeClass (`node.k8s.io/v1`) relie `spec.runtimeClassName` à un handler de la configuration CRI ; classe absente : pod refusé à l'admission ; handler absent : `FailedCreatePodSandBox`.
> - CSI se lit dans l'API par CSIDriver (comportement du pilote), CSINode (pilotes enregistrés par nœud) et VolumeAttachment (seulement si `attachRequired` est vrai).
> - Admission : mutation (plugins, MutatingAdmissionPolicy, webhooks mutants), validation du schéma, puis validation (plugins, ValidatingAdmissionPolicy, webhooks validants, ResourceQuota). VAP GA depuis 1.30, MAP GA depuis 1.36 ; webhooks : `failurePolicy` `Fail` et `timeoutSeconds` 10 par défaut.
> - L'agrégation (APIService) délègue un groupe-version à un autre serveur ; un APIService indisponible bloque la suppression des namespaces.
> - Une CRD s'appelle `<pluriel>.<groupe>`, exige un schéma structurel, élague les champs inconnus, valide par OpenAPI et par CEL (`x-kubernetes-validations`, `oldSelf` pour les transitions) et ne stocke qu'une version (`storage: true`).
> - Avec `subresources.status`, seul `/status` modifie le statut ; kubectl le vise par `--subresource=status`.
> - Un opérateur = CRD + contrôleur (RBAC, souvent webhooks) qui réconcilie par niveau et rend compte dans `status`.
> - cert-manager : Issuer (namespace) ou ClusterIssuer (cluster) → Certificate → CertificateRequest `<nom>-<révision>` → Secret `kubernetes.io/tls` ; supprimer le Secret déclenche une réémission ; durée 90 jours et renouvellement au dernier tiers par défaut.

### 18.9 Exercices

Les manifestes de ce chapitre vont dans `~/cka/extensions/`, `~/cka/crd/` et `~/cka/cert-manager/`.

#### Exercice 18.1 — Le runtime vu du nœud

**Point de départ** : exercice 17.9.

Sur le nœud `cka-m02`, sans utiliser kubectl : affiche la version du runtime et de l'API CRI, liste les sandboxes du namespace `boutique` avec leur handler, retrouve le conteneur `nginx` d'un pod `front` et affiche ses dix dernières lignes de journal. Retrouve enfin, dans la configuration de containerd, le nom du handler par défaut et le pilote de cgroups de runc.

> [!example]- Solution
> ```bash
> kubectl -n boutique get pods -l app=front -o wide     # depuis le poste : où sont les pods ?
> minikube -p cka ssh -n cka-m02
> sudo crictl version
> sudo crictl pods --namespace '^boutique$'
> sudo crictl ps --name nginx --namespace '^boutique$'
> sudo crictl logs --tail 10 $(sudo crictl ps --name nginx --namespace '^boutique$' -q | head -1)
> grep -n -E 'default_runtime_name|runtimes.runc\]|SystemdCgroup' /etc/containerd/config.toml
> exit
> ```
>
> `crictl version` donne `RuntimeName: containerd` et `RuntimeApiVersion: v1`. La colonne RUNTIME de `crictl pods` affiche `(default)` pour les pods qui n'ont pas de RuntimeClass. Les filtres `--namespace` et `--name` de crictl sont des expressions régulières : `--namespace boutique` ramènerait aussi le pod `front` de `boutique-recette` ([chapitre 17](17-helm-et-kustomize.md)), dont le conteneur s'appelle lui aussi `nginx`, d'où l'ancrage `'^boutique$'`. La liste des sandboxes contient aussi des lignes `NotReady` : celles des pods de Job terminés (`rapport-…`) et, si le nœud a redémarré (`minikube -p cka stop` puis `start`), les anciennes sandboxes (ATTEMPT 0) des pods qu'il héberge. Si `crictl ps` ne renvoie que la ligne d'en-tête, aucun pod `front` de `boutique` ne tourne sur ce nœud (la topologySpreadConstraint du [chapitre 8](08-ordonnancement-et-admission.md) répartit sur les zones, pas sur chaque nœud) : refais l'exercice sur le nœud indiqué par `-o wide`. Le conteneur `nginx` de `front-v2` porte le même nom ; `crictl ps --name nginx --pod <id>` lève l'ambiguïté. Le fichier de configuration est au format version 2 sur minikube (18.2.2).
>
> **Vérification** : `grep` affiche `default_runtime_name = "runc"`, la section `[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]` et `SystemdCgroup = true` ; `sudo crictl pods --namespace boutique` liste au moins le pod `agent-noeud-…` du nœud, avec `(default)` en dernière colonne.

#### Exercice 18.2 — La RuntimeClass `runc-standard`

**Point de départ** : exercice 18.1.

Crée la RuntimeClass `runc-standard`, de handler `runc`. Lance dans `boutique` un pod temporaire `test-runc` (busybox:1.37.0, `sleep 3600`) qui l'utilise, placé sur `cka-m02` et conforme au profil `restricted` de Pod Security. Montre, côté API et côté nœud, quel handler il utilise. Montre ensuite ce qui arrive à un pod qui réclame une RuntimeClass `inexistante`. Supprime le pod `test-runc` ; garde la RuntimeClass.

> [!example]- Solution
> ```yaml
> # ~/cka/extensions/runtimeclass.yaml
> apiVersion: node.k8s.io/v1
> kind: RuntimeClass
> metadata:
>   name: runc-standard
> handler: runc
> ```
>
> ```yaml
> # ~/cka/extensions/test-runc.yaml
> apiVersion: v1
> kind: Pod
> metadata:
>   name: test-runc
>   namespace: boutique
>   labels:
>     app: test-runc
>     tier: outils
> spec:
>   runtimeClassName: runc-standard
>   nodeSelector:
>     kubernetes.io/hostname: cka-m02
>   securityContext:
>     runAsNonRoot: true
>     runAsUser: 65534
>     seccompProfile:
>       type: RuntimeDefault
>   containers:
>   - name: test
>     image: busybox:1.37.0
>     command: ["sleep", "3600"]
>     securityContext:
>       allowPrivilegeEscalation: false
>       capabilities:
>         drop: ["ALL"]
> ```
>
> ```bash
> mkdir -p ~/cka/extensions
> kubectl apply -f ~/cka/extensions/runtimeclass.yaml
> kubectl apply -f ~/cka/extensions/test-runc.yaml
> kubectl -n boutique wait --for=condition=Ready pod/test-runc --timeout=60s
> kubectl get runtimeclass
> kubectl -n boutique get pod test-runc -o jsonpath='{.spec.runtimeClassName}{"\n"}'
> kubectl get node cka-m02 -o jsonpath='{range .status.runtimeHandlers[*]}"{.name}"{"\n"}{end}'
> minikube -p cka ssh -n cka-m02 -- sudo crictl pods --name test-runc
> kubectl -n boutique run rc-inconnue --image=busybox:1.37.0 \
>   --overrides='{"apiVersion":"v1","spec":{"runtimeClassName":"inexistante"}}' -- sleep 60
> kubectl -n boutique delete pod test-runc --now
> ```
>
> Le `securityContext` respecte le profil `restricted` : le namespace `boutique` l'audite et en avertit (`warn=restricted`, [chapitre 8](08-ordonnancement-et-admission.md)), un pod qui ne le respecterait pas serait créé avec un avertissement. Les requests et limits viennent de la LimitRange `boutique-limites`. Le pod `rc-inconnue` n'est jamais créé : le contrôleur d'admission `RuntimeClass` le refuse. `--now` évite les 30 secondes du délai de grâce, que `sleep` en PID 1 ignore.
>
> **Vérification** : `kubectl get runtimeclass` affiche `runc-standard   runc` ; le jsonpath du pod affiche `runc-standard` ; le nœud déclare `""` et `"runc"` ; `crictl pods` affiche `runc` dans la colonne RUNTIME pour `test-runc` ; la création de `rc-inconnue` échoue avec `Error from server (Forbidden): pods "rc-inconnue" is forbidden: pod rejected: RuntimeClass "inexistante" not found`.

#### Exercice 18.3 — Inventaire des points d'extension

**Point de départ** : exercice 18.2.

Sans rien modifier, réponds par des commandes : quels pilotes CSI le cluster connaît-il, et exigent-ils l'attachement ? Combien de pilotes chaque nœud a-t-il enregistrés ? Existe-t-il des VolumeAttachments, et pourquoi ? Quels groupes d'API sont servis par un autre serveur que l'API server ? Quelles configurations de webhooks sont installées ? Où le kubelet de `cka-m02` trouve-t-il le socket d'enregistrement du pilote CSI ?

> [!example]- Solution
> ```bash
> kubectl get csidrivers
> kubectl get csinodes
> kubectl get csinode cka-m02 -o jsonpath='{.spec.drivers[*].name}{"\n"}'
> kubectl get volumeattachments
> kubectl get apiservices | grep -v Local
> kubectl get mutatingwebhookconfigurations,validatingwebhookconfigurations
> minikube -p cka ssh -n cka-m02 -- sudo ls /var/lib/kubelet/plugins_registry/
> ```
>
> Le seul pilote est `hostpath.csi.k8s.io`, installé par l'addon du [chapitre 15](15-stockage.md), avec `ATTACHREQUIRED false` : le contrôleur attach/detach ne crée donc aucun VolumeAttachment, même pour le volume monté par `redis-0`. Chaque nœud a son CSINode, avec un pilote (le DaemonSet `csi-hostpathplugin` tourne partout). Le seul APIService non local est celui de metrics-server. Les webhooks visibles appartiennent aux composants installés : cert-manager (chapitre 17, un mutant et un validant), l'admission d'ingress-nginx (chapitre 12, validant) et l'injecteur de topologie d'Envoy Gateway (chapitre 13, mutant `envoy-gateway-topology-injector.envoy-gateway-system`).
>
> **Vérification** : `kubectl get csidrivers` affiche `hostpath.csi.k8s.io   false   true   true   <unset>   false   Persistent,Ephemeral` ; `kubectl get csinodes` affiche `1` dans la colonne DRIVERS pour `cka`, `cka-m02` et `cka-m03` ; `kubectl get volumeattachments` répond `No resources found` ; l'APIService `v1beta1.metrics.k8s.io` pointe vers `kube-system/metrics-server` avec `AVAILABLE True` ; le dossier `plugins_registry` contient un socket `hostpath.csi.k8s.io-reg.sock`.

#### Exercice 18.4 — La CRD `sauvegardes.boutique.example`

**Point de départ** : exercice 18.3.

Crée la CRD `sauvegardes.boutique.example` : groupe `boutique.example`, version `v1` servie et stockée, kind `Sauvegarde`, pluriel `sauvegardes`, abréviation `svg`, portée namespace. Le `spec` contient `cible` (chaîne, obligatoire), `planification` (chaîne) et `retention` (entier de 1 à 30) ; la sous-ressource `status` est active et `status` contient `derniereExecution` (date-heure). `kubectl get` doit afficher les colonnes Cible, Planification, Retention et Age.

> [!example]- Solution
> Enregistre dans `~/cka/crd/sauvegardes-crd.yaml` exactement le manifeste de la section 18.5.1, puis :
>
> ```bash
> mkdir -p ~/cka/crd
> kubectl apply -f ~/cka/crd/sauvegardes-crd.yaml
> kubectl wait --for=condition=Established crd/sauvegardes.boutique.example --timeout=60s
> kubectl api-resources --api-group=boutique.example
> kubectl explain sauvegarde.spec
> ```
>
> La documentation (page *Extend the Kubernetes API with CustomResourceDefinitions* de kubernetes.io) fournit un squelette à copier ; à l'examen, partir de là est plus sûr que de tout taper. Les points à ne pas manquer : le nom `<pluriel>.<groupe>`, `served` et `storage` à `true`, `type: object` à chaque niveau, `required` au niveau de `spec` (et non dans la propriété `cible`), `subresources` et `additionalPrinterColumns` au niveau de la **version**. Lancé dans la seconde qui suit, `kubectl explain` peut répondre `error: couldn't find resource for "boutique.example/v1, Resource=sauvegardes"` : l'API server publie le schéma OpenAPI de la nouvelle CRD quelques secondes après `Established`. Relance-le.
>
> **Vérification** : `kubectl wait` répond `customresourcedefinition.apiextensions.k8s.io/sauvegardes.boutique.example condition met` ; `kubectl api-resources --api-group=boutique.example` affiche `sauvegardes   svg   boutique.example/v1   true   Sauvegarde` ; `kubectl get crd sauvegardes.boutique.example -o jsonpath='{.status.storedVersions}'` affiche `["v1"]`.

#### Exercice 18.5 — La ressource `redis-quotidienne`

**Point de départ** : exercice 18.4.

Crée dans `boutique` la ressource `redis-quotidienne` (cible `redis`, planification `0 2 * * *`, rétention 7). Vérifie que l'API refuse une ressource `redis-hebdo` de rétention 99, puis une ressource `sans-cible` sans cible. Inscris `2026-10-23T02:00:00Z` comme date de dernière exécution de `redis-quotidienne`, et montre qu'un patch ordinaire du statut est ignoré.

> [!example]- Solution
> ```yaml
> # ~/cka/crd/redis-quotidienne.yaml
> apiVersion: boutique.example/v1
> kind: Sauvegarde
> metadata:
>   name: redis-quotidienne
>   namespace: boutique
> spec:
>   cible: redis
>   planification: "0 2 * * *"
>   retention: 7
> ```
>
> ```bash
> kubectl apply -f ~/cka/crd/redis-quotidienne.yaml
> kubectl -n boutique get svg
> sed -e 's/redis-quotidienne/redis-hebdo/' -e 's/retention: 7/retention: 99/' \
>   ~/cka/crd/redis-quotidienne.yaml | kubectl apply -f -
> printf 'apiVersion: boutique.example/v1\nkind: Sauvegarde\nmetadata:\n  name: sans-cible\n  namespace: boutique\nspec:\n  retention: 3\n' \
>   | kubectl apply -f -
> kubectl -n boutique patch svg redis-quotidienne --type=merge \
>   -p '{"status":{"derniereExecution":"2026-10-23T02:00:00Z"}}'
> kubectl -n boutique patch svg redis-quotidienne --subresource=status --type=merge \
>   -p '{"status":{"derniereExecution":"2026-10-23T02:00:00Z"}}'
> kubectl -n boutique get svg redis-quotidienne -o jsonpath='{.status.derniereExecution}{" gen="}{.metadata.generation}{"\n"}'
> ```
>
> `planification` est entre guillemets dans le manifeste : sans eux, YAML lirait `*` comme le début d'un alias. Le premier patch vise l'objet principal : avec la sous-ressource `status` active, l'API ignore `status` et kubectl affiche `patched (no change)`. Le second vise `/status` et réussit sans changer `metadata.generation`.
>
> **Vérification** : `kubectl -n boutique get svg` affiche `redis-quotidienne   redis   0 2 * * *   7   …` sous les en-têtes `NAME  CIBLE  PLANIFICATION  RETENTION  AGE` ; `redis-hebdo` est refusée (`spec.retention: Invalid value: 99: spec.retention in body should be less than or equal to 30`), `sans-cible` aussi (`spec.cible: Required value`) ; le dernier jsonpath affiche `2026-10-23T02:00:00Z gen=1`.

#### Exercice 18.6 — Règles CEL (temporaires)

**Point de départ** : exercice 18.5.

Sur une copie `~/cka/crd/sauvegardes-crd-cel.yaml` de la CRD, ajoute deux règles CEL : `cible` ne peut plus changer une fois posée (message `cible est immuable`) ; `planification` doit compter cinq champs séparés par une espace (message `planification : cinq champs cron séparés par une espace`), avec une longueur maximale de 64. Applique, teste les deux règles sur `redis-quotidienne`, puis rétablis la CRD d'origine.

> [!example]- Solution
> Dans la copie, remplace les propriétés `cible` et `planification` par le bloc de la section 18.5.3 (sans toucher à `required` ni à `retention`), puis :
>
> ```bash
> cp ~/cka/crd/sauvegardes-crd.yaml ~/cka/crd/sauvegardes-crd-cel.yaml
> vim ~/cka/crd/sauvegardes-crd-cel.yaml
> kubectl apply -f ~/cka/crd/sauvegardes-crd-cel.yaml
> kubectl -n boutique patch svg redis-quotidienne --type=merge -p '{"spec":{"cible":"api"}}'
> kubectl -n boutique patch svg redis-quotidienne --type=merge -p '{"spec":{"planification":"0 2 * *"}}'
> kubectl -n boutique patch svg redis-quotidienne --type=merge -p '{"spec":{"retention":10}}'
> kubectl apply -f ~/cka/crd/sauvegardes-crd.yaml
> kubectl -n boutique patch svg redis-quotidienne --type=merge -p '{"spec":{"retention":7}}'
> ```
>
> La règle `self == oldSelf` est une règle de transition : elle ne s'applique qu'aux mises à jour, et la ressource existante, créée avant elle, reste valide. Le troisième patch ne touche ni `cible` ni `planification` : il passe. Réappliquer le fichier d'origine retire les règles, parce que `kubectl apply` supprime les champs présents dans la configuration précédemment appliquée et absents de la nouvelle ; une modification faite par `kubectl edit` n'aurait pas été retirée ainsi. Le dernier patch remet la rétention à 7.
>
> **Vérification** : le premier patch est refusé avec `cible est immuable`, le deuxième avec `planification : cinq champs cron séparés par une espace` (tous deux dans une erreur `The Sauvegarde "redis-quotidienne" is invalid`) ; le troisième réussit ; à la fin, `kubectl get crd sauvegardes.boutique.example -o yaml | grep -c x-kubernetes-validations` affiche `0` et `kubectl -n boutique get svg` montre de nouveau la rétention 7.

#### Exercice 18.7 — ClusterRole agrégée `sauvegardes-lecture`

**Point de départ** : exercice 18.6.

Crée la ClusterRole `sauvegardes-lecture` (get, list, watch sur `sauvegardes` du groupe `boutique.example`) de sorte que le rôle intégré `view` l'inclue automatiquement. Vérifie le résultat dans `view`, puis avec un utilisateur fictif `bob` auquel tu donnes temporairement le rôle `view` dans `boutique`.

> [!example]- Solution
> ```yaml
> # ~/cka/crd/sauvegardes-lecture.yaml
> apiVersion: rbac.authorization.k8s.io/v1
> kind: ClusterRole
> metadata:
>   name: sauvegardes-lecture
>   labels:
>     rbac.authorization.k8s.io/aggregate-to-view: "true"
> rules:
> - apiGroups: ["boutique.example"]
>   resources: ["sauvegardes"]
>   verbs: ["get", "list", "watch"]
> ```
>
> ```bash
> kubectl apply -f ~/cka/crd/sauvegardes-lecture.yaml
> kubectl get clusterrole view -o jsonpath='{.rules[?(@.apiGroups[0]=="boutique.example")]}{"\n"}'
> kubectl auth can-i list sauvegardes.boutique.example -n boutique --as=bob
> kubectl -n boutique create rolebinding bob-lecture --clusterrole=view --user=bob
> kubectl auth can-i list sauvegardes.boutique.example -n boutique --as=bob
> kubectl auth can-i delete sauvegardes.boutique.example -n boutique --as=bob
> kubectl -n boutique delete rolebinding bob-lecture
> ```
>
> Le contrôleur d'agrégation du kube-controller-manager recopie dans `view` les règles de toute ClusterRole qui porte le label `aggregate-to-view` ([chapitre 16](16-rbac-et-authentification.md)). Comme `view` porte lui-même `aggregate-to-edit`, et `edit` `aggregate-to-admin`, la lecture des sauvegardes se propage aussi à `edit` et `admin`. Toute règle écrite à la main dans `view` serait écrasée par ce contrôleur.
>
> **Vérification** : le jsonpath affiche la règle `{"apiGroups":["boutique.example"],"resources":["sauvegardes"],"verbs":["get","list","watch"]}` ; `can-i list` répond `no` avant le RoleBinding et `yes` après ; `can-i delete` répond `no` ; `kubectl get clusterrole edit -o yaml | grep -c sauvegardes` affiche au moins `1`.

#### Exercice 18.8 — Une ValidatingAdmissionPolicy (temporaire)

**Point de départ** : exercice 18.7.

Dans le namespace `boutique-recette` seulement, interdis qu'un Deployment soit créé ou modifié avec plus de 2 réplicas, au moyen d'une ValidatingAdmissionPolicy `recette-replicas-max` et de son binding de même nom (message : `en recette, 2 réplicas au plus`). Teste avec un patch de `spec.replicas` à 3, puis avec `kubectl scale --replicas=3`. Explique le second résultat, remets `front` à 1 réplica et supprime la politique.

> [!example]- Solution
> ```yaml
> # ~/cka/extensions/vap-recette.yaml
> apiVersion: admissionregistration.k8s.io/v1
> kind: ValidatingAdmissionPolicy
> metadata:
>   name: recette-replicas-max
> spec:
>   failurePolicy: Fail
>   matchConstraints:
>     resourceRules:
>     - apiGroups: ["apps"]
>       apiVersions: ["v1"]
>       operations: ["CREATE", "UPDATE"]
>       resources: ["deployments"]
>   validations:
>   - expression: "object.spec.replicas <= 2"
>     message: "en recette, 2 réplicas au plus"
> ---
> apiVersion: admissionregistration.k8s.io/v1
> kind: ValidatingAdmissionPolicyBinding
> metadata:
>   name: recette-replicas-max
> spec:
>   policyName: recette-replicas-max
>   validationActions: [Deny]
>   matchResources:
>     namespaceSelector:
>       matchLabels:
>         kubernetes.io/metadata.name: boutique-recette
> ```
>
> ```bash
> kubectl apply -f ~/cka/extensions/vap-recette.yaml
> kubectl -n boutique-recette patch deployment front --type=merge -p '{"spec":{"replicas":3}}'
> kubectl -n boutique-recette scale deployment front --replicas=3
> kubectl -n boutique-recette get deployment front
> kubectl -n boutique-recette scale deployment front --replicas=1
> kubectl delete -f ~/cka/extensions/vap-recette.yaml
> ```
>
> Le label `kubernetes.io/metadata.name`, posé automatiquement sur chaque namespace, cible un namespace par son nom. Le patch touche la ressource `deployments` : la politique s'applique et le refuse. `kubectl scale` passe par la sous-ressource `deployments/scale`, que la règle ne couvre pas : il réussit, et le Deployment monte à 3 réplicas. Pour fermer cette porte, il faudrait ajouter `deployments/scale` aux `resources` (l'objet évalué serait alors un `Scale`, qui a aussi un `spec.replicas`). C'est le même piège que pour les webhooks (18.4.2).
>
> **Vérification** : le patch échoue avec `ValidatingAdmissionPolicy 'recette-replicas-max' with binding 'recette-replicas-max' denied request: en recette, 2 réplicas au plus` ; après `scale`, `kubectl -n boutique-recette get deployment front` affiche `3/3` ; à la fin, il affiche `1/1` et `kubectl get validatingadmissionpolicies` ne liste plus que `safe-upgrades.gateway.networking.k8s.io`, posée avec les CRD de Gateway API au [chapitre 13](13-gateway-api.md).

#### Exercice 18.9 — Un webhook en panne (temporaire)

**Point de départ** : exercice 18.8.

Lis la politique d'échec et le délai du webhook validant de cert-manager. Arrête le webhook (0 réplica), essaie de créer dans `boutique` un Issuer autosigné `test-webhook`, puis remets le webhook en service, crée l'Issuer et supprime-le.

> [!example]- Solution
> ```bash
> kubectl get validatingwebhookconfiguration cert-manager-webhook \
>   -o jsonpath='{.webhooks[0].failurePolicy}{" "}{.webhooks[0].timeoutSeconds}{"\n"}'
> kubectl -n cert-manager scale deployment cert-manager-webhook --replicas=0
> kubectl -n cert-manager wait --for=delete pod -l app.kubernetes.io/component=webhook --timeout=60s
> mkdir -p ~/cka/cert-manager
> printf 'apiVersion: cert-manager.io/v1\nkind: Issuer\nmetadata:\n  name: test-webhook\n  namespace: boutique\nspec:\n  selfSigned: {}\n' > ~/cka/cert-manager/issuer-test.yaml
> kubectl apply -f ~/cka/cert-manager/issuer-test.yaml
> kubectl -n cert-manager scale deployment cert-manager-webhook --replicas=1
> kubectl -n cert-manager rollout status deployment cert-manager-webhook
> kubectl apply -f ~/cka/cert-manager/issuer-test.yaml
> kubectl delete -f ~/cka/cert-manager/issuer-test.yaml
> ```
>
> Le webhook couvre `CREATE` et `UPDATE` de toutes les ressources de `cert-manager.io` et `acme.cert-manager.io`, en `failurePolicy: Fail` : sans pod prêt derrière le Service `cert-manager-webhook`, l'API server ne peut pas l'appeler et refuse la création. La suppression, elle, n'est pas couverte. Remettre 1 réplica rétablit la valeur du chart : la release Helm ne rencontrera pas de conflit de server-side apply sur `spec.replicas` au prochain upgrade, puisque la valeur est identique (17.7.1).
>
> **Vérification** : le jsonpath affiche `Fail 30` ; la première création échoue, ici au bout des 30 secondes du `timeoutSeconds`, avec `Error from server (InternalError): … Internal error occurred: failed calling webhook "webhook.cert-manager.io": failed to call webhook: Post "https://cert-manager-webhook.cert-manager.svc:443/validate?timeout=30s": … (Client.Timeout exceeded while awaiting headers)` ; la seconde réussit (`issuer.cert-manager.io/test-webhook created`), `kubectl -n boutique get issuer test-webhook` affiche `READY True`, puis la suppression aboutit et `kubectl -n cert-manager get deploy cert-manager-webhook` affiche `1/1`.

#### Exercice 18.10 — Un certificat pour le Gateway

**Point de départ** : exercice 18.9.

Crée le ClusterIssuer autosigné `autosigne`, puis, dans `boutique`, le Certificate `boutique-gw` qui produit le Secret `boutique-gw-tls` pour `gw.boutique.example` (nom commun compris). Suis la chaîne Certificate → CertificateRequest → Secret. Fais ensuite servir ce certificat par le listener `https` du Gateway `boutique-gw` ([chapitre 13](13-gateway-api.md)) et vérifie le certificat présenté.

> [!example]- Solution
> ```yaml
> # ~/cka/cert-manager/autosigne.yaml
> apiVersion: cert-manager.io/v1
> kind: ClusterIssuer
> metadata:
>   name: autosigne
> spec:
>   selfSigned: {}
> ---
> apiVersion: cert-manager.io/v1
> kind: Certificate
> metadata:
>   name: boutique-gw
>   namespace: boutique
> spec:
>   secretName: boutique-gw-tls
>   commonName: gw.boutique.example
>   dnsNames:
>   - gw.boutique.example
>   issuerRef:
>     name: autosigne
>     kind: ClusterIssuer
>     group: cert-manager.io
> ```
>
> ```bash
> kubectl apply -f ~/cka/cert-manager/autosigne.yaml
> kubectl wait --for=condition=Ready clusterissuer/autosigne --timeout=60s
> kubectl -n boutique wait --for=condition=Ready certificate/boutique-gw --timeout=120s
> kubectl -n boutique get certificate,certificaterequest
> kubectl -n boutique get secret boutique-gw-tls
> kubectl -n boutique describe certificate boutique-gw | sed -n '/Events:/,$p'
>
> kubectl -n boutique get gateway boutique-gw \
>   -o jsonpath='{range .spec.listeners[*]}{.name}{" "}{.tls.certificateRefs[0].name}{"\n"}{end}'
> kubectl -n boutique patch gateway boutique-gw --type=json -p '[
>   {"op":"test","path":"/spec/listeners/1/name","value":"https"},
>   {"op":"replace","path":"/spec/listeners/1/tls/certificateRefs/0/name","value":"boutique-gw-tls"}]'
> kubectl -n boutique get gateway boutique-gw \
>   -o jsonpath='{.status.listeners[?(@.name=="https")].conditions[?(@.type=="ResolvedRefs")].status}{"\n"}'
>
> GW=$(kubectl -n boutique get gateway boutique-gw -o jsonpath='{.status.addresses[0].value}')
> openssl s_client -connect $GW:443 -servername gw.boutique.example </dev/null 2>/dev/null \
>   | openssl x509 -noout -subject -issuer -fingerprint -sha256
> kubectl -n boutique get secret boutique-gw-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
>   | openssl x509 -noout -fingerprint -sha256
> curl -sk -o /dev/null -w '%{http_code}\n' --resolve gw.boutique.example:443:$GW https://gw.boutique.example/
> ```
>
> Le patch JSON commence par une opération `test` : si le listener d'indice 1 ne s'appelait pas `https`, le patch entier serait refusé au lieu de modifier le mauvais listener. On ne bascule qu'une fois le Certificate `Ready`, sinon le listener perd son certificat (`ResolvedRefs=False`). Reporte aussi le changement dans le manifeste du Gateway que tu as écrit au chapitre 13, sinon un prochain `kubectl apply` le défera. Le Secret `boutique-tls` du [chapitre 12](12-ingress.md) reste utilisé par l'Ingress `boutique`.
>
> **Vérification** : `kubectl get clusterissuer autosigne` affiche `READY True` ; `kubectl -n boutique get certificate` affiche `boutique-gw   True   boutique-gw-tls` ; la CertificateRequest s'appelle `boutique-gw-1`, avec `APPROVED True`, `READY True`, `ISSUER autosigne` et pour REQUESTER `system:serviceaccount:cert-manager:cert-manager` ; le Secret est de type `kubernetes.io/tls` avec `DATA 3` ; les événements du Certificate se terminent par `The certificate has been successfully issued` ; `ResolvedRefs` vaut `True` ; `openssl` affiche `subject=CN=gw.boutique.example` et `issuer=CN=gw.boutique.example`, avec la même empreinte SHA-256 que le Secret ; `curl` affiche `200`.

#### Exercice 18.11 — La réconciliation à l'œuvre

**Point de départ** : exercice 18.10.

Note l'empreinte du certificat servi par le Gateway, puis supprime le Secret `boutique-gw-tls`. Observe ce que fait cert-manager et ce que sert le Gateway ensuite.

> [!example]- Solution
> ```bash
> kubectl -n boutique get certificate boutique-gw -o jsonpath='{.status.revision}{"\n"}'
> kubectl -n boutique delete secret boutique-gw-tls
> kubectl -n boutique get secret --field-selector metadata.name=boutique-gw-tls --watch   # Ctrl+C dès qu'il réapparaît
> kubectl -n boutique wait --for=condition=Ready certificate/boutique-gw --timeout=120s
> kubectl events -n boutique --for certificate/boutique-gw
> kubectl -n boutique get certificate boutique-gw -o jsonpath='{.status.revision}{"\n"}'
> kubectl -n boutique get certificaterequests
> GW=$(kubectl -n boutique get gateway boutique-gw -o jsonpath='{.status.addresses[0].value}')
> openssl s_client -connect $GW:443 -servername gw.boutique.example </dev/null 2>/dev/null \
>   | openssl x509 -noout -fingerprint -sha256
> ```
>
> Le contrôleur surveille les Secrets qu'il produit : la disparition de `boutique-gw-tls` déclenche aussitôt une réémission (révision 2), avec une nouvelle clé, puisqu'il n'y a plus de clé à réutiliser et que la politique de rotation est `Always`. La CertificateRequest `boutique-gw-1` est supprimée (`revisionHistoryLimit` 1) au profit de `boutique-gw-2`. Envoy Gateway, qui surveille lui aussi le Secret, recharge le nouveau certificat : la coupure TLS ne dure que quelques secondes. C'est la réconciliation par niveau : l'état voulu (le Certificate) n'a pas changé, l'état réel s'en est écarté, le contrôleur l'y ramène. La surveillance passe par un sélecteur de champ : `kubectl get secret boutique-gw-tls --watch` échouerait sur `Error from server (NotFound)` si le Secret n'était pas encore recréé, car on ne surveille pas par son nom un objet absent.
>
> **Vérification** : la révision passe de `1` à `2` ; les événements récents du Certificate sont `Issuing certificate as Secret does not exist`, `Stored new private key in temporary Secret resource "boutique-gw-…"`, `Created new CertificateRequest resource "boutique-gw-2"` et `The certificate has been successfully issued` (les deux messages `Issuing`, identiques d'une émission à l'autre, apparaissent agrégés avec un compteur, `0s (x2 over 17s)` ; les deux autres figurent une fois par révision, avec des noms différents) ; `kubectl -n boutique get certificaterequests` ne liste que `boutique-gw-2` ; l'empreinte servie par le Gateway a changé et égale celle du nouveau Secret.

État laissé par ce chapitre : RuntimeClass `runc-standard`, CRD `sauvegardes.boutique.example` et ressource `boutique/redis-quotidienne`, ClusterRole agrégée `sauvegardes-lecture`, ClusterIssuer `autosigne`, Certificate `boutique/boutique-gw` et listener `https` de `boutique-gw` sur le Secret `boutique-gw-tls`. C'est l'**instantané I4**, point de départ des chapitres 20 à 24 (`lab/restaurer.sh I4`).

---
