extends Control
## Shows a real 3d6 tumble for a dialogue skill check, landing on the
## exact faces SuccessRoll.roll_vs() already rolled — see
## DialogueManager.dice_roll_requested. The roll is fully decided
## before this ever runs; this only ever plays back an already-final
## result, same "decide first, animate second" principle proven out in
## dice_roll_prototype.gd/dice_roll_2d_prototype.gd earlier, now wired
## into the real skill-check flow instead of a standalone demo scene.
##
## Built entirely in code (matching both of those prototypes) rather
## than a hand-authored .tscn — a SubViewport nested under a Control,
## feeding 3 individually-instanced dice, is exactly the kind of tree
## that's easy to get subtly wrong by hand without live-testing it.
##
## Hidden by default. main.tscn adds exactly one of these as a
## CanvasLayer child, after DialogueOverlay/ConversationLog so it
## renders on top of both while a roll is in progress.

const DIE_FACE_NORMALS: Dictionary = {
	1: Vector3.UP, 6: Vector3.DOWN,
	2: Vector3.RIGHT, 5: Vector3.LEFT,
	3: Vector3.BACK, 4: Vector3.FORWARD,
}
const FACE_COLORS: Dictionary = {
	1: Color.RED, 2: Color.LIME, 3: Color.DODGER_BLUE,
	4: Color.YELLOW, 5: Color.MAGENTA, 6: Color.CYAN,
}
const DIE_SPACING: float = 1.4
const TUMBLE_DURATION: float = 1.0

var _dice: Array[Node3D] = []
var _result_label: Label
var _continue_button: Button


func _ready() -> void:
	visible = false
	_build_scene()
	DialogueManager.dice_roll_requested.connect(_on_dice_roll_requested)


func _build_scene() -> void:
	custom_minimum_size = Vector2(420, 280)
	set_anchors_preset(Control.PRESET_CENTER)

	var panel := PanelContainer.new()
	add_child(panel)

	var vbox := VBoxContainer.new()
	panel.add_child(vbox)

	var viewport_container := SubViewportContainer.new()
	vbox.add_child(viewport_container)
	viewport_container.custom_minimum_size = Vector2(400, 170)
	viewport_container.stretch = true

	var viewport := SubViewport.new()
	viewport_container.add_child(viewport)
	viewport.size = Vector2i(400, 170)
	viewport.own_world_3d = true
	viewport.transparent_bg = true

	var camera := Camera3D.new()
	viewport.add_child(camera)
	camera.position = Vector3(0, 2.0, 3.2)
	camera.look_at(Vector3.ZERO, Vector3.UP)

	var light := DirectionalLight3D.new()
	viewport.add_child(light)
	light.rotation_degrees = Vector3(-50, -30, 0)

	for i in 3:
		var die := _build_die()
		viewport.add_child(die)
		die.position = Vector3((i - 1) * DIE_SPACING, 0, 0)
		_dice.append(die)

	_result_label = Label.new()
	vbox.add_child(_result_label)
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_label.add_theme_font_size_override("font_size", 20)

	_continue_button = Button.new()
	vbox.add_child(_continue_button)
	_continue_button.text = "Continue"
	_continue_button.visible = false


## A plain colored-face placeholder — same "mechanic before the art"
## stand-in as dice_roll_prototype.gd, since no real numbered die
## texture exists yet. Swapping in real art later only touches this
## function; _on_dice_roll_requested below never needs to change.
func _build_die() -> Node3D:
	var die := Node3D.new()
	var body := MeshInstance3D.new()
	die.add_child(body)
	body.mesh = BoxMesh.new()
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.15, 0.15, 0.18)
	body.material_override = body_mat

	for face in DIE_FACE_NORMALS:
		var marker := MeshInstance3D.new()
		die.add_child(marker)
		var plane := PlaneMesh.new()
		plane.size = Vector2(0.6, 0.6)
		marker.mesh = plane
		var mat := StandardMaterial3D.new()
		mat.albedo_color = FACE_COLORS[face]
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		marker.material_override = mat

		var normal: Vector3 = DIE_FACE_NORMALS[face]
		marker.position = normal * 0.51
		# Every normal here is axis-aligned, so a direct X/Z rotation is
		# simpler to state (and check by eye) than a general from/to
		# quaternion — same reasoning as dice_roll_prototype.gd.
		if normal == Vector3.UP:
			pass
		elif normal == Vector3.DOWN:
			marker.rotation = Vector3(PI, 0, 0)
		elif normal == Vector3.RIGHT:
			marker.rotation = Vector3(0, 0, -PI / 2)
		elif normal == Vector3.LEFT:
			marker.rotation = Vector3(0, 0, PI / 2)
		elif normal == Vector3.BACK:
			marker.rotation = Vector3(PI / 2, 0, 0)
		elif normal == Vector3.FORWARD:
			marker.rotation = Vector3(-PI / 2, 0, 0)

	return die


func _on_dice_roll_requested(skill_name: String, roll: Dictionary) -> void:
	visible = true
	_continue_button.visible = false
	_result_label.text = "Rolling %s..." % skill_name

	var tweens: Array[Tween] = []
	for i in 3:
		var die: Node3D = _dice[i]
		var face_value: int = roll.dice[i]
		var target_quat: Quaternion = Quaternion(DIE_FACE_NORMALS[face_value], Vector3.UP)
		var target_euler: Vector3 = target_quat.get_euler()
		# Extra whole turns stacked onto the target before tweening —
		# same final orientation either way, but Tween interpolates
		# rotation's X/Y/Z linearly, so the extra turns are visibly
		# travelled through on the way instead of skipped past. Staggered
		# per-die duration so all 3 don't land in perfect unison.
		var spun_euler: Vector3 = target_euler + Vector3(
			TAU * randi_range(2, 3), TAU * randi_range(2, 3), 0
		)
		die.rotation = Vector3(randf_range(0, TAU), randf_range(0, TAU), randf_range(0, TAU))
		var tween: Tween = create_tween()
		tween.tween_property(die, "rotation", spun_euler, TUMBLE_DURATION + i * 0.15) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tweens.append(tween)

	for tween in tweens:
		await tween.finished
	# Normalize off the extra full turns now that every die has landed.
	for i in 3:
		_dice[i].rotation = Quaternion(DIE_FACE_NORMALS[roll.dice[i]], Vector3.UP).get_euler()

	var verdict: String = "Failed"
	if roll.critical_success:
		verdict = "Critical success!"
	elif roll.critical_failure:
		verdict = "Critical failure!"
	elif roll.success:
		verdict = "Success"
	_result_label.text = "%s — %d vs %d" % [verdict, roll.roll, roll.target]

	_continue_button.visible = true
	await _continue_button.pressed
	visible = false
	DialogueManager.dice_roll_finished.emit()
