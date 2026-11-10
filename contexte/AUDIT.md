# Lueur — audit du 10 novembre 2026

*Version auditée : branche `V.1.2` du dépôt `J4y2s/Lueur`, commit `1c3657d` (10/11, 11 h 34), qui contient le correctif 23 (`tvPixHtml`). Les trois fichiers ont été extraits de `update-hue-sync.sh`. C'est exactement la version fournie dans `site/`.*

## Méthode et limites

- Vérifié : les 3 scripts livrés embarquent exactement les mêmes fichiers ; l'installeur compressé dans `create-hue-sync-vm.sh` est identique à `install-hue-airplay.sh` ; `bash -n`, `py_compile` et `node --check` passent.
- Lu en entier : le serveur web (réglages, TV, palettes, métadonnées, Bluetooth, routes), la partie TV et la boucle principale du moteur, les scripts d'installation.
- Lu par sondage seulement : les effets du moteur, le calcul des plans et des scènes, la plus grande partie de `index.html` (seul l'échappement HTML y a été contrôlé partout).
- Non fait : réappliquer les 23 correctifs du projet pour comparer avec GitHub ; tout essai sur le vrai pont ou la vraie TV.
- Deux constats ont été confirmés par un essai local (serveur lancé sans pont) : ils sont marqués « testé ».

## Bilan

Le code est sain pour un usage à la maison : pas d'injection de commande trouvée, les entrées sont bornées et filtrées (adresses MAC, IP, UUID, couleurs), l'interface échappe correctement tous les noms affichés, les identifiants du pont et de la TV ne sortent jamais par l'API. Les fils de la TV sont robustes aux coupures.

Les vrais risques sont ailleurs : la façon dont les sources sont stockées et livrées, l'absence de tests rejouables, et deux défauts du serveur web (écritures concurrentes des réglages, aucune protection contre une page web extérieure).

## Constats, par priorité

### 1. Les sources n'existent nulle part sous forme directement utilisable (important)

- Le dépôt GitHub ne contient que les 3 scripts générés (environ 390 Ko chacun, le même code en trois exemplaires). Ni `hue_music_sync.py`, ni `hue_sync_web.py`, ni les scripts `build*.sh`, ni les fichiers de service n'y sont.
- Dans le projet, la version de référence est « parties du 9/11 + 23 correctifs à appliquer dans l'ordre ». Chaque nouveau correctif allonge la chaîne ; une seule erreur d'ordre casse tout.
- Les petits fichiers (`install-head.sh`, services, `build*.sh`) ne vivent que dans `src/autres-fichiers.txt`.
- L'historique Git ne dit rien (« Add files via upload »), donc pas de retour arrière lisible.
- Restes à la racine de `V.1.2` : `hue sync web.py` (792 lignes, ancienne version, nom avec espaces) et un `index.html` de 95 Ko périmé (l'actuel fait 181 Ko).

**À faire** : mettre les vrais fichiers sources dans le dépôt (`src/`), avec les scripts de construction ; supprimer les deux restes ; dans le projet, remplacer parties + correctifs par les fichiers actuels.

*(Note : le dossier `site/` de ce zip répond en partie à ce constat : il contient les fichiers assemblés.)*

### 2. Réglages écrasés quand deux actions se croisent (bug réel)

`settings.json` est lu, modifié puis réécrit à 16 endroits du serveur, sans verrou, et toujours via le même fichier temporaire `settings.json.tmp`. Le serveur traite les requêtes en parallèle.

Cas le plus exposé : `/api/tv/ambilight` lit les réglages, parle à la TV (jusqu'à 4 s par appel), puis réécrit le tout. Un réglage changé pendant ce temps est perdu. Même risque avec la connexion Bluetooth (fil à part) et l'enregistrement d'un plan.

**À faire** : un seul verrou autour de « lire, modifier, écrire », et pour l'Ambilight, parler à la TV avant de relire les réglages.

### 3. Aucune protection contre une page web extérieure (à corriger, risque modéré)

Le serveur écoute sur toutes les interfaces, sans mot de passe, et tourne en root. C'est assumé (« réseau local uniquement »). Mais il accepte aussi les requêtes envoyées par n'importe quel site ouvert dans un navigateur de la maison : il ne regarde ni l'en-tête `Origin`, ni `Host`, ni le type de contenu. **Testé** : un `POST` en `text/plain` avec `Origin: http://evil.example` modifie les réglages.

Conséquences possibles : éteindre la synchro, oublier la TV, relancer un appairage, piloter les lampes. Pas de vol d'identifiants ni d'exécution de commande.

**À faire** : refuser les `POST` dont l'`Origin` ne correspond pas à `Host`, et exiger `Content-Type: application/json`. Une dizaine de lignes.

### 4. Aucun test rejouable

Le faux pont, la fausse TV et les scénarios Playwright sont décrits dans `NOTES-DEV-TESTS.md` mais « à refaire » à chaque session. Avec 6 300 lignes et 23 correctifs en deux jours, c'est le principal risque de régression.

**À faire** : ranger ces outils dans le dépôt (`tests/`) avec un script unique qui lance les contrôles de syntaxe et quelques scénarios (appairage TV, Ambilight en veille, envoi d'un dégradé).

### 5. Mise à jour sans filet

- `update-hue-sync.sh` écrase les fichiers puis redémarre les services, sans vérifier que le nouveau code démarre. Une sauvegarde est faite, mais le retour arrière est manuel.
- Lancé par `curl | bash` : si le téléchargement est coupé au milieu, bash exécute ce qu'il a reçu et peut écrire un fichier tronqué.
- Les sauvegardes `backup-AAAAMMJJ-HHMMSS` s'accumulent sans limite.
- `nqptp` et `shairport-sync` sont clonés sans version fixée : une installation neuve peut casser sur un changement en amont.

**À faire** : envelopper le script dans une fonction appelée à la dernière ligne ; écrire dans des fichiers temporaires, lancer `py_compile`, puis remplacer ; garder les 5 dernières sauvegardes ; fixer une étiquette de version pour les deux dépôts clonés.

### 6. Robustesse du serveur (mineur)

- **Testé** : un corps JSON qui n'est pas un objet (`[1]`) fait planter la requête ; la connexion est coupée sans réponse. Seules `ValueError`, `TypeError` et `OSError` sont attrapées dans `do_POST`, et rien dans `do_GET` hors `HueError`.
- `/api/pair` accepte n'importe quelle chaîne comme adresse de pont.
- Une image de palette est toujours enregistrée en `.jpg` et servie en `image/jpeg`, même si c'est un PNG ou un WebP.
- Le fil du flux d'événements (`LiveBridge._run`) avale toutes les erreurs sans rien noter au journal.

### 7. Moteur (mineur)

- Chaque écriture de `settings.json` fait tout reconfigurer et écrit « Réglages appliqués » au journal. Faire glisser la roue de l'Ambilight remplit donc le journal.
- La tuile Ambilight et le test de débit ouvrent leur propre connexion à la TV pendant que le moteur lui parle déjà. Vu la fragilité de l'API notée dans le handoff, c'est un point à surveiller si des coupures réapparaissent. Non observé, à vérifier chez l'utilisateur.
- La clé du pont est passée en argument à `openssl s_client` : elle est visible dans la liste des processus de la VM. Sans conséquence sur une VM dédiée.
- Un `settings.json` valide mais qui ne serait pas un objet ferait redémarrer le moteur en boucle.

### 8. Sécurité de la VM (à connaître)

- L'agent Bluetooth accepte tout appairage sans code. Acceptable tant que l'adaptateur n'est pas visible en permanence (aucun `discoverable on` dans le code).
- L'utilisateur `hue` a `sudo` sans mot de passe ; la connexion SSH par mot de passe est activée si l'hôte n'a pas de clé.
- Les deux services tournent en root sans aucun durcissement systemd.

### 9. Cohérence et documentation (cosmétique)

- L'ancien nom traîne : message final de l'installeur « AirPlay > « Hue Sync » », `HUE_AIRPLAY_NAME=Hue Sync` dans le service, descriptions systemd, « n'est pas installé ici ».
- Des commentaires parlent encore de LXC et de `dnf` alors que la cible est une VM Debian.
- Le `README.md` ne parle ni de la TV, ni de l'Ambilight, ni des couleurs par point (déjà noté dans le handoff).
- `index.html` : 131 Ko de JavaScript sur 1 314 lignes très longues ; `cmd_run` fait 250 lignes. Lisible par un outil, difficile à relire à la main.

## Ordre conseillé

1. Sources dans le dépôt et nettoyage du projet (constat 1).
2. Verrou sur les réglages et contrôle de l'origine (constats 2 et 3), plus l'attrape-tout de `do_POST`.
3. Outils de test dans le dépôt (constat 4).
4. Mise à jour plus sûre (constat 5).
5. Le reste au fil de l'eau.

Les vérifications matérielles déjà listées dans `HANDOFF.md` (ordre des pixels de l'Ambilight, dégradés à 2-4 points, synchro vidéo avec la « lampe » Ambilight allumée) restent à faire ; cet audit n'y change rien.
