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
