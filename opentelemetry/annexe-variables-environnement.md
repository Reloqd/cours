## Annexe : Récapitulatif des variables d'environnement OTel

Variables d'environnement standard que le SDK OTel reconnaît dans tous les langages :

```bash
# ─── Identification ───
OTEL_SERVICE_NAME="order-service"
OTEL_RESOURCE_ATTRIBUTES="deployment.environment=production,service.version=2.1.0,team=platform"

# ─── Exporter ───
OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector:4317"
OTEL_EXPORTER_OTLP_PROTOCOL="grpc"                    # grpc, http/protobuf, http/json
OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer xxx"
OTEL_EXPORTER_OTLP_TIMEOUT="10000"                    # ms
OTEL_EXPORTER_OTLP_COMPRESSION="gzip"

# Endpoints par signal (override l'endpoint global)
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="http://collector:4317"
OTEL_EXPORTER_OTLP_METRICS_ENDPOINT="http://collector:4317"
OTEL_EXPORTER_OTLP_LOGS_ENDPOINT="http://collector:4317"

# ─── Traces ───
OTEL_TRACES_EXPORTER="otlp"                            # otlp, jaeger, zipkin, console, none
OTEL_TRACES_SAMPLER="parentbased_traceidratio"         # always_on, always_off, traceidratio, parentbased_*
OTEL_TRACES_SAMPLER_ARG="0.1"                          # Argument du sampler (ex: ratio)

# ─── Metrics ───
OTEL_METRICS_EXPORTER="otlp"                           # otlp, prometheus, console, none
OTEL_METRIC_EXPORT_INTERVAL="60000"                    # Intervalle d'export en ms
OTEL_METRIC_EXPORT_TIMEOUT="30000"                     # Timeout d'export en ms
OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE="cumulative"  # cumulative, delta, lowmemory

# ─── Logs ───
OTEL_LOGS_EXPORTER="otlp"                              # otlp, console, none

# ─── Propagation ───
OTEL_PROPAGATORS="tracecontext,baggage"                # tracecontext, baggage, b3, b3multi, jaeger, xray

# ─── SDK ───
OTEL_SDK_DISABLED="false"                              # Désactiver complètement le SDK
OTEL_LOG_LEVEL="info"                                  # Niveau de log du SDK lui-même

# ─── Batch Span Processor ───
OTEL_BSP_SCHEDULE_DELAY="5000"                         # Intervalle d'export en ms
OTEL_BSP_MAX_QUEUE_SIZE="2048"                         # Taille max de la queue
OTEL_BSP_MAX_EXPORT_BATCH_SIZE="512"                   # Taille max d'un batch
OTEL_BSP_EXPORT_TIMEOUT="30000"                        # Timeout d'export en ms

# ─── Attribut limits ───
OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT="4096"               # Longueur max d'une valeur d'attribut
OTEL_ATTRIBUTE_COUNT_LIMIT="128"                       # Nombre max d'attributs par span/log
OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT="128"
OTEL_SPAN_EVENT_COUNT_LIMIT="128"
OTEL_SPAN_LINK_COUNT_LIMIT="128"
```

---
