"""Thins a city's minor streets the SMT way: through-streets only, and few
enough of them that every block is a big one.

The kept network (major roads, rail, canals, decks) and the minor streets
are noded into one planar graph; its faces are the blocks. A minor street
is cut into runs, one per stretch of one named street between two crossings
of the kept network, so a street goes or stays across a whole superblock
and the grid that is left stays a grid. The smallest block under MIN_BLOCK
loses the run on its edge to its smallest neighbour, merging the two, until
no block is under it or none has a minor street left to lose. Last, every
piece with one block on both sides (a dead end, or a street to nowhere) and
every piece not joined to the kept network goes.

Also handed back: the streets that went from between two of the blocks
they started as, and those blocks, so the buildings can still show the
city's real blocks where the walkable streets no longer do.
"""
import heapq

import numpy as np
import scipy.sparse
import shapely
from scipy.sparse.csgraph import connected_components

MIN_BLOCK = 300.0 * 300.0  # m2: a block smaller than this loses a street


def prune(fixed, minor, names, min_block=MIN_BLOCK):
    """fixed, minor: lists of coordinate lists; names: per minor line its
    street name or None. Returns the minor streets kept and those dropped
    from between two blocks, as coordinate arrays; the blocks as they were
    before any merging, as polygons; and the number of blocks before and
    after."""
    nf = len(fixed)
    src = np.array([shapely.LineString(l) for l in list(fixed) + list(minor)], dtype=object)
    if not len(minor):
        return [], [], np.array([], dtype=object), 0, 0
    edges = shapely.get_parts(shapely.node(shapely.multilinestrings(src)))
    edges = edges[shapely.length(edges) > 1e-6]
    ne = len(edges)

    # Each piece's source line: a fixed one where they overlap.
    mid = shapely.line_interpolate_point(edges, 0.5, normalized=True)
    tree = shapely.STRtree(src)
    qi, qs = tree.query(mid, predicate="dwithin", distance=1e-6)
    of = np.full(ne, np.iinfo(np.int64).max)
    np.minimum.at(of, qi, qs)
    miss = of == np.iinfo(np.int64).max
    if miss.any():
        of[miss] = tree.query_nearest(mid[miss], all_matches=False)[1]
    is_minor = of >= nf

    # Nodes: the pieces' ends.
    ends = np.concatenate([shapely.get_coordinates(shapely.get_point(edges, 0)),
                           shapely.get_coordinates(shapely.get_point(edges, -1))])
    _, node = np.unique(np.round(ends, 6), axis=0, return_inverse=True)
    node = node.reshape(2, ne)
    nn = int(node.max()) + 1

    # Pieces not joined to the kept network go.
    g = scipy.sparse.coo_matrix((np.ones(ne), (node[0], node[1])), shape=(nn, nn))
    _, comp = connected_components(g, directed=False)
    keep_comp = np.zeros(comp.max() + 1, bool)
    keep_comp[comp[node[0][~is_minor]]] = True
    alive = keep_comp[comp[node[0]]]

    # The blocks, and each piece's block on either side (-1 outside all).
    faces = shapely.get_parts(shapely.polygonize(edges[alive]))
    area = np.append(shapely.area(faces), np.inf)  # the last is the outside
    outside = len(faces)
    xy = shapely.get_coordinates(edges, include_z=False)
    first = np.r_[0, np.cumsum(shapely.get_num_coordinates(edges))[:-1]]
    p0, p1 = xy[first], xy[first + 1]
    m = (p0 + p1) / 2
    d = p1 - p0
    nrm = np.c_[-d[:, 1], d[:, 0]] / np.maximum(np.hypot(d[:, 0], d[:, 1]), 1e-12)[:, None] * 0.01
    side = np.full((2, ne), outside)
    ftree = shapely.STRtree(faces)
    for s, pts in enumerate((m + nrm, m - nrm)):
        pi, fi = ftree.query(shapely.points(pts), predicate="within")
        side[s][pi] = fi

    # Runs: one named street between two crossings of the kept network.
    fixed_node = np.zeros(nn, bool)
    fixed_node[node[:, ~is_minor].ravel()] = True
    mi = np.flatnonzero(is_minor & alive)
    label = np.array([names[i - nf] if names[i - nf] else "#%d" % i for i in of[mi]], dtype=object)
    _, name_id = np.unique(label.astype(str), return_inverse=True)
    rows, cols = [], []
    for s in (0, 1):
        v = node[s][mi]
        ok = ~fixed_node[v]
        rows.append(np.arange(len(mi))[ok])
        cols.append((v * (name_id.max() + 1) + name_id)[ok])
    rows, cols = np.concatenate(rows), np.concatenate(cols)
    _, cols = np.unique(cols, return_inverse=True)
    k = len(mi)
    b = scipy.sparse.coo_matrix((np.ones(len(rows)), (rows, cols + k)), shape=(k + cols.max() + 1 if len(cols) else k,) * 2)
    _, run_of = connected_components(b, directed=False)
    run_of = run_of[:k]
    _, run_of = np.unique(run_of, return_inverse=True)
    nr = int(run_of.max()) + 1 if k else 0
    order = np.argsort(run_of, kind="stable")
    run_edges = np.split(mi[order], np.searchsorted(run_of[order], np.arange(1, nr)))
    run_len = np.bincount(run_of, weights=shapely.length(edges[mi]), minlength=nr)

    # Merge the smallest blocks across their minor streets.
    nface = outside + 1
    parent = list(range(nface))
    ar = area.tolist()

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    runs_at = [set() for _ in range(nface)]
    for r, es in enumerate(run_edges):
        for f in np.unique(side[:, es]).tolist():
            runs_at[f].add(r)
    run_alive = [True] * nr
    sl, sr = side[0].tolist(), side[1].tolist()
    heap = [(a, f) for f, a in enumerate(ar) if a < min_block]
    heapq.heapify(heap)
    before = outside
    while heap:
        a, f = heapq.heappop(heap)
        if find(f) != f or a != ar[f] or a >= min_block:
            continue
        best = None
        for r in list(runs_at[f]):
            if not run_alive[r]:
                runs_at[f].discard(r)
                continue
            nb = set()
            for e in run_edges[r].tolist():
                nb.add(find(sl[e]))
                nb.add(find(sr[e]))
            nb.discard(f)
            if not nb:
                continue  # inside this block: a dead end, dropped at the end
            score = (min(ar[x] for x in nb), run_len[r], r)
            if best is None or score < best:
                best = score
        if best is None:
            continue
        r = best[2]
        run_alive[r] = False
        grown = set()
        for e in run_edges[r].tolist():
            x, y = find(sl[e]), find(sr[e])
            if x != y:
                if len(runs_at[x]) < len(runs_at[y]):
                    x, y = y, x
                parent[y] = x
                ar[x] += ar[y]
                runs_at[x] |= runs_at[y]
                runs_at[y] = set()
                grown.add(x)
        # A run can join blocks other than f's along its far edges: every
        # block that grew goes back on the heap at its new size.
        for x in {find(x) for x in grown | {f}}:
            heapq.heappush(heap, (ar[x], x))

    roots = np.array([find(i) for i in range(nface)])
    keep = np.zeros(ne, bool)
    for r in np.flatnonzero(run_alive).tolist():
        keep[run_edges[r]] = True
    keep &= roots[side[0]] != roots[side[1]]
    after = len(np.unique(roots[:outside]))
    gone = np.zeros(ne, bool)
    gone[mi] = True
    gone &= ~keep & (side[0] != side[1]) & (side[0] != outside) & (side[1] != outside)
    return _lines(edges[keep]), _lines(edges[gone]), faces, before, after


def _lines(pieces):
    """Pieces joined end to end where they meet, as coordinate arrays."""
    if not len(pieces):
        return []
    merged = shapely.line_merge(shapely.multilinestrings(pieces))
    return [shapely.get_coordinates(p) for p in shapely.get_parts(merged)]
