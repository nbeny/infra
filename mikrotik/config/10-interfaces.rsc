# ============================================================================
#  Interfaces : bridge, ports, listes, wireless
# ============================================================================
#  ether1 est l'uplink vers la box FAI. ether2-5 et les deux radios sont
#  agreges dans bridge1, qui porte le segment 192.168.100.0/24.
#
#  ATTENTION -- ce fichier reconstruit l'appartenance au bridge. L'appliquer
#  depuis une machine joignable par ether2 coupe brievement la session.
#  Depuis le poste (via ether1) ou depuis le noeud, il n'y a pas de coupure.
# ============================================================================

:if ([:len [/interface bridge find where name="bridge1"]] = 0) do={
    /interface bridge add name=bridge1 protocol-mode=rstp fast-forward=yes
} else={
    /interface bridge set [find where name="bridge1"] \
        protocol-mode=rstp fast-forward=yes
}

/interface bridge port remove [find where dynamic=no]
/interface bridge port
add bridge=bridge1 interface=ether2
add bridge=bridge1 interface=ether3
add bridge=bridge1 interface=ether4
add bridge=bridge1 interface=ether5
add bridge=bridge1 interface=wlan1
add bridge=bridge1 interface=wlan2

# --- Listes d'interfaces ---------------------------------------------------
# Referencees par le NAT (30) et le pare-feu (40) : elles doivent exister
# avant eux. C'est la raison de la numerotation des fichiers.
:if ([:len [/interface list find where name="WAN"]] = 0) do={ /interface list add name=WAN }
:if ([:len [/interface list find where name="LAN"]] = 0) do={ /interface list add name=LAN }
/interface list member remove [find where dynamic=no]
/interface list member add list=WAN interface=ether1
/interface list member add list=LAN interface=bridge1

# --- Wireless --------------------------------------------------------------
# Les cles WPA vivent dans secrets.rsc.
#
# Le profil releve acceptait `wpa-psk,wpa2-psk`. On ne garde que wpa2-psk :
# WPA1 est casse depuis longtemps. Si un appareil ancien du foyer tombe,
# remettre `wpa-psk,wpa2-psk` ici et le noter dans README.md.
/interface wireless security-profiles set [find where name="default"] \
    mode=dynamic-keys authentication-types=wpa2-psk \
    unicast-ciphers=aes-ccm group-ciphers=aes-ccm

/interface wireless set [find where default-name="wlan1"] \
    mode=ap-bridge ssid=MikroTik band=2ghz-b/g channel-width=20mhz \
    frequency=2412 country=etsi security-profile=default disabled=no
/interface wireless set [find where default-name="wlan2"] \
    mode=ap-bridge ssid=MikroTik band=5ghz-a channel-width=20mhz \
    frequency=5180 country=etsi security-profile=default disabled=no
