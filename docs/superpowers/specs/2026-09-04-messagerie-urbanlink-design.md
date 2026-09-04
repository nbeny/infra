# Messagerie `urbanlink.fr` — boîtes à la maison, sortie par le VPS

> 2026-09-04 · dépôts `infra` (VM, Ansible, DNS) et `UrbanConnct` (transactionnel Kratos)

Une vraie messagerie pour `urbanlink.fr` : les boîtes vivent sur une VM du lab, le
courrier entre et sort par l'IP du VPS Hostinger, et les interfaces de gestion restent
hors d'Internet. L'exigence qui commande tout le reste est **ne pas finir en spam chez
Gmail et Outlook** — ce document explique quelles mesures l'imposent et comment le
design y répond.

---

## 1. Les mesures — relevées le 2026-09-04, pas déduites

### 1.1 L'IP de la maison ne peut pas émettre

```
82.65.87.60  zen.spamhaus.org       → 127.0.0.11
             TXT                    → "Listed by PBL, see https://check.spamhaus.org/query/ip/82.65.87.60"
82.65.87.60  b.barracudacentral.org → 127.0.0.2
PTR                                 → 82-65-87-60.subs.proxad.net
```

Le **PBL** n'est pas une sanction : c'est la déclaration, par Free, que la plage est
résidentielle et ne doit pas émettre de SMTP en direct. Aucune demande de délistage
n'aboutit sur une entrée PBL de plage, et le PTR `subs.proxad.net` suffit à lui seul à
faire rejeter chez Outlook. Le port 25 **sortant** est pourtant ouvert chez Free
(`220 mx.google.com` obtenu depuis le nœud) : c'est un piège, la connexion s'établit et
le message part en spam ou en rejet différé.

⇒ **La maison ne sera jamais l'adresse d'émission.** Ce point n'est pas négociable et
c'est lui qui justifie toute l'architecture.

### 1.2 L'IP du VPS est propre, et vérifiée en conditions réelles

```
147.79.102.17  zen · sbl · xbl · pbl · barracuda · spamcop · psbl · sorbs · uceprotect
               → toutes CLEAN
PTR            → srv859050.hstgr.cloud    FCrDNS valide en v4 ET en v6
```

Transactions SMTP réelles menées depuis le VPS, jusqu'au `RCPT TO` puis `QUIT` :

| Destinataire | Bannière | `MAIL FROM` | `RCPT TO` |
|---|---|---|---|
| `hotmail-com.olc.protection.outlook.com` | `220 … Hello [147.79.102.17]` | `250 2.1.0 Sender OK` | `250 2.1.5 Recipient OK` |
| `gmail-smtp-in.l.google.com` | `220 mx.google.com` | `250 2.1.0 OK` | `250 2.1.5 OK` |
| `mta7.am0.yahoodns.net` | `220 … ESMTP ready` | `250 sender ok` | `250 recipient ok` |

Microsoft ne bannit pas cette IP — c'est le seul contrôle qui compte, aucune liste
publique ne reflète les blocages Outlook.

### 1.3 Le piège IPv6

La sonde Gmail est ressortie en **IPv6** : `250-mx.google.com at your service,
[2a02:4780:28:981f::1]`. Le VPS a une adresse v6 globale et la préfère. Gmail applique
aux expéditeurs IPv6 des règles plus strictes qu'en v4 : PTR valide **et** SPF ou DKIM
alignés, sinon rejet. Une pile mail montée sans y penser part en `550` dès le premier
message.

### 1.4 L'existant à ne pas casser

| Endroit | Ce qui tourne | Ce que le design lui prend |
|---|---|---|
| VPS `147.79.102.17` | Traefik (80/443) → `nbeny.fr`, `www.nbeny.fr`, `francois.nbeny.fr` ; CrowdSec ; runner GitHub `folionbeny` | rien : **udp/51820** et **tcp/25**, tous deux libres |
| VPS, disque | 88 Go utilisés sur 99 (**93 %**), dont **40 Go récupérables** (30 Go d'images orphelines, 10 Go de cache de build) | libère 40 Go |
| VPS, `/srv/mailcow-dockerized/` | mailcow d'avril 2026, `MAILCOW_HOSTNAME=mail.urbanlink.fr`, **jamais démarrée** (aucun conteneur, `vmail` à 28 Ko) | sert de point de départ, puis le répertoire est retiré du VPS |
| Proxmox | 110 Go de RAM, **29 Go réellement disponibles** ; `pool2` ZFS, 2,5 To libres | une VM de 8 Go plafond / 4 Go plancher, 150 Go sur `pool2` |
| Cloudflare `urbanlink.fr` | MX Infomaniak, `SPF -all`, DMARC `p=none`, wildcard `*.urbanlink.fr → 192.168.100.50` DNS-only | ajoute `mail`, réécrit MX/SPF à la bascule ; **le wildcard n'est pas touché** |
| Cluster | Kratos émet via `smtps://contact@urbanlink.fr@mail.infomaniak.com:465` | bascule en phase 5 |

---

## 2. Le choix de la pile : Mailcow

L'état de l'art 2026 donne trois candidats sérieux. Mailcow (Postfix + Dovecot +
Rspamd + SOGo + UI d'admin) reste la référence pour une messagerie humaine avec
interface de gestion. Stalwart est le pari moderne — binaire Rust unique, JMAP,
métriques natives — mais **toujours en 0.x**, avec une refonte cassante en v0.16 (les
noms de comptes deviennent des adresses complètes, l'API REST change). Pour une boîte
qui doit tenir des années sans intervention, la maturité l'emporte sur l'élégance.

**Le MTA ne décide de rien en délivrabilité.** Il décide du confort d'exploitation.
La délivrabilité se joue sur l'IP, le PTR, l'authentification et la réputation — c'est
là que va l'effort de ce document.

Rejeté : `docker-mailserver` (aucune UI de gestion, or elle est explicitement
demandée), Mailu (moins complet que Mailcow pour le même prix en complexité).

---

## 3. Architecture — le VPS est un routeur, pas un relais SMTP

```
                         Internet
                             │
             MX urbanlink.fr → mail.urbanlink.fr → 147.79.102.17
                             │
               ┌─────────────▼──────────────┐   VPS Hostinger
               │  nftables : DNAT tcp/25    │   Traefik 80/443 inchangé
               │            SNAT sortant    │   + wg0  udp/51820
               └─────────────┬──────────────┘
                             │  WireGuard  10.88.0.0/30
                             │
               ┌─────────────▼──────────────┐   VM `mail` 10.0.0.140 (VMID 140)
               │          Mailcow           │   Postfix · Dovecot · Rspamd · SOGo
               │   boîtes, index, données   │   150 Go sur pool2
               └─────────────┬──────────────┘
                             │
        UI d'admin · SOGo · Rspamd · métriques
        → mail.urbanlink.fr sur l'openresty du nœud, LAN uniquement
        → depuis l'extérieur : WireGuard
```

### 3.1 Pourquoi router et non relayer — le cœur du design

Un relais SMTP sur le VPS **détruirait l'antispam**. Rspamd, à la maison, ne verrait
plus que `10.88.0.1` comme client : les contrôles SPF, DMARC et listes noires
porteraient sur le VPS au lieu de l'expéditeur réel, et il faudrait activer le module
`external_relay` pour reconstituer l'IP à partir d'en-têtes falsifiables.

En **DNAT sans masquerade**, l'IP source de l'expéditeur traverse le tunnel intacte.
Rspamd voit le vrai client, ses contrôles fonctionnent nativement, et les en-têtes
`Received` racontent la vérité.

Le retour est assuré par une règle de routage **par source**, et non par une route par
défaut : le trafic dont la source est l'adresse WireGuard de la VM repart par le
tunnel, tout le reste continue de passer par la passerelle du lab. La VM reste donc
joignable et à jour même tunnel coupé.

```
# sur la VM — le critère est le RÉSEAU DOCKER de Mailcow, pas le port
ip rule  add from 172.22.1.0/24 lookup 100 pref 100
ip route add default via 10.88.0.1 dev wg0 table 100
iptables -t nat -A POSTROUTING -s 172.22.1.0/24 -o wg0 -j SNAT --to-source 10.88.0.2
```

**Le critère de sélection est le réseau, pas le port** — et ce n'est pas un détail de
mise en œuvre. Postfix tourne dans un conteneur : son trafic traverse `FORWARD`, jamais
`OUTPUT`. Un marquage `-t mangle -A OUTPUT --dport 25` n'attraperait donc rien.

Un marquage en `PREROUTING` ne suffirait pas non plus. Pour une connexion entrante
DNATée, la traduction inverse du paquet de réponse n'a lieu qu'en `POSTROUTING` : au
moment où la décision de routage est prise, la réponse porte encore l'adresse du
conteneur `172.22.1.x`. Une règle `from 10.88.0.2` ne matcherait jamais, et les réponses
partiraient par la passerelle du lab — donc dans le vide.

Router **tout le réseau Docker de Mailcow** par le tunnel règle les deux sens d'un coup.
La VM elle-même garde sa route par défaut vers le lab : elle reste joignable, mise à
jour et administrable même tunnel coupé. Le `SNAT` vers `10.88.0.2` est nécessaire parce
que le pair WireGuard du VPS n'accepte que cette adresse dans ses `AllowedIPs`.

À la sortie, Postfix parle **directement** à Gmail et Outlook ; le VPS ne fait que
traduire l'adresse source. Pas de file d'attente en double, pas de réécriture, les
codes de rejet reviennent bruts jusqu'à la VM.

### 3.2 IPv6 : fermé, pas surveillé

`inet_protocols = ipv4` dans Postfix. Le tunnel est en v4 seul. Émettre en IPv6
demanderait un PTR et un SPF alignés sur `2a02:4780:28:981f::1` ; le gain est nul, le
risque de rejet Gmail est réel. On ferme la porte.

### 3.3 Ce qui est exposé sur Internet

**Le port 25, et rien d'autre.** Submission (465/587) et IMAP (993) ne sont pas
publiés : l'accès se fait par WireGuard, depuis le LAN ou depuis le téléphone. Le
bourrage d'identifiants sur submission est le premier vecteur de compromission d'un
serveur mail — et une compromission est précisément ce qui fait blacklister une IP.
Le coût est un VPN permanent sur le mobile ; c'est un choix assumé.

---

## 4. DNS — zone Cloudflare `urbanlink.fr`

| Nom | Type | Valeur | Proxy | Quand |
|---|---|---|---|---|
| `mail` | A | `147.79.102.17` | **DNS-only** | phase 1 |
| `urbanlink.fr` | MX | `10 mail.urbanlink.fr` | — | phase 3 |
| `urbanlink.fr` | TXT | `v=spf1 ip4:147.79.102.17 -all` | — | phase 3 |
| `dkim._domainkey` | TXT | RSA 2048 généré par Mailcow | — | phase 1 |
| `_dmarc` | TXT | `p=none` → `quarantine` → `reject`, `rua=mailto:dmarc@urbanlink.fr` | — | 3 puis 4 |
| `_mta-sts` | TXT | `v=STSv1; id=<horodatage>` | — | phase 4 |
| `mta-sts` | A/CNAME | vers le VPS, policy servie par Traefik | proxy OK | phase 4 |
| `_smtp._tls` | TXT | `v=TLSRPTv1; rua=mailto:tlsrpt@urbanlink.fr` | — | phase 4 |
| `notifs` | MX/TXT | SPF, DKIM et DMARC propres au transactionnel | — | phase 5 |

**Pendant la transition**, le SPF porte les deux origines :
`v=spf1 ip4:147.79.102.17 include:spf.infomaniak.ch -all`. L'`include` ne tombe qu'une
fois Infomaniak hors service.

**Le wildcard `*.urbanlink.fr → 192.168.100.50` n'est pas modifié.** `mail` étant un
enregistrement explicite, il l'emporte pour le SMTP ; toutes les autres interfaces
restent sur l'IP privée. Le garde-fou du rôle `edge_urbanlink` (assertion que le
wildcard n'a pas bougé) continue de s'appliquer.

**Deux noms, deux rôles — à ne pas confondre.** `mail.urbanlink.fr` est l'identité SMTP :
elle pointe sur le VPS, c'est elle que les MX du monde résolvent et elle que le HELO et
le PTR annoncent. Les interfaces (Mailcow, SOGo, Rspamd) sont servies sous
**`webmail.urbanlink.fr`**, couvert par le wildcard, donc sur l'IP privée. Publier l'UI
sous `mail.urbanlink.fr` était impossible : ce nom résout publiquement vers le VPS.
Mailcow doit donc porter `ADDITIONAL_SERVER_NAMES=webmail.urbanlink.fr`, faute de quoi
son nginx rejette l'en-tête `Host` du vhost interne. Le certificat wildcard couvre les
deux noms.

**Deux actions manuelles restent à l'utilisateur** — elles ne peuvent pas être
automatisées depuis ce dépôt :

1. **rDNS** `147.79.102.17 → mail.urbanlink.fr` dans le hPanel Hostinger. Le PTR
   actuel est cohérent mais générique ; un PTR au nom du domaine pèse chez Outlook.
2. **Inscriptions** : Google Postmaster Tools (vérification par TXT, que je prépare),
   Microsoft **SNDS** et **JMRP** — ce dernier renvoie les plaintes des utilisateurs
   Outlook, c'est le seul signal de réputation que Microsoft consent à donner.

---

## 5. Conformité aux exigences 2026 des grands fournisseurs

Depuis mai 2026, Google, Microsoft et Yahoo rejettent en **550 permanent** — plus de
simple mise en spam. Le design couvre l'ensemble :

| Exigence | Réponse du design |
|---|---|
| SPF **et** DKIM valides | SPF `-all` sur une IP unique ; DKIM RSA 2048 signé par Mailcow |
| Alignement DMARC | `From:` en `@urbanlink.fr`, SPF et DKIM sur le même domaine — alignement strict des deux côtés |
| DMARC publié et appliqué | `p=none` d'abord pour lire les rapports, puis `quarantine`, puis `reject` |
| PTR / FCrDNS | déjà valide ; renforcé par le rDNS au nom du domaine |
| TLS en transport | STARTTLS obligatoire en entrée, opportuniste en sortie, MTA-STS `enforce` en phase 4 |
| Désabonnement un clic (RFC 8058) | posé sur le transactionnel `notifs.urbanlink.fr` en phase 5 |
| Taux de plainte < 0,3 % | surveillé par JMRP et les rapports DMARC, alerte au-delà de 0,1 % |

Le volume attendu reste très inférieur au seuil « expéditeur en masse » (5 000/jour),
mais respecter ces règles est ce qui distingue une boîte crédible d'une boîte tolérée.

---

## 6. Observabilité

Tout se branche sur le `kube-prometheus-stack` existant, à travers le tunnel.

- **Sonde DNSBL** — un exporter interroge `147.79.102.17` sur une dizaine de listes
  toutes les 15 minutes. Alerte **dès la première inscription**, avant que ça se voie
  sur le courrier. C'est la sonde qui répond directement à l'exigence de départ.
- **Exporters** Postfix, Dovecot, Rspamd et node_exporter sur la VM, en cible statique
  du Prometheus du cluster.
- **parsedmarc → Elasticsearch → Kibana** : les deux sont déjà déployés dans le
  cluster. Les rapports DMARC agrégés deviennent des tableaux de bord au lieu de XML
  illisibles — c'est ce qui permet de voir *qui* usurpe le domaine avant de passer en
  `p=reject`.
- **Tableau de bord Grafana « Messagerie »** : file d'attente, différés, rejets par
  destinataire avec Gmail et Outlook isolés, échecs SPF/DKIM entrants, expiration des
  certificats, état du tunnel.
- **Alertes** : file d'attente qui croît, IP listée, certificat à moins de 15 jours,
  taux de plainte au-delà de 0,1 %, tunnel WireGuard silencieux, port 25 entrant muet.

Les interfaces (Mailcow, SOGo, Rspamd) sont publiées par le rôle `edge_urbanlink`
existant, en palier **interne** — couvertes par le wildcard et le bloc allow/deny des
vhosts, comme les dix consoles actuelles. Aucun `public: true`.

---

## 7. Sauvegardes

Les boîtes vivant à la maison, la sauvegarde est locale et rapide :

- `vzdump` de la VM 140 vers `pool2`, dans la rotation Proxmox existante ;
- sauvegarde applicative Mailcow (`backup_and_restore.sh`) quotidienne vers un dataset
  ZFS distinct — une restauration de boîte ne doit pas exiger de restaurer la VM ;
- rétention 30 jours, restauration **testée une fois** en phase 4, pas seulement
  configurée.

---

## 8. Phasage — le courrier actuel ne court aucun risque

Infomaniak continue de recevoir jusqu'à preuve que la nouvelle chaîne fonctionne.

| Phase | Contenu | Critère de passage | Réversibilité |
|---|---|---|---|
| **0** | 40 Go libérés sur le VPS ; VM 140 créée par Terraform ; WireGuard monté des deux côtés ; rDNS posé | tunnel actif, trafic dans les deux sens, DNAT :25 joignable depuis Internet | totale |
| **1** | Mailcow installée ; certificats par DNS-01 Cloudflare ; comptes et alias ; **aucun DNS public modifié** | UI joignable en LAN, IMAP local fonctionnel | totale |
| **2** | Envois de test vers mail-tester, Gmail, Outlook, Yahoo | **10/10 sur mail-tester**, arrivée en boîte de réception chez Gmail *et* Outlook, en-têtes `dkim=pass spf=pass dmarc=pass` | totale |
| **3** | Bascule MX + SPF ; warm-up progressif du volume | réception réelle pendant 48 h sans différé | retour à Infomaniak en 5 minutes (TTL court posé avant) |
| **4** | Observabilité, alertes, sauvegardes, DMARC `quarantine` puis `reject`, MTA-STS `enforce` | rapports DMARC lus, aucun échec légitime | par enregistrement DNS |
| **5** | Kratos → `notifs.urbanlink.fr` ; résiliation Infomaniak | mails de vérification reçus en boîte de réception | `secrets.env` réversible |

**Le TTL des enregistrements concernés est abaissé à 300 s au début de la phase 3** et
remonté une semaine après la bascule. C'est ce qui rend le retour arrière réellement
possible.

---

## 9. Ce que ce design ne fait pas

- **`nbeny.fr` n'est pas touché** : son MX reste chez Infomaniak, ses sites sur le VPS
  continuent de servir. Mailcow gère plusieurs domaines ; l'ajouter plus tard coûtera
  deux enregistrements DNS et un domaine dans l'UI, une fois la réputation établie.
- **Pas de reprise de l'historique Infomaniak** : les boîtes démarrent vides, décision
  prise explicitement. L'historique reste consultable chez Infomaniak tant que le compte
  vit — d'où la résiliation en dernière phase et non en première.
- **Pas de DANE/TLSA** en première intention : cela demande DNSSEC sur la zone, donc un
  enregistrement DS chez le registrar. À reconsidérer en phase 4 si la zone est signée.
- **Pas de webmail public** : SOGo reste interne, conformément au choix « WireGuard
  obligatoire ».
- **Rien n'est déployé sur le cluster Kubernetes.** La messagerie est volontairement
  hors du cluster : un serveur mail veut des ports bruts, de l'état sur disque et une
  identité réseau stable — trois choses que Kubernetes rend difficiles pour rien.

---

## 10. Risques identifiés

| Risque | Portée | Parade |
|---|---|---|
| Le tunnel tombe | courrier entrant différé (les MX émetteurs réessaient 4 à 5 jours), sortant bloqué | alerte sur l'état du tunnel ; `PersistentKeepalive` et unité systemd en `Restart=always` |
| Hostinger bloque le port 25 | émission coupée | rien ne l'indique aujourd'hui (sortie 25 vérifiée) ; le design permet de basculer sur un relais tiers en changeant `relayhost` |
| L'IP du VPS se fait lister | spam ou rejet | sonde DNSBL toutes les 15 min ; submission non exposée, donc pas de compromission par force brute ; warm-up progressif |
| La RAM du Proxmox est déjà surengagée | OOM killer côté hôte | VM à **plafond 8 Go, plancher 4 Go avec ballooning**, contrairement aux VMs existantes en `balloon: 0` |
| Disque du VPS à 93 % | Docker en échec, Traefik compris | 40 Go libérés en phase 0 ; le VPS ne stocke aucune donnée mail |
| Bascule Kratos avant validation | mails de vérification perdus, inscriptions cassées | phase 5, après plusieurs semaines de fonctionnement prouvé |
