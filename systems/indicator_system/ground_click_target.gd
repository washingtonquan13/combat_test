class_name ClickRouter
extends IndicatorBase
## The one owner of player intent — what a click means, and which
## indicators are live because of it.
##
## Kept as the node named GroundClickTarget in MainRoot.tscn because it
## already IS the in-world node clicks physically arrive at: one global
## node doing a centralized raycast (via IndicatorBase's
## _get_mouse_ground_point/_get_hovered_unit/_get_hovered_interactable),
## NOT a script attached to every ground collision body — the version
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


func _ready() -> void:
	super()
	add_to_group(&"click_router")

	# The router MUST apply the intent before any indicator's own _process
	# runs in the same frame, and by default it does the opposite.
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
	if _same_intent(now, _last):
		return
	_last = now
	_apply_intent(now)
	intent_changed.emit(now)


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


## Gate, build the hit ONCE, hand it to the intent, and mark the event
## handled only if the intent actually took it.
##
## Marking it handled is what lets Unit stop carrying its own physics-
## picked click handler: a handled event never reaches the viewport's
## physics picking pass at all. Not marking it when nothing happened is
## equally load-bearing — a click that commanded nobody still has to fall
## through to picking, which is how clicking an overworld avatar (its own
## input_event, not a Unit) keeps working.
func _unhandled_input(event: InputEvent) -> void:
	var is_left: bool = event.is_action_pressed("left_click")
	var is_right: bool = event.is_action_pressed("right_click")
	if not is_left and not is_right:
		if event.is_action_pressed("deselect_all") and CameraDirector.has_control():
			SelectionManager.deselect_all()
		return

	var current: PlayerIntent = intent()
	var hit := ClickHit.new()
	hit.ground = _get_mouse_ground_point()
	hit.unit = _get_hovered_unit()
	hit.interactable = _get_hovered_interactable()

	var consumed: bool = (
		current.handle_left_click(self, hit) if is_left
		else current.handle_right_click(self, hit))
	if consumed:
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
	# _get_hovered_unit() now honours pickability too (see IndicatorBase),
	# which is the same rule one step earlier; this is the one that has to
	# hold even if a caller builds a ClickHit some other way.
	if not is_instance_valid(clicked) or not clicked.is_alive():
		return false

	var acting_unit: Unit = PlayerInteractionState.get_active_unit()
	if acting_unit and acting_unit != clicked and acting_unit in SelectionManager.selected_units:
		var ability: Ability = clicked.click_ability_for(acting_unit)
		if ability:
			acting_unit.use_ability(ability, clicked)
			return true

	SelectionManager.select(clicked, Input.is_action_pressed("select_additive"))
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
	unit.use_ability(ability, ability.targeting.resolve_target_point(click_position))
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

	if movers.is_empty():
		return false

	if movers.size() == 1 and movers[0].in_combat():
		movers[0].move_to(destination)
		return true

	# Free-roam moves aren't gated by turn order the way combat is — every
	# selected unit can move at once — so all of them are excluded from
	# occupancy for this one update, not just a single mover (see
	# NavigationGrid). Simultaneous movers can still end up navigating
	# around each other's stale (pre-move) positions rather than truly
	# live positions until the next update — an accepted approximation
	# outside combat, where "only one unit ever moves at a time" doesn't
	# hold in the first place.
	NavigationGrid.update_occupancy(get_tree(), movers)

	# Leader/follower formation math lives on FormationPlanner, not here —
	# see that file for why it's leader-driven but fully deterministic.
	FormationPlanner.command_group_move(movers, destination)
	return true
