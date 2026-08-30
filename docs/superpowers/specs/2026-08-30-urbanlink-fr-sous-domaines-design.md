# Exposer les outils du lab sous `*.urbanlink.fr`

**Date** : 30 août 2026
**État** : conception validée, implémentation à faire

---

## Le besoin

Chaque outil du lab doit répondre sur un sous-domaine de `urbanlink.fr`, joignable
depuis le poste Windows (`192.168.1.89`), sans dégrader la sécurité de
l'installation. En parallèle, la configuration du routeur MikroTik doit être
versionnée et reconstructible.

Aujourd'hui rien n'est nommé : les manifests Istio déclarent des hosts en
`urbanconnect.fr` qui ne résolvent nulle part, et les consoles d'administration
(pgAdmin, Kibana, Kiali…) ne s'atteignent qu'en `kubectl port-forward`.

---

## L'état constaté

Tout ce qui suit a été relevé sur les machines le 30 août 2026, pas déduit de la
documentation.

### Topologie

```
Internet  82.65.87.60
    │
Box FAI 192.168.1.254 ── DHCP ── poste 192.168.1.89
    │                            (route statique persistante
    │                             192.168.100.0/24 → 192.168.1.50)
MikroTik hAP ac²  RBD52G-5HacD2HnD
    RouterOS 6.49.4 (fév. 2022) · RouterBOOT 6.45.9 · ARM 4×716 MHz · 128 Mo
    ether1  = 192.168.1.50/24  (DHCP de la box)     ← liste WAN
    bridge1 = 192.168.100.1/24                      ← liste LAN
    route statique 10.0.0.0/24 → 192.168.100.50
    │
Proxmox `pve`  192.168.100.50 (vmbr0) · 10.0.0.1 (vmbr1)
    openresty 1.27.1.2 sur :80 :443 :444
      · bouncer CrowdSec openresty (actif, dernier pull OK)
      · vhosts nbeny.fr, www, folio, francois, proxmox — certbot HTTP-01
      · `20-default-deny.conf` : `server_name _` → `return 444`
    MASQUERADE 10.0.0.0/24 → vmbr0
    │
    10.0.0.0/24
        10.0.0.111  urbanlink — k8s 1.36.4, Istio 1.30.4 ambient
                    istio-ingressgateway NodePort 80:30080 443:30443
                    istio-system : istiod, kiali:20001, prometheus:9090
                    urbanconnect : 20 services
```

### Le domaine

`urbanlink.fr` est déjà déposé et sa zone est hébergée chez **Cloudflare**
(`benedict.ns.cloudflare.com`, `vita.ns.cloudflare.com`) — le même compte que
`nbeny.fr`. Aucun enregistrement A n'existe pour l'instant.

C'est le fait qui débloque tout : la zone étant pilotable par API, on peut
obtenir un certificat par challenge **DNS-01**, donc un certificat Let's Encrypt
authentique pour des noms qui ne sont joignables que depuis le LAN.

### Les six constats sur le MikroTik

| Réf | Constat | Conséquence |
|---|---|---|
| **M1** | Les quatre règles `dstnat` (22, 80, 443, 4242) portent `in-interface=ether1` mais **aucun `dst-address`**. | Toute requête du LAN vers **n'importe quelle** IP en `192.168.100.0/24` sur ces ports est détournée vers `192.168.100.50`. Le webfig du routeur lui-même est inatteignable : `https://192.168.100.1` renvoie l'openresty du Proxmox. |
| **M2** | Les chaînes `input` et `forward` contiennent des règles `accept` mais **aucun `drop` final** — la politique par défaut de RouterOS est `accept`. | Le routeur n'a pas de pare-feu. Seule la box FAI le protège, et elle lui redirige déjà 22/80/443. |
| **M3** | `/tool/mac-server` et `/tool/mac-server/mac-winbox` sont sur `allowed-interface-list=all`. | MAC-telnet et MAC-Winbox — qui opèrent en couche 2 et contournent entièrement le filtrage IP — répondent sur le segment WAN. Aucune règle de pare-feu ne les arrête. |
| **M4** | La session BGP avec CrowdSec (`192.168.100.50`, AS 65001) est en `state=active, established=false`. Le scheduler `CrowdsecUpdate` appelle toutes les 15 min un script `crowdsec_import` qui **n'existe pas** (`/system/script` est vide) — 576 exécutions en échec. | Le pipeline de blocage CrowdSec → MikroTik est mort. Les bouncers `cs-mikrotik-bouncer`, `mikrotik-final` et `exabgp-mikrotik` sont enregistrés côté nœud mais ne produisent aucun effet sur le routeur. |
| **M5** | Pool DHCP `dhcp` = `192.168.100.0-192.168.100.200` : inclut l'adresse réseau **et la passerelle**. Entrée `/ip/dhcp-server/network` fantôme `192.0.0.0/8` avec `gateway=192.168.1.50`. Service `api` en clair (8728) activé. | Un bail sur `.1` couperait tout le segment. L'entrée `/8` est un reliquat dangereux. L'API en clair transporte le mot de passe admin en clair sur le LAN. |
| **M6** | RouterBOOT en 6.45.9 sous un RouterOS 6.49.4 daté de février 2022. | Retard de firmware et de correctifs. Hors périmètre : la mise à niveau impose un redémarrage, donc une coupure Internet du foyer. |

---

## Les décisions

| Question | Décision | Pourquoi |
|---|---|---|
| Portée d'exposition | **LAN uniquement** | Les consoles d'administration exposées sur Internet, même protégées par mot de passe, sont la surface d'attaque garantie d'un lab. |
| TLS | **Wildcard Let's Encrypt, challenge DNS-01 Cloudflare** | Certificat authentique sans rien publier. Renouvellement automatique. Pas de CA à installer sur chaque poste. |
| Résolution | **Enregistrement A public → IP privée** | Zéro configuration sur les clients, marche pour tout appareil du LAN, aucun résolveur supplémentaire à maintenir. |
| Domaine applicatif | **`urbanconnect.fr` remplacé par `urbanlink.fr`** | Le dépôt s'appelle `urbanlink` partout (VM, playbook, `kube/urbanlink/`) sauf dans les hosts. On lève l'incohérence. |
| Emplacement du dépôt MikroTik | **Répertoire `mikrotik/` de ce dépôt** | `terraform/`, `packer/`, `ansible/` et `kube/` cohabitent déjà ; la configuration du routeur n'a de sens qu'avec eux. |

### Ce que « A record public vers IP privée » implique

Depuis Internet, `pgadmin.urbanlink.fr` résout en `192.168.100.50` et ne mène
nulle part : l'adresse n'est pas routable. C'est l'isolement le plus solide
possible — il ne dépend d'aucune règle de filtrage, donc aucune erreur de
configuration ne peut l'ouvrir par accident.

La contrepartie est que le plan d'adressage privé devient lisible dans le DNS
public. C'est une information sans valeur offensive — elle ne donne ni accès ni
chemin — mais elle est assumée, pas ignorée.

Les enregistrements doivent être créés en **DNS-only** (nuage gris) dans
Cloudflare. Un enregistrement proxifié (nuage orange) ferait transiter le trafic
par Cloudflare, qui ne peut évidemment pas joindre une IP privée.

### Ce que « nginx parle en clair à la passerelle » implique

Le TLS est terminé sur le nœud. Le saut `192.168.100.50 → 10.0.0.111:30080`
traverse `vmbr1`, un bridge virtuel interne au même hyperviseur — il ne quitte
jamais la machine physique.

L'alternative, `proxy_pass https://10.0.0.111:30443`, obligerait à poser
`proxy_ssl_verify off` face au certificat auto-signé de la passerelle : du
chiffrement sans authentification, qui ne protège de rien de plus sur ce
segment. Le mTLS du mesh reprend derrière la passerelle, là où il a un sens.

---

## Le plan de nommage

Quinze outils, seize noms — `urbanlink.fr` et `www.urbanlink.fr` désignent
le même frontend. Tous sont couverts par le même certificat wildcard.

### Applicatif — étiquette `uc.ingress/tier: public`

| Nom | Destination | Port |
|---|---|---|
| `urbanlink.fr`, `www.urbanlink.fr` | `frontend.urbanconnect.svc.cluster.local` | 3000 |
| `api.urbanlink.fr` | `backend.urbanconnect.svc.cluster.local` | 4000 |
| `auth.urbanlink.fr` | `kratos.urbanconnect.svc.cluster.local` | 4433 |
| `nominatim.urbanlink.fr` | `nominatim.urbanconnect.svc.cluster.local` | 8080 |
| `s3.urbanlink.fr` | `minio.urbanconnect.svc.cluster.local` | 9000 |

`auth` remplace `kratos` : le nom du produit d'authentification n'a pas à
apparaître dans une URL publique.

### Consoles — étiquette `uc.ingress/tier: internal`

| Nom | Destination | Port |
|---|---|---|
| `directus.urbanlink.fr` | `directus.urbanconnect.svc.cluster.local` | 8055 |
| `minio.urbanlink.fr` | `minio.urbanconnect.svc.cluster.local` | 9001 |
| `pgadmin.urbanlink.fr` | `pgadmin.urbanconnect.svc.cluster.local` | 80 |
| `kafka.urbanlink.fr` | `kafka-ui.urbanconnect.svc.cluster.local` | 8080 |
| `temporal.urbanlink.fr` | `temporal-ui.urbanconnect.svc.cluster.local` | 8080 |
| `kibana.urbanlink.fr` | `kibana.urbanconnect.svc.cluster.local` | 5601 |
| `kiali.urbanlink.fr` | `kiali.istio-system.svc.cluster.local` | 20001 |
| `prometheus.urbanlink.fr` | `prometheus.istio-system.svc.cluster.local` | 9090 |

`kiali` et `prometheus` sont nouveaux. Ils tournent depuis l'installation
d'Istio (`k8s_istio_observability: true`) mais n'étaient joignables que par
`kubectl port-forward`.

Le palier `internal` n'a **aucune conséquence technique** dans ce design : tout
est déjà restreint au LAN par nginx. L'étiquette existe pour que la publication
future de l'applicatif soit une ligne à écrire et non un audit à refaire.

### Hors cluster — vhosts nginx directs, sans Istio

| Nom | Destination |
|---|---|
| `proxmox.urbanlink.fr` | `https://192.168.100.50:8006` |
| `router.urbanlink.fr` | `http://192.168.100.1` (webfig, après correctif M1) |

`proxmox.nbeny.fr` existe déjà et reste en place ; le nouveau nom est un second
chemin, pas un remplacement.

---

## Le chemin d'une requête

```
poste 192.168.1.89
  │ DNS   *.urbanlink.fr → 192.168.100.50   (Cloudflare, DNS-only)
  │ route 192.168.100.0/24 via 192.168.1.50 (déjà en place)
  ▼
MikroTik — routage pur entre ether1 et bridge1, plus de détournement (M1)
  ▼
Proxmox 192.168.100.50 · openresty :443
  ├─ certificat wildcard *.urbanlink.fr
  ├─ allow 192.168.1.0/24 ; allow 192.168.100.0/24 ; deny all
  └─ bouncer CrowdSec (déjà dans le chemin, inchangé)
  ▼ proxy_pass http://10.0.0.111:30080 · Host préservé · X-Forwarded-Proto https
Passerelle Istio (NodePort 30080)
  ▼ Gateway `uc-gateway` + un VirtualService par host
services urbanconnect / istio-system
```

L'adresse source vue par nginx est bien celle du poste : le `srcnat` du MikroTik
ne s'applique qu'en sortie `ether1`, et après M1 le trafic LAN → `192.168.100.50`
est du routage sans traduction. Le filtre `allow/deny` porte donc sur la vraie
IP client.

`30-cloudflare-realip.conf` réécrit `remote_addr` à partir des en-têtes envoyés
par les plages Cloudflare. Le trafic LAN ne venant pas de Cloudflare, il n'est
pas concerné — mais les nouveaux vhosts doivent en tenir compte pour ne pas
laisser un client interne forger `X-Forwarded-For`.

---

## Les livrables

### 1 · `mikrotik/` — le dépôt de configuration du routeur

```
mikrotik/
├── README.md                    topologie, inventaire, reconstruction, constats
├── lib/ros_api.py               client API RouterOS, sans dépendance externe
├── backup.sh                    relève la conf vivante → config/current-export.rsc
├── restore.sh                   rejoue les .rsc dans l'ordre, avec filet
├── secrets.rsc.example          modèle ; le vrai fichier est gitignoré
└── config/
    ├── 00-system.rsc            identity, horloge, services IP, utilisateurs
    ├── 05-hardening.rsc         mac-server, UPnP, NTP, services inutilisés (M3, M5)
    ├── 10-interfaces.rsc        bridge, ports, listes WAN/LAN, wireless
    ├── 20-addressing.rsc        adresses, routes, pools, DHCP
    ├── 30-nat.rsc               srcnat + dstnat corrigés (M1)
    ├── 40-firewall.rsc          input / forward / output avec drop final (M2)
    ├── 50-dns.rsc               résolveur
    ├── 60-crowdsec-bgp.rsc      instance BGP, peer, filtre, utilisateur crowdsec
    └── current-state.txt        relevé de l'état vivant, produit par backup.sh
```

**Un `.rsc` par domaine plutôt qu'un export monolithique.** Un
`/export` brut de RouterOS mélange tout, se relit mal en diff, et ne se rejoue
pas partiellement. Ces fichiers sont écrits pour être appliqués isolément :
refaire le pare-feu sans toucher au DHCP doit être possible.

`backup.sh` produit à côté un relevé de l'état vivant dans
`config/current-state.txt`, comme point de comparaison entre le routeur réel et
le dépôt. Ce n'est pas un `/export` : RouterOS 6 n'expose ni `/export` ni
`/import` à l'API, et les ports 22 et 80 du routeur étaient jusqu'au correctif
M1 détournés vers le nœud. Le relevé parcourt donc les menus un par un, en
retirant compteurs et horodatages — sans quoi aucun diff ne serait lisible.

**Aucun secret n'est versionné** : mot de passe `admin`, PSK wifi et clé du
bouncer CrowdSec vivent dans `mikrotik/secrets.rsc`, ajouté au `.gitignore`.

### 2 · `mikrotik/README.md` — la procédure de reconstruction

Doit couvrir, pas à pas :

1. Reset (`/system/reset-configuration no-defaults=yes`) ou netinstall.
2. Accès initial : Winbox par MAC, ou câble sur `ether2` avec l'IP par défaut.
3. Pose de l'adresse `192.168.100.1/24` sur `bridge1` et de l'accès API.
4. `./restore.sh` depuis le poste ou le nœud.
5. Vérifications attendues à chaque étape.

Le README consigne également les six constats M1–M6 et l'état de chacun
(corrigé / documenté / hors périmètre).

### 3 · Le rôle Ansible d'exposition

Un rôle nouveau — nom proposé `edge_urbanlink` — porté par le nœud Proxmox :

- installe `python3-certbot-dns-cloudflare` ;
- dépose `/root/.secrets/cloudflare.ini` en `0600` à partir d'une variable
  chiffrée ou d'une invite ;
- obtient `*.urbanlink.fr` + `urbanlink.fr` par `certbot certonly --dns-cloudflare` ;
- écrit les vhosts nginx depuis un template unique piloté par une liste de
  services, avec le bloc `allow/deny` en commun ;
- recharge nginx après un `nginx -t` qui échoue le playbook s'il ne passe pas.

Le rôle est **idempotent et rejouable** : certbot ne redemande pas un certificat
valide, et les vhosts sont des templates.

### 4 · Les manifests Istio

- `kube/urbanlink/ingress-istio/gateway.yaml` : les 15 hosts en `urbanlink.fr`.
- `kube/urbanlink/ingress-istio/virtualservices.yaml` : un VirtualService par
  nom, dont les deux nouveaux vers `istio-system`.
- `ansible/playbooks/31-urbanlink-deploy.yml` : `urbanlink_domain: urbanlink.fr`.
- La configuration Kratos (`kube/urbanlink/_config/kratos/`) référence des URL
  publiques — elles doivent suivre le changement de domaine.

### 5 · Les correctifs MikroTik

| Réf | Correctif | Risque |
|---|---|---|
| **M1** | `dst-address=192.168.1.50` ajouté aux quatre règles `dstnat`. Requis par le design. | nul |
| **M2** | `input` : accept `established,related` → accept `icmp` → accept LAN → accept BGP depuis `192.168.100.50` → accept API/Winbox/SSH depuis les deux LAN → **drop `in-interface-list=WAN`**. `forward` : accept `established,related` → fasttrack → accept LAN→WAN → accept LAN→LAN → **drop invalid** + **drop WAN→LAN non-dstnat**. | **élevé** |
| **M3** | `mac-server` et `mac-winbox` restreints à `allowed-interface-list=LAN`. UPnP laissé actif : le nœud s'en sert pour le port-mapping Tailscale, et ses interfaces sont déjà correctement déclarées (`ether1` externe, `bridge1` interne) — le `.rsc` ne fait que rendre cet état reproductible. | faible |
| **M5** | Pool `dhcp` ramené à `192.168.100.100-192.168.100.200`. Suppression du réseau DHCP `192.0.0.0/8`. Service `api` (8728) désactivé, `api-ssl` conservé. Suppression du scheduler orphelin `CrowdsecUpdate`. | faible |

**M2 s'applique avec un filet de sécurité, sans exception.** Séquence
obligatoire :

1. `/system/backup save name=pre-firewall` ;
2. `/system/scheduler add name=rollback interval=5m on-event="/system/backup load name=pre-firewall"` ;
3. pose des règles ;
4. vérification effective de la connectivité (API, SSH vers le nœud, Internet
   depuis le poste) ;
5. suppression du scheduler.

Si l'accès est perdu à l'étape 3 ou 4, le routeur se restaure seul en cinq
minutes. Aucun déplacement physique, aucun netinstall.

---

## Hors périmètre

**M4 — le pipeline CrowdSec → MikroTik.** La session BGP est morte et le
scheduler appelle un script fantôme. Le scheduler orphelin est supprimé (c'est
du bruit pur, et sa suppression ne peut rien casser) ; le diagnostic est
consigné dans `mikrotik/README.md`. Réparer la chaîne complète est un chantier à
part entière, autant côté nœud que côté routeur, et le mêler à celui-ci rendrait
les deux illisibles.

**M6 — la mise à niveau RouterOS et RouterBOOT.** Impose un redémarrage du
routeur, donc une coupure Internet du foyer. Cela se planifie, cela ne se glisse
pas dans un lot.

**La rotation du mot de passe `admin`.** Le mot de passe a circulé en clair dans
la conversation de conception. Il n'entre dans aucun fichier versionné, mais il
doit être changé une fois le travail livré. Recommandation associée : remplacer
`admin` (`group=full`, `address=` vide) par un compte nommé restreint à
`192.168.1.0/24,192.168.100.0/24`.

**CrowdSec dans le mesh Istio.** Inchangé, et le constat de `kube/README.md`
reste valable : il n'existe pas de bouncer Envoy utilisable. CrowdSec continue
de filtrer à l'endroit où le trafic Internet arrive réellement — l'openresty du
nœud — qui est aussi le point d'entrée de ce design.

---

## Vérification

Le travail n'est terminé que si chacun de ces points est constaté, pas supposé.

| # | Vérification | Attendu |
|---|---|---|
| 1 | `nslookup pgadmin.urbanlink.fr` depuis le poste | `192.168.100.50` |
| 2 | `curl -I https://pgadmin.urbanlink.fr` depuis le poste | `200` ou `302`, **sans** `-k` |
| 3 | Chaîne du certificat | émetteur Let's Encrypt, SAN `*.urbanlink.fr` |
| 4 | Les 15 noms, un par un | code HTTP attendu pour chacun, aucun `502` |
| 5 | `curl` depuis une source hors LAN vers l'IP du nœud avec `Host: pgadmin.urbanlink.fr` | `403` |
| 6 | `router.urbanlink.fr` | webfig du MikroTik, **pas** l'openresty (prouve M1) |
| 7 | `restore.sh` sur la configuration relevée | aucune erreur, `backup.sh` produit ensuite un diff vide |
| 8 | Depuis le poste après M2 : SSH vers le nœud, API MikroTik, navigation Internet | tout répond |
| 9 | Depuis le WAN après M2 : nbeny.fr et ses sous-domaines | toujours servis (la box redirige toujours 80/443) |
| 10 | `ansible-playbook` du rôle rejoué une seconde fois | `changed=0` |

Le point 10 est la condition d'acceptation qui compte : le dépôt tient sa
promesse de reconstructibilité seulement si rejouer ne change rien.

---

## Risques

| Risque | Portée | Parade |
|---|---|---|
| Perte d'accès au routeur en posant le pare-feu (M2) | Coupure Internet du foyer | Backup + scheduler de restauration à 5 min, supprimé après vérification |
| Le token Cloudflare fuit | Modification de la zone DNS | Token limité à `Zone:DNS:Edit` sur la seule zone `urbanlink.fr`, fichier en `0600`, jamais versionné |
| M1 casse un accès existant | `nbeny.fr` et l'accès SSH depuis Internet | Les règles conservent `in-interface=ether1` ; `dst-address=192.168.1.50` est l'adresse que la box cible déjà. Vérification n° 9 |
| Le changement de domaine casse Kratos | Authentification hors service | Les URL Kratos sont mises à jour dans le même lot ; le stack est redéployé et l'état des pods relevé |
| Le certificat wildcard ne couvre pas l'apex | `urbanlink.fr` sans certificat | Certbot demande `-d urbanlink.fr -d *.urbanlink.fr` : un wildcard ne couvre pas son propre apex |
