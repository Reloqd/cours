# Lab du cours CKA

Scripts du lab minikube du cours (Kubernetes v1.37.0, minikube v1.39.0, profil `cka`).
Le mode d'emploi détaillé, le contenu des instantanés et le dépannage sont dans
l'annexe C du cours (`../annexe-c-lab.md`).

## Prérequis

Docker utilisable sans sudo, 4 CPU et 12 Gio de RAM libres, `minikube` v1.39.0,
`kubectl` 1.37, `helm` 4.3, `openssl` et `curl` dans le PATH. Sur Linux, relever
la limite inotify avant le premier démarrage :

```bash
sudo sysctl fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288
```

## Scripts

| Script | Rôle |
|---|---|
| `demarrer.sh` | Vérifie les prérequis, démarre le profil et attend les nœuds (instantané I0). |
| `restaurer.sh <I0…I4> [--oui]` | Supprime le profil, le recrée et rejoue `etats/NN-*/appliquer.sh` jusqu'à l'instantané. |
| `etats/NN-*/` | Manifestes et `appliquer.sh` de l'état laissé par les exercices du chapitre NN. |
| `pannes.sh liste \| casser NN \| verifier NN` | Pannes 01 à 19 des chapitres 22 et 23, à injecter depuis I4. |
| `examen-blanc/preparer.sh [14\|15]` | Prépare l'examen blanc de l'annexe B depuis I4 ; `14` et `15` injectent les pannes de ces tâches. |
| `examen-blanc/corriger.sh` | Note chaque tâche et donne le total sur 100 (seuil 66). |

Les états se rejouent **dans l'ordre** : un `appliquer.sh` remet les objets de son
chapitre dans l'état de fin de chapitre, sans tenir compte des chapitres suivants.

Durées mesurées le 23 octobre 2026 (nœuds neufs, images retéléchargées) : I0 de 57 s
à 3 min 51 s, I1 10 min 27 s, I2 7 min 23 s, I3 10 min 09 s, I4 14 min 23 s.
Pour garder un état, préfère `minikube -p cka stop` puis `start` (≈ 2 min : arrêt 1 min 20 s à 1 min 26 s, démarrage 29 s).

## Variables

| Variable | Défaut | Effet |
|---|---|---|
| `CKA_PROFIL` | `cka` | Profil minikube, contexte kubeconfig et préfixe des nœuds. |
| `CKA_DOSSIER` | `~/cka` | Dossier de travail (certificat d'alice dans `rbac/`, réponses de l'examen dans `examen/`). |
| `CKA_FORCER` | `0` | `1` : démarrer malgré une limite inotify trop basse (déconseillé). |

Les scripts visent toujours le contexte `cka` (`kubectl --context`), quel que soit
le contexte courant : tu peux rester sur `alice@cka` ou `boutique` sans gêne.
