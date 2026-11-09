class_name OverworldAvatar
extends CharacterBody3D
## One party group, drawn on the overworld — deliberately NOT a Unit:
## no nav-grid pathing, no turn budget, nothing that would make
## UnitQuery/SelectionManager pick it up. Direct WASD physics movement,
## relative to whatever the camera's current yaw is (see
## OverworldCamera.get_yaw()) so "forward" always means "away from the
## camera," the same convention any third-person camera-relative
## controller uses.
##
## Reuses the camera_pan_forward/backward/left/right actions (WASD) —
## those exist for crpg_camera.gd's own tactical free-pan, but that
## script only ever lives inside test_arena.tscn, which is freed before
## the overworld loads, so there's no real conflict repurposing the same
## keys here for a completely different job.
##
## The body itself never rotates toward its direction of travel — see
## SpinPivot below, whose motion instead reads the party leader's
## Law/Chaos alignment (PartyManager.leader_alignment()) — Law spins
## clockwise, Chaos counter-clockwise, both faster the more extreme the
## value; Neutral doesn't spin at all, it wobbles, more agitated the
## closer it sits to tipping one way. Movement direction and the spin are
## still intentionally decoupled: this is not a facing indicator, it's an
## alignment indicator.
##
## HANGING DECISION — control schema divergence: the overworld (this
## file) is WASD + walk-into-range-then-press-interact, JRPG-like, one
## avatar, unambiguous proximity. The in-level tactical party is
## click-to-move + right-click-a-verb, CRPG-like, four selectable units,
## proximity that ISN'T unambiguous. Both are correct for what they are —
## neither is being shoehorned into the other — but whether to eventually
## unify the movement/interaction vocabulary across the two is an open
## question, deliberately deferred, not scheduled. Nothing here should be
## built toward either outcome on spec. See interact_prompt.gd's own
## header for the interaction half of this same comparison.

## The group this avatar stands for. There is one avatar per group in
## the overworld, which is what lets a split party be somewhere at all
## rather than being collected the moment it arrives.
var group: PartyGroup = null

## Only the active avatar takes input. Without this every avatar reads
## the same WASD and the whole party walks in lockstep while pretending
## to be in different places.
var active: bool = false

## Full speed from the first frame a key is held, and dead still the
## frame it is let go: crossing the map is getting somewhere, not
## steering a body with weight, so there is no ramp up or down.
@export var move_speed: float = 6.0
@export var gravity: float = 18.0
## Anything up to this steep is ground the avatar walks on. The city's
## ramps are drawn far steeper than real ones, the way its roads are drawn
## far wider, so the avatar takes them as ground; the walls it must stop at
## (buildings, deck sides, rails) all stand near vertical.
@export_range(0.0, 89.0) var max_slope_degrees: float = 75.0

@export_group("Alignment Spin")
## Degrees/sec at the neutral threshold's own edge (extremity 0.0) for
## Law/Chaos — see UnitAlignment.ALIGNMENT_NEUTRAL_THRESHOLD, the value
## just past which a unit stops counting as Neutral at all.
@export var base_spin_degrees: float = 90.0
@export var mild_spin_scale: float = 0.8
@export var extreme_spin_scale: float = 2.0
## +1 spins Law clockwise viewed from above (Godot's rotate_y is
## otherwise counter-clockwise for a positive angle) — flip to -1 if it
## reads backwards against the actual camera framing.
@export var law_spin_sign: float = -1.0
@export var neutral_wobble_min_degrees: float = 90.0
@export var neutral_wobble_max_degrees: float = 180.0
## Radians/sec fed into sin() for the Neutral wobble — see this file's
## header on the ambiguous "0.005 * time" source spec; this assumes
## milliseconds (~5 rad/sec, a ~1.25s wobble period), tune freely.
@export var neutral_wobble_frequency: float = 5.0
## Draws the icon this many times larger, standing on the same feet. The
## body does not grow, so a big icon still fits down the streets; a map
## seen from far up sets it so the player can still be found.
@export var icon_scale: float = 1.0
## Seconds the icon takes to shrink down into a door it enters, SMT
## style, before the trip starts.
@export var enter_time: float = 0.8
## Seconds the door stands empty after the icon has gone, before the trip
## (and its fade to black) starts, so the eye sees it go.
const ENTER_HOLD := 0.15

@export_group("Alignment Color")
## The whole icon takes its leader's place on the alignment grid: Law to
## Chaos picks the hue (blue to red), Light to Dark its brightness (pale
## and warm to deep and violet). Nine colours, row by row from the top:
## Light Law, Light Neutral, Light Chaos, then Neutral, then Dark.
@export var grid_colors: Array[Color] = [
	Color(0.3, 0.72, 1.0), Color(1.0, 0.76, 0.18), Color(1.0, 0.42, 0.2),
	Color(0.1, 0.3, 0.92), Color(0.45, 0.52, 0.42), Color(0.82, 0.08, 0.05),
	Color(0.12, 0.06, 0.42), Color(0.2, 0.05, 0.28), Color(0.32, 0.0, 0.06),
]
## How fast the colour slides to a new alignment, per second; it fades
## rather than snapping when the leader changes.
@export var color_blend_rate: float = 3.0
## The edge glow's pulse: how deep it dips and how fast, for a leader
## near the centre of the grid and for one out at a corner.
@export var pulse_depth_mild: float = 0.25
@export var pulse_depth_extreme: float = 0.55
@export var pulse_rate_mild: float = 1.8
@export var pulse_rate_extreme: float = 3.6

## Set by overworld.gd right after instancing — the avatar reads this
## every physics frame to know which way "forward" currently means.
@export var camera: OverworldCamera

@onready var _spin_pivot: Node3D = $SpinPivot
var _pivot_height: float
var _view_scale := 1.0
## 1 standing, falling to 0 as the icon shrinks into a door; see enter().
var _shrink := 1.0
var _entering := false
@onready var _body: GeometryInstance3D = $SpinPivot/person_icon_v4/geometry_0
var _color := Color(-1, -1, -1)


func _physics_process(delta: float) -> void:
	# An inactive avatar still falls and still spins — it is standing
	# somewhere, not paused — it just is not being driven.
	var input_dir := Vector2.ZERO
	if not active or _entering:
		input_dir = Vector2.ZERO
	else:
		if Input.is_action_pressed("camera_pan_forward"):
			input_dir.y -= 1.0
		if Input.is_action_pressed("camera_pan_backward"):
			input_dir.y += 1.0
		if Input.is_action_pressed("camera_pan_left"):
			input_dir.x -= 1.0
		if Input.is_action_pressed("camera_pan_right"):
			input_dir.x += 1.0
	input_dir = input_dir.normalized()

	var yaw: float = camera.get_yaw() if camera else 0.0
	var basis := Basis(Vector3.UP, yaw)
	walk(basis * Vector3(input_dir.x, 0.0, input_dir.y), delta)

	# Written back every frame so the group remembers where it is
	# standing — the overworld is rebuilt from groups, not the other way
	# round, and a group that forgot its position would snap back to the
	# door it came in by.
	if group:
		group.overworld_position = global_position
	# Where the player is, for shaders that clear the view to them: the
	# city's bridge decks cut a hole round an avatar walking under one.
	if active:
		RenderingServer.global_shader_parameter_set(&"player_position", global_position)

	# enter() spins the icon itself on the way down.
	if not _entering:
		_apply_alignment_spin(delta)
	_apply_alignment_color(delta)


## One physics step of walking toward a flat direction (length 0 to 1),
## over whatever ground is underfoot. Split from the input reading so
## anything that drives the avatar along a route walks it the same way.
func walk(direction: Vector3, delta: float) -> void:
	velocity.x = direction.x * move_speed
	velocity.z = direction.z * move_speed

	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta

	# The ground can fall away by this much under one step down the
	# steepest slope it may be; snapping no less than that keeps the avatar
	# walking down a ramp instead of launching off its crest and falling.
	var step: float = Vector2(velocity.x, velocity.z).length() * delta
	floor_snap_length = maxf(0.1, step * tan(floor_max_angle) + 0.05)
	move_and_slide()


## Independent of movement/facing entirely — see this file's own header.
## Law/Chaos accumulate rotation (rotate_y, continuous); Neutral instead
## assigns rotation.y ABSOLUTELY each frame rather than accumulating a
## sine on top of it — accumulating would drift into a slow spin of its
## own instead of staying a true wobble around the origin.
##
## The Neutral wobble swings about the direction of the CAMERA rather than
## about the avatar's own zero. Without that, where the wobble sits
## depends on which way the player happens to have swung the camera: the
## indicator can rest on the far side of the capsule and swing behind it,
## so the one alignment that is supposed to read as "not committed either
## way" is the one you cannot see. Facing it at the viewer means the rest
## position is always the readable one and the swing is symmetric on
## screen.
##
## The Law/Chaos branch deliberately does NOT get this. It looks like it
## would be free — a constant offset added to something already spinning
## is invisible — but the offset is not constant: it tracks the camera,
## and the player can rotate the camera at 90 deg/sec, the same order as
## the spin itself. Adding it would make swinging the camera one way
## visibly stall the spin and the other way double it. A spin has no
## meaningful rest orientation to aim anywhere, so there is nothing to
## gain against that.
func _apply_alignment_spin(delta: float) -> void:
	var alignment: int = PartyManager.leader_alignment()
	var category: int = UnitAlignment.category_for(alignment)

	if category == 0:
		var extremity: float = clampf(absf(alignment) / float(UnitAlignment.ALIGNMENT_NEUTRAL_THRESHOLD), 0.0, 1.0)
		var amplitude_degrees: float = lerpf(neutral_wobble_min_degrees, neutral_wobble_max_degrees, extremity)
		var elapsed: float = Time.get_ticks_msec() / 1000.0
		var wobble: float = deg_to_rad(amplitude_degrees) * sin(elapsed * neutral_wobble_frequency)
		_spin_pivot.rotation.y = _yaw_facing_camera() + wobble
		return

	var threshold: float = float(UnitAlignment.ALIGNMENT_NEUTRAL_THRESHOLD)
	var full_scale: float = AlignmentGrid.DISPLAY_RANGE
	var extremity: float = clampf((absf(alignment) - threshold) / (full_scale - threshold), 0.0, 1.0)
	var speed_degrees: float = base_spin_degrees * lerpf(mild_spin_scale, extreme_spin_scale, extremity)
	var direction_sign: float = law_spin_sign if category > 0 else -law_spin_sign
	_spin_pivot.rotate_y(direction_sign * deg_to_rad(speed_degrees) * delta)


## Colours the icon by its leader's alignment, through per-instance shader
## parameters so two avatars of a split party each keep their own.
func _apply_alignment_color(delta: float) -> void:
	var alignment: int = PartyManager.leader_alignment()
	var tendency: int = PartyManager.leader_tendency()
	var column: int = 1 - UnitAlignment.category_for(alignment)
	var row: int = 1 - UnitAlignment.category_for(tendency)
	var target: Color = grid_colors[row * 3 + column]
	var extremity: float = maxf(_extremity(alignment), _extremity(tendency))
	if _color.r < 0.0:
		_color = target
	else:
		_color = _color.lerp(target, clampf(color_blend_rate * delta, 0.0, 1.0))
	_body.set_instance_shader_parameter(&"body_color", Vector3(_color.r, _color.g, _color.b))
	_body.set_instance_shader_parameter(&"pulse_depth", lerpf(pulse_depth_mild, pulse_depth_extreme, extremity))
	_body.set_instance_shader_parameter(&"pulse_rate", lerpf(pulse_rate_mild, pulse_rate_extreme, extremity))


## 0 at the neutral band's edge (or inside it), 1 at the end of the scale.
func _extremity(value: int) -> float:
	var threshold: float = float(UnitAlignment.ALIGNMENT_NEUTRAL_THRESHOLD)
	return clampf((absf(value) - threshold) / (AlignmentGrid.DISPLAY_RANGE - threshold), 0.0, 1.0)


## The SpinPivot yaw that points its +X at the camera, in the pivot's own
## parent space. +X because that is where the indicator bar actually is
## (IndicatorMesh sits at x=0.45 in overworld_avatar.tscn) — the pivot's
## -Z "forward" has nothing on it to look at.
##
## Worked out through to_local() rather than from world positions, so it
## stays correct if the avatar body is ever rotated by anything; today it
## never is (see this file's header). 0.0 with no camera assigned, which
## is the pre-overworld state and every headless test.
func _yaw_facing_camera() -> float:
	if not is_instance_valid(camera):
		return 0.0
	var local_camera: Vector3 = to_local(camera.global_position)
	# Rotating by t about Y sends local +X to (cos t, 0, -sin t), so
	# aiming it along (x, z) wants atan2(-z, x).
	return atan2(-local_camera.z, local_camera.x)


func _ready() -> void:
	# Clickable the same way a Unit is (see unit.gd) — picking is per
	# viewport and the world view already enables it.
	input_ray_pickable = true
	floor_max_angle = deg_to_rad(max_slope_degrees)
	# The same pace up a ramp as along the street; a slope is ground here,
	# not an obstacle that slows the walk.
	floor_constant_speed = true
	if not input_event.is_connected(_on_input_event):
		input_event.connect(_on_input_event)
	_pivot_height = _spin_pivot.position.y
	set_view_scale(1.0)


## Draws the icon f times larger again, on top of icon_scale, for a
## camera that has pulled f times farther away (the tactical view), so
## the avatar stays the same size on screen.
func set_view_scale(f: float) -> void:
	_view_scale = f
	_apply_icon_scale()


func _apply_icon_scale() -> void:
	var s := icon_scale * _view_scale
	# Shrunk toward its feet: the icon sinks into the ground it stands on.
	_spin_pivot.scale = Vector3.ONE * maxf(s * _shrink, 0.0001)
	_spin_pivot.position.y = _pivot_height * s * _shrink


## The classic SMT way into a place: the avatar slides onto the door and
## its icon shrinks away into it, spinning faster as it goes, and
## then_travel runs. Input is ignored meanwhile, so a held key does not
## walk it off the door.
func enter(at: Vector3, then_travel: Callable) -> void:
	if _entering:
		return
	_entering = true
	velocity = Vector3.ZERO
	var tween := create_tween().set_parallel().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	tween.tween_property(self, "global_position", Vector3(at.x, global_position.y, at.z), enter_time * 0.5) 		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	# Smaller every frame from the first: an overshoot (TRANS_BACK) spent
	# half the time growing and left the shrink itself a blink.
	tween.tween_method(_set_shrink, 1.0, 0.0, enter_time).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(_spin_pivot, "rotation:y", _spin_pivot.rotation.y + TAU * 1.5, enter_time) 		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.chain().tween_interval(ENTER_HOLD)
	tween.chain().tween_callback(then_travel)


## Standing at full size again, for an avatar still here after its trip
## did not happen.
func stand() -> void:
	_entering = false
	_set_shrink(1.0)


func _set_shrink(v: float) -> void:
	_shrink = v
	_apply_icon_scale()


## Clicking an avatar commands that group. The counterpart to clicking
## an absent companion's portrait (see unit_portrait._on_pressed), for
## the case where the people you want are not embodied and so have no
## portrait to click.
func _on_input_event(_camera: Node, event: InputEvent, _position: Vector3,
		_normal: Vector3, _shape_idx: int) -> void:
	if not event.is_action_pressed("left_click") or group == null:
		return
	PartyManager.active_group = group
	var overworld: Node = get_parent()
	if overworld and overworld.has_method("sync_avatars"):
		overworld.sync_avatars()
