#!/usr/bin/env bash
# Rejoue la configuration versionnee sur le routeur.
#
#   ./restore.sh                       tous les fichiers de config/, dans l'ordre
#   ./restore.sh 30-nat.rsc            un seul
#   ./restore.sh 30-nat.rsc 00-system.rsc   plusieurs, dans l'ordre donne
#
# Les fichiers sont numerotes : les listes d'interfaces (10) doivent exister
# avant que le NAT (30) et le pare-feu (40) ne les referencent.
set -euo pipefail

cd "$(dirname "$0")"
if [ -f secrets.env ]; then . ./secrets.env; fi

if [ $# -gt 0 ]; then
    files=()
    for f in "$@"; do
        path="config/$(basename "$f")"
        [ -f "$path" ] || { echo "introuvable : $path" >&2; exit 1; }
        files+=("$path")
    done
else
    mapfile -t files < <(ls config/[0-9][0-9]-*.rsc | sort)
fi

echo "Application de ${#files[@]} fichier(s) sur ${MIKROTIK_HOST:-192.168.100.1}"
python3 lib/ros_apply.py "${files[@]}"
echo "Termine. Verifier avec ./backup.sh puis git diff."
