## 10. Comparaisons et migrations

### 10.1 OTel vs exporters Prometheus classiques

```
┌──────────────────────────┬────────────────────────────────────────────────┐
│ Critère                  │ Exporters Prometheus  │ OTel Collector         │
├──────────────────────────┼───────────────────────┼────────────────────────┤
│ Modèle                   │ Pull (scrape)         │ Push (OTLP) + Pull     │
│ Signaux                  │ Métriques uniquement  │ Metrics + Traces + Logs│
│ Instrumentation          │ Client Prometheus     │ SDK OTel (vendor-neutre)│
│ Configuration            │ prometheus.yml        │ collector-config.yaml  │
│ Service discovery        │ Natif (K8s, Consul..) │ Via receiver prometheus│
│ Transformation           │ relabel_configs       │ Processors puissants   │
│ Exemplars               │ Supporté (limité)     │ Natif et riche         │
│ Écosystème              │ Mature, stable        │ En croissance rapide   │
│ Overhead                │ Faible                │ Faible à modéré        │
│ Flexibilité backend     │ Prometheus/Mimir only │ N'importe quel backend │
└──────────────────────────┴───────────────────────┴────────────────────────┘
```

**Verdict** : Si tu n'as besoin que de métriques et que tu es satisfait de Prometheus, les exporters classiques restent pertinents. OTel devient nécessaire quand tu veux unifier les trois signaux ou te libérer du vendor lock-in.

### 10.2 OTel vs Datadog Agent / New Relic

```
┌──────────────────────────┬───────────────────┬──────────────────────────┐
│ Critère                  │ Datadog/New Relic │ OTel                     │
├──────────────────────────┼───────────────────┼──────────────────────────┤
│ Coût                     │ Payant (par host/ │ Gratuit (open source)    │
│                          │ par volume)       │ Tu paies le stockage     │
│ Vendor lock-in           │ Fort              │ Aucun                    │
│ Setup                    │ Très simple       │ Plus de configuration    │
│ UI/UX                    │ Excellent, intégré│ Dépend du backend        │
│ APM avancé               │ Code profiling,   │ Traces + métriques,      │
│                          │ error tracking    │ profiling en dev          │
│ Support                  │ 24/7 commercial   │ Communauté + vendors     │
│ Alerting                 │ Intégré           │ Via Grafana/AlertManager │
│ Instrumentation          │ Agent propriétaire│ Standard ouvert          │
│ Multi-cloud              │ Oui               │ Oui                      │
│ On-premise               │ Non (SaaS)        │ Oui                      │
│ Flexibilité              │ Limitée           │ Totale                   │
└──────────────────────────┴───────────────────┴──────────────────────────┘
```

**Verdict** : Datadog et New Relic offrent une expérience clé-en-main avec un coût élevé. OTel offre la liberté et la flexibilité avec plus de travail d'intégration. Beaucoup d'équipes utilisent OTel pour instrumenter et envoyer les données vers Datadog — c'est un bon compromis.

**Note** : Datadog et New Relic acceptent nativement les données OTLP. Tu peux utiliser le SDK/Collector OTel et envoyer vers eux via OTLP, sans utiliser leur agent propriétaire.

### 10.3 OTel vs ELK stack

```
┌──────────────────────────┬───────────────────┬──────────────────────────┐
│ Critère                  │ ELK Stack         │ OTel + Grafana Stack     │
├──────────────────────────┼───────────────────┼──────────────────────────┤
│ Logs                     │ Excellent          │ Bon (Loki)               │
│ Métriques                │ Basique (Metricbeat)│ Excellent (Mimir)       │
│ Traces                   │ Elastic APM        │ Excellent (Tempo)        │
│ Corrélation              │ Bonne (Elastic APM)│ Excellente (Grafana)     │
│ Coût stockage            │ Élevé (ES indexe   │ Faible (Loki n'indexe    │
│                          │ tout)              │ que les labels)          │
│ Requêtes texte           │ Excellent (Lucene) │ Bon (LogQL)              │
│ Collecteur               │ Beats/Logstash     │ OTel Collector           │
│ Mémoire requise          │ Élevée (JVM)       │ Modérée                  │
│ Complexité ops           │ Élevée             │ Modérée                  │
│ Standard ouvert          │ ECS (propriétaire) │ Semantic Conventions     │
└──────────────────────────┴───────────────────┴──────────────────────────┘
```

**Verdict** : ELK excelle en recherche full-text sur les logs. La stack Grafana avec OTel est plus économique et meilleure pour la corrélation des trois signaux. Pour les logs, Loki est beaucoup moins gourmand en stockage qu'Elasticsearch car il n'indexe que les labels, pas le contenu.

### 10.4 Stratégie de migration progressive

La migration vers OTel ne doit **jamais** être un big bang. Voici une approche progressive :

```
PHASE 1 : Collector comme proxy (semaines 1-4)
──────────────────────────────────────────────
Objectif : Introduire le Collector sans modifier les applications

  Apps existantes ── Prometheus scrape ──▶ OTel Collector ──▶ Prometheus/Mimir
  (pas de changement)                      (prometheus         (remote write)
                                            receiver)

  Résultat : Le Collector est déployé et fonctionnel.
  Les équipes se familiarisent avec sa configuration.
  Aucun risque : si le Collector tombe, Prometheus peut scraper directement.


PHASE 2 : Ajout des traces (semaines 5-12)
──────────────────────────────────────────────
Objectif : Instrumenter les services critiques avec OTel pour les traces

  Services critiques ── OTLP traces ──▶ OTel Collector ──▶ Tempo
  (instrumentation OTel)
  
  Prometheus scrape existant continue de fonctionner en parallèle

  Résultat : Premières traces visibles dans Grafana/Tempo.
  Corrélation metrics↔traces via exemplars.


PHASE 3 : Migration des métriques (semaines 12-24)
──────────────────────────────────────────────
Objectif : Remplacer progressivement les clients Prometheus par le SDK OTel

  Service par service :
  1. Ajouter le SDK OTel avec l'exporter OTLP
  2. Garder l'endpoint /metrics Prometheus en parallèle
  3. Vérifier que les métriques arrivent via les deux chemins
  4. Supprimer le client Prometheus

  Résultat : Les métriques transitent via OTel → Collector → Mimir.


PHASE 4 : Unification des logs (semaines 24-36)
──────────────────────────────────────────────
Objectif : Remplacer Promtail par le Collector pour les logs

  1. Déployer le Collector avec le receiver filelog
  2. Vérifier que les logs arrivent dans Loki
  3. Ajouter la corrélation trace_id dans les logs
  4. Retirer Promtail

  Résultat : Un seul agent (OTel Collector) pour les 3 signaux.


PHASE 5 : Optimisation (en continu)
──────────────────────────────────────────────
  - Ajuster le sampling
  - Ajouter des processors (filter, transform)
  - Activer spanmetrics pour les métriques RED automatiques
  - Déployer le tail sampling
  - Auto-instrumentation via l'Operator K8s
```

---
