# Lueur — audit du moteur et du design (10 novembre 2026)

*Complément de `AUDIT.md`. Même version : branche `V.1.2`, commit `1c3657d`.*

## Méthode

- **Moteur** : lecture complète de l'analyse audio, des 9 effets, des couches, de la session de streaming, de la synchro vidéo et de la boucle principale. Simulation sur des morceaux de synthèse (grosse caisse, caisse claire, charley, basse, nappe) à 44,1 kHz, passés dans `Analyzer` puis `Layered` avec 13 canaux.
- **Design** : interface lancée sur un faux pont (salon : ruban + 6 spots, chambre : 3 lampes, TV appairée en veille, morceau fictif). Captures de 9 écrans à 390 × 844 et de 6 écrans à 1440 × 900, plus une mesure automatique des zones tactiles et des tailles de texte.
- **Limites** : morceaux de synthèse et non de la vraie musique ; rien n'a été essayé sur le vrai pont, la vraie TV ni un vrai iPhone.

## Moteur

### Ce qui est solide (mesuré)

- **Détection des temps** : 100 % des grosses caisses trouvées à 120 et 128 BPM, avec un retard médian de 17 à 20 ms (une image).
- **Indépendante du volume** : résultats identiques de 0 à −50 dB. Baisser le volume de l'iPhone ne dégrade pas la synchro.
- **Charge** : 0,2 à 0,25 ms de calcul par image pour 13 canaux, sur un budget de 20 ms.
- **Découpage** : analyse, effets, couches, session, TV et vidéo sont bien séparés ; les réglages s'appliquent à chaud sans couper le flux.

### Points faibles

1. **Intensité Subtile sur les morceaux rapides.** L'écart minimal entre deux temps est de 0,40 s en Subtile. À partir de 150 BPM environ, c'est plus long que l'intervalle entre deux temps. En simulation à 150 et 174 BPM : une grosse caisse sur deux seulement est retenue, et environ la moitié des temps détectés tombent à contretemps (sur le charley). En Élevée, 100 % à ces tempos. Piste : quand un temps est refusé pour cause d'écart, préférer la grosse caisse suivante, ou caler l'écart sur le tempo mesuré.
2. **Pas de pause entre deux reconnexions du flux.** Quand un envoi échoue, `Session.send` ferme le flux et `acquire` relance aussitôt un `start` et un nouvel `openssl`, à chaque image. Si le pont refuse durablement, Lueur boucle et remplit le journal. Conséquence quand une autre app prend la zone : non testée.
3. **Le décalage des lumières n'existe que pour le Bluetooth.** `bt_offset_ms` ne s'applique que si l'enceinte Bluetooth joue. Avec des enceintes AirPlay écoutées en même temps, aucun réglage ne permet de retarder les lampes. Non vérifié qu'un décalage existe chez l'utilisateur.
4. **Synchro vidéo bridée.** 12 lectures par seconde par défaut, 25 au maximum, alors que la TV de l'utilisateur en a donné 68. S'y ajoute le lissage (0,14 s en Normale). Monter la valeur par défaut à 25 gagnerait environ 40 ms.
5. **Base de temps fixe.** Les effets supposent 20 ms par image. Un appel au pont dans la boucle (prise de zone, changement de zone, jusqu'à 5 s de délai) fige les animations et fait sauter des blocs audio. Rare, visible seulement au démarrage ou lors d'un changement.
6. **Streaming par `openssl s_client`.** Attente fixe de 0,25 s à la connexion, clé en argument, écritures qu'il ne faut pas enchaîner. Ça marche, mais c'est la pièce la plus fragile ; une vraie bibliothèque DTLS serait plus sûre à terme.
7. **Son Bluetooth.** La file jette des blocs de 20 ms quand elle est pleine et rien ne compense la dérive d'horloge entre AirPlay et l'enceinte : de petits clics sont possibles sur une longue écoute. Non testé.
8. **`cmd_run`** fait 250 lignes avec trois chemins (test, vidéo, musique) qui répètent chacun l'équilibre de luminosité et l'écriture de l'état. À découper avant d'ajouter un quatrième mode.

## Design

### Ce qui est solide (mesuré)

- Aucun débordement horizontal à 390 px, aucune erreur dans la console sur les 9 écrans.
- Tous les boutons ont un nom lisible par un lecteur d'écran ; la page est déclarée en français.
- Les rafraîchissements s'arrêtent quand l'onglet est caché.
- L'ensemble est cohérent : mêmes cartes, mêmes rayons, mêmes couleurs de texte partout ; la mise en page ordinateur tient bien.

### Points faibles

1. **Page Ambilight sur iPhone.** Le bloc des 13 pixels pousse la roue sous la barre d'onglets. Il faut faire défiler entre « toucher les pixels » et « choisir la couleur », et la luminosité est encore plus bas. Piste : dessin de la TV plus compact, ou roue réduite sur cet écran.
2. **Zones tactiles sous les 44 px recommandés sur iPhone** :
   - pixels de l'Ambilight : 31 × 31 ;
   - points du dégradé : 40 × 40 ;
   - icônes « Couleurs selon la position » : 40 × 30 ;
   - boutons segmentés (Fixe / Lente…, Linéaire / Reproduit…) : 33 à 35 de haut ;
   - curseurs : zone sensible de 30 de haut ;
   - « Modifier le plan » : 28 de haut.
3. **Icônes sans texte** pour « Couleurs selon la position » (→ ↓ ↻ ✛) : seul le résumé de la carte dit ce qui est choisi.
4. **Petits textes** : libellés à 11 px sur l'écran Synchro, « TV » à 9 px sur le mini-plan.
5. **Ancien nom** : « zone « Hue Sync » » apparaît deux fois dans l'interface (feuille des lampes et message de confirmation).
6. **Bouton central de l'écran Synchro** : un seul toucher arrête la synchro et la désactive aussi au démarrage de la VM, sans confirmation.
7. **Clavier et mouvement** : une seule règle `focus-visible`, aucune prise en compte de `prefers-reduced-motion`. Secondaire sur iPhone, utile sur ordinateur.
8. Déjà connu (handoff) : les tuiles et le mini-plan montrent toujours un fondu, quel que soit le style du dégradé.

## Ordre conseillé

1. Page Ambilight et zones tactiles (design 1 et 2) : c'est ce que l'utilisateur touche le plus.
2. Subtile sur les morceaux rapides (moteur 1), puisque c'est son réglage.
3. Pause entre reconnexions (moteur 2) et lectures vidéo à 25 par seconde (moteur 4) : deux petits changements.
4. Le reste au fil de l'eau.
