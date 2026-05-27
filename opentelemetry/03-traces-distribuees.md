## 3. Les Traces distribuées (en profondeur)

### 3.1 Qu'est-ce qu'une trace, un span, un context ?

#### Trace

Une **trace** représente le parcours complet d'une requête à travers un système distribué. Elle est identifiée par un **trace_id** unique (128 bits, soit 32 caractères hexadécimaux).

Une trace est composée d'un ou plusieurs **spans**, organisés en arbre (relation parent-enfant).

#### Span

Un **span** représente une **opération unitaire** au sein d'une trace. Chaque span possède :

| Champ | Description | Exemple |
|-------|-------------|---------|
| `trace_id` | ID de la trace parente | `4bf92f3577b34da6a3ce929d0e0e4736` |
| `span_id` | ID unique du span | `00f067aa0ba902b7` |
| `parent_span_id` | ID du span parent (vide si root) | `a3ce929d0e0e4736` |
| `name` | Nom de l'opération | `GET /api/users/{id}` |
| `kind` | Type de span | `SERVER`, `CLIENT`, `INTERNAL`, `PRODUCER`, `CONSUMER` |
| `start_time` | Timestamp de début (nanoseconds) | `1700000000000000000` |
| `end_time` | Timestamp de fin (nanoseconds) | `1700000000050000000` |
| `status` | Code de statut | `OK`, `ERROR`, `UNSET` |
| `attributes` | Paires clé-valeur | `http.method=GET` |
| `events` | Événements horodatés dans le span | Exception, log, etc. |
| `links` | Liens vers d'autres spans/traces | Batch processing |

**Span Kind** (type de span) :

```
CLIENT  ──── Appel sortant vers un autre service
              Ex: requête HTTP vers un autre microservice
              Ex: query vers une base de données

SERVER  ──── Traitement d'un appel entrant
              Ex: handler HTTP qui reçoit une requête

INTERNAL ─── Opération interne au service
              Ex: appel à une fonction métier

PRODUCER ─── Envoi d'un message asynchrone
              Ex: publication sur un topic Kafka

CONSUMER ─── Réception d'un message asynchrone
              Ex: consommation d'un message Kafka
```

#### Context

Le **context** (ou span context) est l'information minimale nécessaire pour relier un span à sa trace. Il contient :
- `trace_id` : identifiant de la trace
- `span_id` : identifiant du span courant
- `trace_flags` : drapeaux (sampled ou non)
- `trace_state` : informations vendor-specific (optionnel)

Le context est ce qui est **propagé** entre les services (via les headers HTTP, les métadonnées gRPC, les headers Kafka, etc.).

### 3.2 Propagation de contexte

La propagation de contexte est le mécanisme qui permet de relier les spans à travers les frontières de processus (appels réseau, messages asynchrones, etc.).

```
Service A                          Service B                        Service C
┌──────────┐                      ┌──────────┐                     ┌──────────┐
│          │   HTTP Request       │          │   gRPC Request      │          │
│  Span 1  │─────────────────────▶│  Span 2  │────────────────────▶│  Span 3  │
│          │                      │          │                     │          │
│          │  Headers:            │          │  Metadata:          │          │
│          │  traceparent:        │          │  traceparent:       │          │
│          │  00-{trace_id}-      │          │  00-{trace_id}-     │          │
│          │  {span_1_id}-01     │          │  {span_2_id}-01    │          │
└──────────┘                      └──────────┘                     └──────────┘
```

#### W3C Trace Context (standard recommandé)

Le header `traceparent` suit le format W3C :

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
              ──  ────────────────────────────────  ────────────────  ──
              │              │                           │            │
           version      trace-id                     parent-id   trace-flags
           (00)         (128 bits)                   (64 bits)   (01=sampled)
```

Le header optionnel `tracestate` transporte des informations vendor-specific :
```
tracestate: rojo=00f067aa0ba902b7,congo=t61rcWkgMzE
```

#### B3 Propagation (Zipkin legacy)

Format historique de Zipkin, encore utilisé dans certains environnements :

```
# Format multi-header
X-B3-TraceId: 4bf92f3577b34da6a3ce929d0e0e4736
X-B3-SpanId: 00f067aa0ba902b7
X-B3-ParentSpanId: a3ce929d0e0e4736
X-B3-Sampled: 1

# Format single-header (compact)
b3: 4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-1-a3ce929d0e0e4736
```

**Recommandation** : Utilise W3C Trace Context. C'est le standard. B3 n'est utile que pour la compatibilité avec des systèmes legacy.

### 3.3 Parent/child spans, attributs, événements, statut

#### Relations parent-enfant

Les spans forment un arbre. Le span racine (root span) n'a pas de parent. Chaque span enfant référence son parent via `parent_span_id`.

```
Trace abc123 :

[Root Span] GET /api/orders/42                          0ms ─────────── 120ms
  │
  ├── [Child] authenticate_user                         2ms ──── 8ms
  │
  ├── [Child] SELECT * FROM orders WHERE id=42          10ms ────── 35ms
  │     │
  │     └── [Child] pg_connection_pool.acquire           10ms ── 12ms
  │
  ├── [Child] GET http://inventory-svc/stock/42          36ms ─────────── 95ms
  │     │
  │     └── [Child] (inventory-svc) handle_request       38ms ────────── 93ms
  │           │
  │           └── [Child] Redis GET stock:42              40ms ── 42ms
  │
  └── [Child] serialize_response                        96ms ─── 118ms
```

#### Span Attributes

Les attributs enrichissent un span avec du contexte spécifique. Les Semantic Conventions d'OTel définissent des noms standardisés :

```yaml
# Attributs HTTP (convention sémantique)
http.request.method: "GET"
http.response.status_code: 200
url.full: "https://api.example.com/orders/42"
url.path: "/orders/42"
server.address: "api.example.com"
server.port: 443
network.protocol.version: "1.1"
user_agent.original: "Mozilla/5.0..."

# Attributs base de données
db.system: "postgresql"
db.name: "orders_db"
db.statement: "SELECT * FROM orders WHERE id = $1"
db.operation: "SELECT"

# Attributs RPC
rpc.system: "grpc"
rpc.service: "inventory.StockService"
rpc.method: "GetStock"
rpc.grpc.status_code: 0

# Attributs custom (spécifiques à ton métier)
order.id: "42"
order.total_amount: 99.99
customer.tier: "premium"
```

#### Span Events

Les events sont des **logs structurés horodatés** attachés à un span. Ils représentent un événement ponctuel survenu pendant l'exécution du span.

```
Span: "process_payment"
  Events:
    ├── timestamp=T1, name="payment.validation.start"
    │   attributes: { validation.type: "3ds" }
    │
    ├── timestamp=T2, name="payment.gateway.timeout"
    │   attributes: { gateway: "stripe", timeout_ms: 5000 }
    │
    └── timestamp=T3, name="exception"
        attributes: {
          exception.type: "PaymentTimeoutError"
          exception.message: "Stripe gateway timeout after 5000ms"
          exception.stacktrace: "at PaymentService.process..."
        }
```

L'event `exception` est un cas spécial : la Semantic Convention définit des attributs standardisés (`exception.type`, `exception.message`, `exception.stacktrace`) que les backends d'observabilité savent interpréter.

#### Span Status

Trois codes de statut possibles :

| Code | Signification | Quand l'utiliser |
|------|--------------|------------------|
| `UNSET` | Par défaut | L'opération peut avoir réussi ou échoué, pas d'avis |
| `OK` | Succès explicite | L'opération a réussi (rarement nécessaire) |
| `ERROR` | Erreur | L'opération a échoué |

**Piège courant** : Ne mets pas `OK` sur chaque span qui réussit. `UNSET` est suffisant et idiomatique. Réserve `OK` pour les cas où tu veux explicitement marquer un succès malgré des signaux ambigus (ex: un 404 qui est un comportement normal).

### 3.4 Sampling (échantillonnage)

Le sampling est crucial en production : tracer 100% des requêtes génère un volume de données énorme et coûteux. Le sampling permet de ne conserver qu'un sous-ensemble représentatif.

#### Head-based sampling (décision au départ)

La décision d'échantillonner est prise **au début de la trace** (quand le root span est créé). Tous les spans de la trace suivent cette décision.

```
                    Requête arrive
                         │
                         ▼
                 ┌───────────────┐
                 │  Sampler      │
                 │  Probabilité  │
                 │  = 10%        │
                 └───────┬───────┘
                    │         │
              Sampled(10%) Not sampled(90%)
                    │         │
                    ▼         ▼
              Trace         Trace
              complète      ignorée
              exportée      (aucun span
                            enregistré)
```

Configuration dans le SDK :
```go
// Go : échantillonner 10% des traces
tp := trace.NewTracerProvider(
    trace.WithSampler(trace.TraceIDRatioBased(0.1)),
)

// Toujours échantillonner les erreurs, 10% du reste
tp := trace.NewTracerProvider(
    trace.WithSampler(trace.ParentBased(
        trace.TraceIDRatioBased(0.1),
    )),
)
```

**Avantage** : Simple, prévisible, faible overhead.
**Inconvénient** : Tu perds 90% des traces, y compris les erreurs rares et les requêtes lentes.

#### Tail-based sampling (décision à la fin)

La décision est prise **après** que tous les spans de la trace ont été collectés. Le Collector analyse la trace complète et décide de la conserver ou non.

```
Service A ──▶ ┌─────────────────────────┐
Service B ──▶ │   OTel Collector        │
Service C ──▶ │   (tail_sampling)       │
              │                         │
              │ Règles :                │
              │ - Erreurs → 100%        │
              │ - Latence > 2s → 100%   │
              │ - Route /health → 0%    │
              │ - Reste → 5%            │
              │                         │
              └────────┬────────────────┘
                       │
                       ▼
              Traces filtrées et
              pertinentes uniquement
```

Configuration du processor `tail_sampling` dans le Collector :
```yaml
processors:
  tail_sampling:
    # Temps d'attente pour recevoir tous les spans d'une trace
    decision_wait: 10s
    # Nombre max de traces en mémoire
    num_traces: 100000
    # Nombre attendu de nouveaux spans par seconde
    expected_new_traces_per_sec: 1000
    policies:
      # Conserver 100% des traces avec des erreurs
      - name: errors-policy
        type: status_code
        status_code:
          status_codes: [ERROR]

      # Conserver 100% des traces lentes (> 2 secondes)
      - name: latency-policy
        type: latency
        latency:
          threshold_ms: 2000

      # Ignorer les health checks
      - name: drop-healthcheck
        type: string_attribute
        string_attribute:
          key: http.route
          values: ["/health", "/ready", "/live"]
          enabled_regex_matching: true
          invert_match: true

      # Conserver 5% du reste
      - name: probabilistic-policy
        type: probabilistic
        probabilistic:
          sampling_percentage: 5
```

**Avantage** : Tu conserves les traces intéressantes (erreurs, latence élevée) même si elles sont rares.
**Inconvénient** : Le Collector doit garder les traces en mémoire pendant `decision_wait`, ce qui consomme significativement plus de RAM. Nécessite que tous les spans d'une trace passent par le même Collector (problématique en mode DaemonSet multi-noeud).

#### Sampling probabiliste (compromis)

Un ratio fixe basé sur le trace_id. Comme le trace_id est partagé par tous les spans, la décision est cohérente même si les services utilisent des Collectors différents.

```yaml
processors:
  probabilistic_sampler:
    sampling_percentage: 15  # Garder 15% des traces
    hash_seed: 42            # Seed pour reproductibilité
```

### 3.5 Exemple concret : suivre une requête HTTP à travers 3 microservices

Scénario : un utilisateur passe une commande. La requête traverse `api-gateway` → `order-service` → `payment-service`.

```
Utilisateur
    │
    │ POST /api/orders
    │ (aucun header traceparent)
    ▼
┌─────────────────────────────────────────────────────────────────────┐
│ api-gateway (Node.js)                                               │
│                                                                     │
│ Le SDK crée un root span car il n'y a pas de contexte parent       │
│                                                                     │
│ Span: name="POST /api/orders"                                      │
│       trace_id=aaaa...1111                                         │
│       span_id=bbbb...2222                                          │
│       parent_span_id=<none>                                        │
│       kind=SERVER                                                  │
│       attributes:                                                  │
│         http.request.method=POST                                   │
│         url.path=/api/orders                                       │
│         http.response.status_code=201                              │
│                                                                     │
│ L'API gateway appelle order-service via HTTP.                      │
│ Le SDK injecte automatiquement le header traceparent :             │
│ traceparent: 00-aaaa...1111-bbbb...2222-01                        │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              │ POST /orders (avec traceparent)
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ order-service (Java)                                                │
│                                                                     │
│ Le SDK extrait le contexte du header traceparent                   │
│ Il crée un child span avec le même trace_id                        │
│                                                                     │
│ Span: name="POST /orders"                                          │
│       trace_id=aaaa...1111          (même trace !)                 │
│       span_id=cccc...3333           (nouveau span_id)              │
│       parent_span_id=bbbb...2222    (parent = api-gateway)         │
│       kind=SERVER                                                  │
│       attributes:                                                  │
│         http.request.method=POST                                   │
│         order.id=ORD-12345                                         │
│                                                                     │
│   Child span interne :                                             │
│   Span: name="INSERT orders"                                       │
│         trace_id=aaaa...1111                                       │
│         span_id=dddd...4444                                        │
│         parent_span_id=cccc...3333                                 │
│         kind=CLIENT                                                │
│         attributes:                                                │
│           db.system=postgresql                                     │
│           db.statement="INSERT INTO orders..."                     │
│                                                                     │
│ Ensuite, order-service appelle payment-service.                    │
│ Header injecté : traceparent: 00-aaaa...1111-cccc...3333-01       │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              │ POST /payments (avec traceparent)
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│ payment-service (Python)                                            │
│                                                                     │
│ Span: name="POST /payments"                                        │
│       trace_id=aaaa...1111          (même trace !)                 │
│       span_id=eeee...5555                                          │
│       parent_span_id=cccc...3333    (parent = order-service)       │
│       kind=SERVER                                                  │
│       attributes:                                                  │
│         payment.method=credit_card                                 │
│         payment.amount=99.99                                       │
│                                                                     │
│   Child span :                                                     │
│   Span: name="POST https://api.stripe.com/v1/charges"             │
│         trace_id=aaaa...1111                                       │
│         span_id=ffff...6666                                        │
│         parent_span_id=eeee...5555                                 │
│         kind=CLIENT                                                │
│         attributes:                                                │
│           http.request.method=POST                                 │
│           server.address=api.stripe.com                            │
└─────────────────────────────────────────────────────────────────────┘
```

Résultat : tous ces spans partagent le même `trace_id=aaaa...1111`. Un backend comme Tempo ou Jaeger peut reconstituer l'arbre complet.

### 3.6 Visualisation dans Tempo / Jaeger

Voici comment cette trace apparaît dans Grafana Tempo ou Jaeger :

```
Trace: aaaa...1111    Duration: 320ms    Services: 3    Spans: 6

│ Service          │ Operation                              │ Duration │
├──────────────────┼────────────────────────────────────────┼──────────┤
│ api-gateway      │ POST /api/orders                       │ ████████████████████████████████  320ms
│ order-service    │ POST /orders                           │   ██████████████████████████████  290ms
│ order-service    │ INSERT orders                          │     ████                           25ms
│ order-service    │ POST /payments (client)                │          █████████████████████     210ms
│ payment-service  │ POST /payments                         │           ████████████████████     200ms
│ payment-service  │ POST api.stripe.com/v1/charges         │             ████████████████       180ms
```

Grafana permet de cliquer sur un span pour voir ses attributs, ses events, puis de naviguer vers les logs corrélés (même `trace_id` dans Loki) ou les métriques du service.

---
