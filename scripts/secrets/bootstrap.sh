#!/usr/bin/env bash
# ============================================================================
#  Genere les secrets du stack UrbanLink dans kube/urbanlink/secrets.env
# ----------------------------------------------------------------------------
#   ./scripts/secrets/bootstrap.sh            genere ce qui manque
#   ./scripts/secrets/bootstrap.sh --rotate   regenere TOUTES les valeurs [auto]
#
#  Ne touche jamais aux valeurs [externe] ni [identite] deja renseignees : le
#  script complete, il n'ecrase pas. C'est ce qui le rend rejouable sans
#  perdre les cles Stripe ou Google saisies a la main.
#
#  Le fichier produit n'est PAS versionne. La source de verite est GitHub
#  Secrets -- pousser ensuite avec scripts/secrets/github-sync.sh.
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")/../.."
ENV_FILE="kube/urbanlink/secrets.env"
EXAMPLE="kube/urbanlink/secrets.env.example"
ROTATE="${1:-}"

[ -f "$EXAMPLE" ] || { echo "modele introuvable : $EXAMPLE" >&2; exit 1; }

if [ ! -f "$ENV_FILE" ]; then
    echo "Creation de $ENV_FILE depuis le modele."
    # On retire les commentaires de categorie en fin de ligne : ils
    # deviendraient une partie de la valeur avec --from-env-file.
    sed -E 's/[[:space:]]+#[[:space:]]*\[(auto|identite|externe)\].*$//' "$EXAMPLE" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
fi

# Un secret sans caractere special : ces valeurs finissent dans des URLs de
# connexion (DATABASE_URL, REDIS_URL) ou un `@` ou un `/` casserait l'analyse.
rand() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${1:-40}"; }

get() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true; }

set_kv() {
    local key="$1" val="$2"
    if grep -qE "^$key=" "$ENV_FILE"; then
        # Delimiteur | : les valeurs peuvent contenir des /
        sed -i "s|^$key=.*|$key=$val|" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
    fi
}

# Ne remplit que si vide, sauf --rotate.
fill() {
    local key="$1" val="$2"
    if [ "$ROTATE" = "--rotate" ] || [ -z "$(get "$key")" ]; then
        set_kv "$key" "$val"
        echo "  $key"
    fi
}

echo "Generation des valeurs [auto] dans $ENV_FILE"

# KRATOS_SECRET : Kratos exige >= 32 caracteres. 40 par securite -- l'ancien
# placeholder en faisait 31 et bloquait tout le demarrage.
fill KRATOS_SECRET          "$(rand 40)"
fill KRATOS_WEBHOOK_SECRET  "$(rand 40)"
fill POSTGRES_PASSWORD      "$(rand 32)"
fill KRATOS_DB_PASSWORD     "$(rand 32)"
fill DIRECTUS_DB_PASSWORD   "$(rand 32)"
fill DIRECTUS_ADMIN_PASSWORD "$(rand 24)"
fill DIRECTUS_SECRET        "$(rand 40)"
fill NOMINATIM_DB_PASSWORD  "$(rand 32)"
fill TEMPORAL_DB_PASSWORD   "$(rand 32)"
fill PGADMIN_PASSWORD       "$(rand 24)"
fill REDIS_PASSWORD         "$(rand 32)"
fill ELASTICSEARCH_PASSWORD "$(rand 32)"
fill KIBANA_SYSTEM_PASSWORD "$(rand 32)"
fill MINIO_ROOT_PASSWORD    "$(rand 32)"
fill JWT_SECRET             "$(rand 48)"
fill METRICS_TOKEN          "$(rand 32)"
fill TURN_SECRET            "$(rand 32)"

# --- Valeurs derivees -------------------------------------------------------
# Toujours recalculees : elles doivent suivre les mots de passe ci-dessus,
# sinon une rotation laisserait des URLs pointant sur l'ancien secret.
PG_USER="$(get POSTGRES_USER)"; PG_PASS="$(get POSTGRES_PASSWORD)"; PG_DB="$(get POSTGRES_DB)"
K_USER="$(get KRATOS_DB_USER)"; K_PASS="$(get KRATOS_DB_PASSWORD)"; K_DB="$(get KRATOS_DB_NAME)"
R_PASS="$(get REDIS_PASSWORD)"

set_kv DATABASE_URL "postgresql://${PG_USER}:${PG_PASS}@pgbouncer:6432/${PG_DB}"
set_kv KRATOS_DSN   "postgres://${K_USER}:${K_PASS}@postgres:5432/${K_DB}?sslmode=disable"
set_kv REDIS_URL    "redis://:${R_PASS}@redis:6379"
echo "  DATABASE_URL, KRATOS_DSN, REDIS_URL (recalculees)"

chmod 600 "$ENV_FILE"

# --- Ce qui reste a la charge de l'humain -----------------------------------
MISSING=$(grep -E '^[A-Z_]+=$' "$ENV_FILE" | cut -d= -f1 || true)
echo
if [ -n "$MISSING" ]; then
    echo "A RENSEIGNER a la main (aucun script ne peut les inventer) :"
    echo "$MISSING" | sed 's/^/  /'
    echo
    echo "Le stack demarre sans elles : les manifests les declarent optional."
    echo "Seule la fonction associee reste inactive."
else
    echo "Toutes les cles sont renseignees."
fi
echo
echo "Ensuite :  ./scripts/secrets/github-sync.sh"
