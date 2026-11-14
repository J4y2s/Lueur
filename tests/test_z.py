#!/usr/bin/env python3
"""Scénario Z avec le faux pont : plan 2D + hauteurs -> zone -> synchro.

Parcourt le vrai serveur web (http://127.0.0.1:8099) adossé au faux pont :
pièces, plan avec hauteurs, création de la zone, recopie des z, puis moteur
(plan_channels, test_color_map, effet Colonne, VideoMapper.ambi).

Usage : python3 tests/test_z.py (le serveur web doit tourner sur :8099).
Code de retour 0 si tout passe.
"""

import json
import os
import sys
import time
import urllib.request

ICI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(ICI, "..", "site"))
sys.path.insert(0, ICI)
import faux_pont  # noqa: E402

WEB = "http://127.0.0.1:8099"
CONF = "/tmp/opencode/lueur-test"
echecs = []


def api(methode, chemin, corps=None):
    req = urllib.request.Request(WEB + chemin, method=methode,
                                 data=json.dumps(corps).encode() if corps is not None else None,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read() or b"null")


def check(nom, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + nom + (f" ({detail})" if detail and not cond else ""))
    if not cond:
        echecs.append(nom)


srv, port = faux_pont.demarrer()
with open(os.path.join(CONF, "config.json"), "w") as f:
    json.dump({"bridge": f"127.0.0.1:{port}", "username": "faux"}, f)
with open(os.path.join(CONF, "settings.json"), "w") as f:
    json.dump({}, f)

# 1. Pièces du faux pont
rooms = api("GET", "/api/rooms")
salon = next((r for r in rooms if r["name"] == "Salon"), None)
check("piece Salon visible", salon is not None)
noms = {l["name"] for l in salon["lights"]} if salon else set()
check("4 lampes", noms == {"Ruban Salon", "Spot 1", "Spot 2", "Bloom"}, str(noms))
ids = {l["name"]: l["id"] for l in salon["lights"]} if salon else {}
ruban = next((l for l in salon["lights"] if l["has_gradient"]), None) if salon else None
check("ruban avec degrade", bool(ruban))

# 2. Plan avec hauteurs : ruban et spots en haut, Bloom en bas
plan = {"type": "room", "id": "room-salon",
        "rubans": {ids["Ruban Salon"]: {"walls": 4, "corner": 0, "dir": 1}},
        "spots": {ids["Spot 1"]: [0.2, 0.3], ids["Spot 2"]: [0.8, 0.3], ids["Bloom"]: [0.5, 0.8]},
        "dims": {"w": 5, "d": 4},
        "heights": {ids["Ruban Salon"]: 1, ids["Spot 1"]: 1, ids["Spot 2"]: 1, ids["Bloom"]: -1}}
r = api("POST", "/api/plan", plan)
check("plan enregistre", r.get("ok") is True, str(r))
time.sleep(2.5)   # laisser LIVE relire le pont

# 3. Création de la zone de synchro
r = api("POST", "/api/area/from_room", {"id": "room-salon", **{k: plan[k] for k in ("rubans", "spots", "dims", "heights")}})
check("zone creee", r.get("ok") is True and r.get("channels") == 10, str(r))
aid = r.get("area_id")
time.sleep(2.5)

# 4. Le pont a reçu les positions (z pont : spots 1.0, ruban 0.8, Bloom 0.0)
posts = [c for m, p, c in srv.etat.journal if m == "POST" and p.endswith("entertainment_configuration")]
locs = (posts[-1].get("locations") or {}).get("service_locations", []) if posts else []
check("4 positions envoyees au pont", len(locs) == 4, str(len(locs)))

# 5. Recopie des hauteurs dans le plan de synchro
import hue_music_sync as hms
pl = api("GET", f"/api/plan?area={aid}")
ch = pl.get("plan", {}).get("ch", {})
byz = {}
for cid, q in ch.items():
    byz.setdefault(q.get("z"), []).append(cid)
check("canaux avec z=+1 (ruban 7 + spots 2)", len(byz.get(1, [])) == 9, str({k: len(v) for k, v in byz.items()}))
check("canal avec z=-1 (Bloom)", len(byz.get(-1, [])) == 1, str({k: len(v) for k, v in byz.items()}))

# 6. Moteur : plan_channels, couleurs par segment, Colonne, Ambilight
cfg = {"bridge": f"127.0.0.1:{port}", "username": "faux"}
area = next(a for a in hms.get_areas(cfg) if (a.get("metadata") or {}).get("name") == "Lueur · Salon")
settings = json.load(open(os.path.join(CONF, "settings.json")))
chs = hms.plan_channels(area, settings.get("plans"))
kinds, _ = hms.channel_kinds(cfg, area)
check("10 canaux classes", len(chs) == 10 and set(kinds.values()) == {"ruban", "spots", "lampes"},
      str(sorted(set(kinds.values()))))
cmap = hms.test_color_map(chs, kinds)
check("couleurs par segment calculees", len(cmap) == 10, str(len(cmap)))

fx = hms.Effects(chs, ["#ff0000", "#00ff00", "#0000ff"], "high", 1.0, "colonne")
bands = {"energy": 0.9, "all": 0.9, "bass": 0.9, "mid": 0.5, "high": 0.2,
         "on_bass": 1, "on_mid": 0.5, "on_high": 0.2, "lr": 0.0}
fx.vuz, fx.vuz_peak = 0.45, 0.45
res = fx._render_extra(bands, False, 1.0, len(chs), dict(bands, all=0.5, bass=0.5))
zb = {}
for chh, (_, b, _) in zip(fx.channels, res):
    zb.setdefault(chh["position"].get("z"), []).append(round(b, 2))
bas = [b for z, bs in zb.items() if z == -1 for b in bs]
hauts = [b for z, bs in zb.items() if z == 1 for b in bs]
check("Colonne : le bas s'allume avant le haut", bas and hauts and min(bas) > max(hauts),
      str({k: v for k, v in zb.items()}))
check("Colonne accepte en mode", "colonne" in hms.MODES)

vm = hms.VideoMapper()
vm.configure(chs, kinds, settings.get("plans"), aid, {})
import numpy as np
cadre = {"top": np.ones((7, 3)), "left": np.zeros((3, 3)), "right": np.zeros((3, 3))}
coul = {c["channel_id"]: (1.0, 0.0, 0.0) for c in chs}
ambi = vm.ambi(coul, {"left": 3, "top": 7, "right": 3})
check("Ambilight 3D calcule", ambi is not None and "layer1" in ambi, str(ambi)[:80])

# 7. Changement de hauteur recopié (Bloom -> haut)
api("POST", "/api/plan", {**plan, "heights": {**plan["heights"], ids["Bloom"]: 1}})
time.sleep(0.5)
pl = api("GET", f"/api/plan?area={aid}")
ch2 = pl.get("plan", {}).get("ch", {})
zbloom = [q.get("z") for cid, q in ch2.items() if kinds.get(int(cid)) == "lampes"]
check("Bloom remonte a z=+1", zbloom == [1], str(zbloom))

srv.shutdown()
print(f"\n{len(echecs)} echec(s)" if echecs else "\nTOUT PASSE")
sys.exit(1 if echecs else 0)
