# Exposition des outils sous `*.urbanlink.fr` — plan d'implémentation

> **Pour un agent exécutant :** utiliser `superpowers:subagent-driven-development`
> ou `superpowers:executing-plans`. Les étapes sont des cases à cocher.

**But :** rendre les quinze outils du lab joignables depuis le poste Windows sur
un sous-domaine de `urbanlink.fr`, en TLS valide, sans les exposer à Internet — et
versionner la configuration du MikroTik pour pouvoir la reconstruire.

**Architecture :** un enregistrement DNS public pointe sur une IP privée ;
l'openresty du nœud Proxmox termine le TLS avec un wildcard Let's Encrypt obtenu
par challenge DNS-01, filtre sur l'adresse source, puis relaie vers la passerelle
Istio qui route par `Host`. Le MikroTik ne fait plus que du routage entre les deux
segments, avec un pare-feu qui n'existait pas.

**Pile :** RouterOS 6.49.4 (API binaire sur 8729), nginx/openresty, certbot +
`dns-cloudflare`, Ansible, Istio 1.30.4, Kustomize.

**Conception :** [`docs/superpowers/specs/2026-08-30-urbanlink-fr-sous-domaines-design.md`](../specs/2026-08-30-urbanlink-fr-sous-domaines-design.md)

---

## Prérequis à obtenir avant la tâche 7

Un **token API Cloudflare** portant exactement `Zone:DNS:Edit` sur la zone
`urbanlink.fr` et rien d'autre. À créer sur
`https://dash.cloudflare.com/profile/api-tokens` → *Create Token* → *Edit zone
DNS* → *Zone Resources: Include → Specific zone → urbanlink.fr*.

Les tâches 1 à 6 ne l'exigent pas et peuvent être menées sans.

---

## Structure des fichiers

| Fichier | Responsabilité |
|---|---|
| `mikrotik/lib/ros_api.py` | Protocole API RouterOS : encodage des longueurs, phrases, login. Rien d'autre. |
| `mikrotik/lib/ros_apply.py` | Applique un `.rsc` en le passant par `/system/script`. Nettoie toujours. |
| `mikrotik/lib/ros_dump.py` | Relève les menus et écrit `config/current-state.txt`. |
| `mikrotik/backup.sh` | Enveloppe de `ros_dump.py`. |
| `mikrotik/restore.sh` | Enveloppe de `ros_apply.py`, applique `config/*.rsc` dans l'ordre. |
| `mikrotik/config/*.rsc` | La configuration, un fichier par domaine, idempotent. |
| `mikrotik/secrets.rsc.example` | Modèle des secrets. Le vrai fichier est ignoré par git. |
| `mikrotik/README.md` | Topologie, inventaire, reconstruction, constats M1–M6. |
| `ansible/roles/edge_urbanlink/` | Certificat wildcard + vhosts nginx sur le nœud. |
| `ansible/playbooks/32-urbanlink-edge.yml` | Point d'entrée du rôle. |
| `kube/urbanlink/ingress-istio/*.yaml` | Les quatorze hosts servis par Istio. `proxmox` et `router` n'y sont pas. |

`ros_api.py` ne connaît que le protocole ; `ros_apply.py` ne connaît que
l'application d'un fichier ; `ros_dump.py` ne connaît que la lecture. Chacun est
utilisable seul et testable seul.

---

## Convention commune aux scripts Python

Les trois lisent les mêmes variables d'environnement :

| Variable | Défaut | Rôle |
|---|---|---|
| `MIKROTIK_HOST` | `192.168.100.1` | Adresse du routeur |
| `MIKROTIK_USER` | `admin` | Compte API |
| `MIKROTIK_PASSWORD` | — (obligatoire) | Mot de passe |

`backup.sh` et `restore.sh` chargent `mikrotik/secrets.env` s'il existe. Ce
fichier est **gitignoré** — le mot de passe ne doit jamais atteindre un commit.

---

## Tâche 1 : outillage du dépôt MikroTik

**Fichiers :**
- Créer : `mikrotik/lib/ros_api.py`
- Créer : `mikrotik/lib/ros_dump.py`
- Créer : `mikrotik/backup.sh`
- Créer : `mikrotik/secrets.rsc.example`
- Créer : `mikrotik/.gitignore`

- [ ] **Étape 1 : écrire le client de protocole**

`mikrotik/lib/ros_api.py` :

```python
#!/usr/bin/env python3
"""Client de l'API binaire RouterOS (port 8728 en clair, 8729 en TLS).

Ne connait que le protocole : encodage des longueurs, phrases, login.
Aucune dependance hors bibliotheque standard -- le depot doit rester
utilisable depuis n'importe quelle machine du lab.
"""
import os
import socket
import ssl


class RosApiError(Exception):
    """Le routeur a renvoye !trap ou !fatal."""


def _enc_len(n):
    if n < 0x80:
        return bytes([n])
    if n < 0x4000:
        return (n | 0x8000).to_bytes(2, "big")
    if n < 0x200000:
        return (n | 0xC00000).to_bytes(3, "big")
    if n < 0x10000000:
        return (n | 0xE0000000).to_bytes(4, "big")
    return b"\xf0" + n.to_bytes(4, "big")


class Ros:
    def __init__(self, host, port=8729, use_ssl=True, timeout=15):
        sock = socket.create_connection((host, port), timeout=timeout)
        if use_ssl:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            # Sans certificat associe au service api-ssl, RouterOS negocie en
            # anonyme (ADH) : OpenSSL le refuse au niveau de securite par
            # defaut, il faut l'abaisser explicitement.
            try:
                ctx.set_ciphers("ADH:@SECLEVEL=0")
            except ssl.SSLError:
                ctx.set_ciphers("DEFAULT:@SECLEVEL=0")
            sock = ctx.wrap_socket(sock)
        self.sock = sock
        self.buf = b""

    # --- couche octets ----------------------------------------------------
    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RosApiError("connexion fermee par le routeur")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _read_len(self):
        b0 = self._read(1)[0]
        if b0 & 0x80 == 0:
            return b0
        if b0 & 0xC0 == 0x80:
            return ((b0 & 0x3F) << 8) + self._read(1)[0]
        if b0 & 0xE0 == 0xC0:
            return ((b0 & 0x1F) << 16) + int.from_bytes(self._read(2), "big")
        if b0 & 0xF0 == 0xE0:
            return ((b0 & 0x0F) << 24) + int.from_bytes(self._read(3), "big")
        return int.from_bytes(self._read(4), "big")

    # --- couche phrases ---------------------------------------------------
    def send(self, words):
        out = b"".join(_enc_len(len(w.encode())) + w.encode() for w in words)
        self.sock.sendall(out + b"\x00")

    def read_sentence(self):
        words = []
        while True:
            n = self._read_len()
            if n == 0:
                return words
            words.append(self._read(n).decode(errors="replace"))

    def talk(self, words):
        """Envoie une commande, renvoie la liste des lignes de reponse."""
        self.send(words)
        replies = []
        while True:
            sentence = self.read_sentence()
            if not sentence:
                continue
            tag, attrs = sentence[0], {}
            for w in sentence[1:]:
                if w.startswith("="):
                    k, _, v = w[1:].partition("=")
                    attrs[k] = v
            if tag == "!done":
                if attrs:
                    replies.append(attrs)
                return replies
            if tag in ("!trap", "!fatal"):
                raise RosApiError(attrs.get("message", " ".join(sentence)))
            replies.append(attrs)

    def login(self, user, password):
        self.talk(["/login", f"=name={user}", f"=password={password}"])

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def connect_from_env():
    """Ouvre une session a partir de MIKROTIK_HOST / _USER / _PASSWORD."""
    password = os.environ.get("MIKROTIK_PASSWORD")
    if not password:
        raise SystemExit(
            "MIKROTIK_PASSWORD n'est pas defini.\n"
            "Renseigne mikrotik/secrets.env (voir secrets.rsc.example) "
            "ou exporte la variable."
        )
    ros = Ros(os.environ.get("MIKROTIK_HOST", "192.168.100.1"))
    ros.login(os.environ.get("MIKROTIK_USER", "admin"), password)
    return ros
```

- [ ] **Étape 2 : vérifier que le client parle au routeur**

```bash
cd mikrotik
MIKROTIK_PASSWORD='<le mot de passe admin>' python -c "
import sys; sys.path.insert(0, 'lib')
from ros_api import connect_from_env
r = connect_from_env()
print(r.talk(['/system/resource/print'])[0]['version'])
"
```

Attendu : `6.49.4 (stable)`

> **Piège Git Bash.** Les arguments commençant par `/` sont convertis en chemins
> Windows. Toujours exporter `MSYS_NO_PATHCONV=1` avant de passer une commande
> RouterOS en argument de ligne de commande.

- [ ] **Étape 3 : écrire le relevé de configuration**

`mikrotik/lib/ros_dump.py` :

```python
#!/usr/bin/env python3
"""Releve la configuration vivante du routeur, menu par menu.

Produit un fichier texte destine a etre compare aux .rsc versionnes :
RouterOS 6 n'expose pas /export via l'API, ce relevé en tient lieu.
"""
import sys
from ros_api import connect_from_env, RosApiError

MENUS = [
    "/system/routerboard/print", "/system/package/print",
    "/system/clock/print", "/system/ntp/client/print",
    "/system/scheduler/print", "/system/script/print",
    "/interface/print", "/interface/bridge/print", "/interface/bridge/port/print",
    "/interface/wireless/print", "/interface/wireless/security-profiles/print",
    "/interface/list/print", "/interface/list/member/print",
    "/ip/address/print", "/ip/route/print", "/ip/pool/print",
    "/ip/dhcp-server/print", "/ip/dhcp-server/network/print",
    "/ip/dhcp-server/lease/print", "/ip/dhcp-client/print",
    "/ip/dns/print", "/ip/dns/static/print",
    "/ip/firewall/filter/print", "/ip/firewall/nat/print",
    "/ip/firewall/mangle/print", "/ip/firewall/address-list/print",
    "/ip/service/print", "/ip/cloud/print", "/ip/upnp/print",
    "/ip/upnp/interfaces/print", "/ip/proxy/print", "/ip/socks/print",
    "/user/print", "/user/group/print",
    "/tool/mac-server/print", "/tool/mac-server/mac-winbox/print",
    "/tool/romon/print", "/tool/netwatch/print", "/snmp/print",
    "/certificate/print",
    "/routing/bgp/instance/print", "/routing/bgp/peer/print",
    "/routing/filter/print",
]

# Champs qui changent a chaque lecture : les garder rendrait tout diff illisible.
VOLATILE = {
    "rx-byte", "tx-byte", "rx-packet", "tx-packet", "fp-rx-byte", "fp-tx-byte",
    "fp-rx-packet", "fp-tx-packet", "bytes", "packets", "rx-drop", "tx-drop",
    "tx-queue-drop", "rx-error", "tx-error", "uptime", "free-memory",
    "cpu-load", "free-hdd-space", "write-sect-since-reboot", "write-sect-total",
    "last-logged-in", "last-link-up-time", "last-link-down-time", "link-downs",
    "expires-after", "run-count", "next-run", "time", "date", "cache-used",
    "debug-info", "state", "established", "gateway-status", "next-run",
}
SECRET = {"password", "wpa-pre-shared-key", "wpa2-pre-shared-key",
          "tcp-md5-key", "nv2-preshared-key", "static-key-0", "secrets"}


def main():
    out = sys.stdout
    ros = connect_from_env()
    out.write("# Releve de la configuration vivante du MikroTik.\n")
    out.write("# Genere par mikrotik/backup.sh -- ne pas editer a la main.\n")
    out.write("# Compteurs et horodatages sont retires, secrets caviardes.\n")
    for menu in MENUS:
        out.write("\n" + "=" * 78 + "\n## " + menu + "\n" + "=" * 78 + "\n")
        try:
            rows = ros.talk([menu])
        except RosApiError as exc:
            out.write(f"  !! {exc}\n")
            continue
        if not rows:
            out.write("  (vide)\n")
            continue
        for row in rows:
            parts = []
            for k, v in row.items():
                if k in VOLATILE:
                    continue
                parts.append(f"{k}=<SECRET>" if k in SECRET else f"{k}={v}")
            out.write("  " + " ".join(parts) + "\n")
    ros.close()


if __name__ == "__main__":
    main()
```

- [ ] **Étape 4 : écrire l'enveloppe shell**

`mikrotik/backup.sh` :

```bash
#!/usr/bin/env bash
# Releve la configuration vivante du routeur dans config/current-state.txt.
#
#   ./backup.sh
#
# Le fichier produit est fait pour etre compare d'une fois sur l'autre :
# compteurs, horodatages et secrets en sont retires.
set -euo pipefail

cd "$(dirname "$0")"
# `[ -f x ] && . x` seul ferait sortir le script sous `set -e` quand le
# fichier n'existe pas : le test renvoie 1 et devient le code de retour.
if [ -f secrets.env ]; then . ./secrets.env; fi

mkdir -p config
python3 lib/ros_dump.py > config/current-state.txt
echo "config/current-state.txt : $(wc -l < config/current-state.txt) lignes"
```

- [ ] **Étape 5 : écrire le modèle de secrets et l'exclusion git**

`mikrotik/secrets.rsc.example` :

```
# Copier en secrets.env (variables d'environnement, pour les scripts)
# et/ou secrets.rsc (commandes RouterOS, pour une reconstruction complete).
# Les deux sont ignores par git -- aucun secret ne doit atteindre un commit.
#
# --- secrets.env -----------------------------------------------------------
# export MIKROTIK_HOST=192.168.100.1
# export MIKROTIK_USER=admin
# export MIKROTIK_PASSWORD='...'
#
# --- secrets.rsc -----------------------------------------------------------
# A appliquer manuellement apres restore.sh sur un routeur remis a zero.
#
# /user set [find name="admin"] password="..."
# /user set [find name="crowdsec"] password="..."
# /interface wireless security-profiles set [find name="default"] \
#     wpa-pre-shared-key="..." wpa2-pre-shared-key="..."
```

`mikrotik/.gitignore` :

```
secrets.env
secrets.rsc
```

- [ ] **Étape 6 : produire le premier relevé**

```bash
cd mikrotik
printf "export MIKROTIK_PASSWORD='%s'\n" '<le mot de passe admin>' > secrets.env
chmod 600 secrets.env
./backup.sh
```

Attendu : `config/current-state.txt :` suivi d'un nombre de lignes compris
entre 150 et 400.

- [ ] **Étape 7 : vérifier qu'aucun secret n'a fuité**

```bash
grep -nE "Lokiu|pre-shared-key=[^<]|password=[^<]" mikrotik/config/current-state.txt
```

Attendu : **aucune sortie**. Si une ligne remonte, ajouter le champ à `SECRET`
dans `ros_dump.py` et relancer `./backup.sh` avant de committer.

- [ ] **Étape 8 : vérifier que le relevé est stable**

```bash
cd mikrotik && cp config/current-state.txt /tmp/a.txt && ./backup.sh && diff /tmp/a.txt config/current-state.txt && echo "STABLE"
```

Attendu : `STABLE`. Un diff non vide signale un champ volatil oublié — l'ajouter
à `VOLATILE` et recommencer. Sans cette stabilité, le relevé ne sert à rien
comme point de comparaison.

- [ ] **Étape 9 : committer**

```bash
git add mikrotik/
git commit -m "feat(mikrotik): client API, releve de configuration et exclusion des secrets"
```

---

## Tâche 2 : la configuration en fichiers `.rsc`

Ces fichiers décrivent **l'état actuel**, correctifs non compris. Les correctifs
arrivent aux tâches 4 à 6, et le diff de ce commit-là sera la trace exacte de ce
qui a changé sur le routeur.

**Fichiers :**
- Créer : `mikrotik/config/00-system.rsc`
- Créer : `mikrotik/config/10-interfaces.rsc`
- Créer : `mikrotik/config/20-addressing.rsc`
- Créer : `mikrotik/config/30-nat.rsc`
- Créer : `mikrotik/config/40-firewall.rsc`
- Créer : `mikrotik/config/50-dns.rsc`
- Créer : `mikrotik/config/60-crowdsec-bgp.rsc`
- Créer : `mikrotik/lib/ros_apply.py`
- Créer : `mikrotik/restore.sh`

**Convention d'idempotence.** Pour les menus de type liste (règles de pare-feu,
NAT, entrées DNS), le fichier commence par `remove [find where dynamic=no]` puis
réajoute tout : le fichier fait autorité, et le rejouer ne duplique rien. Le
filtre `dynamic=no` est indispensable — les règles dynamiques créées par UPnP et
par le compteur fasttrack ne sont pas supprimables et feraient échouer le script.
Pour les menus singleton, `set` est naturellement idempotent. Pour les
utilisateurs, on teste l'existence : un `remove [find]` effacerait `admin`.

- [ ] **Étape 1 : `00-system.rsc`**

```
# ============================================================================
#  Identite, horloge, services de gestion, utilisateurs
# ============================================================================

/system identity set name=MikroTik

/system clock set time-zone-autodetect=yes time-zone-name=Europe/Paris

# --- Services de gestion ---------------------------------------------------
# Regle : rien n'ecoute sans restriction d'adresse.
#
# Ce fichier decrit l'etat RELEVE. Deux lignes changeront plus loin dans le
# plan, chacune avec sa verification :
#   - `www` est active et restreint au noeud a la tache 4 (M1), pour que
#     nginx puisse publier le webfig sous router.urbanlink.fr ;
#   - `api` est desactive a la tache 5 (M5).
/ip service set telnet   disabled=yes
/ip service set ftp      disabled=yes
/ip service set www      disabled=yes
/ip service set www-ssl  disabled=yes
/ip service set ssh      address=192.168.1.0/24,192.168.100.0/24 disabled=no
/ip service set winbox   address=192.168.1.0/24,192.168.100.0/24 disabled=no
/ip service set api-ssl  address=192.168.1.0/24,192.168.100.0/24 disabled=no
/ip service set api      address=192.168.1.0/24,192.168.100.0/24 disabled=no

# --- Utilisateurs ----------------------------------------------------------
# Pas de `remove [find]` ici : il emporterait le compte admin et fermerait la
# porte derriere lui.
:if ([:len [/user group find where name="crowdsec"]] = 0) do={
    /user group add name=crowdsec \
        policy=read,write,test,api,!local,!telnet,!ssh,!ftp,!reboot,!policy,!winbox,!password,!web,!sniff,!sensitive,!romon,!dude,!tikapp
} else={
    /user group set [find where name="crowdsec"] \
        policy=read,write,test,api,!local,!telnet,!ssh,!ftp,!reboot,!policy,!winbox,!password,!web,!sniff,!sensitive,!romon,!dude,!tikapp
}
:if ([:len [/user find where name="crowdsec"]] = 0) do={
    /user add name=crowdsec group=crowdsec
}

# Les mots de passe vivent dans secrets.rsc, applique separement.
```

- [ ] **Étape 2 : `10-interfaces.rsc`**

```
# ============================================================================
#  Interfaces : bridge, ports, listes, wireless
# ============================================================================
# ether1 est l'uplink vers la box FAI. ether2-5 et les deux radios sont
# agreges dans bridge1, qui porte le segment 192.168.100.0/24.

:if ([:len [/interface bridge find where name="bridge1"]] = 0) do={
    /interface bridge add name=bridge1 protocol-mode=rstp fast-forward=yes
}

/interface bridge port remove [find where dynamic=no]
/interface bridge port
add bridge=bridge1 interface=ether2
add bridge=bridge1 interface=ether3
add bridge=bridge1 interface=ether4
add bridge=bridge1 interface=ether5
add bridge=bridge1 interface=wlan1
add bridge=bridge1 interface=wlan2

# Les listes WAN et LAN sont referencees par le pare-feu et le NAT : elles
# doivent exister avant 30-nat.rsc et 40-firewall.rsc.
:if ([:len [/interface list find where name="WAN"]] = 0) do={ /interface list add name=WAN }
:if ([:len [/interface list find where name="LAN"]] = 0) do={ /interface list add name=LAN }
/interface list member remove [find where dynamic=no]
/interface list member add list=WAN interface=ether1
/interface list member add list=LAN interface=bridge1

# --- Wireless --------------------------------------------------------------
# Les cles WPA vivent dans secrets.rsc.
/interface wireless security-profiles set [find where name="default"] \
    mode=dynamic-keys authentication-types=wpa2-psk \
    unicast-ciphers=aes-ccm group-ciphers=aes-ccm

/interface wireless set [find where default-name="wlan1"] \
    mode=ap-bridge ssid=MikroTik band=2ghz-b/g channel-width=20mhz \
    frequency=2412 country=etsi security-profile=default disabled=no
/interface wireless set [find where default-name="wlan2"] \
    mode=ap-bridge ssid=MikroTik band=5ghz-a channel-width=20mhz \
    frequency=5180 country=etsi security-profile=default disabled=no
```

> **Note fidèle à l'état relevé :** la sécurité wireless est en
> `wpa-psk,wpa2-psk`. Ce fichier écrit `wpa2-psk` seul — WPA1 est cassé depuis
> longtemps et aucun client du foyer ne devrait en dépendre. Si un appareil
> ancien tombe, remettre `wpa-psk,wpa2-psk` et le noter dans le README.

- [ ] **Étape 3 : `20-addressing.rsc`**

```
# ============================================================================
#  Adressage : adresses, routes, pools, DHCP
# ============================================================================
# ether1 prend son adresse de la box (192.168.1.50/24 en pratique).
# bridge1 porte la passerelle du segment lab.

:if ([:len [/ip dhcp-client find where interface="ether1"]] = 0) do={
    /ip dhcp-client add interface=ether1 add-default-route=yes \
        default-route-distance=1 use-peer-dns=yes use-peer-ntp=yes disabled=no
}

# ATTENTION -- ne jamais faire `remove [find]` puis `add` sur les adresses :
# entre les deux, bridge1 n'a plus d'adresse et la session d'administration
# tombe. On garantit d'abord, on elague ensuite.
:if ([:len [/ip address find where address="192.168.100.1/24" and interface="bridge1"]] = 0) do={
    /ip address add address=192.168.100.1/24 interface=bridge1 comment="Gateway LAN"
}
/ip address remove [find where dynamic=no and address!="192.168.100.1/24"]

# La route par defaut vient du client DHCP et n'est pas geree ici. Seule
# celle-ci est statique : les VMs du lab vivent derriere le noeud Proxmox.
:if ([:len [/ip route find where static=yes and dst-address="10.0.0.0/24" and gateway="192.168.100.50"]] = 0) do={
    /ip route add dst-address=10.0.0.0/24 gateway=192.168.100.50 \
        comment="VMs Proxmox derriere vmbr1"
}

# --- DHCP du segment lab ---------------------------------------------------
# M5 : le pool releve allait de .0 a .200 -- il incluait l'adresse reseau et
# la passerelle. Un bail sur .1 aurait coupe tout le segment.
#
# Meme precaution que pour les adresses : le serveur DHCP refuse qu'on
# supprime un pool auquel il fait reference. On cree, on repointe, on elague.
:if ([:len [/ip pool find where name="dhcp_pool-lan"]] = 0) do={
    /ip pool add name=dhcp_pool-lan ranges=192.168.100.100-192.168.100.200
} else={
    /ip pool set [find where name="dhcp_pool-lan"] ranges=192.168.100.100-192.168.100.200
}
:if ([:len [/ip dhcp-server find where name="dhcp-lan"]] > 0) do={
    /ip dhcp-server set [find where name="dhcp-lan"] address-pool=dhcp_pool-lan
}
/ip pool remove [find where name!="dhcp_pool-lan"]

/ip dhcp-server network remove [find]
/ip dhcp-server network add address=192.168.100.0/24 gateway=192.168.100.1 \
    dns-server=192.168.1.254

:if ([:len [/ip dhcp-server find where name="dhcp-lan"]] = 0) do={
    /ip dhcp-server add name=dhcp-lan interface=bridge1 \
        address-pool=dhcp_pool-lan lease-time=10m authoritative=yes disabled=no
} else={
    /ip dhcp-server set [find where name="dhcp-lan"] interface=bridge1 \
        address-pool=dhcp_pool-lan lease-time=10m authoritative=yes disabled=no
}
```

> **M5 appliqué ici.** Le pool devient `.100-.200` et l'entrée fantôme
> `192.0.0.0/8` disparaît. Le `dns-server` distribué passe de `192.168.100.1`
> (qui ne répond pas : `allow-remote-requests=false`) à la box, qui répond.

- [ ] **Étape 4 : `30-nat.rsc`**

```
# ============================================================================
#  NAT : masquerade en sortie, publications entrantes
# ============================================================================
# Les regles dynamiques (UPnP, notamment le port-mapping Tailscale du noeud)
# ne sont pas supprimables et sont donc exclues du remove.

/ip firewall nat remove [find where dynamic=no]

# --- srcnat ----------------------------------------------------------------
/ip firewall nat
add chain=srcnat action=masquerade out-interface-list=WAN \
    comment="sortie Internet du lab"

# --- dstnat : publications vers le noeud Proxmox ---------------------------
# M1 -- `dst-address=192.168.1.50` est le correctif central.
#
# Sans lui, ces regles portent seulement `in-interface=ether1` : TOUT paquet
# venant du LAN maison vers n'importe quelle adresse en 192.168.100.0/24 sur
# ces ports etait detourne vers 192.168.100.50. Le webfig du routeur lui-meme
# etait inatteignable -- https://192.168.100.1 renvoyait l'openresty du noeud.
#
# 192.168.1.50 est l'adresse que la box FAI cible deja : le trafic Internet
# continue d'etre publie a l'identique.
add chain=dstnat action=dst-nat protocol=tcp in-interface=ether1 \
    dst-address=192.168.1.50 dst-port=80 to-addresses=192.168.100.50 to-ports=80 \
    comment="HTTP -> openresty du noeud"
add chain=dstnat action=dst-nat protocol=tcp in-interface=ether1 \
    dst-address=192.168.1.50 dst-port=443 to-addresses=192.168.100.50 to-ports=443 \
    comment="HTTPS -> openresty du noeud"
add chain=dstnat action=dst-nat protocol=tcp in-interface=ether1 \
    dst-address=192.168.1.50 dst-port=22 to-addresses=192.168.100.50 to-ports=22 \
    comment="SSH -> noeud"
add chain=dstnat action=dst-nat protocol=tcp in-interface=ether1 \
    dst-address=192.168.1.50 dst-port=4242 to-addresses=192.168.100.50 to-ports=4242 \
    comment="SSH VM 102"
```

- [ ] **Étape 5 : `40-firewall.rsc`**

Ce fichier décrit **l'état actuel** — c'est-à-dire un pare-feu quasi inexistant.
Il sera remplacé à la tâche 6. L'écrire tel quel donne au commit de la tâche 6
un diff qui montre exactement ce qui a été durci.

```
# ============================================================================
#  Pare-feu -- ETAT RELEVE LE 30/08/2026, AVANT DURCISSEMENT
# ============================================================================
#  Constat M2 : aucune regle de drop finale. La politique par defaut de
#  RouterOS etant `accept`, le routeur n'a pas de pare-feu.
#  Remplace par la tache 6 du plan.
# ============================================================================

/ip firewall filter remove [find where dynamic=no]
/ip firewall filter
add chain=input  action=accept protocol=tcp src-address=192.168.100.50 dst-port=179 comment="BGP CrowdSec"
add chain=output action=accept protocol=tcp dst-address=192.168.100.50 dst-port=179 comment="BGP CrowdSec"
add chain=input  action=accept src-address=10.0.0.0/24 comment="Allow internal LAN to access router"
add chain=forward action=accept src-address=10.0.0.0/24 comment="Allow Proxmox internal LAN"
add chain=input  action=accept protocol=icmp comment="Allow ICMP ping"
add chain=forward action=fasttrack-connection connection-state=established,related
```

- [ ] **Étape 6 : `50-dns.rsc`**

```
# ============================================================================
#  Resolveur DNS
# ============================================================================
# Le routeur ne sert PAS de resolveur au reseau : allow-remote-requests reste
# a `no`. Les noms *.urbanlink.fr sont resolus par la zone publique Cloudflare
# (enregistrements A vers une IP privee) -- voir la conception.
#
# Ouvrir un resolveur ici ajouterait un point de panne et une surface
# d'amplification DNS pour un gain nul.

/ip dns set allow-remote-requests=no cache-size=2048 cache-max-ttl=1w
/ip dns static remove [find where dynamic=no]
```

- [ ] **Étape 7 : `60-crowdsec-bgp.rsc`**

```
# ============================================================================
#  BGP -- reception des blocages CrowdSec depuis le noeud Proxmox
# ============================================================================
#  Le noeud (AS 65001) annonce les IP a bloquer ; le filtre `crowdsec-in` les
#  installe en route blackhole.
#
#  CONSTAT M4 -- CETTE CHAINE NE FONCTIONNE PAS. Relevé le 30/08/2026 :
#  la session est en `state=active, established=false`, elle n'a jamais ete
#  etablie. Le diagnostic complet est dans README.md. La configuration est
#  versionnee telle quelle pour que la reconstruction soit fidele ; la reparer
#  est un chantier a part.
# ============================================================================

/routing filter remove [find where chain="crowdsec-in"]
/routing filter add chain=crowdsec-in action=accept set-type=blackhole set-bgp-weight=100

/routing bgp instance set default as=65002 router-id=192.168.100.1 disabled=no

:if ([:len [/routing bgp peer find where name="CrowdSec-Bouncer"]] = 0) do={
    /routing bgp peer add name=CrowdSec-Bouncer instance=default \
        remote-address=192.168.100.50 remote-as=65001 \
        in-filter=crowdsec-in hold-time=10m keepalive-time=3m ttl=255
} else={
    /routing bgp peer set [find where name="CrowdSec-Bouncer"] \
        remote-address=192.168.100.50 remote-as=65001 \
        in-filter=crowdsec-in hold-time=10m keepalive-time=3m ttl=255
}
```

- [ ] **Étape 8 : écrire l'applicateur**

`mikrotik/lib/ros_apply.py` :

```python
#!/usr/bin/env python3
"""Applique un fichier .rsc sur le routeur via l'API.

RouterOS 6 n'expose ni /import ni /export a l'API. On passe donc par
/system/script : un script RouterOS accepte exactement la meme syntaxe qu'un
.rsc. Le script temporaire est ajoute, execute, puis supprime -- y compris si
l'execution echoue.

    python3 lib/ros_apply.py config/30-nat.rsc [...]
"""
import sys
from ros_api import connect_from_env, RosApiError

SCRIPT_NAME = "_ros_apply_tmp"
POLICY = "read,write,policy,test"


def _cleanup(ros):
    for row in ros.talk(["/system/script/print"]):
        if row.get("name") == SCRIPT_NAME:
            ros.talk(["/system/script/remove", "=.id=" + row[".id"]])


def apply_file(ros, path):
    with open(path, encoding="utf-8") as fh:
        source = fh.read()
    if not source.strip():
        print(f"  {path} : vide, ignore")
        return
    _cleanup(ros)  # un residu d'une execution precedente ferait echouer l'ajout
    ros.talk(["/system/script/add", f"=name={SCRIPT_NAME}",
              f"=policy={POLICY}", f"=source={source}"])
    script_id = next(r[".id"] for r in ros.talk(["/system/script/print"])
                     if r.get("name") == SCRIPT_NAME)
    try:
        ros.talk(["/system/script/run", "=.id=" + script_id])
        print(f"  {path} : applique")
    finally:
        _cleanup(ros)


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: ros_apply.py <fichier.rsc> [...]")
    ros = connect_from_env()
    try:
        for path in sys.argv[1:]:
            apply_file(ros, path)
    except RosApiError as exc:
        raise SystemExit(f"ECHEC : {exc}")
    finally:
        ros.close()


if __name__ == "__main__":
    main()
```

- [ ] **Étape 9 : écrire `restore.sh`**

```bash
#!/usr/bin/env bash
# Rejoue la configuration versionnee sur le routeur.
#
#   ./restore.sh              tous les fichiers de config/, dans l'ordre
#   ./restore.sh 30-nat.rsc   un seul
#
# Les fichiers sont numerotes : les listes d'interfaces (10) doivent exister
# avant que le NAT (30) et le pare-feu (40) ne les referencent.
set -euo pipefail

cd "$(dirname "$0")"
if [ -f secrets.env ]; then . ./secrets.env; fi

if [ $# -gt 0 ]; then
    files=()
    for f in "$@"; do files+=("config/$(basename "$f")"); done
else
    mapfile -t files < <(ls config/[0-9][0-9]-*.rsc | sort)
fi

echo "Application de ${#files[@]} fichier(s) sur ${MIKROTIK_HOST:-192.168.100.1}"
python3 lib/ros_apply.py "${files[@]}"
echo "Termine. Verifier avec ./backup.sh puis git diff."
```

- [ ] **Étape 10 : vérifier que rejouer ne change rien**

C'est le test qui compte : les `.rsc` décrivent l'état actuel, donc les
appliquer doit être un no-op observable.

```bash
cd mikrotik
./backup.sh && cp config/current-state.txt /tmp/avant.txt
./restore.sh 00-system.rsc 50-dns.rsc 60-crowdsec-bgp.rsc
./backup.sh && diff /tmp/avant.txt config/current-state.txt && echo "NO-OP CONFIRME"
```

Attendu : `NO-OP CONFIRME`. C'est le test qui valide à la fois la fidélité des
`.rsc` et l'idempotence du mécanisme : si ces trois fichiers décrivent
réellement l'état du routeur, les appliquer ne peut rien produire.

> **N'applique que ces trois fichiers à cette étape.** `10`, `20`, `30` et `40`
> touchent aux interfaces, à l'adressage, au NAT et au pare-feu ; ils sont
> appliqués aux tâches 4 à 6, dans l'ordre, avec vérification et filet de
> sécurité. Les appliquer maintenant à l'aveugle ferait perdre l'accès au
> routeur.

- [ ] **Étape 11 : committer**

```bash
git add mikrotik/config mikrotik/lib/ros_apply.py mikrotik/restore.sh
git commit -m "feat(mikrotik): configuration versionnee et mecanisme de restauration"
```

---

## Tâche 3 : le README du dépôt MikroTik

**Fichiers :**
- Créer : `mikrotik/README.md`

- [ ] **Étape 1 : écrire le README**

Il doit contenir, dans cet ordre :

1. **Le matériel.** hAP ac² `RBD52G-5HacD2HnD`, série `D7160DC9D484`, RouterOS
   6.49.4, RouterBOOT 6.45.9, ARM 4×716 MHz, 128 Mo de RAM, 16 Mo de flash.

2. **La topologie**, sous forme du schéma ASCII de la conception.

3. **Le rôle du routeur dans le lab** : il route entre `192.168.1.0/24` (LAN
   maison, ether1) et `192.168.100.0/24` (segment lab, bridge1), publie quatre
   ports vers le nœud Proxmox, et sort en masquerade. Il ne fait ni DNS ni
   terminaison TLS.

4. **Comment s'y connecter** : uniquement par l'API sur 8729 (`api-ssl`), depuis
   `192.168.1.0/24` ou `192.168.100.0/24`. Winbox sur 8291. SSH sur 22 vers
   `192.168.100.1` — en précisant que vers `192.168.1.50` le port 22 est
   redirigé vers le nœud, ce qui est voulu.

5. **La procédure de reconstruction**, pas à pas :

   ```
   1. /system reset-configuration no-defaults=yes skip-backup=yes
      (ou netinstall si le routeur ne repond plus)
   2. Se connecter en Winbox par adresse MAC : 08:55:31:9D:75:4D
   3. Poser l'acces minimal :
        /interface bridge add name=bridge1
        /interface bridge port add bridge=bridge1 interface=ether2
        /ip address add address=192.168.100.1/24 interface=bridge1
        /ip service set api-ssl address=192.168.100.0/24 disabled=no
        /user set [find name=admin] password="..."
   4. Depuis un poste du segment lab :
        cd mikrotik && cp secrets.rsc.example secrets.env  # puis renseigner
        ./restore.sh
   5. Appliquer les secrets :
        python3 lib/ros_apply.py secrets.rsc
   6. Verifier :
        ./backup.sh && git diff config/current-state.txt
   ```

6. **Les six constats M1–M6**, avec pour chacun : ce qui a été observé, la
   conséquence, et l'état (corrigé tâche N / documenté / hors périmètre).

7. **Le diagnostic M4 en détail**, puisqu'il n'est pas corrigé :

   > La session BGP `CrowdSec-Bouncer` (`192.168.100.50`, AS 65001) est en
   > `state=active, established=false` : le routeur tente la connexion, le pair
   > ne répond pas. Côté nœud, les bouncers `cs-mikrotik-bouncer`,
   > `mikrotik-final` et `exabgp-mikrotik` sont enregistrés dans CrowdSec, et
   > `exabgp-mikrotik` fait bien ses pulls d'API. Le maillon manquant est entre
   > exabgp et le port 179 du routeur.
   >
   > En parallèle, le scheduler `CrowdsecUpdate` appelait toutes les 15 minutes
   > un script `crowdsec_import` absent de `/system/script` — 576 exécutions en
   > échec silencieux. Ce scheduler est supprimé à la tâche 5 : il ne faisait
   > rien d'autre que du bruit.
   >
   > Pour reprendre : vérifier que `exabgp` écoute et peer effectivement
   > (`ss -tlnp | grep 179` sur le nœud), puis
   > `/routing bgp peer print status` sur le routeur.

8. **Ce qui n'est pas versionné** : mots de passe, PSK wifi, clé du bouncer —
   et où les retrouver (`secrets.rsc`, hors git).

- [ ] **Étape 2 : vérifier que les liens et chemins cités existent**

```bash
cd mikrotik && ls config/*.rsc lib/*.py backup.sh restore.sh secrets.rsc.example
```

Attendu : les onze fichiers, sans erreur.

- [ ] **Étape 3 : committer**

```bash
git add mikrotik/README.md
git commit -m "docs(mikrotik): topologie, reconstruction et constats M1-M6"
```

---

## Tâche 4 : correctif M1 — le détournement `dstnat`

C'est le correctif qui débloque `router.urbanlink.fr` et rend le segment lab
adressable normalement.

**Fichiers :**
- Modifier : `mikrotik/config/30-nat.rsc` (déjà écrit corrigé en tâche 2)

- [ ] **Étape 1 : constater le défaut**

```bash
curl -s -o /dev/null -w "%{http_code} %{header_json}" --max-time 8 http://192.168.100.1/ | head -c 200
```

Attendu **avant** correctif : un code HTTP servi par `openresty` — la preuve que
la requête vers le routeur atterrit sur le nœud Proxmox.

Vérifier aussi que les publications marchent, pour pouvoir comparer après :

```bash
curl -s -o /dev/null -w "nbeny.fr -> %{http_code}\n" --max-time 8 https://nbeny.fr/
```

- [ ] **Étape 2 : sauvegarder avant de toucher au NAT**

```bash
cd mikrotik
MSYS_NO_PATHCONV=1 python3 -c "
import sys; sys.path.insert(0,'lib')
from ros_api import connect_from_env
r = connect_from_env()
r.talk(['/system/backup/save', '=name=pre-m1'])
print([f['name'] for f in r.talk(['/file/print']) if 'pre-m1' in f.get('name','')])
"
```

Attendu : `['pre-m1.backup']`

- [ ] **Étape 3 : activer le webfig, restreint au seul nœud**

Corriger M1 rend le routeur adressable, mais son interface web est désactivée
(`/ip service www disabled=yes`). Sans elle, `router.urbanlink.fr` n'aurait
rien à servir.

Dans `mikrotik/config/00-system.rsc`, remplacer :

```
/ip service set www      disabled=yes
```

par :

```
# Webfig en clair, restreint a la SEULE adresse du noeud Proxmox : c'est
# nginx qui le publie sous router.urbanlink.fr, apres terminaison TLS et
# filtrage sur l'adresse source. Aucun autre client n'a a l'atteindre --
# et surtout pas depuis ether1.
/ip service set www      address=192.168.100.50 disabled=no
```

Retirer aussi, dans le commentaire d'en-tête de la section *Services de
gestion*, la ligne annonçant ce changement à venir : il est fait.

- [ ] **Étape 4 : appliquer**

```bash
cd mikrotik && ./restore.sh 30-nat.rsc 00-system.rsc
```

Attendu : les deux fichiers signalés `applique`.

- [ ] **Étape 5 : vérifier que le routeur est désormais joignable**

```bash
ssh root@192.168.100.50 'curl -s -o /dev/null -w "%{http_code}\n" --max-time 8 http://192.168.100.1/'
```

Attendu : `200` (ou `303`), servi par RouterOS.

```bash
ssh root@192.168.100.50 'curl -sI --max-time 8 http://192.168.100.1/ | grep -i server'
```

Attendu : **pas** de `openresty`. C'est la preuve directe que M1 est corrigé.

- [ ] **Étape 6 : vérifier la non-régression des publications**

C'est la vérification qui compte : M1 modifie les règles par lesquelles arrive
tout le trafic Internet du nœud.

```bash
curl -s -o /dev/null -w "nbeny.fr        -> %{http_code}\n" --max-time 8 https://nbeny.fr/
curl -s -o /dev/null -w "proxmox.nbeny   -> %{http_code}\n" --max-time 8 https://proxmox.nbeny.fr/
ssh -o ConnectTimeout=8 root@192.168.100.50 'echo "SSH noeud -> OK"'
```

Attendu : les trois répondent comme avant. Si l'un tombe, restaurer :
`/system backup load name=pre-m1` (le routeur redémarre).

- [ ] **Étape 7 : relever et committer**

```bash
cd mikrotik && ./backup.sh
cd .. && git add mikrotik/config/
git commit -m "fix(mikrotik): M1 -- restreindre les dstnat a dst-address=192.168.1.50

Sans dst-address, les quatre regles detournaient vers 192.168.100.50 tout
paquet du LAN vers n'importe quelle IP du segment lab sur 22/80/443/4242.
Le webfig du routeur etait inatteignable."
```

---

## Tâche 5 : correctifs M3 et M5 — surface de gestion et DHCP

**Fichiers :**
- Créer : `mikrotik/config/05-hardening.rsc`
- Modifier : `mikrotik/config/00-system.rsc`

- [ ] **Étape 1 : constater**

```bash
cd mikrotik
MSYS_NO_PATHCONV=1 python3 -c "
import sys; sys.path.insert(0,'lib')
from ros_api import connect_from_env
r = connect_from_env()
print('mac-server   :', r.talk(['/tool/mac-server/print']))
print('mac-winbox   :', r.talk(['/tool/mac-server/mac-winbox/print']))
print('upnp         :', r.talk(['/ip/upnp/print']))
print('upnp ifaces  :', r.talk(['/ip/upnp/interfaces/print']))
print('scheduler    :', [s.get('name') for s in r.talk(['/system/scheduler/print'])])
"
```

Attendu **avant** : `allowed-interface-list=all` deux fois, un scheduler
`CrowdsecUpdate`, et — déjà corrects — deux interfaces UPnP déclarées
(`bridge1` interne, `ether1` externe). Seuls les deux premiers points sont à
corriger ; le troisième est simplement versionné.

- [ ] **Étape 2 : écrire `05-hardening.rsc`**

```
# ============================================================================
#  Reduction de la surface de gestion  (constats M3 et M5)
# ============================================================================

# --- M3 : MAC-telnet et MAC-Winbox -----------------------------------------
# Ces deux protocoles operent en couche 2 et contournent entierement le
# filtrage IP : une regle de pare-feu ne les arrete pas. Les laisser sur
# `all`, c'est les exposer sur le segment WAN.
/tool mac-server set allowed-interface-list=LAN
/tool mac-server mac-winbox set allowed-interface-list=LAN

# --- UPnP ------------------------------------------------------------------
# Deja correctement configure sur le routeur (releve du 30/08/2026 :
# bridge1=internal, ether1=external). On ne le desactive PAS : le noeud s'en
# sert pour le port-mapping Tailscale, et le couper degraderait la traversee
# NAT sans rien gagner. Ces lignes ne corrigent rien -- elles rendent l'etat
# reproductible sur un routeur remis a zero.
:if ([:len [/ip upnp interfaces find where interface="ether1"]] = 0) do={
    /ip upnp interfaces add interface=ether1 type=external
}
:if ([:len [/ip upnp interfaces find where interface="bridge1"]] = 0) do={
    /ip upnp interfaces add interface=bridge1 type=internal
}
/ip upnp set enabled=yes allow-disable-external-interface=no

# --- M5 : scheduler orphelin -----------------------------------------------
# `CrowdsecUpdate` appelle toutes les 15 min un script `crowdsec_import` qui
# n'existe pas : 576 executions en echec silencieux au moment du releve.
# Voir README.md, constat M4, pour le diagnostic complet.
/system scheduler remove [find where name="CrowdsecUpdate"]

# --- Horloge ---------------------------------------------------------------
# Le client NTP etait desactive. Un routeur remis a zero demarre en 1970 :
# tant que l'horloge est fausse, toute verification de certificat TLS faite
# derriere lui echoue -- y compris le renouvellement certbot du noeud.
/system ntp client set enabled=yes mode=unicast \
    primary-ntp=162.159.200.1 secondary-ntp=162.159.200.123

# --- Divers ----------------------------------------------------------------
# Services non utilises, laisses actifs par la configuration d'usine.
/tool romon set enabled=no
/ip proxy set enabled=no
/ip socks set enabled=no
/snmp set enabled=no
```

- [ ] **Étape 3 : désactiver l'API en clair dans `00-system.rsc`**

Remplacer la ligne :

```
/ip service set api      address=192.168.1.0/24,192.168.100.0/24 disabled=no
```

par :

```
# M5 -- l'API en clair transporte le mot de passe admin en clair sur le LAN.
# api-ssl (8729) couvre le meme besoin ; c'est ce qu'utilisent les scripts
# de ce depot.
/ip service set api      disabled=yes
```

- [ ] **Étape 4 : appliquer**

```bash
cd mikrotik && ./restore.sh 05-hardening.rsc 00-system.rsc 20-addressing.rsc
```

Attendu : les trois fichiers signalés `applique`.

- [ ] **Étape 5 : vérifier**

```bash
cd mikrotik
MSYS_NO_PATHCONV=1 python3 -c "
import sys; sys.path.insert(0,'lib')
from ros_api import connect_from_env
r = connect_from_env()
assert r.talk(['/tool/mac-server/print'])[0]['allowed-interface-list'] == 'LAN'
assert r.talk(['/tool/mac-server/mac-winbox/print'])[0]['allowed-interface-list'] == 'LAN'
assert [s for s in r.talk(['/ip/service/print']) if s['name']=='api'][0]['disabled'] == 'true'
assert not [s for s in r.talk(['/system/scheduler/print']) if s.get('name')=='CrowdsecUpdate']
assert r.talk(['/ip/pool/print'])[0]['ranges'] == '192.168.100.100-192.168.100.200'
assert len(r.talk(['/ip/dhcp-server/network/print'])) == 1
assert r.talk(['/system/ntp/client/print'])[0]['enabled'] == 'true'
assert len(r.talk(['/ip/upnp/interfaces/print'])) == 2
print('M3 + M5 : OK')
"
```

Attendu : `M3 + M5 : OK`

La session elle-même prouve qu'`api-ssl` fonctionne toujours — si elle passe,
l'accès n'est pas perdu.

- [ ] **Étape 6 : vérifier que le nœud n'a rien perdu**

```bash
ssh -o ConnectTimeout=8 root@192.168.100.50 'ping -c2 -W2 1.1.1.1 >/dev/null && echo "Internet depuis le noeud : OK"'
```

- [ ] **Étape 7 : relever et committer**

```bash
cd mikrotik && ./backup.sh
cd .. && git add mikrotik/
git commit -m "fix(mikrotik): M3 et M5 -- surface de gestion, UPnP, pool DHCP, API en clair"
```

---

## Tâche 6 : correctif M2 — le pare-feu

**La tâche la plus risquée du plan.** Elle peut couper l'accès au routeur et
Internet pour tout le foyer. Le filet de sécurité n'est pas optionnel.

**Fichiers :**
- Modifier : `mikrotik/config/40-firewall.rsc` (réécriture complète)

- [ ] **Étape 1 : poser le filet**

```bash
cd mikrotik
MSYS_NO_PATHCONV=1 python3 -c "
import sys; sys.path.insert(0,'lib')
from ros_api import connect_from_env
r = connect_from_env()
r.talk(['/system/backup/save', '=name=pre-firewall'])
r.talk(['/system/scheduler/add', '=name=rollback-firewall', '=interval=5m',
        '=on-event=/system backup load name=pre-firewall'])
print('filet arme -- restauration automatique dans 5 minutes')
print('scheduler:', [s.get('name') for s in r.talk(['/system/scheduler/print'])])
"
```

Attendu : `filet arme` et `['rollback-firewall']`.

Le backup est pris **après** M1, M3 et M5 : une restauration ne perd que le
travail de cette tâche. Le scheduler n'étant pas dans le backup, une
restauration le supprime — pas de boucle de redémarrage.

> **À partir d'ici, les étapes 2 à 5 doivent s'enchaîner en moins de cinq
> minutes.** Si le délai est dépassé sans incident, le routeur redémarre : ce
> n'est pas grave, il suffit de reprendre à l'étape 1.

- [ ] **Étape 2 : écrire `40-firewall.rsc`**

```
# ============================================================================
#  Pare-feu  (correctif M2)
# ============================================================================
#  Avant ce fichier, `input` et `forward` ne contenaient que des `accept` et
#  aucun `drop` final. La politique par defaut de RouterOS etant `accept`, le
#  routeur n'avait pas de pare-feu.
#
#  PIEGE MAJEUR -- le poste de travail est sur 192.168.1.0/24, cote ether1,
#  donc dans la liste WAN. Un `drop in-interface-list=WAN` place avant les
#  regles d'acceptation du LAN maison coupe immediatement l'administration.
#  L'ordre ci-dessous n'est pas cosmetique.
# ============================================================================

/ip firewall filter remove [find where dynamic=no]

# --- input : ce qui est adresse au routeur lui-meme -------------------------
/ip firewall filter
add chain=input action=accept connection-state=established,related,untracked \
    comment="retour de trafic deja autorise"
add chain=input action=drop connection-state=invalid \
    comment="paquets hors connexion"
add chain=input action=accept protocol=icmp \
    comment="ping et decouverte de MTU -- ne pas retirer"
add chain=input action=accept in-interface-list=LAN \
    comment="segment lab 192.168.100.0/24"
add chain=input action=accept src-address=10.0.0.0/24 \
    comment="VMs derriere le noeud Proxmox"
add chain=input action=accept protocol=tcp src-address=192.168.100.50 dst-port=179 \
    comment="BGP CrowdSec depuis le noeud"
add chain=input action=accept protocol=tcp src-address=192.168.1.0/24 \
    dst-port=22,8291,8729 \
    comment="administration depuis le LAN maison -- SANS CETTE REGLE, LOCKOUT"
add chain=input action=drop in-interface-list=WAN \
    comment="M2 -- tout le reste arrivant par ether1"

# --- forward : ce qui traverse ---------------------------------------------
add chain=forward action=fasttrack-connection connection-state=established,related \
    comment="deleste le CPU des flux etablis"
add chain=forward action=accept connection-state=established,related,untracked
add chain=forward action=drop connection-state=invalid
add chain=forward action=accept src-address=10.0.0.0/24 \
    comment="VMs -> partout"
add chain=forward action=accept src-address=192.168.1.0/24 dst-address=192.168.100.0/24 \
    comment="LAN maison -> segment lab (le poste de travail passe par ici)"
add chain=forward action=accept src-address=192.168.1.0/24 dst-address=10.0.0.0/24 \
    comment="LAN maison -> VMs"
add chain=forward action=accept in-interface-list=LAN out-interface-list=WAN \
    comment="lab -> Internet"
add chain=forward action=drop connection-state=new connection-nat-state=!dstnat \
    in-interface-list=WAN \
    comment="M2 -- entrant non publie. Les dstnat de 30-nat.rsc passent."

# --- output ----------------------------------------------------------------
# La politique de sortie reste `accept` ; cette regle est conservee pour la
# lisibilite du chemin BGP, elle n'ajoute pas de contrainte.
add chain=output action=accept protocol=tcp dst-address=192.168.100.50 dst-port=179 \
    comment="BGP CrowdSec vers le noeud"
```

- [ ] **Étape 3 : appliquer**

```bash
cd mikrotik && ./restore.sh 40-firewall.rsc
```

Attendu : `config/40-firewall.rsc : applique`

- [ ] **Étape 4 : vérifier immédiatement les cinq chemins critiques**

```bash
cd mikrotik
echo "1. API MikroTik  :" && MSYS_NO_PATHCONV=1 python3 -c "
import sys; sys.path.insert(0,'lib')
from ros_api import connect_from_env
print('   OK --', len(connect_from_env().talk(['/ip/firewall/filter/print'])), 'regles')
"
echo "2. SSH noeud     :" && ssh -o ConnectTimeout=8 root@192.168.100.50 'echo "   OK"'
echo "3. Internet noeud:" && ssh -o ConnectTimeout=8 root@192.168.100.50 'ping -c2 -W2 1.1.1.1 >/dev/null && echo "   OK"'
echo "4. Internet poste:" && curl -s -o /dev/null -w "   %{http_code}\n" --max-time 8 https://1.1.1.1/
echo "5. Publication   :" && curl -s -o /dev/null -w "   nbeny.fr %{http_code}\n" --max-time 8 https://nbeny.fr/
```

Attendu : les cinq répondent `OK` ou un code HTTP valide.

**Si l'un échoue, ne pas insister : attendre les cinq minutes.** Le routeur
redémarre et restaure `pre-firewall`. Corriger `40-firewall.rsc` et reprendre à
l'étape 1.

- [ ] **Étape 5 : désarmer le filet**

Uniquement si les cinq vérifications passent.

```bash
cd mikrotik
MSYS_NO_PATHCONV=1 python3 -c "
import sys; sys.path.insert(0,'lib')
from ros_api import connect_from_env
r = connect_from_env()
for s in r.talk(['/system/scheduler/print']):
    if s.get('name') == 'rollback-firewall':
        r.talk(['/system/scheduler/remove', '=.id=' + s['.id']])
print('filet desarme. schedulers restants:', [s.get('name') for s in r.talk(['/system/scheduler/print'])])
"
```

Attendu : `filet desarme. schedulers restants: []`

- [ ] **Étape 6 : vérifier que le drop mord réellement**

Un pare-feu qui n'a jamais rien compté n'est pas prouvé. Après quelques minutes
d'exposition Internet :

```bash
cd mikrotik
MSYS_NO_PATHCONV=1 python3 -c "
import sys; sys.path.insert(0,'lib')
from ros_api import connect_from_env
for row in connect_from_env().talk(['/ip/firewall/filter/print']):
    if row.get('action') == 'drop':
        print(row.get('chain'), row.get('comment','')[:40], '->', row.get('packets'), 'paquets')
"
```

Attendu : au moins une règle `drop` avec un compteur non nul. Un compteur à zéro
partout après dix minutes signifie soit que la box FAI filtre déjà tout en
amont, soit que les règles ne sont pas atteintes — le noter dans le README plutôt
que de le supposer.

- [ ] **Étape 7 : relever et committer**

```bash
cd mikrotik && ./backup.sh
cd .. && git add mikrotik/
git commit -m "fix(mikrotik): M2 -- pare-feu input et forward avec drop final

Les deux chaines n'avaient aucune regle de drop et la politique par defaut
de RouterOS est accept. Le poste de travail etant sur 192.168.1.0/24, cote
ether1, l'ordre des regles est critique : l'acceptation de l'administration
depuis le LAN maison precede le drop WAN."
```

---

## Tâche 7 : la zone Cloudflare et le certificat wildcard

**Fichiers :**
- Créer : `ansible/roles/edge_urbanlink/defaults/main.yml`
- Créer : `ansible/roles/edge_urbanlink/tasks/certificate.yml`
- Créer : `ansible/roles/edge_urbanlink/tasks/main.yml`
- Créer : `ansible/playbooks/32-urbanlink-edge.yml`

- [ ] **Étape 1 : créer les enregistrements DNS**

Deux enregistrements dans la zone `urbanlink.fr`, en **DNS-only (nuage gris)** :

| Type | Nom | Contenu | Proxy |
|---|---|---|---|
| A | `@` | `192.168.100.50` | DNS only |
| A | `*` | `192.168.100.50` | DNS only |

Par API, avec le token :

```bash
CF_TOKEN='<le token>'
ZONE=$(curl -s -H "Authorization: Bearer $CF_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones?name=urbanlink.fr" | \
  python -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])")
echo "zone: $ZONE"

for NAME in "urbanlink.fr" "*.urbanlink.fr"; do
  curl -s -X POST -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records" \
    --data "{\"type\":\"A\",\"name\":\"$NAME\",\"content\":\"192.168.100.50\",\"proxied\":false,\"ttl\":300}" \
    | python -c "import sys,json; d=json.load(sys.stdin); print(d['success'], d.get('errors'))"
done
```

Attendu : `True None` deux fois.

- [ ] **Étape 2 : vérifier la résolution**

```bash
nslookup pgadmin.urbanlink.fr 8.8.8.8
nslookup urbanlink.fr 8.8.8.8
```

Attendu : `192.168.100.50` dans les deux cas. Si la réponse est une IP publique,
l'enregistrement est proxifié — repasser le nuage en gris.

- [ ] **Étape 3 : écrire les valeurs par défaut du rôle**

`ansible/roles/edge_urbanlink/defaults/main.yml` :

```yaml
---
# ============================================================================
#  Exposition des outils du lab sous *.urbanlink.fr -- LAN uniquement
# ============================================================================
edge_urbanlink_domain: urbanlink.fr

# Adresse de la passerelle Istio. Tous les services du cluster partagent ce
# meme amont : c'est l'en-tete Host qui les distingue, cote Istio.
edge_urbanlink_gateway: "http://10.0.0.111:30080"

# Les seules sources autorisees. Le A record public pointant deja sur une IP
# privee, ce filtre est la seconde barriere -- pas la premiere.
edge_urbanlink_allow:
  - 192.168.1.0/24
  - 192.168.100.0/24

edge_urbanlink_cert_email: ynebocin@gmail.com
edge_urbanlink_cloudflare_token: ""   # a fournir ; jamais ecrit en clair ici

edge_urbanlink_services:
  # --- applicatif ---------------------------------------------------------
  - name: app
    hosts: ["urbanlink.fr", "www.urbanlink.fr"]
  - name: api
    hosts: ["api.urbanlink.fr"]
  - name: auth
    hosts: ["auth.urbanlink.fr"]
  - name: nominatim
    hosts: ["nominatim.urbanlink.fr"]
    read_timeout: 300s          # un geocodage complet peut etre long
  - name: s3
    hosts: ["s3.urbanlink.fr"]
    max_body: 0                 # 0 = pas de limite, pour les envois objet
  # --- consoles d'administration ------------------------------------------
  - name: directus
    hosts: ["directus.urbanlink.fr"]
  - name: minio
    hosts: ["minio.urbanlink.fr"]
    max_body: 0
  - name: pgadmin
    hosts: ["pgadmin.urbanlink.fr"]
  - name: kafka
    hosts: ["kafka.urbanlink.fr"]
  - name: temporal
    hosts: ["temporal.urbanlink.fr"]
  - name: kibana
    hosts: ["kibana.urbanlink.fr"]
    read_timeout: 300s
  - name: kiali
    hosts: ["kiali.urbanlink.fr"]
  - name: prometheus
    hosts: ["prometheus.urbanlink.fr"]
  # --- hors cluster : amont explicite --------------------------------------
  - name: proxmox
    hosts: ["proxmox.urbanlink.fr"]
    upstream: "https://192.168.100.50:8006"
    read_timeout: 3600s         # console noVNC et shell : connexions longues
  - name: router
    hosts: ["router.urbanlink.fr"]
    upstream: "http://192.168.100.1"
```

- [ ] **Étape 4 : écrire l'obtention du certificat**

`ansible/roles/edge_urbanlink/tasks/certificate.yml` :

```yaml
---
# Certificat wildcard par challenge DNS-01. C'est le seul challenge possible
# ici : les noms resolvent en IP privee, Let's Encrypt ne peut pas les
# joindre pour un HTTP-01.

- name: Installer le greffon certbot pour Cloudflare
  ansible.builtin.apt:
    name: python3-certbot-dns-cloudflare
    state: present
    update_cache: true
    cache_valid_time: 3600

- name: Exiger le token Cloudflare
  ansible.builtin.assert:
    that: edge_urbanlink_cloudflare_token | length > 0
    fail_msg: >-
      edge_urbanlink_cloudflare_token est vide. Fournir un token limite a
      Zone:DNS:Edit sur la zone {{ edge_urbanlink_domain }}, par exemple avec
      -e edge_urbanlink_cloudflare_token=... ou via ansible-vault.

- name: Creer le repertoire des identifiants
  ansible.builtin.file:
    path: /root/.secrets
    state: directory
    owner: root
    group: root
    mode: "0700"

- name: Deposer les identifiants Cloudflare
  ansible.builtin.copy:
    dest: /root/.secrets/cloudflare.ini
    content: "dns_cloudflare_api_token = {{ edge_urbanlink_cloudflare_token }}\n"
    owner: root
    group: root
    mode: "0600"
  no_log: true

- name: Verifier si le certificat existe deja
  ansible.builtin.stat:
    path: "/etc/letsencrypt/live/{{ edge_urbanlink_domain }}/fullchain.pem"
  register: edge_cert

# `--dns-cloudflare-propagation-seconds 30` : sans attente, certbot interroge
# l'autoritatif avant que Cloudflare n'ait propage l'enregistrement TXT et le
# challenge echoue de maniere intermittente.
#
# Les deux `-d` sont necessaires : un wildcard ne couvre pas son propre apex.
- name: Obtenir le certificat wildcard
  ansible.builtin.command:
    argv:
      - certbot
      - certonly
      - --non-interactive
      - --agree-tos
      - --email={{ edge_urbanlink_cert_email }}
      - --dns-cloudflare
      - --dns-cloudflare-credentials=/root/.secrets/cloudflare.ini
      - --dns-cloudflare-propagation-seconds=30
      - --cert-name={{ edge_urbanlink_domain }}
      - -d
      - "{{ edge_urbanlink_domain }}"
      - -d
      - "*.{{ edge_urbanlink_domain }}"
  when: not edge_cert.stat.exists
  register: edge_certbot
  changed_when: "'Successfully received certificate' in edge_certbot.stdout"

- name: Relever les noms couverts par le certificat
  ansible.builtin.command:
    argv: [openssl, x509, -noout, -text,
           -in, "/etc/letsencrypt/live/{{ edge_urbanlink_domain }}/fullchain.pem"]
  register: edge_cert_text
  changed_when: false

- name: Verifier que l'apex et le wildcard sont tous deux couverts
  ansible.builtin.assert:
    that:
      - "'DNS:' ~ edge_urbanlink_domain in edge_cert_text.stdout"
      - "'DNS:*.' ~ edge_urbanlink_domain in edge_cert_text.stdout"
    fail_msg: "Le certificat ne couvre pas les deux noms attendus."
```

- [ ] **Étape 5 : écrire le point d'entrée du rôle et le playbook**

`ansible/roles/edge_urbanlink/tasks/main.yml` :

```yaml
---
- name: Obtenir le certificat wildcard
  ansible.builtin.import_tasks: certificate.yml
  tags: [certificate]

- name: Publier les vhosts nginx
  ansible.builtin.import_tasks: nginx.yml
  tags: [nginx]
```

`ansible/playbooks/32-urbanlink-edge.yml` :

```yaml
---
# Expose les outils du lab sous *.urbanlink.fr, depuis le noeud Proxmox.
#
# Prerequis :
#   1. Les enregistrements A urbanlink.fr et *.urbanlink.fr pointent sur
#      192.168.100.50, en DNS-only.
#   2. Un token Cloudflare limite a Zone:DNS:Edit sur cette zone.
#
#   ansible-playbook playbooks/32-urbanlink-edge.yml \
#       -e edge_urbanlink_cloudflare_token=...
#
# Le token n'est pas stocke dans le depot. Pour eviter de le retaper :
#   ansible-vault create inventory/group_vars/proxmox/vault.yml

- name: Exposer les outils sous *.urbanlink.fr
  hosts: proxmox
  gather_facts: true
  become: true
  roles:
    - edge_urbanlink
```

`tasks/nginx.yml` est écrit à la tâche 8 ; créer un fichier vide pour l'instant
ferait échouer le rôle silencieusement — écrire les deux tâches avant de jouer
le playbook.

- [ ] **Étape 6 : committer**

```bash
git add ansible/roles/edge_urbanlink/defaults ansible/roles/edge_urbanlink/tasks/certificate.yml \
        ansible/roles/edge_urbanlink/tasks/main.yml ansible/playbooks/32-urbanlink-edge.yml
git commit -m "feat(ansible): role edge_urbanlink -- certificat wildcard DNS-01 Cloudflare"
```

---

## Tâche 8 : les vhosts nginx

**Fichiers :**
- Créer : `ansible/roles/edge_urbanlink/tasks/nginx.yml`
- Créer : `ansible/roles/edge_urbanlink/templates/urbanlink.conf.j2`
- Créer : `ansible/roles/edge_urbanlink/templates/connection-upgrade.conf.j2`
- Créer : `ansible/roles/edge_urbanlink/handlers/main.yml`

- [ ] **Étape 1 : écrire la carte `$connection_upgrade`**

`templates/connection-upgrade.conf.j2` :

```nginx
# {{ ansible_managed }}
# Necessaire pour relayer les WebSocket. Sans cette carte, `Connection` serait
# transmis tel quel et la montee en WebSocket echouerait sur Kibana, Kiali,
# la console MinIO, Directus et la console Proxmox.
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
```

- [ ] **Étape 2 : écrire le template des vhosts**

`templates/urbanlink.conf.j2` :

```nginx
# {{ ansible_managed }}
# ============================================================================
#  Exposition des outils du lab sous *.{{ edge_urbanlink_domain }}
# ----------------------------------------------------------------------------
#  Genere depuis edge_urbanlink_services. Ne pas editer sur le noeud : le
#  playbook ecrase ce fichier.
#
#  Deux barrieres, dans cet ordre :
#    1. les enregistrements A publics pointent sur une IP privee -- depuis
#       Internet, ces noms ne menent nulle part ;
#    2. le bloc allow/deny ci-dessous, au cas ou la premiere tombe.
# ============================================================================

{% for svc in edge_urbanlink_services %}
# --- {{ svc.name }} {{ '-' * (68 - svc.name | length) }}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name {{ svc.hosts | join(' ') }};

    ssl_certificate     /etc/letsencrypt/live/{{ edge_urbanlink_domain }}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{{ edge_urbanlink_domain }}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

{% for cidr in edge_urbanlink_allow %}
    allow {{ cidr }};
{% endfor %}
    deny all;

    client_max_body_size {{ svc.max_body | default('64m') }};

    location / {
        proxy_pass {{ svc.upstream | default(edge_urbanlink_gateway) }};

        # C'est l'en-tete Host qui selectionne le VirtualService cote Istio :
        # le perdre casserait tout le routage.
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host  $host;

        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

{% if (svc.upstream | default(edge_urbanlink_gateway)).startswith('https://') %}
        # Amont en certificat auto-signe (interface Proxmox) : on ne verifie
        # pas, faute d'autorite commune. Le saut reste interne au noeud.
        proxy_ssl_verify off;
{% endif %}
        proxy_connect_timeout 10s;
        proxy_read_timeout    {{ svc.read_timeout | default('60s') }};
        proxy_send_timeout    {{ svc.read_timeout | default('60s') }};
    }
}

{% endfor %}
# --- redirection HTTP -> HTTPS pour tous les noms ---------------------------
server {
    listen 80;
    listen [::]:80;
    server_name{% for svc in edge_urbanlink_services %}{% for h in svc.hosts %} {{ h }}{% endfor %}{% endfor %};

    return 301 https://$host$request_uri;
}
```

- [ ] **Étape 3 : écrire les tâches nginx**

`tasks/nginx.yml` :

```yaml
---
- name: Deposer la carte connection_upgrade
  ansible.builtin.template:
    src: connection-upgrade.conf.j2
    dest: /etc/nginx/conf.d/40-connection-upgrade.conf
    owner: root
    group: root
    mode: "0644"
  notify: reload nginx

- name: Deposer les vhosts urbanlink
  ansible.builtin.template:
    src: urbanlink.conf.j2
    dest: /etc/nginx/sites-available/urbanlink.fr
    owner: root
    group: root
    mode: "0644"
    validate: "nginx -t -c /etc/nginx/nginx.conf"
  notify: reload nginx

- name: Activer les vhosts
  ansible.builtin.file:
    src: /etc/nginx/sites-available/urbanlink.fr
    dest: /etc/nginx/sites-enabled/urbanlink.fr
    state: link
  notify: reload nginx

# `validate` du module template teste le fichier hors contexte : il ne voit ni
# le lien symbolique ni la carte. Ce test-ci porte sur la configuration reelle
# et fait echouer le playbook plutot que de recharger un nginx casse.
- name: Valider la configuration nginx complete
  ansible.builtin.command: nginx -t
  changed_when: false
```

- [ ] **Étape 4 : écrire le handler**

`handlers/main.yml` :

```yaml
---
- name: reload nginx
  ansible.builtin.systemd_service:
    name: nginx
    state: reloaded
```

- [ ] **Étape 5 : jouer le rôle**

```bash
cd ansible
ansible-playbook playbooks/32-urbanlink-edge.yml -e edge_urbanlink_cloudflare_token='<le token>'
```

Attendu : `failed=0`, avec des tâches `changed` sur le certificat et les vhosts.

> Le playbook s'exécute **depuis le nœud** (`/root/infra/ansible`), comme le
> reste de la chaîne. Penser à pousser le dépôt d'abord :
> `tar -czf - --exclude=.git . | ssh root@192.168.100.50 'tar -xzf - -C /root/infra'`

- [ ] **Étape 6 : vérifier le certificat servi**

```bash
echo | openssl s_client -connect 192.168.100.50:443 -servername pgadmin.urbanlink.fr 2>/dev/null \
  | openssl x509 -noout -issuer -subject -ext subjectAltName
```

Attendu : `issuer=C=US, O=Let's Encrypt...` et un SAN contenant
`DNS:*.urbanlink.fr` et `DNS:urbanlink.fr`.

- [ ] **Étape 7 : vérifier le filtrage**

Le nœud n'est ni dans `192.168.1.0/24` ni... si, il est dans
`192.168.100.0/24` : une requête depuis le nœud est donc autorisée. Pour tester
le refus, forcer une source hors des deux plages depuis une VM du lab :

```bash
ssh root@192.168.100.50 'ssh nbeny@10.0.0.190 "curl -sk -o /dev/null -w \"%{http_code}\n\" --resolve pgadmin.urbanlink.fr:443:192.168.100.50 https://pgadmin.urbanlink.fr/"'
```

Attendu : `403`. La VM est en `10.0.0.190`, hors des plages autorisées — c'est
la preuve que le `deny all` mord.

- [ ] **Étape 8 : vérifier l'idempotence**

```bash
cd ansible && ansible-playbook playbooks/32-urbanlink-edge.yml -e edge_urbanlink_cloudflare_token='<le token>'
```

Attendu : `changed=0`. Sinon, une tâche réécrit un fichier à chaque passage —
la corriger avant de continuer.

- [ ] **Étape 9 : committer**

```bash
git add ansible/roles/edge_urbanlink/
git commit -m "feat(ansible): vhosts nginx *.urbanlink.fr, LAN uniquement"
```

---

## Tâche 9 : les manifests Istio en `urbanlink.fr`

**Fichiers :**
- Modifier : `kube/urbanlink/ingress-istio/gateway.yaml`
- Modifier : `kube/urbanlink/ingress-istio/virtualservices.yaml`
- Modifier : `ansible/playbooks/31-urbanlink-deploy.yml`
- Modifier : `kube/urbanlink/_config/kratos/kratos.urbanlink.yml`

- [ ] **Étape 1 : relever les URL `urbanconnect.fr` restantes**

```bash
grep -rn "urbanconnect\.fr" kube/ ansible/ --include=*.yml --include=*.yaml --include=*.json | grep -v "^kube/urbanlink/ingress/"
```

Attendu : la liste exacte des occurrences à traiter. `kube/urbanlink/ingress/`
est exclu — ce sont les anciens manifests Traefik, conservés à titre de
référence et non appliqués.

- [ ] **Étape 2 : réécrire le Gateway**

Dans `kube/urbanlink/ingress-istio/gateway.yaml`, remplacer les deux listes
`hosts` (HTTP et HTTPS) par les quatorze noms servis par Istio :

```yaml
      hosts:
        - "urbanlink.fr"
        - "www.urbanlink.fr"
        - "api.urbanlink.fr"
        - "auth.urbanlink.fr"
        - "nominatim.urbanlink.fr"
        - "s3.urbanlink.fr"
        - "directus.urbanlink.fr"
        - "minio.urbanlink.fr"
        - "pgadmin.urbanlink.fr"
        - "kafka.urbanlink.fr"
        - "temporal.urbanlink.fr"
        - "kibana.urbanlink.fr"
        - "kiali.urbanlink.fr"
        - "prometheus.urbanlink.fr"
```

`proxmox.urbanlink.fr` et `router.urbanlink.fr` n'y figurent pas : ils sont
servis par nginx sans passer par Istio.

Mettre à jour le commentaire d'en-tête pour refléter que le TLS est désormais
terminé par l'openresty du nœud, et que le certificat auto-signé de la
passerelle ne sert plus qu'à un accès direct au NodePort.

- [ ] **Étape 3 : réécrire les VirtualServices**

Remplacer chaque `hosts:` par son équivalent `urbanlink.fr`, renommer
`uc-kratos` en hôte `auth.urbanlink.fr`, et ajouter les deux nouveaux :

```yaml
---
# --------------------------------------------- interne : Kiali (graphe mesh)
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: uc-kiali
  namespace: urbanconnect
  labels:
    uc.ingress/tier: internal
spec:
  hosts:
    - "kiali.urbanlink.fr"
  gateways:
    - uc-gateway
  http:
    - route:
        - destination:
            host: kiali.istio-system.svc.cluster.local
            port:
              number: 20001
---
# ------------------------------------------ interne : Prometheus (metriques)
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: uc-prometheus
  namespace: urbanconnect
  labels:
    uc.ingress/tier: internal
spec:
  hosts:
    - "prometheus.urbanlink.fr"
  gateways:
    - uc-gateway
  http:
    - route:
        - destination:
            host: prometheus.istio-system.svc.cluster.local
            port:
              number: 9090
```

Ces deux-là routent vers `istio-system`, un autre namespace que celui de la
ressource. C'est permis : un `destination.host` en FQDN complet traverse les
namespaces, tant que le Service n'a pas d'`exportTo` restrictif — ce qui est le
cas ici.

- [ ] **Étape 4 : mettre à jour le domaine du playbook**

Dans `ansible/playbooks/31-urbanlink-deploy.yml`, remplacer :

```yaml
    urbanlink_domain: urbanconnect.fr
```

par :

```yaml
    urbanlink_domain: urbanlink.fr
```

- [ ] **Étape 5 : mettre à jour la configuration Kratos**

Dans `kube/urbanlink/_config/kratos/`, remplacer les URL publiques
`urbanconnect.fr` par `urbanlink.fr`, en remplaçant `kratos.` par `auth.`.

```bash
grep -rn "urbanconnect\.fr" kube/urbanlink/_config/kratos/
```

Vérifier chaque occurrence avant de la modifier : `self_service.default_browser_return_url`,
`serve.public.base_url` et les URL de redirection OIDC doivent toutes pointer sur
le nouveau nom, sinon les boucles de connexion échouent.

- [ ] **Étape 6 : redéployer**

```bash
ssh root@192.168.100.50 'cd /root/infra/ansible && ansible-playbook playbooks/31-urbanlink-deploy.yml'
```

Attendu : `failed=0` et un décompte de pods `Running` équivalent au précédent.

- [ ] **Étape 7 : vérifier le routage depuis le nœud, sans passer par nginx**

Test direct sur la passerelle Istio, pour isoler la couche :

```bash
ssh root@192.168.100.50 'for h in urbanlink.fr api.urbanlink.fr auth.urbanlink.fr pgadmin.urbanlink.fr kiali.urbanlink.fr prometheus.urbanlink.fr; do
  printf "%-28s %s\n" "$h" "$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -H "Host: $h" http://10.0.0.111:30080/)"
done'
```

Attendu : aucun `404` et aucun `503`. Un `404` signifie qu'aucun VirtualService
ne correspond au host ; un `503` que le service amont est absent.

- [ ] **Étape 8 : committer**

```bash
git add kube/urbanlink/ ansible/playbooks/31-urbanlink-deploy.yml
git commit -m "feat(kube): les quatorze hosts Istio en urbanlink.fr, plus kiali et prometheus

Remplace urbanconnect.fr dans le Gateway, les VirtualServices, la config
Kratos et le playbook. kratos. devient auth. Ajoute deux VirtualServices
vers istio-system pour Kiali et Prometheus, jusqu'ici accessibles seulement
par port-forward."
```

---

## Tâche 10 : vérification de bout en bout

Aucun code ici. C'est la tâche qui décide si le travail est livrable.

- [ ] **Étape 1 : les seize noms, depuis le poste**

```bash
for h in urbanlink.fr www.urbanlink.fr api.urbanlink.fr auth.urbanlink.fr \
         nominatim.urbanlink.fr s3.urbanlink.fr directus.urbanlink.fr \
         minio.urbanlink.fr pgadmin.urbanlink.fr kafka.urbanlink.fr \
         temporal.urbanlink.fr kibana.urbanlink.fr kiali.urbanlink.fr \
         prometheus.urbanlink.fr proxmox.urbanlink.fr router.urbanlink.fr; do
  printf "%-28s %s\n" "$h" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$h/")"
done
```

Attendu : aucun `000` (échec de connexion), aucun `502`, aucun `403`. Les
`200`, `301`, `302` et `401` sont tous acceptables — une console qui redirige
vers sa page de connexion est un succès.

Consigner le tableau des seize résultats : il va dans le README.

- [ ] **Étape 2 : le TLS est valide sans `-k`**

```bash
curl -sI --max-time 15 https://pgadmin.urbanlink.fr/ >/dev/null && echo "TLS VALIDE"
```

Attendu : `TLS VALIDE`. Un échec de vérification de certificat fait échouer
`curl` sans `-k` — c'est exactement le test voulu.

- [ ] **Étape 3 : M1 est bien corrigé**

```bash
curl -sI --max-time 10 https://router.urbanlink.fr/ | grep -i "^server"
```

Attendu : la réponse vient de RouterOS et **pas** d'`openresty` — le webfig,
pas le nœud.

- [ ] **Étape 4 : rien n'a été ouvert sur Internet**

```bash
nslookup pgadmin.urbanlink.fr 8.8.8.8 | tail -3
```

Attendu : `192.168.100.50`. Une IP privée dans la réponse publique : le nom ne
mène nulle part depuis l'extérieur.

- [ ] **Étape 5 : les services préexistants n'ont pas bougé**

```bash
for u in https://nbeny.fr/ https://proxmox.nbeny.fr/ https://folio.nbeny.fr/; do
  printf "%-28s %s\n" "$u" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$u")"
done
ssh -o ConnectTimeout=8 root@192.168.100.50 'echo "SSH noeud OK"'
```

Attendu : les mêmes codes qu'avant le chantier.

- [ ] **Étape 6 : le dépôt MikroTik tient sa promesse**

```bash
cd mikrotik && ./backup.sh && cd .. && git diff --stat mikrotik/config/current-state.txt
```

Attendu : **aucun diff**. Si le relevé diffère du dernier commit, l'état réel du
routeur a divergé du dépôt — le réconcilier avant de déclarer terminé.

- [ ] **Étape 7 : les playbooks sont rejouables**

```bash
ssh root@192.168.100.50 'cd /root/infra/ansible && ansible-playbook playbooks/32-urbanlink-edge.yml -e edge_urbanlink_cloudflare_token=... | tail -5'
```

Attendu : `changed=0`.

---

## Tâche 11 : documentation

**Fichiers :**
- Modifier : `README.md`
- Modifier : `kube/README.md`
- Modifier : `mikrotik/README.md`

- [ ] **Étape 1 : le README racine**

Ajouter dans l'arborescence de la section *Référence* :

```
├── mikrotik/                    configuration du routeur, versionnee
```

Ajouter une section **Accès aux outils** après *Accès SSH*, avec le tableau des
seize noms relevé à la tâche 10, et l'explication du chemin en trois lignes :
enregistrement A public vers IP privée, terminaison TLS et filtrage sur le nœud,
routage par `Host` sur Istio.

Ajouter au *Plan d'adressage* la ligne manquante :

| `192.168.1.0/24` | LAN maison — poste de travail, box FAI (192.168.1.254) |
| `192.168.100.0/24` | Segment lab — MikroTik (.1), nœud Proxmox (.50) |

- [ ] **Étape 2 : `kube/README.md`**

Mettre à jour la section ingress : les hosts sont en `urbanlink.fr`, le TLS
n'est plus terminé par Istio mais par l'openresty du nœud, et le certificat
auto-signé de la passerelle ne sert plus qu'à un accès direct au NodePort.
Ajouter Kiali et Prometheus à la liste des services exposés.

- [ ] **Étape 3 : `mikrotik/README.md`**

Compléter le tableau M1–M6 avec l'état final de chacun, et y reporter le
constat de l'étape 6 de la tâche 6 (les compteurs des règles `drop`).

- [ ] **Étape 4 : committer**

```bash
git add README.md kube/README.md mikrotik/README.md
git commit -m "docs: acces aux outils sous *.urbanlink.fr et depot MikroTik"
```

---

## Tâche 12 : rotation du mot de passe

À faire par **l'utilisateur**, pas par l'agent : le nouveau mot de passe ne doit
pas transiter par une conversation.

- [ ] **Étape 1 : créer un compte nommé restreint**

Depuis Winbox ou l'API :

```
/user add name=nbeny group=full address=192.168.1.0/24,192.168.100.0/24 password="..."
```

- [ ] **Étape 2 : vérifier qu'il fonctionne** avant de toucher à `admin`

```bash
cd mikrotik && MIKROTIK_USER=nbeny MIKROTIK_PASSWORD='...' ./backup.sh
```

- [ ] **Étape 3 : changer le mot de passe d'`admin` et le restreindre**

```
/user set [find name="admin"] password="..." address=192.168.1.0/24,192.168.100.0/24
```

- [ ] **Étape 4 : mettre à jour `mikrotik/secrets.env`** — qui est gitignoré.

- [ ] **Étape 5 : consigner l'existence du compte dans `00-system.rsc`**

Sans le mot de passe :

```
:if ([:len [/user find where name="nbeny"]] = 0) do={
    /user add name=nbeny group=full address=192.168.1.0/24,192.168.100.0/24
}
```

---

## Ce que ce plan ne fait pas

| | Pourquoi |
|---|---|
| Réparer la chaîne CrowdSec → MikroTik (M4) | Chantier à part entière, autant côté nœud que côté routeur. Diagnostic consigné dans `mikrotik/README.md`. |
| Mettre à niveau RouterOS et RouterBOOT (M6) | Impose un redémarrage du routeur, donc une coupure Internet du foyer. Se planifie. |
| Publier l'applicatif sur Internet | Décision prise en conception : LAN uniquement. L'étiquette `uc.ingress/tier` prépare la bascule sans la faire. |
| Remplacer `proxmox.nbeny.fr` | Le nom existant reste ; `proxmox.urbanlink.fr` est un second chemin. |
| Changer le namespace Kubernetes `urbanconnect` | Le renommer imposerait de tout redéployer pour un gain cosmétique. |
