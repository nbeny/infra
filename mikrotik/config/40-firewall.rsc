# ============================================================================
#  Pare-feu  (correctif M2)
# ----------------------------------------------------------------------------
#  Avant ce fichier, `input` et `forward` ne contenaient que des `accept` et
#  aucun `drop` final. La politique par defaut de RouterOS etant `accept`, le
#  routeur n'avait pas de pare-feu du tout.
#
#  PIEGE MAJEUR -- LIRE AVANT DE MODIFIER
#
#  Le poste de travail est sur 192.168.1.0/24, cote ether1, donc dans la liste
#  WAN. Un `drop in-interface-list=WAN` place avant les regles d'acceptation du
#  LAN maison coupe immediatement l'administration du routeur. L'ordre des
#  regles ci-dessous n'est pas cosmetique : la premiere qui correspond gagne.
#
#  Toujours appliquer ce fichier derriere un filet :
#
#    /system backup save name=pre-firewall
#    /system scheduler add name=rollback-firewall interval=5m \
#        on-event="/ip firewall filter remove [find where dynamic=no]"
#
#  Si l'acces est perdu, le scheduler retire toutes les regles en moins de
#  cinq minutes et la politique par defaut `accept` rend la main -- sans
#  redemarrage. Supprimer le scheduler une fois les verifications passees.
# ============================================================================

/ip firewall filter remove [find where dynamic=no]

# --- input : ce qui est adresse au routeur lui-meme -------------------------
/ip firewall filter
add chain=input action=accept connection-state=established,related,untracked \
    comment="retour de trafic deja autorise"
add chain=input action=drop connection-state=invalid \
    comment="paquets hors connexion"
add chain=input action=accept protocol=icmp \
    comment="ping et decouverte de MTU -- ne pas retirer"
add chain=input action=accept in-interface-list=LAN \
    comment="segment lab 192.168.100.0/24"
add chain=input action=accept src-address=10.0.0.0/24 \
    comment="VMs derriere le noeud Proxmox"
add chain=input action=accept protocol=tcp src-address=192.168.100.50 dst-port=179 \
    comment="BGP CrowdSec depuis le noeud"
add chain=input action=accept protocol=tcp src-address=192.168.1.0/24 \
    dst-port=22,8291,8729 \
    comment="administration depuis le LAN maison -- SANS CETTE REGLE, LOCKOUT"
add chain=input action=drop in-interface-list=WAN \
    comment="M2 -- tout le reste arrivant par ether1"

# --- forward : ce qui traverse ---------------------------------------------
add chain=forward action=fasttrack-connection connection-state=established,related \
    comment="deleste le CPU des flux etablis"
add chain=forward action=accept connection-state=established,related,untracked \
    comment="retour de trafic deja autorise"
add chain=forward action=drop connection-state=invalid \
    comment="paquets hors connexion"
add chain=forward action=accept src-address=10.0.0.0/24 \
    comment="VMs du lab -> partout"
add chain=forward action=accept src-address=192.168.1.0/24 dst-address=192.168.100.0/24 \
    comment="LAN maison -> segment lab (le poste de travail passe par ici)"
add chain=forward action=accept src-address=192.168.1.0/24 dst-address=10.0.0.0/24 \
    comment="LAN maison -> VMs du lab"
add chain=forward action=accept in-interface-list=LAN out-interface-list=WAN \
    comment="lab -> Internet"
add chain=forward action=drop connection-state=new connection-nat-state=!dstnat \
    in-interface-list=WAN \
    comment="M2 -- entrant non publie. Les dstnat de 30-nat.rsc passent."

# --- output ----------------------------------------------------------------
# La politique de sortie reste `accept` ; cette regle est conservee pour la
# lisibilite du chemin BGP, elle n'ajoute aucune contrainte.
add chain=output action=accept protocol=tcp dst-address=192.168.100.50 dst-port=179 \
    comment="BGP CrowdSec vers le noeud"
