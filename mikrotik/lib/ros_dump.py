#!/usr/bin/env python3
"""Releve la configuration vivante du routeur, menu par menu.

Produit un fichier texte destine a etre compare aux .rsc versionnes :
RouterOS 6 n'expose ni /export ni /import a l'API, ce releve en tient lieu.
"""
import sys

from ros_api import connect_from_env, RosApiError

MENUS = [
    "/system/routerboard/print", "/system/package/print",
    "/system/clock/print", "/system/ntp/client/print",
    "/system/scheduler/print", "/system/script/print",
    "/interface/print", "/interface/bridge/print", "/interface/bridge/port/print",
    "/interface/wireless/print", "/interface/wireless/security-profiles/print",
    "/interface/list/print", "/interface/list/member/print",
    "/ip/address/print", "/ip/route/print", "/ip/pool/print",
    "/ip/dhcp-server/print", "/ip/dhcp-server/network/print",
    "/ip/dhcp-server/lease/print", "/ip/dhcp-client/print",
    "/ip/dns/print", "/ip/dns/static/print",
    "/ip/firewall/filter/print", "/ip/firewall/nat/print",
    "/ip/firewall/mangle/print", "/ip/firewall/address-list/print",
    "/ip/service/print", "/ip/cloud/print", "/ip/upnp/print",
    "/ip/upnp/interfaces/print", "/ip/proxy/print", "/ip/socks/print",
    "/user/print", "/user/group/print",
    "/tool/mac-server/print", "/tool/mac-server/mac-winbox/print",
    "/tool/romon/print", "/tool/netwatch/print", "/snmp/print",
    "/certificate/print",
    "/routing/bgp/instance/print", "/routing/bgp/peer/print",
    "/routing/filter/print",
]

# Champs qui changent a chaque lecture : les garder rendrait tout diff illisible.
VOLATILE = {
    "rx-byte", "tx-byte", "rx-packet", "tx-packet", "fp-rx-byte", "fp-tx-byte",
    "fp-rx-packet", "fp-tx-packet", "bytes", "packets", "rx-drop", "tx-drop",
    "tx-queue-drop", "rx-error", "tx-error", "uptime", "free-memory",
    "cpu-load", "free-hdd-space", "write-sect-since-reboot", "write-sect-total",
    "last-logged-in", "last-link-up-time", "last-link-down-time", "link-downs",
    "expires-after", "run-count", "next-run", "time", "date", "cache-used",
    "debug-info", "state", "established", "gateway-status", "active",
    "running", "inactive", "status", "role", "edge-port", "learning",
    "forwarding", "sending-rstp", "point-to-point-port", "external-fdb-status",
    "actual-mtu", "l2mtu", "port-number", "public-address", "dst-address-list",
    ".nextid", "hw-offload", "bad-blocks", "start-time", "start-date",
    # `.id` est un handle interne reattribue des qu'un objet est recree :
    # rejouer un .rsc le fait changer sans que la configuration bouge. Le
    # garder rendrait tout diff faussement positif. L'identite d'une ligne,
    # ici, c'est son contenu.
    ".id",
}
SECRET = {"password", "wpa-pre-shared-key", "wpa2-pre-shared-key",
          "tcp-md5-key", "nv2-preshared-key", "static-key-0", "secrets",
          "management-protection-key", "nv2-sync-secret", "mschapv2-password"}


def main():
    # Sans cela, Python sous Windows ecrit des CRLF et le fichier differe
    # selon la machine qui lance backup.sh. Le releve doit etre identique
    # depuis le poste et depuis le noeud, sinon le diff n'est pas exploitable.
    sys.stdout.reconfigure(newline="\n")
    out = sys.stdout
    ros = connect_from_env()
    out.write("# Releve de la configuration vivante du MikroTik.\n")
    out.write("# Genere par mikrotik/backup.sh -- ne pas editer a la main.\n")
    out.write("# Compteurs et horodatages sont retires, secrets caviardes.\n")
    for menu in MENUS:
        out.write("\n" + "=" * 78 + "\n## " + menu + "\n" + "=" * 78 + "\n")
        try:
            rows = ros.talk([menu])
        except RosApiError as exc:
            out.write(f"  !! {exc}\n")
            continue
        if not rows:
            out.write("  (vide)\n")
            continue
        for row in rows:
            parts = []
            for k, v in row.items():
                if k in VOLATILE:
                    continue
                parts.append(f"{k}=<SECRET>" if k in SECRET else f"{k}={v}")
            out.write("  " + " ".join(parts) + "\n")
    ros.close()


if __name__ == "__main__":
    main()
