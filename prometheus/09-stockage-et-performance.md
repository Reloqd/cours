## 9. Stockage et performance

### 9.1 Structure de la TSDB sur disque

```
Structure du repertoire data/ de Prometheus :
═════════════════════════════════════════════

  /prometheus/                       ← --storage.tsdb.path
  │
  ├── wal/                           ← Write-Ahead Log
  │   ├── 00000001                   ← Segment WAL (max 128MB)
  │   ├── 00000002
  │   ├── 00000003
  │   └── checkpoint.000002/         ← Checkpoint WAL
  │       └── 00000000
  │
  ├── chunks_head/                   ← Memory-mapped chunks du head block
  │   ├── 000001
  │   └── 000002
  │
  ├── 01JDXYZ.../                    ← Persistent block (ULID)
  │   ├── meta.json                  ← Metadata du block
  │   ├── index                      ← Index inverse (label → series)
  │   ├── chunks/                    ← Donnees compressees
  │   │   └── 000001
  │   └── tombstones                 ← Series supprimees
  │
  ├── 01JDXYZ.../                    ← Autre block
  │   ├── meta.json
  │   ├── index
  │   ├── chunks/
  │   │   └── 000001
  │   └── tombstones
  │
  ├── lock                           ← Verrou (un seul Prometheus a la fois)
  └── queries.active                 ← Requetes en cours
```

```
Cycle de vie des donnees :
══════════════════════════

  Temps ────────────────────────────────────────────────────────▶

  ┌─────────────────────────────────────────────────────────────┐
  │                                                             │
  │  WAL        Head Block        Block 1   Block 2   Block 3  │
  │  (disque)   (memoire+mmap)   (disque)  (disque)  (disque) │
  │                                                             │
  │  ┌──────┐  ┌──────────────┐  ┌──────┐  ┌──────┐  ┌──────┐│
  │  │ Ecrit│  │  ~2h de      │  │  2h  │  │  2h  │  │  8h  ││
  │  │ les  │──▶│  donnees     │──▶│      │  │      │  │      ││
  │  │ sam- │  │  recentes    │  │      │  │      │  │(apres ││
  │  │ ples │  │              │  │      │  │      │  │compac-││
  │  │      │  │              │  │      │  │      │  │tion)  ││
  │  └──────┘  └──────────────┘  └──────┘  └──────┘  └──────┘│
  │                                                             │
  │  ◀── Donnees les plus recentes    Donnees plus anciennes ──▶│
  │                                                             │
  └─────────────────────────────────────────────────────────────┘

  meta.json d'un block :
  {
    "ulid": "01JDXYZ...",
    "minTime": 1716580800000,      ← debut du block (ms)
    "maxTime": 1716588000000,      ← fin du block (ms)
    "stats": {
      "numSamples": 5432100,       ← nombre de samples
      "numSeries": 12345,          ← nombre de series
      "numChunks": 54321           ← nombre de chunks
    },
    "compaction": {
      "level": 2,                  ← niveau de compaction
      "sources": ["01JDX...", "01JDY..."]  ← blocks sources
    },
    "version": 1
  }
```

### 9.2 Compaction

```
La compaction fusionne les petits blocks en plus gros :
═══════════════════════════════════════════════════════

  Avant compaction (toutes les 2h, un nouveau block est cree) :

  ┌──────┐┌──────┐┌──────┐┌──────┐┌──────┐┌──────┐
  │  2h  ││  2h  ││  2h  ││  2h  ││  2h  ││  2h  │
  │  L1  ││  L1  ││  L1  ││  L1  ││  L1  ││  L1  │
  └──────┘└──────┘└──────┘└──────┘└──────┘└──────┘

  Apres compaction niveau 2 :

  ┌──────────────┐┌──────────────┐┌──────┐┌──────┐
  │     4-8h     ││     4-8h     ││  2h  ││  2h  │
  │     L2       ││     L2       ││  L1  ││  L1  │
  └──────────────┘└──────────────┘└──────┘└──────┘

  Apres compaction niveau 3 :

  ┌──────────────────────────────┐┌──────┐┌──────┐
  │           16-32h             ││  2h  ││  2h  │
  │            L3                ││  L1  ││  L1  │
  └──────────────────────────────┘└──────┘└──────┘

  Avantages de la compaction :
  - Meilleure performance en lecture (moins de fichiers a ouvrir)
  - Nettoyage des series supprimees (tombstones)
  - Deduplication des series
  - Meilleure compression globale
```

### 9.3 Retention

```bash
# Retention par duree (defaut : 15 jours)
--storage.tsdb.retention.time=30d

# Retention par taille (pas de defaut)
--storage.tsdb.retention.size=50GB

# Les deux peuvent etre combines.
# Le block le plus ancien est supprime quand L'UN DES DEUX est depasse.

# Duree minimum d'un block (defaut : 2h)
--storage.tsdb.min-block-duration=2h

# Duree maximum d'un block (defaut : duree retention / 10, max 36h)
--storage.tsdb.max-block-duration=36h
```

### 9.4 Calcul de l'espace disque necessaire

```
Formule approximative :
═══════════════════════

  Espace = nombre_series * samples_par_seconde * octets_par_sample * retention_secondes

  Ou :
  - nombre_series : prometheus_tsdb_head_series
  - samples_par_seconde : 1 / scrape_interval
  - octets_par_sample : ~1-2 octets (grace a la compression)
  - retention_secondes : retention en secondes

  Exemple concret pour ton homelab :
  ──────────────────────────────────
  - 10 000 series actives
  - scrape_interval = 15s → 1/15 samples/s/serie
  - ~1.5 octets par sample (apres compression)
  - retention = 30 jours = 2 592 000 secondes

  Espace ≈ 10 000 * (1/15) * 1.5 * 2 592 000
         ≈ 10 000 * 0.0667 * 1.5 * 2 592 000
         ≈ 2 592 000 000 octets
         ≈ 2.6 GB

  En pratique, ajouter ~30% pour l'overhead (WAL, index, meta).
  → ~3.4 GB pour 10K series, 15s interval, 30 jours.

  Avec 100 000 series :
  → ~34 GB

  Verifier l'espace utilise :
  prometheus_tsdb_storage_blocks_bytes    ← Taille des blocks
  prometheus_tsdb_wal_storage_size_bytes  ← Taille du WAL
```

### 9.5 Tuning memoire

```
Estimation de la RAM necessaire :
═════════════════════════════════

  La RAM est principalement consommee par :
  1. Le head block (~2h de donnees en memoire)
  2. L'index inverse (labels → series)
  3. Les requetes en cours

  Formule approximative :
  RAM ≈ nombre_series * 4-8 KB

  Exemples :
  - 10 000 series  → ~40-80 MB
  - 100 000 series → ~400-800 MB
  - 1 000 000 series → ~4-8 GB

  Metriques a surveiller :
  ─────────────────────────
  # Memoire du processus Prometheus
  process_resident_memory_bytes

  # Nombre de series dans le head block
  prometheus_tsdb_head_series

  # Nombre de chunks en memoire
  prometheus_tsdb_head_chunks

  # Memoire allouee par Go
  go_memstats_alloc_bytes

  Drapeaux de tuning :
  ────────────────────
  # Limite le nombre de samples qu'un scrape peut retourner
  --storage.tsdb.max-samples-per-scrape=50000

  # Active le memory mapping des chunks (reduit la RAM, utilise mmap)
  # Active par defaut depuis Prometheus 2.19
```

### 9.6 Cardinalite : comprendre, detecter, reduire

La cardinalite est le facteur numero 1 de performance de Prometheus. Trop de series temporelles = lenteur, OOM, crash.

```
Identifier la high cardinality :
════════════════════════════════

  # Top 10 des metriques par nombre de series
  topk(10, count by (__name__) ({__name__!=""}))

  # Nombre total de series actives
  prometheus_tsdb_head_series

  # Series creees par minute (churn)
  rate(prometheus_tsdb_head_series_created_total[5m])

  # Series supprimees par minute
  rate(prometheus_tsdb_head_series_removed_total[5m])

  # Alerter sur la cardinalite
  prometheus_tsdb_head_series > 500000

Via l'API :
  # Top 10 des metriques par cardinalite
  curl http://localhost:9090/api/v1/status/tsdb | jq '.data.seriesCountByMetricName[:10]'

  # Labels avec le plus de valeurs distinctes
  curl http://localhost:9090/api/v1/status/tsdb | jq '.data.labelValueCountByLabelName[:10]'

  # Paires label=valeur les plus frequentes
  curl http://localhost:9090/api/v1/status/tsdb | jq '.data.seriesCountByLabelValuePair[:10]'

Sources courantes de high cardinality :
═══════════════════════════════════════

  1. Labels a haute cardinalite
     BAD:  http_requests_total{user_id="..."}        ← millions de valeurs
     BAD:  http_requests_total{request_id="..."}      ← unique par requete
     BAD:  http_requests_total{url="/users/12345"}    ← parametriques
     GOOD: http_requests_total{endpoint="/users/:id"} ← normalise

  2. Histogrammes avec trop de buckets
     Un histogram avec 20 buckets et 5 labels = 20 * cardinalite
     Solution : native histograms (1 serie au lieu de 20)

  3. Metriques non utilisees
     Beaucoup d'exporters exposent des centaines de metriques.
     Solution : metric_relabel_configs pour drop les inutiles.

  4. Labels de metadata qui changent souvent
     BAD: labels contenant un hash de deploiement qui change a chaque deploy
     → Cree de nouvelles series a chaque deploy (churn)

Reduire la cardinalite :
════════════════════════

  # 1. Supprimer les metriques inutiles
  metric_relabel_configs:
    - source_labels: [__name__]
      regex: "go_gc_.*|go_memstats_.*|promhttp_.*"
      action: drop

  # 2. Supprimer les labels inutiles
  metric_relabel_configs:
    - regex: "pod_template_hash|controller_revision_hash"
      action: labeldrop

  # 3. Limiter le nombre de samples par scrape
  --storage.tsdb.max-samples-per-scrape=50000

  # 4. Utiliser les native histograms (Prometheus v3)
  --enable-feature=native-histograms
```

### 9.7 Debugging des requetes lentes

```
Identifier les requetes lentes :
════════════════════════════════

  # Metriques de l'API PromQL
  # Duree des requetes
  histogram_quantile(0.99,
    rate(prometheus_engine_query_duration_seconds_bucket[5m])
  )

  # Nombre de series examinees par requete
  prometheus_engine_query_samples_total

  # Requetes en cours
  prometheus_engine_queries

  # Via les logs (avec --log.level=debug)
  # Les requetes de plus de X secondes sont loguees

Optimisations :
══════════════

  1. Utiliser des recording rules pour les requetes complexes
     → Pre-calculer une fois, lire le resultat rapidement

  2. Reduire le range des range vectors
     BAD:  rate(http_requests_total[1h])     sur 100K series
     BETTER: rate(http_requests_total[5m])   sur 100K series

  3. Ajouter des filtres de labels
     BAD:  rate(http_requests_total[5m])                    ← toutes les series
     GOOD: rate(http_requests_total{job="api"}[5m])          ← filtre

  4. Eviter les regex couteux
     BAD:  {__name__=~".*"}
     GOOD: {__name__=~"http_.*"}

  5. Utiliser topk() plutot que sort_desc()
     BAD:  sort_desc(rate(http_requests_total[5m]))          ← trie tout
     GOOD: topk(10, rate(http_requests_total[5m]))           ← ne garde que 10
```

---
