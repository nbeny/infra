#!/bin/bash
# ============================================================================
#  Exercice de restauration de la messagerie
# ----------------------------------------------------------------------------
#  A jouer DEPUIS LE NOEUD PROXMOX. Ne touche pas a la production : il ne fait
#  qu'interroger une copie restauree, deja demarree, via l'agent QEMU.
#
#  PROCEDURE COMPLETE
#
#   1. Choisir une sauvegarde :
#        pvesm list pool1-backup | grep vzdump-qemu-140
#
#   2. La restaurer sous un ID LIBRE. `--unique` regenere les adresses MAC :
#      sans cela, deux cartes identiques se disputeraient le pont.
#        qmrestore pool1-backup:backup/vzdump-qemu-140-<date>.vma.zst 141 #          --storage pool1 --unique 1
#
#   3. ISOLER AVANT DE DEMARRER. C'est l'etape a ne pas manquer : la copie
#      porte la MEME cle privee WireGuard que la production. Si elle montait
#      wg0, le VPS verrait deux pairs pour une seule cle et le courrier
#      entrant tomberait.
#        qm set 141 --name mail-restore-test --onboot 0 --memory 4096 --balloon 2048
#        qm set 141 --net0 "$(qm config 141 | sed -n 's/^net0: //p'),link_down=1"
#
#   4. Demarrer, puis attendre l'agent :
#        qm start 141
#
#   5. Jouer ce script :
#        bash scripts/mail/tester-restauration.sh
#
#   6. Detruire la copie :
#        qm stop 141 && qm destroy 141 --purge
#
#  CE QUE LE TEST PROUVE VRAIMENT. Qu'une sauvegarde existe et se decompresse
#  ne dit rien. Le vmail de Mailcow est CHIFFRE par Dovecot : il n'est lisible
#  que si les cles de /mailcow-crypt ont ete restaurees avec lui. Le controle
#  qui compte est donc le dernier -- lire l'objet et le corps d'un message.
#
#  Au passage, il valide aussi le demarrage a froid : la copie boote sans
#  intervention et la pile doit remonter seule.
# ============================================================================
set -uo pipefail
VM=141
ok=0; ko=0
titre() { printf "\n\033[1m== %s\033[0m\n" "$1"; }
bon()   { printf "  \033[32mOK\033[0m    %s\n" "$1"; ok=$((ok+1)); }
mauvais(){ printf "  \033[31mECHEC\033[0m %s\n" "$1"; ko=$((ko+1)); }

# `qm guest exec` rend un JSON ; on en extrait la sortie standard.
ex() {
  qm guest exec "$VM" --timeout 120 -- /bin/bash -c "$1" 2>/dev/null \
    | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
sys.stdout.write(d.get("out-data") or d.get("err-data") or "")' 2>/dev/null
}

titre "La copie est-elle bien isolee ?"
if qm config "$VM" | grep -q 'link_down=1'; then
  bon "carte reseau coupee : aucun risque pour la production"
else
  mauvais "CARTE RESEAU ACTIVE -- arreter immediatement la VM $VM"
  exit 1
fi

titre "Amorcage a froid"
# L'agent QEMU repond BIEN AVANT que la machine ne soit prete : il demarre tot,
# alors que Docker n'a pas encore lance ses conteneurs. Sans cette attente, le
# test conclut a une restauration ratee sur une machine qui est simplement en
# train de demarrer -- constate le 2026-09-05, 8 echecs sur 9 pour cette seule
# raison.
printf "        convergence de la pile"
for _ in $(seq 1 40); do
  n=$(ex 'docker ps --filter name=mailcow -q 2>/dev/null | wc -l')
  [ "${n:-0}" -ge 15 ] && break
  printf "."
  sleep 15
done
printf "
"

n=$(ex 'systemctl is-system-running 2>/dev/null | head -1')
case "$n" in
  running|degraded) bon "systemd a converge ($n)" ;;
  *) mauvais "systemd : ${n:-sans reponse}" ;;
esac

c=$(ex 'docker ps --filter name=mailcow -q | wc -l')
if [ "${c:-0}" -ge 15 ]; then
  bon "$c conteneurs Mailcow remontes seuls apres le demarrage a froid"
else
  mauvais "seulement ${c:-0} conteneurs Mailcow"
fi

titre "La base est-elle restauree ?"
dom=$(ex 'source /opt/mailcow-dockerized/mailcow.conf && docker compose -f /opt/mailcow-dockerized/docker-compose.yml exec -T mysql-mailcow mysql -umailcow -p"$DBPASS" mailcow -N -B -e "SELECT domain FROM domain" 2>/dev/null')
if echo "$dom" | grep -q 'urbanlink.fr'; then
  bon "domaine present en base : $(echo $dom | tr '\n' ' ')"
else
  mauvais "domaine absent de la base restauree"
fi

nb=$(ex 'source /opt/mailcow-dockerized/mailcow.conf && docker compose -f /opt/mailcow-dockerized/docker-compose.yml exec -T mysql-mailcow mysql -umailcow -p"$DBPASS" mailcow -N -B -e "SELECT COUNT(*) FROM mailbox" 2>/dev/null')
if [ "${nb:-0}" -ge 1 ]; then
  bon "$nb boite(s) aux lettres en base"
else
  mauvais "aucune boite en base"
fi

dkim=$(ex 'docker exec mailcowdockerized-redis-mailcow-1 redis-cli -a "$(grep -oP "(?<=^REDISPASS=).*" /opt/mailcow-dockerized/mailcow.conf)" --no-auth-warning HGET DKIM_PUB_KEYS urbanlink.fr 2>/dev/null | head -c 40')
if [ -n "${dkim:-}" ]; then
  bon "cle DKIM publique restauree (${dkim:0:24}...)"
else
  mauvais "cle DKIM absente -- les signatures ne vaudraient plus rien"
fi

titre "Le courrier est-il LISIBLE ? (le vrai test)"
# C'est ici que se joue la restauration. Le vmail de Mailcow est CHIFFRE par
# Dovecot : il n'est lisible que si les cles de /mailcow-crypt ont ete
# restaurees avec lui. Tout le reste peut etre parfait et ce controle echouer.

# Dovecot boucle au demarrage tant qu'il n'a pas de reseau : il tente de
# telecharger les regles SpamAssassin et sort en erreur. Sur une copie isolee
# c'est normal, il finit par tenir. Sans cette attente, doveadm repondait
# « connect(/run/dovecot/auth-userdb) failed » et le test concluait a tort que
# le courrier etait perdu.
printf "        attente de Dovecot"
for _ in $(seq 1 30); do
  if ex 'docker exec mailcowdockerized-dovecot-mailcow-1 doveadm auth cache flush 2>&1' | grep -qv 'Connection refused'; then
    if ex 'docker exec mailcowdockerized-dovecot-mailcow-1 doveadm search -u alesio@urbanlink.fr all 2>&1' | grep -qv 'Connection refused'; then
      break
    fi
  fi
  printf "."
  sleep 10
done
printf "
"

lst=$(ex 'docker exec mailcowdockerized-dovecot-mailcow-1 doveadm search -u alesio@urbanlink.fr mailbox INBOX all 2>/dev/null | wc -l')
if [ "${lst:-0}" -ge 1 ]; then
  bon "$lst message(s) indexes dans la boite de reception"
else
  mauvais "aucun message dans la boite"
  # Distinguer une restauration ratee d'une sauvegarde simplement trop ancienne.
  # Le cas s'est presente : la sauvegarde datait de 14:25:15 et le premier
  # message de 14:27:33. Le vmail restaure etait donc vide -- a juste titre.
  printf "          Verifier que la sauvegarde est POSTERIEURE au courrier :
"
  printf "            qm guest exec 140 -- /bin/bash -c \
"
  printf "              'docker exec mailcowdockerized-dovecot-mailcow-1 \
"
  printf "                 doveadm fetch -u alesio@urbanlink.fr date.received mailbox INBOX'
"
fi

# `doveadm fetch` prefixe chaque ligne du NOM DU CHAMP demande, pas du nom de
# l'en-tete : la sortie commence par « hdr.subject: », jamais par « Subject: ».
# Chercher « ^Subject: » faisait conclure a des en-tetes illisibles alors que le
# corps, lui, se dechiffrait parfaitement.
suj=$(ex 'docker exec mailcowdockerized-dovecot-mailcow-1 doveadm fetch -u alesio@urbanlink.fr "hdr.subject" mailbox INBOX 2>/dev/null | grep "^hdr.subject:" | head -3')
if [ -n "${suj:-}" ]; then
  bon "en-tetes dechiffres et lisibles :"
  echo "$suj" | sed 's/^/          /'
else
  mauvais "impossible de lire les en-tetes"
fi

corps=$(ex 'docker exec mailcowdockerized-dovecot-mailcow-1 doveadm fetch -u alesio@urbanlink.fr "body" mailbox INBOX 2>/dev/null | head -c 200 | tr -d "
"')
if [ -n "${corps:-}" ]; then
  bon "corps de message dechiffre (${#corps} octets lus)"
else
  mauvais "corps illisible : les cles de chiffrement manquent-elles ?"
fi

printf "
"
if [ "$ko" -eq 0 ]; then
  printf "[32m== Restauration validee : %d controles, aucun echec.[0m
" "$ok"
else
  printf "[31m== %d controle(s) en echec sur %d.[0m
" "$ko" "$((ok+ko))"
fi
exit "$ko"
