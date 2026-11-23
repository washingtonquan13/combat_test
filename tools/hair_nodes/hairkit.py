"""Hair kit for Blender 5.x: scripted guides + Blender's built-in hair node groups.

Run inside Blender (exec this file, then call the functions). See README.md in
this folder for what was learned about the nodes and how the pieces fit.
"""
import bpy, bmesh, math, random, os
from mathutils import Vector
from mathutils.bvhtree import BVHTree

CH = {
    "F": dict(body="CC_Base_Body", eye="CC_Base_Eye", col="F"),
    "M": dict(body="CC_Base_Body.001", eye="CC_Base_Eye.001", col="M"),
}
# Hairline as (azimuth from front, elevation) in degrees around the head centre.
# Hair grows above the line. Front, temple corner, sideburn, over the ear, nape.
HAIRLINE = [(0, 40), (25, 42), (42, 38), (55, 22), (63, -5), (69, -20), (74, -18), (78, 0),
            (95, 2), (112, 0), (118, -15), (135, -40), (180, -52)]
HAIRLINES = {
    # Set against measured face proportions (forehead = brow-to-nose length) and
    # reference photos: front line ~6.5 cm above the pupils, a temple peak at
    # brow level, a sideburn in front of the ear, and the line hugging the ear.
    "F": [(0, 24), (18, 25), (32, 24), (42, 19), (50, 10), (55, 2), (60, -8), (66, -18), (71, -30),
          (84, -30), (87, -6), (100, -4), (113, -7), (120, -22), (135, -42), (180, -52)],
    "M": [(0, 26), (20, 27), (34, 26), (44, 19), (51, 10), (55, 2), (60, -8), (66, -18), (71, -33),
          (84, -33), (88, -4), (100, -1), (113, -5), (120, -20), (135, -38), (180, -48)],
}
_cache = {}


def body_bvh(tag):
    key = ("bvh", tag)
    if key not in _cache:
        body = bpy.data.objects[CH[tag]["body"]]
        bm = bmesh.new(); bm.from_mesh(body.data); bm.transform(body.matrix_world); bm.normal_update()
        _cache[key] = (BVHTree.FromBMesh(bm), bm)
    return _cache[key][0]


def frame(tag):
    key = ("frame", tag)
    if key in _cache:
        return _cache[key]
    body = bpy.data.objects[CH[tag]["body"]]
    eye = bpy.data.objects[CH[tag]["eye"]]
    mw = body.matrix_world
    co = [mw @ v.co for v in body.data.vertices]
    top = max(c.z for c in co)
    eb = [eye.matrix_world @ Vector(c) for c in eye.bound_box]
    eyez = sum(v.z for v in eb) / 8
    mid = [c.y for c in co if abs(c.x) < 0.012 and eyez < c.z < top - 0.02]
    ymid = (min(mid) + max(mid)) / 2
    fr = dict(C=Vector((0, ymid, eyez + 0.02)), top=top, eyez=eyez, yfront=min(mid), yback=max(mid))
    _cache[key] = fr
    return fr


def sph(p, C):
    d = p - C
    phi = math.degrees(math.atan2(abs(d.x), -d.y))
    theta = math.degrees(math.atan2(d.z, math.hypot(d.x, d.y)))
    return phi, theta


def line_theta(phi, table):
    for (a, ta), (b, tb) in zip(table, table[1:]):
        if a <= phi <= b:
            return ta + (tb - ta) * (phi - a) / max(b - a, 1e-6)
    return table[-1][1]


def density_at(p, fr, table, soft):
    phi, theta = sph(p, fr["C"])
    t = (theta - line_theta(phi, table)) / soft
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def _drop(name):
    o = bpy.data.objects.get(name)
    if o:
        bpy.data.objects.remove(o, do_unlink=True)


def build_scalp(tag, table=None, soft=5.0, cuts=2, part=None):
    """Scalp_<tag>: subdivided copy of the head skin above the hairline, with a
    point attribute 'density' that fades to 0 over `soft` degrees at the edge.
    ScalpPaint_<tag>: the same shell tinted hair colour so skin never shows through."""
    fr = frame(tag)
    table = table or HAIRLINES[tag]
    body = bpy.data.objects[CH[tag]["body"]]
    bm = bmesh.new(); bm.from_mesh(body.data); bm.transform(body.matrix_world)
    lo = fr["C"].z - 0.16
    kill = [f for f in bm.faces if not any(
        v.co.z > lo and sph(v.co, fr["C"])[1] - line_theta(sph(v.co, fr["C"])[0], table) > -4 for v in f.verts)]
    bmesh.ops.delete(bm, geom=kill, context='FACES')
    bmesh.ops.subdivide_edges(bm, edges=bm.edges[:], cuts=cuts, use_grid_fill=True)
    if part is not None:
        # Cut the scalp along the parting (x = part, forehead to crown) so that
        # Interpolate's "Part by Mesh Islands" stops children blending across it.
        r = bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], dist=1e-5,
                                   plane_co=(part, 0, 0), plane_no=(1, 0, 0))
        cut = [e for e in r["geom_cut"] if isinstance(e, bmesh.types.BMEdge)
               and all(v.co.y < fr["C"].y + 0.05 and v.co.z > fr["C"].z for v in e.verts)]
        bmesh.ops.split_edges(bm, edges=cut)
    bm.verts.ensure_lookup_table()
    dens = {v: density_at(v.co, fr, table, soft) for v in bm.verts}
    kill = [f for f in bm.faces if max(dens[v] for v in f.verts) <= 0.0]
    bmesh.ops.delete(bm, geom=kill, context='FACES')
    bm.normal_update()
    bm.verts.ensure_lookup_table()
    vals = [dens[v] for v in bm.verts]
    for nm in ("Scalp_" + tag, "ScalpPaint_" + tag, "Hair_" + tag, "Fly_" + tag):
        _drop(nm)
    me = bpy.data.meshes.new("Scalp_" + tag); bm.to_mesh(me); bm.free()
    while len(me.materials):
        me.materials.pop()
    a = me.attributes.new("hair_density", 'FLOAT', 'POINT'); a.data.foreach_set("value", vals)
    ob = bpy.data.objects.new("Scalp_" + tag, me)
    bpy.data.collections[CH[tag]["col"]].objects.link(ob)
    ob.hide_render = True; ob.display_type = 'WIRE'
    ob.add_rest_position_attribute = True
    # tinted shell
    pm = me.copy(); pm.name = "ScalpPaint_" + tag
    for v in pm.vertices:
        v.co += v.normal * 0.0012
    po = bpy.data.objects.new("ScalpPaint_" + tag, pm)
    bpy.data.collections[CH[tag]["col"]].objects.link(po)
    pm.materials.append(paint_material())
    po.visible_shadow = False
    return len(me.polygons)


def paint_material(color=None, strength=None):
    m = bpy.data.materials.get("ScalpPaint")
    if not m:
        m = bpy.data.materials.new("ScalpPaint"); m.use_nodes = True
        nt = m.node_tree; nt.nodes.clear()
        out = nt.nodes.new("ShaderNodeOutputMaterial"); mix = nt.nodes.new("ShaderNodeMixShader")
        tr = nt.nodes.new("ShaderNodeBsdfTransparent"); df = nt.nodes.new("ShaderNodeBsdfDiffuse"); df.name = "Tint"
        at = nt.nodes.new("ShaderNodeAttribute"); at.attribute_name = "hair_density"
        mul = nt.nodes.new("ShaderNodeMath"); mul.name = "Strength"; mul.operation = 'MULTIPLY'
        mul.inputs[1].default_value = 0.85
        nt.links.new(at.outputs["Fac"], mul.inputs[0]); nt.links.new(mul.outputs[0], mix.inputs[0])
        nt.links.new(tr.outputs[0], mix.inputs[1]); nt.links.new(df.outputs[0], mix.inputs[2])
        nt.links.new(mix.outputs[0], out.inputs[0])
    if color:
        m.node_tree.nodes["Tint"].inputs[0].default_value = (*color, 1)
    if strength is not None:
        m.node_tree.nodes["Strength"].inputs[1].default_value = strength
    return m


def _resample(pts, n):
    L = [0.0]
    for a, b in zip(pts, pts[1:]):
        L.append(L[-1] + (b - a).length)
    out = []; j = 0
    for i in range(n):
        t = L[-1] * i / (n - 1)
        while j < len(pts) - 2 and L[j + 1] < t:
            j += 1
        s = L[j + 1] - L[j]
        out.append(pts[j].lerp(pts[j + 1], (t - L[j]) / s if s > 1e-9 else 0.0))
    return out


def grow(tag, style, n=420, spacing=0.008, NP=24, seed=3, step=0.006, name=None):
    """Grow guide curves. `style(info)` returns a dict per root:
    dir (world direction to comb toward), lift (0..1 off the scalp), length,
    grav (pull per step), stiff (steps before gravity is full), off (m off the
    skin), face_push (0..1), cut_z (stop below this height, or None),
    pull (callable(q, i, d) -> Vector to add, or None), skip (drop this root),
    wave ((amplitude m, wavelength m, coherence 0..1) or None)."""
    fr = frame(tag); C = fr["C"]
    scalp = bpy.data.objects["Scalp_" + tag]; sm = scalp.data
    bvh = body_bvh(tag)
    rnd = random.Random(seed)
    sm.calc_loop_triangles()
    dens = [d.value for d in sm.attributes["hair_density"].data]
    tris = [(t, t.area) for t in sm.loop_triangles]
    tot = sum(a for _, a in tris)
    roots = []; tries = 0
    while len(roots) < n and tries < 60000:
        tries += 1
        r = rnd.random() * tot
        for t, a in tris:
            r -= a
            if r <= 0:
                break
        v = [sm.vertices[i].co for i in t.vertices]
        u, w = rnd.random(), rnd.random()
        if u + w > 1:
            u, w = 1 - u, 1 - w
        p = v[0] + (v[1] - v[0]) * u + (v[2] - v[0]) * w
        d = sum(dens[i] for i in t.vertices) / 3
        if d < 0.3:
            continue
        if all((p - q[0]).length > spacing for q in roots):
            roots.append((p, t.normal.copy(), d))
    G = Vector((0, 0, -1))
    strands = []
    for p, nrm, d in roots:
        phi, theta = sph(p, C)
        info = dict(p=p, n=nrm, phi=phi, theta=theta, side=1.0 if p.x >= 0 else -1.0, edge=d,
                    u=rnd.random(), v=rnd.random(), fr=fr,
                    above=theta - line_theta(phi, HAIRLINES[tag]))
        s = dict(dir=Vector((0, 0.3, -1)), lift=0.3, length=0.2, grav=0.3, stiff=8, off=0.008,
                 face_push=0.6, cut_z=None, pull=None, skip=False, wave=None, smooth=2)
        s.update(style(info))
        if s["skip"]:
            continue
        comb = Vector(s["dir"])
        t = comb - nrm * comb.dot(nrm)
        t = t.normalized() if t.length > 1e-6 else nrm.copy()
        dr = (t * (1 - s["lift"]) + nrm * s["lift"]).normalized()
        q = p.copy(); pts = [q.copy()]
        nstep = max(2, int(s["length"] / step)); seg = s["length"] / nstep
        off_max = s["off"] * (0.5 + 1.0 * info["u"])
        near = 0.0
        last = dr.copy()
        for i in range(nstep):
            g = s["grav"] * min(1.0, 0.15 + i / max(1.0, s["stiff"]))
            dr = dr + G * g
            if s["pull"]:
                dr = dr + s["pull"](q, i, dr)
            if s["face_push"] > 0 and near < 0.05 and q.y - C.y < -0.012 and C.z - 0.2 < q.z < C.z + 0.05:
                sx = q.x if abs(q.x) > 1e-3 else info["side"]
                inward = max(0.0, 1.0 - abs(q.x) / 0.085)
                dr = dr + Vector((math.copysign(1.0, sx), 0.6, 0.0)) * s["face_push"] * 0.35 * (0.3 + inward)
            dr.normalize()
            prev = pts[-1]
            q = prev + dr * seg
            loc, nor, idx, dist = bvh.find_nearest(q)
            if loc is not None:
                near = dist
                off = 0.002 + (off_max - 0.002) * min(1.0, i / 5.0)
                if (q - loc).dot(nor) < 0 or dist < off:
                    # Slide along the skin; keep the last heading when gravity
                    # points straight into the surface, or the strand stalls and tangles.
                    t = dr - nor * dr.dot(nor)
                    if t.length < 0.35:
                        t = last - nor * last.dot(nor)
                    if t.length > 1e-6:
                        q = prev + t.normalized() * seg
                        loc, nor, idx, dist = bvh.find_nearest(q)
                    if (q - loc).dot(nor) < 0 or dist < off:
                        q = loc + nor * off
                    nd = q - prev
                    if nd.length > 1e-6:
                        dr = nd.normalized()
            last = dr.copy()
            if s["cut_z"] is not None and q.z < s["cut_z"]:
                a = pts[-1]
                if a.z > s["cut_z"] and a.z - q.z > 1e-6:
                    pts.append(a.lerp(q, (a.z - s["cut_z"]) / (a.z - q.z)))
                break
            pts.append(q.copy())
        if len(pts) < 2:
            continue
        pts = _resample(pts, NP)
        for _ in range(s["smooth"]):
            # Relax sharp bends (hair landing on a shoulder); roots stay put.
            src = [q.copy() for q in pts]
            for k in range(2, NP - 1):
                pts[k] = src[k] * 0.5 + (src[k - 1] + src[k + 1]) * 0.25
        if s["wave"]:
            # S-waves: neighbouring guides share a phase, so locks wave together.
            amp, lam, coherence = s["wave"]
            ph = coherence * (math.radians(phi) * 1.0 + p.z * 8.0) + (1 - coherence) * info["v"] * 6.28
            run = 0.0; src = [q.copy() for q in pts]
            for k in range(1, NP):
                tan = src[k] - src[k - 1]; run += tan.length
                lat = tan.cross(Vector((0, 0, 1)))
                if lat.length < 1e-6:
                    continue
                ramp = min(1.0, run / (lam * 0.75))
                pts[k] = src[k] + lat.normalized() * amp * ramp * math.sin(6.283 * run / lam + ph)
        strands.append(pts)
    name = name or ("Hair_" + tag)
    ho = bpy.data.objects.get(name)
    if not ho:
        hc = bpy.data.hair_curves.new(name)
        ho = bpy.data.objects.new(name, hc)
        bpy.data.collections[CH[tag]["col"]].objects.link(ho)
    hc = ho.data
    hc.remove_curves()
    hc.add_curves([NP] * len(strands))
    hc.attributes["position"].data.foreach_set("vector", [c for s in strands for p in s for c in p])
    hc.surface = scalp
    hc.surface_uv_map = scalp.data.uv_layers[0].name
    ho.parent = scalp
    hc.update_tag()
    for o in bpy.context.selected_objects:
        o.select_set(False)
    bpy.context.view_layer.objects.active = ho
    ho.select_set(True)
    bpy.ops.curves.snap_curves_to_surface(attach_mode='NEAREST')
    return len(strands)


def ensure_groups():
    p = os.path.join(bpy.utils.system_resource('DATAFILES'), "assets", "nodes", "procedural_hair_node_assets.blend")
    with bpy.data.libraries.load(p) as (src, dst):
        dst.node_groups = [n for n in src.node_groups if n not in bpy.data.node_groups]


def stack(ob, cfg, material=None):
    """cfg: list of (node group name, {input name: value}). A value ("attr", name)
    reads a named attribute instead of a constant."""
    ensure_groups()
    ob.modifiers.clear()
    for gname, params in cfg:
        ng = bpy.data.node_groups[gname]
        md = ob.modifiers.new(gname, 'NODES'); md.node_group = ng
        ids = {}
        for i in ng.interface.items_tree:
            if i.item_type == 'SOCKET' and i.in_out == 'INPUT':
                ids.setdefault(i.name, i.identifier)
        for k, v in params.items():
            inp = getattr(md.properties.inputs, ids[k])
            if isinstance(v, tuple) and v[0] == "attr":
                inp.type = 'ATTRIBUTE'; inp.attribute_name = v[1]
            else:
                inp.value = v
    if material:
        ob.data.materials.clear(); ob.data.materials.append(material)
    return [m.name for m in ob.modifiers]


def flyaways(tag, cfg, material=None):
    """Second, sparse hair object on the same guides for loose strands."""
    src = bpy.data.objects["Hair_" + tag]
    _drop("Fly_" + tag)
    ob = bpy.data.objects.new("Fly_" + tag, src.data)
    bpy.data.collections[CH[tag]["col"]].objects.link(ob)
    ob.parent = src.parent
    return stack(ob, cfg, None)


def hair_material(name, melanin=0.8, redness=0.4, rough=0.3, radial=0.35):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    hb = next((n for n in nt.nodes if n.type == "BSDF_HAIR_PRINCIPLED"), None)
    if not hb:
        nt.nodes.clear()
        out = nt.nodes.new("ShaderNodeOutputMaterial"); hb = nt.nodes.new("ShaderNodeBsdfHairPrincipled")
        nt.links.new(hb.outputs[0], out.inputs[0])
    hb.parametrization = 'MELANIN'
    hb.inputs["Melanin"].default_value = melanin
    hb.inputs["Melanin Redness"].default_value = redness
    hb.inputs["Roughness"].default_value = rough
    hb.inputs["Radial Roughness"].default_value = radial
    hb.inputs["Random Color"].default_value = 0.12
    hb.inputs["Random Roughness"].default_value = 0.1
    return m


def show(tag):
    for t, c in CH.items():
        for o in bpy.data.collections[c["col"]].objects:
            if o.name.startswith("Scalp_"):
                continue
            o.hide_render = t != tag


VIEWS = {"front": (0, -1), "front34": (0.5, -0.87), "side": (1, -0.02), "back34": (0.55, 0.84), "back": (0, 1), "top34": (0.35, -0.6, 1.0)}


def shot(tag, view, path, dz=-0.04, dist=1.15, res=(640, 760), samples=64):
    show(tag)
    sc = bpy.context.scene
    fr = frame(tag); cam = bpy.data.objects["Cam"]
    target = fr["C"] + Vector((0, 0, dz))
    v = VIEWS[view]
    pos = target + Vector((v[0], v[1], v[2] if len(v) > 2 else 0.08)).normalized() * dist
    cam.location = pos
    cam.rotation_euler = (target - pos).to_track_quat('-Z', 'Y').to_euler()
    for nm, (ax, ay, az) in {"Key": (0.9, -1.2, 0.9), "Fill": (-1.3, -0.8, 0.3), "Rim": (-0.6, 1.4, 1.0)}.items():
        l = bpy.data.objects[nm]
        l.location = target + Vector((ax, ay, az))
        l.rotation_euler = (target - l.location).to_track_quat('-Z', 'Y').to_euler()
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.cycles.samples = samples
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    return path
