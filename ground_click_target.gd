extends IndicatorBase
## Global click router — the one place that decides what left/right click
## do, for both the ground AND anything interactable (a Unit, an
## InteractableProp, anything future implementing get_interactions()).
##
## Left-click on empty ground moves the selected unit(s) there — UNLESS a
## ground-point-targeting ability like Jump is armed, in which case it's
## used instead (see _try_use_ground_targeted_ability). Left-click on an
## interactable does nothing here at all — Unit._on_input_event (still
## per-object physics picking) owns that click; this script's own
## hovered-interactable check exists purely to bail out and stay out of
## its way.
##
## Right-click disarms an armed ability if there is one (same "cancel the
## thing I just armed" priority as before — right-click swallowing input
## silently otherwise reads as broken, not intentional). Otherwise, if
## the cursor is over an interactable, opens InteractionMenu for it —
## this is the ONLY place that happens; no interactable needs its own
## right-click wiring, just get_interactions(). Right-click on empty
## ground does nothing (no menu, no move — move lives on left-click now).
##
## One global node doing a centralized raycast (via IndicatorBase's
## _get_mouse_ground_point/_get_hovered_unit/_get_hovered_interactable),
## NOT a script attached to every ground collision body — the previous
## version extended StaticBody3D and relied on per-object physics picking
## (CollisionObject3D.input_event), which meant this exact script had
## to be attached individually to all five of main.tscn's ground/
## platform bodies. That stops scaling the moment a real level's ground
## is built from more than a handful of pieces (a GridMap, a multi-
## chunk terrain, ...). This version needs to exist exactly once, and
## works against any number of ground bodies for free as long as they're
## on ground_collision_mask (see IndicatorBase) — no per-object setup.
##
## "Left-click"/"right-click"/"deselect_all" below are all InputMap
## actions (see project.godot > Input Map), not hardcoded
## MOUSE_BUTTON_LEFT/RIGHT/KEY_TAB checks — rebinding any of them needs no
## code change.

func _unhandled_input(event: InputEvent) -> void:
	# The cinematic camera being frozen out from under a live conversation
	# or menu (see camera_director.gd) doesn't by itself stop a click from
	# still reaching the tactical world underneath it — this is what
	# actually does that: no move orders, no ability casts, no context
	# menus while any of CameraDirector's own blockers own the screen.
	# Reuses has_control() itself rather than keeping a second,
	# separately-maintained list of the same conditions here — a click
	# shouldn't be able to reach the world in any state where the camera
	# is frozen out of responding to input either.
	if not CameraDirector.has_control():
		return

	if event.is_action_pressed("left_click"):
		if PlayerInteractionState.is_debug_spawn_armed():
			_spawn_debug_unit()
			return
		if _get_hovered_interactable():
			return
		var click_position = _get_mouse_ground_point()
		if click_position == null:
			return
		if _try_use_ground_targeted_ability(click_position):
			return
		_command_move(click_position)
	elif event.is_action_pressed("right_click"):
		if DebugSpawner.armed_definition:
			DebugSpawner.disarm()
			return
		if AbilityManager.armed_ability:
			AbilityManager.disarm()
			return
		var target: Node = _get_hovered_interactable()
		if not target:
			return
		var actor: Unit = PlayerInteractionState.get_active_unit()
		if actor:
			InteractionMenu.open_for(target, actor)
	elif event.is_action_pressed("deselect_all"):
		SelectionManager.deselect_all()


## If the currently armed ability (see AbilityManager) expects a ground
## point as its target (Ability.targeting.expects_point_target — Jump,
## an AoE, or any future point-targeting ability), and it's the acting
## player unit's own turn, uses it at the clicked point instead of the
## click falling through to normal ground-click behavior. Mirrors how
## Unit._on_input_event checks ability-use before falling through to
## normal selection on an enemy click — same pattern, applied to ground
## clicks instead of unit clicks. Returns true if the click was consumed
## this way.
func _try_use_ground_targeted_ability(click_position: Vector3) -> bool:
	var ability: Ability = AbilityManager.armed_ability
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
	var target_point: Vector3 = ability.targeting.resolve_target_point(click_position)
	unit.use_ability(ability, target_point)
	return true


## Spawns DebugSpawner's currently armed UnitDefinition at wherever the
## ground raycast resolves this click, joining active combat if one's
## running (CombatManager.add_unit_to_combat no-ops out of combat). See
## SummonDemonEffect.apply() for the pattern this simplifies from.
##
## Always consumes the click while armed, even on a miss (no ground hit
## under the cursor) — deliberately does NOT fall through to
## _command_move on a miss, so an accidental miss-click while armed can
## never move the selected unit instead. Stays armed on a miss; disarms
## only once a spawn actually lands.
func _spawn_debug_unit() -> void:
	var click_position = _get_mouse_ground_point()
	if click_position == null:
		return

	var definition: UnitDefinition = DebugSpawner.armed_definition
	var faction: StringName = DebugSpawner.armed_faction
	DebugSpawner.disarm()

	var spawned: Unit = definition.unit_scene.instantiate()
	# .definition's cascade sets faction = definition.faction as part of
	# the same assignment — the override below must come AFTER, or the
	# panel's chosen faction gets silently overwritten back to the
	# species default the instant .definition is assigned.
	spawned.definition = definition
	spawned.faction = faction
	if faction == &"enemy":
		# hover_color/selected_color aren't part of the .definition cascade
		# (see UnitDefinition's header) and default to Unit's own
		# yellow-gold — correct for a friendly spawn (every player-faction
		# unit in main.tscn leaves these unset too), wrong for a hostile
		# one. Every hand-authored hostile uses exactly this red, so match
		# it here instead of leaving debug spawns looking friendly.
		spawned.hover_color = Color(1, 0, 0, 0.501961)
		spawned.selected_color = Color(1, 0, 0, 0.627451)
	WorldManager.spawn_parent().add_child(spawned)
	spawned.global_position = click_position

	CombatManager.add_unit_to_combat(spawned)

	if faction == &"player":
		# party_panel.gd listens to PartyManager.member_added directly and
		# picks this up on its own — no separate registration call needed
		# (that used to be true, back when the panel only ever scanned
		# once at boot; not anymore, see that file's own _ready() header).
		PartyManager.add_member(spawned)


## Only reached on a left-click that didn't land on an interactable and
## wasn't consumed by an armed ground-targeted ability — see
## _unhandled_input.
func _command_move(destination: Vector3) -> void:
	if CombatManager.in_combat:
		# Only the acting unit may move, and only on its own turn — a
		# ground click while other units are selected (or it's not your
		# turn) is silently ignored rather than moving the wrong unit.
		var unit: Unit = CombatManager.current_unit
		if unit and unit in SelectionManager.selected_units:
			unit.move_to(destination)
		return

	# Free-roam moves aren't gated by turn order the way combat is — every
	# selected unit can move at once — so all of them are excluded from
	# occupancy for this one update, not just a single mover (see
	# NavigationGrid). Simultaneous movers can still end up navigating
	# around each other's stale (pre-move) positions rather than truly
	# live positions until the next update — an accepted approximation
	# outside combat, where "only one unit ever moves at a time" doesn't
	# hold in the first place.
	NavigationGrid.update_occupancy(get_tree(), SelectionManager.selected_units)

	# Leader/follower formation math lives on FormationPlanner, not here —
	# see that file for why it's leader-driven but fully deterministic.
	FormationPlanner.command_group_move(SelectionManager.selected_units, destination)
