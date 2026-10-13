"""Deck heights as one system of difference constraints, solved whole.

Every rule the heights follow is a bound between two nodes or on one:
  - a pinned street intersection stands on the ground, and a ramp leaving
    one climbs no steeper than its grade once FOOT past it (an upper bound);
  - along a road, neighbours differ by at most grade times their distance;
  - where a bridge crosses another road, each node of the lower road under
    the upper's footprint stands clear below the upper's nodes over it;
  - nothing stands below the ground.

The greatest heights meeting every upper bound are found first. A node
forced below the ground means the rules contradict each other there; the
chain of bounds that forced it (back to a pinned node, or round a loop of
crossings) is the certificate, and only the rules on it are relaxed: its
roads first climb more steeply, up to GRADE_MAX, standing in for ramps OSM
maps shorter than they are, and only what that cannot make up comes off the
clearance of its crossings, shared evenly and reported. Then the least
heights meeting every lower bound (bridges at their layer, uppers clear of
their lowers) are found below those, smoothed, and pulled back inside the
bounds after every round of smoothing, so smoothing never undoes a
crossing's clearance.
"""
import heapq
import math

import numpy as np
import scipy.sparse
import scipy.sparse.csgraph


def _key(a, b):
    return (a, b) if a < b else (b, a)


def solve(adj, pinned, wanted, pairs, n, grade, grade_max, clear, foot, smooth_rounds, log=print, ties=()):
    """Heights for n nodes.

    adj: per node, [(other, metres)], level edges 0 metres.
    pinned: nodes on the ground.
    wanted: node -> the height its bridge would stand at.
    pairs: per crossing, (label, [(lower node or -1 for the ground, upper node)]).
    ties: edges of no length in adj that only tie decks side by side flush;
    the softest rule, so a contradiction through one drops it first. Dropped
    ties come out of adj itself.
    Returns (height, clear per crossing, report lines)."""
    pinned = list(pinned)
    pinset = set(pinned)
    ties = list(ties)
    g, clr, report, untied = {}, [clear] * len(pairs), [], []
    # Every chain of bounds that forces a node below the ground runs
    # through a crossing, and pinned nodes stand still, so the network
    # falls apart at its pinned nodes into parts that relax alone, and a
    # part with no crossing never needs to. Relaxing the whole network once
    # per contradiction made the parish take hours.
    for nodes, ks in _parts(adj, pinned, pairs, n):
        at = {v: m for m, v in enumerate(nodes)}
        sadj = [[(at[b], d) for b, d in adj[v] if b in at] for v in nodes]
        spairs = [(pairs[k][0], [(at[lo] if lo >= 0 else -1, at[up]) for lo, up in pairs[k][1]]) for k in ks]
        sties = [(at[a], at[b]) for a, b in ties if a in at and b in at]
        sg, sclr, srep, sun = _relax(sadj, [at[v] for v in nodes if v in pinset], spairs, len(nodes),
                                     grade, grade_max, clear, foot, sties, log)
        g.update({_key(nodes[a], nodes[b]): v for (a, b), v in sg.items()})
        for k, c in zip(ks, sclr):
            clr[k] = c
        report.extend(srep)
        for a, b in sun:
            a, b = nodes[a], nodes[b]
            adj[a].remove((b, 0.0))
            adj[b].remove((a, 0.0))
            untied.append((a, b))
    land = _landing(adj, pinned, n, foot)
    ups = _uppers(pairs)
    U, _ = _greatest(adj, pinned, n, _uppers(pairs), clr,
                     lambda a, b, d: g.get(_key(a, b), grade) * (d - land.get(_key(a, b), 0.0)))
    steep = sum(1 for v in g.values() if v > grade + 1e-9)
    if untied:
        log("heights: %d ties side by side dropped, each on a chain of bounds that could not be met" % len(untied))
    for deficit, run, new, rest, labels in report:
        log("heights: %.2f m short over %.0f m of road at %s: grade %.3f%s" % (
            deficit, run, labels, new, (", clearance %.2f m less" % (rest / max(1, len(labels)))) if rest > 1e-6 else ""))
    log("heights: %d contradictions, %d edges steeper than %.2f (steepest %.3f), %d crossings with less than %.1f m" % (
        len(report), steep, grade, max(g.values(), default=grade), sum(c < clear - 1e-6 for c in clr), clear))

    # Least heights: each bridge at its layer as far as its bounds allow,
    # ramping down from there, and every upper clear of its lowers.
    L = np.zeros(n)
    for i, t in wanted.items():
        L[i] = max(L[i], min(t, U[i]))
    heap = [(-L[i], i) for i in range(n) if L[i] > 0]
    heapq.heapify(heap)
    # Every contradiction was relaxed above, so this settles; if one slipped
    # through, uppers and lowers would lift each other without end.
    for rounds in range(1000):
        while heap:
            v, i = heapq.heappop(heap)
            v = -v
            if v < L[i]:
                continue
            for j, d in adj[i]:
                w = v - g.get(_key(i, j), grade) * d
                if w > L[j] + 1e-9:
                    L[j] = w
                    heapq.heappush(heap, (-w, j))
        changed = False
        for up, pp in ups.items():
            need = max((L[lo] if lo >= 0 else 0.0) + clr[k] for k, lo in pp)
            need = min(need, U[up]) if all(lo < 0 for _, lo in pp) else need
            if need > L[up] + 1e-9:
                L[up] = need
                heapq.heappush(heap, (-need, up))
                changed = True
        if not changed:
            break
    else:
        log("heights: the least solve did not settle in %d rounds: a contradiction was missed" % (rounds + 1))
    over = int((L > U + 1e-6).sum())
    if over:
        log("heights: %d nodes above their greatest bound after the least solve (max %.2f m)" % (over, float((L - U).max())))

    # Smoothing, pulled back inside the bounds after every round.
    pk = np.array([k for k, (_, pp) in enumerate(pairs) for _ in pp], int)
    plo = np.array([lo for _, pp in pairs for lo, _ in pp], int)
    pup = np.array([up for _, pp in pairs for _, up in pp], int)
    pc = np.array(clr)[pk] if len(pk) else np.zeros(0)
    ground = plo < 0
    Uf = np.where(np.isfinite(U), U, np.inf)
    ea, eb, ew = [], [], []
    for a in range(n):
        for b, d in adj[a]:
            if a < b:
                ea.append(a)
                eb.append(b)
                ew.append(1.0 / max(d, 1.0))
    ea, eb, ew = np.array(ea, int), np.array(eb, int), np.array(ew)
    den = np.bincount(ea, ew, n) + np.bincount(eb, ew, n)
    free = den > 0
    free[pinned] = False
    # Nodes joined by edges of no length (rungs between decks side by side,
    # level stretches at a junction) are one surface. Smoothing and the
    # projection both work on one height per group, held at its root, so
    # the group can never come apart.
    root = np.arange(n)

    def find(i):
        while root[i] != i:
            root[i] = root[root[i]]
            i = root[i]
        return i

    for a in range(n):
        for b, d in adj[a]:
            if d == 0 and a < b:
                ra, rb = find(a), find(b)
                if ra != rb:
                    root[max(ra, rb)] = min(ra, rb)
    root = np.array([find(i) for i in range(n)])
    size = np.bincount(root, minlength=n)
    grouped = size[root] > 1
    Ug = np.full(n, np.inf)
    np.minimum.at(Ug, root, Uf)
    pin = np.unique(root[np.array(pinned, int)]) if len(pinned) else np.zeros(0, int)
    gup = root[pup]
    glo = np.where(ground, -1, root[np.maximum(plo, 0)])
    same = (~ground) & (glo == gup)
    if same.any():
        log("heights: %d crossing node pairs inside one flush group, dropped" % int(same.sum()))
    keep = ~same
    gup, glo, gc, gground = gup[keep], glo[keep], pc[keep], ground[keep]

    # Edges between groups, and how far each may rise over its length.
    out = root[ea] != root[eb]
    xa, xb, xw = root[ea[out]], root[eb[out]], ew[out]
    xd = np.array([next(x for y, x in adj[a] if y == b) for a, b in zip(ea[out], eb[out])]) if out.any() else np.zeros(0)
    xr = np.array([g.get(_key(a, b), grade) for a, b in zip(ea[out], eb[out])]) * xd

    def graded(h):
        """Pulls down whatever stands steeper above a neighbour than its
        grade lets it; smoothing alone keeps no grade."""
        for _ in range(200):
            c = h.copy()
            np.minimum.at(c, xb, h[xa] + xr)
            np.minimum.at(c, xa, h[xb] + xr)
            if (c >= h - 1e-9).all():
                return h
            h = c
        return h

    # L meets every bound, so it is the floor: the grade pull-down and the
    # lowers coming down both keep above a floor that meets them, and the
    # loop below settles instead of trading clearance for grade.
    Lg = np.full(n, -np.inf)
    np.maximum.at(Lg, root, L)
    Lg = np.minimum(np.maximum(Lg, 0.0), Ug)

    def project(h):
        bad = 0
        for _ in range(100):
            h = np.clip(h, Lg, Ug)
            h[pin] = 0.0
            if len(gup):
                base = np.where(gground, 0.0, h[np.maximum(glo, 0)])
                # Uppers rise as far as their bounds let them, ...
                np.maximum.at(h, gup, np.minimum(base + gc, Ug[gup]))
                # ... and lowers come down the rest.
                m = ~gground
                np.minimum.at(h, glo[m], h[gup[m]] - gc[m])
            h = graded(np.clip(h, Lg, Ug))
            h[pin] = 0.0
            base = np.where(gground, 0.0, h[np.maximum(glo, 0)]) if len(gup) else np.zeros(0)
            bad = int(((h[gup] - base) < gc - 1e-6).sum())
            steep = len(xa) and bool((np.abs(h[xa] - h[xb]) > xr + 1e-6).any())
            if not bad and not steep:
                return h, 0
        return h, bad

    # A group smooths as one node: its members' neighbours outside it,
    # pooled; edges inside it carry no weight.
    gden = np.bincount(xa, xw, n) + np.bincount(xb, xw, n)
    gfree = gden > 0
    gfree[pin] = False
    gfree &= root == np.arange(n)
    H = np.full(n, -np.inf)
    np.maximum.at(H, root, L)
    H, _ = project(H)
    bad = 0
    for _ in range(smooth_rounds):
        avg = (np.bincount(xa, xw * H[xb], n) + np.bincount(xb, xw * H[xa], n)) / np.maximum(gden, 1e-12)
        H[gfree] += 0.5 * (avg[gfree] - H[gfree])
        H, bad = project(H)
    h = H[root]
    hi = np.full(n, -np.inf)
    np.maximum.at(hi, root, h)
    lo_ = np.full(n, np.inf)
    np.minimum.at(lo_, root, h)
    gap = (hi - lo_)[np.unique(root[grouped])] if grouped.any() else np.zeros(0)
    log("heights: %d groups of nodes tied flush, %d of them more than 0.05 m apart (most %.2f m)" % (
        len(gap), int((gap > 0.05).sum()), float(gap.max()) if len(gap) else 0.0))
    def short(v):
        if not len(gup):
            return 0, 0.0
        sh = gc - (v[gup] - np.where(gground, 0.0, v[np.maximum(glo, 0)]))
        return int((sh > 1e-6).sum()), float(max(sh.max(), 0.0))
    log("heights: after smoothing %d node pairs short of their clearance (most %.2f m; %d short before, most %.2f m), %d nodes above their bound" % (
        *short(H), *short(Lg), int((h > Uf + 1e-6).sum())))
    kinks = 0
    if len(ea):
        d = np.array([next(x for y, x in adj[a] if y == b) for a, b in zip(ea, eb)])
        slope = np.abs(h[ea] - h[eb]) / np.maximum(d, 1e-9)
        lim = np.array([g.get((a, b), grade) for a, b in zip(ea, eb)])
        kinks = int(((slope > lim + 1e-3) & (d > 1.0)).sum())
        log("heights: %d edges steeper than their grade after smoothing, steepest %.3f" % (kinks, float(slope[d > 1.0].max())))
    return h, clr, U



def _relax(adj, pinned, pairs, n, grade, grade_max, clear, foot, ties, log):
    """The contradiction loop of solve() on one part of the network: the
    relaxed grades, the clearances, the report and the ties dropped."""
    pinned = list(pinned)
    ties = {_key(a, b) for a, b in ties}
    g = {}  # relaxed grade per edge, (a, b) -> rise over run
    land = {}  # metres of an edge that are landing, (a, b) -> m

    ea, eb, ed = _edges(adj, n)
    alive = np.ones(len(ea), bool)
    flush = {}  # (a, b) -> indices of that 0 m edge, in adj's order
    for e in np.flatnonzero(ed == 0).tolist():
        flush.setdefault((int(ea[e]), int(eb[e])), []).append(e)

    def landing():
        land.clear()
        land.update(_landing(adj, pinned, n, foot, (ea[alive], eb[alive], ed[alive])))
    landing()
    clr = [clear] * len(pairs)
    ups = _uppers(pairs)

    def weight(a, b, d):
        e = _key(a, b)
        return g.get(e, grade) * (d - land.get(e, 0.0))

    def greatest():
        return _greatest(adj, pinned, n, ups, clr, weight)

    def certificate(j, U, pred):
        """The chain of bounds that forced node j below the ground: grade
        edges [(a, b, metres)], crossings [k], and its deficit."""
        path, seen, c = [], {}, j
        while pred[c] is not None and c not in seen:
            seen[c] = len(path)
            kind, i, x = pred[c]
            path.append((kind, i, c, x))
            c = i
        if c in seen:
            path = path[seen[c]:]
            total = sum(weight(a, b, x) if k == "g" else -clr[x] for k, a, b, x in path)
            deficit = max(-total, 0.05)
        else:
            deficit = -U[j]
        edges = [(a, b, x) for k, a, b, x in path if k == "g"]
        cross = sorted({x for k, _, _, x in path if k == "c"})
        return edges, cross, deficit

    report, untied = [], []
    for it in range(2000):
        U, pred = greatest()
        low = np.flatnonzero(U < -1e-6)
        if not len(low):
            break
        j = int(low[np.argmin(U[low])])
        edges, cross, deficit = certificate(j, U, pred)
        cut = {_key(a, b) for a, b, d in edges if d == 0 and _key(a, b) in ties}
        if cut:
            # A ramp held flush beside its road has no length left to climb
            # before a crossing: it climbs beside it instead.
            for a, b in cut:
                adj[a].remove((b, 0.0))
                adj[b].remove((a, 0.0))
                for e in (a, b), (b, a):
                    alive[next(i for i in flush[e] if alive[i])] = False
            ties -= cut
            untied.extend(cut)
            landing()
            continue
        run = sum(d - land.get(_key(a, b), 0.0) for a, b, d in edges)
        now = max((g.get(_key(a, b), grade) for a, b, _ in edges), default=grade)
        new = min(grade_max, now + deficit / run) if run > 0 else now
        for a, b, _ in edges:
            g[_key(a, b)] = max(g.get(_key(a, b), grade), new)
        rest = deficit - (new - now) * run
        if rest > 1e-6:
            if not cross:
                log("heights: a pinned node is held below the ground with no crossing to blame, at node %d" % j)
                break
            for k in cross:
                clr[k] = max(0.0, clr[k] - rest / len(cross))
        report.append((deficit, run, new, rest, [pairs[k][0] for k in cross]))
    return g, clr, report, untied


def _parts(adj, pinned, pairs, n):
    """The parts of the network that hold a crossing, each as (its nodes,
    its crossings): nodes joined by a road with no pinned node between,
    or by a crossing, plus the pinned nodes at its edge."""
    pin = np.zeros(n, bool)
    pin[list(pinned)] = True
    root = list(range(n))

    def find(i):
        while root[i] != i:
            root[i] = root[root[i]]
            i = root[i]
        return i

    def join(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            root[max(ra, rb)] = min(ra, rb)

    for a in range(n):
        if not pin[a]:
            for b, _ in adj[a]:
                if not pin[b]:
                    join(a, b)
    for _, pp in pairs:
        for lo, up in pp:
            if lo >= 0:
                join(lo, up)
    ks = {}
    for k, (_, pp) in enumerate(pairs):
        if pp:
            ks.setdefault(find(pp[0][1]), []).append(k)
    members = {r: [] for r in ks}
    for v in range(n):
        r = find(v)
        if r in members:
            members[r].append(v)
    out = []
    for r, mem in members.items():
        edge = {b for v in mem if not pin[v] for b, _ in adj[v] if pin[b]}
        out.append((sorted(set(mem) | edge), ks[r]))
    return out


def _uppers(pairs):
    """Per upper node, [(crossing, lower node)]."""
    ups = {}
    for k, (_, pp) in enumerate(pairs):
        for lo, up in pp:
            ups.setdefault(up, []).append((k, lo))
    return ups


def _landing(adj, pinned, n, foot, edges=None):
    """How far each edge's first FOOT metres off an intersection reach
    into it: the landing, which climbs nothing. (a, b) -> metres. edges is
    adj as _edges() arrays, if the caller keeps them."""
    a, b, d = _edges(adj, n) if edges is None else edges
    dpin = _dist(adj, {i: 0.0 for i in pinned}, n, (a, b, d))
    keep = (a < b) & (d > 0)
    a, b, d = a[keep], b[keep], d[keep]
    far = np.maximum(dpin[a], dpin[b])
    with np.errstate(invalid="ignore"):
        land = np.where(np.isfinite(far), d - np.minimum(d, np.maximum(0.0, far - foot)), 0.0)
    return dict(zip(zip(a.tolist(), b.tolist()), land.tolist()))


def _greatest(adj, pinned, n, ups, clr, weight):
    """The greatest heights under every upper bound, not clamped at the
    ground, and for each node the bound that set it. Stops at the first
    node forced below the ground."""
    U = np.full(n, np.inf)
    pred = [None] * n
    for i in pinned:
        U[i] = 0.0
    heap = [(0.0, i) for i in pinned]
    heapq.heapify(heap)
    while heap:
        u, i = heapq.heappop(heap)
        if u > U[i]:
            continue
        if u < -1e-6:
            break  # below the ground: the rules contradict each other here
        for j, d in adj[i]:
            v = u + weight(i, j, d)
            if v < U[j] - 1e-9:
                U[j] = v
                pred[j] = ("g", i, d)
                heapq.heappush(heap, (v, j))
        # A road over this one holds it down; this one, over a road,
        # holds that one down.
        for k, lo in ups.get(i, ()):
            if lo >= 0:
                v = u - clr[k]
                if v < U[lo] - 1e-9:
                    U[lo] = v
                    pred[lo] = ("c", i, k)
                    heapq.heappush(heap, (v, lo))
    return U, pred

def pairs_for(crossings, stretch, pos, order, pad, label):
    """Per crossing, its label and the (lower, upper) node pairs it bounds:
    each node of the lower road under the upper's footprint, with each node
    of the upper within half the two widths of it, and a pad. Under a
    railway the lower is the ground, -1. Two bridges of one layer are
    sorted once, by order (heights solved without any crossing)."""
    out = []
    for up, lo, xy, sin in crossings:
        if lo[3] >= 0 and up[2] == lo[2] and _near(order, stretch(lo, xy, 1.0), pos, xy) > _near(order, stretch(up, xy, 1.0), pos, xy):
            up, lo = lo, up
        cos = math.sqrt(max(0.0, 1.0 - sin * sin))
        ui = stretch(up, xy, (lo[5] + up[5] * cos) / 2 / max(sin, 0.2) + pad)
        if lo[3] < 0:
            out.append((label(up, lo), [(-1, i) for i in ui]))
            continue
        li = stretch(lo, xy, (up[5] + lo[5] * cos) / 2 / max(sin, 0.2) + pad)
        r = (up[5] + lo[5]) / 2 + pad + 2.5  # and half a STEP, between nodes
        pp = [(j, i) for j in li for i in ui if float(np.hypot(*(pos[i] - pos[j]))) <= r]
        if not pp:
            pp = [(min(li, key=lambda j: float(np.hypot(*(pos[j] - xy)))), min(ui, key=lambda i: float(np.hypot(*(pos[i] - xy)))))]
        out.append((label(up, lo), pp))
    return out


def _near(h, ids, pos, xy):
    return float(np.mean([h[i] for i in ids]))


def _edges(adj, n):
    """The network as arrays: from, to, metres, in adj's own order."""
    cnt = np.fromiter((len(x) for x in adj), np.int64, n)
    flat = [e for x in adj for e in x]
    b = np.fromiter((e[0] for e in flat), np.int64, len(flat))
    d = np.fromiter((e[1] for e in flat), float, len(flat))
    return np.repeat(np.arange(n), cnt), b, d


def _dist(adj, sources, n, edges=None):
    """Shortest distance from any source, each starting at its own offset
    (scipy's Dijkstra, through one extra node joined to every source)."""
    a, b, d = _edges(adj, n) if edges is None else edges
    src = np.fromiter(sources.keys(), np.int64, len(sources))
    off = np.fromiter(sources.values(), float, len(sources))
    if not len(src):
        return np.full(n, np.inf)
    base = off.min()
    rows = np.concatenate([a, np.full(len(src), n)])
    cols = np.concatenate([b, src])
    data = np.concatenate([d, off - base])
    order = np.argsort(rows, kind="stable")
    indptr = np.searchsorted(rows[order], np.arange(n + 2))
    g = scipy.sparse.csr_matrix((data[order], cols[order], indptr), shape=(n + 1, n + 1))
    return scipy.sparse.csgraph.dijkstra(g, directed=True, indices=n)[:n] + base
