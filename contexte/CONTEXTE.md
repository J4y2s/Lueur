# Lueur — fichier de contexte

*État au 10 novembre 2026 (fin de journée), branche GitHub `V.1.2`.*

## Le projet en bref

Lueur est une VM Proxmox qui sert de récepteur AirPlay 2 et synchronise les lampes Philips Hue sur la musique, et aussi sur l'image de la TV Philips (Ambilight).

- **Réception audio** : shairport-sync reçoit le son de l'iPhone, compilé avec AirPlay 2 et les métadonnées.
- **Moteur** : `hue_music_sync.py` analyse l'audio et envoie les couleurs au pont Hue en streaming (Entertainment API v2, DTLS via `openssl s_client`). Il pilote aussi la TV Philips (API JointSpace v6) : lecture de l'Ambilight pour la synchro vidéo, écriture de l'Ambilight pendant la musique quand la TV est en veille.
- **Interface web** : `hue_sync_web.py` (Python standard, port 8080) sert `index.html`, une app web en JS vanilla au style proche d'iOS et de Hue.
- **Bluetooth** : le son peut aussi sortir sur une enceinte Bluetooth. Un adaptateur USB Apple 05ac:828a (Broadcom) est passé à la VM.

Infos pratiques :

- **Dépôt** : `github.com/J4y2s/Lueur`, branche `V.1.2`.
- **VM actuelle** : **106**, sous Debian 12 (image cloud, UEFI/OVMF, agent QEMU). Interface sur `http://192.168.50.183:8080` (utilisateur `hue`).
- **Côté utilisateur** : iPhone avec le navigateur Brave.

## Installation de chez l'utilisateur

- **Salon** :
  - un ruban **Hue Flux de 17 m** dans une corniche, qui fait le tour de la pièce (7 segments en synchro, 5 points de dégradé hors synchro) ;
  - **6 spots** au plafond ;
  - zone de synchro **« Lueur · Salon »** créée par Lueur (7 canaux pour le ruban) ;
  - une zone Hue « Corniche » qui ne contient que le ruban.
- **Chambre** : une Hue Play et deux Hue Bloom.
- **Bureau** : prévu de façon générique (plusieurs rubans, lampe blanche).
- **TV** : Philips **55OLED707** en `192.168.50.79`, Ambilight 3 côtés (gauche 3 · haut 7 · droite 3 pixels). Appairée à Lueur, rattachée à la pièce du salon (`settings.tv.area`). Sur ce modèle, seul `/6/ambilight/measured` donne les couleurs de l'image (`processed` et `cached` renvoient des zéros en lecture).
- **Zone de divertissement « iLightShow#iOS »** : créée par l'app iLightShow, un seul canal ; ne pas la choisir.
- **Réglages relevés le 9/11** : intensité **Subtile**, décalage Bluetooth de **550 ms**, appareil BT `04:52:C7:88:B1:A5`.

## Fichiers sources

C'est le projet qui fait foi : `src/` (parties + correctifs, voir `src/LISEZMOI.md`), ou le dépôt GitHub `V.1.2` une fois les scripts poussés. L'espace de travail cloud est temporaire.

| Fichier | Rôle |
|---|---|
| `hue_music_sync.py` | Moteur : analyse audio, détection des temps, effets, couches, plans, streaming HueStream, TV (`TvClient`, `TvWatcher`, `VideoMapper`, `tv_amb_apply`) |
| `hue_sync_web.py` | Serveur web et API : réglages, pièces, plans, palettes, métadonnées AirPlay, Bluetooth, scènes, TV |
| `index.html` | Toute l'interface |
| `shairport-sync.conf` | Nom AirPlay « Lueur », sortie stdout, métadonnées vers `/run/hue-music-sync/metadata` |
| `hue-airplay.service` | `shairport-sync \| hue_music_sync.py` en root, avec `RuntimeDirectory=hue-music-sync` |
| `hue-sync-web.service`, `hue-airplay.default` | Service web et variables (`HUE_AIRPLAY_NAME="Lueur"`) |
| `install-head.sh` + `install-tail.sh` | Installeur dans la VM |
| `proxmox-head.sh` + `proxmox-tail.sh` | Création de la VM sur l'hôte Proxmox |
| `build.sh`, `build-update.sh`, `build-proxmox.sh` | Génèrent les 3 scripts livrés |

Les 3 scripts générés sont ceux que l'utilisateur met sur GitHub. Ils embarquent tout le code.

- `install-hue-airplay.sh` : installation complète.
- `update-hue-sync.sh` : mise à jour. Il garde les réglages, installe `python3-pil` et recompile shairport-sync avec `--with-metadata` si besoin.
- `create-hue-sync-vm.sh` : création de la VM. Il contient l'installeur compressé (gzip + base64).

**Commande de mise à jour** (sur l'hôte Proxmox, après avoir poussé les scripts) :

```
qm guest exec 106 --timeout 600 -- bash -c 'curl -fsSL "https://raw.githubusercontent.com/J4y2s/Lueur/V.1.2/update-hue-sync.sh?$(date +%s)" | bash; grep -c galiseur /opt/hue-music-sync/hue_music_sync.py'
```

- Le `?$(date +%s)` contourne le cache de raw.githubusercontent (environ 5 min).
- Le `grep` doit renvoyer au moins 1. 0 veut dire que c'est l'ancien code. Pour la dernière version : `grep -c tvPixHtml /opt/hue-music-sync/index.html` ≥ 1.
- Mettre `--timeout 1800` si shairport doit être recompilé.
- Si l'agent QEMU ne répond pas : `qm reboot 106` ou `ssh hue@192.168.50.183`.

Chemins dans la VM : `/opt/hue-music-sync/` (code), `/etc/hue-music-sync/` (config : `settings.json`, `cover.json`, `config.json`, `tv.json`, `.ambilight-musique` pendant la musique en veille), `/run/hue-music-sync/` (statut, tube de métadonnées).

## Ce qui fonctionne

### Interface

- **Onglets** : Synchro, Lumières, Réglages. Mise en page ordinateur à partir de 960 px.
- **Écran Synchro** : choix de la zone ; pochette AirPlay, titre, artiste, album et barre de progression ; « LEDs » en direct par canal ; halo ; boutons Effet, Intensité, Couleur et Luminosité.
- **Feuilles** : jamais plus hautes que l'écran, en-tête visible, fermeture en tirant vers le bas ou avec Échap.
- **Lumières** :
  - pièces **et zones Hue** ;
  - page Pièce en **cartes déroulantes** (Réglages des scènes, Scènes, Effets, Lampes), mini-plan avec la TV dessinée dans sa pièce ;
  - la TV apparaît comme une **lampe « Ambilight »** dans la pièce de la TV : la tuile allume, éteint et colore l'Ambilight (pas la TV) ;
  - page Lampe : roue de couleurs, Blanc, luminosité ; pour les **rubans et lampes gradient**, 2 à 5 points sur la roue, Style (Linéaire, Reproduit, Épars, Segmenté) et Orientation, comme l'app Hue ; pour l'**Ambilight**, couleur **pixel par pixel** (13 pixels) ;
  - création de scènes et palettes, communes à la synchro et aux scènes des pièces ;
  - effets intégrés du pont (Bougie, Âtre, Prisme…).
- **Réglages** : Plans des pièces (zones de divertissement, pièces, zones Hue), **Téléviseur Ambilight** (appairage, pièce de la TV, synchro vidéo, Ambilight avec la musique, liaison, placement, rendu), Bluetooth, journal.

### Moteur

- **Détection des temps** : deux détecteurs (graves 30–160 Hz, médiums-aigus 160–6000 Hz), retard 0 ms en simulation.
- **Niveaux dynamiques** : chaque bande comparée à sa moyenne sur ~1 s.
- **9 effets** : `pulse`, `spectrum`, `glisse`, `comete`, `vague`, `vumetre`, `stereo`, `etincelles`, `respiration`.
- **Vitesse** ×½, ×1, ×2 ; **couches par famille de lampes** (`settings.layers`) ; **réglages par zone** (`settings.zones`).
- **Plans** (`settings.plans[area_id].ch`) : x et y de −1 à 1 (y = +1 côté TV), ordre de parcours `t`, vraie position gauche-droite `sx`. Appliqués en direct par `plan_channels()`.
- **Palette « Pochette »** : 4 couleurs extraites de la pochette (`cover.json`).
- **Mode test** (`settings.test`) et limite de 20 canaux par message HueStream.
- **Synchro vidéo** (validée le 10/11, 68 lectures/s) : `TvWatcher` lit l'Ambilight et `VideoMapper` répartit les couleurs sur les canaux selon le plan. La musique reste prioritaire. Seulement si la zone synchronisée est celle de la TV.
- **Ambilight avec la musique** (validé le 10/11) : TV en veille, l'Ambilight prend les couleurs des lampes voisines sur le plan, à 20 Hz ; état de la TV lu dans un fil à part (`_power_loop`), renvoi toutes les 2 s, état d'origine rendu à la fin.

### Serveur

- **Connexion** : HTTP/1.1 keep-alive avec TCP_NODELAY ; réglages relus par le moteur toutes les 0,2 s.
- **Flux d'événements du pont** (`LiveBridge`) : état des lampes à jour en direct.
- **Palette d'une pièce** (`/api/room/palette`) : envoi en arrière-plan, palette répartie le long du ruban, chaque spot prend la couleur du point du ruban le plus proche.
- **`APPLIED`** : couleur exacte envoyée à chaque lampe (et dégradé : `{grad, gxy}`), car le pont arrondit les couleurs.
- **`/api/light`** : `on`, `bri`, `color`, `mirek`, et `gradient` (2 à 5 hex) + `mode`. **`/api/light/order`** : sens du ruban.
- **TV** : `GET /api/tv`, `POST /api/tv/pair|pin|test|forget|ambilight` ; réglages `settings.tv` (`on, music, area, x, w, back, spots, hz, smooth, flip, amb`), `amb` = `{on, color, bri, pix}`.
- **Plans des pièces Hue** (`settings.room_plans`), **scènes animées** (scène « Lueur » + `dynamic_palette`), **« Montrer le début »** (`/api/plan/identify`).

## Préférences de l'utilisateur

- Réponses en **français**, utilisateur sur iPhone.
- Style iOS / Hue, mais **sans copier** les logos, icônes ou noms de scènes de Hue. Les icônes de Lueur sont dessinées pour le projet. Les noms des styles de dégradé (Linéaire, Reproduit, Épars, Segmenté) reprennent ceux de l'app Hue à sa demande.
- Pas de sous-titres sous les pièces. Le dégradé du ruban va **du plus foncé au plus clair**, ou suit le plan.
- Pas de bordure colorée sur les tuiles.
- Il veut une interface très réactive, et que les lampes fassent vraiment ce que montre l'app.
- Pas de réglages TV dans les pièces : la TV y est une lampe comme les autres.
- L'app doit rester **générique**, pas seulement adaptée à son installation.

## Sources techniques vérifiées

- **Doc officielle Hue** (reçue le 9/11) : résumé dans `claude/DOC-HUE.md`. Un dégradé REST a 5 points au maximum.
- **Q42.HueApi** : un message de streaming porte 20 canaux au maximum ; canaux reliés au matériel par `members[].service.rid`.
- **TV Philips (testé sur la vraie TV)** : `measured` en lecture ; en écriture `POST /6/ambilight/power`, `/6/ambilight/mode` (`manual` / `internal`), `/6/ambilight/cached` (`{r,g,b}` ou `{"layer1":{left,top,right}}`), y compris en veille, ~50 envois/s. **Non vérifié** : sens de numérotation des pixels sur chaque côté.
