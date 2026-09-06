/* ==========================================================================
 *  urbanlink -- amorce du theme SOGo inspire de Proton Mail
 * --------------------------------------------------------------------------
 *  Deploye par le role Ansible `mailcow` vers
 *  /opt/mailcow-dockerized/data/conf/sogo/custom-theme.js, que le
 *  docker-compose de Mailcow monte deja sur
 *  .../WebServerResources/js/theme.js et que sogo.conf charge via
 *  `SOGoUIAdditionalJSFiles`. Aucun fichier de Mailcow n'est modifie.
 *
 *  Ce fichier fait cinq choses, et rien d'autre :
 *    1. il pose le mode clair/sombre sur <html> AVANT tout rendu ;
 *    2. il rend le zoom au pincement possible, que SOGo interdit ;
 *    3. il injecte la feuille de style du theme ;
 *    4. il donne a Angular Material la palette violette, pour que ce qui est
 *       genere a l'execution (encre, cases a cocher, barres de progression)
 *       soit deja de la bonne couleur au lieu d'etre repeint apres coup ;
 *    5. il ajoute les trois elements que le CSS seul ne peut pas creer :
 *       le bandeau de marque, le bouton « Nouveau message » et la bascule
 *       clair/sombre.
 *
 *  Ce qu'il ne fait PAS : reimplementer la moindre logique de SOGo. Le bouton
 *  de composition delegue au bouton flottant natif ; si SOGo change, le pire
 *  qui arrive est que le bouton disparaisse -- pas que la composition casse.
 * ========================================================================== */

(function () {
  'use strict';

  var CSS_HREF = '/SOGo/WebServerResources/css/custom-theme.css';
  var STORAGE_KEY = 'pm-theme';

  /* ------------------------------------------------------------------ *
   *  1. Mode clair / sombre
   * ------------------------------------------------------------------ */

  function preferredTheme() {
    var stored;
    try {
      stored = window.localStorage.getItem(STORAGE_KEY);
    } catch (e) {
      // Navigation privee ou stockage bloque : on retombe sur le systeme.
      stored = null;
    }
    if (stored === 'dark' || stored === 'light') {
      return stored;
    }
    return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches
      ? 'dark'
      : 'light';
  }

  function applyTheme(theme) {
    document.documentElement.setAttribute('data-pm-theme', theme);
    try {
      window.localStorage.setItem(STORAGE_KEY, theme);
    } catch (e) {
      /* sans persistance, le choix vaut pour la session : acceptable */
    }
  }

  // Pose immediate, avant le premier rendu : sans cela l'interface clignote en
  // clair pendant une frame chez les utilisateurs en mode sombre.
  document.documentElement.setAttribute('data-pm-theme', preferredTheme());

  /* ------------------------------------------------------------------ *
   *  2. Zoom au pincement
   * ------------------------------------------------------------------ *
   *  SOGo declare `maximum-scale=1` dans sa balise viewport, ce qui interdit
   *  d'agrandir la page au pincement sur Android. C'est un manquement
   *  d'accessibilite caracterise (WCAG 1.4.4) et, sur un telephone, la seule
   *  facon de lire une signature de courriel composee en corps 9.
   *
   *  On ne retire QUE cette clause. Le service qu'elle rendait sur iOS --
   *  empecher le zoom automatique a la mise au point d'un champ de moins de
   *  16 px, zoom dont Safari ne revient jamais tout seul -- est repris par la
   *  feuille de style, qui passe tous les champs a 16 px sous 600 px de large
   *  (section 18.3). Sans cette contrepartie, retirer `maximum-scale`
   *  rendrait la saisie pire qu'avant.
   *
   *  La balise est deja dans le DOM : SOGo charge ce script en fin de <body>,
   *  donc le <head> est entierement analyse.                              */

  function relaxZoom() {
    var meta = document.querySelector('meta[name="viewport"]');
    if (!meta) return;

    var content = meta.getAttribute('content') || '';
    if (content.indexOf('maximum-scale') === -1 &&
        content.indexOf('user-scalable') === -1) {
      return;
    }

    meta.setAttribute('content', content
      .split(',')
      .map(function (part) { return part.trim(); })
      .filter(function (part) {
        return part.indexOf('maximum-scale') !== 0 &&
               part.indexOf('user-scalable') !== 0;
      })
      .join(', '));
  }

  relaxZoom();

  /* ------------------------------------------------------------------ *
   *  3. Feuille de style
   * ------------------------------------------------------------------ *
   *  Insertion SYNCHRONE : la balise est ajoutee pendant l'analyse du
   *  document, donc le navigateur la traite comme bloquante au rendu et il
   *  n'y a pas de flash de SOGo non stylise.
   *
   *  Puis REPOSITIONNEMENT en fin de <head> une fois Angular amorce : Angular
   *  Material genere son theme a l'execution et l'injecte dans un <style>.
   *  A specificite egale, le dernier arrive gagne -- il faut donc repasser
   *  derriere lui. Deplacer un <link> deja charge ne provoque aucune requete
   *  supplementaire.                                                       */

  var link = document.createElement('link');
  link.rel = 'stylesheet';
  link.type = 'text/css';
  link.href = CSS_HREF;
  link.id = 'pm-theme-stylesheet';
  document.head.appendChild(link);

  /* ------------------------------------------------------------------ *
   *  4. Palette Angular Material
   * ------------------------------------------------------------------ */

  // Une palette Angular Material doit definir toutes ses teintes, sans quoi
  // definePalette leve une exception et l'application entiere ne demarre pas.
  var VIOLET = {
    '50': 'f4f0ff', '100': 'e5dcff', '200': 'd2c2ff', '300': 'b9a1ff',
    '400': 'a186ff', '500': '6d4aff', '600': '5c39f0', '700': '4d2cd6',
    '800': '3f22b3', '900': '2e1880',
    'A100': 'e5dcff', 'A200': 'b9a1ff', 'A400': '6d4aff', 'A700': '4d2cd6',
    'contrastDefaultColor': 'light',
    'contrastDarkColors': ['50', '100', '200', '300', 'A100', 'A200']
  };

  var MAGENTA = {
    '50': 'fbeaf7', '100': 'f6cdec', '200': 'eda8dd', '300': 'e37fcd',
    '400': 'd854bb', '500': 'c026a8', '600': 'a81f92', '700': '8c1a79',
    '800': '701561', '900': '520f47',
    'A100': 'f6cdec', 'A200': 'e37fcd', 'A400': 'c026a8', 'A700': '8c1a79',
    'contrastDefaultColor': 'light',
    'contrastDarkColors': ['50', '100', '200', 'A100']
  };

  var ROUGE = {
    '50': 'fdeaea', '100': 'fac8c9', '200': 'f5a1a3', '300': 'ee7679',
    '400': 'e5555a', '500': 'd8383d', '600': 'be2f34', '700': '9e262a',
    '800': '7e1e21', '900': '5c1517',
    'A100': 'fac8c9', 'A200': 'ee7679', 'A400': 'd8383d', 'A700': '9e262a',
    'contrastDefaultColor': 'light',
    'contrastDarkColors': ['50', '100', '200', 'A100']
  };

  if (typeof angular !== 'undefined' && angular.module) {
    try {
      angular.module('SOGo.Common').config([
        '$mdThemingProvider',
        function ($mdThemingProvider) {
          $mdThemingProvider.definePalette('pmViolet', VIOLET);
          $mdThemingProvider.definePalette('pmMagenta', MAGENTA);
          $mdThemingProvider.definePalette('pmRouge', ROUGE);

          // La palette de FOND reste celle d'origine, deliberement : c'est
          // elle que la directive md-colors ecrit en styles EN LIGNE, une
          // seule fois au demarrage. La figer permet a la bascule
          // clair/sombre d'agir sans recharger la page -- le CSS reprend la
          // main sur ces quelques points avec !important.
          $mdThemingProvider.theme('default')
            .primaryPalette('pmViolet', {
              'default': '500', 'hue-1': '200', 'hue-2': '700', 'hue-3': 'A700'
            })
            .accentPalette('pmMagenta', {
              'default': '500', 'hue-1': '200', 'hue-2': '700', 'hue-3': 'A700'
            })
            .warnPalette('pmRouge');
        }
      ]);
    } catch (e) {
      // Un module absent (page de connexion, fenetre de composition isolee)
      // ne doit pas empecher la feuille de style de s'appliquer.
      if (window.console && console.warn) {
        console.warn('[pm-theme] palette non appliquee :', e.message);
      }
    }
  }

  /* ------------------------------------------------------------------ *
   *  5. Elements que le CSS ne peut pas creer
   * ------------------------------------------------------------------ */

  var ICONS = {
    edit: 'edit'   // ligature presente depuis la premiere version de la police
  };

  function mdIcon(name) {
    var i = document.createElement('md-icon');
    i.className = 'material-icons';
    i.setAttribute('role', 'img');
    i.setAttribute('aria-hidden', 'true');
    i.textContent = name;
    return i;
  }

  /* Les icones de la bascule sont dessinees en SVG plutot que demandees a la
   * police Material Icons : celle qu'embarque SOGo 5.12 est anterieure aux
   * ligatures `dark_mode` et `light_mode`. Une ligature inconnue ne produit
   * aucun glyphe -- le bouton existait, etait cliquable, et n'affichait
   * rigoureusement rien. */
  var SVG_NS = 'http://www.w3.org/2000/svg';

  function svgIcon(theme) {
    var svg = document.createElementNS(SVG_NS, 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.setAttribute('aria-hidden', 'true');

    if (theme === 'dark') {
      // Soleil : proposer de repasser en clair.
      var c = document.createElementNS(SVG_NS, 'circle');
      c.setAttribute('cx', '12'); c.setAttribute('cy', '12'); c.setAttribute('r', '4.2');
      svg.appendChild(c);
      var rays = [
        [12, 1.5, 12, 3.6], [12, 20.4, 12, 22.5],
        [1.5, 12, 3.6, 12], [20.4, 12, 22.5, 12],
        [4.6, 4.6, 6.1, 6.1], [17.9, 17.9, 19.4, 19.4],
        [19.4, 4.6, 17.9, 6.1], [6.1, 17.9, 4.6, 19.4]
      ];
      rays.forEach(function (r) {
        var l = document.createElementNS(SVG_NS, 'line');
        l.setAttribute('x1', r[0]); l.setAttribute('y1', r[1]);
        l.setAttribute('x2', r[2]); l.setAttribute('y2', r[3]);
        svg.appendChild(l);
      });
    } else {
      // Croissant : proposer de passer en sombre.
      var p = document.createElementNS(SVG_NS, 'path');
      p.setAttribute('d', 'M20.5 14.6A8.6 8.6 0 0 1 9.4 3.5a8.7 8.7 0 1 0 11.1 11.1z');
      svg.appendChild(p);
    }
    return svg;
  }

  /* Le libelle depend du module ouvert. SOGo sert chaque module par une page
   * distincte, donc l'URL suffit et reste juste apres navigation interne. */
  function composeLabel() {
    var p = window.location.pathname;
    if (p.indexOf('/Calendar') !== -1) return 'Nouvel événement';
    if (p.indexOf('/Contacts') !== -1) return 'Nouveau contact';
    return 'Nouveau message';
  }

  /* Le bouton flottant natif porte deja l'action. Deux formes existent selon
   * la preference « composer dans une fenetre » : un bouton simple, ou un
   * cadran a plusieurs actions dont on veut la premiere. */
  function nativeComposeTarget() {
    var simple = document.querySelector('.md-button.md-fab.sg-fab-bottom-center');
    if (simple) return simple;

    var dial = document.querySelector('md-fab-speed-dial.sg-fab-bottom-center');
    if (dial) {
      return dial.querySelector('md-fab-actions .md-button') ||
             dial.querySelector('md-fab-trigger .md-button');
    }
    return null;
  }

  function installBrand(sidenav) {
    if (sidenav.querySelector('.pm-brand')) return;

    var brand = document.createElement('div');
    brand.className = 'pm-brand';

    // Le logo est celui que Mailcow monte deja : remplacer
    // data/conf/sogo/custom-fulllogo.svg suffit a changer la marque.
    var img = document.createElement('img');
    img.src = '/SOGo/WebServerResources/img/sogo-full.svg';
    img.decoding = 'async';
    img.alt = '';
    // Si le fichier manque, on retombe sur un intitule texte plutot que sur
    // une icone cassee.
    img.onerror = function () {
      img.remove();
      var name = document.createElement('span');
      name.className = 'pm-brand-name';
      name.textContent = 'urbanlink';
      brand.appendChild(name);
    };
    brand.appendChild(img);

    sidenav.insertBefore(brand, sidenav.firstChild);
  }

  function installCompose(sidenav) {
    if (sidenav.querySelector('.pm-compose')) return false;

    var target = nativeComposeTarget();
    if (!target) return false;

    var wrap = document.createElement('div');
    wrap.className = 'pm-compose-wrap';

    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'pm-compose';
    btn.appendChild(mdIcon(ICONS.edit));

    var span = document.createElement('span');
    span.textContent = composeLabel();
    btn.appendChild(span);

    // On relit la cible a chaque clic : Angular recree le bouton flottant
    // quand on change de dossier, et une reference gardee deviendrait morte.
    btn.addEventListener('click', function (ev) {
      ev.preventDefault();
      var t = nativeComposeTarget();
      if (t) t.click();
    });

    wrap.appendChild(btn);

    var content = sidenav.querySelector('md-content');
    if (content) {
      content.parentNode.insertBefore(wrap, content);
    } else {
      sidenav.appendChild(wrap);
    }

    document.body.classList.add('pm-has-compose');
    return true;
  }

  function installThemeToggle() {
    var bar = document.querySelector('md-toolbar.toolbar-main .sg-toolbar-group-last');
    if (!bar || bar.querySelector('.pm-theme-toggle')) return;

    var current = document.documentElement.getAttribute('data-pm-theme');

    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'md-button md-icon-button pm-theme-toggle';
    btn.setAttribute('aria-label', 'Basculer clair / sombre');
    btn.title = 'Basculer clair / sombre';
    btn.appendChild(svgIcon(current));

    btn.addEventListener('click', function () {
      var next = document.documentElement.getAttribute('data-pm-theme') === 'dark'
        ? 'light' : 'dark';
      applyTheme(next);
      var old = btn.querySelector('svg');
      if (old) btn.replaceChild(svgIcon(next), old);
    });

    bar.insertBefore(btn, bar.firstChild);
  }

  /* La date du bandeau superieur : SOGo affiche un pave de quatre lignes pour
   * une information que le systeme donne deja. Le CSS masque le pave ; on
   * remet ici le mois et l'annee en suffixe du numero de jour, ce qui tient
   * sur une ligne. L'attribut est lu par une regle ::after -- on ne touche
   * pas au textContent, qui appartient a ng-bind. */
  function annotateDate() {
    var day = document.querySelector('md-toolbar.toolbar-main .sg-date-today');
    if (!day || day.hasAttribute('data-pm-date-suffix')) return;

    var group = document.querySelector('md-toolbar.toolbar-main .sg-date-group');
    if (!group) return;

    var month = group.querySelector('.sg-month');
    var year = group.querySelector('.sg-year');
    if (!month || !year) return;

    var suffix = (month.textContent || '').trim().toLowerCase() + ' ' +
                 (year.textContent || '').trim();
    if (suffix.length > 1) day.setAttribute('data-pm-date-suffix', suffix);
  }

  function enhance() {
    var sidenav = document.querySelector('md-sidenav.md-sidenav-left');
    if (sidenav) {
      installBrand(sidenav);
      installCompose(sidenav);
    }
    installThemeToggle();
    annotateDate();
  }

  /* Angular construit la barre laterale apres l'amorcage, et la reconstruit
   * lors des changements d'etat de ui-router. Un observateur est plus sur
   * qu'un delai fixe, qui casserait sur une machine lente. On le desarme au
   * bout d'une minute : au-dela, ce n'est plus un retard de rendu mais une
   * page qui n'a pas les elements attendus. */
  function watchDom() {
    enhance();

    var observer = new MutationObserver(function () {
      enhance();
    });
    observer.observe(document.body, { childList: true, subtree: true });

    window.setTimeout(function () {
      observer.disconnect();
    }, 60000);
  }

  document.addEventListener('DOMContentLoaded', function () {
    // Angular a enregistre son propre ecouteur DOMContentLoaded AVANT nous
    // (angular.min.js est charge plus tot dans la page), donc son theme
    // genere est deja dans le <head> a ce stade : on peut se placer derriere.
    if (link.parentNode === document.head) {
      document.head.appendChild(link);
    }
    watchDom();
  });
})();
