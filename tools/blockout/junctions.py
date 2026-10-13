"""Simplify the junctions of a (warped) raw OSM dir, SMT style.

    python -I tools/blockout/junctions.py <raw> <out> [--no-snap] [--no-ramps] [--no-medians]

Three passes, all on the raw elements so osm_city needs no change:

1. Medians. The two one-way halves of a divided road (same name, opposite
   directions, MED_MIN..MED_MAX apart) are twins. The ground between them
   gets a synthetic landuse=grass strip, so a divided road reads as one
   avenue with a green median. Halves closer than MED_MIN are already
   joined into one surface by osm_city's join_medians.
2. Ramps. The link roads of one interchange (a connected group of *_link
   ways) are cut down to one ramp per (carriageway direction, on/off): the
   shortest link path from the ground network to that carriageway. A link
   group that touches no carriageway is an at-grade slip lane and goes.
   Gate: no road outside the dropped links loses its connection.
3. Snap. Junctions joined by a road piece shorter than SNAP (offset T's,
   jogs) merge into one node at their mean. Twin halves never merge with
   each other, and highway/link junctions are left alone. Roads are
   straight between nodes, so they follow; each building moves rigidly by
   the road displacement around it (Gaussian weighted, BLD_SIGMA).

Everything not touched is written back byte-for-byte as parsed.
"""

import argparse
import json
import os
import shutil
import sys

import numpy as np
import shapely
from scipy.sparse import coo_matrix, csgraph
from scipy.spatial import cKDTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compress import DP, Frame, write_file  # noqa: E402

ROADS = ("motorway", "trunk", "primary", "secondary", "tertiary", "residential", "unclassified",
         "living_street", "pedestrian")
LINKS = ("motorway_link", "trunk_link", "primary_link", "secondary_link", "tertiary_link")
DECK = ("motorway", "trunk")  # carriageways a ramp serves
DIVIDED = ROADS  # any named one-way pair can be the two sides of one road (neutral ground)
MED_MIN = 12.0  # m: halves closer than this are one surface already (osm_city MEDIAN * 2)
MED_MAX = 60.0  # m: halves farther apart than this are two roads
MED_STEP = 10.0  # m: sample spacing along a half
MED_ANTI = -0.9  # cosine: halves must run this close to opposite
MED_SIDE = 0.35  # the partner must lie mostly across, not along: |along| <= this * gap
MED_RUN = 3  # samples: shortest matched run that makes two ways twins
SNAP = 15.0  # m: junctions joined by a shorter piece merge
SNAP_ROUNDS = 8
THROUGH_COS = 0.94  # cosine: ~20 degrees counts as one straight line
ROAD_STEP = 5.0  # m: road sample spacing for the building displacement field
BLD_SIGMA = 3.0  # m past the building's nearest road sample
BLD_REACH = 40.0  # m: past this from any road, a building does not move


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def frame_of(ways):
    lat = np.array([p["lat"] for w in ways for p in w["geometry"]])
    lon = np.array([p["lon"] for w in ways for p in w["geometry"]])
    return Frame.of_bbox(lat.min(), lon.min(), lat.max(), lon.max())


def is_road(e, classes):
    return e["type"] == "way" and e.get("tags", {}).get("highway") in classes and e.get("geometry") \
        and all(e["geometry"]) and len(e["geometry"]) == len(e.get("nodes", ()))


class Net:
    """Road ways as arrays: per-vertex node id, position, way index."""

    def __init__(self, ways, fr):
        self.ways = ways
        self.fr = fr
        n = np.array([len(w["nodes"]) for w in ways])
        self.start = np.r_[0, np.cumsum(n)[:-1]]
        self.n = n
        self.wid = np.repeat(np.arange(len(ways)), n)
        self.nid = np.fromiter((x for w in ways for x in w["nodes"]), np.int64, n.sum())
        lon = np.fromiter((p["lon"] for w in ways for p in w["geometry"]), float, n.sum())
        lat = np.fromiter((p["lat"] for w in ways for p in w["geometry"]), float, n.sum())
        self.x, self.z = fr.xz(lon, lat)
        self.P = np.c_[self.x, self.z]
        self.cls = np.array([w["tags"]["highway"] for w in ways])
        self.ids, self.vnode = np.unique(self.nid, return_inverse=True)  # vertex -> node index
        last = np.zeros(n.sum(), bool)
        last[self.start + n - 1] = True
        self.seg = np.flatnonzero(~last)  # vertex i -> i+1 is a segment
        a, b = self.vnode[self.seg], self.vnode[self.seg + 1]
        deg = np.bincount(np.r_[a, b], minlength=len(self.ids))
        self.deg = deg
        self.npos = np.zeros((len(self.ids), 2))
        self.npos[self.vnode] = self.P

    def way_pts(self, i):
        s = self.start[i]
        return self.P[s:s + self.n[i]]


# ---------------------------------------------------------------- medians

def halves(net):
    return np.array([w["tags"]["highway"] in DIVIDED and w["tags"].get("oneway") in ("yes", "1", "-1")
                     for w in net.ways])


def sample_ways(net, idx, step):
    """Points every `step` m along the ways in idx (in drawing direction, a
    oneway=-1 way flipped): position, unit tangent, way index."""
    pts, tan, wi = [], [], []
    for i in idx:
        p = net.way_pts(i)
        if net.ways[i]["tags"].get("oneway") == "-1":
            p = p[::-1]
        d = np.diff(p, axis=0)
        L = np.hypot(*d.T)
        ok = L > 1e-6
        if not ok.any():
            continue
        p0, d, L = p[:-1][ok], d[ok], L[ok]
        cum = np.r_[0, np.cumsum(L)]
        s = np.arange(step / 2, cum[-1], step)
        if not len(s):
            s = np.array([cum[-1] / 2])
        k = np.clip(np.searchsorted(cum, s, "right") - 1, 0, len(L) - 1)
        t = (s - cum[k]) / L[k]
        pts.append(p0[k] + d[k] * t[:, None])
        tan.append(d[k] / L[k][:, None])
        wi.append(np.full(len(s), i))
    if not pts:
        return np.zeros((0, 2)), np.zeros((0, 2)), np.zeros(0, int)
    return np.vstack(pts), np.vstack(tan), np.concatenate(wi)


def twins(net):
    """Matched samples of divided-road halves: (twin way pairs, median quads)."""
    idx = np.flatnonzero(halves(net))
    P, T, W = sample_ways(net, idx, MED_STEP)
    name = np.array([net.ways[w]["tags"].get("name", "") for w in W])
    cls = net.cls[W]
    m = cKDTree(P).sparse_distance_matrix(cKDTree(P), MED_MAX, output_type="coo_matrix")
    i, j, g = m.row, m.col, m.data
    keep = (W[i] != W[j]) & (cls[i] == cls[j]) & (name[i] == name[j]) & (name[i] != "") \
        & ((T[i] * T[j]).sum(1) <= MED_ANTI)
    i, j, g = i[keep], j[keep], g[keep]
    along = np.abs(((P[j] - P[i]) * T[i]).sum(1))
    keep = along <= MED_SIDE * np.maximum(g, 1e-9)
    i, j, g = i[keep], j[keep], g[keep]
    # nearest partner per sample
    o = np.lexsort((g, i))
    i, j, g = i[o], j[o], g[o]
    first = np.r_[True, i[1:] != i[:-1]]
    i, j, g = i[first], j[first], g[first]
    partner = np.full(len(P), -1)
    gap = np.zeros(len(P))
    partner[i], gap[i] = j, g
    # way pairs with a long enough matched run
    a, b = np.minimum(W[i], W[j]), np.maximum(W[i], W[j])
    key, cnt = np.unique(np.c_[a, b], axis=0, return_counts=True)
    pairs = key[cnt >= MED_RUN * 2] if len(key) else key  # both directions counted
    pair_set = {tuple(p) for p in pairs.tolist()}
    # quads between consecutive matched samples of the same way, wide medians only
    nxt = np.arange(1, len(P) + 1)
    nxt[-1] = 0
    ok = (partner >= 0) & (np.r_[W[1:], -1] == W) & (partner[np.minimum(nxt, len(P) - 1)] >= 0)
    k = np.flatnonzero(ok)
    k2 = k + 1
    pa, pb = partner[k], partner[k2]
    ok = (W[pa] == W[pb]) & (gap[k] >= MED_MIN) & (gap[k2] >= MED_MIN)
    ok &= np.array([(min(W[x], W[y]), max(W[x], W[y])) in pair_set for x, y in zip(k, pa)], bool) if len(k) else ok
    k, k2, pa, pb = k[ok], k2[ok], pa[ok], pb[ok]
    quads = np.stack([P[k], P[k2], P[pb], P[pa]], axis=1)
    return pair_set, quads


def median_ways(quads, fr, roads_surface):
    if not len(quads):
        return [], 0.0
    polys = shapely.polygons(np.concatenate([quads, quads[:, :1]], axis=1))
    polys = shapely.make_valid(polys)
    green = shapely.union_all(shapely.buffer(polys, 2.0, quad_segs=2))
    green = shapely.buffer(green, -2.0, quad_segs=2)
    green = shapely.difference(green, roads_surface)
    out, area = [], 0.0
    for n, part in enumerate(shapely.get_parts(green)):
        if part.area < 50.0:
            continue
        area += part.area
        r = np.asarray(part.exterior.coords)
        lon, lat = fr.lonlat(r[:, 0], r[:, 1])
        geom = [{"lat": round(float(la), DP), "lon": round(float(lo), DP)} for la, lo in zip(lat, lon)]
        out.append({"type": "way", "id": -(1_000_000 + n), "geometry": geom,
                    "tags": {"landuse": "grass", "median": "yes"}})
    return out, area


# ---------------------------------------------------------------- ramps

def ramps(net):
    """Link ways to drop: everything but one shortest ramp per interchange,
    carriageway direction and on/off."""
    link = np.isin(net.cls, LINKS)
    deck = np.isin(net.cls, DECK)
    ground = ~link & ~deck
    N = len(net.ids)
    vk = np.zeros((N, 3), bool)  # node touches link / deck / ground
    for c, msk in enumerate((link, deck, ground)):
        vk[net.vnode[msk[net.wid]], c] = True
    s = net.seg
    a, b = net.vnode[s], net.vnode[s + 1]
    L = np.hypot(*(net.P[s + 1] - net.P[s]).T)
    lw = link[net.wid[s]]
    G = coo_matrix((L[lw] + 1e-3, (a[lw], b[lw])), shape=(N, N)).tocsr()
    G = G.maximum(G.T)
    nc, lab = csgraph.connected_components(G, directed=False)
    link_nodes = np.flatnonzero(vk[:, 0])
    drop = set(np.flatnonzero(link).tolist())
    keep_ways = set()
    # per link group: deck attachment nodes, with the carriageway's heading there
    dk_v = np.flatnonzero(deck[net.wid])
    head = np.zeros((N, 2))
    for v in dk_v:  # small: deck vertices on link nodes only
        pass
    att = link_nodes[vk[link_nodes, 1]]
    gnd = link_nodes[vk[link_nodes, 2]]
    # heading of a deck way at a node: from the vertex's segment
    first = {}
    for v in dk_v:
        nd = net.vnode[v]
        if not vk[nd, 0] or nd in first:
            continue
        w = net.wid[v]
        k = v - net.start[w]
        p = net.way_pts(w)
        d = p[min(k + 1, len(p) - 1)] - p[max(k - 1, 0)]
        if net.ways[w]["tags"].get("oneway") == "-1":
            d = -d
        first[nd] = d / max(np.hypot(*d), 1e-9)
    # link way direction at a node: into the node (on-ramp end) or out of it
    role = {}
    for w in np.flatnonzero(link):
        nodes = net.vnode[net.start[w]:net.start[w] + net.n[w]]
        rev = net.ways[w]["tags"].get("oneway") == "-1"
        head_n, tail_n = (nodes[0], nodes[-1]) if rev else (nodes[-1], nodes[0])
        role.setdefault(head_n, set()).add("on")
        role.setdefault(tail_n, set()).add("off")
    seg_way = {}
    for k in np.flatnonzero(lw):
        seg_way[(a[k], b[k])] = net.wid[s[k]]
        seg_way[(b[k], a[k])] = net.wid[s[k]]
    by_group = {}
    for nd in att:
        by_group.setdefault(lab[nd], []).append(nd)
    gnd_by = {}
    for nd in gnd:
        gnd_by.setdefault(lab[nd], []).append(nd)
    stats = {"groups": 0, "kept_ramps": 0, "slip_groups": 0}
    for grp, decks in by_group.items():
        stats["groups"] += 1
        gl = gnd_by.get(grp, [])
        if not gl:
            continue  # highway-to-highway: handled below
        axis = np.array([first[d] for d in decks if d in first])
        if not len(axis):
            continue
        u, sv, vt = np.linalg.svd(axis, full_matrices=False)
        ax = vt[0]
        dist, pred = csgraph.dijkstra(G, indices=gl, return_predecessors=True, min_only=True)[0:2] \
            if False else (None, None)
        D, Pr, src = csgraph.dijkstra(G, indices=np.array(gl), min_only=True, return_predecessors=True)
        best = {}
        for d in decks:
            if d not in first or not np.isfinite(D[d]):
                continue
            side = 1 if first[d] @ ax >= 0 else -1
            for r in role.get(d, ()):
                if (side, r) not in best or D[d] < D[best[(side, r)]]:
                    best[(side, r)] = d
        for d in best.values():
            cur = d
            while Pr[cur] >= 0:
                keep_ways.add(seg_way[(Pr[cur], cur)])
                cur = Pr[cur]
            stats["kept_ramps"] += 1
    # highway-to-highway groups: keep them whole (they are decks, not tangles at grade)
    deck_only = set(by_group) - set(gnd_by)
    for w in np.flatnonzero(link):
        nd = net.vnode[net.start[w]]
        if lab[nd] in deck_only:
            keep_ways.add(w)
    slip = set(gnd_by) - set(by_group)
    stats["slip_groups"] = len(slip)
    drop -= keep_ways
    return drop, stats


def components(net, wmask):
    s = net.seg
    ok = wmask[net.wid[s]]
    a, b = net.vnode[s][ok], net.vnode[s + 1][ok]
    N = len(net.ids)
    G = coo_matrix((np.ones(len(a)), (a, b)), shape=(N, N))
    nc, lab = csgraph.connected_components(G, directed=False)
    used = np.zeros(N, bool)
    used[a] = used[b] = True
    return lab, used


# ---------------------------------------------------------------- snap

def through_lines(net, a, b):
    """Straight roads through each node: pairs of incident segments that run
    on opposite sides in nearly one line (one way passing through, or two
    ways meeting end to end). Returns node index, sorted, and unit axis."""
    d = net.npos[b] - net.npos[a]
    d /= np.maximum(np.hypot(*d.T), 1e-9)[:, None]
    node = np.r_[a, b]
    out = np.r_[d, -d]  # outward direction at each end
    o = np.argsort(node, kind="stable")
    node, out = node[o], out[o]
    an, ad = [], []
    maxdeg = int(np.bincount(node).max(initial=0))
    for off in range(1, maxdeg):
        i = np.arange(len(node) - off)
        j = i + off
        m = (node[i] == node[j]) & ((out[i] * out[j]).sum(1) <= -THROUGH_COS)
        an.append(node[i[m]])
        ad.append(out[i[m]])
    an = np.concatenate(an) if an else np.zeros(0, int)
    ad = np.vstack(ad) if ad else np.zeros((0, 2))
    o = np.argsort(an, kind="stable")
    return an[o], ad[o]


def snap(net, alive, twin_pairs):
    """Node index -> new position for merged junction clusters."""
    s = net.seg
    ok = alive[net.wid[s]]
    s = s[ok]
    a, b = net.vnode[s], net.vnode[s + 1]
    N = len(net.ids)
    deg = np.bincount(np.r_[a, b], minlength=N)
    junction = deg >= 3
    hard = np.zeros(N, bool)  # highway / link junctions stay put
    hw = np.isin(net.cls, DECK + LINKS)
    hard[net.vnode[np.flatnonzero(hw[net.wid] & alive[net.wid])]] = True
    # junction-to-junction pieces: walk each way, cutting at junctions
    w_of = net.wid[s]
    cut = junction[a] | (np.r_[True, w_of[1:] != w_of[:-1]])
    piece = np.cumsum(cut) - 1
    L = np.hypot(*(net.P[s + 1] - net.P[s]).T)
    plen = np.bincount(piece, L)
    p_start = a[cut]
    ends = np.r_[np.flatnonzero(cut)[1:] - 1, len(s) - 1]
    p_end = b[ends]
    p_way = w_of[cut]
    short = (plen <= SNAP) & junction[p_start] & junction[p_end] & (p_start != p_end) \
        & ~hard[p_start] & ~hard[p_end]
    k = np.flatnonzero(short)
    # never merge across a divided road: a piece whose ends sit on two twin halves
    W = len(net.ways)
    inc = coo_matrix((np.ones(2 * len(s)), (np.r_[a, b], np.r_[w_of, w_of])), shape=(N, W)).tocsr()
    inc.data[:] = 1
    if twin_pairs:
        tp = np.array(sorted(twin_pairs))
        T = coo_matrix((np.ones(2 * len(tp)), (np.r_[tp[:, 0], tp[:, 1]], np.r_[tp[:, 1], tp[:, 0]])),
                       shape=(W, W)).tocsr()
        across = np.asarray((inc[p_start[k]] @ T).multiply(inc[p_end[k]]).sum(1)).ravel() > 0
        k = k[~across]
    # a node only slides along the straight roads through it: the piece must
    # run along every through line at both of its ends
    ax_node, ax_dir = through_lines(net, a, b)
    chord = net.npos[p_end[k]] - net.npos[p_start[k]]
    chord /= np.maximum(np.hypot(*chord.T), 1e-9)[:, None]
    ok = np.ones(len(k), bool)
    for end in (p_start[k], p_end[k]):
        lo = np.searchsorted(ax_node, end, "left")
        hi = np.searchsorted(ax_node, end, "right")
        for off in range(int((hi - lo).max(initial=0))):
            has = lo + off < hi
            j = np.minimum(lo + off, len(ax_node) - 1)
            along = np.abs((ax_dir[j] * chord).sum(1)) >= THROUGH_COS
            ok &= ~has | along
    k = k[ok]
    G = coo_matrix((np.ones(len(k)), (p_start[k], p_end[k])), shape=(N, N))
    nc, lab = csgraph.connected_components(G, directed=False)
    sz = np.bincount(lab)
    member = sz[lab] >= 2
    cen = np.zeros((nc, 2))
    np.add.at(cen, lab[member], net.npos[member])
    cen[sz >= 2] /= sz[sz >= 2][:, None]
    moved = np.flatnonzero(member)
    rep = {}
    for c in np.unique(lab[moved]):
        nodes = moved[lab[moved] == c]
        rep.update({int(n): int(nodes.min()) for n in nodes})
    return {int(n): cen[lab[n]] for n in moved}, rep, int((sz >= 2).sum()), len(k)


def field(net, alive, newpos, fr):
    """Road samples every ROAD_STEP m with their displacement (linear along a
    segment between its moved/unmoved ends)."""
    s = net.seg
    s = s[alive[net.wid[s]]]
    a, b = net.vnode[s], net.vnode[s + 1]
    disp = np.zeros((len(net.ids), 2))
    for n, p in newpos.items():
        disp[n] = p - net.npos[n]
    # vertices that are not nodes shared with others still have a node index; fine
    L = np.hypot(*(net.P[s + 1] - net.P[s]).T)
    m = np.maximum(1, np.ceil(L / ROAD_STEP)).astype(int)
    rep = np.repeat(np.arange(len(s)), m)
    off = np.arange(m.sum()) - np.repeat(np.cumsum(m) - m, m)
    t = (off + 0.5) / m[rep]
    P = net.P[s][rep] + (net.P[s + 1] - net.P[s])[rep] * t[:, None]
    D = disp[a][rep] * (1 - t)[:, None] + disp[b][rep] * t[:, None]
    return P, D


def building_rings(data, fr):
    """Building ways with clean geometry: element list, flat xz, ring index."""
    own = [e for e in data["elements"] if e["type"] == "way" and e.get("geometry") and all(e["geometry"])]
    n = np.fromiter((len(e["geometry"]) for e in own), int, len(own))
    lon = np.fromiter((p["lon"] for e in own for p in e["geometry"]), float, n.sum())
    lat = np.fromiter((p["lat"] for e in own for p in e["geometry"]), float, n.sum())
    x, z = fr.xz(lon, lat)
    return own, np.c_[x, z], np.repeat(np.arange(len(own)), n), n


def clear_of_roads(X, ring, n, bi, shift, old_lines, new_lines):
    """A road that rotated about its far junction can swing a few metres
    through a corner building that only translated. Push such a building
    (clear of every road before, on one now) out along the road's normal."""
    sel = np.isin(ring, bi) & (n >= 4)[ring]
    if not sel.any():
        return 0
    ids = np.unique(ring[sel])
    inv = np.unique(ring[sel], return_inverse=True)[1]
    before = shapely.make_valid(shapely.polygons(shapely.linearrings(X[sel], indices=inv)))
    after = shapely.make_valid(shapely.polygons(shapely.linearrings(X[sel] + shift[ring[sel]], indices=inv)))
    hit = np.unique(shapely.STRtree(new_lines).query(after, predicate="intersects")[0])
    was = np.unique(shapely.STRtree(old_lines).query(before, predicate="intersects")[0])
    hit = np.setdiff1d(hit, was)
    for h in hit.tolist():  # a handful per parish
        b = ids[h]
        for _ in range(4):
            poly = shapely.make_valid(shapely.Polygon(X[ring == b] + shift[b]))
            q = shapely.STRtree(new_lines).query(poly, predicate="intersects")
            if not len(q):
                break
            line = new_lines[q[0]]
            c = np.asarray(poly.centroid.coords[0])
            foot = np.asarray(shapely.line_interpolate_point(line, shapely.line_locate_point(line, shapely.Point(c))).coords[0])
            nrm = c - foot
            if np.hypot(*nrm) < 1e-6:
                t = np.asarray(line.coords[-1]) - np.asarray(line.coords[0])
                nrm = np.array([-t[1], t[0]])
            nrm /= np.hypot(*nrm)
            V = X[ring == b] + shift[b]
            shift[b] += nrm * (max(0.0, float(-((V - foot) @ nrm).min())) + 1.0)
    return len(hit)


def move_buildings(path, fr, P, D, old_lines, new_lines):
    """Each building moves rigidly with its frontage road: the displacement
    of the road samples nearest its centroid, softly weighted so a corner
    building between two roads takes a blend."""
    data = load(path)
    own, X, ring, n = building_rings(data, fr)
    if not own:
        return data, 0, 0
    C = np.c_[np.bincount(ring, X[:, 0]), np.bincount(ring, X[:, 1])] / n[:, None]
    live = np.hypot(*D.T) > 1e-6
    if not live.any():
        return data, 0, 0
    near = cKDTree(P[live]).query(C, distance_upper_bound=BLD_REACH)[0] < np.inf
    bi = np.flatnonzero(near)
    if not len(bi):
        return data, 0, 0
    m = cKDTree(C[bi]).sparse_distance_matrix(cKDTree(P), BLD_REACH, output_type="coo_matrix")
    dmin = np.full(len(bi), np.inf)
    np.minimum.at(dmin, m.row, m.data)
    w = np.exp(-((m.data - dmin[m.row]) ** 2) / BLD_SIGMA ** 2)  # soft nearest: the frontage road wins
    ws = np.bincount(m.row, w, len(bi))
    d = np.c_[np.bincount(m.row, w * D[m.col, 0], len(bi)), np.bincount(m.row, w * D[m.col, 1], len(bi))]
    d = d.astype(float) / np.maximum(ws, 1e-12)[:, None]
    go = np.hypot(*d.T) >= 0.05
    bi, d = bi[go], d[go]
    shift = np.zeros((len(own), 2))
    shift[bi] = d
    pushed = clear_of_roads(X, ring, n, bi, shift, old_lines, new_lines)
    sel = np.isin(ring, bi)
    lo, la = fr.lonlat(*(X[sel] + shift[ring[sel]]).T)
    lo, la = np.round(lo, DP).tolist(), np.round(la, DP).tolist()
    starts = np.r_[0, np.cumsum(n[bi])[:-1]]
    for k, b in enumerate(bi.tolist()):
        e = own[b]
        sl = slice(starts[k], starts[k] + n[b])
        e["geometry"] = [{"lat": y, "lon": x} for y, x in zip(la[sl], lo[sl])]
        e.pop("bounds", None)
    return data, len(bi), pushed


def road_lines(els, fr, classes):
    rd = [e for e in els if is_road(e, classes)]
    n = [len(e["geometry"]) for e in rd]
    lon = np.fromiter((p["lon"] for e in rd for p in e["geometry"]), float, sum(n))
    lat = np.fromiter((p["lat"] for e in rd for p in e["geometry"]), float, sum(n))
    x, z = fr.xz(lon, lat)
    return shapely.linestrings(np.c_[x, z], indices=np.repeat(np.arange(len(rd)), n))


def on_roads(raw_dir, names, els, fr):
    """Buildings that a road centreline runs through."""
    lines = road_lines(els, fr, ROADS)
    tree = shapely.STRtree(lines)
    hits = 0
    for name in names:
        own, X, ring, n = building_rings(load(os.path.join(raw_dir, name)), fr)
        closed = n >= 4
        if not closed.any():
            continue
        sel = closed[ring]
        polys = shapely.polygons(shapely.linearrings(X[sel], indices=np.unique(ring[sel], return_inverse=True)[1]))
        polys = shapely.make_valid(polys)
        q = tree.query(polys, predicate="intersects")
        hits += len(np.unique(q[0]))
    return hits


def deck_access(els, fr):
    """Motorway/trunk ways that can be entered from, and left to, the ground
    network, following one-way directions."""
    ways = [e for e in els if is_road(e, ROADS + LINKS)]
    net = Net(ways, fr)
    s = net.seg
    a, b = net.vnode[s], net.vnode[s + 1]
    ow = np.array([w["tags"].get("oneway") for w in ways])[net.wid[s]]
    fwd = ow != "-1"
    bwd = ~np.isin(ow, ("yes", "1", "true"))  # two-way, or drawn backwards
    deck = np.isin(net.cls, DECK)[net.wid[s]]
    link = np.isin(net.cls, LINKS)[net.wid[s]]
    N = len(net.ids)
    ground = np.zeros(N + 1, bool)
    ground[net.vnode[~np.isin(net.cls, DECK + LINKS)[net.wid]]] = True
    up = deck | link  # the ramp/deck subgraph; ground nodes are the sources
    src = np.r_[a[up & fwd], b[up & bwd]]
    dst = np.r_[b[up & fwd], a[up & bwd]]
    g = np.flatnonzero(ground[:N])
    src, dst = np.r_[src, np.full(len(g), N)], np.r_[dst, g]  # virtual source N -> every ground node
    G = coo_matrix((np.ones(len(src)), (src, dst)), shape=(N + 1, N + 1)).tocsr()
    into = np.zeros(N + 1, bool)
    into[csgraph.breadth_first_order(G, N, directed=True, return_predecessors=False)] = True
    src2, dst2 = np.r_[dst[:-len(g)] if len(g) else dst, np.full(len(g), N)], np.r_[src[:-len(g)] if len(g) else src, g]
    G2 = coo_matrix((np.ones(len(src2)), (src2, dst2)), shape=(N + 1, N + 1)).tocsr()
    out = np.zeros(N + 1, bool)
    out[csgraph.breadth_first_order(G2, N, directed=True, return_predecessors=False)] = True
    dw = net.wid[s][deck]  # per carriageway way: some vertex reachable
    ways_ = np.unique(dw)
    enter = np.unique(dw[into[a[deck]] | into[b[deck]]])
    leave = np.unique(dw[out[a[deck]] | out[b[deck]]])
    return {"ways": len(ways_), "enterable": len(enter), "leavable": len(leave)}


def apply_snap(els, fr, nid_new, nid_rep):
    """Move merged nodes to their cluster point and give them one id. The
    vertices between two nodes that merged (the jog itself) go, so no spur
    is left behind."""
    out, changed = [], 0
    for e in els:
        nodes = e.get("nodes")
        if not (nodes and any(n in nid_new for n in nodes) and e.get("geometry")
                and len(e["geometry"]) == len(nodes) and all(e["geometry"])):
            out.append(e)
            continue
        g, nn = [], []
        closed = nodes[0] == nodes[-1]
        for t, (n, p) in enumerate(zip(nodes, e["geometry"])):
            if closed and t == len(nodes) - 1:
                n, p = nn[0], g[0]  # a ring closes on its (possibly moved) start
                if nn[-1] != n:
                    nn.append(n)
                    g.append(p)
                continue
            if n in nid_new:
                lo, la = fr.lonlat(*nid_new[n])
                p = {"lat": round(float(la), DP), "lon": round(float(lo), DP)}
                n = nid_rep.get(n, n)
                if n in nn and nid_rep.get(n) is not None:  # back at a merged node: cut the jog
                    k = nn.index(n)
                    del nn[k + 1:], g[k + 1:]
                    continue
            if nn and nn[-1] == n:
                continue
            nn.append(n)
            g.append(p)
        changed += 1
        if len(nn) < 2:
            continue  # a way that was only the jog itself
        e = dict(e, nodes=nn, geometry=g)
        e.pop("bounds", None)
        out.append(e)
    return out, changed


def stranded(net, alive):
    """Node indices of kept roads cut off from the rest of their old network."""
    before, _ = components(net, np.ones(len(net.ways), bool))
    after, _ = components(net, alive)
    keep = np.zeros(len(net.ids), bool)
    keep[net.vnode[alive[net.wid]]] = True
    k = np.flatnonzero(keep)
    # the largest after-component inside each before-component is the body
    pair = before[k] * (after.max() + 1) + after[k]
    u, cnt = np.unique(pair, return_counts=True)
    o = np.lexsort((-cnt, u // (after.max() + 1)))
    u = u[o]
    body = u[np.r_[True, (u[1:] // (after.max() + 1)) != (u[:-1] // (after.max() + 1))]]
    return k[~np.isin(pair, body)]


def link_dead_ends(net, alive):
    """Node indices where a kept link road just stops."""
    s = net.seg
    s = s[alive[net.wid[s]]]
    a, b = net.vnode[s], net.vnode[s + 1]
    deg = np.bincount(np.r_[a, b], minlength=len(net.ids))
    lk = np.isin(net.cls, LINKS)[net.wid[s]]
    ends = np.unique(np.r_[a[lk], b[lk]])
    return ends[deg[ends] == 1]


def reconnect(net, alive):
    """Give back dropped links that were the only way to reach a kept road
    (a residential stub off a slip lane), or whose loss leaves a kept ramp
    ending in mid air. Grows from that side until neither is left."""
    alive = alive.copy()
    restored = 0
    dead0 = link_dead_ends(net, np.ones(len(net.ways), bool))
    while True:
        lost = np.r_[stranded(net, alive), np.setdiff1d(link_dead_ends(net, alive), dead0)]
        if not len(lost):
            return alive, restored
        hit = np.isin(net.vnode, lost) & ~alive[net.wid]
        ws = np.unique(net.wid[hit])
        if not len(ws):
            return alive, restored  # nothing left to give back; the gate reports it
        alive[ws] = True
        restored += len(ws)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("raw")
    ap.add_argument("out")
    ap.add_argument("--no-snap", action="store_true")
    ap.add_argument("--no-ramps", action="store_true")
    ap.add_argument("--no-medians", action="store_true")
    a = ap.parse_args()
    if os.path.normcase(os.path.abspath(a.out)) == os.path.normcase(os.path.abspath(a.raw)):
        sys.exit("junctions: out must not be the raw dir")
    os.makedirs(a.out, exist_ok=True)
    feats = load(os.path.join(a.raw, "features.json"))
    els = feats["elements"]
    road_idx = [k for k, e in enumerate(els) if is_road(e, ROADS + LINKS)]
    ways = [els[k] for k in road_idx]
    fr = frame_of(ways)
    net = Net(ways, fr)
    gate = {"pass": True}

    pair_set, quads = twins(net)
    gate["twin_pairs"] = len(pair_set)

    alive = np.ones(len(ways), bool)
    if not a.no_ramps:
        drop, st = ramps(net)
        alive[list(drop)] = False
        alive, restored = reconnect(net, alive)
        split = len(stranded(net, alive))
        st["new_dead_ends"] = int(len(np.setdiff1d(link_dead_ends(net, alive),
                                                   link_dead_ends(net, np.ones(len(ways), bool)))))
        split += st["new_dead_ends"]
        st["restored_links"] = restored
        drop = set(np.flatnonzero(~alive).tolist())
        lk = np.isin(net.cls, LINKS)
        km0 = sum(np.hypot(*np.diff(net.way_pts(i), axis=0).T).sum() for i in np.flatnonzero(lk)) / 1000
        km1 = sum(np.hypot(*np.diff(net.way_pts(i), axis=0).T).sum() for i in np.flatnonzero(lk & alive)) / 1000
        gate["ramps"] = dict(st, link_km_before=round(km0, 1), link_km_after=round(km1, 1),
                             dropped_ways=len(drop), split_components=split)
        if split:
            gate["pass"] = False

    # apply the ramp cut
    drop_ids = {ways[i]["id"] for i in np.flatnonzero(~alive)}
    out_els = [e for e in els if not (e["type"] == "way" and e.get("id") in drop_ids
                                      and e.get("tags", {}).get("highway") in LINKS)]

    # snap to a fixed point: a merge can bring the next junction within SNAP
    resolve = {}  # original node id -> the id it merged into
    pos = {}  # node id -> final position
    nclus = npieces = changed = rounds = 0
    while not a.no_snap and rounds < SNAP_ROUNDS:
        cur = Net([e for e in out_els if is_road(e, ROADS + LINKS)], fr)
        newpos, rep, c, p = snap(cur, np.ones(len(cur.ways), bool), twins(cur)[0])
        if not newpos:
            break
        rounds += 1
        nclus, npieces = nclus + c, npieces + p
        nid_new = {int(cur.ids[n]): q for n, q in newpos.items()}
        nid_rep = {int(cur.ids[n]): int(cur.ids[r]) for n, r in rep.items()}
        for n, r in nid_rep.items():
            resolve[n] = r
            pos[r] = nid_new[r]
        out_els, ch = apply_snap(out_els, fr, nid_new, nid_rep)
        changed += ch
    final = {}
    for n in resolve:
        r = n
        while r in resolve and resolve[r] != r:
            r = resolve[r]
        final[n] = pos[r]
    id_index = {int(v): k for k, v in enumerate(net.ids)}
    newpos = {id_index[n]: q for n, q in final.items() if n in id_index}
    gate["snap"] = {"rounds": rounds, "clusters": nclus, "pieces": npieces, "ways_changed": changed,
                    "max_move_m": round(max((float(np.hypot(*(q - net.npos[n]))) for n, q in newpos.items()),
                                            default=0.0), 2)}

    if not a.no_medians:
        roads_now = [e for e in out_els if is_road(e, ROADS + LINKS)]
        lines = []
        for e in roads_now:
            x, z = fr.xz([p["lon"] for p in e["geometry"]], [p["lat"] for p in e["geometry"]])
            lines.append(np.c_[x, z])
        ix = np.repeat(np.arange(len(lines)), [len(l) for l in lines])
        surf = shapely.union_all(shapely.buffer(shapely.linestrings(np.vstack(lines), indices=ix), 2.0, quad_segs=2))
        med, area = median_ways(quads, fr, surf)
        out_els.extend(med)
        gate["medians"] = {"strips": len(med), "area_m2": round(area), "quads": len(quads)}
        if med:  # gate: green never lies on a road centreline
            rings = [np.c_[fr.xz(np.array([p["lon"] for p in m["geometry"]]), np.array([p["lat"] for p in m["geometry"]]))]
                     for m in med]
            ix = np.repeat(np.arange(len(rings)), [len(r) for r in rings])
            gp = shapely.make_valid(shapely.polygons(shapely.linearrings(np.vstack(rings), indices=ix)))
            on = shapely.STRtree(road_lines(out_els, fr, ROADS + LINKS)).query(gp, predicate="intersects")
            gate["medians"]["on_roads"] = int(len(np.unique(on[0])))
            if len(on[0]):
                gate["pass"] = False

    feats = dict(feats, elements=out_els)
    write_file(os.path.join(a.out, "features.json"), feats)

    # buildings follow the roads
    P, D = field(net, alive, newpos, fr)
    old_lines, new_lines = road_lines(els, fr, ROADS), road_lines(out_els, fr, ROADS)
    nb = npush = 0
    blds = []
    for name in sorted(os.listdir(a.raw)):
        src = os.path.join(a.raw, name)
        if name == "features.json" or not os.path.isfile(src):
            continue
        if name.startswith("bld_") and name.endswith(".json"):
            blds.append(name)
        if name.startswith("bld_") and name.endswith(".json") and newpos:
            data, m, pu = move_buildings(src, fr, P, D, old_lines, new_lines)
            write_file(os.path.join(a.out, name), data)
            nb += m
            npush += pu
        else:
            shutil.copyfile(src, os.path.join(a.out, name))
    gate["snap"]["buildings_moved"] = nb
    gate["snap"]["buildings_pushed_off_roads"] = npush

    # gate: decks stay reachable both ways
    d0, d1 = deck_access(els, fr), deck_access(out_els, fr)
    gate["decks"] = {"before": d0, "after": d1}
    if d1["enterable"] < d0["enterable"] or d1["leavable"] < d0["leavable"]:
        gate["pass"] = False
    # gate: moving buildings must not push them onto roads
    o0, o1 = on_roads(a.raw, blds, els, fr), on_roads(a.out, blds, out_els, fr)
    gate["buildings_on_roads"] = {"before": o0, "after": o1}
    if o1 > o0:
        gate["pass"] = False
    # gate: no snappable piece left
    if newpos:
        n2 = Net([e for e in out_els if is_road(e, ROADS + LINKS)], fr)
        _, _, c2, p2 = snap(n2, np.ones(len(n2.ways), bool), twins(n2)[0])
        gate["snap"]["left_after"] = p2
        if p2:
            gate["pass"] = False
    with open(os.path.join(a.out, "junctions.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(gate, f, indent=1)
    print(json.dumps(gate, indent=1))
    sys.exit(0 if gate["pass"] else 1)


if __name__ == "__main__":
    main()
