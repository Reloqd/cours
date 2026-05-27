## 10. Prometheus en Kubernetes

### 10.1 kube-prometheus-stack

Le chart Helm `kube-prometheus-stack` (anciennement `prometheus-operator`) est la maniere standard de deployer Prometheus sur Kubernetes. Il installe :

```
Composants de kube-prometheus-stack :
═════════════════════════════════════

  ┌────────────────────────────────────────────────────────────────────────┐
  │                         CLUSTER KUBERNETES                             │
  │                                                                        │
  │  ┌─────────────────────────────────────────────────────────────────┐  │
  │  │                 kube-prometheus-stack                            │  │
  │  │                                                                  │  │
  │  │  ┌────────────────┐  ┌────────────────┐  ┌──────────────────┐  │  │
  │  │  │  Prometheus    │  │  Alertmanager  │  │  Grafana         │  │  │
  │  │  │  Operator      │  │                │  │                  │  │  │
  │  │  │                │  │  Routing &     │  │  Dashboards      │  │  │
  │  │  │  Gere les CRDs │  │  notification  │  │  pre-configures  │  │  │
  │  │  │  et reconcilie │  │  des alertes   │  │  pour K8s        │  │  │
  │  │  └────────┬───────┘  └────────────────┘  └──────────────────┘  │  │
  │  │           │                                                      │  │
  │  │           │ Cree/manage                                          │  │
  │  │           ▼                                                      │  │
  │  │  ┌────────────────┐                                              │  │
  │  │  │  Prometheus    │  ← StatefulSet                               │  │
  │  │  │  Server(s)     │                                              │  │
  │  │  └────────────────┘                                              │  │
  │  │                                                                  │  │
  │  │  ┌────────────────┐  ┌────────────────┐  ┌──────────────────┐  │  │
  │  │  │  node-exporter │  │  kube-state-   │  │  Metriques       │  │  │
  │  │  │  (DaemonSet)   │  │  metrics       │  │  kubelet/cAdvisor│  │  │
  │  │  │                │  │  (Deployment)  │  │  (natif K8s)     │  │  │
  │  │  │  CPU, RAM,     │  │                │  │                  │  │  │
  │  │  │  disque, reseau│  │  Pods, deploy, │  │  Metriques       │  │  │
  │  │  │  du NODE       │  │  services,     │  │  conteneurs      │  │  │
  │  │  │                │  │  jobs, etc.    │  │                  │  │  │
  │  │  └────────────────┘  └────────────────┘  └──────────────────┘  │  │
  │  └──────────────────────────────────────────────────────────────────┘  │
  └────────────────────────────────────────────────────────────────────────┘
```

Installation :

```bash
# Ajouter le repo Helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Installation avec valeurs par defaut
helm install kube-prom prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace

# Installation avec valeurs custom
helm install kube-prom prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  -f values.yaml
```

```yaml
# values.yaml pour kube-prometheus-stack
prometheus:
  prometheusSpec:
    retention: 30d
    retentionSize: "50GB"
    # Scrape interval
    scrapeInterval: "15s"
    evaluationInterval: "15s"
    # Resources
    resources:
      requests:
        memory: "2Gi"
        cpu: "1"
      limits:
        memory: "4Gi"
        cpu: "2"
    # Stockage persistant
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: "local-path"
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi
    # Remote write
    remoteWrite:
      - url: "http://mimir.monitoring.svc:9009/api/v1/push"
    # Selectionner tous les ServiceMonitors
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false

alertmanager:
  alertmanagerSpec:
    resources:
      requests:
        memory: "256Mi"
        cpu: "100m"

grafana:
  adminPassword: "change-me"
  persistence:
    enabled: true
    size: 10Gi

# Node exporter sur tous les nodes
nodeExporter:
  enabled: true

# Kube state metrics
kubeStateMetrics:
  enabled: true
```

### 10.2 Prometheus Operator et CRDs

Le Prometheus Operator utilise des Custom Resource Definitions (CRDs) pour configurer le monitoring de maniere declarative et Kubernetes-native.

```
CRDs du Prometheus Operator :
═════════════════════════════

  ┌──────────────────┐
  │  Prometheus      │  Definit une instance Prometheus
  │  (CRD)           │  (replicas, retention, storage, remote write...)
  └──────────────────┘

  ┌──────────────────┐
  │  Alertmanager    │  Definit une instance Alertmanager
  │  (CRD)           │  (replicas, config...)
  └──────────────────┘

  ┌──────────────────┐
  │  ServiceMonitor  │  Definit un scrape via un Service K8s
  │  (CRD)           │  (selectionne des Services par labels)
  └──────────────────┘

  ┌──────────────────┐
  │  PodMonitor      │  Definit un scrape directement sur des Pods
  │  (CRD)           │  (selectionne des Pods par labels)
  └──────────────────┘

  ┌──────────────────┐
  │  PrometheusRule  │  Definit des recording/alerting rules
  │  (CRD)           │  (genere automatiquement le fichier de rules)
  └──────────────────┘

  ┌──────────────────┐
  │  AlertmanagerConfig│ Definit des routes et receivers
  │  (CRD)              │ pour Alertmanager
  └──────────────────┘

  Flux :
  ──────
  1. Tu crees un ServiceMonitor dans le namespace de ton app
  2. Le Prometheus Operator detecte le nouveau ServiceMonitor
  3. L'Operator met a jour la config de Prometheus
  4. Prometheus commence a scraper la target
```

### 10.3 ServiceMonitor et PodMonitor

```yaml
# ServiceMonitor : scraper un Service Kubernetes
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: mon-api
  namespace: monitoring
  labels:
    # Le Prometheus Operator selectionne les ServiceMonitors par ces labels
    release: kube-prom
spec:
  # Selectionner le Service a monitorer
  selector:
    matchLabels:
      app: mon-api
  # Dans quel(s) namespace(s) chercher le Service
  namespaceSelector:
    matchNames:
      - production
      - staging
  # Configuration du scrape
  endpoints:
    - port: http-metrics    # Nom du port dans le Service
      path: /metrics
      interval: 15s
      scrapeTimeout: 10s
      # Relabeling
      relabelings:
        - sourceLabels: [__meta_kubernetes_namespace]
          targetLabel: namespace
        - sourceLabels: [__meta_kubernetes_pod_name]
          targetLabel: pod
      # Metric relabeling (apres le scrape)
      metricRelabelings:
        - sourceLabels: [__name__]
          regex: "go_gc_.*"
          action: drop
---
# PodMonitor : scraper des Pods directement (sans Service)
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: envoy-sidecar
  namespace: monitoring
  labels:
    release: kube-prom
spec:
  selector:
    matchLabels:
      app: mon-api
  podMetricsEndpoints:
    - port: envoy-admin
      path: /stats/prometheus
      interval: 30s
---
# PrometheusRule : definir des rules
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: api-rules
  namespace: monitoring
  labels:
    release: kube-prom
spec:
  groups:
    - name: api.rules
      rules:
        - alert: ApiHighErrorRate
          expr: |
            sum(rate(http_requests_total{job="mon-api", status=~"5.."}[5m]))
            /
            sum(rate(http_requests_total{job="mon-api"}[5m]))
            > 0.05
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Taux d'erreur API > 5%"
```

### 10.4 Metriques Kubernetes : kube-state-metrics vs cAdvisor vs node-exporter

```
Trois sources complementaires de metriques K8s :
═════════════════════════════════════════════════

  ┌─────────────────────────────────────────────────────────────────────┐
  │                                                                     │
  │  NODE-EXPORTER (DaemonSet)                                         │
  │  ──────────────────────────                                         │
  │  Metriques du NODE (machine physique/VM)                            │
  │                                                                     │
  │  - node_cpu_seconds_total         (CPU par mode)                    │
  │  - node_memory_MemAvailable_bytes (RAM disponible)                  │
  │  - node_filesystem_avail_bytes    (Espace disque)                   │
  │  - node_network_receive_bytes_total (Reseau)                        │
  │  - node_load1, node_load5, node_load15 (Load average)              │
  │  - node_disk_io_time_seconds_total (I/O disque)                     │
  │                                                                     │
  │  Repond a : "Comment va la MACHINE ?"                               │
  └─────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────┐
  │                                                                     │
  │  cADVISOR (integre dans kubelet)                                    │
  │  ──────────────────────────────                                     │
  │  Metriques des CONTENEURS                                           │
  │                                                                     │
  │  - container_cpu_usage_seconds_total  (CPU par conteneur)           │
  │  - container_memory_usage_bytes       (RAM par conteneur)           │
  │  - container_network_receive_bytes_total (Reseau par conteneur)     │
  │  - container_fs_reads_bytes_total     (I/O disque par conteneur)    │
  │                                                                     │
  │  Repond a : "Combien de RESSOURCES consomme chaque conteneur ?"    │
  └─────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────┐
  │                                                                     │
  │  KUBE-STATE-METRICS (Deployment)                                    │
  │  ───────────────────────────────                                    │
  │  Metriques de l'ETAT des objets Kubernetes                          │
  │                                                                     │
  │  - kube_pod_status_phase           (phase du pod)                   │
  │  - kube_pod_container_status_restarts_total (restarts)              │
  │  - kube_deployment_spec_replicas   (replicas desires)               │
  │  - kube_deployment_status_ready_replicas (replicas ready)           │
  │  - kube_node_status_condition      (etat du node)                   │
  │  - kube_job_status_succeeded       (jobs termines)                  │
  │  - kube_hpa_status_current_replicas (HPA)                           │
  │                                                                     │
  │  Repond a : "Quel est l'ETAT des objets Kubernetes ?"              │
  └─────────────────────────────────────────────────────────────────────┘

  Ensemble, ces 3 sources couvrent tout :
  - L'infra (nodes) → node-exporter
  - Les workloads (conteneurs) → cAdvisor
  - L'orchestration (objets K8s) → kube-state-metrics
```

---
