## 7. Integration avec Alertmanager

### 7.1 Architecture

```
Flux complet des alertes :
══════════════════════════

  ┌──────────────┐                    ┌─────────────────────┐
  │  Prometheus  │                    │    ALERTMANAGER      │
  │              │                    │                      │
  │  Rule Engine │   HTTP POST        │  ┌───────────────┐  │
  │  evalue les  │──────────────────▶│  │   Routing     │  │
  │  alerting    │  /api/v1/alerts    │  │   Tree        │  │
  │  rules       │                    │  │               │  │
  │              │                    │  │  Match les    │  │
  │  Si condition│                    │  │  alertes aux  │  │
  │  vraie pour  │                    │  │  receivers    │  │
  │  >= "for"    │                    │  └───────┬───────┘  │
  │  → FIRING    │                    │          │          │
  │              │                    │          ▼          │
  │  Si condition│                    │  ┌───────────────┐  │
  │  fausse      │                    │  │   Grouping    │  │
  │  → RESOLVED  │                    │  │               │  │
  │              │                    │  │  Regroupe les │  │
  │              │                    │  │  alertes avec │  │
  │              │                    │  │  les memes    │  │
  │              │                    │  │  labels       │  │
  │              │                    │  └───────┬───────┘  │
  └──────────────┘                    │          │          │
                                      │          ▼          │
                                      │  ┌───────────────┐  │
                                      │  │  Inhibition   │  │
                                      │  │               │  │
                                      │  │  Supprime les │  │
                                      │  │  alertes si   │  │
                                      │  │  une alerte   │  │
                                      │  │  parente est  │  │
                                      │  │  active       │  │
                                      │  └───────┬───────┘  │
                                      │          │          │
                                      │          ▼          │
                                      │  ┌───────────────┐  │
                                      │  │   Silences    │  │
                                      │  │               │  │
                                      │  │  Mute les     │  │
                                      │  │  alertes      │  │
                                      │  │  matchees     │  │
                                      │  │  (maintenance)│  │
                                      │  └───────┬───────┘  │
                                      │          │          │
                                      │          ▼          │
                                      │  ┌───────────────┐  │
                                      │  │  Receivers    │  │
                                      │  │               │  │
                                      │  │  - Email      │  │
                                      │  │  - Slack      │  │
                                      │  │  - Discord    │  │
                                      │  │  - PagerDuty  │  │
                                      │  │  - Webhook    │  │
                                      │  └───────────────┘  │
                                      └─────────────────────┘
```

### 7.2 Configuration d'Alertmanager

```yaml
# alertmanager.yml - Configuration complete
global:
  # Timeout de resolution automatique si Prometheus n'envoie plus l'alerte
  resolve_timeout: 5m

  # SMTP global (pour les alertes email)
  smtp_smarthost: "smtp.gmail.com:587"
  smtp_from: "alertmanager@example.com"
  smtp_auth_username: "alertmanager@example.com"
  smtp_auth_password: "app-password"
  smtp_require_tls: true

  # Slack global
  slack_api_url: "https://hooks.slack.com/services/T00/B00/XXXXX"

# ─────────────────────────────────────────────────────
# TEMPLATES : fichiers de templates de notification
# ─────────────────────────────────────────────────────
templates:
  - "/etc/alertmanager/templates/*.tmpl"

# ─────────────────────────────────────────────────────
# ROUTE : arbre de routage des alertes
# ─────────────────────────────────────────────────────
route:
  # Receiver par defaut (si aucune route enfant ne matche)
  receiver: "slack-default"

  # Labels utilises pour grouper les alertes
  # Les alertes avec les memes valeurs pour ces labels sont groupees
  group_by: ["alertname", "job", "severity"]

  # Delai avant d'envoyer le premier groupe de notifications
  group_wait: 30s

  # Delai entre les notifications pour le meme groupe
  group_interval: 5m

  # Delai minimum entre deux envois de la meme alerte
  repeat_interval: 4h

  # Routes enfants (evaluees dans l'ordre, la premiere qui matche gagne)
  routes:
    # Alertes critiques → PagerDuty + Slack
    - match:
        severity: critical
      receiver: "pagerduty-critical"
      continue: true  # Continue a evaluer les routes suivantes
      routes:
        - match:
            severity: critical
          receiver: "slack-critical"

    # Alertes de l'equipe infrastructure → canal Slack dedie
    - match:
        team: infrastructure
      receiver: "slack-infra"
      group_by: ["alertname", "instance"]

    # Alertes de l'equipe backend → canal Slack dedie
    - match:
        team: backend
      receiver: "slack-backend"

    # Alertes Kubernetes → Discord
    - match_re:
        alertname: "Kube.*"
      receiver: "discord-k8s"

    # Watchdog (heartbeat) → webhook
    - match:
        alertname: Watchdog
      receiver: "webhook-heartbeat"
      repeat_interval: 1m

# ─────────────────────────────────────────────────────
# INHIBITION RULES : supprimer les alertes redondantes
# ─────────────────────────────────────────────────────
inhibit_rules:
  # Si une alerte critical est active, supprimer les warnings du meme job
  - source_match:
      severity: "critical"
    target_match:
      severity: "warning"
    equal: ["alertname", "job", "instance"]

  # Si le node est down, supprimer les alertes des pods sur ce node
  - source_match:
      alertname: "KubeNodeNotReady"
    target_match_re:
      alertname: "KubePod.*"
    equal: ["node"]

# ─────────────────────────────────────────────────────
# RECEIVERS : destinations des notifications
# ─────────────────────────────────────────────────────
receivers:
  # ---- Slack ----
  - name: "slack-default"
    slack_configs:
      - channel: "#alerts-default"
        send_resolved: true
        title: '{{ if eq .Status "firing" }}[FIRING] {{ else }}[RESOLVED] {{ end }}{{ .CommonLabels.alertname }}'
        text: >-
          {{ range .Alerts }}
          *{{ .Labels.alertname }}* ({{ .Labels.severity }})
          {{ .Annotations.summary }}
          {{ .Annotations.description }}
          {{ end }}
        color: '{{ if eq .Status "firing" }}{{ if eq .CommonLabels.severity "critical" }}danger{{ else }}warning{{ end }}{{ else }}good{{ end }}'

  - name: "slack-critical"
    slack_configs:
      - channel: "#alerts-critical"
        send_resolved: true

  - name: "slack-infra"
    slack_configs:
      - channel: "#alerts-infrastructure"
        send_resolved: true

  - name: "slack-backend"
    slack_configs:
      - channel: "#alerts-backend"
        send_resolved: true

  # ---- Email ----
  - name: "email-oncall"
    email_configs:
      - to: "oncall@example.com"
        send_resolved: true
        headers:
          Subject: '{{ if eq .Status "firing" }}[ALERT] {{ else }}[RESOLVED] {{ end }}{{ .CommonLabels.alertname }}'

  # ---- Discord ----
  - name: "discord-k8s"
    discord_configs:
      - webhook_url: "https://discord.com/api/webhooks/XXXX/YYYY"
        send_resolved: true
        title: '{{ .CommonLabels.alertname }}'
        message: >-
          {{ range .Alerts }}
          **{{ .Labels.alertname }}** - {{ .Labels.severity }}
          {{ .Annotations.summary }}
          {{ end }}

  # ---- PagerDuty ----
  - name: "pagerduty-critical"
    pagerduty_configs:
      - service_key: "PAGERDUTY_SERVICE_KEY"
        severity: '{{ .CommonLabels.severity }}'
        description: '{{ .CommonAnnotations.summary }}'

  # ---- Webhook generique ----
  - name: "webhook-heartbeat"
    webhook_configs:
      - url: "https://healthcheck.example.com/ping/UUID"
        send_resolved: true

  - name: "webhook-custom"
    webhook_configs:
      - url: "http://notification-service:8080/alerts"
        send_resolved: true
        max_alerts: 10  # Nombre max d'alertes par requete
```

### 7.3 Grouping, Inhibition et Silences

```
GROUPING :
══════════

  Sans grouping :
  10 alertes TargetDown = 10 notifications distinctes

  Avec group_by: ["alertname"] :
  10 alertes TargetDown = 1 notification groupee avec les 10 alertes

  group_wait: 30s    → Attend 30s pour accumuler les alertes du groupe
  group_interval: 5m → Attend 5m avant d'envoyer une mise a jour du groupe
  repeat_interval: 4h → Re-notifie apres 4h si l'alerte est toujours active

INHIBITION :
════════════

  Scenario : le node-01 tombe.
  → Alerte KubeNodeNotReady (critical)
  → 20 alertes KubePodNotReady pour les pods sur ce node

  Sans inhibition : 21 notifications (bruit)
  Avec inhibition : 1 notification (KubeNodeNotReady)

  La regle d'inhibition supprime KubePod* quand KubeNodeNotReady
  est active sur le meme node.

SILENCES :
══════════

  Les silences mutent temporairement des alertes.
  Utilisation : maintenance planifiee, mise a jour, problemes connus.

  Creer un silence via l'UI Alertmanager (http://alertmanager:9093/#/silences)
  ou via l'API :

  # Creer un silence de 2h pour toutes les alertes du job "api"
  curl -X POST http://alertmanager:9093/api/v2/silences \
    -H "Content-Type: application/json" \
    -d '{
      "matchers": [{"name": "job", "value": "api", "isRegex": false}],
      "startsAt": "2025-01-01T00:00:00Z",
      "endsAt": "2025-01-01T02:00:00Z",
      "createdBy": "steven",
      "comment": "Maintenance planifiee de l API"
    }'
```

---
