## 4. PromQL - Le langage de requete

PromQL (Prometheus Query Language) est le langage de requete de Prometheus. C'est un langage fonctionnel concu specifiquement pour les series temporelles. Maitriser PromQL est essentiel pour construire des dashboards efficaces et des alertes pertinentes.

### 4.1 Types de donnees

PromQL manipule 4 types de donnees :

```
Les 4 types de donnees PromQL :
═══════════════════════════════

1. INSTANT VECTOR : un ensemble de series temporelles,
   chacune avec UN SEUL sample (le plus recent)
   ┌──────────────────────────────────────────┐
   │ http_requests_total{method="GET"}   1523 │
   │ http_requests_total{method="POST"}   421 │
   │ http_requests_total{method="PUT"}     89 │
   └──────────────────────────────────────────┘
   Requete : http_requests_total

2. RANGE VECTOR : un ensemble de series temporelles,
   chacune avec PLUSIEURS samples sur une fenetre de temps
   ┌──────────────────────────────────────────────────────────┐
   │ http_requests_total{method="GET"}  [1520@t-4, 1521@t-3, │
   │                                     1522@t-2, 1523@t-1, │
   │                                     1524@t]              │
   │ http_requests_total{method="POST"} [418@t-4, 419@t-3,   │
   │                                     420@t-2, 421@t-1,   │
   │                                     421@t]               │
   └──────────────────────────────────────────────────────────┘
   Requete : http_requests_total[5m]

3. SCALAR : une simple valeur numerique flottante
   Exemple : 3.14, 42, -1.5

4. STRING : une simple chaine de caracteres (rarement utilise)
   Exemple : "hello"
```

**Point important** : Grafana attend un **instant vector** pour les graphiques. Les range vectors sont utilises comme **arguments de fonctions** (rate, avg_over_time, etc.), pas directement affiches.

### 4.2 Selecteurs

Les selecteurs permettent de filtrer les series temporelles :

```
Selecteurs de labels :
══════════════════════

=   : egalite exacte
!=  : difference
=~  : correspondance regex
!~  : non-correspondance regex

Exemples :

# Toutes les requetes GET
http_requests_total{method="GET"}

# Toutes les requetes sauf GET
http_requests_total{method!="GET"}

# Methodes commencant par P (POST, PUT, PATCH)
http_requests_total{method=~"P.*"}

# Toutes les metriques du job "api" sauf les status 2xx
http_requests_total{job="api", status!~"2.."}

# Combiner plusieurs filtres (AND implicite)
http_requests_total{job="api", method="GET", status=~"5.."}

# Selecteur sur le nom de la metrique (utilise le label __name__)
{__name__=~"http_requests_.*"}
# Equivalent a chercher toutes les metriques qui commencent par http_requests_

# Range vector : ajouter [duree] pour obtenir un range vector
http_requests_total{method="GET"}[5m]    # 5 dernieres minutes
http_requests_total{method="GET"}[1h]    # derniere heure
http_requests_total{method="GET"}[30s]   # 30 dernieres secondes

# Offset : decaler dans le temps
http_requests_total{method="GET"} offset 1h
# → valeur d'il y a 1 heure

# @ : fixer le timestamp d'evaluation
http_requests_total{method="GET"} @ 1716580800
# → valeur au timestamp Unix 1716580800
```

### 4.3 Operateurs

#### Operateurs arithmetiques

```
+   addition
-   soustraction
*   multiplication
/   division
%   modulo
^   puissance

Exemples :

# Pourcentage de memoire utilisee
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# Pourcentage d'espace disque utilise
(1 - node_filesystem_avail_bytes / node_filesystem_size_bytes) * 100

# Convertir des octets en gigaoctets
node_memory_MemTotal_bytes / 1024 / 1024 / 1024
# ou plus proprement :
node_memory_MemTotal_bytes / (1024^3)
```

#### Operateurs de comparaison

```
==  egal
!=  different
>   superieur
<   inferieur
>=  superieur ou egal
<=  inferieur ou egal

Par defaut, les operateurs de comparaison FILTRENT :
# Renvoie seulement les series ou la valeur > 80
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 80

Avec le mot-cle "bool", ils renvoient 0 ou 1 :
# Renvoie 1 si > 80, 0 sinon (pour chaque serie)
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > bool 80
```

#### Operateurs logiques (entre instant vectors)

```
and          : intersection (garde les series presentes des deux cotes)
or           : union (combine les series des deux cotes)
unless       : difference (garde les series du cote gauche absentes du cote droit)

Exemples :

# Instances qui ont un CPU > 80% ET une memoire > 90%
(node_cpu_usage > 80) and (node_memory_usage > 90)

# Toutes les alertes sauf celles du job "test"
ALERTS{alertstate="firing"} unless ALERTS{job="test"}
```

### 4.4 Fonctions essentielles

#### Fonctions de taux (Rate)

```
rate(v range-vector) :
══════════════════════

  Calcule le taux moyen d'augmentation par seconde sur la fenetre.
  Gere automatiquement les resets de counter.

  Exemple :
  rate(http_requests_total[5m])
  → "Combien de requetes par seconde en moyenne sur 5 minutes"

  Si le counter est passe de 1000 a 1300 en 5 minutes :
  rate = (1300 - 1000) / 300 = 1 req/s

  REGLE D'OR : La fenetre du rate doit etre au moins
  4x le scrape_interval pour avoir assez de points.
  Avec scrape_interval=15s → rate(...[1m]) minimum.
  En pratique, utilise [5m] comme valeur par defaut.

irate(v range-vector) :
═══════════════════════

  Calcule le taux instantane en utilisant les 2 DERNIERS points
  du range vector. Plus reactif mais plus bruyant.

  Utilise irate() quand tu veux voir les pics instantanes.
  Utilise rate() quand tu veux une vue lissee.

  Exemple :
  irate(http_requests_total[5m])
  → Le [5m] ne sert qu'a trouver les 2 derniers points.
  → Le calcul utilise SEULEMENT les 2 derniers points.

increase(v range-vector) :
══════════════════════════

  Equivalent a rate() * duree_en_secondes.
  Donne l'augmentation totale sur la fenetre.

  Exemple :
  increase(http_requests_total[1h])
  → "Combien de requetes au total sur la derniere heure"

  Relation : increase(x[1h]) = rate(x[1h]) * 3600
```

```
Comparaison visuelle rate vs irate :
═════════════════════════════════════

  Valeur du counter :
  100 │  *
  105 │     *
  108 │        *
  150 │           *  ← pic soudain
  155 │              *
  158 │                 *
      └──────────────────────▶ Temps

  rate(counter[5m]) :
  ┌──────────────────────────┐
  │ ~~~~ ─── lisse ──── ~~~~ │  Moyenne sur 5 min
  └──────────────────────────┘

  irate(counter[5m]) :
  ┌──────────────────────────┐
  │ ___╱╲________╱╲_________ │  Pics visibles
  └──────────────────────────┘

  Utilise rate() pour les alertes (evite les faux positifs).
  Utilise irate() pour les dashboards temps reel.
```

#### Fonctions d'agregation

```
Fonctions d'agregation :
════════════════════════

  sum()        : somme
  avg()        : moyenne
  min()        : minimum
  max()        : maximum
  count()      : compte le nombre de series
  count_values(): compte les series par valeur distincte
  stddev()     : ecart type
  stdvar()     : variance
  topk(k, ...) : les k series avec les valeurs les plus elevees
  bottomk(k, ...): les k series avec les valeurs les plus basses
  quantile(q, ...): le quantile q (0 a 1)
  group()      : renvoie 1 pour chaque serie (utile pour le comptage)

  Toutes supportent les clauses BY et WITHOUT :

  # Somme par methode HTTP
  sum by (method) (rate(http_requests_total[5m]))

  # Equivalent : somme en excluant les labels instance et job
  sum without (instance, job) (rate(http_requests_total[5m]))

  Exemple concret :
  ─────────────────

  Donnees d'entree (instant vector) :
  rate(http_requests_total{job="api"}[5m])
    {method="GET",  instance="api-1:8080"} 25
    {method="GET",  instance="api-2:8080"} 30
    {method="POST", instance="api-1:8080"} 10
    {method="POST", instance="api-2:8080"} 15

  sum by (method) (rate(http_requests_total{job="api"}[5m]))
    {method="GET"}  55    (25 + 30)
    {method="POST"} 25    (10 + 15)

  sum without (instance) (rate(http_requests_total{job="api"}[5m]))
    {method="GET",  job="api"} 55
    {method="POST", job="api"} 25

  topk(1, rate(http_requests_total{job="api"}[5m]))
    {method="GET", instance="api-2:8080"} 30

  count by (method) (rate(http_requests_total{job="api"}[5m]))
    {method="GET"}  2    (2 series GET)
    {method="POST"} 2    (2 series POST)
```

#### Fonctions de prediction

```
predict_linear(v range-vector, t scalar) :
══════════════════════════════════════════

  Predit la valeur dans t secondes en utilisant une regression lineaire
  sur les donnees du range vector.

  Exemple : quand le disque sera-t-il plein ?

  # Espace disque disponible dans 24h (en extrapolant les 4 dernieres heures)
  predict_linear(node_filesystem_avail_bytes[4h], 24*3600)

  # ALERTE : le disque sera plein dans moins de 4 heures
  predict_linear(node_filesystem_avail_bytes[6h], 4*3600) < 0

  Representation :

  Espace
  disque
  100GB │ *
   80GB │    *
   60GB │       *
   40GB │          *
   20GB │             *
    0GB │ ─ ─ ─ ─ ─ ─ ─ * ─ ─ ─ ← predict_linear predit ici
  -20GB │                    *
        └──────────────────────────▶ Temps
         Donnees reelles   Prediction

deriv(v range-vector) :
═══════════════════════

  Calcule la derivee (pente) d'un gauge par seconde.
  Utilise la regression lineaire.

  # Vitesse de remplissage du disque (octets/seconde)
  deriv(node_filesystem_avail_bytes[1h])
  → Valeur negative = le disque se remplit
  → Valeur positive = le disque se libere
```

#### Fonctions pour histogrammes

```
histogram_quantile(q scalar, v instant-vector) :
════════════════════════════════════════════════

  Calcule le quantile q a partir des buckets d'un histogram.

  # Latence p50 (mediane)
  histogram_quantile(0.5,
    rate(http_request_duration_seconds_bucket[5m])
  )

  # Latence p95
  histogram_quantile(0.95,
    rate(http_request_duration_seconds_bucket[5m])
  )

  # Latence p99
  histogram_quantile(0.99,
    rate(http_request_duration_seconds_bucket[5m])
  )

  # Latence p99 par endpoint
  histogram_quantile(0.99,
    sum by (le, handler) (
      rate(http_request_duration_seconds_bucket[5m])
    )
  )

  ATTENTION : il faut TOUJOURS garder le label "le" dans l'agregation.
  Le label "le" est utilise par histogram_quantile pour reconstituer
  les buckets.

  Latence moyenne (sans histogram_quantile) :
  rate(http_request_duration_seconds_sum[5m])
  /
  rate(http_request_duration_seconds_count[5m])
```

#### Fonctions de temps

```
time() :
════════
  Renvoie le timestamp Unix courant (en secondes).

  # Depuis combien de temps le processus tourne (uptime)
  time() - process_start_time_seconds

  # Depuis combien de temps la derniere completion de backup
  time() - backup_last_success_timestamp_seconds

timestamp(v instant-vector) :
═════════════════════════════
  Renvoie le timestamp du dernier sample de chaque serie.

  # Detecter une target qui ne rapporte plus de donnees
  time() - timestamp(up) > 120
  → "La target n'a pas ete scrapee depuis plus de 2 minutes"
```

#### Fonctions over_time (sur une fenetre)

```
Fonctions *_over_time : appliquent une agregation sur un range vector.
══════════════════════

  avg_over_time(v[d])     : moyenne sur la fenetre d
  min_over_time(v[d])     : minimum sur la fenetre d
  max_over_time(v[d])     : maximum sur la fenetre d
  sum_over_time(v[d])     : somme sur la fenetre d
  count_over_time(v[d])   : nombre de samples sur la fenetre d
  stddev_over_time(v[d])  : ecart type sur la fenetre d
  quantile_over_time(q, v[d]) : quantile sur la fenetre d
  last_over_time(v[d])    : dernier sample sur la fenetre d

  Exemple :
  # Temperature moyenne sur les 30 dernieres minutes
  avg_over_time(temperature_celsius[30m])

  # Pic de CPU sur la derniere heure
  max_over_time(node_cpu_usage_percent[1h])

  # Nombre de scrapes reussies sur la derniere heure
  count_over_time(up{job="api"}[1h])
```

#### Fonctions absent

```
absent(v instant-vector) :
══════════════════════════

  Renvoie un vecteur vide si v a des resultats.
  Renvoie {label="valeur"} 1 si v est vide.

  Utilisation : alerter quand une metrique DISPARAIT.

  # Alerte si la metrique up du job "api" n'existe plus
  absent(up{job="api"})

  # Alerte si aucune requete n'est recue
  absent(http_requests_total{job="api"})

absent_over_time(v range-vector) :
══════════════════════════════════

  Comme absent mais sur une fenetre de temps.

  # Alerte si aucun sample recu sur les 5 dernieres minutes
  absent_over_time(up{job="api"}[5m])
```

#### Fonctions mathematiques et de tri

```
ceil(v)     : arrondi superieur
floor(v)    : arrondi inferieur
round(v, s) : arrondi au multiple de s le plus proche
abs(v)      : valeur absolue
clamp(v, min, max) : limite les valeurs entre min et max
clamp_min(v, min)  : plafond minimum
clamp_max(v, max)  : plafond maximum
ln(v)       : logarithme naturel
log2(v)     : logarithme base 2
log10(v)    : logarithme base 10
exp(v)      : exponentielle
sqrt(v)     : racine carree
sgn(v)      : signe (-1, 0, 1)

sort(v)     : trie par valeur croissante
sort_desc(v): trie par valeur decroissante
sort_by_label(v, label)     : trie par valeur de label
sort_by_label_desc(v, label): trie par valeur de label decroissante

Exemples :

# Memoire utilisee en GB, arrondie a 1 decimale
round(node_memory_MemTotal_bytes / (1024^3), 0.1)

# CPU usage entre 0 et 100
clamp(node_cpu_usage_percent, 0, 100)

# Top 5 des conteneurs par memoire, tries
sort_desc(topk(5, container_memory_usage_bytes))
```

### 4.5 Vector matching (jointures)

Le vector matching permet de combiner deux instant vectors, de maniere similaire aux JOIN en SQL. C'est un concept avance mais essentiel.

```
Vector matching : combiner deux vectors
═══════════════════════════════════════

  MATCHING ONE-TO-ONE (par defaut) :
  ──────────────────────────────────

  Chaque element du cote gauche est combine avec
  exactement UN element du cote droit qui a les memes labels.

  Exemple :
  methode_requetes_total{method="GET"}  100
  methode_requetes_total{method="POST"}  50

  methode_erreurs_total{method="GET"}    5
  methode_erreurs_total{method="POST"}   2

  # Taux d'erreur par methode
  methode_erreurs_total / methode_requetes_total

  Resultat :
  {method="GET"}  0.05  (5%)
  {method="POST"} 0.04  (4%)

  ────────────────────────────────────────────────

  MATCHING avec on() et ignoring() :
  ──────────────────────────────────

  on(label1, label2) : ne matcher QUE sur ces labels
  ignoring(label1)   : matcher sur TOUS les labels SAUF ceux-ci

  Exemple :
  # Les deux series ont des labels differents
  requests{method="GET", service="api"}    100
  errors{method="GET", service="api", code="500"}  5

  # Sans on(), pas de match (le label "code" n'existe que d'un cote)
  # Avec on() :
  errors / on(method, service) requests
  → {method="GET", service="api"} 0.05

  # Ou avec ignoring() :
  errors / ignoring(code) requests
  → {method="GET", service="api"} 0.05

  ────────────────────────────────────────────────

  MATCHING MANY-TO-ONE avec group_left() / group_right() :
  ────────────────────────────────────────────────────────

  Quand un cote a plus de series que l'autre (comme un LEFT JOIN).

  Exemple : ajouter le nom lisible d'un service a des metriques

  # Metriques de requetes (many)
  http_requests_total{instance="10.0.0.1:8080", method="GET"}   100
  http_requests_total{instance="10.0.0.1:8080", method="POST"}   50
  http_requests_total{instance="10.0.0.2:8080", method="GET"}    80

  # Table de correspondance (one)
  service_info{instance="10.0.0.1:8080", service_name="api-users"}  1
  service_info{instance="10.0.0.2:8080", service_name="api-orders"} 1

  # "Joindre" pour ajouter le label service_name
  http_requests_total
  * on(instance) group_left(service_name)
  service_info

  Resultat :
  {instance="10.0.0.1:8080", method="GET",  service_name="api-users"}  100
  {instance="10.0.0.1:8080", method="POST", service_name="api-users"}   50
  {instance="10.0.0.2:8080", method="GET",  service_name="api-orders"}  80

  Mnemonique :
  group_left  = le cote GAUCHE a PLUS de series (many-to-one)
  group_right = le cote DROIT a PLUS de series (one-to-many)
```

### 4.6 Subqueries

Les subqueries permettent d'executer une requete PromQL comme un range vector, avec sa propre resolution.

```
Syntaxe : <requete>[<range>:<resolution>]

Exemples :

# Calculer le max du rate sur 1h, en evaluant le rate toutes les 5min
max_over_time(rate(http_requests_total[5m])[1h:5m])

# Pic d'utilisation CPU sur 24h (echantillonne toutes les minutes)
max_over_time(
  (1 - rate(node_cpu_seconds_total{mode="idle"}[5m]))[24h:1m]
)

# Moyenne du taux d'erreur sur la derniere semaine,
# echantillonne toutes les 15 minutes
avg_over_time(
  (
    sum(rate(http_requests_total{status=~"5.."}[5m]))
    /
    sum(rate(http_requests_total[5m]))
  )[7d:15m]
)
```

### 4.7 Exemples pratiques progressifs

#### Niveau 1 : Requetes simples

```promql
# 1. Le processus Prometheus est-il up ?
up{job="prometheus"}

# 2. Memoire totale du serveur (en GB)
node_memory_MemTotal_bytes / (1024^3)

# 3. Nombre de CPUs
count without (cpu, mode) (node_cpu_seconds_total{mode="idle"})

# 4. Espace disque disponible (en GB) pour la partition racine
node_filesystem_avail_bytes{mountpoint="/"} / (1024^3)

# 5. Nombre de conteneurs Docker en cours d'execution
count(container_last_seen{name!=""}) by (instance)
```

#### Niveau 2 : Rate et agregation

```promql
# 6. Taux de requetes HTTP par seconde (global)
sum(rate(http_requests_total[5m]))

# 7. Taux de requetes par methode et par code de retour
sum by (method, status) (rate(http_requests_total[5m]))

# 8. Pourcentage d'utilisation CPU
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# 9. Debit reseau en Mbps
rate(node_network_receive_bytes_total{device="eth0"}[5m]) * 8 / 1000000

# 10. Taux d'erreur HTTP (%)
sum(rate(http_requests_total{status=~"5.."}[5m]))
/
sum(rate(http_requests_total[5m]))
* 100
```

#### Niveau 3 : Histogrammes et prediction

```promql
# 11. Latence p99 globale
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket[5m])) by (le)
)

# 12. Latence p95 par endpoint
histogram_quantile(0.95,
  sum by (le, handler) (rate(http_request_duration_seconds_bucket[5m]))
)

# 13. Latence moyenne
sum(rate(http_request_duration_seconds_sum[5m]))
/
sum(rate(http_request_duration_seconds_count[5m]))

# 14. Prediction : quand le disque sera plein
predict_linear(node_filesystem_avail_bytes{mountpoint="/"}[6h], 24*3600) / (1024^3)

# 15. Nombre de requetes sur la derniere heure
sum(increase(http_requests_total[1h]))
```

#### Niveau 4 : Requetes avancees

```promql
# 16. Ratio de cache hit
sum(rate(cache_hits_total[5m]))
/
(sum(rate(cache_hits_total[5m])) + sum(rate(cache_misses_total[5m])))

# 17. Top 5 des endpoints les plus lents (p99)
topk(5,
  histogram_quantile(0.99,
    sum by (le, handler) (rate(http_request_duration_seconds_bucket[5m]))
  )
)

# 18. Pods Kubernetes en CrashLoopBackOff
kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} > 0

# 19. Taux de saturation memoire (OOM kill imminents)
(
  container_memory_usage_bytes{container!=""}
  /
  container_spec_memory_limit_bytes{container!=""}
) > 0.9

# 20. Apdex score (Application Performance Index)
# Seuil satisfait : 0.3s, seuil tolerant : 1.2s
(
  sum(rate(http_request_duration_seconds_bucket{le="0.3"}[5m]))
  +
  sum(rate(http_request_duration_seconds_bucket{le="1.2"}[5m]))
)
/
(2 * sum(rate(http_request_duration_seconds_count[5m])))
```

#### Requetes utiles pour Docker

```promql
# Utilisation CPU par conteneur (%)
sum by (name) (rate(container_cpu_usage_seconds_total{name!=""}[5m])) * 100

# Memoire utilisee par conteneur (MB)
container_memory_usage_bytes{name!=""} / (1024^2)

# Trafic reseau entrant par conteneur (KB/s)
sum by (name) (rate(container_network_receive_bytes_total{name!=""}[5m])) / 1024

# Conteneurs qui consomment le plus de CPU
topk(5,
  sum by (name) (rate(container_cpu_usage_seconds_total{name!=""}[5m])) * 100
)

# Conteneurs redemarres recemment
changes(container_start_time_seconds{name!=""}[1h]) > 0

# Nombre de conteneurs par etat
count by (state) (container_last_seen{name!=""})
```

#### Requetes utiles pour Kubernetes

```promql
# Pods not ready
kube_pod_status_ready{condition="false"} == 1

# Deployments avec des replicas indisponibles
kube_deployment_status_replicas_unavailable > 0

# Utilisation CPU par namespace
sum by (namespace) (
  rate(container_cpu_usage_seconds_total{container!="", container!="POD"}[5m])
)

# Memoire par namespace (GB)
sum by (namespace) (
  container_memory_usage_bytes{container!="", container!="POD"}
) / (1024^3)

# Ratio requests CPU vs usage reel
sum by (namespace, pod) (rate(container_cpu_usage_seconds_total[5m]))
/
sum by (namespace, pod) (kube_pod_container_resource_requests{resource="cpu"})

# Pods en attente de scheduling depuis plus de 5 minutes
kube_pod_status_phase{phase="Pending"} == 1
and on(pod, namespace)
(time() - kube_pod_created > 300)

# PVC avec moins de 10% d'espace libre
kubelet_volume_stats_available_bytes
/
kubelet_volume_stats_capacity_bytes
< 0.10
```

### 4.8 Pieges courants et bonnes pratiques

```
Piege 1 : rate() sur un gauge
══════════════════════════════
  MAUVAIS : rate(node_memory_MemAvailable_bytes[5m])
  → rate() est pour les counters, pas les gauges !

  BON : Pour un gauge, utilise deriv() ou les valeurs directement.
  deriv(node_memory_MemAvailable_bytes[5m])

Piege 2 : Oublier rate() sur un counter dans un sum()
══════════════════════════════════════════════════════
  MAUVAIS : sum(http_requests_total)
  → La valeur brute d'un counter n'est pas utile pour les dashboards.

  BON : sum(rate(http_requests_total[5m]))
  → Le taux par seconde agrege.

Piege 3 : Fenetre de rate() trop petite
════════════════════════════════════════
  MAUVAIS : rate(http_requests_total[15s])
  → Si scrape_interval=15s, il y a seulement 1 sample dans la fenetre.
  → rate() a besoin d'au moins 2 samples.

  BON : rate(http_requests_total[1m]) ou mieux [5m]
  → Regle : fenetre >= 4 * scrape_interval

Piege 4 : avg() sur des rates
══════════════════════════════
  ATTENTION : avg(rate(http_requests_total[5m]))
  → La moyenne des taux n'est PAS le taux moyen.
  → Si instance A fait 100 req/s et instance B fait 0 req/s,
  → la moyenne est 50, mais le total est 100.

  BON (pour le debit total) : sum(rate(http_requests_total[5m]))
  BON (pour le debit moyen par instance) : avg(rate(http_requests_total[5m]))
  → Les deux sont valides, mais ont des significations differentes.

Piege 5 : histogram_quantile sans garder le label "le"
══════════════════════════════════════════════════════
  MAUVAIS :
  histogram_quantile(0.99,
    sum by (handler) (rate(http_request_duration_seconds_bucket[5m]))
  )
  → Le label "le" est perdu, histogram_quantile ne peut pas fonctionner.

  BON :
  histogram_quantile(0.99,
    sum by (le, handler) (rate(http_request_duration_seconds_bucket[5m]))
  )

Piege 6 : Confondre increase() et rate()
═════════════════════════════════════════
  increase(x[1h]) ≈ rate(x[1h]) * 3600
  → increase() donne le total sur la periode
  → rate() donne le taux par seconde
  → Les deux sont bases sur la meme extrapolation

Piege 7 : Utiliser {instance=~".*"} pour matcher tout
═════════════════════════════════════════════════════
  MAUVAIS : up{instance=~".*"}
  → Le regex ".*" matche aussi la chaine vide

  BON : up{instance=~".+"}
  → Le regex ".+" matche au moins 1 caractere
  → Ou plus simplement : up (sans filtre)
```

---
