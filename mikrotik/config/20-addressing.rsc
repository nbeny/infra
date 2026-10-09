# ============================================================================
#  Adressage : adresses, routes, pools, DHCP
# ============================================================================
#  ether1 prend son adresse de la box (192.168.1.50/24 en pratique).
#  bridge1 porte la passerelle du segment lab.
# ============================================================================

:if ([:len [/ip dhcp-client find where interface="ether1"]] = 0) do={
    /ip dhcp-client add interface=ether1 add-default-route=yes \
        default-route-distance=1 use-peer-dns=yes use-peer-ntp=yes disabled=no
}

# ATTENTION -- ne jamais faire `remove [find]` puis `add` sur les adresses :
# entre les deux, bridge1 n'a plus d'adresse et la session d'administration
# tombe. On garantit d'abord, on elague ensuite.
:if ([:len [/ip address find where address="192.168.100.1/24" and interface="bridge1"]] = 0) do={
    /ip address add address=192.168.100.1/24 interface=bridge1 comment="Gateway LAN"
}
/ip address remove [find where dynamic=no and address!="192.168.100.1/24"]

# La route par defaut vient du client DHCP (dynamique). Des copies STATIQUES
# s'etaient accumulees -- cinq `0.0.0.0/0 gw 192.168.1.254` relevees le
# 2026-10-09 : on les elague, la route DHCP n'est pas concernee.
/ip route remove [find where dst-address="0.0.0.0/0" and dynamic=no]

# Seule celle-ci est statique : les VMs du lab vivent derriere le noeud Proxmox.
:if ([:len [/ip route find where static=yes and dst-address="10.0.0.0/24" and gateway="192.168.100.50"]] = 0) do={
    /ip route add dst-address=10.0.0.0/24 gateway=192.168.100.50 \
        comment="VMs Proxmox derriere vmbr1"
}

# --- DHCP du segment lab ---------------------------------------------------
# M5 : le pool releve allait de .0 a .200 -- il incluait l'adresse reseau et
# la passerelle. Un bail sur .1 aurait coupe tout le segment.
#
# Meme precaution que pour les adresses : le serveur DHCP refuse qu'on
# supprime un pool auquel il fait reference. On cree, on repointe, on elague.
:if ([:len [/ip pool find where name="dhcp_pool-lan"]] = 0) do={
    /ip pool add name=dhcp_pool-lan ranges=192.168.100.100-192.168.100.200
} else={
    /ip pool set [find where name="dhcp_pool-lan"] ranges=192.168.100.100-192.168.100.200
}
:if ([:len [/ip dhcp-server find where name="dhcp-lan"]] > 0) do={
    /ip dhcp-server set [find where name="dhcp-lan"] address-pool=dhcp_pool-lan
}
/ip pool remove [find where name!="dhcp_pool-lan"]

# M5 : l'entree relevee `192.0.0.0/8 gateway=192.168.1.50` etait un reliquat
# couvrant tout 192.x.x.x. Elle disparait ici.
#
# Le dns-server distribue passe de 192.168.100.1 -- qui ne repond pas, le
# resolveur du routeur ayant allow-remote-requests=no -- a la box, qui repond.
/ip dhcp-server network remove [find]
/ip dhcp-server network add address=192.168.100.0/24 gateway=192.168.100.1 \
    dns-server=192.168.1.254

:if ([:len [/ip dhcp-server find where name="dhcp-lan"]] = 0) do={
    /ip dhcp-server add name=dhcp-lan interface=bridge1 \
        address-pool=dhcp_pool-lan lease-time=10m authoritative=yes disabled=no
} else={
    /ip dhcp-server set [find where name="dhcp-lan"] interface=bridge1 \
        address-pool=dhcp_pool-lan lease-time=10m authoritative=yes disabled=no
}
