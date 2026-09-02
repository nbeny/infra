# Refonte de l'observabilité UrbanLink — dashboards, alertes, plomberie

> 2026-09-02 · dépôts `infra` et `UrbanConnct`

Huit tableaux de bord maigres, douze alertes dont **six ne peuvent pas tirer**, et une
chaîne de traces qui n'a jamais transporté un seul span. Ce document décrit ce qui a
été mesuré, ce qui est refait, et la porte qui empêchera la situation de se reformer.

---

## 1. L'audit — mesuré, pas déduit

Toutes les observations ci-dessous viennent d'interrogations du **Prometheus réel du
cluster** (`10.0.0.111:30080`, en-tête `Host: prometheus.urbanlink.fr`, depuis le nœud
Proxmox), le 2026-09-02. Aucune n'est tirée de la lecture des fichiers.

État de départ sain par ailleurs : **toutes les cibles `up`**, 80 632 séries en tête,
16 cœurs, charge 5 min à 2,16, RAM à 17 %, disque `/` à 34,6 %. Une seule alerte
active : `Watchdog`, qui tire par conception.

### 1.1 Les compteurs du backend sont faux

Le job `urbanconnect-backend` scrape `backend.urbanconnect.svc.cluster.local:4000` —
un **ClusterIP** — alors que le Deployment `backend` a **2 replicas**. Prometheus
atteint donc un pod tiré au sort à chaque scrape. Relevé sur `/graphql` `200`, pas de
30 s :

```
2531 → 2511 → 2535 → 2514 → 2541 → 2532 → 2581 → 2604 → 2605 → 2567 → 2606 → 2569 …
```

Une seule série, deux pods derrière. Chaque descente est lue par PromQL comme une
**remise à zéro de compteur**, et `rate()` ajoute alors la valeur entière au lieu de la
différence. Conséquence : le débit de requêtes, le taux d'erreur 5xx, le débit Kafka,
les requêtes Prisma — **tout ce qui dérive d'un compteur `urbanconnect_*` est gonflé**,
sur les tableaux de bord comme dans l'alerte `BackendHighErrorRate`.

L'ancien `prometheus.yml` standalone utilisait `dns_sd_configs` sur un Service headless
précisément pour éviter cela ; la migration vers `kube-prometheus-stack`, qui a remplacé
ce fichier par des `additionalScrapeConfigs`, a perdu la précaution sans que rien ne le
signale.

### 1.2 Zéro trace, zéro journal, depuis toujours

```
tempo_distributor_spans_received_total    → série absente
loki_distributor_lines_received_total     → série absente
```

Le Deployment `backend` ne porte **pas** `OTEL_EXPORTER_OTLP_ENDPOINT`, et
`backTs/src/common/observability/tracing.ts` ne démarre rien sans cette variable. Tempo
et Loki tournent, sont scrapés, sont sains — et n'ont jamais rien reçu.

C'est aussi l'explication du point suivant : le collecteur OTel n'expose que **trois**
métriques `otelcol_*` (`exporter_queue_size`, `exporter_queue_capacity`,
`processor_batch_metadata_cardinality`). Les compteurs de spans reçus et exportés
n'existent pas parce que le SDK OpenTelemetry-Go **n'instancie un instrument qu'au
premier enregistrement**. Rien n'a jamais transité, donc rien n'a jamais été créé.

### 1.3 Huit métriques citées par les dashboards ou les alertes n'existent nulle part

| Métrique citée | Citée par | Effet réel |
|---|---|---|
| `urbanconnect_seller_payouts_pending` | dashboard 08 | « No data » permanent |
| `otelcol_receiver_otlp_spans_received_total` | dashboards 04, 06 | panneaux vides |
| `otelcol_exporter_otlp_sent_spans_total` | dashboard 06 | panneau vide |
| `otelcol_exporter_send_failed_spans_total` | **alerte `OTelCollectorDrops`** | ne tirera jamais |
| `otelcol_process_resident_memory_bytes` | dashboard 06 | panneau vide |
| `kube_pod_container_status_restarting_total` | dashboard 01 | panneau vide |
| `kube_deployment_status_ready_replicas` | dash. 07, **alerte `DeploymentReplicasMismatch`** | l'expression rend **0 série**, toujours |
| `kubelet_volume_stats_used_bytes` / `_capacity_bytes` | dash. 01, **alerte `PVCNearFull`** | ne tirera jamais |

Les deux dernières lignes méritent leur explication.

**`kube_deployment_status_ready_replicas` n'existe pas** : kube-state-metrics expose
`kube_deployment_status_replicas_ready` — les deux derniers mots sont inversés. Un `!=`
dont le membre droit est un vecteur vide ne rend aucune série : l'alerte est muette
depuis sa création. Vérifié, l'expression actuelle rend `0 series`.

**`kubelet_volume_stats_*` est absent de ce cluster**, et cela ne se corrige pas : les
12 PVC utilisent tous la StorageClass `local-path`, dont les volumes sont des chemins
de l'hôte. Le kubelet ne produit pas de statistiques de remplissage pour ceux-là. Il
n'existe donc **aucune mesure d'occupation par PVC**, et il ne peut pas en exister sans
changer de provisionneur.

Le fait utile est ailleurs : **les 12 PVC partagent `/dev/sda1`**, le seul système de
fichiers du nœud unique. Surveiller « le PVC de Postgres » n'a pas de sens ici ;
surveiller `/` en a un, et le couvre entièrement.

### 1.4 Le backend est invisible dans le maillage — et c'est normal

`istio_requests_total` ne porte **aucune** série pour `destination_workload="backend"`.
Le backend n'apparaît que dans `istio_tcp_connections_*`.

Ce n'est pas une panne : le mesh tourne en **mode ambient**, où ztunnel n'assure que le
L4. Les métriques HTTP (`istio_requests_total`, `istio_request_duration_milliseconds`)
ne sont produites que par un proxy L7 — ici l'`istio-ingressgateway` seul, qui rapporte
en `reporter="source"`.

Le dashboard `03-istio-mesh` actuel interroge le L7 filtré sur
`destination_workload_namespace != "istio-system"` : il ne montrera jamais autre chose
que le frontend. Un dashboard de mesh honnête sur ce cluster doit **séparer les deux
plans** : L7 au bord, L4 à l'intérieur.

### 1.5 Défauts de fabrication des huit tableaux de bord

- **Aucun `gridPos`** sur aucun panneau : Grafana empile ce qu'il veut.
- **`unit` écrit dans `targets`** au lieu de `fieldConfig.defaults` : le taux d'erreur
  5xx s'affiche `0.0123` au lieu de `1,23 %`.
- **Aucun seuil, aucune variable, aucun lien** entre les pages.
- `count(ALERTS{alertstate="firing"})` compte le `Watchdog` : la « santé globale » ne
  descend jamais à zéro, et n'a donc pas d'état sain.
- Le panneau « Node.js heap » du dashboard backend trace `process_resident_memory_bytes`
  — 16 séries, qui appartiennent à Loki, Tempo et Grafana. Le backend, lui, préfixe tout
  en `urbanconnect_process_*`. Le panneau montre la mémoire de quelqu'un d'autre.

### 1.6 Une source de vérité en double

La datasource « Prometheus (mesh Istio) » pointe sur
`prometheus.istio-system.svc.cluster.local:9090`, devenu un `ExternalName` vers le
Prometheus unique par le commit `af9cc10`. Deux noms, deux entrées dans Grafana, **un
seul serveur**.

---

## 2. Ce qui est fait

### A. Plomberie

| # | Changement | Fichier | Raison |
|---|---|---|---|
| **A1** | Quatre `ServiceMonitor` (backend, otel-collector, tempo, loki) remplacent les `additionalScrapeConfigs` | `kube/urbanlink/observability/servicemonitors.yaml` + template Helm | Un `ServiceMonitor` découvre les **Endpoints**, donc **un pod = une cible**. Les compteurs cessent de rebondir (§1.1). |
| **A2** | `OTEL_EXPORTER_OTLP_ENDPOINT` + `OTEL_SERVICE_NAME` sur `backend` et `temporal-worker` ; `import '../tracing'` en tête de `worker-nest.main.ts` | 2 Deployments + 1 fichier applicatif | Réveille Tempo et Loki (§1.2). |
| **A3** | Suppression de la datasource « Prometheus (mesh Istio) » | `grafana-datasources.yaml` (les deux dépôts) | Doublon (§1.6). |

Notes sur A1 :

- Le jeton du backend passe par `authorization.credentials` — une référence au Secret
  `urbanconnect-secrets`, clé `METRICS_TOKEN` — et non plus par un `credentials_file`
  dont le chemin devait être deviné. L'opérateur résout la référence lui-même en
  écrivant la configuration. Le Secret doit vivre dans le **même namespace que le
  ServiceMonitor** : les deux sont dans `urbanconnect`, la condition est remplie.
  `prometheusSpec.secrets: [urbanconnect-secrets]` est **conservé** dans les valeurs
  Helm : il ne sert plus au scrape, mais le retirer changerait le volume monté dans le
  pod pour un gain nul.
- Le job `kubernetes-pods` (découverte par annotation `prometheus.io/scrape`) est
  **conservé tel quel**. C'est lui qui alimente Kiali et le plan L7 du mesh ; le
  remplacer par des ServiceMonitor casserait le graphe de Kiali.
- Les ServiceMonitor portent `release: kube-prometheus-stack`, le `serviceMonitorSelector`
  par défaut du chart. Sans ce label, l'objet est créé, Argo l'affiche « Synced », et
  Prometheus l'ignore — le même silence que celui décrit dans `prometheus-alias.yaml`.

Notes sur A2 :

- C'est un changement de comportement du **backend**, pas seulement de la supervision.
  L'échantillonnage à 20 % et le masquage des en-têtes `authorization`, `cookie` et
  `set-cookie` sont déjà configurés dans `otel-collector-config.yaml` et s'appliquent dès
  le premier span.
- **Le `frontend` ne reçoit rien**, et c'est délibéré : il n'a **aucune** instrumentation
  OpenTelemetry (ni `instrumentation.ts`, ni dépendance `@opentelemetry/*`). Y poser la
  variable écrirait une clé que personne ne lit — la définition même du réglage décoratif
  que cette refonte élimine. Instrumenter Next.js est un chantier distinct, noté au §4.
- **Le worker demandait une ligne de code en plus.** `worker-nest.main.ts` n'importait pas
  `tracing` : la variable seule n'y aurait rien produit. L'import est placé en **toute
  première ligne**, avant `AppModule`, pour la raison écrite dans `main.ts` — les
  instrumentations remplacent les méthodes de `pg`, `ioredis` et `kafkajs` au moment du
  `require`, et n'attrapent plus rien si le module est déjà chargé.
  ⚠️ Le chemin est `../tracing` et non `../common/observability/tracing` : le second ne
  fait que **définir** `startTracing()`. C'est `src/tracing.ts` qui l'appelle.
  Le vidage des tampons à l'arrêt est déjà couvert : le worker `await app.close()`, ce qui
  déclenche `TracingShutdownService.onApplicationShutdown`.

### B. Cinq tableaux de bord

Les huit anciens sont supprimés. Chaque panneau des nouveaux porte `gridPos`, unité,
seuils et légende ; les pages sont reliées entre elles.

| uid | Titre | Ce qu'on y répond |
|---|---|---|
| `urbanlink-overview` | **00 — Vue d'ensemble** | « Est-ce que ça va ? » en six chiffres, puis où regarder ensuite. |
| `urbanlink-backend` | **01 — Backend UrbanConnect** | « L'API est lente / en erreur — pourquoi ? » |
| `urbanlink-platform` | **02 — Plateforme (nœud + Kubernetes)** | « Est-ce que la machine tient ? » |
| `urbanlink-mesh` | **03 — Maillage Istio & bord** | « Le trafic entre-t-il, et arrive-t-il à destination ? » |
| `urbanlink-observability` | **04 — Chaîne d'observabilité** | « Est-ce que les quatre pages précédentes disent vrai ? » |

Points notables :

- **00** exclut `Watchdog` du décompte d'alertes, affiche la **santé de la chaîne de
  télémétrie** (spans/s et lignes/s : à zéro, le pipeline est muet) et porte la barre de
  liens vers Kiali, Alertmanager, Prometheus, Argo CD, Temporal et Kibana.
- **01** exploite enfin `urbanconnect_graphql_operation_duration_seconds_bucket` (49
  opérations distinctes, jamais affichées) en deux tables : les plus lentes, les plus en
  erreur. Il ajoute le runtime Node qui manquait entièrement — **event-loop lag
  p50/p90/p99**, heap utilisé vs total, GC par type, descripteurs de fichiers.
- **02** ajoute le **nœud**, totalement absent des huit anciens alors que node-exporter
  tourne depuis le début : CPU par mode, mémoire, disque `/` avec `predict_linear`,
  I/O, réseau `eth0`. Côté Kubernetes, la consommation par pod est rapportée **aux
  requests et aux limits**, et une table liste les conteneurs sans limite.
- **03** sépare **bord (L7)** et **interne (L4)**, comme l'impose le mode ambient (§1.4).
  Il porte la table des `response_flags` — `UF`, `UO`, `NR`, `UH` — qui est la seule
  façon de distinguer un 503 « le service a répondu 503 » d'un 503 « personne n'a
  répondu ». Aujourd'hui seuls `-` et `DC` sont observés ; la table vide est la bonne
  nouvelle.
- **04** est la page qui garde les autres honnêtes : durée de scrape par job,
  échantillons rejetés, cibles DOWN, et surtout
  **`prometheus_rule_evaluation_failures_total`** — la métrique qui aurait signalé, dès
  le premier jour, l'appariement `on(pod)` cassé décrit dans l'en-tête de
  `prometheus-alerts.yaml`.

### C. Alertes

Sept groupes. **Chaque règle est adossée à une métrique dont la présence a été vérifiée
sur le cluster**, et chaque seuil est posé au regard de la ligne de base mesurée.

| Groupe | Règles |
|---|---|
| `urbanlink.meta` *(nouveau)* | `PrometheusTargetDown`, `PrometheusRuleFailures`, `AlertmanagerNotificationsFailing`, `PrometheusTSDBGrowth` |
| `urbanlink.availability` | `PodCrashLooping`, `PodNotReady`, `DeploymentReplicasMismatch` *(nom de métrique corrigé)*, `NodeNotReady`, `BackendNoReplicas` |
| `urbanlink.resources` | `HighCPUUsage`, `HighMemoryUsage`, `OOMKillDetected`, `NodeDiskFillingUp`, `NodeDiskAlmostFull`, `NodeMemoryPressure`, `NodeHighLoad` |
| `urbanlink.backend` | `BackendDown`, `BackendHighErrorRate`, `BackendHighLatency`, `GraphQLErrorRatio`, `BackendEventLoopBlocked`, `BackendHeapNearLimit`, `BackendFileDescriptorsHigh` |
| `urbanlink.kafka` | `KafkaDLQMessages`, `OutboxPoisoned`, `OutboxBacklogGrowing` |
| `urbanlink.mesh` *(nouveau)* | `IngressHighErrorRate`, `IngressUpstreamFailures`, `MeshTCPConnectionFailures`, `IstioCertNotRotating` |
| `urbanlink.telemetry` *(remplace `urbanlink.otel`)* | `TelemetryPipelineSilent`, `LogPipelineSilent`, `OTelQueueNearFull`, `TempoFlushFailing`, `LokiChunkFlushFailing` |

Décisions qui ne se devinent pas :

- **`OTelCollectorDrops` est supprimée.** Sa métrique n'existe pas et ne peut pas
  exister tant que rien ne transite (§1.2). Une alerte qui ne peut pas tirer est pire
  qu'une alerte absente : elle donne l'illusion d'une surveillance.
- **`PVCNearFull` est supprimée**, remplacée par `NodeDiskFillingUp` et
  `NodeDiskAlmostFull` sur `/`. Il n'existe pas de mesure par PVC sur ce cluster, et les
  12 PVC vivent de toute façon sur ce système de fichiers-là (§1.3).
- **`GraphQLErrorsSpike` devient `GraphQLErrorRatio`.** Le seuil absolu `> 5 erreurs/s`
  ne tirerait jamais sur un trafic mesuré à moins d'une requête par seconde. Un ratio
  (`> 5 %` pendant 10 min) reste vrai quel que soit le volume.
- **`IstioCertExpiringSoon` devient `IstioCertNotRotating`, seuil à 1 heure.** Les
  certificats de charge de travail Istio ont une durée de vie de 24 h et sont
  renouvelés à mi-parcours ; la valeur relevée est de **76 385 s ≈ 21 h**. Un seuil à
  sept jours, réflexe habituel pour un certificat public, tirerait **en permanence**.
  Sous une heure restante, en revanche, la rotation a réellement échoué.
- **`TelemetryPipelineSilent` et `LogPipelineSilent` s'écrivent
  `… == 0 or absent(…)`.** Sans le `or absent()`, une métrique jamais instanciée rend un
  vecteur vide, la comparaison ne produit aucune série, et l'alerte ne tire pas. C'est
  exactement le mécanisme qui a laissé la chaîne OTel morte pendant des semaines sans un
  mot (§1.2). Ces deux règles sont écrites pour être **vraies avant que la métrique
  n'existe**.

### Alertmanager

Les alertes ne sortent pas du cluster : `GRAFANA_SMTP_*` est vide dans `secrets.env` et
c'est un choix assumé. Le travail porte donc sur la **lisibilité de la page**.

- `group_by: [alertname, namespace, severity]` — un incident, une ligne.
- **`inhibit_rules`**, qui manquaient entièrement :
  - `NodeNotReady` éteint tout le reste. Sur un cluster mono-nœud, la chute du nœud
    déclenche sinon trente alertes qui disent la même chose.
  - `BackendDown` éteint `BackendHighErrorRate` et `BackendHighLatency` : un backend
    arrêté n'a pas un problème de latence.
  - Une alerte `critical` éteint la `warning` de même `alertname` sur le même pod.
- Le récepteur `ops` reste préparé dans le template Helm : renseigner
  `GRAFANA_SMTP_SMARTHOST`, `_USERNAME` et `_PASSWORD` suffira à ouvrir la sortie, sans
  toucher au routage.

### D. La porte de vérification

`scripts/observability/check-queries.py` extrait **chaque expression PromQL** des cinq
tableaux de bord (panneaux *et* variables) et de la `PrometheusRule` — 151 au total — puis
l'exécute contre le Prometheus du cluster. Quatre verdicts :

| verdict | signification | bloquant |
|---|---|---|
| `OK` | au moins une série | — |
| `ERREUR` | PromQL refuse l'expression | **oui** |
| `FANTÔME` | une métrique citée n'existe pas | **oui** |
| `APPARIEMENT` | toutes les métriques existent, mais le calcul rend un vecteur vide **même sans son seuil** | **oui** |
| `VIDE` | métriques présentes, seuil non atteint — l'état sain | seulement si non justifié |

Le verdict est **mécanique**, pas déclaratif : le script extrait les noms de métriques de
l'expression et interroge chacun. C'est cette mécanique qui distingue « le seuil ne
sélectionne rien » de « le calcul est cassé », et elle ne se contourne pas.

**La première version du script ne savait pas les distinguer, et s'est fait prendre.** Elle
cherchait des fragments d'expression dans une liste écrite à la main — dont des seuils nus
(`> 0.8`). `OTelQueueNearFull`, dont l'expression est vide en permanence, y était classée
« aucune ressource au-delà de 80 % » : **la porte justifiait elle-même le défaut qu'elle
était censée trouver**. C'est ce qui a motivé la règle mécanique.

### Ce que la porte a effectivement trouvé

Trois défauts, tous dans du code que j'allais livrer, aucun visible à la lecture :

| trouvé | nature |
|---|---|
| tuile « Taux d'erreur 5xx » (dashboards 00, 01, 03) | numérateur vide quand il n'y a aucun 5xx ⇒ « No data » au lieu de `0 %`. Corrigé par `or vector(0)` sur le numérateur — **seulement sur les panneaux** : pour l'alerte, un vide sans 5xx est le comportement correct |
| **`OTelQueueNearFull`** (héritée de l'ancien fichier) | `queue_size` porte une étiquette `data_type` que `queue_capacity` n'a pas ⇒ aucun appariement, alerte muette depuis toujours. Corrigé par `on(exporter) group_left()` |
| **`NodeHighLoad`** (que je venais d'écrire) | `node_load5` porte sept étiquettes, `count(count by (cpu) (…))` aucune ⇒ aucun appariement. Mesuré : 0 série sans `scalar()`, 0,085 par cœur avec. Corrigé par `scalar()` |

Cela porte le bilan à **huit métriques fantômes** (§1.3) **et deux appariements morts**.

### La porte a été vue au rouge

Une porte qu'on n'a jamais vue échouer ne prouve rien. Quatre défauts ont été injectés
délibérément dans la `PrometheusRule`, puis retirés :

```
✖ FANTOME      DeploymentReplicasMismatch  metrique inexistante : kube_deployment_status_ready_replicas
✖ APPARIEMENT  NodeHighLoad                le calcul rend un vecteur vide MEME SANS SON SEUIL
✖ ERREUR       OutboxPoisoned              parse error: binary expression must contain only scalar…
✖ APPARIEMENT  OTelQueueNearFull           le calcul rend un vecteur vide MEME SANS SON SEUIL
⚠️  NE PAS DEPLOYER EN L'ETAT.
```

Fichier restauré, la porte repasse au vert : **151 expressions · 116 OK · 35 vides
justifiés · 0 erreur · 0 fantôme · 0 vide non justifié**.

---

## 3. Où vivent les fichiers

| Quoi | Dépôt |
|---|---|
| Tableaux de bord, datasources | **UrbanConnct** `config/prod/observability/` — miroir CI vers `infra/kube/urbanlink/config/` |
| Liste du `configMapGenerator` | **infra** `kube/urbanlink/kustomization.yaml` |
| ServiceMonitors, `PrometheusRule` | **infra** `kube/urbanlink/observability/` |
| Valeurs Helm (scrape, Alertmanager) | **infra** `ansible/roles/kubernetes/templates/kube-prometheus-stack-values.yaml.j2` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | **infra** `kube/urbanlink/{backend,frontend,temporal-worker}/deployment.yaml` |
| Script de vérification | **infra** `scripts/observability/` |

⚠️ Un push sur `main` du dépôt applicatif **redéploie la production**. Tout est livré sur
branche ; la mise en service est une décision distincte.

## 4. Ce qui reste ouvert

- **Aucun exporter pour les banques de données.** Ni Postgres, ni Redis, ni Kafka, ni
  Elasticsearch n'exposent de métriques à ce Prometheus. Aucune règle ne peut donc
  parler de connexions saturées, de retard de consommateur Kafka ou de santé de shard.
  C'est un chantier distinct — trois exporters à déployer — délibérément hors de cette
  refonte.
- **Le plan de contrôle reste non scrapable** (`etcd`, `controller-manager`,
  `scheduler`, `kube-proxy` n'écoutent que sur la boucle locale). Inchangé, et documenté
  dans le template Helm.
- **Pas de sonde d'expiration du certificat public** `*.urbanlink.fr` : il est renouvelé
  par certbot sur le nœud Proxmox, hors de portée de ce Prometheus. Il faudrait un
  blackbox exporter ; noté, non fait.
- **Le frontend n'est pas instrumenté.** Aucune trace ne couvre le rendu Next.js, donc une
  trace s'arrête au bord : on voit le temps passé dans l'API, jamais celui passé à
  composer la page. Instrumenter demande un `instrumentation.ts` et les paquets
  `@opentelemetry/*` côté `front/` — un chantier distinct.
- **Aucune mesure d'occupation par PVC**, et il ne peut pas y en avoir avec `local-path`
  (§1.3). Le remède réel serait un provisionneur qui expose des statistiques de volume, pas
  une règle de plus.
