#!/usr/bin/env bash
# Mise à jour de Hue Sync dans la VM (à lancer avec sudo). Conserve réglages, palettes et appairage.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Lance-le avec sudo : sudo bash $0"; exit 1; }
[ -d /opt/hue-music-sync ] || { echo "Hue Sync n'est pas installé ici."; exit 1; }
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p /opt/hue-music-sync/backup-$STAMP
cp /opt/hue-music-sync/*.py /opt/hue-music-sync/*.html /opt/hue-music-sync/backup-$STAMP/ 2>/dev/null || true
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


def resolve_palette(name, conf_dir):
    if name in PALETTES:
        return PALETTES[name]
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
        if self.beat_count % p["every"] == 0:
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
                # Chaque lampe suit sa bande : graves à gauche, médiums au centre, aigus à droite
                if pos < 0.5:
                    hit = bands["on_bass"] * (1 - 2 * pos) + bands["on_mid"] * 2 * pos
                else:
                    hit = bands["on_mid"] * (2 - 2 * pos) + bands["on_high"] * (2 * pos - 1)
                hit = max(0.0, (hit - 0.25) / 0.75)
                if beat and pos < 0.34:
                    hit = max(hit, 0.6 + 0.4 * strength)
                # couleurs fixes par position, qui glissent au fil des changements
                target = self.palette[(self.color_idx + int(pos * (len(self.palette) - 1) + 0.5))
                                      % len(self.palette)]
            else:
                hit = (0.55 + 0.45 * strength) if (beat and self.active[i]) else 0.0
                if beat and p["pattern"] == "wave" and n > 1:
                    dist = abs(i - getattr(self, "wave_pos", 0))
                    hit = (0.55 + 0.45 * strength) * max(0.0, 1 - 0.55 * dist)
                if beat and not self.active[i] and p["pattern"] == "alt":
                    hit = 0.35
                offset = i if p["pattern"] != "all" else (i % 2)
                target = self.palette[(self.color_idx + offset) % len(self.palette)]

            self.env[i] = max(hit, self.env[i] * decay)
            self.current[i] += (target - self.current[i]) * fade

            if self.mode == "spectrum":   # en Spectre, chaque lampe dépend surtout de sa bande
                b = 0.6 * p["base"] + 0.5 * p["energy"] * energy + max(p["beat"], 0.55) * self.env[i]
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

Aucune dépendance hors Python standard. À utiliser sur le réseau local uniquement.
"""

import base64
import json
import os
import re
import secrets
import subprocess
import sys
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
    return "Hue Sync"


def set_airplay_name(name):
    name = re.sub(r'["\\$`\n]', "", name).strip()[:40] or "Hue Sync"
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
# Palettes personnalisées
# ---------------------------------------------------------------------------
def list_custom_palettes():
    return [{k: p.get(k) for k in ("id", "name", "colors", "points", "updated")} for p in hms.custom_palettes(CONF_DIR)]


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
    elif not os.path.exists(os.path.join(PALETTE_IMG_DIR, pid + ".jpg")):
        raise ValueError("Ajoute une image.")
    entry = {"id": pid, "name": name, "colors": colors, "points": points, "updated": int(time.time())}
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
                "name": "Hue Sync", "short_name": "Hue Sync", "display": "standalone",
                "background_color": "#000000", "theme_color": "#000000", "start_url": "/"}).encode(),
                "application/manifest+json")
        if path == "/api/state":
            cfg = hms.load_config_or_none()
            return self._send(200, {
                "service": service_state(),
                "paired": bool(cfg), "bridge": cfg["bridge"] if cfg else None,
                "settings": get_settings(), "airplay_name": airplay_name(),
                "palettes": hms.PALETTES, "custom_palettes": list_custom_palettes(),
                "intensities": list(hms.INTENSITY), "presets": hms.INTENSITY,
                "pairing": pairing, "live": get_live()})
        if path == "/api/live":
            return self._send(200, get_live())
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
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Interface Hue Sync sur http://0.0.0.0:{PORT}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
HUE_FILE_EOF
cat > /opt/hue-music-sync/index.html <<'HUE_FILE_EOF'
<!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Hue Sync">
<meta name="theme-color" content="#000000">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<title>Hue Sync</title>
<style>
  :root {
    --bg: #000; --card: #1c1c1e; --card2: #2c2c2e; --card3: #3a3a3c;
    --sep: rgba(84,84,88,.55); --text: #fff; --sub: #8e8e93; --green: #30d158;
    --red: #ff453a; --radius: 16px;
    --safe-t: env(safe-area-inset-top, 0px); --safe-b: env(safe-area-inset-bottom, 0px);
  }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  html, body { margin: 0; background: var(--bg); color: var(--text); }
  body {
    font: 17px/1.3 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, "Segoe UI", Roboto, sans-serif;
    -webkit-font-smoothing: antialiased; user-select: none; -webkit-user-select: none;
    padding: calc(var(--safe-t) + 12px) 16px calc(var(--safe-b) + 40px);
    max-width: 560px; margin: 0 auto;
  }
  button { font: inherit; color: inherit; background: none; border: 0; padding: 0; cursor: pointer; }
  input, select { font: inherit; color: inherit; }

  /* En-tête */
  .top { display: flex; align-items: flex-end; justify-content: space-between; margin: 8px 4px 18px; }
  h1 { font-size: 34px; line-height: 1.1; font-weight: 700; margin: 0; letter-spacing: .2px; }
  .status { color: var(--sub); font-size: 15px; margin-top: 4px; display: flex; align-items: center; gap: 7px; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--sub); flex: none; }
  .dot.on { background: var(--green); box-shadow: 0 0 8px var(--green); }
  .dot.wait { background: #ffd60a; }
  .icon-btn { width: 36px; height: 36px; border-radius: 50%; background: var(--card); display: grid; place-items: center; }

  /* Tuile de zone, façon carte de pièce Hue */
  .tile {
    position: relative; border-radius: 22px; padding: 18px 18px 16px; min-height: 196px;
    background: var(--card2); overflow: hidden; isolation: isolate;
    transition: background .25s ease;
  }
  .tile::after { /* voile pour garder le texte lisible */
    content: ""; position: absolute; inset: 0; z-index: -1;
    background: linear-gradient(180deg, rgba(0,0,0,.05), rgba(0,0,0,.28));
  }
  .tile-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; }
  .tile-title { font-size: 22px; font-weight: 700; text-shadow: 0 1px 6px rgba(0,0,0,.25); }
  .tile-sub { font-size: 15px; opacity: .85; margin-top: 2px; }
  .lights { display: flex; gap: 12px; margin: 26px 2px 22px; min-height: 30px; align-items: center; flex-wrap: wrap; }
  .bulb {
    width: 26px; height: 26px; border-radius: 50%; background: rgba(255,255,255,.25);
    border: 2px solid rgba(255,255,255,.55); transition: transform .09s linear, background .09s linear, box-shadow .09s linear;
  }

  /* Interrupteur iOS */
  .switch { position: relative; width: 51px; height: 31px; flex: none; }
  .switch input { position: absolute; opacity: 0; inset: 0; margin: 0; cursor: pointer; z-index: 2; }
  .switch span { position: absolute; inset: 0; border-radius: 31px; background: rgba(120,120,128,.36); transition: background .2s; }
  .switch span::after {
    content: ""; position: absolute; width: 27px; height: 27px; left: 2px; top: 2px; border-radius: 50%;
    background: #fff; box-shadow: 0 3px 8px rgba(0,0,0,.25); transition: transform .22s cubic-bezier(.3,.7,.4,1);
  }
  .switch input:checked + span { background: var(--green); }
  .switch input:checked + span::after { transform: translateX(20px); }
  .tile .switch input:checked + span { background: rgba(255,255,255,.95); }
  .tile .switch input:checked + span::after { background: #1c1c1e; }

  /* Curseur de luminosité large, sans poignée (comme dans l'app Hue) */
  .slider { position: relative; height: 44px; border-radius: 14px; background: rgba(0,0,0,.28); overflow: hidden; touch-action: none; cursor: pointer; }
  .slider .fill { position: absolute; inset: 0 auto 0 0; background: rgba(255,255,255,.88); border-radius: 14px 0 0 14px; }
  .slider .lbl { position: absolute; inset: 0; display: flex; align-items: center; justify-content: space-between; padding: 0 14px; font-size: 15px; font-weight: 600; pointer-events: none; }
  .slider .lbl .sun { mix-blend-mode: difference; color: #fff; display: flex; align-items: center; gap: 8px; }
  .slider .lbl .pct { mix-blend-mode: difference; color: #fff; }

  /* Sections */
  .section-title { color: var(--sub); font-size: 13px; text-transform: uppercase; letter-spacing: .4px; margin: 28px 16px 8px; }
  .group { background: var(--card); border-radius: var(--radius); overflow: hidden; }
  .row { display: flex; align-items: center; gap: 12px; min-height: 52px; padding: 10px 16px; position: relative; width: 100%; text-align: left; }
  .row + .row::before { content: ""; position: absolute; top: 0; left: 16px; right: 0; height: .5px; background: var(--sep); }
  .row .main { flex: 1; min-width: 0; }
  .row .t { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .row .s { color: var(--sub); font-size: 14px; margin-top: 1px; }
  .row .v { color: var(--sub); font-size: 16px; }
  .check { color: var(--green); font-weight: 700; font-size: 18px; width: 20px; text-align: right; }
  .chev { color: #5a5a5e; font-size: 20px; }
  .row input.inline { background: transparent; border: 0; text-align: right; color: var(--sub); outline: none; width: 55%; }
  .row select { background: transparent; border: 0; color: var(--sub); text-align: right; appearance: none; -webkit-appearance: none; outline: none; }
  .zone-ico { width: 34px; height: 34px; border-radius: 10px; background: var(--card2); display: grid; place-items: center; flex: none; }
  .empty { color: var(--sub); padding: 18px 16px; font-size: 15px; }

  /* Palettes */
  .palettes { display: flex; gap: 16px; overflow-x: auto; padding: 14px 16px 12px; scroll-snap-type: x mandatory; scroll-padding: 0 16px; scrollbar-width: none; }
  .palettes::-webkit-scrollbar { display: none; }
  .pal { flex: none; display: flex; flex-direction: column; align-items: center; gap: 8px; scroll-snap-align: start; }
  .pal .sw { width: 62px; height: 62px; border-radius: 50%; position: relative; transition: transform .15s; }
  .pal .sw::after { content: ""; position: absolute; inset: -5px; border-radius: 50%; border: 2.5px solid transparent; transition: border-color .15s; }
  .pal.sel .sw::after { border-color: #fff; }
  .pal:active .sw { transform: scale(.94); }
  .pal span { font-size: 13px; color: var(--sub); }
  .pal.sel span { color: var(--text); font-weight: 600; }

  /* Contrôle segmenté iOS */
  .seg { display: grid; grid-auto-flow: column; grid-auto-columns: 1fr; background: var(--card2); border-radius: 10px; padding: 2px; margin: 12px 16px; position: relative; }
  .seg button { padding: 8px 4px; font-size: 14px; font-weight: 500; border-radius: 8px; position: relative; z-index: 1; transition: color .2s; color: #c7c7cc; }
  .seg button.sel { color: #fff; font-weight: 600; }
  .seg .pill { position: absolute; top: 2px; bottom: 2px; border-radius: 8px; background: #636366; box-shadow: 0 3px 8px rgba(0,0,0,.2); transition: left .25s cubic-bezier(.3,.7,.4,1), width .25s; }
  .hint { color: var(--sub); font-size: 13px; padding: 0 16px 14px; margin-top: -4px; }

  /* Cartes de mode */
  .modes { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .mode { background: var(--card); border-radius: var(--radius); padding: 14px; text-align: left; border: 2px solid transparent; transition: border-color .15s; }
  .mode.sel { border-color: #fff; }
  .mode svg { display: block; margin-bottom: 10px; }
  .mode .t { font-weight: 600; }
  .mode .s { color: var(--sub); font-size: 13px; margin-top: 2px; }

  /* Feuilles (appairage, journal) */
  .sheet-bg { position: fixed; inset: 0; background: rgba(0,0,0,.5); opacity: 0; pointer-events: none; transition: opacity .25s; z-index: 10; }
  .sheet-bg.open { opacity: 1; pointer-events: auto; }
  .sheet { position: fixed; left: 0; right: 0; bottom: 0; max-width: 560px; margin: 0 auto; background: var(--card); border-radius: 14px 14px 0 0; padding: 10px 20px calc(var(--safe-b) + 24px); transform: translateY(105%); transition: transform .32s cubic-bezier(.3,.7,.3,1); z-index: 11; max-height: 85vh; display: flex; flex-direction: column; }
  .sheet.open { transform: none; }
  .grab { width: 36px; height: 5px; border-radius: 3px; background: #48484a; margin: 0 auto 14px; flex: none; }
  .sheet h2 { font-size: 22px; margin: 4px 0 6px; }
  .sheet p { color: var(--sub); font-size: 15px; margin: 0 0 16px; }
  .field { width: 100%; background: var(--card2); border: 0; border-radius: 12px; padding: 14px; outline: none; margin-bottom: 12px; }
  .btn { width: 100%; background: #fff; color: #000; border-radius: 14px; padding: 15px; font-weight: 600; font-size: 17px; }
  .btn:disabled { opacity: .5; }
  .btn.secondary { background: var(--card2); color: #fff; margin-top: 10px; }
  pre.logs { flex: 1; overflow: auto; background: #000; border-radius: 12px; padding: 12px; font: 12px/1.45 ui-monospace, Menlo, monospace; color: #c7c7cc; white-space: pre-wrap; user-select: text; -webkit-user-select: text; margin: 0; }
  .ring { width: 92px; height: 92px; margin: 10px auto 18px; border-radius: 50%; border: 4px solid var(--card3); border-top-color: #fff; animation: spin 1s linear infinite; display: grid; place-items: center; }
  .ring b { animation: spin 1s linear infinite reverse; font-size: 22px; }
  @keyframes spin { to { transform: rotate(360deg); } }

  /* Écran d'accueil (pas encore appairé) */
  .welcome { text-align: center; padding: 40px 12px; }
  .welcome .bridge { width: 96px; height: 96px; border-radius: 28px; margin: 0 auto 20px; background: var(--card); display: grid; place-items: center; }
  .welcome h2 { font-size: 24px; margin: 0 0 8px; }
  .welcome p { color: var(--sub); margin: 0 0 24px; }

  .toast { position: fixed; left: 50%; top: calc(var(--safe-t) + 14px); transform: translate(-50%, -20px); background: rgba(44,44,46,.96); backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); padding: 12px 18px; border-radius: 14px; font-size: 15px; opacity: 0; transition: all .25s; z-index: 20; max-width: 90vw; text-align: center; pointer-events: none; }
  .toast.show { opacity: 1; transform: translate(-50%, 0); }
  .slider.dark { background: var(--card2); margin: 4px 16px 14px; }
  .bt-btn { font-size: 15px; color: #64d2ff; padding: 6px 2px; flex: none; }
  .bt-btn.danger { color: var(--red); }
  .bt-ico { width: 34px; height: 34px; border-radius: 10px; background: var(--card2); display: grid; place-items: center; flex: none; }
  .bt-ico.on { background: #0a84ff; }
  .spin { width: 16px; height: 16px; border-radius: 50%; border: 2px solid #48484a; border-top-color: #fff; animation: spin .8s linear infinite; flex: none; }
  .scan-row { color: #64d2ff; justify-content: center; gap: 10px; }
  .group-hint { color: var(--sub); font-size: 13px; margin: 8px 16px 0; min-height: 0; }
  .pal .sw.img { background-size: cover; background-position: center; }
  .pal .badge { position: absolute; right: -3px; bottom: -3px; width: 24px; height: 24px; border-radius: 50%; background: #fff; display: grid; place-items: center; z-index: 1; box-shadow: 0 2px 6px rgba(0,0,0,.4); }
  .pal.add .sw { border: 2px dashed #48484a; display: grid; place-items: center; color: var(--sub); font-size: 30px; font-weight: 300; }
  .sheet.tall { height: 92vh; max-height: 92vh; }
  .sheet-body { flex: 1; overflow: auto; margin: 0 -20px; padding: 0 20px; -webkit-overflow-scrolling: touch; }
  .sheet-foot { flex: none; padding-top: 12px; }
  .pick-area { display: flex; justify-content: center; margin: 4px 0 14px; }
  .pick-wrap { position: relative; touch-action: none; }
  .pick-wrap img { display: block; width: 100%; height: 100%; pointer-events: none; border-radius: 16px; }
  .pt { position: absolute; width: 40px; height: 40px; margin: -20px 0 0 -20px; border-radius: 50%; border: 3px solid #fff; box-shadow: 0 3px 12px rgba(0,0,0,.55); touch-action: none; cursor: grab; transition: transform .12s; }
  .pt.drag { transform: scale(1.3); cursor: grabbing; }
  .pick-empty { width: 100%; height: 240px; border-radius: 16px; border: 2px dashed #48484a; display: grid; place-items: center; text-align: center; color: var(--sub); }
  .pick-empty b { display: block; color: #fff; font-size: 17px; margin: 10px 0 4px; }
  .swatches { display: flex; gap: 10px; justify-content: center; margin: 0 0 16px; }
  .swatches span { width: 34px; height: 34px; border-radius: 50%; box-shadow: inset 0 0 0 1px rgba(255,255,255,.15); }
  .room-h { display: flex; align-items: center; justify-content: space-between; margin: 20px 4px 8px; }
  .room-h .n { color: var(--sub); font-size: 13px; text-transform: uppercase; letter-spacing: .4px; }
  .room-h button { color: #64d2ff; font-size: 15px; }
  .ck { width: 26px; height: 26px; border-radius: 50%; border: 2px solid #48484a; flex: none; display: grid; place-items: center; font-size: 13px; font-weight: 700; color: #fff; transition: all .15s; }
  .ck.on { background: #0a84ff; border-color: #0a84ff; }
  .count { color: var(--sub); font-size: 14px; text-align: center; margin-bottom: 10px; }
  .adv-toggle .chev { transition: transform .2s; }
  .adv-toggle.open .chev { transform: rotate(90deg); }
  .adv-item { padding: 12px 16px 4px; position: relative; }
  .adv-item + .adv-item::before { content: ""; position: absolute; top: 0; left: 16px; right: 0; height: .5px; background: var(--sep); }
  .adv-head { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 8px; }
  .adv-head .v { color: var(--sub); font-size: 15px; }
  .adv-item .slider.dark { margin: 0 0 10px; height: 36px; border-radius: 11px; }
  .adv-item .seg { margin: 0 0 10px; }
  .adv-item .seg button.sel { background: #636366; box-shadow: 0 3px 8px rgba(0,0,0,.2); }
  .adv-item .s { color: var(--sub); font-size: 13px; margin: -2px 0 10px; }
  .badge-custom { display: inline-block; background: #0a84ff; color: #fff; font-size: 11px; font-weight: 700; padding: 2px 7px; border-radius: 6px; margin-left: 6px; vertical-align: 2px; text-transform: none; letter-spacing: 0; }
  .hidden { display: none !important; }
  .foot { color: #48484a; font-size: 12px; text-align: center; margin-top: 28px; }
</style>
</head>
<body>

<div class="top">
  <div>
    <h1>Hue Sync</h1>
    <div class="status"><span class="dot" id="dot"></span><span id="statusText">Connexion…</span></div>
  </div>
  <button class="icon-btn" id="logsBtn" aria-label="Journal">
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round"><path d="M4 6h16M4 12h16M4 18h10"/></svg>
  </button>
</div>

<!-- Pas encore appairé -->
<div id="welcome" class="welcome hidden">
  <div class="bridge">
    <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.6"><rect x="3" y="7" width="18" height="10" rx="5"/><circle cx="12" cy="12" r="2.2"/></svg>
  </div>
  <h2>Connecte ton pont Hue</h2>
  <p>Hue Sync a besoin d'être autorisé sur ton pont pour piloter les lampes.</p>
  <button class="btn" id="welcomePair">Appairer le pont</button>
</div>

<div id="app" class="hidden">
  <!-- Tuile de la zone -->
  <div class="tile" id="tile">
    <div class="tile-head">
      <div>
        <div class="tile-title" id="tileTitle">Zone</div>
        <div class="tile-sub" id="tileSub">—</div>
      </div>
      <label class="switch"><input type="checkbox" id="power"><span></span></label>
    </div>
    <div class="lights" id="lights"></div>
    <div class="slider" id="bri">
      <div class="fill" id="briFill"></div>
      <div class="lbl">
        <span class="sun"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>Luminosité</span>
        <span class="pct" id="briPct">100 %</span>
      </div>
    </div>
  </div>

  <div class="section-title">Palette</div>
  <div class="group"><div class="palettes" id="palettes"></div></div>

  <div class="section-title">Intensité <span class="badge-custom hidden" id="customBadge">Personnalisé</span></div>
  <div class="group">
    <div class="seg" id="intensity"></div>
    <div class="hint" id="intensityHint"></div>
  </div>

  <div class="section-title">Effet</div>
  <div class="modes" id="modes">
    <button class="mode" data-mode="pulse">
      <svg width="44" height="28" viewBox="0 0 44 28"><circle cx="8" cy="14" r="6" fill="#fff"/><circle cx="22" cy="14" r="6" fill="#fff"/><circle cx="36" cy="14" r="6" fill="#fff"/></svg>
      <div class="t">Pulsation</div><div class="s">Toutes les lampes sur le rythme</div>
    </button>
    <button class="mode" data-mode="spectrum">
      <svg width="44" height="28" viewBox="0 0 44 28"><rect x="2" y="4" width="8" height="22" rx="3" fill="#ff7b00"/><rect x="14" y="10" width="8" height="16" rx="3" fill="#ffd60a"/><rect x="26" y="15" width="8" height="11" rx="3" fill="#30d158"/><rect x="38" y="19" width="5" height="7" rx="2.5" fill="#64d2ff"/></svg>
      <div class="t">Spectre</div><div class="s">Graves à gauche, aigus à droite</div>
    </button>
  </div>

  <div class="group" style="margin-top:12px">
    <button class="row adv-toggle" id="advToggle">
      <div class="main"><div class="t">Réglages avancés</div><div class="s">Déclenchement, flashs, couleurs, motif</div></div><span class="chev">›</span>
    </button>
  </div>
  <div class="group hidden" id="adv" style="margin-top:8px"></div>

  <div class="section-title">Enceinte Bluetooth</div>
  <div class="group" id="bt"><div class="empty">Chargement…</div></div>
  <div class="group-hint" id="btMsg"></div>
  <div class="group hidden" id="btOffset" style="margin-top:12px">
    <div class="row" style="padding-bottom:4px">
      <div class="main"><div class="t">Décalage des lumières</div><div class="s">Augmente si les lampes sont en avance sur le son</div></div>
    </div>
    <div class="slider dark" id="offSlider">
      <div class="fill" id="offFill"></div>
      <div class="lbl"><span class="sun">Retard</span><span class="pct" id="offPct">300 ms</span></div>
    </div>
  </div>

  <div class="section-title">Zone de divertissement</div>
  <div class="group" id="zones"><div class="empty">Chargement des zones…</div></div>

  <div class="section-title">Réglages</div>
  <div class="group">
    <label class="row">
      <div class="main"><div class="t">Nom AirPlay</div></div>
      <input class="inline" id="apName" maxlength="40" autocomplete="off" spellcheck="false">
    </label>
    <label class="row">
      <div class="main"><div class="t">Pause après silence</div><div class="s">Rend les lampes à l'app Hue</div></div>
      <select id="idle">
        <option value="5">5 s</option><option value="15">15 s</option><option value="30">30 s</option>
        <option value="60">1 min</option><option value="300">5 min</option><option value="0">Jamais</option>
      </select>
      <span class="chev">›</span>
    </label>
    <button class="row" id="bridgeRow">
      <div class="main"><div class="t">Pont Hue</div><div class="s" id="bridgeSub">—</div></div>
      <span class="v">Réappairer</span><span class="chev">›</span>
    </button>
  </div>
  <div class="foot">Sur l'iPhone : AirPlay → « <span id="footName">Hue Sync</span> » (+ tes enceintes AirPlay si besoin)</div>
</div>

<!-- Feuille d'appairage -->
<div class="sheet-bg" id="sheetBg"></div>
<div class="sheet" id="pairSheet">
  <div class="grab"></div>
  <div id="pairForm">
    <h2>Appairer le pont</h2>
    <p id="discMsg">Recherche des ponts Hue sur ton réseau…</p>
    <div class="group" id="bridgeList" style="margin-bottom:12px"></div>
    <div id="manualBox" class="hidden">
      <input class="field" id="bridgeIp" placeholder="Adresse IP, ex. 192.168.1.20" inputmode="decimal" autocomplete="off">
    </div>
    <button class="btn" id="pairGo" disabled>Continuer</button>
    <button class="btn secondary" data-close>Annuler</button>
  </div>
  <div id="pairWait" class="hidden" style="text-align:center">
    <div class="ring"><b id="pairCount">30</b></div>
    <h2>Appuie sur le bouton du pont</h2>
    <p id="pairMsg">Le gros bouton rond sur le dessus du pont Hue.</p>
    <button class="btn secondary" data-close>Fermer</button>
  </div>
</div>

<div class="sheet" id="logSheet" style="height:80vh">
  <div class="grab"></div>
  <h2>Journal</h2>
  <pre class="logs" id="logs">…</pre>
  <button class="btn secondary" data-close>Fermer</button>
</div>

<!-- Sélection des lampes -->
<div class="sheet tall" id="lightSheet">
  <div class="grab"></div>
  <h2>Choisir mes lampes</h2>
  <p>Coche des pièces entières ou des lampes seules (10 maximum). L'ordre de sélection place les lampes de gauche à droite pour l'effet Spectre.</p>
  <div class="sheet-body" id="lightList"><div class="empty">Chargement des lampes…</div></div>
  <div class="sheet-foot">
    <div class="count" id="lightCount">0 lampe</div>
    <button class="btn" id="lightSave">Utiliser ces lampes</button>
    <button class="btn secondary" data-close>Annuler</button>
  </div>
</div>

<!-- Éditeur de palette -->
<div class="sheet tall" id="palSheet">
  <div class="grab"></div>
  <h2 id="palTitle">Nouvelle palette</h2>
  <div class="sheet-body">
    <div class="pick-area" id="pickArea"></div>
    <div class="swatches" id="palSwatches"></div>
    <input class="field" id="palName" placeholder="Nom de la palette" maxlength="30" autocomplete="off">
    <button class="btn secondary" id="palPhoto" style="margin-top:0">Choisir une autre photo</button>
    <button class="btn secondary hidden" id="palDelete" style="color:var(--red)">Supprimer la palette</button>
  </div>
  <div class="sheet-foot">
    <button class="btn" id="palSave">Enregistrer</button>
    <button class="btn secondary" data-close>Annuler</button>
  </div>
  <input type="file" id="palFile" accept="image/*" class="hidden">
</div>

<div class="toast" id="toast"></div>

<script>
const $ = s => document.querySelector(s);
const PAL_NAMES = { sunset: "Coucher", ocean: "Océan", neon: "Néon", fire: "Feu", forest: "Forêt", party: "Fête", ice: "Glace" };
const INT_NAMES = { subtle: "Subtile", moderate: "Modérée", high: "Élevée", intense: "Intense" };
const INT_HINTS = {
  subtle: "Transitions douces, idéal en fond sonore.",
  moderate: "Équilibré, suit le rythme sans agresser.",
  high: "Réactif, pulsations marquées sur chaque temps.",
  intense: "Changements rapides et flashs sur les drops."
};
let S = null;            // dernier état reçu
let live = { state: "offline", colors: [] };
let zones = null;
let pending = {};        // réglages modifiés en attente d'envoi
let sendTimer = null;
let lockUntil = 0;       // évite que le polling écrase un réglage en cours

const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

async function api(path, body) {
  const opt = body === undefined ? {} : { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) };
  const r = await fetch(path, opt);
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || j.message || ("Erreur " + r.status));
  return j;
}

function toast(msg) {
  const t = $("#toast"); t.textContent = msg; t.classList.add("show");
  clearTimeout(toast.t); toast.t = setTimeout(() => t.classList.remove("show"), 2200);
}

function save(patch, now = false) {
  Object.assign(pending, patch);
  Object.assign(S.settings, patch);
  lockUntil = Date.now() + 2500;
  clearTimeout(sendTimer);
  sendTimer = setTimeout(async () => {
    const body = pending; pending = {};
    try { await api("/api/settings", body); }
    catch (e) { toast("Échec : " + e.message); }
  }, now ? 0 : 280);
}

/* ---------- Rendu ---------- */
function renderStatic() {
  renderPalettes();
  const seg = $("#intensity");
  seg.innerHTML = '<div class="pill"></div>' + S.intensities.map(k => `<button data-int="${k}">${INT_NAMES[k] || k}</button>`).join("");
  seg.querySelectorAll("button").forEach(b => b.onclick = () => {
    S.settings.fx = {}; delete pending.fx;
    save({ intensity: b.dataset.int }, true); renderSettings();
  });

  document.querySelectorAll(".mode").forEach(b => b.onclick = () => { save({ mode: b.dataset.mode }, true); renderSettings(); });
}

let palKey = "";
function renderPalettes() {
  const key = JSON.stringify(S.custom_palettes || []);
  if (key === palKey) return;
  palKey = key;
  const pals = $("#palettes");
  const builtin = Object.entries(S.palettes).map(([k, cols]) =>
    `<button class="pal" data-pal="${k}"><div class="sw" style="background:conic-gradient(${cols.concat(cols[0]).join(",")})"></div><span>${PAL_NAMES[k] || k}</span></button>`);
  const custom = (S.custom_palettes || []).map(p =>
    `<button class="pal" data-pal="${p.id}" data-custom="1"><div class="sw img" style="background-image:url('/palettes/${p.id}.jpg?v=${p.updated || 0}')">
      <span class="badge hidden"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="2.6" stroke-linecap="round"><path d="M4 20h4L20 8l-4-4L4 16v4z"/></svg></span></div><span>${esc(p.name)}</span></button>`);
  pals.innerHTML = builtin.concat(custom).join("") + '<button class="pal add" id="palAdd"><div class="sw">+</div><span>Créer</span></button>';
  pals.querySelectorAll(".pal[data-pal]").forEach(b => b.onclick = () => {
    if (b.dataset.custom && S.settings.palette === b.dataset.pal) return openPalEditor(S.custom_palettes.find(p => p.id === b.dataset.pal));
    save({ palette: b.dataset.pal }, true); renderSettings();
  });
  $("#palAdd").onclick = () => openPalEditor(null);
  renderSettings();
}
function palColors(id) {
  if (S.palettes[id]) return S.palettes[id];
  const c = (S.custom_palettes || []).find(p => p.id === id);
  return c ? c.colors : S.palettes.sunset;
}

function renderSettings() {
  const st = S.settings;
  document.querySelectorAll(".pal[data-custom] .badge").forEach(b => b.classList.toggle("hidden", b.closest(".pal").dataset.pal !== st.palette));
  document.querySelectorAll(".pal").forEach(b => b.classList.toggle("sel", b.dataset.pal === st.palette));
  const btns = [...document.querySelectorAll("#intensity button")];
  btns.forEach(b => b.classList.toggle("sel", b.dataset.int === st.intensity));
  const sel = btns.find(b => b.dataset.int === st.intensity);
  if (sel) { const p = $("#intensity .pill"); p.style.left = sel.offsetLeft + "px"; p.style.width = sel.offsetWidth + "px"; }
  $("#intensityHint").textContent = INT_HINTS[st.intensity] || "";
  document.querySelectorAll(".mode").forEach(b => b.classList.toggle("sel", b.dataset.mode === st.mode));
  setBri(st.brightness, false);
  setOffset(st.bt_offset_ms ?? 300, false);
  const custom = st.fx && Object.keys(st.fx).length > 0;
  $("#customBadge").classList.toggle("hidden", !custom);
  if (custom) $("#intensityHint").textContent = `Préréglage « ${INT_NAMES[st.intensity]} » ajusté dans les réglages avancés.`;
  renderAdvValues();
  if (document.activeElement !== $("#apName")) $("#apName").value = S.airplay_name;
  $("#footName").textContent = S.airplay_name;
  const idle = String(st.idle_release);
  if (![...$("#idle").options].some(o => o.value === idle)) $("#idle").add(new Option(idle + " s", idle));
  $("#idle").value = idle;
  $("#bridgeSub").textContent = S.bridge ? `${S.bridge} · connecté` : "Non appairé";
  renderZones();
}

function renderZones() {
  const g = $("#zones");
  if (zones === null) return;
  if (zones.error) { g.innerHTML = `<div class="empty">${esc(zones.error)}</div>`; return; }
  if (!zones.length) { g.innerHTML = `<div class="empty">Aucune zone pour l'instant : choisis tes lampes ci-dessous.</div><button class="row" id="pickLights"><div class="main"><div class="t" style="color:#64d2ff">Choisir mes lampes…</div></div><span class="chev">›</span></button>`; $("#pickLights").onclick = openLights; return; }
  let cur = S.settings.area || live.area_id;
  if (!zones.some(z => z.id === cur || z.name === cur)) cur = zones[0].id;
  g.innerHTML = zones.map(z => {
    const on = z.id === cur || z.name === cur;
    return `<button class="row" data-id="${esc(z.id)}" data-name="${esc(z.name)}">
      <div class="zone-ico"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8"><path d="M9 18h6M10 21h4M12 3a6 6 0 0 0-4 10.5c.7.7 1 1.5 1 2.5h6c0-1 .3-1.8 1-2.5A6 6 0 0 0 12 3z"/></svg></div>
      <div class="main"><div class="t">${esc(z.name)}</div><div class="s">${z.lights} lampe${z.lights > 1 ? "s" : ""}</div></div>
      <span class="check">${on ? "✓" : ""}</span></button>`;
  }).join("");
  g.insertAdjacentHTML("beforeend", `<button class="row" id="pickLights"><div class="zone-ico"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#64d2ff" stroke-width="2.2" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg></div>
    <div class="main"><div class="t" style="color:#64d2ff">Choisir mes lampes…</div><div class="s">Pièces entières ou lampes seules</div></div><span class="chev">›</span></button>`);
  g.querySelectorAll(".row[data-id]").forEach(r => r.onclick = () => { save({ area: r.dataset.name }, true); renderZones(); toast("Zone : " + r.dataset.name); });
  $("#pickLights").onclick = openLights;
}

function statusInfo() {
  const svc = S.service;
  if (!S.paired) return ["", "Pont non appairé"];
  if (!svc.active) return ["", svc.raw === "activating" ? "Démarrage…" : "Synchro désactivée"];
  if (live.state === "syncing") return ["on", "Synchro en cours"];
  if (live.state === "waiting") return ["wait", "En attente de musique AirPlay"];
  return ["wait", "Démarrage…"];
}

function renderStatus() {
  const [cls, txt] = statusInfo();
  $("#dot").className = "dot " + cls;
  $("#statusText").textContent = txt;
  if (Date.now() > lockUntil) $("#power").checked = S.service.active;
  const zoneName = live.area || (zones && !zones.error && zones.length ? (zones.find(z => z.name === S.settings.area || z.id === S.settings.area) || zones[0]).name : "Hue Sync");
  $("#tileTitle").textContent = zoneName;
  const btOn = live.bt && live.bt.playing ? " · son en Bluetooth" : "";
  $("#tileSub").textContent = !S.service.active ? "Désactivée" : (live.state === "syncing" ? "Synchro en cours" : "En attente de musique") + btOn;
}

/* ---------- Animation en direct ---------- */
function renderLive() {
  const tile = $("#tile");
  const active = S && S.service.active && live.state === "syncing" && live.colors.length;
  const palette = S ? palColors(S.settings.palette) : ["#444"];
  const cols = active ? live.colors : (S && S.service.active ? palette : []);
  const box = $("#lights");
  const n = active ? live.colors.length : (zones && !zones.error && zones.length ? (zones.find(z => z.name === S.settings.area) || zones[0]).lights : 5);
  if (box.children.length !== n) box.innerHTML = '<div class="bulb"></div>'.repeat(n);
  [...box.children].forEach((b, i) => {
    if (!S || !S.service.active) { b.style.background = "rgba(255,255,255,.12)"; b.style.boxShadow = "none"; b.style.transform = "scale(1)"; return; }
    const c = cols[i % cols.length];
    const lum = active ? luminance(c) : .45;
    b.style.background = active ? boost([c], 200)[0] : c + "99";
    b.style.boxShadow = active ? `0 0 ${8 + lum * 26}px ${c}` : "none";
    b.style.transform = `scale(${active ? 0.85 + lum * 0.4 : 1})`;
  });
  if (!S || !S.service.active) { tile.style.background = "var(--card2)"; return; }
  const g = (active ? boost(cols) : palette.map(c => c + "cc"));
  tile.style.background = `linear-gradient(115deg, ${g.length > 1 ? g.join(",") : g[0] + "," + g[0]})`;
}
function luminance(hex) {
  const v = parseInt(hex.slice(1), 16);
  return Math.max((v >> 16) & 255, (v >> 8) & 255, v & 255) / 255;
}
function boost(cols, floor = 150) { // garde des couleurs lisibles même quand les lampes sont sombres entre deux temps
  return cols.map(c => {
    const v = parseInt(c.slice(1), 16); let r = (v >> 16) & 255, g = (v >> 8) & 255, b = v & 255;
    const m = Math.max(r, g, b, 1), k = Math.max(1, floor / m);
    r = Math.min(255, r * k); g = Math.min(255, g * k); b = Math.min(255, b * k);
    return `rgb(${r|0},${g|0},${b|0})`;
  });
}

/* ---------- Luminosité ---------- */
function setBri(v, send) {
  v = Math.max(0.05, Math.min(1, v));
  $("#briFill").style.width = (v * 100) + "%";
  $("#briPct").textContent = Math.round(v * 100) + " %";
  if (send) save({ brightness: Math.round(v * 100) / 100 });
}
function makeSlider(el, onValue) {
  let drag = false;
  const at = e => { const r = el.getBoundingClientRect(); onValue(Math.max(0, Math.min(1, (e.clientX - r.left) / r.width))); };
  el.addEventListener("pointerdown", e => { drag = true; el.setPointerCapture(e.pointerId); at(e); });
  el.addEventListener("pointermove", e => drag && at(e));
  el.addEventListener("pointerup", () => drag = false);
  el.addEventListener("pointercancel", () => drag = false);
}
makeSlider($("#bri"), v => setBri(v, true));
const OFF_MAX = 1000;
function setOffset(ms, send) {
  ms = Math.round(Math.max(0, Math.min(OFF_MAX, ms)) / 10) * 10;
  $("#offFill").style.width = (ms / OFF_MAX * 100) + "%";
  $("#offPct").textContent = ms + " ms";
  if (send) save({ bt_offset_ms: ms });
}
makeSlider($("#offSlider"), v => setOffset(v * OFF_MAX, true));

/* ---------- Réglages avancés ---------- */
const ADV = [
  { key: "source", label: "Déclenchement des flashs", type: "seg",
    options: [["full", "Tout"], ["kick", "Grosse caisse"], ["snare", "Caisse claire"]],
    hint: "Ce qui fait réagir les lampes dans la musique." },
  { key: "beat_k", label: "Sensibilité", type: "range", min: 0.8, max: 3.5, invert: true,
    fmt: v => Math.round((3.5 - v) / 2.7 * 100) + " %", hint: "Plus haut = réagit aux petits sons aussi." },
  { key: "min_beat", label: "Écart minimum entre deux flashs", type: "range", min: 0.12, max: 1.0, fmt: v => Math.round(v * 1000) + " ms" },
  { key: "beat", label: "Force des flashs", type: "range", min: 0, max: 1, fmt: v => Math.round(v * 100) + " %" },
  { key: "tau", label: "Durée des flashs", type: "range", min: 0.04, max: 1.5, fmt: v => Math.round(v * 1000) + " ms" },
  { key: "base", label: "Luminosité de fond", type: "range", min: 0, max: 1, fmt: v => Math.round(v * 100) + " %",
    hint: "Lumière entre deux temps. À 100 % avec des flashs à 0 %, seules les couleurs changent." },
  { key: "energy", label: "Suivi du volume du morceau", type: "range", min: 0, max: 1, fmt: v => Math.round(v * 100) + " %",
    hint: "Plus lumineux dans les refrains, plus calme dans les couplets." },
  { key: "every", label: "Changement de couleur", type: "seg",
    options: [[1, "1 temps"], [2, "2 temps"], [4, "4 temps"], [8, "8 temps"]] },
  { key: "fade", label: "Fondu des couleurs", type: "range", min: 0, max: 4, fmt: v => v < 0.05 ? "Instantané" : v.toFixed(1).replace(".", ",") + " s" },
  { key: "pattern", label: "Motif des lampes", type: "seg",
    options: [["all", "Ensemble"], ["alt", "Alternance"], ["chase", "Chenillard"], ["wave", "Vague"]],
    hint: "Utilisé avec l'effet Pulsation (en Spectre, chaque lampe suit sa fréquence)." },
  { key: "strobe", label: "Flash blanc sur les drops", type: "switch" },
];
function fxValue(key) {
  const st = S.settings, fx = st.fx || {};
  return key in fx ? fx[key] : S.presets[st.intensity][key];
}
function saveFx(key, val) {
  S.settings.fx = Object.assign({}, S.settings.fx, { [key]: val });
  pending.fx = Object.assign({}, pending.fx, { [key]: val });
  save({}, false);
  $("#customBadge").classList.remove("hidden");
}
function buildAdv() {
  const box = $("#adv");
  box.innerHTML = ADV.map(a => {
    let ctl = "";
    if (a.type === "range") ctl = `<div class="slider dark" data-k="${a.key}"><div class="fill"></div></div>`;
    if (a.type === "seg") ctl = `<div class="seg" data-k="${a.key}">${a.options.map(o => `<button data-v="${o[0]}">${o[1]}</button>`).join("")}</div>`;
    if (a.type === "switch") ctl = "";
    return `<div class="adv-item"><div class="adv-head"><span>${a.label}</span>${a.type === "switch"
      ? `<label class="switch"><input type="checkbox" data-k="${a.key}"><span></span></label>`
      : `<span class="v" data-v-for="${a.key}"></span>`}</div>${ctl}${a.hint ? `<div class="s">${a.hint}</div>` : ""}</div>`;
  }).join("") + `<button class="row scan-row" id="advReset">Revenir au préréglage</button>`;
  ADV.forEach(a => {
    if (a.type === "range") {
      const el = box.querySelector(`.slider[data-k="${a.key}"]`);
      makeSlider(el, r => {
        const t = a.invert ? 1 - r : r;
        let v = a.min + t * (a.max - a.min);
        v = Math.round(v * 1000) / 1000;
        setAdv(a, v); saveFx(a.key, v);
      });
    }
    if (a.type === "seg") box.querySelectorAll(`.seg[data-k="${a.key}"] button`).forEach(b => b.onclick = () => {
      const v = typeof a.options[0][0] === "number" ? +b.dataset.v : b.dataset.v;
      setAdv(a, v); saveFx(a.key, v);
    });
    if (a.type === "switch") box.querySelector(`input[data-k="${a.key}"]`).onchange = e => saveFx(a.key, e.target.checked);
  });
  $("#advReset").onclick = () => {
    S.settings.fx = {}; delete pending.fx;
    save({ intensity: S.settings.intensity }, true); renderSettings(); toast("Préréglage rétabli");
  };
}
function setAdv(a, v) {
  const box = $("#adv");
  if (a.type === "range") {
    const t = (v - a.min) / (a.max - a.min);
    box.querySelector(`.slider[data-k="${a.key}"] .fill`).style.width = ((a.invert ? 1 - t : t) * 100) + "%";
    box.querySelector(`[data-v-for="${a.key}"]`).textContent = a.fmt(v);
  }
  if (a.type === "seg") {
    box.querySelectorAll(`.seg[data-k="${a.key}"] button`).forEach(b => b.classList.toggle("sel", String(b.dataset.v) === String(v)));
    const lbl = a.options.find(o => String(o[0]) === String(v));
    box.querySelector(`[data-v-for="${a.key}"]`).textContent = lbl ? lbl[1] : "";
  }
  if (a.type === "switch") box.querySelector(`input[data-k="${a.key}"]`).checked = !!v;
}
function renderAdvValues() {
  if (!S || !S.presets || $("#adv").classList.contains("hidden")) return;
  if (!$("#adv").children.length) buildAdv();
  ADV.forEach(a => setAdv(a, fxValue(a.key)));
}
$("#advToggle").onclick = () => {
  const open = $("#adv").classList.toggle("hidden") === false;
  $("#advToggle").classList.toggle("open", open);
  try { localStorage.setItem("advOpen", open ? "1" : ""); } catch (e) {}
  renderAdvValues();
};
try { if (localStorage.getItem("advOpen")) { $("#adv").classList.remove("hidden"); $("#advToggle").classList.add("open"); } } catch (e) {}

/* ---------- Sélection des lampes ---------- */
let LS = null, sel = [];
async function openLights() {
  openSheet("#lightSheet");
  $("#lightList").innerHTML = '<div class="empty">Chargement des lampes…</div>';
  try {
    LS = await api("/api/lights");
    sel = LS.selected.slice();
    renderLights();
  } catch (e) { $("#lightList").innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
}
function toggleLight(id, force) {
  const i = sel.indexOf(id);
  const want = force === undefined ? i < 0 : force;
  if (want && i < 0) { if (sel.length >= LS.max) { toast(`${LS.max} lampes maximum`); return false; } sel.push(id); }
  if (!want && i >= 0) sel.splice(i, 1);
  return true;
}
function renderLights() {
  if (!LS.groups.length) { $("#lightList").innerHTML = '<div class="empty">Aucune lampe couleur compatible trouvée sur le pont.</div>'; return; }
  $("#lightList").innerHTML = LS.groups.map((g, gi) => {
    const all = g.lights.every(l => sel.includes(l.id));
    return `<div class="room-h"><span class="n">${esc(g.name)}</span><button data-room="${gi}">${all ? "Aucune" : "Toutes"}</button></div>
      <div class="group">${g.lights.map(l => {
        const n = sel.indexOf(l.id);
        return `<button class="row" data-light="${l.id}"><div class="zone-ico"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8"><path d="M9 18h6M10 21h4M12 3a6 6 0 0 0-4 10.5c.7.7 1 1.5 1 2.5h6c0-1 .3-1.8 1-2.5A6 6 0 0 0 12 3z"/></svg></div>
          <div class="main"><div class="t">${esc(l.name)}</div></div><span class="ck ${n >= 0 ? "on" : ""}">${n >= 0 ? n + 1 : ""}</span></button>`;
      }).join("")}</div>`;
  }).join("");
  $("#lightList").querySelectorAll("[data-light]").forEach(b => b.onclick = () => { toggleLight(b.dataset.light); renderLights(); });
  $("#lightList").querySelectorAll("[data-room]").forEach(b => b.onclick = () => {
    const g = LS.groups[+b.dataset.room], all = g.lights.every(l => sel.includes(l.id));
    for (const l of g.lights) if (toggleLight(l.id, !all) === false) break;
    renderLights();
  });
  $("#lightCount").textContent = `${sel.length} lampe${sel.length > 1 ? "s" : ""} sur ${LS.max}`;
  $("#lightSave").disabled = !sel.length;
}
$("#lightSave").onclick = async () => {
  $("#lightSave").disabled = true;
  try {
    const r = await api("/api/lights", { ids: sel });
    closeSheets(); toast(`Zone « Hue Sync » : ${r.count} lampe${r.count > 1 ? "s" : ""}`);
    zones = null; lockUntil = 0; refresh(true);
  } catch (e) { toast("Échec : " + e.message); }
  $("#lightSave").disabled = false;
};

/* ---------- Éditeur de palette (à partir d'une image) ---------- */
const ED = { id: "", img: null, newImage: null, points: [], colors: [], ctx: null, w: 0, h: 0 };
const NPTS = 5;
function openPalEditor(p) {
  Object.assign(ED, { id: p ? p.id : "", img: null, newImage: null, points: p ? p.points.slice() : [], colors: p ? p.colors.slice() : [] });
  $("#palTitle").textContent = p ? "Modifier la palette" : "Nouvelle palette";
  $("#palName").value = p ? p.name : "";
  $("#palDelete").classList.toggle("hidden", !p);
  $("#palPhoto").classList.toggle("hidden", !p);
  openSheet("#palSheet");
  if (p) loadImage(`/palettes/${p.id}.jpg?v=${p.updated || Date.now()}`, false);
  else { renderPicker(); }
}
function loadImage(src, fresh) {
  const im = new Image();
  im.onload = () => {
    const max = 900, k = Math.min(1, max / Math.max(im.width, im.height));
    const c = document.createElement("canvas");
    c.width = Math.round(im.width * k); c.height = Math.round(im.height * k);
    const ctx = c.getContext("2d", { willReadFrequently: true });
    ctx.drawImage(im, 0, 0, c.width, c.height);
    Object.assign(ED, { ctx, w: c.width, h: c.height, img: c.toDataURL("image/jpeg", 0.85) });
    if (fresh) { ED.newImage = ED.img; ED.points = extractPoints(ctx, c.width, c.height); }
    ED.colors = ED.points.map(pt => sampleAt(pt[0], pt[1]));
    renderPicker();
  };
  im.onerror = () => toast("Image illisible");
  im.src = src;
}
$("#palFile").onchange = e => {
  const f = e.target.files[0]; if (!f) return;
  const r = new FileReader();
  r.onload = () => { loadImage(r.result, true); $("#palPhoto").classList.remove("hidden"); if (!$("#palName").value) $("#palName").value = "Ma palette"; };
  r.readAsDataURL(f); e.target.value = "";
};
$("#palPhoto").onclick = () => $("#palFile").click();

function sampleAt(x, y) {
  const px = Math.round(x * (ED.w - 1)), py = Math.round(y * (ED.h - 1)), r = 3;
  const d = ED.ctx.getImageData(Math.max(0, px - r), Math.max(0, py - r), r * 2 + 1, r * 2 + 1).data;
  let R = 0, G = 0, B = 0, n = 0;
  for (let i = 0; i < d.length; i += 4) { R += d[i]; G += d[i + 1]; B += d[i + 2]; n++; }
  const h = v => Math.round(v / n).toString(16).padStart(2, "0");
  return "#" + h(R) + h(G) + h(B);
}
// k-means sur un échantillon de pixels : on garde les couleurs vives, comme l'app Hue
function extractPoints(ctx, w, h) {
  const step = Math.max(1, Math.floor(Math.sqrt(w * h / 5000)));
  const d = ctx.getImageData(0, 0, w, h).data, px = [];
  for (let y = 0; y < h; y += step) for (let x = 0; x < w; x += step) {
    const i = (y * w + x) * 4, r = d[i], g = d[i + 1], b = d[i + 2];
    const mx = Math.max(r, g, b), mn = Math.min(r, g, b);
    px.push([r, g, b, x / (w - 1), y / (h - 1), mx / 255, mx ? (mx - mn) / mx : 0]);
  }
  let pool = px.filter(p => p[5] > 0.15 && p[6] > 0.18);
  if (pool.length < NPTS * 10) pool = px.filter(p => p[5] > 0.08);
  if (pool.length < NPTS) pool = px;
  const dist = (a, b) => (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2;
  // initialisation : la couleur la plus vive, puis les plus éloignées
  const centers = [pool.reduce((a, b) => (b[5] * b[6] > a[5] * a[6] ? b : a)).slice(0, 3)];
  while (centers.length < NPTS) {
    let best = null, bd = -1;
    for (const p of pool) { const dd = Math.min(...centers.map(c => dist(p, c))); if (dd > bd) { bd = dd; best = p; } }
    centers.push(best.slice(0, 3));
  }
  for (let it = 0; it < 10; it++) {
    const acc = centers.map(() => [0, 0, 0, 0]);
    for (const p of pool) {
      let bi = 0, bd = Infinity;
      centers.forEach((c, i) => { const dd = dist(p, c); if (dd < bd) { bd = dd; bi = i; } });
      const a = acc[bi]; a[0] += p[0]; a[1] += p[1]; a[2] += p[2]; a[3]++;
    }
    acc.forEach((a, i) => { if (a[3]) centers[i] = [a[0] / a[3], a[1] / a[3], a[2] / a[3]]; });
  }
  // place chaque pastille sur le pixel le plus proche de sa couleur, sans superposition
  const pts = [];
  for (const c of centers) {
    let best = pool[0], bd = Infinity;
    for (const p of pool) {
      if (p[3] < 0.04 || p[3] > 0.96 || p[4] < 0.04 || p[4] > 0.96) continue;
      if (pts.some(q => (q[0] - p[3]) ** 2 + (q[1] - p[4]) ** 2 < 0.02)) continue;
      const dd = dist(p, c); if (dd < bd) { bd = dd; best = p; }
    }
    pts.push([best[3], best[4]]);
  }
  return pts;
}
function renderPicker() {
  const area = $("#pickArea");
  if (!ED.img) {
    area.innerHTML = `<button class="pick-empty" id="pickEmpty"><div><svg width="44" height="44" viewBox="0 0 24 24" fill="none" stroke="#8e8e93" stroke-width="1.6"><rect x="3" y="5" width="18" height="14" rx="3"/><circle cx="9" cy="10" r="2"/><path d="M21 16l-5-5-8 8"/></svg>
      <b>Choisir une photo</b>Les couleurs seront extraites automatiquement</div></button>`;
    $("#pickEmpty").onclick = () => $("#palFile").click();
    $("#palSwatches").innerHTML = ""; return;
  }
  const maxW = area.clientWidth || 340, maxH = Math.min(window.innerHeight * 0.45, 420);
  const k = Math.min(maxW / ED.w, maxH / ED.h);
  const W = Math.round(ED.w * k), H = Math.round(ED.h * k);
  area.innerHTML = `<div class="pick-wrap" id="pickWrap" style="width:${W}px;height:${H}px"><img src="${ED.img}" alt="">${
    ED.points.map((p, i) => `<div class="pt" data-i="${i}" style="left:${p[0] * 100}%;top:${p[1] * 100}%;background:${ED.colors[i]}"></div>`).join("")}</div>`;
  $("#palSwatches").innerHTML = ED.colors.map(c => `<span style="background:${c}"></span>`).join("");
  const wrap = $("#pickWrap");
  wrap.querySelectorAll(".pt").forEach(el => {
    const i = +el.dataset.i;
    const move = e => {
      const r = wrap.getBoundingClientRect();
      const x = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)), y = Math.max(0, Math.min(1, (e.clientY - r.top) / r.height));
      ED.points[i] = [x, y]; ED.colors[i] = sampleAt(x, y);
      el.style.left = x * 100 + "%"; el.style.top = y * 100 + "%"; el.style.background = ED.colors[i];
      $("#palSwatches").children[i].style.background = ED.colors[i];
    };
    el.addEventListener("pointerdown", e => { e.preventDefault(); el.setPointerCapture(e.pointerId); el.classList.add("drag"); });
    el.addEventListener("pointermove", e => el.classList.contains("drag") && move(e));
    const end = () => el.classList.remove("drag");
    el.addEventListener("pointerup", end); el.addEventListener("pointercancel", end);
  });
}
$("#palSave").onclick = async () => {
  if (!ED.img) return toast("Choisis d'abord une photo");
  $("#palSave").disabled = true;
  try {
    const body = { id: ED.id || undefined, name: $("#palName").value.trim() || "Ma palette", colors: ED.colors, points: ED.points };
    if (ED.newImage) body.image = ED.newImage;
    const p = await api("/api/palettes", body);
    closeSheets(); toast("Palette enregistrée");
    S.settings.palette = p.id; save({ palette: p.id }, true);
    lockUntil = 0; setTimeout(refresh, 400);
  } catch (e) { toast("Échec : " + e.message); }
  $("#palSave").disabled = false;
};
$("#palDelete").onclick = async () => {
  if (!confirm("Supprimer cette palette ?")) return;
  try { await api("/api/palettes/delete", { id: ED.id }); closeSheets(); toast("Palette supprimée"); lockUntil = 0; refresh(); }
  catch (e) { toast("Échec : " + e.message); }
};

/* ---------- Bluetooth ---------- */
let BT = null, btTimer = null;
const SPEAKER = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round"><rect x="5" y="2" width="14" height="20" rx="3"/><circle cx="12" cy="14" r="4"/><circle cx="12" cy="6.5" r="1"/></svg>';
async function loadBt() {
  clearTimeout(btTimer);
  try { BT = await api("/api/bt"); renderBt(); } catch (e) { $("#bt").innerHTML = `<div class="empty">${esc(e.message)}</div>`; }
  btTimer = setTimeout(loadBt, BT && (BT.scanning || BT.busy) ? 1000 : 4000);
}
function renderBt() {
  const g = $("#bt");
  $("#btMsg").textContent = BT.message || "";
  if (!BT.available) {
    g.innerHTML = `<div class="empty">${esc(BT.reason || "Aucun adaptateur Bluetooth détecté. Vérifie le passthrough USB de la VM dans Proxmox.")}</div>`;
    $("#btOffset").classList.add("hidden"); return;
  }
  const list = BT.devices.filter(d => d.audio || d.paired || d.connected || d.mac === BT.selected);
  const rows = list.map(d => {
    const sel = d.mac === BT.selected;
    const playing = sel && live.bt && live.bt.playing;
    const busy = BT.busy === d.mac;
    const sub = busy ? "Connexion…" : d.connected ? (playing ? "Connectée · lecture en cours" : "Connectée") : sel ? "Reconnexion automatique…" : d.paired ? "Appairée" : "Disponible";
    const actions = busy ? '<span class="spin"></span>'
      : sel ? `<button class="bt-btn danger" data-act="disconnect" data-mac="${d.mac}">Déconnecter</button>`
      : `<button class="bt-btn" data-act="connect" data-mac="${d.mac}">Connecter</button>` +
        (d.paired ? `<button class="bt-btn danger" data-act="forget" data-mac="${d.mac}" aria-label="Oublier">✕</button>` : "");
    return `<div class="row"><div class="bt-ico ${d.connected && sel ? "on" : ""}">${SPEAKER}</div>
      <div class="main"><div class="t">${esc(d.name)}</div><div class="s">${sub}</div></div>${actions}</div>`;
  }).join("");
  const empty = !list.length ? `<div class="empty">${BT.scanning ? "Recherche en cours…" : "Aucune enceinte. Mets-la en mode appairage puis lance une recherche."}</div>` : "";
  g.innerHTML = empty + rows + `<button class="row scan-row" id="btScan" ${BT.scanning ? "disabled" : ""}>${BT.scanning ? '<span class="spin"></span>Recherche…' : "Rechercher des enceintes"}</button>`;
  g.querySelectorAll("[data-act]").forEach(b => b.onclick = async () => {
    const act = b.dataset.act;
    if (act === "forget" && !confirm("Oublier cette enceinte ?")) return;
    try { await api("/api/bt/" + act, { mac: b.dataset.mac }); } catch (e) { toast(e.message); }
    loadBt();
  });
  $("#btScan").onclick = async () => { await api("/api/bt/scan", {}).catch(e => toast(e.message)); loadBt(); };
  $("#btOffset").classList.toggle("hidden", !BT.selected);
}

/* ---------- Actions ---------- */
$("#power").onchange = async e => {
  const on = e.target.checked; lockUntil = Date.now() + 4000;
  try { await api("/api/power", { on }); toast(on ? "Synchro activée" : "Synchro désactivée"); }
  catch (err) { toast("Échec : " + err.message); e.target.checked = !on; }
  refresh();
};
$("#apName").addEventListener("change", e => { save({ airplay_name: e.target.value.trim() || "Hue Sync" }, true); toast("Nom AirPlay mis à jour"); });
$("#apName").addEventListener("keydown", e => e.key === "Enter" && e.target.blur());
$("#idle").onchange = e => save({ idle_release: +e.target.value }, true);

function openSheet(id) { $("#sheetBg").classList.add("open"); $(id).classList.add("open"); }
function closeSheets() { $("#sheetBg").classList.remove("open"); document.querySelectorAll(".sheet").forEach(s => s.classList.remove("open")); }
$("#sheetBg").onclick = closeSheets;
document.querySelectorAll("[data-close]").forEach(b => b.onclick = closeSheets);

let pickedBridge = "", bridges = [];
function openPair() {
  $("#pairForm").classList.remove("hidden"); $("#pairWait").classList.add("hidden");
  $("#manualBox").classList.add("hidden"); $("#bridgeIp").value = "";
  openSheet("#pairSheet"); discover();
}
async function discover() {
  pickedBridge = ""; bridges = []; renderBridges(true);
  try { bridges = (await api("/api/discover")).bridges; } catch (e) { bridges = []; }
  if (bridges.length === 1) pickedBridge = bridges[0].ip;
  else if (S.bridge && bridges.some(b => b.ip === S.bridge)) pickedBridge = S.bridge;
  renderBridges(false);
}
function renderBridges(searching) {
  const manual = !$("#manualBox").classList.contains("hidden");
  $("#discMsg").textContent = searching ? "Recherche des ponts Hue sur ton réseau…"
    : bridges.length ? (bridges.length > 1 ? "Choisis ton pont :" : "Pont trouvé. Appuie sur Continuer.")
    : "Aucun pont trouvé automatiquement. Vérifie qu'il est allumé et sur le même réseau, ou saisis son adresse IP.";
  const rows = searching ? '<div class="row"><span class="spin"></span><div class="main"><div class="t">Recherche…</div></div></div>'
    : bridges.map(b => `<button class="row" data-ip="${esc(b.ip)}">
        <div class="zone-ico"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.7"><rect x="3" y="7" width="18" height="10" rx="5"/><circle cx="12" cy="12" r="2"/></svg></div>
        <div class="main"><div class="t">${esc(b.name)}</div><div class="s">${esc(b.ip)}${b.model ? " · " + esc(b.model) : ""}</div></div>
        <span class="check">${pickedBridge === b.ip && !manual ? "✓" : ""}</span></button>`).join("");
  $("#bridgeList").innerHTML = rows + (searching ? "" :
    `<button class="row scan-row" id="discAgain">Rechercher à nouveau</button>
     <button class="row" id="manualToggle"><div class="main"><div class="t" style="color:#64d2ff">${manual ? "Utiliser la recherche automatique" : "Saisir l'adresse IP"}</div></div></button>`);
  $("#bridgeList").querySelectorAll("[data-ip]").forEach(r => r.onclick = () => { pickedBridge = r.dataset.ip; $("#manualBox").classList.add("hidden"); renderBridges(false); });
  if (!searching) {
    $("#discAgain").onclick = discover;
    $("#manualToggle").onclick = () => { $("#manualBox").classList.toggle("hidden"); if (!$("#manualBox").classList.contains("hidden")) $("#bridgeIp").focus(); renderBridges(false); };
  }
  updatePairBtn();
}
function updatePairBtn() {
  const manual = !$("#manualBox").classList.contains("hidden");
  $("#pairGo").disabled = manual ? !/^\d{1,3}(\.\d{1,3}){3}(:\d+)?$/.test($("#bridgeIp").value.trim()) : !pickedBridge;
}
$("#bridgeIp").addEventListener("input", updatePairBtn);
$("#bridgeRow").onclick = openPair;
$("#welcomePair").onclick = openPair;
$("#pairGo").onclick = async () => {
  $("#pairForm").classList.add("hidden"); $("#pairWait").classList.remove("hidden");
  $("#pairMsg").textContent = "Le gros bouton rond sur le dessus du pont Hue.";
  let n = 30; $("#pairCount").textContent = n;
  const tick = setInterval(() => { n = Math.max(0, n - 1); $("#pairCount").textContent = n; }, 1000);
  const manual = !$("#manualBox").classList.contains("hidden");
  try { await api("/api/pair", { bridge: manual ? $("#bridgeIp").value.trim() : pickedBridge }); } catch (e) { $("#pairMsg").textContent = e.message; }
  const poll = setInterval(async () => {
    const st = await api("/api/state").catch(() => null);
    if (!st || st.pairing.state === "waiting") return;
    clearInterval(poll); clearInterval(tick);
    if (st.pairing.state === "ok") { closeSheets(); toast(st.pairing.message); zones = null; S = st; refresh(true); }
    else { $("#pairMsg").textContent = st.pairing.message; $("#pairCount").textContent = "!"; }
  }, 1000);
};

$("#logsBtn").onclick = async () => {
  openSheet("#logSheet"); $("#logs").textContent = "Chargement…";
  try { const j = await api("/api/logs"); $("#logs").textContent = j.lines || "(vide)"; $("#logs").scrollTop = 1e9; }
  catch (e) { $("#logs").textContent = e.message; }
};

/* ---------- Boucles de rafraîchissement ---------- */
let staticDone = false;
async function refresh(forceZones) {
  try {
    const st = await api("/api/state");
    if (Date.now() < lockUntil && S) st.settings = S.settings;  // garde la valeur en cours d'édition
    S = st; live = st.live;
  } catch (e) { $("#statusText").textContent = "Interface injoignable"; $("#dot").className = "dot"; return; }
  $("#welcome").classList.toggle("hidden", S.paired);
  $("#app").classList.toggle("hidden", !S.paired);
  if (!staticDone) { renderStatic(); staticDone = true; }
  if (S.paired && (zones === null || forceZones)) {
    api("/api/areas" + (forceZones ? "?refresh" : "")).then(z => { zones = z; renderZones(); renderStatus(); })
      .catch(e => { zones = { error: e.message }; renderZones(); });
  }
  renderPalettes(); renderSettings(); renderStatus(); renderLive();
}
async function liveLoop() {
  if (!document.hidden && S && S.service.active) {
    try { live = await api("/api/live"); renderLive(); renderStatus(); } catch (e) {}
  }
  setTimeout(liveLoop, 120);
}
refresh(); setInterval(() => !document.hidden && refresh(), 3000); liveLoop(); loadBt();
document.addEventListener("visibilitychange", () => !document.hidden && refresh());
window.addEventListener("resize", () => S && renderSettings());
</script>
</body>
</html>
HUE_FILE_EOF
cp /etc/shairport-sync.conf /opt/hue-music-sync/backup-$STAMP/ 2>/dev/null || true
cp /etc/systemd/system/hue-airplay.service /opt/hue-music-sync/backup-$STAMP/ 2>/dev/null || true
cat > /etc/shairport-sync.conf <<'HUE_FILE_EOF'
// Récepteur AirPlay 2 "Hue Sync" : le son n'est pas joué, il est envoyé
// au script sur STDOUT (44,1 kHz, 16 bits, stéréo), qui l'analyse et peut le
// rejouer sur une enceinte Bluetooth.
general =
{
  name = "Hue Sync";               // nom visible dans le menu AirPlay de l'iPhone
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
apt-get install -y --no-install-recommends avahi-utils rfkill usbutils >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl restart hue-sync-web hue-airplay
echo "Mise à jour terminée (ancienne version sauvegardée dans /opt/hue-music-sync/backup-$STAMP)."
