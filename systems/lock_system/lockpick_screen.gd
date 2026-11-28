class_name LockpickScreen
extends UIScreen
## The lockpicking minigame, after Fallout's: a lock drawn in its own
## little 3D world (a SubViewport with own_world_3d, its own camera and
## light) on a panel over the game. The game camera stays where it is and
## the world keeps running behind the panel.
##
## The rule is Fallout 3 / New Vegas's (the numbers are that game's
## iLockSweetSpotLength / iConcentricLength settings, on its 0..1000 arc):
##   - The pick points at the mouse: its angle is the cursor's direction
##     from the lock's centre on screen, clamped to the upper half, -90 to
##     90. The angle maps onto 0..PICK_RANGE.
##   - The lock hides a sweet spot. Its width comes from the lock's tier
##     (SWEET_LENGTH: 400 of the 1000 on a very easy lock, 25 on a very
##     hard one). Anywhere inside it the plug turns all the way.
##   - Past its edge the plug still turns, less the further out, down to
##     nothing CONCENTRIC beyond the edge, on every tier. How far the plug
##     gets is how close the pick is.
##   - Holding D (or the left mouse button) turns the plug. Turning it the
##     full 90 degrees opens the lock.
##   - A plug pushed against its limit strains the pick, which shakes,
##     louder and harder as it wears, and then snaps, using up one lock
##     pick: about the third full push in the wrong place, later in short
##     taps. How long it lasts comes from the tier and the picker's
##     Lockpicking over the tier's need (pick_life_for).
##   - Force Lock (F) rolls Lockpicking against the tier (Lock.force_target)
##     once: success opens it, failure jams it for good.
##   - Stepping away keeps nothing: the next try places a new sweet spot
##     and starts a fresh pick.
## Who may try at all is Lock.can_pick (the tier's skill need).
##
## Out of combat only. While it is up GameMode reports LOCKPICKING (it
## reads `active`), which takes world clicks and the camera away like a
## stash does. Escape stops; a fight starting in this world stops it too.

## The screen that is up, or null. Static so GameMode can ask without an
## autoload, the same as Terminal.active.
static var active: LockpickScreen = null

## The pick's travel: 1000 over the 180 degrees it can point, Fallout's
## own units.
const PICK_RANGE := 1000.0
## The plug's full turn: this far opens the lock.
const OPEN_ANGLE := 90.0
## Degrees per second the plug turns while held, and springs back after.
const TURN_SPEED := 180.0
const RETURN_SPEED := 360.0
## The sweet spot's full width on PICK_RANGE, by Lock.Tier.
const SWEET_LENGTH := [400.0, 200.0, 100.0, 50.0, 25.0]
## How far past the sweet spot's edge the plug still turns part way, on
## every tier.
const CONCENTRIC := 200.0
## Seconds a pick lasts pushed against the plug, by Lock.Tier, for a picker
## who just meets the tier's need. Each point over it adds PICK_LIFE_PER_POINT.
const PICK_LIFE := [1.6, 1.3, 1.0, 0.8, 0.6]
const PICK_LIFE_PER_POINT := 0.06
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
## Plays a tick each time the pick has moved this far along PICK_RANGE.
const TICK_EVERY := 40.0
## Seconds the panel stays up after a force jams the lock.
const JAM_HOLD := 0.9

const TICK_SOUND: AudioStream = preload("res://assets/audio/lock/pick_tick.wav")
const BIND_SOUND: AudioStream = preload("res://assets/audio/lock/bind.wav")
const STRAIN_SOUND: AudioStream = preload("res://assets/audio/lock/strain.wav")
const SNAP_SOUND: AudioStream = preload("res://assets/audio/lock/snap.wav")
const OPEN_SOUND: AudioStream = preload("res://assets/audio/lock/open.wav")
const JAM_SOUND: AudioStream = preload("res://assets/audio/lock/jam.wav")

var lock: Lock = null
var picker: Unit = null
## Where the sweet spot is on 0..PICK_RANGE. Placed once per sitting.
var sweet_spot := 0.0
## Whether by is in a state to work a lock: there, alive, standing, free to
## act and not fighting.
static func can_pick_now(by: Unit) -> bool:
	return is_instance_valid(by) and by.is_alive() and not by.is_downed() 			and not by.status_prevents_turn() and not by.in_combat()


## Half the sweet spot's width: inside this distance of sweet_spot the
## plug turns all the way.
var sweet_half := 50.0
## Seconds of strain the current pick has left, and a fresh one's.
var pick_life := 1.0
var pick_life_full := 1.0

## The pick's position on 0..PICK_RANGE, and the plug's turn in degrees
## (0 at rest, OPEN_ANGLE open).
var pick := PICK_RANGE * 0.5
var plug := 0.0
## True while the plug is pushed against its limit short of open.
var forcing := false
var opened := false
## A force failed: the panel is about to close.
var jammed := false

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
## Where the pick was at the last tick.
var _tick_at := 0.0
var _strain: AudioStreamPlayer = null
var _on_combat := _on_combat_started

var _view: SubViewportContainer = null
var _plug_node: Node3D = null
var _pick_node: Node3D = null
var _status: Label = null
var _force_button: Button = null


## Opens the screen on lock for picker. False, with the reason in the log,
## if it can't open now.
static func begin(on_lock: Lock, by: Unit) -> bool:
	if active != null or on_lock == null or not on_lock.locked or not can_pick_now(by) 			or not on_lock.can_pick(by):
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


## Seconds a pick lasts against a plug of tier for a picker margin points
## over its need.
static func pick_life_for(tier: int, margin: int) -> float:
	return PICK_LIFE[tier] * clampf(1.0 + PICK_LIFE_PER_POINT * margin, 0.7, 2.0)


## How far the plug can turn with the pick at `at`: all the way inside the
## sweet spot, falling off in a straight line to nothing CONCENTRIC past
## its edge.
func allowed_turn(at: float) -> float:
	var past := absf(at - sweet_spot) - sweet_half
	if past <= 0.0:
		return OPEN_ANGLE
	return OPEN_ANGLE * clampf(1.0 - past / CONCENTRIC, 0.0, 1.0)


## Takes the pick and the turn away from the mouse and keyboard.
func drive(at: float, turning: bool) -> void:
	_driven = true
	_driven_pick = clampf(at, 0.0, PICK_RANGE)
	_driven_turn = turning


func _setup(on_lock: Lock, by: Unit) -> void:
	lock = on_lock
	picker = by
	sweet_half = SWEET_LENGTH[lock.tier] * 0.5
	pick_life_full = pick_life_for(lock.tier, lock.skill_margin(picker))
	pick_life = pick_life_full
	_rng.randomize()
	# Wholly on the arc, so every spot can be found.
	sweet_spot = _rng.randf_range(sweet_half, PICK_RANGE - sweet_half)
	_tick_at = pick
	hides_hud = true
	blocks_input_below = true
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build_panel()
	visibility_changed.connect(func():
		if not visible:
			_finish())


func _process(delta: float) -> void:
	if active != self:
		return
	# One rule for every way the picker stops being able to pick: killed,
	# downed, stunned, pulled into a fight (started or joined), or anything
	# that outranks the screen (a cutscene, a conversation). It holds during
	# the beat after the lock opens or jams too.
	if not can_pick_now(picker) or GameMode.current_mode() != GameMode.Mode.LOCKPICKING:
		close()
		return
	if opened or jammed:
		return
	var turning := _read_turn()
	if _new_pick_in > 0.0:
		_new_pick_in -= delta
		turning = false
		_pick_node.visible = _new_pick_in <= 0.0
		if _pick_node.visible:
			_update_status()
	elif not turning:
		# The pick only moves while the plug is at rest, as in the original.
		var target := _read_pick()
		pick = target if _driven else lerpf(pick, target, 1.0 - exp(-PICK_FOLLOW * delta))
		if absf(pick - _tick_at) >= TICK_EVERY:
			_tick_at = pick
			_play(TICK_SOUND, -6.0)
	var limit := allowed_turn(pick)
	if turning:
		plug = minf(plug + TURN_SPEED * delta, limit)
	else:
		plug = maxf(plug - RETURN_SPEED * delta, 0.0)
	var was_forcing := forcing
	forcing = turning and plug >= limit and limit < OPEN_ANGLE
	if forcing and not was_forcing:
		_play(BIND_SOUND)
		_strain.play()
	elif was_forcing and not forcing:
		_strain.stop()
	if forcing:
		pick_life -= delta
		# The rattle gets louder as the pick gives.
		_strain.volume_db = lerpf(-14.0, -2.0, 1.0 - pick_life / pick_life_full)
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
	# A click on the Force button isn't a turn.
	var on_button := _force_button.get_global_rect().has_point(get_global_mouse_position())
	var held := Input.is_physical_key_pressed(KEY_D) \
			or (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not on_button)
	if not held:
		_turn_armed = true
	return held and _turn_armed


## Force Lock: one roll of Lockpicking against the tier. Success opens
## the lock; failure jams it, and only its key opens it after.
func force() -> void:
	if active != self or opened or jammed:
		return
	var roll := SuccessRoll.roll_vs(lock.force_target(picker), _rng)
	SystemLog.print("%s forces the lock. %s" % [LogFormat.unit_name(picker),
			DialogueFormat.skill_result(Lock.SKILL, roll)])
	if roll.success:
		_open_lock(true)
		return
	jammed = true
	forcing = false
	_strain.stop()
	lock.jam()
	_play(JAM_SOUND)
	SystemLog.print("The lock jams. Only its key will open it now.")
	_update_status("The lock jams.")
	_force_button.disabled = true
	get_tree().create_timer(JAM_HOLD).timeout.connect(func():
		if is_instance_valid(self):
			close())


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if active == self and key and key.pressed and not key.echo and key.physical_keycode == KEY_F:
		force()
		get_viewport().set_input_as_handled()


## A one-shot sound. It plays from the lock, not the panel, so closing the
## panel (the lock opening, a jam) doesn't cut it off.
func _play(stream: AudioStream, volume_db := 0.0) -> void:
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db
	lock.add_child(player)
	player.finished.connect(player.queue_free)
	player.play()


func _snap_pick() -> void:
	PartyManager.inventory.consume(Lock.LOCK_PICK)
	plug = 0.0
	forcing = false
	_strain.stop()
	_play(SNAP_SOUND)
	pick_life = pick_life_full
	# Let go before the next pick turns: a held key would otherwise spend
	# the whole stack in one press.
	_turn_armed = false
	if not PartyManager.inventory.has(Lock.LOCK_PICK):
		SystemLog.print("The pick snaps. That was the last one.")
		close()
		return
	SystemLog.print("The pick snaps.")
	_new_pick_in = NEW_PICK_DELAY
	_pick_node.visible = false
	# The HUD (and so the log) is hidden while the screen is up.
	_update_status("The pick snaps.")


## forced: opened by Force Lock, which logs its own line.
func _open_lock(forced := false) -> void:
	opened = true
	plug = OPEN_ANGLE
	forcing = false
	_strain.stop()
	_force_button.disabled = true
	_play(OPEN_SOUND)
	lock.unlock()
	if not forced:
		SystemLog.print("%s picks the lock." % LogFormat.unit_name(picker))
	_draw_lock()
	get_tree().create_timer(OPEN_HOLD).timeout.connect(func():
		# Closed meanwhile (a cutscene, a conversation): the stash stays shut.
		if not is_instance_valid(self) or active != self:
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
		# Shakes harder as the pick wears: a warning before it goes.
		var shake := lerpf(0.5, 2.0, 1.0 - pick_life / pick_life_full)
		_pick_node.position = Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), 0) * 0.008 * shake
		_pick_node.rotation.z += deg_to_rad(_rng.randf_range(-1.0, 1.0) * shake)
		_plug_node.rotation.z += deg_to_rad(_rng.randf_range(-1.0, 1.0) * shake)
	else:
		_pick_node.position = Vector3.ZERO


func _update_status(note: String = "") -> void:
	var picks := 0
	for item in PartyManager.inventory.items():
		if item.definition == Lock.LOCK_PICK:
			picks += item.count
	var need := "" if lock.required_skill() == 0 else " (needs %d)" % lock.required_skill()
	_status.text = "%s lock%s    Lockpicking %d    Lock picks: %d" % [lock.tier_name(), need,
			Lock.skill_of(picker), picks]
	if not note.is_empty():
		_status.text += "    " + note


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
	_force_button = Button.new()
	_force_button.text = "Force lock (F)  %d%%" % roundi(
			SuccessRoll.chances(lock.force_target(picker)).success * 100.0)
	_force_button.tooltip_text = "One roll of Lockpicking. Fail and the lock jams: only its key opens it after."
	_force_button.focus_mode = Control.FOCUS_NONE
	_force_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_force_button.pressed.connect(force)
	box.add_child(_force_button)
	_strain = AudioStreamPlayer.new()
	_strain.stream = STRAIN_SOUND
	add_child(_strain)
	var hint := Label.new()
	hint.text = "Point the mouse to set the pick. Hold D or the left button to turn. F forces it. Esc to stop."
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
