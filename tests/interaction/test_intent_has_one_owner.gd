extends AiTestCase
## Player intent has exactly one owner.
##
## "What does this click mean" used to be answered in eight places, and
## seven indicators polled three singletons every frame to reconstruct
## the answer for themselves. This suite pins the replacement down:
## ClickRouter DERIVES one PlayerIntent from state that already exists
## (nothing stores "the current intent", exactly like GameMode), and the
## indicators are TOLD which of them is live rather than each deciding.
##
## The checks are shaped to fail loudly if that collapses back:
##
## - the derivation is asked for directly (intent()), never inferred from
##   a side effect, so a stored copy that drifts cannot pass;
## - the live-indicator set is asserted as a SET and asserted to CHANGE
##   as different abilities are armed. "Some indicator is live" would
##   pass against an indicator that never turns off, which is the exact
##   failure this work exists to end — see the sabotage notes in the
##   report and [[sabotage-checks-caught-two-false-greens]];
## - dark means dark: an indicator switched off must also stop DRAWING,
##   asserted by forcing a mesh visible first and watching it go away.
##   is_processing() alone would pass on a stopped indicator that left a
##   line hanging in the world;
## - intent_changed is counted, not merely observed. Re-deriving the same
##   intent must not re-fire, or every listener re-does its work forever;
## - and the intents are asked to actually COMMAND something. An earlier
##   draft of this suite asserted only bookkeeping — stubbing every
##   handle_left_click to `return false` passed all of it. The behaviour
##   half below spawns real units in the fixture world and asserts the
##   SIGNAL the click produced (ability_use_started), never the bool.
##
## Frame order is its own claim, checked with real awaited frames rather
## than the hand-driven _process the bookkeeping half uses. In the real
## tree the indicators sit BEFORE the router (WorldManager reparents
## main_root.gd's attention list in order), so without
## ClickRouter's process_priority they would each run a frame ahead of
## the intent that governs them — reading an ability that is no longer
## theirs. _the_router_runs_before_the_indicators_it_drives mirrors that
## tree order deliberately and watches who moves first.
##
## wants_world(): true. The router is an attention node reparented into
## the world by WorldManager, it raycasts against the world's own physics
## space, and CameraDirector.has_control() reads the focused world's base
## mode — none of which mean anything against a bare floor.
##
## The two source-reading checks at the end are the only way to assert a
## DELETION: that a unit no longer decides what a click on it means, and
## no longer carries its own private guard about whether the player is in
## control. Same pattern as tests/cinematic's _death_is_ungated.

const ROUTER_SCRIPT: GDScript = preload("res://systems/indicator_system/ground_click_target.gd")
const PLAYER_INTENT_SCRIPT: GDScript = preload("res://systems/interaction_system/player_intent.gd")
const CLICK_HIT_SCRIPT: GDScript = preload("res://systems/interaction_system/click_hit.gd")

const INDICATOR_PATHS: Dictionary = {
	&"movement": "res://systems/indicator_system/movement_indicator.gd",
	&"area": "res://systems/indicator_system/area_indicator.gd",
	&"aerial_area": "res://systems/indicator_system/aerial_area_indicator.gd",
	&"jump": "res://systems/indicator_system/jump_indicator.gd",
	&"line_of_sight": "res://systems/indicator_system/line_of_sight_indicator.gd",
	&"seeking": "res://systems/indicator_system/seeking_indicator.gd",
	&"aim_facing": "res://systems/unit_system/unit_aim_facing.gd",
}

## An indicator that records nothing but WHEN it ran, sharing one log
## with the router. Extends the real IndicatorBase, so it joins the
## &"indicators" group, stands down on _ready and is switched by
## set_live exactly like a real one.
class OrderProbe extends IndicatorBase:
	## Shared with the test, and appended to from the router's
	## intent_changed as well — an Array so both sides see the same
	## object (a lambda would capture a primitive by value).
	var order_log: Array = []

	func serves() -> StringName:
		return &"probe_order"

	func _process(_delta: float) -> void:
		order_log.append(&"indicator")


## Names the probe and nothing else, so pushing it lights exactly one
## indicator and popping it darkens exactly one.
class ProbeIntent extends PlayerIntent:
	func kind() -> StringName:
		return &"probe"

	func indicator_ids() -> Array[StringName]:
		return [&"probe_order"]


## Records the clicks the router hands it through the REAL
## _unhandled_input path.
class RecordingIntent extends PlayerIntent:
	var lefts: Array = []

	func kind() -> StringName:
		return &"recording"

	func handle_left_click(_router, hit: ClickHit) -> bool:
		lefts.append(hit)
		return true


var _router: Node3D = null
var _indicators: Dictionary = {}
## Array, not a bare int: a lambda captures primitives by value, so a
## counter incremented inside a signal handler has to live in a container
## to be readable out here at all.
var _fired: Array = []


func wants_world() -> bool:
	return true


func run() -> void:
	_stand_up_the_router()
	if _router == null:
		return

	_nothing_armed_is_idle()
	_arming_derives_aiming()
	_the_live_indicator_set_follows_the_ability()
	_disarming_returns_to_idle()
	_a_pushed_intent_outranks_aiming()
	_losing_the_screen_locks_everything()
	_the_debug_spawner_pushes_one_too()
	await _clicks_actually_command_the_world()
	await _the_router_runs_before_the_indicators_it_drives()
	_a_unit_no_longer_owns_its_own_click()

	_pack_up()


func _stand_up_the_router() -> void:
	# Indicators FIRST, router second — the same order WorldManager
	# reparents main_root.gd's attention list into a focused world, and
	# therefore the order Godot would call _process in if nothing said
	# otherwise. Building the suite the other way round would quietly
	# test an arrangement the game never has.
	for id in INDICATOR_PATHS:
		var node := Node3D.new()
		node.set_script(load(INDICATOR_PATHS[id]) as GDScript)
		_spawn_parent().add_child(node)
		_indicators[id] = node

	_router = Node3D.new()
	_router.set_script(ROUTER_SCRIPT)
	_spawn_parent().add_child(_router)
	# Driven by hand for the bookkeeping half: leaving the engine to call
	# _process too would make the intent_changed COUNT non-deterministic,
	# and the count is part of what this suite asserts. Handed back to the
	# engine for the frame-order half at the end.
	_router.set_process(false)
	_router.intent_changed.connect(func(i): _fired.append(i))

	check("the router registers itself as the one click router",
		get_tree().get_first_node_in_group(&"click_router") == _router,
		"nothing (or something else) is in the click_router group — the "
			+ "debug spawner and every future tool find it by that group")

	var latest_indicator: int = 0
	for id in _indicators:
		latest_indicator = maxi(latest_indicator, _indicators[id].process_priority)
	check("the router is scheduled ahead of every indicator it drives",
		_router.process_priority < latest_indicator,
		"router priority %d, latest indicator %d — it sits AFTER them in "
			% [_router.process_priority, latest_indicator]
			+ "the tree, so without a lower priority they process a frame "
			+ "ahead of the intent that governs them")

	var declared: Array = []
	for id in _indicators:
		if _indicators[id].serves() == id:
			declared.append(id)
	check("every indicator declares the id it answers to",
		declared.size() == _indicators.size(),
		"only %d of %d matched: %s" % [declared.size(), _indicators.size(), declared])

	check("an indicator stands down until the router says otherwise",
		_live_ids().is_empty(),
		"live before the router ever ran: %s" % [_live_ids()])

	# The precondition every other check leans on. If the harness world
	# were not one the player is commanding, everything below would be
	# Locked and would pass for the wrong reason.
	check("the harness world is one the player has control of",
		CameraDirector.has_control(),
		"has_control() is false in the fixture — mode is %d"
			% GameMode.current_mode())


func _nothing_armed_is_idle() -> void:
	AbilityManager.disarm()
	check("with nothing armed and nothing pushed, the intent is idle",
		_router.intent().kind() == &"idle",
		"got %s" % _router.intent().describe())
	check("and an idle intent is aiming no ability",
		_router.intent().ability == null)

	_fired.clear()
	_router._process(0.0)
	check("the first frame tells the indicators what they are",
		_fired.size() == 1 and _fired[0].kind() == &"idle",
		"fired %d times" % _fired.size())
	check("idle means the path preview and nothing else",
		_live_ids() == ["movement"],
		"live: %s" % [_live_ids()])


func _arming_derives_aiming() -> void:
	var grease: Ability = load("res://data/abilities/grease.tres")
	_fired.clear()
	AbilityManager.arm(grease)

	var derived: PlayerIntent = _router.intent()
	check("arming an ability derives an aiming intent",
		derived.kind() == &"aiming",
		"got %s" % derived.describe())
	check("and the intent carries the ability being aimed",
		derived.ability == grease,
		"carries %s" % derived.ability)
	check("deriving twice is the same intent, not a new one every call",
		_router.intent() == derived,
		"intent() minted a second object for the same armed ability")

	_router._process(0.0)
	check("changing intent fires intent_changed exactly once",
		_fired.size() == 1 and _fired[0].kind() == &"aiming",
		"fired %d times" % _fired.size())

	_router._process(0.0)
	_router._process(0.0)
	check("and re-deriving the SAME intent does not fire again",
		_fired.size() == 1,
		"fired %d times across three frames with nothing changing"
			% _fired.size())


## The heart of it: which overlays are live comes from the ability, and
## it CHANGES when a different ability is armed. Each of these five is a
## guard that used to live inside an indicator, asking about itself.
func _the_live_indicator_set_follows_the_ability() -> void:
	_arm_and_apply(load("res://data/abilities/grease.tres"))
	check("an area ability lights the area ring and the facing overlay",
		_live_ids() == ["aim_facing", "area"],
		"live: %s" % [_live_ids()])

	# Force something on in an indicator that is about to be switched
	# off, so "went dark" is a real observation rather than an indicator
	# that was never drawing in the first place.
	_indicators[&"area"]._owned_meshes[0].visible = true

	_arm_and_apply(load("res://data/abilities/basic_attack_ranged.tres"))
	check("a ranged ability swaps the area ring for the line of sight",
		_live_ids() == ["aim_facing", "line_of_sight"],
		"live: %s" % [_live_ids()])
	check("and the overlay it switched off actually stopped drawing",
		not _indicators[&"area"].is_showing_anything(),
		"the area indicator is still showing a ring it no longer owns")

	_arm_and_apply(load("res://data/abilities/magic_missile.tres"))
	check("a seeking ability takes the route preview INSTEAD of the aim line",
		_live_ids() == ["aim_facing", "seeking"],
		"live: %s — a pathed projectile must not also light line_of_sight"
			% [_live_ids()])

	_arm_and_apply(load("res://data/abilities/jump.tres"))
	check("a ground-point ability that moves its caster draws the arc",
		_live_ids() == ["aim_facing", "jump"],
		"live: %s" % [_live_ids()])

	_arm_and_apply(load("res://data/abilities/explosive_fireball.tres"))
	check("an aerial area ability takes the aerial rings, not the flat one",
		_live_ids() == ["aerial_area", "aim_facing"],
		"live: %s — AerialAreaTargeting extends AreaTargeting, so lighting "
			% [_live_ids()] + "both is the bug this replaced")

	check("no ability ever leaves the movement preview live",
		not _indicators[&"movement"].is_processing(),
		"a click while armed casts rather than walks")


func _disarming_returns_to_idle() -> void:
	_fired.clear()
	AbilityManager.disarm()
	check("disarming returns the intent to idle",
		_router.intent().kind() == &"idle")

	_router._process(0.0)
	check("and fires intent_changed exactly once on the way back",
		_fired.size() == 1 and _fired[0].kind() == &"idle",
		"fired %d times" % _fired.size())
	check("the path preview comes back and the aiming overlays go away",
		_live_ids() == ["movement"],
		"live: %s" % [_live_ids()])


## A tool that wants the next click says so by pushing an intent — the
## debug spawner is the only one today, and production code never names
## it. Pushed beats armed.
func _a_pushed_intent_outranks_aiming() -> void:
	_arm_and_apply(load("res://data/abilities/grease.tres"))
	check("precondition: aiming before anything is pushed",
		_router.intent().kind() == &"aiming")

	var pushed: PlayerIntent = PLAYER_INTENT_SCRIPT.new()
	_fired.clear()
	_router.push_intent(pushed)
	check("a pushed intent outranks the armed ability",
		_router.intent() == pushed,
		"got %s" % _router.intent().describe())

	_router._process(0.0)
	check("pushing one is a change, so it fires",
		_fired.size() == 1,
		"fired %d times" % _fired.size())
	check("and an intent naming no indicators darkens all of them",
		_live_ids().is_empty(),
		"live: %s" % [_live_ids()])

	_router.pop_intent(pushed)
	_router._process(0.0)
	check("popping it hands the click back to the armed ability",
		_router.intent().kind() == &"aiming"
			and _live_ids() == ["aim_facing", "area"],
		"intent %s, live %s" % [_router.intent().describe(), _live_ids()])

	_router.pop_intent(pushed)
	check("popping something that is not on the stack is a quiet no-op",
		_router.intent().kind() == &"aiming")


## Something else owning the screen is derived from CameraDirector.
## has_control(), not from a second copy of the same list — and it wins
## over everything, armed abilities included.
func _losing_the_screen_locks_everything() -> void:
	var saved: DialogueNode = DialogueManager.current_node
	DialogueManager.current_node = DialogueNode.new()

	check("precondition: the screen really was taken",
		not CameraDirector.has_control())
	check("losing control locks the intent, armed ability or not",
		_router.intent().kind() == &"locked",
		"got %s" % _router.intent().describe())

	var hit: ClickHit = CLICK_HIT_SCRIPT.new()
	hit.ground = Vector3.ZERO
	check("a locked intent consumes no left click",
		not _router.intent().handle_left_click(_router, hit),
		"it claimed the click, which would swallow it from the UI that "
			+ "actually owns the screen")
	check("and no right click either",
		not _router.intent().handle_right_click(_router, hit))

	_router._process(0.0)
	check("and nothing is drawn over a world the player is not commanding",
		_live_ids().is_empty(),
		"live: %s" % [_live_ids()])

	DialogueManager.current_node = saved
	_router._process(0.0)
	check("handing the screen back restores the aiming overlays",
		_router.intent().kind() == &"aiming"
			and _live_ids() == ["aim_facing", "area"],
		"intent %s, live %s" % [_router.intent().describe(), _live_ids()])

	AbilityManager.disarm()
	_router._process(0.0)


## The only real consumer of push_intent today, checked through its own
## public API rather than by pushing a hand-made stand-in: this is the
## seam that used to be a Callable interceptor list, and DebugSpawner is
## what proves the replacement is actually reachable from outside
## systems/.
func _the_debug_spawner_pushes_one_too() -> void:
	AbilityManager.disarm()
	_router._process(0.0)

	DebugSpawner.arm(_harness_definition(), &"enemy")
	check("arming the debug spawner pushes a spawning intent",
		_router.intent().kind() == &"spawning",
		"got %s" % _router.intent().describe())

	_router._process(0.0)
	check("and a debug placement draws no ability overlays",
		_live_ids().is_empty(),
		"live: %s" % [_live_ids()])

	DebugSpawner.disarm()
	check("disarming it pops the intent back off",
		_router.intent().kind() == &"idle",
		"got %s — a tool that pushes and does not pop swallows every click "
			% _router.intent().describe() + "for the rest of the session")

	DebugSpawner.arm(_harness_definition(), &"enemy")
	DebugSpawner.arm(_harness_definition(), &"player")
	DebugSpawner.disarm()
	check("re-arming while armed leaves nothing behind on the stack",
		_router.intent().kind() == &"idle",
		"got %s" % _router.intent().describe())

	_router._process(0.0)


## The half that would not exist if bookkeeping were enough. An earlier
## draft of this suite passed in full with every intent stubbed to
## `return false` — it proved the router derived and published an intent,
## and nothing at all about that intent COMMANDING anything.
##
## So: real units, in the fixture world, and the assertion is the signal
## the click produced. ability_use_started rather than the returned bool,
## because the bool is the thing a stub can fake and the signal is the
## thing only a real ability use emits (UnitCombat.use_ability emits it
## once every precondition has passed, before the to-hit roll and before
## any await, so it lands synchronously here).
##
## No awaits between the cases, on purpose: use_ability suspends part-way
## through, and letting a frame pass mid-section would let case (a)'s
## attack escalate into a real fight — which would put the party member
## off their own turn and quietly make every later precondition false.
func _clicks_actually_command_the_world() -> void:
	AbilityManager.disarm()
	_router._process(0.0)

	var player: Unit = spawn_unit(&"player", 16, 12, 30, [melee()], Vector3.ZERO)
	# Deliberately unkillable for the length of this section: a target
	# that died to case (a) would make cases (c) and (d) test something
	# else entirely.
	var hostile: Unit = spawn_unit(&"enemy", 10, 10, 9999, [melee()], Vector3(1.0, 0.0, 0.0))
	SelectionManager.select(player)

	var started: Array = []
	player.ability_use_started.connect(func(_a, _t, ability): started.append(ability))

	check("SETUP: the spawned party member is the one being commanded",
		PlayerInteractionState.get_active_unit() == player,
		"nothing is commandable, so every click below would be a no-op for "
			+ "the wrong reason")
	check("SETUP: nothing is armed, so the intent is idle",
		_router.intent().kind() == &"idle")

	# (a) a click on a hostile ATTACKS it.
	var consumed: bool = _router.intent().handle_left_click(_router, _hit_on(hostile))
	check("clicking a hostile actually uses an ability on it",
		started.size() == 1 and started[0] == player.default_ability(),
		"ability_use_started fired %d times %s — the click was routed and "
			% [started.size(), started] + "nothing happened")
	check("and that click is consumed, so it never reaches physics picking",
		consumed,
		"an unconsumed click on a unit falls through and gets handled twice")

	# (b) a click that commands nobody must NOT be consumed. This is the
	# fall-through that keeps a click on the overworld avatar — physics-
	# picked, and not a Unit — working at all.
	SelectionManager.deselect_all()
	started.clear()
	var empty_ground: ClickHit = CLICK_HIT_SCRIPT.new()
	empty_ground.ground = Vector3(4.0, 0.0, 4.0)
	check("a ground click with nobody selected is refused, not swallowed",
		not _router.intent().handle_left_click(_router, empty_ground),
		"consuming it marks the event handled, and anything downstream "
			+ "that relies on physics picking stops responding")

	# (c) a corpse is not a target. Physics picking enforced this for free
	# (unit_death.gd drops input_ray_pickable); the router raycasts for
	# itself, and intersect_ray filters by collision LAYER only — which a
	# corpse with corpse_blocks_movement still has.
	SelectionManager.select(player)
	started.clear()
	var corpse: Unit = spawn_unit(&"enemy", 10, 10, 20, [melee()], Vector3(1.0, 0.0, 1.0))
	corpse.current_hp = 0
	corpse.input_ray_pickable = false
	check("a click on a dead unit is refused",
		not _router.intent().handle_left_click(_router, _hit_on(corpse)),
		"a corpse is selectable and attackable again")
	check("and nothing was used against it",
		started.is_empty(),
		"used %s on a corpse" % [started])

	# (d) with an ability armed, the ARMED one is what fires — not the
	# unit's default. Shove is deliberately not in the caster's own
	# ability list, so the two are distinguishable.
	#
	# A SECOND party member does the casting, because the first one is
	# still mid-swing: case (a)'s use_ability is suspended inside its own
	# coroutine until a frame passes, which is exactly what can_act()
	# reports as busy — and a busy unit is refused before ability_use_
	# started is ever reached. Waiting the frame out instead would let
	# that attack turn into a fight (see this function's header).
	SelectionManager.deselect_all()
	var caster: Unit = spawn_unit(&"player", 16, 12, 30, [melee()], Vector3(0.0, 0.0, 1.0))
	SelectionManager.select(caster)
	var cast_by_caster: Array = []
	caster.ability_use_started.connect(func(_a, _t, ability): cast_by_caster.append(ability))

	var armed: Ability = load("res://data/abilities/shove.tres")
	check("SETUP: the armed ability is not the caster's own default",
		armed != caster.default_ability())
	check("SETUP: the caster is the one being commanded",
		PlayerInteractionState.get_active_unit() == caster)
	AbilityManager.arm(armed)
	_router._process(0.0)
	var aiming: PlayerIntent = _router.intent()
	check("SETUP: arming derives an aiming intent",
		aiming.kind() == &"aiming")
	var aimed_click: bool = aiming.handle_left_click(_router, _hit_on(hostile))
	check("clicking a hostile while aiming uses the ARMED ability",
		cast_by_caster.size() == 1 and cast_by_caster[0] == armed,
		"fired %s, expected %s" % [cast_by_caster, armed.ability_name])
	check("and that click is consumed too", aimed_click)

	AbilityManager.disarm()
	SelectionManager.deselect_all()
	_router._process(0.0)

	# Only now: let the suspended use_ability coroutines finish, put any
	# fight they started back down, and take the units away.
	await get_tree().process_frame
	await get_tree().process_frame
	if CombatManager.focused_encounter:
		CombatManager.end_combat(&"")
	await get_tree().process_frame
	free_spawned()
	await get_tree().process_frame


## A ClickHit shaped the way the router builds one for a unit under the
## cursor: a Unit is an interactable too (it implements get_interactions),
## so both fields are set, exactly as the shared raycast would set them.
func _hit_on(unit: Unit) -> ClickHit:
	var hit: ClickHit = CLICK_HIT_SCRIPT.new()
	hit.unit = unit
	hit.interactable = unit
	hit.ground = unit.global_position
	return hit


## Everything above drives _process by hand. This hands the router back
## to the engine and checks the things only real frames can show.
func _the_router_runs_before_the_indicators_it_drives() -> void:
	_router.set_process(true)

	# --- the real input path, end to end ---------------------------------
	#
	# Pushed through the viewport rather than by calling _unhandled_input
	# directly: push_input clears the handled flag first and then runs the
	# viewport's whole pipeline, so "the router claimed it" is observable
	# afterwards rather than assumed.
	var recorder := RecordingIntent.new()
	_router.push_intent(recorder)
	await get_tree().process_frame
	await get_tree().process_frame

	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	_router.get_viewport().push_input(press)

	check("a real left press reaches the current intent through the "
			+ "router's own _unhandled_input",
		recorder.lefts.size() == 1,
		"the intent was handed %d clicks — the gate, the derivation or "
			% recorder.lefts.size() + "the dispatch is not on the real path")
	if recorder.lefts.size() == 1:
		check("and it is handed one hit the router built, not a raw event",
			recorder.lefts[0] is ClickHit)
	check("a claimed click is marked handled, so physics picking never "
			+ "sees it",
		_router.get_viewport().is_input_handled(),
		"an unhandled click still reaches per-object picking, which is the "
			+ "second click owner this work deleted")

	_router.pop_intent(recorder)

	# --- who moves first -------------------------------------------------
	#
	# The probe sits before the router in the tree, like every real
	# indicator does (see _stand_up_the_router), and both it and the
	# router write into one shared log. On the frame the intent moves, the
	# router has to be the first entry: an indicator that runs first is an
	# indicator reading an ability that is no longer the one it serves,
	# which is a Nil access or a failed cast depending on the pair.
	var probe := OrderProbe.new()
	_spawn_parent().add_child(probe)
	_spawn_parent().move_child(probe, 0)
	_router.intent_changed.connect(func(_i): probe.order_log.append(&"router"))

	var lit := ProbeIntent.new()
	_router.push_intent(lit)
	await get_tree().process_frame
	await get_tree().process_frame
	check("SETUP: the probe is live under an intent that names it",
		probe.is_processing(),
		"the router never switched it on, so the order below is untestable")

	probe.order_log.clear()
	var dark: PlayerIntent = PLAYER_INTENT_SCRIPT.new()
	_router.push_intent(dark)
	await get_tree().process_frame
	await get_tree().process_frame
	check("on the frame the intent moves, the router runs before the "
			+ "indicators it drives",
		not probe.order_log.is_empty() and probe.order_log[0] == &"router",
		"log was %s — the indicators sit ahead of the router in the tree, "
			% [probe.order_log]
			+ "so without process_priority they process a frame ahead of "
			+ "the intent that governs them")

	_router.pop_intent(dark)
	_router.pop_intent(lit)

	# --- an indicator that arrives after boot ----------------------------
	#
	# _apply_intent only runs when the intent MOVES, so anything joining
	# the group afterwards would stay dark forever — and on arrival in a
	# new world, an indicator left live from the old one keeps drawing at
	# the old world's coordinates. Both are the same hole, and a world
	# becoming focused is what closes it.
	_router.push_intent(ProbeIntent.new())
	await get_tree().process_frame
	await get_tree().process_frame

	var latecomer := OrderProbe.new()
	_spawn_parent().add_child(latecomer)
	await get_tree().process_frame
	await get_tree().process_frame
	check("an indicator that joins after the intent settled is dark, "
			+ "because the intent never moved",
		not latecomer.is_processing(),
		"it woke up on its own, which would mean something other than the "
			+ "router is deciding liveness")

	WorldManager.world_focused.emit(WorldManager.current_world())
	await get_tree().process_frame
	await get_tree().process_frame
	check("and focusing a world re-applies the intent to whatever is in "
			+ "the group now",
		latecomer.is_processing(),
		"the router is not listening to WorldManager.world_focused, so an "
			+ "overlay drawn in the world you left keeps drawing at its "
			+ "old coordinates in the world you arrive in")

	latecomer.queue_free()
	probe.queue_free()
	_router.set_process(false)
	_router._last = null


## Read off the source, because what is being asserted is an ABSENCE: a
## deleted handler leaves nothing behind to call.
##
## `func _on_input_event`, not the bare name — the declaration is code,
## and a check that fires on the substring anywhere in the file is a
## check on comment prose, which is not a thing a suite gets to dictate.
## (A prose check on "DialogueManager." lived here and has been removed
## for that reason; the behaviour it was standing in for — a click during
## a conversation doing nothing — is asserted for real in
## _losing_the_screen_locks_everything, and against every screen-owning
## mode rather than only dialogue.)
func _a_unit_no_longer_owns_its_own_click() -> void:
	var text: String = _read("res://systems/unit_system/unit.gd")
	check("unit.gd loads at all for the source check below",
		text != "",
		"could not open unit.gd")
	check("a unit no longer decides what a click on it means",
		not text.contains("func _on_input_event"),
		"unit.gd still declares a physics-picked click handler — that is a "
			+ "second owner of player intent, one per unit in the world")


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text: String = file.get_as_text()
	file.close()
	return text


func _arm_and_apply(ability: Ability) -> void:
	AbilityManager.arm(ability)
	_router._process(0.0)


## Sorted so the comparisons above are order-independent — as Strings,
## deliberately: StringName's own < compares POINTERS, not text, so
## sorting StringNames gives an order that means nothing and does not
## survive a rerun.
func _live_ids() -> Array:
	var live: Array = []
	for id in _indicators:
		if _indicators[id].is_processing():
			live.append(String(id))
	live.sort()
	return live


func _pack_up() -> void:
	AbilityManager.disarm()
	for id in _indicators:
		_indicators[id].queue_free()
	_indicators.clear()
	if is_instance_valid(_router):
		_router.queue_free()
	_router = null
