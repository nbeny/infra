#!/usr/bin/env node
/**
 * Génère `config/dev/kratos/.google-oidc.env` (gitignoré) à partir de GOOGLE_CLIENT_ID /
 * GOOGLE_CLIENT_SECRET de la `.env` racine, qui reste la source de vérité.
 *
 * Pourquoi : Kratos ne mappe NI `GOOGLE_CLIENT_ID` NI `GOOGLE_CLIENT_SECRET` sur
 * un champ imbriqué de provider oidc — le YAML garde son placeholder
 * (`GOCSPX-REPLACE_VIA_ENV`) et Google répond `invalid_client`. Le seul override
 * qui marche est le bloc `providers` ENTIER, en JSON **BRUT** (surtout pas
 * base64 — voir le commentaire de `encoded` plus bas), via
 * SELFSERVICE_METHODS_OIDC_CONFIG_PROVIDERS.
 *
 * Usage :  node config/common/kratos/scripts/gen-google-oidc-env.mjs
 *          node config/common/kratos/scripts/gen-google-oidc-env.mjs --print
 *
 * Puis :   docker compose up -d --force-recreate kratos
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const ENV_KEY = 'SELFSERVICE_METHODS_OIDC_CONFIG_PROVIDERS';
const PLACEHOLDER = 'GOCSPX-REPLACE_VIA_ENV';
const REDIRECT_URI =
  'http://localhost:10008/self-service/methods/oidc/callback/google';

// Le script vit dans config/common/kratos/scripts/ : quatre niveaux le
// séparent de la racine du dépôt. ⚠️ Le compte a changé avec le déplacement
// sous config/ — s'il était resté à deux, `root` aurait désigné `config/` et
// la lecture de la `.env` aurait échoué sur un fichier absent.
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..', '..', '..');
const envPath = resolve(root, '.env');
// La sortie va dans config/dev/ et non config/common/ : c'est un fichier de
// développement. En production, le bloc `providers` est injecté par le Secret
// du cluster, pas par un fichier posé à côté de la configuration.
const outPath = resolve(root, 'config', 'dev', 'kratos', '.google-oidc.env');
const printOnly = process.argv.includes('--print');

const raw = readFileSync(envPath, 'utf8');
const readVar = (key) => {
  const line = raw
    .split(/\r?\n/)
    .find((l) => l.startsWith(`${key}=`) && !l.trimStart().startsWith('#'));
  return line ? line.slice(key.length + 1).trim() : '';
};

const clientId = readVar('GOOGLE_CLIENT_ID');
const clientSecret = readVar('GOOGLE_CLIENT_SECRET');

if (!clientId || !clientSecret) {
  console.error('✖ GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET absents de la .env racine.');
  process.exit(1);
}
if (clientSecret === PLACEHOLDER) {
  console.error(`✖ GOOGLE_CLIENT_SECRET vaut encore le placeholder ${PLACEHOLDER}.`);
  process.exit(1);
}

// Doit rester identique au bloc `providers` de config/dev/kratos/kratos.yml,
// client_secret excepté — cette variable REMPLACE le bloc entier.
const providers = [
  {
    id: 'google',
    provider: 'google',
    client_id: clientId,
    client_secret: clientSecret,
    mapper_url: 'file:///etc/config/kratos/oidc.google.jsonnet',
    scope: ['email', 'profile'],
    requested_claims: {
      id_token: {
        email: { essential: true },
        email_verified: { essential: true },
        given_name: { essential: true },
      },
    },
  },
];

// ⚠️ JSON BRUT sur une ligne — surtout PAS de base64. Vérifié sur Kratos v26.2.0 :
// une valeur base64 (avec ou sans préfixe `base64://`) n'est pas décodée, `providers`
// tombe à null et Kratos refuse de démarrer.
const encoded = JSON.stringify(providers);

if (printOnly) {
  process.stdout.write(`${encoded}\n`);
} else {
  writeFileSync(
    outPath,
    [
      '# GÉNÉRÉ par config/common/kratos/scripts/gen-google-oidc-env.mjs — ne pas éditer à la main.',
      '# Source de vérité : GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET de la .env racine.',
      '# Régénérer après toute rotation du secret Google, puis recréer le conteneur.',
      `${ENV_KEY}=${encoded}`,
      '',
    ].join('\n'),
    'utf8',
  );
  console.log(`✔ config/dev/kratos/.google-oidc.env écrit (JSON brut, ${encoded.length} caractères).`);
  console.log('  → docker compose up -d --force-recreate kratos');
}

// Vérification en direct : Google distingue un secret invalide d'un code invalide.
try {
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      grant_type: 'authorization_code',
      code: 'probe-invalid-code',
      redirect_uri: REDIRECT_URI,
    }),
  });
  const body = await res.json();
  if (body.error === 'invalid_grant') {
    console.log('✔ Google accepte le couple client_id/client_secret.');
  } else if (body.error === 'invalid_client') {
    console.error(`✖ Google refuse le secret : ${body.error_description}`);
    console.error('  → régénérer le secret dans https://console.cloud.google.com/apis/credentials');
    process.exitCode = 2;
  } else {
    console.warn(`? Réponse Google inattendue : ${JSON.stringify(body)}`);
  }
} catch (err) {
  console.warn(`? Vérification Google impossible (hors ligne ?) : ${err.message}`);
}
