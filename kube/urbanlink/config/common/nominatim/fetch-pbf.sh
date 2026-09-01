#!/usr/bin/env bash
# ============================================================================
#  Recuperation de l'extrait OpenStreetMap consomme par Nominatim
# ----------------------------------------------------------------------------
#  Pourquoi un script plutot qu'un fichier dans le depot : l'extrait Europe
#  pese 32 Go. Le versionner rendrait chaque clone du depot impossible, et git
#  le garderait pour toujours meme apres suppression -- un depot ne se
#  degonfle pas. Ce qui se versionne, c'est l'URL (config/<env>/nominatim/
#  nominatim.env) et la facon de la suivre : ce fichier.
#
#  Usage :
#      config/common/nominatim/fetch-pbf.sh dev    # Nord-Pas-de-Calais, ~350 Mo
#      config/common/nominatim/fetch-pbf.sh prod   # Europe entiere, ~32 Go
#
#      DEST=/srv/osm config/common/nominatim/fetch-pbf.sh prod
#
#  L'extrait atterrit dans DEST (defaut : ./data, le repertoire que
#  docker-compose.yml monte sur /data dans le conteneur Nominatim).
#
#  ⚠️ En Kubernetes ce script ne sert PAS au chemin nominal : le conteneur
#  telecharge lui-meme depuis PBF_URL au premier demarrage. Il reste utile
#  pour pre-remplir un PVC a la main, ou pour rejouer un import sans repasser
#  par le reseau.
# ============================================================================
set -euo pipefail

ENV_NAME="${1:-dev}"
DEST="${DEST:-./data}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${HERE}/../../${ENV_NAME}/nominatim/nominatim.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Environnement inconnu : ${ENV_NAME} (aucun ${ENV_FILE})" >&2
  echo "Attendu : dev | prod" >&2
  exit 1
fi

# On lit PBF_URL sans sourcer le fichier : `source` executerait tout ce qu'il
# contient, et une ligne mal formee deviendrait une commande.
PBF_URL="$(sed -n 's/^PBF_URL=//p' "${ENV_FILE}" | head -1)"
if [[ -z "${PBF_URL}" ]]; then
  echo "Aucun PBF_URL dans ${ENV_FILE}" >&2
  exit 1
fi

FILE="$(basename "${PBF_URL}")"
TARGET="${DEST}/${FILE}"

mkdir -p "${DEST}"

echo "Environnement : ${ENV_NAME}"
echo "Source        : ${PBF_URL}"
echo "Destination   : ${TARGET}"
echo

# `--continue` : un telechargement de 32 Go se fait couper. Le relancer doit
# reprendre ou il s'etait arrete, pas repartir de zero.
curl --fail --location --continue-at - --progress-bar \
  --output "${TARGET}" "${PBF_URL}"

# Geofabrik publie un .md5 a cote de chaque extrait. Un fichier tronque
# s'importe partiellement et donne une base qui repond -- avec des trous. La
# verification n'est donc pas du zele : c'est le seul moyen de distinguer
# « import rate » de « region absente de l'extrait ».
if curl --fail --silent --location --output "${TARGET}.md5" "${PBF_URL}.md5"; then
  echo "Verification de l'empreinte…"
  ( cd "${DEST}" && md5sum --check "$(basename "${TARGET}.md5")" )
else
  echo "Pas d'empreinte publiee pour cet extrait -- verification impossible." >&2
fi

echo
echo "Termine. Pour reimporter sans retelecharger, decommenter dans"
echo "${ENV_FILE} :"
echo "    PBF_PATH=/data/${FILE}"
