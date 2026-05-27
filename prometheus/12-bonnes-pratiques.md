## 12. Bonnes pratiques et production

### 12.1 Labels : quoi mettre, quoi ne pas mettre

```
BON (labels a faible cardinalite) :
════════════════════════════════════
  environment : production, staging, development (3 valeurs)
  region      : eu-west-1, us-east-1, ap-south-1 (quelques valeurs)
  service     : api, worker, gateway (dizaines de valeurs)
  method      : GET, POST, PUT, DELETE (4-7 valeurs)
  status      : 200, 201, 400, 404, 500 (dizaines de valeurs)
  instance    : hostname:port (dizaines/centaines de valeurs)

MAUVAIS (labels a haute cardinalite) :
══════════════════════════════════════
  user_id     : des milliers/millions de valeurs
  request_id  : unique par requete
  email       : PII (donnees personnelles) + haute cardinalite
  ip_address  : haute cardinalite
  timestamp   : infinie cardinalite
  url_path    : si non normalise (/users/123 vs /users/456)
  trace_id    : unique par trace

REGLE : Si un label peut avoir plus de ~100 valeurs distinctes,
il ne devrait probablement pas etre un label Prometheus.
Utilise des logs ou des traces pour ces dimensions.
```

### 12.2 Haute disponibilite

```
Architecture HA simple (2 Prometheus identiques) :
══════════════════════════════════════════════════

  ┌──────────────┐              ┌──────────────┐
  │ Prometheus A │              │ Prometheus B │
  │              │              │              │
  │ Meme config  │              │ Meme config  │
  │ Scrape les   │              │ Scrape les   │
  │ memes targets│              │ memes targets│
  │              │              │              │
  │ external_    │              │ external_    │
  │ labels:      │              │ labels:      │
  │  replica: a  │              │  replica: b  │
  └──────┬───────┘              └──────┬───────┘
         │                             │
         │  remote write               │ remote write
         ▼                             ▼
  ┌─────────────────────────────────────────┐
  │              Mimir / Thanos             │
  │                                         │
  │  Deduplique les donnees                 │
  │  grace au label "replica"               │
  │  (ne garde qu'une copie)                │
  └─────────────────────────────────────────┘
         │
         ▼
  ┌──────────────┐
  │   Grafana    │
  │              │
  │ Interroge    │
  │ Mimir/Thanos │
  │ (vue unifiee)│
  └──────────────┘

  Avantages :
  - Si Prometheus A tombe, B continue de scraper
  - Pas de perte de donnees (sauf pendant le temps de scrape manque)
  - Configuration identique, simple a maintenir
  - Le backend long terme deduplique

  Pour Alertmanager, la HA est native :
  - Deployer 2+ instances Alertmanager en cluster
  - Elles se synchronisent automatiquement via gossip (mesh)
  - Les notifications ne sont envoyees qu'une fois
```

### 12.3 Federation

La federation permet a un Prometheus "global" de scraper des metriques selectionnees depuis des Prometheus "locaux".

```
Federation hierarchique :
═════════════════════════

  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
  │ Prometheus   │  │ Prometheus   │  │ Prometheus   │
  │ Cluster A    │  │ Cluster B    │  │ Cluster C    │
  │              │  │              │  │              │
  │ Toutes les   │  │ Toutes les   │  │ Toutes les   │
  │ metriques    │  │ metriques    │  │ metriques    │
  │ du cluster A │  │ du cluster B │  │ du cluster C │
  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
         │                 │                 │
         │  /federate      │  /federate      │  /federate
         │  (subset)       │  (subset)       │  (subset)
         ▼                 ▼                 ▼
  ┌──────────────────────────────────────────────────┐
  │            Prometheus GLOBAL                      │
  │                                                   │
  │  Scrape /federate sur chaque Prometheus local     │
  │  avec match[] pour selectionner les metriques     │
  │                                                   │
  │  Ne stocke que les metriques agregees             │
  │  (recording rules des Prometheus locaux)          │
  └──────────────────────────────────────────────────┘
```

```yaml
# prometheus-global.yml
scrape_configs:
  - job_name: "federation-cluster-a"
    honor_labels: true
    metrics_path: "/federate"
    params:
      # Selectionner les metriques a federer
      match[]:
        - '{job=~".+"}'                              # Tout (pas recommande)
        - 'job:http_requests_total:rate5m'            # Recording rules
        - 'instance:node_cpu_utilisation:rate5m'      # Recording rules
        - '{__name__=~"job:.*"}'                      # Toutes les recording rules
    static_configs:
      - targets:
          - "prometheus-cluster-a:9090"
        labels:
          cluster: "cluster-a"
```

**Note** : La federation a des limitations (pas de deduplication, pas de vue globale PromQL). Pour les architectures multi-cluster, Mimir ou Thanos sont de meilleures solutions.

### 12.4 Securite

```yaml
# Prometheus avec TLS et authentification basic
# web-config.yml (passe via --web.config.file)
tls_server_config:
  cert_file: /etc/prometheus/tls/server.crt
  key_file: /etc/prometheus/tls/server.key

# Authentification basic (bcrypt hash)
basic_auth_users:
  admin: "$2y$12$..."  # bcrypt hash du mot de passe
  grafana: "$2y$12$..."

# Generer le hash bcrypt
# htpasswd -nBC 12 "" | tr -d ':\n'
```

```bash
# Demarrer avec la config web
prometheus --config.file=prometheus.yml --web.config.file=web-config.yml

# Scraper une target securisee
# Dans prometheus.yml :
scrape_configs:
  - job_name: "secure-target"
    scheme: https
    tls_config:
      ca_file: /etc/prometheus/tls/ca.pem
    basic_auth:
      username: "prometheus"
      password_file: /etc/prometheus/secrets/password
```

### 12.5 Checklist production

```
Checklist avant de mettre Prometheus en production :
════════════════════════════════════════════════════

  STOCKAGE
  [ ] Retention configuree (--storage.tsdb.retention.time)
  [ ] Stockage persistant (volume, pas ephemere)
  [ ] Espace disque suffisant (calculer avec la formule)
  [ ] Remote write configure vers un backend long terme
  [ ] Monitoring de l'espace disque Prometheus lui-meme

  HAUTE DISPONIBILITE
  [ ] 2 instances Prometheus avec la meme config
  [ ] Alertmanager en cluster (2+ instances)
  [ ] Backend long terme avec deduplication (Mimir/Thanos)
  [ ] external_labels avec replica=a/b

  PERFORMANCE
  [ ] Cardinalite verifiee (< 500K series pour commencer)
  [ ] Recording rules pour les requetes complexes
  [ ] metric_relabel_configs pour drop les metriques inutiles
  [ ] Resources adequates (RAM, CPU)

  ALERTING
  [ ] Alertes testees avec promtool
  [ ] Alertes pour target down (up == 0)
  [ ] Alertes pour Prometheus lui-meme (TSDB, scrape errors)
  [ ] Inhibition rules configurees
  [ ] Silences documentes pour la maintenance

  SECURITE
  [ ] TLS active (web-config.yml)
  [ ] Authentification configuree
  [ ] RBAC si multi-tenant (via reverse proxy)
  [ ] Pas d'exposition directe sur Internet
  [ ] Secrets dans des fichiers (pas dans la config)

  OPERATIONNEL
  [ ] --web.enable-lifecycle pour le reload sans restart
  [ ] Dashboards Grafana pour Prometheus lui-meme
  [ ] Documentation des recording rules et alerting rules
  [ ] Procedure de backup (snapshots TSDB)
  [ ] Procedure de restauration testee
```

---
