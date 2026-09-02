extends Node3D
## Standalone prototype — proves out "tumble, then settle on a
## pre-decided result" for an animated 3d6 roll (this project's actual
## resolution mechanic, not BG3's d20). The result is picked FIRST, by
## a plain randi_range — the animation only ever sells that result,
## never determines it, same as the real industry technique discussed
## alongside this. Run this scene directly (F6) and press Roll.
##
## Built entirely in code, no mesh/texture assets — a flat color per
## face stands in for a real carved numeral, so "does this consistently
## land on the correct face" is verifiable just by eye (does the same
## color always come up when the label says the same number), without
## needing any art at all. The mechanic first, same instinct as
## ProtoBlock blocking out a level before real geometry exists.

const FACE_COLORS: Dictionary = {
	1: Color.RED, 2: Color.LIME, 3: Color.DODGER_BLUE,
	4: Color.YELLOW, 5: Color.MAGENTA, 6: Color.CYAN,
}
const FACE_NORMALS: Dictionary = {
	1: Vector3.UP, 6: Vector3.DOWN,
	2: Vector3.RIGHT, 5: Vector3.LEFT,
	3: Vector3.BACK, 4: Vector3.FORWARD,
}

var _die: Node3D
var _result_label: Label
var _rolling: bool = false


func _ready() -> void:
	_build_scene()


func _build_scene() -> void:
	var camera := Camera3D.new()
	add_child(camera)
	camera.position = Vector3(0, 2.2, 3.5)
	camera.look_at(Vector3.ZERO, Vector3.UP)

	var light := DirectionalLight3D.new()
	add_child(light)
	light.rotation_degrees = Vector3(-50, -30, 0)

	_die = Node3D.new()
	add_child(_die)

	var body := MeshInstance3D.new()
	_die.add_child(body)
	body.mesh = BoxMesh.new()
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.15, 0.15, 0.18)
	body.material_override = body_mat

	for face in FACE_NORMALS:
		_add_face_marker(face)

	var canvas := CanvasLayer.new()
	add_child(canvas)

	var roll_button := Button.new()
	canvas.add_child(roll_button)
	roll_button.text = "Roll"
	roll_button.position = Vector2(20, 20)
	roll_button.pressed.connect(_roll)

	_result_label = Label.new()
	canvas.add_child(_result_label)
	_result_label.position = Vector2(20, 60)
	_result_label.add_theme_font_size_override("font_size", 24)
	_result_label.text = "Press Roll"


func _add_face_marker(face: int) -> void:
	var marker := MeshInstance3D.new()
	_die.add_child(marker)
	var plane := PlaneMesh.new()
	plane.size = Vector2(0.7, 0.7)
	marker.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = FACE_COLORS[face]
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	marker.material_override = mat

	var normal: Vector3 = FACE_NORMALS[face]
	marker.position = normal * 0.51
	# PlaneMesh's own unrotated normal is +Y — align it to this face's
	# outward normal. Every normal here is axis-aligned, so a direct
	# X/Z rotation is simpler to state (and check by eye once running)
	# than a general from/to quaternion.
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


func _roll() -> void:
	if _rolling:
		return
	_rolling = true

	var result: int = randi_range(1, 6)
	_result_label.text = "Rolling..."

	_die.rotation = Vector3(randf_range(0, TAU), randf_range(0, TAU), randf_range(0, TAU))

	# result is already decided, above, before any of this animates —
	# the die's final orientation is chosen TO MATCH result, never read
	# back FROM wherever it happens to land. That's the whole point
	# being tested here.
	var target_quat: Quaternion = Quaternion(FACE_NORMALS[result], Vector3.UP)
	var target_euler: Vector3 = target_quat.get_euler()
	# Extra whole turns stacked onto the target before tweening — same
	# final orientation either way (rotation repeats every TAU), but
	# Tween interpolates rotation's X/Y/Z LINEARLY and independently, so
	# the extra turns are visibly travelled through on the way there
	# instead of skipped past. That's the entire trick to a tumble that
	# both spins AND still lands correctly.
	var spun_euler: Vector3 = target_euler + Vector3(
		TAU * randi_range(2, 3), TAU * randi_range(2, 3), 0
	)

	var tween: Tween = create_tween()
	tween.tween_property(_die, "rotation", spun_euler, 1.2) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	await tween.finished

	_die.rotation = target_euler  # normalize off the extra full turns
	_result_label.text = "Result: %d" % result
	_rolling = false
