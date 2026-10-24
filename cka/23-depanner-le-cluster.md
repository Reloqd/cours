---
title: "CKA — 23. Dépanner les nœuds et le control plane"
description: "Pourquoi et quand un nœud passe NotReady, ce que deviennent ses pods, comment diagnostiquer kubelet, runtime, certificats et CNI, puis réparer chaque composant du control plane, CoreDNS, kube-proxy et le kubeconfig, y compris quand l'API ne répond plus."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 23. Dépanner les nœuds et le control plane

Le chapitre 22 supposait un cluster sain et cherchait la panne dans l'application. Ici, c'est le cluster lui-même qui flanche : un nœud passe `NotReady`, les nouveaux pods ne sont plus placés, un `kubectl scale` reste sans effet, ou `kubectl` ne parvient même plus à joindre l'API. Ces pannes demandent de quitter `kubectl` pour descendre sur les nœuds : `systemctl`, `journalctl`, `crictl`, les fichiers de `/etc/kubernetes` et de `/var/lib/kubelet`. Le chapitre couvre les compétences « Troubleshoot clusters and nodes » et « Troubleshoot cluster components » du domaine Troubleshooting (30 %), les deux qui rapportent le plus de points à l'examen parmi les tâches de dépannage, car une seule erreur de manifeste y suffit à tout bloquer. Il s'appuie sur le [chapitre 2](02-architecture.md) (composants, pods statiques, kubelet sous systemd), sur le [chapitre 21](21-journaux-et-metriques.md) (journaux) et renvoie au [chapitre 19](19-kubeadm-installation-ha-et-mises-a-jour.md) pour les certificats et au [chapitre 20](20-etcd-sauvegarde-et-restauration.md) pour etcd. Les exercices sont les pannes 11 à 19 de `lab/pannes.sh`, plus trois exercices de lecture.

### 23.1 La carte du terrain

#### 23.1.1 Qui dépend de qui

```
Dépendances du cluster (une flèche = « a besoin de »)
═════════════════════════════════════════════════════

                                ┌──────────────┐
                                │     etcd     │  pod statique, 2379 (clients) / 2380 (pairs)
                                └──────▲───────┘
                                       │
                                ┌──────┴───────┐
            ┌──────────────────▶│kube-apiserver│◀───────────────────┐
            │                   └──▲────▲───▲──┘                    │
            │                      │    │   │                       │
  ┌─────────┴────────┐ ┌───────────┴─┐  │ ┌─┴──────────┐   ┌────────┴─────────┐
  │kube-controller-  │ │kube-scheduler│ │ │  kubectl   │   │ kubelet (chaque  │
  │manager           │ │             │  │ │ (kubeconfig)│   │ nœud) ──▶ runtime│
  └──────────────────┘ └─────────────┘  │ └────────────┘   │       ──▶ CNI    │
                                        │                   └──────────────────┘
                              ┌─────────┴─────────┐
                              │ kube-proxy, CoreDNS│  (pods ordinaires, kube-system)
                              └────────────────────┘

  Le kubelet du control plane lance etcd et les trois composants à partir des
  manifestes de /etc/kubernetes/manifests, SANS avoir besoin de l'API.
```

Ce graphe dicte l'ordre du diagnostic. Si l'API ne répond pas, rien d'autre ne peut être observé par `kubectl` : on commence par elle (23.4.3). Si l'API répond, on regarde les pods de `kube-system` ; un composant absent ou en boucle se voit immédiatement. Si tout le control plane est sain, le problème est sur un nœud (23.2) ou dans un composant de service (CoreDNS, kube-proxy).

```
Arbre de décision
═════════════════

  kubectl get nodes répond ?
  ├── non ── message ? ── « refused » sur un port inattendu ─▶ kubeconfig (23.7)
  │                    └─ « refused » / délai sur le bon port ─▶ apiserver ou etcd
  │                                                             (ssh + crictl, 23.4.3)
  └── oui ── un nœud NotReady ? ─────────────────────────────▶ 23.2
             pods de kube-system en échec ? ──────────────────▶ 23.4, 23.5, 23.6
             pods Pending sans événement ? ───────────────────▶ scheduler (23.4.5)
             contrôleurs inertes (scale sans effet) ? ────────▶ controller-manager (23.4.6)
             DNS ou Services cassés partout ? ────────────────▶ CoreDNS (23.5), kube-proxy (23.6)
```

#### 23.1.2 Les chemins, kubeadm et minikube côte à côte

| Élément | Cluster kubeadm (examen) | Lab minikube |
|---|---|---|
| Accès au nœud | `ssh <nœud>` puis `sudo -i` | `minikube -p cka ssh [-n cka-m02]` puis `sudo` |
| Manifestes statiques | `/etc/kubernetes/manifests/` | identique |
| Certificats | `/etc/kubernetes/pki/` (etcd : `pki/etcd/`) | `/var/lib/minikube/certs/` (etcd : `certs/etcd/`) |
| Données etcd | `/var/lib/etcd` | `/var/lib/minikube/etcd` |
| Port de l'API | 6443 | 8443 |
| kubeconfigs des composants | `/etc/kubernetes/{admin,super-admin,controller-manager,scheduler,kubelet}.conf` | identique (plus `/var/lib/minikube/kubeconfig`) |
| Configuration du kubelet | `/var/lib/kubelet/config.yaml` | identique |
| CA de confiance du kubelet (`clientCAFile`) | `/etc/kubernetes/pki/ca.crt` | `/var/lib/minikube/certs/ca.crt` |
| Certificat client du kubelet | `/var/lib/kubelet/pki/kubelet-client-current.pem` | identique |
| Unité systemd du kubelet | `/usr/lib/systemd/system/kubelet.service` (`RestartSec=10`) | `/lib/systemd/system/kubelet.service` (`RestartSec=600ms`) |
| Drop-in | `/usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf`, lit `kubeadm-flags.env` et `/etc/default/kubelet` | `/etc/systemd/system/kubelet.service.d/10-kubeadm.conf`, options en dur |
| Kubelet activé au démarrage | oui, partout | non sur `cka` (minikube le lance), oui sur les workers |
| Binaires | `/usr/bin/{kubeadm,kubelet,kubectl}` | `/var/lib/minikube/binaries/v1.37.0/`, hors `PATH` |
| `crictl` | en root | `sudo crictl` |
| Élection de leader (scheduler, controller-manager) | activée | `--leader-elect=false` |
| Réplicas de CoreDNS | 2 | 1 par défaut, 2 depuis le chapitre 11 |

Les deux unités ont `Restart=always` et désactivent la limite de redémarrages de systemd (`StartLimitInterval=0` dans le paquet amont, `StartLimitIntervalSec=0` dans minikube) : un kubelet qui échoue au démarrage est relancé indéfiniment, toutes les 10 s sous kubeadm, toutes les 600 ms sous minikube. C'est ce qui produit l'état `activating (auto-restart)` de 23.2.3. Les ports de chaque composant sont au tableau de 2.4.

### 23.2 Un nœud NotReady

#### 23.2.1 Les battements de cœur et leurs délais

Un nœud ne « tombe » pas de lui-même dans l'API : c'est le **contrôleur des nœuds** (node lifecycle controller, dans kube-controller-manager) qui constate l'absence de nouvelles et change son état. Le kubelet envoie deux sortes de signaux :

| Signal | Fréquence | Champ de configuration du kubelet |
|---|---|---|
| Renouvellement de la Lease `kube-node-lease/<nœud>` | toutes les 10 s | durée annoncée `nodeLeaseDurationSeconds: 40` |
| Calcul de `status` (conditions, capacité) | toutes les 10 s (`nodeStatusUpdateFrequency`) | envoyé s'il a changé, sinon au moins toutes les 5 min (`nodeStatusReportFrequency`) |

Le contrôleur examine chaque nœud toutes les **5 s** (`--node-monitor-period`). Quand ni la Lease ni le statut n'ont été rafraîchis depuis **50 s** (`--node-monitor-grace-period`, 40 s avant la 1.32), il passe toutes les conditions du kubelet à `Unknown`, avec la raison `NodeStatusUnknown` et le message `Kubelet stopped posting node status.`, et pose les taints `node.kubernetes.io/unreachable` en `NoSchedule` et en `NoExecute`. Les 40 s de la Lease ne sont qu'une durée déclarée : c'est la période de grâce du contrôleur qui compte. Un nœud qui vient de s'enregistrer bénéficie d'une grâce plus longue, `--node-startup-grace-period` (1 min).

```
Chronologie d'un kubelet qui s'arrête (valeurs par défaut)
══════════════════════════════════════════════════════════

 t = 0       dernier renouvellement de la Lease ; le kubelet s'arrête juste après
 t ≈ 50 s    Ready=Unknown, taints unreachable:NoSchedule et :NoExecute
             événement NodeNotReady ; les pods du nœud passent Ready=False
             → plus aucun pod n'y est placé ; les Services retirent ses pods
 t ≈ 350 s   fin des tolerations de 300 s (DefaultTolerationSeconds) :
             les pods sont supprimés par le contrôleur d'éviction par taint
             → Deployments, ReplicaSets : remplaçants créés ailleurs
             → StatefulSets : le pod reste Terminating, aucun remplaçant
             → pods nus : supprimés, jamais recréés
             → DaemonSets : tolèrent sans limite, restent rattachés au nœud
 retour      le kubelet reprend : Ready=True en ~1 s, taints retirées,
             il achève les suppressions en attente
```

Le lab l'a mesuré : après `systemctl stop kubelet` sur `cka-m03`, le nœud est passé `NotReady` en 44 s, soit 52 s après le dernier renouvellement de sa Lease. Les évictions sont en outre limitées en débit : 0,1 nœud par seconde (`--node-eviction-rate`), et, dans un cluster d'au plus 50 nœuds, plus aucune éviction quand au moins 55 % des nœuds d'une zone sont malades (`--unhealthy-zone-threshold`, `--large-cluster-size-threshold`) ; le contrôleur suppose alors une panne de réseau plutôt qu'une panne de nœuds. Les labels `topology.kubernetes.io/zone` du chapitre 8 définissent ces zones dans le lab.

> [!warning] Sans controller-manager, pas de NotReady
> Ce ne sont pas les nœuds qui se déclarent morts. Si kube-controller-manager est arrêté, un nœud dont le kubelet s'est tu reste affiché `Ready` indéfiniment, avec une Lease périmée. Quand l'état des nœuds paraît incohérent, vérifie d'abord le controller-manager.

#### 23.2.2 Unknown ou False : deux familles de causes

La valeur de la condition `Ready` sépare déjà les pistes :

| `Ready` | Qui l'a écrit | Signification | Exemples de message |
|---|---|---|---|
| `Unknown` | le contrôleur des nœuds | le kubelet ne donne plus de nouvelles | `Kubelet stopped posting node status.` |
| `False` | le kubelet lui-même | le kubelet tourne et joint l'API, mais un sous-système n'est pas prêt | `container runtime network not ready: NetworkReady=false reason:NetworkPluginNotReady message:Network plugin returns error: cni plugin not initialized` ; `container runtime is down` ; `PLEG is not healthy: pleg was last seen active …` |

`Unknown` désigne le kubelet lui-même (arrêté, en boucle de démarrage, incapable de s'authentifier) ou le réseau entre le nœud et l'API. `False` désigne ce que le kubelet surveille : le runtime, le CNI (aucune configuration dans `/etc/cni/net.d`, chapitre 9), le PLEG (le kubelet n'arrive plus à relister les conteneurs, souvent un runtime figé). Le message de la condition est lisible par `kubectl describe node` ou directement :

```bash
kubectl get node cka-m03 -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
kubectl -n kube-node-lease get lease cka-m03 -o jsonpath='{.spec.renewTime}{"\n"}'
```

Les conditions de pression (`MemoryPressure`, `DiskPressure`, `PIDPressure`) laissent le nœud `Ready` : elles posent seulement les taints `NoSchedule` correspondantes et déclenchent les évictions du kubelet quand un seuil `evictionHard` est franchi (22.2.7).

#### 23.2.3 Sur le nœud

La démarche tient en cinq commandes, à lancer dans cet ordre :

```bash
minikube -p cka ssh -n cka-m03          # à l'examen : ssh <nœud>, puis sudo -i
sudo systemctl status kubelet           # état du service, dernières lignes du journal
sudo journalctl -u kubelet -n 50 --no-pager
sudo systemctl status containerd
sudo crictl ps                          # le runtime répond-il ?
```

`systemctl status` donne l'état en une ligne, et chaque état oriente :

| `Active:` | `Loaded:` | Lecture |
|---|---|---|
| `inactive (dead)` | `…; disabled; …` | arrêté et désactivé : `systemctl enable --now kubelet` |
| `inactive (dead)` | `…; enabled; …` | arrêté à la main ; il repartira au prochain démarrage de la machine |
| `activating (auto-restart) (Result: exit-code)` | — | le kubelet démarre puis sort aussitôt : la cause est dans `journalctl` |
| `active (running)` | — | le kubelet tourne : chercher dans son journal ce qui l'empêche de faire son travail (API injoignable, certificat, runtime) |
| `failed` | — | systemd a renoncé ; après correction : `systemctl reset-failed kubelet`, puis `systemctl restart kubelet` |

Pour un kubelet qui sort au démarrage, la cause est la dernière ligne `E…` ou `F…` avant chaque `Main process exited` :

```bash
sudo journalctl -u kubelet -n 200 --no-pager | grep -E 'command failed|E[0-9]{4} ' | tail -3
```

| Message du journal | Cause | Où corriger |
|---|---|---|
| `failed to load kubelet config file, path: /var/lib/kubelet/config.yaml, error: …` | YAML invalide ou champ inconnu (le décodage est strict) | `/var/lib/kubelet/config.yaml` |
| `failed to run Kubelet: open /…/ca.crt: no such file or directory` | un fichier référencé par la configuration est absent (`clientCAFile`, `staticPodPath` inexistant n'est, lui, qu'ignoré) | config.yaml |
| `failed to run Kubelet: unable to load bootstrap kubeconfig: …` ou `invalid kubeconfig` | kubeconfig du kubelet absent ou faux | `/etc/kubernetes/kubelet.conf`, options de l'unité |
| `failed to run Kubelet: running with swap on is not supported, please disable swap or set --fail-swap-on flag to false` | swap actif et `failSwapOn: true` | swap ou config.yaml |
| refus de démarrer sur un hôte en cgroup v1 | `failCgroupV1` vaut `true` par défaut depuis la 1.35 | passer l'hôte en cgroup v2 ; `failCgroupV1: false` n'est qu'un contournement temporaire (chapitre 19) |
| `unknown flag: --…` | option invalide dans l'unité ou le drop-in | `systemctl cat kubelet`, puis `systemctl daemon-reload` |
| `x509: certificate has expired or is not yet valid` | certificat client du kubelet expiré, ou horloge du nœud fausse | `/var/lib/kubelet/pki/`, `date` |
| `connect: connection refused` vers `…:6443` (`:8443` sur le lab) | API injoignable depuis le nœud | réseau, apiserver |
| `"Container runtime network not ready" … cni plugin not initialized` | pas de configuration CNI | `/etc/cni/net.d`, pods du CNI (chapitre 9) |

Le pilote de cgroups, source classique de pannes autrefois, ne l'est plus avec containerd 2.x : depuis la 1.34, le kubelet le demande au runtime par l'appel CRI `RuntimeConfig` et ne se sert du champ `cgroupDriver` qu'en repli, pour un runtime qui ne sait pas répondre (containerd 1.x). Toute modification de l'unité ou du drop-in exige `sudo systemctl daemon-reload` avant le redémarrage ; une modification de `/var/lib/kubelet/config.yaml` exige seulement `sudo systemctl restart kubelet`. Pour vérifier un certificat : `sudo openssl x509 -noout -enddate -in /var/lib/kubelet/pki/kubelet-client-current.pem` (ou, si `openssl` manque dans le nœud, en recopiant le fichier sur ton poste). Le kubelet le renouvelle seul tant que `rotateCertificates: true` et que le controller-manager approuve et signe ses CSR : un certificat expiré sur un seul nœud trahit souvent un nœud éteint au-delà de la durée de vie du certificat.

> [!info] minikube ≠ examen
> À l'examen, tu te connectes par `ssh <nœud>` puis `sudo -i`, et tu reviens au poste de départ par `exit` après chaque tâche (une connexion SSH imbriquée n'est pas prise en charge). Sur le lab, `minikube -p cka ssh -n cka-m03` ouvre une session en tant que `docker`, et chaque commande d'administration prend `sudo`. Les sorties de `systemctl` et de `journalctl` sont les mêmes ; seuls les chemins de l'unité et l'intervalle de redémarrage diffèrent (23.1.2).

#### 23.2.4 Ce que deviennent les pods

Les conséquences d'un nœud muet dépendent du type de propriétaire, comme le montre la chronologie de 23.2.1. Trois points méritent d'être retenus pour l'examen. Les pods d'un **StatefulSet** ne sont jamais remplacés tant que l'ancien pod existe dans l'API : `redis-0` reste `Terminating` jusqu'au retour du kubelet, car Kubernetes ne peut pas savoir si le conteneur tourne encore et écrit sur son volume. Les **pods nus**, comme `outils`, sont supprimés et personne ne les recrée : il faut les recréer soi-même (pour `outils`, `lab/etats/04-pods/appliquer.sh` le refait). Enfin, quand on **sait** qu'un nœud est éteint pour de bon, la taint `node.kubernetes.io/out-of-service=nodeshutdown:NoExecute` posée à la main autorise la suppression forcée de ses pods et le détachement immédiat de leurs volumes : c'est la procédure d'arrêt non gracieux, qui débloque les StatefulSets.

Le retour du kubelet ne ramène pas les pods déplacés : Kubernetes ne rééquilibre jamais un cluster de lui-même. Les nouveaux pods iront sur le nœud revenu ; les autres restent où le scheduler les a mis.

### 23.3 Les taints posées automatiquement

Le tableau complet est en 8.8 ; voici sa lecture en dépannage. Le scheduler ne lit pas les conditions des nœuds, seulement leurs taints : chaque état anormal d'un nœud se traduit donc par une taint, que `kubectl describe node <n> | grep -A3 Taints` montre.

| Taint observée | Ce qu'elle dit | Ce qu'il faut regarder |
|---|---|---|
| `node.kubernetes.io/unreachable` (`NoSchedule` + `NoExecute`) | `Ready=Unknown` : kubelet muet | kubelet, réseau vers l'API (23.2.3) |
| `node.kubernetes.io/not-ready` (`NoSchedule` + `NoExecute`) | `Ready=False` : le kubelet signale un problème | message de la condition `Ready` (runtime, CNI) |
| `node.kubernetes.io/unschedulable:NoSchedule` | nœud cordonné (`kubectl cordon`, `drain`) | `kubectl uncordon` si la maintenance est finie |
| `node.kubernetes.io/{memory,disk,pid}-pressure:NoSchedule` | pression sur une ressource | `kubectl describe node`, disque et mémoire du nœud |
| `node.kubernetes.io/network-unavailable:NoSchedule` | réseau du nœud non configuré | CNI |
| toute autre clé (`maintenance=oui:NoExecute`…) | posée par une personne ou un outil | qui l'a posée, et si elle doit rester |

Une taint `NoExecute` posée à la main évince immédiatement les pods qui ne la tolèrent pas, **sans tenir compte des PodDisruptionBudgets** : seule l'API d'éviction (utilisée par `kubectl drain`) les respecte. Les DaemonSets de `kube-system` (calico-node, kube-proxy) tolèrent toutes les taints (`operator: Exists`), comme `agent-noeud` depuis le chapitre 8 ; ils restent donc sur un nœud vidé par une taint.

### 23.4 Le control plane en pods statiques

#### 23.4.1 Ce que le mécanisme implique pour le dépannage

Le chapitre 2 (2.5) a décrit les pods statiques. Pour le dépannage, sept conséquences comptent.

1. **Le manifeste fait foi.** On répare en éditant `/etc/kubernetes/manifests/<composant>.yaml` ; le kubelet voit le changement (inotify, et relecture toutes les 20 s) et recrée le pod. `kubectl edit` sur le mirror pod ne sert à rien.
2. **Un manifeste illisible fait disparaître le composant.** YAML invalide, champ inconnu, document vide : le kubelet journalise `Could not process manifest file` avec le chemin et l'erreur, et retire le pod de sa liste. Aucun conteneur ne tourne, `crictl ps -a` ne montre plus rien de neuf : seul `journalctl -u kubelet` donne la cause.
3. **Les copies vont hors du dossier.** Tout fichier du dossier qui ne commence pas par un point est un manifeste, quelle que soit son extension (`kube-apiserver.yaml.bak` compris) ; `.kube-apiserver.yaml` est ignoré. Sauvegarde dans `/root/` avant d'éditer.
4. **Un nouveau manifeste, un nouveau pod.** L'UID d'un pod statique est un hachage de son contenu : après modification, ses journaux vont dans un **nouveau** dossier `/var/log/pods/kube-system_<composant>-<nœud>_<nouvel-uid>/`, et le délai de redémarrage (`CrashLoopBackOff`) repart de zéro. Une correction du manifeste prend donc effet en quelques secondes, même après une longue boucle d'échecs.
5. **Les arguments sont dans `spec.containers[0].command`.** kubeadm passe toutes les options comme éléments de `command` (`- --etcd-servers=…`), une par ligne : `grep -- '--option'` les retrouve, et une faute de frappe dans un nom d'option fait sortir le composant avec `unknown flag`.
6. **Les chemins de fichiers doivent être montés.** Un certificat ou un kubeconfig n'est visible dans le conteneur que si un volume `hostPath` le monte (`volumes` et `volumeMounts` du manifeste). Changer un chemin dans une option sans changer le montage produit `no such file or directory`.
7. **Les sondes vérifient le composant.** kubeadm pose une sonde de vie (`/livez` ou `/healthz`, voir 2.4) : un composant qui n'écoute plus là où sa sonde le cherche est tué en boucle même s'il fonctionne.

#### 23.4.2 Quand l'API répond

```bash
kubectl -n kube-system get pods -o wide
kubectl -n kube-system get pods -l tier=control-plane
kubectl -n kube-system logs kube-scheduler-cka
kubectl -n kube-system logs kube-controller-manager-cka -p
kubectl -n kube-system events --for pod/kube-scheduler-cka
```

Les mirror pods portent les labels `component=<composant>` et `tier=control-plane` posés par kubeadm. Leur `STATUS` reflète l'état réel du conteneur (`CrashLoopBackOff`, `ImagePullBackOff`…), puisque le kubelet recopie le statut du pod statique dans son reflet. Pour les événements, préfère `kubectl events --for pod/<nom>`, qui filtre par nom, à `describe`.

#### 23.4.3 Quand l'API ne répond plus

`kubectl` ne sert plus à rien : il parle à l'API. Son message d'erreur oriente quand même.

| Message de kubectl | Lecture |
|---|---|
| `The connection to the server 192.168.49.2:8443 was refused - did you specify the right host or port?` | rien n'écoute à cette adresse : apiserver arrêté ou en boucle, ou mauvais port dans le kubeconfig |
| `Unable to connect to the server: dial tcp …: i/o timeout` | adresse injoignable : mauvaise IP, réseau, pare-feu |
| `Unable to connect to the server: net/http: TLS handshake timeout` ou `EOF` | l'apiserver démarre ou redémarre |
| `Error from server (InternalError)` / `etcdserver: request timed out` / `context deadline exceeded` | l'apiserver tourne mais ne joint pas etcd |
| `Unable to connect to the server: tls: failed to verify certificate: x509: certificate signed by unknown authority` | la CA du kubeconfig ne correspond pas au serveur |
| `error: You must be logged in to the server (Unauthorized)` | identifiants refusés : certificat client expiré ou d'une autre CA, jeton invalide |
| `Error from server (Forbidden): …` | authentifié mais pas autorisé : RBAC (chapitre 16) |
| `The connection to the server localhost:8080 was refused` | aucun kubeconfig trouvé (`KUBECONFIG` vide, `~/.kube/config` absent) |

Quand le message désigne l'apiserver, on se connecte au control plane et on travaille avec le runtime :

```bash
minikube -p cka ssh                                         # à l'examen : ssh <control-plane>, sudo -i
sudo crictl ps -a --name kube-apiserver                     # état, ATTEMPT qui grimpe ?
sudo crictl logs --tail 20 $(sudo crictl ps -a --name kube-apiserver -q | head -1)
sudo ls -t /var/log/pods/ | grep kube-apiserver             # le dossier le plus récent d'abord
sudo journalctl -u kubelet --since "5 min ago" --no-pager | grep -iE 'apiserver|manifest' | tail
curl -sk https://localhost:8443/readyz?verbose              # 6443 à l'examen
sudo crictl ps -a --name etcd && sudo crictl logs --tail 20 $(sudo crictl ps -a --name etcd -q | head -1)
```

`crictl ps -a --name …` liste aussi les conteneurs terminés, du plus récent au plus ancien ; `-q` ne garde que les identifiants, d'où le `head -1` pour le dernier. Si `crictl` ne montre aucun conteneur récent pour l'apiserver, le kubelet n'a pas pu lire le manifeste (23.4.1, point 2) : `journalctl` le dira. Les chemins `/livez`, `/readyz` et `/healthz` de l'apiserver sont lisibles sans authentification (rôle `system:public-info-viewer`) : un `curl -k` qui répond `readyz check passed` prouve que l'API est saine et que le problème est dans le kubeconfig ou sur le chemin réseau.

> [!tip] Réflexe d'examen
> Avant de modifier un manifeste du control plane : copie-le dans `/root/`. Après : surveille `watch crictl ps` (ou relance `crictl ps -a --name …`) jusqu'à voir le conteneur `Running` avec un `ATTEMPT` qui ne bouge plus, puis seulement `kubectl get nodes`. Une minute d'attente est normale ; modifier à nouveau le fichier pendant ce temps relance tout.

> [!info] minikube ≠ examen
> Sur le lab, `minikube -p cka status` résume l'état vu de l'hôte : une ligne `apiserver: Stopped` sur le nœud `cka` confirme d'emblée que l'API est tombée. L'outil n'existe évidemment pas à l'examen, où l'on passe directement par `ssh` et `crictl`. `kubectl debug node/…` ne remplace pas SSH dans ce cas : il crée un pod, donc il a besoin de l'API.

#### 23.4.4 kube-apiserver

Les causes de panne de l'apiserver se rangent en quatre familles, que son journal distingue facilement.

| Famille | Symptôme dans le journal | Exemple |
|---|---|---|
| option invalide | `Error: unknown flag: --…`, sortie immédiate | faute de frappe dans un nom d'option |
| fichier introuvable | `open /var/lib/minikube/certs/….crt: no such file or directory` | chemin de certificat faux ou volume non monté |
| etcd injoignable | `grpc: addrConn.createTransport failed to connect to {Addr: "…"}`, puis sortie après ~20 s (`context deadline exceeded`) | mauvaise URL, mauvais port, certificat client etcd faux |
| adresse ou port | `bind: address already in use`, ou sonde de vie qui échoue | `--secure-port` modifié sans la sonde, `--advertise-address` étrangère au nœud |

L'apiserver attend jusqu'à 20 s que sa connexion à etcd soit prête avant d'abandonner : un etcd injoignable donne donc un conteneur qui vit une vingtaine de secondes, sort, et recommence avec un délai croissant. Les options etcd à vérifier sont `--etcd-servers` (le port **client**, 2379), `--etcd-cafile`, `--etcd-certfile` et `--etcd-keyfile` ; elles se comparent à `--listen-client-urls` et aux certificats du manifeste d'etcd.

#### 23.4.5 kube-scheduler

Sans scheduler, les pods existants tournent normalement ; seuls les nouveaux pods restent `Pending`, avec `NODE <none>` et **aucun événement** (l'événement `FailedScheduling` est écrit par le scheduler lui-même). Un pod qui précise `nodeName` passe outre et démarre : c'est d'ailleurs un contournement d'urgence. On vérifie le mirror pod `kube-scheduler-<nœud>`, son journal, et dans le manifeste l'image, `--kubeconfig=/etc/kubernetes/scheduler.conf` et son montage. Sur un control plane kubeadm à plusieurs nœuds, un scheduler cassé qui n'est pas leader ne produit aucun symptôme (Lease `kube-system/kube-scheduler`) ; le lab, avec `--leader-elect=false` et un seul control plane, rend chaque panne visible.

#### 23.4.6 kube-controller-manager

Le controller-manager héberge des dizaines de boucles de réconciliation. Quand il s'arrête, rien ne casse brutalement ; tout ce qui demande une **convergence** se fige :

| Ce qu'on fait | Ce qui ne se passe plus |
|---|---|
| `kubectl scale`, `kubectl set image`, création d'un Deployment | ReplicaSet non créé ou non ajusté, aucun pod nouveau |
| suppression d'un pod d'un ReplicaSet | pas de remplaçant |
| création d'un Job, d'un CronJob | aucun pod |
| un pod devient prêt ou disparaît | EndpointSlices figées |
| un nœud s'éteint | jamais déclaré `NotReady`, pas d'éviction |
| suppression d'un namespace, d'un propriétaire | namespace bloqué en `Terminating`, pas de ramasse-miettes |
| CSR d'un kubelet, jeton de ServiceAccount | ni approbation ni signature |

Le Deployment montre alors un écart caractéristique : `spec.replicas` change, mais ni `status` ni le ReplicaSet ne suivent (`READY 3/4` avec un ReplicaSet `DESIRED 3`). Les options à vérifier dans le manifeste : `--kubeconfig`, `--authentication-kubeconfig` et `--authorization-kubeconfig` (toutes trois sur `/etc/kubernetes/controller-manager.conf`), les fichiers de signature `--cluster-signing-cert-file` et `--cluster-signing-key-file`, `--service-account-private-key-file`, `--root-ca-file`, et les montages correspondants.

#### 23.4.7 etcd

Un etcd arrêté emporte l'apiserver avec lui : le diagnostic part donc souvent d'une API muette dont le journal parle d'etcd. On lit alors le conteneur etcd avec `crictl` comme en 23.4.3, et on cherche dans son journal les causes habituelles : certificats introuvables, `--data-dir` ou volume `etcd-data` qui pointe vers un dossier vide ou corrompu (après une restauration manquée, chapitre 20), adresse d'écoute étrangère au nœud (`bind: cannot assign requested address`), disque plein, alarme `NOSPACE` (`mvcc: database space exceeded`). Quand etcd tourne, `etcdctl endpoint health` et `endpoint status` (avec les options TLS de 20.4) confirment sa santé. Rappel : l'image d'etcd est *distroless*, sans shell ; on ne peut pas y entrer par `kubectl exec … -- sh`, mais `kubectl -n kube-system exec etcd-cka -- etcdctl …` fonctionne tant que l'API répond.

### 23.5 CoreDNS

CoreDNS est un Deployment de `kube-system` (`k8s-app=kube-dns`), exposé par le Service `kube-dns` (10.96.0.10) et configuré par la ConfigMap `coredns`, montée en `/etc/coredns/Corefile`. Une panne de CoreDNS touche tout le cluster : chaque pod résout par lui.

```bash
kubectl -n kube-system get deploy,pods -l k8s-app=kube-dns
kubectl -n kube-system get endpointslices -l kubernetes.io/service-name=kube-dns
kubectl -n kube-system logs deploy/coredns --tail=20
kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'
```

Trois comportements surprennent. Le plugin **`reload`** relit le Corefile quand la ConfigMap change (avec le délai de propagation des volumes ConfigMap, de l'ordre de la minute) ; si la nouvelle configuration est invalide, CoreDNS **garde l'ancienne** et journalise l'erreur : une ConfigMap fausse ne casse rien… jusqu'au prochain redémarrage des pods, qui ne démarrent plus. Une directive inconnue fait sortir CoreDNS dès le démarrage avec `Corefile:<ligne> - Error during parsing: Unknown directive '<mot>'`. Le plugin **`loop`** arrête CoreDNS quand il détecte une boucle de transfert (typiquement un `forward . /etc/resolv.conf` dont le `resolv.conf` du nœud pointe vers une adresse locale), avec un message `Loop (…) detected`. Enfin, l'adresse du DNS que reçoivent les pods vient de `clusterDNS` dans la configuration du kubelet : un nœud dont `clusterDNS` est faux donne des pods qui interrogent la mauvaise adresse, alors que CoreDNS est sain.

Quand CoreDNS est en échec, le Service `kube-dns` n'a plus d'endpoint prêt : kube-proxy y rejette le trafic (réponse immédiate « connection refused » pour un client à sortie libre), et un pod dont les NetworkPolicies n'autorisent que les pods CoreDNS n'obtient qu'un silence (22.1.2).

### 23.6 kube-proxy

kube-proxy est un DaemonSet de `kube-system` (`k8s-app=kube-proxy`), en `hostNetwork`, configuré par la ConfigMap `kube-proxy` (clé `config.conf`, `KubeProxyConfiguration`). Il traduit en règles iptables (mode du lab et défaut de kubeadm 1.37, écrit explicitement) les Services et leurs EndpointSlices. Sa panne a une signature unique : **les règles déjà écrites restent dans le noyau** quand kube-proxy s'arrête. Les Services existants continuent donc de fonctionner, tant que leurs endpoints ne changent pas ; un Service créé après la panne, ou un pod qui change d'adresse, n'est pas pris en compte.

```bash
kubectl -n kube-system get ds kube-proxy
kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide
kubectl -n kube-system logs -l k8s-app=kube-proxy --tail=5 --prefix
kubectl -n kube-system get configmap kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^(mode|clusterCIDR):'
minikube -p cka ssh -n cka-m02 -- 'curl -s http://127.0.0.1:10256/healthz; echo'
minikube -p cka ssh -n cka-m02 -- 'sudo iptables-save -t nat | grep -c KUBE-SVC'
```

kube-proxy valide sa configuration au démarrage et sort en erreur si elle est fausse. En 1.37, sous Linux, le mode doit être `iptables`, `nftables`, `ipvs` (déprécié, encore accepté tant que la porte `KubeProxyIPVS` est active) ou vide ; toute autre valeur donne `failed validate: KubeProxyConfiguration.Mode: Invalid value: "…": must be iptables, ipvs, nftables or blank (blank means the best-available proxy [currently iptables])`. Comme le DaemonSet ne relit pas la ConfigMap à chaud, une modification de la ConfigMap n'a d'effet qu'au redémarrage des pods : `kubectl -n kube-system rollout restart daemonset kube-proxy`. C'est vrai pour une réparation comme pour une panne.

### 23.7 kubeconfig et accès à l'API

`kubectl` lit sa configuration dans l'ordre : option `--kubeconfig`, variable `KUBECONFIG` (une liste de fichiers fusionnés), puis `~/.kube/config`. Le contexte courant désigne un cluster (adresse et CA du serveur) et un utilisateur (certificat client ou jeton). Les messages du tableau de 23.4.3 désignent l'élément fautif.

```bash
kubectl config current-context
kubectl config get-contexts
kubectl config view --minify                                  # le contexte courant seul, secrets masqués
kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}{"\n"}'
kubectl cluster-info
kubectl config set-cluster cka --server=https://192.168.49.2:8443
kubectl config use-context cka
```

Sur un control plane kubeadm, `/etc/kubernetes/admin.conf` est le kubeconfig d'administration de secours : `kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes`, en root. Son serveur est `controlPlaneEndpoint` ; ses certificats expirent avec ceux du cluster (un an), et `kubeadm certs renew admin.conf` le régénère (chapitre 19). Ne prends pas l'habitude de `super-admin.conf`, qui contourne RBAC.

> [!info] minikube ≠ examen
> minikube écrit le contexte `cka` dans `~/.kube/config`, avec le serveur `https://<IP du nœud cka>:8443` et des certificats référencés par chemin dans le dossier de minikube. Si l'adresse ou le port du kubeconfig ne correspond plus (après une modification, ou un nouveau réseau Docker), `minikube -p cka update-context` le réécrit. Dans le nœud, `kubectl` n'est pas dans le `PATH` : `sudo /var/lib/minikube/binaries/v1.37.0/kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes`.

### 23.8 Les certificats du control plane

Un certificat expiré produit des symptômes en cascade : l'apiserver refuse les clients (`Unauthorized`), le controller-manager et le scheduler ne s'authentifient plus, ou l'apiserver ne joint plus etcd (`x509: certificate has expired`). La vérification et le renouvellement sont au [chapitre 19](19-kubeadm-installation-ha-et-mises-a-jour.md) (19.7) : `kubeadm certs check-expiration`, `kubeadm certs renew all`, puis redémarrage des pods statiques du control plane (sortir leurs manifestes du dossier une vingtaine de secondes, ou `crictl stop`). Pour un fichier précis : `sudo openssl x509 -noout -subject -issuer -enddate -in <fichier>`. Sur le lab, les certificats sont sous `/var/lib/minikube/certs` et `kubeadm certs check-expiration` exige `--config /var/tmp/minikube/kubeadm.yaml`.

### 23.9 Pièges courants

```
Piège 1 : Laisser une sauvegarde dans /etc/kubernetes/manifests
════════════════════════════════════════════════════════════════
  MAUVAIS  : sudo cp kube-apiserver.yaml kube-apiserver.yaml.bak   (dans manifests/)
  SYMPTÔME : deux pods statiques du même nom ; l'ancienne version peut l'emporter.
  BON      : sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/

Piège 2 : Chercher les journaux d'un apiserver mort avec kubectl
════════════════════════════════════════════════════════════════
  SYMPTÔME : « connection refused », rien à lire.
  BON      : ssh au control plane, crictl ps -a, crictl logs, /var/log/pods,
             journalctl -u kubelet.

Piège 3 : Confondre les ports d'etcd
════════════════════════════════════
  MAUVAIS  : --etcd-servers=https://127.0.0.1:2380
  CAUSE    : 2380 est le port des pairs (Raft), 2379 celui des clients.
  BON      : comparer avec --listen-client-urls du manifeste d'etcd.

Piège 4 : Démarrer un service sans l'activer
════════════════════════════════════════════
  MAUVAIS  : systemctl start kubelet      (il était disabled)
  SYMPTÔME : la panne revient au prochain redémarrage du nœud.
  BON      : systemctl enable --now kubelet

Piège 5 : Modifier l'unité du kubelet sans daemon-reload
═══════════════════════════════════════════════════════
  SYMPTÔME : la modification est ignorée ; systemd l'annonce par
             « unit file … changed on disk. Run 'systemctl daemon-reload' ».
  BON      : systemctl daemon-reload && systemctl restart kubelet

Piège 6 : Corriger une ConfigMap de kube-system sans redémarrer les pods
════════════════════════════════════════════════════════════════════════
  SYMPTÔME : kube-proxy reste en boucle ; CoreDNS en CrashLoopBackOff attend
             son prochain essai (jusqu'à 5 min).
  BON      : kubectl -n kube-system rollout restart daemonset kube-proxy
             (ou deployment coredns)

Piège 7 : Oublier que le contrôleur des nœuds vit dans le controller-manager
═════════════════════════════════════════════════════════════════════════════
  SYMPTÔME : un nœud éteint reste « Ready ».
  BON      : vérifier kube-controller-manager avant de se fier aux états.

Piège 8 : Relancer kubectl en boucle pendant que l'apiserver redémarre
══════════════════════════════════════════════════════════════════════
  BON      : surveiller crictl ps sur le nœud ; attendre un conteneur Running
             dont ATTEMPT ne bouge plus.
```

> [!summary] À retenir
> - Un nœud passe `NotReady` (`Ready=Unknown`, taints `unreachable`) quand ni sa Lease (renouvelée toutes les 10 s) ni son statut n'ont bougé depuis 50 s (`--node-monitor-grace-period`) ; ses pods sont évincés 300 s plus tard, sauf DaemonSets, et un pod de StatefulSet reste `Terminating`.
> - `Ready=Unknown` désigne le kubelet ou le réseau vers l'API ; `Ready=False` désigne le runtime, le CNI ou le PLEG, avec le message de la condition.
> - Sur le nœud : `systemctl status kubelet`, `journalctl -u kubelet`, `systemctl status containerd`, `crictl ps` ; `enable --now` pour un service désactivé, `daemon-reload` après toute modification d'unité.
> - Le control plane est fait de pods statiques : on répare le manifeste, copie de sauvegarde hors du dossier ; un manifeste illisible fait disparaître le composant (`Could not process manifest file`).
> - API muette : `crictl ps -a --name`, `crictl logs`, `/var/log/pods` (nouveau dossier à chaque modification du manifeste), `curl -k …/readyz`.
> - Scheduler absent : pods `Pending` sans événement. Controller-manager absent : rien ne converge, même pas l'état des nœuds. etcd : port client 2379, pair 2380.
> - CoreDNS et kube-proxy se configurent par ConfigMap et ne relisent qu'au redémarrage (sauf `reload` de CoreDNS, qui garde l'ancienne configuration si la nouvelle est fausse) ; sans kube-proxy, les anciennes règles restent, les nouveaux Services ne marchent pas.
> - kubeconfig : `config view --minify`, `set-cluster --server`, port 6443 à l'examen et 8443 sur le lab (`minikube -p cka update-context`).

### 23.10 Exercices

Les exercices 23.1 à 23.9 reprennent les pannes 11 à 19. Chacune s'injecte depuis l'instantané I4, ou depuis l'état laissé par la panne précédente une fois réparée et vérifiée, par `lab/pannes.sh casser NN` lancé depuis le dossier du cours ; on contrôle la réparation par `lab/pannes.sh verifier NN`. Ces pannes touchent le control plane : une réparation ratée se rattrape par `lab/restaurer.sh I4`. Les exercices 23.10 à 23.12 se font sans script.

#### Exercice 23.1 — Panne 11 : les nouveaux pods ne démarrent plus

**Point de départ** : instantané I4.

Lance `lab/pannes.sh casser 11`. Les pods existants tournent, mais tout nouveau pod reste `Pending`. Crée dans `default` un pod de test `essai-planif` (busybox 1.37.0, `sleep 600`) pour le constater, trouve la cause et répare. Supprime le pod de test à la fin.

> [!example]- Solution
> ```bash
> kubectl -n default run essai-planif --image=busybox:1.37.0 --restart=Never -- sleep 600
> kubectl -n default get pod essai-planif -o wide
> kubectl -n default events --for pod/essai-planif
> ```
>
> ```
> NAME           READY   STATUS    RESTARTS   AGE   IP       NODE     NOMINATED NODE   READINESS GATES
> essai-planif   0/1     Pending   0          35s   <none>   <none>   <none>           <none>
> No events found in default namespace.
> ```
>
> `Pending` sans nœud **et** sans événement : personne n'a essayé de placer le pod. C'est le scheduler qu'il faut regarder.
>
> ```bash
> kubectl -n kube-system get pods -l component=kube-scheduler
> kubectl -n kube-system events --for pod/kube-scheduler-cka --types=Warning
> ```
>
> ```
> NAME                 READY   STATUS             RESTARTS   AGE
> kube-scheduler-cka   0/1     ImagePullBackOff   0          3m
>
> LAST SEEN   TYPE      REASON   OBJECT                   MESSAGE
> 2m          Warning   Failed   Pod/kube-scheduler-cka   Failed to pull image "registry.k8s.io/kube-scheduler:v1.37.99": rpc error: code = NotFound desc = failed to pull and unpack image "registry.k8s.io/kube-scheduler:v1.37.99": failed to resolve reference "registry.k8s.io/kube-scheduler:v1.37.99": registry.k8s.io/kube-scheduler:v1.37.99: not found
> ```
>
> L'étiquette `v1.37.99` n'existe pas. Le manifeste se corrige sur le nœud, après une copie de sauvegarde **hors** du dossier :
>
> ```bash
> minikube -p cka ssh
> sudo grep -h 'image:' /etc/kubernetes/manifests/*.yaml
> sudo cp /etc/kubernetes/manifests/kube-scheduler.yaml /root/kube-scheduler.yaml.avant
> sudo sed -i 's#kube-scheduler:v1.37.99#kube-scheduler:v1.37.0#' /etc/kubernetes/manifests/kube-scheduler.yaml
> sudo crictl ps --name kube-scheduler
> exit
> kubectl -n default get pod essai-planif -o wide
> kubectl -n default delete pod essai-planif
> ```
>
> La comparaison des images des quatre manifestes montre que tous les autres composants sont en `v1.37.0` ; l'image est déjà présente sur le nœud (`sudo crictl images | grep scheduler`), le conteneur démarre en quelques secondes, et le pod de test est placé aussitôt : le scheduler reprend la file des pods en attente.
>
> **Vérification** : `kubectl -n kube-system get pods -l component=kube-scheduler` montre `1/1 Running`, `sudo ls /etc/kubernetes/manifests` dans le nœud ne liste que les quatre manifestes, et `lab/pannes.sh verifier 11` réussit.

#### Exercice 23.2 — Panne 12 : un scale sans effet

**Point de départ** : exercice 23.1, ou instantané I4.

Lance `lab/pannes.sh casser 12`. On signale que `kubectl -n boutique scale deployment front --replicas=4` ne crée aucun pod. Reproduis, trouve la cause, répare, puis ramène `front` à 3 réplicas.

> [!example]- Solution
> ```bash
> kubectl -n boutique scale deployment front --replicas=4
> sleep 15
> kubectl -n boutique get deploy front
> kubectl -n boutique get rs -l app=front
> ```
>
> ```
> NAME    READY   UP-TO-DATE   AVAILABLE   AGE
> front   3/4     3            3           5h
> NAME               DESIRED   CURRENT   READY   AGE
> front-5b7f9c6d48   0         0         0       2h
> front-7c6d9b8f5d   3         3         3       5h
> ```
>
> Le Deployment veut 4 réplicas, mais son ReplicaSet en vise toujours 3 : le contrôleur de Deployment n'a pas propagé le changement. Tous les contrôleurs vivent dans kube-controller-manager :
>
> ```bash
> kubectl -n kube-system get pods -l component=kube-controller-manager
> kubectl -n kube-system logs kube-controller-manager-cka -p | tail -1
> ```
>
> ```
> NAME                          READY   STATUS             RESTARTS      AGE
> kube-controller-manager-cka   0/1     CrashLoopBackOff   5 (40s ago)   4m
> E1023 20:14:03.402118       1 run.go:72] "command failed" err="stat /etc/kubernetes/controleur-manager.conf: no such file or directory"
> ```
>
> Le composant ne trouve pas son kubeconfig. On compare, dans le manifeste, les trois options de kubeconfig et le volume monté :
>
> ```bash
> minikube -p cka ssh
> sudo grep -n -E 'kubeconfig|controller-manager.conf|controleur' /etc/kubernetes/manifests/kube-controller-manager.yaml
> ```
>
> ```
> 17:    - --authentication-kubeconfig=/etc/kubernetes/controller-manager.conf
> 18:    - --authorization-kubeconfig=/etc/kubernetes/controller-manager.conf
> 25:    - --kubeconfig=/etc/kubernetes/controleur-manager.conf
> …
> 82:    - mountPath: /etc/kubernetes/controller-manager.conf
> 83:      name: kubeconfig
> …
> 112:      path: /etc/kubernetes/controller-manager.conf
> 114:    name: kubeconfig
> ```
>
> (Les numéros de ligne varient d'une installation à l'autre.) Les options d'authentification et le volume `hostPath` désignent `controller-manager.conf`, le seul fichier monté dans le conteneur ; `--kubeconfig` vise un nom mal orthographié.
>
> ```bash
> sudo cp /etc/kubernetes/manifests/kube-controller-manager.yaml /root/kcm.yaml.avant
> sudo sed -i 's#--kubeconfig=/etc/kubernetes/controleur-manager.conf#--kubeconfig=/etc/kubernetes/controller-manager.conf#' /etc/kubernetes/manifests/kube-controller-manager.yaml
> sudo crictl ps --name kube-controller-manager
> exit
> kubectl -n boutique get deploy front
> kubectl -n boutique scale deployment front --replicas=3
> ```
>
> Dès son redémarrage, le controller-manager rattrape tout le travail en attente : le quatrième pod `front` apparaît, puis disparaît au retour à 3.
>
> **Vérification** : `kubectl -n boutique get deploy front` affiche `3/3`, le pod `kube-controller-manager-cka` est `1/1 Running`, et `lab/pannes.sh verifier 12` réussit.

#### Exercice 23.3 — Panne 13 : cka-m03 NotReady

**Point de départ** : exercice 23.2, ou instantané I4.

Lance `lab/pannes.sh casser 13`. Le nœud `cka-m03` passe `NotReady`. Mesure le délai, relève les conditions et les taints, trouve la cause et répare de façon durable (la réparation doit survivre à un redémarrage du nœud).

> [!example]- Solution
> ```bash
> kubectl get nodes -w            # Ctrl+C quand cka-m03 passe NotReady
> kubectl get node cka-m03 -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
> kubectl get node cka-m03 -o jsonpath='{range .spec.taints[*]}{.key}:{.effect}{"\n"}{end}'
> kubectl -n kube-node-lease get lease cka-m03 -o jsonpath='{.spec.renewTime}{"\n"}'
> ```
>
> ```
> cka-m03   NotReady   <none>   5h    v1.37.0
> MemoryPressure=Unknown NodeStatusUnknown: Kubelet stopped posting node status.
> DiskPressure=Unknown NodeStatusUnknown: Kubelet stopped posting node status.
> PIDPressure=Unknown NodeStatusUnknown: Kubelet stopped posting node status.
> Ready=Unknown NodeStatusUnknown: Kubelet stopped posting node status.
> node.kubernetes.io/unreachable:NoSchedule
> node.kubernetes.io/unreachable:NoExecute
> ```
>
> Le passage à `NotReady` survient une cinquantaine de secondes après l'arrêt : c'est la période de grâce du contrôleur des nœuds. `Unknown` signifie que le kubelet ne donne plus de nouvelles, et sa Lease n'est plus renouvelée. On va sur le nœud :
>
> ```bash
> minikube -p cka ssh -n cka-m03
> sudo systemctl status kubelet --no-pager | head -5
> ```
>
> ```
> ○ kubelet.service - kubelet: The Kubernetes Node Agent
>      Loaded: loaded (/lib/systemd/system/kubelet.service; disabled; preset: enabled)
>     Drop-In: /etc/systemd/system/kubelet.service.d
>              └─10-kubeadm.conf
>      Active: inactive (dead) since Fri 2026-10-23 18:21:40 UTC; 3min 12s ago
> ```
>
> Le kubelet est arrêté **et** désactivé (`disabled` sur un worker, alors qu'il y est normalement `enabled`). Un simple `start` réparerait jusqu'au prochain redémarrage du nœud ; `enable --now` répare les deux :
>
> ```bash
> sudo systemctl enable --now kubelet
> systemctl is-enabled kubelet; systemctl is-active kubelet
> exit
> kubectl get node cka-m03
> ```
>
> Le nœud repasse `Ready` en une seconde et les taints `unreachable` disparaissent. Si plus de cinq minutes se sont écoulées, les pods du nœud ont été évincés : ceux des Deployments tournent ailleurs, `redis-0` est resté `Terminating` puis a été recréé sur `cka-m03` au retour du kubelet, et un pod nu comme `outils`, s'il était sur ce nœud, a disparu (`lab/etats/04-pods/appliquer.sh` le recrée).
>
> **Vérification** : `kubectl get node cka-m03` affiche `Ready`, et `lab/pannes.sh verifier 13` réussit.

#### Exercice 23.4 — Panne 14 : cka-m02 NotReady

**Point de départ** : exercice 23.3, ou instantané I4.

Lance `lab/pannes.sh casser 14`. Le nœud `cka-m02` passe `NotReady`. Trouve la cause et répare.

> [!example]- Solution
> ```bash
> kubectl get nodes
> minikube -p cka ssh -n cka-m02
> sudo systemctl status kubelet --no-pager | sed -n 3,7p
> ```
>
> ```
>      Active: activating (auto-restart) (Result: exit-code) since Fri 2026-10-23 18:40:02 UTC; 312ms ago
>     Process: 48211 ExecStart=/var/lib/minikube/binaries/v1.37.0/kubelet --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --config=/var/lib/kubelet/config.yaml --hostname-override=cka-m02 --kubeconfig=/etc/kubernetes/kubelet.conf --node-ip=192.168.49.3 (code=exited, status=1/FAILURE)
>    Main PID: 48211 (code=exited, status=1/FAILURE)
> ```
>
> Cette fois le kubelet est activé, mais il sort aussitôt avec le code 1, et systemd le relance toutes les 600 ms. La cause est dans son journal :
>
> ```bash
> sudo journalctl -u kubelet -n 100 --no-pager | grep 'command failed' | tail -1
> ```
>
> ```
> Oct 23 18:40:02 cka-m02 kubelet[48211]: E1023 18:40:02.716493   48211 run.go:72] "command failed" err="failed to run Kubelet: open /var/lib/minikube/certs/ca-client.crt: no such file or directory"
> ```
>
> Le kubelet doit charger la CA qui authentifie les clients de son API (l'apiserver, pour `logs` et `exec`). Le fichier attendu n'existe pas ; on cherche qui le référence et ce qui existe réellement :
>
> ```bash
> sudo grep -n clientCAFile /var/lib/kubelet/config.yaml
> sudo ls /var/lib/minikube/certs/
> exit
> minikube -p cka ssh -n cka-m03 -- sudo grep clientCAFile /var/lib/kubelet/config.yaml
> ```
>
> ```
> 9:    clientCAFile: /var/lib/minikube/certs/ca-client.crt
> ca.crt  ca.key  proxy-client-ca.crt  proxy-client-ca.key
>     clientCAFile: /var/lib/minikube/certs/ca.crt
> ```
>
> Le nœud voisin, sain, utilise `ca.crt`, qui est bien présent. (Sur un nœud kubeadm, ce serait `/etc/kubernetes/pki/ca.crt`.)
>
> ```bash
> minikube -p cka ssh -n cka-m02
> sudo cp /var/lib/kubelet/config.yaml /root/config.yaml.avant
> sudo sed -i 's#clientCAFile: /var/lib/minikube/certs/ca-client.crt#clientCAFile: /var/lib/minikube/certs/ca.crt#' /var/lib/kubelet/config.yaml
> sudo systemctl restart kubelet
> sudo systemctl is-active kubelet
> exit
> kubectl get node cka-m02
> ```
>
> Une modification de `config.yaml` n'exige qu'un redémarrage du service, pas de `daemon-reload`.
>
> **Vérification** : `kubectl get node cka-m02` affiche `Ready`, et `lab/pannes.sh verifier 14` réussit.

#### Exercice 23.5 — Panne 15 : l'API ne répond plus

**Point de départ** : exercice 23.4, ou instantané I4.

Lance `lab/pannes.sh casser 15`. Une dizaine de secondes plus tard, `kubectl` n'obtient plus de réponse de l'API. Diagnostique sans `kubectl` et répare.

> [!example]- Solution
> ```bash
> kubectl get nodes
> minikube -p cka status
> ```
>
> ```
> The connection to the server 192.168.49.2:8443 was refused - did you specify the right host or port?
> cka
> type: Control Plane
> host: Running
> kubelet: Running
> apiserver: Stopped
> kubeconfig: Configured
> …
> ```
>
> Le port est le bon (8443) et refuse la connexion : l'apiserver n'écoute plus. On passe sur le nœud :
>
> ```bash
> minikube -p cka ssh
> sudo crictl ps -a --name kube-apiserver
> ```
>
> ```
> CONTAINER       IMAGE           CREATED          STATE    NAME             ATTEMPT   POD ID          POD                  NAMESPACE
> 5f0c2a1b9d3e7   6b1e8d2c4a9f0   31 seconds ago   Exited   kube-apiserver   3         c2d9e4f1a7b38   kube-apiserver-cka   kube-system
> ```
>
> Le conteneur sort et recommence (`ATTEMPT` 3). Son journal, lu directement auprès du runtime :
>
> ```bash
> sudo crictl logs --tail 4 $(sudo crictl ps -a --name kube-apiserver -q | head -1)
> ```
>
> ```
> W1023 18:52:31.481203       1 logging.go:55] [core] [Channel #3 SubChannel #5]grpc: addrConn.createTransport failed to connect to {Addr: "127.0.0.1:2380", ServerName: "127.0.0.1:2380", …}. Err: connection error: desc = "…"
> …
> E1023 18:52:43.019887       1 run.go:72] "command failed" err="… context deadline exceeded"
> ```
>
> L'apiserver essaie de joindre etcd sur `127.0.0.1:2380` pendant une vingtaine de secondes, puis abandonne. Or 2380 est le port des **pairs** d'etcd ; les clients utilisent 2379. On le confirme en comparant les deux manifestes :
>
> ```bash
> sudo grep -- '--etcd-servers' /etc/kubernetes/manifests/kube-apiserver.yaml
> sudo grep -- '--listen-client-urls' /etc/kubernetes/manifests/etcd.yaml
> sudo crictl ps --name etcd
> ```
>
> ```
>     - --etcd-servers=https://127.0.0.1:2380
>     - --listen-client-urls=https://127.0.0.1:2379,https://192.168.49.2:2379
> ```
>
> etcd lui-même tourne normalement. Les mêmes lignes se lisent sans `crictl`, dans le fichier le plus récent de `/var/log/pods/kube-system_kube-apiserver-cka_*/kube-apiserver/` (`sudo ls -t /var/log/pods | grep apiserver` donne le dossier courant), et `sudo journalctl -u kubelet | grep kube-apiserver | tail -3` montre le kubelet en attente `CrashLoopBackOff` entre deux essais.
>
> ```bash
> sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.avant
> sudo sed -i 's#--etcd-servers=https://127.0.0.1:2380#--etcd-servers=https://127.0.0.1:2379#' /etc/kubernetes/manifests/kube-apiserver.yaml
> sudo crictl ps --name kube-apiserver          # relancer jusqu'à Running, ATTEMPT stable
> curl -sk https://localhost:8443/readyz; echo
> exit
> kubectl get nodes
> ```
>
> Le manifeste modifié produit un nouveau pod statique, dont le délai de redémarrage repart de zéro : l'apiserver revient en moins d'une minute, et `readyz` répond `ok`.
>
> **Vérification** : `kubectl get --raw /readyz` affiche `ok`, et `lab/pannes.sh verifier 15` réussit (il contrôle aussi qu'aucune copie n'est restée dans le dossier des manifestes).

#### Exercice 23.6 — Panne 16 : plus aucune résolution DNS

**Point de départ** : exercice 23.5, ou instantané I4.

Lance `lab/pannes.sh casser 16`. Plus aucune résolution DNS ne fonctionne dans le cluster, y compris depuis `outils`. Trouve la cause et répare sans perdre les entrées `boutique.example` ajoutées au chapitre 11.

> [!example]- Solution
> ```bash
> kubectl -n boutique exec outils -- dig +time=2 +tries=1 api.boutique.svc.cluster.local | head -1
> kubectl -n kube-system get pods -l k8s-app=kube-dns
> ```
>
> ```
> ;; communications error to 10.96.0.10#53: connection refused
> NAME                       READY   STATUS             RESTARTS      AGE
> coredns-7d4c9b8f6d-4mzq8   0/1     CrashLoopBackOff   3 (30s ago)   90s
> coredns-7d4c9b8f6d-r7wkd   0/1     CrashLoopBackOff   3 (28s ago)   90s
> ```
>
> Depuis `outils`, la requête est refusée tout de suite : le Service `kube-dns` n'a plus d'endpoint prêt, et kube-proxy rejette le trafic. Les deux pods CoreDNS bouclent :
>
> ```bash
> kubectl -n kube-system logs deploy/coredns -p
> kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | grep -n -E 'foward|forward'
> ```
>
> ```
> /etc/coredns/Corefile:… - Error during parsing: Unknown directive 'foward'
> …:    foward . /etc/resolv.conf {
> ```
>
> La directive `forward` est mal orthographiée. Les pods existants auraient gardé l'ancienne configuration grâce au plugin `reload`, mais ils ont été recréés, et CoreDNS refuse de démarrer sur un Corefile invalide. On corrige la ConfigMap sans toucher au reste (le bloc `hosts` avec `boutique.example`), puis on redémarre les pods plutôt que d'attendre leur prochain essai :
>
> ```bash
> kubectl -n kube-system get configmap coredns -o yaml | sed 's/ foward \./ forward ./' | kubectl replace -f -
> kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' | grep -E 'forward|boutique'
> kubectl -n kube-system rollout restart deployment coredns
> kubectl -n kube-system rollout status deployment coredns --timeout=120s
> kubectl -n boutique exec outils -- dig +short api.boutique.svc.cluster.local boutique.example
> ```
>
> `kubectl -n kube-system edit configmap coredns` conviendrait aussi ; le tube `get | sed | replace` a l'avantage d'être rejouable et de ne changer que le mot fautif.
>
> **Vérification** : `dig` renvoie l'IP du Service `api` puis celle du nœud `cka`, `kubectl -n kube-system get deploy coredns` affiche `2/2`, et `lab/pannes.sh verifier 16` réussit.

#### Exercice 23.7 — Panne 17 : un Service neuf injoignable

**Point de départ** : exercice 23.6, ou instantané I4.

Lance `lab/pannes.sh casser 17`. Les Services existants répondent, mais un Service créé maintenant reste injoignable. Crée pour le constater le Service ClusterIP `essai-proxy` dans `boutique` (port 8080, sélecteur `app=api`), trouve la cause, répare, puis supprime `essai-proxy`.

> [!example]- Solution
> ```bash
> kubectl -n boutique create service clusterip essai-proxy --tcp=8080:8080
> kubectl -n boutique set selector service essai-proxy app=api
> kubectl -n boutique get endpointslices -l kubernetes.io/service-name=essai-proxy
> kubectl -n boutique exec outils -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://api:8080/hostname
> kubectl -n boutique exec outils -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://essai-proxy:8080/hostname
> ```
>
> ```
> NAME                ADDRESSTYPE   PORTS   ENDPOINTS                      AGE
> essai-proxy-8vq4d   IPv4          8080    10.244.195.201,10.244.34.137   6s
> 200
> 000
> command terminated with exit code 28
> ```
>
> Le nouveau Service a ses endpoints (le controller-manager fait son travail) et son nom se résout, mais son IP ne mène nulle part, alors que l'ancien Service `api`, vers les mêmes pods, répond. C'est la signature d'un kube-proxy hors service : les règles écrites avant la panne restent dans le noyau, aucune nouvelle n'est ajoutée.
>
> ```bash
> kubectl -n kube-system get pods -l k8s-app=kube-proxy
> kubectl -n kube-system logs $(kubectl -n kube-system get pods -l k8s-app=kube-proxy -o name | head -1) -p
> minikube -p cka ssh -n cka-m02 -- 'sudo iptables-save -t nat | grep -c essai-proxy'
> ```
>
> ```
> NAME               READY   STATUS             RESTARTS      AGE
> kube-proxy-5kq8w   0/1     CrashLoopBackOff   4 (45s ago)   2m
> kube-proxy-n2x7c   0/1     CrashLoopBackOff   4 (41s ago)   2m
> kube-proxy-v9d4t   0/1     CrashLoopBackOff   4 (44s ago)   2m
> E1023 19:07:15.118734       1 run.go:72] "command failed" err="failed validate: KubeProxyConfiguration.Mode: Invalid value: \"iptable\": must be iptables, ipvs, nftables or blank (blank means the best-available proxy [currently iptables])"
> 0
> ```
>
> Le mode configuré, `iptable`, n'existe pas. On corrige la ConfigMap, puis on redémarre le DaemonSet, qui ne relit pas sa configuration à chaud :
>
> ```bash
> kubectl -n kube-system get configmap kube-proxy -o yaml | sed 's/^\( *\)mode: iptable$/\1mode: iptables/' | kubectl replace -f -
> kubectl -n kube-system rollout restart daemonset kube-proxy
> kubectl -n kube-system rollout status daemonset kube-proxy --timeout=120s
> kubectl -n boutique exec outils -- curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 http://essai-proxy:8080/hostname
> kubectl -n boutique delete service essai-proxy
> ```
>
> Au démarrage, kube-proxy resynchronise toutes les règles : `essai-proxy` répond `200`.
>
> **Vérification** : `kubectl -n kube-system get ds kube-proxy` affiche 3 pods prêts, et `lab/pannes.sh verifier 17` réussit.

#### Exercice 23.8 — Panne 18 : cka-m02 vidé de ses pods

**Point de départ** : exercice 23.7, ou instantané I4.

Lance `lab/pannes.sh casser 18`. Plus aucun pod applicatif ne tourne sur `cka-m02`, et aucun nouveau pod n'y est placé, alors que le nœud est `Ready`. Trouve pourquoi, rends le nœud pleinement utilisable, et assure-toi que le pod `outils` existe toujours.

> [!example]- Solution
> ```bash
> kubectl get nodes
> kubectl get pods -A -o wide --field-selector spec.nodeName=cka-m02
> kubectl describe node cka-m02 | grep -A2 -E '^Taints|^Unschedulable'
> ```
>
> ```
> NAME      STATUS                     ROLES           AGE   VERSION
> cka       Ready                      control-plane   6h    v1.37.0
> cka-m02   Ready,SchedulingDisabled   <none>          6h    v1.37.0
> cka-m03   Ready                      <none>          6h    v1.37.0
>
> NAMESPACE     NAME                READY   STATUS    RESTARTS   AGE   IP             NODE      …
> boutique      agent-noeud-7xk2p   1/1     Running   0          6h    10.244.195.194 cka-m02   …
> kube-system   calico-node-hw89l   1/1     Running   0          6h    192.168.49.3   cka-m02   …
> kube-system   kube-proxy-n2x7c    1/1     Running   0          20m   192.168.49.3   cka-m02   …
> …
>
> Taints:             maintenance=oui:NoExecute
>                     node.kubernetes.io/unschedulable:NoSchedule
> Unschedulable:      true
> ```
>
> Deux mécanismes se cumulent. Le nœud est **cordonné** (`SchedulingDisabled`, taint `unschedulable:NoSchedule`) : plus rien n'y est placé. Il porte aussi une taint **`NoExecute`** posée à la main, `maintenance=oui`, qui a évincé tous les pods qui ne la tolèrent pas ; seuls restent les pods de DaemonSet qui tolèrent tout (`operator: Exists`). Les événements gardent la trace des évictions pendant une heure :
>
> ```bash
> kubectl -n boutique events | grep TaintManagerEviction
> ```
>
> Les pods des Deployments ont été recréés ailleurs ; cette éviction par taint n'a pas consulté le PodDisruptionBudget de `front`. On lève les deux mécanismes, puis on vérifie `outils`, un pod nu que personne ne recrée :
>
> ```bash
> kubectl taint node cka-m02 maintenance=oui:NoExecute-
> kubectl uncordon cka-m02
> kubectl -n boutique get pod outils
> # s'il est absent (il tournait sur cka-m02) : lab/etats/04-pods/appliquer.sh
> ```
>
> Les pods évincés ne reviennent pas d'eux-mêmes sur `cka-m02` : Kubernetes ne rééquilibre pas. Les prochains pods créés, eux, pourront y aller.
>
> **Vérification** : `kubectl get node cka-m02` affiche `Ready` sans `SchedulingDisabled`, `kubectl get node cka-m02 -o jsonpath='{.spec.taints}'` est vide, `kubectl -n boutique get pod outils` montre `Running`, et `lab/pannes.sh verifier 18` réussit.

#### Exercice 23.9 — Panne 19 : connection refused

**Point de départ** : exercice 23.8, ou instantané I4.

Lance `lab/pannes.sh casser 19`. `kubectl` échoue avec « connection refused ». Trouve la cause et répare, sans toucher au cluster.

> [!example]- Solution
> ```bash
> kubectl get nodes
> kubectl config current-context
> kubectl config view --minify -o jsonpath='{.clusters[0].name} {.clusters[0].cluster.server}{"\n"}'
> minikube -p cka ip
> minikube -p cka ssh -- 'curl -sk https://localhost:8443/readyz; echo'
> ```
>
> ```
> The connection to the server 192.168.49.2:6443 was refused - did you specify the right host or port?
> cka
> cka https://192.168.49.2:6443
> 192.168.49.2
> ok
> ```
>
> L'API est saine (`readyz` répond `ok` sur 8443, dans le nœud), l'adresse IP est la bonne, mais le kubeconfig vise le port **6443**, celui d'un cluster kubeadm, alors que l'apiserver du lab écoute sur 8443 : rien n'écoute sur 6443, d'où le refus. On corrige l'entrée du cluster `cka`, que partagent les contextes `cka`, `boutique` et `alice@cka` :
>
> ```bash
> kubectl config set-cluster cka --server=https://$(minikube -p cka ip):8443
> kubectl get nodes
> ```
>
> `minikube -p cka update-context` aurait réécrit la même valeur. À l'examen, l'équivalent consiste à lire le bon point d'accès dans `/etc/kubernetes/admin.conf` du control plane, ou dans le manifeste de l'apiserver (`--secure-port`, `--advertise-address`).
>
> **Vérification** : `kubectl get nodes` liste les trois nœuds, et `lab/pannes.sh verifier 19` réussit.

#### Exercice 23.10 — L'inventaire d'un nœud sain

**Point de départ** : exercice 23.9, ou instantané I4.

Sans rien modifier, relève sur `cka-m02` : le fichier d'unité et le drop-in du kubelet, l'état d'activation du kubelet et de containerd, le dossier des pods statiques et la CA de confiance du kubelet, l'adresse de l'API qu'utilise le kubelet, le sujet et la date d'expiration de son certificat client, les ports qu'écoutent le kubelet et kube-proxy, le fichier de configuration CNI, et la date du dernier renouvellement de la Lease du nœud. Écris le tout dans `~/cka/noeuds/cka-m02.txt`, une information par ligne.

> [!example]- Solution
> ```bash
> mkdir -p ~/cka/noeuds
> {
>   minikube -p cka ssh -n cka-m02 -- "systemctl cat kubelet | grep '^# /'"
>   minikube -p cka ssh -n cka-m02 -- 'systemctl is-enabled kubelet containerd'
>   minikube -p cka ssh -n cka-m02 -- 'sudo grep -E "staticPodPath|clientCAFile" /var/lib/kubelet/config.yaml'
>   minikube -p cka ssh -n cka-m02 -- 'sudo grep server: /etc/kubernetes/kubelet.conf'
>   minikube -p cka ssh -n cka-m02 -- 'sudo cat /var/lib/kubelet/pki/kubelet-client-current.pem' | openssl x509 -noout -subject -enddate
>   minikube -p cka ssh -n cka-m02 -- 'sudo ss -ltnp | grep -E "kubelet|kube-proxy"'
>   minikube -p cka ssh -n cka-m02 -- 'ls /etc/cni/net.d/'
>   kubectl -n kube-node-lease get lease cka-m02 -o jsonpath='{.spec.renewTime}{"\n"}'
> } | tr -d '\r' > ~/cka/noeuds/cka-m02.txt
> cat ~/cka/noeuds/cka-m02.txt
> ```
>
> On y lit l'unité `/lib/systemd/system/kubelet.service` et le drop-in `/etc/systemd/system/kubelet.service.d/10-kubeadm.conf` ; `enabled` pour le kubelet et `disabled` pour containerd (minikube démarre le runtime lui-même, ce qu'un nœud kubeadm ne fait pas) ; `staticPodPath: /etc/kubernetes/manifests` et `clientCAFile: /var/lib/minikube/certs/ca.crt` ; le serveur `https://control-plane.minikube.internal:8443`, nom résolu par `/etc/hosts` du nœud vers 192.168.49.2 ; un sujet `O=system:nodes, CN=system:node:cka-m02` et une expiration un an après la création du nœud ; le kubelet sur `*:10250` et `127.0.0.1:10248`, kube-proxy sur 10256 et 10249 ; `10-calico.conflist` ; une Lease renouvelée il y a moins de 10 secondes. Le certificat est décodé sur le poste, où `openssl` est disponible : le fichier `.pem` contient le certificat puis la clé, et `openssl x509` ne lit que le premier. `tr -d '\r'` retire les retours chariot qu'ajoute `minikube ssh`.
>
> **Vérification** : `grep -c . ~/cka/noeuds/cka-m02.txt` affiche au moins 10 lignes, et `grep -q 'CN=system:node:cka-m02' ~/cka/noeuds/cka-m02.txt && echo ok` affiche `ok`.

#### Exercice 23.11 — Diagnostiquer le control plane sans kubectl

**Point de départ** : exercice 23.10, ou instantané I4.

Fais comme si l'API était inaccessible depuis ton poste. Depuis le nœud `cka` seulement, et sans aucun `kubectl`, relève : l'état et le compteur de redémarrages des conteneurs des quatre composants du control plane, la version d'image de chacun d'après les manifestes, la dernière ligne de journal du scheduler lue dans `/var/log/pods`, et l'état de santé détaillé de l'apiserver.

> [!example]- Solution
> ```bash
> minikube -p cka ssh
> sudo crictl ps -a | grep -E 'NAME|kube-apiserver|kube-controller-manager|kube-scheduler|etcd'
> sudo grep -H 'image:' /etc/kubernetes/manifests/*.yaml
> D=$(sudo ls -td /var/log/pods/kube-system_kube-scheduler-cka_* | head -1)
> sudo sh -c "tail -n 1 \$(ls -t $D/kube-scheduler/*.log | head -1)"
> curl -sk "https://localhost:8443/readyz?verbose" | tail -4
> exit
> ```
>
> `crictl ps -a` donne pour chaque conteneur l'état (`Running`) et la colonne `ATTEMPT` ; un composant sain a un `ATTEMPT` stable et aucun conteneur `Exited` récent. Les images sont `registry.k8s.io/kube-{apiserver,controller-manager,scheduler}:v1.37.0` et `registry.k8s.io/etcd:3.7.0-0`. La ligne de journal brute du scheduler commence par l'horodatage CRI et le flux (`stderr F`), suivis de l'en-tête klog. `readyz?verbose` liste chaque vérification (`[+]ping ok`, `[+]etcd ok`…) et se termine par `readyz check passed` ; ce point d'accès ne demande aucune authentification. Ces quatre commandes sont exactement celles d'un control plane dont l'API est tombée (exercice 23.5).
>
> **Vérification** : la dernière commande affiche `readyz check passed`.

#### Exercice 23.12 — Le piège de la copie de sauvegarde

**Point de départ** : exercice 23.11, ou instantané I4.

Sur le nœud `cka`, copie le manifeste du scheduler en `kube-scheduler.yaml.bak` **dans** `/etc/kubernetes/manifests`, observe pendant 30 secondes ce que fait le kubelet, puis recommence avec une copie nommée `.kube-scheduler.yaml.bak`. Explique la différence, et remets le dossier dans son état d'origine.

> [!example]- Solution
> ```bash
> minikube -p cka ssh
> sudo crictl ps -a --name kube-scheduler
> sudo cp /etc/kubernetes/manifests/kube-scheduler.yaml /etc/kubernetes/manifests/kube-scheduler.yaml.bak
> sleep 30
> sudo journalctl -u kubelet --since "1 min ago" --no-pager | grep -i 'mirror pod' | tail -3
> sudo crictl ps -a --name kube-scheduler
> sudo mv /etc/kubernetes/manifests/kube-scheduler.yaml.bak /root/
> sudo cp /etc/kubernetes/manifests/kube-scheduler.yaml /etc/kubernetes/manifests/.kube-scheduler.yaml.bak
> sleep 30
> sudo crictl ps -a --name kube-scheduler
> sudo rm /etc/kubernetes/manifests/.kube-scheduler.yaml.bak
> sudo ls -A /etc/kubernetes/manifests
> exit
> ```
>
> Avec `kube-scheduler.yaml.bak`, le kubelet lit un second manifeste qui décrit un pod de même nom : il recrée le pod statique, le conteneur du scheduler redémarre (nouvelle ligne dans `crictl ps -a`), et le journal contient `Deleted mirror pod as it didn't match the static Pod`. Avec deux versions différentes du même pod, l'une ou l'autre peut l'emporter : c'est ainsi qu'une « réparation » se trouve annulée par une vieille copie. Avec `.kube-scheduler.yaml.bak`, rien ne se passe : le kubelet ignore les fichiers qui commencent par un point. La seule pratique sûre reste de sauvegarder hors du dossier.
>
> **Vérification** : `sudo ls -A /etc/kubernetes/manifests` dans le nœud ne liste que `etcd.yaml`, `kube-apiserver.yaml`, `kube-controller-manager.yaml` et `kube-scheduler.yaml`, et `kubectl -n kube-system get pods -l component=kube-scheduler` montre `1/1 Running`.

---
