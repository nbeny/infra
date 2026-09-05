# Refonte visuelle du webmail SOGo

**Date** : 2026-09-05
**Portee** : interface uniquement. Postfix, Dovecot, Rspamd, MariaDB, Redis, IMAP,
SMTP, l'authentification, les comptes, les filtres et le stockage des messages ne
sont pas touches. Le controle `scripts/mail/verifier-messagerie.sh` passe
35 controles sur 36 apres la refonte, l'unique echec restant etant le PTR chez
Hostinger, anterieur a ce travail.

## Le probleme, et pourquoi il n'avait pas de solution evidente

SOGo 5.12.10 n'expose **aucun point d'accroche pour une feuille de style**. La
seule directive du genre est `SOGoUIAdditionalJSFiles` ; il n'existe pas de
`SOGoUIAdditionalCSSFiles` :

```
$ docker exec ...-sogo-... grep -rao 'SOGoUIAdditional[A-Za-z]*' /usr/local/lib/
SOGoUIAdditionalJSFiles
```

Le gabarit `UIxPageFrame.wox` boucle bien sur un `additionalCSSFiles`, mais cette
liste vient du `product.plist` de chaque paquet de l'image : elle n'est pas
configurable.

Un `sub_filter` nginx aurait pu injecter la balise `<link>`. Il est inutilisable
ici, pour deux raisons cumulees :

- **sogod compresse ses reponses en gzip** des que le client l'accepte
  (verifie : `Content-Encoding: gzip` sur `http://sogo-mailcow:20000/SOGo/`), et
  `sub_filter` travaille sur du texte clair ;
- le bloc `location ^~ /SOGo` livre par Mailcow **definit ses propres
  `proxy_set_header`**, ce qui coupe l'heritage : on ne peut pas y neutraliser
  `Accept-Encoding` depuis un fichier `.custom`, et ce bloc ne peut pas etre
  redeclare.

D'ou la solution retenue : **servir notre propre contenu a l'URL que SOGo demande
deja**. `sogo.conf` charge `js/theme.js` de toute facon ; il suffit que nginx
reponde notre fichier a cette adresse. Le JavaScript injecte ensuite la feuille de
style.

## Architecture

```
depot                                   VM 10.0.0.140                    navigateur
-----                                   -------------                    ----------
files/theme/sogo-proton.css   --->  data/conf/nginx/proton-theme.css.custom   ---.
files/theme/sogo-proton.js    --->  data/conf/nginx/proton-theme.js.custom    ---|
files/theme/logo-*.svg        --->  data/conf/nginx/proton-logo-*.svg.custom  ---|
                                                    |                            |
templates/nginx-theme.conf.j2 --->  data/conf/nginx/site.proton-theme.custom   --+--> location =
                                                                                      + no-cache
files/theme/mailcow-login.css --->  data/web/css/build/0081-custom-mailcow.css --> bundle /cache
```

`data/conf/nginx` est deja monte dans le conteneur nginx en tant que
**repertoire**. C'est le point technique central : un montage de repertoire suit
les chemins, la ou un montage de fichier suit l'**inode**. La premiere version du
theme montait chaque fichier individuellement via un `docker-compose.override.yml`
et servait indefiniment le contenu capture au demarrage du conteneur, parce que
Ansible ecrit dans un fichier temporaire puis le renomme.

## Ce qui a ete choisi, et pourquoi

| Decision | Raison |
|---|---|
| Injection de la feuille par `theme.js` | Seul point d'accroche que SOGo 5.12 offre. |
| `<link>` insere en synchrone, puis redeplace en fin de `<head>` a l'amorcage | L'insertion synchrone evite le flash de page non stylee ; le redeplacement passe derriere le theme genere a l'execution par Angular Material (~170 Ko), qui gagnerait sinon les egalites de specificite. |
| Palette Angular Material redefinie par `$mdThemingProvider` | Ce qui est genere a l'execution (encre, cases a cocher, barres de progression) nait deja violet, au lieu d'etre repeint apres coup. |
| Palette de FOND laissee intacte | C'est elle que la directive `md-colors` ecrit en styles **en ligne**, une seule fois au demarrage. La figer permet a la bascule clair/sombre d'agir sans recharger la page. |
| `Cache-Control: no-cache` sur les fichiers du theme | L'URL generee par SOGo porte un `?lm=` calcule au demarrage de sogod : elle ne change jamais. Sans en-tete, le navigateur resservait sa copie **sans meme revalider**. |
| Aucune police telechargee | La pile s'appuie sur ce qui est installe et retombe sur Roboto, deja embarque par SOGo. Pas de dependance externe, pas de fuite vers un CDN. |
| Icones : celles de SOGo, sauf la bascule | La police Material Icons de SOGo 5.12 est anterieure aux ligatures `dark_mode` / `light_mode` : une ligature inconnue ne rend aucun glyphe. La bascule utilise donc un SVG en ligne. |

## Trois pieges rencontres, et leur diagnostic

**1. Les pseudo-elements de `md-list-item` ne sont jamais peints.** Angular
Material enveloppe le contenu des lignes cliquables dans un bouton
(`_md-button-wrap`). La regle `::before` s'applique, le navigateur calcule ses
valeurs — `width: 3px`, `background: rgb(109,74,255)` — et rien n'apparait. Les
indicateurs « non lu », « selectionne » et « epingle » sont donc des **ombres
internes** (`box-shadow: inset`), qui respectent le rayon et se peignent.

**2. Un survol qui effacait les messages.** La regle generique de survol des
boutons donnait un fond au `<button class="md-no-style">` que Material pose en
position absolue par-dessus chaque ligne de liste. Resultat : expediteur, objet,
date et taille disparaissaient au passage de la souris. Diagnostique a
`document.elementsFromPoint()` : le texte etait la, recouvert. La regle exclut
desormais `.md-no-style`, qui signifie litteralement « ne stylez pas ce bouton ».

**3. Mailcow embarque CKEditor 5, pas 4.** Les classes sont `.ck-*` et l'edition
se fait dans la page, sans iframe : la couleur de texte du corps descendait
jusqu'a la zone de saisie, et en mode sombre on ecrivait en clair sur blanc. Le
theme rebranche les variables CSS de CKEditor 5 sur nos jetons.

## Ce qui survit a une mise a jour de Mailcow

Tous les chemins ecrits sont couverts par le `.gitignore` de Mailcow :

- `data/conf/nginx/*.custom` (lignes 31 et 78) ;
- `data/web/css/build/0081-custom-mailcow.css` (ligne 66).

Aucun fichier livre par Mailcow n'est modifie, aucun conteneur n'est ecrit, et sa
composition Docker n'est pas touchee. `git pull` et `update.sh` laissent le theme
en place. Si une version future de SOGo changeait la structure du DOM, le theme se
degraderait visuellement mais ne casserait aucune fonction : le bouton
« Nouveau message » delegue au bouton flottant natif au lieu de reimplementer la
composition.

## Verification

Le role ne se contente pas de deposer les fichiers : il **compare l'empreinte
SHA-1 de ce que nginx sert a celle de la source du depot**, pour les cinq
ressources. C'est la lecon du premier deploiement, ou les fichiers etaient
corrects sur la VM et le navigateur recevait autre chose, sans le moindre message
d'erreur.

```
ansible-playbook playbooks/42-mailcow.yml --tags theme
```

## Retour en arriere

Supprimer `data/conf/nginx/site.proton-theme.custom` et relancer le conteneur
nginx suffit : les URL retombent sur les fichiers d'origine de SOGo et de Mailcow,
qui n'ont jamais ete modifies.

```bash
ssh nbeny@10.0.0.140 \
  'sudo rm /opt/mailcow-dockerized/data/conf/nginx/site.proton-theme.custom && \
   cd /opt/mailcow-dockerized && sudo docker compose restart nginx-mailcow'
```

Pour l'interface Mailcow, remettre `0081-custom-mailcow.css` a son contenu
d'origine, sauvegarde sur la VM dans `/var/backups/sogo-theme/<horodatage>/`.

## Remplacer le logo

Trois fichiers, dans `ansible/roles/mailcow/files/theme/` :

| Fichier | Ou il apparait |
|---|---|
| `logo-full.svg` | Bandeau de marque, en haut de la barre laterale du webmail |
| `logo-short.svg` | Barre laterale repliee |
| `logo-portrait.svg` | Page de connexion et console Mailcow |

Ecraser le fichier et rejouer le playbook. Les logos d'origine de Mailcow n'ont
pas ete effaces : ils sont intacts dans l'image, et une copie de ce qui existait
sur la VM avant la refonte est dans `/var/backups/sogo-theme/`.

Ces images sont chargees par `<img>` : elles n'heritent pas des variables CSS de
la page. Le violet `#7c5cff` retenu est un compromis, choisi pour tenir le
contraste sur le fond clair comme sur le fond sombre de la barre laterale.

## Limites assumees

- **Le premier chargement apres un changement de theme peut servir l'ancienne
  version.** Les entrees deja en cache chez un utilisateur ont ete enregistrees
  avant que l'en-tete `no-cache` n'existe ; elles expirent d'elles-memes selon la
  regle heuristique du navigateur. Un rafraichissement force (Ctrl+F5) tranche
  immediatement.
- **La console d'administration de Mailcow n'est repeinte qu'en surface**
  (boutons, champs, cartes, liens, logo). C'est un Bootstrap dense : le reprendre
  entierement reviendrait a maintenir un second theme, pour une interface qu'on
  ouvre rarement.
- **Le corps des messages HTML recus garde un fond blanc en mode sombre.**
  Inverser les couleurs d'un courriel rend illisibles les images et les
  signatures ; il est isole dans une carte claire plutot que retouche.
- **Une erreur console prealable subsiste** : `CKEDITOR is not defined`, levee par
  `custom-sogo.js` livre par Mailcow. Elle est anterieure a ce travail et sans
  effet visible.
