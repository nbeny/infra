# Turtle WoW 1.17.2 — VM 150 `wow-turtle`

Serveur de jeu WoW 1.12 modifié par Turtle WoW, publié sous
`turtle.urbanlink.fr`.

```
Client Turtle 1.17.2 (build ≥ 7199)
   │  realmlist turtle.urbanlink.fr
   ▼
turtle.urbanlink.fr  A 82.65.87.60  (Cloudflare, DNS-only)
   │
Freebox ──► MikroTik dstnat 3724, 8091 ──► 10.0.0.150 (VM 150, pool1)
                                            ├─ turtle-realmd   :3724
                                            ├─ turtle-mangosd  :8091
                                            └─ MariaDB 11.8    127.0.0.1 seulement
```

## D'où vient le code — à lire avant toute chose

L'archive `TurtleWoW 1172.7z` est un *repack* Windows du serveur, tiré de la
**fuite de 2024** (dépôt `Winfidonarleyan/turtle-wow`, dossier
`Dumps/Source Code/16 - Development_server/patch_1172`). Le README de ce dépôt
avertit que le code **peut contenir des portes dérobées**.

D'où trois choix :

- **On recompile depuis les sources** au lieu de lancer `mangosd.exe` sous
  Wine. Un binaire compilé ici se relit ; un `.exe` tiré d'un forum, non. Une
  recherche des motifs évidents (`system()`, IP en dur, URL) n'a rien trouvé
  d'anormal : les appels `system()` font de la rotation de journaux et un
  `git push` de développement, qui échoue sans dépôt. **Ce n'est pas un audit
  complet.**
- **La VM est cloisonnée** (`scripts/turtle/nftables.conf`) : en entrée, rien
  d'autre que le jeu et SSH depuis le rebond ; en sortie, aucune connexion
  nouvelle vers 10/8, 172.16/12, 192.168/16. Elle ne peut joindre ni la
  messagerie, ni urbanlink, ni le nœud, ni le LAN.
  **Limite :** ce filtre vit dans la VM. Le vrai cloisonnement serait le
  pare-feu Proxmox (`firewall=1` sur net0), désactivé sur tout le cluster
  (`docs/audit-securite.md`, constat 4).
- **Aucune donnée de joueur n'est reprise.** Les bases du repack ne
  contenaient que le compte de test du repackeur (`123`, rang 4 = admin) et
  deux personnages. Ils ont été supprimés. Le reste du dépôt de la fuite
  (demandes de support, journaux de joueurs) n'a pas été téléchargé.

## Disposition sur la VM

| Chemin | Contenu |
|---|---|
| `/opt/turtle/src` | sources `patch_1172` (clone partiel du dépôt de la fuite) |
| `/opt/turtle/build` | arbre CMake |
| `/opt/turtle/server/bin` | `mangosd`, `realmd` |
| `/opt/turtle/server/etc` | `mangosd.conf`, `realmd.conf`, `anticheat.conf` (mot de passe BDD dedans, 640) |
| `/opt/turtle/server/data` | dbc, maps, vmaps, mmaps du repack (3,1 Go) |
| `/opt/turtle/server/logs` | journaux et fichiers pid |
| `/opt/turtle/.dbpass` | mot de passe de l'utilisateur MariaDB `turtle` (600, root) |

Bases : `tw_world`, `tw_char`, `tw_logon`, `tw_logs`, reprises du datadir
MariaDB 10.3 du repack par `mysqldump`, puis importées dans le MariaDB 11.8 de Debian.

## Compiler

Deux correctifs locaux sont nécessaires avec la chaîne d'outils de Debian 13 :

1. `cmake/FindMySQL.cmake` : `exec_program` n'existe plus depuis CMake 3.28.
   Il est remplacé par `execute_process(COMMAND ${MYSQL_CONFIG} --include …)`, et
   les chemins sont passés explicitement :
   `-DMYSQL_LIBRARY=/usr/lib/x86_64-linux-gnu/libmariadb.so -DMYSQL_INCLUDE_DIR=/usr/include/mariadb`.
2. `dep/include/rapidjson/document.h:319` : l'opérateur d'affectation de
   `GenericStringRef` assigne un membre `const`, ce que GCC 14 refuse. Le
   correctif amont le remplace par `= delete`.

```bash
cmake /opt/turtle/src -DCMAKE_INSTALL_PREFIX=/opt/turtle/server -DCMAKE_BUILD_TYPE=Release \
  -DDEBUG_SYMBOLS=OFF -DUSE_DISCORD_BOT=OFF -DUSE_LIBCURL=OFF -DUSE_EXTRACTORS=OFF \
  -DMYSQL_LIBRARY=/usr/lib/x86_64-linux-gnu/libmariadb.so -DMYSQL_INCLUDE_DIR=/usr/include/mariadb
make -j5 && make install
```

## Pièges

- **`Console.Enable = 0` est obligatoire.** Sous systemd, stdin est
  `/dev/null`. Le thread console lit une fin de fichier et appelle
  `World::StopNow` : le serveur s'arrête dès qu'il a démarré.
- **MariaDB en `lower_case_table_names = 1`**, comme sous Windows, où le repack
  a créé ses tables. Ce réglage ne s'applique qu'à un datadir **neuf**.
- **Le port du monde est 8091**, pas le 8085 habituel de MaNGOS. C'est la
  valeur de `tw_logon.realmlist.port` ; les deux doivent rester alignés.
- **Redémarrage hebdomadaire voulu par le serveur.** Le calcul d'honneur
  (`AutoHonorRestart = 1`) arrête mangosd chaque semaine avec le **code 0**.
  Sous Windows, la boucle du `.bat` le relançait ; ici, c'est
  `Restart=always`. Le 2026-10-04, le premier de ces arrêts s'est **figé**
  après « Stopping network threads » : service `active`, plus rien sur 8091.
  `turtle-watchdog.timer` (toutes les 2 min) tue mangosd s'il est actif depuis
  plus de 5 min sans écouter sur 8091.
- **Calendrier d'honneur hérité du repack.** `tw_char.saved_variables` datait
  de 2024, et chaque démarrage n'avance la maintenance que de 7 jours. Le
  serveur aurait enchaîné une cinquantaine de redémarrages. Remède appliqué le
  2026-10-04 (mangosd arrêté) :
  `UPDATE tw_char.saved_variables SET lastHonorMaintenanceDay=0, nextHonorMaintenanceDay=0, honorMaintenanceMarker=0;`
  Avec `last = 0`, `HonorMaintenancer::Initialize` recalcule les deux dates
  à partir d'aujourd'hui. À refaire après toute restauration d'une vieille base.
- **Deux numéros de build.** Le client 1.17.2 s'annonce en 7199 à realmd
  (`RealmList.cpp`), mais en **5875** au serveur de monde
  (`IsAcceptableClientBuild`). Un outil de test qui envoie 7199 partout reçoit
  « version mismatch » du monde ; ce n'est pas une panne.
- **Rang des comptes ≤ 4.** `ForcePinAccountRank = 5` : au-delà, realmd exige
  un code PIN que le client n'envoie pas.

## Exploitation

```bash
ssh -J root@192.168.100.50 nbeny@10.0.0.150

sudo turtle-compte MONCOMPTE 'motdepasse' 4     # 4 = MJ/admin, 0 = joueur
sudo systemctl status turtle-realmd turtle-mangosd
sudo journalctl -u turtle-mangosd -f
tail -f /opt/turtle/server/logs/server.log
```

Côté client : `realmlist.wtf` → `set realmlist turtle.urbanlink.fr`.

La Freebox fait la boucle NAT : depuis le LAN, l'IP publique fonctionne aussi.

## Site wow.urbanlink.fr (inscription, téléchargement du client)

Dépôt `nbeny/wow-urbanlink` (Next.js). Tourne sur cette VM :
`wow-site.service`, utilisateur `wowsite`, `/srv/wow-site/current`, port 3000.

- **Comptes** : le site écrit `tw_logon.account` comme `turtle-compte`
  (rang 0 uniquement), avec l'utilisateur MariaDB `wowsite` limité par
  colonnes : lecture de `id, username, sha_pass_hash, banned, active`,
  insertion, mise à jour de `sha_pass_hash, v, s` ; `online` de
  `tw_char.characters` pour le compteur. Ni DELETE ni écriture du rang.
- **Client** : `/srv/wow-site/client/TurtleWoW-UrbanLink.zip` (+ `.sha256`),
  servi aux seuls comptes connectés. Fabrication et dépôt : README du dépôt.
- **Exposition** : service `wow` de `edge_urbanlink`, en `direct: true`
  (DNS-only, sans filtre Cloudflare : 9 Go ne passent pas par le CDN gratuit).
  `nftables.conf` n'ouvre 3000 qu'à `10.0.0.1`.
- **Boutique** (points gagnés en jeu, jamais achetés) : base `wow_site`,
  livreur `wow-shop.timer` chaque minute sous l'utilisateur et le compte
  MariaDB `wowshop`, seul autorisé à écrire dans le jeu (`level`/`xp` de
  `characters`, `character_spell`, `character_skills`, INSERT dans
  `pending_commands`). Détail : README de `wow-urbanlink`.
- ⚠️ `tw_char.characters`, `character_skills`, `character_spell` sont en
  **MyISAM** : un `ROLLBACK` ne les annule pas.
- Secrets : `/etc/wow-site/env` (640 root:wowsite) et `shop.env`
  (640 root:wowshop), générés par
  `deploy/install-vm.sh`, jamais versionnés.

## Réseau

- MikroTik : deux `dstnat` dans `mikrotik/config/30-nat.rsc` (3724, 8091 →
  10.0.0.150).
- Freebox : elle doit faire suivre 3724 et 8091 vers 192.168.1.50 (MikroTik),
  ou y avoir sa DMZ.
- DNS : `turtle.urbanlink.fr A 82.65.87.60`, **nuage gris**. Le proxy
  Cloudflare gratuit ne relaie que HTTP(S) ; en orange, le jeu ne se connecte
  pas. Comme pour les noms publics de `edge_urbanlink`, l'enregistrement est
  à rejouer si l'IP de la Freebox change.

## Talents 1.18 côté serveur (2026-10-04)

Le client est en 1.18.x, le serveur en 1.17.2 : leurs arbres de talents n'ont
que 161 identifiants en commun, tous différents. Le client envoyait donc des
talents inconnus et le serveur les ignorait sans rien dire (`Player::LearnTalent`).

Choix : **le serveur adopte les talents du client**.

- `data/dbc/Talent.dbc` et `TalentTab.dbc` remplacés par ceux du client
  (`patch-9.mpq`, chiffré : clé = HashString du nom de fichier). Originaux :
  `*.dbc.orig-1172`.
- `tw_world.spell_template` : les sorts des talents viennent de la base, pas
  du `Spell.dbc`. Import depuis le `Spell.dbc` du client :
  - 331 sorts **nouveaux** (aucun mob, objet ni script ne les utilise) ;
  - 681 sorts **mis à jour** : rangs de talents et sorts qu'ils déclenchent,
    modifiés en 1.18 et utilisés par aucun mob, objet ni script ;
  - **4 sorts laissés en 1.17.2** car aussi utilisés par un mob, un objet ou
    un script : on ne change pas le comportement du monde.
  Les colonnes propres au serveur (`effectBonusCoefficient*`, `customFlags`)
  ne sont pas touchées. Correspondance colonnes ↔ champs DBC validée par
  aller-retour sur 1 998 sorts (seuls écarts : textes et 5 réglages serveur).
- Les talents qui modifient d'autres sorts marchent sans `spell_affect` : le
  serveur prend alors le masque `EffectItemType` du sort (`LoadSpellAffects`).
- Exige un redémarrage de mangosd (DBC et `spell_template` chargés au démarrage).

**Revenir en arrière**, mangosd arrêté :

```bash
B=/opt/turtle/backup-talents-118
sudo mariadb < $B/retour-1-supprimer-nouveaux.sql          # retire les 331 nouveaux
sudo mariadb tw_world < $B/spell_template_avant.sql        # rétablit les 681
for f in Talent TalentTab; do sudo cp -p /opt/turtle/server/data/dbc/$f.dbc.orig-1172 /opt/turtle/server/data/dbc/$f.dbc; done
```

Puis réinitialiser les talents des personnages qui en ont posé.
