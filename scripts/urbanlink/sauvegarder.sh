#!/bin/bash
# ============================================================================
#  Sauvegarde des donnees du cluster UrbanLink
# ----------------------------------------------------------------------------
#  A JOUER DEPUIS LE NOEUD PROXMOX. Declenche par urbanlink-sauvegarde.timer.
#
#  CE QUE CE SCRIPT SAUVEGARDE, ET POURQUOI PAS LE RESTE
#
#  Le depot d'infrastructure reconstruit l'INFRASTRUCTURE. Il ne reconstruit
#  pas les DONNEES. La distinction a longtemps ete invisible parce que la
#  plateforme etait vide ; elle cesse de l'etre au premier utilisateur reel.
#
#    urbanconnect  | annonces, commandes, messages, avis      | IRREMPLACABLE
#    kratos        | identites et justificatifs de connexion  | IRREMPLACABLE
#    temporal(+_visibility) | sagas en cours, versements, litiges | IRREMPLACABLE
#    directus      | contenus editoriaux                      | IRREMPLACABLE
#    globals       | roles et mots de passe Postgres          | sans eux, rien ne se restaure
#    MinIO         | photos deposees + corpus legal publie    | IRREMPLACABLE
#    etcd          | etat du cluster Kubernetes               | gain de TEMPS
#
#  Volontairement ABSENTS, parce qu'ils se reconstruisent :
#    Elasticsearch  -> `npm run search:reindex` depuis Postgres
#    Nominatim      -> 95 Go re-importables depuis Geofabrik (quelques heures)
#    Redis          -> cache, OTP, presence : perissable par nature
#
#  etcd est la ligne intermediaire : ArgoCD sait tout redeployer depuis git,
#  donc l'instantane n'est pas indispensable -- il evite seulement plusieurs
#  heures de remontage. 403 Mo par jour pour ca, c'est donne.
#
#  OU ATTERRIT LA SAUVEGARDE, ET POURQUOI PAS AILLEURS
#
#  Sur pool1 (raidz1, trois disques), JAMAIS sur pool2. `pool2-backup` est un
#  repertoire /pool2/backups : il vit sur le MEME disque -- un seul Hitachi --
#  que les disques de VM qu'il est cense proteger. Ce disque meurt, les deux
#  partent ensemble. Ce n'etait pas une sauvegarde, c'etait une copie.
#
#  ⚠️ pool1 est dans le MEME serveur. Ca protege d'une panne de disque et d'une
#  fausse manoeuvre, PAS d'un incendie ni d'un vol. La copie hors-site reste a
#  faire, et ce script ne pretend pas la remplacer.
#
#  RIEN N'EST ECRIT SUR LE DISQUE DE LA VM
#
#  Chaque dump est diffuse par le tuyau SSH et atterrit directement sur pool1.
#  Une sauvegarde qui a besoin de place sur la machine qu'elle sauvegarde
#  echoue exactement le jour ou on en a besoin -- disque plein, disque mourant.
#
#  ⚠️ Aucun `-t` sur ssh ni sur kubectl exec : un pseudo-terminal traduit les
#  fins de ligne et CORROMPT silencieusement un dump binaire. Le fichier a la
#  bonne taille, et `pg_restore` le refuse le jour de la restauration.
# ============================================================================
set -euo pipefail

VM_SSH="${VM_SSH:-nbeny@10.0.0.111}"
NS="${NS:-urbanconnect}"
RACINE="${RACINE:-/pool1/backups/urbanlink}"
IMAGE_PG="${IMAGE_PG:-postgis/postgis:16-3.5}"

# Retention. Les dumps logiques pesent des dizaines de Mo : garder loin coute
# presque rien, et c'est la profondeur qui rattrape une corruption decouverte
# tard -- le cas ou les sauvegardes recentes contiennent deja le degat.
GARDER_QUOTIDIENS="${GARDER_QUOTIDIENS:-14}"
GARDER_HEBDOS="${GARDER_HEBDOS:-8}"
GARDER_MENSUELS="${GARDER_MENSUELS:-12}"

HORODATAGE=$(date +%Y-%m-%d_%H%M)
CIBLE="$RACINE/$HORODATAGE"
# On ecrit dans un repertoire `.partiel` renomme SEULEMENT a la fin. Sans ca,
# une coupure a mi-course laisse un repertoire date qui a l'air complet : la
# retention le compte comme une sauvegarde valide et finit par supprimer la
# derniere vraie.
TRAVAIL="$CIBLE.partiel"

journal() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }
echec()   { printf '%s  ECHEC: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

sur_vm() { ssh -o BatchMode=yes -o ConnectTimeout=20 "$VM_SSH" "$@"; }

# ⚠️ `stat` et surtout PAS `du` : sur ZFS, `du` rend les blocs ALLOUES, et
# l'allocation n'a pas encore eu lieu juste apres l'ecriture -- la transaction
# n'est pas validee. Un dump de 11 Mo s'affiche alors « 512 ». Le journal
# annoncerait des sauvegardes vides qui n'en sont pas et, pire, rendrait une
# sauvegarde REELLEMENT vide indiscernable des autres. Constate a la deuxieme
# execution, le 2026-09-11.
taille() { numfmt --to=iec --suffix=B "$(stat -c%s "$1")"; }

# ---------------------------------------------------------------------------
#  Verifications d'amont
# ---------------------------------------------------------------------------
command -v docker >/dev/null || echec "docker absent : il sert a VERIFIER les dumps (pg_restore)"
docker image inspect "$IMAGE_PG" >/dev/null 2>&1 \
  || echec "image $IMAGE_PG absente. docker pull $IMAGE_PG"

sur_vm true 2>/dev/null || echec "VM injoignable en SSH ($VM_SSH)"

POD_PG=$(sur_vm "kubectl -n $NS get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}'" 2>/dev/null || true)
[ -n "$POD_PG" ] || echec "aucun pod postgres dans $NS"

# ⚠️ Une sauvegarde prise pendant que le pod redemarre rendrait un dump
# tronque SANS erreur. On exige qu'il soit pret.
PRET=$(sur_vm "kubectl -n $NS get pod $POD_PG -o jsonpath='{.status.containerStatuses[0].ready}'")
[ "$PRET" = "true" ] || echec "$POD_PG n'est pas pret ($PRET)"

mkdir -p "$TRAVAIL"
# ⚠️ Une sauvegarde N'EST PAS un fichier ordinaire. `globals.sql` contient les
# empreintes SCRAM-SHA-256 de TOUS les roles Postgres -- urbanconnect, kratos,
# temporal, directus -- et les dumps portent les donnees personnelles des
# membres. Le defaut d'un `mkdir` (0755) les rendait lisibles par n'importe
# quel compte du noeud.
chmod 700 "$RACINE" "$TRAVAIL"
umask 077
journal "cible : $CIBLE (pod $POD_PG)"

# ---------------------------------------------------------------------------
#  1. Postgres
# ---------------------------------------------------------------------------
# Les ROLES d'abord. Ils ne sont dans AUCUN dump de base : `pg_dump` ne sort
# que le contenu d'une base. Restaurer sans eux donne des tables dont le
# proprietaire n'existe pas, et des `GRANT` qui echouent en cascade.
journal "dump des roles et parametres globaux"
sur_vm "kubectl -n $NS exec $POD_PG -- pg_dumpall -U urbanconnect --globals-only" \
  > "$TRAVAIL/globals.sql" || echec "pg_dumpall --globals-only"
[ -s "$TRAVAIL/globals.sql" ] || echec "globals.sql est vide"

BASES=$(sur_vm "kubectl -n $NS exec $POD_PG -- psql -U urbanconnect -d postgres -tAc \
  \"SELECT datname FROM pg_database WHERE datistemplate=false AND datname<>'postgres'\"" \
  | tr -d '\r')
[ -n "$BASES" ] || echec "aucune base listee"

for base in $BASES; do
  journal "dump de $base"
  # Format `custom` (-Fc) : compresse, et surtout RESTAURABLE TABLE PAR TABLE.
  # Un dump SQL brut ne se restaure qu'en entier ou pas du tout -- inutilisable
  # le jour ou l'on veut recuperer UNE table effacee par erreur.
  sur_vm "kubectl -n $NS exec $POD_PG -- pg_dump -U urbanconnect -Fc --no-owner --no-acl -d $base" \
    > "$TRAVAIL/$base.dump" || echec "pg_dump $base"

  # VERIFICATION IMMEDIATE. Qu'un fichier existe et pese quelque chose ne
  # prouve rien : c'est precisement ce que produit un tuyau coupe. `pg_restore
  # --list` lit la table des matieres du dump, donc echoue sur un fichier
  # tronque ou corrompu -- au moment ou l'on peut encore recommencer, pas six
  # mois plus tard.
  NB=$(docker run --rm -i "$IMAGE_PG" pg_restore --list < "$TRAVAIL/$base.dump" 2>/dev/null \
       | grep -cv '^;' || true)
  [ "${NB:-0}" -gt 0 ] || echec "$base.dump illisible par pg_restore (tronque ?)"
  journal "  $base : $(taille "$TRAVAIL/$base.dump"), $NB objets verifies"
done

# ---------------------------------------------------------------------------
#  2. MinIO
# ---------------------------------------------------------------------------
# Copie au niveau FICHIERS du magasin d'objets. Suffisant pour un MinIO a un
# seul noeud : les objets y sont immuables, on ne risque pas de capturer une
# ecriture a moitie faite sur un objet deja publie.
#
# ⚠️ On passe par le VOLUME cote hote, pas par le conteneur. L'image MinIO est
# entierement distroless : ni `tar`, ni `mc`, ni meme `sh`. `kubectl exec` et
# `kubectl cp` y sont donc inutilisables -- `kubectl cp` a besoin de `tar` DANS
# le conteneur. Verifie le 2026-09-11, la premiere execution est morte dessus.
#
# Le chemin est LU sur le PV, jamais ecrit en dur : il contient l'UUID du PVC,
# qui change des que le volume est recree.
journal "archive MinIO"
PVC_MINIO=$(sur_vm "kubectl -n $NS get pvc -l app=minio -o jsonpath='{.items[0].metadata.name}'" 2>/dev/null || true)
[ -n "$PVC_MINIO" ] || PVC_MINIO=minio-data-minio-0
CHEMIN_MINIO=$(sur_vm "kubectl -n $NS get pvc $PVC_MINIO -o jsonpath='{.spec.volumeName}' 2>/dev/null \
  | xargs -r -I{} kubectl get pv {} -o jsonpath='{.spec.local.path}{.spec.hostPath.path}'" 2>/dev/null || true)
if [ -n "$CHEMIN_MINIO" ]; then
  sur_vm "sudo tar -cf - -C '$CHEMIN_MINIO' ." | gzip > "$TRAVAIL/minio.tar.gz" \
    || echec "archive MinIO"
  # `gzip -t` relit l'archive entiere et verifie son CRC : un tuyau coupe ne
  # passe pas ce test, alors que le fichier a l'air parfaitement normal.
  gzip -t "$TRAVAIL/minio.tar.gz" || echec "minio.tar.gz corrompue"
  NB_OBJ=$(tar -tzf "$TRAVAIL/minio.tar.gz" | grep -c . || true)
  journal "  minio : $(taille "$TRAVAIL/minio.tar.gz"), $NB_OBJ entrees"
else
  echec "chemin du volume MinIO introuvable (PVC $PVC_MINIO)"
fi

# ---------------------------------------------------------------------------
#  3. etcd
# ---------------------------------------------------------------------------
# `etcdctl snapshot save` n'ecrit QUE dans un fichier : il ne sait pas diffuser
# sur la sortie standard. On le fait donc ecrire dans /var/lib/etcd -- le SSD,
# 31 Go libres -- puis on relit le fichier DEPUIS LA VM.
#
# ⚠️ Le relire par `kubectl exec ... cat` est IMPOSSIBLE : le conteneur etcd
# est distroless, il n'a pas `cat` (meme piege que MinIO ci-dessus, qui n'a ni
# `tar` ni `sh`). Mais /var/lib/etcd est un montage hostPath : le fichier est
# visible tel quel sur la VM, ou `cat` existe. C'est aussi plus direct -- rien
# ne transite par l'API Kubernetes.
journal "instantane etcd"
CERTS="--cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key"
TMP_ETCD="/var/lib/etcd/sauvegarde-en-cours.db"
if sur_vm "kubectl -n kube-system exec etcd-urbanlink -- etcdctl --endpoints=https://127.0.0.1:2379 $CERTS snapshot save $TMP_ETCD" >/dev/null 2>&1; then
  # VERIFICATION A LA SOURCE. Un instantane etcd porte son empreinte en FIN de
  # fichier ; `snapshot status` la recontrole, donc il refuse un instantane
  # tronque -- ce qu'une simple lecture ne ferait pas.
  #
  # ⚠️ `etcdutl`, PAS `etcdctl` : en etcd 3.6 le sous-commande `snapshot status`
  # a quitte etcdctl. L'appeler la-bas n'echoue pas -- il imprime son AIDE, sur
  # la sortie standard, et avec un code de retour nul. Un test « la sortie
  # n'est pas vide » passe donc au vert sur du texte d'aide : c'est ce qui est
  # arrive le 2026-09-11, et la sauvegarde s'est declaree verifiee sans l'etre.
  #
  # ⚠️ Et on valide la FORME de la reponse, pas sa presence. Sur un fichier
  # tronque, `etcdutl` ne rend pas une erreur propre : il PANIQUE, et sa trace
  # Go part elle aussi sur la sortie standard. Seul le motif attendu
  # -- empreinte, revision, nombre de cles, taille -- distingue les trois cas.
  ETAT=$(sur_vm "kubectl -n kube-system exec etcd-urbanlink -- etcdutl snapshot status $TMP_ETCD --write-out=simple" 2>/dev/null | tr -d '\r' | head -1 || true)
  echo "$ETAT" | grep -Eq '^[0-9a-f]+, *[0-9]+, *[0-9]+, *[0-9.]+ *[kKMGT]?B' \
    || echec "instantane etcd invalide a la source. Reponse d'etcdutl : ${ETAT:-<vide>}"

  ATTENDU=$(sur_vm "sudo stat -c%s $TMP_ETCD" | tr -d '\r')
  sur_vm "sudo cat $TMP_ETCD" > "$TRAVAIL/etcd.db" || echec "rapatriement de l'instantane etcd"
  sur_vm "sudo rm -f $TMP_ETCD" >/dev/null 2>&1 || true

  # VERIFICATION DU TRANSFERT. L'instantane est valide a la source ; reste a
  # prouver qu'il est arrive ENTIER. Comparer les tailles suffit et ne coute
  # rien -- un tuyau SSH coupe rend un fichier plus court, jamais plus long.
  RECU=$(stat -c%s "$TRAVAIL/etcd.db")
  [ "$RECU" = "$ATTENDU" ] \
    || echec "instantane etcd tronque au transfert : $RECU octets recus, $ATTENDU attendus"
  journal "  etcd : $(taille "$TRAVAIL/etcd.db"), revision $(echo "$ETAT" | cut -d, -f2 | tr -d ' '), $(echo "$ETAT" | cut -d, -f3 | tr -d ' ') cles"
else
  journal "  (instantane etcd indisponible -- non bloquant, ArgoCD redeploie depuis git)"
fi

# ---------------------------------------------------------------------------
#  4. Manifeste
# ---------------------------------------------------------------------------
# Ce que la sauvegarde contenait AU MOMENT ou elle a ete prise. C'est ce qui
# permet, six mois plus tard, de dire si une restauration a rendu la bonne
# chose -- sans avoir a deviner ce que la plateforme contenait ce jour-la.
compter() {  # base table -> nombre de lignes, ou "?" si la table n'existe pas
  sur_vm "kubectl -n $NS exec $POD_PG -- psql -U urbanconnect -d $1 -tAc 'SELECT count(*) FROM $2'" \
    2>/dev/null | tr -d '\r' | tr -d ' ' || echo '?'
}
{
  echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "pod_postgres=$POD_PG"
  echo "bases=$(echo "$BASES" | tr '\n' ' ')"
  for base in $BASES; do
    echo "taille_${base}=$(stat -c%s "$TRAVAIL/$base.dump")"
  done
  echo "lignes_users=$(compter urbanconnect users)"
  echo "lignes_artefacts=$(compter urbanconnect artefacts)"
  echo "lignes_orders=$(compter urbanconnect orders)"
  echo "lignes_identities=$(compter kratos identities)"
  # Les sagas en cours : versements, litiges, verrous de prix. C'est la
  # ligne qui dit si une restauration a rendu un cluster VIVANT ou une
  # coquille -- les autres tables peuvent etre pleines sans elle.
  echo "lignes_temporal_executions=$(compter temporal executions)"
} > "$TRAVAIL/MANIFESTE.txt"

# ---------------------------------------------------------------------------
#  5. Publication atomique, puis retention
# ---------------------------------------------------------------------------
sync
mv "$TRAVAIL" "$CIBLE"
journal "publiee : $CIBLE ($(du -sh "$CIBLE" | cut -f1))"

# Un `.partiel` abandonne par une execution tuee n'est pas une sauvegarde et ne
# doit jamais etre compte par la retention.
find "$RACINE" -maxdepth 1 -name '*.partiel' -mtime +1 -exec rm -rf {} + 2>/dev/null || true

# Retention : quotidiens recents, puis un par semaine, puis un par mois. On
# construit la liste des A GARDER, et on supprime le reste -- l'inverse
# (construire la liste des a supprimer) laisse passer tout ce qu'on a oublie
# de prevoir.
python3 - "$RACINE" "$GARDER_QUOTIDIENS" "$GARDER_HEBDOS" "$GARDER_MENSUELS" <<'PY'
import os, sys, shutil, datetime
racine, q, h, m = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
noms = sorted((n for n in os.listdir(racine)
               if not n.endswith('.partiel') and os.path.isdir(os.path.join(racine, n))),
              reverse=True)
def quand(n):
    return datetime.datetime.strptime(n.split('_')[0], '%Y-%m-%d').date()
garder, vues_sem, vues_mois = set(noms[:q]), set(), set()
for n in noms:
    d = quand(n)
    sem, mois = d.isocalendar()[:2], (d.year, d.month)
    if len(vues_sem) < h and sem not in vues_sem:
        vues_sem.add(sem); garder.add(n)
    if len(vues_mois) < m and mois not in vues_mois:
        vues_mois.add(mois); garder.add(n)
for n in noms:
    if n not in garder:
        shutil.rmtree(os.path.join(racine, n)); print(f"  retention : {n} supprimee")
print(f"  {len(garder)} sauvegardes conservees sur {len(noms)}")
PY

# Temoin lisible par l'exercice de restauration et par un coup d'oeil humain.
date -u +%Y-%m-%dT%H:%M:%SZ > "$RACINE/DERNIERE_REUSSITE"
journal "terminee"
