#!/usr/bin/env node
/**
 * Génère `dashboards.ndjson` — les objets sauvegardés que `kibana-setup`
 * importe dans Kibana au démarrage (dev et cluster).
 *
 * ⚠️ SOURCE DE VÉRITÉ : ce fichier. `dashboards.ndjson` en est le PRODUIT,
 * versionné parce que le conteneur d'import n'a pas de Node. Ne jamais éditer
 * le `.ndjson` à la main — la prochaine génération l'écraserait sans bruit.
 *
 *   node config/common/kibana/build-dashboards.mjs
 *
 * Les champs interrogés sont ceux de `backTs/src/modules/search/
 * index-definitions.ts`, qui reste la seule description des index. Un champ
 * retiré là-bas rend muet le graphique correspondant ici : Lens n'échoue pas,
 * il affiche un panneau vide. C'est le mode de défaillance à surveiller.
 */

import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const OUT = join(dirname(fileURLToPath(import.meta.url)), 'dashboards.ndjson');

/** Les deux data views. `createdAt` est le champ temporel des deux index. */
const DATA_VIEWS = [
  { id: 'uc-listings', title: 'listings', name: 'UrbanLink — annonces' },
  { id: 'uc-posts', title: 'posts', name: 'UrbanLink — publications' },
];

// ---------------------------------------------------------------- colonnes
// Formes de colonnes Lens (datasource `formBased`). Chaque helper rend
// { id, column } ; l'ordre des colonnes est reconstitué par `lens()`.

const count = (label, filter) => ({
  label,
  customLabel: true,
  dataType: 'number',
  operationType: 'count',
  sourceField: '___records___',
  isBucketed: false,
  scale: 'ratio',
  params: { emptyAsNull: false },
  ...(filter ? { filter: { query: filter, language: 'kuery' } } : {}),
});

// ⚠️ `dataType` doit suivre le champ : un `terms` sur un booléen
// (`sellerIsPro`, `isShippable`) annoncé en `string` rend un panneau que Lens
// signale comme cassé plutôt que de le corriger.
const terms = (label, field, size, orderByColumnId, dataType = 'string') => ({
  label,
  customLabel: true,
  dataType,
  operationType: 'terms',
  sourceField: field,
  isBucketed: true,
  scale: 'ordinal',
  params: {
    size,
    orderBy: orderByColumnId ? { type: 'column', columnId: orderByColumnId } : { type: 'alphabetical', fallback: true },
    orderDirection: 'desc',
    otherBucket: false,
    missingBucket: false,
    parentFormat: { id: 'terms' },
  },
});

const dateHistogram = (label, field = 'createdAt') => ({
  label,
  customLabel: true,
  dataType: 'date',
  operationType: 'date_histogram',
  sourceField: field,
  isBucketed: true,
  scale: 'interval',
  params: { interval: 'auto', includeEmptyRows: true, dropPartials: false },
});

const metricOn = (op, label, field, format) => ({
  label,
  customLabel: true,
  dataType: 'number',
  operationType: op,
  sourceField: field,
  isBucketed: false,
  scale: 'ratio',
  params: { emptyAsNull: false, ...(format ? { format } : {}) },
});

/**
 * Colonne « formule » divisant une agrégation par une constante — l'unique
 * forme de formule dont on ait besoin, pour passer des centimes aux euros.
 *
 * Lens stocke une formule en TROIS colonnes : l'agrégation source (`X0`), un
 * nœud `math` portant l'arbre tinymath (`X1`), et la colonne visible qui les
 * référence. Les deux premières sont masquées par `columnOrder`, pas par un
 * drapeau — les omettre rend un panneau cassé sans message.
 */
const divideByConst = (id, label, op, field, divisor, format, kql) => {
  const inner = kql ? `${op}(${field}, kql='${kql}')` : `${op}(${field})`;
  const formula = `${inner} / ${divisor}`;
  return {
    id,
    order: [`${id}X0`, `${id}X1`, id],
    columns: {
      [`${id}X0`]: {
        label: `Part of ${label}`,
        dataType: 'number',
        operationType: op,
        sourceField: field,
        isBucketed: false,
        scale: 'ratio',
        params: { emptyAsNull: false },
        customLabel: true,
        ...(kql ? { filter: { query: kql, language: 'kuery' } } : {}),
      },
      [`${id}X1`]: {
        label: `Part of ${label}`,
        dataType: 'number',
        operationType: 'math',
        isBucketed: false,
        scale: 'ratio',
        params: {
          tinymathAst: {
            type: 'function',
            name: 'divide',
            args: [`${id}X0`, divisor],
            location: { min: 0, max: formula.length },
            text: formula,
          },
        },
        references: [`${id}X0`],
        customLabel: true,
      },
      [id]: {
        label,
        customLabel: true,
        dataType: 'number',
        operationType: 'formula',
        isBucketed: false,
        scale: 'ratio',
        params: { formula, isFormulaBroken: false, ...(format ? { format } : {}) },
        references: [`${id}X1`],
      },
    },
  };
};

// ------------------------------------------------------------ constructeur

const EUR = { id: 'number', params: { decimals: 0, suffix: ' €' } };

/**
 * Fabrique un objet sauvegardé `lens`. `columns` est un objet id → colonne ;
 * `order` fixe `columnOrder`, que Lens lit pour distinguer les buckets des
 * métriques. `viz` reçoit les ids et rend l'état de la visualisation.
 */
function lens({ id, title, type, dataView, columns, order, viz }) {
  return {
    id,
    type: 'lens',
    attributes: {
      title,
      description: '',
      visualizationType: type,
      state: {
        visualization: viz,
        query: { query: '', language: 'kuery' },
        filters: [],
        datasourceStates: {
          formBased: {
            layers: {
              layer1: { columns, columnOrder: order, incompleteColumns: {}, sampling: 1 },
            },
          },
        },
        internalReferences: [],
        adHocDataViews: {},
      },
    },
    references: [
      { type: 'index-pattern', id: dataView, name: 'indexpattern-datasource-layer-layer1' },
    ],
  };
}

/** Camembert / anneau : un bucket, une métrique. */
const pie = ({ id, title, dataView, bucket, metric, shape = 'donut' }) =>
  lens({
    id, title, type: 'lnsPie', dataView,
    columns: { b: bucket, m: metric },
    order: ['b', 'm'],
    viz: {
      shape,
      layers: [{
        layerId: 'layer1',
        layerType: 'data',
        primaryGroups: ['b'],
        metrics: ['m'],
        numberDisplay: 'percent',
        categoryDisplay: 'default',
        legendDisplay: 'default',
        nestedLegend: false,
      }],
    },
  });

/** Barres / courbe : un bucket en X, une ou plusieurs métriques. */
// Une entrée de `metrics` est soit une colonne simple, soit un groupe rendu
// par `divideByConst` — auquel cas ses trois colonnes entrent dans la couche
// et seule la visible devient un accesseur.
const xy = ({ id, title, dataView, bucket, metrics, seriesType = 'bar_horizontal' }) => {
  const columns = { b: bucket };
  const order = ['b'];
  const ids = [];
  metrics.forEach((m, i) => {
    if (m.columns) {
      Object.assign(columns, m.columns);
      order.push(...m.order);
      ids.push(m.id);
    } else {
      columns[`m${i}`] = m;
      order.push(`m${i}`);
      ids.push(`m${i}`);
    }
  });
  return lens({
    id, title, type: 'lnsXY', dataView,
    columns,
    order,
    viz: {
      legend: { isVisible: metrics.length > 1, position: 'right' },
      valueLabels: 'hide',
      preferredSeriesType: seriesType,
      fittingFunction: 'None',
      axisTitlesVisibilitySettings: { x: false, yLeft: false, yRight: false },
      layers: [{
        layerId: 'layer1',
        layerType: 'data',
        seriesType,
        xAccessor: 'b',
        accessors: ids,
        position: 'top',
        showGridlines: false,
      }],
    },
  });
};

/** Grand chiffre. `extra` ajoute un sous-titre chiffré sous la valeur. */
const metric = ({ id, title, dataView, column, columnId = 'm', order, columns, subtitle }) =>
  lens({
    id, title, type: 'lnsMetric', dataView,
    columns: columns ?? { m: column },
    order: order ?? ['m'],
    viz: {
      layerId: 'layer1',
      layerType: 'data',
      metricAccessor: columnId,
      ...(subtitle ? { subtitle } : {}),
    },
  });

/** Tableau : buckets puis métriques, dans l'ordre donné. */
const table = ({ id, title, dataView, columns, order }) =>
  lens({
    id, title, type: 'lnsDatatable', dataView,
    columns, order,
    viz: {
      layerId: 'layer1',
      layerType: 'data',
      columns: order.map((c) => ({ columnId: c, isTransposed: false })),
    },
  });

// ------------------------------------------------------- les deux tableaux

const L = 'uc-listings';
const P = 'uc-posts';

/**
 * La médiane se restreint aux OFFRES à prix non nul : c'est le prix auquel on
 * peut acheter, la seule médiane qui veuille dire quelque chose sur une place
 * de marché.
 *
 * ⚠️ Ne pas attendre de ce filtre qu'il redresse un chiffre qui semble bas.
 * Mesuré le 2026-08-31 sur les 1464 annonces du seed de dev : médiane à
 * **124 centimes avec** le filtre, 123 sans — les `demand` du seed portent un
 * prix (médiane 122) au lieu d'être à zéro. Un « Prix médian : 1 € » n'est
 * donc pas un défaut de ce tableau de bord mais un reflet fidèle de
 * `priceCents`, où cohabitent des valeurs à 61 et à 24 000.
 */
const OFFRES_PAYANTES = 'type: "offer" and priceCents > 0';
const prixMedian = divideByConst('m', 'Prix médian', 'median', 'priceCents', 100, EUR, OFFRES_PAYANTES);
const prixMedianParCat = divideByConst('pm', 'Prix médian', 'median', 'priceCents', 100, EUR, OFFRES_PAYANTES);

const CATALOGUE = [
  metric({
    id: 'uc-l-total', title: 'Annonces au catalogue', dataView: L,
    column: count('Annonces'), subtitle: 'toutes catégories',
  }),
  metric({
    id: 'uc-l-actives', title: 'Annonces en ligne', dataView: L,
    column: count('En ligne', 'status: "ACTIVE"'), subtitle: 'statut ACTIVE',
  }),
  metric({
    id: 'uc-l-prix-median', title: 'Prix médian', dataView: L,
    columns: prixMedian.columns, order: prixMedian.order, columnId: 'm',
    subtitle: 'offres à prix non nul',
  }),
  metric({
    id: 'uc-l-sans-photo', title: 'Annonces sans photo', dataView: L,
    column: count('Sans photo', 'imagesCount <= 0'),
    subtitle: 'signal de qualité du catalogue',
  }),
  pie({
    id: 'uc-l-maintype', title: 'Objets vs Services', dataView: L,
    bucket: terms('Type principal', 'mainType', 5, 'm'), metric: count('Annonces'),
  }),
  pie({
    id: 'uc-l-type', title: 'Offres vs demandes', dataView: L,
    bucket: terms('Sens', 'type', 5, 'm'), metric: count('Annonces'),
  }),
  pie({
    id: 'uc-l-vendeur', title: 'Vendeurs pro vs particuliers', dataView: L,
    bucket: terms('Vendeur professionnel', 'sellerIsPro', 3, 'm', 'boolean'), metric: count('Annonces'),
  }),
  pie({
    id: 'uc-l-verifie', title: 'Vendeurs vérifiés', dataView: L,
    bucket: terms('Vendeur vérifié', 'sellerVerified', 3, 'm', 'boolean'), metric: count('Annonces'),
  }),
  xy({
    id: 'uc-l-categories', title: 'Top 15 des catégories', dataView: L,
    bucket: terms('Catégorie', 'category', 15, 'm0'), metrics: [count('Annonces')],
  }),
  xy({
    id: 'uc-l-villes', title: 'Top 15 des villes', dataView: L,
    bucket: terms('Ville', 'city', 15, 'm0'), metrics: [count('Annonces')],
  }),
  xy({
    id: 'uc-l-statuts', title: 'Répartition par statut', dataView: L,
    bucket: terms('Statut', 'status', 10, 'm0'), metrics: [count('Annonces')],
  }),
  xy({
    id: 'uc-l-dans-le-temps', title: 'Mises en ligne dans le temps', dataView: L,
    bucket: dateHistogram('Date de création'), metrics: [count('Annonces')],
    seriesType: 'area',
  }),
  xy({
    id: 'uc-l-prix-par-categorie', title: 'Prix médian par catégorie (offres)', dataView: L,
    // ⚠️ Trier par la colonne FORMULE (`pm`) rend « error while executing
    // search » : le tri d'un `terms` se traduit en chemin d'agrégation ES, et
    // une formule n'en a pas — elle est calculée après coup. On trie donc par
    // `pmX0`, l'agrégation `median` qui la nourrit, qui en a bien un.
    bucket: terms('Catégorie', 'category', 15, 'pmX0'),
    metrics: [prixMedianParCat],
  }),
  table({
    id: 'uc-l-top-vues', title: 'Annonces les plus vues', dataView: L,
    columns: {
      b: terms('Annonce', 'title.keyword', 10, 'm0'),
      m0: metricOn('max', 'Vues', 'viewsCount'),
      m1: metricOn('max', 'Favoris', 'likesCount'),
      m2: metricOn('max', 'Prix (centimes)', 'priceCents'),
    },
    order: ['b', 'm0', 'm1', 'm2'],
  }),
  xy({
    id: 'uc-l-livraison', title: 'Annonces livrables', dataView: L,
    bucket: terms('Livrable', 'isShippable', 3, 'm0', 'boolean'),
    metrics: [count('Annonces')],
    seriesType: 'bar',
  }),
];

const SOCIAL = [
  metric({
    id: 'uc-p-total', title: 'Publications', dataView: P,
    column: count('Publications'), subtitle: 'toutes visibilités',
  }),
  metric({
    id: 'uc-p-likes', title: 'Likes en moyenne', dataView: P,
    column: metricOn('average', 'Likes par publication', 'likesCount'),
    subtitle: 'par publication',
  }),
  metric({
    id: 'uc-p-comments', title: 'Commentaires en moyenne', dataView: P,
    column: metricOn('average', 'Commentaires par publication', 'commentsCount'),
    subtitle: 'par publication',
  }),
  metric({
    id: 'uc-p-muettes', title: 'Publications sans réaction', dataView: P,
    column: count('Sans réaction', 'likesCount <= 0 and commentsCount <= 0'),
    subtitle: 'ni like ni commentaire',
  }),
  pie({
    id: 'uc-p-media', title: 'Type de média', dataView: P,
    bucket: terms('Média', 'mediaType', 6, 'm'), metric: count('Publications'),
  }),
  pie({
    id: 'uc-p-visibilite', title: 'Visibilité', dataView: P,
    bucket: terms('Visibilité', 'visibility', 6, 'm'), metric: count('Publications'),
  }),
  xy({
    id: 'uc-p-dans-le-temps', title: 'Publications dans le temps', dataView: P,
    bucket: dateHistogram('Date de publication'), metrics: [count('Publications')],
    seriesType: 'area',
  }),
  xy({
    id: 'uc-p-engagement', title: 'Engagement dans le temps', dataView: P,
    bucket: dateHistogram('Date de publication'),
    metrics: [
      metricOn('sum', 'Likes', 'likesCount'),
      metricOn('sum', 'Commentaires', 'commentsCount'),
    ],
    seriesType: 'bar_stacked',
  }),
  table({
    id: 'uc-p-top-auteurs', title: 'Auteurs les plus suivis', dataView: P,
    columns: {
      b: terms('Auteur', 'authorId', 10, 'm0'),
      m0: metricOn('max', 'Abonnés', 'authorFollowersCount'),
      m1: count('Publications'),
      m2: metricOn('sum', 'Likes reçus', 'likesCount'),
    },
    order: ['b', 'm0', 'm1', 'm2'],
  }),
  xy({
    id: 'uc-p-tags', title: 'Tags les plus utilisés', dataView: P,
    bucket: terms('Tag', 'tags.keyword', 15, 'm0'), metrics: [count('Publications')],
  }),
];

// ------------------------------------------------------------- dashboards
// La grille Kibana fait 48 colonnes de large. `h` est en unités de 20 px.

/**
 * ⚠️ `timeRestore` est indispensable. Sans lui le tableau s'ouvre sur la
 * fenêtre par défaut de Kibana (15 dernières minutes) et TOUT est vide —
 * les annonces du seed portent des dates étalées sur l'année écoulée. Un
 * tableau vide se lit comme une panne, alors que la donnée est là.
 */
function dashboard({ id, title, description, panels }) {
  const refs = [];
  const panelsJSON = panels.map((p, i) => {
    const n = i + 1;
    refs.push({ name: `panel_${n}`, type: 'lens', id: p.id });
    return {
      version: '8.15.3',
      type: 'lens',
      gridData: { ...p.grid, i: String(n) },
      panelIndex: String(n),
      embeddableConfig: { enhancements: {} },
      panelRefName: `panel_${n}`,
      title: p.title,
    };
  });

  return {
    id,
    type: 'dashboard',
    attributes: {
      title,
      description,
      panelsJSON: JSON.stringify(panelsJSON),
      optionsJSON: JSON.stringify({
        useMargins: true,
        syncColors: false,
        syncCursor: true,
        syncTooltips: false,
        hidePanelTitles: false,
      }),
      timeRestore: true,
      timeFrom: 'now-1y',
      timeTo: 'now',
      refreshInterval: { pause: true, value: 60000 },
      kibanaSavedObjectMeta: {
        searchSourceJSON: JSON.stringify({ query: { query: '', language: 'kuery' }, filter: [] }),
      },
      version: 1,
    },
    references: refs,
  };
}

/** Dispose une liste de panneaux : 4 métriques en tête, puis 2 par ligne. */
function layout(objs, metricCount) {
  let y = 0;
  return objs.map((o, i) => {
    if (i < metricCount) {
      return { id: o.id, title: o.attributes.title, grid: { x: (i % 4) * 12, y: 0, w: 12, h: 7 } };
    }
    const k = i - metricCount;
    if (k % 2 === 0) y = 7 + Math.floor(k / 2) * 14;
    return { id: o.id, title: o.attributes.title, grid: { x: (k % 2) * 24, y, w: 24, h: 14 } };
  });
}

const DASHBOARDS = [
  dashboard({
    id: 'uc-dashboard-catalogue',
    title: 'UrbanLink — Catalogue',
    description:
      "Ce que contient l'index `listings` : volume, prix, catégories, géographie, "
      + 'qualité des annonces et profil des vendeurs.',
    panels: layout(CATALOGUE, 4),
  }),
  dashboard({
    id: 'uc-dashboard-social',
    title: 'UrbanLink — Fil social',
    description:
      "Ce que contient l'index `posts` : volume de publication, engagement reçu, "
      + 'formats et auteurs.',
    panels: layout(SOCIAL, 4),
  }),
];

// ------------------------------------------------------------------ sortie

const objects = [
  ...DATA_VIEWS.map((d) => ({
    id: d.id,
    type: 'index-pattern',
    attributes: { title: d.title, name: d.name, timeFieldName: 'createdAt' },
    references: [],
  })),
  ...CATALOGUE,
  ...SOCIAL,
  ...DASHBOARDS,
];

/**
 * ⚠️ Ces versions ne sont PAS décoratives, et les omettre ne « laisse pas
 * Kibana faire » : un objet sans `typeMigrationVersion` est réputé antérieur
 * à la 7.0, et Kibana lui applique **toute** la chaîne de migrations. Les
 * premières attendent l'ancien format Lens (datasource `indexpattern`, non
 * `formBased`) et l'import meurt en 500 sur
 * `Cannot read properties of undefined (reading 'currentIndexPatternId')` —
 * un message qui n'accuse rien de ce qu'on a écrit. Mesuré le 2026-08-31.
 *
 * Déclarer la version à laquelle l'objet est écrit est le contrat normal :
 * Kibana saute les migrations passées, et un Kibana futur reprendra à partir
 * d'ici. Valeurs relevées sur le Kibana 8.15.3 lui-même, par `_bulk_create`
 * (qui écrit au format courant) puis lecture de la réponse. **À relever de
 * nouveau lors d'une montée de version de Kibana.**
 */
const MIGRATION_VERSION = { 'index-pattern': '8.0.0', lens: '8.9.0', dashboard: '10.2.0' };

// Un objet par ligne, sans ligne de résumé : `_export` en produit une,
// `_import` n'en réclame aucune.
const ndjson = objects
  .map((o) => JSON.stringify({
    ...o,
    coreMigrationVersion: '8.8.0',
    typeMigrationVersion: MIGRATION_VERSION[o.type],
  }))
  .join('\n');

writeFileSync(OUT, `${ndjson}\n`, 'utf8');
console.log(`dashboards.ndjson écrit — ${objects.length} objets (${DATA_VIEWS.length} data views, ${CATALOGUE.length + SOCIAL.length} graphiques, ${DASHBOARDS.length} tableaux de bord)`);
