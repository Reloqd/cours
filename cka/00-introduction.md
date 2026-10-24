---
title: "CKA — Cours complet pour la certification Certified Kubernetes Administrator"
description: "Page de titre, avant-propos et table des matières d'un cours de niveau expert qui prépare au CKA sur Kubernetes v1.37, avec un lab minikube à trois nœuds et un fil rouge d'exercices."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

# CKA : Cours complet pour la certification Certified Kubernetes Administrator

> **Public cible** : Administrateur système ou ingénieur DevOps à l'aise sous Linux (shell, systemd, réseau IP, paquets), qui connaît les conteneurs et a déjà manipulé `kubectl`.
> **Objectif** : Réussir le CKA en maîtrisant, au niveau d'un administrateur confirmé, chaque compétence du programme : construire, configurer, exposer, sécuriser, mettre à jour, sauvegarder et dépanner un cluster Kubernetes, vite et sans approximation.
> **Certification visée** : Certified Kubernetes Administrator (CKA), programme CNCF `CKA_Curriculum_v1.37`
> **Version de référence** : Kubernetes v1.37 (lab en v1.37.0 sous minikube v1.39.0) ; faits vérifiés le 23 octobre 2026

---

## Avant-propos

### À qui s'adresse ce cours

Ce cours s'adresse à qui veut obtenir le CKA et, au-delà de l'examen, comprendre ce qu'il fait quand il administre un cluster. Il suppose que tu sais travailler en ligne de commande sous Linux et que tu as déjà vu passer des pods et des Deployments, mais il ne suppose pas que tu les maîtrises : chaque notion est reprise depuis son mécanisme. Il vise pourtant le niveau d'un expert. Pour chaque objet, il donne les valeurs par défaut exactes, les cas limites, la raison des choix de conception, les pièges que l'examen exploite et la façon la plus rapide d'obtenir le résultat sous chronomètre.

C'est un livre d'exercices autant qu'un livre de cours. Le CKA est un examen entièrement pratique : quinze à vingt tâches à réaliser en deux heures sur de vrais clusters. Le lire ne suffit pas ; chaque chapitre se termine donc par des exercices rédigés comme des tâches d'examen, qui s'enchaînent sur un même cluster d'un bout à l'autre du cours.

### Prérequis

Côté connaissances, il te faut être à l'aise avec le shell Bash (redirections, tubes, variables, boucles simples), un éditeur en terminal (vim de préférence, puisque c'est celui de l'examen), systemd (`systemctl`, `journalctl`), les bases du réseau IP (sous-réseaux, routage, ports, DNS), la syntaxe YAML, les notions de certificat X.509 et d'autorité de certification, et l'anglais technique écrit : les énoncés de l'examen ne sont pas proposés en français.

Côté matériel, il te faut un **poste Linux** avec Docker utilisable sans `sudo`, 4 CPU et 12 Gio de mémoire libres, une vingtaine de gigaoctets de disque et un accès à Internet. Sous macOS ou Windows, les adresses des nœuds du lab ne sont pas joignables depuis l'hôte, et une partie des exercices ne fonctionnerait pas telle qu'elle est écrite : prends alors une machine virtuelle Linux. Le chapitre 19 utilise en plus un lab de cinq machines virtuelles, celui du cours voisin consacré à [kubeadm](../kubeadm/00-introduction.md), pour les compétences d'installation et de mise à jour que minikube ne permet pas de pratiquer.

### Version de référence

Tout le cours est écrit pour **Kubernetes v1.37**, version de l'environnement d'examen depuis l'automne 2026, et chaque comportement décrit a été vérifié pour cette version le 23 octobre 2026, dans la documentation officielle (kubernetes.io et ses sources, la référence de l'API, les sites officiels des projets) et sur le lab lui-même. Quand le lab minikube diffère d'un cluster kubeadm d'examen, le texte le dit et donne les deux valeurs.

| Élément | Version | Remarque |
|---|---|---|
| Examen CKA | Kubernetes v1.37, programme `CKA_Curriculum_v1.37` | 2 h, 15 à 20 tâches, seuil 66 % |
| Kubernetes | v1.37 (sortie le 26 août 2026, correctif courant v1.37.1) | le lab tourne en v1.37.0, dernière version prise en charge par minikube v1.39.0 |
| minikube | v1.39.0 | pilote docker, runtime containerd 2.3.4 |
| kubectl | v1.37.1 | Kustomize v5.8.1 intégré |
| Helm | v4.3.1 | Helm 3 ne reçoit plus que des correctifs de sécurité, jusqu'au 11 novembre 2026 |
| Calico | v3.32.2 | IPIP, blocs /26 |
| etcd | 3.7.0 (image `3.7.0-0`) | restauration par `etcdutl` |
| CoreDNS | v1.14.6 | |
| metrics-server | v0.9.0 | addon minikube |
| Contrôleur de l'addon ingress | ingress-nginx v1.15.1 | projet retiré le 24 mars 2026 ; l'API Ingress reste au programme |
| Gateway API | v1.6 (v1.6.3 publiée ; Envoy Gateway installe le bundle v1.6.1, canal experimental) | |
| Envoy Gateway | v1.9.2 | |
| crictl | v1.35.0 | dans les nœuds du lab |

Les versions de cert-manager et du chart podinfo, utilisés aux chapitres 17 et 18, sont fixées dans ces chapitres. Les images des exercices sont toujours épinglées, jamais en `latest` :

| Usage | Image |
|---|---|
| Frontal `front`, version initiale (mise à jour du chapitre 5) | `nginx:1.29-alpine` |
| Frontal `front` (version courante) et `front-v2` | `nginx:1.30.6-alpine` |
| API `api` | `registry.k8s.io/e2e-test-images/agnhost:2.66.1` |
| Base de données `redis` | `redis:8.10.2-alpine` |
| Boîte à outils `outils` | `nicolaka/netshoot:v0.16` |
| Tâches simples | `busybox:1.37.0` |
| Tests DNS | `registry.k8s.io/e2e-test-images/jessie-dnsutils:1.7` |
| Client HTTP | `curlimages/curl:8.23.0` |

### Conventions

**Typographie.** Le texte tutoie le lecteur. Les noms d'objets de l'API gardent leur nom anglais et leur majuscule (Deployment, Service, PersistentVolumeClaim, NetworkPolicy), comme dans le programme et dans les énoncés ; les notions sans objet propre gardent leur nom anglais quand c'est le vocabulaire de l'examen (taint, toleration, sidecar, rollout). Les compétences du programme sont citées en anglais et en italique. Le code, les commandes, les noms de fichiers, de champs et de valeurs sont en `police à chasse fixe`. Les domaines de test utilisent `.example`, réservé à la documentation.

**Commandes.** Les blocs de code portent leur langage (`bash`, `yaml`) ; les sorties de commandes sont dans des blocs sans langage, et viennent du lab réel quand elles ont été relevées (les suffixes aléatoires des noms de pods et les âges varient chez toi). Le prompt n'est pas affiché. Sauf mention contraire, une commande s'exécute **sur ton poste**. `kubectl` est toujours écrit en entier dans le texte ; l'alias `k`, disponible à l'examen, est présenté aux chapitres 3 et 24. Les commandes minikube portent toujours `-p cka`. Une commande à exécuter **dans un nœud** est précédée de sa commande d'accès et utilise `sudo` dès qu'elle touche au système :

```bash
minikube -p cka ssh -n cka-m02
sudo crictl ps
exit
```

Une commande à exécuter **dans un pod** passe par `kubectl exec`, avec `--` avant la commande (obligatoire depuis Kubernetes 1.35).

**Encadrés.** Le cours utilise les encadrés d'Obsidian :

| Encadré | Usage |
|---|---|
| `> [!note]` | précision, contexte |
| `> [!tip] Réflexe d'examen` | geste qui fait gagner du temps ou des points à l'examen |
| `> [!warning]` | erreur fréquente, comportement surprenant |
| `> [!danger]` | action destructrice ou risquée |
| `> [!info] minikube ≠ examen` | écart entre le lab et un cluster kubeadm d'examen, avec les deux valeurs |
| `> [!summary] À retenir` | les points essentiels, en fin de chapitre |
| `> [!example]- Solution` | solution d'exercice, repliée |

**Fin de chapitre.** Chaque chapitre se termine dans le même ordre : une section « Pièges courants » (chaque piège sous la forme MAUVAIS, SYMPTÔME, BON), l'encadré « À retenir », puis les exercices.

**Exercices.** Chaque exercice indique son **point de départ** (l'exercice précédent, ou un instantané du lab), puis donne un énoncé rédigé comme une tâche d'examen, avec des noms, des namespaces et des valeurs exacts. La solution est repliée : fais l'exercice avant de l'ouvrir. Elle donne les commandes, explique pourquoi, et se termine toujours par une **vérification** et le résultat attendu.

**Renvois.** Un renvoi cite le chapitre, ou la section : « (chapitre 10) », « voir 15.3 ». Les liens entre fichiers sont relatifs.

### Comment travailler ce cours

**L'ordre.** Les parties se suivent dans l'ordre et chacune s'appuie sur la précédente. La partie I installe le lab et les outils de travail (architecture, kubectl). Les parties II à V construisent, domaine par domaine, l'application du fil rouge et tout ce qui l'entoure. La partie VI, consacrée au dépannage, suppose tout le reste acquis : elle casse ce que tu as construit. La partie VII prépare le jour de l'examen.

**Le lab.** Le [chapitre 1](01-introduction-et-contexte.md) installe kubectl, Helm et minikube et démarre le cluster du cours : trois nœuds `cka`, `cka-m02` et `cka-m03`, en Kubernetes v1.37.0, avec containerd et Calico. Relève la limite inotify de ton poste **avant** le premier démarrage (chapitre 1.6) : c'est la première cause de nœuds `NotReady` sur ce type de lab. L'[annexe C](annexe-c-lab.md) décrit tous les scripts du dossier `lab/`.

**Le fil rouge et les instantanés.** Les exercices construisent pas à pas, dans le namespace `boutique`, une petite application (un frontal nginx, une API, un Redis) et tout ce qu'un administrateur y ajoute. Tes manifestes vivent dans `~/cka/`. Cinq instantanés jalonnent le parcours : **I0** après le chapitre 1, **I1** après le chapitre 8, **I2** après le chapitre 14, **I3** après le chapitre 15, **I4** après le chapitre 18. `lab/restaurer.sh I2` recrée le cluster et rejoue tous les états jusqu'à I2, en cinq à dix minutes : tu peux reprendre le cours à n'importe quel jalon, ou effacer une expérience ratée.

**Les pannes.** Les chapitres 22 et 23 s'exercent sur dix-neuf pannes injectées par `lab/pannes.sh casser NN` depuis I4, et vérifiées par `lab/pannes.sh verifier NN`. Ne lis pas le script : une panne dont on connaît la cause n'entraîne plus le diagnostic. Refais chaque panne au moins deux fois, la seconde chronomètre en main.

**L'examen blanc.** L'[annexe B](annexe-b-examen-blanc.md) propose dix-sept tâches, deux heures, cent points, seuil à 66, préparées par `lab/examen-blanc/preparer.sh` et notées par `lab/examen-blanc/corriger.sh`. Passe-le une fois le chapitre 23 terminé, en conditions réelles, avant la première session du simulateur killer.sh (chapitre 24).

**Le rythme.** Compte dix semaines à raison de huit à dix heures par semaine, ou six semaines si tu administres déjà Kubernetes ; le chapitre 1.10 détaille les deux plans. Refais chaque exercice une seconde fois quelques jours plus tard, sans la solution : la vitesse que demande l'examen vient de la répétition.

---

## Table des matières

### Partie I — Fondations

- [1. L'examen, le programme et le lab](01-introduction-et-contexte.md) — format de l'examen, ressources autorisées, programme v1.37 et table de correspondance avec le cours, changements de Kubernetes 1.35 à 1.37, installation du lab minikube, plan d'adressage, écarts avec l'examen, fil rouge et instantanés, plan de travail.
- [2. Architecture d'un cluster Kubernetes](02-architecture.md) — composants du control plane et des nœuds, chemin d'une requête vers l'API, boucles de réconciliation, pods statiques et pods miroirs, structure des objets, groupes et versions d'API, namespaces.
- [3. kubectl efficace : kubeconfig, impératif, sorties](03-kubectl-efficace.md) — kubeconfig et contextes, impératif et déclaratif, générateurs, `explain`, sorties jsonpath et custom-columns, sélecteurs, `patch` et `apply` côté serveur, alias, complétion, vim, `kuberc`.

### Partie II — Charges de travail et ordonnancement (15 %)

- [4. Pods et conteneurs](04-pods.md) — cycle de vie, phases et conditions, ressources et classes QoS, sondes, init containers, sidecars natifs, redimensionnement en place, arrêt gracieux.
- [5. Deployments et autres contrôleurs](05-deployments-et-controleurs.md) — ReplicaSet, Deployment et ses rollouts, DaemonSet, StatefulSet, Job, CronJob, PodDisruptionBudget, primitives d'auto-réparation.
- [6. ConfigMaps et Secrets](06-configmaps-et-secrets.md) — création, consommation, propagation des mises à jour, types de Secret, volumes projetés, downward API, chiffrement au repos.
- [7. Ressources et autoscaling](07-autoscaling.md) — pipeline de métriques, metrics-server, `kubectl top`, HPA v2 et sa tolérance configurable, VPA et Cluster Autoscaler en concept.
- [8. Ordonnancement et admission des pods](08-ordonnancement-et-admission.md) — scheduler, affinités, topologySpreadConstraints, taints et tolerations, priorités, ResourceQuota, LimitRange, Pod Security Admission, cordon et drain.

### Partie III — Services et réseau (20 %)

- [9. Le réseau des pods et le CNI](09-reseau-des-pods.md) — modèle réseau, espaces de noms réseau, spécification CNI, Calico, trafic entre pods, hostNetwork, rôle de kube-proxy.
- [10. Services et EndpointSlices](10-services.md) — ClusterIP, NodePort, LoadBalancer, ExternalName, headless, EndpointSlices, règles de kube-proxy, politiques de trafic, MetalLB.
- [11. CoreDNS et la résolution de noms](11-coredns.md) — spécification DNS de Kubernetes, Corefile, `resolv.conf` et `ndots`, dnsPolicy, personnalisation, dépannage.
- [12. Ingress et contrôleurs d'Ingress](12-ingress.md) — IngressClass, règles et pathType, TLS, annotations, retrait d'ingress-nginx, dépannage.
- [13. Gateway API](13-gateway-api.md) — rôles, GatewayClass, Gateway, HTTPRoute, ReferenceGrant, canaux, statuts, migration depuis Ingress, Envoy Gateway.
- [14. NetworkPolicies](14-network-policies.md) — sémantique, refus par défaut, sélecteurs et piège ET/OU, DNS, méthode de test.

### Partie IV — Stockage (10 %)

- [15. Volumes, PV, PVC et StorageClasses](15-stockage.md) — types de volumes, liaison, modes d'accès, politiques de récupération, provisionnement dynamique, expansion, CSI, snapshots, StatefulSet et volumes `local`.

### Partie V — Architecture, installation et configuration (25 %)

- [16. Authentification, RBAC et ServiceAccounts](16-rbac-et-authentification.md) — certificats clients et CSR, autorisation Node et RBAC, rôles et bindings, agrégation, ServiceAccounts et jetons, `auth can-i`.
- [17. Helm et Kustomize](17-helm-et-kustomize.md) — Helm 4, dépôts et OCI, valeurs, révisions et rollback ; Kustomize, générateurs, patches, overlays.
- [18. Interfaces d'extension, CRD et opérateurs](18-interfaces-crd-et-operateurs.md) — CRI, CNI, CSI, webhooks et agrégation d'API, CRD, contrôleurs et patron opérateur, cert-manager.
- [19. kubeadm : installer, haute disponibilité, mettre à jour](19-kubeadm-installation-ha-et-mises-a-jour.md) — préparation des nœuds, `kubeadm init` et `join`, control plane hautement disponible, mise à jour de 1.36 à 1.37, certificats.
- [20. etcd : sauvegarde et restauration](20-etcd-sauvegarde-et-restauration.md) — Raft et quorum, etcdctl, sauvegarde, `etcdutl`, restauration sur kubeadm et sur le lab.

### Partie VI — Dépannage (30 %)

- [21. Journaux, événements et métriques](21-journaux-et-metriques.md) — flux de sortie des conteneurs, `/var/log/pods`, `kubectl logs`, journaux des nœuds, événements, `kubectl top`, allocation par nœud.
- [22. Dépanner les applications et le réseau](22-depanner-les-applications.md) — méthode, états des pods, `kubectl debug`, Services, DNS, NetworkPolicies, Ingress et Gateway ; pannes 01 à 10.
- [23. Dépanner les nœuds et le control plane](23-depanner-le-cluster.md) — nœuds NotReady, composants en pods statiques, API server à terre, scheduler, controller-manager, etcd, CoreDNS, kube-proxy, kubeconfig ; pannes 11 à 19.

### Partie VII — L'examen

- [24. Le jour de l'examen](24-examen.md) — environnement PSI, réglages du début, stratégie de temps, liste de contrôle par tâche, erreurs classiques, pages de documentation par domaine, killer.sh, veille et jour J.

### Annexes

- [Annexe A. Aide-mémoire](annexe-a-aide-memoire.md) — les commandes, champs et chemins à connaître, par domaine.
- [Annexe B. Examen blanc](annexe-b-examen-blanc.md) — dix-sept tâches en deux heures, notées sur cent.
- [Annexe C. Le lab : scripts, instantanés, pannes](annexe-c-lab.md) — `lab/demarrer.sh`, `lab/restaurer.sh`, les états par chapitre, `lab/pannes.sh`, les scripts de l'examen blanc.
- [Annexe D. Glossaire](annexe-d-glossaire.md) — les termes du cours et leur équivalent anglais.
- [Bibliographie](bibliographie.md) — sources officielles, datées.

---
