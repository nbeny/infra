# Porte de vérification de l'observabilité

`check-queries.py` exécute **chaque expression PromQL** du dépôt contre le Prometheus réel
du cluster, et refuse ce qui ne peut pas fonctionner.

```bash
# Depuis le nœud Proxmox, qui atteint directement la passerelle du cluster
python3 scripts/observability/check-queries.py

# Depuis un poste, par un tunnel SSH
ssh -f -N -L 19090:10.0.0.111:30080 root@192.168.100.50
PROM_URL=http://127.0.0.1:19090 python3 scripts/observability/check-queries.py

python3 scripts/observability/check-queries.py --only 01-backend   # un seul fichier
python3 scripts/observability/check-queries.py --verbose           # tout, y compris ce qui passe
```

Lecture seule. N'écrit rien, ne lit aucun secret. Sort en `0` si tout est vert, `1` sinon.

## Ce qu'elle couvre

| source | quoi |
|---|---|
| `kube/urbanlink/config/prod/observability/grafana-dashboards/*.json` | l'`expr` de chaque cible de panneau, **et** les `label_values()` des variables |
| `kube/urbanlink/observability/prometheus-alerts.yaml` | l'`expr` de chaque règle |

## Pourquoi elle existe

**Un nom de métrique inexistant ne lève aucune erreur en PromQL.** L'expression rend un
vecteur vide : le panneau affiche « No data » — indiscernable d'un système au repos — et
l'alerte ne part jamais. Le défaut est invisible précisément quand tout va bien, et le
reste jusqu'au jour où l'alerte aurait dû sauver quelque chose.

Huit métriques citées par les anciens tableaux de bord et alertes n'ont jamais existé sur
ce cluster, et deux règles étaient mortes d'un appariement vectoriel qui ne trouvait
aucune paire. Aucune n'aurait survécu à une exécution de ce script.

## Les quatre verdicts

| verdict | signification | bloquant |
|---|---|---|
| `OK` | au moins une série | — |
| `ERREUR` | PromQL refuse l'expression | **oui** |
| `FANTÔME` | une métrique citée n'existe pas sur le cluster | **oui** |
| `APPARIEMENT` | toutes les métriques existent, mais le calcul rend un vecteur vide **même sans son seuil** | **oui** |
| `VIDE` | métriques présentes, seuil non atteint — l'état sain | seulement si non justifié |

Le verdict est **mécanique** : le script extrait les noms de métriques de l'expression et
interroge chacun, puis retire le seuil final et réévalue. C'est ce qui distingue « personne
n'a été tué faute de mémoire » de « l'expression est cassée ».

## Ajouter une justification

Un `VIDE` non justifié bloque. Si l'absence de série est réellement l'état sain, inscrire
la raison dans `VIDES_ATTENDUS`, **sous la clé exacte du titre du panneau ou du nom de
l'alerte** :

```python
VIDES_ATTENDUS = {
    "OOMKillDetected": "personne n'a ete tue faute de memoire.",
}
```

⚠️ **Indexer par titre, jamais par fragment d'expression.** La première version du script
cherchait des fragments, dont des seuils nus (`> 0.8`) — et a classé l'alerte
`OTelQueueNearFull`, vide en permanence pour cause d'appariement cassé, comme « aucune
ressource au-delà de 80 % ». La porte justifiait elle-même le défaut qu'elle était censée
trouver. Un titre est unique et stable ; un fragment attrape ce qu'il ne devrait pas.

Écrire la raison est le point du dispositif : c'est en la formulant qu'on se rend
généralement compte que le vide n'est pas sain.
