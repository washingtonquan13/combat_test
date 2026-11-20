extends Node3D
## The Character Creator humans in a lit studio, on CC's materials
## (CCMaterials): male and female bases idling on a backdrop, three-point
## lighting, orbit camera.
##
## Drag: orbit. Wheel: zoom. 1-4: camera (pair, his face, her face, from
## behind). L: lighting. E: expression. T: tints. M: CC shaders on/off.
##
## For renders, CC_SHOT=<name> CC_CAM=<1-4> CC_LIGHT=<0-3> CC_EXPR=<0-4>
## saves $TEMP/human_<name>.png and quits.

const LIB := "res://assets/locomotion_animations.tres"
const BASES := {"male": Vector3(-0.45, 0, 0), "female": Vector3(0.45, 0, 0)}

const LIGHTS := [
	# name, key energy, key colour, key angles, fill, rim, ambient, sky energy
	["Studio", 2.2, Color(1.0, 0.96, 0.9), Vector3(-30, 35, 0), 0.5, 3.0, 0.35],
	["Torch", 1.6, Color(1.0, 0.7, 0.45), Vector3(-15, 70, 0), 0.15, 2.0, 0.12],
	["Overcast", 0.9, Color(0.9, 0.95, 1.0), Vector3(-60, 10, 0), 1.0, 0.6, 0.8],
	["Backlit", 0.5, Color(1.0, 0.95, 0.9), Vector3(-25, 30, 0), 0.25, 9.0, 0.25],
]
const EXPRESSIONS := [
	["Neutral", {}],
	["Smile", {"Mouth_Smile_L": 1.0, "Mouth_Smile_R": 1.0, "Cheek_Raise_L": 0.7, "Cheek_Raise_R": 0.7, "Eye_Squint_L": 0.3, "Eye_Squint_R": 0.3}],
	["Speaking", {"V_Open": 0.5, "Jaw_Open": 0.35}, 10.0],
	["Worried", {"Brow_Raise_Inner_L": 0.9, "Brow_Raise_Inner_R": 0.9, "Brow_Drop_L": 0.3, "Brow_Drop_R": 0.3, "Mouth_Frown_L": 0.6, "Mouth_Frown_R": 0.6}],
	["Angry", {"Brow_Drop_L": 1.0, "Brow_Drop_R": 1.0, "Nose_Sneer_L": 0.6, "Nose_Sneer_R": 0.6, "Mouth_Shrug_Upper": 0.4, "Eye_Squint_L": 0.5, "Eye_Squint_R": 0.5}],
]
# name, male skin, iris, hair, female skin, iris, hair (hair alpha 0: CC's).
const TINTS := [
	["As made", Color(1, 1, 1), Color(1, 1, 1), Color(0, 0, 0, 0), Color(1, 1, 1), Color(1, 1, 1), Color(0, 0, 0, 0)],
	["Tanned, green eyes", Color(0.86, 0.72, 0.6), Color(0.5, 0.85, 0.55), Color(0.45, 0.28, 0.14), Color(0.9, 0.76, 0.64), Color(0.55, 0.8, 0.6), Color(0.55, 0.18, 0.08)],
	["Dark, brown eyes", Color(0.5, 0.36, 0.28), Color(0.6, 0.42, 0.28), Color(0.05, 0.04, 0.035), Color(0.46, 0.33, 0.26), Color(0.55, 0.38, 0.26), Color(0.07, 0.05, 0.04)],
	["Pale, blue eyes", Color(1.05, 0.98, 0.96), Color(0.55, 0.7, 1.0), Color(0.75, 0.62, 0.4), Color(1.04, 0.97, 0.95), Color(0.6, 0.75, 1.0), Color(0.8, 0.68, 0.45)],
]

var chars := {}
var cam: Camera3D
var key: DirectionalLight3D
var fill: OmniLight3D
var rim: SpotLight3D
var env: Environment
var label: Label
var yaw := 0.0
var pitch := -5.0
var dist := 3.2
var target := Vector3(0, 1.0, 0)
var light_i := 0
var expr_i := 0
var tint_i := 0
var cc_on := true
var blink_t := 0.0
var frames := 0
var shot := ""


func _ready() -> void:
	shot = OS.get_environment("CC_SHOT")
	_build_stage()
	for sex: String in BASES:
		var c: Node3D = (load("res://assets/characters/cc/%s/cc_base_%s.fbx" % [sex, sex]) as PackedScene).instantiate()
		c.position = BASES[sex]
		c.rotation_degrees.y = 12.0 if sex == "male" else -12.0
		add_child(c)
		CCMaterials.fix_shape_tangents(c)
		var ap := AnimationPlayer.new()
		c.add_child(ap)
		ap.root_node = NodePath("..")
		ap.add_animation_library("", load(LIB))
		ap.play("idle")
		if sex == "female":
			ap.seek(1.3, true)
		CCMaterials.apply(c, "res://assets/characters/cc/%s/cc_base_%s.json" % [sex, sex])
		var hair := "res://assets/characters/cc/hair/%s/cc_hair_%s" % [sex, sex]
		CCMaterials.attach_hair(c, hair + ".fbx", hair + ".json")
		chars[sex] = c
	_camera(int(OS.get_environment("CC_CAM")) if OS.get_environment("CC_CAM") != "" else 1)
	_lighting(int(OS.get_environment("CC_LIGHT")) if OS.get_environment("CC_LIGHT") != "" else 0)
	expr_i = int(OS.get_environment("CC_EXPR")) if OS.get_environment("CC_EXPR") != "" else 0
	_expression()
	if OS.get_environment("CC_TINT") != "":
		tint_i = int(OS.get_environment("CC_TINT"))
	_tints()
	if OS.get_environment("CC_OFF") != "":
		_toggle_cc()
	_update_label()


func _build_stage() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var ps := ProceduralSkyMaterial.new()
	ps.sky_top_color = Color(0.32, 0.36, 0.42)
	ps.sky_horizon_color = Color(0.5, 0.5, 0.5)
	ps.ground_bottom_color = Color(0.18, 0.16, 0.15)
	ps.ground_horizon_color = Color(0.4, 0.38, 0.36)
	sky.sky_material = ps
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.ssao_enabled = true
	env.ssao_radius = 0.6
	env.ssao_intensity = 1.5
	env.glow_enabled = true
	env.glow_intensity = 0.3
	env.glow_bloom = 0.02
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	# A seamless cove: floor curving up into a back wall.
	var backdrop := MeshInstance3D.new()
	backdrop.mesh = _cove()
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Color(0.36, 0.34, 0.33)
	bm.roughness = 0.9
	bm.cull_mode = BaseMaterial3D.CULL_DISABLED
	backdrop.material_override = bm
	add_child(backdrop)

	key = DirectionalLight3D.new()
	key.shadow_enabled = true
	key.shadow_blur = 1.5
	key.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	key.directional_shadow_max_distance = 12.0
	add_child(key)
	fill = OmniLight3D.new()
	fill.position = Vector3(-2.5, 1.6, 2.5)
	fill.omni_range = 8.0
	fill.light_color = Color(0.75, 0.85, 1.0)
	add_child(fill)
	rim = SpotLight3D.new()
	rim.position = Vector3(0.6, 2.4, -2.2)
	rim.look_at_from_position(rim.position, Vector3(0, 1.4, 0))
	rim.spot_range = 8.0
	rim.spot_angle = 35.0
	rim.shadow_enabled = true
	rim.shadow_blur = 1.5
	add_child(rim)

	cam = Camera3D.new()
	add_child(cam)
	cam.make_current()

	label = Label.new()
	label.position = Vector2(16, 12)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	var ui := CanvasLayer.new()
	add_child(ui)
	ui.add_child(label)
	label.visible = shot == ""


func _cove() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rows := []
	# Profile in (z, y): floor from z=6 to z=-2, then a quarter circle of
	# radius 2 up to the wall, then the wall to y=8.
	for i in 9:
		rows.append(Vector2(6.0 - i, 0.0))
	for i in range(1, 13):
		var a := float(i) / 12.0 * PI * 0.5
		rows.append(Vector2(-2.0 - sin(a) * 2.0, 2.0 - cos(a) * 2.0))
	rows.append(Vector2(-4.0, 8.0))
	for r in rows.size() - 1:
		for x in [-10.0]:
			var a: Vector2 = rows[r]
			var b: Vector2 = rows[r + 1]
			var p := [Vector3(x, a.y, a.x), Vector3(-x, a.y, a.x), Vector3(-x, b.y, b.x), Vector3(x, b.y, b.x)]
			for k in [0, 1, 2, 0, 2, 3]:
				st.add_vertex(p[k])
	st.generate_normals()
	return st.commit()


func _camera(i: int) -> void:
	match i:
		1:
			target = Vector3(0, 1.0, 0); yaw = 0.0; pitch = -4.0; dist = 3.4; cam.fov = 40
		2:
			target = chars["male"].position + Vector3(-0.02, 1.66, 0); yaw = 18.0; pitch = -2.0; dist = 0.75; cam.fov = 30
		3:
			target = chars["female"].position + Vector3(0.02, 1.57, 0); yaw = -18.0; pitch = -2.0; dist = 0.72; cam.fov = 30
		4:
			target = Vector3(0, 1.4, 0); yaw = 150.0; pitch = -6.0; dist = 2.6; cam.fov = 40
	_place_camera()


func _place_camera() -> void:
	var b := Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0))
	cam.position = target + b * Vector3(0, 0, dist)
	cam.look_at(target)


func _lighting(i: int) -> void:
	light_i = i % LIGHTS.size()
	var l: Array = LIGHTS[light_i]
	key.light_energy = l[1]
	key.light_color = l[2]
	key.rotation_degrees = l[3]
	fill.light_energy = l[4]
	rim.light_energy = l[5]
	env.ambient_light_energy = l[6]
	env.background_energy_multiplier = l[6] * 2.0


func _expression() -> void:
	var e: Array = EXPRESSIONS[expr_i]
	for c: Node3D in chars.values():
		for m: MeshInstance3D in c.find_children("*", "MeshInstance3D", true, false):
			for k in m.get_blend_shape_count():
				var n: String = (m.mesh as ArrayMesh).get_blend_shape_name(k)
				if n.begins_with("Eye_Blink"):
					continue
				m.set_blend_shape_value(k, e[1].get(n, 0.0))


func _tints() -> void:
	var t: Array = TINTS[tint_i]
	CCMaterials.set_tints(chars["male"], t[1], t[2])
	CCMaterials.set_hair_color(chars["male"], t[3])
	CCMaterials.set_tints(chars["female"], t[4], t[5])
	CCMaterials.set_hair_color(chars["female"], t[6])


func _toggle_cc() -> void:
	cc_on = not cc_on
	for sex: String in chars:
		if cc_on:
			CCMaterials.apply(chars[sex], "res://assets/characters/cc/%s/cc_base_%s.json" % [sex, sex])
			CCMaterials.apply(chars[sex], "res://assets/characters/cc/hair/%s/cc_hair_%s.json" % [sex, sex])
		else:
			CCMaterials.clear(chars[sex])


func _update_label() -> void:
	label.text = "Drag orbit · wheel zoom · 1-4 camera\nL lighting: %s · E expression: %s · T tint: %s · M CC shaders: %s" % [
		LIGHTS[light_i][0], EXPRESSIONS[expr_i][0], TINTS[tint_i][0], "on" if cc_on else "off (imported)"]


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventMouseMotion and ev.button_mask & MOUSE_BUTTON_MASK_LEFT:
		yaw -= ev.relative.x * 0.3
		pitch = clampf(pitch - ev.relative.y * 0.3, -60.0, 40.0)
		_place_camera()
	elif ev is InputEventMouseButton and ev.pressed:
		if ev.button_index == MOUSE_BUTTON_WHEEL_UP:
			dist = maxf(0.3, dist * 0.9)
			_place_camera()
		elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dist = minf(10.0, dist * 1.1)
			_place_camera()
	elif ev is InputEventKey and ev.pressed and not ev.echo:
		match ev.keycode:
			KEY_1, KEY_2, KEY_3, KEY_4:
				_camera(ev.keycode - KEY_0)
			KEY_L:
				_lighting(light_i + 1)
			KEY_E:
				expr_i = (expr_i + 1) % EXPRESSIONS.size()
				_expression()
			KEY_T:
				tint_i = (tint_i + 1) % TINTS.size()
				_tints()
			KEY_M:
				_toggle_cc()
		_update_label()


func _process(delta: float) -> void:
	# The jaw shapes are correctives: the jaw bone itself opens the mouth.
	# It turns about the skeleton's left-right axis, seen from the bone.
	var e: Array = EXPRESSIONS[expr_i]
	var jaw: float = e[2] if e.size() > 2 else 0.0
	if OS.get_environment("CC_JAW") != "":
		jaw = float(OS.get_environment("CC_JAW"))
	for c: Node3D in chars.values():
		var sk := c.find_child("GeneralSkeleton", true, false) as Skeleton3D
		var j := sk.find_bone("Jaw")
		if j >= 0:
			var rest := sk.get_bone_rest(j).basis.get_rotation_quaternion()
			var axis := sk.get_bone_global_rest(j).basis.inverse() * Vector3.RIGHT
			sk.set_bone_pose_rotation(j, rest * Quaternion(axis.normalized(), deg_to_rad(jaw)))
	# A blink every few seconds.
	blink_t += delta
	var period := 3.7
	var ph := fmod(blink_t, period)
	var b := 0.0
	if ph < 0.15 and shot == "":
		b = sin(ph / 0.15 * PI)
	for c: Node3D in chars.values():
		var body := c.find_child("CC_Base_Body", true, false) as MeshInstance3D
		for n: String in ["Eye_Blink_L", "Eye_Blink_R"]:
			var k := body.find_blend_shape_by_name(n)
			if k >= 0:
				body.set_blend_shape_value(k, b)
	if shot != "":
		frames += 1
		if frames == 20:
			get_viewport().get_texture().get_image().save_png(OS.get_environment("TEMP") + "/human_%s.png" % shot)
			get_tree().quit()
