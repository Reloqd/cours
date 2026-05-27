## 8. Intégration avec la stack Prometheus/Grafana/Loki/Tempo

### 8.1 OTel + Prometheus

#### Scénario 1 : OTel SDK → Prometheus (pull)

L'application utilise le SDK OTel et expose un endpoint Prometheus pour le scraping :

```go
// Go : exporter les métriques OTel via un endpoint Prometheus
import (
    "go.opentelemetry.io/otel/exporters/prometheus"
    sdkmetric "go.opentelemetry.io/otel/sdk/metric"
)

exporter, _ := prometheus.New()
provider := sdkmetric.NewMeterProvider(sdkmetric.WithReader(exporter))
otel.SetMeterProvider(provider)

// L'exporter enregistre automatiquement un handler sur /metrics
// Prometheus peut scraper http://app:2223/metrics
```

#### Scénario 2 : OTel SDK → Collector → Remote Write → Prometheus/Mimir

L'application envoie via OTLP, le Collector convertit et pousse via Remote Write :

```
App ──OTLP──▶ Collector ──Remote Write──▶ Mimir/Prometheus
```

C'est le scénario recommandé car il découple l'application du backend.

#### Scénario 3 : Prometheus existant → Collector → OTLP

Le Collector scrape les endpoints Prometheus existants (mode transition) :

```yaml
receivers:
  prometheus:
    config:
      scrape_configs:
        - job_name: 'existing-apps'
          static_configs:
            - targets: ['app1:8080', 'app2:8080']
```

Cela permet de migrer progressivement : les applications existantes gardent leur endpoint `/metrics` Prometheus, et le Collector les collecte.

### 8.2 OTel + Loki

Le Collector envoie les logs structurés à Loki. Points d'attention :

```yaml
# Configuration critique pour Loki
exporters:
  loki:
    endpoint: "http://loki:3100/loki/api/v1/push"

processors:
  resource/loki:
    attributes:
      # Définir quels resource attributes deviennent des labels Loki
      # IMPORTANT : limiter les labels pour éviter l'explosion de cardinalité
      - action: insert
        key: loki.resource.labels
        value: service.name, k8s.namespace.name

      # Les attributs trace_id et span_id sont automatiquement propagés
      # et disponibles pour la corrélation dans Grafana
```

**Piège courant** : Loki est optimisé pour un faible nombre de labels avec faible cardinalité. N'ajoutez pas `k8s.pod.name` ou `container.id` comme labels Loki — ils changent à chaque redéploiement. Utilisez-les comme champs structurés (filtrables via `| json`).

### 8.3 OTel + Tempo

Tempo est le backend de traces de Grafana. Il est conçu pour recevoir des données OTLP nativement.

```yaml
# tempo-config.yaml
server:
  http_listen_port: 3200

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: "0.0.0.0:4317"
        http:
          endpoint: "0.0.0.0:4318"

# Le Collector envoie directement les traces à Tempo via OTLP
# Pas de conversion nécessaire
exporters:
  otlp/tempo:
    endpoint: "tempo:4317"
    tls:
      insecure: true
```

Tempo peut aussi recevoir les traces directement depuis les SDKs, sans passer par un Collector. Mais le Collector apporte du batching, du retry, du sampling, et de l'enrichissement — il est recommandé en production.

### 8.4 OTel + Grafana : corrélation metrics <-> logs <-> traces

C'est ici que la magie opère. Grafana peut corréler les trois signaux grâce aux identifiants partagés (trace_id, service.name, etc.).

```
┌───────────────────────────────────────────────────────────────┐
│ GRAFANA                                                       │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ Dashboard : HTTP Latency (Mimir)                        │ │
│  │                                                         │ │
│  │  ╱╲                                                     │ │
│  │ ╱  ╲    ╱╲                         ●  ← Exemplar       │ │
│  │╱    ╲──╱  ╲──────────────────────────                   │ │
│  │                                                         │ │
│  │ Clic sur l'exemplar ●                                   │ │
│  └────────────────────────┬────────────────────────────────┘ │
│                           │                                   │
│                           ▼                                   │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ Trace View (Tempo)          trace_id=abc123             │ │
│  │                                                         │ │
│  │ api-gateway   ████████████████████████████  320ms       │ │
│  │ order-svc       ████████████████████████    290ms       │ │
│  │ payment-svc        ██████████████████       250ms ←ERR  │ │
│  │                                                         │ │
│  │ Clic sur le span payment-svc → "Logs for this span"    │ │
│  └────────────────────────┬────────────────────────────────┘ │
│                           │                                   │
│                           ▼                                   │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ Logs (Loki)           {trace_id="abc123"}               │ │
│  │                                                         │ │
│  │ 10:30:00.100 INFO  Processing payment order=ORD-12345  │ │
│  │ 10:30:00.200 WARN  Stripe timeout, retrying...         │ │
│  │ 10:30:00.350 ERROR Payment failed: gateway_timeout     │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                               │
│  Temps total de diagnostic : < 1 minute                      │
└───────────────────────────────────────────────────────────────┘
```

#### Configuration des data sources dans Grafana

```yaml
# grafana-datasources.yaml (provisioning)
apiVersion: 1
datasources:
  # Métriques
  - name: Mimir
    type: prometheus
    url: http://mimir:9009/prometheus
    jsonData:
      exemplarTraceIdDestinations:
        - name: traceID
          datasourceUid: tempo
      httpMethod: POST

  # Traces
  - name: Tempo
    uid: tempo
    type: tempo
    url: http://tempo:3200
    jsonData:
      tracesToLogsV2:
        datasourceUid: loki
        spanStartTimeShift: "-1h"
        spanEndTimeShift: "1h"
        filterByTraceID: true
        filterBySpanID: false
        customQuery: true
        query: '{service_name="${__span.tags.service.name}"} | json | trace_id = `${__span.traceId}`'
      tracesToMetrics:
        datasourceUid: mimir
        spanStartTimeShift: "-1h"
        spanEndTimeShift: "1h"
        queries:
          - name: "Request rate"
            query: "sum(rate(traces_spanmetrics_calls_total{service=\"${__span.tags.service.name}\"}[5m]))"
          - name: "Error rate"
            query: "sum(rate(traces_spanmetrics_calls_total{service=\"${__span.tags.service.name}\",status_code=\"STATUS_CODE_ERROR\"}[5m]))"
      nodeGraph:
        enabled: true
      serviceMap:
        datasourceUid: mimir

  # Logs
  - name: Loki
    uid: loki
    type: loki
    url: http://loki:3100
    jsonData:
      derivedFields:
        - datasourceUid: tempo
          matcherRegex: "trace_id=(\\w+)"
          name: TraceID
          url: "$${__value.raw}"
          urlDisplayLabel: "View Trace"
```

### 8.5 Architecture complète : diagramme de flux

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           ARCHITECTURE COMPLÈTE                             │
│                                                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐                   │
│  │ Service  │  │ Service  │  │ Service  │  │ Traefik  │                   │
│  │ A (Java) │  │ B (Go)   │  │ C (Node) │  │ (proxy)  │                   │
│  │          │  │          │  │          │  │          │                   │
│  │ Agent    │  │ SDK      │  │ SDK      │  │ Native   │                   │
│  │ auto-ins │  │ manuel   │  │ auto-ins │  │ OTel     │                   │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘                   │
│       │ OTLP        │ OTLP       │ OTLP        │ OTLP                    │
│       └──────────────┼────────────┼─────────────┘                         │
│                      │            │                                        │
│                      ▼            ▼                                        │
│       ┌──────────────────────────────────────────┐                        │
│       │         OTEL COLLECTOR (Gateway)          │                        │
│       │                                           │                        │
│       │  ┌─────────┐  ┌──────────┐  ┌──────────┐│                        │
│       │  │Receivers│  │Processors│  │Exporters ││                        │
│       │  │         │  │          │  │          ││                        │
│       │  │ otlp    │  │ memory   │  │ otlp     ││─── Traces ──▶ Tempo   │
│       │  │ prometh │  │ k8sattr  │  │ prom_rw  ││─── Metrics ─▶ Mimir   │
│       │  │ filelog │  │ filter   │  │ loki     ││─── Logs ────▶ Loki    │
│       │  │ hostmet │  │ batch    │  │          ││                        │
│       │  └─────────┘  └──────────┘  └──────────┘│                        │
│       │                                          │                        │
│       │  Connectors: spanmetrics, servicegraph   │                        │
│       └──────────────────────────────────────────┘                        │
│                                                                            │
│       ┌──────────────────────────────────────────┐                        │
│       │              GRAFANA                      │                        │
│       │                                           │                        │
│       │  Data sources :                           │                        │
│       │  ├── Mimir (metrics)                      │                        │
│       │  ├── Tempo (traces)   ←→ corrélation     │                        │
│       │  └── Loki  (logs)                         │                        │
│       │                                           │                        │
│       │  Dashboards :                             │                        │
│       │  ├── RED metrics (via spanmetrics)         │                        │
│       │  ├── Service graph (via servicegraph)      │                        │
│       │  ├── Trace explorer                        │                        │
│       │  └── Log explorer avec trace correlation   │                        │
│       └──────────────────────────────────────────┘                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

---
