"""Makes game hair from a hairstyle grown by hairstyle.py on a baked MPFB
human: the strands are grown on the body by rule, then

1. each lock (a guide and the strands that follow it; a bun's rope, split by
   where it runs round the bun) becomes cards down its middle, as wide as its
   strands spread: a dense inner card close to the skin, a looser outer one,
   crossed where the lock hangs free; baby hairs get a wisp card;
2. every root is stamped into the body's UV space as a short stroke, the
   scalp texture: under the cards the skin turns to short hair, and the
   hairline fades out in strokes instead of ending at a card's edge;
3. each card's own strands, the lock's grown strands carried onto it, are
   drawn into a tile of the character's strand atlas;
4. a hull over the hair is kept for the outline bake.

The atlas holds no colour, only strands: coverage, a random id per strand,
shading across each strand and by how far back it lies, and how far along
its strand a texel is. groom.gdshader colours it, so any hair colour is a
uniform.

In Blender, from bake_character.py:
    groom.build(body, eyes, rig, style_path, name, scalp_png, strands_png)
"""
import math
import struct
import sys
import zlib

import numpy as np

def write_png(path, array):
    """array: uint8, HxW (grey) or HxWx4 (RGBA)."""
    h, w = array.shape[:2]
    colour = 0 if array.ndim == 2 else 6
    raw = b"".join(b"\x00" + array[y].tobytes() for y in range(h))

    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, colour, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def _smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


# ---------------------------------------------------------------- Blender side

def _blur(grid, passes):
    """A box blur of a 2D grid, repeated `passes` times."""
    for _ in range(passes):
        padded = np.pad(grid, 1, mode="edge")
        grid = sum(padded[1 + dy:1 + dy + grid.shape[0], 1 + dx:1 + dx + grid.shape[1]]
                   for dy in (-1, 0, 1) for dx in (-1, 0, 1)) / 9.0
    return grid


def _blur_within(grid, mask, passes):
    """Blurs grid over the cells in mask only, so values don't fade towards the
    mask's edges; cells within `passes` of the mask take their neighbours'."""
    m = mask.astype(float)
    num, den = _blur(grid * m, passes), _blur(m, passes)
    return np.where(den > 1e-6, num / np.maximum(den, 1e-6), 0.0)


def _upsample(grid, size):
    """Bilinear upsampling of a square grid to size x size."""
    n = grid.shape[0]
    x = np.clip((np.arange(size) + 0.5) * n / size - 0.5, 0.0, n - 1.0)
    i = np.minimum(x.astype(int), n - 2)
    f = x - i
    rows = grid[i] * (1 - f)[:, None] + grid[i + 1] * f[:, None]
    return rows[:, i] * (1 - f)[None, :] + rows[:, i + 1] * f[None, :]


CARD_STEP = 0.008  # metres between a card's rows
BUN_LOCKS = 140  # cards' worth of locks the bun's rope is split into


def build(body, eyes, rig, style_path, name, scalp_png, strands_png, seed=1):
    """Grows the hairstyle at style_path (tools/characters/hairstyles/) on the
    baked body, whose eyes place the head, and makes game hair of it:
    "<name>.groom", the cards, and "<name>.hair_shell", a hull over the hair
    that the outline is built from (CharacterLook hides it). Both ride the
    Head bone. scalp_png gets where the hair grows on the skin, strands_png
    the cards' strands. Returns the cards."""
    import hairstyle

    rng = np.random.default_rng(seed)
    head = hairstyle.Head(body, eyes)
    style = hairstyle.Style(style_path, head)
    info = {}
    strands, _, _ = hairstyle.grow(head, style, seed, info)
    _scalp_texture(body, head, strands, info, scalp_png, rng)
    positions, normals, uvs, colours, faces, tiles = _cards(head, strands, info, rng)
    uvs = _bake_strands(tiles, uvs, strands_png, rng)
    cards = _object(name + ".groom", positions, normals, uvs, colours, faces, rig)
    _hull(head, strands, info, name + ".hair_shell", rig)
    return cards


def _locks(S, info, rng):
    """The strands in locks, as (members, first point, last point, baby, free):
    each guide's strands, over the scalp; a tied style's rope, split by where
    its strands run round the bun."""
    lead, tied, m0 = info["lead"], info["tied"], info["scalp_m"]
    m = S.shape[1]
    out = []
    order = np.argsort(lead, kind="stable")
    keys, starts = np.unique(lead[order], return_index=True)
    for g, members in zip(keys, np.split(order, starts[1:])):
        free = members[~tied[members]]
        bound = members[tied[members]]
        if len(free):
            out.append((free, 0, m, bool(info["baby"][g]), True))
        if len(bound):
            out.append((bound, 0, m0, bool(info["baby"][g]), False))
    rope = np.where(tied)[0]
    if len(rope):
        marks = np.linspace(m0, m - 1, 4).astype(int)
        feature = S[rope][:, marks].reshape(len(rope), -1)
        seeds = feature[rng.choice(len(rope), min(BUN_LOCKS, len(rope)), replace=False)]
        near = np.argmin(((feature[:, None, :] - seeds[None]) ** 2).sum(-1), axis=1)
        for k in range(len(seeds)):
            members = rope[near == k]
            if len(members):
                out.append((members, m0 - 1, m, False, True))
    return out


def _cards(head, S, info, rng):
    """Cards for each lock, running down its strands' middle as wide as they
    spread: an inner card of dense strands under the middle, an outer one of
    looser strands over it, which cross where the lock hangs free so it has
    body from every side. Baby hairs get one wisp card a lock."""
    positions, normals, uvs, colours, faces, tiles = [], [], [], [], [], []

    def card(path, outward, side, width, layer, lock, at, along, density, keep_back=0.0):
        """A card down path; its UVs name its tile until _bake_strands
        places it. density: strands across the card per texel; keep_back:
        the share of the lock's strands, furthest back, it leaves out."""
        k = len(path)
        card_rand = rng.uniform()
        base = len(positions)
        half = 0.5 * width * (1.0 - 0.2 * np.linspace(0.0, 1.0, k))
        for j in range(k):
            s = j / (k - 1)
            positions.extend([path[j] - side[j] * half[j], path[j] + side[j] * half[j]])
            normals.extend([outward[j], outward[j]])
            uvs.extend([(len(tiles), 0.0, s), (len(tiles), 1.0, s)])
            colours.extend([(layer, card_rand, 0.0, 1.0)] * 2)
        for j in range(k - 1):
            l0, r0 = base + 2 * j, base + 2 * j + 1
            faces.append((l0, l0 + 2, r0 + 2, r0))
        tiles.append(dict(path=np.asarray(path), side=np.asarray(side), outward=np.asarray(outward),
                          half=half, strands=lock, at=at, along=along,
                          density=density, keep_back=keep_back))
        tiles[-1]["length"] = float(np.linalg.norm(np.diff(path, axis=0), axis=1).sum())

    m = S.shape[1]
    for members, a, b, baby, hangs in _locks(S, info, rng):
        lock = S[members, a:b]
        along = (a + np.arange(b - a)) / (m - 1.0)
        spine = lock.mean(0)
        seg = np.linalg.norm(np.diff(spine, axis=0), axis=1)
        arc = np.concatenate([[0.0], np.cumsum(seg)])
        if arc[-1] < 0.004:
            continue
        k = int(np.clip(round(arc[-1] / CARD_STEP) + 1, 3, 24))
        at = np.interp(np.linspace(0.0, arc[-1], k), arc, np.arange(len(spine)))
        idx = np.arange(len(spine))
        path = np.column_stack([np.interp(at, idx, spine[:, c]) for c in range(3)])
        tangent = np.gradient(path, axis=0)
        tangent /= np.maximum(np.linalg.norm(tangent, axis=1), 1e-9)[:, None]
        outward, side, spread, depth, free = [], [], [], [], []
        for j, p in enumerate(path):
            q, nq = head.nearest(p)
            f = float(_smoothstep(0.01, 0.03, (p - q) @ nq)) if hangs else 0.0
            o = nq * (1.0 - f) + _unit(p - head.c) * f
            o = _unit(o - tangent[j] * (o @ tangent[j]))
            sd = _unit(np.cross(o, tangent[j]))
            d = lock[:, int(round(at[j]))] - path[j]
            outward.append(o)
            side.append(sd)
            spread.append(float(np.std(d @ sd)))
            depth.append(float(np.std(d @ o)))
            free.append(f)
        outward, side = np.array(outward), np.array(side)
        free, spread, depth = np.array(free), np.array(spread), np.array(depth)
        if baby:
            card(path, outward, side, np.clip(4.0 * spread, 0.003, 0.008), 0.85, lock, at, along, 0.15)
            continue
        width = np.clip(4.0 * spread, 0.012, 0.03)
        cross = math.radians(45.0) * free
        for layer, sign, density, keep_back, scale, lift in ((0.3, 1.0, 0.4, 0.0, 1.3, -0.8),
                                                             (0.85, -1.0, 0.25, 0.4, 1.0, 0.5)):
            p = path + outward * (lift * depth)[:, None]
            for j in range(k):
                q, nq = head.nearest(p[j])
                h = float((p[j] - q) @ nq)
                if h < 0.0008:
                    p[j] += nq * (0.0008 - h)
            twist = sign * cross + rng.normal(0.0, 0.15)
            sd = side * np.cos(twist)[:, None] + outward * np.sin(twist)[:, None]
            card(p, outward, sd, width * scale * rng.uniform(0.85, 1.15), layer, lock, at, along,
                 density, keep_back)
    print("GROOM cards", len(faces), "quads", len(positions), "verts")
    return positions, normals, uvs, colours, faces, tiles


STRAND_ATLAS = 2048  # a character's strand atlas, square, in texels
ALONG_TEXELS = 0.4  # texels along a card for each one across: strands run along


def _pack(sizes, side):
    """Shelf-packs (w, h) rectangles into a side x side square, tallest
    first; their top-left corners, or None if they don't fit."""
    order = sorted(range(len(sizes)), key=lambda i: -sizes[i][1])
    x = y = shelf = 0
    out = [None] * len(sizes)
    for i in order:
        w, h = sizes[i]
        if x + w > side:
            x, y, shelf = 0, y + shelf, 0
        if y + h > side:
            return None
        out[i] = (x, y)
        x, shelf = x + w, max(shelf, h)
    return out


def _bake_strands(tiles, uvs, png, rng):
    """Draws each card's own strands into a tile of its own and points the
    card's UVs at it. A tile is the card unrolled: across it the card's width,
    down it the card from root to tip. The lock's strands are carried onto
    the card along its rows, each with children combed round it until the
    card is as full as it asks; the frontmost strand gives a texel its id,
    shade and length, and the coverage of all of them adds up."""
    side = STRAND_ATLAS
    metres = np.array([(2.0 * t["half"].max(), t["length"]) for t in tiles])
    area = float((metres[:, 0] * metres[:, 1] * ALONG_TEXELS).sum())
    rho = math.sqrt(0.9 * side * side / area)  # texels per metre across
    while True:
        sizes = [(max(4, math.ceil(w * rho)) + 2, max(4, math.ceil(l * rho * ALONG_TEXELS)) + 2)
                 for w, l in metres]
        corners = _pack(sizes, side)
        if corners:
            break
        rho *= 0.97
    print("GROOM strand atlas: %d cards, %.2f texels/mm across" % (len(tiles), rho / 1000.0))

    n_px = side * side
    clear = np.zeros(n_px, np.float64)  # sum of log(1 - coverage)
    ident = np.full(n_px, 0.5, np.float32)
    shade = np.full(n_px, 0.6, np.float32)
    along = np.zeros((side, side), np.float32)
    flat, cov, key, sid, shd, alg = [], [], [], [], [], []

    def flush():
        if not flat:
            return
        f, c = np.concatenate(flat), np.concatenate(cov)
        clear[:] += np.bincount(f, np.log1p(-np.minimum(c, 0.995)), n_px)
        top = c > 0.35
        order = np.argsort(np.concatenate(key)[top], kind="stable")
        ft = f[top][order]
        ident[ft] = np.concatenate(sid)[top][order]
        shade[ft] = np.concatenate(shd)[top][order]
        along.reshape(-1)[ft] = np.concatenate(alg)[top][order]
        for lst in (flat, cov, key, sid, shd, alg):
            lst.clear()

    for t, (x0, y0), (tw, th) in zip(tiles, corners, sizes):
        path, sd, half, out = t["path"], t["side"], t["half"], t["outward"]
        lock, at, root_to_tip = t["strands"], t["at"], t["along"]
        k, (n, L, _) = len(path), lock.shape
        # Each strand sample's place on the card: its row, then across.
        r = np.interp(np.arange(L), at, np.arange(k))
        j0 = np.minimum(r.astype(int), k - 2)
        f = (r - j0)[:, None]
        P = path[j0] * (1 - f) + path[j0 + 1] * f
        D = sd[j0] * (1 - f) + sd[j0 + 1] * f
        D /= np.linalg.norm(D, axis=1)[:, None]
        N = out[j0] * (1 - f) + out[j0 + 1] * f
        N -= D * (N * D).sum(1)[:, None]
        N /= np.maximum(np.linalg.norm(N, axis=1), 1e-9)[:, None]
        H = half[j0] * (1 - f[:, 0]) + half[j0 + 1] * f[:, 0]
        d = lock - P[None]
        u = np.einsum("nlc,lc->nl", d, D) / (2.0 * H)[None] + 0.5
        # A lock wider than its card (a bun's rope, wound round) is drawn
        # squeezed onto it rather than cut off at its edges.
        u = 0.5 + (u - 0.5) / max(1.0, float(np.quantile(np.abs(u - 0.5), 0.95)) / 0.45)
        z = np.einsum("nlc,lc->nl", d, N).mean(1)
        s = r / (k - 1)
        keep = z >= np.quantile(z, t["keep_back"]) if t["keep_back"] > 0 else np.ones(n, bool)
        u, z = u[keep], z[keep]
        # Children combed round each strand, until the card holds as many
        # strands across as it asks for.
        want = max(len(u), int(t["density"] * (tw - 2)))
        c = math.ceil(want / len(u))
        m_ = len(u) * c
        U = np.repeat(u, c, 0)
        if c > 1:
            spread = rng.normal(0.0, 0.12, m_)[:, None] * (0.6 + 0.8 * s[None])
            spread[::c] = 0.0
            wave = rng.uniform(0.0, 0.02, m_)[:, None] * np.sin(
                2 * math.pi * (rng.uniform(0.5, 2.0, m_)[:, None] * s[None] + rng.uniform(0, 1, m_)[:, None]))
            U = U + spread + wave
        Z = np.repeat(z, c) + rng.normal(0.0, 0.3 * (z.std() + 1e-5), m_)
        rank = np.argsort(np.argsort(Z)) / max(m_ - 1, 1)
        ends = np.where(rng.uniform(size=m_) < 0.35, rng.uniform(0.6, 1.0, m_), 1.0)
        # About a texel a step down the tile.
        q = np.linspace(0.0, L - 1.0, max(2 * th, 8))
        i0 = np.minimum(q.astype(int), L - 2)
        fq = q - i0
        Uq = U[:, i0] * (1 - fq) + U[:, i0 + 1] * fq
        sq = np.interp(q, np.arange(L), s)
        tq = q / (L - 1.0)
        aq = np.interp(q, np.arange(L), root_to_tip)
        x = x0 + 1.0 + Uq * (tw - 2)
        y = np.broadcast_to(y0 + 1.0 + sq * (th - 2), x.shape)
        fade = 1.0 - _smoothstep(0.85, 1.0, tq[None] / ends[:, None])
        hw = rng.uniform(0.25, 0.5, m_)[:, None] * (1.0 - 0.5 * tq[None])
        ids = np.broadcast_to(rng.uniform(size=m_)[:, None], x.shape)
        inside = (Uq >= 0.0) & (Uq <= 1.0) & (tq[None] <= ends[:, None])
        yi = np.clip(y.astype(int), y0, y0 + th - 1)
        for off in (-1, 0, 1):
            px = np.floor(x).astype(int) + off
            dist = np.abs(px + 0.5 - x)
            cv = np.clip(hw + 0.5 - dist, 0.0, 1.0) * fade
            ok = inside & (cv > 0.0) & (px >= x0) & (px < x0 + tw)
            rnd = 1.0 - np.clip(dist / np.maximum(hw + 0.5, 0.5), 0.0, 1.0) ** 2
            flat.append((yi * side + px)[ok])
            cov.append(cv[ok])
            key.append(np.broadcast_to(rank[:, None], x.shape)[ok])
            sid.append(ids[ok].astype(np.float32))
            shd.append(((0.55 + 0.45 * rank[:, None]) * (0.7 + 0.3 * rnd))[ok].astype(np.float32))
            alg.append(np.broadcast_to(aq[None], x.shape)[ok].astype(np.float32))
        # Bare texels keep the length their row would have, so mips blend true.
        along[y0:y0 + th, x0:x0 + tw] = np.interp(np.linspace(0.0, 1.0, th), s, root_to_tip)[:, None]
        if sum(len(a) for a in flat) > 4_000_000:
            flush()
    flush()
    cover = 1.0 - np.exp(clear)
    rgba = np.stack([ident, shade, along.reshape(-1), cover], -1).reshape(side, side, 4)
    write_png(png, (np.clip(rgba, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8))

    out = []
    for ti, uu, s in uvs:
        (x0, y0), (tw, th) = corners[ti], sizes[ti]
        out.append(((x0 + 1.0 + uu * (tw - 2)) / side, 1.0 - (y0 + 1.0 + s * (th - 2)) / side))
    return out


def _unit(v):
    return v / max(float(np.linalg.norm(v)), 1e-12)


def _object(name, positions, normals, uvs, colours, faces, rig):
    """The mesh as an object riding the rig's Head bone, with a material of
    its own name (CharacterLook goes by it)."""
    import bpy
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(p) for p in positions], [], faces)
    me.validate()
    if uvs:
        uv = me.uv_layers.new(name="UVMap")
        uv.data.foreach_set("uv", [c for li in me.loops for c in uvs[li.vertex_index]])
    if colours:
        col = me.color_attributes.new("Color", "FLOAT_COLOR", "POINT")
        col.data.foreach_set("color", [c for rgba in colours for c in rgba])
        me.color_attributes.active_color = col
    if normals:
        me.normals_split_custom_set_from_vertices([tuple(n) for n in normals])
    me.materials.append(bpy.data.materials.new(name))
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    obj.parent = rig
    obj.matrix_parent_inverse = rig.matrix_world.inverted()
    obj.vertex_groups.new(name="Head").add(list(range(len(me.vertices))), 1.0, "REPLACE")
    obj.modifiers.new("Armature", "ARMATURE").object = rig
    return obj


def _hull(head, S, info, name, rig):
    """The hair's outer surface, for the outline: the scalp under the hair,
    lifted to where its outer strands lie, and a hull round the bun."""
    import bmesh
    from mathutils import Vector
    from mathutils.kdtree import KDTree

    m0 = info["scalp_m"]
    on_head = np.where(info["tied"][:, None], np.arange(S.shape[1])[None] < m0, True)
    hair_pts = S[::3][on_head[::3]]
    roots = KDTree(len(S))
    for i, p in enumerate(S[:, 0]):
        roots.insert(Vector(p), i)
    roots.balance()
    hair = KDTree(len(hair_pts))
    for i, p in enumerate(hair_pts):
        hair.insert(Vector(p), i)
    hair.balance()
    covered = [int(v) for v in np.unique(head.T) if roots.find_range(Vector(head.V[v]), 0.006)]
    lift = {}
    for v in covered:
        q, nq = head.nearest(head.V[v])
        near = [np.array(p) for p, _, _ in hair.find_range(Vector(q), 0.015)]
        h = float(np.percentile([(p - q) @ nq for p in near], 90)) if near else 0.002
        lift[v] = (q, nq, float(np.clip(h, 0.002, 0.04)))
    # Smoothed, so strays don't dent or spike it.
    nbrs = {v: set() for v in lift}
    for t in head.T:
        for x in t:
            for y in t:
                if x != y and int(x) in lift and int(y) in lift:
                    nbrs[int(x)].add(int(y))
    h = {v: lift[v][2] for v in lift}
    for _ in range(3):
        h = {v: 0.5 * h[v] + 0.5 * np.mean([h[u] for u in nbrs[v]]) if nbrs[v] else h[v] for v in h}
    bm = bmesh.new()
    verts = {v: bm.verts.new(tuple(lift[v][0] + lift[v][1] * (h[v] + 0.001))) for v in lift}
    for t in head.T:
        if all(int(v) in verts for v in t):
            try:
                bm.faces.new([verts[int(v)] for v in t])
            except ValueError:
                pass
    if info["tied"].any():
        rope = S[info["tied"], m0:].reshape(-1, 3)
        rope = rope[np.random.default_rng(0).permutation(len(rope))[:20000]]
        bun = bmesh.new()
        for p in rope:
            bun.verts.new(tuple(p))
        bmesh.ops.convex_hull(bun, input=bun.verts[:])
        bmesh.ops.delete(bun, geom=[v for v in bun.verts if not v.link_faces], context="VERTS")
        bun.verts.ensure_lookup_table()
        new = [bm.verts.new(tuple(v.co)) for v in bun.verts]
        for f in bun.faces:
            bm.faces.new([new[v.index] for v in f.verts])
        bun.free()
    bm.verts.index_update()
    positions = [tuple(v.co) for v in bm.verts]
    faces = [[v.index for v in f.verts] for f in bm.faces]
    bm.free()
    print("GROOM hull", len(positions), "verts", len(faces), "faces")
    return _object(name, positions, [], [], [], faces, rig)


def _scalp_texture(body, head, S, info, png, rng):
    """Where the hair grows, in the body's UVs: a short stroke for each root
    the way it leaves the skin, over a blurred fill of the share of the skin
    the roots cover, so the skin shader turns the scalp to short hair under
    the cards and the hairline fades out in strokes."""
    from mathutils import Vector
    from mathutils.bvhtree import BVHTree
    from mathutils.kdtree import KDTree

    me = body.data
    me.calc_loop_triangles()
    mw = body.matrix_world
    bv = np.array([tuple(mw @ v.co) for v in me.vertices])
    btri = np.array([tuple(t.vertices) for t in me.loop_triangles])
    bloops = np.array([tuple(t.loops) for t in me.loop_triangles])
    buv = np.array([tuple(l.uv) for l in me.uv_layers.active.data])
    bvh = BVHTree.FromPolygons([tuple(v) for v in bv], [tuple(t) for t in btri])

    def locate(p):
        loc, _, tri, _ = bvh.find_nearest(Vector(p))
        a, b, c = bv[btri[tri]]
        v0, v1, v2 = b - a, c - a, np.array(loc) - a
        d00, d01, d11, d20, d21 = v0 @ v0, v0 @ v1, v1 @ v1, v2 @ v0, v2 @ v1
        den = max(d00 * d11 - d01 * d01, 1e-18)
        w1, w2 = (d11 * d20 - d01 * d21) / den, (d00 * d21 - d01 * d20) / den
        return tri, np.clip(np.array([1.0 - w1 - w2, w1, w2]), 0.0, 1.0)

    size = 2048
    acc = np.zeros((size, size), np.float32)
    stroke = 0.006
    edge = info["edge"]
    for i in range(len(S)):
        tri, bary = locate(S[i, 0])
        pa, pb, pc = bv[btri[tri]]
        ua, ub, uc = buv[bloops[tri]]
        coef, *_ = np.linalg.lstsq(np.stack([pb - pa, pc - pa], 1),
                                   _unit(S[i, 2] - S[i, 0]) * stroke * rng.uniform(0.6, 1.2), rcond=None)
        duv = coef[0] * (ub - ua) + coef[1] * (uc - ua)
        uv0 = bary @ buv[bloops[tri]]
        weight = (1.0 - 0.5 * edge[i]) * rng.uniform(0.6, 1.0)
        for s in np.linspace(0.0, 1.0, 7):
            u, v = uv0 + duv * s
            x, y = u * size, (1.0 - v) * size
            xi, yi = int(x), int(y)
            if 0 <= xi < size - 1 and 0 <= yi < size - 1:
                fx, fy = x - xi, y - yi
                w = weight * (1.0 - 0.6 * s)
                acc[yi, xi] += w * (1 - fx) * (1 - fy)
                acc[yi, xi + 1] += w * fx * (1 - fy)
                acc[yi + 1, xi] += w * (1 - fx) * fy
                acc[yi + 1, xi + 1] += w * fx * fy
    # Even samples over the head: how many texels a square centimetre gets
    # (the strokes are scaled by it, or the UVs would thin them in places),
    # and the share of each cell the roots cover (the fill under the strokes).
    sel = np.where(np.isin(btri, np.unique(head.T)).all(1))[0]
    a, b, c = (bv[btri[sel, j]] for j in range(3))
    areas = 0.5 * np.linalg.norm(np.cross(b - a, c - a), axis=1)
    count = 60000
    picks = sel[rng.choice(len(sel), count, p=areas / areas.sum())]
    r1, r2 = np.sqrt(rng.uniform(size=count)), rng.uniform(size=count)
    bary = np.stack([1 - r1, r1 * (1 - r2), r1 * r2], 1)
    pts = np.einsum("ki,kij->kj", bary, bv[btri[picks]])
    uvs = np.einsum("ki,kij->kj", bary, buv[bloops[picks]])
    roots = KDTree(len(S))
    for i, p in enumerate(S[:, 0]):
        roots.insert(Vector(p), i)
    roots.balance()
    covered = np.array([roots.find(Vector(p))[2] < 0.004 for p in pts])
    coarse = 64
    cx = np.clip((uvs[:, 0] * coarse).astype(int), 0, coarse - 1)
    cy = np.clip(((1.0 - uvs[:, 1]) * coarse).astype(int), 0, coarse - 1)
    total = np.zeros((coarse, coarse))
    np.add.at(total, (cy, cx), 1.0)
    hit = np.zeros((coarse, coarse))
    np.add.at(hit, (cy[covered], cx[covered]), 1.0)
    # The blurs stay within the head's UV islands: blurred across an island's
    # edge, the fill would fade along the seams and show them as bare stripes.
    island = total > 0
    density = np.where(island, total.mean() / np.maximum(total, 1e-9) * island.mean(), 0.0)
    density = _upsample(_blur_within(np.clip(density, 0.0, 4.0), island, 1), size)
    fill = _upsample(_blur_within(hit / np.maximum(total, 1.0), island, 2), size)
    # Strokes per texel scale with the roots per stroke; 30000 roots made
    # about as many strokes as the old stamp, whose gain this keeps.
    gain = 1.6 * 30000.0 / len(S)
    scalp = 1.0 - np.exp(-acc * gain * density)
    scalp = np.maximum(scalp, np.clip(fill * 1.4, 0.0, 1.0) * 0.8)
    write_png(png, (scalp * 255.0 + 0.5).astype(np.uint8))
    print("GROOM scalp", png, "covered", int(covered.sum()), "of", count)

