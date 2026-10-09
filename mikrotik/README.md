# MikroTik — configuration versionnée du routeur

Le routeur du lab, décrit en fichiers rejouables. De quoi le reconstruire à
l'identique après une remise à zéro, et de quoi voir en un `git diff` ce qui a
dérivé entre le matériel et le dépôt.

---

## Le matériel

| | |
|---|---|
| Modèle | hAP ac² — `RBD52G-5HacD2HnD` |
| Numéro de série | `D7160DC9D484` |
| Adresse MAC | `08:55:31:9D:75:4D` (utile pour Winbox par MAC) |
| RouterOS | 6.49.4 (stable, février 2022) |
| RouterBOOT | 6.45.9 — **en retard sur RouterOS**, voir M6 |
| Processeur | ARMv7 4 × 716 MHz |
| Mémoire | 128 Mo — 78 Mo libres au relevé |
| Flash | 16 Mo — **2,1 Mo libres**, de quoi tenir deux sauvegardes, pas plus |
| Paquet `ipv6` | désactivé |

---

## Où il se trouve

```
Internet  82.65.87.60
    │
Box FAI 192.168.1.254 ── DHCP ── poste de travail 192.168.1.89
    │                            (route statique persistante
    │                             192.168.100.0/24 → 192.168.1.50)
    │
MikroTik hAP ac²
    ether1  = 192.168.1.50/24  (bail DHCP de la box)   ← liste WAN
    bridge1 = 192.168.100.1/24                         ← liste LAN
              ether2-5 + wlan1 + wlan2
    route statique 10.0.0.0/24 → 192.168.100.50
    │
Proxmox `pve`  192.168.100.50 (vmbr0) · 10.0.0.1 (vmbr1)
    │
    10.0.0.0/24 — les VMs du lab
```

**Son rôle est étroit, et c'est voulu.** Il route entre le LAN de la maison et
le segment du lab, publie quatre ports vers le nœud Proxmox, et masque les
sorties Internet. Il ne fait **ni DNS ni terminaison TLS** : le résolveur reste
la box, et le TLS est terminé par l'openresty du nœud. Lui donner ces rôles
ajouterait deux points de panne sur un boîtier à 128 Mo de RAM.

Sa seule fonction de sécurité propre est le pare-feu, plus le blocage BGP
alimenté par CrowdSec — qui ne fonctionne pas, voir **M4**.

---

## S'y connecter

Les services de gestion sont restreints à `192.168.100.0/24` et
`192.168.1.0/24`. Depuis Internet, rien ne répond.

| Accès | Adresse | Note |
|---|---|---|
| **API TLS** (8729) | `192.168.100.1` | Ce qu'utilisent les scripts de ce répertoire |
| Winbox (8291) | `192.168.1.50` ou `192.168.100.1` | Interface graphique MikroTik |
| SSH (22) | `192.168.100.1` **uniquement** | Voir l'avertissement ci-dessous |
| Webfig (80) | `192.168.100.1`, depuis le nœud seul | Publié sous `router.urbanlink.fr` |

> **Le port 22 de `192.168.1.50` ne mène pas au routeur.** Une règle `dstnat`
> le redirige vers le nœud Proxmox — c'est délibéré, `ssh root@192.168.1.50`
> doit atteindre `pve`. Pour joindre le routeur en SSH, viser `192.168.100.1`.

Le certificat d'`api-ssl` est anonyme (`certificate=none`) : RouterOS négocie
en Diffie-Hellman anonyme. La session est chiffrée mais le serveur n'est pas
authentifié. `lib/ros_api.py` abaisse le niveau de sécurité d'OpenSSL en
conséquence. C'est acceptable sur un segment à deux machines ; ça ne le serait
pas ailleurs.

---

## Utilisation

```bash
cp secrets.rsc.example secrets.env    # puis renseigner MIKROTIK_PASSWORD
chmod 600 secrets.env

./backup.sh                            # relève l'état vivant
./restore.sh                           # rejoue toute la configuration
./restore.sh 30-nat.rsc                # un seul fichier
```

Après toute modification faite à la main sur le routeur :

```bash
./backup.sh && git diff config/current-state.txt
```

Un diff non vide signale que le matériel et le dépôt ont divergé. Soit la
modification est voulue et il faut la porter dans le `.rsc` correspondant, soit
elle ne l'est pas et `./restore.sh` la reprend.

### Ce que contient chaque fichier

| Fichier | Contenu |
|---|---|
| `config/00-system.rsc` | Identité, horloge, services de gestion, utilisateurs et groupes |
| `config/05-hardening.rsc` | MAC-server, UPnP, NTP, services inutilisés — les correctifs M3 et M5 |
| `config/10-interfaces.rsc` | Bridge et ses ports, listes WAN/LAN, radios |
| `config/20-addressing.rsc` | Adresses, routes, pool et serveur DHCP |
| `config/30-nat.rsc` | Masquerade en sortie, publications vers le nœud |
| `config/40-firewall.rsc` | Chaînes `input`, `forward`, `output` |
| `config/50-dns.rsc` | Résolveur — volontairement fermé |
| `config/60-crowdsec-bgp.rsc` | Instance BGP, pair, filtre |
| `config/current-state.txt` | Relevé de l'état vivant, produit par `backup.sh` |

**Un fichier par domaine, pas un export monolithique.** Un `/export` brut de
RouterOS mélange tout, se relit mal en diff et ne se rejoue pas partiellement.
Ces fichiers sont écrits pour être appliqués isolément : refaire le pare-feu
sans toucher au DHCP doit être possible — et l'est.

**Ils sont idempotents.** Les menus de type liste commencent par
`remove [find where dynamic=no]` puis réajoutent tout : le fichier fait
autorité, le rejouer ne duplique rien. Le filtre `dynamic=no` est
indispensable — les règles créées par UPnP et le compteur fasttrack ne sont pas
supprimables et feraient échouer le script. Pour les utilisateurs, on teste
l'existence : un `remove [find]` effacerait `admin` et fermerait la porte.

### Comment ça marche

RouterOS 6 n'expose **ni `/export` ni `/import`** à son API. Deux conséquences,
qui expliquent la forme de ces scripts :

- `restore.sh` passe par `/system/script`. Un script RouterOS accepte
  exactement la même syntaxe qu'un `.rsc` : `ros_apply.py` en crée un
  temporaire, l'exécute, puis le supprime — y compris si l'exécution échoue.
  Les erreurs de syntaxe comme d'exécution remontent en `!trap`.
- `backup.sh` ne produit pas un export mais un **relevé menu par menu**. Les
  compteurs, horodatages et identifiants internes en sont retirés : sans ça,
  deux relevés successifs différeraient toujours et le fichier ne servirait à
  rien comme point de comparaison.

---

## Reconstruire le routeur

1. **Remettre à zéro.**

   ```
   /system reset-configuration no-defaults=yes skip-backup=yes
   ```

   Si le routeur ne répond plus du tout : netinstall, en maintenant le bouton
   de reset au démarrage.

2. **Retrouver un accès.** Winbox se connecte par adresse MAC —
   `08:55:31:9D:75:4D` — sans qu'aucune IP soit configurée. Brancher le poste
   sur `ether2`.

3. **Poser l'accès minimal**, dans le terminal Winbox :

   ```
   /interface bridge add name=bridge1
   /interface bridge port add bridge=bridge1 interface=ether2
   /ip address add address=192.168.100.1/24 interface=bridge1
   /ip service set api-ssl address=192.168.100.0/24 disabled=no
   /user set [find where name="admin"] password="..."
   ```

4. **Rejouer la configuration**, depuis une machine du segment lab :

   ```bash
   cd mikrotik
   cp secrets.rsc.example secrets.env    # puis renseigner
   ./restore.sh
   ```

5. **Appliquer les secrets** — mots de passe et clés WPA, qui ne sont pas
   versionnés :

   ```bash
   python3 lib/ros_apply.py secrets.rsc
   ```

6. **Vérifier :**

   ```bash
   ./backup.sh && git diff config/current-state.txt
   ```

   Un diff vide signifie que le routeur est revenu à l'état décrit par le dépôt.

> **L'ordre des fichiers compte.** `10-interfaces.rsc` crée les listes `WAN` et
> `LAN` que `30-nat.rsc` et `40-firewall.rsc` référencent. `restore.sh` les
> applique dans l'ordre de leur numéro ; ne pas les rejouer à la main dans le
> désordre.

---

## Ce qui n'est pas versionné

`secrets.env` et `secrets.rsc` sont dans `.gitignore` et ne doivent jamais y
sortir. Ils contiennent :

- le mot de passe du compte `admin` ;
- le mot de passe du compte `crowdsec` ;
- les clés WPA du profil wireless `default`.

`config/current-state.txt` est produit avec ces champs caviardés — `backup.sh`
les remplace par `<SECRET>`. Si un champ sensible venait à apparaître en clair
dans un relevé, l'ajouter à l'ensemble `SECRET` de `lib/ros_dump.py`.

---

## Constats relevés le 30 août 2026

Relevés sur le matériel, pas déduits de la documentation.

| Réf | Constat | État |
|---|---|---|
| **M1** | Les quatre règles `dstnat` (22, 80, 443, 4242) portaient `in-interface=ether1` sans aucun `dst-address`. Toute requête du LAN vers **n'importe quelle** IP du segment lab sur ces ports était détournée vers `192.168.100.50` — le webfig du routeur lui-même était inatteignable. | **corrigé** — `30-nat.rsc` |
| **M2** | Les chaînes `input` et `forward` ne contenaient que des `accept`, aucun `drop` final. La politique par défaut de RouterOS étant `accept`, le routeur n'avait pas de pare-feu. | **corrigé** — `40-firewall.rsc` |

### M2 — vérification du pare-feu

Un pare-feu qu'on n'a pas vu bloquer n'est pas prouvé. Le `drop` de la chaîne
`input` a été testé activement : une connexion depuis le poste (`192.168.1.89`,
donc côté WAN) vers `192.168.100.1:8728`, port absent de la liste
d'administration, expire — et le compteur de la règle passe de 0 à 3 paquets.
Un `drop`, pas un `reject` : la connexion expire au lieu d'être refusée, ce qui
ne renseigne pas un scanneur sur l'existence de l'hôte.

Les compteurs relevés juste après la pose confirment que le trafic légitime
emprunte bien les règles prévues :

| Chaîne | Règle | Paquets |
|---|---|---|
| `input` | administration depuis le LAN maison | 3 |
| `input` | segment lab | 1 |
| `forward` | LAN maison → segment lab | 56 |
| `forward` | lab → Internet | 15 |
| `input` | **drop WAN** | 3 (au test) |

Le `drop` de la chaîne `forward` reste à zéro, et c'est attendu : la box FAI ne
redirige vers le routeur que les ports 22, 80, 443, 3724 et 8091 (Turtle WoW),
tous couverts par une règle `dstnat` (4242 retiré le 2026-10-09 avec la VM 102). Rien d'autre n'atteint le routeur depuis Internet.
| **M3** | `/tool/mac-server` et `/tool/mac-server/mac-winbox` étaient sur `allowed-interface-list=all`. MAC-telnet et MAC-Winbox opèrent en couche 2 : aucune règle de pare-feu ne les arrête. | **corrigé** — `05-hardening.rsc` |
| **M4** | La chaîne de blocage CrowdSec → MikroTik ne fonctionne pas. Détail ci-dessous. | **documenté, non corrigé** |
| **M5** | Pool DHCP `192.168.100.0-200`, incluant l'adresse réseau **et la passerelle**. Entrée réseau fantôme `192.0.0.0/8`. API en clair (8728) activée. Scheduler orphelin. | **corrigé** — `20-addressing.rsc`, `05-hardening.rsc`, `00-system.rsc` |
| **M6** | RouterBOOT 6.45.9 sous un RouterOS 6.49.4 daté de février 2022. | **hors périmètre** |

### M4 — la chaîne CrowdSec est morte

Le nœud Proxmox (AS 65001) est censé annoncer en BGP les adresses à bloquer,
que le routeur (AS 65002) installe en routes blackhole via le filtre
`crowdsec-in`. Au relevé :

- la session `CrowdSec-Bouncer` est en `state=active, established=false` — le
  routeur tente la connexion, le pair ne répond pas ;
- côté nœud, les bouncers `cs-mikrotik-bouncer`, `mikrotik-final` et
  `exabgp-mikrotik` sont bien enregistrés dans CrowdSec, et `exabgp-mikrotik`
  fait ses pulls d'API normalement ;
- un scheduler `CrowdsecUpdate` appelait toutes les 15 minutes un script
  `crowdsec_import` **absent de `/system/script`** — 576 exécutions en échec
  silencieux.

Le maillon manquant est donc entre exabgp et le port 179 du routeur, pas dans
CrowdSec lui-même. Le scheduler orphelin a été supprimé : il ne produisait que
du bruit.

Pour reprendre le sujet : vérifier que le pair BGP écoute côté nœud
(`ss -tlnp | grep 179`), puis sur le routeur
`/routing bgp peer print status`. La règle `input` autorisant le port 179
depuis `192.168.100.50` est en place, ce n'est pas elle qui bloque.

### M6 — le firmware

La mise à niveau de RouterOS et de RouterBOOT impose un redémarrage du routeur,
donc une coupure Internet du foyer. Elle se planifie, elle ne se glisse pas
dans un lot. La séquence, le jour venu :

```
/system package update check-for-updates
/system package update install        # redémarre
/system routerboard upgrade           # puis redémarrer une seconde fois
```

Passer en RouterOS 7 est possible sur ce modèle (128 Mo suffisent) et
apporterait l'API REST — mais change le moteur de routage BGP, donc la
configuration de `60-crowdsec-bgp.rsc`.

---

## Écarts assumés

**WPA1 a été retiré du profil wireless.** Le relevé acceptait
`wpa-psk,wpa2-psk` ; `10-interfaces.rsc` n'écrit que `wpa2-psk`. Si un appareil
ancien du foyer ne se connecte plus, remettre `wpa-psk,wpa2-psk` dans ce
fichier — et le noter ici.

**Huit règles de masquerade sont devenues une.** Le relevé en contenait huit,
quasi identiques, empilées au fil du temps. `30-nat.rsc` n'en écrit qu'une, sur
`out-interface-list=WAN`, qui couvre les huit.

**UPnP reste actif.** Le nœud s'en sert pour le port-mapping de Tailscale ; le
couper dégraderait la traversée NAT sans rien gagner. Ses interfaces étaient
déjà correctement déclarées (`ether1` externe, `bridge1` interne) — le `.rsc`
ne fait que rendre cet état reproductible.
