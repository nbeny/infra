# ============================================================================
#  BGP -- reception des blocages CrowdSec depuis le noeud Proxmox
# ----------------------------------------------------------------------------
#  Le noeud (AS 65001) annonce les IP a bloquer ; le filtre `crowdsec-in` les
#  installe en route blackhole sur le routeur.
#
#  CONSTAT M4 -- CETTE CHAINE NE FONCTIONNE PAS. Releve du 30/08/2026 : la
#  session est en `state=active, established=false`, elle n'a jamais ete
#  etablie. Le diagnostic complet est dans README.md.
#
#  La configuration est versionnee telle quelle pour que la reconstruction
#  soit fidele. La reparer est un chantier a part, autant cote noeud que cote
#  routeur.
# ============================================================================

# `set-check-gateway=none` est explicite : sans lui, RouterOS laisse le champ
# vide au lieu de le remettre a sa valeur par defaut, et le filtre recree
# differe de celui qui tournait. Constate par le test de non-regression.
/routing filter remove [find where chain="crowdsec-in"]
/routing filter add chain=crowdsec-in action=accept \
    set-check-gateway=none set-type=blackhole set-bgp-weight=100

/routing bgp instance set default as=65002 router-id=192.168.100.1 disabled=no

:if ([:len [/routing bgp peer find where name="CrowdSec-Bouncer"]] = 0) do={
    /routing bgp peer add name=CrowdSec-Bouncer instance=default \
        remote-address=192.168.100.50 remote-as=65001 \
        in-filter=crowdsec-in hold-time=10m keepalive-time=3m ttl=255
} else={
    /routing bgp peer set [find where name="CrowdSec-Bouncer"] \
        remote-address=192.168.100.50 remote-as=65001 \
        in-filter=crowdsec-in hold-time=10m keepalive-time=3m ttl=255
}
