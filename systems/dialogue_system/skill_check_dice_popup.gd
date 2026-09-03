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
## The die's OVERALL correction per face — NOT the same rotations used
## to place each face's Label3D in _build_die(). This set answers "how
## do I rotate the whole die, as a rigid body, so THIS face ends up
## where Basis.looking_at()'s own -Z convention expects" — i.e. each
## entry is R such that R * DIE_FACE_NORMALS[face] == Vector3(0,0,-1).
## Composed with a camera-facing basis in _on_dice_roll_requested() so
## the chosen face lands pointed at the camera, not just "up" — hand-
## derived per axis-aligned face rather than a generic from/to
## quaternion, which leaves the roll around that axis undetermined
## (fine for a plain color, not fine for a numeral that needs to stay
## upright instead of landing sideways).
const FACE_TO_FORWARD_EULER: Dictionary = {
	1: Vector3(-PI / 2, 0, 0), 6: Vector3(PI / 2, 0, 0),
	2: Vector3(0, PI / 2, 0), 5: Vector3(0, -PI / 2, 0),
	3: Vector3(PI, 0, 0), 4: Vector3(0, 0, 0),
}
const DIE_SPACING: float = 1.4
const TUMBLE_DURATION: float = 1.0
## Each die's tween runs this much longer than the previous die's, so
## all 3 visibly stop in sequence instead of landing in a near-unison
## blur — big enough to read as "one at a time," not just jitter.
const STAGGER_STEP: float = 0.4
## Arbitrary — the roll hasn't happened yet, so no face value is
## "correct" while waiting on the Roll button. Just needs to be some
## fixed value so the idle pose is camera-facing instead of whatever
## identity/last-landed rotation the die happened to have.
const IDLE_FACE_VALUE: int = 1
## Bottom-right, in a small footprint above the conversation band, rather
## than the old dead-centre placement — dead centre sat directly over the
## speaker, which is exactly what the lower-third layout keeps clear.
##
## Anchored to the BOTTOM of the screen, not to a fractional line. An
## earlier version pinned to 0.65 to track the old overlay's own
## anchor_top, but the new band is sized to its CONTENT and pinned to the
## bottom, so there is no fractional line left to track. _BAND_CLEARANCE
## is the room that band needs: its own height plus a gap. If the band
## ever grows past it (a very long choice list), the dice will overlap it
## rather than the speaker, which is the better of the two failures.
##
## Both anchors on each axis are equal, so Godot's anchor-spread sizing
## does not apply: the size is exactly offset_right minus offset_left by
## offset_bottom minus offset_top, a fixed 150x150 pinned to that corner
## as the window resizes.
const _CORNER_SIZE: float = 150.0
const _CORNER_MARGIN: float = 20.0
## Height the conversation band needs at the bottom, plus a gap above it.
const _BAND_CLEARANCE: float = 170.0

var _camera: Camera3D
var _dice: Array[Node3D] = []
var _result_label: Label
var _continue_button: Button


func _ready() -> void:
	visible = false
	_build_scene()
	DialogueManager.dice_roll_requested.connect(_on_dice_roll_requested)


func _build_scene() -> void:
	anchor_left = 1.0
	anchor_top = 1.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = -(_CORNER_SIZE + _CORNER_MARGIN)
	offset_top = -(_CORNER_SIZE + _BAND_CLEARANCE)
	offset_right = -_CORNER_MARGIN
	offset_bottom = -_BAND_CLEARANCE
	custom_minimum_size = Vector2(_CORNER_SIZE, _CORNER_SIZE)

	var panel := PanelContainer.new()
	add_child(panel)

	var vbox := VBoxContainer.new()
	panel.add_child(vbox)

	# 130x55 rather than the old 400x170 — scaled down to fit the 150x150
	# corner box, but kept at (almost exactly) the SAME aspect ratio
	# (400:170 ≈ 2.35, 130:55 ≈ 2.36) on purpose: _face_toward_camera_euler
	# and the camera's own position/FOV below are untouched, so a viewport
	# with a different aspect would crop the two outer dice instead of just
	# rendering the same framing at a lower resolution.
	var viewport_container := SubViewportContainer.new()
	vbox.add_child(viewport_container)
	viewport_container.custom_minimum_size = Vector2(130, 55)
	viewport_container.stretch = true

	var viewport := SubViewport.new()
	viewport_container.add_child(viewport)
	viewport.size = Vector2i(130, 55)
	viewport.own_world_3d = true
	viewport.transparent_bg = true

	_camera = Camera3D.new()
	viewport.add_child(_camera)
	_camera.position = Vector3(0, 2.0, 3.2)
	_camera.look_at(Vector3.ZERO, Vector3.UP)

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
	_result_label.add_theme_font_size_override("font_size", 12)
	# Word-wraps ("Critical success! — 14 vs 10" etc.) inside the 130px
	# viewport width above instead of forcing the whole popup wider than
	# the 150x150 corner box it's now anchored into.
	_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_result_label.custom_minimum_size = Vector2(130, 0)

	_continue_button = Button.new()
	vbox.add_child(_continue_button)
	_continue_button.text = "Continue"
	_continue_button.visible = false


## A real numeral per face — no texture asset exists, but Label3D
## renders actual legible text without needing one, a step up from
## dice_roll_prototype.gd's flat-colored-square placeholder. Swapping
## in real numbered art later only touches this function;
## _on_dice_roll_requested below never needs to change.
##
## The per-face rotation below is confirmed correct on its own terms —
## it aims each face's content at the right world direction, verified
## live (the die itself always presents the intended face to the
## camera). What was still wrong after that was the glyph ITSELF
## reading mirrored on every face — a separate, orthogonal problem:
## rotation alone can never mirror anything (it's orientation-
## preserving), so no amount of retuning the rotation table above could
## ever have fixed this. scale.x = -1 corrects the glyph in the label's
## own local space, independent of and unaffected by whichever way
## that space then gets rotated to face outward. billboard stays
## explicitly disabled: each numeral must rotate WITH the die during
## the tumble and only read correctly once genuinely landed, never
## fake it by always facing the camera.
func _build_die() -> Node3D:
	var die := Node3D.new()
	var body := MeshInstance3D.new()
	die.add_child(body)
	body.mesh = BoxMesh.new()
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.15, 0.15, 0.18)
	body.material_override = body_mat

	for face in DIE_FACE_NORMALS:
		var label := Label3D.new()
		die.add_child(label)
		label.text = str(face)
		label.font_size = 64
		label.pixel_size = 0.008
		label.modulate = Color(0.92, 0.88, 0.78)
		label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		label.scale.x = -1

		var normal: Vector3 = DIE_FACE_NORMALS[face]
		label.position = normal * 0.52
		if normal == Vector3.UP:
			label.rotation = Vector3(-PI / 2, 0, 0)
		elif normal == Vector3.DOWN:
			label.rotation = Vector3(PI / 2, 0, 0)
		elif normal == Vector3.RIGHT:
			label.rotation = Vector3(0, PI / 2, 0)
		elif normal == Vector3.LEFT:
			label.rotation = Vector3(0, -PI / 2, 0)
		elif normal == Vector3.BACK:
			pass
		elif normal == Vector3.FORWARD:
			label.rotation = Vector3(PI, 0, 0)

	return die


## The die's target rotation so face_value points at _camera — not
## just Vector3.UP, which only looks head-on to a camera that's
## directly overhead. Composes a camera-facing basis (whose own -Z
## points at the camera, roll fixed by world-up) with
## FACE_TO_FORWARD_EULER's fixed per-face correction, so the exact
## chosen face ends up where that -Z is, right numeral upright — see
## FACE_TO_FORWARD_EULER's own comment for the derivation.
func _face_toward_camera_euler(die: Node3D, face_value: int) -> Vector3:
	var to_camera: Vector3 = (_camera.position - die.position).normalized()
	var camera_facing: Basis = Basis.looking_at(to_camera, Vector3.UP)
	var face_correction: Basis = Basis.from_euler(FACE_TO_FORWARD_EULER[face_value])
	return (camera_facing * face_correction).get_euler()


func _on_dice_roll_requested(skill_name: String, roll: Dictionary) -> void:
	visible = true
	# Without this, a die sits at whatever rotation it was last left in
	# (identity on the very first roll ever) instead of presenting a
	# face square to the camera — identity in particular reads as
	# tilted, since the camera isn't positioned straight down any one
	# axis (see _build_scene()'s _camera.position).
	for i in 3:
		_dice[i].rotation = _face_toward_camera_euler(_dice[i], IDLE_FACE_VALUE)
	_result_label.text = "%s check" % skill_name
	_continue_button.text = "Roll"
	_continue_button.visible = true
	await _continue_button.pressed

	_continue_button.visible = false
	_result_label.text = "Rolling %s..." % skill_name

	var tweens: Array[Tween] = []
	for i in 3:
		var die: Node3D = _dice[i]
		var target_euler: Vector3 = _face_toward_camera_euler(die, roll.dice[i])
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
		tween.tween_property(die, "rotation", spun_euler, TUMBLE_DURATION + i * STAGGER_STEP) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tweens.append(tween)

	for tween in tweens:
		await tween.finished
	# Normalize off the extra full turns now that every die has landed.
	for i in 3:
		_dice[i].rotation = _face_toward_camera_euler(_dice[i], roll.dice[i])

	var verdict: String = "Failed"
	if roll.critical_success:
		verdict = "Critical success!"
	elif roll.critical_failure:
		verdict = "Critical failure!"
	elif roll.success:
		verdict = "Success"
	_result_label.text = "%s — %d vs %d" % [verdict, roll.roll, roll.target]

	_continue_button.text = "Continue"
	_continue_button.visible = true
	await _continue_button.pressed
	visible = false
	DialogueManager.dice_roll_finished.emit()
