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
import base64
import collections
import hashlib
import hmac
import http.client
import json
import math
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
    "subtle":   dict(base=0.15, beat=0.10, tau=0.70, energy=0.25, every=4, fade=1.60,
                     pattern="all", strobe=False, beat_k=2.0, min_beat=0.40, source="full"),
    "moderate": dict(base=0.18, beat=0.45, tau=0.32, energy=0.18, every=2, fade=0.50,
                     pattern="all", strobe=False, beat_k=1.7, min_beat=0.28, source="full"),
    "high":     dict(base=0.06, beat=0.75, tau=0.20, energy=0.12, every=1, fade=0.15,
                     pattern="alt", strobe=False, beat_k=1.5, min_beat=0.26, source="full"),
    "intense":  dict(base=0.00, beat=0.90, tau=0.12, energy=0.05, every=1, fade=0.00,
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

    def acquire(self, why="Musique détectée"):
        if self.active or time.time() < self.retry_at:
            return
        try:
            if self.dry_run:
                self.stream = DryRunStream()
            else:
                self._action("start")
                self.stream = HueStream(self.cfg["bridge"], self.cfg["app_id"],
                                        self.cfg["clientkey"], self.area["id"])
            log(f"{why} : synchro démarrée.")
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
# Téléviseur Philips Ambilight (API JointSpace v6, TV Android : HTTPS port 1926)
# ---------------------------------------------------------------------------
TV_FILE = "tv.json"                       # identifiants d'appairage, écrits par l'interface web
TV_SHARED_KEY = base64.b64decode(         # clé publique commune utilisée par les TV Philips pour
    "ZmVay1EQVFOaZhwQ4Kv81ypLAZNczV9sG4KkseXWn1NEk6cXmPKO/MCa9sryslvLCFMnNe4Z4CPXzToowvhHvA==")  # signer le PIN


class TvError(Exception):
    pass


class TvClient:
    """Client minimal JointSpace v6. Une seule connexion HTTPS gardée ouverte et un défi Digest
    réutilisé : un appel = une requête, parce que la TV supporte mal les rafales d'appels."""

    def __init__(self, ip, user="", key="", timeout=2.0, port=1926):
        self.ip, self.user, self.key, self.timeout, self.port = ip, user, key, timeout, port
        self.conn, self.chal, self.nc = None, None, 0
        self.ctx = ssl.create_default_context()
        self.ctx.check_hostname = False           # certificat auto-signé de la TV
        self.ctx.verify_mode = ssl.CERT_NONE

    def close(self):
        if self.conn:
            try:
                self.conn.close()
            except Exception:
                pass
        self.conn = None

    @staticmethod
    def _parse_chal(h):
        if not h or not h.lower().startswith("digest"):
            return None
        import re as _re
        return {m[0].lower(): m[1] or m[2] for m in _re.findall(r'(\w+)=(?:"([^"]*)"|([^,\s]*))', h[6:])}

    def _auth(self, method, path):
        c = self.chal
        if not c or not self.user:
            return None
        md5 = lambda t: hashlib.md5(t.encode()).hexdigest()
        self.nc += 1
        nc, cnonce = "%08x" % self.nc, os.urandom(8).hex()
        ha1 = md5(f"{self.user}:{c.get('realm', '')}:{self.key}")
        ha2 = md5(f"{method}:{path}")
        qop = "auth" if "auth" in [q.strip() for q in c.get("qop", "").split(",")] else ""
        resp = md5(f"{ha1}:{c.get('nonce', '')}:{nc}:{cnonce}:{qop}:{ha2}") if qop else md5(f"{ha1}:{c.get('nonce', '')}:{ha2}")
        parts = [f'username="{self.user}"', f'realm="{c.get("realm", "")}"', f'nonce="{c.get("nonce", "")}"',
                 f'uri="{path}"', f'response="{resp}"', "algorithm=MD5"]
        if c.get("opaque"):
            parts.append(f'opaque="{c["opaque"]}"')
        if qop:
            parts += [f"qop={qop}", f"nc={nc}", f'cnonce="{cnonce}"']
        return "Digest " + ", ".join(parts)

    def request(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        sent_auth = False
        for attempt in range(4):
            if self.conn is None:
                self.conn = http.client.HTTPSConnection(self.ip, self.port, timeout=self.timeout, context=self.ctx)
            headers = {"Content-Type": "application/json"} if data is not None else {}
            a = self._auth(method, path)
            if a:
                headers["Authorization"] = a
            try:
                self.conn.request(method, path, body=data, headers=headers)
                r = self.conn.getresponse()
                raw = r.read()
            except (OSError, http.client.HTTPException) as e:
                self.close()
                if attempt >= 1:
                    raise TvError(f"TV injoignable ({e.__class__.__name__}).")
                continue
            if r.status == 401 and self.user:
                ch = self._parse_chal(r.getheader("WWW-Authenticate"))
                if not ch:
                    raise TvError("La TV refuse la connexion.")
                if a and sent_auth and ch.get("stale", "").lower() != "true":
                    raise TvError("La TV ne reconnaît plus Lueur : refais l'appairage.")
                sent_auth = bool(a) or sent_auth
                self.chal, self.nc = ch, 0
                continue
            if r.status >= 400:
                raise TvError(f"La TV a répondu {r.status} sur {path}.")
            try:
                return json.loads(raw or b"{}")
            except ValueError:
                return {}
        raise TvError("La TV ne reconnaît plus Lueur : refais l'appairage.")


def tv_device(dev_id):
    return {"device_name": "Lueur", "device_os": "Android", "app_name": "Lueur", "type": "native",
            "app_id": "app.lueur", "id": dev_id}


def tv_pair_request(ip):
    """1re étape : la TV affiche un code PIN. Renvoie l'état à garder pour tv_pair_grant()."""
    dev_id = "".join(chr(97 + b % 26) for b in os.urandom(16))
    r = TvClient(ip, timeout=5).request("POST", "/6/pair/request",
                                        {"scope": ["read", "write", "control"], "device": tv_device(dev_id)})
    if r.get("error_id") != "SUCCESS" or not r.get("auth_key"):
        raise TvError("La TV refuse l'appairage : " + str(r.get("error_text") or r.get("error_id") or r)[:160])
    return {"ip": ip, "id": dev_id, "auth_key": r["auth_key"], "timestamp": r.get("timestamp"),
            "timeout": r.get("timeout", 60)}


def tv_pair_grant(st, pin):
    """2e étape : on renvoie le PIN signé. Deux formes de signature circulent selon les TV :
    on essaie la plus courante (hexadécimal), puis la variante en base64."""
    pin = str(pin).strip()
    h = hmac.new(TV_SHARED_KEY, (str(st["timestamp"]) + pin).encode(), hashlib.sha1).hexdigest()
    last = None
    for sig in (h, base64.b64encode(h.encode()).decode()):
        body = {"auth": {"auth_AppId": "1", "pin": pin, "auth_timestamp": st["timestamp"],
                         "auth_signature": sig}, "device": tv_device(st["id"])}
        try:
            TvClient(st["ip"], st["id"], st["auth_key"], timeout=5).request("POST", "/6/pair/grant", body)
            return {"ip": st["ip"], "user": st["id"], "key": st["auth_key"]}
        except TvError as e:
            last = e
    raise last or TvError("Appairage refusé.")


def tv_frame(js):
    """Couleurs Ambilight (`/6/ambilight/processed`) -> {côté: tableau N×3 dans [0, 1]}."""
    layer = js.get("layer1") if isinstance(js, dict) else None
    if not isinstance(layer, dict):
        layer = next((v for v in (js or {}).values() if isinstance(v, dict)), {}) if isinstance(js, dict) else {}
    out = {}
    for side in ("left", "top", "right", "bottom"):
        d = layer.get(side) or {}
        px = [d[k] for k in sorted(d, key=lambda k: int(k) if str(k).isdigit() else 0)] if isinstance(d, dict) else []
        out[side] = np.array([[p.get("r", 0), p.get("g", 0), p.get("b", 0)] for p in px if isinstance(p, dict)],
                             dtype=float).reshape(-1, 3) / 255.0
    return out


TV_SOURCES = ("processed", "measured")     # couleurs calculées par l'Ambilight, ou mesurées sur l'image
TV_GAIN = {"processed": 1.0, "measured": 1.3}   # « measured » plafonne vers 190/255 : on le remonte


def tv_black(fr):
    """Vrai si tous les pixels de l'Ambilight sont (presque) noirs."""
    return all(not len(a) or float(a.max()) < 0.02 for a in fr.values())


def tv_read(client, src):
    """Lit les couleurs de l'Ambilight. Sur certaines TV (ex. 55OLED707), « processed » reste
    toujours à zéro et seule « measured » porte les couleurs de l'image : si « processed » est
    noire, on essaie « measured », et on garde celle qui a des couleurs pour la suite.
    Renvoie (image, source utilisée)."""
    fr = tv_frame(client.request("GET", f"/6/ambilight/{src}"))
    if src == "processed" and tv_black(fr):        # une fois sur « measured », on y reste (pas d'appel en double
        fr2 = tv_frame(client.request("GET", "/6/ambilight/measured"))   # pendant les scènes noires)
        if not tv_black(fr2):
            fr, src = fr2, "measured"
    g = TV_GAIN.get(src, 1.0)
    if g != 1.0:
        fr = {k: np.clip(v * g, 0, 1) for k, v in fr.items()}
    return fr, src


def tv_amb_apply(client, amb):
    """Ambilight comme une lampe : couleur fixe (`amb` = {on, color, bri}), ou une couleur par pixel
    (`amb["pix"]` = {left, top, right}, vu de face : gauche de bas en haut, haut de gauche à droite,
    droite de haut en bas), ou éteint. `amb["flip"]` : même inversion gauche/droite que la synchro vidéo."""
    if amb and amb.get("on"):
        k = max(1, min(100, int(amb.get("bri") or 80))) / 100

        def rgb(h):
            h = str(h or amb.get("color") or "#ffb36b").lstrip("#")
            try:
                return {c: int(int(h[i:i + 2], 16) * k) for c, i in zip("rgb", (0, 2, 4))}
            except ValueError:
                return {"r": 0, "g": 0, "b": 0}

        client.request("POST", "/6/ambilight/power", {"power": "On"})
        client.request("POST", "/6/ambilight/mode", {"current": "manual"})
        pix = amb.get("pix") if isinstance(amb.get("pix"), dict) else None
        if pix:
            left, top, right = (list(pix.get(s) or []) for s in ("left", "top", "right"))
            # la TV numérote ses pixels dans le sens des aiguilles d'une montre, vu de face, comme `pix`
            if amb.get("flip"):          # TV vue en miroir : gauche ↔ droite, chaque côté retourné
                left, right, top = right[::-1], left[::-1], top[::-1]
            layer = {}
            for side, cols in (("left", left), ("top", top), ("right", right)):
                if cols:
                    layer[side] = {str(i): rgb(c) for i, c in enumerate(cols)}
            client.request("POST", "/6/ambilight/cached", {"layer1": layer})
        else:
            client.request("POST", "/6/ambilight/cached", rgb(amb.get("color")))
    else:
        client.request("POST", "/6/ambilight/mode", {"current": "internal"})
        client.request("POST", "/6/ambilight/power", {"power": "Off"})


def tv_load(conf_dir):
    try:
        with open(os.path.join(conf_dir, TV_FILE)) as f:
            d = json.load(f)
        return d if d.get("ip") and d.get("user") and d.get("key") else None
    except (OSError, ValueError, AttributeError, TypeError):
        return None


class TvWatcher:
    """Dialogue avec la TV dans son propre fil (une seule connexion, l'API supporte mal les rafales) :
    - TV allumée et synchro vidéo active : lit en continu les couleurs de l'Ambilight ;
    - TV en veille et musique en cours : envoie à l'Ambilight les couleurs de la synchro musique
      (chaque côté prend la couleur des lampes voisines sur le plan), puis lui rend son état d'avant."""

    AMBI_HZ = 20                         # envois par seconde vers l'Ambilight (mesuré : ~50/s possibles)
    AMBI_KEEP = 2.0                      # renvoi des mêmes couleurs au moins toutes les 2 s (la TV sait qu'on est là)
    AMBI_POWER_EVERY = 10.0              # pendant la musique, l'état de la TV n'est relu que toutes les 10 s
    AMBI_RETRIES = 6                     # coupures de connexion tolérées d'affilée avant d'abandonner
    AMBI_FLAG = ".ambilight-musique"     # présent tant que Lueur pilote l'Ambilight (restauration après un arrêt brutal)

    def __init__(self, conf_dir):
        self.conf_dir = conf_dir
        self.enabled, self.video, self.music, self.hz = False, False, False, 12
        self.lamp = {}
        self.frame, self.frame_t, self.power, self.error, self.rate = None, 0.0, None, "", 0.0
        self.src = "processed"
        self.mapper = None               # VideoMapper : positions des lampes et de la TV sur le plan
        self.pushed, self.push_t = None, 0.0
        self.ambi_on, self.ambi_prev, self.topo, self.ambi_last, self.ambi_sent = False, None, None, None, 0.0
        self.fails = 0
        self.here = True                 # la zone de synchro en cours est celle de la TV (ou TV non rattachée)
        self.lock = threading.Lock()
        threading.Thread(target=self._loop, daemon=True).start()
        threading.Thread(target=self._power_loop, daemon=True).start()

    def _power_loop(self):
        """État de la TV (allumée / veille), relu dans son propre fil avec sa propre connexion :
        une TV en veille met parfois plusieurs secondes à répondre, ça ne doit jamais bloquer
        les couleurs envoyées à l'Ambilight ni la lecture de l'image."""
        client, creds, misses = None, None, 0
        while True:
            if not self.enabled:
                if client:
                    client.close()
                client, creds, misses = None, None, 0
                time.sleep(0.5)
                continue
            c = tv_load(self.conf_dir)
            if c != creds:
                creds = c
                if client:
                    client.close()
                client = TvClient(c["ip"], c["user"], c["key"], timeout=4) if c else None
            if not client:
                time.sleep(2)
                continue
            try:
                p = client.request("GET", "/6/powerstate").get("powerstate")
                misses = 0
                if (p == "On") != (self.power == "On") or self.power is None:
                    log(f"TV : {'allumée' if p == 'On' else 'en veille' if p else 'état inconnu'}.")
                self.power = p
            except Exception:
                client.close()
                misses += 1
                if misses >= 3 and not self.ambi_on:    # vraiment injoignable (et pas en pleine musique)
                    self.power = None
            time.sleep(self.AMBI_POWER_EVERY if self.ambi_on else 3)

    def configure(self, tv):
        self.video = bool(tv.get("on"))
        self.lamp = {**tv["amb"], "flip": tv.get("flip")} if isinstance(tv.get("amb"), dict) else {}
        self.music = bool(tv.get("music", True))
        self.enabled = self.video or self.music
        try:
            self.hz = max(4, min(25, int(tv.get("hz", 12))))
        except (TypeError, ValueError):
            self.hz = 12

    @property
    def active(self):
        return self.video and self.power == "On" and time.time() - self.frame_t < 1.5

    def get(self):
        with self.lock:
            return self.frame

    def push(self, colors):
        """Couleurs de la synchro musique [(canal, r, g, b)], appelé par la boucle principale."""
        with self.lock:
            self.pushed, self.push_t = {c: (r, g, b) for c, r, g, b in colors}, time.time()

    def info(self):
        return {"on": self.video, "music": self.music, "power": self.power, "rate": round(self.rate, 1),
                "error": self.error, "active": self.active, "src": self.src, "ambi": self.ambi_on,
                "fails": self.fails, "here": self.here}

    # --- Ambilight piloté par la musique ---
    def _flag(self):
        return os.path.join(self.conf_dir, self.AMBI_FLAG) if self.conf_dir else None

    def _ambi_start(self, client):
        try:                     # déjà démarré avant une coupure de connexion : on garde l'état d'origine
            with open(self._flag()) as f:
                prev = json.load(f).get("power")
        except (OSError, ValueError, TypeError, AttributeError):
            prev = client.request("GET", "/6/ambilight/power").get("power")
            try:
                with open(self._flag(), "w") as f:
                    json.dump({"power": prev}, f)
            except (OSError, TypeError):
                pass
        self.topo = client.request("GET", "/6/ambilight/topology")
        client.request("POST", "/6/ambilight/power", {"power": "On"})
        client.request("POST", "/6/ambilight/mode", {"current": "manual"})
        self.ambi_on, self.ambi_prev, self.ambi_last = True, prev, None
        log("TV en veille : l'Ambilight suit la synchro musique.")

    def _ambi_stop(self, client, why):
        prev = self.ambi_prev
        self.ambi_on, self.ambi_last = False, None
        try:
            if (self.lamp or {}).get("on"):          # l'Ambilight était allumé comme une lampe : on remet sa couleur
                tv_amb_apply(client, self.lamp)
            else:
                client.request("POST", "/6/ambilight/mode", {"current": "internal"})
                if prev and prev != "On" and self.power != "On":
                    client.request("POST", "/6/ambilight/power", {"power": prev})
        finally:
            try:
                os.remove(self._flag())
            except (OSError, TypeError):
                pass
        log(f"Ambilight rendu à la TV ({why}).")

    def _ambi_recover(self, client):
        """Après un arrêt brutal de Lueur, l'Ambilight peut être resté sur nos couleurs : on le rend."""
        try:
            with open(self._flag()) as f:
                self.ambi_prev = json.load(f).get("power")
        except (OSError, ValueError, TypeError, AttributeError):
            return
        self._ambi_stop(client, "reprise après un arrêt de Lueur")

    def shutdown(self):
        """Arrêt du moteur : rend l'Ambilight tout de suite (sans attendre le fil)."""
        if not self.ambi_on:
            return
        c = tv_load(self.conf_dir)
        if c:
            try:
                self._ambi_stop(TvClient(c["ip"], c["user"], c["key"], timeout=2), "arrêt du moteur")
            except Exception:
                pass

    def _loop(self):
        client, creds, next_power, times = None, None, 0.0, collections.deque(maxlen=25)
        while True:
            if not self.enabled:
                if client:
                    if self.ambi_on:
                        try:
                            self._ambi_stop(client, "fonction coupée")
                        except Exception:
                            pass
                    client.close()
                    client = None
                creds = None            # à la réactivation, on relit l'appairage et on recrée la connexion
                self.power, self.frame_t, self.rate, self.error = None, 0.0, 0.0, ""
                times.clear()
                time.sleep(0.5)
                continue
            c = tv_load(self.conf_dir)
            if c != creds:
                creds = c
                if client:
                    client.close()
                client = TvClient(c["ip"], c["user"], c["key"]) if c else None
                if client:
                    try:
                        self._ambi_recover(client)
                    except Exception:
                        pass
            if not client:
                if self.error != "TV non appairée.":
                    log(f"TV : non appairée (fichier {os.path.join(self.conf_dir or '?', TV_FILE)} absent ou incomplet).")
                self.error = "TV non appairée."
                time.sleep(2)
                continue
            if self.error == "TV non appairée.":
                self.error = ""
                log("TV : appairage trouvé.")
            t0 = time.time()
            try:
                if self.power is None:          # état pas encore connu (lu par _power_loop)
                    time.sleep(0.3)
                    continue
                with self.lock:
                    pushed, push_t = self.pushed, self.push_t
                music_now = self.music and pushed is not None and t0 - push_t < 1.5
                if self.power != "On":
                    self.error = ""
                    if music_now and self.power:            # TV en veille et musique : l'Ambilight suit
                        if not self.ambi_on:
                            self._ambi_start(client)
                        body = self.mapper.ambi(pushed, self.topo) if self.mapper else None
                        if body and (body != self.ambi_last or t0 - self.ambi_sent > self.AMBI_KEEP):
                            client.request("POST", "/6/ambilight/cached", body)
                            self.ambi_last, self.ambi_sent = body, t0
                        if self.fails:
                            log(f"TV : connexion rétablie après {self.fails} coupure(s).")
                            self.fails = 0
                        time.sleep(max(0.0, 1.0 / self.AMBI_HZ - (time.time() - t0)))
                        continue
                    if self.ambi_on:
                        self._ambi_stop(client, "fin de la musique")
                    time.sleep(0.25 if self.music else 1)
                    continue
                if self.ambi_on:                             # la TV vient d'être allumée
                    self._ambi_stop(client, "TV allumée")
                if not self.video:
                    time.sleep(1)
                    continue
                fr, src = tv_read(client, self.src)
                if src != self.src:
                    log(f"TV : couleurs lues dans « {src} » (« {self.src} » reste noir sur cette TV).")
                    self.src = src
                with self.lock:
                    self.frame, self.frame_t = fr, time.time()
                times.append(self.frame_t)
                if len(times) > 2:
                    self.rate = (len(times) - 1) / max(1e-3, times[-1] - times[0])
                self.error = ""
            except TvError as e:
                client.close()
                if self.ambi_on and self.fails < self.AMBI_RETRIES:
                    self.fails += 1          # coupure passagère pendant la musique : on reconnecte tout de suite,
                    if self.fails == 1:      # l'Ambilight garde ses couleurs et rien n'est redémarré
                        log(f"TV : coupure de connexion pendant la musique ({e}), reconnexion…")
                    time.sleep(0.2 * self.fails)
                    continue
                if str(e) != self.error:
                    log(f"TV : {e}")
                self.error = str(e)
                self.ambi_on, self.fails = False, 0   # connexion perdue ; le drapeau permettra de rendre l'Ambilight
                time.sleep(3)
                continue
            except Exception as e:                  # réponse inattendue : on le note et on réessaie,
                msg = f"Réponse inattendue de la TV ({e.__class__.__name__} : {str(e)[:120]})."   # le fil ne doit jamais s'arrêter
                if msg != self.error:
                    log(f"TV : {msg}")
                self.error = msg
                self.ambi_on = False
                client.close()
                time.sleep(3)
                continue
            time.sleep(max(0.0, 1.0 / self.hz - (time.time() - t0)))


def _smooth(a, b, x):
    t = max(0.0, min(1.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)


class VideoMapper:
    """Couleurs de l'Ambilight -> canaux de la zone, d'après le plan de la pièce.
    Le haut du plan est le mur de la TV. Ce qui est au-dessus de la TV prend la couleur du haut
    de l'Ambilight à la même position ; ce qui est à gauche ou à droite prend celle du côté ;
    plus on s'éloigne de la TV, plus la lumière baisse et tend vers la moyenne de l'image."""

    SMOOTH = {"vive": 0.05, "normale": 0.14, "douce": 0.35}

    def __init__(self):
        self.map, self.cur, self.flip, self.tau = [], {}, False, 0.14
        self.pos, self.geo = {}, (0.5, 0.15, 4.0, 4.0)   # positions des lampes ; TV (centre, demi-largeur 0-1, W, D)

    def configure(self, channels, kinds, plans, area_id, tv):
        plan = (plans or {}).get(area_id) if isinstance(plans, dict) else None
        plan = plan if isinstance(plan, dict) else {}
        dims = plan.get("dims") if isinstance(plan.get("dims"), dict) else {}
        num = lambda v, d, lo, hi: max(lo, min(hi, float(v))) if isinstance(v, (int, float)) else d
        try:
            W = max(1.0, float(dims.get("w") or 4.0))
            D = max(1.0, float(dims.get("d") or W))
        except (TypeError, ValueError):
            W = D = 4.0
        xc, hw = num(tv.get("x"), 0.5, 0.0, 1.0), num(tv.get("w"), 1.23, 0.3, 4.0) / 2
        back, spots = num(tv.get("back"), 0.35, 0.0, 1.0), num(tv.get("spots"), 0.3, 0.0, 1.0)
        self.flip = bool(tv.get("flip"))
        self.tau = self.SMOOTH.get(tv.get("smooth"), 0.14)
        self.map, self.pos = [], {}
        self.geo = (xc, hw / W, W, D)
        for c in channels:
            p = c.get("position", {})
            # Plan Lueur comme repères du pont : x et y de -1 à 1, y = +1 du côté de la TV.
            # « sx » est la vraie position gauche-droite (« x » sert à l'ordre de parcours).
            x = float(p["sx"]) if "sx" in p else float(p.get("x", 0))
            u, v = (x + 1) / 2, (1 - float(p.get("y", 0))) / 2   # u : 0 à gauche, 1 à droite ; v : 0 au mur de la TV
            du = (u - xc) * W
            if abs(du) <= hw:
                spec = ("top", (du / hw + 1) / 2, 0.0)
            else:
                spec = ("left" if du < 0 else "right", 0.0, min(1.0, (abs(du) - hw) / 0.6))
            self.pos[c["channel_id"]] = (u, v, kinds.get(c["channel_id"]))
            bri = 1 - (1 - back) * _smooth(0.1, 0.9, v)
            if kinds.get(c["channel_id"]) == "spots":
                bri *= spots
            self.map.append((c["channel_id"], spec, 0.5 * _smooth(0.4, 1.0, v), bri))
        self.cur = {k: v for k, v in self.cur.items() if any(m[0] == k for m in self.map)}

    def colors(self, frame, brightness, dt):
        top, left, right = frame.get("top"), frame.get("left"), frame.get("right")
        if self.flip:
            left, right, top = right, left, top[::-1]
        parts = [a for a in (left, top, right) if len(a)]
        avg = np.concatenate(parts).mean(0) if parts else np.zeros(3)
        L = left.mean(0) if len(left) else (top[0] if len(top) else avg)
        R = right.mean(0) if len(right) else (top[-1] if len(top) else avg)
        cl = top[0] if len(top) else L
        cr = top[-1] if len(top) else R
        n = len(top)
        k = 1 - math.exp(-max(0.0, dt) / self.tau)
        out = []
        for cid, (side, t, f), bb, bri in self.map:
            if side == "top":
                if n:
                    i, w = t * (n - 1), max(1.0, n * 0.06)
                    c = top[max(0, int(i - w)):min(n, int(i + w) + 1)].mean(0)
                else:
                    c = avg
            elif side == "left":
                c = cl * (1 - f) + L * f
            else:
                c = cr * (1 - f) + R * f
            c = (c * (1 - bb) + avg * bb) * bri * brightness
            prev = self.cur.get(cid)
            if prev is not None:
                c = prev + (c - prev) * k
            self.cur[cid] = c
            out.append((cid, float(c[0]), float(c[1]), float(c[2])))
        return out

    def ambi(self, colors, topo):
        """Couleurs à envoyer à l'Ambilight (`/6/ambilight/cached`) pendant la musique : chaque pixel,
        placé sur le mur de la TV, prend la couleur des deux lampes les plus proches sur le plan
        (le ruban d'abord ; les spots seulement s'il n'y a pas de ruban)."""
        if not colors or not self.pos:
            return None
        xc, hu, W, D = self.geo
        lamps = [(u, v, colors[c]) for c, (u, v, k) in self.pos.items() if c in colors and k != "spots"]
        if not lamps:
            lamps = [(u, v, colors[c]) for c, (u, v, k) in self.pos.items() if c in colors]
        if not lamps:
            return None

        def at(u):
            near = sorted(((math.hypot((u - lu) * W, lv * D), col) for lu, lv, col in lamps), key=lambda x: x[0])[:2]
            ws = [1 / (d + 0.05) for d, _ in near]
            return [sum(w * col[i] for w, (_, col) in zip(ws, near)) / sum(ws) for i in range(3)]

        topo = topo if isinstance(topo, dict) else {}
        n = {k: int(topo.get(k) or 0) for k in ("left", "top", "right")}
        if not any(n.values()):
            n = {"left": 3, "top": 7, "right": 3}
        px = lambda c: {"r": int(max(0, min(1, c[0])) * 255), "g": int(max(0, min(1, c[1])) * 255),
                        "b": int(max(0, min(1, c[2])) * 255)}
        left, right = at(xc - hu), at(xc + hu)
        top = [at(xc - hu + (i + 0.5) / n["top"] * 2 * hu) for i in range(n["top"])]
        if self.flip:                    # même convention que pour la lecture des couleurs
            left, right, top = right, left, top[::-1]
        layer = {"top": {str(i): px(c) for i, c in enumerate(top)}}
        if n["left"]:
            layer["left"] = {str(i): px(left) for i in range(n["left"])}
        if n["right"]:
            layer["right"] = {str(i): px(right) for i in range(n["right"])}
        return {"layer1": layer}

    def hexes(self):
        return ["#%02x%02x%02x" % tuple(int(max(0, min(1, v)) * 255) for v in self.cur[m[0]])
                for m in self.map if m[0] in self.cur]


# ---------------------------------------------------------------------------
# Commande "run"
# ---------------------------------------------------------------------------
MODES = ("pulse", "spectrum", "glisse", "comete", "vague", "vumetre", "stereo", "etincelles", "respiration")
SPEEDS = (0.5, 1.0, 2.0)          # demi-temps, normal, double
ALONG = ("glisse", "comete", "vague", "vumetre", "etincelles", "respiration")   # effets qui suivent le ruban

SETTINGS_DEFAULTS = {"area": "", "palette": "sunset", "intensity": "high", "mode": "pulse", "speed": 1.0,
                     "layers": {}, "plans": {}, "test": {},
                     "brightness": 1.0, "idle_release": 15,
                     "bt_device": "", "bt_offset_ms": 300, "area_rev": 0, "fx": {}, "tv": {}}


def load_settings(path, args):
    """Réglages : fichier JSON (modifiable à chaud par l'interface web) sinon ligne de commande."""
    s = {"area": args.area or "", "palette": args.palette, "intensity": args.intensity,
         "mode": args.mode, "brightness": args.brightness, "idle_release": args.idle_release,
         "bt_device": "", "bt_offset_ms": 300, "area_rev": 0, "fx": {}, "speed": 1.0, "layers": {}, "plans": {}, "test": {},
         "tv": {}}
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
    if not isinstance(s.get("tv"), dict):
        s["tv"] = {}
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
    conf_dir = os.path.dirname(args.settings) if args.settings else None
    tv = TvWatcher(conf_dir) if conf_dir and not args.dry_run else None
    vmap = VideoMapper()
    if tv:
        tv.mapper = vmap
        tv.configure(settings["tv"])
        vmap.configure(plan_channels(area, settings["plans"]), kinds, settings["plans"], area["id"], settings["tv"])
    video_on, video_t = False, 0.0
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
                    if tv:
                        tv.configure(settings["tv"])
                        vmap.configure(plan_channels(area, settings["plans"]), kinds, settings["plans"], area["id"],
                                       settings["tv"])
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
                if test.get("mode") == "fx":
                    # Test des réglages avancés : le moteur rejoue l'effet actuel avec un rythme
                    # simulé (120 BPM), même sans musique. Tous les curseurs (force, durée,
                    # fond, motif, couleurs, vitesse, couches, flash blanc) se voient en vrai.
                    ph = (now % 0.5) / 0.5
                    beat = ph < 0.05
                    strength = 0.9
                    sw = 0.5 + 0.5 * np.sin(2 * np.pi * now / 6.0)
                    bands = {"bass": 0.9 if beat else 0.25 + 0.2 * sw,
                             "mid": 0.5 + 0.3 * sw, "high": 0.6 if beat else 0.3,
                             "on_bass": 1.0 if beat else 0.15, "on_mid": 0.7 if beat else 0.2,
                             "on_high": 0.8 if beat else 0.25, "energy": 0.35 + 0.5 * sw,
                             "lr": 0.0}
                    colors = fx.update(0.3, bands, beat, strength)
                    eq = plan_eq(area, settings["plans"])
                    if eq:
                        colors = [(c, r * f, g * f, b * f) for c, r, g, b in colors
                                  for f in (eq.get(devs.get(c), 1.0),)]
                    session.send(colors)
                    status.write(state="syncing" if session.active else "waiting",
                                 area=area_name, area_id=area["id"], level=0.3,
                                 beats=beats, colors=fx.colors_hex() if session.active else [],
                                 source="music",
                                 tv=tv.info() if tv else None,
                                 bt={"device": player.device, "playing": player.playing} if player else None)
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
            # La TV peut être rattachée à une zone (sa pièce) : ailleurs, elle est ignorée
            if tv:
                tv_area = settings["tv"].get("area") or ""
                tv.here = not tv_area or tv_area == area["id"]
            # Synchro vidéo : la TV est allumée et aucune musique ne joue (la musique reste prioritaire)
            music = rms >= 0.001 or airplay_on
            if tv and tv.here and tv.active and not music:
                fr = tv.get()
                if fr is not None:
                    if not video_on:
                        video_on, video_t = True, now
                        session.acquire("Image de la TV reçue")
                    silent_since = now
                    colors = vmap.colors(fr, settings["brightness"], now - video_t)
                    video_t = now
                    eq = plan_eq(area, settings["plans"])
                    if eq:
                        colors = [(c, r * f, g * f, b * f) for c, r, g, b in colors
                                  for f in (eq.get(devs.get(c), 1.0),)]
                    session.send(colors)
                    status.write(state="syncing" if session.active else "waiting", source="tv",
                                 area=area_name, area_id=area["id"], level=0, beats=beats,
                                 colors=vmap.hexes() if session.active else [], tv=tv.info(),
                                 bt={"device": player.device, "playing": player.playing} if player else None)
                    continue
            if video_on:
                video_on = False
                vmap.cur.clear()
                if not music:
                    session.release("TV éteinte ou synchro vidéo coupée")
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
            if tv and tv.here and session.active:
                tv.push(colors)             # TV en veille : l'Ambilight suit la musique
            if beat:
                beats += 1
            status.write(state="syncing" if session.active else "waiting",
                         area=area_name, area_id=area["id"], level=round(float(rms), 4),
                         beats=beats, colors=fx.colors_hex() if session.active else [], source="music",
                         tv=tv.info() if tv else None,
                         bt={"device": player.device, "playing": player.playing} if player else None)
    finally:
        audio.close()
        if tv:
            tv.shutdown()
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
