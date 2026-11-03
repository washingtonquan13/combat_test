extends RefCounted

# Where the posed mannequin goes through itself or its weapon. The body
# mesh is skinned on the CPU the way the GPU does it, its surface sampled
# every couple of centimetres and each sample given to a part by the bone
# that moves it most: the head, the torso, each upper arm, forearm, hand,
# thigh and shin. A sample of one part lies inside another when the other's
# nearest sample faces away from it, the sample lying along that one's
# inward normal: off to its side it is past an open edge of the other part,
# like the neck's cut, not in it. Samples by a seam between parts, where a
# part's surface is open, never say a point is inside. How far in is the
# depth. Parts that meet
# at a joint are not checked against each other: their skin is one sheet
# there and folds into itself by design.
#
# The weapon's meshes are sampled the same way and checked against every
# part but the hands that hold it.

enum Part { HEAD, TORSO, L_UPPER, L_FORE, L_HAND, R_UPPER, R_FORE, R_HAND, L_THIGH, L_SHIN, R_THIGH, R_SHIN, WEAPON }

const NAMES := ["head", "torso", "left upper arm", "left forearm", "left hand", "right upper arm", "right forearm", "right hand", "left thigh", "left shin", "right thigh", "right shin", "weapon"]

# Neighbours across a joint, never checked.
const ADJACENT := [
	[Part.HEAD, Part.TORSO],
	[Part.TORSO, Part.L_UPPER], [Part.L_UPPER, Part.L_FORE], [Part.L_FORE, Part.L_HAND],
	[Part.TORSO, Part.R_UPPER], [Part.R_UPPER, Part.R_FORE], [Part.R_FORE, Part.R_HAND],
	[Part.TORSO, Part.L_THIGH], [Part.L_THIGH, Part.L_SHIN],
	[Part.TORSO, Part.R_THIGH], [Part.R_THIGH, Part.R_SHIN],
	[Part.WEAPON, Part.L_HAND], [Part.WEAPON, Part.R_HAND],
]

# Sample spacing on the surface, metres.
const SPACING := 0.015
const CELL := 0.03
# How far in a sample is still looked for: past this it reads as outside.
const REACH := 0.12
# Deeper than this, over at least MIN_SAMPLES samples, is a clip.
const DEPTH := 0.015
const MIN_SAMPLES := 3
# Within this angle of the nearest sample's inward normal.
const INWARD := 0.7
# A triangle with less of its weight than this on its own part is at a seam.
const SEAM := 0.8

var _skeleton: Skeleton3D
# The body mesh: rest vertices and normals, four bind indices and weights
# each, and per bind the skeleton bone and the bind pose.
var _verts := PackedVector3Array()
var _normals := PackedVector3Array()
var _bones := PackedInt32Array()
var _weights := PackedFloat32Array()
var _bind_bone := PackedInt32Array()
var _bind_pose: Array[Transform3D] = []
# Body samples: a triangle's three vertices and where in it.
var _tri := PackedInt32Array()
var _bary := PackedVector3Array()
var _part := PackedInt32Array()
var _seam := PackedByteArray()
# The weapon's samples, in its own space, and the node they belong to.
var _weapon: Node3D
var _weapon_points := PackedVector3Array()
var _weapon_normals := PackedVector3Array()


func _init(skeleton: Skeleton3D, body: MeshInstance3D) -> void:
	_skeleton = skeleton
	var skin := body.skin
	for i in skin.get_bind_count():
		var name := skin.get_bind_name(i)
		_bind_bone.append(skeleton.find_bone(name) if name != "" else skin.get_bind_bone(i))
		_bind_pose.append(skin.get_bind_pose(i))
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	for s in body.mesh.get_surface_count():
		var arrays := body.mesh.surface_get_arrays(s)
		var base := _verts.size()
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		var per := bones.size() / verts.size()
		_verts.append_array(verts)
		_normals.append_array(arrays[Mesh.ARRAY_NORMAL])
		# Keep the four heaviest of however many the mesh carries.
		for v in verts.size():
			var order := range(per)
			order.sort_custom(func(a: int, b: int) -> bool: return weights[v * per + a] > weights[v * per + b])
			for k in 4:
				_bones.append(bones[v * per + order[k]] if k < per else 0)
				_weights.append(weights[v * per + order[k]] if k < per else 0.0)
		var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for t in range(0, index.size(), 3):
			var ia := base + index[t]
			var ib := base + index[t + 1]
			var ic := base + index[t + 2]
			var share := _part_of(ia, ib, ic)
			if share.x < 0:
				continue
			for b: Vector3 in _scatter(_verts[ia], _verts[ib], _verts[ic], rng):
				_tri.append_array([ia, ib, ic])
				_bary.append(b)
				_part.append(int(share.x))
				_seam.append(1 if share.y < SEAM else 0)


# Barycentric points over a triangle, one per SPACING squared of its area.
static func _scatter(a: Vector3, b: Vector3, c: Vector3, rng: RandomNumberGenerator) -> Array[Vector3]:
	var area := (b - a).cross(c - a).length() * 0.5
	var expected := area / (SPACING * SPACING)
	var n := int(expected)
	if rng.randf() < expected - n:
		n += 1
	var out: Array[Vector3] = []
	for i in n:
		var u := rng.randf()
		var v := rng.randf()
		if u + v > 1.0:
			u = 1.0 - u
			v = 1.0 - v
		out.append(Vector3(1.0 - u - v, u, v))
	return out


# The part a triangle belongs to, the one whose bones weigh most over its
# three vertices, and the share of the weight that is: x the part (-1 for
# none), y the share.
func _part_of(ia: int, ib: int, ic: int) -> Vector2:
	var sum := {}
	var total := 0.0
	for v: int in [ia, ib, ic]:
		for k in 4:
			var part := _part_of_bone(_skeleton.get_bone_name(_bind_bone[_bones[v * 4 + k]]))
			sum[part] = sum.get(part, 0.0) + _weights[v * 4 + k]
			total += _weights[v * 4 + k]
	var best := -1
	var most := 0.0
	for part: int in sum:
		if sum[part] > most:
			most = sum[part]
			best = part
	return Vector2(best, most / maxf(total, 1e-6))


static func _part_of_bone(bone: String) -> int:
	var left := bone.begins_with("Left")
	if bone.contains("Head") or bone.contains("Neck") or bone.contains("Jaw") or bone.contains("Eye"):
		return Part.HEAD
	if bone.contains("UpperArm"):
		return Part.L_UPPER if left else Part.R_UPPER
	if bone.contains("LowerArm"):
		return Part.L_FORE if left else Part.R_FORE
	for hand: String in ["Hand", "Thumb", "Index", "Middle", "Ring", "Little"]:
		if bone.contains(hand):
			return Part.L_HAND if left else Part.R_HAND
	if bone.contains("UpperLeg"):
		return Part.L_THIGH if left else Part.R_THIGH
	if bone.contains("LowerLeg") or bone.contains("Foot") or bone.contains("Toes"):
		return Part.L_SHIN if left else Part.R_SHIN
	if bone.contains("Hips") or bone.contains("Spine") or bone.contains("Chest") or bone.contains("Shoulder"):
		return Part.TORSO
	return -1


# The weapon to check, or null. Its meshes are sampled once per node.
func set_weapon(weapon: Node3D) -> void:
	if weapon == _weapon:
		return
	_weapon = weapon
	_weapon_points = PackedVector3Array()
	_weapon_normals = PackedVector3Array()
	if weapon == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 2
	var to_weapon := weapon.global_transform.affine_inverse()
	for mi: MeshInstance3D in weapon.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		var local := to_weapon * mi.global_transform
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			if index.is_empty():
				index = PackedInt32Array(range(verts.size()))
			for t in range(0, index.size(), 3):
				var a := verts[index[t]]
				var b := verts[index[t + 1]]
				var c := verts[index[t + 2]]
				for w: Vector3 in _scatter(a, b, c, rng):
					_weapon_points.append(local * (a * w.x + b * w.y + c * w.z))
					var n := normals[index[t]] * w.x + normals[index[t + 1]] * w.y + normals[index[t + 2]] * w.z
					_weapon_normals.append((local.basis * n).normalized())


# Every clip in the current pose, deepest first: {"into", "from", "depth",
# "at", "count"}, depth in metres, `at` the deepest sample in skeleton
# space.
func overlaps() -> Array[Dictionary]:
	var points := PackedVector3Array()
	var normals := PackedVector3Array()
	var parts := PackedInt32Array()
	_skin_samples(points, normals, parts)
	var seam := _seam.duplicate()
	if _weapon != null and is_instance_valid(_weapon):
		var to_skeleton := _skeleton.global_transform.affine_inverse() * _weapon.global_transform
		for i in _weapon_points.size():
			points.append(to_skeleton * _weapon_points[i])
			normals.append((to_skeleton.basis * _weapon_normals[i]).normalized())
			parts.append(Part.WEAPON)
			seam.append(0)
	# A grid and a box per part.
	var grids := []
	var boxes := []
	for p in NAMES.size():
		grids.append({})
		boxes.append(null)
	for i in points.size():
		var p := parts[i]
		var cell := Vector3i((points[i] / CELL).floor())
		var grid: Dictionary = grids[p]
		if not grid.has(cell):
			grid[cell] = PackedInt32Array()
		grid[cell].append(i)
		boxes[p] = AABB(points[i], Vector3.ZERO) if boxes[p] == null else (boxes[p] as AABB).expand(points[i])
	var worst := {}
	for i in points.size():
		var from := parts[i]
		for into in NAMES.size():
			if into == from or boxes[into] == null or _adjacent(from, into):
				continue
			if not (boxes[into] as AABB).grow(REACH).has_point(points[i]):
				continue
			var q := _nearest(points, grids[into], points[i])
			if q < 0 or seam[q]:
				continue
			var d := points[i] - points[q]
			var depth := d.length()
			if d.dot(normals[q]) > -INWARD * depth:
				continue
			var key := Vector2i(into, from)
			var w: Dictionary = worst.get(key, {"into": into, "from": from, "depth": 0.0, "count": 0})
			if depth > DEPTH:
				w["count"] += 1
			if depth > w["depth"]:
				w["depth"] = depth
				w["at"] = points[i]
			worst[key] = w
	# One line a pair, the way it goes in deeper.
	var pairs := {}
	for w: Dictionary in worst.values():
		if w["count"] < MIN_SAMPLES:
			continue
		var key := Vector2i(mini(w["into"], w["from"]), maxi(w["into"], w["from"]))
		if not pairs.has(key) or w["depth"] > pairs[key]["depth"]:
			pairs[key] = w
	var out: Array[Dictionary] = []
	out.assign(pairs.values())
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["depth"] > b["depth"])
	return out


static func describe(clip: Dictionary) -> String:
	return "%s %.0f cm into %s" % [NAMES[clip["from"]], clip["depth"] * 100.0, NAMES[clip["into"]]]


static func _adjacent(a: int, b: int) -> bool:
	for pair: Array in ADJACENT:
		if (pair[0] == a and pair[1] == b) or (pair[0] == b and pair[1] == a):
			return true
	return false


# The nearest sample in `grid` within REACH, or -1. Rings of cells outward
# until the best found is nearer than the ring's inner edge.
static func _nearest(points: PackedVector3Array, grid: Dictionary, p: Vector3) -> int:
	var centre := Vector3i((p / CELL).floor())
	var best := -1
	var best_d := REACH * REACH
	var rings := int(ceil(REACH / CELL))
	for r in range(1, rings + 1):
		for x in range(-r, r + 1):
			for y in range(-r, r + 1):
				for z in range(-r, r + 1):
					if maxi(absi(x), maxi(absi(y), absi(z))) != r and r > 1:
						continue
					var cell: Variant = grid.get(centre + Vector3i(x, y, z))
					if cell == null:
						continue
					for i: int in cell:
						var d := p.distance_squared_to(points[i])
						if d < best_d:
							best_d = d
							best = i
		if best >= 0 and best_d <= pow((r) * CELL, 2):
			return best
	return best


# The body samples where the current pose puts them, in skeleton space.
func _skin_samples(points: PackedVector3Array, normals: PackedVector3Array, parts: PackedInt32Array) -> void:
	var binds: Array[Transform3D] = []
	for i in _bind_bone.size():
		binds.append(_skeleton.get_bone_global_pose(_bind_bone[i]) * _bind_pose[i])
	var skinned := PackedVector3Array()
	var skinned_n := PackedVector3Array()
	skinned.resize(_verts.size())
	skinned_n.resize(_verts.size())
	for v in _verts.size():
		var p := Vector3.ZERO
		var n := Vector3.ZERO
		for k in 4:
			var w := _weights[v * 4 + k]
			if w <= 0.0:
				continue
			var t := binds[_bones[v * 4 + k]]
			p += (t * _verts[v]) * w
			n += (t.basis * _normals[v]) * w
		skinned[v] = p
		skinned_n[v] = n
	for s in _part.size():
		var a := _tri[s * 3]
		var b := _tri[s * 3 + 1]
		var c := _tri[s * 3 + 2]
		var w := _bary[s]
		points.append(skinned[a] * w.x + skinned[b] * w.y + skinned[c] * w.z)
		normals.append((skinned_n[a] * w.x + skinned_n[b] * w.y + skinned_n[c] * w.z).normalized())
		parts.append(_part[s])
