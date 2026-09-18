#!/usr/bin/env python3
# ============================================================================
#  La porte de verification des requetes d'observabilite
# ----------------------------------------------------------------------------
#  Extrait CHAQUE expression PromQL des tableaux de bord Grafana et de la
#  PrometheusRule, l'execute contre le Prometheus reel du cluster, et refuse de
#  laisser passer ce qui ne peut pas fonctionner.
#
#  ─────────────────────────────────────────────────────────────────────────
#  POURQUOI CE SCRIPT EXISTE
#  ─────────────────────────────────────────────────────────────────────────
#  Un nom de metrique inexistant ne leve AUCUNE erreur en PromQL : l'expression
#  rend un vecteur vide. Un panneau affiche alors « No data » -- indiscernable
#  d'un systeme au repos -- et une alerte ne part simplement JAMAIS.
#
#  Huit metriques citees par les anciens tableaux de bord et alertes n'ont
#  jamais existe sur ce cluster (releve le 2026-09-02) :
#
#    urbanconnect_seller_payouts_pending          panneau vide
#    otelcol_receiver_otlp_spans_received_total   panneau vide
#    otelcol_exporter_otlp_sent_spans_total       panneau vide
#    otelcol_exporter_send_failed_spans_total     alerte muette
#    otelcol_process_resident_memory_bytes        panneau vide
#    kube_pod_container_status_restarting_total   panneau vide
#    kube_deployment_status_ready_replicas        alerte muette
#    kubelet_volume_stats_used_bytes              alerte muette
#
#  Aucune n'aurait survecu a une seule execution de ce script.
#
#  ⚠️ CE SCRIPT INTERROGE LA PRODUCTION, en lecture seule. Il n'ecrit rien, ne
#  modifie rien, et ne lit aucun secret.
#
#  ─────────────────────────────────────────────────────────────────────────
#  USAGE
#  ─────────────────────────────────────────────────────────────────────────
#    # Depuis le noeud Proxmox, qui atteint la passerelle du cluster :
#    python3 scripts/observability/check-queries.py
#
#    # Depuis un poste, par un tunnel SSH :
#    ssh -f -N -L 19090:10.0.0.111:30080 root@192.168.100.50
#    PROM_URL=http://127.0.0.1:19090 python3 scripts/observability/check-queries.py
#
#    # Ne verifier qu'un fichier, ou tout voir :
#    python3 scripts/observability/check-queries.py --only 01-backend
#    python3 scripts/observability/check-queries.py --verbose
#
#  Code de sortie 0 si tout est vert, 1 sinon -- utilisable en porte de CI.
#
#  ─────────────────────────────────────────────────────────────────────────
#  PORTE REVUE AU ROUGE LE 2026-09-18
#  ─────────────────────────────────────────────────────────────────────────
#  Une porte qu'''on n'''a jamais vue refuser ne prouve rien. Deux defauts ont
#  donc ete injectes dans 00-overview.json, puis retires :
#
#    ZZ metrique fantome    sum(urbanconnect_nexistepas_total)
#                           -> refuse en FANTOME
#    ZZ appariement casse   kube_deployment_status_replicas_ready{...}
#                             / count(up{job="urbanconnect-backend"} == 1)
#                           -> refuse en VIDE
#
#  Le second est le piege n°2 de prometheus-alerts.yaml : les DEUX metriques
#  existent, l'''expression se lit parfaitement, et l'''appariement ne trouve
#  aucune paire parce que le denominateur ne porte aucune etiquette. Remede :
#  scalar().
#
#  Les deux ont ete nommes PAR LEUR TITRE DE PANNEAU, pas par un fragment
#  d'''expression -- c'''est cette confusion qui avait fait justifier a la
#  premiere version de ce script le defaut qu'''il devait trouver.
#
#  ⚠️ Sans dependance : `urllib` et `pyyaml` (deja requis par Ansible). Le
#  depot infra n'a pas de package.json, et ce script ne doit pas en imposer un.
# ============================================================================

import argparse
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import yaml

# La console Windows par defaut est en cp1252 et ne sait pas ecrire « ✔ ». Sans
# cette ligne le script MEURT sur son propre rapport, au premier symbole -- et
# l'erreur ressemble a un defaut de la verification, pas de son affichage.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

RACINE = Path(__file__).resolve().parents[2]
DASHBOARDS = RACINE / "kube/urbanlink/config/prod/observability/grafana-dashboards"
REGLES = RACINE / "kube/urbanlink/observability/prometheus-alerts.yaml"

# Par defaut on passe par la passerelle Istio en NodePort, avec l'en-tete Host
# qui aiguille le VirtualService -- ce qui evite l'authentification basique du
# bord sans la contourner : le port n'est joignable que depuis le reseau du lab.
PROM_URL = os.environ.get("PROM_URL", "http://10.0.0.111:30080")
PROM_HOST = os.environ.get("PROM_HOST", "prometheus.urbanlink.fr")
TIMEOUT = int(os.environ.get("PROM_TIMEOUT", "30"))


# ---------------------------------------------------------------------------
#  Comment un VIDE est juge
# ---------------------------------------------------------------------------
#  Une expression qui ne rend aucune serie a DEUX causes possibles, et elles
#  n'ont rien a voir :
#
#    (a) toutes les metriques citees existent, mais le filtre ou le seuil ne
#        selectionne rien. C'est l'etat SAIN d'une alerte -- personne n'a ete
#        tue faute de memoire, aucune cible n'est muette. Legitime.
#
#    (b) une metrique citee N'EXISTE PAS, ou un appariement vectoriel echoue.
#        Le panneau ment et l'alerte est morte. Toujours un defaut.
#
#  ⚠️ LA PREMIERE VERSION DE CE SCRIPT NE SAVAIT PAS LES DISTINGUER, et s'est
#  fait prendre. Elle cherchait des fragments d'expression dans une liste
#  ecrite a la main, dont des seuils nus (« > 0.8 »). Resultat mesure le
#  2026-09-02 : l'alerte OTelQueueNearFull, dont l'expression
#  `otelcol_exporter_queue_size / otelcol_exporter_queue_capacity` rend
#  TOUJOURS un vecteur vide -- `queue_size` porte une etiquette `data_type`
#  que `queue_capacity` n'a pas, donc aucune paire ne correspond -- etait
#  classee « aucune ressource au-dela de 80 % ». La porte justifiait
#  elle-meme le defaut qu'elle etait censee trouver.
#
#  D'ou la regle ci-dessous, mecanique plutot que declarative :
#
#    1. extraire les noms de metriques cites par l'expression ;
#    2. verifier chacun avec `count(<metrique>)` ;
#    3. une metrique absente  -> ERREUR, bloquant, sans exception possible ;
#    4. toutes presentes      -> VIDE, qui exige une justification NOMMEE
#                                ci-dessous. Toutes les metriques peuvent
#                                exister et l'expression rester vide pour une
#                                mauvaise raison (l'appariement d'OTel) :
#                                c'est a l'auteur de dire laquelle.
#
#  La justification est indexee par le TITRE du panneau ou le nom de l'alerte,
#  jamais par un fragment d'expression : un titre est unique et stable, un
#  fragment attrape ce qu'il ne devrait pas.
# ---------------------------------------------------------------------------
VIDES_ATTENDUS = {
    # --- Alertes : vide = tout va bien ------------------------------------
    "OOMKillDetected": "personne n'a ete tue faute de memoire.",
    "PodNotReady": "aucun pod non pret (hors Jobs termines, ecartes par le `unless`).",
    "PodCrashLooping": "aucun conteneur ne redemarre en boucle.",
    "DeploymentReplicasMismatch": "tous les Deployments ont leurs replicas prets.",
    "NodeNotReady": "le noeud est pret.",
    "BackendNoReplicas": "le backend a des replicas prets.",
    "PrometheusTargetDown": "toutes les cibles de collecte repondent.",
    "PrometheusRuleFailures":
        "aucune regle en echec -- c'est precisement ce que ce script garantit.",
    "AlertmanagerNotificationsFailing":
        "tout est route vers le recepteur `null` (aucun SMTP configure) : "
        "Alertmanager ne tente aucune livraison, donc n'en rate aucune.",
    "PrometheusTSDBGrowth":
        "cardinalite sous le seuil (base mesuree : ~80 000 series).",
    "HighCPUUsage": "aucun conteneur au-dela de 80 % de sa limite CPU.",
    "HighMemoryUsage": "aucun conteneur au-dela de 85 % de sa limite memoire.",
    "NodeDiskFillingUp":
        "la projection a 24 h reste positive : le disque ne se remplit pas.",
    "NodeDiskAlmostFull": "disque / a 34,6 %, loin du seuil de 90 %.",
    "NodeMemoryPressure": "il reste plus de 10 % de memoire disponible.",
    "NodeHighLoad": "charge par coeur sous 2 (base mesuree : 0,14).",
    "BackendDown":
        "le backend repond au scrape, donc `absent()` ne rend rien. "
        "⚠️ Un VIDE est ici la BONNE reponse -- l'alerte tire quand la serie "
        "`up` DISPARAIT, pas quand elle vaut 0.",
    "BackendHighErrorRate": "aucune reponse 5xx sur la fenetre.",
    "BackendHighLatency": "la latence p99 reste sous 2 s.",
    "GraphQLErrorRatio": "le taux d'erreur GraphQL reste sous 5 %.",
    "BackendEventLoopBlocked": "la boucle d'evenements n'est pas bloquee.",
    "BackendHeapNearLimit": "le tas V8 reste sous 90 % de l'alloue.",
    "BackendFileDescriptorsHigh": "moins de 80 % des descripteurs sont ouverts.",
    "KafkaDLQMessages": "aucun message abandonne en topic mort.",
    "OutboxPoisoned": "aucun evenement empoisonne.",
    "OutboxBacklogGrowing": "la boite d'envoi n'accumule pas.",
    "IngressHighErrorRate": "le taux de 5xx au bord reste sous 5 %.",
    "IngressUpstreamFailures":
        "aucune defaillance amont. Seuls `-` et `DC` sont observes sur ce "
        "cluster, et `DC` est le comportement normal d'un flux long.",
    "MeshTCPConnectionFailures": "aucune connexion TCP refusee dans le maillage.",
    "IstioCertNotRotating":
        "les certificats internes d'Istio tournent normalement (~21 h "
        "restantes au releve du 2026-09-02).",
    "OTelQueueNearFull": "la file d'export du collecteur est vide.",
    "TelemetryPipelineSilent":
        "des spans arrivent a Tempo. ⚠️ Un VIDE est ici la BONNE reponse : "
        "c'est l'etat sain depuis que OTEL_EXPORTER_OTLP_ENDPOINT est pose. "
        "Avant, la meme regle rendait une serie via `absent()` -- et c'etait "
        "l'alarme.",
    "LogPipelineSilent":
        "la metrique existe, donc `absent()` ne rend rien : Loki a bien recu "
        "des lignes. ⚠️ Cette regle ne surveille QUE le cas « jamais rien "
        "recu » -- les journaux sont filtres par niveau, un backend sain reste "
        "muet apres son demarrage (mesure : 394 lignes au boot puis zero "
        "pendant 30 min, avec Tempo actif en parallele).",
    "TempoFlushFailing": "aucune ecriture de bloc echouee.",
    "LokiChunkFlushFailing": "aucune ecriture de chunk echouee.",

    # --- Panneaux : vide = rien a montrer, et c'est la bonne nouvelle -----
    "Cibles de collecte muettes": "toutes les cibles repondent.",
    "Alertes en cours": "aucune alerte active hors Watchdog.",
    "Pods non prêts": "aucun pod non pret.",
    "Conteneurs sans limite mémoire":
        "⚠️ un vide ici serait une BONNE nouvelle, mais 14 conteneurs etaient "
        "concernes au 2026-09-02 : si ce vide apparait, verifier d'abord que "
        "le `unless on(namespace, pod, container)` s'apparie toujours.",
    "Redémarrages de conteneurs (1 h)": "aucun redemarrage sur la derniere heure.",
    "Connexions TCP échouées /s": "aucune connexion refusee.",
    "Drapeaux de réponse Envoy (1 h)": "aucun drapeau anormal sur la derniere heure.",
    "Opérations en erreur (1 h)": "aucune operation GraphQL en erreur.",
    "Points de terminaison en défaut":
        "istiod ne signale aucun endpoint sans pod pret.",
    "Écritures perdues côté stockage": "aucun flush echoue.",
    "Notifications tentées et échouées":
        "tout est route vers `null` : Alertmanager ne tente aucune livraison.",
}

# ---------------------------------------------------------------------------
#  Les vides qui ne le resteront PAS
# ---------------------------------------------------------------------------
#  Metriques absentes parce que la plomberie n'est pas encore deployee.
#  Signalees a part : ni erreur, ni « attendu ». Elles doivent apparaitre une
#  fois A1/A2 appliques -- et si elles n'apparaissent pas, c'est le deploiement
#  qui a echoue, pas la requete.
#
#  ⚠️ Indexees par NOM DE METRIQUE, pas par titre : c'est la metrique qui est
#  absente, et elle peut etre citee par plusieurs panneaux.
#
#  ⚠️ VIDER CETTE TABLE APRES DEPLOIEMENT. Une entree qui y reste devient une
#  exception permanente, c'est-a-dire exactement le mecanisme que ce script
#  combat.
EN_ATTENTE_DE_DEPLOIEMENT = {
    # VIDE, et c'est l'etat normal. La derniere entree --
    # `urbanconnect_outbox_pending`, absente parce que `drain()` ne posait la
    # jauge que s'il avait publie quelque chose -- a ete retiree le 2026-09-02
    # apres verification sur le cluster : le correctif est deploye
    # (sha-2066558a) et la metrique porte a nouveau ses deux etats sur chaque
    # replica.
    #
    # ⚠️ Toute entree ajoutee ici doit repartir des que le correctif est en
    # ligne. Une exception qui reste devient permanente, c'est-a-dire
    # exactement le mecanisme que ce script combat.
}

# ---------------------------------------------------------------------------
#  Compteurs qui n'existent qu'apres leur premier increment
# ---------------------------------------------------------------------------
#  ⚠️ CETTE CATEGORIE EXISTE PARCE QUE CHAQUE DEPLOIEMENT LA DECLENCHE.
#
#  `prom-client` — comme le SDK OpenTelemetry-Go — ne cree une serie qu'au
#  PREMIER `.inc()` avec ce jeu d'etiquettes. Un compteur d'evenements rares
#  n'existe donc pas du tout tant que l'evenement ne s'est pas produit, et
#  DISPARAIT a chaque redemarrage de pod jusqu'a ce qu'il se reproduise.
#
#  Ce n'est pas un defaut : c'est le comportement correct, et les alertes qui
#  s'y adossent sont justes -- elles tirent quand la serie apparait. Mais le
#  distinguer d'une metrique qui n'a JAMAIS existe demande de le declarer ici,
#  faute de quoi la porte crie a chaque livraison et on apprend a l'ignorer.
#
#  ⚠️ N'y inscrire QUE des compteurs dont on a verifie qu'ils existent apres
#  activite. Un nom mal orthographie y serait indetectable -- c'est la seule
#  faille possible de ce dispositif, et elle se referme en verifiant AVANT
#  d'ajouter une entree.
METRIQUES_A_INSTANCIATION_TARDIVE = {
    "urbanconnect_kafka_messages_total":
        "compteur cree au premier message publie. Absent sur un backend "
        "fraichement redemarre qui n'a encore rien emis. Verifie present le "
        "2026-09-02 avant le redeploiement (topic notification.delivery).",
    "urbanconnect_outbox_events_total":
        "meme mecanisme : cree au premier evenement relaye.",
}

# Mots du langage PromQL : identifiants valides, mais pas des noms de
# metriques. Sans cette liste, `sum`, `rate` ou `by` seraient interroges.
MOTS_PROMQL = {
    "by", "without", "on", "ignoring", "group_left", "group_right", "offset",
    "bool", "and", "or", "unless", "atan2", "start", "end", "inf", "nan",
    "sum", "min", "max", "avg", "group", "stddev", "stdvar", "count",
    "count_values", "bottomk", "topk", "quantile",
    "abs", "absent", "absent_over_time", "ceil", "changes", "clamp",
    "clamp_max", "clamp_min", "day_of_month", "day_of_week", "day_of_year",
    "days_in_month", "delta", "deriv", "exp", "floor", "histogram_quantile",
    "holt_winters", "hour", "idelta", "increase", "irate", "label_join",
    "label_replace", "ln", "log2", "log10", "minute", "month", "predict_linear",
    "rate", "resets", "round", "scalar", "sgn", "sort", "sort_desc", "sqrt",
    "time", "timestamp", "vector", "year",
    "avg_over_time", "min_over_time", "max_over_time", "sum_over_time",
    "count_over_time", "quantile_over_time", "stddev_over_time",
    "stdvar_over_time", "last_over_time", "present_over_time",
}

# Un nom de metrique : identifiant PromQL qui n'est PAS suivi d'une parenthese
# -- ce serait une fonction ou une agregation.
MOTIF_METRIQUE = re.compile(r"\b([a-zA-Z_][a-zA-Z0-9_:]*)\b(?!\s*\()")


def sans_litteraux(expr: str) -> str:
    """L'expression privee de ses selecteurs d'etiquettes et de ses chaines.

    ⚠️ INDISPENSABLE AVANT TOUTE ANALYSE SYNTAXIQUE, et l'oublier produit des
    faux positifs difficiles a lire. Un selecteur comme
    `route!~"/health.*|/metrics"` contient des `/` qui ne sont PAS des
    divisions : la detection d'operateur arithmetique s'y trompait et accusait
    `TelemetryPipelineSilent` d'un defaut d'appariement inexistant.
    """
    return re.sub(r'"[^"]*"', "", re.sub(r"\{[^{}]*\}", "", expr))


def metriques_citees(expr: str):
    """Noms de metriques reellement interroges par l'expression."""
    # Retirer les selecteurs d'etiquettes et les chaines : `status`, `le`,
    # `mutual_tls`... sont des etiquettes ou des valeurs, pas des metriques.
    sans_chaines = sans_litteraux(expr)
    # Retirer le contenu des clauses d'appariement : `by (pod)`, `on(exporter)`.
    sans_appariement = re.sub(
        r"\b(by|without|on|ignoring|group_left|group_right)\s*\([^()]*\)",
        " ", sans_chaines,
    )
    noms = set()
    for nom in MOTIF_METRIQUE.findall(sans_appariement):
        if nom in MOTS_PROMQL:
            continue
        noms.add(nom)
    return sorted(noms)


# Une comparaison numerique en fin d'expression : `> 0.8`, `== 0`, `< 3600`.
COMPARAISON_FINALE = re.compile(r"\s(==|!=|>=|<=|>|<)\s*[-+0-9.eE]+$")

# Un operateur ARITHMETIQUE entre deux vecteurs. Volontairement limite a
# l'arithmetique : `a != b` entre deux metriques est aussi sujet a un defaut
# d'appariement, mais son etat SAIN est justement d'etre vide -- on ne peut
# pas trancher mecaniquement, et ces cas-la restent justifies par leur titre.
OPERATEUR_ARITHMETIQUE = re.compile(r"[/*]|\s[+-]\s")


def noyau_sans_seuil(expr: str) -> str:
    """L'expression privee de sa comparaison finale, s'il y en a une.

    `otelcol_exporter_queue_size / otelcol_exporter_queue_capacity > 0.8`
      -> `otelcol_exporter_queue_size / otelcol_exporter_queue_capacity`

    C'est ce qui permet de distinguer « le seuil ne selectionne rien » (sain)
    de « le calcul lui-meme ne produit rien » (defaut).
    """
    aplati = " ".join(expr.split())
    correspondance = COMPARAISON_FINALE.search(aplati)
    return aplati[: correspondance.start()] if correspondance else aplati


def demander(expr: str):
    """Execute une expression instantanee. Rend (statut, detail)."""
    donnees = urllib.parse.urlencode({"query": expr}).encode()
    requete = urllib.request.Request(
        f"{PROM_URL}/api/v1/query", data=donnees, method="POST"
    )
    requete.add_header("Host", PROM_HOST)
    requete.add_header("Content-Type", "application/x-www-form-urlencoded")
    contexte = ssl._create_unverified_context()
    try:
        with urllib.request.urlopen(requete, timeout=TIMEOUT, context=contexte) as rep:
            charge = json.loads(rep.read())
    except urllib.error.HTTPError as e:
        try:
            charge = json.loads(e.read())
        except Exception:
            return "ERREUR", f"HTTP {e.code}"
    except Exception as e:  # reseau, DNS, timeout
        return "INJOIGNABLE", str(e)

    if charge.get("status") != "success":
        return "ERREUR", charge.get("error", "erreur PromQL sans message")
    resultat = charge["data"]["result"]
    return ("OK", len(resultat)) if resultat else ("VIDE", 0)


_cache_existence = {}


def existe(metrique: str) -> bool:
    """Vrai si la metrique porte au moins une serie. Resultat memorise."""
    if metrique not in _cache_existence:
        statut, _ = demander(f"count({metrique})")
        _cache_existence[metrique] = statut == "OK"
    return _cache_existence[metrique]


def substituer(expr: str) -> str:
    """Remplace les variables Grafana par ce que Grafana enverrait.

    `$pod` devient `.*` -- la valeur envoyee quand « All » est selectionne, et
    la seule valeur sure : une regex qui matche la chaine vide selectionne
    AUSSI les series depourvues de l'etiquette, ce qui rend le panneau correct
    avant comme apres le passage au ServiceMonitor.
    """
    return expr.replace("$pod", ".*")


def exprs_dashboards(filtre=None):
    for fichier in sorted(DASHBOARDS.glob("*.json")):
        if filtre and filtre not in fichier.stem:
            continue
        dash = json.loads(fichier.read_text(encoding="utf-8"))
        for panneau in dash.get("panels", []):
            for cible in panneau.get("targets", []) or []:
                if cible.get("expr"):
                    yield (fichier.name, panneau.get("title", "?"), cible["expr"])
        # Les variables de tableau de bord interrogent Prometheus elles aussi :
        # une `label_values()` sur une etiquette qui n'existe pas rend un menu
        # deroulant vide, et tous les panneaux qui s'en servent avec elle.
        for var in dash.get("templating", {}).get("list", []) or []:
            requete = var.get("query")
            if isinstance(requete, dict):
                requete = requete.get("query")
            if isinstance(requete, str) and requete.startswith("label_values("):
                interne = requete[len("label_values("):-1]
                metrique = interne.rsplit(",", 1)[0].strip()
                yield (fichier.name, f"variable ${var['name']}", metrique)


def exprs_regles(filtre=None):
    if filtre and filtre not in "prometheus-alerts":
        return
    doc = yaml.safe_load(REGLES.read_text(encoding="utf-8"))
    for groupe in doc["spec"]["groups"]:
        for regle in groupe["rules"]:
            yield ("prometheus-alerts.yaml", regle["alert"], regle["expr"])


def main() -> int:
    ap = argparse.ArgumentParser(description="Porte de verification des requetes PromQL")
    ap.add_argument("--only", help="ne verifier que les fichiers dont le nom contient ceci")
    ap.add_argument("--verbose", action="store_true", help="afficher aussi ce qui passe")
    args = ap.parse_args()

    print(f"Prometheus : {PROM_URL}  (Host: {PROM_HOST})\n")

    total = ok = vide_justifie = en_attente = tardif = 0
    erreurs_promql = []
    metriques_fantomes = []
    vides_non_justifies = []

    sources = list(exprs_dashboards(args.only)) + list(exprs_regles(args.only))
    for fichier, titre, expr_brute in sources:
        total += 1
        statut, detail = demander(substituer(expr_brute))

        if statut == "INJOIGNABLE":
            print(f"✖ Prometheus injoignable : {detail}")
            print("  Definir PROM_URL, ou lancer depuis le noeud Proxmox.")
            return 2

        if statut == "ERREUR":
            erreurs_promql.append((fichier, titre))
            print(f"✖ ERREUR  {fichier} › {titre}\n           {detail}")
            continue

        if statut == "OK":
            ok += 1
            if args.verbose:
                print(f"✔ OK      {fichier} › {titre}  ({detail} series)")
            continue

        # --- VIDE : les metriques citees existent-elles ? -------------------
        citees = metriques_citees(substituer(expr_brute))
        absentes = [m for m in citees if not existe(m)]

        tardives = [m for m in absentes if m in METRIQUES_A_INSTANCIATION_TARDIVE]
        if tardives and len(tardives) == len(absentes):
            tardif += 1
            if args.verbose:
                print(f"◷ TARDIVE {fichier} › {titre}")
                print(f"           {METRIQUES_A_INSTANCIATION_TARDIVE[tardives[0]]}")
            continue

        attendues = [m for m in absentes if m in EN_ATTENTE_DE_DEPLOIEMENT]
        if attendues and len(attendues) == len(absentes):
            en_attente += 1
            print(f"⧗ ATTENTE {fichier} › {titre}")
            print(f"           {EN_ATTENTE_DE_DEPLOIEMENT[attendues[0]]}")
            continue

        connues = set(EN_ATTENTE_DE_DEPLOIEMENT) | set(METRIQUES_A_INSTANCIATION_TARDIVE)
        vraiment_absentes = [m for m in absentes if m not in connues]
        if vraiment_absentes:
            metriques_fantomes.append((fichier, titre, vraiment_absentes))
            print(f"✖ FANTOME {fichier} › {titre}")
            print(f"           metrique(s) inexistante(s) : {', '.join(vraiment_absentes)}")
            print("           Le panneau restera vide et l'alerte ne tirera jamais.")
            continue

        # --- L'APPARIEMENT VECTORIEL A-T-IL ECHOUE EN SILENCE ? -------------
        # Deux metriques, un operateur arithmetique, et un resultat vide alors
        # que les deux existent : c'est le defaut d'OTelQueueNearFull. On
        # retire le seuil final et on reevalue. Si le CALCUL lui-meme ne
        # produit rien, aucune justification ne tient -- l'expression est
        # cassee, quel que soit l'etat du systeme.
        expr_norm = substituer(expr_brute)
        aplati = " ".join(expr_norm.split())
        # ⚠️ `sans_litteraux` AVANT la detection d'operateur : sinon le `/` de
        # `route!~"/health.*|/metrics"` passe pour une division.
        if len(citees) >= 2 and OPERATEUR_ARITHMETIQUE.search(sans_litteraux(aplati)):
            noyau = noyau_sans_seuil(expr_norm)
            # ⚠️ Comparer a `aplati`, pas a `expr_norm.strip()`.
            # `noyau_sans_seuil` normalise les espaces : face a une expression
            # ecrite sur plusieurs lignes, la comparaison etait TOUJOURS vraie,
            # le controle se declenchait sans qu'aucun seuil n'ait ete retire,
            # et reevaluait la meme expression -- donc criait au defaut
            # d'appariement sur tout vide legitime.
            if noyau != aplati and demander(noyau)[0] == "VIDE":
                vides_non_justifies.append((fichier, titre, expr_brute))
                print(f"✖ APPARIEMENT {fichier} › {titre}")
                print(f"           Les {len(citees)} metriques existent, mais le calcul")
                print("           rend un vecteur vide MEME SANS SON SEUIL. C'est un")
                print("           defaut d'appariement : les deux cotes n'ont pas le")
                print("           meme jeu d'etiquettes. Ajouter `on(...)` / `ignoring(...)`.")
                print(f"           noyau : {noyau[:130]}")
                continue

        raison = VIDES_ATTENDUS.get(f"{fichier} › {titre}") or VIDES_ATTENDUS.get(titre)
        if raison:
            vide_justifie += 1
            if args.verbose:
                print(f"○ VIDE    {fichier} › {titre}\n           {raison}")
        else:
            vides_non_justifies.append((fichier, titre, expr_brute))
            print(f"✖ VIDE    {fichier} › {titre}")
            print(f"           {' '.join(expr_brute.split())[:150]}")
            print("           Toutes les metriques citees existent, et pourtant aucune")
            print("           serie. C'est peut-etre l'etat sain -- ou un appariement")
            print("           vectoriel qui echoue en silence, comme l'a fait")
            print("           OTelQueueNearFull. Trancher, puis inscrire la raison dans")
            print("           VIDES_ATTENDUS sous la cle exacte du titre.")

    print("\n" + "─" * 74)
    print(f"{total} expressions · {ok} OK · {vide_justifie} vides justifies "
          f"· {tardif} compteurs pas encore instancies "
          f"· {en_attente} en attente de deploiement")
    print(f"{len(erreurs_promql)} erreurs PromQL · {len(metriques_fantomes)} metriques "
          f"fantomes · {len(vides_non_justifies)} vides non justifies")

    if erreurs_promql or metriques_fantomes or vides_non_justifies:
        print("\n⚠️  NE PAS DEPLOYER EN L'ETAT.")
        print("    Une expression en erreur ne s'evalue jamais ; une metrique fantome")
        print("    ou un vide inexplique produit un panneau qui ment et une alerte")
        print("    muette -- qui rassure au lieu d'avertir.")
        return 1

    print("\n✔ Tout est verifiable. Chaque panneau et chaque alerte s'appuie sur")
    print("  des metriques qui existent reellement sur ce cluster, et chaque vide")
    print("  a une raison ecrite.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
