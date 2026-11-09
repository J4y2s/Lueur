#!/usr/bin/env bash
# =============================================================================
# Installation du récepteur AirPlay 2 "Hue Sync" dans un LXC Debian 12
#   - nqptp + shairport-sync (compilés avec AirPlay 2)
#   - script d'analyse musicale -> API Entertainment Philips Hue
#   - service systemd hue-airplay (démarrage automatique)
# Usage (en root dans le LXC) :  bash install-hue-airplay.sh
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Lance ce script en root."; exit 1; }
. /etc/os-release
echo "==> Système : $PRETTY_NAME"

echo "==> Paquets"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends --no-remove \
  build-essential git autoconf automake libtool pkg-config ca-certificates \
  libpopt-dev libconfig-dev libasound2-dev avahi-daemon avahi-utils libavahi-client-dev \
  libssl-dev libsoxr-dev libplist-dev libplist-utils libsodium-dev libavutil-dev libavcodec-dev \
  libavformat-dev uuid-dev libgcrypt-dev xxd \
  python3 python3-numpy python3-pil openssl \
  bluez bluez-tools bluez-alsa-utils libasound2-plugin-bluez alsa-utils rfkill usbutils
# systemd.pc (utile à la compilation d'AirPlay) : déjà fourni par "systemd" sur Debian 12.
# Ne JAMAIS installer systemd-dev depuis les backports : APT retirerait systemd et le noyau
# (la VM tombe alors sur "grub>" au redémarrage suivant).
if ! pkg-config --exists systemd 2>/dev/null; then
  apt-get install -y --no-install-recommends --no-remove -t "${VERSION_CODENAME}" systemd-dev 2>/dev/null || true
fi

echo "==> Firmwares Bluetooth (Intel, Realtek, Atheros...)"
if [ ! -f /etc/apt/sources.list.d/hue-firmware.sources ]; then
  cat > /etc/apt/sources.list.d/hue-firmware.sources <<SRC
Types: deb
URIs: http://deb.debian.org/debian
Suites: ${VERSION_CODENAME} ${VERSION_CODENAME}-updates
Components: non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SRC
  apt-get update || true
fi
apt-get install -y --no-install-recommends --no-remove firmware-realtek firmware-iwlwifi firmware-atheros \
  firmware-misc-nonfree 2>/dev/null || echo "(firmwares non installés, ce n'est pas bloquant)"

# Avahi échoue souvent dans un LXC non privilégié à cause de rlimit-nproc
sed -i 's/^rlimit-nproc=/#rlimit-nproc=/' /etc/avahi/avahi-daemon.conf || true
systemctl enable --now avahi-daemon
systemctl restart avahi-daemon

echo "==> Chargeur de démarrage (GRUB)"
# Les images cloud Debian visent un autre nom de disque que celui de la VM :
# après une mise à jour de GRUB, la VM ne redémarre plus (invite grub>).
# On réinstalle GRUB sur le vrai disque et on le mémorise pour les mises à jour futures.
if [ ! -d /sys/firmware/efi ] && command -v grub-install >/dev/null; then
  # Démarrage BIOS : il faut les fichiers GRUB "PC" pour réécrire le secteur de démarrage
  # (sinon grub-install vise l'EFI et le vieux secteur BIOS reste -> invite grub>).
  apt-get install -y --no-install-recommends --no-remove grub-pc-bin >/dev/null 2>&1 || true
  ROOTDEV=$(findmnt -no SOURCE /)
  DISK=$(lsblk -no PKNAME "$ROOTDEV" 2>/dev/null | head -n1)
  if [ -n "$DISK" ] && [ -b "/dev/$DISK" ] && [ -d /usr/lib/grub/i386-pc ]; then
    echo "grub-pc grub-pc/install_devices multiselect /dev/$DISK" | debconf-set-selections
    grub-install --target=i386-pc "/dev/$DISK" && echo "    GRUB (BIOS) réinstallé sur /dev/$DISK"
  fi
fi
mkdir -p /etc/default/grub.d
printf 'GRUB_TIMEOUT=3\nGRUB_RECORDFAIL_TIMEOUT=3\n' > /etc/default/grub.d/99-hue-sync.cfg
update-grub 2>/dev/null || true

BUILD=/usr/local/src/hue-airplay
mkdir -p "$BUILD"

echo "==> nqptp (horloge AirPlay 2)"
if [ ! -d "$BUILD/nqptp" ]; then
  git clone --depth 1 https://github.com/mikebrady/nqptp.git "$BUILD/nqptp"
fi
cd "$BUILD/nqptp"
autoreconf -fi
./configure --with-systemd-startup
make -j"$(nproc)"
make install
systemctl daemon-reload
systemctl enable --now nqptp

echo "==> shairport-sync (AirPlay 2, sortie stdout)"
if [ ! -d "$BUILD/shairport-sync" ]; then
  git clone --depth 1 https://github.com/mikebrady/shairport-sync.git "$BUILD/shairport-sync"
fi
cd "$BUILD/shairport-sync"
autoreconf -fi
./configure --sysconfdir=/etc --with-alsa --with-stdout --with-pipe --with-soxr \
            --with-avahi --with-ssl=openssl --with-airplay-2 --with-metadata
make -j"$(nproc)"
make install
# On n'utilise pas le service shairport-sync standard : c'est hue-airplay qui le lance
systemctl disable --now shairport-sync 2>/dev/null || true

echo "==> Fichiers Hue Sync"
mkdir -p /opt/hue-music-sync /etc/hue-music-sync
chmod 700 /etc/hue-music-sync
cat > /opt/hue-music-sync/hue_music_sync.py <<'HUE_FILE_EOF'
#!/usr/bin/env python3
"""
hue_music_sync.py — Synchro lumières/musique façon "Hue Sync Desktop".

Capte le son qui sort de l'ordinateur (Apple Music, navigateur, n'importe quelle app),
détecte le rythme en temps réel et pilote une zone de divertissement Hue via
l'API Entertainment (flux DTLS ~50 Hz).

Dépendances :
  - Python 3.9+ et numpy
  - openssl (pour le flux DTLS vers le pont)
  - Linux : parec (paquet pulseaudio-utils, fonctionne avec PipeWire)
    Autres OS : pip install sounddevice (+ un périphérique de bouclage :
    "Mixage stéréo" sous Windows, BlackHole sous macOS)

Utilisation :
  1. python3 hue_music_sync.py pair            (appuie sur le bouton du pont)
  2. python3 hue_music_sync.py list            (liste les zones de divertissement)
  3. python3 hue_music_sync.py run --area "Salon" --palette sunset --intensity high

Mode serveur AirPlay (LXC) :
  shairport-sync | python3 hue_music_sync.py run --source stdin --channels 2
  La zone est libérée après --idle-release secondes de silence (l'app Hue
  reprend la main), puis reprise automatiquement dès que la musique revient.
"""

import argparse
import collections
import json
import os
import queue
import shutil
import signal
import ssl
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

import numpy as np

CONFIG_PATH = os.environ.get("HUE_SYNC_CONFIG",
                             os.path.expanduser("~/.config/hue-music-sync/config.json"))


class HueError(Exception):
    pass


def log(msg):
    print(time.strftime("[%H:%M:%S] ") + msg, flush=True)

SAMPLE_RATE = 48000
HOP = 960            # 960 échantillons à 48 kHz = 20 ms -> 50 images/s
FFT_SIZE = 2048

# ---------------------------------------------------------------------------
# Palettes (même esprit que les palettes de Hue Sync)
# ---------------------------------------------------------------------------
PALETTES = {
    "sunset":  ["#ff2a00", "#ff7b00", "#ff0055", "#ffb300", "#c4005a"],
    "ocean":   ["#0040ff", "#00b4ff", "#00ffd5", "#2a00ff", "#00ff88"],
    "neon":    ["#ff00ff", "#00ffff", "#ff0080", "#7b00ff", "#00ff40"],
    "fire":    ["#ff0000", "#ff4000", "#ff8000", "#ff1a00", "#ffbf00"],
    "forest":  ["#00ff40", "#80ff00", "#00c060", "#ffe000", "#00ff9d"],
    "party":   ["#ff0000", "#00ff00", "#0000ff", "#ffff00", "#ff00ff", "#00ffff"],
    "ice":     ["#ffffff", "#9fd8ff", "#4da6ff", "#c8f0ff", "#0066ff"],
}

# Niveaux d'intensité (comme Hue Sync : subtil / modéré / élevé / intense)
INTENSITY = {
    # base      : luminosité entre deux temps     beat : force du flash sur un temps
    # tau       : durée du flash (s)              energy : part de la dynamique du morceau
    # every     : changement de couleur tous les N temps    fade : fondu de couleur (s)
    # pattern   : "all" toutes ensemble, "alt" lampes en alternance, "chase" chenillard
    # strobe    : flash blanc sur les drops        beat_k / min_beat : sensibilité de détection
    "subtle":   dict(base=0.30, beat=0.22, tau=0.55, energy=0.35, every=4, fade=1.60,
                     pattern="all", strobe=False, beat_k=2.0, min_beat=0.40, source="full"),
    "moderate": dict(base=0.22, beat=0.70, tau=0.28, energy=0.20, every=2, fade=0.45,
                     pattern="all", strobe=False, beat_k=1.7, min_beat=0.28, source="full"),
    "high":     dict(base=0.07, beat=0.93, tau=0.17, energy=0.12, every=1, fade=0.12,
                     pattern="alt", strobe=False, beat_k=1.5, min_beat=0.26, source="full"),
    "intense":  dict(base=0.00, beat=1.00, tau=0.10, energy=0.05, every=1, fade=0.00,
                     pattern="chase", strobe=True, beat_k=1.35, min_beat=0.22, source="full"),
}

# Réglages avancés modifiables depuis l'interface (type, min, max ou choix possibles)
FX_SCHEMA = {
    "base": ("float", 0.0, 1.0), "beat": ("float", 0.0, 1.0), "tau": ("float", 0.04, 1.5),
    "energy": ("float", 0.0, 1.0), "every": ("int", 1, 16), "fade": ("float", 0.0, 4.0),
    "pattern": ("choice", ("all", "alt", "chase", "wave")), "strobe": ("bool",),
    "beat_k": ("float", 0.8, 3.5), "min_beat": ("float", 0.12, 1.0),
    "source": ("choice", ("full", "kick", "snare")),
}


def clean_fx(d):
    """Ne garde que les réglages avancés valides, bornés."""
    out = {}
    for k, v in (d or {}).items() if isinstance(d, dict) else []:
        spec = FX_SCHEMA.get(k)
        if not spec:
            continue
        try:
            if spec[0] == "float":
                out[k] = round(max(spec[1], min(spec[2], float(v))), 3)
            elif spec[0] == "int":
                out[k] = int(max(spec[1], min(spec[2], int(v))))
            elif spec[0] == "bool":
                out[k] = bool(v)
            elif spec[0] == "choice" and v in spec[1]:
                out[k] = v
        except (TypeError, ValueError):
            pass
    return out


def fx_params(intensity, overrides):
    params = dict(INTENSITY.get(intensity, INTENSITY["high"]))
    params.update(clean_fx(overrides))
    return params


def hex_to_rgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)])


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
def load_config():
    if not os.path.exists(CONFIG_PATH):
        sys.exit("Aucune configuration. Lance d'abord : python3 hue_music_sync.py pair")
    with open(CONFIG_PATH) as f:
        return json.load(f)


def load_config_or_none():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def save_config(cfg):
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    with open(CONFIG_PATH, "w") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(CONFIG_PATH, 0o600)


# ---------------------------------------------------------------------------
# API REST du pont (HTTPS, certificat auto-signé du pont sur le réseau local)
# ---------------------------------------------------------------------------
_SSL_CTX = ssl.create_default_context()
_SSL_CTX.check_hostname = False
_SSL_CTX.verify_mode = ssl.CERT_NONE  # le pont Hue utilise un certificat auto-signé


def bridge_request(ip, method, path, key=None, body=None, want_headers=False):
    url = f"https://{ip}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if key:
        req.add_header("hue-application-key", key)
    try:
        with urllib.request.urlopen(req, context=_SSL_CTX, timeout=5) as r:
            payload = json.loads(r.read() or b"null")
            return (payload, r.headers) if want_headers else payload
    except urllib.error.HTTPError as e:
        raise HueError(f"Erreur pont ({e.code}) sur {path} : {e.read().decode(errors='ignore')}")
    except (urllib.error.URLError, OSError) as e:
        raise HueError(f"Impossible de joindre le pont {ip} : {getattr(e, 'reason', e)}")


AVAHI_BROWSE = os.environ.get("HUE_SYNC_AVAHI_BROWSE", "avahi-browse")
DISCOVERY_URL = os.environ.get("HUE_SYNC_DISCOVERY_URL", "https://discovery.meethue.com")


def _describe_bridge(ip):
    """Lit le nom et le modèle du pont (accessible sans authentification)."""
    try:
        req = urllib.request.Request(f"https://{ip}/api/0/config")
        with urllib.request.urlopen(req, context=_SSL_CTX, timeout=3) as r:
            c = json.loads(r.read())
        if isinstance(c, dict) and (c.get("bridgeid") or c.get("modelid")):
            return {"name": c.get("name") or "Pont Hue", "id": (c.get("bridgeid") or "").lower(),
                    "model": c.get("modelid", "")}
    except Exception:
        pass
    return None


def discover_bridges():
    """Cherche les ponts Hue : d'abord sur le réseau local (mDNS, comme l'app Hue),
    puis via le service de découverte en ligne de Philips. Renvoie [{ip, name, id, model}]."""
    candidates = []
    if shutil.which(AVAHI_BROWSE) or os.path.exists(AVAHI_BROWSE):
        try:
            r = subprocess.run([AVAHI_BROWSE, "-rpt", "_hue._tcp"], capture_output=True,
                               text=True, timeout=8)
            for line in r.stdout.splitlines():
                f = line.split(";")
                if len(f) >= 8 and f[0] == "=" and f[2] == "IPv4":
                    candidates.append(f[7])
        except (OSError, subprocess.TimeoutExpired):
            pass
    try:
        with urllib.request.urlopen(DISCOVERY_URL, context=_SSL_CTX, timeout=5) as r:
            for b in json.loads(r.read()):
                ip = b.get("internalipaddress")
                if ip:
                    candidates.append(f"{ip}:{b['port']}" if b.get("port") not in (None, 443) else ip)
    except Exception:
        pass
    found, seen = [], set()
    for ip in candidates:
        if ip in seen:
            continue
        seen.add(ip)
        info = _describe_bridge(ip)
        if info and not any(x["id"] and x["id"] == info["id"] for x in found):
            found.append({"ip": ip, **info})
    return found


def discover_bridge():
    found = discover_bridges()
    return found[0]["ip"] if found else None


def pair_bridge(ip=None, timeout=30):
    """Appaire avec le pont (bouton à presser). Renvoie la config enregistrée."""
    ip = ip or discover_bridge()
    if not ip:
        raise HueError("Pont introuvable. Indique son adresse IP.")
    body = {"devicetype": "hue_music_sync#airplay", "generateclientkey": True}
    deadline = time.time() + timeout
    while time.time() < deadline:
        res = bridge_request(ip, "POST", "/api", body=body)
        item = res[0] if isinstance(res, list) and res else {}
        if "success" in item:
            username = item["success"]["username"]
            clientkey = item["success"]["clientkey"]
            _, headers = bridge_request(ip, "GET", "/auth/v1", key=username, want_headers=True)
            app_id = headers.get("hue-application-id") or username
            cfg = {"bridge": ip, "username": username, "clientkey": clientkey, "app_id": app_id}
            save_config(cfg)
            return cfg
        err = item.get("error", {})
        if err.get("type") != 101:  # 101 = bouton pas encore pressé
            raise HueError(f"Erreur d'appairage : {err.get('description', err)}")
        time.sleep(2)
    raise HueError("Délai dépassé : le bouton du pont n'a pas été pressé.")


def cmd_pair(args):
    print("Appuie sur le gros bouton du pont Hue (tu as 30 secondes)...")
    cfg = pair_bridge(args.bridge)
    print(f"Appairage réussi avec {cfg['bridge']}. Configuration : {CONFIG_PATH}")


def get_areas(cfg):
    res = bridge_request(cfg["bridge"], "GET",
                         "/clip/v2/resource/entertainment_configuration", key=cfg["username"])
    return res.get("data", [])


def bridge_get(cfg, resource):
    res = bridge_request(cfg["bridge"], "GET", f"/clip/v2/resource/{resource}", key=cfg["username"])
    return res.get("data", []) if isinstance(res, dict) else []


MAX_AREA_LIGHTS = 10
CUSTOM_AREA_NAME = "Hue Sync"


def light_inventory(cfg):
    """Pièces et zones du pont, avec leurs lampes compatibles divertissement (couleur)."""
    ents = [e for e in bridge_get(cfg, "entertainment") if e.get("renderer")]
    by_device = {}
    for e in ents:
        by_device.setdefault(e.get("owner", {}).get("rid"), []).append(e["id"])
    devices = {d["id"]: d for d in bridge_get(cfg, "device")}
    light_owner = {l["id"]: l.get("owner", {}).get("rid") for l in bridge_get(cfg, "light")}

    def light_entry(dev_id):
        d = devices.get(dev_id, {})
        md = d.get("metadata", {})
        return [{"id": eid, "name": md.get("name", "Lampe"), "archetype": md.get("archetype", "")}
                for eid in by_device.get(dev_id, [])]

    groups, seen = [], set()
    for kind in ("room", "zone"):
        for g in bridge_get(cfg, kind):
            lights = []
            for c in g.get("children", []):
                dev = c["rid"] if c.get("rtype") == "device" else light_owner.get(c["rid"])
                for le in light_entry(dev):
                    if le["id"] not in {x["id"] for x in lights}:
                        lights.append(le)
            if lights:
                groups.append({"id": g["id"], "kind": kind, "lights": lights,
                               "name": g.get("metadata", {}).get("name", "Pièce")})
                seen.update(x["id"] for x in lights)
    others = [le for dev in by_device for le in light_entry(dev) if le["id"] not in seen]
    if others:
        groups.append({"id": "others", "kind": "other", "name": "Sans pièce", "lights": others})
    return groups


def save_custom_area(cfg, ent_ids, area_id=None):
    """Crée (ou met à jour) la zone de divertissement « Hue Sync » avec les lampes choisies.
    Les lampes sont réparties de gauche à droite dans l'ordre de sélection."""
    ent_ids = list(dict.fromkeys(ent_ids))[:MAX_AREA_LIGHTS]
    if not ent_ids:
        raise HueError("Choisis au moins une lampe.")
    n = len(ent_ids)
    locations = {"service_locations": [
        {"service": {"rid": eid, "rtype": "entertainment"},
         "positions": [{"x": round(-1 + 2 * i / (n - 1), 3) if n > 1 else 0.0, "y": 0.8, "z": 0.0}]}
        for i, eid in enumerate(ent_ids)]}
    existing = {a["id"]: a for a in get_areas(cfg)}
    if not area_id or area_id not in existing:
        area_id = next((a["id"] for a in existing.values()
                        if a.get("metadata", {}).get("name") == CUSTOM_AREA_NAME), None)
    path = "/clip/v2/resource/entertainment_configuration"
    if area_id:
        if existing[area_id].get("status") == "active":
            bridge_request(cfg["bridge"], "PUT", f"{path}/{area_id}", key=cfg["username"],
                           body={"action": "stop"})
        bridge_request(cfg["bridge"], "PUT", f"{path}/{area_id}", key=cfg["username"],
                       body={"metadata": {"name": CUSTOM_AREA_NAME}, "locations": locations})
        return area_id
    res = bridge_request(cfg["bridge"], "POST", path, key=cfg["username"], body={
        "type": "entertainment_configuration", "metadata": {"name": CUSTOM_AREA_NAME},
        "configuration_type": "music", "locations": locations})
    errs = res.get("errors") if isinstance(res, dict) else None
    if errs:
        raise HueError("Le pont a refusé la zone : " + "; ".join(e.get("description", "?") for e in errs))
    try:
        return res["data"][0]["rid"]
    except (KeyError, IndexError, TypeError):
        raise HueError("Réponse inattendue du pont lors de la création de la zone.")


def area_lights(area):
    """Identifiants des services de divertissement d'une zone (pour pré-cocher la sélection)."""
    locs = area.get("locations", {}).get("service_locations", [])
    return [l.get("service", {}).get("rid") for l in locs if l.get("service")]


# ---------------------------------------------------------------------------
# Palettes personnalisées (créées depuis une image dans l'interface web)
# ---------------------------------------------------------------------------
def custom_palettes(conf_dir):
    try:
        with open(os.path.join(conf_dir, "palettes.json")) as f:
            data = json.load(f)
        return [p for p in data.get("custom", []) if isinstance(p.get("colors"), list) and p["colors"]]
    except (OSError, ValueError, AttributeError):
        return []


COVER_FILE = "cover.json"


def cover_palette(conf_dir):
    """Couleurs extraites de la pochette du morceau AirPlay en cours (écrites par l'interface web)."""
    try:
        with open(os.path.join(conf_dir, COVER_FILE)) as f:
            cols = json.load(f).get("colors") or []
        return cols if len(cols) >= 2 else None
    except (OSError, ValueError, AttributeError, TypeError):
        return None


def resolve_palette(name, conf_dir):
    if name in PALETTES:
        return PALETTES[name]
    if name == "cover":
        return (cover_palette(conf_dir) if conf_dir else None) or PALETTES["sunset"]
    for p in custom_palettes(conf_dir) if conf_dir else []:
        if p.get("id") == name:
            return p["colors"]
    return None


def cmd_list(args):
    cfg = load_config()
    areas = get_areas(cfg)
    if not areas:
        print("Aucune zone de divertissement. Crée-en une dans l'app Hue :")
        print("Paramètres > Zones de divertissement.")
        return
    for a in areas:
        name = a.get("metadata", {}).get("name", "?")
        print(f"- {name}  (id {a['id']}, {len(a.get('channels', []))} canaux, état {a.get('status')})")


# ---------------------------------------------------------------------------
# Flux DTLS vers le pont (via openssl s_client, aucun module Python requis)
# ---------------------------------------------------------------------------
class HueStream:
    def __init__(self, ip, app_id, clientkey, area_id, port=2100):
        if not shutil.which("openssl"):
            sys.exit("openssl est requis (sudo dnf install openssl).")
        self.area_id = area_id.encode("ascii")
        self.seq = 0
        self.errors = collections.deque(maxlen=20)
        cmd = ["openssl", "s_client", "-quiet", "-dtls1_2",
               "-cipher", "PSK-AES128-GCM-SHA256",
               "-psk_identity", app_id, "-psk", clientkey,
               "-connect", f"{ip.rsplit(':', 1)[0] if ip.count(':') == 1 else ip}:{port}"]
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                     bufsize=0)
        threading.Thread(target=self._drain, daemon=True).start()
        time.sleep(0.25)  # openssl garde les images reçues en attente pendant le handshake
        if self.proc.poll() is not None:
            raise HueError("Échec de la connexion DTLS au pont :\n" + "".join(self.errors))

    def _drain(self):
        for line in iter(self.proc.stderr.readline, b""):
            self.errors.append(line.decode(errors="ignore"))

    def send(self, colors):
        """colors : liste de (channel_id, r, g, b) avec r,g,b dans [0, 1]."""
        msg = bytearray(b"HueStream")
        msg += bytes([0x02, 0x00, self.seq & 0xFF, 0x00, 0x00, 0x00, 0x00])  # v2.0, RVB
        msg += self.area_id
        for ch, r, g, b in colors[:20]:
            msg += struct.pack(">BHHH", ch,
                               int(max(0, min(1, r)) * 65535),
                               int(max(0, min(1, g)) * 65535),
                               int(max(0, min(1, b)) * 65535))
        self.seq += 1
        if self.proc.poll() is not None:
            return False
        try:
            self.proc.stdin.write(bytes(msg))
            return True
        except (BrokenPipeError, OSError):
            return False

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        self.proc.terminate()


class DryRunStream:
    """Affiche les couleurs dans le terminal au lieu de les envoyer au pont."""

    def __init__(self, *_):
        self.frame = 0

    def send(self, colors):
        self.frame += 1
        if self.frame % 5:
            return True
        line = ""
        for _, r, g, b in colors:
            line += f"\x1b[48;2;{int(r*255)};{int(g*255)};{int(b*255)}m      \x1b[0m "
        print("\r" + line, end="", flush=True)
        return True

    def close(self):
        print()


# ---------------------------------------------------------------------------
# Captation audio
# ---------------------------------------------------------------------------
class AudioSource:
    """Lit l'audio dans un thread et le découpe en blocs de 20 ms (mono, float)."""

    def __init__(self, source, channels=1):
        self.proc = None
        self.sd_stream = None
        self.stdin = None
        self.channels = channels
        self.q = queue.Queue(maxsize=100)
        self.eof = False
        self.raw_sink = None
        if source == "stdin":
            self.stdin = sys.stdin.buffer
        elif shutil.which("parec"):
            device = {"monitor": "@DEFAULT_MONITOR@", "mic": "@DEFAULT_SOURCE@"}.get(source, source)
            self.channels = 1
            self.proc = subprocess.Popen(
                ["parec", f"--device={device}", "--format=s16le", f"--rate={SAMPLE_RATE}",
                 "--channels=1", "--latency-msec=20"],
                stdout=subprocess.PIPE, bufsize=0)
        else:
            try:
                import sounddevice as sd
            except Exception:
                sys.exit("Pas de parec ni de sounddevice. Linux : sudo dnf install pulseaudio-utils ; "
                         "autres : pip install sounddevice")
            dev = None if source in ("monitor", "mic") else source
            self.channels = 1
            self.sd_stream = sd.RawInputStream(samplerate=SAMPLE_RATE, blocksize=HOP,
                                               channels=1, dtype="int16", device=dev)
            self.sd_stream.start()
        threading.Thread(target=self._reader, daemon=True).start()

    def _read_block(self):
        n = HOP * 2 * self.channels
        if self.sd_stream is not None:
            data, _ = self.sd_stream.read(HOP)
            return bytes(data)
        stream = self.stdin if self.stdin is not None else self.proc.stdout
        data = b""
        while len(data) < n:
            chunk = stream.read(n - len(data))
            if not chunk:
                return None
            data += chunk
        return data

    def _reader(self):
        while True:
            data = self._read_block()
            if data is None:
                self.eof = True
                return
            if self.raw_sink is not None:
                self.raw_sink(data)          # copie du son brut vers l'enceinte Bluetooth
            s = np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768.0
            if self.channels > 1:
                s = s.reshape(-1, self.channels).mean(axis=1)   # stéréo -> mono
            if self.q.full():
                try:
                    self.q.get_nowait()
                except queue.Empty:
                    pass
            self.q.put(s)

    def get(self, timeout):
        """Renvoie le prochain bloc, ou None si rien n'arrive (pause, silence AirPlay)."""
        try:
            s = self.q.get(timeout=timeout)
        except queue.Empty:
            return None
        while self.q.qsize() > 3:      # en retard : on saute pour rester en temps réel
            s = self.q.get_nowait()
        return s

    def close(self):
        if self.proc:
            self.proc.terminate()
        if self.sd_stream:
            self.sd_stream.stop()


# ---------------------------------------------------------------------------
# Analyse musicale : bandes de fréquences + détection des temps
# ---------------------------------------------------------------------------
class Analyzer:
    BANDS = {"bass": (30, 150), "mid": (150, 2000), "high": (2000, 12000)}

    SOURCES = {"full": (30, 4000), "kick": (30, 160), "snare": (160, 6000)}

    def __init__(self, beat_k, min_beat, source="full"):
        self.buf = np.zeros(FFT_SIZE, dtype=np.float32)
        self.window = np.hanning(FFT_SIZE).astype(np.float32)
        freqs = np.fft.rfftfreq(FFT_SIZE, 1.0 / SAMPLE_RATE)
        self.masks = {k: (freqs >= lo) & (freqs < hi) for k, (lo, hi) in self.BANDS.items()}
        self.freqs = freqs
        self.source = None
        self.set_params(beat_k, min_beat, source)
        self.peaks = {k: 1e-3 for k in self.BANDS}
        self.prev_band = {k: None for k in self.BANDS}
        self.onset_peak = {k: 1e-3 for k in self.BANDS}
        self.rms_fast = 0.0
        self.rms_slow = 0.0
        self.prev_log = None
        self.last_beat = 0.0
        self.t = 0.0

    def set_params(self, beat_k, min_beat, source="full"):
        self.beat_k, self.min_beat = beat_k, min_beat
        if source != self.source:
            lo, hi = self.SOURCES.get(source, self.SOURCES["full"])
            self.flux_mask = (self.freqs >= lo) & (self.freqs < hi)
            self.flux_hist = collections.deque(maxlen=50)   # ~1 s d'historique
            self.prev_log = None
            self.source = source

    def process(self, samples):
        self.t += len(samples) / SAMPLE_RATE
        self.buf = np.concatenate([self.buf[len(samples):], samples])
        rms = float(np.sqrt(np.mean(samples ** 2)))
        sound = rms >= 0.001       # pendant un silence, on fige les références de volume
        mag = np.abs(np.fft.rfft(self.buf * self.window))

        # Énergie par bande, normalisée par un gain automatique (indépendant du volume),
        # et attaques par bande (hausse brutale d'énergie : kick, caisse claire, charley...)
        bands = {}
        for k, m in self.masks.items():
            e = float(np.log1p(np.sqrt(np.mean(mag[m] ** 2))))
            if sound:
                self.peaks[k] = max(e, self.peaks[k] * 0.997, 1e-3)
            bands[k] = e / self.peaks[k]
            prev = self.prev_band[k]
            rise = 0.0 if prev is None else max(0.0, e - prev)
            self.prev_band[k] = e
            if sound:
                self.onset_peak[k] = max(rise, self.onset_peak[k] * 0.995, 0.02)
            bands["on_" + k] = min(1.0, rise / self.onset_peak[k])
        # Dynamique : volume du moment par rapport aux dernières secondes (couplet calme / refrain)
        self.rms_fast += (rms - self.rms_fast) * 0.12
        if sound:
            if self.rms_slow <= 0:
                self.rms_slow = rms          # premier son : référence immédiate
            self.rms_slow += (rms - self.rms_slow) * 0.004
        ratio = self.rms_fast / max(self.rms_slow, 1e-4)
        bands["energy"] = max(0.0, min(1.0, (ratio - 0.75) / 0.6))

        # Flux spectral : détecte les attaques (kick, caisse claire...)
        log_mag = np.log1p(mag[self.flux_mask])
        flux = 0.0 if self.prev_log is None else float(np.sum(np.maximum(0, log_mag - self.prev_log)))
        self.prev_log = log_mag
        beat, strength = False, 0.0
        if len(self.flux_hist) >= 6 and sound:
            mean = float(np.mean(self.flux_hist))
            std = float(np.std(self.flux_hist)) + 1e-6
            thresh = mean + self.beat_k * std
            floor = 0.0054 * int(self.flux_mask.sum())    # seuil absolu, proportionnel à la bande
            if flux > thresh and flux > floor and (self.t - self.last_beat) > self.min_beat:
                beat = True
                strength = min(1.0, (flux - mean) / (4 * std))
                self.last_beat = self.t
        self.flux_hist.append(flux)
        return rms, bands, beat, strength


# ---------------------------------------------------------------------------
# Moteur d'effets
# ---------------------------------------------------------------------------
class Effects:
    """Transforme l'analyse musicale en couleurs, selon l'intensité et l'effet choisis."""
    DT = 0.02   # une image toutes les 20 ms

    def __init__(self, channels, palette, intensity, brightness, mode):
        self.beat_count = 0
        self.color_idx = 0
        self.flash = 0.0
        self.silent_frames = 0
        self.last_out = []
        self.rng = np.random.default_rng()
        self.configure(channels, palette, intensity, brightness, mode)

    def configure(self, channels, palette, params, brightness, mode):
        """Applique de nouveaux réglages sans couper la synchro."""
        # Canaux triés de gauche à droite (position x définie dans l'app Hue)
        self.channels = sorted(channels, key=lambda c: c["position"]["x"])
        colors = palette if isinstance(palette, list) else PALETTES.get(palette, PALETTES["sunset"])
        # Couleurs ramenées à pleine intensité : la luminosité est gérée par les effets
        self.palette = [c / max(c.max(), 1e-3) if c.max() > 0.04 else np.ones(3)
                        for c in (hex_to_rgb(h) for h in colors)] or [np.ones(3)]
        self.p = params if isinstance(params, dict) else dict(INTENSITY.get(params, INTENSITY["high"]))
        self.brightness = max(0.05, min(1.0, float(brightness)))
        self.mode = mode
        n = len(self.channels)
        if len(getattr(self, "current", [])) != n:
            self.current = [self.palette[i % len(self.palette)].copy() for i in range(n)]
            self.env = np.zeros(n)
            self.active = np.ones(n, dtype=bool)

    def colors_hex(self):
        return ["#%02x%02x%02x" % tuple(int(max(0, min(1, v)) * 255) for v in o[1:])
                for o in self.last_out]

    def _on_beat(self, strength, bands, n):
        p = self.p
        self.beat_count += 1
        every = max(16, p["every"] * 8) if self.mode == "spectrum" else p["every"]
        if self.beat_count % every == 0:   # en Spectre, les couleurs ne tournent que lentement
            self.color_idx = (self.color_idx + 1) % len(self.palette)
        # Quelles lampes s'allument sur ce temps
        if p["pattern"] == "alt" and n > 1:
            self.active = np.array([(i + self.beat_count) % 2 == 0 for i in range(n)])
        elif p["pattern"] == "wave" and n > 1:
            # la lumière fait des allers-retours d'une lampe à l'autre
            step = self.beat_count % (2 * n - 2)
            self.wave_pos = step if step < n else 2 * n - 2 - step
            self.active = np.array([i == self.wave_pos for i in range(n)])
        elif p["pattern"] == "chase" and n > 1:
            k = max(1, n // 2)
            self.active = np.zeros(n, dtype=bool)
            self.active[self.rng.choice(n, size=k, replace=False)] = True
        else:
            self.active = np.ones(n, dtype=bool)
        if p["strobe"] and strength > 0.75 and bands.get("on_bass", 0) > 0.7 and bands["energy"] > 0.5:
            self.flash = 1.0

    def update(self, rms, bands, beat, strength):
        n = len(self.channels)
        p = self.p
        silent = rms < 0.001
        self.silent_frames = self.silent_frames + 1 if silent else 0
        if beat:
            self._on_beat(strength, bands, n)

        decay = np.exp(-self.DT / p["tau"])
        fade = 1.0 if p["fade"] <= 0 else 1 - np.exp(-self.DT / p["fade"])
        energy = bands.get("energy", 0.5)
        out = []
        for i, ch in enumerate(self.channels):
            pos = i / (n - 1) if n > 1 else 0.5

            if self.mode == "spectrum":
                # Égaliseur : graves à gauche, médiums au centre, aigus à droite. Chaque lampe
                # suit en continu le niveau de sa bande (et pas seulement les temps).
                def band(k):
                    return bands.get(k, 0.0)
                if pos < 0.5:
                    lvl = band("bass") * (1 - 2 * pos) + band("mid") * 2 * pos
                    hit = band("on_bass") * (1 - 2 * pos) + band("on_mid") * 2 * pos
                else:
                    lvl = band("mid") * (2 - 2 * pos) + band("high") * (2 * pos - 1)
                    hit = band("on_mid") * (2 - 2 * pos) + band("on_high") * (2 * pos - 1)
                lvl = max(0.0, min(1.0, (lvl - 0.18) / 0.82)) ** 1.6
                hit = max(lvl, max(0.0, (hit - 0.25) / 0.75))
                # couleur liée à la position (palette étalée sur les lampes, foncée → claire),
                # qui monte vers la couleur suivante quand la bande est forte
                npal = len(self.palette)
                k = (self.color_idx + int(pos * (npal - 1) + 0.5)) % npal
                target = self.palette[k] + (self.palette[(k + 1) % npal] - self.palette[k]) * min(1.0, self.env[i])
            else:
                hit = (0.55 + 0.45 * strength) if (beat and self.active[i]) else 0.0
                if beat and p["pattern"] == "wave" and n > 1:
                    dist = abs(i - getattr(self, "wave_pos", 0))
                    hit = (0.55 + 0.45 * strength) * max(0.0, 1 - 0.55 * dist)
                if beat and not self.active[i] and p["pattern"] == "alt":
                    hit = 0.35
                offset = i if p["pattern"] != "all" else (i % 2)
                target = self.palette[(self.color_idx + offset) % len(self.palette)]

            if self.mode == "spectrum":       # réponse rapide, sans attendre les temps
                self.env[i] = max(hit, self.env[i] * np.exp(-self.DT / min(p["tau"], 0.22)))
                self.current[i] += (target - self.current[i]) * max(fade, 0.35)
            else:
                self.env[i] = max(hit, self.env[i] * decay)
                self.current[i] += (target - self.current[i]) * fade

            if self.mode == "spectrum":   # en Spectre, chaque lampe dépend surtout de sa bande
                b = 0.04 + 0.35 * p["base"] + (0.96 - 0.35 * p["base"]) * self.env[i]
            else:
                b = p["base"] + p["energy"] * energy + p["beat"] * self.env[i]
            if p["pattern"] == "chase" and not self.active[i] and self.mode != "spectrum":
                b *= 0.15                                    # lampes éteintes du chenillard
            b = max(0.0, min(1.0, b))
            if self.silent_frames > 50:                      # >1 s de silence : lumière douce
                b = 0.2
            rgb = self.current[i] * b * self.brightness
            if self.flash > 0:
                rgb = rgb * (1 - self.flash) + np.ones(3) * self.flash * self.brightness
            out.append((ch["channel_id"], *rgb))
        self.flash = max(0.0, self.flash - 0.34)             # flash blanc ~60 ms
        self.last_out = out
        return out


# ---------------------------------------------------------------------------
# Lecture sur une enceinte Bluetooth (BlueALSA), en parallèle de l'analyse
# ---------------------------------------------------------------------------
BLUETOOTHCTL = os.environ.get("HUE_SYNC_BLUETOOTHCTL", "bluetoothctl")
APLAY = os.environ.get("HUE_SYNC_APLAY", "aplay")
MAC_RE = __import__("re").compile(r"^[0-9A-F]{2}(:[0-9A-F]{2}){5}$")


def bt_connected(mac):
    try:
        r = subprocess.run([BLUETOOTHCTL, "info", mac], capture_output=True, text=True, timeout=5)
        return "Connected: yes" in r.stdout
    except (OSError, subprocess.TimeoutExpired):
        return False


class BluetoothPlayer:
    """Envoie le son reçu d'AirPlay vers l'enceinte Bluetooth choisie (via aplay + BlueALSA)."""

    def __init__(self, rate, channels):
        self.rate, self.channels = rate, channels
        self.q = queue.Queue(maxsize=25)        # ~0,5 s de marge
        self.device = ""
        self.proc = None
        self.retry_at = 0.0
        self.last_write = 0.0
        threading.Thread(target=self._loop, daemon=True).start()

    def set_device(self, mac):
        mac = (mac or "").upper()
        if mac and not MAC_RE.match(mac):
            mac = ""
        if mac != self.device:
            self.device = mac
            self._stop()
            self.retry_at = 0.0

    @property
    def playing(self):
        return self.proc is not None and self.proc.poll() is None and time.time() - self.last_write < 1.0

    def feed(self, data):
        if not self.device or self.proc is None:
            return
        if self.q.full():
            try:
                self.q.get_nowait()
            except queue.Empty:
                pass
        self.q.put_nowait(data)

    def _stop(self):
        if self.proc:
            try:
                self.proc.stdin.close()
            except Exception:
                pass
            self.proc.terminate()
            self.proc = None

    def _start(self, mac):
        cmd = [APLAY, "-q", "-D", f"bluealsa:DEV={mac},PROFILE=a2dp", "-f", "S16_LE",
               "-r", str(self.rate), "-c", str(self.channels), "-t", "raw",
               "--buffer-time=150000", "-"]
        try:
            self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL, bufsize=0)
            log(f"Enceinte Bluetooth {mac} : lecture démarrée.")
        except OSError as e:
            log(f"Impossible de lancer aplay : {e}")
            self.proc = None

    def _loop(self):
        while True:
            mac = self.device
            if not mac:
                time.sleep(0.5)
                continue
            if self.proc is None or self.proc.poll() is not None:
                if self.proc is not None:
                    log(f"Enceinte Bluetooth {mac} : lecture interrompue.")
                    self.proc = None
                if time.time() < self.retry_at:
                    time.sleep(0.5)
                    continue
                if bt_connected(mac):
                    self._start(mac)
                else:
                    self.retry_at = time.time() + 5
                    continue
            try:
                data = self.q.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                self.proc.stdin.write(data)
                self.last_write = time.time()
            except (BrokenPipeError, OSError, AttributeError):
                self._stop()
                self.retry_at = time.time() + 3


# ---------------------------------------------------------------------------
# Session Entertainment : prise / libération de la zone, reconnexion
# ---------------------------------------------------------------------------
class Session:
    def __init__(self, cfg, area, dry_run):
        self.cfg, self.area, self.dry_run = cfg, area, dry_run
        self.stream = None
        self.retry_at = 0.0

    @property
    def active(self):
        return self.stream is not None

    def _action(self, action):
        bridge_request(self.cfg["bridge"], "PUT",
                       f"/clip/v2/resource/entertainment_configuration/{self.area['id']}",
                       key=self.cfg["username"], body={"action": action})

    def acquire(self):
        if self.active or time.time() < self.retry_at:
            return
        try:
            if self.dry_run:
                self.stream = DryRunStream()
            else:
                self._action("start")
                self.stream = HueStream(self.cfg["bridge"], self.cfg["app_id"],
                                        self.cfg["clientkey"], self.area["id"])
            log("Musique détectée : synchro démarrée.")
        except HueError as e:
            log(f"Pont indisponible, nouvel essai dans 3 s. ({e})")
            self.stream = None
            self.retry_at = time.time() + 3

    def release(self, reason):
        if not self.active:
            return
        self.stream.close()
        self.stream = None
        if not self.dry_run:
            try:
                self._action("stop")
            except HueError as e:
                log(f"Arrêt non confirmé par le pont : {e}")
        log(f"Synchro en pause ({reason}) : les lampes sont rendues à l'app Hue.")

    def send(self, colors):
        if self.active and not self.stream.send(colors):
            log("Flux interrompu par le pont, reconnexion...")
            self.stream.close()
            self.stream = None


# ---------------------------------------------------------------------------
# Commande "run"
# ---------------------------------------------------------------------------
SETTINGS_DEFAULTS = {"area": "", "palette": "sunset", "intensity": "high", "mode": "pulse",
                     "brightness": 1.0, "idle_release": 15,
                     "bt_device": "", "bt_offset_ms": 300, "area_rev": 0, "fx": {}}


def load_settings(path, args):
    """Réglages : fichier JSON (modifiable à chaud par l'interface web) sinon ligne de commande."""
    s = {"area": args.area or "", "palette": args.palette, "intensity": args.intensity,
         "mode": args.mode, "brightness": args.brightness, "idle_release": args.idle_release,
         "bt_device": "", "bt_offset_ms": 300, "area_rev": 0, "fx": {}}
    if path and os.path.exists(path):
        try:
            with open(path) as f:
                s.update({k: v for k, v in json.load(f).items() if k in SETTINGS_DEFAULTS})
        except (OSError, ValueError) as e:
            log(f"Réglages illisibles ({e}), on garde les précédents.")
    conf_dir = os.path.dirname(path) if path else None
    s["palette_colors"] = resolve_palette(s["palette"], conf_dir)
    if not s["palette_colors"]:
        s["palette"], s["palette_colors"] = "sunset", PALETTES["sunset"]
    if s["intensity"] not in INTENSITY:
        s["intensity"] = "high"
    if s["mode"] not in ("pulse", "spectrum"):
        s["mode"] = "pulse"
    s["fx"] = clean_fx(s.get("fx"))
    s["fx_params"] = fx_params(s["intensity"], s["fx"])
    try:
        s["bt_offset_ms"] = max(0, min(1500, int(s["bt_offset_ms"])))
    except (TypeError, ValueError):
        s["bt_offset_ms"] = 300
    return s


def pick_area(areas, wanted):
    if wanted:
        for a in areas:
            if wanted in (a["id"], a.get("metadata", {}).get("name")):
                return a
        log(f"Zone '{wanted}' introuvable, utilisation de la première zone.")
    return areas[0] if areas else None


class StatusWriter:
    """Écrit l'état en direct (lu par l'interface web) dans un fichier JSON."""

    def __init__(self, path):
        self.path = path
        self.last = 0.0

    def write(self, force=False, **data):
        if not self.path or (not force and time.time() - self.last < 0.2):
            return
        self.last = time.time()
        data["updated"] = self.last
        tmp = self.path + ".tmp"
        try:
            with open(tmp, "w") as f:
                json.dump(data, f)
            os.replace(tmp, self.path)
        except OSError:
            pass


def cmd_run(args):
    global SAMPLE_RATE, HOP
    SAMPLE_RATE = args.rate
    HOP = SAMPLE_RATE // 50          # un bloc toutes les 20 ms

    settings = load_settings(args.settings, args)
    settings_mtime = os.path.getmtime(args.settings) if args.settings and os.path.exists(args.settings) else 0
    status = StatusWriter(args.status)

    if args.dry_run:
        cfg = None
        area = {"id": "dry-run", "metadata": {"name": "Aperçu"},
                "channels": [{"channel_id": i, "position": {"x": i - (args.dry_lights - 1) / 2}}
                             for i in range(args.dry_lights)]}
    else:
        cfg = load_config()
        area = pick_area(get_areas(cfg), settings["area"])
        if not area:
            sys.exit("Aucune zone de divertissement : crée-en une dans l'app Hue.")
    area_name = area.get("metadata", {}).get("name")
    log(f"Zone : {area_name} ({len(area['channels'])} canaux)")

    session = Session(cfg, area, args.dry_run)
    audio = AudioSource(args.source, args.channels)
    player = None
    if args.bluetooth:
        player = BluetoothPlayer(SAMPLE_RATE, args.channels)
        player.set_device(settings["bt_device"])
        audio.raw_sink = player.feed
    delayed = collections.deque()
    p = settings["fx_params"]
    analyzer = Analyzer(p["beat_k"], p["min_beat"], p["source"])
    fx = Effects(area["channels"], settings["palette_colors"], p,
                 settings["brightness"], settings["mode"])
    airplay_on, airplay_seen = False, 0.0   # signal « lecture en cours » d'AirPlay
    last_flag = 0.0

    stop = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    log(f"En attente de musique — palette {settings['palette']}, intensité {settings['intensity']}, "
        f"mode {settings['mode']}, pause après {settings['idle_release']} s de silence.")

    silence = np.zeros(HOP, dtype=np.float32)
    silent_since = time.time()
    last_check = 0.0
    beats = 0
    try:
        while not stop.is_set():
            samples = audio.get(timeout=0.02)
            if samples is None:
                if audio.eof:
                    break
                samples = silence           # rien ne joue : on continue à 50 Hz
            rms, bands, beat, strength = analyzer.process(samples)
            now = time.time()

            # Réglages modifiés depuis l'interface web : on les applique à chaud
            if args.settings and now - last_check > 1.0:
                last_check = now
                try:
                    m = os.path.getmtime(args.settings)
                    if settings.get("palette") == "cover":     # nouvelle pochette = nouvelle palette
                        cp = os.path.join(os.path.dirname(args.settings), COVER_FILE)
                        if os.path.exists(cp):
                            m = (m, os.path.getmtime(cp))
                except OSError:
                    m = settings_mtime
                if m != settings_mtime:
                    settings_mtime = m
                    new = load_settings(args.settings, args)
                    area_changed = (new["area"] != settings["area"]
                                    or new.get("area_rev") != settings.get("area_rev"))
                    if area_changed and not args.dry_run:
                        try:
                            new_area = pick_area(get_areas(cfg), new["area"])
                            if new_area and (new_area["id"] != area["id"]
                                             or new_area.get("channels") != area.get("channels")):
                                session.release("changement de zone")
                                area = session.area = new_area
                                area_name = area.get("metadata", {}).get("name")
                                log(f"Nouvelle zone : {area_name}")
                        except HueError as e:
                            log(f"Changement de zone impossible : {e}")
                    settings = new
                    if player:
                        player.set_device(settings["bt_device"])
                    q = settings["fx_params"]
                    analyzer.set_params(q["beat_k"], q["min_beat"], q["source"])
                    fx.configure(area["channels"], settings["palette_colors"], q,
                                 settings["brightness"], settings["mode"])
                    log(f"Réglages appliqués : {settings['palette']}, {settings['intensity']}, "
                        f"{settings['mode']}, luminosité {settings['brightness']}")

            # Signal AirPlay : le fichier existe tant qu'une lecture est en cours (shairport-sync).
            # On prépare les lampes dès l'appui sur Lecture, avant même l'arrivée du son.
            if args.airplay_flag and now - last_flag > 0.1:
                last_flag = now
                try:
                    mt = os.path.getmtime(args.airplay_flag)
                    if not airplay_on or mt > airplay_seen:
                        if not session.active:
                            log("Lecture AirPlay détectée : préparation des lampes.")
                        silent_since = now
                    airplay_on, airplay_seen = True, mt
                except OSError:
                    if airplay_on:
                        airplay_on = False
                        session.release("fin de la lecture AirPlay")

            if rms >= 0.001:
                silent_since = now
            if rms >= 0.001 or airplay_on:
                session.acquire()
            # pause après un silence ; pendant une lecture AirPlay on patiente plus longtemps
            limit = settings["idle_release"] if not airplay_on else max(settings["idle_release"], 600)
            if settings["idle_release"] > 0 and now - silent_since > limit:
                session.release("silence")
            colors = fx.update(rms, bands, beat, strength)
            # Le Bluetooth joue le son en retard : on retarde les lumières d'autant
            delay = int(settings["bt_offset_ms"] / 20) if player and player.playing else 0
            delayed.append(colors)
            while len(delayed) > delay + 1:
                delayed.popleft()
            colors = delayed[0]
            session.send(colors)
            if beat:
                beats += 1
            status.write(state="syncing" if session.active else "waiting",
                         area=area_name, area_id=area["id"], level=round(float(rms), 4),
                         beats=beats, colors=fx.colors_hex() if session.active else [],
                         bt={"device": player.device, "playing": player.playing} if player else None)
    finally:
        audio.close()
        session.release("arrêt du script")
        status.write(force=True, state="stopped", area=area_name, colors=[])
        log("Synchro arrêtée.")


def main():
    ap = argparse.ArgumentParser(description="Synchro musique -> Philips Hue (façon Hue Sync Desktop)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_pair = sub.add_parser("pair", help="Appairer le script avec le pont Hue")
    p_pair.add_argument("--bridge", help="IP du pont (sinon détection automatique)")

    sub.add_parser("list", help="Lister les zones de divertissement")

    p_run = sub.add_parser("run", help="Lancer la synchro")
    p_run.add_argument("--area", help="Nom ou id de la zone de divertissement")
    p_run.add_argument("--source", default="monitor",
                       help="monitor (son du PC, défaut), mic, stdin, ou nom de périphérique")
    p_run.add_argument("--channels", type=int, default=1,
                       help="Canaux de l'audio brut reçu sur stdin (2 pour shairport-sync)")
    p_run.add_argument("--rate", type=int, default=48000, help="Fréquence d'échantillonnage")
    p_run.add_argument("--palette", default="sunset", choices=sorted(PALETTES))
    p_run.add_argument("--intensity", default="high", choices=list(INTENSITY))
    p_run.add_argument("--mode", default="pulse", choices=["pulse", "spectrum"],
                       help="pulse : toutes les lampes sur le rythme ; "
                            "spectrum : graves à gauche, aigus à droite")
    p_run.add_argument("--brightness", type=float, default=1.0, help="0.1 à 1.0")
    p_run.add_argument("--idle-release", type=float, default=15,
                       help="Secondes de silence avant de rendre les lampes à l'app Hue (0 = jamais)")
    p_run.add_argument("--settings", help="Fichier JSON de réglages, rechargé à chaud")
    p_run.add_argument("--status", help="Fichier JSON où écrire l'état en direct")
    p_run.add_argument("--airplay-flag", help="Fichier créé par shairport-sync pendant une lecture AirPlay")
    p_run.add_argument("--bluetooth", action="store_true",
                       help="Rejouer le son sur l'enceinte Bluetooth choisie dans les réglages")
    p_run.add_argument("--dry-run", action="store_true", help="Aperçu dans le terminal, sans pont")
    p_run.add_argument("--dry-lights", type=int, default=5, help=argparse.SUPPRESS)

    args = ap.parse_args()
    try:
        {"pair": cmd_pair, "list": cmd_list, "run": cmd_run}[args.cmd](args)
    except HueError as e:
        sys.exit(str(e))
    if args.cmd == "run":
        # sortie immédiate : le thread de lecture audio peut être bloqué sur stdin
        sys.stdout.flush()
        os._exit(0)


if __name__ == "__main__":
    main()
HUE_FILE_EOF
cat > /opt/hue-music-sync/hue_sync_web.py <<'HUE_FILE_EOF'
#!/usr/bin/env python3
"""
hue_sync_web.py — Interface web du récepteur AirPlay "Hue Sync" (LXC).

Sert la page index.html et une petite API JSON :
  GET  /api/state      état du service, appairage, réglages
  GET  /api/live       état en direct de la synchro (couleurs, niveau)
  GET  /api/areas      zones de divertissement du pont
  GET  /api/logs       dernières lignes du journal
  POST /api/settings   modifie les réglages (appliqués à chaud)
  POST /api/power      {"on": true|false} démarre / arrête la synchro
  POST /api/pair       {"bridge": "ip"} lance l'appairage (bouton du pont)
  GET  /api/discover   recherche des ponts Hue sur le réseau
  GET  /api/bt         adaptateur et appareils Bluetooth
  POST /api/bt/scan | connect | disconnect | forget   {"mac": "AA:BB:..."}
  GET  /api/rooms      pièces du pont avec leurs lampes (état, couleur, type)
  POST /api/light      {"id", "on"?, "bri"?, "color"?}  pilote une lampe hors synchro
  POST /api/room       {"id", "on"?, "bri"?}             pilote toute une pièce
  POST /api/room/palette {"id", "colors": [...]}         applique une scène / palette à la pièce
  GET  /api/now        morceau AirPlay en cours (titre, artiste, album, progression, couleurs)
  GET  /api/cover      pochette du morceau en cours

La pochette est lue dans le tube de métadonnées de shairport-sync ; ses couleurs (extraites
avec Pillow si disponible) alimentent la palette « Pochette » (cover.json).

Aucune dépendance hors Python standard. À utiliser sur le réseau local uniquement.
"""

import base64
import colorsys
import hashlib
import io
import json
import os
import re
import secrets
import subprocess
import sys
import select
import stat
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONF_DIR = os.environ.get("HUE_SYNC_DIR", "/etc/hue-music-sync")
os.environ.setdefault("HUE_SYNC_CONFIG", os.path.join(CONF_DIR, "config.json"))
SETTINGS_PATH = os.path.join(CONF_DIR, "settings.json")
PALETTES_PATH = os.path.join(CONF_DIR, "palettes.json")
PALETTE_IMG_DIR = os.path.join(CONF_DIR, "palettes")
PALETTE_ID_RE = re.compile(r"^c_[0-9a-f]{8}$")
HEX_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
STATUS_PATH = os.environ.get("HUE_SYNC_STATUS", "/run/hue-music-sync/status.json")
META_PIPE = os.environ.get("HUE_SYNC_META_PIPE", "/run/hue-music-sync/metadata")
COVER_PATH = os.path.join(CONF_DIR, "cover.json")
DEFAULTS_PATH = os.environ.get("HUE_SYNC_DEFAULTS", "/etc/default/hue-airplay")
SYSTEMCTL = os.environ.get("HUE_SYNC_SYSTEMCTL", "systemctl")
SERVICE = "hue-airplay"
PORT = int(os.environ.get("HUE_SYNC_WEB_PORT", "8080"))
HERE = os.path.dirname(os.path.abspath(__file__))

sys.path.insert(0, HERE)
import hue_music_sync as hms  # noqa: E402

ICON = (b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#000"/>'
        b'<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ff2a00"/>'
        b'<stop offset=".5" stop-color="#ff0080"/><stop offset="1" stop-color="#7b00ff"/></linearGradient></defs>'
        b'<circle cx="32" cy="32" r="17" fill="url(#g)"/></svg>')
pairing = {"state": "idle", "message": ""}
bt_state = {"scanning": False, "busy": "", "message": ""}
BTCTL = hms.BLUETOOTHCTL
areas_cache = {"t": 0.0, "data": None}


# ---------------------------------------------------------------------------
def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def get_settings():
    s = dict(hms.SETTINGS_DEFAULTS)
    s.update(read_json(SETTINGS_PATH, {}))
    return s


def airplay_name():
    try:
        with open(DEFAULTS_PATH) as f:
            m = re.search(r'^HUE_AIRPLAY_NAME="?(.*?)"?\s*$', f.read(), re.M)
            if m:
                return m.group(1)
    except OSError:
        pass
    return "Lueur"


def set_airplay_name(name):
    name = re.sub(r'["\\$`\n]', "", name).strip()[:40] or "Lueur"
    try:
        with open(DEFAULTS_PATH) as f:
            content = f.read()
    except OSError:
        content = ""
    line = f'HUE_AIRPLAY_NAME="{name}"'
    if re.search(r"^HUE_AIRPLAY_NAME=", content, re.M):
        content = re.sub(r"^HUE_AIRPLAY_NAME=.*$", line, content, flags=re.M)
    else:
        content += ("\n" if content and not content.endswith("\n") else "") + line + "\n"
    with open(DEFAULTS_PATH, "w") as f:
        f.write(content)
    return name


def systemctl(*args):
    try:
        r = subprocess.run([SYSTEMCTL, *args], capture_output=True, text=True, timeout=15)
        return r.returncode, r.stdout.strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, str(e)


def service_state():
    _, active = systemctl("is-active", SERVICE)
    _, enabled = systemctl("is-enabled", SERVICE)
    return {"active": active == "active", "enabled": enabled == "enabled", "raw": active}


def get_live():
    st = read_json(STATUS_PATH, None)
    if not st or time.time() - st.get("updated", 0) > 3:
        return {"state": "offline", "colors": [], "level": 0}
    return st


def get_areas(force=False):
    if not force and areas_cache["data"] is not None and time.time() - areas_cache["t"] < 30:
        return areas_cache["data"]
    cfg = hms.load_config_or_none()
    if not cfg:
        raise hms.HueError("Pont non appairé.")
    data = [{"id": a["id"], "name": a.get("metadata", {}).get("name", "Zone"),
             "lights": len(a.get("channels", [])), "status": a.get("status")}
            for a in hms.get_areas(cfg)]
    areas_cache.update(t=time.time(), data=data)
    return data


def do_pair(bridge):
    pairing.update(state="waiting", message="Appuie sur le bouton du pont Hue…")
    try:
        cfg = hms.pair_bridge(bridge or None, timeout=30)
        pairing.update(state="ok", message=f"Pont {cfg['bridge']} appairé.")
        areas_cache["data"] = None
        systemctl("restart", SERVICE)
    except hms.HueError as e:
        pairing.update(state="error", message=str(e))


def update_settings(body):
    s = get_settings()
    restart = False
    if "palette" in body and hms.resolve_palette(body["palette"], CONF_DIR):
        s["palette"] = body["palette"]
    if "intensity" in body and body["intensity"] in hms.INTENSITY:
        s["intensity"] = body["intensity"]
        if "fx" not in body:
            s["fx"] = {}                 # choisir un préréglage efface les réglages avancés
    if "fx" in body and isinstance(body["fx"], dict):
        merged = dict(s.get("fx") or {})
        for k, v in body["fx"].items():
            if v is None:
                merged.pop(k, None)      # None = revenir à la valeur du préréglage
            else:
                merged[k] = v
        s["fx"] = hms.clean_fx(merged)
    if "mode" in body and body["mode"] in ("pulse", "spectrum"):
        s["mode"] = body["mode"]
    if "brightness" in body:
        s["brightness"] = round(max(0.05, min(1.0, float(body["brightness"]))), 2)
    if "idle_release" in body:
        s["idle_release"] = max(0, min(3600, int(body["idle_release"])))
    if "area" in body:
        s["area"] = str(body["area"])[:64]
    if "bt_offset_ms" in body:
        s["bt_offset_ms"] = max(0, min(1500, int(body["bt_offset_ms"])))
    write_json(SETTINGS_PATH, s)
    if "airplay_name" in body and body["airplay_name"] != airplay_name():
        set_airplay_name(str(body["airplay_name"]))
        restart = True
    if restart and service_state()["active"]:
        systemctl("restart", SERVICE)
    return s


# ---------------------------------------------------------------------------
# Lampes : zone personnalisée
# ---------------------------------------------------------------------------
def lights_state():
    cfg = hms.load_config_or_none()
    if not cfg:
        raise hms.HueError("Pont non appairé.")
    groups = hms.light_inventory(cfg)
    s = get_settings()
    selected = []
    custom_id = s.get("custom_area_id", "")
    for a in hms.get_areas(cfg):
        if a["id"] == custom_id or (not custom_id and a.get("metadata", {}).get("name") == hms.CUSTOM_AREA_NAME):
            selected, custom_id = hms.area_lights(a), a["id"]
    return {"groups": groups, "selected": selected, "custom_area_id": custom_id,
            "max": hms.MAX_AREA_LIGHTS}


def save_lights(ids):
    cfg = hms.load_config_or_none()
    if not cfg:
        raise hms.HueError("Pont non appairé.")
    ids = [str(i) for i in ids if isinstance(i, str) and re.match(r"^[0-9a-f-]{36}$", i)]
    s = get_settings()
    area_id = hms.save_custom_area(cfg, ids, s.get("custom_area_id") or None)
    s.update(area=area_id, custom_area_id=area_id, area_rev=int(s.get("area_rev", 0)) + 1)
    write_json(SETTINGS_PATH, s)
    areas_cache["data"] = None
    return {"area_id": area_id, "count": len(ids)}


# ---------------------------------------------------------------------------
# Lumières hors synchro (pièces, lampes, scènes)
# ---------------------------------------------------------------------------
def hex_to_xy(h):
    """Couleur #rrggbb -> coordonnées xy du pont (gamme large, D65)."""
    r, g, b = (int(h[i:i + 2], 16) / 255.0 for i in (1, 3, 5))
    lin = [((c + 0.055) / 1.055) ** 2.4 if c > 0.04045 else c / 12.92 for c in (r, g, b)]
    X = lin[0] * 0.664511 + lin[1] * 0.154324 + lin[2] * 0.162028
    Y = lin[0] * 0.283881 + lin[1] * 0.668433 + lin[2] * 0.047685
    Z = lin[0] * 0.000088 + lin[1] * 0.072310 + lin[2] * 0.986039
    t = X + Y + Z
    return (0.3227, 0.329) if t <= 0 else (round(X / t, 4), round(Y / t, 4))


def xy_to_hex(x, y):
    """Coordonnées xy -> #rrggbb, à pleine luminosité (pour l'affichage)."""
    if y <= 0:
        return "#ffffff"
    X, Y = x / y, 1.0
    Z = (1 - x - y) / y
    r = X * 1.656492 - Y * 0.354851 - Z * 0.255038
    g = -X * 0.707196 + Y * 1.655397 + Z * 0.036152
    b = X * 0.051713 - Y * 0.121364 + Z * 1.011530
    m = max(r, g, b, 1e-6)
    out = []
    for c in (r / m, g / m, b / m):
        c = max(0.0, c)
        c = 1.055 * c ** (1 / 2.4) - 0.055 if c > 0.0031308 else 12.92 * c
        out.append(int(max(0, min(1, c)) * 255))
    return "#%02x%02x%02x" % tuple(out)


def mirek_to_hex(m):
    """Température de blanc (mirek) -> couleur approchée pour l'affichage."""
    k = 1_000_000 / max(153, min(500, m or 366))
    t = k / 100
    r = 255 if t <= 66 else 329.7 * (t - 60) ** -0.1332
    g = 99.47 * __import__("math").log(t) - 161.1 if t <= 66 else 288.1 * (t - 60) ** -0.0755
    b = 255 if t >= 66 else (0 if t <= 19 else 138.5 * __import__("math").log(t - 10) - 305.0)
    return "#%02x%02x%02x" % tuple(int(max(0, min(255, v))) for v in (r, g, b))


def _cfg():
    cfg = hms.load_config_or_none()
    if not cfg:
        raise hms.HueError("Pont non appairé.")
    return cfg


def _light_view(l, positions):
    color = None
    if l.get("color", {}).get("xy"):
        xy = l["color"]["xy"]
        color = xy_to_hex(xy.get("x", 0.3227), xy.get("y", 0.329))
    if l.get("color_temperature", {}).get("mirek_valid") and not l.get("color", {}).get("xy"):
        color = mirek_to_hex(l["color_temperature"].get("mirek"))
    if l.get("gradient", {}).get("points"):
        grad = [xy_to_hex(p["color"]["xy"]["x"], p["color"]["xy"]["y"]) for p in l["gradient"]["points"]
                if p.get("color", {}).get("xy")]
    else:
        grad = []
    mode = l.get("color_temperature", {}).get("mirek_valid")
    if l.get("color", {}).get("xy") and l.get("color_temperature", {}).get("mirek") is None:
        mode = False
    return {
        "id": l["id"], "name": l.get("metadata", {}).get("name", "Lampe"),
        "archetype": l.get("metadata", {}).get("archetype", ""),
        "on": bool(l.get("on", {}).get("on")),
        "bri": round(l.get("dimming", {}).get("brightness", 100)),
        "color": color or "#fff1dc", "gradient": grad,
        "has_color": "color" in l, "has_gradient": bool(l.get("gradient", {}).get("points_capable")),
        "pos": positions.get(l["id"]),
    }


def rooms_state():
    cfg = _cfg()
    lights = {l["id"]: l for l in hms.bridge_get(cfg, "light")}
    owner_lights = {}
    for l in lights.values():
        owner_lights.setdefault(l.get("owner", {}).get("rid"), []).append(l["id"])
    # positions des lampes dans les zones de divertissement (pour colorer selon le placement)
    ent_owner = {e["id"]: e.get("owner", {}).get("rid") for e in hms.bridge_get(cfg, "entertainment")}
    positions = {}
    for a in hms.get_areas(cfg):
        for loc in a.get("locations", {}).get("service_locations", []):
            dev = ent_owner.get(loc.get("service", {}).get("rid"))
            pts = loc.get("positions") or []
            for lid in owner_lights.get(dev, []):
                if pts and lid not in positions:
                    positions[lid] = {"x": pts[0].get("x", 0), "y": pts[0].get("y", 0)}
    groups = {g["id"]: g for g in hms.bridge_get(cfg, "grouped_light")}
    rooms = []
    for r in hms.bridge_get(cfg, "room"):
        ids = []
        for c in r.get("children", []):
            if c.get("rtype") == "device":
                ids += owner_lights.get(c["rid"], [])
            elif c.get("rtype") == "light":
                ids.append(c["rid"])
        ls = [_light_view(lights[i], positions) for i in dict.fromkeys(ids) if i in lights]
        if not ls:
            continue
        gl = next((s["rid"] for s in r.get("services", []) if s.get("rtype") == "grouped_light"), None)
        g = groups.get(gl, {})
        rooms.append({
            "id": r["id"], "name": r.get("metadata", {}).get("name", "Pièce"),
            "archetype": r.get("metadata", {}).get("archetype", ""), "group": gl,
            "on": bool(g.get("on", {}).get("on", any(l["on"] for l in ls))),
            "bri": round(g.get("dimming", {}).get("brightness", 100)), "lights": ls})
    rooms.sort(key=lambda r: r["name"].lower())
    return rooms


def _put(cfg, rtype, rid, body):
    if not re.match(r"^[0-9a-f-]{36}$", str(rid or "")):
        raise ValueError("Identifiant invalide.")
    hms.bridge_request(cfg["bridge"], "PUT", f"/clip/v2/resource/{rtype}/{rid}", key=cfg["username"], body=body)


def set_light(body):
    cfg, b = _cfg(), {}
    if "on" in body:
        b["on"] = {"on": bool(body["on"])}
    if "bri" in body:
        b["dimming"] = {"brightness": max(1.0, min(100.0, float(body["bri"])))}
    if body.get("color") and HEX_RE.match(body["color"]):
        x, y = hex_to_xy(body["color"])
        b["color"] = {"xy": {"x": x, "y": y}}
        b.setdefault("on", {"on": True})
    if body.get("mirek"):
        b["color_temperature"] = {"mirek": max(153, min(500, int(body["mirek"])))}
        b.setdefault("on", {"on": True})
    _put(cfg, "light", body.get("id"), b)
    return {"ok": True}


def set_room(body):
    cfg, b = _cfg(), {}
    if "on" in body:
        b["on"] = {"on": bool(body["on"])}
    if "bri" in body:
        b["dimming"] = {"brightness": max(1.0, min(100.0, float(body["bri"])))}
    _put(cfg, "grouped_light", body.get("group"), b)
    return {"ok": True}


def room_palette(body):
    """Applique une palette à une pièce : chaque lampe prend la couleur de sa position."""
    cfg = _cfg()
    colors = [c for c in body.get("colors", []) if isinstance(c, str) and HEX_RE.match(c)][:8]
    if not colors:
        raise ValueError("Palette vide.")
    room = next((r for r in rooms_state() if r["id"] == body.get("id")), None)
    if not room:
        raise ValueError("Pièce introuvable.")
    spread = body.get("spread", "lr")
    ls = room["lights"]

    def t_of(i, l):
        p = l.get("pos")
        if not p:
            return i / max(1, len(ls) - 1)
        x, y = p["x"], p["y"]
        if spread == "fb":
            return (1 - y) / 2
        if spread == "centre":
            return min(1.0, (x * x + y * y) ** 0.5 / 1.42)
        if spread == "tour":
            import math
            return ((math.atan2(-y, x) + math.pi * 1.5) % (2 * math.pi)) / (2 * math.pi)
        return (x + 1) / 2

    def pick(t):
        t = max(0.0, min(0.999, t))
        return colors[int(t * len(colors))]

    for i, l in enumerate(ls):
        if l.get("has_gradient"):
            pts = [{"color": {"xy": dict(zip("xy", hex_to_xy(c)))}} for c in colors[:5]]
            body_l = {"on": {"on": True}, "gradient": {"points": pts}}
        elif l.get("has_color"):
            x, y = hex_to_xy(pick(t_of(i, l)))
            body_l = {"on": {"on": True}, "color": {"xy": {"x": x, "y": y}}}
        else:
            body_l = {"on": {"on": True}}
        try:
            _put(cfg, "light", l["id"], body_l)
        except hms.HueError:
            pass
        time.sleep(0.08)               # le pont accepte ~10 commandes par seconde
    return {"ok": True}


# ---------------------------------------------------------------------------
# Palettes personnalisées
# ---------------------------------------------------------------------------
def list_custom_palettes():
    keys = ("id", "name", "colors", "points", "updated", "scenes", "synchro", "image")
    return [{k: p.get(k) for k in keys} for p in hms.custom_palettes(CONF_DIR)]


def touch_settings_if_selected(pid):
    s = get_settings()
    if s.get("palette") == pid:
        write_json(SETTINGS_PATH, s)       # le script relit les couleurs à chaud


def save_palette(body):
    name = re.sub(r"[\x00-\x1f<>]", "", str(body.get("name", "")).strip())[:30] or "Ma palette"
    colors = [c for c in body.get("colors", []) if isinstance(c, str) and HEX_RE.match(c)][:8]
    if len(colors) < 2:
        raise ValueError("Une palette a besoin d'au moins 2 couleurs.")
    points = []
    for pt in body.get("points", [])[:8]:
        try:
            points.append([round(max(0.0, min(1.0, float(pt[0]))), 4), round(max(0.0, min(1.0, float(pt[1]))), 4)])
        except (TypeError, ValueError, IndexError):
            points.append([0.5, 0.5])
    pid = body.get("id") or ""
    pals = hms.custom_palettes(CONF_DIR)
    if pid and not any(p["id"] == pid for p in pals):
        raise ValueError("Palette introuvable.")
    if not pid:
        if len(pals) >= 30:
            raise ValueError("Trop de palettes (30 maximum) : supprimes-en une.")
        pid = "c_" + secrets.token_hex(4)
    img = body.get("image")
    if img:
        m = re.match(r"^data:image/(jpeg|png|webp);base64,(.+)$", img, re.S)
        if not m:
            raise ValueError("Image invalide.")
        raw = base64.b64decode(m.group(2), validate=False)
        if len(raw) > 3_000_000:
            raise ValueError("Image trop lourde.")
        os.makedirs(PALETTE_IMG_DIR, exist_ok=True)
        with open(os.path.join(PALETTE_IMG_DIR, pid + ".jpg"), "wb") as f:
            f.write(raw)
    entry = {"id": pid, "name": name, "colors": colors, "points": points, "updated": int(time.time()),
             "scenes": bool(body.get("scenes", True)), "synchro": bool(body.get("synchro", True)),
             "image": bool(img) or os.path.exists(os.path.join(PALETTE_IMG_DIR, pid + ".jpg"))}
    pals = [p for p in pals if p["id"] != pid] + [entry]
    write_json(PALETTES_PATH, {"custom": pals})
    touch_settings_if_selected(pid)
    return entry


def delete_palette(pid):
    if not PALETTE_ID_RE.match(pid or ""):
        raise ValueError("Palette invalide.")
    pals = [p for p in hms.custom_palettes(CONF_DIR) if p["id"] != pid]
    write_json(PALETTES_PATH, {"custom": pals})
    try:
        os.remove(os.path.join(PALETTE_IMG_DIR, pid + ".jpg"))
    except OSError:
        pass
    s = get_settings()
    if s.get("palette") == pid:
        s["palette"] = "sunset"
        write_json(SETTINGS_PATH, s)


# ---------------------------------------------------------------------------
# Morceau en cours (métadonnées AirPlay de shairport-sync)
# ---------------------------------------------------------------------------
META = {"playing": False, "title": "", "artist": "", "album": "", "client": "",
        "cover": None, "colors": [], "pos": None, "dur": None, "t": 0.0}
_cover = {"id": None, "data": b"", "type": "image/jpeg"}
_meta_lock = threading.Lock()
ITEM_RE = re.compile(rb"<item><type>([0-9a-f]{8})</type><code>([0-9a-f]{8})</code>"
                     rb"<length>(\d+)</length>(?:\s*<data encoding=\"base64\">\s*([^<]*)</data>)?\s*</item>",
                     re.S)
RTP_RATE = 44100


def _hex4(h):
    return bytes.fromhex(h.decode()).decode("latin-1")


def cover_colors(data, n=4):
    """Couleurs d'une pochette pour les lampes : les teintes marquantes (même petites, si elles
    sont vives), complétées par des nuances si la pochette en a peu ; du plus foncé au plus clair."""
    try:
        from PIL import Image
        import numpy as np
    except ImportError:
        return []
    try:
        im = Image.open(io.BytesIO(data)).convert("RGB")
    except Exception:  # image illisible
        return []
    im.thumbnail((128, 128))
    px = np.asarray(im, dtype=np.float32).reshape(-1, 3) / 255
    mx, mn = px.max(1), px.min(1)
    chroma = mx - mn
    l = (mx + mn) / 2
    keep = (chroma > 0.16) & (l > 0.07) & (l < 0.93)
    if keep.sum() < 0.01 * len(px):              # pochette (presque) sans couleur : blancs
        return ["#ffb46b", "#ffd9a8", "#fff1de", "#dfe9ff"][:n]
    p, c = px[keep], chroma[keep]
    r, g, b = p[:, 0], p[:, 1], p[:, 2]
    m = p.max(1)
    d = np.maximum(c[...], 1e-6)
    h = np.where(m == r, ((g - b) / d) % 6, np.where(m == g, (b - r) / d + 2, (r - g) / d + 4)) / 6
    BINS = 36
    idx = (h * BINS).astype(int) % BINS
    w = c ** 2                                   # les couleurs vives pèsent plus que les ternes
    hist = np.bincount(idx, weights=w, minlength=BINS)
    smooth = hist + 0.6 * (np.roll(hist, 1) + np.roll(hist, -1)) + 0.25 * (np.roll(hist, 2) + np.roll(hist, -2))
    peaks, top = [], smooth.max()
    for k in np.argsort(-smooth):
        if smooth[k] < 0.03 * top:
            break
        if all(min(abs(k - q), BINS - abs(k - q)) >= 3 for q in peaks):   # ≥ 30° d'écart
            peaks.append(int(k))
        if len(peaks) == n:
            break

    def mean_rgb(k):
        sel = np.isin(idx, [(k - 1) % BINS, k, (k + 1) % BINS])
        ww = w[sel][:, None]
        return (p[sel] * ww).sum(0) / max(ww.sum(), 1e-6)

    def tune(rgb, light):                        # couleur nette, à la luminosité voulue
        hh, _, ss = colorsys.rgb_to_hls(*(float(v) for v in rgb))
        return colorsys.hls_to_rgb(hh, light, max(ss, 0.6))

    base = [mean_rgb(k) for k in peaks]
    lights = [min(max(colorsys.rgb_to_hls(*(float(v) for v in c_))[1], 0.36), 0.6) for c_ in base]
    cols = [tune(c_, li) for c_, li in zip(base, lights)]
    # Trop peu de teintes : on ajoute des nuances (plus profonde, plus claire) des teintes dominantes
    shades = [(0.27, -0.015), (0.68, 0.025), (0.46, 0.04), (0.33, -0.03)]
    i = 0
    while len(cols) < n and i < 8:
        src = base[i % len(base)]
        li, dh = shades[i % len(shades)]
        hh, _, ss = colorsys.rgb_to_hls(*(float(v) for v in src))
        cols.append(colorsys.hls_to_rgb((hh + dh) % 1, li, max(ss, 0.6)))
        i += 1
    out = sorted(cols, key=lambda c_: 0.3 * c_[0] + 0.59 * c_[1] + 0.11 * c_[2])
    return ["#%02x%02x%02x" % tuple(round(min(1, max(0, v)) * 255) for v in c_) for c_ in out]


def _set_cover(data):
    cid = hashlib.sha1(data).hexdigest()[:12]
    colors = cover_colors(data)
    ctype = "image/png" if data[:4] == b"\x89PNG" else "image/jpeg"
    with _meta_lock:
        _cover.update(id=cid, data=data, type=ctype)
        META["cover"] = cid
        META["colors"] = colors
        title, artist = META["title"], META["artist"]
    if len(colors) >= 2:
        try:
            if read_json(COVER_PATH, {}).get("colors") != colors:
                write_json(COVER_PATH, {"id": cid, "colors": colors, "title": title,
                                        "artist": artist, "time": int(time.time())})
        except OSError:
            pass


def _meta_item(typ, code, data):
    if typ == "core":
        key = {"minm": "title", "asar": "artist", "asal": "album"}.get(code)
        if key:
            with _meta_lock:
                META[key] = data.decode("utf-8", "replace").strip()
        return
    if typ != "ssnc":
        return
    if code == "PICT":
        if len(data) > 64:
            _set_cover(data)
        return
    with _meta_lock:
        now = time.time()
        if code == "mdst":                    # nouveau bloc de métadonnées = nouveau morceau
            META.update(title="", artist="", album="")
        elif code in ("pbeg", "prsm"):
            META.update(playing=True, t=now)
        elif code in ("pend", "pfls"):
            if META["playing"] and META["pos"] is not None:
                META["pos"] = min(META["pos"] + now - META["t"], META["dur"] or 1e9)
            META.update(playing=False, t=now)
            if code == "pend":
                META.update(pos=None, dur=None)
        elif code == "snam":
            META["client"] = data.decode("utf-8", "replace")
        elif code == "prgr":
            try:
                a, c, e = (int(x) for x in data.decode().split("/"))
            except ValueError:
                return
            M = 1 << 32
            META.update(pos=((c - a) % M) / RTP_RATE, dur=((e - a) % M) / RTP_RATE or None,
                        playing=True, t=now)


def meta_feed(buf):
    """Traite les éléments complets du tampon et renvoie le reste."""
    last = 0
    for m in ITEM_RE.finditer(buf):
        last = m.end()
        try:
            _meta_item(_hex4(m.group(1)), _hex4(m.group(2)), base64.b64decode(m.group(4) or b""))
        except (ValueError, UnicodeDecodeError):
            continue
    rest = buf[last:]
    return b"" if len(rest) > 8_000_000 else rest   # flux corrompu : on repart de zéro


def meta_reader():
    """Lit en continu le tube de métadonnées (recréé s'il disparaît, par ex. après un redémarrage)."""
    while True:
        fd = None
        try:
            if not os.path.isdir(os.path.dirname(META_PIPE)):
                time.sleep(3)
                continue
            if not os.path.exists(META_PIPE):
                os.mkfifo(META_PIPE, 0o660)
            st = os.stat(META_PIPE)
            if not stat.S_ISFIFO(st.st_mode):
                time.sleep(10)
                continue
            fd = os.open(META_PIPE, os.O_RDWR)        # lecture + écriture : jamais de fin de fichier
            buf = b""
            while True:
                r, _, _ = select.select([fd], [], [], 5)
                if not r:
                    try:
                        if os.stat(META_PIPE).st_ino != st.st_ino:
                            break
                    except OSError:
                        break
                    continue
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                buf = meta_feed(buf + chunk)
        except OSError as e:
            print(f"Métadonnées AirPlay : {e}", flush=True)
            time.sleep(5)
        finally:
            if fd is not None:
                os.close(fd)


def now_playing():
    with _meta_lock:
        m = dict(META)
    now = time.time()
    if m["playing"] and m["pos"] is not None:
        m["pos"] = min(m["pos"] + now - m["t"], m["dur"] or 1e9)
    m["t"] = now
    m["has"] = bool(m["title"] or m["cover"])
    return m


# ---------------------------------------------------------------------------
# Bluetooth (bluetoothctl)
# ---------------------------------------------------------------------------
def btctl(*args, timeout=10):
    try:
        r = subprocess.run([BTCTL, *args], capture_output=True, text=True, timeout=timeout + 5)
        return r.returncode, r.stdout
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, str(e)


def bt_info(mac):
    _, out = btctl("info", mac)
    info = {"mac": mac, "name": mac, "paired": False, "connected": False, "trusted": False,
            "audio": False, "icon": ""}
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("Name:"):
            info["name"] = line[5:].strip()
        elif line.startswith("Alias:") and info["name"] == mac:
            info["name"] = line[6:].strip()
        elif line.startswith("Paired:"):
            info["paired"] = line.endswith("yes")
        elif line.startswith("Connected:"):
            info["connected"] = line.endswith("yes")
        elif line.startswith("Trusted:"):
            info["trusted"] = line.endswith("yes")
        elif line.startswith("Icon:"):
            info["icon"] = line[5:].strip()
            info["audio"] = info["audio"] or info["icon"].startswith("audio")
        elif line.startswith("UUID:") and "Audio Sink" in line:
            info["audio"] = True
    return info


def has_hci():
    try:
        return any(n.startswith("hci") for n in os.listdir("/sys/class/bluetooth"))
    except OSError:
        return False


bt_diag = {"reason": "", "repair_at": 0.0}


def run_quiet(cmd, timeout=15):
    try:
        subprocess.run(cmd, capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        pass


def bt_adapter():
    """État de l'adaptateur. Tente de réparer les cas courants (pilote non chargé, service arrêté)."""
    can_repair = time.time() >= bt_diag["repair_at"]
    if not has_hci() and can_repair:
        bt_diag["repair_at"] = time.time() + 60
        run_quiet(["modprobe", "btusb"])
        time.sleep(2)
    if not has_hci() and not os.environ.get("HUE_SYNC_BLUETOOTHCTL"):
        bt_diag["reason"] = ("Aucun adaptateur Bluetooth vu par la VM. Vérifie dans Proxmox : "
                             "VM → Matériel → Périphérique USB, puis redémarre la VM.")
        return None
    code, out = btctl("list", timeout=4)
    if (code != 0 or "Controller" not in out) and can_repair:
        bt_diag["repair_at"] = time.time() + 60
        run_quiet([SYSTEMCTL, "restart", "bluetooth"])
        time.sleep(2)
        for svc in ("hue-bt-agent", "hue-bluealsa"):
            run_quiet([SYSTEMCTL, "restart", svc])
        code, out = btctl("list", timeout=4)
    if code != 0 or "Controller" not in out:
        bt_diag["reason"] = ("Adaptateur présent mais le service Bluetooth ne répond pas. "
                             "Redémarre la VM ; si ça persiste, regarde : journalctl -u bluetooth")
        return None
    bt_diag["reason"] = ""
    _, show = btctl("show")
    if "PowerState: off-blocked" in show or "Blocked" in show:
        run_quiet(["rfkill", "unblock", "bluetooth"], timeout=5)
    _, show = btctl("show")
    powered = "Powered: yes" in show
    if not powered:
        btctl("power", "on")
        _, show = btctl("show")
        powered = "Powered: yes" in show
    return {"powered": powered}


def bt_devices():
    _, out = btctl("devices")
    devs = []
    for line in out.splitlines():
        parts = line.strip().split(" ", 2)
        if len(parts) >= 2 and parts[0] == "Device" and hms.MAC_RE.match(parts[1].upper()):
            devs.append(bt_info(parts[1].upper()))
    # enceintes d'abord, puis appareils connus, puis par nom
    devs.sort(key=lambda d: (not d["connected"], not d["audio"], not d["paired"], d["name"].lower()))
    return devs


def bt_scan():
    bt_state.update(scanning=True, message="Recherche des enceintes…")
    btctl("--timeout", "12", "scan", "on", timeout=12)
    bt_state.update(scanning=False, message="")


def bt_connect(mac):
    bt_state.update(busy=mac, message="Connexion…")
    try:
        info = bt_info(mac)
        if not info["paired"]:
            bt_state["message"] = "Appairage… (l'enceinte doit être en mode appairage)"
            btctl("--timeout", "20", "pair", mac, timeout=20)
            if not bt_info(mac)["paired"]:
                bt_state.update(message="Échec de l'appairage : mets l'enceinte en mode appairage.")
                return
        btctl("trust", mac)
        bt_state["message"] = "Connexion…"
        btctl("--timeout", "15", "connect", mac, timeout=15)
        if bt_info(mac)["connected"]:
            s = get_settings()
            s["bt_device"] = mac
            write_json(SETTINGS_PATH, s)
            bt_state.update(message="Enceinte connectée.")
        else:
            bt_state.update(message="Connexion impossible : l'enceinte est-elle allumée et à portée ?")
    finally:
        bt_state["busy"] = ""


def bt_watchdog():
    """Reconnecte l'enceinte choisie si elle se déconnecte (rallumage, hors de portée...)."""
    while True:
        time.sleep(20)
        try:
            mac = get_settings().get("bt_device")
            if mac and not bt_state["busy"] and bt_adapter() and not bt_info(mac)["connected"]:
                btctl("--timeout", "10", "connect", mac, timeout=10)
        except Exception:
            pass


# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "HueSyncWeb/1.0"

    def log_message(self, fmt, *args):
        pass  # pas de log par requête (le polling est fréquent)

    def _send(self, code, payload, ctype="application/json"):
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        limit = 4_500_000 if self.path.startswith("/api/palettes") else 20000
        if n > limit:
            return {}
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return {}

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            with open(os.path.join(HERE, "index.html"), "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        if path in ("/icon.svg", "/favicon.ico"):
            return self._send(200, ICON, "image/svg+xml")
        if path == "/manifest.webmanifest":
            return self._send(200, json.dumps({
                "name": "Lueur", "short_name": "Lueur", "display": "standalone",
                "background_color": "#1b1c20", "theme_color": "#1b1c20", "start_url": "/"}).encode(),
                "application/manifest+json")
        if path == "/api/state":
            cfg = hms.load_config_or_none()
            return self._send(200, {
                "service": service_state(),
                "paired": bool(cfg), "bridge": cfg["bridge"] if cfg else None,
                "settings": get_settings(), "airplay_name": airplay_name(),
                "palettes": hms.PALETTES, "custom_palettes": list_custom_palettes(),
                "intensities": list(hms.INTENSITY), "presets": hms.INTENSITY,
                "pairing": pairing, "live": get_live(), "now": now_playing()})
        if path == "/api/now":
            return self._send(200, now_playing())
        if path == "/api/cover":
            with _meta_lock:
                data, ctype = _cover["data"], _cover["type"]
            if not data:
                return self._send(404, {"error": "aucune pochette"})
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "max-age=86400")
            self.end_headers()
            self.wfile.write(data)
            return
        if path == "/api/live":
            return self._send(200, {**get_live(), "now": now_playing()})
        if path == "/api/areas":
            try:
                return self._send(200, get_areas(force="refresh" in self.path))
            except hms.HueError as e:
                return self._send(502, {"error": str(e)})
        m = re.match(r"^/palettes/(c_[0-9a-f]{8})\.jpg$", path)
        if m:
            try:
                with open(os.path.join(PALETTE_IMG_DIR, m.group(1) + ".jpg"), "rb") as f:
                    return self._send(200, f.read(), "image/jpeg")
            except OSError:
                return self._send(404, {"error": "introuvable"})
        if path == "/api/discover":
            return self._send(200, {"bridges": hms.discover_bridges()})
        if path == "/api/lights":
            try:
                return self._send(200, lights_state())
            except hms.HueError as e:
                return self._send(502, {"error": str(e)})
        if path == "/api/rooms":
            try:
                return self._send(200, rooms_state())
            except hms.HueError as e:
                return self._send(502, {"error": str(e)})
        if path == "/api/bt":
            adapter = bt_adapter()
            return self._send(200, {
                "available": bool(adapter), "powered": bool(adapter and adapter["powered"]),
                "devices": bt_devices() if adapter else [],
                "selected": get_settings().get("bt_device", ""), "reason": bt_diag["reason"],
                **bt_state})
        if path == "/api/logs":
            try:
                r = subprocess.run(["journalctl", "-u", SERVICE, "-n", "60", "--no-pager",
                                    "-o", "cat"], capture_output=True, text=True, timeout=5)
                lines = r.stdout
            except (OSError, subprocess.TimeoutExpired):
                lines = "Journal indisponible."
            return self._send(200, {"lines": lines})
        self._send(404, {"error": "introuvable"})

    def do_POST(self):
        path = self.path.split("?")[0]
        body = self._body()
        try:
            if path == "/api/settings":
                return self._send(200, update_settings(body))
            if path == "/api/power":
                on = bool(body.get("on"))
                if on:
                    systemctl("enable", SERVICE)
                    code, out = systemctl("start", SERVICE)
                else:
                    systemctl("disable", SERVICE)
                    code, out = systemctl("stop", SERVICE)
                return self._send(200 if code == 0 else 500, {"ok": code == 0, "message": out})
            if path == "/api/lights":
                try:
                    return self._send(200, save_lights(body.get("ids", [])))
                except hms.HueError as e:
                    return self._send(502, {"error": str(e)})
            if path in ("/api/light", "/api/room", "/api/room/palette"):
                fn = {"/api/light": set_light, "/api/room": set_room, "/api/room/palette": room_palette}[path]
                try:
                    return self._send(200, fn(body))
                except hms.HueError as e:
                    return self._send(502, {"error": str(e)})
            if path == "/api/palettes":
                return self._send(200, save_palette(body))
            if path == "/api/palettes/delete":
                delete_palette(body.get("id"))
                return self._send(200, {"ok": True})
            if path.startswith("/api/bt/"):
                action = path.rsplit("/", 1)[1]
                mac = str(body.get("mac", "")).upper()
                if action == "scan":
                    if not bt_state["scanning"]:
                        threading.Thread(target=bt_scan, daemon=True).start()
                    return self._send(200, bt_state)
                if not hms.MAC_RE.match(mac):
                    return self._send(400, {"error": "Adresse Bluetooth invalide."})
                if action == "connect":
                    if not bt_state["busy"]:
                        threading.Thread(target=bt_connect, args=(mac,), daemon=True).start()
                    return self._send(200, bt_state)
                if action in ("disconnect", "forget"):
                    s = get_settings()
                    if s.get("bt_device") == mac:
                        s["bt_device"] = ""
                        write_json(SETTINGS_PATH, s)
                    btctl("disconnect", mac)
                    if action == "forget":
                        btctl("remove", mac)
                    return self._send(200, {"ok": True})
                return self._send(404, {"error": "introuvable"})
            if path == "/api/pair":
                if pairing["state"] != "waiting":
                    threading.Thread(target=do_pair, args=(body.get("bridge", "").strip(),),
                                     daemon=True).start()
                    time.sleep(0.1)
                return self._send(200, pairing)
        except (ValueError, TypeError, OSError) as e:
            return self._send(400, {"error": str(e)})
        self._send(404, {"error": "introuvable"})


def main():
    threading.Thread(target=bt_watchdog, daemon=True).start()
    threading.Thread(target=meta_reader, daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Interface Hue Sync sur http://0.0.0.0:{PORT}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
HUE_FILE_EOF
cat > /opt/hue-music-sync/index.html <<'HUE_FILE_EOF'
<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#1b1c20">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Lueur">
<link rel="icon" href="/icon.svg">
<link rel="apple-touch-icon" href="/icon.svg">
<link rel="manifest" href="/manifest.webmanifest">
<title>Lueur</title>
<style>
:root{
  --bg:#1b1c20; --card:#25262b; --card2:#34353a; --sep:#393a3f; --sel:#4a4b52;
  --t2:#a9aab0; --t3:#8d8e94; --blue:#4b8dff; --cta:#1f6fff; --green:#30d158; --red:#ff6961; --orange:#ff9f0a;
  --safe-b:env(safe-area-inset-bottom,0px); --safe-t:env(safe-area-inset-top,0px);
}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;background:var(--bg);color:#fff;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,"Segoe UI",Roboto,sans-serif;-webkit-font-smoothing:antialiased}
body{min-height:100vh;overscroll-behavior-y:none}
button,input,select{font:inherit;color:inherit}
button{cursor:pointer;border:0;background:none;padding:0}
a{color:var(--blue);text-decoration:none}
.hidden{display:none!important}
.app{max-width:520px;margin:0 auto;min-height:100vh;position:relative;padding-bottom:calc(92px + var(--safe-b))}
.view{display:none}.view.on{display:block}
:focus-visible{outline:2px solid var(--blue);outline-offset:2px;border-radius:8px}

/* ---- typographie & structure ---- */
.big{margin:0;padding:calc(56px + var(--safe-t)) 24px 22px;font-size:40px;line-height:1.05;font-weight:800;letter-spacing:-.5px}
.label{padding:30px 24px 12px;color:var(--t2);font-size:13px;font-weight:600;letter-spacing:2.2px;text-transform:uppercase}
.label.in{padding:26px 8px 10px}
.note{margin:0;padding:12px 24px 0;color:var(--t3);font-size:14px;line-height:1.45}
.pad{padding:0 16px}

/* ---- en-tête avec bouton rond ---- */
.nh{display:flex;align-items:center;gap:16px;padding:calc(14px + var(--safe-t)) 16px 16px;background:var(--card);box-shadow:0 6px 16px rgba(0,0,0,.28);position:sticky;top:0;z-index:20}
.nh .t{flex:1;min-width:0;font-size:22px;font-weight:700;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.rb{width:48px;height:48px;border-radius:50%;background:#3a3b40;display:grid;place-items:center;flex:none;transition:transform .12s,filter .12s}
.rb:active{transform:scale(.94);filter:brightness(1.2)}
.rb.blue{background:var(--cta);box-shadow:0 4px 14px rgba(31,111,255,.45)}
.rb svg{width:22px;height:22px}
.txtbtn{color:var(--blue);font-size:16px;font-weight:600;padding:10px 2px}
.txtbtn:disabled{color:#5c5d63}

/* ---- listes pleine largeur ---- */
.list{background:var(--card)}
.row{display:flex;align-items:center;width:100%;min-height:76px;text-align:left;color:#fff}
.row .ic{width:76px;flex:none;display:grid;place-items:center}
.row .ic svg{width:28px;height:28px}
.row .bd{flex:1;min-width:0;align-self:stretch;display:flex;align-items:center;gap:10px;padding:10px 20px 10px 0;border-bottom:1px solid var(--sep)}
.row:last-child .bd{border-bottom:0}
.row .tx{flex:1;min-width:0;display:flex;flex-direction:column;gap:3px}
.row .t1{font-size:18px;font-weight:600}
.row .t2{color:var(--t2);font-size:15px}
.row .val{color:var(--t2);font-size:17px}
.row input.val,.row select.val{background:transparent;border:0;text-align:right;outline:none;max-width:55%}
.row select.val{-webkit-appearance:none;appearance:none;text-align-last:right}
.chev{width:20px;height:20px;flex:none;color:var(--t3)}
.act{font-size:16px;font-weight:600;color:var(--blue);padding:8px 0}
.act.red{color:var(--red)}

/* ---- interrupteur ---- */
.sw{width:51px;height:31px;border-radius:16px;background:#39393d;position:relative;flex:none;transition:background .2s}
.sw i{position:absolute;top:2px;left:2px;width:27px;height:27px;border-radius:50%;background:#fff;box-shadow:0 2px 4px rgba(0,0,0,.3);transition:left .2s}
.sw.on{background:var(--green)}.sw.on i{left:22px}

/* ---- curseurs ---- */
.sl{position:relative;height:30px;touch-action:none;cursor:pointer}
.sl .tr{position:absolute;left:0;right:0;top:11px;height:8px;border-radius:4px;background:#3a3b40}
.sl .fi{position:absolute;left:0;top:11px;height:8px;border-radius:4px;background:#fff}
.sl .kn{position:absolute;top:2px;width:26px;height:26px;margin-left:-13px;border-radius:50%;background:#fff;box-shadow:0 2px 6px rgba(0,0,0,.45)}
.sl.pink .fi{background:#ff6482}

/* ---- segments ---- */
.seg{display:grid;grid-auto-flow:column;grid-auto-columns:minmax(0,1fr);background:var(--card);border-radius:12px;padding:3px}
.seg button{padding:9px 4px;border-radius:10px;color:#c7c7cc;font-size:14px}
.seg button.on{background:var(--sel);color:#fff;font-weight:600}

/* ---- tuiles ---- */
.grid2{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}
.grid3{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px}
.tile{background:var(--card);border-radius:16px;border:2px solid transparent;padding:14px 12px 12px;display:flex;flex-direction:column;gap:8px;text-align:left;color:#fff}
.tile.on{border-color:#fff}
.tile:disabled{opacity:.45;cursor:default}
.tile .n{font-size:15px;font-weight:700}
.tile .d{color:var(--t2);font-size:12px;line-height:1.35}
.tile .soon{color:var(--orange)}

/* tuile orbe (scènes / palettes) */
.orb{background:#2a2b30;border-radius:18px;height:120px;border:2px solid transparent;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:10px;color:#fff;padding:8px 4px}
.orb.on{border-color:#fff}
.orb .o{width:58px;height:58px;border-radius:50%}
.orb .o.dash{border:2px dashed #636366;display:grid;place-items:center;color:#a9aab0;font-size:28px}
.orb span{font-size:13px;font-weight:600;max-width:100%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}

/* tuile lampe */
.lamp{border-radius:18px;border:2px solid transparent;overflow:hidden;display:flex;flex-direction:column;background:#2a2b30;transition:background .3s}
.lamp .top{display:flex;flex-direction:column;align-items:center;gap:8px;padding:16px 6px 10px;color:inherit;text-align:center}
.lamp .top span{font-size:15px;font-weight:600;max-width:100%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.lamp .pw{display:flex;justify-content:center;padding:6px 0 14px}
.pwbtn{width:46px;height:46px;border-radius:50%;display:grid;place-items:center}
.pwbtn svg{width:20px;height:20px}

/* ---- barre d'onglets ---- */
.tabs{position:fixed;left:0;right:0;bottom:0;z-index:30;display:flex;justify-content:center;background:rgba(18,18,20,.92);-webkit-backdrop-filter:blur(18px);backdrop-filter:blur(18px);border-top:.5px solid rgba(255,255,255,.08);padding:6px 8px calc(10px + var(--safe-b))}
.tabs .in{display:flex;width:100%;max-width:520px}
.tabs button{flex:1;display:flex;flex-direction:column;align-items:center;gap:3px;padding:4px 0;color:#8e8e93;font-size:10.5px;font-weight:500}
.tabs button.on{color:#fff}
.tabs svg{width:26px;height:26px}

/* ---- feuilles ---- */
.bg{position:fixed;inset:0;background:rgba(0,0,0,.5);opacity:0;pointer-events:none;transition:opacity .25s;z-index:40}
.bg.open{opacity:1;pointer-events:auto}
.sheet{position:fixed;left:0;right:0;bottom:0;z-index:50;max-width:520px;margin:0 auto;background:var(--card);border-radius:22px 22px 0 0;transform:translateY(105%);transition:transform .3s cubic-bezier(.2,.8,.2,1);max-height:92vh;overflow:auto;padding:8px 16px calc(24px + var(--safe-b))}
.sheet.open{transform:none}
.sheet .grab{width:38px;height:5px;border-radius:3px;background:#5c5d63;margin:0 auto 10px}
.sheet .sh{display:flex;align-items:center;justify-content:space-between;margin:4px 4px 16px}
.sheet .sh b{font-size:20px}
.sheet .tile,.sheet .orb{background:var(--card2)}

/* ---- toast ---- */
.toast{position:fixed;left:50%;bottom:calc(100px + var(--safe-b));transform:translate(-50%,20px);background:rgba(60,60,66,.96);padding:12px 18px;border-radius:14px;font-size:15px;opacity:0;transition:all .25s;z-index:60;pointer-events:none;max-width:86vw;text-align:center}
.toast.show{opacity:1;transform:translate(-50%,0)}

/* ---- Synchro ---- */
.syhead{display:flex;align-items:center;justify-content:center;padding:calc(18px + var(--safe-t)) 16px 0;position:relative}
.zonebtn{display:flex;flex-direction:column;align-items:center;gap:2px;padding:4px 12px}
.zonebtn b{display:flex;align-items:center;gap:6px;font-size:18px}
.zonebtn small{color:var(--t2);font-size:12px;display:flex;align-items:center;gap:5px}
.stage{display:flex;flex-direction:column;align-items:center;margin-top:22px}
.cover{position:relative;width:min(62vw,240px);aspect-ratio:1;border-radius:22px;overflow:hidden;box-shadow:0 24px 60px rgba(0,0,0,.6);isolation:isolate;-webkit-mask-image:-webkit-radial-gradient(white,black);transform:translateZ(0)}
.cover .glow{position:absolute;inset:-20%;filter:blur(30px);transition:background .25s}
.cover .lights{position:absolute;inset:0}
.cover .lights i{position:absolute;width:26px;height:26px;margin:-13px 0 0 -13px;border-radius:50%;transition:background .12s,box-shadow .12s,transform .12s}
.coverwrap{position:relative;width:min(62vw,240px);aspect-ratio:1}
.stage>*:not(.coverwrap){position:relative;z-index:1}
.coverwrap .halo{position:absolute;inset:-22%;opacity:0;transition:opacity .4s;pointer-events:none}
.coverwrap.art .halo{opacity:.85}
.cover img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;opacity:0;transition:opacity .5s;border-radius:inherit}
.coverwrap.art .cover img{opacity:1}
.coverwrap.art .cover .lights,.coverwrap.art .cover .glow{display:none}
.pbar{width:min(78vw,300px);margin-top:16px}
.pbar .tr{height:4px;border-radius:2px;background:#393a3f;overflow:hidden}
.pbar .tr i{display:block;height:100%;width:0;background:#fff;border-radius:2px}
.pbar .tm{display:flex;justify-content:space-between;color:var(--t2);font-size:11px;margin-top:6px;font-variant-numeric:tabular-nums}
.pchip{margin-top:12px;display:inline-flex;align-items:center;gap:8px;background:var(--card);border-radius:20px;padding:6px 12px 6px 8px;font-size:12px;color:var(--t2)}
.pchip .sw4{display:flex}.pchip .sw4 i{width:12px;height:12px;border-radius:50%;margin-right:-3px;border:1.5px solid var(--card)}
.orb .auto{position:absolute;top:8px;right:8px;font-size:9px;font-weight:700;letter-spacing:1px;background:var(--cta);color:#fff;padding:2px 5px;border-radius:5px}
.orb{position:relative}
.stitle{margin-top:20px;font-size:23px;font-weight:700;text-align:center;padding:0 24px;max-width:100%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ssub{margin-top:4px;color:var(--t2);font-size:15px;display:flex;align-items:center;gap:7px}
.dot{width:8px;height:8px;border-radius:50%;background:#636366}
.dot.on{background:var(--green);box-shadow:0 0 10px var(--green)}
.ctrls{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:8px;margin:26px 16px 0}
.ctrl{display:flex;flex-direction:column;align-items:center;gap:7px;color:#fff}
.ctrl .ci{width:58px;height:58px;border-radius:50%;background:var(--card);display:grid;place-items:center}
.ctrl .ci svg{width:26px;height:26px}
.ctrl small{color:var(--t2);font-size:11px;font-weight:600;letter-spacing:1px;text-transform:uppercase}
.ctrl em{font-style:normal;font-size:13px;max-width:100%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.dock{display:flex;align-items:center;justify-content:space-between;margin:28px 22px 0}
.dock .side{width:86px;display:flex;flex-direction:column;align-items:center;gap:4px;color:var(--t2);font-size:11px;font-weight:600;letter-spacing:1px}
.dock .side span{color:#fff;font-size:14px;letter-spacing:0;font-weight:500}
.power{width:92px;height:92px;border-radius:50%;display:grid;place-items:center;background:var(--card);color:#fff;transition:all .25s}
.power.on{background:#fff;color:#1b1c20;box-shadow:0 0 40px rgba(255,255,255,.35)}
.power svg{width:36px;height:36px}
.power.busy{opacity:.5}

/* ---- aperçu des réglages avancés ---- */
.stagebox{margin:14px 16px 0;border-radius:22px;background:radial-gradient(120% 90% at 50% 100%,var(--glow,#ff375f33) 0%,#0b0b0d 62%);box-shadow:inset 0 0 0 1px #1f1f22;padding:14px}
.stagebox .h{display:flex;justify-content:space-between;align-items:center;margin:0 2px 10px}
.prev{display:flex;justify-content:space-between;align-items:center;height:64px;padding:0 6px}
.prev i{width:30px;height:30px;border-radius:50%}
@keyframes f1{0%{opacity:var(--hi);transform:scale(1.14)}12%,100%{opacity:var(--lo);transform:scale(.9)}}
@keyframes f2{0%{opacity:var(--hi);transform:scale(1.14)}28%,100%{opacity:var(--lo);transform:scale(.9)}}
@keyframes f3{0%{opacity:var(--hi);transform:scale(1.14)}50%,100%{opacity:var(--lo);transform:scale(.9)}}
@keyframes bar{0%{opacity:var(--lo)}100%{opacity:var(--hi)}}
@keyframes fl{0%{opacity:1}30%,100%{opacity:.14}}
@keyframes hue{to{filter:hue-rotate(360deg)}}
@keyframes br{0%,100%{opacity:.22}50%{opacity:1}}
@keyframes ping{0%{transform:scale(.6);opacity:.9}100%{transform:scale(1.8);opacity:0}}
.fold{display:flex;align-items:center;gap:12px;width:100%;margin-top:12px;min-height:62px;padding:10px 16px;border-radius:18px;background:var(--card);text-align:left}
.fold .tx{flex:1;display:flex;flex-direction:column;gap:2px}
.fold b{font-size:17px}.fold small{color:var(--t2);font-size:14px}
.fold svg{transition:transform .2s}
.fold.open svg{transform:rotate(90deg)}
.foldin{margin-top:8px;background:var(--card);border-radius:18px;padding:6px 16px 12px}
.srow{padding:10px 0 4px}
.srow .h{display:flex;justify-content:space-between;margin-bottom:2px}
.srow .h span:last-child{color:var(--t2)}
.hint{margin:2px 0 8px;color:var(--t3);font-size:13px;line-height:1.4}

/* ---- pièces ---- */
.rooms{display:flex;flex-direction:column;gap:12px;padding:0 16px}
.room{border-radius:22px;padding:16px;display:flex;flex-direction:column;gap:14px;transition:background .3s}
.room .r1{display:flex;align-items:center;gap:14px}
.room .ri{width:44px;height:44px;border-radius:12px;display:grid;place-items:center;flex:none}
.room .ri svg{width:26px;height:26px}
.room .rn{flex:1;font-size:19px;font-weight:700;text-align:left;color:inherit}
.rhead{border-radius:0 0 28px 28px;padding:calc(14px + var(--safe-t)) 16px 20px;transition:background .3s}
.plan{margin:18px 16px 0;border-radius:20px;background:#0b0b0d;box-shadow:inset 0 0 0 1px #1f1f22;overflow:hidden}
.plan svg{display:block;width:100%;height:auto}
.spr{display:flex;align-items:center;justify-content:space-between;margin:12px 20px 0}
.spr span{color:var(--t2);font-size:13px}
.spr .seg{background:var(--card);grid-auto-columns:40px}
.spr .seg button{padding:5px 0;display:grid;place-items:center}

/* ---- roue des couleurs ---- */
.wheel{position:relative;width:min(76vw,290px);aspect-ratio:1;margin:18px auto 0;border-radius:50%;touch-action:none;background:conic-gradient(from 90deg,#f00,#ff8000,#ff0,#80ff00,#0f8,#0ff,#0080ff,#80f,#f0f,#ff0080,#f00);box-shadow:0 18px 50px rgba(0,0,0,.55)}
.wheel:after{content:"";position:absolute;inset:0;border-radius:50%;background:radial-gradient(circle,#fff 0%,rgba(255,255,255,0) 68%)}
.wheel.white{background:linear-gradient(180deg,#ff9a4d 0%,#ffd9a0 30%,#fff6e6 60%,#fff 78%,#cfe8ff 100%)}
.wheel.white:after{display:none}
.pin{position:absolute;width:48px;height:48px;margin:-24px 0 0 -24px;border-radius:50%;border:3px solid #fff;box-shadow:0 4px 14px rgba(0,0,0,.45);z-index:2;display:grid;place-items:center;color:#1b1c20;pointer-events:none}
.pin svg{width:22px;height:22px}

/* ---- création de palette ---- */
.pick{position:relative;border-radius:18px;overflow:hidden;background:var(--card);min-height:200px;display:grid;place-items:center;margin-top:14px}
.pick img{display:block;width:100%;height:auto}
.pick .pt{position:absolute;width:32px;height:32px;margin:-16px 0 0 -16px;border-radius:50%;border:3px solid #fff;box-shadow:0 3px 10px rgba(0,0,0,.5);touch-action:none}
.pick .empty{display:flex;flex-direction:column;align-items:center;gap:8px;color:var(--t2);padding:30px;text-align:center}
.slots{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px;margin-top:14px}
.slots button{height:62px;border-radius:16px;border:3px solid transparent}
.slots button.on{border-color:#fff}
.sws{display:grid;grid-template-columns:repeat(8,minmax(0,1fr));gap:8px;margin-top:14px;padding:14px;border-radius:18px;background:var(--card)}
.sws button{aspect-ratio:1;border-radius:50%}
.field{display:flex;align-items:center;gap:12px;margin-top:16px;min-height:56px;padding:0 16px;border-radius:16px;background:var(--card)}
.field span{color:var(--t2)}
.field input{flex:1;min-width:0;background:transparent;border:0;outline:none;text-align:right;font-size:17px;font-weight:600}

/* ---- bienvenue ---- */
.welcome{min-height:100vh;display:flex;flex-direction:column;padding:calc(50px + var(--safe-t)) 22px calc(30px + var(--safe-b));max-width:520px;margin:0 auto;text-align:center}
.welcome h1{margin:30px 0 8px;font-size:32px;font-weight:800}
.welcome p{margin:0 6px;color:var(--t2);font-size:16px;line-height:1.45}
.ping{position:relative;width:120px;height:120px;margin:0 auto;display:grid;place-items:center}
.ping:before,.ping:after{content:"";position:absolute;inset:0;border-radius:50%;border:2px solid #ff9f0a;animation:ping 1.8s ease-out infinite}
.ping:after{border-color:#ff375f;animation-delay:.9s}
.ping i{width:74px;height:74px;border-radius:50%;background:radial-gradient(circle at 35% 30%,#fff3e0 0%,#ffb340 35%,#ff375f 75%,#5a1030 100%);box-shadow:0 0 40px #ff375f}
.cta{min-height:56px;border-radius:16px;background:#fff;color:#1b1c20;font-size:17px;font-weight:700;width:100%}
.cta:disabled{opacity:.4}
.cta.ghost{background:var(--card);color:#fff}
.spin{width:18px;height:18px;border-radius:50%;border:2px solid #555;border-top-color:#fff;animation:sp .8s linear infinite;flex:none}
@keyframes sp{to{transform:rotate(360deg)}}
pre.logs{white-space:pre-wrap;font-size:12px;line-height:1.45;color:#d1d1d6;background:#141518;border-radius:14px;padding:12px;max-height:60vh;overflow:auto;margin:0}
</style>
</head>
<body>

<!-- ============ PREMIER LANCEMENT ============ -->
<div id="welcome" class="welcome hidden">
  <div id="wStep0">
    <div class="ping"><i></i></div>
    <h1>Bienvenue dans Lueur</h1>
    <p>Tes lumières suivent la musique que tu envoies en AirPlay. On commence par trouver ton pont d'éclairage.</p>
    <div class="list" style="border-radius:18px;margin-top:26px;text-align:left" id="wBridges"></div>
    <div id="wManual" class="field hidden"><span>Adresse IP</span><input id="wIp" inputmode="decimal" placeholder="192.168.1.20" autocomplete="off"></div>
    <div style="display:flex;justify-content:center;gap:18px;margin-top:10px">
      <button class="txtbtn" id="wAgain">Rechercher à nouveau</button>
      <button class="txtbtn" id="wManualBtn">Saisir l'adresse</button>
    </div>
  </div>
  <div id="wStep1" class="hidden">
    <div style="position:relative;width:170px;height:170px;margin:10px auto 0;display:grid;place-items:center">
      <svg width="170" height="170" viewBox="0 0 170 170" style="position:absolute;inset:0;transform:rotate(-90deg)"><circle cx="85" cy="85" r="80" fill="none" stroke="#34353a" stroke-width="6"/><circle id="wRing" cx="85" cy="85" r="80" fill="none" stroke="#64d2ff" stroke-width="6" stroke-linecap="round" stroke-dasharray="503" stroke-dashoffset="0"/></svg>
      <span style="width:116px;height:116px;border-radius:30px;background:linear-gradient(160deg,#f2f2f7,#c7c7cc);display:grid;place-items:center"><span style="width:46px;height:46px;border-radius:50%;background:#e5e5ea;box-shadow:inset 0 2px 4px rgba(0,0,0,.25)"></span></span>
    </div>
    <div id="wCount" style="margin-top:14px;color:#64d2ff;font-weight:600">30 s</div>
    <h1>Appuie sur le bouton du pont</h1>
    <p id="wMsg">Le gros bouton rond au centre du pont.</p>
  </div>
  <div style="flex:1"></div>
  <button class="cta" id="wGo" disabled>Continuer</button>
</div>

<!-- ============ APPLICATION ============ -->
<div id="app" class="app hidden">

  <!-- SYNCHRO -->
  <section class="view" data-view="sync">
    <div class="syhead">
      <button class="zonebtn" id="zoneBtn" aria-haspopup="true">
        <b><span id="zoneName">Zone</span><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#a9aab0" stroke-width="3" stroke-linecap="round"><path d="M6 9l6 6 6-6"/></svg></b>
        <small><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linejoin="round"><path d="M5 17H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2h-1"/><path d="M12 15l5 6H7z"/></svg>AirPlay · <span id="apNameSmall">Lueur</span></small>
      </button>
    </div>
    <div class="stage">
      <div class="coverwrap" id="coverWrap"><div class="halo" id="coverHalo"></div>
        <div class="cover" id="cover"><div class="glow" id="coverGlow"></div><div class="lights" id="coverLights"></div><img id="coverImg" alt=""></div></div>
      <div class="stitle" id="sTitle">En attente de musique</div>
      <div class="ssub"><i class="dot" id="sDot"></i><span id="sSub">Choisis « Lueur » dans AirPlay</span></div>
      <div class="pbar hidden" id="pBar"><div class="tr"><i id="pFill"></i></div><div class="tm"><span id="pCur">0:00</span><span id="pDur">0:00</span></div></div>
      <button class="pchip hidden" id="pChip" data-sheet="shCouleur"><span class="sw4" id="pChipSw"></span>Couleurs tirées de la pochette</button>
    </div>
    <div class="ctrls">
      <button class="ctrl" data-sheet="shEffet"><span class="ci"><svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round"><path d="M3 12h2M7 8v8M11 5v14M15 9v6M19 11v2"/></svg></span><small>Effet</small><em id="cEffet">—</em></button>
      <button class="ctrl" data-sheet="shInt"><span class="ci"><svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M13 2L4 14h7l-1 8 9-12h-7z"/></svg></span><small>Intensité</small><em id="cInt">—</em></button>
      <button class="ctrl" data-sheet="shCouleur"><span class="ci" id="cPalOrb"></span><small>Couleur</small><em id="cPal">—</em></button>
      <button class="ctrl" data-sheet="shLum"><span class="ci"><svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg></span><small>Luminosité</small><em id="cLum">—</em></button>
    </div>
    <div class="dock">
      <button class="side" id="advOpen"><svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round"><path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/></svg>AVANCÉS</button>
      <button class="power" id="powerBtn" aria-label="Synchro"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M12 3v8"/><path d="M6.4 6.4a8 8 0 1 0 11.2 0"/></svg></button>
      <button class="side" id="lampsOpen"><svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18h6M10 21h4M12 3a6 6 0 0 0-4 10.5c.7.7 1 1.5 1 2.5h6c0-1 .3-1.8 1-2.5A6 6 0 0 0 12 3z"/></svg>LAMPES<span id="lampsCount">—</span></button>
    </div>
  </section>

  <!-- RÉGLAGES AVANCÉS -->
  <section class="view" data-view="avances">
    <div class="nh"><button class="rb" data-back aria-label="Retour"><svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M20 12H5M11 5l-7 7 7 7"/></svg></button><span class="t">Réglages avancés</span><button class="txtbtn" id="advReset">Rétablir</button></div>
    <div class="pad" style="padding-top:6px;color:var(--t2);font-size:15px;padding-left:20px" id="advStatus"></div>
    <div class="stagebox" id="stage"><div class="h"><span class="label" style="padding:0">Aperçu</span><span style="color:var(--t2);font-size:12px;display:flex;align-items:center;gap:6px"><i class="dot on"></i><span id="prevSub"></span></span></div><div class="prev" id="prev"></div></div>
    <div class="pad">
      <div class="label in">Effet</div>
      <div class="grid2" id="advEffects"></div>
      <div id="advFolds"></div>
    </div>
  </section>

  <!-- LUMIÈRES -->
  <section class="view" data-view="lumieres">
    <h1 class="big">Lumières</h1>
    <div class="rooms" id="rooms"><div class="note" style="padding:0 8px">Chargement des pièces…</div></div>
  </section>

  <!-- PIÈCE -->
  <section class="view" data-view="piece"><div id="piece"></div></section>

  <!-- COULEUR D'UNE LAMPE -->
  <section class="view" data-view="lampe"><div id="lampe"></div></section>

  <!-- CRÉER UNE PALETTE -->
  <section class="view" data-view="creer"><div id="creer"></div></section>

  <!-- RÉGLAGES -->
  <section class="view" data-view="reglages">
    <h1 class="big">Réglages</h1>
    <div class="label">Lumières</div>
    <div class="list">
      <button class="row" id="bridgeRow"><span class="ic" data-i="pont"></span><span class="bd"><span class="tx"><span class="t1">Pont d'éclairage</span><span class="t2" id="bridgeSub">—</span></span><svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M9 6l6 6-6 6"/></svg></span></button>
      <button class="row" id="lampsRow"><span class="ic" data-i="zones"></span><span class="bd"><span class="tx"><span class="t1">Lampes de la synchro</span><span class="t2" id="lampsSub">Zone utilisée pour la musique</span></span><svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M9 6l6 6-6 6"/></svg></span></button>
      <button class="row" id="syncRow" role="switch"><span class="ic" data-i="sync"></span><span class="bd"><span class="tx"><span class="t1">Synchro active</span><span class="t2" id="syncSub">—</span></span><span class="sw" id="syncSw"><i></i></span></span></button>
    </div>
    <div class="label">Son · AirPlay</div>
    <div class="list">
      <label class="row"><span class="ic" data-i="airplay"></span><span class="bd"><span class="tx"><span class="t1">Nom AirPlay</span></span><input class="val" id="apName" maxlength="40" autocomplete="off"></span></label>
      <label class="row"><span class="ic" data-i="pause"></span><span class="bd"><span class="tx"><span class="t1">Pause après silence</span><span class="t2">Rend les lampes à l'app d'éclairage</span></span>
        <select class="val" id="idle"><option value="0">Jamais</option><option value="5">5 s</option><option value="15">15 s</option><option value="30">30 s</option><option value="60">1 min</option><option value="300">5 min</option></select></span></label>
    </div>
    <p class="note" id="apNote"></p>
    <div class="label">Son · Enceinte Bluetooth</div>
    <div class="list" id="bt"></div>
    <div class="list" id="btOffset" style="margin-top:1px"><div class="row" style="align-items:flex-start;padding:16px 0 12px"><span class="ic" data-i="delay"></span><span style="flex:1;padding-right:22px"><span style="display:flex;justify-content:space-between"><span class="t1" style="font-size:18px;font-weight:600">Décalage des lumières</span><span class="val" id="offPct" style="color:var(--t2)">300 ms</span></span><div class="sl" id="offSl" style="margin:10px 0 6px"><div class="tr"></div><div class="fi"></div><div class="kn"></div></div><span style="color:var(--t3);font-size:14px">Augmente si les lampes sont en avance sur le son de l'enceinte.</span></span></div></div>
    <p class="note" id="btMsg"></p>
    <div class="label">Système</div>
    <div class="list">
      <button class="row" id="logsRow"><span class="ic" data-i="journal"></span><span class="bd"><span class="tx"><span class="t1">Journal</span><span class="t2">Ce que fait la synchro en ce moment</span></span><svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M9 6l6 6-6 6"/></svg></span></button>
      <button class="row" id="redoRow"><span class="ic" data-i="redo"></span><span class="bd"><span class="tx"><span class="t1">Refaire la configuration</span><span class="t2">Rechercher et appairer le pont</span></span><svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M9 6l6 6-6 6"/></svg></span></button>
    </div>
    <div style="display:flex;flex-direction:column;align-items:center;gap:10px;margin:40px 0 20px;text-align:center">
      <span style="width:64px;height:64px;border-radius:18px;background:var(--card);display:grid;place-items:center"><span style="width:30px;height:30px;border-radius:50%;background:radial-gradient(circle at 40% 35%,#ffd27a,#ff6a3d 55%,#ff375f)"></span></span>
      <span style="font-weight:600">Lueur</span>
      <span style="color:var(--t3);font-size:13px;line-height:1.5">Récepteur AirPlay 2 pour éclairage connecté<br>Projet personnel, sans lien avec Signify ni Apple.</span>
    </div>
  </section>

  <nav class="tabs" aria-label="Onglets"><div class="in">
    <button data-tab="sync"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><path d="M3 12h2M7 8v8M11 5v14M15 9v6M19 11v2"/></svg>Synchro</button>
    <button data-tab="lumieres"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18h6M10 21h4M12 3a6 6 0 0 0-4 10.5c.7.7 1 1.5 1 2.5h6c0-1 .3-1.8 1-2.5A6 6 0 0 0 12 3z"/></svg>Lumières</button>
    <button data-tab="reglages"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1M2 12h3M19 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1"/></svg>Réglages</button>
  </div></nav>
</div>

<!-- ============ FEUILLES ============ -->
<div class="bg" id="sheetBg"></div>
<div class="sheet" id="shEffet"><div class="grab"></div><div class="sh"><b>Effet</b><button class="txtbtn" data-close>OK</button></div><div class="grid2" id="effList"></div>
  <button class="row" id="effAdv" style="margin-top:14px;background:var(--card2);border-radius:16px;min-height:62px"><span class="ic" style="width:60px" data-i="sliders"></span><span class="bd" style="border:0"><span class="tx"><span class="t1" style="font-size:16px">Réglages avancés</span><span class="t2" style="font-size:13px">Rythme, flashs, couleurs, motif</span></span><svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M9 6l6 6-6 6"/></svg></span></button></div>
<div class="sheet" id="shInt"><div class="grab"></div><div class="sh"><b>Intensité</b><button class="txtbtn" data-close>OK</button></div><div id="intList" class="list" style="border-radius:18px;background:var(--card2)"></div><p class="note" style="padding:12px 4px 0" id="intNote"></p></div>
<div class="sheet" id="shCouleur"><div class="grab"></div><div class="sh"><b>Couleur</b><button class="txtbtn" data-close>OK</button></div><div class="grid3" id="palList"></div><p class="note" style="padding:12px 4px 0">« Créer » : depuis une photo ou en choisissant les couleurs. La palette peut aussi servir de scène dans tes pièces.</p></div>
<div class="sheet" id="shLum"><div class="grab"></div><div class="sh"><b>Luminosité</b><button class="txtbtn" data-close>OK</button></div>
  <div style="display:flex;justify-content:space-between;margin:0 4px"><span>Luminosité maximale</span><span id="lumPct" style="color:var(--t2)">100 %</span></div>
  <div class="sl" id="lumSl" style="margin:12px 4px 4px"><div class="tr"></div><div class="fi"></div><div class="kn"></div></div>
  <p class="note" style="padding:8px 4px 0">Plafond de luminosité pendant la synchro. Les flashs ne dépassent jamais cette valeur.</p></div>
<div class="sheet" id="shZone"><div class="grab"></div><div class="sh"><b>Synchroniser</b><button class="txtbtn" data-close>OK</button></div><div class="list" id="zoneList" style="border-radius:18px;background:var(--card2)"></div>
  <button class="cta ghost" id="zoneLamps" style="margin-top:14px">Choisir mes lampes…</button>
  <p class="note" style="padding:12px 4px 0">Les zones viennent de ton pont. « Choisir mes lampes » crée ou modifie la zone « Hue Sync ».</p></div>
<div class="sheet" id="shLampes"><div class="grab"></div><div class="sh"><b>Lampes de la synchro</b><button class="txtbtn" data-close>Annuler</button></div><div id="lightList"></div>
  <div style="display:flex;align-items:center;gap:12px;margin-top:16px"><span id="lightCount" style="flex:1;color:var(--t2)"></span><button class="cta" id="lightSave" style="width:auto;padding:0 26px">Enregistrer</button></div></div>
<div class="sheet" id="shLogs"><div class="grab"></div><div class="sh"><b>Journal</b><button class="txtbtn" data-close>OK</button></div><pre class="logs" id="logs"></pre></div>
<div class="toast" id="toast" role="status" aria-live="polite"></div>
<input type="file" id="palFile" accept="image/*" class="hidden">

<script>
"use strict";
const $ = s => document.querySelector(s), $$ = s => [...document.querySelectorAll(s)];
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

/* =================== ICÔNES =================== */
const IC = {
  classic: 'M9 18h6M10 21h4M12 3a6 6 0 0 0-4 10.5c.7.7 1 1.5 1 2.5h6c0-1 .3-1.8 1-2.5A6 6 0 0 0 12 3z',
  filament: 'M9 18h6M10 21h4M12 3a6 6 0 0 0-4 10.5c.7.7 1 1.5 1 2.5h6c0-1 .3-1.8 1-2.5A6 6 0 0 0 12 3zM10 9l1 2 1-2 1 2 1-2M12 11v5',
  spot: 'M7.5 4h9l-2 7h-5zM9.5 11c0 3.5 1.1 6 2.5 6s2.5-2.5 2.5-6M10 20.5h4',
  strip: 'M2.5 15c3-7 6.3-7 9.5 0s6.5 7 9.5 0',
  bar: 'M3 9.5h18v4H3zM7 13.5v5M17 13.5v5M5.5 18.5h3M15.5 18.5h3',
  bloom: 'M12 4a6.5 6.5 0 1 1 0 13 6.5 6.5 0 0 1 0-13zM8 20.5h8M10 17v3.5M14 17v3.5',
  ceiling: 'M3 8h18M5 8c0 4.4 3.1 7 7 7s7-2.6 7-7M12 4v4M9.5 18.5l-1 1.5M14.5 18.5l1 1.5',
  pendant: 'M12 2v6M5.5 15a6.5 6.5 0 0 1 13 0zM10 18a2 2 0 0 0 4 0',
  floor: 'M8.5 3h7l2 6h-11zM12 9v11M8 21h8',
  table: 'M8 4h8l3 7.5H5zM12 11.5v6.5M8 21h8M10 18h4',
  wall: 'M4 4v16M4 12h4M8 8h8.5l-2 8H10zM12 16v2.5',
  candle: 'M12 3c1.3 1.8 2 3 2 4.3a2 2 0 0 1-4 0C10 6 10.7 4.8 12 3zM9.5 10.5h5V21h-5z',
  outdoor: 'M8.5 3h7v6.5h-7zM12 9.5V20M8 21h8M10 6.2h4',
  tv: 'M3 5h18v12H3zM8 21h8M12 17v4',
  "room-salon": 'M4 11V8a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v3M3 13a2 2 0 0 1 4 0v2h10v-2a2 2 0 0 1 4 0v5H3zM5 18v2M19 18v2',
  "room-chambre": 'M3 18V6M21 18v-5a3 3 0 0 0-3-3h-8v5M3 13h18M3 18h18M7 10.5a1.5 1.5 0 1 0 0 .01',
  "room-bureau": 'M3 10h18M5 10v10M19 10v10M13 10v5h6M9 3h6v4H9zM12 7v3',
  "room-cuisine": 'M4 10h16v10H4zM4 14h16M8 6c0-1 1-1 1-2M12 6c0-1 1-1 1-2M16 6c0-1 1-1 1-2',
  "room-sdb": 'M3 12h18v3a5 5 0 0 1-5 5H8a5 5 0 0 1-5-5zM6 12V5a2 2 0 0 1 4 0M7 20l-1 1.5M17 20l1 1.5',
  "room-entree": 'M6 21V4h12v17M3 21h18M14.5 12.5v.01',
  "room-repas": 'M3 10h18M6 10v10M18 10v10M8 6h8M10 3v3M14 3v3',
  "room-exterieur": 'M12 3l5 7h-3l4 6H6l4-6H7zM12 16v5M8 21h8',
  pont: 'M3 3h18v18H3zM12 8.4a3.6 3.6 0 1 0 0 7.2 3.6 3.6 0 0 0 0-7.2',
  zones: 'M12 3l9 5-9 5-9-5zM3 13l9 5 9-5',
  sync: 'M3 12h2M7 8v8M11 5v14M15 9v6M19 11v2',
  airplay: 'M5 17H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2h-1M12 15l5 6H7z',
  pause: 'M12 5a8 8 0 1 0 0 16 8 8 0 0 0 0-16M12 9v4l2.5 2.5M9 2h6',
  speaker: 'M5 2.5h14v19H5zM12 10.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7M12 6v.01',
  plus: 'M12 5v14M5 12h14',
  delay: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18M12 7v5l3 2',
  journal: 'M6 3h9l4 4v14H6zM9 11h7M9 15h7M9 7h3',
  redo: 'M3 12a9 9 0 1 0 3-6.7L3 8M3 3v5h5',
  sliders: 'M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0M16 4v4M10 10v4M18 16v4',
  power: 'M12 3v8M6.4 6.4a8 8 0 1 0 11.2 0'
};
const icon = (k, size = 28, color = "currentColor", w = 1.9) =>
  `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="${color}" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${IC[k] || IC.classic}"/></svg>`;
function lampKind(a) {
  a = (a || "").toLowerCase();
  if (/strip|tube|signe|lightstrip/.test(a)) return "strip";
  if (/play/.test(a)) return "bar";
  if (/bloom|iris|hue_go|go$/.test(a)) return "bloom";
  if (/spot/.test(a)) return "spot";
  if (/candle/.test(a)) return "candle";
  if (/vintage|filament|luster|edison/.test(a)) return "filament";
  if (/pendant/.test(a)) return "pendant";
  if (/ceiling|recessed|centris/.test(a)) return "ceiling";
  if (/floor/.test(a)) return "floor";
  if (/table|flexible|desk/.test(a)) return "table";
  if (/bollard|lantern|ground|garden|pedestal/.test(a)) return "outdoor";
  if (/wall/.test(a)) return "wall";
  return "classic";
}
function roomKind(a, name) {
  const s = ((a || "") + " " + (name || "")).toLowerCase();
  if (/living|salon|lounge|tv/.test(s)) return "room-salon";
  if (/bed|chambre|kids|nursery|guest/.test(s)) return "room-chambre";
  if (/office|bureau|studio|computer/.test(s)) return "room-bureau";
  if (/kitchen|cuisine/.test(s)) return "room-cuisine";
  if (/bath|toilet|sdb|salle de bain|wc/.test(s)) return "room-sdb";
  if (/dining|repas|manger/.test(s)) return "room-repas";
  if (/hall|door|entr|stair|couloir|corridor/.test(s)) return "room-entree";
  if (/garden|terrace|balcon|patio|garage|ext|carport|pool/.test(s)) return "room-exterieur";
  return "room-salon";
}
$$("[data-i]").forEach(el => el.innerHTML = icon(el.dataset.i));

/* =================== COULEURS =================== */
const hexRgb = h => { const n = parseInt(h.slice(1), 16); return [n >> 16 & 255, n >> 8 & 255, n & 255]; };
const rgbHex = c => "#" + c.map(v => ("0" + Math.round(Math.max(0, Math.min(255, v))).toString(16)).slice(-2)).join("");
const lum = h => { const c = hexRgb(h); return (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255; };
const lighten = (h, k) => rgbHex(hexRgb(h).map(v => v + (255 - v) * k));
function mix(pal, t, cyc) {
  let c = pal.map(hexRgb); if (cyc) c = c.concat([c[0]]);
  t = Math.max(0, Math.min(0.9999, t)); const f = t * (c.length - 1), i = Math.floor(f), k = f - i, a = c[i], b = c[i + 1] || a;
  return rgbHex([0, 1, 2].map(j => a[j] + (b[j] - a[j]) * k));
}
function boost(h, floor = 170) { const c = hexRgb(h), m = Math.max(...c, 1), k = Math.max(1, floor / m); return rgbHex(c.map(v => v * k)); }
const orbBg = c => { const p = c.concat(c, c).slice(0, 4).map(x => boost(x, 140)); return `radial-gradient(circle at 35% 30%, ${lighten(p[0], .45)} 0%, ${p[1]} 32%, ${p[2]} 68%, ${p[3]} 100%)`; };

/* =================== ÉTAT & API =================== */
let S = null, live = { state: "offline", colors: [] }, zones = null, ROOMS = null, BT = null;
let pending = {}, sendTimer = null, lockUntil = 0;
const INT = { subtle: "Subtile", moderate: "Modérée", high: "Élevée", intense: "Intense" };
const INT_D = { subtle: "Doux et lent, les couleurs fondent les unes dans les autres.", moderate: "Suit le rythme sans éblouir.", high: "Flashs francs sur chaque temps, lampes en alternance.", intense: "Le plus nerveux : chenillard et flashs blancs sur les drops." };
const PAL_N = { sunset: "Coucher", ocean: "Océan", neon: "Néon", fire: "Feu", forest: "Forêt", party: "Fête", ice: "Glace" };
const EFFECTS = [
  ["pulse", "Pulsation", "Tout bat ensemble sur le rythme", true],
  ["spectrum", "Spectre étalé", "Graves d'un côté, aigus de l'autre", true],
  ["comete", "Comète", "Une traînée court le long du ruban", false],
  ["vague", "Vague", "La palette défile, sans flash", false],
  ["vumetre", "Vu-mètre", "Se remplit avec le volume", false],
  ["stereo", "Stéréo", "Gauche et droite séparées", false],
  ["etincelles", "Étincelles", "Éclats au hasard sur les aigus", false],
  ["respiration", "Respiration", "Monte et descend doucement", false]
];

async function api(path, body) {
  const opt = body === undefined ? {} : { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) };
  const r = await fetch(path, opt);
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || j.message || ("Erreur " + r.status));
  return j;
}
function toast(m) { const t = $("#toast"); t.textContent = m; t.classList.add("show"); clearTimeout(toast.t); toast.t = setTimeout(() => t.classList.remove("show"), 2300); }
function save(patch, now) {
  Object.assign(pending, patch); Object.assign(S.settings, patch); lockUntil = Date.now() + 2500;
  clearTimeout(sendTimer);
  sendTimer = setTimeout(async () => { const b = pending; pending = {}; try { await api("/api/settings", b); } catch (e) { toast("Échec : " + e.message); } }, now ? 0 : 280);
}
function store(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
function load(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
function allPalettes() {
  const now = S.now || {}, cc = now.colors && now.colors.length >= 2 ? now.colors : null;
  const cover = { id: "cover", name: "Pochette", colors: cc || ["#3a3b40", "#6e6f75", "#a9aab0"], builtin: true, auto: true, scenes: !!cc, synchro: true };
  const b = [cover].concat(Object.entries(S.palettes).map(([id, colors]) => ({ id, name: PAL_N[id] || id, colors, builtin: true, scenes: true, synchro: true })));
  return b.concat((S.custom_palettes || []).map(p => ({ ...p, scenes: p.scenes !== false, synchro: p.synchro !== false })));
}
function palColors(id) { const p = allPalettes().find(x => x.id === id); return p ? p.colors : S.palettes.sunset; }
function palName(id) { const p = allPalettes().find(x => x.id === id); return p ? p.name : id; }

/* =================== CURSEURS =================== */
function slider(el, onValue, onEnd) {
  let drag = false;
  const at = e => { const r = el.getBoundingClientRect(); onValue(Math.max(0, Math.min(1, (e.clientX - r.left) / r.width))); };
  el.addEventListener("pointerdown", e => { drag = true; el.setPointerCapture(e.pointerId); at(e); });
  el.addEventListener("pointermove", e => drag && at(e));
  const end = () => { if (drag && onEnd) onEnd(); drag = false; };
  el.addEventListener("pointerup", end); el.addEventListener("pointercancel", end);
}
function setSl(el, t) { t = Math.max(0, Math.min(1, t)); el.querySelector(".fi").style.width = t * 100 + "%"; el.querySelector(".kn").style.left = t * 100 + "%"; }

/* =================== NAVIGATION =================== */
const TAB_OF = { sync: "sync", avances: "sync", lumieres: "lumieres", piece: "lumieres", lampe: "lumieres", creer: "lumieres", reglages: "reglages" };
let route = { v: "sync", arg: "" }, backTo = [];
function go(v, arg = "", push = true) {
  if (push && route.v !== v) backTo.push({ ...route });
  route = { v, arg };
  $$(".view").forEach(x => x.classList.toggle("on", x.dataset.view === v));
  $$(".tabs button").forEach(b => b.classList.toggle("on", b.dataset.tab === TAB_OF[v]));
  if (["sync", "lumieres", "reglages"].includes(v)) store("tab", v);
  window.scrollTo(0, 0);
  render();
}
function back() { const p = backTo.pop(); if (p) go(p.v, p.arg, false); else go(TAB_OF[route.v] || "sync", "", false); }
$$(".tabs button").forEach(b => b.onclick = () => { backTo = []; go(b.dataset.tab, "", false); });
document.addEventListener("click", e => { if (e.target.closest("[data-back]")) back(); });
function render() {
  if (!S) return;
  const v = route.v;
  if (v === "sync") renderSync();
  if (v === "avances") renderAdv();
  if (v === "lumieres") renderRooms();
  if (v === "piece") renderPiece();
  if (v === "lampe") renderLampe();
  if (v === "creer") renderCreer();
  if (v === "reglages") renderReglages();
}

/* =================== FEUILLES =================== */
function openSheet(id) { $("#sheetBg").classList.add("open"); $("#" + id).classList.add("open"); renderSheets(); }
function closeSheets() { $("#sheetBg").classList.remove("open"); $$(".sheet").forEach(s => s.classList.remove("open")); }
$("#sheetBg").onclick = closeSheets;
$$("[data-close]").forEach(b => b.onclick = closeSheets);
$$("[data-sheet]").forEach(b => b.onclick = () => openSheet(b.dataset.sheet));
function renderSheets() {
  if (!S) return;
  const st = S.settings;
  $("#effList").innerHTML = EFFECTS.map(([k, n, d, ok]) => `<button class="tile ${st.mode === k ? "on" : ""}" data-eff="${k}" ${ok ? "" : "disabled"}>
    ${effStrip(k, palColors(st.palette), 10)}<span class="n">${n}</span><span class="d ${ok ? "" : "soon"}">${ok ? d : "Bientôt"}</span></button>`).join("");
  $$("[data-eff]").forEach(b => b.onclick = () => { save({ mode: b.dataset.eff }, true); renderSheets(); renderSync(); });
  $("#intList").innerHTML = Object.keys(INT).map(k => `<button class="row" data-int="${k}" style="min-height:66px"><span class="bd" style="padding-left:16px"><span class="tx"><span class="t1" style="font-size:17px">${INT[k]}</span><span class="t2" style="font-size:13px">${INT_D[k]}</span></span><span style="width:22px;color:var(--blue);font-weight:700">${st.intensity === k ? "✓" : ""}</span></span></button>`).join("");
  $$("[data-int]").forEach(b => b.onclick = () => { S.settings.fx = {}; delete pending.fx; save({ intensity: b.dataset.int }, true); renderSheets(); renderSync(); });
  const nfx = Object.keys(st.fx || {}).length;
  $("#intNote").textContent = nfx ? `${nfx} réglage${nfx > 1 ? "s" : ""} avancé${nfx > 1 ? "s" : ""} modifié${nfx > 1 ? "s" : ""}. Choisir une intensité les remet à zéro.` : "";
  $("#palList").innerHTML = allPalettes().filter(p => p.synchro).map(p => orbTile(p.name, p.colors, p.id === st.palette, `data-pal="${p.id}"`, p.auto ? "AUTO" : "")).join("") + orbTile("Créer", null, false, 'data-newpal="sync"');
  $$("[data-pal]").forEach(b => b.onclick = () => { save({ palette: b.dataset.pal }, true); renderSheets(); renderSync(); });
  $$("[data-newpal]").forEach(b => b.onclick = () => { closeSheets(); openCreer(b.dataset.newpal); });
  setSl($("#lumSl"), (st.brightness - 0.05) / 0.95); $("#lumPct").textContent = Math.round(st.brightness * 100) + " %";
  renderZoneMenu();
}
slider($("#lumSl"), t => { const v = Math.round((0.05 + t * 0.95) * 100) / 100; setSl($("#lumSl"), t); $("#lumPct").textContent = Math.round(v * 100) + " %"; save({ brightness: v }); renderSync(); });
$("#effAdv").onclick = () => { closeSheets(); go("avances"); };

function orbTile(name, colors, on, attrs, badge) {
  const o = colors ? `<span class="o" style="background:${orbBg(colors)};box-shadow:0 6px 18px ${boost(colors[Math.min(2, colors.length - 1)])}66"></span>` : `<span class="o dash">+</span>`;
  return `<button class="orb ${on ? "on" : ""}" ${attrs}>${badge ? `<b class="auto">${badge}</b>` : ""}${o}<span>${esc(name)}</span></button>`;
}

/* =================== APERÇU D'EFFET (bandeau) =================== */
function effStrip(fx, pal, n) {
  const rnd = [0, .62, .21, .9, .4, .75, .12, .55, .33, .82, .05, .68];
  let h = `<span style="display:flex;gap:3px;height:16px;width:100%">`;
  for (let i = 0; i < n; i++) {
    const c = boost(pal[Math.floor(i / n * pal.length) % pal.length], 180);
    let a = "none";
    if (fx === "pulse") a = "fl .6s infinite";
    else if (fx === "spectrum") a = `bar ${(.45 + rnd[i % 12] * .5).toFixed(2)}s ${(-rnd[(i + 3) % 12]).toFixed(2)}s ease-in-out infinite alternate`;
    else if (fx === "comete") a = `fl 1.4s ${(i * .07).toFixed(2)}s infinite`;
    else if (fx === "vague") a = `hue 4s linear ${(-i * .35).toFixed(2)}s infinite`;
    else if (fx === "vumetre") a = `fl 1.6s ${(i * .06).toFixed(2)}s infinite`;
    else if (fx === "stereo") a = `fl .9s ${i < n / 2 ? 0 : .45}s infinite`;
    else if (fx === "etincelles") a = `fl 1.3s ${(rnd[i % 12] * 1.3).toFixed(2)}s infinite`;
    else if (fx === "respiration") a = "br 3.2s ease-in-out infinite";
    h += `<i style="flex:1;border-radius:3px;background:${c};box-shadow:0 0 8px ${c}88;--hi:1;--lo:.25;animation:${a}"></i>`;
  }
  return h + "</span>";
}

/* =================== SYNCHRO =================== */
function currentZone() {
  if (!zones || zones.error || !zones.length) return null;
  const cur = S.settings.area || live.area_id;
  return zones.find(z => z.id === cur || z.name === cur) || zones[0];
}
function renderSync() {
  const st = S.settings, z = currentZone(), active = S.service.active, syncing = live.state === "syncing";
  $("#zoneName").textContent = z ? z.name : (zones && zones.error ? "Aucune zone" : "Zone");
  $("#apNameSmall").textContent = S.airplay_name;
  $("#lampsCount").textContent = z ? `${z.lights} lampe${z.lights > 1 ? "s" : ""}` : "—";
  $("#cEffet").textContent = st.mode === "spectrum" ? "Spectre" : "Pulsation";
  $("#cInt").textContent = INT[st.intensity] + (Object.keys(st.fx || {}).length ? " *" : "");
  $("#cPal").textContent = palName(st.palette);
  $("#cPalOrb").style.background = orbBg(palColors(st.palette));
  $("#cLum").textContent = Math.round(st.brightness * 100) + " %";
  $("#powerBtn").classList.toggle("on", active);
  $("#powerBtn").setAttribute("aria-label", active ? "Arrêter la synchro" : "Démarrer la synchro");
  $("#sDot").classList.toggle("on", syncing);
  const np = S.now || {}, track = active && np.has && np.title;
  $("#sTitle").textContent = track ? np.title : !active ? "Synchro arrêtée" : syncing ? "Synchro en cours" : "En attente de musique";
  $("#sSub").textContent = track ? [np.artist, np.album].filter(Boolean).join(" · ") || (z && z.name) || ""
    : !active ? "Touche le bouton pour la démarrer" : syncing ? `${live.area || (z && z.name) || ""} · ${palName(st.palette)}` : `Choisis « ${S.airplay_name} » dans AirPlay`;
  const art = active && np.cover;
  if (art && $("#coverImg").dataset.id !== np.cover) { $("#coverImg").dataset.id = np.cover; $("#coverImg").src = "/api/cover?" + np.cover; }
  $("#coverWrap").classList.toggle("art", !!art);
  const auto = st.palette === "cover" && np.colors && np.colors.length >= 2 && active && np.has;
  $("#pChip").classList.toggle("hidden", !auto);
  if (auto) $("#pChipSw").innerHTML = np.colors.map(c => `<i style="background:${c}"></i>`).join("");
  renderProgress();
  renderCover();
}
function renderCover() {
  const pal = palColors(S.settings.palette), syncing = live.state === "syncing";
  const cols = syncing && live.colors && live.colors.length ? live.colors : pal;
  const lights = $("#coverLights"), n = cols.length;
  if (lights.children.length !== n) lights.innerHTML = cols.map((_, i) => { const a = -Math.PI / 2 + i / n * 2 * Math.PI, r = n > 1 ? 28 : 0; return `<i style="left:${50 + Math.cos(a) * r}%;top:${50 + Math.sin(a) * r}%"></i>`; }).join("");
  [...lights.children].forEach((d, i) => {
    const c = cols[i], l = Math.max(...hexRgb(c)) / 255, b = boost(c, 200);
    d.style.background = syncing ? b : boost(c, 150);
    d.style.boxShadow = syncing ? `0 0 ${8 + l * 26}px ${b}` : "none";
    d.style.transform = `scale(${syncing ? .8 + l * .5 : 1})`;
    d.style.opacity = syncing ? .4 + l * .6 : .55;
  });
  const g = cols.slice(0, 4).map(c => boost(c, 160));
  $("#coverGlow").style.background = `radial-gradient(circle at 30% 30%, ${g[0]} 0%, transparent 55%), radial-gradient(circle at 75% 70%, ${g[1] || g[0]} 0%, transparent 55%), radial-gradient(circle at 70% 25%, ${g[2] || g[0]} 0%, transparent 50%), #111`;
  $("#coverGlow").style.opacity = syncing ? 1 : .55;
  const ha = c => c + "99";      // halo doux, sans bord : chaque dégradé s'éteint à l'intérieur de sa boîte
  $("#coverHalo").style.background = `radial-gradient(closest-side at 38% 40%, ${ha(g[0])}, transparent), radial-gradient(closest-side at 62% 62%, ${ha(g[1] || g[0])}, transparent), radial-gradient(closest-side at 62% 36%, ${ha(g[2] || g[0])}, transparent), radial-gradient(closest-side at 40% 64%, ${ha(g[3] || g[1] || g[0])}, transparent)`;
}
let nowAt = 0;
const mmss = t => { t = Math.max(0, Math.floor(t)); return Math.floor(t / 60) + ":" + String(t % 60).padStart(2, "0"); };
function renderProgress() {
  const np = S && S.now, ok = np && np.has && np.dur && np.pos != null && S.service.active;
  $("#pBar").classList.toggle("hidden", !ok);
  if (!ok) return;
  const pos = Math.min(np.dur, np.pos + (np.playing ? (Date.now() - nowAt) / 1000 : 0));
  $("#pFill").style.width = (pos / np.dur * 100).toFixed(2) + "%";
  $("#pCur").textContent = mmss(pos); $("#pDur").textContent = "-" + mmss(np.dur - pos);
}
function setNow(n) { if (n) { S.now = n; nowAt = Date.now(); } }
$("#powerBtn").onclick = async () => {
  const on = !S.service.active; $("#powerBtn").classList.add("busy"); lockUntil = Date.now() + 4000;
  try { await api("/api/power", { on }); toast(on ? "Synchro démarrée" : "Synchro arrêtée"); } catch (e) { toast("Échec : " + e.message); }
  $("#powerBtn").classList.remove("busy"); lockUntil = 0; refresh();
};
$("#advOpen").onclick = () => go("avances");
$("#zoneBtn").onclick = () => openSheet("shZone");
$("#lampsOpen").onclick = () => openSheet("shZone");
function renderZoneMenu() {
  const g = $("#zoneList");
  if (!zones) { g.innerHTML = '<div class="row"><span class="bd" style="padding-left:16px"><span class="spin"></span>Chargement…</span></div>'; return; }
  if (zones.error) { g.innerHTML = `<div class="note" style="padding:16px">${esc(zones.error)}</div>`; return; }
  if (!zones.length) { g.innerHTML = `<div class="note" style="padding:16px">Aucune zone de divertissement. Crée-en une dans l'app d'éclairage, ou choisis tes lampes ci-dessous.</div>`; return; }
  const cz = currentZone();
  g.innerHTML = zones.map(z => `<button class="row" data-zone="${z.id}" style="min-height:60px"><span style="width:44px;text-align:center;color:var(--blue);font-weight:700">${cz && cz.id === z.id ? "✓" : ""}</span><span class="bd"><span class="tx"><span class="t1" style="font-size:17px">${esc(z.name)}</span><span class="t2" style="font-size:13px">${z.lights} lampe${z.lights > 1 ? "s" : ""}</span></span></span></button>`).join("");
  $$("[data-zone]").forEach(b => b.onclick = () => { save({ area: b.dataset.zone }, true); renderZoneMenu(); renderSync(); });
}
$("#zoneLamps").onclick = () => { closeSheets(); setTimeout(openLights, 260); };
$("#lampsRow").onclick = () => openLights();

/* ----- choix des lampes de la synchro ----- */
let LS = null, sel = [];
async function openLights() {
  openSheet("shLampes"); $("#lightList").innerHTML = '<p class="note" style="padding:4px">Chargement des lampes…</p>';
  try { LS = await api("/api/lights"); sel = LS.selected.slice(); renderLights(); } catch (e) { $("#lightList").innerHTML = `<p class="note">${esc(e.message)}</p>`; }
}
function renderLights() {
  if (!LS.groups.length) { $("#lightList").innerHTML = '<p class="note">Aucune lampe couleur compatible trouvée.</p>'; return; }
  $("#lightList").innerHTML = LS.groups.map((g, gi) => `<div style="display:flex;justify-content:space-between;align-items:center;margin:14px 6px 8px"><span class="label" style="padding:0">${esc(g.name)}</span><button class="txtbtn" data-grp="${gi}" style="font-size:14px">${g.lights.every(l => sel.includes(l.id)) ? "Aucune" : "Toutes"}</button></div>
    <div class="list" style="border-radius:16px;background:var(--card2)">${g.lights.map(l => { const n = sel.indexOf(l.id); return `<button class="row" data-li="${l.id}" style="min-height:60px"><span class="ic" style="width:60px">${icon(lampKind(l.archetype), 24)}</span><span class="bd"><span class="tx"><span class="t1" style="font-size:16px">${esc(l.name)}</span></span><span style="width:28px;height:28px;border-radius:50%;display:grid;place-items:center;font-weight:700;font-size:14px;${n >= 0 ? "background:var(--cta)" : "border:2px solid #5c5d63"}">${n >= 0 ? n + 1 : ""}</span></span></button>`; }).join("")}</div>`).join("");
  $$("[data-li]").forEach(b => b.onclick = () => { const i = sel.indexOf(b.dataset.li); if (i >= 0) sel.splice(i, 1); else if (sel.length < LS.max) sel.push(b.dataset.li); else toast(`${LS.max} lampes maximum`); renderLights(); });
  $$("[data-grp]").forEach(b => b.onclick = () => { const g = LS.groups[+b.dataset.grp], all = g.lights.every(l => sel.includes(l.id)); g.lights.forEach(l => { const i = sel.indexOf(l.id); if (all && i >= 0) sel.splice(i, 1); if (!all && i < 0 && sel.length < LS.max) sel.push(l.id); }); renderLights(); });
  $("#lightCount").textContent = `${sel.length} sur ${LS.max} · ordre = gauche → droite`;
  $("#lightSave").disabled = !sel.length;
}
$("#lightSave").onclick = async () => {
  $("#lightSave").disabled = true;
  try { const r = await api("/api/lights", { ids: sel }); closeSheets(); toast(`Zone « Hue Sync » : ${r.count} lampe${r.count > 1 ? "s" : ""}`); zones = null; refresh(true); }
  catch (e) { toast("Échec : " + e.message); }
  $("#lightSave").disabled = false;
};

/* =================== RÉGLAGES AVANCÉS =================== */
const ADV = {
  beat_k: { min: .8, max: 3.5, inv: true, f: v => Math.round((3.5 - v) / 2.7 * 100) + " %", n: "Sensibilité" },
  min_beat: { min: .12, max: 1, f: v => Math.round(v * 1000) + " ms", n: "Écart minimum entre deux flashs" },
  beat: { min: 0, max: 1, f: v => Math.round(v * 100) + " %", n: "Force des flashs" },
  tau: { min: .04, max: 1.5, f: v => Math.round(v * 1000) + " ms", n: "Durée des flashs" },
  base: { min: 0, max: 1, f: v => Math.round(v * 100) + " %", n: "Luminosité de fond" },
  energy: { min: 0, max: 1, f: v => Math.round(v * 100) + " %", n: "Suivi du volume du morceau" },
  fade: { min: 0, max: 4, f: v => v < .05 ? "Net" : v.toFixed(1).replace(".", ",") + " s", n: "Fondu des couleurs" }
};
const fxv = k => { const fx = S.settings.fx || {}; return k in fx ? fx[k] : S.presets[S.settings.intensity][k]; };
function saveFx(k, v) { S.settings.fx = Object.assign({}, S.settings.fx, { [k]: v }); pending.fx = Object.assign({}, pending.fx, { [k]: v }); save({}); }
let open = JSON.parse(load("advOpen") || "{}");
function srow(k) { const a = ADV[k], v = fxv(k), t = (v - a.min) / (a.max - a.min); return `<div class="srow"><div class="h"><span>${a.n}</span><span data-vf="${k}">${a.f(v)}</span></div><div class="sl" data-sl="${k}"><div class="tr"></div><div class="fi" style="width:${(a.inv ? 1 - t : t) * 100}%"></div><div class="kn" style="left:${(a.inv ? 1 - t : t) * 100}%"></div></div></div>`; }
function renderAdv() {
  const st = S.settings, n = Object.keys(st.fx || {}).length, pal = palColors(st.palette);
  $("#advStatus").textContent = `Basé sur « ${INT[st.intensity]} »` + (n ? ` · ${n} modifié${n > 1 ? "s" : ""}` : "");
  $("#advReset").disabled = !n;
  $("#advEffects").innerHTML = EFFECTS.map(([k, nm, d, ok]) => `<button class="tile ${st.mode === k ? "on" : ""}" data-aeff="${k}" ${ok ? "" : "disabled"}>${effStrip(k, pal, 10)}<span class="n">${nm}</span><span class="d ${ok ? "" : "soon"}">${ok ? d : "Bientôt"}</span></button>`).join("");
  $$("[data-aeff]").forEach(b => b.onclick = () => { save({ mode: b.dataset.aeff }, true); renderAdv(); });
  const src = { full: "Tout", kick: "Grosse caisse", snare: "Caisse claire" }, pat = { all: "Ensemble", alt: "Alternance", chase: "Chenillard", wave: "Vague" };
  const folds = [
    ["rythme", "Rythme", `${src[fxv("source")]} · sensibilité ${ADV.beat_k.f(fxv("beat_k"))} · écart ${ADV.min_beat.f(fxv("min_beat"))}`,
      `<div class="seg" style="margin:8px 0 6px">${Object.entries(src).map(([k, v]) => `<button data-src="${k}" class="${fxv("source") === k ? "on" : ""}">${v}</button>`).join("")}</div>${srow("beat_k")}${srow("min_beat")}<p class="hint">Plus l'écart est grand, moins il y a de flashs : pratique pour calmer un morceau rapide.</p>`],
    ["flash", "Flash", `Force ${ADV.beat.f(fxv("beat"))} · ${ADV.tau.f(fxv("tau"))} · fond ${ADV.base.f(fxv("base"))}`,
      `<svg viewBox="0 0 300 100" preserveAspectRatio="none" style="display:block;width:100%;height:96px;margin:10px 0 2px;border-radius:12px;background:#0b0b0d" id="env"></svg>${srow("beat")}${srow("tau")}${srow("base")}${srow("energy")}`],
    ["couleurs", "Couleurs", `${fxv("every") === 1 ? "À chaque temps" : "Tous les " + fxv("every") + " temps"} · fondu ${ADV.fade.f(fxv("fade"))}`,
      `<div id="cstrip" style="height:40px;border-radius:12px;margin:12px 0 10px"></div><div class="srow"><div class="h"><span>Changement de couleur</span><span>${fxv("every") === 1 ? "À chaque temps" : "Tous les " + fxv("every") + " temps"}</span></div><div class="seg" style="margin-top:6px">${[1, 2, 4, 8].map(v => `<button data-every="${v}" class="${fxv("every") === v ? "on" : ""}">${v} temps</button>`).join("")}</div></div>${srow("fade")}`],
  ];
  if (st.mode === "pulse") folds.push(["motif", "Motif des lampes", pat[fxv("pattern")],
    `<div class="grid2" style="margin:10px 0 4px">${Object.entries(pat).map(([k, v]) => `<button class="tile ${fxv("pattern") === k ? "on" : ""}" data-pat="${k}" style="align-items:center;background:var(--card2)">${patDots(k, pal)}<span class="n" style="font-size:13px">${v}</span></button>`).join("")}</div>`]);
  $("#advFolds").innerHTML = folds.map(([k, t, s, body]) => `<button class="fold ${open[k] ? "open" : ""}" data-fold="${k}"><span class="tx"><b>${t}</b><small>${s}</small></span><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#8d8e94" stroke-width="2.6" stroke-linecap="round"><path d="M9 6l6 6-6 6"/></svg></button>${open[k] ? `<div class="foldin">${body}</div>` : ""}`).join("") +
    `<div class="list" style="border-radius:18px;margin-top:12px"><button class="row" id="strobeRow" role="switch" aria-checked="${!!fxv("strobe")}" style="min-height:70px"><span class="ic" style="width:64px"><span style="width:34px;height:34px;border-radius:10px;background:#fff;display:grid;place-items:center">${icon("sync", 18, "#1b1c20", 2.4).replace(IC.sync, "M13 2L4 14h7l-1 8 9-12h-7z")}</span></span><span class="bd"><span class="tx"><span class="t1" style="font-size:17px">Flash blanc sur les drops</span><span class="t2" style="font-size:13px">Toutes les lampes en blanc au moment fort</span></span><span class="sw ${fxv("strobe") ? "on" : ""}"><i></i></span></span></button></div><div style="height:20px"></div>`;
  $$("[data-fold]").forEach(b => b.onclick = () => { open[b.dataset.fold] = !open[b.dataset.fold]; store("advOpen", JSON.stringify(open)); renderAdv(); });
  $$("[data-src]").forEach(b => b.onclick = () => { saveFx("source", b.dataset.src); renderAdv(); });
  $$("[data-every]").forEach(b => b.onclick = () => { saveFx("every", +b.dataset.every); renderAdv(); });
  $$("[data-pat]").forEach(b => b.onclick = () => { saveFx("pattern", b.dataset.pat); renderAdv(); });
  $("#strobeRow").onclick = () => { saveFx("strobe", !fxv("strobe")); renderAdv(); };
  $$("[data-sl]").forEach(el => { const k = el.dataset.sl, a = ADV[k]; slider(el, r => { const t = a.inv ? 1 - r : r, v = Math.round((a.min + t * (a.max - a.min)) * 1000) / 1000; saveFx(k, v); setSl(el, r); $(`[data-vf="${k}"]`).textContent = a.f(v); drawEnv(); drawCStrip(); renderPrev(); }, () => renderAdv()); });
  drawEnv(); drawCStrip(); renderPrev();
}
function patDots(k, pal) { const d = { all: [0, 0, 0, 0, 0], alt: [0, .6, 0, .6, 0], chase: [0, .9, .3, .6, .15], wave: [0, .15, .3, .45, .6] }[k]; return `<span style="display:flex;gap:6px;height:18px;align-items:center">${d.map((x, i) => `<i style="width:14px;height:14px;border-radius:50%;background:${boost(pal[i % pal.length], 200)};--hi:1;--lo:.2;animation:fl 1.2s ${x}s infinite"></i>`).join("")}</span>`; }
function drawEnv() {
  const el = $("#env"); if (!el) return;
  const base = fxv("base"), beat = fxv("beat"), tau = Math.max(.04, fxv("tau")), en = fxv("energy"), col = boost(palColors(S.settings.palette)[0], 200);
  const T = 2, beats = [.1, .58, 1.06, 1.54], pts = [];
  for (let i = 0; i <= 150; i++) { const t = i / 150 * T, last = beats.filter(b => b <= t).pop(), env = last === undefined ? 0 : Math.exp(-(t - last) / tau); pts.push([i * 2, 92 - Math.min(1, base + en * .5 + beat * env) * 82]); }
  const line = pts.map((p, i) => (i ? "L" : "M") + p[0].toFixed(1) + " " + p[1].toFixed(1)).join(" ");
  el.innerHTML = `<defs><linearGradient id="eg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${col}" stop-opacity=".55"/><stop offset="1" stop-color="${col}" stop-opacity="0"/></linearGradient></defs><path d="${line} L300 100 L0 100 Z" fill="url(#eg)"/><path d="${line}" fill="none" stroke="${col}" stroke-width="2.2" vector-effect="non-scaling-stroke"/>`;
}
function drawCStrip() {
  const el = $("#cstrip"); if (!el) return;
  const pal = palColors(S.settings.palette).map(c => boost(c, 170)), every = fxv("every"), fade = fxv("fade"), cells = 16, w = 100 / cells, fw = Math.min(w * every, fade / .48 * w), st = [];
  for (let i = 0; i < cells; i++) { const c = pal[Math.floor(i / every) % pal.length], s = i * w; if (i && i % every === 0) st.push(`${pal[Math.floor((i - 1) / every) % pal.length]} ${s}%`, `${c} ${Math.min(100, s + fw)}%`); else st.push(`${c} ${s}%`); st.push(`${c} ${s + w}%`); }
  el.style.background = `linear-gradient(90deg, ${st.join(",")})`;
}
function renderPrev() {
  const pal = palColors(S.settings.palette), mode = S.settings.mode, n = 8;
  const tau = fxv("tau"), anim = tau < .14 ? "f1" : tau < .32 ? "f2" : "f3", per = .5;
  const dl = { all: [0, 0, 0, 0, 0, 0, 0, 0], alt: [0, .5, 0, .5, 0, .5, 0, .5], chase: [0, .55, .25, .8, .4, .95, .15, .65], wave: [0, .12, .24, .36, .48, .6, .72, .84] }[fxv("pattern")] || [];
  const hi = Math.max(fxv("beat"), fxv("base") + .1), lo = Math.max(fxv("base"), .03);
  $("#prev").innerHTML = Array.from({ length: n }, (_, i) => {
    const c = boost(pal[(i + 1) % pal.length], 200);
    const a = mode === "spectrum" ? `bar ${(.4 + i * .06).toFixed(2)}s ease-in-out infinite alternate` : `${anim} ${per}s ${(dl[i] || 0) * per}s infinite`;
    return `<i style="background:radial-gradient(circle at 35% 30%,#fff 0%,${c} 38%,${c} 100%);box-shadow:0 0 20px ${c};--hi:${hi};--lo:${lo};animation:${a}"></i>`;
  }).join("");
  $("#stage").style.setProperty("--glow", boost(pal[1] || pal[0], 160) + "33");
  $("#prevSub").textContent = (mode === "spectrum" ? "Spectre étalé" : "Pulsation") + " · " + INT[S.settings.intensity];
}
$("#advReset").onclick = () => { S.settings.fx = {}; delete pending.fx; save({ intensity: S.settings.intensity }, true); renderAdv(); toast("Préréglage rétabli"); };

/* =================== LUMIÈRES =================== */
let roomsTimer = null, roomsLock = 0;
async function loadRooms() {
  clearTimeout(roomsTimer);
  if (Date.now() > roomsLock) {
    try { ROOMS = await api("/api/rooms"); } catch (e) { ROOMS = { error: e.message }; }
    if (["lumieres", "piece", "lampe"].includes(route.v)) render();
  }
  roomsTimer = setTimeout(loadRooms, ["lumieres", "piece", "lampe"].includes(route.v) && !document.hidden ? 4000 : 15000);
}
const roomColors = r => { const on = r.lights.filter(l => l.on); return (on.length ? on : r.lights).map(l => l.color); };
function renderRooms() {
  const g = $("#rooms");
  if (!ROOMS) return;
  if (ROOMS.error) { g.innerHTML = `<p class="note" style="padding:0 8px">${esc(ROOMS.error)}</p>`; return; }
  g.innerHTML = ROOMS.map(r => {
    const cs = roomColors(r).map(c => boost(c, 200)), c0 = cs[0] || "#ffe2b8", c1 = cs[1] || cs[0] || "#ffb066";
    const dark = lum(c1) > .5, fg = r.on ? (dark ? "#1b1c20" : "#fff") : "#fff";
    return `<div class="room" style="background:${r.on ? `linear-gradient(135deg, ${lighten(c0, .2)}, ${c1})` : "var(--card)"};color:${fg};box-shadow:${r.on ? `0 8px 28px ${c1}38` : "none"}">
      <div class="r1"><button class="rn" data-room="${r.id}" style="display:flex;align-items:center;gap:14px"><span class="ri" style="background:${r.on ? "rgba(255,255,255,.35)" : "var(--card2)"}">${icon(roomKind(r.archetype, r.name), 26)}</span>${esc(r.name)}</button>
      <button class="pwbtn" data-rpow="${r.id}" aria-label="${r.on ? "Éteindre" : "Allumer"} ${esc(r.name)}" style="background:${r.on ? "rgba(255,255,255,.75)" : "var(--card2)"};color:${r.on ? "#1b1c20" : "#8d8e94"}">${icon("power", 20, "currentColor", 2.4)}</button></div>
      ${r.on ? `<div class="sl" data-rbri="${r.id}"><div class="tr" style="background:rgba(0,0,0,.15)"></div><div class="fi" style="width:${r.bri}%;background:rgba(0,0,0,.3)"></div><div class="kn" style="left:${r.bri}%"></div></div>` : ""}</div>`;
  }).join("") || `<p class="note" style="padding:0 8px">Aucune pièce sur le pont.</p>`;
  bindRoomControls();
}
function bindRoomControls() {
  $$("[data-room]").forEach(b => b.onclick = () => go("piece", b.dataset.room));
  $$("[data-rpow]").forEach(b => b.onclick = () => roomPower(b.dataset.rpow));
  $$("[data-rbri]").forEach(el => { const r = ROOMS.find(x => x.id === el.dataset.rbri); slider(el, t => { setSl(el, t); r.bri = Math.max(1, Math.round(t * 100)); }, () => { roomsLock = Date.now() + 2500; api("/api/room", { group: r.group, bri: r.bri }).catch(e => toast(e.message)); }); });
}
async function roomPower(id) {
  const r = ROOMS.find(x => x.id === id); if (!r) return;
  r.on = !r.on; r.lights.forEach(l => l.on = r.on); roomsLock = Date.now() + 2500; render();
  try { await api("/api/room", { group: r.group, on: r.on }); } catch (e) { toast(e.message); }
}

/* ----- une pièce ----- */
let spread = load("spread") || "lr", scenePick = {};
function planSvg(r) {
  const ls = r.lights, pos = ls.map((l, i) => l.pos ? [179 + l.pos.x * 140, 100 - l.pos.y * 64] : [60 + (ls.length > 1 ? i / (ls.length - 1) : .5) * 238, 100]);
  const shapes = ls.map((l, i) => {
    const [x, y] = pos[i], k = lampKind(l.archetype), c = l.on ? boost(l.color, 200) : "#3a3a3c", glow = l.on ? `filter:drop-shadow(0 0 8px ${c})` : "";
    if (k === "strip") { const gr = (l.gradient && l.gradient.length ? l.gradient : [l.color]).map(x => l.on ? boost(x, 200) : "#3a3a3c"); return `<defs><linearGradient id="g${i}">${gr.map((x, j) => `<stop offset="${gr.length > 1 ? j / (gr.length - 1) : 0}" stop-color="${x}"/>`).join("")}</linearGradient></defs><rect x="${x - 50}" y="${y - 4}" width="100" height="8" rx="4" fill="url(#g${i})" style="${glow}"/>`; }
    if (k === "bar") return `<rect x="${x - 26}" y="${y - 6}" width="52" height="12" rx="6" fill="${c}" style="${glow}"/>`;
    return `<circle cx="${x}" cy="${y}" r="${k === "bloom" ? 13 : 10}" fill="${c}" style="${glow}"/>`;
  }).join("");
  return `<svg viewBox="0 0 358 200" role="img" aria-label="Plan de ${esc(r.name)}"><rect x="18" y="18" width="322" height="164" rx="16" fill="#141416" stroke="#2c2c2e"/>${shapes}</svg>`;
}
function renderPiece() {
  const r = ROOMS && !ROOMS.error && ROOMS.find(x => x.id === route.arg);
  if (!r) { $("#piece").innerHTML = `<div class="nh"><button class="rb" data-back aria-label="Retour">${icon("plus", 22).replace(IC.plus, "M20 12H5M11 5l-7 7 7 7")}</button><span class="t">Pièce</span></div><p class="note">${ROOMS ? "Pièce introuvable." : "Chargement…"}</p>`; return; }
  const cs = roomColors(r).map(c => boost(c, 200)), c0 = cs[0] || "#ffe2b8", c1 = cs[1] || cs[0] || "#ffb066", dark = lum(c1) > .5;
  const fg = r.on ? (dark ? "#1b1c20" : "#fff") : "#fff";
  const scenes = allPalettes().filter(p => p.scenes);
  $("#piece").innerHTML = `<div class="rhead" style="background:${r.on ? `linear-gradient(160deg, ${lighten(c0, .25)}, ${c1})` : "#232326"};color:${fg};box-shadow:${r.on ? `0 10px 34px ${c1}44` : "none"}">
    <div style="display:flex;align-items:center;gap:16px"><button class="rb" data-back aria-label="Retour" style="background:${r.on ? (dark ? "rgba(0,0,0,.12)" : "rgba(255,255,255,.18)") : "#3a3b40"};color:inherit">${icon("plus", 22, "currentColor", 2.6).replace(IC.plus, "M20 12H5M11 5l-7 7 7 7")}</button>
    <span style="flex:1;font-size:22px;font-weight:700">${esc(r.name)}</span>
    <button class="pwbtn" id="pPow" aria-label="${r.on ? "Éteindre" : "Allumer"}" style="width:48px;height:48px;background:${r.on ? "rgba(255,255,255,.75)" : "#34353a"};color:${r.on ? "#1b1c20" : "#8d8e94"}">${icon("power", 22, "currentColor", 2.4)}</button></div>
    ${r.on ? `<div class="sl" id="pBri" style="margin:18px 4px 2px"><div class="tr" style="background:rgba(0,0,0,.12)"></div><div class="fi" style="width:${r.bri}%;background:rgba(0,0,0,.3)"></div><div class="kn" style="left:${r.bri}%"></div></div>` : ""}</div>
    <div class="plan">${planSvg(r)}</div>
    <div class="spr"><span>Couleurs selon la position</span><div class="seg">${[["lr", "M4 12h16M15 7l5 5-5 5", "De gauche à droite"], ["fb", "M12 4v16M7 15l5 5 5-5", "De l'avant vers l'arrière"], ["tour", "M20 12a8 8 0 1 1-2.3-5.7M20 4v4h-4", "Autour de la pièce"], ["centre", "M12 10a2 2 0 1 0 0 4 2 2 0 0 0 0-4M12 3v3M12 18v3M3 12h3M18 12h3", "Du centre vers les murs"]].map(([k, d, t]) => `<button data-spr="${k}" class="${spread === k ? "on" : ""}" aria-label="${t}" title="${t}"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="${d}"/></svg></button>`).join("")}</div></div>
    <div class="pad"><div class="label in">Scènes</div><div class="grid3">${scenes.map(p => orbTile(p.name, p.colors, scenePick[r.id] === p.id && r.on, `data-scene="${p.id}"`)).join("")}${orbTile("Créer", null, false, 'data-newpal="scene"')}</div>
    <div class="label in">Lampes</div><div class="grid3">${r.lights.map(l => lampTile(l)).join("")}</div><div style="height:24px"></div></div>`;
  $("#pPow").onclick = () => roomPower(r.id);
  if ($("#pBri")) slider($("#pBri"), t => { setSl($("#pBri"), t); r.bri = Math.max(1, Math.round(t * 100)); }, () => { roomsLock = Date.now() + 2500; api("/api/room", { group: r.group, bri: r.bri }).catch(e => toast(e.message)); });
  $$("[data-spr]").forEach(b => b.onclick = () => { spread = b.dataset.spr; store("spread", spread); if (scenePick[r.id]) applyScene(r, scenePick[r.id]); else renderPiece(); });
  $$("[data-scene]").forEach(b => b.onclick = () => applyScene(r, b.dataset.scene));
  $$("[data-newpal]").forEach(b => b.onclick = () => openCreer("scene"));
  $$("[data-lpow]").forEach(b => b.onclick = e => { e.stopPropagation(); lightPower(r, b.dataset.lpow); });
  $$("[data-lamp]").forEach(b => b.onclick = () => go("lampe", r.id + "|" + b.dataset.lamp));
}
function lampTile(l) {
  const k = lampKind(l.archetype), c = boost(l.color, 210), grad = k === "strip" && l.gradient && l.gradient.length > 1;
  const bg = l.on ? (grad ? `linear-gradient(90deg, ${l.gradient.map(x => boost(x, 210)).sort((a, b) => lum(a) - lum(b)).join(", ")})` : `linear-gradient(160deg, ${lighten(c, .35)}, ${c})`) : "#2a2b30";
  const light = l.on && (grad ? l.gradient.reduce((a, x) => a + lum(boost(x, 210)), 0) / l.gradient.length < .5 : lum(c) < .45);
  const fg = l.on && !light ? "#1b1c20" : "#fff";
  return `<div class="lamp" style="background:${bg};color:${fg}"><button class="top" data-lamp="${l.id}">${icon(k, 30)}<span>${esc(l.name)}</span></button>
    <div class="pw"><button class="pwbtn" data-lpow="${l.id}" aria-label="${l.on ? "Éteindre" : "Allumer"} ${esc(l.name)}" style="background:${l.on ? "rgba(255,255,255,.75)" : "#34353a"};color:${l.on ? "#1b1c20" : "#8d8e94"}">${icon("power", 20, "currentColor", 2.4)}</button></div></div>`;
}
async function lightPower(r, id) {
  const l = r.lights.find(x => x.id === id); l.on = !l.on; r.on = r.lights.some(x => x.on); roomsLock = Date.now() + 2500; render();
  try { await api("/api/light", { id, on: l.on }); } catch (e) { toast(e.message); }
}
async function applyScene(r, pid) {
  scenePick[r.id] = pid; const colors = palColors(pid), cyc = spread === "tour";
  r.on = true;
  r.lights.forEach((l, i) => {
    l.on = true;
    const p = l.pos || { x: r.lights.length > 1 ? -1 + 2 * i / (r.lights.length - 1) : 0, y: 0 };
    const t = spread === "fb" ? (1 - p.y) / 2 : spread === "centre" ? Math.min(1, Math.hypot(p.x, p.y) / 1.42) : spread === "tour" ? ((Math.atan2(-p.y, p.x) + Math.PI * 1.5) % (2 * Math.PI)) / (2 * Math.PI) : (p.x + 1) / 2;
    if (l.has_gradient) l.gradient = colors.slice(0, 5); else l.color = colors[Math.min(colors.length - 1, Math.floor(Math.max(0, Math.min(.999, t)) * colors.length))];
  });
  roomsLock = Date.now() + 4000; render();
  try { await api("/api/room/palette", { id: r.id, colors, spread }); } catch (e) { toast(e.message); }
}

/* ----- couleur d'une lampe ----- */
let wheelMode = "color";
function renderLampe() {
  const [rid, lid] = route.arg.split("|"), r = ROOMS && !ROOMS.error && ROOMS.find(x => x.id === rid), l = r && r.lights.find(x => x.id === lid);
  if (!l) { $("#lampe").innerHTML = '<p class="note">Lampe introuvable.</p>'; return; }
  const k = lampKind(l.archetype), c = boost(l.color, 210);
  $("#lampe").innerHTML = `<div class="nh"><button class="rb" data-back aria-label="Retour">${icon("plus", 22, "#fff", 2.6).replace(IC.plus, "M20 12H5M11 5l-7 7 7 7")}</button><span class="t">${esc(l.name)}</span></div>
    <div style="margin:14px 20px 0;color:var(--t2);font-size:14px;text-align:center">${esc(r.name)} · ${l.on ? (l.has_color ? "Couleur" : "Blanc") : "Éteinte"}</div>
    ${l.has_color ? `<div class="seg" style="margin:16px 16px 0"><button data-wm="color" class="${wheelMode === "color" ? "on" : ""}">Couleur</button><button data-wm="white" class="${wheelMode === "white" ? "on" : ""}">Blanc</button></div>` : ""}
    <div class="wheel ${wheelMode === "white" || !l.has_color ? "white" : ""}" id="wheel"><div class="pin" id="pin" style="background:${c}">${icon(k, 22, "#1b1c20", 2.2)}</div></div>
    <div style="background:var(--card);border-radius:18px;margin:26px 16px 0;padding:14px 16px 12px"><div style="display:flex;justify-content:space-between"><span style="font-weight:600">Luminosité</span><span style="color:var(--t2)" id="lBriPct">${l.bri} %</span></div><div class="sl" id="lBri" style="margin-top:8px"><div class="tr"></div><div class="fi" style="width:${l.bri}%;background:${c}"></div><div class="kn" style="left:${l.bri}%"></div></div></div>
    <div class="list" style="margin-top:16px"><button class="row" id="lPow" role="switch" style="min-height:64px"><span class="ic">${icon(k, 26)}</span><span class="bd"><span class="tx"><span class="t1" style="font-size:17px">Allumée</span></span><span class="sw ${l.on ? "on" : ""}"><i></i></span></span></button></div>`;
  $$("[data-wm]").forEach(b => b.onclick = () => { wheelMode = b.dataset.wm; renderLampe(); });
  $("#lPow").onclick = () => { lightPower(r, l.id); };
  const wheel = $("#wheel"), pin = $("#pin");
  const place = (x, y) => { pin.style.left = x * 100 + "%"; pin.style.top = y * 100 + "%"; };
  // position initiale approximative à partir de la couleur
  const [rr, gg, bb] = hexRgb(l.color), mx = Math.max(rr, gg, bb), mn = Math.min(rr, gg, bb);
  if (wheelMode === "white" || !l.has_color) place(.5, .62); else {
    let h = 0; if (mx !== mn) { h = mx === rr ? (gg - bb) / (mx - mn) : mx === gg ? 2 + (bb - rr) / (mx - mn) : 4 + (rr - gg) / (mx - mn); h = (h * 60 + 360) % 360; }
    const s = mx ? (mx - mn) / mx : 0, d = .5 * Math.min(1, s * 1.1);
    place(.5 + Math.cos(h * Math.PI / 180) * d, .5 + Math.sin(h * Math.PI / 180) * d);
  }
  let sendT = null;
  const pick = e => {
    const rc = wheel.getBoundingClientRect(); let x = (e.clientX - rc.left) / rc.width - .5, y = (e.clientY - rc.top) / rc.height - .5;
    const d = Math.hypot(x, y); if (d > .5) { x *= .5 / d; y *= .5 / d; }
    place(x + .5, y + .5);
    let col, body;
    if (wheelMode === "white" || !l.has_color) { const t = y + .5, mirek = Math.round(500 - t * 347); body = { id: l.id, mirek }; col = mix(["#ff9a4d", "#ffd9a0", "#fff6e6", "#ffffff", "#cfe8ff"], t); }
    else { const ang = (Math.atan2(y, x) * 180 / Math.PI + 360) % 360, hue = (ang + 0) % 360, sat = Math.min(1, Math.hypot(x, y) * 2); col = hsv(hue, sat, 1); body = { id: l.id, color: col }; }
    pin.style.background = col; l.color = col; l.on = true;
    clearTimeout(sendT); sendT = setTimeout(() => { roomsLock = Date.now() + 2500; api("/api/light", body).catch(er => toast(er.message)); }, 120);
  };
  let drag = false;
  wheel.addEventListener("pointerdown", e => { drag = true; wheel.setPointerCapture(e.pointerId); pick(e); });
  wheel.addEventListener("pointermove", e => drag && pick(e));
  wheel.addEventListener("pointerup", () => drag = false);
  slider($("#lBri"), t => { setSl($("#lBri"), t); l.bri = Math.max(1, Math.round(t * 100)); $("#lBriPct").textContent = l.bri + " %"; }, () => { roomsLock = Date.now() + 2500; api("/api/light", { id: l.id, bri: l.bri }).catch(e => toast(e.message)); });
}
function hsv(h, s, v) { const f = n => { const k = (n + h / 60) % 6; return v - v * s * Math.max(0, Math.min(k, 4 - k, 1)); }; return rgbHex([f(5) * 255, f(3) * 255, f(1) * 255]); }

/* =================== CRÉER UNE PALETTE =================== */
const ED = { from: "sync", tab: "photo", name: "Ma palette", img: null, ctx: null, w: 0, h: 0, points: [], colors: [], manual: ["#ffe2b8", "#ff6a3d", "#bf5af2", "#1a0f4a"], slot: 0, scenes: true, synchro: true };
const SW = ["#ffffff", "#fff1dc", "#ffe2b8", "#ffd60a", "#ffb340", "#ff9f0a", "#ff6a3d", "#ff375f", "#ff2d87", "#bf5af2", "#8a6cff", "#5e5ce6", "#0a84ff", "#64d2ff", "#5ad1c0", "#30d158", "#9be15d", "#c86cff", "#ff8ad8", "#ffc49a", "#9a3a10", "#4a160a", "#1a0f4a", "#0a3a4a"];
function openCreer(from) { Object.assign(ED, { from, tab: "photo", name: "Ma palette", img: null, points: [], colors: [], slot: 0, scenes: true, synchro: true }); go("creer"); }
function edColors() { return ED.tab === "photo" ? ED.colors : ED.manual; }
function renderCreer() {
  const cols = edColors();
  $("#creer").innerHTML = `<div class="nh"><button class="rb" data-back aria-label="Annuler">${icon("plus", 22, "#fff", 2.6).replace(IC.plus, "M6 6l12 12M18 6L6 18")}</button><span class="t">Nouvelle palette</span><button class="rb blue" id="edSave" aria-label="Enregistrer">${icon("plus", 24, "#fff", 2.8).replace(IC.plus, "M5 12.5l4.5 4.5L19 7")}</button></div>
  <div class="pad">
    <div style="display:flex;gap:12px;margin-top:18px">${orbTile(ED.name || "Ma palette", cols.length ? cols : null, true, 'style="width:112px;flex:none" tabindex="-1"')}<div style="flex:1;border-radius:18px;background:#0b0b0d;display:flex;align-items:center;justify-content:center;gap:8px;padding:10px">${(cols.length ? cols : ["#3a3a3c", "#3a3a3c", "#3a3a3c", "#3a3a3c"]).map(c => `<i style="width:26px;height:26px;border-radius:50%;background:${boost(c, 180)};box-shadow:0 0 14px ${boost(c, 180)}88"></i>`).join("")}</div></div>
    <label class="field"><span>Nom</span><input id="edName" value="${esc(ED.name)}" maxlength="30"></label>
    <div class="seg" style="margin-top:20px"><button data-tab2="photo" class="${ED.tab === "photo" ? "on" : ""}">Photo</button><button data-tab2="manual" class="${ED.tab === "manual" ? "on" : ""}">Couleurs</button></div>
    ${ED.tab === "photo" ? `<div class="pick" id="pick">${ED.img ? `<div style="position:relative;width:100%" id="pickWrap"><img src="${ED.img}" alt="Photo choisie">${ED.points.map((p, i) => `<span class="pt" data-pt="${i}" style="left:${p[0] * 100}%;top:${p[1] * 100}%;background:${ED.colors[i]}"></span>`).join("")}</div>` : `<button class="empty" id="pickEmpty"><svg width="44" height="44" viewBox="0 0 24 24" fill="none" stroke="#8d8e94" stroke-width="1.6"><rect x="3" y="5" width="18" height="14" rx="3"/><circle cx="9" cy="10" r="2"/><path d="M21 16l-5-5-8 8"/></svg><b style="color:#fff">Choisir une photo</b>Les couleurs sont extraites automatiquement, puis tu peux déplacer les points.</button>`}</div>
      ${ED.img ? `<button class="cta ghost" id="pickAgain" style="margin-top:10px">Choisir une autre photo</button>` : ""}`
    : `<div class="slots">${ED.manual.map((c, i) => `<button data-slot="${i}" class="${ED.slot === i ? "on" : ""}" style="background:${c};box-shadow:0 4px 14px ${c}55" aria-label="Couleur ${i + 1}"></button>`).join("")}</div>
      <div class="sws">${SW.map(c => `<button data-swc="${c}" style="background:${c}" aria-label="${c}"></button>`).join("")}</div>`}
    <div class="label in">Disponible pour</div>
  </div>
  <div class="list">${[["scenes", "Scènes des pièces", "Apparaît dans les scènes de chaque pièce"], ["synchro", "Palettes de la synchro", "Apparaît dans le panneau Couleur"]].map(([k, t, s]) => `<button class="row" data-use="${k}" role="switch" aria-checked="${ED[k]}"><span class="ic">${icon(k === "scenes" ? "room-salon" : "sync", 26)}</span><span class="bd"><span class="tx"><span class="t1" style="font-size:17px">${t}</span><span class="t2" style="font-size:13px">${s}</span></span><span class="sw ${ED[k] ? "on" : ""}"><i></i></span></span></button>`).join("")}</div><div style="height:30px"></div>`;
  $("#edName").oninput = e => { ED.name = e.target.value; };
  $$("[data-tab2]").forEach(b => b.onclick = () => { ED.tab = b.dataset.tab2; renderCreer(); });
  $$("[data-use]").forEach(b => b.onclick = () => { ED[b.dataset.use] = !ED[b.dataset.use]; renderCreer(); });
  $$("[data-slot]").forEach(b => b.onclick = () => { ED.slot = +b.dataset.slot; renderCreer(); });
  $$("[data-swc]").forEach(b => b.onclick = () => { ED.manual[ED.slot] = b.dataset.swc; ED.slot = (ED.slot + 1) % 4; renderCreer(); });
  if ($("#pickEmpty")) $("#pickEmpty").onclick = () => $("#palFile").click();
  if ($("#pickAgain")) $("#pickAgain").onclick = () => $("#palFile").click();
  const wrap = $("#pickWrap");
  if (wrap) $$("[data-pt]").forEach(el => {
    const i = +el.dataset.pt;
    const mv = e => { const rc = wrap.getBoundingClientRect(), x = Math.max(0, Math.min(1, (e.clientX - rc.left) / rc.width)), y = Math.max(0, Math.min(1, (e.clientY - rc.top) / rc.height)); ED.points[i] = [x, y]; ED.colors[i] = sampleAt(x, y); el.style.left = x * 100 + "%"; el.style.top = y * 100 + "%"; el.style.background = ED.colors[i]; };
    el.addEventListener("pointerdown", e => { e.preventDefault(); el.setPointerCapture(e.pointerId); el.dataset.drag = 1; });
    el.addEventListener("pointermove", e => el.dataset.drag && mv(e));
    el.addEventListener("pointerup", () => { delete el.dataset.drag; renderCreer(); });
  });
  $("#edSave").onclick = saveCreer;
}
$("#palFile").onchange = e => {
  const f = e.target.files[0]; if (!f) return;
  const rd = new FileReader();
  rd.onload = () => { const im = new Image(); im.onload = () => {
    const k = Math.min(1, 900 / Math.max(im.width, im.height)), c = document.createElement("canvas");
    c.width = Math.round(im.width * k); c.height = Math.round(im.height * k);
    const ctx = c.getContext("2d", { willReadFrequently: true }); ctx.drawImage(im, 0, 0, c.width, c.height);
    Object.assign(ED, { ctx, w: c.width, h: c.height, img: c.toDataURL("image/jpeg", .85) });
    ED.points = extractPoints(ctx, c.width, c.height); ED.colors = ED.points.map(p => sampleAt(p[0], p[1])); renderCreer();
  }; im.onerror = () => toast("Image illisible"); im.src = rd.result; };
  rd.readAsDataURL(f); e.target.value = "";
};
function sampleAt(x, y) {
  const px = Math.round(x * (ED.w - 1)), py = Math.round(y * (ED.h - 1)), r = 3;
  const d = ED.ctx.getImageData(Math.max(0, px - r), Math.max(0, py - r), r * 2 + 1, r * 2 + 1).data;
  let R = 0, G = 0, B = 0, n = 0; for (let i = 0; i < d.length; i += 4) { R += d[i]; G += d[i + 1]; B += d[i + 2]; n++; }
  return rgbHex([R / n, G / n, B / n]);
}
function extractPoints(ctx, w, h, N = 4) {
  const step = Math.max(1, Math.floor(Math.sqrt(w * h / 5000))), d = ctx.getImageData(0, 0, w, h).data, px = [];
  for (let y = 0; y < h; y += step) for (let x = 0; x < w; x += step) { const i = (y * w + x) * 4, r = d[i], g = d[i + 1], b = d[i + 2], mx = Math.max(r, g, b), mn = Math.min(r, g, b); px.push([r, g, b, x / (w - 1), y / (h - 1), mx / 255, mx ? (mx - mn) / mx : 0]); }
  let pool = px.filter(p => p[5] > .15 && p[6] > .18); if (pool.length < N * 10) pool = px.filter(p => p[5] > .08); if (pool.length < N) pool = px;
  const dist = (a, b) => (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2;
  const cen = [pool.reduce((a, b) => b[5] * b[6] > a[5] * a[6] ? b : a).slice(0, 3)];
  while (cen.length < N) { let best = null, bd = -1; for (const p of pool) { const dd = Math.min(...cen.map(c => dist(p, c))); if (dd > bd) { bd = dd; best = p; } } cen.push(best.slice(0, 3)); }
  for (let it = 0; it < 10; it++) { const acc = cen.map(() => [0, 0, 0, 0]); for (const p of pool) { let bi = 0, bd = Infinity; cen.forEach((c, i) => { const dd = dist(p, c); if (dd < bd) { bd = dd; bi = i; } }); const a = acc[bi]; a[0] += p[0]; a[1] += p[1]; a[2] += p[2]; a[3]++; } acc.forEach((a, i) => { if (a[3]) cen[i] = [a[0] / a[3], a[1] / a[3], a[2] / a[3]]; }); }
  const pts = [];
  for (const c of cen) { let best = pool[0], bd = Infinity; for (const p of pool) { if (p[3] < .04 || p[3] > .96 || p[4] < .04 || p[4] > .96) continue; if (pts.some(q => (q[0] - p[3]) ** 2 + (q[1] - p[4]) ** 2 < .02)) continue; const dd = dist(p, c); if (dd < bd) { bd = dd; best = p; } } pts.push([best[3], best[4]]); }
  return pts;
}
async function saveCreer() {
  const colors = edColors();
  if (ED.tab === "photo" && !ED.img) return toast("Choisis d'abord une photo");
  if (!ED.scenes && !ED.synchro) return toast("Active au moins un usage");
  try {
    const body = { name: ($("#edName").value || "").trim() || "Ma palette", colors, points: ED.tab === "photo" ? ED.points : [], scenes: ED.scenes, synchro: ED.synchro };
    if (ED.tab === "photo") body.image = ED.img;
    const p = await api("/api/palettes", body);
    toast("Palette enregistrée"); await refresh();
    if (ED.from === "sync" && ED.synchro) save({ palette: p.id }, true);
    back();
  } catch (e) { toast("Échec : " + e.message); }
}

/* =================== RÉGLAGES =================== */
function renderReglages() {
  const st = S.settings;
  $("#bridgeSub").textContent = S.bridge ? `${S.bridge} · connecté` : "Non connecté";
  const z = currentZone(); $("#lampsSub").textContent = z ? `Zone « ${z.name} » · ${z.lights} lampe${z.lights > 1 ? "s" : ""}` : "Zone utilisée pour la musique";
  $("#syncSw").classList.toggle("on", S.service.active); $("#syncRow").setAttribute("aria-checked", S.service.active);
  $("#syncSub").textContent = S.service.active ? "Démarre aussi avec la VM" : "Les lampes restent à l'app d'éclairage";
  if (document.activeElement !== $("#apName")) $("#apName").value = S.airplay_name;
  $("#apNote").textContent = `Sur l'iPhone : AirPlay → « ${S.airplay_name} ». Pour jouer aussi sur des enceintes AirPlay, coche-les en plus.`;
  const idle = String(st.idle_release); if (![...$("#idle").options].some(o => o.value === idle)) $("#idle").add(new Option(idle + " s", idle)); $("#idle").value = idle;
  setSl($("#offSl"), (st.bt_offset_ms ?? 300) / 1000); $("#offPct").textContent = (st.bt_offset_ms ?? 300) + " ms";
  renderBt();
}
$("#syncRow").onclick = () => $("#powerBtn").onclick();
$("#apName").addEventListener("change", e => { save({ airplay_name: e.target.value.trim() || "Lueur" }, true); toast("Nom AirPlay mis à jour"); });
$("#apName").addEventListener("keydown", e => e.key === "Enter" && e.target.blur());
$("#idle").onchange = e => save({ idle_release: +e.target.value }, true);
slider($("#offSl"), t => { const ms = Math.round(t * 100) * 10; setSl($("#offSl"), t); $("#offPct").textContent = ms + " ms"; save({ bt_offset_ms: ms }); });
$("#logsRow").onclick = async () => { openSheet("shLogs"); $("#logs").textContent = "Chargement…"; try { const j = await api("/api/logs"); $("#logs").textContent = j.lines || "(vide)"; $("#logs").scrollTop = 1e9; } catch (e) { $("#logs").textContent = e.message; } };
$("#bridgeRow").onclick = () => showWelcome(true);
$("#redoRow").onclick = () => showWelcome(true);

/* ----- Bluetooth ----- */
let btTimer = null;
async function loadBt() {
  clearTimeout(btTimer);
  if (route.v === "reglages" && !document.hidden) { try { BT = await api("/api/bt"); renderBt(); } catch (e) {} }
  btTimer = setTimeout(loadBt, BT && (BT.scanning || BT.busy) ? 1000 : 4000);
}
function renderBt() {
  const g = $("#bt"); if (!BT) { g.innerHTML = '<div class="row"><span class="ic"><span class="spin"></span></span><span class="bd"><span class="t2">Recherche de l\'adaptateur…</span></span></div>'; return; }
  $("#btMsg").textContent = BT.message || "";
  if (!BT.available) { g.innerHTML = `<p class="note" style="padding:16px 24px">${esc(BT.reason || "Aucun adaptateur Bluetooth détecté.")}</p>`; $("#btOffset").classList.add("hidden"); return; }
  const list = BT.devices.filter(d => d.audio || d.paired || d.connected || d.mac === BT.selected);
  g.innerHTML = list.map(d => {
    const isSel = d.mac === BT.selected, busy = BT.busy === d.mac, playing = isSel && live.bt && live.bt.playing;
    const sub = busy ? "Connexion…" : d.connected ? (playing ? "Connectée · lecture en cours" : "Connectée") : isSel ? "Reconnexion automatique…" : d.paired ? "Appairée" : "Disponible";
    const act = busy ? '<span class="spin"></span>' : isSel ? `<button class="act red" data-bt="disconnect" data-mac="${d.mac}">Déconnecter</button>` : `<button class="act" data-bt="connect" data-mac="${d.mac}">Connecter</button>${d.paired ? `<button class="act red" data-bt="forget" data-mac="${d.mac}" aria-label="Oublier" style="margin-left:6px">✕</button>` : ""}`;
    return `<div class="row"><span class="ic" style="color:${d.connected && isSel ? "#fff" : "#8d8e94"}">${icon("speaker")}</span><span class="bd"><span class="tx"><span class="t1">${esc(d.name)}</span><span class="t2" style="color:${d.connected && isSel ? "var(--green)" : "var(--t2)"}">${sub}</span></span>${act}</span></div>`;
  }).join("") + `<button class="row" id="btScan" ${BT.scanning ? "disabled" : ""}><span class="ic" style="color:var(--blue)">${BT.scanning ? '<span class="spin"></span>' : icon("plus")}</span><span class="bd"><span class="t1" style="color:var(--blue)">${BT.scanning ? "Recherche…" : "Rechercher des enceintes"}</span></span></button>`;
  $$("[data-bt]").forEach(b => b.onclick = async () => { if (b.dataset.bt === "forget" && !confirm("Oublier cette enceinte ?")) return; try { await api("/api/bt/" + b.dataset.bt, { mac: b.dataset.mac }); } catch (e) { toast(e.message); } loadBt(); });
  $("#btScan").onclick = async () => { await api("/api/bt/scan", {}).catch(e => toast(e.message)); loadBt(); };
  $("#btOffset").classList.toggle("hidden", !BT.selected);
}

/* =================== PREMIER LANCEMENT / APPAIRAGE =================== */
let bridges = [], picked = "", manual = false, forcedWelcome = false;
function showWelcome(force) { forcedWelcome = !!force; $("#welcome").classList.remove("hidden"); $("#app").classList.add("hidden"); $("#wStep0").classList.remove("hidden"); $("#wStep1").classList.add("hidden"); $("#wGo").textContent = "Continuer"; discover(); }
async function discover() {
  picked = ""; bridges = []; renderBridges(true);
  try { bridges = (await api("/api/discover")).bridges; } catch (e) { bridges = []; }
  if (bridges.length) picked = (S && S.bridge && bridges.find(b => b.ip === S.bridge) || bridges[0]).ip;
  renderBridges(false);
}
function renderBridges(searching) {
  $("#wBridges").innerHTML = searching ? `<div class="row" style="min-height:64px"><span class="ic"><span class="spin"></span></span><span class="bd"><span class="t1" style="font-size:16px">Recherche du pont…</span></span></div>`
    : bridges.length ? bridges.map(b => `<button class="row" data-ip="${esc(b.ip)}" style="min-height:70px"><span class="ic">${icon("pont", 26)}</span><span class="bd"><span class="tx"><span class="t1" style="font-size:17px">${esc(b.name)}</span><span class="t2" style="font-size:14px;color:${picked === b.ip && !manual ? "var(--green)" : "var(--t2)"}">${picked === b.ip && !manual ? "Trouvé · " : ""}${esc(b.ip)}</span></span><span style="color:var(--green)">${picked === b.ip && !manual ? "✓" : ""}</span></span></button>`).join("")
    : `<p class="note" style="padding:16px">Aucun pont trouvé automatiquement. Vérifie qu'il est allumé et sur le même réseau, ou saisis son adresse.</p>`;
  $$("[data-ip]").forEach(r => r.onclick = () => { picked = r.dataset.ip; manual = false; $("#wManual").classList.add("hidden"); renderBridges(false); });
  updateGo();
}
function updateGo() { $("#wGo").disabled = manual ? !/^\d{1,3}(\.\d{1,3}){3}(:\d+)?$/.test($("#wIp").value.trim()) : !picked; }
$("#wAgain").onclick = discover;
$("#wManualBtn").onclick = () => { manual = !manual; $("#wManual").classList.toggle("hidden", !manual); if (manual) $("#wIp").focus(); renderBridges(false); };
$("#wIp").oninput = updateGo;
$("#wGo").onclick = async () => {
  if ($("#wGo").textContent === "Ouvrir Lueur") { $("#welcome").classList.add("hidden"); $("#app").classList.remove("hidden"); forcedWelcome = false; zones = null; refresh(true); return; }
  $("#wStep0").classList.add("hidden"); $("#wStep1").classList.remove("hidden"); $("#wGo").disabled = true; $("#wGo").textContent = "En attente du pont…";
  let n = 30; const tick = setInterval(() => { n = Math.max(0, n - 1); $("#wCount").textContent = n + " s"; $("#wRing").style.strokeDashoffset = (503 * (1 - n / 30)).toFixed(0); }, 1000);
  try { await api("/api/pair", { bridge: manual ? $("#wIp").value.trim() : picked }); } catch (e) { $("#wMsg").textContent = e.message; }
  const poll = setInterval(async () => {
    const st = await api("/api/state").catch(() => null);
    if (!st || st.pairing.state === "waiting") return;
    clearInterval(poll); clearInterval(tick);
    if (st.pairing.state === "ok") { S = st; $("#wMsg").textContent = st.pairing.message + " Tu peux maintenant choisir « " + st.airplay_name + " » dans AirPlay."; $("#wCount").textContent = "✓"; $("#wGo").disabled = false; $("#wGo").textContent = "Ouvrir Lueur"; }
    else { $("#wMsg").textContent = st.pairing.message; $("#wCount").textContent = "!"; $("#wGo").disabled = false; $("#wGo").textContent = "Réessayer"; $("#wGo").onclick = () => location.reload(); }
  }, 1000);
};

/* =================== BOUCLES =================== */
async function refresh(forceZones) {
  try { const st = await api("/api/state"); if (Date.now() < lockUntil && S) st.settings = S.settings; S = st; live = st.live; nowAt = Date.now(); }
  catch (e) { return; }
  if (!S.paired && $("#welcome").classList.contains("hidden")) { showWelcome(false); return; }
  if (S.paired && !forcedWelcome) { $("#welcome").classList.add("hidden"); $("#app").classList.remove("hidden"); }
  if (S.paired && (zones === null || forceZones)) api("/api/areas" + (forceZones ? "?refresh" : "")).then(z => { zones = z; render(); renderSheets(); }).catch(e => { zones = { error: e.message }; render(); });
  render();
  if ($(".sheet.open")) renderSheets();
}
async function liveLoop() {
  if (!document.hidden && S && S.service.active && route.v === "sync") { try { const l = await api("/api/live"); const n = l.now; delete l.now; live = l; if (n && (!S.now || n.cover !== S.now.cover || n.title !== S.now.title || n.playing !== S.now.playing)) { setNow(n); if ($(".sheet.open")) renderSheets(); } else if (n) setNow(n); renderSync(); } catch (e) {} }
  setTimeout(liveLoop, 150);
}
const Q = new URLSearchParams(location.search);
go(Q.get("v") || load("tab") || "sync", Q.get("a") || "", false);
if (Q.get("sheet")) setTimeout(() => openSheet(Q.get("sheet")), 900);
refresh(); setInterval(() => !document.hidden && refresh(), 3000); setInterval(() => !document.hidden && S && route.v === "sync" && renderProgress(), 500); liveLoop(); loadRooms(); loadBt();
document.addEventListener("visibilitychange", () => { if (!document.hidden) { refresh(); loadRooms(); } });
</script>
</body>
</html>
HUE_FILE_EOF
[ -f /etc/shairport-sync.conf ] && [ ! -f /etc/shairport-sync.conf.orig ] && cp /etc/shairport-sync.conf /etc/shairport-sync.conf.orig || true
cat > /etc/shairport-sync.conf <<'HUE_FILE_EOF'
// Récepteur AirPlay 2 "Lueur" : le son n'est pas joué, il est envoyé
// au script sur STDOUT (44,1 kHz, 16 bits, stéréo), qui l'analyse et peut le
// rejouer sur une enceinte Bluetooth.
general =
{
  name = "Lueur";                 // nom visible dans le menu AirPlay de l'iPhone
  output_backend = "stdout";
  mdns_backend = "avahi";
  ignore_volume_control = "no";    // le volume de l'iPhone règle aussi l'enceinte Bluetooth
};

stdout =
{
  output_rate = 44100;
  output_format = "S16_LE";
  output_channels = 2;
};

// Signaux de lecture : la synchro prépare les lampes dès l'appui sur Lecture,
// et les rend à l'app Hue quand la lecture AirPlay se termine.
sessioncontrol =
{
  run_this_before_play_begins = "/usr/bin/touch /run/hue-music-sync/airplay-active";
  run_this_before_entering_active_state = "/usr/bin/touch /run/hue-music-sync/airplay-active";
  run_this_after_exiting_active_state = "/usr/bin/rm -f /run/hue-music-sync/airplay-active";
  active_state_timeout = 20.0;     // garde les lampes prêtes 20 s entre deux morceaux ou en pause
  wait_for_completion = "no";
};

// Titre, artiste, album et pochette du morceau : envoyés à l'interface web (palette « Pochette »)
metadata =
{
  enabled = "yes";
  include_cover_art = "yes";
  cover_art_cache_directory = "";  // pas de cache disque : la pochette passe par le tube
  pipe_name = "/run/hue-music-sync/metadata";
  pipe_timeout = 5000;
};

diagnostics =
{
  log_output_to = "stderr";        // jamais sur stdout : ça polluerait l'audio
  log_verbosity = 0;
};
HUE_FILE_EOF
cat > /etc/systemd/system/hue-airplay.service <<'HUE_FILE_EOF'
[Unit]
Description=Recepteur AirPlay 2 -> synchro musique Philips Hue
After=network-online.target avahi-daemon.service nqptp.service bluetooth.service hue-bluealsa.service
Wants=network-online.target avahi-daemon.service nqptp.service

[Service]
Environment=HUE_SYNC_CONFIG=/etc/hue-music-sync/config.json
Environment="HUE_AIRPLAY_NAME=Hue Sync"
EnvironmentFile=-/etc/default/hue-airplay
RuntimeDirectory=hue-music-sync
RuntimeDirectoryPreserve=yes
ExecStartPre=-/usr/bin/rm -f /run/hue-music-sync/airplay-active
ExecStart=/bin/bash -c 'set -o pipefail; /usr/local/bin/shairport-sync -c /etc/shairport-sync.conf -a "$$HUE_AIRPLAY_NAME" | /usr/bin/python3 -u /opt/hue-music-sync/hue_music_sync.py run --source stdin --channels 2 --rate 44100 --bluetooth --settings /etc/hue-music-sync/settings.json --status /run/hue-music-sync/status.json --airplay-flag /run/hue-music-sync/airplay-active'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
HUE_FILE_EOF
cat > /etc/systemd/system/hue-sync-web.service <<'HUE_FILE_EOF'
[Unit]
Description=Interface web Hue Sync
After=network-online.target
Wants=network-online.target

[Service]
Environment=HUE_SYNC_DIR=/etc/hue-music-sync
Environment=HUE_SYNC_STATUS=/run/hue-music-sync/status.json
Environment=HUE_SYNC_DEFAULTS=/etc/default/hue-airplay
Environment=HUE_SYNC_WEB_PORT=8080
ExecStart=/usr/bin/python3 -u /opt/hue-music-sync/hue_sync_web.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
HUE_FILE_EOF
cat > /tmp/hue-airplay.default <<'HUE_FILE_EOF'
# Nom du récepteur dans le menu AirPlay (modifiable aussi depuis l'interface web)
HUE_AIRPLAY_NAME="Lueur"
HUE_FILE_EOF

cat > /usr/local/bin/hue-sync <<'WRAP'
#!/bin/sh
# Raccourci : hue-sync pair | list | run ...
HUE_SYNC_CONFIG=/etc/hue-music-sync/config.json exec /usr/bin/python3 /opt/hue-music-sync/hue_music_sync.py "$@"
WRAP
chmod +x /usr/local/bin/hue-sync

if ! grep -q '^HUE_AIRPLAY_NAME=' /etc/default/hue-airplay 2>/dev/null; then
  install -m 644 /tmp/hue-airplay.default /etc/default/hue-airplay
fi
rm -f /tmp/hue-airplay.default
if [ ! -f /etc/hue-music-sync/settings.json ]; then
  cat > /etc/hue-music-sync/settings.json <<'SET'
{"area": "", "palette": "sunset", "intensity": "high", "mode": "pulse", "brightness": 1.0, "idle_release": 15}
SET
fi

echo "==> Bluetooth"
# Agent qui accepte l'appairage des enceintes sans code (mode "Just Works")
cat > /etc/systemd/system/hue-bt-agent.service <<'UNIT'
[Unit]
Description=Agent Bluetooth (appairage automatique des enceintes)
After=bluetooth.service
Requires=bluetooth.service

[Service]
ExecStart=/usr/bin/bt-agent --capability=NoInputNoOutput
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
# BlueALSA : sortie audio Bluetooth sans PulseAudio ni PipeWire
BLUEALSA_BIN=$(command -v bluealsa || echo /usr/bin/bluealsa)
cat > /etc/systemd/system/hue-bluealsa.service <<UNIT
[Unit]
Description=BlueALSA (sortie A2DP vers l'enceinte Bluetooth)
After=bluetooth.service
Requires=bluetooth.service

[Service]
ExecStart=${BLUEALSA_BIN} -p a2dp-source
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl disable --now bluealsa.service 2>/dev/null || true
sed -i 's/^#\?AutoEnable=.*/AutoEnable=true/' /etc/bluetooth/main.conf 2>/dev/null || true
# charge le pilote s'il ne l'est pas déjà (on ne le décharge jamais : certains adaptateurs disparaissent)
if ! ls /sys/class/bluetooth 2>/dev/null | grep -q hci; then
  modprobe btusb 2>/dev/null || true
  sleep 3
fi

systemctl daemon-reload
systemctl enable bluetooth hue-bt-agent hue-bluealsa 2>/dev/null || true
systemctl restart bluetooth 2>/dev/null || true
systemctl restart hue-bt-agent hue-bluealsa 2>/dev/null || true
if [ -d /sys/class/bluetooth ] && ls /sys/class/bluetooth | grep -q hci; then
  echo "    Adaptateur Bluetooth détecté."
else
  echo "    Aucun adaptateur Bluetooth détecté (AirPlay seul fonctionnera quand même)."
fi

systemctl enable --now hue-sync-web
systemctl enable hue-airplay
if [ -f /etc/hue-music-sync/config.json ]; then systemctl restart hue-airplay; fi

IP=$(hostname -I | awk '{print $1}')
echo
echo "============================================================"
echo " Installation terminée."
echo " Ouvre l'interface : http://$IP:8080"
echo "   - appaire le pont (bouton du pont Hue)"
echo "   - choisis la zone, la palette, l'intensité"
echo "   - connecte une enceinte Bluetooth (section Enceinte Bluetooth)"
echo " Sur l'iPhone : AirPlay > « Hue Sync »"
echo " Astuce : dans Safari, Partager > Sur l'écran d'accueil"
echo " Journal : journalctl -u hue-airplay -f"
echo "============================================================"
mkdir -p /var/lib/hue-sync && touch /var/lib/hue-sync/installed
