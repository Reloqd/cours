## 7. Instrumentation

### 7.1 Auto-instrumentation vs instrumentation manuelle

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│  Auto-instrumentation (zero-code)     Instrumentation manuelle          │
│  ─────────────────────────────────    ──────────────────────────        │
│                                                                         │
│  ✓ Aucune modification du code       ✓ Contrôle total                  │
│  ✓ Déploiement rapide                ✓ Spans custom métier             │
│  ✓ Couvre HTTP, gRPC, BDD, etc.      ✓ Attributs custom précis        │
│                                                                         │
│  ✗ Pas de spans métier custom        ✗ Effort de développement         │
│  ✗ Attributs limités au générique    ✗ Maintenance du code             │
│  ✗ Overhead potentiel                ✗ Risque d'oubli                  │
│                                                                         │
│  RECOMMANDATION : Commencer par l'auto-instrumentation,                │
│  puis ajouter de l'instrumentation manuelle pour les                   │
│  opérations métier critiques.                                          │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 7.2 Langages supportés et maturité

| Langage | Traces | Metrics | Logs | Auto-instrumentation |
|---------|--------|---------|------|---------------------|
| **Java** | Stable | Stable | Stable | Oui (agent JAR) |
| **Go** | Stable | Stable | Stable | Non (compile-time) |
| **Python** | Stable | Stable | Stable | Oui (pip package) |
| **JavaScript/Node.js** | Stable | Stable | Stable | Oui (require hook) |
| **.NET** | Stable | Stable | Stable | Oui (CLR profiler) |
| **Rust** | Stable | Alpha | Alpha | Non |
| **C++** | Stable | Stable | Non | Non |
| **PHP** | Stable | Beta | Non | Oui (extension) |
| **Ruby** | Stable | Beta | Non | Oui (gem) |
| **Swift** | Stable | Stable | Non | Non |
| **Erlang/Elixir** | Stable | Stable | Beta | Oui (partiel) |

### 7.3 Instrumentation zero-code

#### Java (Agent JAR)

L'agent Java est le plus mature. Un seul JAR, aucune modification du code source.

```bash
# Télécharger l'agent
curl -L -o opentelemetry-javaagent.jar \
  https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar

# Lancer l'application avec l'agent
java -javaagent:opentelemetry-javaagent.jar \
     -Dotel.service.name=order-service \
     -Dotel.exporter.otlp.endpoint=http://otel-collector:4317 \
     -Dotel.exporter.otlp.protocol=grpc \
     -Dotel.traces.sampler=parentbased_traceidratio \
     -Dotel.traces.sampler.arg=0.1 \
     -Dotel.metrics.exporter=otlp \
     -Dotel.logs.exporter=otlp \
     -jar myapp.jar
```

Ou via variables d'environnement (plus pratique pour Docker/K8s) :
```yaml
# docker-compose.yml
services:
  order-service:
    image: myapp:latest
    environment:
      JAVA_TOOL_OPTIONS: "-javaagent:/opt/opentelemetry-javaagent.jar"
      OTEL_SERVICE_NAME: "order-service"
      OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector:4317"
      OTEL_EXPORTER_OTLP_PROTOCOL: "grpc"
      OTEL_TRACES_SAMPLER: "parentbased_traceidratio"
      OTEL_TRACES_SAMPLER_ARG: "0.1"
      OTEL_METRICS_EXPORTER: "otlp"
      OTEL_LOGS_EXPORTER: "otlp"
      OTEL_RESOURCE_ATTRIBUTES: "deployment.environment=production,service.version=2.1.0"
    volumes:
      - ./opentelemetry-javaagent.jar:/opt/opentelemetry-javaagent.jar:ro
```

L'agent Java instrumente automatiquement :
- Serveurs HTTP : Spring Boot, Jakarta EE, Tomcat, Jetty, Netty
- Clients HTTP : OkHttp, Apache HttpClient, Java HttpClient
- Frameworks : Spring MVC, Spring WebFlux, JAX-RS, gRPC
- Bases de données : JDBC (PostgreSQL, MySQL, etc.), Hibernate, R2DBC
- Messaging : Kafka, RabbitMQ, JMS, AWS SQS
- Caching : Redis (Jedis, Lettuce), Memcached
- Logging : Log4j2, Logback, JUL (injection de trace_id)

#### Python

```bash
# Installer les packages
pip install opentelemetry-distro opentelemetry-exporter-otlp

# Installer automatiquement les instrumentations disponibles
opentelemetry-bootstrap -a install

# Lancer l'application avec auto-instrumentation
opentelemetry-instrument \
    --service_name=payment-service \
    --exporter_otlp_endpoint=http://otel-collector:4317 \
    --exporter_otlp_protocol=grpc \
    python app.py
```

Ou via variables d'environnement :
```yaml
services:
  payment-service:
    build: .
    command: opentelemetry-instrument python app.py
    environment:
      OTEL_SERVICE_NAME: "payment-service"
      OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector:4317"
      OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED: "true"
```

Frameworks auto-instrumentés : Flask, Django, FastAPI, requests, urllib3, psycopg2, SQLAlchemy, Redis, Celery, Kafka, gRPC, etc.

#### Node.js

```bash
npm install @opentelemetry/auto-instrumentations-node \
            @opentelemetry/exporter-trace-otlp-grpc \
            @opentelemetry/exporter-metrics-otlp-grpc \
            @opentelemetry/sdk-node
```

```javascript
// tracing.js — charger AVANT l'application
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-grpc');
const { OTLPMetricExporter } = require('@opentelemetry/exporter-metrics-otlp-grpc');
const { PeriodicExportingMetricReader } = require('@opentelemetry/sdk-metrics');

const sdk = new NodeSDK({
  serviceName: 'api-gateway',
  traceExporter: new OTLPTraceExporter({
    url: 'http://otel-collector:4317',
  }),
  metricReader: new PeriodicExportingMetricReader({
    exporter: new OTLPMetricExporter({
      url: 'http://otel-collector:4317',
    }),
    exportIntervalMillis: 30000,
  }),
  instrumentations: [
    getNodeAutoInstrumentations({
      // Désactiver le fs instrumentation (trop verbeux)
      '@opentelemetry/instrumentation-fs': { enabled: false },
    }),
  ],
});

sdk.start();
```

```bash
# Lancer avec --require pour charger le tracing avant l'app
node --require ./tracing.js app.js
```

Frameworks auto-instrumentés : Express, Fastify, Koa, Hapi, http/https natif, fetch, MongoDB, pg (PostgreSQL), mysql2, Redis (ioredis), gRPC, Kafka (kafkajs), AWS SDK, etc.

#### Instrumentation manuelle (exemple Go)

Go ne supporte pas l'auto-instrumentation car c'est un langage compilé. L'instrumentation est explicite.

```go
package main

import (
    "context"
    "log"
    "net/http"
    "time"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/propagation"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.24.0"
    "go.opentelemetry.io/otel/trace"
    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

func initTracer(ctx context.Context) (*sdktrace.TracerProvider, error) {
    // Créer l'exporter OTLP gRPC
    exporter, err := otlptracegrpc.New(ctx,
        otlptracegrpc.WithEndpoint("otel-collector:4317"),
        otlptracegrpc.WithInsecure(),
    )
    if err != nil {
        return nil, err
    }

    // Créer la resource
    res, err := resource.New(ctx,
        resource.WithAttributes(
            semconv.ServiceName("inventory-service"),
            semconv.ServiceVersion("1.0.0"),
            semconv.DeploymentEnvironment("production"),
        ),
        resource.WithHost(),        // Ajoute host.name, host.id, etc.
        resource.WithContainer(),   // Ajoute container.id
        resource.WithProcess(),     // Ajoute process.pid, etc.
    )
    if err != nil {
        return nil, err
    }

    // Créer le TracerProvider
    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exporter,
            sdktrace.WithBatchTimeout(5*time.Second),
            sdktrace.WithMaxExportBatchSize(512),
        ),
        sdktrace.WithResource(res),
        sdktrace.WithSampler(sdktrace.ParentBased(
            sdktrace.TraceIDRatioBased(0.1),
        )),
    )

    // Enregistrer globalement
    otel.SetTracerProvider(tp)
    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{},  // W3C Trace Context
        propagation.Baggage{},       // W3C Baggage
    ))

    return tp, nil
}

// Créer un tracer pour ce package
var tracer = otel.Tracer("inventory-service/handlers")

func getStockHandler(w http.ResponseWriter, r *http.Request) {
    // Créer un span
    ctx, span := tracer.Start(r.Context(), "getStock",
        trace.WithAttributes(
            attribute.String("product.id", r.URL.Query().Get("id")),
        ),
    )
    defer span.End()

    // Appel à la base de données (child span)
    stock, err := queryDatabase(ctx, r.URL.Query().Get("id"))
    if err != nil {
        span.RecordError(err)
        span.SetStatus(codes.Error, err.Error())
        http.Error(w, "Internal error", 500)
        return
    }

    // Ajouter un événement
    span.AddEvent("stock.retrieved",
        trace.WithAttributes(
            attribute.Int("stock.quantity", stock.Quantity),
        ),
    )

    // Répondre
    w.WriteHeader(200)
    json.NewEncoder(w).Encode(stock)
}

func queryDatabase(ctx context.Context, productID string) (*Stock, error) {
    ctx, span := tracer.Start(ctx, "SELECT stock",
        trace.WithSpanKind(trace.SpanKindClient),
        trace.WithAttributes(
            attribute.String("db.system", "postgresql"),
            attribute.String("db.name", "inventory"),
            attribute.String("db.statement", "SELECT quantity FROM stock WHERE product_id = $1"),
        ),
    )
    defer span.End()

    // ... exécuter la requête
    return &Stock{Quantity: 42}, nil
}

func main() {
    ctx := context.Background()
    tp, err := initTracer(ctx)
    if err != nil {
        log.Fatal(err)
    }
    defer tp.Shutdown(ctx)

    // Utiliser otelhttp pour instrumenter automatiquement le serveur HTTP
    handler := http.NewServeMux()
    handler.HandleFunc("/stock", getStockHandler)

    // otelhttp crée automatiquement des spans pour chaque requête HTTP
    wrappedHandler := otelhttp.NewHandler(handler, "inventory-http-server")

    log.Println("Starting server on :8080")
    http.ListenAndServe(":8080", wrappedHandler)
}
```

### 7.4 Instrumentation des middlewares/proxies

#### Traefik

Traefik supporte nativement OpenTelemetry depuis la version 3.0.

```yaml
# traefik.yml (configuration statique)
tracing:
  otlp:
    grpc:
      endpoint: "otel-collector:4317"
      insecure: true
    # OU HTTP :
    # http:
    #   endpoint: "http://otel-collector:4318/v1/traces"

# Attributs ajoutés automatiquement par Traefik :
# - http.request.method
# - http.response.status_code
# - url.path
# - http.route
# - server.address
# - traefik.router.name
# - traefik.service.name
```

```yaml
# docker-compose.yml avec Traefik + OTel
services:
  traefik:
    image: traefik:v3.1
    command:
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--tracing.otlp.grpc.endpoint=otel-collector:4317"
      - "--tracing.otlp.grpc.insecure=true"
      - "--metrics.otlp.grpc.endpoint=otel-collector:4317"
      - "--metrics.otlp.grpc.insecure=true"
    ports:
      - "80:80"
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
```

Traefik propage automatiquement les headers W3C Trace Context. Si une requête arrive avec un `traceparent`, Traefik crée un child span. Sinon, il crée un root span.

#### Nginx (module OpenTelemetry)

```nginx
# nginx.conf avec le module OTel
load_module modules/ngx_otel_module.so;

http {
    otel_exporter {
        endpoint otel-collector:4317;
    }

    otel_service_name "nginx-gateway";
    otel_trace on;
    otel_trace_context propagate;

    server {
        listen 80;

        location /api/ {
            otel_trace on;
            otel_span_name "nginx-proxy";
            otel_span_attr "nginx.upstream" "$upstream_addr";

            proxy_pass http://backend:8080;
        }
    }
}
```

#### Envoy

Envoy a un support natif d'OpenTelemetry via son tracing provider :

```yaml
# envoy.yaml
static_resources:
  listeners:
    - address:
        socket_address:
          address: 0.0.0.0
          port_value: 8080
      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                tracing:
                  provider:
                    name: envoy.tracers.opentelemetry
                    typed_config:
                      "@type": type.googleapis.com/envoy.config.trace.v3.OpenTelemetryConfig
                      grpc_service:
                        envoy_grpc:
                          cluster_name: otel_collector
                      service_name: envoy-gateway
```

### 7.5 Instrumentation des bases de données et message brokers

#### PostgreSQL (via l'application)

L'instrumentation des BDD se fait côté client (dans l'application), pas sur le serveur de BDD lui-même :

```python
# Python avec psycopg2 instrumenté
from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor

Psycopg2Instrumentor().instrument()

# Chaque requête SQL génère un span :
# name: "SELECT orders"
# attributes:
#   db.system: "postgresql"
#   db.name: "shop"
#   db.statement: "SELECT * FROM orders WHERE user_id = $1"
#   db.operation: "SELECT"
#   server.address: "postgres-primary"
#   server.port: 5432
```

#### Kafka

```java
// Java : l'agent instrumente automatiquement Kafka Producer/Consumer
// Spans générés :
//
// Producer span :
//   name: "orders.created publish"
//   kind: PRODUCER
//   attributes:
//     messaging.system: "kafka"
//     messaging.destination.name: "orders.created"
//     messaging.operation: "publish"
//
// Consumer span :
//   name: "orders.created process"
//   kind: CONSUMER
//   attributes:
//     messaging.system: "kafka"
//     messaging.destination.name: "orders.created"
//     messaging.operation: "process"
//     messaging.kafka.consumer.group: "order-processor"
//     messaging.kafka.message.offset: 12345
//
// Le trace context est propagé via les headers Kafka
// → la trace relie le producer au consumer
```

#### Redis

```javascript
// Node.js avec ioredis instrumenté
const { IORedisInstrumentation } = require('@opentelemetry/instrumentation-ioredis');

// Span généré :
// name: "GET"
// kind: CLIENT
// attributes:
//   db.system: "redis"
//   db.statement: "GET user:session:abc123"
//   server.address: "redis-primary"
//   server.port: 6379
//   db.redis.database_index: 0
```

---
