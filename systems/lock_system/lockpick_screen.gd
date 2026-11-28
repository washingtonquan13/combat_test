class_name LockpickScreen
extends UIScreen
## The lockpicking minigame, after Fallout's: a lock drawn in its own
## little 3D world (a SubViewport with own_world_3d, its own camera and
## light) on a panel over the game. The game camera stays where it is and
## the world keeps running behind the panel.
##
## The rule is adapted from Hexadotz's Lockpick-minigames (MIT,
## github.com/Hexadotz/Lockpick-minigames):
##   - The pick points at the mouse: its angle is the cursor's direction
##     from the lock's centre on screen, clamped to the upper half, -90 to
##     90. The angle maps onto 0..PICK_RANGE.
##   - The lock hides a sweet spot somewhere on that range.
##   - Holding D (or the left mouse button) turns the plug. How far it can
##     turn falls off with the pick's distance from the sweet spot: all
##     the way within the inner fifth of sweet_range, not at all past it.
##   - Turning it the full 90 degrees opens the lock.
## Added here: sweet_range comes from the picker's Lockpicking against the
## lock (sweet_range_for), and a plug pushed against its limit strains the
## pick, which shakes and then snaps, using up one lock pick.
##
## Out of combat only. While it is up GameMode reports LOCKPICKING (it
## reads `active`), which takes world clicks and the camera away like a
## stash does. Escape stops; a fight starting in this world stops it too.

## The screen that is up, or null. Static so GameMode can ask without an
## autoload, the same as Terminal.active.
static var active: LockpickScreen = null

## The pick's travel, in the units sweet_range is measured in.
const PICK_RANGE := 10.0
## The plug's full turn: this far opens the lock.
const OPEN_ANGLE := 90.0
## Degrees per second the plug turns while held, and springs back after.
const TURN_SPEED := 180.0
const RETURN_SPEED := 360.0
## The inner part of sweet_range, as a fraction of it, that turns all the
## way. Without one, only the exact centre would open.
const FULL_TURN_SHARE := 0.2
## Seconds a new pick takes to come in after one snaps.
const NEW_PICK_DELAY := 0.5
## Seconds the opened lock stays up before the panel closes.
const OPEN_HOLD := 0.4
const VIEW_SIZE := Vector2i(520, 420)
## How quickly the drawn pick catches up with the cursor (1/s): enough to
## take the stair-steps out of mouse motion without feeling like lag.
const PICK_FOLLOW := 40.0
## Inside this many pixels of the lock's centre the cursor's direction is
## too twitchy to steer by, so the pick stays where it was.
const DEAD_ZONE := 12.0

var lock: Lock = null
var picker: Unit = null
## Where the sweet spot is on 0..PICK_RANGE. Placed once per sitting.
var sweet_spot := 0.0
## Whether by is in a state to work a lock: there, alive, standing, free to
## act and not fighting.
static func can_pick_now(by: Unit) -> bool:
	return is_instance_valid(by) and by.is_alive() and not by.is_downed() 			and not by.status_prevents_turn() and not by.in_combat()


## How far from the sweet spot the plug still turns at all.
var sweet_range := 1.0
## Seconds of strain the current pick has left.
var pick_life := 1.0

## The pick's position on 0..PICK_RANGE, and the plug's turn in degrees
## (0 at rest, OPEN_ANGLE open).
var pick := PICK_RANGE * 0.5
var plug := 0.0
## True while the plug is pushed against its limit short of open.
var forcing := false
var opened := false

## Set by drive() (tests and demos): the pick and the turn come from here
## instead of the mouse and keyboard.
var _driven := false
var _driven_pick := 0.0
var _driven_turn := false
## The turn needs a fresh press: the click that picked "Pick lock" from the
## menu may still be held when the panel opens.
var _turn_armed := false
var _new_pick_in := 0.0
var _rng := RandomNumberGenerator.new()
var _on_combat := _on_combat_started

var _view: SubViewportContainer = null
var _plug_node: Node3D = null
var _pick_node: Node3D = null
var _status: Label = null


## Opens the screen on lock for picker. False, with the reason in the log,
## if it can't open now.
static func begin(on_lock: Lock, by: Unit) -> bool:
	if active != null or on_lock == null or not on_lock.locked or not can_pick_now(by):
		return false
	if not PartyManager.inventory.has(Lock.LOCK_PICK):
		SystemLog.print("No lock picks.")
		return false
	if GameMode.current_mode() != GameMode.Mode.EXPLORATION or not UIStack.can_open():
		SystemLog.print("Not now.")
		return false
	var layer := CanvasLayer.new()
	layer.name = "LockpickLayer"
	on_lock.add_child(layer)
	var screen := LockpickScreen.new()
	screen.name = "LockpickScreen"
	screen._setup(on_lock, by)
	layer.add_child(screen)
	active = screen
	if not CombatManager.combat_started.is_connected(screen._on_combat):
		CombatManager.combat_started.connect(screen._on_combat)
	screen.open()
	return true


## How far from the sweet spot the plug still turns, for an effective
## skill: 0.67 at 10, doubling every 5 points (Fallout's novice locks
## forgive a lot, its master locks a hair).
static func sweet_range_for(effective_skill: int) -> float:
	return clampf(0.67 * pow(2.0, (effective_skill - 10) / 5.0), 0.2, 2.0)


## Seconds a pick lasts pushed against the plug: longer for the skilled.
static func pick_life_for(effective_skill: int) -> float:
	return clampf(0.5 + 0.05 * effective_skill, 0.5, 2.0)


## How far the plug can turn with the pick at `at`: all the way near the
## sweet spot, falling to nothing at sweet_range from it.
func allowed_turn(at: float) -> float:
	var distance := absf(at - sweet_spot)
	var full := sweet_range * FULL_TURN_SHARE
	if distance <= full:
		return OPEN_ANGLE
	return OPEN_ANGLE * clampf(1.0 - (distance - full) / (sweet_range - full), 0.0, 1.0)


## Takes the pick and the turn away from the mouse and keyboard.
func drive(at: float, turning: bool) -> void:
	_driven = true
	_driven_pick = clampf(at, 0.0, PICK_RANGE)
	_driven_turn = turning


func _setup(on_lock: Lock, by: Unit) -> void:
	lock = on_lock
	picker = by
	var skill := lock.effective_skill(picker)
	sweet_range = sweet_range_for(skill)
	pick_life = pick_life_for(skill)
	_rng.randomize()
	sweet_spot = _rng.randf_range(0.0, PICK_RANGE)
	hides_hud = true
	blocks_input_below = true
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_panel()
	visibility_changed.connect(func():
		if not visible:
			_finish())


func _process(delta: float) -> void:
	if active != self or opened:
		return
	# One rule for every way the picker stops being able to pick: killed,
	# downed, stunned, pulled into a fight (started or joined), or anything
	# that outranks the screen (a cutscene, a conversation).
	if not can_pick_now(picker) or GameMode.current_mode() != GameMode.Mode.LOCKPICKING:
		close()
		return
	var turning := _read_turn()
	if _new_pick_in > 0.0:
		_new_pick_in -= delta
		turning = false
		_pick_node.visible = _new_pick_in <= 0.0
	elif not turning:
		# The pick only moves while the plug is at rest, as in the original.
		var target := _read_pick()
		pick = target if _driven else lerpf(pick, target, 1.0 - exp(-PICK_FOLLOW * delta))
	var limit := allowed_turn(pick)
	if turning:
		plug = minf(plug + TURN_SPEED * delta, limit)
	else:
		plug = maxf(plug - RETURN_SPEED * delta, 0.0)
	forcing = turning and plug >= limit and limit < OPEN_ANGLE
	if forcing:
		pick_life -= delta
		if pick_life <= 0.0:
			_snap_pick()
	if plug >= OPEN_ANGLE:
		_open_lock()
	_draw_lock()


func _read_pick() -> float:
	if _driven:
		return _driven_pick
	# The lock's camera looks straight down its axis, so the pivot is the
	# middle of the view on screen.
	var from := get_global_mouse_position() - _view.get_global_rect().get_center()
	if from.length() < DEAD_ZONE:
		return pick
	# The angle from straight up, + to the left (the pick's own rotation.z):
	# 90 points left (0 on the range), -90 right (PICK_RANGE). Below the
	# centre it pins to whichever side the cursor is on.
	var angle := clampf(rad_to_deg(atan2(-from.x, -from.y)), -90.0, 90.0)
	return (90.0 - angle) / 180.0 * PICK_RANGE


func _read_turn() -> bool:
	if _driven:
		return _driven_turn
	var held := Input.is_physical_key_pressed(KEY_D) or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if not held:
		_turn_armed = true
	return held and _turn_armed


func _snap_pick() -> void:
	PartyManager.inventory.consume(Lock.LOCK_PICK)
	plug = 0.0
	forcing = false
	pick_life = pick_life_for(lock.effective_skill(picker))
	if not PartyManager.inventory.has(Lock.LOCK_PICK):
		SystemLog.print("The pick snaps. That was the last one.")
		close()
		return
	SystemLog.print("The pick snaps.")
	_new_pick_in = NEW_PICK_DELAY
	_pick_node.visible = false
	# The HUD (and so the log) is hidden while the screen is up.
	_update_status("The pick snaps.")


func _open_lock() -> void:
	opened = true
	plug = OPEN_ANGLE
	lock.unlock()
	SystemLog.print("%s picks the lock." % LogFormat.unit_name(picker))
	_draw_lock()
	get_tree().create_timer(OPEN_HOLD).timeout.connect(func():
		if not is_instance_valid(self):
			return
		var stash := StashComponent.find_on(lock.get_parent())
		var by := picker
		close()
		# Fallout opens the container on the same press. The screen has
		# let go of input by now (close() -> _finish()).
		if stash and is_instance_valid(by):
			StashManager.open_stash(stash, by))


func _on_combat_started(turn_order: Array[Unit]) -> void:
	# Lock is a plain Node, so its world is the viewport's it sits in.
	if not turn_order.is_empty() and turn_order[0].get_world_3d() == lock.get_viewport().find_world_3d():
		close()


## Every way out ends here: Escape (UIStack popping the screen), a fight,
## the last pick, or the lock opening.
func _finish() -> void:
	if active == self:
		active = null
	if CombatManager.combat_started.is_connected(_on_combat):
		CombatManager.combat_started.disconnect(_on_combat)
	var layer := get_parent()
	if is_instance_valid(layer):
		layer.queue_free()


func _exit_tree() -> void:
	if active == self:
		active = null
		if UIStack.is_open(self):
			UIStack.pop(self)


func _draw_lock() -> void:
	_plug_node.rotation.z = -deg_to_rad(plug)
	_pick_node.rotation.z = deg_to_rad(90.0 - pick / PICK_RANGE * 180.0)
	if forcing:
		_pick_node.position = Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), 0) * 0.012
		_plug_node.rotation.z += deg_to_rad(_rng.randf_range(-1.5, 1.5))
	else:
		_pick_node.position = Vector3.ZERO


func _update_status(note: String = "") -> void:
	var picks := 0
	for item in PartyManager.inventory.items():
		if item.definition == Lock.LOCK_PICK:
			picks += item.count
	_status.text = "%s    Lockpicking %d    Lock picks: %d" % [_lock_rating(), lock.effective_skill(picker), picks]
	if not note.is_empty():
		_status.text += "    " + note


func _lock_rating() -> String:
	if lock.modifier >= 2:
		return "Easy lock"
	if lock.modifier >= -2:
		return "Average lock"
	if lock.modifier >= -6:
		return "Hard lock"
	return "Very hard lock"


# --- Building the panel and the lock's own little world ---

func _build_panel() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	var title := Label.new()
	title.text = lock.lock_name
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	_view = SubViewportContainer.new()
	_view.stretch = true
	_view.custom_minimum_size = VIEW_SIZE
	_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_view)
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_2X
	viewport.size = VIEW_SIZE
	_view.add_child(viewport)
	viewport.add_child(_build_lock_world())
	_status = Label.new()
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_status)
	var hint := Label.new()
	hint.text = "Point the mouse to set the pick. Hold D or the left button to turn. Esc to stop."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.modulate = Color(1, 1, 1, 0.6)
	box.add_child(hint)
	_update_status()


func _build_lock_world() -> Node3D:
	var root := Node3D.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.04, 0.04, 0.05)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.35, 0.35, 0.4)
	env.ambient_light_energy = 0.6
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	root.add_child(world_env)

	var camera := Camera3D.new()
	camera.position = Vector3(0, 0, 3.6)
	camera.fov = 40.0
	camera.current = true
	root.add_child(camera)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, 25, 0)
	key.light_energy = 1.3
	root.add_child(key)
	var fill := OmniLight3D.new()
	fill.position = Vector3(-1.2, 0.8, 1.6)
	fill.light_color = Color(1.0, 0.85, 0.65)
	fill.light_energy = 0.8
	fill.omni_range = 5.0
	root.add_child(fill)

	var brass := _material(Color(0.55, 0.42, 0.2), 0.85, 0.35)
	var dark_brass := _material(Color(0.4, 0.3, 0.15), 0.85, 0.45)
	var steel := _material(Color(0.62, 0.64, 0.68), 0.9, 0.3)
	var black := _material(Color(0.01, 0.01, 0.01), 0.0, 0.9)

	var body := _cylinder(0.95, 0.3, brass)
	body.position.z = -0.16
	root.add_child(body)

	_plug_node = Node3D.new()
	root.add_child(_plug_node)
	_plug_node.add_child(_cylinder(0.38, 0.06, dark_brass))
	var keyway := _box(Vector3(0.07, 0.42, 0.04), black)
	keyway.position = Vector3(0, -0.04, 0.02)
	_plug_node.add_child(keyway)
	# The tension wrench sits in the bottom of the keyway and turns with it.
	var wrench := _box(Vector3(0.05, 0.75, 0.02), steel)
	wrench.position = Vector3(0, -0.55, 0.07)
	_plug_node.add_child(wrench)
	var wrench_foot := _box(Vector3(0.6, 0.06, 0.02), steel)
	wrench_foot.position = Vector3(0.27, -0.9, 0.07)
	_plug_node.add_child(wrench_foot)

	_pick_node = Node3D.new()
	_pick_node.position = Vector3(0, 0, 0.1)
	var pivot := Node3D.new()
	pivot.position.z = 0.1
	root.add_child(pivot)
	pivot.add_child(_pick_node)
	var shaft := _box(Vector3(0.025, 1.05, 0.015), steel)
	shaft.position.y = 0.525
	_pick_node.add_child(shaft)
	var handle := _box(Vector3(0.08, 0.4, 0.03), _material(Color(0.2, 0.2, 0.22), 0.6, 0.5))
	handle.position.y = 1.2
	_pick_node.add_child(handle)
	_draw_lock_init()
	return root


## The nodes exist before the first _process, so the panel opens on the
## lock at rest rather than a frame of default transforms.
func _draw_lock_init() -> void:
	_plug_node.rotation.z = 0.0
	_pick_node.rotation.z = 0.0


func _material(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = metallic
	material.roughness = roughness
	return material


func _cylinder(radius: float, height: float, material: Material) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 48
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	# Cylinders stand on Y; the lock faces the camera down Z.
	node.rotation_degrees.x = 90.0
	return node


func _box(size: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	return node
