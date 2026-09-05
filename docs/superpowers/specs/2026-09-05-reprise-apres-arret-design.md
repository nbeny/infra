# Reprise apres arret : audit et exercice de restauration

**Date** : 2026-09-05
**Question posee** : au redemarrage du noeud, tout revient-il — sauf `kali-test`,
`test-k8s` et `tpl-macos-monterey` ? Et les sauvegardes sont-elles restaurables ?

## 1. Ce qui redemarre : l'audit

### Cote Proxmox

| VM | onboot | rang de demarrage | voulu |
|---|---|---|---|
| 111 urbanlink | 1 | `order=1,up=90` | demarre |
| 140 mail | 1 | `order=2,up=30` | demarre |
| 130 ci-runner | 1 | sans rang → demarre en dernier | demarre |
| 120 kali-test | 0 | — | **eteinte** |
| 190 test-k8s | 0 | — | **eteinte** |
| 9200 tpl-macos-monterey | 0 | — | **eteinte** |

Les quatre autres `9xxx` portent `template: 1` : ce sont de vrais gabarits,
Proxmox refuse de les demarrer. `tpl-macos-monterey`, malgre son nom, n'en est
**pas** un — c'est une VM ordinaire, d'ou la necessite de la nommer.

### Cote systeme, dans les VMs

Le controle porte sur tous les services **actifs** de chaque hote : lesquels ne
sont pas `enabled`, `static`, `indirect` ou `generated` — c'est-a-dire lesquels
ne reviendraient pas ?

| Hote | services actifs | qui ne reviendraient pas |
|---|---|---|
| noeud Proxmox | 45 | 0 |
| urbanlink | 16 | 0 |
| ci-runner | 20 | 0 |
| mail | 16 | 0 |
| vps-mail | 19 | 0 |

**116 services, aucun trou.**

### Cote conteneurs

50 conteneurs Docker sur les quatre hotes. Deux seulement sans politique de
redemarrage : `bottrading-migrate-1` et `bottrading-kafka-init-1`, des
conteneurs d'initialisation en `on-failure` deja termines. C'est le
comportement correct — les relancer serait le bug.

> **Fausse alerte, corrigee en cours d'audit.** `lab-registry` tourne sans
> politique Docker et avec `--rm`, ce qui ressemblait a un trou. C'est un choix
> deliberé du role `registry` : c'est **systemd** qui le supervise
> (`lab-registry.service`, `Restart=always`, `enabled`), pas le demon Docker. Le
> `--rm` est la pour que le conteneur ne survive pas au service.

### Cote Kubernetes

- 62 pods, **aucun sans controleur** : tout est recree apres un arret ;
- tous les PVC `Bound` ;
- application Argo CD `urbanlink` : `Synced` / `Healthy`.

Et surtout, une preuve empirique plutot qu'un raisonnement : **la VM a redemarre
il y a 20 heures**. Les pods du plan de controle portent des compteurs de
redemarrage dates de ce moment-la — `etcd`, `kube-apiserver` et `coredns` sont
remontes seuls.

## 2. Les deux defauts trouves, et corriges

### `on_boot = false` ne garde pas une VM eteinte

C'est le defaut le plus dangereux, parce qu'il etait **silencieux** : la
configuration disait le contraire de ce qu'elle allait faire.

`on_boot` ne regit que le demarrage du noeud. L'etat courant est regi par
`started`, dont le defaut vaut `true`. Le plan Terraform du jour voulait donc :

```
# module.vm["kali-test"].proxmox_virtual_environment_vm.this will be updated in-place
      ~ started = false -> true
# module.vm["test-k8s"].proxmox_virtual_environment_vm.this will be updated in-place
      ~ started = false -> true
```

Deux des trois VMs qui doivent rester eteintes auraient ete **rallumees par un
simple `terraform apply`**. `started = false` est desormais explicite sur les
deux, et la nuance est documentee dans le tfvars d'exemple.

### Aucun ordre de demarrage, sous une RAM surengagee

118 Go promis aux VMs pour 110 Go physiques. Tant que les invites ne touchent
pas toute leur memoire cela passe, mais un demarrage a froid les lance **toutes
en meme temps** — precisement le moment ou chacune en demande le plus.

Le module `vm` accepte maintenant `startup_order` et `startup_up_delay`.
`urbanlink` demarre en premier (c'est la plus grosse, et la seule sans
ballooning) et laisse 90 s a Kubernetes pour se poser ; `mail` suit a 30 s ;
`ci-runner` n'a volontairement pas de rang, car Proxmox demarre en dernier ce
qui n'en a pas — rien a declarer, et elle n'est de toute facon pas geree par
Terraform.

## 3. L'exercice de restauration

`scripts/mail/tester-restauration.sh`, avec la procedure complete en tete de
fichier.

### Le point a ne pas manquer : l'isolation

La copie restauree porte la **meme cle privee WireGuard** que la production. Si
sa carte reseau montait, le VPS verrait deux pairs pour une seule cle et le
courrier entrant tomberait. D'ou, avant tout demarrage :

```bash
qm set 141 --net0 "$(qm config 141 | sed -n 's/^net0: //p'),link_down=1"
```

Le script refuse de continuer si ce garde-fou n'est pas en place. La
verification passe ensuite par l'**agent QEMU**, pas par SSH : il n'y a pas de
reseau, et c'est voulu. `--unique 1` a la restauration regenere par ailleurs
l'adresse MAC.

Controle fait pendant l'exercice : la poignee de main du tunnel restait sur la
production, et le port 25 repondait `220 mail.urbanlink.fr ESMTP Postcow`.

### Ce que l'exercice a montre

Premier passage, sur la sauvegarde de 14:25 :

| Controle | Resultat |
|---|---|
| Copie isolee | OK |
| **18 conteneurs Mailcow remontes seuls apres un demarrage a froid** | OK |
| Domaine `urbanlink.fr` en base | OK |
| 4 boites aux lettres en base | OK |
| Cle DKIM publique restauree | OK |
| Messages lisibles | **echec apparent** |

L'echec n'en etait pas un. La sauvegarde datait de **14:25:15** ; les trois
messages de la boite ont ete recus a **14:27:33**, **14:31:11** et **14:45:06**.
Le vmail restaure etait vide **a juste titre**.

C'est exactement le genre de conclusion qu'un exercice de restauration sert a
eviter : sans la comparaison des horodatages, on aurait conclu a des sauvegardes
inutilisables. Le script affiche desormais la commande de verification quand la
boite ressort vide.

Deux enseignements au passage :

- **Dovecot boucle au demarrage sur une copie isolee.** Il tente de telecharger
  les regles SpamAssassin, echoue faute de reseau, et sort. Tant qu'il n'a pas
  tenu, `doveadm` repond `connect(/run/dovecot/auth-userdb) failed` — ce qui
  ressemble a une perte de donnees. Le script attend maintenant que Dovecot se
  stabilise avant de conclure.
- `qm restore` n'existe pas ; la commande est **`qmrestore`**.

## 4. Ce qui reste a la main

`ci-runner` (130) et `tpl-macos-monterey` (9200) ne sont pas geres par
Terraform : leur `onboot` est correct mais pose a la main. Les remettre sous
Terraform les ferait recreer — a ne faire que deliberement.
