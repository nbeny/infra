#!/bin/bash
# Crée, dans l'instance Postgres unique, les rôles + bases additionnels selon les
# variables d'env DÉFINIES. Idempotent. Exécuté par docker-entrypoint-initdb.d au
# 1er init (superuser = $POSTGRES_USER sur $POSTGRES_DB). Nominatim est EXCLU (PG dédié).
set -euo pipefail

psql_super() { psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" "$@"; }

ensure_role() { # $1 user, $2 password, $3 extra (ex: CREATEDB)
  local u="$1" p="$2" extra="${3:-}"
  if [ -z "$u" ] || [ -z "$p" ]; then return 0; fi
  if [ "$(psql_super -tAc "SELECT 1 FROM pg_roles WHERE rolname='${u}'")" != "1" ]; then
    psql_super -c "CREATE ROLE \"${u}\" LOGIN PASSWORD '${p}' ${extra};"
  else
    psql_super -c "ALTER ROLE \"${u}\" LOGIN PASSWORD '${p}' ${extra};"
  fi
}

ensure_db() { # $1 dbname, $2 owner
  local d="$1" o="$2"
  if [ -z "$d" ] || [ -z "$o" ]; then return 0; fi
  if [ "$(psql_super -tAc "SELECT 1 FROM pg_database WHERE datname='${d}'")" != "1" ]; then
    psql_super -c "CREATE DATABASE \"${d}\" OWNER \"${o}\";"
  fi
}

# --- Kratos (base dédiée) ---
ensure_role "${KRATOS_DB_USER:-}" "${KRATOS_DB_PASSWORD:-}"
ensure_db   "${KRATOS_DB_NAME:-}" "${KRATOS_DB_USER:-}"

# --- Directus (base dédiée, prod/kube) ---
ensure_role "${DIRECTUS_DB_USER:-}" "${DIRECTUS_DB_PASSWORD:-}"
ensure_db   "${DIRECTUS_DB_NAME:-}" "${DIRECTUS_DB_USER:-}"

# --- Temporal : rôle CREATEDB + base `temporal` pré-créée. auto-setup ATTEND que
#     `temporal` existe (dans l'ancien setup, POSTGRES_DB=temporal la créait) ; il ne
#     crée lui-même que `temporal_visibility`. ---
ensure_role "${TEMPORAL_DB_USER:-}" "${TEMPORAL_DB_PASSWORD:-}" "CREATEDB"
if [ -n "${TEMPORAL_DB_USER:-}" ]; then
  ensure_db "temporal" "${TEMPORAL_DB_USER}"
fi

echo "create-databases.sh: rôles/bases additionnels assurés (nominatim exclu)."

# --- Rôle APPLICATIF (sans droits d'administration) ---
#
# Délégué à un fichier séparé, et ce n'est pas un découpage esthétique : le même
# fichier est rejoué à CHAQUE démarrage par le service one-shot
# `postgres-app-role` du compose. `docker-entrypoint-initdb.d` ne s'exécute que
# sur un volume vierge — sans ce second appel, aucun poste déjà installé ne
# verrait jamais le rôle, et le durcissement ne vaudrait que pour les machines
# neuves. Une seule source de vérité, deux appelants.
#
# Le chemin de montage est HORS de `docker-entrypoint-initdb.d/` : posé dedans,
# l'entrypoint l'exécuterait une deuxième fois juste après celui-ci.
if [ -f /urbanconnect/ensure-app-role.sh ]; then
  bash /urbanconnect/ensure-app-role.sh
else
  echo "create-databases.sh: /urbanconnect/ensure-app-role.sh absent — rôle applicatif non créé ici." >&2
  echo "  (Le service one-shot 'postgres-app-role' le posera au démarrage de la pile.)" >&2
fi
