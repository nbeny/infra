# ============================================================================
#  Resolveur DNS
# ============================================================================
#  Le routeur ne sert PAS de resolveur au reseau : allow-remote-requests reste
#  a `no`. Les noms *.urbanlink.fr sont resolus par la zone publique
#  Cloudflare, dont les enregistrements A pointent sur une IP privee.
#
#  Ouvrir un resolveur ici ajouterait un point de panne et une surface
#  d'amplification DNS pour un gain nul : aucun client n'en a besoin.
#
#  Le routeur garde son propre cache, alimente par la box via DHCP
#  (dynamic-servers), pour ses propres resolutions.
# ============================================================================

/ip dns set allow-remote-requests=no cache-size=2048 cache-max-ttl=1w
/ip dns static remove [find where dynamic=no]
