# Protection anti-abus de la messagerie

**Date** : 2026-09-05
**Portee** : surface exposee du courrier entrant. Rien de ce qui touche a la
delivrabilite sortante n'est modifie.

## Ce qui protegeait deja, et qu'il ne fallait pas dupliquer

L'audit a d'abord servi a ne pas reinventer ce que Mailcow fait bien. Mesures
sur l'installation reelle :

| Mecanisme | Etat |
|---|---|
| **postscreen** sur le port 25 | **actif**, ~20 listes noires, seuil 6, `enforce` |
| `smtpd_hard_error_limit` | 5 (defaut Postfix : 20) |
| `smtpd_soft_error_limit` | 3 (defaut : 10) |
| `smtpd_error_sleep_time` | 10 s (defaut : 1 s) |
| `disable_vrfy_command` | `yes` |
| `reject_unauth_pipelining` | actif |
| Rspamd | listes noires, greylisting, SPF/DKIM/DMARC, bayes, fuzzy |
| Fail2ban Mailcow | 9 expressions, bannissement incrementiel |

> **Correction d'un diagnostic errone.** Un premier passage a conclu que
> postscreen etait desactive, sur la foi de `/etc/postfix/master.cf` ou la ligne
> est commentee. C'est un residu de l'image de base : le repertoire de
> configuration reel est `/opt/postfix/conf`, et postscreen y est bien actif.
> Il avait d'ailleurs deja rejete le seul attaquant observe
> (`blocked using zen.spamhaus.org`) et intercepte 14 violations de
> pre-salutation.

La defense en place est donc **reputationnelle** et solide. Les trois trous
combles ici sont d'une autre nature.

## Trou n° 1 : aucune limite de debit

Les trois compteurs de Postfix etaient a **zero**, c'est-a-dire illimites. Une
IP pouvait ouvrir autant de connexions et sonder autant d'adresses qu'elle
voulait, indefiniment.

postscreen ne comble pas ce trou : il ne connait que les adresses **deja
listees**. Une IP encore inconnue passe, et rien ne la ralentit ensuite.

Poses dans `data/conf/postfix/extra.cf`, le point d'extension prevu par Mailcow
(present dans son `.gitignore`, fusionne dans `main.cf` au demarrage) :

```
smtpd_client_connection_rate_limit      = 30   /min/IP
smtpd_client_message_rate_limit         = 60   /min/IP
smtpd_client_recipient_rate_limit       = 60   /min/IP   <- anti-moissonnage
smtpd_client_new_tls_session_rate_limit = 30   /min/IP
smtpd_client_event_limit_exceptions     = $mynetworks, 10.88.0.0/16
```

Le mode d'echec est doux, et c'est ce qui rend ces valeurs sures : en
depassement Postfix repond `450 4.7.1`, un **differe**, pas un rejet. Un
expediteur legitime retente et passe. On ne perd pas de courrier.

**Piege du fichier.** Le script de demarrage de Mailcow supprime toute ligne
nommant l'hote dans `extra.cf` puis la reinjecte en tete. Le gabarit doit donc
la porter deja, et se terminer par un unique saut de ligne : sinon le conteneur
reecrit le fichier a chaque demarrage et Ansible le voit eternellement
« changed ».

## Trou n° 2 : Fail2ban ne connaissait pas le moissonnage

Les neuf expressions de Mailcow couvrent l'authentification. Aucune ne reconnait
le sondage d'adresses, qui est pourtant le motif d'attaque le plus courant sur
un MX ouvert. Trois expressions ajoutees :

| Motif | Ce qu'il attrape |
|---|---|
| `NOQUEUE: reject: RCPT from [^\[]*\[(IP)\]:port: 5xx ` | moissonnage d'annuaire, et les rejets postscreen |
| `postscreen[...]: PREGREET n after t from [(IP)]` | le client parle avant la banniere : signature de robot |
| `postscreen[...]: COMMAND (?:TIME\|COUNT\|LENGTH) LIMIT from [(IP)]` | depassement des limites de commande |

Trois details qui decident du fonctionnement :

- **`[^\[]*\[` avant l'adresse** couvre les deux formats du journal : postscreen
  ecrit `RCPT from [1.2.3.4]:25`, smtpd ecrit `RCPT from hote[1.2.3.4]:25`.
- **Le groupe de `(?:TIME|COUNT|LENGTH)` est NON CAPTURANT.** L'analyseur de
  Mailcow lit `result.group(1)` (`data/Dockerfiles/netfilter/main.py:271`) : un
  groupe capturant en tete lui aurait fait bannir la chaine « TIME ». L'API
  accepte l'expression sans broncher — la panne aurait ete silencieuse.
- **`5[0-9][0-9]` et non `4xx`** : un `450` de greylisting vient d'un expediteur
  legitime qui retentera. Le bannir couperait le courrier.

Un script de test (`files/tester-regex-f2b.py`, joue a chaque execution du role)
confronte les expressions a de vraies lignes de journal et exige que `group(1)`
soit bien l'adresse — plus deux lignes legitimes qui ne doivent **pas**
declencher.

Bannissement porte de 30 min a 1 h, plafond de 2 h 45 a 24 h. `10.88.0.0/16` en
liste blanche : nos appareils nomades ne doivent jamais pouvoir se couper du
serveur.

## Trou n° 3 : CrowdSec etait aveugle au courrier

CrowdSec tourne sur le VPS depuis deux mois, en bonne sante, avec **82 260
decisions actives**. Et il ne voyait rien du port 25 :

```
table ip crowdsec {
    chain crowdsec-chain-input {
        type filter hook input priority filter; policy accept;
```

**Une seule chaine, sur le hook `input`.** Or rien n'ecoute sur le port 25 du
VPS : le paquet est DNAT en prerouting vers `10.88.0.2` puis **forwarde**. Il ne
traverse jamais `input`.

```
prerouting (DNAT) -> decision de routage -> destination NON locale -> FORWARD
                                                                       ^
                                              `input` n'est jamais traverse
```

### Ce qu'on a mis en place

```
      VM 10.0.0.140                        VPS 147.79.102.17
   ┌────────────────────┐               ┌──────────────────────────┐
   │ agent CrowdSec     │  decisions    │ API locale CrowdSec      │
   │ lit les journaux   │──────────────>│ (relais socket systemd   │
   │ Postfix (docker)   │   tunnel wg0  │  sur 10.88.0.1:8080)     │
   │ collection postfix │               │                          │
   └────────────────────┘               │ table nft `mailguard`    │
                                        │  hook FORWARD, dport 25  │
                                        └──────────────────────────┘
```

La detection est la ou sont les journaux, l'application la ou entre le trafic.
C'est le decoupage multi-machine natif de CrowdSec.

### Quatre decisions de conception, et leur raison

**1. Jamais la liste communautaire sur le port 25.** Seules les decisions
**locales** (`crowdsec`, `cscli`) sont appliquees au courrier. Deux raisons, la
seconde etant la vraie :

- mesure : l'attaquant SMTP observe (`136.64.100.47`) ne figurait dans **aucune**
  des quatre listes. Le gain serait faible ;
- un MTA legitime partageant une IP avec un hebergeur web compromis figure, lui,
  dans ces listes. Un `drop` sur SMTP ne se voit pas : l'expediteur retente cinq
  jours, puis rend un rebond a son utilisateur. C'est exactement le mode de
  panne que tout ce projet cherche a eviter.

**2. Une table nftables a nous, pas une chaine dans celle du bouncer.** Le
bouncer recree et vide sa table a chaque demarrage : une chaine ajoutee dedans
disparaitrait au premier redemarrage du service. `table ip mailguard` lui est
inaccessible, et se retire d'un seul `nft delete table ip mailguard`.

**3. Un relais de socket systemd, pas une modification de leur composition
Docker.** L'API de CrowdSec n'ecoutait que sur `127.0.0.1`. `systemd-socket-proxyd`
— livre avec systemd — la republie sur l'adresse du tunnel. Aucun paquet a
installer, aucun conteneur a redemarrer, et une chaine `input` de notre table
n'autorise que `10.88.0.2` a l'atteindre.

**4. `use_wal: true` — le seul reglage de leur CrowdSec qu'on modifie.** Avec un
second agent qui ecrit, le journal s'est rempli en moins d'une heure de :

```
heartbeat error: API error: updating machine last_heartbeat:
database is locked: unable to update
```

Le mode WAL est le correctif documente pour ce message exact. Apres redemarrage :
zero verrou, les deux agents valides, le bouncer et le greffon Traefik
reconnectes. Le bouncer conserve ses jeux nftables pendant le redemarrage : la
protection ne s'interrompt pas.

### Le piege qui aurait casse leur CrowdSec

`cscli machines add NOM --password X` ecrit, **sans destination explicite**, les
identifiants de la nouvelle machine dans
`/etc/crowdsec/local_api_credentials.yaml` — le fichier dont se sert l'agent
local du VPS.

CrowdSec refuse d'ecraser un fichier existant, et c'est ce refus qui a fait
echouer la premiere version de la tache :

```
Error: credentials file '/etc/crowdsec/local_api_credentials.yaml' already
exists: please remove it, use "--force" or specify a different file with "-f"
```

Le message invite a `--force`. **Le faire aurait fait perdre son mot de passe a
l'agent qui protege les trois sites du VPS.** La tache passe `-f /dev/null`, et
le commentaire dans le code interdit explicitement `--force`.

## Ce que ce role ne fait PAS, deliberement

- **Pas de tests protocolaires approfondis de postscreen.** Ils imposent une
  re-connexion, donc un differe sur le **premier** courrier de tout nouvel
  expediteur legitime. Le cout en delivrabilite entrante depasse le gain.
- **Pas de `reject_unknown_reverse_client_hostname`.** Beaucoup de petits
  expediteurs legitimes n'ont pas de rDNS valide ; Rspamd score deja ce signal
  au lieu de rejeter sec.
- **Pas de limites Rspamd.** Elles feraient doublon avec les compteurs anvil de
  Postfix, qui agissent plus tot et pour moins cher.
- **Pas de durcissement des limites d'erreur.** Celles de Mailcow sont deja plus
  strictes que les defauts de Postfix.

## Verification

Le role verifie des **effets**, pas des fichiers :

- Postfix : `postconf -h` sur la configuration **effective**, avec attente sur
  les valeurs. La premiere version attendait le seul succes de la commande et
  lisait quatre zeros : `postconf` repond avant que l'entrypoint n'ait fusionne
  `extra.cf` dans `main.cf`.
- Fail2ban : relecture par l'API, plus le test des expressions sur de vraies
  lignes.
- CrowdSec : l'agent doit etre **valide** aupres de l'API du VPS, et son journal
  doit confirmer l'abonnement aux journaux de chaque conteneur surveille. Un
  conteneur « Up » ne prouve rien : il peut tourner en boucle d'erreur
  d'authentification sans que Docker s'en emeuve.
- mailguard : la chaine doit etre sur `hook forward` **et** filtrer `tcp dport
  25`. C'est tout l'objet du role ; une chaine sur `input` ne verrait rien.

`scripts/mail/verifier-messagerie.sh` reprend ces controles.

## Retour en arriere

```bash
# 1. Application sur le port 25
ssh root@147.79.102.17 'systemctl disable --now mailguard-sync.timer \
  && nft delete table ip mailguard'

# 2. Relais de l'API
ssh root@147.79.102.17 'systemctl disable --now crowdsec-lapi-tunnel.socket'

# 3. Agent sur la VM
ssh nbeny@10.0.0.140 'cd /opt/crowdsec-mail && sudo docker compose down -v'
ssh root@147.79.102.17 'docker exec crowdsec cscli machines delete mail-vm'

# 4. Compteurs Postfix : vider extra.cf en gardant sa premiere ligne
#    (le nom d'hote), puis redemarrer postfix-mailcow.
```

Le mode WAL peut rester : il est benefique meme sans second agent.
