"""Download a city's buildings and ground features from the Overpass API.

    python -I tools/blockout/fetch_osm_city.py <raw dir> --bbox S,W,N,E

Writes bld_I_J.json (buildings, one file per tile of a 4x4 split, because
one query for a whole city times out) and features.json (water, roads,
green space, rail), the input of osm_city.py. Files already present are
skipped, so a failed run can be resumed. The public servers rate-limit
and time out often; the script rotates between them and retries.

Map data (c) OpenStreetMap contributors, ODbL 1.0.
"""
import argparse
import json
import os
import time
import urllib.parse
import urllib.request

SERVERS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]
SPLIT = 4
TRIES = 12


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--bbox", required=True)
    args = ap.parse_args()
    s, w, n, e = (float(v) for v in args.bbox.split(","))
    os.makedirs(args.out, exist_ok=True)
    for i in range(SPLIT):
        for j in range(SPLIT):
            ts, tn = s + (n - s) * i / SPLIT, s + (n - s) * (i + 1) / SPLIT
            tw, te = w + (e - w) * j / SPLIT, w + (e - w) * (j + 1) / SPLIT
            _fetch(os.path.join(args.out, "bld_%d_%d.json" % (i, j)),
                   '[out:json][timeout:300];way["building"](%f,%f,%f,%f);out tags geom;' % (ts, tw, tn, te))
    bb = "(%f,%f,%f,%f)" % (s, w, n, e)
    # `out geom`, not `out tags geom`: relations need their members, and
    # the bbox clips them, which osm_city.py repairs.
    _fetch(os.path.join(args.out, "features.json"), f"""[out:json][timeout:300];
(
 way["natural"="water"]{bb}; relation["natural"="water"]{bb};
 way["waterway"~"^(river|canal|riverbank)$"]{bb}; relation["waterway"="riverbank"]{bb};
 way["highway"~"^(motorway|trunk|primary|secondary|tertiary|motorway_link|trunk_link|primary_link)$"]{bb};
 way["highway"~"^(residential|unclassified|living_street|service|pedestrian)$"]{bb};
 way["leisure"~"^(park|golf_course|stadium|pitch)$"]{bb}; relation["leisure"="park"]{bb};
 way["landuse"~"^(cemetery|grass|forest|meadow|recreation_ground|industrial|railway)$"]{bb};
 relation["landuse"~"^(cemetery|forest|industrial)$"]{bb};
 way["natural"~"^(wood|wetland|scrub)$"]{bb}; relation["natural"~"^(wood|wetland)$"]{bb};
 way["man_made"="dyke"]{bb}; way["railway"="rail"]{bb};
);
out geom{bb};""")


def _fetch(path, query):
    if os.path.exists(path) and os.path.getsize(path) > 100:
        print("have", os.path.basename(path))
        return
    data = urllib.parse.urlencode({"data": query}).encode()
    for attempt in range(TRIES):
        url = SERVERS[attempt % len(SERVERS)]
        try:
            req = urllib.request.Request(url, data=data, headers={"User-Agent": "combat_test-blockout/1.0"})
            with urllib.request.urlopen(req, timeout=400) as r:
                body = r.read()
            json.loads(body)
            with open(path, "wb") as f:
                f.write(body)
            print("got", os.path.basename(path), len(body) // 1024, "KB", flush=True)
            return
        except Exception as ex:
            print("retry", os.path.basename(path), url, ex, flush=True)
            time.sleep(20)
    raise SystemExit("failed " + path)


if __name__ == "__main__":
    main()
