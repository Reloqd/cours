## 5. Les Logs (en profondeur)

### 5.1 Le modèle de log OTel (LogRecord)

Le modèle de log OTel est plus structuré qu'un simple message texte. Voici la structure d'un **LogRecord** :

```
LogRecord
├── timestamp              : 2024-01-15T10:30:00.123456789Z
├── observed_timestamp     : 2024-01-15T10:30:00.123500000Z
├── severity_number        : 17 (ERROR)
├── severity_text          : "ERROR"
├── body                   : "Failed to process payment for order ORD-12345"
├── attributes             :
│   ├── order.id           : "ORD-12345"
│   ├── payment.method     : "credit_card"
│   ├── error.type         : "PaymentGatewayTimeout"
│   ├── code.function      : "processPayment"
│   └── code.filepath      : "src/payment/handler.go"
├── trace_id               : "4bf92f3577b34da6a3ce929d0e0e4736"  ← CORRÉLATION
├── span_id                : "00f067aa0ba902b7"                   ← CORRÉLATION
├── trace_flags            : 01
├── resource               :
│   ├── service.name       : "payment-service"
│   ├── service.version    : "2.1.0"
│   └── k8s.pod.name       : "payment-7d8f9-xz4kl"
└── instrumentation_scope  :
    ├── name               : "payment-service"
    └── version            : "2.1.0"
```

#### Niveaux de sévérité

OTel définit une échelle numérique de sévérité (1-24) avec des mappings vers les noms courants :

| Range | Nom | Équivalent courant |
|-------|-----|-------------------|
| 1-4 | TRACE | Trace/Finest |
| 5-8 | DEBUG | Debug |
| 9-12 | INFO | Info |
| 13-16 | WARN | Warning |
| 17-20 | ERROR | Error |
| 21-24 | FATAL | Fatal/Critical |

Le `severity_number` est un entier, ce qui permet des comparaisons et des filtres numériques. Le `severity_text` est la représentation textuelle pour l'humain.

### 5.2 Corrélation logs <-> traces

C'est **la** killer feature des logs OTel : chaque log peut être automatiquement enrichi avec le `trace_id` et le `span_id` du contexte actif. Cela permet de passer instantanément d'un log à la trace complète, et inversement.

```
Flux de corrélation :

  Grafana Dashboard
       │
       │ Alerte : taux d'erreur élevé
       ▼
  Métrique : http_server_errors_total = 42/min
       │
       │ Exemplar : trace_id=abc123
       ▼
  Trace abc123 dans Tempo
       │
       │ Le span "payment-service/processPayment" est en ERROR
       │ trace_id=abc123, span_id=def456
       ▼
  Logs dans Loki : {trace_id="abc123"}
       │
       │ 10:30:00.123 ERROR Failed to process payment
       │   order.id=ORD-12345
       │   error.type=PaymentGatewayTimeout
       │
       ▼
  DIAGNOSTIC COMPLET en 30 secondes
```

#### Injection automatique du trace_id dans les logs

**Approche 1 : Via le SDK OTel (recommandé)**

Le SDK OTel peut s'intégrer avec les frameworks de logging existants pour injecter automatiquement `trace_id` et `span_id`.

```python
# Python avec structlog + OTel
import structlog
from opentelemetry import trace
from opentelemetry.instrumentation.logging import LoggingInstrumentor

# Active l'injection automatique de trace_id/span_id
LoggingInstrumentor().instrument(set_logging_format=True)

# Maintenant chaque log contient trace_id et span_id automatiquement
logger = structlog.get_logger()
logger.error("Payment failed", order_id="ORD-12345")
# Output:
# {
#   "event": "Payment failed",
#   "order_id": "ORD-12345",
#   "otelTraceID": "4bf92f3577b34da6a3ce929d0e0e4736",
#   "otelSpanID": "00f067aa0ba902b7",
#   "severity": "ERROR"
# }
```

```java
// Java avec Log4j2 / SLF4J + OTel Java Agent
// L'agent Java OTel injecte automatiquement dans le MDC :
//   trace_id, span_id, trace_flags

// log4j2.xml — pattern avec trace_id
<PatternLayout pattern="%d{ISO8601} [%t] %-5p %c - trace_id=%X{trace_id} span_id=%X{span_id} - %m%n"/>
```

**Approche 2 : Via le Collector (parsing)**

Si l'application n'est pas instrumentée, le Collector peut extraire ou ajouter le `trace_id` à partir des logs :

```yaml
receivers:
  filelog:
    include: [/var/log/app/*.log]
    operators:
      # Parser le format du log
      - type: regex_parser
        regex: '^(?P<timestamp>\S+) (?P<severity>\S+) trace_id=(?P<trace_id>\S+) (?P<body>.*)'
        timestamp:
          parse_from: attributes.timestamp
          layout: '2006-01-02T15:04:05.000Z'
        severity:
          parse_from: attributes.severity
        trace:
          trace_id:
            parse_from: attributes.trace_id
```

### 5.3 Bridge avec les systèmes existants

La réalité, c'est que la majorité des applications ne vont pas migrer vers le SDK OTel pour les logs du jour au lendemain. OTel a prévu des **bridges** pour collecter les logs existants.

```
┌──────────────────────────────────────────────────────────────────┐
│ Sources de logs existantes                                       │
│                                                                  │
│  stdout/stderr ──┐                                               │
│  fichiers ───────┤                                               │
│  syslog ─────────┤        ┌──────────────────────┐               │
│  journald ───────┼───────▶│ OTel Collector       │               │
│  Windows Events ─┤        │                      │               │
│  Docker logs ────┤        │ Receivers:           │               │
│  Kubernetes logs ┘        │ - filelog             │               │
│                           │ - syslog             │               │
│                           │ - journald           │               │
│                           │ - windowseventlog    │               │
│                           │                      │               │
│                           │ Le Collector parse,  │               │
│                           │ enrichit et exporte  │               │
│                           │ les logs             │               │
│                           └────────┬─────────────┘               │
│                                    │                              │
│                                    ▼                              │
│                           Loki / Elasticsearch /                  │
│                           Splunk / etc.                           │
└──────────────────────────────────────────────────────────────────┘
```

#### Remplacer Promtail par le Collector OTel

Tu utilises Promtail pour envoyer les logs à Loki ? Le Collector OTel peut le remplacer, avec l'avantage de gérer aussi les métriques et les traces dans un seul agent.

Promtail :
```yaml
# promtail-config.yaml
scrape_configs:
  - job_name: containers
    static_configs:
      - targets: [localhost]
        labels:
          job: containers
          __path__: /var/log/containers/*.log
    pipeline_stages:
      - json:
          expressions:
            log: log
            stream: stream
            time: time
```

Equivalent OTel Collector :
```yaml
# otel-collector-config.yaml
receivers:
  filelog:
    include:
      - /var/log/containers/*.log
    exclude:
      - /var/log/containers/otel-collector*.log  # Éviter la boucle
    operators:
      - type: container
        id: container-parser
      # Enrichir avec les métadonnées k8s
      - type: move
        from: attributes["k8s.pod.name"]
        to: resource["k8s.pod.name"]

processors:
  batch:
    send_batch_size: 1000
    timeout: 5s

  resource:
    attributes:
      - action: insert
        key: loki.resource.labels
        value: k8s.pod.name, k8s.namespace.name, k8s.container.name

exporters:
  loki:
    endpoint: "http://loki:3100/loki/api/v1/push"

service:
  pipelines:
    logs:
      receivers: [filelog]
      processors: [batch, resource]
      exporters: [loki]
```

### 5.4 OTel Collector comme agent de collecte de logs

Le Collector est un remplacement viable de Promtail, Fluentd, Fluent Bit, ou Filebeat. Voici les receivers de logs principaux :

#### filelog receiver

Le plus courant. Lit des fichiers de log, les parse, et les exporte.

```yaml
receivers:
  filelog:
    include:
      - /var/log/app/*.log
      - /var/log/syslog
    exclude:
      - /var/log/app/debug.log
    # Suivi de la position (comme un offset Kafka)
    start_at: end  # "beginning" ou "end"
    # Stockage des offsets pour survivre aux redémarrages
    storage: file_storage

    # Pipeline d'opérateurs pour parser les logs
    operators:
      # Parser du JSON
      - type: json_parser
        timestamp:
          parse_from: attributes.timestamp
          layout: '%Y-%m-%dT%H:%M:%S.%fZ'
        severity:
          parse_from: attributes.level
          mapping:
            error: [err, error, ERROR]
            warn: [warning, warn, WARN]
            info: [info, INFO]

      # Extraire le trace_id si présent
      - type: trace_parser
        trace_id:
          parse_from: attributes.trace_id
        span_id:
          parse_from: attributes.span_id

      # Déplacer des attributs vers le body ou la resource
      - type: move
        from: attributes.message
        to: body
```

#### syslog receiver

Pour les applications qui envoient des logs via syslog (RFC 5424 ou RFC 3164) :

```yaml
receivers:
  syslog:
    udp:
      listen_address: "0.0.0.0:514"
    protocol: rfc5424
```

#### journald receiver (Linux systemd)

```yaml
receivers:
  journald:
    directory: /var/log/journal
    units:
      - sshd
      - kubelet
      - docker
    priority: info  # Minimum severity
```

---
