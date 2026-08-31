# Audit DevOps & sécurité — nœud `pve`

Audit du nœud Proxmox `pve` (82.65.87.60 / 192.168.100.50) et du lab.
Réalisé le **30 août 2026** sur Proxmox VE 9.1.7, noyau 6.17.13-2-pve.

Tous les constats ci-dessous ont été **vérifiés sur la machine**, pas déduits.
Les commandes de vérification sont données pour que tu puisses les rejouer.

**Rien n'a été modifié.** Le correctif de chaque point est fourni en code dans
[`ansible/roles/pve_hardening/`](../ansible/roles/pve_hardening/), désactivé par
défaut — voir [Appliquer les correctifs](#appliquer-les-correctifs).

---

## Résumé

| # | Constat | Gravité |
|---|---|---|
| 1 | Aucune sauvegarde depuis le 6 avril — **VM 100 (1 To) jamais sauvegardée** | 🔴 Critique |
| 2 | L'origine est jointe en direct, **Cloudflare est contourné à 100 %** | 🔴 Critique |
| 3 | Certificats Let's Encrypt **expirés depuis 3–4 mois**, renouvellement muet | 🟠 Élevée |
| 4 | Pare-feu Proxmox **jamais activé** → aucune isolation entre VMs | 🟠 Élevée |
| 5 | SSH : `PermitRootLogin yes` + `PasswordAuthentication yes` | 🟠 Élevée |
| 6 | Aucun 2FA sur `root@pam` | 🟠 Élevée |
| 7 | `iperf3` en écoute publique sur `*:5201`, autorisé par ufw | 🟠 Élevée |
| 8 | ZFS : **aucun scrub depuis le 8 mars** malgré le cron mensuel | 🟡 Moyenne |
| 9 | `rpcbind` (111) et `snmpd` (161) exposés, aucun des deux n'est utilisé | 🟡 Moyenne |
| 10 | Pas de mises à jour automatiques sur le nœud (dont `zfsutils` en retard) | 🟡 Moyenne |
| 11 | Règles ufw obsolètes (BGP 179, 443/udp, 8006/udp) | 🟡 Moyenne |
| 12 | Deux serveurs web en parallèle (nginx + openresty) | 🟡 Moyenne |
| 13 | Règle NAT `MASQUERADE` dupliquée | 🔵 Faible |
| 14 | `kernel.kptr_restrict = 0` | 🔵 Faible |
| 15 | `folio.nbeny.fr` : vhost servi sans enregistrement DNS | 🔵 Faible |
| K1 | Secrets Kubernetes **non chiffrés dans etcd** (donc en clair dans les sauvegardes) | 🟠 Élevée |
| K2 | **Aucune NetworkPolicy** : réseau de pods totalement plat | 🟠 Élevée |
| K3 | API server joignable depuis tout le lab, Kali comprise | 🟡 Moyenne |
| K4 | Pas de Pod Security Admission sur le namespace applicatif | 🟡 Moyenne |
| B1 | **Le backend n'est pas constructible** : lockfile désynchronisé | 🟠 Élevée |
| B2 | Image frontend de 6,27 Go (≈10× la taille attendue) | 🟡 Moyenne |

**Le point le plus urgent est le n° 1.** Une panne disque aujourd'hui coûterait
UrbanConnect en entier. Tout le reste est secondaire à côté.

---

## 🔴 1. Aucune sauvegarde — la VM principale n'en a jamais eu

```console
$ ls /etc/pve/jobs.cfg
ls: cannot access '/etc/pve/jobs.cfg': No such file or directory

$ ls /pool2/backups/dump/ | grep -oE "qemu-[0-9]+" | sort -u
qemu-101
qemu-102

$ ls -lt /pool2/backups/dump/ | head -3
vzdump-qemu-102-2026_04_06-02_10_45.vma.zst      6 avr.
vzdump-qemu-101-2026_04_06-02_00_03.vma.zst      6 avr.
```

Aucun job planifié. Les 99 Go présents sont des dumps manuels d'avril, et ils
ne couvrent que les VM 101 et 102. **La VM 100 — UrbanConnect, 1 To, ton host
principal — n'apparaît nulle part.**

`/etc/cron.d/vzdump` existe mais ne contient plus que son en-tête : la
planification a été supprimée à un moment sans être remplacée.

Il n'y a pas non plus de snapshot ZFS des disques de VM (seuls les snapshots
`@__base__` des templates existent) : aucun filet de secours local.

**Correctif** — `pve_hardening_backup: true` crée un job vzdump quotidien vers
`pool2-backup` avec rétention. À faire aujourd'hui, avant tout le reste.

> Une sauvegarde sur le même serveur ne protège que de l'erreur humaine, pas de
> l'incendie ni du vol. Prévoir une copie hors-site (Proxmox Backup Server
> distant, ou `zfs send` vers un NAS) reste à faire dans un second temps.

---

## 🔴 2. Cloudflare est contourné : l'origine est exposée en direct

Les domaines sont derrière Cloudflare :

```console
$ dig +short @8.8.8.8 nbeny.fr
188.114.96.2
188.114.97.2      # ← Cloudflare
```

Mais le trafic qui arrive réellement sur nginx ne vient **pas** de Cloudflare :

```console
$ awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -5
   1856 35.240.141.232     DIRECT (contourne Cloudflare)
     72 93.123.109.178     DIRECT (contourne Cloudflare)
     43 103.215.75.66      DIRECT (contourne Cloudflare)
     41 103.215.74.26      DIRECT (contourne Cloudflare)
     10 47.84.16.218       DIRECT (contourne Cloudflare)
```

Aucune de ces IP n'appartient aux plages Cloudflare. L'IP publique
`82.65.87.60` est connue des scanners, qui frappent nginx directement.

Conséquence : **le WAF, la protection DDoS et les règles de Cloudflare ne
s'appliquent à personne.** Payer ou configurer Cloudflare ne sert à rien tant
que l'origine reste joignable. CrowdSec a d'ailleurs déjà banni un scanner :

```console
$ cscli decisions list
Ip:103.78.2.252 | crowdsecurity/http-cve-2021-42013 | ban | VN
```

Bon réflexe déjà en place : `/etc/nginx/conf.d/30-cloudflare-realip.conf`
existe, donc quand le trafic passe bien par Cloudflare, les vraies IP client
sont restaurées et CrowdSec bannit le bon acteur.

**Correctif** — `pve_hardening_cloudflare_only: true` restreint 80/443 aux
plages Cloudflare officielles (téléchargées depuis `cloudflare.com/ips-v4`),
ce qui rend le contournement impossible.

> À ne pas activer si un service doit rester joignable hors Cloudflare.
> Vérifie d'abord que tous tes domaines sont bien proxifiés (nuage orange).

---

## 🟠 3. Certificats expirés depuis 3 à 4 mois

```console
$ certbot certificates
  folio.nbeny.fr       Expiry: 2026-04-26  (INVALID: EXPIRED)
  francois.nbeny.fr    Expiry: 2026-05-22  (INVALID: EXPIRED)
  nbeny.fr             Expiry: 2026-05-26  (INVALID: EXPIRED)
  proxmox.nbeny.fr     Expiry: 2026-04-10  (INVALID: EXPIRED)
```

nginx sert bien ces certificats expirés, y compris sur l'IP publique :

```console
$ echo | openssl s_client -connect 82.65.87.60:443 -servername nbeny.fr | openssl x509 -noout -enddate
notAfter=May 26 14:47:47 2026 GMT
```

Les visiteurs ne voient rien : Cloudflare termine le TLS avec son propre
certificat valide. **Mais cela veut dire que Cloudflare est en mode « Full » et
non « Full (strict) »** — il accepte n'importe quel certificat côté origine,
y compris expiré. Le lien Cloudflare→origine n'est donc pas authentifié : il
est vulnérable à une interception entre les deux.

Le timer certbot tourne pourtant :

```console
$ systemctl is-active certbot.timer
active
$ systemctl list-timers certbot.timer
LAST: Sat 2026-08-29 20:51:45 CEST (il y a 9 h)
```

Il s'exécute donc et échoue silencieusement depuis avril.

**À faire à la main** (diagnostic, pas automatisable à l'aveugle) :

```bash
certbot renew --dry-run --cert-name nbeny.fr -v
journalctl -u certbot.service --since "7 days ago" | tail -50
```

Piste la plus probable : le challenge HTTP-01 passe par Cloudflare, qui peut
intercepter `/.well-known/acme-challenge/`. Le plus robuste ici est de basculer
sur le challenge **DNS-01 avec le plugin Cloudflare**, qui ne dépend plus du
tout de la joignabilité HTTP :

```bash
apt install python3-certbot-dns-cloudflare
# jeton API Cloudflare avec la permission Zone:DNS:Edit
certbot certonly --dns-cloudflare --dns-cloudflare-credentials /root/.cf.ini -d nbeny.fr
```

Une fois les certificats valides, passer Cloudflare en **Full (strict)**.

---

## 🟠 4. Le pare-feu Proxmox n'a jamais été activé

```console
$ cat /etc/pve/firewall/cluster.fw
cat: No such file or directory        # ← pare-feu datacenter jamais configuré

$ cat /etc/pve/nodes/pve/host.fw
[RULES]
IN ACCEPT -p tcp -dport 8006 -log nolog
```

Une règle existe au niveau du nœud, et les VM 102 et 103 portent `firewall=1`.
Mais **sans activation au niveau datacenter, rien de tout cela ne s'applique** :
c'est l'interrupteur principal, et il est absent.

Conséquence concrète : les VM de `vmbr1` se voient toutes entre elles et
atteignent le nœud sur `10.0.0.1`, sans filtrage. Une VM compromise (typiquement
la Kali, faite pour manipuler des outils offensifs) peut balayer et attaquer
UrbanConnect librement.

Les VM créées par Terraform sont en `firewall=0`. Le module expose désormais une
variable `firewall`, **laissée à `false` volontairement** : une VM marquée
`firewall=1` **sans** fichier `/etc/pve/firewall/<vmid>.fw` hérite de la
politique par défaut (`DROP`) dès que le pare-feu datacenter est activé, et
devient injoignable — y compris pour Ansible. L'ordre correct est : écrire les
règles de la VM, puis passer `firewall = true` sur son entrée `vms`.

**Correctif** — `pve_hardening_firewall: true` active le pare-feu datacenter
avec une politique d'entrée par défaut `DROP`, en autorisant explicitement SSH,
8006 et le trafic déjà établi.

> Étape sensible : une erreur ici coupe l'accès au nœud. Le rôle conserve un
> accès SSH et 8006 depuis le LAN dans tous les cas, et fait une sauvegarde
> avant écriture. À lancer quand tu as un accès physique ou IPMI de secours.

---

## 🟠 5. SSH : root par mot de passe autorisé

```console
$ sshd -T | grep -E "permitrootlogin|passwordauthentication"
permitrootlogin yes
passwordauthentication yes
```

Nuance importante, mesurée : **le port 22 n'est pas joignable depuis Internet.**

```console
$ (depuis Internet) nc -z 82.65.87.60 22   → filtré
$ grep -c "Failed password" /var/log/auth.log
0                                          # aucune attaque en 3 j 12 h d'uptime
```

Ce n'est donc pas une urgence — mais c'est le compte le plus privilégié de
l'infrastructure, protégé par un simple mot de passe, joignable par toute
machine du LAN et par toute VM du lab. Un poste compromis sur le réseau, ou une
VM Kali qui part de travers, suffit pour tenter un bruteforce local sans limite.

Et CrowdSec ne rattrape pas ce cas : il lit bien `/var/log/auth.log`, mais
n'en parse rien d'utile aujourd'hui.

```console
$ cscli metrics
| file:/var/log/auth.log          | 1.43k lues | 0 parsées |
| file:/var/log/pveproxy/access.log | 39.27k lues | 0 parsées |
```

**La connexion à l'interface web Proxmox n'est pas protégée non plus** : 39 000
lignes lues, aucune analysée, donc aucun bannissement possible sur un bruteforce
de l'interface d'administration.

### Cause réelle, mesurée le 2026-08-31

La première version de ce constat accusait l'acquisition (« il manque un
`labels.type` »). C'était faux : `acquis.yaml` déclarait déjà `type: syslog`
sur `auth.log`. La cause est ailleurs, et elle est unique pour les deux
sources.

`hub_dir` vaut `/etc/crowdsec/hub`, mais **49 des items installés étaient des
liens symboliques vers `/var/lib/crowdsec/hub`**, l'emplacement qu'utilisait
l'ancien paquet Debian. Une cible hors de `hub_dir` fait classer l'item
« local » : `cscli` refuse de le mettre à jour (« not downloading local
item ») et `cscli hub upgrade` passe à côté **sans rien signaler**. Ces 49
items étaient figés depuis le 21/12/2025.

Parmi eux, `crowdsecurity/sshd-logs`, resté sur :

```yaml
filter: "evt.Parsed.program == 'sshd'"
```

Or Debian 13 embarque OpenSSH 10, qui journalise sous le nom `sshd-session` :

```
2026-08-31T14:57:12+02:00 pve sshd-session[1822459]: Invalid user admin from ...
```

Plus une seule ligne de `auth.log` ne franchissait l'étape `s01-parse`. Le hub
courant dit `filter: "evt.Parsed.program in ['sshd-session', 'sshd']"` — le
correctif était publié, il n'arrivait simplement plus jusqu'ici.

`pveproxy/access.log`, lui, ne sera jamais lisible : Proxmox y écrit un mois
**en chiffres** (`[31/08/2026:14:57:11 +0200]`) là où `%{HTTPDATE}` attend
`Aug`, et sans les champs referer/user-agent qu'exige `crowdsecurity/nginx-logs`.
Les échecs d'authentification Proxmox sont en revanche écrits par `pvedaemon`
dans `/var/log/syslog`, et la collection `fulljackz/proxmox` sait les lire :
c'est par là que passe désormais la détection.

**Correctif** — `pve_hardening_ssh: true` passe `PermitRootLogin` à
`prohibit-password` et coupe l'authentification par mot de passe (tes 4 clés
publiques sont déjà en place, l'accès est donc préservé).
`pve_hardening_crowdsec_acquis: true` rebranche les items orphelins sur le hub
courant, installe `fulljackz/proxmox`, réduit l'acquisition aux trois sources
qui servent, puis **vérifie le résultat avec `cscli explain`** — le play échoue
si une ligne SSH ou `pvedaemon` de référence ne parse pas.

---

## 🟠 6. Aucun 2FA sur `root@pam`

```console
$ cat /etc/pve/priv/tfa.cfg
{}
```

L'interface Proxmox donne un accès total au matériel virtualisé. Elle n'est pas
exposée sur Internet (vérifié : port 8006 filtré), mais un seul facteur pour
l'administration complète de l'infrastructure reste faible.

**À faire à la main** — 2 minutes, pas automatisable proprement :
*Datacenter → Permissions → Two Factor → Add → TOTP* sur `root@pam`.

Note aussi : le token `terraform@pve!provider` est en `privsep=0` (mêmes droits
que l'utilisateur) et `expire=0` (n'expire jamais). Acceptable pour de
l'automatisation, mais à révoquer si le dépôt fuite.

---

## 🟠 7. `iperf3` en écoute publique

```console
$ ss -tulnp | grep 5201
tcp LISTEN 0 4096 *:5201  users:(("iperf3",pid=2131,fd=3))

$ systemctl is-enabled iperf3
enabled

$ ufw status | grep 5201
5201    ALLOW IN    Anywhere
```

Un démon de test de débit, activé au démarrage, en écoute sur **toutes** les
interfaces, et **explicitement autorisé par ufw depuis n'importe où**. L'origine
étant joignable en direct (constat n° 2), n'importe qui peut saturer ta ligne
ou s'en servir comme relais.

C'était probablement pour un test ponctuel resté en place.

**Correctif** — `pve_hardening_disable_unused: true` arrête et désactive le
service, et retire la règle ufw.

---

## 🟡 8. Aucun scrub ZFS depuis 6 mois

```console
$ zpool status pool1 | grep scan:
  scan: scrub repaired 0B in 00:05:19 with 0 errors on Sun Mar  8 00:29:20 2026
```

Le cron mensuel existe pourtant et le script est bien là :

```console
$ grep scrub /etc/cron.d/zfsutils-linux
24 0 8-14 * * root if [ $(date +\%w) -eq 0 ] && [ -x /usr/lib/zfs-linux/scrub ]; then /usr/lib/zfs-linux/scrub; fi
$ ls -l /usr/lib/zfs-linux/scrub
-rwxr-xr-x 1 root root 1432 May 20  2023
```

Le 8 mars était un dimanche entre le 8 et le 14 : le dernier scrub correspond
exactement à un déclenchement du cron. Depuis, avril, mai, juin, juillet et août
avaient tous un dimanche dans la fenêtre, et aucun scrub n'a eu lieu. Le cron ne
produit donc plus rien.

Un scrub est ce qui détecte la corruption silencieuse. Sur 2,7 To de données de
production, six mois sans vérification, c'est long.

**Correctif** — `pve_hardening_zfs_scrub: true` remplace le cron par un timer
systemd mensuel (déterministe et observable via `systemctl list-timers`), et
lance un scrub immédiat si le dernier date de plus de 35 jours.

---

## 🟡 9. Services exposés inutilisés : `rpcbind` et `snmpd`

```console
$ ss -tulnp | grep -E ":111|:161"
udp 0.0.0.0:111   rpcbind
udp 0.0.0.0:161   snmpd
tcp 0.0.0.0:111   rpcbind

$ grep -c nfs /etc/pve/storage.cfg
0                                    # aucun stockage NFS
$ showmount -e localhost
clnt_create: RPC: Program not registered
```

`rpcbind` (portmapper NFS) tourne sans qu'aucun NFS ne soit utilisé. C'est un
vecteur d'amplification UDP classique.

`snmpd` écoute sur **toutes** les interfaces (`agentAddress udp:161,udp6:161`)
et tourne en `agentuser root`. Le défaut Debian est de n'écouter que sur la
boucle locale — la configuration a été élargie.

ufw bloque ces deux ports depuis l'extérieur aujourd'hui, ce qui limite le
risque. Mais ce sont deux services privilégiés qui tournent pour rien.

**Correctif** — `pve_hardening_disable_unused: true` désactive `rpcbind` et
restreint `snmpd` à `127.0.0.1` (ou le désactive si tu ne supervises rien).

---

## 🟡 10. Pas de mises à jour automatiques sur le nœud

```console
$ systemctl is-enabled unattended-upgrades
not-found

$ apt-get -s upgrade | grep ^Inst | tail -3
Inst zfsutils-linux [2.4.1-pve1] (2.4.4-pve1 ...)
Inst zfs-zed [2.4.1-pve1] (2.4.4-pve1 ...)
Inst zsh [5.9-8+b21] (5.9-8+b23 ...)
```

Les VM du lab ont `unattended-upgrades` (rôle `common`), le nœud non. Il accuse
notamment trois versions de retard sur ZFS, la couche qui porte toutes tes
données.

**Correctif** — `pve_hardening_unattended: true` installe
`unattended-upgrades` limité aux mises à jour de **sécurité** (jamais les
montées de version PVE, qui doivent rester manuelles), sans redémarrage
automatique.

---

## 🟡 11. Règles ufw obsolètes

```console
$ ufw status
5201        ALLOW IN    Anywhere     # iperf3 (constat n° 7)
179/tcp     ALLOW IN    Anywhere     # BGP -- aucun démon n'écoute
443/udp     ALLOW IN    Anywhere     # QUIC non utilisé
8006/udp    ALLOW IN    Anywhere     # 8006 est du TCP uniquement
4242/*      ALLOW IN    Anywhere     # DNAT vers le SSH de la VM 102
```

Les trois premières n'ouvrent rien qui écoute — bruit sans risque immédiat, mais
elles masquent la vraie surface d'exposition. Les règles `443/udp` et
`8006/udp` sont des erreurs de saisie (protocole inutile).

La règle **4242** en revanche expose délibérément le SSH de la VM 102 à
Internet. C'est le mode d'accès historique, remplacé par le ProxyJump depuis ce
dépôt. À supprimer une fois que tu utilises `ssh/config.example`.

**Correctif** — `pve_hardening_ufw_cleanup: true` retire 5201, 179, 443/udp et
8006/udp. La règle 4242 est laissée en place : sa suppression est un choix
d'usage, pas de sécurité (`pve_hardening_drop_dnat_4242: true` pour la retirer).

---

## 🟡 12. Deux serveurs web en parallèle

```console
$ systemctl is-active openresty
active
$ nginx -v
nginx/1.26.3
$ cscli metrics | grep openresty
| file:/usr/local/openresty/nginx/logs/error.log | 28 lues |
```

nginx (paquet Debian) et openresty (compilé dans `/usr/local`) tournent en même
temps. Deux serveurs web, deux configurations, deux cycles de mises à jour —
et openresty, installé hors paquet, **n'est pas mis à jour par apt**. Une faille
dans sa version restera ouverte jusqu'à recompilation manuelle.

Il faut déterminer lequel sert réellement (nginx tient 80/443/444) et supprimer
l'autre. Rien n'est automatisé ici : c'est une décision d'architecture.

Point connexe : `server_tokens` est commenté dans la configuration nginx, donc
la version exacte est annoncée dans chaque réponse HTTP. Un `server_tokens off;`
ne protège de rien en soi, mais évite de servir la liste des CVE applicables aux
scanners.

---

## 🔵 13–15. Points mineurs

**13. Règle NAT dupliquée.** Le `MASQUERADE` de `10.0.0.0/24` apparaît deux fois
dans `iptables -t nat -S` : un `post-up` rejoué sans `post-down`. Sans effet
fonctionnel, mais chaque paquet traverse la règle deux fois et l'état diverge de
`/etc/network/interfaces`.

**14. `kernel.kptr_restrict = 0`.** Les adresses du noyau sont lisibles par un
utilisateur non privilégié, ce qui facilite l'exploitation locale (contournement
de KASLR). Le défaut Debian est `1`. Corrigé par `pve_hardening_sysctl: true`.

**15. `folio.nbeny.fr` sans DNS.** Le vhost est servi par nginx mais le domaine
ne résout plus (`dig +short folio.nbeny.fr` → vide). Le certificat associé
continue d'être renouvelé pour rien — et un échec sur ce domaine mort peut
faire échouer tout le lot certbot, ce qui expliquerait le constat n° 3.
À vérifier en priorité lors du diagnostic certbot.

---

## Volet Kubernetes (cluster `urbanlink`)

Le cluster qui héberge le stack UrbanLink est neuf, donc sur les défauts de
kubeadm. Ce qui est bon d'emblée : `authorization-mode=Node,RBAC`, Kubernetes
**v1.36.4** à jour, et un seul conteneur privilégié (`kube-proxy`, attendu).

Trois écarts comptent pour une charge de production :

### K1. Les secrets ne sont pas chiffrés dans etcd 🟠

```console
$ grep -c encryption-provider-config /etc/kubernetes/manifests/kube-apiserver.yaml
0
```

Sans `EncryptionConfiguration`, un `Secret` Kubernetes n'est que du base64 dans
etcd. Or `kube/urbanlink/secrets.yaml` porte, une fois rempli : mots de passe
PostgreSQL, `JWT_SECRET`, clés MinIO, `KRATOS_SECRET`, identifiants Directus.

Concrètement : **toute sauvegarde de la VM `urbanlink` contient ces secrets en
clair** — y compris le vzdump que le correctif n° 1 va commencer à produire.

Correctif : activer un `EncryptionConfiguration` (`aescbc` ou KMS) sur
l'API server, puis réécrire les secrets existants
(`kubectl get secrets -A -o json | kubectl replace -f -`).

### K2. Aucune NetworkPolicy 🟠

```console
$ kubectl get networkpolicy -A --no-headers | wc -l
0
```

Le réseau de pods est plat : le frontend peut parler directement à PostgreSQL,
à Elasticsearch et à MinIO. Sur un stack de 27 composants dont plusieurs sont
exposés publiquement, une seule RCE dans le frontend donne accès à toutes les
bases.

Flannel n'implémente pas les NetworkPolicy — c'est justement l'argument pour
basculer sur **Cilium**, déjà prévu dans le rôle :

```bash
ansible-playbook playbooks/20-debian-k8s.yml -l urbanlink -e k8s_cni=cilium
```

Ensuite, au minimum : un `default-deny` en entrée sur le namespace
`urbanconnect`, puis les autorisations explicitement nécessaires.

### K3. L'API server est joignable depuis tout le lab 🟡

```console
$ ss -tlnp | grep 6443
LISTEN 0 4096 *:6443
```

L'API écoute sur toutes les interfaces, donc sur `10.0.0.111:6443`. Combiné au
constat n° 4 (pas de pare-feu entre VM), **la VM Kali peut joindre l'API du
cluster de production**. RBAC empêche l'accès anonyme utile, mais c'est une
surface qui n'a aucune raison d'exister : le seul client légitime est le nœud
lui-même et Ansible.

Le correctif n° 4 (pare-feu Proxmox) traite la cause. Pour aller plus loin, une
règle `<vmid>.fw` sur la VM `urbanlink` limitant 6443 à `10.0.0.1`.

### K4. Pas de Pod Security Admission sur `urbanconnect` 🟡

Le namespace applicatif n'a pas de label `pod-security.kubernetes.io/*` : rien
n'empêche d'y déployer un pod privilégié ou en `hostNetwork`. Un
`enforce=baseline` coûte une ligne et bloque les abus les plus courants :

```bash
kubectl label ns urbanconnect \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted
```

> `coturn` est déployé en `hostNetwork` (nécessaire pour le STUN/TURN) : il
> faudra soit l'exempter, soit le laisser dans un namespace séparé.

---

## Volet chaîne de build (constaté en testant)

### B1. Le backend n'est pas constructible en l'état 🟠

En construisant `urbanconnect-backend:prod` depuis le dépôt applicatif :

```console
npm error code EUSAGE
npm error `npm ci` can only install packages when your package.json and
npm error package-lock.json are in sync.
npm error Missing: react@19.2.8 from lock file
npm error Missing: react-dom@19.2.8 from lock file
npm error Missing: @types/react@19.2.18 from lock file
npm error Missing: csstype@3.2.3 from lock file
npm error Missing: scheduler@0.27.0 from lock file
```

`backTs/package-lock.json` a divergé de `package.json`. Le Dockerfile utilise
`npm ci` — et il a raison, c'est ce qui garantit qu'un build est reproductible.
Le résultat est qu'**aucune image backend ne peut être produite aujourd'hui**,
ni ici ni dans une CI.

Détail qui interpelle : `react`, `react-dom` et `scheduler` sont des
dépendances **frontend** déclarées dans le `package.json` d'un backend NestJS.
Ça ressemble à un `npm install react` lancé dans le mauvais répertoire.

Correction, à faire dans le dépôt applicatif :

```bash
cd UrbanConnct/backTs
npm install                      # resynchronise le lockfile
git diff package.json            # vérifier si react/react-dom ont leur place ici
git add package-lock.json && git commit -m "fix(backend): resynchronise le lockfile"
```

Le playbook `30-urbanlink-images.yml` offre `-e urbanlink_backend_relock=true`
pour régénérer le lockfile **dans la copie de build** et débloquer un test.
C'est un contournement, pas un correctif : il annule la garantie apportée par
`npm ci`, et il est désactivé par défaut.

### B2. L'image frontend pèse 6,27 Go 🟡

```console
$ docker images
urbanconnect-frontend:prod   6.27GB
```

Pour une application Next.js, c'est environ dix fois la taille attendue. La
cible `production` du Dockerfile ne repart pas d'une image mince : elle
conserve les dépendances de build et le cache. Un `output: "standalone"` côté
Next.js et une étape finale sur `node:20-alpine` ramèneraient l'image sous
500 Mo — avec un impact direct sur le temps de démarrage des pods et sur la
surface d'attaque (moins d'outils embarqués dans le conteneur).

---

## Ce qui est déjà bien

Il serait malhonnête de ne lister que les problèmes. Plusieurs choses sont
mieux faites que sur la moyenne des serveurs auto-hébergés :

- **CrowdSec est en place et fonctionne** sur nginx : 5,03 k lignes parsées sur
  5,28 k, avec des bannissements réels sur des CVE HTTP.
- **`30-cloudflare-realip.conf` est configuré** — le piège classique (bannir les
  IP de Cloudflare au lieu des attaquants) est évité.
- **ufw est actif** avec une politique `deny (incoming)` par défaut, et
  `FORWARD` en `DROP`.
- **Le dépôt enterprise est désactivé** et no-subscription correctement activé.
- **ZFS est sain** : `all pools are healthy`, zéro erreur.
- **Ports 22 et 8006 non joignables depuis Internet** — la surface d'exposition
  réelle se limite à 80/443.
- `TLSv1.3` uniquement côté nginx.

---

## Appliquer les correctifs

Tout est désactivé par défaut. Chaque point s'active indépendamment.

```bash
cd /root/infra/ansible

# 1. Voir ce qui serait fait, sans rien changer
ansible-playbook playbooks/95-hardening.yml --check --diff

# 2. Le plus urgent : les sauvegardes
ansible-playbook playbooks/95-hardening.yml -e pve_hardening_backup=true

# 3. Services inutiles + ufw + sysctl + scrub + mises à jour (sans risque)
ansible-playbook playbooks/95-hardening.yml \
  -e pve_hardening_disable_unused=true \
  -e pve_hardening_ufw_cleanup=true \
  -e pve_hardening_sysctl=true \
  -e pve_hardening_zfs_scrub=true \
  -e pve_hardening_unattended=true

# 4. SSH (garde une session ouverte le temps de vérifier)
ansible-playbook playbooks/95-hardening.yml -e pve_hardening_ssh=true

# 5. Sensibles -- à faire avec un accès de secours
ansible-playbook playbooks/95-hardening.yml -e pve_hardening_firewall=true
ansible-playbook playbooks/95-hardening.yml -e pve_hardening_cloudflare_only=true
```

Ou tout d'un coup, une fois chaque point relu :

```bash
ansible-playbook playbooks/95-hardening.yml -e pve_hardening_all=true
```

### Restant à faire à la main

| Point | Pourquoi pas automatisé |
|---|---|
| Diagnostic certbot (n° 3) | La cause n'est pas déterminée ; automatiser à l'aveugle risquerait de casser des certificats encore utilisés |
| 2FA sur `root@pam` (n° 6) | Nécessite de scanner un QR code |
| Choisir entre nginx et openresty (n° 12) | Décision d'architecture |
| Sauvegarde hors-site (n° 1) | Dépend d'une destination que tu dois choisir |
| Cloudflare en « Full (strict) » (n° 3) | Se règle dans l'interface Cloudflare, après réparation des certificats |
