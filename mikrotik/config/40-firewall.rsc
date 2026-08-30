# ============================================================================
#  Pare-feu -- ETAT RELEVE LE 30/08/2026, AVANT DURCISSEMENT
# ----------------------------------------------------------------------------
#  Constat M2 : ces regles ne contiennent aucun `drop` final. La politique par
#  defaut de RouterOS etant `accept`, le routeur n'a pas de pare-feu.
#
#  Ce fichier existe pour que le depot decrive d'abord la realite. Il est
#  remplace par la version durcie a l'etape suivante -- le diff de ce commit-la
#  est la trace exacte de ce qui a change.
# ============================================================================

/ip firewall filter remove [find where dynamic=no]
/ip firewall filter
add chain=input   action=accept protocol=tcp src-address=192.168.100.50 dst-port=179 comment="BGP CrowdSec"
add chain=output  action=accept protocol=tcp dst-address=192.168.100.50 dst-port=179 comment="BGP CrowdSec"
add chain=input   action=accept src-address=10.0.0.0/24 comment="Allow internal LAN to access router"
add chain=forward action=accept src-address=10.0.0.0/24 comment="Allow Proxmox internal LAN"
add chain=input   action=accept protocol=icmp comment="Allow ICMP ping"
add chain=forward action=fasttrack-connection connection-state=established,related
