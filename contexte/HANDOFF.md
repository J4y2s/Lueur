# Lueur — handoff

*Pour reprendre le projet dans une nouvelle conversation. Mis à jour le 10/11/2026 en fin de journée. Lire aussi `CONTEXTE.md` et `DOC-HUE.md`.*

## Pour démarrer la prochaine session

1. **Les sources sont dans le projet**, dossier `src/`. `src/LISEZMOI.md` explique comment les reconstituer : parties à mettre bout à bout, puis les **23 correctifs** à appliquer dans l'ordre. Les petits fichiers sont dans `autres-fichiers.txt`.
   - Plus simple, si l'utilisateur a poussé les derniers scripts : le dépôt GitHub `J4y2s/Lueur` (branche `V.1.2`) se clone depuis l'espace de travail. `update-hue-sync.sh` contient les 3 fichiers à jour entre des lignes `cat > /opt/hue-music-sync/<fichier> <<'HUE_FILE_EOF'` … `HUE_FILE_EOF`. **Vérifier qu'il contient `tvPixHtml` (dernier correctif, 23)** ; sinon appliquer les correctifs manquants du projet.
2. Pour reconstruire les scripts livrés : soit `bash build-update.sh && bash build.sh && bash build-proxmox.sh`, soit le raccourci décrit dans `LISEZMOI` (remplacer les blocs dans les scripts GitHub, réencoder l'installeur de `create-hue-sync-vm.sh`). Puis `bash -n`, `py_compile` et `node --check`.
3. Pour tester sans matériel (outils à refaire, l'espace de travail est perdu) : faux pont, fausse TV, captures Chrome sans écran à 390 px, gestes avec Playwright. Détails dans `src/LISEZMOI.md`.

## Fait le 10/11 (correctifs 14 à 23)

- Lecture des couleurs dans `measured` (14), format du plan corrigé (15), robustesse et reprise de `TvWatcher` (16, 17). **Synchro vidéo validée sur le vrai matériel.**
- **Ambilight avec la musique quand la TV est en veille** (18). **Validé.** Puis correction des coupures/reprises de l'Ambilight pendant la musique (19 : `powerstate` lu dans un fil à part).
- **TV rattachée à une pièce ou une zone** (20), écran TV refait et cartes déroulantes dans les pièces (21).
- **L'Ambilight comme une lampe** dans sa pièce (22) : la tuile ne pilote que l'Ambilight, pas la TV ni ses réglages (demande explicite de l'utilisateur).
- **Couleurs comme dans l'app Hue, hors synchro** (23) : rubans et lampes gradient à 2-5 points + Style + Orientation ; Ambilight pixel par pixel (13 pixels). Choix de l'utilisateur : 5 points (pas les 7 segments, impossibles sans streaming) et pixel par pixel pour l'Ambilight.
- Scripts livrés à l'utilisateur avec les correctifs 1 à 23. Il doit les pousser sur `V.1.2`, puis lancer la mise à jour.

## À vérifier chez l'utilisateur

- [ ] Dernière version installée : `grep -c tvPixHtml /opt/hue-music-sync/index.html` ≥ 1.
- [ ] **Ordre des pixels de l'Ambilight** (hypothèse : sens des aiguilles d'une montre vu de face, gauche de bas en haut, droite de haut en bas). Test : un pixel rouge en bas à gauche dans la page Ambilight ; s'il s'allume en haut, inverser `left` et `right` dans `tv_amb_apply` (et peut-être dans `VideoMapper.ambi`).
- [ ] **Dégradé à 5 points** : le pont accepte-t-il 2, 3 ou 4 points ? les 4 styles ? Orientation : effet visible sur un dégradé fixe ?
- [ ] Synchro vidéo encore OK quand la « lampe » Ambilight est allumée (mode `manual`) : la lecture `measured` suit-elle toujours l'image ?
- [ ] Plus de coupures de l'Ambilight pendant la musique en veille (correctif 19).
- [ ] TV rattachée au salon : rien ne se passe sur la TV quand on synchronise une autre zone.
- [ ] Interface : cartes déroulantes, tuile Ambilight, page Lampe sur iPhone (Brave).
- [ ] Anciens points non confirmés : effets intégrés avec `color`, styles du ruban dans une scène animée, glisse de Glissé/Comète, décalage Bluetooth (550 ms), barre de progression du morceau.

## Pistes ouvertes

- Proposées, pas demandées : **changement automatique de zone de synchro** quand la TV s'allume, **mode cinéma** selon l'app ouverte sur la TV (`/6/activities/current`), **scènes de l'app Hue** listées et rappelables (le plus gros manque).
- Mettre à jour le `README.md` du dépôt (`src/README.md`) : il ne parle pas encore de la TV ni des couleurs par point.
- Idées du 9/11 (rien de fait) : scènes naturelles (`smart_scene`), blanc à l'échelle d'une pièce, fondus (`dynamics.duration`), gamut, lampes injoignables, suppression des zones de synchro, alerte quand une autre app tient le flux, accessoires Hue, mémoire par morceau, sauvegarde du pont, raccourcis Siri.
- Aperçu des modes de dégradé : les tuiles et le mini-plan montrent toujours un fondu (la page Lampe, elle, montre le bon style).
- **Artefact Design de référence** (slug `85ac4275-4016-472f-9983-662555cda87a`) : maquette complète, modifiée par l'utilisateur, passer par `edit_version`.

## Points de vigilance

- **Debian 12 image cloud** : ne jamais installer `systemd-dev` depuis les backports ; toujours `apt-get --no-remove`.
- **Bluetooth** : l'adaptateur n'apparaît qu'après un redémarrage (la création de VM fait un `qm reboot`).
- **Agent QEMU** de la VM parfois arrêté (vu le 10/11) : `qm reboot 106` ou SSH ; l'état reste lisible via `curl http://192.168.50.183:8080/api/live`.
- **Console web Proxmox** : un collage peut être altéré. Préférer `qm guest exec`.
- **API de la TV** : fragile avec les rafales ; une connexion par fil (lecture vidéo/écriture d'un côté, `powerstate` de l'autre). Un appel lent ne doit jamais tout relancer.
- **Streaming via `openssl s_client`** : ne pas écrire deux messages d'affilée.
- **Tests** : toujours à taille iPhone réelle (390 px de large). Ne pas réutiliser un nom de classe CSS déjà pris.
- **Plusieurs sessions en parallèle** : avant de partir de GitHub, comparer avec les correctifs du projet.
- **Upload dans le projet** : `project_write` avec `local_path` exige d'avoir lu le fichier en entier ; pour de gros changements, préférer un `.patch`.
- **Suppressions** dans l'espace de travail : éviter `rm -rf` sur des chemins relatifs avec `*` (bloqué) ; créer un nouveau dossier à la place.
