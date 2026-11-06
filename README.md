# Lueur

**Tes lumières Philips Hue au rythme de ta musique, depuis Apple Music ou n'importe quelle app de ton iPhone.**

Lueur transforme une petite VM Proxmox en récepteur AirPlay 2. Tu envoies ta musique dessus depuis l'iPhone, elle analyse le son en temps réel et anime tes lampes Hue comme la synchro Spotify de l'app Hue, mais avec n'importe quelle source audio. Elle peut aussi jouer le son sur une enceinte Bluetooth branchée au serveur.

Tout se pilote depuis une interface web pensée pour le téléphone.

---

## Fonctionnalités

- **Récepteur AirPlay 2** : apparaît comme une enceinte dans le menu AirPlay de l'iPhone, compatible multi-room avec tes autres enceintes AirPlay.
- **Synchro musique → lumières** en temps réel : détection des temps, des basses et des drops, flux à ~50 images/s via l'API Entertainment de Hue.
- **Palettes de couleurs** prêtes à l'emploi, ou **créées à partir d'une photo** : les couleurs sont extraites automatiquement et tu peux déplacer les pastilles sur l'image.
- **4 niveaux d'intensité** (Subtile, Modérée, Élevée, Intense) et **2 effets** (Pulsation, Spectre graves → aigus de gauche à droite).
- **Choix des lampes** : une zone de divertissement existante, ou tes propres lampes, pièce par pièce ou une par une (10 maximum).
- **Enceinte Bluetooth** : recherche, appairage et reconnexion automatique depuis l'interface, avec un réglage de décalage pour caler les lumières sur le son.
- **Recherche automatique du pont Hue** sur le réseau.
- **Pause automatique** : après quelques secondes de silence, les lampes sont rendues à l'app Hue.
- **Réglages appliqués à chaud**, sans couper la musique.

## Prérequis

| | |
|---|---|
| Serveur | Proxmox VE 8 (hôte avec accès Internet) |
| Ressources | 2 cœurs, 1 Go de RAM, 8 Go de disque |
| Éclairage | Pont Hue v2 (carré) et lampes **couleur** |
| Source | iPhone, iPad ou Mac (AirPlay 2) |
| Bluetooth *(facultatif)* | Adaptateur Bluetooth USB sur l'hôte (intégré ou dongle) |

L'iPhone, le pont Hue et la VM doivent être sur le **même réseau** (même VLAN), sinon l'enceinte AirPlay n'apparaît pas.

## Installation

Dans le shell de l'hôte Proxmox, en root :

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/J4y2s/lueur/V.1/create-hue-sync-vm.sh)"
```

> Utilise bien cette forme et non `curl … | bash` : le script doit pouvoir te poser une question si tu as plusieurs adaptateurs Bluetooth.

Le script :

1. télécharge l'image officielle **Debian 12** (version cloud « generic », sans interface graphique) et vérifie sa somme de contrôle ;
2. crée la VM et lui attribue l'adaptateur Bluetooth détecté sur l'hôte ;
3. installe tout au premier démarrage (AirPlay 2, synchro, interface web, Bluetooth) ;
4. affiche l'adresse de l'interface et le mot de passe de la VM.

Compte **15 à 25 minutes**, l'essentiel étant la compilation d'AirPlay 2.

### Options

À placer devant la commande, par exemple `VLAN=20 VMID=150 bash -c "$(curl …)"`.

| Variable | Défaut | Rôle |
|---|---|---|
| `VMID` | prochain libre | Numéro de la VM |
| `NAME` | `hue-sync` | Nom de la VM |
| `STORAGE` | `local-lvm` ou `local-zfs` | Stockage du disque |
| `BRIDGE` | `vmbr0` | Pont réseau |
| `VLAN` | *(aucun)* | Tag VLAN |
| `MEMORY` | `1024` | RAM en Mo |
| `CORES` | `2` | Cœurs |
| `DISK` | `8G` | Taille du disque |
| `BT_USB` | détection auto | Adaptateur Bluetooth (`vendor:product`), ou `none` |

## Premiers pas

1. Ouvre l'interface : `http://<ip-de-la-vm>:8080`.
   Astuce : dans Safari, *Partager → Sur l'écran d'accueil* pour l'avoir comme une app.
2. **Appaire le pont** : il est trouvé automatiquement, appuie sur son bouton rond quand l'interface te le demande.
3. **Choisis tes lampes** : une zone existante, ou *Choisir mes lampes…*.
4. Sur l'iPhone, lance ta musique, puis **AirPlay → « Hue Sync »**.

### Deux façons d'écouter

- **Avec une enceinte Bluetooth** branchée au serveur : connecte-la dans la section *Enceinte Bluetooth*, puis envoie la musique uniquement à « Hue Sync ». Si les lumières sont en avance sur le son, augmente le *décalage des lumières*.
- **Avec des enceintes AirPlay** (HomePod, Sonos, etc.) : dans le menu AirPlay, coche **tes enceintes et « Hue Sync »**. AirPlay 2 synchronise tout le monde.

> Une enceinte Bluetooth connectée directement à l'iPhone ne peut pas être combinée avec AirPlay : c'est une limite d'iOS.

## Dépannage

| Problème | Piste |
|---|---|
| « Hue Sync » n'apparaît pas dans AirPlay | iPhone et VM sur le même réseau ou VLAN ? Point vert dans l'interface ? |
| Pont introuvable | Même réseau que la VM ? Sinon, saisis son adresse IP manuellement. |
| Aucun adaptateur Bluetooth | Vérifie *VM → Matériel → Périphérique USB* dans Proxmox. L'adaptateur ne peut servir qu'à une VM à la fois. |
| Lumières décalées par rapport au son | Ajuste le *décalage des lumières* (Bluetooth), ou baisse l'intensité. |
| Le volume « Hue Sync » est à zéro | Remonte-le : à volume nul, plus de signal à analyser. |

Journaux, depuis la VM :

```bash
journalctl -u hue-airplay -f      # synchro + AirPlay
journalctl -u hue-sync-web -f     # interface web
sudo less /var/log/hue-install.log   # installation
```

## Comment ça marche

```
iPhone ──AirPlay 2──▶ shairport-sync ──audio──▶ analyse (temps, basses, drops)
                                                   │            │
                                                   ▼            ▼
                                        Pont Hue (DTLS)   Enceinte Bluetooth (BlueALSA)
                                                   ▲
                                 Interface web ────┘ (réglages à chaud)
```

## Limites

- L'analyse se fait **en direct, à l'écoute**. Contrairement à l'intégration Spotify de Hue, Lueur ne connaît pas la structure du morceau à l'avance. Le résultat est très proche sur la musique rythmée, et un peu moins « chorégraphié » sur les morceaux calmes.
- 10 lampes maximum par zone (limite du pont Hue).
- L'interface web n'a pas de mot de passe : garde-la sur ton réseau local, ou mets-la derrière un reverse proxy avec authentification.

## Crédits

- [shairport-sync](https://github.com/mikebrady/shairport-sync) et [nqptp](https://github.com/mikebrady/nqptp) de Mike Brady, pour la réception AirPlay 2
- [BlueALSA](https://github.com/arkq/bluez-alsa), pour la sortie Bluetooth
- [Debian](https://www.debian.org/), pour l'image cloud

---

*Lueur est un projet personnel, sans lien avec Signify ni Philips. « Philips Hue » est une marque de Signify. AirPlay est une marque d'Apple Inc.*
