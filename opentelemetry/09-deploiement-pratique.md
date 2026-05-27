## 9. Déploiement pratique

### 9.1 Docker Compose : stack complète

Voici un Docker Compose fonctionnel pour une stack complète d'observabilité avec OTel.

```yaml
# docker-compose.yaml
# Stack complète : OTel Collector + Tempo + Mimir + Loki + Grafana
# + une application de démo instrumentée

version: "3.9"

services:
  # ─────────────────────────────────────────────────────────
  # OTEL COLLECTOR
  # ─────────────────────────────────────────────────────────
  otel-collector:
    image: otel/opentelemetry-collector-contrib:0.116.0
    command: ["--config=/etc/otel/config.yaml"]
    volumes:
      - ./otel-collector-config.yaml:/etc/otel/config.yaml:ro
      - otel-storage:/var/otel/storage
    ports:
      - "4317:4317"   # OTLP gRPC
      - "4318:4318"   # OTLP HTTP
      - "8888:8888"   # Métriques internes du Collector
      - "13133:13133" # Health check
    depends_on:
      - tempo
      - loki
      - mimir
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 512M

  # ─────────────────────────────────────────────────────────
  # TEMPO (Traces)
  # ─────────────────────────────────────────────────────────
  tempo:
    image: grafana/tempo:2.6.1
    command: ["-config.file=/etc/tempo/config.yaml"]
    volumes:
      - ./tempo-config.yaml:/etc/tempo/config.yaml:ro
      - tempo-data:/var/tempo
    ports:
      - "3200:3200"   # Tempo HTTP API
    restart: unless-stopped

  # ─────────────────────────────────────────────────────────
  # MIMIR (Metrics - compatible Prometheus)
  # ─────────────────────────────────────────────────────────
  mimir:
    image: grafana/mimir:2.14.2
    command: ["-config.file=/etc/mimir/config.yaml", "-target=all"]
    volumes:
      - ./mimir-config.yaml:/etc/mimir/config.yaml:ro
      - mimir-data:/data
    ports:
      - "9009:9009"
    restart: unless-stopped

  # ─────────────────────────────────────────────────────────
  # LOKI (Logs)
  # ─────────────────────────────────────────────────────────
  loki:
    image: grafana/loki:3.3.2
    command: ["-config.file=/etc/loki/config.yaml"]
    volumes:
      - ./loki-config.yaml:/etc/loki/config.yaml:ro
      - loki-data:/loki
    ports:
      - "3100:3100"
    restart: unless-stopped

  # ─────────────────────────────────────────────────────────
  # GRAFANA
  # ─────────────────────────────────────────────────────────
  grafana:
    image: grafana/grafana:11.4.0
    volumes:
      - ./grafana-datasources.yaml:/etc/grafana/provisioning/datasources/datasources.yaml:ro
      - grafana-data:/var/lib/grafana
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: admin
      GF_FEATURE_TOGGLES_ENABLE: "traceqlEditor tempoServiceGraph traceToMetrics"
    ports:
      - "3000:3000"
    depends_on:
      - mimir
      - tempo
      - loki
    restart: unless-stopped

  # ─────────────────────────────────────────────────────────
  # APPLICATION DE DÉMO (optionnel)
  # ─────────────────────────────────────────────────────────
  demo-app:
    image: ghcr.io/open-telemetry/opentelemetry-demo:latest
    environment:
      OTEL_SERVICE_NAME: "demo-app"
      OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector:4317"
    depends_on:
      - otel-collector

volumes:
  otel-storage:
  tempo-data:
  mimir-data:
  loki-data:
  grafana-data:
```

#### Configuration Tempo

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

storage:
  trace:
    backend: local
    local:
      path: /var/tempo/traces
    wal:
      path: /var/tempo/wal

query_frontend:
  search:
    duration_slo: 5s
    throughput_bytes_slo: 1.073741824e+09

metrics_generator:
  registry:
    external_labels:
      source: tempo
  storage:
    path: /var/tempo/generator/wal
    remote_write:
      - url: http://mimir:9009/api/v1/push
        send_exemplars: true
  processor:
    service_graphs:
      dimensions:
        - http.request.method
    span_metrics:
      dimensions:
        - http.request.method
        - http.response.status_code

overrides:
  defaults:
    metrics_generator:
      processors: [service-graphs, span-metrics]
```

#### Configuration Mimir

```yaml
# mimir-config.yaml
multitenancy_enabled: false

server:
  http_listen_port: 9009

blocks_storage:
  backend: filesystem
  filesystem:
    dir: /data/blocks
  tsdb:
    dir: /data/tsdb
  bucket_store:
    sync_dir: /data/sync

compactor:
  data_dir: /data/compactor
  sharding_ring:
    kvstore:
      store: memberlist

distributor:
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: memberlist

ingester:
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: memberlist
    replication_factor: 1

ruler_storage:
  backend: filesystem
  filesystem:
    dir: /data/rules

limits:
  native_histograms_ingestion_enabled: true
```

#### Configuration Loki

```yaml
# loki-config.yaml
auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  allow_structured_metadata: true
  volume_enabled: true
```

#### Configuration OTel Collector (pour Docker Compose)

```yaml
# otel-collector-config.yaml
extensions:
  health_check:
    endpoint: "0.0.0.0:13133"

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:4317"
      http:
        endpoint: "0.0.0.0:4318"

processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 75
    spike_limit_percentage: 25

  batch:
    send_batch_size: 4096
    timeout: 5s

  resource/loki:
    attributes:
      - action: insert
        key: loki.resource.labels
        value: service.name

connectors:
  spanmetrics:
    histogram:
      explicit:
        buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 5s, 10s]
    dimensions:
      - name: http.request.method
      - name: http.response.status_code
    exemplars:
      enabled: true

exporters:
  otlp/tempo:
    endpoint: "tempo:4317"
    tls:
      insecure: true

  prometheusremotewrite:
    endpoint: "http://mimir:9009/api/v1/push"
    resource_to_telemetry_conversion:
      enabled: true

  loki:
    endpoint: "http://loki:3100/loki/api/v1/push"

  debug:
    verbosity: basic

service:
  extensions: [health_check]
  telemetry:
    logs:
      level: info
    metrics:
      address: "0.0.0.0:8888"

  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/tempo, spanmetrics, debug]

    metrics:
      receivers: [otlp, spanmetrics]
      processors: [memory_limiter, batch]
      exporters: [prometheusremotewrite]

    logs:
      receivers: [otlp]
      processors: [memory_limiter, resource/loki, batch]
      exporters: [loki]
```

#### Configuration des datasources Grafana

```yaml
# grafana-datasources.yaml
apiVersion: 1
datasources:
  - name: Mimir
    type: prometheus
    access: proxy
    url: http://mimir:9009/prometheus
    isDefault: true
    jsonData:
      exemplarTraceIdDestinations:
        - name: trace_id
          datasourceUid: tempo
      httpMethod: POST

  - name: Tempo
    uid: tempo
    type: tempo
    access: proxy
    url: http://tempo:3200
    jsonData:
      tracesToLogsV2:
        datasourceUid: loki
        spanStartTimeShift: "-1h"
        spanEndTimeShift: "1h"
        filterByTraceID: true
        customQuery: false
      tracesToMetrics:
        datasourceUid: Mimir
        spanStartTimeShift: "-1h"
        spanEndTimeShift: "1h"
        queries:
          - name: "Request rate"
            query: 'sum(rate(traces_spanmetrics_calls_total{$$__tags}[5m]))'
      nodeGraph:
        enabled: true
      serviceMap:
        datasourceUid: Mimir

  - name: Loki
    uid: loki
    type: loki
    access: proxy
    url: http://loki:3100
    jsonData:
      derivedFields:
        - datasourceUid: tempo
          matcherRegex: '"trace_id":"(\w+)"'
          name: TraceID
          url: "$${__value.raw}"
```

### 9.2 Kubernetes : Helm chart, Operator, DaemonSet vs Deployment

#### Option 1 : Helm Chart officiel

```bash
# Ajouter le repo Helm
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# Installer le Collector en mode DaemonSet (agent)
helm install otel-agent open-telemetry/opentelemetry-collector \
  --namespace observability \
  --create-namespace \
  --values otel-agent-values.yaml

# Installer le Collector en mode Deployment (gateway)
helm install otel-gateway open-telemetry/opentelemetry-collector \
  --namespace observability \
  --values otel-gateway-values.yaml
```

```yaml
# otel-agent-values.yaml (DaemonSet)
mode: daemonset

image:
  repository: otel/opentelemetry-collector-contrib

presets:
  # Collecte automatique des logs Kubernetes
  logsCollection:
    enabled: true
  # Enrichissement avec les métadonnées K8s
  kubernetesAttributes:
    enabled: true
  # Métriques du kubelet
  kubeletMetrics:
    enabled: true
  # Métriques du host
  hostMetrics:
    enabled: true

config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: "0.0.0.0:4317"
        http:
          endpoint: "0.0.0.0:4318"

  processors:
    memory_limiter:
      check_interval: 1s
      limit_percentage: 75
      spike_limit_percentage: 25
    batch:
      send_batch_size: 4096
      timeout: 5s

  exporters:
    otlp/gateway:
      endpoint: "otel-gateway-opentelemetry-collector.observability:4317"
      tls:
        insecure: true

  service:
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp/gateway]
      metrics:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp/gateway]
      logs:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp/gateway]

resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 100m
    memory: 128Mi

tolerations:
  - operator: Exists
```

```yaml
# otel-gateway-values.yaml (Deployment)
mode: deployment
replicaCount: 2

image:
  repository: otel/opentelemetry-collector-contrib

config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: "0.0.0.0:4317"

  connectors:
    spanmetrics:
      histogram:
        explicit:
          buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 5s, 10s]
      exemplars:
        enabled: true

  processors:
    memory_limiter:
      check_interval: 1s
      limit_percentage: 75
      spike_limit_percentage: 25
    batch:
      send_batch_size: 8192
      timeout: 5s
    filter:
      error_mode: ignore
      traces:
        span:
          - 'attributes["http.route"] == "/health"'

  exporters:
    otlp/tempo:
      endpoint: "tempo.observability:4317"
      tls:
        insecure: true
    prometheusremotewrite:
      endpoint: "http://mimir.observability:9009/api/v1/push"
    loki:
      endpoint: "http://loki.observability:3100/loki/api/v1/push"

  service:
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, filter, batch]
        exporters: [otlp/tempo, spanmetrics]
      metrics:
        receivers: [otlp, spanmetrics]
        processors: [memory_limiter, batch]
        exporters: [prometheusremotewrite]
      logs:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [loki]

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80

resources:
  limits:
    cpu: "2"
    memory: 2Gi
  requests:
    cpu: 500m
    memory: 512Mi
```

#### Option 2 : OpenTelemetry Operator

L'Operator Kubernetes gère le cycle de vie des Collectors et peut injecter automatiquement l'instrumentation dans les pods.

```bash
# Installer l'Operator via Helm
helm install otel-operator open-telemetry/opentelemetry-operator \
  --namespace observability \
  --set "manager.collectorImage.repository=otel/opentelemetry-collector-contrib"
```

```yaml
# OpenTelemetryCollector CRD (géré par l'Operator)
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel-gateway
  namespace: observability
spec:
  mode: deployment
  replicas: 2
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: "0.0.0.0:4317"
    processors:
      batch:
        send_batch_size: 8192
    exporters:
      otlp/tempo:
        endpoint: "tempo:4317"
        tls:
          insecure: true
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [otlp/tempo]
```

```yaml
# Auto-instrumentation (injection automatique)
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: otel-instrumentation
  namespace: production
spec:
  exporter:
    endpoint: http://otel-gateway.observability:4317
  propagators:
    - tracecontext
    - baggage
  sampler:
    type: parentbased_traceidratio
    argument: "0.1"
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:latest
  python:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-python:latest
  nodejs:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-nodejs:latest
  dotnet:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-dotnet:latest
```

Ensuite, annote tes pods pour activer l'auto-instrumentation :

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
spec:
  template:
    metadata:
      annotations:
        # Pour Java
        instrumentation.opentelemetry.io/inject-java: "true"
        # Pour Python
        # instrumentation.opentelemetry.io/inject-python: "true"
        # Pour Node.js
        # instrumentation.opentelemetry.io/inject-nodejs: "true"
        # Pour .NET
        # instrumentation.opentelemetry.io/inject-dotnet: "true"
    spec:
      containers:
        - name: order-service
          image: my-order-service:latest
          # L'Operator injecte automatiquement l'init container
          # et les variables d'environnement OTel
```

L'Operator injecte automatiquement :
1. Un init container qui copie l'agent d'instrumentation
2. Les variables d'environnement `JAVA_TOOL_OPTIONS`, `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`, etc.
3. Un volume partagé pour l'agent

### 9.3 Bonnes pratiques de production

#### Resource limits

```yaml
# DaemonSet (agent) : léger
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

# Deployment (gateway) : plus de ressources
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: "2"
    memory: 2Gi
```

**Règle** : le `memory_limiter` doit être configuré à ~80% de la limit mémoire du conteneur. Si la limit est 512Mi, configure `limit_mib: 400`.

#### Batching optimal

```yaml
processors:
  batch:
    # Pour un agent (faible volume)
    send_batch_size: 1024
    timeout: 5s

    # Pour un gateway (haut volume)
    send_batch_size: 8192
    send_batch_max_size: 16384
    timeout: 2s
```

#### Retry et queue

```yaml
exporters:
  otlp/tempo:
    endpoint: "tempo:4317"

    # Retry : réessayer en cas d'échec temporaire
    retry_on_failure:
      enabled: true
      initial_interval: 5s     # Premier retry après 5s
      max_interval: 30s        # Max entre deux retries
      max_elapsed_time: 300s   # Abandon après 5 minutes
      randomization_factor: 0.5 # Jitter pour éviter les thundering herds

    # Queue : buffer en mémoire (ou sur disque) pour absorber les pics
    sending_queue:
      enabled: true
      num_consumers: 10        # Workers parallèles
      queue_size: 5000         # Nombre d'items en queue
      storage: file_storage    # Persistance sur disque (optionnel)
```

#### Haute disponibilité

```yaml
# Pour le Gateway : au moins 2 replicas
replicaCount: 2

# PodDisruptionBudget
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: otel-gateway
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: otel-gateway

# Service avec session affinity pour le tail sampling
apiVersion: v1
kind: Service
metadata:
  name: otel-gateway
spec:
  sessionAffinity: ClientIP  # Nécessaire pour tail_sampling
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 300
```

#### Sécurité

```yaml
# TLS entre les services
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:4317"
        tls:
          cert_file: /certs/server.crt
          key_file: /certs/server.key
          client_ca_file: /certs/ca.crt  # mTLS

exporters:
  otlp/tempo:
    endpoint: "tempo:4317"
    tls:
      cert_file: /certs/client.crt
      key_file: /certs/client.key
      ca_file: /certs/ca.crt

# Authentification
extensions:
  bearertokenauth:
    token: "${env:OTEL_AUTH_TOKEN}"

exporters:
  otlp/backend:
    endpoint: "backend:4317"
    auth:
      authenticator: bearertokenauth
```

---
