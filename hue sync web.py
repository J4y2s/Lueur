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
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Interface Hue Sync sur http://0.0.0.0:{PORT}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
