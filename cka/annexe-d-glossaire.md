---
title: "CKA — Annexe D. Glossaire"
description: "Définitions courtes et exactes des termes du CKA v1.37, avec le chapitre du cours qui les traite."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## Annexe D. Glossaire

Ce glossaire définit les termes du cours en une ou deux phrases, au sens exact qu'ils ont dans Kubernetes v1.37. Il suit l'ordre alphabétique, accents et majuscules ignorés. Les termes de l'examen restent dans leur forme anglaise quand c'est le vocabulaire officiel ; l'équivalent anglais ou français figure entre parenthèses quand il diffère. Chaque entrée renvoie au chapitre qui traite le sujet en détail : la définition dit ce qu'est la chose, le chapitre dit comment elle marche et comment elle casse.

### A

**Access mode** (mode d'accès) — Manière dont un volume peut être monté : `ReadWriteOnce` (lecture-écriture par un seul nœud), `ReadOnlyMany` (lecture seule par plusieurs nœuds), `ReadWriteMany` (lecture-écriture par plusieurs nœuds), `ReadWriteOncePod` (lecture-écriture par un seul pod). Une PVC ne se lie qu'à un PV qui offre le mode demandé. → [chapitre 15](15-stockage.md)

**Admission (contrôleur d')** (*admission controller*) — Greffon de kube-apiserver qui examine une requête d'écriture déjà authentifiée et autorisée, puis la modifie (mutation) ou la refuse (validation) avant son enregistrement dans etcd. Exemples : `NamespaceLifecycle`, `LimitRanger`, `ResourceQuota`, `PodSecurity`, `DefaultTolerationSeconds`, `NodeRestriction`. → chapitres [2](02-architecture.md) et [8](08-ordonnancement-et-admission.md)

**Affinité de nœud** (*node affinity*) — Règle du pod (`spec.affinity.nodeAffinity`) qui exige (`requiredDuringSchedulingIgnoredDuringExecution`) ou préfère (`preferredDuringSchedulingIgnoredDuringExecution`, poids de 1 à 100) des nœuds d'après leurs labels. Elle n'est évaluée qu'au moment de l'ordonnancement. → [chapitre 8](08-ordonnancement-et-admission.md)

**Affinité et anti-affinité de pods** (*pod affinity, pod anti-affinity*) — Règle qui place un pod dans le même domaine de topologie que des pods portant certains labels, ou l'en écarte ; le domaine est défini par `topologyKey` (nœud, zone…). → [chapitre 8](08-ordonnancement-et-admission.md)

**Agrégation d'API** (*API aggregation layer*) — Mécanisme par lequel kube-apiserver relaie un groupe d'API vers un serveur d'extension déclaré par un objet `APIService` ; metrics-server sert ainsi `metrics.k8s.io`. → chapitres [7](07-autoscaling.md) et [18](18-interfaces-crd-et-operateurs.md)

**Agrégation de ClusterRoles** — ClusterRole munie d'un `aggregationRule`, dont un contrôleur remplit les règles avec celles de toutes les ClusterRoles qui portent les labels choisis ; `admin`, `edit` et `view` sont agrégées par les labels `rbac.authorization.k8s.io/aggregate-to-<rôle>: "true"`. → [chapitre 16](16-rbac-et-authentification.md)

**Allocatable** — Part de la capacité d'un nœud offerte aux pods, une fois retirées les réservations du système, du kubelet et le seuil d'éviction. Le scheduler compare la somme des requests à cette valeur, jamais à l'usage réel. → chapitres [8](08-ordonnancement-et-admission.md) et [21](21-journaux-et-metriques.md)

**allowedRoutes** — Champ d'un listener de Gateway qui fixe les namespaces dont les routes peuvent s'y attacher (`Same` par défaut, `All`, `Selector`) et les types de routes admis. → [chapitre 13](13-gateway-api.md)

**Annotation** — Paire clé-valeur attachée à un objet, non sélectionnable, destinée aux outils et aux contrôleurs (exemple : `kubernetes.io/change-cause`). → [chapitre 2](02-architecture.md)

**apiVersion** — Couple groupe/version du type d'un objet : `v1` pour le groupe cœur, `apps/v1`, `networking.k8s.io/v1`… Une ressource peut être servie en plusieurs versions ; une seule est la version de stockage dans etcd. → [chapitre 2](02-architecture.md)

**Authentification** — Première étape du traitement d'une requête : établir l'utilisateur et ses groupes, par certificat client X.509, jeton de ServiceAccount, jeton OIDC ou proxy authentifiant. Kubernetes ne stocke aucun compte utilisateur. → [chapitre 16](16-rbac-et-authentification.md)

**Autorisation** — Deuxième étape : décider si l'identité peut appliquer le verbe à la ressource. Les clusters kubeadm et minikube utilisent `--authorization-mode=Node,RBAC`. → [chapitre 16](16-rbac-et-authentification.md)

### B

**backendRef** — Référence d'une règle de route Gateway API vers un backend, en général un Service et son port, avec un `weight` facultatif (1 par défaut) : la part d'un backend vaut son poids divisé par la somme des poids. → [chapitre 13](13-gateway-api.md)

**BestEffort** — Classe QoS d'un pod dont aucun conteneur ne déclare de request ni de limit. Premier évincé quand le nœud manque de mémoire. → [chapitre 4](04-pods.md)

**Binding** — Dernière étape de l'ordonnancement : le scheduler écrit le nœud choisi dans `spec.nodeName` par la sous-ressource `pods/binding`. → [chapitre 8](08-ordonnancement-et-admission.md)

**Bound token** (jeton lié) — Jeton JWT de ServiceAccount émis par l'API TokenRequest, avec audience et durée limitées, lié à un objet (pod, Secret) dont la suppression l'invalide ; c'est le jeton qu'un volume projeté injecte dans chaque pod. → [chapitre 16](16-rbac-et-authentification.md)

**Burstable** — Classe QoS d'un pod qui a au moins une request ou une limit sans remplir les conditions de Guaranteed. → [chapitre 4](04-pods.md)

### C

**Cache de watch** (*watch cache*) — Copie en mémoire des objets que kube-apiserver entretient par un watch sur etcd et qui sert les requêtes `list` et `watch`. Après une restauration d'etcd, il peut servir des objets disparus tant que l'apiserver n'a pas redémarré, d'où les options `--bump-revision` et `--mark-compacted` d'`etcdutl`. → [chapitre 20](20-etcd-sauvegarde-et-restauration.md)

**Calico** — Plugin CNI du lab (v3.32.2) : adresses de pods prises par blocs /26 dans l'IPPool `default-ipv4-ippool` (10.244.0.0/16), encapsulation IPIP entre nœuds, application des NetworkPolicies. → [chapitre 9](09-reseau-des-pods.md)

**Canal** (*release channel*) — Ensemble des CRD de Gateway API publié pour une version : `standard` (types et champs stables) ou `experimental` (en plus, types et champs expérimentaux). → [chapitre 13](13-gateway-api.md)

**Capacity** (capacité) — Ressources totales qu'un nœud annonce : CPU, mémoire, nombre de pods, stockage éphémère. → [chapitre 21](21-journaux-et-metriques.md)

**Certificate** — Ressource `cert-manager.io/v1` qui décrit le certificat voulu : `secretName`, `dnsNames`, `issuerRef`, durée et délai de renouvellement. → [chapitre 18](18-interfaces-crd-et-operateurs.md)

**CertificateSigningRequest** (CSR) — Objet `certificates.k8s.io/v1` qui porte une demande de signature PKCS#10 encodée en base64, un `signerName`, des `usages` et une durée facultative (`expirationSeconds`, au moins 600). Approuvé, il reçoit le certificat signé dans `status.certificate`. → [chapitre 16](16-rbac-et-authentification.md)

**cert-manager** — Opérateur qui émet et renouvelle des certificats X.509 décrits par des ressources `Certificate`, signés par un `Issuer` ou un `ClusterIssuer`, et rangés dans des Secrets de type `kubernetes.io/tls`. Version du cours : v1.21.2. → [chapitre 18](18-interfaces-crd-et-operateurs.md)

**cgroup** — Mécanisme du noyau Linux qui borne et compte les ressources d'un groupe de processus. Le kubelet y applique requests et limits ; depuis 1.35 il refuse par défaut de démarrer sur cgroup v1 (`failCgroupV1: true`), et le pilote de cgroups (`systemd` recommandé) se règle dans le runtime, que le kubelet interroge depuis 1.34 (`cgroupDriver` n'est plus qu'un repli). → chapitres [4](04-pods.md) et [19](19-kubeadm-installation-ha-et-mises-a-jour.md)

**ClusterIP** — Type de Service par défaut : une adresse virtuelle stable, prise dans la plage des Services, joignable seulement depuis le cluster. → [chapitre 10](10-services.md)

**ClusterIssuer** — Issuer de cert-manager à portée de cluster, utilisable par les Certificate de tous les namespaces. → [chapitre 18](18-interfaces-crd-et-operateurs.md)

**ClusterRole** — Ensemble de règles RBAC sans namespace. Il couvre les ressources de cluster (nodes, persistentvolumes…) et les URL hors ressources, ou sert de modèle réutilisé par des RoleBindings dans plusieurs namespaces. → [chapitre 16](16-rbac-et-authentification.md)

**ClusterRoleBinding** — Liaison d'une ClusterRole à des sujets, valable dans tout le cluster. → [chapitre 16](16-rbac-et-authentification.md)

**CNI** (*Container Network Interface*) — Spécification et plugins que le runtime appelle (opérations `ADD`, `DEL`, `CHECK`) pour câbler le réseau du sandbox d'un pod. Configuration dans `/etc/cni/net.d/`, binaires dans `/opt/cni/bin/`. → [chapitre 9](09-reseau-des-pods.md)

**Condition** — Élément de `status` (type, statut `True`/`False`/`Unknown`, raison, message) qui décrit un aspect de l'état d'un objet : `PodScheduled` ou `Ready` pour un pod, `Ready` ou `MemoryPressure` pour un nœud, `Available` ou `Progressing` pour un Deployment. → chapitres [4](04-pods.md) et [23](23-depanner-le-cluster.md)

**ConfigMap** — Objet qui porte des données de configuration non confidentielles, consommées en variables d'environnement, en arguments de commande ou en fichiers ; 1 Mio au plus. → [chapitre 6](06-configmaps-et-secrets.md)

**containerd** — Runtime de conteneurs qui implémente le CRI. Kubernetes 1.37 s'utilise avec containerd 2.x ; la branche 1.7 n'est plus prise en charge depuis 1.36. → chapitres [18](18-interfaces-crd-et-operateurs.md) et [19](19-kubeadm-installation-ha-et-mises-a-jour.md)

**Conteneur éphémère** (*ephemeral container*) — Conteneur ajouté à un pod en cours d'exécution par la sous-ressource `ephemeralcontainers`, sans ports, sondes ni ressources, jamais redémarré ; c'est ce qu'ajoute `kubectl debug` sur un pod. → chapitres [4](04-pods.md) et [22](22-depanner-les-applications.md)

**Contexte** — Entrée d'un kubeconfig qui associe un cluster, un utilisateur et un namespace par défaut. → [chapitre 3](03-kubectl-efficace.md)

**Control plane** — Ensemble des composants qui gèrent le cluster (kube-apiserver, etcd, kube-scheduler, kube-controller-manager), et par extension les nœuds qui les hébergent. → [chapitre 2](02-architecture.md)

**Contrôleur** — Boucle qui observe l'état réel par watch et agit pour le rapprocher de l'état voulu décrit dans `spec`. kube-controller-manager en réunit plusieurs dizaines. → [chapitre 2](02-architecture.md)

**controlPlaneEndpoint** — Adresse stable de l'API (nom DNS ou IP et port) déclarée à kubeadm, gravée dans les certificats et les kubeconfigs ; indispensable pour ajouter des control planes. → [chapitre 19](19-kubeadm-installation-ha-et-mises-a-jour.md)

**cordon** — Rendre un nœud non ordonnançable (`spec.unschedulable: true`, taint `node.kubernetes.io/unschedulable:NoSchedule`) sans toucher aux pods présents ; `uncordon` l'annule. → [chapitre 8](08-ordonnancement-et-admission.md)

**CoreDNS** — Serveur DNS du cluster, Deployment de `kube-system` exposé par le Service `kube-dns` (10.96.0.10 dans le cours) ; version v1.14.6 avec Kubernetes 1.37. → [chapitre 11](11-coredns.md)

**Corefile** — Configuration de CoreDNS, dans la ConfigMap `kube-system/coredns` : blocs de serveur et chaîne de plugins (`kubernetes`, `forward`, `cache`, `hosts`, `reload`…). → [chapitre 11](11-coredns.md)

**CrashLoopBackOff** — Raison d'attente d'un conteneur qui s'arrête en boucle : le kubelet le relance avec un délai qui double (10 s, 20 s, 40 s…) jusqu'à 300 s, et remet ce délai à zéro après 10 minutes de fonctionnement sans incident. → chapitres [4](04-pods.md) et [22](22-depanner-les-applications.md)

**CRD** (*CustomResourceDefinition*) — Objet `apiextensions.k8s.io/v1` qui déclare un nouveau type de ressource (groupe, noms, portée, versions, schéma OpenAPI v3) ; kube-apiserver le sert ensuite comme une API native et stocke ses objets dans etcd. Son nom vaut `<pluriel>.<groupe>`. → [chapitre 18](18-interfaces-crd-et-operateurs.md)

**CRI** (*Container Runtime Interface*) — API gRPC entre le kubelet et le runtime de conteneurs : sandboxes, conteneurs, images. → [chapitre 18](18-interfaces-crd-et-operateurs.md)

**crictl** — Client en ligne de commande du CRI, lancé sur un nœud (avec `sudo`) pour lister sandboxes, conteneurs et images et lire les journaux, même quand l'API est injoignable. → chapitres [2](02-architecture.md), [18](18-interfaces-crd-et-operateurs.md) et [23](23-depanner-le-cluster.md)

**CronJob** — Contrôleur qui crée des Jobs selon une planification cron, avec fuseau horaire facultatif (`timeZone`), politique de concurrence (`Allow`, `Forbid`, `Replace`) et historiques bornés. → [chapitre 5](05-deployments-et-controleurs.md)

**CSI** (*Container Storage Interface*) — API standard entre Kubernetes et les pilotes de stockage externes, déployés en pods (partie contrôleur et plugin de nœud) ; décrits par les objets CSIDriver, CSINode et VolumeAttachment. → chapitres [15](15-stockage.md) et [18](18-interfaces-crd-et-operateurs.md)

**custom-columns** — Format de sortie de kubectl qui construit un tableau à partir d'expressions jsonpath (`-o custom-columns=NOM:.metadata.name`). → [chapitre 3](03-kubectl-efficace.md)

### D

**DaemonSet** — Contrôleur qui fait tourner une copie d'un pod sur chaque nœud éligible. → [chapitre 5](05-deployments-et-controleurs.md)

**Décalage de versions** (*version skew*) — Écarts de versions mineures permis entre composants : kube-controller-manager et kube-scheduler au plus une mineure sous kube-apiserver, kubelet et kube-proxy au plus trois, kubectl une de part et d'autre, jamais un composant plus récent que l'apiserver. → [chapitre 19](19-kubeadm-installation-ha-et-mises-a-jour.md)

**Deployment** — Contrôleur de pods sans état qui gère des ReplicaSets successifs pour mettre à jour progressivement (`RollingUpdate`) ou d'un bloc (`Recreate`) et revenir à une révision antérieure. → [chapitre 5](05-deployments-et-controleurs.md)

**dnsPolicy** — Politique DNS d'un pod : `ClusterFirst` (défaut), `ClusterFirstWithHostNet` (pod en `hostNetwork`), `Default` (configuration du nœud) ou `None` (seulement `dnsConfig`). → [chapitre 11](11-coredns.md)

**Downward API** — Moyen d'exposer à un conteneur des champs de son pod (nom, namespace, IP, nœud, labels) ou ses ressources, en variables d'environnement ou en fichiers. → [chapitre 6](06-configmaps-et-secrets.md)

**drain** — Cordonner un nœud puis évincer ses pods par l'API Eviction, qui respecte les PodDisruptionBudgets ; préalable à une maintenance ou à une mise à jour du kubelet. → [chapitre 8](08-ordonnancement-et-admission.md)

**Dry-run** — Exécution sans enregistrement : `--dry-run=client` rend l'objet localement (sert à générer du YAML), `--dry-run=server` le fait passer par l'admission et la validation du serveur. → [chapitre 3](03-kubectl-efficace.md)

### E

**Effet** (d'une taint) — `NoSchedule` : aucun nouveau pod sans tolérance ; `PreferNoSchedule` : nœud évité si possible ; `NoExecute` : les pods déjà présents qui ne tolèrent pas la taint sont aussi évincés. → [chapitre 8](08-ordonnancement-et-admission.md)

**emptyDir** — Volume vide créé quand le pod arrive sur un nœud, partagé par ses conteneurs et détruit avec le pod. → [chapitre 15](15-stockage.md)

**EncryptionConfiguration** — Fichier passé à kube-apiserver par `--encryption-provider-config` qui fait chiffrer au repos, dans etcd, les ressources choisies (les Secrets en général). → [chapitre 6](06-configmaps-et-secrets.md)

**Endpoints** — Ancienne API de liste des adresses d'un Service, dépréciée depuis 1.33 (avertissement à chaque lecture) au profit des EndpointSlices. → [chapitre 10](10-services.md)

**EndpointSlice** — Objet `discovery.k8s.io/v1` qui liste une partie des points de terminaison d'un Service (adresses, ports, conditions `ready`, `serving`, `terminating`) ; il est rattaché à son Service par le label `kubernetes.io/service-name`. → [chapitre 10](10-services.md)

**Envoy Gateway** — Implémentation de Gateway API fondée sur le proxy Envoy, installée par Helm dans le lab (v1.9.2, contrôleur `gateway.envoyproxy.io/gatewayclass-controller`) ; elle crée un Deployment et un Service LoadBalancer par Gateway. → [chapitre 13](13-gateway-api.md)

**etcd** — Base clé-valeur distribuée et cohérente (Raft) où kube-apiserver range tout l'état du cluster ; version 3.7.0 avec kubeadm 1.37. → [chapitre 20](20-etcd-sauvegarde-et-restauration.md)

**etcdctl** — Client d'etcd : santé, statut, membres, clés. Depuis etcd 3.6, il ne garde que `snapshot save` parmi les opérations de snapshot. → [chapitre 20](20-etcd-sauvegarde-et-restauration.md)

**etcdutl** — Outil hors ligne d'etcd qui travaille sur les fichiers : `snapshot status`, `snapshot restore`, `defrag`. → [chapitre 20](20-etcd-sauvegarde-et-restauration.md)

**Événement** (*Event*) — Objet de courte durée (une heure par défaut) qui relate un fait : ordonnancement, tirage d'image, échec de sonde, éviction… Lu par `kubectl events` ou en bas de `kubectl describe`. → [chapitre 21](21-journaux-et-metriques.md)

**Éviction** — Suppression contrôlée d'un pod : par l'API Eviction (drain, dans le respect des PDB), par le kubelet quand le nœud manque de mémoire, de disque ou de PID, ou à cause d'une taint `NoExecute`. → chapitres [8](08-ordonnancement-et-admission.md) et [23](23-depanner-le-cluster.md)

**ExternalName** — Type de Service sans sélecteur ni ClusterIP dont le nom DNS répond par un enregistrement CNAME vers un nom externe. → [chapitre 10](10-services.md)

**externalTrafficPolicy** — Pour un Service NodePort ou LoadBalancer : `Cluster` (défaut, répartition sur tous les pods, IP source masquée par SNAT) ou `Local` (seulement les pods du nœud qui reçoit, IP du client conservée). → [chapitre 10](10-services.md)

### F

**Feature gate** — Interrupteur nommé d'une fonction dans les composants de Kubernetes. Une fonction GA voit son interrupteur verrouillé, puis supprimé quelques versions plus tard. → [chapitre 1](01-introduction-et-contexte.md)

**Field selector** (sélecteur de champs) — Filtre de `kubectl get` sur certains champs : `metadata.name`, `metadata.namespace`, `status.phase`, `spec.nodeName`… → [chapitre 3](03-kubectl-efficace.md)

**Finalizer** — Clé de `metadata.finalizers` qui retient la suppression effective d'un objet tant qu'un contrôleur ne l'a pas retirée ; l'objet reste en `Terminating`. → [chapitre 2](02-architecture.md)

### G

**Garbage collection** (ramasse-miettes) — Suppression automatique des objets dont tous les propriétaires (`ownerReferences`) ont disparu, en cascade `Background` (défaut de kubectl), `Foreground` ou `Orphan`. → [chapitre 2](02-architecture.md)

**Gateway** — Ressource de Gateway API qui instancie un point d'entrée du trafic, avec ses listeners (port, protocole, nom d'hôte, TLS), selon une GatewayClass. → [chapitre 13](13-gateway-api.md)

**Gateway API** — Famille d'API `gateway.networking.k8s.io` (GatewayClass, Gateway, HTTPRoute, GRPCRoute, ReferenceGrant…) qui succède à Ingress avec un modèle découpé par rôles ; version v1.6 en 2026. → [chapitre 13](13-gateway-api.md)

**GatewayClass** — Ressource de cluster qui désigne, par `controllerName`, le contrôleur chargé des Gateways de cette classe. → [chapitre 13](13-gateway-api.md)

**GRPCRoute** — Route de Gateway API pour le trafic gRPC (service et méthode), dans le canal standard depuis la v1.1. → [chapitre 13](13-gateway-api.md)

**Guaranteed** — Classe QoS d'un pod dont chaque conteneur fixe des requests égales à ses limits, pour le CPU comme pour la mémoire. Dernier évincé. → [chapitre 4](04-pods.md)

### H

**Headless** (Service) — Service sans ClusterIP (`clusterIP: None`) : le DNS rend directement les adresses des pods prêts ; un pod qui déclare `hostname` et `subdomain`, comme ceux d'un StatefulSet, y reçoit son propre nom. → chapitres [10](10-services.md), [11](11-coredns.md) et [15](15-stockage.md)

**Helm** — Gestionnaire de paquets qui rend des charts (gabarits et valeurs) et suit chaque installation comme une release révisionnée. Version 4 depuis novembre 2025 ; 4.3 dans le cours. → [chapitre 17](17-helm-et-kustomize.md)

**HorizontalPodAutoscaler** (HPA) — Objet `autoscaling/v2` qui ajuste le nombre de réplicas d'une cible (Deployment, StatefulSet…) d'après des métriques, toutes les 15 s par défaut. → [chapitre 7](07-autoscaling.md)

**hostNetwork** — Option d'un pod qui lui fait partager l'espace de noms réseau du nœud : il voit les interfaces du nœud et occupe ses ports. → [chapitre 9](09-reseau-des-pods.md)

**hostPath** — Volume qui monte un chemin du système de fichiers du nœud ; il attache les données à ce nœud et ouvre des risques de sécurité. → [chapitre 15](15-stockage.md)

**hostPort** — Port du nœud redirigé vers un port de conteneur (plugin CNI `portmap`). → [chapitre 9](09-reseau-des-pods.md)

**HTTPRoute** — Route de Gateway API pour HTTP : `parentRefs`, `hostnames`, règles faites de correspondances (chemin, en-têtes, paramètres, méthode), de filtres et de `backendRefs` pondérés. → [chapitre 13](13-gateway-api.md)

### I

**imagePullSecrets** — Liste de Secrets de type `kubernetes.io/dockerconfigjson` qu'utilise le kubelet pour tirer les images d'un registre privé. → [chapitre 6](06-configmaps-et-secrets.md)

**Immutable** (immuable) — ConfigMap ou Secret marqué `immutable: true` : ses données ne peuvent plus changer, il faut le recréer ; le kubelet cesse de le surveiller. → [chapitre 6](06-configmaps-et-secrets.md)

**Impersonation** (emprunt d'identité) — Options `--as` et `--as-group` : l'API traite la requête comme si elle venait d'une autre identité, à condition que l'appelant ait le verbe `impersonate`. Sert à tester des droits avec `kubectl auth can-i`. → [chapitre 16](16-rbac-et-authentification.md)

**Ingress** — Objet `networking.k8s.io/v1` de routage HTTP et HTTPS par nom d'hôte et chemin vers des Services, appliqué par un contrôleur d'Ingress. L'API reste GA. → [chapitre 12](12-ingress.md)

**ingress2gateway** — Outil officiel de conversion d'Ingress en ressources Gateway API (version 1.0 en mars 2026, v1.2.0 dans le cours). → [chapitre 13](13-gateway-api.md)

**IngressClass** — Objet qui rattache des Ingress à un contrôleur (`spec.controller`) ; l'annotation `ingressclass.kubernetes.io/is-default-class: "true"` en fait la classe par défaut. → [chapitre 12](12-ingress.md)

**ingress-nginx** — Contrôleur d'Ingress fondé sur NGINX, retiré le 24 mars 2026 (dépôt archivé, plus aucun correctif) ; l'addon `ingress` de minikube v1.39.0 l'installe encore (v1.15.1). → [chapitre 12](12-ingress.md)

**Init container** — Conteneur de `spec.initContainers` exécuté jusqu'à son terme, dans l'ordre, avant les conteneurs principaux ; avec `restartPolicy: Always`, il devient un sidecar natif. → [chapitre 4](04-pods.md)

**IPIP** — Encapsulation d'un paquet IP dans un autre paquet IP, utilisée par Calico dans le lab pour transporter le trafic de pod à pod entre nœuds. → [chapitre 9](09-reseau-des-pods.md)

**IPPool** — Ressource Calico qui définit une plage d'adresses de pods : CIDR, taille de bloc, mode d'encapsulation, NAT sortant. → [chapitre 9](09-reseau-des-pods.md)

**Issuer** — Ressource `cert-manager.io/v1` namespacée qui sait signer des certificats (`selfSigned`, `ca`, `acme`, `vault`…) pour les Certificate de son namespace. → [chapitre 18](18-interfaces-crd-et-operateurs.md)

### J

**Job** — Contrôleur qui exécute des pods jusqu'à un nombre de réussites (`completions`), avec un parallélisme, une limite d'échecs (`backoffLimit`, 6 par défaut) et un nettoyage différé (`ttlSecondsAfterFinished`). → [chapitre 5](05-deployments-et-controleurs.md)

**jsonpath** — Langage d'extraction de champs de kubectl (`-o jsonpath=`) : chemins (`{.items[*].metadata.name}`), filtres (`[?(@.type=="Ready")]`), boucles (`{range …}{end}`). → [chapitre 3](03-kubectl-efficace.md)

### K

**kubeadm** — Outil officiel qui amorce un cluster conforme (`init`, `join`), le met à jour (`upgrade`) et gère ses certificats ; il écrit des fichiers et rend la main, sans démon. → [chapitre 19](19-kubeadm-installation-ha-et-mises-a-jour.md)

**kube-apiserver** — Composant qui expose l'API REST et seul à parler à etcd ; il authentifie, autorise, admet et valide chaque requête. → [chapitre 2](02-architecture.md)

**kubeconfig** — Fichier YAML (`~/.kube/config` par défaut, ou la liste de `$KUBECONFIG`) qui décrit des clusters, des utilisateurs et des contextes. → [chapitre 3](03-kubectl-efficace.md)

**kube-controller-manager** — Processus qui exécute les contrôleurs intégrés : ReplicaSet, Deployment, nœuds, Jobs, ServiceAccounts, signature des CSR, ramasse-miettes… → [chapitre 2](02-architecture.md)

**kubectl debug** — Commande qui ajoute un conteneur éphémère à un pod, crée une copie modifiée d'un pod, ou lance sur un nœud un pod privilégié qui voit la racine du nœud en `/host` ; profil `general` par défaut depuis 1.36. → [chapitre 22](22-depanner-les-applications.md)

**kubelet** — Agent de chaque nœud, service systemd, qui fait tourner par le CRI les pods attribués au nœud, lance les pods statiques et rapporte l'état du nœud. → [chapitre 2](02-architecture.md)

**kube-proxy** — Agent de chaque nœud (DaemonSet) qui programme le noyau pour les ClusterIP et NodePort des Services : mode `iptables` par défaut, `nftables` GA depuis 1.33, `ipvs` déprécié depuis 1.35. → [chapitre 10](10-services.md)

**kuberc** — Fichier de préférences de kubectl (`~/.kube/kuberc`, `kind: Preference`, en bêta) pour définir alias et options par défaut, distinct du kubeconfig. → [chapitre 3](03-kubectl-efficace.md)

**kube-scheduler** — Composant qui choisit un nœud pour chaque pod non attribué : filtrage des nœuds possibles, notation, puis binding. → chapitres [2](02-architecture.md) et [8](08-ordonnancement-et-admission.md)

**kube-vip** — Pod statique qui porte l'adresse virtuelle de l'API dans le lab kubeadm du chapitre 19 (mode ARP). → [chapitre 19](19-kubeadm-installation-ha-et-mises-a-jour.md)

**Kustomize** — Outil de personnalisation sans gabarit, intégré à kubectl (`-k`) : une base et des overlays décrits par `kustomization.yaml` (`resources`, `namespace`, `labels`, `images`, `replicas`, générateurs, `patches`). Version 5.8.1 dans kubectl 1.37. → [chapitre 17](17-helm-et-kustomize.md)

**KYAML** — Variante stricte de YAML, sans ambiguïté de types, produite par `kubectl get -o kyaml` ; GA en 1.37. → [chapitre 3](03-kubectl-efficace.md)

### L

**Label** — Paire clé-valeur attachée à un objet, sur laquelle portent les sélecteurs : Services, contrôleurs, NetworkPolicies, affinités. → [chapitre 2](02-architecture.md)

**Leader election** (élection de leader) — Mécanisme, fondé sur un Lease, qui garantit qu'une seule instance de kube-scheduler et de kube-controller-manager agit à la fois dans un control plane hautement disponible. Désactivé dans le lab minikube. → chapitres [2](02-architecture.md) et [19](19-kubeadm-installation-ha-et-mises-a-jour.md)

**Lease** — Objet `coordination.k8s.io/v1`. Chaque kubelet renouvelle le sien dans le namespace `kube-node-lease` pour signaler qu'il est vivant ; les élections de leader en utilisent aussi. → chapitres [2](02-architecture.md) et [23](23-depanner-le-cluster.md)

**LimitRange** — Objet de namespace qui impose des bornes de ressources par conteneur, pod ou PVC et injecte des requests et limits par défaut aux conteneurs qui n'en déclarent pas. → [chapitre 8](08-ordonnancement-et-admission.md)

**Listener** — Point d'écoute d'un Gateway : nom, port, protocole, nom d'hôte facultatif, configuration TLS et routes admises. → [chapitre 13](13-gateway-api.md)

**Liveness probe** (sonde de vivacité) — Sonde dont les échecs répétés font redémarrer le conteneur. → [chapitre 4](04-pods.md)

**LoadBalancer** — Type de Service qui demande une adresse externe à un fournisseur (cloud, MetalLB) ; il comprend aussi un NodePort et un ClusterIP. → [chapitre 10](10-services.md)

**Local** (volume) — PV de type `local` qui désigne un disque ou un dossier d'un nœud précis ; il exige une `nodeAffinity` et va de pair avec une classe en `WaitForFirstConsumer`. → [chapitre 15](15-stockage.md)

### M

**Manifeste** — Fichier YAML ou JSON qui décrit un ou plusieurs objets ; pour le kubelet, fichier de pod statique. → [chapitre 3](03-kubectl-efficace.md)

**MetalLB** — Implémentation des Services LoadBalancer pour les clusters sans fournisseur ; dans le lab, addon v0.9.6 en mode couche 2, configuré par la ConfigMap `metallb-system/config`. → [chapitre 10](10-services.md)

**metrics-server** — Agrégateur des mesures de CPU et de mémoire relevées par les kubelets, servies par l'API `metrics.k8s.io` ; il alimente `kubectl top` et le HPA. Version v0.9.0 dans le lab. → chapitres [7](07-autoscaling.md) et [21](21-journaux-et-metriques.md)

**minikube** — Outil qui crée un cluster local ; le cours l'utilise en v1.39.0, avec le pilote docker, trois nœuds et le profil `cka`. → [chapitre 1](01-introduction-et-contexte.md)

**Mirror pod** (pod miroir) — Reflet, dans l'API, d'un pod statique ; son nom porte le nom du nœud en suffixe (`kube-apiserver-cka`) et le supprimer ne fait que le recréer. → [chapitre 2](02-architecture.md)

### N

**Namespace** — Portée de noms des objets namespacés, et cadre des quotas, des politiques et des droits. → [chapitre 2](02-architecture.md)

**ndots** — Option de `resolv.conf` (5 dans un pod) : un nom qui compte moins de cinq points est d'abord essayé suffixé par chaque domaine de recherche. → [chapitre 11](11-coredns.md)

**NetworkPolicy** — Objet `networking.k8s.io/v1` qui isole les pods sélectionnés et n'autorise que les flux décrits, en entrée (`Ingress`) ou en sortie (`Egress`) ; appliqué par le plugin CNI. → [chapitre 14](14-network-policies.md)

**Node** (nœud) — Machine qui exécute des pods (un conteneur Docker dans le lab) ; objet de cluster décrit par sa capacité, ses conditions, ses labels et ses taints. → [chapitre 2](02-architecture.md)

**Node authorizer** — Mode d'autorisation qui limite chaque kubelet (groupe `system:nodes`) aux objets liés aux pods de son nœud ; il va de pair avec l'admission `NodeRestriction`. → [chapitre 16](16-rbac-et-authentification.md)

**NodePort** — Type de Service qui ouvre le même port, pris entre 30000 et 32767, sur chaque nœud, en plus du ClusterIP. → [chapitre 10](10-services.md)

**nodeSelector** — Champ du pod qui exige des labels de nœud par égalité ; forme simple de l'affinité de nœud. → [chapitre 8](08-ordonnancement-et-admission.md)

**NotReady** — État d'un nœud dont la condition `Ready` vaut `False` ou `Unknown` (kubelet muet depuis plus de 50 s) ; les taints `not-ready` ou `unreachable` y sont posées. → [chapitre 23](23-depanner-le-cluster.md)

### O

**OOMKilled** — Raison de fin d'un conteneur tué par le noyau pour avoir dépassé sa limite de mémoire (code de sortie 137). → [chapitre 4](04-pods.md)

**Opérateur** (*operator*) — Contrôleur personnalisé qui pilote une application à travers des CRD et encode le savoir-faire de son exploitation. → [chapitre 18](18-interfaces-crd-et-operateurs.md)

**ownerReference** — Lien d'un objet vers son propriétaire (pod vers ReplicaSet, ReplicaSet vers Deployment), sur lequel s'appuie le ramasse-miettes. → [chapitre 2](02-architecture.md)

### P

**parentRef** — Référence d'une route Gateway API vers le Gateway auquel elle s'attache, et éventuellement vers l'un de ses listeners (`sectionName`). → [chapitre 13](13-gateway-api.md)

**PersistentVolume** (PV) — Ressource de stockage de cluster, créée à la main ou par provisionnement dynamique, avec capacité, modes d'accès, politique de récupération et classe. → [chapitre 15](15-stockage.md)

**PersistentVolumeClaim** (PVC) — Demande de stockage namespacée (taille, modes d'accès, classe) liée de façon exclusive à un PV. → [chapitre 15](15-stockage.md)

**Phase** — Résumé du cycle de vie d'un pod : `Pending`, `Running`, `Succeeded`, `Failed` ou `Unknown`. `CrashLoopBackOff` n'est pas une phase. → [chapitre 4](04-pods.md)

**Pod** — Plus petite unité déployable : un ou plusieurs conteneurs qui partagent réseau, IPC et volumes, et sont placés ensemble sur un nœud. → [chapitre 4](04-pods.md)

**Pod Security Admission** — Contrôleur d'admission intégré qui applique les Pod Security Standards namespace par namespace, d'après les labels `pod-security.kubernetes.io/enforce`, `audit` et `warn`. → [chapitre 8](08-ordonnancement-et-admission.md)

**Pod Security Standards** — Trois niveaux de règles de sécurité des pods : `privileged`, `baseline`, `restricted`. → [chapitre 8](08-ordonnancement-et-admission.md)

**Pod statique** (*static pod*) — Pod que le kubelet lit dans un fichier du dossier `staticPodPath` (`/etc/kubernetes/manifests`), sans passer par l'API ni le scheduler ; c'est la forme des composants du control plane sous kubeadm. → chapitres [2](02-architecture.md) et [23](23-depanner-le-cluster.md)

**PodCIDR** — Plage d'adresses (`spec.podCIDR`) que kube-controller-manager attribue à chaque nœud ; Calico l'ignore et distribue ses propres blocs /26. → [chapitre 9](09-reseau-des-pods.md)

**PodDisruptionBudget** (PDB) — Objet `policy/v1` qui borne les interruptions volontaires d'un ensemble de pods par `minAvailable` ou `maxUnavailable`. → [chapitre 5](05-deployments-et-controleurs.md)

**Port nommé** — Nom donné à un port de conteneur (`name: http`) qu'un Service (`targetPort`) ou une sonde peut viser à la place du numéro. → [chapitre 10](10-services.md)

**port-forward** — Tunnel ouvert par l'API entre un port local et un port d'un pod ou d'un Service (`kubectl port-forward`). → [chapitre 10](10-services.md)

**Préemption** — Éviction, par le scheduler, de pods de priorité inférieure pour placer un pod plus prioritaire qui ne trouve pas de place. → [chapitre 8](08-ordonnancement-et-admission.md)

**PriorityClass** — Objet de cluster qui associe un nom à une priorité entière ; un pod la désigne par `priorityClassName`. → [chapitre 8](08-ordonnancement-et-admission.md)

**Projected volume** (volume projeté) — Volume qui réunit dans un même dossier plusieurs sources : Secret, ConfigMap, downward API, jeton de ServiceAccount. → [chapitre 6](06-configmaps-et-secrets.md)

**Provisionnement dynamique** — Création automatique d'un PV par le provisioner d'une StorageClass quand une PVC le demande. → [chapitre 15](15-stockage.md)

### Q

**QoS** (classe de) — `Guaranteed`, `Burstable` ou `BestEffort`, déduite des requests et limits des conteneurs ; elle ordonne les évictions quand un nœud manque de mémoire. → [chapitre 4](04-pods.md)

**Quorum** — Majorité des membres d'etcd (⌊n/2⌋ + 1) nécessaire pour écrire : trois membres tolèrent une panne, cinq en tolèrent deux. → [chapitre 20](20-etcd-sauvegarde-et-restauration.md)

### R

**Raft** — Algorithme de consensus d'etcd : un leader élu reçoit les écritures et les réplique sur les autres membres. → [chapitre 20](20-etcd-sauvegarde-et-restauration.md)

**RBAC** (*Role-Based Access Control*) — Mode d'autorisation par rôles : Role et ClusterRole énumèrent des permissions, uniquement additives ; RoleBinding et ClusterRoleBinding les accordent à des sujets. → [chapitre 16](16-rbac-et-authentification.md)

**Readiness probe** (sonde de disponibilité) — Sonde qui décide si le conteneur reçoit du trafic ; en échec, le pod sort des EndpointSlices sans redémarrer. → [chapitre 4](04-pods.md)

**Reclaim policy** (politique de récupération) — Sort d'un PV quand sa PVC disparaît : `Retain`, `Delete`, ou `Recycle` (dépréciée). → [chapitre 15](15-stockage.md)

**Réconciliation** — Travail d'un contrôleur qui compare l'état voulu et l'état observé et agit sur l'écart, indéfiniment. → [chapitre 2](02-architecture.md)

**Redimensionnement en place** (*in-place pod resize*) — Modification des requests et limits de CPU et de mémoire d'un pod en cours d'exécution par la sous-ressource `resize`, sans recréer le pod ; GA en 1.35. → chapitres [4](04-pods.md) et [7](07-autoscaling.md)

**ReferenceGrant** — Objet de Gateway API, posé dans le namespace cible, qui autorise des références venues d'un autre namespace (route vers un Service, Gateway vers un Secret). → [chapitre 13](13-gateway-api.md)

**Release** — Installation nommée d'un chart Helm dans un namespace, avec un historique de révisions. → [chapitre 17](17-helm-et-kustomize.md)

**ReplicaSet** — Contrôleur qui maintient un nombre donné de pods identiques sélectionnés par labels ; un Deployment en crée un par révision. → [chapitre 5](05-deployments-et-controleurs.md)

**Requests et limits** — Requests : ressources réservées au conteneur, que le scheduler additionne pour placer le pod. Limits : plafond appliqué par le noyau, par bridage pour le CPU et par l'OOM killer pour la mémoire. → [chapitre 4](04-pods.md)

**ResourceQuota** — Objet de namespace qui plafonne la somme des requests et limits et le nombre d'objets ; une création qui dépasserait le quota est refusée à l'admission. → [chapitre 8](08-ordonnancement-et-admission.md)

**Révision** — Version numérotée du gabarit d'un Deployment (un ReplicaSet par révision) ou d'une release Helm. → chapitres [5](05-deployments-et-controleurs.md) et [17](17-helm-et-kustomize.md)

**Role** — Ensemble de règles RBAC valable dans un seul namespace. → [chapitre 16](16-rbac-et-authentification.md)

**RoleBinding** — Liaison d'un Role, ou d'une ClusterRole, à des sujets (`User`, `Group`, `ServiceAccount`), valable dans le namespace du binding ; son `roleRef` est immuable. → [chapitre 16](16-rbac-et-authentification.md)

**Rollback** (retour arrière) — Retour à une révision antérieure : `kubectl rollout undo` pour un Deployment, `helm rollback` pour une release ; dans les deux cas une nouvelle révision est créée. → chapitres [5](05-deployments-et-controleurs.md) et [17](17-helm-et-kustomize.md)

**RollingUpdate** — Stratégie de mise à jour progressive d'un Deployment, réglée par `maxSurge` et `maxUnavailable` (25 % chacun par défaut). → [chapitre 5](05-deployments-et-controleurs.md)

**RuntimeClass** — Objet `node.k8s.io/v1` qui associe un nom à un handler du runtime de conteneurs ; un pod le choisit par `runtimeClassName`. → [chapitre 18](18-interfaces-crd-et-operateurs.md)

### S

**Sandbox** — Environnement isolé du pod (espaces de noms réseau et IPC) que le runtime crée avant les conteneurs, porté par le conteneur `pause`. → chapitres [9](09-reseau-des-pods.md) et [18](18-interfaces-crd-et-operateurs.md)

**Secret** — Objet destiné aux données confidentielles, encodées en base64 et non chiffrées (sauf chiffrement au repos) ; types `Opaque`, `kubernetes.io/tls`, `kubernetes.io/dockerconfigjson`… → [chapitre 6](06-configmaps-et-secrets.md)

**Sélecteur de labels** (*label selector*) — Expression qui choisit des objets par leurs labels, par égalité (`app=api`) ou par ensemble (`tier in (web,api)`). → [chapitre 3](03-kubectl-efficace.md)

**SelfSubjectReview** — API qu'interroge `kubectl auth whoami` pour connaître l'identité (utilisateur, groupes) que le serveur attribue à l'appelant. → [chapitre 16](16-rbac-et-authentification.md)

**Server-side apply** — Mode d'`apply` calculé par l'API, qui enregistre le gestionnaire propriétaire de chaque champ (`managedFields`) et signale les conflits entre gestionnaires. → [chapitre 3](03-kubectl-efficace.md)

**Service** — Abstraction qui donne un nom DNS et une adresse stables à un ensemble de pods choisis par sélecteur, et répartit le trafic entre eux. → [chapitre 10](10-services.md)

**ServiceAccount** — Identité namespacée destinée aux processus des pods (`system:serviceaccount:<ns>:<nom>`), qui s'authentifie par des jetons liés. → [chapitre 16](16-rbac-et-authentification.md)

**sessionAffinity** — Option `ClientIP` d'un Service qui renvoie un même client vers le même pod, pendant 10 800 s (3 h) par défaut. → [chapitre 10](10-services.md)

**Sidecar natif** — Init container avec `restartPolicy: Always` : démarré avant les conteneurs principaux, arrêté après eux, redémarré s'il tombe ; GA depuis 1.33. → [chapitre 4](04-pods.md)

**Snapshot etcd** — Copie cohérente de la base d'etcd, prise par `etcdctl snapshot save` et restaurée par `etcdutl snapshot restore` dans un nouveau répertoire de données. → [chapitre 20](20-etcd-sauvegarde-et-restauration.md)

**Sous-ressource** (*subresource*) — Chemin d'API attaché à un objet (`pods/log`, `pods/exec`, `deployments/scale`, `status`, `resize`) et soumis à ses propres règles RBAC. → [chapitre 16](16-rbac-et-authentification.md)

**Stabilisation** (fenêtre de) — Durée sur laquelle le HPA retient la recommandation la plus haute avant de réduire (300 s par défaut en descente, 0 s en montée) ; réglée par `behavior.scaleDown.stabilizationWindowSeconds`. → [chapitre 7](07-autoscaling.md)

**Stacked etcd** (etcd empilé) — Topologie haute disponibilité où chaque control plane héberge un membre etcd, par opposition à un etcd externe sur des machines dédiées. → [chapitre 19](19-kubeadm-installation-ha-et-mises-a-jour.md)

**Startup probe** (sonde de démarrage) — Sonde qui suspend liveness et readiness jusqu'à son premier succès ; elle laisse le temps à un démarrage lent. → [chapitre 4](04-pods.md)

**StatefulSet** — Contrôleur de pods à identité stable : nom ordinal (`redis-0`), nom DNS par Service headless, une PVC par pod ; créations et mises à jour dans l'ordre. → chapitres [5](05-deployments-et-controleurs.md) et [15](15-stockage.md)

**StorageClass** — Objet de cluster qui décrit une classe de stockage : provisioner, paramètres, politique de récupération, mode de liaison, expansion permise. L'annotation `storageclass.kubernetes.io/is-default-class: "true"` en fait la classe par défaut. → [chapitre 15](15-stockage.md)

**subPath** — Montage d'un seul fichier ou sous-dossier d'un volume ; un ConfigMap ou un Secret monté ainsi ne reçoit plus les mises à jour. → [chapitre 6](06-configmaps-et-secrets.md)

**super-admin.conf** — Kubeconfig créé par kubeadm dont l'identité appartient au groupe `system:masters`, qui contourne toute autorisation ; `admin.conf`, lui, passe par le groupe `kubeadm:cluster-admins` et RBAC. → [chapitre 19](19-kubeadm-installation-ha-et-mises-a-jour.md)

### T

**Taint** — Marque posée sur un nœud (clé, valeur, effet) qui repousse les pods qui ne la tolèrent pas. → [chapitre 8](08-ordonnancement-et-admission.md)

**Tolérance du HPA** (*tolerance*) — Écart relatif entre mesure et cible en deçà duquel le HPA n'agit pas : 10 % par défaut, réglable règle par règle (`behavior.scaleUp.tolerance`, `behavior.scaleDown.tolerance`) depuis la GA de 1.37. → [chapitre 7](07-autoscaling.md)

**Toleration** — Déclaration d'un pod qui l'autorise à aller sur un nœud porteur d'une taint (`operator` `Equal` ou `Exists`, `tolerationSeconds` pour `NoExecute`) ; elle permet sans attirer. → [chapitre 8](08-ordonnancement-et-admission.md)

**Topology spread constraint** — Règle qui répartit des pods entre domaines de topologie (zones, nœuds) avec un écart maximal (`maxSkew`) ; `whenUnsatisfiable` vaut `DoNotSchedule` par défaut ou `ScheduleAnyway`. → [chapitre 8](08-ordonnancement-et-admission.md)

**trafficDistribution** — Préférence de routage d'un Service vers des points de terminaison proches : `PreferSameZone` ou `PreferSameNode` (`PreferClose` est l'ancien nom, déprécié, de `PreferSameZone`). → [chapitre 10](10-services.md)

### V

**veth** — Paire d'interfaces virtuelles qui relie l'espace de noms réseau d'un pod à celui du nœud. → [chapitre 9](09-reseau-des-pods.md)

**volumeBindingMode** — Moment où une PVC est liée : `Immediate` (défaut) ou `WaitForFirstConsumer`, qui attend qu'un pod l'utilise et tient compte du nœud choisi. → [chapitre 15](15-stockage.md)

**volumeClaimTemplates** — Modèles de PVC d'un StatefulSet : une PVC par pod, nommée `<modèle>-<pod>` (`data-redis-0`). → [chapitre 15](15-stockage.md)

**VolumeSnapshot** — Demande d'instantané d'une PVC (`snapshot.storage.k8s.io/v1`) réalisée par un pilote CSI selon une VolumeSnapshotClass ; une nouvelle PVC peut en être restaurée par `dataSource`. → [chapitre 15](15-stockage.md)

**VPA** (*Vertical Pod Autoscaler*) — Projet complémentaire du HPA, hors de Kubernetes lui-même, qui recommande ou applique des requests ; modes `Off`, `Initial`, `Recreate`, `InPlaceOrRecreate`, `InPlace` (`Auto` est déprécié). → [chapitre 7](07-autoscaling.md)

### W

**WaitForFirstConsumer** — Mode de liaison qui retarde la liaison et le provisionnement d'une PVC jusqu'à l'ordonnancement d'un pod qui l'utilise. → [chapitre 15](15-stockage.md)

**Watch** — Requête d'API de longue durée qui reçoit les créations, modifications et suppressions d'une ressource à partir d'une `resourceVersion` ; tous les contrôleurs en dépendent. → [chapitre 2](02-architecture.md)

**Webhook d'admission** — Service externe que kube-apiserver appelle pour muter (`MutatingWebhookConfiguration`) ou valider (`ValidatingWebhookConfiguration`) des requêtes. → [chapitre 18](18-interfaces-crd-et-operateurs.md)

**Worker** — Nœud qui n'héberge que des charges applicatives et les agents de nœud (kubelet, kube-proxy, plugin CNI). → [chapitre 2](02-architecture.md)

---
