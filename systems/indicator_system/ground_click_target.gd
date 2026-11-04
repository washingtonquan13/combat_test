class_name ClickRouter
extends Node3D
## The one owner of player intent — what a click means, which indicators
## are live because of it — and of where the player is pointing.
##
## Each frame, in this order (see _process): derive the intent, resolve
## the ONE Cursor (the only mouse raycast and the only Ctrl read in the
## project), let the intent steer any held height drag, build the ONE Aim
## from that cursor, and hand it to every live indicator's draw(). Clicks
## take a cursor from the same resolve_cursor(). Indicators never raycast,
## read input or decide anything — they draw what they are given, so the
## preview and the click cannot disagree about where the cursor is.
##
## Kept as the node named GroundClickTarget in MainRoot.tscn because it
## already IS the in-world node clicks physically arrive at: one global
## node doing a centralized raycast, NOT a script attached to every ground collision body — the version
## before that extended StaticBody3D and relied on per-object physics
## picking, which meant it had to be attached individually to all five of
## the old main.tscn's ground/platform bodies. This needs to exist exactly
## once and works against any number of ground bodies for free as long as
## they are on ground_collision_mask.
##
## INTENT IS DERIVED, NEVER STORED — same shape as GameMode.current_mode(),
## for the same reason. intent() reads CameraDirector, the pushed stack
## and AbilityManager and returns the answer; _process compares this
## frame's answer to last frame's and emits intent_changed when it moved.
## Nothing anywhere assigns "the current intent", so nothing can disagree
## about it, and there is no state to get stuck in.
##
## What that replaced: eight places deciding what a click meant (this
## file's own left/right branches, Unit._on_input_event's physics-picked
## copy, the debug spawner's interceptor list) and seven indicators
## polling three singletons every frame to re-derive whether they were
## the one being aimed. Indicators are now TOLD, once, on change — see
## _apply_intent and IndicatorBase.serves().
##
## "Left-click"/"right-click"/"deselect_all" are InputMap actions (see
## project.godot > Input Map), not hardcoded button constants —
## rebinding any of them needs no code change.

signal intent_changed(intent: PlayerIntent)

## Heights dragged with Ctrl move in steps this big.
const HEIGHT_STEP: float = 0.25

## Pixels the mouse may travel between press and release and still be a
## click. Past it the gesture is a box select (DragSelectBox reads this
## same constant), so a box drag never also issues a move.
const CLICK_DRAG_THRESHOLD: float = 6.0

@export var ground_collision_mask: int = 1
## Unit pick areas only (Unit.PICK_LAYER, layer 20), not unit bodies.
@export_flags_3d_physics var unit_collision_mask: int = 1 << 19

## This frame's cursor and aim, as handed to the indicators. Read-only
## for anyone else (the nav debug overlay reads cursor); null before the
## first frame.
var cursor: Cursor = null
var aim: Aim = null

## The ground point a Ctrl height drag holds, or null when none does.
## Taken on the first frame of a drag, released the moment the drag is
## not one any more (Ctrl up, or an intent with no height to drag). Only
## resolve_cursor reads or writes it, so no indicator switching off
## mid-press can leave it stale.
var _held_ground = null

## A left press waiting for its release: the cursor and intent at press,
## and where it was pressed. Cleared on release, or once the mouse moves
## past CLICK_DRAG_THRESHOLD (then it is a box drag, not a click).
var _press_cursor: Cursor = null
var _press_intent: PlayerIntent = null
var _press_position: Vector2 = Vector2.ZERO

## Intents pushed by a tool that wants first refusal on clicks — right
## now only debug/spawning_intent.gd. A stack rather than a flag so
## nesting is at least well-defined, and PlayerIntent-typed so production
## code never names the debug tool that pushes one (the old
## intercept_clicks/release_clicks pair took bare Callables for the same
## reason; this replaces them).
##
## Registered in the &"click_router" group (see _ready) rather than as an
## autoload singleton, because this node already IS the one global click
## authority and already lives inside the world SubViewport where the
## click physically arrives — a tool that armed itself via its own
## _input() could not reliably beat or follow this node's _unhandled_input
## in tree order (autoloads sit before MainRoot, but the world
## SubViewportContainer forwards its click into the SubViewport's own
## synchronous input pass — ground picking included — before _input ever
## reaches further down the physical root tree), so claiming a click has
## to happen from inside that same pass instead.
var _pushed: Array[PlayerIntent] = []

## Reused rather than rebuilt each frame: these two carry no state, and
## intent() is called from _process. Aiming is cached per ability for the
## same reason — see intent().
var _idle: IdleIntent = IdleIntent.new()
var _locked: LockedIntent = LockedIntent.new()
var _aiming: AimingIntent = null

## Last intent handed to intent_changed. Null until the first _process,
## which is deliberate: the first comparison always differs, so the
## indicators get told what they are from the very first frame instead of
## staying dark until something happens to change. Cleared again on every
## world focus — see _on_world_focused.
var _last: PlayerIntent = null

## The look, sound and OS cursor of each decision this router makes. Built
## here rather than authored in MainRoot.tscn so it travels with the
## router between worlds and no scene has to remember to add it.
var _feedback: ClickFeedback = null


## What a left click would do right now, and whether it would be taken -
## the one answer both the context cursor (every frame) and the click
## feedback (on release) read, so the cursor never promises a click the
## router then refuses. Built by _answer from the same Cursor the click
## uses.
class ClickAnswer:
	## &"none" (no opinion: locked, a pushed tool, nothing under the
	## cursor), &"move", &"select", &"use" (an ability, at a unit or a
	## point), &"interact", &"nothing" (aiming at nothing - consumed, does
	## nothing).
	var verb: StringName = &"none"
	var ok: bool = true
	## Why not, when ok is false. Empty means the router has nothing
	## better than the generic line for the verb.
	var reason: String = ""
	## Where the feedback goes: the destination, the target's feet, the
	## aimed point. Null when there is no spot to mark.
	var point = null

	func _init(answer_verb: StringName = &"none", answer_point = null) -> void:
		verb = answer_verb
		point = answer_point

	func refused(why: String) -> ClickAnswer:
		ok = false
		reason = why
		return self


func _ready() -> void:
	add_to_group(&"click_router")

	# The router draws the indicators itself now, so for them frame order
	# no longer matters. It still runs first because the dev views that
	# keep their own _process (the nav overlay) read this frame's cursor,
	# and because of the history below.
	#
	# WorldManager._move_attention_to reparents the attention nodes into
	# the focused world's viewport in main_root.gd's declared order —
	# [Indicators, GroundClickTarget, CinematicCamera, DragSelectBox] — so
	# in-world tree order puts every indicator BEFORE this node, and Godot
	# calls _process in tree order. Each indicator therefore processed one
	# frame ahead of _apply_intent: on the frame an ability was armed or
	# swapped, an indicator that was still live from the previous intent
	# ran with the NEW armed ability in hand, which is a Nil access or a
	# failed typed assignment depending on the pair (hotbar swaps hit this
	# for real).
	#
	# Lower priority runs first. Fixing it here rather than by reordering
	# main_root.gd's array, because the array is about what the player's
	# attention follows between worlds and says nothing about frame order,
	# and the indicators' own defensive guards are a second line — not the
	# rule. Nothing else in the project sets process_priority, so -10 is
	# simply "before everyone".
	process_priority = -10

	# A world becoming focused is the one moment the applied state can be
	# stale without the intent having changed: this node and the
	# indicators are reparented into the arriving world, and an indicator
	# left live from world A keeps drawing at world-A coordinates in world
	# B until something happens to move the intent. Same hole catches an
	# indicator that joins the group after boot — it would stay dark
	# forever. Dropping the cache forces the next _process to re-apply
	# unconditionally.
	#
	# Connected for good, with no _exit_tree teardown: reparent() does
	# fire NOTIFICATION_EXIT_TREE, so disconnecting there would silently
	# unhook this on the FIRST world switch and never restore it (_ready
	# runs once). This node is reparented, never freed — it is a child of
	# MainRoot and _move_attention_to(null) returns it there — so the
	# connection can only outlive it if MainRoot itself is freed, and
	# Godot drops signal connections to a freed Object on its own.
	WorldManager.world_focused.connect(_on_world_focused)

	_feedback = ClickFeedback.new()
	_feedback.name = "ClickFeedback"
	add_child(_feedback)


## THE derivation. Priority, top down:
##
##   1. Locked, if something else owns the screen (CameraDirector.
##      has_control() — a conversation, negotiation, loot screen,
##      cutscene, open context menu, or the menus). Above the pushed
##      stack on purpose: a debug tool arming itself must not punch
##      through a live conversation either.
##   2. Whatever was pushed, most recent first.
##   3. Aiming, if AbilityManager has something armed.
##   4. Idle.
##
## No branch of this reads or writes a stored "current intent" — every
## call recomputes from the sources that already own each fact.
func intent() -> PlayerIntent:
	if not CameraDirector.has_control():
		return _locked
	if not _pushed.is_empty():
		return _pushed[_pushed.size() - 1]
	var armed: Ability = AbilityManager.armed_ability
	if armed == null:
		return _idle
	if _aiming == null or _aiming.ability != armed:
		_aiming = AimingIntent.new(armed)
	return _aiming


## Gives intent first refusal on every click this router sees, ahead of
## the ordinary aiming/move/interaction behaviour, until it is popped.
func push_intent(intent_to_push: PlayerIntent) -> void:
	if intent_to_push == null or _pushed.has(intent_to_push):
		return
	_pushed.push_back(intent_to_push)


## Silent no-op if it is not on the stack, so a double-release (disarm
## firing twice) cannot error.
func pop_intent(intent_to_pop: PlayerIntent) -> void:
	_pushed.erase(intent_to_pop)


## Forgets what was applied, without deciding anything: the next _process
## derives the intent fresh and applies it to whatever indicators are in
## the group NOW. Not _apply_intent() directly — this can fire mid-load,
## and intent() is only meaningful once the arriving world is the focused
## one.
func _on_world_focused(_world: Node) -> void:
	_last = null


func _process(_delta: float) -> void:
	var now: PlayerIntent = intent()
	if not _same_intent(now, _last):
		_last = now
		_apply_intent(now)
		intent_changed.emit(now)

	cursor = resolve_cursor(now)
	now.steer(self, cursor)
	aim = Aim.build(cursor, now)
	for indicator in get_tree().get_nodes_in_group(&"indicators"):
		if indicator.serves() != &"" and indicator.is_live():
			indicator.draw(aim)
	_feedback.show_cursor(_cursor_shape(now))


func _input(event: InputEvent) -> void:
	if event.is_action_released("fly_altitude_modifier"):
		_held_ground = null


## What the mouse is over right now, and the height drag if one is held.
## The only mouse raycasts in the project: the world past units (see
## _raycast_past_units), and the unit pick areas (_unit_under_mouse).
##
## The drag holds only while Ctrl is down AND the intent has a height to
## drag (PlayerIntent.drags_height) - Ctrl over anything else leaves the
## cursor free. Its first frame takes the ground under the mouse, or the
## active unit's own spot when the mouse is over nothing.
func resolve_cursor(current: PlayerIntent) -> Cursor:
	var result := Cursor.new()
	# The world under the mouse, looking THROUGH units: cursor.ground is the
	# floor (or prop) behind a unit, never a point on its capsule, so a
	# path or an area aimed past a unit lands where the player sees it.
	var ground_hit: Dictionary = _raycast_past_units(ground_collision_mask)
	var collider: Object = _pickable_collider(ground_hit)
	if collider is Node and not (collider is Unit) and collider.has_method("get_interactions"):
		result.interactable = collider
	var free_ground = null if ground_hit.is_empty() else ground_hit.position
	result.unit = _unit_under_mouse(ground_hit)
	if result.unit and result.unit.has_method("get_interactions"):
		result.interactable = result.unit

	var dragging: bool = (Input.is_action_pressed("fly_altitude_modifier")
		and current != null and current.drags_height(self))
	if not dragging:
		_held_ground = null
		result.ground = free_ground
		return result

	if _held_ground == null:
		var unit: Unit = active_unit()
		_held_ground = free_ground if free_ground != null else (unit.global_position if unit else null)
	result.ground = _held_ground
	if _held_ground != null:
		result.dragging_height = true
		result.height = _sample_height(Vector2(_held_ground.x, _held_ground.z))
	return result


## The unit indicators draw for - and null for one standing in a world
## the player is not looking at.
##
## That guard belongs HERE rather than in each indicator: indicators are
## carried between viewports as the player switches worlds (see
## WorldManager attention nodes), so without it a line of sight, a
## movement range or a jump arc drawn for somebody in another area keeps
## being drawn over the area now on screen - pointing at geometry that is
## not there.
static func active_unit() -> Unit:
	var unit: Unit = PlayerInteractionState.get_active_unit()
	if unit == null:
		return null
	var context: WorldContext = WorldManager.context()
	if context and not context.contains(unit):
		return null
	return unit


## One mouse ray against mask. Empty if nothing hit, or there is no
## active camera.
func _raycast(collision_mask: int, exclude: Array[RID] = [], areas_only: bool = false) -> Dictionary:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if not camera:
		return {}
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var from: Vector3 = camera.project_ray_origin(mouse_pos)
	var to: Vector3 = from + camera.project_ray_normal(mouse_pos) * 1000.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = collision_mask
	query.exclude = exclude
	if areas_only:
		query.collide_with_areas = true
		query.collide_with_bodies = false
	return get_world_3d().direct_space_state.intersect_ray(query)


## The first non-unit hit under the mouse. Units share the ground's
## physics layer (they collide with walls and each other on it), so the
## ray is re-cast past each unit it meets rather than masked; a handful of
## units stacked on one ray is the most this ever loops.
func _raycast_past_units(collision_mask: int) -> Dictionary:
	var exclude: Array[RID] = []
	for i in 8:
		var hit: Dictionary = _raycast(collision_mask, exclude)
		if hit.is_empty() or not (hit.collider is Unit):
			return hit
		exclude.append(hit.rid)
	return {}


## The unit the mouse is over, picked by its PickArea (Unit.PICK_LAYER, a
## cylinder the size of the selection ring) rather than its 0.25 m
## capsule, which made units a sliver to click. Only a unit nearer the
## camera than the world behind it counts, so walls still hide units, and
## only one that accepts clicks (Unit.set_pickable; off on death).
func _unit_under_mouse(world_hit: Dictionary) -> Unit:
	var hit: Dictionary = _raycast(unit_collision_mask, [], true)
	if hit.is_empty():
		return null
	var unit: Unit = Unit.from_pick_area(hit.collider)
	if unit == null or not unit.input_ray_pickable:
		return null
	if not world_hit.is_empty():
		var camera: Camera3D = get_viewport().get_camera_3d()
		var eye: Vector3 = camera.global_position
		if eye.distance_to(hit.position) > eye.distance_to(world_hit.position):
			return null
	return unit


## What a ray hit, but only if that body would have accepted a click.
##
## intersect_ray filters by collision LAYER and nothing else, while
## Godot's own physics picking (which used to deliver every click on a
## unit, before ClickRouter raycast for itself) additionally skips any
## CollisionObject3D with input_ray_pickable off. Honouring it here keeps
## hovering and clicking agreeing with each other AND with what picking
## did: unit_death.gd turns pickability off on death, so a corpse that
## still blocks movement - and so still carries its collision layer -
## stops being hoverable and clickable the way it always was.
##
## Anything that is not a CollisionObject3D is passed straight through:
## pickability is a property only that class has, and inventing an answer
## for other colliders would be a rule this function has no business
## making up.
func _pickable_collider(result: Dictionary) -> Object:
	if result.is_empty():
		return null
	var collider = result.get("collider")
	var body := collider as CollisionObject3D
	if body and not body.input_ray_pickable:
		return null
	return collider


## The height the mouse points at above anchor_xz: the camera ray through
## the mouse crossing a vertical wall through that point. The wall's
## normal is the camera's back vector flattened to horizontal (Y zeroed
## before normalizing) - flattening is what keeps it a true vertical wall
## whatever the camera's pitch, so only how high or low the ray crosses
## it matters; a tilted wall would couple sideways mouse movement into
## the height. Snapped to HEIGHT_STEP. Null with no camera, or with the
## ray near-parallel to the wall.
func _sample_height(anchor_xz: Vector2):
	var camera: Camera3D = get_viewport().get_camera_3d()
	if not camera:
		return null
	var back: Vector3 = camera.global_transform.basis.z
	var normal := Vector3(back.x, 0.0, back.z)
	if normal.length() < 0.001:
		return null
	var plane := Plane(normal.normalized(), Vector3(anchor_xz.x, 0.0, anchor_xz.y))
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var hit = plane.intersects_ray(camera.project_ray_origin(mouse_pos), camera.project_ray_normal(mouse_pos))
	if hit == null:
		return null
	return snappedf(hit.y, HEIGHT_STEP)


## By kind AND ability, never by object identity — a freshly built
## AimingIntent for the ability already being aimed is the same intent,
## and re-firing on it would make every listener re-do its work on a
## frame where nothing actually moved.
func _same_intent(a: PlayerIntent, b: PlayerIntent) -> bool:
	if a == null or b == null:
		return false
	return a.kind() == b.kind() and a.ability == b.ability


## Tells every intent-driven indicator whether it is currently the one.
## Indicators declaring serves() == &"" are skipped entirely: the sight
## cones and the nav overlay are development views with their own
## toggles, and the router has no business switching those off.
func _apply_intent(current: PlayerIntent) -> void:
	var live_ids: Array[StringName] = current.indicator_ids()
	for indicator in get_tree().get_nodes_in_group(&"indicators"):
		var id: StringName = indicator.serves()
		if id == &"":
			continue
		indicator.set_live(live_ids.has(id))


## Gate, resolve the cursor, hand it to the intent, and mark the event
## handled only if the intent actually took it.
##
## Resolved fresh rather than reusing this frame's cursor: input runs
## before _process, so the stored one is a frame old. Same function, so
## same answer as the preview the player is looking at.
##
## Marking it handled is what lets Unit stop carrying its own physics-
## picked click handler: a handled event never reaches the viewport's
## physics picking pass at all. Not marking it when nothing happened is
## equally load-bearing — a click that commanded nobody still has to fall
## through to picking, which is how clicking an overworld avatar (its own
## input_event, not a Unit) keeps working.
func _unhandled_input(event: InputEvent) -> void:
	# A left click is decided on RELEASE, so a press that turns into a box
	# drag never also commands anyone. The target is still taken at press
	# (what the player pressed on is what they meant), and the drag is
	# measured against the one CLICK_DRAG_THRESHOLD DragSelectBox uses too:
	# past it the gesture is a box, short of it a click, never both.
	if event.is_action_pressed("left_click"):
		_press_intent = intent()
		_press_cursor = resolve_cursor(_press_intent)
		_press_position = event.position if event is InputEventMouse else get_viewport().get_mouse_position()
		return
	if event is InputEventMouseMotion and _press_cursor != null:
		if _press_position.distance_to(event.position) >= CLICK_DRAG_THRESHOLD:
			_press_cursor = null
			_press_intent = null
		return
	if event.is_action_released("left_click"):
		var pressed: Cursor = _press_cursor
		var pressed_intent: PlayerIntent = _press_intent
		_press_cursor = null
		_press_intent = null
		if pressed == null:
			return
		# The intent could have moved between press and release (a hotbar
		# key, a turn ending); the click means what the screen showed when
		# it was pressed, unless that intent is gone from the stack.
		if pressed_intent != intent() and not (pressed_intent in _pushed):
			pressed_intent = intent()
		# Answered before the intent acts: acting changes the state the
		# answer reads (a move spends budget, a first line click sets
		# its start), and the feedback is for the click as it was made.
		var answer: ClickAnswer = _answer(pressed_intent, pressed)
		var consumed: bool = pressed_intent.handle_left_click(self, pressed)
		_give_feedback(answer, consumed)
		if consumed:
			get_viewport().set_input_as_handled()
		return

	if not event.is_action_pressed("right_click"):
		if event.is_action_pressed("deselect_all") and CameraDirector.has_control():
			SelectionManager.deselect_all()
		return

	var current: PlayerIntent = intent()
	if current.handle_right_click(self, resolve_cursor(current)):
		get_viewport().set_input_as_handled()


## Clicking a unit: use an ability against it if the acting unit has one
## that routes at it (see UnitCombat.resolve_click_ability — the armed
## ability first, otherwise the acting unit's default), otherwise select
## it, additively while select_additive is held.
##
## Ported verbatim off Unit._on_input_event, which is deleted. It never
## belonged on the unit: every unit in the world carried a copy of the
## player's targeting rules and its own guard about whether the player
## was even in control, and only ever ran because physics picking
## happened to reach it. Returns true always — a click on a unit is
## spoken for even when SelectionManager refuses it (it refuses anything
## not player-controlled), which is the same nothing that happened before.
func click_unit(clicked: Unit) -> bool:
	# A corpse is not a target and not a selection. Physics picking used
	# to enforce this for free — unit_death.gd sets input_ray_pickable =
	# false — but this router raycasts for itself, and intersect_ray
	# filters by collision LAYER only. A corpse with corpse_blocks_movement
	# keeps its layer, so without this it became clickable again the
	# moment picking stopped being the thing that delivered the click.
	# resolve_cursor honours pickability too (see _pickable_collider),
	# which is the same rule one step earlier; this is the one that has to
	# hold even if a caller builds a Cursor some other way.
	if not is_instance_valid(clicked) or not clicked.is_alive():
		return false

	var acting_unit: Unit = PlayerInteractionState.get_active_unit()
	var ability: Ability = _click_ability_on(clicked)
	if ability:
		acting_unit.use_ability(ability, clicked)
		return true

	var additive: bool = Input.is_action_pressed("select_additive")
	# In combat, a plain click on an ally who can't act right now must not
	# take the selection off the unit whose turn it is: that left the
	# player with nobody to command until they clicked back. Additive
	# clicks still build a group as before.
	if not additive and acting_unit and acting_unit != clicked \
			and acting_unit.in_combat() and not clicked.is_commandable():
		return true
	SelectionManager.select(clicked, additive)
	return true


## If ability expects a ground point as its target (Ability.targeting.
## expects_point_target — Jump, an AoE, any future point-targeting
## ability) and the player is actually commanding the caster, uses it at
## the clicked point. Returns whether it did.
func use_ground_targeted(ability: Ability, click_position: Vector3) -> bool:
	if not ability or not ability.targeting or not ability.targeting.expects_point_target():
		return false

	var unit: Unit = PlayerInteractionState.get_active_unit()
	if not unit or unit not in SelectionManager.selected_units:
		return false

	# click_position is always exactly where the physics ray hit the
	# ground, so it can never carry a lifted height on its own — letting
	# ability.targeting itself decide whether/how to adjust it (see
	# AbilityTargeting.resolve_target_point) instead of this router
	# knowing about specific subclasses like AerialAreaTargeting. Plain
	# AreaTargeting (Grease) and GroundPointTargeting (Jump) both inherit
	# the no-op default — floor-only abilities have no business picking
	# up a stray height override.
	var target = ability.targeting.resolve_click(unit, click_position)
	if target != null:
		unit.use_ability(ability, target)
	return true


## Moves whoever is selected and free to move. Returns whether anybody
## actually got an order — false leaves the click unconsumed, so a click
## that commanded nobody still falls through to physics picking.
##
## Gated per COMMANDED UNIT, not on whether a fight exists somewhere.
##
## This used to check the global CombatManager.in_combat and then permit
## only CombatManager.current_unit to move, which meant any running fight
## anywhere froze every other party member solid. A unit deliberately
## held out of a battle could not be walked anywhere — so ambushes,
## flanking and held reserves were impossible rather than merely fiddly,
## and DetectionManager's join-in-progress had nothing that could ever
## carry a straggler into range.
##
## Now: units in the fight obey turn order; units outside it move freely,
## even while it rages. Splitting selected units into the two groups
## rather than picking one lets a mixed selection do the sensible thing
## — the free ones go, the busy ones don't.
func command_move(destination: Vector3) -> bool:
	var movers: Array[Unit] = move_order_units()
	if movers.is_empty():
		return false

	if movers.size() == 1 and movers[0].in_combat():
		movers[0].move_to(destination)
		return true

	# Leader/follower formation math lives on FormationPlanner, not here —
	# see that file for why it's leader-driven but fully deterministic.
	FormationPlanner.command_group_move(movers, destination)
	return true


## Who a move order would go to: every selected, living unit, except that
## one in a fight moves only on its own turn with move left. Shared by
## command_move and _move_answer, so the cursor and the order agree.
static func move_order_units() -> Array[Unit]:
	var movers: Array[Unit] = []
	for unit in SelectionManager.selected_units:
		if not is_instance_valid(unit) or not unit.is_alive():
			continue
		if unit.in_combat():
			# Combat movement stays strictly one unit on its own turn.
			if unit.is_my_turn() and unit.has_move_remaining():
				movers.append(unit)
		else:
			movers.append(unit)
	return movers


## The ability a click on clicked would use, or null when the click would
## select it instead - click_unit's rule, and _answer's preview of it.
func _click_ability_on(clicked: Unit) -> Ability:
	var acting_unit: Unit = PlayerInteractionState.get_active_unit()
	if acting_unit and acting_unit != clicked and acting_unit in SelectionManager.selected_units:
		return clicked.click_ability_for(acting_unit)
	return null


## THE answer to "what would a left click do now" for current and at -
## see ClickAnswer. Follows the intents' own handle_left_click branches
## in their own order, and asks the same rules they act on (move_order_units,
## _click_ability_on, the ability's targeting check_click/check), so it
## can only be as wrong as those are. Pushed tools and the locked intent
## get no opinion: they own their clicks.
func _answer(current: PlayerIntent, at: Cursor) -> ClickAnswer:
	if at == null or current == null:
		return ClickAnswer.new()
	if current is IdleIntent:
		if at.unit:
			return _unit_answer(at.unit, false)
		if at.interactable:
			return ClickAnswer.new(&"interact")
		if at.ground == null:
			return ClickAnswer.new()
		return _move_answer(at.ground)
	if current is AimingIntent:
		var ability: Ability = current.ability
		if ability and ability.targeting and ability.targeting.expects_point_target():
			var p = at.aim_point(ability)
			var caster: Unit = PlayerInteractionState.get_active_unit()
			if p == null or caster == null or caster not in SelectionManager.selected_units:
				return ClickAnswer.new()
			var answer := ClickAnswer.new(&"use", ability.targeting.resolve_target_point(p))
			var reach: AbilityTargeting.Reach = ability.targeting.check_click(caster, p)
			if reach != AbilityTargeting.Reach.OK:
				answer.refused(_reach_reason(reach, false))
			return answer
		if at.unit:
			return _unit_answer(at.unit, true)
		if at.interactable:
			return ClickAnswer.new()
		return ClickAnswer.new(&"nothing", at.ground).refused("No target")
	return ClickAnswer.new()


## A click on a unit: an ability at it (in reach or not), else a
## selection. aiming says an ability is armed, so a unit the armed
## ability cannot take (a heal on a hostile) is a refusal rather than a
## quiet selection - the player meant to cast. A unit that is not the
## player's to select is interact (its right-click menu).
func _unit_answer(clicked: Unit, aiming: bool) -> ClickAnswer:
	if not is_instance_valid(clicked) or not clicked.is_alive():
		return ClickAnswer.new()
	var point: Vector3 = clicked.global_position
	var ability: Ability = _click_ability_on(clicked)
	if ability == null:
		if aiming:
			return ClickAnswer.new(&"use", point).refused("Invalid target")
		if clicked.is_player_controlled():
			return ClickAnswer.new(&"select", point)
		return ClickAnswer.new(&"interact", point)
	var answer := ClickAnswer.new(&"use", point)
	if ability.targeting:
		var reach: AbilityTargeting.Reach = ability.targeting.check(PlayerInteractionState.get_active_unit(), clicked)
		if reach != AbilityTargeting.Reach.OK:
			answer.refused(_reach_reason(reach, true))
	return answer


## A move order to destination. Nobody selected is no opinion (nothing
## would happen, and nothing should look refused). Somebody selected who
## cannot move is refused with why. A destination the commanded unit has
## no route to is refused too: command_move would still hand out the
## order, but the unit would not go anywhere. Beyond the move budget is
## fine - the move walks as far as it can, as the preview shows.
func _move_answer(destination: Vector3) -> ClickAnswer:
	if SelectionManager.selected_units.is_empty():
		return ClickAnswer.new()
	var answer := ClickAnswer.new(&"move", destination)
	var movers: Array[Unit] = move_order_units()
	if movers.is_empty():
		var acting: Unit = PlayerInteractionState.get_active_unit()
		if acting and acting.in_combat() and not acting.is_my_turn():
			return answer.refused("Not your turn")
		if acting and acting.in_combat() and not acting.has_move_remaining():
			return answer.refused("No movement left")
		return answer.refused("Can't move there")
	# The same route the movement preview draws this frame (its A* is
	# cached by cell, so asking again costs a walk, not a search).
	var unit: Unit = active_unit()
	if unit and unit in movers and unit.preview_route(destination, FormationPlanner.move_ignore(movers)).path.is_empty():
		return answer.refused("Can't move there")
	return answer


static func _reach_reason(reach: AbilityTargeting.Reach, at_unit: bool) -> String:
	match reach:
		AbilityTargeting.Reach.OUT_OF_RANGE:
			return "Out of reach"
		# Every shape that returns BLOCKED returns it for line of sight.
		AbilityTargeting.Reach.BLOCKED:
			return "No line of sight"
	return "Invalid target" if at_unit else "Can't target there"


## The feedback for a click, from the answer taken at release and whether
## the intent consumed it. A move is believed only if it was both
## answered ok and actually handed out (command_move returning false is a
## refusal whatever the answer said).
func _give_feedback(answer: ClickAnswer, consumed: bool) -> void:
	match answer.verb:
		&"move":
			if answer.ok and consumed:
				_feedback.confirm_move(answer.point)
			else:
				_feedback.refuse(answer.point, answer.reason if answer.reason != "" else "Can't move there")
		&"use":
			if answer.ok:
				_feedback.confirm()
			else:
				_feedback.refuse(answer.point, answer.reason if answer.reason != "" else "Out of reach")
		&"nothing":
			_feedback.refuse(answer.point, answer.reason)


## The OS cursor for this frame, from this frame's cursor and intent. The
## plain arrow whenever the router is not the one the mouse is talking
## to: something owns the screen (locked), a blocking screen is open, or
## the mouse is over UI. A refused answer is forbidden whatever the verb;
## the rest by verb. Moving keeps the arrow: it is the default action,
## and a hand or crosshair over every patch of floor would say nothing.
func _cursor_shape(current: PlayerIntent) -> Input.CursorShape:
	if current == _locked or not UIStack.can_open() or _mouse_over_gui():
		return Input.CURSOR_ARROW
	var answer: ClickAnswer = _answer(current, cursor)
	if not answer.ok:
		return Input.CURSOR_FORBIDDEN
	match answer.verb:
		&"use":
			return Input.CURSOR_CROSS
		&"interact":
			return Input.CURSOR_POINTING_HAND
	return Input.CURSOR_ARROW


## Whether the mouse is over a Control rather than the world. Clicks
## already know this for free - the GUI consumes them before
## _unhandled_input - but _process runs regardless, so the cursor asks.
## The world is drawn by a SubViewportContainer (world_view.tscn) that is
## itself the hovered Control while the mouse is over the world, so that
## one does not count; a Control inside the world's own viewport does.
func _mouse_over_gui() -> bool:
	var hovered: Control = get_tree().root.gui_get_hovered_control()
	if hovered != null and not (hovered is SubViewportContainer):
		return true
	var viewport: Viewport = get_viewport()
	return viewport != get_tree().root and viewport.gui_get_hovered_control() != null
