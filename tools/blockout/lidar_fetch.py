"""Measured heights for the elevated roads: USGS 3DEP LiDAR along the deck strip.

    python -I tools/blockout/lidar_fetch.py fetch <raw dir> <out dir> --cache <dir>
        [--city data/blockouts/new_orleans/city.json] [--margin 10]
        [--spacing 1.0] [--budget-gb 3] [--plan-only]
    python -I tools/blockout/lidar_fetch.py plot <raw dir> <out dir> --spot name,x,z,r [--spot ...]
        --png-dir <dir> [--city ...] [--frame <blockout>/city.json]

fetch:
  1. Inventory. From <raw dir>/features.json, every road bridges.py could
     raise: bridge=*, layer>0, or an EXPRESS class (motorway*, trunk*). These
     are the "deck" ways. Roads that share a node with one get their first
     APPROACH metres too (the ramps up to a bridge are often a plain primary
     on an embankment). Only what lies inside the map boundary plus RUNOUT.
  2. Strip. Each way buffered by half its width plus --margin, all unioned,
     in map metres (city.json's origin, x east, z south, equirectangular,
     the same frame as bridges.py).
  3. Datasets. The public 3DEP Entwine index (resources.geojson from
     hobuinc/usgs-lidar) names every dataset; those touching the strip are
     ranked newest first and each takes the part of the strip no newer one
     covers. Their ept.json gives the SRS (EPSG:3857 for the public bucket,
     reprojected by hand here: no pyproj) and the octree.
  4. Plan. The octree is walked over the strip only, down to the depth whose
     voxels are --spacing metres on the ground (each EPT level is a uniform
     thinning of the next, so stopping early IS the thinning). Point counts
     come from the hierarchy; bytes per point from HEAD requests on a few
     nodes. The plan is printed per dataset and depth. Over --budget-gb, the
     margin drops to 5 m; still over, it stops.
  5. Fetch. Nodes one at a time into <cache>/<dataset>/ept-data/, never
     downloaded twice (a file on disk is final; downloads land in .part and
     are renamed), exponential backoff on errors, stop after repeated
     failures.
  6. Points. Classes 17 (bridge deck), 2 (ground) and 1 (unclassified, the
     fallback where a dataset has no 17). Only points inside the strip are
     kept. 17 is kept whole; 2 and 1 are thinned to the lowest point per
     GROUND_CELL / LOW_CELL square, which keeps the ground and, for 1, the
     deck under any car, sign or canopy. Written to <out>/lidar_decks.npz:
     x, z, h (float32, map metres; h is the dataset's own elevation, NAVD88
     metres for 3DEP) and cls (uint8), plus a JSON "meta" string.
  7. Coverage. Every deck way is sampled every metre along its centreline;
     a sample is covered when a class-17 point lies within COVER metres.
     <out>/lidar_coverage.json lists every way with its covered fraction,
     and the ways under half covered are printed.

plot: the points around each spot over the OSM road lines, coloured by class
(17 orange, 1 grey, 2 green), the road lines in blue; one PNG per spot. The
spots are in --frame's map metres, so a smaller blockout cut from the same
OSM (nola_test_c) can name its own coordinates. load() does the same move
for any other reader.

Network etiquette: one request at a time, everything cached on disk.

LiDAR: U.S. Geological Survey 3D Elevation Program, public domain.
Map data (c) OpenStreetMap contributors, ODbL.
"""
import argparse
import json
import math
import os
import re
import site
import sys
import time
import http.client
import urllib.parse

import numpy as np
import shapely
import shapely.ops
from shapely.geometry import LineString, Point, box, shape

sys.path.insert(0, os.path.dirname(__file__))
from osm_city import ROAD_WIDTHS, road_class  # noqa: E402

INDEX_URL = "https://raw.githubusercontent.com/hobuinc/usgs-lidar/master/boundaries/resources.geojson"
BUCKET = "https://s3-us-west-2.amazonaws.com/usgs-lidar-public/"
EXPRESS = ("motorway", "motorway_link", "trunk", "trunk_link")
RUNOUT = 60.0  # bridges.py draws decks this far past the boundary
APPROACH = 150.0  # metres of a joining road kept in the strip
KEEP = (17, 2, 1)
GROUND_CELL = 2.0
LOW_CELL = 1.0
COVER = 5.0  # a deck sample is covered by a class-17 point this near
SAMPLE = 1.0
NARROW_MARGIN = 5.0
R_EARTH = 6378137.0  # EPSG:3857 sphere
M_LAT = 111_320.0  # bridges.py's metres per degree
TRIES = 6
GIVE_UP = 3  # files that failed every try before the run stops
UA = "combat_test-blockout/1.0 (one request at a time; cached)"


# --- frames ---------------------------------------------------------------
class Frame:
    """Map metres <-> lon/lat <-> EPSG:3857, the way bridges.py maps OSM."""

    def __init__(self, city):
        self.lat0, self.lon0 = city["origin"]
        self.m_lon = M_LAT * math.cos(math.radians(self.lat0))

    def to_lonlat(self, x, z):
        return self.lon0 + np.asarray(x) / self.m_lon, self.lat0 - np.asarray(z) / M_LAT

    def from_lonlat(self, lon, lat):
        return (np.asarray(lon) - self.lon0) * self.m_lon, -(np.asarray(lat) - self.lat0) * M_LAT

    def to_merc(self, x, z):
        lon, lat = self.to_lonlat(x, z)
        return (R_EARTH * np.radians(lon),
                R_EARTH * np.log(np.tan(math.pi / 4 + np.radians(lat) / 2)))

    def from_merc(self, mx, my):
        lon = np.degrees(np.asarray(mx, float) / R_EARTH)
        lat = np.degrees(2 * np.arctan(np.exp(np.asarray(my, float) / R_EARTH)) - math.pi / 2)
        return self.from_lonlat(lon, lat)

    def geom_to(self, g, which):
        """A map-metre geometry into lon/lat or 3857, its edges split first
        so a long straight edge stays on the same ground."""
        g = shapely.segmentize(g, 50.0)
        f = self.to_lonlat if which == "lonlat" else self.to_merc
        return shapely.transform(g, lambda c: np.column_stack(f(c[:, 0], c[:, 1])))

    def geom_from(self, g, which):
        g = shapely.segmentize(g, 0.0005 if which == "lonlat" else 50.0)
        f = self.from_lonlat if which == "lonlat" else self.from_merc
        return shapely.transform(g, lambda c: np.column_stack(f(c[:, 0], c[:, 1])))


def _region(rings):
    region = shapely.Polygon()
    for r in rings:
        region = shapely.symmetric_difference(region, shapely.make_valid(shapely.Polygon(r)))
    return region


# --- inventory ------------------------------------------------------------
def inventory(raw, frame, city):
    """Deck ways (bridge, layer > 0 or EXPRESS) and the first APPROACH metres
    of every road joining one, clipped to the map boundary plus RUNOUT."""
    feats = json.load(open(os.path.join(raw, "features.json"), encoding="utf-8"))["elements"]
    region = shapely.buffer(_region(city["boundary"]), RUNOUT)
    shapely.prepare(region)
    roads = []
    for el in feats:
        tags = el.get("tags", {})
        geom = [g for g in el.get("geometry") or [] if g]
        hw = tags.get("highway")
        if el["type"] != "way" or len(geom) < 2 or not hw:
            continue
        if tags.get("building", "no") != "no" or tags.get("area") == "yes":
            continue
        width = ROAD_WIDTHS.get(road_class(tags), 0.0)
        if ROAD_WIDTHS.get(hw, 0.0) <= 0 or width <= 0:
            continue
        bridge = tags.get("bridge", "no") != "no"
        try:
            layer = int(tags.get("layer", "1" if bridge else "0"))
        except ValueError:
            layer = 1 if bridge else 0
        keys = [(round(g["lat"], 7), round(g["lon"], 7)) for g in geom]
        x, z = frame.from_lonlat([g["lon"] for g in geom], [g["lat"] for g in geom])
        roads.append({"osm": el.get("id"), "name": tags.get("name", ""), "ref": tags.get("ref", ""),
                      "cls": hw, "width": width, "bridge": bridge, "layer": layer, "keys": keys,
                      "line": LineString(np.column_stack([x, z])),
                      "deck": bridge or layer > 0 or hw in EXPRESS})
    deck_keys = set()
    for r in roads:
        if r["deck"]:
            deck_keys.update(r["keys"])
    out = []
    for r in roads:
        if r["deck"]:
            line = r["line"]
        else:
            ends = [i for i, k in enumerate(r["keys"]) if k in deck_keys]
            if not ends:
                continue
            pieces = []
            for i in ends:
                s = r["line"].project(Point(r["line"].coords[i]))
                lo, hi = max(0.0, s - APPROACH), min(r["line"].length, s + APPROACH)
                pieces.append(shapely.ops.substring(r["line"], lo, hi))
            line = shapely.line_merge(shapely.union_all(pieces))
        line = shapely.intersection(line, region)
        if line.is_empty or line.length < 1.0:
            continue
        r = dict(r, line=line, kind="deck" if r["deck"] else "approach")
        del r["keys"], r["deck"]
        out.append(r)
    return out


def strip(ways, margin):
    return shapely.union_all([shapely.buffer(w["line"], w["width"] / 2 + margin, quad_segs=4) for w in ways])


# --- network ---------------------------------------------------------------
class Net:
    """One request at a time over one kept-alive connection per host."""

    def __init__(self):
        self.failed = 0
        self.requests = 0
        self.bytes = 0
        self.conns = {}

    def _request(self, method, url):
        """(headers, body) of a 200, None after TRIES failures. 403/404 raise."""
        u = urllib.parse.urlsplit(url)
        delay = 2.0
        for attempt in range(TRIES):
            conn = self.conns.get(u.netloc)
            if conn is None:
                conn = self.conns[u.netloc] = http.client.HTTPSConnection(u.netloc, timeout=120)
            try:
                self.requests += 1
                conn.request(method, u.path, headers={"User-Agent": UA})
                resp = conn.getresponse()
                body = resp.read()
                if resp.status == 200:
                    return resp.headers, body
                if resp.status in (403, 404):
                    raise FileNotFoundError("%s: HTTP %d" % (url, resp.status))
                err = "HTTP %d" % resp.status
            except (http.client.HTTPException, OSError) as e:
                if isinstance(e, FileNotFoundError):
                    raise
                err = e
            conn.close()
            del self.conns[u.netloc]
            print("lidar: %s failed (%s), retry in %.0f s" % (url, err, delay), flush=True)
            time.sleep(delay)
            delay *= 2
        self.failed += 1
        if self.failed >= GIVE_UP:
            sys.exit("lidar: %d files failed every try; stopping rather than hammering the server" % self.failed)
        return None

    def get(self, url, path):
        """The file at url, cached at path: a file on disk is never fetched again."""
        if os.path.exists(path):
            return path
        os.makedirs(os.path.dirname(path), exist_ok=True)
        got = self._request("GET", url)
        if got is None:
            return None
        part = path + ".part"
        with open(part, "wb") as f:
            f.write(got[1])
        self.bytes += len(got[1])
        os.replace(part, path)
        return path

    def size(self, url, cache):
        """Content-Length of url (HEAD), remembered in the json file cache."""
        known = json.load(open(cache)) if os.path.exists(cache) else {}
        if url not in known:
            got = self._request("HEAD", url)
            if got is None:
                return None
            known[url] = int(got[0]["Content-Length"])
            json.dump(known, open(cache, "w"))
        return known[url]


# --- EPT -------------------------------------------------------------------
def _year(name):
    m = re.findall(r"(?:19|20)\d\d", name)
    return max(int(y) for y in m) if m else 0


def datasets(net, cache, frame, area):
    """3DEP datasets touching area, newest first, each with the part of area
    no newer one covers (map metres)."""
    index = net.get(INDEX_URL, os.path.join(cache, "resources.geojson"))
    feats = json.load(open(index, encoding="utf-8"))["features"]
    area_ll = frame.geom_to(area, "lonlat")
    hits = []
    for f in feats:
        g = shapely.make_valid(shape(f["geometry"]))
        if g.intersects(area_ll):
            hits.append((f["properties"], g))
    hits.sort(key=lambda h: (-_year(h[0]["name"]), -h[0]["count"]))
    left, out = area, []
    for props, g in hits:
        part = shapely.intersection(left, frame.geom_from(g, "lonlat"))
        if part.area < 1.0:
            continue
        left = shapely.difference(left, part)
        out.append({"name": props["name"], "count": props["count"], "part": part})
    return out, left


def _node_box(ept, key):
    d, x, y, _ = key
    b = ept["bounds"]
    s = (b[3] - b[0]) / (1 << d)
    return b[0] + x * s, b[1] + y * s, b[0] + (x + 1) * s, b[1] + (y + 1) * s


def walk(net, cache, name, ept, part_merc, max_depth):
    """Every octree node down to max_depth whose square meets part_merc:
    {(d, x, y, z): points}."""
    shapely.prepare(part_merc)
    nodes, pages = {}, [(0, 0, 0, 0)]
    while pages:
        page = pages.pop()
        key = "-".join(map(str, page))
        path = net.get(BUCKET + name + "/ept-hierarchy/" + key + ".json",
                       os.path.join(cache, name, "ept-hierarchy", key + ".json"))
        if path is None:
            continue
        h = json.load(open(path))
        stack = [page]
        while stack:
            k = stack.pop()
            n = h.get("-".join(map(str, k)))
            if n is None or k[0] > max_depth:
                continue
            if not part_merc.intersects(box(*_node_box(ept, k))):
                continue
            if n == -1 and k != page:
                pages.append(k)
                continue
            if n > 0:
                nodes[k] = n
            d, x, y, z = k
            for i in range(8):
                stack.append((d + 1, 2 * x + (i & 1), 2 * y + ((i >> 1) & 1), 2 * z + (i >> 2)))
    return nodes


def depth_for(ept, spacing, lat0):
    """The first depth whose voxels are no wider than spacing on the ground."""
    b = ept["bounds"]
    cell = (b[3] - b[0]) / ept["span"] * math.cos(math.radians(lat0))
    d = 0
    while cell / (1 << d) > spacing:
        d += 1
    return d, cell / (1 << d)


def bytes_per_depth(net, cache, name, nodes, per=3):
    """Compressed bytes per point at each depth, from HEADs on `per` nodes
    spread over that depth: shallow nodes scatter their points over a wide
    square and compress worse than deep ones."""
    out, heads = {}, 0
    for d in sorted({k[0] for k in nodes}):
        keys = sorted(k for k in nodes if k[0] == d)
        size = n = 0
        for k in keys[:: max(1, len(keys) // per)][:per]:
            s = net.size(BUCKET + name + "/ept-data/" + "-".join(map(str, k)) + ".laz",
                         os.path.join(cache, name, "sizes.json"))
            heads += 1
            if s:
                size += s
                n += nodes[k]
        out[d] = size / max(n, 1)
    return out, heads


# --- points ----------------------------------------------------------------
def _lowest(x, z, h, cell):
    """Indices of the lowest point in each cell x cell square."""
    if len(x) == 0:
        return np.zeros(0, int)
    ix = np.floor(x / cell).astype(np.int64)
    iz = np.floor(z / cell).astype(np.int64)
    key = (ix - ix.min()) * (iz.max() - iz.min() + 1) + (iz - iz.min())
    order = np.lexsort((h, key))
    first = np.concatenate([[True], key[order][1:] != key[order][:-1]])
    return order[first]


def read_node(path, frame, part_xz, laspy):
    las = laspy.read(path)
    cls = np.asarray(las.classification).astype(np.uint8)
    keep = np.isin(cls, KEEP)
    mx, my, h = np.asarray(las.x)[keep], np.asarray(las.y)[keep], np.asarray(las.z)[keep]
    cls = cls[keep]
    x, z = frame.from_merc(mx, my)
    inside = shapely.contains_xy(part_xz, x, z)
    f = np.float32
    return (x[inside].astype(f), z[inside].astype(f), h[inside].astype(f), cls[inside],
            np.bincount(np.asarray(las.classification), minlength=256)[:256])


def thin(x, z, h, cls):
    idx = [np.flatnonzero(cls == 17)]
    for c, cell in ((2, GROUND_CELL), (1, LOW_CELL)):
        sel = np.flatnonzero(cls == c)
        idx.append(sel[_lowest(x[sel], z[sel], h[sel], cell)])
    idx = np.concatenate(idx)
    return x[idx], z[idx], h[idx], cls[idx]


# --- coverage --------------------------------------------------------------
class Grid:
    """Points binned into COVER-metre cells for nearest-within-COVER tests."""

    def __init__(self, x, z, cell=COVER):
        self.cell = cell
        self.cells = {}
        ix = np.floor(x / cell).astype(np.int64)
        iz = np.floor(z / cell).astype(np.int64)
        order = np.lexsort((iz, ix))
        ix, iz = ix[order], iz[order]
        self.x, self.z = x[order], z[order]
        if len(ix):
            cut = np.flatnonzero((ix[1:] != ix[:-1]) | (iz[1:] != iz[:-1])) + 1
            starts = np.concatenate([[0], cut])
            ends = np.concatenate([cut, [len(ix)]])
            for s, e in zip(starts, ends):
                self.cells[(int(ix[s]), int(iz[s]))] = (s, e)

    def near(self, px, pz, r=COVER):
        out = np.zeros(len(px), bool)
        for i, (a, b) in enumerate(zip(px, pz)):
            cx, cz = int(math.floor(a / self.cell)), int(math.floor(b / self.cell))
            for dx in (-1, 0, 1):
                for dz in (-1, 0, 1):
                    se = self.cells.get((cx + dx, cz + dz))
                    if se and np.any((self.x[se[0]:se[1]] - a) ** 2 + (self.z[se[0]:se[1]] - b) ** 2 <= r * r):
                        out[i] = True
                        break
                if out[i]:
                    break
        return out


def coverage(ways, x, z, cls):
    deck = cls == 17
    grid = Grid(x[deck], z[deck])
    rows = []
    for w in ways:
        if w["kind"] != "deck":
            continue
        line = w["line"]
        s = np.arange(0.0, line.length + 1e-9, SAMPLE)
        p = shapely.get_coordinates(shapely.line_interpolate_point(line, s))
        hit = grid.near(p[:, 0], p[:, 1])
        mid = shapely.get_coordinates(line.interpolate(0.5, normalized=True))[0]
        rows.append({"way": w["osm"], "name": w["name"], "ref": w["ref"], "class": w["cls"],
                     "bridge": w["bridge"], "layer": w["layer"], "length": round(line.length, 1),
                     "covered": round(float(hit.mean()), 3), "at": [round(float(mid[0]), 1), round(float(mid[1]), 1)]})
    return rows


# --- commands --------------------------------------------------------------
def _load_laspy():
    sys.path.append(site.getusersitepackages())
    import laspy
    return laspy


def cmd_fetch(a):
    city = json.load(open(a.city, encoding="utf-8"))
    frame = Frame(city)
    net = Net()
    os.makedirs(a.cache, exist_ok=True)
    ways = inventory(a.raw, frame, city)
    deck = [w for w in ways if w["kind"] == "deck"]
    print("lidar: %d deck ways (%.1f km: %d bridge, %d layer>0, %d express), %d approaches (%.1f km)"
          % (len(deck), sum(w["line"].length for w in deck) / 1000, sum(w["bridge"] for w in deck),
             sum(w["layer"] > 0 for w in deck), sum(w["cls"] in EXPRESS for w in deck),
             len(ways) - len(deck), sum(w["line"].length for w in ways if w["kind"] != "deck") / 1000), flush=True)

    for margin in ([a.margin, NARROW_MARGIN] if a.margin > NARROW_MARGIN else [a.margin]):
        area = strip(ways, margin)
        print("lidar: strip at margin %.0f m: %.2f km^2" % (margin, area.area / 1e6), flush=True)
        sets, left = datasets(net, a.cache, frame, area)
        if left.area > 1.0:
            print("lidar: %.3f km^2 of the strip is in no dataset" % (left.area / 1e6), flush=True)
        plan, total = [], 0.0
        for ds in sets:
            ept_path = net.get(BUCKET + ds["name"] + "/ept.json", os.path.join(a.cache, ds["name"], "ept.json"))
            ept = json.load(open(ept_path))
            srs = ept.get("srs", {})
            if str(srs.get("horizontal")) != "3857":
                sys.exit("lidar: %s is in %s; only EPSG:3857 is reprojected here" % (ds["name"], srs))
            depth, res = depth_for(ept, a.spacing, frame.lat0)
            part_merc = frame.geom_to(ds["part"], "merc")
            nodes = walk(net, a.cache, ds["name"], ept, part_merc, depth)
            bpp, sampled = bytes_per_depth(net, a.cache, ds["name"], nodes)
            pts = sum(nodes.values())
            est = sum(v * bpp[k[0]] for k, v in nodes.items())
            print("lidar: %s  srs EPSG:%s vertical %s  dataset %.2f G points  strip part %.2f km^2"
                  % (ds["name"], srs.get("horizontal"), srs.get("vertical", "unstated"), ds["count"] / 1e9,
                     ds["part"].area / 1e6), flush=True)
            for d in sorted({k[0] for k in nodes}):
                n = sum(v for k, v in nodes.items() if k[0] <= d)
                gb = sum(v * bpp[k[0]] for k, v in nodes.items() if k[0] <= d) / 1e9
                print("lidar:   to depth %2d (%.2f m): %6d nodes, %11d points, ~%.2f GB (%.1f bytes/point here)"
                      % (d, res * (1 << (depth - d)), sum(1 for k in nodes if k[0] <= d), n, gb, bpp[d]), flush=True)
            print("lidar:   %d points, ~%.2f GB, bytes/point from %d HEADs" % (pts, est / 1e9, sampled), flush=True)
            total += est
            plan.append((ds, ept, nodes, depth, res))
        print("lidar: estimate %.2f GB for %d datasets at %.2f m spacing" % (total / 1e9, len(plan), a.spacing), flush=True)
        if total <= a.budget_gb * 1e9:
            break
        print("lidar: over the %.1f GB budget" % a.budget_gb, flush=True)
    else:
        sys.exit("lidar: still over budget at the narrowest margin; not fetching")
    if a.plan_only:
        return

    laspy = _load_laspy()
    xs, zs, hs, cs = [], [], [], []
    hist = np.zeros(256, np.int64)
    meta_sets = []
    for ds, ept, nodes, depth, res in plan:
        part = ds["part"]
        shapely.prepare(part)
        done = 0
        t0 = time.time()
        parts = []
        for k in sorted(nodes):
            key = "-".join(map(str, k))
            path = net.get(BUCKET + ds["name"] + "/ept-data/" + key + ".laz",
                           os.path.join(a.cache, ds["name"], "ept-data", key + ".laz"))
            done += 1
            if path is None:
                continue
            bx = box(*_node_box(ept, k))
            clip = shapely.intersection(part, frame.geom_from(bx, "merc"))
            x, z, h, c, hc = read_node(path, frame, clip, laspy)
            hist += hc
            parts.append((x, z, h, c))
            if done % 200 == 0:
                print("lidar: %s %d/%d nodes, %.0f MB fetched this run, %.0f s"
                      % (ds["name"], done, len(nodes), net.bytes / 1e6, time.time() - t0), flush=True)
        # Thinned once over the whole part: a node's square overlaps its
        # parent's, so thinning node by node would keep a point per level.
        x, z, h, c = thin(*(np.concatenate(v) for v in zip(*parts)))
        parts.clear()
        xs.append(x.astype(np.float32)); zs.append(z.astype(np.float32))
        hs.append(h.astype(np.float32)); cs.append(c)
        meta_sets.append({"name": ds["name"], "depth": depth, "spacing": round(res, 3), "nodes": len(nodes),
                          "points_in_nodes": int(sum(nodes.values())), "kept": len(x),
                          "classes_read": {str(i): int(n) for i, n in enumerate(hist) if n},
                          "part_km2": round(part.area / 1e6, 3)})
        print("lidar: %s classes read %s; kept %d" % (ds["name"], meta_sets[-1]["classes_read"], len(x)), flush=True)
        hist[:] = 0
    x, z, h, c = (np.concatenate(v) for v in (xs, zs, hs, cs))
    # A node and its children overlap in space, not in points; but two
    # datasets' parts never overlap, so no point is in twice.
    print("lidar: kept %d points: %s" % (len(x), {int(k): int((c == k).sum()) for k in KEEP}), flush=True)
    rows = coverage(ways, x, z, c)
    low = [r for r in rows if r["covered"] < 0.5]
    os.makedirs(a.out, exist_ok=True)
    meta = {"source": "USGS 3DEP LiDAR via the usgs-lidar-public Entwine index (public domain)",
            "frame": "map metres: x east, z south from city.json origin, equirectangular (bridges.py)",
            "origin": city["origin"], "h": "dataset elevation, metres", "classes": list(KEEP),
            "thinning": {"17": "all", "2": "lowest per %.0f m" % GROUND_CELL, "1": "lowest per %.0f m" % LOW_CELL},
            "margin": margin, "strip_km2": round(area.area / 1e6, 3), "datasets": meta_sets,
            "deck_ways": len(rows), "under_half_covered": len(low), "fetched_bytes_this_run": net.bytes,
            "requests_this_run": net.requests}
    np.savez_compressed(os.path.join(a.out, "lidar_decks.npz"), x=x, z=z, h=h, cls=c, meta=json.dumps(meta))
    json.dump({"cover_radius": COVER, "ways": sorted(rows, key=lambda r: r["covered"])},
              open(os.path.join(a.out, "lidar_coverage.json"), "w"), indent=1)
    for tag, f in (("all deck ways", lambda r: True), ("bridge=*", lambda r: r["bridge"]),
                   ("layer>0, not bridge", lambda r: not r["bridge"] and r["layer"] > 0),
                   ("express at grade", lambda r: not r["bridge"] and r["layer"] <= 0)):
        g = [r for r in rows if f(r)]
        m = sum(r["length"] for r in g)
        lo = [r for r in g if r["covered"] < 0.5]
        print("lidar: coverage %-20s %4d ways %6.1f km, %5.1f%% of length; %4d under half (%.1f km)"
              % (tag, len(g), m / 1000, 100 * sum(r["covered"] * r["length"] for r in g) / max(m, 1),
                 len(lo), sum(r["length"] for r in lo) / 1000), flush=True)
    # An expressway at grade is meant to have no deck returns; a bridge
    # without them is the one step 3 must fall back on the solver for.
    for r in sorted(low, key=lambda r: (not r["bridge"], -r["length"]))[:40]:
        print("lidar:   way %s %-30s %-14s bridge=%d layer=%d %6.0f m  %3.0f%% at (%.0f, %.0f)"
              % (r["way"], r["name"][:30], r["class"], r["bridge"], r["layer"], r["length"], 100 * r["covered"], *r["at"]))
    print("lidar: wrote %s (%d points), %d requests, %.0f MB this run"
          % (os.path.join(a.out, "lidar_decks.npz"), len(x), net.requests, net.bytes / 1e6), flush=True)


def load(path, city=None):
    """lidar_decks.npz as (x, z, h, cls, meta), x and z moved into city's
    frame (a city.json dict) when it is given and its origin differs."""
    d = np.load(path)
    meta = json.loads(str(d["meta"]))
    x, z = d["x"].astype(np.float64), d["z"].astype(np.float64)
    if city is not None and list(city["origin"]) != list(meta["origin"]):
        lon, lat = Frame({"origin": meta["origin"]}).to_lonlat(x, z)
        x, z = Frame(city).from_lonlat(lon, lat)
    return x, z, d["h"], d["cls"], meta


def cmd_plot(a):
    from PIL import Image, ImageDraw
    city = json.load(open(a.frame or a.city, encoding="utf-8"))
    frame = Frame(city)
    x, z, h, c, _ = load(os.path.join(a.out, "lidar_decks.npz"), city)
    feats = json.load(open(os.path.join(a.raw, "features.json"), encoding="utf-8"))["elements"]
    lines = []
    for el in feats:
        tags = el.get("tags", {})
        geom = [g for g in el.get("geometry") or [] if g]
        if el["type"] == "way" and len(geom) >= 2 and ROAD_WIDTHS.get(tags.get("highway"), 0) > 0:
            lx, lz = frame.from_lonlat([g["lon"] for g in geom], [g["lat"] for g in geom])
            lines.append((np.column_stack([lx, lz]), tags.get("bridge", "no") != "no" or tags.get("highway") in EXPRESS))
    os.makedirs(a.png_dir, exist_ok=True)
    px = 900
    for spot in a.spot:
        name, sx, sz, r = spot.split(",")
        sx, sz, r = float(sx), float(sz), float(r)
        m = (np.abs(x - sx) < r) & (np.abs(z - sz) < r)
        im = Image.new("RGB", (px, px), (255, 255, 255))
        dr = ImageDraw.Draw(im)
        k = px / (2 * r)
        to = lambda X, Z: ((X - sx + r) * k, (Z - sz + r) * k)  # noqa: E731
        for cl, col in ((2, (90, 170, 90)), (1, (150, 150, 150)), (17, (235, 120, 20))):
            sel = m & (c == cl)
            for X, Z in zip(*to(x[sel], z[sel])):
                dr.point((X, Z), fill=col) if cl != 17 else dr.ellipse((X - 1, Z - 1, X + 1, Z + 1), fill=col)
        for pts, big in lines:
            if np.all(np.abs(pts[:, 0] - sx) > r * 1.2) or np.all(np.abs(pts[:, 1] - sz) > r * 1.2):
                continue
            X, Z = to(pts[:, 0], pts[:, 1])
            dr.line(list(zip(X, Z)), fill=(20, 60, 220) if big else (90, 140, 255), width=2 if big else 1)
        dr.text((8, 8), "%s (%.0f, %.0f) +-%.0f m   17 orange, 1 grey, 2 green; OSM roads blue (express/bridge thick)"
                % (name, sx, sz, r), fill=(0, 0, 0))
        dr.text((8, 22), "points: 17=%d 2=%d 1=%d" % ((m & (c == 17)).sum(), (m & (c == 2)).sum(), (m & (c == 1)).sum()),
                fill=(0, 0, 0))
        im.save(os.path.join(a.png_dir, name + ".png"))
        print("lidar: plot %s: %d points" % (name, int(m.sum())), flush=True)


def main():
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("fetch", "plot"):
        s = sub.add_parser(name)
        s.add_argument("raw")
        s.add_argument("out")
        s.add_argument("--city", default=os.path.join(root, "data", "blockouts", "new_orleans", "city.json"))
    f = sub.choices["fetch"]
    f.add_argument("--cache", required=True)
    f.add_argument("--margin", type=float, default=10.0)
    f.add_argument("--spacing", type=float, default=1.0)
    f.add_argument("--budget-gb", type=float, default=3.0)
    f.add_argument("--plan-only", action="store_true")
    pl = sub.choices["plot"]
    pl.add_argument("--spot", action="append", required=True)
    pl.add_argument("--png-dir", required=True)
    pl.add_argument("--frame", help="city.json whose frame the spots are in (default --city)")
    a = p.parse_args()
    if a.cmd == "fetch":
        if os.path.normcase(os.path.abspath(a.out)) == os.path.normcase(os.path.join(root, "data", "blockouts", "new_orleans")):
            sys.exit("lidar: never write into data/blockouts/new_orleans; use a sibling directory")
        cmd_fetch(a)
    else:
        cmd_plot(a)


if __name__ == "__main__":
    main()
