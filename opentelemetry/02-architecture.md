## 2. Architecture d'OpenTelemetry

### 2.1 Les composants principaux

OpenTelemetry est composé de quatre grandes briques :

```
┌───────────────────────────────────────────────────────────────────────┐
│                     OPENTELEMETRY - VUE D'ENSEMBLE                    │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────┐         │
│  │                    APPLICATION                           │         │
│  │                                                          │         │
│  │   ┌──────────┐         ┌──────────┐                     │         │
│  │   │  OTel    │ appelle │  OTel    │                     │         │
│  │   │  API     │────────▶│  SDK     │                     │         │
│  │   │          │         │          │                     │         │
│  │   │(interface│         │(implémen-│                     │         │
│  │   │ stable)  │         │ tation)  │                     │         │
│  │   └──────────┘         └────┬─────┘                     │         │
│  │                              │                           │         │
│  │                              │ Exporte via OTLP          │         │
│  └──────────────────────────────┼───────────────────────────┘         │
│                                 │                                     │
│                                 ▼                                     │
│  ┌──────────────────────────────────────────────────────────┐        │
│  │              OTEL COLLECTOR                               │        │
│  │                                                           │        │
│  │  Receivers ──▶ Processors ──▶ Exporters                   │        │
│  │                                                           │        │
│  │  (reçoit)      (transforme)    (envoie)                   │        │
│  └────────────────────┬──────────────┬──────────────┬────────┘        │
│                       │              │              │                  │
│                       ▼              ▼              ▼                  │
│                  Prometheus       Tempo           Loki                 │
│                  (metrics)       (traces)        (logs)               │
└───────────────────────────────────────────────────────────────────────┘
```

#### L'API

L'API est l'**interface publique** qu'utilisent les développeurs et les bibliothèques d'instrumentation. Elle définit les types et les méthodes pour créer des traces, des métriques et des logs, mais **ne contient aucune implémentation**.

Pourquoi cette séparation ? Les bibliothèques tierces (frameworks HTTP, clients de BDD, etc.) dépendent de l'API uniquement. Elles n'imposent aucun backend ni configuration. C'est l'application finale qui choisit le SDK et le configure.

L'API est conçue pour être **no-op par défaut** : si aucun SDK n'est enregistré, les appels à l'API ne font rien. Pas de crash, pas de log inutile, pas d'overhead. Cela permet aux bibliothèques de s'instrumenter sans imposer OTel comme dépendance obligatoire.

#### Le SDK

Le SDK est l'**implémentation** de l'API. Il gère :
- La création et le cycle de vie des spans, métriques et logs
- Le sampling (décision d'enregistrer ou non une trace)
- Le batching (regroupement des données avant export)
- L'export des données vers les backends (via les exporters)
- La gestion des resources (métadonnées sur la source des données)

Le SDK est configuré au démarrage de l'application. Tu choisis quels exporters utiliser, quel sampling appliquer, quelles resources attacher.

#### Les Exporters

Les exporters sont des plugins du SDK qui envoient les données vers une destination spécifique. Les principaux :

| Exporter | Protocole | Destination |
|----------|-----------|-------------|
| `otlp` | gRPC/HTTP | OTel Collector, Tempo, tout backend OTLP |
| `prometheus` | HTTP pull | Prometheus (expose un endpoint `/metrics`) |
| `console`/`stdout` | stdout | Terminal (debug) |
| `zipkin` | HTTP | Zipkin |
| `jaeger` | gRPC/Thrift | Jaeger (déprécié, utiliser OTLP) |

#### Le Collector

Le Collector est un **proxy/agent** indépendant de l'application qui reçoit, traite et réexporte les données de télémétrie. C'est le composant le plus important du point de vue DevOps. Nous le détaillons en section 6.

### 2.2 Schéma d'architecture détaillé

Voici comment les composants s'emboîtent dans une architecture réelle :

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              CLUSTER KUBERNETES                              │
│                                                                              │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐             │
│  │  Service A       │  │  Service B       │  │  Service C       │             │
│  │  (Go)            │  │  (Java)          │  │  (Python)        │             │
│  │                  │  │                  │  │                  │             │
│  │  OTel SDK ───┐   │  │  OTel Agent ─┐   │  │  OTel SDK ───┐   │             │
│  │  (traces +   │   │  │  (auto-instr │   │  │  (traces +   │   │             │
│  │   metrics)   │   │  │   zero-code) │   │  │   metrics +  │   │             │
│  └──────────────┼───┘  └──────────────┼───┘  │   logs)      │   │             │
│                 │                     │       └──────────────┼───┘             │
│                 │  OTLP (gRPC)       │  OTLP (gRPC)        │                 │
│                 │                     │                      │                 │
│                 ▼                     ▼                      ▼                 │
│  ┌────────────────────────────────────────────────────────────────┐           │
│  │                 OTEL COLLECTOR (DaemonSet)                      │           │
│  │                                                                 │           │
│  │  ┌───────────┐    ┌──────────────┐    ┌───────────────┐        │           │
│  │  │ Receivers │    │ Processors   │    │ Exporters     │        │           │
│  │  │           │    │              │    │               │        │           │
│  │  │ - otlp    │───▶│ - batch      │───▶│ - otlp (Tempo)│        │           │
│  │  │ - filelog  │    │ - memory_    │    │ - promremote  │        │           │
│  │  │ - hostmetr│    │   limiter    │    │   write       │        │           │
│  │  │ - kubelet │    │ - k8sattrib  │    │ - loki        │        │           │
│  │  │   stats   │    │ - filter     │    │               │        │           │
│  │  └───────────┘    └──────────────┘    └──────┬────────┘        │           │
│  └──────────────────────────────────────────────┼─────────────────┘           │
│                                                  │                            │
└──────────────────────────────────────────────────┼────────────────────────────┘
                                                   │
                          ┌────────────────────────┼────────────────────────┐
                          │                        │                        │
                          ▼                        ▼                        ▼
                   ┌─────────────┐         ┌─────────────┐         ┌─────────────┐
                   │   Tempo     │         │  Prometheus │         │    Loki     │
                   │  (traces)   │         │  /Mimir     │         │   (logs)    │
                   │             │         │  (metrics)  │         │             │
                   └──────┬──────┘         └──────┬──────┘         └──────┬──────┘
                          │                       │                       │
                          └───────────────────────┼───────────────────────┘
                                                  │
                                                  ▼
                                          ┌──────────────┐
                                          │   Grafana    │
                                          │              │
                                          │ Dashboards + │
                                          │ Corrélation  │
                                          │ M/L/T        │
                                          └──────────────┘
```

### 2.3 Le protocole OTLP (OpenTelemetry Protocol)

OTLP est le protocole natif d'OpenTelemetry pour transporter les données de télémétrie. C'est **le** standard à privilégier.

#### Deux transports disponibles

**OTLP/gRPC** (port par défaut : `4317`)
- Basé sur Protocol Buffers (protobuf) + HTTP/2
- Streaming bidirectionnel
- Compression native (gzip)
- Plus efficace en bande passante
- Recommandé pour les communications internes (service → collector)

**OTLP/HTTP** (port par défaut : `4318`)
- Basé sur protobuf ou JSON sur HTTP/1.1 ou HTTP/2
- Plus facile à traverser les proxies et load balancers
- Compatible avec les environnements qui ne supportent pas gRPC
- Endpoints : `/v1/traces`, `/v1/metrics`, `/v1/logs`

```
OTLP/gRPC :
  Application ──── gRPC (port 4317) ────▶ Collector
                   protobuf binaire
                   HTTP/2 multiplexé
                   Compression gzip

OTLP/HTTP :
  Application ──── HTTP POST (port 4318) ────▶ Collector
                   /v1/traces   (protobuf ou JSON)
                   /v1/metrics  (protobuf ou JSON)
                   /v1/logs     (protobuf ou JSON)
```

#### Structure d'un message OTLP

Un message OTLP suit une hiérarchie précise. Voici un exemple simplifié pour les traces :

```
ExportTraceServiceRequest
├── resource_spans[]
│   ├── resource
│   │   └── attributes[]
│   │       ├── service.name = "api-gateway"
│   │       ├── service.version = "1.2.0"
│   │       ├── deployment.environment = "production"
│   │       └── host.name = "node-01"
│   │
│   └── scope_spans[]
│       ├── scope
│       │   ├── name = "io.opentelemetry.contrib.httpserver"
│       │   └── version = "1.24.0"
│       │
│       └── spans[]
│           ├── trace_id = "abc123..."
│           ├── span_id = "def456..."
│           ├── parent_span_id = "000000..."
│           ├── name = "GET /api/users"
│           ├── kind = SERVER
│           ├── start_time = 1700000000000000000
│           ├── end_time = 1700000000050000000
│           ├── status = { code: OK }
│           ├── attributes[]
│           │   ├── http.method = "GET"
│           │   ├── http.status_code = 200
│           │   └── http.url = "/api/users"
│           └── events[]
│               └── { name: "cache.miss", timestamp: ... }
```

### 2.4 Les concepts fondamentaux

#### Resources

Une **Resource** identifie la source des données de télémétrie. C'est un ensemble d'attributs attachés à toutes les données produites par une entité (un processus, un conteneur, un service).

Attributs de resource courants :
```
service.name          = "checkout-service"      # OBLIGATOIRE
service.version       = "2.1.0"
service.namespace     = "shop"
deployment.environment = "production"
host.name             = "worker-node-03"
container.id          = "a1b2c3d4..."
cloud.provider        = "aws"
cloud.region          = "eu-west-1"
k8s.pod.name          = "checkout-7d8f9-xz4kl"
k8s.namespace.name    = "production"
```

`service.name` est le seul attribut réellement obligatoire. Sans lui, tes données seront groupées sous "unknown_service" — ce qui est inutilisable en production.

#### Attributes

Les **Attributes** sont des paires clé-valeur qui enrichissent les données de télémétrie. Ils existent à plusieurs niveaux :
- **Resource attributes** : identifient la source (voir ci-dessus)
- **Span attributes** : décrivent une opération spécifique
- **Metric attributes** (labels) : dimensions d'une métrique
- **Log attributes** : métadonnées d'un événement

Les valeurs peuvent être : string, bool, int64, float64, ou des tableaux de ces types.

#### Instrumentation Scope

L'**Instrumentation Scope** identifie la bibliothèque d'instrumentation qui a produit les données. Cela permet de distinguer les spans produits par différentes bibliothèques au sein du même service.

```
Scope: name="@opentelemetry/instrumentation-http", version="0.52.0"
  → Tous les spans HTTP produits par cette lib

Scope: name="@opentelemetry/instrumentation-pg", version="0.43.0"
  → Tous les spans PostgreSQL produits par cette lib
```

---
