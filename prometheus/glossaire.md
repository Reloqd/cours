## Glossaire

| Terme | Definition |
|-------|------------|
| **Sample** | Un point de donnees : (timestamp, valeur) pour une serie temporelle donnee |
| **Series temporelle** | Une sequence de samples identifiee par un nom de metrique + labels |
| **Label** | Paire cle=valeur qui identifie une dimension d'une metrique |
| **Cardinalite** | Nombre total de series temporelles uniques |
| **Scrape** | Action de Prometheus collectant les metriques d'une target via HTTP GET /metrics |
| **Target** | Un endpoint HTTP qui expose des metriques au format Prometheus |
| **Exporter** | Un processus qui collecte des metriques d'un systeme tiers et les expose au format Prometheus |
| **TSDB** | Time Series Database, le moteur de stockage de Prometheus |
| **WAL** | Write-Ahead Log, journal d'ecriture anticipee pour la durabilite |
| **Head block** | Bloc en memoire contenant les ~2 dernieres heures de donnees |
| **Compaction** | Fusion de petits blocks en plus gros blocks sur disque |
| **Recording rule** | Regle qui pre-calcule une requete PromQL et stocke le resultat |
| **Alerting rule** | Regle qui evalue une condition et envoie une alerte si vraie |
| **Instant vector** | Ensemble de series temporelles, chacune avec un seul sample |
| **Range vector** | Ensemble de series temporelles, chacune avec plusieurs samples sur une fenetre de temps |
| **Remote write** | Protocole pour envoyer les metriques vers un stockage distant |
| **PromQL** | Prometheus Query Language, langage de requete pour les series temporelles |
| **Churn** | Creation et suppression frequentes de series temporelles (probleme de performance) |
| **Native histogram** | Nouveau type d'histogram (Prometheus v3) avec buckets dynamiques exponentiels |

---

> Ce cours couvre Prometheus de la theorie a la production. L'etape suivante est de combiner ces connaissances avec le cours OpenTelemetry pour construire une stack d'observabilite complete : OTel pour l'instrumentation, Prometheus pour le stockage des metriques, Grafana pour la visualisation, et Alertmanager pour les alertes.
