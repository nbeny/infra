#!/bin/bash
# ============================================================================
#  Verification de bout en bout de la messagerie urbanlink.fr
# ----------------------------------------------------------------------------
#  A jouer DEPUIS LE NOEUD PROXMOX, qui est le seul point d'ou l'on peut a la
#  fois joindre la VM, le VPS et Internet :
#
#      ssh root@192.168.100.50 'bash /root/infra/scripts/mail/verifier-messagerie.sh'
#
#  Ce script ne modifie RIEN. Il ne fait qu'observer, et il echoue bruyamment :
#  chaque controle qui tombe incremente le code de sortie.
#
#  Ce qu'il ne peut pas verifier, et qu'il faut faire a la main :
#    * l'arrivee en BOITE DE RECEPTION chez Gmail et Outlook (il faut y
#      regarder) -- le script ne verifie que l'acceptation par leurs serveurs ;
#    * l'ingestion des rapports DMARC, qui n'arrivent qu'une fois par jour.
# ============================================================================
set -uo pipefail

VM=10.0.0.140          # VM de messagerie, vue du noeud
VPS=147.79.102.17      # IP d'emission
DOMAINE=urbanlink.fr
MX_ATTENDU=mail.urbanlink.fr
RESOLVEUR=1.1.1.1

echecs=0
section() { printf "\n\033[1m== %s\033[0m\n" "$1"; }
ok()      { printf "  \033[32mOK\033[0m    %s\n" "$1"; }
ko()      { printf "  \033[31mECHEC\033[0m %s\n" "$1"; echecs=$((echecs+1)); }
info()    { printf "        %s\n" "$1"; }

# `attendu` compare une valeur relevee a une valeur voulue.
attendu() { # <libelle> <obtenu> <attendu>
  if [ "$2" = "$3" ]; then ok "$1 = $2"; else ko "$1 : obtenu « $2 », attendu « $3 »"; fi
}
contient() { # <libelle> <chaine> <motif>
  if echo "$2" | grep -qi -- "$3"; then ok "$1"; else ko "$1 (motif « $3 » absent)"; fi
}

vm() { ssh -o BatchMode=yes -o ConnectTimeout=10 "nbeny@${VM}" "$@" 2>/dev/null; }

# ---------------------------------------------------------------------------
section "DNS — ce que le monde voit"
# ---------------------------------------------------------------------------
mx=$(dig +short MX "$DOMAINE" @$RESOLVEUR | awk '{print $2}' | sed 's/\.$//')
attendu "MX" "${mx:-aucun}" "$MX_ATTENDU"

a=$(dig +short A "$MX_ATTENDU" @$RESOLVEUR)
attendu "A du MX" "${a:-aucun}" "$VPS"

# Deux SPF sur un meme nom les invalident TOUS LES DEUX (permerror) : ce
# controle vaut mieux qu'une simple presence.
nb_spf=$(dig +short TXT "$DOMAINE" @$RESOLVEUR | grep -c 'v=spf1')
attendu "nombre d'enregistrements SPF" "$nb_spf" "1"
spf=$(dig +short TXT "$DOMAINE" @$RESOLVEUR | grep 'v=spf1')
contient "SPF autorise l'IP d'emission" "$spf" "ip4:$VPS"
contient "SPF se termine par -all" "$spf" '\-all'

dkim=$(dig +short TXT "dkim._domainkey.$DOMAINE" @$RESOLVEUR)
contient "DKIM publie" "$dkim" "v=DKIM1"
if [ ${#dkim} -gt 380 ]; then ok "cle DKIM de taille 2048 bits"; else ko "cle DKIM trop courte (${#dkim} caracteres)"; fi

contient "DMARC publie" "$(dig +short TXT "_dmarc.$DOMAINE" @$RESOLVEUR)" "v=DMARC1"
contient "DMARC collecte les rapports chez nous" "$(dig +short TXT "_dmarc.$DOMAINE" @$RESOLVEUR)" "dmarc@$DOMAINE"
contient "MTA-STS publie" "$(dig +short TXT "_mta-sts.$DOMAINE" @$RESOLVEUR)" "v=STSv1"
contient "TLS-RPT publie" "$(dig +short TXT "_smtp._tls.$DOMAINE" @$RESOLVEUR)" "v=TLSRPTv1"

# Le wildcard fait tenir tout le palier interne du lab : s'il bougeait, douze
# consoles deviendraient joignables depuis Internet.
attendu "wildcard interne intact" "$(dig +short A "grafana.$DOMAINE" @$RESOLVEUR)" "192.168.100.50"
attendu "nom d'acces nomade" "$(dig +short A "vpn-mail.$DOMAINE" @$RESOLVEUR)" "10.88.0.2"

ptr=$(dig +short -x "$VPS" @$RESOLVEUR | sed 's/\.$//')
if [ "$ptr" = "$MX_ATTENDU" ]; then
  ok "PTR = $ptr"
else
  ko "PTR = ${ptr:-aucun}, attendu $MX_ATTENDU (a corriger dans le hPanel Hostinger)"
fi

# ---------------------------------------------------------------------------
section "Chemin entrant — Internet vers la VM"
# ---------------------------------------------------------------------------
banniere=$(timeout 15 bash -c "exec 3<>/dev/tcp/$MX_ATTENDU/25 && head -1 <&3" 2>/dev/null)
contient "port 25 joignable depuis Internet" "$banniere" "220"
contient "banniere au bon nom" "$banniere" "$MX_ATTENDU"

# Ce qui NE DOIT PAS etre ouvert : la messagerie n'expose que le 25.
for p in 587 465 993 143; do
  if timeout 8 bash -c "exec 3<>/dev/tcp/$VPS/$p" 2>/dev/null; then
    ko "port $p ouvert sur Internet -- il ne devrait pas l'etre"
  else
    ok "port $p ferme sur Internet"
  fi
done

# ---------------------------------------------------------------------------
section "Tunnel et emission"
# ---------------------------------------------------------------------------
hs=$(vm "sudo wg show wg0 latest-handshakes | awk '{print \$2}'")
if [ -n "${hs:-}" ] && [ "$hs" -gt 0 ] 2>/dev/null; then
  age=$(( $(date +%s) - hs ))
  if [ "$age" -lt 300 ]; then ok "tunnel WireGuard actif (poignee de main il y a ${age}s)"
  else ko "derniere poignee de main il y a ${age}s -- le tunnel est peut-etre tombe"; fi
else
  ko "aucune poignee de main WireGuard"
fi

# LE controle central du design : les conteneurs doivent sortir par le VPS.
# S'ils sortaient par la maison, le courrier partirait d'une IP en Spamhaus PBL.
#
# ⚠️ Ce controle a ete le SEUL a voir la panne du 2026-09-13 au 2026-09-20 --
# et il n'a rien dit, parce qu'il faut le lancer a la main. D'ou les deux
# controles suivants, et surtout l'alerte MailEgressIPWrong cote Prometheus.
sortie=$(vm "sudo docker run --rm --network mailcowdockerized_mailcow-network curlimages/curl:latest -s -4 --max-time 20 https://ifconfig.me")
attendu "IP d'emission des conteneurs" "${sortie:-inconnue}" "$VPS"

# La regle elle-meme. La chercher explicitement donne un diagnostic immediat :
# si elle manque, on sait quoi relancer sans avoir a fouiller.
if vm "ip rule show" | grep -q "172.22.1.0/24 lookup 100"; then
  ok "regle de routage du reseau Docker presente"
else
  ko "regle « from 172.22.1.0/24 lookup 100 » ABSENTE -- lancer « systemctl start mail-tunnel-rules » sur la VM"
fi

# Les deux protections contre l'effacement par systemd-networkd. Sans elles, la
# panne du 2026-09-13 se reproduira a la prochaine mise a jour de systemd.
if vm "grep -q 'ManageForeignRoutingPolicyRules=no' /etc/systemd/networkd.conf.d/10-regles-etrangeres.conf 2>/dev/null"; then
  ok "networkd a interdiction d'effacer le routage du tunnel"
else
  ko "networkd peut effacer le routage du tunnel -- rejouer le role mail_tunnel"
fi

if vm "systemctl is-enabled --quiet mail-tunnel-rules 2>/dev/null"; then
  ok "unite de rearmement du routage active"
else
  ko "mail-tunnel-rules inactive : un redemarrage de networkd couperait l'emission en silence"
fi

# La VM, elle, doit garder sa route par defaut vers le lab : c'est ce qui la
# rend administrable tunnel coupe.
sortie_vm=$(vm "curl -s -4 --max-time 15 https://ifconfig.me")
if [ "$sortie_vm" = "$VPS" ]; then
  ko "la VM elle-meme sort par le tunnel -- elle serait injoignable s'il tombait"
else
  ok "la VM garde sa route par defaut ($sortie_vm)"
fi

# ---------------------------------------------------------------------------
section "Listes noires de l'IP d'emission"
# ---------------------------------------------------------------------------
listees=$(vm "curl -s localhost:9100/metrics | awk '/^mail_dnsbl_listed/ && \$2==1' | wc -l")
sante=$(vm "curl -s localhost:9100/metrics | awk '/^mail_dnsbl_probe_healthy/ {print \$2}'")
attendu "zones ou l'IP est listee" "${listees:-?}" "0"
attendu "sonde en bonne sante" "${sante:-?}" "1"

# ---------------------------------------------------------------------------
section "TLS et politiques"
# ---------------------------------------------------------------------------
cert=$(vm "echo QUIT | openssl s_client -starttls smtp -connect 127.0.0.1:25 -servername $MX_ATTENDU 2>/dev/null | openssl x509 -noout -subject -checkend 604800")
contient "certificat SMTP au bon nom" "$cert" "urbanlink.fr"
if echo "$cert" | grep -q "will not expire"; then ok "certificat valide plus de 7 jours"; else ko "certificat expire dans moins de 7 jours"; fi

politique=$(curl -s -m 20 "https://mta-sts.$DOMAINE/.well-known/mta-sts.txt")
contient "politique MTA-STS servie en HTTPS" "$politique" "STSv1"
contient "politique MTA-STS coherente avec le MX" "$politique" "mx: $MX_ATTENDU"

# ---------------------------------------------------------------------------
section "Services de la messagerie"
# ---------------------------------------------------------------------------
nb=$(vm "sudo docker ps --filter name=mailcow --format '{{.Names}}' | wc -l")
if [ "${nb:-0}" -ge 15 ]; then ok "$nb conteneurs Mailcow en service"; else ko "seulement ${nb:-0} conteneurs Mailcow"; fi

restarting=$(vm "sudo docker ps --filter name=mailcow --filter status=restarting -q | wc -l")
attendu "conteneurs en boucle de redemarrage" "${restarting:-?}" "0"

# L'interface interne, vue comme la voit l'openresty du noeud.
code=$(curl -sk -o /dev/null -w '%{http_code}' -m 20 https://webmail.$DOMAINE/)
if [ "$code" = "200" ] || [ "$code" = "302" ]; then ok "interface web joignable en LAN ($code)"; else ko "interface web : HTTP $code"; fi

file=$(vm "curl -s localhost:9100/metrics | awk '/^mail_queue_size/ {print \$2}'")
attendu "file d'attente" "${file:-?}" "0"

# ---------------------------------------------------------------------------
section "Sauvegardes"
# ---------------------------------------------------------------------------
derniere=$(vm "sudo ls -1t /var/backups/mailcow-data/store/ 2>/dev/null | head -1")
if [ -n "${derniere:-}" ]; then
  ok "derniere sauvegarde applicative : $derniere"
  comp=$(vm "sudo ls /var/backups/mailcow-data/store/$derniere | wc -l")
  if [ "${comp:-0}" -ge 6 ]; then ok "$comp composants sauvegardes"; else ko "seulement ${comp:-0} composants"; fi
  # Sans la cle de chiffrement, le vmail sauvegarde est illisible.
  vm "sudo test -f /var/backups/mailcow-data/store/$derniere/backup_crypt.tar.zst" \
    && ok "cle de chiffrement incluse" || ko "cle de chiffrement ABSENTE -- le vmail serait illisible"
else
  ko "aucune sauvegarde applicative"
fi

# pool1-backup : le job vzdump y ecrit depuis que pool2 (disque unique) a ete
# perdu le 2026-10-04.
if pvesm list pool1-backup 2>/dev/null | grep -q 'vzdump-qemu-140'; then
  ok "instantane vzdump de la VM present"
else
  ko "aucun vzdump de la VM 140"
fi

# ---------------------------------------------------------------------------
section "Protections anti-abus"
# ---------------------------------------------------------------------------
# Ces quatre controles portent sur le role mail_antiabus. Chacun verifie un
# EFFET, pas la presence d'un fichier de configuration.

# 1. Les compteurs de debit de Postfix. Ils etaient a zero -- illimites -- dans
#    la configuration livree par Mailcow.
debits=$(vm "sudo docker exec mailcowdockerized-postfix-mailcow-1 postconf -h   smtpd_client_connection_rate_limit smtpd_client_recipient_rate_limit 2>/dev/null | tr '\n' ' '")
if echo "$debits" | grep -qE '^[1-9][0-9]* [1-9][0-9]*'; then
  ok "compteurs de debit Postfix actifs ($debits)"
else
  ko "compteurs de debit Postfix a zero ou absents (« $debits »)"
fi

# 2. Fail2ban doit connaitre le moissonnage d'annuaire. Neuf expressions, c'est
#    le jeu d'origine de Mailcow : les notres n'ont pas ete posees.
nb_regex=$(vm "K=\$(sudo cat /opt/mailcow-dockerized/.api-key);   curl -s -H \"X-API-Key: \$K\" http://127.0.0.1:8080/api/v1/get/fail2ban   | python3 -c 'import sys,json; print(len(json.load(sys.stdin)[\"regex\"]))'")
if [ "${nb_regex:-0}" -ge 12 ]; then
  ok "Fail2ban : $nb_regex expressions (moissonnage inclus)"
else
  ko "Fail2ban : seulement ${nb_regex:-0} expressions, le moissonnage n'est pas couvert"
fi

# 3. L'agent CrowdSec de la VM doit etre vu ET valide par l'API du VPS.
agent=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "root@${VPS}"   "docker exec crowdsec cscli machines list -o json 2>/dev/null" 2>/dev/null   | python3 -c 'import sys,json
try:
    m=[x for x in json.load(sys.stdin) if x["machineId"]=="mail-vm"]
    print("valide" if m and m[0].get("isValidated") else ("non-valide" if m else "absent"))
except Exception:
    print("illisible")' 2>/dev/null)
attendu "agent CrowdSec de la VM" "${agent:-illisible}" "valide"

# 4. LE controle central : la chaine doit etre sur le hook FORWARD. Sur `input`
#    elle ne verrait jamais un paquet du port 25, qui est DNAT puis forwarde --
#    c'est precisement le defaut du bouncer livre par CrowdSec.
garde=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "root@${VPS}"   "nft list table ip mailguard 2>/dev/null" 2>/dev/null)
contient "chaine mailguard sur le hook forward" "$garde" "hook forward"
contient "mailguard filtre bien le port 25" "$garde" "tcp dport 25"

if ssh -o BatchMode=yes -o ConnectTimeout=10 "root@${VPS}"      "systemctl is-active --quiet mailguard-sync.timer" 2>/dev/null; then
  ok "minuterie de synchronisation des decisions active"
else
  ko "minuterie mailguard-sync inactive : les bannissements ne seraient jamais appliques"
fi

# ---------------------------------------------------------------------------
section "Ce qui ne doit pas avoir casse"
# ---------------------------------------------------------------------------
# Trois tentatives : ces requetes traversent Internet et le proxy Cloudflare.
# Un 522 isole -- Cloudflare n'a pas joint l'origine sur CE coup-la -- ne dit
# rien de l'etat du site. Vu le 2026-09-05 : le script annoncait francois.nbeny.fr
# en panne, six requetes lancees dans la foulee depuis deux points repondaient
# toutes 200. Un controle qui declenche sur un alea reseau apprend a ignorer
# ses propres alertes.
for site in nbeny.fr francois.nbeny.fr; do
  c=000
  for essai in 1 2 3; do
    c=$(curl -s -o /dev/null -w '%{http_code}' -m 20 "https://$site")
    case "$c" in 200|301|302) break ;; esac
    sleep 3
  done
  if [ "$c" = "200" ] || [ "$c" = "301" ] || [ "$c" = "302" ]; then
    ok "$site repond ($c)"
  else
    ko "$site : HTTP $c apres 3 tentatives"
  fi
done

# ---------------------------------------------------------------------------
printf "\n"
if [ "$echecs" -eq 0 ]; then
  printf "\033[32m== Tous les controles passent.\033[0m\n"
else
  printf "\033[31m== %d controle(s) en echec.\033[0m\n" "$echecs"
fi
exit "$echecs"
