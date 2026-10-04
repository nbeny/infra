#!/bin/sh
# Cree (ou remet a zero) un compte de jeu.  ->  /usr/local/sbin/turtle-compte
#
#   sudo turtle-compte <identifiant> <mot_de_passe> [rang]
#
# rang : 0 joueur (defaut), 1..4 MJ ; 4 = administrateur, comme le compte de
# test du repack (supprime). Ne PAS depasser 4 : ForcePinAccountRank = 5 dans
# realmd.conf exigerait alors un code PIN que le client n'envoie pas.
#
# Seul sha_pass_hash est ecrit. v et s sont laisses vides : realmd les calcule
# lui-meme a la premiere connexion (AuthSocket::_SetVSFields).
set -eu
[ $# -ge 2 ] || { sed -n 4,11p "$0"; exit 1; }
U=$(printf %s "$1" | tr '[:lower:]' '[:upper:]')
P=$(printf %s "$2" | tr '[:lower:]' '[:upper:]')
R=${3:-0}
case "$U" in *[!A-Z0-9_]*|'') echo "identifiant : lettres, chiffres, _ uniquement" >&2; exit 1;; esac
case "$R" in [0-4]) ;; *) echo "rang : 0 a 4" >&2; exit 1;; esac
H=$(printf '%s:%s' "$U" "$P" | sha1sum | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]')
mariadb tw_logon <<SQL
INSERT INTO account (username, sha_pass_hash, v, s, rank, joindate, active, email_verif)
VALUES ('$U', '$H', '', '', $R, NOW(), 1, 1)
ON DUPLICATE KEY UPDATE sha_pass_hash = VALUES(sha_pass_hash), v = '', s = '',
                        rank = VALUES(rank), active = 1, locked = 0;
SQL
echo "compte $U pret (rang $R)"
