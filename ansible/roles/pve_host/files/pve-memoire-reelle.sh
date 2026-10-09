#!/usr/bin/env bash
# ============================================================================
#  Faire afficher par Proxmox la memoire REELLEMENT utilisee des VMs
# ----------------------------------------------------------------------------
#  Gere par Ansible (role pve_host). Rejoue apres chaque mise a jour de
#  qemu-server par /etc/apt/apt.conf.d/99-pve-memoire-reelle.
#
#  Proxmox calcule la memoire d'une VM a ballon par `total - free` : le cache
#  disque du guest compte comme « utilise ». Mesure le 2026-10-09 sur
#  urbanlink : 85 Go affiches, 17,7 Go reellement utilises, 70 Go de cache.
#
#  QEMU expose pourtant `stat-available-memory` (MemAvailable du guest) dans
#  les guest-stats du ballon -- Proxmox ne le lit pas. Ce script ajoute cette
#  lecture dans PVE::QemuServer::vmstatus : `mem = total - disponible`.
#
#  Seul `mem` (l'affichage et les graphiques) change. `freemem`, que lit
#  l'auto-ballooning de pvestatd, garde sa valeur d'origine. Si le guest ne
#  remonte pas la valeur, le calcul d'origine reste en place.
#
#  Garde-fous : on n'ecrit que si l'ancre existe exactement une fois, on
#  verifie que le module compile, et on restaure l'original sinon.
# ============================================================================
set -euo pipefail

FICHIER=/usr/share/perl5/PVE/QemuServer.pm
MARQUEUR='LAB-PATCH memoire-reelle'

if grep -q "$MARQUEUR" "$FICHIER"; then
  echo "deja applique"
  exit 0
fi

ANCRE='            $d->{freemem} = $info->{free_mem};'
if [ "$(grep -cF -- "$ANCRE" "$FICHIER")" != 1 ]; then
  echo "ancre introuvable ou ambigue dans $FICHIER : qemu-server a change, patch NON applique" >&2
  exit 1
fi

SAUVEGARDE="$FICHIER.avant-memoire-reelle"
cp -p "$FICHIER" "$SAUVEGARDE"

ANCRE="$ANCRE" MARQUEUR="$MARQUEUR" perl -0pi -e '
  my $ancre = $ENV{ANCRE};
  my $ajout = <<"PERL";
            # $ENV{MARQUEUR} (role pve_host, infra) : memoire hors cache disque.
            \$qmpclient->queue_cmd(vm_qmp_peer(\$vmid), sub {
                my (undef, \$r) = \@_;
                my \$st = ((\$r // {})->{return} // {})->{stats} // {};
                my \$avail = \$st->{"stat-available-memory"};
                if (defined(\$avail) && \$avail > 0 && \$avail <= \$info->{total_mem}) {
                    \$d->{mem} = \$info->{total_mem} - \$avail;
                }
            }, "qom-get", path => "/machine/peripheral/balloon0", property => "guest-stats");
PERL
  s/\Q$ancre\E\n/$ancre\n$ajout/;
' "$FICHIER"

if ! perl -I/usr/share/perl5 -e 'use PVE::QemuServer; 1' 2>/tmp/pve-memoire-reelle.err; then
  cp -p "$SAUVEGARDE" "$FICHIER"
  echo "le module ne compile plus : original restaure" >&2
  cat /tmp/pve-memoire-reelle.err >&2
  exit 1
fi

# pvestatd alimente les graphiques, pvedaemon/pveproxy l'API et l'interface.
systemctl reload-or-restart pvestatd pvedaemon pveproxy
echo "applique"
