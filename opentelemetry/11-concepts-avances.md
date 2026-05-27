## 11. Concepts avancés

### 11.1 Semantic Conventions

Les **Semantic Conventions** sont des spécifications qui standardisent les noms d'attributs, de métriques et de spans. Elles garantissent que toutes les instrumentations utilisent le même vocabulaire.

#### Pourquoi c'est important ?

Sans conventions : chaque bibliothèque nomme les attributs différemment.

```
# Bibliothèque A          # Bibliothèque B          # Bibliothèque C
method: "GET"              http_method: "GET"        request.method: "GET"
status: 200                statusCode: 200           http.status: 200
url: "/api/users"          path: "/api/users"        request_url: "/api/users"
```

Avec les Semantic Conventions :
```
# Toutes les bibliothèques
http.request.method: "GET"
http.response.status_code: 200
url.path: "/api/users"
```

#### Conventions principales

**HTTP** (server et client) :
```yaml
# Attributs de span
http.request.method: "GET"           # Méthode HTTP
http.response.status_code: 200       # Code de réponse
url.full: "https://example.com/api"  # URL complète
url.path: "/api"                     # Chemin
url.scheme: "https"                  # Schéma
server.address: "example.com"        # Hostname du serveur
server.port: 443                     # Port
user_agent.original: "curl/8.0"     # User agent
network.protocol.version: "1.1"     # Version HTTP

# Nom de span recommandé
# SERVER : "{http.request.method} {http.route}"  → "GET /api/users/{id}"
# CLIENT : "{http.request.method}"                → "GET"
```

**Base de données** :
```yaml
db.system: "postgresql"              # Type de BDD
db.namespace: "shop"                 # Nom de la BDD / schema
db.operation.name: "SELECT"          # Opération
db.query.text: "SELECT * FROM..."    # Requête (attention aux données sensibles)
server.address: "db-primary"         # Hostname
server.port: 5432                    # Port

# Nom de span : "{db.operation.name} {db.namespace}.{db.collection.name}"
# → "SELECT shop.orders"
```

**Messaging** (Kafka, RabbitMQ, etc.) :
```yaml
messaging.system: "kafka"
messaging.operation.type: "publish"  # ou "receive", "process"
messaging.destination.name: "orders.created"
messaging.kafka.consumer.group: "order-processor"
messaging.message.id: "msg-123"
messaging.kafka.message.offset: 42
```

**RPC** (gRPC, etc.) :
```yaml
rpc.system: "grpc"
rpc.service: "mypackage.MyService"
rpc.method: "MyMethod"
rpc.grpc.status_code: 0  # OK
```

**Infrastructure** :
```yaml
# Container
container.id: "abc123..."
container.name: "my-app"
container.image.name: "myregistry/my-app"
container.image.tags: ["v1.2.3"]

# Kubernetes
k8s.cluster.name: "production"
k8s.namespace.name: "shop"
k8s.pod.name: "order-service-7d8f9-xz4kl"
k8s.deployment.name: "order-service"
k8s.node.name: "worker-03"

# Cloud
cloud.provider: "aws"
cloud.region: "eu-west-1"
cloud.availability_zone: "eu-west-1a"
cloud.account.id: "123456789"
cloud.platform: "aws_eks"
```

### 11.2 Baggage

Le **Baggage** est un mécanisme de propagation de données contextuelles entre services. Contrairement au trace context (qui propage uniquement les identifiants de trace), le baggage propage des données métier arbitraires.

```
Service A                          Service B                        Service C
┌──────────┐                      ┌──────────┐                     ┌──────────┐
│          │                      │          │                     │          │
│ Baggage: │ ── propagation ────▶ │ Baggage: │ ── propagation ───▶│ Baggage: │
│ user.id  │    (HTTP header)     │ user.id  │   (HTTP header)    │ user.id  │
│ = "u123" │                      │ = "u123" │                    │ = "u123" │
│ tenant   │                      │ tenant   │                    │ tenant   │
│ = "acme" │                      │ = "acme" │                    │ = "acme" │
└──────────┘                      └──────────┘                     └──────────┘
                                                                   
Header HTTP propagé :
baggage: user.id=u123,tenant=acme
```

```go
// Go : définir un baggage
import "go.opentelemetry.io/otel/baggage"

member1, _ := baggage.NewMember("user.id", "u123")
member2, _ := baggage.NewMember("tenant", "acme")
bag, _ := baggage.New(member1, member2)
ctx = baggage.ContextWithBaggage(ctx, bag)

// Plus tard, dans un autre service (le baggage est propagé automatiquement) :
bag := baggage.FromContext(ctx)
userID := bag.Member("user.id").Value()  // "u123"
tenant := bag.Member("tenant").Value()    // "acme"
```

**Cas d'usage** :
- Propager un tenant ID dans une architecture multi-tenant
- Propager un user ID pour le debug
- Propager des feature flags entre services
- Propager un request ID métier

**Attention** : Le baggage est propagé dans les headers HTTP en clair. Ne jamais y mettre de données sensibles (tokens, mots de passe, PII). Le baggage traverse potentiellement des services que tu ne contrôles pas.

### 11.3 Resource detection

Les **Resource Detectors** identifient automatiquement l'environnement d'exécution et enrichissent les données avec les attributs appropriés.

```go
// Go : resource detection automatique
import (
    "go.opentelemetry.io/otel/sdk/resource"
    "go.opentelemetry.io/contrib/detectors/aws/ec2"
    "go.opentelemetry.io/contrib/detectors/aws/ecs"
    "go.opentelemetry.io/contrib/detectors/gcp"
)

res, err := resource.New(ctx,
    // Détection automatique de l'environnement
    resource.WithHost(),           // host.name, host.id, host.arch, os.type
    resource.WithProcess(),        // process.pid, process.executable.name
    resource.WithContainer(),      // container.id
    resource.WithTelemetrySDK(),   // telemetry.sdk.name, .version, .language

    // Détecteurs cloud spécifiques
    resource.WithDetectors(
        ec2.NewResourceDetector(),  // cloud.provider, cloud.region, host.id (EC2)
        ecs.NewResourceDetector(),  // aws.ecs.cluster.arn, aws.ecs.task.arn
        gcp.NewDetector(),          // cloud.provider, cloud.region (GCP)
    ),

    // Attributs manuels (priorité la plus haute)
    resource.WithAttributes(
        semconv.ServiceName("order-service"),
        semconv.ServiceVersion("2.1.0"),
        semconv.DeploymentEnvironment("production"),
    ),
)
```

Dans le Collector, le processor `resourcedetection` fait la même chose :

```yaml
processors:
  resourcedetection:
    detectors:
      - env             # Lit OTEL_RESOURCE_ATTRIBUTES
      - system          # host.name, os.type
      - docker          # container.id, container.name
      - ec2             # AWS EC2 metadata
      - ecs             # AWS ECS metadata
      - eks             # AWS EKS metadata
      - gcp             # GCP metadata
      - azure           # Azure metadata
    timeout: 5s
    override: false     # Ne pas écraser les attributs déjà présents
```

### 11.4 Feature gates et stabilité des composants

OpenTelemetry utilise un système de **feature gates** pour activer/désactiver des fonctionnalités et un modèle de **maturité** pour indiquer la stabilité de chaque composant.

#### Niveaux de stabilité

| Niveau | Signification | Engagement |
|--------|--------------|------------|
| **Stable** | Prêt pour la production | API gelée, pas de breaking changes |
| **Beta** | Fonctionnel mais l'API peut changer | Breaking changes possibles entre versions mineures |
| **Alpha** | Expérimental | API instable, peut être supprimé |
| **Development** | En cours de développement | Ne pas utiliser |
| **Deprecated** | En fin de vie | Sera supprimé dans une future version |

#### État actuel (2025)

```
┌────────────────────────┬──────────┬──────────┬──────────┐
│ Composant              │ Traces   │ Metrics  │ Logs     │
├────────────────────────┼──────────┼──────────┼──────────┤
│ API (spécification)    │ Stable   │ Stable   │ Stable   │
│ SDK (Go, Java, etc.)   │ Stable   │ Stable   │ Stable   │
│ OTLP (protocole)       │ Stable   │ Stable   │ Stable   │
│ Collector (core)       │ Stable   │ Stable   │ Stable   │
│ Semantic Conventions   │ Mixte (HTTP: stable, DB: stable, Messaging: stable) │
│ Profiling              │ ───────── Development ─────────│
│ Events                 │ ───────── Experimental ────────│
└────────────────────────┴──────────┴──────────┴──────────┘
```

#### Feature gates dans le Collector

Le Collector permet d'activer/désactiver des fonctionnalités via des feature gates :

```bash
# Lister les feature gates disponibles
otelcol --feature-gates=help

# Activer une feature gate
otelcol --feature-gates=exporter.prometheusremotewrite.EnableCreatedMetric

# Désactiver une feature gate
otelcol --feature-gates=-processor.batch.useGranularBatching
```

Les feature gates suivent un cycle de vie :
1. **Alpha** : désactivé par défaut, opt-in
2. **Beta** : activé par défaut, peut être désactivé
3. **Stable** : toujours activé, ne peut pas être désactivé
4. **Removed** : supprimé du code

#### Collector Core vs Contrib

Deux distributions du Collector :

```
otel/opentelemetry-collector          (Core)
├── Receivers : otlp
├── Processors : batch, memory_limiter
├── Exporters : otlp, debug, otlphttp
└── Minimal, supporté officiellement

otel/opentelemetry-collector-contrib  (Contrib)
├── Tout ce qui est dans Core
├── + 200+ composants additionnels
│   ├── Receivers : prometheus, filelog, hostmetrics, kafka, etc.
│   ├── Processors : k8sattributes, filter, transform, etc.
│   ├── Exporters : prometheusremotewrite, loki, datadog, etc.
│   └── Connectors : spanmetrics, servicegraph, etc.
└── Certains composants sont alpha/beta
```

**Recommandation** : Utilise `contrib` en production. C'est la distribution la plus courante. Si tu as des contraintes de sécurité strictes, tu peux construire un Collector custom avec le **OCB (OpenTelemetry Collector Builder)** en sélectionnant uniquement les composants dont tu as besoin :

```yaml
# ocb-config.yaml
dist:
  name: my-custom-collector
  description: "Custom collector with only needed components"
  output_path: ./dist

receivers:
  - gomod: go.opentelemetry.io/collector/receiver/otlpreceiver v0.116.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/receiver/prometheusreceiver v0.116.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/receiver/filelogreceiver v0.116.0

processors:
  - gomod: go.opentelemetry.io/collector/processor/batchprocessor v0.116.0
  - gomod: go.opentelemetry.io/collector/processor/memorylimiterprocessor v0.116.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/processor/filterprocessor v0.116.0

exporters:
  - gomod: go.opentelemetry.io/collector/exporter/otlpexporter v0.116.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/exporter/prometheusremotewriteexporter v0.116.0
  - gomod: github.com/open-telemetry/opentelemetry-collector-contrib/exporter/lokiexporter v0.116.0
```

```bash
# Construire le Collector custom
ocb --config=ocb-config.yaml
```

---
