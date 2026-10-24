---
title: "CKA — 16. Authentification, RBAC et ServiceAccounts"
description: "Comment l'API server identifie un client (certificats X.509, jetons de ServiceAccount, OIDC), l'API CertificateSigningRequest, l'autorisation RBAC et ses garde-fous, les ServiceAccounts et leurs jetons, et la vérification des droits avec kubectl auth."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 16. Authentification, RBAC et ServiceAccounts

Ce chapitre répond aux deux questions que l'API server pose à chaque requête : qui es-tu, et as-tu le droit ? Il décrit les mécanismes d'authentification (certificats X.509, jetons de ServiceAccount, OIDC et les autres), l'API CertificateSigningRequest qui permet de délivrer un certificat à un utilisateur sans toucher à la clé de la CA, puis l'autorisation par RBAC : rôles, liaisons, verbes, sous-ressources, agrégation, rôles par défaut et garde-fous contre l'escalade de privilèges. Il termine par les ServiceAccounts, l'identité des pods, et par les outils de vérification `kubectl auth can-i` et `kubectl auth whoami`. La compétence officielle visée est *Manage role based access control (RBAC)*, dans le domaine *Cluster Architecture, Installation and Configuration* (25 %). Elle tombe presque à chaque session sous une forme ou une autre : créer un ServiceAccount, un rôle et sa liaison, donner un accès à un utilisateur, vérifier un droit. Ce sont des tâches rapides si l'on connaît les commandes impératives et les pièges de portée (Role ou ClusterRole, RoleBinding ou ClusterRoleBinding), et coûteuses si l'on tâtonne.

### 16.1 Le chemin d'une requête

Le [chapitre 2](02-architecture.md) a montré qu'une requête traverse l'API server en quatre étapes avant d'atteindre etcd. Ce chapitre se concentre sur les deux premières.

```
Une requête vers l'API server :
═══════════════════════════════

  kubectl ── TLS ──▶ ┌────────────────────┐
  (certificat client │ 1. AUTHENTIFICATION│  qui es-tu ?   échec ──▶ 401 Unauthorized
   ou jeton porteur) │    x509, jetons,   │  → utilisateur, UID, groupes, extra
                     │    OIDC, webhook…  │
                     ├────────────────────┤
                     │ 2. AUTORISATION    │  as-tu le droit ? refus ──▶ 403 Forbidden
                     │    Node, RBAC…     │  (verbe, ressource, namespace, nom)
                     ├────────────────────┤
                     │ 3. ADMISSION       │  la demande est-elle acceptable ?
                     │    mutation puis   │  (chapitre 8)  refus ──▶ 403 ou 422
                     │    validation      │
                     ├────────────────────┤
                     │ 4. VALIDATION,     │
                     │    écriture etcd   │
                     └────────────────────┘
```

Retiens la différence entre les deux codes d'erreur, qui oriente le diagnostic. Un **401** signifie que l'API server ne sait pas qui tu es : certificat expiré ou signé par une autre CA, jeton invalide ou périmé. Un **403** signifie qu'il le sait, mais qu'aucun autorisateur n'a accepté la requête. L'admission ne s'exécute qu'après une autorisation réussie.

### 16.2 L'authentification

#### Il n'y a pas d'objet « utilisateur »

Kubernetes ne stocke aucun utilisateur humain. Il n'existe pas de ressource `User` dans l'API, et on ne crée pas d'utilisateur par `kubectl`. Une identité, c'est ce que produit un authentificateur à partir des informations d'identification présentées : un **nom d'utilisateur**, un **UID** facultatif, une liste de **groupes** et des attributs **extra**. Ces valeurs sont opaques : elles ne prennent un sens que lorsque l'autorisation les compare aux sujets de ses règles. Tout client authentifié appartient en plus au groupe `system:authenticated`. Une requête sans identifiant, si l'accès anonyme est actif (il l'est par défaut dès qu'un mode d'autorisation autre que `AlwaysAllow` est configuré), devient l'utilisateur `system:anonymous` du groupe `system:unauthenticated`.

Les **ServiceAccounts**, eux, sont des objets de l'API, namespacés : ils donnent une identité aux processus des pods (16.9). Leur nom d'utilisateur est `system:serviceaccount:<namespace>:<nom>` (au singulier), et ils appartiennent aux groupes `system:serviceaccounts` et `system:serviceaccounts:<namespace>` (au pluriel).

#### Les méthodes

| Méthode | Ce que présente le client | Identité obtenue | Configuration de l'API server |
|---|---|---|---|
| Certificat client X.509 | certificat signé par une CA de confiance | `CN` → nom, chaque `O` → un groupe | `--client-ca-file` |
| Jeton de ServiceAccount | JWT signé par la clé des ServiceAccounts | `system:serviceaccount:<ns>:<nom>` | `--service-account-key-file`, `--service-account-issuer` |
| Jeton d'amorçage (*bootstrap token*) | `<id>.<secret>`, Secret dans `kube-system` | `system:bootstrap:<id>` | `--enable-bootstrap-token-auth` (posé par kubeadm) |
| Fichier de jetons statiques | jeton listé dans un CSV | colonnes du CSV | `--token-auth-file` ; changer la liste exige de redémarrer l'API server |
| OIDC / JWT | jeton d'identité d'un fournisseur externe | revendications (*claims*) du jeton | `--oidc-*` ou `--authentication-config` |
| Webhook | jeton porteur vérifié par un service externe | réponse du service | `--authentication-token-webhook-config-file` |
| Proxy d'authentification | en-têtes `X-Remote-User`, `X-Remote-Group` | en-têtes | `--requestheader-*` |

Plusieurs méthodes sont actives en même temps ; le premier authentificateur qui reconnaît la requête l'emporte, et l'API server ne garantit pas l'ordre dans lequel il les essaie. Pour les humains, l'examen ne connaît que le certificat X.509. **OIDC** est à connaître en concept : l'API server fait confiance à un fournisseur d'identité externe (Keycloak, Dex, un IdP d'entreprise), l'utilisateur obtient un jeton d'identité par un plugin d'identification de `kubectl` (`exec` dans le kubeconfig), et ses groupes viennent d'une revendication du jeton. Depuis 1.34, la configuration par fichier (`AuthenticationConfiguration` de `apiserver.config.k8s.io/v1`, passée par `--authentication-config`) est stable : elle accepte plusieurs émetteurs et des expressions CEL pour construire nom et groupes.

#### Les certificats X.509

Un certificat client est accepté s'il est signé par une CA listée dans `--client-ca-file`, s'il est dans sa période de validité et s'il porte l'usage étendu *client auth*. Le `CN` donne le nom d'utilisateur ; chaque attribut `O` ajoute un groupe. Le certificat de `CN=alice, O=developpeurs` authentifie donc l'utilisateur `alice` dans les groupes `developpeurs` et `system:authenticated`. L'API server ajoute aussi un attribut extra `authentication.kubernetes.io/credential-id` qui vaut `X509SHA256=<empreinte du certificat>`, utile dans les journaux d'audit.

> [!warning]
> Kubernetes ne gère **pas la révocation** des certificats : un certificat émis reste valable jusqu'à son expiration. Un groupe inscrit dans un certificat ne se retire pas non plus. On limite donc la durée des certificats d'utilisateurs, et l'on donne les droits par des liaisons RBAC, qu'on peut supprimer, plutôt que par des groupes puissants gravés dans le certificat.

C'est la raison d'être d'un garde-fou à connaître : le groupe **`system:masters`**. Ses membres contournent entièrement l'autorisation : l'API server les accepte avant même de consulter RBAC, et aucune règle ne peut les restreindre. Un certificat portant `O=system:masters` est donc un passe-partout irrévocable. Le contrôleur d'admission `CertificateSubjectRestriction` (actif par défaut) refuse toute CSR qui le demande au signataire `kubernetes.io/kube-apiserver-client` : `use of kubernetes.io/kube-apiserver-client signer with system:masters group is not allowed`.

Depuis 1.29, kubeadm n'utilise plus ce groupe pour l'administration courante. `admin.conf` contient le certificat `O=kubeadm:cluster-admins, CN=kubernetes-admin`, et le groupe `kubeadm:cluster-admins` reçoit `cluster-admin` par la ClusterRoleBinding `kubeadm:cluster-admins` : c'est un droit RBAC, révocable. `super-admin.conf`, créé par `kubeadm init` sur le premier nœud de control plane, contient `O=system:masters, CN=kubernetes-super-admin` : c'est le kubeconfig de secours, pour le jour où une erreur RBAC aurait verrouillé le cluster. On le garde hors du nœud, on ne s'en sert jamais au quotidien.

> [!info] minikube ≠ examen
> Le kubeconfig que minikube écrit sur ton poste utilise son propre certificat client, `CN=minikube-user, O=system:masters`, signé par la CA `CN=minikubeCA` (sur kubeadm, la CA s'appelle `CN=kubernetes`). `kubectl auth whoami` affiche donc sur le lab :
> ```
> ATTRIBUTE                                           VALUE
> Username                                            minikube-user
> Groups                                              [system:masters system:authenticated]
> Extra: authentication.kubernetes.io/credential-id   [X509SHA256=…]
> ```
> Sur un cluster kubeadm, avec `admin.conf`, tu verrais `kubernetes-admin` dans `[kubeadm:cluster-admins system:authenticated]`. Le nœud `cka` contient bien `/etc/kubernetes/admin.conf` et `/etc/kubernetes/super-admin.conf`, car minikube installe le control plane avec kubeadm.

### 16.3 L'API CertificateSigningRequest

Délivrer un certificat à un utilisateur demande la clé privée de la CA. Plutôt que de la manipuler (sur un nœud kubeadm, `openssl x509 -req -CA ca.crt -CAkey ca.key` ou `kubeadm kubeconfig user --client-name=alice --org=developpeurs`, voir le [chapitre 19](19-kubeadm-installation-ha-et-mises-a-jour.md)), on passe par l'API **CertificateSigningRequest** (`certificates.k8s.io/v1`), qui confie la signature au kube-controller-manager : seul lui détient la clé, par ses options `--cluster-signing-cert-file` et `--cluster-signing-key-file` que kubeadm fait pointer sur la CA du cluster.

```
Délivrer un certificat à alice :
════════════════════════════════

  poste de l'administrateur                 API server / controller-manager
  ─────────────────────────                 ───────────────────────────────
  1. openssl genrsa  → alice.key            (la clé privée ne quitte jamais le poste)
  2. openssl req     → alice.csr  (PKCS#10, CN=alice, O=developpeurs)
  3. base64 -w0 alice.csr ──▶ CertificateSigningRequest "alice"
                                  signerName: kubernetes.io/kube-apiserver-client
                                  expirationSeconds, usages: [client auth]
                                                     │  Pending
  4. kubectl certificate approve alice ─────────────▶│  Approved
                                                     │  le signataire du controller-manager
                                                     │  vérifie usages, CA interdite…
                                                     │  et signe avec la CA du cluster
                                                     ▼  Approved,Issued
  5. kubectl get csr alice -o jsonpath='{.status.certificate}' | base64 -d → alice.crt
  6. kubectl config set-credentials / set-context → kubeconfig d'alice
```

La spec d'une CSR comporte quatre champs utiles. `request` contient la demande PKCS#10 **au format PEM, encodée en base64 sur une seule ligne**. `signerName`, obligatoire, désigne le signataire. `expirationSeconds` demande une durée de validité : au moins 600 (dix minutes), et plafonnée par `--cluster-signing-duration` du kube-controller-manager (un an par défaut), la plus petite des deux l'emportant ; sans ce champ, on obtient le plafond. `usages` est obligatoire et doit, pour un certificat client, contenir `client auth`.

| `signerName` | Signe | Approbation automatique | Usages permis |
|---|---|---|---|
| `kubernetes.io/kube-apiserver-client` | certificats clients d'utilisateurs | **jamais** | doit contenir `client auth` ; au plus `digital signature`, `key encipherment`, `client auth` |
| `kubernetes.io/kube-apiserver-client-kubelet` | certificats clients des kubelets (`O=system:nodes`, `CN=system:node:<nœud>`) | oui, par le controller-manager | `client auth` (+ `digital signature`, `key encipherment`) |
| `kubernetes.io/kubelet-serving` | certificats serveurs des kubelets | jamais | `server auth` (+ `digital signature`, `key encipherment`) |
| `kubernetes.io/legacy-unknown` | rien | — | refusé par l'API `v1` |

Après approbation, si la demande ne respecte pas les règles du signataire (un usage `server auth` pour un client, par exemple), le certificat n'est pas émis : la CSR passe `Approved,Failed` avec la raison `SignerValidationFailure` (`invalid usage for client certificate: server auth`). Les CSR ne restent pas indéfiniment : un contrôleur les supprime une heure après leur approbation, leur refus ou leur échec, vingt-quatre heures après leur création si personne ne les a traitées, et dans tous les cas à l'expiration du certificat émis. Le contrôleur ne passe qu'une fois par heure : compte jusqu'à deux heures avant de voir disparaître une CSR traitée. Récupère donc le certificat aussitôt.

Approuver se fait par `kubectl certificate approve <nom>` et refuser par `kubectl certificate deny <nom>`. Ces commandes écrivent dans la sous-ressource `certificatesigningrequests/approval`. Le droit d'approuver exige `update` sur cette sous-ressource **et** le verbe spécial `approve` sur la ressource `signers` (groupe `certificates.k8s.io`), avec le nom du signataire comme `resourceNames` (`kubernetes.io/kube-apiserver-client`, ou `kubernetes.io/*`).

> [!tip] Réflexe d'examen
> La page à ouvrir est *Issue a Certificate for a Kubernetes API Client Using a CertificateSigningRequest* (`/docs/tasks/tls/certificate-issue-client-csr/`) : elle donne la suite exacte, openssl compris. Encode avec `base64 -w0` : sans `-w0`, `base64` coupe sa sortie toutes les 76 colonnes et la valeur insérée dans le YAML casse le document. Et récupère le certificat avec `base64 -d`, pas `-w0`.

### 16.4 L'autorisation : les modes

L'API server enchaîne les autorisateurs listés par `--authorization-mode`, dans l'ordre. Chacun rend l'un de trois verdicts : **autorisé**, **refusé** ou **sans avis**. Le premier verdict tranché arrête la chaîne ; si tous sont sans avis, la requête est refusée (403). Sur kubeadm comme sur le lab, la valeur est `--authorization-mode=Node,RBAC`.

| Mode | Rôle |
|---|---|
| `Node` | autorise les kubelets (`system:node:<nœud>`, groupe `system:nodes`) sur les seuls objets liés à leurs pods : leurs Secrets, ConfigMaps, PVC, jetons de ServiceAccount… ; complété par l'admission `NodeRestriction`, qui limite un kubelet à son propre objet Node et aux pods qui lui sont affectés |
| `RBAC` | règles stockées dans l'API (16.5) ; ne rend jamais « refusé », seulement « autorisé » ou « sans avis » |
| `ABAC` | politique dans un fichier local (`--authorization-policy-file`) ; historique, à éviter |
| `Webhook` | délègue la décision à un service externe par une `SubjectAccessReview` |
| `AlwaysAllow`, `AlwaysDeny` | tout accepter ou tout refuser ; `AlwaysAllow` désactive de fait l'autorisation |

Comme RBAC ne refuse jamais, placer `AlwaysAllow` n'importe où dans la liste ouvre tout. Depuis 1.32, la configuration par fichier (`AuthorizationConfiguration` de `apiserver.config.k8s.io/v1`, option `--authorization-config`) est stable : elle permet plusieurs webhooks, des politiques d'échec et des préfiltres CEL, et elle exclut l'usage simultané de `--authorization-mode`.

Ce que l'autorisation examine se résume à quelques attributs : l'utilisateur, ses groupes et ses extras, le **verbe**, le **groupe d'API**, la **ressource**, la **sous-ressource**, le **namespace** et le **nom** de l'objet, ou, pour les URL hors ressources (`/healthz`, `/version`, `/metrics`), le chemin et la méthode HTTP en minuscules.

### 16.5 RBAC : les quatre objets

RBAC (`rbac.authorization.k8s.io/v1`) repose sur quatre types d'objets. Un **Role** contient des règles valables dans un namespace ; un **ClusterRole** contient des règles sans namespace. Une **RoleBinding** accorde un rôle à des sujets dans un namespace ; une **ClusterRoleBinding** l'accorde dans tout le cluster. Les permissions sont **purement additives** : il n'existe aucune règle de refus. Ce qu'un sujet peut faire, c'est l'union de toutes les règles de tous les rôles qui lui sont liés, directement ou par ses groupes. Pour retirer un droit, on retire une liaison ; on ne peut pas « soustraire » une permission d'un rôle plus large.

```
Les quatre combinaisons :
═════════════════════════

  Role (ns boutique)  ──▶ RoleBinding (ns boutique)  = droits dans boutique
  ClusterRole         ──▶ RoleBinding (ns boutique)  = droits dans boutique seulement
                                                       (le ClusterRole sert de modèle réutilisable)
  ClusterRole         ──▶ ClusterRoleBinding         = droits dans tous les namespaces
                                                       + ressources sans namespace (nodes, PV,
                                                       StorageClasses, CSR…) + URL hors ressources
  Role                ──▶ ClusterRoleBinding         = IMPOSSIBLE (roleRef doit être un ClusterRole)
```

Deux conséquences. Les ressources **sans namespace** (`nodes`, `persistentvolumes`, `storageclasses`, `namespaces`, `clusterroles`…) ne s'accordent utilement que par un ClusterRole lié par une ClusterRoleBinding : un ClusterRole qui autorise `nodes`, lié par une RoleBinding, ne donne rien. Et une RoleBinding ne peut référencer qu'un Role **de son propre namespace** (son `roleRef` n'a pas de champ namespace) ou un ClusterRole.

Une règle combine des listes ; une requête est autorisée si elle correspond à **une** règle d'**un** rôle lié :

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: exemple-regles
  namespace: boutique
rules:
- apiGroups: [""]                  # "" = groupe de base (pods, services, configmaps, secrets…)
  resources: ["pods", "pods/log"]  # ressource/sous-ressource
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  resourceNames: ["front"]         # restreint aux objets nommés
  verbs: ["get", "patch"]
```

Le `roleRef` d'une liaison est **immuable** : pour changer le rôle accordé, on supprime et recrée la liaison (ou l'on passe par `kubectl auth reconcile`, qui le fait). C'est voulu : on peut ainsi déléguer la gestion de la liste des sujets d'une liaison (`update`) sans permettre d'en changer le rôle. Les sujets s'écrivent ainsi :

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: exemple-sujets
  namespace: boutique
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
- kind: User
  name: alice
  apiGroup: rbac.authorization.k8s.io
- kind: Group
  name: developpeurs
  apiGroup: rbac.authorization.k8s.io
- kind: ServiceAccount             # pas d'apiGroup, namespace obligatoire
  name: deployeur
  namespace: boutique
- kind: Group                      # tous les ServiceAccounts d'un namespace
  name: system:serviceaccounts:boutique
  apiGroup: rbac.authorization.k8s.io
```

Les noms sont sensibles à la casse et ne sont pas vérifiés : lier un rôle à l'utilisateur `Alice` ou au groupe `developpeur` (sans s) réussit, et ne sert à rien. Le préfixe `system:` est réservé à Kubernetes.

### 16.6 Verbes, sous-ressources et resourceNames

Le verbe d'une requête sur une ressource se déduit de la méthode HTTP et de la cible :

| Méthode HTTP | Verbe |
|---|---|
| `GET`, `HEAD` sur un objet | `get` |
| `GET`, `HEAD` sur une collection | `list` ; `watch` avec `?watch=true` |
| `POST` | `create` |
| `PUT` | `update` |
| `PATCH` | `patch` |
| `DELETE` sur un objet | `delete` |
| `DELETE` sur une collection | `deletecollection` |

`get`, `list` et `watch` donnent accès aux mêmes données : un `list` sur `secrets` montre leur contenu tout autant qu'un `get`. Certaines commandes demandent plusieurs verbes : `kubectl apply` fait un `get` puis un `create` ou un `patch` ; `kubectl rollout status` fait un `list` puis un `watch` ; `kubectl scale` lit l'objet (`get`) puis modifie la sous-ressource `scale` (`patch`). D'autres verbes sont **spéciaux** et n'ont rien à voir avec HTTP : `bind` et `escalate` sur `roles` et `clusterroles` (16.7), `impersonate` sur `users`, `groups`, `serviceaccounts`, `uids` et `userextras` (16.10), `approve` et `sign` sur `signers` (16.3).

Les **sous-ressources** s'écrivent `ressource/sous-ressource` et s'accordent séparément de la ressource :

| Sous-ressource | Verbe exigé | Commande concernée |
|---|---|---|
| `pods/log` | `get` | `kubectl logs` |
| `pods/exec` | `create` (et `get` sur `pods`) | `kubectl exec` ; `create` exigé aussi en WebSocket depuis 1.35 |
| `pods/attach`, `pods/portforward` | `create` | `kubectl attach`, `kubectl port-forward` |
| `pods/eviction` | `create` | `kubectl drain` |
| `deployments/scale`, `statefulsets/scale` | `get`, `update`, `patch` | `kubectl scale`, HPA |
| `*/status` | `update`, `patch` | contrôleurs |
| `serviceaccounts/token` | `create` | `kubectl create token` |
| `certificatesigningrequests/approval` | `update` | `kubectl certificate approve` |

Accorder `pods` n'accorde pas `pods/log` ni `pods/exec`, et l'inverse est vrai : un sujet qui n'a que `get` sur `pods/log` ne peut même pas lister les pods.

`resourceNames` limite une règle à des objets nommés. Deux restrictions en découlent. Un `create` ne peut pas être restreint par nom (le nom n'existe pas encore au moment de l'autorisation), sauf sur une sous-ressource (`pods/exec` d'un pod précis). Et `list`, `watch` ou `deletecollection` restreints par nom n'autorisent que les requêtes qui filtrent sur ce nom : `kubectl get configmaps --field-selector=metadata.name=front-html`. Le joker `*` vaut pour tous les groupes, ressources ou verbes, y compris ceux qui apparaîtront plus tard : c'est commode et dangereux. Pour les URL hors ressources (`nonResourceURLs`, ClusterRole seulement), `*` en fin de chemin vaut pour tous les sous-chemins.

### 16.7 Prévention de l'escalade

RBAC serait inutile si un utilisateur autorisé à créer des rôles pouvait s'accorder n'importe quoi. L'API impose donc deux règles, appliquées à l'écriture des objets RBAC eux-mêmes (elles valent même quand l'autorisateur RBAC n'est pas actif).

On ne peut créer ou modifier un Role ou un ClusterRole que si l'on **détient déjà toutes les permissions qu'il contient**, à la même portée (dans le namespace pour un Role, dans tout le cluster pour un ClusterRole), ou si l'on a le verbe **`escalate`** sur `roles` ou `clusterroles`. On ne peut créer ou modifier une liaison que si l'on détient déjà toutes les permissions du rôle référencé, à la portée de la liaison, ou si l'on a le verbe **`bind`** sur ce rôle précis. Le refus nomme les permissions manquantes :

```
Error from server (Forbidden): roles.rbac.authorization.k8s.io "lire-secrets" is forbidden: user "alice" (groups=["developpeurs" "system:authenticated"]) is attempting to grant RBAC permissions not currently held:
{APIGroups:[""], Resources:["secrets"], Verbs:["get"]}
```

`bind` sert à la délégation : avec `bind` sur le ClusterRole `view` (en `resourceNames`) et `create` sur `rolebindings` dans un namespace, un chef d'équipe distribue `view` dans ce namespace sans en détenir lui-même toutes les permissions. Pour amorcer le système, il faut une identité qui ait déjà tout : `cluster-admin`, ou un membre de `system:masters`.

Ces règles ne ferment que la porte RBAC. La plus grande source d'escalade est ailleurs : **créer des pods**. Un sujet qui peut créer un pod dans un namespace peut y monter n'importe quel Secret de ce namespace, puis lire son contenu dans les journaux du conteneur ; il peut aussi lancer le pod avec n'importe quel ServiceAccount du namespace, et récupérer son jeton. Le rôle `developpeur` du fil rouge n'accorde rien sur les Secrets, mais il permet de créer des pods : alice ne peut pas faire `kubectl get secret api-secret`, mais elle peut lancer un pod qui affiche `DB_PASSWORD`. Même raisonnement pour tout ce qui crée des pods indirectement (Deployments, Jobs, CronJobs…). Les droits d'écriture sur les charges de travail sont donc, en pratique, des droits sur les Secrets et les ServiceAccounts du namespace.

### 16.8 Rôles par défaut et agrégation

L'API server crée au démarrage un jeu de ClusterRoles et de ClusterRoleBindings, tous labellisés `kubernetes.io/bootstrapping=rbac-defaults`, et les **réconcilie à chaque démarrage** : il y rajoute les permissions et les sujets manquants. Une modification manuelle d'un rôle par défaut est donc réparée au prochain redémarrage, sauf si l'on pose sur lui l'annotation `rbac.authorization.kubernetes.io/autoupdate: "false"`. Les rôles préfixés `system:` servent aux composants (`system:kube-scheduler`, `system:node-proxier`, `system:controller:*` pour chaque contrôleur…) ; on n'y touche pas. Trois rôles de découverte sont liés à tous les utilisateurs authentifiés : `system:basic-user` (s'interroger sur soi-même, ce qui fait marcher `kubectl auth whoami` et `kubectl auth can-i`), `system:discovery` (découverte de l'API) et `system:public-info-viewer` (version, santé ; lié aussi aux non-authentifiés).

Quatre ClusterRoles sont destinés aux humains :

| ClusterRole | Lié par défaut à | Secrets | Rôles et liaisons | exec, attach, port-forward | ServiceAccounts |
|---|---|---|---|---|---|
| `cluster-admin` | groupe `system:masters` | tout | tout | oui | tout |
| `admin` | personne | lecture et écriture | lecture et écriture dans le namespace | oui | peut créer leurs jetons et les usurper |
| `edit` | personne | lecture et écriture | **aucun** | oui | peut créer leurs jetons et les usurper |
| `view` | personne | **aucun accès** | aucun | non | lecture seule des objets ServiceAccount |

`admin`, `edit` et `view` sont faits pour être accordés **dans un namespace**, par une RoleBinding. `admin` ajoute à `edit` la gestion des Roles et RoleBindings du namespace, mais pas l'écriture des ResourceQuotas ni du namespace lui-même. `edit` donne accès aux Secrets et permet de lancer des pods sous n'importe quel ServiceAccount du namespace : il équivaut donc à disposer des droits de tous ces ServiceAccounts. `view` exclut les Secrets pour cette raison précise : lire un Secret de jeton, c'est obtenir l'identité d'un ServiceAccount. Aucun des trois ne permet d'écrire les EndpointSlices dans un cluster créé en 1.22 ou après. `cluster-admin`, lié par une RoleBinding, donne tout pouvoir dans le namespace de la liaison, namespace compris.

#### L'agrégation

Ces trois rôles sont **agrégés** : leurs règles ne sont pas écrites en dur, elles sont la réunion des règles de tous les ClusterRoles qui portent un label donné. Un ClusterRole agrégé déclare un `aggregationRule` avec des sélecteurs de labels ; le contrôleur `clusterrole-aggregation` du kube-controller-manager recalcule son champ `rules` à chaque changement des ClusterRoles sélectionnés, et **écrase** toute règle écrite à la main dans ce champ.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: supervision
aggregationRule:
  clusterRoleSelectors:
  - matchLabels:
      rbac.example/aggregate-to-supervision: "true"
# pas de champ rules : le contrôleur le remplit
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: supervision-endpointslices
  labels:
    rbac.example/aggregate-to-supervision: "true"
rules:
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices"]
  verbs: ["get", "list", "watch"]
```

Les rôles par défaut utilisent les labels `rbac.authorization.k8s.io/aggregate-to-admin`, `aggregate-to-edit` et `aggregate-to-view`, et s'emboîtent : `view` porte `aggregate-to-edit` et `edit` porte `aggregate-to-admin`, si bien que `admin` ⊇ `edit` ⊇ `view`. C'est le moyen officiel d'étendre ces rôles aux ressources d'une CRD : un ClusterRole labellisé `aggregate-to-view: "true"` qui autorise la lecture de la nouvelle ressource la rend visible à tous les détenteurs de `view`, `edit` et `admin`. Le [chapitre 18](18-interfaces-crd-et-operateurs.md) le fait pour la ressource `sauvegardes` du fil rouge. N'écris jamais de champ `rules`, même vide, dans le manifeste d'un ClusterRole agrégé : appliqué en *server-side apply*, il revendique la propriété du champ et entre en conflit avec le contrôleur.

### 16.9 ServiceAccounts et jetons

#### L'identité des pods

Un ServiceAccount est un objet namespacé, très simple, qui donne une identité aux processus d'un pod. Le contrôleur `serviceaccount` garantit qu'un ServiceAccount nommé `default` existe dans chaque namespace. À la création d'un pod, le contrôleur d'admission `ServiceAccount` :

1. renseigne `spec.serviceAccountName: default` si le champ est vide ;
2. refuse le pod si le ServiceAccount désigné n'existe pas ;
3. sauf si `automountServiceAccountToken` vaut `false` sur le pod ou sur le ServiceAccount, ajoute un volume projeté `kube-api-access-<suffixe>` et le monte dans chaque conteneur en `/var/run/secrets/kubernetes.io/serviceaccount` ;
4. copie les `imagePullSecrets` du ServiceAccount si le pod n'en a pas.

Le volume projeté réunit trois sources : un jeton (`serviceAccountToken`, fichier `token`), le certificat de la CA du cluster (`ca.crt`, tiré de la ConfigMap `kube-root-ca.crt` présente dans chaque namespace) et le namespace du pod (`namespace`, par l'API *downward*). Le jeton est **lié** : il porte l'audience de l'API server, une date d'expiration, et les nom et UID du pod (ainsi que ceux de son nœud) ; il cesse d'être valable quand le pod ou le ServiceAccount est supprimé. Le kubelet l'obtient par l'API *TokenRequest* et le renouvelle dès qu'il a dépassé 80 % de sa durée de vie ou 24 heures ; l'application doit relire le fichier régulièrement.

> [!note]
> La durée demandée pour ce jeton par défaut est de 3607 secondes. Pour ne pas casser les applications qui ne relisent jamais leur jeton, l'API server, avec `--service-account-extend-token-expiration=true` (défaut), le rend valable un an, tout en notant dans le jeton (revendication `warnafter`) le moment où il aurait dû expirer. Les journaux d'audit signalent les clients qui utilisent un jeton au-delà de cette heure.

`automountServiceAccountToken: false` se pose sur le ServiceAccount (pour tous ses pods) ou sur le pod ; **la valeur du pod l'emporte**. C'est la bonne pratique pour tout pod qui n'appelle pas l'API : un jeton monté sans raison est un jeton à voler.

#### Obtenir un jeton : kubectl create token

`kubectl create token <sa>` appelle la sous-ressource `serviceaccounts/token` (verbe `create`) et affiche un jeton JWT lié, que rien ne stocke dans le cluster :

| Option | Effet | Défaut |
|---|---|---|
| `--duration` | durée de vie demandée | celle du serveur : 1 heure ; minimum 10 minutes ; plafond `--service-account-max-token-expiration` s'il est défini |
| `--audience` (répétable) | audience(s) du jeton | celle de l'API server (`--api-audiences`, à défaut l'émetteur `--service-account-issuer`) |
| `--bound-object-kind`, `--bound-object-name` | lie le jeton à un `Pod`, un `Secret` ou un `Node` : il expire avec l'objet | non lié |
| `-o yaml` | affiche l'objet TokenRequest : audiences, `expirationSeconds`, `status.expirationTimestamp` | jeton seul |

Sur le lab comme sur kubeadm, l'émetteur est `https://kubernetes.default.svc.cluster.local`, et c'est l'audience par défaut. Un jeton demandé pour une autre audience (`--audience=https://coffre.example`) est refusé par l'API server (401) : il est destiné à un autre service, qui le vérifiera avec les clés publiques publiées par le cluster. Chaque jeton porte aussi un identifiant unique (`jti`), qui apparaît dans `kubectl auth whoami` sous l'extra `authentication.kubernetes.io/credential-id` (`JTI=…`). Il n'existe **aucun moyen de révoquer** un jeton lié, sinon de supprimer l'objet auquel il est lié ou le ServiceAccount lui-même : on le demande donc court.

#### Le jeton de longue durée

Avant 1.24, chaque ServiceAccount recevait automatiquement un Secret contenant un jeton sans expiration. Ce n'est plus le cas. Si un outil exige un jeton permanent, on crée soi-même un Secret de type `kubernetes.io/service-account-token` annoté du nom du ServiceAccount ; le contrôleur de jetons du kube-controller-manager y écrit `token`, `ca.crt` et `namespace`, et ajoute l'annotation `kubernetes.io/service-account.uid`.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: deployeur-jeton
  namespace: boutique
  annotations:
    kubernetes.io/service-account.name: deployeur
type: kubernetes.io/service-account-token
```

Ce jeton n'expire jamais et ne porte pas d'audience restreinte : il reste valable tant que le Secret et le ServiceAccount existent. Le révoquer, c'est **supprimer le Secret**. L'effet n'est pas instantané : l'API server garde en cache pendant 10 secondes chaque authentification par jeton réussie, si bien qu'un jeton vérifié juste avant la suppression est encore accepté quelques secondes après. Les anciens jetons créés automatiquement (ceux que le champ `secrets` du ServiceAccount référence) sont, depuis 1.30, marqués invalides après un an sans usage (label `kubernetes.io/legacy-token-invalid-since`), puis supprimés après une seconde année ; les Secrets créés à la main ne sont pas concernés.

#### Vérifier un jeton : TokenReview

L'API `TokenReview` (`authentication.k8s.io/v1`) demande à l'API server de valider un jeton et d'en extraire l'identité, sans l'utiliser. L'objet n'est pas stocké : on le crée et on lit la réponse.

```yaml
apiVersion: authentication.k8s.io/v1
kind: TokenReview
spec:
  token: eyJhbGciOiJSUzI1NiIsImtpZCI6IjEifQ.exemple.signature
  audiences:
  - https://coffre.example
```

`status.authenticated` vaut `true` et `status.user` donne nom, UID, groupes et extras quand le jeton est valide pour l'une des audiences demandées (sans `audiences`, celles de l'API server) ; sinon le champ `authenticated` est absent et `status.error` explique le refus.

### 16.10 Vérifier les droits : auth can-i, auth whoami, usurpation

#### kubectl auth can-i

`kubectl auth can-i VERBE RESSOURCE[/NOM]` envoie une `SelfSubjectAccessReview` et répond `yes` ou `no`, avec un code de retour 0 ou 1 (`-q` supprime l'affichage, pratique dans un script). Le namespace est celui du contexte, ou `-n`, ou tous avec `-A`. Les noms courts et les groupes sont résolus : `deploy`, `deployments.apps`.

```bash
kubectl auth can-i list pods -n boutique
kubectl auth can-i patch deployments.apps/front -n boutique        # un objet précis
kubectl auth can-i get pods --subresource=log -n boutique          # une sous-ressource
kubectl auth can-i get /healthz                                     # URL hors ressource
kubectl auth can-i '*' '*' -n boutique                              # tout ?
kubectl auth can-i --list -n boutique                               # tout ce que je peux faire
```

> [!danger]
> `kubectl auth can-i get pods/log` ne teste **pas** la sous-ressource `log` : la barre oblique sépare la ressource du **nom** de l'objet, et la commande demande « puis-je lire le pod nommé `log` ? ». Pour une sous-ressource, utilise toujours `--subresource=log`. `--list` ne se combine ni avec `--subresource`, ni avec `-A`, ni avec `-q`, et sa liste peut être incomplète quand un autorisateur webhook est en jeu.

#### L'usurpation d'identité : --as, --as-group

Les options `--as`, `--as-group`, `--as-uid` et `--as-user-extra` de kubectl envoient les en-têtes `Impersonate-User`, `Impersonate-Group`, etc. L'API server authentifie d'abord le demandeur, vérifie qu'il a le verbe `impersonate` sur l'attribut usurpé (`users`, `groups`, `serviceaccounts`, `uids`, `userextras/<clé>`), puis traite la requête **comme si** elle venait de l'identité usurpée. Combinées à `can-i`, ces options testent les droits d'un tiers sans posséder ses identifiants. `cluster-admin` (et donc l'administrateur de l'examen) a ce droit.

La règle qui piège tout le monde concerne les groupes. Avec `--as=alice` seul, l'identité usurpée est `alice` dans le seul groupe `system:authenticated` : **les groupes de son certificat ne sont pas devinés**, puisque l'API server ne voit pas ce certificat. Si les droits d'alice viennent d'une liaison au groupe `developpeurs`, `kubectl auth can-i list pods --as=alice` répond `no` ; il faut `--as=alice --as-group=developpeurs`. Pour un ServiceAccount, en revanche, les groupes se déduisent du nom : `--as=system:serviceaccount:boutique:deployeur` reçoit automatiquement `system:serviceaccounts`, `system:serviceaccounts:boutique` et `system:authenticated`. `kubectl auth whoami --as=alice` montre exactement l'identité usurpée et permet de le constater.

#### kubectl auth whoami

`kubectl auth whoami` (GA depuis 1.28) envoie une `SelfSubjectReview` et affiche l'identité que l'API server t'attribue réellement : nom, UID s'il existe, groupes et extras. C'est le premier réflexe quand un 403 surprend : le kubeconfig utilise-t-il bien l'identité que tu crois ? `-o yaml` donne la réponse complète.

> [!tip] Réflexe d'examen
> Après toute tâche RBAC, prouve le résultat dans les deux sens, en usurpant le sujet exact de l'énoncé : un `yes` sur ce qui doit être permis, un `no` sur ce qui ne doit pas l'être (un autre verbe, un autre namespace, les Secrets). Pour un ServiceAccount, la forme est toujours `--as=system:serviceaccount:<ns>:<nom>`.

### 16.11 À l'examen : la méthode rapide

Tout RBAC se crée en impératif, ce qui évite le YAML et ses fautes de frappe :

```bash
kubectl -n boutique create serviceaccount deployeur
kubectl -n boutique create role lecture-pods --verb=get,list,watch --resource=pods
kubectl -n boutique create role lecture-journaux --verb=get --resource=pods/log
kubectl create clusterrole lecteur-noeuds --verb=get,list,watch --resource=nodes
kubectl create clusterrole agrege --aggregation-rule="rbac.example/aggregate-to-supervision=true"
kubectl -n boutique create rolebinding developpeurs --role=developpeur --group=developpeurs
kubectl -n boutique create rolebinding deployeur --role=deployeur --serviceaccount=boutique:deployeur
kubectl -n boutique create rolebinding alice-view --clusterrole=view --user=alice
kubectl create clusterrolebinding lecteur-noeuds-alice --clusterrole=lecteur-noeuds --user=alice
kubectl -n boutique create token deployeur --duration=1h
```

`kubectl create role` résout chaque ressource en interrogeant la découverte de l'API (`deployments` devient `deployments` du groupe `apps`) : il a besoin du serveur, même avec `--dry-run=client`. Il génère une règle par groupe d'API, avec les mêmes verbes pour toutes. Quand des ressources demandent des verbes différents (tout sur `pods`, seulement `get` sur `pods/log`), génère le YAML de la première partie avec `--dry-run=client -o yaml`, ajoute la règle manquante à la main, puis applique. Les verbes acceptés sans avertissement sont `get`, `list`, `watch`, `create`, `update`, `patch`, `delete`, `deletecollection`, `proxy`, `use`, `bind`, `escalate`, `impersonate` et `*` ; un autre verbe (`approve`, par exemple) passe avec `Warning: 'approve' is not a standard resource verb`. Les verbes spéciaux ne valent que sur leurs ressources (`bind` et `escalate` sur `roles` et `clusterroles`, `impersonate` sur `users`, `groups`, `serviceaccounts` et `userextras`) : ailleurs, kubectl refuse de générer la règle (`error: can not perform 'bind' on 'pods' in group ''`). `--resource-name` ajoute des `resourceNames`.

Les pages à ouvrir sont *Using RBAC Authorization* (`/docs/reference/access-authn-authz/rbac/`), qui contient des exemples de règles et toutes les commandes impératives, *Configure Service Accounts for Pods* (`/docs/tasks/configure-pod-container/configure-service-account/`) et la page CSR citée en 16.3. `kubectl explain role.rules` et `kubectl explain rolebinding.subjects` rappellent les champs.

Une tâche RBAC typique tient en cinq étapes : lire l'énoncé pour noter le **sujet** (utilisateur, groupe ou ServiceAccount, avec son namespace), la **portée** (un namespace ou le cluster), les **ressources** avec leur groupe et leurs sous-ressources, et les **verbes** exacts ; créer le rôle ; créer la liaison ; vérifier par `can-i` en usurpant le sujet ; vérifier aussi un refus.

### 16.12 Pièges courants

```
Piège 1 : --as sans --as-group pour un droit accordé à un groupe
═════════════════════════════════════════════════════════════════
  MAUVAIS  : kubectl auth can-i list pods --as=alice -n boutique   → no
  SYMPTÔME : on croit la liaison cassée, alors qu'elle vise le groupe.
  BON      : --as=alice --as-group=developpeurs, ou tester avec le
             contexte d'alice (kubectl --context alice@cka …).

Piège 2 : kubectl auth can-i get pods/log
══════════════════════════════════════════
  SYMPTÔME : « yes » alors que pods/log n'est pas accordé : la commande
             a testé le pod nommé « log ».
  BON      : kubectl auth can-i get pods --subresource=log

Piège 3 : ClusterRole sur des nœuds lié par une RoleBinding
════════════════════════════════════════════════════════════
  SYMPTÔME : Forbidden sur kubectl get nodes malgré la liaison.
  BON      : ClusterRoleBinding pour toute ressource sans namespace.

Piège 4 : Sujet ServiceAccount mal écrit
═════════════════════════════════════════
  MAUVAIS  : --user=deployeur, ou kind: ServiceAccount sans namespace.
  BON      : --serviceaccount=boutique:deployeur ; en YAML,
             kind: ServiceAccount, name, namespace, sans apiGroup.

Piège 5 : base64 sans -w0 dans la CSR
═════════════════════════════════════
  SYMPTÔME : YAML invalide, ou requête PEM illisible à la création.
  BON      : request: $(base64 -w0 < alice.csr)

Piège 6 : CSR approuvée mais pas de certificat
══════════════════════════════════════════════
  SYMPTÔME : CONDITION « Approved,Failed », status.certificate vide.
  CAUSE    : usages non permis (server auth…), signerName erroné.
  BON      : usages: [client auth], signerName kube-apiserver-client.

Piège 7 : Changer le rôle d'une liaison
═══════════════════════════════════════
  SYMPTÔME : « roleRef: Invalid value: … field is immutable ».
  BON      : supprimer et recréer la liaison (ou kubectl auth reconcile).

Piège 8 : --token avec un contexte qui porte déjà un certificat
════════════════════════════════════════════════════════════════
  SYMPTÔME : le test « en tant que ServiceAccount » réussit trop bien :
             le client présente aussi son certificat, et l'API server
             peut l'authentifier par ce dernier (l'ordre n'est pas garanti).
  BON      : un contexte dédié (set-credentials --token), ou --as.

Piège 9 : Croire qu'un rôle sans « secrets » protège les Secrets
═════════════════════════════════════════════════════════════════
  SYMPTÔME : un sujet qui crée des pods lit les Secrets en les montant.
  BON      : traiter la création de pods comme un accès aux Secrets
             et aux ServiceAccounts du namespace.
```

> [!summary] À retenir
> - 401 = identité non reconnue ; 403 = identité reconnue mais refusée. L'admission ne vient qu'après.
> - Pas d'objet utilisateur : un certificat donne `CN` = nom et `O` = groupes ; les ServiceAccounts sont `system:serviceaccount:<ns>:<nom>`.
> - `system:masters` contourne l'autorisation et ne se révoque pas ; kubeadm le réserve à `super-admin.conf` et donne `admin.conf` au groupe `kubeadm:cluster-admins`.
> - CSR : `request` en `base64 -w0`, `signerName: kubernetes.io/kube-apiserver-client`, `usages: [client auth]`, `expirationSeconds` ≥ 600 ; puis `kubectl certificate approve` et `base64 -d` du `status.certificate`.
> - RBAC est additif, sans refus ; Role et RoleBinding pour un namespace, ClusterRole et ClusterRoleBinding pour le cluster et les ressources sans namespace ; `roleRef` est immuable.
> - Les sous-ressources s'accordent à part (`pods/log`, `pods/exec` en `create`, `deployments/scale`) ; `resourceNames` ne restreint ni `create` ni un `list` sans sélecteur de champ.
> - Escalade : créer un rôle exige ses permissions ou `escalate` ; créer une liaison exige les permissions du rôle ou `bind` ; créer des pods donne accès aux Secrets et ServiceAccounts du namespace.
> - `view` exclut les Secrets ; `edit` et `admin` les incluent ; `admin` gère en plus Roles et RoleBindings ; agrégation par les labels `aggregate-to-*`.
> - `kubectl create token` : 1 h par défaut, 10 min au minimum, audience de l'API server ; jeton permanent = Secret `kubernetes.io/service-account-token`, révoqué en supprimant le Secret.
> - `can-i` : `--subresource` pour une sous-ressource, `--as-group` pour un droit de groupe, `--as=system:serviceaccount:<ns>:<nom>` pour un ServiceAccount.

### 16.13 Exercices

#### Exercice 16.1 — Un certificat pour alice

**Point de départ** : exercice 15.6, ou instantané I3.

Dans `~/cka/rbac/`, crée une clé RSA de 3072 bits et une demande de certificat pour l'utilisateur `alice` du groupe `developpeurs`. Soumets-la au cluster sous le nom `alice`, pour le signataire des clients de l'API server, avec une validité de sept jours. Approuve-la, récupère le certificat dans `~/cka/rbac/alice.crt` et vérifie son sujet et sa date d'expiration. Ajoute à ton kubeconfig l'utilisateur `alice`, certificat et clé intégrés au fichier, et le contexte `alice@cka` (cluster `cka`, namespace `boutique`). Que peut faire alice à ce stade ?

> [!example]- Solution
> ```bash
> mkdir -p ~/cka/rbac && cd ~/cka/rbac
> openssl genrsa -out alice.key 3072
> openssl req -new -key alice.key -out alice.csr -subj "/CN=alice/O=developpeurs"
> openssl req -in alice.csr -noout -subject
> cat > alice-csr.yaml <<EOF
> apiVersion: certificates.k8s.io/v1
> kind: CertificateSigningRequest
> metadata:
>   name: alice
> spec:
>   request: $(base64 -w0 < alice.csr)
>   signerName: kubernetes.io/kube-apiserver-client
>   expirationSeconds: 604800
>   usages:
>   - client auth
> EOF
> kubectl apply -f alice-csr.yaml
> kubectl get csr alice
> kubectl certificate approve alice
> kubectl get csr alice
> kubectl get csr alice -o jsonpath='{.status.certificate}' | base64 -d > alice.crt
> openssl x509 -in alice.crt -noout -subject -issuer -enddate
> kubectl config set-credentials alice --client-certificate=alice.crt --client-key=alice.key --embed-certs=true
> kubectl config set-context alice@cka --cluster=cka --user=alice --namespace=boutique
> kubectl --context alice@cka auth whoami
> kubectl --context alice@cka get pods
> ```
>
> La demande affiche `subject=CN=alice, O=developpeurs`. Avant approbation, `kubectl get csr alice` montre `SIGNERNAME kubernetes.io/kube-apiserver-client`, `REQUESTOR minikube-user` (l'identité qui a créé la CSR ; `kubernetes-admin` sur un cluster kubeadm), `REQUESTEDDURATION 7d` et `CONDITION Pending` ; après, `Approved,Issued`. Le certificat affiche `subject=O=developpeurs, CN=alice` (même sujet, attributs dans l'ordre où le signataire les écrit), est émis par `CN=minikubeCA` et expire sept jours plus tard, 604 800 secondes étant sous le plafond d'un an du controller-manager. `--embed-certs=true` copie certificat et clé en base64 dans le kubeconfig (`client-certificate-data`, `client-key-data`) : le kubeconfig ne dépend plus des fichiers. La clé privée n'a jamais quitté le poste. alice est authentifiée, mais aucun droit ne lui est encore accordé au-delà des rôles de découverte : `get pods` échoue avec `Error from server (Forbidden): pods is forbidden: User "alice" cannot list resource "pods" in API group "" in the namespace "boutique"`.
>
> **Vérification** : `kubectl --context alice@cka auth whoami` affiche `Username alice` et `Groups [developpeurs system:authenticated]` ; `kubectl config get-contexts alice@cka` montre le cluster `cka`, l'utilisateur `alice` et le namespace `boutique`.

#### Exercice 16.2 — Le rôle des développeurs

**Point de départ** : exercice 16.1.

Dans `boutique`, crée le Role `developpeur` : `get`, `list`, `watch`, `create`, `update`, `patch` et `delete` sur les pods, services, configmaps et deployments ; `get` sur les journaux des pods ; rien sur les Secrets. Lie-le au groupe `developpeurs` par la RoleBinding `developpeurs`. Vérifie avec `kubectl auth can-i`, en usurpant alice, qu'elle peut lister les pods et lire leurs journaux dans `boutique`, mais pas lire les Secrets, ni ouvrir un shell dans un pod, ni lister les pods de `default`. Confirme avec le contexte `alice@cka`.

> [!example]- Solution
> ```yaml
> # ~/cka/rbac/developpeur.yaml
> apiVersion: rbac.authorization.k8s.io/v1
> kind: Role
> metadata:
>   name: developpeur
>   namespace: boutique
> rules:
> - apiGroups: [""]
>   resources: ["pods", "services", "configmaps"]
>   verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
> - apiGroups: ["apps"]
>   resources: ["deployments"]
>   verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
> - apiGroups: [""]
>   resources: ["pods/log"]
>   verbs: ["get"]
> ---
> apiVersion: rbac.authorization.k8s.io/v1
> kind: RoleBinding
> metadata:
>   name: developpeurs
>   namespace: boutique
> roleRef:
>   apiGroup: rbac.authorization.k8s.io
>   kind: Role
>   name: developpeur
> subjects:
> - apiGroup: rbac.authorization.k8s.io
>   kind: Group
>   name: developpeurs
> ```
>
> ```bash
> kubectl apply -f ~/cka/rbac/developpeur.yaml
> kubectl auth can-i list pods -n boutique --as=alice
> kubectl auth can-i list pods -n boutique --as=alice --as-group=developpeurs
> kubectl auth can-i get pods --subresource=log -n boutique --as=alice --as-group=developpeurs
> kubectl auth can-i patch deployments -n boutique --as=alice --as-group=developpeurs
> kubectl auth can-i get secrets -n boutique --as=alice --as-group=developpeurs
> kubectl auth can-i create pods --subresource=exec -n boutique --as=alice --as-group=developpeurs
> kubectl auth can-i list pods -n default --as=alice --as-group=developpeurs
> kubectl --context alice@cka get pods
> kubectl --context alice@cka logs deployment/api --tail=2
> kubectl --context alice@cka get secrets
> ```
>
> Le rôle compte trois règles, car les deployments sont dans le groupe `apps` et `pods/log` n'a pas les mêmes verbes que `pods`. En impératif, la première partie s'obtient par `kubectl -n boutique create role developpeur --verb=get,list,watch,create,update,patch,delete --resource=pods,services,configmaps,deployments --dry-run=client -o yaml`, à compléter de la règle `pods/log` avant de l'appliquer ; la liaison, par `kubectl -n boutique create rolebinding developpeurs --role=developpeur --group=developpeurs`. Le premier `can-i` répond `no` : sans `--as-group`, l'identité usurpée n'a que `system:authenticated`, et le droit est accordé au groupe. Les suivants répondent `yes`, `yes`, `yes`, puis `no` pour les Secrets, `no` pour `exec` (il faudrait `create` sur `pods/exec`) et `no` dans `default`. Avec son propre certificat, alice liste les pods et lit les journaux de `api`, et se voit refuser les Secrets.
>
> **Vérification** : `kubectl -n boutique get rolebinding developpeurs -o wide` montre `Role/developpeur` et le groupe `developpeurs` ; `kubectl --context alice@cka get secrets` répond `Error from server (Forbidden): secrets is forbidden: User "alice" cannot list resource "secrets" in API group "" in the namespace "boutique"`.

#### Exercice 16.3 — Lire les nœuds

**Point de départ** : exercice 16.2.

Donne à alice, et à elle seule, le droit de lire les nœuds du cluster : ClusterRole `lecteur-noeuds` (`get`, `list`, `watch` sur `nodes`) et ClusterRoleBinding `lecteur-noeuds-alice`. Vérifie qu'alice liste les nœuds, mais pas les PersistentVolumes, et que les autres membres de `developpeurs` n'ont pas reçu ce droit.

> [!example]- Solution
> ```bash
> kubectl create clusterrole lecteur-noeuds --verb=get,list,watch --resource=nodes
> kubectl create clusterrolebinding lecteur-noeuds-alice --clusterrole=lecteur-noeuds --user=alice
> kubectl --context alice@cka get nodes
> kubectl --context alice@cka get pv
> kubectl auth can-i list nodes -A --as=bob --as-group=developpeurs
> kubectl auth can-i list nodes -A --as=alice
> ```
>
> `-A` pose la question sans namespace, ce qui convient à une ressource qui n'en a pas ; sans lui, `can-i` ajoute le namespace du contexte et affiche l'avertissement `resource 'nodes' is not namespace scoped`, sans changer la réponse. Les nœuds n'ont pas de namespace : seule une ClusterRoleBinding rend ce droit effectif. Une RoleBinding vers le même ClusterRole, dans `boutique`, n'aurait rien donné. La liaison vise l'utilisateur `alice`, pas le groupe : un autre développeur (`bob`, usurpé avec le même groupe) n'en profite pas, et `--as=alice` suffit ici puisque le sujet est l'utilisateur lui-même. Lire les nœuds ne donne pas leurs métriques : `kubectl --context alice@cka top nodes` serait refusé, la ressource `nodes` du groupe `metrics.k8s.io` étant distincte.
>
> **Vérification** : alice voit `cka`, `cka-m02` et `cka-m03` ; `kubectl --context alice@cka get pv` répond `Forbidden … cannot list resource "persistentvolumes"` ; le `can-i` pour `bob` répond `no`, celui pour `alice` répond `yes`.

#### Exercice 16.4 — Un compte de déploiement

**Point de départ** : exercice 16.3.

Dans `boutique`, crée le ServiceAccount `deployeur`, le Role `deployeur` (`get`, `list`, `patch`, `update` sur les deployments ; `get`, `update`, `patch` sur leur sous-ressource `scale`) et la RoleBinding `deployeur`. Vérifie par usurpation que le compte peut changer le nombre de réplicas d'un deployment, mais pas lister les pods. Obtiens ensuite un jeton d'une heure pour ce compte, et utilise-le dans un contexte temporaire `deployeur@cka` pour identifier le compte, faire passer `front` à 4 réplicas puis le ramener à 3, et constater le refus sur les pods. Supprime enfin le contexte et l'utilisateur temporaires de ton kubeconfig.

> [!example]- Solution
> ```yaml
> # ~/cka/rbac/deployeur.yaml
> apiVersion: v1
> kind: ServiceAccount
> metadata:
>   name: deployeur
>   namespace: boutique
> ---
> apiVersion: rbac.authorization.k8s.io/v1
> kind: Role
> metadata:
>   name: deployeur
>   namespace: boutique
> rules:
> - apiGroups: ["apps"]
>   resources: ["deployments"]
>   verbs: ["get", "list", "patch", "update"]
> - apiGroups: ["apps"]
>   resources: ["deployments/scale"]
>   verbs: ["get", "update", "patch"]
> ---
> apiVersion: rbac.authorization.k8s.io/v1
> kind: RoleBinding
> metadata:
>   name: deployeur
>   namespace: boutique
> roleRef:
>   apiGroup: rbac.authorization.k8s.io
>   kind: Role
>   name: deployeur
> subjects:
> - kind: ServiceAccount
>   name: deployeur
>   namespace: boutique
> ```
>
> ```bash
> kubectl apply -f ~/cka/rbac/deployeur.yaml
> SA=system:serviceaccount:boutique:deployeur
> kubectl auth can-i patch deployments --subresource=scale -n boutique --as=$SA
> kubectl auth can-i list pods -n boutique --as=$SA
> kubectl auth can-i --list -n boutique --as=$SA
> kubectl -n boutique create token deployeur --duration=1h -o yaml | grep -E 'expirationSeconds|expirationTimestamp|- https'
> TOKEN=$(kubectl -n boutique create token deployeur --duration=1h)
> kubectl config set-credentials deployeur --token="$TOKEN"
> kubectl config set-context deployeur@cka --cluster=cka --user=deployeur --namespace=boutique
> kubectl --context deployeur@cka auth whoami
> kubectl --context deployeur@cka scale deployment front --replicas=4
> kubectl --context deployeur@cka scale deployment front --replicas=3
> kubectl --context deployeur@cka get pods
> kubectl config delete-context deployeur@cka
> kubectl config delete-user deployeur
> ```
>
> Les deux `can-i` répondent `yes` puis `no` ; `--list` montre `deployments.apps` et `deployments.apps/scale` avec leurs verbes, plus les droits de découverte communs à tous. Le jeton demandé en `-o yaml` montre `expirationSeconds: 3600`, l'audience `https://kubernetes.default.svc.cluster.local` et l'heure d'expiration. Le contexte temporaire n'a **que** le jeton : avec le contexte `cka`, qui porte déjà un certificat client, `--token` pourrait être ignoré au profit du certificat. `whoami` affiche `Username system:serviceaccount:boutique:deployeur`, l'UID du ServiceAccount, les groupes `[system:serviceaccounts system:serviceaccounts:boutique system:authenticated]` et l'extra `authentication.kubernetes.io/credential-id [JTI=…]`. `kubectl scale` lit le deployment (`get`) puis modifie `deployments/scale` (`patch`) : `deployment.apps/front scaled`. Le rôle n'a pas `watch` : `kubectl rollout status` serait refusé, ce qui est voulu ici. La liste des pods est refusée : `User "system:serviceaccount:boutique:deployeur" cannot list resource "pods"`.
>
> **Vérification** : `kubectl -n boutique get deployment front` affiche de nouveau `3/3` ; `kubectl config get-contexts` ne liste plus `deployeur@cka` ; `kubectl -n boutique get sa,role,rolebinding deployeur` montre les trois objets.

#### Exercice 16.5 — Les garde-fous de l'escalade

**Point de départ** : exercice 16.4.

Donne temporairement à alice le droit de gérer les rôles et liaisons de `boutique` : Role `gestion-roles` (`get`, `list`, `create`, `delete` sur `roles` et `rolebindings`) lié à l'utilisateur `alice` par la RoleBinding `alice-gestion-roles`. Avec le contexte d'alice, tente de créer un rôle `lire-secrets` (`get` sur les secrets), puis un rôle `lire-pods` (`get`, `list` sur les pods), puis une RoleBinding `bob-view` qui accorde le ClusterRole `view` à l'utilisateur `bob`. Explique chaque résultat. Accorde ensuite à alice, dans `gestion-roles`, le seul droit de lier `view`, et retente la dernière opération. Supprime enfin tout ce que cet exercice a créé.

> [!example]- Solution
> ```yaml
> # ~/cka/rbac/gestion-roles.yaml
> apiVersion: rbac.authorization.k8s.io/v1
> kind: Role
> metadata:
>   name: gestion-roles
>   namespace: boutique
> rules:
> - apiGroups: ["rbac.authorization.k8s.io"]
>   resources: ["roles", "rolebindings"]
>   verbs: ["get", "list", "create", "delete"]
> ---
> apiVersion: rbac.authorization.k8s.io/v1
> kind: RoleBinding
> metadata:
>   name: alice-gestion-roles
>   namespace: boutique
> roleRef:
>   apiGroup: rbac.authorization.k8s.io
>   kind: Role
>   name: gestion-roles
> subjects:
> - apiGroup: rbac.authorization.k8s.io
>   kind: User
>   name: alice
> ```
>
> ```bash
> kubectl apply -f ~/cka/rbac/gestion-roles.yaml
> kubectl --context alice@cka create role lire-secrets --verb=get --resource=secrets
> kubectl --context alice@cka create role lire-pods --verb=get,list --resource=pods
> kubectl --context alice@cka create rolebinding bob-view --clusterrole=view --user=bob
> ```
>
> Le premier essai échoue : `user "alice" (groups=["developpeurs" "system:authenticated"]) is attempting to grant RBAC permissions not currently held: {APIGroups:[""], Resources:["secrets"], Verbs:["get"]}`. alice peut créer des rôles, mais pas y mettre une permission qu'elle n'a pas. Le second réussit (`role.rbac.authorization.k8s.io/lire-pods created`) : elle détient déjà `get` et `list` sur les pods. Le troisième échoue sur le même message, préfixé cette fois par kubectl (`error: failed to create rolebinding: rolebindings.rbac.authorization.k8s.io "bob-view" is forbidden: …`) et suivi de la longue liste des permissions de `view` qu'elle ne détient pas (événements, ReplicaSets, Jobs…). On ajoute alors au rôle une règle de délégation, limitée à `view` :
>
> ```yaml
> # ~/cka/rbac/gestion-roles.yaml (Role modifié)
> apiVersion: rbac.authorization.k8s.io/v1
> kind: Role
> metadata:
>   name: gestion-roles
>   namespace: boutique
> rules:
> - apiGroups: ["rbac.authorization.k8s.io"]
>   resources: ["roles", "rolebindings"]
>   verbs: ["get", "list", "create", "delete"]
> - apiGroups: ["rbac.authorization.k8s.io"]
>   resources: ["clusterroles"]
>   resourceNames: ["view"]
>   verbs: ["bind"]
> ```
>
> ```bash
> kubectl apply -f ~/cka/rbac/gestion-roles.yaml
> kubectl auth can-i bind clusterroles/view -n boutique --as=alice
> kubectl --context alice@cka create rolebinding bob-view --clusterrole=view --user=bob
> kubectl -n boutique delete rolebinding bob-view alice-gestion-roles
> kubectl -n boutique delete role lire-pods gestion-roles
> ```
>
> Le contrôle de `bind` se fait dans le namespace de la liaison créée : la règle du Role de `boutique` suffit pour des RoleBindings de `boutique`. C'est aussi pourquoi le `can-i` garde `-n boutique` : il affiche l'avertissement `Warning: resource 'clusterroles' is not namespace scoped in group 'rbac.authorization.k8s.io'`, mais pose bien la question dans `boutique`, et répond `yes`. alice peut désormais distribuer `view` dans ce namespace, sans pouvoir l'utiliser elle-même au-delà de ses propres droits, et sans pouvoir lier `edit` ou `admin`. Le verbe `escalate` sur `roles` lui aurait, lui, permis d'écrire n'importe quelle permission dans un rôle : c'est un droit d'administrateur.
>
> **Vérification** : `kubectl auth can-i bind clusterroles/view -n boutique --as=alice` répondait `yes` avant le nettoyage ; à la fin, `kubectl -n boutique get roles,rolebindings` ne liste plus que les Roles `developpeur` et `deployeur` et les RoleBindings `developpeurs` et `deployeur`.

#### Exercice 16.6 — Les jetons des ServiceAccounts

**Point de départ** : exercice 16.5.

Dans `boutique`, lance deux pods temporaires sous le ServiceAccount `deployeur`, image `busybox:1.37.0`, commande `sleep 3600`, labels `tier=outils` : `inspecteur` (labels `app=inspecteur`), avec le montage de jeton par défaut, et `sans-jeton` (labels `app=sans-jeton`), sans montage de jeton. Compare le contenu de `/var/run/secrets/kubernetes.io/serviceaccount` dans les deux pods et relève la durée demandée pour le jeton projeté. Crée ensuite le Secret `deployeur-jeton` qui porte un jeton permanent du compte, vérifie ce jeton par une TokenReview, supprime le Secret et vérifie de nouveau. Termine par un jeton de dix minutes destiné à l'audience `https://coffre.example`, et montre que l'API server le refuse alors qu'il est valide pour son audience. Supprime les pods.

> [!example]- Solution
> ```yaml
> # ~/cka/rbac/jetons.yaml
> apiVersion: v1
> kind: Pod
> metadata:
>   name: inspecteur
>   namespace: boutique
>   labels:
>     app: inspecteur
>     tier: outils
> spec:
>   serviceAccountName: deployeur
>   containers:
>   - name: inspecteur
>     image: busybox:1.37.0
>     command: ["sh", "-c", "sleep 3600"]
> ---
> apiVersion: v1
> kind: Pod
> metadata:
>   name: sans-jeton
>   namespace: boutique
>   labels:
>     app: sans-jeton
>     tier: outils
> spec:
>   serviceAccountName: deployeur
>   automountServiceAccountToken: false
>   containers:
>   - name: sans-jeton
>     image: busybox:1.37.0
>     command: ["sh", "-c", "sleep 3600"]
> ---
> apiVersion: v1
> kind: Secret
> metadata:
>   name: deployeur-jeton
>   namespace: boutique
>   annotations:
>     kubernetes.io/service-account.name: deployeur
> type: kubernetes.io/service-account-token
> ```
>
> ```bash
> kubectl apply -f ~/cka/rbac/jetons.yaml
> kubectl -n boutique wait --for=condition=Ready pod/inspecteur pod/sans-jeton --timeout=60s
> kubectl -n boutique exec inspecteur -- ls /var/run/secrets/kubernetes.io/serviceaccount
> kubectl -n boutique get pod inspecteur -o jsonpath='{.spec.volumes[0].projected.sources[0]}{"\n"}'
> kubectl -n boutique exec sans-jeton -- ls /var/run/secrets/kubernetes.io/serviceaccount
> kubectl -n boutique describe secret deployeur-jeton
>
> JETON=$(kubectl -n boutique get secret deployeur-jeton -o jsonpath='{.data.token}' | base64 -d)
> cat <<EOF | kubectl create -o jsonpath='{.status.authenticated} {.status.user.username}{"\n"}' -f -
> apiVersion: authentication.k8s.io/v1
> kind: TokenReview
> spec:
>   token: $JETON
> EOF
> kubectl -n boutique delete secret deployeur-jeton
> sleep 10                                  # cache d'authentification de l'API server
> cat <<EOF | kubectl create -o jsonpath='{.status.authenticated} {.status.user.username}{"\n"}' -f -
> apiVersion: authentication.k8s.io/v1
> kind: TokenReview
> spec:
>   token: $JETON
> EOF
>
> JETON=$(kubectl -n boutique create token deployeur --duration=10m --audience=https://coffre.example)
> cat <<EOF | kubectl create -o jsonpath='{.status.authenticated} {.status.user.username}{"\n"}' -f -
> apiVersion: authentication.k8s.io/v1
> kind: TokenReview
> spec:
>   token: $JETON
> EOF
> cat <<EOF | kubectl create -o jsonpath='{.status.authenticated} {.status.user.username}{"\n"}' -f -
> apiVersion: authentication.k8s.io/v1
> kind: TokenReview
> spec:
>   token: $JETON
>   audiences:
>   - https://coffre.example
> EOF
> kubectl -n boutique delete pod inspecteur sans-jeton --now
> ```
>
> `inspecteur` contient `ca.crt`, `namespace` et `token`, et son volume `kube-api-access-…` demande `{"serviceAccountToken":{"expirationSeconds":3607,"path":"token"}}`. Dans `sans-jeton`, le répertoire n'existe pas : `ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory` et `command terminated with exit code 1`. Le Secret a été complété par le contrôleur de jetons : `describe` montre l'annotation `kubernetes.io/service-account.uid` et les clés `ca.crt`, `namespace` et `token`. La première TokenReview répond `true system:serviceaccount:boutique:deployeur` ; après la suppression du Secret, la réponse est vide : `authenticated` vaut `false` (champ omis), et `-o yaml` montrerait `status.error` : `[invalid bearer token, Token has been invalidated]`. Le jeton permanent est révoqué. Le `sleep 10` n'est pas décoratif : l'API server garde 10 secondes en cache les authentifications par jeton réussies, et une TokenReview lancée aussitôt après la suppression répond encore `true` (8 à 9 secondes mesurées sur le lab avant le refus). Le jeton destiné à `https://coffre.example` n'est pas valide pour l'audience de l'API server (réponse vide), mais il l'est quand la TokenReview demande son audience (`true system:serviceaccount:boutique:deployeur`) : c'est ainsi qu'un service tiers vérifierait les jetons qui lui sont destinés. La création de pods affiche aussi les avertissements Pod Security du mode `warn` (chapitre 8). `--now` épargne les 30 secondes du délai de grâce, que `sh` en PID 1 ignore.
>
> **Vérification** : les sorties décrites ci-dessus ; à la fin, `kubectl -n boutique get pods -l tier=outils` ne liste plus ni `inspecteur` ni `sans-jeton`, et `kubectl -n boutique get secret deployeur-jeton` répond `NotFound`. L'état laissé par le chapitre : l'utilisateur `alice` et son contexte `alice@cka`, le Role et la RoleBinding `developpeur`/`developpeurs`, le ClusterRole `lecteur-noeuds` et sa liaison `lecteur-noeuds-alice`, le ServiceAccount `deployeur` avec son Role et sa RoleBinding.

---
