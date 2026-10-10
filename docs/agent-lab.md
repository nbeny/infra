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

## Secrets et CI/CD

**Source de vérité des secrets des agents : les GitHub Secrets du dépôt
`nbeny/agent-lab`** — `CLAUDE_CODE_OAUTH_TOKEN` (abonnement, `claude
setup-token`), `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`,
`CLOUDFLARE_ZONE_ID`, `AGENTS_MAILBOX_PASSWORD` (= mot de passe des consoles,
comme les autres boîtes). Copie lisible : `agent-lab/.secrets/agent-lab.env`
sur le PC, repoussée par `scripts/github-sync-secrets.sh`.

**Déploiement automatique** (`.github/workflows/ci-cd.yml` du dépôt agent-lab) :

```
push main ─► test (ubuntu-latest : pytest, agents, scripts)
          └► deploy (runner auto-hébergé SUR la VM, label agent-lab, utilisateur agent)
               1. écrit ~/.config/agent-lab/secrets.env depuis les GitHub Secrets (0600)
               2. bin/install.sh : rsync → /opt/agent-lab, pip, labctl sync-timers
               3. vérifie Cloudflare et Prometheus
```

Aucun port ouvert vers le lab : le runner va chercher ses jobs chez GitHub.
Ansible ne garde que le jeton Grafana (`/etc/agent-lab/env`), qu'il émet avec
les identifiants des consoles.

## Mise en service

1. **Boîte mail** : `ansible-playbook playbooks/42-mailcow.yml --tags accounts`.
2. **Log edge par hôte** : `ansible-playbook playbooks/33-urbanlink-edge.yml`.
3. **VM** : `terraform apply` (crée 170 avec `agent = false`), puis
   `ansible-playbook playbooks/50-agent-lab.yml -e github_runners_pat=$(gh auth token)`
   (le PAT enregistre le runner, une seule fois), puis la procédure de l'agent
   QEMU (`qm set 170 --agent enabled=1 && qm stop 170 && qm start 170`, et
   `agent = true` dans `lab.auto.tfvars`).
4. **Premier déploiement** : push sur `main` du dépôt agent-lab (ou relancer le
   workflow `ci-cd`). Secours sans CI : `lab deploy` depuis le PC.
5. **PC** : bloc `lab ssh-config` dans `~/.ssh/config`, `pipx install <agent-lab>`,
   puis `lab run traffic`.

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
rapports, journaux de runs), `/etc/agent-lab/env` (config + jeton Grafana,
0640 root:agent), `~agent/.config/agent-lab/secrets.env` (écrit par la CI),
`/opt/actions-runner/agent-lab` (runner).
Timers : `systemctl --user list-timers` sous `agent`.

**Changer un secret d'agent** : `.secrets/agent-lab.env` puis
`scripts/github-sync-secrets.sh`, et relancer le workflow `ci-cd`.

**Renouveler le jeton Grafana** : retirer la ligne `GRAFANA_TOKEN=` de
`/etc/agent-lab/env` et rejouer 50-agent-lab.yml.

**Quota de l'abonnement** : les runs partagent le quota de l'abonnement Claude
de Nicolas. Un run qui l'atteint échoue proprement (rapport `-ECHEC` + email).

## Ajouter un agent

Dossier `agents/<nom>/` dans le dépôt agent-lab (voir son `agents/README.md`),
puis `lab deploy`. Si l'agent a besoin d'une nouvelle source, l'accès en
lecture se pose ici (`roles/agent_lab`), l'outil dans `labtools`.
