---
title: "CKA — 24. Le jour de l'examen"
description: "L'environnement PSI de l'examen CKA, les réglages à faire en début d'épreuve, la stratégie de temps, la vérification de chaque tâche, les erreurs classiques, les pages de documentation à connaître, killer.sh, la veille et le jour J."
tags: [cka, kubernetes, certification]
date: 2026-10-23
---

## 24. Le jour de l'examen

Les vingt-trois chapitres précédents t'ont appris à faire. Celui-ci t'apprend à faire **le jour de l'examen**, dans un environnement qui n'est pas le tien, avec un chronomètre, une documentation que tu consultes dans un Firefox distant et des hôtes où tu te connectes par `ssh` à chaque tâche. Des candidats qui savent tout échouent sur ce terrain : une tâche faite sur le mauvais hôte, un fichier écrit dans le mauvais `~`, une heure perdue sur une tâche à 4 % pendant que trois tâches faciles attendent. Ce chapitre ne correspond à aucune compétence du programme : il sert les cinq domaines à la fois (*Storage*, *Troubleshooting*, *Workloads and Scheduling*, *Cluster Architecture, Installation and Configuration*, *Services and Networking*) en te faisant marquer les points que tu sais déjà gagner. Il reprend l'environnement, les réglages du début, la gestion du temps, la vérification de chaque tâche, les erreurs classiques, les pages de documentation à connaître, le simulateur killer.sh, puis la veille et le jour J. Tout ce qu'il affirme sur l'examen vient des pages de la Linux Foundation lues le 23 octobre 2026 ; ce qu'elles ne disent pas est signalé comme tel.

### 24.1 De l'inscription au résultat

```
Calendrier d'un passage :
═════════════════════════

  Inscription ─────────▶ 12 mois pour planifier et passer
       │                  l'examen ET la seconde tentative
       │
  Réservation ─────────▶ au moins 24 h d'avance, jusqu'à 90 jours ;
       │                  modifiable jusqu'à 24 h avant l'heure
       │
  J-30 à J-7 ──────────▶ killer.sh A puis B (36 h chacune,
       │                  à activer quand tu as fini le cours)
       │
  J-1 ─────────────────▶ vérification du poste (PSI), tutoriel
       │                  du navigateur sécurisé, pièce d'identité
       │
  J, heure - 30 min ───▶ « Take Exam » : accueil automatique,
       │                  photo de la pièce, selfie, tour de la pièce
       │
  J, heure + 30 min ───▶ dernier délai pour avoir commencé,
       │                  sinon : absent, examen perdu
       │
  Examen ──────────────▶ 2 h ; le chronomètre démarre à la fin
       │                  de la visite guidée de l'interface
       │
  J+1 ─────────────────▶ résultat par courriel sous 24 h
                          (et sur le portail)
```

Quelques règles de ce calendrier méritent d'être lues deux fois. Une fois la réservation à moins de 24 heures, plus rien ne bouge : ni report, ni annulation. Un candidat qui ne s'est pas présenté perd ses frais et son droit à la seconde tentative. Le nom saisi dans la liste de préparation (*Exam Preparation Checklist*) doit correspondre **exactement** à celui de la pièce d'identité, et il est figé dès que tu cliques sur « Start My Test ». La pièce doit être un original physique, en cours de validité, émis par un État, avec nom, photo et signature (une carte d'identité nationale ou un passeport conviennent).

Le tutoriel de PSI (*PSI Remote Testing Tutorial*) prend une trentaine de minutes : il installe le navigateur sécurisé, le teste et te montre comment fermer les programmes interdits. Il est accessible dès que tu as une réservation, et jusqu'à 150 minutes avant l'heure de l'examen. Fais-le la veille, pas le jour même.

### 24.2 L'environnement d'examen

#### Le navigateur sécurisé et l'interface

L'examen se passe dans le **PSI Secure Browser**, un navigateur dérivé de Chrome que PSI te fait télécharger au lancement. Il affiche l'interface d'examen (*ExamUI*) en deux zones. À gauche, le **panneau de contenu** présente les tâches, une à la fois, avec leur encadré de connexion et, quand il y en a, l'encadré *Quick Reference* qui donne des liens de documentation propres à la tâche ; il se redimensionne en faisant glisser sa bordure, et l'icône en forme de globe change la langue des énoncés. À droite, le **bureau distant** est un bureau Linux (XFCE) qui contient le terminal, Firefox, l'éditeur VSCodium et un clavier virtuel.

Le chronomètre ne démarre qu'à la fin de la visite guidée de l'interface (ou quand tu la masques). L'interface t'avertit à 30, 15 et 5 minutes de la fin. Demander une pause au surveillant **n'arrête pas** le chronomètre, et une déconnexion non plus : tu relances l'examen depuis le bouton « Access » du tableau de bord PSI (ou l'application PSI Secure Browser installée), tu refais l'accueil, et le temps a continué de courir. Pour terminer, on clique sur « End Exam », puis sur « End Session ».

Les menus de l'ExamUI ajustent l'affichage : boutons « + » et « − » pour la taille de la police du bureau distant, menu des réglages (roue dentée) pour ajuster le bureau à l'écran ou le réinitialiser (*Reset Desktop*) si l'affichage se fige. Un double clic dans la barre de titre de Firefox l'agrandit ou le réduit.

#### Le système base et les hôtes de chaque tâche

Le terminal du bureau distant s'ouvre sur une machine nommée `base`. Elle ne porte **aucun** des outils de l'examen : pas de `kubectl`, pas de `yq`. Chaque tâche se fait sur un **hôte désigné** : un encadré, en tête de la tâche, donne la commande `ssh` pour s'y connecter. Sur tous ces hôtes SSH, la Linux Foundation a préinstallé et préconfiguré :

| Outil | Remarque |
|---|---|
| `kubectl` | avec l'alias `k` et la complétion Bash |
| `yq` | pour lire et modifier du YAML |
| `curl`, `wget` | pour tester des services web |
| `man` et les pages de manuel | documentation hors ligne |

```
Une tâche, du début à la fin :
══════════════════════════════

  …@base:~$ ssh <hôte de la tâche>     ← copié depuis l'encadré
        │
        ▼
  …@<hôte>:~$ k get …                  ← kubectl, alias k, complétion
        │
        │  besoin de root (manifestes, kubelet, crictl, etcd) ?
        ├──▶ sudo <commande>           ← une commande en root
        └──▶ sudo -i  …  exit          ← un shell root, refermé
        │
        ▼
  …@<hôte>:~$ exit                     ← retour sur base
  …@base:~$                            ← prêt pour la tâche suivante

  Le ssh imbriqué n'est pas pris en charge : depuis un hôte, on ne
  se connecte pas à un autre hôte. On revient TOUJOURS sur base.
  Ne redémarre jamais base : cela ne relance pas l'environnement.
```

La documentation de la Linux Foundation décrit ce modèle « une tâche, un hôte ». Le simulateur killer.sh et des versions plus anciennes de l'examen faisaient aussi changer de contexte kubeconfig (`kubectl config use-context …`) en tête de tâche. Le réflexe qui couvre tous les cas : exécute **exactement** ce que dit l'encadré de la tâche, commande `ssh`, changement de contexte ou option `--kubeconfig`, avant toute autre commande, même si tu crois être au bon endroit.

#### Clavier et presse-papiers

Le bureau distant impose quelques raccourcis, qui piègent surtout les habitués de macOS :

| Action | Raccourci |
|---|---|
| Copier dans le terminal | `Ctrl+Shift+C` (ou clic droit, « Copy ») |
| Coller dans le terminal | `Ctrl+Shift+V` (ou clic droit, « Paste ») |
| Copier, coller dans Firefox et VSCodium | `Ctrl+C`, `Ctrl+V` |
| Effacer le mot précédent (bash), commande de fenêtre (vim) | `Ctrl+Alt+W` au lieu de `Ctrl+W`, qui fermerait l'onglet du navigateur |
| Retrouver le curseur | `Ctrl+Alt+K` |
| Rechercher dans une page de Firefox | `Ctrl+F` (agrandis d'abord la fenêtre pour voir la barre de recherche, en bas) |
| Passer en insertion dans vim | `i` : la touche `Inser` est interdite sur le bureau distant |

Certaines touches des claviers non américains réagissent mal à distance : le clavier virtuel (icône « Virtual Keyboard » du bureau) fournit les caractères spéciaux qui manquent. Entraîne-toi au moins une fois avec ton propre clavier dans le simulateur killer.sh, qui reproduit ce bureau : découvrir le jour J que la touche `|` ne passe pas coûte cher.

#### La documentation dans Firefox

Le Firefox du bureau distant n'ouvre que les sites autorisés (section 1.2) : https://kubernetes.io/docs, https://kubernetes.io/blog/, https://helm.sh/docs et, pour le CKA, https://gateway-api.sigs.k8s.io, plus les liens de l'encadré *Quick Reference*. La recherche intégrée à kubernetes.io est permise, mais tu ne dois pas ouvrir de résultat qui sortirait de ces sites. Une extension de traduction (Simple Translate) est installée. Firefox, comme tout le bureau, passe par une connexion à distance : le défilement et l'ouverture des pages sont plus lents que chez toi. C'est l'argument principal pour connaître à l'avance l'adresse des pages utiles (section 24.7) et pour préférer `kubectl explain` et `--help` quand ils suffisent.

### 24.3 Les réglages du début

#### Ce qui est déjà en place

Sur les hôtes SSH, `kubectl`, l'alias `k` et la complétion Bash sont configurés pour toi : `k get po -n kube-<Tab>` complète déjà. Il n'y a donc **rien d'obligatoire** à taper en début d'examen, et chaque minute passée à personnaliser l'environnement est une minute retirée aux tâches. Les guides qui recommandent dix lignes de `.bashrc` ont été écrits pour une version de l'examen où l'on travaillait depuis un seul terminal en changeant de contexte ; aujourd'hui, chaque tâche peut se dérouler sur un hôte différent, et ce que tu configures sur l'un n'existe pas sur l'autre.

#### Ce qui vaut la peine d'être tapé

Deux réglages rapportent plus qu'ils ne coûtent, à condition de les avoir prêts à coller. Le premier définit deux variables qu'on utilise sans cesse :

```bash
export do="--dry-run=client -o yaml" now="--force --grace-period=0"
```

`k create deploy web --image=nginx:1.30.6-alpine $do > web.yaml` produit un manifeste à compléter, `k delete pod essai $now` supprime un pod sans attendre son délai de grâce. Les deux variables s'utilisent **sans guillemets** (`$do`, pas `"$do"`), pour que le shell découpe leur contenu en plusieurs options.

Le second est un `.vimrc` minimal pour le YAML, détaillé ci-dessous. Où les taper ? Une variable d'environnement ne vit que dans le shell courant : elle disparaît au `exit`. Un `~/.vimrc` reste sur l'hôte, mais seulement sur cet hôte et pour cet utilisateur. La méthode la plus économique : au début de l'examen, écris une fois ces lignes dans VSCodium (ou un fichier ouvert dans le terminal de `base`), puis colle-les sur chaque nouvel hôte où tu vas éditer du YAML, au moment où tu y arrives. Le collage prend trois secondes ; les retaper prendrait une minute à chaque fois.

> [!warning] sudo -i change de maison
> Après `sudo -i`, tu es root, ton répertoire personnel est `/root`, et ni tes variables, ni ton `~/.vimrc`, ni peut-être l'alias `k` et la complétion n'y existent. Pire : `kubectl` lancé en root cherche `/root/.kube/config`, souvent absent, et répond `The connection to the server localhost:8080 was refused - did you specify the right host or port?`. Garde `kubectl` sous ton utilisateur, et ne passe en root que pour ce qui l'exige vraiment (manifestes de `/etc/kubernetes`, kubelet, `crictl`, etcd), de préférence commande par commande avec `sudo`.

#### Un .vimrc minimal pour le YAML

L'éditeur par défaut de `kubectl edit` est `vi`, et vim reste l'éditeur le plus sûr d'être présent sur un hôte Linux. Trois difficultés guettent le YAML : les tabulations (YAML les interdit pour l'indentation), la largeur d'indentation et le collage de blocs copiés depuis la documentation. Voici le fichier, puis son explication :

```bash
cat > ~/.vimrc <<'EOF'
unlet! skip_defaults_vim
source $VIMRUNTIME/defaults.vim
set expandtab shiftwidth=2 softtabstop=2 tabstop=2 autoindent
set mouse=
EOF
```

Les deux premières lignes ne sont pas décoratives. Depuis Vim 8.0, quand **aucun** fichier `~/.vimrc` n'existe, Vim charge `$VIMRUNTIME/defaults.vim`, qui active entre autres la détection du type de fichier avec ses greffons (`filetype plugin indent on`) et la coloration syntaxique. Créer un `~/.vimrc`, même d'une ligne, **désactive** ce chargement. L'aide de Vim (`:help defaults.vim`) recommande donc de commencer son `.vimrc` par ces deux lignes. Sans elles, un `.vimrc` réduit à `set et ts=2 sw=2` fait perdre le greffon YAML de Vim ; selon le vimrc système de la distribution, on perd aussi la coloration (Ubuntu, par exemple, la réactive dans `/etc/vim/vimrc`, mais pas les greffons).

La troisième ligne règle l'indentation : `expandtab` remplace chaque tabulation par des espaces, `shiftwidth=2` fixe l'indentation de `>>`, `<<` et `>` à deux espaces, `softtabstop=2` fait avancer et reculer `Tab` et `Retour arrière` de deux colonnes, `tabstop=2` affiche une éventuelle tabulation résiduelle sur deux colonnes, `autoindent` reprend l'indentation de la ligne précédente. La quatrième désactive la souris dans vim : `defaults.vim` l'active (`mouse=a`) dans les terminaux de type xterm, et une sélection à la souris passe alors en mode visuel de vim au lieu de sélectionner le texte du terminal, ce qui empêche le copier par `Ctrl+Shift+C`.

Vérification, dans vim, sur un fichier `.yaml` : `:set et? sw? ts? mouse?` doit afficher `expandtab  shiftwidth=2  tabstop=2  mouse=`. Si vim affiche une erreur sur les deux premières lignes au démarrage, c'est une version minimale (`vim-tiny`, sans langage de script) : retire ces deux lignes.

> [!tip] Réflexe d'examen : coller du YAML sans vim
> Vim coupe le collage en morceaux et réindente en cascade quand le terminal ne lui signale pas qu'il s'agit d'un collage. Les terminaux de type xterm le signalent (*bracketed paste*), mais si l'indentation part en escalier, `:set paste` avant de passer en insertion, `:set nopaste` après. Plus simple encore : colle directement dans le terminal, sans éditeur :
> ```bash
> cat > pvc.yaml <<'EOF'
> (coller ici le YAML copié dans la documentation)
> EOF
> ```
> Les guillemets autour de `'EOF'` empêchent le shell d'interpréter les `$` du YAML.

#### Les gestes de vim qui servent pour le YAML

| Geste | Effet |
|---|---|
| `V` puis `j`/`k`, puis `>` ou `<` | indenter ou désindenter un bloc de deux espaces |
| `5>>` | indenter 5 lignes à partir du curseur |
| `.` | répéter la dernière modification (une seconde indentation, par exemple) |
| `dd`, `5dd`, `p` | couper une ligne, cinq lignes, coller en dessous |
| `yy`, `yyp` | copier une ligne, la dupliquer |
| `u`, `Ctrl+R` | annuler, rétablir |
| `/replicas` puis `n` | chercher, occurrence suivante |
| `:set list` | afficher les tabulations (`^I`) et fins de ligne : un `^I` dans du YAML est une erreur |
| `:%s/v1beta1/v1/g` | remplacer dans tout le fichier |
| `:wq` ou `ZZ`, `:q!` | enregistrer et quitter, quitter sans enregistrer |

> [!warning] Quand kubectl edit refuse d'enregistrer
> Si le YAML modifié par `kubectl edit` est invalide ou touche un champ immuable, kubectl rouvre l'éditeur avec l'erreur en commentaire en tête du fichier ; si tu quittes sans corriger, il enregistre ta version dans un fichier temporaire (`/tmp/kubectl-edit-….yaml`) et te donne son chemin. Pour un champ immuable (le sélecteur d'un Deployment, la plupart des champs d'un pod), applique ce fichier par `kubectl replace --force -f /tmp/kubectl-edit-….yaml` : l'objet est supprimé puis recréé (chapitre 3.7).

### 24.4 La stratégie de temps

#### Le budget

Deux heures pour quinze à vingt tâches : environ sept minutes par tâche en moyenne si tu en as dix-sept. Mais les tâches sont inégales. Lister les nœuds dans un fichier prend deux minutes ; restaurer etcd ou réparer un control plane en prend quinze. La règle qui compte n'est donc pas la moyenne, mais **le plafond** : en première passe, aucune tâche ne mérite plus de huit à dix minutes, sauf si tu es à une commande de la fin.

#### Trois passes

La méthode la plus sûre se déroule en trois passes, calées sur les alertes de l'interface (30, 15 et 5 minutes avant la fin) :

```
Les trois passes :
══════════════════

  0 ──────────────────────────────── 90 ─────────── 105 ──────── 115 ── 120 min
  │          PASSE 1                  │   PASSE 2    │  PASSE 3   │ fin │
  │ toutes les tâches, dans l'ordre ; │ les tâches   │ relire les │ rien│
  │ chacune finie ET vérifiée, ou     │ notées, par  │ doutes,    │ de  │
  │ notée et abandonnée au plafond    │ meilleur     │ vérifier   │neuf │
  │                                   │ rapport      │ les états  │     │
  │                                   │ points/temps │            │     │
                                      ▲              ▲            ▲
                               alerte 30 min   alerte 15 min  alerte 5 min
```

En première passe, tu prends les tâches dans l'ordre, parce que lire toutes les tâches avant de commencer coûte cinq à dix minutes et que l'ordre n'a pas d'importance pour la note. Chaque tâche est soit terminée et vérifiée (section 24.5), soit notée et laissée de côté au plafond. Ce qui fait passer une tâche dans la liste : une commande dont tu ne retrouves pas la syntaxe après deux minutes de documentation, un composant qui ne revient pas après une correction, une tâche longue (installation, restauration) qu'il vaut mieux faire quand les tâches courtes sont acquises.

En deuxième passe, tu reprends la liste, en commençant par les tâches qui rapportent le plus pour le temps qui reste. En troisième passe, tu ne commences plus rien de lourd : tu relis les tâches marquées « doute », tu vérifies que les états attendus tiennent toujours (un pod qui a redémarré entre-temps, un nœud redevenu `NotReady`). Les cinq dernières minutes ne servent qu'à finir proprement une commande en cours.

#### Poids et drapeaux

La documentation de la Linux Foundation ne décrit pas le barème, ni l'affichage d'un poids par tâche, ni de fonction pour marquer une tâche dans l'interface des examens pratiques (elle en décrit une, « Flag », seulement pour les examens à choix multiples). Le simulateur killer.sh affiche un poids pour chaque tâche. Ta stratégie doit donc fonctionner dans les deux cas. Si l'interface affiche un poids, sers-t'en en deuxième passe : une tâche à 7 % avant une tâche à 4 %. Sinon, estime-le par le nombre de sous-tâches de l'énoncé, puisque la note se calcule vraisemblablement par sous-tâche (section 1.2).

Pour les drapeaux, ne dépends pas de l'interface : tiens ta propre liste dans un fichier de `base`, ouvert dans VSCodium ou dans un second onglet du terminal. Une ligne par tâche laissée de côté suffit :

```
T04  ~6 %  À FAIRE   sidecar : vérifier la syntaxe restartPolicy dans la doc
T09  ~7 %  DOUTE     HTTPRoute acceptée, poids 80/20 non testés
T13  ~6 %  À FAIRE   etcd : snapshot pas encore lancé
```

Le règlement interdit d'écrire en dehors de l'écran d'examen (papier, autre appareil) ; un fichier ouvert dans le bureau distant fait partie de cet écran.

#### Quand abandonner

Abandonner une tâche n'est pas un échec, c'est une décision de gestion. Le seuil est à 66 % : réussir parfaitement des tâches qui pèsent ensemble 70 % suffit, même si toutes les autres restent vides. Le vrai danger est l'inverse : s'acharner vingt-cinq minutes sur une tâche à 5 %, et ne plus avoir le temps de faire trois tâches de deux minutes à la fin. Avant d'abandonner, laisse la tâche dans l'état le plus avancé possible (la moitié des sous-tâches faites rapporte probablement des points), note ce qui manque, fais `exit` et passe à la suivante.

### 24.5 Vérifier chaque tâche : la liste de contrôle

Une tâche n'est finie que vérifiée. La vérification prend trente secondes et rattrape les erreurs qui coûtent le plus cher : la faute de frappe dans un nom, le mauvais namespace, la valeur oubliée. Voici la liste à dérouler, mentalement puis par réflexe, à chaque tâche :

```
Liste de contrôle d'une tâche :
═══════════════════════════════

  AVANT
  [ ] Lire l'énoncé EN ENTIER : hôte, namespace, noms, valeurs,
      fichiers de sortie, contraintes ("sans modifier…", "uniquement…")
  [ ] Coller la commande de l'encadré (ssh, contexte) ; lire le prompt
  [ ] Repérer chaque sous-tâche : une ligne de la liste de suivi chacune

  PENDANT
  [ ] Noms copiés depuis l'énoncé (copier-coller, pas de retape)
  [ ] -n <namespace> sur CHAQUE commande, ou namespace dans le YAML
  [ ] Chemins de fichiers absolus, tels que l'énoncé les donne

  APRÈS
  [ ] L'objet existe, au bon endroit, avec les bonnes valeurs
  [ ] Il FONCTIONNE : Running et prêt, Bound, Ready, Accepted…
  [ ] L'état TIENT : manifeste corrigé, service activé, rien de "à chaud"
  [ ] exit (deux fois après sudo -i) : retour sur base
```

Le « il fonctionne » dépend de l'objet. Le tableau suivant donne, pour chaque type de tâche, la vérification la plus rapide :

| Tâche | Vérification |
|---|---|
| Deployment, mise à jour, retour arrière | `k -n NS rollout status deploy/NOM` ; `k -n NS get deploy NOM -o wide` (image, réplicas prêts) ; `k -n NS rollout history deploy/NOM` |
| Pod avec conteneurs particuliers (sidecar, init) | `k -n NS get pod NOM` (`READY 2/2`) ; `k -n NS logs NOM -c CONTENEUR` |
| ConfigMap, Secret consommés | `k -n NS exec NOM -- env` ou `-- cat /chemin/monté` |
| Service | `k -n NS get endpointslices -l kubernetes.io/service-name=NOM` (adresses prêtes) ; un `curl` depuis un pod ou un nœud |
| NodePort | `curl http://<IP d'un nœud>:<nodePort>/` |
| Ingress | colonne `ADDRESS` remplie ; `curl -H 'Host: <hôte>' http://<adresse>/` |
| Gateway, HTTPRoute | `k -n NS get gateway,httproute` ; conditions `Accepted`, `Programmed`, `ResolvedRefs` à `True` dans `describe` |
| NetworkPolicy | un test du trafic **autorisé** ET un test du trafic **refusé** (`--timeout`, `-T`) |
| PVC, StorageClass | PVC `Bound` (ou `Pending` attendu avec `WaitForFirstConsumer` tant qu'aucun pod ne la consomme) ; pod consommateur `Running` |
| RBAC | `k auth can-i VERBE RESSOURCE -n NS --as=system:serviceaccount:NS:SA` : `yes` pour ce qui est permis, `no` pour le reste |
| HPA | `k -n NS get hpa` : cibles chiffrées, pas `<unknown>` |
| Nœud réparé | `k get nodes` : `Ready` ; dans le nœud, `systemctl is-active kubelet` **et** `systemctl is-enabled kubelet` |
| Pod statique, control plane | `sudo crictl ps --name kube-…` ; le pod miroir `…-<nœud>` dans `kube-system` |
| Sauvegarde etcd | `sudo etcdutl snapshot status <fichier> -w table` |
| Release Helm | `helm -n NS list` ; `helm -n NS get values RELEASE` |
| Fichier demandé | `cat /chemin/absolu` sur l'hôte de la tâche : contenu et format exacts |

> [!tip] Réflexe d'examen : relire l'énoncé une dernière fois
> Avant de faire `exit`, relis l'énoncé ligne à ligne en regard de ta vérification. C'est à ce moment qu'on découvre le label demandé et jamais posé, le port 8080 tapé 8008, le `--namespace` oublié qui a tout créé dans `default`.

#### Anatomie d'un énoncé

Les énoncés sont proposés en anglais, en chinois simplifié et en japonais ; pour un francophone, l'anglais est la seule option, et quelques mots y portent toute la contrainte. Voici un énoncé **fictif**, rédigé dans le style de l'examen, puis sa lecture :

```
ssh host-3

Context
  The Deployment web in namespace shop runs fine, but its Service
  has no endpoints.

Task
  1. Fix the Service web so that it routes traffic to the Pods of the
     Deployment web. Do not modify the Deployment.
  2. Expose the Deployment web through a new Service named web-np of
     type NodePort, on node port 30085.
  3. Save the list of ready endpoint IPs of web-np to /opt/answers/web.txt,
     one IP per line.
```

| Sous-tâche | Contrainte cachée | Commande | Vérification |
|---|---|---|---|
| 0 | « ssh host-3 » : avant tout | `ssh host-3` | prompt qui affiche l'hôte `host-3` |
| 1 | *Do not modify the Deployment* : la réparation se fait sur le Service seul | `k -n shop get deploy web -o jsonpath='{.spec.selector}'` puis `k -n shop edit svc web` (sélecteur) | `k -n shop get endpointslices -l kubernetes.io/service-name=web` |
| 2 | *new Service named web-np* : un second Service, l'ancien reste | `k -n shop expose deploy web --name=web-np --type=NodePort --port=80` puis patch du `nodePort` | `k -n shop get svc web-np` : `80:30085/TCP` |
| 3 | *ready endpoint IPs*, *one IP per line*, chemin absolu sur `host-3` | `k -n shop get endpointslices -l kubernetes.io/service-name=web-np -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}{.addresses[0]}{"\n"}{end}' \| sudo tee /opt/answers/web.txt` | `cat /opt/answers/web.txt` |
| fin | | `exit` | prompt qui affiche `base` |

Le port du Service `web-np` n'est pas imposé par l'énoncé : on reprend celui du conteneur (ici 80), que donne `k -n shop get deploy web -o yaml`. `sudo tee` n'est utile que si `/opt/answers` appartient à root ; essaie d'abord sans.

Le vocabulaire qui contraint, et sa traduction exacte :

| Anglais | Ce qu'il impose |
|---|---|
| *Ensure*, *make sure* | l'état doit être atteint **et** vérifié |
| *Do not modify*, *without changing* | un objet est interdit de modification : le correcteur peut vérifier qu'il est intact |
| *Only*, *exclusively* | rien de plus : pas de règle, de label ou de port en trop |
| *Existing* | l'objet existe déjà : on le modifie, on ne le recrée pas (sauf impossibilité) |
| *New* | un objet supplémentaire, à côté de l'existant |
| *Persist*, *survive a reboot*, *permanently* | une configuration sur disque, un service `enable`, pas un réglage à chaud |
| *Save / write the output to* | un fichier, au chemin exact, sur l'hôte de la tâche, au format demandé |
| *In namespace X*, *in the X namespace* | `-n X` partout |
| *Use the image X* | l'étiquette exacte (`nginx:1.30.6-alpine`, pas `nginx`) |
| *Schedule on*, *run on node X* | vérifier le nœud obtenu, pas seulement l'état `Running` |
| *Temporarily*, *then revert* | l'état final est l'état d'origine |

### 24.6 Les erreurs classiques

Les erreurs qui coûtent des points au CKA sont rarement des erreurs de connaissance. Ce sont presque toujours les mêmes erreurs de manipulation, et elles se préviennent toutes par une habitude.

**Le mauvais hôte, le mauvais contexte.** L'erreur la plus coûteuse, parce qu'elle annule une tâche parfaitement faite : tout a été créé sur le cluster de la tâche précédente. Elle naît d'une tâche commencée sans retaper la commande de l'encadré, « puisque je suis déjà connecté ». Le prompt affiche le nom de l'hôte : lis-le avant la première commande. Si la tâche donne un contexte, `k config current-context` le confirme.

**Le mauvais nœud.** Une tâche peut viser un nœud précis d'un cluster : « le kubelet du nœud X ne démarre plus », « placer ce pod sur le nœud Y ». Réparer le kubelet sur le control plane alors que c'est le worker qui est en panne ne rapporte rien ; `hostname` lève le doute en une seconde. Pour placer un pod, vérifie le nœud obtenu (`k get pod -o wide`), pas seulement que le pod tourne.

**L'`exit` oublié.** Rester connecté à l'hôte de la tâche 5 en commençant la tâche 6 produit soit une erreur (le ssh imbriqué n'est pas pris en charge), soit, pire, un travail fait au mauvais endroit sans aucun message. Après `sudo -i`, il faut **deux** `exit` : le premier quitte le shell root, le second la session SSH. Le prompt qui affiche de nouveau le nom d'hôte `base` est le seul signe que tu es prêt pour la tâche suivante.

**sudo au mauvais endroit.** Trois formes. Oublier `sudo` devant une commande qui l'exige (`crictl`, `systemctl restart`, lecture d'un manifeste en 0600, `etcdctl` avec des clés lisibles par root seul) donne un `permission denied` qu'on prend parfois pour une panne. Lancer `kubectl` en root donne un `localhost:8080 was refused` (section 24.3). Et `sudo commande > /fichier/protege` échoue, parce que la redirection est faite par **ton** shell, pas par sudo : écris `commande | sudo tee /fichier/protege`, ou `sudo sh -c 'commande > /fichier/protege'`.

**Le chemin du fichier de sortie.** Quand l'énoncé demande d'écrire un résultat dans un fichier, il en donne le chemin, presque toujours absolu. Le correcteur lit **ce** chemin, sur **cet** hôte. `~/resultat.txt` sur `base` n'est pas `~/resultat.txt` sur l'hôte de la tâche, et `~` en root est `/root`. Crée le répertoire parent s'il manque (`mkdir -p`, avec `sudo` s'il est dans une arborescence système), et respecte le format demandé à la lettre : une ligne par élément, l'ordre de tri, l'absence d'en-tête (`--no-headers`).

**Le namespace par défaut.** `k create …` sans `-n` crée dans le namespace du contexte, en général `default`. Mets `-n NS` à chaque commande, ou le `namespace:` dans le YAML. Changer le namespace du contexte (`k config set-context --current --namespace=NS`) fait gagner des caractères mais modifie le kubeconfig de l'hôte : la tâche suivante sur le même hôte en hérite. Si tu le fais, défais-le en fin de tâche.

**La réparation à chaud.** Modifier un pod géré par un Deployment (il sera remplacé), démarrer un service sans l'activer (il ne reviendra pas au redémarrage), corriger un pod statique par `kubectl edit` sur son pod miroir (le kubelet le recrée depuis le manifeste du disque) : autant de corrections qui ne tiennent pas. On corrige toujours la source : le Deployment, l'unité systemd (`enable --now`), le fichier de `/etc/kubernetes/manifests`.

**La copie de sauvegarde au mauvais endroit.** Avant de modifier un manifeste statique, on le sauvegarde, mais **hors** de `/etc/kubernetes/manifests` : le kubelet charge tous les fichiers de ce dossier, quel que soit leur suffixe, et une copie `.bak` y crée un second pod statique (chapitres 2.5 et 23.4.1).

**Attendre ce qui ne viendra pas.** Après la modification d'un manifeste du control plane, le kubelet met de quelques secondes à une minute pour relancer le composant. Pendant ce temps, `kubectl` peut échouer. Ne modifie pas le fichier une seconde fois par impatience : surveille plutôt `sudo crictl ps -a --name kube-apiserver` et lis `/var/log/pods` si le conteneur ne revient pas (chapitre 23.4.3).

> [!info] minikube ≠ examen : t'entraîner aux gestes de l'examen
> Le lab remplace `ssh <nœud>` par `minikube -p cka ssh -n <nœud>`, et l'utilisateur `docker` y a un `sudo` sans mot de passe, comme le candidat de l'examen. Pour t'entraîner aux bons réflexes, travaille dans le lab comme à l'examen : entre dans le nœud en interactif, utilise `sudo` commande par commande ou `sudo -i`, et sors par `exit`. Rappelle-toi seulement les chemins propres au lab (`/var/lib/minikube/certs`, `/var/lib/minikube/etcd`, devenu `/var/lib/minikube/etcd-restore` après l'exercice 20.5 alors qu'un `lab/restaurer.sh I4` repart de `/var/lib/minikube/etcd`, port 8443) et leurs équivalents d'examen (`/etc/kubernetes/pki`, `/var/lib/etcd`, port 6443).

### 24.7 Les pages de documentation à connaître

Chercher une page dans un Firefox distant coûte du temps ; savoir où elle est en fait gagner. Les tableaux suivants donnent, par domaine du programme, les pages de kubernetes.io et des autres sites autorisés qui contiennent ce qu'on vient y copier à l'examen. Toutes ces adresses répondaient (code HTTP 200) le 23 octobre 2026. Ouvre chacune au moins une fois pendant ta préparation, repère ce que tu y copierais, et retiens le chemin d'accès depuis l'accueil de la documentation plutôt que l'adresse exacte : la recherche du site et les menus suffisent si tu sais ce que tu cherches.

#### Pour tous les domaines

| Page | On y trouve |
|---|---|
| https://kubernetes.io/docs/reference/kubectl/quick-reference/ | complétion, alias `k`, exemples de toutes les commandes courantes, `--dry-run=client -o yaml` |
| https://kubernetes.io/docs/reference/kubectl/jsonpath/ | syntaxe JSONPath, filtres `?(@.type=="…")`, `range` |
| https://kubernetes.io/docs/reference/kubectl/generated/kubectl/ | référence de chaque commande et de ses options (par exemple `kubectl_create/kubectl_create_ingress/`) |
| https://kubernetes.io/docs/reference/labels-annotations-taints/ | labels, annotations et taints bien connus (`node-role…`, `topology.kubernetes.io/zone`…) |
| https://kubernetes.io/docs/reference/kubernetes-api/ | tous les champs de tous les objets ; `kubectl explain` donne la même chose plus vite |

#### Workloads and Scheduling (15 %)

| Page | On y trouve |
|---|---|
| https://kubernetes.io/docs/concepts/workloads/controllers/deployment/ | stratégies, `rollout`, `maxSurge`, `maxUnavailable` |
| https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/ | manifeste complet de DaemonSet avec tolérances |
| https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/ | StatefulSet et `volumeClaimTemplates` |
| https://kubernetes.io/docs/concepts/workloads/controllers/job/ et https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/ | `completions`, `parallelism`, `backoffLimit`, syntaxe cron, `timeZone` |
| https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/ | sidecar natif : init container avec `restartPolicy: Always` |
| https://kubernetes.io/docs/concepts/workloads/pods/init-containers/ | init containers |
| https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/ | sondes `httpGet`, `exec`, `tcpSocket`, `startupProbe` |
| https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/ | `envFrom`, `valueFrom`, ConfigMap en volume |
| https://kubernetes.io/docs/concepts/configuration/secret/ | types de Secret, consommation |
| https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/ | Secret en variable et en volume, exemples complets |
| https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/ | requests et limits, unités |
| https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/ | HPA v2, `behavior`, tolérance |
| https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/ | `kubectl autoscale`, manifeste `autoscaling/v2` complet |
| https://kubernetes.io/docs/tasks/configure-pod-container/resize-container-resources/ | redimensionnement en place, `--subresource resize` |
| https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/ | `nodeSelector`, affinités de nœud et de pod, `nodeName` |
| https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/ | taints, tolérances, `tolerationSeconds` |
| https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/ | `topologySpreadConstraints` |
| https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/ | PriorityClass |
| https://kubernetes.io/docs/concepts/policy/resource-quotas/ et https://kubernetes.io/docs/concepts/policy/limit-range/ | ResourceQuota, LimitRange |
| https://kubernetes.io/docs/concepts/security/pod-security-admission/ | labels `pod-security.kubernetes.io/enforce` etc. |
| https://kubernetes.io/docs/tasks/run-application/configure-pdb/ et https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/ | PodDisruptionBudget, `drain` |

#### Services and Networking (20 %)

| Page | On y trouve |
|---|---|
| https://kubernetes.io/docs/concepts/services-networking/service/ | types de Service, `targetPort`, NodePort, headless, ExternalName |
| https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/ | EndpointSlices, label `kubernetes.io/service-name` |
| https://kubernetes.io/docs/reference/networking/virtual-ips/ | modes de kube-proxy, `externalTrafficPolicy`, `sessionAffinity` |
| https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/ | noms DNS des Services et des pods, enregistrements SRV, `dnsPolicy`, `dnsConfig` |
| https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/ | Corefile de CoreDNS, `forward`, domaines de transfert |
| https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/ | méthode de dépannage DNS, pod de test |
| https://kubernetes.io/docs/concepts/services-networking/ingress/ | Ingress complet : `pathType`, TLS, `defaultBackend`, `ingressClassName` |
| https://kubernetes.io/docs/concepts/services-networking/ingress-controllers/ | IngressClass, classe par défaut |
| https://kubernetes.io/docs/concepts/services-networking/gateway/ | Gateway API vue de kubernetes.io |
| https://kubernetes.io/docs/concepts/services-networking/network-policies/ | NetworkPolicy, refus par défaut, `namespaceSelector`, `ipBlock`, `endPort` |
| https://gateway-api.sigs.k8s.io/guides/getting-started/introduction/ | installation des CRD, canaux |
| https://gateway-api.sigs.k8s.io/guides/user-guides/http-routing/ | HTTPRoute par hôte et par chemin |
| https://gateway-api.sigs.k8s.io/guides/user-guides/traffic-splitting/ | répartition par `weight` |
| https://gateway-api.sigs.k8s.io/guides/user-guides/http-redirect-rewrite/ | `RequestRedirect`, `URLRewrite` |
| https://gateway-api.sigs.k8s.io/guides/user-guides/tls/ | listener HTTPS, `certificateRefs` |
| https://gateway-api.sigs.k8s.io/guides/user-guides/multiple-ns/ | `allowedRoutes`, routes d'un autre namespace |
| https://gateway-api.sigs.k8s.io/reference/api-types/httproute/, `…/gateway/`, `…/referencegrant/` | description de chaque ressource |
| https://gateway-api.sigs.k8s.io/reference/api-spec/1.6/spec/ | spécification complète de l'API v1.6 |
| https://gateway-api.sigs.k8s.io/guides/getting-started/migrating-from-ingress/ | équivalences Ingress → Gateway API |

#### Storage (10 %)

| Page | On y trouve |
|---|---|
| https://kubernetes.io/docs/concepts/storage/persistent-volumes/ | PV, PVC, modes d'accès, politiques de récupération, expansion |
| https://kubernetes.io/docs/tutorials/configuration/configure-persistent-volume-storage/ | PV `hostPath`, PVC et pod complets, à copier d'un bloc |
| https://kubernetes.io/docs/concepts/storage/storage-classes/ | StorageClass, `volumeBindingMode`, `allowVolumeExpansion`, classe par défaut |
| https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/ | provisionnement dynamique |
| https://kubernetes.io/docs/concepts/storage/volumes/ | tous les types de volumes, dont `local`, `hostPath`, `emptyDir` |
| https://kubernetes.io/docs/concepts/storage/volume-snapshots/ | VolumeSnapshot, restauration par `dataSource` |
| https://kubernetes.io/docs/concepts/storage/projected-volumes/ | volumes projetés |

#### Cluster Architecture, Installation and Configuration (25 %)

| Page | On y trouve |
|---|---|
| https://kubernetes.io/docs/reference/access-authn-authz/rbac/ | Role, ClusterRole, bindings, agrégation, exemples `kubectl create role` |
| https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/ | CSR d'un utilisateur, `kubectl certificate approve`, kubeconfig |
| https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/ | ServiceAccount, `kubectl create token`, montage du jeton |
| https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/ | dépôt pkgs.k8s.io, paquets, prérequis des nœuds |
| https://kubernetes.io/docs/setup/production-environment/container-runtimes/ | modules, sysctl, configuration de containerd (`SystemdCgroup`) |
| https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/ | `kubeadm init`, kubeconfig, CNI, `join` |
| https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/ | control plane HA, `--control-plane-endpoint`, `--upload-certs` |
| https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/ | mise à jour pas à pas, ordre des opérations |
| https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/upgrading-linux-nodes/ | mise à jour d'un worker |
| https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/ | `kubeadm certs check-expiration`, `renew` |
| https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/ | `etcdctl snapshot save`, `etcdutl snapshot restore`, options TLS |
| https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/ | CRD complète : schéma, `additionalPrinterColumns`, sous-ressources |
| https://kubernetes.io/docs/concepts/extend-kubernetes/operator/ | patron opérateur |
| https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/ | `kustomization.yaml`, générateurs, overlays, `kubectl apply -k` |
| https://kubernetes.io/docs/concepts/containers/runtime-class/ | RuntimeClass |
| https://helm.sh/docs/intro/using_helm/ | `helm repo add`, `install`, `upgrade`, `rollback`, `--set` |
| https://helm.sh/docs/helm/helm_install/ et https://helm.sh/docs/helm/helm_upgrade/ | toutes les options |

La politique de décalage des versions (*Version Skew Policy*) est publiée à l'adresse https://kubernetes.io/releases/version-skew-policy/, **hors** de `/docs` : elle ne fait pas partie des adresses autorisées. Les règles utiles à une mise à jour sont rappelées dans la page de mise à jour kubeadm, et le chapitre 19.5 te les fait apprendre.

#### Troubleshooting (30 %)

| Page | On y trouve |
|---|---|
| https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/ | pods Pending, en attente, en échec |
| https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/ | méthode complète de dépannage d'un Service |
| https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/ | `kubectl debug`, conteneurs éphémères, copie de pod |
| https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/ | `terminationMessagePath`, raison de l'échec |
| https://kubernetes.io/docs/tasks/debug/debug-cluster/ | dépannage du cluster, journaux des composants |
| https://kubernetes.io/docs/tasks/debug/debug-cluster/crictl/ | `crictl` : `ps`, `logs`, `inspect`, `pods` |
| https://kubernetes.io/docs/tasks/debug/debug-cluster/kubectl-node-debug/ | `kubectl debug node/…`, montage `/host` |
| https://kubernetes.io/docs/concepts/cluster-administration/logging/ | architecture des journaux, rotation |
| https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/ | metrics-server, `kubectl top` |
| https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/ | pods statiques, `staticPodPath` |
| https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/ | tous les champs de `/var/lib/kubelet/config.yaml` |
| https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/ | toutes les options de l'API server |
| https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/ | seuils d'éviction, conditions de pression |

> [!tip] Réflexe d'examen : la documentation hors ligne d'abord
> `k explain deploy.spec.strategy.rollingUpdate` répond en une seconde là où Firefox en demande vingt. `k create ingress -h`, `k create role -h`, `k run -h` affichent des exemples prêts à adapter. `man` est aussi disponible sur les hôtes. Garde Firefox pour ce que kubectl ne génère pas : PersistentVolume, NetworkPolicy, StorageClass, HTTPRoute, CRD, sondes.

### 24.8 killer.sh

Toute inscription au CKA (hors `CKA-SINGLE`) comprend deux sessions du simulateur killer.sh, à activer depuis la liste de préparation de l'examen. Les deux sessions sont différentes : l'une ouvre le jeu de questions CKA-A, l'autre le jeu CKA-B, dix-sept questions chacun. Une session activée reste accessible **36 heures d'affilée**, d'horloge et pas d'utilisation : elle ne se fractionne pas sur plusieurs jours. Le simulateur reproduit le bureau distant de l'examen (XFCE, terminal, Firefox), avec trois différences : on y accède par un navigateur ordinaire, son Firefox n'est pas restreint aux sites autorisés, et on peut y basculer vers un terminal simple, ce que l'examen ne permet pas. Après la fin du compte à rebours, la note et les solutions détaillées s'affichent, et l'environnement reste disponible jusqu'au terme des 36 heures : on peut redémarrer la session (« Restart Session ») pour tout recommencer.

Les questions de killer.sh sont réputées plus longues et plus difficiles que celles de l'examen ; une note modeste au premier passage n'annonce donc pas un échec. Leur valeur tient à trois choses : l'interface identique, le chronomètre, et des solutions qui montrent souvent une méthode plus rapide que la tienne. Pour en tirer le maximum :

| Moment | Quoi | Pourquoi |
|---|---|---|
| Après le chapitre 23 et l'examen blanc de l'annexe B | session A, en conditions réelles : 2 heures, sans les solutions | mesurer, pas apprendre |
| Dans les 36 heures qui suivent | refaire chaque question ratée, puis lire **toutes** les solutions, même des questions réussies | les solutions contiennent les raccourcis |
| Les jours suivants | retravailler les chapitres des questions ratées ; refaire les exercices correspondants | combler les vrais trous |
| Une semaine avant l'examen environ | session B, en conditions réelles | vérifier le progrès et le rythme |
| Dans les 36 heures qui suivent | refaire toute la session B une seconde fois, chronomètre en main | automatiser les gestes |

### 24.9 La veille et le jour J

#### La veille

La veille ne sert plus à apprendre. Elle sert à supprimer toutes les causes d'échec qui ne tiennent pas à Kubernetes. Vérifie, dans l'ordre :

```
Liste de contrôle de la veille :
════════════════════════════════

  [ ] Le poste : ordinateur personnel plutôt que professionnel (les
      postes d'entreprise bloquent souvent le navigateur sécurisé),
      pas de machine virtuelle, un seul écran, webcam orientable,
      micro, alimentation branchée
  [ ] La vérification système de PSI ("PSI Online Proctoring System
      Check") passée sur CE poste et CE réseau
  [ ] Le tutoriel PSI fait : navigateur sécurisé installé et testé
  [ ] Le réseau : filaire de préférence, pas de VPN ni de proxy,
      personne d'autre qui télécharge ou diffuse ; accès HTTPS aux
      points de terminaison AWS S3 (*.s3.amazonaws.com) non bloqué
  [ ] La pièce : fermée, calme, éclairée de face, bureau vide,
      rien sous le bureau, murs sans papiers affichés
  [ ] La pièce d'identité : originale, valide, nom identique à celui
      de la liste de préparation
  [ ] Une bouteille transparente sans étiquette, de l'eau
      (seuls les liquides clairs sont admis)
  [ ] L'heure de l'examen, dans le bon fuseau, relue sur le portail
  [ ] Les antivirus et logiciels de synchronisation prêts à être
      arrêtés ; les droits pour fermer des processus sur le poste
  [ ] Une nuit complète. Rien de neuf à apprendre ce soir.
```

#### Le jour J

Trente minutes avant l'heure, clique sur « Take Exam » dans le portail de la Linux Foundation : tu es redirigé vers le tableau de bord de PSI, où « Start My Test » lance le téléchargement ou l'ouverture du navigateur sécurisé. L'accueil se fait seul d'abord : le navigateur cherche les programmes et matériels interdits, te fait accepter le règlement, photographier ta pièce d'identité, puis prendre un selfie. Un agent d'accueil te demande ensuite de filmer la pièce et le bureau, puis te confie à un surveillant qui libère l'examen. L'attente avant un agent ne devrait pas dépasser quinze minutes ; en cas de problème, le bouton de discussion en direct (*Live Chat*) joint le support technique.

Pendant l'examen, tu ne parles qu'au surveillant, tu ne lis pas les énoncés à voix haute, tu restes dans le champ de la caméra, tu ne manges pas, tu ne portes ni écouteurs ni montre connectée. Le surveillant peut t'envoyer un message dans le chat de l'interface : réponds-y, puis reprends.

Les premières minutes de l'examen fixent le rythme. Masque la visite guidée de l'interface si tu la connais (le chronomètre démarre à ce moment), ouvre VSCodium ou un fichier de suivi sur `base`, colle-y la ligne de réglages de la section 24.3, et commence la tâche 1. Ne lis pas tout l'examen d'abord. Applique les trois passes, et respecte le plafond de chaque tâche.

#### Après

Le résultat arrive par courriel dans les 24 heures, et sur le portail. La Linux Foundation ne communique pas le détail par tâche. En cas d'échec, la seconde tentative est comprise dans l'inscription : elle se planifie comme la première, dans les 12 mois qui suivent l'inscription. Reprends alors ta liste de suivi de mémoire, note les domaines qui t'ont résisté, refais les exercices et les pannes correspondants, puis refais l'examen blanc de l'annexe B avant de réserver.

### 24.10 Pièges courants

```
Piège 1 : Commencer une tâche sans l'encadré
════════════════════════════════════════════
  MAUVAIS : "je suis déjà sur le bon hôte", et la tâche 6 se fait
            sur le cluster de la tâche 5.
  SYMPTÔME : aucun, avant la note.
  BON      : coller la commande ssh (ou use-context) de CHAQUE tâche,
             puis lire le prompt.

Piège 2 : Oublier de revenir sur base
═════════════════════════════════════
  MAUVAIS : ssh hôte-B depuis hôte-A.
  SYMPTÔME : échec de connexion (ssh imbriqué non pris en charge),
             ou travail fait au mauvais endroit.
  BON      : exit en fin de tâche ; DEUX exit après sudo -i ;
             le nom d'hôte base dans le prompt fait foi.

Piège 3 : kubectl en root
═════════════════════════
  MAUVAIS : sudo -i, puis kubectl get nodes
  SYMPTÔME : "The connection to the server localhost:8080 was refused"
  CAUSE    : pas de /root/.kube/config.
  BON      : kubectl sous ton utilisateur ; sudo seulement pour
             crictl, systemctl, les fichiers de /etc/kubernetes.

Piège 4 : La redirection sous sudo
══════════════════════════════════
  MAUVAIS : sudo etcdctl … member list > /opt/sortie/membres.txt
  SYMPTÔME : "Permission denied" : la redirection est faite par
             ton shell, pas par sudo.
  BON      : sudo etcdctl … member list | sudo tee /opt/sortie/membres.txt

Piège 5 : Le .vimrc naïf
════════════════════════
  MAUVAIS : echo "set et ts=2 sw=2" > ~/.vimrc
  SYMPTÔME : plus de greffon YAML ; selon la distribution, plus de
             coloration non plus.
  CAUSE    : un ~/.vimrc désactive le chargement de defaults.vim.
  BON      : unlet! skip_defaults_vim
             source $VIMRUNTIME/defaults.vim   en tête du fichier.

Piège 6 : L'acharnement
═══════════════════════
  MAUVAIS : 25 minutes sur une tâche à 5 %.
  SYMPTÔME : trois tâches faciles jamais commencées.
  BON      : plafond de 8 à 10 minutes en première passe ; noter,
             laisser la tâche à moitié faite, passer à la suivante.

Piège 7 : Vérifier l'existence au lieu du fonctionnement
════════════════════════════════════════════════════════
  MAUVAIS : "le Service existe, c'est bon".
  SYMPTÔME : sélecteur faux, aucune EndpointSlice prête, 0 point.
  BON      : tester l'effet : endpoints, curl, auth can-i, Ready, Bound.

Piège 8 : Le fichier de sortie au mauvais endroit
═════════════════════════════════════════════════
  MAUVAIS : écrire ~/reponse.txt sur base, ou dans /root après sudo -i,
            alors que l'énoncé demande /chemin/absolu sur l'hôte.
  BON      : le chemin exact de l'énoncé, sur l'hôte de la tâche ;
             cat pour vérifier contenu et format.
```

> [!summary] À retenir
> - Une tâche, un hôte : on colle la commande de l'encadré au début de chaque tâche, on lit le prompt, on revient sur `base` par `exit` (deux fois après `sudo -i`). Le ssh imbriqué n'est pas pris en charge ; on ne redémarre jamais `base`.
> - Sur les hôtes SSH, `kubectl`, l'alias `k`, la complétion Bash, `yq`, `curl`, `wget` et `man` sont prêts ; sur `base`, rien. Ce qu'on configure ne vaut que pour l'hôte et l'utilisateur courants.
> - Les seuls réglages rentables : `export do="--dry-run=client -o yaml" now="--force --grace-period=0"` et un `.vimrc` qui commence par charger `defaults.vim`, préparés une fois et collés sur chaque hôte.
> - `Ctrl+Shift+C` et `Ctrl+Shift+V` dans le terminal, `Ctrl+Alt+W` au lieu de `Ctrl+W`, pas de touche `Inser`.
> - Trois passes calées sur les alertes de 30, 15 et 5 minutes ; un plafond de 8 à 10 minutes par tâche en première passe ; une liste de suivi tenue dans un fichier de `base`.
> - Une tâche n'est finie que vérifiée : l'objet existe, il fonctionne, son état tient ; on relit l'énoncé avant `exit`.
> - Garder `kubectl` hors de root, passer la redirection par `sudo tee`, écrire les fichiers au chemin exact de l'énoncé, sur l'hôte de la tâche.
> - Connaître les pages de documentation par domaine, et préférer `kubectl explain` et `-h` quand ils suffisent.
> - killer.sh : session A après le cours, session B une semaine avant ; chaque session dure 36 heures d'affilée.

### 24.11 Exercices

#### Exercice 24.1 — Préparer un hôte en deux minutes

**Point de départ** : instantané I4 (le cluster n'est pas modifié par cet exercice).

Simule l'arrivée sur un hôte d'examen vierge : un shell Bash sans fichier de démarrage, avec un répertoire personnel vide, mais qui sait joindre le cluster du lab. Dans ce shell, en moins de deux minutes chronomètre en main : définis l'alias `k` (présent à l'examen, absent ici), les variables `do` et `now`, écris le `.vimrc` de la section 24.3, génère avec `k` et `$do` le manifeste d'un pod `essai` (image `busybox:1.37.0`) dans `essai.yaml`, ouvre-le dans vim et vérifie les options d'indentation. Quitte enfin ce shell.

> [!example]- Solution
> ```bash
> # Préparation (hors chronomètre) : un shell vierge qui garde l'accès au cluster
> export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
> env HOME="$(mktemp -d)" bash --noprofile --norc
> cd
>
> # Chronomètre : la ligne à coller sur chaque hôte (alias k en plus, ici)
> alias k=kubectl
> export do="--dry-run=client -o yaml" now="--force --grace-period=0"
> cat > ~/.vimrc <<'EOF'
> unlet! skip_defaults_vim
> source $VIMRUNTIME/defaults.vim
> set expandtab shiftwidth=2 softtabstop=2 tabstop=2 autoindent
> set mouse=
> EOF
>
> k run essai --image=busybox:1.37.0 $do > essai.yaml
> vim essai.yaml        # puis  :set et? sw? ts? mouse?   et  :q
> exit
> ```
>
> `env HOME=… bash --noprofile --norc` reproduit un hôte où rien ne t'appartient encore : pas de `.bashrc`, pas de `.vimrc`, pas d'alias. On exporte `KUBECONFIG` avant de changer `HOME`, sinon kubectl chercherait `~/.kube/config` dans le nouveau répertoire vide. À l'examen, l'alias `k` et la complétion sont déjà là : ta ligne à coller se réduit à l'`export` et au `.vimrc`. Écris ces lignes une fois dans un éditeur, puis colle-les ; c'est ce geste que l'exercice entraîne.
>
> **Vérification** : `head -3 essai.yaml` affiche `apiVersion: v1`, `kind: Pod`, `metadata:` (et aucun pod `essai` n'existe dans le cluster : `kubectl get pod essai` répond `NotFound`, puisque `--dry-run=client` n'envoie rien à l'API). Dans vim, `:set et? sw? ts? mouse?` affiche `expandtab  shiftwidth=2  tabstop=2  mouse=`. Après `exit`, tu es revenu dans ton shell habituel, et le répertoire temporaire n'est plus utilisé.

#### Exercice 24.2 — Chronométrage : cinq tâches en vingt minutes

**Point de départ** : instantané I4.

Avant de lancer le chronomètre, crée le namespace `chrono` et le dossier `~/cka/chrono/` sur ton poste. Puis enchaîne les cinq tâches suivantes en **vingt minutes** au total, en tenant une liste de suivi, et en vérifiant chaque tâche avant de passer à la suivante. Note le temps passé sur chacune.

| N° | Pts | Domaine | Tâche |
|---|---|---|---|
| T1 | 4 | Troubleshooting | Écris dans `~/cka/chrono/t1.txt`, sur ton poste, une ligne `<nom du pod> <nœud>` par pod du namespace `boutique` portant le label `tier=web`, triée par nom de pod, sans ligne d'en-tête. |
| T2 | 6 | Workloads | Dans `chrono`, crée le Deployment `horloge` : image `busybox:1.37.0`, 2 réplicas, commande `sh -c 'while true; do date; sleep 5; done'`, requests `cpu: 10m` et `memory: 16Mi`. Ajoute-lui ensuite la variable d'environnement `TZ=Europe/Paris` sans le recréer : l'historique doit compter deux révisions. |
| T3 | 6 | Networking | Dans `chrono`, crée le Deployment `echo` (image `registry.k8s.io/e2e-test-images/agnhost:2.66.1`, commande `/agnhost netexec --http-port=8080`, 2 réplicas, port 8080) et expose-le par un Service NodePort `echo-np` sur le port 8080, nodePort `30180`. Le chemin `/hostname` doit répondre depuis ton poste sur `http://<IP de cka>:30180/hostname`. |
| T4 | 5 | Storage | Dans `chrono`, crée la PersistentVolumeClaim `brouillon` (100Mi, `ReadWriteOnce`, StorageClass `rapide`) et le pod `ecrivain` (`busybox:1.37.0`) qui la monte en `/data`, écrit `chrono` dans `/data/preuve.txt`, puis dort une heure. |
| T5 | 5 | Architecture | Sur le nœud `cka`, écris dans `/opt/chrono/t5.txt` la date d'expiration du certificat `apiserver`, telle que l'affiche `kubeadm certs check-expiration` (par exemple `Oct 22, 2029 18:16 UTC`). |

Note-toi sur 26 points. Seuil de confort : 20 points en vingt minutes. En dessous, refais l'exercice deux jours plus tard (après `kubectl delete namespace chrono`).

> [!example]- Solution
> **Préparation** (hors chronomètre) :
>
> ```bash
> kubectl create namespace chrono
> mkdir -p ~/cka/chrono
> ```
>
> **T1** (cible : 2 minutes).
>
> ```bash
> kubectl -n boutique get pods -l tier=web --sort-by=.metadata.name --no-headers \
>   -o custom-columns=NOM:.metadata.name,NOEUD:.spec.nodeName > ~/cka/chrono/t1.txt
> cat ~/cka/chrono/t1.txt
> ```
>
> `--no-headers` supprime la ligne d'en-tête qu'ajoute `custom-columns`, `--sort-by` trie sur le nom. Les colonnes sont séparées par des espaces, ce que tolère un format « `<nom> <nœud>` » ; si l'énoncé exigeait un seul espace exact, on passerait par `-o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}'`, trié par `--sort-by`.
>
> **Vérification** : quatre lignes triées par nom, trois pods `front-…` et un pod `front-v2-…`, chacun suivi du nom de son nœud ; `kubectl -n boutique get pods -l tier=web -o wide` permet de comparer.
>
> **T2** (cible : 4 minutes).
>
> ```bash
> kubectl -n chrono create deployment horloge --image=busybox:1.37.0 --replicas=2 \
>   --dry-run=client -o yaml -- sh -c 'while true; do date; sleep 5; done' \
>   | kubectl set resources -f - --local --requests=cpu=10m,memory=16Mi -o yaml \
>   | kubectl apply -f -
> kubectl -n chrono rollout status deployment/horloge
> kubectl -n chrono set env deployment/horloge TZ=Europe/Paris
> kubectl -n chrono rollout status deployment/horloge
> ```
>
> `kubectl create deployment … -- sh -c '…'` place la commande dans `command`. `kubectl set resources --local` modifie le manifeste qui passe dans le tube sans contacter l'API : le Deployment naît avec ses requests, en une seule révision. `kubectl set env` modifie ensuite le modèle de pod, ce qui déclenche un déploiement progressif et crée la révision 2. Créer d'abord puis appeler `set resources` sur l'objet vivant aurait produit trois révisions.
>
> **Vérification** :
>
> ```bash
> kubectl -n chrono rollout history deployment/horloge
> kubectl -n chrono get deployment horloge -o jsonpath='{.spec.template.spec.containers[0].env}{"\n"}{.spec.template.spec.containers[0].resources}{"\n"}'
> ```
>
> L'historique liste les révisions `1` et `2` ; la seconde commande affiche `[{"name":"TZ","value":"Europe/Paris"}]` puis `{"requests":{"cpu":"10m","memory":"16Mi"}}`.
>
> **T3** (cible : 4 minutes).
>
> ```bash
> kubectl -n chrono create deployment echo --image=registry.k8s.io/e2e-test-images/agnhost:2.66.1 \
>   --replicas=2 --port=8080 -- /agnhost netexec --http-port=8080
> kubectl -n chrono expose deployment echo --name=echo-np --type=NodePort --port=8080
> kubectl -n chrono patch service echo-np -p '{"spec":{"ports":[{"port":8080,"nodePort":30180}]}}'
> kubectl -n chrono rollout status deployment/echo
> ```
>
> `kubectl expose` reprend le sélecteur du Deployment (`app: echo`). Le piège de cette tâche est `kubectl create service nodeport echo-np --tcp=8080:8080 --node-port=30180` : la commande paraît faite pour cela, mais elle pose le sélecteur `app: echo-np`, qui ne correspond à aucun pod. `expose` n'ayant pas d'option de nodePort, on fixe celui-ci par un patch stratégique : la liste `ports` d'un Service est fusionnée sur la clé `port`, si bien que seul le `nodePort` de l'entrée 8080 change.
>
> **Vérification** :
>
> ```bash
> kubectl -n chrono get endpointslices -l kubernetes.io/service-name=echo-np
> curl -s http://$(minikube -p cka ip):30180/hostname; echo
> ```
>
> L'EndpointSlice liste deux adresses de pods ; `curl` affiche le nom d'un des pods `echo-…` (relance-le : le nom peut changer d'un appel à l'autre au gré de la répartition). Lancé dans la seconde qui suit la création du Service, le premier `curl` peut ne rien afficher (un échec, que `-s` rend muet) : kube-proxy n'a pas encore programmé le NodePort ; relance-le.
>
> **T4** (cible : 4 minutes). Le manifeste s'inspire de la page « Configure a Pod to Use a PersistentVolume for Storage » ; enregistre-le dans `~/cka/chrono/t4.yaml` (par exemple en le collant dans `cat > ~/cka/chrono/t4.yaml <<'EOF'` … `EOF`) :
>
> ```yaml
> apiVersion: v1
> kind: PersistentVolumeClaim
> metadata:
>   name: brouillon
>   namespace: chrono
> spec:
>   accessModes: ["ReadWriteOnce"]
>   storageClassName: rapide
>   resources:
>     requests:
>       storage: 100Mi
> ---
> apiVersion: v1
> kind: Pod
> metadata:
>   name: ecrivain
>   namespace: chrono
> spec:
>   containers:
>   - name: ecrivain
>     image: busybox:1.37.0
>     command: ["sh", "-c", "echo chrono > /data/preuve.txt && sleep 3600"]
>     volumeMounts:
>     - name: donnees
>       mountPath: /data
>   volumes:
>   - name: donnees
>     persistentVolumeClaim:
>       claimName: brouillon
> ```
>
> ```bash
> kubectl apply -f ~/cka/chrono/t4.yaml
> kubectl -n chrono wait --for=condition=Ready pod/ecrivain --timeout=2m
> ```
>
> La StorageClass `rapide` est en `WaitForFirstConsumer` (chapitre 15.6) : la PVC reste `Pending` tant que le pod n'est pas planifié, puis le pilote CSI crée le volume sur le nœud choisi. Un `Pending` juste après la création de la seule PVC n'est donc pas une erreur ; il le devient si le pod est lui-même planifié et que la PVC ne se lie toujours pas.
>
> **Vérification** :
>
> ```bash
> kubectl -n chrono get pvc brouillon
> kubectl -n chrono exec ecrivain -- cat /data/preuve.txt
> ```
>
> La PVC est `Bound`, de capacité `100Mi`, classe `rapide` ; la seconde commande affiche `chrono`.
>
> **T5** (cible : 4 minutes). On travaille comme à l'examen : connexion interactive au nœud, `sudo` pour ce qui l'exige, `exit` à la fin.
>
> ```bash
> minikube -p cka ssh
> sudo /var/lib/minikube/binaries/v1.37.0/kubeadm certs check-expiration \
>   --cert-dir /var/lib/minikube/certs | grep '^apiserver '
> sudo mkdir -p /opt/chrono
> sudo /var/lib/minikube/binaries/v1.37.0/kubeadm certs check-expiration \
>   --cert-dir /var/lib/minikube/certs \
>   | awk '$1 == "apiserver" {print $2, $3, $4, $5, $6}' | sudo tee /opt/chrono/t5.txt
> exit
> ```
>
> Trois pièges en une tâche. Sur le lab, `kubeadm` est hors du `PATH` et sa commande échoue sans `--cert-dir` (ou `--config /var/tmp/minikube/kubeadm.yaml`), parce qu'elle cherche `/etc/kubernetes/pki/ca.crt` (chapitre 19.7.1) ; sur un cluster d'examen, `sudo kubeadm certs check-expiration` suffit. `/opt` appartient à root : `mkdir` exige `sudo`, et l'écriture passe par `sudo tee`, car un `sudo … > /opt/chrono/t5.txt` ferait la redirection avec tes droits. Enfin `grep '^apiserver '`, avec l'espace, isole la ligne `apiserver` des lignes `apiserver-etcd-client` et `apiserver-kubelet-client` ; `awk` fait de même en comparant le premier champ.
>
> **Vérification** : `minikube -p cka ssh -- sudo cat /opt/chrono/t5.txt` affiche une date de la forme `Oct 22, 2029 18:16 UTC`, 26 280 heures (1 095 jours) après la création de ton cluster : le certificat `apiserver` du lab est émis pour 3 ans par minikube, contre 1 an sous kubeadm.
>
> **Notation** : T1 4 points (fichier au bon chemin 1, quatre lignes 1, format 1, tri 1) ; T2 6 points (Deployment et image 1, réplicas 1, commande 1, requests 1, variable 1, deux révisions 1) ; T3 6 points (Deployment 2, Service NodePort au bon sélecteur 2, nodePort 30180 1, réponse de `/hostname` 1) ; T4 5 points (PVC conforme 2, `Bound` 1, pod `Running` 1, fichier écrit 1) ; T5 5 points (fichier au bon chemin 2, date exacte 3).
>
> **Remise en état** (le cluster revient à I4) :
>
> ```bash
> kubectl delete namespace chrono
> minikube -p cka ssh -- sudo rm -rf /opt/chrono
> ```
>
> La suppression du namespace emporte la PVC `brouillon`, et avec elle son volume, puisque la classe `rapide` a la politique de récupération `Delete`. Garde `~/cka/chrono/` si tu veux comparer tes temps d'une tentative à l'autre.

---
