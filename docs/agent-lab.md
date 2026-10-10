# Lab d'agents IA — VM 170 `agent-lab`

Agents Claude Code (abonnement, pas de clé d'API) qui tournent en tâche de
fond. Premier agent : **`traffic`**, rapport quotidien à 18:00 sur le trafic et
les utilisateurs de urbanlink.fr et wow.urbanlink.fr, avec recommandations.
Code des agents : dépôt **`agent-lab`** (CLI `lab` côté PC, `labctl` côté VM).

```
PC ── ssh (ProxyJump pve) ──► agent-lab 10.0.0.170 ── labctl ── claude -p ── labtools
                                   │ timer 18:00                  (lecture seule)
                                   ▼                                   │
                         rapport .md + email agents@ ──► alesio@       ├─ Cloudflare GraphQL (jeton Analytics:Read)
                                                                       ├─ Prometheus  10.0.0.111:30080 Host: prometheus.urbanlink.fr
                                                                       ├─ Grafana API (Viewer) → postgres-metier (grafana_ro), Loki
                                                                       ├─ ssh agentlog@10.0.0.1  → cat access-vhost.log (commande forcée)
                                                                       └─ ssh agentro@10.0.0.150 → MariaDB SELECT / journalctl (commande forcée)
```

## Ce qui garantit la lecture seule

Pas seulement la liste blanche d'outils de Claude Code : **chaque identifiant
est en lecture à la source.**

| Source | Borne |
|---|---|
| Postgres | rôle `grafana_ro`, `default_transaction_read_only = on` ; compte de service Grafana *Viewer* |
| Prometheus, Cloudflare | API de lecture ; jeton Cloudflare *Analytics:Read* |
| Log edge | utilisateur `agentlog` (groupe `adm`), clé `restrict,from=10.0.0.170,command=agent-lab-edge-log` |
| WoW | utilisateur `agentro`, clé bridée de même ; MariaDB unix_socket, `SELECT` sur `tw_char`, `wow_site` et des **colonnes** non sensibles de `tw_logon.account` (ni hash, ni email, ni IP) ; transaction `READ ONLY` |
| VM | utilisateur `agent` non-root, aucun kubeconfig, aucune clé vers le cluster |

Les IP du log edge sont remplacées par un condensat salé avant analyse.

## Mise en service

1. **Secrets** — sur le PC, `claude setup-token` (connexion à l'abonnement),
   puis sur le nœud `/root/.secrets/agent-lab.env` (0600) :
   ```
   CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
   CLOUDFLARE_API_TOKEN=...
   CLOUDFLARE_ZONE_ID=b8f77d7d9755c33f819b8116aee8dd40
   ```
   et dans `kube/urbanlink/secrets.env` : `AGENTS_MAILBOX_PASSWORD=` (12+ car.).
2. **Boîte mail** : `ansible-playbook playbooks/42-mailcow.yml` (crée `agents@`).
3. **Log edge par hôte** : `ansible-playbook playbooks/33-urbanlink-edge.yml`.
4. **VM** : `terraform apply` (crée 170 avec `agent = false`), puis
   `ansible-playbook playbooks/50-agent-lab.yml`, puis la procédure de l'agent
   QEMU (`qm set 170 --agent enabled=1 && qm stop 170 && qm start 170`, et
   `agent = true` dans `lab.auto.tfvars`).
5. **PC** : bloc `lab ssh-config` dans `~/.ssh/config`, `pipx install <agent-lab>`,
   puis `lab deploy` et `lab run traffic`.

## Exploitation

| Besoin | Commande (PC) |
|---|---|
| Rapport du jour | `lab report traffic` |
| Question | `lab ask traffic "d'où viennent les inscrits de la semaine ?"` (`-c` pour enchaîner) |
| Lancer maintenant | `lab run traffic` |
| Historique, journaux | `lab runs`, `lab logs <id>`, `lab stop <id>` |
| Changer l'heure | `lab schedule traffic 19:30` (`off`, `default`) |
| État et prochains déclenchements | `lab status` |

Sur la VM : `/opt/agent-lab` (code + `.venv`), `/var/lib/agent-lab` (lab.db,
rapports, journaux de runs), `/etc/agent-lab/env` (secrets, 0640 root:agent).
Timers : `systemctl --user list-timers` sous `agent`.

**Renouveler le jeton Grafana** : retirer la ligne `GRAFANA_TOKEN=` de
`/etc/agent-lab/env` et rejouer 50-agent-lab.yml.

**Quota de l'abonnement** : les runs partagent le quota de l'abonnement Claude
de Nicolas. Un run qui l'atteint échoue proprement (rapport `-ECHEC` + email).

## Ajouter un agent

Dossier `agents/<nom>/` dans le dépôt agent-lab (voir son `agents/README.md`),
puis `lab deploy`. Si l'agent a besoin d'une nouvelle source, l'accès en
lecture se pose ici (`roles/agent_lab`), l'outil dans `labtools`.
