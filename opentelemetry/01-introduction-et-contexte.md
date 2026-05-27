## 1. Introduction et contexte

### 1.1 Qu'est-ce que l'observabilité ?

L'observabilité est la capacité à comprendre l'état interne d'un système à partir de ses sorties externes. Contrairement au monitoring classique (qui répond à "est-ce que ça marche ?"), l'observabilité répond à "pourquoi ça ne marche pas ?" — y compris pour des problèmes jamais rencontrés auparavant.

Elle repose sur **trois piliers** complémentaires :

```
┌─────────────────────────────────────────────────────────────────────┐
│                        OBSERVABILITÉ                                │
│                                                                     │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐           │
│  │   METRICS     │  │    LOGS       │  │   TRACES      │           │
│  │               │  │               │  │               │           │
│  │ "Quoi"        │  │ "Pourquoi"    │  │ "Où et quand" │           │
│  │               │  │               │  │               │           │
│  │ - Compteurs   │  │ - Événements  │  │ - Spans       │           │
│  │ - Gauges      │  │ - Erreurs     │  │ - Context     │           │
│  │ - Histogrammes│  │ - Debug info  │  │ - Propagation │           │
│  │               │  │               │  │               │           │
│  │ Réponse :     │  │ Réponse :     │  │ Réponse :     │           │
│  │ "Le taux      │  │ "L'erreur est │  │ "La latence   │           │
│  │ d'erreur est  │  │ un NPE dans   │  │ vient du      │           │
│  │ à 5%"         │  │ UserService"  │  │ service DB"   │           │
│  └───────────────┘  └───────────────┘  └───────────────┘           │
│                                                                     │
│  Corrélés ensemble, ces 3 signaux permettent un diagnostic complet  │
└─────────────────────────────────────────────────────────────────────┘
```

**Metrics** : Données numériques agrégées dans le temps. Elles sont idéales pour les alertes et les dashboards. Tu connais cela via Prometheus : `http_requests_total`, `process_cpu_seconds_total`, etc. Les métriques répondent au "quoi" : quel est le taux d'erreur ? Quelle est la latence p99 ?

**Logs** : Enregistrements textuels horodatés d'événements discrets. Tu les exploites déjà via Loki. Ils répondent au "pourquoi" : quelle erreur s'est produite ? Quel utilisateur était concerné ? Les logs sont riches en contexte mais coûteux en volume.

**Traces (distribuées)** : Représentation du chemin complet d'une requête à travers un système distribué. Chaque trace est composée de spans (opérations unitaires). Elles répondent au "où et quand" : dans quel service la latence est-elle introduite ? Quel appel a échoué dans la chaîne ?

La puissance de l'observabilité moderne réside dans la **corrélation** entre ces trois signaux. Par exemple : une alerte sur une métrique de latence te conduit à une trace montrant que le service `payment` est lent, et les logs de ce service révèlent des timeouts sur la connexion à la base de données.

### 1.2 Le problème avant OpenTelemetry

Avant OpenTelemetry, l'écosystème de l'observabilité était extrêmement fragmenté :

```
AVANT OpenTelemetry :
┌─────────────────────────────────────────────────────────────┐
│                     APPLICATION                              │
│                                                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │Prometheus │  │ Jaeger   │  │ Datadog  │  │ New Relic│   │
│  │  client   │  │ client   │  │  agent   │  │  agent   │   │
│  │  library  │  │ library  │  │  library │  │  library │   │
│  └─────┬────┘  └─────┬────┘  └─────┬────┘  └─────┬────┘   │
│        │             │             │             │          │
│  Chaque vendor a sa propre lib, son propre format,          │
│  son propre protocole. Le code applicatif est couplé        │
│  au backend d'observabilité.                                │
└────────┼─────────────┼─────────────┼─────────────┼──────────┘
         │             │             │             │
         ▼             ▼             ▼             ▼
    Prometheus      Jaeger       Datadog       New Relic
```

**Problèmes concrets** :

1. **Vendor lock-in** : Si ton code utilise le client Datadog, migrer vers Grafana Cloud nécessite de modifier chaque application, chaque bibliothèque, chaque configuration. C'est un projet à part entière.

2. **Fragmentation des standards** : Pour le tracing, il existait OpenTracing (API sans implémentation) et OpenCensus (API + implémentation par Google). Deux projets, deux communautés, deux approches incompatibles. Pour les métriques, chaque vendor avait son format. Pour les logs, c'était encore pire : stdout, syslog, fichiers, formats propriétaires.

3. **Instrumentation multiple** : Une même application devait embarquer 2, 3, voire 4 bibliothèques d'instrumentation différentes. Cela alourdissait les binaires, complexifiait les dépendances, et créait des conflits.

4. **Pas de corrélation native** : Sans standard commun, corréler une métrique avec une trace et un log nécessitait des hacks et du glue-code.

5. **Coût de maintenance** : Chaque upgrade d'un backend d'observabilité pouvait casser l'intégration. Les équipes DevOps passaient un temps considérable à maintenir la plomberie.

### 1.3 Historique : OpenTracing + OpenCensus -> OpenTelemetry

```
Timeline :

2016 ──── OpenTracing rejoint la CNCF (projet de standard pour le tracing)
   │      - API uniquement, pas d'implémentation
   │      - Supporté par Uber (Jaeger), LightStep, etc.
   │
2017 ──── OpenCensus lancé par Google
   │      - API + SDK + Exporters
   │      - Metrics + Tracing
   │      - Issu du projet Census interne à Google
   │
2018 ──── Les deux projets coexistent et se font concurrence
   │      - La communauté est divisée
   │      - Les utilisateurs doivent choisir un camp
   │
2019 ──── Fusion annoncée : OpenTelemetry (OTel)
   │      - Merger des deux communautés
   │      - Objectif : un standard unique et universel
   │      - Projet CNCF dès le départ
   │
2021 ──── Traces API/SDK déclarées stables
   │
2023 ──── Metrics API/SDK déclarées stables
   │      Logs API/SDK en beta
   │
2024 ──── Logs déclarés stables
   │      OTel devient le 2e projet le plus actif de la CNCF (après K8s)
   │
2025 ──── Adoption massive en production
          Profiling en développement actif
          Semantic Conventions en stabilisation
```

Le point clé : OpenTelemetry n'est **pas** un backend d'observabilité. Il ne stocke pas de données, ne fournit pas de dashboards. C'est une **couche d'instrumentation et de collecte standardisée** qui s'intercale entre tes applications et tes backends (Prometheus, Grafana, Tempo, Loki, Datadog, ou n'importe quel autre).

### 1.4 CNCF et adoption par l'industrie

OpenTelemetry est un projet **Incubating** de la CNCF (Cloud Native Computing Foundation), en chemin vers le statut **Graduated**. C'est le deuxième projet le plus actif après Kubernetes en termes de contributeurs.

**Qui l'utilise et le soutient** :
- **Cloud providers** : AWS (ADOT), Google Cloud, Azure Monitor, tous supportent OTLP nativement
- **Vendors d'observabilité** : Datadog, New Relic, Splunk, Dynatrace, Elastic — tous acceptent les données OTel
- **Projets open source** : Grafana (Tempo, Mimir, Alloy), Jaeger, Zipkin
- **Entreprises** : eBay, Shopify, GitHub, Skyscanner, Zalando

**Pourquoi c'est important pour toi en tant que DevOps** :
- Tu instrumente une fois, tu exportes partout
- Tu peux changer de backend sans toucher au code applicatif
- Les développeurs n'ont besoin d'apprendre qu'une seule API
- La communauté converge vers un standard unique

---
