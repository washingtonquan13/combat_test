class_name MeshClose
extends RefCounted

## Makes a scanned rock watertight. Poly Haven's low-poly scans are decimated
## in patches whose edges don't share vertices, so the surface is crossed by
## cracks a centimetre or more wide, and the side the scan never saw (a
## boulder's bottom, a cliff face's back, a terrain sheet's underside) is
## missing. With back faces culled, both show what's behind the rock: it
## reads as hollow.
##
## Cracks are zipped: a boundary vertex lying across a crack from an edge
## splits that edge, so both sides end up sharing it. What's still open after
## that is a real hole, and is capped by a polygon in its own plane.

const ATTRS := [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2]
const WIDTH := {Mesh.ARRAY_TANGENT: 4}

## How wide a gap still counts as a crack, against the mesh's diagonal.
const CRACK := 0.015


## Returns {mesh, open_dir, report}. `open_dir`, in the mesh's own space, is
## the way the capped holes face on balance (DOWN if nothing was capped), so
## a placement can still turn the smeared cap underground.
static func close(src: Mesh) -> Dictionary:
	assert(src.get_surface_count() == 1)
	var arrays := src.surface_get_arrays(0)
	for k in arrays.size():
		assert(arrays[k] == null or k in ATTRS or k == Mesh.ARRAY_INDEX, "MeshClose: unhandled array %d" % k)
	var ind: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var diag := src.get_aabb().size.length()
	var res := diag * 1e-5

	# 1. Zip the cracks.
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var weld := _weld(pos, res)
	var ids: PackedInt32Array = weld[0]
	var wpos: PackedVector3Array = weld[1]
	var open := _boundary(ind, ids)
	var tol := diag * CRACK
	var cell := tol
	var grid := {}
	for e: int in open.size() / 4:
		var a := wpos[ids[open[e * 4]]]
		var b := wpos[ids[open[e * 4 + 1]]]
		var lo := Vector3i(((a.min(b) - Vector3.ONE * tol) / cell).floor())
		var hi := Vector3i(((a.max(b) + Vector3.ONE * tol) / cell).floor())
		for x in range(lo.x, hi.x + 1):
			for y in range(lo.y, hi.y + 1):
				for z in range(lo.z, hi.z + 1):
					var key := Vector3i(x, y, z)
					if not grid.has(key):
						grid[key] = []
					grid[key].append(e)
	# The way the rim runs through each boundary vertex.
	var run := {}
	for e: int in open.size() / 4:
		var a := ids[open[e * 4]]
		var b := ids[open[e * 4 + 1]]
		var d := wpos[b] - wpos[a]
		run[a] = run.get(a, Vector3.ZERO) + d
		run[b] = run.get(b, Vector3.ZERO) + d
	var parent := PackedInt32Array()
	parent.resize(wpos.size())
	for i in wpos.size():
		parent[i] = i
	var splits := {}  # boundary edge -> [[t, welded vertex], ...]
	var n_split := 0
	var n_merge := 0
	for v: int in run:
		var p := wpos[v]
		var dv: Vector3 = run[v].normalized()
		var best := tol
		var hit := -1
		var hit_t := 0.0
		var key := Vector3i((p / cell).floor())
		if not grid.has(key):
			continue
		for e: int in grid[key]:
			var a := ids[open[e * 4]]
			var b := ids[open[e * 4 + 1]]
			if a == v or b == v:
				continue
			var ab := wpos[b] - wpos[a]
			if ab.normalized().dot(dv) > -0.3:
				continue  # not the other side of a crack: that runs the other way
			var t := clampf((p - wpos[a]).dot(ab) / maxf(ab.length_squared(), 1e-20), 0.0, 1.0)
			var dist := p.distance_to(wpos[a] + ab * t)
			if dist < best:
				best = dist
				hit = e
				hit_t = t
		if hit < 0:
			continue
		var len := (wpos[ids[open[hit * 4 + 1]]] - wpos[ids[open[hit * 4]]]).length()
		var end := maxf(best, len * 0.12)
		if hit_t * len < end:
			_union(parent, v, ids[open[hit * 4]])
			n_merge += 1
		elif (1.0 - hit_t) * len < end:
			_union(parent, v, ids[open[hit * 4 + 1]])
			n_merge += 1
		else:
			if not splits.has(hit):
				splits[hit] = []
			splits[hit].append([hit_t, v])
			n_split += 1
	# Merged vertices meet halfway.
	var sum := {}
	for i in wpos.size():
		var r := _find(parent, i)
		var s: Vector4 = sum.get(r, Vector4.ZERO)
		sum[r] = s + Vector4(wpos[i].x, wpos[i].y, wpos[i].z, 1.0)
	var final := PackedVector3Array()
	final.resize(wpos.size())
	for i in wpos.size():
		var s: Vector4 = sum[_find(parent, i)]
		final[i] = Vector3(s.x, s.y, s.z) / s.w
	var out := {}
	for k: int in ATTRS:
		if arrays[k] != null:
			out[k] = arrays[k].duplicate()
	var vp: PackedVector3Array = out[Mesh.ARRAY_VERTEX]
	for i in vp.size():
		vp[i] = final[ids[i]]
	out[Mesh.ARRAY_VERTEX] = vp
	# Split triangles. A boundary edge has one triangle, and runs its way.
	var by_tri := {}
	for e: int in splits:
		by_tri[open[e * 4 + 2]] = true
	var tris := PackedInt32Array()
	for t in ind.size() / 3:
		if not by_tri.has(t):
			tris.append_array([ind[t * 3], ind[t * 3 + 1], ind[t * 3 + 2]])
	var edge_of := {}  # (triangle, corner) -> boundary edge
	for e: int in open.size() / 4:
		edge_of[Vector2i(open[e * 4 + 2], open[e * 4 + 3])] = e
	for t: int in by_tri:
		var ring := PackedInt32Array()
		var cut := 0
		for c in 3:
			var ia := ind[t * 3 + c]
			var ib := ind[t * 3 + (c + 1) % 3]
			ring.append(ia)
			var e: int = edge_of.get(Vector2i(t, c), -1)
			if e < 0 or not splits.has(e):
				continue
			cut += 1
			var list: Array = splits[e]
			list.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
			for s: Array in list:
				ring.append(_add_vertex(out, ia, ib, s[0], final[s[1]]))
		var centre: int
		var start := 0
		if cut == 1:
			# Fan from the corner across from the cut edge.
			for c in 3:
				if splits.has(edge_of.get(Vector2i(t, c), -1)):
					centre = ind[t * 3 + (c + 2) % 3]
					start = ring.find(centre)
			for i in ring.size() - 2:
				tris.append_array([ring[(start + 1 + i) % ring.size()], ring[(start + 2 + i) % ring.size()], centre])
		else:
			centre = _add_centre(out, [ind[t * 3], ind[t * 3 + 1], ind[t * 3 + 2]])
			for i in ring.size():
				tris.append_array([ring[i], ring[(i + 1) % ring.size()], centre])

	# 2. Cap what's still open.
	vp = out[Mesh.ARRAY_VERTEX]
	weld = _weld(vp, res)
	ids = weld[0]
	wpos = weld[1]
	# Merges fold some triangles to a line; they'd only confuse the rims.
	var kept := PackedInt32Array()
	var n_drop := 0
	for t in tris.size() / 3:
		var a := ids[tris[t * 3]]
		var b := ids[tris[t * 3 + 1]]
		var c := ids[tris[t * 3 + 2]]
		if a == b or b == c or c == a:
			n_drop += 1
		else:
			kept.append_array([tris[t * 3], tris[t * 3 + 1], tris[t * 3 + 2]])
	tris = kept
	open = _boundary(tris, ids)
	var nrm: PackedVector3Array = out[Mesh.ARRAY_NORMAL]
	var facing := 0.0  # which way a cross product of a triangle points: out or in
	for t in tris.size() / 3:
		var a := vp[tris[t * 3]]
		facing += (vp[tris[t * 3 + 1]] - a).cross(vp[tris[t * 3 + 2]] - a).dot(nrm[tris[t * 3]])
	facing = signf(facing)
	var loops := _loops(open, ids)
	var open_dir := Vector3.ZERO
	var n_cap := 0
	var failed := 0
	for loop: PackedInt32Array in loops:
		# Corners are the loop's own vertices, so the cap takes their texture.
		var corner := PackedInt32Array()
		var ring := PackedVector3Array()
		var newell := Vector3.ZERO
		for i in loop.size():
			corner.append(loop[i])
			ring.append(vp[loop[i]])
		for i in ring.size():
			var a := ring[i]
			var b := ring[(i + 1) % ring.size()]
			newell += Vector3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
		if newell.length_squared() < 1e-24:
			failed += 1
			continue
		var nz := newell.normalized()
		var nx := nz.cross(Vector3.UP if absf(nz.y) < 0.9 else Vector3.RIGHT).normalized()
		var ny := nz.cross(nx)
		var flat := PackedVector2Array()
		for p in ring:
			flat.append(Vector2(p.dot(nx), p.dot(ny)))
		var cap := Geometry2D.triangulate_polygon(flat)
		if cap.is_empty():
			cap = PackedInt32Array()
			for i in range(1, ring.size() - 1):
				cap.append_array([0, i, i + 1])
		var area := Vector3.ZERO
		for i in range(0, cap.size(), 3):
			var a := ring[cap[i]]
			var cr := (ring[cap[i + 1]] - a).cross(ring[cap[i + 2]] - a)
			# The rim runs the way the triangles beside it do; the cap must
			# run it backwards, so it winds against the rim's own polygon.
			if cr.dot(newell) > 0.0:
				tris.append_array([corner[cap[i]], corner[cap[i + 2]], corner[cap[i + 1]]])
				cr = -cr
			else:
				tris.append_array([corner[cap[i]], corner[cap[i + 1]], corner[cap[i + 2]]])
			area += cr
		open_dir += area * facing
		n_cap += 1
	var left := _boundary(tris, ids).size() / 4
	out[Mesh.ARRAY_INDEX] = tris
	var full := []
	full.resize(Mesh.ARRAY_MAX)
	for k: int in out:
		full[k] = out[k]
	var im := ImporterMesh.new()
	im.add_surface(Mesh.PRIMITIVE_TRIANGLES, full, [], {}, src.surface_get_material(0))
	im.generate_lods(25.0, 60.0, [])
	return {
		"mesh": im.get_mesh(),
		"open_dir": open_dir.normalized() if open_dir.length_squared() > 0.0 else Vector3.DOWN,
		"report": "%d cracks split, %d merged, %d folded tris dropped, %d holes capped, %d bad loops, %d open edges left" % [n_split, n_merge, n_drop, n_cap, failed, left],
		"left": left,
	}


static func _weld(pos: PackedVector3Array, res: float) -> Array:
	var ids := PackedInt32Array()
	ids.resize(pos.size())
	var map := {}
	var wpos := PackedVector3Array()
	for i in pos.size():
		var key := Vector3i((pos[i] / res).round())
		if not map.has(key):
			map[key] = wpos.size()
			wpos.append(pos[i])
		ids[i] = map[key]
	return [ids, wpos]


## Edges used by one triangle only, as [from, to, triangle, corner] in
## original vertex indices, running the way their triangle runs.
static func _boundary(ind: PackedInt32Array, ids: PackedInt32Array) -> PackedInt32Array:
	var count := {}
	for t in ind.size() / 3:
		for c in 3:
			var a := ids[ind[t * 3 + c]]
			var b := ids[ind[t * 3 + (c + 1) % 3]]
			var key := Vector2i(mini(a, b), maxi(a, b))
			count[key] = count.get(key, 0) + 1
	var out := PackedInt32Array()
	for t in ind.size() / 3:
		for c in 3:
			var a := ids[ind[t * 3 + c]]
			var b := ids[ind[t * 3 + (c + 1) % 3]]
			if a != b and count[Vector2i(mini(a, b), maxi(a, b))] == 1:
				out.append_array([ind[t * 3 + c], ind[t * 3 + (c + 1) % 3], t, c])
	return out


## Closed rims of boundary edges, as original vertex indices in the way the
## triangles beside them run.
static func _loops(open: PackedInt32Array, ids: PackedInt32Array) -> Array[PackedInt32Array]:
	var next := {}  # welded from -> list of edge indices
	for e in open.size() / 4:
		var a := ids[open[e * 4]]
		if not next.has(a):
			next[a] = []
		next[a].append(e)
	var used := {}
	var loops: Array[PackedInt32Array] = []
	for e0 in open.size() / 4:
		if used.has(e0):
			continue
		var loop := PackedInt32Array()
		var e := e0
		while not used.has(e):
			used[e] = true
			loop.append(open[e * 4])
			var to := ids[open[e * 4 + 1]]
			var nxt := -1
			for c: int in next.get(to, []):
				if not used.has(c):
					nxt = c
					break
			if nxt < 0:
				break
			e = nxt
		if loop.size() >= 3:
			loops.append(loop)
	return loops


static func _add_vertex(out: Dictionary, ia: int, ib: int, t: float, at: Vector3) -> int:
	var n: int = out[Mesh.ARRAY_VERTEX].size()
	for k: int in out:
		var arr = out[k]
		if k == Mesh.ARRAY_VERTEX:
			arr.append(at)
		elif k == Mesh.ARRAY_TANGENT:
			for j in 4:
				arr.append(lerpf(arr[ia * 4 + j], arr[ib * 4 + j], t))
		elif k == Mesh.ARRAY_NORMAL:
			arr.append(arr[ia].lerp(arr[ib], t).normalized())
		else:
			arr.append(arr[ia].lerp(arr[ib], t))
		out[k] = arr
	return n


static func _add_centre(out: Dictionary, c: Array) -> int:
	var n: int = out[Mesh.ARRAY_VERTEX].size()
	for k: int in out:
		var arr = out[k]
		if k == Mesh.ARRAY_TANGENT:
			for j in 4:
				arr.append((arr[c[0] * 4 + j] + arr[c[1] * 4 + j] + arr[c[2] * 4 + j]) / 3.0)
		elif k == Mesh.ARRAY_NORMAL:
			arr.append((arr[c[0]] + arr[c[1]] + arr[c[2]]).normalized())
		else:
			arr.append((arr[c[0]] + arr[c[1]] + arr[c[2]]) / 3.0)
		out[k] = arr
	return n


static func _find(parent: PackedInt32Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i


static func _union(parent: PackedInt32Array, a: int, b: int) -> void:
	parent[_find(parent, a)] = _find(parent, b)
