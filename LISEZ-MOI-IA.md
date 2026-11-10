# Lueur — dossier de reprise pour une autre IA

Ce zip contient le code de Lueur et le contexte du projet, pour qu'une autre IA puisse le reprendre. Il vient de la branche `V.1.2` du dépôt `github.com/J4y2s/Lueur`, commit `1c3657d` (10/11/2026), qui inclut les correctifs 1 à 23. L'utilisateur parle français : répondre en français.

## Lueur en deux phrases

Une VM Proxmox (Debian 12) qui reçoit l'audio AirPlay 2 (shairport-sync), le passe à `hue_music_sync.py`, qui pilote des lampes Philips Hue en synchro musicale (Entertainment API v2, DTLS 50 Hz) et une TV Philips Ambilight (JointSpace v6). Une interface web (`hue_sync_web.py` + `index.html`, port 8080) sert à tout régler depuis un iPhone ou un ordinateur.

## Contenu

| Dossier / fichier | Contenu |
|---|---|
| `site/hue_music_sync.py` | Moteur : analyse audio, effets, plans, streaming HueStream, TV |
| `site/hue_sync_web.py` | Serveur web et API (Python standard) |
| `site/index.html` | Toute l'interface (JS vanilla, une seule page) |
| `deploy/` | `shairport-sync.conf`, services systemd, fichier d'environnement |
| `docs/` | Images du README du dépôt |
| `contexte/CONTEXTE.md` | Vue d'ensemble, installation de l'utilisateur, fonctionnalités, préférences |
| `contexte/HANDOFF.md` | Où on en est, à vérifier chez l'utilisateur, pistes, points de vigilance |
| `contexte/DOC-HUE.md` | Notes sur l'API Hue (segments, dégradés, scènes, zones, débits) |
| `contexte/AUDIT.md`, `AUDIT-MOTEUR-DESIGN.md` | Audits du 10/11 de cette version |
| `contexte/NOTES-DEV-TESTS.md` | Journal des 23 correctifs et recettes de test |
| `contexte/README-depot.md` | README du dépôt GitHub |

## Par où commencer

1. Lire `contexte/CONTEXTE.md`, puis `contexte/HANDOFF.md`.
2. Les fichiers de `site/` sont les sources à jour et déjà assemblées (vérifiées avec `py_compile` et `node --check`). Pas besoin d'appliquer de correctifs.
3. Pour toucher à l'API Hue, lire `contexte/DOC-HUE.md` d'abord (position `STRIP_SPOT` d'un ruban, limites de 5 points de dégradé et 20 canaux par message).
4. Les audits listent les corrections prioritaires (verrou sur `settings.json`, contrôle de l'`Origin`, tests rejouables, mise à jour plus sûre).

## Ce qui n'est pas dans le zip

- **Les 3 scripts d'installation générés** (`install-hue-airplay.sh`, `update-hue-sync.sh`, `create-hue-sync-vm.sh`) : ils embarquent tout le code et sont sur GitHub, branche `V.1.2`. Les scripts de construction (`build*.sh`, `install-head/tail.sh`, `proxmox-head/tail.sh`) ne vivent que dans le projet Claude « Lueur » (`src/autres-fichiers.txt`) ; le principe est décrit dans `contexte/NOTES-DEV-TESTS.md`.
- **Aucun secret** : ni `config.json` (clé du pont), ni `tv.json` (identifiants TV), ni `settings.json`. Ces fichiers sont créés dans la VM, dans `/etc/hue-music-sync/`.
- Le faux pont et la fausse TV de test sont décrits mais pas fournis : à refaire.

## Règles à respecter

- Interface en français, style iOS / Hue, sans copier les logos ni icônes de Hue.
- L'application doit rester générique (pas seulement adaptée à l'installation de l'utilisateur).
- Pas de réglages TV dans les pièces : la TV y est une lampe « Ambilight ».
- Tester à taille d'iPhone réelle (390 px de large).
- Debian 12 image cloud : ne jamais installer `systemd-dev` depuis les backports ; toujours `apt-get --no-remove`.
