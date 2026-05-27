## 6. Le Collector (composant central)

### 6.1 Architecture du Collector

Le Collector est construit autour d'un modèle de **pipelines**. Chaque pipeline traite un type de signal (traces, métriques ou logs).

```
┌───────────────────────────────────────────────────────────────────────────┐
│                           OTEL COLLECTOR                                  │
│                                                                           │
│  Pipeline "traces" :                                                      │
│  ┌───────────┐    ┌───────────┐    ┌───────────┐    ┌───────────┐        │
│  │ Receiver  │───▶│ Processor │───▶│ Processor │───▶│ Exporter  │        │
│  │ otlp      │    │ batch     │    │ tail_     │    │ otlp      │        │
│  └───────────┘    └───────────┘    │ sampling  │    │ (Tempo)   │        │
│                                    └───────────┘    └───────────┘        │
│                                                                           │
│  Pipeline "metrics" :                                                     │
│  ┌───────────┐    ┌───────────┐    ┌───────────┐    ┌───────────┐        │
│  │ Receiver  │───▶│ Processor │───▶│ Processor │───▶│ Exporter  │        │
│  │ otlp      │    │ memory_   │    │ batch     │    │ prometheus │        │
│  │ prometheus │    │ limiter   │    │           │    │ remote_   │        │
│  │ hostmetric│    └───────────┘    └───────────┘    │ write     │        │
│  └───────────┘                                      └───────────┘        │
│                                                                           │
│  Pipeline "logs" :                                                        │
│  ┌───────────┐    ┌───────────┐    ┌───────────┐    ┌───────────┐        │
│  │ Receiver  │───▶│ Processor │───▶│ Processor │───▶│ Exporter  │        │
│  │ filelog   │    │ k8s_      │    │ batch     │    │ loki      │        │
│  │ otlp      │    │ attributes│    │           │    │           │        │
│  └───────────┘    └───────────┘    └───────────┘    └───────────┘        │
│                                                                           │
│  ┌──────────────────────────────────────────────────────────────┐        │
│  │ Extensions :                                                  │        │
│  │  - health_check (endpoint /health)                            │        │
│  │  - zpages (debug UI)                                          │        │
│  │  - pprof (profiling Go)                                       │        │
│  │  - file_storage (persistence des offsets)                     │        │
│  └──────────────────────────────────────────────────────────────┘        │
└───────────────────────────────────────────────────────────────────────────┘
```

**Points clés** :
- Un même receiver peut alimenter plusieurs pipelines
- Un même exporter peut recevoir de plusieurs pipelines
- Les processors sont exécutés dans l'ordre déclaré (l'ordre compte !)
- Un pipeline ne mélange jamais les types de signaux (traces/metrics/logs)

### 6.2 Modes de déploiement

#### Mode Agent (DaemonSet / Sidecar)

```
┌─────────────────────────────────────────────────────┐
│ Node Kubernetes                                      │
│                                                      │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐               │
│  │ Pod A   │ │ Pod B   │ │ Pod C   │               │
│  │ App     │ │ App     │ │ App     │               │
│  └────┬────┘ └────┬────┘ └────┬────┘               │
│       │           │           │                      │
│       │   OTLP    │   OTLP   │   OTLP              │
│       ▼           ▼           ▼                      │
│  ┌──────────────────────────────────────┐           │
│  │ OTel Collector (DaemonSet)           │           │
│  │ - Un par noeud                       │           │
│  │ - Accès aux logs locaux (/var/log)   │           │
│  │ - Accès aux métriques du noeud       │           │
│  │ - Faible latence réseau              │           │
│  └───────────────────┬──────────────────┘           │
│                      │                               │
└──────────────────────┼───────────────────────────────┘
                       │ OTLP
                       ▼
              Backend (Tempo/Mimir/Loki)
```

Usage : collecte de logs fichier, métriques du noeud/host, faible latence.

#### Mode Gateway (Deployment)

```
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│ Node 1          │  │ Node 2          │  │ Node 3          │
│ Pods ───────────┼──┼── Pods ─────────┼──┼── Pods ─────────┤
└────────┬────────┘  └────────┬────────┘  └────────┬────────┘
         │                    │                    │
         │    OTLP            │    OTLP           │    OTLP
         └────────────────────┼────────────────────┘
                              │
                              ▼
                 ┌──────────────────────────┐
                 │ OTel Collector Gateway   │
                 │ (Deployment, 2+ replicas)│
                 │                          │
                 │ - Traitement centralisé  │
                 │ - Tail-based sampling    │
                 │ - Transformation lourde  │
                 │ - Load balancing         │
                 │ - Retry, queue           │
                 └────────────┬─────────────┘
                              │
                   ┌──────────┼──────────┐
                   │          │          │
                   ▼          ▼          ▼
                 Tempo     Mimir      Loki
```

Usage : traitement centralisé, tail sampling (nécessite de voir toute la trace), transformations coûteuses.

#### Architecture hybride (Agent + Gateway)

C'est l'architecture recommandée en production :

```
┌─────────────────────────────────────────────────────────┐
│ Node 1                                                   │
│  Pods ──▶ Collector Agent (DaemonSet)                   │
│           - filelog receiver                              │
│           - hostmetrics receiver                         │
│           - otlp receiver                                │
│           - Pré-traitement léger (batch, memory_limiter) │
│           - Exporte via OTLP vers le Gateway             │
└─────────────────────┬───────────────────────────────────┘
                      │
┌─────────────────────┼───────────────────────────────────┐
│ Node 2              │                                    │
│  Pods ──▶ Collector Agent ───┐                          │
└─────────────────────┬────────┘                          │
                      │                                    │
                      ▼                                    │
         ┌──────────────────────────┐                     │
         │ Collector Gateway        │                     │
         │ (Deployment, HPA)        │                     │
         │                          │                     │
         │ - tail_sampling          │                     │
         │ - spanmetrics connector  │                     │
         │ - k8sattributes          │                     │
         │ - Routing vers backends  │                     │
         └────────────┬─────────────┘                     │
                      │                                    │
           ┌──────────┼──────────┐                        │
           ▼          ▼          ▼                        │
         Tempo     Mimir      Loki                        │
```

### 6.3 Receivers principaux

#### otlp receiver

Le receiver le plus important : il reçoit les données OTLP des SDKs et d'autres Collectors.

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:4317"
        max_recv_msg_size_mib: 4       # Taille max des messages gRPC
        keepalive:
          server_parameters:
            max_connection_age: 60s
            max_connection_age_grace: 5s
      http:
        endpoint: "0.0.0.0:4318"
        cors:
          allowed_origins: ["*"]       # Pour le browser (RUM)
          allowed_headers: ["*"]
```

#### prometheus receiver

Scrape des endpoints Prometheus existants. Utile pour collecter les métriques d'applications déjà instrumentées avec les clients Prometheus.

```yaml
receivers:
  prometheus:
    config:
      scrape_configs:
        - job_name: 'kubernetes-pods'
          scrape_interval: 15s
          kubernetes_sd_configs:
            - role: pod
          relabel_configs:
            # Ne scraper que les pods avec l'annotation prometheus.io/scrape=true
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: true
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
              action: replace
              target_label: __metrics_path__
              regex: (.+)
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port, __meta_kubernetes_pod_ip]
              action: replace
              regex: (\d+);(([\d\.]+))
              replacement: $2:$1
              target_label: __address__
```

**Note** : La configuration du receiver Prometheus utilise le même format que `prometheus.yml`. Tu peux réutiliser ta configuration Prometheus existante.

#### filelog receiver

Déjà détaillé en section 5.4. Lit des fichiers de log et les parse.

#### hostmetrics receiver

Collecte les métriques du système hôte (CPU, mémoire, disque, réseau). Remplace `node_exporter` dans certains cas.

```yaml
receivers:
  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu:
        metrics:
          system.cpu.utilization:
            enabled: true
      memory:
        metrics:
          system.memory.utilization:
            enabled: true
      disk: {}
      filesystem:
        exclude_mount_points:
          mount_points: [/dev/*, /proc/*, /sys/*]
          match_type: regexp
      load: {}
      network: {}
      paging: {}
      processes: {}
```

#### docker_stats receiver

Collecte les métriques des conteneurs Docker. Utile si tu n'es pas sur Kubernetes (ou pour Docker standalone / Docker Compose).

```yaml
receivers:
  docker_stats:
    endpoint: "unix:///var/run/docker.sock"
    collection_interval: 10s
    timeout: 20s
    # Métriques par conteneur : CPU, mémoire, réseau, I/O disque
    container_labels_to_metric_labels:
      com.docker.compose.service: docker_compose_service
    provide_per_core_cpu_metrics: true
```

#### kubeletstats receiver

Collecte les métriques des pods/conteneurs via l'API Kubelet (Kubernetes-native).

```yaml
receivers:
  kubeletstats:
    collection_interval: 20s
    auth_type: serviceAccount
    endpoint: "https://${env:K8S_NODE_NAME}:10250"
    insecure_skip_verify: true
    metric_groups:
      - node
      - pod
      - container
```

### 6.4 Processors principaux

Les processors transforment les données entre la réception et l'export. **L'ordre est important** : ils sont exécutés séquentiellement.

Ordre recommandé dans un pipeline :
```
memory_limiter → k8sattributes → filter → attributes → transform → batch
```

#### batch processor

Regroupe les données en lots avant export. **Essentiel en production** pour réduire le nombre d'appels réseau.

```yaml
processors:
  batch:
    # Envoyer un batch quand il contient 8192 spans/metrics/logs
    send_batch_size: 8192
    # Ou quand 5 secondes se sont écoulées (même si le batch n'est pas plein)
    timeout: 5s
    # Taille max d'un batch (sécurité)
    send_batch_max_size: 16384
```

#### memory_limiter processor

**Critique en production.** Empêche le Collector de consommer trop de mémoire et d'être OOMKilled.

```yaml
processors:
  memory_limiter:
    # Vérifier l'utilisation mémoire toutes les secondes
    check_interval: 1s
    # Commencer à refuser les données quand il reste 20% de la limite
    limit_percentage: 80
    # Revenir à la normale quand il reste 30%
    spike_limit_percentage: 25
```

**Toujours mettre `memory_limiter` en premier** dans la liste des processors. Si un processor en amont consomme trop de mémoire, le limiter ne peut pas agir.

#### attributes processor

Manipule les attributs (ajouter, modifier, supprimer, hacher).

```yaml
processors:
  attributes:
    actions:
      # Ajouter un attribut
      - key: environment
        value: production
        action: insert

      # Mettre à jour un attribut existant
      - key: http.url
        action: update
        value: "REDACTED"

      # Supprimer un attribut
      - key: user.password
        action: delete

      # Hacher une valeur (PII)
      - key: user.email
        action: hash

      # Extraire une valeur avec une regex
      - key: http.url
        pattern: "^https?://(?P<host>[^/]+)"
        action: extract
```

#### filter processor

Supprime des spans, métriques ou logs selon des conditions. Utile pour réduire le volume.

```yaml
processors:
  filter:
    # Syntaxe OTTL (OpenTelemetry Transformation Language)
    error_mode: ignore

    traces:
      span:
        # Supprimer les spans de health check
        - 'attributes["http.route"] == "/health"'
        - 'attributes["http.route"] == "/ready"'
        # Supprimer les spans trop courts (< 1ms, probablement du bruit)
        - 'duration < 1000000'  # nanosecondes

    metrics:
      metric:
        # Supprimer les métriques qu'on ne veut pas
        - 'name == "rpc.server.duration" and resource.attributes["service.name"] == "debug-service"'

    logs:
      log_record:
        # Supprimer les logs DEBUG en production
        - 'severity_number < 9'  # Tout ce qui est en dessous de INFO
        # Supprimer les logs de health check
        - 'body == "Health check OK"'
```

#### transform processor

Transformations puissantes avec le langage OTTL :

```yaml
processors:
  transform:
    error_mode: ignore

    trace_statements:
      - context: span
        statements:
          # Tronquer les noms de span trop longs
          - truncate_all(attributes, 256)
          # Renommer un attribut
          - set(attributes["http.method"], attributes["http.request.method"])
            where attributes["http.request.method"] != nil
          # Ajouter un attribut conditionnel
          - set(attributes["error"], true)
            where status.code == 2

    metric_statements:
      - context: datapoint
        statements:
          # Convertir des unités
          - set(attributes["response_time_class"], "fast")
            where value_double < 0.1
          - set(attributes["response_time_class"], "slow")
            where value_double >= 1.0

    log_statements:
      - context: log
        statements:
          # Enrichir les logs avec des attributs dérivés
          - set(attributes["log.source"], "application")
            where resource.attributes["service.name"] != nil
          # Masquer les données sensibles
          - replace_pattern(body, "password=\\S+", "password=***")
          - replace_pattern(body, "\\b\\d{16}\\b", "****-****-****-****")
```

#### tail_sampling processor

Déjà détaillé en section 3.4. Décision d'échantillonnage basée sur la trace complète.

#### k8sattributes processor

Enrichit automatiquement les données avec les métadonnées Kubernetes (pod name, namespace, deployment, labels, annotations).

```yaml
processors:
  k8sattributes:
    auth_type: serviceAccount
    passthrough: false
    # Extraire les métadonnées du pod source
    extract:
      metadata:
        - k8s.pod.name
        - k8s.pod.uid
        - k8s.namespace.name
        - k8s.node.name
        - k8s.deployment.name
        - k8s.replicaset.name
        - k8s.statefulset.name
        - k8s.daemonset.name
        - k8s.container.name
      labels:
        - tag_name: app.label.team
          key: team
          from: pod
      annotations:
        - tag_name: app.annotation.version
          key: app-version
          from: pod
    # Filtrer les pods à surveiller
    pod_association:
      - sources:
          - from: resource_attribute
            name: k8s.pod.ip
      - sources:
          - from: connection
```

### 6.5 Exporters principaux

#### otlp exporter

Envoie les données via OTLP vers un autre Collector ou un backend compatible.

```yaml
exporters:
  otlp:
    endpoint: "tempo:4317"
    tls:
      insecure: true  # ou configurer mTLS
    # Retry en cas d'échec
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    # Queue pour absorber les pics
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000
      storage: file_storage  # Persistance sur disque

  otlp/tempo:
    endpoint: "tempo:4317"
    tls:
      insecure: true

  otlp/mimir:
    endpoint: "mimir:4317"
    tls:
      insecure: true
```

Note : Tu peux définir plusieurs instances du même exporter avec des suffixes (`otlp/tempo`, `otlp/mimir`).

#### prometheusremotewrite exporter

Envoie les métriques vers Prometheus, Mimir, Thanos, Cortex, ou tout backend compatible Remote Write.

```yaml
exporters:
  prometheusremotewrite:
    endpoint: "http://mimir:9009/api/v1/push"
    # Authentification
    headers:
      X-Scope-OrgID: "tenant-1"
    # TLS
    tls:
      insecure: false
      cert_file: /certs/client.crt
      key_file: /certs/client.key
    # Conversion OTel → Prometheus
    namespace: ""  # Préfixe des métriques (vide = pas de préfixe)
    send_metadata: true
    resource_to_telemetry_conversion:
      enabled: true  # Convertit les resource attributes en labels
    # Retry et queue
    retry_on_failure:
      enabled: true
    sending_queue:
      enabled: true
      queue_size: 10000
```

#### loki exporter

Envoie les logs vers Loki.

```yaml
exporters:
  loki:
    endpoint: "http://loki:3100/loki/api/v1/push"
    headers:
      X-Scope-OrgID: "tenant-1"
    # Quels attributs deviennent des labels Loki
    # ATTENTION : trop de labels = explosion de la cardinalité
    default_labels_enabled:
      exporter: false
      job: true
```

Pour contrôler quels attributs deviennent des labels Loki (ce qui est critique pour la performance), utilise un hint via le processor `resource` :

```yaml
processors:
  resource:
    attributes:
      - action: insert
        key: loki.resource.labels
        value: service.name, k8s.namespace.name, k8s.pod.name
      # Optionnel : définir le tenant
      - action: insert
        key: loki.tenant
        value: team-platform
```

#### debug exporter

Affiche les données dans stdout. Indispensable pour le développement et le debug.

```yaml
exporters:
  debug:
    verbosity: detailed   # "basic", "normal", "detailed"
    sampling_initial: 5    # Premiers N messages affichés
    sampling_thereafter: 1 # Puis 1 sur N
```

### 6.6 Connectors

Les connectors sont un concept puissant : ils agissent comme un **exporter d'un pipeline ET un receiver d'un autre pipeline**. Ils permettent de dériver de nouvelles données à partir des données existantes.

#### spanmetrics connector

Génère des métriques (RED : Rate, Errors, Duration) à partir des traces. Plus besoin d'instrumenter séparément les métriques de latence — elles sont dérivées automatiquement des spans.

```yaml
connectors:
  spanmetrics:
    # Histogramme de latence
    histogram:
      explicit:
        buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 2.5s, 5s, 10s]
    # Dimensions (attributes des spans à utiliser comme labels)
    dimensions:
      - name: http.request.method
      - name: http.response.status_code
      - name: rpc.grpc.status_code
    # Métriques générées :
    # - traces_spanmetrics_calls_total (counter)
    # - traces_spanmetrics_duration_milliseconds_bucket (histogram)
    # - traces_spanmetrics_duration_milliseconds_count
    # - traces_spanmetrics_duration_milliseconds_sum
    exemplars:
      enabled: true  # Ajouter des exemplars liés aux traces
    namespace: traces.spanmetrics

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp/tempo, spanmetrics]  # spanmetrics est un exporter ici

    metrics:
      receivers: [spanmetrics]               # spanmetrics est un receiver ici
      processors: [batch]
      exporters: [prometheusremotewrite]
```

```
Flux :
                                    ┌───────────────┐
Traces ──▶ Pipeline traces ──▶─────┤  spanmetrics  ├──▶ Pipeline metrics ──▶ Mimir
                            └──▶   │  connector    │
                            Tempo  └───────────────┘
```

#### servicegraph connector

Génère un graphe de dépendances entre services à partir des traces. Utile pour visualiser l'architecture dans Grafana.

```yaml
connectors:
  servicegraph:
    latency_histogram_buckets: [10ms, 50ms, 100ms, 500ms, 1s, 5s]
    dimensions:
      - http.request.method
    store:
      ttl: 2s
      max_items: 1000
    # Métriques générées :
    # - traces_service_graph_request_total
    # - traces_service_graph_request_failed_total
    # - traces_service_graph_request_server_seconds_bucket
    # - traces_service_graph_request_client_seconds_bucket
```

### 6.7 Configuration YAML complète commentée

Voici un fichier de configuration complet et réaliste pour un Collector en mode Gateway :

```yaml
# otel-collector-config.yaml
# Configuration complète pour un OTel Collector en mode Gateway
# Stack : OTel → Tempo (traces) + Mimir (metrics) + Loki (logs)

# ─────────────────────────────────────────────────────────────────
# EXTENSIONS
# ─────────────────────────────────────────────────────────────────
extensions:
  # Endpoint de health check pour les probes Kubernetes
  health_check:
    endpoint: "0.0.0.0:13133"
    path: "/health"

  # Pages de debug (accessible via navigateur)
  zpages:
    endpoint: "0.0.0.0:55679"

  # Stockage sur disque pour la persistance des queues
  file_storage:
    directory: /var/otel/storage
    timeout: 10s
    compaction:
      on_start: true
      directory: /tmp/otel-compaction

# ─────────────────────────────────────────────────────────────────
# RECEIVERS
# ─────────────────────────────────────────────────────────────────
receivers:
  # Réception OTLP (depuis les SDKs et les Collectors agents)
  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:4317"
      http:
        endpoint: "0.0.0.0:4318"

  # Scraper les métriques Prometheus existantes
  prometheus:
    config:
      scrape_configs:
        - job_name: 'otel-collector-self'
          scrape_interval: 15s
          static_configs:
            - targets: ['localhost:8888']

  # Métriques du host
  hostmetrics:
    collection_interval: 30s
    scrapers:
      cpu: {}
      memory: {}
      disk: {}
      network: {}
      load: {}
      filesystem:
        exclude_mount_points:
          mount_points: ["/dev/*", "/proc/*", "/sys/*"]
          match_type: regexp

  # Lecture de fichiers de log
  filelog:
    include:
      - /var/log/containers/*.log
    exclude:
      - /var/log/containers/otel-collector*.log
    start_at: end
    storage: file_storage
    operators:
      - type: container
        id: container-parser

# ─────────────────────────────────────────────────────────────────
# PROCESSORS
# ─────────────────────────────────────────────────────────────────
processors:
  # [1] TOUJOURS en premier : protection mémoire
  memory_limiter:
    check_interval: 1s
    limit_percentage: 75
    spike_limit_percentage: 25

  # [2] Enrichissement Kubernetes (si applicable)
  k8sattributes:
    auth_type: serviceAccount
    passthrough: false
    extract:
      metadata:
        - k8s.pod.name
        - k8s.namespace.name
        - k8s.deployment.name
        - k8s.node.name
        - k8s.container.name

  # [3] Filtrer le bruit
  filter:
    error_mode: ignore
    traces:
      span:
        - 'attributes["http.route"] == "/health"'
        - 'attributes["http.route"] == "/ready"'
        - 'attributes["http.route"] == "/metrics"'
    logs:
      log_record:
        - 'severity_number < 9'   # Supprimer les logs DEBUG

  # [4] Manipulation d'attributs
  attributes:
    actions:
      - key: environment
        value: production
        action: insert

  # [5] Transformation
  transform:
    error_mode: ignore
    trace_statements:
      - context: span
        statements:
          - truncate_all(attributes, 512)
    log_statements:
      - context: log
        statements:
          - replace_pattern(body, "password=\\S+", "password=***")

  # [6] Contrôle des labels Loki
  resource/loki:
    attributes:
      - action: insert
        key: loki.resource.labels
        value: service.name, k8s.namespace.name, k8s.pod.name

  # [7] TOUJOURS en dernier : batching
  batch:
    send_batch_size: 8192
    send_batch_max_size: 16384
    timeout: 5s

# ─────────────────────────────────────────────────────────────────
# CONNECTORS
# ─────────────────────────────────────────────────────────────────
connectors:
  # Générer des métriques RED à partir des traces
  spanmetrics:
    histogram:
      explicit:
        buckets: [5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 5s, 10s]
    dimensions:
      - name: http.request.method
      - name: http.response.status_code
    exemplars:
      enabled: true

# ─────────────────────────────────────────────────────────────────
# EXPORTERS
# ─────────────────────────────────────────────────────────────────
exporters:
  # Traces → Tempo
  otlp/tempo:
    endpoint: "tempo:4317"
    tls:
      insecure: true
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 5000
      storage: file_storage

  # Métriques → Mimir (ou Prometheus via Remote Write)
  prometheusremotewrite:
    endpoint: "http://mimir:9009/api/v1/push"
    resource_to_telemetry_conversion:
      enabled: true
    retry_on_failure:
      enabled: true
    sending_queue:
      enabled: true
      queue_size: 10000

  # Logs → Loki
  loki:
    endpoint: "http://loki:3100/loki/api/v1/push"

  # Debug (désactiver en production)
  debug:
    verbosity: basic

# ─────────────────────────────────────────────────────────────────
# SERVICE (assemblage des pipelines)
# ─────────────────────────────────────────────────────────────────
service:
  extensions: [health_check, zpages, file_storage]

  # Métriques internes du Collector lui-même
  telemetry:
    logs:
      level: info
      encoding: json
    metrics:
      level: detailed
      address: "0.0.0.0:8888"

  pipelines:
    # Pipeline traces
    traces:
      receivers: [otlp]
      processors:
        - memory_limiter
        - k8sattributes
        - filter
        - attributes
        - transform
        - batch
      exporters: [otlp/tempo, spanmetrics, debug]

    # Pipeline métriques (depuis les apps + spanmetrics)
    metrics:
      receivers: [otlp, prometheus, hostmetrics, spanmetrics]
      processors:
        - memory_limiter
        - k8sattributes
        - batch
      exporters: [prometheusremotewrite]

    # Pipeline logs
    logs:
      receivers: [otlp, filelog]
      processors:
        - memory_limiter
        - k8sattributes
        - filter
        - transform
        - resource/loki
        - batch
      exporters: [loki]
```

### 6.8 Health check et monitoring du Collector

Le Collector expose ses propres métriques. Il est essentiel de le monitorer.

#### Métriques internes clés

```
# Spans reçus / exportés / droppés
otelcol_receiver_accepted_spans
otelcol_receiver_refused_spans
otelcol_exporter_sent_spans
otelcol_exporter_send_failed_spans

# Métriques reçues / exportées
otelcol_receiver_accepted_metric_points
otelcol_exporter_sent_metric_points

# Logs reçus / exportés
otelcol_receiver_accepted_log_records
otelcol_exporter_sent_log_records

# Queue d'export (si sending_queue activée)
otelcol_exporter_queue_size        # Taille actuelle
otelcol_exporter_queue_capacity    # Capacité max

# Mémoire
otelcol_process_memory_rss         # RSS du processus
otelcol_processor_memory_limiter_decision  # accepted/refused

# Batch processor
otelcol_processor_batch_batch_send_size    # Taille des batches envoyés
otelcol_processor_batch_timeout_trigger_send  # Envois déclenchés par timeout
```

#### Dashboard Grafana recommandé

Scrape les métriques du Collector avec Prometheus :

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'otel-collector'
    scrape_interval: 15s
    static_configs:
      - targets: ['otel-collector:8888']
```

Alertes essentielles :
```yaml
# Alertmanager rules
groups:
  - name: otel-collector
    rules:
      - alert: OTelCollectorDroppingSpans
        expr: rate(otelcol_exporter_send_failed_spans[5m]) > 0
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "OTel Collector is dropping spans"

      - alert: OTelCollectorQueueFull
        expr: otelcol_exporter_queue_size / otelcol_exporter_queue_capacity > 0.8
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "OTel Collector export queue is >80% full"

      - alert: OTelCollectorMemoryPressure
        expr: otelcol_processor_memory_limiter_decision{decision="refused"} > 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "OTel Collector is refusing data due to memory pressure"
```

---
