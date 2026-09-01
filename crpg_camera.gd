extends Camera3D
class_name CRPGCamera

## Classic CRPG-style orbit camera (Baldur's Gate 3 / Pillars of Eternity style).
##
## There is exactly one behavior model — orbit an anchor point, zoom toward/
## away from it, auto-pitch downward as you zoom out, rotate with Q/E. Bound
## and unbound modes differ in exactly one respect: where the anchor point
## comes from.
##
##   BOUND (focus_target assigned):
##     anchor = focus_target's position (+ focus_offset), plus a WASD pan
##     offset that's leashed within max_pan_radius of the target.
##
##   UNBOUND (focus_target is null):
##     anchor = a free point in space that WASD moves directly, with no
##     leash — otherwise every control (Q/E, WASD, scroll, auto-pitch,
##     look_at) behaves identically to bound mode.
##
## Controls (identical in both modes) — bound to InputMap actions (see
## project.godot > Input Map, or Project Settings in the editor) rather
## than hardcoded keys/buttons, so rebinding any of these needs no code
## changes:
##   camera_rotate_left / camera_rotate_right (Q / E) — yaw around the anchor
##   camera_pan_forward/backward/left/right (W A S D) — move the anchor
##     (leashed in bound, free in unbound)
##   camera_zoom_in / camera_zoom_out (scroll wheel)  — zoom toward/away
##     from the anchor (clamped to min_distance/max_distance in both modes)
##
## Pitch is never controlled directly — it's always derived from zoom
## distance via min_pitch/max_pitch, in both modes, exactly like bound
## mode always has been.
##
## Because yaw/pitch/distance/anchor are all continuous shared state, and
## focus_target's own setter converts the anchor's stored offset between
## "relative to a target" and "absolute position" at the exact moment of
## any transition (see that property's own doc comment), gaining, losing,
## or switching focus_target at runtime never jumps the anchor's position.
## look_at's own target is smoothed too (current_look_at_point, eased
## toward the true anchor every frame) rather than snapping to face a new
## anchor point instantly — position and rotation now ease together
## instead of position gliding while rotation whips to match.
##
## global_position eases toward a single desired_position every physics frame
## (the "swagger" lerp) — identical in both modes, since desired_position is
## built from the same distance/pitch/anchor smoothing pipeline either way.
##
## Also handled, both physics-driven rather than input-driven so they react
## regardless of what the player's actively doing: distance collision (see
## _required_distance_reduction/_update_distance_reduction — pulls the
## camera in rather than clipping through geometry) and, unbound mode only,
## height correction over uneven terrain (see _required_height_lift/
## _update_height_lift). Both are computed as small, disposable "how much
## correction right now" magnitudes eased toward 0 every frame, layered on
## top of the true player-driven distance/anchor rather than ever being
## written into them — see _smoothed_distance_reduction/_smoothed_height_
## lift's own header for why that split matters.
##
## Distance collision alone still gets uncomfortably close in a tight
## corner (it can only pull straight back along one fixed line, never
## find a less-cramped angle) — a lateral "dodge to the clearer side" fix
## was tried and worked, but got dropped: no real CRPG actually solves
## corners that way. What BG3 itself does instead is documented (see
## _apply_occlusion_fade's own header) — fading walls/ceilings transparent
## rather than repositioning the camera at all — and that's the intended
## real fix, not yet built.
##
## Written for Godot 4.x

enum Mode { BOUND, UNBOUND }

@export_group("Target")
## The node the camera orbits. Leave empty for free-roam (unbound) mode.
## A property with a setter, not a plain field, specifically so every
## transition (gaining a target, losing one, switching to a different
## one) keeps the anchor's WORLD POSITION continuous instead of jumping.
## current_anchor_offset means something different in each mode (see its
## own doc comment below): a small offset RELATIVE to focus_target in
## bound mode, but the anchor's ABSOLUTE position in unbound mode.
## Without this setter, losing focus would reinterpret whatever small
## pan offset was active as an absolute world position instead of
## converting it — teleporting the anchor to wherever that offset sits
## near the origin, rather than seamlessly staying exactly where it was
## already looking.
@export var focus_target: Node3D:
	set(value):
		if value == focus_target:
			return
		if value == null:
			# Losing focus: freeze the anchor's CURRENT world position
			# into current_anchor_offset itself, so unbound mode (which
			# reads it as an absolute position) picks up from exactly
			# where bound mode left off.
			var frozen: Vector3 = _get_anchor_point()
			current_anchor_offset = frozen
			target_anchor_offset = frozen
		elif focus_target == null:
			# Gaining focus from unbound: convert the absolute anchor
			# position into an offset relative to the new target, so
			# bound mode's leash math starts from the right place
			# instead of jumping to "no pan at all."
			var relative: Vector3 = current_anchor_offset - (value.global_position + focus_offset)
			current_anchor_offset = relative
			target_anchor_offset = relative
		else:
			# Switching between two different non-null targets: recenter
			# on the new one rather than carrying over however far the
			# player had panned from the old one. current_anchor_offset
			# still eases toward this via the existing lerp in
			# _physics_process — same smoothing any other pan gets.
			target_anchor_offset = Vector3.ZERO
		focus_target = value
## Offset applied to the focus target's position (e.g. raise anchor above
## the ground). Also applied in unbound mode to the ground-probed initial
## anchor (see _ready()) and to _required_height_lift's own probe, for
## the same reason: an anchor sitting exactly ON a collision surface,
## rather than above it, makes camera collision's own raycast immediately
## self-intersect that surface (confirmed bug — see
## _required_distance_reduction's header) and clamp to
## min_collision_distance every frame, regardless of any real obstruction.
@export var focus_offset: Vector3 = Vector3(0, 1, 0)
## How quickly the camera's actual position catches up to desired_position.
## This is the main source of the camera's "swagger" — identical in both modes.
@export var follow_smoothing: float = 10.0
## How quickly the camera's LOOK direction (what look_at aims at) catches
## up to the true anchor point — separate from follow_smoothing (which
## eases global_position) so a target change can't make the camera snap
## its facing instantly while its physical position is still gliding
## over. Same default so both ease at the same rate out of the box.
@export var look_smoothing: float = 10.0

@export_group("Rotation (Q/E)")
@export var rotation_speed: float = 90.0
@export var rotation_smoothing: float = 10.0

@export_group("Anchor Movement (WASD)")
## Speed the anchor point moves at when panning (bound) or roaming (unbound).
@export var move_speed: float = 12.0
## How quickly the anchor eases toward its input-driven target position.
@export var move_smoothing: float = 10.0
## Max horizontal distance (XZ plane) the anchor may stray from focus_target.
## Bound mode only — unbound mode's anchor is never leashed.
@export var max_pan_radius: float = 8.0
## How far above/below the anchor's current height to search for ground
## in free-roam (unbound) mode — see _required_height_lift. Bound mode
## doesn't use this: its anchor already tracks focus_target's own height
## directly, so uneven terrain is handled for free by just following
## whoever the camera is focused on.
@export var ground_probe_range: float = 20.0

@export_group("Zoom (Scroll)")
@export var zoom_speed: float = 10.0
@export var zoom_smoothing: float = 8.0
@export var min_distance: float = 5.0
@export var max_distance: float = 25.0

@export_group("Angle (Pitch) — tied to zoom, both modes")
## Downward pitch angle (degrees) when fully zoomed IN (close to the anchor).
@export var min_pitch: float = 30.0
## Downward pitch angle (degrees) when fully zoomed OUT (far from the anchor).
@export var max_pitch: float = 65.0
## Optional curve mapping zoom-in (0) to zoom-out (1) fraction to pitch interpolation.
@export var pitch_curve: Curve

@export_group("Collision")
## Physics layer(s) the camera avoids clipping through — matches this
## project's shared ground/geometry layer (see indicator_base.gd's own
## ground_collision_mask default). Units live on that same layer but are
## always excluded explicitly (see _required_distance_reduction) — the
## same "environment blocks, units don't" rule LineOfSight already
## establishes for line-of-sight raycasts (see that file's header): a
## party member or enemy walking near the sightline should never yank
## the camera around, only walls/terrain/props should.
@export var collision_mask: int = 1
## Radius of the sphere swept from the anchor toward the camera's ideal
## position (see _required_distance_reduction), rather than a zero-
## thickness ray — a plain ray can slip past a wall grazing the edge of
## the view (a corner, a doorway frame) since it only tests one exact
## line; a small sphere catches that because it has to keep this much
## clearance on every side, not just dead-center.
@export var collision_shape_radius: float = 0.3
## Additional clearance kept from a hit surface ON TOP OF
## collision_shape_radius — the camera stops this much further short of
## the wall than the bare non-overlap point, so its own near-clip plane
## doesn't still poke through at oblique angles.
@export var collision_margin: float = 0.4
## Absolute floor on how close collision is allowed to pull the camera,
## even in a tight corner where the raycast/shapecast math would
## otherwise put it nearer still (or, degenerately, negative).
@export var min_collision_distance: float = 1.0

@export_group("Collision Response")
## How quickly a NEW or worsening obstruction pulls the camera in (see
## _update_distance_reduction) or lifts its height (see
## _update_height_lift) — kept fast on purpose, so the camera never
## visibly clips even for a frame or two while catching up. Shared
## between both systems since they're the same underlying idea (react
## fast to a new problem, ease out of a solved one) — split into
## separate distance/height knobs later if they ever need to feel
## different from each other.
@export var response_in_speed: float = 20.0
## How quickly the camera eases back out once an obstruction clears —
## deliberately slower than response_in_speed by default, so release
## reads as a graceful settle rather than snapping straight back to
## full distance/height the instant something's no longer in the way.
@export var response_out_speed: float = 6.0

@export_group("Load Focus")
## How close global_position needs to get to desired_position before the
## initial on-load focus (see _on_world_loaded below) is considered
## "settled" and releases back to free-roam. Checked against the actual
## eased position, not the raw anchor/yaw/distance targets individually
## — global_position is where every one of those pipelines converges,
## so it's the one number that means "no longer visibly moving."
@export var load_focus_settle_distance: float = 0.5

# shared state (kept continuous across both modes so switching never snaps)
var current_yaw: float = 0.0        # degrees
var target_yaw: float = 0.0         # degrees
var current_pitch: float = 0.0      # degrees
var target_pitch: float = 0.0       # degrees
var current_distance: float
var target_distance: float

## Bound mode: offset from focus_target's position, leashed to max_pan_radius.
## Unbound mode: no target to offset from, so this IS the absolute anchor
## position in world space, and is never leashed.
var current_anchor_offset: Vector3 = Vector3.ZERO
var target_anchor_offset: Vector3 = Vector3.ZERO

## Where the camera should be right now, computed from the anchor/distance/
## pitch pipeline each physics frame. global_position eases toward this —
## see _physics_process. That one lerp is where all the "swagger" comes from.
var desired_position: Vector3 = Vector3.ZERO
## What look_at actually aims at — eased toward the true anchor point
## every physics frame (see look_smoothing), rather than look_at reading
## the anchor directly. Reading it directly would snap the camera's
## facing instantly on any focus_target change, even on frames where
## global_position is still gliding smoothly toward its own
## desired_position — position and rotation need the same kind of easing
## to actually look like one continuous motion instead of two mismatched ones.
var current_look_at_point: Vector3 = Vector3.ZERO
var _last_anchor_point: Vector3 = Vector3.ZERO   # cached for look_at, applied after the shared position lerp

## How much shorter than current_distance collision currently requires
## the camera to sit, and how much ABOVE current_anchor_offset.y the
## free-roam anchor currently needs lifting — both pure "magnitude of
## correction right now" values, always >= 0, eased every physics frame
## toward a freshly-computed target (see _update_distance_reduction/
## _update_height_lift) rather than ever being written back into
## current_distance/current_anchor_offset themselves. That distinction
## is load-bearing, not stylistic: an earlier version of height
## correction DID write directly into the anchor's persistent height,
## which meant it could only ever go up and had no way to tell "still
## needed" apart from "was needed once" — see _update_height_lift's own
## header for the full story. Naturally revert to 0 the moment they're
## no longer needed, since nothing ever mutates the value they're
## measured against.
var _smoothed_distance_reduction: float = 0.0
var _smoothed_height_lift: float = 0.0

## True from the moment _on_world_loaded below assigns focus_target to
## the leader until the camera visually settles on them (see
## load_focus_settle_distance) and releases back to free-roam. Checked
## every physics frame while true (see _physics_process); a no-op the
## rest of the time.
var _settling_load_focus: bool = false


func _get_mode() -> Mode:
	return Mode.BOUND if focus_target != null else Mode.UNBOUND


func _ready() -> void:
	CameraDirector.register_tactical_camera(self)
	CombatManager.turn_started.connect(_on_turn_started)
	CombatManager.combat_ended.connect(_on_combat_ended)
	# Fires once for THIS camera's own creation — a new CRPGCamera
	# instance is built fresh on every area load (see area .tscn files),
	# so by the time a DIFFERENT world_loaded could fire, this instance
	# already belongs to a torn-down world and the is_ancestor_of() guard
	# below skips it.
	WorldManager.world_loaded.connect(_on_world_loaded)

	target_distance = clamp((min_distance + max_distance) * 0.5, min_distance, max_distance)
	current_distance = target_distance
	target_pitch = _calculate_pitch_for_distance(current_distance)
	current_pitch = target_pitch

	if focus_target:
		var dir: Vector3 = global_position - (focus_target.global_position + focus_offset)
		target_yaw = rad_to_deg(atan2(dir.x, dir.z))
	else:
		target_yaw = rotation_degrees.y
		# No target to anchor to: place the initial anchor out in front of
		# wherever the camera starts, so it doesn't snap on the first frame.
		var yaw_rad: float = deg_to_rad(target_yaw)
		var pitch_rad: float = deg_to_rad(target_pitch)
		var forward: Vector3 = Vector3(
			-sin(yaw_rad) * cos(pitch_rad),
			-sin(pitch_rad),
			-cos(yaw_rad) * cos(pitch_rad)
		)
		# Raycast toward the ground first, rather than blindly projecting
		# by current_distance — confirmed bug: on this scene's authored
		# starting angle, a blind projection overshoots the floor and
		# lands the anchor underneath it, in open space below the map.
		# Harmless on its own (nothing used to care where the anchor
		# physically was), but camera collision (see
		# _required_distance_reduction) then faithfully finds "the floor,
		# hit from below, right in front of the anchor" and pulls the
		# camera down toward it — the reported "stuck in the void" bug.
		# Falls back to the old blind projection if the ray finds nothing
		# (e.g. the camera happens to be aimed at open sky).
		var probe_target: Vector3 = global_position + forward * current_distance
		var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
		var probe_query := PhysicsRayQueryParameters3D.create(global_position, probe_target)
		probe_query.collision_mask = collision_mask
		var probe_result: Dictionary = space_state.intersect_ray(probe_query)
		target_anchor_offset = (probe_result.position + focus_offset) if not probe_result.is_empty() else probe_target

	current_yaw = target_yaw
	current_anchor_offset = target_anchor_offset
	desired_position = global_position
	current_look_at_point = _get_anchor_point()


## Camera has never followed anyone up to now — focus_target simply
## started null and nothing ever assigned it, so the camera has run in
## permanent free-roam (UNBOUND) mode since before combat, flight, or
## ladders existed. Following whoever's turn it is is the highest-value
## default for TACTICAL play specifically — see focus_target's own
## setter for how this transition (and losing focus, below) stays
## seamless instead of snapping.
func _on_turn_started(unit: Unit) -> void:
	focus_target = unit


## Returns to free-roam once tactical play ends, rather than leaving the
## camera leashed (max_pan_radius) to whichever unit happened to act
## last — exploration/out-of-combat movement isn't yet wired to any
## per-unit follow target, so null (unbound) is the correct default here.
## focus_target's own setter freezes the anchor's current world position
## into current_anchor_offset the instant this fires, so the camera
## keeps looking at exactly the same point and simply stops following it
## — not a jump to wherever that offset would otherwise land.
func _on_combat_ended(_winning_faction: StringName) -> void:
	focus_target = null


## Every area load drops this camera in wherever its OWN .tscn happens
## to author its starting transform — with no relationship at all to
## wherever the party actually spawned, which reads as especially wrong
## after a save/load restores a leader position far from that default
## framing. Reuses the exact same focus_target pipeline
## _on_turn_started already drives for combat-follow: aim at the leader,
## let the existing anchor/yaw/distance easing carry the camera to them
## (the "swagger" glide, not a snap), then hand control back once
## _physics_process below detects it's actually arrived.
func _on_world_loaded(world: Node) -> void:
	if not world.is_ancestor_of(self):
		return
	if not PartyManager.leader:
		return
	focus_target = PartyManager.leader
	_settling_load_focus = true


## Bails without releasing if focus_target no longer points at the
## leader THIS settle started for — combat starting mid-glide (unlikely,
## since worlds only ever load out of combat, but not impossible if a
## fight is scripted to start immediately on entry) has already
## reassigned focus_target via _on_turn_started by then, and that
## follow now owns the camera; this must not clear it out from under
## that on the next frame's settle check.
func _update_load_focus() -> void:
	if focus_target != PartyManager.leader:
		_settling_load_focus = false
		return
	if global_position.distance_to(desired_position) <= load_focus_settle_distance:
		focus_target = null
		_settling_load_focus = false


func _unhandled_input(event: InputEvent) -> void:
	if not CameraDirector.has_control():
		return

	var scroll_up: bool = event.is_action_pressed("camera_zoom_in")
	var scroll_down: bool = event.is_action_pressed("camera_zoom_out")
	if not (scroll_up or scroll_down):
		return

	# Identical in both modes: zoom toward/away from the anchor, clamped.
	var step: float = zoom_speed * 0.1
	target_distance += (-step if scroll_up else step)
	target_distance = clamp(target_distance, min_distance, max_distance)


func _process(delta: float) -> void:
	if not CameraDirector.has_control():
		return

	_handle_rotation_input(delta)
	_handle_anchor_movement_input(delta)


func _physics_process(delta: float) -> void:
	# Yaw uses angle-aware lerping done correctly in radians (lerp_angle expects
	# radians; feeding it raw degrees causes rapid, incorrect wraparound).
	var yaw_rad: float = lerp_angle(deg_to_rad(current_yaw), deg_to_rad(target_yaw), 1.0 - exp(-rotation_smoothing * delta))
	current_yaw = rad_to_deg(yaw_rad)

	current_distance = lerp(current_distance, target_distance, 1.0 - exp(-zoom_smoothing * delta))

	target_pitch = _calculate_pitch_for_distance(current_distance)
	current_pitch = lerp(current_pitch, target_pitch, 1.0 - exp(-zoom_smoothing * delta))

	current_anchor_offset = current_anchor_offset.lerp(target_anchor_offset, 1.0 - exp(-move_smoothing * delta))
	_update_height_lift(delta)

	var anchor_point: Vector3 = _get_anchor_point()
	_last_anchor_point = anchor_point

	var pitch_rad: float = deg_to_rad(current_pitch)
	# Matches Godot's real forward convention (-Z at yaw 0, pitch 0).
	var forward: Vector3 = Vector3(
		-sin(yaw_rad) * cos(pitch_rad),
		-sin(pitch_rad),
		-cos(yaw_rad) * cos(pitch_rad)
	)

	_update_distance_reduction(anchor_point, forward, current_distance, delta)
	_apply_occlusion_fade(anchor_point, forward, current_distance)
	var collision_safe_distance: float = max(current_distance - _smoothed_distance_reduction, min_collision_distance)
	desired_position = anchor_point - (forward * collision_safe_distance)

	# Shared "swagger" step — identical lerp for both modes. desired_
	# position is already smooth by the time it gets here (both
	# _smoothed_distance_reduction and _smoothed_height_lift are eased
	# values, not raw per-frame results), so this lerp is a second,
	# general layer of smoothing on top — the collision/height response
	# has its own fast-in/slow-out character (see the Collision Response
	# export group), and this lerp gives it the same general "swagger"
	# every other camera movement already has, exactly like it already
	# eases toward every other change to anchor/zoom/rotation.
	global_position = global_position.lerp(desired_position, 1.0 - exp(-follow_smoothing * delta))

	# Eased toward the true anchor, same as global_position is eased
	# toward desired_position above — look_at()'ing anchor_point directly
	# would rotate the camera to face it instantly, snapping the view the
	# moment focus_target changes even while global_position is still
	# gliding smoothly toward the new anchor.
	current_look_at_point = current_look_at_point.lerp(anchor_point, 1.0 - exp(-look_smoothing * delta))
	look_at(current_look_at_point, Vector3.UP)

	# After the lerps above so this frame's freshly-updated
	# global_position/desired_position are what gets checked — settling
	# a frame late is harmless, checking against last frame's stale
	# values isn't.
	if _settling_load_focus:
		_update_load_focus()


## Bound mode: anchor = focus_target + offset + leashed pan offset.
## Unbound mode: anchor = the pan offset itself (never leashed), plus
## whatever height lift is currently active — see _smoothed_height_lift
## and _update_height_lift. Bound mode never adds lift: focus_target's
## own live position already IS the true height, in both directions.
func _get_anchor_point() -> Vector3:
	if focus_target:
		return focus_target.global_position + focus_offset + current_anchor_offset
	return current_anchor_offset + Vector3(0, _smoothed_height_lift, 0)


## Eases _smoothed_distance_reduction toward whatever
## _required_distance_reduction freshly computes this frame — fast when
## a NEW or worsening obstruction needs more pulled off (response_in_
## speed), slower when releasing back out as one clears (response_out_
## speed). See _smoothed_distance_reduction's own header for why this is
## a magnitude eased toward zero rather than an absolute value written
## into current_distance/target_distance directly.
func _update_distance_reduction(anchor_point: Vector3, forward: Vector3, distance: float, delta: float) -> void:
	var required: float = _required_distance_reduction(anchor_point, forward, distance)
	var response_speed: float = response_in_speed if required > _smoothed_distance_reduction else response_out_speed
	_smoothed_distance_reduction = lerp(_smoothed_distance_reduction, required, 1.0 - exp(-response_speed * delta))


## How much shorter than `distance` collision currently requires the
## camera to sit, or 0.0 if the path from `from` toward the camera's
## ideal position (from - forward*distance) is clear — the camera pulls
## IN toward the anchor to avoid clipping through geometry instead of
## phasing through it, same idea SpringArm3D uses for a third-person
## follow camera, just computed by hand here since this script already
## owns its own position pipeline rather than delegating to a node
## hierarchy.
##
## Swept as a small sphere (collision_shape_radius), not a bare ray —
## a zero-thickness ray can slip past a wall grazing the edge of the
## view (a corner, a doorway frame) since it only tests one exact line;
## a sphere has to keep that much clearance on every side. Units are
## gathered fresh and excluded every call — see this file's Collision
## export group for why.
func _required_distance_reduction(from: Vector3, forward: Vector3, distance: float) -> float:
	var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state

	var shape := SphereShape3D.new()
	shape.radius = collision_shape_radius

	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), from)
	query.motion = -forward * distance
	query.collision_mask = collision_mask

	# Global on purpose, and harmlessly so: this builds an EXCLUSION list
	# for a shape cast, and a unit in another world has no body in this
	# world's physics space to exclude. Excluding more than exists costs
	# nothing; excluding too few would let the camera collide with the
	# party, so the safe direction is the wide one.
	var excluded: Array = []
	for unit in UnitQuery.all_units(get_tree()):
		excluded.append(unit.get_rid())
	query.exclude = excluded

	var cast_result: PackedFloat32Array = space_state.cast_motion(query)
	# cast_motion does NOT return an empty array for "nothing in the
	# way" — confirmed via direct testing, contrary to how intersect_ray
	# behaves elsewhere in this file. A fully clear motion reports
	# safe_fraction 1.0 (a normal 2-element result), not emptiness; an
	# empty result specifically means the query itself couldn't run
	# (e.g. no space state available). Both need to bail out with no
	# reduction — treating a 1.0 safe_fraction as "found something" was
	# a real, confirmed bug: it applied collision_margin's subtraction
	# unconditionally, reporting a small phantom reduction even on a
	# completely open line.
	if cast_result.is_empty() or cast_result[0] >= 1.0:
		return 0.0

	var safe_fraction: float = cast_result[0]
	var safe_distance: float = max(safe_fraction * distance - collision_margin, min_collision_distance)
	return max(distance - safe_distance, 0.0)


## Occlusion fade hook — NOT YET IMPLEMENTED. This is the intended REAL
## fix for the "gets uncomfortably close in a tight corner" problem
## distance reduction alone has (see _required_distance_reduction's own
## header) — not by finding a cleverer camera position, but by not
## needing to: fade whatever's in the way transparent and leave the
## camera where it already was. Confirmed via direct research
## (2026-08-25) that this is what CRPGs with this camera style actually
## do — Larian has said BG3's camera dissolves walls/ceilings with a
## smooth opacity transition on entering a room and fades them back in
## on leaving, rather than repositioning the camera around them; older
## isometric CRPGs (Diablo-likes) use the same "fade what's between
## camera and character" idea for trees/walls. A lateral "dodge to
## whichever side has more room" alternative was tried here first and
## it DID work (headless-verified: recovered a fully-clear distance in a
## corner scenario that pure distance-reduction left stuck badly
## cramped) — dropped anyway, specifically because no real CRPG solves
## corners by repositioning the camera like that; fading the obstruction
## is the authentic technique and this hook exists so a future pass can
## build that instead.
##
## Left as a hook rather than built now: a real version needs its own
## tagging convention (a dedicated physics layer, or a group, marking
## which objects are fade-eligible vs. solid — walls/ceilings dissolve,
## solid terrain still gets real collision) and a dithered-transparency
## shader or material trick, and this project has no fadeable-prop
## content yet to build or verify either of those against. Called every
## physics frame with the same inputs _update_distance_reduction gets,
## so wiring a real implementation in later is a matter of filling this
## function in — no changes needed elsewhere in the pipeline.
func _apply_occlusion_fade(_from: Vector3, _forward: Vector3, _distance: float) -> void:
	pass


func _handle_rotation_input(delta: float) -> void:
	# Note: in Godot, increasing rotation_degrees.y turns the camera
	# counterclockwise (left) when viewed from above — the opposite of the
	# usual "E turns right" expectation. Q therefore increases yaw (turn
	# left) and E decreases it (turn right) to match that expectation.
	if Input.is_action_pressed("camera_rotate_left"):
		target_yaw += rotation_speed * delta
	if Input.is_action_pressed("camera_rotate_right"):
		target_yaw -= rotation_speed * delta


## Moves the anchor point with WASD, relative to the camera's current facing,
## flattened to the ground plane (yaw only — ignoring pitch keeps panning
## level instead of diving with the camera's tilt). In bound mode the result
## is leashed to max_pan_radius around focus_target; in unbound mode it's
## free, since target_anchor_offset IS the absolute anchor position there.
func _handle_anchor_movement_input(delta: float) -> void:
	var input_dir: Vector2 = _get_wasd_input()
	if input_dir == Vector2.ZERO:
		return

	var facing: Array = _get_flat_facing(current_yaw)
	var forward: Vector3 = facing[0]
	var right: Vector3 = facing[1]

	var move: Vector3 = (right * input_dir.x + forward * -input_dir.y) * move_speed * delta
	target_anchor_offset += move

	if _get_mode() == Mode.BOUND and target_anchor_offset.length() > max_pan_radius:
		target_anchor_offset = target_anchor_offset.normalized() * max_pan_radius


## Eases _smoothed_height_lift toward whatever _required_height_lift
## freshly computes this frame — same asymmetric fast-in/slow-out shape
## _update_distance_reduction uses, for the same reason. Bound mode
## doesn't need lift at all (focus_target's live height already tracks
## both up and down for free), so this just holds it at exactly 0 there
## rather than letting a stale value from a previous unbound stretch
## linger.
##
## This whole function — and the base/offset split it and
## _required_height_lift exist to preserve — replaces an earlier
## version that WROTE the required height directly into
## target_anchor_offset.y, permanently. That meant there was no
## separate "true" height left to revert to: once raised for a tall
## platform, it could only ever go up, never back down once you moved
## away, since the correction and the base it was correcting were the
## same variable. _collision_clamp_distance (now _required_distance_
## reduction) never had this problem — it already computed a fresh,
## disposable correction every frame instead of mutating current_
## distance/target_distance — height just hadn't been brought in line
## with that same pattern yet.
func _update_height_lift(delta: float) -> void:
	if _get_mode() == Mode.BOUND:
		_smoothed_height_lift = 0.0
		return

	var required: float = _required_height_lift()
	var response_speed: float = response_in_speed if required > _smoothed_height_lift else response_out_speed
	_smoothed_height_lift = lerp(_smoothed_height_lift, required, 1.0 - exp(-response_speed * delta))


## Free-roam only: how much ABOVE current_anchor_offset.y (the anchor's
## own, un-lifted height — never the already-lifted _get_anchor_point())
## the ground directly below actually requires right now, or 0.0 if the
## current height already clears it (or nothing is found within
## ground_probe_range). A pure "extra lift needed" magnitude, always
## >= 0 — never negative, since being above a surface by any amount is
## never itself a problem worth correcting (confirmed bug in an earlier
## version that DID treat "lower surface below" as something to snap
## down to — see _update_height_lift's own header for the fuller story).
func _required_height_lift() -> float:
	var base_y: float = current_anchor_offset.y
	var probe_top: Vector3 = Vector3(current_anchor_offset.x, base_y + ground_probe_range, current_anchor_offset.z)
	var probe_bottom: Vector3 = Vector3(current_anchor_offset.x, base_y - ground_probe_range, current_anchor_offset.z)

	var space_state: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(probe_top, probe_bottom)
	query.collision_mask = collision_mask
	var result: Dictionary = space_state.intersect_ray(query)
	if result.is_empty():
		return 0.0

	var required_y: float = result.position.y + focus_offset.y
	return max(required_y - base_y, 0.0)


## Ground-plane forward/right for a given yaw, ignoring pitch. Signs match
## Godot's actual camera basis at pitch 0 (forward = -Z, right = +X).
func _get_flat_facing(yaw_deg: float) -> Array:
	var yaw_rad: float = deg_to_rad(yaw_deg)
	var forward: Vector3 = Vector3(-sin(yaw_rad), 0.0, -cos(yaw_rad))
	var right: Vector3 = Vector3(cos(yaw_rad), 0.0, -sin(yaw_rad))
	return [forward, right]


func _get_wasd_input() -> Vector2:
	var input_dir: Vector2 = Vector2.ZERO
	if Input.is_action_pressed("camera_pan_forward"):
		input_dir.y -= 1.0
	if Input.is_action_pressed("camera_pan_backward"):
		input_dir.y += 1.0
	if Input.is_action_pressed("camera_pan_left"):
		input_dir.x -= 1.0
	if Input.is_action_pressed("camera_pan_right"):
		input_dir.x += 1.0
	return input_dir.normalized() if input_dir.length() > 0.0 else input_dir


## Maps the current zoom distance to a downward pitch angle. Used in both modes.
func _calculate_pitch_for_distance(distance: float) -> float:
	var t: float = inverse_lerp(min_distance, max_distance, distance)
	t = clamp(t, 0.0, 1.0)
	var curved: float = t
	if pitch_curve:
		curved = pitch_curve.sample(t)
	return lerp(min_pitch, max_pitch, curved)
