# `edge_urbanlink` — publication des outils sous `*.urbanlink.fr`

Ce rôle décide, pour chacun des dix-sept noms du lab, **qui a le droit de
l'atteindre**. Il tourne sur le nœud Proxmox, qui termine le TLS et relaie vers
la passerelle Istio.

---

## Les deux paliers

Le drapeau `public` de `edge_urbanlink_services` est le seul commutateur.

| Palier | Noms | DNS | Contrôle nginx |
|---|---|---|---|
| **Public** | `urbanlink.fr`, `www`, `api`, `auth`, `nominatim`, `s3` | enregistrement **explicite** → `82.65.87.60`, proxy Cloudflare | `403` si la requête ne vient ni de Cloudflare ni du LAN |
| **Interne** | `directus`, `minio`, `pgadmin`, `kafka`, `temporal`, `kibana`, `kiali`, `prometheus`, `argo`, `proxmox`, `router` | couverts par le **wildcard** `*.urbanlink.fr` → `192.168.100.50`, DNS-only | `allow` LAN, `deny all` |

L'isolement des consoles ne repose pas sur une seule règle : leur nom résout en
IP privée **et** leur vhost refuse tout hors LAN. Les publier par accident
demanderait de se tromper deux fois.

C'est aussi pourquoi le rôle ne touche **jamais** au wildcard : il n'ajoute que
des enregistrements explicites, qui l'emportent sur lui pour les seuls noms
concernés. Une assertion finale relit la zone et échoue si le wildcard a bougé.

### Ajouter ou retirer un nom du palier public

Une ligne dans `defaults/main.yml`, puis rejouer le playbook :

```yaml
  - name: api
    hosts: ["api.urbanlink.fr"]
    public: true        # <- retirer cette ligne repasse le nom en interne
```

Retirer `public: true` remet le `deny all` côté nginx, mais **ne supprime pas
l'enregistrement DNS explicite** — le rôle ne détruit rien. Le nom continuerait
de résoudre vers l'IP publique et répondrait 403. Pour le refermer
complètement, supprimer aussi l'enregistrement dans Cloudflare : le wildcard
reprend alors la main.

---

## Trois pièges, tous constatés en production le 31/08/2026

### 1. `allow`/`deny` ne peut pas filtrer sur Cloudflare

`/etc/nginx/conf.d/30-cloudflare-realip.conf` réécrit `$remote_addr` depuis
`CF-Connecting-IP`. Le module `realip` agit en phase `POST_READ`, le module
`access` (`allow`/`deny`) en phase `ACCESS`, donc **plus tard** : quand `allow`
s'exécute, `$remote_addr` porte déjà l'adresse du visiteur final, pas celle de
Cloudflare. Un `allow <plage Cloudflare>; deny all;` refuserait tout le monde.

D'où le bloc `geo $realip_remote_addr` de `45-cloudflare-origin.conf` —
`$realip_remote_addr` est la seule variable qui désigne encore le pair TCP réel.

### 2. Le serveur par défaut gouverne le TLS de toute la socket

`50-default-deny-tls.conf` déclare `listen 443 ssl default_server`. Un serveur
par défaut ne sert pas qu'aux `Host` inconnus : nginx y lit `ssl_protocols` et
`ssl_ciphers` pour la poignée de main de **toutes** les connexions de la
socket, avant que le SNI n'ait désigné un vhost.

Écrit sans `include /etc/letsencrypt/options-ssl-nginx.conf`, ce bloc héritait
du niveau `http` du `nginx.conf` d'OpenResty — `ssl_protocols TLSv1.3;` seul,
`ssl_prefer_server_ciphers on;` — alors que tous les autres vhosts imposent
`TLSv1.2 TLSv1.3` et `prefer_server_ciphers off`. Résultat : l'origin pull de
Cloudflare échouait (HelloRetryRequest puis alerte TLS), **525 sur les six noms
publics**, tandis qu'un `openssl s_client` local négociait sans problème. Le
symptôme n'était visible que depuis Cloudflare.

### 3. `include_tasks` ne propage pas ses tags

`-t dns` exécutait l'include puis filtrait chacune des tâches de `dns.yml`,
faute de tag : le playbook affichait un succès en ne faisant rien. Il faut
`apply: tags: [dns]` sur l'include.

---

## Vérifier

```bash
# 1. Les six noms publics répondent via Cloudflare
for h in urbanlink.fr www.urbanlink.fr api.urbanlink.fr \
         auth.urbanlink.fr s3.urbanlink.fr nominatim.urbanlink.fr; do
  curl -s -o /dev/null -w "$h -> %{http_code}\n" "https://$h/"
done

# 2. Les consoles restent privées
nslookup pgadmin.urbanlink.fr 1.1.1.1     # attendu : 192.168.100.50

# 3. Rien ne passe depuis une source ni LAN ni Cloudflare
ssh root@192.168.100.50 \
  'curl -sk --interface 10.0.0.1 -o /dev/null -w "%{http_code}\n" \
   https://192.168.100.50/ -H "Host: pgadmin.urbanlink.fr"'   # attendu : 403

# 4. Host inconnu en TLS sur l'origine
curl -sk https://192.168.100.50/ -H "Host: inconnu.example.com"  # coupé (exit 56)

# 5. Rejouer ne change rien
ansible-playbook playbooks/33-urbanlink-edge.yml               # attendu : changed=0
```

---

## Le piège qui bloque tout le rôle : deux bouncers CrowdSec

Le rôle valide la configuration nginx **complète** avant de la publier, et son
`rescue` retire tout ce qu'il a posé si `nginx -t` échoue. Une configuration
déjà cassée pour une raison étrangère au rôle fait donc échouer le playbook
*et* déposer les vhosts — l'inverse de ce qu'on veut.

C'est arrivé le 2026-09-01 :

```
nginx: [emerg] "lua_package_path" directive is duplicate
       in /etc/nginx/conf.d/crowdsec_nginx.conf:1
```

**Deux** bouncers CrowdSec déclaraient `lua_package_path` dans
`/etc/nginx/conf.d/` :

| Fichier | Bouncer | État |
|---|---|---|
| `10-crowdsec_nginx.conf` | `crowdsec-openresty-bouncer` v1.1.3 | **Le vrai.** `cscli bouncers list` le montre en train de puller. |
| `crowdsec_nginx.conf` | `crowdsec-nginx-bouncer` v1.2.2 (paquet Debian) | Déposé par `apt` le 2026-08-31. Enregistré dans CrowdSec mais **jamais un seul pull**. |

Le second a été écarté (`/root/crowdsec_nginx.conf.disabled-2026-09-01`), pas
supprimé. Conséquence à connaître : `nginx -t` échouait — donc **tout
rechargement** — depuis le 2026-08-31 sans que rien ne le signale, openresty
continuant de servir la configuration chargée en mémoire. Le premier
redémarrage du service aurait fait tomber `nbeny.fr` **et** `urbanlink.fr`.

Si le paquet `crowdsec-nginx-bouncer` est réinstallé ou mis à jour, il
redéposera son fichier. Vérifier alors :

```bash
grep -rl lua_package_path /etc/nginx/conf.d/     # doit rendre UN seul fichier
/usr/local/openresty/nginx/sbin/nginx -t
```

---

## Revenir en arrière

Tout refermer, sans Ansible :

```bash
# nginx : retirer les deux fichiers du rôle et le lien des vhosts
rm -f /etc/nginx/conf.d/45-cloudflare-origin.conf \
      /etc/nginx/conf.d/50-default-deny-tls.conf \
      /etc/nginx/sites-enabled/urbanlink.fr
/usr/local/openresty/nginx/sbin/nginx -t && systemctl reload openresty
```

Côté DNS, supprimer les six enregistrements explicites dans Cloudflare : le
wildcard `*.urbanlink.fr → 192.168.100.50` reprend la main et les noms
redeviennent injoignables depuis Internet.

---

## Ce que ce rôle ne fait pas

- **Le mode SSL/TLS de la zone.** Le token est limité à `Zone:DNS:Edit` et ne
  peut pas lire ni écrire les réglages de zone. Il doit être sur **Full
  (strict)** : l'origine présente un certificat Let's Encrypt valide, donc rien
  ne s'y oppose. En *Flexible*, Cloudflare parlerait HTTP à l'origine et le
  bloc port 80 renverrait une redirection infinie.
- **Le suivi de l'IP publique.** `edge_urbanlink_public_ip` est figée. L'IP de
  la ligne n'est pas garantie fixe : si elle change, les six noms tombent
  jusqu'à un `-t dns`. Un DDNS reste à écrire.
- **La policy de bucket MinIO et le CORS de `s3.urbanlink.fr`.** Le nom est
  joignable, mais l'API S3 refuse les requêtes non signées. L'application passe
  par le relais same-origin `https://urbanlink.fr/api/minio`.
