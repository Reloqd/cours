## 8. Remote Write / Remote Read

### 8.1 Pourquoi le remote write ?

Le stockage local de Prometheus a des limitations :
- **Retention limitee** : garder 30 jours de donnees avec un scrape_interval de 15s peut necessiter des centaines de Go
- **Pas de haute disponibilite** : si le serveur Prometheus tombe, les donnees sont inaccessibles
- **Pas de vue globale** : avec plusieurs Prometheus, il n'y a pas de requete cross-cluster native
- **Pas de downsampling** : les vieilles donnees gardent la meme resolution

Le remote write permet d'envoyer les metriques vers un backend de stockage long terme.

```
Architecture avec remote write :
════════════════════════════════

  ┌──────────────┐      remote write       ┌──────────────────┐
  │ Prometheus   │ ──────────────────────▶ │ Backend long     │
  │ (homelab)    │   POST /api/v1/push     │ terme            │
  │              │                          │                  │
  │ Retention :  │                          │ - Mimir          │
  │ 15 jours     │                          │ - Thanos         │
  │              │                          │ - VictoriaMetrics│
  │ Usage :      │                          │ - Cortex         │
  │ Donnees      │                          │                  │
  │ recentes     │                          │ Retention :      │
  └──────────────┘                          │ 1 an+            │
                                            │                  │
                                            │ Stockage :       │
                                            │ Object storage   │
                                            │ (S3, GCS, MinIO) │
                                            └────────┬─────────┘
                                                     │
                                                     │  PromQL
                                                     ▼
                                            ┌──────────────────┐
                                            │     Grafana      │
                                            │                  │
                                            │  Requetes sur    │
                                            │  donnees long    │
                                            │  terme           │
                                            └──────────────────┘
```

### 8.2 Configuration du remote write

```yaml
# prometheus.yml
remote_write:
  # ---- Vers Grafana Mimir ----
  - url: "http://mimir:9009/api/v1/push"

    # Authentification (si necessaire)
    # basic_auth:
    #   username: "tenant-1"
    #   password: "secret"

    # Headers custom
    headers:
      X-Scope-OrgID: "tenant-1"

    # Configuration des files d'attente
    queue_config:
      # Nombre maximum de samples en attente dans la queue
      capacity: 10000

      # Nombre maximum de shards (threads) d'envoi paralleles
      max_shards: 50

      # Nombre minimum de shards
      min_shards: 1

      # Nombre max de samples par requete
      max_samples_per_send: 2000

      # Delai maximum avant d'envoyer un batch incomplet
      batch_send_deadline: 5s

      # Backoff en cas d'erreur
      min_backoff: 30ms
      max_backoff: 5s

      # Nombre max de retries
      retry_on_http_429: true  # Retry sur rate limiting

    # Filtrer les metriques envoyees (economiser la bande passante/stockage)
    write_relabel_configs:
      # Ne pas envoyer les metriques internes de Prometheus
      - source_labels: [__name__]
        regex: "prometheus_.*"
        action: drop

      # Ne pas envoyer les metriques Go internes
      - source_labels: [__name__]
        regex: "go_.*"
        action: drop

      # Supprimer un label inutile avant l'envoi
      - regex: "pod_template_hash"
        action: labeldrop

    # Metadata (types de metriques, help text)
    send_exemplars: true
    send_native_histograms: true

    # Remote write protocol v2 (Prometheus 3.x)
    # protobuf_message: "io.prometheus.write.v2.Request"

  # ---- Second backend (optionnel) ----
  - url: "http://victoria-metrics:8428/api/v1/write"
    queue_config:
      capacity: 5000
      max_shards: 10
```

### 8.3 Remote write avec OTel Collector

Dans ton homelab, tu utilises OTel Collector qui pousse vers Prometheus via remote write. Voici la configuration cote Collector :

```yaml
# otel-collector-config.yml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:4317"
      http:
        endpoint: "0.0.0.0:4318"

processors:
  batch:
    send_batch_size: 10000
    timeout: 5s
  memory_limiter:
    check_interval: 1s
    limit_mib: 512

exporters:
  prometheusremotewrite:
    endpoint: "http://prometheus:9090/api/v1/write"
    # Ou vers Mimir directement :
    # endpoint: "http://mimir:9009/api/v1/push"
    tls:
      insecure: true
    send_metadata: true
    resource_to_telemetry_conversion:
      enabled: true  # Convertit les resource attributes en labels

service:
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheusremotewrite]
```

```
Flux OTel → Prometheus :
════════════════════════

  ┌───────────┐    OTLP     ┌───────────────┐  remote    ┌──────────────┐
  │ App avec  │────────────▶│ OTel          │──write───▶│  Prometheus  │
  │ OTel SDK  │  gRPC:4317  │ Collector     │  HTTP POST │  v3.4.1      │
  │           │             │               │            │              │
  │ Metriques │             │ Receivers     │            │ --web.enable │
  │ OTel      │             │ → Processors  │            │ -remote-write│
  │ format    │             │ → Exporters   │            │ -receiver    │
  └───────────┘             └───────────────┘            └──────────────┘

  Alternative avec Prometheus v3 natif OTLP :

  ┌───────────┐    OTLP     ┌──────────────┐
  │ App avec  │────────────▶│  Prometheus  │
  │ OTel SDK  │  HTTP:9090  │  v3.4.1      │
  │           │  /api/v1/   │              │
  │           │  otlp/v1/   │ --enable-    │
  │           │  metrics    │ feature=     │
  └───────────┘             │ otlp-write-  │
                            │ receiver     │
                            └──────────────┘

  Note : La reception OTLP native dans Prometheus v3 evite le besoin
  d'un Collector si tu n'as pas besoin de processing intermediaire.
```

### 8.4 Remote read

Le remote read permet a Prometheus de lire des donnees depuis un stockage externe, comme si elles etaient locales.

```yaml
remote_read:
  - url: "http://mimir:9009/prometheus/api/v1/read"
    # Ne pas lire les donnees recentes (elles sont deja en local)
    read_recent: false

    # Filtrer les series lues
    # required_matchers:
    #   job: "important-service"
```

**Quand utiliser remote read** :
- Quand tu veux interroger des donnees plus anciennes que ta retention locale
- Quand tu migres d'un backend a un autre
- En general, il vaut mieux configurer Grafana pour interroger directement le backend long terme plutot qu'utiliser remote read

---
