extends Node3D
## Tenement kit test: buildings stacked from assets/level/tenement_kit pieces
## (2.5 m bays; plinth 0-1.5, stone ground storey 1.5-4.0, ledge band to 4.5,
## brick storeys every 2.5 m), next to the kit's own assembled tenement, with
## 1.8 m capsules for scale. Play to orbit; run with `-- <dir>` to save shots.
##
## Piece frame: origin at the facade's bottom-left on the wall plane, the bay
## runs +X, the facade faces +Z, the inside is -Z.

const K := "res://assets/level/tenement_kit/pieces/"
const BAY := 2.5
const PLINTH := 1.5
const BAND := 4.0  # ledge band bottom; brick starts at BAND + 2 * LEDGE
const LEDGE := 0.25

var _cam: Camera3D
var _t := 0.0
var _out := ""
var _cache := {}


func _ready() -> void:
	_stage()
	# w bays wide, d deep, brick storeys, entrance bay, balcony bays
	_building(Vector3(0, 0, 0), 5, 4, 3, 2, [])
	_building(Vector3(14, 0, 0), 4, 4, 4, 1, [2])
	_building(Vector3(25, 0, 0), 3, 3, 2, 0, [])
	_put("tenement", Vector3(-17, 0, 0), 0)
	_put("downspout", Vector3(11.5, 0, 0), 0)
	_put("ac_unit", Vector3(4.0, 0, 1.2), 0)
	_put("ac_unit", Vector3(30.6, 0, 1.1), PI / 2)
	_put("roof_hut", Vector3(17, BAND + 2 * LEDGE + 4 * BAY, -3.8), 0)
	for x in [5.6, 18.8]:
		var cap := MeshInstance3D.new()
		var cm := CapsuleMesh.new()
		cm.height = 1.8
		cm.radius = 0.25
		cap.mesh = cm
		cap.position = Vector3(x, 0.9, 2.4)
		add_child(cap)


func _building(at: Vector3, w: int, d: int, storeys: int, door: int, balconies: Array) -> void:
	var brick := BAND + 2 * LEDGE
	var top := brick + storeys * BAY
	# Four facades, walked anticlockwise from above: front, right, back, left.
	var starts := [Vector3(0, 0, 0), Vector3(w * BAY, 0, 0), Vector3(w * BAY, 0, -d * BAY), Vector3(0, 0, -d * BAY)]
	var lens := [w, d, w, d]
	for f in 4:
		var yaw := f * PI / 2
		var dir := Vector3.RIGHT.rotated(Vector3.UP, yaw)
		var n: int = lens[f]
		for i in n:
			var p: Vector3 = at + starts[f] + dir * (i * BAY)
			var entrance := f == 0 and i == door
			# The previous facade's corner piece wraps round onto bay 0.
			if entrance:
				_put("entrance", p, yaw)
			elif i == n - 1:
				_put("plinth_corner", p, yaw)
			elif i > 0:
				_put("plinth", p, yaw)
			if not entrance:
				_put("stone_window" if (i + f) % 2 == 0 or f == 0 else "stone_wall", p + Vector3.UP * PLINTH, yaw)
			for y in [BAND, BAND + LEDGE, top, top + LEDGE]:
				_put("ledge", p + Vector3.UP * y, yaw)
			for s in storeys:
				var blank := f % 2 == 1 and i % 2 == 1
				_put("brick_wall" if blank else "brick_window", p + Vector3.UP * (brick + s * BAY), yaw)
				if f == 0 and i in balconies and i + 1 < n:
					_put("balcony", p + Vector3.UP * (brick + s * BAY), yaw)
	var roof := _put("roof", at + Vector3.UP * top, 0)
	roof.scale = Vector3(w / 5.0, 1, d / 5.0)  # the roof piece is 5x5 bays


func _put(piece: String, at: Vector3, yaw: float) -> Node3D:
	if not _cache.has(piece):
		_cache[piece] = load(K + piece + ".tscn")
	var n: Node3D = _cache[piece].instantiate()
	n.position = at
	n.rotation.y = yaw
	add_child(n)
	return n


func _stage() -> void:
	var env := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.ssao_enabled = true
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 30, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(150, 100)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.3, 0.3, 0.31)
	gm.roughness = 1.0
	ground.material_override = gm
	ground.position = Vector3(5, -0.01, 0)
	add_child(ground)
	_cam = Camera3D.new()
	_cam.fov = 50
	add_child(_cam)
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out = args[0]
	_aim(0.45)


func _aim(a: float) -> void:
	var c := Vector3(8, 6, -4)
	_cam.position = c + Vector3(sin(a) * 37.0, 7.5, cos(a) * 37.0)
	_cam.look_at(c)


func _process(delta: float) -> void:
	_t += delta
	if _out == "":
		_aim(0.45 + _t * 0.2)
		return
	var f := Engine.get_process_frames()
	if f == 30:
		_shot("tenement_a.png")
		_aim(-0.6)
	elif f == 60:
		_shot("tenement_b.png")
		_cam.position = Vector3(24, 1.6, 11)
		_cam.look_at(Vector3(12.5, 5.6, 0))
	elif f == 90:
		_shot("tenement_c.png")
		get_tree().quit()


func _shot(file: String) -> void:
	get_viewport().get_texture().get_image().save_png(_out.path_join(file))
