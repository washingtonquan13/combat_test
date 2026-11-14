"""Grows modern hair cards for a baked MPFB human, in place of its hair shell.

MakeHuman's hairstyles are shells: one or two helmets around the head with a
painted picture of hair on them. That reads as a hat, with a hard cut where
the shell meets the forehead. This keeps the shell only as the shape of the
style and grows real hair inside it:

1. roots are scattered over the scalp the shell covers;
2. strands grow from them along the style's flow (away from a crown whorl, or
   pulled back to a ponytail tie and down the tail), held between the scalp
   and the shell, and stop where the shell ends;
3. each strand becomes a ribbon card, in two layers (a dense inner one close
   to the scalp, a looser outer one), textured from a shared strand atlas;
4. every root is also stamped into the body's UV space as short strokes, the
   scalp texture: under the cards the skin turns to short hair, and the
   hairline fades out in strokes instead of ending at a card's edge.

The atlas holds no colour, only strands: coverage, a random id per strand,
shading across and along each strand. groom.gdshader colours it, so every
character shares one atlas and any hair colour is a uniform.

In Blender, from bake_character.py:
    groom.build(body, shell, rig, style, name, scalp_png)
Outside Blender, for the shared atlas (numpy only):
    python tools/characters/groom.py atlas assets/characters/hair/hair_strands.png

A style is tools/characters/grooms/<hair>.json, beside the MPFB hair it reworks:
    flow          "crown" (strands leave a whorl) or "tie" (drawn back to a
                  ponytail; the shell's tail gives the tail's path)
    crown_dir     where the whorl sits, as a direction from the head's middle
    comb          a direction every strand leans towards (x right, y back, z up)
    gravity       how much strands fall
    swirl         how much they turn around the whorl
    length        longest strand on the scalp, metres
    tip_jitter    how far past the shell's edge strands may run, metres
    spacing       distance between card roots, metres
    card_width    metres
    layers        [{"height": share of the shell's thickness, "atlas": kind}]
    hairline      how far below the top of the head the front hairline sits,
                  metres: shells hang a fringe over the brow, but no roots go
                  there
"""
import math
import struct
import sys
import zlib

import numpy as np

ATLAS_SIZE = 2048
ATLAS_COLUMNS = 8
# The kinds of card, and which atlas columns hold each.
VARIANTS = {"dense": (0, 1, 2), "medium": (3, 4, 5), "wisp": (6, 7)}
STRANDS_PER_COLUMN = {"dense": 120, "medium": 64, "wisp": 18}


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


def make_atlas(path, seed=7):
    """The shared strand atlas. Each column is one card: roots at the top,
    tips at the bottom. R a random id per strand, G shading (round across the
    strand, darker for strands further back), B how far along its strand,
    A coverage."""
    rng = np.random.default_rng(seed)
    size, cw = ATLAS_SIZE, ATLAS_SIZE // ATLAS_COLUMNS
    cover = np.zeros((size, size), np.float32)
    ident = np.full((size, size), 0.5, np.float32)
    shade = np.full((size, size), 0.6, np.float32)
    along = np.repeat(np.linspace(0.0, 1.0, size, dtype=np.float32)[:, None], size, 1)
    for kind, columns in VARIANTS.items():
        spread = {"dense": 0.17, "medium": 0.22, "wisp": 0.26}[kind]
        for col in columns:
            x0 = col * cw
            count = STRANDS_PER_COLUMN[kind]
            # Back to front: later strands lie over earlier ones.
            for s in range(count):
                depth = s / max(count - 1, 1)
                start = rng.uniform(0.0, 0.06) * size
                reach = rng.uniform(0.78, 1.0) if kind == "dense" else rng.uniform(0.5, 1.0)
                end = reach * size
                rows = np.arange(int(start), int(end))
                t = np.clip((rows - start) / max(end - start, 1.0), 0.0, 1.0)
                centre = np.clip(rng.normal(cw * 0.5, cw * spread), cw * 0.06, cw * 0.94)
                drift = rng.normal(0.0, cw * 0.07) * t ** 1.6
                wave = rng.uniform(0.5, 3.0) * np.sin(2 * math.pi * (t * rng.uniform(0.6, 2.2) + rng.uniform()))
                x = centre + drift + wave
                half = rng.uniform(0.7, 1.5) * (1.0 - 0.55 * t)
                fade = 1.0 - _smoothstep(0.8, 1.0, t)
                sid = rng.uniform()
                body = 0.55 + 0.45 * depth
                for off in range(-3, 4):
                    px = np.floor(x).astype(int) + off
                    d = np.abs(px + 0.5 - x)
                    cov = np.clip(half + 0.5 - d, 0.0, 1.0) * fade
                    keep = (px >= 0) & (px < cw) & (cov > 0.0)
                    r, c, cv = rows[keep], px[keep] + x0, cov[keep]
                    round_ = 1.0 - np.clip(d[keep] / np.maximum(half[keep] + 0.5, 0.5), 0.0, 1.0) ** 2
                    cover[r, c] = cover[r, c] + cv * (1.0 - cover[r, c])
                    ident[r, c] += (sid - ident[r, c]) * cv
                    shade[r, c] += (body * (0.7 + 0.3 * round_) - shade[r, c]) * cv
                    along[r, c] += (t[keep] - along[r, c]) * cv
    out = np.stack([ident, shade, along, cover], -1)
    write_png(path, (np.clip(out, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8))


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


def build(body, shell, rig, style, name, scalp_png, seed=1):
    """Grows the cards for one character. body and shell are the baked body and
    the MPFB hair; the shell is kept, emptied of its texture and renamed
    "<name>.hair_shell" (the outline is built from it, CharacterLook hides it).
    Returns the new cards object, "<name>.groom"."""
    import bpy
    from mathutils import Vector
    from mathutils.bvhtree import BVHTree
    from mathutils.kdtree import KDTree

    rng = np.random.default_rng(seed)

    def world_mesh(obj):
        me = obj.data
        me.calc_loop_triangles()
        mw = obj.matrix_world
        verts = np.array([tuple(mw @ v.co) for v in me.vertices], np.float64)
        rot = mw.to_3x3().inverted().transposed()
        normals = np.array([tuple((rot @ v.normal).normalized()) for v in me.vertices], np.float64)
        tris = np.array([tuple(t.vertices) for t in me.loop_triangles], np.int64)
        loops = np.array([tuple(t.loops) for t in me.loop_triangles], np.int64)
        return verts, normals, tris, loops

    bv, bn, btri, bloops = world_mesh(body)
    uv_layer = body.data.uv_layers.active.data
    buv = np.array([tuple(l.uv) for l in uv_layer], np.float64)
    body_bvh = BVHTree.FromPolygons([tuple(v) for v in bv], [tuple(t) for t in btri])
    sv, _, stri, _ = world_mesh(shell)
    shell_bvh = BVHTree.FromPolygons([tuple(v) for v in sv], [tuple(t) for t in stri])

    head_bone = rig.data.bones["Head"]
    head_z = (rig.matrix_world @ head_bone.head_local).z
    head_sel = bv[:, 2] > head_z - 0.035
    centre = bv[head_sel].mean(0)
    front = np.array([0.0, -1.0, 0.0])

    def surface(p):
        """Nearest point on the body: location, smooth normal, triangle, barycentrics."""
        loc, _, tri, _ = body_bvh.find_nearest(Vector(p))
        loc = np.array(loc)
        a, b, c = bv[btri[tri]]
        v0, v1, v2 = b - a, c - a, loc - a
        d00, d01, d11 = v0 @ v0, v0 @ v1, v1 @ v1
        d20, d21 = v2 @ v0, v2 @ v1
        den = max(d00 * d11 - d01 * d01, 1e-18)
        w1 = (d11 * d20 - d01 * d21) / den
        w2 = (d00 * d21 - d01 * d20) / den
        bary = np.clip(np.array([1.0 - w1 - w2, w1, w2]), 0.0, 1.0)
        n = bn[btri[tri]].T @ bary
        return loc, n / np.linalg.norm(n), tri, bary

    def thickness(loc, n, reach=0.08):
        hit = shell_bvh.ray_cast(Vector(loc + n * 0.0005), Vector(n), reach)
        return None if hit[0] is None else hit[3]

    def tangent(v, n):
        v = v - n * (v @ n)
        length = np.linalg.norm(v)
        return v / length if length > 1e-9 else None

    # -- the style's flow
    flow = style.get("flow", "crown")
    comb = np.array(style.get("comb", [0.0, 0.0, 0.0]), np.float64)
    gravity = float(style.get("gravity", 0.3))
    swirl = float(style.get("swirl", 0.4))
    max_len = float(style.get("length", 0.08))
    tip_jitter = float(style.get("tip_jitter", 0.02))
    step = 0.006

    crown = None
    if flow == "crown":
        cdir = np.array(style.get("crown_dir", [0.0, 0.4, 1.0]), np.float64)
        cdir /= np.linalg.norm(cdir)
        hv = bv[head_sel]
        crown = hv[np.argmax((hv - centre) @ cdir)]

    tail = None
    if flow == "tie":
        tail = _tail_path(sv, surface)
        tie = tail["points"][0]
        tie_loc, tie_n, _, _ = surface(tie)

    def direction(p, n, bias):
        if flow == "crown":
            radial = tangent(p - crown, n)
            if radial is None:
                radial = tangent(front.copy(), n)
            # Strands leaving the whorl straight out would bare its middle;
            # close to it they turn around it, and their cards cover it.
            r = np.linalg.norm(p - crown)
            d = radial + np.cross(n, radial) * (swirl * math.exp(-r / 0.05) + 2.5 * math.exp(-r / 0.02))
        else:
            d = tangent(tie_loc - p, n)
            if d is None:
                d = tangent(np.array([0.0, 1.0, 0.0]), n)
        d = d + np.array([0.0, 0.0, -1.0]) * gravity + comb + bias
        d = tangent(d, n)
        return d if d is not None else tangent(np.array([0.0, 0.0, -1.0]), n)

    # -- scalp samples: where the shell covers the head
    tri_sel = np.where(head_sel[btri].all(1))[0]
    a, b, c = (bv[btri[tri_sel, i]] for i in range(3))
    areas = 0.5 * np.linalg.norm(np.cross(b - a, c - a), axis=1)
    count = 60000
    picks = tri_sel[rng.choice(len(tri_sel), count, p=areas / areas.sum())]
    r1, r2 = np.sqrt(rng.uniform(size=count)), rng.uniform(size=count)
    bary = np.stack([1 - r1, r1 * (1 - r2), r1 * r2], 1)
    pts = np.einsum("ki,kij->kj", bary, bv[btri[picks]])
    nrm = np.einsum("ki,kij->kj", bary, bn[btri[picks]])
    nrm /= np.linalg.norm(nrm, axis=1)[:, None]
    top = bv[head_sel, 2].max()
    hairline = float(style.get("hairline", 1.0))
    max_root = float(style.get("max_thickness", 0.045))
    taus = np.full(count, -1.0)
    for i in range(count):
        # The brow: shells hang a fringe over it, but nothing grows there.
        facing = float(_smoothstep(0.1, 0.6, nrm[i] @ front))
        if facing > 0.0 and pts[i, 2] < top - hairline - (1.0 - facing) * 0.06:
            continue
        # Ears are thin flaps: the body is right behind them.
        if body_bvh.ray_cast(Vector(pts[i] - nrm[i] * 0.001), Vector(-nrm[i]), 0.02)[0] is not None:
            continue
        tau = thickness(pts[i], nrm[i])
        if tau is not None and tau <= max_root:
            taus[i] = tau
    covered = np.where(taus >= 0.0)[0]
    print("GROOM scalp samples covered", len(covered), "of", count)

    # -- scalp texture: a stroke per covered sample
    size = 2048
    acc = np.zeros((size, size), np.float32)
    uvs = np.einsum("ki,kij->kj", bary, buv[bloops[picks]])
    edge = np.percentile(taus[covered], 25) if len(covered) else 1.0
    stroke = 0.006
    for i in covered:
        n = nrm[i]
        d = direction(pts[i], n, 0.0)
        tri = picks[i]
        pa, pb, pc = bv[btri[tri]]
        ua, ub, uc = buv[bloops[tri]]
        e = np.stack([pb - pa, pc - pa], 1)
        coef, *_ = np.linalg.lstsq(e, d * stroke * rng.uniform(0.6, 1.2), rcond=None)
        duv = coef[0] * (ub - ua) + coef[1] * (uc - ua)
        weight = (0.35 + 0.65 * float(_smoothstep(0.0, edge, taus[i]))) * rng.uniform(0.6, 1.0)
        for s in np.linspace(0.0, 1.0, 7):
            u, v = uvs[i] + duv * s
            x, y = u * size, (1.0 - v) * size
            xi, yi = int(x), int(y)
            if 0 <= xi < size - 1 and 0 <= yi < size - 1:
                fx, fy = x - xi, y - yi
                w = weight * (1.0 - 0.6 * s)
                acc[yi, xi] += w * (1 - fx) * (1 - fy)
                acc[yi, xi + 1] += w * fx * (1 - fy)
                acc[yi + 1, xi] += w * (1 - fx) * fy
                acc[yi + 1, xi + 1] += w * fx * fy
    # The head's UVs give some parts more texels per square centimetre than
    # others, which would thin the strokes there; scale them by the samples'
    # density in a coarse grid. A blurred fill of the covered fraction goes
    # under the strokes, so no bare skin shows between them.
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
    scalp = 1.0 - np.exp(-acc * 1.6 * density)
    scalp = np.maximum(scalp, np.clip(fill * 1.4, 0.0, 1.0) * 0.8)
    write_png(scalp_png, (scalp * 255.0 + 0.5).astype(np.uint8))

    # -- card roots: covered samples at least `spacing` apart
    spacing = float(style.get("spacing", 0.011))
    grid = {}
    roots = []
    for i in rng.permutation(covered):
        cell = tuple((pts[i] // spacing).astype(int))
        near = [r for dx in (-1, 0, 1) for dy in (-1, 0, 1) for dz in (-1, 0, 1)
                for r in grid.get((cell[0] + dx, cell[1] + dy, cell[2] + dz), ())]
        if any(np.sum((pts[r] - pts[i]) ** 2) < spacing * spacing for r in near):
            continue
        grid.setdefault(cell, []).append(i)
        roots.append(i)
    print("GROOM card roots", len(roots))

    def grow(i, layer):
        loc, n = pts[i], nrm[i]
        angle = rng.normal(0.0, 0.25)
        side = np.cross(n, direction(loc, n, 0.0))
        bias = side * math.tan(angle)
        path, normals = [loc + n * 0.001], [n]
        length = 0.0
        p = path[0]
        reached_tie = False
        # Strands run on past the shell's edge by a random amount, so the
        # hair ends raggedly rather than where MakeHuman's mesh was cut.
        overshoot = rng.uniform(0.0, tip_jitter)
        past, last_tau = 0.0, None
        limit = max_len * rng.uniform(0.85, 1.0)
        while length < limit:
            s_loc, s_n, _, _ = surface(p)
            d = direction(s_loc, s_n, bias)
            q = s_loc + d * step
            q_loc, q_n, _, _ = surface(q)
            tau = thickness(q_loc, q_n)
            if tau is None:
                if last_tau is None or past >= overshoot:
                    break
                tau = last_tau
                past += step
            else:
                last_tau = tau
            rise = min(1.0, (length + step) / 0.02)
            h = max(0.0012, layer * tau * rise)
            q = q_loc + q_n * h
            length += np.linalg.norm(q - p)
            path.append(q)
            normals.append(q_n)
            p = q
            if flow == "tie" and np.linalg.norm(q_loc - tie_loc) < 0.02:
                reached_tie = True
                break
        if flow == "tie" and (reached_tie or length >= max_len * 0.5):
            tail_path, tail_normals = _tail_strand(tail, rng, path[-1])
            path += tail_path
            normals += tail_normals
        return np.array(path), np.array(normals)

    # -- cards
    width = float(style.get("card_width", 0.018))
    positions, normals_out, uvs_out, colours, faces = [], [], [], [], []
    for li, layer in enumerate(style.get("layers", [{"height": 0.4, "atlas": "dense"},
                                                    {"height": 0.85, "atlas": "medium"}])):
        columns = VARIANTS[layer["atlas"]]
        for i in roots:
            path, pn = grow(i, float(layer["height"]))
            if len(path) < 3:
                continue
            if len(path) > 4:
                keep = list(range(0, len(path) - 1, 2)) + [len(path) - 1]
                path, pn = path[keep], pn[keep]
            col = columns[rng.integers(len(columns))]
            u0, u1 = col / ATLAS_COLUMNS, (col + 1) / ATLAS_COLUMNS
            twist = rng.normal(0.0, 0.3)
            w = width * rng.uniform(0.8, 1.2) * float(layer.get("width", 1.0))
            card_rand = rng.uniform()
            k = len(path)
            base = len(positions)
            for j in range(k):
                t = path[min(j + 1, k - 1)] - path[max(j - 1, 0)]
                t /= max(np.linalg.norm(t), 1e-9)
                n = pn[j]
                side = np.cross(n, t)
                side /= max(np.linalg.norm(side), 1e-9)
                side = side * math.cos(twist) + n * math.sin(twist)
                half = 0.5 * w * (1.0 - 0.35 * j / (k - 1))
                v = 1.0 - j / (k - 1)
                positions += [path[j] - side * half, path[j] + side * half]
                normals_out += [n, n]
                uvs_out += [(u0, v), (u1, v)]
                colours += [(float(layer["height"]), card_rand, 0.0, 1.0)] * 2
            for j in range(k - 1):
                l0, r0 = base + 2 * j, base + 2 * j + 1
                faces.append((l0, l0 + 2, r0 + 2, r0))

    me = bpy.data.meshes.new(name + ".groom")
    me.from_pydata([tuple(p) for p in positions], [], faces)
    me.validate()
    uv = me.uv_layers.new(name="UVMap")
    flat_uv = [uvs_out[li.vertex_index] for li in me.loops]
    uv.data.foreach_set("uv", [c for pair in flat_uv for c in pair])
    col = me.color_attributes.new("Color", "FLOAT_COLOR", "POINT")
    col.data.foreach_set("color", [c for rgba in colours for c in rgba])
    me.color_attributes.active_color = col
    me.normals_split_custom_set_from_vertices([tuple(n) for n in normals_out])
    mat = bpy.data.materials.new(name + ".groom")
    me.materials.append(mat)
    cards = bpy.data.objects.new(name + ".groom", me)
    bpy.context.scene.collection.objects.link(cards)
    cards.parent = rig
    cards.matrix_parent_inverse = rig.matrix_world.inverted()

    # Weights: each card vertex takes the nearest shell vertex's.
    tree = KDTree(len(sv))
    for idx, p in enumerate(sv):
        tree.insert(Vector(p), idx)
    tree.balance()
    groups = {g.index: cards.vertex_groups.new(name=g.name) for g in shell.vertex_groups}
    shell_weights = [[(g.group, g.weight) for g in v.groups] for v in shell.data.vertices]
    for vi, p in enumerate(positions):
        _, nearest, _ = tree.find(Vector(p))
        for gi, wgt in shell_weights[nearest]:
            groups[gi].add([vi], wgt, "REPLACE")
    mod = cards.modifiers.new("Armature", "ARMATURE")
    mod.object = rig

    # The shell stays, for the outline; it needs no texture.
    shell.name = name + ".hair_shell"
    plain = bpy.data.materials.new(name + ".hair_shell")
    shell.data.materials.clear()
    shell.data.materials.append(plain)
    if shell.data.shape_keys:
        shell.shape_key_clear()
    print("GROOM cards", len(faces), "quads", len(positions), "verts")
    return cards


def _tail_path(shell_verts, surface):
    """The ponytail's path: the shell's vertices well off the head, sliced
    along their long axis. points[0] is the end at the head."""
    off = []
    for p in shell_verts:
        loc, _, _, _ = surface(p)
        if np.linalg.norm(p - loc) > 0.035:
            off.append(p)
    off = np.array(off)
    if len(off) < 20:
        sys.exit("groom: a tie style needs a tail on its shell")
    mean = off.mean(0)
    _, _, vt = np.linalg.svd(off - mean, full_matrices=False)
    axis = vt[0]
    proj = (off - mean) @ axis
    near_end = off[np.argmin([np.linalg.norm(p - surface(p)[0]) for p in off])]
    if (near_end - mean) @ axis > 0:
        axis, proj = -axis, -proj
    lo, hi = proj.min(), proj.max()
    bins = max(4, int((hi - lo) / 0.02))
    points, radii = [], []
    for k in range(bins):
        a = lo + (hi - lo) * k / bins
        b = lo + (hi - lo) * (k + 1) / bins
        sel = off[(proj >= a) & (proj <= b)]
        if len(sel) < 3:
            continue
        cmean = sel.mean(0)
        points.append(cmean)
        radii.append(np.mean(np.linalg.norm((sel - cmean) - np.outer((sel - cmean) @ axis, axis), axis=1)))
    print("GROOM tail", len(points), "slices, %.2f m" % (hi - lo))
    return {"points": np.array(points), "radii": np.array(radii) * 0.85, "axis": axis}


def _tail_strand(tail, rng, start):
    pts, radii = tail["points"], tail["radii"]
    angle = rng.uniform(0.0, 2.0 * math.pi)
    radius = math.sqrt(rng.uniform(0.05, 1.0))
    length = rng.uniform(0.75, 1.0)
    path, normals = [], []
    last = int(len(pts) * length)
    for k in range(1, max(last, 2)):
        a = pts[k] - pts[k - 1]
        a /= np.linalg.norm(a)
        u = np.cross(a, [0.0, 0.0, 1.0]) if abs(a[2]) < 0.9 else np.cross(a, [1.0, 0.0, 0.0])
        u /= np.linalg.norm(u)
        v = np.cross(a, u)
        out = u * math.cos(angle) + v * math.sin(angle)
        blend = min(1.0, k / 2.0)
        p = pts[k] + out * radii[k] * radius
        if k == 1:
            p = start * (1 - blend) + p * blend
        path.append(p)
        normals.append(out)
    return path, normals


if __name__ == "__main__" and len(sys.argv) >= 3 and sys.argv[1] == "atlas":
    make_atlas(sys.argv[2])
    print("wrote", sys.argv[2])
