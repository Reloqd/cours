## 11. Exporters

### 11.1 Concept d'exporter

Un exporter est un processus qui collecte des metriques aupres d'un systeme tiers et les expose au format Prometheus (`/metrics`). Les exporters sont le pont entre les systemes qui ne parlent pas nativement Prometheus et l'ecosysteme Prometheus.

```
Fonctionnement d'un exporter :
══════════════════════════════

  ┌──────────┐                 ┌──────────────┐               ┌──────────────┐
  │ Systeme  │  Protocole      │  Exporter    │  HTTP GET     │  Prometheus  │
  │ source   │  natif          │              │  /metrics     │              │
  │          │────────────────▶│  Traduit en  │◀──────────────│  Scrape      │
  │ MySQL    │  SQL queries    │  format      │               │              │
  │ Redis    │  INFO command   │  Prometheus  │──────────────▶│  Stocke      │
  │ Linux    │  /proc, /sys    │              │  Reponse text │              │
  └──────────┘                 └──────────────┘               └──────────────┘
```

### 11.2 node-exporter

Le node-exporter expose les metriques systeme (CPU, memoire, disque, reseau) d'une machine Linux.

```
Metriques principales du node-exporter :
═════════════════════════════════════════

  CPU :
  - node_cpu_seconds_total{cpu="0", mode="idle|user|system|iowait|..."}
  - node_load1, node_load5, node_load15

  Memoire :
  - node_memory_MemTotal_bytes
  - node_memory_MemFree_bytes
  - node_memory_MemAvailable_bytes
  - node_memory_Buffers_bytes
  - node_memory_Cached_bytes
  - node_memory_SwapTotal_bytes
  - node_memory_SwapFree_bytes

  Disque :
  - node_filesystem_size_bytes{mountpoint="/", fstype="ext4"}
  - node_filesystem_avail_bytes{mountpoint="/", fstype="ext4"}
  - node_filesystem_free_bytes{mountpoint="/", fstype="ext4"}
  - node_disk_read_bytes_total{device="sda"}
  - node_disk_written_bytes_total{device="sda"}
  - node_disk_io_time_seconds_total{device="sda"}

  Reseau :
  - node_network_receive_bytes_total{device="eth0"}
  - node_network_transmit_bytes_total{device="eth0"}
  - node_network_receive_errs_total{device="eth0"}
  - node_network_transmit_errs_total{device="eth0"}

  Systeme :
  - node_boot_time_seconds
  - node_time_seconds
  - node_uname_info{...}  (version du noyau, hostname, etc.)

  Requetes utiles :
  ─────────────────
  # CPU usage (%)
  100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

  # RAM utilisee (%)
  (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

  # Disque utilise (%)
  (1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100

  # IO wait (%)
  avg by (instance) (rate(node_cpu_seconds_total{mode="iowait"}[5m])) * 100

  # Uptime
  time() - node_boot_time_seconds
```

### 11.3 blackbox-exporter

Le blackbox-exporter permet de prober des endpoints HTTP, TCP, ICMP et DNS depuis l'exterieur.

```yaml
# blackbox-exporter config
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: [200]
      method: GET
      follow_redirects: true
      preferred_ip_protocol: "ip4"

  http_post_2xx:
    prober: http
    timeout: 5s
    http:
      method: POST
      body: '{}'
      headers:
        Content-Type: application/json

  tcp_connect:
    prober: tcp
    timeout: 5s

  icmp:
    prober: icmp
    timeout: 5s

  dns_resolution:
    prober: dns
    timeout: 5s
    dns:
      query_name: "example.com"
      query_type: "A"
```

```yaml
# prometheus.yml - scrape config pour le blackbox-exporter
scrape_configs:
  - job_name: "blackbox-http"
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
          - "https://example.com"
          - "https://api.example.com/health"
          - "https://grafana.example.com"
        labels:
          probe_type: "http"
    relabel_configs:
      # L'URL a prober est passee comme parametre "target"
      - source_labels: [__address__]
        target_label: __param_target
      # Le label "instance" contient l'URL probee
      - source_labels: [__param_target]
        target_label: instance
      # L'adresse reelle du blackbox-exporter
      - target_label: __address__
        replacement: "blackbox-exporter:9115"

  - job_name: "blackbox-icmp"
    metrics_path: /probe
    params:
      module: [icmp]
    static_configs:
      - targets:
          - "8.8.8.8"
          - "1.1.1.1"
          - "192.168.1.1"
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: "blackbox-exporter:9115"
```

```
Metriques du blackbox-exporter :
════════════════════════════════

  probe_success                  : 1 si le probe a reussi, 0 sinon
  probe_duration_seconds         : duree totale du probe
  probe_http_status_code         : code HTTP retourne
  probe_http_duration_seconds    : duree par phase (dns, connect, tls, transfer)
  probe_ssl_earliest_cert_expiry : timestamp d'expiration du certificat SSL
  probe_dns_lookup_time_seconds  : duree de resolution DNS
  probe_ip_protocol              : protocole IP utilise (4 ou 6)

  Alertes utiles :
  ────────────────
  # Endpoint down
  probe_success{job="blackbox-http"} == 0

  # Certificat SSL expire dans moins de 30 jours
  (probe_ssl_earliest_cert_expiry - time()) / 86400 < 30

  # Latence HTTP > 2 secondes
  probe_http_duration_seconds{phase="transfer"} > 2
```

### 11.4 Autres exporters populaires

```
Exporter              Port    Metriques
─────────────────────────────────────────────────────────────
mysqld-exporter       9104    mysql_global_status_*, mysql_slave_*
postgres-exporter     9187    pg_stat_activity, pg_stat_database
redis-exporter        9121    redis_connected_clients, redis_memory_*
mongodb-exporter      9216    mongodb_connections, mongodb_op_counters
nginx-exporter        9113    nginx_connections_*, nginx_http_requests_total
haproxy-exporter      9101    haproxy_frontend_*, haproxy_backend_*
cadvisor              8080    container_cpu_*, container_memory_*
snmp-exporter         9116    Metriques SNMP (reseau, imprimantes...)
elasticsearch-exporter 9114   elasticsearch_cluster_health_*
rabbitmq-exporter     9419    rabbitmq_queue_messages, rabbitmq_connections
```

### 11.5 Ecrire un exporter custom

#### En Python (avec prometheus_client)

```python
# exporter_custom.py
from prometheus_client import start_http_server, Gauge, Counter, Histogram, Info
import time
import random

# ---- Definir les metriques ----

# Gauge : valeur qui monte et descend
temperature = Gauge(
    'room_temperature_celsius',
    'Temperature ambiante en degres Celsius',
    ['room', 'sensor']
)

# Counter : valeur qui ne fait que monter
requests_total = Counter(
    'myapp_requests_total',
    'Nombre total de requetes traitees',
    ['method', 'endpoint', 'status']
)

# Histogram : distribution des valeurs
request_duration = Histogram(
    'myapp_request_duration_seconds',
    'Duree des requetes en secondes',
    ['endpoint'],
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]
)

# Info : metadata (labels statiques)
build_info = Info(
    'myapp_build',
    'Information de build de l application'
)

# ---- Mettre a jour les metriques ----

def collect_metrics():
    """Simule la collecte de metriques."""
    # Gauge : mettre a jour la valeur
    temperature.labels(room='serveur', sensor='capteur-1').set(22.5 + random.uniform(-2, 2))
    temperature.labels(room='bureau', sensor='capteur-2').set(24.0 + random.uniform(-1, 1))

    # Counter : incrementer
    requests_total.labels(method='GET', endpoint='/api/users', status='200').inc()

    # Histogram : observer une valeur
    duration = random.uniform(0.001, 0.5)
    request_duration.labels(endpoint='/api/users').observe(duration)

if __name__ == '__main__':
    # Info de build (defini une seule fois)
    build_info.info({
        'version': '1.2.0',
        'commit': 'abc123',
        'branch': 'main'
    })

    # Demarrer le serveur HTTP sur le port 8000
    start_http_server(8000)
    print("Exporter demarre sur :8000/metrics")

    # Boucle de collecte
    while True:
        collect_metrics()
        time.sleep(5)
```

```bash
# Installation
pip install prometheus_client

# Lancement
python exporter_custom.py

# Test
curl http://localhost:8000/metrics
```

#### En Go (avec prometheus/client_golang)

```go
// main.go
package main

import (
    "math/rand"
    "net/http"
    "time"

    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
    requestsTotal = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "myapp_requests_total",
            Help: "Nombre total de requetes traitees",
        },
        []string{"method", "endpoint", "status"},
    )

    requestDuration = prometheus.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "myapp_request_duration_seconds",
            Help:    "Duree des requetes en secondes",
            Buckets: prometheus.DefBuckets,
        },
        []string{"endpoint"},
    )

    temperature = prometheus.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "room_temperature_celsius",
            Help: "Temperature ambiante",
        },
        []string{"room"},
    )
)

func init() {
    prometheus.MustRegister(requestsTotal)
    prometheus.MustRegister(requestDuration)
    prometheus.MustRegister(temperature)
}

func main() {
    // Simuler des metriques
    go func() {
        for {
            requestsTotal.WithLabelValues("GET", "/api/users", "200").Inc()
            requestDuration.WithLabelValues("/api/users").Observe(rand.Float64() * 0.5)
            temperature.WithLabelValues("serveur").Set(22.0 + rand.Float64()*4)
            time.Sleep(5 * time.Second)
        }
    }()

    http.Handle("/metrics", promhttp.Handler())
    http.ListenAndServe(":8080", nil)
}
```

### 11.6 Conventions de nommage des metriques

```
Regles de nommage :
═══════════════════

  1. Prefixe avec le nom du composant/exporter
     GOOD: node_cpu_seconds_total
     GOOD: http_requests_total
     BAD:  cpu_total
     BAD:  requests

  2. Suffixe avec l'unite (au singulier, en base unit)
     _seconds    (pas _milliseconds)
     _bytes      (pas _kilobytes)
     _meters     (pas _kilometers)
     _celsius
     _ratio      (pour les pourcentages 0-1)

  3. Suffixe _total pour les counters
     GOOD: http_requests_total
     BAD:  http_requests_count (sauf pour les histograms/summaries)

  4. Suffixe _info pour les metriques d'information (gauge = 1)
     GOOD: node_uname_info{release="6.1.0", machine="x86_64"} 1

  5. Utiliser des snake_case
     GOOD: http_request_duration_seconds
     BAD:  httpRequestDurationSeconds
     BAD:  http-request-duration-seconds

  6. Eviter le prefixe du type de metrique
     BAD:  gauge_temperature_celsius
     GOOD: temperature_celsius

  Exemples conformes :
  ────────────────────
  process_cpu_seconds_total          (counter, en secondes)
  process_resident_memory_bytes      (gauge, en octets)
  http_request_duration_seconds      (histogram, en secondes)
  node_filesystem_avail_bytes        (gauge, en octets)
  net_conntrack_dialer_conn_attempted_total (counter)
```

---
