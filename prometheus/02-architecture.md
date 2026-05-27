## 2. Architecture de Prometheus

### 2.1 Les composants internes

Prometheus est un binaire unique qui integre plusieurs composants :

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    PROMETHEUS SERVER - COMPOSANTS INTERNES              │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────┐      │
│  │                        RETRIEVAL                             │      │
│  │                                                              │      │
│  │  ┌──────────────┐     ┌──────────────────┐                  │      │
│  │  │  Service     │────▶│  Target Manager  │                  │      │
│  │  │  Discovery   │     │                  │                  │      │
│  │  │              │     │  Gere la liste   │                  │      │
│  │  │  - static    │     │  des targets a   │                  │      │
│  │  │  - k8s       │     │  scraper         │                  │      │
│  │  │  - docker    │     └────────┬─────────┘                  │      │
│  │  │  - consul    │              │                             │      │
│  │  │  - file      │              ▼                             │      │
│  │  │  - dns       │     ┌──────────────────┐                  │      │
│  │  └──────────────┘     │  Scrape Manager  │                  │      │
│  │                        │                  │                  │      │
│  │                        │  Scrape chaque   │                  │      │
│  │                        │  target selon    │                  │      │
│  │                        │  scrape_interval │                  │      │
│  │                        └────────┬─────────┘                  │      │
│  └─────────────────────────────────┼────────────────────────────┘      │
│                                    │                                    │
│                                    │ Samples (timestamp, value, labels) │
│                                    ▼                                    │
│  ┌──────────────────────────────────────────────────────────────┐      │
│  │                         TSDB                                 │      │
│  │                                                              │      │
│  │  ┌───────────┐    ┌───────────┐    ┌───────────────┐        │      │
│  │  │    WAL    │    │   Head    │    │  Persistent   │        │      │
│  │  │           │    │   Block   │    │  Blocks       │        │      │
│  │  │  Write    │───▶│           │───▶│               │        │      │
│  │  │  Ahead    │    │  En memoire│    │  Sur disque   │        │      │
│  │  │  Log      │    │  ~2h de   │    │  Compactes    │        │      │
│  │  │           │    │  donnees  │    │  Immutables   │        │      │
│  │  └───────────┘    └───────────┘    └───────────────┘        │      │
│  └──────────────────────────────────────────────────────────────┘      │
│                                    │                                    │
│                                    │ Query                              │
│                                    ▼                                    │
│  ┌──────────────────────────────────────────────────────────────┐      │
│  │                      RULE ENGINE                             │      │
│  │                                                              │      │
│  │  ┌──────────────────┐    ┌──────────────────┐               │      │
│  │  │  Recording Rules │    │  Alerting Rules  │               │      │
│  │  │                  │    │                  │               │      │
│  │  │  Pre-calcule des │    │  Evalue des      │               │      │
│  │  │  requetes PromQL │    │  conditions et   │               │      │
│  │  │  a intervalles   │    │  envoie a        │               │      │
│  │  │  reguliers       │    │  Alertmanager    │               │      │
│  │  └──────────────────┘    └────────┬─────────┘               │      │
│  └──────────────────────────────────┼──────────────────────────┘      │
│                                      │                                 │
│  ┌──────────────────────┐           │                                 │
│  │      HTTP API        │           ▼                                 │
│  │                      │    ┌──────────────┐                         │
│  │  /api/v1/query       │    │ Alertmanager │                         │
│  │  /api/v1/query_range │    │ (externe)    │                         │
│  │  /api/v1/labels      │    └──────────────┘                         │
│  │  /api/v1/series      │                                             │
│  │  /api/v1/targets     │                                             │
│  │  /api/v1/rules       │                                             │
│  │  /metrics            │                                             │
│  └──────────────────────┘                                             │
└─────────────────────────────────────────────────────────────────────────┘
```

**Retrieval (Scrape Manager + Service Discovery)**

Le composant de retrieval est responsable de la collecte des metriques. Il fonctionne en deux etapes :

1. Le **Service Discovery** decouvre dynamiquement les targets (pods Kubernetes, conteneurs Docker, instances EC2, etc.) ou utilise une liste statique.
2. Le **Scrape Manager** envoie des requetes HTTP GET vers l'endpoint `/metrics` de chaque target, a intervalles reguliers (`scrape_interval`).

Chaque scrape produit un ensemble de **samples** : des tuples (metrique + labels, timestamp, valeur). Ces samples sont ecrits dans la TSDB.

**TSDB (Time Series Database)**

La TSDB est le moteur de stockage de Prometheus. Elle est optimisee pour les series temporelles et gere trois couches :

1. **WAL (Write-Ahead Log)** : Journal d'ecriture anticipee. Chaque sample ecrit est d'abord persiste dans le WAL pour garantir la durabilite en cas de crash. Le WAL est rejoue au demarrage.

2. **Head Block** : Bloc en memoire contenant les 2 dernieres heures de donnees (par defaut). C'est ici que les nouvelles donnees sont ecrites et que les requetes recentes sont les plus rapides.

3. **Persistent Blocks** : Quand le head block est plein (~2h), il est "coupe" (cut) et ecrit sur disque comme un bloc immutable. Ces blocs sont ensuite compactes par le compacteur de la TSDB.

**Rule Engine**

Le moteur de regles evalue periodiquement (selon `evaluation_interval`) deux types de regles :
- **Recording rules** : Pre-calculent des requetes PromQL couteuses et stockent le resultat comme nouvelles series temporelles
- **Alerting rules** : Evaluent des conditions et, si elles sont vraies pendant la duree specifiee (`for`), envoient des alertes a Alertmanager

**HTTP API**

L'API REST de Prometheus est utilisee par :
- Grafana pour executer des requetes PromQL
- Les outils CLI (curl, promtool)
- Toute application qui a besoin d'interroger Prometheus

### 2.2 Le modele de donnees

Prometheus stocke des **series temporelles** (time series). Chaque serie est identifiee de maniere unique par :
- Un **nom de metrique** (`http_requests_total`)
- Un ensemble de **labels** (paires cle-valeur) (`method="GET"`, `status="200"`)

```
Anatomie d'une serie temporelle :
══════════════════════════════════

  Nom de la metrique          Labels (dimensions)
  ──────────────────          ────────────────────
  http_requests_total{method="GET", handler="/api/users", status="200"}

  Cette combinaison unique (nom + labels) identifie UNE serie temporelle.

  Dans cette serie, chaque point est un SAMPLE :

  Timestamp (ms)        Valeur
  ──────────────        ──────
  1716580800000         1523
  1716580815000         1524
  1716580830000         1527
  1716580845000         1531
  ...

  Representation graphique :

  Valeur
  1531 │                                         *
  1527 │                              *
  1524 │                   *
  1523 │        *
       └──────────────────────────────────────────▶ Temps
            t0       t0+15s    t0+30s    t0+45s

  Chaque combinaison de labels cree une NOUVELLE serie :

  http_requests_total{method="GET",  status="200"}  ← serie 1
  http_requests_total{method="GET",  status="404"}  ← serie 2
  http_requests_total{method="POST", status="200"}  ← serie 3
  http_requests_total{method="POST", status="500"}  ← serie 4

  4 combinaisons = 4 series temporelles distinctes
```

**Regles de nommage** :
- Le nom de la metrique matche `[a-zA-Z_:][a-zA-Z0-9_:]*`
- Les noms de labels matchent `[a-zA-Z_][a-zA-Z0-9_]*`
- Les labels commencant par `__` sont reserves a l'usage interne de Prometheus
- Le label `job` et `instance` sont ajoutes automatiquement par Prometheus lors du scrape

**La cardinalite** (concept critique) :

La cardinalite d'une metrique est le nombre total de series temporelles qu'elle genere. C'est le produit des valeurs possibles de chaque label.

```
Exemple de cardinalite :

http_requests_total avec :
  method:  GET, POST, PUT, DELETE           = 4 valeurs
  handler: /api/users, /api/orders, /health = 3 valeurs
  status:  200, 201, 400, 404, 500          = 5 valeurs

Cardinalite = 4 x 3 x 5 = 60 series temporelles

C'est raisonnable. Mais attention :

http_requests_total avec :
  method:  4 valeurs
  handler: 3 valeurs
  status:  5 valeurs
  user_id: 100 000 valeurs              ← DANGER !

Cardinalite = 4 x 3 x 5 x 100 000 = 6 000 000 series

C'est de la HIGH CARDINALITY. Prometheus va souffrir.
```

### 2.3 Les 4 types de metriques

Prometheus definit 4 types de metriques fondamentaux. Chacun a un usage specifique.

#### Counter (compteur)

Un counter est une valeur qui ne fait **que monter** (ou etre remise a zero au redemarrage du processus). C'est le type le plus courant.

```
Counter : valeur monotone croissante
═════════════════════════════════════

  Valeur
  150 │                                              *
  120 │                                    *
  100 │                          *
   80 │                 *
   50 │        *
   20 │  *
      └──────────────────────────────────────────────▶ Temps

  La valeur ne descend JAMAIS (sauf reset au redemarrage).

  Exemples concrets :
  - http_requests_total        (nombre total de requetes)
  - node_network_receive_bytes_total  (octets recus au total)
  - process_cpu_seconds_total  (temps CPU consomme au total)

  ATTENTION : La valeur brute d'un counter est rarement utile.
  Ce qui t'interesse, c'est le TAUX DE VARIATION :

  rate(http_requests_total[5m])
  → "combien de requetes par seconde en moyenne sur 5 min"

  Counter avec un RESET (redemarrage du processus) :

  Valeur
  150 │                    *
  120 │              *
  100 │        *                          *
   80 │  *                          *
   50 │                       *
   20 │                  *
      └──────────────────────────────────────────────▶ Temps
                       ↑
                    Reset (redemarrage)
                    rate() gere ca automatiquement
```

**Convention de nommage** : les counters finissent toujours par `_total`.

#### Gauge (jauge)

Un gauge est une valeur qui peut **monter et descendre**. Il represente un etat instantane.

```
Gauge : valeur qui fluctue
══════════════════════════

  Valeur
   85 │              *
   78 │        *           *
   65 │                          *
   52 │  *                             *
   45 │                                      *
   38 │                                            *
      └──────────────────────────────────────────────▶ Temps

  Exemples concrets :
  - node_memory_MemAvailable_bytes  (memoire disponible)
  - node_filesystem_avail_bytes     (espace disque disponible)
  - go_goroutines                   (nombre de goroutines)
  - kube_deployment_spec_replicas   (nombre de replicas desires)
  - temperature_celsius             (temperature d'un capteur)

  Contrairement au counter, la valeur brute EST directement utile :
  node_memory_MemAvailable_bytes → "combien de RAM disponible ?"
```

#### Histogram (histogramme)

Un histogram echantillonne des observations (generalement des durees ou des tailles) et les compte dans des buckets configurables. Il expose plusieurs series :

```
Histogram : distribution des observations
══════════════════════════════════════════

  Imaginons un histogram pour la duree des requetes HTTP :

  http_request_duration_seconds_bucket{le="0.005"}  12400
  http_request_duration_seconds_bucket{le="0.01"}   13200
  http_request_duration_seconds_bucket{le="0.025"}  14800
  http_request_duration_seconds_bucket{le="0.05"}   15200
  http_request_duration_seconds_bucket{le="0.1"}    15800
  http_request_duration_seconds_bucket{le="0.25"}   16200
  http_request_duration_seconds_bucket{le="0.5"}    16400
  http_request_duration_seconds_bucket{le="1"}      16500
  http_request_duration_seconds_bucket{le="2.5"}    16520
  http_request_duration_seconds_bucket{le="5"}      16525
  http_request_duration_seconds_bucket{le="10"}     16525
  http_request_duration_seconds_bucket{le="+Inf"}   16525
  http_request_duration_seconds_sum                  1234.56
  http_request_duration_seconds_count                16525

  Chaque bucket contient le nombre d'observations <= a sa borne (le = "less or equal").
  Les buckets sont CUMULATIFS.

  Representation visuelle de la distribution :

  Nombre d'observations dans chaque tranche :
  ─────────────────────────────────────────────

  0-5ms     │████████████████████████  12400
  5-10ms    │████                       800
  10-25ms   │████████                  1600
  25-50ms   │██                         400
  50-100ms  │████                       600
  100-250ms │██                         400
  250-500ms │█                          200
  500ms-1s  │                           100
  1-2.5s    │                            20
  2.5-5s    │                             5
  5-10s     │                             0
  >10s      │                             0
            └────────────────────────────────

  Le histogram expose TROIS types de series :
  1. _bucket{le="..."}  : les buckets cumulatifs
  2. _sum               : la somme de toutes les observations
  3. _count             : le nombre total d'observations

  Avec ces donnees, tu peux calculer :
  - La latence p50 (mediane) : histogram_quantile(0.5, rate(...[5m]))
  - La latence p95 : histogram_quantile(0.95, rate(...[5m]))
  - La latence p99 : histogram_quantile(0.99, rate(...[5m]))
  - La latence moyenne : rate(_sum[5m]) / rate(_count[5m])
```

**Native Histograms** (Prometheus v3.x) :

Prometheus v3 introduit les **native histograms** (aussi appeles sparse histograms). Au lieu de buckets pre-definis, les buckets sont generes dynamiquement avec une resolution exponentielle. Avantages : meilleure precision, moins de series temporelles, moins de cardinalite.

```
Classic histogram :  12 series (1 par bucket) + _sum + _count = 14 series
Native histogram :   1 seule serie contenant tous les buckets

Tu gagnes un facteur ~14x en cardinalite !
```

#### Summary (resume)

Un summary est similaire a un histogram mais calcule les quantiles **cote client** (dans l'application) plutot que cote serveur.

```
Summary : quantiles pre-calcules
═════════════════════════════════

  http_request_duration_seconds{quantile="0.5"}   0.042
  http_request_duration_seconds{quantile="0.9"}   0.087
  http_request_duration_seconds{quantile="0.99"}  0.245
  http_request_duration_seconds_sum               1234.56
  http_request_duration_seconds_count             16525

  Differences avec l'histogram :
  ┌──────────────────────┬──────────────────────┐
  │     HISTOGRAM        │     SUMMARY          │
  ├──────────────────────┼──────────────────────┤
  │ Quantiles calcules   │ Quantiles calcules   │
  │ cote SERVEUR         │ cote CLIENT          │
  │ (dans PromQL)        │ (dans l'app)         │
  ├──────────────────────┼──────────────────────┤
  │ Agregeables entre    │ NON agregeables      │
  │ instances            │ entre instances       │
  ├──────────────────────┼──────────────────────┤
  │ Precision depend     │ Precision configurable│
  │ des bornes de bucket │ mais couteuse en CPU │
  ├──────────────────────┼──────────────────────┤
  │ Peut choisir le      │ Les quantiles sont   │
  │ quantile a posteriori│ fixes a l'avance     │
  └──────────────────────┴──────────────────────┘
```

**Recommandation** : Utilise des histograms dans 99% des cas. Les summaries ont un cas d'usage de niche (quand tu as besoin d'un quantile exact sur une seule instance). Le probleme majeur des summaries : tu ne peux pas agreger le p99 de 10 instances pour obtenir le p99 global. Avec les histograms, si.

### 2.4 Ingestion, samples, chunks et blocks

```
Flux de donnees dans la TSDB :
══════════════════════════════

  1. SCRAPE : Prometheus scrape une target
     │
     │  http_requests_total{method="GET"} 1523 @1716580800
     │  http_requests_total{method="POST"} 421 @1716580800
     │
     ▼
  2. WRITE-AHEAD LOG (WAL) : Les samples sont ecrits dans le WAL
     │  (fichier sequentiel sur disque pour la durabilite)
     │
     │  data/wal/
     │  ├── 00000001
     │  ├── 00000002
     │  └── 00000003   ← segment courant
     │
     ▼
  3. HEAD BLOCK : Les samples sont indexes en memoire
     │
     │  En memoire :
     │  ┌─────────────────────────────────────────────────┐
     │  │ serie_id=1 : http_requests_total{method="GET"}  │
     │  │   chunk: [1523@t0, 1524@t1, 1527@t2, ...]      │
     │  │                                                  │
     │  │ serie_id=2 : http_requests_total{method="POST"} │
     │  │   chunk: [421@t0, 422@t1, 425@t2, ...]          │
     │  └─────────────────────────────────────────────────┘
     │
     │  Les donnees sont compressees en "chunks" (XOR encoding
     │  pour les valeurs, delta-of-delta pour les timestamps).
     │  Un chunk couvre ~120 samples (~2h a 15s d'intervalle).
     │
     ▼
  4. PERSISTENT BLOCK : Toutes les ~2h, le head block est "cut"
     │
     │  data/
     │  ├── wal/
     │  ├── 01HQRS.../ ← block 1 (2h de donnees)
     │  │   ├── meta.json
     │  │   ├── index
     │  │   ├── chunks/
     │  │   │   └── 000001
     │  │   └── tombstones
     │  ├── 01HQRT.../ ← block 2 (2h de donnees)
     │  └── 01HQRU.../ ← block 3 (apres compaction, peut couvrir plus)
     │
     ▼
  5. COMPACTION : Prometheus fusionne les petits blocks en plus gros
     │
     │  Avant compaction :
     │  [block 2h][block 2h][block 2h][block 2h]
     │
     │  Apres compaction :
     │  [      block 8h      ][      block 8h      ]
     │
     │  Puis :
     │  [              block 16h                    ]
     │
     │  Avantages :
     │  - Moins de fichiers a gerer
     │  - Meilleures performances de lecture
     │  - Les series supprimees (tombstones) sont nettoyees
     │
     ▼
  6. RETENTION : Les blocks trop anciens sont supprimes
     --storage.tsdb.retention.time=15d  (defaut)
     --storage.tsdb.retention.size=50GB (optionnel)
```

**Metriques d'ingestion** :

```
# Nombre de samples ingeres par seconde (ingestion rate)
rate(prometheus_tsdb_head_samples_appended_total[5m])

# Nombre de series actives dans le head block
prometheus_tsdb_head_series

# Nombre de chunks en memoire
prometheus_tsdb_head_chunks

# Taille du WAL
prometheus_tsdb_wal_storage_size_bytes
```

---
