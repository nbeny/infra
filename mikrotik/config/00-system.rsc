# ============================================================================
#  Identite, horloge, services de gestion, utilisateurs
# ============================================================================

/system identity set name=MikroTik

/system clock set time-zone-autodetect=yes time-zone-name=Europe/Paris

# --- Services de gestion ---------------------------------------------------
# Regle : rien n'ecoute sans restriction d'adresse.
#
# Ce fichier decrit l'etat RELEVE le 30/08/2026. Deux lignes changent plus
# loin dans la mise en oeuvre, chacune avec sa verification :
#   - `www` est active et restreint au noeud (tache 4, M1), pour que nginx
#     puisse publier le webfig sous router.urbanlink.fr ;
#   - `api` est desactive (tache 5, M5) au profit d'api-ssl.
/ip service set telnet   disabled=yes
/ip service set ftp      disabled=yes
/ip service set www      disabled=yes
/ip service set www-ssl  disabled=yes
/ip service set ssh      address=192.168.100.0/24,192.168.1.0/24 disabled=no
/ip service set winbox   address=192.168.100.0/24,192.168.1.0/24 disabled=no
/ip service set api-ssl  address=192.168.100.0/24,192.168.1.0/24 disabled=no
/ip service set api      address=192.168.100.0/24,192.168.1.0/24 disabled=no

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
