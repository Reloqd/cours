## 4. Les Metrics (en profondeur)

### 4.1 Types de métriques OTel

OpenTelemetry définit des types d'instruments (instruments) pour créer des métriques. Chaque instrument a une sémantique précise.

#### Counter

Un **Counter** est un compteur monotone croissant. Il ne peut qu'augmenter (ou être réinitialisé à 0 au redémarrage).

```go
// Go : créer un counter
meter := otel.Meter("checkout-service")
orderCounter, _ := meter.Int64Counter(
    "orders.created",
    metric.WithDescription("Number of orders created"),
    metric.WithUnit("{order}"),
)

// Incrémenter
orderCounter.Add(ctx, 1,
    metric.WithAttributes(
        attribute.String("payment.method", "credit_card"),
        attribute.String("customer.tier", "premium"),
    ),
)
```

Usage : comptage de requêtes, d'erreurs, d'octets envoyés, etc.

#### UpDownCounter

Comme un Counter, mais peut aussi **décroître**. Utile pour les valeurs qui montent et descendent.

```python
# Python : connexions actives
active_connections = meter.create_up_down_counter(
    name="db.connections.active",
    description="Number of active database connections",
    unit="{connection}",
)

# Quand une connexion est ouverte
active_connections.add(1, {"db.system": "postgresql"})

# Quand une connexion est fermée
active_connections.add(-1, {"db.system": "postgresql"})
```

Usage : connexions actives, taille de queue, nombre de goroutines, etc.

#### Histogram

Un **Histogram** enregistre la distribution de valeurs. Il calcule automatiquement des buckets, la somme, le count, le min et le max.

```java
// Java : latence des requêtes
LongHistogram requestDuration = meter.histogramBuilder("http.server.request.duration")
    .setDescription("Duration of HTTP server requests")
    .setUnit("ms")
    .ofLongs()
    .build();

// Enregistrer une valeur
requestDuration.record(42,
    Attributes.of(
        AttributeKey.stringKey("http.request.method"), "GET",
        AttributeKey.longKey("http.response.status_code"), 200
    )
);
```

Les buckets par défaut d'OTel : `[0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000]`

Tu peux les personnaliser via une **View** dans le SDK :
```go
view := metric.NewView(
    metric.Instrument{Name: "http.server.request.duration"},
    metric.Stream{
        Aggregation: metric.AggregationExplicitBucketHistogram{
            Boundaries: []float64{5, 10, 25, 50, 100, 250, 500, 1000, 5000},
        },
    },
)
```

#### Gauge

Un **Gauge** représente une valeur instantanée qui peut monter et descendre. Contrairement à l'UpDownCounter, le Gauge enregistre des **valeurs absolues**, pas des deltas.

```go
// Go : température CPU
cpuTemp, _ := meter.Float64Gauge(
    "system.cpu.temperature",
    metric.WithDescription("Current CPU temperature"),
    metric.WithUnit("Cel"),
)

// Callback : la valeur est lue périodiquement
cpuTemp.Record(ctx, 72.5,
    metric.WithAttributes(attribute.Int("cpu.core", 0)),
)
```

Usage : température, utilisation mémoire (%), taille d'un pool, etc.

**Note** : Le Gauge OTel est apparu tardivement (stabilisé en 2024). Avant, on utilisait des callbacks asynchrones (ObservableGauge).

### 4.2 Comparaison avec les types Prometheus

| Type OTel | Type Prometheus | Notes |
|-----------|----------------|-------|
| `Counter` | `counter` | Équivalent direct |
| `UpDownCounter` | `gauge` | Prometheus utilise `gauge` pour les valeurs up/down |
| `Histogram` | `histogram` | Buckets similaires, mais OTel ajoute min/max |
| `Gauge` | `gauge` | OTel distingue gauge (instantané) et up-down-counter (cumulatif delta) |
| — | `summary` | OTel n'a pas d'équivalent. Les summaries Prometheus sont calculées côté client, ce qu'OTel déconseille |

**Différence fondamentale** : Prometheus a 4 types simples. OTel a 6 instruments (Counter, UpDownCounter, Histogram, Gauge + versions asynchrones/Observable). OTel est plus précis dans sa sémantique.

### 4.3 Le modèle de données OTel vs Prometheus

#### Modèle Prometheus

Prometheus utilise un modèle **one-dimensional time series** :

```
# Chaque série est identifiée par son nom + labels
http_requests_total{method="GET", status="200", handler="/api/users"} 1234

# Le nom encode implicitement le type et l'unité
# Conventions : _total pour counter, _seconds pour durée, etc.
```

Caractéristiques :
- Modèle **pull** : Prometheus scrape des endpoints `/metrics`
- Format texte **Exposition** (ou protobuf)
- Temporalité **cumulative** uniquement
- Pas de métadonnées riches (pas de resource, pas de scope)

#### Modèle OTel

OTel utilise un modèle **hiérarchique et structuré** :

```
ExportMetricsServiceRequest
├── resource_metrics[]
│   ├── resource
│   │   └── attributes: {service.name: "api", k8s.pod.name: "api-xyz"}
│   │
│   └── scope_metrics[]
│       ├── scope: {name: "otel-http-instrumentation", version: "1.0"}
│       │
│       └── metrics[]
│           ├── name: "http.server.request.duration"
│           ├── description: "Duration of HTTP server requests"
│           ├── unit: "s"
│           │
│           └── data (histogram)
│               └── data_points[]
│                   ├── attributes: {http.method: "GET", http.status_code: 200}
│                   ├── start_time: 1700000000
│                   ├── time: 1700000060
│                   ├── count: 150
│                   ├── sum: 23.7
│                   ├── min: 0.005
│                   ├── max: 2.3
│                   ├── bucket_counts: [10, 30, 50, 40, 15, 5]
│                   ├── explicit_bounds: [0.01, 0.05, 0.1, 0.5, 1.0]
│                   └── exemplars[]    ← lien vers une trace !
│                       └── {trace_id: "abc...", span_id: "def...", value: 2.3}
```

Caractéristiques :
- Modèle **push** : les données sont envoyées activement
- Protocole **OTLP** (protobuf)
- Temporalité **cumulative** OU **delta**
- Métadonnées riches (resource, scope, unit, description)
- **Exemplars** : lien direct entre une métrique et une trace

### 4.4 Push (OTLP) vs Pull (Prometheus scrape)

```
PULL (Prometheus) :                      PUSH (OTel OTLP) :

┌───────────┐                            ┌───────────┐
│   App     │                            │   App     │
│           │  GET /metrics              │           │  OTLP POST
│  /metrics │◀──────────────┐            │  SDK      │──────────────▶┌───────────┐
│  endpoint │               │            │           │               │ Collector │
└───────────┘               │            └───────────┘               │ ou Backend│
                            │                                        └───────────┘
                     ┌──────┴──────┐
                     │ Prometheus  │
                     │ (scraper)   │
                     └─────────────┘
```

| Critère | Pull (Prometheus) | Push (OTLP) |
|---------|-------------------|-------------|
| **Découverte** | Prometheus doit connaître les targets (service discovery) | L'application connaît le endpoint du Collector |
| **Firewall** | Prometheus doit pouvoir atteindre chaque target | Les apps poussent vers un endpoint centralisé |
| **Éphémère** | Problématique pour les jobs courts (batch, serverless) — Pushgateway nécessaire | Natif : les données sont envoyées immédiatement |
| **Réseau** | Prometheus initie les connexions | L'application initie les connexions |
| **Charge** | Prometheus contrôle la fréquence | L'application contrôle le rythme d'export |
| **Haute dispo** | Deux Prometheus qui scrapent = données doublées mais indépendantes | L'application peut envoyer à deux Collectors |
| **Debugging** | `curl http://app:8080/metrics` — instantané | Il faut un Collector ou activer l'exporter console |

**En pratique** : Ce n'est pas l'un ou l'autre. Le Collector OTel peut **scraper** des endpoints Prometheus (via le receiver `prometheus`) ET recevoir des données OTLP. Tu peux avoir les deux dans la même architecture.

### 4.5 Exemplars : lier une métrique à une trace

Les **exemplars** sont un mécanisme puissant qui lie un point de données métrique à une trace spécifique. C'est le pont entre les métriques et les traces.

```
Scénario : ta métrique http_server_request_duration montre un pic de latence.
Tu veux savoir QUELLE requête a causé ce pic.

Métrique avec exemplar :
http_server_request_duration_seconds_bucket{le="1.0"} 9999
                                                       │
                                        ┌──────────────┘
                                        ▼
                              Exemplar: {
                                trace_id: "abc123...",
                                span_id: "def456...",
                                value: 0.95,
                                timestamp: 1700000000
                              }
                                        │
                                        │ Clic dans Grafana
                                        ▼
                              Trace abc123... dans Tempo
                              → Visualisation complète
                              → Le span montre que la BDD
                                a mis 800ms à répondre
```

Dans Grafana, les exemplars apparaissent comme des points sur les graphiques de métriques. Un clic sur un exemplar ouvre directement la trace correspondante dans Tempo.

Configuration dans le SDK (Go) :
```go
// Les exemplars sont collectés automatiquement si un span est actif
// quand la métrique est enregistrée. Pas de code supplémentaire nécessaire
// si le SDK est configuré avec un TracerProvider actif.

// Dans le Collector, s'assurer que les exemplars sont propagés :
exporters:
  prometheusremotewrite:
    endpoint: "http://mimir:9009/api/v1/push"
    send_metadata: true
    # Les exemplars sont envoyés automatiquement via remote write
```

### 4.6 Delta vs Cumulative temporality

C'est un concept qui n'existe pas dans Prometheus (qui est toujours cumulatif) et qui est source de confusion quand on découvre OTel.

#### Cumulative (comme Prometheus)

La valeur représente le **total depuis le démarrage** du processus.

```
T=0s  → counter = 0     (démarrage)
T=10s → counter = 5     (5 requêtes au total)
T=20s → counter = 12    (12 requêtes au total)
T=30s → counter = 20    (20 requêtes au total)

Pour calculer le débit : rate() = (20-12)/(30-20) = 0.8 req/s
```

#### Delta

La valeur représente le **changement depuis le dernier export**.

```
T=0s  → (démarrage)
T=10s → delta = 5       (5 nouvelles requêtes)
T=20s → delta = 7       (7 nouvelles requêtes)
T=30s → delta = 8       (8 nouvelles requêtes)

Le débit est directement : 8/10 = 0.8 req/s
```

```
Cumulative :                          Delta :

Valeur                                Valeur
  │                 ╱                   │
  │              ╱╱                     │         ┌──┐
  │           ╱╱                        │    ┌──┐ │  │
  │        ╱╱                           │┌──┐│  │ │  │
  │     ╱╱                              ││  ││  │ │  │
  │  ╱╱                                 ││  ││  │ │  │
  └──────────────▶ Temps                └┴──┴┴──┴─┴──┴──▶ Temps
```

| Temporalité | Avantages | Inconvénients |
|-------------|-----------|---------------|
| **Cumulative** | Compatible Prometheus. Résistant aux gaps. `rate()` fonctionne. | Rollover au redémarrage. Plus de bande passante (valeurs croissantes). |
| **Delta** | Plus compact. Pas de problème de restart. Naturel pour les systèmes stateless. | Perte d'un point = perte de données. Incompatible Prometheus natif. |

**Recommandation** : Si tu exportes vers Prometheus ou Mimir, utilise la temporalité **cumulative** (c'est le défaut). Si tu exportes vers Datadog ou un système natif OTLP, le **delta** est souvent préférable. Le Collector peut convertir entre les deux via le processor `cumulativetodelta` (ou inversement).

```yaml
# Conversion dans le Collector
processors:
  cumulativetodelta:
    include:
      match_type: strict
      metrics:
        - system.cpu.time
        - system.network.io
```

---
