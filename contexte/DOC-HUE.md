# Doc officielle Hue — ce qui concerne Lueur

*Relevé le 9/11/2026 dans la page « Hue CLIP API » (HTML complet fourni par l'utilisateur) et les guides Entertainment / System Performance. La section « Mesuré sur le vrai pont » vient de tests faits chez l'utilisateur.*

## Segments d'un ruban (`/resource/entertainment`, GET)
- `segments.configurable` (bool), `segments.max_segments` (int), `segments.segments[]` = `{start, length}`.
- Le code lit déjà `segments.max_segments` : c'est le bon nom.
- PUT `/resource/entertainment/{id}` n'accepte que `id`/`type` : **le découpage en segments ne se change ni par l'API ni dans l'app Hue** (fixé par le modèle).
- Aussi : `renderer`, `proxy`, `equalizer`, `max_streams`.

## Mesuré sur le vrai pont (9/11/2026, ruban Flux 17 m : 7 segments, max 10, `configurable: false`)
Le nombre de **canaux** que le pont donne au ruban dans une zone de divertissement dépend **uniquement de la position du ruban** dans la zone (pas des autres lampes, pas du `configuration_type`) :
- **1 point en (x 0, y 0,8, z 0)** : **7 canaux** (un par segment), même avec 6 spots dans la zone (13 canaux au total). C'est la seule position qui marche.
- 1 point ailleurs (centre, fond, côté, avant au bord y 1, avant au plafond z 0,8, avant en bas z −0,8) : **1 canal**.
- 2 points en diagonale ou le long du mur avant : 5 canaux ; le long du mur gauche : 2 ; du bas vers le haut : 3 ; diagonales en 3D : 4.
- Le `configuration_type` (music, 3dspace, other, screen) ne change rien.

→ Lueur place donc toujours un ruban à segments en `STRIP_SPOT = {x 0, y 0,8, z 0}` (création de zone depuis une pièce et « Choisir mes lampes »). L'ordre réel des segments vient de `members[].index`, et la place du ruban dans la pièce vient du plan Lueur, pas des positions du pont.

## Dégradé d'une lampe (`/resource/light/{id}`)
- `gradient.points` : 2 à 5 points (PUT), `gradient.points_capable`, `gradient.pixel_count`, `gradient.mode_values`.
- `gradient.mode` : `interpolated_palette` (défaut), `interpolated_palette_mirrored`, `random_pixelated`, `segmented_palette`.
- `content_configuration.order.order` : `forward` / `reversed` (sens du contenu pixelisé) ; `orientation` : `horizontal` / `vertical`.
- `effects_v2.action` : `effect` parmi prism, opal, glisten, sparkle, fire, candle, underwater, cosmos, sunbeam, enchant, no_effect ; `parameters` : `color`, `color_temperature`, `speed` (0-1). `effects` (v1) est déprécié.
- `dynamics.speed` (0-1) n'est valable qu'en statut `dynamic_palette`.
- À ne pas confondre : **5 points de couleur** pour un dégradé de scène (limite de l'API) et **7 segments** en synchro (découpage du pont).

## Scènes (`/resource/scene`, POST ; `/{id}`, PUT)
- `actions[].action` : on, dimming, color, color_temperature, **gradient** (points ≤ 5 + mode), effects_v2, dynamics.duration.
- `palette` : `color` (≤ 9, chacune avec `dimming`), `dimming` (tableau ≤ 1, obligatoire), `color_temperature` (obligatoire, peut être vide), `effects_v2` (≤ 3). `effects` déprécié.
- `speed` (0-1), `auto_dynamic` (bool).
- `recall.action` : `active`, `dynamic_palette`, `static` ; `recall.duration` (ms).
- La doc ne dit pas si `dynamic_palette` fait glisser le dégradé le long du ruban : seul un test sur le vrai matériel le dira.

## Zone de divertissement (`/resource/entertainment_configuration`, POST ; `/{id}`, PUT)
- POST : `metadata.name` (≤ 32 car.), `configuration_type` (screen, monitor, music, 3dspace, other), `locations.service_locations[]` avec `positions` (1 à 2 points, x/y/z entre −1 et 1), `equalization_factor` (≤ 1).
- Les **canaux** sont créés par le pont ; l'API ne permet pas de les choisir (« each channel groups segments of one or different light »).
- `stream_proxy.mode` : auto / manual ; `action` : start / stop (arrêter avant de modifier une zone en cours de flux).

## Débits (guides)
- Flux : 50-60 messages/s recommandés, 20 canaux max par message, fermeture après 10 s sans message.
- Côté Zigbee, le pont transmet à 25 Hz : effets visibles conseillés < 12,5 Hz.
- REST : ~10 commandes/s sur les lampes (100 ms d'écart), 1/s sur les groupes ; au-delà, mise en tampon puis erreur 503.
- Un pont ne joue qu'un flux de divertissement à la fois : Lueur ne pilote qu'une zone.
