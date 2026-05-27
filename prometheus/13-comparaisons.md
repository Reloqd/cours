## 13. Comparaisons

### 13.1 Prometheus vs InfluxDB

```
┌─────────────────────────┬───────────────────────────────┐
│      PROMETHEUS         │         INFLUXDB              │
├─────────────────────────┼───────────────────────────────┤
│ Pull-based              │ Push-based                    │
│ (scrape /metrics)       │ (write API)                   │
├─────────────────────────┼───────────────────────────────┤
│ PromQL (fonctionnel)    │ InfluxQL ou Flux              │
│                         │ (SQL-like ou fonctionnel)     │
├─────────────────────────┼───────────────────────────────┤
│ Labels (dimensions)     │ Tags + Fields                 │
│ Tout est un label       │ Tags indexes, fields non      │
├─────────────────────────┼───────────────────────────────┤
│ 4 types de metriques    │ Types flexibles               │
│ (counter, gauge,        │ (int, float, string, bool)    │
│ histogram, summary)     │                               │
├─────────────────────────┼───────────────────────────────┤
│ Optimise monitoring     │ TSDB generique                │
│ et alerting             │ (IoT, analytics, monitoring)  │
├─────────────────────────┼───────────────────────────────┤
│ Open source pur         │ OSS (limite) + Enterprise     │
│ Apache 2.0              │ Le clustering est payant      │
├─────────────────────────┼───────────────────────────────┤
│ Ecosysteme Kubernetes   │ Ecosysteme IoT et analytics   │
│ massif                  │                               │
├─────────────────────────┼───────────────────────────────┤
│ Pas de downsampling     │ Continuous queries             │
│ natif (besoin Thanos/   │ (downsampling integre)        │
│ Mimir)                  │                               │
└─────────────────────────┴───────────────────────────────┘

Verdict : Pour le monitoring d'infrastructure et d'applications
cloud-native, Prometheus est le standard. InfluxDB est meilleur
pour les cas d'usage IoT et analytics generiques.
```

### 13.2 Prometheus vs Datadog / New Relic

```
┌─────────────────────────┬───────────────────────────────┐
│      PROMETHEUS         │     DATADOG / NEW RELIC       │
├─────────────────────────┼───────────────────────────────┤
│ Self-hosted             │ SaaS (manage)                 │
│ Tu geres tout           │ Ils gerent tout               │
├─────────────────────────┼───────────────────────────────┤
│ Gratuit                 │ Payant                        │
│ (cout = infra + temps)  │ (par host, par metrique,      │
│                         │ par million de samples...)    │
├─────────────────────────┼───────────────────────────────┤
│ Metriques only          │ Metriques + Traces + Logs     │
│ (avec Grafana/Loki/     │ + APM + Security + ...        │
│ Tempo pour le reste)    │ Solution integree             │
├─────────────────────────┼───────────────────────────────┤
│ Pull-based              │ Push-based (agent)            │
├─────────────────────────┼───────────────────────────────┤
│ PromQL                  │ Langage proprietaire          │
│ (standard ouvert)       │                               │
├─────────────────────────┼───────────────────────────────┤
│ Communaute open source  │ Support commercial            │
├─────────────────────────┼───────────────────────────────┤
│ Personnalisation totale │ Less flexible mais            │
│ (tu peux tout modifier) │ out-of-the-box               │
├─────────────────────────┼───────────────────────────────┤
│ Pas de vendor lock-in   │ Vendor lock-in fort           │
│ (PromQL universel)      │ (langage/format proprietaire) │
└─────────────────────────┴───────────────────────────────┘

Cout typique Datadog :
- $15/host/mois pour l'infra
- $0.10 par million de metriques custom ingestes
- 100 hosts + metriques custom = facilement $3000+/mois

Cout Prometheus :
- $0 pour le logiciel
- Le cout de l'infra (VM/conteneur) + ton temps

Verdict : Prometheus + Grafana stack pour les equipes qui veulent
le controle et le cout minimal. Datadog/New Relic pour les equipes
qui preferent payer plutot que gerer, ou qui ont besoin d'une
solution tout-en-un sans effort operationnel.
```

### 13.3 Prometheus vs VictoriaMetrics

```
┌─────────────────────────┬───────────────────────────────┐
│      PROMETHEUS         │     VICTORIAMETRICS           │
├─────────────────────────┼───────────────────────────────┤
│ Ecrit en Go             │ Ecrit en Go                   │
│ TSDB custom             │ TSDB optimisee                │
├─────────────────────────┼───────────────────────────────┤
│ Un seul node            │ Single-node OU cluster        │
│ (pas de clustering)     │ (scaling horizontal natif)    │
├─────────────────────────┼───────────────────────────────┤
│ PromQL                  │ MetricsQL (superset de        │
│                         │ PromQL, compatible)           │
├─────────────────────────┼───────────────────────────────┤
│ ~1.5 bytes/sample       │ ~0.7 bytes/sample             │
│ (compression)           │ (meilleure compression)       │
├─────────────────────────┼───────────────────────────────┤
│ Ingestion : ~millions   │ Ingestion : ~dizaines de      │
│ samples/s               │ millions samples/s            │
├─────────────────────────┼───────────────────────────────┤
│ Standard de fait        │ Drop-in replacement           │
│ Reference               │ compatible                    │
├─────────────────────────┼───────────────────────────────┤
│ Communaute massive      │ Communaute plus petite        │
│ CNCF Graduated          │ mais en croissance            │
├─────────────────────────┼───────────────────────────────┤
│ Remote write v1/v2      │ Compatible remote write       │
│ sender                  │ receiver et sender            │
├─────────────────────────┼───────────────────────────────┤
│ Ecosysteme d'exporters  │ Reutilise les exporters       │
│ + Operator K8s          │ Prometheus + ses propres      │
└─────────────────────────┴───────────────────────────────┘

Verdict : VictoriaMetrics est une excellente alternative/complement
a Prometheus. Beaucoup l'utilisent comme backend de stockage long
terme (via remote write) grace a sa meilleure compression et ses
performances superieures. C'est un choix judicieux pour les gros
volumes.
```

### 13.4 Prometheus + Mimir vs Thanos

```
┌──────────────────────────┬──────────────────────────────┐
│   PROMETHEUS + MIMIR     │   PROMETHEUS + THANOS        │
├──────────────────────────┼──────────────────────────────┤
│ Push (remote write)      │ Pull (sidecar upload)        │
│ Prometheus pousse vers   │ Thanos lit la TSDB locale    │
│ Mimir                    │ de Prometheus                │
├──────────────────────────┼──────────────────────────────┤
│ Grafana Labs             │ Communaute (CNCF Incubating) │
│ (enterprise + OSS)       │ Projet purement open source  │
├──────────────────────────┼──────────────────────────────┤
│ Architecture centralisee │ Architecture distribuee      │
│ Mimir recoit tout        │ Sidecar sur chaque Prometheus│
├──────────────────────────┼──────────────────────────────┤
│ Multi-tenant natif       │ Multi-tenant via labels       │
├──────────────────────────┼──────────────────────────────┤
│ Object storage (S3/GCS)  │ Object storage (S3/GCS)      │
│ pour le long terme       │ pour le long terme           │
├──────────────────────────┼──────────────────────────────┤
│ Downsampling : non       │ Downsampling : oui           │
│ (garde la resolution     │ (5m et 1h pour les vieilles  │
│ complete)                │ donnees)                     │
├──────────────────────────┼──────────────────────────────┤
│ Plus simple a operer     │ Plus de composants a gerer   │
│ (moins de composants)    │ (sidecar, store, compact,    │
│                          │ query, ruler)                │
├──────────────────────────┼──────────────────────────────┤
│ Meilleure perf en query  │ Bonne perf mais plus de      │
│ (shuffle sharding)       │ latence sur les grosses      │
│                          │ requetes cross-cluster       │
├──────────────────────────┼──────────────────────────────┤
│ Prometheus peut etre     │ Prometheus garde ses donnees │
│ stateless (pas de TSDB   │ locales (TSDB locale         │
│ locale necessaire)       │ necessaire)                  │
└──────────────────────────┴──────────────────────────────┘

Architecture Mimir :
────────────────────
  Prometheus ──remote write──▶ Mimir ──▶ S3
                                ▲
                                │ PromQL
                              Grafana

Architecture Thanos :
─────────────────────
  Prometheus + Sidecar ──upload──▶ S3
                ▲                    ▲
                │                    │
          Thanos Query ──────────────┘
                ▲
                │ PromQL
              Grafana

Verdict : Mimir est plus simple a operer et offre de meilleures
performances. Thanos est un choix valide si tu veux rester 100%
open source CNCF sans dependance a un vendor. Pour un homelab,
Mimir (mode monolithique) est recommande pour sa simplicite.
```

### 13.5 Prometheus vs OTel Metrics

```
┌──────────────────────────┬──────────────────────────────┐
│   PROMETHEUS METRICS     │   OPENTELEMETRY METRICS      │
├──────────────────────────┼──────────────────────────────┤
│ Format d'exposition      │ Format OTLP (protobuf)       │
│ texte (/metrics)         │                              │
├──────────────────────────┼──────────────────────────────┤
│ Pull (scrape)            │ Push (OTLP) ou Pull          │
│                          │ (via Collector prometheus    │
│                          │ receiver)                    │
├──────────────────────────┼──────────────────────────────┤
│ Toujours cumulatif       │ Cumulatif OU delta           │
├──────────────────────────┼──────────────────────────────┤
│ Client libraries :       │ SDK OTel :                   │
│ prometheus_client        │ opentelemetry-api/sdk         │
│ (specifique Prometheus)  │ (standard universel)         │
├──────────────────────────┼──────────────────────────────┤
│ Metriques seulement      │ Metriques + Traces + Logs    │
│                          │ (avec correlation)           │
├──────────────────────────┼──────────────────────────────┤
│ Exemplars (limites)      │ Exemplars natifs + riches    │
│                          │ (lien trace ↔ metrique)      │
├──────────────────────────┼──────────────────────────────┤
│ Maturite : 10+ ans       │ Maturite : ~5 ans            │
│ Ecosysteme enorme        │ Ecosysteme en croissance     │
├──────────────────────────┼──────────────────────────────┤
│ Pas de dependance vendor │ Pas de dependance vendor     │
│ (mais lie a Prometheus)  │ (agnostique du backend)      │
└──────────────────────────┴──────────────────────────────┘

En pratique : Les deux sont complementaires.
- Utilise les client libraries Prometheus pour les exporters
  et les applications existantes.
- Utilise OTel pour les nouvelles applications (metriques +
  traces + logs unifies).
- Prometheus v3 recoit nativement les metriques OTLP.
- OTel Collector peut scraper des endpoints /metrics Prometheus.

Architecture hybride (comme ton homelab) :
──────────────────────────────────────────
  Apps instrumentees OTel → OTel Collector → remote write → Prometheus
  Exporters classiques → scrape direct par Prometheus
  Prometheus → Grafana
```

---
