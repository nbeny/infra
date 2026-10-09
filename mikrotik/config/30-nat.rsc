# ============================================================================
#  NAT : masquerade en sortie, publications entrantes
# ============================================================================
#  Les regles dynamiques (UPnP, notamment le port-mapping Tailscale du noeud)
#  ne sont pas supprimables et sont donc exclues du remove.
# ============================================================================

/ip firewall nat remove [find where dynamic=no]

# --- srcnat ----------------------------------------------------------------
# Le releve contenait huit regles de masquerade quasi identiques, empilees au
# fil du temps. Une seule est necessaire.
/ip firewall nat
add chain=srcnat action=masquerade out-interface-list=WAN \
    comment="sortie Internet du lab"

# --- dstnat : publications vers le noeud Proxmox ---------------------------
# M1 -- `dst-address=192.168.1.50` est le correctif central.
#
# Sans lui, ces regles ne portent que `in-interface=ether1` : TOUT paquet
# venant du LAN maison vers n'importe quelle adresse en 192.168.100.0/24 sur
# ces ports etait detourne vers 192.168.100.50. Le webfig du routeur lui-meme
# etait inatteignable -- https://192.168.100.1 renvoyait l'openresty du noeud.
#
# 192.168.1.50 est l'adresse que la box FAI cible deja : le trafic Internet
# continue d'etre publie a l'identique.
add chain=dstnat action=dst-nat protocol=tcp in-interface=ether1 \
    dst-address=192.168.1.50 dst-port=80 to-addresses=192.168.100.50 to-ports=80 \
    comment="HTTP -> openresty du noeud"
add chain=dstnat action=dst-nat protocol=tcp in-interface=ether1 \
    dst-address=192.168.1.50 dst-port=443 to-addresses=192.168.100.50 to-ports=443 \
    comment="HTTPS -> openresty du noeud"
add chain=dstnat action=dst-nat protocol=tcp in-interface=ether1 \
    dst-address=192.168.1.50 dst-port=22 to-addresses=192.168.100.50 to-ports=22 \
    comment="SSH -> noeud"
# (4242 "SSH VM 102" retiree le 2026-10-09 : la VM 102 n'existe plus. La
# redirection 4242 de la Freebox est a retirer a la main.)

# --- Turtle WoW (VM 150 wow-turtle) ------------------------------------------
# TCP brut, que le proxy Cloudflare ne relaie pas : turtle.urbanlink.fr est en
# DNS-only et designe directement l'IP de la maison. Cible = la VM, pas le
# noeud -- la route statique 10.0.0.0/24 -> 192.168.100.50 fait le reste.
#   3724 : realmd (authentification, liste des royaumes)
#   8091 : mangosd (le monde ; c'est le port annonce dans tw_logon.realmlist)
add chain=dstnat action=dst-nat protocol=tcp in-interface=ether1 \
    dst-address=192.168.1.50 dst-port=3724 to-addresses=10.0.0.150 to-ports=3724 \
    comment="Turtle WoW realmd -> VM 150"
add chain=dstnat action=dst-nat protocol=tcp in-interface=ether1 \
    dst-address=192.168.1.50 dst-port=8091 to-addresses=10.0.0.150 to-ports=8091 \
    comment="Turtle WoW monde -> VM 150"
