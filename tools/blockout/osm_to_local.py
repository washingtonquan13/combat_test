"""Turns an Overpass API JSON extract into a blockout source file in local
metres, which tools/blockout/build_osm_blockout.gd then builds into a scene.

    python tools/blockout/osm_to_local.py <overpass.json> <out.json> \
        --bbox S,W,N,E [--default-height 11]

Coordinates: x is east, z is south (Godot's -Z is north), metres from the
centre of the bbox. Map data (c) OpenStreetMap contributors, ODbL.
"""
import argparse
import json
import math

LEVEL_HEIGHT = 3.6  # Quarter buildings have tall storeys
ROOF_ALLOWANCE = 1.0

LINE_WIDTHS = {
    "residential": 7.0, "tertiary": 8.0, "secondary": 9.0, "service": 4.0,
    "pedestrian": 6.0, "footway": 2.0, "path": 1.5, "steps": 2.5,
    "construction": 5.0,
}
BARRIER_HEIGHTS = {"fence": 1.6, "wall": 2.2, "hedge": 1.1, "coupure": 2.5}
AREA_KINDS = {
    ("leisure", "park"): "park", ("leisure", "garden"): "garden",
    ("landuse", "grass"): "grass", ("landuse", "village_green"): "grass",
    ("leisure", "bleachers"): "bleachers", ("man_made", "pier"): "pier",
    ("highway", "pedestrian"): "plaza",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("out")
    ap.add_argument("--bbox", required=True)
    ap.add_argument("--default-height", type=float, default=11.0)
    args = ap.parse_args()
    s, w, n, e = (float(v) for v in args.bbox.split(","))
    lat0, lon0 = (s + n) / 2, (w + e) / 2
    m_lat = 111_320.0
    m_lon = 111_320.0 * math.cos(math.radians(lat0))
    half_x = (e - w) / 2 * m_lon
    half_z = (n - s) / 2 * m_lat

    def local(node):
        return [round((node["lon"] - lon0) * m_lon, 2), round(-(node["lat"] - lat0) * m_lat, 2)]

    def inside(p, margin=0.0):
        return abs(p[0]) <= half_x + margin and abs(p[1]) <= half_z + margin

    data = json.load(open(args.src, encoding="utf-8"))
    nodes = {el["id"]: el for el in data["elements"] if el["type"] == "node"}
    ways = {el["id"]: el for el in data["elements"] if el["type"] == "way"}
    relations = [el for el in data["elements"] if el["type"] == "relation"]

    def way_points(way):
        return [local(nodes[i]) for i in way["nodes"] if i in nodes]

    def centroid(ring):
        return [sum(p[0] for p in ring) / len(ring), sum(p[1] for p in ring) / len(ring)]

    def open_ring(pts):
        return pts[:-1] if len(pts) > 1 and pts[0] == pts[-1] else pts

    def join_rings(member_ways):
        """Multipolygon outers/inners can be split over several ways."""
        chains = [list(w["nodes"]) for w in member_ways]
        rings = []
        while chains:
            ring = chains.pop(0)
            changed = True
            while ring[0] != ring[-1] and changed:
                changed = False
                for c in chains:
                    if c[0] == ring[-1]:
                        ring += c[1:]
                    elif c[-1] == ring[-1]:
                        ring += c[-2::-1]
                    elif c[-1] == ring[0]:
                        ring = c[:-1] + ring
                    elif c[0] == ring[0]:
                        ring = c[:0:-1] + ring
                    else:
                        continue
                    chains.remove(c)
                    changed = True
                    break
            rings.append(open_ring([local(nodes[i]) for i in ring if i in nodes]))
        return [r for r in rings if len(r) >= 3]

    def height_of(tags):
        if "height" in tags:
            try:
                return float(tags["height"].split()[0]), "height tag"
            except ValueError:
                pass
        if "building:levels" in tags:
            try:
                return float(tags["building:levels"]) * LEVEL_HEIGHT + ROOF_ALLOWANCE, "levels tag"
            except ValueError:
                pass
        return args.default_height, "default"

    buildings, areas, lines, trees, landmarks = [], [], [], [], []
    member_way_ids = set()

    for rel in relations:
        tags = rel.get("tags", {})
        if "building" not in tags and "building:part" not in tags:
            continue
        outers = [ways[m["ref"]] for m in rel["members"] if m["type"] == "way" and m["role"] == "outer" and m["ref"] in ways]
        inners = [ways[m["ref"]] for m in rel["members"] if m["type"] == "way" and m["role"] == "inner" and m["ref"] in ways]
        member_way_ids.update(w["id"] for w in outers + inners)
        height, src = height_of(tags)
        inner_rings = join_rings(inners)
        for i, outer in enumerate(join_rings(outers)):
            if not inside(centroid(outer)):
                continue
            buildings.append({
                "name": tags.get("name", "Building %d" % rel["id"]) + ("" if i == 0 else " %d" % (i + 1)),
                "osm": "relation/%d" % rel["id"], "height": height, "height_source": src,
                "outer": outer, "inners": inner_rings,
            })

    for way in ways.values():
        tags = way.get("tags", {})
        if not tags or way["id"] in member_way_ids:
            continue
        pts = way_points(way)
        if len(pts) < 2:
            continue
        closed = way["nodes"][0] == way["nodes"][-1]
        if "building" in tags and closed:
            ring = open_ring(pts)
            if len(ring) >= 3 and inside(centroid(ring)):
                height, src = height_of(tags)
                buildings.append({
                    "name": tags.get("name", "Building %d" % way["id"]), "osm": "way/%d" % way["id"],
                    "height": height, "height_source": src, "outer": ring, "inners": [],
                })
            continue
        kind = next((AREA_KINDS[(k, tags[k])] for k in ("leisure", "landuse", "man_made", "highway")
                     if (k, tags.get(k)) in AREA_KINDS), None)
        if kind and closed and (kind != "plaza" or tags.get("area") == "yes"):
            ring = open_ring(pts)
            if len(ring) >= 3 and any(inside(p, 30) for p in ring):
                areas.append({"kind": kind, "name": tags.get("name", ""), "osm": "way/%d" % way["id"], "poly": ring})
            continue
        if "highway" in tags and tags["highway"] in LINE_WIDTHS:
            kind, width, height = "steps" if tags["highway"] == "steps" else "street", LINE_WIDTHS[tags["highway"]], 0.0
        elif "barrier" in tags and tags["barrier"] in BARRIER_HEIGHTS:
            kind, width, height = "barrier", 0.3, BARRIER_HEIGHTS[tags["barrier"]]
        elif "railway" in tags:
            kind, width, height = "rail", 3.0, 0.0
        else:
            continue
        if not any(inside(p, 20) for p in pts):
            continue
        lines.append({"kind": kind, "type": tags.get("highway") or tags.get("barrier") or tags.get("railway"),
                      "name": tags.get("name", ""), "osm": "way/%d" % way["id"],
                      "width": width, "height": height, "pts": pts})

    for node in nodes.values():
        tags = node.get("tags", {})
        p = local(node)
        if not inside(p):
            continue
        if tags.get("natural") == "tree":
            trees.append(p)
        elif "historic" in tags:
            landmarks.append({"name": tags.get("name", tags["historic"]), "kind": tags["historic"], "pos": p})

    out = {
        "attribution": "Map data (c) OpenStreetMap contributors, ODbL 1.0. https://www.openstreetmap.org/copyright",
        "bbox": [s, w, n, e], "origin": [lat0, lon0], "half_extent": [round(half_x, 1), round(half_z, 1)],
        "buildings": buildings, "areas": areas, "lines": lines, "trees": trees, "landmarks": landmarks,
    }
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    print("buildings %d (%d with real heights), areas %d, lines %d, trees %d, landmarks %d" % (
        len(buildings), sum(b["height_source"] != "default" for b in buildings),
        len(areas), len(lines), len(trees), len(landmarks)))


if __name__ == "__main__":
    main()
