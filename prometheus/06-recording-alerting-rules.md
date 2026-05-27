## 6. Recording Rules et Alerting Rules

### 6.1 Recording Rules

Les recording rules pre-calculent des requetes PromQL couteuses et stockent le resultat comme de nouvelles series temporelles. Elles sont evaluees a chaque `evaluation_interval`.

**Quand utiliser des recording rules** :
- Requetes PromQL complexes utilisees dans plusieurs dashboards
- Agregations couteuses sur de nombreuses series
- Requetes dans les alertes (les alertes doivent etre rapides)
- Pre-calcul pour accelerer les dashboards Grafana

```yaml
# rules/recording_rules.yml
groups:
  # ---- Regles pour les requetes HTTP ----
  - name: http_recording_rules
    interval: 15s  # Override de evaluation_interval (optionnel)
    rules:
      # Convention de nommage : level:metric:operations
      # level = niveau d'agregation (job, instance, namespace...)
      # metric = nom de la metrique source
      # operations = operations appliquees (rate5m, sum, etc.)

      # Taux de requetes par job et methode
      - record: job_method:http_requests_total:rate5m
        expr: sum by (job, method) (rate(http_requests_total[5m]))

      # Taux d'erreurs par job
      - record: job:http_requests_errors:rate5m
        expr: sum by (job) (rate(http_requests_total{status=~"5.."}[5m]))

      # Taux d'erreur en pourcentage par job
      - record: job:http_requests_error_rate:ratio_rate5m
        expr: |
          job:http_requests_errors:rate5m
          /
          sum by (job) (rate(http_requests_total[5m]))

      # Latence p99 par job
      - record: job:http_request_duration_seconds:p99_rate5m
        expr: |
          histogram_quantile(0.99,
            sum by (job, le) (rate(http_request_duration_seconds_bucket[5m]))
          )

      # Latence p50 par job
      - record: job:http_request_duration_seconds:p50_rate5m
        expr: |
          histogram_quantile(0.50,
            sum by (job, le) (rate(http_request_duration_seconds_bucket[5m]))
          )

  # ---- Regles pour les metriques systeme ----
  - name: node_recording_rules
    rules:
      # Utilisation CPU par instance
      - record: instance:node_cpu_utilisation:rate5m
        expr: |
          1 - avg by (instance) (
            rate(node_cpu_seconds_total{mode="idle"}[5m])
          )

      # Utilisation memoire par instance
      - record: instance:node_memory_utilisation:ratio
        expr: |
          1 - (
            node_memory_MemAvailable_bytes
            /
            node_memory_MemTotal_bytes
          )

      # Utilisation disque par instance et mountpoint
      - record: instance_mountpoint:node_filesystem_utilisation:ratio
        expr: |
          1 - (
            node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}
            /
            node_filesystem_size_bytes{fstype!~"tmpfs|overlay"}
          )

      # Debit reseau entrant par instance (bytes/s)
      - record: instance:node_network_receive_bytes:rate5m
        expr: |
          sum by (instance) (
            rate(node_network_receive_bytes_total{device!~"lo|docker.*|veth.*|br-.*"}[5m])
          )

      # Debit reseau sortant par instance (bytes/s)
      - record: instance:node_network_transmit_bytes:rate5m
        expr: |
          sum by (instance) (
            rate(node_network_transmit_bytes_total{device!~"lo|docker.*|veth.*|br-.*"}[5m])
          )
```

### 6.2 Naming conventions pour les recording rules

```
Convention : level:metric_name:operations
═════════════════════════════════════════

  level       : le niveau d'agregation
                job, instance, namespace, cluster, pod, node...

  metric_name : le nom de la metrique source (sans _total, _bucket, etc.)

  operations  : les operations PromQL appliquees
                rate5m, ratio, sum, p99, etc.

  Exemples :
  ─────────
  job:http_requests_total:rate5m
  │   │                   │
  │   │                   └─ rate sur 5 minutes
  │   └─ metrique source
  └─ agrege par job

  instance:node_cpu_utilisation:rate5m
  │        │                    │
  │        │                    └─ rate sur 5 minutes
  │        └─ metrique derivee
  └─ agrege par instance

  namespace_pod:container_cpu_usage:sum_rate5m
  │              │                   │
  │              │                   └─ sum du rate 5m
  │              └─ metrique source
  └─ agrege par namespace et pod
```

### 6.3 Alerting Rules

Les alerting rules evaluent des conditions PromQL et, si la condition est vraie pendant la duree specifiee par `for`, envoient une alerte a Alertmanager.

```yaml
# rules/alerting_rules.yml
groups:
  # ===========================================================
  # ALERTES INFRASTRUCTURE
  # ===========================================================
  - name: infrastructure_alerts
    rules:
      # ---- CPU ----
      - alert: HighCpuUsage
        expr: instance:node_cpu_utilisation:rate5m > 0.85
        for: 10m
        labels:
          severity: warning
          team: infrastructure
        annotations:
          summary: "CPU eleve sur {{ $labels.instance }}"
          description: >-
            L'instance {{ $labels.instance }} a une utilisation CPU
            de {{ $value | humanizePercentage }} depuis plus de 10 minutes.
          runbook_url: "https://wiki.internal/runbooks/high-cpu"

      - alert: CriticalCpuUsage
        expr: instance:node_cpu_utilisation:rate5m > 0.95
        for: 5m
        labels:
          severity: critical
          team: infrastructure
        annotations:
          summary: "CPU critique sur {{ $labels.instance }}"
          description: >-
            L'instance {{ $labels.instance }} a une utilisation CPU
            de {{ $value | humanizePercentage }} depuis plus de 5 minutes.

      # ---- Memoire ----
      - alert: HighMemoryUsage
        expr: instance:node_memory_utilisation:ratio > 0.85
        for: 10m
        labels:
          severity: warning
          team: infrastructure
        annotations:
          summary: "Memoire elevee sur {{ $labels.instance }}"
          description: >-
            L'instance {{ $labels.instance }} utilise
            {{ $value | humanizePercentage }} de sa memoire.

      - alert: MemoryAlmostFull
        expr: instance:node_memory_utilisation:ratio > 0.95
        for: 5m
        labels:
          severity: critical
          team: infrastructure
        annotations:
          summary: "Memoire critique sur {{ $labels.instance }}"
          description: >-
            L'instance {{ $labels.instance }} utilise
            {{ $value | humanizePercentage }} de sa memoire.
            Risque d'OOM killer imminent.

      # ---- Disque ----
      - alert: DiskSpaceRunningLow
        expr: instance_mountpoint:node_filesystem_utilisation:ratio > 0.80
        for: 15m
        labels:
          severity: warning
          team: infrastructure
        annotations:
          summary: "Disque {{ $labels.mountpoint }} presque plein sur {{ $labels.instance }}"
          description: >-
            La partition {{ $labels.mountpoint }} sur {{ $labels.instance }}
            est remplie a {{ $value | humanizePercentage }}.

      - alert: DiskWillFillIn24Hours
        expr: |
          predict_linear(
            node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}[6h], 24*3600
          ) < 0
        for: 30m
        labels:
          severity: warning
          team: infrastructure
        annotations:
          summary: "Disque {{ $labels.mountpoint }} sera plein dans 24h sur {{ $labels.instance }}"
          description: >-
            En extrapolant la tendance des 6 dernieres heures,
            la partition {{ $labels.mountpoint }} sur {{ $labels.instance }}
            sera pleine dans moins de 24 heures.

      - alert: DiskWillFillIn4Hours
        expr: |
          predict_linear(
            node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}[4h], 4*3600
          ) < 0
        for: 15m
        labels:
          severity: critical
          team: infrastructure
        annotations:
          summary: "URGENT - Disque {{ $labels.mountpoint }} sera plein dans 4h"
          description: >-
            Partition {{ $labels.mountpoint }} sur {{ $labels.instance }}.
            Action immediate requise.

      # ---- Reseau ----
      - alert: HighNetworkTraffic
        expr: |
          instance:node_network_receive_bytes:rate5m > 100 * 1024 * 1024
        for: 15m
        labels:
          severity: warning
          team: infrastructure
        annotations:
          summary: "Trafic reseau eleve sur {{ $labels.instance }}"
          description: >-
            {{ $labels.instance }} recoit
            {{ $value | humanize1024 }}B/s de trafic reseau.

      # ---- Target down ----
      - alert: TargetDown
        expr: up == 0
        for: 3m
        labels:
          severity: critical
          team: infrastructure
        annotations:
          summary: "Target {{ $labels.job }}/{{ $labels.instance }} down"
          description: >-
            La target {{ $labels.instance }} du job {{ $labels.job }}
            n'est plus joignable depuis 3 minutes.

  # ===========================================================
  # ALERTES CONTENEURS DOCKER
  # ===========================================================
  - name: docker_alerts
    rules:
      - alert: ContainerHighCpu
        expr: |
          sum by (name) (rate(container_cpu_usage_seconds_total{name!=""}[5m])) > 0.80
        for: 10m
        labels:
          severity: warning
          team: platform
        annotations:
          summary: "Conteneur {{ $labels.name }} utilise beaucoup de CPU"
          description: >-
            Le conteneur {{ $labels.name }} utilise
            {{ $value | humanizePercentage }} de CPU.

      - alert: ContainerHighMemory
        expr: |
          container_memory_usage_bytes{name!=""}
          /
          container_spec_memory_limit_bytes{name!=""}
          > 0.90
        for: 5m
        labels:
          severity: warning
          team: platform
        annotations:
          summary: "Conteneur {{ $labels.name }} proche de sa limite memoire"
          description: >-
            Le conteneur {{ $labels.name }} utilise
            {{ $value | humanizePercentage }} de sa limite memoire.

      - alert: ContainerRestarting
        expr: |
          increase(container_restart_count{name!=""}[1h]) > 3
        for: 0m
        labels:
          severity: warning
          team: platform
        annotations:
          summary: "Conteneur {{ $labels.name }} redemarrage frequent"
          description: >-
            Le conteneur {{ $labels.name }} a redemarre
            {{ $value }} fois dans la derniere heure.

  # ===========================================================
  # ALERTES KUBERNETES
  # ===========================================================
  - name: kubernetes_alerts
    rules:
      - alert: KubePodCrashLooping
        expr: |
          rate(kube_pod_container_status_restarts_total[15m]) * 60 * 5 > 0
        for: 15m
        labels:
          severity: critical
          team: platform
        annotations:
          summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} en crash loop"
          description: >-
            Le pod {{ $labels.pod }} dans le namespace {{ $labels.namespace }}
            redemarrage en boucle.

      - alert: KubePodNotReady
        expr: |
          kube_pod_status_ready{condition="false"} == 1
        for: 15m
        labels:
          severity: warning
          team: platform
        annotations:
          summary: "Pod {{ $labels.namespace }}/{{ $labels.pod }} not ready"
          description: >-
            Le pod {{ $labels.pod }} dans {{ $labels.namespace }}
            n'est pas pret depuis 15 minutes.

      - alert: KubeDeploymentReplicasMismatch
        expr: |
          kube_deployment_spec_replicas
          !=
          kube_deployment_status_ready_replicas
        for: 15m
        labels:
          severity: warning
          team: platform
        annotations:
          summary: "Deployment {{ $labels.namespace }}/{{ $labels.deployment }} replicas mismatch"
          description: >-
            Le deployment {{ $labels.deployment }} dans {{ $labels.namespace }}
            a {{ $value }} replicas desires mais pas autant de ready.

      - alert: KubeNodeNotReady
        expr: kube_node_status_condition{condition="Ready",status="true"} == 0
        for: 5m
        labels:
          severity: critical
          team: infrastructure
        annotations:
          summary: "Node {{ $labels.node }} not ready"
          description: >-
            Le node Kubernetes {{ $labels.node }} n'est pas en etat Ready.

      - alert: KubePersistentVolumeFillingUp
        expr: |
          kubelet_volume_stats_available_bytes
          /
          kubelet_volume_stats_capacity_bytes
          < 0.10
        for: 15m
        labels:
          severity: warning
          team: infrastructure
        annotations:
          summary: "PVC {{ $labels.persistentvolumeclaim }} presque plein"
          description: >-
            Le PVC {{ $labels.persistentvolumeclaim }} dans
            {{ $labels.namespace }} n'a plus que
            {{ $value | humanizePercentage }} d'espace libre.

  # ===========================================================
  # ALERTES APPLICATIVES (RED Method)
  # ===========================================================
  - name: application_alerts
    rules:
      # Rate - Taux d'erreurs
      - alert: HighErrorRate
        expr: job:http_requests_error_rate:ratio_rate5m > 0.05
        for: 5m
        labels:
          severity: critical
          team: backend
        annotations:
          summary: "Taux d'erreur eleve pour {{ $labels.job }}"
          description: >-
            Le job {{ $labels.job }} a un taux d'erreur HTTP 5xx
            de {{ $value | humanizePercentage }} (seuil: 5%).

      # Errors - Nombre absolu d'erreurs
      - alert: TooManyErrors
        expr: |
          sum by (job) (rate(http_requests_total{status=~"5.."}[5m])) > 10
        for: 5m
        labels:
          severity: warning
          team: backend
        annotations:
          summary: "Plus de 10 erreurs/s pour {{ $labels.job }}"

      # Duration - Latence elevee
      - alert: HighLatencyP99
        expr: job:http_request_duration_seconds:p99_rate5m > 1
        for: 10m
        labels:
          severity: warning
          team: backend
        annotations:
          summary: "Latence p99 elevee pour {{ $labels.job }}"
          description: >-
            La latence p99 du job {{ $labels.job }} est de
            {{ $value | humanizeDuration }} (seuil: 1s).

      # Saturation
      - alert: HighSaturation
        expr: |
          sum by (job) (go_goroutines) > 1000
        for: 5m
        labels:
          severity: warning
          team: backend
        annotations:
          summary: "Nombre eleve de goroutines pour {{ $labels.job }}"

  # ===========================================================
  # ALERTES PROMETHEUS (self-monitoring)
  # ===========================================================
  - name: prometheus_self_alerts
    rules:
      - alert: PrometheusTargetScrapeError
        expr: |
          increase(prometheus_target_scrapes_exceeded_sample_limit_total[1h]) > 0
        for: 0m
        labels:
          severity: warning
          team: infrastructure
        annotations:
          summary: "Prometheus depasse la limite de samples pour certaines targets"

      - alert: PrometheusTSDBCompactionsFailing
        expr: increase(prometheus_tsdb_compactions_failed_total[6h]) > 0
        for: 0m
        labels:
          severity: critical
          team: infrastructure
        annotations:
          summary: "Les compactions TSDB echouent"

      - alert: PrometheusRuleEvaluationFailures
        expr: increase(prometheus_rule_evaluation_failures_total[5m]) > 0
        for: 5m
        labels:
          severity: warning
          team: infrastructure
        annotations:
          summary: "Des regles Prometheus echouent lors de l'evaluation"

      - alert: PrometheusHighCardinality
        expr: prometheus_tsdb_head_series > 1000000
        for: 1h
        labels:
          severity: warning
          team: infrastructure
        annotations:
          summary: "Prometheus a plus de 1M de series actives"
          description: >-
            Nombre de series actives : {{ $value | humanize }}.
            Verifier la cardinalite des metriques.
```

### 6.4 Templates Go dans les annotations

Les annotations supportent les templates Go pour inserer des valeurs dynamiques :

```
Variables disponibles :
═══════════════════════

  {{ $labels }}            : tous les labels de la serie
  {{ $labels.instance }}   : valeur du label "instance"
  {{ $value }}             : valeur numerique de l'expression
  {{ $externalLabels }}    : les external_labels de Prometheus

Fonctions de formatage :
════════════════════════

  {{ $value | humanize }}            : 1234567 → "1.235M"
  {{ $value | humanize1024 }}        : 1073741824 → "1Gi"
  {{ $value | humanizePercentage }}  : 0.854 → "85.4%"
  {{ $value | humanizeDuration }}    : 3723 → "1h 2m 3s"

Exemples :

  summary: "CPU a {{ $value | humanizePercentage }} sur {{ $labels.instance }}"
  → "CPU a 87.3% sur server-01:9100"

  description: >-
    Le disque {{ $labels.mountpoint }} sur {{ $labels.instance }}
    n'a plus que {{ $value | humanize1024 }}B disponible.
  → "Le disque /data sur server-01:9100 n'a plus que 2.3GiB disponible."
```

### 6.5 Tester les rules avec promtool

```bash
# Verifier la syntaxe
promtool check rules rules/alerting_rules.yml

# Test unitaire des rules
promtool test rules tests/rules_test.yml
```

Fichier de test :

```yaml
# tests/rules_test.yml
rule_files:
  - ../rules/alerting_rules.yml
  - ../rules/recording_rules.yml

evaluation_interval: 1m

tests:
  # Test : HighCpuUsage doit se declencher apres 10 minutes a > 85%
  - interval: 1m
    input_series:
      - series: 'instance:node_cpu_utilisation:rate5m{instance="server1:9100"}'
        values: "0.5 0.6 0.7 0.8 0.86 0.86 0.86 0.86 0.86 0.86 0.86 0.86 0.86"
    alert_rule_test:
      - eval_time: 10m
        alertname: HighCpuUsage
        exp_alerts: []  # Pas encore (for: 10m pas atteint)
      - eval_time: 15m
        alertname: HighCpuUsage
        exp_alerts:
          - exp_labels:
              severity: warning
              team: infrastructure
              instance: "server1:9100"
            exp_annotations:
              summary: "CPU eleve sur server1:9100"

  # Test : TargetDown doit se declencher quand up == 0
  - interval: 1m
    input_series:
      - series: 'up{job="api", instance="api:8080"}'
        values: "1 1 1 0 0 0 0"
    alert_rule_test:
      - eval_time: 6m
        alertname: TargetDown
        exp_alerts:
          - exp_labels:
              severity: critical
              team: infrastructure
              job: api
              instance: "api:8080"
```

---
