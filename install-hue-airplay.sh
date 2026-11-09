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


KINDS = {"ruban": "Ruban", "spots": "Spots", "play": "Play", "lampes": "Lampes"}


def kind_of(archetype, product="", channels_on_device=1):
    """Famille d'une lampe pour les couches d'effet : ruban, spots, Play ou autres lampes."""
    a, pr = (archetype or "").lower(), (product or "").lower()
    if "play" in a or "play" in pr:
        return "play"
    if "strip" in a or "strip" in pr or "flux" in pr or channels_on_device > 1:
        return "ruban"
    if "spot" in a or "recessed" in a or "spot" in pr:
        return "spots"
    return "lampes"


def channel_info(cfg, area):
    """Canaux d'une zone avec leur lampe : [{id, kind, dev, name, archetype, idx, x, y}].
    idx = numéro du segment le long d'un ruban (ordre réel des segments)."""
    ents = bridge_get(cfg, "entertainment")
    ent_owner = {e["id"]: e.get("owner", {}).get("rid") for e in ents}
    ent_seg = {e.get("owner", {}).get("rid"): e.get("segments") or {} for e in ents}
    devices = {d["id"]: d for d in bridge_get(cfg, "device")}
    lights = bridge_get(cfg, "light")
    dev_light = {l.get("owner", {}).get("rid"): l for l in lights}
    rows = []
    for ch in area.get("channels", []):
        mem = (ch.get("members") or [{}])[0]
        rows.append({"id": ch["channel_id"], "dev": ent_owner.get(mem.get("service", {}).get("rid")),
                     "idx": mem.get("index", 0) or 0,
                     "x": ch.get("position", {}).get("x", 0), "y": ch.get("position", {}).get("y", 0)})
    per_dev = collections.Counter(r["dev"] for r in rows)
    for r in rows:
        d = devices.get(r["dev"], {})
        md, pd = d.get("metadata", {}), d.get("product_data", {})
        r["kind"] = kind_of(md.get("archetype", ""), pd.get("product_name", ""), per_dev[r["dev"]])
        r["name"] = md.get("name", "Lampe")
        r["archetype"] = md.get("archetype", "")
        r["segments"] = per_dev[r["dev"]]
        lt = dev_light.get(r["dev"], {})
        sg = ent_seg.get(r["dev"], {})
        r["light"] = lt.get("id")
        r["max_segments"] = sg.get("max_segments")
        r["grad_points"] = (lt.get("gradient") or {}).get("points_capable")
        r["pixels"] = (lt.get("gradient") or {}).get("pixel_count")
        r["seg_configurable"] = sg.get("configurable")
        r["order"] = ((lt.get("content_configuration") or {}).get("order") or {}).get("order")
    return rows


def channel_kinds(cfg, area):
    """{channel_id: famille} et {channel_id: nom de la lampe} pour une zone de divertissement."""
    rows = channel_info(cfg, area)
    return {r["id"]: r["kind"] for r in rows}, {r["id"]: r["name"] for r in rows}


def plan_channels(area, plans):
    """Applique le plan de la pièce (s'il existe) : chaque canal reçoit son ordre de parcours
    (le long du ruban, ou de gauche à droite) et sa vraie position gauche / droite."""
    plan = (plans or {}).get(area.get("id"), {}) if isinstance(plans, dict) else {}
    pts = plan.get("ch", {}) if isinstance(plan, dict) else {}
    try:                                   # proportions de la pièce : profondeur / largeur
        dims = plan.get("dims") or {}
        ratio = float(dims["d"]) / float(dims["w"]) if dims.get("w") and dims.get("d") else 1.0
    except (TypeError, ValueError, ZeroDivisionError, AttributeError):
        ratio = 1.0
    out = []
    for ch in area.get("channels", []):
        c = dict(ch)
        q = pts.get(str(ch["channel_id"]))
        if isinstance(q, dict):
            try:
                t, x, y = (max(-1.0, min(1.0, float(q[k]))) for k in ("t", "x", "y"))
                c["position"] = {"x": t * 2 - 1, "y": y, "z": 0, "sx": x, "sy": y * ratio}
            except (KeyError, TypeError, ValueError):
                pass
        out.append(c)
    if not pts:
        # Pas de plan : les segments d'un ruban suivent leur VRAI ordre (numéro du segment),
        # pas leur position gauche-droite (un ruban qui fait le tour de la pièce serait mélangé).
        by = {}
        for c in out:
            m = (c.get("members") or [{}])[0]
            by.setdefault(m.get("service", {}).get("rid"), []).append(c)
        for rid, cs in by.items():
            if not rid or len(cs) < 2:
                continue
            xs = sorted(c["position"].get("x", 0) for c in cs)
            for c, x in zip(sorted(cs, key=lambda c: (c.get("members") or [{}])[0].get("index", 0) or 0), xs):
                p = dict(c["position"])
                p["sx"], p["x"] = p.get("x", 0), x
                c["position"] = p
    return out


def plan_eq(area, plans):
    """Équilibre de luminosité du plan : {lampe: facteur 0,1-1} (lampes absentes = 1)."""
    plan = (plans or {}).get(area.get("id"), {}) if isinstance(plans, dict) else {}
    eq = plan.get("eq") if isinstance(plan, dict) else None
    out = {}
    for k, v in (eq or {}).items() if isinstance(eq, dict) else []:
        try:
            out[k] = max(0.1, min(1.0, float(v)))
        except (TypeError, ValueError):
            pass
    return out


# Couleurs du test « couleurs par segment » (dans l'ordre des segments du ruban)
TEST_COLORS = ["#ff0000", "#ff7a00", "#ffe600", "#00d000", "#00e5ff", "#0030ff", "#9a00ff",
               "#ff00a8", "#ffffff", "#7a3b00"]


def _pos2(c):
    """Position réelle d'un canal dans la pièce (gauche-droite, avant-fond à l'échelle)."""
    p = c["position"]
    return p.get("sx", p["x"]), p.get("sy", p.get("y", 0))


def strip_anchor(strip, o):
    """Point du ruban le plus proche d'une lampe : (canal a, canal b, f). La lampe prend la couleur
    a et b mélangées (f = 0 : tout a, f = 1 : tout b). `strip` est trié dans l'ordre du ruban."""
    if len(strip) == 1:
        c = strip[0]["channel_id"]
        return c, c, 0.0
    pts = [_pos2(c) for c in strip]
    ox, oy = _pos2(o)
    steps = [((pts[i + 1][0] - pts[i][0]) ** 2 + (pts[i + 1][1] - pts[i][1]) ** 2) ** 0.5 for i in range(len(pts) - 1)]
    pairs = list(range(len(pts) - 1))
    close = ((pts[0][0] - pts[-1][0]) ** 2 + (pts[0][1] - pts[-1][1]) ** 2) ** 0.5
    if len(pts) > 2 and close <= 1.6 * sorted(steps)[len(steps) // 2]:
        pairs.append(-1)                   # le ruban fait le tour : le dernier segment touche le premier
    best = None
    for i in pairs:
        a, b = (len(pts) - 1, 0) if i == -1 else (i, i + 1)
        (ax, ay), (bx, by) = pts[a], pts[b]
        dx, dy = bx - ax, by - ay
        L = dx * dx + dy * dy
        f = 0.0 if L <= 1e-9 else max(0.0, min(1.0, ((ox - ax) * dx + (oy - ay) * dy) / L))
        d = (ax + dx * f - ox) ** 2 + (ay + dy * f - oy) ** 2
        if best is None or d < best[0]:
            best = (d, strip[a]["channel_id"], strip[b]["channel_id"], f)
    return best[1], best[2], best[3]


def mix_hex(a, b, f):
    ca, cb = hex_to_rgb(a), hex_to_rgb(b)
    return "#%02x%02x%02x" % tuple(int(round((x + (y - x) * f) * 255)) for x, y in zip(ca, cb))


def test_color_map(channels, kinds):
    """{canal: couleur} pour le test : segments du ruban en couleurs distinctes (dans l'ordre du
    plan), les autres lampes prennent la couleur du point du ruban le plus proche d'elles, avec
    l'entre-deux (à mi-chemin entre deux segments : le mélange des deux couleurs)."""
    strip = sorted([c for c in channels if kinds.get(c["channel_id"]) == "ruban"], key=lambda c: c["position"]["x"])
    out = {c["channel_id"]: TEST_COLORS[i % len(TEST_COLORS)] for i, c in enumerate(strip)}
    others = [c for c in channels if c["channel_id"] not in out]
    for k, o in enumerate(others):
        if strip:
            a, b, f = strip_anchor(strip, o)
            out[o["channel_id"]] = mix_hex(out[a], out[b], f)
        else:
            out[o["channel_id"]] = TEST_COLORS[k % len(TEST_COLORS)]
    return out


MAX_AREA_LIGHTS = 10
# Position d'un ruban à segments dans une zone de divertissement : seul cet endroit (avant, mi-hauteur)
# garde un canal par segment. Mesuré le 9/11 sur un Flux à 7 segments : 2 points ou tout autre point
# donnent 1 à 5 canaux, quelles que soient les autres lampes de la zone.
STRIP_SPOT = {"x": 0.0, "y": 0.8, "z": 0.0}
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
    strips = {e["id"] for e in bridge_get(cfg, "entertainment")
              if ((e.get("segments") or {}).get("max_segments") or 1) > 1}
    locations = {"service_locations": [
        {"service": {"rid": eid, "rtype": "entertainment"},
         "positions": [dict(STRIP_SPOT) if eid in strips else
                       {"x": round(-1 + 2 * i / (n - 1), 3) if n > 1 else 0.0, "y": 0.8, "z": 0.0}]}
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
        # Un message HueStream porte 20 canaux au plus. Au-delà, on envoie les paquets à tour
        # de rôle, un par image (deux écritures d'affilée pourraient être fusionnées par openssl).
        if len(colors) > 20:
            chunks = [colors[i:i + 20] for i in range(0, len(colors), 20)]
            colors = chunks[self.seq % len(chunks)]
        for ch, r, g, b in colors:
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
        self.lr = (0.0, 0.0)            # niveau gauche / droite du dernier bloc (effet Stéréo)
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
            lr = None
            if self.channels > 1:
                st = s.reshape(-1, self.channels)
                lr = (float(np.sqrt(np.mean(st[:, 0] ** 2))), float(np.sqrt(np.mean(st[:, 1] ** 2))))
                s = st.mean(axis=1)                             # stéréo -> mono
            s = (s, lr)
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
        s, lr = s
        self.lr = lr if lr is not None else (0.0, 0.0)
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
        self.last_low = False
        self.t = 0.0

    def set_params(self, beat_k, min_beat, source="full"):
        self.beat_k, self.min_beat = beat_k, min_beat
        if source != self.source:
            # Deux détecteurs séparés : graves (grosse caisse) et médiums-aigus (caisse claire,
            # attaques). Séparés, les graves ne sont plus noyés sous les centaines de fréquences aiguës.
            self.flux_masks = {"low": (self.freqs >= 30) & (self.freqs < 160),
                               "high": (self.freqs >= 160) & (self.freqs < 6000)}
            self.flux_mask = self.flux_masks["low"] | self.flux_masks["high"]
            self.flux_hist = {k: collections.deque(maxlen=50) for k in self.flux_masks}   # ~1 s
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

        # Flux spectral par région : hausse d'énergie moyenne par fréquence (attaques)
        log_mag = np.log1p(mag)
        z, ok = {}, False
        for k, m in self.flux_masks.items():
            cur = log_mag[m]
            prev = None if self.prev_log is None else self.prev_log[m]
            flux = 0.0 if prev is None else float(np.mean(np.maximum(0, cur - prev)))
            hist = self.flux_hist[k]
            if len(hist) >= 6:
                mean = float(np.mean(hist))
                std = float(np.std(hist)) + 1e-6
                z[k] = (flux - mean) / std
                ok = ok or flux > 0.0054                  # seuil absolu : pas de temps dans le souffle
            hist.append(flux)
        self.prev_log = log_mag
        beat, strength = False, 0.0
        if z and sound and ok:
            if self.source == "kick":
                nov = z.get("low", 0.0)
            elif self.source == "snare":
                nov = z.get("high", 0.0)
            else:
                nov = max(z.get("low", 0.0), 0.85 * z.get("high", 0.0))
            low = z.get("low", 0.0) > self.beat_k and self.source != "snare"
            free = (self.t - self.last_beat) > self.min_beat
            # une grosse caisse peut passer devant un temps aigu récent (sinon un charley détecté
            # juste avant bloquerait tous les kicks et les lampes tomberaient à contretemps)
            steal = low and not self.last_low and (self.t - self.last_beat) > 0.09
            if nov > self.beat_k and (free or steal):
                beat = True
                strength = min(1.0, max(0.3, nov / 4))
                self.last_beat = self.t
                self.last_low = low
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
        self.speed = 1.0
        self.t = 0.0
        self.beat_t = []                 # instants des derniers temps (tempo pour la vitesse ×2)
        self.half_done = True
        self.raw_beats = 0
        self.comets = []                 # [position, sens, couleur]
        self.sparks = None
        self.vu = 0.0
        self.vu_peak = 0.0
        self.phase = 0.0
        self.push = 0.0                  # élan donné par la grosse caisse (effet Glissé)
        self.lr_ref = 1e-3
        self.bavg = {}                   # niveau moyen récent de chaque bande (~1 s)
        self.dyn = {"bass": 0.0, "mid": 0.0, "high": 0.0, "all": 0.0}
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

    def _apply_speed(self, beat, strength):
        """Vitesse : ×½ ne garde qu'un temps sur deux, ×2 ajoute un temps entre deux temps."""
        self.t += self.DT
        if beat:
            self.beat_t = [t for t in self.beat_t if self.t - t < 4.0][-7:] + [self.t]
            self.raw_beats += 1
            self.half_done = False
            if self.speed < 1 and self.raw_beats % 2 == 0:
                return False, 0.0
            return True, strength
        if self.speed > 1 and not self.half_done and len(self.beat_t) >= 3:
            gaps = np.diff(self.beat_t)
            period = float(np.median(gaps))
            if 0.2 < period < 1.6 and self.t - self.beat_t[-1] >= period / 2:
                self.half_done = True
                return True, 0.6
        return False, 0.0

    def palette_at(self, x):
        """Couleur de la palette à la position x (0 → 1, bouclée), avec fondu entre couleurs."""
        npal = len(self.palette)
        x = (x % 1.0) * npal
        k = int(x) % npal
        return self.palette[k] + (self.palette[(k + 1) % npal] - self.palette[k]) * (x - int(x))

    def _render_extra(self, bands, beat, strength, n, dyn):
        """Effets supplémentaires : renvoie [(couleur cible, luminosité 0-1, fondu rapide ?)]."""
        p, sp, dt = self.p, self.speed, self.DT
        energy = bands.get("energy", 0.5)
        lvl = max(dyn["all"], dyn["bass"] * 0.9, dyn["mid"] * 0.8)
        if beat:
            lvl = max(lvl, 0.6 + 0.4 * strength)
        res = []
        pos = [i / (n - 1) if n > 1 else 0.5 for i in range(n)]
        mode = self.mode

        if mode == "comete":
            # Une seule comète qui tourne en continu le long du ruban (toujours dans le même sens),
            # avec une longue traînée qui s'éteint en fondu. Chaque temps lui donne un élan et la
            # fait briller ; la couleur de la tête change avec la palette (tous les N temps).
            if beat:
                self.push = min(2.5, self.push + 0.5 + 0.8 * strength)
                self.env[:] = np.maximum(self.env, 0.5 + 0.5 * strength)
            self.push *= np.exp(-dt / 0.5)
            self.env *= np.exp(-dt / 0.35)
            self.head = (getattr(self, "head", 0.0) + dt * sp * (0.16 + 0.10 * energy + 0.30 * self.push)) % 1.0
            npal = len(self.palette)
            c0 = self.palette[self.color_idx % npal]
            c1 = self.palette[(self.color_idx + 1) % npal]
            if n == 1:                                        # une seule lampe : elle « respire » au passage
                k = 0.5 + 0.5 * np.cos(2 * np.pi * self.head)
                res.append((c0, 0.06 + 0.8 * k * (0.7 + 0.3 * self.env[0]), True))
            else:
                tail = 0.55                                   # un peu plus d'un demi-tour de traînée
                front = 0.7 / n                               # la tête entre en fondu dans le segment suivant
                glow = 0.7 + 0.3 * min(1.0, self.push)
                for i in range(n):
                    u = i / n                                 # position sur la boucle (le ruban fait le tour)
                    d = (self.head - u) % 1.0                 # distance derrière la tête
                    if d <= tail:
                        k = (1 - d / tail) ** 1.8
                    elif 1 - d < front:                       # juste devant la tête
                        k = 1 - (1 - d) / front
                    else:
                        k = 0.0
                    col = c0 + (c1 - c0) * min(1.0, d / tail)     # la queue glisse vers la couleur suivante
                    b = 0.03 + 0.15 * p["base"] + 0.85 * k * glow + 0.15 * k * self.env[i]
                    res.append((col, b, True))
        elif mode == "glisse":
            # La palette glisse en continu le long des lampes ; chaque grosse caisse donne un élan
            # qui accélère puis s'amortit. Couleurs interpolées : passage en fondu d'un segment à l'autre.
            if beat:
                self.push = min(3.0, self.push + 0.9 + 1.2 * strength)
            self.push *= np.exp(-dt / 0.45)
            self.phase += dt * sp * (0.05 + 0.10 * energy + 0.22 * self.push)
            span = 0.9 if n > 1 else 0.0
            for i, x in enumerate(pos):
                b = 0.45 + 0.2 * p["base"] + 0.25 * lvl + 0.15 * min(1.0, self.push)
                res.append((self.palette_at(self.phase - x * span), b, True))

        elif mode == "vague":
            self.phase += dt * 0.22 * sp * (0.6 + 0.8 * energy)     # ~1 tour de palette en 4-6 s
            if beat:
                self.env[:] = np.maximum(self.env, 0.35 * strength)
            self.env *= np.exp(-dt / 0.4)
            for i, x in enumerate(pos):
                b = 0.35 + 0.25 * p["base"] + 0.3 * lvl + 0.25 * self.env[i]
                res.append((self.palette_at(x * 0.85 + self.phase), b, True))

        elif mode == "vumetre":
            # niveau réel du moment (sans le coup de pouce des temps, qui le collait en haut)
            target = min(1.0, max(dyn["all"], 0.85 * dyn["bass"], 0.7 * dyn["mid"]) ** 0.9)
            rise = 1 - np.exp(-dt / 0.04)
            fall = 1 - np.exp(-dt / (0.35 / sp))
            self.vu += (target - self.vu) * (rise if target > self.vu else fall)
            self.vu_peak = max(self.vu, self.vu_peak - dt * 0.35 * sp)
            for x in pos:
                if n == 1:
                    res.append((self.palette_at(self.vu * 0.75), 0.05 + 0.95 * self.vu, True))
                    continue
                fill = max(0.0, min(1.0, (self.vu * 1.1 - x) * n))
                b = 0.03 + 0.97 * fill
                if abs(x - self.vu_peak) < 0.5 / n + 1e-6 and self.vu_peak > 0.08:
                    b = max(b, 0.85)
                res.append((self.palette_at(x * 0.75), b, True))

        elif mode == "stereo":
            l, r = bands.get("lr", (0.0, 0.0))
            avg = self.bavg.setdefault("lr", [l or 1e-3, r or 1e-3])
            sides = []
            for j, v in enumerate((l, r)):
                avg[j] += (v - avg[j]) * 0.02
                sides.append(max(0.0, min(1.0, (v / max(avg[j], 1e-5) - 0.7) / 0.8)))
            if l + r < 1e-4:                               # pas de stéréo (source mono) : milieu
                sides = [lvl, lvl]
            if beat:
                self.env[:] = np.maximum(self.env, 0.5 + 0.5 * strength)
            self.env *= np.exp(-dt / max(0.08, p["tau"] / sp))
            npal = len(self.palette)
            cl, cr = self.palette[0], self.palette[-1] if npal > 1 else self.palette[0]
            for i, x in enumerate(pos):
                if n == 1:
                    bal = sides[1] / max(sides[0] + sides[1], 1e-3)
                    col = cl + (cr - cl) * bal
                    b = 0.08 + 0.6 * max(sides) ** 1.3 + 0.35 * self.env[i]
                else:
                    px = self.channels[i]["position"]
                    rx = (px.get("sx", px["x"]) + 1) / 2 if "sx" in px else x
                    w = min(1.0, max(0.0, (rx - 0.35) / 0.3))    # 0 = gauche, 1 = droite
                    sv = sides[0] * (1 - w) + sides[1] * w
                    col = cl + (cr - cl) * w
                    b = 0.05 + 0.65 * max(0.0, (sv - 0.15) / 0.85) ** 1.3 + 0.3 * self.env[i] * sv
                res.append((col, b, True))

        elif mode == "etincelles":
            if self.sparks is None or len(self.sparks) != n:
                self.sparks = [[0.0, self.palette[0]] for _ in range(n)]
            hi = bands.get("on_high", 0.0)
            if hi > 0.45 or beat:
                k = max(1, int(round(n * (0.12 + 0.2 * hi))))
                for j in self.rng.choice(n, size=min(k, n), replace=False):
                    c = self.palette[int(self.rng.integers(len(self.palette)))]
                    self.sparks[j] = [0.7 + 0.3 * max(hi, strength), c * 0.6 + np.ones(3) * 0.4]
            decay = np.exp(-dt / (0.14 / sp))
            for i, x in enumerate(pos):
                self.sparks[i][0] *= decay
                glow = self.palette_at(x * 0.7 + self.phase)
                k = self.sparks[i][0]
                col = glow + (self.sparks[i][1] - glow) * min(1.0, k * 1.4)
                res.append((col, 0.06 + 0.15 * p["base"] + 0.1 * energy + 0.9 * k, True))
            self.phase += dt * 0.01

        else:  # respiration
            period = 8.0 / sp
            self.phase += dt / period
            for x in pos:
                local = 0.5 - 0.5 * np.cos(2 * np.pi * (self.phase - 0.18 * x))
                b = 0.12 + 0.7 * local * (0.75 + 0.25 * energy)
                res.append((self.palette_at(self.phase * 0.25 + x * 0.3), b, False))
        return res

    def update(self, rms, bands, beat, strength):
        n = len(self.channels)
        p = self.p
        silent = rms < 0.001
        self.silent_frames = self.silent_frames + 1 if silent else 0
        beat, strength = self._apply_speed(beat, strength)
        if beat:
            self._on_beat(strength, bands, n)
        # Niveaux « dynamiques » : chaque bande comparée à sa moyenne récente. Une musique
        # compressée reste toujours forte ; seule la variation fait bouger les lampes.
        if not silent:
            for k in ("bass", "mid", "high"):
                v = bands.get(k, 0.0)
                avg = self.bavg.get(k, v)
                avg += (v - avg) * 0.025
                self.bavg[k] = avg
                self.dyn[k] = max(0.0, min(1.0, (v / max(avg, 1e-3) - 0.8) / 0.75))
            a = rms / max(self.bavg.get("rms", rms), 1e-5)
            self.bavg["rms"] = self.bavg.get("rms", rms) + (rms - self.bavg.get("rms", rms)) * 0.02
            self.dyn["all"] = max(0.0, min(1.0, (a - 0.75) / 0.9))
        else:
            self.dyn = {k: v * 0.9 for k, v in self.dyn.items()}
        dyn = self.dyn

        if self.mode not in ("pulse", "spectrum"):
            out = []
            fade = 1.0 if p["fade"] <= 0 else 1 - np.exp(-self.DT / p["fade"])
            for i, (ch, (target, b, quick)) in enumerate(zip(self.channels, self._render_extra(bands, beat, strength, n, dyn))):
                self.current[i] += (target - self.current[i]) * (max(fade, 0.5) if quick else max(fade, 0.03))
                b = max(0.0, min(1.0, b))
                if self.silent_frames > 50:
                    b = 0.2
                rgb = self.current[i] * b * self.brightness
                if self.flash > 0:
                    rgb = rgb * (1 - self.flash) + np.ones(3) * self.flash * self.brightness
                out.append((ch["channel_id"], *rgb))
            self.flash = max(0.0, self.flash - 0.34)
            self.last_out = out
            return out

        decay = np.exp(-self.DT / p["tau"])
        fade = 1.0 if p["fade"] <= 0 else 1 - np.exp(-self.DT / p["fade"])
        energy = bands.get("energy", 0.5)
        out = []
        for i, ch in enumerate(self.channels):
            pos = i / (n - 1) if n > 1 else 0.5

            if self.mode == "spectrum" and n == 1:
                # Une seule lampe : la couleur suit le registre (graves = couleur foncée de la
                # palette, aigus = couleur claire) et la luminosité suit le niveau, en continu.
                bb, mm, hh = dyn["bass"], dyn["mid"], dyn["high"]
                tot = bb + mm + hh
                bright = (0.5 * mm + hh) / tot / 1.5 if tot > 1e-3 else 0.0
                lvl = max(bb, mm, hh) ** 1.2
                if beat:
                    lvl = max(lvl, 0.7 + 0.3 * strength)
                hit = max(lvl, max(0.0, (max(bands.get("on_bass", 0), bands.get("on_high", 0)) - 0.25) / 0.75))
                npal = len(self.palette)
                x = min(0.999, max(0.0, bright * 1.6)) * (npal - 1)
                k = int(x)
                target = self.palette[k] + (self.palette[min(k + 1, npal - 1)] - self.palette[k]) * (x - k)
            elif self.mode == "spectrum":
                # Égaliseur : graves à gauche, médiums au centre, aigus à droite. Chaque lampe
                # suit en continu le niveau de sa bande (et pas seulement les temps).
                def band(k):
                    return bands.get(k, 0.0)
                if pos < 0.5:
                    lvl = dyn["bass"] * (1 - 2 * pos) + dyn["mid"] * 2 * pos
                    hit = band("on_bass") * (1 - 2 * pos) + band("on_mid") * 2 * pos
                else:
                    lvl = dyn["mid"] * (2 - 2 * pos) + dyn["high"] * (2 * pos - 1)
                    hit = band("on_mid") * (2 - 2 * pos) + band("on_high") * (2 * pos - 1)
                lvl = lvl ** 1.3
                if beat and pos < 0.4:            # la grosse caisse frappe côté graves
                    lvl = max(lvl, 0.7 + 0.3 * strength)
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


class Layered:
    """Couches d'effet : chaque famille de lampes (ruban, spots...) peut avoir son propre effet
    et sa vitesse ; les autres suivent l'effet principal. Même interface qu'Effects."""

    def __init__(self, channels, palette, params, brightness, mode, speed=1.0, kinds=None, layers=None):
        self.fx = {}
        self.last_out = []
        self.configure(channels, palette, params, brightness, mode, speed, kinds, layers)

    def configure(self, channels, palette, params, brightness, mode, speed=1.0, kinds=None, layers=None):
        kinds, layers = kinds or {}, layers or {}
        self.order = [c["channel_id"] for c in sorted(channels, key=lambda c: c["position"]["x"])]
        groups = {}
        for ch in channels:
            k = kinds.get(ch["channel_id"], "lampes")
            ov = layers.get(k) if isinstance(layers.get(k), dict) else None
            if ov and ov.get("mode") in MODES:
                groups.setdefault(k, (ov["mode"], ov.get("speed", speed), []))[2].append(ch)
            else:
                groups.setdefault("_", (mode, speed, []))[2].append(ch)
        # Effets « le long du ruban » : le ruban joue l'effet, et chaque autre lampe du même groupe
        # (spot, Play…) reprend la couleur du point du ruban le plus proche d'elle dans la pièce.
        self.follow = {}
        for name, (m, sp, chs) in list(groups.items()):
            strip = [c for c in chs if kinds.get(c["channel_id"]) == "ruban"]
            others = [c for c in chs if kinds.get(c["channel_id"]) != "ruban"]
            if m in ALONG and len(strip) > 1 and others:
                order = sorted(strip, key=lambda c: c["position"]["x"])
                for o in others:
                    self.follow[o["channel_id"]] = strip_anchor(order, o)
                groups[name] = (m, sp, strip)
        fx = {}
        for name, (m, sp, chs) in groups.items():
            e = self.fx.get(name)
            if e is None or {c["channel_id"] for c in e.channels} != {c["channel_id"] for c in chs}:
                e = Effects(chs, palette, params, brightness, m)
            else:
                e.configure(chs, palette, params, brightness, m)
            try:
                e.speed = min(SPEEDS, key=lambda v: abs(v - float(sp)))
            except (TypeError, ValueError):
                e.speed = 1.0
            fx[name] = e
        self.fx = fx
        self.desc = " + ".join(f"{KINDS.get(n, 'reste') if n != '_' else 'reste'} {e.mode}"
                               for n, e in fx.items()) if len(fx) > 1 else ""

    def update(self, rms, bands, beat, strength):
        out = []
        for e in self.fx.values():
            out += e.update(rms, bands, beat, strength)
        if self.follow:
            by = {o[0]: o for o in out}
            for cid, (a, b, f) in self.follow.items():
                if a in by and b in by:
                    out.append((cid, *(x + (y - x) * f for x, y in zip(by[a][1:], by[b][1:]))))
        self.last_out = out
        return out

    def colors_hex(self):
        by = {o[0]: o for o in self.last_out}
        return ["#%02x%02x%02x" % tuple(int(max(0, min(1, v)) * 255) for v in by[c][1:])
                for c in self.order if c in by]


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
MODES = ("pulse", "spectrum", "glisse", "comete", "vague", "vumetre", "stereo", "etincelles", "respiration")
SPEEDS = (0.5, 1.0, 2.0)          # demi-temps, normal, double
ALONG = ("glisse", "comete", "vague", "vumetre", "etincelles", "respiration")   # effets qui suivent le ruban

SETTINGS_DEFAULTS = {"area": "", "palette": "sunset", "intensity": "high", "mode": "pulse", "speed": 1.0,
                     "layers": {}, "plans": {}, "test": {},
                     "brightness": 1.0, "idle_release": 15,
                     "bt_device": "", "bt_offset_ms": 300, "area_rev": 0, "fx": {}}


def load_settings(path, args):
    """Réglages : fichier JSON (modifiable à chaud par l'interface web) sinon ligne de commande."""
    s = {"area": args.area or "", "palette": args.palette, "intensity": args.intensity,
         "mode": args.mode, "brightness": args.brightness, "idle_release": args.idle_release,
         "bt_device": "", "bt_offset_ms": 300, "area_rev": 0, "fx": {}, "speed": 1.0, "layers": {}, "plans": {}, "test": {}}
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
    if s["mode"] not in MODES:
        s["mode"] = "pulse"
    try:
        s["speed"] = min(SPEEDS, key=lambda v: abs(v - float(s["speed"])))
    except (TypeError, ValueError):
        s["speed"] = 1.0
    if not isinstance(s.get("layers"), dict):
        s["layers"] = {}
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
        if not self.path or (not force and time.time() - self.last < 0.05):
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
            # Pas de zone : on attend qu'une zone soit créée (depuis Lueur ou l'app Hue) au lieu de
            # quitter, sinon le service redémarrerait en boucle.
            log("Aucune zone de divertissement : crée-en une dans Lueur (Réglages > Pièces et zones de synchro).")
            stop_wait = threading.Event()
            signal.signal(signal.SIGTERM, lambda *_: stop_wait.set())
            signal.signal(signal.SIGINT, lambda *_: stop_wait.set())
            while not area and not stop_wait.wait(5):
                try:
                    found = get_areas(cfg)
                    if found:
                        settings = load_settings(args.settings, args)
                        area = pick_area(found, settings["area"])
                except HueError:
                    area = None
            if not area:
                return
            log("Zone de divertissement trouvée : synchro prête.")
    area_name = area.get("metadata", {}).get("name")
    log(f"Zone : {area_name} ({len(area['channels'])} canaux)")

    devs = {}                         # canal -> lampe (pour l'équilibre de luminosité)

    def kinds_for(a):
        devs.clear()
        if args.dry_run:
            return {}
        try:
            rows = channel_info(cfg, a)
            devs.update({r["id"]: r["dev"] for r in rows})
            return {r["id"]: r["kind"] for r in rows}
        except HueError as e:
            log(f"Familles de lampes inconnues ({e}) : un seul effet pour toute la zone.")
            return {}
    kinds = kinds_for(area)
    if kinds:
        log("Lampes : " + ", ".join(f"{KINDS[k]} ×{n}" for k, n in collections.Counter(kinds.values()).items()))

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
    fx = Layered(plan_channels(area, settings["plans"]), settings["palette_colors"], p, settings["brightness"],
                 settings["mode"], settings["speed"], kinds, settings["layers"])
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
            bands["lr"] = audio.lr
            now = time.time()

            # Réglages modifiés depuis l'interface web : on les applique à chaud
            if args.settings and now - last_check > 0.2:     # réglages appliqués en ~0,2 s
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
                                kinds = kinds_for(area)
                                log(f"Nouvelle zone : {area_name}")
                        except HueError as e:
                            log(f"Changement de zone impossible : {e}")
                    settings = new
                    if player:
                        player.set_device(settings["bt_device"])
                    q = settings["fx_params"]
                    analyzer.set_params(q["beat_k"], q["min_beat"], q["source"])
                    fx.configure(plan_channels(area, settings["plans"]), settings["palette_colors"], q, settings["brightness"],
                                 settings["mode"], settings["speed"], kinds, settings["layers"])
                    log(f"Réglages appliqués : {settings['palette']}, {settings['intensity']}, "
                        f"{settings['mode']} ×{settings['speed']:g}, luminosité {settings['brightness']}"
                        + (f" — couches : {fx.desc}" if fx.desc else ""))

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
            test = settings.get("test") if isinstance(settings.get("test"), dict) else {}
            if test.get("area") == area.get("id") and test.get("until", 0) > time.time():
                # Test de l'ordre : un point blanc parcourt les lampes dans l'ordre que suivent les
                # effets (début en rouge, fin en bleu), même sans musique.
                session.acquire()
                silent_since = now
                if test.get("mode") == "colors":
                    # Couleurs par segment : chaque segment du ruban a sa couleur, chaque spot prend
                    # celle du segment le plus proche sur le plan (pour vérifier où sont les spots).
                    cmap = test_color_map(plan_channels(area, settings["plans"]), kinds)
                    session.send([(cid, *(v * 0.85 for v in hex_to_rgb(hx))) for cid, hx in cmap.items()])
                    continue
                order = [c["channel_id"] for c in sorted(plan_channels(area, settings["plans"]),
                                                         key=lambda c: c["position"]["x"])]
                n = len(order)
                head = (now * 2.5) % max(n, 1)
                colors = []
                for k, cid in enumerate(order):
                    d = (head - k) % n
                    w = 1.0 if d < 1 else 0.35 if d < 2 else 0.0
                    base = (0.5, 0.0, 0.0) if k == 0 else (0.0, 0.0, 0.5) if k == n - 1 else (0.02, 0.02, 0.03)
                    colors.append((cid, *(max(b, w) for b in base)))
                session.send(colors)
                continue
            colors = fx.update(rms, bands, beat, strength)
            # Équilibre de luminosité choisi dans le plan : une lampe trop forte est atténuée
            eq = plan_eq(area, settings["plans"])
            if eq:
                colors = [(c, r * f, g * f, b * f) for c, r, g, b in colors
                          for f in (eq.get(devs.get(c), 1.0),)]
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
    p_run.add_argument("--mode", default="pulse", choices=list(MODES),
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
  POST /api/room/palette {"id", "colors": [...], "grad_mode"?}  applique une scène / palette à la pièce
  POST /api/room/effect  {"id", "effect", "speed"?}       effet intégré au pont (bougie, étincelles…)
  POST /api/light/order  {"light", "order"}               sens du contenu sur un ruban (forward / reversed)
  POST /api/plan/eq      {"id", "eq": {lampe: 0.1-1}}      équilibre de luminosité d'une zone de synchro
  POST /api/area/from_room {"id", "rubans"?, "spots"?}    crée la zone de divertissement d'une pièce d'après son plan
  POST /api/plan/colortest {"id", "rubans", "spots", "dims", "stop"?}  test « couleurs par segment » d'une pièce
  GET  /api/plan?area=ID  canaux de la zone et plan enregistré ; POST /api/plan l'enregistre
  GET  /api/now        morceau AirPlay en cours (titre, artiste, album, progression, couleurs)
  GET  /api/cover      pochette du morceau en cours

La pochette est lue dans le tube de métadonnées de shairport-sync ; ses couleurs (extraites
avec Pillow si disponible) alimentent la palette « Pochette » (cover.json).

Aucune dépendance hors Python standard. À utiliser sur le réseau local uniquement.
"""

import base64
import colorsys
import copy
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
import urllib.request
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
    data = []
    for a in hms.get_areas(cfg):
        try:
            kinds, _ = hms.channel_kinds(cfg, a)
        except hms.HueError:
            kinds = {}
        counts = {}
        for k in kinds.values():
            counts[k] = counts.get(k, 0) + 1
        data.append({"id": a["id"], "name": a.get("metadata", {}).get("name", "Zone"),
                     "lights": len(a.get("channels", [])), "status": a.get("status"), "kinds": counts})
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


def plan_info(area_id):
    cfg = hms.load_config_or_none()
    if not cfg:
        raise hms.HueError("Pont non appairé.")
    area = next((a for a in hms.get_areas(cfg) if a["id"] == area_id), None)
    if not area:
        raise hms.HueError("Zone introuvable.")
    plans = get_settings().get("plans") or {}
    return {"id": area_id, "name": area.get("metadata", {}).get("name", "Zone"),
            "channels": hms.channel_info(cfg, area), "plan": plans.get(area_id) or {}}


def room_plan_info(rid):
    room = next((r for r in rooms_state() if r["id"] == rid), None)
    if not room:
        raise hms.HueError("Pièce introuvable.")
    # Si la pièce a sa zone de synchro, le ruban est dessiné avec ses vrais segments de synchro
    # (ex. 7) ; sinon avec les 5 points de couleur des scènes.
    segs = {}
    try:
        cfg = _cfg()
        zname = (ZONE_PREFIX + room["name"])[:32]
        area = next((a for a in hms.get_areas(cfg) if a.get("metadata", {}).get("name") == zname), None)
        if area:
            owner = {l["id"]: l.get("owner", {}).get("rid") for l in hms.bridge_get(cfg, "light")}
            cnt = {}
            for r in hms.channel_info(cfg, area):
                cnt[r["dev"]] = cnt.get(r["dev"], 0) + 1
            for l in room["lights"]:
                if cnt.get(owner.get(l["id"]), 0) > 1:
                    segs[l["id"]] = cnt[owner[l["id"]]]
    except hms.HueError:
        pass
    chs, n = [], len(room["lights"])
    for i, l in enumerate(room["lights"]):
        p = l.get("pos") or {"x": round(-0.7 + 1.4 * i / max(1, n - 1), 3) if n > 1 else 0, "y": 0}
        base = {"dev": l["id"], "light": l["id"], "name": l["name"], "archetype": l["archetype"], "x": p["x"], "y": p["y"],
                "grad_points": GRAD_POINTS if l.get("has_gradient") else None, "order": l.get("order"),
                "sync_segments": segs.get(l["id"])}
        if l.get("has_gradient"):                   # un ruban : on le trace le long des murs
            chs += [dict(base, id=f"{l['id']}#{k}", idx=k) for k in range(segs.get(l["id"]) or GRAD_POINTS)]
        else:
            chs.append(dict(base, id=l["id"], idx=0))
    plan = (get_settings().get("room_plans") or {}).get(rid) or {}
    return {"id": rid, "type": "room", "name": room["name"], "channels": chs, "plan": plan}


def save_plan(body):
    """Plan d'une pièce : réglages de l'éditeur + position calculée de chaque canal."""
    aid = str(body.get("id", ""))[:64]
    if not aid:
        raise ValueError("Zone manquante.")
    num = lambda v, lo, hi: max(lo, min(hi, round(float(v), 4)))
    if body.get("type") == "room":                  # pièce ou zone de l'app (hors synchro)
        s = get_settings()
        plans = s.get("room_plans") if isinstance(s.get("room_plans"), dict) else {}
        if body.get("reset"):
            plans.pop(aid, None)
        else:
            plans[aid] = {
                "dims": dict(zip("wd", dims_of(body.get("dims")))),
                "spots": {str(k)[:64]: [num(v[0], 0, 1), num(v[1], 0, 1)] for k, v in (body.get("spots") or {}).items()},
                "rubans": {str(d)[:64]: {"walls": int(num(r.get("walls", 1), 1, 4)), "corner": int(num(r.get("corner", 0), 0, 3)),
                                         "dir": 1 if r.get("dir", 1) >= 0 else -1}
                           for d, r in (body.get("rubans") or {}).items()}}
        s["room_plans"] = plans
        write_json(SETTINGS_PATH, s)
        rooms_cache["t"] = 0
        if not body.get("reset"):
            try:
                refresh_room_zone(aid)          # la zone de synchro de la pièce suit le nouveau plan
            except Exception as e:              # pas de zone, pont injoignable… : le plan reste enregistré
                print(f"Plan de synchro non recopié : {e}", flush=True)
        return {"ok": True}
    ch = {}
    for k, q in (body.get("ch") or {}).items():
        ch[str(int(k))] = {"t": num(q["t"], 0, 1), "x": num(q["x"], -1, 1), "y": num(q["y"], -1, 1)}
    rubans = {}
    for dev, r in (body.get("rubans") or {}).items():
        rubans[str(dev)[:64]] = {"walls": int(num(r.get("walls", 4), 1, 4)), "corner": int(num(r.get("corner", 0), 0, 3)),
                                 "dir": 1 if r.get("dir", 1) >= 0 else -1}
    spots = {str(k)[:64]: [num(v[0], 0, 1), num(v[1], 0, 1)] for k, v in (body.get("spots") or {}).items()}
    s = get_settings()
    plans = s.get("plans") if isinstance(s.get("plans"), dict) else {}
    eq = (plans.get(aid) or {}).get("eq") if isinstance(plans.get(aid), dict) else None
    if body.get("reset"):
        plans.pop(aid, None)                # positions de l'app Hue, mais on garde l'équilibre
        if eq:
            plans[aid] = {"eq": eq}
    else:
        plans[aid] = {"ch": ch, "rubans": rubans, "spots": spots, "dims": dict(zip("wd", dims_of(body.get("dims")))),
                      **({"eq": eq} if eq else {})}
    s["plans"] = plans
    write_json(SETTINGS_PATH, s)
    return {"ok": True}


def plan_test(body):
    """Zone de synchro : un point blanc parcourt les lampes dans l'ordre des effets (15 s)."""
    aid = str(body.get("id", ""))[:64]
    s = get_settings()
    s["test"] = {"area": aid, "until": time.time() + 15} if not body.get("stop") else {}
    write_json(SETTINGS_PATH, s)
    active = service_state()["active"]
    return {"ok": True, "running": active, "area_selected": s.get("area") in ("", aid)}


identify_jobs = {}


def identify_light(body):
    """Ruban : début en rouge, fin en bleu pendant 10 s, puis retour à l'état d'avant."""
    cfg = _cfg()
    lid = str(body.get("light", ""))
    l = next((x for x in hms.bridge_get(cfg, "light") if x["id"] == lid), None)
    if not l:
        raise ValueError("Lampe introuvable.")
    n = (l.get("gradient") or {}).get("points_capable") or 0
    if n < 2:
        raise ValueError("Cette lampe n'a pas de dégradé.")
    marks = ["#ff0000", "#ff6a00", "#ffffff", "#00b4ff", "#0000ff"][:n] if n >= 5 else ["#ff0000", "#0000ff"]
    before = {"on": {"on": l.get("on", {}).get("on", False)}}
    if l.get("dimming"):
        before["dimming"] = {"brightness": l["dimming"].get("brightness", 100)}
    pts = (l.get("gradient") or {}).get("points") or []
    if pts:
        before["gradient"] = {"points": pts}
    elif (l.get("color") or {}).get("xy"):
        before["color"] = {"xy": l["color"]["xy"]}
    if (l.get("gradient") or {}).get("mode") and pts:
        before["gradient"]["mode"] = l["gradient"]["mode"]
    # rendu « fondu » forcé : en miroir ou en blocs, le rouge ne serait pas forcément au début
    mark = {"points": [{"color": {"xy": dict(zip("xy", hex_to_xy(c)))}} for c in marks]}
    if "interpolated_palette" in ((l.get("gradient") or {}).get("mode_values") or []):
        mark["mode"] = "interpolated_palette"
    _put(cfg, "light", lid, {"on": {"on": True}, "dimming": {"brightness": 100}, "gradient": mark})
    gen = identify_jobs.get(lid, 0) + 1
    identify_jobs[lid] = gen

    def restore():
        time.sleep(10)
        if identify_jobs.get(lid) != gen:
            return
        try:
            _put(cfg, "light", lid, before)
        except hms.HueError:
            pass
    threading.Thread(target=restore, daemon=True).start()
    return {"ok": True, "points": n}


ZONE_KEYS = ("palette", "intensity", "fx", "mode", "speed", "layers", "brightness")


def clean_layers(d):
    out = {}
    for k, v in (d or {}).items() if isinstance(d, dict) else []:
        if k in hms.KINDS and isinstance(v, dict) and v.get("mode") in hms.MODES:
            try:
                sp = min(hms.SPEEDS, key=lambda x: abs(x - float(v.get("speed", 1))))
            except (TypeError, ValueError):
                sp = 1.0
            out[k] = {"mode": v["mode"], "speed": sp}
    return out


def update_settings(body):
    s = get_settings()
    restart = False
    zones = s.get("zones") if isinstance(s.get("zones"), dict) else {}
    # Changement de zone : chaque zone retrouve ses propres réglages (effet, couleurs, couches…)
    if "area" in body and str(body["area"])[:64] != s.get("area", ""):
        new = str(body["area"])[:64]
        zones[s.get("area", "")] = {k: s.get(k) for k in ZONE_KEYS}
        for k, v in (zones.get(new) or {}).items():
            if k in ZONE_KEYS and k not in body:
                s[k] = v
        if new not in zones and "layers" not in body:
            s["layers"] = {}             # zone jamais réglée : mêmes réglages, sans couches
        s["area"] = new
    if "layers" in body:
        s["layers"] = clean_layers(body["layers"])
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
    if "mode" in body and body["mode"] in hms.MODES:
        s["mode"] = body["mode"]
    if "speed" in body:
        try:
            s["speed"] = min(hms.SPEEDS, key=lambda v: abs(v - float(body["speed"])))
        except (TypeError, ValueError):
            pass
    if "brightness" in body:
        s["brightness"] = round(max(0.05, min(1.0, float(body["brightness"]))), 2)
    if "idle_release" in body:
        s["idle_release"] = max(0, min(3600, int(body["idle_release"])))
    if "bt_offset_ms" in body:
        s["bt_offset_ms"] = max(0, min(1500, int(body["bt_offset_ms"])))
    zones[s.get("area", "")] = {k: s.get(k) for k in ZONE_KEYS}
    s["zones"] = zones
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


APPLIED = {}          # dernière couleur envoyée à chaque lampe : {id: {"xy", "hex", "grad"}}
# Effets intégrés au pont (CLIP v2, effects_v2) et façons de déployer un dégradé sur un ruban
EFFECTS_V2 = ("prism", "opal", "glisten", "sparkle", "fire", "candle", "underwater", "cosmos",
              "sunbeam", "enchant", "no_effect")
GRAD_MODES = ("interpolated_palette", "interpolated_palette_mirrored", "segmented_palette", "random_pixelated")


def _near(a, b, tol=0.012):
    return abs(a[0] - b[0]) < tol and abs(a[1] - b[1]) < tol


def _light_view(l, positions):
    color = None
    ap = APPLIED.get(l["id"], {})
    if l.get("color", {}).get("xy"):
        xy = l["color"]["xy"]
        color = xy_to_hex(xy.get("x", 0.3227), xy.get("y", 0.329))
        if ap.get("xy") and _near(ap["xy"], (xy.get("x", 0), xy.get("y", 0))):
            color = ap["hex"]               # la couleur choisie, pas son arrondi par le pont
    if l.get("color_temperature", {}).get("mirek_valid") and not l.get("color", {}).get("xy"):
        color = mirek_to_hex(l["color_temperature"].get("mirek"))
    if l.get("gradient", {}).get("points"):
        gxy = [(p["color"]["xy"]["x"], p["color"]["xy"]["y"]) for p in l["gradient"]["points"]
               if p.get("color", {}).get("xy")]
        grad = [xy_to_hex(x, y) for x, y in gxy]
        if ap.get("gxy") and len(ap["gxy"]) == len(gxy) and all(_near(a, b) for a, b in zip(ap["gxy"], gxy)):
            grad = list(ap["grad"])
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
        "pos": (positions.get(l["id"]) or {}).get("pos") if "pos" in (positions.get(l["id"]) or {}) else positions.get(l["id"]),
        "path": (positions.get(l["id"]) or {}).get("path"),
        "line": (positions.get(l["id"]) or {}).get("line"),
        # effets intégrés au pont (effects_v2) que la lampe sait jouer, et celui en cours
        "effects": [e for e in ((l.get("effects_v2") or {}).get("action") or {}).get("effect_values", [])
                    if e in EFFECTS_V2 and e != "no_effect"],
        "effect": ((l.get("effects_v2") or {}).get("status") or {}).get("effect", "no_effect"),
        # rendus possibles du dégradé (fondu, blocs, miroir…) et sens du contenu sur le ruban
        "grad_modes": [m for m in (l.get("gradient") or {}).get("mode_values", []) if m in GRAD_MODES],
        "grad_mode": (l.get("gradient") or {}).get("mode"),
        "order": (((l.get("content_configuration") or {}).get("order") or {}).get("order")),
    }


PM = 0.07
PCORNERS = [(PM, PM), (1 - PM, PM), (1 - PM, 1 - PM), (PM, 1 - PM)]


def perim(sv):
    """Point du tour de la pièce (coordonnées écran 0-1), comme dans l'éditeur de plan."""
    sv %= 4
    e, f = int(sv) % 4, sv - int(sv)
    a, b = PCORNERS[e], PCORNERS[(e + 1) % 4]
    return a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f


def dims_of(dims):
    """Largeur (mur de l'écran) et profondeur de la pièce en mètres ; carré par défaut."""
    try:
        w, d = float((dims or {}).get("w") or 1), float((dims or {}).get("d") or 1)
    except (TypeError, ValueError, AttributeError):
        w, d = 1.0, 1.0
    return max(0.5, min(40.0, w)), max(0.5, min(40.0, d))


def along(rb, u, dims=None):
    """Point du ruban à la fraction u (0-1) de sa longueur, en suivant les murs depuis son coin de
    départ et dans son sens, avec la vraie longueur de chaque mur (pièce rectangulaire)."""
    w, d = dims_of(dims)
    lens = [w, d, w, d]                       # mur avant, droit, fond, gauche
    c, seq = int(rb.get("corner", 0)) % 4, []
    for _ in range(max(1, min(4, int(rb.get("walls", 1))))):
        if rb.get("dir", 1) >= 0:
            seq.append((c, True)); c = (c + 1) % 4
        else:
            c = (c - 1) % 4; seq.append((c, False))
    s = max(0.0, min(1.0, u)) * sum(lens[e] for e, _ in seq)
    for k, (e, fwd) in enumerate(seq):
        if s <= lens[e] or k == len(seq) - 1:
            f = min(1.0, s / lens[e])
            return perim(e + (f if fwd else 1 - f))
        s -= lens[e]


def to_hue(px, py):
    return {"x": round(px * 2 - 1, 4), "y": round(1 - py * 2, 4)}


GRAD_POINTS = 5
rooms_cache = {"t": 0.0, "data": None}


# ---------------------------------------------------------------------------
# État du pont tenu à jour en direct : on écoute le flux d'événements du pont
# (/eventstream/clip/v2) au lieu de tout relire à chaque affichage.
# Sans flux (pont injoignable, vieux firmware), on relit tout toutes les 2 s.
# ---------------------------------------------------------------------------
LIVE_KINDS = ("light", "grouped_light", "room", "zone", "entertainment", "entertainment_configuration")


def open_events(cfg):
    """Flux d'événements du pont : renvoie d'abord [] (connecté), puis chaque lot d'événements."""
    req = urllib.request.Request(f"https://{cfg['bridge']}/eventstream/clip/v2",
                                 headers={"hue-application-key": cfg["username"], "Accept": "text/event-stream"})
    with urllib.request.urlopen(req, context=hms._SSL_CTX, timeout=90) as r:
        yield []
        for raw in r:
            line = raw.decode("utf-8", "ignore").strip()
            if line.startswith("data:"):
                try:
                    yield json.loads(line[5:])
                except ValueError:
                    pass


def _merge(dst, src):
    for k, v in src.items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            _merge(dst[k], v)
        else:
            dst[k] = v


class LiveBridge:
    def __init__(self):
        self.lock = threading.Lock()
        self.res, self.t, self.stream, self.started = {}, 0.0, False, False

    def dirty(self):
        self.t = 0.0

    def _full(self, cfg):
        res = {k: {d["id"]: d for d in hms.bridge_get(cfg, k) if "id" in d} for k in LIVE_KINDS}
        with self.lock:
            self.res, self.t = res, time.time()

    def get(self, cfg, kind):
        if not self.started:
            self.started = True
            threading.Thread(target=self._run, daemon=True).start()
        # avec le flux, une relecture complète toutes les 60 s suffit (filet de sécurité)
        if not self.res or time.time() - self.t > (60 if self.stream else 2):
            self._full(cfg)
        with self.lock:
            return copy.deepcopy(list(self.res.get(kind, {}).values()))

    def apply(self, events):
        with self.lock:
            for ev in events if isinstance(events, list) else []:
                for d in ev.get("data") or []:
                    kind, rid = d.get("type"), d.get("id")
                    if kind not in self.res or not rid:
                        continue
                    if ev.get("type") == "delete":
                        self.res[kind].pop(rid, None)
                    elif ev.get("type") == "add" or rid not in self.res[kind]:
                        self.res[kind][rid] = d
                    else:
                        _merge(self.res[kind][rid], d)

    def _run(self):
        while True:
            cfg = hms.load_config_or_none()
            if cfg:
                try:
                    for evs in open_events(cfg):
                        if not evs:            # (re)connecté : on a pu rater des événements
                            self.dirty()
                            self.stream = True
                        else:
                            self.apply(evs)
                except Exception:
                    pass
            self.stream = False
            time.sleep(5)


LIVE = LiveBridge()


def rooms_state(force=True):
    if not force and rooms_cache["data"] is not None and time.time() - rooms_cache["t"] < 1:
        return rooms_cache["data"]
    cfg = _cfg()
    if rooms_cache["t"] == 0:
        LIVE.dirty()                      # une action vient de changer le pont : on relit tout
    lights = {l["id"]: l for l in LIVE.get(cfg, "light")}
    owner_lights = {}
    for l in lights.values():
        owner_lights.setdefault(l.get("owner", {}).get("rid"), []).append(l["id"])
    # positions des lampes dans les zones de divertissement (pour colorer selon le placement)
    ent_owner = {e["id"]: e.get("owner", {}).get("rid") for e in LIVE.get(cfg, "entertainment")}
    positions = {}
    for a in LIVE.get(cfg, "entertainment_configuration"):
        for loc in a.get("locations", {}).get("service_locations", []):
            dev = ent_owner.get(loc.get("service", {}).get("rid"))
            pts = loc.get("positions") or []
            for lid in owner_lights.get(dev, []):
                if pts and lid not in positions:
                    positions[lid] = {"x": pts[0].get("x", 0), "y": pts[0].get("y", 0)}
    groups = {g["id"]: g for g in LIVE.get(cfg, "grouped_light")}
    plans = get_settings().get("room_plans") or {}
    rooms = []
    for rtype in ("room", "zone"):
        for r in LIVE.get(cfg, rtype):
            ids = []
            for c in r.get("children", []):
                if c.get("rtype") == "device":
                    ids += owner_lights.get(c["rid"], [])
                elif c.get("rtype") == "light":
                    ids.append(c["rid"])
            pl = plans.get(r["id"]) or {}
            pos_r = dict(positions)
            for lid, q in (pl.get("spots") or {}).items():
                pos_r[lid] = to_hue(q[0], q[1])
            for lid, rb in (pl.get("rubans") or {}).items():
                at = lambda u: to_hue(*along(rb, u, pl.get("dims")))
                pts = [at(k / (GRAD_POINTS - 1)) for k in range(GRAD_POINTS)]   # points du dégradé, du début à la fin
                line = [at(k / 48) for k in range(49)]                          # tracé fin (coins compris)
                pos_r[lid] = {"pos": pts[GRAD_POINTS // 2], "path": pts, "line": line}
            ls = [_light_view(lights[i], pos_r) for i in dict.fromkeys(ids) if i in lights]
            if not ls:
                continue
            gl = next((s["rid"] for s in r.get("services", []) if s.get("rtype") == "grouped_light"), None)
            g = groups.get(gl, {})
            rooms.append({
                "id": r["id"], "name": r.get("metadata", {}).get("name", "Pièce"), "type": rtype,
                "planned": r["id"] in plans,
                "archetype": r.get("metadata", {}).get("archetype", ""), "group": gl,
                "on": bool(g.get("on", {}).get("on", any(l["on"] for l in ls))),
                "bri": round(g.get("dimming", {}).get("brightness", 100)), "lights": ls})
    rooms.sort(key=lambda r: (r["type"] != "room", r["name"].lower()))
    rooms_cache.update(t=time.time(), data=rooms)
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
        APPLIED[body.get("id")] = {"xy": (x, y), "hex": body["color"]}
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


def _lum(h):
    r, g, b = (int(h[i:i + 2], 16) for i in (1, 3, 5))
    return 0.3 * r + 0.59 * g + 0.11 * b


room_jobs = {}        # pièce -> numéro du dernier envoi (un nouveau choix annule l'ancien)
SCENE_NAME = "Lueur"


def _rid(res):
    try:
        return res["data"][0]["rid"]
    except (KeyError, IndexError, TypeError):
        raise hms.HueError(f"Réponse inattendue du pont : {str(res)[:200]}")


def dynamic_scene(cfg, room, jobs, colors, speed):
    """Crée (ou met à jour) la scène « Lueur » de la pièce avec la palette, puis la lance en mode
    dynamique : le pont anime lui-même les couleurs à la vitesse demandée (0-1)."""
    bri = {l["id"]: max(1.0, float(l.get("bri") or 100)) for l in room["lights"]}
    actions = []
    for lid, b in jobs:
        a = {"on": {"on": True}, "dimming": {"brightness": bri.get(lid, 100.0)}}
        for k in ("color", "gradient", "effects_v2"):
            if k in b:
                a[k] = b[k]
        actions.append({"target": {"rid": lid, "rtype": "light"}, "action": a})
    palette = {"color": [{"color": {"xy": dict(zip("xy", hex_to_xy(c)))}, "dimming": {"brightness": 100.0}}
                         for c in colors[:9]],
               "dimming": [], "color_temperature": []}
    group = {"rid": room["id"], "rtype": room.get("type", "room")}
    existing = next((sc for sc in hms.bridge_get(cfg, "scene")
                     if sc.get("metadata", {}).get("name") == SCENE_NAME and sc.get("group", {}).get("rid") == room["id"]), None)
    body = {"actions": actions, "palette": palette, "speed": speed, "auto_dynamic": True}
    req = lambda method, path, b: hms.bridge_request(cfg["bridge"], method, path, key=cfg["username"], body=b)
    try:
        if existing:
            req("PUT", f"/clip/v2/resource/scene/{existing['id']}", body)
            sid = existing["id"]
        else:
            res = req("POST", "/clip/v2/resource/scene",
                      dict(body, type="scene", metadata={"name": SCENE_NAME}, group=group))
            sid = _rid(res)
    except hms.HueError as e:
        if "effects" not in str(e):
            raise
        body["palette"]["effects_v2"] = []       # certains ponts exigent aussi la liste des effets (v2)
        if existing:
            req("PUT", f"/clip/v2/resource/scene/{existing['id']}", body)
            sid = existing["id"]
        else:
            res = req("POST", "/clip/v2/resource/scene",
                      dict(body, type="scene", metadata={"name": SCENE_NAME}, group=group))
            sid = _rid(res)
    req("PUT", f"/clip/v2/resource/scene/{sid}", {"recall": {"action": "dynamic_palette"}})



def room_palette(body):
    """Applique une palette à une pièce : chaque lampe prend la couleur de sa position ; un ruban
    à dégradé suit son tracé sur le plan (sinon du plus foncé au plus clair). La réponse donne
    tout de suite les couleurs choisies ; l'envoi aux lampes se fait en arrière-plan."""
    cfg = _cfg()
    colors = [c for c in body.get("colors", []) if isinstance(c, str) and HEX_RE.match(c)][:8]
    if not colors:
        raise ValueError("Palette vide.")
    room = next((r for r in rooms_state(force=False) if r["id"] == body.get("id")), None)
    if not room:
        raise ValueError("Pièce introuvable.")
    spread = body.get("spread", "lr")
    gmode = body.get("grad_mode") if body.get("grad_mode") in GRAD_MODES else None
    ls = room["lights"]
    import math

    def t_of(i, p):
        if not p:
            return i / max(1, len(ls) - 1)
        x, y = p["x"], p["y"]
        if spread == "fb":
            return (1 - y) / 2
        if spread == "centre":
            return min(1.0, (x * x + y * y) ** 0.5 / 1.42)
        if spread == "tour":
            return ((math.atan2(-y, x) + math.pi * 1.5) % (2 * math.pi)) / (2 * math.pi)
        return (x + 1) / 2

    rgb = [tuple(int(c[i:i + 2], 16) for i in (1, 3, 5)) for c in colors]
    hexc = lambda v: "#%02x%02x%02x" % tuple(max(0, min(255, round(x))) for x in v)

    def mix(a, b, f):                       # mélange par la teinte (le chemin le plus court) : reste vif
        ha, la, sa = colorsys.rgb_to_hls(*(v / 255 for v in a))
        hb, lb, sb = colorsys.rgb_to_hls(*(v / 255 for v in b))
        if sa < 0.08:
            ha = hb
        if sb < 0.08:
            hb = ha
        dh = ((hb - ha + 0.5) % 1.0) - 0.5
        r_, g_, b_ = colorsys.hls_to_rgb((ha + dh * f) % 1.0, la + (lb - la) * f, sa + (sb - sa) * f)
        return (r_ * 255, g_ * 255, b_ * 255)

    def pal_at(t):                          # une vraie couleur de la palette (jamais de mélange inventé)
        t = max(0.0, min(1.0, t))
        if spread == "tour":
            return rgb[int(round(t * len(rgb))) % len(rgb)]
        return rgb[min(len(rgb) - 1, int(round(t * (len(rgb) - 1))))]

    def along(grad, u):                     # couleur du point du ruban le plus proche de la fraction u
        return grad[int(round(max(0.0, min(1.0, u)) * (len(grad) - 1)))]

    result, jobs = {}, []
    by_lum = sorted(rgb, key=lambda v: 0.3 * v[0] + 0.59 * v[1] + 0.11 * v[2])
    strips = []                             # (tracé, dégradé) des rubans placés, pour la continuité
    for i, l in enumerate(ls):
        if not l.get("has_gradient"):
            continue
        if l.get("path"):                   # palette étalée le long du ruban (en boucle s'il fait le tour)
            pth, n = l["path"], len(rgb)
            loop = abs(pth[0]["x"] - pth[-1]["x"]) < 1e-3 and abs(pth[0]["y"] - pth[-1]["y"]) < 1e-3
            # Points de couleur envoyés au ruban (5 au plus, répartis à égale distance par le pont).
            # En boucle, le dernier point reprend le premier pour refermer le tour sans cassure :
            # on garde donc au plus 4 couleurs distinctes, réparties régulièrement dans la palette.
            if loop:
                idx = list(range(n)) if n <= GRAD_POINTS - 1 else [round(i * n / (GRAD_POINTS - 1)) % n for i in range(GRAD_POINTS - 1)]
                idx = idx + [idx[0]]
            else:
                idx = list(range(n)) if n <= GRAD_POINTS else [round(i * (n - 1) / (GRAD_POINTS - 1)) for i in range(GRAD_POINTS)]
            if len(idx) < 2:
                idx = idx * 2
            grad = [rgb[i] for i in idx]
            if l.get("line"):
                strips.append((l["line"], grad))
        else:                               # pas de plan : du plus foncé au plus clair
            grad = [along(by_lum, k / (GRAD_POINTS - 1)) for k in range(GRAD_POINTS)]
        gh = [hexc(c) for c in grad]
        gxy = [hex_to_xy(c) for c in gh]
        gb = {"points": [{"color": {"xy": {"x": x, "y": y}}} for x, y in gxy]}
        if gmode and gmode in (l.get("grad_modes") or []):
            gb["mode"] = gmode
        jobs.append((l["id"], {"on": {"on": True}, "gradient": gb}))
        APPLIED[l["id"]] = {"grad": gh, "gxy": gxy}
        result[l["id"]] = {"gradient": gh, "color": gh[len(gh) // 2]}

    gm = gmode or "interpolated_palette"

    def grad_at(grad, u):                   # couleur affichée par le ruban à la fraction u de sa longueur
        m, u = len(grad), max(0.0, min(1.0, u))
        if gm == "segmented_palette":       # blocs nets
            return grad[min(m - 1, int(u * m))]
        if gm == "interpolated_palette_mirrored":
            u = abs(2 * u - 1)              # le dégradé part du milieu et se reflète vers les deux bouts
        x = u * (m - 1)
        k = min(int(x), m - 2)
        f = x - k
        return tuple(a + (b - a) * f for a, b in zip(grad[k], grad[k + 1]))

    def near_strip(p):                      # spot : la couleur du ruban juste à côté de lui (avec l'entre-deux)
        best = None
        for line, grad in strips:
            for k, q in enumerate(line):
                d = (q["x"] - p["x"]) ** 2 + (q["y"] - p["y"]) ** 2
                if best is None or d < best[0]:
                    best = (d, grad_at(grad, k / (len(line) - 1)))
        return best[1] if best else None

    for i, l in enumerate(ls):
        if l.get("has_gradient"):
            continue
        if l.get("has_color"):
            c = (near_strip(l["pos"]) if strips and l.get("pos") else None) or pal_at(t_of(i, l.get("pos")))
            c = hexc(c)
            x, y = hex_to_xy(c)
            jobs.append((l["id"], {"on": {"on": True}, "color": {"xy": {"x": x, "y": y}}}))
            APPLIED[l["id"]] = {"xy": (x, y), "hex": c}
            result[l["id"]] = {"color": c}
        else:
            jobs.append((l["id"], {"on": {"on": True}}))
    running = {l["id"] for l in ls if l.get("effect") not in (None, "no_effect")}
    for lid, b in jobs:                     # une scène remplace l'effet intégré en cours
        if lid in running:
            b["effects_v2"] = {"action": {"effect": "no_effect"}}
    gen = room_jobs.get(room["id"], 0) + 1
    room_jobs[room["id"]] = gen
    try:
        speed = float(body.get("speed") or 0)
    except (TypeError, ValueError):
        speed = 0.0
    if speed > 0:
        # Scène animée : le pont fait lui-même glisser la palette, au niveau des LED du ruban
        dynamic_scene(cfg, room, jobs, colors, max(0.05, min(1.0, speed)))
        rooms_cache["t"] = 0
        return {"ok": True, "lights": result, "ms": 0, "animated": True}

    def send():
        for lid, b in jobs:
            if room_jobs.get(room["id"]) != gen:
                return                      # une autre scène a été choisie entre-temps
            try:
                _put(cfg, "light", lid, b)
            except hms.HueError:
                pass
            time.sleep(0.1)                 # le pont accepte ~10 commandes par seconde
        rooms_cache["t"] = 0
    threading.Thread(target=send, daemon=True).start()
    return {"ok": True, "lights": result, "ms": len(jobs) * 110}


def room_effect(body):
    """Lance un effet intégré au pont (bougie, étincelles…) sur les lampes de la pièce qui le savent
    jouer. Chaque lampe garde sa couleur actuelle comme base ; « no_effect » arrête l'effet."""
    cfg = _cfg()
    eff = body.get("effect")
    if eff not in EFFECTS_V2:
        raise ValueError("Effet inconnu.")
    room = next((r for r in rooms_state(force=False) if r["id"] == body.get("id")), None)
    if not room:
        raise ValueError("Pièce introuvable.")
    try:
        speed = max(0.0, min(1.0, float(body.get("speed", 0.5))))
    except (TypeError, ValueError):
        speed = 0.5
    jobs = []
    for l in room["lights"]:
        if eff == "no_effect":
            if l.get("effect") not in (None, "no_effect"):
                jobs.append((l["id"], {"effects_v2": {"action": {"effect": "no_effect"}}}))
            continue
        if eff not in (l.get("effects") or []):
            continue
        params = {"speed": speed}
        ap = APPLIED.get(l["id"], {})
        hx = ap.get("hex") or (ap.get("grad") or [None])[len(ap.get("grad") or [None]) // 2] or l.get("color")
        if l.get("has_color") and hx and HEX_RE.match(hx):
            params["color"] = {"xy": dict(zip("xy", hex_to_xy(hx)))}
        jobs.append((l["id"], {"on": {"on": True}, "effects_v2": {"action": {"effect": eff, "parameters": params}}}))
    if not jobs and eff != "no_effect":
        raise ValueError("Aucune lampe de cette pièce ne sait jouer cet effet.")
    gen = room_jobs.get(room["id"], 0) + 1
    room_jobs[room["id"]] = gen

    def send():
        for lid, b in jobs:
            if room_jobs.get(room["id"]) != gen:
                return
            try:
                _put(cfg, "light", lid, b)
            except hms.HueError as e:
                print(f"Effet {eff} refusé par {lid} : {e}", flush=True)
            time.sleep(0.1)
        rooms_cache["t"] = 0
    threading.Thread(target=send, daemon=True).start()
    return {"ok": True, "count": len(jobs), "lights": {lid: {"effect": eff} for lid, _ in jobs}}


def light_order(body):
    """Sens du contenu sur un ruban (content_configuration.order) : dans quel sens le pont déroule
    ses effets et ses dégradés le long des LED."""
    order = body.get("order")
    if order not in ("forward", "reversed"):
        raise ValueError("Sens invalide.")
    _put(_cfg(), "light", body.get("light"), {"content_configuration": {"order": {"order": order}}})
    rooms_cache["t"] = 0
    return {"ok": True, "order": order}


def plan_eq(body):
    """Équilibre de luminosité d'une zone de synchro : {lampe: facteur 0,1-1}, appliqué en direct."""
    aid = str(body.get("id", ""))[:64]
    if not aid:
        raise ValueError("Zone manquante.")
    eq = {}
    for k, v in (body.get("eq") or {}).items():
        f = round(max(0.1, min(1.0, float(v))), 2)
        if f < 1.0:
            eq[str(k)[:64]] = f
    s = get_settings()
    plans = s.get("plans") if isinstance(s.get("plans"), dict) else {}
    p = plans.get(aid) if isinstance(plans.get(aid), dict) else {}
    p["eq"] = eq
    plans[aid] = p
    s["plans"] = plans
    write_json(SETTINGS_PATH, s)
    return {"ok": True, "eq": eq}


ZONE_PREFIX = "Lueur · "
STRIP_SPOT = hms.STRIP_SPOT


def room_sync_plan(cfg, room, area, plan, lights, strips=None):
    """Plan de la zone de synchro d'une pièce, recopié de son plan Lueur (mêmes conventions que
    l'éditeur) : ordre et place de chaque segment du ruban, place de chaque spot."""
    if strips is None:
        strips = {l["id"]: dict({"walls": 1, "corner": 0, "dir": 1}, **((plan.get("rubans") or {}).get(l["id"]) or {}))
                  for l in room["lights"] if l.get("has_gradient")}
    rows = hms.channel_info(cfg, area)
    light_of_dev = {lights.get(l["id"], {}).get("owner", {}).get("rid"): l["id"] for l in room["lights"]}
    ch, rubans, spots, by_dev = {}, {}, {}, {}
    for r in rows:
        by_dev.setdefault(r["dev"], []).append(r)
    for dev, rs in by_dev.items():
        lid = light_of_dev.get(dev)
        rb = strips.get(lid)
        if rb and len(rs) > 1:
            rubans[dev] = rb
            rs.sort(key=lambda r: r["idx"])
            for k, r in enumerate(rs):
                u = (k + 0.5) / len(rs)
                px, py = along(rb, u, plan.get("dims"))
                ch[str(r["id"])] = {"t": round(u, 4), "x": round(px * 2 - 1, 4), "y": round(1 - py * 2, 4)}
        else:
            for r in rs:
                q = (plan.get("spots") or {}).get(lid) or [(r["x"] + 1) / 2, (1 - r["y"]) / 2]
                q = [max(PM, min(1 - PM, float(q[0]))), max(PM, min(1 - PM, float(q[1])))]
                spots[str(r["id"])] = q
                ch[str(r["id"])] = {"t": round(q[0], 4), "x": round(q[0] * 2 - 1, 4), "y": round(1 - q[1] * 2, 4)}
    return rows, ch, rubans, spots, light_of_dev, by_dev


def refresh_room_zone(rid):
    """Recopie le plan d'une pièce dans le plan de sa zone de synchro « Lueur · <pièce> », si elle existe
    (sans rien changer sur le pont). Renvoie (zone, lignes des canaux, lampe de chaque appareil)."""
    cfg = _cfg()
    room = next((r for r in rooms_state(force=False) if r["id"] == rid), None)
    if not room:
        return None
    zname = (ZONE_PREFIX + room["name"])[:32]
    area = next((a for a in hms.get_areas(cfg) if a.get("metadata", {}).get("name") == zname), None)
    if not area:
        return None
    plan = (get_settings().get("room_plans") or {}).get(rid) or {}
    lights = {l["id"]: l for l in hms.bridge_get(cfg, "light")}
    rows, ch, rubans, spots, light_of_dev, _ = room_sync_plan(cfg, room, area, plan, lights)
    s = get_settings()
    plans = s.get("plans") if isinstance(s.get("plans"), dict) else {}
    old = plans.get(area["id"]) if isinstance(plans.get(area["id"]), dict) else {}
    plans[area["id"]] = {"ch": ch, "rubans": rubans, "spots": spots, "dims": plan.get("dims") or {},
                         **({"eq": old["eq"]} if old.get("eq") else {})}
    s["plans"] = plans
    write_json(SETTINGS_PATH, s)
    return room, area, rows, light_of_dev


def color_test(body):
    """Test « couleurs par segment » depuis le plan d'une pièce : enregistre le plan, recalcule le plan
    de sa zone de synchro et allume chaque segment d'une couleur (2 min). Renvoie les couleurs pour
    que l'écran montre les mêmes."""
    rid = str(body.get("id", ""))[:64]
    s = get_settings()
    if body.get("stop"):
        s["test"] = {}
        write_json(SETTINGS_PATH, s)
        return {"ok": True, "stopped": True}
    save_plan({"type": "room", "id": rid, "rubans": body.get("rubans") or {}, "spots": body.get("spots") or {},
               "dims": body.get("dims")})
    got = refresh_room_zone(rid)
    if not got:
        raise ValueError("Crée d'abord la zone de synchro de cette pièce.")
    room, area, rows, light_of_dev = got
    if get_settings().get("area") != area["id"]:
        update_settings({"area": area["id"]})          # le test passe par la zone de synchro de la pièce
    s = get_settings()
    s["test"] = {"area": area["id"], "until": time.time() + 120, "mode": "colors"}
    write_json(SETTINGS_PATH, s)
    plans = s.get("plans") or {}
    started = False
    if not service_state()["active"]:
        systemctl("start", SERVICE)
        started = True
    cmap = hms.test_color_map(hms.plan_channels(area, plans), {r["id"]: r["kind"] for r in rows})
    seg, spot = [], {}
    for r in sorted(rows, key=lambda r: r["idx"]):
        lid = light_of_dev.get(r["dev"])
        if lid in (l["id"] for l in room["lights"] if l.get("has_gradient")):
            seg.append(cmap.get(r["id"]))
        elif lid:
            spot[lid] = cmap.get(r["id"])
    return {"ok": True, "segments": seg, "spots": spot, "started": started, "seconds": 120}


def area_from_room(body):
    """Crée (ou met à jour) sur le pont la zone de divertissement « Lueur · <pièce> » à partir du plan
    Lueur de la pièce : chaque lampe à sa place, le ruban de son début à sa fin. Le plan est recopié
    dans la zone de synchro (ordre des segments, spots), et la zone est choisie pour la musique."""
    cfg = _cfg()
    rid = str(body.get("id", ""))[:64]
    if "rubans" in body or "spots" in body:          # on enregistre d'abord le plan tel qu'il est à l'écran
        save_plan({"type": "room", "id": rid, "rubans": body.get("rubans") or {}, "spots": body.get("spots") or {},
                   "dims": body.get("dims")})
    room = next((r for r in rooms_state() if r["id"] == rid), None)
    if not room:
        raise ValueError("Pièce introuvable.")
    plan = (get_settings().get("room_plans") or {}).get(rid) or {}
    lights = {l["id"]: l for l in hms.bridge_get(cfg, "light")}
    ent_of_dev = {e.get("owner", {}).get("rid"): e["id"] for e in hms.bridge_get(cfg, "entertainment") if e.get("renderer")}
    n = len(room["lights"])
    locs, used, strips = [], {}, {}
    for i, l in enumerate(room["lights"]):
        eid = ent_of_dev.get(lights.get(l["id"], {}).get("owner", {}).get("rid"))
        if not eid or eid in used.values():
            continue                                  # lampe sans couleur (pas de divertissement possible)
        a = (l.get("archetype") or "").lower()
        z = 1.0 if any(k in a for k in ("ceiling", "recessed", "spot")) else 0.8 if l.get("has_gradient") else 0.0
        pt = lambda q: {"x": round(q[0] * 2 - 1, 3), "y": round(1 - q[1] * 2, 3), "z": z}
        if l.get("has_gradient"):
            rb = dict({"walls": 1, "corner": 0, "dir": 1}, **((plan.get("rubans") or {}).get(l["id"]) or {}))
            # Un seul point, à l'avant à mi-hauteur : c'est la seule position où le pont garde tous
            # les segments du ruban séparés (testé le 9/11 : ailleurs, ou avec 2 points, il les
            # regroupe en 1 à 5 canaux). Lueur n'en a pas besoin : il suit son propre plan.
            pos = [dict(STRIP_SPOT)]
            strips[l["id"]] = rb
        else:
            q = (plan.get("spots") or {}).get(l["id"])
            if not q:
                p = l.get("pos") or {"x": round(-0.7 + 1.4 * i / max(1, n - 1), 3) if n > 1 else 0.0, "y": 0.0}
                q = [(p["x"] + 1) / 2, (1 - p["y"]) / 2]
            pos = [pt(q)]
        locs.append({"service": {"rid": eid, "rtype": "entertainment"}, "positions": pos})
        used[l["id"]] = eid
    if not locs:
        raise ValueError("Aucune lampe couleur dans cette pièce.")
    if len(locs) > hms.MAX_AREA_LIGHTS:
        raise ValueError(f"Une zone de divertissement accepte {hms.MAX_AREA_LIGHTS} lampes au plus "
                         f"(cette pièce en a {len(locs)}).")
    name = (ZONE_PREFIX + room["name"])[:32]
    path = "/clip/v2/resource/entertainment_configuration"
    req = lambda method, p, b: hms.bridge_request(cfg["bridge"], method, p, key=cfg["username"], body=b)
    existing = next((a for a in hms.get_areas(cfg) if a.get("metadata", {}).get("name") == name), None)
    if existing:
        if existing.get("status") == "active":       # le pont refuse de modifier une zone en cours de flux
            req("PUT", f"{path}/{existing['id']}", {"action": "stop"})
        req("PUT", f"{path}/{existing['id']}", {"metadata": {"name": name}, "configuration_type": "music",
                                               "locations": {"service_locations": locs}})
        aid = existing["id"]
    else:
        res = req("POST", path, {"type": "entertainment_configuration", "metadata": {"name": name},
                                 "configuration_type": "music", "locations": {"service_locations": locs}})
        errs = res.get("errors") if isinstance(res, dict) else None
        if errs:
            raise hms.HueError("Le pont a refusé la zone : " + "; ".join(e.get("description", "?") for e in errs))
        aid = _rid(res)
    area = next((a for a in hms.get_areas(cfg) if a["id"] == aid), None)
    if not area:
        raise hms.HueError("Zone créée, mais introuvable sur le pont.")
    rows, ch, rubans, spots, light_of_dev, by_dev = room_sync_plan(cfg, room, area, plan, lights, strips)
    update_settings({"area": aid})                   # la zone devient celle de la musique
    s = get_settings()
    plans = s.get("plans") if isinstance(s.get("plans"), dict) else {}
    eq = (plans.get(aid) or {}).get("eq") if isinstance(plans.get(aid), dict) else None
    plans[aid] = {"ch": ch, "rubans": rubans, "spots": spots, "dims": plan.get("dims") or {}, **({"eq": eq} if eq else {})}
    s.update(plans=plans, area_rev=int(s.get("area_rev", 0)) + 1)
    write_json(SETTINGS_PATH, s)
    areas_cache["data"] = None
    segs = max((len(rs) for dev, rs in by_dev.items() if light_of_dev.get(dev) in strips), default=0)
    return {"ok": True, "area_id": aid, "name": name, "created": not existing,
            "lights": len(locs), "channels": len(rows), "segments": segs}


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
    protocol_version = "HTTP/1.1"      # connexion gardée ouverte : réponses plus rapides

    def setup(self):
        super().setup()
        import socket
        try:                                 # pas d'attente TCP entre en-têtes et contenu
            self.request.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass

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
            while n > 0:                     # on vide la requête pour garder la connexion saine
                n -= len(self.rfile.read(min(n, 65536)) or b"x" * n)
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
        if path == "/api/plan":
            try:
                from urllib.parse import parse_qs, urlparse
                q = parse_qs(urlparse(self.path).query)
                if q.get("room"):
                    return self._send(200, room_plan_info(q["room"][0]))
                return self._send(200, plan_info(q.get("area", [""])[0]))
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
            if path in ("/api/light", "/api/room", "/api/room/palette", "/api/room/effect", "/api/light/order"):
                fn = {"/api/light": set_light, "/api/room": set_room, "/api/room/palette": room_palette,
                      "/api/room/effect": room_effect, "/api/light/order": light_order}[path]
                try:
                    return self._send(200, fn(body))
                except hms.HueError as e:
                    return self._send(502, {"error": str(e)})
            if path == "/api/plan":
                return self._send(200, save_plan(body))
            if path == "/api/area/from_room":
                try:
                    return self._send(200, area_from_room(body))
                except hms.HueError as e:
                    return self._send(502, {"error": str(e)})
            if path == "/api/plan/colortest":
                try:
                    return self._send(200, color_test(body))
                except hms.HueError as e:
                    return self._send(502, {"error": str(e)})
            if path == "/api/plan/eq":
                return self._send(200, plan_eq(body))
            if path == "/api/plan/test":
                return self._send(200, plan_test(body))
            if path == "/api/plan/identify":
                try:
                    return self._send(200, identify_light(body))
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
.lamp,.room,.rhead{background-origin:border-box!important;background-clip:border-box!important}
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
.sheet{position:fixed;left:0;right:0;bottom:0;z-index:50;max-width:520px;margin:0 auto;background:var(--card);border-radius:22px 22px 0 0;transform:translateY(105%);transition:transform .3s cubic-bezier(.2,.8,.2,1);max-height:82vh;max-height:86dvh;overflow:auto;overscroll-behavior:contain;-webkit-overflow-scrolling:touch;padding:0 16px calc(24px + var(--safe-b))}
.sheet.open{transform:none}
.sheet .grab{width:38px;height:5px;border-radius:3px;background:#5c5d63;margin:0 auto;position:sticky;top:0;z-index:3;box-shadow:0 0 0 8px var(--card);transform:translateY(8px)}
.sheet .sh{display:flex;align-items:center;justify-content:space-between;margin:0 -16px 12px;padding:16px 20px 10px;position:sticky;top:0;z-index:2;background:var(--card)}
.sheet .sh .txtbtn{padding:8px 4px;min-width:44px;text-align:right}
body.locked{overflow:hidden}
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
.cover{position:relative;width:100%;aspect-ratio:1;border-radius:22px;overflow:hidden;box-shadow:0 24px 60px rgba(0,0,0,.6);isolation:isolate;-webkit-mask-image:-webkit-radial-gradient(white,black);transform:translateZ(0)}
.cover .glow{position:absolute;inset:-20%;filter:blur(30px);transition:background .25s}
.cover .lights{position:absolute;inset:0}
.cover .lights i{position:absolute;width:26px;height:26px;margin:-13px 0 0 -13px;border-radius:50%;transition:background .12s,box-shadow .12s,transform .12s}
.proom{position:relative;background:#141518;border-radius:20px;padding:26px 10px 10px;border:1px solid #2c2d32}
.proom .front{position:absolute;top:8px;left:0;right:0;text-align:center;font-size:10px;letter-spacing:2px;color:var(--t3);font-weight:700}
.proom svg{display:block;width:100%;height:auto;touch-action:none;user-select:none;-webkit-user-select:none}
.proom .spot{cursor:grab}
.rcard{background:var(--card);border-radius:18px;padding:14px 14px 16px;margin-top:14px}
.rcard .h{display:flex;align-items:center;gap:10px;margin-bottom:12px}
.rcard .h b{font-size:17px}.rcard .h small{color:var(--t2);font-size:13px}
.rcard .lb{color:var(--t2);font-size:12px;font-weight:600;letter-spacing:1px;text-transform:uppercase;margin:12px 2px 6px}
.coverwrap{position:relative;width:min(62vw,240px,32vh);aspect-ratio:1}
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
.prev.live{gap:4px;justify-content:center}.prev.live i{width:auto;flex:1;max-width:30px;height:auto;aspect-ratio:1;transition:opacity .06s,transform .06s,box-shadow .06s}
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
.spr .seg.wide{grid-auto-columns:minmax(0,1fr)}.spr .seg.wide button{padding:8px 0;font-size:14px}

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
button,a,label,.sl,[data-sheet]{touch-action:manipulation;-webkit-tap-highlight-color:transparent}
button{transition:transform .08s,opacity .08s}
button:active{transform:scale(.96);opacity:.82}
.sl:active,.tabs button:active{transform:none}
.leds{display:flex;gap:4px;justify-content:center;margin-top:12px;height:10px;width:min(78vw,300px)}
.leds i{flex:1;max-width:26px;border-radius:5px;background:#2a2b30;transition:background .06s,box-shadow .06s}
.leds.off{opacity:.25}
@media (max-height:760px){
  .coverwrap{width:min(62vw,240px,27vh)}.syhead{padding-top:calc(10px + var(--safe-t))}.leds{margin-top:8px}
  .stage{margin-top:10px}.stitle{margin-top:12px;font-size:20px}.pbar{margin-top:10px}.pchip{margin-top:8px}
  .ctrls{margin-top:16px}.ctrl .ci{width:52px;height:52px}.dock{margin-top:16px}.power{width:78px!important;height:78px!important}
}
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
      <div class="leds" id="leds" title="Ce que reçoivent les lampes en ce moment"></div>
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

  <!-- PLANS DES PIÈCES -->
  <section class="view" data-view="plans">
    <div class="nh"><button class="rb" data-back aria-label="Retour"><svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M20 12H5M11 5l-7 7 7 7"/></svg></button><span class="t">Pièces et zones de synchro</span></div>
    <p class="note" style="padding:16px 20px 0">Place tes lampes comme dans la vraie pièce. La synchro (Comète, Vague, Stéréo…) et les couleurs des scènes suivent ce plan.</p>
    <div id="plansList"></div>
  </section>
  <section class="view" data-view="plan">
    <div class="nh"><button class="rb" data-back aria-label="Retour"><svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M20 12H5M11 5l-7 7 7 7"/></svg></button><span class="t" id="planTitle">Plan</span><button class="txtbtn" id="planSave">OK</button></div>
    <div class="pad" style="padding-top:14px">
      <div class="proom"><span class="front">ÉCRAN · DEVANT</span><svg id="planSvg" viewBox="0 0 100 75"></svg></div>
      <p class="hint" id="planHint" style="margin:10px 4px 0">Fais glisser les lampes sur le plan.</p>
      <div id="planRubans"></div>
      <button class="row" id="planReset" style="margin-top:18px;background:var(--card);border-radius:16px;min-height:56px;justify-content:center;color:var(--blue);font-weight:600">Reprendre les positions de l'app Hue</button>
      <div style="height:30px"></div>
    </div>
  </section>

  <!-- RÉGLAGES AVANCÉS -->
  <section class="view" data-view="avances">
    <div class="nh"><button class="rb" data-back aria-label="Retour"><svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M20 12H5M11 5l-7 7 7 7"/></svg></button><span class="t">Réglages avancés</span><button class="txtbtn" id="advReset">Rétablir</button></div>
    <div class="pad" style="padding-top:6px;color:var(--t2);font-size:15px;padding-left:20px" id="advStatus"></div>
    <div class="stagebox" id="stage"><div class="h"><span class="label" style="padding:0">Aperçu</span><span style="color:var(--t2);font-size:12px;display:flex;align-items:center;gap:6px"><i class="dot on"></i><span id="prevSub"></span></span></div><div class="prev" id="prev"></div></div>
    <div class="pad">
      <div class="label in">Effet</div>
      <div class="seg hidden" id="advTarget" style="margin-bottom:6px"></div><p class="hint hidden" id="advLayers" style="margin:2px 4px 12px"></p>
      <div class="grid2" id="advEffects"></div>
      <div class="label in">Vitesse</div><div class="seg" id="advSpeed"></div><p class="hint" id="speedHint" style="margin:8px 4px 0"></p>
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
      <button class="row" id="plansRow"><span class="ic" data-i="zones"></span><span class="bd"><span class="tx"><span class="t1">Pièces et zones de synchro</span><span class="t2">Plans, et création des zones pour la musique</span></span><svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M9 6l6 6-6 6"/></svg></span></button>
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
<div class="sheet" id="shEffet"><div class="grab"></div><div class="sh"><b>Effet</b><button class="txtbtn" data-close>OK</button></div><div class="seg hidden" id="effTarget" style="background:var(--card2);margin-bottom:6px"></div><p class="note hidden" id="effLayers" style="padding:2px 4px 12px"></p><div class="grid2" id="effList"></div>
  <div class="label" style="padding:18px 4px 8px">Vitesse</div><div class="seg" id="effSpeed" style="background:var(--card2)"></div>
  <button class="row" id="effAdv" style="margin-top:14px;background:var(--card2);border-radius:16px;min-height:62px"><span class="ic" style="width:60px" data-i="sliders"></span><span class="bd" style="border:0"><span class="tx"><span class="t1" style="font-size:16px">Réglages avancés</span><span class="t2" style="font-size:13px">Rythme, flashs, couleurs, motif</span></span><svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M9 6l6 6-6 6"/></svg></span></button></div>
<div class="sheet" id="shInt"><div class="grab"></div><div class="sh"><b>Intensité</b><button class="txtbtn" data-close>OK</button></div><div id="intList" class="list" style="border-radius:18px;background:var(--card2)"></div><p class="note" style="padding:12px 4px 0" id="intNote"></p></div>
<div class="sheet" id="shCouleur"><div class="grab"></div><div class="sh"><b>Couleur</b><button class="txtbtn" data-close>OK</button></div><div class="grid3" id="palList"></div><p class="note" style="padding:12px 4px 0">« Créer » : depuis une photo ou en choisissant les couleurs. La palette peut aussi servir de scène dans tes pièces.</p></div>
<div class="sheet" id="shLum"><div class="grab"></div><div class="sh"><b>Luminosité</b><button class="txtbtn" data-close>OK</button></div>
  <div style="display:flex;justify-content:space-between;margin:0 4px"><span>Luminosité maximale</span><span id="lumPct" style="color:var(--t2)">100 %</span></div>
  <div class="sl" id="lumSl" style="margin:12px 4px 4px"><div class="tr"></div><div class="fi"></div><div class="kn"></div></div>
  <p class="note" style="padding:8px 4px 0">Plafond de luminosité pendant la synchro. Les flashs ne dépassent jamais cette valeur.</p></div>
<div class="sheet" id="shZone"><div class="grab"></div><div class="sh"><b>Synchroniser</b><button class="txtbtn" data-close>OK</button></div><div class="list" id="zoneList" style="border-radius:18px;background:var(--card2)"></div>
  <button class="cta ghost" id="zoneFromRoom" style="margin-top:14px">Créer la zone d'une pièce…</button>
  <button class="cta ghost" id="zoneLamps" style="margin-top:10px">Choisir mes lampes…</button>
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
  ["glisse", "Glissé", "La palette coule le long du ruban, poussée par le rythme", true],
  ["comete", "Comète", "Une traînée tourne sur le ruban, poussée par le rythme", true],
  ["vague", "Vague", "La palette défile, sans flash", true],
  ["vumetre", "Vu-mètre", "Se remplit avec le volume", true],
  ["stereo", "Stéréo", "Gauche et droite séparées", true],
  ["etincelles", "Étincelles", "Éclats au hasard sur les aigus", true],
  ["respiration", "Respiration", "Monte et descend doucement", true]
];

const SPEEDS = [[0.5, "Demi-temps"], [1, "Normale"], [2, "Double"]];
const SPEED_D = { pulse: "Demi-temps : un temps sur deux. Double : un flash entre deux temps.", spectrum: "Demi-temps : un temps sur deux. Double : un flash entre deux temps.",
  comete: "Vitesse à laquelle la comète fait le tour du ruban.", glisse: "Vitesse de glisse et force de l'élan sur chaque temps.", vague: "Vitesse de défilement des couleurs.", vumetre: "Vitesse à laquelle le niveau redescend.",
  stereo: "Durée des éclats sur les temps.", etincelles: "Durée des éclats.", respiration: "Demi-temps : 16 s par souffle. Double : 4 s." };
const KIND_N = { ruban: "Ruban", spots: "Spots", play: "Play", lampes: "Lampes" };
let effTarget = "all";
const effName = m => (EFFECTS.find(e => e[0] === m) || EFFECTS[0])[1].replace(" étalé", "");
const spTag = v => (v || 1) === 1 ? "" : v > 1 ? " ×2" : " ×½";
function zoneKinds() { const z = currentZone(); return z && z.kinds ? Object.keys(z.kinds).filter(k => z.kinds[k]) : []; }
function effCur() {
  const st = S.settings, L = st.layers || {};
  return effTarget !== "all" && L[effTarget] ? L[effTarget] : { mode: st.mode, speed: st.speed || 1 };
}
function effSet(patch) {          // patch : { mode } ou { speed }
  const st = S.settings, c = { ...effCur(), ...patch };
  if (effTarget === "all") return save(patch.mode ? { mode: c.mode, layers: {} } : { speed: c.speed }, true);
  const L = { ...(st.layers || {}) };
  if (c.mode === st.mode && c.speed === (st.speed || 1)) delete L[effTarget]; else L[effTarget] = c;
  save({ layers: L }, true);
}
function effSummary() {
  const st = S.settings, L = st.layers || {}, ks = Object.keys(L).filter(k => zoneKinds().includes(k));
  if (!ks.length) return "";
  return ks.map(k => `${KIND_N[k]} : ${effName(L[k].mode)}${spTag(L[k].speed)}`).join(" · ") + ` · le reste : ${effName(st.mode)}${spTag(st.speed)}`;
}
function effPicker(ids, after) {   // ids : [cible, résumé, grille, vitesse]
  const [tId, sId, gId, vId] = ids, ks = zoneKinds(), pal = palColors(S.settings.palette);
  if (!ks.includes(effTarget)) effTarget = "all";
  const t = $(tId), multi = ks.length > 1;
  t.classList.toggle("hidden", !multi);
  if (multi) {
    const z = currentZone();
    t.innerHTML = [["all", "Toute la zone"]].concat(ks.map(k => [k, `${KIND_N[k]} (${z.kinds[k]})`])).map(([k, n]) => `<button data-tgt="${k}" class="${effTarget === k ? "on" : ""}">${n}</button>`).join("");
    t.querySelectorAll("[data-tgt]").forEach(b => b.onclick = () => { effTarget = b.dataset.tgt; after(); });
  }
  const sm = effSummary(); $(sId).textContent = sm; $(sId).classList.toggle("hidden", !multi || !sm);
  const cur = effCur();
  $(gId).innerHTML = EFFECTS.map(([k, n, d, ok]) => `<button class="tile ${cur.mode === k ? "on" : ""}" data-effk="${k}" ${ok ? "" : "disabled"}>${effStrip(k, pal, 10)}<span class="n">${n}</span><span class="d ${ok ? "" : "soon"}">${ok ? d : "Bientôt"}</span></button>`).join("");
  $(gId).querySelectorAll("[data-effk]").forEach(b => b.onclick = () => { effSet({ mode: b.dataset.effk }); after(); });
  const v = $(vId);
  v.innerHTML = SPEEDS.map(([x, n]) => `<button data-speed="${x}" class="${cur.speed === x ? "on" : ""}">${n}</button>`).join("");
  v.querySelectorAll("[data-speed]").forEach(b => b.onclick = () => { effSet({ speed: +b.dataset.speed }); after(); });
}
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
const TAB_OF = { sync: "sync", avances: "sync", lumieres: "lumieres", piece: "lumieres", lampe: "lumieres", creer: "lumieres", reglages: "reglages", plans: "reglages", plan: "reglages" };
let route = { v: "sync", arg: "" }, backTo = [];
function go(v, arg = "", push = true) {
  if (push && route.v !== v) backTo.push({ ...route });
  const LV = ["lumieres", "piece", "lampe", "plans"], was = route.v;
  route = { v, arg };
  if (LV.includes(v) && !LV.includes(was)) loadRooms();   // on arrive sur les lumières : état frais tout de suite
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
  if (v === "plans") renderPlans();
  if (v === "plan") renderPlan();
}

/* =================== PLANS DES PIÈCES =================== */
let PLAN = null, PED = null, planDrag = null;
$("#plansRow").onclick = () => go("plans");
function renderPlans() {
  const el = $("#plansList");
  if (!zones || !ROOMS) { el.innerHTML = `<div class="row"><span class="bd" style="padding-left:16px"><span class="t2">Chargement…</span></span></div>`; return; }
  const plans = S.settings.plans || {}, RM = ROOMS && !ROOMS.error ? ROOMS : [], ZS = zones.error ? [] : zones;
  const chev = `<svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M9 6l6 6-6 6"/></svg>`;
  const row = (id, ic, name, sub) => `<button class="row" data-plan="${esc(id)}"><span class="ic">${ic}</span><span class="bd"><span class="tx"><span class="t1">${esc(name)}</span><span class="t2">${sub}</span></span>${chev}</span></button>`;
  // pièces et zones de l'app : on y règle le plan, puis on crée leur zone de synchro sur le pont
  const zoneOf = r => ZS.find(z => z.name === ("Lueur · " + r.name).slice(0, 32));
  const sub = r => { const z = zoneOf(r); return `${r.lights.length} lampe${r.lights.length > 1 ? "s" : ""}${r.planned ? " · plan fait" : ""} · ${z ? `<span style="color:var(--green)">zone de synchro prête</span>` : "pas encore de zone de synchro"}`; };
  const rooms = RM.filter(r => r.type !== "zone"), hz = RM.filter(r => r.type === "zone");
  const grp = (t, list) => list.length ? `<div class="label">${t}</div><div class="list">${list.map(r => row("r:" + r.id, icon(roomKind(r.archetype, r.name)), r.name, sub(r))).join("")}</div>` : "";
  const own = new Set(RM.map(r => ("Lueur · " + r.name).slice(0, 32)));
  const others = ZS.filter(z => !own.has(z.name));
  el.innerHTML = (ROOMS.error ? `<p class="note">${esc(ROOMS.error)}</p>` : "")
    + grp("Pièces", rooms) + grp("Zones de l'app", hz)
    + (RM.length || ROOMS.error ? "" : `<p class="note">Aucune pièce sur le pont.</p>`)
    + (zones.error ? `<p class="note">${esc(zones.error)}</p>`
      : others.length ? `<div class="label">Autres zones de divertissement</div><div class="list">${others.map(z => row(z.id, icon("zones"), z.name, `${Object.entries(z.kinds || {}).map(([k, n]) => `${KIND_N[k] || k} ${n}`).join(" · ") || z.lights + " lampes"}${plans[z.id] ? " · plan fait" : ""}`)).join("")}</div>` : "")
    + `<p class="note">Ouvre une pièce, place tes lampes et ton ruban, puis touche « Créer la zone de synchro » : Lueur crée la zone de divertissement sur le pont et la choisit pour la musique.</p>`;
  $$("[data-plan]").forEach(b => b.onclick = () => go("plan", b.dataset.plan));
}
const PM = 0.07, PC = [[PM, PM], [1 - PM, PM], [1 - PM, 1 - PM], [PM, 1 - PM]];
function alongP(r, u, dims) {   // point du ruban à la fraction u, avec la vraie longueur des murs
  const w = Math.max(.5, +(dims && dims.w) || 1), d = Math.max(.5, +(dims && dims.d) || 1), lens = [w, d, w, d], seq = [];
  let c = ((r.corner | 0) % 4 + 4) % 4;
  for (let k = 0; k < Math.max(1, Math.min(4, r.walls | 0)); k++) { if (r.dir >= 0) { seq.push([c, 1]); c = (c + 1) % 4; } else { c = (c + 3) % 4; seq.push([c, 0]); } }
  let s = Math.max(0, Math.min(1, u)) * seq.reduce((a, [e]) => a + lens[e], 0);
  for (let k = 0; k < seq.length; k++) { const [e, fwd] = seq[k]; if (s <= lens[e] || k === seq.length - 1) { const f = Math.min(1, s / lens[e]); return perim(e + (fwd ? f : 1 - f)); } s -= lens[e]; }
}
function perim(sv) { sv = ((sv % 4) + 4) % 4; const e = Math.floor(sv) % 4, f = sv - Math.floor(sv), a = PC[e], b = PC[(e + 1) % 4]; return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f]; }
function planDevs() {   // lampes à plusieurs segments (rubans) et lampes simples
  const by = {}; PLAN.channels.forEach(c => (by[c.dev] = by[c.dev] || []).push(c));
  const rub = [], single = [];
  Object.entries(by).forEach(([d, cs]) => (cs.length > 1 ? rub : single).push([d, cs.sort((a, b) => a.idx - b.idx || a.id - b.id)]));
  return { rub, single };
}
function planLayout() {  // positions à l'écran (0-1) et ordre de parcours de chaque canal
  const { rub, single } = planDevs(), pos = {};
  rub.forEach(([d, cs]) => { const r = PED.rubans[d], n = cs.length; cs.forEach((c, i) => { const u = (i + .5) / n; pos[c.id] = { p: alongP(r, u, PED.dims), t: u, dev: d, i, n }; }); });
  single.forEach(([d, cs]) => cs.forEach(c => { const q = PED.spots[c.id]; pos[c.id] = { p: q, t: q[0], dev: d }; }));
  return pos;
}
async function renderPlan() {
  const id = route.arg;
  if (!PLAN || PLAN.key !== id) {
    $("#planTitle").textContent = "Plan"; $("#planSvg").innerHTML = ""; $("#planRubans").innerHTML = "";
    try { PLAN = await api(id.startsWith("r:") ? "/api/plan?room=" + encodeURIComponent(id.slice(2)) : "/api/plan?area=" + encodeURIComponent(id)); PLAN.key = id; } catch (e) { toast(e.message); return; }
    const pl = PLAN.plan || {}, clamp = v => Math.max(PM, Math.min(1 - PM, v));
    PED = { rubans: {}, spots: {}, eq: { ...(pl.eq || {}) }, dims: { w: 0, d: 0, ...(pl.dims || {}) } };
    COLORTEST = null;
    const { rub, single } = planDevs();
    rub.forEach(([d]) => PED.rubans[d] = { walls: PLAN.type === "room" ? 1 : 4, corner: 0, dir: 1, ...(pl.rubans || {})[d] });
    single.forEach(([, cs]) => cs.forEach(c => PED.spots[c.id] = (pl.spots || {})[c.id] || [clamp((c.x + 1) / 2), clamp((1 - c.y) / 2)]));
  }
  $("#planTitle").textContent = "Plan · " + PLAN.name;
  drawPlan();
  const { rub, single } = planDevs();
  $("#planHint").textContent = single.length ? "Fais glisser les lampes à leur place. La ligne du ruban montre son point de départ (flèche) et son sens." : "La ligne montre le départ du ruban (flèche) et son sens.";
  const seg = (k, d, opts, cur) => `<div class="seg">${opts.map(([v, n]) => `<button data-rk="${k}" data-rd="${esc(d)}" data-rv="${v}" class="${cur === v ? "on" : ""}">${n}</button>`).join("")}</div>`;
  $("#planRubans").innerHTML = dimsCard() + rub.map(([d, cs]) => { const r = PED.rubans[d]; return `<div class="rcard"><div class="h"><span class="ic" style="width:auto">${icon(lampKind(cs[0].archetype), 22)}</span><span><b>${esc(cs[0].name)}</b><br><small>${PLAN.type === "room" ? (cs[0].sync_segments ? `Synchro : ${cs[0].sync_segments} segments · scènes : ${cs[0].grad_points || 5} points de couleur` : `Dégradé à ${cs[0].grad_points || cs.length} points de couleur · pas encore de zone de synchro`) : `${cs.length} segments dans cette zone${cs[0].max_segments ? ` (max ${cs[0].max_segments})` : ""}${cs[0].grad_points ? ` · ${cs[0].grad_points} points de dégradé` : ""}`}</small></span></div>
    <div class="seg" style="margin-bottom:4px;background:var(--card2)"><button data-ident="${esc(cs[0].light || "")}">Montrer le début</button>${PLAN.type === "room" ? (cs[0].sync_segments ? `<button data-ctest class="${COLORTEST ? "on" : ""}">${COLORTEST ? "Arrêter le test" : "Couleurs par segment"}</button>` : "") : `<button data-ordre>Tester l'ordre</button>`}</div>
    ${COLORTEST ? `<p class="hint" style="margin:6px 2px 0">Chaque segment du ruban a sa couleur (comme sur le plan), et chaque spot prend la couleur du segment le plus proche <b>sur le plan</b>. Si un spot n'a pas la même couleur que le bout de ruban à côté de lui dans la pièce, déplace-le sur le plan : les lampes suivent. Le test s'arrête seul après 2 min.</p>` : ""}
    <p class="hint" style="margin:6px 2px 0">${PLAN.type === "room" ? "Le ruban s'allume du <b style=\"color:#ff5a4a\">rouge</b> (début) au <b style=\"color:#4b8dff\">bleu</b> (fin) pendant 10 s : place la flèche du plan là où tu vois le rouge." : "« Montrer le début » : rouge au début, bleu à la fin (synchro arrêtée). « Tester l'ordre » : avec la synchro en marche, un point blanc parcourt les segments dans l'ordre des effets, du rouge au bleu."}</p>
    <div class="lb">Longueur</div>${seg("walls", d, [[1, "1 mur"], [2, "2 murs"], [3, "3 murs"], [4, "Tour complet"]], r.walls)}
    <div class="lb">Départ</div>${seg("corner", d, [[0, "↖ Avant gauche"], [1, "↗ Avant droit"], [2, "↘ Fond droit"], [3, "↙ Fond gauche"]], r.corner)}
    <div class="lb">Sens</div>${seg("dir", d, [[1, "↻ Horaire"], [-1, "↺ Antihoraire"]], r.dir)}
    ${cs[0].order && cs[0].light ? `<div class="lb">Sens des effets du pont</div><div class="seg">${[["forward", "Normal"], ["reversed", "Inversé"]].map(([v, n]) => `<button data-ord="${v}" data-ol="${esc(cs[0].light)}" class="${cs[0].order === v ? "on" : ""}">${n}</button>`).join("")}</div><p class="hint" style="margin:6px 2px 0">Sens dans lequel le pont déroule ses effets intégrés et ses dégradés. Après un changement, refais « Montrer le début ».</p>` : ""}</div>`; }).join("") + (PLAN.type === "room" ? areaCard() : eqCard());
  $$("[data-ord]").forEach(b => b.onclick = async () => {
    try { await api("/api/light/order", { light: b.dataset.ol, order: b.dataset.ord }); PLAN.channels.forEach(c => { if (c.light === b.dataset.ol) c.order = b.dataset.ord; }); renderPlan(); toast("Sens changé : refais « Montrer le début »"); }
    catch (e) { toast(e.message); }
  });
  if ($("#planArea")) $("#planArea").onclick = async () => {
    const b = $("#planArea"); b.disabled = true; b.textContent = "Création sur le pont…";
    try {
      const r = await api("/api/area/from_room", { id: PLAN.id, rubans: PED.rubans, spots: PED.spots, dims: PED.dims });
      toast(`« ${r.name} » ${r.created ? "créée" : "mise à jour"} : ${r.channels} canaux${r.segments ? `, ruban en ${r.segments} segments` : ""}`);
      zones = null; roomsLock = 0; loadRooms(); await refresh(true); PLAN = null; renderPlan();
    } catch (e) { toast("Échec : " + e.message); b.disabled = false; b.textContent = "Réessayer"; }
  };
  $$("[data-eq]").forEach(el => slider(el, t => { const v = Math.round((0.1 + t * 0.9) * 100) / 100; setSl(el, t); PED.eq[el.dataset.eq] = v; el.parentElement.querySelector("[data-eqv]").textContent = Math.round(v * 100) + " %"; clearTimeout(eqTimer); eqTimer = setTimeout(sendEq, 250); }, sendEq));
  $$("[data-rk]").forEach(b => b.onclick = () => { PED.rubans[b.dataset.rd][b.dataset.rk] = +b.dataset.rv; renderPlan(); colorTestSoon(); });
  $$("[data-dim]").forEach(el => el.onchange = () => { const v = parseFloat(String(el.value).replace(",", ".")); PED.dims[el.dataset.dim] = v > 0 ? Math.min(40, v) : 0; renderPlan(); colorTestSoon(); });
  $$("[data-ctest]").forEach(b => b.onclick = () => colorTest(!!COLORTEST));
  $$("[data-ident]").forEach(b => b.onclick = async () => {
    if (!b.dataset.ident) return toast("Lampe introuvable sur le pont.");
    try { await api("/api/plan/identify", { light: b.dataset.ident }); toast("Regarde le ruban : rouge = début, bleu = fin (10 s)"); } catch (e) { toast(e.message); }
  });
  $$("[data-ordre]").forEach(b => b.onclick = async () => {
    try {
      await savePlanQuiet();
      const r = await api("/api/plan/test", { id: PLAN.id });
      if (!r.running) return toast("Démarre la synchro pour tester l'ordre.");
      if (!r.area_selected) return toast("Choisis cette zone dans l'écran Synchro pour la tester.");
      toast("Un point blanc parcourt les segments pendant 15 s");
    } catch (e) { toast(e.message); }
  });
}
function areaCard() {    // zone de divertissement de la pièce, créée d'après ce plan
  const name = ("Lueur · " + PLAN.name).slice(0, 32), z = zones && !zones.error ? zones.find(x => x.name === name) : null;
  return `<div class="rcard"><div class="h"><span class="ic" style="width:auto">${icon("zones", 22)}</span><span><b>Zone de synchro</b><br><small>${z ? `« ${esc(name)} » · ${z.lights} canaux` : "Pas encore créée"}</small></span></div>
    <button class="cta" id="planArea" style="margin-top:4px">${z ? "Mettre à jour la zone de synchro" : "Créer la zone de synchro"}</button>
    <p class="hint" style="margin:8px 2px 0">${z ? "Remet" : "Crée"} sur le pont la zone de divertissement « ${esc(name)} » avec les lampes de la pièce placées comme sur ce plan, recopie le plan pour la synchro et la choisit pour la musique. Le nombre de segments du ruban reste celui réglé dans l'app Hue.</p></div>`;
}
let COLORTEST = null, ctTimer = null, ctEnd = null;
function dimsCard() {   // dimensions de la pièce : le plan prend la bonne forme et le ruban suit la vraie longueur des murs
  const v = k => PED.dims[k] ? String(PED.dims[k]).replace(".", ",") : "";
  return `<div class="rcard"><div class="h"><span class="ic" style="width:auto">${icon("zones", 22)}</span><span><b>Dimensions de la pièce</b><br><small>${PED.dims.w && PED.dims.d ? "Le plan suit ces proportions" : "Non renseignées : pièce carrée"}</small></span></div>
    <div style="display:flex;gap:10px"><label class="field" style="flex:1;min-width:0;margin:0;padding:0 10px;gap:6px;background:var(--card2)"><span style="font-size:13px">Largeur</span><input data-dim="w" size="4" style="width:100%;min-width:3.4ch;font-size:16px" inputmode="decimal" placeholder="m" value="${v("w")}"><span>m</span></label><label class="field" style="flex:1;min-width:0;margin:0;padding:0 10px;gap:6px;background:var(--card2)"><span style="font-size:13px">Profondeur</span><input data-dim="d" size="4" style="width:100%;min-width:3.4ch;font-size:16px" inputmode="decimal" placeholder="m" value="${v("d")}"><span>m</span></label></div>
    <p class="hint" style="margin:8px 2px 0">En mètres. Largeur = le mur de l'écran (en haut du plan), profondeur = de ce mur au mur d'en face. Les segments du ruban sont répartis selon la vraie longueur de chaque mur.</p></div>`;
}
async function colorTest(stop) {   // test « couleurs par segment » (plan d'une pièce)
  clearTimeout(ctTimer);
  if (stop) { COLORTEST = null; clearTimeout(ctEnd); try { await api("/api/plan/colortest", { id: PLAN.id, stop: true }); } catch (e) {} if (route.v === "plan") renderPlan(); return; }
  try {
    const r = await api("/api/plan/colortest", { id: PLAN.id, rubans: PED.rubans, spots: PED.spots, dims: PED.dims });
    const first = !COLORTEST; COLORTEST = { segments: r.segments || [], spots: r.spots || {} };
    if (first) toast(r.started ? "Synchro démarrée : chaque segment s'allume de sa couleur" : "Chaque segment s'allume de sa couleur (2 min)");
    clearTimeout(ctEnd); ctEnd = setTimeout(() => { COLORTEST = null; if (route.v === "plan") renderPlan(); }, (r.seconds || 120) * 1000);
    renderPlan();
  } catch (e) { toast(e.message); COLORTEST = null; renderPlan(); }
}
function colorTestSoon() { if (COLORTEST && PLAN && PLAN.type === "room") { clearTimeout(ctTimer); ctTimer = setTimeout(() => colorTest(false), 300); } }
let eqTimer = null;
function eqCard() {      // équilibre de luminosité de chaque lampe de la zone de synchro
  const by = {}; PLAN.channels.forEach(c => { if (!by[c.dev]) by[c.dev] = c; });
  const devs = Object.entries(by);
  if (devs.length < 2) return "";
  return `<div class="rcard"><div class="h"><span class="ic" style="width:auto">${icon("sliders", 22)}</span><span><b>Équilibre de luminosité</b><br><small>Pendant la synchro</small></span></div>
    ${devs.map(([d, c]) => { const v = PED.eq[d] ?? 1; return `<div class="srow"><div class="h"><span>${esc(c.name)}</span><span data-eqv>${Math.round(v * 100)} %</span></div><div class="sl" data-eq="${esc(d)}"><div class="tr"></div><div class="fi" style="width:${(v - .1) / .9 * 100}%"></div><div class="kn" style="left:${(v - .1) / .9 * 100}%"></div></div></div>`; }).join("")}
    <p class="hint" style="margin:8px 2px 0">Baisse une lampe qui éblouit par rapport aux autres. Se règle en direct, pendant que la musique joue.</p></div>`;
}
async function sendEq() {
  clearTimeout(eqTimer);
  try { await api("/api/plan/eq", { id: PLAN.id, eq: PED.eq }); const p = { ...(S.settings.plans || {}) }; p[PLAN.id] = { ...(p[PLAN.id] || {}), eq: { ...PED.eq } }; S.settings.plans = p; } catch (e) { toast(e.message); }
}
// Carte des couleurs du test : chaque point de la pièce prend la couleur du point du ruban le plus
// proche (mélange des deux segments voisins), comme le moteur le fait pour un spot placé là.
let FIELD = { key: "", url: "" };
function stripPolyline(pts) {       // paires de segments voisins (+ fermeture si le ruban fait le tour)
  const pairs = []; for (let i = 0; i < pts.length - 1; i++) pairs.push([i, i + 1]);
  if (pts.length > 2) {
    const steps = pairs.map(([a, b]) => Math.hypot(pts[b][0] - pts[a][0], pts[b][1] - pts[a][1])).sort((a, b) => a - b);
    if (Math.hypot(pts[0][0] - pts.at(-1)[0], pts[0][1] - pts.at(-1)[1]) <= 1.6 * steps[Math.floor(steps.length / 2)]) pairs.push([pts.length - 1, 0]);
  }
  return pairs;
}
function fieldColor(pts, cols, pairs, x, y) {
  if (pts.length === 1) return hexRgb(cols[0]);
  let best = null;
  for (const [a, b] of pairs) {
    const dx = pts[b][0] - pts[a][0], dy = pts[b][1] - pts[a][1], L = dx * dx + dy * dy;
    const f = L < 1e-9 ? 0 : Math.max(0, Math.min(1, ((x - pts[a][0]) * dx + (y - pts[a][1]) * dy) / L));
    const d = (pts[a][0] + dx * f - x) ** 2 + (pts[a][1] + dy * f - y) ** 2;
    if (!best || d < best[0]) best = [d, a, b, f];
  }
  const ca = hexRgb(cols[best[1]]), cb = hexRgb(cols[best[2]]);
  return ca.map((v, i) => v + (cb[i] - v) * best[3]);
}
function colorField(pts, cols, W, H) {   // image de fond (calculée une fois par réglage du ruban)
  const key = JSON.stringify([pts.map(p => p.map(v => v.toFixed(2))), cols, W, H.toFixed(1)]);
  if (FIELD.key === key) return FIELD.url;
  const pairs = stripPolyline(pts), cw = 160, ch = Math.max(40, Math.round(160 * H / W)), cv = document.createElement("canvas");
  cv.width = cw; cv.height = ch; const ctx = cv.getContext("2d"), img = ctx.createImageData(cw, ch);
  for (let j = 0; j < ch; j++) for (let i = 0; i < cw; i++) {
    const c = fieldColor(pts, cols, pairs, (i + .5) / cw * W, (j + .5) / ch * H), k = (j * cw + i) * 4;
    img.data[k] = c[0]; img.data[k + 1] = c[1]; img.data[k + 2] = c[2]; img.data[k + 3] = 255;
  }
  ctx.putImageData(img, 0, 0);
  FIELD = { key, url: cv.toDataURL() };
  return FIELD.url;
}
function drawPlan() {
  // proportions de la pièce : largeur (mur de l'écran) × profondeur, carré si non renseignées
  const dw = +PED.dims.w || 0, dd = +PED.dims.d || 0, W = 100, H = dw && dd ? Math.max(35, Math.min(150, 100 * dd / dw)) : 75;
  const pos = planLayout(), pal = palColors(S.settings.palette), X = p => p[0] * W, Y = p => p[1] * H;
  let h = `<rect x="${PM * W}" y="${PM * H}" width="${(1 - 2 * PM) * W}" height="${(1 - 2 * PM) * H}" rx="2" fill="none" stroke="#3a3b40" stroke-width=".5" stroke-dasharray="1.5 1.5"/>`;
  h += `<rect x="38" y="1.2" width="24" height="1.6" rx=".8" fill="#4a4b52"/>`;
  const { rub, single } = planDevs(), CT = COLORTEST;
  // Pendant le test : fond = couleur que prendrait un spot à chaque endroit de la pièce
  let fieldAt = null;
  if (CT && rub.length && CT.segments.length) {
    const [, cs] = rub[0], spts = cs.map(c => [X(pos[c.id].p), Y(pos[c.id].p)]), cols = cs.map((c, i) => CT.segments[i] || "#ffffff");
    const pairs = stripPolyline(spts);
    fieldAt = (x, y) => rgbHex(fieldColor(spts, cols, pairs, x, y));
    const rx = PM * W, ry = PM * H, rw = (1 - 2 * PM) * W, rh = (1 - 2 * PM) * H;
    h = `<defs><clipPath id="roomclip"><rect x="${rx}" y="${ry}" width="${rw}" height="${rh.toFixed(1)}" rx="2"/></clipPath><radialGradient id="vign"><stop offset=".6" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".3"/></radialGradient></defs>`
      + `<g clip-path="url(#roomclip)"><image href="${colorField(spts, cols, W, H)}" x="0" y="0" width="${W}" height="${H.toFixed(1)}" preserveAspectRatio="none" opacity=".72"/><rect x="${rx}" y="${ry}" width="${rw}" height="${rh.toFixed(1)}" fill="url(#vign)"/></g>` + h;
  }
  rub.forEach(([d, cs]) => {
    const r = PED.rubans[d], pts = []; for (let k = 0; k <= 60; k++) pts.push(alongP(r, k / 60, PED.dims));
    h += `<polyline points="${pts.map(p => X(p).toFixed(1) + "," + Y(p).toFixed(1)).join(" ")}" fill="none" stroke="#2a2b30" stroke-width="3.2" stroke-linecap="round"/>`;
    cs.forEach((c, i) => { const q = pos[c.id], tc = CT && CT.segments[i], col = tc || (i === 0 ? "#ff5a4a" : i === cs.length - 1 ? "#4b8dff" : "#d9dade"); const nx = X(q.p), ny = Y(q.p), cx = 50 - nx, cy = H / 2 - ny, k = 4.2 / (Math.hypot(cx, cy) || 1);
      h += `<circle cx="${nx}" cy="${ny}" r="${tc ? 2.6 : 1.9}" fill="${col}"${tc ? ` stroke="#fff" stroke-width=".4"` : ""}/><text x="${nx + cx * k}" y="${ny + cy * k + 1}" text-anchor="middle" font-size="2.8" font-weight="700" fill="${col}">${i + 1}</text>`; });
    const a = alongP(r, .02, PED.dims), b = alongP(r, .12, PED.dims), ang = Math.atan2(Y(b) - Y(a), X(b) - X(a)) * 180 / Math.PI, s0 = alongP(r, 0, PED.dims);
    h += `<g transform="translate(${X(s0)},${Y(s0)}) rotate(${ang})"><circle r="3.2" fill="#fff"/><path d="M-1.4 -1.6 L1.6 0 L-1.4 1.6Z" fill="#1b1c20"/></g>`;
  });
  single.forEach(([, cs]) => cs.forEach(c => { const q = pos[c.id].p, tc = CT && (fieldAt ? fieldAt(X(q), Y(q)) : CT.spots[c.light || c.id]), col = tc || boost(pal[Math.min(pal.length - 1, Math.floor(q[0] * pal.length))], 190);
    h += `<g class="spot" data-spot="${c.id}" transform="translate(${X(q)},${Y(q)})"><circle r="6" fill="transparent"/><circle r="3.6" fill="${col}" stroke="#fff" stroke-width=".7"/><text y="8.6" text-anchor="middle" font-size="3.4" fill="#a9aab0">${esc(c.name.slice(0, 14))}</text></g>`; }));
  const svg = $("#planSvg"); svg.setAttribute("viewBox", `0 0 ${W} ${H.toFixed(1)}`); svg.innerHTML = h;
  svg.querySelectorAll("[data-spot]").forEach(g => g.onpointerdown = e => { e.preventDefault(); planDrag = g.dataset.spot; svg.setPointerCapture(e.pointerId); });
  svg.onpointermove = e => { if (planDrag === null) return; const r = svg.getBoundingClientRect(); PED.spots[planDrag] = [Math.max(PM, Math.min(1 - PM, (e.clientX - r.left) / r.width)), Math.max(PM, Math.min(1 - PM, (e.clientY - r.top) / r.height))]; drawPlan(); };
  svg.onpointerup = svg.onpointercancel = () => { if (planDrag !== null) colorTestSoon(); planDrag = null; };
}
async function savePlanQuiet() {   // enregistre le plan de la zone de synchro (pour tester l'ordre)
  const pos = planLayout(), ch = {};
  PLAN.channels.forEach(c => { const q = pos[c.id]; if (q) ch[c.id] = { t: q.t, x: q.p[0] * 2 - 1, y: 1 - q.p[1] * 2 }; });
  await api("/api/plan", { id: PLAN.id, ch, rubans: PED.rubans, spots: PED.spots, dims: PED.dims });
  S.settings.plans = { ...(S.settings.plans || {}), [PLAN.id]: { ch, eq: { ...PED.eq } } };
}
$("#planSave").onclick = async () => {
  const pos = planLayout(), ch = {};
  PLAN.channels.forEach(c => { const q = pos[c.id]; if (q) ch[c.id] = { t: q.t, x: q.p[0] * 2 - 1, y: 1 - q.p[1] * 2 }; });
  try {
    if (PLAN.type === "room") { if (COLORTEST) colorTest(true); await api("/api/plan", { type: "room", id: PLAN.id, rubans: PED.rubans, spots: PED.spots, dims: PED.dims }); roomsLock = 0; loadRooms(); }
    else { await api("/api/plan", { id: PLAN.id, ch, rubans: PED.rubans, spots: PED.spots, dims: PED.dims }); S.settings.plans = { ...(S.settings.plans || {}), [PLAN.id]: { ch, eq: { ...PED.eq } } }; }
    toast("Plan enregistré"); PLAN = null; back();
  }
  catch (e) { toast("Échec : " + e.message); }
};
$("#planReset").onclick = async () => {
  try { const room = PLAN.type === "room"; await api("/api/plan", { id: PLAN.id, reset: true, type: room ? "room" : undefined }); if (room) { roomsLock = 0; await loadRooms(); } else { const p = { ...(S.settings.plans || {}) }; delete p[PLAN.id]; S.settings.plans = p; } PLAN = null; toast("Positions de l'app Hue reprises"); renderPlan(); }
  catch (e) { toast("Échec : " + e.message); }
};

/* =================== FEUILLES =================== */
function openSheet(id) { closeSheets(); $("#sheetBg").classList.add("open"); const el = $("#" + id); el.classList.add("open"); el.scrollTop = 0; document.body.classList.add("locked"); renderSheets(); }
function closeSheets() { $("#sheetBg").classList.remove("open"); $$(".sheet").forEach(s => { s.classList.remove("open"); s.style.transform = ""; }); document.body.classList.remove("locked"); }
document.addEventListener("keydown", e => { if (e.key === "Escape") closeSheets(); });
$$(".sheet").forEach(sh => {   // tirer la feuille vers le bas (depuis son en-tête) pour la fermer
  let y0 = null, dy = 0;
  sh.addEventListener("touchstart", e => { const t = e.target; y0 = (sh.scrollTop <= 0 && (t.closest(".sh") || t.closest(".grab"))) ? e.touches[0].clientY : null; dy = 0; }, { passive: true });
  sh.addEventListener("touchmove", e => { if (y0 === null) return; dy = Math.max(0, e.touches[0].clientY - y0); sh.style.transition = "none"; sh.style.transform = `translateY(${dy}px)`; }, { passive: true });
  sh.addEventListener("touchend", () => { if (y0 === null) return; sh.style.transition = ""; if (dy > 90) closeSheets(); else sh.style.transform = ""; y0 = null; });
});
$("#sheetBg").onclick = closeSheets;
$$("[data-close]").forEach(b => b.onclick = closeSheets);
$$("[data-sheet]").forEach(b => b.onclick = () => openSheet(b.dataset.sheet));
function renderSheets() {
  if (!S) return;
  const st = S.settings;
  effPicker(["#effTarget", "#effLayers", "#effList", "#effSpeed"], () => { renderSheets(); renderSync(); });
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
function effAnim(fx, i, n, sp) {
  const rnd = [0, .62, .21, .9, .4, .75, .12, .55, .33, .82, .05, .68], k = 1 / (sp || 1), f = v => (v * k).toFixed(2);
  if (fx === "spectrum") return `bar ${(.45 + rnd[i % 12] * .5).toFixed(2)}s ${(-rnd[(i + 3) % 12]).toFixed(2)}s ease-in-out infinite alternate`;
  if (fx === "comete") return `fl ${f(1.6)}s ${f(i * 1.6 / n)}s infinite`;
  if (fx === "glisse") return `br ${f(1.6)}s ease-in-out ${f(-i * .16)}s infinite`;
  if (fx === "vague") return `br ${f(2.4)}s ease-in-out ${f(-i * .22)}s infinite`;
  if (fx === "vumetre") return `fl ${f(1.6)}s ${f(i * .06)}s infinite`;
  if (fx === "stereo") return `fl ${f(.9)}s ${i < n / 2 ? 0 : f(.45)}s infinite`;
  if (fx === "etincelles") return `fl ${f(1.3)}s ${f(rnd[i % 12] * 1.3)}s infinite`;
  if (fx === "respiration") return `br ${f(3.2)}s ease-in-out ${f(-i * .12)}s infinite`;
  return `fl ${f(.6)}s infinite`;
}
function effStrip(fx, pal, n) {
  const rnd = [0, .62, .21, .9, .4, .75, .12, .55, .33, .82, .05, .68];
  let h = `<span style="display:flex;gap:3px;height:16px;width:100%">`;
  for (let i = 0; i < n; i++) {
    const c = boost(pal[Math.floor(i / n * pal.length) % pal.length], 180);
    const a = effAnim(fx, i, n, 1);
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
  const lk = Object.keys(st.layers || {}).filter(k => zoneKinds().includes(k));
  $("#cEffet").textContent = lk.length ? [...new Set([st.mode, ...lk.map(k => st.layers[k].mode)])].map(effName).join(" + ") : effName(st.mode) + spTag(st.speed);
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
  renderLeds();
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
function renderLeds() {
  const el = $("#leds"); if (!el) return;
  const syncing = live.state === "syncing", cols = syncing && live.colors ? live.colors : [];
  el.classList.toggle("off", !syncing);
  const n = Math.min(cols.length || 8, 24);
  if (el.children.length !== n) el.innerHTML = "<i></i>".repeat(n);
  [...el.children].forEach((d, i) => { const c = cols[i]; if (!c) { d.style.background = ""; d.style.boxShadow = ""; return; } const l = Math.max(...hexRgb(c)) / 255, b = boost(c, 255); d.style.background = l < .03 ? "#1e1f23" : `color-mix(in srgb, ${b} ${Math.round(25 + l * 75)}%, #1e1f23)`; d.style.boxShadow = l > .35 ? `0 0 ${4 + l * 10}px ${b}` : "none"; });
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
  if (!zones.length) { g.innerHTML = `<div class="note" style="padding:16px">Aucune zone de synchro pour l'instant. Touche « Créer la zone d'une pièce… » ci-dessous.</div>`; return; }
  const cz = currentZone();
  g.innerHTML = zones.map(z => `<button class="row" data-zone="${z.id}" style="min-height:60px"><span style="width:44px;text-align:center;color:var(--blue);font-weight:700">${cz && cz.id === z.id ? "✓" : ""}</span><span class="bd"><span class="tx"><span class="t1" style="font-size:17px">${esc(z.name)}</span><span class="t2" style="font-size:13px">${z.lights} lampe${z.lights > 1 ? "s" : ""}</span></span></span></button>`).join("");
  $$("[data-zone]").forEach(b => b.onclick = () => { save({ area: b.dataset.zone }, true); renderZoneMenu(); renderSync(); });
}
$("#zoneFromRoom").onclick = () => { closeSheets(); backTo = []; go("plans"); toast("Choisis la pièce, puis « Créer la zone de synchro »"); };
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
  effPicker(["#advTarget", "#advLayers", "#advEffects", "#advSpeed"], renderAdv);
  $("#speedHint").textContent = SPEED_D[effCur().mode] || "";
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
function livePrev() {   // pendant la synchro, l'aperçu montre les vraies couleurs envoyées
  const el = $("#prev"); if (!el) return;
  const syncing = live.state === "syncing" && live.colors && live.colors.length;
  el.classList.toggle("live", !!syncing);
  if (!syncing) { if (el.dataset.live) { delete el.dataset.live; renderPrev(); } return; }
  const cols = live.colors.slice(0, 16);
  if (el.dataset.live !== String(cols.length)) { el.dataset.live = cols.length; el.innerHTML = cols.map(() => "<i></i>").join(""); }
  [...el.children].forEach((d, i) => { const c = cols[i], l = Math.max(...hexRgb(c)) / 255, b = boost(c, 255); d.style.animation = "none"; d.style.opacity = .15 + .85 * l; d.style.transform = `scale(${.85 + .3 * l})`; d.style.background = `radial-gradient(circle at 35% 30%,#fff 0%,${b} 38%,${b} 100%)`; d.style.boxShadow = `0 0 ${6 + 18 * l}px ${b}`; });
  $("#prevSub").textContent = "En direct · ce que reçoivent tes lampes";
}
function renderPrev() {
  if ($("#prev") && $("#prev").dataset.live) return;
  const pal = palColors(S.settings.palette), cur = effCur(), mode = cur.mode, n = 8;
  const sp = cur.speed || 1, tau = fxv("tau"), anim = tau < .14 ? "f1" : tau < .32 ? "f2" : "f3", per = .5 / sp;
  const dl = { all: [0, 0, 0, 0, 0, 0, 0, 0], alt: [0, .5, 0, .5, 0, .5, 0, .5], chase: [0, .55, .25, .8, .4, .95, .15, .65], wave: [0, .12, .24, .36, .48, .6, .72, .84] }[fxv("pattern")] || [];
  const hi = Math.max(fxv("beat"), fxv("base") + .1), lo = Math.max(fxv("base"), .03);
  $("#prev").innerHTML = Array.from({ length: n }, (_, i) => {
    const c = boost(pal[(i + 1) % pal.length], 200);
    const a = mode === "spectrum" ? `bar ${(.4 + i * .06).toFixed(2)}s ease-in-out infinite alternate` : mode === "pulse" ? `${anim} ${per}s ${(dl[i] || 0) * per}s infinite` : effAnim(mode, i, n, sp);
    return `<i style="background:radial-gradient(circle at 35% 30%,#fff 0%,${c} 38%,${c} 100%);box-shadow:0 0 20px ${c};--hi:${hi};--lo:${lo};animation:${a}"></i>`;
  }).join("");
  $("#stage").style.setProperty("--glow", boost(pal[1] || pal[0], 160) + "33");
  $("#prevSub").textContent = (EFFECTS.find(e => e[0] === mode) || EFFECTS[0])[1] + " · " + INT[S.settings.intensity] + (sp !== 1 ? (sp > 1 ? " · ×2" : " · ×½") : "");
}
$("#advReset").onclick = () => { S.settings.fx = {}; delete pending.fx; save({ intensity: S.settings.intensity }, true); renderAdv(); toast("Préréglage rétabli"); };

/* =================== LUMIÈRES =================== */
let roomsTimer = null, roomsLock = 0, roomsSeq = 0;
let held = false;   // doigt posé (curseur, roue des couleurs…) : on ne redessine pas sous le doigt
document.addEventListener("pointerdown", () => held = true, true);
["pointerup", "pointercancel"].forEach(t => document.addEventListener(t, () => { held = false; }, true));
async function loadRooms() {
  clearTimeout(roomsTimer);
  if (Date.now() > roomsLock) {
    // une réponse partie avant un geste (ou doublée par une lecture plus récente) est ignorée :
    // sinon elle remettrait à l'écran les anciennes couleurs
    const my = ++roomsSeq, lk = roomsLock;
    let r; try { r = await api("/api/rooms"); } catch (e) { r = { error: e.message }; }
    if (my === roomsSeq && lk === roomsLock && Date.now() > roomsLock && !held) {
      ROOMS = r;
      if (["lumieres", "piece", "lampe", "plans"].includes(route.v)) render();
    }
  }
  const near = ["lumieres", "piece", "lampe", "plans"].includes(route.v) && !document.hidden;
  roomsTimer = setTimeout(loadRooms, Date.now() < roomsLock ? Math.max(200, roomsLock - Date.now() + 50) : near ? 1500 : 10000);
}
const roomColors = r => { const on = r.lights.filter(l => l.on); return (on.length ? on : r.lights).map(l => l.color); };
function renderRooms() {
  const g = $("#rooms");
  if (!ROOMS) return;
  if (ROOMS.error) { g.innerHTML = `<p class="note" style="padding:0 8px">${esc(ROOMS.error)}</p>`; return; }
  g.innerHTML = ROOMS.map((r, i) => {
    const rb = roomBg(r), c1 = boost(rb.colors[rb.colors.length - 1], 190);
    const dark = rb.colors.reduce((a, c) => a + lum(boost(c, 190)), 0) / rb.colors.length > .5, fg = r.on ? (dark ? "#1b1c20" : "#fff") : "#fff";
    const head = r.type === "zone" && (i === 0 || ROOMS[i - 1].type !== "zone") ? `<div class="label" style="padding-left:6px">Zones</div>` : "";
    return head + `<div class="room" style="background:${r.on ? rb.css : "var(--card)"};color:${fg};box-shadow:${r.on ? `0 8px 28px ${c1}38` : "none"}">
      <div class="r1"><button class="rn" data-room="${r.id}" style="display:flex;align-items:center;gap:14px"><span class="ri" style="background:${r.on ? "rgba(255,255,255,.35)" : "var(--card2)"}">${icon(roomKind(r.archetype, r.name), 26)}</span>${esc(r.name)}</button>
      <button class="pwbtn" data-rpow="${r.id}" aria-label="${r.on ? "Éteindre" : "Allumer"} ${esc(r.name)}" style="background:${r.on ? "rgba(255,255,255,.75)" : "var(--card2)"};color:${r.on ? "#1b1c20" : "#8d8e94"}">${icon("power", 20, "currentColor", 2.4)}</button></div>
      ${r.on ? `<div class="sl" data-rbri="${r.id}"><div class="tr" style="background:rgba(0,0,0,.15)"></div><div class="fi" style="width:${r.bri}%;background:rgba(0,0,0,.3)"></div><div class="kn" style="left:${r.bri}%"></div></div>` : ""}</div>`;
  }).join("") || `<p class="note" style="padding:0 8px">Aucune pièce sur le pont.</p>`;
  bindRoomControls();
}
function bindRoomControls() {
  $$("[data-room]").forEach(b => b.onclick = () => go("piece", b.dataset.room));
  $$("[data-rpow]").forEach(b => b.onclick = () => roomPower(b.dataset.rpow));
  $$("[data-rbri]").forEach(el => { const r = ROOMS.find(x => x.id === el.dataset.rbri); slider(el, t => { setSl(el, t); r.bri = Math.max(1, Math.round(t * 100)); }, () => { roomsLock = Date.now() + 1200; api("/api/room", { group: r.group, bri: r.bri }).catch(e => toast(e.message)); }); });
}
async function roomPower(id) {
  const r = ROOMS.find(x => x.id === id); if (!r) return;
  r.on = !r.on; r.lights.forEach(l => l.on = r.on); roomsLock = Date.now() + 1200; render();
  try { await api("/api/room", { group: r.group, on: r.on }); } catch (e) { toast(e.message); }
}

/* ----- une pièce ----- */
let spread = load("spread") || "lr", scenePick = {};
let ANIM = {}; try { ANIM = JSON.parse(load("anim") || "{}"); } catch (e) {}
const ANIMS = [[0, "Fixe"], [0.25, "Lente"], [0.5, "Moyenne"], [0.85, "Rapide"]];
// Rendu d'un dégradé sur un ruban (gradient.mode du pont)
const GMODES = [["interpolated_palette", "Fondu"], ["segmented_palette", "Blocs"], ["interpolated_palette_mirrored", "Miroir"], ["random_pixelated", "Mélange"]];
const GMODE_D = { interpolated_palette: "Les couleurs se fondent les unes dans les autres le long du ruban.", segmented_palette: "Des blocs de couleur nets, côte à côte.",
  interpolated_palette_mirrored: "Le dégradé part du milieu et se reflète vers les deux bouts.", random_pixelated: "Les couleurs de la scène dispersées en petits points." };
let GMODE = {}; try { GMODE = JSON.parse(load("gmode") || "{}"); } catch (e) {}
const gmodeOf = r => GMODE[r.id] || "interpolated_palette";
// Effets intégrés au pont (effects_v2) : nom et description maison
const FX_N = { candle: ["Bougie", "Flamme douce qui vacille"], fire: ["Âtre", "Feu de cheminée, plus vif"], sparkle: ["Pétillement", "Petits éclats au hasard"],
  glisten: ["Miroitement", "Reflets qui brillent par instants"], prism: ["Prisme", "Les teintes tournent lentement"], opal: ["Opale", "Reflets nacrés qui ondulent"],
  underwater: ["Sous l'eau", "Lumière mouvante, comme au fond d'une piscine"], cosmos: ["Cosmos", "Lueurs lointaines qui dérivent"], sunbeam: ["Rayon", "Un rayon de soleil qui passe"],
  enchant: ["Féerie", "Lueurs qui dansent doucement"] };
const FX_P = { candle: IC.candle, fire: "M12 3c3 4 5 6.5 5 10a5 5 0 0 1-10 0c0-2 1-3.5 2-4.5 0 2 1 3 2 3-1-3 0-6 1-8.5z", sparkle: "M12 3v4M12 17v4M3 12h4M17 12h4M6.5 6.5l2 2M15.5 15.5l2 2M6.5 17.5l2-2M15.5 8.5l2-2",
  glisten: "M12 3c.6 4.4 2.6 6.4 7 7-4.4.6-6.4 2.6-7 7-.6-4.4-2.6-6.4-7-7 4.4-.6 6.4-2.6 7-7zM19 16v4M17 18h4", prism: "M12 4l8 15H4zM12 4v15M4 19l8-6 8 6",
  opal: "M12 3.5a8.5 8.5 0 1 1 0 17 8.5 8.5 0 0 1 0-17zM5 13c2.5-2 4.5 2 7 0s4.5 2 7 0", underwater: "M3 9c2-2 4 2 6 0s4 2 6 0 4 2 6 0M3 14c2-2 4 2 6 0s4 2 6 0 4 2 6 0M7 19h10",
  cosmos: "M12 8a4 4 0 1 1 0 8 4 4 0 0 1 0-8zM3.5 15c-1-2 3.5-5 8.5-6.5s9-1.5 8.5.5-3.5 5-8.5 6.5-9 1.5-8.5-.5z", sunbeam: "M12 8a4 4 0 1 1 0 8 4 4 0 0 1 0-8zM12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M5 19l2-2M17 7l2-2",
  enchant: "M4 20L15 9M14 4v3M17.5 5.5l-2 2M20 9h-3M17.5 12.5l-2-2" };
const fxIcon = k => `<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${FX_P[k] || IC.sliders}"/></svg>`;
async function applyEffect(r, k) {
  const sp = ANIM[r.id] || 0.5;
  roomsLock = Date.now() + 2000 + 120 * r.lights.length;
  try {
    const res = await api("/api/room/effect", { id: r.id, effect: k, speed: sp });
    r.lights.forEach(l => { if (k === "no_effect") l.effect = "no_effect"; else if ((res.lights || {})[l.id]) { l.effect = k; l.on = true; } });
    if (k !== "no_effect") { r.on = true; scenePick[r.id] = null; }
    toast(k === "no_effect" ? "Effet arrêté" : `${FX_N[k][0]} : ${res.count} lampe${res.count > 1 ? "s" : ""}`);
    roomsLock = Date.now() + 1500 + 110 * (res.count || 0); render();
  } catch (e) { toast(e.message); }
}
function gradAt(gr, u) {   // couleur le long d'un dégradé (fondu entre ses points, comme le ruban)
  if (gr.length < 2) return gr[0];
  const x = Math.max(0, Math.min(1, u)) * (gr.length - 1), k = Math.min(Math.floor(x), gr.length - 2), f = x - k;
  const a = hexRgb(gr[k]), b = hexRgb(gr[k + 1]);
  return rgbHex(a.map((v, i) => v + (b[i] - v) * f));
}
function roomBg(r, angle = 135) {   // dégradé d'une pièce : les couleurs réellement allumées, de gauche à droite
  const on = r.lights.filter(l => l.on), src = on.length ? on : r.lights, items = [];
  src.forEach((l, i) => {
    const x = l.pos ? l.pos.x : -1 + 2 * i / Math.max(1, src.length - 1);
    if (l.gradient && l.gradient.length > 1) l.gradient.forEach((c, k) => items.push([l.path && l.path[k] ? l.path[k].x : x - .5 + k / (l.gradient.length - 1), c]));
    else items.push([x, l.color]);
  });
  const by = {}; items.forEach(([x, c]) => { (by[c] = by[c] || { n: 0, x: 0 }); by[c].n++; by[c].x += x; });
  let cs = Object.entries(by).sort((a, b) => b[1].n - a[1].n).slice(0, 3).sort((a, b) => a[1].x / a[1].n - b[1].x / b[1].n).map(e => e[0]);
  if (cs.length === 1) cs = [lighten(cs[0], .25), cs[0]];
  return { css: `linear-gradient(${angle}deg, ${cs.map(c => boost(c, 190)).join(", ")})`, colors: cs };
}
function planSvg(r) {
  const ls = r.lights, pos = ls.map((l, i) => l.pos ? [179 + l.pos.x * 140, 100 - l.pos.y * 64] : [60 + (ls.length > 1 ? i / (ls.length - 1) : .5) * 238, 100]);
  const shapes = ls.map((l, i) => {
    const [x, y] = pos[i], k = lampKind(l.archetype), c = l.on ? boost(l.color, 200) : "#3a3a3c", glow = l.on ? `filter:drop-shadow(0 0 8px ${c})` : "";
    if ((l.line || l.path) && (l.line || l.path).length > 1) {   // ruban placé sur le plan : on suit son tracé
      const gr = (l.gradient && l.gradient.length ? l.gradient : [l.color]).map(x => l.on ? x : "#3a3a3c");
      const P = (l.line || l.path).map(q => [179 + q.x * 140, 100 - q.y * 64]), col = j => gradAt(gr, j / (P.length - 1));
      const segs = P.slice(1).map((q, j) => { const dx = q[0] - P[j][0], dy = q[1] - P[j][1], d = Math.hypot(dx, dy) || 1, e = .6 / d;   // léger chevauchement : pas de jointure visible
        return `<linearGradient id="g${i}_${j}" gradientUnits="userSpaceOnUse" x1="${P[j][0]}" y1="${P[j][1]}" x2="${q[0]}" y2="${q[1]}"><stop offset="0" stop-color="${col(j)}"/><stop offset="1" stop-color="${col(j + 1)}"/></linearGradient>|<line x1="${P[j][0] - dx * e}" y1="${P[j][1] - dy * e}" x2="${q[0] + dx * e}" y2="${q[1] + dy * e}" stroke="url(#g${i}_${j})" stroke-width="7" stroke-linecap="butt"/>`; });
      return `<defs>${segs.map(x => x.split("|")[0]).join("")}</defs><g style="${l.on ? `filter:drop-shadow(0 0 6px ${gr[0]}aa)` : ""}">${segs.map(x => x.split("|")[1]).join("")}</g>`;
    }
    if (k === "strip") { const gr = (l.gradient && l.gradient.length ? l.gradient : [l.color]).map(x => l.on ? boost(x, 200) : "#3a3a3c"); return `<defs><linearGradient id="g${i}">${gr.map((x, j) => `<stop offset="${gr.length > 1 ? j / (gr.length - 1) : 0}" stop-color="${x}"/>`).join("")}</linearGradient></defs><rect x="${x - 50}" y="${y - 4}" width="100" height="8" rx="4" fill="url(#g${i})" style="${glow}"/>`; }
    if (k === "bar") return `<rect x="${x - 26}" y="${y - 6}" width="52" height="12" rx="6" fill="${c}" style="${glow}"/>`;
    return `<circle cx="${x}" cy="${y}" r="${k === "bloom" ? 13 : 10}" fill="${c}" style="${glow}"/>`;
  }).join("");
  return `<svg viewBox="0 0 358 200" role="img" aria-label="Plan de ${esc(r.name)}"><rect x="18" y="18" width="322" height="164" rx="16" fill="#141416" stroke="#2c2c2e"/>${shapes}</svg>`;
}
function renderPiece() {
  const r = ROOMS && !ROOMS.error && ROOMS.find(x => x.id === route.arg);
  if (!r) { $("#piece").innerHTML = `<div class="nh"><button class="rb" data-back aria-label="Retour">${icon("plus", 22).replace(IC.plus, "M20 12H5M11 5l-7 7 7 7")}</button><span class="t">Pièce</span></div><p class="note">${ROOMS ? "Pièce introuvable." : "Chargement…"}</p>`; return; }
  const rb = roomBg(r, 160), c1 = boost(rb.colors[rb.colors.length - 1], 190), dark = rb.colors.reduce((a, c) => a + lum(boost(c, 190)), 0) / rb.colors.length > .5;
  const fg = r.on ? (dark ? "#1b1c20" : "#fff") : "#fff";
  const scenes = allPalettes().filter(p => p.scenes);
  const effs = Object.keys(FX_N).filter(k => r.lights.some(l => (l.effects || []).includes(k)));
  const gsup = new Set(r.lights.flatMap(l => l.grad_modes || [])), gmodes = GMODES.filter(([k]) => gsup.has(k));
  $("#piece").innerHTML = `<div class="rhead" style="background:${r.on ? rb.css : "#232326"};color:${fg};box-shadow:${r.on ? `0 10px 34px ${c1}44` : "none"}">
    <div style="display:flex;align-items:center;gap:16px"><button class="rb" data-back aria-label="Retour" style="background:${r.on ? (dark ? "rgba(0,0,0,.12)" : "rgba(255,255,255,.18)") : "#3a3b40"};color:inherit">${icon("plus", 22, "currentColor", 2.6).replace(IC.plus, "M20 12H5M11 5l-7 7 7 7")}</button>
    <span style="flex:1;font-size:22px;font-weight:700">${esc(r.name)}</span>
    <button class="pwbtn" id="pPow" aria-label="${r.on ? "Éteindre" : "Allumer"}" style="width:48px;height:48px;background:${r.on ? "rgba(255,255,255,.75)" : "#34353a"};color:${r.on ? "#1b1c20" : "#8d8e94"}">${icon("power", 22, "currentColor", 2.4)}</button></div>
    ${r.on ? `<div class="sl" id="pBri" style="margin:18px 4px 2px"><div class="tr" style="background:rgba(0,0,0,.12)"></div><div class="fi" style="width:${r.bri}%;background:rgba(0,0,0,.3)"></div><div class="kn" style="left:${r.bri}%"></div></div>` : ""}</div>
    <div class="plan" style="position:relative">${planSvg(r)}<button class="txtbtn" data-editplan style="position:absolute;right:26px;bottom:24px;font-size:13px;background:rgba(27,28,32,.8);padding:6px 10px;border-radius:10px">Modifier le plan</button></div>
    <div class="spr"><span>Couleurs selon la position</span><div class="seg">${[["lr", "M4 12h16M15 7l5 5-5 5", "De gauche à droite"], ["fb", "M12 4v16M7 15l5 5 5-5", "De l'avant vers l'arrière"], ["tour", "M20 12a8 8 0 1 1-2.3-5.7M20 4v4h-4", "Autour de la pièce"], ["centre", "M12 10a2 2 0 1 0 0 4 2 2 0 0 0 0-4M12 3v3M12 18v3M3 12h3M18 12h3", "Du centre vers les murs"]].map(([k, d, t]) => `<button data-spr="${k}" class="${spread === k ? "on" : ""}" aria-label="${t}" title="${t}"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="${d}"/></svg></button>`).join("")}</div></div>
    <div class="spr" style="flex-direction:column;align-items:stretch;gap:8px"><span>Animation des scènes</span><div class="seg wide">${ANIMS.map(([v, n]) => `<button data-anim="${v}" class="${(ANIM[r.id] || 0) === v ? "on" : ""}">${n}</button>`).join("")}</div></div>
    ${gmodes.length > 1 ? `<div class="spr" style="flex-direction:column;align-items:stretch;gap:8px"><span>Rendu du ruban</span><div class="seg wide">${gmodes.map(([k, n]) => `<button data-gmode="${k}" class="${gmodeOf(r) === k ? "on" : ""}">${n}</button>`).join("")}</div><span style="font-size:12px;color:var(--t3)">${GMODE_D[gmodeOf(r)] || ""}</span></div>` : ""}
    <div class="pad"><div class="label in">Scènes</div><div class="grid3">${scenes.map(p => orbTile(p.name, p.colors, scenePick[r.id] === p.id && r.on, `data-scene="${p.id}"`)).join("")}${orbTile("Créer", null, false, 'data-newpal="scene"')}</div>
    ${effs.length ? `<div class="label in">Effets</div><div class="grid2">${effs.map(k => { const on = r.on && r.lights.some(l => l.effect === k); return `<button class="tile ${on ? "on" : ""}" data-fx="${k}">${fxIcon(k)}<span class="n">${FX_N[k][0]}</span><span class="d">${FX_N[k][1]}</span></button>`; }).join("")}</div>${r.lights.some(l => l.effect && l.effect !== "no_effect") ? `<button class="cta ghost" data-fx="no_effect" style="margin-top:10px">Arrêter l'effet</button>` : ""}<p class="hint" style="margin:8px 4px 0">Joués par le pont lui-même, sur la couleur actuelle de chaque lampe. La vitesse suit « Animation des scènes ».</p>` : ""}
    <div class="label in">Lampes</div><div class="grid3">${r.lights.map(l => lampTile(l)).join("")}</div><div style="height:24px"></div></div>`;
  $("#pPow").onclick = () => roomPower(r.id);
  if ($("#pBri")) slider($("#pBri"), t => { setSl($("#pBri"), t); r.bri = Math.max(1, Math.round(t * 100)); }, () => { roomsLock = Date.now() + 1200; api("/api/room", { group: r.group, bri: r.bri }).catch(e => toast(e.message)); });
  $$("[data-spr]").forEach(b => b.onclick = () => { spread = b.dataset.spr; store("spread", spread); if (scenePick[r.id]) applyScene(r, scenePick[r.id]); else renderPiece(); });
  $$("[data-scene]").forEach(b => b.onclick = () => applyScene(r, b.dataset.scene));
  $$("[data-editplan]").forEach(b => b.onclick = () => go("plan", "r:" + r.id));
  $$("[data-anim]").forEach(b => b.onclick = () => { ANIM[r.id] = +b.dataset.anim; store("anim", JSON.stringify(ANIM)); if (scenePick[r.id]) applyScene(r, scenePick[r.id]); else { renderPiece(); toast(ANIM[r.id] ? "Choisis une scène : elle sera animée" : "Scènes fixes"); } });
  $$("[data-newpal]").forEach(b => b.onclick = () => openCreer("scene"));
  $$("[data-gmode]").forEach(b => b.onclick = () => { GMODE[r.id] = b.dataset.gmode; store("gmode", JSON.stringify(GMODE)); if (scenePick[r.id]) applyScene(r, scenePick[r.id]); else { renderPiece(); toast("Choisis une scène pour voir le rendu"); } });
  $$("[data-fx]").forEach(b => b.onclick = () => applyEffect(r, b.dataset.fx));
  $$("[data-lpow]").forEach(b => b.onclick = e => { e.stopPropagation(); lightPower(r, b.dataset.lpow); });
  $$("[data-lamp]").forEach(b => b.onclick = () => go("lampe", r.id + "|" + b.dataset.lamp));
}
function lampTile(l) {
  const k = lampKind(l.archetype), c = boost(l.color, 210), grad = l.gradient && l.gradient.length > 1;
  let bg = "#2a2b30";
  if (l.on && grad) {        // le dégradé du ruban tel qu'il est allumé, du début à la fin
    const u = [...new Set(l.gradient)], g = (u.length > 3 ? [u[0], u[Math.floor(u.length / 2)], u[u.length - 1]] : u).map(x => boost(x, 190));
    bg = g.length > 1 ? `linear-gradient(155deg, ${g.map((c, i) => `${c} ${Math.round(8 + i / (g.length - 1) * 84)}%`).join(", ")})` : g[0];
  } else if (l.on) bg = `linear-gradient(160deg, ${lighten(c, .35)}, ${c})`;
  const light = l.on && (grad ? l.gradient.reduce((a, x) => a + lum(boost(x, 200)), 0) / l.gradient.length < .5 : lum(c) < .45);
  const fg = l.on && !light ? "#1b1c20" : "#fff";
  return `<div class="lamp" style="background:${bg};color:${fg}"><button class="top" data-lamp="${l.id}">${icon(k, 30)}<span>${esc(l.name)}</span></button>
    <div class="pw"><button class="pwbtn" data-lpow="${l.id}" aria-label="${l.on ? "Éteindre" : "Allumer"} ${esc(l.name)}" style="background:${l.on ? "rgba(255,255,255,.75)" : "#34353a"};color:${l.on ? "#1b1c20" : "#8d8e94"}">${icon("power", 20, "currentColor", 2.4)}</button></div></div>`;
}
async function lightPower(r, id) {
  const l = r.lights.find(x => x.id === id); l.on = !l.on; r.on = r.lights.some(x => x.on); roomsLock = Date.now() + 1200; render();
  try { await api("/api/light", { id, on: l.on }); } catch (e) { toast(e.message); }
}
async function applyScene(r, pid) {
  scenePick[r.id] = pid; const colors = palColors(pid), cyc = spread === "tour";
  r.on = true;
  r.lights.forEach(l => { l.on = true; l.effect = "no_effect"; });
  roomsLock = Date.now() + 2000 + 120 * r.lights.length;
  try {
    const res = await api("/api/room/palette", { id: r.id, colors, spread, speed: ANIM[r.id] || 0, grad_mode: gmodeOf(r) });
    if (res.animated) toast("Scène animée lancée");
    Object.entries(res.lights || {}).forEach(([id, v]) => { const l = r.lights.find(x => x.id === id); if (l) Object.assign(l, v); });
    roomsLock = Date.now() + 1500 + (res.ms || 0); render();
  } catch (e) { toast(e.message); }
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
    clearTimeout(sendT); sendT = setTimeout(() => { roomsLock = Date.now() + 1200; api("/api/light", body).catch(er => toast(er.message)); }, 120);
  };
  let drag = false;
  wheel.addEventListener("pointerdown", e => { drag = true; wheel.setPointerCapture(e.pointerId); pick(e); });
  wheel.addEventListener("pointermove", e => drag && pick(e));
  wheel.addEventListener("pointerup", () => drag = false);
  slider($("#lBri"), t => { setSl($("#lBri"), t); l.bri = Math.max(1, Math.round(t * 100)); $("#lBriPct").textContent = l.bri + " %"; }, () => { roomsLock = Date.now() + 1200; api("/api/light", { id: l.id, bri: l.bri }).catch(e => toast(e.message)); });
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
  if (!document.hidden && S && S.service.active && (route.v === "sync" || route.v === "avances")) { try { const l = await api("/api/live"); const n = l.now; delete l.now; live = l; if (n && (!S.now || n.cover !== S.now.cover || n.title !== S.now.title || n.playing !== S.now.playing)) { setNow(n); if ($(".sheet.open")) renderSheets(); } else if (n) setNow(n); if (route.v === "sync") renderSync(); else livePrev(); } catch (e) {} }
  setTimeout(liveLoop, 100);
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
