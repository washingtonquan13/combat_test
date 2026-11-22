extends Node3D
## Medieval kit test: two houses kitbashed from assets/level/medieval_kit
## pieces (Quaternius MegaKit re-textured with Poly Haven materials), with
## 1.8 m capsules for scale. Play to orbit; run with `-- <dir>` to save shots.
##
## Piece frame: walls are 2 m bays centred on the origin, 3.12 m tall, the
## outside faces +Z (wall plane z = 0). Gable roofs run their ridge along Z;
## Roof_RoundTiles_WxL covers a W m (X) by L m (Z) footprint.

const K := "res://assets/level/medieval_kit/pieces/"
const BAY := 2.0
const STOREY := 3.12

var _cam: Camera3D
var _t := 0.0
var _out := ""
var _cache := {}


func _ready() -> void:
	_stage()
	_house(Vector3(0, 0, 0), 3, 4, true)
	_house(Vector3(11, 0, -1), 2, 3, false)
	for x in [1.2, 9.5]:
		var cap := MeshInstance3D.new()
		var cm := CapsuleMesh.new()
		cm.height = 1.8
		cm.radius = 0.25
		cap.mesh = cm
		cap.position = Vector3(x, 0.9, 5.6)
		add_child(cap)


## w bays across (X) and d bays deep (Z); stone ground storey on the big house,
## plaster all the way up on the small one. The door is mid-front.
func _house(at: Vector3, w: int, d: int, stone: bool) -> void:
	var hw := w * BAY / 2.0
	var hd := d * BAY / 2.0
	# front (+Z), right (+X), back (-Z), left (-X): centre, yaw, bays
	var faces := [[Vector3(0, 0, hd), 0.0, w], [Vector3(hw, 0, 0), PI / 2, d],
		[Vector3(0, 0, -hd), PI, w], [Vector3(-hw, 0, 0), -PI / 2, d]]
	for f in 4:
		var c: Vector3 = at + faces[f][0]
		var yaw: float = faces[f][1]
		var n: int = faces[f][2]
		var along := Vector3.RIGHT.rotated(Vector3.UP, yaw)
		for i in n:
			var p := c + along * ((i - (n - 1) / 2.0) * BAY)
			var door := f == 0 and i == n / 2
			var window := (i + f) % 2 == 0
			var base := "UnevenBrick" if stone else "Plaster"
			if door:
				_put("Wall_%s_Door_Round" % base, p, yaw)
				_put("Door_1_Round", p + along * -0.53, yaw)
			elif window:
				_put("Wall_%s_Window_Wide_Round" % base, p, yaw)
				_put("Window_Wide_Round1", p, yaw)
				_put("WindowShutters_Wide_Round_Closed" if f % 2 else "WindowShutters_Wide_Round_Open", p, yaw)
			else:
				_put("Wall_UnevenBrick_Straight" if stone else "Wall_Plaster_Straight_Base", p, yaw)
			var up := p + Vector3.UP * STOREY
			if (i + f) % 2 == 1 or door:
				_put("Wall_Plaster_Window_Wide_Flat", up, yaw)
				_put("Window_Wide_Flat1", up, yaw)
				_put("WindowShutters_Wide_Flat_Open", up, yaw)
			else:
				_put("Wall_Plaster_WoodGrid", up, yaw)
		# corner where this face ends and the next begins
		var corner := c + along * (n * BAY / 2.0)
		_put("Corner_Exterior_Brick" if stone else "Corner_Exterior_Wood", corner, yaw)
		_put("Corner_Exterior_Wood", corner + Vector3.UP * STOREY, yaw)
	var top := at + Vector3.UP * 2 * STOREY
	_put("Roof_RoundTiles_%dx%d" % [w * 2, d * 2], top, 0)
	var gable := "Roof_Front_Brick%d" % (w * 2)
	_put(gable, top + Vector3(0, 0, hd), 0)
	_put(gable, top + Vector3(0, 0, -hd), PI)
	_put("Prop_Chimney", top + Vector3(hw * 0.5, 0.6, -hd * 0.5), 0)
	_put("Prop_Vine1", at + Vector3(-hw + 0.7, STOREY + 0.6, hd + 0.05), 0)


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
	sun.rotation_degrees = Vector3(-40, 35, 0)
	sun.shadow_enabled = true
	add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(100, 100)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.3, 0.29, 0.26)
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
	_aim(0.5)


func _aim(a: float) -> void:
	var c := Vector3(5, 4, -0.5)
	_cam.position = c + Vector3(sin(a) * 24.0, 4.0, cos(a) * 24.0)
	_cam.look_at(c)


func _process(delta: float) -> void:
	_t += delta
	if _out == "":
		_aim(0.5 + _t * 0.2)
		return
	var f := Engine.get_process_frames()
	if f == 30:
		_shot("medieval_a.png")
		_aim(PI + 0.6)
	elif f == 60:
		_shot("medieval_b.png")
		_cam.position = Vector3(-2.5, 1.7, 9.5)
		_cam.look_at(Vector3(0.5, 2.6, 4))
	elif f == 90:
		_shot("medieval_c.png")
		get_tree().quit()


func _shot(file: String) -> void:
	get_viewport().get_texture().get_image().save_png(_out.path_join(file))
