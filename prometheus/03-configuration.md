## 3. Configuration

### 3.1 Le fichier prometheus.yml

C'est le fichier de configuration principal de Prometheus. Voici sa structure complete avec explications :

```yaml
# ============================================================================
# PROMETHEUS.YML - Configuration complete commentee
# ============================================================================

# ----------------------------------------------------------------------------
# GLOBAL : parametres par defaut appliques a tous les scrape_configs
# ----------------------------------------------------------------------------
global:
  # Frequence a laquelle Prometheus scrape les targets
  # Peut etre surcharge par scrape_config
  scrape_interval: 15s

  # Frequence a laquelle Prometheus evalue les recording/alerting rules
  evaluation_interval: 15s

  # Timeout pour chaque scrape (doit etre < scrape_interval)
  scrape_timeout: 10s

  # Labels ajoutes a toutes les series et alertes generees par ce Prometheus
  # Utile pour identifier l'instance Prometheus en federation/remote write
  external_labels:
    cluster: "homelab"
    environment: "production"
    region: "eu-west-1"

# ----------------------------------------------------------------------------
# RULE FILES : fichiers contenant les recording et alerting rules
# ----------------------------------------------------------------------------
rule_files:
  - "rules/recording_rules.yml"
  - "rules/alerting_rules.yml"
  - "rules/*.yml"              # Glob pattern supporte

# ----------------------------------------------------------------------------
# ALERTING : configuration de la connexion vers Alertmanager
# ----------------------------------------------------------------------------
alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - "alertmanager:9093"
      # Timeout pour l'envoi d'alertes a Alertmanager
      timeout: 10s
      # Chemin de l'API (utile si Alertmanager est derriere un reverse proxy)
      path_prefix: /
      # TLS optionnel
      # tls_config:
      #   ca_file: /etc/prometheus/ca.pem

# ----------------------------------------------------------------------------
# SCRAPE CONFIGS : definition des targets a scraper
# ----------------------------------------------------------------------------
scrape_configs:
  # ------ Prometheus lui-meme (self-monitoring) ------
  - job_name: "prometheus"
    # Override du scrape_interval global pour ce job
    scrape_interval: 10s
    static_configs:
      - targets: ["localhost:9090"]
        labels:
          service: "prometheus"

  # ------ Node Exporter (metriques systeme) ------
  - job_name: "node-exporter"
    static_configs:
      - targets:
          - "node-exporter:9100"
        labels:
          environment: "homelab"
    # Metriques a filtrer (optionnel)
    metric_relabel_configs:
      - source_labels: [__name__]
        # Supprimer les metriques inutiles pour reduire la cardinalite
        regex: "node_cpu_guest_seconds_total|node_netstat_.*"
        action: drop

  # ------ Application custom ------
  - job_name: "mon-api"
    scrape_interval: 30s    # Override : scrape moins frequent
    scrape_timeout: 5s
    metrics_path: /metrics  # Chemin par defaut, peut etre change
    scheme: https           # https au lieu de http
    tls_config:
      insecure_skip_verify: true  # Dev only, pas en prod !
    static_configs:
      - targets: ["api:8080"]

  # ------ Targets avec authentification ------
  - job_name: "secured-app"
    bearer_token_file: /etc/prometheus/token
    # ou : basic_auth:
    #        username: "prometheus"
    #        password_file: /etc/prometheus/password
    static_configs:
      - targets: ["secured-app:443"]
    scheme: https
    tls_config:
      ca_file: /etc/prometheus/ca.pem

# ----------------------------------------------------------------------------
# REMOTE WRITE : envoyer les metriques vers un stockage long terme
# ----------------------------------------------------------------------------
remote_write:
  - url: "http://mimir:9009/api/v1/push"
    # Files d'attente pour le remote write
    queue_config:
      capacity: 10000
      max_shards: 30
      max_samples_per_send: 5000
      batch_send_deadline: 5s
      min_backoff: 30ms
      max_backoff: 5s
    # Filtrer ce qui est envoye en remote write
    write_relabel_configs:
      - source_labels: [__name__]
        regex: "go_.*"
        action: drop  # Ne pas envoyer les metriques Go internes

# ----------------------------------------------------------------------------
# REMOTE READ : lire les metriques depuis un stockage externe
# ----------------------------------------------------------------------------
remote_read:
  - url: "http://mimir:9009/prometheus/api/v1/read"
    read_recent: false  # Ne pas lire les donnees recentes (deja dans la TSDB locale)

# ----------------------------------------------------------------------------
# STORAGE : configuration du stockage local
# ----------------------------------------------------------------------------
# Note : ces parametres sont des flags CLI, pas dans le YAML
# --storage.tsdb.path=/prometheus
# --storage.tsdb.retention.time=15d
# --storage.tsdb.retention.size=50GB
# --storage.tsdb.min-block-duration=2h
# --storage.tsdb.max-block-duration=36h

# ----------------------------------------------------------------------------
# OTLP : reception de metriques OTel (Prometheus v3+)
# ----------------------------------------------------------------------------
otlp:
  # Active la reception de metriques via OTLP
  # Endpoints : /api/v1/otlp/v1/metrics (HTTP)
  promote_resource_attributes:
    - "service.name"
    - "service.namespace"
    - "service.instance.id"
```

### 3.2 Exemple complet pour un homelab Docker

Voici un exemple realiste pour ton homelab avec Docker Compose :

```yaml
# docker-compose.yml
services:
  prometheus:
    image: prom/prometheus:v3.4.1
    container_name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/rules/:/etc/prometheus/rules/:ro
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
      - '--storage.tsdb.retention.size=10GB'
      - '--web.enable-lifecycle'          # Permet le reload via API
      - '--web.enable-remote-write-receiver'  # Permet le remote write entrant
      - '--enable-feature=native-histograms'  # Active les native histograms
      - '--enable-feature=otlp-write-receiver' # Active la reception OTLP
    restart: unless-stopped
    networks:
      - monitoring

  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    ports:
      - "9100:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--path.rootfs=/rootfs'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
    restart: unless-stopped
    networks:
      - monitoring

  alertmanager:
    image: prom/alertmanager:latest
    container_name: alertmanager
    ports:
      - "9093:9093"
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
    restart: unless-stopped
    networks:
      - monitoring

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    volumes:
      - grafana_data:/var/lib/grafana
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    restart: unless-stopped
    networks:
      - monitoring

volumes:
  prometheus_data:
  grafana_data:

networks:
  monitoring:
    driver: bridge
```

```yaml
# prometheus/prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: "homelab"

rule_files:
  - "rules/*.yml"

alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "node-exporter"
    static_configs:
      - targets: ["node-exporter:9100"]

  - job_name: "alertmanager"
    static_configs:
      - targets: ["alertmanager:9093"]

  - job_name: "grafana"
    static_configs:
      - targets: ["grafana:3000"]
```

### 3.3 Verifier la configuration

```bash
# Valider la syntaxe du fichier prometheus.yml
promtool check config prometheus.yml

# Valider les fichiers de rules
promtool check rules rules/*.yml

# Recharger la configuration sans redemarrer (si --web.enable-lifecycle)
curl -X POST http://localhost:9090/-/reload

# Ou envoyer un SIGHUP
kill -HUP $(pidof prometheus)

# Verifier les targets dans l'API
curl http://localhost:9090/api/v1/targets | jq .

# Verifier les rules chargees
curl http://localhost:9090/api/v1/rules | jq .
```

---
