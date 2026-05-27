## Exercices pratiques

### Exercice 1 : Setup de base

Deployer un stack Prometheus + node-exporter + Grafana avec Docker Compose. Verifier que Prometheus scrape correctement node-exporter. Creer un dashboard Grafana avec les metriques CPU, memoire, disque, et reseau.

### Exercice 2 : PromQL

Ecrire les requetes PromQL suivantes et les tester dans l'UI Prometheus :
1. Taux d'utilisation CPU moyen sur 5 minutes
2. Top 3 des partitions les plus remplies
3. Debit reseau entrant en Mbps
4. Prediction de l'espace disque dans 7 jours
5. Nombre total de scrapes reussies depuis le demarrage

### Exercice 3 : Alerting

Creer des alerting rules pour :
1. CPU > 80% pendant 10 minutes (warning)
2. CPU > 95% pendant 5 minutes (critical)
3. Disque plein dans moins de 24h
4. Target down depuis 3 minutes
Les valider avec `promtool check rules`.

### Exercice 4 : Service Discovery Docker

Configurer `docker_sd_configs` pour decouvrir automatiquement les conteneurs Docker avec le label `prometheus.scrape=true`. Deployer un conteneur avec ce label et verifier qu'il apparait dans les targets Prometheus.

### Exercice 5 : Remote Write

Configurer le remote write vers un Mimir en mode monolithique (Docker). Verifier que les metriques sont recues par Mimir. Configurer Grafana pour interroger Mimir comme data source.

### Exercice 6 : Blackbox Exporter

Deployer le blackbox-exporter et configurer des probes HTTP pour 3 sites web. Creer une alerte quand un site est down ou quand le certificat SSL expire dans moins de 30 jours.

### Exercice 7 : Recording Rules

Creer des recording rules pour pre-calculer :
1. Le taux de requetes HTTP par methode et par status code
2. L'utilisation CPU par instance
3. La latence p99 par endpoint
Verifier que les nouvelles series apparaissent dans Prometheus.

### Exercice 8 : Exporter Custom

Ecrire un exporter custom en Python (ou Go) qui expose :
- Un counter pour le nombre de requetes traitees
- Un gauge pour la temperature
- Un histogram pour la duree de traitement
Le deployer, le scraper avec Prometheus, et visualiser dans Grafana.

---
