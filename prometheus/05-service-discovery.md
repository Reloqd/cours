## 5. Service Discovery

Le service discovery (SD) permet a Prometheus de decouvrir dynamiquement les targets a scraper, au lieu de les lister manuellement.

### 5.1 static_configs

Le plus simple. Tu listes les targets manuellement.

```yaml
scrape_configs:
  - job_name: "node-exporter"
    static_configs:
      - targets:
          - "server1:9100"
          - "server2:9100"
          - "server3:9100"
        labels:
          datacenter: "dc1"
      - targets:
          - "server4:9100"
          - "server5:9100"
        labels:
          datacenter: "dc2"
```

Adapte pour : homelabs, petites infras, targets stables. Pas adapte pour des environnements dynamiques (Kubernetes, auto-scaling).

### 5.2 file_sd_configs

Prometheus lit un fichier JSON ou YAML qui contient la liste des targets. Le fichier peut etre genere par un outil externe (Ansible, Terraform, script custom). Prometheus detecte automatiquement les changements du fichier (inotify).

```yaml
# prometheus.yml
scrape_configs:
  - job_name: "dynamic-targets"
    file_sd_configs:
      - files:
          - "/etc/prometheus/targets/*.json"
        refresh_interval: 5m  # Relecture periodique (en plus de inotify)
```

```json
// /etc/prometheus/targets/servers.json
[
  {
    "targets": ["server1:9100", "server2:9100"],
    "labels": {
      "datacenter": "dc1",
      "environment": "production"
    }
  },
  {
    "targets": ["server3:9100"],
    "labels": {
      "datacenter": "dc2",
      "environment": "staging"
    }
  }
]
```

```
Flux file_sd_configs :
══════════════════════

  ┌───────────┐  genere    ┌─────────────────┐
  │ Ansible / │ ─────────▶ │ targets.json    │
  │ Terraform │            │                 │
  │ Script    │            │ [{"targets":..} │
  └───────────┘            └───────┬─────────┘
                                    │
                           inotify / poll
                                    │
                                    ▼
                           ┌──────────────┐
                           │  Prometheus  │
                           │              │
                           │  Lit le      │
                           │  fichier et  │
                           │  met a jour  │
                           │  les targets │
                           └──────────────┘
```

### 5.3 docker_sd_configs

Decouverte automatique des conteneurs Docker. Ideal pour ton homelab.

```yaml
scrape_configs:
  - job_name: "docker-containers"
    docker_sd_configs:
      - host: "unix:///var/run/docker.sock"
        refresh_interval: 15s
        # Filtrer uniquement les conteneurs avec un label specifique
        filters:
          - name: "label"
            values: ["prometheus.scrape=true"]

    # Relabeling pour extraire les informations utiles
    relabel_configs:
      # Garder uniquement les conteneurs avec le label prometheus.scrape=true
      - source_labels: [__meta_docker_container_label_prometheus_scrape]
        regex: "true"
        action: keep

      # Utiliser le label prometheus.port pour definir le port de scrape
      - source_labels: [__meta_docker_container_label_prometheus_port]
        regex: (.+)
        target_label: __address__
        replacement: "${1}"
        action: replace
      - source_labels:
          [__meta_docker_container_network_ip, __meta_docker_container_label_prometheus_port]
        regex: "(.*);(.*)"
        target_label: __address__
        replacement: "${1}:${2}"

      # Utiliser le nom du conteneur comme label "container"
      - source_labels: [__meta_docker_container_name]
        regex: "/?(.*)"
        target_label: container

      # Utiliser le label prometheus.job comme job_name
      - source_labels: [__meta_docker_container_label_prometheus_job]
        regex: (.+)
        target_label: job

      # Chemin des metriques custom
      - source_labels: [__meta_docker_container_label_prometheus_metrics_path]
        regex: (.+)
        target_label: __metrics_path__
```

Meta-labels Docker disponibles :

```
__meta_docker_container_id             : ID du conteneur
__meta_docker_container_name           : Nom du conteneur
__meta_docker_container_network_ip     : IP du conteneur dans le reseau
__meta_docker_container_label_<nom>    : Labels Docker du conteneur
__meta_docker_network_name             : Nom du reseau Docker
__meta_docker_port_private             : Port interne
__meta_docker_port_public              : Port expose
__meta_docker_port_public_ip           : IP publique du port
```

Exemple de conteneur avec les labels Docker :

```yaml
# docker-compose.yml
services:
  mon-api:
    image: mon-api:latest
    labels:
      prometheus.scrape: "true"
      prometheus.port: "8080"
      prometheus.job: "mon-api"
      prometheus.metrics_path: "/metrics"
```

### 5.4 kubernetes_sd_configs

Le service discovery Kubernetes est le plus utilise en production. Il peut decouvrir 5 types de ressources :

```
Types de decouverte Kubernetes :
════════════════════════════════

  ┌────────────┐   Decouvre les machines du cluster
  │   node     │   Meta: __meta_kubernetes_node_name, _label_*, _address_*
  └────────────┘

  ┌────────────┐   Decouvre chaque pod individuellement
  │   pod      │   Meta: __meta_kubernetes_pod_name, _namespace, _label_*,
  └────────────┘         _container_name, _container_port_*

  ┌────────────┐   Decouvre les Services Kubernetes
  │  service   │   Meta: __meta_kubernetes_service_name, _namespace, _label_*,
  └────────────┘         _port_name, _port_number

  ┌────────────┐   Decouvre les Endpoints (pods derriere un Service)
  │ endpoints  │   Meta: combine pod + service meta-labels
  └────────────┘

  ┌────────────┐   Decouvre les Ingress
  │  ingress   │   Meta: __meta_kubernetes_ingress_name, _namespace, _host, _path
  └────────────┘
```

Exemple complet pour scraper les pods avec une annotation specifique :

```yaml
scrape_configs:
  - job_name: "kubernetes-pods"
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      # Garder uniquement les pods annotes prometheus.io/scrape: "true"
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true

      # Utiliser l'annotation prometheus.io/path pour le chemin des metriques
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)

      # Utiliser l'annotation prometheus.io/port pour le port
      - source_labels:
          [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: "([^:]+)(?::\\d+)?;(\\d+)"
        replacement: "${1}:${2}"
        target_label: __address__

      # Ajouter le namespace comme label
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: namespace

      # Ajouter le nom du pod comme label
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: pod

      # Ajouter le nom du node comme label
      - source_labels: [__meta_kubernetes_pod_node_name]
        action: replace
        target_label: node
```

Exemple pour scraper les nodes (kubelet) :

```yaml
  - job_name: "kubernetes-nodes"
    kubernetes_sd_configs:
      - role: node
    scheme: https
    tls_config:
      ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      insecure_skip_verify: true
    bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
    relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      - target_label: __address__
        replacement: kubernetes.default.svc:443
      - source_labels: [__meta_kubernetes_node_name]
        regex: (.+)
        target_label: __metrics_path__
        replacement: /api/v1/nodes/${1}/proxy/metrics
```

### 5.5 Autres mecanismes de service discovery

```yaml
# consul_sd_configs : decouverte via Consul
scrape_configs:
  - job_name: "consul-services"
    consul_sd_configs:
      - server: "consul:8500"
        services: []  # Vide = tous les services
        tags: ["monitoring"]  # Filtrer par tag
    relabel_configs:
      - source_labels: [__meta_consul_service]
        target_label: job
      - source_labels: [__meta_consul_dc]
        target_label: datacenter

# dns_sd_configs : decouverte via DNS (SRV records)
  - job_name: "dns-discovery"
    dns_sd_configs:
      - names:
          - "_prometheus._tcp.example.com"
        type: SRV
        refresh_interval: 30s

# ec2_sd_configs : decouverte via AWS EC2
  - job_name: "ec2-instances"
    ec2_sd_configs:
      - region: "eu-west-1"
        port: 9100
        filters:
          - name: "tag:monitoring"
            values: ["enabled"]
    relabel_configs:
      - source_labels: [__meta_ec2_tag_Name]
        target_label: instance_name
      - source_labels: [__meta_ec2_instance_type]
        target_label: instance_type
```

### 5.6 relabel_configs en detail

Le relabeling est un mecanisme puissant qui transforme les labels avant (relabel_configs) ou apres (metric_relabel_configs) le scrape. Comprendre le relabeling est essentiel pour maitriser le service discovery.

```
Flux du relabeling :
════════════════════

  Service Discovery
        │
        │  Genere des meta-labels
        │  __meta_kubernetes_pod_name = "api-xyz"
        │  __meta_kubernetes_namespace = "production"
        │  __address__ = "10.0.0.5:8080"
        │  __metrics_path__ = "/metrics"
        │  __scheme__ = "http"
        │
        ▼
  ┌──────────────────┐
  │ relabel_configs  │   AVANT le scrape
  │                  │   Modifie les target labels
  │  Peut :          │   Peut garder/supprimer des targets
  │  - keep/drop     │
  │  - replace       │
  │  - labelmap      │
  │  - hashmod       │
  └────────┬─────────┘
           │
           │  Scrape HTTP GET /metrics
           ▼
  ┌──────────────────────┐
  │ metric_relabel_configs│  APRES le scrape
  │                       │  Modifie les labels des metriques
  │  Peut :               │  Peut supprimer des metriques
  │  - keep/drop          │
  │  - replace            │
  │  - labeldrop/keep     │
  └───────────────────────┘
           │
           ▼
        TSDB
```

Les actions disponibles :

```yaml
# ACTION: keep - Garder seulement les targets qui matchent
relabel_configs:
  - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
    regex: "true"
    action: keep
    # → Garde uniquement les pods annotes "prometheus.io/scrape=true"

# ACTION: drop - Supprimer les targets qui matchent
  - source_labels: [__meta_kubernetes_namespace]
    regex: "kube-system|kube-public"
    action: drop
    # → Supprime les targets dans les namespaces systeme

# ACTION: replace - Remplacer un label (action par defaut)
  - source_labels: [__meta_kubernetes_pod_name]
    target_label: pod
    action: replace
    # → Copie le meta-label dans le label "pod"

  # Avec regex et replacement
  - source_labels: [__address__]
    regex: "(.+):\\d+"
    target_label: __address__
    replacement: "${1}:9090"
    action: replace
    # → Change le port de toutes les targets en 9090

# ACTION: labelmap - Copier les meta-labels qui matchent
  - regex: __meta_kubernetes_pod_label_(.+)
    action: labelmap
    # → Tous les labels Kubernetes du pod deviennent des labels Prometheus
    # → __meta_kubernetes_pod_label_app → app
    # → __meta_kubernetes_pod_label_version → version

# ACTION: labeldrop - Supprimer les labels qui matchent
  - regex: "pod_template_hash|controller_revision_hash"
    action: labeldrop
    # → Supprime ces labels de toutes les metriques

# ACTION: labelkeep - Garder seulement les labels qui matchent
  - regex: "job|instance|namespace|pod|container"
    action: labelkeep
    # → Ne garde que ces labels

# ACTION: hashmod - Sharding (repartir les targets entre N Prometheus)
  - source_labels: [__address__]
    modulus: 3      # 3 instances Prometheus
    target_label: __tmp_hash
    action: hashmod
  - source_labels: [__tmp_hash]
    regex: "0"      # Cette instance prend le shard 0
    action: keep
```

```
Schema : relabeling pour le sharding
═════════════════════════════════════

  100 targets decouvertes par le service discovery
          │
          ▼
  ┌─────────────────────────────┐
  │  hashmod(address, 3)        │
  │                             │
  │  Target → hash % 3 = shard │
  └──────┬──────────┬──────────┤
         │          │          │
     shard 0    shard 1    shard 2
     ~33 targets ~33 targets ~34 targets
         │          │          │
         ▼          ▼          ▼
   Prometheus-0  Prometheus-1  Prometheus-2
```

---
