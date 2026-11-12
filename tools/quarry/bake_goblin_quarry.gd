extends SceneTree

# Bakes the Old Quarry: a sculpted bowl in rolling hills, dressed with scanned
# rocks and plants, with collision the nav grid reads as exact triangles.
# Writes world/goblin_quarry/terrain.scn and rewrites world/goblin_quarry.tscn
# from the retired blockout: the blockout's ground goes, its town, camp,
# units, exit and ladder stay and are seated on the new ground.
#
#   godot --path . -s tools/quarry/bake_goblin_quarry.gd
#
# Run it windowed: headless Godot saves every MultiMesh transform as zero.

const OLD_SCENE := "res://world/retired/goblin_quarry_blockout.tscn"
const NEW_SCENE := "res://world/goblin_quarry.tscn"
const OUT := "res://world/goblin_quarry/"
const M := "res://assets/level/quarry/models/"
const T := "res://assets/level/quarry/textures/"

const CELL := 0.4
const TILE := 24.0
# What is drawn, and the smaller part that has collision and can be walked.
const X0 := -64.0
const X1 := 64.0
const Z0 := -104.0
const Z1 := 84.0
const CX0 := -52.0
const CX1 := 52.0
const CZ0 := -92.0
const CZ1 := 72.0

const RAMP_A := Vector2(15.5, -33.5)
const RAMP_B := Vector2(9.5, -50.0)
const CAMP := Vector2(0.0, -48.0)
const ROAD := [Vector2(2, 22), Vector2(8, 0), Vector2(13, -20), RAMP_A]
const FLOOR_PATH := [RAMP_B, Vector2(5, -48.5), Vector2(0, -46.5), Vector2(-7, -48), Vector2(-12.5, -50)]
const LADDER_BASE := Vector2(-13.4, -50.0)
const LADDER_TOP := Vector2(-14.8, -50.0)
# A stream from a spring in the west hills, down a gully that splits the
# field from the quarry rim, into a pond at its east end. The gully is cut
# about 3 m into the ground with steep walls; the road fords it, and a log
# bridges it further west. Shallow throughout: units wade it.
const STREAM := [Vector2(-40, -17), Vector2(-28, -22), Vector2(-14, -25.5), Vector2(0, -26), Vector2(10, -24.5), Vector2(17.5, -23.4)]
const POND := Vector2(22.0, -23.0)
const POND_R := Vector2(5.5, 4.0)
const GULLY_HW := 2.6
const FORD := Vector2(13.7, -24.0)
const LOG_A := Vector2(-11.4, -20.8)
const LOG_B := Vector2(-10.6, -30.6)
# Archer perches on the rim over the camp: [centre, the way its gentle side faces].
const KNOLLS := [[Vector2(-4.0, -31.0), Vector2(-1, 0)], [Vector2(6.0, -30.0), Vector2(1, 0)]]
const SHELF := Vector2(-6.0, -36.5)
const SPIRE := Vector2(-24.0, -62.0)
## The spider cave's entrance: a rock outcrop (tools/cave/cave_volume.py
## --mouth, which holds the same numbers) with a tunnel into the south cliff.
## The ground is cut to just under the tunnel's floor where the outcrop
## stands, and raised to it in front, so the cliff doesn't fill the tunnel.
const CAVE_MOUTH := Vector2(-14.0, -79.0)
const CAVE_FLOOR := 3.6
const F := "res://assets/level/forest/"

# Places clutter must leave alone: [centre, radius]. Houses, props, units,
# spawn and exit, the ladder's ends, and the spots the tests walk to.
const KEEP_OUT := [
	[Vector2(-13, 30), 5.0], [Vector2(-14, 40), 4.5], [Vector2(14, 28), 5.0], [Vector2(13, 39), 5.5],
	[Vector2(-7, 23), 3.5], [Vector2(-3, 22), 2.0], [Vector2(3.5, -2), 2.5], [Vector2(-4.5, -14), 3.0],
	[Vector2(-8, -52), 2.8], [Vector2(5, -54), 2.8],
	[Vector2(-3.5, -41), 1.6], [Vector2(-2.4, -41.3), 1.6], [Vector2(4, -42), 1.6],
	[CAMP, 5.5], [Vector2(0.5, 20), 1.5], [Vector2(-2, -45.5), 1.5], [Vector2(2, -46), 1.5],
	[Vector2(0, -57.5), 1.5], [Vector2(2, 32), 1.5], [Vector2(0, 43), 3.0], [Vector2(0, 40), 2.0],
	[Vector2(4, 34), 2.5], [LADDER_BASE, 2.5], [LADDER_TOP, 2.5],
	[Vector2(-10.4, -48), 1.2], [Vector2(-10.4, -46.5), 1.2], [Vector2(-5.4, -50), 1.2],
	[Vector2(4, 30), 1.5], [Vector2(0, -44), 1.5], [Vector2(6, -40), 1.5], [Vector2(12, -30), 1.5],
	[LOG_A, 2.0], [LOG_B, 2.0], [(LOG_A + LOG_B) * 0.5, 2.5],
	[CAVE_MOUTH + Vector2(0, 7), 3.5], [CAVE_MOUTH + Vector2(0, 2), 4.5], [CAVE_MOUTH + Vector2(0, -3), 6.0],
]

var _rng := RandomNumberGenerator.new()
var _warp := FastNoiseLite.new()
var _big := FastNoiseLite.new()
var _small := FastNoiseLite.new()
var _patch := FastNoiseLite.new()
var _nx := 0
var _nz := 0
var _hgrid := PackedFloat32Array()
var _hA := 0.0
var _hB := 0.0
## Poly Haven scans that come cracked and backless; MeshClose seals them.
const MeshCloser := preload("res://tools/quarry/mesh_close.gd")
const SCANNED_ROCKS := ["rock_moss_set_01", "rock_moss_set_02", "rock_face_01", "rock_face_02", "rock_07", "rock_09", "coast_rocks_01", "coast_rocks_02"]
# Scans whose gloss map says polished stone; see _dry_stone.
const POLISHED_ROCKS := ["rock_07", "rock_09"]

var _open_cache := {}
var _convex_cache := {}
var _saved := {}
var _batches := {}
var _obstacles: StaticBody3D
var _obstacle_count := 0
var _stream_lv := PackedFloat32Array()
var _stream_len := 0.0
var _pond_lv := 0.0
# The trees, planned before the ground is painted so the floor under them can
# go bare: each is {at, kind, pick, size, yaw, lean}. Their own random stream,
# so moving a tree doesn't reshuffle every rock.
var _trees: Array[Dictionary] = []
## Tree spots turned down for bad footing, for the bake log.
var _unfooted := 0
const FOOT_R := 2.0
const FOOT_STEP := 0.6
var _trng := RandomNumberGenerator.new()
var _canopy := PackedFloat32Array()
var _cnx := 0
var _cnz := 0
const CAN := 1.0


func _initialize() -> void:
	# `-- --dump-heights <file>` writes the height grid and the paint for
	# tools/quarry/terrain_relief.py and stops; that much runs headless.
	var args := OS.get_cmdline_user_args()
	var dump := args.find("--dump-heights")
	if dump < 0 and DisplayServer.get_name() == "headless":
		push_error("Run the quarry bake windowed: headless Godot saves every MultiMesh transform as zero.")
		quit(1)
		return
	_rng.seed = 41
	_warp.seed = 3
	_warp.frequency = 0.09
	_big.seed = 8
	_big.frequency = 0.05
	_small.seed = 12
	_small.frequency = 0.35
	_patch.seed = 21
	_patch.frequency = 0.11
	for i in STREAM.size() - 1:
		_stream_len += (STREAM[i] as Vector2).distance_to(STREAM[i + 1])
	_hA = _h_base(RAMP_A.x, RAMP_A.y)
	_hB = _h_base(RAMP_B.x, RAMP_B.y)

	var t0 := Time.get_ticks_msec()
	_plan_water()
	_bake_heights()
	print("heights %d x %d in %d ms" % [_nx, _nz, Time.get_ticks_msec() - t0])
	if dump >= 0:
		_plan_trees()
		_dump_heights(args[dump + 1])
		quit(0)
		return
	for spot: Array in [["ramp top", RAMP_A], ["ramp foot", RAMP_B], ["camp", CAMP], ["ledge", Vector2(0, -57.5)],
			["ladder base", LADDER_BASE], ["ladder top", LADDER_TOP], ["town", Vector2(4, 30)], ["exit", Vector2(0, 43)],
			["field", Vector2(-4.5, -14)], ["ford", FORD], ["log field end", LOG_A], ["log rim end", LOG_B],
			["knoll west", KNOLLS[0][0]], ["knoll east", KNOLLS[1][0]], ["shelf", SHELF], ["spire", SPIRE],
			["spire foot", SPIRE + Vector2(7, 4)], ["pond", POND], ["cave mouth", CAVE_MOUTH + Vector2(0, 6)],
			["cave tunnel", CAVE_MOUTH + Vector2(0, -1)], ["cave arrival", CAVE_MOUTH + Vector2(0, 9)]]:
		var p: Vector2 = spot[1]
		print("  %s (%.1f, %.1f): y %.2f  pit d %.2f  n.y %.2f" % [spot[0], p.x, p.y, _gy(p.x, p.y), _pit_d(p.x, p.y), _n_at(p.x, p.y).y])

	_plan_trees()
	var ok := _flood_checks()

	var root := Node3D.new()
	root.name = "QuarryTerrain"
	_build_ground(root)
	_build_ground_body(root)
	_build_water(root)
	_build_log_bridge(root)
	_build_cave_mouth(root)
	var clutter := Node3D.new()
	clutter.name = "Clutter"
	root.add_child(clutter)
	_obstacles = StaticBody3D.new()
	_obstacles.name = "Obstacles"
	root.add_child(_obstacles)
	_dress()
	_dress_trees()
	_vines(root)
	_build_campfire(root)
	_flush_batches(clutter)
	_build_props()
	_build_grass(root)
	_own(root, root)
	var packed := PackedScene.new()
	packed.pack(root)
	var err := ResourceSaver.save(packed, OUT + "terrain.scn", ResourceSaver.FLAG_COMPRESS)
	print("terrain.scn: err %d, %d KB, %d obstacles" % [err, FileAccess.get_file_as_bytes(OUT + "terrain.scn").size() / 1024, _obstacle_count])
	root.free()

	_save_environment()
	_patch_scene()
	print("bake %s in %d ms" % ["OK" if ok else "WITH FLOOD FAILURES", Time.get_ticks_msec() - t0])
	quit(0 if ok else 1)


# ---------------------------------------------------------------- shape

func _smooth(a: float, b: float, v: float) -> float:
	return smoothstep(a, b, v) if a < b else 1.0 - smoothstep(b, a, v)


func _rect_sdf(x: float, z: float, cx: float, cz: float, hx: float, hz: float) -> float:
	var dx := absf(x - cx) - hx
	var dz := absf(z - cz) - hz
	return Vector2(maxf(dx, 0.0), maxf(dz, 0.0)).length() + minf(maxf(dx, dz), 0.0)


func _ellipse_sdf(p: Vector2, r: Vector2) -> float:
	var k1 := (p / (r * r)).length()
	if k1 < 1e-6:
		return -minf(r.x, r.y)
	var k0 := (p / r).length()
	return k0 * (k0 - 1.0) / k1


func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> Vector2:
	# Distance to segment ab, and how far along it the nearest point is.
	var ab := b - a
	var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return Vector2(p.distance_to(a + ab * t), t)


func _line_dist(p: Vector2, pts: Array) -> float:
	var best := INF
	for i in pts.size() - 1:
		best = minf(best, _seg_dist(p, pts[i], pts[i + 1]).x)
	return best


func _ladder_win(x: float, z: float) -> float:
	return _smooth(5.0, 2.0, absf(z + 50.0)) * _smooth(-4.0, -8.0, x)


func _pit_d(x: float, z: float) -> float:
	# Signed distance from the pit's edge, negative inside. A lobed ellipse
	# that wanders, with a straight cliff cut where the ladder stands.
	var p := Vector2(x, z + 47.0)
	var d := _ellipse_sdf(p, Vector2(15.0, 14.0))
	var th := atan2(p.y, p.x)
	d -= sin(3.0 * th + 0.7) * 1.2 + sin(5.0 * th + 2.1) * 0.6
	d += _warp.get_noise_2d(x, z) * 0.9 + _small.get_noise_2d(x * 1.3, z * 1.3) * 0.15
	return lerpf(d, -14.0 - x, _ladder_win(x, z))


func _road(x: float, z: float) -> float:
	return _smooth(3.0, 1.6, _line_dist(Vector2(x, z), ROAD))


func _floor_path(x: float, z: float) -> float:
	return _smooth(1.8, 0.8, _line_dist(Vector2(x, z), FLOOR_PATH))


func _ramp_hw(x: float, z: float) -> float:
	return 2.2 + _warp.get_noise_2d(x * 2.0, z * 2.0) * 0.5 + _small.get_noise_2d(x, z) * 0.2


func _ramp_dist(x: float, z: float) -> Vector2:
	return _seg_dist(Vector2(x, z), RAMP_A, RAMP_B)


func _on_ramp(x: float, z: float) -> float:
	var hw := _ramp_hw(x, z)
	return _smooth(hw + 0.5, hw - 0.5, _ramp_dist(x, z).x)


func _smin(a: float, b: float, k: float) -> float:
	var h := clampf(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
	return lerpf(b, a, h) - k * h * (1.0 - h)


func _valley_d(x: float, z: float) -> float:
	# The valley the map sits in, negative inside: three overlapping basins
	# (town, field, quarry) blended together and warped, so no side is straight.
	var p := Vector2(x, z)
	var d := _ellipse_sdf(p - Vector2(0.0, 26.0), Vector2(31.0, 25.0))
	d = _smin(d, _ellipse_sdf(p - Vector2(4.0, -10.0), Vector2(29.0, 28.0)), 10.0)
	d = _smin(d, _ellipse_sdf(p - Vector2(1.0, -50.0), Vector2(30.0, 20.0)), 10.0)
	return d + _warp.get_noise_2d(x * 0.35, z * 0.35) * 5.0 + _warp.get_noise_2d(x * 0.9 + 30.0, z * 0.9) * 1.5


func _berm(x: float, z: float) -> float:
	# Hills close the map: a rise you can climb a little way, then a steep bank
	# past the edge of the walkable ground. How high, how far out and how steep
	# all wander along the edge, so it reads as hills, not a wall.
	var o := _valley_d(x, z)
	var lift := 0.5 + 0.5 * _big.get_noise_2d(x * 0.6 + 90.0, z * 0.6)
	var sharp := 0.5 + 0.5 * _patch.get_noise_2d(x * 0.4 - 70.0, z * 0.4)
	var gentle := smoothstep(0.0, 14.0, o) * lerpf(3.0, 8.0, lift)
	var steep := minf(maxf(0.0, o - lerpf(9.0, 5.0, lift)) * lerpf(1.3, 2.1, sharp), lerpf(4.0, 13.0, lift))
	return gentle + steep


func _h_base(x: float, z: float) -> float:
	var d := _pit_d(x, z)
	var win := _ladder_win(x, z)
	var big := _big.get_noise_2d(x, z)
	var small := _small.get_noise_2d(x, z)
	var floor_y := -6.0 + big * 0.2 + small * 0.04
	var talus := 0.9 * smoothstep(-4.0, -1.4, d) * (1.0 - win)
	var rim := (_big.get_noise_2d(x + 40.0, z) * (0.25 + 0.4 * smoothstep(4.0, 20.0, d)) + small * 0.06) * (1.0 - _road(x, z) * 0.7)
	var town := _smooth(2.0, -2.0, _rect_sdf(x, z, 0.0, 30.0, 22.0, 18.0))
	rim = lerpf(rim, clampf(rim, -0.05, 0.05), town)
	rim += _tier(x, z) + _knolls(x, z) + _berm(x, z)
	var w_in := lerpf(1.3, 2.6, 0.5 + 0.5 * _patch.get_noise_2d(x * 0.5, z * 0.5))
	var s := lerpf(smoothstep(-w_in, 0.4, d), smoothstep(-0.3, 0.3, d), win)
	var h := lerpf(floor_y + talus, rim, s) + _small.get_noise_2d(x * 2.1, z * 2.1) * 0.25 * 4.0 * s * (1.0 - s) * (1.0 - win)
	return minf(h, _gully(x, z))


func _gully_z(x: float) -> float:
	# Where the gully runs at this x, held flat past its ends.
	if x <= STREAM[0].x:
		return STREAM[0].y
	for i in STREAM.size() - 1:
		var a: Vector2 = STREAM[i]
		var b: Vector2 = STREAM[i + 1]
		if x <= b.x:
			return lerpf(a.y, b.y, (x - a.x) / (b.x - a.x))
	return POND.y


func _tier(x: float, z: float) -> float:
	# The ground's steps: the town on a plateau at 0, a bluff down to the field
	# at -2.5, and past the gully the quarry rim, -1.5 on its north side and
	# climbing to the south and west. The bluff eases where the road and a
	# goat path go down it.
	var rim_lv := -1.5 + 3.0 * _smooth(-30.0, -68.0, z) + 0.6 * _smooth(-10.0, -36.0, x)
	var t := smoothstep(_gully_z(x) - 3.0, _gully_z(x) + 3.0, z)
	var y := lerpf(rim_lv, -2.5, t)
	var bz := 10.0 + _warp.get_noise_2d(x * 0.4, 61.0) * 2.5
	var gentle := maxf(_smooth(5.0, 2.5, _line_dist(Vector2(x, z), ROAD)), _smooth(5.0, 2.5, absf(x + 22.0)))
	var bw := lerpf(0.6, 4.5, gentle)
	return lerpf(y, 0.0, smoothstep(bz - bw, bz + bw, z))


func _knolls(x: float, z: float) -> float:
	# Rock knolls on the rim, 2.5 m up, steep but for one side to walk up.
	var best := 0.0
	for k: Array in KNOLLS:
		var p := Vector2(x, z) - (k[0] as Vector2)
		var l := p.length()
		var facing := maxf(0.0, (p / maxf(l, 0.001)).dot(k[1]))
		var r_in := 1.8 + _warp.get_noise_2d(x * 1.5, z * 1.5) * 0.3
		var r_out := lerpf(2.7, 7.0, facing * facing)
		best = maxf(best, 2.5 * _smooth(r_out, r_in, l))
	return best


func _gully(x: float, z: float) -> float:
	# The gully the stream runs down: a floor about 3 m under the ground, walls
	# too steep to climb, and a gentle cut where the road fords it. It opens
	# round the pond at its east end and rises to a spring at its head.
	var p := Vector2(x, z)
	var s := _line_param(p, STREAM)
	var gd := minf(s.x - GULLY_HW, _ellipse_sdf(p - POND, POND_R) - 1.6)
	gd += _warp.get_noise_2d(x * 1.2 + 5.0, z * 1.2) * 0.5
	var floor_y := lerpf(-5.2, -5.5, clampf(s.y / _stream_len, 0.0, 1.0)) + 2.4 * _smooth(8.0, 0.0, s.y)
	var ford := _smooth(4.5, 2.2, _line_dist(p, ROAD)) * _smooth(20.0, 15.0, p.distance_to(FORD))
	var k := lerpf(lerpf(2.0, 2.8, 0.5 + 0.5 * _patch.get_noise_2d(x * 0.7, z * 0.7)), 0.36, ford)
	return floor_y + maxf(0.0, gd) * k + _small.get_noise_2d(x * 2.0, z * 2.0) * 0.08


func _h(x: float, z: float) -> float:
	# The dry ground with the stream and pond beds cut into it.
	var h := _h_dry(x, z)
	var s := _line_param(Vector2(x, z), STREAM)
	var sd := s.x - _stream_hw(s.y)
	# Only on the gully floor: past it the bank slope would carve the walls.
	if sd < 1.5:
		h = minf(h, _bed(_stream_level(s.y), sd, 0.3 * smoothstep(0.0, 3.0, s.y), 0.9, x, z))
	var pd := _pond_d(x, z)
	if pd < 1.5:
		h = minf(h, _bed(_pond_lv, pd, 0.55, 3.0, x, z))
	return h


func _bed(level: float, d: float, depth: float, inner: float, x: float, z: float) -> float:
	# A bed `depth` below the water at its middle, meeting the water `d` = 0.25
	# out from the edge, then a bank climbing out at a walkable slope.
	var bed := level - depth * smoothstep(0.25, -inner, d) + maxf(0.0, d - 0.25) * 0.55
	return bed + _small.get_noise_2d(x * 3.0, z * 3.0) * 0.04


func _line_param(p: Vector2, pts: Array) -> Vector2:
	# Distance to a polyline, and the arc length to its nearest point.
	var best := INF
	var at := 0.0
	var run := 0.0
	for i in pts.size() - 1:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var sd := _seg_dist(p, a, b)
		if sd.x < best:
			best = sd.x
			at = run + sd.y * a.distance_to(b)
		run += a.distance_to(b)
	return Vector2(best, at)


func _along(pts: Array, s: float) -> Vector2:
	for i in pts.size() - 1:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var l := a.distance_to(b)
		if s <= l or i == pts.size() - 2:
			return a.lerp(b, clampf(s / l, 0.0, 1.0))
		s -= l
	return pts[-1]


func _stream_hw(s: float) -> float:
	return lerpf(0.55, 1.2, smoothstep(0.0, _stream_len, s)) + _warp.get_noise_2d(s * 3.0, 7.0) * 0.25


func _stream_level(s: float) -> float:
	var f := clampf(s / 0.5, 0.0, _stream_lv.size() - 1.001)
	var i := int(f)
	return lerpf(_stream_lv[i], _stream_lv[i + 1], f - i)


func _pond_d(x: float, z: float) -> float:
	return _ellipse_sdf(Vector2(x, z) - POND, POND_R) + _warp.get_noise_2d(x * 0.8 + 17.0, z * 0.8) * 1.2


func _plan_water() -> void:
	# Water levels from the dry ground: the stream never runs higher than its
	# lowest bank so far, and the pond sits under the lowest point of its shore.
	_stream_len = 0.0
	for i in STREAM.size() - 1:
		_stream_len += (STREAM[i] as Vector2).distance_to(STREAM[i + 1])
	var n := int(ceil(_stream_len / 0.5)) + 1
	_stream_lv.resize(n)
	var lv := INF
	for i in n:
		var s := minf(i * 0.5, _stream_len)
		var p := _along(STREAM, s)
		var dir := (_along(STREAM, minf(s + 0.5, _stream_len)) - _along(STREAM, maxf(s - 0.5, 0.0))).normalized()
		var side := dir.orthogonal() * (_stream_hw(s) + 0.6)
		for q: Vector2 in [p, p + side, p - side]:
			lv = minf(lv, _h_dry(q.x, q.y) - 0.12)
		_stream_lv[i] = lv
	var shore := INF
	for k in 96:
		var a := TAU * k / 96.0
		for r: float in [0.0, 0.6]:
			var p: Vector2 = POND + Vector2(cos(a), sin(a)) * (POND_R + Vector2.ONE * (2.0 + r))
			# Walk in until the shore line itself.
			var q := p
			for step in 30:
				if _pond_d(q.x, q.y) < 0.4:
					break
				q = q.lerp(POND, 0.04)
			shore = minf(shore, _h_dry(q.x, q.y))
	_pond_lv = minf(shore - 0.1, lv)
	for i in n:
		_stream_lv[i] = lerpf(_stream_lv[i], _pond_lv, smoothstep(_stream_len - 5.0, _stream_len, i * 0.5))
	print("water: stream %.1f m, %.2f to %.2f; pond at %.2f" % [_stream_len, _stream_lv[0], _stream_lv[n - 1], _pond_lv])


func _water_at(x: float, z: float) -> Vector2:
	# The water surface here, and how far inside the water's edge (negative
	# inside); y is INF where there is no water nearby.
	var s := _line_param(Vector2(x, z), STREAM)
	var sd := s.x - _stream_hw(s.y)
	var pd := _pond_d(x, z)
	if minf(sd, pd) > 3.0:
		return Vector2(0.0, INF)
	if pd < sd:
		return Vector2(_pond_lv, pd)
	return Vector2(_stream_level(s.y), sd)


func _h_dry(x: float, z: float) -> float:
	var h := _h_base(x, z)
	# The ramp: a cut through the rim and an embankment down into the pit,
	# with banks whose steepness and edge wander.
	var rd := _ramp_dist(x, z)
	var hw := _ramp_hw(x, z)
	var ry := lerpf(_hA, _hB, rd.y) + _small.get_noise_2d(x, z) * 0.06
	var e := maxf(0.0, rd.x - hw)
	var k := lerpf(1.3, 2.2, 0.5 + 0.5 * _patch.get_noise_2d(x * 1.5, z * 1.5))
	var hc := clampf(h, ry - e * k, ry + e * k)
	h = hc + _small.get_noise_2d(x * 2.5, z * 2.5) * 0.2 * smoothstep(0.0, 0.5, absf(hc - h)) * smoothstep(0.0, 0.6, e)
	# The shaman's ledge against the south wall.
	var ld := _ellipse_sdf(Vector2(x, z + 58.5), Vector2(5.5, 3.0)) + _warp.get_noise_2d(x + 9.0, z) * 0.4
	h = maxf(h, lerpf(-6.5, -3.0 + _small.get_noise_2d(x, z) * 0.05, _smooth(0.5, -0.5, ld)))
	# A shelf halfway down the north wall: drop to it from the rim, then to the floor.
	var sd := _ellipse_sdf(Vector2(x, z) - SHELF, Vector2(4.0, 2.2)) + _warp.get_noise_2d(x - 13.0, z) * 0.4
	h = maxf(h, lerpf(-6.5, -3.5 + _small.get_noise_2d(x, z) * 0.05, _smooth(0.4, -0.4, sd)))
	# The landmark: a rock spire at the quarry's south-west corner, seen from town.
	var q := Vector2(x, z) - SPIRE
	var th := atan2(q.y, q.x)
	var lump := sin(3.0 * th + 1.0) * 0.6 + sin(7.0 * th + 0.3) * 0.25 + _warp.get_noise_2d(x * 1.4, z * 1.4) * 0.4
	var r0 := 4.6 + lump
	var r1 := 1.7 + lump * 0.5
	var up := clampf((r0 - q.length()) / (r0 - r1), 0.0, 1.0)
	h = lerpf(h, maxf(h, 14.0 + _small.get_noise_2d(x * 2.0, z * 2.0) * 0.4), up)
	# The cave mouth: flat just under the tunnel floor across the outcrop's
	# footprint, easing back to the ground in front and at the sides.
	var side := smoothstep(4.0, 2.4, absf(x - CAVE_MOUTH.x))
	var front := smoothstep(CAVE_MOUTH.y + 10.0, CAVE_MOUTH.y + 7.0, z)
	front *= smoothstep(CAVE_MOUTH.y - 9.0, CAVE_MOUTH.y - 7.0, z)
	h = lerpf(h, CAVE_FLOOR - 0.12, side * front)
	return h


# ---------------------------------------------------------------- grid

func _bake_heights() -> void:
	_nx = int(round((X1 - X0) / CELL)) + 1
	_nz = int(round((Z1 - Z0) / CELL)) + 1
	_hgrid.resize(_nx * _nz)
	for iz in _nz:
		for ix in _nx:
			_hgrid[ix + iz * _nx] = _h(X0 + ix * CELL, Z0 + iz * CELL)


func _dump_heights(path: String) -> void:
	# Little-endian: nx, nz (int32), x0, z0, cell (float32), then nx * nz
	# heights, then nx * nz * 4 paint weights (rock, soil, grass, dirt).
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_32(_nx)
	f.store_32(_nz)
	f.store_float(X0)
	f.store_float(Z0)
	f.store_float(CELL)
	f.store_buffer(_hgrid.to_byte_array())
	var paint := PackedFloat32Array()
	paint.resize(_nx * _nz * 4)
	for iz in _nz:
		for ix in _nx:
			var c := _splat(X0 + ix * CELL, Z0 + iz * CELL, _grid_normal(ix, iz))
			var i := (ix + iz * _nx) * 4
			paint[i] = c.r
			paint[i + 1] = c.g
			paint[i + 2] = c.b
			paint[i + 3] = c.a
	f.store_buffer(paint.to_byte_array())
	f.close()
	print("heights dumped to %s" % path)


func _hv(ix: int, iz: int) -> float:
	return _hgrid[clampi(ix, 0, _nx - 1) + clampi(iz, 0, _nz - 1) * _nx]


func _gy(x: float, z: float) -> float:
	# Exactly on the drawn (and collided) triangles.
	var fx := (x - X0) / CELL
	var fz := (z - Z0) / CELL
	var ix := clampi(int(floor(fx)), 0, _nx - 2)
	var iz := clampi(int(floor(fz)), 0, _nz - 2)
	fx -= ix
	fz -= iz
	var ha := _hv(ix, iz)
	var hb := _hv(ix + 1, iz)
	var hc := _hv(ix, iz + 1)
	var hd := _hv(ix + 1, iz + 1)
	if fx + fz <= 1.0:
		return ha + (hb - ha) * fx + (hc - ha) * fz
	return hd + (hc - hd) * (1.0 - fx) + (hb - hd) * (1.0 - fz)


func _grid_normal(ix: int, iz: int) -> Vector3:
	return Vector3(_hv(ix - 1, iz) - _hv(ix + 1, iz), 2.0 * CELL, _hv(ix, iz - 1) - _hv(ix, iz + 1)).normalized()


func _n_at(x: float, z: float) -> Vector3:
	var e := CELL
	return Vector3(_gy(x - e, z) - _gy(x + e, z), 2.0 * e, _gy(x, z - e) - _gy(x, z + e)).normalized()


# ---------------------------------------------------------------- paint

func _grassiness(x: float, z: float) -> float:
	var d := _pit_d(x, z)
	var n := _patch.get_noise_2d(x, z)
	var rim := smoothstep(0.1, 1.5, d) * smoothstep(-0.75, -0.1, n)
	var edge := smoothstep(-7.5, -3.0, d) * smoothstep(-1.0, -2.2, d) * smoothstep(0.05, 0.4, n)
	var path := maxf(maxf(_road(x, z), _floor_path(x, z)), _cave_path(x, z))
	return clampf(maxf(rim, edge) - path * 1.5 - _on_ramp(x, z) * 2.0, 0.0, 1.0) * (1.0 - 0.8 * _canopy_at(x, z))


func _cave_path(x: float, z: float) -> float:
	# The way into the cave mouth and the ground under the outcrop: bare
	# soil, no grass.
	var w := 2.6 + smoothstep(CAVE_MOUTH.y + 6.0, CAVE_MOUTH.y + 11.0, z) * 0.8 + _warp.get_noise_2d(x * 2.0, z * 2.0) * 0.6
	return smoothstep(w + 0.8, w - 0.4, absf(x - CAVE_MOUTH.x)) * smoothstep(CAVE_MOUTH.y + 12.5, CAVE_MOUTH.y + 9.0, z)


func _splat(x: float, z: float, n: Vector3) -> Color:
	var d := _pit_d(x, z)
	var ramp := _on_ramp(x, z)
	var rock := smoothstep(0.16, 0.36, 1.0 - n.y) * (1.0 - ramp)
	var grass := _grassiness(x, z)
	var floor_zone := smoothstep(-1.2, -3.0, d) * (1.0 - grass)
	var mottle := smoothstep(-0.45, 0.45, _patch.get_noise_2d(x * 0.9 + 50.0, z * 0.9))
	var bedrock := smoothstep(0.26, 0.46, _patch.get_noise_2d(x * 0.8 - 30.0, z * 0.8)) * floor_zone
	rock = maxf(rock, bedrock * 0.8 * (1.0 - ramp))
	var path := maxf(_road(x, z), _floor_path(x, z))
	var dirt := maxf(maxf(ramp * lerpf(0.5, 1.0, mottle), path), floor_zone * lerpf(0.25, 1.0, mottle))
	var soil := clampf(1.0 - dirt - grass, 0.0, 1.0)
	return Color(rock, soil * (1.0 - rock), grass * (1.0 - rock), dirt * (1.0 - rock))


func _wet(x: float, z: float, y: float) -> Vector2:
	# x: riverbed stones, under the water and just above it. y: damp bank.
	var w := _water_at(x, z)
	if w.y == INF:
		return Vector2.ZERO
	return Vector2(smoothstep(w.x + 0.12, w.x - 0.04, y), smoothstep(w.x + 0.5, w.x + 0.04, y))


func _ground_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(OUT + "quarry_ground.gdshader")
	for layer: Array in [["rock", "rock_face_03"], ["soil", "forest_ground_04"], ["grass", "grass_path_2"], ["dirt", "dirt_floor"]]:
		mat.set_shader_parameter(layer[0] + "_albedo", load(T + layer[1] + "_diff_2k.jpg"))
		mat.set_shader_parameter(layer[0] + "_normal", load(T + layer[1] + "_nor_gl_2k.jpg"))
		# ARM with height in B, from tools/quarry/height_from_normal.py.
		mat.set_shader_parameter(layer[0] + "_arm", load(T + layer[1] + "_armh_2k.png"))
	mat.set_shader_parameter("bed_albedo", load(F + "textures/river_small_rocks_diff_2k.jpg"))
	mat.set_shader_parameter("bed_normal", load(F + "textures/river_small_rocks_nor_gl_2k.jpg"))
	mat.set_shader_parameter("bed_arm", load(F + "textures/river_small_rocks_armh_2k.png"))
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_octaves = 3
	noise.seed = 71
	var variation := NoiseTexture2D.new()
	variation.width = 256
	variation.height = 256
	variation.seamless = true
	variation.generate_mipmaps = true
	variation.normalize = true
	variation.noise = noise
	mat.set_shader_parameter("variation", variation)
	_set_relief(mat)
	return mat


# The valley-wide maps from tools/quarry/terrain_relief.py, which the ground
# and the grass on it both read: finer ground than the mesh has, in the light
# and the paint only.
func _set_relief(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("terrain_relief", load(OUT + "terrain_relief.png"))
	mat.set_shader_parameter("terrain_masks", load(OUT + "terrain_masks.png"))
	mat.set_shader_parameter("relief_rect", Vector4(X0, Z0, 1.0 / (X1 - X0), 1.0 / (Z1 - Z0)))
	mat.set_shader_parameter("relief_amount", 1.0)
	mat.set_shader_parameter("occlusion_amount", 1.0)
	mat.set_shader_parameter("shape_paint", 1.0)


func _grid_mesh(ix0: int, iz0: int, ix1: int, iz1: int, paint: bool) -> Array:
	# Vertices and triangles for grid points ix0..ix1, iz0..iz1, in world space.
	var w := ix1 - ix0 + 1
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	for iz in range(iz0, iz1 + 1):
		for ix in range(ix0, ix1 + 1):
			var x := X0 + ix * CELL
			var z := Z0 + iz * CELL
			verts.append(Vector3(x, _hv(ix, iz), z))
			if paint:
				var n := _grid_normal(ix, iz)
				norms.append(n)
				colors.append(_splat(x, z, n))
				uvs.append(_wet(x, z, _hv(ix, iz)))
	var tris := PackedInt32Array()
	for iz in iz1 - iz0:
		for ix in w - 1:
			var a := ix + iz * w
			var b := a + 1
			var c := a + w
			var d := c + 1
			tris.append_array([a, b, c, b, d, c])
	return [verts, norms, colors, tris, uvs]


func _build_ground(root: Node3D) -> void:
	var ground := Node3D.new()
	ground.name = "Ground"
	root.add_child(ground)
	var mat := _ground_material()
	var step := int(round(TILE / CELL))
	var tiles := 0
	var iz := 0
	while iz < _nz - 1:
		var ix := 0
		while ix < _nx - 1:
			var g := _grid_mesh(ix, iz, mini(ix + step, _nx - 1), mini(iz + step, _nz - 1), true)
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = g[0]
			arrays[Mesh.ARRAY_NORMAL] = g[1]
			arrays[Mesh.ARRAY_COLOR] = g[2]
			arrays[Mesh.ARRAY_TEX_UV] = g[4]
			arrays[Mesh.ARRAY_INDEX] = g[3]
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			var mi := MeshInstance3D.new()
			mi.name = "Tile_%d_%d" % [ix / step, iz / step]
			mi.mesh = mesh
			mi.material_override = mat
			ground.add_child(mi)
			tiles += 1
			ix += step
		iz += step
	print("ground: %d tiles" % tiles)


func _build_ground_body(root: Node3D) -> void:
	var ix0 := int(round((CX0 - X0) / CELL))
	var ix1 := int(round((CX1 - X0) / CELL))
	var iz0 := int(round((CZ0 - Z0) / CELL))
	var iz1 := int(round((CZ1 - Z0) / CELL))
	var g := _grid_mesh(ix0, iz0, ix1, iz1, false)
	var verts: PackedVector3Array = g[0]
	var tris: PackedInt32Array = g[3]
	var faces := PackedVector3Array()
	faces.resize(tris.size())
	for i in tris.size():
		faces[i] = verts[tris[i]]
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var body := StaticBody3D.new()
	body.name = "GroundBody"
	var col := CollisionShape3D.new()
	col.name = "Collision"
	col.shape = shape
	body.add_child(col)
	root.add_child(body)
	print("collision: %d triangles" % (faces.size() / 3))


## Metres a second that a flow speed of 1 (COLOR.b) stands for; the water
## shader's flow_max.
const FLOW_MAX := 1.2
## The stream's typical (median) speed, metres a second.
const FLOW_TYPICAL := 0.35
## Metres of stream the spring seeps in along, so the flow gathers rather
## than bursting from one shallow spot.
const SPRING := 5.0


func _flow_colors(w: int, h: int, wet: PackedByteArray, depth: PackedFloat32Array, role: PackedInt32Array) -> PackedColorArray:
	# The water's flow, per vertex of the water sheet: COLOR.rg the direction
	# (0.5 = still), COLOR.b the speed over FLOW_MAX.
	#
	# Solved, not drawn: water seeps in along the first SPRING metres of the
	# stream, sinks evenly over the pond, and moves down a potential phi with
	# flux h^(5/3) * -grad(phi) (Manning's
	# law with the surface slope folded into phi), so what goes in comes out.
	# The speed h^(2/3) * |grad(phi)| is then faster where the stream narrows or
	# shallows, slower at its banks, and dies away across the pond; and the
	# direction follows every bend of the banks rather than the centre line.
	var n := w * h
	var k := PackedInt32Array()
	k.resize(n)
	k.fill(-1)
	var cells := PackedInt32Array()
	for i in n:
		if wet[i] == 1:
			k[i] = cells.size()
			cells.append(i)
	var m := cells.size()
	# Only water joined to the spring flows; a puddle cut off by a dry cell
	# stays still.
	var reached := PackedByteArray()
	reached.resize(m)
	var todo: Array[int] = []
	for j in m:
		if role[cells[j]] == 1:
			reached[j] = 1
			todo.append(j)
	while not todo.is_empty():
		var i := cells[todo.pop_back()]
		for o: int in [i - 1, i + 1, i - w, i + w]:
			if o >= 0 and o < n and (o % w - i % w) * (o % w - i % w) <= 1 and k[o] >= 0 and reached[k[o]] == 0:
				reached[k[o]] = 1
				todo.append(k[o])
	var src := 0
	var sink := 0
	for j in m:
		if reached[j] == 1:
			src += 1 if role[cells[j]] == 1 else 0
			sink += 1 if role[cells[j]] == -1 else 0
	var b := PackedFloat64Array()
	b.resize(m)
	for j in m:
		if reached[j] == 0:
			continue
		if role[cells[j]] == 1:
			b[j] = 1.0 / src
		elif role[cells[j]] == -1 and sink > 0:
			b[j] = -1.0 / sink
	# Conductance across each cell's east and south faces.
	var ce := PackedFloat64Array()
	var cs := PackedFloat64Array()
	ce.resize(m)
	cs.resize(m)
	var diag := PackedFloat64Array()
	diag.resize(m)
	for j in m:
		var i := cells[j]
		if i % w < w - 1 and k[i + 1] >= 0:
			ce[j] = pow(0.5 * (depth[i] + depth[i + 1]), 5.0 / 3.0)
			diag[j] += ce[j]
			diag[k[i + 1]] += ce[j]
		if i + w < n and k[i + w] >= 0:
			cs[j] = pow(0.5 * (depth[i] + depth[i + w]), 5.0 / 3.0)
			diag[j] += cs[j]
			diag[k[i + w]] += cs[j]
	var phi := _solve_flow(cells, k, w, ce, cs, diag, b)
	# Speeds from the potential's slope, central differences where both
	# neighbours are wet.
	var vel := PackedVector2Array()
	vel.resize(n)
	var speeds := PackedFloat32Array()
	for j in m:
		var i := cells[j]
		if reached[j] == 0:
			continue
		var g := Vector2.ZERO
		for axis in 2:
			var step := 1 if axis == 0 else w
			var lo := i - step
			var hi := i + step
			var lo_ok := lo >= 0 and k[lo] >= 0 and (axis == 1 or i % w > 0)
			var hi_ok := hi < n and k[hi] >= 0 and (axis == 1 or i % w < w - 1)
			var d := 0.0
			if lo_ok and hi_ok:
				d = (phi[k[hi]] - phi[k[lo]]) / 2.0
			elif hi_ok:
				d = phi[k[hi]] - phi[j]
			elif lo_ok:
				d = phi[j] - phi[k[lo]]
			g[axis] = d
		vel[i] = -g * pow(depth[i], 2.0 / 3.0)
		if role[i] != -1:
			speeds.append(vel[i].length())
	speeds.sort()
	var scale := FLOW_TYPICAL / maxf(speeds[speeds.size() / 2], 1e-12) if not speeds.is_empty() else 0.0
	var colors := PackedColorArray()
	colors.resize(n)
	var fast := 0.0
	for i in n:
		var v := vel[i] * scale
		if wet[i] == 0:
			# Under the bank: the mean of the wet water beside it, so the
			# ripples at the shore move with the water next to them.
			var sum := Vector2.ZERO
			var c := 0
			for o: int in [i - 1, i + 1, i - w, i + w]:
				if o >= 0 and o < n and absi(o % w - i % w) <= 1 and wet[o] == 1:
					sum += vel[o] * scale
					c += 1
			v = sum / c if c > 0 else Vector2.ZERO
		var sp := minf(v.length(), FLOW_MAX)
		fast = maxf(fast, sp)
		var dir := v.normalized() if sp > 1e-4 else Vector2.ZERO
		colors[i] = Color(dir.x * 0.5 + 0.5, dir.y * 0.5 + 0.5, sp / FLOW_MAX)
	print("flow: %d wet cells (%d joined), spring %d, pond %d; median %.2f m/s, fastest %.2f" % [
		m, reached.count(1), src, sink, FLOW_TYPICAL, fast])
	return colors


func _solve_flow(cells: PackedInt32Array, k: PackedInt32Array, w: int, ce: PackedFloat64Array,
		cs: PackedFloat64Array, diag: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	# Conjugate gradients, Jacobi-preconditioned, on the weighted Laplacian
	# (A phi)_j = sum over neighbours of c (phi_j - phi_o). A tiny pull to 0
	# makes it definite; the sources balance, so it only fixes phi's level.
	var m := cells.size()
	var eps := 1e-9
	var east := PackedInt32Array()
	var south := PackedInt32Array()
	east.resize(m)
	south.resize(m)
	for j in m:
		var i := cells[j]
		east[j] = k[i + 1] if ce[j] > 0.0 else -1
		south[j] = k[i + w] if cs[j] > 0.0 else -1
	var apply := func(x: PackedFloat64Array) -> PackedFloat64Array:
		var y := PackedFloat64Array()
		y.resize(m)
		for j in m:
			y[j] += (diag[j] + eps) * x[j]
			var e := east[j]
			if e >= 0:
				y[j] -= ce[j] * x[e]
				y[e] -= ce[j] * x[j]
			var s := south[j]
			if s >= 0:
				y[j] -= cs[j] * x[s]
				y[s] -= cs[j] * x[j]
		return y
	var x := PackedFloat64Array()
	x.resize(m)
	var r := b.duplicate()
	var z := PackedFloat64Array()
	z.resize(m)
	for j in m:
		z[j] = r[j] / (diag[j] + eps)
	var p := z.duplicate()
	var rz := 0.0
	var bb := 0.0
	for j in m:
		rz += r[j] * z[j]
		bb += b[j] * b[j]
	var it := 0
	var rr := bb
	while it < 4000 and rr > bb * 1e-14:
		var ap: PackedFloat64Array = apply.call(p)
		var pap := 0.0
		for j in m:
			pap += p[j] * ap[j]
		var alpha := rz / pap
		rr = 0.0
		for j in m:
			x[j] += alpha * p[j]
			r[j] -= alpha * ap[j]
			z[j] = r[j] / (diag[j] + eps)
			rr += r[j] * r[j]
		var rz2 := 0.0
		for j in m:
			rz2 += r[j] * z[j]
		var beta := rz2 / rz
		rz = rz2
		for j in m:
			p[j] = z[j] + beta * p[j]
		it += 1
	print("flow solve: %d cells, %d iterations, residual %s" % [m, it, str(sqrt(rr / maxf(bb, 1e-30)))])
	return x


func _build_water(root: Node3D) -> void:
	# One sheet over every grid cell the water reaches, its edge running on
	# under the banks so the ground cuts the shore line.
	var lo := POND - POND_R - Vector2.ONE * 3.0
	var hi := POND + POND_R + Vector2.ONE * 3.0
	for q: Vector2 in STREAM:
		lo = lo.min(q - Vector2.ONE * 3.0)
		hi = hi.max(q + Vector2.ONE * 3.0)
	var ix0 := int(floor((lo.x - X0) / CELL))
	var iz0 := int(floor((lo.y - Z0) / CELL))
	var ix1 := int(ceil((hi.x - X0) / CELL))
	var iz1 := int(ceil((hi.y - Z0) / CELL))
	var w := ix1 - ix0 + 1
	var level := PackedFloat32Array()
	var wet := PackedByteArray()
	var verts := PackedVector3Array()
	var depth := PackedFloat32Array()
	# 1 where the spring feeds the stream, -1 in the pond it drains into.
	var role := PackedInt32Array()
	for iz in range(iz0, iz1 + 1):
		for ix in range(ix0, ix1 + 1):
			var x := X0 + ix * CELL
			var z := Z0 + iz * CELL
			var wa := _water_at(x, z)
			var y := wa.x if wa.y < 2.5 else -100.0
			level.append(y)
			wet.append(1 if y > _hv(ix, iz) + 0.005 else 0)
			verts.append(Vector3(x, y, z))
			depth.append(maxf(0.0, y - _hv(ix, iz)))
			var s := _line_param(Vector2(x, z), STREAM)
			var pond := _pond_d(x, z) < s.x - _stream_hw(s.y)
			role.append(-1 if pond else (1 if s.y < SPRING else 0))
	var colors := _flow_colors(w, iz1 - iz0 + 1, wet, depth, role)
	var idx := PackedInt32Array()
	var cells := 0
	for iz in iz1 - iz0:
		for ix in w - 1:
			var a := ix + iz * w
			var corners := [a, a + 1, a + w, a + w + 1]
			var any_wet := false
			var all_defined := true
			for c: int in corners:
				any_wet = any_wet or wet[c] == 1
				all_defined = all_defined and level[c] > -99.0
			if not (any_wet and all_defined):
				continue
			idx.append_array([a, a + 1, a + w, a + 1, a + w + 1, a + w])
			cells += 1
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var norms := PackedVector3Array()
	norms.resize(verts.size())
	norms.fill(Vector3.UP)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := ShaderMaterial.new()
	mat.shader = load(OUT + "quarry_water.gdshader")
	var mi := MeshInstance3D.new()
	mi.name = "Water"
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)
	print("water: %d cells" % cells)

	# The same water as a fixed surface, one entry per SurfaceGrid cell it
	# covers, so units wade it and spells leave it be.
	var layer: Node3D = load("res://systems/surface_system/fixed_surface_layer.gd").new()
	layer.name = "WaterSurface"
	layer.set("surface", load("res://data/surfaces/level_water.tres"))
	var sc := 0.25  # SurfaceGrid.CELL; the bake can't load the surface system's autoload chain
	var laid := PackedVector3Array()
	for kz in range(floori(lo.y / sc), ceili(hi.y / sc) + 1):
		for kx in range(floori(lo.x / sc), ceili(hi.x / sc) + 1):
			var cx := (kx + 0.5) * sc
			var cz := (kz + 0.5) * sc
			var wa := _water_at(cx, cz)
			var gy := _gy(cx, cz)
			if wa.y < 2.5 and wa.x > gy + 0.03:
				laid.append(Vector3(kx, gy, kz))
	layer.set("cells", laid)
	root.add_child(layer)
	print("water surface: %d cells" % laid.size())


func _build_log_bridge(root: Node3D) -> void:
	# Two felled trunks across the gully, field to rim, with one box the
	# nav grid walks over. The ends sink into the ground.
	var a := Vector3(LOG_A.x, _gy(LOG_A.x, LOG_A.y) - 0.12, LOG_A.y)
	var b := Vector3(LOG_B.x, _gy(LOG_B.x, LOG_B.y) - 0.12, LOG_B.y)
	var along := (b - a).normalized()
	var side := Vector3.UP.cross(along).normalized()
	var basis := Basis(side, along.cross(side), along)
	var length := a.distance_to(b) + 1.6
	var body := StaticBody3D.new()
	body.name = "LogBridge"
	body.transform = Transform3D(basis, (a + b) * 0.5)
	var col := CollisionShape3D.new()
	col.name = "Collision"
	var box := BoxShape3D.new()
	box.size = Vector3(1.3, 0.62, length)
	col.shape = box
	body.add_child(col)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load(F + "models/fir_tree_01_fir_tree_01_bark_diff_2k.jpg")
	mat.normal_enabled = true
	mat.normal_texture = load(F + "models/fir_tree_01_fir_tree_01_bark_nor_gl_2k.jpg")
	mat.uv1_scale = Vector3(2.0, length / 2.0, 1.0)
	for i in 2:
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.3 - i * 0.03
		cyl.bottom_radius = 0.34 - i * 0.03
		cyl.height = length + 0.4 - i * 0.9
		cyl.radial_segments = 14
		cyl.rings = 1
		cyl.material = mat
		var mi := MeshInstance3D.new()
		mi.name = "Trunk%d" % i
		mi.mesh = cyl
		# A cylinder stands on its own y: lay it along the box's length.
		mi.transform = Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3((i - 0.5) * 0.66, -0.02 + i * 0.03, i * 0.3))
		body.add_child(mi)
	root.add_child(body)
	print("log bridge: %.1f m, %.2f to %.2f" % [length, a.y, b.y])


# ---------------------------------------------------------------- checks

func _build_cave_mouth(root: Node3D) -> void:
	# The outcrop over the spider cave's entrance, meshed by the cave tool,
	# drawn with the cave's rock shader and walked under by its own trimesh;
	# a black card deep in the tunnel stands for the dark beyond.
	var dir := OS.get_user_data_dir().path_join("cave_mouth_bake")
	var out: Array = []
	var code := OS.execute("python", ["-I", ProjectSettings.globalize_path("res://tools/cave/cave_volume.py"), dir,
			"--mouth", "--cell", "0.25"], out, true)
	if code != 0:
		push_error("cave_volume.py --mouth failed: %d
%s" % [code, "".join(out)])
		return
	var verts := FileAccess.get_file_as_bytes(dir.path_join("verts.bin")).to_float32_array()
	var normals := FileAccess.get_file_as_bytes(dir.path_join("normals.bin")).to_float32_array()
	var ao := FileAccess.get_file_as_bytes(dir.path_join("ao.bin")).to_float32_array()
	var masks := FileAccess.get_file_as_bytes(dir.path_join("masks.bin")).to_float32_array()
	var index := FileAccess.get_file_as_bytes(dir.path_join("index.bin")).to_int32_array()
	var n := ao.size()
	var v := PackedVector3Array()
	var nrm := PackedVector3Array()
	var col := PackedColorArray()
	v.resize(n)
	nrm.resize(n)
	col.resize(n)
	for i in n:
		v[i] = Vector3(verts[i * 3], verts[i * 3 + 1], verts[i * 3 + 2])
		nrm[i] = Vector3(normals[i * 3], normals[i * 3 + 1], normals[i * 3 + 2])
		col[i] = Color(ao[i], masks[i * 3], masks[i * 3 + 1], masks[i * 3 + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_NORMAL] = nrm
	arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_INDEX] = index
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://world/spider_cave/cave_rock.gdshader")
	# All rock, ledges too: the cave's dirt floor layer browns every ledge.
	for layer: Array in [["rock", T + "rock_face_03"], ["floor", T + "rock_face_03"], ["stones", F + "textures/river_small_rocks"]]:
		mat.set_shader_parameter(layer[0] + "_albedo", load(layer[1] + "_diff_2k.jpg"))
		mat.set_shader_parameter(layer[0] + "_normal", load(layer[1] + "_nor_gl_2k.jpg"))
		mat.set_shader_parameter(layer[0] + "_arm", load(layer[1] + "_arm_2k.jpg"))
	# Lit like the quarry's own rock faces, not the cave's damp walls.
	mat.set_shader_parameter("rock_tint", Color(0.84, 0.86, 0.88))
	mat.set_shader_parameter("floor_tint", Color(0.78, 0.8, 0.82))
	mat.set_shader_parameter("floor_tile", 0.22)
	mat.set_shader_parameter("rock_tile", 0.22)
	mat.set_shader_parameter("wet_roughness", 1.0)
	mat.set_shader_parameter("ao_strength", 0.7)
	# Out in the sun: rain leaves stains down the faces, not a wet shine.
	mat.set_shader_parameter("streak_gloss", 0.1)
	mesh.surface_set_material(0, mat)

	var mouth := Node3D.new()
	mouth.name = "CaveMouth"
	root.add_child(mouth)
	var mi := MeshInstance3D.new()
	mi.name = "Rock"
	mi.mesh = mesh
	mouth.add_child(mi)
	var faces := PackedVector3Array()
	faces.resize(index.size())
	for i in index.size():
		faces[i] = v[index[i]]
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var body := StaticBody3D.new()
	body.name = "RockBody"
	var cs := CollisionShape3D.new()
	cs.name = "Collision"
	cs.shape = shape
	body.add_child(cs)
	mouth.add_child(body)

	var dark := StandardMaterial3D.new()
	dark.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dark.albedo_color = Color.BLACK
	var card := QuadMesh.new()
	card.size = Vector2(5.0, 4.2)
	card.material = dark
	var void_mi := MeshInstance3D.new()
	void_mi.name = "Dark"
	void_mi.mesh = card
	void_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	void_mi.position = Vector3(CAVE_MOUTH.x, CAVE_FLOOR + 2.0, CAVE_MOUTH.y - 3.0)
	mouth.add_child(void_mi)
	print("cave mouth: %d verts, %d triangles" % [n, index.size() / 3])


func _flood(blocked: Callable) -> PackedByteArray:
	# Which grid points a walker can reach from the camp: gentle enough to
	# stand on, and no big step between neighbours.
	var ix0 := int(round((CX0 - X0) / CELL))
	var ix1 := int(round((CX1 - X0) / CELL))
	var iz0 := int(round((CZ0 - Z0) / CELL))
	var iz1 := int(round((CZ1 - Z0) / CELL))
	var seen := PackedByteArray()
	seen.resize(_nx * _nz)
	var start := Vector2i(int(round((CAMP.x - X0) / CELL)), int(round((CAMP.y + 1.0 - Z0) / CELL)))
	var queue: Array[Vector2i] = [start]
	seen[start.x + start.y * _nx] = 1
	var head := 0
	while head < queue.size():
		var c := queue[head]
		head += 1
		var hc := _hv(c.x, c.y)
		for off: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var q := c + off
			if q.x < ix0 or q.x > ix1 or q.y < iz0 or q.y > iz1:
				continue
			var i := q.x + q.y * _nx
			if seen[i] != 0:
				continue
			if absf(_hv(q.x, q.y) - hc) > 0.42 or _grid_normal(q.x, q.y).y < 0.70:
				continue
			if blocked.call(X0 + q.x * CELL, Z0 + q.y * CELL):
				continue
			seen[i] = 1
			queue.append(q)
	return seen


func _reached(seen: PackedByteArray, x: float, z: float) -> bool:
	var ix := int(round((x - X0) / CELL))
	var iz := int(round((z - Z0) / CELL))
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if seen[ix + dx + (iz + dz) * _nx] != 0:
				return true
	return false


func _flood_checks() -> bool:
	var ok := true
	var open := _flood(func(_x: float, _z: float) -> bool: return false)
	if _reached(open, 0.0, -58.5):
		print("FLOOD FAIL: the ledge is reachable on foot")
		ok = false
	if not _reached(open, 4.0, 30.0):
		print("FLOOD FAIL: the town is not reachable from the camp")
		ok = false
	var edge := 0
	for iz in _nz:
		for ix in _nx:
			if open[ix + iz * _nx] == 0:
				continue
			var x := X0 + ix * CELL
			var z := Z0 + iz * CELL
			if x < CX0 + 1.5 or x > CX1 - 1.5 or z < CZ0 + 1.5 or z > CZ1 - 1.5:
				edge += 1
	if edge > 0:
		print("FLOOD FAIL: %d walkable points within 1.5 m of the collision edge" % edge)
		ok = false
	var sealed := _flood(func(x: float, z: float) -> bool: return _ramp_dist(x, z).x < _ramp_hw(x, z) + 2.5)
	var leaks := 0
	var first := Vector2.ZERO
	for i in sealed.size():
		if sealed[i] != 0 and _pit_d(X0 + (i % _nx) * CELL, Z0 + (i / _nx) * CELL) > 1.0:
			if leaks == 0:
				first = Vector2(X0 + (i % _nx) * CELL, Z0 + (i / _nx) * CELL)
			leaks += 1
	if leaks > 0:
		print("FLOOD FAIL: %d rim points reachable without the ramp, first at %s" % [leaks, first])
		ok = false
	var count := 0
	for v in open:
		count += v
	print("flood: %d walkable points reached from the camp%s" % [count, "" if not ok else ", all checks pass"])
	return ok


# ---------------------------------------------------------------- dressing

func _dry_stone(mesh: Mesh, file: String) -> void:
	# Two faults in the scans as they come. rock_07 carries leftover vertex
	# colours, a dark grey that the import multiplies into the stone. And the
	# small stones' gloss maps are flat at 0.3 and 0.5, a wet pebble's: in the
	# quarry they mirror the sky and turn purple and silver.
	for s in mesh.get_surface_count():
		var mat := mesh.surface_get_material(s) as BaseMaterial3D
		if mat == null:
			continue
		# And a scan alone looks dropped in: quarry_rock.gdshader shades each
		# copy apart, settles the local ground on its top and fades its foot
		# into the ground it sits on.
		var rock := ShaderMaterial.new()
		rock.shader = load(OUT + "quarry_rock.gdshader")
		rock.set_shader_parameter("albedo_tex", mat.albedo_texture)
		rock.set_shader_parameter("normal_tex", mat.normal_texture)
		rock.set_shader_parameter("arm_tex", mat.roughness_texture)
		rock.set_shader_parameter("flat_roughness", 0.92 if file in POLISHED_ROCKS or mat.roughness_texture == null else -1.0)
		rock.set_shader_parameter("arm_occlusion", mat.roughness_texture != null and mat.roughness_texture.resource_path.contains("_arm_"))
		rock.set_shader_parameter("rock_height", mesh.get_aabb().size.y)
		_set_rock_ground(rock)
		mesh.surface_set_material(s, rock)


var _rock_ground: Array[Texture2D] = []


# The ground as the rocks read it: heights and paint weights, one texel per
# mesh cell, saved beside the meshes so every rock shares the one copy.
func _set_rock_ground(mat: ShaderMaterial) -> void:
	if _rock_ground.is_empty():
		var heights := Image.create_from_data(_nx, _nz, false, Image.FORMAT_RF, _hgrid.to_byte_array())
		var paint := Image.create(_nx, _nz, false, Image.FORMAT_RGBA8)
		for iz in _nz:
			for ix in _nx:
				paint.set_pixel(ix, iz, _splat(X0 + ix * CELL, Z0 + iz * CELL, _grid_normal(ix, iz)))
		for pair: Array in [["ground_height", heights], ["ground_paint", paint]]:
			var tex := ImageTexture.create_from_image(pair[1])
			var path: String = OUT + "meshes/%s.res" % pair[0]
			ResourceSaver.save(tex, path, ResourceSaver.FLAG_CHANGE_PATH | ResourceSaver.FLAG_COMPRESS)
			tex.take_over_path(path)
			_rock_ground.append(tex)
	mat.set_shader_parameter("ground_height", _rock_ground[0])
	mat.set_shader_parameter("ground_paint", _rock_ground[1])
	# Texel centres sit on the grid points.
	var w := _nx * CELL
	var d := _nz * CELL
	mat.set_shader_parameter("ground_rect", Vector4(X0 - CELL * 0.5, Z0 - CELL * 0.5, 1.0 / w, 1.0 / d))
	for layer: Array in [["soil", "forest_ground_04"], ["grass", "grass_path_2"], ["dirt", "dirt_floor"]]:
		mat.set_shader_parameter(layer[0] + "_albedo", load(T + layer[1] + "_diff_2k.jpg"))


func _meshes_of(file: String, dir := M) -> Array[Mesh]:
	if _saved.has(file):
		return _saved[file]
	var out: Array[Mesh] = []
	var scene: Node = (load(dir + file + ".glb") as PackedScene).instantiate()
	var i := 0
	for mi: Node in scene.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		if file in SCANNED_ROCKS:
			# Their cracks and missing backs show the sky through the rock.
			var shut: Dictionary = MeshCloser.close(mesh)
			print("  closed %s[%d]: %s" % [file, i, shut.report])
			if shut.left > 0:
				print("  WARNING %s[%d] still has %d open edges" % [file, i, shut.left])
			mesh = shut.mesh
			_open_cache[mesh] = shut.open_dir
			_dry_stone(mesh, file)
		var path := OUT + "meshes/%s_%d.res" % [file, i]
		ResourceSaver.save(mesh, path, ResourceSaver.FLAG_CHANGE_PATH | ResourceSaver.FLAG_COMPRESS)
		mesh.take_over_path(path)
		for dep: String in ResourceLoader.get_dependencies(path):
			# A rock's own shader and the ground it reads are expected.
			var known := file in SCANNED_ROCKS and (dep.contains(OUT.trim_prefix("res://")) or dep.contains(T.trim_prefix("res://")))
			if not known and not dep.contains(dir.trim_prefix("res://")):
				print("  WARNING %s depends on %s" % [path, dep])
		out.append(mesh)
		i += 1
	scene.free()
	_saved[file] = out
	return out


func _clear(x: float, z: float, r: float, water := true) -> bool:
	var p := Vector2(x, z)
	for k: Array in KEEP_OUT:
		if p.distance_to(k[0]) < k[1] + r:
			return false
	if x > -18.0 - r and x < -14.8 + r and z > -51.5 - r and z < -48.5 + r:
		return false
	if _ramp_dist(x, z).x < _ramp_hw(x, z) + 0.3 + r:
		return false
	if water and _water_at(x, z).y < r + 0.4:
		return false
	return _road(x, z) <= 0.2 and _floor_path(x, z) <= 0.3


func _in_collision(x: float, z: float) -> bool:
	return x > CX0 and x < CX1 and z > CZ0 and z < CZ1


func _open_dir(mesh: Mesh) -> Vector3:
	# Which way the open side of a scanned shell faces: the middle of its bare
	# edges, seen from the middle of the mesh. Seams are welded first.
	if _open_cache.has(mesh):
		return _open_cache[mesh]
	var arrays := mesh.surface_get_arrays(0)
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var ind: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var ids := PackedInt32Array()
	ids.resize(pos.size())
	var weld := {}
	var welded: Array[Vector3] = []
	var centre := Vector3.ZERO
	for i in pos.size():
		var key := Vector3i(pos[i] * 2000.0)
		if not weld.has(key):
			weld[key] = welded.size()
			welded.append(pos[i])
			centre += pos[i]
		ids[i] = weld[key]
	centre /= maxf(welded.size(), 1.0)
	var edges := {}
	for t in range(0, ind.size(), 3):
		for e in 3:
			var a := ids[ind[t + e]]
			var b := ids[ind[t + (e + 1) % 3]]
			var key := mini(a, b) * 100000 + maxi(a, b)
			edges[key] = edges.get(key, 0) + 1
	var sum := Vector3.ZERO
	var count := 0
	for key: int in edges:
		if edges[key] == 1:
			sum += welded[key / 100000] + welded[key % 100000]
			count += 2
	var dir := Vector3.DOWN if count == 0 else (sum / count - centre).normalized()
	_open_cache[mesh] = dir
	return dir


func _is_upright(mesh: Mesh, away: Vector3) -> bool:
	var size := (Transform3D(Basis(Quaternion(_open_dir(mesh), away.normalized())), Vector3.ZERO) * mesh.get_aabb()).size
	return size.y > 1.1 * minf(size.x, size.z)


func _xf_place(mesh: Mesh, at: Vector3, yaw: float, size: float, tilt := 0.0) -> Transform3D:
	var b := Basis(Vector3.UP, yaw).rotated(Vector3.RIGHT.rotated(Vector3.UP, yaw), tilt).scaled(Vector3.ONE * size)
	return Transform3D(b, at - b * mesh.get_aabb().get_center())


func _xf_shut(mesh: Mesh, at: Vector3, away: Vector3, roll: float, size: float, sink: float) -> Transform3D:
	var turn := Basis(Quaternion(_open_dir(mesh), away.normalized()))
	var b := (Basis(away.normalized(), roll) * turn).scaled(Vector3.ONE * size)
	var aabb := mesh.get_aabb()
	var height := (Transform3D(b, Vector3.ZERO) * aabb).size.y
	return Transform3D(b, at + Vector3.UP * height * (0.5 - sink) - b * aabb.get_center())


func _add(mesh: Mesh, xf: Transform3D, shadow := true, solid := false, fade := -1.0, begin := 0.0, shadow_only := false) -> void:
	# `fade`: how far away it stops drawing; by default only shadowless small
	# things fade, at 60 m. `begin`: how far away it starts, for far LODs.
	# `shadow_only`: drawn into shadow maps but never seen.
	var cell := Vector2i(floori(xf.origin.x / 24.0), floori(xf.origin.z / 24.0))
	var key := [mesh, cell, shadow, fade if fade >= 0.0 else (0.0 if shadow else 60.0), begin, shadow_only]
	if not _batches.has(key):
		_batches[key] = []
	_batches[key].append(xf)
	if solid:
		_add_obstacle(mesh, xf)


func _add_obstacle(mesh: Mesh, xf: Transform3D) -> void:
	if not _in_collision(xf.origin.x, xf.origin.z):
		return
	if not _convex_cache.has(mesh):
		_convex_cache[mesh] = mesh.create_convex_shape(true, true).points
	var local: PackedVector3Array = _convex_cache[mesh]
	var pts := PackedVector3Array()
	pts.resize(local.size())
	var centre := xf * mesh.get_aabb().get_center()
	for i in local.size():
		pts[i] = xf * local[i] - centre
	var shape := ConvexPolygonShape3D.new()
	shape.points = pts
	var col := CollisionShape3D.new()
	col.name = "Rock%d" % _obstacle_count
	col.shape = shape
	col.position = centre
	_obstacles.add_child(col)
	_obstacle_count += 1


func _height_of(mesh: Mesh, xf: Transform3D) -> float:
	return (Transform3D(xf.basis, Vector3.ZERO) * mesh.get_aabb()).size.y


# Plants that never hide a unit go on XRaySilhouettes.SEE_THROUGH_LAYER.
const SEE_THROUGH := 1 << (19 - 1)
const SEE_THROUGH_PLANTS := ["gen_fern", "gen_bush", "nettle", "celandine", "grass_medium"]


func _flush_batches(clutter: Node3D) -> void:
	var instances := 0
	for key: Array in _batches:
		var list: Array = _batches[key]
		var mesh: Mesh = key[0]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = list.size()
		for i in list.size():
			mm.set_instance_transform(i, list[i])
		var inst := MultiMeshInstance3D.new()
		inst.name = "%s_%d_%d%s" % [mesh.resource_path.get_file().get_basename(), key[1].x, key[1].y, "_so" if key[5] else ("" if key[2] else "_ns")]
		inst.multimesh = mm
		if key[5]:
			inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		elif not key[2]:
			inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if key[3] > 0.0:
			inst.visibility_range_end = key[3]
			inst.visibility_range_end_margin = 4.0
		if key[4] > 0.0:
			inst.visibility_range_begin = key[4]
			inst.visibility_range_begin_margin = 4.0
		# Near/far pairs cross-fade instead of popping; shadow proxies needn't.
		if not key[5] and (key[4] > 0.0 or key[3] > 0.0):
			inst.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		var base := mesh.resource_path.get_file()
		for prefix in SEE_THROUGH_PLANTS:
			if base.begins_with(prefix):
				inst.layers = SEE_THROUGH
		clutter.add_child(inst)
		instances += list.size()
	print("clutter: %d pieces in %d batches" % [instances, _batches.size()])


func _ground_at(x: float, z: float) -> Vector3:
	return Vector3(x, _gy(x, z), z)


func _at_wall_foot(x: float, z: float) -> bool:
	# Ground a stone can rest on, with a wall rising within a stride or two.
	# The wall's own face is no place for one: it would hang there.
	if _n_at(x, z).y < 0.85:
		return false
	for k in 8:
		var o := Vector2.from_angle(k * TAU / 8.0) * 1.6
		if _n_at(x + o.x, z + o.y).y < 0.55 and _gy(x + o.x, z + o.y) > _gy(x, z) + 0.4:
			return true
	return false


func _place_group(pool: Array[Mesh], c: Vector2, big: Vector2, small: Vector2, want: int) -> void:
	var placed := 0
	var attempts := 0
	while placed < want and attempts < 14:
		attempts += 1
		var m: Mesh = pool[_rng.randi() % pool.size()]
		var away := Vector3.DOWN + Vector3(_rng.randf_range(-0.15, 0.15), 0.0, _rng.randf_range(-0.15, 0.15))
		if _is_upright(m, away):
			continue
		var off := Vector2.ZERO if placed == 0 else Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(0.6, 1.5)
		var p := c + off
		# The group's middle was checked; a member a stride off may be on a wall.
		if _n_at(p.x, p.y).y < 0.8:
			continue
		var size := _rng.randf_range(big.x, big.y) if placed == 0 else _rng.randf_range(small.x, small.y)
		var xf := _xf_shut(m, _ground_at(p.x, p.y), away, _rng.randf() * TAU, size, 0.3)
		_add(m, xf, true, _height_of(m, xf) > 0.7)
		placed += 1


func _dress() -> void:
	var moss: Array[Mesh] = _meshes_of("rock_moss_set_01")
	moss.append_array(_meshes_of("rock_moss_set_02"))
	var blocks: Array[Mesh] = _meshes_of("rock_face_01")
	blocks.append_array(_meshes_of("rock_face_02"))
	var stones: Array[Mesh] = _meshes_of("rock_07")
	stones.append_array(_meshes_of("rock_09"))
	var stump: Mesh = _meshes_of("tree_stump_01")[0]
	var trunk: Mesh = _meshes_of("dead_tree_trunk_02")[0]
	var branches: Array[Mesh] = _meshes_of("dry_branches_medium_01")

	# Boulder groups: mossy on the grass and the hills, broken blocks in the pit.
	var groups: Array[Vector2] = []
	var tries := 0
	while groups.size() < 42 and tries < 3000:
		tries += 1
		var c := Vector2(_rng.randf_range(X0 + 6.0, X1 - 6.0), _rng.randf_range(Z0 + 6.0, Z1 - 6.0))
		var d := _pit_d(c.x, c.y)
		var in_pit := d < -0.5
		# In the pit: against the foot of a wall, or now and then out on the
		# floor. Never by distance from the rim, which lands on the wall itself.
		if in_pit and not (_at_wall_foot(c.x, c.y) or (_rng.randf() < 0.2 and _n_at(c.x, c.y).y > 0.85)):
			continue
		if not _clear(c.x, c.y, 2.0) or _n_at(c.x, c.y).y < 0.6:
			continue
		var crowded := false
		for other: Vector2 in groups:
			if other.distance_to(c) < 7.0:
				crowded = true
		if crowded:
			continue
		groups.append(c)
		if in_pit:
			_place_group(blocks, c, Vector2(0.3, 0.45), Vector2(0.12, 0.22), _rng.randi_range(2, 4))
		else:
			_place_group(moss, c, Vector2(0.32, 0.55), Vector2(0.14, 0.26), _rng.randi_range(2, 5))

	# Fallen stones heaped along the foot of every wall.
	var placed := 0
	tries = 0
	while placed < 160 and tries < 6000:
		tries += 1
		var x := _rng.randf_range(-20.0, 22.0)
		var z := _rng.randf_range(-66.0, -28.0)
		var d := _pit_d(x, z)
		if d < -7.0 or d > -1.0 or not _clear(x, z, 0.4) or not _at_wall_foot(x, z):
			continue
		var m: Mesh = stones[_rng.randi() % stones.size()]
		if _is_upright(m, Vector3.DOWN):
			continue
		var xf := _xf_shut(m, _ground_at(x, z), Vector3.DOWN, _rng.randf() * TAU, _rng.randf_range(1.0, 3.2), 0.3)
		_add(m, xf, true, _height_of(m, xf) > 0.7)
		placed += 1

	# Loose stones across the worked floor.
	placed = 0
	tries = 0
	while placed < 60 and tries < 3000:
		tries += 1
		var x := _rng.randf_range(-14.0, 14.0)
		var z := _rng.randf_range(-60.0, -34.0)
		if _pit_d(x, z) > -3.0 or not _clear(x, z, 0.4) or _n_at(x, z).y < 0.7:
			continue
		var m: Mesh = stones[_rng.randi() % stones.size()]
		if _is_upright(m, Vector3.DOWN):
			continue
		_add(m, _xf_shut(m, _ground_at(x, z), Vector3.DOWN, _rng.randf() * TAU, _rng.randf_range(0.9, 2.4), 0.3))
		placed += 1

	# Rubble spilled down the ramp's banks, broken and half buried.
	placed = 0
	tries = 0
	# Stones only: a cliff-face scan shrunk to rubble is a thin black shard.
	var rubble: Array[Mesh] = stones
	while placed < 70 and tries < 4000:
		tries += 1
		var t := _rng.randf()
		var along := RAMP_A.lerp(RAMP_B, t)
		var side := (RAMP_B - RAMP_A).normalized().orthogonal() * (1.0 if _rng.randf() < 0.5 else -1.0)
		var p := along + side * (_ramp_hw(along.x, along.y) + _rng.randf_range(0.5, 3.0))
		# The banks, not the pit wall the ramp runs beside.
		if not _clear(p.x, p.y, 0.0) or _n_at(p.x, p.y).y < 0.65:
			continue
		var m: Mesh = rubble[_rng.randi() % rubble.size()]
		var away := Vector3.DOWN + Vector3(_rng.randf_range(-0.3, 0.3), 0.0, _rng.randf_range(-0.3, 0.3))
		if _is_upright(m, away):
			continue
		var size := _rng.randf_range(1.0, 3.0)
		_add(m, _xf_shut(m, _ground_at(p.x, p.y), away, _rng.randf() * TAU, size, 0.4))
		placed += 1

	# Pebbles: everywhere but the houses, no shadows.
	placed = 0
	tries = 0
	while placed < 420 and tries < 6000:
		tries += 1
		var x := _rng.randf_range(CX0, CX1)
		var z := _rng.randf_range(CZ0, CZ1)
		var near_pit := _pit_d(x, z) < 6.0
		if not near_pit and _rng.randf() < 0.6:
			continue
		var blocked := false
		for k: Array in KEEP_OUT.slice(0, 8):
			if Vector2(x, z).distance_to(k[0]) < k[1]:
				blocked = true
		if blocked or _n_at(x, z).y < 0.7:
			continue
		var m: Mesh = stones[_rng.randi() % stones.size()]
		_add(m, _xf_shut(m, _ground_at(x, z), Vector3.DOWN, _rng.randf() * TAU, _rng.randf_range(0.3, 0.75), 0.35), false)
		placed += 1

	# Plants tucked against rock and in the grass, on the hills too.
	for i in 2600:
		var x := _rng.randf_range(X0 + 2.0, X1 - 2.0)
		var z := _rng.randf_range(Z0 + 2.0, Z1 - 2.0)
		var d := _pit_d(x, z)
		var near_wall := absf(d + 2.2) < 1.2 or absf(d - 1.2) < 1.0
		if _n_at(x, z).y < 0.75 or not _clear(x, z, 0.3):
			continue
		if not near_wall and _grassiness(x, z) < 0.4:
			continue
		if _rng.randf() < 0.5:
			continue
		var at := _ground_at(x, z)
		if _rng.randf() < 0.45:
			_add_fern(at, _rng.randi(), _rng.randf() * TAU, _rng.randf_range(0.8, 1.3))
		elif _rng.randf() < 0.35 and _clear(x, z, 0.9):
			_add_bush(at, _rng.randf() * TAU, _rng.randf_range(0.55, 1.1), _rng.randi())

	# Dead wood on the rim and the hills.
	placed = 0
	tries = 0
	while placed < 22 and tries < 2000:
		tries += 1
		var x := _rng.randf_range(-40.0, 40.0)
		var z := _rng.randf_range(-80.0, 56.0)
		if _pit_d(x, z) < 2.0 or not _clear(x, z, 2.0) or _n_at(x, z).y < 0.9:
			continue
		var at := _ground_at(x, z)
		var roll := _rng.randf()
		if roll < 0.25:
			at.y += 0.2
			_add(stump, _xf_place(stump, at, _rng.randf() * TAU, _rng.randf_range(0.8, 1.2)), true, true)
		elif roll < 0.55:
			at.y += 0.36
			_add(trunk, _xf_place(trunk, at, _rng.randf() * TAU, _rng.randf_range(0.8, 1.2), _rng.randf_range(-0.04, 0.04)), true, true)
		else:
			var m: Mesh = branches[_rng.randi() % branches.size()]
			at.y += 0.12
			_add(m, _xf_place(m, at, _rng.randf() * TAU, _rng.randf_range(1.0, 1.4)))
		placed += 1


func _build_campfire(root: Node3D) -> void:
	var at := _ground_at(CAMP.x, CAMP.y)
	var stone07: Mesh = _meshes_of("rock_07")[0]
	var stone09: Mesh = _meshes_of("rock_09")[0]
	for i in 10:
		var a := TAU * i / 10.0
		var p := at + Vector3(cos(a), 0.0, sin(a)) * 0.62
		p.y = _gy(p.x, p.z) + 0.06
		var m := stone07 if i % 2 == 0 else stone09
		_add(m, _xf_place(m, p, _rng.randf() * TAU, _rng.randf_range(0.8, 1.15) if i % 2 == 0 else 2.0))
	var logs: Array[Mesh] = _meshes_of("dry_branches_medium_01")
	for i in 3:
		_add(logs[i % logs.size()], _xf_place(logs[i % logs.size()], at + Vector3(0, 0.12, 0), TAU * i / 3.0, 0.75, 0.12))

	var fire := Node3D.new()
	fire.name = "Campfire"
	fire.position = at
	root.add_child(fire)
	var body := StaticBody3D.new()
	body.name = "Body"
	var col := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.7
	cyl.height = 0.4
	col.shape = cyl
	col.position = Vector3(0, 0.2, 0)
	body.add_child(col)
	fire.add_child(body)

	var light := OmniLight3D.new()
	light.name = "Light"
	light.position = Vector3(0, 0.7, 0)
	light.light_color = Color(1.0, 0.55, 0.22)
	light.light_energy = 1.8
	light.omni_range = 9.0
	light.omni_attenuation = 1.6
	light.shadow_enabled = true
	light.set_script(load(OUT + "fire_flicker.gd"))
	fire.add_child(light)

	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.62, 0.2, 0.75))
	grad.set_color(1, Color(1.0, 0.25, 0.04, 0.0))
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 64
	tex.height = 64
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = tex
	mat.albedo_color = Color(0.95, 0.62, 0.36)
	var quad := QuadMesh.new()
	quad.size = Vector2(0.42, 0.6)
	quad.material = mat
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3.UP
	pm.spread = 8.0
	pm.initial_velocity_min = 0.5
	pm.initial_velocity_max = 1.1
	pm.gravity = Vector3(0, 0.5, 0)
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.2
	pm.scale_min = 0.45
	pm.scale_max = 1.0
	var fade := CurveTexture.new()
	var curve := Curve.new()
	curve.add_point(Vector2(0, 0.7))
	curve.add_point(Vector2(0.3, 1.0))
	curve.add_point(Vector2(1, 0.0))
	fade.curve = curve
	pm.scale_curve = fade
	var flame := GPUParticles3D.new()
	flame.name = "Flame"
	flame.amount = 14
	flame.lifetime = 0.9
	flame.preprocess = 2.0
	flame.process_material = pm
	flame.draw_pass_1 = quad
	flame.position = Vector3(0, 0.15, 0)
	flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fire.add_child(flame)


func _card_clump(cards: int, lean_deg: Vector2, width: Vector2, height: Vector2, rows: int, seed: int, core := 0) -> ArrayMesh:
	# Cards fanned out from one root, each leaning outward and bending a
	# little more toward its top, so the clump reads as one plant from any
	# side. `core` more cards stand nearly upright through the middle,
	# turned across each other, so the clump is full rather than a ring of
	# blades around an empty centre. What a card shows is drawn in an atlas; UV is the point in the
	# card (0..1, V down from the top) and the shader picks the cell. UV2.x
	# is 0 at the root and 1 at the top; UV2.y is a random number per card
	# that the shader folds cards away by with distance.
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	for k in cards + core:
		var r := (k + rng.randf() * 0.9) / (cards + core)
		var yaw := TAU * k / cards + rng.randf_range(-0.35, 0.35)
		var out := Vector3(cos(yaw), 0.0, sin(yaw))
		var side := Vector3(-sin(yaw), 0.0, cos(yaw))
		var lean := deg_to_rad(rng.randf_range(lean_deg.x, lean_deg.y))
		var w := rng.randf_range(width.x, width.y)
		var h := rng.randf_range(height.x, height.y)
		var root := out * 0.05
		if k >= cards:
			# A core card: its plane runs through the middle of the clump.
			yaw = PI * (k - cards) / core + rng.randf_range(-0.3, 0.3)
			out = Vector3(cos(yaw), 0.0, sin(yaw))
			side = Vector3(-sin(yaw), 0.0, cos(yaw))
			lean = deg_to_rad(rng.randf_range(2.0, 12.0))
			h *= rng.randf_range(1.0, 1.15)
			root = Vector3(rng.randf_range(-0.04, 0.04), 0.0, rng.randf_range(-0.04, 0.04))
		var start := verts.size()
		for s in rows + 1:
			var t := float(s) / rows
			# The lean grows toward the top, so the card curves outward.
			var a := lean * (0.6 + 0.4 * t)
			var c := root + (Vector3.UP * cos(a) + out * sin(a)) * h * t
			verts.append(c - side * w * 0.5)
			verts.append(c + side * w * 0.5)
			uvs.append(Vector2(0.0, 1.0 - t))
			uvs.append(Vector2(1.0, 1.0 - t))
			uv2s.append(Vector2(t, r))
			uv2s.append(Vector2(t, r))
			# Normals tip outward toward the top, as on a dome over the
			# clump: the sunward side of a clump lights and the far side
			# shades, so it reads as a mound of blades. At the root the
			# normal is straight up, so the base lights like the ground.
			var n := (Vector3.UP + out * 0.9 * t).normalized()
			norms.append(n)
			norms.append(n)
		for q in rows:
			var o := start + q * 2
			idx.append_array([o, o + 1, o + 2, o + 1, o + 3, o + 2])
	return _clump_mesh(verts, norms, uvs, uv2s, idx)


func _flat_clump() -> ArrayMesh:
	# Two cards lying just above the ground, turned against each other, for
	# plants seen from above: clover patches and weed rosettes.
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	for k in 2:
		var yaw := k * 0.9
		var u := Vector3(cos(yaw), 0.0, sin(yaw))
		var v := Vector3(-sin(yaw), 0.0, cos(yaw))
		var off := Vector3(0.12, 0.0, -0.08) * (k * 2 - 1)
		var y := Vector3.UP * (0.03 + 0.02 * k)
		var size := 0.5 - 0.1 * k
		var start := verts.size()
		for c: Vector2 in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
			verts.append(off + y + (u * (c.x - 0.5) + v * (c.y - 0.5)) * size)
			uvs.append(c)
			uv2s.append(Vector2(0.4, 0.15 + 0.5 * k))
			norms.append(Vector3.UP)
		idx.append_array([start, start + 1, start + 2, start + 1, start + 3, start + 2])
	return _clump_mesh(verts, norms, uvs, uv2s, idx)


func _clump_mesh(verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, uv2s: PackedVector2Array, idx: PackedInt32Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _grass_material(atlas_png: String, res_name: String, painted: bool) -> ShaderMaterial:
	if _gen == null:
		_gen = load("res://tools/quarry/plant_gen.gd").new()
	var atlas: Texture2D = _gen.coverage_texture(atlas_png)
	ResourceSaver.save(atlas, OUT + "meshes/" + res_name, ResourceSaver.FLAG_CHANGE_PATH | ResourceSaver.FLAG_COMPRESS)
	atlas.take_over_path(OUT + "meshes/" + res_name)
	var mat := ShaderMaterial.new()
	mat.shader = load(OUT + "quarry_grass.gdshader")
	mat.set_shader_parameter("tufts", atlas)
	mat.set_shader_parameter("painted", painted)
	mat.set_shader_parameter("ground_grass", load(T + "grass_path_2_diff_2k.jpg"))
	mat.set_shader_parameter("ground_soil", load(T + "forest_ground_04_diff_2k.jpg"))
	_set_relief(mat)
	return mat


class Scatter:
	# Instances of one mesh in one chunk: transform, tint, and which atlas
	# cells (INSTANCE_CUSTOM, see quarry_grass.gdshader).
	var xforms: Array[Transform3D] = []
	var tints: Array[Color] = []
	var cells: Array[Color] = []

	func add(xf: Transform3D, tint: Color, cell: Color) -> void:
		xforms.append(xf)
		tints.append(tint)
		cells.append(cell)


func _emit_scatter(parent: Node3D, node_name: String, mesh: Mesh, sc: Scatter, range_end: float) -> int:
	if sc.xforms.is_empty():
		return 0
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = sc.xforms.size()
	for i in sc.xforms.size():
		mm.set_instance_transform(i, sc.xforms[i])
		mm.set_instance_color(i, sc.tints[i])
		mm.set_instance_custom_data(i, sc.cells[i])
	var inst := MultiMeshInstance3D.new()
	inst.name = node_name
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	inst.layers = SEE_THROUGH
	inst.visibility_range_end = range_end
	parent.add_child(inst)
	return sc.xforms.size()


## Grass grid spacing: about 15 clumps per square metre.
const GRASS_STEP := 0.26


func _build_grass(root: Node3D) -> void:
	# Two layers. Grass: a dense carpet of short wide clumps over every grassy
	# spot, with tall tufts standing out of it in patches. Meadow: clover in
	# colonies, flowers in drifts of one colour, dry stalks in dry spots and
	# the odd weed rosette, all from meadow_plants.png.
	var grass := Node3D.new()
	grass.name = "Grass"
	root.add_child(grass)
	var tall := _card_clump(6, Vector2(20, 34), Vector2(0.36, 0.46), Vector2(0.62, 0.82), 3, 5, 3)
	var carpet := _card_clump(6, Vector2(28, 44), Vector2(0.4, 0.5), Vector2(0.34, 0.44), 2, 9, 2)
	var upright := _card_clump(3, Vector2(4, 12), Vector2(0.36, 0.44), Vector2(0.42, 0.52), 1, 13)
	var flat := _flat_clump()
	var grass_mat := _grass_material("res://assets/level/quarry/foliage/grass_tufts.png", "grass_tufts.res", false)
	var meadow_mat := _grass_material("res://assets/level/quarry/foliage/meadow_plants.png", "meadow_plants.res", true)
	tall.surface_set_material(0, grass_mat)
	carpet.surface_set_material(0, grass_mat)
	upright.surface_set_material(0, meadow_mat)
	flat.surface_set_material(0, meadow_mat)
	var counts := {"tall": 0, "carpet": 0, "flat": 0, "upright": 0}

	var chunk := 12.0
	var cx := CX0
	while cx < CX1:
		var cz := CZ0
		while cz < CZ1:
			var t_sc := Scatter.new()
			var c_sc := Scatter.new()
			# One clump per cell of a jittered grid: purely random spots bunch
			# up and leave bare holes at any density.
			var cells_n := int(chunk / GRASS_STEP)
			for i in cells_n * cells_n:
				var x := cx + (i % cells_n + _rng.randf()) * GRASS_STEP
				var z := cz + (i / cells_n + _rng.randf()) * GRASS_STEP
				var g := _grassiness(x, z)
				if g < 0.08 or g < _rng.randf() * 0.5:
					continue
				if _n_at(x, z).y < 0.84 or _water_at(x, z).y < 0.5 or _indoors(x, z):
					continue
				var stand := smoothstep(-0.4, 0.5, _patch.get_noise_2d(x * 3.1 + 17.0, z * 3.1))
				var v := _patch.get_noise_2d(x * 2.0, z * 2.0)
				var tint := Color(1.0 + v * 0.12 + _rng.randf() * 0.08, 1.0 + _rng.randf() * 0.08, 0.95 + v * 0.08)
				var at := Vector3(x, _gy(x, z) - 0.02, z)
				var spin := Basis(Vector3.UP, _rng.randf() * TAU)
				if _rng.randf() < lerpf(0.12, 0.7, stand) * g:
					var size := _rng.randf_range(0.8, 1.2) * lerpf(0.6, 0.95, g) * lerpf(0.8, 1.4, stand)
					t_sc.add(Transform3D(spin.scaled(Vector3.ONE * size), at), tint, Color(0, 2, 4, 0))
				else:
					var size := _rng.randf_range(0.8, 1.2) * lerpf(0.55, 1.0, g)
					c_sc.add(Transform3D(spin.scaled(Vector3.ONE * size), at), tint * 0.94, Color(2, 2, 4, 0))
			var tag := "%d_%d" % [int(cx), int(cz)]
			counts.tall += _emit_scatter(grass, "Tufts_" + tag, tall, t_sc, 48.0)
			counts.carpet += _emit_scatter(grass, "Carpet_" + tag, carpet, c_sc, 44.0)
			cz += chunk
		cx += chunk

	chunk = 16.0
	cx = CX0
	while cx < CX1:
		var cz := CZ0
		while cz < CZ1:
			var f_sc := Scatter.new()
			var u_sc := Scatter.new()
			for i in int(chunk * chunk * 1.4):
				var x := cx + _rng.randf() * chunk
				var z := cz + _rng.randf() * chunk
				var g := _grassiness(x, z)
				if g < 0.25:
					continue
				if _n_at(x, z).y < 0.84 or _water_at(x, z).y < 0.5 or _indoors(x, z):
					continue
				var at := Vector3(x, _gy(x, z) - 0.01, z)
				var spin := Basis(Vector3.UP, _rng.randf() * TAU)
				var shade := _rng.randf_range(0.85, 1.1)
				var tint := Color(shade, shade, shade)
				var clover := _patch.get_noise_2d(x * 0.6 + 90.0, z * 0.6 - 40.0)
				var bloom := _patch.get_noise_2d(x * 0.45 - 120.0, z * 0.45 + 60.0)
				var dry := _patch.get_noise_2d(x * 0.5 + 200.0, z * 0.5 - 11.0)
				if clover > 0.2 and _rng.randf() < 0.85:
					f_sc.add(Transform3D(spin.scaled(Vector3.ONE * _rng.randf_range(0.9, 1.4)), at), tint, Color(0, 1, 4, 0))
				elif bloom > 0.3 and _rng.randf() < 0.6:
					# One colour per drift, from a broad noise.
					var hue := _patch.get_noise_2d(x * 0.12 + 300.0, z * 0.12)
					var col := floorf(clampf(hue + 0.5, 0.0, 0.999) * 4.0)
					u_sc.add(Transform3D(spin.scaled(Vector3.ONE * _rng.randf_range(0.75, 1.15)), at), tint, Color(2, 1, col, 0))
				elif dry > 0.3 and _rng.randf() < 0.5:
					u_sc.add(Transform3D(spin.scaled(Vector3.ONE * _rng.randf_range(0.8, 1.25)), at), tint, Color(3, 1, 4, 0))
				elif _rng.randf() < 0.06:
					f_sc.add(Transform3D(spin.scaled(Vector3.ONE * _rng.randf_range(0.7, 1.1)), at), tint, Color(1, 1, 4, 0))
			var tag := "%d_%d" % [int(cx), int(cz)]
			counts.flat += _emit_scatter(grass, "Low_" + tag, flat, f_sc, 40.0)
			counts.upright += _emit_scatter(grass, "Herbs_" + tag, upright, u_sc, 44.0)
			cz += chunk
		cx += chunk
	print("grass: %s" % counts)


# ---------------------------------------------------------------- vines

const VINE_END := 120.0


func _surface_at(q: Vector3) -> Array:
	# The ground point nearest q, found by stepping along the normal; on a
	# cliff that is the point on the face, not the one straight below.
	# [] off the map or in the water.
	var p := q
	var n := Vector3.UP
	for i in 5:
		if p.x < X0 + 1.0 or p.x > X1 - 1.0 or p.z < Z0 + 1.0 or p.z > Z1 - 1.0:
			return []
		n = _n_at(p.x, p.z)
		p -= n * (p.y - _gy(p.x, p.z)) * n.y
	p.y = _gy(p.x, p.z)
	if _water_at(p.x, p.z).y < 0.3:
		return []
	return [p, _n_at(p.x, p.z)]


func _vines(root: Node3D) -> void:
	# Ivy on the faces: the pit, the gully, the spire and the ledges. Walls
	# are found by their slope, patches by the clutter noise, and each patch
	# grows a few strands up from the wall's foot and, sometimes, a curtain
	# down from its rim. Grown in place, so one mesh per 24 m tile.
	var vrng := RandomNumberGenerator.new()
	vrng.seed = 77
	if _gen == null:
		_gen = load("res://tools/quarry/plant_gen.gd").new()
	var atlas: Texture2D = _gen.coverage_texture("res://assets/level/quarry/foliage/vine_runs.png")
	ResourceSaver.save(atlas, OUT + "meshes/vine_runs.res", ResourceSaver.FLAG_CHANGE_PATH | ResourceSaver.FLAG_COMPRESS)
	atlas.take_over_path(OUT + "meshes/vine_runs.res")
	var mat: Material = _gen.leaf_material(atlas)
	var surface := Callable(self, "_surface_at")
	var tiles := {}
	var spots: Array[Vector2] = []
	var strands := 0
	var cards := 0
	var x := X0 + 2.0
	while x < X1 - 2.0:
		var z := Z0 + 2.0
		while z < Z1 - 2.0:
			var sx := x + vrng.randf_range(-0.5, 0.5)
			var sz := z + vrng.randf_range(-0.5, 0.5)
			z += 1.2
			var n := _n_at(sx, sz)
			if n.y > 0.5 or _patch.get_noise_2d(sx * 1.7, sz * 1.7) < 0.15:
				continue
			var h := Vector3(n.x, 0.0, n.z).normalized()
			var foot := _walk_flat(sx, sz, h)
			var top := _walk_flat(sx, sz, -h)
			if foot.is_empty() or top.is_empty():
				continue
			var tall: float = _gy(top[0].x, top[0].y) - _gy(foot[0].x, foot[0].y)
			if tall < 1.6:
				continue
			var here := Vector2(sx, sz)
			var near := false
			for o in spots:
				if o.distance_to(here) < 3.0:
					near = true
					break
			if near or _ladder_win(sx, sz) > 0.05 or not _clear(foot[0].x, foot[0].y, 0.3) or not _clear(sx, sz, 0.3):
				continue
			spots.append(here)
			var key := Vector2i(floori(sx / TILE), floori(sz / TILE))
			if not tiles.has(key):
				tiles[key] = _gen.Surf.new()
			var surf = tiles[key]
			var along := h.cross(Vector3.UP).normalized()
			for k in vrng.randi_range(3, 6):
				var off := along * vrng.randf_range(-1.8, 1.8)
				var st: Array = _walk_flat(sx + off.x, sz + off.z, h, 0.6)
				if st.is_empty():
					continue
				var start := Vector3(st[0].x, _gy(st[0].x, st[0].y) + 0.05, st[0].y)
				cards += _gen.vine(surf, vrng.randi(), start, Vector3.UP, tall * vrng.randf_range(0.5, 1.05), surface)
				strands += 1
			if vrng.randf() < 0.4:
				for k in vrng.randi_range(2, 4):
					var off := along * vrng.randf_range(-1.5, 1.5)
					var st: Array = _walk_flat(sx + off.x, sz + off.z, -h, 0.6)
					if st.is_empty():
						continue
					var start := Vector3(st[0].x, _gy(st[0].x, st[0].y), st[0].y)
					cards += _gen.vine(surf, vrng.randi(), start, Vector3.DOWN, tall * vrng.randf_range(0.3, 0.7), surface)
					strands += 1
		x += 1.2
	var node := Node3D.new()
	node.name = "Vines"
	root.add_child(node)
	for key: Vector2i in tiles:
		var surf = tiles[key]
		if surf.idx.is_empty():
			continue
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, surf.arrays())
		m.surface_set_material(0, mat)
		var mi := MeshInstance3D.new()
		mi.name = "Vines_%d_%d" % [key.x, key.y]
		mi.mesh = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.layers = SEE_THROUGH
		mi.visibility_range_end = VINE_END
		mi.visibility_range_end_margin = 10.0
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		node.add_child(mi)
	print("vines: %d patches, %d strands, %d cards" % [spots.size(), strands, cards])


func _walk_flat(x: float, z: float, h: Vector3, flat := 0.75) -> Array:
	# Steps from (x, z) along h until the ground levels out (n.y > flat);
	# [Vector2] where it does, [] if it doesn't within 10 m.
	var p := Vector2(x, z)
	var d := Vector2(h.x, h.z) * 0.25
	for i in 40:
		if _n_at(p.x, p.y).y > flat:
			return [p]
		p += d
	return []


func _own(node: Node, root: Node) -> void:
	for child in node.get_children():
		child.owner = root
		_own(child, root)


# ---------------------------------------------------------------- light

func _save_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.32, 0.47, 0.72)
	sky_mat.sky_horizon_color = Color(0.7, 0.76, 0.7)
	sky_mat.ground_horizon_color = Color(0.36, 0.42, 0.3)
	sky_mat.ground_bottom_color = Color(0.14, 0.16, 0.09)
	sky_mat.sun_angle_max = 18.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.75
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.tonemap_white = 6.0
	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 1.8
	env.ssao_light_affect = 0.15
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_bloom = 0.03
	env.glow_hdr_threshold = 1.1
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.006
	env.volumetric_fog_albedo = Color(1.0, 0.96, 0.9)
	env.volumetric_fog_anisotropy = 0.55
	env.volumetric_fog_length = 70.0
	env.volumetric_fog_ambient_inject = 0.35
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.0
	env.adjustment_contrast = 1.04
	print("environment: err %d" % ResourceSaver.save(env, OUT + "quarry_environment.tres"))


# ---------------------------------------------------------------- scene

func _node_path(header: String) -> String:
	var name := _attr(header, "name")
	var parent := _attr(header, "parent")
	if parent == "":
		return "."
	return name if parent == "." else parent + "/" + name


func _attr(header: String, key: String) -> String:
	var re := RegEx.new()
	re.compile(key + "=\"([^\"]*)\"")
	var m := re.search(header)
	return "" if m == null else m.get_string(1)


func _origin(block: String) -> Vector3:
	var re := RegEx.new()
	re.compile("\ntransform = Transform3D\\(([^)]*)\\)")
	var m := re.search(block)
	if m == null:
		return Vector3.ZERO
	var v := m.get_string(1).split(",")
	return Vector3(float(v[9]), float(v[10]), float(v[11]))


func _with_origin(block: String, o: Vector3) -> String:
	var re := RegEx.new()
	re.compile("\ntransform = Transform3D\\(([^)]*)\\)")
	var m := re.search(block)
	var num := func(f: float) -> String: return String.num(snappedf(f, 0.0001))
	if m == null:
		var lines := block.split("\n")
		lines.insert(1, "transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, %s, %s, %s)" % [num.call(o.x), num.call(o.y), num.call(o.z)])
		return "\n".join(lines)
	var v := Array(m.get_string(1).split(","))
	for i in v.size():
		v[i] = v[i].strip_edges()
	v[9] = num.call(o.x)
	v[10] = num.call(o.y)
	v[11] = num.call(o.z)
	return block.substr(0, m.get_start()) + "\ntransform = Transform3D(" + ", ".join(v) + ")" + block.substr(m.get_end())


func _seat(x: float, z: float) -> float:
	var lo := _gy(x, z)
	for off: Vector2 in [Vector2(0.8, 0), Vector2(-0.8, 0), Vector2(0, 0.8), Vector2(0, -0.8)]:
		lo = minf(lo, _gy(x + off.x, z + off.y))
	return lo


# ---------------------------------------------------------------- props

# Blockout placeholder -> generated prop. The StaticBody and its box collision
# stay; only the Mesh child's mesh is swapped, so nav and cover don't change.
var _props := {}


# HouseWest is a walk-in experiment: hollow walls with their own collision, and
# a roof that WalkInBuilding hides while the party is inside.
const WALK_IN := "LevelGeometry/Town/HouseWest"
const WALK_IN_AT := Vector2(-13, 30)
var _walk_in := {}


func _indoors(x: float, z: float) -> bool:
	# Grass would poke up through the walk-in house's floor.
	var p := Vector2(x, z) - WALK_IN_AT
	for room: AABB in _walk_in.get("rooms", []):
		if p.x > room.position.x - 0.2 and p.x < room.end.x + 0.2 and p.y > room.position.z - 0.2 and p.y < room.end.z + 0.2:
			return true
	return false


func _build_props() -> void:
	var g = load("res://tools/quarry/prop_gen.gd").new()
	g.interior = true
	var walk_in: ArrayMesh = g.cottage(Vector3(7, 4, 6), 90, true, 1)
	_walk_in = {roof = g.roof_mesh, colliders = g.colliders.duplicate(), rooms = g.rooms.duplicate()}
	g.interior = false
	var plan := {
		WALK_IN: walk_in,
		"LevelGeometry/Town/HouseWestBack": g.cottage(Vector3(6, 5, 5), 180, false, 2),
		"LevelGeometry/Town/HouseEast": g.cottage(Vector3(6, 4, 7), 270, true, 3),
		"LevelGeometry/Town/HouseEastBack": g.cottage(Vector3(8, 3.5, 5), 180, false, 4),
		"LevelGeometry/Town/Fence": g.fence(Vector3(6, 1, 0.3), 5),
		"LevelGeometry/Town/Well": g.well(1.2, 1.0, 6),
		"LevelGeometry/Road/Cart": g.cart(Vector3(2, 1.2, 3), 7),
		"LevelGeometry/Road/LowWall": g.low_wall(Vector3(5, 1, 0.5), 8),
		"LevelGeometry/Camp/TentWest": g.tent(Vector3(3, 2.2, 3), 90, 9),
		"LevelGeometry/Camp/TentEast": g.tent(Vector3(3, 2.2, 3), 0, 10),
		"LevelGeometry/Camp/Crate": g.crate(Vector3(1, 1, 1), 11),
		"LevelGeometry/Camp/Crate2": g.crate(Vector3(1, 1, 1), 12),
		"LevelGeometry/Camp/Crates3": g.crate(Vector3(1.2, 1.2, 2.2), 13),
	}
	DirAccess.make_dir_recursive_absolute(OUT + "props")
	# Materials first, saved once, so every prop mesh points at the same files.
	for key: String in g._mats:
		ResourceSaver.save(g._mats[key], OUT + "props/mat_%s.tres" % key, ResourceSaver.FLAG_CHANGE_PATH)
	for path: String in plan:
		var file := OUT + "props/%s.res" % path.get_file().to_snake_case()
		ResourceSaver.save(plan[path], file, ResourceSaver.FLAG_CHANGE_PATH | ResourceSaver.FLAG_COMPRESS)
		_props[path + "/Mesh"] = file
	_walk_in.file = OUT + "props/house_west_roof.res"
	ResourceSaver.save(_walk_in.roof, _walk_in.file, ResourceSaver.FLAG_CHANGE_PATH | ResourceSaver.FLAG_COMPRESS)
	print("props: %d meshes, %d materials; walk-in %d boxes, %d rooms" % [plan.size(), g._mats.size(), _walk_in.colliders.size(), _walk_in.rooms.size()])


func _patch_scene() -> void:
	var text := FileAccess.get_file_as_string(OLD_SCENE)
	var blocks: Array[String] = []
	for part in text.split("\n["):
		blocks.append(part if blocks.is_empty() else "[" + part)
	var removed := ["LevelGeometry/Terrain", "LevelGeometry/Ramp", "LevelGeometry/Road/Strip", "LevelGeometry/Road/Boulder",
			"LevelGeometry/Road/Boulder2", "LevelGeometry/Road/RimBoulder", "LevelGeometry/Road/RimBoulder2",
			"LevelGeometry/Camp/Campfire", "LevelGeometry/Camp/Boulder"]
	var kept: Array[String] = []
	var ladder_base_y := _gy(LADDER_BASE.x, LADDER_BASE.y)
	for block in blocks:
		if not block.begins_with("[node"):
			kept.append(block)
			continue
		var header := block.get_slice("\n", 0)
		var path := _node_path(header)
		var drop := false
		for r: String in removed:
			if path == r or path.begins_with(r + "/"):
				drop = true
		if drop:
			continue
		var parent := _attr(header, "parent")
		var o := _origin(block)
		match parent:
			"LevelGeometry/Town", "LevelGeometry/Road":
				block = _with_origin(block, o + Vector3.UP * (_seat(o.x, o.z) - 0.08))
			"LevelGeometry/Camp":
				block = _with_origin(block, o + Vector3.UP * (_seat(o.x, o.z) + 6.0 - 0.08))
		match path:
			"Scared Townperson", "GoblinRogue", "Hobgoblin", "GoblinShaman":
				block = _with_origin(block, Vector3(o.x, _gy(o.x, o.z) + 0.05, o.z))
			"MovableBox", "OverworldExit", "CaveExit":
				block = _with_origin(block, o + Vector3.UP * _gy(o.x, o.z))
			"PartySpawnPoint":
				block = _with_origin(block, Vector3(o.x, _gy(o.x, o.z), o.z))
			"LevelGeometry/Ladder":
				block = _with_origin(block, Vector3(LADDER_BASE.x, ladder_base_y, LADDER_BASE.y))
			"LevelGeometry/Ladder/Top":
				block = _with_origin(block, Vector3(0.0, _gy(LADDER_TOP.x, LADDER_TOP.y) - ladder_base_y, 1.4))
			"WorldEnvironment":
				block = block.replace("ExtResource(\"6_env\")", "ExtResource(\"q_env\")")
			"DirectionalLight3D":
				var b := Basis.from_euler(Vector3(deg_to_rad(-38.0), deg_to_rad(-62.0), 0.0))
				var vals := []
				for row in 3:
					for col in 3:
						vals.append(String.num(snappedf(b[col][row], 0.000001)))
				block = header + "\ntransform = Transform3D(%s, 0, 10, 0)\nlight_color = Color(1, 0.93, 0.8, 1)\nlight_energy = 2.3\nlight_angular_distance = 1.0\nlight_volumetric_fog_energy = 1.4\nshadow_enabled = true\nshadow_opacity = 0.92\ndirectional_shadow_max_distance = 75.0\n" % ", ".join(vals)
		if _props.has(path):
			block = header + "\nmesh = ExtResource(\"p_%s\")\n" % path.get_slice("/", 2).to_snake_case()
		if path == WALK_IN:
			# A node export saved as a NodePath only resolves when the header
			# lists it in node_paths; without that the roof is null.
			block = block.replace(header, header.trim_suffix("]") + " node_paths=PackedStringArray(\"roof\")]")
			block = block.strip_edges() + "\nscript = ExtResource(\"q_walkin\")\nroof = NodePath(\"Roof\")\nrooms = %s\n" % var_to_str(_walk_in.rooms)
		if path == WALK_IN + "/Collision":
			# The one box becomes the walls, floors, steps and chimney.
			block = "[node name=\"Roof\" type=\"MeshInstance3D\" parent=\"%s\"]\nmesh = ExtResource(\"q_walkin_roof\")\n" % WALK_IN
			for i in _walk_in.colliders.size():
				block += "\n[node name=\"Box%d\" type=\"CollisionShape3D\" parent=\"%s\"]\ntransform = %s\nshape = SubResource(\"walkin_%d\")\n" \
						% [i, WALK_IN, var_to_str(_walk_in.colliders[i][0]), i]
		kept.append(block)
		if path == "LevelGeometry":
			kept.append("[node name=\"Terrain\" parent=\"LevelGeometry\" instance=ExtResource(\"q_terrain\")]\n")

	# Ext resources for the terrain and environment, then drop what nothing uses.
	var first_sub := 0
	for i in kept.size():
		if kept[i].begins_with("[ext_resource"):
			first_sub = i + 1
	kept.insert(first_sub, "[ext_resource type=\"PackedScene\" path=\"%sterrain.scn\" id=\"q_terrain\"]\n" % OUT)
	kept.insert(first_sub + 1, "[ext_resource type=\"Environment\" path=\"%squarry_environment.tres\" id=\"q_env\"]\n" % OUT)
	kept.insert(first_sub + 2, "[ext_resource type=\"Script\" path=\"res://world/walk_in_building.gd\" id=\"q_walkin\"]\n")
	kept.insert(first_sub + 3, "[ext_resource type=\"ArrayMesh\" path=\"%s\" id=\"q_walkin_roof\"]\n" % _walk_in.file)
	var at := first_sub + 4
	for p: String in _props:
		kept.insert(at, "[ext_resource type=\"ArrayMesh\" path=\"%s\" id=\"p_%s\"]\n" % [_props[p], p.get_slice("/", 2).to_snake_case()])
		at += 1
	# The walk-in boxes go after the last sub_resource, before the first node.
	for i in kept.size():
		if kept[i].begins_with("[node"):
			for j in range(_walk_in.colliders.size() - 1, -1, -1):
				kept.insert(i, "[sub_resource type=\"BoxShape3D\" id=\"walkin_%d\"]\nsize = %s\n" % [j, var_to_str(_walk_in.colliders[j][1])])
			break
	var changed := true
	while changed:
		changed = false
		var body := ""
		for block in kept:
			var own := block.begins_with("[sub_resource") or block.begins_with("[ext_resource")
			body += (block.substr(block.find("]") + 1) if own else block) + "\n"
		for i in range(kept.size() - 1, -1, -1):
			var block := kept[i]
			var kind := ""
			if block.begins_with("[sub_resource"):
				kind = "SubResource"
			elif block.begins_with("[ext_resource"):
				kind = "ExtResource"
			if kind == "":
				continue
			var id := _attr(block.get_slice("\n", 0), "id")
			if not body.contains(kind + "(\"" + id + "\")"):
				kept.remove_at(i)
				changed = true
	var count := 0
	for block in kept:
		if block.begins_with("[sub_resource") or block.begins_with("[ext_resource"):
			count += 1
	var re := RegEx.new()
	re.compile("load_steps=\\d+")
	kept[0] = re.sub(kept[0], "load_steps=%d" % (count + 1))
	var out := ""
	for i in kept.size():
		var tight := i + 1 < kept.size() and kept[i].begins_with("[ext_resource") and kept[i + 1].begins_with("[ext_resource")
		out += kept[i].rstrip("\n") + ("\n" if tight else "\n\n")
	out = out.rstrip("\n") + "\n"
	var f := FileAccess.open(NEW_SCENE, FileAccess.WRITE)
	f.store_string(out)
	f.close()
	print("scene: %d resources, %d blocks -> %s" % [count, kept.size(), NEW_SCENE])


# ---------------------------------------------------------------- trees

const TREE_SHADE := {"fir": 3.2, "firm": 2.4, "isle": 2.3, "sap": 0.0}
const TREE_TRUNK := {"fir": 0.32, "firm": 0.13, "isle": 0.16, "sap": 0.0}


func _bank_point(pond_share: float, near: Vector2, far: Vector2) -> Vector2:
	# Somewhere near the pond or the stream: `near`..`far` out from the pond's
	# middle, or `near.y`..`far.y` from the stream's line.
	if _trng.randf() < pond_share:
		return POND + Vector2.from_angle(_trng.randf() * TAU) * _trng.randf_range(near.x, far.x)
	return _along(STREAM, _trng.randf() * _stream_len) + Vector2.from_angle(_trng.randf() * TAU) * _trng.randf_range(near.y, far.y)


func _plan_trees() -> void:
	# A dark fir treeline on the hills closes the map; inside the valley,
	# clumps of three to eight with open clearings between them for fights;
	# a few trees lean over the water.
	_trng.seed = 5
	var t0 := Time.get_ticks_msec()
	var tries := 0
	# Out past the steep bank too: the bank itself is a rock face trees can't
	# stand on, so the treeline carries on along the hilltops above it.
	while tries < 20000:
		tries += 1
		var x := _trng.randf_range(X0 + 1.0, X1 - 1.0)
		var z := _trng.randf_range(Z0 + 1.0, Z1 - 1.0)
		var v := _valley_d(x, z)
		if v < 2.0 or v > 20.0 or _pit_d(x, z) < 3.0 or _water_at(x, z).y < 2.0 or not _clear(x, z, 1.0):
			continue
		var deep := smoothstep(2.0, 9.0, v)
		if _trng.randf() > lerpf(0.5, 1.0, deep):
			continue
		# Tall firs behind, the cheaper young ones packed in front of them.
		if _trng.randf() < lerpf(0.25, 0.55, deep):
			_try_tree(Vector2(x, z), "fir", 4.6, _trng.randf_range(0.7, 1.0))
		else:
			_try_tree(Vector2(x, z), "firm", 2.8, _trng.randf_range(0.8, 1.2))

	var clumps: Array[Vector2] = []
	tries = 0
	while clumps.size() < 14 and tries < 4000:
		tries += 1
		var c := Vector2(_trng.randf_range(-34.0, 34.0), _trng.randf_range(-80.0, 62.0))
		if _valley_d(c.x, c.y) > 0.0 or _pit_d(c.x, c.y) < 5.0 or not _clear(c.x, c.y, 3.0):
			continue
		if _rect_sdf(c.x, c.y, 0.0, 30.0, 20.0, 16.0) < 2.0 or _line_dist(c, ROAD) < 6.0 or _n_at(c.x, c.y).y < 0.85:
			continue
		var crowded := false
		for o: Vector2 in clumps:
			crowded = crowded or o.distance_to(c) < 19.0
		if crowded:
			continue
		clumps.append(c)
		var want := _trng.randi_range(3, 8)
		var got := 0
		for k in 30:
			if got >= want:
				break
			var p := c + Vector2.from_angle(_trng.randf() * TAU) * _trng.randf_range(0.0, 2.0 + want * 0.6)
			var roll := _trng.randf()
			var kind := "fir"
			var size := _trng.randf_range(0.5, 0.68)
			if roll < 0.5:
				kind = "isle"
				size = _trng.randf_range(1.0, 1.5)
			elif roll < 0.82:
				kind = "firm"
				size = _trng.randf_range(0.7, 1.0)
			if _try_tree(p, kind, 2.4, size, 1.2):
				got += 1

	# Leaning over the pond and the stream.
	var banked := 0
	tries = 0
	while banked < 9 and tries < 2000:
		tries += 1
		var p := _bank_point(0.5, Vector2(5.0, 1.5), Vector2(11.0, 4.0))
		var w := _water_at(p.x, p.y).y
		if w < 1.0 or w > 3.0:
			continue
		var s := _line_param(p, STREAM)
		var to := _along(STREAM, s.y) - p
		if _pond_d(p.x, p.y) < s.x - _stream_hw(s.y):
			to = POND - p
		if _try_tree(p, "isle", 2.6, _trng.randf_range(1.1, 1.6), 1.0, to.normalized() * _trng.randf_range(0.08, 0.16)):
			banked += 1

	# Saplings at the clumps' and the treeline's edges.
	var saps := 0
	tries = 0
	while saps < 90 and tries < 6000:
		tries += 1
		var x := _trng.randf_range(-44.0, 44.0)
		var z := _trng.randf_range(-92.0, 72.0)
		var v := _valley_d(x, z)
		var near_clump := false
		for c: Vector2 in clumps:
			near_clump = near_clump or c.distance_to(Vector2(x, z)) < 9.0
		if not (near_clump or (v > -2.0 and v < 6.0)):
			continue
		if _pit_d(x, z) < 1.5 or not _clear(x, z, 0.6) or _n_at(x, z).y < 0.8:
			continue
		if _try_tree(Vector2(x, z), "sap", 1.3, _trng.randf_range(0.9, 1.8), 0.0):
			saps += 1

	# How shaded the floor is, so the grass thins under the trees.
	_cnx = int((X1 - X0) / CAN) + 2
	_cnz = int((Z1 - Z0) / CAN) + 2
	_canopy.resize(_cnx * _cnz)
	_canopy.fill(0.0)
	for t: Dictionary in _trees:
		var r: float = TREE_SHADE[t.kind] * t.size
		if r <= 0.0:
			continue
		var at: Vector2 = t.at
		for iz in range(int((at.y - r - Z0) / CAN), int((at.y + r - Z0) / CAN) + 2):
			for ix in range(int((at.x - r - X0) / CAN), int((at.x + r - X0) / CAN) + 2):
				if ix < 0 or iz < 0 or ix >= _cnx or iz >= _cnz:
					continue
				var d := Vector2(X0 + ix * CAN, Z0 + iz * CAN).distance_to(at)
				var i := ix + iz * _cnx
				_canopy[i] = maxf(_canopy[i], smoothstep(r, r * 0.35, d))
	var counts := {}
	for t: Dictionary in _trees:
		counts[t.kind] = counts.get(t.kind, 0) + 1
	print("trees: %s, %d clumps, %d spots on bad footing, in %d ms" % [counts, clumps.size(), _unfooted, Time.get_ticks_msec() - t0])


func _try_tree(p: Vector2, kind: String, gap: float, size: float, trunk := 1.0, lean := Vector2.ZERO) -> bool:
	for t: Dictionary in _trees:
		if (t.at as Vector2).distance_to(p) < gap * minf(size, 1.0) and (t.kind != "sap" or kind == "sap"):
			return false
	if kind != "sap" and (_water_at(p.x, p.y).y < 0.8 or not _clear(p.x, p.y, trunk)):
		return false
	if kind != "sap" and not _footing(p):
		_unfooted += 1
		return false
	if lean == Vector2.ZERO:
		lean = Vector2.from_angle(_trng.randf() * TAU) * _trng.randf_range(0.0, 0.04)
	_trees.append({"at": p, "kind": kind, "pick": _trng.randi() % 3, "size": size, "yaw": _trng.randf() * TAU, "lean": lean})
	return true


func _footing(p: Vector2) -> bool:
	# A tree needs ground it could grow on: no slope steeper than about 45
	# degrees, and no break in the ground within FOOT_R of the trunk. A
	# break is where the ground leaves the plane of the slope at the trunk
	# by more than FOOT_STEP: a cliff lip falling away, a gully wall rising,
	# a ledge. A smooth hillside, however steep, stays near its plane.
	var n := _n_at(p.x, p.y)
	if n.y < 0.7:
		return false
	var y0 := _gy(p.x, p.y)
	var grad := Vector2(-n.x, -n.z) / n.y
	for k in 12:
		var d := Vector2.from_angle(TAU * k / 12.0) * FOOT_R
		var q := p + d
		if absf(_gy(q.x, q.y) - (y0 + grad.dot(d))) > FOOT_STEP:
			return false
	return true


func _canopy_at(x: float, z: float) -> float:
	if _canopy.is_empty():
		return 0.0
	var fx := clampf((x - X0) / CAN, 0.0, _cnx - 1.001)
	var fz := clampf((z - Z0) / CAN, 0.0, _cnz - 1.001)
	var ix := int(fx)
	var iz := int(fz)
	fx -= ix
	fz -= iz
	var a := lerpf(_canopy[ix + iz * _cnx], _canopy[ix + 1 + iz * _cnx], fx)
	var b := lerpf(_canopy[ix + (iz + 1) * _cnx], _canopy[ix + 1 + (iz + 1) * _cnx], fx)
	return lerpf(a, b, fz)


func _xf_tree(at: Vector3, yaw: float, size: float, lean: Vector2) -> Transform3D:
	# For models whose origin is at their foot: stood at `at`, tipped by `lean`.
	var b := Basis(Vector3.UP, yaw)
	if lean.length() > 0.001:
		var axis := Vector3.UP.cross(Vector3(lean.x, 0.0, lean.y)).normalized()
		b = Basis(axis, lean.length()) * b
	return Transform3D(b.scaled(Vector3.ONE * size), at)


func _xf_on_ground(mesh: Mesh, at: Vector3, yaw: float, size: float) -> Transform3D:
	# Lies along the slope, its middle at the given point.
	var n := _n_at(at.x, at.z)
	var b := (Basis(Quaternion(Vector3.UP, n)) * Basis(Vector3.UP, yaw)).scaled(Vector3.ONE * size)
	return Transform3D(b, at - b * mesh.get_aabb().get_center())


func _add_trunk(at: Vector3, radius: float) -> void:
	if not _in_collision(at.x, at.z):
		return
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = 4.0
	var col := CollisionShape3D.new()
	col.name = "Trunk%d" % _obstacle_count
	col.shape = shape
	col.position = at + Vector3.UP * 1.9
	_obstacles.add_child(col)
	_obstacle_count += 1


# Each kind: the height it's generated at (placement scales it by `size`) and
# how many variants.
const FIR_GEN := {"fir": [17.0, 4], "firm": [8.0, 3]}
const BROAD_GEN := {"isle": [6.0, 4]}
const BUSH_GEN := [1.5, 5]
const FERN_GEN := [0.6, 5]

var _gen: Object
var _broad_mat: Array = []
var _bush_lods: Array = []
var _bush_count := 0
var _fern_lods: Array = []
var _fern_count := 0


func _broad_mats() -> Array:
	# [bark, leaf] for everything leafy: leafy-twig cards from
	# tools/quarry/leaf_atlas.py and the island tree's bark. Made once.
	if _broad_mat.is_empty():
		if _gen == null:
			_gen = load("res://tools/quarry/plant_gen.gd").new()
		var atlas: Texture2D = _gen.coverage_texture("res://assets/level/quarry/foliage/broadleaf_cards.png")
		ResourceSaver.save(atlas, OUT + "meshes/broadleaf_cards.res", ResourceSaver.FLAG_CHANGE_PATH | ResourceSaver.FLAG_COMPRESS)
		atlas.take_over_path(OUT + "meshes/broadleaf_cards.res")
		var tex := F + "models/island_tree_01_island_tree_01_"
		_broad_mat = [_gen.bark_material(load(tex + "diff_2k.jpg"), load(tex + "nor_gl_2k.jpg")), _gen.leaf_material(atlas)]
	return _broad_mat


func _bushes() -> Array:
	# Generated bushes as [near, far] pairs, made on first use.
	if _bush_lods.is_empty():
		var mats := _broad_mats()
		for v in int(BUSH_GEN[1]):
			var pair := []
			for lod in 2:
				var m: ArrayMesh = _gen.mesh(_gen.bush(7300 + v, BUSH_GEN[0], 1.0 if lod == 0 else 0.4), mats[0], mats[1])
				var path := OUT + "meshes/gen_bush_%d_%s.res" % [v, "near" if lod == 0 else "far"]
				ResourceSaver.save(m, path, ResourceSaver.FLAG_CHANGE_PATH | ResourceSaver.FLAG_COMPRESS)
				m.take_over_path(path)
				pair.append(m)
				print("  bush %d %s: %d tris" % [v, "near" if lod == 0 else "far", (m.surface_get_array_index_len(0) + m.surface_get_array_index_len(1)) / 3])
			_bush_lods.append(pair)
	return _bush_lods


func _add_lod_pair(pair: Array, xf: Transform3D, shade: bool) -> void:
	# The full mesh is all that's ever seen, at any distance: swapping to the
	# coarse one popped in mid-view (the CRPG camera always sees past any
	# swap distance, and a swap goes a whole 24 m cell at once). The coarse
	# mesh only stands in for it in the shadow maps, at a fraction of the
	# triangles.
	_add(pair[0], xf, false, false, 0.0)
	if shade:
		_add(pair[1], xf, true, false, 0.0, 0.0, true)


func _add_bush(at: Vector3, yaw: float, size: float, pick: int, shade := true) -> void:
	var pair: Array = _bushes()[pick % int(BUSH_GEN[1])]
	var xf := _xf_tree(at - Vector3.UP * 0.03, yaw, size, Vector2.ZERO)
	_bush_count += 1
	_add_lod_pair(pair, xf, shade)


func _ferns() -> Array:
	# Generated ferns as [near, far] pairs: frond cards from
	# tools/quarry/fern_atlas.py, no bark. Made on first use.
	if _fern_lods.is_empty():
		if _gen == null:
			_gen = load("res://tools/quarry/plant_gen.gd").new()
		var atlas: Texture2D = _gen.coverage_texture("res://assets/level/quarry/foliage/fern_fronds.png")
		ResourceSaver.save(atlas, OUT + "meshes/fern_fronds.res", ResourceSaver.FLAG_CHANGE_PATH | ResourceSaver.FLAG_COMPRESS)
		atlas.take_over_path(OUT + "meshes/fern_fronds.res")
		var leaf: Material = _gen.leaf_material(atlas)
		for v in int(FERN_GEN[1]):
			var pair := []
			for lod in 2:
				var m: ArrayMesh = _gen.mesh(_gen.fern(7400 + v, FERN_GEN[0], 1.0 if lod == 0 else 0.5), null, leaf)
				var path := OUT + "meshes/gen_fern_%d_%s.res" % [v, "near" if lod == 0 else "far"]
				ResourceSaver.save(m, path, ResourceSaver.FLAG_CHANGE_PATH | ResourceSaver.FLAG_COMPRESS)
				m.take_over_path(path)
				pair.append(m)
			_fern_lods.append(pair)
	return _fern_lods


func _add_fern(at: Vector3, pick: int, yaw: float, size: float) -> void:
	var pair: Array = _ferns()[pick % int(FERN_GEN[1])]
	var xf := _xf_tree(at - Vector3.UP * 0.02, yaw, size, Vector2.ZERO)
	_fern_count += 1
	# Full mesh only; it fades at 60 m with the other small plants.
	_add(pair[0], xf, false, false)


func _gen_trees() -> Dictionary:
	if _gen == null:
		_gen = load("res://tools/quarry/plant_gen.gd").new()
	var gen = _gen
	var tex := F + "models/fir_tree_01_fir_tree_01_"
	var atlas: Texture2D = gen.coverage_texture(tex + "twig_cards_diff_2k.png")
	ResourceSaver.save(atlas, OUT + "meshes/fir_cards.res", ResourceSaver.FLAG_CHANGE_PATH | ResourceSaver.FLAG_COMPRESS)
	atlas.take_over_path(OUT + "meshes/fir_cards.res")
	var leaf: Material = gen.leaf_material(atlas)
	var bark: Material = gen.bark_material(load(tex + "bark_diff_2k.jpg"), load(tex + "bark_nor_gl_2k.jpg"))
	var out := {}
	var seed := 7100
	for kind: String in FIR_GEN:
		var h: float = FIR_GEN[kind][0]
		out[kind] = []
		for v in int(FIR_GEN[kind][1]):
			var pair := []
			for lod in 2:
				var m: ArrayMesh = gen.mesh(gen.fir(seed, h, 1.0 if lod == 0 else 0.4), bark, leaf)
				var path := OUT + "meshes/gen_%s_%d_%s.res" % [kind, v, "near" if lod == 0 else "far"]
				ResourceSaver.save(m, path, ResourceSaver.FLAG_CHANGE_PATH | ResourceSaver.FLAG_COMPRESS)
				m.take_over_path(path)
				pair.append(m)
			out[kind].append(pair)
			seed += 1
	var mats := _broad_mats()
	bark = mats[0]
	leaf = mats[1]
	seed = 7200
	for kind: String in BROAD_GEN:
		var h: float = BROAD_GEN[kind][0]
		out[kind] = []
		for v in int(BROAD_GEN[kind][1]):
			var pair := []
			for lod in 2:
				var m: ArrayMesh = gen.mesh(gen.broadleaf(seed, h, 1.0 if lod == 0 else 0.4), bark, leaf)
				var path := OUT + "meshes/gen_%s_%d_%s.res" % [kind, v, "near" if lod == 0 else "far"]
				ResourceSaver.save(m, path, ResourceSaver.FLAG_CHANGE_PATH | ResourceSaver.FLAG_COMPRESS)
				m.take_over_path(path)
				pair.append(m)
				print("  %s %d %s: %d tris" % [kind, v, "near" if lod == 0 else "far", (m.surface_get_array_index_len(0) + m.surface_get_array_index_len(1)) / 3])
			out[kind].append(pair)
			seed += 1
	return out


func _dress_trees() -> void:
	var d := F + "models/"
	var pools := {"sap": _meshes_of("fir_sapling", d)}
	# Firs and broadleaves come from our own generator, each as a near and a
	# far mesh.
	var lods := _gen_trees()
	var roots: Array[Mesh] = _meshes_of("pine_roots", d)
	var bark: Array[Mesh] = _meshes_of("bark_debris_01", d)
	var nettle: Array[Mesh] = _meshes_of("nettle_plant", d)
	var celandine: Array[Mesh] = _meshes_of("celandine_01", d)
	var tufts: Array[Mesh] = _meshes_of("grass_medium_01", d)
	tufts.append_array(_meshes_of("grass_medium_02", d))
	var slabs: Array[Mesh] = _meshes_of("coast_rocks_01", d)
	slabs.append_array(_meshes_of("coast_rocks_02", d))
	var plants := 0

	for t: Dictionary in _trees:
		var p: Vector2 = t.at
		var size: float = t.size
		# Stood on the lowest ground under the trunk, so no side floats.
		var y := minf(_gy(p.x, p.y), minf(minf(_gy(p.x + 0.5, p.y), _gy(p.x - 0.5, p.y)), minf(_gy(p.x, p.y + 0.5), _gy(p.x, p.y - 0.5))))
		var at := Vector3(p.x, y - 0.06, p.y)
		var xf := _xf_tree(at, t.yaw, size, t.lean)
		# The back rows of the treeline cast no shadow: it would land on the hills.
		var shade := _valley_d(p.x, p.y) < 8.0
		if lods.has(t.kind):
			var pair: Array = lods[t.kind][t.pick % lods[t.kind].size()]
			_add_lod_pair(pair, xf, shade)
		else:
			var pool: Array = pools[t.kind]
			_add(pool[t.pick % pool.size()], xf, shade, false, 50.0)
		if TREE_TRUNK[t.kind] > 0.0:
			_add_trunk(at, TREE_TRUNK[t.kind] * size)
		if t.kind == "sap":
			continue
		var conifer: bool = t.kind == "fir" or t.kind == "firm"
		if conifer:
			var r: Mesh = roots[_trng.randi() % roots.size()]
			_add(r, _xf_tree(Vector3(p.x, _gy(p.x, p.y) - 0.04, p.y), t.yaw, size * (1.3 if t.kind == "fir" else 0.7), Vector2.ZERO), true, false, 40.0)
		if _valley_d(p.x, p.y) > 10.0:
			continue
		for k in _trng.randi_range(2, 5):
			var q := p + Vector2.from_angle(_trng.randf() * TAU) * _trng.randf_range(0.8, 3.2)
			if not _clear(q.x, q.y, 0.15) or _n_at(q.x, q.y).y < 0.72:
				continue
			var g := _ground_at(q.x, q.y)
			var roll := _trng.randf()
			if roll < 0.3 and conifer:
				var b: Mesh = bark[_trng.randi() % bark.size()]
				_add(b, _xf_on_ground(b, g + Vector3.UP * 0.02, _trng.randf() * TAU, _trng.randf_range(1.6, 2.6)), false)
			elif roll < 0.3 and _clear(q.x, q.y, 0.8):
				_add_bush(g, _trng.randf() * TAU, _trng.randf_range(0.6, 1.2), _trng.randi())
			elif roll < 0.55:
				_add_fern(g, _trng.randi(), _trng.randf() * TAU, _trng.randf_range(0.8, 1.2))
			elif roll < 0.8:
				var n: Mesh = nettle[_trng.randi() % nettle.size()]
				_add(n, _xf_tree(g - Vector3.UP * 0.02, _trng.randf() * TAU, _trng.randf_range(5.0, 8.0), Vector2.ZERO), false)
			else:
				var c: Mesh = celandine[_trng.randi() % celandine.size()]
				_add(c, _xf_tree(g - Vector3.UP * 0.01, _trng.randf() * TAU, _trng.randf_range(1.8, 2.8), Vector2.ZERO), false)
			plants += 1

	# The treeline's floor: ferns between the trunks.
	for i in 2400:
		var x := _trng.randf_range(X0 + 1.0, X1 - 1.0)
		var z := _trng.randf_range(Z0 + 1.0, Z1 - 1.0)
		var v := _valley_d(x, z)
		if v < 1.0 or v > 14.0 or _canopy_at(x, z) < 0.2 or _pit_d(x, z) < 2.0 or not _clear(x, z, 0.3):
			continue
		var pick := _trng.randi()
		_add_fern(_ground_at(x, z), pick, _trng.randf() * TAU, _trng.randf_range(0.9, 1.5))
		plants += 1

	# Banks: tufts, celandine and nettles at the water's edge, thinning away
	# from it; flat stones half in the shallows.
	for i in 5000:
		var p := _bank_point(0.55, Vector2(3.0, 0.0), Vector2(11.0, 4.0))
		var w := _water_at(p.x, p.y).y
		if w < 0.1 or w > 2.6 or not _clear(p.x, p.y, 0.1, false) or _n_at(p.x, p.y).y < 0.7:
			continue
		if _trng.randf() < smoothstep(0.4, 2.6, w):
			continue
		var g := _ground_at(p.x, p.y)
		var roll := _trng.randf()
		if roll < 0.6:
			var m: Mesh = tufts[_trng.randi() % tufts.size()]
			_add(m, _xf_tree(g - Vector3.UP * 0.02, _trng.randf() * TAU, _trng.randf_range(2.0, 3.6), Vector2.ZERO), false)
		elif roll < 0.82:
			var m: Mesh = celandine[_trng.randi() % celandine.size()]
			_add(m, _xf_tree(g - Vector3.UP * 0.01, _trng.randf() * TAU, _trng.randf_range(1.8, 2.8), Vector2.ZERO), false)
		else:
			var m: Mesh = nettle[_trng.randi() % nettle.size()]
			_add(m, _xf_tree(g - Vector3.UP * 0.02, _trng.randf() * TAU, _trng.randf_range(5.0, 8.0), Vector2.ZERO), false)
		plants += 1
	var stones := 0
	for i in 600:
		if stones >= 26:
			break
		var p := _bank_point(0.6, Vector2(4.0, 0.0), Vector2(10.0, 3.0))
		var w := _water_at(p.x, p.y).y
		if absf(w) > 0.7 or not _clear(p.x, p.y, 0.8, false):
			continue
		var m: Mesh = slabs[_trng.randi() % slabs.size()]
		_add(m, _xf_on_ground(m, _ground_at(p.x, p.y) - Vector3.UP * 0.03, _trng.randf() * TAU, _trng.randf_range(0.035, 0.06)))
		stones += 1
	print("bushes: %d, ferns: %d" % [_bush_count, _fern_count])
	print("forest floor: %d plants, %d bank stones" % [plants, stones])
