#!/usr/bin/env python3
"""Faux pont Hue (CLIP v2, HTTPS auto-signé) pour tester Lueur sans matériel.

Imite un salon : un ruban (7 segments), 2 spots, 1 Bloom, sans zone de
divertissement au départ. Lueur la crée via POST /entertainment_configuration.

Usage :
    import faux_pont
    srv, port = faux_pont.demarrer()
    ...
    srv.shutdown()

Le client Lueur ignore la vérification TLS (CERT_NONE), donc le certificat
auto-signé généré au démarrage suffit.
"""

import copy
import json
import ssl
import subprocess
import tempfile
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---------------------------------------------------------------------------
# Données : un salon avec ruban + 2 spots + 1 Bloom


def _lampe(dev, nom, archetype, produit, grad=False):
    return {
        "device": {"id": dev, "metadata": {"name": nom, "archetype": archetype},
                   "product_data": {"product_name": produit}},
        "light": {"id": "l-" + dev, "owner": {"rid": dev, "rtype": "device"},
                  "metadata": {"name": nom, "archetype": archetype},
                  "on": {"on": True}, "dimming": {"brightness": 80},
                  "color": {"xy": {"x": 0.3227, "y": 0.329}},
                  **({"gradient": {"points_capable": 5, "mode": "interpolated_palette",
                                    "mode_values": ["interpolated_palette"],
                                    "points": [{"color": {"xy": {"x": 0.3, "y": 0.3}}}] * 5}} if grad else {}),
                  },
        "ent": {"id": "e-" + dev, "owner": {"rid": dev, "rtype": "device"},
                "renderer": True,
                "segments": {"max_segments": 7 if grad else 1, "configurable": grad}},
    }


def jeu_initial():
    """État initial du pont : pièces, lampes, services, sans zone de synchro."""
    lampes = [
        _lampe("dev-ruban", "Ruban Salon", "hue_lightstrip", "Hue Flux", grad=True),
        _lampe("dev-spot1", "Spot 1", "recessed_ceiling", "Hue Spot"),
        _lampe("dev-spot2", "Spot 2", "recessed_ceiling", "Hue Spot"),
        _lampe("dev-bloom", "Bloom", "huebloom", "Hue Bloom"),
    ]
    return {
        "device": [x["device"] for x in lampes],
        "light": [x["light"] for x in lampes],
        "entertainment": [x["ent"] for x in lampes],
        "room": [{"id": "room-salon", "metadata": {"name": "Salon"},
                  "children": [{"rid": x["device"]["id"], "rtype": "device"} for x in lampes],
                  "services": [{"rid": "gl-salon", "rtype": "grouped_light"}]}],
        "zone": [],
        "grouped_light": [{"id": "gl-salon", "on": {"on": True}, "dimming": {"brightness": 80}}],
        "entertainment_configuration": [],
        "scene": [],
    }


class Etat:
    def __init__(self):
        self.res = jeu_initial()
        self.cid = 0          # prochains channel_id
        self.journal = []     # (méthode, chemin, corps) pour les vérifications

    def canaux(self, locs):
        ent_dev = {e["id"]: e["owner"]["rid"] for e in self.res["entertainment"]}
        maxseg = {e["id"]: (e.get("segments") or {}).get("max_segments", 1)
                  for e in self.res["entertainment"]}
        dev_max = {}
        for eid, dev in ent_dev.items():
            dev_max[dev] = max(dev_max.get(dev, 1), maxseg[eid] or 1)
        canaux = []
        for loc in locs:
            rid = (loc.get("service") or {}).get("rid")
            dev = ent_dev.get(rid)
            pos = (loc.get("positions") or [{}])[0]
            for i in range(dev_max.get(dev, 1)):
                canaux.append({"channel_id": self.cid,
                               "position": {"x": pos.get("x", 0), "y": pos.get("y", 0),
                                            "z": pos.get("z", 0)},
                               "members": [{"service": {"rid": rid, "rtype": "entertainment"},
                                            "index": i}]})
                self.cid += 1
        return canaux


class Handler(BaseHTTPRequestHandler):
    server_version = "FauxPont/1"

    def _send(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _corps(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        return json.loads(self.rfile.read(n) or b"null")

    def log_message(self, *a):
        pass

    def do_GET(self):
        etat = self.server.etat
        if self.path == "/api/0/config":
            return self._send(200, {"bridgeid": "FAUXPONT", "modelid": "BSB002",
                                    "name": "Faux pont"})
        if self.path == "/eventstream/clip/v2":
            return self._send(404, {})
        parts = self.path.strip("/").split("/")
        if len(parts) == 4 and parts[:3] == ["clip", "v2", "resource"]:
            return self._send(200, {"data": copy.deepcopy(etat.res.get(parts[3], []))})
        return self._send(404, {})

    def do_POST(self):
        etat = self.server.etat
        body = self._corps()
        etat.journal.append(("POST", self.path, body))
        parts = self.path.strip("/").split("/")
        if parts == ["clip", "v2", "resource", "entertainment_configuration"]:
            locs = ((body.get("locations") or {}).get("service_locations") or [])
            aid = "area-%d" % (len(etat.res["entertainment_configuration"]) + 1)
            etat.res["entertainment_configuration"].append({
                "id": aid, "metadata": body.get("metadata", {}),
                "configuration_type": body.get("configuration_type", "music"),
                "status": "active", "locations": {"service_locations": locs},
                "channels": etat.canaux(locs), "stream": {"active": False}})
            return self._send(200, {"data": [{"rid": aid}]})
        return self._send(404, {})

    def do_PUT(self):
        etat = self.server.etat
        body = self._corps()
        etat.journal.append(("PUT", self.path, body))
        parts = self.path.strip("/").split("/")
        if len(parts) == 5 and parts[:3] == ["clip", "v2", "resource"]:
            kind, rid = parts[3], parts[4]
            for d in etat.res.get(kind, []):
                if d.get("id") == rid:
                    if kind == "entertainment_configuration" and body.get("action") == "stop":
                        d["status"] = "inactive"
                    else:
                        for k, v in body.items():
                            if isinstance(v, dict) and isinstance(d.get(k), dict):
                                d[k].update(v)
                            else:
                                d[k] = v
                        if kind == "entertainment_configuration" and "locations" in body:
                            locs = (body["locations"].get("service_locations") or [])
                            d["channels"] = etat.canaux(locs)
                            d["status"] = "active"
                    return self._send(200, {"data": [{"rid": rid}]})
            return self._send(404, {"errors": [{"description": "introuvable"}]})
        return self._send(404, {})


def demarrer(port=0):
    """Lance le faux pont en fond (HTTPS). Renvoie (serveur, port)."""
    tmp = tempfile.mkdtemp(prefix="faux-pont-")
    key, crt = os.path.join(tmp, "key.pem"), os.path.join(tmp, "crt.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", key, "-out", crt, "-days", "2",
                    "-subj", "/CN=127.0.0.1"], check=True,
                   capture_output=True)
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    srv.etat = Etat()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(crt, key)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    import threading
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]


if __name__ == "__main__":
    import time
    srv, port = demarrer(8443)
    print(f"Faux pont sur https://127.0.0.1:{port} (Ctrl+C pour arrêter)")
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
