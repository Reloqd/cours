## Annexe : Glossaire

| Terme | Définition |
|-------|-----------|
| **OTLP** | OpenTelemetry Protocol — le protocole natif pour transporter les données de télémétrie |
| **Span** | Opération unitaire au sein d'une trace distribuée |
| **Trace** | Ensemble de spans représentant le parcours complet d'une requête |
| **Resource** | Ensemble d'attributs identifiant la source des données (service, pod, host, etc.) |
| **Instrumentation Scope** | Identifiant de la bibliothèque d'instrumentation qui a produit les données |
| **Receiver** | Composant du Collector qui reçoit les données (entrée d'un pipeline) |
| **Processor** | Composant du Collector qui transforme les données |
| **Exporter** | Composant du Collector qui envoie les données vers un backend |
| **Connector** | Composant qui est à la fois exporter d'un pipeline et receiver d'un autre |
| **Exemplar** | Lien d'une valeur de métrique vers un span spécifique (pont metrics↔traces) |
| **Baggage** | Données contextuelles propagées entre services (au-delà du trace context) |
| **Semantic Conventions** | Noms standardisés pour les attributs, métriques et spans |
| **Temporality** | Cumulative (total depuis le début) ou Delta (changement depuis le dernier export) |
| **Head-based sampling** | Décision d'échantillonnage prise au début de la trace |
| **Tail-based sampling** | Décision d'échantillonnage prise après avoir vu la trace complète |
| **OTTL** | OpenTelemetry Transformation Language — langage de transformation dans le Collector |
| **OCB** | OpenTelemetry Collector Builder — outil pour construire un Collector custom |
| **RED** | Rate, Errors, Duration — les trois métriques fondamentales d'un service |

---

*Dernière mise à jour : mai 2025*
*Ce cours couvre OpenTelemetry specification v1.39+ et Collector v0.116+*
