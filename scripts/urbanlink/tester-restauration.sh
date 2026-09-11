#!/bin/bash
# ============================================================================
#  Exercice de restauration des donnees UrbanLink
# ----------------------------------------------------------------------------
#  A JOUER DEPUIS LE NOEUD PROXMOX. Ne touche PAS a la production : tout se
#  passe dans un conteneur Postgres jetable, detruit a la fin.
#
#      bash scripts/urbanlink/tester-restauration.sh              # la derniere
#      bash scripts/urbanlink/tester-restauration.sh 2026-09-11_0850
#
#  CE QUE CE TEST PROUVE, ET CE QU'IL NE PROUVE PAS
#
#  Qu'un fichier de sauvegarde existe et pese quelque chose ne dit RIEN. Un
#  tuyau SSH coupe produit exactement ca. Le script de sauvegarde verifie deja
#  chaque dump a l'ecriture ; ici on va plus loin, on le RESTAURE vraiment.
#
#  Le controle qui compte est le dernier : lire des LIGNES dans les tables
#  restaurees et les comparer au MANIFESTE pris le jour de la sauvegarde. Une
#  restauration qui rend une base vide « reussit » du point de vue de
#  `pg_restore` -- elle ne rend simplement plus rien.
#
#  ⚠️ L'image est `postgis/postgis`, la MEME qu'en production. Restaurer dans
#  un `postgres` nu echouerait sur les objets PostGIS : on croirait la
#  sauvegarde cassee alors que c'est le banc d'essai qui l'est.
#
#  NON COUVERT ICI, et il faut le savoir : la restauration d'une VM entiere
#  (`qmrestore`) et le retour de MinIO dans un vrai MinIO. Ce test porte sur ce
#  qui est irremplacable et se verifie en trois minutes.
# ============================================================================
set -uo pipefail

RACINE="${RACINE:-/pool1/backups/urbanlink}"
IMAGE_PG="${IMAGE_PG:-postgis/postgis:16-3.5}"
CONTENEUR="urbanlink-restauration-test"

ok=0; ko=0
titre()   { printf "\n\033[1m== %s\033[0m\n" "$1"; }
bon()     { printf "  \033[32mOK\033[0m    %s\n" "$1"; ok=$((ok+1)); }
mauvais() { printf "  \033[31mECHEC\033[0m %s\n" "$1"; ko=$((ko+1)); }

nettoyer() { docker rm -f "$CONTENEUR" >/dev/null 2>&1 || true; }
trap nettoyer EXIT

# ---------------------------------------------------------------------------
titre "Quelle sauvegarde ?"
SAUV="${1:-}"
if [ -z "$SAUV" ]; then
  SAUV=$(ls -1 "$RACINE" 2>/dev/null | grep -v '\.partiel$' | grep -v '^DERNIERE' | sort | tail -1)
fi
REP="$RACINE/$SAUV"
if [ -d "$REP" ]; then bon "$SAUV"; else mauvais "introuvable : $REP"; exit 1; fi

# Une sauvegarde qui ne tourne plus est le mode de panne le plus courant, et le
# plus silencieux : les fichiers d'hier rassurent, ils ont six mois.
titre "La sauvegarde tourne-t-elle encore ?"
if [ -f "$RACINE/DERNIERE_REUSSITE" ]; then
  AGE=$(( ($(date +%s) - $(date -d "$(cat "$RACINE/DERNIERE_REUSSITE")" +%s)) / 3600 ))
  if [ "$AGE" -le 48 ]; then bon "derniere reussite il y a ${AGE} h"
  else mauvais "derniere reussite il y a ${AGE} h (plus de 48 h : le timer tourne-t-il ?)"; fi
else
  mauvais "pas de temoin DERNIERE_REUSSITE"
fi

titre "Le manifeste est-il la ?"
MAN="$REP/MANIFESTE.txt"
if [ -f "$MAN" ]; then
  bon "manifeste present ($(grep -c . "$MAN") lignes)"
  sed 's/^/        /' "$MAN"
else
  mauvais "MANIFESTE.txt absent -- impossible de comparer l'avant et l'apres"
fi

attendu() { grep -m1 "^$1=" "$MAN" 2>/dev/null | cut -d= -f2- | tr -d ' '; }

# ---------------------------------------------------------------------------
titre "Un Postgres jetable demarre-t-il ?"
nettoyer
# ⚠️ `apparmor=unconfined` n'est pas une commodite : sur CE noeud, le profil
# AppArmor `docker-default` refuse la creation de toute socket AF_UNIX. Le
# journal du noyau le dit en clair :
#
#   apparmor="DENIED" operation="create" class="net" family="unix"
#   sock_type="stream" profile="docker-default"
#
# Postgres sort alors sur « could not create any Unix-domain sockets », y
# compris avec `unix_socket_directories=/tmp` -- ce n'est pas un probleme de
# droits sur un repertoire, c'est le LSM. Meme `bash` et `getent` sont refuses
# dans un conteneur de ce noeud.
#
# Le conteneur est jetable, local, sans reseau publie et detruit a la sortie :
# le desarmer ici n'expose rien. Le VRAI correctif est de regenerer le profil
# docker-default du noeud -- a faire separement, il concerne TOUT conteneur
# Docker de cette machine, pas seulement ce test.
#
# `fsync=off` : c'est un banc d'essai jetable. On veut mesurer que le dump se
# restaure, pas la durabilite d'une base qu'on detruit dans trois minutes.
#
# ⚠️ `--shm-size=1g` est OBLIGATOIRE, pas un confort. Docker donne 64 Mo de
# /dev/shm par defaut ; PostgreSQL s'en sert, et la restauration de `temporal`
# le depasse. Le serveur MEURT en cours de route :
#
#   pg_restore: error: error returned by PQputCopyData:
#   server closed the connection unexpectedly
#
# Le test annoncait alors « temporal : AUCUNE table restauree » -- autrement
# dit il accusait la SAUVEGARDE, qui etait parfaitement saine. Un banc d'essai
# sous-dimensionne ne rend pas un verdict prudent : il rend un FAUX verdict, et
# dans le sens le plus couteux, celui qui fait douter des sauvegardes.
docker run -d --name "$CONTENEUR" --security-opt apparmor=unconfined --shm-size=1g \
  -e POSTGRES_PASSWORD=test -e POSTGRES_DB=postgres \
  "$IMAGE_PG" -c fsync=off -c full_page_writes=off >/dev/null 2>&1
# ⚠️ `pg_isready` NE SUFFIT PAS, et c'est le piege le plus couteux de ce
# script. L'image officielle demarre un serveur TEMPORAIRE pour son
# initialisation (creation du cluster, extensions PostGIS), puis l'ARRETE pour
# lancer le vrai :
#
#   LOG: received fast shutdown request
#   PostgreSQL init process complete; ready for start up.
#   LOG: starting PostgreSQL 16.9 ...
#
# `pg_isready` repond « oui » des la phase d'initialisation. Une restauration
# lancee a ce moment-la travaille sur un serveur condamne : les petites bases
# passent, et la premiere GROSSE se fait couper au milieu --
#
#   pg_restore: error: server closed the connection unexpectedly
#
# Le test annoncait alors « temporal : AUCUNE table restauree » et accusait la
# sauvegarde. Elle etait saine : verifiee a part, elle rend 36 tables et 2601
# executions. C'est le banc d'essai qui mentait, pour la deuxieme fois.
#
# Le seul marqueur fiable est la ligne de fin d'initialisation, qui n'apparait
# qu'UNE fois. On attend d'abord elle, ensuite seulement `pg_isready`.
pret=0
for _ in $(seq 1 60); do
  if docker logs "$CONTENEUR" 2>&1 | grep -q 'init process complete'; then pret=1; break; fi
  sleep 2
done
if [ "$pret" = 1 ]; then
  pret=0
  for _ in $(seq 1 60); do
    if docker exec "$CONTENEUR" pg_isready -U postgres >/dev/null 2>&1; then pret=1; break; fi
    sleep 2
  done
fi
if [ "$pret" = 1 ]; then bon "conteneur $CONTENEUR pret (initialisation terminee)"; else mauvais "le Postgres de test n'a pas demarre"; exit 1; fi

# ---------------------------------------------------------------------------
# Les roles AVANT les bases. Sans eux, chaque `GRANT` du dump echoue -- et
# `pg_restore` continue malgre tout, en signalant des erreurs qu'on prend pour
# du bruit. C'est ainsi qu'on decouvre a la restauration reelle que personne ne
# peut se connecter.
titre "Les roles se restaurent-ils ?"
if docker exec -i "$CONTENEUR" psql -U postgres -q -d postgres < "$REP/globals.sql" >/dev/null 2>&1; then
  NB_ROLES=$(docker exec "$CONTENEUR" psql -U postgres -tAc "SELECT count(*) FROM pg_roles WHERE rolname NOT LIKE 'pg\_%'" 2>/dev/null | tr -d ' ')
  bon "$NB_ROLES roles presents apres restauration"
else
  mauvais "globals.sql refuse"
fi

# ---------------------------------------------------------------------------
titre "Les bases se restaurent-elles ?"
for f in "$REP"/*.dump; do
  base=$(basename "$f" .dump)
  docker exec "$CONTENEUR" psql -U postgres -q -c "DROP DATABASE IF EXISTS \"$base\"" >/dev/null 2>&1
  docker exec "$CONTENEUR" psql -U postgres -q -c "CREATE DATABASE \"$base\"" >/dev/null 2>&1
  # `--no-owner --no-acl` : le dump a ete pris ainsi, on reste coherent.
  # Les erreurs sont conservees : c'est le seul endroit ou on les verra.
  ERR=$(docker exec -i "$CONTENEUR" pg_restore -U postgres -d "$base" --no-owner --no-acl 2>&1 < "$f" | grep -c '^pg_restore: error' || true)
  NB_TABLES=$(docker exec "$CONTENEUR" psql -U postgres -d "$base" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null | tr -d ' ')
  if [ "${NB_TABLES:-0}" -gt 0 ] && [ "${ERR:-0}" -eq 0 ]; then
    bon "$base : $NB_TABLES tables, 0 erreur"
  elif [ "${NB_TABLES:-0}" -gt 0 ]; then
    mauvais "$base : $NB_TABLES tables mais $ERR erreurs de restauration"
  else
    mauvais "$base : AUCUNE table restauree"
  fi
done

# ---------------------------------------------------------------------------
# Le controle qui compte vraiment. Tout ce qui precede peut reussir sur une
# base vide.
titre "Les DONNEES sont-elles la, et les memes qu'au moment de la sauvegarde ?"
comparer() { # base table cle_du_manifeste
  local reel; reel=$(docker exec "$CONTENEUR" psql -U postgres -d "$1" -tAc "SELECT count(*) FROM $2" 2>/dev/null | tr -d ' ')
  local att;  att=$(attendu "$3")
  if [ -z "$reel" ]; then mauvais "$1.$2 : table absente"; return; fi
  if [ -z "$att" ] || [ "$att" = "?" ]; then bon "$1.$2 : $reel lignes (rien a comparer dans le manifeste)"; return; fi
  if [ "$reel" = "$att" ]; then bon "$1.$2 : $reel lignes, conforme au manifeste"
  else mauvais "$1.$2 : $reel lignes restaurees, $att attendues"; fi
}
comparer urbanconnect users      lignes_users
comparer urbanconnect artefacts  lignes_artefacts
comparer urbanconnect orders     lignes_orders
comparer kratos       identities lignes_identities
comparer temporal     executions lignes_temporal_executions

# Les migrations Prisma sont le squelette : une base restauree sans elles est
# une base que le backend refusera de servir. Le compte reste verifiable meme
# quand la plateforme est vide, contrairement aux lignes metier.
NB_MIG=$(docker exec "$CONTENEUR" psql -U postgres -d urbanconnect -tAc \
  "SELECT count(*) FROM _prisma_migrations WHERE finished_at IS NOT NULL" 2>/dev/null | tr -d ' ')
if [ "${NB_MIG:-0}" -gt 0 ]; then bon "_prisma_migrations : $NB_MIG migrations appliquees"
else mauvais "_prisma_migrations vide ou absente"; fi

# PostGIS : `spatial_ref_sys` porte ~8500 lignes et la geolocalisation en
# depend. Une restauration qui la perd ne casse rien de visible... jusqu'a la
# premiere recherche par distance.
NB_SRS=$(docker exec "$CONTENEUR" psql -U postgres -d urbanconnect -tAc \
  "SELECT count(*) FROM spatial_ref_sys" 2>/dev/null | tr -d ' ')
if [ "${NB_SRS:-0}" -gt 1000 ]; then bon "PostGIS : spatial_ref_sys a $NB_SRS lignes"
else mauvais "PostGIS : spatial_ref_sys a ${NB_SRS:-0} lignes (attendu > 1000)"; fi

# ---------------------------------------------------------------------------
titre "Les archives annexes sont-elles saines ?"
if [ -f "$REP/minio.tar.gz" ]; then
  if gzip -t "$REP/minio.tar.gz" 2>/dev/null; then
    bon "minio.tar.gz : $(tar -tzf "$REP/minio.tar.gz" | grep -c .) entrees, CRC valide"
  else mauvais "minio.tar.gz corrompue"; fi
else mauvais "minio.tar.gz absente"; fi

if [ -f "$REP/etcd.db" ]; then
  # ⚠️ La verification de l'empreinte a lieu a la PRISE de l'instantane, dans
  # le conteneur etcd qui seul porte `etcdutl`. Ici on ne verifie que la
  # presence et la taille -- le dire plutot que de laisser croire a un controle
  # qui n'a pas lieu.
  T=$(stat -c%s "$REP/etcd.db")
  if [ "$T" -gt 1000000 ]; then bon "etcd.db : $(numfmt --to=iec --suffix=B "$T") (empreinte verifiee a la prise)"
  else mauvais "etcd.db suspect : $T octets"; fi
else mauvais "etcd.db absent"; fi

# ---------------------------------------------------------------------------
printf "\n\033[1m== Resultat ==\033[0m\n"
printf "  %d controles reussis, %d echecs\n" "$ok" "$ko"
[ "$ko" -eq 0 ] || exit 1
