#!/bin/bash
# =============================================================================
#  Rôle PostgreSQL APPLICATIF — celui avec lequel le backend et le worker
#  Temporal parlent à la base. Idempotent, rejouable à volonté.
# -----------------------------------------------------------------------------
#  ## Pourquoi ce fichier existe
#
#  L'application se connectait avec `POSTGRES_USER`, qui est le SUPERUTILISATEUR
#  de l'instance : propriétaire des tables, capable de les détruire, de modifier
#  le schéma, de créer des rôles et de lire la base `kratos` — donc les
#  identifiants de tous les membres. Une injection SQL ou une simple fuite de
#  variable d'environnement ne coûtait pas quelques lignes, elle coûtait
#  l'instance entière.
#
#  Le rôle créé ici n'a que ce dont Prisma se sert À L'EXÉCUTION. Il ne peut
#  créer ni détruire une table, ni approcher le schéma `kratos`.
#
#  ## Pourquoi il est appelé DEUX fois
#
#    1. par `create-databases.sh`, dans `docker-entrypoint-initdb.d`, au tout
#       premier démarrage d'un volume vierge ;
#    2. par le service one-shot `postgres-app-role` du compose, à CHAQUE
#       démarrage de la pile.
#
#  Le second n'est pas une ceinture de plus. `docker-entrypoint-initdb.d` ne
#  s'exécute QUE sur un volume vierge : sans lui, aucun poste déjà installé ne
#  verrait jamais ce rôle, et le correctif ne s'appliquerait qu'aux machines
#  neuves. Il rattrape aussi les tables créées entre-temps : `GRANT … ON ALL
#  TABLES` ne vaut que pour les tables existant à l'instant du GRANT, et à
#  l'init il n'y en a aucune — Prisma les crée plus tard.
#
#  ## Ce que ce rôle NE PEUT PAS faire, et qui en dépend
#
#  Pas de DDL ⇒ `prisma migrate dev|deploy`, `prisma db push` et la
#  réinitialisation de base continuent d'exiger le rôle PROPRIÉTAIRE. Ils se
#  lancent depuis l'hôte (`backTs/.env`, port 10001 via pgbouncer), chemin
#  inchangé et documenté dans CLAUDE.md.
#
#  `TRUNCATE` fait exception et EST accordé : le seed de développement passe par
#  `prisma/clean-db.ts`, qui vide les tables avec `TRUNCATE … CASCADE`. C'est un
#  droit de TABLE, du même ordre que `DELETE` (que le rôle a déjà, et qui permet
#  exactement la même destruction) — pas un droit d'administration.
# =============================================================================
set -euo pipefail

SUPER_USER="${POSTGRES_USER:-urbanconnect}"
APP_DB="${POSTGRES_DB:-urbanconnect}"
APP_USER="${POSTGRES_APP_USER:-urbanconnect_app}"
APP_PASSWORD="${POSTGRES_APP_PASSWORD:-}"

if [ -z "$APP_PASSWORD" ]; then
  echo "ensure-app-role.sh: POSTGRES_APP_PASSWORD absent — rôle applicatif NON créé." >&2
  echo "  Le backend ne pourra pas s'authentifier. Définir la variable dans la .env racine." >&2
  exit 1
fi

# `psql` lit PGHOST/PGPORT/PGPASSWORD dans l'environnement quand ils sont posés
# (cas du service one-shot, qui attaque `postgres:5432` par le réseau Docker) et
# retombe sur la socket locale quand ils ne le sont pas (cas de
# `docker-entrypoint-initdb.d`, où le serveur n'écoute pas encore en TCP).
psql_super() { psql -v ON_ERROR_STOP=1 --username "$SUPER_USER" --dbname "$APP_DB" "$@"; }

# Le mot de passe est passé en PARAMÈTRE de requête et non concaténé dans le
# SQL : un mot de passe contenant une apostrophe casserait la chaîne, et un mot
# de passe hostile l'exploiterait. `format('%L')` cite pour nous.
psql_super <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${APP_USER}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${APP_USER}', \$pw\$${APP_PASSWORD}\$pw\$);
    RAISE NOTICE 'Rôle applicatif %I créé', '${APP_USER}';
  ELSE
    -- Réaligne le mot de passe : la .env fait autorité, pas ce qui traîne en base.
    EXECUTE format('ALTER ROLE %I LOGIN PASSWORD %L', '${APP_USER}', \$pw\$${APP_PASSWORD}\$pw\$);
  END IF;

  -- Ceintures explicites : ce rôle ne doit JAMAIS pouvoir administrer.
  EXECUTE format('ALTER ROLE %I NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', '${APP_USER}');
END
\$\$;

-- Droit d'ouvrir une connexion sur la base applicative, et sur elle seule.
GRANT CONNECT ON DATABASE "${APP_DB}" TO "${APP_USER}";

-- Schéma `public` : traverser, oui. Y créer des objets, non (pas de CREATE).
GRANT USAGE ON SCHEMA public TO "${APP_USER}";

-- Tables et séquences EXISTANTES.
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA public TO "${APP_USER}";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "${APP_USER}";

-- Tables et séquences FUTURES. Sans ces deux lignes, chaque migration Prisma
-- créerait des tables invisibles au rôle applicatif : le backend tomberait sur
-- « permission denied for table … » à la première lecture, longtemps après la
-- migration, et l'erreur accuserait le code plutôt que les droits.
--
-- ⚠️ `FOR ROLE` est indispensable : ALTER DEFAULT PRIVILEGES ne vaut QUE pour
-- les objets créés par le rôle nommé. Les migrations tournent sous le
-- propriétaire — c'est donc lui qu'il faut désigner, pas l'exécutant du script.
ALTER DEFAULT PRIVILEGES FOR ROLE "${SUPER_USER}" IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON TABLES TO "${APP_USER}";
ALTER DEFAULT PRIVILEGES FOR ROLE "${SUPER_USER}" IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO "${APP_USER}";
SQL

# Schéma `kratos` : AUCUN droit, et on le dit explicitement plutôt que de
# compter sur l'absence de GRANT. `init-db.sql` ouvre ce schéma en grand au
# propriétaire ; rien ne doit ruisseler vers le rôle applicatif — l'identité des
# membres n'est pas une donnée métier de la marketplace.
#
# Le REVOKE est conditionné à l'existence du schéma : au tout premier init il
# n'existe pas encore (`init-db.sql` s'exécute APRÈS `create-databases.sh` dans
# l'ordre alphabétique), et un REVOKE sur un schéma absent ferait échouer
# l'initialisation entière.
psql_super <<SQL
DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'kratos') THEN
    EXECUTE format('REVOKE ALL ON SCHEMA kratos FROM %I', '${APP_USER}');
    EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA kratos FROM %I', '${APP_USER}');
    EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA kratos FROM %I', '${APP_USER}');
  END IF;
END
\$\$;
SQL

echo "ensure-app-role.sh: rôle applicatif « ${APP_USER} » assuré sur « ${APP_DB} » (sans droits d'administration, sans accès au schéma kratos)."
