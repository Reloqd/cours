## 5. Joindre des nœuds : discovery et bootstrap TLS

### 5.1 Deux confiances à établir

Joindre un nœud pose deux problèmes symétriques :

```
                 ┌──────────────────────────────┐
                 │  Le NŒUD doit faire          │
                 │  confiance au CLUSTER        │  → DISCOVERY
                 │                              │
                 │  Sinon : une machine qui se  │
                 │  fait passer pour l'API      │
                 │  reçoit le nœud, ses         │
                 │  identifiants, ses pods.     │
                 └──────────────────────────────┘
                 ┌──────────────────────────────┐
                 │  Le CLUSTER doit faire       │
                 │  confiance au NŒUD           │  → BOOTSTRAP TLS
                 │                              │
                 │  Un kubelet neuf n'a aucun   │
                 │  certificat : il faut lui en │
                 │  délivrer un, sans signature │
                 │  manuelle par un admin.      │
                 └──────────────────────────────┘
```

Les deux s'appuient sur un même secret partagé : le **jeton de bootstrap**.

### 5.2 La discovery

Le ConfigMap `cluster-info` du namespace `kube-public` est **lisible sans authentification**. kubeadm le crée pendant la phase `bootstrap-token` avec l'adresse de l'API et le certificat de la CA Kubernetes. Ensuite, le contrôleur `bootstrapsigner` du controller-manager y ajoute, pour chaque jeton valide, une **signature JWS** de ce contenu, calculée avec le secret du jeton. Il la retire quand le jeton expire.

```bash
kubectl -n kube-public get cm cluster-info -o yaml
# data:
#   jws-kubeconfig-abcdef: eyJhbGciOiJIUzI1NiIs...   ← une signature par jeton
#   kubeconfig: |
#     apiVersion: v1
#     clusters:
#     - cluster:
#         certificate-authority-data: LS0tLS1CRUdJTi...
#         server: https://k8s-api.example:6443
```

Le nœud qui rejoint vérifie deux choses :

```
Vérification 1 : la signature JWS
═════════════════════════════════
  "l'émetteur connaît le jeton"
  → insuffisant seule : le jeton circule en clair dans la commande
    de join, l'historique du shell, les outils d'automatisation.
    Quiconque l'a vu peut produire une signature valide.

Vérification 2 : le hash de la clé publique de la CA
═════════════════════════════════════════════════════
  --discovery-token-ca-cert-hash sha256:<hash>
  "la CA reçue est bien celle du cluster attendu"
  → le hash a été obtenu sur le control plane, par un canal de
    confiance. Un imposteur ne peut pas présenter une CA qui
    produise ce hash.
```

C'est pourquoi `--discovery-token-unsafe-skip-ca-verification` porte bien son nom.

### 5.3 Le bootstrap TLS

```
nœud (kubeadm join)                                     API server
 │                                                            │
 │ 1. GET kube-public/cluster-info (anonyme)                  │
 │ ◄─────── adresse + CA + signature JWS ─────────────────────┤
 │                                                            │
 │ 2. vérifie la signature (jeton) et le hash de la CA        │
 │                                                            │
 │ 3. écrit /etc/kubernetes/bootstrap-kubelet.conf            │
 │    (authentification par le jeton) et démarre le kubelet   │
 │                                                            │
 │ kubelet ── s'authentifie avec le jeton ───────────────────►│ identité :
 │                                                            │ system:bootstrap:<id>
 │         ── crée une CSR ──────────────────────────────────►│ signer :
 │            (CN=system:node:w1, O=system:nodes)             │ kube-apiserver-client-kubelet
 │                                                            │
 │                                     controller-manager :   │
 │                                     approbation auto       │
 │                                     puis signature par     │
 │                                     la CA                  │
 │ ◄─────── certificat client ────────────────────────────────┤
 │                                                            │
 │ 4. écrit /var/lib/kubelet/pki/kubelet-client-*.pem         │
 │    et /etc/kubernetes/kubelet.conf qui y pointe            │
 │    supprime bootstrap-kubelet.conf                         │
 │    enregistre l'objet Node                                 │
```

Le jeton authentifie le kubelet sous l'identité `system:bootstrap:<id>`, membre du groupe `system:bootstrappers:kubeadm:default-node-token`. La phase `bootstrap-token` de l'init a accordé à ce groupe juste ce qu'il faut :

| ClusterRoleBinding | Pour qui | Effet |
|--------------------|----------|-------|
| `kubeadm:kubelet-bootstrap` | `system:bootstrappers:kubeadm:default-node-token` | Autorise le dépôt d'une CSR |
| `kubeadm:node-autoapprove-bootstrap` | Le même groupe | Approbation automatique de la première CSR client |
| `kubeadm:node-autoapprove-certificate-rotation` | `system:nodes` | Approbation automatique des renouvellements |
| `kubeadm:get-nodes` | Le même groupe | Lecture des Nodes pendant le join |

La trace du bootstrap reste visible un moment dans l'API :

```bash
kubectl get csr
# NAME        AGE   SIGNERNAME                                    REQUESTOR                 CONDITION
# csr-7x2kq   40s   kubernetes.io/kube-apiserver-client-kubelet   system:bootstrap:abcdef   Approved,Issued
```

Les CSR approuvées sont purgées au bout d'une heure : passé ce délai, la liste est vide, ce qui est normal.

### 5.4 Les jetons

```
Anatomie d'un jeton de bootstrap :
══════════════════════════════════

         abcdef.0123456789abcdef
         ──────  ────────────────
           │            │
           │            └── secret (16 caractères [a-z0-9])
           └── identifiant public (6 caractères [a-z0-9])

  Stocké dans : Secret kube-system/bootstrap-token-abcdef
  Durée de vie par défaut : 24 heures
  Le contrôleur "tokencleaner" supprime les jetons expirés.
```

Le jeton affiché à la fin de l'init a donc souvent expiré quand on veut ajouter un nœud le lendemain. On en crée un nouveau :

```bash
kubeadm token list
kubeadm token create --print-join-command            # jeton + commande complète
kubeadm token create --ttl 2h --print-join-command
kubeadm token delete abcdef                          # révoquer un jeton
```

`--ttl 0` crée un jeton qui n'expire jamais : une porte ouverte sur le cluster, à proscrire.

Le hash de la CA se recalcule à partir de `ca.crt` :

```bash
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
  | openssl pkey -pubin -outform der 2>/dev/null \
  | openssl dgst -sha256 -hex | sed 's/^.* //'
```

**Note** : la documentation officielle utilise `openssl rsa` au lieu de `openssl pkey`. Cette variante échoue si la CA utilise une clé ECDSA (champ `encryptionAlgorithm` de la configuration v1beta4). `openssl pkey` fonctionne pour les deux types de clé.

### 5.5 Joindre un worker

```bash
sudo kubeadm join k8s-api.example:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:<hash>
```

Le worker doit résoudre `k8s-api.example` (dans ce cours, par `/etc/hosts`). Une fois le join terminé, il apparaît `NotReady` le temps que le DaemonSet du CNI y démarre, puis `Ready`.

Un worker n'a **pas** de kubeconfig administrateur : `kubectl` ne fonctionne que depuis un control plane, ou depuis une machine qui a reçu une copie d'`admin.conf`.

### 5.6 Joindre un control plane

Un control plane supplémentaire a besoin de plus qu'un certificat de kubelet. Il lui faut **les mêmes CA**, la paire `sa.key`/`sa.pub` et la CA front-proxy, puisque ces éléments ne se régénèrent pas (chapitre 2.4).

```
Le transport des certificats partagés :
═══════════════════════════════════════

  cp1                                           cp2
  ───                                           ───
  kubeadm init phase upload-certs --upload-certs
        │
        │  chiffre ca.key, etcd/ca.key, front-proxy-ca.key,
        │  sa.key… avec une CLÉ DE CERTIFICATS (AES, 32 octets)
        ▼
  Secret kube-system/kubeadm-certs  ──────────────▶  kubeadm join … --control-plane
  (supprimé au bout de 2 heures)                       --certificate-key <clé>
        │                                                    │
        │  affiche la clé                                    │ télécharge, déchiffre,
        ▼                                                    │ écrit /etc/kubernetes/pki/
  « Using certificate key: 9f3b…»  ─── canal de confiance ──▶ génère ses propres
                                                              certificats feuilles
```

```bash
# sur cp1 : republier les certificats et obtenir une nouvelle clé
sudo kubeadm init phase upload-certs --upload-certs

# commande de join complète pour un control plane
kubeadm token create --print-join-command --certificate-key <clé>
```

```bash
# sur cp2
sudo kubeadm join k8s-api.example:6443 \
  --token <jeton> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane --certificate-key <clé> \
  --apiserver-advertise-address 192.168.10.12
```

Le join d'un control plane fait, en plus du join d'un worker : télécharger les certificats partagés, générer ses certificats feuilles, écrire les manifestes, **ajouter un membre etcd** au cluster existant, écrire son propre `admin.conf`, et marquer le nœud comme control plane.

### 5.7 Pièges courants

```
Piège 1 : Jeton expiré
═══════════════════════
  SYMPTÔME : "could not find a JWS signature in the cluster-info
             ConfigMap for token ID …"
  BON      : kubeadm token create --print-join-command

Piège 2 : Clé de certificats expirée (plus de 2 heures)
════════════════════════════════════════════════════════
  SYMPTÔME : le join --control-plane échoue en téléchargeant
             les certificats (Secret kubeadm-certs introuvable).
  BON      : kubeadm init phase upload-certs --upload-certs

Piège 3 : Joindre un control plane sans controlPlaneEndpoint
════════════════════════════════════════════════════════════
  SYMPTÔME : "unable to add a new control plane instance to a cluster
             that doesn't have a stable controlPlaneEndpoint address"
  BON      : décider de l'endpoint à l'init (chapitre 6.3).

Piège 4 : Mauvaise adresse annoncée sur un nœud à plusieurs interfaces
═══════════════════════════════════════════════════════════════════════
  SYMPTÔME : le nœud s'enregistre avec l'IP de la mauvaise interface,
             etcd ou les sondes visent une adresse injoignable.
  BON      : --apiserver-advertise-address pour un control plane,
             node-ip dans kubeletExtraArgs pour tous les nœuds.

Piège 5 : Lancer kubectl sur un worker
═══════════════════════════════════════
  → aucun kubeconfig admin : "connection refused" sur localhost:8080.
  BON      : kubectl depuis un control plane.
```

---
