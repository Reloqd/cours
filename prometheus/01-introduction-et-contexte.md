## 1. Introduction et contexte

### 1.1 Qu'est-ce que Prometheus ?

Prometheus est un systeme de monitoring et d'alerting open source concu pour la fiabilite. Il collecte des metriques numeriques horodatees, les stocke dans une base de donnees de series temporelles (TSDB), et fournit un langage de requete puissant (PromQL) pour les exploiter.

En tant que DevOps, tu utilises Prometheus pour repondre a des questions comme :
- Quel est le taux de requetes HTTP 5xx sur mon API depuis 5 minutes ?
- Combien de memoire consomme chaque conteneur Docker ?
- A quelle vitesse mon disque se remplit-il, et quand sera-t-il plein ?
- Quel pourcentage de mes pods Kubernetes sont en etat CrashLoopBackOff ?

Prometheus ne se contente pas de collecter : il evalue des regles en continu et declenche des alertes quand les conditions que tu definis sont remplies. C'est le coeur du monitoring pour la majorite des infrastructures cloud-native.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    PROMETHEUS - VUE D'ENSEMBLE                          │
│                                                                         │
│    ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐             │
│    │  Node    │  │  App     │  │ Kube-    │  │  MySQL   │             │
│    │ Exporter │  │ /metrics │  │ State    │  │ Exporter │             │
│    │ :9100    │  │ :8080    │  │ Metrics  │  │ :9104    │             │
│    └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘             │
│         │             │             │             │                     │
│         │   HTTP GET /metrics (pull)│             │                     │
│         │             │             │             │                     │
│         ▼             ▼             ▼             ▼                     │
│    ┌───────────────────────────────────────────────────┐               │
│    │              PROMETHEUS SERVER                     │               │
│    │                                                    │               │
│    │  ┌──────────┐  ┌──────────┐  ┌──────────────┐    │               │
│    │  │ Scraper  │  │  TSDB    │  │ Rule Engine  │    │               │
│    │  │          │  │          │  │              │    │               │
│    │  │ Collecte │  │ Stocke   │  │ Evalue les   │    │               │
│    │  │ pull     │  │ series   │  │ recording &  │    │               │
│    │  │ /metrics │  │ tempo-   │  │ alerting     │    │               │
│    │  │          │  │ relles   │  │ rules        │    │               │
│    │  └──────────┘  └──────────┘  └──────┬───────┘    │               │
│    │                                      │            │               │
│    │  ┌──────────┐  ┌──────────────┐     │            │               │
│    │  │ HTTP     │  │ Remote Write │     │            │               │
│    │  │ API      │  │              │     │            │               │
│    │  │ PromQL   │  │ Vers Mimir,  │     │            │               │
│    │  │ /query   │  │ Thanos, etc. │     │            │               │
│    │  └────┬─────┘  └──────┬───────┘     │            │               │
│    └───────┼───────────────┼─────────────┼────────────┘               │
│            │               │             │                             │
│            ▼               ▼             ▼                             │
│       ┌─────────┐   ┌──────────┐  ┌──────────────┐                   │
│       │ Grafana │   │  Mimir   │  │ Alertmanager │                   │
│       │         │   │  (long   │  │              │                   │
│       │ Dash-   │   │  term)   │  │ Route, group │                   │
│       │ boards  │   │          │  │ silence, send│                   │
│       └─────────┘   └──────────┘  └──────┬───────┘                   │
│                                           │                           │
│                                           ▼                           │
│                                    ┌─────────────┐                    │
│                                    │ Slack/Email/ │                    │
│                                    │ PagerDuty/   │                    │
│                                    │ Discord      │                    │
│                                    └─────────────┘                    │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Historique

```
Timeline :

2012 ──── Prometheus cree chez SoundCloud par Matt T. Proud et Julius Volz
   │      - Inspire par Borgmon, le systeme de monitoring interne de Google
   │      - Besoin : monitorer une architecture microservices dynamique
   │      - Les solutions existantes (Nagios, Graphite) ne suffisent plus
   │
2013 ──── Premiere release open source
   │      - Adoption rapide dans la communaute
   │
2015 ──── Utilisation croissante (Docker, CoreOS, DigitalOcean)
   │
2016 ──── Prometheus rejoint la CNCF comme 2e projet (apres Kubernetes)
   │      - Signal fort : le monitoring cloud-native a un standard
   │      - Release de Prometheus 1.0
   │
2017 ──── Prometheus 2.0
   │      - Nouvelle TSDB (ecrite par Fabian Reinartz)
   │      - Performance multipliee par 10 en ecriture
   │      - Consommation memoire divisee par 3
   │      - Format de stockage sur disque completement reecrit
   │
2018 ──── Prometheus devient le 2e projet "Graduated" de la CNCF
   │      (apres Kubernetes)
   │
2019-2023  Stabilite, adoption massive, ecosysteme mature
   │      - Exporters pour tout
   │      - kube-prometheus-stack devient le standard K8s
   │      - Thanos et Cortex pour le long terme
   │      - Mimir (Grafana Labs) comme alternative a Cortex
   │
2024 ──── Prometheus 3.0
   │      - Nouvelle UI (React)
   │      - Support natif d'OTLP (reception de metriques OTel)
   │      - Support natif d'UTF-8 dans les noms de metriques
   │      - Nouveau parseur PromQL plus performant
   │      - Remote write v2 (protobuf optimise)
   │
2025 ──── Prometheus 3.4.1 (version actuelle de ton homelab)
          - Maturite du support OTLP
          - Ameliorations continues de la TSDB
          - CreatedTimestamp pour les counters
```

### 1.3 Positionnement dans l'ecosysteme

Prometheus n'est pas seul sur le marche du monitoring. Voici comment il se positionne :

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    ECOSYSTEME DU MONITORING                             │
│                                                                         │
│  Open Source, Self-Hosted              SaaS / Managed                   │
│  ─────────────────────────             ──────────────                   │
│                                                                         │
│  ┌─────────────────────┐              ┌──────────────────┐             │
│  │ Prometheus          │              │ Datadog          │             │
│  │ + Grafana           │              │                  │             │
│  │ Pull-based, TSDB    │              │ SaaS complet     │             │
│  │ Standard de facto   │              │ Agent push       │             │
│  │ cloud-native        │              │ Tres cher a      │             │
│  └─────────────────────┘              │ l'echelle        │             │
│                                        └──────────────────┘             │
│  ┌─────────────────────┐              ┌──────────────────┐             │
│  │ VictoriaMetrics     │              │ New Relic        │             │
│  │                     │              │                  │             │
│  │ Compatible PromQL   │              │ SaaS, free tier  │             │
│  │ Meilleure perf que  │              │ genereux         │             │
│  │ Prometheus natif    │              │                  │             │
│  └─────────────────────┘              └──────────────────┘             │
│                                                                         │
│  ┌─────────────────────┐              ┌──────────────────┐             │
│  │ Mimir (Grafana)     │              │ CloudWatch (AWS) │             │
│  │                     │              │                  │             │
│  │ Prometheus long     │              │ Natif AWS        │             │
│  │ terme, multi-tenant │              │ Pousse les       │             │
│  │ Stockage objet S3   │              │ metriques auto   │             │
│  └─────────────────────┘              └──────────────────┘             │
│                                                                         │
│  ┌─────────────────────┐              ┌──────────────────┐             │
│  │ InfluxDB            │              │ Grafana Cloud    │             │
│  │                     │              │                  │             │
│  │ TSDB generique      │              │ Prometheus       │             │
│  │ Push-based           │              │ manage par       │             │
│  │ Son propre langage  │              │ Grafana Labs     │             │
│  │ (Flux/InfluxQL)     │              │ (base sur Mimir) │             │
│  └─────────────────────┘              └──────────────────┘             │
└─────────────────────────────────────────────────────────────────────────┘
```

**Pourquoi Prometheus reste le standard** :
- Gratuit et open source, pas de couts par serie/host/conteneur
- PromQL est devenu le langage de requete universel (meme VictoriaMetrics, Mimir, Thanos l'utilisent)
- Ecosysteme massif d'exporters (400+)
- Integration native avec Kubernetes
- Communaute enorme, documentation abondante
- Simplicite operationnelle : un seul binaire, pas de dependances externes

### 1.4 Architecture pull-based vs push-based

C'est la difference fondamentale entre Prometheus et la plupart des autres systemes de monitoring.

```
PULL (Prometheus) :
═══════════════════

  Le serveur Prometheus va CHERCHER les metriques chez chaque target.
  Les targets exposent un endpoint HTTP /metrics.

  ┌──────────┐     GET /metrics      ┌──────────────┐
  │  Target  │◀─────────────────────│  Prometheus  │
  │  :9100   │                       │              │
  │          │─────────────────────▶│  "Je viens   │
  │ /metrics │   Reponse: metriques │   chercher"  │
  └──────────┘     en texte clair    └──────────────┘

  Avantages :
  - Prometheus controle la frequence de collecte
  - Debug facile : curl http://target:9100/metrics
  - Si une target est down, Prometheus le detecte (up == 0)
  - Pas besoin de configurer les targets pour pousser
  - Pas de surcharge : Prometheus decide du rythme

PUSH (Datadog, InfluxDB, OTel) :
═════════════════════════════════

  Chaque application ENVOIE ses metriques vers un collecteur central.

  ┌──────────┐     POST metriques    ┌──────────────┐
  │  App     │─────────────────────▶│  Collecteur  │
  │          │                       │              │
  │  Agent   │   "Je te les envoie" │  (Datadog,   │
  │  SDK     │                       │   InfluxDB)  │
  └──────────┘                       └──────────────┘

  Avantages :
  - Fonctionne derriere un NAT/firewall
  - Adapte aux jobs ephemeres (batch, serverless)
  - L'application controle ce qu'elle envoie
```

| Critere | Pull (Prometheus) | Push (Datadog, InfluxDB) |
|---------|-------------------|--------------------------|
| **Qui initie** | Le serveur de monitoring | L'application monitoree |
| **Firewall** | Prometheus doit atteindre les targets | Les targets doivent atteindre le collecteur |
| **Jobs courts** | Problematique (Pushgateway necessaire) | Natif |
| **Debug** | `curl /metrics` direct | Besoin de logs/traces |
| **Decouverte** | Service discovery cote serveur | Configuration cote client |
| **Surcharge** | Le serveur controle le rythme | Risque de surcharge si trop de clients |
| **Haute dispo** | 2 Prometheus qui scrapent = simple | 2 collecteurs = config client plus complexe |

**Note importante pour ton homelab** : Tu utilises deja OTel Collector avec remote write vers Prometheus. C'est du **push** vers Prometheus. Prometheus v3.x supporte nativement le remote write en reception, ce qui combine le meilleur des deux mondes : tes applications instrumentees avec OTel poussent vers le Collector, qui pousse vers Prometheus, tandis que Prometheus peut aussi scraper directement des exporters classiques.

---
