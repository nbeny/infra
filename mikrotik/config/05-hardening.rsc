# ============================================================================
#  Reduction de la surface de gestion  (constats M3 et M5)
# ============================================================================

# --- M3 : MAC-telnet et MAC-Winbox -----------------------------------------
# Ces deux protocoles operent en couche 2 et contournent entierement le
# filtrage IP : aucune regle de /ip firewall ne les arrete. Les laisser sur
# `all`, c'est les exposer sur le segment WAN.
/tool mac-server set allowed-interface-list=LAN
/tool mac-server mac-winbox set allowed-interface-list=LAN

# --- UPnP ------------------------------------------------------------------
# Deja correctement configure sur le routeur (releve du 30/08/2026 :
# bridge1=internal, ether1=external). On ne le desactive PAS : le noeud s'en
# sert pour le port-mapping Tailscale, et le couper degraderait la traversee
# NAT sans rien gagner. Ces lignes ne corrigent rien -- elles rendent l'etat
# reproductible sur un routeur remis a zero.
:if ([:len [/ip upnp interfaces find where interface="ether1"]] = 0) do={
    /ip upnp interfaces add interface=ether1 type=external
}
:if ([:len [/ip upnp interfaces find where interface="bridge1"]] = 0) do={
    /ip upnp interfaces add interface=bridge1 type=internal
}
/ip upnp set enabled=yes allow-disable-external-interface=no

# --- M5 : scheduler orphelin -----------------------------------------------
# `CrowdsecUpdate` appelait toutes les 15 min un script `crowdsec_import` qui
# n'existe pas : 576 executions en echec silencieux au moment du releve.
# Voir README.md, constat M4, pour le diagnostic complet.
/system scheduler remove [find where name="CrowdsecUpdate"]

# --- Horloge ---------------------------------------------------------------
# Le client NTP etait desactive. Un routeur remis a zero demarre en 1970 :
# tant que son horloge est fausse, toute verification de certificat TLS faite
# derriere lui echoue.
#
# `mode` n'est PAS reglable sous RouterOS 6 : c'est une propriete en lecture
# seule qui rapporte le mode en cours. Renseigner primary/secondary suffit a
# passer en unicast.
/system ntp client set enabled=yes \
    primary-ntp=162.159.200.1 secondary-ntp=162.159.200.123

# --- Divers ----------------------------------------------------------------
# Services laisses actifs par la configuration d'usine et inutilises ici.
/tool romon set enabled=no
/ip proxy set enabled=no
/ip socks set enabled=no
/snmp set enabled=no
