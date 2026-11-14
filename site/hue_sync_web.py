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


def default_height(lamp):
    """Hauteur par défaut d'une lampe (-1 au sol, 0 au milieu, +1 au plafond) d'après son type."""
    a = ((lamp or {}).get("archetype") or "").lower()
    if any(k in a for k in ("ceiling", "recessed", "spot")):
        return 1
    if (lamp or {}).get("has_gradient"):
        return 1
    if any(k in a for k in ("play", "bloom", "go")):
        return -1
    return 0


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
            heights = {}
            for k, v in (body.get("heights") or {}).items():
                try:
                    heights[str(k)[:64]] = max(-1, min(1, int(round(float(v)))))
                except (TypeError, ValueError):
                    pass
            plans[aid] = {
                "dims": dict(zip("wd", dims_of(body.get("dims")))),
                "spots": {str(k)[:64]: [num(v[0], 0, 1), num(v[1], 0, 1)] for k, v in (body.get("spots") or {}).items()},
                "rubans": {str(d)[:64]: {"walls": int(num(r.get("walls", 1), 1, 4)), "corner": int(num(r.get("corner", 0), 0, 3)),
                                         "dir": 1 if r.get("dir", 1) >= 0 else -1}
                           for d, r in (body.get("rubans") or {}).items()},
                "heights": heights}
        s["room_plans"] = plans
        write_json(SETTINGS_PATH, s)
        rooms_cache["t"] = 0
        if not body.get("reset"):
            try:
                refresh_room_zone(aid)          # la zone de synchro de la pièce suit le nouveau plan
            except Exception as e:              # pas de zone, pont injoignable… : le plan reste enregistré
                print(f"Plan de synchro non recopié : {e}", flush=True)
        return {"ok": True}
    s = get_settings()
    plans = s.get("plans") if isinstance(s.get("plans"), dict) else {}
    old_ch = (plans.get(aid) or {}).get("ch") if isinstance(plans.get(aid), dict) else {}
    old_ch = old_ch if isinstance(old_ch, dict) else {}
    ch = {}
    for k, q in (body.get("ch") or {}).items():
        ck = str(int(k))
        zq = q.get("z", (old_ch.get(ck) or {}).get("z", 0) if isinstance(old_ch.get(ck), dict) else 0)
        ch[ck] = {"t": num(q["t"], 0, 1), "x": num(q["x"], -1, 1), "y": num(q["y"], -1, 1),
                  "z": num(zq, -1, 1)}
    rubans = {}
    for dev, r in (body.get("rubans") or {}).items():
        rubans[str(dev)[:64]] = {"walls": int(num(r.get("walls", 4), 1, 4)), "corner": int(num(r.get("corner", 0), 0, 3)),
                                 "dir": 1 if r.get("dir", 1) >= 0 else -1}
    spots = {str(k)[:64]: [num(v[0], 0, 1), num(v[1], 0, 1)] for k, v in (body.get("spots") or {}).items()}
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


def clean_tv(d):
    """Réglages de la synchro vidéo (Ambilight)."""
    out = {}
    num = lambda k, lo, hi, dflt: max(lo, min(hi, float(d[k]))) if isinstance(d.get(k), (int, float)) else dflt
    out["on"] = bool(d.get("on"))
    out["music"] = bool(d.get("music", True))             # TV en veille : l'Ambilight suit la musique
    a = str(d.get("area") or "")
    out["area"] = a if re.match(r"^[0-9a-f-]{36}$", a) else ""   # zone de synchro de la pièce de la TV ("" = toutes)
    out["x"] = round(num("x", 0.0, 1.0, 0.5), 3)          # centre de la TV le long du mur (0-1)
    out["w"] = round(num("w", 0.3, 4.0, 1.23), 2)         # largeur de la TV en mètres
    out["back"] = round(num("back", 0.0, 1.0, 0.35), 2)   # luminosité au fond de la pièce
    out["spots"] = round(num("spots", 0.0, 1.0, 0.3), 2)  # luminosité des spots
    out["hz"] = int(num("hz", 4, 25, 12))
    out["smooth"] = d.get("smooth") if d.get("smooth") in ("vive", "normale", "douce") else "normale"
    out["flip"] = bool(d.get("flip"))
    out["amb"] = clean_amb(d.get("amb"))          # l'Ambilight comme une lampe (couleur fixe)
    return out


# --- Téléviseur : appairage et état ---
TV_PATH = os.path.join(CONF_DIR, hms.TV_FILE)
tv_pairing = {"state": "idle", "message": ""}
_tv_pending = {}


def tv_state():
    c = hms.tv_load(CONF_DIR)
    if not c and tv_pairing["state"] == "done":
        tv_pairing.update(state="idle", message="")
    st = get_live()
    return {"paired": bool(c), "ip": (c or {}).get("ip") or _tv_pending.get("ip", ""),
            "model": (c or {}).get("model", ""), "pairing": tv_pairing,
            "engine": st.get("tv") if isinstance(st.get("tv"), dict) else None,
            "source": st.get("source"), "settings": clean_tv(get_settings().get("tv") or {})}


def tv_pair(body):
    ip = str(body.get("ip", "")).strip()
    if not re.match(r"^[0-9]{1,3}(\.[0-9]{1,3}){3}$", ip):
        raise ValueError("Adresse IP de la TV invalide.")
    try:
        st = hms.tv_pair_request(ip)
    except hms.TvError as e:
        tv_pairing.update(state="error", message=str(e))
        return tv_state()
    _tv_pending.clear()
    _tv_pending.update(st, t=time.time())
    tv_pairing.update(state="pin", message="Saisis le code affiché sur la TV.")
    return tv_state()


def tv_pin(body):
    if not _tv_pending or time.time() - _tv_pending.get("t", 0) > max(30, _tv_pending.get("timeout") or 60) + 30:
        tv_pairing.update(state="error", message="Code expiré : recommence l'appairage.")
        return tv_state()
    pin = re.sub(r"\D", "", str(body.get("pin", "")))
    if not pin:
        raise ValueError("Code PIN manquant.")
    try:
        cred = hms.tv_pair_grant(_tv_pending, pin)
    except hms.TvError as e:
        tv_pairing.update(state="error", message="Code refusé par la TV : vérifie-le et recommence l'appairage.")
        return tv_state()
    try:
        info = hms.TvClient(cred["ip"], cred["user"], cred["key"], timeout=4).request("GET", "/6/system")
        cred["model"] = str(info.get("name") or info.get("model") or "")[:60]
    except hms.TvError:
        pass
    write_json(TV_PATH, cred)
    try:
        os.chmod(TV_PATH, 0o600)
    except OSError:
        pass
    _tv_pending.clear()
    tv_pairing.update(state="done", message="TV appairée.")
    return tv_state()


def tv_forget():
    try:
        os.remove(TV_PATH)
    except OSError:
        pass
    s = get_settings()
    s["tv"] = {**clean_tv(s.get("tv") or {}), "on": False}
    write_json(SETTINGS_PATH, s)
    tv_pairing.update(state="idle", message="")
    return tv_state()


AMB_SIDES = ("left", "top", "right")


def clean_amb(d):
    """L'Ambilight piloté comme une lampe : allumé, couleur, luminosité, et couleurs pixel par pixel
    (`pix` = {left: [...], top: [...], right: [...]}, vu de face ; None = une seule couleur partout)."""
    d = d if isinstance(d, dict) else {}
    col = d.get("color") if isinstance(d.get("color"), str) and HEX_RE.match(d.get("color")) else "#ffb36b"
    try:
        bri = max(1, min(100, int(d.get("bri", 80))))
    except (TypeError, ValueError):
        bri = 80
    pix = None
    if isinstance(d.get("pix"), dict):
        pix = {}
        for side in AMB_SIDES:
            v = d["pix"].get(side)
            v = v if isinstance(v, list) else []
            pix[side] = [c if isinstance(c, str) and HEX_RE.match(c) else col for c in v[:16]]
        if not any(pix.values()):
            pix = None
    return {"on": bool(d.get("on")), "color": col, "bri": bri, "pix": pix}


def tv_ambilight(body):
    """Allume l'Ambilight en couleur fixe (comme une lampe), change sa couleur ou sa luminosité,
    ou l'éteint. Indépendant de l'allumage de la TV."""
    c = hms.tv_load(CONF_DIR)
    if not c:
        raise ValueError("TV non appairée.")
    s = get_settings()
    tv = clean_tv(s.get("tv") or {})
    amb = clean_amb({**tv.get("amb", {}), **{k: body[k] for k in ("on", "color", "bri", "pix") if k in body}})
    if "color" in body and "pix" not in body:
        amb["pix"] = None                      # une seule couleur : tous les pixels pareils
    if ("color" in body or "bri" in body or "pix" in body) and "on" not in body:
        amb["on"] = True                       # toucher la roue ou la luminosité allume, comme une lampe
    cl = hms.TvClient(c["ip"], c["user"], c["key"], timeout=4)
    try:
        hms.tv_amb_apply(cl, {**amb, "flip": tv.get("flip")})
    except hms.TvError as e:
        raise ValueError(f"La TV ne répond pas ({e}).")
    finally:
        cl.close()
    s["tv"] = {**tv, "amb": amb}
    write_json(SETTINGS_PATH, s)
    return {"ok": True, "amb": amb}


def tv_test():
    """Mesure combien de fois par seconde on peut lire les couleurs de l'Ambilight (20 lectures)."""
    c = hms.tv_load(CONF_DIR)
    if not c:
        raise ValueError("TV non appairée.")
    cl = hms.TvClient(c["ip"], c["user"], c["key"], timeout=3)
    try:
        power = cl.request("GET", "/6/powerstate").get("powerstate")
        if power != "On":
            return {"ok": False, "power": power, "message": "Allume la TV (pas en veille) pour mesurer."}
        topo = cl.request("GET", "/6/ambilight/topology")
        mode = cl.request("GET", "/6/ambilight/mode").get("current")
        black = {k: hms.tv_black(hms.tv_frame(cl.request("GET", f"/6/ambilight/{k}"))) for k in hms.TV_SOURCES}
        src = next((k for k in hms.TV_SOURCES if not black[k]), "processed")
        times, last = [], None
        t0 = time.time()
        for _ in range(20):
            a = time.time()
            last, src = hms.tv_read(cl, src)
            times.append(time.time() - a)
        total = time.time() - t0
    except hms.TvError as e:
        return {"ok": False, "message": str(e)}
    finally:
        cl.close()
    times.sort()
    sides = {k: len(v) for k, v in (last or {}).items()}
    to_hex = lambda a: ["#%02x%02x%02x" % tuple(int(max(0, min(1, x)) * 255) for x in p) for p in a]
    return {"ok": True, "power": power, "hz": round(20 / total, 1), "ms": round(times[len(times) // 2] * 1000),
            "ms_max": round(times[-1] * 1000), "topology": topo, "mode": mode, "sides": sides,
            "src": src, "black": black,
            "preview": {k: to_hex(v) for k, v in (last or {}).items() if len(v)}}


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
    if isinstance(body.get("tv"), dict):
        s["tv"] = clean_tv({**(s.get("tv") if isinstance(s.get("tv"), dict) else {}), **body["tv"]})
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
    grad = body.get("gradient")
    if isinstance(grad, list) and grad:         # dégradé point par point, comme l'app Hue (2 à 5 points)
        gh = [c for c in grad if isinstance(c, str) and HEX_RE.match(c)][:GRAD_POINTS]
        if len(gh) < 2:
            raise ValueError("Il faut 2 à 5 couleurs.")
        gxy = [hex_to_xy(c) for c in gh]
        gb = {"points": [{"color": {"xy": {"x": x, "y": y}}} for x, y in gxy]}
        if body.get("mode") in GRAD_MODES:
            gb["mode"] = body["mode"]
        b["gradient"] = gb
        b.pop("color", None)
        APPLIED[body.get("id")] = {"grad": gh, "gxy": gxy}
        b.setdefault("on", {"on": True})
    elif body.get("mode") in GRAD_MODES:        # changer seulement le style du dégradé
        b["gradient"] = {"mode": body["mode"]}
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
    l'éditeur) : ordre et place de chaque segment du ruban, place et hauteur de chaque spot."""
    if strips is None:
        strips = {l["id"]: dict({"walls": 1, "corner": 0, "dir": 1}, **((plan.get("rubans") or {}).get(l["id"]) or {}))
                  for l in room["lights"] if l.get("has_gradient")}
    rows = hms.channel_info(cfg, area)
    light_of_dev = {lights.get(l["id"], {}).get("owner", {}).get("rid"): l["id"] for l in room["lights"]}
    by_lamp = {l["id"]: l for l in room["lights"]}
    heights = plan.get("heights") if isinstance(plan.get("heights"), dict) else {}

    def height_of(lid):
        try:
            return max(-1, min(1, int(round(float(heights[lid])))))
        except (KeyError, TypeError, ValueError):
            return default_height(by_lamp.get(lid))

    ch, rubans, spots, by_dev = {}, {}, {}, {}
    for r in rows:
        by_dev.setdefault(r["dev"], []).append(r)
    for dev, rs in by_dev.items():
        lid = light_of_dev.get(dev)
        rb = strips.get(lid)
        zh = height_of(lid)
        if rb and len(rs) > 1:
            rubans[dev] = rb
            rs.sort(key=lambda r: r["idx"])
            for k, r in enumerate(rs):
                u = (k + 0.5) / len(rs)
                px, py = along(rb, u, plan.get("dims"))
                ch[str(r["id"])] = {"t": round(u, 4), "x": round(px * 2 - 1, 4), "y": round(1 - py * 2, 4),
                                    "z": zh}
        else:
            for r in rs:
                q = (plan.get("spots") or {}).get(lid) or [(r["x"] + 1) / 2, (1 - r["y"]) / 2]
                q = [max(PM, min(1 - PM, float(q[0]))), max(PM, min(1 - PM, float(q[1])))]
                spots[str(r["id"])] = q
                ch[str(r["id"])] = {"t": round(q[0], 4), "x": round(q[0] * 2 - 1, 4), "y": round(1 - q[1] * 2, 4),
                                    "z": zh}
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
               "dims": body.get("dims"), "heights": body.get("heights")})
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
    if "rubans" in body or "spots" in body or "heights" in body:          # on enregistre d'abord le plan tel qu'il est à l'écran
        save_plan({"type": "room", "id": rid, "rubans": body.get("rubans") or {}, "spots": body.get("spots") or {},
                   "dims": body.get("dims"), "heights": body.get("heights")})
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
        if path == "/api/tv":
            return self._send(200, tv_state())
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
            if path in ("/api/tv/pair", "/api/tv/pin", "/api/tv/forget", "/api/tv/test", "/api/tv/ambilight"):
                fn = {"/api/tv/pair": lambda: tv_pair(body), "/api/tv/pin": lambda: tv_pin(body),
                      "/api/tv/forget": tv_forget, "/api/tv/test": tv_test, "/api/tv/ambilight": lambda: tv_ambilight(body)}[path]
                return self._send(200, fn())
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
