# ============================================================================
#  Identite, horloge, services de gestion, utilisateurs
# ============================================================================

/system identity set name=MikroTik

/system clock set time-zone-autodetect=yes time-zone-name=Europe/Paris

# --- Services de gestion ---------------------------------------------------
# Regle : rien n'ecoute sans restriction d'adresse.
#
/ip service set telnet   disabled=yes
/ip service set ftp      disabled=yes

# Webfig en clair, restreint a la SEULE adresse du noeud Proxmox : c'est nginx
# qui le publie sous router.urbanlink.fr, apres terminaison TLS et filtrage sur
# l'adresse source. Aucun autre client n'a a l'atteindre -- et surtout pas
# depuis ether1.
#
# Le saut noeud -> routeur est en clair, sur un segment a deux machines.
# L'alternative serait www-ssl avec un certificat auto-signe, que nginx devrait
# alors accepter sans le verifier : du chiffrement sans authentification, qui
# ne protegerait de rien de plus ici.
/ip service set www      address=192.168.100.50/32 disabled=no
/ip service set www-ssl  disabled=yes
/ip service set ssh      address=192.168.100.0/24,192.168.1.0/24 disabled=no
/ip service set winbox   address=192.168.100.0/24,192.168.1.0/24 disabled=no
/ip service set api-ssl  address=192.168.100.0/24,192.168.1.0/24 disabled=no

# M5 -- l'API en clair transporte le mot de passe admin en clair sur le LAN.
# api-ssl (8729) couvre exactement le meme besoin, et c'est ce qu'utilisent
# les scripts de ce depot.
/ip service set api      disabled=yes

# --- Utilisateurs ----------------------------------------------------------
# Pas de `remove [find]` ici : il emporterait le compte admin et fermerait la
# porte derriere lui.
#
# Le groupe `crowdsec` n'a que read, write, test et api : le bouncer doit
# pouvoir installer des routes blackhole, rien d'autre. Ni ssh, ni winbox,
# ni policy, ni sensitive.
:if ([:len [/user group find where name="crowdsec"]] = 0) do={
    /user group add name=crowdsec \
        policy=read,write,test,api,!local,!telnet,!ssh,!ftp,!reboot,!policy,!winbox,!password,!web,!sniff,!sensitive,!romon,!dude,!tikapp
} else={
    /user group set [find where name="crowdsec"] \
        policy=read,write,test,api,!local,!telnet,!ssh,!ftp,!reboot,!policy,!winbox,!password,!web,!sniff,!sensitive,!romon,!dude,!tikapp
}
:if ([:len [/user find where name="crowdsec"]] = 0) do={
    /user add name=crowdsec group=crowdsec
}

# Les mots de passe vivent dans secrets.rsc, applique separement et non
# versionne. Voir secrets.rsc.example.
