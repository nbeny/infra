#!/bin/sh
# /usr/local/sbin/turtle-watchdog -- lance toutes les 2 min par turtle-watchdog.timer
#
# Le 2026-10-04, mangosd s'est fige au redemarrage d'honneur, apres « Stopping
# network threads » : processus vivant, service `active`, mais plus rien sur
# 8091. systemd ne voit rien, le serveur est mort pour les joueurs.
# Regle : actif depuis plus de 5 min ET 8091 ferme  ->  SIGKILL, puis
# Restart=always le relance.
set -eu
U=turtle-mangosd
systemctl -q is-active "$U" || exit 0
debut=$(systemctl show -p ActiveEnterTimestampMonotonic --value "$U")
age=$(( $(awk '{print int($1)}' /proc/uptime) - debut / 1000000 ))
[ "$age" -gt 300 ] || exit 0
ss -Htln 'sport = :8091' | grep -q . && exit 0
logger -t turtle-watchdog "8091 ferme depuis le demarrage (+${age}s) : mangosd fige, SIGKILL"
systemctl kill -s KILL "$U"
